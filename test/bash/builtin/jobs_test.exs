defmodule Bash.Builtin.JobsTest do
  use Bash.SessionCase, async: false

  setup :start_session

  test "lists background jobs", %{session: session} do
    run_script(session, "sleep 0.5 &")

    result = run_script(session, "jobs")

    assert result.exit_code == 0
    output = get_stdout(result)
    assert output =~ "[1]"
    assert output =~ "Running"
    assert output =~ "sleep"
  end

  test "jobs -l shows PIDs", %{session: session} do
    run_script(session, "sleep 0.5 &")
    Process.sleep(50)

    result = run_script(session, "jobs -l")

    assert result.exit_code == 0
    output = get_stdout(result)
    assert output =~ ~r/\d+/
  end

  test "returns empty when no jobs running", %{session: session} do
    result = run_script(session, "jobs")

    assert result.exit_code == 0

    assert get_stdout(result) == ""
  end

  test "jobs shows running background process without extra notification", %{session: session} do
    result =
      run_script(session, """
      sleep 0.5 &
      jobs
      wait
      """)

    stdout = get_stdout(result)
    lines = String.split(stdout, "\n", trim: true)
    job_lines = Enum.filter(lines, &(&1 =~ ~r/\[\d+\]/))
    assert length(job_lines) == 1
    assert hd(job_lines) =~ "Running"
  end
end
