defmodule Bash.Builtin.EchoTest do
  @moduledoc """
  Unit tests for the Echo builtin.
  """
  use Bash.SessionCase, async: true

  alias Bash.Builtin.Echo
  alias Bash.CommandResult

  describe "basic echo" do
    test "echoes a single argument" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["hello"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\n"
    end

    test "echoes multiple arguments with spaces" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["hello", "world"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello world\n"
    end

    test "echoes empty string with no arguments" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute([], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "\n"
    end

    test "returns exit code 0" do
      {result, _stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["test"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
    end
  end

  describe "-n flag (no newline)" do
    test "suppresses trailing newline" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-n", "hello"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello"
    end

    test "works with multiple arguments" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-n", "hello", "world"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello world"
    end

    test "works with empty string" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-n"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == ""
    end
  end

  describe "-e flag (enable escape sequences)" do
    test "interprets \\n as newline" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\nworld\n"
    end

    test "interprets \\t as tab" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\tworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\tworld\n"
    end

    test "interprets \\r as carriage return" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\rworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\rworld\n"
    end

    test "interprets \\\\ as backslash" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\\\world"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\\world\n"
    end

    test "interprets \\a as bell" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\aworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\aworld\n"
    end

    test "interprets \\b as backspace" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\bworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\bworld\n"
    end

    test "interprets \\f as form feed" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\fworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\fworld\n"
    end

    test "interprets \\v as vertical tab" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\vworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\vworld\n"
    end

    test "interprets \\e and \\E as escape" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\e[31mred\\e[0m"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "\e[31mred\e[0m\n"

      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\E[31mred\\E[0m"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "\e[31mred\e[0m\n"
    end

    test "interprets \\c to suppress further output" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\cworld"], nil, state)
        end)

      # \\c suppresses everything after it, including the newline
      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello"
    end

    test "handles multiple escape sequences" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "line1\\nline2\\tindented"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "line1\nline2\tindented\n"
    end
  end

  describe "-e flag with octal sequences" do
    test "interprets \\0 followed by octal digits" do
      # \\065 = ASCII 53 = '5'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\0065"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "5\n"
    end

    test "interprets octal with 1-3 digits" do
      # \\0101 = ASCII 65 = 'A'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\0101"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "A\n"
    end

    test "stops at non-octal digit" do
      # \\0659 = ASCII 53 ('5') + '9'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\0659"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "59\n"
    end
  end

  describe "-e flag with hex sequences" do
    test "interprets \\x followed by hex digits" do
      # \\x41 = ASCII 65 = 'A'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\x41"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "A\n"
    end

    test "interprets hex with 1-2 digits" do
      # \\x7A = ASCII 122 = 'z'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\x7A"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "z\n"
    end

    test "stops at non-hex character" do
      # \\x41G = 'A' + 'G'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\x41G"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "AG\n"
    end
  end

  describe "-e flag with unicode sequences" do
    test "interprets \\u followed by 1-4 hex digits" do
      # \\u0041 = 'A'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\u0041"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "A\n"

      # \\u03B1 = Greek letter alpha
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\u03B1"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "α\n"
    end

    test "interprets \\U followed by 1-8 hex digits" do
      # \\U00000041 = 'A'
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\U00000041"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "A\n"

      # \\U0001F4A9 = pile of poo emoji
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "\\U0001F4A9"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "💩\n"
    end
  end

  describe "-E flag (disable escape sequences)" do
    test "disables escape interpretation" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-E", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\\nworld\n"
    end

    test "overrides -e flag when both present" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "-E", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\\nworld\n"
    end
  end

  describe "combined flags" do
    test "-ne combines no newline and escape sequences" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-ne", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\nworld"
    end

    test "-en is same as -ne" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-en", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\nworld"
    end

    test "-nE combines no newline and disables escapes" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-nE", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\\nworld"
    end
  end

  describe "edge cases" do
    test "handles arguments that look like flags after first arg" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["hello", "-n", "world"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello -n world\n"
    end

    test "unknown flags are treated as regular arguments" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-x", "hello"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "-x hello\n"
    end

    test "double dash stops flag parsing" do
      # In our implementation, we don't have -- support, so -n would be treated as arg
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["--", "-n"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "-- -n\n"
    end

    test "handles empty string in arguments" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["hello", "", "world"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello  world\n"
    end

    test "handles special characters without -e" do
      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["hello\\nworld"], nil, state)
        end)

      # Without -e, backslashes are literal
      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\\nworld\n"
    end
  end

  describe "compatibility with bash" do
    test "matches bash behavior for basic echo" do
      {bash_output, 0} = System.cmd("bash", ["-c", "echo hello world"])

      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["hello", "world"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == bash_output
    end

    test "matches bash behavior for echo -n" do
      {bash_output, 0} = System.cmd("bash", ["-c", "echo -n hello"])

      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-n", "hello"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == bash_output
    end

    test "matches bash behavior for echo -e with newline" do
      {bash_output, 0} = System.cmd("bash", ["-c", "echo -e 'hello\\nworld'"])

      {result, stdout, _stderr} =
        with_output_capture(fn state ->
          Echo.execute(["-e", "hello\\nworld"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == bash_output
    end
  end
end
