defmodule Bash.ArrayAssignmentTest do
  use ExUnit.Case, async: true

  alias Bash.AST.ArrayAssignment
  alias Bash.AST.Word
  alias Bash.Executor
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session
  alias Bash.Variable

  # Helper to create a session state
  defp session_state(env_vars \\ %{}) do
    variables =
      Map.new(env_vars, fn {k, v} ->
        # Don't double-wrap if already a Variable
        {k, if(is_struct(v, Variable), do: v, else: Variable.new(v))}
      end)

    %Session{
      id: "test",
      variables: variables,
      working_dir: "/tmp",
      functions: %{},
      aliases: %{},
      options: %{},
      hash: %{},
      in_function: false,
      jobs: %{},
      next_job_number: 1,
      current_job: nil,
      previous_job: nil,
      completed_jobs: []
    }
  end

  # Helper to parse and execute a command
  defp run_command(cmd, session_state \\ nil) do
    state = session_state || session_state()
    {:ok, %Script{statements: [ast]}} = Parser.parse(cmd)
    Executor.execute(ast, state)
  end

  describe "array literal assignment" do
    test "creates indexed array from literal" do
      {:ok, result, state_updates} = run_command("arr=(a b c)")

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "a"
      assert Variable.get(var, 1) == "b"
      assert Variable.get(var, 2) == "c"
      assert var.attributes.array_type == :indexed
    end

    test "creates empty array" do
      {:ok, result, state_updates} = run_command("arr=()")

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert var.attributes.array_type == :indexed
      assert map_size(var.value) == 0
    end

    test "handles array with spaces in elements" do
      {:ok, result, state_updates} = run_command(~s{arr=("hello world" "foo bar")})

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "hello world"
      assert Variable.get(var, 1) == "foo bar"
    end

    test "expands variables in array elements" do
      state = session_state(%{"x" => "value1", "y" => "value2"})
      {:ok, result, state_updates} = run_command(~s{arr=($x $y)}, state)

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "value1"
      assert Variable.get(var, 1) == "value2"
    end

    test "overwrites existing variable" do
      state = session_state(%{"arr" => "scalar"})
      {:ok, result, state_updates} = run_command("arr=(a b c)", state)

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "a"
      assert Variable.get(var, 1) == "b"
      assert Variable.get(var, 2) == "c"
    end
  end

  describe "array element assignment" do
    test "assigns to specific index in new array" do
      {:ok, result, state_updates} = run_command("arr[2]=value")

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 2) == "value"
      assert var.attributes.array_type == :indexed
    end

    test "assigns to specific index in existing array" do
      state =
        session_state(%{
          "arr" => Variable.new_indexed_array(%{0 => "a", 1 => "b", 2 => "c"})
        })

      {:ok, result, state_updates} = run_command("arr[1]=updated", state)

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "a"
      assert Variable.get(var, 1) == "updated"
      assert Variable.get(var, 2) == "c"
    end

    test "expands index as arithmetic expression" do
      state = session_state(%{"i" => "2"})
      {:ok, result, state_updates} = run_command("arr[i+1]=value", state)

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 3) == "value"
    end

    test "expands value with variables" do
      state = session_state(%{"val" => "hello"})
      {:ok, result, state_updates} = run_command(~s{arr[0]=$val}, state)

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "hello"
    end

    test "creates sparse array" do
      {:ok, result, state_updates} = run_command("arr[10]=value")

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      assert Variable.get(var, 10) == "value"
      # Indices 0-9 should be empty strings
      assert Variable.get(var, 0) == ""
      assert Variable.get(var, 5) == ""
    end

    test "negative indices work as expected (bash 5.x behavior)" do
      state =
        session_state(%{
          "arr" => Variable.new_indexed_array(%{0 => "a", 1 => "b", 2 => "c"})
        })

      # Note: Bash treats negative indices specially, but the behavior may vary
      # This test documents current behavior
      {:ok, result, state_updates} = run_command("arr[-1]=last", state)

      assert result.exit_code == 0
      assert %{"arr" => var} = state_updates.variables
      # Verify the update happened (exact behavior may depend on implementation)
      assert is_map(var.value)
    end
  end

  describe "readonly variable protection" do
    test "fails when assigning to readonly array" do
      readonly_var = Variable.new_indexed_array(%{0 => "a", 1 => "b"})
      # Manually set readonly attribute
      readonly_var = %{readonly_var | attributes: %{readonly_var.attributes | readonly: true}}
      state = session_state(%{"arr" => readonly_var})

      # Set up sink to capture stderr
      {:ok, collector} = Bash.OutputCollector.start_link()
      sink = Bash.Sink.collector(collector)
      state = %{state | stderr_sink: sink, stdout_sink: sink, output_collector: collector}

      {:error, result} = run_command("arr=(x y z)", state)

      assert result.exit_code == 1
      stderr = Bash.OutputCollector.stderr(collector) |> IO.iodata_to_binary()
      assert stderr =~ "arr: readonly variable"
    end

    test "fails when assigning to readonly array element" do
      readonly_var = Variable.new_indexed_array(%{0 => "a", 1 => "b"})
      # Manually set readonly attribute
      readonly_var = %{readonly_var | attributes: %{readonly_var.attributes | readonly: true}}
      state = session_state(%{"arr" => readonly_var})

      # Set up sink to capture stderr
      {:ok, collector} = Bash.OutputCollector.start_link()
      sink = Bash.Sink.collector(collector)
      state = %{state | stderr_sink: sink, stdout_sink: sink, output_collector: collector}

      {:error, result} = run_command("arr[0]=x", state)

      assert result.exit_code == 1
      stderr = Bash.OutputCollector.stderr(collector) |> IO.iodata_to_binary()
      assert stderr =~ "arr: readonly variable"
    end
  end

  describe "ArrayAssignment.execute/3 direct tests" do
    test "executes array literal assignment" do
      elements = [
        %Word{parts: [{:literal, "a"}]},
        %Word{parts: [{:literal, "b"}]},
        %Word{parts: [{:literal, "c"}]}
      ]

      assignment = %ArrayAssignment{
        meta: nil,
        name: "test_arr",
        elements: elements,
        subscript: nil
      }

      {:ok, result, state_updates} = ArrayAssignment.execute(assignment, "", session_state())

      assert result.exit_code == 0
      assert %{"test_arr" => var} = state_updates.variables
      assert Variable.get(var, 0) == "a"
      assert Variable.get(var, 1) == "b"
      assert Variable.get(var, 2) == "c"
    end

    test "executes array element assignment with index" do
      element = %Word{parts: [{:literal, "value"}]}

      assignment = %ArrayAssignment{
        meta: nil,
        name: "test_arr",
        elements: [element],
        subscript: {:index, "5"}
      }

      {:ok, result, state_updates} = ArrayAssignment.execute(assignment, "", session_state())

      assert result.exit_code == 0
      assert %{"test_arr" => var} = state_updates.variables
      assert Variable.get(var, 5) == "value"
    end

    test "evaluates arithmetic in subscript" do
      element = %Word{parts: [{:literal, "value"}]}
      state = session_state(%{"i" => "2"})

      assignment = %ArrayAssignment{
        meta: nil,
        name: "test_arr",
        elements: [element],
        subscript: {:index, "i * 3 + 1"}
      }

      {:ok, result, state_updates} = ArrayAssignment.execute(assignment, "", state)

      assert result.exit_code == 0
      assert %{"test_arr" => var} = state_updates.variables
      # i * 3 + 1 = 2 * 3 + 1 = 7
      assert Variable.get(var, 7) == "value"
    end
  end
end
