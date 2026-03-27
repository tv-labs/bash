defmodule JQ.Tokenizer do
  @moduledoc """
  Tokenizer for the jq language.

  Converts a jq filter string into a list of tokens suitable for parsing.
  Handles the full jq syntax including string interpolation, comments,
  all operators, keywords, and numeric literals.

  ## Token Format

  Each token is a 4-tuple: `{type, value, line, column}` where `value`
  is `nil` for fixed-symbol tokens and holds the parsed value for literals,
  identifiers, and strings.

  ## Examples

      iex> JQ.Tokenizer.tokenize(".")
      {:ok, [{:dot, nil, 1, 0}, {:eof, nil, 1, 1}]}

      iex> JQ.Tokenizer.tokenize(".foo | .bar")
      {:ok, [
        {:dot, nil, 1, 0}, {:ident, "foo", 1, 1}, {:pipe, nil, 1, 5},
        {:dot, nil, 1, 7}, {:ident, "bar", 1, 8}, {:eof, nil, 1, 11}
      ]}
  """

  alias JQ.Error.ParseError

  @type token_type ::
          :dot
          | :dotdot
          | :pipe
          | :comma
          | :colon
          | :semicolon
          | :lparen
          | :rparen
          | :lbracket
          | :rbracket
          | :lbrace
          | :rbrace
          | :question
          | :plus
          | :minus
          | :star
          | :slash
          | :percent
          | :eq
          | :neq
          | :lt
          | :gt
          | :lte
          | :gte
          | :assign
          | :update
          | :add_assign
          | :sub_assign
          | :mul_assign
          | :div_assign
          | :mod_assign
          | :alt
          | :alt_assign
          | :try_alt
          | :number
          | :string
          | :ident
          | :variable
          | :format
          | :kw_if
          | :kw_then
          | :kw_elif
          | :kw_else
          | :kw_end
          | :kw_as
          | :kw_def
          | :kw_reduce
          | :kw_foreach
          | :kw_try
          | :kw_catch
          | :kw_import
          | :kw_include
          | :kw_label
          | :kw_break
          | :kw_and
          | :kw_or
          | :kw_not
          | :kw_true
          | :kw_false
          | :kw_null
          | :eof

  @type token :: {token_type(), term(), pos_integer(), non_neg_integer()}

  @type string_part :: {:literal, String.t()} | {:interp, [token()]}

  @keywords %{
    "if" => :kw_if,
    "then" => :kw_then,
    "elif" => :kw_elif,
    "else" => :kw_else,
    "end" => :kw_end,
    "as" => :kw_as,
    "def" => :kw_def,
    "reduce" => :kw_reduce,
    "foreach" => :kw_foreach,
    "try" => :kw_try,
    "catch" => :kw_catch,
    "import" => :kw_import,
    "include" => :kw_include,
    "label" => :kw_label,
    "break" => :kw_break,
    "and" => :kw_and,
    "or" => :kw_or,
    "not" => :kw_not,
    "true" => :kw_true,
    "false" => :kw_false,
    "null" => :kw_null
  }

  @doc """
  Tokenizes a jq filter string into a list of tokens.

  Returns `{:ok, tokens}` on success or `{:error, %ParseError{}}` on failure.
  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, ParseError.t()}
  def tokenize(input) when is_binary(input) do
    case do_tokenize(String.to_charlist(input), 1, 0, []) do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Tokenizes a jq filter string, raising on error.
  """
  @spec tokenize!(String.t()) :: [token()]
  def tokenize!(input) when is_binary(input) do
    case tokenize(input) do
      {:ok, tokens} -> tokens
      {:error, error} -> raise error
    end
  end

  defguardp is_digit(c) when c >= ?0 and c <= ?9

  defguardp is_alpha(c)
            when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_

  defguardp is_alnum(c)
            when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or
                   (c >= ?0 and c <= ?9) or c == ?_

  defguardp is_whitespace(c) when c == ?\s or c == ?\t or c == ?\r

  defp do_tokenize([], line, col, acc) do
    {:ok, [{:eof, nil, line, col} | acc]}
  end

  defp do_tokenize([?\n | rest], line, _col, acc) do
    do_tokenize(rest, line + 1, 0, acc)
  end

  defp do_tokenize([c | rest], line, col, acc) when is_whitespace(c) do
    do_tokenize(rest, line, col + 1, acc)
  end

  defp do_tokenize([?# | rest], line, _col, acc) do
    rest = skip_comment(rest)
    do_tokenize(rest, line + 1, 0, acc)
  end

  defp do_tokenize([?" | rest], line, col, acc) do
    case tokenize_string(rest, line, col + 1, []) do
      {:ok, parts, rest, new_line, new_col} ->
        token = {:string, parts, line, col}
        do_tokenize(rest, new_line, new_col, [token | acc])

      {:error, _} = err ->
        err
    end
  end

  defp do_tokenize([??, ?/, ?/ | rest], line, col, acc) do
    do_tokenize(rest, line, col + 3, [{:try_alt, nil, line, col} | acc])
  end

  defp do_tokenize([?? | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:question, nil, line, col} | acc])
  end

  defp do_tokenize([?., ?. | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:dotdot, nil, line, col} | acc])
  end

  defp do_tokenize([?. | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:dot, nil, line, col} | acc])
  end

  defp do_tokenize([?|, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:update, nil, line, col} | acc])
  end

  defp do_tokenize([?| | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:pipe, nil, line, col} | acc])
  end

  defp do_tokenize([?, | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:comma, nil, line, col} | acc])
  end

  defp do_tokenize([?: | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:colon, nil, line, col} | acc])
  end

  defp do_tokenize([?; | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:semicolon, nil, line, col} | acc])
  end

  defp do_tokenize([?( | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lparen, nil, line, col} | acc])
  end

  defp do_tokenize([?) | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:rparen, nil, line, col} | acc])
  end

  defp do_tokenize([?[ | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lbracket, nil, line, col} | acc])
  end

  defp do_tokenize([?] | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:rbracket, nil, line, col} | acc])
  end

  defp do_tokenize([?{ | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lbrace, nil, line, col} | acc])
  end

  defp do_tokenize([?} | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:rbrace, nil, line, col} | acc])
  end

  defp do_tokenize([?+, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:add_assign, nil, line, col} | acc])
  end

  defp do_tokenize([?-, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:sub_assign, nil, line, col} | acc])
  end

  defp do_tokenize([?*, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:mul_assign, nil, line, col} | acc])
  end

  defp do_tokenize([?/, ?/, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 3, [{:alt_assign, nil, line, col} | acc])
  end

  defp do_tokenize([?/, ?/ | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:alt, nil, line, col} | acc])
  end

  defp do_tokenize([?/, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:div_assign, nil, line, col} | acc])
  end

  defp do_tokenize([?%, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:mod_assign, nil, line, col} | acc])
  end

  defp do_tokenize([?+ | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:plus, nil, line, col} | acc])
  end

  defp do_tokenize([?- | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:minus, nil, line, col} | acc])
  end

  defp do_tokenize([?* | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:star, nil, line, col} | acc])
  end

  defp do_tokenize([?/ | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:slash, nil, line, col} | acc])
  end

  defp do_tokenize([?% | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:percent, nil, line, col} | acc])
  end

  defp do_tokenize([?=, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:eq, nil, line, col} | acc])
  end

  defp do_tokenize([?!, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:neq, nil, line, col} | acc])
  end

  defp do_tokenize([?<, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:lte, nil, line, col} | acc])
  end

  defp do_tokenize([?>, ?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:gte, nil, line, col} | acc])
  end

  defp do_tokenize([?< | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lt, nil, line, col} | acc])
  end

  defp do_tokenize([?> | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:gt, nil, line, col} | acc])
  end

  defp do_tokenize([?= | rest], line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:assign, nil, line, col} | acc])
  end

  defp do_tokenize([?@, c | rest], line, col, acc) when is_alpha(c) do
    {name, rest, new_col} = read_ident([c | rest], col + 1, [])
    do_tokenize(rest, line, new_col, [{:format, name, line, col} | acc])
  end

  defp do_tokenize([?@ | _], line, col, _acc) do
    error("unexpected character after '@'", line, col)
  end

  defp do_tokenize([?$, c | rest], line, col, acc) when is_alpha(c) do
    {name, rest, new_col} = read_ident([c | rest], col + 1, [])
    do_tokenize(rest, line, new_col, [{:variable, "$" <> name, line, col} | acc])
  end

  defp do_tokenize([?$ | _], line, col, _acc) do
    error("unexpected character after '$'", line, col)
  end

  defp do_tokenize([c | _] = input, line, col, acc) when is_digit(c) do
    case read_number(input, col, []) do
      {:ok, value, rest, new_col} ->
        do_tokenize(rest, line, new_col, [{:number, value, line, col} | acc])

      {:error, msg} ->
        error(msg, line, col)
    end
  end

  defp do_tokenize([c | _] = input, line, col, acc) when is_alpha(c) do
    {name, rest, new_col} = read_ident(input, col, [])

    token =
      case Map.get(@keywords, name) do
        nil -> {:ident, name, line, col}
        kw -> {kw, nil, line, col}
      end

    do_tokenize(rest, line, new_col, [token | acc])
  end

  defp do_tokenize([c | _], line, col, _acc) do
    error("unexpected character '#{<<c::utf8>>}'", line, col)
  end

  defp skip_comment([?\n | _] = rest), do: rest
  defp skip_comment([_ | rest]), do: skip_comment(rest)
  defp skip_comment([]), do: []

  defp read_ident([c | rest], col, acc) when is_alnum(c) do
    read_ident(rest, col + 1, [c | acc])
  end

  defp read_ident(rest, col, acc) do
    {acc |> Enum.reverse() |> List.to_string(), rest, col}
  end

  defp read_number(input, col, acc) do
    {digits, rest, col} = read_digits(input, col, acc)

    case rest do
      [?., d | _] when is_digit(d) ->
        {frac_digits, rest, col} = read_digits([d | tl(rest)], col + 1, [?. | digits])
        maybe_read_exponent(frac_digits, rest, col, :float)

      [e | _] when e == ?e or e == ?E ->
        maybe_read_exponent(digits, rest, col, :float)

      _ ->
        value = digits |> Enum.reverse() |> List.to_string() |> String.to_integer()
        {:ok, value, rest, col}
    end
  end

  defp maybe_read_exponent(digits, [e | rest], col, _type) when e == ?e or e == ?E do
    {sign_chars, rest, col} =
      case rest do
        [s | rest2] when s == ?+ or s == ?- -> {[s], rest2, col + 2}
        _ -> {[], rest, col + 1}
      end

    case rest do
      [d | _] when is_digit(d) ->
        {exp_digits, rest, col} = read_digits(rest, col, sign_chars ++ [e | digits])
        value = exp_digits |> Enum.reverse() |> List.to_string() |> String.to_float()
        {:ok, value, rest, col}

      _ ->
        {:error, "invalid number: expected digit after exponent"}
    end
  end

  defp maybe_read_exponent(digits, rest, col, :float) do
    value = digits |> Enum.reverse() |> List.to_string() |> String.to_float()
    {:ok, value, rest, col}
  end

  defp maybe_read_exponent(digits, rest, col, :integer) do
    value = digits |> Enum.reverse() |> List.to_string() |> String.to_integer()
    {:ok, value, rest, col}
  end

  defp read_digits([c | rest], col, acc) when is_digit(c) do
    read_digits(rest, col + 1, [c | acc])
  end

  defp read_digits(rest, col, acc), do: {acc, rest, col}

  defp tokenize_string([?" | rest], line, col, parts) do
    {:ok, finalize_string_parts(parts), rest, line, col + 1}
  end

  defp tokenize_string([], line, col, _parts) do
    error("unterminated string literal", line, col)
  end

  defp tokenize_string([?\n | rest], line, _col, parts) do
    tokenize_string(rest, line + 1, 0, add_literal_char(parts, ?\n))
  end

  defp tokenize_string([?\\, ?( | rest], line, col, parts) do
    case tokenize_interpolation(rest, line, col + 2, 0, []) do
      {:ok, interp_tokens, rest, new_line, new_col} ->
        new_parts = [{:interp, interp_tokens} | parts]
        tokenize_string(rest, new_line, new_col, new_parts)

      {:error, _} = err ->
        err
    end
  end

  defp tokenize_string([?\\ | rest], line, col, parts) do
    case rest do
      [?" | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?"))
      [?\\ | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?\\))
      [?/ | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?/))
      [?n | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?\n))
      [?r | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?\r))
      [?t | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?\t))
      [?) | rest] -> tokenize_string(rest, line, col + 2, add_literal_char(parts, ?)))
      [?u | rest] -> tokenize_unicode_escape(rest, line, col + 2, parts)
      _ -> error("invalid escape sequence", line, col)
    end
  end

  defp tokenize_string([c | rest], line, col, parts) do
    tokenize_string(rest, line, col + 1, add_literal_char(parts, c))
  end

  defp tokenize_unicode_escape(input, line, col, parts) do
    case read_hex_digits(input, 4, []) do
      {:ok, hex_chars, rest, consumed} ->
        codepoint = hex_chars |> List.to_string() |> String.to_integer(16)

        case handle_surrogate(codepoint, rest, col + consumed) do
          {:ok, char_bytes, rest, new_col} ->
            new_parts = add_literal_bytes(parts, char_bytes)
            tokenize_string(rest, line, new_col, new_parts)

          {:error, msg} ->
            error(msg, line, col)
        end

      {:error, _msg} ->
        error("invalid unicode escape: expected 4 hex digits", line, col)
    end
  end

  defp handle_surrogate(high, rest, col) when high >= 0xD800 and high <= 0xDBFF do
    case rest do
      [?\\, ?u | rest2] ->
        case read_hex_digits(rest2, 4, []) do
          {:ok, hex_chars, rest3, consumed} ->
            low = hex_chars |> List.to_string() |> String.to_integer(16)

            if low >= 0xDC00 and low <= 0xDFFF do
              codepoint = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
              {:ok, <<codepoint::utf8>>, rest3, col + 2 + consumed}
            else
              {:error, "invalid unicode surrogate pair"}
            end

          {:error, _} ->
            {:error, "invalid unicode escape in surrogate pair"}
        end

      _ ->
        {:error, "expected low surrogate after high surrogate"}
    end
  end

  defp handle_surrogate(codepoint, rest, col) do
    {:ok, <<codepoint::utf8>>, rest, col}
  end

  defp read_hex_digits(rest, 0, acc) do
    {:ok, Enum.reverse(acc), rest, length(acc)}
  end

  defp read_hex_digits([c | rest], n, acc) when n > 0 do
    if hex_digit?(c) do
      read_hex_digits(rest, n - 1, [c | acc])
    else
      {:error, "expected hex digit"}
    end
  end

  defp read_hex_digits([], _n, _acc) do
    {:error, "unexpected end of input in unicode escape"}
  end

  defp hex_digit?(c)
       when (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F),
       do: true

  defp hex_digit?(_), do: false

  defp tokenize_interpolation([?) | rest], line, col, 0, acc) do
    {:ok, Enum.reverse(acc), rest, line, col + 1}
  end

  defp tokenize_interpolation([], line, col, _depth, _acc) do
    error("unterminated string interpolation", line, col)
  end

  defp tokenize_interpolation(input, line, col, depth, acc) do
    case scan_one_token(input, line, col) do
      {:ok, token, rest, new_line, new_col} ->
        {type, _, _, _} = token

        case type do
          :rparen when depth == 0 ->
            {:ok, Enum.reverse(acc), rest, new_line, new_col}

          :lparen ->
            tokenize_interpolation(rest, new_line, new_col, depth + 1, [token | acc])

          :rparen ->
            tokenize_interpolation(rest, new_line, new_col, depth - 1, [token | acc])

          _ ->
            tokenize_interpolation(rest, new_line, new_col, depth, [token | acc])
        end

      {:error, _} = err ->
        err
    end
  end

  defp scan_one_token([], line, col, _acc) do
    error("unexpected end of input in interpolation", line, col)
  end

  defp scan_one_token(input, line, col) do
    scan_one_token(input, line, col, [])
  end

  defp scan_one_token([?\n | rest], line, _col, _acc) do
    scan_one_token(rest, line + 1, 0, [])
  end

  defp scan_one_token([c | rest], line, col, _acc) when is_whitespace(c) do
    scan_one_token(rest, line, col + 1, [])
  end

  defp scan_one_token([?# | rest], line, _col, _acc) do
    rest = skip_comment(rest)
    scan_one_token(rest, line + 1, 0, [])
  end

  defp scan_one_token([?" | rest], line, col, _acc) do
    case tokenize_string(rest, line, col + 1, []) do
      {:ok, parts, rest, new_line, new_col} ->
        {:ok, {:string, parts, line, col}, rest, new_line, new_col}

      {:error, _} = err ->
        err
    end
  end

  defp scan_one_token([??, ?/, ?/ | rest], line, col, _acc) do
    {:ok, {:try_alt, nil, line, col}, rest, line, col + 3}
  end

  defp scan_one_token([?? | rest], line, col, _acc) do
    {:ok, {:question, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?., ?. | rest], line, col, _acc) do
    {:ok, {:dotdot, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?. | rest], line, col, _acc) do
    {:ok, {:dot, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?|, ?= | rest], line, col, _acc) do
    {:ok, {:update, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?| | rest], line, col, _acc) do
    {:ok, {:pipe, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?, | rest], line, col, _acc) do
    {:ok, {:comma, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?: | rest], line, col, _acc) do
    {:ok, {:colon, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?; | rest], line, col, _acc) do
    {:ok, {:semicolon, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?( | rest], line, col, _acc) do
    {:ok, {:lparen, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?) | rest], line, col, _acc) do
    {:ok, {:rparen, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?[ | rest], line, col, _acc) do
    {:ok, {:lbracket, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?] | rest], line, col, _acc) do
    {:ok, {:rbracket, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?{ | rest], line, col, _acc) do
    {:ok, {:lbrace, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?} | rest], line, col, _acc) do
    {:ok, {:rbrace, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?+, ?= | rest], line, col, _acc) do
    {:ok, {:add_assign, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?-, ?= | rest], line, col, _acc) do
    {:ok, {:sub_assign, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?*, ?= | rest], line, col, _acc) do
    {:ok, {:mul_assign, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?/, ?/, ?= | rest], line, col, _acc) do
    {:ok, {:alt_assign, nil, line, col}, rest, line, col + 3}
  end

  defp scan_one_token([?/, ?/ | rest], line, col, _acc) do
    {:ok, {:alt, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?/, ?= | rest], line, col, _acc) do
    {:ok, {:div_assign, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?%, ?= | rest], line, col, _acc) do
    {:ok, {:mod_assign, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?+ | rest], line, col, _acc) do
    {:ok, {:plus, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?- | rest], line, col, _acc) do
    {:ok, {:minus, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?* | rest], line, col, _acc) do
    {:ok, {:star, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?/ | rest], line, col, _acc) do
    {:ok, {:slash, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?% | rest], line, col, _acc) do
    {:ok, {:percent, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?=, ?= | rest], line, col, _acc) do
    {:ok, {:eq, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?!, ?= | rest], line, col, _acc) do
    {:ok, {:neq, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?<, ?= | rest], line, col, _acc) do
    {:ok, {:lte, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?>, ?= | rest], line, col, _acc) do
    {:ok, {:gte, nil, line, col}, rest, line, col + 2}
  end

  defp scan_one_token([?< | rest], line, col, _acc) do
    {:ok, {:lt, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?> | rest], line, col, _acc) do
    {:ok, {:gt, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?= | rest], line, col, _acc) do
    {:ok, {:assign, nil, line, col}, rest, line, col + 1}
  end

  defp scan_one_token([?@, c | rest], line, col, _acc) when is_alpha(c) do
    {name, rest, new_col} = read_ident([c | rest], col + 1, [])
    {:ok, {:format, name, line, col}, rest, line, new_col}
  end

  defp scan_one_token([?$, c | rest], line, col, _acc) when is_alpha(c) do
    {name, rest, new_col} = read_ident([c | rest], col + 1, [])
    {:ok, {:variable, "$" <> name, line, col}, rest, line, new_col}
  end

  defp scan_one_token([c | _] = input, line, col, _acc) when is_digit(c) do
    case read_number(input, col, []) do
      {:ok, value, rest, new_col} ->
        {:ok, {:number, value, line, col}, rest, line, new_col}

      {:error, msg} ->
        error(msg, line, col)
    end
  end

  defp scan_one_token([c | _] = input, line, col, _acc) when is_alpha(c) do
    {name, rest, new_col} = read_ident(input, col, [])

    token =
      case Map.get(@keywords, name) do
        nil -> {:ident, name, line, col}
        kw -> {kw, nil, line, col}
      end

    {:ok, token, rest, line, new_col}
  end

  defp scan_one_token([c | _], line, col, _acc) do
    error("unexpected character '#{<<c::utf8>>}'", line, col)
  end

  defp add_literal_char([{:literal_acc, chars} | rest], c) do
    [{:literal_acc, [c | chars]} | rest]
  end

  defp add_literal_char(parts, c) do
    [{:literal_acc, [c]} | parts]
  end

  defp add_literal_bytes([{:literal_acc, chars} | rest], bytes) do
    byte_chars = :binary.bin_to_list(bytes)
    [{:literal_acc, Enum.reverse(byte_chars) ++ chars} | rest]
  end

  defp add_literal_bytes(parts, bytes) do
    byte_chars = bytes |> :binary.bin_to_list() |> Enum.reverse()
    [{:literal_acc, byte_chars} | parts]
  end

  defp finalize_string_parts(parts) do
    parts
    |> Enum.map(fn
      {:literal_acc, chars} -> {:literal, chars |> Enum.reverse() |> List.to_string()}
      {:interp, tokens} -> {:interp, tokens}
    end)
    |> Enum.reverse()
  end

  defp error(message, line, col) do
    {:error, %ParseError{message: message, line: line, column: col}}
  end
end
