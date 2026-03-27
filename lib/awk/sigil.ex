defmodule AWK.Sigil do
  @moduledoc """
  Sigil implementation for `~AWK`.

  Parses AWK programs at compile time into `AWK.AST.Program` structs.
  Supports Elixir `\#{}` interpolation for dynamic program construction.

  ## Examples

      # Parse a simple AWK program:
      iex> import AWK.Sigil
      iex> prog = ~AWK'{print $1}'
      %AWK.AST.Program{...}

      # Pattern-action rules:
      iex> import AWK.Sigil
      iex> prog = ~AWK'/error/ {print NR, $0}'
      %AWK.AST.Program{...}

      # BEGIN/END blocks:
      iex> import AWK.Sigil
      iex> prog = ~AWK'BEGIN {FS=","} {print $2} END {print NR}'
      %AWK.AST.Program{...}

  ## String Delimiters

  Single-quoted `~AWK'...'` is recommended to avoid conflicts with AWK string syntax.
  All Elixir sigil delimiters are supported.
  """

  alias AWK.Parser
  alias AWK.Tokenizer
  alias AWK.Error.ParseError

  @doc """
  The `~AWK` sigil for parsing AWK programs.

  Returns an `AWK.AST.Program` struct at compile time.
  """
  defmacro sigil_AWK({:<<>>, _meta, [raw]}, _modifiers) when is_binary(raw) do
    case parse_awk(raw) do
      {:ok, ast} ->
        Macro.escape(ast)

      {:error, %ParseError{} = error} ->
        raise error
    end
  end

  defmacro sigil_AWK({:<<>>, _meta, parts}, _modifiers) do
    quote do
      raw = unquote({:<<>>, [], parts})

      case AWK.Sigil.parse_awk(raw) do
        {:ok, ast} -> ast
        {:error, error} -> raise error
      end
    end
  end

  @doc false
  def parse_awk(source) do
    with {:ok, tokens} <- Tokenizer.tokenize(source) do
      Parser.parse(tokens)
    end
  end
end
