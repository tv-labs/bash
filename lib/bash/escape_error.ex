defmodule Bash.EscapeError do
  @moduledoc """
  Exception raised when a string cannot be safely escaped for a Bash context.

  This occurs when escaping is not possible, such as when a heredoc delimiter
  appears on its own line within the content.
  """

  defexception [:message, :reason, :content, :context]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: :delimiter_in_content,
          content: String.t(),
          context: integer() | String.t()
        }

  @impl true
  def message(%{message: message}) when is_binary(message), do: message

  def message(%{reason: :delimiter_in_content, context: delimiter}) do
    "cannot escape string: heredoc delimiter #{inspect(delimiter)} appears on its own line in content"
  end
end
