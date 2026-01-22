defmodule Bash.Execution do
  @moduledoc """
  Represents a single command execution with its own I/O streams.

  Each command in a session gets its own Execution struct with separate
  StringIO devices for stdout and stderr. This enables:

  - Per-command output inspection after execution
  - Pipeline wiring (previous stdout becomes next stdin)
  - Merged enumeration across all executions

  ## Example

      # Create execution for a command
      {:ok, exec} = Execution.new("echo hello")

      # Write to its streams
      IO.puts(exec.stdout, "hello")

      # Get output after completion
      Execution.stdout_contents(exec)  # => "hello\\n"

  """

  @type t :: %__MODULE__{
          command: String.t(),
          stdout: pid(),
          stderr: pid(),
          exit_code: 0..255 | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil
        }

  defstruct [
    :command,
    :stdout,
    :stderr,
    :exit_code,
    :started_at,
    :completed_at
  ]

  @doc ~S"""
  Creates a new Execution with fresh StringIO streams.

  ## Examples

      {:ok, exec} = Execution.new("echo hello")
      IO.write(exec.stdout, "hello\n")

  """
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(command) when is_binary(command) do
    with {:ok, stdout} <- StringIO.open(""),
         {:ok, stderr} <- StringIO.open("") do
      {:ok,
       %__MODULE__{
         command: command,
         stdout: stdout,
         stderr: stderr,
         exit_code: nil,
         started_at: DateTime.utc_now(),
         completed_at: nil
       }}
    end
  end

  @doc """
  Marks the execution as completed with the given exit code.
  """
  @spec complete(t(), 0..255) :: t()
  def complete(%__MODULE__{} = exec, exit_code) when exit_code in 0..255 do
    %{exec | exit_code: exit_code, completed_at: DateTime.utc_now()}
  end

  @doc """
  Gets the stdout contents from the execution.

  Returns the accumulated output written to stdout.
  """
  @spec stdout_contents(t()) :: String.t()
  def stdout_contents(%__MODULE__{stdout: stdout}) do
    {_input, output} = StringIO.contents(stdout)
    output
  end

  @doc """
  Gets the stderr contents from the execution.

  Returns the accumulated output written to stderr.
  """
  @spec stderr_contents(t()) :: String.t()
  def stderr_contents(%__MODULE__{stderr: stderr}) do
    {_input, output} = StringIO.contents(stderr)
    output
  end

  @doc """
  Closes the StringIO devices for this execution.

  Should be called when the execution is no longer needed to free resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{stdout: stdout, stderr: stderr}) do
    StringIO.close(stdout)
    StringIO.close(stderr)
    :ok
  end
end
