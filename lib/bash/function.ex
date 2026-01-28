defmodule Bash.Function do
  @moduledoc """
  Function definition.

  ## Examples

      # function name { body; }
      %Function{
        name: "name",
        body: [...]
      }

      # name() { body; }
      %Function{
        name: "name",
        body: [...]
      }
  """

  alias Bash.AST
  alias Bash.Builtin.Trap
  alias Bash.Executor
  alias Bash.CommandResult
  alias Bash.Variable
  alias Bash.Statement

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: String.t(),
          body: Statement.t(),
          # Whether this function is exported (for subshells)
          exported: boolean(),
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :name,
    :body,
    # Function attributes
    exported: false,
    # Execution results
    exit_code: nil,
    state_updates: %{}
  ]

  @doc """
  Execute a function definition.

  When a function is defined, we store it in the session's functions map.
  This doesn't execute the function body - it just registers the function.
  """
  def execute(%__MODULE__{name: name, body: body, meta: meta} = ast, _stdin, _session_state) do
    started_at = DateTime.utc_now()

    # Create a function definition to store in session
    func_def = %__MODULE__{
      meta: nil,
      name: name,
      body: body
    }

    updates = %{function_updates: %{name => func_def}}
    completed_at = DateTime.utc_now()

    executed_ast = %{
      ast
      | exit_code: 0,
        state_updates: updates,
        meta: maybe_mark_evaluated(meta, started_at, completed_at)
    }

    {:ok, executed_ast, updates}
  end

  defp maybe_mark_evaluated(nil, _started_at, _completed_at), do: nil

  defp maybe_mark_evaluated(meta, started_at, completed_at) do
    AST.Meta.mark_evaluated(meta, started_at, completed_at)
  end

  @doc """
  Call a function with the given arguments.

  This executes the function body in a new context with the function marked as active.
  The function arguments become the positional parameters ($1, $2, etc.) within the function.

  ## Trap Inheritance

  - If `errtrace` option (`set -E`) is enabled, the ERR trap is inherited by the function
  - If `functrace` option (`set -T`) is enabled, the DEBUG trap is inherited by the function
  """
  def call(func_def, args, session_state, opts \\ []) do
    # Push args onto positional_params stack (they become $1, $2, etc.)
    current_params = Map.get(session_state, :positional_params, [[]])

    # Build inherited traps based on errtrace and functrace options
    inherited_traps = build_inherited_traps(session_state)

    # Build call stack frame from caller metadata
    caller_line = Keyword.get(opts, :caller_line, 0)
    source_file = Map.get(session_state.special_vars, "0", "bash")
    current_stack = Map.get(session_state, :call_stack, [])

    frame = %{
      line_number: caller_line,
      function_name: func_def.name,
      source_file: source_file
    }

    func_state = %{
      session_state
      | in_function: true,
        positional_params: [args | current_params],
        traps: inherited_traps,
        call_stack: [frame | current_stack]
    }

    # Execute each statement in the function body
    # If any statement is a return, stop execution early
    # Filter separators for execution (they're preserved in AST for formatting)
    executable_body = Enum.reject(func_def.body, &match?({:separator, _}, &1))
    result = execute_body(executable_body, func_state, nil)

    case result do
      {:return, exit_code, _state} ->
        # Return statement was encountered
        {:ok,
         %CommandResult{
           command: func_def.name,
           exit_code: exit_code,
           error: nil
         }}

      {:ok, last_result, _state} ->
        # Normal completion - return the last command's result
        {:ok, last_result}

      {:error, error_result, _state} ->
        # Error during execution
        {:error, error_result}

      {:exit, exit_result, _state} ->
        # errexit triggered - propagate
        {:exit, exit_result}
    end
  end

  # Build inherited traps based on errtrace and functrace options.
  #
  # When errtrace (-E) is enabled, the ERR trap is inherited by shell functions.
  # When functrace (-T) is enabled, the DEBUG trap is inherited by shell functions.
  #
  # By default, functions do NOT inherit traps (they start with an empty trap map).
  # Only with these options enabled do the specified traps propagate into functions.
  defp build_inherited_traps(session_state) do
    options = Map.get(session_state, :options, %{})

    errtrace_enabled = Map.get(options, :errtrace, false)
    functrace_enabled = Map.get(options, :functrace, false)

    # Start with empty traps (functions don't inherit by default)
    inherited = %{}

    # Add ERR trap if errtrace is enabled
    inherited =
      if errtrace_enabled do
        case Trap.get_err_trap(session_state) do
          nil -> inherited
          err_trap -> Map.put(inherited, "ERR", err_trap)
        end
      else
        inherited
      end

    # Add DEBUG trap if functrace is enabled
    inherited =
      if functrace_enabled do
        case Trap.get_debug_trap(session_state) do
          nil -> inherited
          debug_trap -> Map.put(inherited, "DEBUG", debug_trap)
        end
      else
        inherited
      end

    # Note: RETURN trap is also affected by functrace in bash, add it as well
    inherited =
      if functrace_enabled do
        case Trap.get_return_trap(session_state) do
          nil -> inherited
          return_trap -> Map.put(inherited, "RETURN", return_trap)
        end
      else
        inherited
      end

    inherited
  end

  # Execute function body statements sequentially
  # Stop early if return is encountered
  # Execute function body - output goes to sinks during execution
  defp execute_body([], state, last_result) do
    # No more statements - return the last result or a success
    result =
      last_result ||
        %CommandResult{
          command: "",
          exit_code: 0,
          error: nil
        }

    {:ok, result, state}
  end

  defp execute_body([stmt | rest], state, _last_result) do
    case Executor.execute(stmt, state) do
      {:ok, %CommandResult{command: "return", exit_code: exit_code}} ->
        # Legacy CommandResult return statement - stop execution and propagate exit code
        {:return, exit_code, state}

      {:ok, result} ->
        # Check if this is a return statement (AST node wrapping return builtin result)
        if is_return_command?(result) do
          {:return, result.exit_code, state}
        else
          # Normal statement - continue with next
          execute_body(rest, state, result)
        end

      {:ok, result, state_updates} ->
        # Check if this is a return statement with state updates
        if is_return_command?(result) do
          {:return, result.exit_code, state}
        else
          # Statement with state updates (like cd or function definitions)
          # Apply state updates by merging into struct fields
          updated_state = apply_state_updates(state, state_updates)
          execute_body(rest, updated_state, result)
        end

      {:error, result} ->
        # Error - stop execution
        {:error, result, state}

      {:error, result, state_updates} ->
        updated_state = apply_state_updates(state, state_updates)
        {:error, result, updated_state}

      {:exit, result} ->
        # errexit triggered - propagate exit
        {:exit, result, state}

      {:exit, result, state_updates} ->
        updated_state = apply_state_updates(state, state_updates)
        {:exit, result, updated_state}
    end
  end

  defp apply_state_updates(state, updates) do
    state
    |> maybe_update_working_dir(updates)
    |> maybe_update_env_vars(updates)
    |> maybe_update_var_updates(updates)
    |> maybe_update_functions(updates)
    |> maybe_update_positional_params(updates)
  end

  defp maybe_update_working_dir(state, %{working_dir: new_dir}) do
    %{state | working_dir: new_dir}
  end

  defp maybe_update_working_dir(state, _), do: state

  defp maybe_update_env_vars(state, %{env_updates: env_updates}) do
    new_variables =
      Map.merge(
        state.variables,
        Map.new(env_updates, fn {k, v} -> {k, Variable.new(v)} end)
      )

    %{state | variables: new_variables}
  end

  defp maybe_update_env_vars(state, _), do: state

  defp maybe_update_var_updates(state, %{var_updates: var_updates}) do
    new_variables =
      state.variables
      |> Map.merge(var_updates)
      |> Map.reject(fn {_k, v} -> v == :deleted end)

    %{state | variables: new_variables}
  end

  defp maybe_update_var_updates(state, _), do: state

  defp maybe_update_functions(state, %{function_updates: function_updates}) do
    new_functions =
      state.functions
      |> Map.merge(function_updates)
      |> Map.reject(fn {_k, v} -> v == :deleted end)

    %{state | functions: new_functions}
  end

  defp maybe_update_functions(state, _), do: state

  defp maybe_update_positional_params(state, %{positional_params: new_params}) do
    %{state | positional_params: new_params}
  end

  defp maybe_update_positional_params(state, _), do: state

  # Check if a result is from a "return" command
  # Works with both legacy CommandResult and AST nodes
  defp is_return_command?(%CommandResult{command: "return"}), do: true

  defp is_return_command?(%AST.Command{name: %AST.Word{parts: [{:literal, "return"}]}}), do: true

  defp is_return_command?(_), do: false

  defimpl String.Chars do
    def to_string(%{name: name, body: body}) do
      body_str =
        body
        |> Enum.reject(&match?({:separator, _}, &1))
        |> Enum.map(&Kernel.to_string/1)
        |> Enum.join("\n  ")

      "function #{name} {\n  #{body_str}\n}"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{name: name, exit_code: exit_code}, opts) do
      base = concat(["#Function{", color(name, :atom, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
