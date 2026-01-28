defmodule Bash.Builtin.HelpTest do
  use Bash.SessionCase, async: true

  setup :start_session

  test "no args lists builtins", %{session: session} do
    result = run_script(session, "help")
    stdout = get_stdout(result)
    assert stdout =~ "GNU bash"
    assert stdout =~ "shell commands are defined internally"
  end

  test "no args output contains common builtins", %{session: session} do
    result = run_script(session, "help")
    stdout = get_stdout(result)
    assert stdout =~ "cd"
    assert stdout =~ "echo"
    assert stdout =~ "export"
    assert stdout =~ "exit"
  end

  test "help echo shows help for echo", %{session: session} do
    result = run_script(session, "help echo")
    stdout = get_stdout(result)
    assert stdout =~ "echo"
    assert stdout =~ "Write arguments to the standard output."
  end

  test "-d echo shows short description", %{session: session} do
    result = run_script(session, "help -d echo")
    stdout = get_stdout(result)
    assert stdout =~ "echo - Write arguments to the standard output."
  end

  test "-s echo shows synopsis only", %{session: session} do
    result = run_script(session, "help -s echo")
    stdout = get_stdout(result)
    assert stdout =~ "echo: echo [-neE] [arg ...]"
  end

  test "nonexistent builtin returns exit code 1", %{session: session} do
    result = run_script(session, "help nonexistent_xyz")
    assert result.exit_code == 1
    stderr = get_stderr(result)
    assert stderr =~ "no help topics match `nonexistent_xyz'"
  end

  test "pattern matching with glob", %{session: session} do
    result = run_script(session, "help 'ec*'")
    stdout = get_stdout(result)
    assert stdout =~ "echo"
  end
end
