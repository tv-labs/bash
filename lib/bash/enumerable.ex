defimpl Enumerable, for: Bash.Script do
  @moduledoc """
  Implements Enumerable for Script to allow iteration over statements.

  By default, enumerates only executable statements (filters out separators and comments).

  ## Examples

      script = %Script{statements: [cmd1, {:separator, ";"}, cmd2, %Comment{}]}

      # Iterate over executable statements only
      Enum.each(script, fn statement -> IO.inspect(statement) end)
      # => cmd1
      # => cmd2

      # Map over statements
      results = Enum.map(script, &execute_statement/1)

      # Reduce to execute all statements
      Enum.reduce(script, initial_state, fn statement, state ->
        Executable.execute(statement, "", state)
      end)
  """

  alias Bash.AST

  @doc """
  Returns the count of executable statements (excluding separators and comments).
  """
  def count(%{statements: statements}) do
    count =
      Enum.count(statements, fn
        {:separator, _} -> false
        %AST.Comment{} -> false
        _ -> true
      end)

    {:ok, count}
  end

  @doc """
  Checks if an element is a statement in the script.
  """
  def member?(%{statements: statements}, element) do
    {:ok, element in statements}
  end

  @doc """
  Slice is not implemented for scripts.
  """
  def slice(_script) do
    {:error, __MODULE__}
  end

  @doc """
  Reduces over executable statements, filtering out separators and comments.
  """
  def reduce(%{statements: statements}, acc, fun) do
    # Filter to only executable statements
    executable =
      Enum.filter(statements, fn
        {:separator, _} -> false
        %Bash.AST.Comment{} -> false
        _ -> true
      end)

    Enumerable.List.reduce(executable, acc, fun)
  end
end
