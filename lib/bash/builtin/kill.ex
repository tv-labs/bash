defmodule Bash.Builtin.Kill do
  @moduledoc """
  `kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]`

  Send the processes named by PID (or JOBSPEC) the signal SIGSPEC.
  If SIGSPEC is not present, then SIGTERM is assumed. An argument of `-l`
  lists the signal names; if arguments follow `-l` they are assumed to be
  signal numbers for which names should be listed.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/kill.def?h=bash-5.3
  """
  use Bash.Builtin

  @signals %{
    "HUP" => 1,
    "INT" => 2,
    "QUIT" => 3,
    "ILL" => 4,
    "TRAP" => 5,
    "ABRT" => 6,
    "EMT" => 7,
    "FPE" => 8,
    "KILL" => 9,
    "BUS" => 10,
    "SEGV" => 11,
    "SYS" => 12,
    "PIPE" => 13,
    "ALRM" => 14,
    "TERM" => 15,
    "URG" => 16,
    "STOP" => 17,
    "TSTP" => 18,
    "CONT" => 19,
    "CHLD" => 20,
    "TTIN" => 21,
    "TTOU" => 22,
    "IO" => 23,
    "XCPU" => 24,
    "XFSZ" => 25,
    "VTALRM" => 26,
    "PROF" => 27,
    "WINCH" => 28,
    "INFO" => 29,
    "USR1" => 30,
    "USR2" => 31
  }

  @signal_names Map.new(@signals, fn {k, v} -> {v, k} end)

  @doc """
  Execute kill command.
  Returns a special tuple for Session to handle.
  """
  defbash execute(args, state) do
    case parse_args(args) do
      {:list, nums} ->
        # -l mode: list signal names
        stdout = list_signals(nums)
        write(stdout)
        :ok

      {:error, message} ->
        error(message)
        {:ok, 1}

      {:kill, _signal, []} ->
        error("kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ...\n")
        {:ok, 1}

      {:kill, signal, targets} ->
        # Parse targets into job numbers or PIDs
        parsed_targets = parse_targets(targets, state)

        case Enum.find(parsed_targets, &match?({:error, _}, &1)) do
          {:error, msg} ->
            error(msg)
            {:ok, 1}

          nil ->
            # All targets valid - return tuple for Session to handle
            {:signal_jobs, signal, parsed_targets}
        end
    end
  end

  # Default signal is SIGTERM (15)
  defp parse_args(args), do: parse_args(args, 15, [])

  defp parse_args(["-l" | rest], _signal, _targets) do
    {:list, rest}
  end

  defp parse_args(["-s", sigspec | rest], _signal, targets) do
    case parse_signal(sigspec) do
      {:ok, sig} -> parse_args(rest, sig, targets)
      :error -> {:error, "kill: invalid signal specification: #{sigspec}\n"}
    end
  end

  defp parse_args(["-n", signum | rest], _signal, targets) do
    case Integer.parse(signum) do
      {num, ""} when num > 0 -> parse_args(rest, num, targets)
      _ -> {:error, "kill: invalid signal number: #{signum}\n"}
    end
  end

  defp parse_args(["-" <> sigspec | rest], _signal, targets) do
    case parse_signal(sigspec) do
      {:ok, sig} -> parse_args(rest, sig, targets)
      :error -> {:error, "kill: invalid signal specification: #{sigspec}\n"}
    end
  end

  defp parse_args([], signal, targets), do: {:kill, signal, Enum.reverse(targets)}

  defp parse_args([target | rest], signal, targets),
    do: parse_args(rest, signal, [target | targets])

  defp parse_signal(spec) do
    upper = String.upcase(spec)
    # Try with and without SIG prefix
    name = String.replace_prefix(upper, "SIG", "")

    cond do
      Map.has_key?(@signals, name) ->
        {:ok, @signals[name]}

      match?({_, ""}, Integer.parse(spec)) ->
        {num, ""} = Integer.parse(spec)
        {:ok, num}

      true ->
        :error
    end
  end

  defp list_signals([]) do
    # List all signals
    @signal_names
    |> Enum.sort_by(fn {num, _} -> num end)
    |> Enum.map_join("\n", fn {num, name} -> "#{num}) SIG#{name}" end)
    |> Kernel.<>("\n")
  end

  defp list_signals(nums) do
    nums
    |> Enum.map_join(" ", fn num_str ->
      case Integer.parse(num_str) do
        {num, ""} ->
          case Map.get(@signal_names, num) do
            nil -> num_str
            name -> "SIG#{name}"
          end

        _ ->
          num_str
      end
    end)
    |> Kernel.<>("\n")
  end

  defp parse_targets(targets, state) do
    Enum.map(targets, fn target ->
      cond do
        # Job spec starting with %
        String.starts_with?(target, "%") ->
          case parse_job_spec(target, state) do
            {:ok, job_num} -> {:job, job_num}
            :error -> {:error, "kill: #{target}: no such job\n"}
          end

        # Negative number could be process group
        String.starts_with?(target, "-") ->
          case Integer.parse(target) do
            {pid, ""} -> {:pid, abs(pid)}
            _ -> {:error, "kill: #{target}: arguments must be process or job IDs\n"}
          end

        # Regular PID
        true ->
          case Integer.parse(target) do
            {pid, ""} -> {:pid, pid}
            _ -> {:error, "kill: #{target}: arguments must be process or job IDs\n"}
          end
      end
    end)
  end

  defp parse_job_spec("%" <> rest, state) do
    case rest do
      "%" ->
        {:ok, state.current_job}

      "+" ->
        {:ok, state.current_job}

      "-" ->
        {:ok, state.previous_job}

      _ ->
        case Integer.parse(rest) do
          {num, ""} ->
            if Map.has_key?(state.jobs, num) do
              {:ok, num}
            else
              :error
            end

          _ ->
            :error
        end
    end
  end
end
