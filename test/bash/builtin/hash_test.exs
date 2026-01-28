defmodule Bash.Builtin.HashTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "hash" do
    test "-r clears hash table", %{session: session} do
      result =
        run_script(session, ~S"""
        hash -r; echo $?
        """)

      assert get_stdout(result) =~ "0"
    end

    test "-t shows path after hashing", %{session: session} do
      result =
        run_script(session, ~S"""
        hash ls 2>/dev/null; hash -t ls
        """)

      assert get_stdout(result) =~ "/"
    end

    test "-t nonexistent command returns 1", %{session: session} do
      result =
        run_script(session, ~S"""
        hash -t nonexistent_cmd_xyz 2>/dev/null; echo $?
        """)

      assert get_stdout(result) =~ "1"
    end
  end
end
