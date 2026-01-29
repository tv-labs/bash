defmodule Bash.AST.Pipeline do
  @moduledoc """
  Pipeline: sequence of commands connected by pipes (|).

  ## Examples

      # ls | grep txt | wc -l
      %Pipeline{
        commands: [
          %Command{name: "ls", ...},
          %Command{name: "grep", args: ["txt"], ...},
          %Command{name: "wc", args: ["-l"], ...}
        ]
      }

      # ! grep pattern file
      %Pipeline{
        commands: [%Command{name: "grep", ...}],
        negate: true
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.Builtin
  alias Bash.Executor
  alias Bash.OutputCollector
  alias Bash.Sink
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          commands: [AST.Command.t()],
          negate: boolean(),
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map(),
          pipestatus: [0..255] | nil
        }

  defstruct [
    :meta,
    :commands,
    negate: false,
    # Execution results
    exit_code: nil,
    state_updates: %{},
    pipestatus: nil
  ]

  # Get exit code from the last command (respects PIPEFAIL session option).
  @doc false
  @spec get_exit_code(t()) :: 0..255 | nil
  def get_exit_code(%__MODULE__{exit_code: exit_code}), do: exit_code

  # Get array of all exit codes from each command in the pipeline.
  @doc false
  @spec pipestatus(t()) :: [0..255] | nil
  def pipestatus(%__MODULE__{pipestatus: pipestatus}), do: pipestatus

  # Execute a Pipeline - chain commands together, piping output from one to the next
  #
  # Options:
  #   - :sink - Output sink for streaming (default: accumulates to output field)
  def execute(%__MODULE__{commands: commands} = pipeline, stdin, session_state, opts \\ []) do
    # For pure external command pipelines, use streaming for memory efficiency
    cond do
      all_external_commands?(commands, session_state) ->
        execute_streaming(pipeline, stdin, session_state, opts)

      has_any_external_commands?(commands, session_state) ->
        # Mixed pipeline: stream between external commands, accumulate at builtin boundaries
        execute_mixed(pipeline, stdin, session_state, opts)

      true ->
        # All builtins/functions - use sequential execution
        execute_sequential(pipeline, stdin, session_state, opts)
    end
  end

  defp has_any_external_commands?(commands, session_state) do
    Enum.any?(commands, &external_command?(&1, session_state))
  end

  # Execute a mixed pipeline by segmenting into external command runs and non-external commands.
  # External segments stream via ExCmd. Non-external commands execute individually.
  # Only accumulates at builtin boundaries that require stdin.
  defp execute_mixed(
         %__MODULE__{commands: commands, negate: negate, meta: meta} = pipeline,
         stdin,
         session_state,
         _opts
       ) do
    started_at = DateTime.utc_now()

    # Segment commands into runs of external vs individual non-external
    segments = segment_commands(commands, session_state)

    # Execute segments, passing output from one to the next
    # Track exit codes per command (not per segment) for proper PIPESTATUS
    {final_output, exit_codes, _env_updates} =
      Enum.reduce(segments, {stdin, [], %{}}, fn segment, {input, codes, env} ->
        # Update session state with accumulated env updates
        updated_session = apply_env_updates(session_state, env)

        case segment do
          {:external, external_cmds} ->
            # Build and execute streaming pipeline for external commands
            {output, segment_exit_code} =
              execute_external_segment(external_cmds, input, updated_session)

            # Expand exit code to one per command in the segment
            # Note: ExCmd streaming only gives us the final exit code, so we
            # replicate it for each command. This is accurate when all succeed,
            # but for pipefail we'd need individual process tracking.
            segment_codes = List.duplicate(segment_exit_code, length(external_cmds))
            {output, codes ++ segment_codes, env}

          {:other, cmd} ->
            # Execute non-external command (builtin/function)
            {output, exit_code, cmd_env} =
              execute_non_external_command(cmd, input, updated_session)

            {output, codes ++ [exit_code], Map.merge(env, cmd_env)}
        end
      end)

    completed_at = DateTime.utc_now()

    # Determine final exit code based on pipefail
    pipefail_enabled = pipefail_enabled?(session_state)

    final_exit_code =
      if pipefail_enabled do
        # Rightmost non-zero, or 0 if all succeeded
        Enum.reduce(exit_codes, 0, fn code, acc ->
          if code != 0, do: code, else: acc
        end)
      else
        # Last command's exit code
        List.last(exit_codes) || 0
      end

    # Apply negate
    final_exit_code =
      if negate do
        if final_exit_code == 0, do: 1, else: 0
      else
        final_exit_code
      end

    # Write final output to session's sink to maintain ordering with other commands
    # The sink writes to the session's OutputCollector which preserves order
    case Map.get(session_state, :stdout_sink) do
      sink when is_function(sink) and is_binary(final_output) and final_output != "" ->
        sink.({:stdout, final_output})

      _ ->
        :ok
    end

    # Return updated pipeline struct
    executed_pipeline = %{
      pipeline
      | exit_code: final_exit_code,
        pipestatus: exit_codes,
        meta: AST.Meta.mark_evaluated(meta, started_at, completed_at)
    }

    if final_exit_code == 0 do
      {:ok, executed_pipeline}
    else
      {:error, executed_pipeline}
    end
  end

  # Segment commands into consecutive runs of external commands vs individual non-external
  defp segment_commands(commands, session_state) do
    commands
    |> Enum.reduce({[], nil}, fn cmd, {segments, current_run} ->
      is_external = external_command?(cmd, session_state)

      case {is_external, current_run} do
        {true, nil} ->
          # Start new external run
          {segments, [cmd]}

        {true, run} ->
          # Add to current external run
          {segments, run ++ [cmd]}

        {false, nil} ->
          # Non-external command, no current run
          {segments ++ [{:other, cmd}], nil}

        {false, run} ->
          # End external run, add non-external
          {segments ++ [{:external, run}, {:other, cmd}], nil}
      end
    end)
    |> then(fn {segments, current_run} ->
      # Finalize any remaining external run
      if current_run do
        segments ++ [{:external, current_run}]
      else
        segments
      end
    end)
  end

  # Execute a segment of external commands as a streaming pipeline
  defp execute_external_segment(commands, input, session_state) do
    # Build the streaming pipeline
    stream = build_stream_pipeline(Enum.reverse(commands), input, session_state)

    # Consume the stream
    {output_chunks, exit_info} = consume_stream(stream)

    output = IO.iodata_to_binary(output_chunks)

    exit_code =
      case exit_info do
        {:status, code} -> code
        :epipe -> 141
        _ -> 1
      end

    {output, exit_code}
  end

  # Execute a non-external command (builtin or function)
  # For pipeline stages, we capture output to a temporary collector instead of
  # writing to the session's collector.
  defp execute_non_external_command(cmd, input, session_state) do
    # For builtins that don't use stdin, we should drain the input without accumulating
    # For builtins that need stdin, we materialize it
    stdin_data =
      case input do
        nil ->
          nil

        data when is_binary(data) ->
          data

        stream ->
          # Check if this command uses stdin
          if command_uses_stdin?(cmd, session_state) do
            # Materialize the stream for commands that need it
            materialize_stream(stream)
          else
            # Drain without accumulating for commands that ignore stdin
            drain_stream(stream)
            nil
          end
      end

    # Create a temporary collector for this pipeline stage
    {:ok, temp_collector} = OutputCollector.start_link()
    temp_stdout_sink = Sink.collector(temp_collector)
    temp_stderr_sink = Sink.collector(temp_collector)

    # Replace session sinks with temporary ones
    pipeline_session = %{
      session_state
      | stdout_sink: temp_stdout_sink,
        stderr_sink: temp_stderr_sink
    }

    result =
      case Executor.execute(cmd, pipeline_session, stdin_data) do
        {:ok, result, state_updates} ->
          env_updates = Map.get(state_updates, :env_updates, %{})
          {result.exit_code || 0, env_updates}

        {:ok, result} ->
          {result.exit_code || 0, %{}}

        {:error, result, state_updates} ->
          env_updates = Map.get(state_updates, :env_updates, %{})
          {result.exit_code || 1, env_updates}

        {:error, result} ->
          {result.exit_code || 1, %{}}

        {:exit, result, state_updates} ->
          env_updates = Map.get(state_updates, :env_updates, %{})
          {result.exit_code || 0, env_updates}

        {:exit, result} ->
          {result.exit_code || 0, %{}}
      end

    # Extract output from the temporary collector
    {stdout_iodata, _stderr_iodata} = OutputCollector.flush_split(temp_collector)
    GenServer.stop(temp_collector, :normal)

    output = IO.iodata_to_binary(stdout_iodata)
    {exit_code, env_updates} = result

    {output, exit_code, env_updates}
  end

  # Check if a command uses stdin (builtins that read from stdin)
  defp command_uses_stdin?(%AST.Command{name: name}, session_state) do
    command_name = Helpers.word_to_string(name, session_state)
    # Builtins that actually read from stdin
    command_name in ["read", "mapfile", "readarray", "cat"]
  end

  # Assume other AST nodes may use stdin
  defp command_uses_stdin?(_, _), do: true

  # Materialize a stream into a binary string
  defp materialize_stream(stream) do
    stream
    |> Stream.filter(&is_binary/1)
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  # Drain a stream without accumulating (discard data)
  defp drain_stream(stream) do
    Stream.run(stream)
  end

  # Apply env updates to session state
  defp apply_env_updates(session_state, env_updates) when map_size(env_updates) == 0 do
    session_state
  end

  defp apply_env_updates(session_state, env_updates) do
    new_variables =
      Map.merge(
        session_state.variables,
        Map.new(env_updates, fn {k, v} -> {k, Variable.new(v)} end)
      )

    %{session_state | variables: new_variables}
  end

  # Sequential execution for all-builtin pipelines
  # Uses temporary collectors to capture output from each command
  defp execute_sequential(
         %__MODULE__{commands: commands, negate: negate, meta: meta} = pipeline,
         stdin,
         session_state,
         _opts
       ) do
    started_at = DateTime.utc_now()

    # Execute pipeline by piping stdout from each command to stdin of the next
    # Track all exit codes for pipestatus and pipefail support
    # Accumulator: {prev_stdout, status, env_updates, exit_codes}
    initial_acc = {"", :ok, %{}, []}

    {final_stdout, final_status, env_updates, pipestatus} =
      Enum.reduce(commands, initial_acc, fn
        cmd, {prev_stdout, :ok, acc_env, exit_codes} ->
          next_stdin = if prev_stdout == "", do: stdin, else: prev_stdout

          # Update session state with accumulated env updates
          updated_session = apply_env_updates(session_state, acc_env)

          # Execute with temporary collector
          {stdout, exit_code, cmd_env} =
            execute_with_temp_collector(cmd, next_stdin, updated_session)

          merged_env = Map.merge(acc_env, cmd_env)

          if exit_code == 0 do
            {stdout, :ok, merged_env, exit_codes ++ [exit_code]}
          else
            # Pipeline continues even if command fails
            {stdout, :ok, merged_env, exit_codes ++ [exit_code]}
          end

        cmd, {_prev_stdout, :error, acc_env, exit_codes} ->
          # If previous command errored, still try next (like bash pipelines)
          updated_session = apply_env_updates(session_state, acc_env)

          {stdout, exit_code, cmd_env} =
            execute_with_temp_collector(cmd, stdin, updated_session)

          merged_env = Map.merge(acc_env, cmd_env)

          if exit_code == 0 do
            {stdout, :ok, merged_env, exit_codes ++ [exit_code]}
          else
            {stdout, :error, merged_env, exit_codes ++ [exit_code]}
          end

        _cmd, {prev_stdout, :exit, acc_env, exit_codes} ->
          # errexit triggered - propagate without executing more commands
          {prev_stdout, :exit, acc_env, exit_codes}
      end)

    completed_at = DateTime.utc_now()

    # Check if pipefail is enabled
    pipefail_enabled = pipefail_enabled?(session_state)

    # Determine final exit code based on pipefail setting
    final_exit_code =
      case {pipefail_enabled, pipestatus} do
        {true, codes} when is_list(codes) and length(codes) > 0 ->
          # With pipefail: return rightmost non-zero exit code, or 0 if all succeeded
          Enum.reduce(codes, 0, fn code, acc ->
            if code != 0, do: code, else: acc
          end)

        _ ->
          # Without pipefail: use last command's exit code
          List.last(pipestatus) || 0
      end

    # Write final output to session's sink to maintain ordering with other commands
    # The sink writes to the session's OutputCollector which preserves order
    case Map.get(session_state, :stdout_sink) do
      sink when is_function(sink) and final_stdout != "" ->
        sink.({:stdout, final_stdout})

      _ ->
        :ok
    end

    # Apply negate if present
    final_exit_code =
      if negate do
        if final_exit_code == 0, do: 1, else: 0
      else
        final_exit_code
      end

    # Build the executed pipeline struct
    executed_pipeline = %{
      pipeline
      | exit_code: final_exit_code,
        pipestatus: pipestatus,
        meta: AST.Meta.mark_evaluated(meta, started_at, completed_at)
    }

    # Determine the return tuple based on the final result status
    case final_status do
      :exit ->
        {:exit, executed_pipeline}

      _ ->
        if final_exit_code == 0 do
          if map_size(env_updates) > 0 do
            {:ok, executed_pipeline, %{env_updates: env_updates}}
          else
            {:ok, executed_pipeline}
          end
        else
          {:error, executed_pipeline}
        end
    end
  end

  # Execute a command with a temporary collector and return {stdout_string, exit_code, env_updates}
  defp execute_with_temp_collector(cmd, stdin, session_state) do
    {:ok, temp_collector} = OutputCollector.start_link()
    temp_stdout_sink = Sink.collector(temp_collector)
    temp_stderr_sink = Sink.collector(temp_collector)

    pipeline_session = %{
      session_state
      | stdout_sink: temp_stdout_sink,
        stderr_sink: temp_stderr_sink
    }

    result =
      case Executor.execute(cmd, pipeline_session, stdin) do
        {:ok, result, state_updates} ->
          env_updates = Map.get(state_updates, :env_updates, %{})
          {result.exit_code || 0, env_updates}

        {:ok, result} ->
          {result.exit_code || 0, %{}}

        {:error, result, state_updates} ->
          env_updates = Map.get(state_updates, :env_updates, %{})
          {result.exit_code || 1, env_updates}

        {:error, result} ->
          {result.exit_code || 1, %{}}

        {:exit, result, state_updates} ->
          env_updates = Map.get(state_updates, :env_updates, %{})
          {result.exit_code || 0, env_updates}

        {:exit, result} ->
          {result.exit_code || 0, %{}}
      end

    {stdout_iodata, _stderr_iodata} = OutputCollector.flush_split(temp_collector)
    GenServer.stop(temp_collector, :normal)

    output = IO.iodata_to_binary(stdout_iodata)
    {exit_code, env_updates} = result

    {output, exit_code, env_updates}
  end

  defp pipefail_enabled?(session_state) do
    options = Map.get(session_state, :options, %{})
    Map.get(options, :pipefail, false) == true
  end

  # =============================================================================
  # External Command Detection
  # =============================================================================

  # Check if all commands in a pipeline are external commands (not builtins/functions).
  @doc false
  def all_external_commands?(commands, session_state) do
    Enum.all?(commands, &external_command?(&1, session_state))
  end

  # Check if a single command is external (not a builtin or function) and has no redirects.
  # Commands with redirects need sequential execution to handle the redirect logic.
  defp external_command?(%AST.Command{name: name, redirects: redirects}, session_state) do
    # Commands with redirects can't use simple streaming
    if redirects != [] do
      false
    else
      command_name = Helpers.word_to_string(name, session_state)

      # Check in order: functions, elixir interop, builtins
      not has_function?(command_name, session_state) and
        not has_elixir_interop?(command_name, session_state) and
        not Builtin.implemented?(command_name)
    end
  end

  # Non-Command AST nodes are not external commands
  defp external_command?(_ast, _session_state), do: false

  defp has_function?(command_name, session_state) do
    Map.has_key?(session_state.functions, command_name)
  end

  defp has_elixir_interop?(command_name, session_state) do
    case String.split(command_name, ".", parts: 2) do
      [namespace, _function_name] ->
        Map.has_key?(Map.get(session_state, :elixir_modules, %{}), namespace)

      _ ->
        false
    end
  end

  # =============================================================================
  # Streaming Pipeline Execution
  # =============================================================================

  # Execute a pipeline using ExCmd stream composition for memory-efficient streaming.
  # Only works for pure external command pipelines.
  #
  # Options:
  # - :sink - Output sink function for streaming. When provided, output streams
  # to the sink without accumulating in memory.
  @doc false
  def execute_streaming(
        %__MODULE__{commands: commands, negate: negate, meta: meta} = pipeline,
        stdin,
        session_state,
        opts \\ []
      ) do
    started_at = DateTime.utc_now()

    # Build the stream pipeline (commands flow right-to-left through nested streams)
    stream = build_stream_pipeline(Enum.reverse(commands), stdin, session_state)

    # Get sink from options or session's stdout_sink
    sink_opt = Keyword.get(opts, :sink) || Map.get(session_state, :stdout_sink)

    # Consume the stream, streaming to sink
    exit_info =
      if sink_opt do
        # Stream directly to sink without accumulating
        consume_stream_to_sink(stream, sink_opt)
      else
        # No sink available - consume and discard (shouldn't happen with proper setup)
        {_output_chunks, exit_info} = consume_stream(stream)
        exit_info
      end

    completed_at = DateTime.utc_now()

    # Extract exit code from the stream's exit info
    exit_code =
      case exit_info do
        {:status, code} -> code
        # SIGPIPE: 128 + 13
        :epipe -> 141
        _ -> 1
      end

    # Check pipefail - for streaming we only have the final exit code
    # TODO: Track individual exit codes for full pipestatus support
    pipefail_enabled = pipefail_enabled?(session_state)
    final_exit_code = if pipefail_enabled, do: exit_code, else: exit_code

    # Apply negate
    final_exit_code =
      if negate do
        if final_exit_code == 0, do: 1, else: 0
      else
        final_exit_code
      end

    # Return updated pipeline struct
    # For streaming, we replicate the final exit code for each command
    # since ExCmd only gives us the final exit status
    executed_pipeline = %{
      pipeline
      | exit_code: final_exit_code,
        pipestatus: List.duplicate(exit_code, length(commands)),
        meta: AST.Meta.mark_evaluated(meta, started_at, completed_at)
    }

    if final_exit_code == 0 do
      {:ok, executed_pipeline}
    else
      {:error, executed_pipeline}
    end
  end

  # Build nested ExCmd.stream calls from innermost (first command) to outermost (last command)
  defp build_stream_pipeline([cmd], stdin, session_state) do
    {name, args, env} = resolve_external_command(cmd, session_state)

    ExCmd.stream([name | args],
      input: stdin,
      cd: session_state.working_dir,
      env: env,
      stderr: :redirect_to_stdout
    )
  end

  defp build_stream_pipeline([cmd | rest], stdin, session_state) do
    # Build upstream first (inner stream)
    upstream = build_stream_pipeline(rest, stdin, session_state)

    # Filter out exit tuples - only pass binary data to downstream command
    # ExCmd.stream yields {:exit, exit_info} as last element which can't be used as input
    filtered_upstream =
      Stream.filter(upstream, fn
        {:exit, _} -> false
        data when is_binary(data) -> true
        _ -> false
      end)

    {name, args, env} = resolve_external_command(cmd, session_state)

    ExCmd.stream([name | args],
      input: filtered_upstream,
      cd: session_state.working_dir,
      env: env,
      stderr: :redirect_to_stdout
    )
  end

  # Resolve command name, args, and environment from AST
  defp resolve_external_command(%AST.Command{name: name, args: args}, session_state) do
    command_name = Helpers.word_to_string(name, session_state)
    {expanded_args, _env_updates} = Helpers.expand_word_list(args, session_state)

    env =
      session_state.variables
      |> Enum.filter(fn {_k, v} -> Variable.get(v, nil) != nil end)
      |> Enum.map(fn {k, v} -> {k, Variable.get(v, nil)} end)

    {command_name, expanded_args, env}
  end

  # Consume the stream, separating output chunks from the exit info (accumulates)
  defp consume_stream(stream) do
    Enum.reduce(stream, {[], nil}, fn
      {:exit, exit_info}, {chunks, _} ->
        {Enum.reverse(chunks), exit_info}

      chunk, {chunks, exit_info} when is_binary(chunk) ->
        {[chunk | chunks], exit_info}

      _other, acc ->
        acc
    end)
  end

  # Consume stream by sending chunks to sink without accumulating
  defp consume_stream_to_sink(stream, sink) do
    Enum.reduce(stream, nil, fn
      {:exit, exit_info}, _acc ->
        exit_info

      chunk, acc when is_binary(chunk) ->
        sink.({:stdout, chunk})
        acc

      _other, acc ->
        acc
    end)
  end

  defimpl String.Chars do
    def to_string(%{commands: commands, negate: negate}) do
      commands_str = Enum.map_join(commands, " | ", &Kernel.to_string/1)

      if negate do
        "! #{commands_str}"
      else
        commands_str
      end
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{commands: commands, negate: negate, exit_code: exit_code}, opts) do
      cmd_count = length(commands)
      prefix = if negate, do: "!", else: ""
      base = concat(["#Pipeline{", prefix, color("#{cmd_count}", :number, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
