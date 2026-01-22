defmodule Bash.ExternalCommandsTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  setup :start_session

  describe "External command execution" do
    test "executes ls command", %{session: session} do
      result = run_script(session, "ls")

      # Should return directory contents
      output = get_stdout(result)
      assert is_binary(output)
      # ls should list files, so output length should be > 0
      assert String.length(output) > 0
    end

    test "executes date command", %{session: session} do
      result = run_script(session, "date")

      # Date should return a date string
      output = get_stdout(result)
      assert is_binary(output)
      assert String.length(output) > 0
      assert String.ends_with?(output, "\n")
    end

    test "handles command with arguments", %{session: session} do
      result = run_script(session, "echo external")

      # This should use the builtin echo, but if it were external it should work too
      output = get_stdout(result)
      assert output == "external\n"
    end

    test "handles nonexistent command gracefully", %{session: session} do
      result = run_script(session, "thiscommanddoesnotexist123456")

      # Result should have non-zero exit code (127 for command not found)
      assert result.exit_code != 0 or result.exit_code == 127
    end

    test "handles command failure with exit code", %{session: session} do
      # Use a command that should fail - try to ls a nonexistent directory
      result = run_script(session, "ls \"/this/path/does/not/exist/hopefully\"")

      assert result.exit_code != 0
    end

    test "passes environment variables to external command", %{session: session} do
      # Set an environment variable in the session
      :ok = Session.set_env(session, "TEST_VAR", "hello_from_session")

      # Use env command to print the variable
      result = run_script(session, "env")
      output = get_stdout(result)

      # Should contain our test variable
      assert String.contains?(output, "TEST_VAR=hello_from_session")
    end

    test "respects working directory", %{session: session} do
      # Change to /tmp directory
      Session.chdir(session, "/tmp")

      # Run pwd command
      result = run_script(session, "pwd")
      output = get_stdout(result)

      # Should show /tmp (or actual resolved path)
      assert String.contains?(output, "tmp")
    end
  end
end
