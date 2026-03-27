defmodule AWK do
  @moduledoc """
  A complete AWK language interpreter implemented in pure Elixir.

  Parses and executes AWK programs against streams of text input.
  Supports the full AWK language including pattern-action rules,
  associative arrays, regular expressions, user-defined functions,
  and all standard built-in functions.

  ## Quick Start

      iex> AWK.run!("{print $1}", "hello world\\nfoo bar")
      "hello\\nfoo\\n"

      iex> AWK.run!("BEGIN {FS=\\",\\"} {print $2}", "a,b,c\\nd,e,f")
      "b\\ne\\n"

      iex> AWK.run!("/error/ {count++} END {print count}", "ok\\nerror here\\nerror there")
      "2\\n"

  ## Streaming

      iex> lines = Stream.map(["hello world", "foo bar"], & &1)
      iex> AWK.stream("{print $1}", lines) |> Enum.to_list()
      ["hello\\n", "foo\\n"]

  ## Compile-Time Parsing with Sigil

      import AWK.Sigil

      program = ~AWK'BEGIN {FS=","} {sum += $2} END {print sum}'
      AWK.eval!(program, csv_data)

  ## AWK Processing Model

  ```mermaid
  graph TD
      A[Input Stream] --> B[Split into Records by RS]
      B --> C[For Each Record]
      C --> D[Split into Fields by FS]
      D --> E[Match Against Patterns]
      E --> F[Execute Matching Actions]
      F --> G[Output Stream]
      H[BEGIN Rules] --> C
      C --> I[END Rules]
      I --> G
  ```
  """

  alias AWK.AST
  alias AWK.Evaluator
  alias AWK.Parser
  alias AWK.Tokenizer
  alias AWK.Error.ParseError

  @type program :: AST.Program.t()

  @doc """
  Parses an AWK program string into an AST.

  ## Examples

      iex> AWK.parse("{print}")
      {:ok, %AWK.AST.Program{}}
  """
  @spec parse(String.t()) :: {:ok, program()} | {:error, ParseError.t()}
  def parse(source) do
    with {:ok, tokens} <- Tokenizer.tokenize(source) do
      Parser.parse(tokens)
    end
  end

  @doc """
  Parses an AWK program string into an AST, raising on error.
  """
  @spec parse!(String.t()) :: program()
  def parse!(source) do
    case parse(source) do
      {:ok, program} -> program
      {:error, error} -> raise error
    end
  end

  @doc """
  Evaluates a pre-parsed AWK program against input text.

  Returns `{:ok, output}` where output is the collected stdout string,
  or `{:error, reason}`.

  ## Options

    * `:variables` - map of variable name => value to pre-set
    * `:fs` - field separator (default: `" "`)

  ## Examples

      iex> {:ok, prog} = AWK.parse("{print NR, $1}")
      iex> AWK.eval(prog, "hello world\\nfoo bar")
      {:ok, "1 hello\\n2 foo\\n"}
  """
  @spec eval(program(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def eval(program, input, opts \\ []) do
    Evaluator.run_string(program, input, opts)
  end

  @doc """
  Evaluates a pre-parsed AWK program, raising on error.
  """
  @spec eval!(program(), String.t(), keyword()) :: String.t()
  def eval!(program, input, opts \\ []) do
    case eval(program, input, opts) do
      {:ok, output} -> output
      {:error, reason} -> raise AWK.Error.RuntimeError, message: "#{reason}"
    end
  end

  @doc """
  Parses and evaluates an AWK program against input text.

  ## Examples

      iex> AWK.run("{print $1}", "hello world")
      {:ok, "hello\\n"}

      iex> AWK.run("BEGIN {print 2+2}")
      {:ok, "4\\n"}
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(source, input \\ "", opts \\ []) do
    with {:ok, program} <- parse(source) do
      eval(program, input, opts)
    end
  end

  @doc """
  Parses and evaluates an AWK program, raising on error.
  """
  @spec run!(String.t(), String.t(), keyword()) :: String.t()
  def run!(source, input \\ "", opts \\ []) do
    case run(source, input, opts) do
      {:ok, output} -> output
      {:error, %ParseError{} = e} -> raise e
      {:error, reason} -> raise AWK.Error.RuntimeError, message: "#{reason}"
    end
  end

  @doc """
  Applies a pre-parsed AWK program to a stream of input lines,
  producing a lazy stream of output strings. Never accumulates
  all input in memory.

  ## Examples

      iex> lines = ["hello world", "foo bar"]
      iex> {:ok, prog} = AWK.parse("{print $1}")
      iex> AWK.eval_stream(prog, lines) |> Enum.to_list()
      ["hello\\n", "foo\\n"]
  """
  @spec eval_stream(program(), Enumerable.t(), keyword()) :: Enumerable.t()
  def eval_stream(program, input_stream, opts \\ []) do
    Evaluator.run(program, input_stream, opts)
  end

  @doc """
  Parses an AWK program and applies it to an input stream.
  """
  @spec stream(String.t(), Enumerable.t(), keyword()) :: Enumerable.t()
  def stream(source, input_stream, opts \\ []) do
    program = parse!(source)
    eval_stream(program, input_stream, opts)
  end
end
