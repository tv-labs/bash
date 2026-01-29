defmodule Bash.BackgroundTest do
  use Bash.SessionCase, async: false

  @moduletag :tmp_dir
  @moduletag working_dir: :tmp_dir

  alias Bash.AST.Command
  alias Bash.AST.Compound
  alias Bash.Job
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session

  setup :start_session

  describe "parser" do
    test "parses simple background command" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello &")

      assert %Compound{
               kind: :operand,
               statements: [%Command{}, {:operator, :bg}]
             } = ast
    end

    test "parses compound with background" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo one && echo two &")

      assert %Compound{
               kind: :operand,
               statements: [
                 %Command{},
                 {:operator, :and},
                 %Command{},
                 {:operator, :bg}
               ]
             } = ast
    end

    test "serializes background operator round-trip" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello &")
      serialized = to_string(ast)
      assert serialized == "echo hello &"
    end
  end

  describe "background execution" do
    test "background command returns job number", %{session: session} do
      result = run_script(session, "sleep 0.1 &")

      assert result.exit_code == 0
      assert session_stderr(session) =~ ~r/\[1\]/
    end

    test "multiple background jobs get sequential numbers", %{session: session} do
      run_script(session, "sleep 0.1 &")
      output1 = session_stderr(session)
      flush_session_output(session)

      run_script(session, "sleep 0.1 &")
      output2 = session_stderr(session)

      assert output1 =~ "[1]"
      assert output2 =~ "[2]"
    end
  end

  describe "kill builtin" do
  end

  describe "job tracking" do
    test "jobs are removed after completion", %{session: session} do
      run_script(session, "echo done &")

      # Wait for job to complete
      Process.sleep(100)

      jobs = Session.list_jobs(session)
      assert Enum.empty?(jobs)
    end

    test "completed jobs appear in notifications", %{session: session} do
      run_script(session, "echo done &")

      # Wait for job to complete
      Process.sleep(100)

      completed = Session.pop_completed_jobs(session)
      assert length(completed) == 1
      assert hd(completed).status == :done
    end

    test "current_job tracks most recent background job", %{session: session} do
      run_script(session, "sleep 0.5 &")
      run_script(session, "sleep 0.5 &")

      state = Session.get_state(session)
      assert state.current_job == 2
      assert state.previous_job == 1
    end
  end

  describe "integration: compare with real bash" do
    # These tests validate our implementation against real bash behavior

    test "background operator parsing matches bash", %{session: session} do
      # Real bash parses "echo foo &" as a background command
      # Verify our parser produces equivalent AST
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo foo &")
      assert %Compound{kind: :operand} = ast
      assert {:operator, :bg} = List.last(ast.statements)

      # Run in our session and verify it returns immediately
      result = run_script(session, "echo foo &")
      assert result.exit_code == 0
      # Job number like bash (notification goes to stderr)
      assert session_stderr(session) =~ "[1]"
    end

    test "jobs output format similar to bash", %{session: session} do
      # Start a background job
      run_script(session, "sleep 1 &")

      result = run_script(session, "jobs")

      # Bash jobs output format: [N]+ Status Command
      # Example: [1]+  Running                 sleep 1 &
      output = get_stdout(result)
      # Job number in brackets
      assert output =~ ~r/\[1\]/
      # Status
      assert output =~ ~r/Running/
      # Command name
      assert output =~ ~r/sleep/
    end

    test "wait returns correct exit code like bash", %{session: session} do
      # In bash: "bash -c 'exit 5' &; wait; echo $?" prints "5"
      run_script(session, "bash -c 'exit 5' &")

      result = run_script(session, "wait")

      # Wait should return the exit code of the waited job
      assert result.exit_code == 5
    end

    test "kill sends SIGTERM by default like bash", %{session: session} do
      # In bash, kill without signal sends SIGTERM (15)
      run_script(session, "sleep 10 &")
      Process.sleep(50)

      run_script(session, "kill %1")

      # Wait for the killed job - should exit with signal code
      result = run_script(session, "wait")

      # Process killed by SIGTERM typically exits with 128+15=143 or just 15
      assert result.exit_code in [15, 143]
    end

    test "fg returns job's output like bash", %{session: session} do
      # In bash, fg waits for job and returns its exit code
      run_script(session, "bash -c 'echo hello; exit 7' &")
      flush_session_output(session)

      result = run_script(session, "fg")

      # fg should return the job's exit code
      assert result.exit_code == 7
      # Should contain job's output
      assert session_stdout(session) =~ "hello"
    end

    test "multiple background jobs like bash", %{session: session} do
      # In bash, multiple & creates multiple jobs with sequential numbers
      run_script(session, "sleep 0.5 &")
      output1 = session_stderr(session)
      flush_session_output(session)

      run_script(session, "sleep 0.5 &")
      output2 = session_stderr(session)
      flush_session_output(session)

      run_script(session, "sleep 0.5 &")
      output3 = session_stderr(session)
      flush_session_output(session)

      # Each should get a sequential job number (notification goes to stderr)
      assert output1 =~ "[1]"
      assert output2 =~ "[2]"
      assert output3 =~ "[3]"

      # Jobs should list all three
      jobs_result = run_script(session, "jobs")
      jobs_output = get_stdout(jobs_result)
      assert jobs_output =~ "[1]"
      assert jobs_output =~ "[2]"
      assert jobs_output =~ "[3]"
    end

    test "current/previous job tracking like bash", %{session: session} do
      # In bash, %% and %+ refer to current job, %- to previous
      run_script(session, "sleep 0.5 &")
      run_script(session, "sleep 0.5 &")

      result = run_script(session, "jobs")

      # Job 2 should be current (+), job 1 should be previous (-)
      output = get_stdout(result)
      # Current job marker
      assert output =~ ~r/\[2\]\+/
      # Previous job marker
      assert output =~ ~r/\[1\]-/
    end

    test "compound command with background like bash", %{session: session} do
      # In bash, "echo a && echo b &" backgrounds the whole compound
      result = run_script(session, "echo first && echo second &")

      # Should return immediately with job number
      assert result.exit_code == 0
      assert session_stderr(session) =~ "[1]"

      # Wait for it to complete and check the job ran both commands
      Process.sleep(100)
      completed = Session.pop_completed_jobs(session)
      assert length(completed) == 1

      # Output is streamed to session's output collector, not accumulated in job
      stdout_text = session_stdout(session)
      assert stdout_text =~ "first"
      assert stdout_text =~ "second"
    end
  end

  describe "Job struct" do
    test "new/1 creates job with defaults" do
      job = Job.new(job_number: 1, command: "sleep 10")

      assert job.job_number == 1
      assert job.command == "sleep 10"
      assert job.status == :running
      assert job.exit_code == nil
    end

    test "complete/2 updates job status and exit code" do
      job = Job.new(job_number: 1, command: "test")
      completed = Job.complete(job, 0)

      assert completed.status == :done
      assert completed.exit_code == 0
      assert completed.completed_at
    end

    test "stop/1 and resume/1 update status" do
      job = Job.new(job_number: 1, command: "test")

      stopped = Job.stop(job)
      assert stopped.status == :stopped

      resumed = Job.resume(stopped)
      assert resumed.status == :running
    end
  end

  describe "background echo output capture" do
    test "echo c & echo d produces both c and d", %{session: session} do
      result =
        run_script(session, """
        echo c & echo d
        wait
        """)

      stdout = get_stdout(result)
      assert stdout =~ "c"
      assert stdout =~ "d"
    end
  end
end
