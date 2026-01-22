defmodule Bash.AST.Compound do
  @moduledoc """
  Compound statement: subshell or command group.

  ## Examples

      # (cd /tmp && ls)  - subshell
      %Compound{
        kind: :subshell,
        statements: [...]
      }

      # { cd /tmp && ls; }  - group (current shell)
      %Compound{
        kind: :group,
        statements: [...]
      }

      # cmd1; cmd2; cmd3 - sequential
      %Compound{
        statements: [
          %Command{name: "cmd1", ...},
          %Command{name: "cmd2", ...}
        ]
      }

      # cmd1 && cmd2 || cmd3 - operand
      %Compound{
        statements: [
          %Command{name: "cmd1", ...},
          {:operator, :&&}
          %Command{name: "cmd2", ...},
          {:operator, :||}
          %Command{name: "cmd3", ...}
        ]
      }

      # cmd1 & cmd2 & - operand
      %Compound{
        statements: [
          %Command{name: "cmd1", ...},
          {:operator, :bg},
          %Command{name: "cmd2", ...},
          {:operator, :bg}
        ]
      }
  """

  alias Bash.AST
  alias Bash.Variable
  alias Bash.AST.Helpers
  alias Bash.Variable
  alias Bash.Executor
  alias Bash.Variable
  alias Bash.CommandResult
  alias Bash.Variable

  @type kind :: :subshell | :group | :operand | :sequential

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          kind: kind(),
          statements: [Statement.t()],
          redirects: [Redirect.t()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :kind,
    :statements,
    redirects: [],
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  @doc """
  Get exit code from the last evaluated statement.
  """
  @spec get_exit_code(t()) :: 0..255 | nil
  def get_exit_code(%__MODULE__{statements: statements}) do
    statements
    |> Enum.reject(&operator?/1)
    |> Enum.filter(&evaluated?/1)
    |> List.last()
    |> case do
      nil -> nil
      stmt -> Map.get(stmt, :exit_code)
    end
  end

  @doc """
  Filter to only evaluated statements (no operators, only statements with evaluated: true).
  """
  @spec evaluated_statements(t()) :: [map()]
  def evaluated_statements(%__MODULE__{statements: statements}) do
    statements
    |> Enum.reject(&operator?/1)
    |> Enum.filter(&evaluated?/1)
  end

  # Check if an item is an operator tuple
  defp operator?({:operator, _}), do: true
  defp operator?(_), do: false

  # Check if a statement has been evaluated
  defp evaluated?(%{meta: %AST.Meta{evaluated: true}}), do: true
  defp evaluated?(_), do: false

  def execute(%__MODULE__{kind: :operand, statements: statements}, _stdin, session_state) do
    # Filter separators for execution (they're preserved in AST for formatting)
    statements = Helpers.executable_statements(statements)

    # Check if the compound ends with a background operator
    # If so, return a :background tuple for the Session to handle
    case List.pop_at(statements, -1) do
      {{:operator, :bg}, statements} ->
        # Remove trailing :bg and return signal for Session to background this
        statements = build_foreground_ast(statements)
        {:background, statements, session_state}

      _ ->
        # Execute compound command with && and || operators normally
        # statements is: [cmd1, {:operator, :and}, cmd2, {:operator, :or}, cmd3, ...]
        execute_compound_operand(statements, session_state, %{}, %{})
    end
  end

  # Subshell: ( commands )
  # Executes in an isolated copy of session state - env/cwd changes don't affect parent
  # Note: We DON'T spawn a child GenServer to avoid nested GenServer.call deadlock.
  # Instead, we execute directly with a copy of state and discard the updates.
  def execute(%__MODULE__{kind: :subshell, statements: statements}, _stdin, session_state) do
    # Create an isolated copy of session state for subshell execution
    # Per bash behavior: inherit env_vars, working_dir, functions, options
    # Do NOT inherit: aliases, hash table
    subshell_state = %{
      session_state
      | aliases: %{},
        hash: %{}
    }

    # Execute the body and get result, but discard the state updates (isolation)
    case Helpers.execute_body(statements, subshell_state, %{}) do
      {:ok, result, _discarded_env_updates} ->
        # Return result WITHOUT env_updates (subshell isolation)
        {:ok, result}

      {:error, result} ->
        {:error, result}
    end
  end

  # Command group: { commands; }
  # Executes in current session - env/cwd changes persist
  def execute(%__MODULE__{kind: :group, statements: statements}, stdin, session_state) do
    # If we have piped stdin, set up a StringIO device for the read builtin
    {stdin_session, stdin_cleanup} = setup_stdin_device(stdin, session_state)

    try do
      # Execute statements in current session, accumulating env updates
      Helpers.execute_body(statements, stdin_session, %{})
    after
      stdin_cleanup.()
    end
  end

  # Sequential: cmd1; cmd2; cmd3
  # Executes statements in order in current session - env/cwd changes persist
  def execute(%__MODULE__{kind: :sequential, statements: statements}, _stdin, session_state) do
    # Execute statements in current session, accumulating env updates
    Helpers.execute_body(statements, session_state, %{})
  end

  # Build AST for foreground execution from compound statements
  # If there's just one statement, return it directly
  # Otherwise, rebuild the Compound with remaining statements
  defp build_foreground_ast([single_statement]), do: single_statement

  defp build_foreground_ast(statements) do
    %__MODULE__{meta: nil, kind: :operand, statements: statements, redirects: []}
  end

  # Execute compound operand statements (cmd && cmd || cmd)
  # Implements short-circuit evaluation:
  # - && (and): execute next only if previous succeeded (exit_code == 0)
  # - || (or): execute next only if previous failed (exit_code != 0)
  # Output goes directly to sinks during execution
  # Tracks both env_updates (strings) and var_updates (Variable structs) separately
  defp execute_compound_operand([], _session_state, env_updates, var_updates) do
    # No statements left - return success with empty result
    {:ok,
     %CommandResult{
       command: nil,
       exit_code: 0,
       error: nil
     }, %{env_updates: env_updates, var_updates: var_updates}}
  end

  defp execute_compound_operand([statement], session_state, env_updates, var_updates) do
    # Last statement - execute and return result
    updated_session = apply_updates_to_session(session_state, env_updates, var_updates)

    case Executor.execute(statement, updated_session, nil) do
      {:ok, result, updates} ->
        env_from_stmt = Map.get(updates, :env_updates, %{})
        var_from_stmt = Map.get(updates, :var_updates, %{})
        merged_env = Map.merge(env_updates, env_from_stmt)
        merged_var = Map.merge(var_updates, var_from_stmt)
        {:ok, result, %{env_updates: merged_env, var_updates: merged_var}}

      {:ok, result} ->
        {:ok, result, %{env_updates: env_updates, var_updates: var_updates}}

      {:error, result} ->
        {:error, result}

      # Propagate loop control flow
      {:break, _result, _levels} = break ->
        break

      {:continue, _result, _levels} = continue ->
        continue

      {:exit, _result} = exit ->
        exit
    end
  end

  defp execute_compound_operand(
         [statement, {:operator, operator} | rest],
         session_state,
         env_updates,
         var_updates
       ) do
    # Execute statement, then decide based on operator whether to continue
    updated_session = apply_updates_to_session(session_state, env_updates, var_updates)

    case Executor.execute(statement, updated_session, nil) do
      {:ok, result, updates} ->
        env_from_stmt = Map.get(updates, :env_updates, %{})
        var_from_stmt = Map.get(updates, :var_updates, %{})
        merged_env = Map.merge(env_updates, env_from_stmt)
        merged_var = Map.merge(var_updates, var_from_stmt)

        decide_continue(
          result.exit_code,
          operator,
          rest,
          session_state,
          merged_env,
          merged_var,
          result
        )

      {:ok, result} ->
        decide_continue(
          result.exit_code,
          operator,
          rest,
          session_state,
          env_updates,
          var_updates,
          result
        )

      {:error, result} ->
        # Error results are treated as failed (exit_code != 0)
        decide_continue(
          result.exit_code || 1,
          operator,
          rest,
          session_state,
          env_updates,
          var_updates,
          result
        )

      # Propagate loop control flow - don't continue with compound
      {:break, _result, _levels} = break ->
        break

      {:continue, _result, _levels} = continue ->
        continue

      {:exit, _result} = exit ->
        exit
    end
  end

  # Apply both env_updates and var_updates to session state
  defp apply_updates_to_session(session_state, env_updates, var_updates) do
    # env_updates: string values that need Variable.new()
    # var_updates: already Variable structs (preserved for arrays like BASH_REMATCH)
    env_vars = Map.new(env_updates, fn {k, v} -> {k, Variable.new(v)} end)
    new_variables = session_state.variables |> Map.merge(env_vars) |> Map.merge(var_updates)
    %{session_state | variables: new_variables}
  end

  # Decide whether to continue based on exit code and operator
  # When we short-circuit (skip a command), we still need to check remaining operators
  # Now tracks both env_updates and var_updates separately
  defp decide_continue(
         exit_code,
         operator,
         rest,
         session_state,
         env_updates,
         var_updates,
         _last_result
       )
       when exit_code == 0 and operator == :and do
    execute_compound_operand(rest, session_state, env_updates, var_updates)
  end

  defp decide_continue(
         exit_code,
         operator,
         rest,
         session_state,
         env_updates,
         var_updates,
         _last_result
       )
       when exit_code != 0 and operator == :or do
    execute_compound_operand(rest, session_state, env_updates, var_updates)
  end

  defp decide_continue(
         exit_code,
         _operator,
         rest,
         _session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code == 0 and rest == [] do
    # No more commands - return current result
    {:ok, last_result, %{env_updates: env_updates, var_updates: var_updates}}
  end

  defp decide_continue(
         exit_code,
         operator,
         [_] = _rest,
         _session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code == 0 and operator == :or do
    # Success with || - skip the next command and return success
    {:ok, last_result, %{env_updates: env_updates, var_updates: var_updates}}
  end

  defp decide_continue(
         exit_code,
         operator,
         [_] = _rest,
         _session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code != 0 and operator == :and do
    # Failure with && - skip the next command but return success with non-zero exit code
    # This is not an error, just a short-circuit
    {:ok, last_result, %{env_updates: env_updates, var_updates: var_updates}}
  end

  defp decide_continue(
         exit_code,
         _operator,
         [_] = _rest,
         _session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code != 0 do
    # Only one more command and we're skipping it - return success with non-zero exit code
    {:ok, last_result, %{env_updates: env_updates, var_updates: var_updates}}
  end

  # Skip a command and continue with the next operator (success with || case)
  defp decide_continue(
         exit_code,
         operator,
         [_skipped_cmd, {:operator, next_op} | rest],
         session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code == 0 and operator == :or do
    # Success with || - skip command and continue evaluating with next operator
    decide_continue(
      exit_code,
      next_op,
      rest,
      session_state,
      env_updates,
      var_updates,
      last_result
    )
  end

  # Skip a command and continue with the next operator (failure with && case)
  defp decide_continue(
         exit_code,
         operator,
         [_skipped_cmd, {:operator, next_op} | rest],
         session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code != 0 and operator == :and do
    # Failure with && - skip command and continue evaluating with next operator
    decide_continue(
      exit_code,
      next_op,
      rest,
      session_state,
      env_updates,
      var_updates,
      last_result
    )
  end

  defp decide_continue(
         exit_code,
         operator,
         [{:operator, next_op} | rest],
         session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code == 0 and operator == :or do
    # Success with || - skip and check next operator
    decide_continue(
      exit_code,
      next_op,
      rest,
      session_state,
      env_updates,
      var_updates,
      last_result
    )
  end

  defp decide_continue(
         exit_code,
         operator,
         [{:operator, next_op} | rest],
         session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code != 0 and operator == :and do
    # Failure with && - skip and check next operator
    decide_continue(
      exit_code,
      next_op,
      rest,
      session_state,
      env_updates,
      var_updates,
      last_result
    )
  end

  defp decide_continue(
         exit_code,
         _operator,
         [{:operator, next_op} | rest],
         session_state,
         env_updates,
         var_updates,
         last_result
       )
       when exit_code != 0 do
    # There's another operator after the skipped command
    # Check if we should continue with the remaining based on current exit_code
    decide_continue(
      exit_code,
      next_op,
      rest,
      session_state,
      env_updates,
      var_updates,
      last_result
    )
  end

  # Set up stdin device for command groups receiving piped input
  # Opens a StringIO device that read builtin can consume line by line
  # Returns {modified_session_state, cleanup_fn}
  defp setup_stdin_device(stdin, session_state)
       when is_binary(stdin) and stdin != "" do
    # Convert piped stdin to a StringIO device for line-by-line reading
    {:ok, device} = StringIO.open(stdin)
    new_session = Map.put(session_state, :stdin_device, device)
    cleanup_fn = fn -> StringIO.close(device) end
    {new_session, cleanup_fn}
  end

  defp setup_stdin_device(_stdin, session_state) do
    {session_state, fn -> :ok end}
  end

  defimpl String.Chars do
    # Filter separator tuples (used for formatting, not for simple string conversion)
    defp filter_separators(statements) do
      Enum.reject(statements, &match?({:separator, _}, &1))
    end

    # Compound with operators (&&, ||, &)
    def to_string(%{kind: :operand, statements: statements}) do
      statements
      |> filter_separators()
      |> Enum.map_join(" ", fn
        {:operator, :and} -> "&&"
        {:operator, :or} -> "||"
        {:operator, :bg} -> "&"
        node -> Kernel.to_string(node)
      end)
    end

    # Subshell: ( commands )
    def to_string(%{kind: :subshell, statements: statements}) do
      body_str =
        statements
        |> filter_separators()
        |> Enum.map_join("; ", &Kernel.to_string/1)

      "(#{body_str})"
    end

    # Command group: { commands; }
    def to_string(%{kind: :group, statements: statements}) do
      body_str =
        statements
        |> filter_separators()
        |> Enum.map_join("; ", &Kernel.to_string/1)

      "{ #{body_str}; }"
    end

    # Sequential (default)
    def to_string(%{statements: statements}) do
      statements
      |> filter_separators()
      |> Enum.map_join("; ", &Kernel.to_string/1)
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{kind: kind, statements: statements, exit_code: exit_code}, opts) do
      stmt_count =
        Enum.count(statements, fn
          {:operator, _} -> false
          _ -> true
        end)

      kind_str = Atom.to_string(kind || :compound)

      base =
        concat([
          "#Compound{",
          color(kind_str, :atom, opts),
          ", ",
          color("#{stmt_count}", :number, opts),
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
