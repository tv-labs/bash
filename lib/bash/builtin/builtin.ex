defmodule Bash.Builtin.Builtin do
  @moduledoc """
  `builtin [shell-builtin [arg ...]]`

  Execute the specified shell builtin, passing it args, and return its exit status.
  This is useful when you wish to define a shell function with the same name as a
  shell builtin, retaining the functionality of the builtin within the function.

  The return status is non-zero if shell-builtin is not a shell builtin command.

  Exit Status:
  Returns the exit status of SHELL-BUILTIN, or false if SHELL-BUILTIN is not a
  shell builtin.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/builtin.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Builtin

  @doc """
  Execute the builtin builtin.

  With no arguments, returns exit code 0.
  With a builtin name and optional args, executes that builtin.
  Returns exit code 1 if the specified name is not a shell builtin.
  """
  defbash execute(args, state) do
    case args do
      [] ->
        :ok

      [builtin_name | rest_args] ->
        case Builtin.get_module(builtin_name) do
          nil ->
            error("builtin: #{builtin_name}: not a shell builtin")
            {:ok, 1}

          module when is_atom(module) and not is_nil(module) ->
            # Execute the builtin's execute/3 function with the remaining args
            # Pass through the result directly (defbash generates execute/3)
            module.execute(rest_args, nil, state)
        end
    end
  end
end
