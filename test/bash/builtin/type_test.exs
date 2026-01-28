defmodule Bash.Builtin.TypeTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "type" do
    test "identifies a builtin", %{session: session} do
      result = run_script(session, "type echo")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "builtin"
    end

    test "-t outputs the type word", %{session: session} do
      result = run_script(session, "type -t echo")
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() == "builtin"
    end

    test "errors for nonexistent command", %{session: session} do
      result = run_script(session, "type nonexistent_command_xyz")
      assert result.exit_code == 1
    end

    test "identifies a function", %{session: session} do
      result = run_script(session, "f() { echo hi; }; type f")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "function"
    end
  end
end
