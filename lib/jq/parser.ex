defmodule JQ.Parser do
  @moduledoc """
  Recursive descent parser for the jq language.

  Converts a list of tokens produced by `JQ.Tokenizer` into an AST
  composed of `JQ.AST` node structs. The parser implements the full
  jq grammar with correct operator precedence and associativity.

  ## Precedence (low to high)

  1. Pipe `|` (right-associative)
  2. Comma `,`
  3. Assignment `=`, `|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`
  4. Binding `as`
  5. Or `or`
  6. And `and`
  7. Comparison `==`, `!=`, `<`, `>`, `<=`, `>=`
  8. Alternative `//`
  9. Addition `+`, `-`
  10. Multiplication `*`, `/`, `%`
  11. Unary `-`
  12. Postfix `?`, `.field`, `[idx]`, `[]`
  13. Primary expressions

  ## Examples

      iex> {:ok, tokens} = JQ.Tokenizer.tokenize(".")
      iex> JQ.Parser.parse(tokens)
      {:ok, %JQ.AST.Identity{}}

      iex> {:ok, tokens} = JQ.Tokenizer.tokenize(".foo | .bar")
      iex> JQ.Parser.parse(tokens)
      {:ok, %JQ.AST.Pipe{
        left: %JQ.AST.Field{name: "foo"},
        right: %JQ.AST.Field{name: "bar"}
      }}
  """

  alias JQ.AST
  alias JQ.Error.ParseError

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{tokens: tuple(), pos: non_neg_integer(), size: non_neg_integer()}
    defstruct [:tokens, :pos, :size]
  end

  @assignment_ops [:assign, :update, :add_assign, :sub_assign, :mul_assign, :div_assign,
                   :mod_assign, :alt_assign]

  @comparison_ops [:eq, :neq, :lt, :gt, :lte, :gte]

  @doc """
  Parses a list of tokens into a jq AST.

  Returns `{:ok, ast}` on success or `{:error, %ParseError{}}` on failure.
  """
  @spec parse([JQ.Tokenizer.token()]) :: {:ok, AST.filter()} | {:error, ParseError.t()}
  def parse(tokens) when is_list(tokens) do
    state = %State{tokens: List.to_tuple(tokens), pos: 0, size: length(tokens)}

    case parse_pipe(state) do
      {:ok, ast, state} ->
        case peek(state) do
          {:eof, _, _, _} -> {:ok, ast}
          {type, _, line, col} -> error("unexpected token #{type}", line, col)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Parses a list of tokens into a jq AST, raising on error.
  """
  @spec parse!([JQ.Tokenizer.token()]) :: AST.filter()
  def parse!(tokens) when is_list(tokens) do
    case parse(tokens) do
      {:ok, ast} -> ast
      {:error, err} -> raise err
    end
  end

  defp peek(%State{tokens: tokens, pos: pos, size: size}) when pos < size do
    elem(tokens, pos)
  end

  defp peek(%State{}) do
    {:eof, nil, 0, 0}
  end

  defp peek_type(state) do
    {type, _, _, _} = peek(state)
    type
  end

  defp advance(%State{pos: pos} = state) do
    %{state | pos: pos + 1}
  end

  defp expect(state, expected_type) do
    {type, value, line, col} = peek(state)

    if type == expected_type do
      {:ok, value, advance(state)}
    else
      error("expected #{expected_type}, got #{type}", line, col)
    end
  end

  defp match_token(state, expected_type) do
    {type, _, _, _} = peek(state)

    if type == expected_type do
      {:ok, advance(state)}
    else
      :nomatch
    end
  end

  defp error(message, line, col) do
    {:error, %ParseError{message: message, line: line, column: col}}
  end

  # -- Pipe (right-associative): comma ("|" comma)*
  defp parse_pipe(state) do
    with {:ok, left, state} <- parse_comma(state) do
      case match_token(state, :pipe) do
        {:ok, state} ->
          with {:ok, right, state} <- parse_pipe(state) do
            {:ok, %AST.Pipe{left: left, right: right}, state}
          end

        :nomatch ->
          {:ok, left, state}
      end
    end
  end

  # -- Comma: assign ("," assign)*
  defp parse_comma(state) do
    with {:ok, left, state} <- parse_assign(state) do
      parse_comma_rest(left, state)
    end
  end

  defp parse_comma_rest(left, state) do
    case match_token(state, :comma) do
      {:ok, state} ->
        with {:ok, right, state} <- parse_assign(state) do
          parse_comma_rest(%AST.Comma{left: left, right: right}, state)
        end

      :nomatch ->
        {:ok, left, state}
    end
  end

  # -- Assignment: binding (("=" | "|=" | "+=" | ...) binding)?
  defp parse_assign(state) do
    with {:ok, left, state} <- parse_binding(state) do
      type = peek_type(state)

      if type in @assignment_ops do
        state = advance(state)
        op = assignment_op(type)

        with {:ok, right, state} <- parse_binding(state) do
          {:ok, %AST.Assign{path: left, op: op, value: right}, state}
        end
      else
        {:ok, left, state}
      end
    end
  end

  defp assignment_op(:assign), do: :assign
  defp assignment_op(:update), do: :update
  defp assignment_op(:add_assign), do: :add
  defp assignment_op(:sub_assign), do: :sub
  defp assignment_op(:mul_assign), do: :mul
  defp assignment_op(:div_assign), do: :div
  defp assignment_op(:mod_assign), do: :mod
  defp assignment_op(:alt_assign), do: :alt

  # -- Binding: or ("as" pattern "|" pipe)?
  defp parse_binding(state) do
    with {:ok, expr, state} <- parse_or(state) do
      case match_token(state, :kw_as) do
        {:ok, state} ->
          parse_as_binding(expr, state)

        :nomatch ->
          {:ok, expr, state}
      end
    end
  end

  defp parse_as_binding(expr, state) do
    case peek(state) do
      {:variable, name, _, _} ->
        state = advance(state)

        with {:ok, state} <- expect_pipe(state),
             {:ok, body, state} <- parse_pipe(state) do
          {:ok, %AST.Binding{expr: expr, var: name, body: body}, state}
        end

      {:lbrace, _, _, _} ->
        with {:ok, patterns, state} <- parse_destructure_pattern(state),
             {:ok, state} <- expect_pipe(state),
             {:ok, body, state} <- parse_pipe(state) do
          {:ok, %AST.PatternBinding{expr: expr, patterns: patterns, body: body}, state}
        end

      {:lbracket, _, _, _} ->
        with {:ok, patterns, state} <- parse_destructure_pattern(state),
             {:ok, state} <- expect_pipe(state),
             {:ok, body, state} <- parse_pipe(state) do
          {:ok, %AST.PatternBinding{expr: expr, patterns: patterns, body: body}, state}
        end

      {type, _, line, col} ->
        error("expected variable or pattern after 'as', got #{type}", line, col)
    end
  end

  defp expect_pipe(state) do
    case expect(state, :pipe) do
      {:ok, _, state} -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  defp parse_destructure_pattern(state) do
    case peek(state) do
      {:lbrace, _, _, _} ->
        state = advance(state)
        with {:ok, pairs, state} <- parse_destruct_object_pairs(state, []) do
          with {:ok, _, state} <- expect(state, :rbrace) do
            {:ok, {:object, pairs}, state}
          end
        end

      {:lbracket, _, _, _} ->
        state = advance(state)
        with {:ok, elems, state} <- parse_destruct_array_elems(state, []) do
          with {:ok, _, state} <- expect(state, :rbracket) do
            {:ok, {:array, elems}, state}
          end
        end

      {type, _, line, col} ->
        error("expected destructure pattern, got #{type}", line, col)
    end
  end

  defp parse_destruct_object_pairs(state, acc) do
    with {:ok, pair, state} <- parse_destruct_object_pair(state) do
      acc = [pair | acc]

      case match_token(state, :comma) do
        {:ok, state} -> parse_destruct_object_pairs(state, acc)
        :nomatch -> {:ok, Enum.reverse(acc), state}
      end
    end
  end

  defp parse_destruct_object_pair(state) do
    case peek(state) do
      {:ident, name, _, _} ->
        state = advance(state)

        case match_token(state, :colon) do
          {:ok, state} ->
            with {:ok, pattern, state} <- parse_destruct_value(state) do
              {:ok, {name, pattern}, state}
            end

          :nomatch ->
            {:ok, {name, {:variable, "$" <> name}}, state}
        end

      {:variable, name, _, _} ->
        state = advance(state)
        {:ok, {String.trim_leading(name, "$"), {:variable, name}}, state}

      {type, _, line, col} ->
        error("expected identifier or variable in object pattern, got #{type}", line, col)
    end
  end

  defp parse_destruct_value(state) do
    case peek(state) do
      {:variable, name, _, _} ->
        {:ok, {:variable, name}, advance(state)}

      {:lbrace, _, _, _} ->
        parse_destructure_pattern(state)

      {:lbracket, _, _, _} ->
        parse_destructure_pattern(state)

      {type, _, line, col} ->
        error("expected variable or nested pattern, got #{type}", line, col)
    end
  end

  defp parse_destruct_array_elems(state, acc) do
    with {:ok, elem, state} <- parse_destruct_value(state) do
      acc = [elem | acc]

      case match_token(state, :comma) do
        {:ok, state} -> parse_destruct_array_elems(state, acc)
        :nomatch -> {:ok, Enum.reverse(acc), state}
      end
    end
  end

  # -- Or: and ("or" and)*
  defp parse_or(state) do
    with {:ok, left, state} <- parse_and(state) do
      parse_or_rest(left, state)
    end
  end

  defp parse_or_rest(left, state) do
    case match_token(state, :kw_or) do
      {:ok, state} ->
        with {:ok, right, state} <- parse_and(state) do
          parse_or_rest(%AST.LogicalOr{left: left, right: right}, state)
        end

      :nomatch ->
        {:ok, left, state}
    end
  end

  # -- And: comparison ("and" comparison)*
  defp parse_and(state) do
    with {:ok, left, state} <- parse_comparison(state) do
      parse_and_rest(left, state)
    end
  end

  defp parse_and_rest(left, state) do
    case match_token(state, :kw_and) do
      {:ok, state} ->
        with {:ok, right, state} <- parse_comparison(state) do
          parse_and_rest(%AST.LogicalAnd{left: left, right: right}, state)
        end

      :nomatch ->
        {:ok, left, state}
    end
  end

  # -- Comparison: alternative (("==" | "!=" | ...) alternative)?
  defp parse_comparison(state) do
    with {:ok, left, state} <- parse_alternative(state) do
      type = peek_type(state)

      if type in @comparison_ops do
        state = advance(state)

        with {:ok, right, state} <- parse_alternative(state) do
          {:ok, %AST.Comparison{op: type, left: left, right: right}, state}
        end
      else
        {:ok, left, state}
      end
    end
  end

  # -- Alternative: addition ("//" addition)*
  defp parse_alternative(state) do
    with {:ok, left, state} <- parse_addition(state) do
      parse_alternative_rest(left, state)
    end
  end

  defp parse_alternative_rest(left, state) do
    case match_token(state, :alt) do
      {:ok, state} ->
        with {:ok, right, state} <- parse_addition(state) do
          node = %AST.FuncCall{name: "//", args: [left, right]}
          parse_alternative_rest(node, state)
        end

      :nomatch ->
        {:ok, left, state}
    end
  end

  # -- Addition: multiplication (("+" | "-") multiplication)*
  defp parse_addition(state) do
    with {:ok, left, state} <- parse_multiplication(state) do
      parse_addition_rest(left, state)
    end
  end

  defp parse_addition_rest(left, state) do
    type = peek_type(state)

    case type do
      t when t in [:plus, :minus] ->
        state = advance(state)
        op = if t == :plus, do: :add, else: :sub

        with {:ok, right, state} <- parse_multiplication(state) do
          parse_addition_rest(%AST.Arithmetic{op: op, left: left, right: right}, state)
        end

      _ ->
        {:ok, left, state}
    end
  end

  # -- Multiplication: unary (("*" | "/" | "%") unary)*
  defp parse_multiplication(state) do
    with {:ok, left, state} <- parse_unary(state) do
      parse_multiplication_rest(left, state)
    end
  end

  defp parse_multiplication_rest(left, state) do
    type = peek_type(state)

    case type do
      t when t in [:star, :slash, :percent] ->
        state = advance(state)
        op = mul_op(t)

        with {:ok, right, state} <- parse_unary(state) do
          parse_multiplication_rest(%AST.Arithmetic{op: op, left: left, right: right}, state)
        end

      _ ->
        {:ok, left, state}
    end
  end

  defp mul_op(:star), do: :mul
  defp mul_op(:slash), do: :div
  defp mul_op(:percent), do: :mod

  # -- Unary: "-" unary | postfix
  defp parse_unary(state) do
    case peek_type(state) do
      :minus ->
        state = advance(state)

        with {:ok, expr, state} <- parse_unary(state) do
          {:ok, %AST.Negate{expr: expr}, state}
        end

      _ ->
        parse_postfix(state)
    end
  end

  # -- Postfix: primary suffix*
  # suffix = "?" | "." ident | "." string | "[" expr "]" | "[" "]" | "[" expr ":" expr "]"
  defp parse_postfix(state) do
    with {:ok, expr, state} <- parse_primary(state) do
      parse_postfix_suffix(expr, state)
    end
  end

  defp parse_postfix_suffix(expr, state) do
    case peek(state) do
      {:question, _, _, _} ->
        state = advance(state)
        parse_postfix_suffix(%AST.Optional{expr: expr}, state)

      {:try_alt, _, _, _} ->
        state = advance(state)
        with {:ok, alt, state} <- parse_addition(state) do
          node = %AST.FuncCall{name: "//", args: [%AST.TryCatch{try_expr: expr, catch_expr: nil}, alt]}
          parse_postfix_suffix(node, state)
        end

      {:dot, _, _, _} ->
        parse_postfix_dot(expr, state)

      {:lbracket, _, _, _} ->
        with {:ok, suffix, state} <- parse_bracket_suffix(state) do
          node = apply_bracket_suffix(expr, suffix)
          parse_postfix_suffix(node, state)
        end

      _ ->
        {:ok, expr, state}
    end
  end

  defp parse_postfix_dot(expr, state) do
    state = advance(state)

    case peek(state) do
      {:ident, name, _, _} ->
        state = advance(state)
        node = %AST.Pipe{left: expr, right: %AST.Field{name: name}}
        parse_postfix_suffix(node, state)

      {:string, parts, _, _} ->
        state = advance(state)
        field_expr = string_parts_to_ast(parts)

        case field_expr do
          %AST.Literal{value: name} when is_binary(name) ->
            node = %AST.Pipe{left: expr, right: %AST.Field{name: name}}
            parse_postfix_suffix(node, state)

          interp ->
            node = %AST.Pipe{left: expr, right: %AST.Index{expr: interp}}
            parse_postfix_suffix(node, state)
        end

      _ ->
        {:ok, expr, state}
    end
  end

  defp parse_bracket_suffix(state) do
    state = advance(state)

    case peek(state) do
      {:rbracket, _, _, _} ->
        {:ok, :iterate, advance(state)}

      {:colon, _, _, _} ->
        state = advance(state)

        with {:ok, to, state} <- parse_pipe(state),
             {:ok, _, state} <- expect(state, :rbracket) do
          {:ok, {:slice, nil, to}, state}
        end

      _ ->
        with {:ok, expr, state} <- parse_pipe(state) do
          case peek(state) do
            {:colon, _, _, _} ->
              state = advance(state)

              case peek(state) do
                {:rbracket, _, _, _} ->
                  {:ok, {:slice, expr, nil}, advance(state)}

                _ ->
                  with {:ok, to, state} <- parse_pipe(state),
                       {:ok, _, state} <- expect(state, :rbracket) do
                    {:ok, {:slice, expr, to}, state}
                  end
              end

            {:rbracket, _, _, _} ->
              {:ok, {:index, expr}, advance(state)}

            {type, _, line, col} ->
              error("expected ']' or ':', got #{type}", line, col)
          end
        end
    end
  end

  defp apply_bracket_suffix(expr, :iterate) do
    %AST.Pipe{left: expr, right: %AST.Iterate{}}
  end

  defp apply_bracket_suffix(expr, {:index, idx}) do
    %AST.Pipe{left: expr, right: %AST.Index{expr: idx}}
  end

  defp apply_bracket_suffix(expr, {:slice, from, to}) do
    %AST.Pipe{left: expr, right: %AST.Slice{from: from, to: to}}
  end

  # -- Primary expressions
  defp parse_primary(state) do
    case peek(state) do
      {:dot, _, _, _} ->
        parse_dot(state)

      {:dotdot, _, _, _} ->
        {:ok, %AST.RecurseAll{}, advance(state)}

      {:number, value, _, _} ->
        {:ok, %AST.Literal{value: value}, advance(state)}

      {:string, parts, _, _} ->
        {:ok, string_parts_to_ast(parts), advance(state)}

      {:kw_true, _, _, _} ->
        {:ok, %AST.Literal{value: true}, advance(state)}

      {:kw_false, _, _, _} ->
        {:ok, %AST.Literal{value: false}, advance(state)}

      {:kw_null, _, _, _} ->
        {:ok, %AST.Literal{value: nil}, advance(state)}

      {:variable, name, _, _} ->
        {:ok, %AST.Variable{name: name}, advance(state)}

      {:ident, _name, _, _} ->
        parse_ident_or_call(state)

      {:kw_not, _, _, _} ->
        {:ok, %AST.FuncCall{name: "not", args: []}, advance(state)}

      {:lparen, _, _, _} ->
        parse_grouped(state)

      {:lbracket, _, _, _} ->
        parse_array_construct(state)

      {:lbrace, _, _, _} ->
        parse_object_construct(state)

      {:kw_if, _, _, _} ->
        parse_if(state)

      {:kw_try, _, _, _} ->
        parse_try(state)

      {:kw_reduce, _, _, _} ->
        parse_reduce(state)

      {:kw_foreach, _, _, _} ->
        parse_foreach(state)

      {:kw_def, _, _, _} ->
        parse_def(state)

      {:kw_label, _, _, _} ->
        parse_label(state)

      {:kw_break, _, _, _} ->
        parse_break(state)

      {:format, name, _, _} ->
        parse_format(name, state)

      {:minus, _, _, _} ->
        parse_unary(state)

      {type, _, line, col} ->
        error("unexpected token #{type}", line, col)
    end
  end

  # -- Dot: "." possibly followed by ident for field access
  defp parse_dot(state) do
    state = advance(state)

    case peek(state) do
      {:ident, name, _, _} ->
        state = advance(state)
        {:ok, %AST.Field{name: name}, state}

      {:string, parts, _, _} ->
        state = advance(state)
        field_expr = string_parts_to_ast(parts)

        case field_expr do
          %AST.Literal{value: name} when is_binary(name) ->
            {:ok, %AST.Field{name: name}, state}

          interp ->
            {:ok, %AST.Index{expr: interp}, state}
        end

      {:lbracket, _, _, _} ->
        with {:ok, suffix, state} <- parse_bracket_suffix(state) do
          node = apply_bracket_suffix(%AST.Identity{}, suffix)
          {:ok, node, state}
        end

      _ ->
        {:ok, %AST.Identity{}, state}
    end
  end

  # -- Identifier or function call
  defp parse_ident_or_call(state) do
    {:ident, name, _, _} = peek(state)
    state = advance(state)

    case match_token(state, :lparen) do
      {:ok, state} ->
        with {:ok, args, state} <- parse_func_args(state),
             {:ok, _, state} <- expect(state, :rparen) do
          {:ok, %AST.FuncCall{name: name, args: args}, state}
        end

      :nomatch ->
        {:ok, %AST.FuncCall{name: name, args: []}, state}
    end
  end

  # Function arguments separated by ";"
  defp parse_func_args(state) do
    case peek_type(state) do
      :rparen ->
        {:ok, [], state}

      _ ->
        with {:ok, first, state} <- parse_pipe(state) do
          parse_func_args_rest([first], state)
        end
    end
  end

  defp parse_func_args_rest(acc, state) do
    case match_token(state, :semicolon) do
      {:ok, state} ->
        with {:ok, arg, state} <- parse_pipe(state) do
          parse_func_args_rest([arg | acc], state)
        end

      :nomatch ->
        {:ok, Enum.reverse(acc), state}
    end
  end

  # -- Grouped expression: "(" expr ")"
  defp parse_grouped(state) do
    state = advance(state)

    with {:ok, expr, state} <- parse_pipe(state),
         {:ok, _, state} <- expect(state, :rparen) do
      {:ok, expr, state}
    end
  end

  # -- Array construction: "[" expr? "]"
  defp parse_array_construct(state) do
    state = advance(state)

    case peek_type(state) do
      :rbracket ->
        {:ok, %AST.ArrayConstruct{expr: nil}, advance(state)}

      _ ->
        with {:ok, expr, state} <- parse_pipe(state),
             {:ok, _, state} <- expect(state, :rbracket) do
          {:ok, %AST.ArrayConstruct{expr: expr}, state}
        end
    end
  end

  # -- Object construction: "{" pairs "}"
  defp parse_object_construct(state) do
    state = advance(state)

    case peek_type(state) do
      :rbrace ->
        {:ok, %AST.ObjectConstruct{pairs: []}, advance(state)}

      _ ->
        with {:ok, pairs, state} <- parse_object_pairs(state),
             {:ok, _, state} <- expect(state, :rbrace) do
          {:ok, %AST.ObjectConstruct{pairs: pairs}, state}
        end
    end
  end

  defp parse_object_pairs(state) do
    with {:ok, pair, state} <- parse_object_pair(state) do
      parse_object_pairs_rest([pair], state)
    end
  end

  defp parse_object_pairs_rest(acc, state) do
    case match_token(state, :comma) do
      {:ok, state} ->
        with {:ok, pair, state} <- parse_object_pair(state) do
          parse_object_pairs_rest([pair | acc], state)
        end

      :nomatch ->
        {:ok, Enum.reverse(acc), state}
    end
  end

  defp parse_object_pair(state) do
    case peek(state) do
      {:ident, name, _, _} ->
        parse_object_ident_pair(name, state)

      {:variable, name, _, _} ->
        state = advance(state)

        case match_token(state, :colon) do
          {:ok, state} ->
            with {:ok, value, state} <- parse_pipe(state) do
              {:ok, {%AST.Literal{value: String.trim_leading(name, "$")}, value}, state}
            end

          :nomatch ->
            var_name = String.trim_leading(name, "$")
            {:ok, {%AST.Literal{value: var_name}, %AST.Variable{name: name}}, state}
        end

      {:format, name, _, _} ->
        state = advance(state)

        case match_token(state, :colon) do
          {:ok, state} ->
            with {:ok, value, state} <- parse_pipe(state) do
              {:ok, {%AST.Literal{value: name}, value}, state}
            end

          :nomatch ->
            {:ok, {%AST.Literal{value: name}, %AST.Format{name: name, expr: nil}}, state}
        end

      {:string, parts, _, _} ->
        state = advance(state)
        key = string_parts_to_ast(parts)

        with {:ok, _, state} <- expect(state, :colon),
             {:ok, value, state} <- parse_pipe(state) do
          {:ok, {key, value}, state}
        end

      {:lparen, _, _, _} ->
        state = advance(state)

        with {:ok, key, state} <- parse_pipe(state),
             {:ok, _, state} <- expect(state, :rparen),
             {:ok, _, state} <- expect(state, :colon),
             {:ok, value, state} <- parse_pipe(state) do
          {:ok, {key, value}, state}
        end

      {type, _, line, col} ->
        error("expected object key, got #{type}", line, col)
    end
  end

  defp parse_object_ident_pair(name, state) do
    state = advance(state)

    case match_token(state, :colon) do
      {:ok, state} ->
        with {:ok, value, state} <- parse_pipe(state) do
          {:ok, {%AST.Literal{value: name}, value}, state}
        end

      :nomatch ->
        {:ok, {%AST.Literal{value: name}, %AST.Field{name: name}}, state}
    end
  end

  # -- If-then-elif-else-end
  defp parse_if(state) do
    state = advance(state)

    with {:ok, cond_expr, state} <- parse_pipe(state),
         {:ok, _, state} <- expect(state, :kw_then),
         {:ok, then_expr, state} <- parse_pipe(state),
         {:ok, elifs, else_expr, state} <- parse_elif_chain(state),
         {:ok, _, state} <- expect(state, :kw_end) do
      {:ok,
       %AST.IfThenElse{
         condition: cond_expr,
         then_branch: then_expr,
         elifs: elifs,
         else_branch: else_expr
       }, state}
    end
  end

  defp parse_elif_chain(state) do
    case peek_type(state) do
      :kw_elif ->
        state = advance(state)

        with {:ok, cond_expr, state} <- parse_pipe(state),
             {:ok, _, state} <- expect(state, :kw_then),
             {:ok, then_expr, state} <- parse_pipe(state),
             {:ok, rest_elifs, else_expr, state} <- parse_elif_chain(state) do
          {:ok, [{cond_expr, then_expr} | rest_elifs], else_expr, state}
        end

      :kw_else ->
        state = advance(state)

        with {:ok, else_expr, state} <- parse_pipe(state) do
          {:ok, [], else_expr, state}
        end

      _ ->
        {:ok, [], nil, state}
    end
  end

  # -- Try-catch
  defp parse_try(state) do
    state = advance(state)

    with {:ok, try_expr, state} <- parse_postfix(state) do
      case match_token(state, :kw_catch) do
        {:ok, state} ->
          with {:ok, catch_expr, state} <- parse_postfix(state) do
            {:ok, %AST.TryCatch{try_expr: try_expr, catch_expr: catch_expr}, state}
          end

        :nomatch ->
          {:ok, %AST.TryCatch{try_expr: try_expr, catch_expr: nil}, state}
      end
    end
  end

  # -- Reduce: "reduce" expr "as" $var "(" init ";" update ")"
  defp parse_reduce(state) do
    state = advance(state)

    with {:ok, expr, state} <- parse_postfix(state),
         {:ok, _, state} <- expect(state, :kw_as),
         {:ok, var, state} <- expect_variable(state),
         {:ok, _, state} <- expect(state, :lparen),
         {:ok, init, state} <- parse_pipe(state),
         {:ok, _, state} <- expect(state, :semicolon),
         {:ok, update, state} <- parse_pipe(state),
         {:ok, _, state} <- expect(state, :rparen) do
      {:ok, %AST.Reduce{expr: expr, var: var, init: init, update: update}, state}
    end
  end

  # -- Foreach: "foreach" expr "as" $var "(" init ";" update (";" extract)? ")"
  defp parse_foreach(state) do
    state = advance(state)

    with {:ok, expr, state} <- parse_postfix(state),
         {:ok, _, state} <- expect(state, :kw_as),
         {:ok, var, state} <- expect_variable(state),
         {:ok, _, state} <- expect(state, :lparen),
         {:ok, init, state} <- parse_pipe(state),
         {:ok, _, state} <- expect(state, :semicolon),
         {:ok, update, state} <- parse_pipe(state) do
      case match_token(state, :semicolon) do
        {:ok, state} ->
          with {:ok, extract, state} <- parse_pipe(state),
               {:ok, _, state} <- expect(state, :rparen) do
            {:ok,
             %AST.Foreach{expr: expr, var: var, init: init, update: update, extract: extract},
             state}
          end

        :nomatch ->
          with {:ok, _, state} <- expect(state, :rparen) do
            {:ok,
             %AST.Foreach{expr: expr, var: var, init: init, update: update, extract: nil}, state}
          end
      end
    end
  end

  defp parse_def(state) do
    state = advance(state)

    with {:ok, name, state} <- expect_ident(state),
         {:ok, params, state} <- parse_optional_def_params(state),
         {:ok, _, state} <- expect(state, :colon),
         {:ok, body, state} <- parse_pipe(state),
         {:ok, _, state} <- expect(state, :semicolon),
         {:ok, next, state} <- parse_pipe(state) do
      {:ok, %AST.FuncDef{name: name, params: params, body: body, next: next}, state}
    end
  end

  defp parse_optional_def_params(state) do
    case match_token(state, :lparen) do
      {:ok, state} ->
        with {:ok, params, state} <- parse_def_params(state),
             {:ok, _, state} <- expect(state, :rparen) do
          {:ok, params, state}
        end

      :nomatch ->
        {:ok, [], state}
    end
  end

  defp parse_def_params(state) do
    case peek_type(state) do
      :rparen ->
        {:ok, [], state}

      _ ->
        with {:ok, first, state} <- parse_def_param(state) do
          parse_def_params_rest([first], state)
        end
    end
  end

  defp parse_def_params_rest(acc, state) do
    case match_token(state, :semicolon) do
      {:ok, state} ->
        with {:ok, param, state} <- parse_def_param(state) do
          parse_def_params_rest([param | acc], state)
        end

      :nomatch ->
        {:ok, Enum.reverse(acc), state}
    end
  end

  defp parse_def_param(state) do
    case peek(state) do
      {:ident, name, _, _} ->
        {:ok, name, advance(state)}

      {:variable, name, _, _} ->
        {:ok, name, advance(state)}

      {type, _, line, col} ->
        error("expected parameter name, got #{type}", line, col)
    end
  end

  # -- Label: "label" $var "|" body
  defp parse_label(state) do
    state = advance(state)

    with {:ok, var, state} <- expect_variable(state),
         {:ok, state} <- expect_pipe(state),
         {:ok, body, state} <- parse_pipe(state) do
      {:ok, %AST.Label{name: var, body: body}, state}
    end
  end

  # -- Break: "break" $var
  defp parse_break(state) do
    state = advance(state)

    with {:ok, var, state} <- expect_variable(state) do
      {:ok, %AST.Break{name: var}, state}
    end
  end

  # -- Format: "@name" optionally followed by a string
  defp parse_format(name, state) do
    state = advance(state)

    case peek(state) do
      {:string, parts, _, _} ->
        state = advance(state)
        str_ast = string_parts_to_ast(parts)
        {:ok, %AST.Format{name: name, expr: str_ast}, state}

      _ ->
        {:ok, %AST.Format{name: name, expr: nil}, state}
    end
  end

  # -- Helpers

  defp expect_variable(state) do
    case peek(state) do
      {:variable, name, _, _} -> {:ok, name, advance(state)}
      {type, _, line, col} -> error("expected variable, got #{type}", line, col)
    end
  end

  defp expect_ident(state) do
    case peek(state) do
      {:ident, name, _, _} -> {:ok, name, advance(state)}
      {type, _, line, col} -> error("expected identifier, got #{type}", line, col)
    end
  end

  defp string_parts_to_ast([]) do
    %AST.Literal{value: ""}
  end

  defp string_parts_to_ast([{:literal, text}]) do
    %AST.Literal{value: text}
  end

  defp string_parts_to_ast(parts) do
    parsed_parts =
      Enum.map(parts, fn
        {:literal, text} ->
          {:literal, text}

        {:interp, tokens} ->
          tokens_with_eof = tokens ++ [{:eof, nil, 0, 0}]
          inner_state = %State{tokens: List.to_tuple(tokens_with_eof), pos: 0, size: length(tokens_with_eof)}

          case parse_pipe(inner_state) do
            {:ok, ast, _} -> {:interp, ast}
            {:error, _} -> {:literal, ""}
          end
      end)

    %AST.StringInterpolation{parts: parsed_parts}
  end
end
