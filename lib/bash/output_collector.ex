defmodule Bash.OutputCollector do
  @moduledoc false
  # Linked GenServer that collects stdout/stderr as interleaved chunks.
  #
  # This process is spawned by Session on execution start and linked to it.
  # If the session crashes, the collector dies with it.
  #
  # Output is accumulated as a single interleaved list of `{:stdout, data}` and
  # `{:stderr, data}` tuples, preserving the order in which output was received.
  # This is important for accurate reproduction in formatters and debugging.
  #
  # Chunks are prepended for efficiency, then reversed on read.

  use GenServer

  defstruct chunks: []

  @type chunk :: {:stdout | :stderr, binary()}
  @type t :: %__MODULE__{
          chunks: [chunk()]
        }

  # Starts an OutputCollector process.
  #
  # ## Options
  #
  # * `:name` - Optional name registration
  #
  # ## Examples
  #
  # {:ok, pid} = OutputCollector.start_link()
  #
  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, opts)
  end

  # Writes a chunk to the collector.
  #
  # This is an async cast for performance - writes don't block.
  #
  # ## Examples
  #
  # OutputCollector.write(pid, :stdout, "hello\\n")
  # OutputCollector.write(pid, :stderr, "error message")
  #
  @doc false
  @spec write(pid(), :stdout | :stderr, binary()) :: :ok
  def write(pid, stream, data) when stream in [:stdout, :stderr] and is_binary(data) do
    GenServer.cast(pid, {:write, stream, data})
  end

  # Gets all interleaved chunks in order.
  #
  # Returns a list of `{:stdout, data}` and `{:stderr, data}` tuples
  # in the order they were received.
  @doc false
  @spec chunks(pid()) :: [chunk()]
  def chunks(pid), do: GenServer.call(pid, :chunks)

  # Gets accumulated stdout as iodata (list of binaries).
  #
  # ## Examples
  #
  # iodata = OutputCollector.stdout(pid)
  # binary = IO.iodata_to_binary(iodata)
  #
  @doc false
  @spec stdout(pid()) :: iodata()
  def stdout(pid), do: GenServer.call(pid, :stdout)

  # Gets accumulated stderr as iodata (list of binaries).
  @doc false
  @spec stderr(pid()) :: iodata()
  def stderr(pid), do: GenServer.call(pid, :stderr)

  # Gets both stdout and stderr as `{stdout_iodata, stderr_iodata}`.
  #
  # Note: This separates the interleaved chunks, losing ordering.
  # Use `chunks/1` if you need ordering preserved.
  @doc false
  @spec output(pid()) :: {iodata(), iodata()}
  def output(pid), do: GenServer.call(pid, :output)

  # Clears accumulated output and returns what was collected as interleaved chunks.
  @doc false
  @spec flush(pid()) :: [chunk()]
  def flush(pid), do: GenServer.call(pid, :flush)

  # Clears accumulated output and returns it as separate stdout/stderr iodata.
  #
  # This is a convenience function for backward compatibility.
  # Use `flush/1` if you need ordering preserved.
  @doc false
  @spec flush_split(pid()) :: {iodata(), iodata()}
  def flush_split(pid), do: GenServer.call(pid, :flush_split)

  # GenServer Callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:write, stream, data}, state) when stream in [:stdout, :stderr] do
    {:noreply, %{state | chunks: [{stream, data} | state.chunks]}}
  end

  @impl true
  def handle_call(:chunks, _from, state) do
    {:reply, Enum.reverse(state.chunks), state}
  end

  def handle_call(:stdout, _from, state) do
    stdout_data =
      state.chunks
      |> Enum.reverse()
      |> Enum.flat_map(fn
        {:stdout, data} -> [data]
        _ -> []
      end)

    {:reply, stdout_data, state}
  end

  def handle_call(:stderr, _from, state) do
    stderr_data =
      state.chunks
      |> Enum.reverse()
      |> Enum.flat_map(fn
        {:stderr, data} -> [data]
        _ -> []
      end)

    {:reply, stderr_data, state}
  end

  def handle_call(:output, _from, state) do
    reversed = Enum.reverse(state.chunks)

    stdout_data =
      Enum.flat_map(reversed, fn
        {:stdout, data} -> [data]
        _ -> []
      end)

    stderr_data =
      Enum.flat_map(reversed, fn
        {:stderr, data} -> [data]
        _ -> []
      end)

    {:reply, {stdout_data, stderr_data}, state}
  end

  def handle_call(:flush, _from, state) do
    result = Enum.reverse(state.chunks)
    {:reply, result, %__MODULE__{}}
  end

  def handle_call(:flush_split, _from, state) do
    reversed = Enum.reverse(state.chunks)

    stdout_data =
      Enum.flat_map(reversed, fn
        {:stdout, data} -> [data]
        _ -> []
      end)

    stderr_data =
      Enum.flat_map(reversed, fn
        {:stderr, data} -> [data]
        _ -> []
      end)

    {:reply, {stdout_data, stderr_data}, %__MODULE__{}}
  end
end
