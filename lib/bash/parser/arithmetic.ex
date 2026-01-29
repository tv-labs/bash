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
    with {:ok, tokens} <- tokenize(String.trim(expr)),
         {:ok, ast, []} <- parse_expression(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, remaining} -> {:error, "Unexpected tokens: #{inspect(remaining)}"}
      {:error, _} = err -> err
    end
  end

  @whitespace ~c[ \t\n\r]
  @unary_operators ~w[+ - ! ~]
  @assignment_operators ~w[= += -= *= /= %= <<= >>= &= ^= |=]

  @op_info %{
    :comma => {1, :left},
    :assign => {2, :right},
    :ternary => {3, :right},
    :unary => {15, :right},
    "," => {1, :left},
    "=" => {2, :right},
    "+=" => {2, :right},
    "-=" => {2, :right},
    "*=" => {2, :right},
    "/=" => {2, :right},
    "%=" => {2, :right},
    "<<=" => {2, :right},
    ">>=" => {2, :right},
    "&=" => {2, :right},
    "^=" => {2, :right},
    "|=" => {2, :right},
    "?" => {3, :right},
    "||" => {4, :left},
    "&&" => {5, :left},
    "|" => {6, :left},
    "^" => {7, :left},
    "&" => {8, :left},
    "==" => {9, :left},
    "!=" => {9, :left},
    "<" => {10, :left},
    ">" => {10, :left},
    "<=" => {10, :left},
    ">=" => {10, :left},
    "<<" => {11, :left},
    ">>" => {11, :left},
    "+" => {12, :left},
    "-" => {12, :left},
    "*" => {13, :left},
    "/" => {13, :left},
    "%" => {13, :left},
    "**" => {14, :right},
    ":" => {0, :left}
  }

  @doc false
  # Tokenize an arithmetic expression string.
  #
  # Returns `{:ok, tokens}` or `{:error, reason}`.
  def tokenize(expr) when is_binary(expr), do: tokenize(expr, [])
  def tokenize("", acc), do: {:ok, Enum.reverse(acc)}
  def tokenize(<<c, rest::binary>>, acc) when c in @whitespace, do: tokenize(rest, acc)
  def tokenize("**" <> rest, acc), do: tokenize(rest, [{:op, "**"} | acc])
  def tokenize("++" <> rest, acc), do: tokenize(rest, [{:op, "++"} | acc])
  def tokenize("--" <> rest, acc), do: tokenize(rest, [{:op, "--"} | acc])
  def tokenize("<<=" <> rest, acc), do: tokenize(rest, [{:op, "<<="} | acc])
  def tokenize(">>=" <> rest, acc), do: tokenize(rest, [{:op, ">>="} | acc])
  def tokenize("<<" <> rest, acc), do: tokenize(rest, [{:op, "<<"} | acc])
  def tokenize(">>" <> rest, acc), do: tokenize(rest, [{:op, ">>"} | acc])
  def tokenize("<=" <> rest, acc), do: tokenize(rest, [{:op, "<="} | acc])
  def tokenize(">=" <> rest, acc), do: tokenize(rest, [{:op, ">="} | acc])
  def tokenize("==" <> rest, acc), do: tokenize(rest, [{:op, "=="} | acc])
  def tokenize("!=" <> rest, acc), do: tokenize(rest, [{:op, "!="} | acc])
  def tokenize("&&" <> rest, acc), do: tokenize(rest, [{:op, "&&"} | acc])
  def tokenize("||" <> rest, acc), do: tokenize(rest, [{:op, "||"} | acc])
  def tokenize("+=" <> rest, acc), do: tokenize(rest, [{:op, "+="} | acc])
  def tokenize("-=" <> rest, acc), do: tokenize(rest, [{:op, "-="} | acc])
  def tokenize("*=" <> rest, acc), do: tokenize(rest, [{:op, "*="} | acc])
  def tokenize("/=" <> rest, acc), do: tokenize(rest, [{:op, "/="} | acc])
  def tokenize("%=" <> rest, acc), do: tokenize(rest, [{:op, "%="} | acc])
  def tokenize("&=" <> rest, acc), do: tokenize(rest, [{:op, "&="} | acc])
  def tokenize("^=" <> rest, acc), do: tokenize(rest, [{:op, "^="} | acc])
  def tokenize("|=" <> rest, acc), do: tokenize(rest, [{:op, "|="} | acc])
  def tokenize("+" <> rest, acc), do: tokenize(rest, [{:op, "+"} | acc])
  def tokenize("-" <> rest, acc), do: tokenize(rest, [{:op, "-"} | acc])
  def tokenize("*" <> rest, acc), do: tokenize(rest, [{:op, "*"} | acc])
  def tokenize("/" <> rest, acc), do: tokenize(rest, [{:op, "/"} | acc])
  def tokenize("%" <> rest, acc), do: tokenize(rest, [{:op, "%"} | acc])
  def tokenize("<" <> rest, acc), do: tokenize(rest, [{:op, "<"} | acc])
  def tokenize(">" <> rest, acc), do: tokenize(rest, [{:op, ">"} | acc])
  def tokenize("=" <> rest, acc), do: tokenize(rest, [{:op, "="} | acc])
  def tokenize("!" <> rest, acc), do: tokenize(rest, [{:op, "!"} | acc])
  def tokenize("~" <> rest, acc), do: tokenize(rest, [{:op, "~"} | acc])
  def tokenize("&" <> rest, acc), do: tokenize(rest, [{:op, "&"} | acc])
  def tokenize("|" <> rest, acc), do: tokenize(rest, [{:op, "|"} | acc])
  def tokenize("^" <> rest, acc), do: tokenize(rest, [{:op, "^"} | acc])
  def tokenize("?" <> rest, acc), do: tokenize(rest, [{:op, "?"} | acc])
  def tokenize(":" <> rest, acc), do: tokenize(rest, [{:op, ":"} | acc])
  def tokenize("," <> rest, acc), do: tokenize(rest, [{:op, ","} | acc])
  def tokenize("(" <> rest, acc), do: tokenize(rest, [{:lparen, "("} | acc])
  def tokenize(")" <> rest, acc), do: tokenize(rest, [{:rparen, ")"} | acc])

  def tokenize(<<c, _rest::binary>> = input, acc) when c in ?0..?9 do
    {num_str, rest} = take_while(input, &(&1 in ?0..?9))

    # Check for base#value notation (e.g., 16#FF, 8#77, 2#1010)
    case rest do
      "#" <> after_hash ->
        base = String.to_integer(num_str)
        {value_str, rest2} = take_base_digits(after_hash, base)

        if value_str == "" do
          {:error, "Invalid base-#{base} number: expected digits after #"}
        else
          case parse_base_number(value_str, base) do
            {:ok, value} -> tokenize(rest2, [{:number, value} | acc])
            {:error, _} = err -> err
          end
        end

      _ ->
        tokenize(rest, [{:number, String.to_integer(num_str)} | acc])
    end
  end

  def tokenize(<<c, _rest::binary>> = input, acc)
      when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {id, rest} = take_while(input, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    tokenize(rest, [{:id, id} | acc])
  end

  def tokenize(<<c, _rest::binary>>, _acc), do: {:error, "Unexpected character: #{<<c>>}"}

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

  # Take digits valid for a given base (0-9, a-z, A-Z)
  # Base 2: 0-1, Base 8: 0-7, Base 10: 0-9, Base 16: 0-9, a-f, A-F, etc.
  defp take_base_digits(input, base) do
    take_base_digits(input, base, "")
  end

  defp take_base_digits("", _base, acc), do: {acc, ""}

  defp take_base_digits(<<c, rest::binary>> = input, base, acc) do
    if valid_base_digit?(c, base) do
      take_base_digits(rest, base, acc <> <<c>>)
    else
      {acc, input}
    end
  end

  # Check if a character is a valid digit for the given base
  # Bash supports bases 2-64 where:
  # - 2-36: 0-9, a-z (case insensitive)
  # - 37-62: 0-9, a-z, A-Z (case sensitive)
  # - 63-64: 0-9, a-z, A-Z, @, _
  defp valid_base_digit?(c, base) when base >= 2 and base <= 36 do
    cond do
      c in ?0..?9 -> c - ?0 < base
      c in ?a..?z -> c - ?a + 10 < base
      c in ?A..?Z -> c - ?A + 10 < base
      true -> false
    end
  end

  defp valid_base_digit?(c, base) when base >= 37 and base <= 62 do
    cond do
      c in ?0..?9 -> true
      c in ?a..?z -> c - ?a + 10 < 36
      c in ?A..?Z -> c - ?A + 36 < base
      true -> false
    end
  end

  defp valid_base_digit?(c, base) when base >= 63 and base <= 64 do
    cond do
      c in ?0..?9 -> true
      c in ?a..?z -> true
      c in ?A..?Z -> true
      c == ?@ -> base >= 63
      c == ?_ -> base >= 64
      true -> false
    end
  end

  defp valid_base_digit?(_c, _base), do: false

  # Parse a string as a number in the given base
  defp parse_base_number(str, base) when base >= 2 and base <= 64 do
    result =
      str
      |> String.graphemes()
      |> Enum.reduce_while(0, fn char, acc ->
        case digit_value(char, base) do
          {:ok, value} -> {:cont, acc * base + value}
          :error -> {:halt, :error}
        end
      end)

    case result do
      :error -> {:error, "Invalid digit in base-#{base} number: #{str}"}
      value -> {:ok, value}
    end
  end

  defp parse_base_number(_str, base), do: {:error, "Invalid base: #{base} (must be 2-64)"}

  # Get the numeric value of a digit character in the given base
  defp digit_value(<<c>>, base) when c in ?0..?9 do
    value = c - ?0
    if value < base, do: {:ok, value}, else: :error
  end

  defp digit_value(<<c>>, base) when c in ?a..?z do
    value = c - ?a + 10
    if value < base or base > 36, do: {:ok, min(value, c - ?a + 10)}, else: :error
  end

  defp digit_value(<<c>>, base) when c in ?A..?Z do
    if base <= 36 do
      # Case insensitive for base <= 36
      value = c - ?A + 10
      if value < base, do: {:ok, value}, else: :error
    else
      # Case sensitive for base > 36
      value = c - ?A + 36
      if value < base, do: {:ok, value}, else: :error
    end
  end

  defp digit_value("@", base) when base >= 63, do: {:ok, 62}
  defp digit_value("_", base) when base >= 64, do: {:ok, 63}
  defp digit_value(_, _), do: :error

  defp parse_expression(tokens), do: parse_prec(tokens, prec(:comma))

  defp parse_prec(tokens, min_prec) do
    with {:ok, left, rest} <- parse_prefix(tokens) do
      parse_infix(left, rest, min_prec)
    end
  end

  defp parse_prefix([{:number, n} | rest]), do: {:ok, {:number, n}, rest}

  defp parse_prefix([{:id, name} | rest]) do
    case rest do
      [{:op, "++"} | rest2] -> {:ok, {:post_inc, {:var, name}}, rest2}
      [{:op, "--"} | rest2] -> {:ok, {:post_dec, {:var, name}}, rest2}
      _ -> {:ok, {:var, name}, rest}
    end
  end

  defp parse_prefix([{:op, "++"}, {:id, name} | rest]), do: {:ok, {:pre_inc, name}, rest}
  defp parse_prefix([{:op, "--"}, {:id, name} | rest]), do: {:ok, {:pre_dec, name}, rest}

  defp parse_prefix([{:op, op} | rest]) when op in @unary_operators do
    with {:ok, expr, rest2} <- parse_prec(rest, prec(:unary)) do
      {:ok, {:unop, op, expr}, rest2}
    end
  end

  defp parse_prefix([{:lparen, _} | rest]) do
    with {:ok, expr, [{:rparen, _} | rest2]} <- parse_expression(rest) do
      case {expr, rest2} do
        {{:var, name}, [{:op, "++"} | rest3]} -> {:ok, {:post_inc, {:var, name}}, rest3}
        {{:var, name}, [{:op, "--"} | rest3]} -> {:ok, {:post_dec, {:var, name}}, rest3}
        _ -> {:ok, expr, rest2}
      end
    else
      {:ok, _expr, _} -> {:error, "Expected closing parenthesis"}
      err -> err
    end
  end

  defp parse_prefix([]), do: {:error, "Unexpected end of expression"}
  defp parse_prefix([token | _]), do: {:error, "Unexpected token: #{inspect(token)}"}

  defp parse_infix(left, [{:op, op} | rest] = tokens, min_prec) do
    {op_prec, assoc} = operator_info(op)

    if op_prec >= min_prec do
      parse_infix_op(left, op, rest, min_prec, assoc, op_prec)
    else
      {:ok, left, tokens}
    end
  end

  defp parse_infix(left, tokens, _min_prec), do: {:ok, left, tokens}

  defp parse_infix_op(left, "?", rest, min_prec, _assoc, _prec) do
    with {:ok, true_expr, [{:op, ":"} | rest2]} <- parse_prec(rest, prec(:ternary)),
         {:ok, false_expr, rest3} <- parse_prec(rest2, prec(:ternary)) do
      parse_infix({:ternary, left, true_expr, false_expr}, rest3, min_prec)
    else
      {:ok, _, _} -> {:error, "Expected ':' in ternary expression"}
      err -> err
    end
  end

  defp parse_infix_op(left, op, rest, min_prec, _assoc, _prec) when op in @assignment_operators do
    case left do
      {:var, _} = var ->
        with {:ok, right, rest2} <- parse_prec(rest, prec(:assign)) do
          parse_infix({:assign, op, var, right}, rest2, min_prec)
        end

      _ ->
        {:error, "Invalid assignment target"}
    end
  end

  defp parse_infix_op(left, ",", rest, min_prec, _assoc, _prec) do
    with {:ok, right, rest2} <- parse_prec(rest, prec(:comma) + 1) do
      comma_expr =
        case left do
          {:comma, exprs} -> {:comma, exprs ++ [right]}
          _ -> {:comma, [left, right]}
        end

      parse_infix(comma_expr, rest2, min_prec)
    end
  end

  defp parse_infix_op(left, op, rest, min_prec, assoc, op_prec) do
    next_prec = if assoc == :right, do: op_prec, else: op_prec + 1

    with {:ok, right, rest2} <- parse_prec(rest, next_prec) do
      parse_infix({:binop, op, left, right}, rest2, min_prec)
    end
  end

  defp operator_info({:op, op}), do: operator_info(op)
  defp operator_info(op), do: @op_info[op] || {0, :left}

  defp prec(op), do: operator_info(op) |> elem(0)
end
