defmodule AWK.Parser do
  @moduledoc """
  Recursive descent parser for AWK programs.

  Transforms a list of tokens from `AWK.Tokenizer.tokenize/1` into an
  `AWK.AST.Program` struct. The parser handles all AWK language constructs
  including expression precedence, implicit string concatenation, range
  patterns, and newline-significance rules.

  ## Expression Precedence (low to high)

  1. Assignment (`= += -= *= /= %= ^=`) -- right-associative
  2. Ternary (`? :`)
  3. Logical OR (`||`)
  4. Logical AND (`&&`)
  5. Array membership (`in`)
  6. Match (`~ !~`)
  7. Comparison (`< <= > >= == !=`)
  8. Concatenation (implicit juxtaposition)
  9. Addition (`+ -`)
  10. Multiplication (`* / %`)
  11. Exponentiation (`^`) -- right-associative
  12. Unary (`! + - ++ -- $`)
  13. Postfix (`++ --`)
  14. Primary (literals, identifiers, function calls, getline, grouped expressions)
  """

  alias AWK.AST
  alias AWK.Error.ParseError

  defstruct [:tokens, :pos]

  @doc """
  Parses a list of tokens into an AWK AST program.

  Returns `{:ok, %AWK.AST.Program{}}` on success or `{:error, %AWK.Error.ParseError{}}` on failure.

  ## Examples

      iex> {:ok, tokens} = AWK.Tokenizer.tokenize("{ print $0 }")
      iex> {:ok, %AWK.AST.Program{}} = AWK.Parser.parse(tokens)

  """
  @spec parse([AWK.Tokenizer.token()]) :: {:ok, AST.Program.t()} | {:error, ParseError.t()}
  def parse(tokens) when is_list(tokens) do
    state = %__MODULE__{tokens: List.to_tuple(tokens), pos: 0}

    case parse_program(state) do
      {:ok, program, _state} -> {:ok, program}
      {:error, _} = err -> err
    end
  end

  @doc """
  Parses a list of tokens into an AWK AST program, raising on error.

  Returns `%AWK.AST.Program{}` on success, raises `AWK.Error.ParseError` on failure.
  """
  @spec parse!([AWK.Tokenizer.token()]) :: AST.Program.t()
  def parse!(tokens) when is_list(tokens) do
    case parse(tokens) do
      {:ok, program} -> program
      {:error, error} -> raise error
    end
  end

  defp peek(%__MODULE__{tokens: tokens, pos: pos}) do
    elem(tokens, pos)
  end

  defp peek_type(state) do
    {type, _, _, _} = peek(state)
    type
  end

  defp advance(%__MODULE__{pos: pos} = state) do
    %{state | pos: pos + 1}
  end

  defp expect(state, expected_type) do
    {type, value, line, col} = peek(state)

    if type == expected_type do
      {:ok, {type, value, line, col}, advance(state)}
    else
      {:error,
       %ParseError{
         message: "expected #{expected_type}, got #{type}",
         line: line,
         column: col
       }}
    end
  end

  defp match_token(state, expected_type) do
    case peek_type(state) do
      ^expected_type -> {:ok, advance(state)}
      _ -> :nomatch
    end
  end

  defp skip_terminators(state) do
    case peek_type(state) do
      :newline -> skip_terminators(advance(state))
      :semicolon -> skip_terminators(advance(state))
      _ -> state
    end
  end

  defp skip_newlines(state) do
    case peek_type(state) do
      :newline -> skip_newlines(advance(state))
      _ -> state
    end
  end

  defguardp is_stmt_end(type) when type in [:newline, :semicolon, :rbrace, :eof]

  defp at_stmt_end?(state), do: is_stmt_end(peek_type(state))

  defp token_line_col(state) do
    {_, _, line, col} = peek(state)
    {line, col}
  end

  defp parse_program(state) do
    state = skip_terminators(state)
    do_parse_program(state, [], [], [], [])
  end

  defp do_parse_program(state, begins, rules, ends, funcs) do
    state = skip_terminators(state)

    case peek_type(state) do
      :eof ->
        program = %AST.Program{
          begin_rules: Enum.reverse(begins),
          rules: Enum.reverse(rules),
          end_rules: Enum.reverse(ends),
          functions: Enum.reverse(funcs)
        }

        {:ok, program, state}

      type when type in [:kw_function, :kw_func] ->
        with {:ok, func_def, state} <- parse_func_def(state) do
          do_parse_program(state, begins, rules, ends, [func_def | funcs])
        end

      :kw_begin ->
        with {:ok, rule, state} <- parse_special_rule(state, AST.BeginRule) do
          do_parse_program(state, [rule | begins], rules, ends, funcs)
        end

      :kw_end ->
        with {:ok, rule, state} <- parse_special_rule(state, AST.EndRule) do
          do_parse_program(state, begins, rules, [rule | ends], funcs)
        end

      :kw_beginfile ->
        with {:ok, rule, state} <- parse_special_rule(state, AST.BeginfileRule) do
          do_parse_program(state, begins, [rule | rules], ends, funcs)
        end

      :kw_endfile ->
        with {:ok, rule, state} <- parse_special_rule(state, AST.EndfileRule) do
          do_parse_program(state, begins, [rule | rules], ends, funcs)
        end

      :lbrace ->
        with {:ok, block, state} <- parse_block(state) do
          do_parse_program(state, begins, [%AST.Rule{pattern: nil, action: block} | rules], ends, funcs)
        end

      _ ->
        with {:ok, rule, state} <- parse_pattern_rule(state) do
          do_parse_program(state, begins, [rule | rules], ends, funcs)
        end
    end
  end

  defp parse_special_rule(state, mod) do
    state = advance(state) |> skip_newlines()

    with {:ok, block, state} <- parse_block(state) do
      {:ok, struct!(mod, action: block), state}
    end
  end

  defp parse_pattern_rule(state) do
    with {:ok, pattern, state} <- parse_pattern(state) do
      state = skip_newlines(state)

      case peek_type(state) do
        :comma ->
          parse_range_pattern_rule(state, pattern)

        :lbrace ->
          with {:ok, block, state} <- parse_block(state) do
            {:ok, %AST.Rule{pattern: pattern, action: block}, state}
          end

        _ ->
          {:ok, %AST.Rule{pattern: pattern, action: nil}, state}
      end
    end
  end

  defp parse_range_pattern_rule(state, from_pattern) do
    state = advance(state) |> skip_newlines()

    with {:ok, to_pattern, state} <- parse_pattern(state) do
      range = %AST.RangePattern{from: from_pattern, to: to_pattern}
      state = skip_newlines(state)

      case peek_type(state) do
        :lbrace ->
          with {:ok, block, state} <- parse_block(state) do
            {:ok, %AST.Rule{pattern: range, action: block}, state}
          end

        _ ->
          {:ok, %AST.Rule{pattern: range, action: nil}, state}
      end
    end
  end

  defp parse_pattern(state) do
    case peek_type(state) do
      :regex ->
        {_, value, _, _} = peek(state)
        {:ok, %AST.RegexPattern{regex: value}, advance(state)}

      _ ->
        with {:ok, expr, state} <- parse_expr(state) do
          {:ok, %AST.ExprPattern{expr: expr}, state}
        end
    end
  end

  defp parse_func_def(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, {_, name, _, _}, state} <- expect(state, :ident),
         {:ok, _, state} <- expect(state, :lparen) do
      state = skip_newlines(state)

      {params, state} =
        case peek_type(state) do
          :rparen -> {[], state}
          _ -> parse_param_list(state, [])
        end

      with {:ok, _, state} <- expect(state, :rparen) do
        state = skip_newlines(state)

        with {:ok, block, state} <- parse_block(state) do
          {:ok, %AST.FuncDef{name: name, params: params, body: block}, state}
        end
      end
    end
  end

  defp parse_param_list(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:ident, name, _, _} ->
        state = advance(state) |> skip_newlines()

        case peek_type(state) do
          :comma -> parse_param_list(advance(state), [name | acc])
          _ -> {Enum.reverse([name | acc]), state}
        end

      _ ->
        {Enum.reverse(acc), state}
    end
  end

  defp parse_block(state) do
    with {:ok, _, state} <- expect(state, :lbrace) do
      parse_block_body(skip_terminators(state), [])
    end
  end

  defp parse_block_body(state, acc) do
    state = skip_terminators(state)

    case peek_type(state) do
      :rbrace ->
        {:ok, %AST.Block{statements: Enum.reverse(acc)}, advance(state)}

      :eof ->
        {line, col} = token_line_col(state)
        {:error, %ParseError{message: "unexpected end of input, expected '}'", line: line, column: col}}

      _ ->
        with {:ok, stmt, state} <- parse_statement(state) do
          parse_block_body(skip_terminators(state), [stmt | acc])
        end
    end
  end

  defp parse_statement(state) do
    case peek_type(state) do
      :kw_if -> parse_if_stmt(state)
      :kw_while -> parse_while_stmt(state)
      :kw_do -> parse_do_while_stmt(state)
      :kw_for -> parse_for_stmt(state)
      :kw_print -> parse_print_stmt(state)
      :kw_printf -> parse_printf_stmt(state)
      :kw_delete -> parse_delete_stmt(state)
      :kw_getline -> parse_getline_stmt(state)
      :kw_break -> {:ok, %AST.BreakStmt{}, advance(state)}
      :kw_continue -> {:ok, %AST.ContinueStmt{}, advance(state)}
      :kw_next -> {:ok, %AST.NextStmt{}, advance(state)}
      :kw_nextfile -> {:ok, %AST.NextfileStmt{}, advance(state)}
      :kw_exit -> parse_exit_stmt(state)
      :kw_return -> parse_return_stmt(state)
      :lbrace -> parse_block(state)
      _ -> parse_expr_stmt(state)
    end
  end

  defp parse_if_stmt(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, _, state} <- expect(state, :lparen),
         state = skip_newlines(state),
         {:ok, condition, state} <- parse_expr(state),
         state = skip_newlines(state),
         {:ok, _, state} <- expect(state, :rparen),
         state = skip_newlines(state),
         {:ok, consequent, state} <- parse_statement(state) do
      state = skip_terminators(state)

      case peek_type(state) do
        :kw_else ->
          state = advance(state) |> skip_newlines()

          with {:ok, alternative, state} <- parse_statement(state) do
            {:ok, %AST.IfStmt{condition: condition, consequent: consequent, alternative: alternative}, state}
          end

        _ ->
          {:ok, %AST.IfStmt{condition: condition, consequent: consequent, alternative: nil}, state}
      end
    end
  end

  defp parse_while_stmt(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, _, state} <- expect(state, :lparen),
         state = skip_newlines(state),
         {:ok, condition, state} <- parse_expr(state),
         state = skip_newlines(state),
         {:ok, _, state} <- expect(state, :rparen),
         state = skip_newlines(state),
         {:ok, body, state} <- parse_statement(state) do
      {:ok, %AST.WhileStmt{condition: condition, body: body}, state}
    end
  end

  defp parse_do_while_stmt(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, body, state} <- parse_statement(state) do
      state = skip_terminators(state)

      with {:ok, _, state} <- expect(state, :kw_while),
           state = skip_newlines(state),
           {:ok, _, state} <- expect(state, :lparen),
           state = skip_newlines(state),
           {:ok, condition, state} <- parse_expr(state),
           state = skip_newlines(state),
           {:ok, _, state} <- expect(state, :rparen) do
        {:ok, %AST.DoWhileStmt{body: body, condition: condition}, state}
      end
    end
  end

  defp parse_for_stmt(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, _, state} <- expect(state, :lparen) do
      state = skip_newlines(state)

      if for_in?(state) do
        parse_for_in_body(state)
      else
        parse_for_c_body(state)
      end
    end
  end

  defp for_in?(state) do
    case peek(state) do
      {:ident, _, _, _} -> peek_type(advance(state)) == :kw_in
      _ -> false
    end
  end

  defp parse_for_in_body(state) do
    {:ident, var, _, _} = peek(state)
    state = advance(state)

    with {:ok, _, state} <- expect(state, :kw_in) do
      state = skip_newlines(state)

      with {:ok, {_, array, _, _}, state} <- expect(state, :ident),
           state = skip_newlines(state),
           {:ok, _, state} <- expect(state, :rparen),
           state = skip_newlines(state),
           {:ok, body, state} <- parse_statement(state) do
        {:ok, %AST.ForInStmt{variable: var, array: array, body: body}, state}
      end
    end
  end

  defp parse_for_c_body(state) do
    state = skip_newlines(state)

    with {:ok, init, state} <- parse_optional_for_init(state),
         {:ok, _, state} <- expect(state, :semicolon),
         state = skip_newlines(state),
         {:ok, condition, state} <- parse_optional_expr(:semicolon, state),
         {:ok, _, state} <- expect(state, :semicolon),
         state = skip_newlines(state),
         {:ok, increment, state} <- parse_optional_expr(:rparen, state),
         state = skip_newlines(state),
         {:ok, _, state} <- expect(state, :rparen),
         state = skip_newlines(state),
         {:ok, body, state} <- parse_statement(state) do
      {:ok, %AST.ForStmt{init: init, condition: condition, increment: increment, body: body}, state}
    end
  end

  defp parse_optional_for_init(state) do
    case peek_type(state) do
      :semicolon -> {:ok, nil, state}
      _ -> parse_expr_stmt(state)
    end
  end

  defp parse_optional_expr(terminator, state) do
    case peek_type(state) do
      ^terminator -> {:ok, nil, state}
      _ -> parse_expr(state)
    end
  end

  defp parse_print_stmt(state) do
    state = advance(state)

    if at_stmt_end?(state) do
      {:ok, %AST.PrintStmt{args: [], redirect: nil}, state}
    else
      with {:ok, expr, state} <- parse_non_assignment_expr(state) do
        collect_print_args(state, [expr])
      end
    end
  end

  defp collect_print_args(state, acc) do
    case peek_type(state) do
      :comma ->
        state = advance(state) |> skip_newlines()

        with {:ok, expr, state} <- parse_non_assignment_expr(state) do
          collect_print_args(state, [expr | acc])
        end

      type when type in [:gt, :append, :pipe, :pipe_both] ->
        with {:ok, redirect, state} <- parse_output_redirect(state) do
          {:ok, %AST.PrintStmt{args: Enum.reverse(acc), redirect: redirect}, state}
        end

      _ ->
        {:ok, %AST.PrintStmt{args: Enum.reverse(acc), redirect: nil}, state}
    end
  end

  defp parse_printf_stmt(state) do
    state = advance(state)

    with {:ok, format_expr, state} <- parse_non_assignment_expr(state) do
      {args, state} = collect_printf_args(state, [])

      case peek_type(state) do
        type when type in [:gt, :append, :pipe, :pipe_both] ->
          with {:ok, redirect, state} <- parse_output_redirect(state) do
            {:ok, %AST.PrintfStmt{format: format_expr, args: Enum.reverse(args), redirect: redirect}, state}
          end

        _ ->
          {:ok, %AST.PrintfStmt{format: format_expr, args: Enum.reverse(args), redirect: nil}, state}
      end
    end
  end

  defp collect_printf_args(state, acc) do
    case peek_type(state) do
      :comma ->
        state = advance(state) |> skip_newlines()

        case parse_non_assignment_expr(state) do
          {:ok, expr, state} -> collect_printf_args(state, [expr | acc])
          {:error, _} -> {acc, state}
        end

      _ ->
        {acc, state}
    end
  end

  defp parse_output_redirect(state) do
    case peek_type(state) do
      :gt ->
        state = advance(state) |> skip_newlines()

        with {:ok, target, state} <- parse_non_assignment_expr(state) do
          {:ok, %AST.OutputRedirect{type: :write, target: target}, state}
        end

      :append ->
        state = advance(state) |> skip_newlines()

        with {:ok, target, state} <- parse_non_assignment_expr(state) do
          {:ok, %AST.OutputRedirect{type: :append, target: target}, state}
        end

      type when type in [:pipe, :pipe_both] ->
        state = advance(state) |> skip_newlines()

        with {:ok, target, state} <- parse_non_assignment_expr(state) do
          {:ok, %AST.OutputRedirect{type: :pipe, target: target}, state}
        end

      _ ->
        {line, col} = token_line_col(state)
        {:error, %ParseError{message: "expected output redirect", line: line, column: col}}
    end
  end

  defp parse_delete_stmt(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, {_, name, _, _}, state} <- expect(state, :ident) do
      case peek_type(state) do
        :lbracket ->
          state = advance(state) |> skip_newlines()

          with {:ok, indices, state} <- parse_expr_list(state),
               state = skip_newlines(state),
               {:ok, _, state} <- expect(state, :rbracket) do
            {:ok, %AST.DeleteStmt{target: %AST.ArrayRef{name: name, indices: indices}}, state}
          end

        _ ->
          {:ok, %AST.DeleteStmt{target: %AST.Variable{name: name}}, state}
      end
    end
  end

  defp parse_getline_stmt(state) do
    state = advance(state)

    {variable, state} = maybe_parse_getline_var(state)

    case peek_type(state) do
      :lt ->
        state = advance(state) |> skip_newlines()

        with {:ok, source, state} <- parse_primary(state) do
          {:ok, %AST.GetlineStmt{variable: variable, source: source}, state}
        end

      _ ->
        {:ok, %AST.GetlineStmt{variable: variable, source: nil}, state}
    end
  end

  defp maybe_parse_getline_var(state) do
    case peek(state) do
      {:ident, name, _, _} ->
        next = advance(state)

        case peek_type(next) do
          t when t in [:lt, :newline, :semicolon, :rbrace, :eof] -> {name, next}
          _ -> {nil, state}
        end

      _ ->
        {nil, state}
    end
  end

  defp parse_exit_stmt(state) do
    state = advance(state)

    if at_stmt_end?(state) do
      {:ok, %AST.ExitStmt{status: nil}, state}
    else
      with {:ok, expr, state} <- parse_expr(state) do
        {:ok, %AST.ExitStmt{status: expr}, state}
      end
    end
  end

  defp parse_return_stmt(state) do
    state = advance(state)

    if at_stmt_end?(state) do
      {:ok, %AST.ReturnStmt{value: nil}, state}
    else
      with {:ok, expr, state} <- parse_expr(state) do
        {:ok, %AST.ReturnStmt{value: expr}, state}
      end
    end
  end

  defp parse_expr_stmt(state) do
    with {:ok, expr, state} <- parse_expr(state) do
      {:ok, %AST.ExprStmt{expr: expr}, state}
    end
  end

  defp parse_expr(state), do: parse_assignment(state)

  defp parse_non_assignment_expr(state), do: parse_ternary(state)

  @assignment_ops %{
    assign: :eq,
    add_assign: :plus_eq,
    sub_assign: :minus_eq,
    mul_assign: :times_eq,
    div_assign: :div_eq,
    mod_assign: :mod_eq,
    pow_assign: :pow_eq
  }

  defp parse_assignment(state) do
    with {:ok, left, state} <- parse_ternary(state) do
      type = peek_type(state)

      case Map.get(@assignment_ops, type) do
        nil ->
          {:ok, left, state}

        op ->
          if assignable?(left) do
            state = advance(state) |> skip_newlines()

            with {:ok, right, state} <- parse_assignment(state) do
              {:ok, %AST.Assignment{target: left, op: op, value: right}, state}
            end
          else
            {:ok, left, state}
          end
      end
    end
  end

  defp assignable?(%AST.Variable{}), do: true
  defp assignable?(%AST.ArrayRef{}), do: true
  defp assignable?(%AST.FieldRef{}), do: true
  defp assignable?(_), do: false

  defp parse_ternary(state) do
    with {:ok, condition, state} <- parse_or(state) do
      case peek_type(state) do
        :question ->
          state = advance(state) |> skip_newlines()

          with {:ok, consequent, state} <- parse_assignment(state),
               state = skip_newlines(state),
               {:ok, _, state} <- expect(state, :colon),
               state = skip_newlines(state),
               {:ok, alternative, state} <- parse_assignment(state) do
            {:ok, %AST.TernaryExpr{condition: condition, consequent: consequent, alternative: alternative}, state}
          end

        _ ->
          {:ok, condition, state}
      end
    end
  end

  defp parse_or(state) do
    with {:ok, left, state} <- parse_and(state) do
      parse_or_rest(state, left)
    end
  end

  defp parse_or_rest(state, left) do
    case match_token(state, :or) do
      {:ok, state} ->
        state = skip_newlines(state)

        with {:ok, right, state} <- parse_and(state) do
          parse_or_rest(state, %AST.BinaryExpr{op: :or, left: left, right: right})
        end

      :nomatch ->
        {:ok, left, state}
    end
  end

  defp parse_and(state) do
    with {:ok, left, state} <- parse_in_expr(state) do
      parse_and_rest(state, left)
    end
  end

  defp parse_and_rest(state, left) do
    case match_token(state, :and) do
      {:ok, state} ->
        state = skip_newlines(state)

        with {:ok, right, state} <- parse_in_expr(state) do
          parse_and_rest(state, %AST.BinaryExpr{op: :and, left: left, right: right})
        end

      :nomatch ->
        {:ok, left, state}
    end
  end

  defp parse_in_expr(state) do
    with {:ok, left, state} <- parse_match(state) do
      case peek_type(state) do
        :kw_in ->
          state = advance(state) |> skip_newlines()

          with {:ok, {_, array, _, _}, state} <- expect(state, :ident) do
            index = extract_in_index(left)
            {:ok, %AST.InExpr{index: index, array: array}, state}
          end

        _ ->
          {:ok, left, state}
      end
    end
  end

  defp extract_in_index(%AST.GroupExpr{expr: exprs}) when is_list(exprs), do: exprs
  defp extract_in_index(%AST.GroupExpr{expr: expr}), do: [expr]
  defp extract_in_index(expr), do: [expr]

  defp parse_match(state) do
    with {:ok, left, state} <- parse_comparison(state) do
      case peek_type(state) do
        :match ->
          state = advance(state) |> skip_newlines()

          with {:ok, right, state} <- parse_comparison(state) do
            {:ok, %AST.MatchExpr{expr: left, regex: right, negate: false}, state}
          end

        :not_match ->
          state = advance(state) |> skip_newlines()

          with {:ok, right, state} <- parse_comparison(state) do
            {:ok, %AST.MatchExpr{expr: left, regex: right, negate: true}, state}
          end

        _ ->
          {:ok, left, state}
      end
    end
  end

  @comparison_ops %{
    lt: :less,
    lte: :less_eq,
    gt: :greater,
    gte: :greater_eq,
    eq: :equal,
    neq: :not_equal
  }

  defp parse_comparison(state) do
    with {:ok, left, state} <- parse_concatenation(state) do
      parse_comparison_rest(state, left)
    end
  end

  defp parse_comparison_rest(state, left) do
    type = peek_type(state)

    case Map.get(@comparison_ops, type) do
      nil ->
        maybe_parse_pipe_getline(state, left)

      op ->
        state = advance(state) |> skip_newlines()

        with {:ok, right, state} <- parse_concatenation(state) do
          parse_comparison_rest(state, %AST.BinaryExpr{op: op, left: left, right: right})
        end
    end
  end

  defp maybe_parse_pipe_getline(state, left) do
    case peek_type(state) do
      :pipe ->
        next = advance(state)

        case peek_type(next) do
          :kw_getline ->
            state = advance(next)
            {variable, state} = maybe_parse_getline_target(state)
            {:ok, %AST.PipeGetline{command: left, variable: variable}, state}

          _ ->
            {:ok, left, state}
        end

      _ ->
        {:ok, left, state}
    end
  end

  defp maybe_parse_getline_target(state) do
    case peek(state) do
      {:ident, name, _, _} -> {name, advance(state)}
      _ -> {nil, state}
    end
  end

  @concat_starters [
    :number,
    :string,
    :regex,
    :ident,
    :dollar,
    :lparen,
    :not,
    :increment,
    :decrement,
    :minus,
    :plus,
    :kw_getline
  ]

  defp parse_concatenation(state) do
    with {:ok, left, state} <- parse_addition(state) do
      parse_concatenation_rest(state, left)
    end
  end

  defp parse_concatenation_rest(state, left) do
    type = peek_type(state)

    if type in @concat_starters and not at_stmt_end?(state) do
      with {:ok, right, state} <- parse_addition(state) do
        parse_concatenation_rest(state, %AST.Concatenation{left: left, right: right})
      end
    else
      {:ok, left, state}
    end
  end

  defp parse_addition(state) do
    with {:ok, left, state} <- parse_multiplication(state) do
      parse_addition_rest(state, left)
    end
  end

  defp parse_addition_rest(state, left) do
    case peek_type(state) do
      :plus ->
        state = advance(state) |> skip_newlines()

        with {:ok, right, state} <- parse_multiplication(state) do
          parse_addition_rest(state, %AST.BinaryExpr{op: :add, left: left, right: right})
        end

      :minus ->
        state = advance(state) |> skip_newlines()

        with {:ok, right, state} <- parse_multiplication(state) do
          parse_addition_rest(state, %AST.BinaryExpr{op: :subtract, left: left, right: right})
        end

      _ ->
        {:ok, left, state}
    end
  end

  defp parse_multiplication(state) do
    with {:ok, left, state} <- parse_exponentiation(state) do
      parse_multiplication_rest(state, left)
    end
  end

  defp parse_multiplication_rest(state, left) do
    case peek_type(state) do
      :star ->
        state = advance(state) |> skip_newlines()

        with {:ok, right, state} <- parse_exponentiation(state) do
          parse_multiplication_rest(state, %AST.BinaryExpr{op: :multiply, left: left, right: right})
        end

      :slash ->
        state = advance(state) |> skip_newlines()

        with {:ok, right, state} <- parse_exponentiation(state) do
          parse_multiplication_rest(state, %AST.BinaryExpr{op: :divide, left: left, right: right})
        end

      :percent ->
        state = advance(state) |> skip_newlines()

        with {:ok, right, state} <- parse_exponentiation(state) do
          parse_multiplication_rest(state, %AST.BinaryExpr{op: :modulo, left: left, right: right})
        end

      _ ->
        {:ok, left, state}
    end
  end

  defp parse_exponentiation(state) do
    with {:ok, left, state} <- parse_unary(state) do
      case peek_type(state) do
        :caret ->
          state = advance(state) |> skip_newlines()

          with {:ok, right, state} <- parse_exponentiation(state) do
            {:ok, %AST.BinaryExpr{op: :power, left: left, right: right}, state}
          end

        _ ->
          {:ok, left, state}
      end
    end
  end

  defp parse_unary(state) do
    case peek_type(state) do
      :not ->
        with {:ok, operand, state} <- state |> advance() |> skip_newlines() |> parse_unary() do
          {:ok, %AST.UnaryNot{operand: operand}, state}
        end

      :minus ->
        with {:ok, operand, state} <- state |> advance() |> skip_newlines() |> parse_unary() do
          {:ok, %AST.UnaryMinus{operand: operand}, state}
        end

      :plus ->
        with {:ok, operand, state} <- state |> advance() |> skip_newlines() |> parse_unary() do
          {:ok, %AST.UnaryPlus{operand: operand}, state}
        end

      :increment ->
        with {:ok, operand, state} <- state |> advance() |> parse_unary() do
          {:ok, %AST.PreIncrement{operand: operand}, state}
        end

      :decrement ->
        with {:ok, operand, state} <- state |> advance() |> parse_unary() do
          {:ok, %AST.PreDecrement{operand: operand}, state}
        end

      :dollar ->
        with {:ok, operand, state} <- state |> advance() |> parse_unary() do
          {:ok, %AST.FieldRef{expr: operand}, state}
        end

      _ ->
        parse_postfix(state)
    end
  end

  defp parse_postfix(state) do
    with {:ok, expr, state} <- parse_primary(state) do
      case peek_type(state) do
        :increment -> {:ok, %AST.PostIncrement{operand: expr}, advance(state)}
        :decrement -> {:ok, %AST.PostDecrement{operand: expr}, advance(state)}
        _ -> {:ok, expr, state}
      end
    end
  end

  defp parse_primary(state) do
    case peek(state) do
      {:number, value, _, _} ->
        {:ok, %AST.NumberLiteral{value: value}, advance(state)}

      {:string, value, _, _} ->
        {:ok, %AST.StringLiteral{value: value}, advance(state)}

      {:regex, value, _, _} ->
        {:ok, %AST.RegexLiteral{value: value}, advance(state)}

      {:ident, name, _, _} ->
        parse_ident_primary(advance(state), name)

      {:kw_getline, _, _, _} ->
        parse_getline_expr(state)

      {:lparen, _, _, _} ->
        parse_grouped_expr(state)

      {type, _, line, col} ->
        {:error, %ParseError{message: "unexpected token #{type}", line: line, column: col}}
    end
  end

  defp parse_ident_primary(state, name) do
    case peek_type(state) do
      :lparen -> parse_func_call(state, name)
      :lbracket -> parse_array_ref(state, name)
      _ -> {:ok, %AST.Variable{name: name}, state}
    end
  end

  defp parse_func_call(state, name) do
    state = advance(state) |> skip_newlines()

    case peek_type(state) do
      :rparen ->
        {:ok, %AST.FuncCall{name: name, args: []}, advance(state)}

      _ ->
        with {:ok, args, state} <- parse_expr_list(state),
             state = skip_newlines(state),
             {:ok, _, state} <- expect(state, :rparen) do
          {:ok, %AST.FuncCall{name: name, args: args}, state}
        end
    end
  end

  defp parse_array_ref(state, name) do
    state = advance(state) |> skip_newlines()

    with {:ok, indices, state} <- parse_expr_list(state),
         state = skip_newlines(state),
         {:ok, _, state} <- expect(state, :rbracket) do
      {:ok, %AST.ArrayRef{name: name, indices: indices}, state}
    end
  end

  defp parse_expr_list(state) do
    with {:ok, expr, state} <- parse_expr(state) do
      parse_expr_list_rest(state, [expr])
    end
  end

  defp parse_expr_list_rest(state, acc) do
    case peek_type(state) do
      :comma ->
        state = advance(state) |> skip_newlines()

        with {:ok, expr, state} <- parse_expr(state) do
          parse_expr_list_rest(state, [expr | acc])
        end

      _ ->
        {:ok, Enum.reverse(acc), state}
    end
  end

  defp parse_grouped_expr(state) do
    state = advance(state) |> skip_newlines()

    with {:ok, expr, state} <- parse_expr(state) do
      state = skip_newlines(state)

      case peek_type(state) do
        :comma ->
          with {:ok, exprs, state} <- collect_grouped_exprs(state, [expr]),
               state = skip_newlines(state),
               {:ok, _, state} <- expect(state, :rparen) do
            {:ok, %AST.GroupExpr{expr: exprs}, state}
          end

        _ ->
          with {:ok, _, state} <- expect(state, :rparen) do
            {:ok, %AST.GroupExpr{expr: expr}, state}
          end
      end
    end
  end

  defp collect_grouped_exprs(state, acc) do
    case peek_type(state) do
      :comma ->
        state = advance(state) |> skip_newlines()

        with {:ok, expr, state} <- parse_expr(state) do
          collect_grouped_exprs(state, [expr | acc])
        end

      _ ->
        {:ok, Enum.reverse(acc), state}
    end
  end

  defp parse_getline_expr(state) do
    state = advance(state)

    {variable, state} =
      case peek(state) do
        {:ident, name, _, _} ->
          next = advance(state)

          case peek_type(next) do
            t when t in [:lt, :newline, :semicolon, :rbrace, :eof, :rparen, :rbracket] ->
              {name, next}

            _ ->
              {nil, state}
          end

        _ ->
          {nil, state}
      end

    case peek_type(state) do
      :lt ->
        state = advance(state) |> skip_newlines()

        with {:ok, source, state} <- parse_primary(state) do
          {:ok, %AST.GetlineExpr{variable: variable, source: source}, state}
        end

      _ ->
        {:ok, %AST.GetlineExpr{variable: variable, source: nil}, state}
    end
  end

end
