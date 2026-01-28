defmodule Bash.Builtin.ReturnTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "return" do
    test "returns specified exit code from function", %{session: session} do
      result = run_script(session, "f() { return 42; }; f; echo $?")
      assert get_stdout(result) == "42\n"
    end

    test "return with no arg defaults to 0", %{session: session} do
      result = run_script(session, "f() { return; }; f; echo $?")
      assert get_stdout(result) == "0\n"
    end

    test "return outside function produces error", %{session: session} do
      result = run_script(session, "return")
      assert get_stderr(result) =~ "return"
    end
  end
end
