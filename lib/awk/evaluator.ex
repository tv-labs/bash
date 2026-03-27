defmodule AWK.Evaluator do
  @moduledoc """
  Streaming evaluator for AWK programs.

  Processes input records through pattern-action rules, maintaining
  AWK runtime state (variables, arrays, fields, counters).

  ```mermaid
  graph TD
      A[Input Stream] --> B[Split by RS]
      B --> C{BEGIN rules}
      C --> D[For each record]
      D --> E[Split by FS into fields]
      E --> F[Match patterns]
      F --> G[Execute actions]
      G --> H[Collect output]
      D --> I{END rules}
      I --> H
  ```
  """

  alias AWK.AST
  alias AWK.Builtins

  defmodule State do
    @moduledoc "AWK runtime state."

    @type t :: %__MODULE__{
            variables: %{String.t() => term()},
            arrays: %{String.t() => %{String.t() => term()}},
            functions: %{String.t() => AWK.AST.FuncDef.t()},
            fields: [String.t()],
            record: String.t(),
            nr: non_neg_integer(),
            fnr: non_neg_integer(),
            nf: non_neg_integer(),
            fs: String.t(),
            rs: String.t(),
            ofs: String.t(),
            ors: String.t(),
            ofmt: String.t(),
            convfmt: String.t(),
            subsep: String.t(),
            filename: String.t(),
            output: [String.t()],
            rng_state: term(),
            range_states: %{reference() => boolean()},
            open_files: %{String.t() => term()},
            exit_code: non_neg_integer() | nil
          }

    defstruct variables: %{},
              arrays: %{},
              functions: %{},
              fields: [],
              record: "",
              nr: 0,
              fnr: 0,
              nf: 0,
              fs: " ",
              rs: "\n",
              ofs: " ",
              ors: "\n",
              ofmt: "%.6g",
              convfmt: "%.6g",
              subsep: <<28>>,
              filename: "",
              output: [],
              rng_state: nil,
              range_states: %{},
              open_files: %{},
              exit_code: nil
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec run(AST.Program.t(), Enumerable.t(), keyword()) :: Enumerable.t()
  def run(program, input_stream, opts \\ []) do
    state = init_state(program, opts)
    state = exec_begin_rules(program.begin_rules, state)
    begin_output = Enum.reverse(state.output)
    state = %{state | output: []}

    Stream.concat([
      begin_output,
      Stream.transform(
        input_stream,
        {state, program},
        fn record, {st, prog} ->
          st = process_record(record, prog.rules, %{st | output: []})

          if st.exit_code != nil do
            {:halt, {st, prog}}
          else
            {Enum.reverse(st.output), {st, prog}}
          end
        end,
        fn {st, prog} ->
          st = exec_end_rules(prog.end_rules, %{st | output: []})
          {Enum.reverse(st.output), {st, prog}}
        end,
        fn _ -> :ok end
      )
    ])
  end

  @spec run_string(AST.Program.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_string(program, input, opts \\ []) do
    state = init_state(program, opts)
    state = exec_begin_rules(program.begin_rules, state)

    records = split_records(input, state.rs)

    state =
      Enum.reduce_while(records, state, fn record, st ->
        st = process_record(record, program.rules, st)

        if st.exit_code != nil do
          {:halt, st}
        else
          {:cont, st}
        end
      end)

    state = exec_end_rules(program.end_rules, state)
    {:ok, state.output |> Enum.reverse() |> Enum.join()}
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # Initialization
  # ---------------------------------------------------------------------------

  defp init_state(program, opts) do
    functions =
      program.functions
      |> Enum.into(%{}, fn %AST.FuncDef{name: name} = fd -> {name, fd} end)

    fs = Keyword.get(opts, :fs, " ")
    rs = Keyword.get(opts, :rs, "\n")
    vars = Keyword.get(opts, :variables, %{})

    %State{
      functions: functions,
      fs: fs,
      rs: rs,
      variables: vars
    }
  end

  defp split_records(input, "\n"), do: String.split(input, "\n", trim: true)

  defp split_records(input, rs) do
    String.split(input, rs, trim: true)
  end

  # ---------------------------------------------------------------------------
  # BEGIN / END rules
  # ---------------------------------------------------------------------------

  defp exec_begin_rules(rules, state) do
    Enum.reduce(rules, state, fn %AST.BeginRule{action: action}, st ->
      exec_block(action, st)
    end)
  end

  defp exec_end_rules(rules, state) do
    Enum.reduce(rules, state, fn %AST.EndRule{action: action}, st ->
      exec_block(action, st)
    end)
  end

  # ---------------------------------------------------------------------------
  # Record processing
  # ---------------------------------------------------------------------------

  defp process_record(record, rules, state) do
    state = %{state |
      record: record,
      nr: state.nr + 1,
      fnr: state.fnr + 1
    }

    state = split_fields(state)

    Enum.reduce_while(rules, state, fn rule, st ->
      case match_pattern(rule.pattern, st) do
        {true, st} ->
          action = rule.action || %AST.Block{statements: [%AST.PrintStmt{args: []}]}

          case exec_action(action, st) do
            {:next, st} -> {:halt, st}
            {:nextfile, st} -> {:halt, st}
            {:exit, code, st} -> {:halt, %{st | exit_code: code}}
            {:ok, st} -> {:cont, st}
          end

        {false, st} ->
          {:cont, st}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Field splitting
  # ---------------------------------------------------------------------------

  defp split_fields(state) do
    fields =
      case state.fs do
        " " -> String.split(state.record)
        fs when byte_size(fs) == 1 -> String.split(state.record, fs)
        fs ->
          case Regex.compile(fs) do
            {:ok, r} -> Regex.split(r, state.record)
            {:error, _} -> String.split(state.record, fs)
          end
      end

    %{state | fields: fields, nf: length(fields)}
  end

  defp get_field(state, 0), do: state.record

  defp get_field(state, n) when is_integer(n) and n > 0 do
    Enum.at(state.fields, n - 1, "")
  end

  defp get_field(_state, _), do: ""

  defp set_field(state, 0, value) do
    record = to_string_awk(value, state)

    fields =
      case state.fs do
        " " -> String.split(record)
        fs when byte_size(fs) == 1 -> String.split(record, fs)
        fs ->
          case Regex.compile(fs) do
            {:ok, r} -> Regex.split(r, record)
            {:error, _} -> String.split(record, fs)
          end
      end

    %{state | record: record, fields: fields, nf: length(fields)}
  end

  defp set_field(state, n, value) when is_integer(n) and n > 0 do
    str_val = to_string_awk(value, state)
    fields = state.fields
    current_len = length(fields)

    fields =
      if n > current_len do
        fields ++ List.duplicate("", n - current_len)
      else
        fields
      end

    fields = List.replace_at(fields, n - 1, str_val)
    record = Enum.join(fields, state.ofs)
    %{state | fields: fields, record: record, nf: length(fields)}
  end

  defp set_field(state, _, _), do: state

  # ---------------------------------------------------------------------------
  # Pattern matching
  # ---------------------------------------------------------------------------

  defp match_pattern(nil, state), do: {true, state}

  defp match_pattern(%AST.ExprPattern{expr: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {truthy?(val), state}
  end

  defp match_pattern(%AST.RegexPattern{regex: regex}, state) do
    case Regex.compile(regex) do
      {:ok, r} -> {Regex.match?(r, state.record), state}
      {:error, _} -> {false, state}
    end
  end

  defp match_pattern(%AST.RangePattern{from: from, to: to} = pat, state) do
    key = :erlang.phash2(pat)
    active = Map.get(state.range_states, key, false)

    if active do
      {to_match, state} = match_pattern(to, state)

      if to_match do
        {true, %{state | range_states: Map.put(state.range_states, key, false)}}
      else
        {true, state}
      end
    else
      {from_match, state} = match_pattern(from, state)

      if from_match do
        {true, %{state | range_states: Map.put(state.range_states, key, true)}}
      else
        {false, state}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Statement execution
  # ---------------------------------------------------------------------------

  defp exec_action(action, state) do
    exec_stmt(action, state)
  catch
    {:next, st} -> {:next, st}
    {:nextfile, st} -> {:nextfile, st}
    {:exit, code, st} -> {:exit, code, st}
  end

  defp exec_block(%AST.Block{statements: stmts}, state) do
    Enum.reduce(stmts, state, fn stmt, st ->
      {_, st} = exec_stmt(stmt, st)
      st
    end)
  end

  defp exec_stmt(%AST.Block{statements: stmts}, state) do
    state =
      Enum.reduce(stmts, state, fn stmt, st ->
        {_, st} = exec_stmt(stmt, st)
        st
      end)

    {:ok, state}
  end

  defp exec_stmt(%AST.ExprStmt{expr: expr}, state) do
    {_val, state} = eval_expr(expr, state)
    {:ok, state}
  end

  defp exec_stmt(%AST.PrintStmt{args: args, redirect: redirect}, state) do
    state = exec_print(args, state, redirect)
    {:ok, state}
  end

  defp exec_stmt(%AST.PrintfStmt{format: fmt_expr, args: args, redirect: redirect}, state) do
    {fmt, state} = eval_expr(fmt_expr, state)
    {evaluated_args, state} = eval_expr_list(args, state)
    output = Builtins.format_printf(to_string_awk(fmt, state), evaluated_args)
    state = emit_output(output, state, redirect)
    {:ok, state}
  end

  defp exec_stmt(%AST.IfStmt{condition: cond_expr, consequent: cons, alternative: alt}, state) do
    {val, state} = eval_expr(cond_expr, state)

    if truthy?(val) do
      exec_stmt(cons, state)
    else
      if alt do
        exec_stmt(alt, state)
      else
        {:ok, state}
      end
    end
  end

  defp exec_stmt(%AST.WhileStmt{condition: cond_expr, body: body}, state) do
    do_while_loop(cond_expr, body, state)
  end

  defp exec_stmt(%AST.DoWhileStmt{body: body, condition: cond_expr}, state) do
    state =
      try do
        {_, st} = exec_stmt(body, state)
        st
      catch
        :break -> throw({:do_while_break, state})
        :continue -> state
      end

    do_while_loop(cond_expr, body, state)
  catch
    {:do_while_break, st} -> {:ok, st}
  end

  defp exec_stmt(%AST.ForStmt{init: init, condition: cond_expr, increment: incr, body: body}, state) do
    state =
      if init do
        {_, st} = exec_stmt(init, state)
        st
      else
        state
      end

    do_for_loop(cond_expr, incr, body, state)
  end

  defp exec_stmt(%AST.ForInStmt{variable: var, array: array_name, body: body}, state) do
    arr = Map.get(state.arrays, array_name, %{})

    state =
      Enum.reduce_while(Map.keys(arr), state, fn key, st ->
        st = %{st | variables: Map.put(st.variables, var, key)}

        try do
          {_, st} = exec_stmt(body, st)
          {:cont, st}
        catch
          :break -> {:halt, st}
          :continue -> {:cont, st}
        end
      end)

    {:ok, state}
  end

  defp exec_stmt(%AST.BreakStmt{}, _state) do
    throw(:break)
  end

  defp exec_stmt(%AST.ContinueStmt{}, _state) do
    throw(:continue)
  end

  defp exec_stmt(%AST.NextStmt{}, state) do
    throw({:next, state})
  end

  defp exec_stmt(%AST.NextfileStmt{}, state) do
    throw({:nextfile, state})
  end

  defp exec_stmt(%AST.ExitStmt{status: status_expr}, state) do
    {code, state} =
      if status_expr do
        {val, state} = eval_expr(status_expr, state)
        {to_integer(val), state}
      else
        {0, state}
      end

    throw({:exit, code, state})
  end

  defp exec_stmt(%AST.ReturnStmt{value: val_expr}, state) do
    {val, state} =
      if val_expr do
        eval_expr(val_expr, state)
      else
        {"", state}
      end

    throw({:return, val, state})
  end

  defp exec_stmt(%AST.DeleteStmt{target: %AST.ArrayRef{name: name, indices: indices}}, state) do
    {keys, state} = eval_array_key(indices, state)
    arr = Map.get(state.arrays, name, %{})
    arr = Map.delete(arr, keys)
    {:ok, %{state | arrays: Map.put(state.arrays, name, arr)}}
  end

  defp exec_stmt(%AST.DeleteStmt{target: %AST.Variable{name: name}}, state) do
    {:ok, %{state | arrays: Map.delete(state.arrays, name)}}
  end

  defp exec_stmt(%AST.GetlineStmt{}, state) do
    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Loops
  # ---------------------------------------------------------------------------

  defp do_while_loop(cond_expr, body, state) do
    {val, state} = eval_expr(cond_expr, state)

    if truthy?(val) do
      try do
        {_, state} = exec_stmt(body, state)
        do_while_loop(cond_expr, body, state)
      catch
        :break -> {:ok, state}
        :continue -> do_while_loop(cond_expr, body, state)
      end
    else
      {:ok, state}
    end
  end

  defp do_for_loop(cond_expr, incr, body, state) do
    should_continue =
      if cond_expr do
        {val, st} = eval_expr(cond_expr, state)
        {truthy?(val), st}
      else
        {true, state}
      end

    case should_continue do
      {false, state} ->
        {:ok, state}

      {true, state} ->
        try do
          {_, state} = exec_stmt(body, state)

          state =
            if incr do
              {_, st} = eval_expr(incr, state)
              st
            else
              state
            end

          do_for_loop(cond_expr, incr, body, state)
        catch
          :break ->
            {:ok, state}

          :continue ->
            state =
              if incr do
                {_, st} = eval_expr(incr, state)
                st
              else
                state
              end

            do_for_loop(cond_expr, incr, body, state)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Print
  # ---------------------------------------------------------------------------

  defp exec_print(args, state, redirect) do
    {values, state} = eval_expr_list(args, state)

    line =
      case values do
        [] -> to_string_awk(get_field(state, 0), state)
        vs -> Enum.map(vs, &to_string_awk(&1, state)) |> Enum.join(state.ofs)
      end

    output = line <> state.ors
    emit_output(output, state, redirect)
  end

  defp emit_output(output, state, nil) do
    %{state | output: [output | state.output]}
  end

  defp emit_output(output, state, %AST.OutputRedirect{type: _type, target: target_expr}) do
    {_target, state} = eval_expr(target_expr, state)
    %{state | output: [output | state.output]}
  end

  # ---------------------------------------------------------------------------
  # Expression evaluation
  # ---------------------------------------------------------------------------

  defp eval_expr(%AST.NumberLiteral{value: v}, state), do: {v, state}
  defp eval_expr(%AST.StringLiteral{value: v}, state), do: {v, state}

  defp eval_expr(%AST.RegexLiteral{value: regex}, state) do
    case Regex.compile(regex) do
      {:ok, r} -> {if(Regex.match?(r, state.record), do: 1, else: 0), state}
      {:error, _} -> {0, state}
    end
  end

  defp eval_expr(%AST.Variable{name: name}, state) do
    val = resolve_variable(name, state)
    {val, state}
  end

  defp eval_expr(%AST.FieldRef{expr: expr}, state) do
    {idx, state} = eval_expr(expr, state)
    {get_field(state, to_integer(idx)), state}
  end

  defp eval_expr(%AST.ArrayRef{name: name, indices: indices}, state) do
    {key, state} = eval_array_key(indices, state)
    arr = Map.get(state.arrays, name, %{})
    {Map.get(arr, key, ""), state}
  end

  defp eval_expr(%AST.Assignment{target: target, op: op, value: val_expr}, state) do
    {rhs, state} = eval_expr(val_expr, state)

    case op do
      :eq ->
        state = assign_target(target, rhs, state)
        {rhs, state}

      compound_op ->
        {current, state} = eval_expr(target, state)
        result = apply_compound_op(compound_op, current, rhs)
        state = assign_target(target, result, state)
        {result, state}
    end
  end

  defp eval_expr(%AST.BinaryExpr{op: op, left: left, right: right}, state) do
    case op do
      :and ->
        {lval, state} = eval_expr(left, state)

        if truthy?(lval) do
          {rval, state} = eval_expr(right, state)
          {if(truthy?(rval), do: 1, else: 0), state}
        else
          {0, state}
        end

      :or ->
        {lval, state} = eval_expr(left, state)

        if truthy?(lval) do
          {1, state}
        else
          {rval, state} = eval_expr(right, state)
          {if(truthy?(rval), do: 1, else: 0), state}
        end

      _ ->
        {lval, state} = eval_expr(left, state)
        {rval, state} = eval_expr(right, state)
        {eval_binary_op(op, lval, rval), state}
    end
  end

  defp eval_expr(%AST.UnaryExpr{op: :minus, operand: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {-to_number(val), state}
  end

  defp eval_expr(%AST.UnaryExpr{op: :plus, operand: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {to_number(val), state}
  end

  defp eval_expr(%AST.UnaryExpr{op: :not, operand: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {if(truthy?(val), do: 0, else: 1), state}
  end

  defp eval_expr(%AST.UnaryMinus{operand: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {-to_number(val), state}
  end

  defp eval_expr(%AST.UnaryPlus{operand: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {to_number(val), state}
  end

  defp eval_expr(%AST.UnaryNot{operand: expr}, state) do
    {val, state} = eval_expr(expr, state)
    {if(truthy?(val), do: 0, else: 1), state}
  end

  defp eval_expr(%AST.TernaryExpr{condition: cond_expr, consequent: cons, alternative: alt}, state) do
    {val, state} = eval_expr(cond_expr, state)

    if truthy?(val) do
      eval_expr(cons, state)
    else
      eval_expr(alt, state)
    end
  end

  defp eval_expr(%AST.MatchExpr{expr: expr, regex: regex_expr, negate: negate}, state) do
    {str, state} = eval_expr(expr, state)
    {pattern, state} = eval_expr(regex_expr, state)
    regex = compile_regex(pattern)
    matched = Regex.match?(regex, to_string_awk(str, state))
    result = if negate, do: !matched, else: matched
    {if(result, do: 1, else: 0), state}
  end

  defp eval_expr(%AST.InExpr{index: indices, array: array_name}, state) do
    {key, state} = eval_array_key(indices, state)
    arr = Map.get(state.arrays, array_name, %{})
    {if(Map.has_key?(arr, key), do: 1, else: 0), state}
  end

  defp eval_expr(%AST.Concatenation{left: left, right: right}, state) do
    {lval, state} = eval_expr(left, state)
    {rval, state} = eval_expr(right, state)
    {to_string_awk(lval, state) <> to_string_awk(rval, state), state}
  end

  defp eval_expr(%AST.PreIncrement{operand: operand}, state) do
    {val, state} = eval_expr(operand, state)
    new_val = to_number(val) + 1
    state = assign_target(operand, new_val, state)
    {new_val, state}
  end

  defp eval_expr(%AST.PreDecrement{operand: operand}, state) do
    {val, state} = eval_expr(operand, state)
    new_val = to_number(val) - 1
    state = assign_target(operand, new_val, state)
    {new_val, state}
  end

  defp eval_expr(%AST.PostIncrement{operand: operand}, state) do
    {val, state} = eval_expr(operand, state)
    old_val = to_number(val)
    state = assign_target(operand, old_val + 1, state)
    {old_val, state}
  end

  defp eval_expr(%AST.PostDecrement{operand: operand}, state) do
    {val, state} = eval_expr(operand, state)
    old_val = to_number(val)
    state = assign_target(operand, old_val - 1, state)
    {old_val, state}
  end

  defp eval_expr(%AST.FuncCall{name: name, args: args}, state) do
    {evaluated_args, state} = eval_expr_list(args, state)

    case Map.get(state.functions, name) do
      nil ->
        call_builtin_with_sub_gsub(name, args, evaluated_args, state)

      %AST.FuncDef{params: params, body: body} ->
        call_user_function(params, body, args, evaluated_args, state)
    end
  end

  defp eval_expr(%AST.GroupExpr{expr: expr}, state) do
    eval_expr(expr, state)
  end

  defp eval_expr(%AST.GetlineExpr{}, state) do
    {0, state}
  end

  defp eval_expr(%AST.PipeGetline{}, state) do
    {0, state}
  end

  # ---------------------------------------------------------------------------
  # Builtin calls with special sub/gsub handling
  # ---------------------------------------------------------------------------

  defp call_builtin_with_sub_gsub(name, raw_args, evaluated_args, state)
       when name in ["sub", "gsub"] do
    {pattern, state} = eval_expr(Enum.at(raw_args, 0), state)
    {replacement, state} = eval_expr(Enum.at(raw_args, 1), state)
    pattern_str = to_string_awk(pattern, state)
    replacement_str = to_string_awk(replacement, state)

    target_arg = Enum.at(raw_args, 2)

    case target_arg do
      nil ->
        regex = compile_regex(pattern_str)
        repl = awk_sub_replacement(replacement_str)

        {count, new_record} =
          if name == "sub" do
            do_sub(regex, repl, state.record)
          else
            do_gsub(regex, repl, state.record)
          end

        state = set_field(state, 0, new_record)
        {count, state}

      %AST.Variable{name: var_name} ->
        current = Map.get(state.variables, var_name, "")
        regex = compile_regex(pattern_str)
        repl = awk_sub_replacement(replacement_str)

        {count, new_val} =
          if name == "sub" do
            do_sub(regex, repl, to_string_awk(current, state))
          else
            do_gsub(regex, repl, to_string_awk(current, state))
          end

        state = %{state | variables: Map.put(state.variables, var_name, new_val)}
        {count, state}

      %AST.FieldRef{expr: idx_expr} ->
        {idx, state} = eval_expr(idx_expr, state)
        n = to_integer(idx)
        current = get_field(state, n)
        regex = compile_regex(pattern_str)
        repl = awk_sub_replacement(replacement_str)

        {count, new_val} =
          if name == "sub" do
            do_sub(regex, repl, current)
          else
            do_gsub(regex, repl, current)
          end

        state = set_field(state, n, new_val)
        {count, state}

      _ ->
        Builtins.call(name, evaluated_args, state)
    end
  end

  defp call_builtin_with_sub_gsub(name, _raw_args, evaluated_args, state) do
    Builtins.call(name, evaluated_args, state)
  end

  defp do_sub(regex, replacement, str) do
    case Regex.run(regex, str, return: :index) do
      nil ->
        {0, str}

      [{pos, len} | _] ->
        matched = binary_part(str, pos, len)
        before = binary_part(str, 0, pos)
        after_part = binary_part(str, pos + len, byte_size(str) - pos - len)
        replaced = String.replace(replacement, "\\0", matched)
        {1, before <> replaced <> after_part}
    end
  end

  defp do_gsub(regex, replacement, str) do
    matches = Regex.scan(regex, str, return: :index)

    if matches == [] do
      {0, str}
    else
      new_str =
        Regex.replace(regex, str, fn matched ->
          String.replace(replacement, "\\0", matched)
        end)

      {length(matches), new_str}
    end
  end

  defp awk_sub_replacement(repl) do
    repl
    |> String.replace("&", "\\0")
    |> String.replace("\\\\", "\\")
  end

  # ---------------------------------------------------------------------------
  # User-defined function calls
  # ---------------------------------------------------------------------------

  defp call_user_function(params, body, raw_args, evaluated_args, state) do
    saved_vars = state.variables

    state =
      params
      |> Enum.with_index()
      |> Enum.reduce(state, fn {param, idx}, st ->
        raw_arg = Enum.at(raw_args, idx)

        case raw_arg do
          %AST.Variable{name: arr_name} when is_map_key(st.arrays, arr_name) ->
            st

          _ ->
            val = Enum.at(evaluated_args, idx, "")
            %{st | variables: Map.put(st.variables, param, val)}
        end
      end)

    {return_val, state} =
      try do
        state = exec_block(body, state)
        {"", state}
      catch
        {:return, val, st} -> {val, st}
      end

    restored_vars =
      Enum.reduce(Map.keys(saved_vars), state.variables, fn key, vars ->
        if Map.has_key?(saved_vars, key) do
          Map.put(vars, key, Map.get(saved_vars, key))
        else
          vars
        end
      end)

    local_params = MapSet.new(params)

    restored_vars =
      Enum.reduce(Map.keys(restored_vars), restored_vars, fn key, vars ->
        if MapSet.member?(local_params, key) and not Map.has_key?(saved_vars, key) do
          Map.delete(vars, key)
        else
          vars
        end
      end)

    {return_val, %{state | variables: restored_vars}}
  end

  # ---------------------------------------------------------------------------
  # Variable resolution
  # ---------------------------------------------------------------------------

  defp resolve_variable("NR", state), do: state.nr
  defp resolve_variable("NF", state), do: state.nf
  defp resolve_variable("FNR", state), do: state.fnr
  defp resolve_variable("FS", state), do: state.fs
  defp resolve_variable("RS", state), do: state.rs
  defp resolve_variable("OFS", state), do: state.ofs
  defp resolve_variable("ORS", state), do: state.ors
  defp resolve_variable("OFMT", state), do: state.ofmt
  defp resolve_variable("CONVFMT", state), do: state.convfmt
  defp resolve_variable("SUBSEP", state), do: state.subsep
  defp resolve_variable("FILENAME", state), do: state.filename

  defp resolve_variable(name, state) do
    Map.get(state.variables, name, "")
  end

  defp assign_target(%AST.Variable{name: name}, value, state) do
    assign_variable(name, value, state)
  end

  defp assign_target(%AST.FieldRef{expr: expr}, value, state) do
    {idx, state} = eval_expr(expr, state)
    set_field(state, to_integer(idx), value)
  end

  defp assign_target(%AST.ArrayRef{name: name, indices: indices}, value, state) do
    {key, state} = eval_array_key(indices, state)
    arr = Map.get(state.arrays, name, %{})
    arr = Map.put(arr, key, value)
    %{state | arrays: Map.put(state.arrays, name, arr)}
  end

  defp assign_target(_, _value, state), do: state

  defp assign_variable("FS", value, state), do: %{state | fs: to_string_awk(value, state)}
  defp assign_variable("RS", value, state), do: %{state | rs: to_string_awk(value, state)}
  defp assign_variable("OFS", value, state), do: %{state | ofs: to_string_awk(value, state)}
  defp assign_variable("ORS", value, state), do: %{state | ors: to_string_awk(value, state)}
  defp assign_variable("NR", value, state), do: %{state | nr: to_integer(value)}
  defp assign_variable("NF", value, state), do: %{state | nf: to_integer(value)}
  defp assign_variable("FNR", value, state), do: %{state | fnr: to_integer(value)}
  defp assign_variable("OFMT", value, state), do: %{state | ofmt: to_string_awk(value, state)}
  defp assign_variable("CONVFMT", value, state), do: %{state | convfmt: to_string_awk(value, state)}
  defp assign_variable("SUBSEP", value, state), do: %{state | subsep: to_string_awk(value, state)}
  defp assign_variable("FILENAME", value, state), do: %{state | filename: to_string_awk(value, state)}

  defp assign_variable(name, value, state) do
    %{state | variables: Map.put(state.variables, name, value)}
  end

  # ---------------------------------------------------------------------------
  # Array key computation
  # ---------------------------------------------------------------------------

  defp eval_array_key(indices, state) do
    {vals, state} = eval_expr_list(indices, state)
    key = vals |> Enum.map(&to_string_awk(&1, state)) |> Enum.join(state.subsep)
    {key, state}
  end

  # ---------------------------------------------------------------------------
  # Binary operators
  # ---------------------------------------------------------------------------

  defp eval_binary_op(:add, l, r), do: to_number(l) + to_number(r)
  defp eval_binary_op(:subtract, l, r), do: to_number(l) - to_number(r)
  defp eval_binary_op(:multiply, l, r), do: to_number(l) * to_number(r)

  defp eval_binary_op(:divide, l, r) do
    divisor = to_number(r)
    if divisor == 0, do: raise("AWK: division by zero"), else: to_number(l) / divisor
  end

  defp eval_binary_op(:modulo, l, r) do
    divisor = to_number(r)
    if divisor == 0, do: raise("AWK: division by zero"), else: rem(to_integer_val(l), to_integer_val(r))
  end

  defp eval_binary_op(:power, l, r), do: :math.pow(to_number(l), to_number(r))

  defp eval_binary_op(:less, l, r), do: bool_to_int(compare(l, r) < 0)
  defp eval_binary_op(:less_eq, l, r), do: bool_to_int(compare(l, r) <= 0)
  defp eval_binary_op(:equal, l, r), do: bool_to_int(compare(l, r) == 0)
  defp eval_binary_op(:not_equal, l, r), do: bool_to_int(compare(l, r) != 0)
  defp eval_binary_op(:greater, l, r), do: bool_to_int(compare(l, r) > 0)
  defp eval_binary_op(:greater_eq, l, r), do: bool_to_int(compare(l, r) >= 0)

  defp compare(l, r) when is_number(l) and is_number(r), do: cond_compare(l, r)

  defp compare(l, r) do
    if looks_numeric?(l) and looks_numeric?(r) do
      cond_compare(to_number(l), to_number(r))
    else
      str_l = if is_binary(l), do: l, else: to_string(l)
      str_r = if is_binary(r), do: r, else: to_string(r)

      cond do
        str_l < str_r -> -1
        str_l > str_r -> 1
        true -> 0
      end
    end
  end

  defp cond_compare(a, b) do
    cond do
      a < b -> -1
      a > b -> 1
      true -> 0
    end
  end

  defp looks_numeric?(v) when is_number(v), do: true

  defp looks_numeric?(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {_, ""} -> true
      {_, _rest} -> false
      :error -> false
    end
  end

  defp looks_numeric?(_), do: false

  # ---------------------------------------------------------------------------
  # Compound assignment operators
  # ---------------------------------------------------------------------------

  defp apply_compound_op(:plus_eq, l, r), do: to_number(l) + to_number(r)
  defp apply_compound_op(:minus_eq, l, r), do: to_number(l) - to_number(r)
  defp apply_compound_op(:times_eq, l, r), do: to_number(l) * to_number(r)

  defp apply_compound_op(:div_eq, l, r) do
    divisor = to_number(r)
    if divisor == 0, do: raise("AWK: division by zero"), else: to_number(l) / divisor
  end

  defp apply_compound_op(:mod_eq, l, r) do
    divisor = to_number(r)
    if divisor == 0, do: raise("AWK: division by zero"), else: rem(to_integer_val(l), to_integer_val(r))
  end

  defp apply_compound_op(:pow_eq, l, r), do: :math.pow(to_number(l), to_number(r))

  # ---------------------------------------------------------------------------
  # Type coercion
  # ---------------------------------------------------------------------------

  defp to_number(v) when is_number(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, _} -> if trunc(n) == n, do: trunc(n), else: n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp to_integer(v), do: trunc(to_number(v))

  defp to_integer_val(v) when is_integer(v), do: v
  defp to_integer_val(v), do: trunc(to_number(v))

  defp to_string_awk(v, _state) when is_binary(v), do: v
  defp to_string_awk(v, _state) when is_integer(v), do: Integer.to_string(v)

  defp to_string_awk(v, state) when is_float(v) do
    if trunc(v) == v and abs(v) < 1.0e15 do
      Integer.to_string(trunc(v))
    else
      :io_lib.format(to_charlist(state.ofmt), [v]) |> to_string()
    end
  end

  defp to_string_awk(_, _), do: ""

  defp truthy?(0), do: false
  defp truthy?(0.0), do: false
  defp truthy?(""), do: false
  defp truthy?("0"), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  # ---------------------------------------------------------------------------
  # Regex helpers
  # ---------------------------------------------------------------------------

  defp compile_regex(%Regex{} = r), do: r

  defp compile_regex(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, r} -> r
      {:error, _} -> ~r/(?!)/
    end
  end

  defp compile_regex(other), do: compile_regex(to_string(other))

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp eval_expr_list(exprs, state) do
    Enum.reduce(exprs, {[], state}, fn expr, {acc, st} ->
      {val, st} = eval_expr(expr, st)
      {acc ++ [val], st}
    end)
  end
end
