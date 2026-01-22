defmodule Bash.Sink do
  @moduledoc ~S"""
  Output sink functions for streaming command output.

  A sink is a function that receives `{:stdout, binary}` or `{:stderr, binary}` chunks.
  Sinks enable streaming output without accumulating in memory.

  ## Sink Types

  - `collector/1` - Writes to an OutputCollector GenServer (default for sessions)
  - `stream/2` - Writes to a File.Stream or any Collectable
  - `passthrough/1` - Forwards chunks to a callback function
  - `file/2` - Writes directly to a file path
  - `null/0` - Discards all output (for /dev/null)

  ## Builtin Helpers

  - `write/3` - Write to stdout/stderr sink from session_state
  - `write_stdout/2` - Write to stdout sink
  - `write_stderr/2` - Write to stderr sink

  ## Usage

      # Create a collector-backed sink
      {:ok, collector} = OutputCollector.start_link()
      sink = Sink.collector(collector)
      sink.({:stdout, "hello"})

      # Create a File.Stream sink
      stream = File.stream!("/tmp/output.txt")
      sink = Sink.stream(stream)
      sink.({:stdout, "hello"})

      # In builtins, use the helpers:
      Sink.write_stdout(session_state, "output\n")
      Sink.write_stderr(session_state, "error\n")

  """

  alias Bash.OutputCollector

  @type chunk :: {:stdout, binary()} | {:stderr, binary()}
  @type t :: (chunk() -> :ok | {:error, term()})

  @doc ~S"""
  Creates a sink that writes to an OutputCollector GenServer.

  This is the default sink type used by sessions. Output is accumulated
  as iodata in the collector and retrieved at the end of execution.

  ## Examples

      {:ok, collector} = OutputCollector.start_link()
      sink = Sink.collector(collector)
      sink.({:stdout, "hello\n"})
      sink.({:stderr, "warning\n"})

      # Later, retrieve output
      {stdout, stderr} = OutputCollector.output(collector)

  """
  @spec collector(pid()) :: t()
  def collector(pid) when is_pid(pid) do
    fn
      {:stdout, data} when is_binary(data) ->
        OutputCollector.write(pid, :stdout, data)
        :ok

      {:stderr, data} when is_binary(data) ->
        OutputCollector.write(pid, :stderr, data)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Creates a sink that writes to a File.Stream or any Collectable.

  Use this for `:stdout_into` and `:stderr_into` options to stream
  output directly to files without accumulating in memory.

  ## Options

    * `:stream_type` - Which stream to capture (`:stdout`, `:stderr`, or `:both`).
      Defaults to `:both`.

  ## Examples

      # Stream stdout to a file
      file_stream = File.stream!("/tmp/output.txt")
      sink = Sink.stream(file_stream)
      sink.({:stdout, "hello"})

      # Stream to any Collectable
      sink = Sink.stream(some_collectable, stream_type: :stderr)

  """
  @spec stream(Collectable.t(), keyword()) :: t()
  def stream(collectable, opts \\ []) do
    stream_type = Keyword.get(opts, :stream_type, :both)
    {acc, collector_fun} = Collectable.into(collectable)

    # Store the accumulator in process dictionary so we can update it
    ref = make_ref()
    Process.put({__MODULE__, ref}, acc)

    fn
      {:stdout, data} when stream_type in [:stdout, :both] and is_binary(data) ->
        current_acc = Process.get({__MODULE__, ref})
        new_acc = collector_fun.(current_acc, {:cont, data})
        Process.put({__MODULE__, ref}, new_acc)
        :ok

      {:stderr, data} when stream_type in [:stderr, :both] and is_binary(data) ->
        current_acc = Process.get({__MODULE__, ref})
        new_acc = collector_fun.(current_acc, {:cont, data})
        Process.put({__MODULE__, ref}, new_acc)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Finalizes a stream sink created with `stream/2`.

  Must be called after all output has been written to ensure the
  Collectable is properly closed.
  """
  @spec finalize_stream(Collectable.t()) :: term()
  def finalize_stream(collectable) do
    {_acc, collector_fun} = Collectable.into(collectable)
    collector_fun.(nil, :done)
  end

  @doc """
  Creates a passthrough sink that calls the given callback for each chunk.

  Useful for real-time streaming to the caller or for testing.

  ## Examples

      sink = Sink.passthrough(fn
        {:stdout, data} -> IO.write(data)
        {:stderr, data} -> IO.write(:stderr, data)
      end)

  """
  @spec passthrough((chunk() -> any())) :: t()
  def passthrough(callback) when is_function(callback, 1) do
    fn chunk ->
      callback.(chunk)
      :ok
    end
  end

  @doc """
  Creates a file sink that writes output directly to a file path.

  ## Options

    * `:append` - Append to file instead of overwriting (default: false)
    * `:stream_type` - Which stream to write (`:stdout`, `:stderr`, or `:both`, default: `:stdout`)

  Returns `{sink_fun, close_fun}` where close_fun must be called to close the file.

  ## Examples

      {sink, close} = Sink.file("/tmp/output.txt")
      sink.({:stdout, "hello\\n"})
      close.()

  """
  @spec file(Path.t(), keyword()) :: {t(), (-> :ok | {:error, term()})}
  def file(path, opts \\ []) do
    append = Keyword.get(opts, :append, false)
    stream_type = Keyword.get(opts, :stream_type, :stdout)

    mode = if append, do: [:write, :append, :raw], else: [:write, :raw]

    case :file.open(path, mode) do
      {:ok, fd} ->
        sink = fn
          {:stdout, data} when stream_type in [:stdout, :both] and is_binary(data) ->
            :file.write(fd, data)
            :ok

          {:stderr, data} when stream_type in [:stderr, :both] and is_binary(data) ->
            :file.write(fd, data)
            :ok

          _ ->
            :ok
        end

        close = fn -> :file.close(fd) end
        {sink, close}

      {:error, reason} ->
        sink = fn _ -> {:error, reason} end
        close = fn -> {:error, reason} end
        {sink, close}
    end
  end

  @doc """
  Creates a null sink that discards all output.

  Used for `/dev/null` redirections.

  ## Examples

      sink = Sink.null()
      sink.({:stdout, "discarded"})  # => :ok

  """
  @spec null() :: t()
  def null do
    fn _ -> :ok end
  end

  @doc ~S"""
  Write data to stdout sink if available.

  Returns `:ok` if written to sink, `:no_sink` if no sink configured.
  Builtins should check the return value to decide whether to include
  output in the CommandResult.

  ## Examples

      case Sink.write_stdout(session_state, "hello\n") do
        :ok -> {:ok, %CommandResult{exit_code: 0}}
        :no_sink -> :no_sink
      end

  """
  @spec write_stdout(map(), binary()) :: :ok | :no_sink
  def write_stdout(session_state, data) when is_binary(data) do
    case Map.get(session_state, :stdout_sink) do
      nil ->
        :no_sink

      sink when is_function(sink) ->
        sink.({:stdout, data})
        :ok
    end
  end

  @doc ~S"""
  Write data to stderr sink if available.

  Returns `:ok` if written to sink, `:no_sink` if no sink configured.

  ## Examples

      case Sink.write_stderr(session_state, "error\n") do
        :ok -> {:ok, %CommandResult{exit_code: 0}}
        :no_sink -> :no_sink
      end

  """
  @spec write_stderr(map(), binary()) :: :ok | :no_sink
  def write_stderr(session_state, data) when is_binary(data) do
    case Map.get(session_state, :stderr_sink) do
      nil ->
        :no_sink

      sink when is_function(sink) ->
        sink.({:stderr, data})
        :ok
    end
  end

  @doc """
  Write data to the specified stream's sink if available.

  ## Examples

      Sink.write(session_state, :stdout, "hello\\n")
      Sink.write(session_state, :stderr, "error\\n")

  """
  @spec write(map(), :stdout | :stderr, binary()) :: :ok | :no_sink
  def write(session_state, :stdout, data), do: write_stdout(session_state, data)
  def write(session_state, :stderr, data), do: write_stderr(session_state, data)
end

# Keep these modules for backwards compatibility during transition
# They will be removed once all code uses the new sink API

defmodule Bash.Sink.Passthrough do
  @moduledoc false
  # Deprecated: Use Sink.passthrough/1 instead

  @spec new((Bash.Sink.chunk() -> any())) :: Bash.Sink.t()
  def new(callback), do: Bash.Sink.passthrough(callback)
end

defmodule Bash.Sink.File do
  @moduledoc false
  # Deprecated: Use Sink.file/2 instead

  @spec new(Path.t(), keyword()) :: {Bash.Sink.t(), (-> :ok | {:error, term()})}
  def new(path, opts \\ []), do: Bash.Sink.file(path, opts)
end

defmodule Bash.Sink.Null do
  @moduledoc false
  # Deprecated: Use Sink.null/0 instead

  @spec new() :: Bash.Sink.t()
  def new, do: Bash.Sink.null()
end

defmodule Bash.Sink.Accumulator do
  @moduledoc false
  # Deprecated: Use OutputCollector instead
  # Kept for backwards compatibility during transition

  @spec new() :: {Bash.Sink.t(), (-> binary())}
  def new do
    ref = make_ref()
    Process.put({__MODULE__, ref}, [])

    sink = fn
      {:stdout, data} when is_binary(data) ->
        chunks = Process.get({__MODULE__, ref})
        Process.put({__MODULE__, ref}, [data | chunks])
        :ok

      {:stderr, data} when is_binary(data) ->
        chunks = Process.get({__MODULE__, ref})
        Process.put({__MODULE__, ref}, [data | chunks])
        :ok

      _ ->
        :ok
    end

    get_result = fn ->
      chunks = Process.get({__MODULE__, ref})
      Process.delete({__MODULE__, ref})
      chunks |> Enum.reverse() |> :erlang.iolist_to_binary()
    end

    {sink, get_result}
  end

  @spec new_separated() :: {Bash.Sink.t(), (-> {binary(), binary()})}
  def new_separated do
    ref = make_ref()
    Process.put({__MODULE__, ref, :stdout}, [])
    Process.put({__MODULE__, ref, :stderr}, [])

    sink = fn
      {:stdout, data} when is_binary(data) ->
        chunks = Process.get({__MODULE__, ref, :stdout})
        Process.put({__MODULE__, ref, :stdout}, [data | chunks])
        :ok

      {:stderr, data} when is_binary(data) ->
        chunks = Process.get({__MODULE__, ref, :stderr})
        Process.put({__MODULE__, ref, :stderr}, [data | chunks])
        :ok

      _ ->
        :ok
    end

    get_result = fn ->
      stdout = Process.get({__MODULE__, ref, :stdout})
      stderr = Process.get({__MODULE__, ref, :stderr})
      Process.delete({__MODULE__, ref, :stdout})
      Process.delete({__MODULE__, ref, :stderr})

      {
        stdout |> Enum.reverse() |> :erlang.iolist_to_binary(),
        stderr |> Enum.reverse() |> :erlang.iolist_to_binary()
      }
    end

    {sink, get_result}
  end
end

defmodule Bash.Sink.List do
  @moduledoc false
  # Deprecated: Use OutputCollector instead
  # Kept for backwards compatibility during transition

  @spec new() :: {Bash.Sink.t(), (-> [{:stdout | :stderr, [binary()]}])}
  def new do
    ref = make_ref()
    Process.put({__MODULE__, ref}, [])

    sink = fn
      {stream, data} when stream in [:stdout, :stderr] and is_binary(data) ->
        chunks = Process.get({__MODULE__, ref})
        Process.put({__MODULE__, ref}, [{stream, data} | chunks])
        :ok

      _ ->
        :ok
    end

    get_result = fn ->
      chunks = Process.get({__MODULE__, ref})
      Process.delete({__MODULE__, ref})

      chunks
      |> Enum.reverse()
      |> Enum.chunk_by(fn {stream, _} -> stream end)
      |> Enum.map(fn group ->
        {stream, _} = hd(group)
        data = Enum.map(group, fn {_, d} -> d end)
        {stream, data}
      end)
    end

    {sink, get_result}
  end
end
