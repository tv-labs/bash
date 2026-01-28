defmodule Bash.Builtin.ColonTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe ":" do
    test "returns exit code 0", %{session: session} do
      result = run_script(session, ":")
      assert result.exit_code == 0
    end

    test "ignores arguments", %{session: session} do
      result = run_script(session, ": some args here")
      assert result.exit_code == 0
    end
  end
end
