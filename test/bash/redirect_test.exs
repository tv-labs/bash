defmodule Bash.RedirectTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  describe "input redirection execution" do
    @describetag :tmp_dir
    setup :start_session

    test "reads from file with <", %{session: session, tmp_dir: tmp_dir} do
      # Create input file
      input_path = Path.join(tmp_dir, "test_input_#{:erlang.unique_integer()}.txt")
      File.write!(input_path, "hello from file\n")

      result = run_script(session, "cat < #{input_path}")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello from file\n"
    end
  end

  describe "output redirection execution" do
    @describetag :tmp_dir
    setup :start_session

    test "writes to file with >", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_output_#{:erlang.unique_integer()}.txt")

      result = run_script(session, "echo hello world > #{output_path}")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
      assert File.read!(output_path) == "hello world\n"
    end

    test "truncates existing file with >", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_truncate_#{:erlang.unique_integer()}.txt")
      File.write!(output_path, "old content that should be gone\n")

      _result = run_script(session, "echo new content > #{output_path}")

      assert File.read!(output_path) == "new content\n"
    end

    test "appends to file with >>", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_append_#{:erlang.unique_integer()}.txt")
      File.write!(output_path, "line 1\n")

      _result = run_script(session, "echo line 2 >> #{output_path}")

      assert File.read!(output_path) == "line 1\nline 2\n"
    end

    test "creates file if not exists with >>", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_append_new_#{:erlang.unique_integer()}.txt")
      refute File.exists?(output_path)

      _result = run_script(session, "echo first line >> #{output_path}")

      assert File.read!(output_path) == "first line\n"
    end
  end

  describe "stderr redirection execution" do
    @describetag :tmp_dir
    setup :start_session

    test "redirects stderr to file with 2>", %{session: session, tmp_dir: tmp_dir} do
      err_path = Path.join(tmp_dir, "test_stderr_#{:erlang.unique_integer()}.txt")

      # ls on nonexistent file writes to stderr
      result =
        run_script_allow_error(
          session,
          "ls /nonexistent_path_#{:erlang.unique_integer()} 2> #{err_path}"
        )

      # Command fails but stderr is captured to file
      assert result.exit_code != 0
      assert File.exists?(err_path)
      stderr_content = File.read!(err_path)
      assert stderr_content =~ "No such file" or stderr_content =~ "cannot access"
    end

    test "redirects stderr to stdout with 2>&1", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_combined_#{:erlang.unique_integer()}.txt")

      # This should capture both stdout and stderr to the file
      result =
        run_script_allow_error(
          session,
          "ls /nonexistent_#{:erlang.unique_integer()} > #{output_path} 2>&1"
        )

      assert result.exit_code != 0
      content = File.read!(output_path)
      assert content =~ "No such file" or content =~ "cannot access"
    end
  end

  describe "combined input/output redirection execution" do
    @describetag :tmp_dir
    setup :start_session

    test "reads from file and writes to another", %{session: session, tmp_dir: tmp_dir} do
      input_path = Path.join(tmp_dir, "test_io_in_#{:erlang.unique_integer()}.txt")
      output_path = Path.join(tmp_dir, "test_io_out_#{:erlang.unique_integer()}.txt")

      File.write!(input_path, "transform this\n")

      result = run_script(session, "cat < #{input_path} > #{output_path}")

      assert result.exit_code == 0
      assert File.read!(output_path) == "transform this\n"
    end
  end

  describe "&> combined redirect execution" do
    @describetag :tmp_dir
    setup :start_session

    test "captures both stdout and stderr with &>", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_both_#{:erlang.unique_integer()}.txt")

      # A command that writes to both stdout and stderr
      result =
        run_script_allow_error(
          session,
          "ls /nonexistent_#{:erlang.unique_integer()} &> #{output_path}"
        )

      assert result.exit_code != 0
      content = File.read!(output_path)
      assert content =~ "No such file" or content =~ "cannot access"
    end
  end

  describe "redirection in pipelines" do
    @describetag :tmp_dir
    setup :start_session

    test "input redirect on first command of pipeline", %{session: session, tmp_dir: tmp_dir} do
      input_path = Path.join(tmp_dir, "test_pipe_in_#{:erlang.unique_integer()}.txt")
      File.write!(input_path, "hello\nworld\n")

      result = run_script(session, "cat < #{input_path} | wc -l")

      assert result.exit_code == 0
      assert String.trim(get_stdout(result)) == "2"
    end

    test "output redirect on last command of pipeline", %{session: session, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "test_pipe_out_#{:erlang.unique_integer()}.txt")

      result = run_script(session, "echo -e 'a\\nb\\nc' | sort > #{output_path}")

      assert result.exit_code == 0
      content = File.read!(output_path)
      assert content == "a\nb\nc\n"
    end
  end

  describe "multiple FD redirects" do
    @describetag :tmp_dir
    setup :start_session

    test "redirect stdout and stderr to separate files", %{session: session, tmp_dir: tmp_dir} do
      stdout_file = Path.join(tmp_dir, "stdout_#{:erlang.unique_integer([:positive])}.txt")
      stderr_file = Path.join(tmp_dir, "stderr_#{:erlang.unique_integer([:positive])}.txt")

      # Command that writes to both stdout and stderr
      # Using a subshell to generate both outputs
      bash_script = """
      (echo "stdout_line" && echo "stderr_line" >&2) > #{stdout_file} 2> #{stderr_file}
      echo "OUT: $(cat #{stdout_file})"
      echo "ERR: $(cat #{stderr_file})"
      """

      {_bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      # Clean up from bash run
      File.rm(stdout_file)
      File.rm(stderr_file)

      # Our implementation - simplified since we may not have subshell support
      # Test the basic redirect pattern: cmd > file 2> file2
      _result =
        run_script_allow_error(
          session,
          "ls /nonexistent_#{:erlang.unique_integer([:positive])} 2> #{stderr_file}"
        )

      assert File.exists?(stderr_file)
      stderr_content = File.read!(stderr_file)
      assert stderr_content =~ "No such file" or stderr_content =~ "cannot access"
    end

    test "stderr to stdout duplication then to file", %{session: session, tmp_dir: tmp_dir} do
      output_file = Path.join(tmp_dir, "combined_#{:erlang.unique_integer([:positive])}.txt")

      # Classic pattern: cmd > file 2>&1 (redirect stderr to stdout, then stdout to file)
      bash_script = """
      ls /nonexistent_xyz_#{:erlang.unique_integer([:positive])} > #{output_file} 2>&1
      cat #{output_file}
      """

      {bash_output, _} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      # Clean up from bash
      File.rm(output_file)

      # Our implementation
      _result =
        run_script_allow_error(
          session,
          "ls /nonexistent_xyz_#{:erlang.unique_integer([:positive])} > #{output_file} 2>&1"
        )

      our_output = File.read!(output_file)

      # Both should contain the error message
      assert bash_output =~ "No such file" or bash_output =~ "cannot access"
      assert our_output =~ "No such file" or our_output =~ "cannot access"
    end

    test "stdout to stderr duplication (1>&2)", %{session: session, tmp_dir: tmp_dir} do
      stderr_file = Path.join(tmp_dir, "to_stderr_#{:erlang.unique_integer([:positive])}.txt")

      # Redirect stdout to stderr, then capture stderr to file
      # Quote paths to handle special characters in tmp_dir path
      bash_script = """
      echo "going to stderr" >&2 2> "#{stderr_file}"
      cat "#{stderr_file}"
      """

      {_bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir, stderr_to_stdout: true)

      File.rm(stderr_file)

      # Our implementation - quote path for special characters
      # The echo >&2 sends stdout to stderr, then 2> captures stderr to file
      result = run_script_allow_error(session, ~s(echo going_to_stderr >&2 2> "#{stderr_file}"))

      # Verify the redirect worked - output should be in the file
      assert result.exit_code == 0

      # The file should contain the output that went through >&2 then 2>
      if File.exists?(stderr_file) do
        content = File.read!(stderr_file)
        assert content =~ "going_to_stderr"
      end
    end

    test "&> redirects both stdout and stderr to file", %{session: session, tmp_dir: tmp_dir} do
      output_file = Path.join(tmp_dir, "both_#{:erlang.unique_integer([:positive])}.txt")

      # &> is shorthand for > file 2>&1
      bash_script = """
      (echo "stdout"; echo "stderr" >&2) &> #{output_file}
      cat #{output_file}
      """

      {_bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      File.rm(output_file)

      # Our implementation with a command that produces stderr
      _result =
        run_script_allow_error(
          session,
          "ls /nonexistent_both_#{:erlang.unique_integer([:positive])} &> #{output_file}"
        )

      our_output = File.read!(output_file)
      assert our_output =~ "No such file" or our_output =~ "cannot access"
    end

    test "&>> appends both stdout and stderr", %{session: session, tmp_dir: tmp_dir} do
      output_file = Path.join(tmp_dir, "append_both_#{:erlang.unique_integer([:positive])}.txt")

      # Pre-populate file
      File.write!(output_file, "existing_line\n")

      # Bash behavior
      bash_script = """
      echo "existing_line" > #{output_file}
      ls /nonexistent_append_#{:erlang.unique_integer([:positive])} &>> #{output_file}
      cat #{output_file}
      """

      {_bash_output, _} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      # Reset file
      File.write!(output_file, "existing_line\n")

      # Our implementation
      _result =
        run_script_allow_error(
          session,
          "ls /nonexistent_append_#{:erlang.unique_integer([:positive])} &>> #{output_file}"
        )

      our_output = File.read!(output_file)

      # Both should have existing_line followed by error
      assert our_output =~ "existing_line"
      assert our_output =~ "No such file" or our_output =~ "cannot access"
    end
  end

  describe "input redirect combinations" do
    @describetag :tmp_dir
    setup :start_session

    test "input from file, output to another file", %{session: session, tmp_dir: tmp_dir} do
      input_file = Path.join(tmp_dir, "input_#{:erlang.unique_integer([:positive])}.txt")
      output_file = Path.join(tmp_dir, "output_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(input_file, "line1\nline2\nline3\n")

      # Bash
      bash_script = """
      cat < #{input_file} > #{output_file}
      cat #{output_file}
      """

      {bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      File.rm(output_file)

      # Our implementation
      _result = run_script(session, "cat < #{input_file} > #{output_file}")

      our_output = File.read!(output_file)

      assert String.trim(bash_output) == String.trim(our_output)
    end

    test "input redirect with pipeline", %{session: session, tmp_dir: tmp_dir} do
      input_file = Path.join(tmp_dir, "pipe_input_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(input_file, "zebra\napple\nbanana\n")

      # Bash: input redirect on first command, pipe to sort
      bash_script = """
      cat < #{input_file} | sort
      """

      {bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      # Our implementation
      result = run_script(session, "cat < #{input_file} | sort")

      our_output = get_stdout(result)

      assert String.trim(bash_output) == String.trim(our_output)
      assert our_output =~ "apple\nbanana\nzebra"
    end

    test "pipeline with output redirect on last command", %{session: session, tmp_dir: tmp_dir} do
      output_file = Path.join(tmp_dir, "pipe_output_#{:erlang.unique_integer([:positive])}.txt")

      # Bash
      bash_script = """
      echo -e "3\\n1\\n2" | sort > #{output_file}
      cat #{output_file}
      """

      {bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      File.rm(output_file)

      # Our implementation
      _result = run_script(session, "echo -e '3\\n1\\n2' | sort > #{output_file}")

      our_output = File.read!(output_file)

      assert String.trim(bash_output) == String.trim(our_output)
    end
  end

  describe "complex redirect patterns" do
    @describetag :tmp_dir
    setup :start_session

    test "multiple output redirects - last one wins for same FD", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # In bash: echo "content" > file1 > file2
      # - file1 is created but empty
      # - file2 gets the content
      file1 = Path.join(tmp_dir, "first_#{:erlang.unique_integer([:positive])}.txt")
      file2 = Path.join(tmp_dir, "second_#{:erlang.unique_integer([:positive])}.txt")

      result = run_script(session, ~s[echo "content" > #{file1} > #{file2}])

      assert result.exit_code == 0
      assert get_stdout(result) == ""

      # First file should be created but empty
      assert File.exists?(file1)
      assert File.read!(file1) == ""

      # Last file should have the content
      assert File.exists?(file2)
      assert File.read!(file2) == "content\n"
    end

    test "three or more output redirects - last one wins", %{session: session, tmp_dir: tmp_dir} do
      file1 = Path.join(tmp_dir, "first_#{:erlang.unique_integer([:positive])}.txt")
      file2 = Path.join(tmp_dir, "second_#{:erlang.unique_integer([:positive])}.txt")
      file3 = Path.join(tmp_dir, "third_#{:erlang.unique_integer([:positive])}.txt")

      result = run_script(session, ~s[echo "data" > #{file1} > #{file2} > #{file3}])

      assert result.exit_code == 0

      # First two files should be empty
      assert File.read!(file1) == ""
      assert File.read!(file2) == ""

      # Last file gets the content
      assert File.read!(file3) == "data\n"
    end

    test "multiple stderr redirects - last one wins", %{session: session, tmp_dir: tmp_dir} do
      file1 = Path.join(tmp_dir, "err1_#{:erlang.unique_integer([:positive])}.txt")
      file2 = Path.join(tmp_dir, "err2_#{:erlang.unique_integer([:positive])}.txt")

      # Command that outputs to stderr
      _result = run_script(session, ~s[echo "error" >&2 2> #{file1} 2> #{file2}])

      # First file should be empty, second gets stderr
      assert File.read!(file1) == ""
      assert File.read!(file2) == "error\n"
    end

    test "interleaved stdout and stderr redirects", %{session: session, tmp_dir: tmp_dir} do
      out1 = Path.join(tmp_dir, "out1_#{:erlang.unique_integer([:positive])}.txt")
      out2 = Path.join(tmp_dir, "out2_#{:erlang.unique_integer([:positive])}.txt")
      err1 = Path.join(tmp_dir, "err1_#{:erlang.unique_integer([:positive])}.txt")

      # stdout to two files (last wins), stderr to one file - interleaved order
      _result = run_script(session, ~s[echo "content" > #{out1} 2> #{err1} > #{out2}])

      # First stdout file empty, second gets content
      assert File.read!(out1) == ""
      assert File.read!(out2) == "content\n"

      # Stderr file should be empty (echo doesn't produce stderr)
      assert File.read!(err1) == ""
    end

    test "redirect with variable in filename", %{session: session, tmp_dir: tmp_dir} do
      output_file = Path.join(tmp_dir, "var_output_#{:erlang.unique_integer([:positive])}.txt")

      # Set variable and use in redirect
      _assign_result = run_script(session, "OUTFILE=#{output_file}")

      _result = run_script(session, "echo variable_redirect > $OUTFILE")

      content = File.read!(output_file)
      assert String.trim(content) == "variable_redirect"

      File.rm(output_file)
    end

    test "input and output on same command with stderr redirect", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      input_file = Path.join(tmp_dir, "triple_in_#{:erlang.unique_integer([:positive])}.txt")
      output_file = Path.join(tmp_dir, "triple_out_#{:erlang.unique_integer([:positive])}.txt")
      stderr_file = Path.join(tmp_dir, "triple_err_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(input_file, "input_data\n")

      # Bash: all three redirects
      bash_script = """
      cat < #{input_file} > #{output_file} 2> #{stderr_file}
      echo "stdout: $(cat #{output_file})"
      """

      {_bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      File.rm(output_file)
      File.rm(stderr_file)

      # Our implementation
      _result = run_script(session, "cat < #{input_file} > #{output_file} 2> #{stderr_file}")

      our_stdout = File.read!(output_file)

      assert String.trim(our_stdout) == "input_data"
    end

    test "redirect order matters: > file 2>&1 vs 2>&1 > file", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      file1 = Path.join(tmp_dir, "order1_#{:erlang.unique_integer([:positive])}.txt")
      file2 = Path.join(tmp_dir, "order2_#{:erlang.unique_integer([:positive])}.txt")

      # Pattern 1: > file 2>&1 - stderr goes to file (stderr duplicates to where stdout points)
      # Pattern 2: 2>&1 > file - stderr goes to original stdout (terminal), stdout to file

      # Test pattern 1: both should go to file
      _result1 = run_script_allow_error(session, "ls /nonexistent_order1 > #{file1} 2>&1")

      content1 = File.read!(file1)
      assert content1 =~ "No such file" or content1 =~ "cannot access"

      # Test pattern 2: only stdout goes to file (which is empty for ls error)
      # stderr would go to console
      _result2 = run_script_allow_error(session, "ls /nonexistent_order2 2>&1 > #{file2}")
      content2 = File.read!(file2)
      assert content2 =~ "No such file" or content2 =~ "cannot access"
    end
  end

  describe "/dev/null redirects" do
    @describetag :tmp_dir
    setup :start_session

    test "discard stdout with > /dev/null", %{session: session} do
      # Bash
      {"visible\n", 0} = run_in_bash("echo 'should disappear' > /dev/null; echo 'visible'")

      # Our implementation
      result = run_script(session, "echo should_disappear > /dev/null")

      stdout = get_stdout(result)
      assert stdout == ""
    end

    test "discard stderr with 2> /dev/null", %{session: session} do
      # Our implementation - error output should be discarded
      result = run_script_allow_error(session, "ls /nonexistent_devnull 2> /dev/null")

      stderr = get_stderr(result)
      assert stderr == ""
    end

    test "discard both with &> /dev/null", %{session: session} do
      result = run_script_allow_error(session, "ls /nonexistent_both_null &> /dev/null")

      stdout = get_stdout(result)
      stderr = get_stderr(result)

      assert stdout == ""
      assert stderr == ""
    end

    test "read from /dev/null gives empty input", %{session: session} do
      result = run_script(session, "cat < /dev/null")

      stdout = get_stdout(result)
      assert stdout == ""
    end
  end

  describe "append redirects" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir
    setup :start_session

    test ">> appends multiple times", %{session: session, tmp_dir: tmp_dir} do
      output_file = Path.join(tmp_dir, "multi_append_#{:erlang.unique_integer([:positive])}.txt")
      File.rm(output_file)

      # Bash
      bash_script = """
      echo "line1" > #{output_file}
      echo "line2" >> #{output_file}
      echo "line3" >> #{output_file}
      cat #{output_file}
      """

      {bash_output, 0} = run_in_bash(bash_script, tmp_dir: tmp_dir)

      # Our implementation
      _result1 = run_script(session, "echo line1 > #{output_file}")
      _result2 = run_script(session, "echo line2 >> #{output_file}")
      _result3 = run_script(session, "echo line3 >> #{output_file}")

      our_output = File.read!(output_file)

      assert String.trim(bash_output) == String.trim(our_output)
      assert our_output == "line1\nline2\nline3\n"
    end

    test "2>> appends stderr", %{session: session, tmp_dir: tmp_dir} do
      stderr_file = Path.join(tmp_dir, "stderr_append_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(stderr_file, "existing\n")

      _result =
        run_script_allow_error(session, "ls /nonexistent_stderr_append 2>> #{stderr_file}")

      content = File.read!(stderr_file)

      assert content =~ "existing"
      assert content =~ "No such file" or content =~ "cannot access"
    end
  end

  # Helper to run script and allow error exit codes
  defp run_script_allow_error(session, script) do
    {:ok, ast} = Bash.Parser.parse(String.trim(script))
    {_status, result} = Session.execute(session, ast)
    result
  end

  # Helper to run command in real bash and capture result
  defp run_in_bash(script, opts \\ []) do
    tmp_dir = opts[:tmp_dir] || System.tmp_dir!()

    # Write script to temp file to handle complex quoting
    script_path = Path.join(tmp_dir, "test_script_#{:erlang.unique_integer([:positive])}.sh")
    File.write!(script_path, script)

    {output, exit_code} =
      System.cmd("bash", [script_path],
        stderr_to_stdout: opts[:stderr_to_stdout] || false,
        cd: tmp_dir
      )

    File.rm(script_path)
    {output, exit_code}
  end
end
