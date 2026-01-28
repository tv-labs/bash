defmodule Bash.Builtin.EnableTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "enable" do
    test "lists builtins", %{session: session} do
      result = run_script(session, "enable | head -3")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "enable"
    end

    test "lists all builtins with -a", %{session: session} do
      result = run_script(session, "enable -a")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert stdout =~ "enable echo"
      assert stdout =~ "enable cd"
    end

    test "returns error for unknown builtin", %{session: session} do
      result =
        run_script(session, ~S"""
        enable nonexistent_builtin_xyz 2>/dev/null; echo $?
        """)

      assert get_stdout(result) =~ "1"
    end
  end
end
