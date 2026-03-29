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

  alias Bash.AST
  alias Bash.CommandResult
  alias Bash.Parser
  alias Bash.Script

  # Execute the eval builtin.
  #
  # Concatenates all arguments with spaces, parses them as bash commands,
  # and executes the resulting AST.
  @doc false
  defbash execute(args, state) do
    # Concatenate all arguments with spaces (like bash does)
    command_string = Enum.join(args, " ")

    # Empty string or whitespace only returns success with no action
    if String.trim(command_string) == "" do
      :ok
    else
      case execute_string(command_string, state) do
        {:ok, exit_code, updates} ->
          apply_updates(updates)
          {:ok, exit_code}

        {:return, exit_code, updates} ->
          apply_updates(updates)

          {:return,
           %CommandResult{
             command: "return",
             exit_code: exit_code,
             error: nil
           }}

        {:break, result, levels, updates} ->
          apply_updates(updates)

          {:break,
           %CommandResult{
             command: "break",
             exit_code: result.exit_code || 0,
             error: nil
           }, levels}

        {:continue, result, levels, updates} ->
          apply_updates(updates)

          {:continue,
           %CommandResult{
             command: "continue",
             exit_code: result.exit_code || 0,
             error: nil
           }, levels}

        {:error, msg} ->
          error(msg)
          {:ok, 1}
      end
    end
  end

  defp apply_updates(updates) do
    Enum.each(updates, fn {key, value} ->
      update_state([{key, value}])
    end)
  end

  defp execute_string(command_string, session_state) do
    case safe_parse(command_string) do
      {:ok, script} ->
        # Execute the parsed script in the current session context
        # Output flows directly through sinks during execution
        # Clear EXIT trap so nested execution doesn't fire it
        nested_state = %{session_state | traps: Map.delete(session_state.traps, "EXIT")}

        case Script.execute(script, nil, nested_state) do
          {:ok, result, updates} ->
            if return_terminated?(result) and Map.get(session_state, :in_function, false) do
              {:return, result.exit_code || 0, updates}
            else
              {:ok, result.exit_code || 0, updates}
            end

          {:exit, result, updates} ->
            {:ok, result.exit_code || 0, updates}

          {:error, result, updates} ->
            {:ok, result.exit_code || 1, updates}

          {:break, result, levels, _script, updates} ->
            {:break, result, levels, updates}

          {:continue, result, levels, _script, updates} ->
            {:continue, result, levels, updates}
        end

      {:error, msg, line, _col} ->
        {:error, "eval: line #{line}: #{msg}"}
    end
  end

  defp return_terminated?(%Script{statements: stmts}) do
    stmts
    |> Enum.reject(&match?({:separator, _}, &1))
    |> List.last()
    |> case do
      %AST.Command{name: %AST.Word{parts: [{:literal, "return"}]}} -> true
      _ -> false
    end
  end

  defp return_terminated?(_), do: false

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
