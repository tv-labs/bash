defmodule Bash.Script do
  @moduledoc """
  Top-level script: a sequence of statements with separators.

  ## Examples

      # Simple script
      %Script{
        statements: [
          %Assignment{name: "x", value: ...},
          {:separator, ";"},
          %Command{name: "echo", args: [...]}
        ]
      }

      # Single statement (no separators)
      %Script{
        statements: [%Command{name: "echo", args: [...]}]
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.AST.Pipeline
  alias Bash.Builtin.Trap
  alias Bash.Executor
  alias Bash.Parser
  alias Bash.Variable

  @type separator :: {:separator, String.t()}
  @type statement_or_separator :: AST.Statement.t() | separator()
  @type output_entry :: {:stdout, String.t()} | {:stderr, String.t()}

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          shebang: String.t() | nil,
          statements: [statement_or_separator()],
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map(),
          # Output collector for reading output after execution
          collector: pid() | nil
        }

  defstruct [
    :meta,
    :shebang,
    statements: [],
    # Execution results
    exit_code: nil,
    state_updates: %{},
    # Output collector - read from this to get stdout/stderr
    collector: nil
  ]

  @doc """
  Execute a script, updating all statements with their execution results.

  Returns the script with:
  - All statements updated with their exit_code and meta
  - The script's exit_code set to the last statement's exit code
  - The script's state_updates merged from all statements
  - The script's collector set to the output collector (for reading output)

  Output is written to sinks during execution. Read from the collector after execution.
  """
  def execute(%__MODULE__{statements: statements, meta: meta} = script, _stdin, session_state) do
    started_at = DateTime.utc_now()

    {executed_statements, final_exit_code, _accumulated_output, merged_updates, final_result} =
      execute_statements(statements, session_state, [], 0, [], %{})

    completed_at = DateTime.utc_now()

    # Get the collector from session state so callers can read output
    collector = Map.get(session_state, :output_collector)

    executed_script = %{
      script
      | statements: executed_statements,
        exit_code: final_exit_code,
        state_updates: merged_updates,
        meta: AST.Meta.mark_evaluated(meta, started_at, completed_at),
        collector: collector
    }

    # Check if there's a pending background job to start
    pending_bg = Map.get(merged_updates, :pending_background)
    # Remove pending_background from updates before returning (it's handled separately)
    clean_updates = Map.delete(merged_updates, :pending_background)

    # Get the final session state with all accumulated updates for EXIT trap
    final_session = apply_updates_to_session(session_state, merged_updates)

    # Execute EXIT trap before returning (unless it's a background job or job control)
    case final_result do
      :ok when pending_bg != nil ->
        # Script completed but there's a background job to start
        {:background, executed_script, clean_updates, {:background, pending_bg, session_state}}

      :ok ->
        execute_exit_trap(final_session)
        {:ok, executed_script, clean_updates}

      :exit ->
        execute_exit_trap(final_session)
        {:exit, executed_script, clean_updates}

      :exec ->
        # Don't run EXIT trap for exec (shell is being replaced)
        {:exec, executed_script, clean_updates}

      :error ->
        execute_exit_trap(final_session)
        {:error, executed_script, clean_updates}

      # Job control builtins - include executed_script so Session can return it
      {:wait_for_jobs, job_specs} ->
        {:wait_for_jobs, job_specs, executed_script, clean_updates}

      {:signal_jobs, signal, targets} ->
        {:signal_jobs, signal, targets, executed_script, clean_updates}

      {:foreground_job, job_number} ->
        {:foreground_job, job_number, executed_script, clean_updates}

      {:background_job, job_numbers} ->
        {:background_job, job_numbers, executed_script, clean_updates}
    end
  end

  @doc """
  Continue executing a script from where it left off (after wait, fg, etc).

  This finds the first unexecuted statement (exit_code: nil) and continues
  from there. Used by Session to resume scripts after job control operations.
  """
  def continue_execution(%__MODULE__{statements: statements} = script, session_state) do
    # Find the split point: executed statements have exit_code set
    {executed_stmts, remaining_stmts} = split_at_unexecuted(statements)

    if remaining_stmts == [] do
      # Nothing more to execute
      {:ok, script, %{}}
    else
      # Continue executing remaining statements
      {new_statements, final_exit_code, _output, merged_updates, final_result} =
        execute_statements(
          remaining_stmts,
          session_state,
          Enum.reverse(executed_stmts),
          0,
          [],
          %{}
        )

      executed_script = %{
        script
        | statements: new_statements,
          exit_code: final_exit_code,
          state_updates: Map.merge(script.state_updates, merged_updates)
      }

      clean_updates = Map.delete(merged_updates, :pending_background)

      case final_result do
        :ok ->
          final_session = apply_updates_to_session(session_state, merged_updates)
          execute_exit_trap(final_session)
          {:ok, executed_script, clean_updates}

        :exit ->
          final_session = apply_updates_to_session(session_state, merged_updates)
          execute_exit_trap(final_session)
          {:exit, executed_script, clean_updates}

        :exec ->
          {:exec, executed_script, clean_updates}

        :error ->
          final_session = apply_updates_to_session(session_state, merged_updates)
          execute_exit_trap(final_session)
          {:error, executed_script, clean_updates}

        # Further job control - return for Session to handle
        {:wait_for_jobs, job_specs} ->
          {:wait_for_jobs, job_specs, executed_script, clean_updates}

        {:signal_jobs, signal, targets} ->
          {:signal_jobs, signal, targets, executed_script, clean_updates}

        {:foreground_job, job_number} ->
          {:foreground_job, job_number, executed_script, clean_updates}

        {:background_job, job_numbers} ->
          {:background_job, job_numbers, executed_script, clean_updates}
      end
    end
  end

  @doc """
  Split a script's statements into executed and remaining (unexecuted).
  Public wrapper for debugging script continuation.
  """
  def split_executed(%__MODULE__{statements: statements}) do
    split_at_unexecuted(statements)
  end

  # Split statements into executed and remaining
  # Executed statements have exit_code set (not nil), remaining have nil
  defp split_at_unexecuted(statements) do
    split_at_unexecuted(statements, [])
  end

  defp split_at_unexecuted([], executed) do
    {Enum.reverse(executed), []}
  end

  defp split_at_unexecuted([{:separator, _} = sep | rest], executed) do
    # Separators count as executed
    split_at_unexecuted(rest, [sep | executed])
  end

  defp split_at_unexecuted([stmt | rest] = remaining, executed) do
    if stmt_executed?(stmt) do
      split_at_unexecuted(rest, [stmt | executed])
    else
      {Enum.reverse(executed), remaining}
    end
  end

  defp stmt_executed?(%{exit_code: nil}), do: false
  defp stmt_executed?(%{exit_code: _}), do: true
  # Comments, etc.
  defp stmt_executed?(_), do: true

  # Mark a statement as executed with the given exit code
  defp mark_executed(%{exit_code: _} = stmt, code), do: %{stmt | exit_code: code}
  defp mark_executed(stmt, _code), do: stmt

  # Execute EXIT trap if one is set
  # The EXIT trap runs when the shell exits (script finishes)
  defp execute_exit_trap(session_state) do
    # Skip if already executing a trap (prevent infinite recursion)
    if Map.get(session_state, :in_trap, false) do
      :ok
    else
      case Trap.get_exit_trap(session_state) do
        nil ->
          :ok

        :ignore ->
          :ok

        trap_command when is_binary(trap_command) ->
          # Parse and execute the trap command
          case Parser.parse(trap_command) do
            {:ok, ast} ->
              # Execute trap with in_trap flag to prevent recursion
              trap_session = Map.put(session_state, :in_trap, true)
              Helpers.execute_body(ast.statements, trap_session, %{})

            {:error, _, _, _} ->
              :ok
          end
      end
    end
  end

  # Execute statements sequentially, accumulating results
  defp execute_statements([], _session_state, executed, last_exit_code, output, updates) do
    {Enum.reverse(executed), last_exit_code, output, updates, :ok}
  end

  defp execute_statements(
         [{:separator, _} = sep | rest],
         session_state,
         executed,
         last_exit_code,
         output,
         updates
       ) do
    # Keep separators as-is
    execute_statements(rest, session_state, [sep | executed], last_exit_code, output, updates)
  end

  defp execute_statements(
         [%AST.Comment{} = comment | rest],
         session_state,
         executed,
         last_exit_code,
         output,
         updates
       ) do
    # Keep comments as-is
    execute_statements(rest, session_state, [comment | executed], last_exit_code, output, updates)
  end

  defp execute_statements(
         [stmt | rest],
         session_state,
         executed,
         _last_exit_code,
         output,
         updates
       ) do
    # Apply accumulated updates to session state for this statement
    updated_session = apply_updates_to_session(session_state, updates)

    # Check if noexec (-n) is enabled - if so, skip execution
    if noexec_enabled?(updated_session) do
      # In noexec mode, read but don't execute - continue with exit code 0
      execute_statements(rest, session_state, [stmt | executed], 0, output, updates)
    else
      case Executor.execute(stmt, updated_session, nil) do
        {:ok, executed_stmt, stmt_updates} ->
          new_output = output ++ extract_output(executed_stmt)
          new_updates = merge_state_updates(updates, stmt_updates)
          exit_code = Map.get(executed_stmt, :exit_code, 0)
          # Update $? special variable for subsequent statements
          new_updates = add_exit_code_update(new_updates, exit_code)
          # Update PIPESTATUS for subsequent statements
          new_updates = add_pipestatus_update(new_updates, executed_stmt, exit_code)

          # Check errexit: if enabled and command failed, stop execution
          # Check onecmd (-t): if enabled, exit after executing one command
          # Pass stmt_updates to onecmd_triggered? to avoid triggering on the command that sets it
          cond do
            errexit_triggered?(exit_code, new_updates, updated_session) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            onecmd_triggered?(new_updates, updated_session, stmt_updates) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            true ->
              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                exit_code,
                new_output,
                new_updates
              )
          end

        {:ok, executed_stmt} ->
          new_output = output ++ extract_output(executed_stmt)
          exit_code = Map.get(executed_stmt, :exit_code, 0)
          # Update $? special variable for subsequent statements
          new_updates = add_exit_code_update(updates, exit_code)
          # Update PIPESTATUS for subsequent statements
          new_updates = add_pipestatus_update(new_updates, executed_stmt, exit_code)

          # Check errexit: if enabled and command failed, stop execution
          # Check onecmd (-t): if enabled, exit after executing one command
          cond do
            errexit_triggered?(exit_code, new_updates, updated_session) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            onecmd_triggered?(new_updates, updated_session) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            true ->
              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                exit_code,
                new_output,
                new_updates
              )
          end

        {:exit, executed_stmt} ->
          # Exit control flow - stop execution and return
          new_output = output ++ extract_output(executed_stmt)
          exit_code = Map.get(executed_stmt, :exit_code, 0)

          {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output, updates,
           :exit}

        {:exec, executed_stmt} ->
          # Exec control flow - stop execution and return (shell replacement)
          new_output = output ++ extract_output(executed_stmt)
          exit_code = Map.get(executed_stmt, :exit_code, 0)

          {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output, updates,
           :exec}

        {:error, executed_stmt} ->
          # Error - check errexit, onecmd, or continue
          new_output = output ++ extract_output(executed_stmt)
          exit_code = Map.get(executed_stmt, :exit_code, 1)
          # Update $? special variable for subsequent statements
          new_updates = add_exit_code_update(updates, exit_code)

          cond do
            errexit_triggered?(exit_code, new_updates, updated_session) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            onecmd_triggered?(new_updates, updated_session) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            true ->
              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                exit_code,
                new_output,
                new_updates
              )
          end

        {:error, executed_stmt, stmt_updates} ->
          new_output = output ++ extract_output(executed_stmt)
          new_updates = merge_state_updates(updates, stmt_updates)
          exit_code = Map.get(executed_stmt, :exit_code, 1)
          # Update $? special variable for subsequent statements
          new_updates = add_exit_code_update(new_updates, exit_code)

          cond do
            errexit_triggered?(exit_code, new_updates, updated_session) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            onecmd_triggered?(new_updates, updated_session, stmt_updates) ->
              {Enum.reverse([executed_stmt | executed]) ++ rest, exit_code, new_output,
               new_updates, :exit}

            true ->
              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                exit_code,
                new_output,
                new_updates
              )
          end

        # Job control builtins - handle based on sync vs async behavior
        # wait and fg are async (need to wait for jobs) - stop execution
        # Mark statement as executed (exit_code: 0) so continuation doesn't re-run it
        {:wait_for_jobs, _job_specs} = wait_result ->
          executed_stmt = mark_executed(stmt, 0)
          all_stmts = Enum.reverse([executed_stmt | executed]) ++ rest
          {all_stmts, 0, output, updates, wait_result}

        {:foreground_job, _job_number} = fg_result ->
          executed_stmt = mark_executed(stmt, 0)
          {Enum.reverse([executed_stmt | executed]) ++ rest, 0, output, updates, fg_result}

        # kill sends signals immediately via callback
        {:signal_jobs, signal, targets} ->
          case Map.get(session_state, :signal_jobs_fn) do
            nil ->
              # No callback - fall back to deferred execution (legacy path)
              new_updates =
                Map.update(
                  updates,
                  :pending_signals,
                  [{signal, targets}],
                  &[
                    {signal, targets} | &1
                  ]
                )

              executed_stmt = mark_executed(stmt, 0)

              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                0,
                output,
                new_updates
              )

            signal_fn when is_function(signal_fn, 3) ->
              # Send signals immediately
              exit_code =
                case signal_fn.(signal, targets, session_state) do
                  {:ok, code} -> code
                  {:error, code, _msg} -> code
                end

              executed_stmt = mark_executed(stmt, exit_code)

              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                exit_code,
                output,
                updates
              )
          end

        {:background_job, job_numbers} ->
          # Store for Session to handle after script completes, continue execution
          new_updates = Map.update(updates, :pending_bg_jobs, [job_numbers], &[job_numbers | &1])
          executed_stmt = mark_executed(stmt, 0)

          execute_statements(
            rest,
            session_state,
            [executed_stmt | executed],
            0,
            output,
            new_updates
          )

        # Background command - start job immediately to get $! before continuing
        {:background, foreground_ast, bg_session_state} ->
          # Try to use the callback to start the job immediately
          case Map.get(session_state, :start_background_job_fn) do
            nil ->
              # No callback - fall back to deferred execution (legacy path)
              bg_updates = Map.put(updates, :pending_background, foreground_ast)
              executed_stmt = mark_executed(stmt, 0)

              execute_statements(
                rest,
                session_state,
                [executed_stmt | executed],
                0,
                output,
                bg_updates
              )

            start_bg_fn when is_function(start_bg_fn, 2) ->
              # Start the background job immediately to get the PID for $!
              case start_bg_fn.(foreground_ast, bg_session_state) do
                {:ok, _os_pid_str, updated_session_state, job_state_updates} ->
                  # Merge job state updates into the accumulated updates
                  merged_updates = Map.merge(updates, job_state_updates)
                  # Mark statement as executed so continuation doesn't re-run it
                  executed_stmt = mark_executed(stmt, 0)
                  # Continue with updated session_state that has $! set
                  execute_statements(
                    rest,
                    updated_session_state,
                    [executed_stmt | executed],
                    0,
                    output,
                    merged_updates
                  )

                {:error, _reason} ->
                  # Job failed to start, continue with exit code 1
                  executed_stmt = mark_executed(stmt, 1)

                  execute_statements(
                    rest,
                    session_state,
                    [executed_stmt | executed],
                    1,
                    output,
                    updates
                  )
              end
          end
      end
    end
  end

  # Add exit code to special_vars updates
  defp add_exit_code_update(updates, exit_code) do
    special_vars_updates = Map.get(updates, :special_vars_updates, %{})
    new_special_vars = Map.put(special_vars_updates, "?", exit_code)
    Map.put(updates, :special_vars_updates, new_special_vars)
  end

  # Add PIPESTATUS update based on the executed statement
  defp add_pipestatus_update(updates, %Pipeline{pipestatus: pipestatus}, _exit_code)
       when is_list(pipestatus) do
    pipestatus_var = build_pipestatus_var(pipestatus)
    var_updates = Map.get(updates, :var_updates, %{})
    new_var_updates = Map.put(var_updates, "PIPESTATUS", pipestatus_var)
    Map.put(updates, :var_updates, new_var_updates)
  end

  defp add_pipestatus_update(updates, _executed_stmt, exit_code) do
    # For non-pipeline statements, PIPESTATUS is single element [exit_code]
    pipestatus_var = build_pipestatus_var([exit_code])
    var_updates = Map.get(updates, :var_updates, %{})
    new_var_updates = Map.put(var_updates, "PIPESTATUS", pipestatus_var)
    Map.put(updates, :var_updates, new_var_updates)
  end

  defp build_pipestatus_var(exit_codes) do
    indexed_values =
      exit_codes
      |> Enum.with_index()
      |> Map.new(fn {code, idx} -> {idx, Integer.to_string(code)} end)

    Variable.new_indexed_array(indexed_values)
  end

  # Check if noexec (-n) option is enabled
  defp noexec_enabled?(state) do
    Map.get(state, :options, %{})[:noexec] == true
  end

  # Check if errexit should trigger based on exit code and options
  defp errexit_triggered?(0, _updates, _state), do: false

  defp errexit_triggered?(exit_code, updates, state) when exit_code != 0 do
    # errexit only triggers on non-zero exit codes
    # Merge options from updates (more recent) with session state
    merged_options = Map.merge(Map.get(state, :options, %{}), updates[:options] || %{})

    Map.get(merged_options, :errexit, false) == true
  end

  # Check if onecmd (-t) should trigger exit after this command
  # The stmt_updates parameter is the updates from the current statement only,
  # used to avoid triggering exit for the command that sets onecmd (like `set -t`)
  defp onecmd_triggered?(updates, session_state, stmt_updates \\ %{}) do
    # Check if this statement just set onecmd - if so, don't trigger yet
    stmt_options = Map.get(stmt_updates, :options, %{})
    just_set_onecmd = Map.get(stmt_options, :onecmd, nil) == true

    if just_set_onecmd do
      # Don't trigger for the command that sets onecmd
      false
    else
      # Check options from updates first (more recent), then session state
      options_from_updates = Map.get(updates, :options, %{})
      options_from_session = Map.get(session_state, :options, %{})
      merged_options = Map.merge(options_from_session, options_from_updates)
      Map.get(merged_options, :onecmd, false) == true
    end
  end

  defp extract_output(%{output: output}) when is_list(output), do: output
  defp extract_output(_), do: []

  # Merge state updates from a statement into accumulated updates
  # Handles env_updates, var_updates, and function_updates specially by merging the inner maps
  defp merge_state_updates(acc, stmt_updates) when map_size(stmt_updates) == 0, do: acc

  defp merge_state_updates(acc, stmt_updates) do
    # Get the new var_updates from this statement
    new_var_updates = Map.get(stmt_updates, :var_updates, %{})

    # Merge env_updates by combining the inner maps
    # BUT: remove keys that are in the new var_updates, since a variable assignment
    # should override stale env_updates from previous arithmetic expressions
    acc_env_updates = Map.get(acc, :env_updates, %{})
    cleaned_acc_env = Map.drop(acc_env_updates, Map.keys(new_var_updates))
    env_updates = Map.merge(cleaned_acc_env, Map.get(stmt_updates, :env_updates, %{}))

    # Merge var_updates by combining the inner maps
    var_updates =
      Map.merge(
        Map.get(acc, :var_updates, %{}),
        new_var_updates
      )

    # Merge function_updates by combining the inner maps
    function_updates =
      Map.merge(
        Map.get(acc, :function_updates, %{}),
        Map.get(stmt_updates, :function_updates, %{})
      )

    # Merge options by combining the inner maps
    options =
      Map.merge(
        Map.get(acc, :options, %{}),
        Map.get(stmt_updates, :options, %{})
      )

    # Merge special_vars_updates by combining the inner maps
    special_vars_updates =
      Map.merge(
        Map.get(acc, :special_vars_updates, %{}),
        Map.get(stmt_updates, :special_vars_updates, %{})
      )

    # For other keys, the later value wins (like clear_history, working_dir, etc.)
    merged = Map.merge(acc, stmt_updates)

    # Put the merged updates back
    merged =
      if map_size(env_updates) > 0 do
        Map.put(merged, :env_updates, env_updates)
      else
        Map.delete(merged, :env_updates)
      end

    merged =
      if map_size(var_updates) > 0 do
        Map.put(merged, :var_updates, var_updates)
      else
        Map.delete(merged, :var_updates)
      end

    merged =
      if map_size(function_updates) > 0 do
        Map.put(merged, :function_updates, function_updates)
      else
        Map.delete(merged, :function_updates)
      end

    merged =
      if map_size(options) > 0 do
        Map.put(merged, :options, options)
      else
        Map.delete(merged, :options)
      end

    if map_size(special_vars_updates) > 0 do
      Map.put(merged, :special_vars_updates, special_vars_updates)
    else
      Map.delete(merged, :special_vars_updates)
    end
  end

  # Apply accumulated updates to session state for subsequent statements
  defp apply_updates_to_session(session_state, updates) do
    alias Bash.Variable

    env_updates = Map.get(updates, :env_updates, %{})
    var_updates = Map.get(updates, :var_updates, %{})
    function_updates = Map.get(updates, :function_updates, %{})
    options_updates = Map.get(updates, :options, nil)
    special_vars_updates = Map.get(updates, :special_vars_updates, %{})
    positional_params_updates = Map.get(updates, :positional_params, nil)
    working_dir_update = Map.get(updates, :working_dir, nil)

    # Convert env_updates (string values) to Variable structs
    env_vars = Map.new(env_updates, fn {k, v} -> {k, Variable.new(v)} end)

    # Merge both types of updates (var_updates are already Variable structs)
    # Apply env_vars LAST since they may come from arithmetic statements that
    # update variables after initial assignments (e.g., z=10; ((z+=5)))
    new_variables =
      session_state.variables
      |> Map.merge(var_updates)
      |> Map.merge(env_vars)

    # Merge function_updates
    new_functions = Map.merge(Map.get(session_state, :functions, %{}), function_updates)

    # Merge options if present
    new_options =
      if options_updates do
        Map.merge(Map.get(session_state, :options, %{}), options_updates)
      else
        Map.get(session_state, :options, %{})
      end

    # Merge special_vars (like $?)
    new_special_vars =
      Map.merge(Map.get(session_state, :special_vars, %{}), special_vars_updates)

    # Update positional_params if present (replaces entirely, doesn't merge)
    new_positional_params =
      if positional_params_updates do
        positional_params_updates
      else
        Map.get(session_state, :positional_params, [[]])
      end

    # Update working_dir if present (from cd builtin)
    new_working_dir =
      if working_dir_update do
        working_dir_update
      else
        Map.get(session_state, :working_dir)
      end

    # Update traps if present (from trap builtin)
    traps_updates = Map.get(updates, :traps, nil)

    new_traps =
      if traps_updates do
        traps_updates
      else
        Map.get(session_state, :traps, %{})
      end

    # Update dir_stack if present (from pushd/popd builtins)
    dir_stack_update = Map.get(updates, :dir_stack, nil)

    new_dir_stack =
      if dir_stack_update do
        dir_stack_update
      else
        Map.get(session_state, :dir_stack, [])
      end

    session_state
    |> maybe_update(:variables, new_variables, session_state.variables)
    |> maybe_update(:functions, new_functions, Map.get(session_state, :functions, %{}))
    |> maybe_update(:options, new_options, Map.get(session_state, :options, %{}))
    |> maybe_update(:special_vars, new_special_vars, Map.get(session_state, :special_vars, %{}))
    |> maybe_update(
      :positional_params,
      new_positional_params,
      Map.get(session_state, :positional_params, [[]])
    )
    |> maybe_update(:working_dir, new_working_dir, Map.get(session_state, :working_dir))
    |> maybe_update(:traps, new_traps, Map.get(session_state, :traps, %{}))
    |> maybe_update(:dir_stack, new_dir_stack, Map.get(session_state, :dir_stack, []))
  end

  defp maybe_update(state, key, new_value, old_value) do
    if new_value == old_value do
      state
    else
      Map.put(state, key, new_value)
    end
  end

  @doc """
  Get exit code from the last evaluated statement.
  Returns nil if no statements have been evaluated.
  """
  @spec exit_code(t()) :: 0..255 | nil
  def exit_code(%__MODULE__{statements: statements}) do
    statements
    |> Enum.reject(&separator?/1)
    |> Enum.filter(&evaluated?/1)
    |> List.last()
    |> case do
      nil -> nil
      stmt -> Map.get(stmt, :exit_code)
    end
  end

  @doc """
  Filter to only evaluated statements (no separators, only statements with evaluated: true).
  """
  @spec evaluated_statements(t()) :: [map()]
  def evaluated_statements(%__MODULE__{statements: statements}) do
    statements
    |> Enum.reject(&separator?/1)
    |> Enum.filter(&evaluated?/1)
  end

  # Check if an item is a separator tuple
  defp separator?({:separator, _}), do: true
  defp separator?(_), do: false

  # Check if a statement has been evaluated
  defp evaluated?(%{meta: %AST.Meta{evaluated: true}}), do: true
  defp evaluated?(_), do: false

  defimpl String.Chars do
    def to_string(%{shebang: shebang, statements: statements}) do
      body =
        Enum.map_join(statements, "", fn
          {:separator, ";"} -> "; "
          {:separator, sep} -> sep
          node -> Kernel.to_string(node)
        end)

      # Only add trailing newline if the last item is a separator and it's a newline
      # or if the script contains newline separators (not just semicolons)
      has_newline_sep =
        Enum.any?(statements, fn
          {:separator, "\n"} -> true
          _ -> false
        end)

      body =
        case {List.last(statements), has_newline_sep} do
          {{:separator, "\n"}, _} -> body
          {_, true} -> body <> "\n"
          _ -> body
        end

      # Prepend shebang if present
      case shebang do
        nil -> body
        interpreter -> "#!#{interpreter}\n#{body}"
      end
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    @max_visible_elements 10

    def inspect(%{statements: statements, exit_code: exit_code}, opts) do
      # Filter out separators for display
      nodes = Enum.reject(statements, &match?({:separator, _}, &1))
      node_count = length(nodes)

      # Build header
      header = build_header(node_count, exit_code, opts)

      if node_count == 0 do
        header
      else
        # Build tree structure
        tree = build_tree(nodes, opts)
        concat([header, tree])
      end
    end

    defp build_header(node_count, exit_code, opts) do
      base = concat(["#Script(", color("#{node_count}", :number, opts), " nodes)"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end

    defp build_tree(nodes, opts) do
      visible = Enum.take(nodes, @max_visible_elements)
      hidden_count = length(nodes) - length(visible)

      tree_lines =
        visible
        |> Enum.with_index()
        |> Enum.map(fn {node, idx} ->
          is_last = idx == length(visible) - 1 and hidden_count == 0
          connector = if is_last, do: "└── ", else: "├── "
          node_str = node_summary(node, opts)
          concat([line(), connector, node_str])
        end)

      # Add "...and N more" if truncated
      tree_lines =
        if hidden_count > 0 do
          more_line = concat([line(), "└── ", color("...and #{hidden_count} more", :faint, opts)])
          tree_lines ++ [more_line]
        else
          tree_lines
        end

      concat([concat(["<"] ++ tree_lines), line(), ">"])
    end

    defp node_summary(node, opts) do
      {type, summary, exit_code} = extract_node_info(node)

      base =
        if summary do
          concat([color("[#{type}]", :atom, opts), " ", summary])
        else
          color("[#{type}]", :atom, opts)
        end

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end

    defp extract_node_info(%AST.Command{name: name, exit_code: exit_code}) do
      cmd_name = Kernel.to_string(name)
      {"command", cmd_name, exit_code}
    end

    defp extract_node_info(%AST.Pipeline{commands: cmds, negate: negate, exit_code: exit_code}) do
      prefix = if negate, do: "!", else: ""
      {"pipeline", "#{prefix}#{length(cmds)} commands", exit_code}
    end

    defp extract_node_info(%AST.Assignment{name: name, exit_code: exit_code}) do
      {"assignment", name, exit_code}
    end

    defp extract_node_info(%AST.ArrayAssignment{name: name, exit_code: exit_code}) do
      {"array", name, exit_code}
    end

    defp extract_node_info(%AST.If{
           elif_clauses: elifs,
           else_body: else_body,
           exit_code: exit_code
         }) do
      branch_count = 1 + length(elifs) + if(else_body, do: 1, else: 0)
      {"if", "#{branch_count} branches", exit_code}
    end

    defp extract_node_info(%AST.ForLoop{variable: var, items: items, exit_code: exit_code}) do
      {"for", "#{var} in #{length(items)} items", exit_code}
    end

    defp extract_node_info(%AST.WhileLoop{exit_code: exit_code}) do
      {"while", nil, exit_code}
    end

    defp extract_node_info(%AST.Case{word: word, exit_code: exit_code}) do
      {"case", Kernel.to_string(word), exit_code}
    end

    defp extract_node_info(%AST.Compound{kind: kind, exit_code: exit_code}) do
      {"compound", Atom.to_string(kind), exit_code}
    end

    defp extract_node_info(%AST.Arithmetic{expression: expr, exit_code: exit_code}) do
      truncated = String.slice(expr, 0..20)
      summary = if String.length(expr) > 20, do: "#{truncated}...", else: expr
      {"arithmetic", summary, exit_code}
    end

    defp extract_node_info(%AST.TestExpression{exit_code: exit_code}) do
      {"test", "[[...]]", exit_code}
    end

    defp extract_node_info(%AST.TestCommand{exit_code: exit_code}) do
      {"test", "[...]", exit_code}
    end

    defp extract_node_info(%AST.Comment{text: text}) do
      truncated = String.slice(text, 0..30)
      summary = if String.length(text) > 30, do: "#{truncated}...", else: text
      {"comment", summary, nil}
    end

    defp extract_node_info(%{__struct__: module, exit_code: exit_code}) do
      type = module |> Module.split() |> List.last() |> Macro.underscore()
      {type, nil, exit_code}
    end

    defp extract_node_info(%{__struct__: module}) do
      type = module |> Module.split() |> List.last() |> Macro.underscore()
      {type, nil, nil}
    end

    defp extract_node_info(_) do
      {"unknown", nil, nil}
    end
  end
end
