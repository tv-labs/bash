defmodule Bash.Builtin.FgTest do
  use Bash.SessionCase, async: false

  setup :start_session

  test "with no jobs returns error", %{session: session} do
    result = run_script(session, "fg")

    assert result.exit_code == 1
    assert get_stderr(result) =~ "no current job"
  end

  test "brings background job to foreground", %{session: session} do
    run_script(session, "sleep 0.1 &")

    start_time = System.monotonic_time(:millisecond)
    result = run_script(session, "fg")
    elapsed = System.monotonic_time(:millisecond) - start_time

    assert elapsed >= 50
    assert result.exit_code == 0
  end
end
