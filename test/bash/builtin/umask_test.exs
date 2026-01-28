defmodule Bash.Builtin.UmaskTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "umask" do
    test "shows octal value", %{session: session} do
      result = run_script(session, "umask")
      assert result.exit_code == 0
      assert get_stdout(result) =~ ~r/\d{4}/
    end

    test "-S shows symbolic format", %{session: session} do
      result = run_script(session, "umask -S")
      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert stdout =~ "u="
      assert stdout =~ "g="
      assert stdout =~ "o="
    end

    test "setting umask exits 0", %{session: session} do
      result =
        run_script(session, ~S"""
        umask 077; echo $?
        """)

      assert get_stdout(result) =~ "0"
    end
  end
end
