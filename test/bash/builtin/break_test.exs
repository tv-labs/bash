defmodule Bash.Builtin.BreakTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "break" do
    test "breaks out of for loop", %{session: session} do
      result = run_script(session, "for i in 1 2 3; do echo $i; break; done")
      assert get_stdout(result) == "1\n"
    end

    test "break 2 exits nested loops", %{session: session} do
      result =
        run_script(session, "for i in 1 2; do for j in a b; do echo $j; break 2; done; done")

      assert get_stdout(result) == "a\n"
    end

    test "break outside loop produces error", %{session: session} do
      result = run_script(session, "break")
      assert get_stderr(result) =~ "break"
    end
  end
end
