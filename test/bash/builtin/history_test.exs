defmodule Bash.Builtin.HistoryTest do
  use ExUnit.Case, async: true

  import Bash.Sigil

  alias Bash
  alias Bash.Session
  alias Bash.ExecutionResult
  alias Bash.Builtin.History

  describe "history -c (clear history)" do
    test "clears all command history" do
      {:ok, session} = Session.new()

      # Run some commands to build up history
      {:ok, _result, session} = Bash.run(~b"echo first", session)
      {:ok, _result, session} = Bash.run(~b"echo second", session)
      {:ok, _result, session} = Bash.run(~b"echo third", session)

      # Verify history has 3 entries
      history = Session.get_command_history(session)
      assert length(history) == 3

      # Clear history
      {:ok, result, session} = Bash.run(~b"history -c", session)
      assert result.exit_code == 0

      # Verify history is now empty
      history_after_clear = Session.get_command_history(session)
      assert length(history_after_clear) == 0
    end
  end

  describe "history -d offset (delete entry)" do
    test "deletes entry at valid positive offset" do
      {:ok, session} = Session.new()

      # Build up history
      {:ok, _result, session} = Bash.run(~b"echo first", session)
      {:ok, _result, session} = Bash.run(~b"echo second", session)
      {:ok, _result, session} = Bash.run(~b"echo third", session)

      # Delete the second entry (1-based index)
      {:ok, result, session} = Bash.run(~b"history -d 2", session)
      assert result.exit_code == 0

      # Verify we now have 3 entries (the deleted entry was removed, but history -d was added)
      # Resulting history: "echo first", "echo third", "history"
      history = Session.get_command_history(session)
      assert length(history) == 3
      # Use to_string() to get command representation from AST nodes
      assert to_string(Enum.at(history, 0)) =~ "echo"
      assert to_string(Enum.at(history, 1)) =~ "echo"
      assert to_string(Enum.at(history, 2)) =~ "history"
    end

    test "deletes entry at valid negative offset" do
      {:ok, session} = Session.new()

      # Build up history
      {:ok, _result, session} = Bash.run(~b"echo first", session)
      {:ok, _result, session} = Bash.run(~b"echo second", session)
      {:ok, _result, session} = Bash.run(~b"echo third", session)

      # Delete the last entry using negative offset
      # This will delete "echo third" before "history -d -1" is added
      {:ok, result, session} = Bash.run(~b"history -d -1", session)
      assert result.exit_code == 0

      # Verify we now have 3 entries ("echo first", "echo second", "history")
      history = Session.get_command_history(session)
      assert length(history) == 3
    end

    test "returns error for out of range offset" do
      {:ok, session} = Session.new()

      {:ok, _result, session} = Bash.run(~b"echo first", session)

      # Try to delete entry that doesn't exist
      {:ok, result, _session} = Bash.run(~b"history -d 100", session)
      assert result.exit_code == 1
      # Check stderr output for error message
      assert ExecutionResult.stderr(result) =~ "out of range"
    end
  end

  describe "history (list)" do
    test "lists all history entries" do
      {:ok, session} = Session.new()

      {:ok, _result, session} = Bash.run(~b"echo first", session)
      {:ok, _result, session} = Bash.run(~b"echo second", session)

      {:ok, result, _session} = Bash.run(~b"history", session)
      assert result.exit_code == 0

      output = ExecutionResult.stdout(result)
      assert output =~ "1  echo"
      assert output =~ "2  echo"
    end

    test "lists last N entries when count is specified" do
      {:ok, session} = Session.new()

      {:ok, _result, session} = Bash.run(~b"echo first", session)
      {:ok, _result, session} = Bash.run(~b"echo second", session)
      {:ok, _result, session} = Bash.run(~b"echo third", session)

      {:ok, result, _session} = Bash.run(~b"history 2", session)
      assert result.exit_code == 0

      output = ExecutionResult.stdout(result)
      lines = String.split(output, "\n", trim: true)
      assert length(lines) == 2
    end
  end

  describe "History.format_history/2" do
    test "formats command results with line numbers" do
      {:ok, session} = Session.new()

      {:ok, _result, session} = Bash.run(~b"echo hello", session)
      {:ok, _result, session} = Bash.run(~b"pwd", session)

      history = Session.get_command_history(session)
      formatted = History.format_history(history)

      assert formatted =~ "1  echo"
      assert formatted =~ "2  pwd"
    end

    test "formats with custom count" do
      {:ok, session} = Session.new()

      {:ok, _result, session} = Bash.run(~b"echo one", session)
      {:ok, _result, session} = Bash.run(~b"echo two", session)
      {:ok, _result, session} = Bash.run(~b"echo three", session)

      history = Session.get_command_history(session)
      formatted = History.format_history(history, count: 2)

      lines = String.split(formatted, "\n", trim: true)
      assert length(lines) == 2
    end
  end
end
