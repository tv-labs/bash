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

  Note: Since Elixir/Erlang doesn't track process times the same way a traditional
  Unix shell does, this implementation returns placeholder values. In a real bash
  shell, this would show actual CPU time consumed.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-times
  """
  use Bash.Builtin

  defbash execute(_args, _state) do
    # Get runtime system statistics if available
    # For the BEAM VM, we can get some timing info from :erlang.statistics
    {shell_user, shell_sys} = get_shell_times()
    {child_user, child_sys} = get_child_times()

    shell_line = "#{format_time(shell_user)} #{format_time(shell_sys)}"
    child_line = "#{format_time(child_user)} #{format_time(child_sys)}"
    puts("#{shell_line}\n#{child_line}")
    :ok
  end

  # Get accumulated times for the shell process itself
  # Using Erlang's runtime statistics
  defp get_shell_times do
    # :runtime returns {Total_Run_Time, Time_Since_Last_Call} in milliseconds
    # This is CPU time used by the Erlang emulator
    {total_runtime_ms, _} = :erlang.statistics(:runtime)

    # Convert to seconds
    total_runtime_s = total_runtime_ms / 1000.0

    # We don't have a clean split between user and system time in BEAM,
    # so we report all as user time and 0 for system time
    {total_runtime_s, 0.0}
  end

  # Get accumulated times for child processes
  # In bash, this would be cumulative time from all forked processes
  defp get_child_times do
    # The BEAM doesn't track child process times the same way Unix shells do.
    # When we spawn external processes via ports, we don't get their CPU times.
    # Return zeros as placeholder.
    {0.0, 0.0}
  end

  # Format time as NmN.NNNs
  defp format_time(seconds) when is_float(seconds) do
    minutes = trunc(seconds / 60)
    remaining_seconds = seconds - minutes * 60

    "#{minutes}m#{:erlang.float_to_binary(remaining_seconds, decimals: 3)}s"
  end

  defp format_time(seconds) when is_integer(seconds) do
    format_time(seconds * 1.0)
  end
end
