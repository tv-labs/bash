defmodule Bash.Builtin.Fg do
  @moduledoc """
  `fg [job_spec]`

  Place JOB_SPEC in the foreground, and make it the current job.
  If JOB_SPEC is not present, the shell's notion of the current job is used.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/fg_bg.def?h=bash-5.3
  """
  use Bash.Builtin

  @doc """
  Execute fg command.
  Returns a special tuple for Session to handle since fg blocks until job completion.
  """
  defbash execute(args, state) do
    job_spec = parse_job_spec(args, state)

    case job_spec do
      nil ->
        error("fg: no current job")
        {:ok, 1}

      :invalid ->
        error("fg: invalid job specification")
        {:ok, 1}

      job_number ->
        # Verify job exists
        case Map.get(state.jobs, job_number) do
          nil ->
            error("fg: %#{job_number}: no such job")
            {:ok, 1}

          _pid ->
            # Return special tuple for Session to handle
            {:foreground_job, job_number}
        end
    end
  end

  defp parse_job_spec([], session_state) do
    session_state.current_job
  end

  defp parse_job_spec(["%%" | _], session_state), do: session_state.current_job
  defp parse_job_spec(["%+" | _], session_state), do: session_state.current_job
  defp parse_job_spec(["%-" | _], session_state), do: session_state.previous_job

  defp parse_job_spec(["%" <> rest | _], _session_state) do
    case Integer.parse(rest) do
      {num, ""} -> num
      _ -> :invalid
    end
  end

  defp parse_job_spec([arg | _], _session_state) do
    case Integer.parse(arg) do
      {num, ""} -> num
      _ -> :invalid
    end
  end
end
