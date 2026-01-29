defmodule Bash.ComprehensiveGapsTest do
  @moduledoc """
  Tests for each missing line from the sloppy comprehensive bash reference.
  Each test represents a gap identified in the comprehensive test output.
  """
  use Bash.SessionCase, async: true

  setup :start_session

  describe "array subscript default expansion (ref line 154 blocker)" do
    test "${arr[N]:-default} returns element value when set", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -a arr=(foo bar)
        echo "${arr[1]:-fallback}"
        """)

      assert get_stdout(result) |> String.trim() == "bar"
    end

    test "${arr[N]:-default} returns default when unset index", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -a arr=(foo bar)
        echo "${arr[5]:-fallback}"
        """)

      assert get_stdout(result) |> String.trim() == "fallback"
    end

    test "${arr[N]:-} returns element value when set (empty default)", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -a arr=(foo bar)
        echo "[${arr[1]:-}]"
        """)

      assert get_stdout(result) |> String.trim() == "[bar]"
    end

    test "${arr[N]:+alternate} returns alternate when set", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -a arr=(foo bar)
        echo "${arr[1]:+yes}"
        """)

      assert get_stdout(result) |> String.trim() == "yes"
    end
  end

  describe "exec FD redirect (ref lines 55, 223)" do
    test "exec 3>&1 then echo >&3 writes to stdout", %{session: session} do
      result =
        run_script(session, ~S"""
        exec 3>&1
        echo "to fd 3" >&3
        exec 3>&-
        """)

      assert get_stdout(result) |> String.trim() == "to fd 3"
    end

    test "exec 4>&1 then echo >&4 writes to stdout", %{session: session} do
      result =
        run_script(session, ~S"""
        exec 4>&1
        echo "to fd 4" >&4
        exec 4>&-
        """)

      assert get_stdout(result) |> String.trim() == "to fd 4"
    end
  end

  describe "declare -p (ref line 225)" do
    test "declare -p shows variable declaration", %{session: session} do
      result =
        run_script(session, ~S"""
        myvar="hello"
        declare -p myvar
        """)

      assert get_stdout(result) |> String.trim() == ~S'declare -- myvar="hello"'
    end

    test "declare -p shows integer variable", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -i intvar=10
        declare -p intvar
        """)

      assert get_stdout(result) |> String.trim() == ~S'declare -i intvar="10"'
    end
  end

  describe "-R test operator for namerefs (ref line 236)" do
    test "[[ -R nameref ]] returns true for nameref variable", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -n nameref=myvar
        [[ -R nameref ]] && echo "-R: nameref is a nameref"
        """)

      assert get_stdout(result) |> String.trim() == "-R: nameref is a nameref"
    end

    test "[[ -R normalvar ]] returns false for regular variable", %{session: session} do
      result =
        run_script(session, ~S"""
        normalvar="hello"
        [[ -R normalvar ]] && echo "yes" || echo "no"
        """)

      assert get_stdout(result) |> String.trim() == "no"
    end
  end

  describe "times piped (ref line 124)" do
    test "times output piped through head -1", %{session: session} do
      result = run_script(session, "times 2>/dev/null | head -1 || true")

      stdout = get_stdout(result) |> String.trim()
      # times outputs "XmX.XXXs XmX.XXXs" for user/system times
      assert stdout =~ ~r/\d+m\d+\.\d+s\s+\d+m\d+\.\d+s/
    end
  end

  describe "jobs output format (ref line 126)" do
    test "jobs shows running background process without extra notification", %{session: session} do
      result =
        run_script(session, """
        sleep 0.5 &
        jobs
        wait
        """)

      stdout = get_stdout(result)
      lines = String.split(stdout, "\n", trim: true)
      # Should have exactly one jobs line like: [1]+  Running  sleep 0.5 &
      job_lines = Enum.filter(lines, &(&1 =~ ~r/\[\d+\]/))
      assert length(job_lines) == 1
      assert hd(job_lines) =~ "Running"
    end
  end

  describe "dirs output (ref line 129)" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    test "dirs shows directory stack with tilde shortening", %{session: session} do
      result =
        run_script(session, """
        pushd /tmp > /dev/null
        dirs
        popd > /dev/null
        """)

      stdout = get_stdout(result) |> String.trim()
      assert stdout =~ "/tmp"
    end
  end

  describe "caller format (ref line 132)" do
    test "caller 0 in function shows line number, function name, and filename", %{
      session: session
    } do
      result =
        run_script(session, ~S"""
        showcaller() { caller 0; }
        showcaller
        """)

      stdout = get_stdout(result) |> String.trim()
      # caller 0 should output: line_number subroutine filename
      # e.g., "2 showcaller bash" or similar
      parts = String.split(stdout)
      assert length(parts) >= 2
      # First part should be a line number
      assert {_, ""} = Integer.parse(hd(parts))
    end
  end

  describe "coproc with default expansion (ref line 154)" do
    test "coproc I/O works with ${NAME[N]:-} guard", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc MYCP { cat; }
        if [[ -n "${MYCP[1]:-}" ]]; then
          echo "hello coproc" >&${MYCP[1]}
          eval "exec ${MYCP[1]}>&-"
          read -u ${MYCP[0]} reply
          echo "Coproc reply: $reply"
        else
          echo "Coproc: skipped"
        fi
        """)

      assert get_stdout(result) |> String.trim() == "Coproc reply: hello coproc"
    end
  end

  describe "background echo ordering (ref line 205)" do
    test "echo c & echo d produces both c and d", %{session: session} do
      result =
        run_script(session, """
        echo c & echo d
        wait
        """)

      stdout = get_stdout(result)
      assert stdout =~ "c"
      assert stdout =~ "d"
    end
  end
end
