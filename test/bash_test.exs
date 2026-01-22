defmodule BashTest do
  use Bash.SessionCase, async: true

  import Bash.Sigil

  setup :start_session

  test "runs a simple command", %{session: session} do
    {:ok, result, _session} = Bash.run(~BASH"echo hello", session)
    assert Bash.ExecutionResult.stdout(result) == "hello\n"
  end
end
