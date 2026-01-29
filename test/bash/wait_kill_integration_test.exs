defmodule Bash.WaitKillIntegrationTest do
  @moduledoc """
  Integration tests for background job lifecycle: starting, waiting, killing,
  and script continuation after wait. Asserts no lingering OS processes remain
  after each scenario.
  """
  use Bash.SessionCase, async: false

  @moduletag timeout: 30_000
  @moduletag :tmp_dir
  @moduletag working_dir: :tmp_dir

  alias Bash.Session

  setup :start_session

  defp os_process_alive?(os_pid) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, ""} -> os_process_alive?(pid)
      _ -> false
    end
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_for_os_process_exit(os_pid, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if not os_process_alive?(os_pid) do
        :done
      else
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(50)
          :continue
        end
      end
    end)
    |> Enum.find(&(&1 != :continue))
  end

  defp collect_os_pids(session, script) do
    result = run_script(session, script)
    stdout = get_stdout(result)

    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Integer.parse(String.trim(line)) do
        {pid, ""} when pid > 0 -> [pid]
        _ -> []
      end
    end)
  end

  defp assert_no_lingering_processes(os_pids) do
    lingering =
      os_pids
      |> Enum.filter(&os_process_alive?/1)

    assert lingering == [],
           "Expected all OS processes to be terminated, but these are still alive: #{inspect(lingering)}"
  end

  describe "wait continues script execution" do
    test "wait then echo in single script", %{session: session} do
      result = run_script(session, "sleep 0.05 & wait; echo continued")
      assert get_stdout(result) =~ "continued"
    end

    test "wait then multiple commands", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        wait
        echo first
        echo second
        """)

      stdout = get_stdout(result)
      assert stdout =~ "first"
      assert stdout =~ "second"
    end

    test "wait returns zero for successful jobs", %{session: session} do
      result =
        run_script(session, """
        bash -c 'exit 0' &
        wait
        echo "status: $?"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "status: 0"
    end

    test "wait for specific job by number", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        sleep 0.05 &
        wait %1
        echo "waited for job 1"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "waited for job 1"
    end

    test "wait for all then run commands", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        sleep 0.05 &
        sleep 0.05 &
        wait
        echo "all done"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "all done"
    end

    test "multiple wait calls in sequence", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        wait
        echo "after first wait"
        sleep 0.05 &
        wait
        echo "after second wait"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "after first wait"
      assert stdout =~ "after second wait"
    end

    test "wait with no background jobs is a no-op", %{session: session} do
      result =
        run_script(session, """
        wait
        echo "no jobs to wait for"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "no jobs to wait for"
    end

    test "variable assignments persist after wait", %{session: session} do
      result =
        run_script(session, """
        x=before
        sleep 0.05 &
        wait
        echo $x
        x=after
        echo $x
        """)

      stdout = get_stdout(result)
      assert stdout =~ "before"
      assert stdout =~ "after"
    end
  end

  describe "kill then wait in script" do
    test "kill %N then wait continues", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        kill %1
        sleep 0.1
        wait
        echo "done after kill"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "done after kill"
    end

    test "kill $! then wait continues", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        pid=$!
        kill $pid
        sleep 0.1
        wait
        echo "killed by pid"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "killed by pid"
    end

    test "kill multiple jobs individually then wait", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        sleep 100 &
        kill %1
        kill %2
        sleep 0.2
        wait
        echo "both killed"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "both killed"
    end

    test "kill multiple jobs in one command then wait", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        sleep 100 &
        kill %1 %2
        sleep 0.2
        wait
        echo "multi-kill done"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "multi-kill done"
    end

    test "kill -9 then wait", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        kill -9 %1
        sleep 0.1
        wait
        echo "sigkilled"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "sigkilled"
    end

    test "kill then wait completes without error", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        kill %1
        sleep 0.1
        wait
        echo "completed"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "completed"
      assert result.exit_code == 0
    end
  end

  describe "no lingering OS processes after wait" do
    test "single background job cleaned up after wait", %{session: session} do
      os_pids = collect_os_pids(session, "sleep 100 & echo $!")
      assert length(os_pids) == 1

      run_script(session, "kill %1; sleep 0.1; wait")

      assert_no_lingering_processes(os_pids)
    end

    test "multiple background jobs cleaned up after separate kills", %{session: session} do
      os_pids1 = collect_os_pids(session, "sleep 100 & echo $!")
      os_pids2 = collect_os_pids(session, "sleep 100 & echo $!")
      os_pids = os_pids1 ++ os_pids2
      assert length(os_pids) == 2

      run_script(session, "kill %1")
      run_script(session, "kill %2")
      Process.sleep(200)
      run_script(session, "wait")

      for os_pid <- os_pids do
        assert wait_for_os_process_exit(os_pid) == :done,
               "OS process #{os_pid} still alive after kill+wait"
      end
    end

    test "naturally completed jobs leave no OS processes", %{session: session} do
      os_pids = collect_os_pids(session, "sleep 0.05 & echo $!")
      assert length(os_pids) == 1

      run_script(session, "wait")
      assert wait_for_os_process_exit(hd(os_pids)) == :done
    end

    test "killed job leaves no OS process", %{session: session} do
      os_pids =
        collect_os_pids(session, """
        sleep 100 &
        echo $!
        """)

      assert length(os_pids) == 1

      run_script(session, "kill %1")
      assert wait_for_os_process_exit(hd(os_pids)) == :done
    end

    test "kill -9 leaves no OS process", %{session: session} do
      os_pids =
        collect_os_pids(session, """
        sleep 100 &
        echo $!
        """)

      run_script(session, "kill -9 %1")
      assert wait_for_os_process_exit(hd(os_pids)) == :done
    end

    test "script with kill+wait leaves no OS processes", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        pid1=$!
        kill %1
        sleep 0.2
        wait
        echo $pid1
        echo "clean"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "clean"

      os_pids =
        stdout
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Integer.parse(String.trim(line)) do
            {pid, ""} when pid > 0 -> [pid]
            _ -> []
          end
        end)

      assert_no_lingering_processes(os_pids)
    end
  end

  describe "no lingering OS processes after session stop" do
    test "session stop terminates BEAM job processes", context do
      {:ok, isolated_session} =
        Session.new(id: context.test, working_dir: context.tmp_dir)

      run_script(isolated_session, "sleep 100 &")

      state = Session.get_state(isolated_session)
      job_pids = Map.values(state.jobs)
      assert length(job_pids) == 1
      beam_pid = hd(job_pids)
      assert Process.alive?(beam_pid)

      GenServer.stop(isolated_session)

      # BEAM-level JobProcess should be terminated
      refute Process.alive?(beam_pid)
    end
  end

  describe "wait in script with job state visibility" do
    test "wait sees jobs started in same script", %{session: session} do
      start_time = System.monotonic_time(:millisecond)

      result =
        run_script(session, """
        sleep 0.2 &
        wait
        echo "waited"
        """)

      elapsed = System.monotonic_time(:millisecond) - start_time

      stdout = get_stdout(result)
      assert stdout =~ "waited"
      # Must have actually waited (at least 100ms to account for timing)
      assert elapsed >= 100, "wait should have blocked for at least 100ms, got #{elapsed}ms"
    end

    test "kill sees jobs started in same script", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        kill %1
        echo "killed in script"
        """)

      stdout = get_stdout(result)
      # kill should not produce an error about missing job
      stderr = get_stderr(result)
      refute stderr =~ "no such job"
      assert stdout =~ "killed in script"
    end

    test "jobs sees jobs started in same script", %{session: session} do
      result =
        run_script(session, """
        sleep 0.5 &
        jobs
        """)

      stdout = get_stdout(result)
      assert stdout =~ "[1]"
      assert stdout =~ "Running"
    end

    test "wait for specific job spec %% (current)", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        wait %%
        echo "current done"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "current done"
    end
  end

  describe "edge cases" do
    test "wait after job already completed", %{session: session} do
      result =
        run_script(session, """
        echo fast &
        sleep 0.1
        wait
        echo "waited for completed"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "waited for completed"
    end

    test "rapid start and kill", %{session: session} do
      result =
        run_script(session, """
        sleep 100 &
        kill %1
        echo "rapid"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "rapid"
    end

    test "wait between background jobs", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        wait
        sleep 0.05 &
        wait
        echo "interleaved"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "interleaved"
    end

    test "background job output captured after wait", %{session: session} do
      result =
        run_script(session, """
        echo "from bg" &
        wait
        echo "from fg"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "from bg"
      assert stdout =~ "from fg"
    end

    test "sequential wait calls each complete", %{session: session} do
      result =
        run_script(session, """
        sleep 0.05 &
        wait
        first="done1"
        sleep 0.05 &
        wait
        second="done2"
        echo "$first $second"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "done1 done2"
    end

    test "wait with nonexistent job number errors", %{session: session} do
      result =
        run_script(session, """
        wait %99
        echo "exit: $?"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "exit: 127"
    end

    test "compound command in background then wait", %{session: session} do
      result =
        run_script(session, """
        (echo hello && echo world) &
        wait
        echo "after compound"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "after compound"
    end

    test "pipeline in background then wait", %{session: session} do
      result =
        run_script(session, """
        echo data | cat &
        wait
        echo "after pipeline"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "after pipeline"
    end
  end
end
