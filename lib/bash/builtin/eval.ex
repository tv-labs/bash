defmodule Bash.Builtin.Eval do
  @moduledoc """
  `eval [arg ...]`

  Read ARGs as input to the shell and execute the resulting command(s).

  The args are concatenated together into a single string. The string is
  then parsed as a bash command and executed, with the exit status of the
  executed command returned.

  If there are no args, or only empty args, eval returns 0.

  Reference:
  - https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
  - https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/evalstring.c?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Parser
  alias Bash.Script

  @doc """
  Execute the eval builtin.

  Concatenates all arguments with spaces, parses them as bash commands,
  and executes the resulting AST.
  """
  defbash execute(args, state) do
    # Concatenate all arguments with spaces (like bash does)
    command_string = Enum.join(args, " ")

    # Empty string or whitespace only returns success with no action
    if String.trim(command_string) == "" do
      :ok
    else
      case execute_string(command_string, state) do
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

  defp execute_string(command_string, session_state) do
    case safe_parse(command_string) do
      {:ok, script} ->
        # Execute the parsed script in the current session context
        # Output flows directly through sinks during execution
        case Script.execute(script, nil, session_state) do
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
        {:error, "eval: line #{line}: #{msg}"}
    end
  end

  # Wrap Parser.parse to catch tokenizer errors that raise exceptions
  defp safe_parse(command_string) do
    Parser.parse(command_string)
  rescue
    e in MatchError ->
      # Extract error message from tokenizer errors
      case e.term do
        {:error, msg, line, col} ->
          {:error, msg, line, col}

        _ ->
          {:error, "syntax error", 1, 0}
      end

    _ ->
      {:error, "syntax error", 1, 0}
  end
end
