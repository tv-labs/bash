defmodule Bash.Builtin.ShoptTest do
  @moduledoc """
  Tests for the shopt builtin.

  shopt [-pqsu] [-o] [optname ...]

  Options:
  - `-s` - Enable (set) each optname
  - `-u` - Disable (unset) each optname
  - `-q` - Quiet mode: suppress output, exit status indicates whether option is set
  - `-p` - Print in reusable format
  - `-o` - Operate on set -o options instead of shopt options
  """

  use Bash.SessionCase, async: true

  alias Bash.Session
  alias Bash.Builtin.Shopt
  alias Bash.CommandResult

  describe "shopt with no arguments" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_noargs_#{context.test}")
      {:ok, session: session}
    end

    test "lists all shopt options", %{session: session} do
      result = run_script(session, "shopt")

      assert result.exit_code == 0
      stdout = get_stdout(result)

      # Should contain common shopt options
      assert String.contains?(stdout, "extglob")
      assert String.contains?(stdout, "nullglob")
      assert String.contains?(stdout, "dotglob")
      assert String.contains?(stdout, "globstar")
    end

    test "shows on/off status for each option", %{session: session} do
      result = run_script(session, "shopt")

      stdout = get_stdout(result)

      # Each line should have either "on" or "off"
      lines = String.split(stdout, "\n", trim: true)

      assert Enum.all?(lines, fn line ->
               String.contains?(line, "on") or String.contains?(line, "off")
             end)
    end
  end

  describe "shopt -s (set/enable option)" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_set_#{context.test}")
      {:ok, session: session}
    end

    test "enables a single option", %{session: session} do
      result =
        run_script(session, """
        shopt -s extglob
        shopt extglob
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.contains?(stdout, "extglob") and String.contains?(stdout, "on")
    end

    test "enables multiple options", %{session: session} do
      result =
        run_script(session, """
        shopt -s extglob nullglob dotglob
        shopt extglob nullglob dotglob
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)

      # All three should be "on"
      lines = String.split(stdout, "\n", trim: true)

      assert Enum.all?(lines, fn line ->
               String.contains?(line, "on")
             end)
    end

    test "returns error for invalid option name", %{session: session} do
      result = run_script(session, "shopt -s invalid_option_xyz")

      assert result.exit_code == 1
      stderr = get_stderr(result)
      assert String.contains?(stderr, "invalid shell option name")
    end
  end

  describe "shopt -u (unset/disable option)" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_unset_#{context.test}")
      {:ok, session: session}
    end

    test "disables a single option", %{session: session} do
      # First enable, then disable
      result =
        run_script(session, """
        shopt -s extglob
        shopt -u extglob
        shopt extglob
        """)

      # Exit code should be 1 because extglob is now off
      assert result.exit_code == 1
      stdout = get_stdout(result)
      assert String.contains?(stdout, "extglob") and String.contains?(stdout, "off")
    end

    test "disables multiple options", %{session: session} do
      # sourcepath is on by default, so let's disable it
      result =
        run_script(session, """
        shopt -u sourcepath cmdhist
        shopt sourcepath cmdhist
        """)

      # Exit code should be 1 because both are now off
      assert result.exit_code == 1
      stdout = get_stdout(result)

      lines = String.split(stdout, "\n", trim: true)

      assert Enum.all?(lines, fn line ->
               String.contains?(line, "off")
             end)
    end
  end

  describe "shopt -q (quiet mode)" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_quiet_#{context.test}")
      {:ok, session: session}
    end

    test "returns exit code 0 when option is enabled", %{session: session} do
      result =
        run_script(session, """
        shopt -s extglob
        shopt -q extglob
        """)

      assert result.exit_code == 0
      # Output should be empty in quiet mode
      assert get_stdout(result) == ""
    end

    test "returns exit code 1 when option is disabled", %{session: session} do
      result =
        run_script(session, """
        shopt -u extglob
        shopt -q extglob
        """)

      assert result.exit_code == 1
      # Output should be empty in quiet mode
      assert get_stdout(result) == ""
    end

    test "produces no output even with multiple options", %{session: session} do
      result =
        run_script(session, """
        shopt -s extglob nullglob
        shopt -q extglob nullglob
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end
  end

  describe "shopt -p (print in reusable format)" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_print_#{context.test}")
      {:ok, session: session}
    end

    test "prints options in shopt -s/-u format", %{session: session} do
      result =
        run_script(session, """
        shopt -s extglob
        shopt -p extglob
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.contains?(stdout, "shopt -s extglob")
    end

    test "prints disabled options with -u flag", %{session: session} do
      result =
        run_script(session, """
        shopt -u extglob
        shopt -p extglob
        """)

      stdout = get_stdout(result)
      assert String.contains?(stdout, "shopt -u extglob")
    end

    test "prints all options in reusable format when no optnames given", %{session: session} do
      result = run_script(session, "shopt -p")

      assert result.exit_code == 0
      stdout = get_stdout(result)

      # Each line should start with "shopt -s " or "shopt -u "
      lines = String.split(stdout, "\n", trim: true)

      assert Enum.all?(lines, fn line ->
               String.starts_with?(line, "shopt -s ") or String.starts_with?(line, "shopt -u ")
             end)
    end
  end

  describe "shopt -o (use set -o options)" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_o_#{context.test}")
      {:ok, session: session}
    end

    test "lists set -o options instead of shopt options", %{session: session} do
      result = run_script(session, "shopt -o")

      assert result.exit_code == 0
      stdout = get_stdout(result)

      # Should contain set -o options
      assert String.contains?(stdout, "errexit")
      assert String.contains?(stdout, "pipefail")
      assert String.contains?(stdout, "nounset")
    end

    test "enables set -o option with -s -o", %{session: session} do
      result =
        run_script(session, """
        shopt -s -o errexit
        shopt -o errexit
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.contains?(stdout, "errexit") and String.contains?(stdout, "on")
    end

    test "disables set -o option with -u -o", %{session: session} do
      result =
        run_script(session, """
        shopt -s -o errexit
        shopt -u -o errexit
        shopt -o errexit
        """)

      # Exit code should be 1 because errexit is now off
      assert result.exit_code == 1
      stdout = get_stdout(result)
      assert String.contains?(stdout, "errexit") and String.contains?(stdout, "off")
    end

    test "prints set -o options in reusable format", %{session: session} do
      result =
        run_script(session, """
        shopt -s -o errexit
        shopt -p -o errexit
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.contains?(stdout, "shopt -o -s errexit")
    end
  end

  describe "combined flags" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_combined_#{context.test}")
      {:ok, session: session}
    end

    test "shopt -so works for set -o options", %{session: session} do
      result =
        run_script(session, """
        shopt -so errexit
        shopt -o errexit
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.contains?(stdout, "errexit") and String.contains?(stdout, "on")
    end

    test "shopt -qo works for quiet query of set -o options", %{session: session} do
      result =
        run_script(session, """
        shopt -so errexit
        shopt -qo errexit
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end
  end

  describe "error handling" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_errors_#{context.test}")
      {:ok, session: session}
    end

    test "returns error for invalid flag", %{session: session} do
      result = run_script(session, "shopt -x extglob")

      assert result.exit_code == 2
      stderr = get_stderr(result)
      assert String.contains?(stderr, "invalid option")
    end

    test "cannot set and unset simultaneously", %{session: session} do
      # Test via direct module call since parser may not allow this
      base_state = Session.get_state(session)

      {result, _stdout, stderr} =
        with_output_capture(base_state, fn state ->
          Shopt.execute(["-s", "-u", "extglob"], nil, state)
        end)

      assert {:ok, %CommandResult{exit_code: 2}} = result
      assert String.contains?(stderr, "cannot set and unset")
    end
  end

  describe "option persistence" do
    setup context do
      {:ok, session} = Session.start_link(id: "shopt_persist_#{context.test}")
      {:ok, session: session}
    end

    test "option value persists across commands", %{session: session} do
      # Enable extglob then query it in separate commands
      result =
        run_script(session, """
        shopt -s extglob
        shopt extglob
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert String.contains?(stdout, "on")
    end
  end

  describe "default values" do
    test "sourcepath is on by default" do
      assert Shopt.default_value("sourcepath") == true
    end

    test "extglob is off by default" do
      assert Shopt.default_value("extglob") == false
    end

    test "cmdhist is on by default" do
      assert Shopt.default_value("cmdhist") == true
    end

    test "nullglob is off by default" do
      assert Shopt.default_value("nullglob") == false
    end
  end

  describe "valid_option?/2" do
    test "recognizes valid shopt options" do
      assert Shopt.valid_option?("extglob") == true
      assert Shopt.valid_option?("nullglob") == true
      assert Shopt.valid_option?("dotglob") == true
      assert Shopt.valid_option?("globstar") == true
    end

    test "rejects invalid shopt options" do
      assert Shopt.valid_option?("not_a_real_option") == false
      # This is a set -o option
      assert Shopt.valid_option?("errexit") == false
    end

    test "recognizes valid set -o options with use_set_o: true" do
      assert Shopt.valid_option?("errexit", true) == true
      assert Shopt.valid_option?("pipefail", true) == true
      assert Shopt.valid_option?("nounset", true) == true
    end

    test "rejects shopt options when use_set_o: true" do
      assert Shopt.valid_option?("extglob", true) == false
    end
  end

  describe "shopt_option_names/0" do
    test "returns list of all shopt option names" do
      names = Shopt.shopt_option_names()

      assert is_list(names)
      assert "extglob" in names
      assert "nullglob" in names
      assert "dotglob" in names
      assert "globstar" in names
      assert "expand_aliases" in names
      assert "sourcepath" in names
    end
  end
end
