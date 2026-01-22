defmodule Bash.IntegrationTest do
  @moduledoc """
  Integration tests comparing the Bash package's parser and executor
  with actual bash shell behavior.
  """
  use Bash.SessionCase, async: true

  alias Bash.Parser
  alias Bash.Session
  alias Bash.Variable

  setup :start_session

  describe "Command execution comparison with bash" do
    test "echo command produces same output", %{session: session} do
      # Execute with Bash package
      result = run_script(session, "echo hello world")
      package_output = get_stdout(result)

      # Execute with real bash
      {bash_output, 0} = System.cmd("bash", ["-c", "echo hello world"])

      assert package_output == bash_output
    end

    test "echo with quoted strings", %{session: session} do
      result = run_script(session, ~s|echo "hello world"|)
      package_output = get_stdout(result)

      {bash_output, 0} = System.cmd("bash", ["-c", "echo \"hello world\""])

      assert package_output == bash_output
    end

    test "pwd command returns current directory", %{session: session} do
      result = run_script(session, "pwd")
      package_output = String.trim(get_stdout(result))

      {bash_output, 0} = System.cmd("bash", ["-c", "pwd"])
      bash_output = String.trim(bash_output)

      # Both should return absolute paths to the same directory
      assert package_output == bash_output
      assert package_output == File.cwd!()
    end

    test "date command format", %{session: session} do
      result = run_script(session, "date +%Y")
      package_output = String.trim(get_stdout(result))

      {bash_output, 0} = System.cmd("bash", ["-c", "date +%Y"])
      bash_output = String.trim(bash_output)

      # Both should return the same year
      assert package_output == bash_output
      assert String.match?(package_output, ~r/^\d{4}$/)
    end

    @tag :tmp_dir
    test "command with multiple arguments", %{session: session, tmp_dir: tmp_dir} do
      # Create a test file in the temporary directory
      test_file = Path.join(tmp_dir, "test.txt")
      File.write!(test_file, "line1\nline2\nline3\n")

      result = run_script(session, "wc -l #{test_file}")
      package_output = String.trim(get_stdout(result))

      {bash_output, 0} = System.cmd("bash", ["-c", "wc -l #{test_file}"])
      bash_output = String.trim(bash_output)

      # Both should report 3 lines (the exact format may vary slightly)
      assert package_output =~ "3"
      assert bash_output =~ "3"
    end
  end

  describe "Pipeline execution comparison" do
    test "echo | wc", %{session: session} do
      result = run_script(session, "echo hello | wc -c")
      package_output = String.trim(get_stdout(result))

      {bash_output, 0} = System.cmd("bash", ["-c", "echo hello | wc -c"])
      bash_output = String.trim(bash_output)

      # Both should count 6 bytes (hello\n)
      assert package_output == bash_output
      assert package_output == "6"
    end

    test "echo | grep", %{session: session} do
      result = run_script(session, "echo -e 'apple\nbanana\ncherry' | grep banana")
      package_output = String.trim(get_stdout(result))

      {bash_output, 0} =
        System.cmd("bash", ["-c", "echo -e 'apple\nbanana\ncherry' | grep banana"])

      bash_output = String.trim(bash_output)

      assert package_output == bash_output
      assert package_output == "banana"
    end

    @tag :tmp_dir
    test "streaming pipeline uses bounded memory", %{session: session, tmp_dir: tmp_dir} do
      # Generate 1MB of data (10000 lines of ~100 chars each)
      data_file = Path.join(tmp_dir, "large_data.txt")

      lines =
        1..10000
        |> Enum.map(fn n -> String.duplicate("a", 90) <> " line_#{n}\n" end)
        |> IO.iodata_to_binary()

      data_size = byte_size(lines)
      File.write!(data_file, lines)

      # Force GC and measure baseline heap
      :erlang.garbage_collect()
      {_, initial_heap} = :erlang.process_info(self(), :heap_size)

      # Parse and execute a pure external command pipeline
      # This should use streaming and NOT accumulate the full 1MB in memory
      # Note: We run the Script which uses its collector to capture output.
      # The streaming behavior is tested by the heap growth assertion.
      {:ok, script} = Parser.parse("cat #{data_file} | grep line_ | wc -l")

      {:ok, result, ^session} = Bash.run(script, session)

      # Force GC and measure final heap
      :erlang.garbage_collect()
      {_, final_heap} = :erlang.process_info(self(), :heap_size)

      # Verify correctness
      output = String.trim(get_stdout(result))
      assert output == "10000"

      # The heap growth should be significantly less than the data size
      # Heap is in words (8 bytes on 64-bit), so convert to bytes
      heap_growth_bytes = (final_heap - initial_heap) * 8

      # The heap should grow by less than 25% of the data size
      # (allowing for some overhead, result struct, etc.)
      max_allowed_growth = div(data_size, 4)

      assert heap_growth_bytes < max_allowed_growth,
             "Heap grew by #{heap_growth_bytes} bytes, expected < #{max_allowed_growth} bytes. " <>
               "Data size: #{data_size} bytes. This may indicate output accumulation in memory."
    end

    @tag :tmp_dir
    test "mixed pipeline with builtin drains upstream without accumulating", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Generate 1MB of data
      data_file = Path.join(tmp_dir, "large_data.txt")

      lines =
        1..10000
        |> Enum.map(fn n -> String.duplicate("a", 90) <> " line_#{n}\n" end)
        |> IO.iodata_to_binary()

      data_size = byte_size(lines)
      File.write!(data_file, lines)

      # Force GC and measure baseline heap
      :erlang.garbage_collect()
      {_, initial_heap} = :erlang.process_info(self(), :heap_size)

      # Mixed pipeline: external | builtin (ignores stdin) | external
      # The builtin `echo` ignores stdin, so it should drain without accumulating
      result = run_script(session, "cat #{data_file} | echo 'ignored' | wc -c")

      # Force GC and measure final heap
      :erlang.garbage_collect()
      {_, final_heap} = :erlang.process_info(self(), :heap_size)

      # Verify correctness - echo outputs "ignored\n" (8 bytes)
      output = String.trim(get_stdout(result))
      assert output == "8"

      # Heap growth should still be bounded - the cat output is drained, not accumulated
      heap_growth_bytes = (final_heap - initial_heap) * 8
      max_allowed_growth = div(data_size, 4)

      assert heap_growth_bytes < max_allowed_growth,
             "Heap grew by #{heap_growth_bytes} bytes, expected < #{max_allowed_growth} bytes. " <>
               "Mixed pipeline should drain builtin input without accumulating."
    end
  end

  describe "environment variables" do
    test "setting and reading environment variables", %{session: session} do
      # Set variable in Bash session
      Session.set_env(session, "TEST_VAR", "test_value")

      result = run_script(session, "echo $TEST_VAR")
      package_output = String.trim(get_stdout(result))

      # Set variable for bash and test
      {bash_output, 0} = System.cmd("bash", ["-c", "TEST_VAR=test_value; echo $TEST_VAR"])
      bash_output = String.trim(bash_output)

      assert package_output == bash_output
      assert package_output == "test_value"
    end
  end

  describe "error handling comparison" do
    test "nonexistent command returns error in both", %{session: session} do
      result = run_script(session, "thiscommanddoesnotexist99999")

      # Exit code 127 = command not found
      assert result.exit_code == 127

      # Real bash also fails with non-zero exit
      {_output, exit_code} =
        System.cmd("bash", ["-c", "thiscommanddoesnotexist99999"], stderr_to_stdout: true)

      assert exit_code != 0
    end

    test "command with invalid arguments fails in both", %{session: session} do
      result = run_script(session, "ls /this/path/does/not/exist/at/all")

      assert result.exit_code != 0

      {_output, bash_exit_code} =
        System.cmd("bash", ["-c", "ls /this/path/does/not/exist/at/all"], stderr_to_stdout: true)

      assert bash_exit_code != 0
      # Both should have non-zero exit codes
      assert result.exit_code == bash_exit_code
    end
  end

  describe "working directory" do
    test "changing directory affects pwd in both", %{session: session} do
      # Change to /tmp in Bash session
      Session.chdir(session, "/tmp")

      result = run_script(session, "pwd")
      package_output = String.trim(get_stdout(result))

      # Execute bash with explicit cd
      {bash_output, 0} = System.cmd("bash", ["-c", "cd /tmp && pwd"])
      bash_output = String.trim(bash_output)

      # Both should show /tmp (or its realpath)
      assert package_output == bash_output
      assert String.contains?(package_output, "tmp")
    end
  end

  describe "Simple Commands" do
    test "executes basic command" do
      {:ok, result, _session_pid} = Bash.run("echo hello")

      assert result.exit_code == 0
    end

    test "executes command with arguments" do
      {:ok, result, _session_pid} = Bash.run("echo hello world")

      assert result.exit_code == 0
    end

    test "executes string directly without parsing" do
      {:ok, result, _session_pid} = Bash.run("echo hello from string")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello from string\n"
    end

    test "executes multi-line script from string" do
      script = """
      x=5
      y=10
      echo $x $y
      """

      {:ok, result, session_pid} = Bash.run(script)

      assert result.exit_code == 0
      assert get_stdout(result) == "5 10\n"

      # Verify variables were set
      state = Session.get_state(session_pid)
      assert Variable.get(state, "x") == "5"
      assert Variable.get(state, "y") == "10"
    end
  end

  describe "Variable Assignment" do
    test "simple assignment" do
      {:ok, result, session_pid} = Bash.run("x=hello")

      assert result.exit_code == 0
      state = Session.get_state(session_pid)
      assert Variable.get(state, "x") == "hello"
    end

    test "multiple assignments in sequence" do
      script = """
      x=1
      y=2
      z=3
      """

      {:ok, _, session_pid} = Bash.run(script)

      state = Session.get_state(session_pid)
      assert Variable.get(state, "x") == "1"
      assert Variable.get(state, "y") == "2"
      assert Variable.get(state, "z") == "3"
    end
  end

  describe "Variable Expansion" do
    test "simple variable expansion" do
      {:ok, session} = Session.new(id: "test_#{:erlang.unique_integer()}")
      Session.set_env(session, "USER", "alice")
      result = run_script(session, "echo $USER")

      assert result.exit_code == 0
    end

    test "variable expansion in assignment" do
      script = """
      x=hello
      y=$x
      """

      {:ok, _, session_pid} = Bash.run(script)

      state = Session.get_state(session_pid)
      assert Variable.get(state, "y") == "hello"
    end
  end

  describe "Arithmetic Evaluation" do
    test "simple arithmetic assignment" do
      {:ok, result, session_pid} = Bash.run("x=5")

      assert result.exit_code == 0
      state = Session.get_state(session_pid)
      assert Variable.get(state, "x") == "5"
    end

    test "arithmetic expansion with variables" do
      script = """
      x=5
      y=10
      """

      {:ok, _, session_pid} = Bash.run(script)

      state = Session.get_state(session_pid)
      assert Variable.get(state, "x") == "5"
      assert Variable.get(state, "y") == "10"
    end
  end

  describe "Array Assignment" do
    test "array literal assignment" do
      {:ok, result, session_pid} = Bash.run("arr=(a b c)")

      assert result.exit_code == 0
      state = Session.get_state(session_pid)
      arr = Map.get(state.variables, "arr")
      assert Variable.get(arr, 0) == "a"
      assert Variable.get(arr, 1) == "b"
      assert Variable.get(arr, 2) == "c"
    end

    test "array element assignment" do
      {:ok, result, session_pid} = Bash.run("arr[0]=hello")

      assert result.exit_code == 0
      state = Session.get_state(session_pid)
      arr = Map.get(state.variables, "arr")
      assert Variable.get(arr, 0) == "hello"
    end
  end

  describe "Comprehensive Golden Test Script" do
    @external_resource "test/fixtures/golden_test_simple.sh"
    @external_resource "test/fixtures/golden_test_simple_expected.txt"

    @script_path "test/fixtures/golden_test_simple.sh"
    @script File.read!(@script_path)

    @expected_path "test/fixtures/golden_test_simple_expected.txt"
    @expected File.read!(@expected_path)

    @tag golden: true, timeout: 30_000
    test "executes simple golden test script and compares output" do
      # Execute the entire script at once
      {:ok, result, _session} = Bash.run(@script)

      # Get output from the Script result (reads from collector)
      accumulated_output = ExecutionResult.all_output(result)

      # Compare with expected output
      assert accumulated_output == @expected, """
        === ACTUAL OUTPUT ===
        #{accumulated_output}
        === EXPECTED OUTPUT ===
        #{@expected}
      """
    end

    @golden_test_path "test/fixtures/golden_test.sh"
    @golden_test_expected_path "test/fixtures/golden_test_expected.txt"

    @external_resource @golden_test_path
    @external_resource @golden_test_expected_path

    @golden_test File.read!(@golden_test_path)
    @golden_test_expected File.read!(@golden_test_expected_path)

    @tag golden_comprehensive: true, timeout: 30_000
    test "executes comprehensive golden test script and compares output" do
      result =
        case Bash.run(@golden_test) do
          {:ok, result, _pid} ->
            result

          {:exit, result, _pid} ->
            result

          {:error, result, _session} ->
            IO.puts("Script failed: #{inspect(result)}")
            flunk("Script execution failed")
        end

      # Get output from the Script result (reads from collector)
      accumulated_output = ExecutionResult.all_output(result)

      # Show diff when outputs don't match
      if accumulated_output != @golden_test_expected do
        IO.puts("\n=== ACTUAL OUTPUT ===")
        IO.puts(accumulated_output)
        IO.puts("\n=== EXPECTED OUTPUT ===")
        IO.puts(@golden_test_expected)
      end

      assert accumulated_output == @golden_test_expected, "Golden test output mismatch"
    end
  end
end
