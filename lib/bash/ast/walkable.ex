defprotocol Bash.AST.Walkable do
  @moduledoc """
  Protocol for traversing and transforming AST nodes.

  Each AST node implements this protocol to expose its child statement nodes
  and allow reconstruction with updated children. This powers the tree
  traversal functions in `Bash.AST`.

  Statement lists in the AST may contain interleaved separator tuples like
  `{:separator, "\\n"}` or `{:operator, :and}`. The protocol implementations
  filter these out when returning children and splice them back in during
  reconstruction.
  """

  @doc "Returns child statement nodes as a flat list."
  @spec children(t()) :: [Bash.Statement.t()]
  def children(node)

  # Returns the node with children replaced from a flat list.
  #
  # The list must be in the same order as returned by `children/1`.
  @doc false
  @spec update_children(t(), [Bash.Statement.t()]) :: t()
  def update_children(node, children)
end

defmodule Bash.AST.Walkable.Helpers do
  @moduledoc false

  # Extracts struct nodes from a list that may contain separator/operator tuples.
  @doc false
  def extract_structs(list), do: Enum.filter(list, &is_struct/1)

  # Replaces struct positions in a mixed list with nodes from a queue,
  # preserving non-struct elements (separators, operators) in place.
  @doc false
  def splice_structs(original, new_children) do
    queue = :queue.from_list(new_children)

    {result, _} =
      Enum.flat_map_reduce(original, queue, fn
        elem, queue when is_struct(elem) ->
          case :queue.out(queue) do
            {{:value, next}, rest} -> {[next], rest}
            {:empty, queue} -> {[], queue}
          end

        non_struct, queue ->
          {[non_struct], queue}
      end)

    result
  end
end

# Leaf nodes — no children

defimpl Bash.AST.Walkable, for: Bash.AST.Command do
  def children(_node), do: []
  def update_children(node, []), do: node
end

defimpl Bash.AST.Walkable, for: Bash.AST.Assignment do
  def children(_node), do: []
  def update_children(node, []), do: node
end

defimpl Bash.AST.Walkable, for: Bash.AST.Comment do
  def children(_node), do: []
  def update_children(node, []), do: node
end

defimpl Bash.AST.Walkable, for: Bash.AST.TestCommand do
  def children(_node), do: []
  def update_children(node, []), do: node
end

defimpl Bash.AST.Walkable, for: Bash.AST.TestExpression do
  def children(_node), do: []
  def update_children(node, []), do: node
end

defimpl Bash.AST.Walkable, for: Bash.AST.Arithmetic do
  def children(_node), do: []
  def update_children(node, []), do: node
end

defimpl Bash.AST.Walkable, for: Bash.AST.ArrayAssignment do
  def children(_node), do: []
  def update_children(node, []), do: node
end

# Compound nodes

defimpl Bash.AST.Walkable, for: Bash.AST.Pipeline do
  def children(%{commands: commands}), do: commands

  def update_children(node, children), do: %{node | commands: children}
end

defimpl Bash.AST.Walkable, for: Bash.AST.If do
  alias Bash.AST.Walkable.Helpers

  def children(%{condition: condition, body: body, elif_clauses: elifs, else_body: else_body}) do
    elif_children =
      Enum.flat_map(elifs, fn {cond_node, body_nodes} ->
        [cond_node | Helpers.extract_structs(body_nodes)]
      end)

    [condition | Helpers.extract_structs(body)] ++
      elif_children ++ Helpers.extract_structs(else_body || [])
  end

  def update_children(node, children) do
    %{body: body, elif_clauses: elifs, else_body: else_body} = node
    body_struct_count = length(Helpers.extract_structs(body))

    elif_counts =
      Enum.map(elifs, fn {_c, b} -> 1 + length(Helpers.extract_structs(b)) end)

    else_struct_count =
      if(else_body, do: length(Helpers.extract_structs(else_body)), else: 0)

    [condition | rest] = children
    {new_body_structs, rest} = Enum.split(rest, body_struct_count)

    {new_elifs, rest} =
      Enum.map_reduce(Enum.zip(elif_counts, elifs), rest, fn {count, {_old_c, old_b}},
                                                             remaining ->
        {elif_nodes, remaining} = Enum.split(remaining, count)
        [elif_cond | elif_body_structs] = elif_nodes
        {{elif_cond, Helpers.splice_structs(old_b, elif_body_structs)}, remaining}
      end)

    {new_else_structs, []} =
      if else_struct_count > 0 do
        Enum.split(rest, else_struct_count)
      else
        {nil, rest}
      end

    new_else =
      if else_body && new_else_structs do
        Helpers.splice_structs(else_body, new_else_structs)
      else
        new_else_structs
      end

    %{
      node
      | condition: condition,
        body: Helpers.splice_structs(body, new_body_structs),
        elif_clauses: new_elifs,
        else_body: new_else
    }
  end
end

defimpl Bash.AST.Walkable, for: Bash.AST.ForLoop do
  alias Bash.AST.Walkable.Helpers

  def children(%{body: body}), do: Helpers.extract_structs(body)

  def update_children(node, children) do
    %{node | body: Helpers.splice_structs(node.body, children)}
  end
end

defimpl Bash.AST.Walkable, for: Bash.AST.WhileLoop do
  alias Bash.AST.Walkable.Helpers

  def children(%{condition: condition, body: body}) do
    [condition | Helpers.extract_structs(body)]
  end

  def update_children(node, [condition | body_structs]) do
    %{node | condition: condition, body: Helpers.splice_structs(node.body, body_structs)}
  end
end

defimpl Bash.AST.Walkable, for: Bash.AST.Case do
  alias Bash.AST.Walkable.Helpers

  def children(%{cases: cases}) do
    Enum.flat_map(cases, fn {_patterns, body, _terminator} ->
      Helpers.extract_structs(body)
    end)
  end

  def update_children(node, children) do
    {new_cases, []} =
      Enum.map_reduce(node.cases, children, fn {patterns, body, terminator}, remaining ->
        struct_count = length(Helpers.extract_structs(body))
        {new_structs, remaining} = Enum.split(remaining, struct_count)
        {{patterns, Helpers.splice_structs(body, new_structs), terminator}, remaining}
      end)

    %{node | cases: new_cases}
  end
end

defimpl Bash.AST.Walkable, for: Bash.AST.Compound do
  alias Bash.AST.Walkable.Helpers

  def children(%{statements: statements}), do: Helpers.extract_structs(statements)

  def update_children(node, children) do
    %{node | statements: Helpers.splice_structs(node.statements, children)}
  end
end

defimpl Bash.AST.Walkable, for: Bash.AST.Coproc do
  def children(%{body: body}), do: [body]

  def update_children(node, [body]), do: %{node | body: body}
end

defimpl Bash.AST.Walkable, for: Bash.AST.Function do
  alias Bash.AST.Walkable.Helpers

  def children(%{body: body}) when is_list(body), do: Helpers.extract_structs(body)
  def children(%{body: body}), do: [body]

  def update_children(node, children) when is_list(node.body) do
    %{node | body: Helpers.splice_structs(node.body, children)}
  end

  def update_children(node, [body]), do: %{node | body: body}
end

defimpl Bash.AST.Walkable, for: Bash.Script do
  alias Bash.AST.Walkable.Helpers

  def children(%{statements: statements}), do: Helpers.extract_structs(statements)

  def update_children(node, children) do
    %{node | statements: Helpers.splice_structs(node.statements, children)}
  end
end
