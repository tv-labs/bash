defmodule Bash.Builtin.CommandTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "command" do
    test "executes a command", %{session: session} do
      result = run_script(session, "command echo hello")
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() == "hello"
    end

    test "-v outputs the command name", %{session: session} do
      result = run_script(session, "command -v echo")
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() == "echo"
    end

    test "-V describes the command", %{session: session} do
      result = run_script(session, "command -V echo")
      assert result.exit_code == 0
      assert get_stdout(result) =~ "builtin"
    end

    test "bypasses function definitions", %{session: session} do
      result = run_script(session, ~s|echo() { command echo "wrapped"; }; command echo original|)
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() == "original"
    end
  end
end
