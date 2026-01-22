defmodule Bash.Executor do
  @moduledoc """
  Executes parsed Bash AST nodes within session context.

  This module dispatches AST node execution to the appropriate module's
  `execute/3` function, handling session state like environment variables
  and working directory.
  """

  alias Bash.AST
  alias Bash.CommandResult
  alias Bash.Function
  alias Bash.Script

  @doc """
  Executes a command AST or list of ASTs within session state.
  Optionally accepts stdin input for piped commands.

  ## Options

    * `:sink` - Output sink function for streaming. When provided, output is
      streamed to the sink instead of accumulated in the result.

  ## Examples

      # Execute a single command
      session_state = %Session{...}
      ast = %AST.Command{...}
      {:ok, result, state_updates} = Executor.execute(ast, session_state)

      # Execute a list of ASTs
      asts = [%AST.Assignment{...}, %AST.Command{...}]
      {:ok, result, state_updates} = Executor.execute(asts, session_state)

      # Execute with streaming output
      sink = Bash.Sink.Passthrough.new(fn chunk -> IO.write(elem(chunk, 1)) end)
      Executor.execute(ast, session_state, nil, sink: sink)

  """
  def execute(ast_or_list, session_state, stdin \\ nil, opts \\ [])

  def execute(asts, session_state, stdin, opts) when is_list(asts) do
    Enum.reduce_while(asts, {:ok, nil, session_state}, fn ast, {_, _, current_state} ->
      case execute(ast, current_state, stdin, opts) do
        {:ok, result, updated_state} ->
          {:cont, {:ok, result, updated_state}}

        {:ok, result} ->
          {:cont, {:ok, result, current_state}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  def execute(%AST.Pipeline{} = ast, session_state, stdin, opts) do
    AST.Pipeline.execute(ast, stdin, session_state, opts)
  end

  def execute(%AST.Comment{}, _session_state, _stdin, _opts) do
    {:ok, %CommandResult{command: "comment", exit_code: 0}, %{}}
  end

  def execute(%mod{} = ast, session_state, stdin, _opts)
      when mod in [
             AST.Arithmetic,
             AST.ArrayAssignment,
             AST.Assignment,
             AST.Case,
             AST.Command,
             AST.Compound,
             AST.ForLoop,
             Function,
             AST.If,
             Script,
             AST.TestCommand,
             AST.TestExpression,
             AST.WhileLoop
           ] do
    mod.execute(ast, stdin, session_state)
  end

  def execute(token, _session_state, _stdin, _opts) do
    {:error, {:invalid_ast, token}}
  end
end
