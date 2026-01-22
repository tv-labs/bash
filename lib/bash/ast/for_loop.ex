defmodule Bash.AST.ForLoop do
  @moduledoc """
  for NAME [in WORDS ... ] ; do COMMANDS; done

  Execute commands for each member in a list.

  The `for` loop executes a sequence of commands for each member in a list of items.  If `in WORDS ...;` is not present, then `in "$@"` is assumed. For each element in WORDS, NAME is set to that element, and the COMMANDS are executed.

  Exit Status:
  Returns the status of the last command executed.

  ## Examples

      # for var in one two three; do echo $var; done
      %ForLoop{
        variable: "var",
        items: [
          %Word{parts: [{:literal, "one"}]},
          %Word{parts: [{:literal, "two"}]},
          %Word{parts: [{:literal, "three"}]}
        ],
        body: [
          %Command{name: "echo", args: [%Word{parts: [{:variable, "var"}]}]}
        ]
      }

      # for file in *.txt; do process $file; done
      %ForLoop{
        variable: "file",
        items: [%Word{parts: [{:glob, "*.txt"}]}],
        body: [...]
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.Executor
  alias Bash.Statement
  alias Bash.Telemetry
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          variable: String.t() | nil,
          items: [AST.Word.t()],
          body: [Statement.t()],
          # C-style for loop fields (optional)
          init: String.t() | nil,
          condition: String.t() | nil,
          update: String.t() | nil,
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map(),
          iteration_count: non_neg_integer() | nil
        }

  defstruct [
    :meta,
    :variable,
    :items,
    :body,
    # C-style for loop (optional)
    init: nil,
    condition: nil,
    update: nil,
    # Execution results
    exit_code: nil,
    state_updates: %{},
    iteration_count: nil
  ]

  @doc """
  Get exit code from the last loop iteration.
  """
  @spec get_exit_code(t()) :: 0..255 | nil
  def get_exit_code(%__MODULE__{exit_code: exit_code}), do: exit_code

  @doc """
  Get the number of times the loop was executed.
  """
  @spec iteration_count(t()) :: non_neg_integer() | nil
  def iteration_count(%__MODULE__{iteration_count: count}), do: count

  # C-style for loop: for ((init; condition; update)); do body; done
  def execute(
        %__MODULE__{init: init, condition: condition, update: update, body: body} = ast,
        _stdin,
        session_state
      )
      when not is_nil(init) do
    started_at = DateTime.utc_now()

    {final_result, final_env_updates, iteration_count} =
      Telemetry.for_loop_span("c-style", 0, fn ->
        current_depth = Map.get(session_state, :loop_depth, 0)
        loop_session = Map.put(session_state, :loop_depth, current_depth + 1)

        executable_body = Helpers.executable_statements(body)

        {result, env_updates, iter_count} =
          execute_c_style_for(init, condition, update, executable_body, loop_session, %{}, 0)

        exit_code = for_loop_exit_code(result)
        {{result, env_updates, iter_count}, %{iteration_count: iter_count, exit_code: exit_code}}
      end)

    completed_at = DateTime.utc_now()

    exit_code = for_loop_exit_code(final_result)

    executed_ast = %{
      ast
      | exit_code: exit_code,
        state_updates: %{env_updates: final_env_updates},
        iteration_count: iteration_count,
        meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
    }

    case final_result do
      {:exit, result} -> {:exit, %{executed_ast | exit_code: result.exit_code}}
      _ -> {:ok, executed_ast, %{env_updates: final_env_updates}}
    end
  end

  # Traditional for loop: for var in items; do body; done
  def execute(
        %__MODULE__{variable: var_name, items: items, body: body} = ast,
        _stdin,
        session_state
      ) do
    started_at = DateTime.utc_now()

    # Expand items list (handles command substitution, variable expansion, globs)
    expanded_items = expand_for_loop_items(items, session_state)
    item_count = length(expanded_items)

    {final_result, final_env_updates, iteration_count} =
      Telemetry.for_loop_span(var_name, item_count, fn ->
        # Increment loop depth for break/continue validation
        current_depth = Map.get(session_state, :loop_depth, 0)
        loop_session = Map.put(session_state, :loop_depth, current_depth + 1)

        # Filter separators for execution (they're preserved in AST for formatting)
        executable_body = Helpers.executable_statements(body)

        # Execute the loop body for each item
        {result, env_updates, iter_count} =
          execute_for_loop(expanded_items, var_name, executable_body, loop_session, %{}, 0)

        exit_code = for_loop_exit_code(result)
        {{result, env_updates, iter_count}, %{iteration_count: iter_count, exit_code: exit_code}}
      end)

    completed_at = DateTime.utc_now()

    # Build the executed AST node with results
    exit_code = for_loop_exit_code(final_result)

    executed_ast = %{
      ast
      | exit_code: exit_code,
        state_updates: %{env_updates: final_env_updates},
        iteration_count: iteration_count,
        meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
    }

    # Propagate exit control flow
    case final_result do
      {:exit, result} -> {:exit, %{executed_ast | exit_code: result.exit_code}}
      _ -> {:ok, executed_ast, %{env_updates: final_env_updates}}
    end
  end

  defp for_loop_exit_code({:ok, %{exit_code: code}}) when is_integer(code), do: code
  defp for_loop_exit_code({:ok, nil}), do: 0
  defp for_loop_exit_code({:exit, _}), do: 0
  defp for_loop_exit_code(_), do: 1

  defp execute_for_loop([], _var_name, _body, _session, env_acc, count) do
    # No more items - loop completed normally
    {{:ok, nil}, env_acc, count}
  end

  defp execute_for_loop([item | rest], var_name, body, session_state, env_acc, count) do
    # Set the loop variable in the session state with accumulated updates
    new_variables =
      Map.merge(
        session_state.variables,
        Map.new(Map.put(env_acc, var_name, item), fn {k, v} -> {k, Variable.new(v)} end)
      )

    updated_session = %{session_state | variables: new_variables}

    # Execute body and handle control flow
    case execute_loop_body(body, updated_session, %{}) do
      {:ok, _result, body_env_updates} ->
        # Normal completion - continue to next iteration
        merged_env =
          env_acc
          |> Map.put(var_name, item)
          |> Map.merge(body_env_updates)

        execute_for_loop(
          rest,
          var_name,
          body,
          session_state,
          merged_env,
          count + 1
        )

      {:continue, result, levels, body_env_updates} ->
        # Continue: skip rest of body, go to next iteration
        merged_env =
          env_acc
          |> Map.put(var_name, item)
          |> Map.merge(body_env_updates)

        if levels > 1 do
          # Propagate continue to outer loop
          {{:continue, result, levels - 1}, merged_env, count + 1}
        else
          # Continue this loop
          execute_for_loop(
            rest,
            var_name,
            body,
            session_state,
            merged_env,
            count + 1
          )
        end

      {:break, result, levels, body_env_updates} ->
        # Break: exit this loop
        merged_env =
          env_acc
          |> Map.put(var_name, item)
          |> Map.merge(body_env_updates)

        if levels > 1 do
          # Propagate break to outer loop
          {{:break, result, levels - 1}, merged_env, count + 1}
        else
          # Break out of this loop
          {{:ok, result}, merged_env, count + 1}
        end

      {:exit, result, body_env_updates} ->
        # Exit: terminate the shell
        merged_env =
          env_acc
          |> Map.put(var_name, item)
          |> Map.merge(body_env_updates)

        {{:exit, result}, merged_env, count + 1}

      {:error, _result} ->
        # Error in body - continue but track error
        merged_env = Map.put(env_acc, var_name, item)

        execute_for_loop(
          rest,
          var_name,
          body,
          session_state,
          merged_env,
          count + 1
        )
    end
  end

  defp execute_loop_body([], _session, env_acc) do
    # Return a synthetic result
    {:ok, %{exit_code: 0}, env_acc}
  end

  defp execute_loop_body([stmt | rest], session_state, env_acc) do
    # Use the accumulated environment from previous statements
    stmt_new_variables =
      Map.merge(
        session_state.variables,
        Map.new(env_acc, fn {k, v} -> {k, Variable.new(v)} end)
      )

    stmt_session = %{session_state | variables: stmt_new_variables}

    case Executor.execute(stmt, stmt_session, nil) do
      {:ok, _result, updates} ->
        # Collect both env_updates and var_updates (var_updates as string values)
        env_updates = Map.get(updates, :env_updates, %{})
        var_updates = Map.get(updates, :var_updates, %{})
        # Convert var_updates (Variable structs) to string values for accumulation
        var_values = Map.new(var_updates, fn {k, v} -> {k, Variable.get(v, nil) || ""} end)
        new_env = env_acc |> Map.merge(env_updates) |> Map.merge(var_values)
        execute_loop_body(rest, session_state, new_env)

      {:ok, _result} ->
        execute_loop_body(rest, session_state, env_acc)

      {:break, result, levels} ->
        {:break, %{exit_code: result.exit_code}, levels, env_acc}

      {:continue, result, levels} ->
        {:continue, %{exit_code: result.exit_code}, levels, env_acc}

      {:exit, result} ->
        {:exit, %{exit_code: result.exit_code}, env_acc}

      {:error, result} ->
        {:error, result}
    end
  end

  # Expand for loop items (handles command substitution, variables, globs)
  defp expand_for_loop_items(items, session_state) do
    Enum.flat_map(items, fn item ->
      expanded = Helpers.word_to_string(item, session_state)

      # Split on whitespace to get individual items (bash behavior)
      String.split(expanded, ~r/\s+/, trim: true)
    end)
  end

  # C-style for loop execution
  alias Bash.Parser.Arithmetic, as: ArithParser
  alias Bash.AST.Arithmetic, as: Arith

  defp execute_c_style_for(init, condition, update, body, session_state, env_acc, count) do
    # Build arithmetic env from session variables
    arith_env = build_arith_env(session_state, env_acc)

    # Execute init expression if not empty (e.g., "i=0")
    arith_env = eval_arith_expr(init, arith_env)

    # Start the loop
    c_style_loop(condition, update, body, session_state, arith_env, env_acc, count)
  end

  defp c_style_loop(condition, update, body, session_state, arith_env, env_acc, count) do
    # Evaluate condition (e.g., "i<3") - empty condition is always true
    cond_result = eval_arith_condition(condition, arith_env)

    if cond_result == 0 do
      # Condition is false - exit loop
      {{:ok, nil}, merge_arith_env(env_acc, arith_env), count}
    else
      # Condition is true - execute body
      # Merge arithmetic env into session state for body execution
      merged_env = merge_arith_env(env_acc, arith_env)

      new_variables =
        Map.merge(
          session_state.variables,
          Map.new(merged_env, fn {k, v} -> {k, Variable.new(v)} end)
        )

      updated_session = %{session_state | variables: new_variables}

      case execute_loop_body(body, updated_session, merged_env) do
        {:ok, _result, body_env_updates} ->
          # Body completed - execute update and continue
          # Merge body updates into arith_env
          updated_arith_env =
            Enum.reduce(body_env_updates, arith_env, fn {k, v}, acc ->
              Map.put(acc, k, to_string(v))
            end)

          # Execute update expression (e.g., "i++")
          new_arith_env = eval_arith_expr(update, updated_arith_env)

          # Continue to next iteration
          c_style_loop(
            condition,
            update,
            body,
            session_state,
            new_arith_env,
            body_env_updates,
            count + 1
          )

        {:continue, _result, levels, body_env_updates} ->
          if levels > 1 do
            {{:continue, %{exit_code: 0}, levels - 1},
             merge_arith_env(body_env_updates, arith_env), count + 1}
          else
            # Continue this loop - execute update and go to next iteration
            updated_arith_env =
              Enum.reduce(body_env_updates, arith_env, fn {k, v}, acc ->
                Map.put(acc, k, to_string(v))
              end)

            new_arith_env = eval_arith_expr(update, updated_arith_env)

            c_style_loop(
              condition,
              update,
              body,
              session_state,
              new_arith_env,
              body_env_updates,
              count + 1
            )
          end

        {:break, result, levels, body_env_updates} ->
          if levels > 1 do
            {{:break, result, levels - 1}, merge_arith_env(body_env_updates, arith_env),
             count + 1}
          else
            {{:ok, result}, merge_arith_env(body_env_updates, arith_env), count + 1}
          end

        {:exit, result, body_env_updates} ->
          {{:exit, result}, merge_arith_env(body_env_updates, arith_env), count + 1}

        {:error, _result} ->
          # Continue on error
          new_arith_env = eval_arith_expr(update, arith_env)
          c_style_loop(condition, update, body, session_state, new_arith_env, env_acc, count + 1)
      end
    end
  end

  defp build_arith_env(session_state, env_acc) do
    # Get current variable values as strings for arithmetic evaluation
    base_env =
      session_state.variables
      |> Enum.map(fn {k, v} -> {k, Variable.get(v, nil) || "0"} end)
      |> Map.new()

    # Merge with accumulated env values
    Map.merge(base_env, Map.new(env_acc, fn {k, v} -> {k, to_string(v)} end))
  end

  defp merge_arith_env(env_acc, arith_env) do
    Map.merge(env_acc, arith_env)
  end

  # Evaluate arithmetic expression, returning updated env
  # Empty or whitespace-only expressions return env unchanged
  defp eval_arith_expr(expr, env) when is_binary(expr) do
    trimmed = String.trim(expr)

    if trimmed == "" do
      env
    else
      case ArithParser.parse(trimmed) do
        {:ok, ast} ->
          case Arith.execute(ast, env) do
            {:ok, _result, new_env} -> new_env
            {:error, _} -> env
          end

        {:error, _} ->
          env
      end
    end
  end

  defp eval_arith_expr(nil, env), do: env

  # Evaluate arithmetic condition, returning 0 (false) or 1 (true)
  # Empty condition is always true (1) in bash
  defp eval_arith_condition(cond_expr, env) when is_binary(cond_expr) do
    trimmed = String.trim(cond_expr)

    if trimmed == "" do
      1
    else
      case ArithParser.parse(trimmed) do
        {:ok, ast} ->
          case Arith.execute(ast, env) do
            {:ok, result, _new_env} -> result
            {:error, _} -> 0
          end

        {:error, _} ->
          0
      end
    end
  end

  defp eval_arith_condition(nil, _env), do: 1

  alias Bash.AST.Formatter

  @doc """
  Convert to Bash string with formatting context.
  """
  def to_bash(%__MODULE__{variable: variable, items: items, body: body}, %Formatter{} = fmt) do
    indent = Formatter.current_indent(fmt)
    inner_fmt = Formatter.indent(fmt)
    items_str = Enum.map_join(items, " ", &Kernel.to_string/1)
    body_str = Formatter.serialize_body(body, inner_fmt)
    "for #{variable} in #{items_str}; do\n#{body_str}\n#{indent}done"
  end

  defimpl String.Chars do
    alias Bash.AST.Formatter

    def to_string(%Bash.AST.ForLoop{} = for_loop) do
      Bash.AST.ForLoop.to_bash(for_loop, Formatter.new())
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{variable: variable, items: items, exit_code: exit_code}, opts) do
      item_count = length(items)

      base =
        concat([
          "#For{",
          color(variable, :atom, opts),
          ", ",
          color("#{item_count}", :number, opts),
          "}"
        ])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
