defmodule Bash.Tokenizer do
  @moduledoc ~S"""
  Lexer for Bash syntax.

  Produces a stream of tokens with position information for the parser to consume.
  Handles quoting, escapes, and nested structures (command substitution, etc.) correctly.

  ## Token Types

  Tokens are tuples of `{type, value, line, column}` or `{type, line, column}` for
  valueless tokens like operators.

  ### Word tokens
  - `{:word, parts, line, col}` - A word with parts (literals, variables, etc.)
  - `{:assignment_word, name, value_parts, line, col}` - VAR=value

  ### Operators
  - `{:pipe, line, col}` - |
  - `{:and_if, line, col}` - &&
  - `{:or_if, line, col}` - ||
  - `{:background, line, col}` - &
  - `{:semi, line, col}` - ;
  - `{:dsemi, line, col}` - ;;
  - `{:semi_and, line, col}` - ;&
  - `{:dsemi_and, line, col}` - ;;&
  - `{:newline, line, col}` - \n
  - `{:lparen, line, col}` - (
  - `{:rparen, line, col}` - )
  - `{:lbrace, line, col}` - {
  - `{:rbrace, line, col}` - }

  ### Redirections
  - `{:less, fd, line, col}` - <
  - `{:greater, fd, line, col}` - >
  - `{:dgreater, fd, line, col}` - >>
  - `{:lessand, fd, line, col}` - <&
  - `{:greaterand, fd, line, col}` - >&
  - `{:lessgreat, fd, line, col}` - <>
  - `{:dless, fd, line, col}` - << (heredoc)
  - `{:dlessdash, fd, line, col}` - <<- (heredoc with tab stripping)
  - `{:tless, fd, line, col}` - <<< (herestring)
  - `{:andgreat, line, col}` - &>
  - `{:anddgreat, line, col}` - &>>

  ### Reserved words (context-dependent)
  - `{:if, line, col}`
  - `{:then, line, col}`
  - `{:else, line, col}`
  - `{:elif, line, col}`
  - `{:fi, line, col}`
  - `{:case, line, col}`
  - `{:esac, line, col}`
  - `{:for, line, col}`
  - `{:while, line, col}`
  - `{:until, line, col}`
  - `{:do, line, col}`
  - `{:done, line, col}`
  - `{:in, line, col}`
  - `{:function, line, col}`
  - `{:bang, line, col}` - !

  ### Test constructs
  - `{:lbracket, line, col}` - [
  - `{:rbracket, line, col}` - ]
  - `{:dlbracket, line, col}` - [[
  - `{:drbracket, line, col}` - ]]

  ### Arithmetic
  - `{:arith_command, content, line, col}` - ((...)) arithmetic command with raw content
  - `{:dlparen, line, col}` - (( (only in subshell contexts like $((expr)))
  - `{:drparen, line, col}` - ))

  ### Special
  - `{:eof, line, col}` - End of input
  - `{:comment, text, line, col}` - # comment
  """

  # Reserved words that can start a command
  @reserved_words ~w(if then else elif fi case esac for while until do done in function)

  # Characters that are always special (metacharacters)
  @metacharacters [?\s, ?\t, ?\n, ?|, ?&, ?;, ?(, ?), ?<, ?>]

  # Unicode lookalike characters that should be flagged as errors (SC1015-SC1018, SC1100)
  # Maps codepoint to {error_code, description, replacement}
  @unicode_lookalikes %{
    # Curly double quotes - SC1015
    0x201C => {"SC1015", "Unicode left double quote \u201C", "\""},
    0x201D => {"SC1015", "Unicode right double quote \u201D", "\""},
    # Curly single quotes - SC1016
    0x2018 => {"SC1016", "Unicode left single quote \u2018", "'"},
    0x2019 => {"SC1016", "Unicode right single quote \u2019", "'"},
    # Non-breaking space - SC1018
    0x00A0 => {"SC1018", "Unicode non-breaking space", "regular space"},
    # Acute accent (wrong backtick) - SC1077
    0x00B4 => {"SC1077", "Unicode acute accent \u00B4 (backtick slants wrong)", "`"},
    # En-dash and em-dash - SC1100
    0x2013 => {"SC1100", "Unicode en-dash \u2013", "-"},
    0x2014 => {"SC1100", "Unicode em-dash \u2014", "-"}
  }

  @type position :: {line :: pos_integer(), column :: pos_integer()}

  @type token ::
          {:word, [word_part()], pos_integer(), pos_integer()}
          | {:assignment_word, String.t(), [word_part()], pos_integer(), pos_integer()}
          | {:append_word, String.t(), [word_part()], pos_integer(), pos_integer()}
          | {:arith_command, String.t(), pos_integer(), pos_integer()}
          | {atom(), pos_integer(), pos_integer()}
          | {atom(), non_neg_integer(), pos_integer(), pos_integer()}
          | {:comment, String.t(), pos_integer(), pos_integer()}

  @type word_part ::
          {:literal, String.t()}
          | {:single_quoted, String.t()}
          | {:double_quoted, [word_part()]}
          | {:variable, String.t()}
          | {:variable_braced, String.t(), keyword()}
          | {:command_subst, [token()]}
          | {:process_subst_in, [token()]}
          | {:process_subst_out, [token()]}
          | {:arith_expand, String.t()}
          | {:backtick, String.t()}
          | {:brace_expand, brace_spec()}

  @type brace_spec :: %{
          type: :list | :range,
          items: [[word_part()]] | nil,
          range_start: String.t() | nil,
          range_end: String.t() | nil,
          step: integer() | nil,
          zero_pad: non_neg_integer() | nil
        }

  @type heredoc_pending :: %{
          delimiter: String.t(),
          strip_tabs: boolean(),
          expand: boolean(),
          start_line: pos_integer(),
          start_col: pos_integer()
        }

  @type state :: %{
          input: String.t(),
          pos: non_neg_integer(),
          line: pos_integer(),
          column: pos_integer(),
          # Context tracking for [[ ]] regex patterns
          in_test_expr: boolean(),
          after_regex_op: boolean(),
          # Pending heredocs to be consumed after newline
          pending_heredocs: [heredoc_pending()]
        }

  @doc """
  Tokenize a Bash script into a list of tokens.

  Returns `{:ok, tokens}` or `{:error, reason, line, column}`.
  """
  @spec tokenize(String.t()) ::
          {:ok, [token()]} | {:error, String.t(), pos_integer(), pos_integer()}
  def tokenize(input) when is_binary(input) do
    # Check for common script issues before tokenizing
    case check_script_start(input) do
      {:error, _, _, _} = err ->
        err

      :ok ->
        state = %{
          input: input,
          pos: 0,
          line: 1,
          column: 1,
          in_test_expr: false,
          after_regex_op: false,
          pending_heredocs: []
        }

        tokenize_loop(state, [])
    end
  end

  # Check for common issues at the start of a script
  defp check_script_start(input) do
    cond do
      # SC1082: UTF-8 BOM at start of file
      String.starts_with?(input, <<0xEF, 0xBB, 0xBF>>) ->
        {:error, "(SC1082) UTF-8 BOM detected - remove the BOM from the start of the file", 1, 1}

      # SC1084: !# instead of #!
      String.starts_with?(input, "!#") ->
        {:error, "(SC1084) Shebang uses !# instead of #! - use #! for shebang", 1, 1}

      # SC1104: !/bin/bash instead of #!/bin/bash (missing #)
      Regex.match?(~r/^!/u, input) and Regex.match?(~r/^![\/a-zA-Z]/u, input) ->
        {:error, "(SC1104) Use `#!` for shebang, not just `!`. Add `#` before the `!`", 1, 1}

      # SC1114: Leading whitespace before shebang
      Regex.match?(~r/^[ \t]+#!/, input) ->
        {:error, "(SC1114) Shebang has leading whitespace - remove spaces/tabs before #!", 1, 1}

      # SC1115: Space between # and !
      String.starts_with?(input, "# !") or String.starts_with?(input, "#  !") ->
        {:error, "(SC1115) Space between # and ! in shebang - use #! without spaces", 1, 1}

      # SC1113: #/bin/bash or # /bin/bash instead of #!/bin/bash (missing !)
      Regex.match?(~r/^#[ \t]*\/[a-zA-Z]/u, input) ->
        {:error, "(SC1113) Use `#!` for shebang, not just `#`. Add `!` after the `#`", 1, 1}

      true ->
        :ok
    end
  end

  defp tokenize_loop(state, acc) do
    case read_token(state) do
      {:ok, {:eof, _, _} = token, _state} ->
        {:ok, Enum.reverse([token | acc])}

      {:ok, {:newline, _, _} = token, new_state} ->
        # Check for pending heredocs and consume their content
        case consume_pending_heredocs(new_state) do
          {:ok, heredoc_tokens, state_after_heredocs} ->
            tokenize_loop(state_after_heredocs, heredoc_tokens ++ [token | acc])

          {:error, _, _, _} = err ->
            err
        end

      {:ok, token, new_state} ->
        # Check for assignment spacing errors before continuing
        case check_assignment_spacing(token, acc) do
          {:error, _, _, _} = err ->
            err

          :ok ->
            # Track heredoc markers - when we see dless/dlessdash followed by a word
            new_state = maybe_track_heredoc(token, acc, new_state)
            tokenize_loop(new_state, [token | acc])
        end

      {:error, reason, line, col} ->
        {:error, reason, line, col}
    end
  end

  # Check for common assignment spacing mistakes
  # Note: We skip this check inside test expressions ([ ] or [[ ]])
  defp check_assignment_spacing(current_token, prev_tokens) do
    # Don't flag assignment errors inside test expressions
    if inside_test_expression?(prev_tokens) do
      :ok
    else
      check_assignment_spacing_impl(current_token, prev_tokens)
    end
  end

  defp inside_test_expression?(tokens) do
    # Check if we've seen [ or [[ without a closing ] or ]]
    Enum.reduce_while(tokens, 0, fn token, depth ->
      case token do
        {:lbracket, _, _} -> {:halt, depth + 1}
        {:dlbracket, _, _} -> {:halt, depth + 1}
        {:rbracket, _, _} -> {:cont, max(0, depth - 1)}
        {:drbracket, _, _} -> {:cont, max(0, depth - 1)}
        _ -> {:cont, depth}
      end
    end) > 0
  end

  defp check_assignment_spacing_impl(current_token, prev_tokens) do
    case {current_token, prev_tokens} do
      # SC1007: VAR= value (space after =)
      # assignment_word with empty value, followed by a word
      {{:word, _, line, col}, [{:assignment_word, var_name, [], _, _} | _]} ->
        {:error,
         "(SC1007) Remove space after = in assignment, or quote the value if intentionally empty - #{var_name}= followed by word",
         line, col}

      # SC1068: VAR = value (spaces around =)
      # word that is just "=", preceded by a variable-name-like word
      {{:word, [{:literal, "="}], line, col}, [{:word, [{:literal, var_name}], _, _} | _]}
      when is_binary(var_name) ->
        if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, var_name) do
          {:error,
           "(SC1068) Remove spaces around = in assignment - use #{var_name}=value not #{var_name} = value",
           line, col}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # Track heredoc when we see a word token after dless/dlessdash
  defp maybe_track_heredoc({:word, parts, _, _} = _word_token, acc, state) do
    case acc do
      [{:dless, _fd, line, col} | _] ->
        {delimiter, expand} = extract_heredoc_delimiter(parts)

        pending = %{
          delimiter: delimiter,
          strip_tabs: false,
          expand: expand,
          start_line: line,
          start_col: col
        }

        %{state | pending_heredocs: state.pending_heredocs ++ [pending]}

      [{:dlessdash, _fd, line, col} | _] ->
        {delimiter, expand} = extract_heredoc_delimiter(parts)

        pending = %{
          delimiter: delimiter,
          strip_tabs: true,
          expand: expand,
          start_line: line,
          start_col: col
        }

        %{state | pending_heredocs: state.pending_heredocs ++ [pending]}

      _ ->
        state
    end
  end

  defp maybe_track_heredoc(_token, _acc, state), do: state

  # Extract delimiter string and whether to expand variables
  defp extract_heredoc_delimiter(parts) do
    case parts do
      # Quoted delimiter - no expansion
      [{:single_quoted, delim}] ->
        {delim, false}

      [{:double_quoted, inner_parts}] ->
        delim =
          Enum.map_join(inner_parts, "", fn
            {:literal, s} -> s
            _ -> ""
          end)

        {delim, false}

      # Unquoted delimiter - allows expansion
      _ ->
        delim =
          Enum.map_join(parts, "", fn
            {:literal, s} -> s
            _ -> ""
          end)

        {delim, true}
    end
  end

  # Consume heredoc content for all pending heredocs
  defp consume_pending_heredocs(%{pending_heredocs: []} = state) do
    {:ok, [], state}
  end

  defp consume_pending_heredocs(state) do
    consume_heredocs(state.pending_heredocs, state, [])
  end

  defp consume_heredocs([], state, heredoc_tokens) do
    {:ok, heredoc_tokens, %{state | pending_heredocs: []}}
  end

  defp consume_heredocs([pending | rest], state, heredoc_tokens) do
    case read_heredoc_content(state, pending) do
      {:ok, token, new_state} ->
        consume_heredocs(rest, new_state, [token | heredoc_tokens])

      {:error, _, _, _} = err ->
        err
    end
  end

  # Read heredoc content until delimiter
  defp read_heredoc_content(state, pending) do
    read_heredoc_lines(state, pending.delimiter, pending.strip_tabs, [])
  end

  defp read_heredoc_lines(state, delimiter, strip_tabs, acc) do
    case read_line(state) do
      {:eof, state} ->
        # EOF before finding delimiter - error
        {:error, "here-document delimited by end-of-file (wanted `#{delimiter}')", state.line,
         state.column}

      {:ok, line, new_state} ->
        check_line = if strip_tabs, do: String.trim_leading(line, "\t"), else: line

        case check_heredoc_delimiter(check_line, delimiter, state.line, line, strip_tabs) do
          :match ->
            # Found delimiter - build heredoc content token
            content = Enum.reverse(acc) |> Enum.join("\n")
            content = if content == "", do: "", else: content <> "\n"
            token = {:heredoc_content, content, delimiter, strip_tabs}
            {:ok, token, new_state}

          {:error, _, _, _} = err ->
            err

          :no_match ->
            content_line = if strip_tabs, do: String.trim_leading(line, "\t"), else: line
            read_heredoc_lines(new_state, delimiter, strip_tabs, [content_line | acc])
        end
    end
  end

  # Check if a line is a valid heredoc delimiter, detecting common errors
  # line: the (possibly tab-stripped) line to check
  # original_line: the original line before tab stripping
  # strip_tabs: true if <<- heredoc (tabs should be stripped)
  defp check_heredoc_delimiter(line, delimiter, line_num, original_line, strip_tabs) do
    trimmed = String.trim_trailing(line)
    fully_trimmed = String.trim(line)

    cond do
      # Exact match - success
      line == delimiter ->
        :match

      # SC1039: For << heredocs, end token must not be indented
      # If strip_tabs is false and fully_trimmed matches but original has leading whitespace
      not strip_tabs and fully_trimmed == delimiter and
          String.trim_leading(original_line) != original_line ->
        {:error,
         "(SC1039) Remove indentation before end token `#{delimiter}` (or use <<- and indent with tabs)",
         line_num, 0}

      # SC1040: For <<- heredocs, indentation must use tabs not spaces
      # If strip_tabs is true and fully_trimmed matches but original_line has leading spaces
      strip_tabs and fully_trimmed == delimiter and has_leading_spaces?(original_line) ->
        {:error,
         "(SC1040) When using <<-, indent with tabs instead of spaces. Spaces are not stripped by <<-",
         line_num, 0}

      # SC1118: Trailing whitespace after end token
      trimmed == delimiter and line != delimiter ->
        {:error,
         "(SC1118) Heredoc end token `#{delimiter}` has trailing whitespace. Remove spaces after the delimiter",
         line_num, String.length(delimiter)}

      # SC1043: Case mismatch in delimiter
      String.downcase(trimmed) == String.downcase(delimiter) and trimmed != delimiter ->
        {:error,
         "(SC1043) Heredoc delimiter case mismatch: found `#{trimmed}` but expected `#{delimiter}`. Delimiters are case-sensitive",
         line_num, 0}

      # SC1119: Missing linefeed before ) - delimiter immediately followed by )
      String.starts_with?(trimmed, delimiter) and
          String.starts_with?(String.slice(trimmed, String.length(delimiter)..-1//1), ")") ->
        {:error,
         "(SC1119) Add a linefeed between heredoc end token `#{delimiter}` and the closing ). Put ) on its own line",
         line_num, String.length(delimiter)}

      # SC1120: Comment after end token
      String.starts_with?(trimmed, delimiter <> " #") or
        String.starts_with?(trimmed, delimiter <> "\t#") or trimmed == delimiter <> "#" ->
        {:error,
         "(SC1120) No comments allowed after heredoc end token `#{delimiter}`. Put the comment on the next line",
         line_num, String.length(delimiter)}

      # SC1121/SC1122: Syntax after heredoc body - operators that should be on << line
      String.starts_with?(trimmed, delimiter) and heredoc_trailing_syntax?(trimmed, delimiter) ->
        suffix = String.slice(trimmed, String.length(delimiter)..-1//1) |> String.trim_leading()

        {:error,
         "(SC1122) Nothing allowed after heredoc end token. Move `#{suffix}` to the line with <<",
         line_num, String.length(delimiter)}

      # SC1041: End token found but not on separate line (has prefix)
      # Check if line contains delimiter but has content before it
      String.contains?(line, delimiter) and not String.starts_with?(line, delimiter) ->
        {:error,
         "(SC1041) Found `#{delimiter}` but not on a separate line. The end token must be alone on its line",
         line_num, 0}

      true ->
        :no_match
    end
  end

  # Check if line has leading spaces (not just tabs)
  # For SC1040: <<- only strips tabs, so spaces in indentation are an error
  defp has_leading_spaces?(line) do
    case line do
      " " <> _ -> true
      "\t" <> rest -> has_leading_spaces?(rest)
      _ -> false
    end
  end

  # Check if there's trailing syntax after the delimiter that should be on the << line
  defp heredoc_trailing_syntax?(line, delimiter) do
    suffix = String.slice(line, String.length(delimiter)..-1//1) |> String.trim()
    # Check for common operators/syntax that people mistakenly put after heredoc
    suffix != "" and
      (String.starts_with?(suffix, "|") or
         String.starts_with?(suffix, "&") or
         String.starts_with?(suffix, ";") or
         String.starts_with?(suffix, ">") or
         String.starts_with?(suffix, ")") or
         Regex.match?(~r/^\d*[<>]/, suffix))
  end

  # Read a single line from input
  defp read_line(state) do
    read_line_chars(state, [])
  end

  defp read_line_chars(state, acc) do
    case peek(state) do
      nil ->
        if acc == [] do
          {:eof, state}
        else
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
        end

      ?\n ->
        line = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, line, advance(state)}

      c ->
        read_line_chars(advance(state), [c | acc])
    end
  end

  @doc """
  Read a single token from the input.

  Returns `{:ok, token, new_state}` or `{:error, reason, line, column}`.
  """
  @spec read_token(state()) ::
          {:ok, token(), state()} | {:error, String.t(), pos_integer(), pos_integer()}
  def read_token(state) do
    # Track column before skipping blanks for SC1020 detection
    col_before = state.column

    case skip_blanks(state) do
      {:error, _, _, _} = err ->
        err

      {:ok, state} ->
        state = Map.put(state, :col_before_blanks, col_before)

        # After =~ in [[ ]], read next token as regex pattern
        if state.after_regex_op do
          read_regex_pattern(state)
        else
          read_token_normal(state)
        end
    end
  end

  defp read_token_normal(state) do
    # Check for problematic Unicode characters before processing
    case check_unicode_lookalike(state) do
      {:error, _, _, _} = err ->
        err

      :ok ->
        read_token_dispatch(state)
    end
  end

  defp read_token_dispatch(state) do
    case peek(state) do
      nil ->
        {:ok, {:eof, state.line, state.column}, state}

      ?\n ->
        {:ok, {:newline, state.line, state.column}, advance(state)}

      ?# ->
        read_comment(state)

      ?| ->
        read_pipe_or_or(state)

      ?& ->
        read_amp(state)

      ?; ->
        read_semicolon(state)

      ?( ->
        read_lparen(state)

      ?) ->
        {:ok, {:rparen, state.line, state.column}, advance(state)}

      ?{ ->
        read_lbrace_or_brace_expansion(state)

      ?} ->
        {:ok, {:rbrace, state.line, state.column}, advance(state)}

      ?< ->
        read_less(state)

      ?> ->
        read_greater(state)

      ?[ ->
        read_lbracket(state)

      ?] ->
        read_rbracket(state)

      ?! ->
        {:ok, {:bang, state.line, state.column}, advance(state)}

      c when c in ?0..?9 ->
        # Check if this is an io_number (digit followed by < or >)
        case peek_next(state) do
          next when next in [?<, ?>] ->
            # This is an io_number - read the digit and return
            fd = c - ?0
            {:ok, {:io_number, fd, state.line, state.column}, advance(state)}

          _ ->
            # Just a regular word starting with a digit
            read_word(state)
        end

      _ ->
        read_word(state)
    end
  end

  # Read a regex pattern after =~ in [[ ]]
  # Preserves regex metacharacters that would normally be interpreted as shell syntax
  defp read_regex_pattern(state) do
    start_line = state.line
    start_col = state.column

    case peek(state) do
      nil ->
        # Empty pattern at end of input
        {:ok, {:eof, state.line, state.column}, state}

      ?] ->
        # Check for ]] which ends the test expression
        if peek_next(state) == ?] do
          # Don't consume ]], let read_rbracket handle it
          # Actually, this would be a syntax error in bash: [[ x =~ ]]
          {:error, "expected regex pattern", state.line, state.column}
        else
          # Single ] is part of regex pattern (character class end)
          read_regex_pattern_parts(state, [], start_line, start_col)
        end

      _ ->
        read_regex_pattern_parts(state, [], start_line, start_col)
    end
  end

  # Read parts of a regex pattern
  defp read_regex_pattern_parts(state, acc, start_line, start_col) do
    # Start with bracket_depth = 0, tracking [ ] nesting for character classes
    read_regex_pattern_parts(state, acc, start_line, start_col, 0)
  end

  defp read_regex_pattern_parts(state, acc, start_line, start_col, bracket_depth) do
    case peek(state) do
      nil ->
        finalize_regex_pattern(acc, start_line, start_col, state)

      # Whitespace terminates regex (unless escaped or inside character class)
      c when c in [?\s, ?\t, ?\n] ->
        if bracket_depth > 0 do
          # Inside character class, whitespace is literal
          read_regex_pattern_parts(
            advance(state),
            [{:literal, <<c>>} | acc],
            start_line,
            start_col,
            bracket_depth
          )
        else
          finalize_regex_pattern(acc, start_line, start_col, state)
        end

      # Check for && (and_if) - terminates regex (but not inside character class)
      ?& ->
        if bracket_depth == 0 and peek_next(state) == ?& do
          finalize_regex_pattern(acc, start_line, start_col, state)
        else
          # Single & or inside character class - literal
          read_regex_pattern_parts(
            advance(state),
            [{:literal, "&"} | acc],
            start_line,
            start_col,
            bracket_depth
          )
        end

      # Check for || (or_if) - terminates regex (but not inside character class)
      ?| ->
        if bracket_depth == 0 and peek_next(state) == ?| do
          finalize_regex_pattern(acc, start_line, start_col, state)
        else
          # Single | (regex alternation) or inside character class
          read_regex_pattern_parts(
            advance(state),
            [{:literal, "|"} | acc],
            start_line,
            start_col,
            bracket_depth
          )
        end

      # Opening bracket - start or nested character class (for POSIX classes like [[:space:]])
      ?[ ->
        read_regex_pattern_parts(
          advance(state),
          [{:literal, "["} | acc],
          start_line,
          start_col,
          bracket_depth + 1
        )

      # Closing bracket
      ?] ->
        if bracket_depth > 0 do
          # Inside character class - this closes the class (or nested POSIX class)
          read_regex_pattern_parts(
            advance(state),
            [{:literal, "]"} | acc],
            start_line,
            start_col,
            bracket_depth - 1
          )
        else
          # Not inside character class - check for ]] to end test expression
          if peek_next(state) == ?] do
            finalize_regex_pattern(acc, start_line, start_col, state)
          else
            # Lone ] outside character class (unusual but valid)
            read_regex_pattern_parts(
              advance(state),
              [{:literal, "]"} | acc],
              start_line,
              start_col,
              bracket_depth
            )
          end
        end

      # Escape sequences
      ?\\ ->
        state2 = advance(state)

        case peek(state2) do
          nil ->
            # Trailing backslash
            read_regex_pattern_parts(
              state2,
              [{:literal, "\\"} | acc],
              start_line,
              start_col,
              bracket_depth
            )

          c ->
            # Escaped character (including space)
            read_regex_pattern_parts(
              advance(state2),
              [{:literal, <<c>>} | acc],
              start_line,
              start_col,
              bracket_depth
            )
        end

      # Variable expansion (but not inside character class where $ is literal)
      ?$ ->
        if bracket_depth > 0 do
          # Inside character class, $ is literal
          read_regex_pattern_parts(
            advance(state),
            [{:literal, "$"} | acc],
            start_line,
            start_col,
            bracket_depth
          )
        else
          {:ok, part, new_state} = read_dollar(state)
          read_regex_pattern_parts(new_state, [part | acc], start_line, start_col, bracket_depth)
        end

      # Single-quoted string - literal, no regex interpretation
      ?' ->
        case read_single_quoted(state) do
          {:ok, part, new_state} ->
            read_regex_pattern_parts(
              new_state,
              [part | acc],
              start_line,
              start_col,
              bracket_depth
            )

          {:error, _, _, _} = err ->
            err
        end

      # Double-quoted string - variables expand, but content is literal regex
      ?" ->
        case read_double_quoted(state) do
          {:ok, part, new_state} ->
            read_regex_pattern_parts(
              new_state,
              [part | acc],
              start_line,
              start_col,
              bracket_depth
            )

          {:error, _, _, _} = err ->
            err
        end

      # All other characters are literal regex pattern characters
      # This includes: ( ) { } * + ? ^ $ . and regular chars
      c ->
        read_regex_pattern_parts(
          advance(state),
          [{:literal, <<c>>} | acc],
          start_line,
          start_col,
          bracket_depth
        )
    end
  end

  defp finalize_regex_pattern([], start_line, start_col, _state) do
    {:error, "expected regex pattern", start_line, start_col}
  end

  defp finalize_regex_pattern(acc, start_line, start_col, state) do
    parts = acc |> Enum.reverse() |> merge_adjacent_literals()
    # Clear after_regex_op flag
    new_state = Map.put(state, :after_regex_op, false)
    {:ok, {:regex_pattern, parts, start_line, start_col}, new_state}
  end

  # Skip spaces and tabs (but not newlines)
  # Returns {:ok, state} or {:error, message, line, col}
  defp skip_blanks(state) do
    case peek(state) do
      c when c in [?\s, ?\t] ->
        skip_blanks(advance(state))

      ?\\ ->
        # Check for line continuation (backslash-newline)
        case peek_next(state) do
          ?\n ->
            # Skip both backslash and newline, then continue skipping blanks
            state
            |> advance()
            |> advance()
            |> skip_blanks()

          c when c in [?\s, ?\t] ->
            # SC1101: Check for trailing spaces after backslash before newline
            case check_trailing_spaces_after_backslash(state) do
              {:error, _, _, _} = err -> err
              :ok -> {:ok, state}
            end

          _ ->
            # Backslash followed by something else - not whitespace
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  # SC1101: Check if backslash is followed by only spaces/tabs before newline
  defp check_trailing_spaces_after_backslash(state) do
    # state is positioned at the backslash
    check_only_whitespace_until_newline(advance(state), state.line, state.column)
  end

  defp check_only_whitespace_until_newline(state, backslash_line, backslash_col) do
    case peek(state) do
      c when c in [?\s, ?\t] ->
        check_only_whitespace_until_newline(advance(state), backslash_line, backslash_col)

      ?\n ->
        # Found newline after only whitespace - this is the SC1101 case
        {:error,
         "(SC1101) Trailing spaces after `\\` break line continuation. Remove spaces after the backslash.",
         backslash_line, backslash_col}

      _ ->
        # Found non-whitespace before newline - not the SC1101 pattern
        :ok
    end
  end

  # Peek at current character without consuming
  defp peek(%{input: input, pos: pos}) do
    case input do
      <<_::binary-size(^pos), c, _::binary>> -> c
      _ -> nil
    end
  end

  # Peek at next character (pos + 1)
  defp peek_next(%{input: input, pos: pos}) do
    case input do
      <<_::binary-size(^pos), _, c, _::binary>> -> c
      _ -> nil
    end
  end

  # Advance position by one character
  defp advance(%{input: input, pos: pos, line: line, column: col} = state) do
    case input do
      <<_::binary-size(^pos), ?\n, _::binary>> ->
        %{state | pos: pos + 1, line: line + 1, column: 1}

      <<_::binary-size(^pos), _, _::binary>> ->
        %{state | pos: pos + 1, column: col + 1}

      _ ->
        state
    end
  end

  # Advance by n characters
  defp advance(state, 0), do: state
  defp advance(state, n) when n > 0, do: advance(advance(state), n - 1)

  # Peek at current UTF-8 codepoint (for Unicode detection)
  defp peek_codepoint(%{input: input, pos: pos}) do
    case input do
      <<_::binary-size(^pos), rest::binary>> ->
        case rest do
          <<codepoint::utf8, _::binary>> -> {:ok, codepoint}
          <<byte, _::binary>> -> {:ok, byte}
          <<>> -> nil
        end

      _ ->
        nil
    end
  end

  # Check if current position has a problematic Unicode lookalike character
  defp check_unicode_lookalike(state) do
    case peek_codepoint(state) do
      {:ok, codepoint} ->
        case Map.get(@unicode_lookalikes, codepoint) do
          {code, description, replacement} ->
            {:error, "(#{code}) #{description} - use #{replacement} instead", state.line,
             state.column}

          nil ->
            :ok
        end

      nil ->
        :ok
    end
  end

  # Read a comment (# to end of line) or shebang (#! at line 1, col 1)
  defp read_comment(state) do
    start_line = state.line
    start_col = state.column

    # Check for shebang: #! at the very start of the file
    cond do
      start_line == 1 and start_col == 1 and peek_next(state) == ?! ->
        # Valid shebang position - skip #!
        state = advance(state, 2)
        {interpreter, state} = read_until_newline(state, [])

        # SC1008: Validate the interpreter is a recognized shell
        case validate_shebang_interpreter(interpreter) do
          :ok ->
            {:ok, {:shebang, interpreter, start_line, start_col}, state}

          {:error, msg} ->
            {:error, msg, start_line, start_col}
        end

      # SC1128: Shebang not on first line
      start_line > 1 and peek_next(state) == ?! ->
        {:error, "(SC1128) Shebang (#!) must be on the first line of the script", start_line,
         start_col}

      true ->
        # Regular comment - skip #
        state = advance(state)
        {text, state} = read_until_newline(state, [])
        {:ok, {:comment, text, start_line, start_col}, state}
    end
  end

  # SC1008: Validate shebang interpreter is a recognized shell
  # Recognized: sh, bash, dash, ksh, zsh (and /usr/bin/env variants)
  @recognized_shells ~w(sh bash dash ksh zsh)

  defp validate_shebang_interpreter(interpreter) do
    trimmed = String.trim(interpreter)

    cond do
      # Empty interpreter is fine (will use default shell)
      trimmed == "" ->
        :ok

      # Direct path to shell: /bin/bash, /usr/bin/bash, etc.
      Regex.match?(~r{^/\S*/(#{Enum.join(@recognized_shells, "|")})(\s|$)}, trimmed) ->
        :ok

      # env invocation: /usr/bin/env bash, /bin/env bash, etc.
      Regex.match?(~r{^/\S*/env\s+(#{Enum.join(@recognized_shells, "|")})(\s|$)}, trimmed) ->
        :ok

      # Just the shell name (rare but valid): bash, sh
      Enum.any?(@recognized_shells, fn shell ->
        trimmed == shell or String.starts_with?(trimmed, shell <> " ")
      end) ->
        :ok

      true ->
        shell_name = extract_shell_name(trimmed)

        {:error,
         "(SC1008) Unrecognized shebang interpreter `#{shell_name}`. " <>
           "This parser only supports sh/bash/dash/ksh/zsh scripts"}
    end
  end

  defp extract_shell_name(interpreter) do
    # Extract the shell/command name from the interpreter string
    interpreter
    |> String.split("/")
    |> List.last()
    |> String.split()
    |> List.first()
    |> Kernel.||("unknown")
  end

  defp read_until_newline(state, acc) do
    case peek(state) do
      nil -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
      ?\n -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
      c -> read_until_newline(advance(state), [c | acc])
    end
  end

  # | or ||
  defp read_pipe_or_or(state) do
    start_line = state.line
    start_col = state.column

    case peek_next(state) do
      ?| -> {:ok, {:or_if, start_line, start_col}, advance(state, 2)}
      _ -> {:ok, {:pipe, start_line, start_col}, advance(state)}
    end
  end

  # & or && or &> or &>>
  defp read_amp(state) do
    start_line = state.line
    start_col = state.column

    # SC1109: Check for HTML entities before processing & as operator
    case check_html_entity_at_amp(state) do
      {:error, _, _, _} = err ->
        err

      :ok ->
        case peek_next(state) do
          ?& ->
            {:ok, {:and_if, start_line, start_col}, advance(state, 2)}

          ?> ->
            state2 = advance(state, 2)

            case peek(state2) do
              ?> -> {:ok, {:anddgreat, start_line, start_col}, advance(state2)}
              _ -> {:ok, {:andgreat, start_line, start_col}, state2}
            end

          _ ->
            state1 = advance(state)

            # SC1045: &; is not valid - both & and ; terminate the command
            cond do
              peek(state1) == ?; ->
                {:error, "(SC1045) `&;` is not valid - `&` already terminates the command",
                 start_line, start_col}

              # SC1132: Check for foo&bar pattern (& between words without space)
              word_char_after_amp?(state1) and no_space_before?(state, start_col) ->
                {:error,
                 "(SC1132) `&` terminates the command. Escape it or add a space after if you want to run in background.",
                 start_line, start_col}

              true ->
                {:ok, {:background, start_line, start_col}, state1}
            end
        end
    end
  end

  # Check if next char starts a word (for SC1132)
  defp word_char_after_amp?(state) do
    case peek(state) do
      c when c in [?\s, ?\t, ?\n, nil, ?;, ?|, ?&, ?(, ?), ?<, ?>, ?#] -> false
      _ -> true
    end
  end

  # Check if there was no space before current position (for SC1132)
  defp no_space_before?(state, col) do
    col_before = Map.get(state, :col_before_blanks, 0)
    col_before == col and col > 1
  end

  # SC1109: Check if & starts an HTML entity
  @html_entity_patterns ["amp;", "lt;", "gt;", "nbsp;", "quot;", "#39;", "#x27;"]

  defp check_html_entity_at_amp(state) do
    # Get the text after &
    rest = String.slice(state.input, state.pos + 1, 10)

    found =
      Enum.find(@html_entity_patterns, fn pattern ->
        String.starts_with?(rest, pattern)
      end)

    case found do
      nil ->
        :ok

      pattern ->
        entity = "&" <> pattern
        replacement = html_entity_replacement(pattern)

        {:error,
         "(SC1109) HTML entity `#{entity}` found. Did you copy this code from a webpage? Replace with `#{replacement}`.",
         state.line, state.column}
    end
  end

  defp html_entity_replacement("amp;"), do: "&"
  defp html_entity_replacement("lt;"), do: "<"
  defp html_entity_replacement("gt;"), do: ">"
  defp html_entity_replacement("nbsp;"), do: "a space"
  defp html_entity_replacement("quot;"), do: "\""
  defp html_entity_replacement("#39;"), do: "'"
  defp html_entity_replacement("#x27;"), do: "'"
  defp html_entity_replacement(_), do: "the correct character"

  # ; or ;; or ;& or ;;&
  defp read_semicolon(state) do
    start_line = state.line
    start_col = state.column

    case peek_next(state) do
      ?; ->
        state2 = advance(state, 2)

        case peek(state2) do
          ?& -> {:ok, {:dsemi_and, start_line, start_col}, advance(state2)}
          _ -> {:ok, {:dsemi, start_line, start_col}, state2}
        end

      ?& ->
        {:ok, {:semi_and, start_line, start_col}, advance(state, 2)}

      _ ->
        {:ok, {:semi, start_line, start_col}, advance(state)}
    end
  end

  # ( or ((
  # For ((...)), we collect raw content like $((expr)) to avoid
  # misinterpreting << and >> as heredocs/appends instead of shifts
  defp read_lparen(state) do
    start_line = state.line
    start_col = state.column

    case peek_next(state) do
      ?( ->
        # Arithmetic command: ((expr))
        # Collect raw content until matching ))
        state2 = advance(state, 2)
        read_arith_command_content(state2, 0, [], start_line, start_col)

      _ ->
        {:ok, {:lparen, start_line, start_col}, advance(state)}
    end
  end

  # Read arithmetic command content: ((expr))
  # Similar to read_arith_content but returns an arith_command token
  defp read_arith_command_content(state, depth, acc, start_line, start_col) do
    case {peek(state), peek_next(state)} do
      {nil, _} ->
        {:error, "unterminated arithmetic command", start_line, start_col}

      {?), ?)} when depth == 0 ->
        content = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:arith_command, content, start_line, start_col}, advance(state, 2)}

      {?(, _} ->
        read_arith_command_content(advance(state), depth + 1, [?( | acc], start_line, start_col)

      {?), _} when depth > 0 ->
        read_arith_command_content(advance(state), depth - 1, [?) | acc], start_line, start_col)

      {c, _} ->
        read_arith_command_content(advance(state), depth, [c | acc], start_line, start_col)
    end
  end

  # { can be either command group delimiter or brace expansion like {1..3}
  # Brace expansion: {content} with no spaces, where content contains .. or ,
  defp read_lbrace_or_brace_expansion(state) do
    start_line = state.line
    start_col = state.column

    # Look ahead to see if this is brace expansion
    case peek_brace_expansion(state.input, state.pos + 1) do
      {:brace_expansion, end_pos, content} ->
        # Parse the brace content
        new_state = %{state | pos: end_pos, column: state.column + (end_pos - state.pos)}

        first_part =
          case parse_brace_content(content, state) do
            {:ok, brace_spec} ->
              {:brace_expand, brace_spec}

            :not_expansion ->
              {:literal, "{" <> content <> "}"}
          end

        # Continue reading more word parts after the brace (e.g., {a,b}{1,2} or {a,b}suffix)
        case read_word_parts(new_state, [first_part]) do
          {:ok, parts, final_state} ->
            {:ok, {:word, parts, start_line, start_col}, final_state}

          error ->
            error
        end

      {:literal_brace, end_pos, content} ->
        # Closed brace but no expansion pattern - return as literal word
        new_state = %{state | pos: end_pos, column: state.column + (end_pos - state.pos)}
        first_part = {:literal, "{" <> content <> "}"}

        # Continue reading more word parts after the brace
        case read_word_parts(new_state, [first_part]) do
          {:ok, parts, final_state} ->
            {:ok, {:word, parts, start_line, start_col}, final_state}

          error ->
            error
        end

      :not_brace_expansion ->
        state1 = advance(state)

        # SC1054: { must be followed by whitespace to start a command group
        case peek(state1) do
          c when c not in [nil | @metacharacters] and c not in [?}, ?#] ->
            {:error,
             "(SC1054) `{` is only a reserved word when followed by whitespace. Use `{ #{<<c>>}...` instead of `{#{<<c>>}...`",
             start_line, start_col}

          _ ->
            {:ok, {:lbrace, start_line, start_col}, state1}
        end
    end
  end

  # Check if what follows { looks like brace expansion
  # Returns {:brace_expansion, end_pos, content} or {:literal_brace, end_pos, content} or :not_brace_expansion
  defp peek_brace_expansion(input, pos) do
    input_len = byte_size(input)

    # Scan ahead to find the closing } without hitting whitespace
    case scan_for_closing_brace(input, pos, input_len, false, false, 0) do
      {:found, end_pos, has_dots_or_comma} when has_dots_or_comma ->
        content = binary_part(input, pos, end_pos - pos - 1)
        {:brace_expansion, end_pos, content}

      {:found, end_pos, _has_dots_or_comma} ->
        # Found closing brace but no dots/comma - treat as literal brace word
        content = binary_part(input, pos, end_pos - pos - 1)
        {:literal_brace, end_pos, content}

      _ ->
        :not_brace_expansion
    end
  end

  defp scan_for_closing_brace(input, pos, len, has_dots, has_comma, depth) when pos < len do
    case :binary.at(input, pos) do
      # Found closing brace
      ?} when depth == 0 ->
        {:found, pos + 1, has_dots or has_comma}

      ?} ->
        scan_for_closing_brace(input, pos + 1, len, has_dots, has_comma, depth - 1)

      # Whitespace at top level means it's a command group, not brace expansion
      c when c in [?\s, ?\t, ?\n, ?\r] and depth == 0 ->
        :not_found

      # Whitespace inside nested braces is ok
      c when c in [?\s, ?\t, ?\n, ?\r] ->
        scan_for_closing_brace(input, pos + 1, len, has_dots, has_comma, depth)

      # Check for .. (range expansion)
      ?. ->
        if pos + 1 < len and :binary.at(input, pos + 1) == ?. do
          scan_for_closing_brace(input, pos + 2, len, true, has_comma, depth)
        else
          scan_for_closing_brace(input, pos + 1, len, has_dots, has_comma, depth)
        end

      # Comma means list expansion
      ?, ->
        scan_for_closing_brace(input, pos + 1, len, has_dots, true, depth)

      # Nested brace - track depth
      ?{ ->
        scan_for_closing_brace(input, pos + 1, len, has_dots, has_comma, depth + 1)

      # Any other character, continue scanning
      _ ->
        scan_for_closing_brace(input, pos + 1, len, has_dots, has_comma, depth)
    end
  end

  defp scan_for_closing_brace(_input, _pos, _len, _has_dots, _has_comma, _depth), do: :not_found

  # < or << or <<- or <<< or <& or <>
  defp read_less(state) do
    start_line = state.line
    start_col = state.column

    # Check for fd number prefix (already consumed in read_word for redirects)
    case peek_next(state) do
      ?( ->
        # Process substitution: <(...)
        # skip <(
        state2 = advance(state, 2)

        case read_process_subst(state2, start_line, start_col) do
          {:ok, content, new_state} ->
            {:ok, {:word, [{:process_subst_in, content}], start_line, start_col}, new_state}

          {:error, _, _, _} = err ->
            err
        end

      ?< ->
        state2 = advance(state, 2)

        case peek(state2) do
          ?- -> {:ok, {:dlessdash, 0, start_line, start_col}, advance(state2)}
          ?< -> {:ok, {:tless, 0, start_line, start_col}, advance(state2)}
          _ -> {:ok, {:dless, 0, start_line, start_col}, state2}
        end

      ?& ->
        {:ok, {:lessand, 0, start_line, start_col}, advance(state, 2)}

      ?> ->
        {:ok, {:lessgreat, 0, start_line, start_col}, advance(state, 2)}

      _ ->
        {:ok, {:less, 0, start_line, start_col}, advance(state)}
    end
  end

  # > or >> or >& or >(
  defp read_greater(state) do
    start_line = state.line
    start_col = state.column

    case peek_next(state) do
      ?( ->
        # Process substitution: >(...)
        # skip >(
        state2 = advance(state, 2)

        case read_process_subst(state2, start_line, start_col) do
          {:ok, content, new_state} ->
            {:ok, {:word, [{:process_subst_out, content}], start_line, start_col}, new_state}

          {:error, _, _, _} = err ->
            err
        end

      ?> ->
        {:ok, {:dgreater, 1, start_line, start_col}, advance(state, 2)}

      ?& ->
        {:ok, {:greaterand, 1, start_line, start_col}, advance(state, 2)}

      _ ->
        {:ok, {:greater, 1, start_line, start_col}, advance(state)}
    end
  end

  # [ or [[
  defp read_lbracket(state) do
    start_line = state.line
    start_col = state.column

    case peek_next(state) do
      ?[ ->
        # Enter test expression context for [[ ]]
        new_state = state |> advance(2) |> Map.put(:in_test_expr, true)
        {:ok, {:dlbracket, start_line, start_col}, new_state}

      _ ->
        {:ok, {:lbracket, start_line, start_col}, advance(state)}
    end
  end

  # ] or ]]
  defp read_rbracket(state) do
    start_line = state.line
    start_col = state.column

    case peek_next(state) do
      ?] ->
        # Exit test expression context
        new_state =
          state
          |> advance(2)
          |> Map.put(:in_test_expr, false)
          |> Map.put(:after_regex_op, false)

        {:ok, {:drbracket, start_line, start_col}, new_state}

      _ ->
        # SC1020: Check if no whitespace was skipped before ]
        # This indicates "foo]" pattern where ] is missing a preceding space
        col_before = Map.get(state, :col_before_blanks, 0)
        no_space_before = col_before == start_col and start_col > 1

        token_type = if no_space_before, do: :rbracket_no_space, else: :rbracket
        new_state = advance(state)

        # SC1136: Check if ] is followed by characters that should have a separator
        case check_chars_after_bracket(new_state) do
          {:error, _, _, _} = err -> err
          :ok -> {:ok, {token_type, start_line, start_col}, new_state}
        end
    end
  end

  # SC1136: Check for word-starting characters immediately after ]
  defp check_chars_after_bracket(state) do
    case peek(state) do
      # OK: whitespace, operators, EOF, or = (for array subscripts like [key]=value)
      c when c in [nil, ?\s, ?\t, ?\n, ?|, ?&, ?;, ?(, ?), ?<, ?>, ?#, ?=] ->
        :ok

      # Suspicious: word starters, quotes, expansions
      _c ->
        {:error,
         "(SC1136) Unexpected characters after `]`. Add a space or semicolon after `]`, or quote the `]` if literal.",
         state.line, state.column}
    end
  end

  @doc """
  Read a word token (including assignments and redirections with fd prefixes).

  Words can contain:
  - Literal text
  - Single-quoted strings
  - Double-quoted strings (with expansions)
  - Variable references ($VAR, ${VAR}, ${VAR:-default}, etc.)
  - Command substitutions ($(cmd) or `cmd`)
  - Arithmetic expansions ($((expr)))
  """
  def read_word(state) do
    start_line = state.line
    start_col = state.column

    case read_word_parts(state, []) do
      {:ok, [], state} ->
        # No word parts - shouldn't happen if called correctly
        {:error, "unexpected character", state.line, state.column}

      {:ok, parts, new_state} ->
        # Check if this is an assignment (VAR=value)
        case build_word_token(parts, start_line, start_col) do
          {:error, _, _, _} = err ->
            err

          token ->
            # SC1069: Check for reserved word immediately followed by [
            case check_keyword_bracket_collision(token) do
              {:error, _, _, _} = err ->
                err

              :ok ->
                # Check for reserved words
                token = maybe_reserved_word(token)

                # Check if this is =~ inside [[ ]] - set flag for next token
                new_state = maybe_set_regex_op_flag(token, new_state)

                {:ok, token, new_state}
            end
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  # If we just tokenized =~ inside a test expression, set the flag
  # so the next token is read as a regex pattern
  defp maybe_set_regex_op_flag({:word, [{:literal, "=~"}], _, _}, %{in_test_expr: true} = state) do
    Map.put(state, :after_regex_op, true)
  end

  defp maybe_set_regex_op_flag(_token, state), do: state

  defp read_word_parts(state, acc) do
    case peek(state) do
      nil ->
        {:ok, Enum.reverse(acc), state}

      c when c in @metacharacters ->
        {:ok, Enum.reverse(acc), state}

      ?\\ ->
        # Escape sequence
        {:ok, part, new_state} = read_escape(state)
        read_word_parts(new_state, [part | acc])

      ?' ->
        # Single-quoted string
        case read_single_quoted(state) do
          {:ok, part, new_state} -> read_word_parts(new_state, [part | acc])
          {:error, _, _, _} = err -> err
        end

      ?" ->
        # Double-quoted string
        case read_double_quoted(state) do
          {:ok, part, new_state} -> read_word_parts(new_state, [part | acc])
          {:error, _, _, _} = err -> err
        end

      ?$ ->
        # Variable, command substitution, or arithmetic expansion
        case read_dollar(state) do
          {:ok, part, new_state} -> read_word_parts(new_state, [part | acc])
          {:error, _, _, _} = err -> err
        end

      ?` ->
        # Backtick command substitution
        case read_backtick(state) do
          {:ok, part, new_state} -> read_word_parts(new_state, [part | acc])
          {:error, _, _, _} = err -> err
        end

      ?] ->
        # ] ends word in some contexts, but can be literal too
        {:ok, Enum.reverse(acc), state}

      ?[ ->
        # [ starts array subscript in word context - read until matching ]
        {:ok, part, new_state} = read_array_subscript(state)
        read_word_parts(new_state, [part | acc])

      ?{ ->
        # { starts brace expansion in word context - read until matching }
        {:ok, part, new_state} = read_brace_expansion(state)
        read_word_parts(new_state, [part | acc])

      ?} ->
        # } ends the word (end of brace expansion context)
        {:ok, Enum.reverse(acc), state}

      _ ->
        # Regular character - read literal run
        case read_literal(state) do
          {:ok, part, new_state} -> read_word_parts(new_state, [part | acc])
          {:error, _, _, _} = err -> err
        end
    end
  end

  # Read a run of literal characters (not special)
  defp read_literal(state) do
    case read_literal_chars(state, []) do
      {:ok, chars, new_state} ->
        text = chars |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:literal, text}, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  defp read_literal_chars(state, acc) do
    # Check for Unicode lookalikes first
    case check_unicode_lookalike(state) do
      {:error, _, _, _} = err ->
        err

      :ok ->
        case peek(state) do
          nil -> {:ok, acc, state}
          c when c in @metacharacters -> {:ok, acc, state}
          c when c in [?\\, ?', ?", ?$, ?`, ?], ?[, ?{, ?}] -> {:ok, acc, state}
          c -> read_literal_chars(advance(state), [c | acc])
        end
    end
  end

  # Read array subscript [index] - returns the content including brackets as a literal
  defp read_array_subscript(state) do
    # skip '['
    state = advance(state)
    {content, new_state} = read_until_bracket_close(state, [])

    case peek(new_state) do
      ?] ->
        text = "[" <> (content |> Enum.reverse() |> IO.iodata_to_binary()) <> "]"
        {:ok, {:literal, text}, advance(new_state)}

      _ ->
        {:error, "unterminated array subscript", state.line, state.column}
    end
  end

  defp read_until_bracket_close(state, acc) do
    case peek(state) do
      nil -> {acc, state}
      ?] -> {acc, state}
      c -> read_until_bracket_close(advance(state), [c | acc])
    end
  end

  # Read brace expansion {content} - parses and returns {:brace_expand, spec} or {:literal, text}
  defp read_brace_expansion(state) do
    start_state = state
    # skip '{'
    state = advance(state)
    {content, new_state} = read_until_brace_close(state, [], 1)

    case peek(new_state) do
      ?} ->
        content_str = content |> Enum.reverse() |> IO.iodata_to_binary()
        final_state = advance(new_state)

        # Try to parse as brace expansion
        case parse_brace_content(content_str, start_state) do
          {:ok, brace_spec} ->
            {:ok, {:brace_expand, brace_spec}, final_state}

          :not_expansion ->
            # Not a valid brace expansion, return as literal
            text = "{" <> content_str <> "}"
            {:ok, {:literal, text}, final_state}
        end

      _ ->
        {:error, "unterminated brace expansion", state.line, state.column}
    end
  end

  defp read_until_brace_close(state, acc, depth) do
    case peek(state) do
      nil -> {acc, state}
      ?} when depth == 1 -> {acc, state}
      ?} -> read_until_brace_close(advance(state), [?} | acc], depth - 1)
      ?{ -> read_until_brace_close(advance(state), [?{ | acc], depth + 1)
      c -> read_until_brace_close(advance(state), [c | acc], depth)
    end
  end

  # Parse brace content to determine if it's a range or list expansion
  defp parse_brace_content(content, _state) do
    cond do
      # Empty or single item without comma/range - not expansion
      content == "" ->
        :not_expansion

      # Check for range pattern: start..end or start..end..step
      String.contains?(content, "..") and not String.contains?(content, ",") ->
        parse_brace_range(content)

      # Check for comma-separated list
      String.contains?(content, ",") ->
        parse_brace_list(content)

      # Single item without comma or range - not expansion
      true ->
        :not_expansion
    end
  end

  # Parse range: {1..10} or {a..z} or {1..10..2} or {01..05}
  defp parse_brace_range(content) do
    parts = String.split(content, "..")

    case parts do
      [start_str, end_str] ->
        zero_pad = detect_zero_padding(start_str, end_str)

        {:ok,
         %{
           type: :range,
           range_start: start_str,
           range_end: end_str,
           step: nil,
           zero_pad: zero_pad
         }}

      [start_str, end_str, step_str] ->
        case Integer.parse(step_str) do
          {step, ""} when step != 0 ->
            zero_pad = detect_zero_padding(start_str, end_str)

            {:ok,
             %{
               type: :range,
               range_start: start_str,
               range_end: end_str,
               step: step,
               zero_pad: zero_pad
             }}

          _ ->
            :not_expansion
        end

      _ ->
        :not_expansion
    end
  end

  # Detect zero-padding from start value like "01" or "001"
  defp detect_zero_padding(start_str, end_str) do
    start_pad = count_leading_zeros(start_str)
    end_pad = count_leading_zeros(end_str)

    cond do
      start_pad > 0 -> String.length(start_str)
      end_pad > 0 -> String.length(end_str)
      true -> nil
    end
  end

  defp count_leading_zeros(str) do
    str
    |> String.graphemes()
    |> Enum.take_while(&(&1 == "0"))
    |> length()
  end

  # Parse comma-separated list: {a,b,c}
  # Items can contain nested braces
  defp parse_brace_list(content) do
    items = split_brace_items(content)

    # Parse each item into word parts (supporting nested braces)
    parsed_items = Enum.map(items, &parse_brace_item/1)

    {:ok, %{type: :list, items: parsed_items}}
  end

  # Split on commas, respecting nested braces
  defp split_brace_items(content) do
    split_brace_items(content, 0, [], [])
  end

  defp split_brace_items("", _depth, current, acc) do
    item = current |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([item | acc])
  end

  defp split_brace_items(<<?,, rest::binary>>, 0, current, acc) do
    item = current |> Enum.reverse() |> IO.iodata_to_binary()
    split_brace_items(rest, 0, [], [item | acc])
  end

  defp split_brace_items(<<?\{, rest::binary>>, depth, current, acc) do
    split_brace_items(rest, depth + 1, [?{ | current], acc)
  end

  defp split_brace_items(<<?\}, rest::binary>>, depth, current, acc) when depth > 0 do
    split_brace_items(rest, depth - 1, [?} | current], acc)
  end

  defp split_brace_items(<<c, rest::binary>>, depth, current, acc) do
    split_brace_items(rest, depth, [c | current], acc)
  end

  # Parse a single brace item into word parts
  # This handles nested braces like "b{1,2}" -> [{:literal, "b"}, {:brace_expand, ...}]
  defp parse_brace_item(item) do
    parse_brace_item_parts(item, [])
  end

  defp parse_brace_item_parts("", acc), do: Enum.reverse(acc)

  defp parse_brace_item_parts(<<?\{, rest::binary>>, acc) do
    # Find matching close brace
    case extract_nested_brace(rest, [], 1) do
      {:ok, inner, remaining} ->
        # Recursively parse the nested brace content
        case parse_brace_content(inner, nil) do
          {:ok, brace_spec} ->
            parse_brace_item_parts(remaining, [{:brace_expand, brace_spec} | acc])

          :not_expansion ->
            # Keep as literal
            parse_brace_item_parts(remaining, [{:literal, "{" <> inner <> "}"} | acc])
        end

      :error ->
        # Unmatched brace, treat rest as literal
        [{:literal, "{" <> rest} | acc] |> Enum.reverse()
    end
  end

  defp parse_brace_item_parts(str, acc) do
    # Read literal until we hit a brace or end
    {literal, rest} = take_until_brace(str, [])

    if literal == "" do
      Enum.reverse(acc)
    else
      parse_brace_item_parts(rest, [{:literal, literal} | acc])
    end
  end

  defp take_until_brace("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_until_brace(<<?\{, _::binary>> = rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_until_brace(<<c, rest::binary>>, acc), do: take_until_brace(rest, [c | acc])

  defp extract_nested_brace("", _acc, _depth), do: :error

  defp extract_nested_brace(<<?\}, rest::binary>>, acc, 1) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp extract_nested_brace(<<?\}, rest::binary>>, acc, depth) do
    extract_nested_brace(rest, [?} | acc], depth - 1)
  end

  defp extract_nested_brace(<<?\{, rest::binary>>, acc, depth) do
    extract_nested_brace(rest, [?{ | acc], depth + 1)
  end

  defp extract_nested_brace(<<c, rest::binary>>, acc, depth) do
    extract_nested_brace(rest, [c | acc], depth)
  end

  # Read escape sequence
  defp read_escape(state) do
    # skip backslash
    state = advance(state)

    case peek(state) do
      nil ->
        # Backslash at end of input - literal backslash
        {:ok, {:literal, "\\"}, state}

      ?\n ->
        # Line continuation - skip both backslash and newline
        {:ok, {:literal, ""}, advance(state)}

      c ->
        # Escaped character
        {:ok, {:literal, <<c>>}, advance(state)}
    end
  end

  # Read single-quoted string (no escapes except '')
  defp read_single_quoted(state) do
    start_line = state.line
    start_col = state.column
    # skip opening quote
    state = advance(state)
    read_single_quoted_content(state, [], start_line, start_col)
  end

  defp read_single_quoted_content(state, acc, start_line, start_col) do
    case peek(state) do
      nil ->
        {:error, "unterminated single quote", start_line, start_col}

      ?' ->
        text = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:single_quoted, text}, advance(state)}

      c ->
        read_single_quoted_content(advance(state), [c | acc], start_line, start_col)
    end
  end

  # Read double-quoted string (with variable/command expansion)
  defp read_double_quoted(state) do
    start_line = state.line
    start_col = state.column
    # skip opening quote
    state = advance(state)
    read_double_quoted_content(state, [], start_line, start_col)
  end

  defp read_double_quoted_content(state, acc, start_line, start_col) do
    case peek(state) do
      nil ->
        {:error, "unterminated double quote", start_line, start_col}

      ?" ->
        parts = acc |> Enum.reverse() |> merge_adjacent_literals()
        {:ok, {:double_quoted, parts}, advance(state)}

      ?\\ ->
        {:ok, part, new_state} = read_double_quoted_escape(state)
        read_double_quoted_content(new_state, [part | acc], start_line, start_col)

      ?$ ->
        {:ok, part, new_state} = read_dollar(state)
        read_double_quoted_content(new_state, [part | acc], start_line, start_col)

      ?` ->
        {:ok, part, new_state} = read_backtick(state)
        read_double_quoted_content(new_state, [part | acc], start_line, start_col)

      c ->
        read_double_quoted_content(
          advance(state),
          [{:literal, <<c>>} | acc],
          start_line,
          start_col
        )
    end
  end

  # Escape sequences in double quotes - only certain chars are special
  defp read_double_quoted_escape(state) do
    # skip backslash
    state = advance(state)

    case peek(state) do
      nil ->
        {:ok, {:literal, "\\"}, state}

      c when c in [?$, ?`, ?", ?\\, ?\n] ->
        if c == ?\n do
          # Line continuation
          {:ok, {:literal, ""}, advance(state)}
        else
          {:ok, {:literal, <<c>>}, advance(state)}
        end

      c ->
        # Backslash is literal when followed by non-special char
        {:ok, {:literal, <<?\\, c>>}, advance(state)}
    end
  end

  # Read $... expansion
  defp read_dollar(state) do
    start_line = state.line
    start_col = state.column
    # skip $
    state = advance(state)

    case peek(state) do
      nil ->
        {:ok, {:literal, "$"}, state}

      ?{ ->
        read_braced_variable(state, start_line, start_col)

      ?( ->
        case peek_next(state) do
          ?( ->
            # $(( - arithmetic expansion
            read_arith_expansion(state, start_line, start_col)

          _ ->
            # $( - command substitution
            read_command_subst(state, start_line, start_col)
        end

      c when c in [??, ?$, ?!, ?_, ?#, ?@, ?*, ?-] or c in ?0..?9 or c in ?a..?z or c in ?A..?Z ->
        read_simple_variable(state, start_line, start_col)

      ?' ->
        read_ansi_c_quoted(state, start_line, start_col)

      _ ->
        {:ok, {:literal, "$"}, state}
    end
  end

  # Read simple variable: $VAR, $?, $$, $1, $-, etc.
  defp read_simple_variable(state, start_line, start_col) do
    case peek(state) do
      c when c in [??, ?$, ?!, ?#, ?@, ?*, ?_, ?-] ->
        {:ok, {:variable, <<c>>}, advance(state)}

      c when c in ?0..?9 ->
        # Check for multi-digit positional parameter (SC1037)
        # $10 is interpreted as $1 followed by literal 0
        next_state = advance(state)

        case peek(next_state) do
          next when next in ?0..?9 ->
            # Collect all following digits to show in error message
            {remaining_digits, _} = collect_digits(next_state, [])
            full_num = <<c>> <> remaining_digits

            {:error,
             "(SC1037) $#{full_num} is $#{<<c>>} followed by '#{remaining_digits}' - use ${#{full_num}} for positional parameters > 9",
             start_line, start_col}

          _ ->
            {:ok, {:variable, <<c>>}, next_state}
        end

      c when c in ?a..?z or c in ?A..?Z or c == ?_ ->
        {name, new_state} = read_var_name(state, [])

        # Check for $VAR= pattern (SC1066) and $arr[0] pattern (SC1087)
        case peek(new_state) do
          ?= ->
            {:error,
             "(SC1066) Don't use $ on the left side of assignments - use #{name}=value instead of $#{name}=value",
             start_line, start_col}

          ?[ ->
            {:error,
             "(SC1087) Use braces when accessing array elements. Use ${#{name}[...]} instead of $#{name}[...]",
             start_line, start_col}

          _ ->
            {:ok, {:variable, name}, new_state}
        end

      _ ->
        {:ok, {:literal, "$"}, state}
    end
  end

  # Collect consecutive digits for error messages
  defp collect_digits(state, acc) do
    case peek(state) do
      c when c in ?0..?9 ->
        collect_digits(advance(state), [c | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  defp read_var_name(state, acc) do
    case peek(state) do
      c when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ ->
        read_var_name(advance(state), [c | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  # Read ANSI-C quoted string: $'...'
  # Supports escape sequences like \t, \n, \xNN, \NNN (octal)
  defp read_ansi_c_quoted(state, start_line, start_col) do
    # skip opening '
    state = advance(state)
    read_ansi_c_quoted_content(state, [], start_line, start_col)
  end

  defp read_ansi_c_quoted_content(state, acc, start_line, start_col) do
    case peek(state) do
      nil ->
        {:error, "unterminated $'...' string", start_line, start_col}

      ?' ->
        # End of string - return as single_quoted to prevent word-splitting
        content = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:single_quoted, content}, advance(state)}

      ?\\ ->
        # Escape sequence
        case read_ansi_escape(advance(state)) do
          {:ok, char, new_state} ->
            read_ansi_c_quoted_content(new_state, [char | acc], start_line, start_col)

          {:error, _} = err ->
            err
        end

      c ->
        read_ansi_c_quoted_content(advance(state), [c | acc], start_line, start_col)
    end
  end

  defp read_ansi_escape(state) do
    case peek(state) do
      nil ->
        {:error, "unterminated escape sequence"}

      # bell
      ?a ->
        {:ok, 0x07, advance(state)}

      # backspace
      ?b ->
        {:ok, 0x08, advance(state)}

      # escape
      ?e ->
        {:ok, 0x1B, advance(state)}

      # escape
      ?E ->
        {:ok, 0x1B, advance(state)}

      # form feed
      ?f ->
        {:ok, 0x0C, advance(state)}

      # newline
      ?n ->
        {:ok, 0x0A, advance(state)}

      # carriage return
      ?r ->
        {:ok, 0x0D, advance(state)}

      # tab
      ?t ->
        {:ok, 0x09, advance(state)}

      # vertical tab
      ?v ->
        {:ok, 0x0B, advance(state)}

      # backslash
      ?\\ ->
        {:ok, ?\\, advance(state)}

      # single quote
      ?' ->
        {:ok, ?', advance(state)}

      # double quote
      ?" ->
        {:ok, ?", advance(state)}

      # question mark
      ?? ->
        {:ok, ??, advance(state)}

      ?x ->
        # Hex escape: \xNN
        read_hex_escape(advance(state))

      c when c in ?0..?7 ->
        # Octal escape: \NNN (1-3 digits)
        read_octal_escape(state)

      c ->
        # Unknown escape - just use the character literally
        {:ok, c, advance(state)}
    end
  end

  defp read_hex_escape(state) do
    # Read up to 2 hex digits
    case peek(state) do
      c when c in ?0..?9 or c in ?a..?f or c in ?A..?F ->
        {hex_str, new_state} = read_hex_digits(state, [], 2)
        value = String.to_integer(hex_str, 16)
        {:ok, value, new_state}

      _ ->
        # No hex digits - treat as literal 'x'
        {:ok, ?x, state}
    end
  end

  defp read_hex_digits(state, acc, 0), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}

  defp read_hex_digits(state, acc, remaining) do
    case peek(state) do
      c when c in ?0..?9 or c in ?a..?f or c in ?A..?F ->
        read_hex_digits(advance(state), [c | acc], remaining - 1)

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  defp read_octal_escape(state) do
    # Read up to 3 octal digits
    {octal_str, new_state} = read_octal_digits(state, [], 3)
    value = String.to_integer(octal_str, 8)
    # Clamp to byte range
    value = rem(value, 256)
    {:ok, value, new_state}
  end

  defp read_octal_digits(state, acc, 0),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}

  defp read_octal_digits(state, acc, remaining) do
    case peek(state) do
      c when c in ?0..?7 ->
        read_octal_digits(advance(state), [c | acc], remaining - 1)

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end
  end

  # Read braced variable: ${VAR}, ${VAR:-default}, ${#VAR}, etc.
  defp read_braced_variable(state, start_line, start_col) do
    # skip {
    state = advance(state)

    case read_braced_content(state, start_line, start_col) do
      {:ok, content, new_state} ->
        part = parse_braced_content(content)
        {:ok, part, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  # Read content between { and }, handling nesting
  defp read_braced_content(state, start_line, start_col) do
    read_matched_pair(state, ?{, ?}, start_line, start_col)
  end

  # Generic matched pair reader (handles nesting, quotes, escapes)
  defp read_matched_pair(state, _open, close, start_line, start_col) do
    read_matched_pair_loop(state, close, 0, [], start_line, start_col)
  end

  defp read_matched_pair_loop(state, close, depth, acc, start_line, start_col) do
    case peek(state) do
      nil ->
        {:error, "unterminated #{<<close>>}", start_line, start_col}

      ^close when depth == 0 ->
        content = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, content, advance(state)}

      ^close ->
        read_matched_pair_loop(
          advance(state),
          close,
          depth - 1,
          [close | acc],
          start_line,
          start_col
        )

      c when c == ?{ and close == ?} ->
        read_matched_pair_loop(advance(state), close, depth + 1, [c | acc], start_line, start_col)

      c when c == ?( and close == ?) ->
        read_matched_pair_loop(advance(state), close, depth + 1, [c | acc], start_line, start_col)

      ?\\ ->
        state2 = advance(state)

        case peek(state2) do
          nil ->
            read_matched_pair_loop(state2, close, depth, [?\\ | acc], start_line, start_col)

          c ->
            read_matched_pair_loop(
              advance(state2),
              close,
              depth,
              [c, ?\\ | acc],
              start_line,
              start_col
            )
        end

      ?' ->
        case read_single_quoted_raw(advance(state), [?' | acc]) do
          {:ok, new_acc, new_state} ->
            read_matched_pair_loop(new_state, close, depth, new_acc, start_line, start_col)

          {:error, _, _, _} = err ->
            err
        end

      ?" ->
        case read_double_quoted_raw(advance(state), [?" | acc], start_line, start_col) do
          {:ok, new_acc, new_state} ->
            read_matched_pair_loop(new_state, close, depth, new_acc, start_line, start_col)

          {:error, _, _, _} = err ->
            err
        end

      c ->
        read_matched_pair_loop(advance(state), close, depth, [c | acc], start_line, start_col)
    end
  end

  # Read single-quoted string content for raw capture
  defp read_single_quoted_raw(state, acc) do
    case peek(state) do
      nil -> {:error, "unterminated single quote", state.line, state.column}
      ?' -> {:ok, [?' | acc], advance(state)}
      c -> read_single_quoted_raw(advance(state), [c | acc])
    end
  end

  # Read double-quoted string content for raw capture
  defp read_double_quoted_raw(state, acc, start_line, start_col) do
    case peek(state) do
      nil ->
        {:error, "unterminated double quote", start_line, start_col}

      ?" ->
        {:ok, [?" | acc], advance(state)}

      ?\\ ->
        state2 = advance(state)

        case peek(state2) do
          nil -> {:ok, [?\\ | acc], state2}
          c -> read_double_quoted_raw(advance(state2), [c, ?\\ | acc], start_line, start_col)
        end

      c ->
        read_double_quoted_raw(advance(state), [c | acc], start_line, start_col)
    end
  end

  # Parse braced variable content into a structured part
  defp parse_braced_content(content) do
    cond do
      # ${#VAR} or ${#ARR[@]} - length
      String.starts_with?(content, "#") and not String.contains?(content, ":") ->
        rest = String.slice(content, 1..-1//1)
        # Check for array subscript: VAR[@] or VAR[*] or VAR[idx]
        case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\[([^\]]+)\]$/s, rest) do
          [_, var_name, subscript] ->
            sub =
              case subscript do
                "@" -> :all_values
                "*" -> :all_star
                idx -> {:index, idx}
              end

            {:variable_braced, var_name, [subscript: sub, length: true]}

          nil ->
            {:variable_braced, rest, [length: true]}
        end

      # Check for operators
      true ->
        parse_braced_with_operators(content)
    end
  end

  defp parse_braced_with_operators(content) do
    # Try to find operator patterns
    cond do
      # ${VAR:-default}, ${VAR:=default}, ${VAR:?error}, ${VAR:+alternate}
      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*|[?$!#@*0-9])(:-|:=|:\?|:\+)(.*)$/s, content) ->
        [_, var_name, op, word] = match

        op_atom =
          case op do
            ":-" -> :default
            ":=" -> :assign_default
            ":?" -> :error
            ":+" -> :alternate
          end

        {:variable_braced, var_name, [{op_atom, word}]}

      # ${VAR#pattern}, ${VAR##pattern}, ${VAR%pattern}, ${VAR%%pattern}
      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*|[?$!#@*0-9])(##?|%%?)(.*)$/s, content) ->
        [_, var_name, op, pattern] = match

        {op_type, mode} =
          case op do
            "#" -> {:remove_prefix, :shortest}
            "##" -> {:remove_prefix, :longest}
            "%" -> {:remove_suffix, :shortest}
            "%%" -> {:remove_suffix, :longest}
          end

        {:variable_braced, var_name, [{op_type, pattern, mode}]}

      # ${VAR/pattern/replacement}, ${VAR//pattern/replacement}
      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*|[?$!#@*0-9])(\/\/?)(.*)/s, content) ->
        [_, var_name, op, rest] = match

        {pattern, replacement} =
          case String.split(rest, "/", parts: 2) do
            [p, r] -> {p, r}
            [p] -> {p, ""}
          end

        mode = if op == "//", do: :all, else: :first
        {:variable_braced, var_name, [{:substitute, pattern, replacement, mode}]}

      # ${VAR^}, ${VAR^^}, ${VAR,}, ${VAR,,} - case modification
      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*|[?$!#@*0-9])(\^\^?|,,?)$/s, content) ->
        [_, var_name, op] = match

        mode =
          case op do
            "^" -> :upper_first
            "^^" -> :upper_all
            "," -> :lower_first
            ",," -> :lower_all
          end

        {:variable_braced, var_name, [{:case_modify, mode}]}

      # ${!VAR[@]} or ${!VAR[*]} - list array indices/keys
      match = Regex.run(~r/^!([A-Za-z_][A-Za-z0-9_]*)\[(@|\*)\]$/s, content) ->
        [_, var_name, sub] = match
        sub_type = if sub == "@", do: :all_values, else: :all_star
        {:variable_braced, var_name, [subscript: sub_type, list_keys: true]}

      # ${!VAR} - indirect reference (use VAR's value as variable name)
      match = Regex.run(~r/^!([A-Za-z_][A-Za-z0-9_]*)$/s, content) ->
        [_, var_name] = match
        {:variable_braced, var_name, [indirect: true]}

      # ${VAR[@]:offset} or ${VAR[@]:offset:length} - array slicing
      match =
          Regex.run(
            ~r/^([A-Za-z_][A-Za-z0-9_]*)\[(@|\*)\]:(\(-?\d+\)| ?-?\d+)(?::(\d+))?$/s,
            content
          ) ->
        [_ | captures] = match

        case captures do
          [var_name, sub, offset_str, length_str] when length_str != "" ->
            sub_type = if sub == "@", do: :all_values, else: :all_star

            {:variable_braced, var_name,
             [
               subscript: sub_type,
               slice: {parse_offset(offset_str), String.to_integer(length_str)}
             ]}

          [var_name, sub, offset_str | _] ->
            sub_type = if sub == "@", do: :all_values, else: :all_star

            {:variable_braced, var_name,
             [subscript: sub_type, slice: {parse_offset(offset_str), nil}]}
        end

      # ${VAR:offset} or ${VAR:offset:length}
      # Note: Negative offsets can be written as :(-5) or : -5 (space before negative)
      match =
          Regex.run(
            ~r/^([A-Za-z_][A-Za-z0-9_]*|[?$!#@*0-9]):(\(-?\d+\)| ?-?\d+)(?::(\d+))?$/s,
            content
          ) ->
        case match do
          [_, var_name, offset_str, length_str] when length_str != "" ->
            {:variable_braced, var_name,
             [{:substring, parse_offset(offset_str), String.to_integer(length_str)}]}

          [_, var_name, offset_str] ->
            {:variable_braced, var_name, [{:substring, parse_offset(offset_str), nil}]}

          [_, var_name, offset_str, ""] ->
            {:variable_braced, var_name, [{:substring, parse_offset(offset_str), nil}]}
        end

      # ${VAR[subscript]}
      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\[([^\]]+)\]$/s, content) ->
        [_, var_name, subscript] = match

        sub =
          case subscript do
            "@" -> :all_values
            "*" -> :all_star
            idx -> {:index, idx}
          end

        {:variable_braced, var_name, [subscript: sub]}

      # Simple ${VAR}
      true ->
        {:variable_braced, content, []}
    end
  end

  # Parse offset string for substring expansion
  # Handles: "5", "-5", "(-5)", " -5"
  defp parse_offset(str) do
    str = String.trim(str)

    # Handle parenthesized form: (-5) -> -5
    str =
      case Regex.run(~r/^\((-?\d+)\)$/, str) do
        [_, inner] -> inner
        nil -> str
      end

    String.to_integer(str)
  end

  # Read command substitution: $(...)
  # Recursively tokenizes the content for proper nested structure
  defp read_command_subst(state, start_line, start_col) do
    # skip (
    state = advance(state)

    case tokenize_subshell_content(state, [], 0, start_line, start_col) do
      {:ok, tokens, new_state} ->
        {:ok, {:command_subst, tokens}, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  # Read process substitution content: <(...) or >(...)
  # Called after <( or >( has already been consumed
  # Recursively tokenizes the content for proper nested structure
  defp read_process_subst(state, start_line, start_col) do
    case tokenize_subshell_content(state, [], 0, start_line, start_col) do
      {:ok, tokens, new_state} ->
        {:ok, tokens, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  # Recursively tokenize content inside $(...) or <(...) or >(...)
  # Tracks parenthesis depth to find the matching closing )
  # Handles heredocs correctly by consuming them after newlines
  defp tokenize_subshell_content(state, acc, paren_depth, start_line, start_col) do
    case read_token(state) do
      {:ok, {:rparen, _line, _col}, new_state} ->
        if paren_depth == 0 do
          # Found the closing ), we're done
          # Don't include the ) in the tokens - it's the delimiter
          {:ok, Enum.reverse(acc), new_state}
        else
          # Nested ), continue with decreased depth
          tokenize_subshell_content(
            new_state,
            [{:rparen, state.line, state.column} | acc],
            paren_depth - 1,
            start_line,
            start_col
          )
        end

      {:ok, {:lparen, line, col}, new_state} ->
        # Nested (, increase depth
        tokenize_subshell_content(
          new_state,
          [{:lparen, line, col} | acc],
          paren_depth + 1,
          start_line,
          start_col
        )

      {:ok, {:eof, _, _}, _state} ->
        # EOF before finding closing )
        {:error, "(SC1081) Unclosed command substitution - missing )", start_line, start_col}

      {:ok, {:newline, _line, _col} = token, new_state} ->
        # After newline, consume any pending heredocs
        case consume_pending_heredocs(new_state) do
          {:ok, heredoc_tokens, newer_state} ->
            tokenize_subshell_content(
              newer_state,
              heredoc_tokens ++ [token | acc],
              paren_depth,
              start_line,
              start_col
            )

          {:error, _, _, _} = err ->
            err
        end

      {:ok, token, new_state} ->
        # Regular token - track heredocs if this is a heredoc delimiter
        new_state = maybe_track_heredoc(token, acc, new_state)

        tokenize_subshell_content(
          new_state,
          [token | acc],
          paren_depth,
          start_line,
          start_col
        )

      {:error, _, _, _} = err ->
        err
    end
  end

  # Read arithmetic expansion: $((...))
  defp read_arith_expansion(state, start_line, start_col) do
    # skip ((
    state = advance(state, 2)
    read_arith_content(state, 0, [], start_line, start_col)
  end

  defp read_arith_content(state, depth, acc, start_line, start_col) do
    case {peek(state), peek_next(state)} do
      {nil, _} ->
        {:error, "unterminated arithmetic expansion", start_line, start_col}

      {?), ?)} when depth == 0 ->
        content = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:arith_expand, content}, advance(state, 2)}

      {?(, _} ->
        read_arith_content(advance(state), depth + 1, [?( | acc], start_line, start_col)

      {?), _} when depth > 0 ->
        read_arith_content(advance(state), depth - 1, [?) | acc], start_line, start_col)

      {c, _} ->
        read_arith_content(advance(state), depth, [c | acc], start_line, start_col)
    end
  end

  # Read backtick command substitution: `...`
  defp read_backtick(state) do
    start_line = state.line
    start_col = state.column
    # skip `
    state = advance(state)
    read_backtick_content(state, [], start_line, start_col)
  end

  defp read_backtick_content(state, acc, start_line, start_col) do
    case peek(state) do
      nil ->
        {:error, "unterminated backtick", start_line, start_col}

      ?` ->
        content = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:backtick, content}, advance(state)}

      ?\\ ->
        state2 = advance(state)

        case peek(state2) do
          c when c in [?$, ?`, ?\\] ->
            read_backtick_content(advance(state2), [c | acc], start_line, start_col)

          _ ->
            read_backtick_content(state2, [?\\ | acc], start_line, start_col)
        end

      c ->
        read_backtick_content(advance(state), [c | acc], start_line, start_col)
    end
  end

  # Merge adjacent literal parts
  defp merge_adjacent_literals(parts) do
    parts
    |> Enum.reduce([], fn
      {:literal, text}, [{:literal, prev} | rest] ->
        [{:literal, prev <> text} | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
  end

  # Build word token, detecting assignments
  defp build_word_token(parts, line, col) do
    # Merge adjacent literals first, then check for assignment pattern
    merged_parts = merge_adjacent_literals(parts)

    # SC1109: Check for HTML entities in any literal part
    case check_html_entities(merged_parts, line, col) do
      {:error, _, _, _} = err ->
        err

      :ok ->
        case merged_parts do
          [{:literal, text} | rest] ->
            # SC1097: Check for VAR==value (likely meant VAR=value or comparison)
            case check_double_equals_assignment(text) do
              {:error, var_name} ->
                {:error,
                 "(SC1097) Unexpected `==` in assignment. Use `#{var_name}=value` for assignment, or `[ \"$#{var_name}\" = value ]` for comparison",
                 line, col}

              :ok ->
                build_word_token_assignment(merged_parts, rest, text, line, col)
            end

          _ ->
            {:word, merged_parts, line, col}
        end
    end
  end

  # SC1109: Check for HTML entities that indicate copy-paste from web
  @html_entities %{
    "&amp;" => "&",
    "&lt;" => "<",
    "&gt;" => ">",
    "&nbsp;" => "space",
    "&quot;" => "\"",
    "&#39;" => "'"
  }

  defp check_html_entities(parts, line, col) do
    # Extract all literal text from parts
    literals =
      parts
      |> Enum.filter(fn
        {:literal, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:literal, text} -> text end)
      |> Enum.join()

    # Check for any HTML entity
    found =
      Enum.find(@html_entities, fn {entity, _replacement} ->
        String.contains?(literals, entity)
      end)

    case found do
      {entity, replacement} ->
        {:error,
         "(SC1109) Unquoted HTML entity `#{entity}` found. Did you copy code from a webpage? Replace with `#{replacement}`.",
         line, col}

      nil ->
        :ok
    end
  end

  # SC1097: Check for VAR==value pattern using simple string operations
  defp check_double_equals_assignment(text) do
    case String.split(text, "==", parts: 2) do
      [var_name, _value] when byte_size(var_name) > 0 ->
        if valid_var_name?(var_name) do
          {:error, var_name}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp valid_var_name?(name) do
    case String.to_charlist(name) do
      [first | rest] when first in ?A..?Z or first in ?a..?z or first == ?_ ->
        Enum.all?(rest, fn c -> c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_ end)

      _ ->
        false
    end
  end

  # Extracted assignment detection logic
  defp build_word_token_assignment(merged_parts, rest, text, line, col) do
    # Try append assignment first: VAR+=value
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\+=(.*)$/s, text) do
      [_, var_name, value_start] ->
        value_parts =
          if value_start == "" do
            rest
          else
            [{:literal, value_start} | rest]
          end

        {:append_word, var_name, merge_adjacent_literals(value_parts), line, col}

      nil ->
        # Try simple assignment: VAR=value
        case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s, text) do
          [_, var_name, value_start] ->
            value_parts =
              if value_start == "" do
                rest
              else
                [{:literal, value_start} | rest]
              end

            {:assignment_word, var_name, merge_adjacent_literals(value_parts), line, col}

          nil ->
            # Try array subscript assignment: VAR[index]=value
            case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*\[[^\]]*\])=(.*)$/s, text) do
              [_, var_with_subscript, value_start] ->
                value_parts =
                  if value_start == "" do
                    rest
                  else
                    [{:literal, value_start} | rest]
                  end

                {:assignment_word, var_with_subscript, merge_adjacent_literals(value_parts), line,
                 col}

              nil ->
                {:word, merged_parts, line, col}
            end
        end
    end
  end

  # SC1069: Check if a word looks like a reserved word immediately followed by [
  # e.g., "if[" or "while[" - these should have a space before [
  # SC1129: Check for keyword immediately followed by ! (e.g., "if!" or "while!")
  defp check_keyword_bracket_collision({:word, [{:literal, text}], line, col}) do
    # Check for patterns like "if[", "while[", "for[", etc.
    bracket_error =
      Enum.find_value(@reserved_words, nil, fn keyword ->
        if String.starts_with?(text, keyword <> "[") do
          {:error,
           "(SC1069) Missing space between `#{keyword}` and `[`. Use `#{keyword} [` instead of `#{keyword}[`",
           line, col}
        end
      end)

    # Check for patterns like "if!", "while!", "until!" (SC1129)
    bang_error =
      Enum.find_value(~w(if while until), nil, fn keyword ->
        if String.starts_with?(text, keyword <> "!") do
          {:error,
           "(SC1129) Missing space before `!`. Use `#{keyword} !` instead of `#{keyword}!`", line,
           col}
        end
      end)

    # Check for patterns like "if:", "while:", "until:" (SC1130)
    colon_error =
      Enum.find_value(~w(if while until), nil, fn keyword ->
        if String.starts_with?(text, keyword <> ":") do
          {:error,
           "(SC1130) Missing space before `:`. Use `#{keyword} :` instead of `#{keyword}:`", line,
           col}
        end
      end)

    bracket_error || bang_error || colon_error || :ok
  end

  defp check_keyword_bracket_collision(_token), do: :ok

  # Convert word to reserved word if applicable
  defp maybe_reserved_word({:word, [{:literal, text}], line, col}) when text in @reserved_words do
    {String.to_atom(text), line, col}
  end

  defp maybe_reserved_word(token), do: token
end
