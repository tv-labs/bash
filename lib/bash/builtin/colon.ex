defmodule Bash.Builtin.Colon do
  @moduledoc """
  Null command.

  No effect; the command does nothing.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/colon.def?h=bash-5.3
  """
  use Bash.Builtin

  @doc """
  Execute the colon builtin.

  The colon builtin is a null command that does nothing and always succeeds.
  It ignores all arguments.
  """
  defbash execute(_args, _state) do
    :ok
  end
end
