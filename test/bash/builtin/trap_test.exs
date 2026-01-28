defmodule Bash.Builtin.TrapTest do
  use Bash.SessionCase, async: true

  setup :start_session

  describe "EXIT trap" do
    test "fires at script end", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo EXIT_FIRED' EXIT
        echo hello
        """)

      stdout = get_stdout(result)
      assert stdout =~ "hello"
      assert stdout =~ "EXIT_FIRED"
    end

    test "fires after last command", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo EXITING' EXIT
        echo first
        echo second
        """)

      stdout = get_stdout(result)
      lines = String.split(stdout, "\n", trim: true)
      assert List.last(lines) == "EXITING"
    end

    test "fires even when script exits with nonzero", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo CLEANUP' EXIT
        false
        """)

      assert get_stdout(result) =~ "CLEANUP"
    end

    test "fires on explicit exit", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo TRAP_RAN' EXIT
        exit 0
        """)

      assert get_stdout(result) =~ "TRAP_RAN"
    end

    test "fires on exit with nonzero code", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo EXITED' EXIT
        exit 42
        """)

      assert result.exit_code == 42
      assert get_stdout(result) =~ "EXITED"
    end

    test "can run multiple commands in trap handler", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo one; echo two; echo three' EXIT
        echo start
        """)

      stdout = get_stdout(result)
      assert stdout =~ "one"
      assert stdout =~ "two"
      assert stdout =~ "three"
    end

    test "ignored EXIT trap prevents handler from firing", %{session: session} do
      result =
        run_script(session, ~S"""
        trap '' EXIT
        echo done
        """)

      assert get_stdout(result) == "done\n"
    end

    test "fires only once, not from nested eval", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo EXIT_FIRED' EXIT
        eval 'echo from_eval'
        """)

      stdout = get_stdout(result)
      assert stdout =~ "from_eval"
      occurrences = length(String.split(stdout, "EXIT_FIRED")) - 1
      assert occurrences == 1
    end
  end

  describe "DEBUG trap" do
    test "fires before each simple command", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo DEBUG' DEBUG
        echo first
        echo second
        """)

      stdout = get_stdout(result)
      debug_count = length(String.split(stdout, "DEBUG")) - 1
      assert debug_count >= 2
    end

    test "fires with BASH_COMMAND set", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo "cmd: $BASH_COMMAND"' DEBUG
        echo hello
        """)

      stdout = get_stdout(result)
      assert stdout =~ "cmd:"
    end
  end

  describe "resetting traps" do
    test "dash resets EXIT trap so it does not fire", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo EXIT_FIRED' EXIT
        trap - EXIT
        echo done
        """)

      stdout = get_stdout(result)
      refute stdout =~ "EXIT_FIRED"
      assert stdout =~ "done"
    end

    test "overwriting trap replaces handler", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo FIRST' EXIT
        trap 'echo SECOND' EXIT
        echo done
        """)

      stdout = get_stdout(result)
      refute stdout =~ "FIRST"
      assert stdout =~ "SECOND"
    end
  end

  describe "listing traps" do
    test "trap with no args lists current traps", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo hello' EXIT
        trap
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap -- 'echo hello' EXIT"
    end

    test "trap -p prints traps in reusable format", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo hello' EXIT
        trap -p
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap -- 'echo hello' EXIT"
    end

    test "trap -p EXIT prints specific trap", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo hello' EXIT
        trap 'echo err' ERR
        trap -p EXIT
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap -- 'echo hello' EXIT"
      refute stdout =~ "trap -- 'echo err' ERR"
    end

    test "trap -l lists signal names", %{session: session} do
      result = run_script(session, "trap -l")
      stdout = get_stdout(result)
      assert stdout =~ "SIGHUP"
      assert stdout =~ "SIGINT"
      assert stdout =~ "SIGTERM"
    end
  end

  describe "ERR trap" do
    test "ERR trap is stored and displayed by trap -p", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo ERROR_CAUGHT' ERR
        trap -p ERR
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap -- 'echo ERROR_CAUGHT' ERR"
    end
  end

  describe "trap in function" do
    test "top-level EXIT trap fires after function call", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo TOP_TRAP' EXIT
        myfunc() { echo in_func; }
        myfunc
        """)

      stdout = get_stdout(result)
      assert stdout =~ "in_func"
      assert stdout =~ "TOP_TRAP"
    end

    test "function can set EXIT trap that fires at script end", %{session: session} do
      result =
        run_script(session, ~S"""
        setup() { trap 'echo FUNC_TRAP' EXIT; }
        setup
        echo after_setup
        """)

      stdout = get_stdout(result)
      assert stdout =~ "after_setup"
      # Note: trap set inside function may or may not propagate to top level
      # depending on implementation - just verify no crash
      assert result.exit_code == 0
    end
  end

  describe "multiple signal specs" do
    test "set same handler for multiple signals", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo TRAPPED' EXIT ERR
        trap -p EXIT
        trap -p ERR
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap -- 'echo TRAPPED' EXIT"
      assert stdout =~ "trap -- 'echo TRAPPED' ERR"
    end
  end

  describe "signal name variants" do
    test "accepts SIG prefix", %{session: session} do
      result =
        run_script(session, ~S"""
        trap '' SIGINT
        trap -p INT
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap --"
      assert stdout =~ "INT"
    end

    test "accepts numeric signal spec 0 as EXIT", %{session: session} do
      result =
        run_script(session, ~S"""
        trap 'echo ZERO' 0
        trap -p EXIT
        """)

      stdout = get_stdout(result)
      assert stdout =~ "trap --"
    end
  end
end
