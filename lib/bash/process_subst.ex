defmodule Bash.ProcessSubst do
  @moduledoc """
  GenServer managing process substitution execution.

  Process substitution (`<(command)` and `>(command)`) creates a named pipe (FIFO)
  and runs a background command that reads from or writes to it. The FIFO path
  is returned and can be used as a file argument to other commands.

  ## Input Process Substitution

  Creates a FIFO where the command's stdout is written. The parent command
  reads from this FIFO as if it were a file.

      diff <(sort file1) <(sort file2)

  ## Output Process Substitution

  Creates a FIFO where the parent command writes. The substituted command
  reads from this FIFO as its stdin.

      tee >(gzip > file.gz) >(bzip2 > file.bz2)

  ## Lifecycle

  1. Created via `start_link/1` with command AST and session state
  2. Creates FIFO in session's temp directory
  3. Spawns background process via ExCmd
  4. Returns FIFO path synchronously
  5. Background process runs until command completes or FIFO is closed
  6. Cleanup happens on GenServer stop (FIFO removed)
  """

  use GenServer

  alias Bash.CommandResult
  alias Bash.Executor
  alias Bash.Sink

  defstruct [
    :fifo_path,
    :direction,
    :command_ast,
    :session_state,
    :worker_pid,
    :os_pid
  ]

  @type direction :: :input | :output

  @type t :: %__MODULE__{
          fifo_path: String.t() | nil,
          direction: direction(),
          command_ast: term(),
          session_state: map(),
          worker_pid: pid() | nil,
          os_pid: pos_integer() | nil
        }

  # --- Public API ---

  @doc """
  Start a process substitution.

  ## Options

  - `:direction` - `:input` for `<(cmd)` or `:output` for `>(cmd)` (required)
  - `:command_ast` - The parsed AST of the command to execute (required)
  - `:session_state` - Current session state for variable expansion (required)
  - `:temp_dir` - Directory for FIFO creation (defaults to /tmp)

  Returns `{:ok, pid, fifo_path}` on success.
  """
  @spec start_link(keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        # Wait for FIFO path to be ready
        case GenServer.call(pid, :get_fifo_path, 5000) do
          {:ok, fifo_path} -> {:ok, pid, fifo_path}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Wait for the process substitution to complete.

  Returns the command result.
  """
  @spec wait(pid()) :: {:ok, CommandResult.t()} | {:error, term()}
  def wait(pid) do
    GenServer.call(pid, :wait, :infinity)
  end

  @doc """
  Stop the process substitution and cleanup.
  """
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
      fifo_path: nil,
      worker_pid: nil,
      os_pid: nil
    }

    # Create FIFO and start worker asynchronously
    {:ok, state, {:continue, {:setup, temp_dir}}}
  end

  @impl true
  def handle_continue({:setup, temp_dir}, state) do
    # Generate unique FIFO path using monotonic integer + random + pid for uniqueness
    unique_id = :erlang.unique_integer([:positive, :monotonic])
    random_suffix = :rand.uniform(999_999)
    pid_hash = :erlang.phash2(self())
    fifo_path = Path.join(temp_dir, "runcom_proc_subst_#{unique_id}_#{random_suffix}_#{pid_hash}")

    # Create the FIFO
    case create_fifo(fifo_path) do
      :ok ->
        # Start the worker process
        parent = self()
        worker_pid = spawn_link(fn -> run_worker(state.direction, fifo_path, state, parent) end)

        {:noreply, %{state | fifo_path: fifo_path, worker_pid: worker_pid}}

      {:error, reason} ->
        {:stop, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_fifo_path, _from, %{fifo_path: nil} = state) do
    # FIFO not ready yet - this shouldn't happen if setup succeeded
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call(:get_fifo_path, _from, state) do
    {:reply, {:ok, state.fifo_path}, state}
  end

  def handle_call(:wait, _from, %{worker_pid: nil} = state) do
    # Already done
    {:reply, {:ok, %CommandResult{exit_code: 0}}, state}
  end

  def handle_call(:wait, from, state) do
    # Store caller to reply when worker completes
    {:noreply, Map.put(state, :wait_from, from)}
  end

  @impl true
  def handle_info({:worker_done, result}, state) do
    # Reply to any waiting caller
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
    # Worker exited - might be normal or abnormal
    result =
      case reason do
        :normal -> {:ok, %CommandResult{exit_code: 0}}
        _ -> {:error, reason}
      end

    # Reply to any waiting caller
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
    # Some other linked process exited
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.fifo_path && File.exists?(state.fifo_path) do
      File.rm(state.fifo_path)
    end

    :ok
  end

  defp create_fifo(path) do
    case System.cmd("mkfifo", [path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  end

  # Worker for input process substitution: <(command)
  # Runs the command natively and streams stdout directly to the FIFO
  defp run_worker(:input, fifo_path, state, parent) do
    # Open FIFO for writing (blocks until reader opens)
    case :file.open(fifo_path, [:write, :raw]) do
      {:ok, fd} ->
        # Create a sink that writes directly to the FIFO fd (streaming, no accumulation)
        fifo_sink = fn
          {:stdout, data} when is_binary(data) ->
            :file.write(fd, data)
            :ok

          _ ->
            :ok
        end

        # Execute command with FIFO sink - output streams directly, no accumulation
        exec_session = %{state.session_state | stdout_sink: fifo_sink, stderr_sink: Sink.null()}

        exit_code =
          case Executor.execute(state.command_ast, exec_session, nil) do
            {:ok, %{exit_code: code}, _} when is_integer(code) -> code
            {:ok, %{exit_code: code}} when is_integer(code) -> code
            {:error, %{exit_code: code}, _} when is_integer(code) -> code
            {:error, %{exit_code: code}} when is_integer(code) -> code
            _ -> 0
          end

        :file.close(fd)
        send(parent, {:worker_done, {:ok, %CommandResult{exit_code: exit_code}}})

      {:error, reason} ->
        send(parent, {:worker_done, {:error, {:fifo_open_failed, reason}}})
    end
  end

  # Worker for output process substitution: >(command)
  # Reads from FIFO and pipes to command's stdin
  defp run_worker(:output, fifo_path, state, parent) do
    # Open FIFO for reading (blocks until writer opens)
    case :file.open(fifo_path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        # Create a lazy stream that reads from the FIFO fd
        stdin_stream =
          Stream.resource(
            fn -> fd end,
            fn fd ->
              case :file.read(fd, 65536) do
                {:ok, data} -> {[data], fd}
                :eof -> {:halt, fd}
                {:error, _} -> {:halt, fd}
              end
            end,
            fn _fd -> :ok end
          )

        # Execute command with FIFO stream as stdin
        # Output goes to session's existing sinks (no accumulation here)
        exit_code =
          case Executor.execute(state.command_ast, state.session_state, stdin_stream) do
            {:ok, %{exit_code: code}, _} when is_integer(code) -> code
            {:ok, %{exit_code: code}} when is_integer(code) -> code
            {:error, %{exit_code: code}, _} when is_integer(code) -> code
            {:error, %{exit_code: code}} when is_integer(code) -> code
            _ -> 0
          end

        :file.close(fd)
        send(parent, {:worker_done, {:ok, %CommandResult{exit_code: exit_code}}})

      {:error, reason} ->
        send(parent, {:worker_done, {:error, {:fifo_open_failed, reason}}})
    end
  end
end
