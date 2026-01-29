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

  use Bash.SessionCase, async: true

  @moduletag :comprehensive
  @moduletag timeout: 120_000

  @script_path Path.expand("../fixtures/sloppy_comprehensive.bash", __DIR__)
  @reference_path Path.expand("../fixtures/sloppy_comprehensive.reference", __DIR__)

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

          # Show context around the error
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

          # Report what DID parse successfully
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

          # This is informational - we want to track progress, not fail
          IO.puts("\n" <> String.duplicate("=", 70))
          IO.puts("Parser needs work on: #{summarize_feature(msg, line, lines)}")
          IO.puts(String.duplicate("=", 70))

          # Don't fail the test - this is a coverage report
          assert true, "Parser coverage test - see output for details"
      end
    end

    test "execution comparison (if parseable)", %{session: session} do
      script = File.read!(@script_path)
      reference = File.read!(@reference_path)

      case Bash.Parser.parse(script) do
        {:ok, _ast} ->
          # Full script parses - run it and compare
          result = run_script(session, script)

          actual_stdout = get_stdout(result)
          actual_stderr = get_stderr(result)
          actual = actual_stdout <> actual_stderr

          report_comparison(reference, actual, result.exit_code)

        {:error, _msg, line, _col} ->
          # Script doesn't fully parse - try running what we can
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

              report_comparison(partial_reference, actual, result.exit_code)

            {:error, _, _, _} ->
              IO.puts("\nCannot run partial script - earlier parse errors")
              assert true
          end
      end
    end
  end

  describe "individual feature tests" do
    setup :start_session

    test "arithmetic operators", %{session: session} do
      result =
        run_script(session, """
        x=5;y=3
        echo "Basic: $((x+y)) $((x-y)) $((x*y)) $((x/y)) $((x%y)) $((x**y))"
        echo "Comparison: $((x<y)) $((x>y)) $((x<=y)) $((x>=y)) $((x==y)) $((x!=y))"
        echo "Logical: $((x&&y)) $((x||y)) $((!x))"
        echo "Ternary: $((x>y?1:0))"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "Basic: 8 2 15 1 2 125"
      assert stdout =~ "Comparison: 0 1 0 1 0 1"
      assert stdout =~ "Logical: 1 1 0"
      assert stdout =~ "Ternary: 1"
    end

    test "variable expansion", %{session: session} do
      result =
        run_script(session, """
        myvar="hello world"
        echo "${myvar}" "${#myvar}" "${myvar:0:5}" "${myvar:6}"
        echo "${myvar:-default}" "${myvar:+alternative}"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "hello world"
      assert stdout =~ "11"
      assert stdout =~ "hello"
      assert stdout =~ "alternative"
    end

    test "arrays", %{session: session} do
      result =
        run_script(session, """
        arr=(one two three four five)
        echo "Array: ${arr[@]}"
        echo "Length: ${#arr[@]}"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "one two three four five"
      assert stdout =~ "Length: 5"
    end

    test "if/elif/else", %{session: session} do
      result =
        run_script(session, """
        if [ 1 -eq 1 ]; then echo "if true"
        elif [ 1 -eq 2 ]; then echo "elif"
        else echo "else"; fi
        """)

      assert get_stdout(result) =~ "if true"
    end

    test "for loop", %{session: session} do
      result =
        run_script(session, """
        for i in 1 2 3; do echo "for: $i"; done
        """)

      stdout = get_stdout(result)
      assert stdout =~ "for: 1"
      assert stdout =~ "for: 2"
      assert stdout =~ "for: 3"
    end

    test "while loop", %{session: session} do
      result =
        run_script(session, """
        count=0
        while ((count<3)); do
          echo "while: $count"
          ((count++))
        done
        """)

      stdout = get_stdout(result)
      assert stdout =~ "while: 0"
      assert stdout =~ "while: 1"
      assert stdout =~ "while: 2"
    end

    test "case statement", %{session: session} do
      result =
        run_script(session, """
        word="bar"
        case $word in
          foo) echo "matched foo";;
          bar|baz) echo "matched bar or baz";;
          *) echo "default";;
        esac
        """)

      assert get_stdout(result) =~ "matched bar or baz"
    end

    test "functions", %{session: session} do
      result =
        run_script(session, """
        func1() { echo "parens style: $1"; return 42; }
        func1 "arg1"
        echo "Return value: $?"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "parens style: arg1"
      assert stdout =~ "Return value: 42"
    end

    test "here documents", %{session: session} do
      result =
        run_script(session, """
        myvar="expanded"
        cat <<EOF
        Here doc with $myvar
        EOF
        """)

      assert get_stdout(result) =~ "Here doc with expanded"
    end

    test "pipelines", %{session: session} do
      result = run_script(session, "echo hello | cat")
      assert get_stdout(result) =~ "hello"
    end

    test "brace expansion", %{session: session} do
      result = run_script(session, "echo {a,b,c}{1,2}")
      assert get_stdout(result) =~ "a1 a2 b1 b2 c1 c2"
    end

    test "command substitution", %{session: session} do
      result = run_script(session, ~s[echo "Nested: $(echo $(echo nested))"])
      assert get_stdout(result) =~ "Nested: nested"
    end
  end

  # Helpers

  defp report_comparison(reference, actual, exit_code) do
    ref_lines = String.split(normalize_output(reference), "\n")
    act_lines = String.split(normalize_output(actual), "\n")

    _ref_set = MapSet.new(ref_lines)
    act_set = MapSet.new(act_lines)

    matching = Enum.count(ref_lines, &MapSet.member?(act_set, &1))
    total = length(ref_lines)
    pct = if total > 0, do: Float.round(matching / total * 100, 1), else: 0.0

    IO.puts("Exit code: #{exit_code}")
    IO.puts("Reference lines: #{total}")
    IO.puts("Matching lines: #{matching} (#{pct}%)")
    IO.puts("Missing from output: #{total - matching}")
    IO.puts("Extra in output: #{length(act_lines) - matching}")

    if matching < total do
      missing =
        ref_lines
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _} -> MapSet.member?(act_set, line) end)
        |> Enum.take(20)

      if length(missing) > 0 do
        IO.puts("\nFirst 20 missing lines:")

        Enum.each(missing, fn {line, idx} ->
          IO.puts("  #{idx}: #{String.slice(line, 0, 60)}...")
        end)
      end
    end

    assert true, "Comparison report complete"
  end

  defp get_partial_reference(reference, up_to_line) do
    # This is approximate - reference output doesn't map 1:1 to source lines
    # Just take first portion of reference proportionally
    lines = String.split(reference, "\n")
    # Estimate ~4 output lines per 10 source lines
    estimate = div(up_to_line * 4, 10)
    Enum.take(lines, estimate) |> Enum.join("\n")
  end

  defp normalize_output(output) do
    output
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
    |> String.replace(~r|/Users/[^\s]+|, "/XXXX")
    |> String.replace(~r|/home/[^\s]+|, "/XXXX")
    |> String.replace(~r/BASH_VERSION: [^\n]+/, "BASH_VERSION: XXXX")
    |> String.replace(~r/\d+ main [^\n]+/, "XXXX main XXXX")
    |> String.replace(~r/\r\n/, "\n")
    |> String.trim()
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
