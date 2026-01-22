defmodule Bash.AST.TestCommand do
  @moduledoc """
  Test command for [ ... ] conditional constructs.

  This represents the POSIX test command using bracket notation.
  The args are passed directly to the test builtin for evaluation.

  ## Examples

      # [ -f file ]
      %TestCommand{
        args: ["-f", "file"]
      }

      # [ "$x" -eq 5 ]
      %TestCommand{
        args: [%Word{...}, "-eq", "5"]
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.Builtin.TestCommand

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          args: [AST.Word.t() | String.t()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    args: [],
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  def execute(%__MODULE__{args: args}, stdin, session_state) do
    {expanded_args, _env_updates} = Helpers.expand_word_list(args, session_state)
    TestCommand.execute(expanded_args, stdin, session_state)
  end

  defimpl String.Chars do
    def to_string(%{args: args}) do
      args_str = Enum.map_join(args, " ", &Kernel.to_string/1)
      "[ #{args_str} ]"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{exit_code: exit_code}, opts) do
      base = "#Test{}"

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
