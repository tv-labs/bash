defmodule Bash.AST.Formatter do
  @moduledoc false

  @type t :: %__MODULE__{
          indent: String.t(),
          indent_level: non_neg_integer()
        }

  defstruct indent: "  ",
            indent_level: 0

  @doc """
  Create a new formatter with default options.
  """
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Get the current indentation string based on indent level.
  """
  def current_indent(%__MODULE__{indent: indent, indent_level: level}) do
    String.duplicate(indent, level)
  end

  @doc """
  Increase the indent level for nested content.
  """
  def indent(%__MODULE__{indent_level: level} = fmt) do
    %{fmt | indent_level: level + 1}
  end

  @doc """
  Decrease the indent level.
  """
  def dedent(%__MODULE__{indent_level: level} = fmt) when level > 0 do
    %{fmt | indent_level: level - 1}
  end

  def dedent(%__MODULE__{} = fmt), do: fmt

  @doc """
  Convert an AST node to Bash string with formatting context.

  Delegates to the node's `to_bash/2` function if available,
  otherwise falls back to `to_string/1`.
  """
  def to_bash(node, %__MODULE__{} = fmt) do
    module = node.__struct__
    Code.ensure_loaded(module)

    if function_exported?(module, :to_bash, 2) do
      module.to_bash(node, fmt)
    else
      Kernel.to_string(node)
    end
  end

  @doc """
  Serialize a list of statements with proper indentation.
  Handles separator tuples to preserve blank lines.

  Separators contain the newline(s) that follow each statement, so statements
  don't add their own trailing newline when followed by a separator.
  """
  def serialize_body(statements, %__MODULE__{} = fmt) when is_list(statements) do
    indent_str = current_indent(fmt)

    # Convert to tagged tuples
    tagged =
      statements
      |> Enum.map(fn
        {:separator, sep} -> {:sep, sep}
        stmt -> {:stmt, "#{indent_str}#{to_bash(stmt, fmt)}"}
      end)
      |> Enum.reduce([], fn
        {:sep, _sep}, [] -> []
        {:sep, sep}, acc -> [{:sep, sep} | acc]
        {:stmt, content}, acc -> [{:stmt, content} | acc]
      end)
      |> Enum.reverse()

    # Join with awareness of what follows each statement
    tagged
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {{:sep, sep}, _idx} ->
        sep

      {{:stmt, content}, idx} ->
        # Check if next item is a separator
        next = Enum.at(tagged, idx + 1)

        case next do
          {:sep, _} ->
            # Separator follows - it provides the newline
            content

          _ ->
            # No separator follows - add newline
            content <> "\n"
        end
    end)
    |> String.trim_trailing("\n")
  end
end
