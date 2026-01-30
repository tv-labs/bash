defmodule Bash.Builtin.Let do
  @moduledoc """
  `let arg [arg ...]`
  `(( expression ))`

  Evaluate arithmetic expressions.

  Each ARG is an arithmetic expression to be evaluated. Evaluation is done in
  fixed-width integers with no check for overflow, though division by 0 is
  trapped and flagged as an error.

  Operator precedence (highest to lowest):
    id++, id--        variable post-increment, post-decrement
    ++id, --id        variable pre-increment, pre-decrement
    -, +              unary minus, plus
    !, ~              logical and bitwise negation
    **                exponentiation
    *, /, %           multiplication, division, remainder
    +, -              addition, subtraction
    <<, >>            left and right bitwise shifts
    <=, >=, <, >      comparison
    ==, !=            equality, inequality
    &                 bitwise AND
    ^                 bitwise exclusive OR
    |                 bitwise OR
    &&                logical AND
    ||                logical OR
    expr ? expr : expr
                      conditional operator
    =, *=, /=, %=,
    +=, -=, <<=, >>=,
    &=, ^=, |=        assignment

  Shell variables are allowed as operands. Variable names are replaced by
  their values (coerced to integers). No $ prefix is needed.

  Exit Status:
  If the last ARG evaluates to 0, let returns 1; let returns 0 otherwise.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/let.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Arithmetic
  alias Bash.Variable

  defbash execute(args, state) do
    case args do
      [] ->
        error("let: expression expected")
        {:ok, 1}

      _ ->
        # Evaluate each argument as an arithmetic expression
        # Return the result of the last expression
        case evaluate_expressions(args, state) do
          {:ok, result, updated_state} ->
            # Inverted exit code: 0 if result is nonzero, 1 if result is zero
            exit_code = if result == 0, do: 1, else: 0

            # Calculate var_updates (variables that changed) - convert to Variable structs
            var_updates =
              updated_state.variables
              |> Enum.filter(fn {k, v} ->
                case Map.get(state.variables, k) do
                  nil -> true
                  %Variable{} = old_var -> Variable.get(old_var, nil) != Variable.get(v, nil)
                end
              end)
              |> Map.new()

            update_state(variables: var_updates)
            {:ok, exit_code}

          {:error, reason} ->
            error("let: #{reason}")
            {:ok, 2}
        end
    end
  end

  defp evaluate_expressions(args, session_state) do
    Enum.reduce_while(args, {:ok, 0, session_state}, fn expr, {:ok, _result, state} ->
      case evaluate_single_expression(expr, state) do
        {:ok, new_result, new_state} ->
          {:cont, {:ok, new_result, new_state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_single_expression(expr_string, session_state) do
    # Convert Variables to plain string map for arithmetic evaluator
    env_vars =
      Map.new(session_state.variables, fn {k, v} ->
        {k, Variable.get(v, nil)}
      end)

    with {:ok, result, new_env} <- Arithmetic.evaluate(expr_string, env_vars) do
      # Convert updated env back to Variables
      new_variables =
        Map.new(new_env, fn {k, v} ->
          {k, Variable.new(v)}
        end)

      new_state = %{session_state | variables: new_variables}
      {:ok, result, new_state}
    end
  end
end
