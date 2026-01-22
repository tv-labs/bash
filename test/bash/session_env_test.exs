defmodule Bash.SessionEnvTest do
  use Bash.SessionCase, async: true

  alias Bash.Session
  alias Bash.Variable

  describe "Default Bash Environment Variables" do
    setup :start_session

    test "sets BASH_VERSION", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "BASH_VERSION")
      assert var != nil
      assert Variable.get(var, nil) == "5.3"
    end

    test "sets PWD to working directory", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "PWD")
      assert var != nil
      assert Variable.get(var, nil) != ""
    end

    test "sets HOME", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "HOME")
      assert var != nil
      assert Variable.get(var, nil) != ""
    end

    test "sets PATH", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "PATH")
      assert var != nil
      assert Variable.get(var, nil) != ""
    end

    test "sets HOSTNAME", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "HOSTNAME")
      assert var != nil
      assert Variable.get(var, nil) != ""
    end

    test "sets HOSTTYPE", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "HOSTTYPE")
      assert var != nil
      assert Variable.get(var, nil) != ""
    end

    test "sets MACHTYPE", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "MACHTYPE")
      assert var != nil
      # MACHTYPE can be from env or calculated
      assert Variable.get(var, nil) != ""
    end

    test "sets OSTYPE", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "OSTYPE")
      assert var != nil
      assert Variable.get(var, nil) != ""
    end

    test "sets TERM to dumb", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "TERM")
      assert var != nil
      assert Variable.get(var, nil) == "dumb"
    end

    test "sets HISTSIZE", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "HISTSIZE")
      assert var != nil
      assert Variable.get(var, nil) == "500"
    end

    test "sets HISTFILESIZE", %{session: session} do
      state = Session.get_state(session)
      var = Map.get(state.variables, "HISTFILESIZE")
      assert var != nil
      assert Variable.get(var, nil) == "500"
    end
  end

  describe "env option" do
    test "env variables are available in session" do
      {:ok, session} =
        Session.start_link(
          id: "env_test_#{:erlang.unique_integer()}",
          env: %{"MY_CUSTOM_VAR" => "custom_value", "ANOTHER_VAR" => "/some/path"}
        )

      state = Session.get_state(session)

      my_var = Map.get(state.variables, "MY_CUSTOM_VAR")
      assert my_var != nil
      assert Variable.get(my_var, nil) == "custom_value"

      another_var = Map.get(state.variables, "ANOTHER_VAR")
      assert another_var != nil
      assert Variable.get(another_var, nil) == "/some/path"
    end

    test "env variables can be used in variable expansion" do
      alias Bash
      import Bash.Sigil

      {:ok, result, _session} =
        Bash.run(
          ~b"echo $TOOLKIT/utils",
          env: %{"TOOLKIT" => "/path/to/toolkit"}
        )

      assert result.exit_code == 0
      assert Bash.stdout(result) =~ "/path/to/toolkit/utils"
    end

    test "env variables override defaults" do
      {:ok, session} =
        Session.start_link(
          id: "env_override_#{:erlang.unique_integer()}",
          env: %{"PATH" => "/custom/path"}
        )

      state = Session.get_state(session)
      path_var = Map.get(state.variables, "PATH")
      assert Variable.get(path_var, nil) == "/custom/path"
    end
  end
end
