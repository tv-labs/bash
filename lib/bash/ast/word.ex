defmodule Bash.AST.Word do
  @moduledoc """
  Word: expandable text that may contain variables, command substitutions, etc.

  A word is composed of parts that are either literals or expansions.
  Quoting affects how expansions are performed.

  ## Examples

      # hello (literal)
      %Word{
        parts: [{:literal, "hello"}],
        quoted: :none
      }

      # $USER (variable)
      %Word{
        parts: [{:variable, %Variable{name: "USER"}}],
        quoted: :none
      }

      # "hello $USER" (double-quoted with expansion)
      %Word{
        parts: [
          {:literal, "hello "},
          {:variable, %Variable{name: "USER"}}
        ],
        quoted: :double
      }

      # 'hello $USER' (single-quoted, no expansion)
      %Word{
        parts: [{:literal, "hello $USER"}],
        quoted: :single
      }

      # $(echo test) (command substitution)
      %Word{
        parts: [
          {:command_subst, [%Command{name: "echo", args: ["test"]}]}
        ],
        quoted: :none
      }

      # $((1 + 2)) (arithmetic expansion)
      %Word{
        parts: [{:arith_expand, "1 + 2"}],
        quoted: :none
      }

      # *.txt (glob pattern)
      %Word{
        parts: [{:glob, "*.txt"}],
        quoted: :none
      }
  """

  alias Bash.AST

  @type part ::
          {:literal, String.t()}
          | {:variable, Variable.t()}
          | {:command_subst, [Statement.t()]}
          | {:process_subst_in, [Statement.t()]}
          | {:process_subst_out, [Statement.t()]}
          | {:arith_expand, String.t()}
          | {:glob, String.t()}
          | {:brace_expand, BraceExpand.t()}

  @type quote_type :: :none | :single | :double

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          parts: [part()],
          quoted: quote_type()
        }

  defstruct [:meta, parts: [], quoted: :none]

  defimpl String.Chars do
    def to_string(%{parts: parts, quoted: quoted}) do
      parts_str =
        Enum.map_join(parts, "", fn
          {:literal, text} ->
            text

          {:single_quoted, text} ->
            "'#{text}'"

          {:double_quoted, inner_parts} ->
            # Serialize inner parts without the outer quote wrapper
            inner = Enum.map_join(inner_parts, "", &serialize_part/1)
            "\"#{inner}\""

          {:variable, var_ref} ->
            Kernel.to_string(var_ref)

          {:command_subst, commands} when is_list(commands) ->
            "$(#{Enum.map_join(commands, "; ", &Kernel.to_string/1)})"

          {:command_subst, command} ->
            # Single command (not wrapped in list)
            "$(#{Kernel.to_string(command)})"

          {:process_subst_in, commands} when is_list(commands) ->
            "<(#{Enum.map_join(commands, "; ", &Kernel.to_string/1)})"

          {:process_subst_in, command} ->
            "<(#{Kernel.to_string(command)})"

          {:process_subst_out, commands} when is_list(commands) ->
            ">(#{Enum.map_join(commands, "; ", &Kernel.to_string/1)})"

          {:process_subst_out, command} ->
            ">(#{Kernel.to_string(command)})"

          {:arith_expand, expr} ->
            "$((" <> expr <> "))"

          {:glob, pattern} ->
            pattern

          {:brace_expand, brace} ->
            serialize_brace_expand(brace)
        end)

      case quoted do
        :none -> parts_str
        :single -> "'#{parts_str}'"
        :double -> "\"#{parts_str}\""
      end
    end

    # Helper to serialize individual parts within double quotes
    defp serialize_part({:literal, text}), do: escape_for_double_quote(text)
    defp serialize_part({:variable, var_ref}), do: Kernel.to_string(var_ref)

    defp serialize_part({:command_subst, commands}) when is_list(commands),
      do: "$(#{Enum.map_join(commands, "; ", &Kernel.to_string/1)})"

    defp serialize_part({:command_subst, command}), do: "$(#{Kernel.to_string(command)})"

    defp serialize_part({:process_subst_in, commands}) when is_list(commands),
      do: "<(#{Enum.map_join(commands, "; ", &Kernel.to_string/1)})"

    defp serialize_part({:process_subst_in, command}), do: "<(#{Kernel.to_string(command)})"

    defp serialize_part({:process_subst_out, commands}) when is_list(commands),
      do: ">(#{Enum.map_join(commands, "; ", &Kernel.to_string/1)})"

    defp serialize_part({:process_subst_out, command}), do: ">(#{Kernel.to_string(command)})"
    defp serialize_part({:arith_expand, expr}), do: "$((" <> expr <> "))"
    defp serialize_part({:brace_expand, brace}), do: serialize_brace_expand(brace)
    defp serialize_part(other), do: inspect(other)

    # Escape special characters for double-quoted context
    # In double quotes: \ " $ ` need escaping
    defp escape_for_double_quote(text) do
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")
    end

    defp serialize_brace_expand(%{type: :list, items: items}) do
      inner =
        Enum.map_join(items, ",", fn item_parts ->
          Enum.map_join(item_parts, "", &serialize_part/1)
        end)

      "{#{inner}}"
    end

    defp serialize_brace_expand(%{type: :range, range_start: s, range_end: e, step: step}) do
      base = "{#{s}..#{e}"

      if step && step != 1 do
        base <> "..#{step}}"
      else
        base <> "}"
      end
    end
  end

  defimpl Inspect do
    def inspect(%{parts: parts, quoted: quoted}, _opts) do
      content = Kernel.to_string(%Bash.AST.Word{parts: parts, quoted: quoted})
      "#Word{#{content}}"
    end
  end
end
