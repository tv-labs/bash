defmodule Bash.Builtin.Exit do
  @moduledoc """
  `exit [n]`

  Exit the shell with a status of N.  If N is omitted, the exit status is that of the last command executed.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/exit.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.CommandResult

  # Execute the exit builtin.
  #
  # ## Exit Code Behavior
  #
  # - No arguments: Uses the exit code of the last executed command
  # - Numeric argument: Uses that value wrapped to 0-255 (modulo 256)
  # - Negative numbers: Wrapped modulo 256 (-1 becomes 255)
  # - Non-numeric argument: Returns exit code 2 with error message
  # - Too many arguments: Returns exit code 1 with error message
  @doc false
  defbash execute(args, state) do
    case args do
      [] ->
        exit_code = Map.get(state, :last_exit_code, 0)

        {:exit,
         %CommandResult{
           command: "exit",
           exit_code: exit_code,
           error: nil
         }}

      [arg] ->
        # Trim whitespace from the argument
        trimmed = String.trim(arg)

        case Integer.parse(trimmed) do
          {num, ""} ->
            # Valid integer, wrap to 0-255 range
            # Handle negative numbers correctly with rem and adjustment
            exit_code = rem(rem(num, 256) + 256, 256)

            {:exit,
             %CommandResult{
               command: "exit",
               exit_code: exit_code,
               error: nil
             }}

          _ ->
            # Non-numeric argument
            error("exit: #{arg}: numeric argument required")
            {:ok, 2}
        end

      _ ->
        # Too many arguments
        error("exit: too many arguments")
        {:ok, 1}
    end
  end
end
