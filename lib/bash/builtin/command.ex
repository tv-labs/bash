defmodule Bash.Builtin.Command do
  @moduledoc """
  `command [-pVv] command [arg ...]`

  Run COMMAND with ARGS ignoring shell functions.

  If the -p option is given, the search for COMMAND is performed using a
  default value for PATH that is guaranteed to find all the standard utilities.

  If the -V or -v option is given, a description of COMMAND is printed.
  The -v option outputs a single word; -V outputs a more verbose description.

  Exit Status:
  Returns exit status of COMMAND, or failure if COMMAND is not found.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/command.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Builtin
  alias Bash.Variable

  # Standard utilities path that is guaranteed to find all standard utilities
  @default_path "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  defbash execute(args, state) do
    case args do
      [] ->
        # No command given - just return success (like bash)
        :ok

      _ ->
        {opts, command_args} = parse_args(args)

        cond do
          Enum.empty?(command_args) ->
            # No command given after flags
            :ok

          opts.verbose_describe ->
            # -V: verbose description
            describe_command(hd(command_args), state, :verbose, opts)

          opts.simple_describe ->
            # -v: simple description
            describe_command(hd(command_args), state, :simple, opts)

          true ->
            # Execute command, bypassing function lookup
            run_command(command_args, state, opts)
        end
    end
  end

  defp parse_args(args) do
    {opts, rest, _} =
      Enum.reduce(args, {%{}, [], false}, fn
        arg, {opts, acc, finished_flags} ->
          cond do
            finished_flags ->
              {opts, acc ++ [arg], finished_flags}

            arg == "--" ->
              {opts, acc, true}

            String.starts_with?(arg, "-") and arg != "-" ->
              case parse_flags(String.slice(arg, 1..-1//1)) do
                {:ok, flag_opts} ->
                  {Map.merge(opts, flag_opts), acc, finished_flags}

                :end_flags ->
                  # Invalid flag - treat rest as command
                  {opts, acc ++ [arg], true}
              end

            true ->
              # First non-flag is the command
              {opts, acc ++ [arg], true}
          end
      end)

    {normalize_opts(opts), rest}
  end

  defp parse_flags(flags) do
    flags
    |> String.graphemes()
    |> Enum.reduce_while({:ok, %{}}, fn
      "p", {:ok, opts} ->
        {:cont, {:ok, Map.put(opts, :use_default_path, true)}}

      "V", {:ok, opts} ->
        {:cont, {:ok, Map.put(opts, :verbose_describe, true)}}

      "v", {:ok, opts} ->
        {:cont, {:ok, Map.put(opts, :simple_describe, true)}}

      _, _ ->
        {:halt, :end_flags}
    end)
    |> case do
      {:ok, opts} -> {:ok, opts}
      :end_flags -> :end_flags
    end
  end

  defp normalize_opts(opts) do
    %{
      use_default_path: Map.get(opts, :use_default_path, false),
      verbose_describe: Map.get(opts, :verbose_describe, false),
      simple_describe: Map.get(opts, :simple_describe, false)
    }
  end

  # Describe what a command is (-v or -V)
  defp describe_command(name, state, format, opts) do
    # Apply -p option for PATH lookup
    lookup_state =
      if opts.use_default_path do
        %{
          state
          | variables: Map.put(state.variables, "PATH", Variable.new(@default_path))
        }
      else
        state
      end

    case lookup_command(name, lookup_state) do
      {:alias, value} ->
        case format do
          :verbose -> puts("#{name} is aliased to `#{value}'")
          :simple -> puts("alias #{name}='#{value}'")
        end

        :ok

      :keyword ->
        case format do
          :verbose -> puts("#{name} is a shell keyword")
          :simple -> puts(name)
        end

        :ok

      {:function, _func_def} ->
        case format do
          :verbose -> puts("#{name} is a function")
          :simple -> puts("#{name}")
        end

        :ok

      {:builtin, _} ->
        case format do
          :verbose -> puts("#{name} is a shell builtin")
          :simple -> puts("#{name}")
        end

        :ok

      {:file, path} ->
        case format do
          :verbose -> puts("#{name} is #{path}")
          :simple -> puts("#{path}")
        end

        :ok

      :not_found ->
        case format do
          :verbose -> error("bash: command: #{name}: not found")
          # -v outputs nothing on not found
          :simple -> :ok
        end

        {:ok, 1}
    end
  end

  # Lookup what type of command this is
  defp lookup_command(name, state) do
    cond do
      # Check aliases
      Map.has_key?(state.aliases, name) ->
        {:alias, state.aliases[name]}

      # Check reserved words
      Builtin.reserved_word?(name) ->
        :keyword

      # Check functions
      Map.has_key?(state.functions, name) ->
        {:function, state.functions[name]}

      # Check builtins
      Builtin.builtin?(name) ->
        {:builtin, name}

      # Check PATH for external command
      true ->
        case find_in_path(name, state) do
          nil -> :not_found
          path -> {:file, path}
        end
    end
  end

  # Run a command, bypassing function lookup
  defp run_command([command_name | args], state, opts) do
    # When running a command with `command`, we bypass function lookup
    # but still check for builtins and external commands

    path_to_use =
      if opts.use_default_path do
        @default_path
      else
        case Map.get(state.variables, "PATH") do
          nil -> @default_path
          %Variable{} = var -> Variable.get(var, nil) || @default_path
        end
      end

    # Create a modified state with the specified PATH for lookup
    lookup_state = %{
      state
      | variables: Map.put(state.variables, "PATH", Variable.new(path_to_use))
    }

    case Builtin.get_module(command_name) do
      builtin when is_atom(builtin) and builtin != nil ->
        builtin.execute(args, nil, state)

      nil ->
        case find_in_path(command_name, lookup_state) do
          nil ->
            error("bash: #{command_name}: command not found")
            {:ok, 127}

          path ->
            # Execute external command
            execute_external(path, args, state, opts)
        end
    end
  end

  # Find command in PATH
  defp find_in_path(name, state) do
    if String.contains?(name, "/") do
      # Absolute or relative path - check directly
      if File.exists?(name) and not File.dir?(name) do
        Path.expand(name, state.working_dir)
      else
        nil
      end
    else
      # Search in PATH
      path_var = Map.get(state.variables, "PATH", Variable.new(@default_path))
      path_dirs = path_var |> Variable.get(nil) |> String.split(":")

      Enum.find_value(path_dirs, fn dir ->
        full_path = Path.join(dir, name)

        if File.exists?(full_path) and not File.dir?(full_path) do
          full_path
        end
      end)
    end
  end

  # Execute an external command
  defp execute_external(path, args, state, _opts) do
    # Build environment from exported variables
    env =
      state.variables
      |> Enum.filter(fn {_k, v} -> v.attributes[:export] == true end)
      |> Enum.map(fn {k, v} -> {k, Variable.get(v, nil) || ""} end)

    cmd_opts = [
      cd: state.working_dir,
      env: env,
      stderr_to_stdout: false
    ]

    try do
      case System.cmd(path, args, cmd_opts) do
        {stdout, exit_code} ->
          write(stdout)
          {:ok, exit_code}
      end
    rescue
      e in ErlangError ->
        error("bash: #{path}: #{inspect(e)}")
        {:ok, 126}
    end
  end
end
