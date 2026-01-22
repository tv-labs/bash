defmodule Bash.ControlFlowTest do
  use Bash.SessionCase, async: true

  alias Bash.AST
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session

  describe "if statement parsing" do
    test "parses simple if-then-fi" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("if true; then echo yes; fi")

      assert %AST.If{
               condition: %AST.Command{},
               body: [%AST.Command{}],
               elif_clauses: [],
               else_body: nil
             } = ast
    end

    test "parses if-then-else-fi" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("if false; then echo yes; else echo no; fi")

      assert %AST.If{
               condition: %AST.Command{},
               body: [%AST.Command{}],
               elif_clauses: [],
               else_body: [%AST.Command{}]
             } = ast
    end

    test "parses if-elif-else-fi" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse(
          "if false; then echo first; elif true; then echo second; else echo third; fi"
        )

      assert %AST.If{
               condition: %AST.Command{},
               body: [%AST.Command{}],
               elif_clauses: [{%AST.Command{}, [%AST.Command{}]}],
               else_body: [%AST.Command{}]
             } = ast
    end

    test "parses if with test command condition" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("if [ -d /tmp ]; then echo exists; fi")

      assert %AST.If{
               condition: %AST.TestCommand{},
               body: [%AST.Command{}]
             } = ast
    end

    test "parses if with test expression condition" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("if [[ -n foo ]]; then echo not_empty; fi")

      assert %AST.If{
               condition: %AST.TestExpression{},
               body: [%AST.Command{}]
             } = ast
    end

    test "parses multiline if" do
      script = """
      if true
      then
        echo line1
        echo line2
      fi
      """

      {:ok, %Script{statements: [ast]}} = Parser.parse(String.trim(script))

      assert %AST.If{body: body} = ast
      # Filter separators for assertion (they're preserved for formatting)
      executable_body = Enum.reject(body, &match?({:separator, _}, &1))
      assert [%AST.Command{}, %AST.Command{}] = executable_body
    end
  end

  describe "while loop parsing" do
    test "parses simple while loop" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("while true; do echo loop; done")

      assert %AST.WhileLoop{
               condition: %AST.Command{},
               body: [%AST.Command{}],
               until: false
             } = ast
    end

    test "parses while with test command" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("while [ -f /tmp/flag ]; do echo waiting; done")

      assert %AST.WhileLoop{
               condition: %AST.TestCommand{},
               body: [%AST.Command{}],
               until: false
             } = ast
    end

    test "parses multiline while" do
      script = """
      while true
      do
        echo line1
        echo line2
      done
      """

      {:ok, %Script{statements: [ast]}} = Parser.parse(String.trim(script))

      assert %AST.WhileLoop{body: body, until: false} = ast
      # Filter separators for assertion (they're preserved for formatting)
      executable_body = Enum.reject(body, &match?({:separator, _}, &1))
      assert [%AST.Command{}, %AST.Command{}] = executable_body
    end

    test "parses while with input redirect after done" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("while read line; do echo \"$line\"; done < file.txt")

      assert %AST.WhileLoop{
               condition: %AST.Command{name: %{parts: [{:literal, "read"}]}},
               body: [%AST.Command{}],
               redirects: [%AST.Redirect{direction: :input}]
             } = ast
    end

    test "parses while with process substitution redirect" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("while read line; do echo \"$line\"; done < <(echo test)")

      assert %AST.WhileLoop{
               redirects: [%AST.Redirect{direction: :input, target: {:file, word}}]
             } = ast

      # Process substitution target should have process_subst_in part
      assert Enum.any?(word.parts, fn
               {:process_subst_in, _} -> true
               _ -> false
             end)
    end

    test "parses while with heredoc redirect" do
      script = """
      while read line; do echo "$line"; done <<EOF
      line1
      line2
      EOF
      """

      {:ok, %Script{statements: statements}} = Parser.parse(String.trim(script))
      # Filter out separators to get actual AST nodes
      [ast | _] = Enum.reject(statements, &match?({:separator, _}, &1))

      assert %AST.WhileLoop{
               redirects: [%AST.Redirect{direction: :heredoc, target: {:heredoc, _, "EOF", _}}]
             } = ast
    end
  end

  describe "until loop parsing" do
    test "parses simple until loop" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("until false; do echo loop; done")

      assert %AST.WhileLoop{
               condition: %AST.Command{},
               body: [%AST.Command{}],
               until: true
             } = ast
    end

    test "parses until with test command" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("until [ -f /tmp/done ]; do echo waiting; done")

      assert %AST.WhileLoop{
               condition: %AST.TestCommand{},
               body: [%AST.Command{}],
               until: true
             } = ast
    end
  end

  describe "if statement execution" do
    setup :start_session

    test "executes then body when condition is true", %{session: session} do
      result = run_script(session, "if true; then echo yes; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "yes\n"
    end

    test "skips then body when condition is false", %{session: session} do
      result = run_script(session, "if false; then echo should_not_run; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end

    test "executes else body when condition is false", %{session: session} do
      result = run_script(session, "if false; then echo yes; else echo no; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "no\n"
    end

    test "executes elif body when first condition fails", %{session: session} do
      result =
        run_script(
          session,
          "if false; then echo first; elif true; then echo second; else echo third; fi"
        )

      assert result.exit_code == 0
      assert get_stdout(result) == "second\n"
    end

    test "works with test command condition", %{session: session} do
      result = run_script(session, "if [ -d /tmp ]; then echo exists; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "exists\n"
    end

    test "works with test expression condition", %{session: session} do
      result = run_script(session, "if [[ -n foo ]]; then echo not_empty; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "not_empty\n"
    end

    test "multiple commands in then body", %{session: session} do
      result = run_script(session, "if true; then echo one; echo two; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "one\ntwo\n"
    end
  end

  describe "while loop execution" do
    setup :start_session

    test "does not execute body when condition is false", %{session: session} do
      result = run_script(session, "while false; do echo never; done")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end

    test "body exit code does not affect loop continuation", %{session: session} do
      # Even if body command fails, loop continues based on condition
      result = run_script(session, "while false; do false; done")

      assert result.exit_code == 0
    end

    @tag :tmp_dir
    test "reads from file with input redirect after done", %{session: session, tmp_dir: tmp_dir} do
      # Create a test file with content
      test_file = Path.join(tmp_dir, "input.txt")
      File.write!(test_file, "line1\nline2\nline3\n")

      script = """
      while read line; do
        echo "read: $line"
      done < #{test_file}
      """

      result = run_script(session, script)

      assert result.exit_code == 0
      assert get_stdout(result) == "read: line1\nread: line2\nread: line3\n"
    end

    @tag :tmp_dir
    test "reads from heredoc redirect", %{session: session} do
      script = ~S"""
      while read line; do
        echo "got: $line"
      done <<EOF
      first
      second
      EOF
      """

      result = run_script(session, script)

      assert result.exit_code == 0
      assert get_stdout(result) == "got: first\ngot: second\n"
    end
  end

  describe "until loop execution" do
    setup :start_session

    test "does not execute body when condition is true", %{session: session} do
      result = run_script(session, "until true; do echo never; done")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end
  end

  describe "nested control flow" do
    setup :start_session

    test "if inside if", %{session: session} do
      result = run_script(session, "if true; then if true; then echo nested; fi; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "nested\n"
    end

    test "if with compound condition", %{session: session} do
      result = run_script(session, "if [ -d /tmp ] && [ -d /var ]; then echo both_exist; fi")

      assert result.exit_code == 0
      assert get_stdout(result) == "both_exist\n"
    end
  end

  describe "errexit (set -e)" do
    setup :start_session

    test "set -e causes script to exit on failed command", %{session: session} do
      script = """
      set -e
      false
      echo "should not reach here"
      """

      {:ok, ast} = Parser.parse(String.trim(script))
      {:exit, result} = Session.execute(session, ast)

      # Script should exit after 'false' command
      assert result.exit_code == 1
      # The echo should not have run
      refute String.contains?(get_stdout(result), "should not reach here")
    end

    test "without set -e, script continues after failed command", %{session: session} do
      script = """
      false
      echo "should reach here"
      """

      {:ok, ast} = Parser.parse(String.trim(script))
      {:ok, result} = Session.execute(session, ast)

      # The echo should have run
      assert String.contains?(get_stdout(result), "should reach here")
    end

    test "set -e with pipefail and other options", %{session: session} do
      script = """
      set -euo pipefail
      false
      echo "should not reach here"
      """

      {:ok, ast} = Parser.parse(String.trim(script))
      {:exit, result} = Session.execute(session, ast)

      assert result.exit_code == 1
      refute String.contains?(get_stdout(result), "should not reach here")
    end

    test "set +e disables errexit", %{session: session} do
      script = """
      set -e
      set +e
      false
      echo "should reach here"
      """

      {:ok, ast} = Parser.parse(String.trim(script))
      {:ok, result} = Session.execute(session, ast)

      assert String.contains?(get_stdout(result), "should reach here")
    end
  end
end
