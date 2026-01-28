defmodule Bash.Builtin.ExitTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "exit" do
    test "exit 0 returns 0", %{session: session} do
      result = run_script(session, "exit 0")
      assert result.exit_code == 0
    end

    test "exit 42 returns 42", %{session: session} do
      result = run_script(session, "exit 42")
      assert result.exit_code == 42
    end

    test "exit 256 wraps to 0 via modulo 256", %{session: session} do
      result = run_script(session, "exit 256")
      assert result.exit_code == 0
    end

    test "no arg defaults to 0 when no prior exit code", %{session: session} do
      result = run_script(session, "exit")
      assert result.exit_code == 0
    end
  end
end
