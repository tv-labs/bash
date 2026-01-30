defmodule Bash.Context do
  @moduledoc """
  Unified execution context for `defbash` functions in both builtins and interop.

  Manages process-dictionary-based I/O context with support for nesting
  (e.g., `eval` calling builtins). Provides stdout/stderr writing, stdin reading,
  state access, and delta-based state updates.

  ## I/O Functions

    * `write/1` - Write raw data to stdout
    * `write_stderr/1` - Write raw data to stderr
    * `puts/1` - Write to stdout with trailing newline
    * `error/1` - Write to stderr with trailing newline

  ## Stdin

    * `gets/0` - Read a line from stdin
    * `read/1` - Read from stdin (`:all`, `:line`, or byte count)
    * `stream/1` - Get stdin as a lazy stream

  ## Output Streams

    * `stream/2` - Stream an enumerable to stdout or stderr

  ## State

    * `get_state/0` - Get the current session state
    * `update_state/1` - Accumulate state update deltas
  """

  alias Bash.CommandResult
  alias Bash.Sink

  @context_key :bash_context
  @context_stack_key :bash_context_stack

  defstruct [
    :state,
    :stdin,
    state_updates: %{}
  ]

  @type t :: %__MODULE__{
          state: map(),
          stdin: term(),
          state_updates: map()
        }

  @doc false
  # Initialize execution context from session state.
  #
  # Extracts stdin from session state and stores context in the process dictionary.
  # Saves any existing context to a stack to support nested calls (e.g., `eval`
  # invoking a builtin).
  @spec init(map()) :: :ok
  def init(session_state) do
    case Process.get(@context_key) do
      nil ->
        :ok

      existing_ctx ->
        stack = Process.get(@context_stack_key, [])
        Process.put(@context_stack_key, [existing_ctx | stack])
    end

    ctx = %__MODULE__{
      state: session_state,
      stdin: Map.get(session_state, :stdin)
    }

    Process.put(@context_key, ctx)
    :ok
  end

  @doc false
  # Finalize execution and return appropriate result.
  #
  # Converts the defbash return value to the format expected by Session:
  #   - `:ok` -> `{:ok, %CommandResult{exit_code: 0}}`
  #   - `{:ok, n}` -> `{:ok, %CommandResult{exit_code: n}}`
  #   - `{:error, msg}` -> `{:error, %CommandResult{exit_code: 1, ...}}`
  #
  # Also includes any state updates requested via `update_state/1`.
  @spec finalize(term()) ::
          {:ok, CommandResult.t()} | {:ok, CommandResult.t(), map()} | {:error, CommandResult.t()}
  def finalize(result) do
    ctx = Process.delete(@context_key)
    restore_previous_context()

    state_updates = if ctx, do: ctx.state_updates, else: %{}

    case result do
      :ok ->
        wrap_ok(%CommandResult{command: nil, exit_code: 0, error: nil}, state_updates)

      {:ok, exit_code} when is_integer(exit_code) ->
        wrap_ok(%CommandResult{command: nil, exit_code: exit_code, error: nil}, state_updates)

      {:ok, %CommandResult{} = cmd_result} ->
        wrap_ok(cmd_result, state_updates)

      {:ok, %CommandResult{} = cmd_result, existing_updates} ->
        {:ok, cmd_result, Map.merge(state_updates, existing_updates)}

      {:error, %CommandResult{} = cmd_result} ->
        if state_updates == %{} do
          {:error, cmd_result}
        else
          {:error, cmd_result, state_updates}
        end

      {:break, %CommandResult{} = cmd_result, levels} ->
        {:break, cmd_result, levels}

      {:continue, %CommandResult{} = cmd_result, levels} ->
        {:continue, cmd_result, levels}

      {:exit, %CommandResult{} = cmd_result} ->
        {:exit, cmd_result}

      {:suspend, %CommandResult{} = cmd_result} ->
        {:suspend, cmd_result}

      {:exec, %CommandResult{} = cmd_result} ->
        {:exec, cmd_result}

      {:exec, result} when is_map(result) ->
        {:exec, result}

      {:background_job, job_numbers} ->
        {:background_job, job_numbers}

      {:foreground_job, job_number} ->
        {:foreground_job, job_number}

      {:signal_jobs, signal, targets} ->
        {:signal_jobs, signal, targets}

      {:wait_for_jobs, job_specs} ->
        {:wait_for_jobs, job_specs}

      {:error, message} when is_binary(message) ->
        if ctx, do: Sink.write_stderr(ctx.state, to_string(message) <> "\n")

        cmd_result = %CommandResult{command: nil, exit_code: 1, error: :command_failed}

        if state_updates == %{} do
          {:error, cmd_result}
        else
          {:error, cmd_result, state_updates}
        end

      other ->
        cmd_result = %CommandResult{command: nil, exit_code: 1, error: {:invalid_return, other}}
        {:error, cmd_result}
    end
  end

  defp wrap_ok(cmd_result, state_updates) when state_updates == %{}, do: {:ok, cmd_result}
  defp wrap_ok(cmd_result, state_updates), do: {:ok, cmd_result, state_updates}

  @doc false
  # Clean up context on exception (no result to return).
  @spec cleanup() :: :ok
  def cleanup do
    Process.delete(@context_key)
    restore_previous_context()
    :ok
  end

  @doc """
  Write message to stdout with trailing newline.
  """
  @spec puts(String.t()) :: :ok
  def puts(message) do
    write(to_string(message) <> "\n")
  end

  @doc """
  Write to stdout or stderr.

  When called with a stream target and message:
    - `puts(:stdout, message)` - Write to stdout
    - `puts(:stderr, message)` - Write to stderr
  """
  @spec puts(:stdout | :stderr, String.t()) :: :ok
  def puts(:stdout, message), do: puts(message)

  def puts(:stderr, message) do
    case get_context_safe() do
      nil -> :ok
      context -> Sink.write_stderr(context.state, message)
    end

    :ok
  end

  @doc """
  Write raw data to stdout (no newline added).
  """
  @spec write(iodata()) :: :ok
  def write(data) do
    case get_context_safe() do
      nil -> :ok
      ctx -> Sink.write_stdout(ctx.state, IO.iodata_to_binary(data))
    end
  end

  @doc """
  Write message to stderr with trailing newline.
  """
  @spec error(String.t()) :: :ok
  def error(message) do
    case get_context_safe() do
      nil ->
        :ok

      ctx ->
        binary_data = to_string(message) <> "\n"
        Sink.write_stderr(ctx.state, binary_data)
    end
  end

  @doc """
  Write raw data to stderr (no newline added).
  """
  @spec write_stderr(iodata()) :: :ok
  def write_stderr(data) do
    case get_context_safe() do
      nil ->
        :ok

      ctx ->
        binary_data = IO.iodata_to_binary(data)
        Sink.write_stderr(ctx.state, binary_data)
    end
  end

  @doc """
  Read a line from stdin.

  Returns `{:ok, line}`, `:eof`, or `{:error, reason}`.
  """
  @spec gets() :: {:ok, String.t()} | :eof | {:error, term()}
  def gets do
    ctx = get_context()

    case ctx.stdin do
      empty when empty in [nil, ""] ->
        :eof

      stdin when is_pid(stdin) ->
        case IO.binread(stdin, :line) do
          :eof -> :eof
          {:error, reason} -> {:error, reason}
          data -> {:ok, data}
        end

      stdin when is_binary(stdin) ->
        gets_from_binary(stdin)

      {buffer, rest} when is_binary(buffer) ->
        gets_from_binary_with_rest(buffer, rest)

      stdin ->
        pull_and_gets(stdin)
    end
  end

  defp gets_from_binary(stdin) do
    case String.split(stdin, "\n", parts: 2) do
      [line] ->
        update_stdin(nil)
        {:ok, line}

      [line, ""] ->
        update_stdin(nil)
        {:ok, line <> "\n"}

      [line, rest] ->
        update_stdin(rest)
        {:ok, line <> "\n"}
    end
  end

  defp gets_from_binary_with_rest(buffer, rest) do
    case String.split(buffer, "\n", parts: 2) do
      [no_newline] ->
        case take_next(rest) do
          :eof ->
            update_stdin(nil)
            if no_newline == "", do: :eof, else: {:ok, no_newline}

          {:ok, chunk, new_rest} ->
            update_stdin({IO.iodata_to_binary([no_newline, chunk]), new_rest})
            gets()
        end

      [line, ""] ->
        update_stdin({"", rest})
        {:ok, line <> "\n"}

      [line, remaining] ->
        update_stdin({remaining, rest})
        {:ok, line <> "\n"}
    end
  end

  defp pull_and_gets(enumerable) do
    case take_next(enumerable) do
      :eof ->
        update_stdin(nil)
        :eof

      {:ok, chunk, rest} ->
        update_stdin({IO.iodata_to_binary(chunk), rest})
        gets()
    end
  end

  @doc """
  Read from stdin.

  Modes:
    - `:all` - Read all remaining input
    - `:line` - Read a single line (same as `gets/0`)
    - `n` (integer) - Read n bytes
  """
  @spec read(:all | :line | non_neg_integer()) :: {:ok, String.t()} | :eof | {:error, term()}
  def read(:line), do: gets()

  def read(:all) do
    ctx = get_context()

    case ctx.stdin do
      empty when empty in [nil, ""] ->
        :eof

      stdin when is_pid(stdin) ->
        case IO.binread(stdin, :eof) do
          :eof -> :eof
          {:error, reason} -> {:error, reason}
          data -> {:ok, data}
        end

      stdin when is_binary(stdin) ->
        update_stdin(nil)
        {:ok, stdin}

      {buffer, rest} when is_binary(buffer) ->
        tail = rest |> Enum.map(&IO.iodata_to_binary/1) |> IO.iodata_to_binary()
        update_stdin(nil)
        {:ok, IO.iodata_to_binary([buffer, tail])}

      stdin ->
        data = stdin |> Enum.map(&IO.iodata_to_binary/1) |> IO.iodata_to_binary()
        update_stdin(nil)

        if data == "" do
          :eof
        else
          {:ok, data}
        end
    end
  end

  def read(n) when is_integer(n) and n > 0 do
    ctx = get_context()

    case ctx.stdin do
      empty when empty in [nil, ""] ->
        :eof

      stdin when is_pid(stdin) ->
        case IO.binread(stdin, n) do
          :eof -> :eof
          {:error, reason} -> {:error, reason}
          data -> {:ok, data}
        end

      stdin when is_binary(stdin) ->
        if byte_size(stdin) <= n do
          update_stdin(nil)
          {:ok, stdin}
        else
          <<chunk::binary-size(^n), rest::binary>> = stdin
          update_stdin(rest)
          {:ok, chunk}
        end

      {buffer, rest} when is_binary(buffer) ->
        if byte_size(buffer) >= n do
          <<chunk::binary-size(^n), remaining::binary>> = buffer
          update_stdin({remaining, rest})
          {:ok, chunk}
        else
          case take_next(rest) do
            :eof ->
              update_stdin(nil)
              {:ok, buffer}

            {:ok, chunk, new_rest} ->
              update_stdin({IO.iodata_to_binary([buffer, chunk]), new_rest})
              read(n)
          end
        end

      stdin ->
        case take_next(stdin) do
          :eof ->
            update_stdin(nil)
            :eof

          {:ok, chunk, rest} ->
            update_stdin({IO.iodata_to_binary(chunk), rest})
            read(n)
        end
    end
  end

  @doc """
  Get stdin as a lazy stream.

  Returns an empty stream if no stdin is available.
  """
  @spec stream(:stdin) :: Enumerable.t()
  def stream(:stdin) do
    case get_context_safe() do
      nil ->
        Stream.map([], & &1)

      context ->
        case context.stdin do
          nil -> Stream.map([], & &1)
          list when is_list(list) -> Stream.map(list, & &1)
          stream -> stream
        end
    end
  end

  @doc """
  Stream an enumerable to stdout or stderr.

  Each element is converted to a string and written immediately.
  """
  @spec stream(:stdout | :stderr, Enumerable.t()) :: :ok
  def stream(:stdout, enumerable) do
    case get_context_safe() do
      nil ->
        :ok

      context ->
        Enum.each(enumerable, fn chunk ->
          Sink.write_stdout(context.state, to_string(chunk))
        end)
    end

    :ok
  end

  def stream(:stderr, enumerable) do
    case get_context_safe() do
      nil ->
        :ok

      context ->
        Enum.each(enumerable, fn chunk ->
          Sink.write_stderr(context.state, to_string(chunk))
        end)
    end

    :ok
  end

  @doc """
  Get the current session state.
  """
  @spec get_state() :: map()
  def get_state do
    case get_context_safe() do
      nil -> %{}
      context -> context.state
    end
  end

  @doc """
  Request state updates to be applied after execution completes.

  Accumulates a delta map of update keys.

  For more details on settings variables, see `Bash.Variable`. By default, a string key
  and string value will default to an exported variable.

  ## Example

      update_state(
        working_dir: "/new/path",
        variables: %{"PWD" => "/new/path"}
      )
  """
  @spec update_state(keyword() | map()) :: :ok
  def update_state(updates) when is_list(updates) do
    update_state(Map.new(updates))
  end

  def update_state(updates) when is_map(updates) do
    ctx = get_context()
    normalized = normalize_variable_updates(updates)
    new_updates = Map.merge(ctx.state_updates, normalized)
    Process.put(@context_key, %{ctx | state_updates: new_updates})
    :ok
  end

  defp normalize_variable_updates(%{variables: vars} = updates) when is_map(vars) do
    normalized_vars =
      Map.new(vars, fn
        {k, %Bash.Variable{} = v} ->
          {k, v}

        {k, nil} ->
          {k, nil}

        {k, v} when is_binary(v) ->
          var = Bash.Variable.new(v)
          {k, %{var | attributes: %{var.attributes | export: true}}}
      end)

    %{updates | variables: normalized_vars}
  end

  defp normalize_variable_updates(updates), do: updates

  @doc """
  Get accumulated state updates from the current context.

  Used by interop's `execute_with_context` to retrieve deltas without
  going through `finalize/1`.
  """
  @spec get_state_updates() :: map()
  def get_state_updates do
    case get_context_safe() do
      nil -> %{}
      ctx -> ctx.state_updates
    end
  end

  @doc """
  Delete the current context and restore previous (for interop cleanup).
  """
  @spec delete_context() :: :ok
  def delete_context do
    Process.delete(@context_key)
    restore_previous_context()
    :ok
  end

  # Raises if no context — used by builtins that require a context
  defp get_context do
    case Process.get(@context_key) do
      nil ->
        raise RuntimeError, """
        No execution context available.

        puts/write/error/gets/read/update_state can only be called inside a defbash function.
        """

      ctx ->
        ctx
    end
  end

  # Returns nil if no context — used by interop functions that tolerate missing context
  defp get_context_safe, do: Process.get(@context_key)

  defp update_stdin(new_stdin) do
    ctx = get_context()
    Process.put(@context_key, %{ctx | stdin: new_stdin})
    :ok
  end

  defp take_next([]), do: :eof
  defp take_next([head | tail]), do: {:ok, head, tail}

  defp take_next(stream) do
    reducer = fn element, _acc -> {:suspend, element} end

    case Enumerable.reduce(stream, {:cont, nil}, reducer) do
      {:suspended, element, continuation} ->
        rest_stream = Stream.resource(fn -> continuation end, &resume_stream/1, fn _ -> :ok end)
        {:ok, element, rest_stream}

      {:done, _} ->
        :eof

      {:halted, _} ->
        :eof
    end
  end

  defp resume_stream(continuation) do
    case continuation.({:cont, nil}) do
      {:suspended, element, next_cont} -> {[element], next_cont}
      {:done, _} -> {:halt, nil}
      {:halted, _} -> {:halt, nil}
    end
  end

  defp restore_previous_context do
    case Process.get(@context_stack_key, []) do
      [] ->
        :ok

      [prev_ctx] ->
        Process.put(@context_key, prev_ctx)
        Process.delete(@context_stack_key)

      [prev_ctx | rest] ->
        Process.put(@context_key, prev_ctx)
        Process.put(@context_stack_key, rest)
    end
  end
end
