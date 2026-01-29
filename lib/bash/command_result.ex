defmodule Bash.CommandResult do
  @moduledoc """
  Represents the result of executing a command.

  Output is streamed through sinks during execution rather than accumulated here.
  Use `OutputCollector` to capture output when needed for testing.

  ## Fields

  - `command` - The command string that was executed
  - `exit_code` - The exit code (0 for success, non-zero for failure)
  - `error` - Error type if command failed (`:command_not_found`, `:timeout`, etc.)
  """

  defstruct [
    :command,
    :exit_code,
    :error
  ]

  @type error_type :: :command_not_found | :command_failed | :timeout | term()

  @type t :: %__MODULE__{
          command: String.t(),
          exit_code: non_neg_integer() | nil,
          error: error_type() | nil
        }

  # Returns true if the command succeeded (exit code 0, no error).
  @doc false
  def success?(%__MODULE__{exit_code: 0, error: nil}), do: true
  def success?(%__MODULE__{}), do: false

  # Returns true if there was an error.
  @doc false
  def error?(%__MODULE__{error: nil}), do: false
  def error?(%__MODULE__{}), do: true

  defimpl String.Chars do
    def to_string(%{command: command}) do
      command || "(command result)"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{exit_code: exit_code}, opts) do
      if exit_code do
        concat(["#Result{} => ", color("#{exit_code}", :number, opts)])
      else
        "#Result{}"
      end
    end
  end
end
