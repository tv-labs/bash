defmodule Bash.Builtin.Trap do
  @moduledoc """
  `trap [-lp] [arg signal_spec ...]`

  The command ARG is to be read and executed when the shell receives
  signal(s) SIGNAL_SPEC.  If ARG is absent (and a single SIGNAL_SPEC
  is supplied) or `-`, each specified signal is reset to its original
  value.  If ARG is the null string each SIGNAL_SPEC is ignored by the
  shell and by the commands it invokes.  If a SIGNAL_SPEC is EXIT (0)
  the command ARG is executed on exit from the shell.  If a SIGNAL_SPEC
  is DEBUG, ARG is executed after every simple command.  If the`-p` option
  is supplied then the trap commands associated with each SIGNAL_SPEC are
  displayed.  If no arguments are supplied or if only `-p` is given, trap
  prints the list of commands associated with each signal.  Each SIGNAL_SPEC
  is either a signal name in <signal.h> or a signal number.  Signal names
  are case insensitive and the SIG prefix is optional. `trap -l` prints
  a list of signal names and their corresponding numbers.  Note that a
  signal can be sent to the shell with `kill -signal $$`.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/trap.def?h=bash-5.3
  """
  use Bash.Builtin

  # Pseudo-signals (bash-specific)
  @pseudo_signals %{
    "EXIT" => 0,
    "ERR" => -1,
    "DEBUG" => -2,
    "RETURN" => -3
  }

  # Standard POSIX signals (typical Unix values)
  @standard_signals %{
    "HUP" => 1,
    "SIGHUP" => 1,
    "INT" => 2,
    "SIGINT" => 2,
    "QUIT" => 3,
    "SIGQUIT" => 3,
    "ILL" => 4,
    "SIGILL" => 4,
    "TRAP" => 5,
    "SIGTRAP" => 5,
    "ABRT" => 6,
    "SIGABRT" => 6,
    "EMT" => 7,
    "SIGEMT" => 7,
    "FPE" => 8,
    "SIGFPE" => 8,
    "KILL" => 9,
    "SIGKILL" => 9,
    "BUS" => 10,
    "SIGBUS" => 10,
    "SEGV" => 11,
    "SIGSEGV" => 11,
    "SYS" => 12,
    "SIGSYS" => 12,
    "PIPE" => 13,
    "SIGPIPE" => 13,
    "ALRM" => 14,
    "SIGALRM" => 14,
    "TERM" => 15,
    "SIGTERM" => 15,
    "URG" => 16,
    "SIGURG" => 16,
    "STOP" => 17,
    "SIGSTOP" => 17,
    "TSTP" => 18,
    "SIGTSTP" => 18,
    "CONT" => 19,
    "SIGCONT" => 19,
    "CHLD" => 20,
    "SIGCHLD" => 20,
    "TTIN" => 21,
    "SIGTTIN" => 21,
    "TTOU" => 22,
    "SIGTTOU" => 22,
    "IO" => 23,
    "SIGIO" => 23,
    "XCPU" => 24,
    "SIGXCPU" => 24,
    "XFSZ" => 25,
    "SIGXFSZ" => 25,
    "VTALRM" => 26,
    "SIGVTALRM" => 26,
    "PROF" => 27,
    "SIGPROF" => 27,
    "WINCH" => 28,
    "SIGWINCH" => 28,
    "INFO" => 29,
    "SIGINFO" => 29,
    "USR1" => 30,
    "SIGUSR1" => 30,
    "USR2" => 31,
    "SIGUSR2" => 31
  }

  # All signals combined
  @all_signals Map.merge(@pseudo_signals, @standard_signals)

  # Signal number to canonical name mapping
  @signal_numbers %{
    0 => "EXIT",
    1 => "HUP",
    2 => "INT",
    3 => "QUIT",
    4 => "ILL",
    5 => "TRAP",
    6 => "ABRT",
    7 => "EMT",
    8 => "FPE",
    9 => "KILL",
    10 => "BUS",
    11 => "SEGV",
    12 => "SYS",
    13 => "PIPE",
    14 => "ALRM",
    15 => "TERM",
    16 => "URG",
    17 => "STOP",
    18 => "TSTP",
    19 => "CONT",
    20 => "CHLD",
    21 => "TTIN",
    22 => "TTOU",
    23 => "IO",
    24 => "XCPU",
    25 => "XFSZ",
    26 => "VTALRM",
    27 => "PROF",
    28 => "WINCH",
    29 => "INFO",
    30 => "USR1",
    31 => "USR2",
    # Pseudo-signals with negative numbers
    -1 => "ERR",
    -2 => "DEBUG",
    -3 => "RETURN"
  }

  defbash execute(args, state) do
    traps = Map.get(state, :traps, %{})

    case parse_args(args) do
      {:list_all} ->
        # No args or just -p: list all traps
        stdout = format_traps_string(traps)
        if stdout != "", do: write(stdout)
        :ok

      {:list_signals} ->
        # -l: list signal names and numbers
        write(format_signal_list_string())
        :ok

      {:print, signals} ->
        # -p signal...: print specific traps in reusable format
        stdout = format_traps_string(traps, signals)
        if stdout != "", do: write(stdout)
        :ok

      {:set, action, signals} ->
        # Set trap for signals
        case set_traps(traps, action, signals) do
          {:ok, new_traps} ->
            update_state(traps: new_traps)
            :ok

          {:error, message} ->
            error(message)
            {:ok, 1}
        end

      {:reset, signals} ->
        # Reset signals to default (using -)
        case reset_traps(traps, signals) do
          {:ok, new_traps} ->
            update_state(traps: new_traps)
            :ok

          {:error, message} ->
            error(message)
            {:ok, 1}
        end

      {:error, message} ->
        error(message)
        {:ok, 1}
    end
  end

  # Parse command-line arguments
  defp parse_args([]) do
    {:list_all}
  end

  defp parse_args(["-l"]) do
    {:list_signals}
  end

  defp parse_args(["-l" | _rest]) do
    # -l ignores other arguments
    {:list_signals}
  end

  defp parse_args(["-p"]) do
    {:list_all}
  end

  defp parse_args(["-p" | signals]) when signals != [] do
    {:print, signals}
  end

  # Handle -lp or -pl combinations
  defp parse_args(["-lp" | _rest]), do: {:list_signals}
  defp parse_args(["-pl" | _rest]), do: {:list_signals}

  defp parse_args(["-"]) do
    {:error, "trap: missing signal specification"}
  end

  defp parse_args(["-" | signals]) when signals != [] do
    # Reset signals to default
    {:reset, signals}
  end

  defp parse_args([action | signals]) when signals != [] do
    # Set trap action for signals
    {:set, action, signals}
  end

  defp parse_args([signal]) do
    # Single argument without action - reset to default
    {:reset, [signal]}
  end

  # Set traps for the given signals
  defp set_traps(traps, action, signals) do
    Enum.reduce_while(signals, {:ok, traps}, fn signal_spec, {:ok, acc} ->
      case normalize_signal(signal_spec) do
        {:ok, signal_name} ->
          new_traps =
            if action == "" do
              # Empty string means ignore the signal
              Map.put(acc, signal_name, :ignore)
            else
              Map.put(acc, signal_name, action)
            end

          {:cont, {:ok, new_traps}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # Reset traps to default (remove from map)
  defp reset_traps(traps, signals) do
    Enum.reduce_while(signals, {:ok, traps}, fn signal_spec, {:ok, acc} ->
      case normalize_signal(signal_spec) do
        {:ok, signal_name} ->
          {:cont, {:ok, Map.delete(acc, signal_name)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # Normalize a signal specification to a canonical signal name
  defp normalize_signal(spec) do
    # First try parsing as a number
    case Integer.parse(spec) do
      {num, ""} ->
        case Map.get(@signal_numbers, num) do
          nil -> {:error, "trap: #{spec}: invalid signal specification"}
          name -> {:ok, name}
        end

      _ ->
        # Try as signal name (case insensitive, optional SIG prefix)
        upper = String.upcase(spec)

        cond do
          Map.has_key?(@all_signals, upper) ->
            {:ok, canonical_name(upper)}

          Map.has_key?(@all_signals, "SIG" <> upper) ->
            {:ok, canonical_name("SIG" <> upper)}

          true ->
            {:error, "trap: #{spec}: invalid signal specification"}
        end
    end
  end

  # Get the canonical name for a signal
  defp canonical_name(name) do
    # Get the signal number and then the canonical name
    num = Map.get(@all_signals, name)
    Map.get(@signal_numbers, num, name)
  end

  # Format traps for display (all traps) - returns string
  defp format_traps_string(traps) when map_size(traps) == 0 do
    ""
  end

  defp format_traps_string(traps) do
    traps
    |> Enum.sort_by(fn {name, _} -> signal_sort_key(name) end)
    |> Enum.map_join("\n", fn {signal, action} ->
      format_trap_line(signal, action)
    end)
    |> Kernel.<>("\n")
  end

  # Format traps for specific signals - returns string
  defp format_traps_string(traps, signals) do
    output =
      signals
      |> Enum.filter(fn spec ->
        case normalize_signal(spec) do
          {:ok, name} -> Map.has_key?(traps, name)
          _ -> false
        end
      end)
      |> Enum.map(fn spec ->
        {:ok, name} = normalize_signal(spec)
        {name, Map.get(traps, name)}
      end)
      |> Enum.sort_by(fn {name, _} -> signal_sort_key(name) end)
      |> Enum.map_join("\n", fn {signal, action} ->
        format_trap_line(signal, action)
      end)

    if output == "", do: "", else: output <> "\n"
  end

  # Format a single trap line in reusable format
  defp format_trap_line(signal, :ignore) do
    "trap -- '' #{signal}"
  end

  defp format_trap_line(signal, action) do
    escaped = escape_for_shell(action)
    "trap -- #{escaped} #{signal}"
  end

  # Escape a string for shell reuse
  defp escape_for_shell(str) do
    if needs_quoting?(str) do
      "'" <> String.replace(str, "'", "'\\''") <> "'"
    else
      str
    end
  end

  defp needs_quoting?(str) do
    String.contains?(str, [" ", "\t", "\n", "'", "\"", "$", "`", "\\", ";", "|", "&", "<", ">"])
  end

  # Sort key for signals (pseudo-signals first, then by number)
  defp signal_sort_key(name) do
    num = Map.get(@all_signals, name, 999)
    # Put pseudo-signals (negative numbers) first, sorted by abs value
    if num < 0, do: {0, -num}, else: {1, num}
  end

  # Format the signal list (-l output) - returns string
  defp format_signal_list_string do
    # Format similar to bash's output: number) NAME pairs
    @signal_numbers
    |> Enum.filter(fn {num, _} -> num >= 0 end)
    |> Enum.sort_by(fn {num, _} -> num end)
    |> Enum.map(fn {num, name} -> " #{num}) SIG#{name}" end)
    |> Enum.chunk_every(4)
    |> Enum.map_join("\n", fn chunk -> Enum.join(chunk, "\t") end)
    |> Kernel.<>("\n")
  end

  @doc """
  Get the trap action for a specific signal.

  Returns:
  - `nil` - signal uses default behavior
  - `:ignore` - signal is ignored
  - `command` - command string to execute
  """
  def get_trap(session_state, signal) do
    traps = Map.get(session_state, :traps, %{})

    case normalize_signal(to_string(signal)) do
      {:ok, name} -> Map.get(traps, name)
      _ -> nil
    end
  end

  @doc """
  Check if a signal has a trap set.
  """
  def has_trap?(session_state, signal) do
    get_trap(session_state, signal) != nil
  end

  @doc """
  Get the EXIT trap command, if set.
  """
  def get_exit_trap(session_state) do
    get_trap(session_state, "EXIT")
  end

  @doc """
  Get the ERR trap command, if set.
  """
  def get_err_trap(session_state) do
    get_trap(session_state, "ERR")
  end

  @doc """
  Get the DEBUG trap command, if set.
  """
  def get_debug_trap(session_state) do
    get_trap(session_state, "DEBUG")
  end

  @doc """
  Get the RETURN trap command, if set.
  """
  def get_return_trap(session_state) do
    get_trap(session_state, "RETURN")
  end
end
