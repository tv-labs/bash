defmodule Bash.ProcessSubst do
  @moduledoc """
  GenServer managing process substitution execution.

  Process substitution (`<(command)` and `>(command)`) creates a temp file
  via the session's `Bash.Filesystem` and runs a background command that
  reads from or writes to it. The temp file path is returned and can be
  used as a file argument to other commands.

  ## Input Process Substitution

  Runs the command, captures its stdout to a binary, and writes the result
  to a VFS temp file. The parent command reads from this path as if it were
  a regular file.

      diff <(sort file1) <(sort file2)

  ## Output Process Substitution

  Creates a temp file path. The parent command writes to it; the substituted
  command polls for the file to appear and then reads it as stdin.

      tee >(gzip > file.gz) >(bzip2 > file.bz2)

  ## Lifecycle

  1. Created via `start_link/1` with command AST and session state
  2. Generates a unique temp path in session's temp directory
  3. Spawns background process to run the command
  4. Returns temp file path synchronously
  5. Background process runs until command completes
  6. Cleanup happens on GenServer stop (temp file removed via VFS)

  ## State Machine

  ```mermaid
  stateDiagram-v2
    [*] --> Initialising: start_link/1
    Initialising --> Running: handle_continue setup
    Running --> Done: worker_done message
    Done --> [*]: stop/1
  ```
  """

  use GenServer

  alias Bash.CommandResult
  alias Bash.Executor
  alias Bash.Sink

  defstruct [
    :temp_path,
    :direction,
    :command_ast,
    :session_state,
    :worker_pid,
    :os_pid
  ]

  @type direction :: :input | :output

  @type t :: %__MODULE__{
          temp_path: String.t() | nil,
          direction: direction(),
          command_ast: term(),
          session_state: map(),
          worker_pid: pid() | nil,
          os_pid: pos_integer() | nil
        }

  # --- Public API ---

  # Start a process substitution.
  #
  # ## Options
  #
  # - `:direction` - `:input` for `<(cmd)` or `:output` for `>(cmd)` (required)
  # - `:command_ast` - The parsed AST of the command to execute (required)
  # - `:session_state` - Current session state for variable expansion (required)
  # - `:temp_dir` - Directory for temp file creation (defaults to /tmp)
  #
  # Returns `{:ok, pid, temp_path}` on success.
  @doc false
  @spec start_link(keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        case GenServer.call(pid, :get_temp_path, :infinity) do
          {:ok, temp_path} -> {:ok, pid, temp_path}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Wait for the process substitution to complete.
  #
  # Returns the command result.
  @doc false
  @spec wait(pid()) :: {:ok, CommandResult.t()} | {:error, term()}
  def wait(pid) do
    GenServer.call(pid, :wait, :infinity)
  end

  # Stop the process substitution and cleanup.
  @doc false
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    direction = Keyword.fetch!(opts, :direction)
    command_ast = Keyword.fetch!(opts, :command_ast)
    session_state = Keyword.fetch!(opts, :session_state)
    temp_dir = Keyword.get(opts, :temp_dir, "/tmp")

    state = %__MODULE__{
      direction: direction,
      command_ast: command_ast,
      session_state: session_state,
      temp_path: nil,
      worker_pid: nil,
      os_pid: nil
    }

    {:ok, state, {:continue, {:setup, temp_dir}}}
  end

  @impl true
  def handle_continue({:setup, temp_dir}, state) do
    unique_id = :erlang.unique_integer([:positive, :monotonic])
    random_suffix = :rand.uniform(999_999)
    pid_hash = :erlang.phash2(self())
    temp_path = Path.join(temp_dir, "runcom_proc_subst_#{unique_id}_#{random_suffix}_#{pid_hash}")

    filesystem = Bash.Filesystem.from_state(state.session_state)
    Bash.Filesystem.mkdir_p(filesystem, temp_dir)

    # For :input (<(cmd)), run the command inline so the file is written before
    # get_temp_path returns. The GenServer is blocked during execution, which is
    # fine — the caller needs the file ready before it can proceed anyway.
    #
    # For :output (>(cmd)), spawn async: the caller writes the file and the
    # worker polls for it, so they must run concurrently.
    state =
      case state.direction do
        :input ->
          run_worker(:input, temp_path, state, self())
          %{state | temp_path: temp_path}

        :output ->
          parent = self()
          worker_pid = spawn_link(fn -> run_worker(:output, temp_path, state, parent) end)
          %{state | temp_path: temp_path, worker_pid: worker_pid}
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_temp_path, _from, state) do
    {:reply, {:ok, state.temp_path}, state}
  end

  def handle_call(:wait, _from, %{worker_pid: nil} = state) do
    {:reply, {:ok, %CommandResult{exit_code: 0}}, state}
  end

  def handle_call(:wait, from, state) do
    {:noreply, Map.put(state, :wait_from, from)}
  end

  @impl true
  def handle_info({:worker_done, result}, state) do
    state =
      case Map.get(state, :wait_from) do
        nil ->
          state

        from ->
          GenServer.reply(from, result)
          Map.delete(state, :wait_from)
      end

    {:noreply, %{state | worker_pid: nil}}
  end

  def handle_info({:EXIT, pid, reason}, %{worker_pid: pid} = state) do
    result =
      case reason do
        :normal -> {:ok, %CommandResult{exit_code: 0}}
        _ -> {:error, reason}
      end

    state =
      case Map.get(state, :wait_from) do
        nil ->
          state

        from ->
          GenServer.reply(from, result)
          Map.delete(state, :wait_from)
      end

    {:noreply, %{state | worker_pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.temp_path do
      filesystem = Bash.Filesystem.from_state(state.session_state)
      Bash.Filesystem.rm(filesystem, state.temp_path)
    end

    :ok
  end

  # Worker for input process substitution: <(command)
  # Runs the command, captures stdout to a binary, writes to VFS temp file.
  defp run_worker(:input, temp_path, state, parent) do
    filesystem = Bash.Filesystem.from_state(state.session_state)

    {:ok, collector_device} = StringIO.open("")

    collector_sink = fn
      {:stdout, data} when is_binary(data) ->
        IO.binwrite(collector_device, data)
        :ok

      _ ->
        :ok
    end

    exec_session = %{state.session_state | stdout_sink: collector_sink, stderr_sink: Sink.null()}

    exit_code =
      case Executor.execute(state.command_ast, exec_session, nil) do
        {:ok, %{exit_code: code}, _} when is_integer(code) -> code
        {:ok, %{exit_code: code}} when is_integer(code) -> code
        {:error, %{exit_code: code}, _} when is_integer(code) -> code
        {:error, %{exit_code: code}} when is_integer(code) -> code
        _ -> 0
      end

    {_, output} = StringIO.contents(collector_device)
    StringIO.close(collector_device)
    Bash.Filesystem.write(filesystem, temp_path, output, [])

    send(parent, {:worker_done, {:ok, %CommandResult{exit_code: exit_code}}})
  end

  # Worker for output process substitution: >(command)
  # Polls for the temp file to appear in VFS, reads it, passes as stdin.
  defp run_worker(:output, temp_path, state, parent) do
    filesystem = Bash.Filesystem.from_state(state.session_state)

    stdin_data = poll_for_file(filesystem, temp_path, 100, 50)

    exit_code =
      case Executor.execute(state.command_ast, state.session_state, stdin_data) do
        {:ok, %{exit_code: code}, _} when is_integer(code) -> code
        {:ok, %{exit_code: code}} when is_integer(code) -> code
        {:error, %{exit_code: code}, _} when is_integer(code) -> code
        {:error, %{exit_code: code}} when is_integer(code) -> code
        _ -> 0
      end

    send(parent, {:worker_done, {:ok, %CommandResult{exit_code: exit_code}}})
  end

  defp poll_for_file(filesystem, path, retries, interval) do
    case Bash.Filesystem.read(filesystem, path) do
      {:ok, data} ->
        data

      {:error, :enoent} when retries > 0 ->
        Process.sleep(interval)
        poll_for_file(filesystem, path, retries - 1, interval)

      {:error, _} ->
        ""
    end
  end
end
