defmodule Bash.Builtin.PopdTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "popd" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    test "returns to original directory after pushd", %{session: session, tmp_dir: tmp_dir} do
      result = run_script(session, "pushd /tmp >/dev/null; popd >/dev/null; pwd")
      assert result.exit_code == 0
      assert get_stdout(result) == "#{tmp_dir}\n"
    end

    test "errors on empty stack", %{session: session} do
      result = run_script(session, "popd 2>/dev/null; echo $?")
      assert get_stdout(result) == "1\n"
    end
  end
end
