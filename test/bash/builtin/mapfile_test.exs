defmodule Bash.Builtin.MapfileTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "mapfile" do
    test "basic usage with -t", %{session: session} do
      result =
        run_script(session, ~S"""
        printf "a\nb\nc\n" | { mapfile -t arr; echo "${arr[0]} ${arr[1]} ${arr[2]}"; }
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "a b c\n"
    end

    test "with -n count limit", %{session: session} do
      result =
        run_script(session, ~S"""
        printf "a\nb\nc\n" | { mapfile -t -n 2 arr; echo "${#arr[@]}"; }
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "2\n"
    end

    test "with -s skip", %{session: session} do
      result =
        run_script(session, ~S"""
        printf "a\nb\nc\n" | { mapfile -t -s 1 arr; echo "${arr[0]}"; }
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "b\n"
    end

    test "default array name MAPFILE", %{session: session} do
      result =
        run_script(session, ~S"""
        printf "a\nb\n" | { mapfile -t; echo "${MAPFILE[0]}"; }
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "a\n"
    end
  end
end
