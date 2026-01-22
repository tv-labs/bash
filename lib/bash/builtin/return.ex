defmodule Bash.Builtin.Return do
  @moduledoc """
  `return [n]`

  Causes a function to exit with the return value specified by N. If N
  is omitted, the return status is that of the last command.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/return.def?h=bash-5.3
  """
  use Bash.Builtin

  @doc """
  Execute the return builtin.

  ## Return Code Behavior

  - Can only be used inside a function or sourced script
  - No arguments: Uses the exit code of the last executed command
  - Numeric argument: Uses that value wrapped to 0-255 (modulo 256)
  - Negative numbers: Wrapped modulo 256 (-1 becomes 255)
  - Non-numeric argument: Returns exit code 2 with error message
  - Too many arguments: Returns exit code 1 with error message
  - Outside function context: Returns exit code 1 with error message
  """
  defbash execute(args, state) do
    in_function = Map.get(state, :in_function, false)

    if not in_function do
      error("return: can only `return' from a function or sourced script")
      {:ok, 2}
    else
      case args do
        [] ->
          exit_code = Map.get(state, :last_exit_code, 0)
          {:ok, exit_code}

        [arg] ->
          # Trim whitespace from the argument
          trimmed = String.trim(arg)

          case Integer.parse(trimmed) do
            {num, ""} ->
              # Valid integer, wrap to 0-255 range
              # Handle negative numbers correctly with rem and adjustment
              exit_code = rem(rem(num, 256) + 256, 256)
              {:ok, exit_code}

            _ ->
              error("return: #{arg}: numeric argument required")
              {:ok, 2}
          end

        _ ->
          # Too many arguments
          error("return: too many arguments")
          {:ok, 1}
      end
    end
  end
end
