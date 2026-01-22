defmodule Bash.CommandPort do
  @moduledoc """
  Executes external commands using ExCmd.

  ExCmd provides proper stdin/stdout/stderr separation with backpressure,
  unlike native Erlang ports which cannot close stdin separately from stdout.

  ## Streaming

  By default, output is accumulated for backwards compatibility. To stream
  output without accumulation, pass a `:sink` option:

      # Streaming to callback
      sink = Bash.Sink.Passthrough.new(fn chunk -> IO.inspect(chunk) end)
      CommandPort.execute("cat", ["bigfile.txt"], sink: sink)

      # Streaming to file
      {sink, close} = Bash.Sink.File.new("/tmp/output.txt")
      CommandPort.execute("cat", ["bigfile.txt"], sink: sink)
      close.()
  """

  alias Bash.CommandResult
  alias Bash.Sink

  @doc """
  Executes a command with optional stdin input.

  Returns {:ok, %CommandResult{}} or {:error, %CommandResult{}}.
  Output is streamed to the sink during execution rather than accumulated.

  ## Options

  - `:stdin` - Binary data to write to the command's stdin
  - `:timeout` - Timeout in milliseconds (default: 5000)
  - `:cd` - Working directory for the command
  - `:env` - Environment variables as a list of `{key, value}` tuples
  - `:sink` - Output sink function (default: uses Sink.List for backwards compat)
  """
  def execute(command_name, args, opts \\ []) do
    stdin = opts[:stdin]
    timeout = opts[:timeout] || 5000
    cd = opts[:cd] || File.cwd!()
    env = opts[:env] || []
    sink_opt = opts[:sink]

    execute_command(command_name, args, stdin, cd, env, timeout, sink_opt)
  end

  defp execute_command(command_name, args, stdin, cd, env, timeout, sink_opt) do
    cmd_parts = [command_name | args]

    # Check if command exists before trying to execute
    # ExCmd doesn't return 127 for command not found, so we check manually
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
      execute_with_excmd(cmd_parts, stdin, cd, env, timeout, sink_opt)
    end
  end

  defp execute_with_excmd(cmd_parts, stdin, cd, env, timeout, sink_opt) do
    # Build ExCmd options - ExCmd 0.18.0 only accepts cd, env, and stderr options
    exec_opts = [
      cd: cd,
      env: normalize_env(env),
      stderr: :redirect_to_stdout
    ]

    # If no sink provided, use list accumulator
    sink =
      if sink_opt do
        sink_opt
      else
        {sink, _get_output} = Sink.List.new()
        sink
      end

    case ExCmd.Process.start_link(cmd_parts, exec_opts) do
      {:ok, process} ->
        # Write stdin if provided, then close stdin
        if stdin do
          case ExCmd.Process.write(process, stdin) do
            :ok -> ExCmd.Process.close_stdin(process)
            {:error, reason} -> {:error, reason}
          end
        else
          # Close stdin when no input provided
          ExCmd.Process.close_stdin(process)
        end

        # Stream output to sink (does not accumulate in memory)
        stream_to_sink(process, sink)

        # Wait for exit
        case ExCmd.Process.await_exit(process, timeout) do
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

  # Stream output chunks to sink without accumulating in memory
  defp stream_to_sink(process, sink) do
    case ExCmd.Process.read(process) do
      {:ok, data} ->
        sink.({:stdout, data})
        stream_to_sink(process, sink)

      :eof ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  # Normalize environment to keyword list format expected by ExCmd
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
end
