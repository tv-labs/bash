defmodule Bash.Builtin.TimesTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "times" do
    test "outputs two lines in NmN.NNNs format", %{session: session} do
      result = run_script(session, "times")
      assert result.exit_code == 0

      stdout = get_stdout(result)
      lines = String.split(stdout, "\n", trim: true)
      assert length(lines) == 2

      time_pattern = ~r/^\d+m\d+\.\d{3}s \d+m\d+\.\d{3}s$/
      assert Enum.at(lines, 0) =~ time_pattern
      assert Enum.at(lines, 1) =~ time_pattern
    end
  end
end
