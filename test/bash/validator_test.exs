defmodule Bash.ValidatorTest do
  use ExUnit.Case, async: true

  alias Bash.Parser
  alias Bash.Validator

  describe "validate/2 - valid scripts" do
    test "accepts simple command" do
      {:ok, ast} = Parser.parse("echo hello")
      assert :ok = Validator.validate(ast, "echo hello")
    end

    test "accepts pipeline" do
      {:ok, ast} = Parser.parse("echo hello | wc -c")
      assert :ok = Validator.validate(ast, "echo hello | wc -c")
    end

    test "accepts proper if statement" do
      {:ok, ast} = Parser.parse("if true; then echo hi; fi")
      assert :ok = Validator.validate(ast, "if true; then echo hi; fi")
    end

    test "accepts proper while loop" do
      {:ok, ast} = Parser.parse("while true; do echo hi; done")
      assert :ok = Validator.validate(ast, "while true; do echo hi; done")
    end

    test "accepts proper for loop" do
      {:ok, ast} = Parser.parse("for i in a b c; do echo $i; done")
      assert :ok = Validator.validate(ast, "for i in a b c; do echo $i; done")
    end

    test "accepts proper command group" do
      {:ok, ast} = Parser.parse("{ echo hello; }")
      assert :ok = Validator.validate(ast, "{ echo hello; }")
    end

    test "accepts multiple commands" do
      {:ok, ast} = Parser.parse("echo one; echo two; echo three")
      assert :ok = Validator.validate(ast, "echo one; echo two; echo three")
    end

    test "accepts assignment" do
      {:ok, ast} = Parser.parse("FOO=bar")
      assert :ok = Validator.validate(ast, "FOO=bar")
    end
  end

  describe "parse-time errors - structural" do
    # The new parser catches structural errors at parse time, not validation time

    test "rejects unclosed command group at parse time" do
      assert {:error, msg, _line, _col} = Parser.parse("{ echo hello")
      assert msg =~ "}" or msg =~ "brace"
    end

    test "allows closing brace as argument (valid in bash)" do
      # In bash, } as an argument is valid: echo } prints }
      {:ok, ast} = Parser.parse("echo hello }")
      assert :ok = Validator.validate(ast, "echo hello }")
    end

    test "rejects standalone closing brace at parse time" do
      # When } appears as a command, the parser rejects it
      assert {:error, _msg, _line, _col} = Parser.parse("}")
    end
  end

  describe "parse-time errors - control flow" do
    # The new parser catches control flow errors at parse time

    test "rejects if without fi at parse time" do
      assert {:error, msg, _line, _col} = Parser.parse("if true; then echo hi")
      assert msg =~ "fi" or msg =~ "elif" or msg =~ "else"
    end

    test "rejects while without done at parse time" do
      assert {:error, msg, _line, _col} = Parser.parse("while true; do echo hi")
      assert msg =~ "done"
    end

    test "rejects for without done at parse time" do
      assert {:error, msg, _line, _col} = Parser.parse("for i in a b; do echo $i")
      assert msg =~ "done"
    end

    test "rejects orphan then at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("then echo hi")
    end

    test "rejects orphan else at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("else echo hi")
    end

    test "rejects orphan fi at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("fi")
    end

    test "rejects orphan do at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("do echo hi; done")
    end

    test "rejects orphan done at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("done")
    end

    test "rejects incomplete case statement at parse time" do
      assert {:error, _reason, _line, _column} = Parser.parse("case $x in a) echo hi")
    end

    test "rejects bare case keyword at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("case")
    end

    test "rejects orphan esac at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("esac")
    end

    test "rejects orphan in at parse time" do
      assert {:error, _msg, _line, _col} = Parser.parse("in a b c")
    end
  end

  describe "validate_all/2" do
    test "returns empty list for valid script" do
      {:ok, ast} = Parser.parse("echo hello")
      assert {:ok, []} = Validator.validate_all(ast, "echo hello")
    end

    test "validates nested structures" do
      {:ok, ast} = Parser.parse("if true; then echo one; echo two; fi")
      assert {:ok, []} = Validator.validate_all(ast, "if true; then echo one; echo two; fi")
    end
  end
end
