defmodule Bash.Builtin.Readonly do
  @moduledoc """
  `readonly [-aAf] [name[=value] ...] or readonly -p`

  Mark shell variables as not changeable.  If no ARGUMENTs are given,
  or if `-p' is given, a list of all readonly variables is printed.
  An argument of `--' disables further option processing.

  This is equivalent to `declare -r`.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/declare.def?h=bash-5.3
  """

  alias Bash.Builtin.Declare

  @doc """
  Execute the readonly builtin by delegating to declare -r.
  """
  def execute(args, stdin, session_state) do
    # readonly is equivalent to declare -r
    # Prepend -r to the args
    Declare.execute(["-r" | args], stdin, session_state)
  end
end
