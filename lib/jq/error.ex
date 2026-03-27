defmodule JQ.Error do
  @moduledoc """
  Error types for the JQ interpreter.

  Defines structured error types for parse errors, type errors,
  and runtime errors that occur during jq filter evaluation.
  """

  defmodule ParseError do
    @moduledoc """
    Raised when jq filter syntax is invalid.

    ## Fields

      * `:message` - Human-readable error description
      * `:line` - Line number where the error occurred (1-based)
      * `:column` - Column number where the error occurred (0-based)
      * `:source` - The source string being parsed
    """

    defexception [:message, :line, :column, :source]

    @type t :: %__MODULE__{
            message: String.t(),
            line: pos_integer(),
            column: non_neg_integer(),
            source: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg, line: line, column: col}) do
      "jq parse error at line #{line}, column #{col}: #{msg}"
    end
  end

  defmodule TypeError do
    @moduledoc """
    Raised when a jq operation receives an incompatible type.

    For example, attempting to index a number or add a string to an array.
    """

    defexception [:message, :value, :expected]

    @type t :: %__MODULE__{
            message: String.t(),
            value: term(),
            expected: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg}), do: msg
  end

  defmodule RuntimeError do
    @moduledoc """
    Raised for general runtime errors during jq filter evaluation.
    """

    defexception [:message]

    @type t :: %__MODULE__{message: String.t()}

    @impl true
    def message(%__MODULE__{message: msg}), do: msg
  end

  @doc """
  Returns the jq type name for a given Elixir value.
  """
  @spec type_name(term()) :: String.t()
  def type_name(nil), do: "null"
  def type_name(v) when is_boolean(v), do: "boolean"
  def type_name(v) when is_integer(v), do: "number"
  def type_name(v) when is_float(v), do: "number"
  def type_name(v) when is_binary(v), do: "string"
  def type_name(v) when is_list(v), do: "array"
  def type_name(v) when is_map(v), do: "object"
  def type_name(_), do: "unknown"
end
