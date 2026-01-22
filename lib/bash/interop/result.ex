defmodule Bash.Interop.Result do
  @moduledoc """
  Normalized result from an Elixir interop function call.

  This struct provides a consistent interface for accessing the results
  of `defbash` function calls, regardless of which return format was used.
  """

  defstruct [:stdout, :stderr, :exit_code, :state]

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer(),
          state: map()
        }

  @doc false
  def normalize(result, session_state) do
    case result do
      {:ok, exit_code, opts} when is_integer(exit_code) and is_list(opts) ->
        %__MODULE__{
          stdout: opts |> Keyword.get(:stdout, "") |> to_string(),
          stderr: opts |> Keyword.get(:stderr, "") |> to_string(),
          exit_code: exit_code,
          state: Keyword.get(opts, :state, session_state)
        }

      {:ok, exit_code} when is_integer(exit_code) ->
        %__MODULE__{
          stdout: "",
          stderr: "",
          exit_code: exit_code,
          state: session_state
        }

      {:error, stderr} ->
        %__MODULE__{
          stdout: "",
          stderr: to_string(stderr),
          exit_code: 1,
          state: session_state
        }

      # For catch-all undefined function handler
      {:exit, exit_code, opts} when is_integer(exit_code) and is_list(opts) ->
        %__MODULE__{
          stdout: opts |> Keyword.get(:stdout, "") |> to_string(),
          stderr: opts |> Keyword.get(:stderr, "") |> to_string(),
          exit_code: exit_code,
          state: Keyword.get(opts, :state, session_state)
        }
    end
  end
end
