defmodule Bash.Interop.Result do
  @moduledoc """
  Normalized result from an Elixir interop function call.

  This struct provides a consistent interface for accessing the results
  of `defbash` function calls, regardless of which return format was used.
  """

  defstruct [:exit_code]

  @type t :: %__MODULE__{
          exit_code: non_neg_integer()
        }

  @doc false
  def normalize(result) do
    case result do
      {:ok, exit_code} when is_integer(exit_code) ->
        %__MODULE__{exit_code: exit_code}

      {:error, exit_code} when is_integer(exit_code) ->
        %__MODULE__{exit_code: exit_code}

      {:error, _} ->
        %__MODULE__{exit_code: 1}

      # For catch-all undefined function handler
      {:exit, exit_code, _opts} when is_integer(exit_code) ->
        %__MODULE__{exit_code: exit_code}
    end
  end
end
