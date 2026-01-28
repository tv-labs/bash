defmodule Bash.Builtin.UlimitTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "ulimit" do
    test "-a shows all limits", %{session: session} do
      result = run_script(session, "ulimit -a")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      lines = String.split(stdout, "\n", trim: true)
      assert length(lines) > 1
    end

    test "default shows file size limit", %{session: session} do
      result = run_script(session, "ulimit")
      assert result.exit_code == 0
      stdout = get_stdout(result) |> String.trim()
      assert stdout =~ ~r/^\d+$|^unlimited$/
    end
  end
end
