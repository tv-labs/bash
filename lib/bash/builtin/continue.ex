defmodule Bash.Builtin.Continue do
  @moduledoc """
  `continue [n]`
  Resume for, while, or until loops.

  Resumes the next iteration of the enclosing FOR, WHILE or UNTIL loop. If N is specified, resumes the Nth enclosing loop.

  Exit Status:
  The exit status is 0 unless N is not greater than or equal to 1.
  """
  use Bash.Builtin

  alias Bash.CommandResult

  @doc """
  Execute the continue builtin.

  Returns a control flow tuple `{:continue, result, levels}` to signal loop continuation.
  The loop executor is responsible for handling this and continuing at the
  appropriate loop level.

  ## Arguments

  - No arguments: continue innermost loop (levels = 1)
  - n: continue from n levels up

  ## Exit Status

  - 0 if inside a loop and successfully signaling continue
  - 1 if not inside a loop (error)
  - 2 if argument is not a valid positive integer
  """
  defbash execute(args, state) do
    loop_depth = Map.get(state, :loop_depth, 0)

    if loop_depth == 0 do
      error("continue: only meaningful in a `for', `while', or `until' loop")
      {:ok, 1}
    else
      case parse_level(args, loop_depth) do
        {:ok, levels} ->
          {:continue,
           %CommandResult{
             command: "continue",
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
        {:error, "continue: #{arg}: loop count out of range"}

      _ ->
        {:error, "continue: #{arg}: numeric argument required"}
    end
  end

  defp parse_level([_ | _], _loop_depth) do
    {:error, "continue: too many arguments"}
  end
end
