defmodule Bash.Builtin.UnsetTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "unset" do
    test "removes a variable", %{session: session} do
      result = run_script(session, ~S[x=hello; unset x; echo "${x:-empty}"])
      assert result.exit_code == 0
      assert get_stdout(result) == "empty\n"
    end

    test "removes a function with -f", %{session: session} do
      result = run_script(session, ~S[f() { echo hi; }; unset -f f; f 2>/dev/null; echo $?])
      assert result.exit_code == 0
      assert get_stdout(result) == "127\n"
    end

    test "cannot unset readonly variable", %{session: session} do
      result = run_script(session, ~S[readonly RO=val; unset RO 2>/dev/null; echo $?])
      assert result.exit_code == 0
      assert get_stdout(result) == "1\n"
    end

    test "unsets array element", %{session: session} do
      result = run_script(session, "arr=(a b c); unset 'arr[1]'; echo \"${arr[@]}\"")
      assert result.exit_code == 0
      assert get_stdout(result) == "a c\n"
    end
  end

  describe "unset with namerefs" do
    test "unset on a nameref unsets the target variable", %{session: session} do
      result =
        run_script(session, ~S"""
        target=hello
        declare -n ref=target
        unset ref
        echo "${target:-gone}"
        """)

      assert get_stdout(result) == "gone\n"
    end

    test "unset -n on a nameref unsets the nameref itself", %{session: session} do
      result =
        run_script(session, ~S"""
        target=hello
        declare -n ref=target
        unset -n ref
        echo "$target"
        """)

      assert get_stdout(result) == "hello\n"
    end
  end
end
