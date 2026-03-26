defmodule Bash.CommandPort do
  @moduledoc """
  Single interface for all user-facing OS process execution.

  Provides two layers of API:

  ## High-level API

  `execute/3` runs a command to completion, streaming output to a sink:

      CommandPort.execute("cat", ["bigfile.txt"], sink: sink)

  ## Low-level Process API

  For callers that manage process lifecycles directly (JobProcess, Coproc):

      {:ok, proc} = CommandPort.start_link(["cat"], opts)
      CommandPort.write(proc, "data")
      CommandPort.close_stdin(proc)
      {:ok, data} = CommandPort.read(proc)
      {:ok, 0} = CommandPort.await_exit(proc, 5000)

  ## Streaming API

  For pipeline streaming:

      stream = CommandPort.stream(["sort"], input: upstream)

  ## Restricted Mode

  All process-spawning functions accept a `restricted` boolean. When `true`,
  they return `{:error, :restricted}` instead of spawning a process.

  Internal plumbing (signal delivery, hostname lookup, named pipe creation)
  is exempt and continues to use `System.cmd` directly.

  ```mermaid
  graph TD
    AST[AST.Command] --> CP[CommandPort]
    JP[JobProcess] --> CP
    CO[Coproc] --> CP
    PL[Pipeline] --> CP
    CM[Command builtin] --> CP
    CP -->|restricted?| ERR["{:error, :restricted}"]
    CP -->|allowed| EX[ExCmd / System.cmd]
  ```
  """

  alias Bash.CommandResult

  defguardp is_restricted(restricted) when restricted == true

  # ---------------------------------------------------------------------------
  # Restricted mode helper
  # ---------------------------------------------------------------------------

  @doc """
  Returns whether restricted mode is active for the given session state.

  Safely traverses the nested options map, defaulting to `false` when keys
  are absent (e.g. bare state maps in tests).
  """
  @spec restricted?(map()) :: boolean()
  def restricted?(state), do: state |> Map.get(:options, %{}) |> Map.get(:restricted, false)

  # ---------------------------------------------------------------------------
  # Low-level process API (thin delegates to ExCmd.Process)
  # ---------------------------------------------------------------------------

  @doc """
  Starts an OS process via `ExCmd.Process.start_link/2`.

  Returns `{:error, :restricted}` when `restricted` is `true`.
  """
  @spec start_link(list(String.t()), keyword(), boolean()) ::
          {:ok, pid()} | {:error, :restricted} | {:error, term()}
  def start_link(_cmd_parts, _opts, restricted) when is_restricted(restricted),
    do: {:error, :restricted}

  def start_link(cmd_parts, opts, _restricted),
    do: ExCmd.Process.start_link(cmd_parts, opts)

  @doc "Returns the OS PID of the process."
  @spec os_pid(pid()) :: {:ok, non_neg_integer()} | non_neg_integer()
  defdelegate os_pid(process), to: ExCmd.Process

  @doc "Reads a chunk from the process stdout. Returns `{:ok, data}`, `:eof`, or `{:error, reason}`."
  @spec read(pid()) :: {:ok, binary()} | :eof | {:error, term()}
  defdelegate read(process), to: ExCmd.Process

  @doc "Writes data to the process stdin."
  @spec write(pid(), binary()) :: :ok | {:error, term()}
  defdelegate write(process, data), to: ExCmd.Process

  @doc "Closes the process stdin."
  @spec close_stdin(pid()) :: :ok
  defdelegate close_stdin(process), to: ExCmd.Process

  @doc "Closes the process stdout."
  @spec close_stdout(pid()) :: :ok
  defdelegate close_stdout(process), to: ExCmd.Process

  @doc "Waits for the process to exit within the given timeout."
  @spec await_exit(pid(), non_neg_integer() | :infinity) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate await_exit(process, timeout), to: ExCmd.Process

  # ---------------------------------------------------------------------------
  # Streaming API
  # ---------------------------------------------------------------------------

  @doc """
  Creates an OS process stream via `ExCmd.stream/2`.

  Returns `{:error, :restricted}` when `restricted` is `true`.
  """
  @spec stream(list(String.t()), keyword(), boolean()) ::
          Enumerable.t() | {:error, :restricted}
  def stream(_cmd_parts, _opts, restricted) when is_restricted(restricted),
    do: {:error, :restricted}

  def stream(cmd_parts, opts, _restricted),
    do: ExCmd.stream(cmd_parts, opts)

  # ---------------------------------------------------------------------------
  # System.cmd wrapper
  # ---------------------------------------------------------------------------

  @doc """
  Executes a command via `System.cmd/3`.

  Returns `{:error, :restricted}` when `restricted` is `true`.
  """
  @spec system_cmd(String.t(), list(String.t()), keyword(), boolean()) ::
          {String.t(), non_neg_integer()} | {:error, :restricted}
  def system_cmd(_path, _args, _opts, restricted) when is_restricted(restricted),
    do: {:error, :restricted}

  def system_cmd(path, args, opts, _restricted),
    do: System.cmd(path, args, opts)

  # ---------------------------------------------------------------------------
  # High-level API
  # ---------------------------------------------------------------------------

  @doc false
  def execute(command_name, args, opts \\ []) do
    stdin = opts[:stdin]
    timeout = opts[:timeout] || 5000
    cd = opts[:cd] || File.cwd!()
    env = opts[:env] || []
    sink_opt = opts[:sink]
    restricted = opts[:restricted] || false

    execute_command(command_name, args, stdin, cd, env, timeout, sink_opt, restricted)
  end

  defp execute_command(command_name, args, stdin, cd, env, timeout, sink_opt, restricted) do
    cmd_parts = [command_name | args]

    if System.find_executable(command_name) == nil and
         not String.starts_with?(command_name, "/") and
         not String.starts_with?(command_name, "./") do
      {:error,
       %CommandResult{
         command: Enum.join(cmd_parts, " "),
         exit_code: 127,
         error: :command_not_found
       }}
    else
      execute_with_excmd(cmd_parts, stdin, cd, env, timeout, sink_opt, restricted)
    end
  end

  defp execute_with_excmd(cmd_parts, stdin, cd, env, timeout, sink_opt, restricted) do
    exec_opts = [
      cd: cd,
      env: normalize_env(env),
      stderr: :redirect_to_stdout
    ]

    sink = sink_opt || fn _chunk -> :ok end

    case start_link(cmd_parts, exec_opts, restricted) do
      {:error, :restricted} ->
        command_name = hd(cmd_parts)
        sink.({:stderr, "bash: #{command_name}: restricted\n"})

        {:error,
         %CommandResult{
           command: Enum.join(cmd_parts, " "),
           exit_code: 1,
           error: :restricted
         }}

      {:ok, process} ->
        write_stdin_then_close(process, stdin)
        stream_to_sink(process, sink)

        case await_exit(process, timeout) do
          {:ok, 0} ->
            {:ok,
             %CommandResult{
               command: Enum.join(cmd_parts, " "),
               exit_code: 0,
               error: nil
             }}

          {:ok, 127} ->
            {:error,
             %CommandResult{
               command: Enum.join(cmd_parts, " "),
               exit_code: 127,
               error: :command_not_found
             }}

          {:ok, exit_code} ->
            {:error,
             %CommandResult{
               command: Enum.join(cmd_parts, " "),
               exit_code: exit_code,
               error: :command_failed
             }}

          {:error, :killed} ->
            {:error,
             %CommandResult{
               command: Enum.join(cmd_parts, " "),
               exit_code: nil,
               error: :killed
             }}

          {:error, reason} ->
            {:error,
             %CommandResult{
               command: Enum.join(cmd_parts, " "),
               exit_code: nil,
               error: reason
             }}
        end

      {:error, reason} ->
        {:error,
         %CommandResult{
           command: Enum.join(cmd_parts, " "),
           exit_code: nil,
           error: reason
         }}
    end
  end

  defp stream_to_sink(process, sink) do
    case read(process) do
      {:ok, data} ->
        sink.({:stdout, data})
        stream_to_sink(process, sink)

      :eof ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp normalize_env([]), do: []

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp write_stdin_then_close(process, nil) do
    close_stdin(process)
  end

  defp write_stdin_then_close(process, data) when is_binary(data) do
    case write(process, data) do
      :ok -> close_stdin(process)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_stdin_then_close(process, %Bash.Pipe{} = pipe) do
    case Bash.Pipe.read_line(pipe) do
      {:ok, data} ->
        case write(process, data) do
          :ok -> write_stdin_then_close(process, pipe)
          {:error, _} -> close_stdin(process)
        end

      :eof ->
        close_stdin(process)
    end
  end
end
