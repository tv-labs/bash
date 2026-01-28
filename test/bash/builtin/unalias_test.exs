defmodule Bash.Builtin.UnaliasTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "unalias" do
    test "removes a defined alias", %{session: session} do
      run_script(session, "alias foo='echo test'")
      run_script(session, "unalias foo")
      result = run_script(session, "foo")
      assert result.exit_code != 0
    end

    test "-a removes all aliases", %{session: session} do
      run_script(session, "alias a='echo 1'; alias b='echo 2'")
      run_script(session, "unalias -a")
      result = run_script(session, "alias -p")
      assert get_stdout(result) == ""
    end

    test "errors for nonexistent alias", %{session: session} do
      result = run_script(session, "unalias nonexistent")
      assert result.exit_code == 1
    end
  end
end
