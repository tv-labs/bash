defmodule Bash.Builtin.WaitTest do
  use Bash.SessionCase, async: false

  setup :start_session

  test "with no jobs succeeds immediately", %{session: session} do
    result = run_script(session, "wait")

    assert result.exit_code == 0
  end

  test "blocks until job completes", %{session: session} do
    run_script(session, "sleep 0.1 &")

    start_time = System.monotonic_time(:millisecond)
    result = run_script(session, "wait")
    elapsed = System.monotonic_time(:millisecond) - start_time

    assert result.exit_code == 0
    assert elapsed >= 50
  end

  test "returns exit code of completed job", %{session: session} do
    run_script(session, "bash -c 'exit 42' &")
    result = run_script(session, "wait")
    assert result.exit_code == 42
  end
end
