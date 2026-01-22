defmodule Bash.SyntaxError do
  @moduledoc """
  Exception raised when bash script parsing or validation fails.

  Error codes follow ShellCheck conventions where applicable:
  - `SC1xxx`: Syntax errors (parser-level)
  - `SC2xxx`: Semantic warnings (future)

  ## Example

      iex> raise Bash.SyntaxError,
      ...>   code: "SC1046",
      ...>   line: 1,
      ...>   column: 0,
      ...>   script: "if true; then echo",
      ...>   hint: "'if' without matching 'fi'"

  Produces:

      ** (Bash.SyntaxError) [SC1046] Bash syntax error at line 1, column 0:

          if true; then echo
          ^

        hint: 'if' without matching 'fi'

  Reference: https://www.shellcheck.net/wiki/
  """

  defexception [:message, :code, :line, :column, :script, :hint]

  @type t :: %__MODULE__{
          __exception__: true,
          message: String.t() | nil,
          code: String.t() | nil,
          line: pos_integer() | nil,
          column: non_neg_integer() | nil,
          script: String.t() | nil,
          hint: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{code: code, script: script, line: line, column: col, hint: hint}) do
    lines = String.split(script, "\n")
    script_line = Enum.at(lines, line - 1, "")
    line_len = String.length(script_line)

    # Clamp column to valid range for pointer
    safe_col = min(col, line_len)
    pointer = String.duplicate(" ", safe_col + 4) <> "^"

    # Build context with line numbers
    context = build_context(lines, line)

    """
    [#{code}] Bash syntax error at line #{line}:

    #{context}
    #{pointer}

      hint: #{hint}\
    """
  end

  # Build context showing the error line and optionally surrounding lines
  defp build_context(lines, error_line) do
    total_lines = length(lines)
    line_num_width = total_lines |> Integer.to_string() |> String.length()

    # Show up to 2 lines before and the error line
    start_line = max(1, error_line - 2)
    end_line = error_line

    start_line..end_line
    |> Enum.map(fn n ->
      line_content = Enum.at(lines, n - 1, "")
      marker = if n == error_line, do: ">", else: " "
      line_num = n |> Integer.to_string() |> String.pad_leading(line_num_width)
      "#{marker} #{line_num} | #{line_content}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Build a SyntaxError from a parser failure.

  ## Examples

      iex> SyntaxError.from_parse_error("echo \\"hello", "expected end of string")
      %SyntaxError{code: "SC1009", hint: "unclosed quote or expression", ...}
  """
  @spec from_parse_error(String.t(), String.t(), pos_integer(), non_neg_integer()) ::
          %__MODULE__{}
  def from_parse_error(script, reason, line \\ 1, column \\ 0) do
    {code, hint} = translate_parse_error(reason)

    error = %__MODULE__{
      code: code,
      line: line,
      column: column,
      script: script,
      hint: hint
    }

    %{error | message: message(error)}
  end

  @doc """
  Build a SyntaxError from validator results.
  """
  @spec from_validation(String.t(), String.t(), String.t(), map() | nil) :: %__MODULE__{}
  def from_validation(script, code, hint, meta \\ nil) do
    {line, column} = extract_position(meta)

    error = %__MODULE__{
      code: code,
      line: line,
      column: column,
      script: script,
      hint: hint
    }

    %{error | message: message(error)}
  end

  defp extract_position(nil), do: {1, 0}
  defp extract_position(%{line: line, column: col}), do: {line || 1, col || 0}
  defp extract_position(_), do: {1, 0}

  # Translate error messages to {code, hint} tuples
  # New format: messages prefixed with (SCxxxx) - just extract the code
  # Legacy format: pattern-match on message content for parser errors
  defp translate_parse_error(msg) when is_binary(msg) do
    # Check for new (SCxxxx) prefix format first
    case Regex.run(~r/^\(SC(\d+)\)\s*(.*)$/s, msg) do
      [_, code_num, hint] ->
        {"SC#{code_num}", String.trim(hint)}

      nil ->
        # Fall back to legacy pattern matching for parser errors
        translate_legacy_error(msg)
    end
  end

  defp translate_parse_error(other) do
    {"SC1000", inspect(other)}
  end

  # Legacy error translation for parser errors that don't use the new prefix format
  defp translate_legacy_error("expected end of string") do
    {"SC1009", "unclosed quote or expression"}
  end

  defp translate_legacy_error(msg) when byte_size(msg) > 200 do
    {"SC1000", "syntax error - unexpected token or incomplete statement"}
  end

  defp translate_legacy_error(msg) do
    cond do
      # Control flow errors
      String.contains?(msg, "'if' without matching") or
          String.contains?(msg, "expected 'elif', 'else', or 'fi'") ->
        {"SC1046", msg}

      String.contains?(msg, "'then' outside of if") ->
        {"SC1047", msg}

      String.contains?(msg, "'else' outside of if") ->
        {"SC1048", msg}

      String.contains?(msg, "'elif' outside of if") ->
        {"SC1049", msg}

      String.contains?(msg, "'fi' without matching") ->
        {"SC1050", msg}

      String.contains?(msg, "'while' without matching") or
        String.contains?(msg, "'for' without matching") or
        String.contains?(msg, "'until' without matching") or
          String.contains?(msg, "expected 'done' to close") ->
        {"SC1061", msg}

      String.contains?(msg, "'do' outside of loop") ->
        {"SC1062", msg}

      String.contains?(msg, "'done' without matching") ->
        {"SC1063", msg}

      String.contains?(msg, "'case' without matching") or
          String.contains?(msg, "expected 'esac'") ->
        {"SC1058", msg}

      String.contains?(msg, "'esac' without matching") ->
        {"SC1059", msg}

      String.contains?(msg, "'in' outside of") ->
        {"SC1060", msg}

      # Structural errors
      String.contains?(msg, "'{' starts a command group") or
          String.contains?(msg, "expected '}' to close") ->
        {"SC1056", msg}

      String.contains?(msg, "unexpected '}'") ->
        {"SC1057", msg}

      # Quote-related errors
      String.contains?(msg, "unclosed double quote") ->
        {"SC1009", "unclosed double quote"}

      String.contains?(msg, "unclosed single quote") ->
        {"SC1003", "unclosed single quote"}

      String.contains?(msg, "$(") ->
        {"SC1081", "unclosed command substitution"}

      String.contains?(msg, "$((") ->
        {"SC1102", "unclosed arithmetic expansion"}

      true ->
        {"SC1000", msg}
    end
  end
end
