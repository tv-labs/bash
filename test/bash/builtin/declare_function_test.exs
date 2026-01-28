defmodule Bash.Builtin.DeclareFunctionTest do
  use Bash.SessionCase, async: true

  alias Bash.Builtin.Declare
  alias Bash.Function
  alias Bash.AST.Command
  alias Bash.AST.Word
  alias Bash.CommandResult

  describe "declare -f (show function definitions)" do
    test "lists all functions with their definitions" do
      func1 = make_function("greet", "echo", "Hello")
      func2 = make_function("farewell", "echo", "Goodbye")

      base_state = session_state(functions: %{"greet" => func1, "farewell" => func2})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-f"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result

      # Both functions should be present with their definitions
      assert stdout =~ "function greet {"
      assert stdout =~ "echo Hello"
      assert stdout =~ "function farewell {"
      assert stdout =~ "echo Goodbye"
    end

    test "shows a specific function definition" do
      func1 = make_function("greet", "echo", "Hello")
      func2 = make_function("farewell", "echo", "Goodbye")

      base_state = session_state(functions: %{"greet" => func1, "farewell" => func2})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-f", "greet"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result

      assert stdout =~ "function greet {"
      assert stdout =~ "echo Hello"
      refute stdout =~ "farewell"
    end

    test "returns error when function does not exist" do
      base_state = session_state()

      {result, _stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-f", "nonexistent"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 1}} = result
      assert stderr =~ "nonexistent: not found"
    end

    test "handles multiple function names with some missing" do
      func = make_function("greet", "echo", "Hello")

      base_state = session_state(functions: %{"greet" => func})

      {result, stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-f", "greet", "nonexistent"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 1}} = result

      # Should show the existing function
      assert stdout =~ "function greet {"
      # Should report the missing function
      assert stderr =~ "nonexistent: not found"
    end

    test "returns empty output when no functions are defined" do
      base_state = session_state()

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-f"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == ""
    end
  end

  describe "declare -F (show function names only)" do
    test "lists all function names without definitions" do
      func1 = make_function("greet", "echo", "Hello")
      func2 = make_function("farewell", "echo", "Goodbye", exported: true)

      base_state = session_state(functions: %{"greet" => func1, "farewell" => func2})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-F"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result

      # Should show function names with declare prefix
      assert stdout =~ "declare -f greet"
      assert stdout =~ "declare -fx farewell"

      # Should NOT show function bodies
      refute stdout =~ "echo Hello"
      refute stdout =~ "echo Goodbye"
    end

    test "shows a specific function name with attributes" do
      func = make_function("myfunc", "echo", "test", exported: true)

      base_state = session_state(functions: %{"myfunc" => func})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-F", "myfunc"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result

      # Should show function name with export flag
      assert stdout =~ "declare -fx myfunc"
      refute stdout =~ "echo"
    end

    test "shows function name without export flag when not exported" do
      func = make_function("myfunc", "echo", "test", exported: false)

      base_state = session_state(functions: %{"myfunc" => func})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-F", "myfunc"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result

      assert stdout =~ "declare -f myfunc"
      refute stdout =~ "declare -fx myfunc"
    end

    test "returns error when function does not exist" do
      base_state = session_state()

      {result, _stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-F", "nonexistent"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 1}} = result
      assert stderr =~ "nonexistent: not found"
    end

    test "returns empty output when no functions are defined" do
      base_state = session_state()

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-F"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == ""
    end
  end

  describe "functions sorted alphabetically" do
    test "declare -f lists functions in alphabetical order" do
      func_z = make_function("zebra", "echo", "z")
      func_a = make_function("apple", "echo", "a")
      func_m = make_function("mango", "echo", "m")

      base_state =
        session_state(functions: %{"zebra" => func_z, "apple" => func_a, "mango" => func_m})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-f"], nil, state)
        end)

      assert {:ok, %CommandResult{}} = result

      # Find positions of each function
      apple_pos = :binary.match(stdout, "function apple")
      mango_pos = :binary.match(stdout, "function mango")
      zebra_pos = :binary.match(stdout, "function zebra")

      # Verify alphabetical order
      assert elem(apple_pos, 0) < elem(mango_pos, 0)
      assert elem(mango_pos, 0) < elem(zebra_pos, 0)
    end

    test "declare -F lists functions in alphabetical order" do
      func_z = make_function("zebra", "echo", "z")
      func_a = make_function("apple", "echo", "a")
      func_m = make_function("mango", "echo", "m")

      base_state =
        session_state(functions: %{"zebra" => func_z, "apple" => func_a, "mango" => func_m})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-F"], nil, state)
        end)

      assert {:ok, %CommandResult{}} = result

      # Find positions of each function
      apple_pos = :binary.match(stdout, "apple")
      mango_pos = :binary.match(stdout, "mango")
      zebra_pos = :binary.match(stdout, "zebra")

      # Verify alphabetical order
      assert elem(apple_pos, 0) < elem(mango_pos, 0)
      assert elem(mango_pos, 0) < elem(zebra_pos, 0)
    end
  end

  describe "declare -p output format" do
    test "uses -- prefix for variables with no flags" do
      var = Bash.Variable.new("hello")
      base_state = session_state(variables: %{"myvar" => var})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Declare.execute(["-p", "myvar"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout =~ "declare -- myvar=\"hello\""
    end
  end

  defp session_state(opts \\ []) do
    variables = Keyword.get(opts, :variables, %{})
    functions = Keyword.get(opts, :functions, %{})

    %{
      variables: variables,
      functions: functions
    }
  end

  defp make_function(name, command_name, command_arg, opts \\ []) do
    exported = Keyword.get(opts, :exported, false)

    %Function{
      name: name,
      body: [
        %Command{
          name: %Word{parts: [{:literal, command_name}]},
          args: [%Word{parts: [{:literal, command_arg}]}]
        }
      ],
      exported: exported
    }
  end
end
