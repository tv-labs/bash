defmodule Bash.Builtin.Exec do
  @moduledoc """
  `exec [-cl] [-a name] [command [argument ...]]`

  Replace the shell with the given command. If command is not specified, any
  redirections take effect in the current shell.

  In our interpreter context, exec executes the command and signals that the
  shell should exit with that command's exit code.

  Options:
  - `-c` - Execute command with an empty environment
  - `-l` - Place a dash at the beginning of the zeroth argument (login shell)
  - `-a name` - Pass name as the zeroth argument to the command

  Exit Status:
  Returns success unless command is not found or cannot be executed.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
  """
  use Bash.Builtin

  alias Bash.CommandPort
  alias Bash.Variable

  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, _opts, []} ->
        # No command - exec with only redirections
        # In real bash, this would apply redirections to current shell
        # For now, we just succeed without doing anything
        :ok

      {:ok, opts, [command | command_args]} ->
        execute_command(command, command_args, opts, state)

      {:error, message} ->
        error("exec: #{message}")
        {:ok, 2}
    end
  end

  # Parse exec options
  # Returns {:ok, opts, remaining_args} or {:error, message}
  defp parse_args(args) do
    parse_args(args, %{clear_env: false, login_shell: false, argv0: nil})
  end

  defp parse_args([], opts) do
    {:ok, opts, []}
  end

  defp parse_args(["--" | rest], opts) do
    # End of options
    {:ok, opts, rest}
  end

  defp parse_args(["-c" | rest], opts) do
    parse_args(rest, %{opts | clear_env: true})
  end

  defp parse_args(["-l" | rest], opts) do
    parse_args(rest, %{opts | login_shell: true})
  end

  defp parse_args(["-a", name | rest], opts) when is_binary(name) do
    parse_args(rest, %{opts | argv0: name})
  end

  defp parse_args(["-a"], _opts) do
    {:error, "-a: option requires an argument"}
  end

  # Combined short options like -cl (must not start with another dash)
  defp parse_args([<<"-", first_char, rest_flags::binary>> | rest], opts)
       when byte_size(rest_flags) >= 1 and first_char != ?- do
    flags = <<first_char, rest_flags::binary>>

    case parse_combined_flags(flags) do
      {:ok, new_opts} ->
        merged_opts = Map.merge(opts, new_opts)
        parse_args(rest, merged_opts)

      {:error, _} = err ->
        err
    end
  end

  defp parse_args([<<"-", char::binary-size(1)>> | _rest], _opts)
       when char not in ["c", "l", "a"] do
    {:error, "-#{char}: invalid option"}
  end

  defp parse_args(args, opts) do
    # No more options, rest are command and arguments
    {:ok, opts, args}
  end

  # Parse combined flags like -cl
  defp parse_combined_flags(flags) do
    flags
    |> String.graphemes()
    |> Enum.reduce_while({:ok, %{}}, fn char, {:ok, acc} ->
      case char do
        "c" -> {:cont, {:ok, Map.put(acc, :clear_env, true)}}
        "l" -> {:cont, {:ok, Map.put(acc, :login_shell, true)}}
        _ -> {:halt, {:error, "-#{char}: invalid option"}}
      end
    end)
  end

  # Execute the command with the given options
  defp execute_command(command, args, opts, session_state) do
    # Build environment
    env =
      if opts.clear_env do
        []
      else
        Map.new(session_state.variables, fn {k, v} ->
          {k, Variable.get(v, nil)}
        end)
        |> Map.to_list()
      end

    # Modify argv[0] if login shell or custom argv0
    {actual_command, display_args} =
      cond do
        opts.argv0 != nil ->
          # Custom argv[0] - for display purposes
          {command, [opts.argv0 | args]}

        opts.login_shell ->
          # Login shell - prepend dash to command name for display
          base_name = Path.basename(command)
          {command, ["-#{base_name}" | args]}

        true ->
          {command, args}
      end

    # Get stdin from state if available (passed via defbash wrapper)
    stdin_data = Map.get(session_state, :stdin)

    exec_opts = [
      cd: session_state.working_dir,
      env: env,
      stdin: stdin_data,
      timeout: :infinity
    ]

    # Execute the command
    case CommandPort.execute(actual_command, args, exec_opts) do
      {:ok, result} ->
        # Command succeeded - signal shell exit with this result
        {:exec, %{result | command: format_command(command, display_args)}}

      {:error, result} ->
        # Command failed - still signal shell exit with this result
        # The exit code comes from the command itself
        {:exec, %{result | command: format_command(command, display_args)}}
    end
  end

  # Format the command for display
  defp format_command(command, args) do
    Enum.join([command | args], " ")
  end
end
