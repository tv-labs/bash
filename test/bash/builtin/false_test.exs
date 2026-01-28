defmodule Bash.Builtin.FalseTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "false" do
    test "returns exit code 1", %{session: session} do
      result = run_script(session, "false")
      assert result.exit_code == 1
    end

    test "ignores arguments", %{session: session} do
      result = run_script(session, "false some args here")
      assert result.exit_code == 1
    end
  end
end
