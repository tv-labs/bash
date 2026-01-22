defmodule Bash.Builtin.Disown do
  @moduledoc """
  `disown [-h] [-ar] [jobspec ... | pid ...]`

  Remove jobs from the job table or mark them so they don't receive SIGHUP.

  Options:
    -a    Remove all jobs if no jobspec is given
    -r    Remove only running jobs
    -h    Mark jobs so that SIGHUP is not sent when the shell exits

  Without options, remove each JOBSPEC from the table of active jobs.
  If JOBSPEC is not present, the current job is used.

  Exit Status:
  Returns success unless an invalid option or JOBSPEC is given.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/jobs.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.JobProcess
  alias Bash.OrphanSupervisor

  defbash execute(args, state) do
    {opts, job_specs} = parse_args(args)

    cond do
      opts.all -> disown_all(state, opts)
      job_specs == [] -> disown_current(state, opts)
      true -> disown_specs(job_specs, state, opts)
    end
  end

  defp parse_args(args) do
    parse_args(args, %{all: false, running_only: false, no_hup: false}, [])
  end

  defp parse_args([], opts, specs), do: {opts, Enum.reverse(specs)}
  defp parse_args(["-a" | rest], opts, specs), do: parse_args(rest, %{opts | all: true}, specs)

  defp parse_args(["-r" | rest], opts, specs),
    do: parse_args(rest, %{opts | running_only: true}, specs)

  defp parse_args(["-h" | rest], opts, specs), do: parse_args(rest, %{opts | no_hup: true}, specs)

  defp parse_args(["-" <> flags | rest], opts, specs) when byte_size(flags) > 1 do
    new_opts =
      String.graphemes(flags)
      |> Enum.reduce(opts, fn
        "a", acc -> %{acc | all: true}
        "r", acc -> %{acc | running_only: true}
        "h", acc -> %{acc | no_hup: true}
        _, acc -> acc
      end)

    parse_args(rest, new_opts, specs)
  end

  defp parse_args(["--" | rest], opts, specs), do: {opts, Enum.reverse(specs) ++ rest}
  defp parse_args([spec | rest], opts, specs), do: parse_args(rest, opts, [spec | specs])

  defp disown_all(state, opts) do
    jobs_to_remove =
      state.jobs
      |> Enum.map(fn {job_num, pid} -> {job_num, pid, get_job_safe(pid)} end)
      |> maybe_filter_running(opts.running_only)

    if opts.no_hup do
      # Mark jobs as nohup (we don't actually track this, just succeed)
      :ok
    else
      # Detach each job from the session
      Enum.each(jobs_to_remove, fn {_, pid, _} -> OrphanSupervisor.adopt(pid) end)

      job_nums_to_remove = Enum.map(jobs_to_remove, fn {num, _, _} -> num end)
      new_jobs = Map.drop(state.jobs, job_nums_to_remove)
      update_state(jobs: new_jobs)
      :ok
    end
  end

  defp disown_current(state, opts) do
    case state.current_job do
      nil ->
        error("disown: current: no such job\n")
        {:ok, 1}

      job_num ->
        disown_job_number(job_num, state, opts)
    end
  end

  defp disown_specs(specs, state, opts) do
    results = Enum.map(specs, &parse_job_spec(&1, state))

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, msg} ->
        error("#{msg}\n")
        {:ok, 1}

      nil ->
        job_nums = Enum.map(results, fn {:ok, num} -> num end)

        # Validate all job numbers exist
        missing = Enum.find(job_nums, fn num -> not Map.has_key?(state.jobs, num) end)

        if missing do
          error("disown: %#{missing}: no such job\n")
          {:ok, 1}
        else
          if opts.no_hup do
            :ok
          else
            # Detach each job from the session
            Enum.each(job_nums, fn job_num ->
              case Map.get(state.jobs, job_num) do
                nil -> :ok
                pid -> OrphanSupervisor.adopt(pid)
              end
            end)

            new_jobs = Map.drop(state.jobs, job_nums)
            update_state(jobs: new_jobs)
            :ok
          end
        end
    end
  end

  defp disown_job_number(job_num, state, opts) do
    case Map.get(state.jobs, job_num) do
      nil ->
        error("disown: %#{job_num}: no such job\n")
        {:ok, 1}

      pid ->
        if opts.no_hup do
          :ok
        else
          # Detach the job from the session
          OrphanSupervisor.adopt(pid)
          new_jobs = Map.delete(state.jobs, job_num)
          update_state(jobs: new_jobs)
          :ok
        end
    end
  end

  defp parse_job_spec("%" <> rest, state) do
    case rest do
      "%" ->
        {:ok, state.current_job || 0}

      "+" ->
        {:ok, state.current_job || 0}

      "-" ->
        {:ok, state.previous_job || 0}

      _ ->
        case Integer.parse(rest) do
          {num, ""} -> {:ok, num}
          _ -> {:error, "disown: %#{rest}: no such job"}
        end
    end
  end

  defp parse_job_spec(spec, _state) do
    case Integer.parse(spec) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "disown: #{spec}: no such job"}
    end
  end

  defp get_job_safe(pid) do
    try do
      JobProcess.get_job(pid)
    catch
      :exit, _ -> nil
    end
  end

  defp maybe_filter_running(jobs, true) do
    # Only keep jobs that we can confirm are running
    Enum.filter(jobs, fn {_, _, job} -> job && job.status == :running end)
  end

  defp maybe_filter_running(jobs, false) do
    # Keep all jobs, whether we can get their status or not
    jobs
  end
end
