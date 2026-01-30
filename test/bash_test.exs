defmodule BashTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  import Bash.Sigil

  setup :start_session

  test "runs a simple command", %{session: session} do
    {:ok, result, _session} = Bash.run(~BASH"echo hello", session)
    assert Bash.ExecutionResult.stdout(result) == "hello\n"
  end

  describe "pipe chaining" do
    test "chains multiple runs with |>", %{session: session} do
      result =
        Bash.run("x=hello", session)
        |> Bash.run("echo $x")

      assert Bash.stdout(result) == "hello\n"
    end

    test "chains three commands preserving session state", %{session: session} do
      result =
        Bash.run("a=1", session)
        |> Bash.run("b=2")
        |> Bash.run("echo $a $b")

      assert Bash.stdout(result) == "1 2\n"
    end
  end

  describe "stdout/stderr/output helpers" do
    test "stdout extracts standard output", %{session: session} do
      assert Bash.run("echo out", session) |> Bash.stdout() == "out\n"
    end

    test "stderr extracts standard error", %{session: session} do
      assert Bash.run("echo err >&2", session) |> Bash.stderr() == "err\n"
    end

    test "output combines stdout and stderr", %{session: session} do
      output = Bash.run("echo out; echo err >&2", session) |> Bash.output()
      assert output =~ "out"
      assert output =~ "err"
    end

    test "stdout from session pid accumulates across runs", %{session: session} do
      Bash.run("echo first", session)
      Bash.run("echo second", session)
      assert Bash.stdout(session) =~ "first"
      assert Bash.stdout(session) =~ "second"
    end
  end

  describe "exit_code and success?" do
    test "successful command returns exit code 0", %{session: session} do
      assert Bash.run("true", session) |> Bash.exit_code() == 0
    end

    test "failed command returns non-zero exit code", %{session: session} do
      assert Bash.run("false", session) |> Bash.exit_code() == 1
    end

    test "exit with explicit code", %{session: session} do
      assert Bash.run("exit 42", session) |> Bash.exit_code() == 42
    end

    test "success? returns true for exit code 0", %{session: session} do
      assert Bash.run("true", session) |> Bash.success?()
    end

    test "success? returns false for non-zero exit", %{session: session} do
      refute Bash.run("false", session) |> Bash.success?()
    end
  end

  describe "with_session/1" do
    test "creates and stops session automatically" do
      output =
        Bash.with_session(fn session ->
          {:ok, result, _} = Bash.run("echo managed", session)
          Bash.stdout(result)
        end)

      assert output == "managed\n"
    end

    test "with_session/2 accepts options" do
      output =
        Bash.with_session([env: %{"GREETING" => "hi"}], fn session ->
          Bash.run("echo $GREETING", session) |> Bash.stdout()
        end)

      assert output == "hi\n"
    end
  end

  describe "environment variables" do
    test "session env is available to scripts", %{session: session} do
      Session.set_env(session, "MY_VAR", "my_value")
      assert Bash.run("echo $MY_VAR", session) |> Bash.stdout() == "my_value\n"
    end

    test "env option sets initial environment" do
      {:ok, result, _} = Bash.run("echo $WHO", env: %{"WHO" => "world"})
      assert Bash.stdout(result) == "world\n"
    end

    test "export makes variable available in subshells", %{session: session} do
      result =
        Bash.run("export FOO=bar", session)
        |> Bash.run("echo $FOO")

      assert Bash.stdout(result) == "bar\n"
    end
  end

  describe "multi-line scripts" do
    test "variable assignment and expansion", %{session: session} do
      script = """
      name="world"
      greeting="hello $name"
      echo $greeting
      """

      assert Bash.run(script, session) |> Bash.stdout() == "hello world\n"
    end

    test "conditional execution", %{session: session} do
      script = """
      x=5
      if [ $x -eq 5 ]; then
        echo "five"
      else
        echo "not five"
      fi
      """

      assert Bash.run(script, session) |> Bash.stdout() == "five\n"
    end

    test "for loop", %{session: session} do
      script = """
      for i in a b c; do
        echo $i
      done
      """

      assert Bash.run(script, session) |> Bash.stdout() == "a\nb\nc\n"
    end

    test "while loop with counter", %{session: session} do
      script = """
      i=0
      while [ $i -lt 3 ]; do
        echo $i
        i=$((i + 1))
      done
      """

      assert Bash.run(script, session) |> Bash.stdout() == "0\n1\n2\n"
    end

    test "case statement", %{session: session} do
      script = """
      fruit=apple
      case $fruit in
        apple) echo "red" ;;
        banana) echo "yellow" ;;
        *) echo "unknown" ;;
      esac
      """

      assert Bash.run(script, session) |> Bash.stdout() == "red\n"
    end

    test "function definition and call", %{session: session} do
      script = """
      greet() {
        echo "hello $1"
      }
      greet world
      """

      assert Bash.run(script, session) |> Bash.stdout() == "hello world\n"
    end

    test "command substitution", %{session: session} do
      script = """
      result=$(echo works)
      echo "it $result"
      """

      assert Bash.run(script, session) |> Bash.stdout() == "it works\n"
    end

    test "arithmetic expansion", %{session: session} do
      script = """
      a=3
      b=4
      echo $((a + b))
      """

      assert Bash.run(script, session) |> Bash.stdout() == "7\n"
    end
  end

  describe "pipelines" do
    test "simple pipe", %{session: session} do
      stdout = Bash.run("echo hello | cat", session) |> Bash.stdout()
      assert stdout == "hello\n"
    end

    test "multi-stage pipe", %{session: session} do
      stdout = Bash.run("echo hello | cat | cat", session) |> Bash.stdout()
      assert stdout == "hello\n"
    end

    test "pipe with grep", %{session: session} do
      script = "echo -e 'foo\nbar\nbaz' | grep bar"
      assert Bash.run(script, session) |> Bash.stdout() == "bar\n"
    end
  end

  describe "logical operators" do
    test "&& executes second on success", %{session: session} do
      assert Bash.run("true && echo yes", session) |> Bash.stdout() == "yes\n"
    end

    test "&& skips second on failure", %{session: session} do
      assert Bash.run("false && echo yes", session) |> Bash.stdout() == ""
    end

    test "|| executes second on failure", %{session: session} do
      assert Bash.run("false || echo fallback", session) |> Bash.stdout() == "fallback\n"
    end

    test "|| skips second on success", %{session: session} do
      assert Bash.run("true || echo fallback", session) |> Bash.stdout() == ""
    end
  end

  describe "redirections" do
    @tag :tmp_dir
    test "redirect stdout to file", %{session: session, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "out.txt")
      Bash.run("echo hello > #{file}", session)
      assert File.read!(file) == "hello\n"
    end

    @tag :tmp_dir
    test "append to file", %{session: session, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "out.txt")
      Bash.run("echo first > #{file}", session)
      Bash.run("echo second >> #{file}", session)
      assert File.read!(file) == "first\nsecond\n"
    end

    @tag :tmp_dir
    test "redirect stdin from file", %{session: session, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "in.txt")
      File.write!(file, "from file\n")
      assert Bash.run("cat < #{file}", session) |> Bash.stdout() == "from file\n"
    end
  end

  describe "error handling" do
    test "syntax error returns error tuple" do
      {:error, result, nil} = Bash.run("if then")
      assert result.exit_code == 1
    end

    test "command not found returns exit code 127", %{session: session} do
      result = Bash.run("nonexistent_cmd_xyz", session)
      assert Bash.exit_code(result) == 127
    end
  end

  describe "parse and validate" do
    test "parse returns AST for valid script" do
      assert {:ok, %Bash.Script{}} = Bash.parse("echo hello")
    end

    test "parse returns error for invalid script" do
      assert {:error, %Bash.SyntaxError{}} = Bash.parse("if then")
    end

    test "validate returns :ok for valid script" do
      assert :ok = Bash.validate("echo hello")
    end

    test "validate returns error for invalid script" do
      assert {:error, %Bash.SyntaxError{}} = Bash.validate("if then")
    end
  end

  describe "sigil" do
    test "~BASH sigil produces AST at compile time" do
      ast = ~BASH"echo hello"
      assert %Bash.Script{} = ast
    end

    test "~BASH sigil AST can be executed", %{session: session} do
      {:ok, result, _} = Bash.run(~BASH"echo from_sigil", session)
      assert Bash.stdout(result) == "from_sigil\n"
    end
  end
end
