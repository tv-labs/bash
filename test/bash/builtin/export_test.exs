defmodule Bash.Builtin.ExportTest do
  use Bash.SessionCase, async: true

  alias Bash.Builtin.Export
  alias Bash.Variable
  alias Bash.Function
  alias Bash.CommandResult

  describe "export without options" do
    test "exports a variable with assignment" do
      state = session_state()
      {:ok, result, updates} = Export.execute(["FOO=bar"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"FOO" => var}} = updates
      assert var.value == "bar"
      assert var.attributes.export == true
    end

    test "exports multiple variables with assignments" do
      state = session_state()
      {:ok, result, updates} = Export.execute(["FOO=bar", "BAZ=qux"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: var_updates} = updates
      assert Map.has_key?(var_updates, "FOO")
      assert Map.has_key?(var_updates, "BAZ")
      assert var_updates["FOO"].value == "bar"
      assert var_updates["BAZ"].value == "qux"
    end

    test "exports an existing variable (marks it for export)" do
      existing_var = %Variable{
        value: "existing_value",
        attributes: %{readonly: false, export: false, integer: false, array_type: nil}
      }

      state = session_state(variables: %{"FOO" => existing_var})
      {:ok, result, updates} = Export.execute(["FOO"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"FOO" => var}} = updates
      assert var.value == "existing_value"
      assert var.attributes.export == true
    end

    test "exports and assigns to an existing variable" do
      existing_var = %Variable{
        value: "old_value",
        attributes: %{readonly: false, export: false, integer: false, array_type: nil}
      }

      state = session_state(variables: %{"FOO" => existing_var})
      {:ok, result, updates} = Export.execute(["FOO=new_value"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"FOO" => var}} = updates
      assert var.value == "new_value"
      assert var.attributes.export == true
    end
  end

  describe "export -p (list)" do
    test "lists exported variables" do
      var1 = %Variable{
        value: "value1",
        attributes: %{readonly: false, export: true, integer: false, array_type: nil}
      }

      var2 = %Variable{
        value: "value2",
        attributes: %{readonly: false, export: false, integer: false, array_type: nil}
      }

      base_state = session_state(variables: %{"EXPORTED" => var1, "NOT_EXPORTED" => var2})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-p"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout =~ "declare -x EXPORTED="
      refute stdout =~ "NOT_EXPORTED"
    end

    test "lists all variables when none are explicitly exported" do
      var = %Variable{
        value: "value",
        attributes: %{readonly: false, export: false, integer: false, array_type: nil}
      }

      base_state = session_state(variables: %{"VAR" => var})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-p"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      # When no variables have export=true, we list all
      assert stdout =~ "declare -x VAR="
    end
  end

  describe "export -f (functions)" do
    test "exports a function" do
      func = %Function{
        name: "myfunc",
        body: [],
        exported: false
      }

      state = session_state(functions: %{"myfunc" => func})
      {:ok, result, updates} = Export.execute(["-f", "myfunc"], nil, state)

      assert result.exit_code == 0
      assert %{function_updates: %{"myfunc" => exported_func}} = updates
      assert exported_func.exported == true
    end

    test "exports multiple functions" do
      func1 = %Function{name: "func1", body: [], exported: false}
      func2 = %Function{name: "func2", body: [], exported: false}

      state = session_state(functions: %{"func1" => func1, "func2" => func2})
      {:ok, result, updates} = Export.execute(["-f", "func1", "func2"], nil, state)

      assert result.exit_code == 0
      assert %{function_updates: func_updates} = updates
      assert func_updates["func1"].exported == true
      assert func_updates["func2"].exported == true
    end

    test "returns error when function does not exist" do
      base_state = session_state()

      {result, _stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-f", "nonexistent"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 1}} = result
      assert stderr =~ "nonexistent: not a function"
    end
  end

  describe "export -pf (list functions)" do
    test "lists exported functions" do
      func1 = %Function{name: "exported_func", body: [], exported: true}
      func2 = %Function{name: "not_exported_func", body: [], exported: false}

      base_state =
        session_state(functions: %{"exported_func" => func1, "not_exported_func" => func2})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-pf"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout =~ "declare -fx exported_func"
      refute stdout =~ "not_exported_func"
    end

    test "returns empty when no functions are exported" do
      func = %Function{name: "myfunc", body: [], exported: false}

      base_state = session_state(functions: %{"myfunc" => func})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-pf"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == ""
    end
  end

  describe "export -n (unexport)" do
    test "removes export attribute from a variable" do
      var = %Variable{
        value: "value",
        attributes: %{readonly: false, export: true, integer: false, array_type: nil}
      }

      state = session_state(variables: %{"FOO" => var})
      {:ok, result, updates} = Export.execute(["-n", "FOO"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"FOO" => updated_var}} = updates
      assert updated_var.value == "value"
      assert updated_var.attributes.export == false
    end

    test "unexports multiple variables" do
      var1 = %Variable{
        value: "v1",
        attributes: %{readonly: false, export: true, integer: false, array_type: nil}
      }

      var2 = %Variable{
        value: "v2",
        attributes: %{readonly: false, export: true, integer: false, array_type: nil}
      }

      state = session_state(variables: %{"FOO" => var1, "BAR" => var2})
      {:ok, result, updates} = Export.execute(["-n", "FOO", "BAR"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: var_updates} = updates
      assert var_updates["FOO"].attributes.export == false
      assert var_updates["BAR"].attributes.export == false
    end

    test "creates variable without export when it doesn't exist" do
      state = session_state()
      {:ok, result, updates} = Export.execute(["-n", "NEWVAR"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"NEWVAR" => var}} = updates
      assert var.value == ""
      assert var.attributes.export == false
    end
  end

  describe "export -nf (unexport functions)" do
    test "removes export attribute from a function" do
      func = %Function{name: "myfunc", body: [], exported: true}

      state = session_state(functions: %{"myfunc" => func})
      {:ok, result, updates} = Export.execute(["-nf", "myfunc"], nil, state)

      assert result.exit_code == 0
      assert %{function_updates: %{"myfunc" => updated_func}} = updates
      assert updated_func.exported == false
    end

    test "returns error when function does not exist" do
      base_state = session_state()

      {result, _stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-nf", "nonexistent"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 1}} = result
      assert stderr =~ "nonexistent: not a function"
    end
  end

  describe "export -fn (unexport functions - different order)" do
    test "removes export attribute from a function" do
      func = %Function{name: "myfunc", body: [], exported: true}

      state = session_state(functions: %{"myfunc" => func})
      {:ok, result, updates} = Export.execute(["-fn", "myfunc"], nil, state)

      assert result.exit_code == 0
      assert %{function_updates: %{"myfunc" => updated_func}} = updates
      assert updated_func.exported == false
    end
  end

  describe "-- option terminator" do
    test "treats arguments after -- as names, not options" do
      state = session_state()
      {:ok, result, updates} = Export.execute(["--", "-f"], nil, state)

      # -f should be treated as a variable name, not an option
      assert result.exit_code == 0
      assert %{var_updates: %{"-f" => var}} = updates
      assert var.attributes.export == true
    end
  end

  describe "invalid options" do
    test "returns error for invalid option" do
      base_state = session_state()

      {result, _stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-x"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 1}} = result
      assert stderr =~ "-x: invalid option"
    end
  end

  describe "edge cases" do
    test "handles empty value in assignment" do
      state = session_state()
      {:ok, result, updates} = Export.execute(["FOO="], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"FOO" => var}} = updates
      assert var.value == ""
      assert var.attributes.export == true
    end

    test "handles value with equals sign" do
      state = session_state()
      {:ok, result, updates} = Export.execute(["FOO=a=b=c"], nil, state)

      assert result.exit_code == 0
      assert %{var_updates: %{"FOO" => var}} = updates
      assert var.value == "a=b=c"
    end

    test "escapes special characters in list output" do
      var = %Variable{
        value: "line1\nline2\ttab",
        attributes: %{readonly: false, export: true, integer: false, array_type: nil}
      }

      base_state = session_state(variables: %{"SPECIAL" => var})

      {result, stdout, _stderr} =
        with_output_capture(base_state, fn state ->
          Export.execute(["-p"], nil, state)
        end)

      assert {:ok, %CommandResult{}} = result
      assert stdout =~ "\\n"
      assert stdout =~ "\\t"
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
end
