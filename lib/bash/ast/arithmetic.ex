defmodule Bash.AST.Arithmetic do
  @moduledoc """
  Arithmetic expression for (( ... )) constructs.

  ## Examples

      # (( x = 5 ))
      %Arithmetic{
        operator: :assign,
        operands: [
          {:var, "x"},
          {:literal, 5}
        ]
      }

      # (( x + 5 ))
      %Arithmetic{
        operator: :add,
        operands: [
          {:var, "x"},
          {:literal, 5}
        ]
      }

      # (( x > 5 ))
      %Arithmetic{
        operator: :gt,
        operands: [
          {:var, "x"},
          {:literal, 5}
        ]
      }

      # (( x++ ))
      %Arithmetic{
        operator: :post_increment,
        operands: [{:var, "x"}]
      }

      # (( (x + y) * z ))
      %Arithmetic{
        operator: :mul,
        operands: [
          %Arithmetic{operator: :add, operands: [{:var, "x"}, {:var, "y"}]},
          {:var, "z"}
        ]
      }
  """

  # Assignment
  @type operator ::
          :assign
          | :add_assign
          | :sub_assign
          | :mul_assign
          | :div_assign
          | :mod_assign
          # Arithmetic
          | :add
          | :sub
          | :mul
          | :div
          | :mod
          | :pow
          # Increment/Decrement
          | :pre_increment
          | :post_increment
          | :pre_decrement
          | :post_decrement
          # Comparison
          | :eq
          | :ne
          | :lt
          | :le
          | :gt
          | :ge
          # Logical
          | :and
          | :or
          | :not
          # Bitwise
          | :bit_and
          | :bit_or
          | :bit_xor
          | :bit_not
          | :left_shift
          | :right_shift
          # Ternary
          | :ternary

  @type operand :: {:var, String.t()} | {:literal, integer()} | t()

  @type t :: %__MODULE__{
          meta: Bash.AST.Meta.t(),
          operator: operator(),
          operands: [operand()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :operator,
    :operands,
    # Raw expression string (for ((...)) commands that haven't been fully parsed)
    expression: nil,
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  alias Bash.{Arithmetic, CommandResult}

  @doc """
  Execute an arithmetic expression as a command.

  This is the interface used by the Executor. In bash, `(( expr ))` evaluates
  the expression and returns exit code 0 if the result is non-zero (true),
  or exit code 1 if the result is zero (false).

  ## Examples

      # (( 5 > 3 )) returns exit code 0 (true)
      # (( 3 > 5 )) returns exit code 1 (false)
  """
  def execute(%__MODULE__{expression: expression}, _stdin, session_state)
      when is_binary(expression) do
    # Build environment map from session variables
    env = build_env(session_state.variables)

    # Add positional parameters ($1, $2, etc.)
    positional_params = Map.get(session_state, :positional_params, [])

    env_with_positional =
      positional_params
      |> Enum.with_index(1)
      |> Enum.reduce(env, fn {value, idx}, acc ->
        Map.put(acc, Integer.to_string(idx), value)
      end)

    # Expand $variable references in the expression before evaluation
    expanded_expr = expand_arith_variables(expression, env_with_positional)

    case Arithmetic.evaluate(expanded_expr, env_with_positional) do
      {:ok, result, new_env} ->
        # In bash, (( expr )) returns 0 if result != 0, else 1
        exit_code = if result == 0, do: 1, else: 0
        env_updates = build_env_updates(new_env, env)

        command_result = %CommandResult{
          command: "(( #{expression} ))",
          exit_code: exit_code
        }

        if map_size(env_updates) > 0 do
          {:ok, command_result, %{env_updates: env_updates}}
        else
          {:ok, command_result}
        end

      {:error, reason} ->
        {:error,
         %CommandResult{
           command: "(( #{expression} ))",
           exit_code: 1,
           error: reason
         }}
    end
  end

  defp build_env(variables) do
    variables
    |> Enum.filter(fn {_name, %{value: value}} -> is_binary(value) or is_integer(value) end)
    |> Map.new(fn {name, %{value: value}} ->
      # Convert to string for arithmetic evaluator
      {name, to_string(value)}
    end)
  end

  defp build_env_updates(new_env, old_env) do
    new_env
    |> Enum.filter(fn {k, v} -> Map.get(old_env, k) != v end)
    |> Map.new()
  end

  # Expand $variable references in arithmetic expressions
  # Handles: $1, $var, ${var}
  defp expand_arith_variables(expr, vars) do
    Regex.replace(
      ~r/\$\{([^}]+)\}|\$([0-9]+)|\$([A-Za-z_][A-Za-z0-9_]*)/,
      expr,
      fn
        _full, var_name, "", "" -> Map.get(vars, var_name, "0")
        _full, "", digits, "" -> Map.get(vars, digits, "0")
        _full, "", "", var_name -> Map.get(vars, var_name, "0")
        full, _, _, _ -> full
      end
    )
  end

  @doc """
  Execute (evaluate) an arithmetic AST node.

  Takes an AST node (from the Arithmetic parser) and an environment map.
  Returns `{:ok, result, updated_env}` or `{:error, reason}`.

  The AST format matches what Arithmetic produces:
  - `{:number, n}` - integer literal
  - `{:var, name}` - variable reference
  - `{:binop, op, left, right}` - binary operation
  - `{:unop, op, expr}` - unary operation
  - `{:assign, op, var, expr}` - assignment
  - `{:ternary, cond, true_expr, false_expr}` - ternary operator
  - `{:pre_inc, name}` / `{:pre_dec, name}` - pre-increment/decrement
  - `{:post_inc, var}` / `{:post_dec, var}` - post-increment/decrement
  """
  def execute(ast, env) do
    case eval(ast, env) do
      {:ok, result, new_env} -> {:ok, to_int(result), new_env}
      error -> error
    end
  end

  defp eval({:number, n}, env), do: {:ok, n, env}

  defp eval({:var, name}, env) do
    value = Map.get(env, name, "0")
    {:ok, to_int(value), env}
  end

  defp eval({:binop, op, left, right}, env) do
    with {:ok, l_val, env2} <- eval(left, env),
         {:ok, r_val, env3} <- eval(right, env2) do
      result =
        case op do
          "+" -> l_val + r_val
          "-" -> l_val - r_val
          "*" -> l_val * r_val
          "/" when r_val != 0 -> div(l_val, r_val)
          "/" -> raise "Division by zero"
          "%" when r_val != 0 -> rem(l_val, r_val)
          "%" -> raise "Division by zero"
          "**" -> l_val |> :math.pow(r_val) |> trunc()
          "<<" -> Bitwise.bsl(l_val, r_val)
          ">>" -> Bitwise.bsr(l_val, r_val)
          "<" -> if l_val < r_val, do: 1, else: 0
          ">" -> if l_val > r_val, do: 1, else: 0
          "<=" -> if l_val <= r_val, do: 1, else: 0
          ">=" -> if l_val >= r_val, do: 1, else: 0
          "==" -> if l_val == r_val, do: 1, else: 0
          "!=" -> if l_val == r_val, do: 0, else: 1
          "&" -> Bitwise.band(l_val, r_val)
          "|" -> Bitwise.bor(l_val, r_val)
          "^" -> Bitwise.bxor(l_val, r_val)
          "&&" -> if l_val != 0 and r_val != 0, do: 1, else: 0
          "||" -> if l_val != 0 or r_val != 0, do: 1, else: 0
        end

      {:ok, result, env3}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp eval({:unop, op, expr}, env) do
    with {:ok, val, env2} <- eval(expr, env) do
      result =
        case op do
          "+" -> val
          "-" -> -val
          "!" -> if val == 0, do: 1, else: 0
          "~" -> Bitwise.bnot(val)
        end

      {:ok, result, env2}
    end
  end

  defp eval({:ternary, cond_expr, true_expr, false_expr}, env) do
    with {:ok, cond_val, env2} <- eval(cond_expr, env) do
      if cond_val == 0 do
        eval(false_expr, env2)
      else
        eval(true_expr, env2)
      end
    end
  end

  defp eval({:assign, "=", {:var, name}, right}, env) do
    with {:ok, val, env2} <- eval(right, env) do
      {:ok, val, Map.put(env2, name, Integer.to_string(val))}
    end
  end

  defp eval({:assign, op, {:var, name}, right}, env) do
    with {:ok, left_val, env2} <- eval({:var, name}, env),
         {:ok, right_val, env3} <- eval(right, env2) do
      result =
        case op do
          "+=" -> left_val + right_val
          "-=" -> left_val - right_val
          "*=" -> left_val * right_val
          "/=" when right_val != 0 -> div(left_val, right_val)
          "%=" when right_val != 0 -> rem(left_val, right_val)
          "<<=" -> Bitwise.bsl(left_val, right_val)
          ">>=" -> Bitwise.bsr(left_val, right_val)
          "&=" -> Bitwise.band(left_val, right_val)
          "^=" -> Bitwise.bxor(left_val, right_val)
          "|=" -> Bitwise.bor(left_val, right_val)
          _ -> raise "Unsupported compound assignment: #{op}"
        end

      {:ok, result, Map.put(env3, name, Integer.to_string(result))}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp eval({:pre_inc, name}, env) do
    with {:ok, val, env2} <- eval({:var, name}, env) do
      new_val = val + 1
      {:ok, new_val, Map.put(env2, name, Integer.to_string(new_val))}
    end
  end

  defp eval({:pre_dec, name}, env) do
    with {:ok, val, env2} <- eval({:var, name}, env) do
      new_val = val - 1
      {:ok, new_val, Map.put(env2, name, Integer.to_string(new_val))}
    end
  end

  defp eval({:post_inc, {:var, name}}, env) do
    with {:ok, val, env2} <- eval({:var, name}, env) do
      new_val = val + 1
      {:ok, val, Map.put(env2, name, Integer.to_string(new_val))}
    end
  end

  defp eval({:post_dec, {:var, name}}, env) do
    with {:ok, val, env2} <- eval({:var, name}, env) do
      new_val = val - 1
      {:ok, val, Map.put(env2, name, Integer.to_string(new_val))}
    end
  end

  # Comma operator: evaluate each expression in order, return last result
  defp eval({:comma, exprs}, env) when is_list(exprs) do
    Enum.reduce_while(exprs, {:ok, 0, env}, fn expr, {:ok, _val, acc_env} ->
      case eval(expr, acc_env) do
        {:ok, result, new_env} -> {:cont, {:ok, result, new_env}}
        error -> {:halt, error}
      end
    end)
  end

  defp eval(ast, _env), do: {:error, "Invalid AST node: #{inspect(ast)}"}

  defp to_int(val) when is_integer(val), do: val

  defp to_int(val) when is_binary(val) do
    # Trim whitespace before parsing (bash allows leading/trailing whitespace)
    case Integer.parse(String.trim(val)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defimpl String.Chars do
    def to_string(%{expression: expr}) when is_binary(expr) do
      "(( #{expr} ))"
    end

    def to_string(%{expression: expr}) do
      "(( #{serialize_expr(expr)} ))"
    end

    defp serialize_expr({:var, name}), do: name
    defp serialize_expr({:literal, n}), do: Kernel.to_string(n)

    defp serialize_expr({:add, left, right}),
      do: "#{serialize_expr(left)} + #{serialize_expr(right)}"

    defp serialize_expr({:sub, left, right}),
      do: "#{serialize_expr(left)} - #{serialize_expr(right)}"

    defp serialize_expr({:mul, left, right}),
      do: "#{serialize_expr(left)} * #{serialize_expr(right)}"

    defp serialize_expr({:div, left, right}),
      do: "#{serialize_expr(left)} / #{serialize_expr(right)}"

    defp serialize_expr({:mod, left, right}),
      do: "#{serialize_expr(left)} % #{serialize_expr(right)}"

    defp serialize_expr({:pow, left, right}),
      do: "#{serialize_expr(left)} ** #{serialize_expr(right)}"

    defp serialize_expr({:eq, left, right}),
      do: "#{serialize_expr(left)} == #{serialize_expr(right)}"

    defp serialize_expr({:ne, left, right}),
      do: "#{serialize_expr(left)} != #{serialize_expr(right)}"

    defp serialize_expr({:lt, left, right}),
      do: "#{serialize_expr(left)} < #{serialize_expr(right)}"

    defp serialize_expr({:le, left, right}),
      do: "#{serialize_expr(left)} <= #{serialize_expr(right)}"

    defp serialize_expr({:gt, left, right}),
      do: "#{serialize_expr(left)} > #{serialize_expr(right)}"

    defp serialize_expr({:ge, left, right}),
      do: "#{serialize_expr(left)} >= #{serialize_expr(right)}"

    defp serialize_expr({:and, left, right}),
      do: "#{serialize_expr(left)} && #{serialize_expr(right)}"

    defp serialize_expr({:or, left, right}),
      do: "#{serialize_expr(left)} || #{serialize_expr(right)}"

    defp serialize_expr({:not, operand}), do: "! #{serialize_expr(operand)}"

    defp serialize_expr({:assign, {:var, name}, val}), do: "#{name} = #{serialize_expr(val)}"
    defp serialize_expr({:pre_inc, {:var, name}}), do: "++#{name}"
    defp serialize_expr({:pre_dec, {:var, name}}), do: "--#{name}"
    defp serialize_expr({:post_inc, {:var, name}}), do: "#{name}++"
    defp serialize_expr({:post_dec, {:var, name}}), do: "#{name}--"

    defp serialize_expr({:ternary, cond, t, f}),
      do: "#{serialize_expr(cond)} ? #{serialize_expr(t)} : #{serialize_expr(f)}"

    defp serialize_expr({:comma, exprs}), do: Enum.map_join(exprs, ", ", &serialize_expr/1)
    defp serialize_expr({:group, expr}), do: "(#{serialize_expr(expr)})"

    defp serialize_expr(other), do: Kernel.inspect(other)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{exit_code: exit_code}, opts) do
      base = "#Arithmetic{}"

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
