defmodule Bash.Validator do
  @moduledoc """
  Validates parsed Bash ASTs for structural errors.

  This module detects cases where the parser incorrectly parsed invalid Bash
  as valid commands. For example, `{ echo hello` (missing closing brace) gets
  parsed as a command named `{` with arguments `echo` and `hello`.

  Error codes follow ShellCheck conventions where applicable.

  ## Example

      iex> {:ok, ast} = Bash.Parser.parse("{ echo hello")
      iex> Bash.Validator.validate(ast, "{ echo hello")
      {:error, %SyntaxError{code: "SC1056", hint: "'{' starts a command group - missing '}'"}}
  """

  alias Bash.AST
  alias Bash.SyntaxError

  # Shell metacharacters that indicate unclosed structures when parsed as commands
  @structure_errors %{
    "{" => {"SC1056", "'{' starts a command group - missing '}'"},
    "}" => {"SC1057", "unexpected '}' - no matching '{'"}
  }

  # Control flow keywords that shouldn't appear as command names
  # When these are parsed as commands, it indicates structural errors
  @control_flow_errors %{
    "if" => {"SC1046", "'if' without matching 'fi'"},
    "then" => {"SC1047", "'then' outside of if/elif block"},
    "else" => {"SC1048", "'else' outside of if block"},
    "elif" => {"SC1049", "'elif' outside of if block"},
    "fi" => {"SC1050", "'fi' without matching 'if'"},
    "while" => {"SC1061", "'while' without matching 'done'"},
    "until" => {"SC1061", "'until' without matching 'done'"},
    "for" => {"SC1061", "'for' without matching 'done'"},
    "do" => {"SC1062", "'do' outside of loop context"},
    "done" => {"SC1063", "'done' without matching 'do'"},
    "case" => {"SC1058", "'case' without matching 'esac'"},
    "esac" => {"SC1059", "'esac' without matching 'case'"},
    "in" => {"SC1060", "'in' outside of case/for statement"}
  }

  @doc """
  Validate a parsed Bash script AST.

  Returns `:ok` if valid, or `{:error, %SyntaxError{}}` if structural issues are found.

  ## Parameters

    * `script` - The parsed `%Bash.Script{}` struct
    * `source` - The original source string (used for error messages)

  ## Examples

      iex> {:ok, ast} = Parser.parse("echo hello")
      iex> Validator.validate(ast, "echo hello")
      :ok

      iex> {:ok, ast} = Parser.parse("{ echo hello")
      iex> {:error, %SyntaxError{}} = Validator.validate(ast, "{ echo hello")
  """
  @spec validate(Bash.Script.t(), String.t()) :: :ok | {:error, SyntaxError.t()}
  def validate(%Bash.Script{} = script, source) do
    case find_errors(script.statements, source, []) do
      [] -> :ok
      [error | _] -> {:error, error}
    end
  end

  @doc """
  Returns all validation errors found in the script.

  Unlike `validate/2`, this returns all errors, not just the first one.
  """
  @spec validate_all(Bash.Script.t(), String.t()) ::
          {:ok, []} | {:error, [SyntaxError.t()]}
  def validate_all(%Bash.Script{} = script, source) do
    case find_errors(script.statements, source, []) do
      [] -> {:ok, []}
      errors -> {:error, errors}
    end
  end

  # Recursively find errors in statements
  defp find_errors([], _source, acc), do: Enum.reverse(acc)

  defp find_errors([{:separator, _} | rest], source, acc) do
    find_errors(rest, source, acc)
  end

  defp find_errors([stmt | rest], source, acc) do
    errors = check_statement(stmt, source)
    find_errors(rest, source, errors ++ acc)
  end

  # Check a single statement for structural errors
  defp check_statement(%AST.Command{name: %AST.Word{parts: [{:literal, name}]}} = cmd, source) do
    check_command_name(name, cmd.meta, source)
  end

  # Check nested statements in compound commands
  defp check_statement(%AST.Compound{statements: statements}, source) do
    find_errors(statements, source, [])
  end

  # Check nested statements in pipelines
  defp check_statement(%AST.Pipeline{commands: commands}, source) do
    Enum.flat_map(commands, &check_statement(&1, source))
  end

  # Check nested statements in if/while/for/case
  defp check_statement(
         %AST.If{body: body, elif_clauses: elif_clauses, else_body: else_body},
         source
       ) do
    body_errors = find_errors(body, source, [])

    elif_errors =
      Enum.flat_map(elif_clauses, fn {_cond, elif_body} ->
        find_errors(elif_body, source, [])
      end)

    else_errors = if else_body, do: find_errors(else_body, source, []), else: []

    body_errors ++ elif_errors ++ else_errors
  end

  defp check_statement(%AST.WhileLoop{body: body}, source) do
    find_errors(body, source, [])
  end

  defp check_statement(%AST.ForLoop{body: body}, source) do
    find_errors(body, source, [])
  end

  defp check_statement(%AST.Case{cases: cases}, source) do
    Enum.flat_map(cases, fn {_patterns, case_body} ->
      find_errors(case_body, source, [])
    end)
  end

  # Default case - no errors
  defp check_statement(_stmt, _source), do: []

  # Check if command name is a structural character or control flow keyword
  defp check_command_name(name, meta, source) do
    cond do
      Map.has_key?(@structure_errors, name) ->
        {code, hint} = @structure_errors[name]
        [SyntaxError.from_validation(source, code, hint, meta)]

      Map.has_key?(@control_flow_errors, name) ->
        {code, hint} = @control_flow_errors[name]
        [SyntaxError.from_validation(source, code, hint, meta)]

      true ->
        []
    end
  end
end
