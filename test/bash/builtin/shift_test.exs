defmodule Bash.Builtin.ShiftTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "shift" do
    test "shifts positional parameters by 1", %{session: session} do
      result = run_script(session, ~S[set -- a b c; shift; echo "$@"])
      assert result.exit_code == 0
      assert get_stdout(result) == "b c\n"
    end

    test "shifts positional parameters by n", %{session: session} do
      result = run_script(session, ~S[set -- a b c d; shift 2; echo "$@"])
      assert result.exit_code == 0
      assert get_stdout(result) == "c d\n"
    end

    test "errors when shift count exceeds parameters", %{session: session} do
      result = run_script(session, ~S[set -- a; shift 5 2>/dev/null; echo $?])
      assert result.exit_code == 0
      assert get_stdout(result) == "1\n"
    end
  end
end
