defmodule Bash.Pipe do
  @moduledoc """
  Bidirectional OS pipe backed by a POSIX FIFO (named pipe).

  Provides streaming, zero-copy data transfer between processes using
  real OS pipes. Data written to the pipe is available for reading
  without accumulation in BEAM memory — the kernel manages the buffer.

  Uses `mkfifo` to create a named pipe in a temporary directory,
  then opens read and write ends as regular file devices.

  ```mermaid
  sequenceDiagram
      participant Writer
      participant FIFO as OS FIFO (kernel buffer)
      participant Reader

      Writer->>FIFO: IO.binwrite(write_end, data)
      FIFO-->>Reader: IO.binread(read_end, :line)
      Writer->>FIFO: File.close(write_end)
      FIFO-->>Reader: :eof
  ```
  """

  @type t :: %__MODULE__{
          path: Path.t(),
          read_end: pid() | nil,
          write_end: pid() | nil
        }

  defstruct [:path, :read_end, :write_end]

  # Create a new FIFO pipe. Returns `{:ok, pipe}`.
  #
  # The read and write ends must be opened separately with `open_read/1`
  # and `open_write/1`, each from different processes (opening both from
  # the same process will deadlock since FIFO open blocks until both ends
  # are connected).
  @doc false
  @spec create(Path.t()) :: {:ok, t()} | {:error, term()}
  def create(dir \\ System.tmp_dir!()) do
    path = Path.join(dir, "bash_pipe_#{:erlang.unique_integer([:positive])}")

    case System.cmd("mkfifo", [path], stderr_to_stdout: true) do
      {_, 0} -> {:ok, %__MODULE__{path: path}}
      {output, code} -> {:error, "mkfifo failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  # Open the read end of the pipe. Blocks until a writer opens the other end.
  @doc false
  @spec open_read(t()) :: {:ok, t()}
  def open_read(%__MODULE__{path: path} = pipe) do
    {:ok, device} = File.open(path, [:read, :binary, :raw])
    {:ok, %{pipe | read_end: device}}
  end

  # Open the write end of the pipe. Blocks until a reader opens the other end.
  @doc false
  @spec open_write(t()) :: {:ok, t()}
  def open_write(%__MODULE__{path: path} = pipe) do
    {:ok, device} = File.open(path, [:write, :binary, :raw])
    {:ok, %{pipe | write_end: device}}
  end

  # Write data to the pipe.
  @doc false
  @spec write(t(), iodata()) :: :ok | {:error, term()}
  def write(%__MODULE__{write_end: device}, data) do
    IO.binwrite(device, data)
  end

  # Read a line from the pipe. Blocks until data is available or EOF.
  @doc false
  @spec read_line(t()) :: {:ok, binary()} | :eof
  def read_line(%__MODULE__{read_end: device}) do
    case IO.binread(device, :line) do
      :eof -> :eof
      {:error, _} -> :eof
      data -> {:ok, data}
    end
  end

  # Read all data from the pipe until EOF.
  @doc false
  @spec read_all(t()) :: binary()
  def read_all(%__MODULE__{read_end: device}) do
    case IO.binread(device, :all) do
      :eof -> ""
      {:error, _} -> ""
      data -> data
    end
  end

  # Close the write end, signaling EOF to readers.
  @doc false
  @spec close_write(t()) :: :ok
  def close_write(%__MODULE__{write_end: nil}), do: :ok
  def close_write(%__MODULE__{write_end: device}), do: File.close(device)

  # Close the read end.
  @doc false
  @spec close_read(t()) :: :ok
  def close_read(%__MODULE__{read_end: nil}), do: :ok
  def close_read(%__MODULE__{read_end: device}), do: File.close(device)

  # Remove the FIFO from the filesystem and close both ends.
  @doc false
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{} = pipe) do
    close_write(pipe)
    close_read(pipe)
    File.rm(pipe.path)
    :ok
  end
end
