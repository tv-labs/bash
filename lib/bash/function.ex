defmodule Bash.AST.Function do
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
  alias Bash.CommandResult
  alias Bash.Executor
  alias Bash.Statement

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: String.t(),
          body: Statement.t(),
          exported: boolean(),
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :name,
    :body,
    exported: false,
    exit_code: nil,
    state_updates: %{}
  ]

  @doc false
  def execute(%__MODULE__{name: name, body: body, meta: meta} = ast, _stdin, _session_state) do
    started_at = DateTime.utc_now()

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

  # Call a function with the given arguments.
  #
  # Bash uses dynamic scoping: variables set inside a function (without `local`)
  # are global and visible to the caller after return. Variables declared with
  # `local` are discarded when the function returns.
  #
  # Prefix/temp bindings (e.g., `X=val func`) create a scope layer that is
  # saved and can be restored by `unset` within the function.
  @doc false
  def call(func_def, args, session_state, opts \\ []) do
    current_params = Map.get(session_state, :positional_params, [[]])
    inherited_traps = build_inherited_traps(session_state)

    caller_line = Keyword.get(opts, :caller_line, 0)
    source_file = Map.get(session_state.special_vars, "0", "bash")
    current_stack = Map.get(session_state, :call_stack, [])

    frame = %{
      line_number: caller_line,
      function_name: Map.get(session_state, :current_function_name, "main"),
      source_file: source_file
    }

    pre_call_vars = Keyword.get(opts, :pre_prefix_vars) || session_state.variables
    pre_call_funcs = session_state.functions
    pre_call_working_dir = session_state.working_dir

    # Build save frame for prefix/temp bindings so `unset` can restore them
    save_frame =
      if Keyword.get(opts, :pre_prefix_vars) do
        pre_call_vars
        |> Map.filter(fn {name, _var} ->
          Map.get(session_state.variables, name) != Map.get(pre_call_vars, name)
        end)
      else
        %{}
      end

    current_saved = Map.get(session_state, :saved_vars, [])

    func_state = %{
      session_state
      | in_function: true,
        current_function_name: func_def.name,
        positional_params: [args | current_params],
        traps: inherited_traps,
        call_stack: [frame | current_stack],
        local_vars: MapSet.new(),
        saved_vars: [save_frame | current_saved]
    }

    executable_body = Enum.reject(func_def.body, &match?({:separator, _}, &1))
    result = execute_body(executable_body, func_state, nil)

    case result do
      {:return, exit_code, final_state} ->
        state_updates =
          collect_global_updates(final_state, pre_call_vars, pre_call_funcs, pre_call_working_dir)

        {:ok,
         %CommandResult{
           command: func_def.name,
           exit_code: exit_code,
           error: nil
         }, state_updates}

      {:ok, last_result, final_state} ->
        state_updates =
          collect_global_updates(final_state, pre_call_vars, pre_call_funcs, pre_call_working_dir)

        {:ok, last_result, state_updates}

      {:error, error_result, final_state} ->
        state_updates =
          collect_global_updates(final_state, pre_call_vars, pre_call_funcs, pre_call_working_dir)

        {:error, error_result, state_updates}

      {:exit, exit_result, final_state} ->
        state_updates =
          collect_global_updates(final_state, pre_call_vars, pre_call_funcs, pre_call_working_dir)

        {:exit, exit_result, state_updates}
    end
  end

  defp build_inherited_traps(session_state) do
    options = Map.get(session_state, :options, %{})

    errtrace_enabled = Map.get(options, :errtrace, false)
    functrace_enabled = Map.get(options, :functrace, false)

    inherited = %{}

    inherited =
      if errtrace_enabled do
        case Trap.get_err_trap(session_state) do
          nil -> inherited
          err_trap -> Map.put(inherited, "ERR", err_trap)
        end
      else
        inherited
      end

    inherited =
      if functrace_enabled do
        case Trap.get_debug_trap(session_state) do
          nil -> inherited
          debug_trap -> Map.put(inherited, "DEBUG", debug_trap)
        end
      else
        inherited
      end

    if functrace_enabled do
      case Trap.get_return_trap(session_state) do
        nil -> inherited
        return_trap -> Map.put(inherited, "RETURN", return_trap)
      end
    else
      inherited
    end
  end

  defp execute_body([], state, last_result) do
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
        {:return, exit_code, state}

      {:ok, result} ->
        if is_return_command?(result) do
          {:return, result.exit_code, state}
        else
          execute_body(rest, state, result)
        end

      {:ok, result, state_updates} ->
        if is_return_command?(result) do
          {:return, result.exit_code, state}
        else
          updated_state = apply_state_updates(state, state_updates)
          execute_body(rest, updated_state, result)
        end

      {:return, result} ->
        {:return, result.exit_code || 0, state}

      {:return, result, _state_updates} ->
        {:return, result.exit_code || 0, state}

      {:error, result} ->
        {:error, result, state}

      {:error, result, state_updates} ->
        updated_state = apply_state_updates(state, state_updates)
        {:error, result, updated_state}

      {:exit, result} ->
        {:exit, result, state}

      {:exit, result, state_updates} ->
        updated_state = apply_state_updates(state, state_updates)
        {:exit, result, updated_state}
    end
  end

  defp collect_global_updates(final_state, pre_call_vars, pre_call_funcs, pre_call_working_dir) do
    local_vars = Map.get(final_state, :local_vars, MapSet.new())

    changed_vars =
      final_state.variables
      |> Enum.reject(fn {name, _} -> MapSet.member?(local_vars, name) end)
      |> Enum.filter(fn {name, var} -> Map.get(pre_call_vars, name) != var end)
      |> Map.new()

    unset_vars =
      pre_call_vars
      |> Map.keys()
      |> Enum.reject(fn name -> MapSet.member?(local_vars, name) end)
      |> Enum.reject(fn name -> Map.has_key?(final_state.variables, name) end)
      |> Map.new(fn name -> {name, nil} end)

    var_updates = Map.merge(changed_vars, unset_vars)

    func_changes =
      final_state.functions
      |> Enum.filter(fn {name, func} -> Map.get(pre_call_funcs, name) != func end)
      |> Map.new()

    updates = %{}

    updates =
      if map_size(var_updates) > 0,
        do: Map.put(updates, :variables, var_updates),
        else: updates

    updates =
      if map_size(func_changes) > 0,
        do: Map.put(updates, :function_updates, func_changes),
        else: updates

    if final_state.working_dir != pre_call_working_dir,
      do: Map.put(updates, :working_dir, final_state.working_dir),
      else: updates
  end

  defp apply_state_updates(state, updates) do
    state
    |> maybe_update_working_dir(updates)
    |> maybe_update_variables(updates)
    |> maybe_update_functions(updates)
    |> maybe_update_positional_params(updates)
    |> maybe_update_local_vars(updates)
    |> maybe_push_save_frame(updates)
  end

  defp maybe_update_working_dir(state, %{working_dir: new_dir}) do
    %{state | working_dir: new_dir}
  end

  defp maybe_update_working_dir(state, _), do: state

  defp maybe_update_variables(state, %{variables: variables}) do
    new_variables =
      state.variables
      |> Map.merge(variables)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %{state | variables: new_variables}
  end

  defp maybe_update_variables(state, _), do: state

  defp maybe_update_functions(state, %{function_updates: function_updates}) do
    new_functions =
      state.functions
      |> Map.merge(function_updates)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %{state | functions: new_functions}
  end

  defp maybe_update_functions(state, _), do: state

  defp maybe_update_positional_params(state, %{positional_params: new_params}) do
    %{state | positional_params: new_params}
  end

  defp maybe_update_positional_params(state, _), do: state

  defp maybe_update_local_vars(state, %{local_vars: new_locals}) do
    current = Map.get(state, :local_vars, MapSet.new())
    %{state | local_vars: MapSet.union(current, new_locals)}
  end

  defp maybe_update_local_vars(state, _), do: state

  defp maybe_push_save_frame(state, %{save_frame: frame}) when map_size(frame) > 0 do
    current = Map.get(state, :saved_vars, [])

    case current do
      [head | rest] ->
        %{state | saved_vars: [Map.merge(head, frame) | rest]}

      [] ->
        %{state | saved_vars: [frame]}
    end
  end

  defp maybe_push_save_frame(state, _), do: state

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
