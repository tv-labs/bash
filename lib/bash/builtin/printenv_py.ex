defmodule Bash.Builtin.PrintenvPy do
  @moduledoc false

  # `printenv.py [VAR ...]`
  #
  # Spec test helper that prints environment variable values.
  #
  # For each variable name given, prints the value if the variable exists
  # and is exported, or `None` if it is not set or not exported.
  #
  # This emulates the Oils test suite `printenv.py` helper.
  #
  # ## Examples
  #
  #     FOO=bar printenv.py FOO
  #     # bar
  #
  #     printenv.py NONEXISTENT
  #     # None

  use Bash.Builtin

  alias Bash.Variable

  defbash execute(args, state) do
    Enum.each(args, fn var_name ->
      case Map.get(state.variables, var_name) do
        %Variable{} = var ->
          value = Variable.get(var, nil)
          puts(value)

        nil ->
          puts("None")
      end
    end)

    :ok
  end
end
