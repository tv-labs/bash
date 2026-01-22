defmodule Bash.Builtin.Local do
  @moduledoc """
  `local [option] name[=value] ...`

  Local variables are visible only to the function and the commands it invokes.
  This makes it possible for a function to have its own private variables.

  The local builtin is essentially the same as declare, but it creates local
  variables that are only visible within the function scope.

  When used outside a function, it behaves like declare (creating variables
  in the current scope).

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/declare.def?h=bash-5.3
  """

  alias Bash.Builtin.Declare

  @doc """
  Execute the local builtin command.

  Delegates to the declare builtin, which handles variable creation.
  The distinction between local and declare is primarily about scope,
  which is handled by the execution context.
  """
  def execute(args, stdin, session_state) do
    # Delegate to declare - the scope handling happens at the execution level
    Declare.execute(args, stdin, session_state)
  end
end
