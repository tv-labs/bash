defmodule Bash.Builtin.PrintfTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "printf" do
    test "string format", %{session: session} do
      result = run_script(session, ~S|printf "%s\n" hello|)
      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "integer format", %{session: session} do
      result = run_script(session, ~S|printf "%d\n" 42|)
      assert result.exit_code == 0
      assert get_stdout(result) == "42\n"
    end

    test "zero-padded integer", %{session: session} do
      result = run_script(session, ~S|printf "%05d\n" 42|)
      assert result.exit_code == 0
      assert get_stdout(result) == "00042\n"
    end

    test "float precision", %{session: session} do
      result = run_script(session, ~S|printf "%.2f\n" 3.14159|)
      assert result.exit_code == 0
      assert get_stdout(result) == "3.14\n"
    end

    test "multiple string arguments", %{session: session} do
      result = run_script(session, ~S|printf "%s %s\n" hello world|)
      assert result.exit_code == 0
      assert get_stdout(result) == "hello world\n"
    end

    test "assign to variable with -v", %{session: session} do
      result = run_script(session, ~S|printf -v myvar "%s" hello; echo $myvar|)
      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "format repeating for extra arguments", %{session: session} do
      result = run_script(session, ~S|printf "%s\n" a b c|)
      assert result.exit_code == 0
      assert get_stdout(result) == "a\nb\nc\n"
    end

    test "escape sequences", %{session: session} do
      result = run_script(session, ~S|printf "hello\tworld\n"|)
      assert result.exit_code == 0
      assert get_stdout(result) == "hello\tworld\n"
    end
  end
end
