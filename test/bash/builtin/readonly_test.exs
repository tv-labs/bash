defmodule Bash.Builtin.ReadonlyTest do
  use ExUnit.Case, async: true

  alias Bash.Builtin.Readonly
  alias Bash.CommandResult

  @session_state %{
    variables: %{},
    working_dir: "/tmp"
  }

  describe "readonly with variable assignment" do
    test "creates readonly variable" do
      assert {:ok, %CommandResult{exit_code: 0}, %{variables: updates}} =
               Readonly.execute(["foo=bar"], nil, @session_state)

      assert updates["foo"].value == "bar"
      assert updates["foo"].attributes[:readonly] == true
    end

    test "creates multiple readonly variables" do
      assert {:ok, %CommandResult{exit_code: 0}, %{variables: updates}} =
               Readonly.execute(["a=1", "b=2"], nil, @session_state)

      assert updates["a"].value == "1"
      assert updates["a"].attributes[:readonly] == true
      assert updates["b"].value == "2"
      assert updates["b"].attributes[:readonly] == true
    end
  end

  describe "readonly with name only" do
    test "marks variable as readonly without value" do
      assert {:ok, %CommandResult{exit_code: 0}, %{variables: updates}} =
               Readonly.execute(["myvar"], nil, @session_state)

      assert Map.has_key?(updates, "myvar")
      assert updates["myvar"].attributes[:readonly] == true
    end
  end

  describe "readonly with -a flag" do
    test "creates readonly indexed array" do
      assert {:ok, %CommandResult{exit_code: 0}, %{variables: updates}} =
               Readonly.execute(["-a", "arr"], nil, @session_state)

      assert updates["arr"].attributes[:readonly] == true
      assert updates["arr"].attributes[:array_type] == :indexed
    end
  end

  describe "readonly with -A flag" do
    test "creates readonly associative array" do
      assert {:ok, %CommandResult{exit_code: 0}, %{variables: updates}} =
               Readonly.execute(["-A", "arr"], nil, @session_state)

      assert updates["arr"].attributes[:readonly] == true
      assert updates["arr"].attributes[:array_type] == :associative
    end
  end
end
