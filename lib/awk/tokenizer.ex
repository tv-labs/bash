defmodule AWK.Tokenizer do
  @moduledoc """
  Lexer for AWK program syntax.

  Produces a stream of tokens with position information for the parser to consume.
  Handles AWK's full lexical grammar including regex literals, string escape sequences,
  numeric formats, and newline significance.

  ## Token Format

  All tokens are 4-tuples of `{type, value, line, column}` where:
  - `type` is an atom identifying the token kind
  - `value` is the token's semantic value (string, number, or nil for operators/delimiters)
  - `line` is the 1-based line number
  - `column` is the 1-based column number

  ## Regex vs Division Disambiguation

  The `/` character is interpreted as the start of a regex literal when it appears at the
  start of input, or after an operator, delimiter, keyword, or newline. It is interpreted
  as the division operator when it follows a value-producing token such as a number, string,
  identifier, `)`, `]`, `++`, or `--`.

  ## Newline Significance

  AWK uses newlines as statement separators. However, newlines are suppressed (not emitted)
  in the following contexts:
  - After a backslash line continuation
  - After `,`, `{`, `(`, `||`, `&&`, `do`, `else`
  - Inside parentheses or brackets (implicit continuation)
  """

  alias AWK.Error.ParseError

  @type token ::
          {atom(), String.t() | number() | nil, pos_integer(), pos_integer()}

  @type tokens :: [token()]

  @keywords %{
    "BEGIN" => :kw_begin,
    "END" => :kw_end,
    "BEGINFILE" => :kw_beginfile,
    "ENDFILE" => :kw_endfile,
    "if" => :kw_if,
    "else" => :kw_else,
    "while" => :kw_while,
    "for" => :kw_for,
    "do" => :kw_do,
    "break" => :kw_break,
    "continue" => :kw_continue,
    "next" => :kw_next,
    "nextfile" => :kw_nextfile,
    "function" => :kw_function,
    "func" => :kw_func,
    "return" => :kw_return,
    "exit" => :kw_exit,
    "delete" => :kw_delete,
    "getline" => :kw_getline,
    "print" => :kw_print,
    "printf" => :kw_printf,
    "in" => :kw_in,
    "switch" => :kw_switch,
    "case" => :kw_case,
    "default" => :kw_default
  }

  @doc """
  Tokenizes an AWK program string into a list of tokens.

  Returns `{:ok, tokens}` on success or `{:error, %ParseError{}}` on failure.

  ## Examples

      iex> AWK.Tokenizer.tokenize("{ print $1 }")
      {:ok, [{:lbrace, nil, 1, 1}, {:kw_print, "print", 1, 3},
             {:dollar, nil, 1, 9}, {:number, 1, 1, 10},
             {:rbrace, nil, 1, 12}, {:eof, nil, 1, 13}]}

  """
  @spec tokenize(String.t()) :: {:ok, tokens()} | {:error, ParseError.t()}
  def tokenize(input) when is_binary(input) do
    state = %{
      input: input,
      pos: 0,
      line: 1,
      col: 1,
      tokens: [],
      last_significant: nil,
      paren_depth: 0,
      bracket_depth: 0
    }

    case do_tokenize(state) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, _} = err -> err
    end
  end

  @doc """
  Tokenizes an AWK program string, raising on error.

  Returns the list of tokens on success, raises `ParseError` on failure.
  """
  @spec tokenize!(String.t()) :: tokens()
  def tokenize!(input) when is_binary(input) do
    case tokenize(input) do
      {:ok, tokens} -> tokens
      {:error, error} -> raise error
    end
  end

  # --- Core Loop ---

  defp do_tokenize(state) do
    case peek(state) do
      :eof ->
        token = {:eof, nil, state.line, state.col}
        {:ok, Enum.reverse([token | state.tokens])}

      char ->
        case scan_token(char, state) do
          {:ok, new_state} -> do_tokenize(new_state)
          {:error, _} = err -> err
        end
    end
  end

  # --- Character Scanning ---

  defp scan_token(?\s, state), do: {:ok, advance(state)}
  defp scan_token(?\t, state), do: {:ok, advance(state)}
  defp scan_token(?\r, state), do: {:ok, advance(state)}

  defp scan_token(?#, state) do
    {:ok, skip_comment(state)}
  end

  defp scan_token(?\n, state) do
    state = advance_newline(state)

    if newline_suppressed?(state) do
      {:ok, state}
    else
      token = {:newline, nil, state.line - 1, state.col}
      {:ok, emit(state, token)}
    end
  end

  defp scan_token(?\\, state) do
    case peek_at(state, 1) do
      ?\n ->
        state = state |> advance() |> advance_newline()
        {:ok, state}

      _ ->
        parse_error(state, "unexpected backslash")
    end
  end

  defp scan_token(?", state), do: scan_string(state)

  defp scan_token(?/, state) do
    if regex_context?(state) do
      scan_regex(state)
    else
      scan_operator(state)
    end
  end

  defp scan_token(char, state) when char in ~c'0123456789' do
    scan_number(state)
  end

  defp scan_token(?., state) do
    case peek_at(state, 1) do
      d when d in ~c'0123456789' -> scan_number(state)
      _ -> parse_error(state, "unexpected character '.'")
    end
  end

  defp scan_token(char, state) when char in ~c'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_' do
    scan_identifier(state)
  end

  defp scan_token(char, state) when char in ~c'+-*%^=!<>~?:,;()[]{}$|&' do
    scan_operator(state)
  end

  defp scan_token(char, state) do
    parse_error(state, "unexpected character '#{<<char::utf8>>}'")
  end

  # --- String Scanning ---

  defp scan_string(state) do
    start_line = state.line
    start_col = state.col
    state = advance(state)
    scan_string_body(state, [], start_line, start_col)
  end

  defp scan_string_body(state, acc, start_line, start_col) do
    case peek(state) do
      :eof ->
        parse_error_at(state, "unterminated string", start_line, start_col)

      ?\n ->
        parse_error_at(state, "unterminated string", start_line, start_col)

      ?" ->
        value = acc |> Enum.reverse() |> IO.iodata_to_binary()
        state = advance(state)
        token = {:string, value, start_line, start_col}
        {:ok, emit(state, token)}

      ?\\ ->
        case scan_string_escape(advance(state)) do
          {:ok, char, new_state} ->
            scan_string_body(new_state, [char | acc], start_line, start_col)

          {:error, _} = err ->
            err
        end

      char ->
        scan_string_body(advance(state), [<<char::utf8>> | acc], start_line, start_col)
    end
  end

  defp scan_string_escape(state) do
    case peek(state) do
      :eof ->
        parse_error(state, "unterminated escape sequence")

      ?\\ -> {:ok, "\\", advance(state)}
      ?" -> {:ok, "\"", advance(state)}
      ?n -> {:ok, "\n", advance(state)}
      ?t -> {:ok, "\t", advance(state)}
      ?r -> {:ok, "\r", advance(state)}
      ?a -> {:ok, "\a", advance(state)}
      ?b -> {:ok, "\b", advance(state)}
      ?f -> {:ok, "\f", advance(state)}
      ?v -> {:ok, "\v", advance(state)}
      ?/ -> {:ok, "/", advance(state)}

      ?x ->
        scan_hex_escape(advance(state))

      d when d in ~c'01234567' ->
        scan_octal_escape(state)

      char ->
        {:ok, <<?\\ :: utf8, char::utf8>>, advance(state)}
    end
  end

  defp scan_hex_escape(state) do
    {digits, new_state} = take_hex_digits(state, 2)

    if digits == "" do
      parse_error(state, "invalid hex escape sequence")
    else
      code = String.to_integer(digits, 16)
      {:ok, <<code::utf8>>, new_state}
    end
  end

  defp take_hex_digits(state, max), do: take_hex_digits(state, max, [])

  defp take_hex_digits(state, 0, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}

  defp take_hex_digits(state, remaining, acc) do
    case peek(state) do
      c when c in ~c'0123456789abcdefABCDEF' ->
        take_hex_digits(advance(state), remaining - 1, [<<c::utf8>> | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  defp scan_octal_escape(state) do
    {digits, new_state} = take_octal_digits(state, 3)
    code = String.to_integer(digits, 8)
    {:ok, <<code::utf8>>, new_state}
  end

  defp take_octal_digits(state, max), do: take_octal_digits(state, max, [])

  defp take_octal_digits(state, 0, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}

  defp take_octal_digits(state, remaining, acc) do
    case peek(state) do
      c when c in ~c'01234567' ->
        take_octal_digits(advance(state), remaining - 1, [<<c::utf8>> | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  # --- Regex Scanning ---

  defp scan_regex(state) do
    start_line = state.line
    start_col = state.col
    state = advance(state)
    scan_regex_body(state, [], false, start_line, start_col)
  end

  defp scan_regex_body(state, acc, in_bracket, start_line, start_col) do
    case peek(state) do
      :eof ->
        parse_error_at(state, "unterminated regex", start_line, start_col)

      ?\n ->
        parse_error_at(state, "unterminated regex", start_line, start_col)

      ?/ when not in_bracket ->
        value = acc |> Enum.reverse() |> IO.iodata_to_binary()
        state = advance(state)
        token = {:regex, value, start_line, start_col}
        {:ok, emit(state, token)}

      ?\\ ->
        state = advance(state)

        case peek(state) do
          :eof ->
            parse_error_at(state, "unterminated regex", start_line, start_col)

          char ->
            scan_regex_body(
              advance(state),
              [<<char::utf8>>, "\\" | acc],
              in_bracket,
              start_line,
              start_col
            )
        end

      ?[ ->
        scan_regex_body(advance(state), ["[" | acc], true, start_line, start_col)

      ?] when in_bracket ->
        scan_regex_body(advance(state), ["]" | acc], false, start_line, start_col)

      char ->
        scan_regex_body(advance(state), [<<char::utf8>> | acc], in_bracket, start_line, start_col)
    end
  end

  # --- Number Scanning ---

  defp scan_number(state) do
    start_line = state.line
    start_col = state.col

    case peek(state) do
      ?0 ->
        case peek_at(state, 1) do
          c when c in ~c'xX' ->
            scan_hex_number(advance(advance(state)), start_line, start_col)

          _ ->
            scan_decimal_number(state, start_line, start_col)
        end

      _ ->
        scan_decimal_number(state, start_line, start_col)
    end
  end

  defp scan_hex_number(state, start_line, start_col) do
    {digits, new_state} = take_hex_digits(state, 64)

    if digits == "" do
      parse_error_at(state, "invalid hex number", start_line, start_col)
    else
      value = String.to_integer(digits, 16)
      token = {:number, value, start_line, start_col}
      {:ok, emit(new_state, token)}
    end
  end

  defp scan_decimal_number(state, start_line, start_col) do
    {integer_part, state} = take_digits(state)
    {has_dot, state} = maybe_take_dot(state)
    {frac_part, state} = if has_dot, do: take_digits(state), else: {"", state}
    {exp_part, state} = maybe_take_exponent(state)

    raw =
      cond do
        has_dot and exp_part != "" -> integer_part <> "." <> frac_part <> exp_part
        has_dot -> integer_part <> "." <> frac_part
        exp_part != "" -> integer_part <> exp_part
        true -> integer_part
      end

    value =
      cond do
        has_dot or exp_part != "" ->
          String.to_float(normalize_float(raw))

        String.starts_with?(raw, "0") and String.length(raw) > 1 ->
          String.to_integer(raw, 8)

        true ->
          String.to_integer(raw)
      end

    token = {:number, value, start_line, start_col}
    {:ok, emit(state, token)}
  end

  defp normalize_float(raw) do
    raw =
      if String.starts_with?(raw, "."), do: "0" <> raw, else: raw

    raw =
      cond do
        String.ends_with?(raw, ".") -> raw <> "0"
        String.contains?(raw, ".") -> raw
        String.contains?(raw, "e") or String.contains?(raw, "E") ->
          case String.split(raw, ~r/[eE]/, parts: 2) do
            [base, exp] ->
              base = if String.contains?(base, "."), do: base, else: base <> ".0"
              base <> "e" <> exp
          end
        true -> raw <> ".0"
      end

    raw
  end

  defp take_digits(state), do: take_digits(state, [])

  defp take_digits(state, acc) do
    case peek(state) do
      c when c in ~c'0123456789' ->
        take_digits(advance(state), [<<c::utf8>> | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  defp maybe_take_dot(state) do
    case peek(state) do
      ?. ->
        case peek_at(state, 1) do
          c when c in ~c'0123456789' -> {true, advance(state)}
          _ -> {true, advance(state)}
        end

      _ ->
        {false, state}
    end
  end

  defp maybe_take_exponent(state) do
    case peek(state) do
      c when c in ~c'eE' ->
        state2 = advance(state)

        case peek(state2) do
          s when s in ~c'+-' ->
            state3 = advance(state2)

            case peek(state3) do
              d when d in ~c'0123456789' ->
                {digits, final} = take_digits(state3)
                {<<c::utf8, s::utf8>> <> digits, final}

              _ ->
                {"", state}
            end

          d when d in ~c'0123456789' ->
            {digits, final} = take_digits(state2)
            {<<c::utf8>> <> digits, final}

          _ ->
            {"", state}
        end

      _ ->
        {"", state}
    end
  end

  # --- Identifier / Keyword Scanning ---

  defp scan_identifier(state) do
    start_line = state.line
    start_col = state.col
    {name, new_state} = take_identifier(state)

    case Map.get(@keywords, name) do
      nil ->
        token = {:ident, name, start_line, start_col}
        {:ok, emit(new_state, token)}

      kw_type ->
        token = {kw_type, name, start_line, start_col}
        {:ok, emit(new_state, token)}
    end
  end

  defp take_identifier(state), do: take_identifier(state, [])

  defp take_identifier(state, acc) do
    case peek(state) do
      c when c in ~c'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789' ->
        take_identifier(advance(state), [<<c::utf8>> | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  # --- Operator Scanning ---

  defp scan_operator(state) do
    line = state.line
    col = state.col
    char = peek(state)

    case char do
      ?+ ->
        case peek_at(state, 1) do
          ?+ -> emit_op(advance(advance(state)), {:increment, nil, line, col})
          ?= -> emit_op(advance(advance(state)), {:add_assign, nil, line, col})
          _ -> emit_op(advance(state), {:plus, nil, line, col})
        end

      ?- ->
        case peek_at(state, 1) do
          ?- -> emit_op(advance(advance(state)), {:decrement, nil, line, col})
          ?= -> emit_op(advance(advance(state)), {:sub_assign, nil, line, col})
          _ -> emit_op(advance(state), {:minus, nil, line, col})
        end

      ?* ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:mul_assign, nil, line, col})
          _ -> emit_op(advance(state), {:star, nil, line, col})
        end

      ?/ ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:div_assign, nil, line, col})
          _ -> emit_op(advance(state), {:slash, nil, line, col})
        end

      ?% ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:mod_assign, nil, line, col})
          _ -> emit_op(advance(state), {:percent, nil, line, col})
        end

      ?^ ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:pow_assign, nil, line, col})
          _ -> emit_op(advance(state), {:caret, nil, line, col})
        end

      ?= ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:eq, nil, line, col})
          _ -> emit_op(advance(state), {:assign, nil, line, col})
        end

      ?! ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:neq, nil, line, col})
          ?~ -> emit_op(advance(advance(state)), {:not_match, nil, line, col})
          _ -> emit_op(advance(state), {:not, nil, line, col})
        end

      ?< ->
        case peek_at(state, 1) do
          ?= -> emit_op(advance(advance(state)), {:lte, nil, line, col})
          _ -> emit_op(advance(state), {:lt, nil, line, col})
        end

      ?> ->
        case peek_at(state, 1) do
          ?> -> emit_op(advance(advance(state)), {:append, nil, line, col})
          ?= -> emit_op(advance(advance(state)), {:gte, nil, line, col})
          _ -> emit_op(advance(state), {:gt, nil, line, col})
        end

      ?~ ->
        emit_op(advance(state), {:match, nil, line, col})

      ?& ->
        case peek_at(state, 1) do
          ?& -> emit_op(advance(advance(state)), {:and, nil, line, col})
          _ -> parse_error(state, "unexpected character '&'; did you mean '&&'?")
        end

      ?| ->
        case peek_at(state, 1) do
          ?| -> emit_op(advance(advance(state)), {:or, nil, line, col})
          ?& -> emit_op(advance(advance(state)), {:pipe_both, nil, line, col})
          _ -> emit_op(advance(state), {:pipe, nil, line, col})
        end

      ?? -> emit_op(advance(state), {:question, nil, line, col})
      ?: -> emit_op(advance(state), {:colon, nil, line, col})
      ?, -> emit_op(advance(state), {:comma, nil, line, col})
      ?; -> emit_op(advance(state), {:semicolon, nil, line, col})
      ?$ -> emit_op(advance(state), {:dollar, nil, line, col})

      ?( ->
        state = advance(state)
        state = %{state | paren_depth: state.paren_depth + 1}
        emit_op(state, {:lparen, nil, line, col})

      ?) ->
        state = advance(state)
        state = %{state | paren_depth: max(state.paren_depth - 1, 0)}
        emit_op(state, {:rparen, nil, line, col})

      ?[ ->
        state = advance(state)
        state = %{state | bracket_depth: state.bracket_depth + 1}
        emit_op(state, {:lbracket, nil, line, col})

      ?] ->
        state = advance(state)
        state = %{state | bracket_depth: max(state.bracket_depth - 1, 0)}
        emit_op(state, {:rbracket, nil, line, col})

      ?{ -> emit_op(advance(state), {:lbrace, nil, line, col})
      ?} -> emit_op(advance(state), {:rbrace, nil, line, col})
    end
  end

  defp emit_op(state, token), do: {:ok, emit(state, token)}

  # --- Regex vs Division Context ---

  @value_tokens [
    :number,
    :string,
    :ident,
    :rparen,
    :rbracket,
    :increment,
    :decrement
  ]

  defp regex_context?(state) do
    state.last_significant not in @value_tokens
  end

  # --- Newline Suppression ---

  @continuation_tokens [
    :comma,
    :lbrace,
    :lparen,
    :or,
    :and,
    :kw_do,
    :kw_else,
    :not,
    :match,
    :not_match,
    :plus,
    :minus,
    :star,
    :slash,
    :percent,
    :caret,
    :assign,
    :add_assign,
    :sub_assign,
    :mul_assign,
    :div_assign,
    :mod_assign,
    :pow_assign,
    :eq,
    :neq,
    :lt,
    :gt,
    :lte,
    :gte,
    :question,
    :colon,
    :pipe,
    :pipe_both,
    :append,
    :dollar
  ]

  defp newline_suppressed?(state) do
    state.paren_depth > 0 or
      state.bracket_depth > 0 or
      state.last_significant in @continuation_tokens
  end

  # --- Comment Handling ---

  defp skip_comment(state) do
    case peek(state) do
      :eof -> state
      ?\n -> state
      _ -> skip_comment(advance(state))
    end
  end

  # --- State Helpers ---

  defp peek(%{input: input, pos: pos}) do
    case input do
      <<_::binary-size(pos), c::utf8, _::binary>> -> c
      _ -> :eof
    end
  end

  defp peek_at(%{input: input, pos: pos}, offset) do
    target = pos + offset

    case input do
      <<_::binary-size(target), c::utf8, _::binary>> -> c
      _ -> :eof
    end
  end

  defp advance(%{input: input, pos: pos} = state) do
    case input do
      <<_::binary-size(pos), c::utf8, _::binary>> ->
        %{state | pos: pos + byte_size(<<c::utf8>>), col: state.col + 1}

      _ ->
        state
    end
  end

  defp advance_newline(state) do
    %{state | line: state.line + 1, col: 1}
  end

  defp emit(state, {type, _value, _line, _col} = token) do
    significant =
      case type do
        :newline -> state.last_significant
        _ -> type
      end

    %{state | tokens: [token | state.tokens], last_significant: significant}
  end

  # --- Error Helpers ---

  defp parse_error(state, message) do
    {:error,
     %ParseError{
       message: message,
       line: state.line,
       column: state.col,
       source: nil
     }}
  end

  defp parse_error_at(_state, message, line, col) do
    {:error,
     %ParseError{
       message: message,
       line: line,
       column: col,
       source: nil
     }}
  end
end
