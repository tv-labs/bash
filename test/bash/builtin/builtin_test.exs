defmodule Bash.Builtin.BuiltinTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "builtin" do
    test "builtin echo outputs text", %{session: session} do
      result = run_script(session, "builtin echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "bypasses function override", %{session: session} do
      result = run_script(session, ~s|echo() { command echo "wrapped: $1"; }; builtin echo hi|)
      assert get_stdout(result) == "hi\n"
    end

    test "nonexistent builtin produces error", %{session: session} do
      result = run_script(session, "builtin nonexistent_builtin")
      assert result.exit_code != 0
      assert get_stderr(result) =~ "nonexistent_builtin"
    end
  end
end
