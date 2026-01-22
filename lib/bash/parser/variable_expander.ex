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

  @doc """
  Expand variables in text using session environment variables.

  Accepts either a binary string or a pre-parsed token list from the Parser.
  Returns `{expanded_text, env_updates}` where env_updates is a map of variables
  that were assigned during expansion (e.g., via `${var:=default}`).
  """
  @spec expand_variables(String.t() | [term()], map()) :: {String.t(), map()}
  def expand_variables(text, session_state) when is_binary(text) do
    case parse(text) do
      {:ok, tokens} ->
        expand_tokens(tokens, session_state)

      {:error, _reason} ->
        # If parsing fails, return original text with no updates
        {text, %{}}
    end
  end

  def expand_variables(tokens, session_state) when is_list(tokens) do
    # Handle pre-parsed tokens from the main Parser
    expand_parser_tokens(tokens, session_state)
  end

  @doc """
  Parse a string into a list of tokens for variable expansion.

  Returns `{:ok, tokens}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    parse_tokens(text, [])
  end

  defp parse_tokens("", acc), do: {:ok, Enum.reverse(acc)}

  defp parse_tokens("${" <> rest, acc) do
    case parse_braced_var(rest) do
      {:ok, token, remaining} ->
        parse_tokens(remaining, [token | acc])

      {:error, _} = err ->
        err
    end
  end

  defp parse_tokens("$" <> rest, acc) do
    case parse_simple_var(rest) do
      {:ok, token, remaining} ->
        parse_tokens(remaining, [token | acc])

      :no_var ->
        # Just a lone $ - treat as literal
        parse_tokens(rest, [add_to_literal(acc, "$")])
    end
  end

  defp parse_tokens(<<char::utf8, rest::binary>>, acc) do
    parse_tokens(rest, add_to_literal(acc, <<char::utf8>>))
  end

  # Helper to accumulate literal text into acc list
  defp add_to_literal([{:literal, text} | rest], char) do
    [{:literal, text <> char} | rest]
  end

  defp add_to_literal(acc, char) do
    [{:literal, char} | acc]
  end

  # Parse simple variable: $VAR or $1, $?, $@, etc.
  defp parse_simple_var(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    {name, remaining} = take_var_name_chars(rest, <<char>>)
    {:ok, {:var_simple, name}, remaining}
  end

  # Special variables: $0-$9, $?, $!, $$, $#, $*, $@, $-
  defp parse_simple_var(<<char, rest::binary>>)
       when char in ?0..?9 or char in [??, ?!, ?$, ?#, ?*, ?@, ?-] do
    {:ok, {:var_simple, <<char>>}, rest}
  end

  defp parse_simple_var(_), do: :no_var

  defp take_var_name_chars(<<char, rest::binary>>, acc)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_ do
    take_var_name_chars(rest, acc <> <<char>>)
  end

  defp take_var_name_chars(rest, acc), do: {acc, rest}

  # Parse braced variable: ${VAR}, ${VAR:-default}, ${#VAR}, etc.
  defp parse_braced_var("#" <> rest) do
    # Length operator: ${#VAR}
    case parse_var_name(rest) do
      {:ok, name, "}" <> remaining} ->
        {:ok, {:var_braced, name, [:length]}, remaining}

      {:ok, _name, remaining} ->
        {:error, "expected } after ${#VAR, got: #{inspect(String.slice(remaining, 0, 10))}"}

      {:error, _} = err ->
        err
    end
  end

  defp parse_braced_var(rest) do
    case parse_var_name(rest) do
      {:ok, name, remaining} ->
        parse_braced_modifiers(name, remaining)

      {:error, _} = err ->
        err
    end
  end

  defp parse_var_name(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    {name, remaining} = take_var_name_chars(rest, <<char>>)
    {:ok, name, remaining}
  end

  # Special variables in braced form: ${?}, ${!}, etc.
  defp parse_var_name(<<char, rest::binary>>)
       when char in [??, ?!, ?$, ?#, ?*, ?@, ?-] or char in ?0..?9 do
    {:ok, <<char>>, rest}
  end

  defp parse_var_name(rest) do
    {:error, "expected variable name, got: #{inspect(String.slice(rest, 0, 10))}"}
  end

  # Parse modifiers after variable name in braced expansion
  defp parse_braced_modifiers(name, "}" <> remaining) do
    # Simple ${VAR}
    {:ok, {:var_braced, name, []}, remaining}
  end

  # Default value operators: :-, :=, :?, :+
  defp parse_braced_modifiers(name, ":-" <> rest) do
    parse_default_modifier(name, ":-", rest)
  end

  defp parse_braced_modifiers(name, ":=" <> rest) do
    parse_default_modifier(name, ":=", rest)
  end

  defp parse_braced_modifiers(name, ":?" <> rest) do
    parse_default_modifier(name, ":?", rest)
  end

  defp parse_braced_modifiers(name, ":+" <> rest) do
    parse_default_modifier(name, ":+", rest)
  end

  # Substring: ${VAR:offset} or ${VAR:offset:length}
  defp parse_braced_modifiers(name, ":" <> rest) do
    case take_until_close_brace(rest, "") do
      {:ok, params, remaining} ->
        {:ok, {:var_braced, name, [{:substring, params}]}, remaining}

      {:error, _} = err ->
        err
    end
  end

  # Pattern removal: ##, #, %%, %
  defp parse_braced_modifiers(name, "##" <> rest) do
    parse_pattern_modifier(name, "##", rest)
  end

  defp parse_braced_modifiers(name, "#" <> rest) do
    parse_pattern_modifier(name, "#", rest)
  end

  defp parse_braced_modifiers(name, "%%" <> rest) do
    parse_pattern_modifier(name, "%%", rest)
  end

  defp parse_braced_modifiers(name, "%" <> rest) do
    parse_pattern_modifier(name, "%", rest)
  end

  # Substitution: //, /
  defp parse_braced_modifiers(name, "//" <> rest) do
    parse_subst_modifier(name, "//", rest)
  end

  defp parse_braced_modifiers(name, "/" <> rest) do
    parse_subst_modifier(name, "/", rest)
  end

  defp parse_braced_modifiers(_name, rest) do
    {:error, "unexpected modifier in ${}: #{inspect(String.slice(rest, 0, 10))}"}
  end

  defp parse_default_modifier(name, op, rest) do
    case take_until_close_brace(rest, "") do
      {:ok, word, remaining} ->
        {:ok, {:var_braced, name, [{:default, op, word}]}, remaining}

      {:error, _} = err ->
        err
    end
  end

  defp parse_pattern_modifier(name, op, rest) do
    case take_until_close_brace(rest, "") do
      {:ok, pattern, remaining} ->
        {:ok, {:var_braced, name, [{:pattern, op, pattern}]}, remaining}

      {:error, _} = err ->
        err
    end
  end

  defp parse_subst_modifier(name, op, rest) do
    case take_until_close_brace(rest, "") do
      {:ok, word, remaining} ->
        {:ok, {:var_braced, name, [{:subst, op, word}]}, remaining}

      {:error, _} = err ->
        err
    end
  end

  # Take characters until we hit an unescaped }
  # Handles nested ${} by tracking brace depth
  defp take_until_close_brace("", _acc) do
    {:error, "unexpected end of input, expected }"}
  end

  defp take_until_close_brace("}" <> rest, acc) do
    {:ok, acc, rest}
  end

  defp take_until_close_brace("\\}" <> rest, acc) do
    # Escaped brace
    take_until_close_brace(rest, acc <> "}")
  end

  defp take_until_close_brace("${" <> rest, acc) do
    # Nested expansion - find matching close brace
    case take_nested_braces(rest, 1, "${") do
      {:ok, nested, remaining} ->
        take_until_close_brace(remaining, acc <> nested)

      {:error, _} = err ->
        err
    end
  end

  defp take_until_close_brace(<<char::utf8, rest::binary>>, acc) do
    take_until_close_brace(rest, acc <> <<char::utf8>>)
  end

  defp take_nested_braces("", _depth, _acc) do
    {:error, "unexpected end of input in nested expansion"}
  end

  defp take_nested_braces("}" <> rest, 1, acc) do
    {:ok, acc <> "}", rest}
  end

  defp take_nested_braces("}" <> rest, depth, acc) do
    take_nested_braces(rest, depth - 1, acc <> "}")
  end

  defp take_nested_braces("${" <> rest, depth, acc) do
    take_nested_braces(rest, depth + 1, acc <> "${")
  end

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

  # Expand braced parts from the main Parser format
  defp expand_braced_parts(parts, session_state) do
    var_name = get_parser_var_name(parts)
    has_length_op = Keyword.has_key?(parts, :length_op)

    cond do
      has_length_op ->
        value = get_var(var_name, session_state)
        {Integer.to_string(String.length(value)), %{}}

      default_op = Keyword.get(parts, :default_op) ->
        word = Keyword.get(parts, :word, "")
        expand_default_op(var_name, default_op, word, session_state)

      pattern_op = Keyword.get(parts, :pattern_op) ->
        word = Keyword.get(parts, :word, "")
        {expand_pattern_op(var_name, pattern_op, word, session_state), %{}}

      subst_op = Keyword.get(parts, :subst_op) ->
        word = Keyword.get(parts, :word, "")
        {expand_subst_op(var_name, subst_op, word, session_state), %{}}

      _substring_op = Keyword.get(parts, :substring_op) ->
        word = Keyword.get(parts, :word, "")
        {expand_substring_op(var_name, word, session_state), %{}}

      true ->
        {get_var(var_name, session_state), %{}}
    end
  end

  defp get_parser_var_name(parts) do
    case Keyword.get(parts, :var_name) do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  # ${var:-default}, ${var:=default}, ${var:?error}, ${var:+alternate}
  defp expand_default_op(var_name, op, word, session_state) do
    value = get_var_or_nil(var_name, session_state)
    is_null_or_unset = is_nil(value) or value == ""

    case op do
      ":-" ->
        result = if is_null_or_unset, do: word, else: value
        {result, %{}}

      ":=" ->
        if is_null_or_unset do
          {word, %{var_name => word}}
        else
          {value, %{}}
        end

      ":?" ->
        if is_null_or_unset do
          error_msg = if word == "", do: "parameter null or not set", else: word
          raise "bash: #{var_name}: #{error_msg}"
        else
          {value, %{}}
        end

      ":+" ->
        result = if is_null_or_unset, do: "", else: word
        {result, %{}}
    end
  end

  # ${var#pattern}, ${var##pattern}, ${var%pattern}, ${var%%pattern}
  defp expand_pattern_op(var_name, op, pattern, session_state) do
    value = get_var(var_name, session_state)

    case op do
      "#" -> remove_prefix(value, pattern, :shortest)
      "##" -> remove_prefix(value, pattern, :longest)
      "%" -> remove_suffix(value, pattern, :shortest)
      "%%" -> remove_suffix(value, pattern, :longest)
    end
  end

  # ${var/pattern/replacement}, ${var//pattern/replacement}
  defp expand_subst_op(var_name, op, word, session_state) do
    value = get_var(var_name, session_state)
    {pattern, replacement} = parse_substitution_word(word)

    case op do
      "/" -> String.replace(value, pattern, replacement, global: false)
      "//" -> String.replace(value, pattern, replacement, global: true)
    end
  end

  # ${var:offset} or ${var:offset:length}
  defp expand_substring_op(var_name, params, session_state) do
    value = get_var(var_name, session_state)

    case parse_substring_params(params) do
      {offset, nil} -> String.slice(value, offset..-1//1)
      {offset, length} -> String.slice(value, offset, length)
    end
  end

  defp get_var(var_name, session_state) do
    # Try env_vars first, then fall back to variables map
    cond do
      Map.has_key?(session_state, :env_vars) ->
        Map.get(session_state.env_vars, var_name, "")

      Map.has_key?(session_state, :variables) ->
        case Map.get(session_state.variables, var_name) do
          nil -> ""
          %{value: v} -> to_string(v)
          v when is_binary(v) -> v
          v -> to_string(v)
        end

      true ->
        ""
    end
  end

  defp get_var_or_nil(var_name, session_state) do
    cond do
      Map.has_key?(session_state, :env_vars) ->
        if Map.has_key?(session_state.env_vars, var_name) do
          Map.get(session_state.env_vars, var_name)
        else
          nil
        end

      Map.has_key?(session_state, :variables) ->
        case Map.get(session_state.variables, var_name) do
          nil -> nil
          %{value: v} -> to_string(v)
          v when is_binary(v) -> v
          v -> to_string(v)
        end

      true ->
        nil
    end
  end

  defp remove_prefix(value, pattern, mode) do
    regex_pattern = glob_to_regex(pattern, mode)
    regex = Regex.compile!("^#{regex_pattern}")
    String.replace(value, regex, "", global: false)
  end

  defp remove_suffix(value, pattern, mode) do
    regex_pattern = glob_to_regex(pattern, :longest)

    prefix_quantifier =
      case mode do
        :shortest -> ".*"
        :longest -> ".*?"
      end

    regex = Regex.compile!("^(#{prefix_quantifier})(#{regex_pattern})$")

    case Regex.run(regex, value) do
      [_, before, _match] -> before
      nil -> value
    end
  end

  defp glob_to_regex(pattern, mode) do
    wildcard_replacement =
      case mode do
        :shortest -> ".*?"
        :longest -> ".*"
      end

    pattern
    |> Regex.escape()
    |> String.replace("\\*", wildcard_replacement)
    |> String.replace("\\?", ".")
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
      [offset_str, length_str] ->
        {parse_int(offset_str), parse_int(length_str)}

      [offset_str] ->
        {parse_int(offset_str), nil}

      [] ->
        {0, nil}
    end
  end

  defp parse_int(str) do
    str = String.trim(str)

    # Handle parenthesized negatives like (-5) which bash uses for negative offsets
    str =
      case Regex.run(~r/^\((-?\d+)\)$/, str) do
        [_, inner] -> inner
        nil -> str
      end

    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end
end
