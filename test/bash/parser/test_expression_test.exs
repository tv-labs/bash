defmodule Bash.Parser.TestExpressionTest do
  use ExUnit.Case

  alias Bash.AST
  alias Bash.AST.RegexPattern
  alias Bash.Parser
  alias Bash.Script

  describe "test expression [[ ]] parsing" do
    test "simple file test" do
      script = "[[ -f file.txt ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      # Expression is a list of words and operators
      assert length(test_expr.expression) == 2
      assert %AST.Word{parts: [literal: "-f"]} = Enum.at(test_expr.expression, 0)
      assert %AST.Word{parts: [literal: "file.txt"]} = Enum.at(test_expr.expression, 1)
    end

    test "string equality with =" do
      script = ~s([[ "hello" = "world" ]])
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 3
      assert %AST.Word{quoted: :double} = Enum.at(test_expr.expression, 0)
      assert "=" = Enum.at(test_expr.expression, 1)
      assert %AST.Word{quoted: :double} = Enum.at(test_expr.expression, 2)
    end

    test "pattern matching with ==" do
      script = "[[ \"file.txt\" == *.txt ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 3
      assert %AST.Word{quoted: :double} = Enum.at(test_expr.expression, 0)
      assert "==" = Enum.at(test_expr.expression, 1)
      assert %AST.Word{parts: [literal: "*.txt"]} = Enum.at(test_expr.expression, 2)
    end

    test "regex matching with =~" do
      script = ~s([[ "hello123" =~ "[0-9]+" ]])
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 3
      assert %AST.Word{quoted: :double} = Enum.at(test_expr.expression, 0)
      assert "=~" = Enum.at(test_expr.expression, 1)
      # After =~, patterns are now RegexPattern (quoted patterns are literal matches)
      assert %RegexPattern{parts: [{:double_quoted, _}]} = Enum.at(test_expr.expression, 2)
    end

    test "with && operator" do
      script = "[[ -f file.txt && -r file.txt ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 5
      [w1, w2, op, w3, w4] = test_expr.expression
      assert %AST.Word{parts: [literal: "-f"]} = w1
      assert %AST.Word{parts: [literal: "file.txt"]} = w2
      assert "&&" = op
      assert %AST.Word{parts: [literal: "-r"]} = w3
      assert %AST.Word{parts: [literal: "file.txt"]} = w4
    end

    test "with || operator" do
      script = "[[ -f file.txt || -d file.txt ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 5
      [w1, w2, op, w3, w4] = test_expr.expression
      assert %AST.Word{parts: [literal: "-f"]} = w1
      assert %AST.Word{parts: [literal: "file.txt"]} = w2
      assert "||" = op
      assert %AST.Word{parts: [literal: "-d"]} = w3
      assert %AST.Word{parts: [literal: "file.txt"]} = w4
    end

    test "with ! operator" do
      script = "[[ ! -f file.txt ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 3

      ["!", %AST.Word{parts: [literal: "-f"]}, %AST.Word{parts: [literal: "file.txt"]}] =
        test_expr.expression
    end

    test "complex expression with ! && and" do
      script = "[[ ! -f file.txt && -d dir ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 6
      ["!", %AST.Word{}, %AST.Word{}, "&&", %AST.Word{}, %AST.Word{}] = test_expr.expression
    end

    test "numeric comparison" do
      script = "[[ 5 -eq 5 ]]"
      {:ok, %Script{statements: [test_expr]}} = Parser.parse(script)

      assert %AST.TestExpression{} = test_expr
      assert length(test_expr.expression) == 3

      [
        %AST.Word{parts: [literal: "5"]},
        %AST.Word{parts: [literal: "-eq"]},
        %AST.Word{parts: [literal: "5"]}
      ] =
        test_expr.expression
    end
  end
end
