defmodule Bash.Builtin.Times do
  @moduledoc """
  `times`

  Print the accumulated user and system times for the shell and for processes
  run from the shell.

  The return status is zero.

  Output format:
    user_time system_time    (shell)
    user_time system_time    (children)

  Where each time is in the format NmN.NNNs (minutes and seconds).

  Since the BEAM VM doesn't distinguish user vs system CPU time, we report
  `:erlang.statistics(:runtime)` elapsed since session start as user time
  and `0m0.000s` for system time.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-times
  """
  use Bash.Builtin

  defbash execute(_args, state) do
    shell_user_ms = get_shell_user_time(state)

    shell_line = "#{format_time(shell_user_ms)} #{format_time(0)}"
    child_line = "#{format_time(0)} #{format_time(0)}"
    puts("#{shell_line}\n#{child_line}")
    :ok
  end

  defp get_shell_user_time(state) do
    {current_runtime_ms, _} = :erlang.statistics(:runtime)
    start_runtime_ms = Map.get(state, :start_runtime_ms, current_runtime_ms)
    current_runtime_ms - start_runtime_ms
  end

  defp format_time(milliseconds) when is_integer(milliseconds) do
    seconds = milliseconds / 1000.0
    minutes = trunc(seconds / 60)
    remaining = seconds - minutes * 60
    "#{minutes}m#{:erlang.float_to_binary(remaining, decimals: 3)}s"
  end
end
