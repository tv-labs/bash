defmodule Bash.AST.TestExpression do
  @moduledoc """
  Test expression for [[ ... ]] conditional constructs.

  This represents bash's extended test expression using double bracket notation.
  The expression tokens are passed directly to the test expression builtin for evaluation.

  ## Examples

      # [[ -f file ]]
      %TestExpression{
        expression: ["-f", "file"]
      }

      # [[ $x -eq 5 ]]
      %TestExpression{
        expression: [%Word{...}, "-eq", "5"]
      }

      # [[ -f file1 && -f file2 ]]
      %TestExpression{
        expression: ["-f", "file1", "&&", "-f", "file2"]
      }

  Expressions are composed of the same primaries used
  by the `test` builtin, and may be combined using the following operators:

  - `( EXPRESSION )` - Returns the value of EXPRESSION
  - `! EXPRESSION` - True if EXPRESSION is false; else false
  - `EXPR1 && EXPR2` - True if both EXPR1 and EXPR2 are true; else false
  - `EXPR1 || EXPR2` - True if either EXPR1 or EXPR2 is true; else false

  When the `==` and `!=` operators are used, the string to the right of
  the operator is used as a pattern and pattern matching is performed.
  When the `=~` operator is used, the string to the right of the operator
  is matched as a regular expression.

  The && and || operators do not evaluate EXPR2 if EXPR1 is sufficient to
  determine the expression's value.

  Exit Status:
  0 or 1 depending on value of EXPRESSION.

  Operator precedence: ! > && > ||

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/test.def?h=bash-5.3
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.AST.RegexPattern
  alias Bash.Builtin.Test
  alias Bash.CommandResult
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          expression: [AST.Word.t() | String.t()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    expression: [],
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  # Execute the conditional test expression builtin.
  #
  # Takes a list of arguments and session state, returns a CommandResult
  # with exit code 0 (true) or 1 (false).
  @doc false
  def execute(%__MODULE__{expression: expression}, _stdin, session_state) do
    case Helpers.expand_word_list(expression, session_state) do
      {[], _} ->
        {:ok, %CommandResult{command: "[[", exit_code: 1, error: nil}}

      {args, _} ->
        args
        |> parse_expr(session_state)
        |> build_result()
    end
  end

  # Build CommandResult from parse result
  # With state updates (e.g., BASH_REMATCH from regex matching)
  defp build_result({:ok, result, [], state_updates}) do
    exit_code = if result, do: 0, else: 1
    {:ok, %CommandResult{command: "[[", exit_code: exit_code, error: nil}, state_updates}
  end

  defp build_result({:ok, result, []}) do
    exit_code = if result, do: 0, else: 1
    {:ok, %CommandResult{command: "[[", exit_code: exit_code, error: nil}}
  end

  defp build_result({:ok, _result, remaining, _state_updates}) do
    {:error,
     %CommandResult{
       command: "[[",
       exit_code: 2,
       error: "unexpected arguments: #{inspect(remaining)}"
     }}
  end

  defp build_result({:ok, _result, remaining}) do
    {:error,
     %CommandResult{
       command: "[[",
       exit_code: 2,
       error: "unexpected arguments: #{inspect(remaining)}"
     }}
  end

  defp build_result({:error, reason}) do
    {:error, %CommandResult{command: "[[", exit_code: 2, error: reason}}
  end

  # Operator precedence: || (OR) - lowest precedence with short-circuit evaluation
  defp parse_expr(args, session_state) do
    case parse_and_expr(args, session_state) do
      {:ok, true, ["||" | rest], left_updates} ->
        # Short-circuit: left is true, but still need to consume right side
        case parse_expr(rest, session_state) do
          {:ok, _, remaining} -> {:ok, true, remaining, left_updates}
          {:ok, _, remaining, _} -> {:ok, true, remaining, left_updates}
          error -> error
        end

      {:ok, true, ["||" | rest]} ->
        # Short-circuit: left is true, but still need to consume right side
        case parse_expr(rest, session_state) do
          {:ok, _, remaining} -> {:ok, true, remaining}
          {:ok, _, remaining, _} -> {:ok, true, remaining}
          error -> error
        end

      {:ok, false, ["||" | rest], left_updates} ->
        # Left is false, evaluate right side
        case parse_expr(rest, session_state) do
          {:ok, right_result, remaining} ->
            {:ok, right_result, remaining, left_updates}

          {:ok, right_result, remaining, right_updates} ->
            {:ok, right_result, remaining, merge_updates(left_updates, right_updates)}

          error ->
            error
        end

      {:ok, false, ["||" | rest]} ->
        # Left is false, evaluate right side
        case parse_expr(rest, session_state) do
          {:ok, right_result, remaining} ->
            {:ok, right_result, remaining}

          {:ok, right_result, remaining, right_updates} ->
            {:ok, right_result, remaining, right_updates}

          error ->
            error
        end

      other ->
        other
    end
  end

  # Operator precedence: && (AND) - medium precedence with short-circuit evaluation
  defp parse_and_expr(args, session_state) do
    case parse_unary(args, session_state) do
      {:ok, false, ["&&" | rest], left_updates} ->
        # Short-circuit: left is false, but still need to consume right side
        case parse_and_expr(rest, session_state) do
          {:ok, _, remaining} -> {:ok, false, remaining, left_updates}
          {:ok, _, remaining, _} -> {:ok, false, remaining, left_updates}
          error -> error
        end

      {:ok, false, ["&&" | rest]} ->
        # Short-circuit: left is false, but still need to consume right side
        case parse_and_expr(rest, session_state) do
          {:ok, _, remaining} -> {:ok, false, remaining}
          {:ok, _, remaining, _} -> {:ok, false, remaining}
          error -> error
        end

      {:ok, true, ["&&" | rest], left_updates} ->
        # Left is true, evaluate right side
        case parse_and_expr(rest, session_state) do
          {:ok, right_result, remaining} ->
            {:ok, right_result, remaining, left_updates}

          {:ok, right_result, remaining, right_updates} ->
            {:ok, right_result, remaining, merge_updates(left_updates, right_updates)}

          error ->
            error
        end

      {:ok, true, ["&&" | rest]} ->
        # Left is true, evaluate right side
        case parse_and_expr(rest, session_state) do
          {:ok, right_result, remaining} ->
            {:ok, right_result, remaining}

          {:ok, right_result, remaining, right_updates} ->
            {:ok, right_result, remaining, right_updates}

          error ->
            error
        end

      other ->
        other
    end
  end

  defp merge_updates(left, right) do
    # Merge state updates, with right side taking precedence for conflicts
    Map.merge(left, right, fn _k, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        Map.merge(left_val, right_val)
      else
        right_val
      end
    end)
  end

  # Operator precedence: ! (NOT) - highest precedence
  defp parse_unary(["!" | rest], session_state) do
    case parse_unary(rest, session_state) do
      {:ok, result, remaining} -> {:ok, !result, remaining}
      {:ok, result, remaining, state_updates} -> {:ok, !result, remaining, state_updates}
      error -> error
    end
  end

  defp parse_unary(args, session_state) do
    parse(args, session_state)
  end

  # Primary expressions - binary operators

  # Pattern matching (glob)
  defp parse([left, "==", pattern | rest], _session_state) do
    {:ok, match_pattern?(left, pattern), rest}
  end

  defp parse([left, "!=", pattern | rest], _session_state) do
    {:ok, !match_pattern?(left, pattern), rest}
  end

  # Regex matching with RegexPattern AST node
  defp parse([left, "=~", %RegexPattern{parts: parts} = pattern | rest], session_state) do
    regex_str = RegexPattern.expand(pattern, session_state)

    # Check if pattern is entirely quoted (literal matching) or unquoted (regex)
    if entirely_quoted?(parts) do
      # Quoted patterns are literal string matches, not regex
      # BASH_REMATCH is still set on match
      do_literal_match(left, regex_str, rest)
    else
      do_regex_match(left, regex_str, rest)
    end
  end

  # Regex matching with string (from expand_word_list, already literal)
  defp parse([left, "=~", regex_str | rest], _session_state) when is_binary(regex_str) do
    # String patterns are treated as regex (they come from quoted Word expansion)
    do_regex_match(left, regex_str, rest)
  end

  # String comparisons (exact match)
  defp parse([left, "=", right | rest], _session_state) do
    {:ok, left == right, rest}
  end

  # Lexicographic string comparisons
  defp parse([left, "<", right | rest], _session_state) do
    {:ok, left < right, rest}
  end

  defp parse([left, ">", right | rest], _session_state) do
    {:ok, left > right, rest}
  end

  # Numeric comparisons
  defp parse([left, "-eq", right | rest], _session_state) do
    {:ok, Test.to_integer(left) == Test.to_integer(right), rest}
  end

  defp parse([left, "-ne", right | rest], _session_state) do
    {:ok, Test.to_integer(left) != Test.to_integer(right), rest}
  end

  defp parse([left, "-lt", right | rest], _session_state) do
    {:ok, Test.to_integer(left) < Test.to_integer(right), rest}
  end

  defp parse([left, "-le", right | rest], _session_state) do
    {:ok, Test.to_integer(left) <= Test.to_integer(right), rest}
  end

  defp parse([left, "-gt", right | rest], _session_state) do
    {:ok, Test.to_integer(left) > Test.to_integer(right), rest}
  end

  defp parse([left, "-ge", right | rest], _session_state) do
    {:ok, Test.to_integer(left) >= Test.to_integer(right), rest}
  end

  # File comparisons
  defp parse([file1, "-nt", file2 | rest], session_state) do
    {:ok, Test.file_newer_than?(file1, file2, session_state), rest}
  end

  defp parse([file1, "-ot", file2 | rest], session_state) do
    {:ok, Test.file_older_than?(file1, file2, session_state), rest}
  end

  defp parse([file1, "-ef", file2 | rest], session_state) do
    {:ok, Test.file_same_file?(file1, file2, session_state), rest}
  end

  # Primary expressions - unary operators

  # File type tests
  defp parse(["-f", path | rest], session_state) do
    {:ok, Test.file_regular?(path, session_state), rest}
  end

  defp parse(["-d", path | rest], session_state) do
    {:ok, Test.file_directory?(path, session_state), rest}
  end

  defp parse(["-e", path | rest], session_state) do
    {:ok, Test.file_exists?(path, session_state), rest}
  end

  defp parse(["-a", path | rest], session_state) do
    {:ok, Test.file_exists?(path, session_state), rest}
  end

  defp parse(["-L", path | rest], session_state) do
    {:ok, Test.file_symlink?(path, session_state), rest}
  end

  defp parse(["-h", path | rest], session_state) do
    {:ok, Test.file_symlink?(path, session_state), rest}
  end

  defp parse(["-b", path | rest], session_state) do
    {:ok, Test.file_block_special?(path, session_state), rest}
  end

  defp parse(["-c", path | rest], session_state) do
    {:ok, Test.file_char_special?(path, session_state), rest}
  end

  defp parse(["-p", path | rest], session_state) do
    {:ok, Test.file_named_pipe?(path, session_state), rest}
  end

  defp parse(["-S", path | rest], session_state) do
    {:ok, Test.file_socket?(path, session_state), rest}
  end

  # File permission tests
  defp parse(["-r", path | rest], session_state) do
    {:ok, Test.file_readable?(path, session_state), rest}
  end

  defp parse(["-w", path | rest], session_state) do
    {:ok, Test.file_writable?(path, session_state), rest}
  end

  defp parse(["-x", path | rest], session_state) do
    {:ok, Test.file_executable?(path, session_state), rest}
  end

  # File attribute tests
  defp parse(["-s", path | rest], session_state) do
    {:ok, Test.file_not_empty?(path, session_state), rest}
  end

  defp parse(["-g", path | rest], session_state) do
    {:ok, Test.file_setgid?(path, session_state), rest}
  end

  defp parse(["-k", path | rest], session_state) do
    {:ok, Test.file_sticky_bit?(path, session_state), rest}
  end

  defp parse(["-u", path | rest], session_state) do
    {:ok, Test.file_setuid?(path, session_state), rest}
  end

  defp parse(["-O", path | rest], session_state) do
    {:ok, Test.file_owned_by_user?(path, session_state), rest}
  end

  defp parse(["-G", path | rest], session_state) do
    {:ok, Test.file_owned_by_group?(path, session_state), rest}
  end

  defp parse(["-N", path | rest], session_state) do
    {:ok, Test.file_modified_since_read?(path, session_state), rest}
  end

  defp parse(["-t", fd | rest], _session_state) do
    {:ok, Test.fd_is_terminal?(fd), rest}
  end

  # String tests
  defp parse(["-z", str | rest], _session_state) do
    {:ok, str == "", rest}
  end

  defp parse(["-n", str | rest], _session_state) do
    {:ok, str != "", rest}
  end

  # Variable existence test - [[ -v varname ]]
  # Tests if the variable is set (has been assigned a value)
  defp parse(["-v", varname | rest], session_state) do
    {:ok, variable_is_set?(varname, session_state), rest}
  end

  # Nameref test - [[ -R varname ]]
  # Tests if the variable is a nameref
  defp parse(["-R", varname | rest], session_state) do
    {:ok, variable_is_nameref?(varname, session_state), rest}
  end

  # Unary operator without argument - error
  defp parse([op], _session_state)
       when op in ~w[-f -d -e -a -r -w -x -s -z -n -v -R -b -c -g -h -k -p -t -u -L -O -G -N -S] do
    {:error, "unary operator expected argument"}
  end

  # String alone - true if not empty
  defp parse([str], _session_state) when is_binary(str) do
    {:ok, str != "", []}
  end

  defp parse([str | rest], _session_state) when is_binary(str) do
    {:ok, str != "", rest}
  end

  defp parse([], _session_state) do
    {:error, "too few arguments"}
  end

  # Regex matching helpers

  defp entirely_quoted?(parts) do
    case parts do
      [{:single_quoted, _}] -> true
      [{:double_quoted, _}] -> true
      _ -> false
    end
  end

  defp do_literal_match(left, pattern, rest) do
    if String.contains?(left, pattern) do
      # Match found - BASH_REMATCH[0] = matched portion
      bash_rematch = Variable.new_indexed_array(%{0 => pattern})
      state_updates = %{var_updates: %{"BASH_REMATCH" => bash_rematch}}
      {:ok, true, rest, state_updates}
    else
      # No match - unset BASH_REMATCH
      bash_rematch = Variable.new_indexed_array(%{})
      state_updates = %{var_updates: %{"BASH_REMATCH" => bash_rematch}}
      {:ok, false, rest, state_updates}
    end
  end

  defp do_regex_match(left, regex_str, rest) do
    case Regex.compile(regex_str) do
      {:ok, regex} ->
        case Regex.run(regex, left, capture: :all) do
          nil ->
            # No match - unset BASH_REMATCH (empty array)
            bash_rematch = Variable.new_indexed_array(%{})
            state_updates = %{var_updates: %{"BASH_REMATCH" => bash_rematch}}
            {:ok, false, rest, state_updates}

          captures ->
            # Match found - populate BASH_REMATCH with captures
            bash_rematch = captures_to_bash_rematch(captures)
            state_updates = %{var_updates: %{"BASH_REMATCH" => bash_rematch}}
            {:ok, true, rest, state_updates}
        end

      {:error, {reason, _}} ->
        {:error, "invalid regex: #{regex_str} (#{reason})"}

      {:error, reason} ->
        {:error, "invalid regex: #{regex_str} (#{inspect(reason)})"}
    end
  end

  defp captures_to_bash_rematch(captures) do
    # BASH_REMATCH[0] = entire match, [1..n] = capture groups
    values =
      captures
      |> Enum.with_index()
      |> Map.new(fn {value, index} -> {index, value} end)

    Variable.new_indexed_array(values)
  end

  # Pattern matching helper - convert glob pattern to regex
  defp match_pattern?(string, pattern) do
    # Convert bash glob pattern to Elixir regex
    # Strategy: replace glob wildcards with placeholders, escape, then restore
    regex_pattern =
      pattern
      |> String.replace("*", "\x00STAR\x00")
      |> String.replace("?", "\x00QUESTION\x00")
      |> Regex.escape()
      |> String.replace("\x00STAR\x00", ".*")
      |> String.replace("\x00QUESTION\x00", ".")

    case Regex.compile("^#{regex_pattern}$") do
      {:ok, regex} -> Regex.match?(regex, string)
      {:error, _} -> false
    end
  end

  # Check if a variable is set (has been assigned a value)
  # Supports array subscripts: arr[0], arr[@], arr[*]
  defp variable_is_set?(varname, session_state) do
    # Handle array subscript syntax: VAR[idx]
    {base_name, subscript} = parse_subscript(varname)

    case Map.get(session_state.variables, base_name) do
      nil ->
        false

      %Variable{} = var ->
        case subscript do
          nil ->
            # No subscript - variable is set if it has a value
            Variable.get(var, nil) != nil

          {:index, idx} ->
            # Specific index - check if that index exists
            case Variable.get(var, idx) do
              nil -> false
              _ -> true
            end

          :all ->
            # [@] or [*] - true if array is not empty
            case var.value do
              %{} = map when map_size(map) > 0 -> true
              _ -> false
            end
        end
    end
  end

  # Check if a variable is a nameref
  defp variable_is_nameref?(varname, session_state) do
    case Map.get(session_state.variables, varname) do
      %Variable{attributes: attrs} -> Map.get(attrs, :nameref, false)
      _ -> false
    end
  end

  # Parse array subscript from variable name
  defp parse_subscript(varname) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\[(.+)\]$/, varname) do
      [_, base, "@"] -> {base, :all}
      [_, base, "*"] -> {base, :all}
      [_, base, idx] -> {base, {:index, idx}}
      nil -> {varname, nil}
    end
  end

  defimpl String.Chars do
    def to_string(%{expression: expression}) do
      expr_str = Enum.map_join(expression, " ", &Kernel.to_string/1)
      "[[ #{expr_str} ]]"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{exit_code: exit_code}, opts) do
      base = "#TestExpr{}"

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
