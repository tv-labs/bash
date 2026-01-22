defmodule Bash.UnifiedStreamsTest do
  use ExUnit.Case, async: true

  alias Bash.Session
  alias Bash.Execution

  describe "Execution struct" do
    test "new/1 creates execution with StringIO streams" do
      {:ok, exec} = Execution.new("echo hello")

      assert exec.command == "echo hello"
      assert is_pid(exec.stdout)
      assert is_pid(exec.stderr)
      assert is_nil(exec.exit_code)
      assert %DateTime{} = exec.started_at
      assert is_nil(exec.completed_at)
    end

    test "complete/2 sets exit code and timestamp" do
      {:ok, exec} = Execution.new("test")
      completed = Execution.complete(exec, 0)

      assert completed.exit_code == 0
      assert %DateTime{} = completed.completed_at
    end

    test "stdout_contents/1 returns written output" do
      {:ok, exec} = Execution.new("test")
      IO.write(exec.stdout, "hello\n")

      assert Execution.stdout_contents(exec) == "hello\n"
    end

    test "stderr_contents/1 returns written errors" do
      {:ok, exec} = Execution.new("test")
      IO.write(exec.stderr, "error!\n")

      assert Execution.stderr_contents(exec) == "error!\n"
    end

    test "close/1 closes StringIO devices" do
      {:ok, exec} = Execution.new("test")
      assert :ok = Execution.close(exec)
    end
  end

  describe "Session read helpers" do
    test "read/3 reads from stdin StringIO" do
      session = %Session{stdin: nil}
      {:ok, stdin} = StringIO.open("line1\nline2\n")
      session = %{session | stdin: stdin}

      assert {:ok, "line1\n"} = Session.read(session, :stdin, :line)
      assert {:ok, "line2\n"} = Session.read(session, :stdin, :line)
      assert :eof = Session.read(session, :stdin, :line)
    end

    test "read/3 returns :eof when stdin is nil" do
      session = %Session{stdin: nil}
      assert :eof = Session.read(session, :stdin, :line)
    end

    test "read/3 reads all content with :all mode" do
      session = %Session{stdin: nil}
      {:ok, stdin} = StringIO.open("line1\nline2\n")
      session = %{session | stdin: stdin}

      assert {:ok, "line1\nline2\n"} = Session.read(session, :stdin, :all)
    end

    test "read/3 reads from file descriptor" do
      {:ok, fd_device} = StringIO.open("fd content\n")
      session = %Session{stdin: nil, file_descriptors: %{3 => fd_device}}

      assert {:ok, "fd content\n"} = Session.read(session, {:fd, 3}, :line)
    end

    test "read/3 returns error for bad file descriptor" do
      session = %Session{stdin: nil, file_descriptors: %{}}

      assert {:error, "3: Bad file descriptor"} = Session.read(session, {:fd, 3}, :line)
    end

    test "read/3 returns error for fd 1 and 2 (stdout/stderr not readable)" do
      session = %Session{stdin: nil, file_descriptors: %{}}

      assert {:error, "1: Bad file descriptor"} = Session.read(session, {:fd, 1}, :line)
      assert {:error, "2: Bad file descriptor"} = Session.read(session, {:fd, 2}, :line)
    end

    test "read/3 with {:fd, 0} reads from stdin" do
      session = %Session{stdin: nil}
      {:ok, stdin} = StringIO.open("from stdin\n")
      session = %{session | stdin: stdin}

      assert {:ok, "from stdin\n"} = Session.read(session, {:fd, 0}, :line)
    end

    test "gets/1 is convenience wrapper for read line" do
      session = %Session{stdin: nil}
      {:ok, stdin} = StringIO.open("test line\n")
      session = %{session | stdin: stdin}

      assert {:ok, "test line\n"} = Session.gets(session)
    end
  end

  describe "Session write helpers" do
    test "write/3 writes to current execution's stdout" do
      {:ok, exec} = Execution.new("test")
      session = %Session{current: exec, is_pipeline_tail: true}

      _session = Session.write(session, :stdout, "hello")
      assert Execution.stdout_contents(exec) == "hello"
    end

    test "write/3 writes to current execution's stderr" do
      {:ok, exec} = Execution.new("test")
      session = %Session{current: exec, is_pipeline_tail: true}

      _session = Session.write(session, :stderr, "error")
      assert Execution.stderr_contents(exec) == "error"
    end

    test "write/3 does nothing when current is nil" do
      session = %Session{current: nil}
      session = Session.write(session, :stdout, "ignored")
      assert session.current == nil
    end

    test "write/3 forwards to user sink when pipeline tail" do
      test_pid = self()
      sink = fn chunk -> send(test_pid, chunk) end

      {:ok, exec} = Execution.new("test")

      session = %Session{
        current: exec,
        is_pipeline_tail: true,
        stdout_sink: sink
      }

      Session.write(session, :stdout, "hello")

      assert_received {:stdout, "hello"}
    end

    test "write/3 does NOT forward to user sink when not pipeline tail" do
      test_pid = self()
      sink = fn chunk -> send(test_pid, chunk) end

      {:ok, exec} = Execution.new("test")

      session = %Session{
        current: exec,
        is_pipeline_tail: false,
        stdout_sink: sink
      }

      Session.write(session, :stdout, "hello")

      refute_received {:stdout, _}
      # But still written to execution stream
      assert Execution.stdout_contents(exec) == "hello"
    end

    test "puts/2 appends newline" do
      {:ok, exec} = Execution.new("test")
      session = %Session{current: exec, is_pipeline_tail: true}

      Session.puts(session, "hello")
      assert Execution.stdout_contents(exec) == "hello\n"
    end

    test "write/3 to {:fd, 1} writes to stdout" do
      {:ok, exec} = Execution.new("test")
      session = %Session{current: exec, is_pipeline_tail: true}

      Session.write(session, {:fd, 1}, "via fd")
      assert Execution.stdout_contents(exec) == "via fd"
    end

    test "write/3 to {:fd, 2} writes to stderr" do
      {:ok, exec} = Execution.new("test")
      session = %Session{current: exec, is_pipeline_tail: true}

      Session.write(session, {:fd, 2}, "via fd")
      assert Execution.stderr_contents(exec) == "via fd"
    end
  end

  describe "Execution lifecycle" do
    test "begin_execution/2 creates new execution with fresh streams" do
      session = %Session{}
      session = Session.begin_execution(session, "echo hello")

      assert session.current != nil
      assert session.current.command == "echo hello"
      assert is_pid(session.current.stdout)
      assert is_pid(session.current.stderr)
      assert session.is_pipeline_tail == true
    end

    test "begin_execution/3 with pipeline_tail: false" do
      session = %Session{}
      session = Session.begin_execution(session, "cat", pipeline_tail: false)

      assert session.is_pipeline_tail == false
    end

    test "end_execution/2 completes current and moves to executions" do
      session = %Session{executions: []}
      session = Session.begin_execution(session, "echo 1")
      Session.puts(session, "1")
      session = Session.end_execution(session, exit_code: 0)

      assert session.current == nil
      assert length(session.executions) == 1
      assert hd(session.executions).exit_code == 0
    end

    test "end_execution/2 does nothing when current is nil" do
      session = %Session{current: nil, executions: []}
      session = Session.end_execution(session, exit_code: 0)

      assert session.executions == []
    end
  end

  describe "pipe_forward/1" do
    test "wires previous stdout to stdin" do
      session = %Session{executions: []}

      # First command writes to stdout
      session = Session.begin_execution(session, "echo hello")
      Session.write(session, :stdout, "hello\n")
      session = Session.end_execution(session, exit_code: 0)

      # Pipe forward
      session = Session.pipe_forward(session)

      # Read from stdin should get previous stdout
      assert {:ok, "hello\n"} = Session.read(session, :stdin, :all)
    end

    test "pipe_forward/1 does nothing when no executions" do
      session = %Session{executions: [], stdin: nil}
      session = Session.pipe_forward(session)

      assert session.stdin == nil
    end
  end

  describe "open_stdin/2" do
    test "creates StringIO for stdin from string" do
      session = %Session{stdin: nil}
      session = Session.open_stdin(session, "input data\n")

      assert is_pid(session.stdin)
      assert {:ok, "input data\n"} = Session.read(session, :stdin, :all)
    end
  end

  describe "stdout/2 and stderr/2 accessors" do
    test "stdout/1 streams all executions' stdout" do
      session = %Session{executions: []}

      session = Session.begin_execution(session, "echo 1")
      Session.write(session, :stdout, "1\n")
      session = Session.end_execution(session, exit_code: 0)

      session = Session.begin_execution(session, "echo 2")
      Session.write(session, :stdout, "2\n")
      session = Session.end_execution(session, exit_code: 0)

      assert Session.stdout(session) |> Enum.to_list() == ["1\n", "2\n"]
    end

    test "stdout/2 with index returns specific execution" do
      session = %Session{executions: []}

      session = Session.begin_execution(session, "echo 1")
      Session.write(session, :stdout, "first\n")
      session = Session.end_execution(session, exit_code: 0)

      session = Session.begin_execution(session, "echo 2")
      Session.write(session, :stdout, "second\n")
      session = Session.end_execution(session, exit_code: 0)

      assert Session.stdout(session, index: 0) == "first\n"
      assert Session.stdout(session, index: 1) == "second\n"
      assert Session.stdout(session, index: 2) == ""
    end

    test "stderr/2 works similarly" do
      session = %Session{executions: []}

      session = Session.begin_execution(session, "cmd")
      Session.write(session, :stderr, "error\n")
      session = Session.end_execution(session, exit_code: 1)

      assert Session.stderr(session, index: 0) == "error\n"
    end
  end

  describe "execution/2 accessor" do
    test "returns execution at index" do
      session = %Session{executions: []}

      session = Session.begin_execution(session, "cmd1")
      session = Session.end_execution(session, exit_code: 0)

      session = Session.begin_execution(session, "cmd2")
      session = Session.end_execution(session, exit_code: 1)

      exec0 = Session.execution(session, 0)
      assert exec0.command == "cmd1"
      assert exec0.exit_code == 0

      exec1 = Session.execution(session, 1)
      assert exec1.command == "cmd2"
      assert exec1.exit_code == 1

      assert Session.execution(session, 2) == nil
    end
  end

  describe "pipeline wiring integration" do
    test "simulates cat | tr pipeline" do
      session = %Session{executions: []}
      session = Session.open_stdin(session, "hello\n")

      # cmd1: cat (reads stdin, writes stdout)
      session = Session.begin_execution(session, "cat", pipeline_tail: false)
      {:ok, data} = Session.read(session, :stdin, :all)
      Session.write(session, :stdout, data)
      session = Session.end_execution(session, exit_code: 0)

      # Wire stdout -> stdin
      session = Session.pipe_forward(session)

      # cmd2: tr a-z A-Z (uppercase)
      session = Session.begin_execution(session, "tr a-z A-Z", pipeline_tail: true)
      {:ok, data} = Session.read(session, :stdin, :all)
      Session.write(session, :stdout, String.upcase(data))
      session = Session.end_execution(session, exit_code: 0)

      assert Session.stdout(session, index: 0) == "hello\n"
      assert Session.stdout(session, index: 1) == "HELLO\n"
    end

    test "user sink receives only pipeline tail output" do
      test_pid = self()
      sink = fn chunk -> send(test_pid, chunk) end

      session = %Session{executions: [], stdout_sink: sink}
      session = Session.open_stdin(session, "input\n")

      # Non-tail command
      session = Session.begin_execution(session, "cmd1", pipeline_tail: false)
      Session.puts(session, "intermediate")
      session = Session.end_execution(session, exit_code: 0)

      refute_received {:stdout, _}

      session = Session.pipe_forward(session)

      # Tail command
      session = Session.begin_execution(session, "cmd2", pipeline_tail: true)
      Session.puts(session, "final")
      _session = Session.end_execution(session, exit_code: 0)

      assert_received {:stdout, ["final", "\n"]}
    end
  end
end
