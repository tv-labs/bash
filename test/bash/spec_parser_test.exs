defmodule Bash.SpecParserTest do
  use ExUnit.Case, async: true

  alias Bash.SpecParser

  describe "parse_string/1" do
    test "parses a single test case with single-line stdout" do
      content = """
      #### Echo test
      echo hello
      ## stdout: hello
      """

      assert [%SpecParser{name: "Echo test", code: "echo hello", stdout: "hello\n"}] =
               SpecParser.parse_string(content)
    end

    test "parses a test case with status" do
      content = """
      #### Failing command
      false
      ## status: 1
      """

      assert [%SpecParser{name: "Failing command", code: "false", status: 1}] =
               SpecParser.parse_string(content)
    end

    test "parses multi-line STDOUT block" do
      content = """
      #### Multi-line output
      echo one
      echo two
      ## STDOUT:
      one
      two
      ## END
      """

      assert [%SpecParser{name: "Multi-line output", stdout: "one\ntwo\n"}] =
               SpecParser.parse_string(content)
    end

    test "parses multiple test cases in one string" do
      content = """
      #### First
      echo one
      ## stdout: one

      #### Second
      echo two
      ## stdout: two
      """

      assert [
               %SpecParser{name: "First", code: "echo one", stdout: "one\n"},
               %SpecParser{name: "Second", code: "echo two", stdout: "two\n"}
             ] = SpecParser.parse_string(content)
    end

    test "prefers OK bash stdout over default stdout" do
      content = """
      #### Bash-specific
      echo test
      ## stdout: default
      ## OK bash stdout: bash-specific
      """

      assert [%SpecParser{stdout: "bash-specific\n"}] = SpecParser.parse_string(content)
    end

    test "handles OK bash/zsh stdout variant" do
      content = """
      #### Multi-shell override
      echo test
      ## stdout: default
      ## OK bash/zsh stdout: override
      """

      assert [%SpecParser{stdout: "override\n"}] = SpecParser.parse_string(content)
    end

    test "skips test cases with empty code" do
      content = """
      #### Empty case
      ## stdout: nothing

      #### Real case
      echo hi
      ## stdout: hi
      """

      assert [%SpecParser{name: "Real case"}] = SpecParser.parse_string(content)
    end

    test "records line numbers" do
      content = """
      # preamble comment
      ## compare_shells: bash

      #### First test
      echo one
      ## stdout: one

      #### Second test
      echo two
      ## stdout: two
      """

      cases = SpecParser.parse_string(content)

      assert [
               %SpecParser{name: "First test", line: 4},
               %SpecParser{name: "Second test", line: 8}
             ] = cases
    end

    test "handles stdout-json format" do
      content = """
      #### JSON stdout
      echo -n ""
      ## stdout-json: ""
      """

      assert [%SpecParser{stdout: ""}] = SpecParser.parse_string(content)
    end

    test "handles stdout-json with escaped characters" do
      content = """
      #### JSON with newline
      echo hello
      ## stdout-json: "hello\\n"
      """

      assert [%SpecParser{stdout: "hello\n"}] = SpecParser.parse_string(content)
    end

    test "marks N-I bash tests as skip" do
      content = """
      #### Not implemented
      echo test
      ## stdout: something
      ## N-I bash stdout-json: ""
      ## N-I bash status: 2
      """

      assert [%SpecParser{skip: true}] = SpecParser.parse_string(content)
    end

    test "marks N-I bash/zsh tests as skip" do
      content = """
      #### Not implemented in bash or zsh
      echo test
      ## stdout: something
      ## N-I bash/zsh stdout: other
      """

      assert [%SpecParser{skip: true}] = SpecParser.parse_string(content)
    end

    test "marks tests containing $SH in code as skip" do
      content = """
      #### Shell binary test
      $SH -c 'echo hello'
      ## stdout: hello
      """

      assert [%SpecParser{skip: true}] = SpecParser.parse_string(content)
    end

    test "marks tests containing case $SH in as skip" do
      content = """
      #### Shell case test
      case $SH in
        */bash) echo bash ;;
      esac
      ## stdout: bash
      """

      assert [%SpecParser{skip: true}] = SpecParser.parse_string(content)
    end

    test "handles OK bash multi-line STDOUT override" do
      content = """
      #### Multi-line bash override
      echo test
      ## STDOUT:
      default
      ## END
      ## OK bash STDOUT:
      bash-specific
      ## END
      """

      assert [%SpecParser{stdout: "bash-specific\n"}] = SpecParser.parse_string(content)
    end

    test "ignores preamble lines before first test case" do
      content = """
      # Arithmetic tests
      ## compare_shells: bash dash mksh zsh

      #### Actual test
      echo hello
      ## stdout: hello
      """

      assert [%SpecParser{name: "Actual test"}] = SpecParser.parse_string(content)
    end

    test "defaults skip to false for normal tests" do
      content = """
      #### Normal test
      echo hello
      ## stdout: hello
      """

      assert [%SpecParser{skip: false}] = SpecParser.parse_string(content)
    end

    test "handles both stdout and status together" do
      content = """
      #### With both
      echo hello
      exit 42
      ## stdout: hello
      ## status: 42
      """

      assert [%SpecParser{stdout: "hello\n", status: 42}] = SpecParser.parse_string(content)
    end
  end
end
