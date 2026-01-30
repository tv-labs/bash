defmodule Bash.Arithmetic do
  @moduledoc """
  Evaluates bash arithmetic expressions.

  Supports the full range of bash arithmetic operators:
  - Arithmetic: `+ - * / % **`
  - Comparison: `< > <= >= == !=`
  - Logical: `&& || !`
  - Bitwise: `& | ^ ~ << >>`
  - Assignment: `= += -= *= /= %= <<= >>= &= ^= |=`
  - Increment/decrement: `++ --`
  - Ternary: `?:`
  - Parentheses for grouping

  Variable references work without $ prefix (e.g., `x + 1` where x is a variable).

  ## Examples

      iex> Arithmetic.evaluate("1 + 2", %{})
      {:ok, 3, %{}}

      iex> Arithmetic.evaluate("x + 1", %{"x" => "5"})
      {:ok, 6, %{"x" => "5"}}

      iex> Arithmetic.evaluate("x = 5", %{})
      {:ok, 5, %{"x" => "5"}}

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/let.def?h=bash-5.3
  """

  alias Bash.AST
  alias Bash.Parser.Arithmetic, as: ArithmeticParser

  # Evaluate an arithmetic expression string.
  #
  # Returns `{:ok, result, updated_env}` on success, or `{:error, reason}` on failure.
  # The result is an integer, and updated_env contains any variables modified by assignments.
  #
  # This is the entry point for string-based arithmetic evaluation.
  # It parses (using NimbleParsec) and evaluates the expression.
  @doc false
  def evaluate(expr_string, env_vars) when is_binary(expr_string) and is_map(env_vars) do
    with {:ok, ast} <- ArithmeticParser.parse(expr_string),
         {:ok, result, new_env} <- AST.Arithmetic.execute(ast, env_vars) do
      {:ok, result, new_env}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
