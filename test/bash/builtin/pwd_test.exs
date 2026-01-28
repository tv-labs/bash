defmodule Bash.Builtin.PwdTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "pwd" do
    test "outputs a path starting with /", %{session: session} do
      result = run_script(session, "pwd")
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() |> String.starts_with?("/")
    end
  end
end
