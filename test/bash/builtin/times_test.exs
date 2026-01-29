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

    test "reports children time from completed background jobs", %{session: session} do
      result = run_script(session, "sleep 0.1 & wait; times")
      assert result.exit_code == 0

      stdout = get_stdout(result)
      # Find the times output lines (NmN.NNNs format pairs)
      time_pattern = ~r/^\d+m\d+\.\d{3}s \d+m\d+\.\d{3}s$/
      times_lines = stdout |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ time_pattern))
      assert length(times_lines) == 2

      # Children line (second) should not be all zeros
      child_line = Enum.at(times_lines, 1)
      refute child_line == "0m0.000s 0m0.000s", "expected children time > 0 after background job"
    end

    test "continues script after wait executes remaining statements", %{session: session} do
      result = run_script(session, "sleep 0.01 & wait; echo done")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "done"
    end

    test "times output piped through head -1", %{session: session} do
      result = run_script(session, "times 2>/dev/null | head -1 || true")

      stdout = get_stdout(result) |> String.trim()
      assert stdout =~ ~r/\d+m\d+\.\d+s\s+\d+m\d+\.\d+s/
    end
  end
end
