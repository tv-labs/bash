defmodule Bash.Builtin.Break do
  @moduledoc """
  `break [n]`

  Exit from within a FOR, WHILE or UNTIL loop. If N is specified, break N levels.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/break.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.CommandResult

  @doc """
  Execute the break builtin.

  Returns a control flow tuple `{:break, result, levels}` to signal loop exit.
  The loop executor is responsible for handling this and breaking out of
  the appropriate number of loop levels.

  ## Arguments

  - No arguments: break from innermost loop (levels = 1)
  - n: break from n levels of loops

  ## Exit Status

  - 0 if inside a loop and successfully signaling break
  - 1 if not inside a loop (error)
  - 2 if argument is not a valid positive integer
  """
  defbash execute(args, state) do
    loop_depth = Map.get(state, :loop_depth, 0)

    if loop_depth == 0 do
      error("break: only meaningful in a `for', `while', or `until' loop")
      {:ok, 1}
    else
      case parse_level(args, loop_depth) do
        {:ok, levels} ->
          {:break,
           %CommandResult{
             command: "break",
             exit_code: 0,
             error: nil
           }, levels}

        {:error, reason} ->
          error(reason)
          {:ok, 2}
      end
    end
  end

  defp parse_level([], _loop_depth), do: {:ok, 1}

  defp parse_level([arg], loop_depth) do
    trimmed = String.trim(arg)

    case Integer.parse(trimmed) do
      {n, ""} when n > 0 ->
        # Clamp to current loop depth
        {:ok, min(n, loop_depth)}

      {n, ""} when n <= 0 ->
        {:error, "break: #{arg}: loop count out of range"}

      _ ->
        {:error, "break: #{arg}: numeric argument required"}
    end
  end

  defp parse_level([_ | _], _loop_depth) do
    {:error, "break: too many arguments"}
  end
end
