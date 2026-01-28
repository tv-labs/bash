defmodule Bash.Builtin.CdTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "cd" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    test "changes to subdirectory", %{session: session} do
      result = run_script(session, "mkdir sub; cd sub; pwd")
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() |> String.ends_with?("/sub")
    end

    test "errors on nonexistent directory", %{session: session} do
      result = run_script(session, "cd /nonexistent_dir_xyz")
      assert result.exit_code != 0
      assert get_stderr(result) =~ "No such file or directory"
    end

    test "cd - returns to previous directory", %{session: session, tmp_dir: tmp_dir} do
      result = run_script(session, "cd /tmp; cd -; pwd")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      resolved_tmp = Path.expand(tmp_dir)
      assert stdout =~ resolved_tmp
    end

    test "cd with no args goes to HOME", %{session: session} do
      result = run_script(session, "HOME=/tmp cd; pwd")
      assert result.exit_code == 0
      assert get_stdout(result) |> String.trim() == "/tmp"
    end
  end
end
