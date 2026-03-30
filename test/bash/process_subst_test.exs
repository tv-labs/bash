defmodule Bash.ProcessSubstTest do
  use ExUnit.Case, async: false

  alias Bash.ProcessSubst
  alias Bash.Parser
  alias Bash.Session

  @moduletag :tmp_dir

  describe "ProcessSubst GenServer" do
    test "creates temp file and returns path" do
      {:ok, session} = Session.start_link(id: "proc-subst-test-1")
      state = :sys.get_state(session)

      {:ok, ast} = Parser.parse("echo hello")
      %Bash.Script{statements: [cmd]} = ast

      {:ok, pid, temp_path} =
        ProcessSubst.start_link(
          direction: :input,
          command_ast: cmd,
          session_state: state,
          temp_dir: "/tmp"
        )

      assert is_pid(pid)
      assert is_binary(temp_path)
      assert String.starts_with?(temp_path, "/tmp/runcom_proc_subst_")

      # start_link blocks until the :input worker finishes writing,
      # so the file is ready to read immediately.
      assert {:ok, content} = File.read(temp_path)
      assert content == "hello\n"

      ProcessSubst.stop(pid)
      Session.stop(session)
    end
  end

  describe "word expansion with process substitution" do
    test "expands process substitution to temp file path" do
      {:ok, session} = Session.start_link(id: "proc-subst-test-2")
      state = :sys.get_state(session)

      {:ok, ast} = Parser.parse("cat <(echo hello)")
      %Bash.Script{statements: [cmd]} = ast

      [arg_word] = cmd.args

      expanded = Bash.AST.Helpers.word_to_string(arg_word, state)

      assert is_binary(expanded)
      assert String.starts_with?(expanded, "/tmp/runcom_proc_subst_")

      # start_link blocks until the :input worker finishes writing,
      # so the file is ready immediately after word_to_string returns.
      assert {:ok, content} = File.read(expanded)
      assert content == "hello\n"

      Session.stop(session)
    end
  end

  describe "streaming large data" do
    @tag timeout: 120_000
    test "20MB piped through process substitution produces correct byte count" do
      {:ok, session} = Session.start_link(id: "streaming-test")

      {:ok, ast} = Parser.parse("wc -c <(dd if=/dev/urandom bs=1M count=20 2>/dev/null)")

      result = Session.execute(session, ast)

      assert {:ok, %Bash.Script{} = script} = result
      stdout = Bash.ExecutionResult.stdout(script)
      [count_str | _] = String.split(String.trim(stdout), ~r/\s+/)
      byte_count = String.to_integer(count_str)

      assert byte_count >= 20 * 1024 * 1024,
             "Expected at least 20MB but got #{byte_count} bytes"

      Session.stop(session)
    end

    @tag timeout: 120_000
    test "streaming through session with simple process substitution" do
      {:ok, session} = Session.start_link(id: "simple-stream-test")

      {:ok, ast} = Parser.parse("cat <(echo hello)")

      result = Session.execute(session, ast)

      assert {:ok, %Bash.Script{} = script} = result
      stdout = Bash.ExecutionResult.stdout(script)
      assert stdout == "hello\n"

      Session.stop(session)
    end
  end
end
