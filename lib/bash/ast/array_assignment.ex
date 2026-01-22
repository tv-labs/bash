defmodule Bash.AST.ArrayAssignment do
  @moduledoc """
  Array assignment statement.

  ## Examples

      # Array literal: arr=(a b c)
      %ArrayAssignment{
        name: "arr",
        elements: [%Word{...}, %Word{...}, %Word{...}],
        subscript: nil
      }

      # Array element: arr[0]=value
      %ArrayAssignment{
        name: "arr",
        elements: [%Word{...}],
        subscript: {:index, "0"}
      }

      # All elements: arr[@]=value (expands to multiple assignments)
      %ArrayAssignment{
        name: "arr",
        elements: [%Word{...}],
        subscript: :all_values
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: String.t(),
          elements: [AST.Word.t()],
          subscript: AST.Variable.subscript(),
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :name,
    :elements,
    subscript: nil,
    append: false,
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  @doc """
  Execute an array assignment.

  For array literals `arr=(a b c)`, creates an indexed array.
  For array elements `arr[idx]=value`, updates a single element.
  """
  def execute(
        %__MODULE__{name: name, elements: elements, subscript: subscript, meta: meta} = ast,
        _stdin,
        session_state
      ) do
    started_at = DateTime.utc_now()

    case Map.get(session_state.variables, name) do
      %Variable{attributes: %{readonly: true}} ->
        completed_at = DateTime.utc_now()
        Bash.Sink.write_stderr(session_state, "#{name}: readonly variable\n")

        executed_ast = %{
          ast
          | exit_code: 1,
            state_updates: %{},
            meta: maybe_mark_evaluated(meta, started_at, completed_at)
        }

        {:error, executed_ast}

      _existing when is_nil(subscript) ->
        # Array literal assignment: arr=(a b c)
        execute_array_literal(ast, name, elements, session_state, started_at)

      existing ->
        # Array element assignment: arr[idx]=value
        execute_array_element(ast, name, existing, subscript, elements, session_state, started_at)
    end
  end

  defp maybe_mark_evaluated(nil, _started_at, _completed_at), do: nil

  defp maybe_mark_evaluated(meta, started_at, completed_at) do
    AST.Meta.mark_evaluated(meta, started_at, completed_at)
  end

  # Execute array literal assignment: arr=(a b c) or arr=([key]=value ...) or arr+=(...)
  defp execute_array_literal(ast, name, elements, session_state, started_at) do
    existing_var = Map.get(session_state.variables, name)

    # Determine if this is an associative or indexed array based on elements
    # Associative arrays have elements as {key_word, value_word} tuples
    {expanded_elements, is_associative} =
      case elements do
        [{%{}, %{}} | _] ->
          # Associative array: elements are {key, value} tuples
          entries =
            Map.new(elements, fn {key_word, value_word} ->
              key = Helpers.word_to_string(key_word, session_state)
              value = Helpers.word_to_string(value_word, session_state)
              {key, value}
            end)

          {entries, true}

        _ ->
          # Indexed array: elements are words
          entries =
            elements
            |> Enum.with_index()
            |> Map.new(fn {word, idx} ->
              {idx, Helpers.word_to_string(word, session_state)}
            end)

          {entries, false}
      end

    var =
      if ast.append && existing_var do
        # Append mode: merge new elements with existing array
        append_to_array(existing_var, expanded_elements, is_associative)
      else
        # Normal assignment: create new array
        if is_associative do
          Variable.new_associative_array(expanded_elements)
        else
          Variable.new_indexed_array(expanded_elements)
        end
      end

    updates = %{var_updates: %{name => var}}
    completed_at = DateTime.utc_now()

    executed_ast = %{
      ast
      | exit_code: 0,
        state_updates: updates,
        meta: maybe_mark_evaluated(ast.meta, started_at, completed_at)
    }

    {:ok, executed_ast, updates}
  end

  # Append new elements to an existing array
  defp append_to_array(existing_var, new_elements, _is_associative) do
    existing_value = existing_var.value || %{}

    # For indexed arrays, find the max index and append after it
    # For associative arrays, just merge (new keys override)
    merged_value =
      if is_integer_keyed?(existing_value) && is_integer_keyed?(new_elements) do
        # Both are indexed arrays - append new elements after max index
        max_idx =
          existing_value
          |> Map.keys()
          |> Enum.max(fn -> -1 end)

        # Shift new element indices to come after existing elements
        shifted_elements =
          Map.new(new_elements, fn {idx, val} ->
            {max_idx + 1 + idx, val}
          end)

        Map.merge(existing_value, shifted_elements)
      else
        # Associative or mixed - just merge
        Map.merge(existing_value, new_elements)
      end

    %{existing_var | value: merged_value}
  end

  # Check if all keys in a map are integers (indexed array)
  defp is_integer_keyed?(map) when map_size(map) == 0, do: true

  defp is_integer_keyed?(map) do
    Enum.all?(map, fn {k, _} -> is_integer(k) end)
  end

  # Execute array element assignment: arr[idx]=value
  defp execute_array_element(
         ast,
         name,
         existing,
         subscript,
         [value_word],
         session_state,
         started_at
       ) do
    var = existing || Variable.new_indexed_array()
    is_associative = Variable.is_associative_array?(var)
    idx = evaluate_subscript(subscript, session_state, is_associative)
    expanded_value = Helpers.word_to_string(value_word, session_state)
    updated_var = Variable.set(var, expanded_value, idx)
    updates = %{var_updates: %{name => updated_var}}
    completed_at = DateTime.utc_now()

    executed_ast = %{
      ast
      | exit_code: 0,
        state_updates: updates,
        meta: maybe_mark_evaluated(ast.meta, started_at, completed_at)
    }

    {:ok, executed_ast, updates}
  end

  # Evaluate a subscript - for associative arrays, use as string key; for indexed, use arithmetic
  defp evaluate_subscript({:index, expr}, session_state, is_associative) do
    if is_associative do
      # For associative arrays, the subscript is a string key
      # Expand any variables but don't do arithmetic evaluation
      Helpers.expand_simple_string(expr, session_state)
    else
      # For indexed arrays, parse as arithmetic expression
      result = Helpers.expand_arithmetic(expr, session_state)

      case Integer.parse(result) do
        {n, _} -> n
        :error -> 0
      end
    end
  end

  defp evaluate_subscript(:all_values, _session_state, _is_associative), do: :all_values
  defp evaluate_subscript(:all_star, _session_state, _is_associative), do: :all_star

  defimpl String.Chars do
    # Array literal: arr=(val1 val2 val3) or arr=([key1]=val1 [key2]=val2)
    # Or append: arr+=(val1 val2)
    def to_string(%{name: name, elements: elements, subscript: nil, append: append}) do
      elements_str =
        Enum.map_join(elements, " ", fn
          {key, value} -> "[#{key}]=#{value}"
          word -> Kernel.to_string(word)
        end)

      op = if append, do: "+=", else: "="
      "#{name}#{op}(#{elements_str})"
    end

    # Array element: arr[idx]=value
    def to_string(%{name: name, subscript: subscript, elements: [value]}) do
      subscript_str =
        case subscript do
          {:index, expr} -> expr
          :all_values -> "@"
          :all_star -> "*"
        end

      "#{name}[#{subscript_str}]=#{value}"
    end

    # Fallback for multiple elements with subscript (shouldn't normally happen)
    def to_string(%{name: name, elements: elements}) do
      elements_str =
        Enum.map_join(elements, " ", fn
          {key, value} -> "[#{key}]=#{value}"
          word -> Kernel.to_string(word)
        end)

      "#{name}=(#{elements_str})"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{name: name, elements: elements, exit_code: exit_code}, opts) do
      base =
        concat([
          "#ArrayAssignment{",
          color(name, :atom, opts),
          ", ",
          color("#{length(elements)}", :number, opts),
          "}"
        ])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
