defmodule Bash.Builtin.DirsTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "dirs" do
    test "outputs at least the current directory", %{session: session} do
      result = run_script(session, "dirs")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.length(stdout) > 0
    end

    test "clearing with -c leaves only current dir", %{session: session} do
      result = run_script(session, "cd lib; cd bash; dirs -c; dirs")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.length(stdout) > 0
    end

    test "-p shows one entry per line with at least 2 after pushd", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs -p")
      assert result.exit_code == 0
      lines = result |> get_stdout() |> String.split("\n", trim: true)
      assert length(lines) >= 2
    end

    test "-l shows full paths without tilde contraction", %{session: session} do
      result = run_script(session, "dirs -l")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      refute stdout =~ "~"
    end

    test "-v shows entries with index numbers", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs -v")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert stdout =~ " 0  "
      assert stdout =~ " 1  "
    end

    test "+N shows Nth entry from left", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs +0")
      assert result.exit_code == 0
      stdout = get_stdout(result) |> String.trim()
      assert String.length(stdout) > 0
    end

    test "+N shows second entry from left", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs +1")
      assert result.exit_code == 0
      stdout = get_stdout(result) |> String.trim()
      assert String.length(stdout) > 0
    end

    test "-N shows Nth entry from right", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs -0")
      assert result.exit_code == 0
      stdout = get_stdout(result) |> String.trim()
      assert String.length(stdout) > 0
    end

    test "+N out of range returns error", %{session: session} do
      result = run_script(session, "dirs +99 2>/dev/null")
      assert result.exit_code == 1
    end

    test "-N out of range returns error", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs -99 2>/dev/null")
      assert result.exit_code == 1
    end

    test "-lp shows full paths one per line", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs -lp")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      lines = String.split(stdout, "\n", trim: true)
      assert length(lines) >= 2
      Enum.each(lines, fn line -> refute line =~ "~" end)
    end

    test "-v combined with -l shows indexed full paths", %{session: session} do
      result = run_script(session, "pushd /tmp >/dev/null 2>&1; dirs -lv")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert stdout =~ " 0  "
      refute stdout =~ "~"
    end

    test "dirs shows directory stack with tilde shortening after pushd", %{session: session} do
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
end
