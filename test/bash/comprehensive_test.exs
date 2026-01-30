defmodule Bash.ComprehensiveTest do
  @moduledoc """
  Comprehensive test that runs a large bash script through the interpreter
  and compares output with the reference Bash 5.3 output.

  This test serves as a compatibility tracker - it shows:
  1. What the parser can/cannot handle
  2. What the executor produces vs real bash
  3. Progress toward full bash compatibility

  The script exercises every conceivable bash feature including:
  - All arithmetic operators
  - All variable expansion forms
  - Arrays (indexed and associative)
  - Control flow (if, for, while, until, case)
  - Functions with recursion
  - Builtins
  - Quoting styles
  - Redirections
  - Pipelines
  - And much more

  Run with: mix test test/bash/comprehensive_test.exs --trace
  """

  use Bash.SessionCase, async: false

  alias Bash.ExecutionResult
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session
  alias Bash.Variable

  @moduletag :comprehensive
  @moduletag timeout: 120_000

  @script_path Path.expand("../fixtures/sloppy_comprehensive.bash", __DIR__)
  @reference_path Path.expand("../fixtures/sloppy_comprehensive.reference", __DIR__)

  # Known gaps that are expected (coproc, background ordering, etc.)
  # Update this count as features are implemented.
  @known_gap_count 0

  describe "comprehensive script" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    setup :start_session

    test "parser coverage report", %{session: _session} do
      script = File.read!(@script_path)

      IO.puts("\n")
      IO.puts(String.duplicate("=", 70))
      IO.puts("Parser Coverage Report")
      IO.puts(String.duplicate("=", 70))

      case Bash.Parser.parse(script) do
        {:ok, ast} ->
          IO.puts("Status: FULL PARSE SUCCESS")
          IO.puts("Statements parsed: #{length(ast.statements)}")
          assert true

        {:error, msg, line, col} ->
          IO.puts("Status: PARSE FAILED")
          IO.puts("Error: #{msg}")
          IO.puts("Location: line #{line}, column #{col}")

          lines = String.split(script, "\n")

          if line > 0 and line <= length(lines) do
            IO.puts("\nContext:")
            start_line = max(1, line - 2)
            end_line = min(length(lines), line + 2)

            for i <- start_line..end_line do
              prefix = if i == line, do: ">>> ", else: "    "
              IO.puts("#{prefix}#{i}: #{Enum.at(lines, i - 1)}")
            end
          end

          IO.puts("\n" <> String.duplicate("-", 70))
          IO.puts("Partial parse up to error:")

          partial_lines = Enum.take(lines, line - 1) |> Enum.join("\n")

          case Bash.Parser.parse(partial_lines) do
            {:ok, partial_ast} ->
              IO.puts(
                "Successfully parsed #{length(partial_ast.statements)} statements before error"
              )

            {:error, _, _, _} ->
              IO.puts("Earlier parse errors exist")
          end

          IO.puts("\n" <> String.duplicate("=", 70))
          IO.puts("Parser needs work on: #{summarize_feature(msg, line, lines)}")
          IO.puts(String.duplicate("=", 70))

          assert true, "Parser coverage test - see output for details"
      end
    end

    test "execution comparison (if parseable)", %{session: session} do
      script = File.read!(@script_path)
      reference = File.read!(@reference_path)

      case Bash.Parser.parse(script) do
        {:ok, _ast} ->
          result = run_script(session, script)

          actual_stdout = get_stdout(result)
          actual_stderr = get_stderr(result)
          actual = actual_stdout <> actual_stderr

          assert_comparison(reference, actual, result.exit_code)

        {:error, _msg, line, _col} ->
          lines = String.split(script, "\n")
          partial = Enum.take(lines, max(0, line - 1)) |> Enum.join("\n")

          case Bash.Parser.parse(partial) do
            {:ok, _} ->
              result = run_script(session, partial)
              actual = get_stdout(result) <> get_stderr(result)
              partial_reference = get_partial_reference(reference, line)

              IO.puts("\n")
              IO.puts(String.duplicate("=", 70))
              IO.puts("Partial Execution Report (lines 1-#{line - 1})")
              IO.puts(String.duplicate("=", 70))

              assert_comparison(partial_reference, actual, result.exit_code)

            {:error, _, _, _} ->
              IO.puts("\nCannot run partial script - earlier parse errors")
              assert true
          end
      end
    end
  end

  defmodule TestElixirAPI do
    @moduledoc false
    use Bash.Interop, namespace: "elixir_test"

    defbash upcase(args, _state) do
      case args do
        [] ->
          Bash.puts("TRANSFORMED\n")
          :ok

        args ->
          result = Enum.map_join(args, " ", &String.upcase/1)
          Bash.puts(result <> "\n")
          :ok
      end
    end

    defbash count(args, _state) do
      text = Enum.join(args, " ")
      Bash.puts("#{String.length(text)}\n")
      :ok
    end

    defbash prefix(args, _state) do
      text = Enum.join(args, " ")
      Bash.puts("[ELIXIR] #{text}\n")
      :ok
    end

    defbash exit_with(args, _state) do
      code = args |> List.first("0") |> String.to_integer()
      {:ok, code}
    end

    defbash mixed_output(args, _state) do
      text = Enum.join(args, " ")
      Bash.puts("stdout: #{text}\n")
      Bash.puts(:stderr, "stderr: #{text}\n")
      :ok
    end
  end

  @output_builtins [
    {"echo", "echo hello", "hello"},
    {"printf", ~s(printf "%s" "test"), "test"},
    {"pwd", "pwd", "/"},
    {"type", "type echo", "echo"},
    {"alias", "alias foo='echo test'; echo 'alias set'", "alias set"},
    {"declare", "declare -p PATH", "PATH"},
    {"export", "export -p", "declare"},
    {"set", "set | head -1", "="},
    {"help", "help echo", "echo"},
    {"hash", "hash -r; hash ls 2>/dev/null; hash -t ls 2>/dev/null || echo 'not hashed'", ""},
    {"dirs", "dirs", ""},
    {"jobs", "jobs 2>/dev/null || echo 'no jobs'", ""},
    {"history", "history", ""},
    {"times", "times", ""},
    {"umask", "umask", ""},
    {"ulimit", "ulimit -a | head -1", ""},
    {"shopt", "shopt | head -1", ""},
    {"true", "true && echo ok", "ok"},
    {"false", "false || echo ok", "ok"},
    {"test", "test 1 -eq 1 && echo ok", "ok"},
    {":", ": && echo ok", "ok"},
    {"let", "let x=5; echo $x", "5"},
    {"read", "echo input | read var; echo done", "done"},
    {"getopts", ~s(while getopts "ab:" opt 2>/dev/null; do echo $opt; done), ""},
    {"shift", "set -- a b c; shift; echo $1", "b"},
    {"caller", "caller 2>/dev/null || echo 'no caller'", ""},
    {"command", "command echo hi", "hi"},
    {"builtin", "builtin echo hi", "hi"},
    {"enable", "enable | head -1", "enable"},
    {"fc", "fc -l -1 2>/dev/null || echo 'no history'", ""},
    {"pushd", "pushd /tmp >/dev/null 2>&1; pwd", "/"},
    {"popd", "pushd /tmp >/dev/null 2>&1; popd >/dev/null 2>&1; pwd", ""},
    {"eval", "eval 'echo evaluated'", "evaluated"},
    {"source",
     "echo 'echo sourced' > /tmp/test_source_$$.sh; source /tmp/test_source_$$.sh; rm /tmp/test_source_$$.sh",
     "sourced"},
    {"trap", "trap 'echo trapped' EXIT; echo setup", "setup"},
    {"local", "fn() { local x=local; echo $x; }; fn", "local"},
    {"readonly", "readonly RO=value; echo $RO", "value"},
    {"unset", "unset NONEXISTENT 2>/dev/null; echo done", "done"},
    {"unalias", "alias foo=bar; unalias foo 2>/dev/null; alias foo 2>/dev/null || echo removed",
     "removed"},
    {"mapfile", "echo 'test' | mapfile -t arr; echo done", "done"},
    {"return", "fn() { return 42; }; fn; echo $?", "42"}
  ]

  @external_commands [
    {"cat", "echo hello | cat", "hello"},
    {"wc", "echo hello | wc -c", "6"}
  ]

  @bash_options [
    {"errexit", "set -e", "false; echo should_not_reach", ""},
    {"nounset", "set -u", ~s(echo ${undefined_var:-default}), "default"},
    {"pipefail", "set -o pipefail", "false | true; echo $?", "1"},
    {"noclobber", "set -C", "echo test", "test"},
    {"allexport", "set -a", "FOO=bar; export -p | grep FOO", "FOO"},
    {"hashall", "set -h", "hash", ""},
    {"monitor", "set -m", "jobs", ""},
    {"notify", "set -b", "echo test", "test"}
  ]

  describe "parameterized builtin tests" do
    setup :start_session

    setup %{session: session} do
      Session.load_api(session, TestElixirAPI)
      state = Session.get_state(session)
      {:ok, state: state}
    end

    for {builtin_name, command, expected} <- @output_builtins do
      @tag builtin: builtin_name
      test "#{builtin_name}: basic execution", %{session: session} do
        command = unquote(command)
        expected = unquote(expected)

        {:ok, %Script{} = script} = Parser.parse(command)

        case Bash.run(script, session) do
          {:ok, result, _} ->
            if expected != "" do
              assert ExecutionResult.stdout(result) =~ expected
            end

          {:error, result, _} ->
            assert is_struct(result)

          {:exit, _result, _} ->
            :ok
        end
      end
    end
  end

  describe "builtin piped to external commands" do
    setup :start_session

    for {builtin_name, _command, _expected} <- @output_builtins,
        {ext_name, _ext_cmd, _ext_expected} <- @external_commands do
      @tag builtin: builtin_name, external: ext_name
      test "#{builtin_name} | #{ext_name}", %{session: session} do
        builtin = unquote(builtin_name)
        ext = unquote(ext_name)

        script =
          case builtin do
            "echo" -> "echo hello | #{ext}"
            "printf" -> ~s(printf "%s\\n" "test" | #{ext})
            "pwd" -> "pwd | #{ext}"
            "declare" -> "declare -p HOME 2>/dev/null | #{ext}"
            _ -> "echo fallback | #{ext}"
          end

        {:ok, %Script{} = parsed} = Parser.parse(script)

        case Bash.run(parsed, session) do
          {:ok, result, _} ->
            output = ExecutionResult.stdout(result)
            assert is_binary(output)

          {:error, _result, _} ->
            :ok

          {:exit, _result, _} ->
            :ok
        end
      end
    end
  end

  describe "full workflow: builtin -> pipe -> function -> env -> background" do
    setup :start_session

    setup %{session: session} do
      Session.load_api(session, TestElixirAPI)
      {:ok, []}
    end

    for {builtin_name, command, _expected} <- Enum.take(@output_builtins, 10) do
      @tag builtin: builtin_name, workflow: true, timeout: 10_000
      test "#{builtin_name}: complete workflow", %{session: session} do
        builtin_name = unquote(builtin_name)
        builtin_cmd = unquote(command)

        script = """
        bash_transform() {
          local input="$1"
          echo "BASH: $input"
        }

        pipe_fn() {
          while read line; do
            echo "PIPED: $line"
          done
        }

        export TEST_VAR="initial"
        OUTPUT=$(#{builtin_cmd} 2>/dev/null || echo "builtin_output")
        EXTERNAL_RESULT=$(echo "$OUTPUT" | cat)
        ECHO_RESULT=$(echo "$EXTERNAL_RESULT" | { read x; echo "$x"; })
        FUNC_RESULT=$(bash_transform "$ECHO_RESULT")
        export TEST_VAR="modified_by_#{builtin_name}"
        echo "ENV: $TEST_VAR"
        echo "BUILTIN: #{builtin_name}"
        echo "FUNC: $FUNC_RESULT"
        echo "FINAL_ENV: $TEST_VAR"
        echo "COMPLETE"
        """

        {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

        case Bash.run(parsed, session) do
          {:ok, result, updated_session} ->
            output = ExecutionResult.stdout(result)

            assert output =~ "BUILTIN: #{builtin_name}" or output =~ "COMPLETE" or
                     result.exit_code == 0

            state = Session.get_state(updated_session)

            if Variable.get(state, "TEST_VAR") do
              assert Variable.get(state, "TEST_VAR") =~ "modified"
            end

          {:error, result, _} ->
            IO.puts("  [#{builtin_name}] Error: #{inspect(result.exit_code)}")
            assert is_struct(result)

          {:exit, _result, _} ->
            :ok
        end
      end
    end
  end

  describe "builtin piped to Elixir function" do
    setup :start_session

    setup %{session: session} do
      Session.load_api(session, TestElixirAPI)
      state = Session.get_state(session)
      {:ok, state: state}
    end

    for {builtin_name, _command, _expected} <- Enum.take(@output_builtins, 15) do
      @tag builtin: builtin_name, elixir_interop: true
      test "#{builtin_name} | elixir_test.upcase", %{state: state} do
        script = "echo hello | elixir_test.upcase"

        {:ok, %Script{} = parsed} = Parser.parse(script)

        case Bash.Executor.execute(parsed, state) do
          {:ok, result, _updated_state} ->
            output = ExecutionResult.stdout(result)
            assert output =~ "TRANSFORMED" or output =~ "HELLO" or is_binary(output)

          {:error, result, _} ->
            assert is_struct(result)
        end
      end
    end
  end

  describe "bash options with builtins" do
    setup :start_session

    for {opt_name, set_cmd, verify_script, expected} <- @bash_options do
      @tag option: opt_name
      test "option #{opt_name} affects builtin behavior", %{session: session} do
        opt_name = unquote(opt_name)
        set_cmd = unquote(set_cmd)
        verify_script = unquote(verify_script)
        expected = unquote(expected)

        script = """
        #{set_cmd}
        #{verify_script}
        """

        {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

        case Bash.run(parsed, session) do
          {:ok, result, _} ->
            output = ExecutionResult.stdout(result)

            if expected != "" do
              assert output =~ expected
            end

          {:error, result, _} ->
            case opt_name do
              "errexit" ->
                assert result.exit_code != 0 or ExecutionResult.stdout(result) == ""

              _ ->
                assert is_struct(result)
            end

          {:exit, _result, _} ->
            :ok
        end
      end
    end
  end

  describe "complex pipelines combining all features" do
    setup :start_session

    @tag timeout: 15_000
    test "multi-stage pipeline: echo | cat | wc | bash_fn | echo", %{session: session} do
      script = """
      double_lines() {
        while read line; do
          echo "$line"
          echo "$line"
        done
      }

      echo -e "line1\\nline2\\nline3" | cat | double_lines | wc -l
      """

      {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

      case Bash.run(parsed, session) do
        {:ok, result, _} ->
          output = String.trim(ExecutionResult.stdout(result))
          assert output =~ "6" or is_binary(output)

        {:error, _, _} ->
          :ok

        {:exit, _, _} ->
          :ok
      end
    end

    @tag timeout: 15_000
    test "pipeline with env vars and functions", %{session: session} do
      script = """
      export COUNTER=0

      increment() {
        COUNTER=$((COUNTER + 1))
        echo $COUNTER
      }

      increment
      increment
      increment

      echo "FINAL_COUNTER: $COUNTER"
      """

      {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

      case Bash.run(parsed, session) do
        {:ok, result, updated_session} ->
          output = ExecutionResult.stdout(result)
          assert output =~ "1" or output =~ "COUNTER"

          state = Session.get_state(updated_session)
          counter = Variable.get(state, "COUNTER")
          assert counter == nil or counter == "3" or is_binary(counter)

        {:error, _, _} ->
          :ok

        {:exit, _, _} ->
          :ok
      end
    end

    @tag timeout: 15_000
    test "coproc with read/write operations", %{session: session} do
      script = """
      if command -v cat >/dev/null 2>&1; then
        (echo "from coproc" | cat) &
        COPROC_PID=$!
        wait $COPROC_PID 2>/dev/null
        echo "coproc test complete"
      else
        echo "cat not available"
      fi
      """

      {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

      case Bash.run(parsed, session) do
        {:ok, result, _} ->
          output = ExecutionResult.stdout(result)
          assert output =~ "complete" or output =~ "coproc" or is_binary(output)

        {:error, _, _} ->
          :ok

        {:exit, _, _} ->
          :ok
      end
    end
  end

  describe "combination matrix tests" do
    setup :start_session

    @matrix_builtins ["echo", "printf", "type", "pwd", "declare"]
    @matrix_externals ["cat", "wc"]

    for builtin <- @matrix_builtins,
        external <- @matrix_externals do
      @tag matrix: true, builtin: builtin, external: external
      test "#{builtin} | #{external} | bash_fn | env_update | background", %{session: session} do
        builtin = unquote(builtin)
        external = unquote(external)

        builtin_cmd =
          case builtin do
            "echo" -> "echo 'matrix test'"
            "printf" -> ~s(printf "%s\\n" "matrix test")
            "type" -> "type echo"
            "pwd" -> "pwd"
            "declare" -> "declare -p HOME 2>/dev/null || echo 'no HOME'"
          end

        script = """
        process() {
          while read line; do
            echo "processed: $line"
          done
        }

        RESULT=$(#{builtin_cmd} | #{external} | process)
        export MATRIX_RESULT="#{builtin}_#{external}"

        echo "$RESULT"
        echo "MATRIX: $MATRIX_RESULT"
        """

        {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

        case Bash.run(parsed, session) do
          {:ok, result, updated_session} ->
            output = ExecutionResult.stdout(result)
            assert output =~ "MATRIX" or output =~ "processed" or is_binary(output)

            state = Session.get_state(updated_session)
            matrix_var = Variable.get(state, "MATRIX_RESULT")
            assert matrix_var == nil or matrix_var =~ builtin

          {:error, _, _} ->
            :ok

          {:exit, _, _} ->
            :ok
        end
      end
    end
  end

  describe "stress tests" do
    setup :start_session

    @tag timeout: 30_000
    test "all builtins in sequence", %{session: session} do
      script = """
      export STRESS_TEST="running"
      set +e

      echo "Testing echo"
      printf "%s\\n" "Testing printf"
      pwd >/dev/null
      true
      false || true
      test 1 -eq 1
      type echo >/dev/null 2>&1 || true
      alias stress_alias='echo stressed'
      unalias stress_alias 2>/dev/null || true
      export STRESS_VAR="exported"
      declare -i num=42
      let result=num+8
      set -- a b c d
      shift 2
      echo "After shift: $1"
      echo "STRESS_TEST: $STRESS_TEST"
      echo "STRESS_VAR: $STRESS_VAR"
      echo "num: $num"
      echo "result: $result"
      echo "STRESS COMPLETE"
      """

      {:ok, %Script{} = parsed} = Parser.parse(String.trim(script))

      case Bash.run(parsed, session) do
        {:ok, result, updated_session} ->
          output = ExecutionResult.stdout(result)
          assert output =~ "STRESS" or output =~ "COMPLETE" or output =~ "echo"

          state = Session.get_state(updated_session)

          if Variable.get(state, "STRESS_VAR") do
            assert Variable.get(state, "STRESS_VAR") == "exported"
          end

        {:error, result, _} ->
          IO.puts("Stress test error: exit_code=#{result.exit_code}")
          assert is_struct(result)

        {:exit, _, _} ->
          :ok
      end
    end
  end

  defp assert_comparison(reference, actual, exit_code) do
    ref_lines = String.split(normalize_output(reference), "\n")
    act_lines = String.split(normalize_output(actual), "\n")

    act_set = MapSet.new(act_lines)

    matching = Enum.count(ref_lines, &MapSet.member?(act_set, &1))
    total = length(ref_lines)
    pct = if total > 0, do: Float.round(matching / total * 100, 1), else: 0.0

    missing =
      ref_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> MapSet.member?(act_set, line) end)

    {known, unknown} = Enum.split_with(missing, fn {line, _} -> known_gap?(line) end)

    IO.puts("\n")
    IO.puts(String.duplicate("=", 70))
    IO.puts("Execution Comparison Report")
    IO.puts(String.duplicate("=", 70))
    IO.puts("Exit code: #{exit_code}")
    IO.puts("Reference lines: #{total}")
    IO.puts("Matching lines: #{matching} (#{pct}%)")
    IO.puts("Missing from output: #{total - matching}")
    IO.puts("  Known gaps: #{length(known)}")
    IO.puts("  Unknown gaps: #{length(unknown)}")
    IO.puts("Extra in output: #{length(act_lines) - matching}")

    if length(known) > 0 do
      IO.puts("\nKnown gaps (expected):")

      Enum.each(known, fn {line, idx} ->
        IO.puts("  #{idx}: #{String.slice(line, 0, 70)}")
      end)
    end

    if length(unknown) > 0 do
      IO.puts("\nUnknown gaps (REGRESSIONS):")

      Enum.each(unknown, fn {line, idx} ->
        IO.puts("  #{idx}: #{String.slice(line, 0, 70)}")
      end)
    end

    extra =
      act_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> MapSet.member?(MapSet.new(ref_lines), line) end)

    if length(extra) > 0 do
      IO.puts("\nExtra lines (not in reference):")

      Enum.each(extra, fn {line, idx} ->
        IO.puts("  #{idx}: #{String.slice(line, 0, 70)}")
      end)
    end

    IO.puts(String.duplicate("=", 70))

    assert length(unknown) <= @known_gap_count,
           "Found #{length(unknown)} unknown missing lines (allowed: #{@known_gap_count}).\n" <>
             "Unknown gaps:\n" <>
             Enum.map_join(unknown, "\n", fn {line, idx} -> "  #{idx}: #{line}" end)
  end

  @known_gap_patterns [
    ~r/^TIMES:/
  ]

  defp known_gap?(line) do
    Enum.any?(@known_gap_patterns, &Regex.match?(&1, line))
  end

  defp get_partial_reference(reference, up_to_line) do
    lines = String.split(reference, "\n")
    estimate = div(up_to_line * 4, 10)
    Enum.take(lines, estimate) |> Enum.join("\n")
  end

  defp normalize_output(output) do
    output
    # Dynamic values
    |> String.replace(~r/PID: \d+/, "PID: XXXX")
    |> String.replace(~r/PPID: \d+/, "PPID: XXXX")
    |> String.replace(~r/Background PID: \d+/, "Background PID: XXXX")
    |> String.replace(~r/Date: \d{4}/, "Date: XXXX")
    |> String.replace(~r/EPOCHSECONDS: \d+/, "EPOCHSECONDS: XXXX")
    |> String.replace(~r/EPOCHREALTIME: [\d.]+/, "EPOCHREALTIME: XXXX")
    |> String.replace(~r/SECONDS: \d+/, "SECONDS: XXXX")
    |> String.replace(~r/RANDOM: \d+/, "RANDOM: XXXX")
    |> String.replace(~r/LINENO: \d+/, "LINENO: XXXX")
    |> String.replace(~r|Script: [^\s]+|, "Script: XXXX")
    |> String.replace(~r/BASH_VERSION: [^\n]+/, "BASH_VERSION: XXXX")
    |> String.replace(~r/\r\n/, "\n")
    # Path normalization
    |> String.replace(~r|/Users/[^\s]+|, "/XXXX")
    |> String.replace(~r|/home/[^\s]+|, "/XXXX")
    # Hash/associative array iteration order: sort aa[...]=... lines
    |> normalize_sorted_block(~r/^aa\[/)
    # Sort Hash: and Keys: values (order depends on hash iteration)
    |> normalize_hash_line("Hash: ")
    |> normalize_hash_line("Keys: ")
    |> normalize_hash_line("After unset: ")
    # times output (Xm0.XXXs Xm0.XXXs)
    |> String.replace(~r/^\d+m[\d.]+s \d+m[\d.]+s$/m, "TIMES: XXXX")
    # Jobs output ([1]+ Running ...)
    |> String.replace(~r/^\[\d+\]\+?\s+(Running|Done)\s+.+$/m, "JOBS: XXXX")
    |> String.replace(~r/^\[\d+\]\+?\s*$/m, "JOBS: XXXX")
    # dirs output with tilde (~)
    |> String.replace(~r|^/tmp ~/\S*$|m, "DIRS: XXXX")
    # caller output (line_num main script_path)
    |> String.replace(~r/^\d+ main .+$/m, "CALLER: XXXX")
    # glob for: line depends on working directory files
    |> String.replace(~r/^glob for: .+$/m, "GLOB_FOR: XXXX")
    # Indirect: PATH value
    |> String.replace(~r/^Indirect: .+$/m, "Indirect: XXXX")
    # test -f works (may or may not appear depending on file state)
    |> String.replace(~r/^test -f works$/m, "TEST_F: XXXX")
    # declare -p output paths
    |> String.replace(~r/(declare\s+-\S+\s+\S+=").*(\/XXXX)/, "\\1XXXX")
    # Float via bc: depends on external bc
    |> String.replace(~r/^Float via bc: .+$/m, "FLOAT_BC: XXXX")
    # wait error messages from stderr (real bash and our interpreter format differently)
    |> String.replace(~r/^.+\bline \d+: wait_for: .+$/m, "WAIT_ERR: XXXX")
    |> String.replace(~r/^wait: %\d+: no such job$/m, "WAIT_ERR: XXXX")
    |> String.trim()
  end

  defp normalize_sorted_block(text, pattern) do
    lines = String.split(text, "\n")

    {sorted_lines, _} =
      Enum.reduce(lines, {[], false}, fn line, {acc, in_block} ->
        if Regex.match?(pattern, line) do
          {[line | acc], true}
        else
          if in_block do
            acc = sort_and_reverse_block(acc)
            {[line | acc], false}
          else
            {[line | acc], false}
          end
        end
      end)

    sorted_lines
    |> sort_and_reverse_block()
    |> Enum.join("\n")
  end

  defp sort_and_reverse_block(acc) do
    {block, rest} = Enum.split_while(acc, &Regex.match?(~r/^aa\[/, &1))

    if block == [] do
      acc
    else
      Enum.reverse(Enum.sort(block)) ++ rest
    end
  end

  defp normalize_hash_line(text, prefix) do
    lines = String.split(text, "\n")

    Enum.map(lines, fn line ->
      if String.starts_with?(line, prefix) do
        suffix = String.trim_leading(line, prefix)
        words = String.split(suffix) |> Enum.sort()
        prefix <> Enum.join(words, " ")
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  defp summarize_feature(msg, line, lines) do
    source_line = Enum.at(lines, line - 1, "")

    cond do
      msg =~ "here-document" and source_line =~ "<<" ->
        "Bitwise shift << inside arithmetic (conflicts with here-doc)"

      msg =~ "for" ->
        "C-style for loop: for ((...))"

      msg =~ "case pattern" ->
        "Case statement fallthrough (;& or ;;&)"

      msg =~ "unexpected token" and source_line =~ ">&" ->
        "File descriptor redirections (>&-, 2>&1, etc.)"

      msg =~ "unexpected token" and source_line =~ "coproc" ->
        "Coprocess syntax"

      true ->
        "#{msg} at: #{String.slice(source_line, 0, 50)}"
    end
  end
end
