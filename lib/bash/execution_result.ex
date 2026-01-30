defprotocol Bash.ExecutionResult do
  @moduledoc """
  Protocol for extracting execution results from various result types.

  This protocol provides a unified interface for both:
  - CommandResult structs (which still have output for external commands)
  - AST nodes with embedded execution results (output goes to sinks)

  Note: stdout/stderr/all_output functions return results from the collector
  for Script types, and empty strings for AST nodes since output goes to sinks.
  """

  @doc "Get stdout output as a string"
  @spec stdout(t) :: String.t()
  def stdout(result)

  @doc "Get stderr output as a string"
  @spec stderr(t) :: String.t()
  def stderr(result)

  @doc "Get all output as a string"
  @spec all_output(t) :: String.t()
  def all_output(result)

  @doc "Get exit code"
  @spec exit_code(t) :: non_neg_integer() | nil
  def exit_code(result)

  @doc "Check if execution was successful (exit code 0)"
  @spec success?(t) :: boolean()
  def success?(result)
end

# Implementation for CommandResult
# Note: Output goes to sinks during execution, not accumulated in CommandResult
defimpl Bash.ExecutionResult, for: Bash.CommandResult do
  alias Bash.CommandResult

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: CommandResult.success?(result)
end

# Implementation for AST.Command
defimpl Bash.ExecutionResult, for: Bash.AST.Command do
  alias Bash.AST

  def stdout(result), do: AST.stdout(result)
  def stderr(result), do: AST.stderr(result)
  def all_output(result), do: AST.all_output(result)
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.Pipeline
# Note: Pipeline has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.Pipeline do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.Compound
# Note: Compound has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.Compound do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.If
# Note: If has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.If do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.ForLoop
# Note: ForLoop has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.ForLoop do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.WhileLoop
# Note: WhileLoop has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.WhileLoop do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.Case
# Note: Case has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.Case do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.Assignment
# Note: Assignment has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.Assignment do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.ArrayAssignment
# Note: ArrayAssignment has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.ArrayAssignment do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.TestExpression
# Note: TestExpression has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.TestExpression do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.TestCommand
# Note: TestCommand has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.TestCommand do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for AST.Arithmetic
# Note: Arithmetic has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.Arithmetic do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for Function
# Note: Function has no output field - output goes to sinks
defimpl Bash.ExecutionResult, for: Bash.AST.Function do
  alias Bash.AST

  def stdout(_result), do: ""
  def stderr(_result), do: ""
  def all_output(_result), do: ""
  def exit_code(%{exit_code: code}), do: code
  def success?(result), do: AST.success?(result)
end

# Implementation for Script
# Script stores a collector reference - read from it to get output
defimpl Bash.ExecutionResult, for: Bash.Script do
  alias Bash.AST
  alias Bash.OutputCollector

  def stdout(%{collector: collector}) when is_pid(collector) do
    if Process.alive?(collector) do
      collector |> OutputCollector.stdout() |> IO.iodata_to_binary()
    else
      ""
    end
  end

  def stdout(_result), do: ""

  def stderr(%{collector: collector}) when is_pid(collector) do
    if Process.alive?(collector) do
      collector |> OutputCollector.stderr() |> IO.iodata_to_binary()
    else
      ""
    end
  end

  def stderr(_result), do: ""

  def all_output(%{collector: collector}) when is_pid(collector) do
    if Process.alive?(collector) do
      collector
      |> OutputCollector.chunks()
      |> Enum.map_join("", fn {_stream, data} -> data end)
    else
      ""
    end
  end

  def all_output(_result), do: ""

  def exit_code(%{exit_code: code}), do: code

  def success?(result), do: AST.success?(result)
end
