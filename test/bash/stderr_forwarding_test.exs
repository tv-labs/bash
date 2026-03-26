defmodule Bash.StderrForwardingTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "command substitution stderr forwarding" do
    test "stderr from command inside $() is forwarded to session", %{session: session} do
      result = run_script(session, ~S'x=$(echo out; echo err >&2); echo "captured: $x"')
      assert get_stdout(result) == "captured: out\n"
      assert get_stderr(result) =~ "err"
    end

    test "stderr from backtick substitution is forwarded to session", %{session: session} do
      result = run_script(session, ~S'x=`echo out; echo err >&2`; echo "captured: $x"')
      assert get_stdout(result) == "captured: out\n"
      assert get_stderr(result) =~ "err"
    end

    test "stderr is not included in substitution value", %{session: session} do
      result = run_script(session, ~S'echo "$(echo good; echo bad >&2)"')
      assert get_stdout(result) == "good\n"
      assert get_stderr(result) =~ "bad"
    end
  end

  describe "pipeline stderr forwarding" do
    test "stderr from non-tail pipeline command reaches session", %{session: session} do
      # In a pipeline, commands run in subshells with temp collectors.
      # Stderr from those collectors should be forwarded to the session.
      result = run_script(session, ~S'echo good_err >&2 | cat')
      assert get_stderr(result) =~ "good_err"
    end
  end
end
