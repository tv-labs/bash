defmodule Bash.AST.Variable do
  @moduledoc """
  Variable reference with optional parameter expansion operators.

  ## Examples

      # $VAR or ${VAR}
      %Variable{name: "VAR", expansion: nil}

      # ${VAR:-default}
      %Variable{
        name: "VAR",
        expansion: {:default, %Word{parts: [{:literal, "default"}]}}
      }

      # ${VAR:=default}
      %Variable{
        name: "VAR",
        expansion: {:assign_default, %Word{...}}
      }

      # ${VAR:?error message}
      %Variable{
        name: "VAR",
        expansion: {:error, %Word{...}}
      }

      # ${VAR:+alternate}
      %Variable{
        name: "VAR",
        expansion: {:alternate, %Word{...}}
      }

      # ${#VAR}
      %Variable{name: "VAR", expansion: {:length}}

      # ${VAR:offset:length}
      %Variable{
        name: "VAR",
        expansion: {:substring, 0, 10}
      }

      # ${VAR#pattern}
      %Variable{
        name: "VAR",
        expansion: {:remove_prefix, %Word{...}, :shortest}
      }

      # ${VAR##pattern}
      %Variable{
        name: "VAR",
        expansion: {:remove_prefix, %Word{...}, :longest}
      }

      # ${VAR%pattern}
      %Variable{
        name: "VAR",
        expansion: {:remove_suffix, %Word{...}, :shortest}
      }

      # ${VAR%%pattern}
      %Variable{
        name: "VAR",
        expansion: {:remove_suffix, %Word{...}, :longest}
      }

      # ${VAR/pattern/replacement}
      %Variable{
        name: "VAR",
        expansion: {:substitute, %Word{...}, %Word{...}, :first}
      }

      # ${VAR//pattern/replacement}
      %Variable{
        name: "VAR",
        expansion: {:substitute, %Word{...}, %Word{...}, :all}
      }
  """

  alias Bash.AST

  @type subscript :: nil | {:index, String.t()} | :all_values | :all_star

  @type expansion ::
          nil
          | {:default, AST.Word.t()}
          | {:assign_default, AST.Word.t()}
          | {:error, AST.Word.t()}
          | {:alternate, AST.Word.t()}
          | {:length}
          | {:substring, integer(), integer() | nil}
          | {:remove_prefix, AST.Word.t(), :shortest | :longest}
          | {:remove_suffix, AST.Word.t(), :shortest | :longest}
          | {:substitute, pattern :: AST.Word.t(), replacement :: AST.Word.t(), :first | :all}
          | {:prefix_names, :star | :at}
          | {:transform, :quote | :escape | :prompt | :assignment | :quoted_keys | :keys | :attributes | :upper | :lower}

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: String.t(),
          subscript: subscript(),
          expansion: expansion()
        }

  defstruct [:meta, :name, subscript: nil, expansion: nil]

  defimpl String.Chars do
    # Variable without expansion - can use short form $VAR or ${VAR[subscript]}
    def to_string(%{name: name, subscript: nil, expansion: nil}) do
      "$#{name}"
    end

    def to_string(%{name: name, subscript: subscript, expansion: nil}) do
      "${#{name}#{format_subscript(subscript)}}"
    end

    # Variable with expansion - always uses ${...} form
    def to_string(%{name: name, subscript: subscript, expansion: expansion}) do
      name_with_subscript = "#{name}#{format_subscript(subscript)}"

      case expansion do
        {:default, word} ->
          "${#{name_with_subscript}:-#{word}}"

        {:assign_default, word} ->
          "${#{name_with_subscript}:=#{word}}"

        {:error, word} ->
          "${#{name_with_subscript}:?#{word}}"

        {:alternate, word} ->
          "${#{name_with_subscript}:+#{word}}"

        {:length} ->
          "${##{name_with_subscript}}"

        {:substring, offset, nil} ->
          "${#{name_with_subscript}:#{offset}}"

        {:substring, offset, length} ->
          "${#{name_with_subscript}:#{offset}:#{length}}"

        {:remove_prefix, pattern, :shortest} ->
          "${#{name_with_subscript}##{pattern}}"

        {:remove_prefix, pattern, :longest} ->
          "${#{name_with_subscript}###{pattern}}"

        {:remove_suffix, pattern, :shortest} ->
          "${#{name_with_subscript}%#{pattern}}"

        {:remove_suffix, pattern, :longest} ->
          "${#{name_with_subscript}%%#{pattern}}"

        {:substitute, pattern, replacement, :first} ->
          "${#{name_with_subscript}/#{pattern}/#{replacement}}"

        {:substitute, pattern, replacement, :all} ->
          "${#{name_with_subscript}//#{pattern}/#{replacement}}"

        {:prefix_names, :star} ->
          "${!#{name}*}"

        {:prefix_names, :at} ->
          "${!#{name}@}"

        {:transform, op} ->
          "${#{name_with_subscript}@#{transform_op_char(op)}}"
      end
    end

    defp format_subscript(nil), do: ""
    defp format_subscript(:all_values), do: "[@]"
    defp format_subscript(:all_star), do: "[*]"
    defp format_subscript({:index, idx}), do: "[#{idx}]"

    defp transform_op_char(:quote), do: "Q"
    defp transform_op_char(:escape), do: "E"
    defp transform_op_char(:prompt), do: "P"
    defp transform_op_char(:assignment), do: "A"
    defp transform_op_char(:quoted_keys), do: "K"
    defp transform_op_char(:keys), do: "k"
    defp transform_op_char(:attributes), do: "a"
    defp transform_op_char(:upper), do: "u"
    defp transform_op_char(:lower), do: "L"
  end

  defimpl Inspect do
    def inspect(%{name: name}, _opts) do
      "#Variable{#{name}}"
    end
  end
end
