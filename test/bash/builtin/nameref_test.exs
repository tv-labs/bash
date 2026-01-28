defmodule Bash.Builtin.NamerefTest do
  use Bash.SessionCase, async: true

  setup :start_session

  describe "declare -n (nameref)" do
    test "basic nameref reads target variable value", %{session: session} do
      run_script(session, """
      target="original value"
      declare -n ref=target
      echo "$ref"
      """)

      assert session_stdout(session) == "original value\n"
    end

    test "assignment through nameref modifies target", %{session: session} do
      run_script(session, """
      target="original"
      declare -n ref=target
      ref="modified"
      echo "$target"
      """)

      assert session_stdout(session) == "modified\n"
    end

    test "nameref works with arrays", %{session: session} do
      run_script(session, """
      myarray=(one two three)
      declare -n ref=myarray
      echo "${ref[1]}"
      """)

      assert session_stdout(session) == "two\n"
    end

    test "array assignment through nameref", %{session: session} do
      run_script(session, """
      myarray=(one two three)
      declare -n ref=myarray
      ref[1]="modified"
      echo "${myarray[1]}"
      """)

      assert session_stdout(session) == "modified\n"
    end

    test "nameref chain (nameref to nameref)", %{session: session} do
      run_script(session, """
      original="deep value"
      declare -n ref1=original
      declare -n ref2=ref1
      echo "$ref2"
      """)

      assert session_stdout(session) == "deep value\n"
    end

    test "nameref with unset target returns empty", %{session: session} do
      run_script(session, """
      declare -n ref=nonexistent
      echo "value: '$ref'"
      """)

      assert session_stdout(session) == "value: ''\n"
    end

    test "assignment through nameref to unset target creates variable", %{session: session} do
      run_script(session, """
      declare -n ref=newvar
      ref="created"
      echo "$newvar"
      """)

      assert session_stdout(session) == "created\n"
    end
  end

  describe "Variable.nameref?/1" do
    test "returns true for nameref variable", %{session: session} do
      run_script(session, """
      target="value"
      declare -n ref=target
      """)

      state = Bash.Session.get_state(session)
      ref_var = Map.get(state.variables, "ref")

      assert Bash.Variable.nameref?(ref_var) == true
    end

    test "returns false for regular variable", %{session: session} do
      run_script(session, "target=\"value\"")

      state = Bash.Session.get_state(session)
      target_var = Map.get(state.variables, "target")

      assert Bash.Variable.nameref?(target_var) == false
    end
  end

  describe "Variable.nameref_target/1" do
    test "returns target name for nameref", %{session: session} do
      run_script(session, """
      target="value"
      declare -n ref=target
      """)

      state = Bash.Session.get_state(session)
      ref_var = Map.get(state.variables, "ref")

      assert Bash.Variable.nameref_target(ref_var) == "target"
    end

    test "returns nil for regular variable", %{session: session} do
      run_script(session, "target=\"value\"")

      state = Bash.Session.get_state(session)
      target_var = Map.get(state.variables, "target")

      assert Bash.Variable.nameref_target(target_var) == nil
    end
  end
end
