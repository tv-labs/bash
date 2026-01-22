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
  """
  use Bash.Builtin

  alias Bash.Variable

  use GenServer

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, name, command, cmd_args} ->
        start_coproc(name, command, cmd_args, state)

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

  defp parse_args([name, command | rest]) do
    # Check if first arg looks like a variable name (alphanumeric, starts with letter/underscore)
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name) do
      {:ok, name, command, rest}
    else
      # First arg is the command
      {:ok, "COPROC", name, [command | rest]}
    end
  end

  defp start_coproc(name, command, cmd_args, session_state) do
    # Start the coprocess GenServer under the session's job supervisor
    child_spec = %{
      id: {__MODULE__, name},
      start:
        {__MODULE__, :start_link,
         [
           %{
             command: command,
             args: cmd_args,
             working_dir: session_state.working_dir,
             env: build_env(session_state)
           }
         ]},
      restart: :temporary
    }

    supervisor = Map.get(session_state, :job_supervisor)

    if supervisor == nil do
      error("coproc: job supervisor not available")
      {:ok, 1}
    else
      case DynamicSupervisor.start_child(supervisor, child_spec) do
        {:ok, pid} ->
          # Get the OS PID and pipe info
          case GenServer.call(pid, :get_info) do
            {:ok, os_pid, read_fd, write_fd} ->
              # Create the array variable and PID variable
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

              # Store the coproc pid in session for later cleanup
              coproc_updates =
                Map.put(
                  Map.get(session_state, :coprocs, %{}),
                  name,
                  %{pid: pid, os_pid: os_pid}
                )

              # Return with state updates
              update_state(var_updates: var_updates, coprocs: coproc_updates)
              :ok

            {:error, reason} ->
              GenServer.stop(pid)
              error("coproc: failed to start: #{inspect(reason)}")
              {:ok, 1}
          end

        {:error, reason} ->
          error("coproc: failed to start: #{inspect(reason)}")
          {:ok, 1}
      end
    end
  end

  defp build_env(session_state) do
    session_state.variables
    |> Enum.filter(fn {_, v} -> v.attributes[:export] == true end)
    |> Enum.map(fn {k, v} -> {k, Variable.get(v, nil)} end)
  end

  # GenServer Implementation

  @impl true
  def init(opts) do
    # Start the process with ExCmd
    cmd = [opts.command | opts.args]

    proc_opts = [
      cd: opts.working_dir,
      env: opts.env,
      stdin: :pipe,
      stdout: :pipe,
      stderr: :pipe
    ]

    case ExCmd.Process.start_link(cmd, proc_opts) do
      {:ok, pid} ->
        # Get OS PID
        os_pid = ExCmd.Process.os_pid(pid)

        # Create pipe file descriptors (we use the GenServer pid as a pseudo-FD)
        # In a real implementation, we'd use actual file descriptors
        # Here we use process-based communication
        read_fd = :erlang.phash2({self(), :read})
        write_fd = :erlang.phash2({self(), :write})

        {:ok,
         %{
           proc: pid,
           os_pid: os_pid,
           read_fd: read_fd,
           write_fd: write_fd,
           stdout_buffer: [],
           stderr_buffer: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    {:reply, {:ok, state.os_pid, state.read_fd, state.write_fd}, state}
  end

  @impl true
  def handle_call(:read, _from, state) do
    # Read available stdout from the process
    case ExCmd.Process.read(state.proc) do
      {:ok, data} ->
        {:reply, {:ok, data}, state}

      :eof ->
        {:reply, :eof, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    case ExCmd.Process.write(state.proc, data) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:close_stdin, _from, state) do
    ExCmd.Process.close_stdin(state.proc)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    # Try to get exit status with 0 timeout to check if process is still running
    case ExCmd.Process.await_exit(state.proc, 0) do
      {:ok, exit_code} ->
        {:reply, {:exited, exit_code}, state}

      {:error, :timeout} ->
        {:reply, :running, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _proc, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    # The ExCmd process is linked to this GenServer and will be cleaned up
    # when the GenServer terminates. We just need to ensure we await the exit.
    if state.proc do
      # Close stdin to signal we're done, then await exit
      ExCmd.Process.close_stdin(state.proc)
      ExCmd.Process.await_exit(state.proc, 1000)
    end

    :ok
  end

  # Public API for interacting with coprocs

  @doc """
  Read from a coprocess's stdout.
  """
  def read_output(coproc_pid) do
    GenServer.call(coproc_pid, :read)
  end

  @doc """
  Write to a coprocess's stdin.
  """
  def write_input(coproc_pid, data) do
    GenServer.call(coproc_pid, {:write, data})
  end

  @doc """
  Close the coprocess's stdin.
  """
  def close_input(coproc_pid) do
    GenServer.call(coproc_pid, :close_stdin)
  end

  @doc """
  Get the status of a coprocess.
  """
  def get_status(coproc_pid) do
    GenServer.call(coproc_pid, :status)
  end
end
