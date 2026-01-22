defmodule Bash.AST.WhileLoop do
  @moduledoc """
  While or until loop.

  ## Examples

      # while [ condition ]; do body; done
      %WhileLoop{
        condition: %Command{name: "test", ...},
        body: [...],
        until: false
      }

      # until [ condition ]; do body; done
      %WhileLoop{
        condition: %Command{name: "test", ...},
        body: [...],
        until: true
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.AST.Redirect
  alias Bash.CommandResult
  alias Bash.Executor
  alias Bash.Statement
  alias Bash.Telemetry
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          condition: Statement.t(),
          body: [Statement.t()],
          until: boolean(),
          redirects: [Redirect.t()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map(),
          iteration_count: non_neg_integer() | nil
        }

  defstruct [
    :meta,
    :condition,
    :body,
    until: false,
    redirects: [],
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

  # Execute while/until loop
  @max_loop_iterations 10_000

  # Execute a WhileLoop (handles both while and until via the :until flag)
  def execute(
        %__MODULE__{condition: condition, body: body, until: until_mode, redirects: redirects} =
          ast,
        stdin,
        session_state
      ) do
    started_at = DateTime.utc_now()

    loop_result =
      Telemetry.while_loop_span(until_mode, fn ->
        # Set up stdin device for input redirects (e.g., done < file) or piped stdin
        {stdin_session, stdin_cleanup} = setup_stdin_device(redirects, session_state, stdin)

        # Set up output redirects
        {loop_session_state, output_cleanup} =
          setup_loop_output_redirects(redirects, stdin_session)

        # Increment loop depth for break/continue validation
        current_depth = Map.get(loop_session_state, :loop_depth, 0)
        loop_session = Map.put(loop_session_state, :loop_depth, current_depth + 1)

        # Filter separators for execution (they're preserved in AST for formatting)
        executable_body = Helpers.executable_statements(body)

        result =
          execute_while_loop(condition, executable_body, until_mode, loop_session, %{}, 0, stdin)

        # Clean up redirect resources
        stdin_cleanup.()
        output_cleanup.()

        {iter_count, exit_code} = while_loop_telemetry_metadata(result)
        {result, %{iteration_count: iter_count, exit_code: exit_code}}
      end)

    completed_at = DateTime.utc_now()

    case loop_result do
      {:ok, result, env_updates, iter_count} ->
        executed_ast = %{
          ast
          | exit_code: result.exit_code,
            state_updates: %{env_updates: env_updates},
            iteration_count: iter_count,
            meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
        }

        {:ok, executed_ast, %{env_updates: env_updates}}

      {:exit, result, env_updates, iter_count} ->
        executed_ast = %{
          ast
          | exit_code: result.exit_code,
            state_updates: %{env_updates: env_updates},
            iteration_count: iter_count,
            meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
        }

        {:exit, executed_ast}

      {:break, _result, levels, env_updates, iter_count} ->
        executed_ast = %{
          ast
          | exit_code: 0,
            state_updates: %{env_updates: env_updates},
            iteration_count: iter_count,
            meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
        }

        if levels > 1 do
          {:break, executed_ast, levels - 1}
        else
          {:ok, executed_ast, %{env_updates: env_updates}}
        end

      {:continue, _result, levels, env_updates, iter_count} ->
        executed_ast = %{
          ast
          | exit_code: 0,
            state_updates: %{env_updates: env_updates},
            iteration_count: iter_count,
            meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
        }

        if levels > 1 do
          {:continue, executed_ast, levels - 1}
        else
          {:ok, executed_ast, %{env_updates: env_updates}}
        end

      {:error, result} ->
        executed_ast = %{
          ast
          | exit_code: result.exit_code || 1,
            state_updates: %{},
            iteration_count: 0,
            meta: AST.Meta.mark_evaluated(ast.meta, started_at, completed_at)
        }

        {:error, executed_ast}
    end
  end

  defp while_loop_telemetry_metadata({:ok, result, _env_updates, iter_count}) do
    {iter_count, result.exit_code}
  end

  defp while_loop_telemetry_metadata({:exit, result, _env_updates, iter_count}) do
    {iter_count, result.exit_code}
  end

  defp while_loop_telemetry_metadata({:break, _result, _levels, _env_updates, iter_count}) do
    {iter_count, 0}
  end

  defp while_loop_telemetry_metadata({:continue, _result, _levels, _env_updates, iter_count}) do
    {iter_count, 0}
  end

  defp while_loop_telemetry_metadata({:error, result}) do
    {0, result.exit_code || 1}
  end

  defp execute_while_loop(
         condition,
         body,
         until_mode,
         session_state,
         env_updates,
         iteration,
         effective_stdin
       ) do
    # Safety check to prevent infinite loops
    if iteration >= @max_loop_iterations do
      # Write error to stderr sink
      Bash.Sink.write_stderr(
        session_state,
        "loop: iteration limit exceeded (#{@max_loop_iterations})\n"
      )

      {:error, %CommandResult{exit_code: 1, error: :loop_limit_exceeded}}
    else
      stmt_new_variables =
        Map.merge(
          session_state.variables,
          Map.new(env_updates, fn {k, v} -> {k, Variable.new(v)} end)
        )

      stmt_session = %{session_state | variables: stmt_new_variables}

      condition_result =
        case Executor.execute(condition, stmt_session, effective_stdin) do
          {:ok, result, updates} ->
            # Collect both env_updates and var_updates
            env_from_cond = Map.get(updates, :env_updates, %{})
            var_from_cond = Map.get(updates, :var_updates, %{})
            var_values = Map.new(var_from_cond, fn {k, v} -> {k, Variable.get(v, nil) || ""} end)
            merged = env_updates |> Map.merge(env_from_cond) |> Map.merge(var_values)
            {:ok, result.exit_code, merged}

          {:ok, result} ->
            {:ok, result.exit_code, env_updates}

          {:error, result} ->
            {:ok, result.exit_code || 1, env_updates}
        end

      {:ok, exit_code, updated_env} = condition_result
      # For while: continue if exit_code == 0
      # For until: continue if exit_code != 0
      should_continue = if until_mode, do: exit_code != 0, else: exit_code == 0

      if should_continue do
        # Execute the body
        body_new_variables =
          Map.merge(
            session_state.variables,
            Map.new(updated_env, fn {k, v} -> {k, Variable.new(v)} end)
          )

        body_session = %{session_state | variables: body_new_variables}

        case execute_loop_body(body, body_session, updated_env) do
          {:ok, _result, body_env} ->
            # Continue looping
            execute_while_loop(
              condition,
              body,
              until_mode,
              session_state,
              body_env,
              iteration + 1,
              effective_stdin
            )

          {:break, result, levels, body_env} ->
            # Break out of loop
            if levels > 1 do
              {:break, result, levels - 1, body_env, iteration + 1}
            else
              {:ok, %CommandResult{exit_code: 0}, body_env, iteration + 1}
            end

          {:continue, result, levels, body_env} ->
            # Continue to next iteration
            if levels > 1 do
              {:continue, result, levels - 1, body_env, iteration + 1}
            else
              execute_while_loop(
                condition,
                body,
                until_mode,
                session_state,
                body_env,
                iteration + 1,
                effective_stdin
              )
            end

          {:exit, result, body_env} ->
            {:exit, result, body_env, iteration + 1}

          {:error, result} ->
            # Body failed - stop loop and return error
            {:error, result}
        end
      else
        # Loop condition no longer met - return success
        {:ok, %CommandResult{exit_code: 0}, updated_env, iteration}
      end
    end
  end

  defp execute_loop_body([], _session, env_acc) do
    {:ok, %{exit_code: 0}, env_acc}
  end

  defp execute_loop_body([stmt | rest], session_state, env_acc) do
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

  # Set up stdin device for the while loop from input redirects (e.g., done < file)
  # or from piped stdin (e.g., echo "data" | while read line; do ...; done)
  # Opens a StringIO device that read builtin can consume line by line
  # Returns {modified_session_state, cleanup_fn}
  defp setup_stdin_device(redirects, session_state, stdin)
       when redirects in [nil, []] and is_binary(stdin) and stdin != "" do
    # Convert piped stdin to a StringIO device for line-by-line reading
    {:ok, device} = StringIO.open(stdin)
    new_session = Map.put(session_state, :stdin_device, device)
    cleanup_fn = fn -> StringIO.close(device) end
    {new_session, cleanup_fn}
  end

  defp setup_stdin_device(redirects, session_state, _stdin)
       when redirects in [nil, []] do
    {session_state, fn -> :ok end}
  end

  defp setup_stdin_device(redirects, session_state, _stdin) do
    # Find the last input redirect
    input_redirect =
      redirects
      |> Enum.filter(
        &match?(%AST.Redirect{direction: dir} when dir in [:input, :heredoc, :herestring], &1)
      )
      |> List.last()

    content =
      case input_redirect do
        nil ->
          nil

        %AST.Redirect{direction: :input, target: {:file, file_word}} ->
          # Read from file (including process substitution results via /dev/fd/N)
          file_path = Bash.AST.Helpers.word_to_string(file_word, session_state)

          case File.read(file_path) do
            {:ok, content} -> content
            {:error, _} -> nil
          end

        %AST.Redirect{
          direction: :heredoc,
          target: {:heredoc, heredoc_content, _delimiter, _strip_tabs}
        } ->
          to_string(heredoc_content)

        %AST.Redirect{direction: :herestring, target: {:word, word}} ->
          Bash.AST.Helpers.word_to_string(word, session_state) <> "\n"

        _ ->
          nil
      end

    if content do
      # Open a StringIO device for line-by-line reading
      {:ok, device} = StringIO.open(content)
      new_session = Map.put(session_state, :stdin_device, device)
      cleanup_fn = fn -> StringIO.close(device) end
      {new_session, cleanup_fn}
    else
      {session_state, fn -> :ok end}
    end
  end

  # Set up output redirects for the while loop
  defp setup_loop_output_redirects(redirects, session_state)
       when redirects in [nil, []] do
    {session_state, fn -> :ok end}
  end

  defp setup_loop_output_redirects(_redirects, session_state) do
    # Output redirects on while loops are less common
    # For now, pass through unchanged - can be enhanced to handle output redirects
    {session_state, fn -> :ok end}
  end

  alias Bash.AST.Formatter

  @doc """
  Convert to Bash string with formatting context.
  """
  def to_bash(
        %__MODULE__{until: until, condition: condition, body: body, redirects: redirects},
        %Formatter{} = fmt
      ) do
    indent = Formatter.current_indent(fmt)
    inner_fmt = Formatter.indent(fmt)
    keyword = if until, do: "until", else: "while"
    body_str = Formatter.serialize_body(body, inner_fmt)
    redirects_str = serialize_redirects(redirects)

    "#{keyword} #{Formatter.to_bash(condition, fmt)}; do\n#{body_str}\n#{indent}done#{redirects_str}"
  end

  defp serialize_redirects([]), do: ""
  defp serialize_redirects(nil), do: ""

  defp serialize_redirects(redirects) do
    " " <> Enum.map_join(redirects, " ", &to_string/1)
  end

  defimpl String.Chars do
    alias Bash.AST.Formatter

    def to_string(%Bash.AST.WhileLoop{} = while_loop) do
      Bash.AST.WhileLoop.to_bash(while_loop, Formatter.new())
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{until: until, exit_code: exit_code}, opts) do
      kind = if until, do: "until", else: "while"
      base = concat(["#While{", color(kind, :atom, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
