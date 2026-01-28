defmodule Bash.Builtin.LetTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "let" do
    test "assigns a variable", %{session: session} do
      result = run_script(session, ~S[let x=5; echo $x])
      assert result.exit_code == 0
      assert get_stdout(result) == "5\n"
    end

    test "evaluates arithmetic expressions", %{session: session} do
      result = run_script(session, ~S[let "x=2+3"; echo $x])
      assert result.exit_code == 0
      assert get_stdout(result) == "5\n"
    end

    test "returns exit code 1 for zero result", %{session: session} do
      result = run_script(session, ~S[let "0"; echo $?])
      assert result.exit_code == 0
      assert get_stdout(result) == "1\n"
    end

    test "returns exit code 0 for nonzero result", %{session: session} do
      result = run_script(session, ~S[let "1"; echo $?])
      assert result.exit_code == 0
      assert get_stdout(result) == "0\n"
    end

    test "handles multiple expressions", %{session: session} do
      result = run_script(session, ~S[let "x=3" "y=4"; echo "$x $y"])
      assert result.exit_code == 0
      assert get_stdout(result) == "3 4\n"
    end
  end
end
