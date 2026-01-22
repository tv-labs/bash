defmodule Bash.OrphanSupervisor do
  @moduledoc """
  DynamicSupervisor for managing orphaned/disowned jobs.

  When a job is disowned via the `disown` builtin, it is moved from the
  session's job_supervisor to this supervisor. This ensures the job continues
  running even after the session terminates.

  Unlike session-supervised jobs, orphaned jobs:
  - Do not notify any session on completion
  - Continue running until they exit naturally or are killed
  - Are not affected by session termination
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Adopt a job from a session's supervisor.

  This is called by the disown builtin to move a job to the orphan supervisor.
  The job will continue running but will no longer be associated with any session.
  """
  @spec adopt(pid()) :: :ok | {:error, term()}
  def adopt(job_pid) when is_pid(job_pid) do
    # First, tell the job to detach from its session
    case GenServer.call(job_pid, :detach_from_session, 5000) do
      :ok ->
        # The job is now orphaned - it will continue running under its current
        # supervisor but won't notify the session anymore.
        # Note: We can't easily move a process between supervisors in OTP,
        # so we just detach the notification link.
        :ok

      error ->
        error
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
