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
  alias Bash.Function
  alias Bash.Script

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
  Walk the AST and apply a function to each node.
  The function receives the node and returns a transformed node.
  """
  def walk(ast, fun) when is_function(fun, 1) do
    ast
    |> fun.()
    |> walk_children(fun)
  end

  defp walk_children(%Script{statements: stmts} = node, fun) do
    %{node | statements: Enum.map(stmts, &walk(&1, fun))}
  end

  defp walk_children(%AST.Command{args: args} = node, fun) do
    %{node | args: Enum.map(args, &walk(&1, fun))}
  end

  defp walk_children(%AST.Pipeline{commands: cmds} = node, fun) do
    %{node | commands: Enum.map(cmds, &walk(&1, fun))}
  end

  defp walk_children(%AST.If{} = node, fun) do
    %{
      node
      | condition: walk(node.condition, fun),
        body: Enum.map(node.body, &walk(&1, fun)),
        elif_clauses:
          Enum.map(node.elif_clauses, fn {cond, body} ->
            {walk(cond, fun), Enum.map(body, &walk(&1, fun))}
          end),
        else_body:
          if node.else_body do
            Enum.map(node.else_body, &walk(&1, fun))
          end
    }
  end

  defp walk_children(%AST.ForLoop{items: items, body: body} = node, fun) do
    %{
      node
      | items: Enum.map(items, &walk(&1, fun)),
        body: Enum.map(body, &walk(&1, fun))
    }
  end

  defp walk_children(%AST.WhileLoop{condition: cond, body: body} = node, fun) do
    %{
      node
      | condition: walk(cond, fun),
        body: Enum.map(body, &walk(&1, fun))
    }
  end

  defp walk_children(%Function{body: body} = node, fun) do
    %{node | body: Enum.map(body, &walk(&1, fun))}
  end

  defp walk_children(%AST.Compound{statements: stmts} = node, fun) do
    %{node | statements: Enum.map(stmts, &walk(&1, fun))}
  end

  defp walk_children(%AST.Word{parts: parts} = node, fun) do
    %{
      node
      | parts:
          Enum.map(parts, fn
            {:variable, var_ref} ->
              {:variable, walk(var_ref, fun)}

            {:command_subst, stmts} when is_list(stmts) ->
              {:command_subst, Enum.map(stmts, &walk(&1, fun))}

            {:command_subst, stmt} ->
              {:command_subst, walk(stmt, fun)}

            {:arithmetic, expr} ->
              {:arithmetic, walk(expr, fun)}

            other ->
              other
          end)
    }
  end

  defp walk_children(%AST.Variable{expansion: exp} = node, fun) do
    %{
      node
      | expansion:
          case exp do
            {:default, word} -> {:default, walk(word, fun)}
            {:assign_default, word} -> {:assign_default, walk(word, fun)}
            {:error, word} -> {:error, walk(word, fun)}
            {:alternate, word} -> {:alternate, walk(word, fun)}
            {:remove_prefix, word, mode} -> {:remove_prefix, walk(word, fun), mode}
            {:remove_suffix, word, mode} -> {:remove_suffix, walk(word, fun), mode}
            {:substitute, pat, repl, mode} -> {:substitute, walk(pat, fun), walk(repl, fun), mode}
            other -> other
          end
    }
  end

  defp walk_children(%AST.TestExpression{expression: expression} = node, fun) do
    %{
      node
      | expression:
          Enum.map(expression, fn
            item when is_struct(item) -> walk(item, fun)
            other -> other
          end)
    }
  end

  defp walk_children(%AST.TestCommand{args: args} = node, fun) do
    %{
      node
      | args:
          Enum.map(args, fn
            item when is_struct(item) -> walk(item, fun)
            other -> other
          end)
    }
  end

  defp walk_children(%AST.Arithmetic{operands: operands} = node, fun) do
    %{
      node
      | operands:
          Enum.map(operands, fn
            operand when is_struct(operand) -> walk(operand, fun)
            other -> other
          end)
    }
  end

  defp walk_children(node, _fun), do: node

  @doc """
  Traverse the AST and apply a function to each node with filtering support.

  The function receives each node and should return one of:
  - `{:ok, new_node}` - replace the node with new_node
  - `:keep` - keep the original node unchanged
  - `:drop` or `nil` - remove the node from its parent's list

  This allows users to:
  - Audit functions and commands
  - Drop dangerous commands from scripts
  - Modify or replace specific commands
  - Filter out certain constructs

  ## Examples

      # Drop all commands named "rm"
      traverse(ast, fn
        %AST.Command{name: %AST.Word{parts: [{:literal, "rm"}]}} -> :drop
        node -> {:ok, node}
      end)

      # Replace "sudo" commands with their arguments
      traverse(ast, fn
        %AST.Command{name: %AST.Word{parts: [{:literal, "sudo"}]}, args: [actual | rest]} = cmd ->
          {:ok, %{cmd | name: actual, args: rest}}
        node -> {:ok, node}
      end)

      # Audit all external commands
      traverse(ast, fn
        %AST.Command{name: name} = cmd ->
          IO.puts("Found command: \#{name}")
          :keep
        _node -> :keep
      end)
  """
  @spec traverse(any(), (any() -> {:ok, any()} | :keep | :drop | nil)) :: any()
  def traverse(ast, fun) when is_function(fun, 1) do
    case fun.(ast) do
      {:ok, new_ast} ->
        traverse_children(new_ast, fun)

      :keep ->
        traverse_children(ast, fun)

      result when result in [:drop, nil] ->
        nil
    end
  end

  defp traverse_children(%Script{statements: stmts} = node, fun) do
    %{node | statements: traverse_list(stmts, fun)}
  end

  defp traverse_children(%AST.Command{args: args} = node, fun) do
    %{node | args: traverse_list(args, fun)}
  end

  defp traverse_children(%AST.Pipeline{commands: cmds} = node, fun) do
    new_commands = traverse_list(cmds, fun)
    # If all commands were dropped, drop the pipeline too
    if new_commands == [], do: nil, else: %{node | commands: new_commands}
  end

  defp traverse_children(%AST.If{} = node, fun) do
    new_condition = traverse(node.condition, fun)
    new_body = traverse_list(node.body, fun)

    new_elif_clauses =
      node.elif_clauses
      |> Enum.map(fn {cond, body} ->
        new_cond = traverse(cond, fun)
        new_body_elif = traverse_list(body, fun)
        if new_cond, do: {new_cond, new_body_elif}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    new_else_body =
      if node.else_body do
        traverse_list(node.else_body, fun)
      end

    # If condition was dropped, drop the whole if
    if new_condition == nil do
      nil
    else
      %{
        node
        | condition: new_condition,
          body: new_body,
          elif_clauses: new_elif_clauses,
          else_body: new_else_body
      }
    end
  end

  defp traverse_children(%AST.ForLoop{items: items, body: body} = node, fun) do
    %{
      node
      | items: traverse_list(items, fun),
        body: traverse_list(body, fun)
    }
  end

  defp traverse_children(%AST.WhileLoop{condition: cond, body: body} = node, fun) do
    new_condition = traverse(cond, fun)

    if new_condition == nil do
      nil
    else
      %{
        node
        | condition: new_condition,
          body: traverse_list(body, fun)
      }
    end
  end

  defp traverse_children(%AST.Case{word: word, cases: cases} = node, fun) do
    new_word = traverse(word, fun)

    new_cases =
      cases
      |> Enum.map(fn {patterns, body} ->
        new_patterns = traverse_list(patterns, fun)
        new_body = traverse_list(body, fun)
        if new_patterns == [], do: nil, else: {new_patterns, new_body}
      end)
      |> Enum.reject(&is_nil/1)

    if new_word == nil do
      nil
    else
      %{node | word: new_word, cases: new_cases}
    end
  end

  defp traverse_children(%Function{body: body} = node, fun) do
    %{node | body: traverse_list(body, fun)}
  end

  defp traverse_children(%AST.Compound{statements: stmts} = node, fun) do
    new_statements =
      stmts
      |> Enum.map(fn
        {:operator, _} = op -> op
        stmt -> traverse(stmt, fun)
      end)
      |> Enum.reject(&is_nil/1)

    if new_statements == [] do
      nil
    else
      %{node | statements: new_statements}
    end
  end

  defp traverse_children(%AST.Word{parts: parts} = node, fun) do
    new_parts =
      parts
      |> Enum.map(fn
        {:variable, var_ref} ->
          result = traverse(var_ref, fun)
          if result, do: {:variable, result}, else: nil

        {:command_subst, stmts} when is_list(stmts) ->
          new_stmts = traverse_list(stmts, fun)
          {:command_subst, new_stmts}

        {:command_subst, stmt} ->
          result = traverse(stmt, fun)
          if result, do: {:command_subst, result}, else: nil

        {:arithmetic, expr} ->
          result = traverse(expr, fun)
          if result, do: {:arithmetic, result}, else: nil

        other ->
          other
      end)
      |> Enum.reject(&is_nil/1)

    %{node | parts: new_parts}
  end

  defp traverse_children(%AST.Variable{expansion: exp} = node, fun) do
    new_expansion =
      case exp do
        {:default, word} ->
          result = traverse(word, fun)
          if result, do: {:default, result}, else: nil

        {:assign_default, word} ->
          result = traverse(word, fun)
          if result, do: {:assign_default, result}, else: nil

        {:error, word} ->
          result = traverse(word, fun)
          if result, do: {:error, result}, else: nil

        {:alternate, word} ->
          result = traverse(word, fun)
          if result, do: {:alternate, result}, else: nil

        {:remove_prefix, word, mode} ->
          result = traverse(word, fun)
          if result, do: {:remove_prefix, result, mode}, else: nil

        {:remove_suffix, word, mode} ->
          result = traverse(word, fun)
          if result, do: {:remove_suffix, result, mode}, else: nil

        {:substitute, pat, repl, mode} ->
          new_pat = traverse(pat, fun)
          new_repl = traverse(repl, fun)
          if new_pat && new_repl, do: {:substitute, new_pat, new_repl, mode}, else: nil

        other ->
          other
      end

    %{node | expansion: new_expansion}
  end

  defp traverse_children(%AST.TestExpression{expression: expression} = node, fun) do
    new_expression =
      Enum.map(expression, fn
        item when is_struct(item) -> traverse(item, fun)
        other -> other
      end)
      |> Enum.reject(&is_nil/1)

    %{node | expression: new_expression}
  end

  defp traverse_children(%AST.TestCommand{args: args} = node, fun) do
    new_args =
      Enum.map(args, fn
        item when is_struct(item) -> traverse(item, fun)
        other -> other
      end)
      |> Enum.reject(&is_nil/1)

    %{node | args: new_args}
  end

  defp traverse_children(%AST.Arithmetic{operands: operands} = node, fun) do
    new_operands =
      Enum.map(operands, fn
        operand when is_struct(operand) -> traverse(operand, fun)
        other -> other
      end)
      |> Enum.reject(&is_nil/1)

    %{node | operands: new_operands}
  end

  defp traverse_children(node, _fun), do: node

  # Helper to traverse a list and filter out nil results
  defp traverse_list(items, fun) do
    items
    |> Enum.map(&traverse(&1, fun))
    |> Enum.reject(&is_nil/1)
  end

  # ============================================================================
  # Execution Result Helpers
  # ============================================================================
  # These functions provide a unified interface for extracting execution results
  # from AST nodes, similar to CommandResult helpers.

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
