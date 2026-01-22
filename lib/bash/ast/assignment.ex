defmodule Bash.AST.Assignment do
  @moduledoc """
  Variable assignment.

  ## Examples

      # VAR=value
      %Assignment{
        name: "VAR",
        value: %Word{parts: [{:literal, "value"}]}
      }

      # export PATH=/usr/bin:$PATH
      %Assignment{
        name: "PATH",
        value: %Word{...},
        export: true
      }

      # local x=1 (in function)
      %Assignment{
        name: "x",
        value: %Word{parts: [{:literal, "1"}]},
        local: true
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: String.t(),
          value: AST.Word.t(),
          export: boolean(),
          local: boolean(),
          readonly: boolean(),
          append: boolean(),
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :name,
    :value,
    export: false,
    local: false,
    readonly: false,
    append: false,
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  def execute(
        %__MODULE__{name: name, value: value, export: export, meta: meta} = ast,
        _stdin,
        session_state
      ) do
    started_at = DateTime.utc_now()
    expanded_value = Helpers.word_to_string(value, session_state)
    completed_at = DateTime.utc_now()

    # Check if variable should be exported:
    # - export flag on the assignment itself (export VAR=value)
    # - allexport option enabled (set -a)
    allexport = allexport_enabled?(session_state)
    should_export = export || allexport

    updates =
      if should_export do
        %{env_updates: %{name => expanded_value}}
      else
        %{var_updates: %{name => Bash.Variable.new(expanded_value)}}
      end

    executed_ast = %{
      ast
      | exit_code: 0,
        state_updates: updates,
        meta: AST.Meta.mark_evaluated(meta, started_at, completed_at)
    }

    {:ok, executed_ast, updates}
  end

  defp allexport_enabled?(session_state) do
    options = Map.get(session_state, :options, %{})
    Map.get(options, :allexport, false) == true
  end

  defimpl String.Chars do
    def to_string(%{
          name: name,
          value: value,
          export: export,
          local: local,
          readonly: readonly,
          append: append
        }) do
      prefix =
        cond do
          export -> "export "
          local -> "local "
          readonly -> "readonly "
          true -> ""
        end

      op = if append, do: "+=", else: "="
      "#{prefix}#{name}#{op}#{value}"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{name: name, exit_code: exit_code}, opts) do
      base = concat(["#Assignment{", color(name, :atom, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
