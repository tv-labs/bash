defmodule Bash.AST.Comment do
  @moduledoc """
  Comment for # ... constructs.

  ## Examples

      # This is a comment
      %Comment{
        text: " This is a comment"
      }
  """

  @type t :: %__MODULE__{
          meta: Bash.AST.Meta.t(),
          text: String.t()
        }

  defstruct [:meta, :text]

  defimpl String.Chars do
    def to_string(%{text: text}) do
      "##{text}"
    end
  end

  defimpl Inspect do
    def inspect(_comment, _opts) do
      "#Comment{}"
    end
  end
end
