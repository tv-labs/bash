defmodule Bash.Parser.Arithmetic do
  @moduledoc """
  Parser for bash arithmetic expressions.

  Parses expressions like "x + 1", "a++ * b--", "x = y ? 1 : 0"
  into an AST that can be evaluated by `Bash.AST.Arithmetic`.

  ## Operator Precedence (lowest to highest)

  1. `,` (comma/sequence)
  2. `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `<<=`, `>>=`, `&=`, `^=`, `|=` (assignment)
  3. `? :` (ternary)
  4. `||` (logical OR)
  5. `&&` (logical AND)
  6. `|` (bitwise OR)
  7. `^` (bitwise XOR)
  8. `&` (bitwise AND)
  9. `==`, `!=` (equality)
  10. `<`, `<=`, `>`, `>=` (comparison)
  11. `<<`, `>>` (bit shift)
  12. `+`, `-` (addition/subtraction)
  13. `*`, `/`, `%` (multiplication/division/modulo)
  14. `**` (exponentiation)
  15. `!`, `~`, `+`, `-` (unary)
  16. `++`, `--` (pre/post increment/decrement)

  ## AST Node Types

  - `{:number, n}` - integer literal
  - `{:var, name}` - variable reference
  - `{:binop, op, left, right}` - binary operation
  - `{:unop, op, expr}` - unary operation
  - `{:assign, op, var_node, expr}` - assignment
  - `{:ternary, cond, true_expr, false_expr}` - ternary operator
  - `{:pre_inc, name}` / `{:pre_dec, name}` - pre-increment/decrement
  - `{:post_inc, var_node}` / `{:post_dec, var_node}` - post-increment/decrement
  """

  @doc """
  Parse an arithmetic expression string into an AST.

  Returns `{:ok, ast}` or `{:error, reason}`.

  ## Examples

      iex> Arithmetic.parse("1 + 2")
      {:ok, {:binop, "+", {:number, 1}, {:number, 2}}}

      iex> Arithmetic.parse("x = 5")
      {:ok, {:assign, "=", {:var, "x"}, {:number, 5}}}

      iex> Arithmetic.parse("++x")
      {:ok, {:pre_inc, "x"}}
  """
  def parse(expr) when is_binary(expr) do
    case tokenize(String.trim(expr)) do
      {:ok, tokens} ->
        case parse_expression(tokens) do
          {:ok, ast, []} -> {:ok, ast}
          {:ok, _ast, remaining} -> {:error, "Unexpected tokens: #{inspect(remaining)}"}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Tokenize an arithmetic expression string.

  Returns `{:ok, tokens}` or `{:error, reason}`.
  """
  def tokenize(expr) when is_binary(expr) do
    tokenize_loop(expr, [])
  end

  defp tokenize_loop("", acc), do: {:ok, Enum.reverse(acc)}

  # Skip whitespace
  defp tokenize_loop(<<c, rest::binary>>, acc) when c in ~c[ \t\n\r] do
    tokenize_loop(rest, acc)
  end

  # Multi-character operators (must come before single-char)
  defp tokenize_loop("**" <> rest, acc), do: tokenize_loop(rest, [{:op, "**"} | acc])
  defp tokenize_loop("++" <> rest, acc), do: tokenize_loop(rest, [{:op, "++"} | acc])
  defp tokenize_loop("--" <> rest, acc), do: tokenize_loop(rest, [{:op, "--"} | acc])
  defp tokenize_loop("<<=" <> rest, acc), do: tokenize_loop(rest, [{:op, "<<="} | acc])
  defp tokenize_loop(">>=" <> rest, acc), do: tokenize_loop(rest, [{:op, ">>="} | acc])
  defp tokenize_loop("<<" <> rest, acc), do: tokenize_loop(rest, [{:op, "<<"} | acc])
  defp tokenize_loop(">>" <> rest, acc), do: tokenize_loop(rest, [{:op, ">>"} | acc])
  defp tokenize_loop("<=" <> rest, acc), do: tokenize_loop(rest, [{:op, "<="} | acc])
  defp tokenize_loop(">=" <> rest, acc), do: tokenize_loop(rest, [{:op, ">="} | acc])
  defp tokenize_loop("==" <> rest, acc), do: tokenize_loop(rest, [{:op, "=="} | acc])
  defp tokenize_loop("!=" <> rest, acc), do: tokenize_loop(rest, [{:op, "!="} | acc])
  defp tokenize_loop("&&" <> rest, acc), do: tokenize_loop(rest, [{:op, "&&"} | acc])
  defp tokenize_loop("||" <> rest, acc), do: tokenize_loop(rest, [{:op, "||"} | acc])
  defp tokenize_loop("+=" <> rest, acc), do: tokenize_loop(rest, [{:op, "+="} | acc])
  defp tokenize_loop("-=" <> rest, acc), do: tokenize_loop(rest, [{:op, "-="} | acc])
  defp tokenize_loop("*=" <> rest, acc), do: tokenize_loop(rest, [{:op, "*="} | acc])
  defp tokenize_loop("/=" <> rest, acc), do: tokenize_loop(rest, [{:op, "/="} | acc])
  defp tokenize_loop("%=" <> rest, acc), do: tokenize_loop(rest, [{:op, "%="} | acc])
  defp tokenize_loop("&=" <> rest, acc), do: tokenize_loop(rest, [{:op, "&="} | acc])
  defp tokenize_loop("^=" <> rest, acc), do: tokenize_loop(rest, [{:op, "^="} | acc])
  defp tokenize_loop("|=" <> rest, acc), do: tokenize_loop(rest, [{:op, "|="} | acc])

  # Single-character operators
  defp tokenize_loop("+" <> rest, acc), do: tokenize_loop(rest, [{:op, "+"} | acc])
  defp tokenize_loop("-" <> rest, acc), do: tokenize_loop(rest, [{:op, "-"} | acc])
  defp tokenize_loop("*" <> rest, acc), do: tokenize_loop(rest, [{:op, "*"} | acc])
  defp tokenize_loop("/" <> rest, acc), do: tokenize_loop(rest, [{:op, "/"} | acc])
  defp tokenize_loop("%" <> rest, acc), do: tokenize_loop(rest, [{:op, "%"} | acc])
  defp tokenize_loop("<" <> rest, acc), do: tokenize_loop(rest, [{:op, "<"} | acc])
  defp tokenize_loop(">" <> rest, acc), do: tokenize_loop(rest, [{:op, ">"} | acc])
  defp tokenize_loop("=" <> rest, acc), do: tokenize_loop(rest, [{:op, "="} | acc])
  defp tokenize_loop("!" <> rest, acc), do: tokenize_loop(rest, [{:op, "!"} | acc])
  defp tokenize_loop("~" <> rest, acc), do: tokenize_loop(rest, [{:op, "~"} | acc])
  defp tokenize_loop("&" <> rest, acc), do: tokenize_loop(rest, [{:op, "&"} | acc])
  defp tokenize_loop("|" <> rest, acc), do: tokenize_loop(rest, [{:op, "|"} | acc])
  defp tokenize_loop("^" <> rest, acc), do: tokenize_loop(rest, [{:op, "^"} | acc])
  defp tokenize_loop("?" <> rest, acc), do: tokenize_loop(rest, [{:op, "?"} | acc])
  defp tokenize_loop(":" <> rest, acc), do: tokenize_loop(rest, [{:op, ":"} | acc])
  defp tokenize_loop("," <> rest, acc), do: tokenize_loop(rest, [{:op, ","} | acc])

  # Parentheses
  defp tokenize_loop("(" <> rest, acc), do: tokenize_loop(rest, [{:lparen, "("} | acc])
  defp tokenize_loop(")" <> rest, acc), do: tokenize_loop(rest, [{:rparen, ")"} | acc])

  # Numbers
  defp tokenize_loop(<<c, _rest::binary>> = input, acc) when c in ?0..?9 do
    {num_str, rest} = take_while(input, fn c -> c in ?0..?9 end)
    tokenize_loop(rest, [{:number, String.to_integer(num_str)} | acc])
  end

  # Identifiers (variable names)
  defp tokenize_loop(<<c, _rest::binary>> = input, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {id, rest} =
      take_while(input, fn c -> c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ end)

    tokenize_loop(rest, [{:id, id} | acc])
  end

  defp tokenize_loop(<<c, _rest::binary>>, _acc) do
    {:error, "Unexpected character: #{<<c>>}"}
  end

  defp take_while(input, pred) do
    take_while(input, pred, "")
  end

  defp take_while("", _pred, acc), do: {acc, ""}

  defp take_while(<<c, rest::binary>> = input, pred, acc) do
    if pred.(c) do
      take_while(rest, pred, acc <> <<c>>)
    else
      {acc, input}
    end
  end

  # Precedence levels
  @prec_comma 1
  @prec_assign 2
  @prec_ternary 3
  @prec_or 4
  @prec_and 5
  @prec_bitor 6
  @prec_bitxor 7
  @prec_bitand 8
  @prec_equality 9
  @prec_comparison 10
  @prec_shift 11
  @prec_additive 12
  @prec_multiplicative 13
  @prec_power 14
  @prec_unary 15

  defp parse_expression(tokens) do
    parse_prec(tokens, @prec_comma)
  end

  defp parse_prec(tokens, min_prec) do
    case parse_prefix(tokens) do
      {:ok, left, rest} ->
        parse_infix(left, rest, min_prec)

      {:error, _} = err ->
        err
    end
  end

  # Number literal
  defp parse_prefix([{:number, n} | rest]) do
    {:ok, {:number, n}, rest}
  end

  # Variable
  defp parse_prefix([{:id, name} | rest]) do
    # Check for post-increment/decrement
    case rest do
      [{:op, "++"} | rest2] -> {:ok, {:post_inc, {:var, name}}, rest2}
      [{:op, "--"} | rest2] -> {:ok, {:post_dec, {:var, name}}, rest2}
      _ -> {:ok, {:var, name}, rest}
    end
  end

  # Pre-increment
  defp parse_prefix([{:op, "++"}, {:id, name} | rest]) do
    {:ok, {:pre_inc, name}, rest}
  end

  # Pre-decrement
  defp parse_prefix([{:op, "--"}, {:id, name} | rest]) do
    {:ok, {:pre_dec, name}, rest}
  end

  # Unary plus
  defp parse_prefix([{:op, "+"} | rest]) do
    case parse_prec(rest, @prec_unary) do
      {:ok, expr, rest2} -> {:ok, {:unop, "+", expr}, rest2}
      err -> err
    end
  end

  # Unary minus
  defp parse_prefix([{:op, "-"} | rest]) do
    case parse_prec(rest, @prec_unary) do
      {:ok, expr, rest2} -> {:ok, {:unop, "-", expr}, rest2}
      err -> err
    end
  end

  # Logical NOT
  defp parse_prefix([{:op, "!"} | rest]) do
    case parse_prec(rest, @prec_unary) do
      {:ok, expr, rest2} -> {:ok, {:unop, "!", expr}, rest2}
      err -> err
    end
  end

  # Bitwise NOT
  defp parse_prefix([{:op, "~"} | rest]) do
    case parse_prec(rest, @prec_unary) do
      {:ok, expr, rest2} -> {:ok, {:unop, "~", expr}, rest2}
      err -> err
    end
  end

  # Parenthesized expression
  defp parse_prefix([{:lparen, _} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, [{:rparen, _} | rest2]} ->
        # Check for post-increment/decrement on grouped expression
        case {expr, rest2} do
          {{:var, name}, [{:op, "++"} | rest3]} -> {:ok, {:post_inc, {:var, name}}, rest3}
          {{:var, name}, [{:op, "--"} | rest3]} -> {:ok, {:post_dec, {:var, name}}, rest3}
          _ -> {:ok, expr, rest2}
        end

      {:ok, _expr, _} ->
        {:error, "Expected closing parenthesis"}

      err ->
        err
    end
  end

  defp parse_prefix([]) do
    {:error, "Unexpected end of expression"}
  end

  defp parse_prefix([token | _]) do
    {:error, "Unexpected token: #{inspect(token)}"}
  end

  defp parse_infix(left, tokens, min_prec) do
    case tokens do
      [{:op, op} | rest] ->
        {op_prec, assoc} = operator_info(op)

        if op_prec >= min_prec do
          case op do
            # Ternary operator
            "?" ->
              parse_ternary(left, rest, min_prec)

            # Assignment operators (right-associative)
            assign
            when assign in ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "^=", "|="] ->
              parse_assignment(left, assign, rest, min_prec)

            # Comma (sequence)
            "," ->
              parse_comma(left, rest, min_prec)

            # Regular binary operators
            _ ->
              next_prec = if assoc == :right, do: op_prec, else: op_prec + 1

              case parse_prec(rest, next_prec) do
                {:ok, right, rest2} ->
                  parse_infix({:binop, op, left, right}, rest2, min_prec)

                err ->
                  err
              end
          end
        else
          {:ok, left, tokens}
        end

      _ ->
        {:ok, left, tokens}
    end
  end

  defp parse_ternary(cond_expr, tokens, min_prec) do
    case parse_prec(tokens, @prec_ternary) do
      {:ok, true_expr, [{:op, ":"} | rest2]} ->
        case parse_prec(rest2, @prec_ternary) do
          {:ok, false_expr, rest3} ->
            parse_infix({:ternary, cond_expr, true_expr, false_expr}, rest3, min_prec)

          err ->
            err
        end

      {:ok, _, _} ->
        {:error, "Expected ':' in ternary expression"}

      err ->
        err
    end
  end

  defp parse_assignment(left, op, tokens, min_prec) do
    case left do
      {:var, _name} = var ->
        # Right-associative: parse with same precedence
        case parse_prec(tokens, @prec_assign) do
          {:ok, right, rest2} ->
            parse_infix({:assign, op, var, right}, rest2, min_prec)

          err ->
            err
        end

      _ ->
        {:error, "Invalid assignment target"}
    end
  end

  defp parse_comma(left, tokens, min_prec) do
    case parse_prec(tokens, @prec_comma + 1) do
      {:ok, right, rest2} ->
        # Build comma sequence
        comma_expr =
          case left do
            {:comma, exprs} -> {:comma, exprs ++ [right]}
            _ -> {:comma, [left, right]}
          end

        parse_infix(comma_expr, rest2, min_prec)

      err ->
        err
    end
  end

  # Returns {precedence, associativity}
  defp operator_info(op) do
    case op do
      "," -> {@prec_comma, :left}
      "=" -> {@prec_assign, :right}
      "+=" -> {@prec_assign, :right}
      "-=" -> {@prec_assign, :right}
      "*=" -> {@prec_assign, :right}
      "/=" -> {@prec_assign, :right}
      "%=" -> {@prec_assign, :right}
      "<<=" -> {@prec_assign, :right}
      ">>=" -> {@prec_assign, :right}
      "&=" -> {@prec_assign, :right}
      "^=" -> {@prec_assign, :right}
      "|=" -> {@prec_assign, :right}
      "?" -> {@prec_ternary, :right}
      "||" -> {@prec_or, :left}
      "&&" -> {@prec_and, :left}
      "|" -> {@prec_bitor, :left}
      "^" -> {@prec_bitxor, :left}
      "&" -> {@prec_bitand, :left}
      "==" -> {@prec_equality, :left}
      "!=" -> {@prec_equality, :left}
      "<" -> {@prec_comparison, :left}
      ">" -> {@prec_comparison, :left}
      "<=" -> {@prec_comparison, :left}
      ">=" -> {@prec_comparison, :left}
      "<<" -> {@prec_shift, :left}
      ">>" -> {@prec_shift, :left}
      "+" -> {@prec_additive, :left}
      "-" -> {@prec_additive, :left}
      "*" -> {@prec_multiplicative, :left}
      "/" -> {@prec_multiplicative, :left}
      "%" -> {@prec_multiplicative, :left}
      "**" -> {@prec_power, :right}
      # Colon has no precedence on its own (used in ternary)
      ":" -> {0, :left}
      _ -> {0, :left}
    end
  end
end
