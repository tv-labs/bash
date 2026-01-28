defmodule Bash.Builtin.GetoptsTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "getopts" do
    test "basic option", %{session: session} do
      result = run_script(session, ~S|set -- -a; getopts "a" opt; echo $opt|)
      assert result.exit_code == 0
      assert get_stdout(result) == "a\n"
    end

    test "option with argument", %{session: session} do
      result = run_script(session, ~S|set -- -f filename; getopts "f:" opt; echo "$opt $OPTARG"|)
      assert result.exit_code == 0
      assert get_stdout(result) == "f filename\n"
    end

    test "OPTIND advances", %{session: session} do
      result = run_script(session, ~S|set -- -a -b; getopts "ab" opt; echo $OPTIND|)
      assert result.exit_code == 0
      assert get_stdout(result) == "2\n"
    end

    test "invalid option returns question mark", %{session: session} do
      result = run_script(session, ~S|set -- -x; getopts "ab" opt 2>/dev/null; echo $opt|)
      assert get_stdout(result) == "?\n"
    end

    test "loop pattern", %{session: session} do
      result =
        run_script(session, ~S"""
        set -- -a -b -c
        while getopts "abc" opt; do
          printf "%s " "$opt"
        done
        echo done
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "a b c done\n"
    end
  end
end
