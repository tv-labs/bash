defmodule Bash.Parser.TestCommandTest do
  use ExUnit.Case

  alias Bash.AST
  alias Bash.Parser
  alias Bash.Script

  describe "test command [ ] parsing" do
    test "simple file test" do
      script = "[ -f file.txt ]"
      {:ok, %Script{statements: [test_cmd]}} = Parser.parse(script)

      assert %AST.TestCommand{} = test_cmd
      assert length(test_cmd.args) == 2
      assert %AST.Word{parts: [literal: "-f"]} = Enum.at(test_cmd.args, 0)
      assert %AST.Word{parts: [literal: "file.txt"]} = Enum.at(test_cmd.args, 1)
    end

    test "string equality with =" do
      script = ~s([ "hello" = "world" ])
      {:ok, %Script{statements: [test_cmd]}} = Parser.parse(script)

      assert %AST.TestCommand{} = test_cmd
      assert length(test_cmd.args) == 3
      assert %AST.Word{quoted: :double} = Enum.at(test_cmd.args, 0)
      assert "=" = Enum.at(test_cmd.args, 1)
      assert %AST.Word{quoted: :double} = Enum.at(test_cmd.args, 2)
    end

    test "numeric comparison" do
      script = "[ 5 -eq 5 ]"
      {:ok, %Script{statements: [test_cmd]}} = Parser.parse(script)

      assert %AST.TestCommand{} = test_cmd
      assert length(test_cmd.args) == 3

      [
        %AST.Word{parts: [literal: "5"]},
        %AST.Word{parts: [literal: "-eq"]},
        %AST.Word{parts: [literal: "5"]}
      ] =
        test_cmd.args
    end

    test "file comparison with -nt" do
      script = "[ file1.txt -nt file2.txt ]"
      {:ok, %Script{statements: [test_cmd]}} = Parser.parse(script)

      assert %AST.TestCommand{} = test_cmd
      assert length(test_cmd.args) == 3

      [
        %AST.Word{parts: [literal: "file1.txt"]},
        %AST.Word{parts: [literal: "-nt"]},
        %AST.Word{parts: [literal: "file2.txt"]}
      ] =
        test_cmd.args
    end

    test "with != operator" do
      script = ~s([ "abc" != "def" ])
      {:ok, %Script{statements: [test_cmd]}} = Parser.parse(script)

      assert %AST.TestCommand{} = test_cmd
      assert length(test_cmd.args) == 3
      assert %AST.Word{quoted: :double} = Enum.at(test_cmd.args, 0)
      assert "!=" = Enum.at(test_cmd.args, 1)
      assert %AST.Word{quoted: :double} = Enum.at(test_cmd.args, 2)
    end
  end
end
