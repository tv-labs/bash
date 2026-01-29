defmodule Bash.Builtin.CallerTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "caller" do
    test "caller 0 inside a function returns line subroutine filename", %{session: session} do
      result =
        run_script(session, ~S"""
        f() { caller 0; }
        f
        """)

      stdout = get_stdout(result)
      assert stdout =~ ~r/2 main bash/
    end

    test "caller with no args inside a function returns line filename", %{session: session} do
      result =
        run_script(session, ~S"""
        f() { caller; }
        f
        """)

      stdout = get_stdout(result)
      assert stdout =~ ~r/2 bash/
    end

    test "outside a function returns non-zero exit code", %{session: session} do
      result = run_script(session, "caller 2>/dev/null")
      assert Bash.ExecutionResult.exit_code(result) != 0
    end

    test "caller with frame number exceeding stack depth returns non-zero", %{session: session} do
      result =
        run_script(session, ~S"""
        f() { caller 5; }
        f 2>/dev/null
        """)

      assert Bash.ExecutionResult.exit_code(result) != 0
    end

    test "nested function calls produce correct stack frames", %{session: session} do
      result =
        run_script(session, ~S"""
        inner() { caller 0; caller 1; }
        outer() { inner; }
        outer
        """)

      stdout = get_stdout(result)
      lines = String.split(stdout, "\n", trim: true)
      assert Enum.at(lines, 0) =~ ~r/2 outer bash/
      assert Enum.at(lines, 1) =~ ~r/3 main bash/
    end

    test "caller with negative number returns exit code 2", %{session: session} do
      result =
        run_script(session, ~S"""
        f() { caller -1; }
        f 2>/dev/null
        """)

      assert Bash.ExecutionResult.exit_code(result) == 2
    end

    test "caller with non-numeric argument returns exit code 2", %{session: session} do
      result =
        run_script(session, ~S"""
        f() { caller abc; }
        f 2>/dev/null
        """)

      assert Bash.ExecutionResult.exit_code(result) == 2
    end

    test "caller 0 in named function shows line number and main", %{session: session} do
      result =
        run_script(session, ~S"""
        showcaller() { caller 0; }
        showcaller
        """)

      stdout = get_stdout(result) |> String.trim()
      parts = String.split(stdout)
      assert length(parts) >= 2
      assert {_, ""} = Integer.parse(hd(parts))
    end
  end
end
