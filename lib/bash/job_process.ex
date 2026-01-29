defmodule Bash.JobProcess do
  @moduledoc """
  GenServer wrapping a background OS process.

  Each background job is managed by a JobProcess GenServer which:
  - Starts and monitors the OS process via ExCmd
  - Accumulates stdout/stderr output preserving order
  - Notifies the Session on status changes (done, stopped)
  - Supports foregrounding (blocks caller until completion)
  - Handles signals (SIGSTOP, SIGCONT, SIGTERM, etc.)

  ## Lifecycle

  1. Started by Session via `start_link/1`
  2. Spawns OS process via ExCmd
  3. Spawns reader tasks for stdout/stderr that send messages back
  4. On process exit, notifies Session and transitions to :done
  5. Can be foregrounded (caller blocks until done)
  6. Can receive signals (kill, stop, continue)
  """

  use GenServer

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  alias Bash.CommandResult
  alias Bash.Job

  defstruct [
    :job,
    :session_pid,
    :os_pid,
    :excmd_process,
    :stdout_reader,
    :stderr_reader,
    :foreground_from,
    :await_start_from,
    :command_string,
    :working_dir,
    :env,
    :last_signal,
    # Sinks for streaming output directly to destination
    :stdout_sink,
    :stderr_sink,
    # Session's persistent output collector for later retrieval
    :output_collector
  ]

  @type t :: %__MODULE__{
          job: Job.t(),
          session_pid: pid(),
          os_pid: pos_integer() | nil,
          excmd_process: pid() | nil,
          stdout_reader: pid() | nil,
          stderr_reader: pid() | nil,
          foreground_from: GenServer.from() | nil,
          command_string: String.t(),
          working_dir: String.t(),
          env: [{String.t(), String.t()}]
        }

  # Start a background job process.
  #
  # ## Options
  #
  # - `:job_number` - Job number assigned by Session (required)
  # - `:command` - Command string to execute (required)
  # - `:args` - List of arguments (default: [])
  # - `:session_pid` - Parent Session pid for notifications (required)
  # - `:working_dir` - Working directory (required)
  # - `:env` - Environment variables as keyword list (default: [])
  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Get current job status and accumulated output.
  @doc false
  @spec get_job(pid()) :: Job.t()
  def get_job(job_pid) do
    GenServer.call(job_pid, :get_job)
  end

  # Bring job to foreground.
  #
  # Blocks until the job completes and returns a CommandResult with all output.
  # If job is stopped, it will be resumed first.
  @doc false
  @spec foreground(pid()) :: {:ok, CommandResult.t()} | {:error, term()}
  def foreground(job_pid) do
    GenServer.call(job_pid, :foreground, :infinity)
  end

  # Resume a stopped job in the background.
  #
  # Sends SIGCONT to the OS process if it's stopped.
  @doc false
  @spec background(pid()) :: :ok | {:error, term()}
  def background(job_pid) do
    GenServer.call(job_pid, :background)
  end

  # Send a signal to the job's OS process.
  #
  # Signal can be an atom (:sigterm, :sigkill, :sigstop, :sigcont) or integer.
  @doc false
  @spec signal(pid(), atom() | integer()) :: :ok | {:error, term()}
  def signal(job_pid, sig) do
    GenServer.call(job_pid, {:signal, sig})
  end

  # Wait for the job to complete.
  #
  # Blocks until the job finishes and returns the exit code.
  @doc false
  @spec wait(pid()) :: {:ok, integer()} | {:error, term()}
  def wait(job_pid) do
    GenServer.call(job_pid, :wait, :infinity)
  end

  # Wait for the job to start and return its OS PID.
  #
  # Blocks until the OS process has actually started. This is useful
  # for getting the correct value for $! immediately after backgrounding.
  @doc false
  @spec await_start(pid()) :: {:ok, pos_integer()} | {:error, term()}
  def await_start(job_pid) do
    GenServer.call(job_pid, :await_start, 5_000)
  end

  @impl true
  def init(opts) do
    # Trap exits to handle ExCmd.Process exit without crashing
    Process.flag(:trap_exit, true)

    job_number = Keyword.fetch!(opts, :job_number)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    session_pid = Keyword.fetch!(opts, :session_pid)
    working_dir = Keyword.fetch!(opts, :working_dir)
    env = Keyword.get(opts, :env, [])

    # Get sinks for streaming output directly
    stdout_sink = Keyword.get(opts, :stdout_sink)
    stderr_sink = Keyword.get(opts, :stderr_sink)
    output_collector = Keyword.get(opts, :output_collector)

    # Build command string for display
    command_string = build_command_string(command, args)

    # Create initial Job struct
    job =
      Job.new(
        job_number: job_number,
        command: command_string,
        erlang_pid: self()
      )

    state = %__MODULE__{
      job: job,
      session_pid: session_pid,
      os_pid: nil,
      excmd_process: nil,
      stdout_reader: nil,
      stderr_reader: nil,
      foreground_from: nil,
      command_string: command_string,
      working_dir: working_dir,
      env: env,
      stdout_sink: stdout_sink,
      stderr_sink: stderr_sink,
      output_collector: output_collector
    }

    # Start the process asynchronously
    {:ok, state, {:continue, {:start_process, command, args}}}
  end

  @impl true
  def handle_continue({:start_process, command, args}, state) do
    case start_os_process(command, args, state.working_dir, state.env) do
      {:ok, excmd_process, os_pid, stdout_reader, stderr_reader} ->
        job = %{state.job | os_pid: os_pid}

        # Notify session that job started
        notify_session(state.session_pid, {:job_started, job})

        # Reply to await_start caller if someone was waiting
        if state.await_start_from do
          GenServer.reply(state.await_start_from, {:ok, os_pid})
        end

        {:noreply,
         %{
           state
           | job: job,
             os_pid: os_pid,
             excmd_process: excmd_process,
             stdout_reader: stdout_reader,
             stderr_reader: stderr_reader,
             await_start_from: nil
         }}

      {:error, reason} ->
        # Process failed to start - write error to stderr sink
        error_msg = "Failed to start: #{inspect(reason)}\n"
        if state.stderr_sink, do: state.stderr_sink.({:stderr, error_msg})

        if state.output_collector do
          Bash.OutputCollector.write(state.output_collector, :stderr, error_msg)
        end

        job = Job.complete(state.job, 127)

        # Reply to await_start caller if someone was waiting
        if state.await_start_from do
          GenServer.reply(state.await_start_from, {:error, reason})
        end

        notify_session(state.session_pid, {:job_completed, job})

        {:stop, :normal, %{state | job: job}}
    end
  end

  @impl true
  def handle_call(:get_job, _from, state) do
    {:reply, state.job, state}
  end

  def handle_call(:await_start, _from, %{os_pid: os_pid} = state) when is_integer(os_pid) do
    # OS process already started, return the pid immediately
    {:reply, {:ok, os_pid}, state}
  end

  def handle_call(:await_start, _from, %{job: %{status: :done}} = state) do
    # Job failed to start
    {:reply, {:error, :job_failed}, state}
  end

  def handle_call(:await_start, from, state) do
    # OS process not started yet, wait for handle_continue to set it
    {:noreply, %{state | await_start_from: from}}
  end

  def handle_call(:foreground, _from, %{job: %{status: :done}} = state) do
    # Already done, return result immediately
    result = build_command_result(state.job)
    {:reply, {:ok, result}, state}
  end

  def handle_call(:foreground, from, %{job: %{status: :stopped}} = state) do
    # Resume the process first, then wait
    case send_signal(state.os_pid, :sigcont) do
      :ok ->
        job = Job.resume(state.job)
        {:noreply, %{state | job: job, foreground_from: {:foreground, from}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:foreground, from, state) do
    # Running - wait for completion
    {:noreply, %{state | foreground_from: {:foreground, from}}}
  end

  def handle_call(:background, _from, %{job: %{status: :stopped}} = state) do
    case send_signal(state.os_pid, :sigcont) do
      :ok ->
        job = Job.resume(state.job)
        notify_session(state.session_pid, {:job_resumed, job})
        {:reply, :ok, %{state | job: job}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:background, _from, %{job: %{status: :running}} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:background, _from, %{job: %{status: :done}} = state) do
    {:reply, {:error, :job_completed}, state}
  end

  def handle_call({:signal, _sig}, _from, %{os_pid: nil} = state) do
    {:reply, {:error, :no_process}, state}
  end

  def handle_call({:signal, sig}, _from, state) do
    result = send_signal(state.os_pid, sig)

    # Handle status changes from signals
    state =
      case {sig, result} do
        {:sigstop, :ok} ->
          job = Job.stop(state.job)
          notify_session(state.session_pid, {:job_stopped, job})
          %{state | job: job}

        {:sigcont, :ok} ->
          job = Job.resume(state.job)
          notify_session(state.session_pid, {:job_resumed, job})
          %{state | job: job}

        _ ->
          state
      end

    # Track the signal for determining exit code when process is killed
    sig_num = if is_integer(sig), do: sig, else: signal_number(sig)
    state = %{state | last_signal: sig_num}

    {:reply, result, state}
  end

  def handle_call(:wait, _from, %{job: %{status: :done}} = state) do
    {:reply, {:ok, state.job.exit_code}, state}
  end

  def handle_call(:wait, from, state) do
    # Store the caller and call type to reply when done
    {:noreply, %{state | foreground_from: {:wait, from}}}
  end

  def handle_call(:detach_from_session, _from, state) do
    # Called by disown to detach this job from its session.
    # The job will continue running but won't notify the session anymore.
    # Unlink from the supervisor process so job survives session termination.
    # This is called by OrphanSupervisor.adopt which will establish its own monitoring.
    {:dictionary, dict} = Process.info(self(), :dictionary)

    case Keyword.get(dict, :"$ancestors") do
      [supervisor_pid | _] when is_pid(supervisor_pid) ->
        Process.unlink(supervisor_pid)

      _ ->
        :ok
    end

    {:reply, :ok, %{state | session_pid: nil}}
  end

  @impl true
  def handle_info({:stdout, data}, state) do
    # Stream output directly to sink instead of accumulating
    if state.stdout_sink, do: state.stdout_sink.({:stdout, data})

    # Also write to session's persistent output collector if available
    if state.output_collector do
      Bash.OutputCollector.write(state.output_collector, :stdout, data)
    end

    {:noreply, state}
  end

  def handle_info({:stderr, data}, state) do
    # Stream output directly to sink instead of accumulating
    if state.stderr_sink, do: state.stderr_sink.({:stderr, data})

    # Also write to session's persistent output collector if available
    if state.output_collector do
      Bash.OutputCollector.write(state.output_collector, :stderr, data)
    end

    {:noreply, state}
  end

  def handle_info({:reader_done, :stdout}, state) do
    {:noreply, %{state | stdout_reader: nil}}
  end

  def handle_info({:reader_done, :stderr}, state) do
    {:noreply, %{state | stderr_reader: nil}}
  end

  def handle_info({:process_exit, {:ok, code}}, state) do
    handle_process_exit(state, code)
  end

  def handle_info({:process_exit, :killed}, state) do
    # Process was killed by a signal - use last_signal to determine exit code
    # Default to SIGTERM (15) if no signal was recorded
    signal = state.last_signal || 15
    exit_code = 128 + signal
    handle_process_exit(state, exit_code)
  end

  def handle_info({:process_exit, {:error, _reason}}, state) do
    # Unknown error - use exit code 1
    handle_process_exit(state, 1)
  end

  # Legacy format for backwards compatibility
  def handle_info({:process_exit, exit_code}, state) when is_integer(exit_code) do
    handle_process_exit(state, exit_code)
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Handle EXIT messages from linked ExCmd.Process - ignore as we get exit via await_exit
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_os_process(command, args, working_dir, env) do
    cmd_parts = [command | args]
    parent = self()

    # Spawn a worker process that owns the ExCmd process
    # This avoids blocking the GenServer on await_exit
    worker =
      spawn(fn ->
        run_command_worker(cmd_parts, working_dir, env, parent)
      end)

    # Wait for the worker to report the OS PID
    receive do
      {:worker_started, os_pid} ->
        {:ok, nil, os_pid, worker, nil}

      {:worker_failed, reason} ->
        {:error, reason}
    after
      5000 ->
        Process.exit(worker, :kill)
        {:error, :timeout}
    end
  end

  defp run_command_worker(cmd_parts, working_dir, env, parent) do
    exec_opts = [
      cd: working_dir,
      env: normalize_env(env),
      stderr: :redirect_to_stdout
    ]

    case ExCmd.Process.start_link(cmd_parts, exec_opts) do
      {:ok, process} ->
        os_pid =
          case ExCmd.Process.os_pid(process) do
            {:ok, pid} -> pid
            pid when is_integer(pid) -> pid
          end

        send(parent, {:worker_started, os_pid})

        # Close stdin since we don't need it for background jobs
        ExCmd.Process.close_stdin(process)

        # Read all output first — ExCmd requires reads from the owner process.
        # read/1 blocks until data is available, returning :eof when the process exits.
        read_and_forward_output(process, parent)

        # Now await exit to get the exit code
        exit_result =
          case ExCmd.Process.await_exit(process, :infinity) do
            {:ok, code} -> {:ok, code}
            {:error, :killed} -> :killed
            {:error, other} -> {:error, other}
          end

        send(parent, {:process_exit, exit_result})

      {:error, reason} ->
        send(parent, {:worker_failed, reason})
    end
  end

  defp read_and_forward_output(process, parent) do
    case ExCmd.Process.read(process) do
      {:ok, data} ->
        send(parent, {:stdout, data})
        read_and_forward_output(process, parent)

      :eof ->
        send(parent, {:reader_done, :stdout})

      {:error, _} ->
        send(parent, {:reader_done, :stdout})
    end
  end

  defp send_signal(os_pid, sig) when is_atom(sig) do
    sig_num = signal_number(sig)
    send_signal(os_pid, sig_num)
  end

  defp send_signal(os_pid, sig_num) when is_integer(sig_num) do
    # Use the kill command to send signals since ExCmd doesn't support it directly
    case System.cmd("kill", ["-#{sig_num}", "#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp normalize_env([]), do: []

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp signal_number(:sigterm), do: 15
  defp signal_number(:sigkill), do: 9
  defp signal_number(:sigstop), do: 19
  defp signal_number(:sigcont), do: 18
  defp signal_number(:sighup), do: 1
  defp signal_number(:sigint), do: 2
  defp signal_number(:sigquit), do: 3
  defp signal_number(:sigusr1), do: 10
  defp signal_number(:sigusr2), do: 12
  defp signal_number(other), do: other

  defp handle_process_exit(state, exit_code) do
    job = Job.complete(state.job, exit_code)

    # Notify session
    notify_session(state.session_pid, {:job_completed, job})

    # Reply to any waiting caller
    state =
      case state.foreground_from do
        {:wait, from} ->
          # For :wait, return just the exit code
          GenServer.reply(from, {:ok, exit_code})
          %{state | foreground_from: nil}

        {:foreground, from} ->
          # For :foreground, return the full result
          result = build_command_result(job)
          GenServer.reply(from, {:ok, result})
          %{state | foreground_from: nil}

        {_, _} = from ->
          # Legacy format - return full result
          result = build_command_result(job)
          GenServer.reply(from, {:ok, result})
          %{state | foreground_from: nil}

        nil ->
          state
      end

    {:noreply, %{state | job: job}}
  end

  defp build_command_result(%Job{} = job) do
    %CommandResult{
      command: job.command,
      exit_code: job.exit_code,
      error: if(job.exit_code == 0, do: nil, else: :command_failed)
    }
  end

  defp build_command_string(command, []), do: command
  defp build_command_string(command, args), do: "#{command} #{Enum.join(args, " ")}"

  # Helper to safely notify session (handles detached/disowned jobs)
  defp notify_session(nil, _message), do: :ok
  defp notify_session(session_pid, message), do: send(session_pid, message)
end
