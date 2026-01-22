defmodule Bash.SyntaxErrorTest do
  use ExUnit.Case, async: true

  alias Bash.SyntaxError

  describe "message/1" do
    test "formats error with line pointer" do
      error = %SyntaxError{
        code: "SC1046",
        line: 1,
        column: 0,
        script: "if true; then echo",
        hint: "'if' without matching 'fi'"
      }

      message = Exception.message(error)

      assert message =~ "[SC1046]"
      assert message =~ "line 1"
      assert message =~ "if true; then echo"
      assert message =~ "^"
      assert message =~ "'if' without matching 'fi'"
    end

    test "formats error with column offset" do
      error = %SyntaxError{
        code: "SC1009",
        line: 1,
        column: 5,
        script: "echo \"hello",
        hint: "unclosed double quote"
      }

      message = Exception.message(error)

      assert message =~ "[SC1009]"
      # Pointer should be offset by 5 plus the prefix "  1 | "
      assert message =~ "^"
    end

    test "handles multi-line scripts with context" do
      error = %SyntaxError{
        code: "SC1056",
        line: 2,
        column: 0,
        script: "echo hello\n{ echo world",
        hint: "'{' starts a command group - missing '}'"
      }

      message = Exception.message(error)

      assert message =~ "line 2"
      # Shows previous line as context
      assert message =~ "echo hello"
      # Shows error line with marker
      assert message =~ "> 2 | { echo world"
    end

    test "shows line numbers with proper alignment" do
      error = %SyntaxError{
        code: "SC1046",
        line: 10,
        column: 0,
        script: Enum.map_join(1..10, "\n", fn i -> "echo #{i}" end),
        hint: "test"
      }

      message = Exception.message(error)

      # Line numbers should be padded consistently
      assert message =~ "> 10 | echo 10"
      assert message =~ "   9 | echo 9"
    end

    test "clamps column to line length" do
      error = %SyntaxError{
        code: "SC1046",
        line: 1,
        # Past end of line
        column: 100,
        script: "short",
        hint: "test"
      }

      message = Exception.message(error)

      # Should not crash, pointer should be at end of line
      assert message =~ "short"
      assert message =~ "^"
    end
  end

  describe "from_parse_error/4" do
    test "translates 'expected end of string' to unclosed quote" do
      error = SyntaxError.from_parse_error("echo \"hello", "expected end of string")

      assert error.code == "SC1009"
      assert error.hint == "unclosed quote or expression"
      assert error.script == "echo \"hello"
      assert error.line == 1
      assert error.column == 0
    end

    test "truncates very long parser messages" do
      long_msg = String.duplicate("x", 250)
      error = SyntaxError.from_parse_error("invalid", long_msg)

      assert error.code == "SC1000"
      assert error.hint == "syntax error - unexpected token or incomplete statement"
    end

    test "preserves short parser messages" do
      error = SyntaxError.from_parse_error("invalid", "custom error")

      assert error.code == "SC1000"
      assert error.hint == "custom error"
    end

    test "accepts custom line and column" do
      error = SyntaxError.from_parse_error("script", "error", 5, 10)

      assert error.line == 5
      assert error.column == 10
    end
  end

  describe "from_validation/4" do
    test "builds error from validation result" do
      error =
        SyntaxError.from_validation(
          "{ echo hello",
          "SC1056",
          "'{' starts a command group - missing '}'"
        )

      assert error.code == "SC1056"
      assert error.hint == "'{' starts a command group - missing '}'"
      assert error.script == "{ echo hello"
      assert error.line == 1
      assert error.column == 0
    end

    test "extracts position from meta" do
      meta = %{line: 3, column: 5}
      error = SyntaxError.from_validation("script", "SC1000", "hint", meta)

      assert error.line == 3
      assert error.column == 5
    end

    test "handles nil meta" do
      error = SyntaxError.from_validation("script", "SC1000", "hint", nil)

      assert error.line == 1
      assert error.column == 0
    end
  end

  describe "raise/1" do
    test "can be raised as exception" do
      assert_raise SyntaxError, ~r/SC1046/, fn ->
        raise SyntaxError,
          code: "SC1046",
          line: 1,
          column: 0,
          script: "if true",
          hint: "'if' without matching 'fi'"
      end
    end
  end
end
