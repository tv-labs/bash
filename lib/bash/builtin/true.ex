defmodule Bash.Builtin.True do
  @moduledoc """
  Return a successful result.

  Exit Status:
  Always succeeds.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/colon.def?h=bash-5.3
  """
  use Bash.Builtin

  @doc """
  Execute the true builtin.

  The true builtin always succeeds and returns exit code 0.
  All arguments are ignored.
  """
  defbash execute(_args, _state) do
    :ok
  end
end
