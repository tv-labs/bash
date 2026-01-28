defmodule Bash.AST.Command do
  @moduledoc """
  Simple command: name with arguments and optional redirections.

  ## Examples

      # echo hello world
      %Command{
        name: %Word{parts: [{:literal, "echo"}]},
        args: [
          %Word{parts: [{:literal, "hello"}]},
          %Word{parts: [{:literal, "world"}]}
        ]
      }

      # VAR=value command arg
      %Command{
        name: %Word{parts: [{:literal, "command"}]},
        args: [%Word{parts: [{:literal, "arg"}]}],
        env_assignments: [{"VAR", %Word{parts: [{:literal, "value"}]}}]
      }

      # command < input.txt > output.txt
      %Command{
        name: %Word{parts: [{:literal, "command"}]},
        redirects: [
          %Redirect{direction: :input, target: "input.txt"},
          %Redirect{direction: :output, target: "output.txt"}
        ]
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.Builtin
  alias Bash.CommandPort
  alias Bash.CommandResult
  alias Bash.Function
  alias Bash.Sink
  alias Bash.Telemetry
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: AST.Word.t(),
          args: [AST.Word.t()],
          redirects: [AST.Redirect.t()],
          env_assignments: [{String.t(), AST.Word.t()}],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :name,
    args: [],
    redirects: [],
    env_assignments: [],
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  def execute(
        %__MODULE__{name: name, args: args, redirects: redirects} = ast,
        stdin,
        session_state
      ) do
    try do
      do_execute(ast, name, args, redirects, stdin, session_state)
    rescue
      e in RuntimeError ->
        # Handle nounset errors (unbound variable)
        if String.contains?(e.message, "unbound variable") do
          result = %CommandResult{
            command: "expansion",
            exit_code: 1,
            error: :unbound_variable
          }

          started_at = DateTime.utc_now()
          completed_at = DateTime.utc_now()
          executed_ast = populate_execution_result(ast, result, started_at, completed_at)
          {:exit, executed_ast}
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp do_execute(
         %__MODULE__{redirects: redirects, env_assignments: env_assignments} = ast,
         name,
         args,
         redirects,
         stdin,
         session_state
       ) do
    # Execute DEBUG trap before each simple command (if set)
    execute_debug_trap(session_state)

    command_name = Helpers.word_to_string(name, session_state)
    {expanded_args, env_updates} = Helpers.expand_word_list(args, session_state)
    effective_stdin = process_input_redirects(redirects, session_state, stdin)

    # Apply prefix env assignments (e.g., "IFS=: read -a parts")
    # These are temporary and only affect this command's execution
    session_with_prefix_env = apply_prefix_assignments(env_assignments, session_state)

    # Write verbose/xtrace output to stderr sink (before command execution)
    write_trace_output(ast, command_name, expanded_args, session_with_prefix_env)

    started_at = DateTime.utc_now()

    result =
      if command_name == "exec" and expanded_args == [] do
        apply_exec_fd_redirects(redirects, session_with_prefix_env)
      else
        Telemetry.command_span(command_name, expanded_args, fn ->
          # Set up hierarchical sinks for output redirects BEFORE execution.
          # This allows output to flow directly to files without post-processing.
          {exec_session, cleanup_fn, redirect_error} =
            setup_output_redirect_sinks(redirects, session_with_prefix_env)

          exec_result =
            if redirect_error do
              # Redirect error - write error to stderr and return error result
              Sink.write_stderr(session_state, redirect_error)

              {:error,
               %CommandResult{
                 command: command_name,
                 exit_code: 1,
                 error: :redirect_error
               }}
            else
              resolve_and_execute(
                command_name,
                expanded_args,
                exec_session,
                effective_stdin,
                redirects,
                ast.meta
              )
            end

          # Close file handles from redirect sinks
          cleanup_fn.()

          exit_code = get_exit_code(exec_result)
          {exec_result, %{exit_code: exit_code}}
        end)
      end

    completed_at = DateTime.utc_now()

    handle_execution_result(result, ast, started_at, completed_at, env_updates)
  end

  defp apply_exec_fd_redirects(redirects, session_state) do
    result =
      Enum.reduce_while(redirects, {:ok, session_state}, fn redirect, {:ok, state} ->
        case redirect do
          %AST.Redirect{direction: dir, fd: fd, target: {:file, file_word}}
          when fd >= 3 and dir in [:output, :append, :input] ->
            path = resolve_redirect_path(file_word, state)

            modes =
              case dir do
                :output -> [:write]
                :append -> [:write, :append]
                :input -> [:read]
              end

            case Bash.Session.open_fd(state, fd, path, modes) do
              {:ok, new_state} -> {:cont, {:ok, new_state}}
              {:error, reason} -> {:halt, {:error, path, reason}}
            end

          %AST.Redirect{direction: :close, fd: fd} ->
            {:cont, {:ok, Bash.Session.close_fd(state, fd)}}

          _ ->
            {:cont, {:ok, state}}
        end
      end)

    case result do
      {:ok, new_state} ->
        {:ok, %CommandResult{command: "exec", exit_code: 0},
         %{file_descriptors: new_state.file_descriptors}}

      {:error, path, reason} ->
        message = :file.format_error(reason) |> to_string() |> String.capitalize()
        Sink.write_stderr(session_state, "bash: #{path}: #{message}\n")
        {:error, %CommandResult{command: "exec", exit_code: 1, error: reason}}
    end
  end

  defp get_exit_code({:ok, %{exit_code: code}}), do: code
  defp get_exit_code({:error, %{exit_code: code}}), do: code
  defp get_exit_code(_), do: nil

  defp handle_execution_result(result, ast, started_at, completed_at, env_updates) do
    case result do
      {:wait_for_jobs, _} = r ->
        r

      {:foreground_job, _} = r ->
        r

      {:background_job, _} = r ->
        r

      {:signal_jobs, _, _} = r ->
        r

      {:background, _, _} = r ->
        r

      # Control flow with AST wrapping
      {control, command_result, levels} when control in [:break, :continue] ->
        {control, wrap_result(ast, command_result, started_at, completed_at), levels}

      {control, command_result} when control in [:exit, :exec] ->
        {control, wrap_result(ast, command_result, started_at, completed_at)}

      # Standard ok/error tuples
      {status, command_result, state_updates} when status in [:ok, :error] ->
        executed_ast = wrap_result(ast, command_result, started_at, completed_at)
        {status, executed_ast, merge_env_updates(state_updates, env_updates)}

      {status, command_result} when status in [:ok, :error] ->
        executed_ast = wrap_result(ast, command_result, started_at, completed_at)
        maybe_add_env_updates({status, executed_ast}, env_updates)
    end
  end

  defp wrap_result(ast, result, started_at, completed_at) do
    populate_execution_result(ast, result, started_at, completed_at)
  end

  defp maybe_add_env_updates(result, env_updates) when map_size(env_updates) > 0 do
    {status, ast} = result
    {status, ast, %{env_updates: env_updates}}
  end

  defp maybe_add_env_updates(result, _), do: result

  defp populate_execution_result(
         ast,
         %Bash.CommandResult{} = result,
         started_at,
         completed_at
       ) do
    %{
      ast
      | exit_code: result.exit_code,
        meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
    }
  end

  defp populate_execution_result(
         ast,
         %{exit_code: _} = result,
         started_at,
         completed_at
       ) do
    %{
      ast
      | exit_code: result.exit_code,
        meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
    }
  end

  defp merge_env_updates(state_updates, env_updates) when map_size(env_updates) > 0 do
    merged_env = Map.merge(env_updates, Map.get(state_updates, :env_updates, %{}))
    Map.put(state_updates, :env_updates, merged_env)
  end

  defp merge_env_updates(state_updates, _env_updates), do: state_updates

  defp process_input_redirects(redirects, _session_state, default_stdin)
       when redirects in [nil, []], do: default_stdin

  defp process_input_redirects(redirects, session_state, default_stdin) do
    redirects
    |> Enum.filter(
      &match?(%AST.Redirect{direction: dir} when dir in [:input, :heredoc, :herestring], &1)
    )
    |> List.last()
    |> read_input_redirect(session_state, default_stdin)
  end

  # Hierarchical sink setup: creates file sinks for output redirects BEFORE execution.
  # This allows output to flow directly to files without post-processing.
  # Returns {modified_session_state, cleanup_fn, error} where cleanup_fn closes file handles.
  defp setup_output_redirect_sinks(redirects, session_state)
       when redirects in [nil, []] do
    {session_state, fn -> :ok end, nil}
  end

  defp setup_output_redirect_sinks(redirects, session_state) do
    # Filter to output redirects only (file outputs and FD duplications)
    output_redirects =
      Enum.filter(redirects, fn
        %AST.Redirect{direction: dir} when dir in [:output, :append, :duplicate] -> true
        _ -> false
      end)

    if output_redirects == [] do
      {session_state, fn -> :ok end, nil}
    else
      do_setup_output_redirect_sinks(output_redirects, session_state)
    end
  end

  defp do_setup_output_redirect_sinks(output_redirects, session_state) do
    noclobber = noclobber_enabled?(session_state)

    # Split redirects into file redirects and duplications
    # Process file redirects first, then duplications, so duplications
    # point to the final destinations.
    # For ">&2 2> file", we want: stderr→file first, then stdout→stderr (which is file)
    {file_redirects, dup_redirects} =
      Enum.split_with(output_redirects, fn
        %AST.Redirect{direction: :duplicate} -> false
        _ -> true
      end)

    initial_state = %{
      stdout_sink: session_state.stdout_sink,
      stderr_sink: session_state.stderr_sink,
      file_handles: [],
      error: nil
    }

    # Process file redirects first
    state_after_files =
      Enum.reduce_while(file_redirects, initial_state, fn redirect, acc ->
        case apply_redirect_to_sinks(redirect, acc, session_state, noclobber) do
          {:ok, new_acc} -> {:cont, new_acc}
          {:error, error, new_acc} -> {:halt, %{new_acc | error: error}}
        end
      end)

    # Then process duplications (they'll point to the final file destinations)
    final_state =
      if state_after_files.error do
        state_after_files
      else
        Enum.reduce_while(dup_redirects, state_after_files, fn redirect, acc ->
          case apply_redirect_to_sinks(redirect, acc, session_state, noclobber) do
            {:ok, new_acc} -> {:cont, new_acc}
            {:error, error, new_acc} -> {:halt, %{new_acc | error: error}}
          end
        end)
      end

    # Build modified session state
    exec_session = %{
      session_state
      | stdout_sink: final_state.stdout_sink,
        stderr_sink: final_state.stderr_sink
    }

    # Cleanup function closes all file handles
    cleanup_fn = fn ->
      Enum.each(final_state.file_handles, fn close_fn -> close_fn.() end)
    end

    {exec_session, cleanup_fn, final_state.error}
  end

  # FD duplication: 2>&1 or 1>&2
  # When duplicating FDs, we need to re-tag the output so the collector
  # stores it under the correct stream.
  defp apply_redirect_to_sinks(
         %AST.Redirect{direction: :duplicate, fd: from_fd, target: {:fd, to_fd}},
         state,
         session_state,
         _noclobber
       ) do
    duplicate_fd_sink(from_fd, to_fd, state, session_state)
  end

  # FD duplication with variable target: >&${FD_VAR}
  # When the target is a word (variable), expand it and try to get the FD number
  defp apply_redirect_to_sinks(
         %AST.Redirect{direction: :duplicate, fd: from_fd, target: {:file, file_word}},
         state,
         session_state,
         _noclobber
       ) do
    target_str = resolve_redirect_path(file_word, session_state)

    case Integer.parse(target_str) do
      {to_fd, ""} when to_fd >= 0 ->
        duplicate_fd_sink(from_fd, to_fd, state, session_state)

      _ ->
        {:ok, state}
    end
  end

  # File redirect: > file, >> file, 2> file, &> file, etc.
  defp apply_redirect_to_sinks(
         %AST.Redirect{direction: dir, fd: fd, target: {:file, file_word}},
         state,
         session_state,
         noclobber
       )
       when dir in [:output, :append] do
    file_path = resolve_redirect_path(file_word, session_state)
    append = dir == :append

    # Check noclobber (set -C): cannot overwrite existing file with >
    if noclobber && !append && File.exists?(file_path) do
      error_msg = "bash: #{file_path}: cannot overwrite existing file\n"
      {:error, error_msg, state}
    else
      create_file_sink_for_redirect(file_path, append, fd, state)
    end
  end

  defp create_file_sink_for_redirect(file_path, append, fd, state) do
    # Ensure parent directory exists
    file_path |> Path.dirname() |> File.mkdir_p()

    # Set stream_type based on which fd this sink is for
    # This matters when FD duplication re-tags chunks (e.g., 1>&2 sends :stderr to this sink)
    stream_type =
      case fd do
        :both -> :both
        2 -> :stderr
        _ -> :stdout
      end

    {sink, close_fn} = Sink.file(file_path, append: append, stream_type: stream_type)

    new_state =
      case fd do
        :both ->
          # &> file - both stdout and stderr go to file
          %{
            state
            | stdout_sink: sink,
              stderr_sink: sink,
              file_handles: [close_fn | state.file_handles]
          }

        2 ->
          # 2> file - stderr goes to file
          %{state | stderr_sink: sink, file_handles: [close_fn | state.file_handles]}

        _ ->
          # > file or 1> file - stdout goes to file
          %{state | stdout_sink: sink, file_handles: [close_fn | state.file_handles]}
      end

    {:ok, new_state}
  end

  defp duplicate_fd_sink(from_fd, to_fd, state, session_state) do
    case {from_fd, to_fd} do
      # 2>&1 - stderr goes where stdout goes (re-tag :stderr as :stdout)
      {2, 1} ->
        {:ok, %{state | stderr_sink: retag_sink(state.stdout_sink, :stderr, :stdout)}}

      # 1>&2 - stdout goes where stderr goes (re-tag :stdout as :stderr)
      {1, 2} ->
        {:ok, %{state | stdout_sink: retag_sink(state.stderr_sink, :stdout, :stderr)}}

      # Duplicate from_fd to a higher fd (e.g., 1>&3)
      {from_fd, to_fd} when to_fd >= 3 ->
        case Map.get(session_state.file_descriptors, to_fd) do
          nil ->
            {:error, "bash: #{to_fd}: Bad file descriptor\n", state}

          device when is_pid(device) ->
            fd_sink = fn {_stream, data} when is_binary(data) ->
              IO.binwrite(device, data)
              :ok
            end

            new_state =
              case from_fd do
                1 -> %{state | stdout_sink: fd_sink}
                2 -> %{state | stderr_sink: fd_sink}
                _ -> state
              end

            {:ok, new_state}
        end

      _ ->
        {:ok, state}
    end
  end

  # Create a sink that re-tags chunks from one stream to another
  defp retag_sink(target_sink, from_stream, to_stream) do
    fn
      {^from_stream, data} -> target_sink.({to_stream, data})
      other -> target_sink.(other)
    end
  end

  defp read_input_redirect(nil, _session_state, default_stdin), do: default_stdin

  defp read_input_redirect(
         %AST.Redirect{direction: :input, target: {:file, file_word}},
         session_state,
         default_stdin
       ) do
    file_word
    |> resolve_redirect_path(session_state)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _} -> default_stdin
    end
  end

  defp read_input_redirect(
         %AST.Redirect{direction: :heredoc, target: {:heredoc, word, _, _}},
         session_state,
         _default
       ) do
    Helpers.word_to_string(word, session_state)
  end

  defp read_input_redirect(
         %AST.Redirect{direction: :herestring, target: {:word, word}},
         session_state,
         _default
       ) do
    Helpers.word_to_string(word, session_state) <> "\n"
  end

  defp noclobber_enabled?(session_state) do
    session_state
    |> Map.get(:options, %{})
    |> Map.get(:noclobber, false)
  end

  # Apply prefix environment assignments (e.g., "IFS=: read -a parts")
  # These temporarily modify the session state for this command only
  defp apply_prefix_assignments(nil, session_state), do: session_state
  defp apply_prefix_assignments([], session_state), do: session_state

  defp apply_prefix_assignments(assignments, session_state) do
    updated_vars =
      Enum.reduce(assignments, session_state.variables, fn {var_name, value_word}, vars ->
        value = Helpers.word_to_string(value_word, session_state)
        Map.put(vars, var_name, Variable.new(value))
      end)

    %{session_state | variables: updated_vars}
  end

  defp resolve_redirect_path(file_word, session_state) do
    file_word
    |> Helpers.word_to_string(session_state)
    |> expand_relative_path(session_state.working_dir)
  end

  defp expand_relative_path(path, working_dir) do
    if Path.type(path) == :relative, do: Path.join(working_dir, path), else: path
  end

  # Dispatch order: functions -> elixir interop -> builtins -> external
  defp resolve_and_execute(command_name, args, session_state, stdin, redirects, meta) do
    with nil <- try_bash_function(command_name, args, session_state, meta),
         nil <- try_elixir_interop(command_name, args, stdin, session_state),
         nil <- try_builtin(command_name, args, stdin, session_state) do
      execute_external_command(command_name, args, session_state, stdin, redirects)
    end
  end

  defp try_bash_function(command_name, args, session_state, meta) do
    case Map.get(session_state.functions, command_name) do
      %Function{} = func ->
        caller_line = if meta, do: meta.line, else: 0
        Function.call(func, args, session_state, caller_line: caller_line)

      nil ->
        nil
    end
  end

  defp try_elixir_interop(command_name, args, stdin, session_state) do
    case resolve_elixir_function(command_name, session_state) do
      {:ok, module, function_name} ->
        call_elixir_function(module, function_name, args, stdin, session_state)

      :not_found ->
        nil
    end
  end

  defp try_builtin(command_name, args, stdin, session_state) do
    case Builtin.get_module(command_name) do
      nil -> nil
      module when not is_nil(module) -> module.execute(args, stdin, session_state)
    end
  end

  defp resolve_elixir_function(command_name, session_state) do
    case String.split(command_name, ".", parts: 2) do
      [namespace, function_name] ->
        session_state.elixir_modules
        |> Map.get(namespace)
        |> case do
          nil -> :not_found
          module -> {:ok, module, function_name}
        end

      _ ->
        :not_found
    end
  end

  defp call_elixir_function(module, function_name, args, stdin, session_state) do
    alias Bash.Interop.Result

    stdin_stream = normalize_stdin_stream(stdin)
    command_name = "#{module.__bash_namespace__()}.#{function_name}"
    raw_result = module.__bash_call__(function_name, args, stdin_stream, session_state)

    # Handle control flow before normalization
    case raw_result do
      control when control in [:continue, :break] ->
        {control, %CommandResult{command: command_name, exit_code: 0, error: nil}, 1}

      _ ->
        normalized = Result.normalize(raw_result, session_state)

        # Stream output to sinks if available
        stream_output_to_sinks(normalized.stdout, normalized.stderr, session_state)

        command_result = %CommandResult{
          command: command_name,
          exit_code: normalized.exit_code,
          error: nil
        }

        if normalized.state != session_state do
          {:ok, command_result, %{var_updates: normalized.state.variables}}
        else
          {:ok, command_result}
        end
    end
  end

  defp normalize_stdin_stream(nil), do: nil
  defp normalize_stdin_stream(""), do: nil
  defp normalize_stdin_stream(binary) when is_binary(binary), do: [binary]
  defp normalize_stdin_stream(stream), do: stream

  defp build_output("", ""), do: []
  defp build_output(stdout, ""), do: [{:stdout, [stdout]}]
  defp build_output("", stderr), do: [{:stderr, [stderr]}]
  defp build_output(stdout, stderr), do: [{:stdout, [stdout]}, {:stderr, [stderr]}]

  # Stream output to sinks if available, otherwise return output list for CommandResult
  defp stream_output_to_sinks(stdout, stderr, session_state) do
    stdout_sink = Map.get(session_state, :stdout_sink)
    stderr_sink = Map.get(session_state, :stderr_sink)

    cond do
      stdout_sink && stderr_sink ->
        if stdout != "", do: stdout_sink.({:stdout, stdout})
        if stderr != "", do: stderr_sink.({:stderr, stderr})
        []

      true ->
        build_output(stdout, stderr)
    end
  end

  defp execute_external_command(command_name, args, session_state, stdin, redirects) do
    env =
      session_state.variables
      |> Map.new(fn {k, v} -> {k, Variable.get(v, nil)} end)
      |> Map.to_list()

    stderr_file_redirects = get_stderr_file_redirects(redirects, session_state)

    # Create a combined sink that routes stdout/stderr to the session's sinks
    # This ensures external command output is interleaved correctly with builtin output
    combined_sink = build_combined_sink(session_state)

    base_opts = [cd: session_state.working_dir, env: env, stdin: stdin, timeout: 5000]
    opts = if combined_sink, do: [{:sink, combined_sink} | base_opts], else: base_opts

    # Resolve command through hash table or PATH
    {resolved_command, hash_updates} = resolve_command_path(command_name, session_state)

    result =
      case stderr_file_redirects do
        [] ->
          CommandPort.execute(resolved_command, args, opts)

        _ ->
          execute_with_os_redirects(
            resolved_command,
            args,
            session_state,
            stdin,
            env,
            stderr_file_redirects
          )
      end

    # Attach hash updates to the result if any
    maybe_add_hash_updates(result, hash_updates)
  end

  # Resolves a command name to its full path using hash table or PATH search.
  # Returns {resolved_command, hash_updates} where hash_updates is nil or a map.
  defp resolve_command_path(command_name, session_state) do
    # Commands with slashes are paths, not looked up
    if String.contains?(command_name, "/") do
      {command_name, nil}
    else
      resolve_via_hash_or_path(command_name, session_state)
    end
  end

  defp resolve_via_hash_or_path(command_name, session_state) do
    hash_table = Map.get(session_state, :hash, %{})
    options = Map.get(session_state, :options, %{})
    hashall_enabled = Map.get(options, :hashall, true)

    case Map.get(hash_table, command_name) do
      {hit_count, cached_path} ->
        # Found in hash table - verify path still exists
        if File.exists?(cached_path) and not File.dir?(cached_path) do
          # Path valid - increment hit count and use cached path
          {cached_path, %{hash_updates: %{command_name => {hit_count + 1, cached_path}}}}
        else
          # Path stale - remove from hash and search PATH
          resolve_from_path_with_stale_removal(command_name, session_state, hashall_enabled)
        end

      nil ->
        # Not in hash table - search PATH
        resolve_from_path(command_name, session_state, hashall_enabled)
    end
  end

  defp resolve_from_path_with_stale_removal(command_name, session_state, hashall_enabled) do
    case find_command_in_path(command_name, session_state) do
      nil ->
        # Not found - delete stale entry
        {command_name, %{hash_updates: %{command_name => :delete}}}

      found_path ->
        # Found - update hash with new path (replacing stale entry)
        if hashall_enabled do
          {found_path, %{hash_updates: %{command_name => {0, found_path}}}}
        else
          {found_path, %{hash_updates: %{command_name => :delete}}}
        end
    end
  end

  defp resolve_from_path(command_name, session_state, hashall_enabled) do
    case find_command_in_path(command_name, session_state) do
      nil ->
        # Not found in PATH - let CommandPort handle the error
        {command_name, nil}

      found_path ->
        # Found - cache if hashall enabled
        if hashall_enabled do
          {found_path, %{hash_updates: %{command_name => {0, found_path}}}}
        else
          {found_path, nil}
        end
    end
  end

  defp find_command_in_path(command_name, session_state) do
    path_var = Map.get(session_state.variables, "PATH", Variable.new("/usr/bin:/bin"))
    path_dirs = path_var |> Variable.get(nil) |> String.split(":")

    Enum.find_value(path_dirs, fn dir ->
      full_path = Path.join(dir, command_name)

      if File.exists?(full_path) and not File.dir?(full_path) do
        full_path
      end
    end)
  end

  defp maybe_add_hash_updates(result, nil), do: result

  defp maybe_add_hash_updates({status, command_result}, hash_updates) do
    {status, command_result, hash_updates}
  end

  defp get_stderr_file_redirects(redirects, _session_state) when redirects in [nil, []], do: []

  defp get_stderr_file_redirects(redirects, session_state) do
    redirects
    |> Enum.filter(
      &match?(
        %AST.Redirect{direction: dir, fd: 2, target: {:file, _}} when dir in [:output, :append],
        &1
      )
    )
    |> Enum.map(fn %AST.Redirect{direction: direction, target: {:file, file_word}} ->
      {direction, resolve_redirect_path(file_word, session_state)}
    end)
  end

  defp execute_with_os_redirects(command_name, args, session_state, stdin, env, stderr_redirects) do
    {direction, file_path} = List.last(stderr_redirects)
    redirect_op = if direction == :append, do: ">>", else: ">"

    full_cmd =
      [command_name | args]
      |> Enum.map_join(" ", &shell_escape/1)
      |> Kernel.<>(" 2#{redirect_op} #{shell_escape(file_path)}")

    # Create a combined sink that routes stdout/stderr to the session's sinks
    combined_sink = build_combined_sink(session_state)

    base_opts = [cd: session_state.working_dir, env: env, stdin: stdin, timeout: 5000]
    opts = if combined_sink, do: [{:sink, combined_sink} | base_opts], else: base_opts

    CommandPort.execute("bash", ["-c", full_cmd], opts)
    |> mark_stderr_redirects_handled(stderr_redirects)
  end

  defp mark_stderr_redirects_handled({status, result}, stderr_redirects) do
    paths = Enum.map(stderr_redirects, fn {_dir, path} -> path end)
    {status, Map.put(result, :os_handled_stderr_redirects, paths)}
  end

  defp shell_escape(str) do
    str
    |> String.replace("'", "'\\''")
    |> then(&"'#{&1}'")
  end

  # Write verbose/xtrace trace output to stderr sink
  defp write_trace_output(ast, command_name, args, session_state) do
    options = Map.get(session_state, :options, %{})
    stderr_sink = Map.get(session_state, :stderr_sink)

    # Only write if we have a stderr sink
    if stderr_sink do
      # Verbose mode: print the command as read
      if Map.get(options, :verbose, false) do
        stderr_sink.({:stderr, "#{to_string(ast)}\n"})
      end

      # Xtrace mode: print expanded command with + prefix
      if Map.get(options, :xtrace, false) do
        stderr_sink.({:stderr, "+ #{Enum.join([command_name | args], " ")}\n"})
      end
    end

    :ok
  end

  # Build a combined sink for routing stdout/stderr to session sinks
  # Returns nil if sinks are not available (for backward compatibility with tests)
  defp build_combined_sink(session_state) do
    stdout_sink = Map.get(session_state, :stdout_sink)
    stderr_sink = Map.get(session_state, :stderr_sink)

    if stdout_sink && stderr_sink do
      fn
        {:stdout, data} -> stdout_sink.({:stdout, data})
        {:stderr, data} -> stderr_sink.({:stderr, data})
      end
    else
      nil
    end
  end

  # Execute DEBUG trap if one is set
  # The DEBUG trap runs before each simple command
  defp execute_debug_trap(session_state) do
    # Skip if already executing a trap (prevent infinite recursion)
    if Map.get(session_state, :in_trap, false) do
      :ok
    else
      traps = Map.get(session_state, :traps, %{})

      case Map.get(traps, "DEBUG") do
        nil ->
          :ok

        :ignore ->
          :ok

        trap_command when is_binary(trap_command) ->
          # Parse and execute the trap command
          case Bash.Parser.parse(trap_command) do
            {:ok, ast} ->
              # Execute trap with in_trap flag to prevent recursion
              trap_session = Map.put(session_state, :in_trap, true)
              Helpers.execute_body(ast.statements, trap_session, %{})

            {:error, _, _, _} ->
              :ok
          end
      end
    end
  end

  defimpl String.Chars do
    def to_string(%{
          name: name,
          args: args,
          redirects: redirects,
          env_assignments: env_assignments
        }) do
      # Format env assignments as VAR=value prefixes
      env_str =
        case env_assignments do
          nil ->
            []

          [] ->
            []

          assignments ->
            Enum.map(assignments, fn {var, value} ->
              "#{var}=#{Kernel.to_string(value)}"
            end)
        end

      redirects_str =
        if redirects in [nil, []], do: [], else: Enum.map(redirects, &Kernel.to_string/1)

      (env_str ++ [Kernel.to_string(name) | Enum.map(args, &Kernel.to_string/1)])
      |> Kernel.++(redirects_str)
      |> Enum.join(" ")
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{name: name, exit_code: exit_code}, opts) do
      name_str = Kernel.to_string(name)
      base = concat(["#Command{", color(name_str, :atom, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
