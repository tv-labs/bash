defmodule Bash.Pipe do
  @moduledoc """
  BEAM-native pipe that buffers data between a writer and reader using
  blocked `GenServer.call/3`.

  Replaces the OS FIFO-backed pipe with a pure-BEAM implementation that
  works inside a virtual filesystem sandbox without touching the real
  filesystem or spawning OS processes.

  A single writer appends data; a single reader consumes it line-by-line
  or all at once. When no data is available the reader parks inside a
  `GenServer.call` and is unblocked as soon as the writer delivers data
  or signals EOF via `close_write/1`.

  ```mermaid
  stateDiagram-v2
      [*] --> Open : create/1

      Open --> Open : write/2 (buffer += data, fulfill parked reader)
      Open --> Open : read_line/1 (line ready → return immediately)
      Open --> Parked : read_line/1 (no complete line, not closed → park caller)
      Parked --> Open : write/2 delivers line → GenServer.reply to parked caller
      Parked --> Closed : close_write/1 → GenServer.reply :eof or partial to parked caller

      Open --> Closed : close_write/1
      Closed --> Closed : read_line/1 (drain buffer then :eof)
      Closed --> Closed : write/2 → {:error, :closed}

      Open --> [*] : destroy/1
      Closed --> [*] : destroy/1
  ```
  """

  use GenServer

  @type t :: %__MODULE__{pid: pid()}

  defstruct [:pid]

  @typep reader :: {:line | :all, GenServer.from()}

  @doc false
  @spec create(keyword()) :: {:ok, t()}
  def create(opts \\ []) do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, %{buffer: "", closed: false, reader: nil}, opts)

    {:ok, %__MODULE__{pid: pid}}
  end

  @doc false
  @spec write(t(), iodata()) :: :ok | {:error, :closed}
  def write(%__MODULE__{pid: pid}, data) do
    GenServer.call(pid, {:write, IO.iodata_to_binary(data)})
  end

  @doc false
  @spec read_line(t()) :: {:ok, binary()} | :eof
  def read_line(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :read_line, :infinity)
  end

  @doc false
  @spec read_all(t()) :: binary()
  def read_all(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :read_all, :infinity)
  end

  @doc false
  @spec close_write(t()) :: :ok
  def close_write(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :close_write)
  end

  @doc false
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{pid: pid}) do
    GenServer.stop(pid, :normal)
  end

  # GenServer callbacks

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:write, _data}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:write, data}, _from, %{buffer: buffer, reader: reader} = state) do
    new_buffer = buffer <> data

    case try_fulfill(reader, new_buffer, false) do
      {:fulfilled, reply, rest} ->
        GenServer.reply(elem(reader, 1), reply)
        {:reply, :ok, %{state | buffer: rest, reader: nil}}

      :pending ->
        {:reply, :ok, %{state | buffer: new_buffer}}
    end
  end

  def handle_call(:read_line, from, %{buffer: buffer, closed: closed} = state) do
    case extract_line(buffer, closed) do
      {:ok, line, rest} ->
        {:reply, {:ok, line}, %{state | buffer: rest}}

      :eof ->
        {:reply, :eof, state}

      :wait ->
        {:noreply, %{state | reader: {:line, from}}}
    end
  end

  def handle_call(:read_all, _from, %{buffer: buffer, closed: true} = state) do
    {:reply, buffer, %{state | buffer: ""}}
  end

  def handle_call(:read_all, from, state) do
    {:noreply, %{state | reader: {:all, from}}}
  end

  def handle_call(:close_write, _from, %{closed: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close_write, _from, %{reader: reader, buffer: buffer} = state) do
    new_state = %{state | closed: true, reader: nil}

    case reader do
      nil ->
        {:reply, :ok, new_state}

      {:line, from} ->
        case extract_line(buffer, true) do
          {:ok, line, rest} ->
            GenServer.reply(from, {:ok, line})
            {:reply, :ok, %{new_state | buffer: rest}}

          :eof ->
            GenServer.reply(from, :eof)
            {:reply, :ok, new_state}
        end

      {:all, from} ->
        GenServer.reply(from, buffer)
        {:reply, :ok, %{new_state | buffer: ""}}
    end
  end

  # Private helpers

  @spec extract_line(binary(), boolean()) :: {:ok, binary(), binary()} | :eof | :wait
  defp extract_line("", true), do: :eof
  defp extract_line("", false), do: :wait

  defp extract_line(buffer, closed) do
    case :binary.match(buffer, "\n") do
      {pos, 1} ->
        line = binary_part(buffer, 0, pos + 1)
        rest = binary_part(buffer, pos + 1, byte_size(buffer) - pos - 1)
        {:ok, line, rest}

      :nomatch when closed ->
        {:ok, buffer, ""}

      :nomatch ->
        :wait
    end
  end

  @spec try_fulfill(reader() | nil, binary(), boolean()) ::
          {:fulfilled, term(), binary()} | :pending
  defp try_fulfill(nil, _buffer, _closed), do: :pending

  defp try_fulfill({:line, _from}, buffer, closed) do
    case extract_line(buffer, closed) do
      {:ok, line, rest} -> {:fulfilled, {:ok, line}, rest}
      _ -> :pending
    end
  end

  defp try_fulfill({:all, _from}, _buffer, _closed), do: :pending
end
