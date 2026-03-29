defmodule Bash.Builtin.Return do
  @moduledoc """
  `return [n]`

  Causes a function to exit with the return value specified by N. If N
  is omitted, the return status is that of the last command.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/return.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.CommandResult

  @doc false
  defbash execute(args, state) do
    in_function = Map.get(state, :in_function, false)

    if not in_function do
      error("return: can only `return' from a function or sourced script")
      {:ok, 2}
    else
      case parse_return_code(args, state) do
        {:ok, exit_code} ->
          {:return, %CommandResult{command: "return", exit_code: exit_code, error: nil}}

        {:error, msg, code} ->
          error(msg)
          {:ok, code}
      end
    end
  end

  defp parse_return_code([], state) do
    {:ok, Map.get(state, :last_exit_code, 0)}
  end

  defp parse_return_code([arg], _state) do
    trimmed = String.trim(arg)

    case Integer.parse(trimmed) do
      {num, ""} ->
        {:ok, rem(rem(num, 256) + 256, 256)}

      _ ->
        {:error, "return: #{arg}: numeric argument required", 2}
    end
  end

  defp parse_return_code(_, _state) do
    {:error, "return: too many arguments", 1}
  end
end
