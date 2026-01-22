defmodule Bash.Builtin.Context do
  @moduledoc false

  alias Bash.CommandResult
  alias Bash.Sink

  @context_key :defbash_builtin_context
  @context_stack_key :defbash_builtin_context_stack

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

  @doc """
  Initialize execution context from session state.

  Extracts sinks and stdin from session state and stores context
  in the process dictionary. Saves any existing context to a stack
  to support nested builtin calls.
  """
  @spec init(map()) :: :ok
  def init(session_state) do
    # Save existing context to stack if present (for nested calls)
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

  @doc """
  Finalize execution and return appropriate result.

  Converts the defbash return value to the format expected by Session:
    - `:ok` -> `{:ok, %CommandResult{exit_code: 0}}`
    - `{:ok, n}` -> `{:ok, %CommandResult{exit_code: n}}`
    - `{:error, msg}` -> `{:error, %CommandResult{exit_code: 1, ...}}`

  Also includes any state updates requested via `update_state/1`.
  """
  @spec finalize(term()) ::
          {:ok, CommandResult.t()} | {:ok, CommandResult.t(), map()} | {:error, CommandResult.t()}
  def finalize(result) do
    ctx = Process.delete(@context_key)

    # Restore previous context from stack if present (for nested calls)
    case Process.get(@context_stack_key, []) do
      [] ->
        :ok

      [prev_ctx | rest] ->
        Process.put(@context_key, prev_ctx)

        if rest == [] do
          Process.delete(@context_stack_key)
        else
          Process.put(@context_stack_key, rest)
        end
    end

    state_updates = if ctx, do: ctx.state_updates, else: %{}

    case result do
      # Simple return values (new API)
      :ok ->
        cmd_result = %CommandResult{command: nil, exit_code: 0, error: nil}

        if state_updates == %{} do
          {:ok, cmd_result}
        else
          {:ok, cmd_result, state_updates}
        end

      {:ok, exit_code} when is_integer(exit_code) ->
        cmd_result = %CommandResult{command: nil, exit_code: exit_code, error: nil}

        if state_updates == %{} do
          {:ok, cmd_result}
        else
          {:ok, cmd_result, state_updates}
        end

      # Pass through already-formatted results for backwards compatibility
      {:ok, %CommandResult{} = cmd_result} ->
        if state_updates == %{} do
          {:ok, cmd_result}
        else
          {:ok, cmd_result, state_updates}
        end

      {:ok, %CommandResult{} = cmd_result, existing_updates} ->
        merged_updates = Map.merge(state_updates, existing_updates)
        {:ok, cmd_result, merged_updates}

      {:error, %CommandResult{} = cmd_result} ->
        if state_updates == %{} do
          {:error, cmd_result}
        else
          {:error, cmd_result, state_updates}
        end

      # Control flow tuples - pass through
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

      # Also handle exec with map result from CommandPort
      {:exec, result} when is_map(result) ->
        {:exec, result}

      # Job control tuples - pass through for Session to handle
      {:background_job, job_numbers} ->
        {:background_job, job_numbers}

      {:foreground_job, job_number} ->
        {:foreground_job, job_number}

      {:signal_jobs, signal, targets} ->
        {:signal_jobs, signal, targets}

      {:wait_for_jobs, job_specs} ->
        {:wait_for_jobs, job_specs}

      # Generic error with message (new API) - must come AFTER CommandResult patterns
      {:error, message} when is_binary(message) ->
        # Write error to stderr sink
        if ctx, do: Sink.write_stderr(ctx.state, to_string(message) <> "\n")

        cmd_result = %CommandResult{command: nil, exit_code: 1, error: :command_failed}

        if state_updates == %{} do
          {:error, cmd_result}
        else
          {:error, cmd_result, state_updates}
        end

      other ->
        # Unknown return - treat as error
        cmd_result = %CommandResult{command: nil, exit_code: 1, error: {:invalid_return, other}}
        {:error, cmd_result}
    end
  end

  @doc """
  Clean up context on exception (no result to return).
  """
  @spec cleanup() :: :ok
  def cleanup do
    Process.delete(@context_key)

    # Restore previous context from stack if present (for nested calls)
    case Process.get(@context_stack_key, []) do
      [] ->
        :ok

      [prev_ctx | rest] ->
        Process.put(@context_key, prev_ctx)

        if rest == [] do
          Process.delete(@context_stack_key)
        else
          Process.put(@context_stack_key, rest)
        end
    end

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
  Write raw data to stdout (no newline added).
  """
  @spec write(iodata()) :: :ok
  def write(data) do
    ctx = get_context()
    binary_data = IO.iodata_to_binary(data)
    Sink.write_stdout(ctx.state, binary_data)
    :ok
  end

  @doc """
  Write message to stderr with trailing newline.
  """
  @spec error(String.t()) :: :ok
  def error(message) do
    ctx = get_context()
    binary_data = to_string(message) <> "\n"
    Sink.write_stderr(ctx.state, binary_data)
    :ok
  end

  @doc """
  Write raw data to stderr (no newline added).
  """
  @spec write_stderr(iodata()) :: :ok
  def write_stderr(data) do
    ctx = get_context()
    binary_data = IO.iodata_to_binary(data)
    Sink.write_stderr(ctx.state, binary_data)
    :ok
  end

  @doc """
  Read a line from stdin.

  Returns `{:ok, line}`, `:eof`, or `{:error, reason}`.
  """
  @spec gets() :: {:ok, String.t()} | :eof | {:error, term()}
  def gets do
    ctx = get_context()

    case ctx.stdin do
      nil ->
        :eof

      stdin when is_pid(stdin) ->
        case IO.read(stdin, :line) do
          :eof -> :eof
          {:error, reason} -> {:error, reason}
          data -> {:ok, data}
        end

      stdin when is_binary(stdin) ->
        # String stdin - read first line
        case String.split(stdin, "\n", parts: 2) do
          [line] ->
            update_stdin(nil)
            {:ok, line}

          [line, rest] ->
            update_stdin(rest)
            {:ok, line <> "\n"}
        end
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
      nil ->
        :eof

      stdin when is_pid(stdin) ->
        case IO.read(stdin, :eof) do
          :eof -> :eof
          {:error, reason} -> {:error, reason}
          data -> {:ok, data}
        end

      stdin when is_binary(stdin) ->
        update_stdin(nil)
        {:ok, stdin}
    end
  end

  def read(n) when is_integer(n) and n > 0 do
    ctx = get_context()

    case ctx.stdin do
      nil ->
        :eof

      stdin when is_pid(stdin) ->
        case IO.read(stdin, n) do
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
    end
  end

  @doc """
  Get the current session state.
  """
  @spec get_state() :: map()
  def get_state, do: get_context().state

  @doc """
  Request state updates to be applied after execution completes.

  Supported keys:
    - `:working_dir` - New working directory
    - `:env` or `:env_updates` - Environment variable updates
    - `:var_updates` - Variable updates (Variable structs)
    - `:alias_updates` - Alias updates
    - `:function_updates` - Function updates
    - `:dir_stack` - Directory stack
    - `:options` - Shell options
    - `:hash_updates` - Command hash updates
    - `:positional_params` - Positional parameters

  ## Example

      update_state(
        working_dir: "/new/path",
        env_updates: %{"PWD" => "/new/path", "OLDPWD" => "/old/path"}
      )
  """
  @spec update_state(keyword() | map()) :: :ok
  def update_state(updates) when is_list(updates) do
    update_state(Map.new(updates))
  end

  def update_state(updates) when is_map(updates) do
    ctx = get_context()
    new_updates = Map.merge(ctx.state_updates, updates)
    Process.put(@context_key, %{ctx | state_updates: new_updates})
    :ok
  end

  defp get_context do
    case Process.get(@context_key) do
      nil ->
        raise RuntimeError, """
        No builtin execution context available.

        puts/write/error/gets/read/update_state can only be called inside a defbash function.
        """

      ctx ->
        ctx
    end
  end

  defp update_stdin(new_stdin) do
    ctx = get_context()
    Process.put(@context_key, %{ctx | stdin: new_stdin})
    :ok
  end
end
