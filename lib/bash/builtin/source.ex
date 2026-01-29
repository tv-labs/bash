defmodule Bash.Builtin.Source do
  @moduledoc """
  `source filename [arguments]`

  Read and execute commands from FILENAME and return.  The pathnames
  in $PATH are used to find the directory containing FILENAME.  If any
  ARGUMENTS are supplied, they become the positional parameters when
  FILENAME is executed.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/source.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Parser
  alias Bash.Script
  alias Bash.Variable

  # Execute the source builtin.
  @doc false
  defbash execute(args, state) do
    case args do
      [] ->
        error("source: filename argument required")
        {:ok, 2}

      [filename | extra_args] ->
        case source_file(filename, extra_args, state) do
          {:ok, exit_code, updates} ->
            # Apply updates here while context is still valid
            Enum.each(updates, fn {key, value} ->
              update_state([{key, value}])
            end)

            {:ok, exit_code}

          {:ok, exit_code} ->
            {:ok, exit_code}

          {:error, msg} ->
            error(msg)
            {:ok, 1}
        end
    end
  end

  defp source_file(filename, args, session_state) do
    # Resolve path (check working dir first, then PATH)
    resolved_path = resolve_path(filename, session_state)

    case resolved_path do
      nil ->
        {:error, "source: #{filename}: No such file or directory"}

      path ->
        case File.read(path) do
          {:ok, content} ->
            execute_content(content, args, session_state)

          {:error, reason} ->
            {:error, "source: #{filename}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp resolve_path(filename, session_state) do
    cond do
      # Absolute path
      String.starts_with?(filename, "/") ->
        if File.exists?(filename), do: filename, else: nil

      # Relative path (contains /)
      String.contains?(filename, "/") ->
        full_path = Path.join(session_state.working_dir, filename)
        if File.exists?(full_path), do: full_path, else: nil

      # Search in PATH
      true ->
        path_dirs =
          session_state.variables
          |> Map.get("PATH", Variable.new(""))
          |> Variable.get(nil)
          |> String.split(":")

        Enum.find_value(path_dirs, fn dir ->
          full_path = Path.join(dir, filename)
          if File.exists?(full_path), do: full_path, else: nil
        end)
    end
  end

  defp execute_content(content, _args, session_state) do
    case Parser.parse(content) do
      {:ok, script} ->
        # Execute script in current session context
        # Output flows directly through sinks during execution
        # Clear EXIT trap so nested execution doesn't fire it
        nested_state = %{
          session_state
          | traps: Map.delete(session_state.traps, "EXIT"),
            in_function: true
        }

        case Script.execute(script, nil, nested_state) do
          {:ok, result, updates} when is_map(updates) ->
            {:ok, result.exit_code || 0, updates}

          {:ok, result, _} ->
            {:ok, result.exit_code || 0}

          {:exit, result, updates} when is_map(updates) ->
            {:ok, result.exit_code || 0, updates}

          {:exit, result, _} ->
            {:ok, result.exit_code || 0}

          {:error, result, updates} when is_map(updates) ->
            {:ok, result.exit_code || 1, updates}

          {:error, result, _} ->
            {:ok, result.exit_code || 1}
        end

      {:error, msg, line, _col} ->
        {:error, "source: line #{line}: #{msg}"}
    end
  end
end
