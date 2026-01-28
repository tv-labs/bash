defmodule Bash.Builtin.AliasTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "alias" do
    test "defines an alias and can print it", %{session: session} do
      run_script(session, "alias foo='echo bar'")
      result = run_script(session, "alias foo")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "alias foo='echo bar'"
    end

    test "-p lists aliases", %{session: session} do
      run_script(session, "alias foo='echo test'")
      result = run_script(session, "alias -p")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "alias foo='echo test'"
    end

    test "prints a specific alias definition", %{session: session} do
      run_script(session, "alias foo='echo test'")
      result = run_script(session, "alias foo")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "foo"
      assert get_stdout(result) =~ "echo test"
    end

    test "errors for nonexistent alias", %{session: session} do
      result = run_script(session, "alias nonexistent")
      assert result.exit_code == 1
    end
  end
end
