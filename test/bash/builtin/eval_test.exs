defmodule Bash.Builtin.EvalTest do
  @moduledoc """
  Unit tests for the Eval builtin.
  """
  use Bash.SessionCase, async: true

  alias Bash.Builtin.Eval
  alias Bash.CommandResult
  alias Bash.Session

  @session_state %{
    variables: %{},
    functions: %{},
    working_dir: "/tmp"
  }

  describe "basic eval" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_basic_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "executes a simple echo command", %{session: session} do
      result = run_script(session, "eval 'echo hello'")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "executes command with multiple arguments", %{session: session} do
      # eval "echo" "hello" "world" -> echo hello world
      result = run_script(session, "eval echo hello world")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello world\n"
    end

    test "returns exit code 0 for empty arguments" do
      assert {:ok, %CommandResult{exit_code: 0}} =
               Eval.execute([], nil, @session_state)
    end

    test "returns exit code 0 for whitespace-only arguments" do
      assert {:ok, %CommandResult{exit_code: 0}} =
               Eval.execute(["   "], nil, @session_state)
    end

    test "returns exit code 0 for empty string argument" do
      assert {:ok, %CommandResult{exit_code: 0}} =
               Eval.execute([""], nil, @session_state)
    end
  end

  describe "variable assignment" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_var_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "assigns a variable", %{session: session} do
      result = run_script(session, "eval 'x=5'")
      assert result.exit_code == 0

      # Check variable was set by echoing it
      result2 = run_script(session, "echo $x")
      assert get_stdout(result2) == "5\n"
    end

    test "assigns and uses a variable in multiple commands", %{session: session} do
      result = run_script(session, "eval 'x=hello; echo $x'")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end
  end

  describe "exit code propagation" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_exit_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "returns the exit code of false", %{session: session} do
      result = run_script(session, "eval false")
      assert result.exit_code == 1
    end

    test "returns the exit code of true", %{session: session} do
      result = run_script(session, "eval true")
      assert result.exit_code == 0
    end

    test "returns exit code of last command in sequence", %{session: session} do
      result1 = run_script(session, "eval 'false; true'")
      assert result1.exit_code == 0

      result2 = run_script(session, "eval 'true; false'")
      assert result2.exit_code == 1
    end
  end

  describe "uses session context" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_ctx_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "can reference existing variables", %{session: session} do
      # Set a variable first
      run_script(session, "greeting=hello")

      result = run_script(session, "eval 'echo $greeting'")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "variable updates persist", %{session: session} do
      run_script(session, "eval 'name=world'")

      result = run_script(session, "echo $name")
      assert get_stdout(result) == "world\n"
    end
  end

  describe "parse errors" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_parse_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "returns error for unclosed quote", %{session: session} do
      result = run_script(session, "eval 'echo \"hello'")

      assert result.exit_code == 1
      stderr = get_stderr(result)
      assert stderr =~ "eval:"
    end
  end

  describe "complex commands" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_complex_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "executes arithmetic expansion", %{session: session} do
      result = run_script(session, "eval 'echo $((2 + 3))'")

      assert result.exit_code == 0
      assert get_stdout(result) == "5\n"
    end

    test "executes conditionals", %{session: session} do
      result = run_script(session, "eval 'if true; then echo yes; fi'")

      assert result.exit_code == 0
      assert get_stdout(result) == "yes\n"
    end

    test "executes loops", %{session: session} do
      result = run_script(session, "eval 'for i in 1 2 3; do echo $i; done'")

      assert result.exit_code == 0
      assert get_stdout(result) == "1\n2\n3\n"
    end
  end

  describe "concatenation behavior" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_concat_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "concatenates multiple arguments with spaces", %{session: session} do
      # eval "echo" "hello" should become "echo hello"
      result = run_script(session, "eval echo hello")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "handles arguments with internal spaces", %{session: session} do
      # eval "echo hello world" should output "hello world"
      result = run_script(session, "eval 'echo hello world'")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello world\n"
    end
  end

  describe "bash compatibility" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_bash_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "matches bash behavior for simple echo", %{session: session} do
      {bash_output, 0} = System.cmd("bash", ["-c", "eval 'echo hello world'"])

      result = run_script(session, "eval 'echo hello world'")

      assert result.exit_code == 0
      assert get_stdout(result) == bash_output
    end

    test "matches bash behavior for variable assignment and echo", %{session: session} do
      {bash_output, 0} = System.cmd("bash", ["-c", "eval 'x=5; echo $x'"])

      result = run_script(session, "eval 'x=5; echo $x'")

      assert result.exit_code == 0
      assert get_stdout(result) == bash_output
    end

    test "matches bash behavior for exit code of false", %{session: session} do
      {bash_output, _bash_exit_code} = System.cmd("bash", ["-c", "eval 'false'; echo $?"])

      result = run_script(session, "eval false")

      # bash echo $? shows 1, so we verify our exit code is 1
      assert result.exit_code == 1
      assert String.trim(bash_output) == "1"
    end

    test "matches bash behavior for empty eval" do
      {bash_output, _bash_exit_code} = System.cmd("bash", ["-c", "eval ''; echo $?"])

      assert {:ok, %CommandResult{exit_code: 0}} =
               Eval.execute([""], nil, @session_state)

      assert String.trim(bash_output) == "0"
    end
  end

  describe "nested eval" do
    setup do
      {:ok, session} = Session.start_link(id: "eval_nested_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "can execute nested eval", %{session: session} do
      result = run_script(session, "eval 'eval echo hello'")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end
  end
end
