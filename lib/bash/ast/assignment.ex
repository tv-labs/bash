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
    # Assignments do not perform glob or brace expansion (bash spec).
    noglob_state = suppress_glob(session_state)
    value = suppress_brace_expansion(value)
    # Use word_to_string_with_updates to capture ${x:=default} side effects
    {expanded_value, value_updates} = Helpers.word_to_string_with_updates(value, noglob_state)
    completed_at = DateTime.utc_now()

    # Extract command substitution exit code (e.g., x=$(exit 42) should set $? to 42)
    {cmd_sub_exit_code, value_updates} = Map.pop(value_updates, :__cmd_sub_exit_code__)
    exit_code = cmd_sub_exit_code || 0

    # Resolve the target variable name (follow nameref chain)
    target_name = resolve_nameref_target(session_state, name)

    # Check if variable should be exported:
    # - export flag on the assignment itself (export VAR=value)
    # - allexport option enabled (set -a)
    allexport = allexport_enabled?(session_state)
    should_export = export || allexport

    # Build updates for this assignment
    assignment_updates =
      if should_export do
        var = Bash.Variable.new(expanded_value)
        %{variables: %{target_name => %{var | attributes: %{var.attributes | export: true}}}}
      else
        %{variables: %{target_name => Bash.Variable.new(expanded_value)}}
      end

    # Merge with any updates from the value expansion (e.g., ${x:=default})
    updates = merge_updates(assignment_updates, value_updates)

    updates =
      if cmd_sub_exit_code do
        Map.put(updates, :special_vars_updates, %{"?" => cmd_sub_exit_code})
      else
        updates
      end

    executed_ast = %{
      ast
      | exit_code: exit_code,
        state_updates: updates,
        meta: AST.Meta.mark_evaluated(meta, started_at, completed_at)
    }

    {:ok, executed_ast, updates}
  end

  # Merge updates from value expansion into assignment updates
  defp merge_updates(assignment_updates, value_updates) when map_size(value_updates) == 0 do
    assignment_updates
  end

  defp merge_updates(assignment_updates, value_updates) do
    existing_vars = Map.get(assignment_updates, :variables, %{})
    value_vars = Map.new(value_updates, fn {k, v} -> {k, Bash.Variable.new(v)} end)
    merged_vars = Map.merge(value_vars, existing_vars)
    Map.put(assignment_updates, :variables, merged_vars)
  end

  # Follow nameref chain to find the actual target variable
  defp resolve_nameref_target(session_state, name, depth \\ 0)

  defp resolve_nameref_target(session_state, name, depth) when depth < 10 do
    case Map.get(session_state.variables, name) do
      %Bash.Variable{} = var ->
        case Bash.Variable.nameref_target(var) do
          nil -> name
          target -> resolve_nameref_target(session_state, target, depth + 1)
        end

      nil ->
        name
    end
  end

  defp resolve_nameref_target(_session_state, name, _depth), do: name

  defp allexport_enabled?(session_state) do
    options = Map.get(session_state, :options, %{})
    Map.get(options, :allexport, false) == true
  end

  defp suppress_glob(session_state) do
    options = Map.get(session_state, :options, %{})
    %{session_state | options: Map.put(options, :noglob, true)}
  end

  defp suppress_brace_expansion(%AST.Word{parts: parts} = word) do
    %{word | parts: Enum.map(parts, &neutralize_brace/1)}
  end

  defp neutralize_brace({:brace_expand, %{type: :list, items: items}}) do
    inner =
      items
      |> Enum.map(fn parts ->
        Enum.map_join(parts, "", fn
          {:literal, text} -> text
          {:brace_expand, spec} -> neutralize_brace_to_string(spec)
          other -> neutralize_brace_to_string(other)
        end)
      end)
      |> Enum.join(",")

    {:literal, "{" <> inner <> "}"}
  end

  defp neutralize_brace({:brace_expand, %{type: :range} = spec}) do
    step_str = if spec.step, do: "..#{spec.step}", else: ""
    {:literal, "{#{spec.range_start}..#{spec.range_end}#{step_str}}"}
  end

  defp neutralize_brace(other), do: other

  defp neutralize_brace_to_string({:brace_expand, spec}) do
    {:literal, text} = neutralize_brace({:brace_expand, spec})
    text
  end

  defp neutralize_brace_to_string({:literal, text}), do: text
  defp neutralize_brace_to_string({:variable, name}), do: "$" <> name
  defp neutralize_brace_to_string({:variable_braced, name, _}), do: "${" <> name <> "}"
  defp neutralize_brace_to_string({:command_subst, cmd}), do: "$(" <> cmd <> ")"
  defp neutralize_brace_to_string({:single_quoted, str}), do: "'" <> str <> "'"
  defp neutralize_brace_to_string(_), do: ""

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
