defmodule JQ do
  @moduledoc """
  A complete jq language interpreter implemented in pure Elixir.

  Parses and evaluates jq filter expressions against JSON-compatible Elixir data.
  Supports the full jq language including streaming, function definitions,
  try-catch, reduce, foreach, path operations, and all builtins.

  ## Value Mapping

  jq values map to Elixir terms:

  | jq type  | Elixir type          |
  |----------|----------------------|
  | null     | `nil`                |
  | boolean  | `true` / `false`     |
  | number   | `integer` / `float`  |
  | string   | `String.t()`         |
  | array    | `list`               |
  | object   | `map` (string keys)  |

  ## Quick Start

      iex> JQ.run!(".", %{"name" => "Alice"})
      [%{"name" => "Alice"}]

      iex> JQ.run!(".name", %{"name" => "Alice"})
      ["Alice"]

      iex> JQ.run!(".[] | . * 2", [1, 2, 3])
      [2, 4, 6]

      iex> JQ.run!("{a: .x, b: .y}", %{"x" => 1, "y" => 2})
      [%{"a" => 1, "b" => 2}]

  ## Streaming

      iex> stream = JQ.stream(".[] | . + 1", Stream.cycle([[1, 2, 3]]))
      iex> Enum.take(stream, 6)
      [2, 3, 4, 2, 3, 4]

  ## Compile-Time Parsing with Sigil

      import JQ.Sigil

      filter = ~JQ'.[] | select(.age > 21) | .name'
      JQ.eval!(filter, users)
  """

  alias JQ.AST
  alias JQ.Evaluator
  alias JQ.Parser
  alias JQ.Error.ParseError

  @type value :: nil | boolean() | number() | String.t() | [value()] | %{String.t() => value()}
  @type filter :: AST.filter()

  @doc """
  Parses a jq filter string into an AST.

  ## Examples

      iex> JQ.parse(".")
      {:ok, %JQ.AST.Identity{}}

      iex> JQ.parse(".foo")
      {:ok, %JQ.AST.Field{name: "foo"}}

      iex> JQ.parse("invalid!!!")
      {:error, %JQ.Error.ParseError{}}
  """
  @spec parse(String.t()) :: {:ok, filter()} | {:error, ParseError.t()}
  defdelegate parse(source), to: Parser

  @doc """
  Parses a jq filter string into an AST, raising on error.
  """
  @spec parse!(String.t()) :: filter()
  defdelegate parse!(source), to: Parser

  @doc """
  Evaluates a pre-parsed filter AST against an input value.

  Returns `{:ok, results}` where results is a list of output values,
  or `{:error, reason}`.

  ## Examples

      iex> {:ok, filter} = JQ.parse(".name")
      iex> JQ.eval(filter, %{"name" => "Alice"})
      {:ok, ["Alice"]}
  """
  @spec eval(filter(), value(), keyword()) :: {:ok, [value()]} | {:error, term()}
  def eval(filter, input, opts \\ []) do
    env = build_env(opts)
    Evaluator.eval(filter, input, env)
  end

  @doc """
  Evaluates a pre-parsed filter AST against an input value, raising on error.
  """
  @spec eval!(filter(), value(), keyword()) :: [value()]
  def eval!(filter, input, opts \\ []) do
    case eval(filter, input, opts) do
      {:ok, results} -> results
      {:error, reason} -> raise JQ.Error.RuntimeError, message: "#{reason}"
    end
  end

  @doc """
  Parses and evaluates a jq filter string against an input value.

  Combines `parse/1` and `eval/3` for convenience.

  ## Examples

      iex> JQ.run(".", 42)
      {:ok, [42]}

      iex> JQ.run(".[] | . + 1", [1, 2, 3])
      {:ok, [2, 3, 4]}

      iex> JQ.run("map(select(. > 2))", [1, 2, 3, 4])
      {:ok, [[3, 4]]}
  """
  @spec run(String.t(), value(), keyword()) :: {:ok, [value()]} | {:error, term()}
  def run(source, input, opts \\ []) do
    with {:ok, filter} <- parse(source) do
      eval(filter, input, opts)
    end
  end

  @doc """
  Parses and evaluates a jq filter string, raising on error.
  """
  @spec run!(String.t(), value(), keyword()) :: [value()]
  def run!(source, input, opts \\ []) do
    case run(source, input, opts) do
      {:ok, results} -> results
      {:error, %ParseError{} = e} -> raise e
      {:error, reason} -> raise JQ.Error.RuntimeError, message: "#{reason}"
    end
  end

  @doc """
  Applies a pre-parsed filter to a stream of input values, producing
  a lazy stream of output values. Never accumulates the entire input
  or output in memory.

  ## Examples

      iex> inputs = Stream.map(1..5, & &1)
      iex> filter = JQ.parse!(". * 2")
      iex> JQ.eval_stream(filter, inputs) |> Enum.to_list()
      [2, 4, 6, 8, 10]
  """
  @spec eval_stream(filter(), Enumerable.t(), keyword()) :: Enumerable.t()
  def eval_stream(filter, input_stream, opts \\ []) do
    env = build_env(opts)
    Evaluator.eval_stream(filter, input_stream, env)
  end

  @doc """
  Parses a filter string and applies it to a stream of input values.
  """
  @spec stream(String.t(), Enumerable.t(), keyword()) :: Enumerable.t()
  def stream(source, input_stream, opts \\ []) do
    filter = parse!(source)
    eval_stream(filter, input_stream, opts)
  end

  @doc """
  Returns the first result of evaluating a filter, or nil if no results.

  Useful for filters expected to produce a single output.

  ## Examples

      iex> JQ.one!(".name", %{"name" => "Alice"})
      "Alice"
  """
  @spec one!(String.t(), value(), keyword()) :: value() | nil
  def one!(source, input, opts \\ []) do
    case run!(source, input, opts) do
      [first | _] -> first
      [] -> nil
    end
  end

  defp build_env(opts) do
    bindings = Keyword.get(opts, :bindings, %{})
    functions = Keyword.get(opts, :functions, %{})
    %Evaluator.Env{bindings: bindings, functions: functions}
  end
end
