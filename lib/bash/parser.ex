defmodule Bash.Parser do
  @moduledoc """
  Recursive descent parser for Bash scripts.

  Converts tokens from the Tokenizer into AST nodes.

  ## Grammar Overview

  The parser follows Bash's grammar from parse.y:

  ```
  script       → statement_list EOF
  statement    → simple_command
               | compound_command
               | pipeline
               | control_flow
  pipeline     → command ('|' command)*
  command      → simple_command redirect*
  simple_cmd   → assignment* name word* redirect*
  compound_cmd → '{' list '}'
               | '(' list ')'
               | if_clause
               | for_clause
               | while_clause
               | case_clause
               | function_def
  ```
  """

  alias Bash.Tokenizer
  alias Bash.AST
  alias Bash.Script
  alias Bash.Function

  @type token :: Tokenizer.token()
  @type state :: %{tokens: [token()], pos: non_neg_integer()}

  # Reserved words that start compound commands (for reference, not currently used)
  # compound_starters: [:if, :for, :while, :until, :case, :select, :"{", :"(", :"((", :"[["]

  # Reserved words that are control operators (for reference, not currently used)
  # control_operators: [:and_if, :or_if, :pipe, :background, :semi, :newline]

  @doc """
  Parse a Bash script string into an AST.
  """
  @spec parse(String.t()) ::
          {:ok, Script.t()} | {:error, String.t(), pos_integer(), pos_integer()}
  def parse(input) when is_binary(input) do
    case Tokenizer.tokenize(input) do
      {:ok, tokens} ->
        parse_tokens(tokens)

      {:error, reason, line, col} ->
        {:error, reason, line, col}
    end
  end

  # Resolve a heredoc in accumulated statements using tokenizer-provided content
  # Statements are in reverse order (most recent first)
  defp resolve_heredoc_in_statements(acc, content, delimiter) do
    # Find and resolve the first pending heredoc matching this delimiter
    resolve_heredoc_in_list(acc, content, delimiter, [])
  end

  defp resolve_heredoc_in_list([], _content, _delimiter, resolved) do
    # No matching heredoc found - return unchanged
    Enum.reverse(resolved)
  end

  defp resolve_heredoc_in_list([stmt | rest], content, delimiter, resolved) do
    case resolve_heredoc_in_stmt(stmt, content, delimiter) do
      {:resolved, new_stmt} ->
        # Found and resolved - reconstruct list
        Enum.reverse(resolved) ++ [new_stmt | rest]

      :not_found ->
        resolve_heredoc_in_list(rest, content, delimiter, [stmt | resolved])
    end
  end

  defp resolve_heredoc_in_stmt(%AST.Command{redirects: redirects} = cmd, content, delimiter) do
    case resolve_heredoc_in_redirects(redirects, content, delimiter) do
      {:resolved, new_redirects} -> {:resolved, %{cmd | redirects: new_redirects}}
      :not_found -> :not_found
    end
  end

  defp resolve_heredoc_in_stmt(%AST.Pipeline{commands: commands} = pipeline, content, delimiter) do
    case resolve_heredoc_in_commands(commands, content, delimiter, []) do
      {:resolved, new_commands} -> {:resolved, %{pipeline | commands: new_commands}}
      :not_found -> :not_found
    end
  end

  defp resolve_heredoc_in_stmt(
         %AST.WhileLoop{redirects: redirects} = while_loop,
         content,
         delimiter
       ) do
    case resolve_heredoc_in_redirects(redirects, content, delimiter) do
      {:resolved, new_redirects} -> {:resolved, %{while_loop | redirects: new_redirects}}
      :not_found -> :not_found
    end
  end

  defp resolve_heredoc_in_stmt(_stmt, _content, _delimiter), do: :not_found

  defp resolve_heredoc_in_commands([], _content, _delimiter, _resolved), do: :not_found

  defp resolve_heredoc_in_commands([cmd | rest], content, delimiter, resolved) do
    case resolve_heredoc_in_stmt(cmd, content, delimiter) do
      {:resolved, new_cmd} ->
        {:resolved, Enum.reverse(resolved) ++ [new_cmd | rest]}

      :not_found ->
        resolve_heredoc_in_commands(rest, content, delimiter, [cmd | resolved])
    end
  end

  defp resolve_heredoc_in_redirects(redirects, content, delimiter) do
    resolve_heredoc_in_redirect_list(redirects, content, delimiter, [])
  end

  defp resolve_heredoc_in_redirect_list([], _content, _delimiter, _resolved), do: :not_found

  defp resolve_heredoc_in_redirect_list([redirect | rest], content, delimiter, resolved) do
    case redirect do
      %AST.Redirect{target: {:heredoc_pending, ^delimiter, strip_tabs, expand}} ->
        # Found matching pending heredoc - resolve it
        content_word =
          if expand do
            parse_heredoc_content(content)
          else
            %AST.Word{parts: [{:literal, content}]}
          end

        new_redirect = %{redirect | target: {:heredoc, content_word, delimiter, strip_tabs}}
        {:resolved, Enum.reverse(resolved) ++ [new_redirect | rest]}

      _ ->
        resolve_heredoc_in_redirect_list(rest, content, delimiter, [redirect | resolved])
    end
  end

  # Parse heredoc content for variable expansion
  # This keeps the content as-is except for $VAR and ${VAR} expansions
  defp parse_heredoc_content(content) when content == "" do
    %AST.Word{parts: []}
  end

  defp parse_heredoc_content(content) do
    # Parse the content to find $VAR and ${VAR} patterns
    parts = parse_heredoc_parts(content, [])
    %AST.Word{parts: parts}
  end

  # Parse heredoc content to extract variable references
  defp parse_heredoc_parts("", acc) do
    Enum.reverse(acc)
  end

  defp parse_heredoc_parts("$" <> rest, acc) do
    case parse_variable_in_heredoc(rest) do
      {:ok, var, remaining} ->
        parse_heredoc_parts(remaining, [var | acc])

      :error ->
        # Literal $
        case acc do
          [{:literal, s} | tail] -> parse_heredoc_parts(rest, [{:literal, s <> "$"} | tail])
          _ -> parse_heredoc_parts(rest, [{:literal, "$"} | acc])
        end
    end
  end

  defp parse_heredoc_parts(<<c::utf8, rest::binary>>, acc) do
    case acc do
      [{:literal, s} | tail] -> parse_heredoc_parts(rest, [{:literal, s <> <<c::utf8>>} | tail])
      _ -> parse_heredoc_parts(rest, [{:literal, <<c::utf8>>} | acc])
    end
  end

  # Parse a variable reference in heredoc content
  defp parse_variable_in_heredoc("{" <> rest) do
    # Braced variable: ${VAR}
    case String.split(rest, "}", parts: 2) do
      [var_content, remaining] ->
        var = %AST.Variable{name: var_content}
        {:ok, {:variable, var}, remaining}

      _ ->
        :error
    end
  end

  defp parse_variable_in_heredoc("(" <> rest) do
    # Command substitution: $(...)
    case find_matching_paren(rest, 1, []) do
      {:ok, cmd_content, remaining} ->
        {:ok, {:cmd_subst, cmd_content}, remaining}

      :error ->
        :error
    end
  end

  defp parse_variable_in_heredoc(rest) do
    # Simple variable: $VAR
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)(.*)$/s, rest) do
      [_, name, remaining] ->
        var = %AST.Variable{name: name}
        {:ok, {:variable, var}, remaining}

      _ ->
        :error
    end
  end

  # Find matching closing paren, handling nesting
  defp find_matching_paren("", _depth, _acc), do: :error

  defp find_matching_paren(")" <> rest, 1, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp find_matching_paren(")" <> rest, depth, acc) do
    find_matching_paren(rest, depth - 1, [?) | acc])
  end

  defp find_matching_paren("(" <> rest, depth, acc) do
    find_matching_paren(rest, depth + 1, [?( | acc])
  end

  defp find_matching_paren(<<c::utf8, rest::binary>>, depth, acc) do
    find_matching_paren(rest, depth, [c | acc])
  end

  @doc """
  Parse a list of tokens into an AST.
  """
  @spec parse_tokens([token()]) ::
          {:ok, Script.t()} | {:error, String.t(), pos_integer(), pos_integer()}
  def parse_tokens(tokens) when is_list(tokens) do
    state = %{tokens: tokens, pos: 0}

    case parse_script(state) do
      {:ok, script, new_state} ->
        # Check for unconsumed tokens (orphan keywords at top level)
        case current_token(new_state) do
          {:eof, _, _} ->
            {:ok, script}

          # Reserved words that shouldn't appear at top level outside their context
          {:then, line, col} ->
            {:error, "'then' outside of if/elif block", line, col}

          {:else, line, col} ->
            {:error, "'else' outside of if block", line, col}

          {:elif, line, col} ->
            {:error, "'elif' outside of if block", line, col}

          {:fi, line, col} ->
            {:error, "'fi' without matching 'if'", line, col}

          {:do, line, col} ->
            {:error, "'do' outside of loop context", line, col}

          {:done, line, col} ->
            {:error, "'done' without matching loop", line, col}

          {:esac, line, col} ->
            {:error, "'esac' without matching 'case'", line, col}

          {:rbrace, line, col} ->
            {:error, "unexpected '}' - no matching '{'", line, col}

          {:in, line, col} ->
            {:error, "'in' outside of case/for statement", line, col}

          other ->
            {line, col} = token_position(other)
            {:error, "unexpected token: #{inspect(other)}", line, col}
        end

      {:error, reason, line, col} ->
        {:error, reason, line, col}
    end
  end

  defp parse_script(state) do
    {line, col} = current_position(state)

    # Check for shebang at the start
    {shebang, state} =
      case current_token(state) do
        {:shebang, interpreter, _, _} ->
          # Skip the shebang token and any following newline
          state = advance(state)

          state =
            case current_token(state) do
              {:newline, _, _} -> advance(state)
              _ -> state
            end

          {interpreter, state}

        _ ->
          {nil, state}
      end

    case parse_statement_list(state, []) do
      {:ok, statements, new_state} ->
        script = %Script{
          meta: AST.meta(line, col),
          shebang: shebang,
          statements: statements
        }

        {:ok, script, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  defp parse_statement_list(state, acc) do
    # Skip any leading newlines/semicolons/comments
    {_seps, state} = collect_separators(state, [])

    case current_token(state) do
      {:eof, _, _} ->
        {:ok, Enum.reverse(acc), state}

      # Stop at closing tokens for compound commands
      {:rbrace, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:rparen, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:fi, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:done, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:esac, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:elif, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:else, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:then, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:do, _, _} ->
        {:ok, Enum.reverse(acc), state}

      # Heredoc content - resolve pending heredocs in accumulated statements
      {:heredoc_content, content, delimiter, _strip_tabs} ->
        resolved_acc = resolve_heredoc_in_statements(acc, content, delimiter)
        parse_statement_list(advance(state), resolved_acc)

      # Case clause terminators
      {:dsemi, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:dsemi_and, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:semi_and, _, _} ->
        {:ok, Enum.reverse(acc), state}

      # Handle standalone comment
      {:comment, text, line, col} ->
        comment = %AST.Comment{
          meta: AST.meta(line, col),
          text: text
        }

        state = advance(state)
        {seps, state} = collect_separators(state, [])

        # Add separator after comment if there's a following statement
        new_acc =
          case {seps, peek_for_statement(state)} do
            {[], _} ->
              [comment | acc]

            {_, false} ->
              [comment | acc]

            {_, true} ->
              # Join all separators to preserve blank lines
              sep = Enum.join(seps, "")
              [{:separator, sep}, comment | acc]
          end

        parse_statement_list(state, new_acc)

      _ ->
        case parse_complete_statement(state) do
          {:ok, statement, new_state} ->
            # Collect separators after statement
            {seps, new_state} = collect_separators(new_state, [])

            # Check if there are more statements after the separator
            # Only add separator if there's a following statement
            new_acc =
              case {seps, peek_for_statement(new_state)} do
                {[], _} ->
                  [statement | acc]

                {_, false} ->
                  # No following statement - don't add trailing separator
                  [statement | acc]

                {_, true} ->
                  # Has following statement - add separator between them
                  # Join all separators to preserve blank lines
                  sep = Enum.join(seps, "")
                  [{:separator, sep}, statement | acc]
              end

            parse_statement_list(new_state, new_acc)

          {:error, _, _, _} = err ->
            err
        end
    end
  end

  # Check if there's a potential statement following (not EOF or closing token)
  defp peek_for_statement(state) do
    case current_token(state) do
      {:eof, _, _} -> false
      {:rbrace, _, _} -> false
      {:rparen, _, _} -> false
      {:fi, _, _} -> false
      {:done, _, _} -> false
      {:esac, _, _} -> false
      {:elif, _, _} -> false
      {:else, _, _} -> false
      {:then, _, _} -> false
      {:do, _, _} -> false
      {:dsemi, _, _} -> false
      {:dsemi_and, _, _} -> false
      {:semi_and, _, _} -> false
      _ -> true
    end
  end

  # Collect separators and return them along with new state
  defp collect_separators(state, acc) do
    case current_token(state) do
      {:semi, _, _} ->
        collect_separators(advance(state), [";" | acc])

      {:newline, _, _} ->
        collect_separators(advance(state), ["\n" | acc])

      _ ->
        {Enum.reverse(acc), state}
    end
  end

  # Parse a complete statement (pipeline with possible && or ||)
  defp parse_complete_statement(state) do
    case parse_pipeline(state) do
      {:ok, left, new_state} ->
        parse_logical_continuation(left, new_state)

      {:error, _, _, _} = err ->
        err
    end
  end

  # Parse && and || operators
  defp parse_logical_continuation(left, state) do
    case current_token(state) do
      {:and_if, line, col} ->
        state = advance(state)
        state = skip_newlines(state)

        case parse_pipeline(state) do
          {:ok, right, new_state} ->
            compound = merge_compound_operand(left, :and, right, line, col)
            parse_logical_continuation(compound, new_state)

          {:error, _, _, _} = err ->
            err
        end

      {:or_if, line, col} ->
        state = advance(state)
        state = skip_newlines(state)

        case parse_pipeline(state) do
          {:ok, right, new_state} ->
            compound = merge_compound_operand(left, :or, right, line, col)
            parse_logical_continuation(compound, new_state)

          {:error, _, _, _} = err ->
            err
        end

      {:background, line, col} ->
        # Background operator & - append to compound with :bg operator
        state = advance(state)
        compound = merge_compound_operand(left, :bg, nil, line, col)
        # Check if there's more after the &
        case current_token(state) do
          {:eof, _, _} ->
            {:ok, compound, state}

          {:newline, _, _} ->
            {:ok, compound, state}

          {:semi, _, _} ->
            {:ok, compound, state}

          {:rparen, _, _} ->
            {:ok, compound, state}

          {:rbrace, _, _} ->
            {:ok, compound, state}

          _ ->
            # More statements follow - but they're separate statements, not continuation
            {:ok, compound, state}
        end

      _ ->
        {:ok, left, state}
    end
  end

  # Helper to merge operand compounds correctly
  # Compound operands store statements with operator tuples: [stmt1, {:operator, :and}, stmt2]
  # When right is nil (trailing & for background), just add the operator
  defp merge_compound_operand(
         %AST.Compound{kind: :operand, statements: stmts},
         op,
         nil,
         _line,
         _col
       ) do
    # Trailing operator (like &) - no right side
    %AST.Compound{
      meta: AST.meta(1, 1),
      kind: :operand,
      statements: stmts ++ [{:operator, op}]
    }
  end

  defp merge_compound_operand(
         %AST.Compound{kind: :operand, statements: stmts},
         op,
         right,
         _line,
         _col
       ) do
    %AST.Compound{
      meta: AST.meta(1, 1),
      kind: :operand,
      statements: stmts ++ [{:operator, op}, right]
    }
  end

  defp merge_compound_operand(left, op, nil, line, col) do
    # Trailing operator (like &) - no right side
    %AST.Compound{
      meta: AST.meta(line, col),
      kind: :operand,
      statements: [left, {:operator, op}]
    }
  end

  defp merge_compound_operand(left, op, right, line, col) do
    # Create new operand compound
    %AST.Compound{
      meta: AST.meta(line, col),
      kind: :operand,
      statements: [left, {:operator, op}, right]
    }
  end

  defp parse_pipeline(state) do
    {negate, state} =
      case current_token(state) do
        {:bang, _, _} -> {true, advance(state)}
        _ -> {false, state}
      end

    case parse_command(state) do
      {:ok, first_cmd, new_state} ->
        parse_pipeline_continuation(first_cmd, new_state, [first_cmd], negate)

      {:error, _, _, _} = err ->
        err
    end
  end

  defp parse_pipeline_continuation(first_cmd, state, commands, negate) do
    case current_token(state) do
      {:pipe, _line, _col} ->
        state = advance(state)
        state = skip_newlines(state)

        case parse_command(state) do
          {:ok, cmd, new_state} ->
            parse_pipeline_continuation(first_cmd, new_state, [cmd | commands], negate)

          {:error, _, _, _} = err ->
            err
        end

      _ ->
        if length(commands) == 1 and not negate do
          # Single command without negation - return as-is
          {:ok, first_cmd, state}
        else
          # Either a pipeline or a negated command - wrap in Pipeline
          {line, col} = get_meta_position(first_cmd)

          pipeline = %AST.Pipeline{
            meta: AST.meta(line, col),
            commands: Enum.reverse(commands),
            negate: negate
          }

          {:ok, pipeline, state}
        end
    end
  end

  defp parse_command(state) do
    case current_token(state) do
      # Compound command starters
      {:if, _, _} -> parse_if(state)
      {:for, _, _} -> parse_for(state)
      {:while, _, _} -> parse_while(state)
      {:until, _, _} -> parse_until(state)
      {:case, _, _} -> parse_case(state)
      {:lbrace, _, _} -> parse_brace_group(state)
      {:lparen, _, _} -> parse_subshell(state)
      {:dlparen, _, _} -> parse_arithmetic_command(state)
      {:arith_command, _, _, _} -> parse_arithmetic_command(state)
      {:dlbracket, _, _} -> parse_test_command(state)
      {:lbracket, _, _} -> parse_test_bracket_command(state)
      {:function, _, _} -> parse_function(state)
      # Simple command (including assignments)
      _ -> parse_simple_command(state)
    end
  end

  defp parse_simple_command(state) do
    {line, col} = current_position(state)

    # Collect prefix assignments
    {assignments, state} = collect_assignments(state, [])

    # Parse command name (if any)
    case current_token(state) do
      {:word, [{:literal, name_str}], _, _} ->
        state = advance(state)

        # Check for function definition: name() { ... }
        case current_token(state) do
          {:lparen, _, _} ->
            state = advance(state)

            case current_token(state) do
              {:rparen, _, _} ->
                state = advance(state)
                state = skip_newlines(state)
                # This is a function definition
                case parse_function_body(state) do
                  {:ok, body, new_state} ->
                    func = %Function{
                      meta: AST.meta(line, col),
                      name: name_str,
                      body: body
                    }

                    {:ok, func, new_state}

                  {:error, _, _, _} = err ->
                    err
                end

              _ ->
                # lparen without rparen - treat as subshell or error
                # Back up and parse as normal command
                name = build_word([{:literal, name_str}], line, col)
                # Need to handle the lparen case - for now treat as args
                {args, redirects, state2} = parse_command_args(state, [], [])

                cmd = %AST.Command{
                  meta: AST.meta(line, col),
                  name: name,
                  args: args,
                  redirects: redirects,
                  env_assignments: assignments
                }

                {:ok, cmd, state2}
            end

          _ ->
            # Normal command
            name = build_word([{:literal, name_str}], line, col)
            {args, redirects, state} = parse_command_args(state, [], [])

            cmd = %AST.Command{
              meta: AST.meta(line, col),
              name: name,
              args: args,
              redirects: redirects,
              env_assignments: assignments
            }

            {:ok, cmd, state}
        end

      {:word, parts, _, _} ->
        name = build_word(parts, line, col)
        state = advance(state)

        # Parse arguments and redirects
        {args, redirects, state} = parse_command_args(state, [], [])

        cmd = %AST.Command{
          meta: AST.meta(line, col),
          name: name,
          args: args,
          redirects: redirects,
          env_assignments: assignments
        }

        {:ok, cmd, state}

      # Just assignments, no command
      _ when assignments != [] ->
        # Return assignments as standalone
        [first | rest] = Enum.reverse(assignments)

        if rest == [] do
          assignment = build_assignment_ast(first, line, col)
          {:ok, assignment, state}
        else
          # Multiple assignments - wrap in compound
          stmts =
            Enum.map(Enum.reverse(assignments), fn assign ->
              build_assignment_ast(assign, line, col)
            end)

          compound = %AST.Compound{
            meta: AST.meta(line, col),
            kind: :sequential,
            statements: stmts
          }

          {:ok, compound, state}
        end

      token ->
        {tline, tcol} = token_position(token)
        {:error, "unexpected token: #{inspect(token)}", tline, tcol}
    end
  end

  defp collect_assignments(state, acc) do
    case current_token(state) do
      {:assignment_word, var_name, value_parts, line, col} ->
        state = advance(state)
        # Check if this is an indexed array assignment (VAR[idx]=value)
        case parse_indexed_var_name(var_name) do
          {:indexed, base_name, subscript} ->
            # Indexed array assignment: arr[0]=value
            value = build_word(value_parts, line, col)
            indexed_assign = {:indexed_array_assignment, base_name, subscript, value, line, col}
            collect_assignments(state, [indexed_assign | acc])

          :not_indexed ->
            # Check if this is an array literal (VAR=(...))
            case {value_parts, current_token(state)} do
              {[], {:lparen, _, _}} ->
                # Array literal assignment - parse the elements
                case parse_array_elements(advance(state), []) do
                  {:ok, elements, new_state} ->
                    array_assign = {:array_assignment, var_name, elements, line, col}
                    collect_assignments(new_state, [array_assign | acc])

                  {:error, _, _, _} = err ->
                    err
                end

              _ ->
                # Regular scalar assignment
                value = build_word(value_parts, line, col)
                collect_assignments(state, [{var_name, value} | acc])
            end
        end

      # Array append: VAR+=(...)
      {:append_word, var_name, value_parts, line, col} ->
        state = advance(state)
        # Check if this is an array append (VAR+=(...))
        case {value_parts, current_token(state)} do
          {[], {:lparen, _, _}} ->
            # Array append - parse the elements
            case parse_array_elements(advance(state), []) do
              {:ok, elements, new_state} ->
                array_append = {:array_append, var_name, elements, line, col}
                collect_assignments(new_state, [array_append | acc])

              {:error, _, _, _} = err ->
                err
            end

          _ ->
            # Scalar append: VAR+=value (string concatenation)
            value = build_word(value_parts, line, col)
            collect_assignments(state, [{:scalar_append, var_name, value, line, col} | acc])
        end

      _ ->
        {Enum.reverse(acc), state}
    end
  end

  # Parse variable name to detect array subscript: arr[0] -> {:indexed, "arr", {:index, "0"}}
  defp parse_indexed_var_name(var_name) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\[([^\]]*)\]$/, var_name) do
      [_, base_name, subscript_expr] ->
        subscript =
          case subscript_expr do
            "@" -> :all_values
            "*" -> :all_star
            expr -> {:index, strip_quotes(expr)}
          end

        {:indexed, base_name, subscript}

      nil ->
        :not_indexed
    end
  end

  # Strip surrounding quotes from a string (for associative array keys)
  defp strip_quotes(str) do
    cond do
      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        String.slice(str, 1..-2//1)

      String.starts_with?(str, "'") and String.ends_with?(str, "'") ->
        String.slice(str, 1..-2//1)

      true ->
        str
    end
  end

  defp parse_array_elements(state, acc) do
    case current_token(state) do
      {:rparen, _, _} ->
        {:ok, Enum.reverse(acc), advance(state)}

      # Skip newlines inside array literals
      {:newline, _, _} ->
        parse_array_elements(advance(state), acc)

      # Associative array element: [key]=value
      {:lbracket, _, _} ->
        case parse_assoc_array_element(advance(state)) do
          {:ok, key_word, value_word, new_state} ->
            parse_array_elements(new_state, [{key_word, value_word} | acc])

          {:error, _, _, _} = err ->
            err
        end

      {:word, parts, line, col} ->
        word = build_word(parts, line, col)
        parse_array_elements(advance(state), [word | acc])

      {:eof, line, col} ->
        {:error, "unterminated array assignment", line, col}

      token ->
        {tline, tcol} = token_position(token)
        {:error, "unexpected token in array: #{inspect(token)}", tline, tcol}
    end
  end

  # Parse associative array element: [key]=value (after the opening bracket)
  defp parse_assoc_array_element(state) do
    # Expect the key (usually a word)
    case current_token(state) do
      {:word, key_parts, key_line, key_col} ->
        key_word = build_word(key_parts, key_line, key_col)
        state = advance(state)

        # Expect closing bracket
        case current_token(state) do
          {:rbracket, _, _} ->
            state = advance(state)

            # Expect =value (as a word starting with =)
            case current_token(state) do
              {:word, value_parts, value_line, value_col} ->
                # The value word starts with "=" literal, strip it
                stripped_parts = strip_leading_equals(value_parts)
                value_word = build_word(stripped_parts, value_line, value_col)
                {:ok, key_word, value_word, advance(state)}

              token ->
                {tline, tcol} = token_position(token)
                {:error, "expected value after [key]=", tline, tcol}
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected ] in associative array element", tline, tcol}
        end

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected key in associative array element", tline, tcol}
    end
  end

  # Strip leading "=" literal from word parts
  defp strip_leading_equals([{:literal, "=" <> rest} | tail]) when rest != "" do
    [{:literal, rest} | tail]
  end

  defp strip_leading_equals([{:literal, "="} | tail]) do
    tail
  end

  defp strip_leading_equals(parts), do: parts

  # Build assignment AST from tuple
  defp build_assignment_ast({:array_assignment, var_name, elements, _aline, _acol}, line, col) do
    %AST.ArrayAssignment{
      meta: AST.meta(line, col),
      name: var_name,
      elements: elements
    }
  end

  defp build_assignment_ast(
         {:indexed_array_assignment, base_name, subscript, value, _aline, _acol},
         line,
         col
       ) do
    %AST.ArrayAssignment{
      meta: AST.meta(line, col),
      name: base_name,
      subscript: subscript,
      elements: [value]
    }
  end

  # Array append: VAR+=(...)
  defp build_assignment_ast({:array_append, var_name, elements, _aline, _acol}, line, col) do
    %AST.ArrayAssignment{
      meta: AST.meta(line, col),
      name: var_name,
      elements: elements,
      append: true
    }
  end

  # Scalar append: VAR+=value (string concatenation)
  defp build_assignment_ast({:scalar_append, var_name, value, _aline, _acol}, line, col) do
    %AST.Assignment{
      meta: AST.meta(line, col),
      name: var_name,
      value: value,
      append: true
    }
  end

  defp build_assignment_ast({var_name, value}, line, col) do
    %AST.Assignment{
      meta: AST.meta(line, col),
      name: var_name,
      value: value
    }
  end

  # Reserved words that should be treated as literal words in argument position
  @reserved_as_arg [:done, :fi, :esac, :then, :do, :elif, :else, :in, :rbrace]

  defp parse_command_args(state, args, redirects) do
    case current_token(state) do
      {:word, parts, line, col} ->
        word = build_word(parts, line, col)
        parse_command_args(advance(state), [word | args], redirects)

      # Reserved words as arguments - treat as literal words
      {reserved, line, col} when reserved in @reserved_as_arg ->
        word = build_word([{:literal, Atom.to_string(reserved)}], line, col)
        parse_command_args(advance(state), [word | args], redirects)

      # Redirects - token format is {:type, fd, line, col}
      {:less, _fd, line, col} ->
        case parse_redirect(:input, 0, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:greater, fd, line, col} ->
        case parse_redirect(:output, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:dgreater, fd, line, col} ->
        case parse_redirect(:append, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:lessand, _fd, line, col} ->
        case parse_redirect(:duplicate, 0, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:greaterand, fd, line, col} ->
        case parse_redirect(:duplicate, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:lessgreat, _fd, line, col} ->
        case parse_redirect(:read_write, 0, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:andgreat, line, col} ->
        # &> redirects both stdout and stderr to file
        case parse_redirect(:output, :both, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:anddgreat, line, col} ->
        # &>> appends both stdout and stderr to file
        case parse_redirect(:append, :both, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:dless, fd, line, col} ->
        case parse_heredoc(:heredoc, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:dlessdash, fd, line, col} ->
        case parse_heredoc(:heredoc_strip, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      {:tless, fd, line, col} ->
        case parse_herestring(fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          err ->
            err
        end

      # File descriptor redirects with explicit fd like 2>&1
      {:io_number, fd, line, col} ->
        case parse_fd_redirect(fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_command_args(new_state, args, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      # Assignment-like words as arguments (e.g., echo foo=bar, declare -A arr=(...))
      # For builtins like declare/typeset, these can have array literal values
      {:assignment_word, var_name, value_parts, line, col} ->
        state = advance(state)
        # Check if this is an array literal argument (VAR=(...))
        case {value_parts, current_token(state)} do
          {[], {:lparen, _, _}} ->
            # Array literal as argument to declare/local/typeset/etc.
            case parse_array_elements(advance(state), []) do
              {:ok, elements, new_state} ->
                # Build as ArrayAssignment AST for proper handling
                array_assign = %AST.ArrayAssignment{
                  meta: AST.meta(line, col),
                  name: var_name,
                  elements: elements
                }

                parse_command_args(new_state, [array_assign | args], redirects)

              {:error, _, _, _} = err ->
                err
            end

          _ ->
            # Regular assignment-like argument: "name=value"
            word = build_assignment_as_word(var_name, value_parts, line, col)
            parse_command_args(state, [word | args], redirects)
        end

      _ ->
        {Enum.reverse(args), Enum.reverse(redirects), state}
    end
  end

  # Convert an assignment_word token back to a regular word for use as command argument
  defp build_assignment_as_word(var_name, value_parts, line, col) do
    # Reconstruct the parts as: literal "name=", then value parts
    all_parts = [{:literal, var_name <> "="}] ++ convert_assignment_value_parts(value_parts)
    build_word(all_parts, line, col)
  end

  defp convert_assignment_value_parts([]), do: []

  defp convert_assignment_value_parts(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      {:literal, text} -> [{:literal, text}]
      {:variable, name} -> [{:variable, name}]
      {:arith_expand, expr} -> [{:arith_expand, expr}]
      {:command_subst, content} -> [{:command_subst, content}]
      other -> [other]
    end)
  end

  defp parse_redirect(direction, fd, line, col, state) do
    case current_token(state) do
      {:word, [{:literal, "-"}], _, _} when direction == :duplicate ->
        # Close file descriptor: <&- or >&-
        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: :close,
          fd: fd,
          target: :close
        }

        {:ok, redirect, advance(state)}

      {:word, parts, _, _} when direction == :duplicate ->
        # For duplicate (>&), target is a file descriptor number like "1" or "2"
        target_word = build_word(parts, line, col)
        target_str = to_string(target_word)

        case Integer.parse(target_str) do
          {target_fd, ""} ->
            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: direction,
              fd: fd,
              target: {:fd, target_fd}
            }

            {:ok, redirect, advance(state)}

          _ ->
            # Not a number, treat as file
            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: direction,
              fd: fd,
              target: {:file, target_word}
            }

            {:ok, redirect, advance(state)}
        end

      {:word, parts, _, _} ->
        target_word = build_word(parts, line, col)

        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: direction,
          fd: fd,
          target: {:file, target_word}
        }

        {:ok, redirect, advance(state)}

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected file for redirect", tline, tcol}
    end
  end

  defp parse_heredoc(type, fd, line, col, state) do
    strip_tabs = type == :heredoc_strip

    case current_token(state) do
      # Single-quoted delimiter: <<'EOF' - no variable expansion
      {:word, [{:single_quoted, delim}], _, _} ->
        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: :heredoc,
          fd: fd,
          target: {:heredoc_pending, delim, strip_tabs, false}
        }

        {:ok, redirect, advance(state)}

      # Double-quoted delimiter: <<"EOF" - no variable expansion
      {:word, [{:double_quoted, parts}], _, _} ->
        delimiter =
          Enum.map_join(parts, "", fn
            {:literal, s} -> s
            _ -> ""
          end)

        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: :heredoc,
          fd: fd,
          target: {:heredoc_pending, delimiter, strip_tabs, false}
        }

        {:ok, redirect, advance(state)}

      # Unquoted literal delimiter - allows variable expansion
      {:word, [{:literal, delimiter}], _, _} ->
        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: :heredoc,
          fd: fd,
          target: {:heredoc_pending, delimiter, strip_tabs, true}
        }

        {:ok, redirect, advance(state)}

      {:word, parts, _, _} ->
        # Complex word - extract literal parts for delimiter
        # Check if it's quoted (no expansion) or unquoted (with expansion)
        {delimiter, expand} = extract_heredoc_delimiter(parts)

        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: :heredoc,
          fd: fd,
          target: {:heredoc_pending, delimiter, strip_tabs, expand}
        }

        {:ok, redirect, advance(state)}

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected heredoc delimiter", tline, tcol}
    end
  end

  # Extract delimiter string from word parts and determine if expansion is enabled
  defp extract_heredoc_delimiter(parts) do
    {text, has_quotes} =
      Enum.reduce(parts, {"", false}, fn
        {:literal, s}, {acc, q} ->
          {acc <> s, q}

        {:single_quoted, s}, {acc, _q} ->
          {acc <> s, true}

        {:double_quoted, inner_parts}, {acc, _q} ->
          inner =
            Enum.map_join(inner_parts, "", fn
              {:literal, s} -> s
              _ -> ""
            end)

          {acc <> inner, true}

        _, {acc, q} ->
          {acc, q}
      end)

    # If any quoted parts, no expansion
    {text, not has_quotes}
  end

  defp parse_fd_redirect(fd, line, col, state) do
    case current_token(state) do
      {:less, _, _, _} ->
        state = advance(state)

        case current_token(state) do
          {:word, parts, _, _} ->
            target_word = build_word(parts, line, col)

            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: :input,
              fd: fd,
              target: {:file, target_word}
            }

            {:ok, redirect, advance(state)}

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected redirect target", tline, tcol}
        end

      {:greater, _, _, _} ->
        state = advance(state)

        case current_token(state) do
          {:word, parts, _, _} ->
            target_word = build_word(parts, line, col)

            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: :output,
              fd: fd,
              target: {:file, target_word}
            }

            {:ok, redirect, advance(state)}

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected redirect target", tline, tcol}
        end

      {:greaterand, _, _, _} ->
        # 2>&1 style or 2>&- (close fd)
        state = advance(state)

        case current_token(state) do
          {:word, [{:literal, "-"}], _, _} ->
            # Close file descriptor: >&- or 2>&-
            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: :close,
              fd: fd,
              target: :close
            }

            {:ok, redirect, advance(state)}

          {:word, [{:literal, target_fd}], _, _} ->
            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: :duplicate,
              fd: fd,
              target: {:fd, String.to_integer(target_fd)}
            }

            {:ok, redirect, advance(state)}

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected file descriptor", tline, tcol}
        end

      {:dgreater, _, _, _} ->
        state = advance(state)

        case current_token(state) do
          {:word, parts, _, _} ->
            target_word = build_word(parts, line, col)

            redirect = %AST.Redirect{
              meta: AST.meta(line, col),
              direction: :append,
              fd: fd,
              target: {:file, target_word}
            }

            {:ok, redirect, advance(state)}

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected file for redirect", tline, tcol}
        end

      # Heredoc with custom fd: 3<<DELIM
      {:dless, _, _, _} ->
        parse_heredoc(:heredoc, fd, line, col, advance(state))

      # Heredoc strip tabs with custom fd: 3<<-DELIM
      {:dlessdash, _, _, _} ->
        parse_heredoc(:heredoc_strip, fd, line, col, advance(state))

      # Herestring with custom fd: 3<<<word
      {:tless, _, _, _} ->
        parse_herestring(fd, line, col, advance(state))

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected redirect operator", tline, tcol}
    end
  end

  defp parse_herestring(fd, line, col, state) do
    case current_token(state) do
      {:word, parts, _, _} ->
        word = build_word(parts, line, col)

        redirect = %AST.Redirect{
          meta: AST.meta(line, col),
          direction: :herestring,
          fd: fd,
          target: {:word, word}
        }

        {:ok, redirect, advance(state)}

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected string for herestring", tline, tcol}
    end
  end

  # Parse trailing redirects after compound commands (while, for, until, etc.)
  # These only collect redirects, not command arguments
  defp parse_trailing_redirects(state, redirects) do
    case current_token(state) do
      {:less, _fd, line, col} ->
        case parse_redirect(:input, 0, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:greater, fd, line, col} ->
        case parse_redirect(:output, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:dgreater, fd, line, col} ->
        case parse_redirect(:append, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:lessand, _fd, line, col} ->
        case parse_redirect(:duplicate, 0, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:greaterand, fd, line, col} ->
        case parse_redirect(:duplicate, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:lessgreat, _fd, line, col} ->
        case parse_redirect(:read_write, 0, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:andgreat, line, col} ->
        case parse_redirect(:output, :both, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:anddgreat, line, col} ->
        case parse_redirect(:append, :both, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:dless, fd, line, col} ->
        case parse_heredoc(:heredoc, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:dlessdash, fd, line, col} ->
        case parse_heredoc(:heredoc_strip, fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:tless, fd, line, col} ->
        case parse_herestring(fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      {:io_number, fd, line, col} ->
        case parse_fd_redirect(fd, line, col, advance(state)) do
          {:ok, redirect, new_state} ->
            parse_trailing_redirects(new_state, [redirect | redirects])

          {:error, _, _, _} = err ->
            err
        end

      _ ->
        # No more redirects - return what we've collected
        {:ok, Enum.reverse(redirects), state}
    end
  end

  # ===========================================================================
  # Control Flow Parsing
  # ===========================================================================

  defp parse_if(state) do
    {line, col} = current_position(state)
    # skip 'if'
    state = advance(state)

    # Parse condition
    case parse_statement_list(state, []) do
      {:ok, condition_stmts, new_state} ->
        # Expect 'then'
        case current_token(new_state) do
          {:then, _, _} ->
            new_state = advance(new_state)

            # SC1051/SC1052: Semicolon immediately after 'then' is not allowed
            case current_token(new_state) do
              {:semi, sline, scol} ->
                {:error,
                 "(SC1051) Semicolons directly after `then` are not allowed. Remove the `;`",
                 sline, scol}

              _ ->
                parse_if_body(condition_stmts, line, col, new_state, [], nil)
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected 'then' after if condition", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  # Parse the then-body and then collect elif/else clauses
  defp parse_if_body(condition, line, col, state, elif_clauses, _else_body) do
    # Parse the body for this branch
    case parse_statement_list(state, []) do
      {:ok, body_stmts, new_state} ->
        case current_token(new_state) do
          {:elif, _, _} ->
            new_state = advance(new_state)
            # Parse elif condition
            case parse_statement_list(new_state, []) do
              {:ok, elif_cond, newer_state} ->
                case current_token(newer_state) do
                  {:then, _, _} ->
                    newer_state = advance(newer_state)

                    # SC1051/SC1052: Semicolon immediately after 'then' is not allowed
                    case current_token(newer_state) do
                      {:semi, sline, scol} ->
                        {:error,
                         "(SC1051) Semicolons directly after `then` are not allowed. Remove the `;`",
                         sline, scol}

                      _ ->
                        # Parse elif body in a new recursive call
                        # Store current body_stmts for THIS branch, then parse elif body
                        parse_elif_body(
                          condition,
                          body_stmts,
                          elif_cond,
                          line,
                          col,
                          newer_state,
                          elif_clauses
                        )
                    end

                  token ->
                    {tline, tcol} = token_position(token)
                    {:error, "expected 'then' after elif condition", tline, tcol}
                end

              {:error, _, _, _} = err ->
                err
            end

          {:else, _, _} ->
            new_state = advance(new_state)

            # SC1053: Semicolon immediately after 'else' is not allowed
            case current_token(new_state) do
              {:semi, sline, scol} ->
                {:error,
                 "(SC1053) Semicolons directly after `else` are not allowed. Remove the `;`",
                 sline, scol}

              _ ->
                case parse_statement_list(new_state, []) do
                  {:ok, else_stmts, newer_state} ->
                    case current_token(newer_state) do
                      {:fi, _, _} ->
                        if_node =
                          build_if(condition, body_stmts, elif_clauses, else_stmts, line, col)

                        {:ok, if_node, advance(newer_state)}

                      token ->
                        {tline, tcol} = token_position(token)
                        {:error, "expected 'fi' to close if", tline, tcol}
                    end

                  {:error, _, _, _} = err ->
                    err
                end
            end

          {:fi, _, _} ->
            if_node = build_if(condition, body_stmts, elif_clauses, nil, line, col)
            {:ok, if_node, advance(new_state)}

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected 'elif', 'else', or 'fi'", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  # Parse elif body and continue with more elif/else/fi
  defp parse_elif_body(orig_condition, orig_body, elif_cond, line, col, state, elif_clauses) do
    case parse_statement_list(state, []) do
      {:ok, elif_body_stmts, new_state} ->
        # Add this elif clause to the list
        new_elif_clauses = [{wrap_condition(elif_cond), elif_body_stmts} | elif_clauses]

        case current_token(new_state) do
          {:elif, _, _} ->
            new_state = advance(new_state)
            # Parse next elif condition
            case parse_statement_list(new_state, []) do
              {:ok, next_elif_cond, newer_state} ->
                case current_token(newer_state) do
                  {:then, _, _} ->
                    newer_state = advance(newer_state)

                    # SC1051/SC1052: Semicolon immediately after 'then' is not allowed
                    case current_token(newer_state) do
                      {:semi, sline, scol} ->
                        {:error,
                         "(SC1051) Semicolons directly after `then` are not allowed. Remove the `;`",
                         sline, scol}

                      _ ->
                        # Recursively parse next elif body
                        parse_elif_body(
                          orig_condition,
                          orig_body,
                          next_elif_cond,
                          line,
                          col,
                          newer_state,
                          new_elif_clauses
                        )
                    end

                  token ->
                    {tline, tcol} = token_position(token)
                    {:error, "expected 'then' after elif condition", tline, tcol}
                end

              {:error, _, _, _} = err ->
                err
            end

          {:else, _, _} ->
            new_state = advance(new_state)

            # SC1053: Semicolon immediately after 'else' is not allowed
            case current_token(new_state) do
              {:semi, sline, scol} ->
                {:error,
                 "(SC1053) Semicolons directly after `else` are not allowed. Remove the `;`",
                 sline, scol}

              _ ->
                case parse_statement_list(new_state, []) do
                  {:ok, else_stmts, newer_state} ->
                    case current_token(newer_state) do
                      {:fi, _, _} ->
                        if_node =
                          build_if(
                            orig_condition,
                            orig_body,
                            new_elif_clauses,
                            else_stmts,
                            line,
                            col
                          )

                        {:ok, if_node, advance(newer_state)}

                      token ->
                        {tline, tcol} = token_position(token)
                        {:error, "expected 'fi' to close if", tline, tcol}
                    end

                  {:error, _, _, _} = err ->
                    err
                end
            end

          {:fi, _, _} ->
            if_node = build_if(orig_condition, orig_body, new_elif_clauses, nil, line, col)
            {:ok, if_node, advance(new_state)}

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected 'elif', 'else', or 'fi'", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp build_if(condition, body, elif_clauses, else_body, line, col) do
    %AST.If{
      meta: AST.meta(line, col),
      condition: wrap_condition(condition),
      body: body,
      elif_clauses: Enum.reverse(elif_clauses),
      else_body: else_body
    }
  end

  # Check if statements represent a single executable statement (excluding separators)
  defp wrap_condition(stmts) when is_list(stmts) do
    executable = Enum.reject(stmts, &match?({:separator, _}, &1))

    case executable do
      [single] ->
        # Single executable statement - return it directly
        # Include separators in compound for formatting if there are any
        if length(stmts) == 1 do
          single
        else
          %AST.Compound{
            meta: AST.meta(1, 1),
            kind: :sequential,
            statements: stmts
          }
        end

      _ ->
        %AST.Compound{
          meta: AST.meta(1, 1),
          kind: :sequential,
          statements: stmts
        }
    end
  end

  defp parse_for(state) do
    {line, col} = current_position(state)
    # skip 'for'
    state = advance(state)

    # Check for C-style for loop: for ((init; cond; update))
    case current_token(state) do
      {:arith_command, content, _, _} ->
        parse_c_style_for(state, content, line, col)

      {:word, [{:literal, var_name}], _, _} ->
        state = advance(state)
        state = skip_newlines(state)

        # Check for 'in' (optional - if missing, uses positional params)
        {items, state} =
          case current_token(state) do
            {:in, _, _} ->
              state = advance(state)
              parse_word_list(state, [])

            _ ->
              {[], state}
          end

        state = skip_separators(state)

        # Expect 'do'
        case current_token(state) do
          {:do, _, _} ->
            state = advance(state)

            case parse_statement_list(state, []) do
              {:ok, body, new_state} ->
                case current_token(new_state) do
                  {:done, _, _} ->
                    for_loop = %AST.ForLoop{
                      meta: AST.meta(line, col),
                      variable: var_name,
                      items: items,
                      body: body
                    }

                    {:ok, for_loop, advance(new_state)}

                  token ->
                    {tline, tcol} = token_position(token)
                    {:error, "expected 'done' to close for loop", tline, tcol}
                end

              {:error, _, _, _} = err ->
                err
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected 'do' in for loop", tline, tcol}
        end

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected variable name after 'for'", tline, tcol}
    end
  end

  # Parse C-style for loop: for ((init; cond; update)); do ... done
  defp parse_c_style_for(state, content, line, col) do
    # Skip the arith_command token
    state = advance(state)
    state = skip_separators(state)

    # Parse the content into init, condition, update
    # Content is like "i=0;i<3;i++" or "i=0; i<3; i++"
    parts = String.split(content, ";", parts: 3)

    {init, condition, update} =
      case parts do
        [i, c, u] -> {String.trim(i), String.trim(c), String.trim(u)}
        [i, c] -> {String.trim(i), String.trim(c), ""}
        [i] -> {String.trim(i), "", ""}
        [] -> {"", "", ""}
      end

    # Expect 'do'
    case current_token(state) do
      {:do, _, _} ->
        state = advance(state)

        case parse_statement_list(state, []) do
          {:ok, body, new_state} ->
            case current_token(new_state) do
              {:done, _, _} ->
                for_loop = %AST.ForLoop{
                  meta: AST.meta(line, col),
                  variable: nil,
                  items: [],
                  init: init,
                  condition: condition,
                  update: update,
                  body: body
                }

                {:ok, for_loop, advance(new_state)}

              token ->
                {tline, tcol} = token_position(token)
                {:error, "expected 'done' to close for loop", tline, tcol}
            end

          {:error, _, _, _} = err ->
            err
        end

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected 'do' in for loop", tline, tcol}
    end
  end

  defp parse_word_list(state, acc) do
    case current_token(state) do
      {:word, parts, line, col} ->
        word = build_word(parts, line, col)
        parse_word_list(advance(state), [word | acc])

      _ ->
        {Enum.reverse(acc), state}
    end
  end

  defp parse_while(state) do
    parse_while_until(:while, state)
  end

  defp parse_until(state) do
    parse_while_until(:until, state)
  end

  defp parse_while_until(type, state) do
    {line, col} = current_position(state)
    # skip 'while' or 'until'
    state = advance(state)

    # Parse condition
    case parse_statement_list(state, []) do
      {:ok, condition_stmts, new_state} ->
        case current_token(new_state) do
          {:do, _, _} ->
            new_state = advance(new_state)

            case parse_statement_list(new_state, []) do
              {:ok, body, newer_state} ->
                case current_token(newer_state) do
                  {:done, _, _} ->
                    # Parse any trailing redirects after 'done' (e.g., done < file)
                    case parse_trailing_redirects(advance(newer_state), []) do
                      {:ok, redirects, final_state} ->
                        while_loop = %AST.WhileLoop{
                          meta: AST.meta(line, col),
                          until: type == :until,
                          condition: wrap_condition(condition_stmts),
                          body: body,
                          redirects: redirects
                        }

                        {:ok, while_loop, final_state}

                      {:error, _, _, _} = err ->
                        err
                    end

                  token ->
                    {tline, tcol} = token_position(token)
                    {:error, "expected 'done' to close while loop", tline, tcol}
                end

              {:error, _, _, _} = err ->
                err
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected 'do' in while loop", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp parse_case(state) do
    {line, col} = current_position(state)
    # skip 'case'
    state = advance(state)

    # Parse word to match
    case current_token(state) do
      {:word, parts, wline, wcol} ->
        word = build_word(parts, wline, wcol)
        state = advance(state)
        state = skip_newlines(state)

        case current_token(state) do
          {:in, _, _} ->
            state = advance(state)
            state = skip_separators(state)

            case parse_case_items(state, []) do
              {:ok, cases, new_state} ->
                case current_token(new_state) do
                  {:esac, _, _} ->
                    case_node = %AST.Case{
                      meta: AST.meta(line, col),
                      word: word,
                      cases: cases
                    }

                    {:ok, case_node, advance(new_state)}

                  token ->
                    {tline, tcol} = token_position(token)
                    {:error, "expected 'esac' to close case", tline, tcol}
                end

              {:error, _, _, _} = err ->
                err
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected 'in' after case word", tline, tcol}
        end

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected word after 'case'", tline, tcol}
    end
  end

  defp parse_case_items(state, acc) do
    state = skip_separators(state)

    case current_token(state) do
      {:esac, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:lparen, _, _} ->
        # Optional ( before pattern
        parse_case_item(advance(state), acc)

      {:word, _, _, _} ->
        parse_case_item(state, acc)

      # Glob pattern starting with [
      {:lbracket, _, _} ->
        parse_case_item(state, acc)

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected case pattern or 'esac'", tline, tcol}
    end
  end

  defp parse_case_item(state, acc) do
    # Parse patterns separated by |
    case parse_case_patterns(state, []) do
      {:ok, patterns, new_state} ->
        case current_token(new_state) do
          {:rparen, _, _} ->
            new_state = advance(new_state)

            case parse_statement_list(new_state, []) do
              {:ok, body, newer_state} ->
                # Expect ;; or ;;& or ;& - store the terminator type
                {terminator, newer_state} =
                  case current_token(newer_state) do
                    {:dsemi, _, _} -> {:break, advance(newer_state)}
                    {:dsemi_and, _, _} -> {:continue_matching, advance(newer_state)}
                    {:semi_and, _, _} -> {:fallthrough, advance(newer_state)}
                    _ -> {:break, newer_state}
                  end

                parse_case_items(newer_state, [{patterns, body, terminator} | acc])

              {:error, _, _, _} = err ->
                err
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected ')' after case pattern", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp parse_case_patterns(state, acc) do
    # Parse a single pattern which may consist of multiple consecutive parts
    # e.g., [Yy][Ee][Ss] or *.txt or [Yy]es
    case collect_case_pattern_parts(state, []) do
      {:ok, pattern_parts, new_state} when pattern_parts != [] ->
        {line, col} = current_position(state)
        pattern = build_word(pattern_parts, line, col)

        case current_token(new_state) do
          {:pipe, _, _} ->
            parse_case_patterns(advance(new_state), [pattern | acc])

          _ ->
            {:ok, Enum.reverse([pattern | acc]), new_state}
        end

      {:ok, [], _state} ->
        token = current_token(state)
        {tline, tcol} = token_position(token)
        {:error, "expected case pattern", tline, tcol}

      {:error, _, _, _} = err ->
        err
    end
  end

  # Collect consecutive pattern parts (words and bracket globs) until we hit | or )
  defp collect_case_pattern_parts(state, acc) do
    case current_token(state) do
      {:word, parts, _line, _col} ->
        collect_case_pattern_parts(advance(state), acc ++ parts)

      # Glob pattern starting with [ like [abc] or [!abc]
      {:lbracket, _line, _col} ->
        case parse_bracket_glob_pattern_parts(state) do
          {:ok, glob_part, new_state} ->
            collect_case_pattern_parts(new_state, acc ++ [glob_part])

          {:error, _, _, _} = err ->
            err
        end

      # Stop on pipe, rparen, or other non-pattern tokens
      _ ->
        {:ok, acc, state}
    end
  end

  # Parse a bracket glob pattern and return just the glob part (not a full word)
  defp parse_bracket_glob_pattern_parts(state) do
    # skip [
    state = advance(state)

    # Collect tokens until ]
    {parts, state} = collect_bracket_pattern_parts(state, [])

    case current_token(state) do
      {:rbracket, _, _} ->
        pattern_content = Enum.map_join(parts, "", fn text -> text end)
        {:ok, {:glob, "[#{pattern_content}]"}, advance(state)}

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected ']' to close bracket pattern", tline, tcol}
    end
  end

  defp collect_bracket_pattern_parts(state, acc) do
    case current_token(state) do
      {:rbracket, _, _} ->
        {Enum.reverse(acc), state}

      {:word, [{:literal, text}], _, _} ->
        collect_bracket_pattern_parts(advance(state), [text | acc])

      {:word, parts, _, _} ->
        # More complex word - extract text
        text =
          Enum.map_join(parts, "", fn
            {:literal, t} -> t
            {_, t} when is_binary(t) -> t
            _ -> ""
          end)

        collect_bracket_pattern_parts(advance(state), [text | acc])

      {:bang, _, _} ->
        collect_bracket_pattern_parts(advance(state), ["!" | acc])

      _ ->
        {Enum.reverse(acc), state}
    end
  end

  # ===========================================================================
  # Compound Commands
  # ===========================================================================

  defp parse_brace_group(state) do
    {line, col} = current_position(state)
    # skip '{'
    state = advance(state)

    case parse_statement_list(state, []) do
      {:ok, stmts, new_state} ->
        case current_token(new_state) do
          {:rbrace, rline, rcol} ->
            # SC1055: Empty brace group needs at least one command
            if stmts == [] do
              {:error,
               "(SC1055) Brace groups need at least one command. Use `true` as a no-op if needed",
               rline, rcol}
            else
              new_state = advance(new_state)

              # Collect any redirections after the brace group
              case parse_trailing_redirects(new_state, []) do
                {:ok, redirects, final_state} ->
                  compound = %AST.Compound{
                    meta: AST.meta(line, col),
                    kind: :group,
                    statements: stmts,
                    redirects: redirects
                  }

                  {:ok, compound, final_state}

                {:error, _, _, _} = err ->
                  err
              end
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected '}' to close brace group", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp parse_subshell(state) do
    {line, col} = current_position(state)
    # skip '('
    state = advance(state)

    case parse_statement_list(state, []) do
      {:ok, stmts, new_state} ->
        case current_token(new_state) do
          {:rparen, _, _} ->
            new_state = advance(new_state)

            # Collect any redirections after the subshell
            case parse_trailing_redirects(new_state, []) do
              {:ok, redirects, final_state} ->
                compound = %AST.Compound{
                  meta: AST.meta(line, col),
                  kind: :subshell,
                  statements: stmts,
                  redirects: redirects
                }

                {:ok, compound, final_state}

              {:error, _, _, _} = err ->
                err
            end

          token ->
            {tline, tcol} = token_position(token)
            {:error, "expected ')' to close subshell", tline, tcol}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp parse_arithmetic_command(state) do
    case current_token(state) do
      # New format: tokenizer collected raw content
      {:arith_command, content, line, col} ->
        arith = %AST.Arithmetic{
          meta: AST.meta(line, col),
          expression: content
        }

        {:ok, arith, advance(state)}

      # Legacy format: dlparen with separate tokens (kept for backwards compat)
      {:dlparen, line, col} ->
        state = advance(state)
        {content, new_state} = collect_until_arith_close(state, [])

        arith = %AST.Arithmetic{
          meta: AST.meta(line, col),
          expression: content
        }

        {:ok, arith, new_state}
    end
  end

  defp collect_until_arith_close(state, acc) do
    case current_token(state) do
      {:drparen, _, _} ->
        # Double right paren token if it exists
        {Enum.reverse(acc) |> Enum.join(" "), advance(state)}

      {:rparen, _, _} ->
        # Check for ))
        next_state = advance(state)

        case current_token(next_state) do
          {:rparen, _, _} ->
            {Enum.reverse(acc) |> Enum.join(" "), advance(next_state)}

          _ ->
            collect_until_arith_close(next_state, [")" | acc])
        end

      {:word, [{:literal, text}], _, _} ->
        collect_until_arith_close(advance(state), [text | acc])

      {:word, parts, _, _} ->
        text = parts_to_string(parts)
        collect_until_arith_close(advance(state), [text | acc])

      {:eof, _, _} ->
        {Enum.reverse(acc) |> Enum.join(" "), state}

      {type, _, _} when is_atom(type) ->
        collect_until_arith_close(advance(state), [token_to_arith_string(type) | acc])

      {type, _, _, _} when is_atom(type) ->
        collect_until_arith_close(advance(state), [token_to_arith_string(type) | acc])

      _ ->
        collect_until_arith_close(advance(state), acc)
    end
  end

  # Convert token types to their arithmetic string representation
  defp token_to_arith_string(:greater), do: ">"
  defp token_to_arith_string(:less), do: "<"
  defp token_to_arith_string(:ampersand), do: "&"
  defp token_to_arith_string(:pipe), do: "|"
  defp token_to_arith_string(:semi), do: ";"
  defp token_to_arith_string(type), do: Atom.to_string(type)

  defp parse_test_command(state) do
    {line, col} = current_position(state)
    # skip '[['
    state = advance(state)

    # Collect tokens until ]]
    case collect_test_expression(state, [], line, col) do
      {:ok, expression, new_state} ->
        # [[ ]] creates TestExpression, [ ] creates TestCommand
        test_expr = %AST.TestExpression{
          meta: AST.meta(line, col),
          expression: expression
        }

        {:ok, test_expr, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  # Operators that should be returned as plain strings in test expressions
  @test_expr_string_operators ["=", "==", "!=", "=~"]

  defp collect_test_expression(state, acc, start_line, start_col) do
    case current_token(state) do
      {:drbracket, _, _} ->
        {:ok, Enum.reverse(acc), advance(state)}

      # SC1033: [[ closed with ] instead of ]]
      {:rbracket, line, col} ->
        {:error, "(SC1033) [[ was closed with ] instead of ]] - use ]] to close [[", line, col}

      # SC1026: Using [ for grouping inside [[ ]] - use ( ) instead
      {:lbracket, line, col} ->
        {:error,
         "(SC1026) Can't use [ ] for grouping in [[ ]]. Use ( ) instead: [[ ( a || b ) && c ]]",
         line, col}

      {:word, [{:literal, op}], _line, _col} when op in @test_expr_string_operators ->
        # Comparison operators are returned as plain strings
        collect_test_expression(advance(state), [op | acc], start_line, start_col)

      # SC1029: Escaped parentheses in [[ ]] - don't escape, use ( ) directly
      {:word, [{:literal, "("}], line, col} ->
        {:error,
         "(SC1029) Escaped \\( in [[ ]]. Don't escape parentheses - use ( directly for grouping",
         line, col}

      {:word, [{:literal, ")"}], line, col} ->
        {:error,
         "(SC1029) Escaped \\) in [[ ]]. Don't escape parentheses - use ) directly for grouping",
         line, col}

      {:word, parts, line, col} ->
        word = build_word(parts, line, col)
        collect_test_expression(advance(state), [word | acc], start_line, start_col)

      {:regex_pattern, parts, line, col} ->
        regex = build_regex_pattern(parts, line, col)
        collect_test_expression(advance(state), [regex | acc], start_line, start_col)

      {:and_if, _, _} ->
        collect_test_expression(advance(state), ["&&" | acc], start_line, start_col)

      {:or_if, _, _} ->
        collect_test_expression(advance(state), ["||" | acc], start_line, start_col)

      # String comparison operators < and >
      {:less, _, _, _} ->
        collect_test_expression(advance(state), ["<" | acc], start_line, start_col)

      {:greater, _, _, _} ->
        collect_test_expression(advance(state), [">" | acc], start_line, start_col)

      # Handle ! followed by = as !=
      {:bang, _, _} ->
        next_state = advance(state)

        case current_token(next_state) do
          {:word, [{:literal, "="}], _, _} ->
            collect_test_expression(advance(next_state), ["!=" | acc], start_line, start_col)

          _ ->
            collect_test_expression(next_state, ["!" | acc], start_line, start_col)
        end

      # SC1033: missing ]] to close [[
      {:eof, _, _} ->
        {:error, "(SC1033) missing ]] to close [[", start_line, start_col}

      {op, _line, _col} when op in [:eq, :ne, :lt, :gt, :le, :ge] ->
        collect_test_expression(advance(state), [Atom.to_string(op) | acc], start_line, start_col)

      _ ->
        collect_test_expression(advance(state), acc, start_line, start_col)
    end
  end

  # Parse [ expression ] - single bracket test command
  defp parse_test_bracket_command(state) do
    {line, col} = current_position(state)
    # skip '['
    state = advance(state)

    # Collect args until ]
    case collect_test_bracket_args(state, [], line, col) do
      {:ok, args, new_state} ->
        # Validate test arguments for common errors
        case validate_test_args(args, line, col) do
          :ok ->
            # Use TestCommand struct - the serializer handles adding [ ]
            test_cmd = %AST.TestCommand{
              meta: AST.meta(line, col),
              args: args
            }

            {:ok, test_cmd, new_state}

          {:error, _, _, _} = err ->
            err
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp collect_test_bracket_args(state, acc, start_line, start_col) do
    case current_token(state) do
      {:rbracket, _line, _col} ->
        # Don't include ] in args - TestCommand serializer adds it
        {:ok, Enum.reverse(acc), advance(state)}

      # SC1034: [ closed with ]] instead of ]
      {:drbracket, line, col} ->
        {:error, "(SC1034) [ was closed with ]] instead of ] - use ] to close [", line, col}

      # SC1026: Using [ for grouping inside [ ] - use \( \) or rewrite
      {:lbracket, line, col} ->
        {:error,
         "(SC1026) Can't use [ ] for grouping in [ ]. Use \\( \\) or rewrite: { [ a ] || [ b ]; } && [ c ]",
         line, col}

      # Handle ! followed by = as !=
      {:bang, _, _} ->
        next_state = advance(state)

        case current_token(next_state) do
          {:word, [{:literal, "="}], _, _} ->
            collect_test_bracket_args(advance(next_state), ["!=" | acc], start_line, start_col)

          _ ->
            collect_test_bracket_args(next_state, ["!" | acc], start_line, start_col)
        end

      # Comparison operators as plain strings
      {:word, [{:literal, op}], _line, _col} when op in @test_expr_string_operators ->
        collect_test_bracket_args(advance(state), [op | acc], start_line, start_col)

      {:word, parts, line, col} ->
        word = build_word(parts, line, col)
        collect_test_bracket_args(advance(state), [word | acc], start_line, start_col)

      # SC1034: missing ] to close [
      {:eof, _, _} ->
        {:error, "(SC1034) missing ] to close [", start_line, start_col}

      # SC1028: Unescaped parentheses inside [ ] - must be escaped as \( \)
      {:lparen, line, col} ->
        {:error,
         "(SC1028) Unescaped ( in [ ]. For grouping, use \\( or rewrite: { [ a ] || [ b ]; } && [ c ]",
         line, col}

      {:rparen, line, col} ->
        {:error,
         "(SC1028) Unescaped ) in [ ]. For grouping, use \\) or rewrite: { [ a ] || [ b ]; } && [ c ]",
         line, col}

      # SC1080: Newline inside [ ] without backslash continuation
      {:newline, line, col} ->
        {:error,
         "(SC1080) [ ] does not allow line breaks without backslash continuation. Use \\ before newline or use [[ ]]",
         line, col}

      # Handle other operators as literal words
      {op, line, col} when is_atom(op) ->
        word = build_word([{:literal, Atom.to_string(op)}], line, col)
        collect_test_bracket_args(advance(state), [word | acc], start_line, start_col)

      _ ->
        collect_test_bracket_args(advance(state), acc, start_line, start_col)
    end
  end

  # Unary test operators that require an argument
  @unary_test_operators ~w(-a -b -c -d -e -f -g -h -k -L -n -N -O -G -p -r -s -S -t -u -w -x -z)

  # Binary test operators that require arguments on both sides
  @binary_test_operators ~w(= == != -eq -ne -lt -le -gt -ge -nt -ot -ef =~)

  # Validate test command arguments for common errors
  defp validate_test_args(args, start_line, start_col) do
    # Convert args to strings for validation
    string_args = Enum.map(args, &arg_to_string/1)

    cond do
      # SC1020: Check if any word ends with ] (missing space before ])
      word_ends_with_bracket?(string_args) ->
        {:error, "(SC1020) missing space before ]", start_line, start_col}

      # SC1019: Check for unary operator without argument
      unary_missing_argument?(string_args) ->
        {:error, "(SC1019) unary operator requires an argument", start_line, start_col}

      # SC1027: Check for binary operator without both arguments
      binary_missing_argument?(string_args) ->
        {:error, "(SC1027) binary operator requires arguments on both sides", start_line,
         start_col}

      true ->
        :ok
    end
  end

  defp arg_to_string(%AST.Word{parts: parts}), do: parts_to_string(parts)
  defp arg_to_string(str) when is_binary(str), do: str
  defp arg_to_string(_), do: ""

  defp parts_to_string(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      {:literal, s} -> s
      _ -> ""
    end)
  end

  defp parts_to_string(_), do: ""

  # SC1020: Check if any argument ends with ] (missing space)
  defp word_ends_with_bracket?(args) do
    Enum.any?(args, fn
      str when is_binary(str) ->
        String.length(str) > 1 and String.ends_with?(str, "]")

      %AST.Word{parts: parts} ->
        # Check if the last literal part ends with ]
        case List.last(parts) do
          {:literal, text} when is_binary(text) ->
            String.length(text) > 1 and String.ends_with?(text, "]")

          _ ->
            false
        end

      _ ->
        false
    end)
  end

  # SC1019: Unary operator at the end without argument
  defp unary_missing_argument?(args) do
    case List.last(args) do
      op when op in @unary_test_operators -> true
      _ -> false
    end
  end

  # SC1027: Binary operator without arguments on both sides
  defp binary_missing_argument?(args) do
    cond do
      # Binary operator at the very end (missing right operand)
      List.last(args) in @binary_test_operators ->
        true

      # Binary operator at the very beginning (missing left operand)
      List.first(args) in @binary_test_operators ->
        true

      true ->
        false
    end
  end

  defp parse_function(state) do
    {line, col} = current_position(state)
    # skip 'function'
    state = advance(state)

    case current_token(state) do
      {:word, [{:literal, name}], wline, wcol} ->
        # SC1095: Check if function name contains { (missing space between name and {)
        if String.contains?(name, "{") do
          {:error,
           "(SC1095) Missing space between function name and `{`. Use `function #{String.split(name, "{") |> hd()} { ...` instead",
           wline, wcol}
        else
          state = advance(state)

          # Optional ()
          state =
            case current_token(state) do
              {:lparen, _, _} ->
                state = advance(state)

                case current_token(state) do
                  {:rparen, _, _} -> advance(state)
                  _ -> state
                end

              _ ->
                state
            end

          state = skip_newlines(state)

          # Parse body (usually { ... })
          case parse_function_body(state) do
            {:ok, body, new_state} ->
              func = %Function{
                meta: AST.meta(line, col),
                name: name,
                body: body
              }

              {:ok, func, new_state}

            {:error, _, _, _} = err ->
              err
          end
        end

      token ->
        {tline, tcol} = token_position(token)
        {:error, "expected function name", tline, tcol}
    end
  end

  # Parse function body - usually a brace group { ... }
  # Returns the body as a list of statements
  defp parse_function_body(state) do
    case parse_command(state) do
      {:ok, body, new_state} ->
        # Extract statements from compound command if it's a brace group
        statements =
          case body do
            %AST.Compound{kind: :group, statements: stmts} -> stmts
            other -> [other]
          end

        {:ok, statements, new_state}

      {:error, _, _, _} = err ->
        err
    end
  end

  defp build_word(parts, line, col) do
    # Determine if word is entirely single or double quoted
    {quoted, converted_parts} = convert_word_parts(parts)

    %AST.Word{
      meta: AST.meta(line, col),
      parts: converted_parts,
      quoted: quoted
    }
  end

  defp build_regex_pattern(parts, line, col) do
    converted_parts = convert_regex_parts(parts)

    %AST.RegexPattern{
      meta: AST.meta(line, col),
      parts: converted_parts
    }
  end

  defp convert_regex_parts(parts) do
    Enum.flat_map(parts, fn
      {:literal, text} ->
        [{:literal, text}]

      {:variable, name} ->
        [{:variable, %AST.Variable{name: name}}]

      {:variable_braced, name, ops} ->
        [{:variable, build_variable_ast(name, ops)}]

      {:single_quoted, text} ->
        [{:single_quoted, text}]

      {:double_quoted, inner_parts} ->
        [{:double_quoted, convert_double_quoted_parts(inner_parts)}]

      other ->
        [other]
    end)
  end

  # If parts is a single single-quoted or double-quoted string, unwrap it
  defp convert_word_parts([{:single_quoted, text}]) do
    {:single, [{:literal, text}]}
  end

  defp convert_word_parts([{:double_quoted, inner_parts}]) do
    {:double, convert_double_quoted_parts(inner_parts)}
  end

  # Otherwise, convert all parts with quoted: :none
  defp convert_word_parts(parts) do
    converted =
      Enum.flat_map(parts, fn
        {:literal, text} ->
          [{:literal, text}]

        {:variable, name} ->
          [{:variable, %AST.Variable{name: name}}]

        {:variable_braced, name, ops} ->
          [{:variable, build_variable_ast(name, ops)}]

        {:single_quoted, text} ->
          [{:single_quoted, text}]

        {:double_quoted, inner_parts} ->
          [{:double_quoted, convert_double_quoted_parts(inner_parts)}]

        {:command_subst, content} ->
          [{:command_subst, parse_command_subst(content)}]

        {:backtick, content} ->
          [{:command_subst, parse_command_subst(content)}]

        {:process_subst_in, content} ->
          [{:process_subst_in, parse_command_subst(content)}]

        {:process_subst_out, content} ->
          [{:process_subst_out, parse_command_subst(content)}]

        {:arith_expand, expr} ->
          [{:arith_expand, expr}]

        {:glob, pattern} ->
          [{:glob, pattern}]

        {:brace_expand, spec} ->
          [{:brace_expand, build_brace_expand(spec)}]

        other ->
          [other]
      end)

    {:none, converted}
  end

  # Common helper to convert parts inside double-quoted strings
  defp convert_double_quoted_parts(inner_parts) do
    Enum.map(inner_parts, fn
      {:literal, text} -> {:literal, text}
      {:variable, name} -> {:variable, %AST.Variable{name: name}}
      {:variable_braced, name, ops} -> {:variable, build_variable_ast(name, ops)}
      {:command_subst, content} -> {:command_subst, parse_command_subst(content)}
      {:process_subst_in, content} -> {:process_subst_in, parse_command_subst(content)}
      {:process_subst_out, content} -> {:process_subst_out, parse_command_subst(content)}
      other -> other
    end)
  end

  # Build AST.BraceExpand from tokenizer brace expansion spec
  defp build_brace_expand(%{type: type} = spec) do
    %AST.BraceExpand{
      type: type,
      items: convert_brace_items(Map.get(spec, :items)),
      range_start: Map.get(spec, :range_start),
      range_end: Map.get(spec, :range_end),
      step: Map.get(spec, :step),
      zero_pad: Map.get(spec, :zero_pad)
    }
  end

  # Convert brace expansion items, recursively converting nested expansions
  defp convert_brace_items(nil), do: nil

  defp convert_brace_items(items) when is_list(items) do
    Enum.map(items, fn item_parts ->
      Enum.map(item_parts, fn
        {:brace_expand, nested_spec} -> {:brace_expand, build_brace_expand(nested_spec)}
        {:literal, text} -> {:literal, text}
        other -> other
      end)
    end)
  end

  # Build AST.Variable from braced variable operations
  # The tokenizer produces ops in various formats:
  # - Keywords: [subscript: {:index, "0"}], [length: true], [list_keys: true], [slice: {offset, len}], [indirect: true]
  # - Tuples: [{:remove_suffix, "|*", :longest}], [{:substitute, "a", "b", :first}]
  defp build_variable_ast(name, ops) do
    subscript = Keyword.get(ops, :subscript)
    length = Keyword.get(ops, :length, false)
    list_keys = Keyword.get(ops, :list_keys, false)
    slice = Keyword.get(ops, :slice)
    indirect = Keyword.get(ops, :indirect, false)

    # Find expansion from either keyword or tuple format
    expansion =
      cond do
        indirect ->
          {:indirect}

        list_keys ->
          {:list_keys}

        slice != nil ->
          {offset, len} = slice
          {:slice, offset, len}

        length ->
          {:length}

        Keyword.has_key?(ops, :default) ->
          {:default, Keyword.get(ops, :default)}

        Keyword.has_key?(ops, :assign_default) ->
          {:assign_default, Keyword.get(ops, :assign_default)}

        Keyword.has_key?(ops, :error) ->
          {:error, Keyword.get(ops, :error)}

        Keyword.has_key?(ops, :alternate) ->
          {:alternate, Keyword.get(ops, :alternate)}

        true ->
          find_expansion_tuple(ops)
      end

    %AST.Variable{name: name, subscript: subscript, expansion: expansion}
  end

  # Find expansion operations stored as tuples (not keywords)
  defp find_expansion_tuple([]), do: nil
  defp find_expansion_tuple([{:subscript, _} | rest]), do: find_expansion_tuple(rest)
  defp find_expansion_tuple([{:length, _} | rest]), do: find_expansion_tuple(rest)
  defp find_expansion_tuple([{:substring, offset, len} | _]), do: {:substring, offset, len}

  defp find_expansion_tuple([{:remove_prefix, pattern, mode} | _]),
    do: {:remove_prefix, pattern, mode}

  defp find_expansion_tuple([{:remove_suffix, pattern, mode} | _]),
    do: {:remove_suffix, pattern, mode}

  defp find_expansion_tuple([{:substitute, pattern, replacement, mode} | _]),
    do: {:substitute, pattern, replacement, mode}

  defp find_expansion_tuple([{:case_modify, mode} | _]),
    do: {:case_modify, mode}

  defp find_expansion_tuple([_ | rest]), do: find_expansion_tuple(rest)

  # Parse command substitution from pre-tokenized content (from $(...)
  defp parse_command_subst(tokens) when is_list(tokens) do
    # Add EOF if not present
    tokens_with_eof =
      case List.last(tokens) do
        {:eof, _, _} -> tokens
        _ -> tokens ++ [{:eof, 0, 0}]
      end

    case parse_tokens(tokens_with_eof) do
      {:ok, %Script{statements: [single_cmd]}} -> single_cmd
      {:ok, script} -> script
      # Fall back to empty on parse error
      {:error, _, _, _} -> %Script{statements: []}
    end
  end

  # Parse command substitution from raw string (from backticks)
  defp parse_command_subst(content) when is_binary(content) do
    case parse(content) do
      {:ok, %Script{statements: [single_cmd]}} -> single_cmd
      {:ok, script} -> script
      # Fall back to raw string on error
      {:error, _, _, _} -> content
    end
  end

  defp current_token(%{tokens: tokens, pos: pos}) do
    Enum.at(tokens, pos, {:eof, 0, 0})
  end

  defp advance(%{pos: pos} = state) do
    %{state | pos: pos + 1}
  end

  defp current_position(state) do
    case current_token(state) do
      {_, line, col} -> {line, col}
      {_, _, line, col} -> {line, col}
      _ -> {1, 1}
    end
  end

  defp token_position(token) do
    case token do
      {_, line, col} -> {line, col}
      {_, _, line, col} -> {line, col}
      _ -> {1, 1}
    end
  end

  defp get_meta_position(%{meta: %{line: line, column: col}}), do: {line, col}
  defp get_meta_position(_), do: {1, 1}

  defp skip_separators(state) do
    case current_token(state) do
      {:semi, _, _} -> skip_separators(advance(state))
      {:newline, _, _} -> skip_separators(advance(state))
      {:comment, _, _, _} -> skip_separators(advance(state))
      _ -> state
    end
  end

  defp skip_newlines(state) do
    case current_token(state) do
      {:newline, _, _} -> skip_newlines(advance(state))
      {:comment, _, _, _} -> skip_newlines(advance(state))
      _ -> state
    end
  end
end
