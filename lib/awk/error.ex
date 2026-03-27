defmodule AWK.Error do
  @moduledoc "Error types for the AWK interpreter."

  defmodule ParseError do
    @moduledoc "Raised when AWK program syntax is invalid."

    @type t :: %__MODULE__{
            message: String.t(),
            line: pos_integer(),
            column: non_neg_integer(),
            source: String.t() | nil
          }

    defexception [:message, :line, :column, :source]

    @impl true
    def message(%__MODULE__{message: msg, line: line, column: column, source: source}) do
      location = "line #{line}, column #{column}"

      case source do
        nil -> "#{msg} at #{location}"
        src -> "#{msg} at #{location} in #{src}"
      end
    end
  end

  defmodule RuntimeError do
    @moduledoc "Raised for runtime errors during AWK program execution."

    @type t :: %__MODULE__{message: String.t()}

    defexception [:message]
  end
end
