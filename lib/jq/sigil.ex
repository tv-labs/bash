defmodule JQ.Sigil do
  @moduledoc """
  Sigil implementation for `~JQ`.

  Parses jq filter expressions at compile time into `JQ.AST` structs.
  Supports Elixir `\#{}` interpolation for dynamic filter construction.

  ## Examples

      # Parse a filter at compile time:
      iex> import JQ.Sigil
      iex> ~JQ'.'
      %JQ.AST.Identity{}

      # Field access:
      iex> import JQ.Sigil
      iex> ~JQ'.name'
      %JQ.AST.Field{name: "name"}

      # Complex filters:
      iex> import JQ.Sigil
      iex> ~JQ'.[] | select(.age > 21)'
      %JQ.AST.Pipe{...}

  ## Modifiers

  - No modifier: Returns the parsed `JQ.AST` filter struct (default)
  - `s`: Returns a `JQ.Program` struct with streaming support

  ## String Delimiters

  Supports all Elixir sigil delimiters:

      ~JQ'.'
      ~JQ"."
      ~JQ|.|
      ~JQ(.)
      ~JQ[.]
      ~JQ{.}
      ~JQ<.>

  Single-quoted `~JQ'...'` is recommended to avoid conflicts with jq string syntax.
  """

  alias JQ.Parser
  alias JQ.Error.ParseError

  @doc """
  The `~JQ` sigil for parsing jq filter expressions.

  Returns a `JQ.AST` filter struct at compile time.
  """
  defmacro sigil_JQ({:<<>>, _meta, [raw]}, _modifiers) when is_binary(raw) do
    case Parser.parse(raw) do
      {:ok, ast} ->
        Macro.escape(ast)

      {:error, %ParseError{} = error} ->
        raise error
    end
  end

  defmacro sigil_JQ({:<<>>, _meta, parts}, _modifiers) do
    quote do
      raw = unquote({:<<>>, [], parts})

      case Parser.parse(raw) do
        {:ok, ast} -> ast
        {:error, error} -> raise error
      end
    end
  end
end
