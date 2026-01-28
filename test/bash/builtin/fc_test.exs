defmodule Bash.Builtin.FcTest do
  @moduledoc """
  Tests for the fc builtin command history management.
  """
  use Bash.SessionCase, async: true

  setup :start_session

  describe "fc -l" do
    test "lists recent history", %{session: session} do
      run_script(session, "echo first")
      run_script(session, "echo second")
      result = run_script(session, "fc -l")
      stdout = get_stdout(result)
      assert stdout =~ "echo first"
      assert stdout =~ "echo second"
    end

    test "includes line numbers by default", %{session: session} do
      run_script(session, "echo hello")
      result = run_script(session, "fc -l")
      stdout = get_stdout(result)
      assert stdout =~ ~r/\d+\t/
    end

    test "suppresses line numbers with -n", %{session: session} do
      run_script(session, "echo hello")
      result = run_script(session, "fc -ln")
      stdout = get_stdout(result)
      refute stdout =~ ~r/^\s*\d+\t/m
      assert stdout =~ "echo hello"
    end

    test "reverses order with -r", %{session: session} do
      run_script(session, "echo first")
      run_script(session, "echo second")
      run_script(session, "echo third")
      result = run_script(session, "fc -lr")
      stdout = get_stdout(result)
      first_pos = :binary.match(stdout, "echo first") |> elem(0)
      third_pos = :binary.match(stdout, "echo third") |> elem(0)
      assert third_pos < first_pos
    end

    test "combined -lnr flags", %{session: session} do
      run_script(session, "echo first")
      run_script(session, "echo second")
      result = run_script(session, "fc -lnr")
      stdout = get_stdout(result)
      refute stdout =~ ~r/^\s*\d+\t/m
      second_pos = :binary.match(stdout, "echo second") |> elem(0)
      first_pos = :binary.match(stdout, "echo first") |> elem(0)
      assert second_pos < first_pos
    end

    test "lists specific entry by number", %{session: session} do
      run_script(session, "echo first")
      run_script(session, "echo second")
      run_script(session, "echo third")
      result = run_script(session, "fc -l 2")
      stdout = get_stdout(result)
      assert stdout =~ "echo second"
    end

    test "lists range of entries", %{session: session} do
      run_script(session, "echo first")
      run_script(session, "echo second")
      run_script(session, "echo third")
      result = run_script(session, "fc -l 1 2")
      stdout = get_stdout(result)
      assert stdout =~ "echo first"
      assert stdout =~ "echo second"
      refute stdout =~ "echo third"
    end
  end

  describe "fc -s" do
    test "re-executes last command", %{session: session} do
      run_script(session, "echo hello")
      result = run_script(session, "fc -s")
      stdout = get_stdout(result)
      assert stdout =~ "echo hello"
    end

    test "re-executes with pattern substitution", %{session: session} do
      run_script(session, "echo hello")
      result = run_script(session, "fc -s hello=world")
      stdout = get_stdout(result)
      assert stdout =~ "echo world"
    end

    test "re-executes command matching prefix", %{session: session} do
      run_script(session, "echo alpha")
      run_script(session, "echo beta")

      result =
        run_script(session, ~S"""
        fc -s "echo a"
        """)

      stdout = get_stdout(result)
      assert stdout =~ "echo alpha"
    end
  end

  describe "fc with no flags" do
    test "returns error for unsupported interactive editing", %{session: session} do
      run_script(session, "echo hello")
      result = run_script(session, "fc")
      stderr = get_stderr(result)
      assert stderr =~ "not supported"
    end
  end

  describe "fc -e" do
    test "returns error for unsupported editor mode", %{session: session} do
      run_script(session, "echo hello")
      result = run_script(session, "fc -e vim")
      stderr = get_stderr(result)
      assert stderr =~ "not supported"
    end
  end
end
