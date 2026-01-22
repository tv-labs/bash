defmodule Bash.Builtin.LocalTest do
  use ExUnit.Case, async: true

  alias Bash.Builtin.Local
  alias Bash.CommandResult

  @session_state %{
    variables: %{},
    working_dir: "/tmp"
  }

  describe "local delegation to declare" do
    test "creates variable with value" do
      assert {:ok, %CommandResult{exit_code: 0}, %{var_updates: updates}} =
               Local.execute(["foo=bar"], nil, @session_state)

      assert updates["foo"].value == "bar"
    end

    test "creates variable without value" do
      assert {:ok, %CommandResult{exit_code: 0}, %{var_updates: updates}} =
               Local.execute(["foo"], nil, @session_state)

      assert Map.has_key?(updates, "foo")
    end

    test "supports -i flag for integer" do
      assert {:ok, %CommandResult{exit_code: 0}, %{var_updates: updates}} =
               Local.execute(["-i", "num=42"], nil, @session_state)

      assert updates["num"].attributes[:integer] == true
    end

    test "supports -a flag for array" do
      assert {:ok, %CommandResult{exit_code: 0}, %{var_updates: updates}} =
               Local.execute(["-a", "arr"], nil, @session_state)

      assert updates["arr"].attributes[:array_type] == :indexed
    end

    test "supports -r flag for readonly" do
      assert {:ok, %CommandResult{exit_code: 0}, %{var_updates: updates}} =
               Local.execute(["-r", "const=value"], nil, @session_state)

      assert updates["const"].attributes[:readonly] == true
    end

    test "supports -x flag for export" do
      assert {:ok, %CommandResult{exit_code: 0}, %{var_updates: updates}} =
               Local.execute(["-x", "exported=value"], nil, @session_state)

      assert updates["exported"].attributes[:export] == true
    end
  end
end
