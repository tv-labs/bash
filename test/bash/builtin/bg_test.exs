defmodule Bash.Builtin.BgTest do
  use Bash.SessionCase, async: false

  setup :start_session

  describe "error cases" do
    test "with no jobs returns error", %{session: session} do
      result = run_script(session, "bg")

      assert result.exit_code == 1
      assert get_stderr(result) =~ "no current job"
    end

    test "with nonexistent job returns error", %{session: session} do
      result = run_script(session, "bg %99")

      assert result.exit_code == 1
      assert get_stderr(result) =~ "no such job"
    end

    test "with invalid job spec returns error", %{session: session} do
      result = run_script(session, "bg %abc")

      assert result.exit_code == 1
      assert get_stderr(result) =~ "invalid job"
    end

    test "nonexistent job by number returns error", %{session: session} do
      result = run_script(session, "bg 42")

      assert result.exit_code == 1
      assert get_stderr(result) =~ "no such job"
    end
  end

  describe "job spec parsing" do
    test "parses %N format", %{session: session} do
      result = run_script(session, "bg %5")

      assert result.exit_code == 1
      assert get_stderr(result) =~ "no such job"
    end

    test "parses bare number format", %{session: session} do
      result = run_script(session, "bg 5")

      assert result.exit_code == 1
      assert get_stderr(result) =~ "no such job"
    end

    test "parses %% as current job spec", %{session: session} do
      result = run_script(session, "bg %%")

      assert result.exit_code == 1
    end

    test "parses %+ as current job spec", %{session: session} do
      result = run_script(session, "bg %+")

      assert result.exit_code == 1
    end

    test "parses %- as previous job spec", %{session: session} do
      result = run_script(session, "bg %-")

      assert result.exit_code == 1
    end
  end
end
