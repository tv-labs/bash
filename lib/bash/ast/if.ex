defmodule Bash.AST.If do
  @moduledoc """
  Conditional statement: if/elif/else/fi.

  ## Examples

      # if [ -f file ]; then echo exists; fi
      %If{
        condition: %Command{name: "test", args: ["-f", "file"]},
        body: [%Command{name: "echo", args: ["exists"]}],
        elif_clauses: [],
        else_body: nil
      }

      # if cmd1; then body1; elif cmd2; then body2; else body3; fi
      %If{
        condition: %Command{name: "cmd1", ...},
        body: [...],
        elif_clauses: [
          {%Command{name: "cmd2", ...}, [...]}
        ],
        else_body: [...]
      }
  """

  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.CommandResult
  alias Bash.Executor
  alias Bash.Statement
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          condition: Statement.t(),
          body: [Statement.t()],
          elif_clauses: [{Statement.t(), [Statement.t()]}],
          else_body: [Statement.t()] | nil,
          # Execution results (nil before execution)
          exit_code: 0..255 | nil,
          state_updates: map(),
          executed_branch: :then | :elif | :else | nil
        }

  defstruct [
    :meta,
    :condition,
    :body,
    elif_clauses: [],
    else_body: nil,
    # Execution results
    exit_code: nil,
    state_updates: %{},
    executed_branch: nil
  ]

  # Get exit code from the executed branch.
  @doc false
  @spec get_exit_code(t()) :: 0..255 | nil
  def get_exit_code(%__MODULE__{} = if_node) do
    case if_node.executed_branch do
      :then -> get_last_exit_code(if_node.body)
      :elif -> get_elif_exit_code(if_node.elif_clauses)
      :else -> get_last_exit_code(if_node.else_body)
      nil -> nil
    end
  end

  # Get which branch was executed.
  @doc false
  @spec executed_branch(t()) :: :then | :elif | :else | nil
  def executed_branch(%__MODULE__{executed_branch: branch}), do: branch

  defp get_last_exit_code(nil), do: nil

  defp get_last_exit_code(body) when is_list(body) do
    body
    |> List.last()
    |> case do
      nil -> nil
      stmt -> Map.get(stmt, :exit_code)
    end
  end

  defp get_elif_exit_code(elif_clauses) do
    elif_clauses
    |> Enum.find(fn {cond, _body} ->
      case cond do
        %{meta: %AST.Meta{evaluated: true}, exit_code: 0} -> true
        _ -> false
      end
    end)
    |> case do
      nil -> nil
      {_cond, body} -> get_last_exit_code(body)
    end
  end

  def execute(
        %__MODULE__{
          condition: condition,
          body: body,
          elif_clauses: elif_clauses,
          else_body: else_body
        },
        _stdin,
        session_state
      ) do
    # Execute the condition
    case Executor.execute(condition, session_state, nil) do
      {:ok, result, updates} ->
        new_variables =
          Map.merge(
            session_state.variables,
            Map.new(Map.get(updates, :env_updates, %{}), fn {k, v} -> {k, Variable.new(v)} end)
          )

        session_state = %{session_state | variables: new_variables}

        execute_if_branch(
          result.exit_code,
          body,
          elif_clauses,
          else_body,
          session_state,
          Map.get(updates, :env_updates, %{})
        )

      {:ok, result} ->
        execute_if_branch(
          result.exit_code,
          body,
          elif_clauses,
          else_body,
          session_state,
          %{}
        )

      {:error, result} ->
        # Condition failed (non-zero exit) - try elif or else
        execute_if_branch(
          result.exit_code || 1,
          body,
          elif_clauses,
          else_body,
          session_state,
          %{}
        )
    end
  end

  # Helper for if statement branch selection
  defp execute_if_branch(0, body, _elif_clauses, _else_body, session_state, env_updates) do
    Helpers.execute_body(body, session_state, env_updates)
  end

  defp execute_if_branch(_exit_code, _body, elif_clauses, else_body, session_state, env_updates) do
    # Condition failed - try elif clauses
    case try_elif_clauses(elif_clauses, session_state, env_updates) do
      {:executed, result} ->
        result

      :not_executed ->
        # No elif matched - try else
        if else_body do
          Helpers.execute_body(else_body, session_state, env_updates)
        else
          # No else clause - return success with no output
          {:ok, %CommandResult{exit_code: 0}, %{env_updates: env_updates}}
        end
    end
  end

  # Try elif clauses in order
  defp try_elif_clauses([], _session_state, _env_updates), do: :not_executed

  defp try_elif_clauses([{condition, body} | rest], session_state, env_updates) do
    case Executor.execute(condition, session_state, nil) do
      {:ok, result, updates} ->
        merged_env = Map.merge(env_updates, Map.get(updates, :env_updates, %{}))

        new_variables =
          Map.merge(
            session_state.variables,
            Map.new(merged_env, fn {k, v} -> {k, Variable.new(v)} end)
          )

        session_state = %{session_state | variables: new_variables}

        if result.exit_code == 0 do
          {:executed, Helpers.execute_body(body, session_state, merged_env)}
        else
          try_elif_clauses(rest, session_state, merged_env)
        end

      {:ok, result} ->
        if result.exit_code == 0 do
          {:executed, Helpers.execute_body(body, session_state, env_updates)}
        else
          try_elif_clauses(rest, session_state, env_updates)
        end

      {:error, _} ->
        # Condition errored (non-zero exit) - try next elif
        try_elif_clauses(rest, session_state, env_updates)
    end
  end

  alias Bash.AST.Formatter

  # Convert to Bash string with formatting context.
  @doc false
  def to_bash(
        %__MODULE__{condition: condition, body: body, elif_clauses: elifs, else_body: else_body},
        %Formatter{} = fmt
      ) do
    indent = Formatter.current_indent(fmt)
    inner_fmt = Formatter.indent(fmt)

    parts = [
      "if #{Formatter.to_bash(condition, fmt)}; then\n#{Formatter.serialize_body(body, inner_fmt)}"
    ]

    parts =
      parts ++
        Enum.map(elifs, fn {cond, elif_body} ->
          "#{indent}elif #{Formatter.to_bash(cond, fmt)}; then\n#{Formatter.serialize_body(elif_body, inner_fmt)}"
        end)

    parts =
      if else_body do
        parts ++ ["#{indent}else\n#{Formatter.serialize_body(else_body, inner_fmt)}"]
      else
        parts
      end

    Enum.join(parts, "\n") <> "\n#{indent}fi"
  end

  defimpl String.Chars do
    alias Bash.AST.Formatter

    def to_string(%Bash.AST.If{} = if_stmt) do
      Bash.AST.If.to_bash(if_stmt, Formatter.new())
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{elif_clauses: elifs, else_body: else_body, exit_code: exit_code}, opts) do
      branch_count = 1 + length(elifs) + if(else_body, do: 1, else: 0)
      base = concat(["#If{", color("#{branch_count}", :number, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
