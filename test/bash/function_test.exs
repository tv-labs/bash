defmodule Bash.FunctionTest do
  use Bash.SessionCase, async: false

  alias Bash.AST
  alias Bash.Function
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session

  describe "function definition parsing" do
    test "parses function keyword syntax" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("function greet { echo hello; }")

      assert %Function{
               name: "greet",
               body: [%AST.Command{name: %AST.Word{parts: [literal: "echo"]}}]
             } = ast
    end

    test "parses function keyword syntax with optional parentheses" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("function greet() { echo hello; }")

      assert %Function{
               name: "greet",
               body: [%AST.Command{name: %AST.Word{parts: [literal: "echo"]}}]
             } = ast
    end

    test "parses name() syntax" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("greet() { echo hello; }")

      assert %Function{
               name: "greet",
               body: [%AST.Command{name: %AST.Word{parts: [literal: "echo"]}}]
             } = ast
    end

    test "parses function with multiple statements" do
      script = """
      function greet {
        echo hello
        echo world
      }
      """

      {:ok, %Script{statements: [ast]}} = Parser.parse(String.trim(script))

      assert %Function{name: "greet", body: body} = ast
      # Filter separators for assertion (they're preserved for formatting)
      executable_body = Enum.reject(body, &match?({:separator, _}, &1))
      assert [%AST.Command{}, %AST.Command{}] = executable_body
    end

    test "parses function with variable reference in body" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("greet() { echo $NAME; }")

      assert %Function{
               name: "greet",
               body: [%AST.Command{}]
             } = ast
    end

    test "parses multiline function body with variables" do
      script = """
      function add {
        echo ${foo}
      }
      """

      {:ok, %Script{statements: [ast]}} = Parser.parse(String.trim(script))

      assert %Function{
               name: "add",
               body: body
             } = ast

      assert length(body) >= 1
    end
  end

  describe "function execution" do
    setup :start_session

    test "defines and calls a simple function", %{session: session} do
      # Define the function
      run_script(session, "greet() { echo hello; }")

      # Call the function
      result = run_script(session, "greet")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "function can be overwritten", %{session: session} do
      # Define initial function
      run_script(session, "greet() { echo hello; }")

      # Overwrite the function
      run_script(session, "greet() { echo goodbye; }")

      # Call the overwritten function
      result = run_script(session, "greet")

      assert result.exit_code == 0
      assert get_stdout(result) == "goodbye\n"
    end

    test "return statement exits function with specified code", %{session: session} do
      # Define function with return
      run_script(session, "check() { return 42; }")

      # Call the function
      result = run_script(session, "check")

      assert result.exit_code == 42
    end

    test "return without argument uses last command exit code", %{session: session} do
      # Define function with return after a successful command
      script = """
      check() {
        echo hello
        return
      }
      """

      run_script(session, script)

      # Call the function
      result = run_script(session, "check")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "return stops function execution early", %{session: session} do
      script = """
      early_exit() {
        echo before
        return 1
        echo after
      }
      """

      run_script(session, script)

      result = run_script(session, "early_exit")

      # Should only have "before" in output, not "after"
      assert result.exit_code == 1
      assert get_stdout(result) == "before\n"
    end

    test "function with keyword syntax works the same", %{session: session} do
      run_script(session, "function hello { echo hi; }")

      result = run_script(session, "hello")

      assert result.exit_code == 0
      assert get_stdout(result) == "hi\n"
    end

    test "function can access outer variables", %{session: session} do
      # Set an outer variable
      Session.set_env(session, "OUTER", "outer_value")

      run_script(session, "show_outer() { echo $OUTER; }")

      result = run_script(session, "show_outer")

      assert result.exit_code == 0
      assert get_stdout(result) == "outer_value\n"
    end

    test "function with multiple statements executes all", %{session: session} do
      script = """
      multi() {
        echo line1
        echo line2
      }
      """

      run_script(session, script)

      result = run_script(session, "multi")

      assert result.exit_code == 0
      assert get_stdout(result) == "line1\nline2\n"
    end
  end

  describe "local variables in functions" do
    setup :start_session

    test "local with quoted string containing spaces", %{session: session} do
      script = """
      test_func() {
        local text="Hello World"
        echo "$text"
      }
      test_func
      """

      result = run_script(session, script)

      assert result.exit_code == 0
      assert get_stdout(result) == "Hello World\n"
    end

    test "local with positional parameter containing spaces", %{session: session} do
      script = """
      test_func() {
        local text="$1"
        echo "$text"
      }
      test_func "Hello World"
      """

      result = run_script(session, script)

      assert result.exit_code == 0
      assert get_stdout(result) == "Hello World\n"
    end

    test "local variable doesn't leak outside function", %{session: session} do
      script = """
      test_func() {
        local inner="inside"
        echo "$inner"
      }
      test_func
      echo "outer:$inner"
      """

      result = run_script(session, script)

      assert result.exit_code == 0
      # The outer echo should have empty $inner since it was local
      assert get_stdout(result) == "inside\nouter:\n"
    end

    test "declare with quoted value containing spaces", %{session: session} do
      script = """
      declare msg="Hello World"
      echo "$msg"
      """

      result = run_script(session, script)

      assert result.exit_code == 0
      assert get_stdout(result) == "Hello World\n"
    end
  end
end
