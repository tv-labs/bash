defmodule Bash.FileDescriptorTest do
  use Bash.SessionCase, async: true

  @moduletag :tmp_dir
  @moduletag working_dir: :tmp_dir

  setup :start_session

  describe "file descriptor read and write" do
    test "exec 3>file opens fd for writing, >&3 redirects to it", %{session: session, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "output.txt")

      result =
        run_script(session, """
        exec 3>#{path}
        echo "hello" >&3
        exec 3>&-
        """)

      assert get_stdout(result) == ""
      assert File.read!(path) == "hello\n"
    end

    test "exec 3<file opens fd for reading, read -u 3 consumes lines", %{session: session, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "input.txt")
      File.write!(path, "line1\nline2\n")

      result =
        run_script(session, """
        exec 3<#{path}
        read -u 3 first
        read -u 3 second
        exec 3<&-
        echo "$first $second"
        """)

      assert get_stdout(result) == "line1 line2\n"
    end

    test "exec 3>>file opens fd in append mode", %{session: session, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "append.txt")
      File.write!(path, "existing\n")

      result =
        run_script(session, """
        exec 3>>#{path}
        echo "appended" >&3
        exec 3>&-
        """)

      assert get_stdout(result) == ""
      assert File.read!(path) == "existing\nappended\n"
    end

    test ">&3 after exec 3>&- errors with bad file descriptor", %{session: session, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "output.txt")

      result =
        run_script(session, """
        exec 3>#{path}
        exec 3>&-
        echo "after close" >&3
        echo "exit: $?"
        """)

      assert get_stderr(result) =~ "3: Bad file descriptor"
      assert get_stdout(result) == "exit: 1\n"
    end

    test "fd persists across commands until closed", %{session: session, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multi.txt")

      result =
        run_script(session, """
        exec 3>#{path}
        echo "one" >&3
        echo "two" >&3
        echo "three" >&3
        exec 3>&-
        """)

      assert get_stdout(result) == ""
      assert File.read!(path) == "one\ntwo\nthree\n"
    end
  end
end
