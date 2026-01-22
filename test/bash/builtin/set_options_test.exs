defmodule Bash.Builtin.SetOptionsTest do
  @moduledoc """
  Tests for all set builtin options.

  Options tested:
  - errexit (-e): Exit immediately if a command exits with a non-zero status
  - nounset (-u): Treat unset variables as an error when substituting
  - pipefail: Return value of pipeline is status of last command to exit with non-zero status
  - allexport (-a): Mark variables which are modified or created for export
  - noglob (-f): Disable file name generation (globbing)
  - noclobber (-C): Disallow existing regular files to be overwritten by redirection
  - noexec (-n): Read commands but do not execute them
  - verbose (-v): Print shell input lines as they are read
  - xtrace (-x): Print commands and their arguments as they are executed
  """

  use Bash.SessionCase, async: true

  alias Bash.Session

  describe "errexit (-e)" do
    setup :start_session

    test "set -e causes script to exit on failed command", %{session: session} do
      result =
        run_script(session, """
        set -e
        false
        echo "should not reach here"
        """)

      assert result.exit_code == 1
      refute String.contains?(get_stdout(result), "should not reach here")
    end

    test "without set -e, script continues after failed command", %{session: session} do
      result =
        run_script(session, """
        false
        echo "should reach here"
        """)

      assert String.contains?(get_stdout(result), "should reach here")
    end

    test "set +e disables errexit", %{session: session} do
      result =
        run_script(session, """
        set -e
        set +e
        false
        echo "should reach here"
        """)

      assert String.contains?(get_stdout(result), "should reach here")
    end
  end

  describe "nounset (-u)" do
    setup :start_session

    test "set -u causes error on unset variable", %{session: session} do
      result =
        run_script(session, """
        set -u
        echo "$UNDEFINED_VAR"
        """)

      # Should fail with an error about unset variable
      assert result.exit_code != 0
    end

    test "without set -u, unset variable expands to empty", %{session: session} do
      result =
        run_script(session, """
        echo "value=$UNDEFINED_VAR"
        """)

      assert result.exit_code == 0
      assert String.contains?(get_stdout(result), "value=")
    end

    test "set -u allows defined variables", %{session: session} do
      result =
        run_script(session, """
        set -u
        MY_VAR="hello"
        echo "$MY_VAR"
        """)

      assert result.exit_code == 0
      assert String.contains?(get_stdout(result), "hello")
    end
  end

  describe "pipefail" do
    setup :start_session

    test "set -o pipefail causes pipeline to fail if any command fails", %{session: session} do
      result =
        run_script(session, """
        set -o pipefail
        false | true
        """)

      # With pipefail, the pipeline should fail because 'false' failed
      assert result.exit_code == 1
    end

    test "without pipefail, pipeline succeeds if last command succeeds", %{session: session} do
      result =
        run_script(session, """
        false | true
        """)

      # Without pipefail, only the last command's exit code matters
      assert result.exit_code == 0
    end
  end

  describe "allexport (-a)" do
    setup :start_session

    test "set -a causes variables to be exported", %{session: session} do
      # With allexport, variables should be automatically exported to child processes
      result =
        run_script(session, """
        set -a
        MY_VAR="exported_value"
        """)

      assert result.exit_code == 0

      # The variable should be marked as exported
      state = Session.get_state(session)
      var = Map.get(state.variables, "MY_VAR")
      assert var != nil
      assert var.attributes.export == true
      assert Bash.Variable.get(var, nil) == "exported_value"
    end

    test "without set -a, variables are not automatically exported", %{session: session} do
      result =
        run_script(session, """
        MY_VAR="not_exported"
        """)

      assert result.exit_code == 0

      # Variable should not be marked as exported
      state = Session.get_state(session)
      var = Map.get(state.variables, "MY_VAR")
      assert var != nil
      assert var.attributes.export == false
    end
  end

  describe "noglob (-f)" do
    setup :start_session

    test "set -f disables globbing", %{session: session} do
      result =
        run_script(session, """
        set -f
        echo *
        """)

      # With noglob, the * should be printed literally, not expanded
      assert String.trim(get_stdout(result)) == "*"
    end
  end

  describe "noclobber (-C)" do
    @describetag :tmp_dir
    setup :start_session

    test "set -C prevents overwriting existing files with redirection", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Create a temp file first
      temp_file = Path.join(tmp_dir, "noclobber_test")
      File.write!(temp_file, "original content")

      result =
        run_script(session, """
        set -C
        echo "new content" > #{temp_file}
        """)

      # Command should have non-zero exit code
      assert result.exit_code != 0

      # Error message should be in stderr
      assert String.contains?(get_stderr(result), "cannot overwrite existing file")

      # Original content should be preserved
      assert File.read!(temp_file) == "original content"
    end
  end

  describe "noexec (-n)" do
    setup :start_session

    test "set -n reads but does not execute commands", %{session: session} do
      result =
        run_script(session, """
        set -n
        echo "should not be executed"
        """)

      # Commands should not be executed, so no output
      refute String.contains?(get_stdout(result), "should not be executed")
    end
  end

  describe "verbose (-v)" do
    setup :start_session

    test "set -v prints commands as they are read", %{session: session} do
      result =
        run_script(session, """
        set -v
        echo "hello"
        """)

      # Should have the command echoed to stderr
      assert String.contains?(get_stderr(result), "echo")

      # And the actual output
      assert String.contains?(get_stdout(result), "hello")
    end
  end

  describe "xtrace (-x)" do
    setup :start_session

    test "set -x prints commands with + prefix before execution", %{session: session} do
      result =
        run_script(session, """
        set -x
        echo "hello"
        """)

      # Should have the command with + prefix on stderr
      assert String.contains?(get_stderr(result), "+ echo")

      # And the actual output
      assert String.contains?(get_stdout(result), "hello")
    end

    test "set -x expands variables before printing", %{session: session} do
      result =
        run_script(session, """
        MY_VAR="world"
        set -x
        echo "hello $MY_VAR"
        """)

      stderr = get_stderr(result)
      # The trace should show the expanded command
      assert String.contains?(stderr, "+ echo") && String.contains?(stderr, "world")
    end
  end

  describe "combined options" do
    setup :start_session

    test "set -euo pipefail sets multiple options", %{session: session} do
      result =
        run_script(session, """
        set -euo pipefail
        MY_VAR="test"
        echo "$MY_VAR"
        """)

      # Should succeed since no errors
      assert result.exit_code == 0

      # Options should be set in session state
      state = Session.get_state(session)
      assert state.options.errexit == true
      assert state.options.nounset == true
      assert state.options.pipefail == true
    end
  end

  describe "positional parameters with set --" do
    setup :start_session

    test "set -- assigns positional parameters", %{session: session} do
      result =
        run_script(session, """
        set -- arg1 arg2 arg3
        echo "$1 $2 $3"
        """)

      assert String.contains?(get_stdout(result), "arg1 arg2 arg3")
    end
  end

  describe "onecmd (-t)" do
    setup :start_session

    test "set -t causes exit after executing one command", %{session: session} do
      result =
        run_script(session, """
        set -t
        echo "first"
        echo "second"
        """)

      # Should exit after first echo with exit code 0
      assert result.exit_code == 0

      # Should have "first" in output
      assert String.contains?(get_stdout(result), "first")

      # Should NOT have "second" in output
      refute String.contains?(get_stdout(result), "second")
    end

    test "set -t with -o onecmd alias", %{session: session} do
      result =
        run_script(session, """
        set -o onecmd
        echo "first"
        echo "second"
        """)

      assert result.exit_code == 0
      assert String.contains?(get_stdout(result), "first")
      refute String.contains?(get_stdout(result), "second")
    end

    test "set -t exits with failed command's exit code", %{session: session} do
      result =
        run_script(session, """
        set -t
        false
        echo "should not reach here"
        """)

      # Should exit with false's exit code (1)
      assert result.exit_code == 1
      refute String.contains?(get_stdout(result), "should not reach here")
    end

    test "set +t disables onecmd", %{session: session} do
      result =
        run_script(session, """
        set -t
        set +t
        echo "first"
        echo "second"
        """)

      # Should complete normally since onecmd was disabled
      assert result.exit_code == 0

      # Should have both outputs
      assert String.contains?(get_stdout(result), "first")
      assert String.contains?(get_stdout(result), "second")
    end
  end
end
