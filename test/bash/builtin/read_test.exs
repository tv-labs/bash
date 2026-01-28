defmodule Bash.Builtin.ReadTest do
  use Bash.SessionCase, async: true

  setup :start_session

  describe "read with combined flags" do
    test "read -ra splits input into array", %{session: session} do
      result =
        run_script(session, ~S"""
        echo "one two three" | { read -ra arr; echo "${arr[0]} ${arr[1]} ${arr[2]}"; }
        """)

      assert get_stdout(result) == "one two three\n"
    end

    test "read -ra with custom IFS", %{session: session} do
      result =
        run_script(session, ~S"""
        echo "a:b:c" | { IFS=: read -ra arr; echo "${arr[0]} ${arr[1]} ${arr[2]}"; }
        """)

      assert get_stdout(result) == "a b c\n"
    end

    test "read with here-string", %{session: session} do
      result =
        run_script(session, ~S"""
        read -r line <<< "hello world"; echo "$line"
        """)

      assert get_stdout(result) == "hello world\n"
    end

    test "read -ra with session-level IFS and here-string", %{session: session} do
      result =
        run_script(session, ~S"""
        IFS=:; parts="a:b:c"; read -ra arr <<< "$parts"; echo "IFS split: ${arr[@]}"
        """)

      assert get_stdout(result) == "IFS split: a b c\n"
    end
  end
end
