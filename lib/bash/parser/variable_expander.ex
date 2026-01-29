defmodule Bash.Parser.VariableExpander do
  @moduledoc """
  Hand-written parser and expander for Bash variable expansions.

  Handles all forms of parameter expansion:
  - Simple: `$VAR`
  - Braced: `${VAR}`
  - Default values: `${VAR:-default}`, `${VAR:=default}`, `${VAR:?error}`, `${VAR:+alternate}`
  - Pattern removal: `${VAR#pattern}`, `${VAR##pattern}`, `${VAR%pattern}`, `${VAR%%pattern}`
  - Substitution: `${VAR/pattern/replacement}`, `${VAR//pattern/replacement}`
  - Substring: `${VAR:offset}`, `${VAR:offset:length}`
  - Length: `${#VAR}`

  References:
  - https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion
  - https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/subst.c?h=bash-5.3
  """

  @type token ::
          {:literal, String.t()}
          | {:var_simple, String.t()}
          | {:var_braced, String.t(), [modifier]}
  @type modifier ::
          {:length}
          | {:default, String.t(), String.t()}
          | {:pattern, String.t(), String.t()}
          | {:subst, String.t(), String.t()}
          | {:substring, String.t()}

  @special_vars ~c[?!$#*@-]

  defguardp is_var_start(char) when char in ?a..?z or char in ?A..?Z or char == ?_

  defguardp is_var_char(char)
            when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_

  defguardp is_special_var(char) when char in ?0..?9 or char in @special_vars

  @doc false
  # Expand variables in text using session environment variables.
  #
  # Accepts either a binary string or a pre-parsed token list from the Parser.
  # Returns `{expanded_text, env_updates}` where env_updates is a map of variables
  # that were assigned during expansion (e.g., via `${var:=default}`).
  @spec expand_variables(String.t() | [term()], map()) :: {String.t(), map()}
  def expand_variables(text, session_state) when is_binary(text) do
    case parse(text) do
      {:ok, tokens} -> expand_tokens(tokens, session_state)
      {:error, _reason} -> {text, %{}}
    end
  end

  def expand_variables(tokens, session_state) when is_list(tokens) do
    expand_parser_tokens(tokens, session_state)
  end

  @doc """
  Parse a string into a list of tokens for variable expansion.

  Returns `{:ok, tokens}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  def parse(text) when is_binary(text), do: parse(text, [])

  defp parse("", acc), do: {:ok, Enum.reverse(acc)}

  defp parse("${" <> rest, acc) do
    with {:ok, token, remaining} <- parse_braced_var(rest) do
      parse(remaining, [token | acc])
    end
  end

  defp parse("$" <> rest, acc) do
    case parse_simple_var(rest) do
      {:ok, token, remaining} -> parse(remaining, [token | acc])
      :no_var -> parse(rest, [add_to_literal(acc, "$")])
    end
  end

  defp parse(<<char::utf8, rest::binary>>, acc) do
    parse(rest, add_to_literal(acc, <<char::utf8>>))
  end

  defp add_to_literal([{:literal, text} | rest], char), do: [{:literal, text <> char} | rest]
  defp add_to_literal(acc, char), do: [{:literal, char} | acc]

  defp parse_simple_var(<<char, rest::binary>>) when is_var_start(char) do
    {name, remaining} = take_var_name_chars(rest, <<char>>)
    {:ok, {:var_simple, name}, remaining}
  end

  defp parse_simple_var(<<char, rest::binary>>) when is_special_var(char) do
    {:ok, {:var_simple, <<char>>}, rest}
  end

  defp parse_simple_var(_), do: :no_var

  defp take_var_name_chars(<<char, rest::binary>>, acc) when is_var_char(char) do
    take_var_name_chars(rest, acc <> <<char>>)
  end

  defp take_var_name_chars(rest, acc), do: {acc, rest}

  defp parse_braced_var("#" <> rest) do
    with {:ok, name, "}" <> remaining} <- parse_var_name(rest) do
      {:ok, {:var_braced, name, [:length]}, remaining}
    else
      {:ok, _name, remaining} ->
        {:error, "expected } after ${#VAR, got: #{inspect(String.slice(remaining, 0, 10))}"}

      {:error, _} = err ->
        err
    end
  end

  defp parse_braced_var(rest) do
    with {:ok, name, remaining} <- parse_var_name(rest) do
      parse_braced_modifiers(name, remaining)
    end
  end

  defp parse_var_name(<<char, rest::binary>>) when is_var_start(char) do
    {name, remaining} = take_var_name_chars(rest, <<char>>)
    {:ok, name, remaining}
  end

  defp parse_var_name(<<char, rest::binary>>) when is_special_var(char) do
    {:ok, <<char>>, rest}
  end

  defp parse_var_name(rest) do
    {:error, "expected variable name, got: #{inspect(String.slice(rest, 0, 10))}"}
  end

  defp parse_braced_modifiers(name, "}" <> remaining),
    do: {:ok, {:var_braced, name, []}, remaining}

  defp parse_braced_modifiers(name, ":-" <> rest), do: parse_modifier(name, :default, ":-", rest)
  defp parse_braced_modifiers(name, ":=" <> rest), do: parse_modifier(name, :default, ":=", rest)
  defp parse_braced_modifiers(name, ":?" <> rest), do: parse_modifier(name, :default, ":?", rest)
  defp parse_braced_modifiers(name, ":+" <> rest), do: parse_modifier(name, :default, ":+", rest)
  defp parse_braced_modifiers(name, ":" <> rest), do: parse_modifier(name, :substring, nil, rest)
  defp parse_braced_modifiers(name, "##" <> rest), do: parse_modifier(name, :pattern, "##", rest)
  defp parse_braced_modifiers(name, "#" <> rest), do: parse_modifier(name, :pattern, "#", rest)
  defp parse_braced_modifiers(name, "%%" <> rest), do: parse_modifier(name, :pattern, "%%", rest)
  defp parse_braced_modifiers(name, "%" <> rest), do: parse_modifier(name, :pattern, "%", rest)
  defp parse_braced_modifiers(name, "//" <> rest), do: parse_modifier(name, :subst, "//", rest)
  defp parse_braced_modifiers(name, "/" <> rest), do: parse_modifier(name, :subst, "/", rest)

  defp parse_braced_modifiers(_name, rest) do
    {:error, "unexpected modifier in ${}: #{inspect(String.slice(rest, 0, 10))}"}
  end

  defp parse_modifier(name, :substring, _op, rest) do
    with {:ok, params, remaining} <- take_until_close_brace(rest, "") do
      {:ok, {:var_braced, name, [{:substring, params}]}, remaining}
    end
  end

  defp parse_modifier(name, kind, op, rest) do
    with {:ok, word, remaining} <- take_until_close_brace(rest, "") do
      {:ok, {:var_braced, name, [{kind, op, word}]}, remaining}
    end
  end

  defp take_until_close_brace("", _acc), do: {:error, "unexpected end of input, expected }"}
  defp take_until_close_brace("}" <> rest, acc), do: {:ok, acc, rest}
  defp take_until_close_brace("\\}" <> rest, acc), do: take_until_close_brace(rest, acc <> "}")

  defp take_until_close_brace("${" <> rest, acc) do
    with {:ok, nested, remaining} <- take_nested_braces(rest, 1, "${") do
      take_until_close_brace(remaining, acc <> nested)
    end
  end

  defp take_until_close_brace(<<char::utf8, rest::binary>>, acc) do
    take_until_close_brace(rest, acc <> <<char::utf8>>)
  end

  defp take_nested_braces("", _depth, _acc),
    do: {:error, "unexpected end of input in nested expansion"}

  defp take_nested_braces("}" <> rest, 1, acc), do: {:ok, acc <> "}", rest}

  defp take_nested_braces("}" <> rest, depth, acc),
    do: take_nested_braces(rest, depth - 1, acc <> "}")

  defp take_nested_braces("${" <> rest, depth, acc),
    do: take_nested_braces(rest, depth + 1, acc <> "${")

  defp take_nested_braces(<<char::utf8, rest::binary>>, depth, acc) do
    take_nested_braces(rest, depth, acc <> <<char::utf8>>)
  end

  defp expand_tokens(tokens, session_state) do
    {parts, env_updates} =
      Enum.map_reduce(tokens, %{}, fn token, acc_updates ->
        {expanded, updates} = expand_token(token, session_state)
        {expanded, Map.merge(acc_updates, updates)}
      end)

    {Enum.join(parts, ""), env_updates}
  end

  defp expand_token({:literal, text}, _session_state), do: {text, %{}}

  defp expand_token({:var_simple, name}, session_state) do
    {get_var(name, session_state), %{}}
  end

  defp expand_token({:var_braced, name, []}, session_state) do
    {get_var(name, session_state), %{}}
  end

  defp expand_token({:var_braced, name, [:length]}, session_state) do
    value = get_var(name, session_state)
    {Integer.to_string(String.length(value)), %{}}
  end

  defp expand_token({:var_braced, name, [{:default, op, word}]}, session_state) do
    expand_default_op(name, op, word, session_state)
  end

  defp expand_token({:var_braced, name, [{:pattern, op, pattern}]}, session_state) do
    {expand_pattern_op(name, op, pattern, session_state), %{}}
  end

  defp expand_token({:var_braced, name, [{:subst, op, word}]}, session_state) do
    {expand_subst_op(name, op, word, session_state), %{}}
  end

  defp expand_token({:var_braced, name, [{:substring, params}]}, session_state) do
    {expand_substring_op(name, params, session_state), %{}}
  end

  defp expand_parser_tokens(tokens, session_state) do
    {parts, env_updates} =
      Enum.map_reduce(tokens, %{}, fn token, acc_updates ->
        {expanded, updates} = expand_parser_token(token, session_state)
        {expanded, Map.merge(acc_updates, updates)}
      end)

    {Enum.join(parts, ""), env_updates}
  end

  defp expand_parser_token({:var_ref_simple, [var_name]}, session_state)
       when is_binary(var_name) do
    {get_var(var_name, session_state), %{}}
  end

  defp expand_parser_token({:var_ref_braced, [var_name]}, session_state)
       when is_binary(var_name) do
    {get_var(var_name, session_state), %{}}
  end

  defp expand_parser_token({:var_ref_braced, parts}, session_state) when is_list(parts) do
    expand_braced_parts(parts, session_state)
  end

  defp expand_parser_token(text, _session_state) when is_binary(text) do
    {text, %{}}
  end

  defp expand_parser_token(charlist, _session_state) when is_list(charlist) do
    {List.to_string(charlist), %{}}
  end

  defp expand_parser_token(other, _session_state) do
    {to_string(other), %{}}
  end

  defp expand_braced_parts(parts, session_state) do
    var_name = get_parser_var_name(parts)
    word = Keyword.get(parts, :word, "")

    expand_braced_op(var_name, word, parts, session_state)
  end

  defp expand_braced_op(var_name, _word, [{:length_op, _} | _], session_state) do
    value = get_var(var_name, session_state)
    {Integer.to_string(String.length(value)), %{}}
  end

  defp expand_braced_op(var_name, word, [{:default_op, op} | _], session_state) do
    expand_default_op(var_name, op, word, session_state)
  end

  defp expand_braced_op(var_name, word, [{:pattern_op, op} | _], session_state) do
    {expand_pattern_op(var_name, op, word, session_state), %{}}
  end

  defp expand_braced_op(var_name, word, [{:subst_op, op} | _], session_state) do
    {expand_subst_op(var_name, op, word, session_state), %{}}
  end

  defp expand_braced_op(var_name, word, [{:substring_op, _} | _], session_state) do
    {expand_substring_op(var_name, word, session_state), %{}}
  end

  defp expand_braced_op(var_name, _word, [{:var_name, _} | rest], session_state) do
    expand_braced_op(var_name, "", rest, session_state)
  end

  defp expand_braced_op(var_name, word, [{:word, _} | rest], session_state) do
    expand_braced_op(var_name, word, rest, session_state)
  end

  defp expand_braced_op(var_name, _word, [], session_state) do
    {get_var(var_name, session_state), %{}}
  end

  defp get_parser_var_name(parts) do
    case Keyword.get(parts, :var_name) do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  defp expand_default_op(var_name, op, word, session_state) do
    value = get_var_or_nil(var_name, session_state)
    null_or_unset? = is_nil(value) or value == ""

    expand_default(op, var_name, value, word, null_or_unset?)
  end

  defp expand_default(":-", _name, _value, word, true), do: {word, %{}}
  defp expand_default(":-", _name, value, _word, false), do: {value, %{}}
  defp expand_default(":=", name, _value, word, true), do: {word, %{name => word}}
  defp expand_default(":=", _name, value, _word, false), do: {value, %{}}
  defp expand_default(":+", _name, _value, _word, true), do: {"", %{}}
  defp expand_default(":+", _name, _value, word, false), do: {word, %{}}

  defp expand_default(":?", name, _value, word, true) do
    hint = if word == "", do: "parameter null or not set", else: word

    raise Bash.SyntaxError,
      code: "SC2154",
      line: 1,
      column: 0,
      script: "${#{name}:?#{word}}",
      hint: "#{name}: #{hint}"
  end

  defp expand_default(":?", _name, value, _word, false), do: {value, %{}}

  defp expand_pattern_op(var_name, "#", pattern, session_state) do
    get_var(var_name, session_state) |> remove_prefix(pattern, :shortest)
  end

  defp expand_pattern_op(var_name, "##", pattern, session_state) do
    get_var(var_name, session_state) |> remove_prefix(pattern, :longest)
  end

  defp expand_pattern_op(var_name, "%", pattern, session_state) do
    get_var(var_name, session_state) |> remove_suffix(pattern, :shortest)
  end

  defp expand_pattern_op(var_name, "%%", pattern, session_state) do
    get_var(var_name, session_state) |> remove_suffix(pattern, :longest)
  end

  defp expand_subst_op(var_name, op, word, session_state) do
    value = get_var(var_name, session_state)
    {pattern, replacement} = parse_substitution_word(word)
    global? = op == "//"

    String.replace(value, pattern, replacement, global: global?)
  end

  defp expand_substring_op(var_name, params, session_state) do
    value = get_var(var_name, session_state)
    {offset, length} = parse_substring_params(params)

    case length do
      nil -> String.slice(value, offset..-1//1)
      len -> String.slice(value, offset, len)
    end
  end

  defp get_var(var_name, %{env_vars: env_vars}) do
    Map.get(env_vars, var_name, "")
  end

  defp get_var(var_name, %{variables: variables}) do
    normalize_var_value(Map.get(variables, var_name), "")
  end

  defp get_var(_var_name, _session_state), do: ""

  defp get_var_or_nil(var_name, %{env_vars: env_vars}) do
    Map.get(env_vars, var_name)
  end

  defp get_var_or_nil(var_name, %{variables: variables}) do
    normalize_var_value(Map.get(variables, var_name), nil)
  end

  defp get_var_or_nil(_var_name, _session_state), do: nil

  defp normalize_var_value(nil, default), do: default
  defp normalize_var_value(%{value: v}, _default), do: to_string(v)
  defp normalize_var_value(v, _default) when is_binary(v), do: v
  defp normalize_var_value(v, _default), do: to_string(v)

  defp remove_prefix(value, pattern, mode) do
    regex = Regex.compile!("^#{glob_to_regex(pattern, mode)}")
    String.replace(value, regex, "", global: false)
  end

  defp remove_suffix(value, pattern, mode) do
    prefix_quantifier = if mode == :shortest, do: ".*", else: ".*?"
    regex = Regex.compile!("^(#{prefix_quantifier})(#{glob_to_regex(pattern, :longest)})$")

    case Regex.run(regex, value) do
      [_, before, _match] -> before
      nil -> value
    end
  end

  defp glob_to_regex(pattern, :shortest) do
    pattern |> Regex.escape() |> String.replace("\\*", ".*?") |> String.replace("\\?", ".")
  end

  defp glob_to_regex(pattern, :longest) do
    pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")
  end

  defp parse_substitution_word(word) do
    case String.split(word, "/", parts: 2) do
      [pattern, replacement] -> {pattern, replacement}
      [pattern] -> {pattern, ""}
      [] -> {"", ""}
    end
  end

  defp parse_substring_params(params) do
    case String.split(params, ":", parts: 2) do
      [offset_str, length_str] -> {parse_int(offset_str), parse_int(length_str)}
      [offset_str] -> {parse_int(offset_str), nil}
      [] -> {0, nil}
    end
  end

  defp parse_int(str) do
    str
    |> String.trim()
    |> unwrap_parens()
    |> Integer.parse()
    |> case do
      {n, _} -> n
      :error -> 0
    end
  end

  # Bash uses parenthesized negatives like (-5) for negative offsets
  defp unwrap_parens(str) do
    case Regex.run(~r/^\((-?\d+)\)$/, str) do
      [_, inner] -> inner
      nil -> str
    end
  end
end
