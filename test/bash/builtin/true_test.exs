defmodule Bash.Builtin.TrueTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "true" do
    test "returns exit code 0", %{session: session} do
      result = run_script(session, "true")
      assert result.exit_code == 0
    end

    test "ignores arguments", %{session: session} do
      result = run_script(session, "true some args here")
      assert result.exit_code == 0
    end
  end
end
