defmodule Bash.AST.BraceExpand do
  @moduledoc """
  Brace expansion AST node.

  Represents brace expansion patterns like `{a,b,c}` or `{1..10}`.

  ## Types

  - `:list` - Comma-separated alternatives: `{a,b,c}`
  - `:range` - Sequence generation: `{1..10}`, `{a..z}`, `{1..10..2}`

  ## Examples

      # List: {a,b,c}
      %BraceExpand{type: :list, items: ["a", "b", "c"]}

      # Numeric range: {1..5}
      %BraceExpand{type: :range, range_start: "1", range_end: "5"}

      # Range with step: {1..10..2}
      %BraceExpand{type: :range, range_start: "1", range_end: "10", step: 2}

      # Zero-padded: {01..05}
      %BraceExpand{type: :range, range_start: "01", range_end: "05", zero_pad: 2}
  """

  alias Bash.AST

  @type t :: %__MODULE__{
          meta: AST.Meta.t() | nil,
          type: :list | :range,
          # For :list type - list of items (each item is a list of word parts)
          items: [[word_part()]] | nil,
          # For :range type
          range_start: String.t() | nil,
          range_end: String.t() | nil,
          step: integer() | nil,
          zero_pad: non_neg_integer() | nil
        }

  @type word_part ::
          {:literal, String.t()}
          | {:brace_expand, t()}
          | {:variable, String.t()}
          | {:variable_braced, String.t(), keyword()}
          | {:command_subst, String.t()}
          | {:arith_expand, String.t()}
          | {:single_quoted, String.t()}
          | {:double_quoted, [word_part()]}

  defstruct [:meta, :type, :items, :range_start, :range_end, :step, :zero_pad]

  # Expand a brace expansion into a list of strings.
  #
  # For list type, returns the items.
  # For range type, generates the sequence.
  # Returns `{:ok, [String.t()]}` or `{:error, reason}` for invalid ranges.
  @doc false
  @spec expand(t()) :: {:ok, [String.t()]} | {:error, :invalid_range}
  def expand(%__MODULE__{type: :list, items: items}) do
    {:ok, Enum.flat_map(items, &expand_item/1)}
  end

  def expand(%__MODULE__{type: :range} = brace) do
    expand_range(brace)
  end

  # Expand a single item which may contain nested brace expansions
  defp expand_item(parts) when is_list(parts) do
    expand_parts(parts)
  end

  defp expand_item(str) when is_binary(str), do: [str]

  # Expand a list of word parts, handling nested brace expansions.
  #
  # Returns a list of all possible string combinations.
  @doc false
  @spec expand_parts([word_part()]) :: [String.t()]
  def expand_parts([]), do: [""]

  def expand_parts(parts) do
    # Split into segments, expand each, compute cartesian product
    parts
    |> Enum.map(&expand_part/1)
    |> cartesian_product()
    |> Enum.map(&Enum.join/1)
  end

  defp expand_part({:literal, str}), do: [str]
  defp expand_part({:single_quoted, str}), do: [str]

  defp expand_part({:brace_expand, brace}) do
    case expand(brace) do
      {:ok, items} -> items
      {:error, _} -> [format_range_literal(brace)]
    end
  end

  # For other parts that need session state, just convert to string representation
  # These will be expanded later in the pipeline
  defp expand_part({:variable, name}), do: ["$" <> name]
  defp expand_part({:variable_braced, name, _opts}), do: ["${" <> name <> "}"]
  defp expand_part({:command_subst, cmd}), do: ["$(" <> cmd <> ")"]
  defp expand_part({:arith_expand, expr}), do: ["$((" <> expr <> "))"]
  defp expand_part({:double_quoted, parts}), do: [expand_double_quoted(parts)]

  defp expand_double_quoted(parts) do
    # Inside double quotes, brace expansion doesn't happen
    Enum.map_join(parts, "", fn
      {:literal, str} -> str
      {:single_quoted, str} -> str
      {:variable, name} -> "$" <> name
      {:variable_braced, name, _} -> "${" <> name <> "}"
      {:command_subst, cmd} -> "$(" <> cmd <> ")"
      {:arith_expand, expr} -> "$((" <> expr <> "))"
      # Shouldn't happen inside quotes
      {:brace_expand, _} -> ""
      {:double_quoted, inner} -> expand_double_quoted(inner)
    end)
  end

  # Compute cartesian product of list of lists
  defp cartesian_product([]), do: [[]]

  defp cartesian_product([head | tail]) do
    tail_product = cartesian_product(tail)
    for h <- head, t <- tail_product, do: [h | t]
  end

  defp format_range_literal(%__MODULE__{range_start: s, range_end: e, step: step}) do
    step_str = if step, do: "..#{step}", else: ""
    "{#{s}..#{e}#{step_str}}"
  end

  # Expand a range specification
  defp expand_range(%__MODULE__{
         range_start: start_str,
         range_end: end_str,
         step: step,
         zero_pad: zero_pad
       }) do
    cond do
      # Numeric range
      numeric?(start_str) and numeric?(end_str) ->
        expand_numeric_range(start_str, end_str, step, zero_pad)

      # Alpha range - both must be same case (both lower or both upper)
      single_lower?(start_str) and single_lower?(end_str) ->
        expand_alpha_range(start_str, end_str, step)

      single_upper?(start_str) and single_upper?(end_str) ->
        expand_alpha_range(start_str, end_str, step)

      # Mixed case alpha range - this is a syntax error (status 2)
      single_alpha?(start_str) and single_alpha?(end_str) ->
        {:error, :invalid_range}

      # Completely invalid range (mixed types) - treat as literal
      true ->
        {:error, :not_a_range}
    end
  end

  defp numeric?(str) do
    case Integer.parse(str) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp single_lower?(<<c>>) when c in ?a..?z, do: true
  defp single_lower?(_), do: false

  defp single_upper?(<<c>>) when c in ?A..?Z, do: true
  defp single_upper?(_), do: false

  defp single_alpha?(<<c>>) when c in ?a..?z or c in ?A..?Z, do: true
  defp single_alpha?(_), do: false

  defp expand_numeric_range(start_str, end_str, step, zero_pad) do
    {start_num, ""} = Integer.parse(start_str)
    {end_num, ""} = Integer.parse(end_str)

    pad_width = zero_pad || 0

    # Bash ignores step sign and treats 0 as 1
    abs_step = if step, do: max(abs(step), 1), else: 1

    cond do
      start_num == end_num ->
        {:ok, [format_padded_number(start_num, pad_width)]}

      start_num < end_num ->
        {:ok, format_numeric_range(start_num..end_num//abs_step, pad_width)}

      true ->
        {:ok, format_numeric_range(start_num..end_num//-abs_step, pad_width)}
    end
  end

  defp format_numeric_range(range, pad_width) do
    range
    |> Enum.to_list()
    |> Enum.map(&format_padded_number(&1, pad_width))
  end

  defp format_padded_number(n, pad_width) when pad_width > 0 do
    if n < 0 do
      # For negative numbers, pad after the minus sign
      formatted = Integer.to_string(abs(n))
      # pad_width includes the minus sign
      "-" <> String.pad_leading(formatted, pad_width - 1, "0")
    else
      n |> Integer.to_string() |> String.pad_leading(pad_width, "0")
    end
  end

  defp format_padded_number(n, _pad_width), do: Integer.to_string(n)

  defp expand_alpha_range(<<start_char>>, <<end_char>>, step) do
    # Bash ignores step sign and treats 0 as 1
    abs_step = if step, do: max(abs(step), 1), else: 1

    cond do
      start_char == end_char ->
        {:ok, [<<start_char>>]}

      start_char < end_char ->
        {:ok, start_char..end_char//abs_step |> Enum.to_list() |> Enum.map(&<<&1>>)}

      true ->
        {:ok, start_char..end_char//-abs_step |> Enum.to_list() |> Enum.map(&<<&1>>)}
    end
  end
end
