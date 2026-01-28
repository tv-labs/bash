defmodule Bash.AST.Helpers do
  @moduledoc false

  alias Bash.Arithmetic
  alias Bash.AST
  alias Bash.AST.BraceExpand
  alias Bash.CommandResult
  alias Bash.Executor
  alias Bash.OutputCollector
  alias Bash.Parser
  alias Bash.Parser.VariableExpander
  alias Bash.ProcessSubst
  alias Bash.Sink
  alias Bash.Variable

  @doc """
  Filter separator tuples from a statement list for execution.
  Separators are preserved in the AST for formatting but skipped during execution.
  """
  def executable_statements(statements) when is_list(statements) do
    Enum.reject(statements, &match?({:separator, _}, &1))
  end

  # Execute a body (list of statements) and track state changes
  # Tracks env_updates (strings), var_updates (Variable structs), and working_dir
  # Output goes directly to sinks during execution
  def execute_body([], _session_state, env_updates) do
    {:ok, %CommandResult{exit_code: 0}, %{env_updates: env_updates}}
  end

  def execute_body(statements, session_state, env_updates) do
    statements = executable_statements(statements)
    # Track accumulated state: {env_updates, var_updates, working_dir}
    # env_updates: string values, var_updates: Variable structs (for arrays, etc.)
    initial_acc = {env_updates, %{}, session_state.working_dir}

    {final_result, {final_env, final_var, final_working_dir}} =
      Enum.reduce_while(
        statements,
        {{:ok, %CommandResult{exit_code: 0}}, initial_acc},
        fn stmt, {_last_result, {acc_env, acc_var, acc_working_dir}} ->
          # Apply accumulated state updates for this statement
          # Convert env updates to Variable structs and merge with var_updates
          env_as_vars = Map.new(acc_env, fn {k, v} -> {k, Variable.new(v)} end)

          stmt_session = %{
            session_state
            | variables:
                session_state.variables
                |> Map.merge(env_as_vars)
                |> Map.merge(acc_var),
              working_dir: acc_working_dir
          }

          case Executor.execute(stmt, stmt_session, nil) do
            {:ok, result, updates} ->
              # Collect both env_updates and var_updates
              env_updates_from_stmt = Map.get(updates, :env_updates, %{})
              var_updates_from_stmt = Map.get(updates, :var_updates, %{})
              # Keep var_updates as Variable structs (for arrays, etc.)
              merged_env = Map.merge(acc_env, env_updates_from_stmt)
              merged_var = Map.merge(acc_var, var_updates_from_stmt)
              # Track working_dir if it was updated by this command (e.g., cd)
              new_working_dir = Map.get(updates, :working_dir, acc_working_dir)
              {:cont, {{:ok, result}, {merged_env, merged_var, new_working_dir}}}

            {:ok, result} ->
              {:cont, {{:ok, result}, {acc_env, acc_var, acc_working_dir}}}

            {:error, _result} = err ->
              # Stop on error
              {:halt, {err, {acc_env, acc_var, acc_working_dir}}}

            {:error, result, updates} ->
              # Error with updates (e.g., hash_updates)
              env_updates_from_stmt = Map.get(updates, :env_updates, %{})
              var_updates_from_stmt = Map.get(updates, :var_updates, %{})
              merged_env = Map.merge(acc_env, env_updates_from_stmt)
              merged_var = Map.merge(acc_var, var_updates_from_stmt)
              new_working_dir = Map.get(updates, :working_dir, acc_working_dir)
              {:halt, {{:error, result}, {merged_env, merged_var, new_working_dir}}}

            {:exit, result} ->
              # exit builtin - terminate execution immediately
              {:halt, {{:exit, result}, {acc_env, acc_var, acc_working_dir}}}

            {:break, result, levels} ->
              # break inside body - propagate upward and stop
              {:halt, {{:break, result, levels}, {acc_env, acc_var, acc_working_dir}}}

            {:continue, result, levels} ->
              # continue inside body - propagate upward and stop
              {:halt, {{:continue, result, levels}, {acc_env, acc_var, acc_working_dir}}}

            {:background, foreground_ast, bg_session_state} ->
              # Background command inside a body - propagate upward to Session level
              {:halt,
               {{:background, foreground_ast, bg_session_state},
                {acc_env, acc_var, acc_working_dir}}}
          end
        end
      )

    case final_result do
      {:ok, result} ->
        # Build state updates, including var_updates if any
        state_updates =
          %{env_updates: final_env}
          |> maybe_add_var_updates(final_var)
          |> maybe_add_working_dir(final_working_dir, session_state.working_dir)

        {:ok, result, state_updates}

      {:error, result} ->
        {:error, result}

      {:exit, result} ->
        # Propagate exit signal upward
        {:exit, result}

      {:break, result, levels} ->
        # Propagate break signal upward
        {:break, result, levels}

      {:continue, result, levels} ->
        # Propagate continue signal upward
        {:continue, result, levels}

      {:background, foreground_ast, bg_session_state} ->
        # Propagate background signal upward to Session level
        {:background, foreground_ast, bg_session_state}
    end
  end

  # Add var_updates to state_updates map if non-empty
  defp maybe_add_var_updates(state_updates, var_updates) when map_size(var_updates) == 0 do
    state_updates
  end

  defp maybe_add_var_updates(state_updates, var_updates) do
    Map.put(state_updates, :var_updates, var_updates)
  end

  # Add working_dir to state_updates if it changed
  defp maybe_add_working_dir(state_updates, working_dir, original_working_dir)
       when working_dir == original_working_dir do
    state_updates
  end

  defp maybe_add_working_dir(state_updates, working_dir, _original_working_dir) do
    Map.put(state_updates, :working_dir, working_dir)
  end

  # Helper to convert Word to string, expanding variables and command substitution
  def word_to_string(%AST.Word{parts: parts}, session_state) do
    Enum.map_join(parts, "", &expand_part(&1, session_state))
  end

  def word_to_string(str, _session_state) when is_binary(str), do: str

  @doc """
  Expand a word to a string and return env updates from arithmetic expressions
  and ${var:=default} expansions.

  This is needed because $((n++)) and ${x:=default} should update variables.

  The env_updates are threaded through each part expansion, so $((++n)) followed
  by $((n++)) will see the updated value of n from the first expansion.
  """
  def word_to_string_with_updates(%AST.Word{parts: parts}, session_state) do
    {result_parts, env_updates, _final_state} =
      Enum.reduce(parts, {[], %{}, session_state}, fn part,
                                                      {results, acc_updates, current_state} ->
        {result, updates} = expand_part_with_updates(part, current_state)
        new_state = apply_env_updates_to_state(current_state, updates)
        {[result | results], Map.merge(acc_updates, updates), new_state}
      end)

    {result_parts |> Enum.reverse() |> Enum.join(""), env_updates}
  end

  def word_to_string_with_updates(str, _session_state) when is_binary(str), do: {str, %{}}

  # Apply env updates (string values) to session state for threading through expansions
  defp apply_env_updates_to_state(session_state, updates) when map_size(updates) == 0 do
    session_state
  end

  defp apply_env_updates_to_state(session_state, updates) do
    new_vars =
      Map.new(updates, fn {k, v} ->
        {k, Variable.new(v)}
      end)

    %{session_state | variables: Map.merge(session_state.variables, new_vars)}
  end

  # Helper to expand a single part with env updates (for arithmetic and assign-default)
  # Returns {result, env_updates}
  defp expand_part_with_updates({:arith_expand, expr_string}, session_state) do
    expand_arithmetic_with_updates(expr_string, session_state)
  end

  defp expand_part_with_updates({:variable, %AST.Variable{} = var}, session_state) do
    expand_variable_with_updates(var, session_state)
  end

  defp expand_part_with_updates(part, session_state) do
    # All other parts don't produce env updates
    {expand_part(part, session_state), %{}}
  end

  # Helper to expand a single part (used by word_to_string and word_to_string_with_updates)
  defp expand_part({:literal, text}, session_state) do
    text |> expand_tilde(session_state) |> expand_glob_pattern(session_state)
  end

  defp expand_part({:variable, %AST.Variable{} = var}, session_state),
    do: expand_variable(var, session_state)

  defp expand_part({:command_subst, parsed_ast}, session_state),
    do: expand_command_substitution(parsed_ast, session_state)

  defp expand_part({tag, command_string}, session_state)
       when tag in [:backtick, :cmd_subst] do
    case Parser.parse(command_string) do
      {:ok, parsed_ast} -> expand_command_substitution(parsed_ast, session_state)
      {:error, _, _, _} -> ""
    end
  end

  defp expand_part({:process_subst_in, parsed_ast}, session_state) do
    {path, _pid} = expand_process_substitution(parsed_ast, :input, session_state)
    path
  end

  defp expand_part({:process_subst_out, parsed_ast}, session_state) do
    {path, _pid} = expand_process_substitution(parsed_ast, :output, session_state)
    path
  end

  defp expand_part({:arith_expand, expr_string}, session_state),
    do: expand_arithmetic(expr_string, session_state)

  defp expand_part({:glob, pattern}, session_state),
    do: expand_glob_pattern(pattern, session_state)

  defp expand_part({:single_quoted, text}, _session_state), do: text

  defp expand_part({:double_quoted, inner_parts}, session_state) do
    # Inside double quotes: no tilde/glob expansion on literals, but expand variables etc.
    Enum.map_join(inner_parts, "", fn
      {:literal, text} -> text
      part -> expand_part(part, session_state)
    end)
  end

  defp expand_part({:brace_expand, brace_spec}, _session_state) do
    brace_spec
    |> to_brace_expand_struct()
    |> BraceExpand.expand()
    |> Enum.join(" ")
  end

  defp expand_part(other, _session_state), do: inspect(other)

  @doc """
  Expand a word to a list of strings, handling brace expansion.

  Unlike word_to_string/2 which returns a single string, this function
  properly handles brace expansion which can produce multiple words.

  ## Examples

      expand_word(%Word{parts: [{:literal, "file"}, {:brace_expand, %{type: :list, items: ...}}]}, state)
      #=> ["file1", "file2", "file3"]
  """
  @spec expand_word(AST.Word.t(), map()) :: [String.t()]
  def expand_word(%AST.Word{parts: parts, quoted: :none}, session_state) do
    # Check if any part is a brace expansion
    if has_brace_expansion?(parts) do
      expand_word_with_braces(parts, session_state)
    else
      # No brace expansion, return single-element list
      [word_to_string(%AST.Word{parts: parts, quoted: :none}, session_state)]
    end
  end

  def expand_word(%AST.Word{} = word, session_state) do
    # Quoted words don't do brace expansion
    [word_to_string(word, session_state)]
  end

  def expand_word(str, _session_state) when is_binary(str), do: [str]

  @doc """
  Expand a word to a list of strings and return env updates from arithmetic expressions.
  """
  def expand_word_with_updates(%AST.Word{parts: parts, quoted: :none}, session_state) do
    if has_brace_expansion?(parts) do
      # For brace expansion, we need to collect updates from each expanded word
      # Currently brace expansion doesn't track updates (rare case)
      {expand_word_with_braces(parts, session_state), %{}}
    else
      # No brace expansion, use word_to_string_with_updates
      {result, updates} =
        word_to_string_with_updates(%AST.Word{parts: parts, quoted: :none}, session_state)

      {[result], updates}
    end
  end

  def expand_word_with_updates(%AST.Word{} = word, session_state) do
    # Quoted words don't do brace expansion
    {result, updates} = word_to_string_with_updates(word, session_state)
    {[result], updates}
  end

  def expand_word_with_updates(str, _session_state) when is_binary(str), do: {[str], %{}}

  # Check if parts contain brace expansion
  defp has_brace_expansion?(parts) do
    Enum.any?(parts, fn
      {:brace_expand, _} -> true
      _ -> false
    end)
  end

  # Expand word parts with brace expansion, computing cartesian product
  defp expand_word_with_braces(parts, session_state) do
    # Convert each part to a list of alternatives
    # Brace expansion returns multiple alternatives; everything else is wrapped in [...]
    alternatives =
      Enum.map(parts, fn
        {:brace_expand, brace_spec} ->
          brace_spec
          |> to_brace_expand_struct()
          |> BraceExpand.expand()

        part ->
          [expand_part(part, session_state)]
      end)

    # Compute cartesian product and join each combination
    alternatives
    |> cartesian_product()
    |> Enum.map(&Enum.join/1)
  end

  # Cartesian product of list of lists
  defp cartesian_product([]), do: [[]]

  defp cartesian_product([head | tail]) do
    tail_product = cartesian_product(tail)
    for h <- head, t <- tail_product, do: [h | t]
  end

  # Convert tokenizer brace_spec map to BraceExpand struct
  defp to_brace_expand_struct(%{type: type} = spec) do
    %BraceExpand{
      type: type,
      items: Map.get(spec, :items),
      range_start: Map.get(spec, :range_start),
      range_end: Map.get(spec, :range_end),
      step: Map.get(spec, :step),
      zero_pad: Map.get(spec, :zero_pad)
    }
  end

  # Expand a variable AST to its string value
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: nil},
         session_state
       ) do
    get_scalar_value(session_state, var_name)
  end

  defp expand_variable(
         %AST.Variable{name: var_name, subscript: :all_values, expansion: nil},
         session_state
       ) do
    expand_array_all(session_state, var_name, " ")
  end

  defp expand_variable(
         %AST.Variable{name: var_name, subscript: :all_star, expansion: nil},
         session_state
       ) do
    ifs = get_scalar_value(session_state, "IFS") || " \t\n"
    separator = String.first(ifs) || ""
    expand_array_all(session_state, var_name, separator)
  end

  defp expand_variable(
         %AST.Variable{name: var_name, subscript: {:index, idx_expr}, expansion: nil},
         session_state
       ) do
    expand_array_element(session_state, var_name, idx_expr)
  end

  # ${!arr[@]} or ${!arr[*]} - list array indices/keys
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: sub, expansion: {:list_keys}},
         session_state
       )
       when sub in [:all_values, :all_star] do
    list_array_keys(session_state, var_name)
  end

  # ${!ref} - indirect reference (use ref's value as variable name)
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:indirect}},
         session_state
       ) do
    # Get the value of the reference variable
    ref_value = get_scalar_value(session_state, var_name)
    # Use that value as the variable name to look up
    if ref_value != "" do
      get_scalar_value(session_state, ref_value)
    else
      ""
    end
  end

  # ${arr[@]:offset} or ${arr[@]:offset:length} - array slicing
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: sub, expansion: {:slice, offset, length}},
         session_state
       )
       when sub in [:all_values, :all_star] do
    slice_array(session_state, var_name, offset, length)
  end

  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:length}},
         session_state
       ) do
    get_scalar_value(session_state, var_name) |> String.length() |> to_string()
  end

  defp expand_variable(
         %AST.Variable{name: var_name, subscript: sub, expansion: {:length}},
         session_state
       )
       when sub in [:all_values, :all_star] do
    get_array_length(session_state, var_name) |> to_string()
  end

  # ${#arr[idx]} - string length of element at index
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: {:index, idx_expr}, expansion: {:length}},
         session_state
       ) do
    element = expand_array_element(session_state, var_name, idx_expr)
    String.length(element) |> to_string()
  end

  # ${var:-default} - Use default if var is unset or null (empty)
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:default, default_value}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    if value == nil or value == "" do
      expand_word_or_string(default_value, session_state)
    else
      value
    end
  end

  # ${var:=default} - Assign default if var is unset or null (empty)
  # NOTE: This returns just the value; for the assignment side effect,
  # use expand_variable_with_updates/2
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:assign_default, default_value}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    if value == nil or value == "" do
      expand_word_or_string(default_value, session_state)
    else
      value
    end
  end

  # ${var:+alternate} - Use alternate if var is set and not null
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:alternate, alt_value}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    if value != nil and value != "" do
      expand_word_or_string(alt_value, session_state)
    else
      ""
    end
  end

  # ${var:offset} or ${var:offset:length} - Substring extraction
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:substring, offset, length}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    case {offset, length} do
      {offset, nil} -> String.slice(value, offset..-1//1)
      {offset, len} when offset < 0 -> String.slice(value, offset, len)
      {offset, len} -> String.slice(value, offset, len)
    end
  end

  # ${var#pattern} or ${var##pattern} - Remove prefix
  defp expand_variable(
         %AST.Variable{
           name: var_name,
           subscript: nil,
           expansion: {:remove_prefix, pattern, mode}
         },
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)
    remove_prefix(value, pattern, mode)
  end

  # ${var%pattern} or ${var%%pattern} - Remove suffix
  defp expand_variable(
         %AST.Variable{
           name: var_name,
           subscript: nil,
           expansion: {:remove_suffix, pattern, mode}
         },
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)
    remove_suffix(value, pattern, mode)
  end

  # ${var/pattern/replacement} or ${var//pattern/replacement} - Substitution
  defp expand_variable(
         %AST.Variable{
           name: var_name,
           subscript: nil,
           expansion: {:substitute, pattern, replacement, mode}
         },
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    case {pattern, mode} do
      {"#" <> rest, _mode} ->
        # Prefix substitution: ${var/#pattern/replacement}
        substitute_prefix(value, rest, replacement)

      {"%" <> rest, _mode} ->
        # Suffix substitution: ${var/%pattern/replacement}
        substitute_suffix(value, rest, replacement)

      {pat, :first} ->
        # First occurrence only
        String.replace(value, pat, replacement, global: false)

      {pat, :all} ->
        # All occurrences
        String.replace(value, pat, replacement, global: true)
    end
  end

  # ${var^} - uppercase first character
  # ${var^^} - uppercase all characters
  # ${var,} - lowercase first character
  # ${var,,} - lowercase all characters
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:case_modify, mode}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    case mode do
      :upper_first ->
        case String.graphemes(value) do
          [] -> ""
          [first | rest] -> String.upcase(first) <> Enum.join(rest)
        end

      :upper_all ->
        String.upcase(value)

      :lower_first ->
        case String.graphemes(value) do
          [] -> ""
          [first | rest] -> String.downcase(first) <> Enum.join(rest)
        end

      :lower_all ->
        String.downcase(value)
    end
  end

  # ${!prefix*} and ${!prefix@} - expand to names of variables matching prefix
  defp expand_variable(
         %AST.Variable{name: prefix, expansion: {:prefix_names, _mode}},
         session_state
       ) do
    # Get all variable names matching the prefix
    matching_names =
      session_state.variables
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    # In bash, @ joins with space when quoted, * joins with first char of IFS
    # For simplicity, we join with space for both (most common behavior)
    Enum.join(matching_names, " ")
  end

  # ${var@Q} - quote value for reuse as input
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, :quote}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)
    # Quote the value using $'...' syntax for special chars, or '...' for simple strings
    quote_for_reuse(value)
  end

  # ${var@a} - variable attributes
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, :attributes}},
         session_state
       ) do
    case resolve_variable(session_state, var_name) do
      nil ->
        ""

      %Variable{attributes: attrs} ->
        # Return attribute flags: r=readonly, x=export, a=indexed array, A=associative array, etc.
        flags = []
        flags = if attrs[:readonly], do: ["r" | flags], else: flags
        flags = if attrs[:export], do: ["x" | flags], else: flags
        flags = if attrs[:integer], do: ["i" | flags], else: flags
        flags = if attrs[:indexed_array], do: ["a" | flags], else: flags
        flags = if attrs[:assoc_array], do: ["A" | flags], else: flags
        flags = if attrs[:nameref], do: ["n" | flags], else: flags
        flags = if attrs[:lowercase], do: ["l" | flags], else: flags
        flags = if attrs[:uppercase], do: ["u" | flags], else: flags
        Enum.join(Enum.reverse(flags), "")
    end
  end

  # ${var@E} - expand backslash escape sequences
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, :escape}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)
    expand_escape_sequences(value)
  end

  # ${var@A} - assignment statement that would recreate the variable
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, :assignment}},
         session_state
       ) do
    case resolve_variable(session_state, var_name) do
      nil -> ""
      %Variable{} = var -> "#{var_name}=#{quote_for_reuse(Variable.get(var, nil) || "")}"
    end
  end

  # ${var@u} - uppercase first character (like ${var^})
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, :upper}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    case String.graphemes(value) do
      [] -> ""
      [first | rest] -> String.upcase(first) <> Enum.join(rest)
    end
  end

  # ${var@L} - lowercase all characters (like ${var,,})
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, :lower}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)
    String.downcase(value)
  end

  # ${var@P} - prompt string expansion (simplified - just return value)
  # ${var@K} and ${var@k} - quoted keys for arrays (not fully implemented)
  defp expand_variable(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:transform, _op}},
         session_state
       ) do
    # For unsupported transforms, just return the value
    get_scalar_value(session_state, var_name)
  end

  defp expand_variable(%AST.Variable{name: var_name}, session_state) do
    # Fallback for any other variable patterns
    case resolve_variable(session_state, var_name) do
      nil -> ""
      %Variable{} = var -> Variable.get(var, nil) || ""
    end
  end

  # Expand variable with env updates - only ${var:=default} produces updates
  # Returns {result, env_updates}
  defp expand_variable_with_updates(
         %AST.Variable{name: var_name, subscript: nil, expansion: {:assign_default, default_value}},
         session_state
       ) do
    value = get_scalar_value(session_state, var_name)

    if value == nil or value == "" do
      default = expand_word_or_string(default_value, session_state)
      {default, %{var_name => default}}
    else
      {value, %{}}
    end
  end

  defp expand_variable_with_updates(var, session_state) do
    # All other variable expansions don't produce env updates
    {expand_variable(var, session_state), %{}}
  end

  # Quote a value for safe reuse as shell input
  # Uses $'...' syntax for strings with special chars, '...' otherwise
  defp quote_for_reuse(nil), do: "''"
  defp quote_for_reuse(""), do: "''"

  defp quote_for_reuse(value) when is_binary(value) do
    if needs_special_quoting?(value) do
      # Use $'...' syntax with escape sequences
      escaped =
        value
        |> String.replace("\\", "\\\\")
        |> String.replace("'", "\\'")
        |> String.replace("\n", "\\n")
        |> String.replace("\t", "\\t")
        |> String.replace("\r", "\\r")

      "$'#{escaped}'"
    else
      # Simple single-quoting
      "'#{String.replace(value, "'", "'\\''")}'"
    end
  end

  defp needs_special_quoting?(value) do
    String.contains?(value, ["\n", "\t", "\r", "\x00"])
  end

  # Expand backslash escape sequences like $'...' strings
  defp expand_escape_sequences(value) when is_binary(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\\", "\\")
    |> String.replace("\\'", "'")
    |> String.replace("\\\"", "\"")
  end

  # Helper to expand either a Word struct or a plain string
  defp expand_word_or_string(%AST.Word{} = word, session_state),
    do: word_to_string(word, session_state)

  defp expand_word_or_string(str, _session_state) when is_binary(str), do: str

  # Convert Word to string for case pattern matching - NO pathname expansion
  # Glob characters are kept as-is for pattern matching purposes
  def pattern_to_string(%AST.Word{parts: parts}, session_state) do
    Enum.map_join(parts, "", fn
      {:literal, text} -> text
      {:glob, pattern} -> pattern
      {:variable, %AST.Variable{} = var} -> expand_variable(var, session_state)
      {:command_subst, parsed_ast} -> expand_command_substitution(parsed_ast, session_state)
      {:arith_expand, expr_string} -> expand_arithmetic(expr_string, session_state)
    end)
  end

  def pattern_to_string(str, _session_state) when is_binary(str), do: str

  # Expand glob pattern from session's working directory
  # If noglob option is set, return the pattern literally
  # Tilde expansion: ~, ~+, ~-, ~/path
  # If the variable is not set, the tilde is not expanded (bash behavior)
  defp expand_tilde("~+", session_state), do: session_state.working_dir

  defp expand_tilde("~-" = text, session_state) do
    case get_scalar_value(session_state, "OLDPWD") do
      nil -> text
      "" -> text
      value -> value
    end
  end

  defp expand_tilde("~+" <> rest, session_state) do
    session_state.working_dir <> rest
  end

  defp expand_tilde("~-" <> rest = text, session_state) do
    case get_scalar_value(session_state, "OLDPWD") do
      nil -> text
      "" -> text
      value -> value <> rest
    end
  end

  defp expand_tilde("~", session_state) do
    case get_scalar_value(session_state, "HOME") do
      nil -> "~"
      "" -> "~"
      value -> value
    end
  end

  defp expand_tilde("~/" <> rest = text, session_state) do
    case get_scalar_value(session_state, "HOME") do
      nil -> text
      "" -> text
      home -> Path.join(home, rest)
    end
  end

  defp expand_tilde(text, _session_state), do: text

  defp expand_glob_pattern(pattern, session_state) do
    if noglob_enabled?(session_state) do
      # noglob (-f) is set - don't expand
      pattern
    else
      # For absolute paths, use them directly; for relative paths, join with working_dir
      {glob_path, is_absolute, has_dot_prefix} =
        if String.starts_with?(pattern, "/") do
          {pattern, true, false}
        else
          # Track if pattern starts with ./ to preserve it in output
          has_dot = String.starts_with?(pattern, "./")
          {Path.join(session_state.working_dir, pattern), false, has_dot}
        end

      case Path.wildcard(glob_path, match_dot: false) do
        # No matches, return pattern literally
        [] ->
          pattern

        matches ->
          if is_absolute do
            # For absolute patterns, return matches as-is
            Enum.join(matches, " ")
          else
            # Convert absolute paths to relative paths (from working_dir)
            # Preserve ./ prefix if original pattern had it
            Enum.map_join(matches, " ", fn match ->
              relative = Path.relative_to(match, session_state.working_dir)

              if has_dot_prefix do
                "./" <> relative
              else
                relative
              end
            end)
          end
      end
    end
  end

  defp noglob_enabled?(session_state) do
    options = Map.get(session_state, :options, %{})
    Map.get(options, :noglob, false) == true
  end

  # Expand arithmetic expression and return the result as a string
  def expand_arithmetic(expr_string, session_state) do
    {result, _env_updates} = expand_arithmetic_with_updates(expr_string, session_state)
    result
  end

  @doc """
  Expand arithmetic expression and return both result and env updates.
  In bash, $((n++)) updates the variable n.
  """
  def expand_arithmetic_with_updates(expr_string, session_state) do
    # Convert variables to plain string map for Arithmetic
    vars =
      Map.new(session_state.variables, fn {k, v} ->
        {k, Variable.get(v, nil)}
      end)

    # Add positional parameters ($1, $2, etc.)
    positional_params = Map.get(session_state, :positional_params, [])

    vars_with_positional =
      positional_params
      |> Enum.with_index(1)
      |> Enum.reduce(vars, fn {value, idx}, acc ->
        Map.put(acc, Integer.to_string(idx), value)
      end)

    # First expand command substitutions $(...)  in the expression
    # This must happen before variable expansion
    expr_with_cmd_subst = expand_arith_command_subst(expr_string, session_state)

    # Expand $variable references in the expression before evaluation
    # Bash allows both $var and var inside $((...))
    expanded_expr = expand_arith_variables(expr_with_cmd_subst, vars_with_positional)

    case Arithmetic.evaluate(expanded_expr, vars_with_positional) do
      {:ok, result, updated_env} ->
        # Calculate which variables changed
        env_updates =
          updated_env
          |> Enum.filter(fn {k, v} -> Map.get(vars, k) != v end)
          |> Map.new()

        {Integer.to_string(result), env_updates}

      {:error, _reason} ->
        # On error, return empty string (like bash does for failed expansions)
        {"", %{}}
    end
  end

  # Expand command substitutions $(...) in arithmetic expressions
  # Must be done before variable expansion since $(cmd) is not a variable pattern
  defp expand_arith_command_subst(expr, session_state) do
    expand_arith_command_subst_loop(expr, session_state)
  end

  defp expand_arith_command_subst_loop(expr, session_state) do
    case find_command_subst(expr) do
      nil ->
        expr

      {start_pos, end_pos, cmd_content} ->
        # Execute the command substitution
        output =
          case Parser.parse(cmd_content) do
            {:ok, ast} ->
              expand_command_substitution(ast, session_state)

            {:error, _, _, _} ->
              ""
          end

        # Replace the $(...) with the output
        prefix = String.slice(expr, 0, start_pos)
        suffix = String.slice(expr, end_pos + 1, String.length(expr))
        new_expr = prefix <> output <> suffix

        # Recurse to handle any remaining command substitutions
        expand_arith_command_subst_loop(new_expr, session_state)
    end
  end

  # Find the first $(...) command substitution in the expression
  # Returns {start_pos, end_pos, content} or nil
  # Handles nested parentheses correctly
  defp find_command_subst(expr) do
    case :binary.match(expr, "$(") do
      :nomatch ->
        nil

      {start_pos, 2} ->
        # Found "$(" - now find the matching ")"
        content_start = start_pos + 2
        rest = String.slice(expr, content_start, String.length(expr))

        case find_matching_paren(rest, 0, 0) do
          nil ->
            nil

          content_length ->
            content = String.slice(rest, 0, content_length)
            end_pos = content_start + content_length
            {start_pos, end_pos, content}
        end
    end
  end

  # Find the position of the matching closing paren, handling nesting
  # Returns the length of content (not including the closing paren) or nil
  defp find_matching_paren(<<>>, _depth, _pos), do: nil

  defp find_matching_paren(<<"(", rest::binary>>, depth, pos) do
    find_matching_paren(rest, depth + 1, pos + 1)
  end

  defp find_matching_paren(<<")", _rest::binary>>, 0, pos), do: pos

  defp find_matching_paren(<<")", rest::binary>>, depth, pos) do
    find_matching_paren(rest, depth - 1, pos + 1)
  end

  defp find_matching_paren(<<_char::utf8, rest::binary>>, depth, pos) do
    find_matching_paren(rest, depth, pos + 1)
  end

  # Expand $variable references in arithmetic expressions
  # Handles: $1, $var, ${var}
  # Returns the expression with variables replaced by their values
  defp expand_arith_variables(expr, vars) do
    # Match ${var}, $digits, and $var patterns
    Regex.replace(
      ~r/\$\{([^}]+)\}|\$([0-9]+)|\$([A-Za-z_][A-Za-z0-9_]*)/,
      expr,
      fn
        # ${var} pattern
        _full, var_name, "", "" ->
          Map.get(vars, var_name, "0")

        # $digits pattern (positional params)
        _full, "", digits, "" ->
          Map.get(vars, digits, "0")

        # $var pattern
        _full, "", "", var_name ->
          Map.get(vars, var_name, "0")

        # Fallback
        full, _, _, _ ->
          full
      end
    )
  end

  @doc """
  Expand a simple string expression for use as an associative array key.

  This expands variable references like $var and ${var} but does NOT
  perform arithmetic evaluation. The string is returned as-is if it
  contains no variables.
  """
  def expand_simple_string(expr_string, session_state) do
    {expanded, _updates} = VariableExpander.expand_variables(expr_string, session_state)
    expanded
  end

  # Expand command substitution by executing the parsed AST and capturing stdout
  # Uses a temporary collector to capture output without polluting the session's collector
  defp expand_command_substitution(ast, session_state) do
    # Create a temporary collector for this command substitution
    {:ok, temp_collector} = OutputCollector.start_link()
    temp_stdout_sink = Sink.collector(temp_collector)
    temp_stderr_sink = Sink.collector(temp_collector)

    # Replace session sinks with temporary ones
    subst_session = %{
      session_state
      | stdout_sink: temp_stdout_sink,
        stderr_sink: temp_stderr_sink
    }

    # Execute the AST with the temporary sinks
    _result = Executor.execute(ast, subst_session, nil)

    # Extract stdout from the temporary collector
    {stdout_iodata, _stderr_iodata} = OutputCollector.flush_split(temp_collector)
    GenServer.stop(temp_collector, :normal)

    # Convert iodata to string and trim trailing newline (bash behavior)
    IO.iodata_to_binary(stdout_iodata)
    |> String.trim_trailing("\n")
  end

  # Expand process substitution by starting a background process and returning FIFO path
  # The background process writes to (for input) or reads from (for output) the FIFO.
  # Returns {fifo_path, pid} so caller can track for cleanup.
  defp expand_process_substitution(ast, direction, session_state) do
    temp_dir = get_temp_dir(session_state)

    case ProcessSubst.start_link(
           direction: direction,
           command_ast: ast,
           session_state: session_state,
           temp_dir: temp_dir
         ) do
      {:ok, pid, fifo_path} ->
        {fifo_path, pid}

      {:error, reason} ->
        # On error, return empty string (similar to failed command substitution)
        require Logger
        Logger.warning("Process substitution failed: #{inspect(reason)}")
        {"", nil}
    end
  end

  # Get temp directory from session state or use default
  defp get_temp_dir(session_state) do
    Map.get(session_state, :temp_dir, "/tmp")
  end

  @doc """
  Cleanup a list of process substitution PIDs.

  This should be called after a command that used process substitution
  completes to ensure the background processes and FIFOs are cleaned up.
  """
  @spec cleanup_process_substs([pid()]) :: :ok
  def cleanup_process_substs(pids) when is_list(pids) do
    Enum.each(pids, fn pid ->
      if pid && Process.alive?(pid) do
        ProcessSubst.stop(pid)
      end
    end)

    :ok
  end

  # Check if a pattern matches a value (supports glob patterns)
  def pattern_matches?(pattern, value, session_state) do
    # For case patterns, use pattern_to_string which does NOT do pathname expansion
    # Glob characters (* ? [...]) are for matching, not filename expansion
    pattern_str = pattern_to_string(pattern, session_state)

    if String.contains?(pattern_str, ["*", "?", "["]) do
      # Glob pattern - convert to regex
      regex_pattern =
        pattern_str
        |> String.graphemes()
        |> convert_glob_to_regex([])
        |> Enum.reverse()
        |> Enum.join()

      case Regex.compile("^#{regex_pattern}$") do
        {:ok, regex} -> Regex.match?(regex, value)
        {:error, _} -> pattern_str == value
      end
    else
      pattern_str == value
    end
  end

  # Convert glob pattern to regex pattern
  defp convert_glob_to_regex([], acc), do: acc

  defp convert_glob_to_regex(["*" | rest], acc) do
    convert_glob_to_regex(rest, [".*" | acc])
  end

  defp convert_glob_to_regex(["?" | rest], acc) do
    convert_glob_to_regex(rest, ["." | acc])
  end

  defp convert_glob_to_regex(["[", "!" | rest], acc) do
    # Negated character class - convert [!...] to [^...]
    convert_glob_to_regex(rest, ["[^" | acc])
  end

  defp convert_glob_to_regex(["[" | rest], acc) do
    # Character class - pass through to regex
    convert_glob_to_regex(rest, ["[" | acc])
  end

  defp convert_glob_to_regex(["]" | rest], acc) do
    convert_glob_to_regex(rest, ["]" | acc])
  end

  defp convert_glob_to_regex([char | rest], acc) do
    # Escape regex special characters
    escaped =
      case char do
        "." -> "\\."
        "^" -> "\\^"
        "$" -> "\\$"
        "+" -> "\\+"
        "{" -> "\\{"
        "}" -> "\\}"
        "|" -> "\\|"
        "(" -> "\\("
        ")" -> "\\)"
        "\\" -> "\\\\"
        other -> other
      end

    convert_glob_to_regex(rest, [escaped | acc])
  end

  # Helper to expand a list of Words or strings
  # Handles brace expansion which can produce multiple words from a single Word
  # Also collects env_updates from arithmetic expansions like $((n++))
  def expand_word_list(items, session_state) do
    {expanded, env_updates} =
      Enum.flat_map_reduce(items, %{}, fn item, acc_updates ->
        case item do
          %AST.Word{quoted: :none} = word ->
            # Unquoted word - use expand_word_with_updates for brace expansion and updates
            {expanded_words, word_updates} = expand_word_with_updates(word, session_state)
            merged_updates = Map.merge(acc_updates, word_updates)

            if contains_quoted_parts?(word) do
              # Word contains double-quoted parts - don't word-split
              {expanded_words, merged_updates}
            else
              # Fully unquoted - expand and split on whitespace (for glob expansion)
              split_args =
                expanded_words
                |> Enum.flat_map(&String.split(&1, ~r/\s+/, trim: true))

              {split_args, merged_updates}
            end

          %AST.Word{} = word ->
            # Quoted word - no brace expansion or word-splitting
            {expanded, word_updates} = word_to_string_with_updates(word, session_state)
            {[expanded], Map.merge(acc_updates, word_updates)}

          %AST.ArrayAssignment{} = array_assign ->
            # Pass ArrayAssignment through for builtins like declare to handle
            {[array_assign], acc_updates}

          %AST.RegexPattern{} = regex ->
            # Pass RegexPattern through - expansion handled in TestExpression
            {[regex], acc_updates}

          str when is_binary(str) ->
            {[str], acc_updates}
        end
      end)

    {expanded, env_updates}
  end

  # Check if a Word contains any double-quoted parts
  # These parts should not be subject to word-splitting
  defp contains_quoted_parts?(%AST.Word{parts: parts}) do
    Enum.any?(parts, fn
      {:double_quoted, _} -> true
      {:single_quoted, _} -> true
      _ -> false
    end)
  end

  # Get scalar variable value (extracts from Variable struct)
  # Also handles special variables ($?, $$, $!, $0, $_) and positional params ($1-$9)
  defp get_scalar_value(session_state, var_name) do
    cond do
      # Special single-character variables: $?, $$, $!, $0, $_, $-
      is_special_var?(var_name) ->
        get_special_var(var_name, session_state)

      # Positional parameters: $1 through $9 (and multi-digit in braces)
      is_positional_param?(var_name) ->
        get_positional_param(var_name, session_state)

      # Dynamic variables that are computed on access
      is_dynamic_var?(var_name) ->
        get_dynamic_var(var_name, session_state)

      # Regular variable
      true ->
        resolve_variable_value(session_state, var_name, 0)
    end
  end

  # Resolve variable value, following nameref references
  defp resolve_variable_value(session_state, var_name, depth) when depth < 10 do
    case Map.get(session_state.variables, var_name) do
      nil ->
        # Check nounset option - error if variable is unset
        if nounset_enabled?(session_state) do
          raise "bash: #{var_name}: unbound variable"
        else
          ""
        end

      %Variable{} = var ->
        # Check if this is a nameref - follow the reference
        case Variable.nameref_target(var) do
          nil ->
            Variable.get(var, nil) || ""

          target_name ->
            # Recursively resolve the target variable
            resolve_variable_value(session_state, target_name, depth + 1)
        end
    end
  end

  # Prevent infinite loops from circular namerefs
  defp resolve_variable_value(_session_state, _var_name, _depth) do
    ""
  end

  # Check if nounset option is enabled in session state
  defp nounset_enabled?(session_state) do
    options = Map.get(session_state, :options, %{})
    Map.get(options, :nounset, false) == true
  end

  # Check if variable name is a special variable
  defp is_special_var?(name) when name in ~w(? $ ! 0 _ # @ * -), do: true
  defp is_special_var?(_), do: false

  # Check if variable name is a dynamic variable (computed on access)
  defp is_dynamic_var?(name) when name in ~w(RANDOM LINENO SECONDS PPID BASH_VERSION), do: true
  defp is_dynamic_var?(_), do: false

  # Get dynamic variable value
  defp get_dynamic_var("RANDOM", _session_state), do: to_string(:rand.uniform(32768) - 1)

  defp get_dynamic_var("LINENO", session_state),
    do: to_string(Map.get(session_state, :current_line, 1))

  defp get_dynamic_var("SECONDS", session_state) do
    start_time = Map.get(session_state, :start_time, System.monotonic_time(:second))
    elapsed = System.monotonic_time(:second) - start_time
    to_string(max(0, elapsed))
  end

  defp get_dynamic_var("PPID", _session_state) do
    # Parent PID - in Elixir we use the OS PID
    System.pid() |> String.to_integer() |> to_string()
  end

  defp get_dynamic_var("BASH_VERSION", _session_state), do: "5.3.3(1)-release"
  defp get_dynamic_var(_, _), do: ""

  # Check if variable name is a positional parameter (1-9 or multi-digit)
  defp is_positional_param?(name) do
    case Integer.parse(name) do
      {n, ""} when n >= 1 -> true
      _ -> false
    end
  end

  # Get special variable value from session state
  defp get_special_var(var_name, session_state) do
    special_vars = Map.get(session_state, :special_vars, %{})

    case var_name do
      "?" -> to_string(special_vars["?"] || 0)
      "$" -> to_string(special_vars["$"] || 0)
      "!" -> to_string(special_vars["!"] || "")
      "0" -> to_string(special_vars["0"] || "bash")
      "_" -> to_string(special_vars["_"] || "")
      "#" -> get_param_count(session_state)
      "@" -> get_all_params(session_state, :separate)
      "*" -> get_all_params(session_state, :joined)
      "-" -> get_shell_options(session_state)
    end
  end

  # Get shell options as a string (like "hB" for hashall and braceexpand)
  @option_flags [
    {:hashall, "h"},
    {:braceexpand, "B"},
    {:noglob, "f"},
    {:noclobber, "C"},
    {:nounset, "u"},
    {:errexit, "e"},
    {:xtrace, "x"},
    {:verbose, "v"},
    {:noexec, "n"},
    {:allexport, "a"},
    {:notify, "b"},
    {:interactive, "i"},
    {:monitor, "m"},
    {:privileged, "p"},
    {:physical, "P"},
    {:histexpand, "H"}
  ]
  defp get_shell_options(session_state) do
    options = Map.get(session_state, :options, %{})

    # Map option names to their single-letter flags
    @option_flags
    |> Enum.filter(fn {opt, _} -> options[opt] || false end)
    |> Enum.map_join("", fn {_, flag} -> flag end)
  end

  # Get positional parameter by index (1-based)
  defp get_positional_param(name, session_state) do
    case Integer.parse(name) do
      {index, ""} when index >= 1 ->
        positional_params = Map.get(session_state, :positional_params, [[]])
        current_params = List.first(positional_params) || []

        case Enum.at(current_params, index - 1) do
          nil -> ""
          value -> value
        end

      _ ->
        ""
    end
  end

  # Get count of positional parameters
  defp get_param_count(session_state) do
    positional_params = Map.get(session_state, :positional_params, [[]])
    current_params = List.first(positional_params) || []
    to_string(length(current_params))
  end

  # Get all positional parameters
  # TODO: $* should join with IFS first char, $@ should keep separate when quoted
  defp get_all_params(session_state, _mode) do
    positional_params = Map.get(session_state, :positional_params, [[]])
    current_params = List.first(positional_params) || []
    Enum.join(current_params, " ")
  end

  # Resolve variable by name, following nameref chain
  # Returns the actual Variable struct (or nil if not found)
  defp resolve_variable(session_state, var_name, depth \\ 0)

  defp resolve_variable(session_state, var_name, depth) when depth < 10 do
    case Map.get(session_state.variables, var_name) do
      nil ->
        nil

      %Variable{} = var ->
        case Variable.nameref_target(var) do
          nil -> var
          target -> resolve_variable(session_state, target, depth + 1)
        end
    end
  end

  defp resolve_variable(_session_state, _var_name, _depth), do: nil

  # Expand all array values with separator: ${arr[@]} or ${arr[*]}
  defp expand_array_all(session_state, var_name, separator) do
    case resolve_variable(session_state, var_name) do
      nil ->
        ""

      %Variable{attributes: %{array_type: nil}} = var ->
        Variable.get(var, nil) || ""

      %Variable{attributes: %{array_type: :indexed}} = var ->
        var |> Variable.all_values() |> Enum.join(separator)

      %Variable{attributes: %{array_type: :associative}} = var ->
        var |> Variable.all_values() |> Enum.join(separator)
    end
  end

  # Expand single array element: ${arr[0]} or ${assoc[key]}
  defp expand_array_element(session_state, var_name, idx_expr) do
    case resolve_variable(session_state, var_name) do
      nil ->
        ""

      %Variable{attributes: %{array_type: :associative}} = var ->
        # For associative arrays, use string key (expand variables but no arithmetic)
        key = expand_simple_string(idx_expr, session_state)
        Variable.get(var, key) || ""

      %Variable{} = var ->
        # For indexed arrays and scalars, use numeric index
        idx = evaluate_subscript_expr(idx_expr, session_state)
        Variable.get(var, idx) || ""
    end
  end

  # Evaluate subscript expression to integer
  defp evaluate_subscript_expr(expr, session_state) do
    result = expand_arithmetic(expr, session_state)

    case Integer.parse(result) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Get array length: ${#arr[@]}
  defp get_array_length(session_state, var_name) do
    case resolve_variable(session_state, var_name) do
      nil -> 0
      %Variable{} = var -> Variable.length(var)
    end
  end

  # Remove prefix pattern from value
  # ${var#pattern} removes shortest match, ${var##pattern} removes longest match
  defp remove_prefix(value, pattern, mode) do
    regex = glob_pattern_to_regex(pattern, mode == :longest)

    case Regex.run(~r/^#{regex}/, value) do
      nil -> value
      [match | _] -> String.replace_prefix(value, match, "")
    end
  end

  # Remove suffix pattern from value
  # ${var%pattern} removes shortest match, ${var%%pattern} removes longest match
  defp remove_suffix(value, pattern, mode) do
    # For suffix removal, we need to find matches at different positions
    # and choose shortest or longest based on mode
    regex_pattern = glob_pattern_to_regex(pattern, true)

    case Regex.compile("(#{regex_pattern})$") do
      {:ok, regex} ->
        # Find all possible suffix matches by trying from different start positions
        matches = find_suffix_matches(value, regex)

        case {matches, mode} do
          {[], _} ->
            value

          {ms, :shortest} ->
            # Shortest: remove the smallest matching suffix
            shortest = Enum.min_by(ms, &String.length/1)
            String.replace_suffix(value, shortest, "")

          {ms, :longest} ->
            # Longest: remove the largest matching suffix
            longest = Enum.max_by(ms, &String.length/1)
            String.replace_suffix(value, longest, "")
        end

      {:error, _} ->
        value
    end
  end

  # Find all possible suffix matches by checking substrings
  defp find_suffix_matches(value, regex) do
    len = String.length(value)

    0..(len - 1)
    |> Enum.map(fn i -> String.slice(value, i, len) end)
    |> Enum.filter(fn substring ->
      case Regex.run(regex, substring) do
        nil -> false
        [match] -> match == substring
        [match | _] -> match == substring
      end
    end)
  end

  # Substitute prefix: ${var/#pattern/replacement}
  defp substitute_prefix(value, pattern, replacement) do
    regex = glob_pattern_to_regex(pattern, false)

    case Regex.run(~r/^#{regex}/, value) do
      nil -> value
      [match | _] -> String.replace_prefix(value, match, replacement)
    end
  end

  # Substitute suffix: ${var/%pattern/replacement}
  defp substitute_suffix(value, pattern, replacement) do
    regex = glob_pattern_to_regex(pattern, false)

    case Regex.run(~r/#{regex}$/, value) do
      nil -> value
      [match | _] -> String.replace_suffix(value, match, replacement)
    end
  end

  # Convert glob pattern to regex pattern
  # If greedy is true, use greedy matching (longest); otherwise non-greedy (shortest)
  @regex_special_chars ~w(. ^ $ + { } | [ ] \\) ++ ~w[( )]
  defp glob_pattern_to_regex(pattern, greedy) do
    pattern
    |> String.graphemes()
    |> Enum.map(fn
      "*" -> if greedy, do: ".*", else: ".*?"
      "?" -> "."
      char when char in @regex_special_chars -> "\\" <> char
      char -> char
    end)
    |> Enum.join()
  end

  # List array indices (for indexed arrays) or keys (for associative arrays)
  # ${!arr[@]} or ${!arr[*]}
  defp list_array_keys(session_state, var_name) do
    case resolve_variable(session_state, var_name) do
      nil ->
        ""

      %Variable{attributes: %{array_type: :indexed}} = var ->
        var
        |> Variable.all_keys()
        |> Enum.sort_by(&String.to_integer/1)
        |> Enum.join(" ")

      %Variable{attributes: %{array_type: :associative}} = var ->
        var
        |> Variable.all_keys()
        |> Enum.join(" ")

      %Variable{} ->
        # Scalar variable treated as single-element array with index 0
        "0"
    end
  end

  # Slice array: ${arr[@]:offset} or ${arr[@]:offset:length}
  defp slice_array(session_state, var_name, offset, length) do
    case resolve_variable(session_state, var_name) do
      nil ->
        ""

      %Variable{} = var ->
        values = Variable.all_values(var)

        sliced =
          case {offset, length} do
            {off, nil} when off >= 0 ->
              Enum.drop(values, off)

            {off, nil} when off < 0 ->
              Enum.take(values, off)

            {off, len} when off >= 0 ->
              values |> Enum.drop(off) |> Enum.take(len)

            {off, len} when off < 0 ->
              values |> Enum.take(off) |> Enum.take(len)
          end

        Enum.join(sliced, " ")
    end
  end
end
