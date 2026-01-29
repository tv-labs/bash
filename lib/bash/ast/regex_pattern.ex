defmodule Bash.AST.RegexPattern do
  @moduledoc """
  Regex pattern for use with the `=~` operator in `[[ ]]` test expressions.

  Unlike regular words, regex patterns preserve metacharacters like `[`, `]`, `(`, `)`,
  `{`, `}`, `|`, `*`, `+`, `?`, `^`, `$`, and `.` as literal regex syntax rather than
  interpreting them as shell glob patterns or operators.

  ## Examples

      # [[ "hello123" =~ [0-9]+ ]]
      %RegexPattern{
        parts: [literal: "[0-9]+"]
      }

      # [[ "$str" =~ ^${prefix}[0-9]+$ ]]
      %RegexPattern{
        parts: [
          {:literal, "^"},
          {:variable, %AST.Variable{name: "prefix"}},
          {:literal, "[0-9]+$"}
        ]
      }

  ## BASH_REMATCH

  When a regex pattern matches, the `BASH_REMATCH` array is populated:
  - `BASH_REMATCH[0]` contains the entire match
  - `BASH_REMATCH[1..n]` contain capture group matches

  When the pattern does not match, `BASH_REMATCH` is unset.
  """

  alias Bash.AST
  alias Bash.Variable

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          parts: [AST.Word.part()]
        }

  defstruct [:meta, parts: []]

  # Expand the regex pattern parts into a string for compilation.
  #
  # Variables are expanded using the session state. Unlike word expansion,
  # no word splitting or glob expansion is performed.
  @doc false
  def expand(%__MODULE__{parts: parts}, session_state) do
    parts
    |> Enum.map(&expand_part(&1, session_state))
    |> IO.iodata_to_binary()
  end

  defp expand_part({:literal, text}, _session_state), do: text

  defp expand_part({:single_quoted, text}, _session_state), do: text

  defp expand_part({:double_quoted, inner_parts}, session_state) do
    inner_parts
    |> Enum.map(&expand_part(&1, session_state))
    |> IO.iodata_to_binary()
  end

  defp expand_part({:variable, %AST.Variable{name: var_name}}, session_state) do
    case Map.get(session_state.variables, var_name) do
      nil -> ""
      %Variable{} = var -> Variable.get(var, nil) || ""
    end
  end

  defp expand_part({:variable, name}, session_state) when is_binary(name) do
    case Map.get(session_state.variables, name) do
      nil -> ""
      %Variable{} = var -> Variable.get(var, nil) || ""
    end
  end

  defp expand_part(_part, _session_state), do: ""

  defimpl String.Chars do
    def to_string(%{parts: parts}) do
      parts
      |> Enum.map(&part_to_string/1)
      |> IO.iodata_to_binary()
    end

    defp part_to_string({:literal, text}), do: escape_for_unquoted(text)
    defp part_to_string({:single_quoted, text}), do: "'#{text}'"

    defp part_to_string({:double_quoted, inner_parts}) do
      inner = Enum.map_join(inner_parts, "", &inner_part_to_string/1)
      "\"#{inner}\""
    end

    defp part_to_string({:variable, var}), do: Kernel.to_string(var)
    defp part_to_string(_), do: ""

    # Serialize parts inside double quotes with proper escaping
    defp inner_part_to_string({:literal, text}), do: escape_for_double_quote(text)
    defp inner_part_to_string({:variable, %Bash.AST.Variable{name: name}}), do: "$#{name}"
    defp inner_part_to_string({:variable, name}) when is_binary(name), do: "$#{name}"
    defp inner_part_to_string(other), do: part_to_string(other)

    # Escape special characters for double-quoted context
    # In double quotes: \ " $ ` need escaping
    defp escape_for_double_quote(text) do
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")
    end

    # Escape special characters for unquoted regex pattern context
    # In unquoted context: \ " $ ` space and shell metacharacters need escaping
    defp escape_for_unquoted(text) do
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")
      |> String.replace(" ", "\\ ")
      |> String.replace("\t", "\\\t")
      |> String.replace(";", "\\;")
      |> String.replace("&", "\\&")
      |> String.replace("#", "\\#")
      |> String.replace("'", "\\'")
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{parts: parts}, opts) do
      parts_str =
        parts
        |> Enum.map(&part_to_inspect_string/1)
        |> Enum.join()

      concat(["#Regex<", color(parts_str, :string, opts), ">"])
    end

    defp part_to_inspect_string({:literal, text}), do: text
    defp part_to_inspect_string({:single_quoted, text}), do: "'#{text}'"
    defp part_to_inspect_string({:double_quoted, _}), do: "\"...\""
    defp part_to_inspect_string({:variable, var}), do: Kernel.to_string(var)
    defp part_to_inspect_string(_), do: "..."
  end
end
