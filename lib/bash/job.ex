defmodule Bash.Job do
  @moduledoc ~S"""
  Represents a background job in a Bash session.

  Each job has:
  - A job number (1-based, assigned by Session)
  - An OS process ID (from ExCmd)
  - Status tracking (running, stopped, done)

  ## Job States

  - `:running` - Process is actively executing
  - `:stopped` - Process has been suspended (SIGSTOP)
  - `:done` - Process has completed (exit code available)

  ## Output

  Job output flows through sinks to the session's OutputCollector,
  not accumulated in the Job struct itself.
  """

  @type status :: :running | :stopped | :done

  @type t :: %__MODULE__{
          job_number: pos_integer(),
          os_pid: pos_integer() | nil,
          erlang_pid: pid() | nil,
          command: String.t(),
          status: status(),
          exit_code: integer() | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil
        }

  defstruct [
    :job_number,
    :os_pid,
    :erlang_pid,
    :command,
    :status,
    :exit_code,
    :started_at,
    :completed_at
  ]

  # Create a new Job struct.
  #
  # ## Options
  #
  # - `:job_number` - Job number assigned by Session (required)
  # - `:command` - Command string for display (required)
  # - `:os_pid` - OS process ID from ExCmd
  # - `:erlang_pid` - JobProcess GenServer pid
  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      job_number: Keyword.fetch!(opts, :job_number),
      command: Keyword.fetch!(opts, :command),
      os_pid: Keyword.get(opts, :os_pid),
      erlang_pid: Keyword.get(opts, :erlang_pid),
      status: :running,
      exit_code: nil,
      started_at: DateTime.utc_now(),
      completed_at: nil
    }
  end

  # Mark the job as completed with the given exit code.
  @doc false
  @spec complete(t(), integer()) :: t()
  def complete(%__MODULE__{} = job, exit_code) do
    %{job | status: :done, exit_code: exit_code, completed_at: DateTime.utc_now()}
  end

  # Mark the job as stopped (suspended).
  @doc false
  @spec stop(t()) :: t()
  def stop(%__MODULE__{} = job) do
    %{job | status: :stopped}
  end

  # Mark the job as running (resumed from stopped).
  @doc false
  @spec resume(t()) :: t()
  def resume(%__MODULE__{} = job) do
    %{job | status: :running}
  end

  # Check if the job has completed successfully (exit code 0).
  @doc false
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{status: :done, exit_code: 0}), do: true
  def success?(_), do: false

  # Check if the job is still running.
  @doc false
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(_), do: false

  # Check if the job is stopped (suspended).
  @doc false
  @spec stopped?(t()) :: boolean()
  def stopped?(%__MODULE__{status: :stopped}), do: true
  def stopped?(_), do: false

  # Check if the job is done (completed).
  @doc false
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{status: :done}), do: true
  def done?(_), do: false

  # Format job for display in `jobs` output.
  #
  # Returns a string like:
  #
  # [1]+  Running                 sleep 100 &
  # [2]-  Done                    echo hello
  @doc false
  @spec format(t(), keyword()) :: String.t()
  def format(%__MODULE__{} = job, opts \\ []) do
    current = Keyword.get(opts, :current, false)
    previous = Keyword.get(opts, :previous, false)
    show_pid = Keyword.get(opts, :show_pid, false)

    marker =
      cond do
        current -> "+"
        previous -> "-"
        true -> " "
      end

    status_str =
      case job.status do
        :running -> "Running"
        :stopped -> "Stopped"
        :done when job.exit_code == 0 -> "Done"
        :done -> "Exit #{job.exit_code}"
      end

    pid_str = if show_pid, do: " #{job.os_pid}", else: ""

    "[#{job.job_number}]#{marker}#{pid_str}  #{String.pad_trailing(status_str, 20)}#{job.command}"
  end
end
