defmodule Bash.TimeoutDebugTest do
  use Bash.SessionCase, async: true
  @moduletag timeout: 15000
  @moduletag :tmp_dir
  @moduletag working_dir: :tmp_dir

  setup :start_session

  test "kill by PID clears job from state", %{session: session} do
    # This is the pattern at lines 303-306 in sloppy_comprehensive.bash
    result =
      run_script(session, """
      sleep 100 &
      pid=$!
      kill $pid 2>/dev/null
      sleep 0.1
      wait $pid 2>/dev/null || true
      echo "after kill wait"
      """)

    stdout = get_stdout(result)
    assert String.contains?(stdout, "after kill wait")
  end

  test "wait after killed job doesn't hang", %{session: session} do
    # Start a job, kill it, then run a bare wait that should not hang
    result =
      run_script(session, """
      sleep 100 &
      pid=$!
      kill $pid 2>/dev/null
      sleep 0.5
      wait
      echo "bare wait done"
      """)

    stdout = get_stdout(result)
    assert String.contains?(stdout, "bare wait done")
  end

  test "multiple bg jobs then bare wait", %{session: session} do
    result =
      run_script(session, """
      echo a &
      echo b &
      wait
      echo "done"
      """)

    stdout = get_stdout(result)
    assert String.contains?(stdout, "done")
  end

  test "kill by job spec then wait", %{session: session} do
    # This goes through JobProcess.signal, not System.cmd
    result =
      run_script(session, """
      sleep 100 &
      kill %1
      sleep 0.5
      wait
      echo "done"
      """)

    stdout = get_stdout(result)
    assert String.contains?(stdout, "done")
  end

  test "echo in background then wait", %{session: session} do
    # This mirrors line 471-472 of the comprehensive test
    result =
      run_script(session, """
      echo c & echo d
      wait
      echo "after wait"
      """)

    stdout = get_stdout(result)
    assert String.contains?(stdout, "after wait")
  end
end
