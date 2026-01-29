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

    formatted =
      statements
      |> Enum.reduce([], fn
        {:seperator, _sep}, [] -> []
        {:seperator, sep}, acc -> [{:seperator, sep} | acc]
        content, acc -> ["#{indent_str}#{to_bash(content, fmt)}" | acc]
      end)
      |> Enum.reverse()

    formatted
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {{:seperator, sep}, _idx} ->
        sep

      {content, idx} ->
        next = Enum.at(formatted, idx + 1)

        case next do
          {:seperator, _} -> content
          _ -> content <> "\n"
        end
    end)
    |> String.trim_trailing("\n")
  end
end
