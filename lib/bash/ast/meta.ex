defmodule Bash.AST.Meta do
  @moduledoc """
  Source location metadata attached to every AST node.
  Used for error reporting, debugging, and execution tracking.

  ## Fields

  ### Source Location
  - `line` - Line number in source (1-indexed)
  - `column` - Column number in source (1-indexed)
  - `source_range` - Character range in source (optional)

  ### Evaluation Tracking (nil before execution)
  - `evaluated` - `true` if node was executed, `false` if skipped, `nil` if not yet run
  - `duration_ms` - Execution time in milliseconds
  - `started_at` - DateTime when execution started
  - `completed_at` - DateTime when execution completed
  """

  @type t :: %__MODULE__{
          line: pos_integer(),
          column: pos_integer(),
          source_range: Range.t() | nil,
          evaluated: boolean() | nil,
          duration_ms: non_neg_integer() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  defstruct line: 1,
            column: 1,
            source_range: nil,
            evaluated: nil,
            duration_ms: nil,
            started_at: nil,
            completed_at: nil

  @doc """
  Mark meta as evaluated with timing information.
  """
  @spec mark_evaluated(t(), DateTime.t(), DateTime.t()) :: t()
  def mark_evaluated(%__MODULE__{} = meta, started_at, completed_at) do
    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    %{
      meta
      | evaluated: true,
        started_at: started_at,
        completed_at: completed_at,
        duration_ms: duration_ms
    }
  end

  @doc """
  Mark meta as skipped (not evaluated).
  """
  @spec mark_skipped(t()) :: t()
  def mark_skipped(%__MODULE__{} = meta) do
    %{meta | evaluated: false}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{line: line, column: column, duration_ms: duration_ms}, opts) do
      if duration_ms do
        concat([
          "#Meta{",
          color("#{line}:#{column}", :number, opts),
          ", ",
          color("#{duration_ms}ms", :number, opts),
          "}"
        ])
      else
        concat(["#Meta{", color("#{line}:#{column}", :number, opts), "}"])
      end
    end
  end
end
