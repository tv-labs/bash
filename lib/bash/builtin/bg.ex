defmodule Bash.Builtin.Bg do
  @moduledoc """
  `bg [job_spec ...]`

  Place each JOB_SPEC in the background, as if it had been started with `&`.
  If JOB_SPEC is not present, the shell's notion of the current job is used.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/fg_bg.def?h=bash-5.3
  """
  use Bash.Builtin

  # Execute bg command.
  # Returns a special tuple for Session to handle.
  @doc false
  defbash execute(args, state) do
    job_specs = parse_job_specs(args, state)

    case job_specs do
      [] ->
        error("bg: no current job")
        {:ok, 1}

      [:invalid | _] ->
        error("bg: invalid job specification")
        {:ok, 1}

      job_numbers ->
        # Verify all jobs exist
        missing =
          Enum.find(job_numbers, fn num ->
            not Map.has_key?(state.jobs, num)
          end)

        case missing do
          nil ->
            # Return special tuple for Session to handle
            {:background_job, job_numbers}

          num ->
            error("bg: %#{num}: no such job")
            {:ok, 1}
        end
    end
  end

  defp parse_job_specs([], session_state) do
    if session_state.current_job do
      [session_state.current_job]
    else
      []
    end
  end

  defp parse_job_specs(args, _session_state) do
    Enum.map(args, &parse_job_spec/1)
  end

  defp parse_job_spec("%%"), do: :current
  defp parse_job_spec("%+"), do: :current
  defp parse_job_spec("%-"), do: :previous

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
