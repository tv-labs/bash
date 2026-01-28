defmodule Bash.Builtin.DisownTest do
  use Bash.SessionCase, async: false

  @moduletag :tmp_dir
  @moduletag working_dir: :tmp_dir
  @moduletag timeout: 10_000

  alias Bash.OrphanSupervisor
  alias Bash.Session

  setup :start_session

  defp wait_until(fun, timeout_ms, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :done
      else
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(interval_ms)
          :continue
        end
      end
    end)
    |> Enum.find(&(&1 != :continue))
  end

  describe "disown builtin" do
    test "disown removes job from session and adds to orphan supervisor", %{session: session} do
      # Start a long-running background job
      run_script(session, "sleep 10 &")

      # Get the job PID from session state
      state = Session.get_state(session)
      assert map_size(state.jobs) == 1
      [{job_number, job_pid}] = Map.to_list(state.jobs)
      assert is_pid(job_pid)
      assert Process.alive?(job_pid)

      # Verify OrphanSupervisor has no orphans yet
      assert OrphanSupervisor.list_orphans() == []

      # Disown the job
      result = run_script(session, "disown %#{job_number}")
      assert result.exit_code == 0

      # Verify job is removed from session
      state_after = Session.get_state(session)
      assert map_size(state_after.jobs) == 0

      # Verify OrphanSupervisor is now monitoring the job
      orphans = OrphanSupervisor.list_orphans()
      assert job_pid in orphans

      # Verify the job process is still alive
      assert Process.alive?(job_pid)

      # Verify the job process is unlinked from its original supervisor
      # by checking that $ancestors no longer includes the supervisor as linked
      {:links, links} = Process.info(job_pid, :links)
      # The job should have no links to the session's job_supervisor
      # (it may still have links to its own spawned processes like ExCmd)
      refute state.job_supervisor in links

      # Clean up - kill the job
      Process.exit(job_pid, :kill)
    end

    test "disown -a removes all jobs", %{session: session} do
      # Start multiple background jobs
      run_script(session, "sleep 10 &")
      run_script(session, "sleep 10 &")

      state = Session.get_state(session)
      assert map_size(state.jobs) == 2
      job_pids = Map.values(state.jobs)

      # Disown all jobs
      result = run_script(session, "disown -a")
      assert result.exit_code == 0

      # Verify all jobs removed from session
      state_after = Session.get_state(session)
      assert map_size(state_after.jobs) == 0

      # Verify all jobs are now orphans
      orphans = OrphanSupervisor.list_orphans()

      for pid <- job_pids do
        assert pid in orphans
      end

      # Clean up
      for pid <- job_pids, Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end

    test "disowned job is tracked by orphan supervisor and unlinked from session supervisor", %{
      session: session
    } do
      # Start a background job
      run_script(session, "sleep 10 &")

      state = Session.get_state(session)
      [{_job_number, job_pid}] = Map.to_list(state.jobs)
      job_supervisor = state.job_supervisor

      # Verify job is initially linked to the session's job_supervisor
      {:links, initial_links} = Process.info(job_pid, :links)
      assert job_supervisor in initial_links, "Job should be linked to supervisor initially"

      # Disown the job
      run_script(session, "disown")

      # Verify job is orphaned (tracked by OrphanSupervisor)
      assert job_pid in OrphanSupervisor.list_orphans()

      # Verify job is unlinked from the session's job_supervisor
      {:links, links_after_disown} = Process.info(job_pid, :links)

      refute job_supervisor in links_after_disown,
             "Job should be unlinked from supervisor after disown"

      # Verify the job process is still alive (it's a GenServer that stays alive)
      assert Process.alive?(job_pid)

      # Clean up - kill the orphaned job
      Process.exit(job_pid, :kill)

      # Wait for OrphanSupervisor to process the DOWN message
      wait_until(fn -> job_pid not in OrphanSupervisor.list_orphans() end, 1000)
    end

    test "disown with no jobs reports error", %{session: session} do
      result = run_script(session, "disown")

      # Should fail when no current job
      assert result.exit_code == 1
      stderr = get_stderr(result)
      assert stderr =~ "no such job"
    end

    test "disown nonexistent job reports error", %{session: session} do
      result = run_script(session, "disown %99")

      assert result.exit_code == 1
      stderr = get_stderr(result)
      assert stderr =~ "no such job"
    end
  end
end
