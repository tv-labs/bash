defmodule Bash.Builtin.ContinueTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "continue in for loop" do
    test "skips remaining body", %{session: session} do
      script = ~S"""
      for i in 1 2 3; do
        if [ "$i" = "2" ]; then continue; fi
        echo $i
      done
      """

      result = run_script(session, script)
      assert get_stdout(result) == "1\n3\n"
    end

    test "skips entire body when unconditional", %{session: session} do
      result = run_script(session, "for i in 1 2 3; do continue; echo $i; done")
      assert get_stdout(result) == ""
    end
  end

  describe "continue in while loop" do
    test "skips remaining body", %{session: session} do
      script = ~S"""
      i=0
      while [ "$i" -lt 5 ]; do
        i=$((i + 1))
        if [ "$i" = "3" ]; then continue; fi
        echo $i
      done
      """

      result = run_script(session, script)
      assert get_stdout(result) == "1\n2\n4\n5\n"
    end
  end

  describe "continue N" do
    test "skips N levels of nesting", %{session: session} do
      script = """
      for i in 1 2; do
        for j in a b; do
          continue 2
          echo "$j"
        done
        echo "$i"
      done
      """

      result = run_script(session, script)
      assert get_stdout(result) == ""
    end

    test "value greater than nesting depth is clamped", %{session: session} do
      script = """
      for i in 1 2; do
        for j in a b; do
          continue 10
          echo "$j"
        done
        echo "$i"
      done
      """

      result = run_script(session, script)
      assert get_stdout(result) == ""
    end
  end

  describe "continue in nested loop" do
    test "only affects innermost loop", %{session: session} do
      script = ~S"""
      for i in 1 2; do
        for j in a b c; do
          if [ "$j" = "b" ]; then continue; fi
          echo "$i$j"
        done
      done
      """

      result = run_script(session, script)
      assert get_stdout(result) == "1a\n1c\n2a\n2c\n"
    end
  end

  describe "continue preserves loop variable state" do
    test "variable advances to next iteration value", %{session: session} do
      script = ~S"""
      for i in 1 2 3; do
        continue
      done
      echo $i
      """

      result = run_script(session, script)
      assert get_stdout(result) == "3\n"
    end
  end

  describe "error cases" do
    test "outside a loop produces error", %{session: session} do
      result = run_script(session, "continue")
      assert get_stderr(result) =~ "only meaningful in a"
    end

    test "continue 0 is invalid", %{session: session} do
      result = run_script(session, "for i in 1; do continue 0; done")
      assert get_stderr(result) =~ "loop count out of range"
    end

    test "continue with negative number is invalid", %{session: session} do
      result = run_script(session, "for i in 1; do continue -1; done")
      assert get_stderr(result) =~ "loop count out of range"
    end
  end
end
