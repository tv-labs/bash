defmodule Bash.AST.Case do
  @moduledoc """
  Case statement: pattern matching.

  ## Examples

      # case $var in
      #   pattern1) commands1 ;;
      #   pattern2|pattern3) commands2 ;;
      #   *) default ;;
      # esac
      %Case{
        word: %Word{parts: [{:variable, "var"}]},
        cases: [
          {[%Word{parts: [{:literal, "pattern1"}]}], [...]},
          {[%Word{parts: [{:literal, "pattern2"}]},
            %Word{parts: [{:literal, "pattern3"}]}
          ], [...]},
          {[%Word{parts: [{:literal, "*"}]}], [...]}
        ]
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.CommandResult
  alias Bash.Statement

  @type terminator :: :break | :fallthrough | :continue_matching
  @type case_clause :: {patterns :: [AST.Word.t()], body :: [Statement.t()], terminator()}

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          word: AST.Word.t(),
          cases: [case_clause()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map(),
          matched_pattern_index: non_neg_integer() | nil
        }

  defstruct [
    :meta,
    :word,
    cases: [],
    # Execution results
    exit_code: nil,
    state_updates: %{},
    matched_pattern_index: nil
  ]

  def execute(%__MODULE__{word: word, cases: cases}, _stdin, session_state) do
    execute_case_clauses(
      cases,
      Helpers.word_to_string(word, session_state),
      session_state,
      %{}
    )
  end

  defp execute_case_clauses([], _match_value, _session_state, variables) do
    # No matching clause found - return success with exit code 0
    {:ok, %CommandResult{exit_code: 0}, %{variables: variables}}
  end

  # Handle 3-tuple format with terminator
  defp execute_case_clauses(
         [{patterns, body, terminator} | rest],
         match_value,
         session_state,
         variables
       ) do
    if Enum.any?(patterns, &Helpers.pattern_matches?(&1, match_value, session_state)) do
      execute_matched_clause(body, terminator, rest, match_value, session_state, variables)
    else
      # Pattern doesn't match - try next clause
      execute_case_clauses(rest, match_value, session_state, variables)
    end
  end

  # Handle legacy 2-tuple format (for backwards compatibility)
  defp execute_case_clauses([{patterns, body} | rest], match_value, session_state, variables) do
    execute_case_clauses(
      [{patterns, body, :break} | rest],
      match_value,
      session_state,
      variables
    )
  end

  # Execute a matched clause and handle terminator behavior
  defp execute_matched_clause(body, terminator, rest, match_value, session_state, variables) do
    case Helpers.execute_body(body, session_state, variables) do
      {:ok, result, updates} ->
        new_env = Map.get(updates, :variables, variables)

        case terminator do
          :break ->
            {:ok, result, %{variables: new_env}}

          :fallthrough ->
            case rest do
              [] ->
                {:ok, result, %{variables: new_env}}

              [{_patterns, next_body, next_terminator} | next_rest] ->
                execute_matched_clause(
                  next_body,
                  next_terminator,
                  next_rest,
                  match_value,
                  session_state,
                  new_env
                )

              [{_patterns, next_body} | next_rest] ->
                execute_matched_clause(
                  next_body,
                  :break,
                  next_rest,
                  match_value,
                  session_state,
                  new_env
                )
            end

          :continue_matching ->
            case rest do
              [] ->
                {:ok, result, %{variables: new_env}}

              _ ->
                execute_case_clauses(rest, match_value, session_state, new_env)
            end
        end

      error ->
        error
    end
  end

  alias Bash.AST.Formatter

  # Convert to Bash string with formatting context.
  @doc false
  def to_bash(%__MODULE__{word: word, cases: cases}, %Formatter{} = fmt) do
    indent = Formatter.current_indent(fmt)
    pattern_fmt = Formatter.indent(fmt)
    body_fmt = Formatter.indent(pattern_fmt)
    pattern_indent = Formatter.current_indent(pattern_fmt)
    body_indent = Formatter.current_indent(body_fmt)

    cases_str =
      Enum.map_join(cases, "\n", fn clause ->
        {patterns, body, terminator} = normalize_clause(clause)
        patterns_str = Enum.map_join(patterns, "|", &Kernel.to_string/1)
        body_str = Formatter.serialize_body(body, body_fmt)
        term_str = terminator_to_string(terminator)
        "#{pattern_indent}#{patterns_str})\n#{body_str}\n#{body_indent}#{term_str}"
      end)

    "case #{word} in\n#{cases_str}\n#{indent}esac"
  end

  # Normalize 2-tuple to 3-tuple format
  defp normalize_clause({patterns, body, terminator}), do: {patterns, body, terminator}
  defp normalize_clause({patterns, body}), do: {patterns, body, :break}

  defp terminator_to_string(:break), do: ";;"
  defp terminator_to_string(:fallthrough), do: ";&"
  defp terminator_to_string(:continue_matching), do: ";;&"

  defimpl String.Chars do
    alias Bash.AST.Formatter

    def to_string(%Bash.AST.Case{} = case_stmt) do
      Bash.AST.Case.to_bash(case_stmt, Formatter.new())
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{cases: cases, exit_code: exit_code}, opts) do
      case_count = length(cases)
      base = concat(["#Case{", color("#{case_count}", :number, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
