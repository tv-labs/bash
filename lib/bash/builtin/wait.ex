defmodule Bash.Builtin.Wait do
  @moduledoc """
  `wait [n ...]`

  Wait for the specified process and report its termination status.
  If N is not given, all currently active child processes are waited for,
  and the return code is zero. N may be a process ID or a job specification;
  if a job spec is given, all processes in the job's pipeline are waited for.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/wait.def?h=bash-5.3
  """
  use Bash.Builtin

  # Execute wait command.
  # Returns a special tuple for Session to handle since wait blocks until job completion.
  @doc false
  defbash execute(args, state) do
    job_specs = parse_job_specs(args, state)

    case job_specs do
      :all when map_size(state.jobs) == 0 ->
        :ok

      :all ->
        {:wait_for_jobs, nil}

      [:invalid | _] ->
        error("wait: invalid job specification\n")
        {:ok, 1}

      job_numbers ->
        job_numbers
        |> Enum.find(fn num ->
          is_integer(num) and not Map.has_key?(state.jobs, num)
        end)
        |> case do
          nil ->
            {:wait_for_jobs, job_numbers}

          num ->
            error("wait: %#{num}: no such job\n")
            {:ok, 127}
        end
    end
  end

  defp parse_job_specs([], _state), do: :all

  defp parse_job_specs(args, _state) do
    Enum.map(args, &parse_job_spec/1)
  end

  defp parse_job_spec("%%" <> _), do: :current
  defp parse_job_spec("%+" <> _), do: :current
  defp parse_job_spec("%-" <> _), do: :previous

  defp parse_job_spec("%" <> rest) do
    case Integer.parse(rest) do
      {num, ""} -> num
      _ -> :invalid
    end
  end

  defp parse_job_spec(arg) do
    case Integer.parse(arg) do
      {num, ""} -> num
      _ -> :invalid
    end
  end
end
