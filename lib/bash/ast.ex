defmodule Bash.AST do
  @moduledoc """
  Typed Abstract Syntax Tree (AST) for Bash.

  This module defines structured types for representing parsed Bash code.
  Each AST node includes metadata for source location tracking and error reporting.

  ## Design Principles

  1. **Type Safety**: Every node is a proper struct with `@type` specs
  2. **Source Tracking**: All nodes include line/column for error messages
  3. **Complete**: Represents all Bash constructs we support
  4. **Immutable**: AST is built once during parsing, never modified

  ## AST Hierarchy

  ```
  Script (top level)
  ├── Statement (commands, assignments, control flow)
  │   ├── Command (simple command with args)
  │   ├── Pipeline (cmd1 | cmd2 | cmd3)
  │   ├── Assignment (VAR=value)
  │   ├── If (if/elif/else/fi)
  │   ├── ForLoop (for var in items; do...; done)
  │   ├── WhileLoop (while/until condition; do...; done)
  │   ├── Case (case var in "pattern)" esac)
  │   ├── Function (function name { ...; })
  │   ├── Compound (subshells, groups, logical, sequential)
  │   ├── Word (text with variable expansion)
  │   └── Variable (variable reference with operators)
  └── Expression (expandable text, tests, arithmetic)
      ├── TestExpression (`[[ ... ]]` expressions)
      └── Arithmetic (`(( ... ))` arithmetic)
  ```

  ## Reference

  Bash grammar: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/parse.y?h=bash-5.3
  """

  alias Bash.AST
  alias Bash.AST.Walkable

  @doc """
  Extracts the literal command name from a `Command` node.

  Usable in guards and pattern match `when` clauses.

  ## Examples

      import Bash.AST

      # In a walker callback
      AST.prewalk(script, fn
        node when command_name(node) == "rm" -> nil
        node -> node
      end)

      # In a function head
      def handle_command(node) when command_name(node) == "sudo" do
        # ...
      end
  """
  defguard command_name(node) when elem(hd(node.name.parts), 1)

  @doc """
  Returns `true` if `node` is a `Command` with the given literal name.

  Usable in guards and pattern match `when` clauses.

  ## Examples

      import Bash.AST

      AST.prewalk(script, fn
        node when is_command(node, "rm") -> nil
        node -> node
      end)
  """
  defguard is_command(node)
           when is_struct(node, AST.Command) and
                  elem(hd(node.name.parts), 0) == :literal

  defguard is_command(node, name)
            when is_command(node) and command_name(node) == name

  @doc """
  Extracts the variable name from an `Assignment` node.

  Usable in guards and pattern match `when` clauses.

  ## Examples

      import Bash.AST

      AST.reduce(script, [], fn
        node when is_assignment(node, "PATH") -> [:found | acc]
        _, acc -> acc
      end)
  """
  defguard assignment_name(node) when node.name

  @doc """
  Returns `true` if `node` is an `Assignment` with the given variable name.

  Usable in guards and pattern match `when` clauses.
  """

  defguard is_assignment(node) when is_struct(node, AST.Assignment)
  defguard is_assignment(node, name) when is_assignment(node) and assignment_name(node) == name

  @doc """
  Create metadata from line and column information.
  """
  def meta(line, column, source_range \\ nil) do
    %AST.Meta{line: line, column: column, source_range: source_range}
  end

  @doc """
  Check if an AST node is a constant (no expansions needed).
  Returns true if the node contains only literals.
  """
  def constant?(%AST.Word{parts: parts}) do
    Enum.all?(parts, fn
      {:literal, _} -> true
      _ -> false
    end)
  end

  def constant?(_), do: false

  @doc """
  Extract the literal value from a constant word.
  Returns {:ok, string} or :error if not constant.
  """
  def literal_value(%AST.Word{} = word) do
    if constant?(word) do
      value =
        Enum.map_join(word.parts, fn {:literal, text} -> text end)

      {:ok, value}
    else
      :error
    end
  end

  def literal_value(_), do: :error

  @doc """
  Walks the AST with an accumulator, calling `pre` before descending
  into children and `post` after.

  Both callbacks receive `(node, acc)` and must return `{node, acc}`.
  Returning `nil` as the node removes it from parent lists.
  """
  @spec walk_tree(node, acc, (node, acc -> {node, acc}), (node, acc -> {node, acc})) ::
          {node, acc}
        when node: Walkable.t(), acc: term()
  def walk_tree(node, acc, pre, post) do
    {node, acc} = pre.(node, acc)

    if is_nil(node) do
      {nil, acc}
    else
      children = Walkable.children(node)

      {new_children, acc} =
        Enum.flat_map_reduce(children, acc, fn child, acc ->
          {child, acc} = walk_tree(child, acc, pre, post)

          if is_nil(child) do
            {[], acc}
          else
            {[child], acc}
          end
        end)

      node = Walkable.update_children(node, new_children)
      post.(node, acc)
    end
  end

  @doc """
  Top-down transformation using the `Walkable` protocol.

  Applies `fun` to each node before descending into its children.
  Return `nil` to remove a node from its parent list.
  """
  @spec prewalk(Walkable.t(), (Walkable.t() -> Walkable.t() | nil)) :: Walkable.t() | nil
  def prewalk(node, fun) do
    {result, _} =
      walk_tree(node, nil, fn n, acc -> {fun.(n), acc} end, fn n, acc -> {n, acc} end)

    result
  end

  @doc """
  Bottom-up transformation using the `Walkable` protocol.

  Applies `fun` to each node after processing its children.
  Return `nil` to remove a node from its parent list.
  """
  @spec postwalk(Walkable.t(), (Walkable.t() -> Walkable.t() | nil)) :: Walkable.t() | nil
  def postwalk(node, fun) do
    {result, _} =
      walk_tree(node, nil, fn n, acc -> {n, acc} end, fn n, acc -> {fun.(n), acc} end)

    result
  end

  @doc """
  Reduces over all nodes in the tree without modifying it.

  Visits each node depth-first (pre-order) and applies `fun` to
  accumulate a result.
  """
  @spec reduce(Walkable.t(), acc, (Walkable.t(), acc -> acc)) :: acc when acc: term()
  def reduce(node, acc, fun) do
    {_node, acc} =
      walk_tree(node, acc, fn n, acc -> {n, fun.(n, acc)} end, fn n, acc -> {n, acc} end)

    acc
  end

  @doc """
  Extracts only stdout from an AST node's output field.

  ## Examples

      iex> AST.stdout(%AST.Command{output: [{:stdout, "hello\\n"}]})
      "hello\\n"

  """
  def stdout(%{output: output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      {:stdout, data} when is_list(data) -> data
      {:stdout, data} when is_binary(data) -> [data]
      _ -> []
    end)
    |> IO.iodata_to_binary()
  end

  def stdout(_), do: ""

  @doc """
  Extracts only stderr from an AST node's output field.

  ## Examples

      iex> AST.stderr(%AST.Command{output: [{:stderr, "error\\n"}]})
      "error\\n"

  """
  def stderr(%{output: output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      {:stderr, data} when is_list(data) -> data
      {:stderr, data} when is_binary(data) -> [data]
      _ -> []
    end)
    |> IO.iodata_to_binary()
  end

  def stderr(_), do: ""

  @doc """
  Returns all output as a single binary, preserving order.

  ## Examples

      iex> AST.all_output(%AST.Command{output: [{:stdout, "out"}, {:stderr, "err"}]})
      "outerr"

  """
  def all_output(%{output: output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      {_, data} when is_list(data) -> data
      {_, data} when is_binary(data) -> [data]
      _ -> []
    end)
    |> IO.iodata_to_binary()
  end

  def all_output(_), do: ""

  @doc """
  Returns true if the AST node executed successfully (exit code 0).

  ## Examples

      iex> AST.success?(%AST.Command{exit_code: 0})
      true

      iex> AST.success?(%AST.Command{exit_code: 1})
      false

  """
  def success?(%{exit_code: 0}), do: true
  def success?(%{exit_code: _}), do: false
  def success?(_), do: false

  @doc """
  Returns true if the AST node has been executed (has an exit code).

  ## Examples

      iex> AST.executed?(%AST.Command{exit_code: 0})
      true

      iex> AST.executed?(%AST.Command{exit_code: nil})
      false

  """
  def executed?(%{exit_code: nil}), do: false
  def executed?(%{exit_code: _}), do: true
  def executed?(_), do: false

  @doc """
  Gets the exit code from an AST node.

  ## Examples

      iex> AST.get_exit_code(%AST.Command{exit_code: 0})
      0

      iex> AST.get_exit_code(%AST.Command{exit_code: nil})
      nil

  """
  def get_exit_code(%{exit_code: code}), do: code
  def get_exit_code(_), do: nil
end
