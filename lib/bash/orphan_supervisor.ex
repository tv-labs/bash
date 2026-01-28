defmodule Bash.OrphanSupervisor do
  @moduledoc """
  GenServer for managing orphaned/disowned jobs.

  When a job is disowned via the `disown` builtin, it is detached from
  the session and monitored by this supervisor. This ensures the job continues
  running even after the session terminates.

  Unlike session-supervised jobs, orphaned jobs:
  - Do not notify any session on completion
  - Continue running until they exit naturally or are killed
  - Are not affected by session termination
  - Are monitored by this supervisor for tracking purposes
  """

  use GenServer

  require Logger

  defstruct orphans: %{}

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %__MODULE__{}}
  end

  @doc """
  Adopt a job from a session's supervisor.

  This is called by the disown builtin to move a job to the orphan supervisor.
  The job will continue running but will no longer be associated with any session.
  The job unlinks from its original supervisor and is monitored by this supervisor.
  """
  @spec adopt(pid()) :: :ok | {:error, term()}
  def adopt(job_pid) when is_pid(job_pid) do
    GenServer.call(__MODULE__, {:adopt, job_pid}, 5000)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  List all orphaned job PIDs being monitored.
  """
  @spec list_orphans() :: [pid()]
  def list_orphans do
    GenServer.call(__MODULE__, :list_orphans)
  end

  @impl true
  def handle_call({:adopt, job_pid}, _from, state) do
    case GenServer.call(job_pid, :detach_from_session, 5000) do
      :ok ->
        ref = Process.monitor(job_pid)
        new_orphans = Map.put(state.orphans, ref, job_pid)
        {:reply, :ok, %{state | orphans: new_orphans}}

      error ->
        {:reply, error, state}
    end
  catch
    :exit, reason -> {:reply, {:error, {:exit, reason}}, state}
  end

  def handle_call(:list_orphans, _from, state) do
    {:reply, Map.values(state.orphans), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.orphans, ref) do
      {^pid, new_orphans} ->
        Logger.debug("Orphaned job #{inspect(pid)} exited: #{inspect(reason)}")
        {:noreply, %{state | orphans: new_orphans}}

      {nil, _} ->
        {:noreply, state}
    end
  end
end
