defmodule Bash.Builtin.False do
  @moduledoc """
  Return an unsuccessful result.

  Exit Status:
  Always fails.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/colon.def?h=bash-5.3
  """
  use Bash.Builtin

  # Execute the false builtin.
  #
  # Always returns exit code 1, regardless of arguments.
  # All arguments are ignored, as per the bash source implementation.
  @doc false
  defbash execute(_args, _state) do
    {:ok, 1}
  end
end
