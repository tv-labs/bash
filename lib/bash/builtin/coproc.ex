defmodule Bash.Builtin.Coproc do
  @moduledoc """
  `coproc [NAME] command [redirections]`

  Create a coprocess named NAME.

  Execute COMMAND asynchronously, with the standard output and standard
  input of the command connected via a pipe to file descriptors assigned
  to indices 0 and 1 of an array variable NAME in the executing shell.
  The default NAME is "COPROC".

  The coprocess is executed asynchronously in a subshell, as if the command
  had been terminated with the `&` control operator.

  When the coprocess is executed, the shell creates an array variable NAME
  in the context of the executing shell. The standard output of command is
  connected via a pipe to a file descriptor in the executing shell, and that
  file descriptor is assigned to NAME[0]. The standard input of command is
  connected via a pipe to a file descriptor in the executing shell, and that
  file descriptor is assigned to NAME[1].

  The shell also sets the variable NAME_PID to the process ID of the coprocess.

  Exit Status:
  Returns the exit status of COMMAND.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/reserved.def?h=bash-5.3

  ## Architecture

  Two modes of operation:

  ### External (simple commands like `coproc cat`)

  ```mermaid
  stateDiagram-v2
      [*] --> running: start_link(:external)
      running --> running: read/write via ExCmd.Process
      running --> closing: close_stdin
      closing --> stopped: process exits
      running --> stopped: process exits
      stopped --> [*]
  ```

  ### Internal (compound commands like `coproc MYPROC { cat; }`)

  ```mermaid
  stateDiagram-v2
      [*] --> running: start_link(:internal)
      running --> running: read/write via message passing
      running --> closing: close_stdin
      closing --> stopped: body task exits
      running --> stopped: body task exits
      stopped --> [*]
  ```

  File descriptors stored in the session's `file_descriptors` map contain
  `{:coproc, pid, :read | :write}` tuples that route I/O through this
  GenServer.
  """
  use Bash.Builtin

  alias Bash.Executor
  alias Bash.Variable

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, name, command, cmd_args} ->
        case start_external_coproc(name, command, cmd_args, state) do
          {:ok, updates} ->
            update_state(Map.to_list(updates))
            :ok

          {:error, _code} ->
            {:ok, 1}
        end

      {:error, msg} ->
        error("coproc: failed to start: #{msg}")
        {:ok, 1}
    end
  end

  defp parse_args([]) do
    {:error, "command required"}
  end

  defp parse_args([command]) do
    {:ok, "COPROC", command, []}
  end

  defp parse_args([command | rest]) do
    {:ok, "COPROC", command, rest}
  end

  @doc """
  Start a coproc running an external OS command via ExCmd.
  """
  def start_external_coproc(name, command, cmd_args, session_state) do
    child_spec = %{
      id: {__MODULE__, name},
      start:
        {__MODULE__, :start_link,
         [
           %{
             mode: :external,
             command: command,
             args: cmd_args,
             working_dir: session_state.working_dir,
             env: build_env(session_state)
           }
         ]},
      restart: :temporary
    }

    start_coproc_child(name, child_spec, session_state)
  end

  @doc """
  Start a coproc running a compound command body within the Elixir interpreter.
  """
  def start_internal_coproc(name, body_ast, session_state) do
    child_spec = %{
      id: {__MODULE__, name},
      start:
        {__MODULE__, :start_link,
         [
           %{
             mode: :internal,
             body: body_ast,
             session_state: session_state
           }
         ]},
      restart: :temporary
    }

    start_coproc_child(name, child_spec, session_state)
  end

  defp start_coproc_child(name, child_spec, session_state) do
    supervisor = session_state.job_supervisor

    if supervisor == nil do
      Bash.Sink.write_stderr(session_state, "coproc: job supervisor not available\n")
      {:error, 1}
    else
      case DynamicSupervisor.start_child(supervisor, child_spec) do
        {:ok, pid} ->
          case GenServer.call(pid, :get_info) do
            {:ok, os_pid} ->
              register_coproc(name, pid, os_pid, session_state)

            {:error, reason} ->
              GenServer.stop(pid)

              Bash.Sink.write_stderr(
                session_state,
                "coproc: failed to start: #{inspect(reason)}\n"
              )

              {:error, 1}
          end

        {:error, reason} ->
          Bash.Sink.write_stderr(session_state, "coproc: failed to start: #{inspect(reason)}\n")
          {:error, 1}
      end
    end
  end

  defp register_coproc(name, pid, os_pid, session_state) do
    existing_fds = Map.get(session_state, :file_descriptors, %{})
    read_fd = next_available_fd(existing_fds)
    write_fd = next_available_fd(existing_fds, read_fd + 1)

    new_fds =
      existing_fds
      |> Map.put(read_fd, {:coproc, pid, :read})
      |> Map.put(write_fd, {:coproc, pid, :write})

    array_var =
      Variable.new_indexed_array(%{
        0 => to_string(read_fd),
        1 => to_string(write_fd)
      })

    pid_var = Variable.new(to_string(os_pid))

    var_updates = %{
      name => array_var,
      "#{name}_PID" => pid_var
    }

    coproc_updates =
      Map.put(
        Map.get(session_state, :coprocs, %{}),
        name,
        %{pid: pid, os_pid: os_pid, read_fd: read_fd, write_fd: write_fd}
      )

    updates = %{
      var_updates: var_updates,
      coprocs: coproc_updates,
      file_descriptors: new_fds
    }

    # When called from defbash execute, use update_state macro.
    # When called from AST.Coproc.execute, return updates directly.
    {:ok, updates}
  end

  defp next_available_fd(existing_fds) do
    taken = Map.keys(existing_fds) |> Enum.filter(&is_integer/1)

    case taken do
      [] -> 3
      keys -> Enum.max(keys) + 1
    end
  end

  defp next_available_fd(existing_fds, minimum) do
    fd = next_available_fd(existing_fds)
    max(fd, minimum)
  end

  defp build_env(session_state) do
    session_state.variables
    |> Enum.filter(fn {_, v} -> v.attributes[:export] == true end)
    |> Enum.map(fn {k, v} -> {k, Variable.get(v, nil)} end)
  end

  # GenServer Implementation — External mode (ExCmd)

  @impl true
  def init(%{mode: :external} = opts) do
    cmd = [opts.command | opts.args]

    proc_opts = [
      cd: opts.working_dir,
      env: opts.env,
      stderr: :redirect_to_stdout
    ]

    case ExCmd.Process.start_link(cmd, proc_opts) do
      {:ok, pid} ->
        os_pid =
          case ExCmd.Process.os_pid(pid) do
            {:ok, os_pid} -> os_pid
            os_pid when is_integer(os_pid) -> os_pid
          end

        {:ok, %{mode: :external, proc: pid, os_pid: os_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # GenServer Implementation — Internal mode (BEAM process running AST)

  def init(%{mode: :internal} = opts) do
    {:ok, stdin_pipe} = Bash.Pipe.create()
    {:ok, stdout_pipe} = Bash.Pipe.create()

    parent = self()

    # FIFO open blocks until both ends are connected,
    # so body and GenServer must open concurrently.
    pid =
      spawn(fn ->
        {:ok, stdin_r} = Bash.Pipe.open_read(stdin_pipe)
        {:ok, stdout_w} = Bash.Pipe.open_write(stdout_pipe)
        run_internal_body(parent, stdin_r, stdout_w, opts.body, opts.session_state)
      end)

    {:ok, stdin_pipe} = Bash.Pipe.open_write(stdin_pipe)
    {:ok, stdout_pipe} = Bash.Pipe.open_read(stdout_pipe)

    ref = Process.monitor(pid)

    {:ok,
     %{
       mode: :internal,
       os_pid: :erlang.phash2(pid),
       body_pid: pid,
       body_ref: ref,
       stdin_pipe: stdin_pipe,
       stdout_pipe: stdout_pipe
     }}
  end

  defp run_internal_body(_coproc_server, stdin_pipe, stdout_pipe, body, session_state) do
    body_session = %{
      session_state
      | stdout_sink: Bash.Sink.pipe(stdout_pipe),
        stderr_sink: session_state.stderr_sink
    }

    Executor.execute(body, body_session, stdin_pipe)
    Bash.Pipe.close_write(stdout_pipe)
  end

  # Shared callbacks

  @impl true
  def handle_call(:get_info, _from, state) do
    {:reply, {:ok, state.os_pid}, state}
  end

  # Read — external mode
  @impl true
  def handle_call(:read, _from, %{mode: :external} = state) do
    case ExCmd.Process.read(state.proc) do
      {:ok, data} -> {:reply, {:ok, data}, state}
      :eof -> {:reply, :eof, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Read — internal mode
  def handle_call(:read, _from, %{mode: :internal} = state) do
    case Bash.Pipe.read_line(state.stdout_pipe) do
      {:ok, data} -> {:reply, {:ok, data}, state}
      :eof -> {:reply, :eof, state}
    end
  end

  # Write — external mode
  @impl true
  def handle_call({:write, data}, _from, %{mode: :external} = state) do
    case ExCmd.Process.write(state.proc, data) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Write — internal mode
  def handle_call({:write, data}, _from, %{mode: :internal} = state) do
    case Bash.Pipe.write(state.stdin_pipe, data) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Close stdin — external mode
  @impl true
  def handle_call(:close_stdin, _from, %{mode: :external} = state) do
    ExCmd.Process.close_stdin(state.proc)
    {:reply, :ok, state}
  end

  # Close stdin — internal mode
  def handle_call(:close_stdin, _from, %{mode: :internal} = state) do
    Bash.Pipe.close_write(state.stdin_pipe)
    {:reply, :ok, %{state | stdin_pipe: %{state.stdin_pipe | write_end: nil}}}
  end

  # Close stdout — external mode
  @impl true
  def handle_call(:close_stdout, _from, %{mode: :external} = state) do
    ExCmd.Process.close_stdout(state.proc)
    {:reply, :ok, state}
  end

  # Close stdout — internal mode
  def handle_call(:close_stdout, _from, %{mode: :internal} = state) do
    {:reply, :ok, state}
  end

  # Status
  @impl true
  def handle_call(:status, _from, %{mode: :external} = state) do
    case ExCmd.Process.await_exit(state.proc, 0) do
      {:ok, exit_code} -> {:reply, {:exited, exit_code}, state}
      {:error, :timeout} -> {:reply, :running, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, %{mode: :internal} = state) do
    if Process.alive?(state.body_pid) do
      {:reply, :running, state}
    else
      {:reply, {:exited, 0}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _proc, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{mode: :internal, body_ref: ref} = state
      ) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    require Logger
    Logger.debug("Coproc received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{mode: :external} = state) do
    if state.proc do
      ExCmd.Process.close_stdin(state.proc)
      ExCmd.Process.await_exit(state.proc, 1000)
    end

    :ok
  end

  def terminate(_reason, %{mode: :internal} = state) do
    if Process.alive?(state.body_pid), do: Process.exit(state.body_pid, :kill)
    Bash.Pipe.destroy(state.stdin_pipe)
    Bash.Pipe.destroy(state.stdout_pipe)
    :ok
  end

  @doc """
  Read from a coprocess's stdout.
  """
  def read_output(coproc_pid, timeout \\ :infinity) do
    GenServer.call(coproc_pid, :read, timeout)
  end

  @doc """
  Write to a coprocess's stdin.
  """
  def write_input(coproc_pid, data, timeout \\ :infinity) do
    GenServer.call(coproc_pid, {:write, data}, timeout)
  end

  @doc """
  Close the coprocess's stdin (write end).
  """
  def close_write(coproc_pid, timeout \\ :infinity) do
    GenServer.call(coproc_pid, :close_stdin, timeout)
  end

  @doc """
  Close the coprocess's stdout (read end).
  """
  def close_read(coproc_pid, timeout \\ :infinity) do
    GenServer.call(coproc_pid, :close_stdout, timeout)
  end

  @doc """
  Get the status of a coprocess.
  """
  def get_status(coproc_pid, timeout \\ :infinity) do
    GenServer.call(coproc_pid, :status, timeout)
  end
end
