defmodule Bash.Builtin.KillTest do
  use Bash.SessionCase, async: false

  setup :start_session

  test "kill -l lists signals", %{session: session} do
    result = run_script(session, "kill -l")

    assert result.exit_code == 0
    output = get_stdout(result)
    assert output =~ "SIGTERM"
    assert output =~ "SIGKILL"
  end

  test "kill terminates background job", %{session: session} do
    run_script(session, "sleep 10 &")

    # Wait for job to start
    Process.sleep(100)

    result = run_script(session, "kill %1")

    assert result.exit_code == 0

    # Job should complete quickly after signal
    run_script(session, "wait")

    # Verify job is gone
    jobs_result = run_script(session, "jobs")
    assert get_stdout(jobs_result) == ""
  end
end
