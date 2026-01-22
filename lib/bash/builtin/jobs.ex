defmodule Bash.Builtin.Jobs do
  @moduledoc """
  `jobs [-lnprs] [jobspec ...] or jobs -x command [args]`

  Lists the active jobs.  The -l option lists process id's in addition to the
  normal information; the -p option lists process id's only. If -n is given,
  only processes that have changed status since the last notification are
  printed. JOBSPEC restricts output to that job. The -r and -s options restrict
  output to running and stopped jobs only, respectively. Without options, the
  status of all active jobs is printed.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/jobs.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.JobProcess

  @doc """
  Execute jobs command and return list of active jobs.
  """
  defbash execute(args, state) do
    {flags, job_specs} = parse_args(args)

    # Get all jobs from session state
    jobs =
      state.jobs
      |> Enum.map(fn {_job_num, pid} ->
        try do
          JobProcess.get_job(pid)
        catch
          :exit, _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> filter_by_specs(job_specs)
      |> filter_by_flags(flags)
      |> Enum.sort_by(& &1.job_number)

    # Format and output
    output = format_jobs(jobs, flags, state.current_job, state.previous_job)

    if output do
      write(output)
    end

    :ok
  end

  defp parse_args(args),
    do:
      parse_args(
        args,
        %{long: false, pids_only: false, running: false, stopped: false, new: false},
        []
      )

  defp parse_args([], flags, specs), do: {flags, Enum.reverse(specs)}
  defp parse_args(["-l" | rest], flags, specs), do: parse_args(rest, %{flags | long: true}, specs)

  defp parse_args(["-p" | rest], flags, specs),
    do: parse_args(rest, %{flags | pids_only: true}, specs)

  defp parse_args(["-r" | rest], flags, specs),
    do: parse_args(rest, %{flags | running: true}, specs)

  defp parse_args(["-s" | rest], flags, specs),
    do: parse_args(rest, %{flags | stopped: true}, specs)

  defp parse_args(["-n" | rest], flags, specs), do: parse_args(rest, %{flags | new: true}, specs)
  defp parse_args([arg | rest], flags, specs), do: parse_args(rest, flags, [arg | specs])

  defp filter_by_specs(jobs, []), do: jobs

  defp filter_by_specs(jobs, specs) do
    spec_numbers = specs |> Enum.map(&parse_job_spec/1) |> Enum.reject(&is_nil/1)
    Enum.filter(jobs, fn job -> job.job_number in spec_numbers end)
  end

  defp parse_job_spec("%" <> rest) do
    case Integer.parse(rest) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp parse_job_spec(spec) do
    case Integer.parse(spec) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp filter_by_flags(jobs, %{running: true}), do: Enum.filter(jobs, &(&1.status == :running))
  defp filter_by_flags(jobs, %{stopped: true}), do: Enum.filter(jobs, &(&1.status == :stopped))
  defp filter_by_flags(jobs, _), do: jobs

  defp format_jobs([], _flags, _current_job, _previous_job), do: nil

  defp format_jobs(jobs, flags, current_job, previous_job) do
    Enum.map_join(jobs, "", &format_job(&1, flags, current_job, previous_job))
  end

  defp format_job(job, %{pids_only: true}, _current, _previous) do
    "#{job.os_pid || "?"}\n"
  end

  defp format_job(job, flags, current_job, previous_job) do
    # Marker: + for current, - for previous, space otherwise
    marker =
      cond do
        job.job_number == current_job -> "+"
        job.job_number == previous_job -> "-"
        true -> " "
      end

    status_str =
      case job.status do
        :running -> "Running"
        :stopped -> "Stopped"
        :done -> "Done"
      end

    # Pad status to align
    status_padded = String.pad_trailing(status_str, 23)

    base = "[#{job.job_number}]#{marker}  #{status_padded} #{job.command}"

    if flags.long and job.os_pid do
      "[#{job.job_number}]#{marker}  #{job.os_pid} #{status_padded} #{job.command}\n"
    else
      base <> "\n"
    end
  end
end
