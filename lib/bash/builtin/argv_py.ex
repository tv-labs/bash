defmodule Bash.Builtin.ArgvPy do
  @moduledoc """
  `argv.py [arg ...]`

  Spec test helper that prints arguments in Python list format.

  Outputs each argument wrapped in single quotes, separated by commas,
  surrounded by brackets. Newlines within arguments are rendered as
  literal `\\n` sequences.

  ## Examples

      argv.py hello world
      # ['hello', 'world']

      argv.py "hi there"
      # ['hi there']
  """
  use Bash.Builtin

  defbash execute(args, _state) do
    formatted =
      args
      |> Enum.map_join(", ", fn arg ->
        escaped =
          arg
          |> String.replace("\\", "\\\\")
          |> String.replace("\n", "\\n")

        "'" <> escaped <> "'"
      end)

    puts("[" <> formatted <> "]")
    :ok
  end
end
