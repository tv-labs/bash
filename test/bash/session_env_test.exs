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

  describe "system environment is not inherited by default" do
    setup :start_session

    test "system env vars not in bash defaults are absent", %{session: session} do
      sys_env = System.get_env()

      bash_default_keys =
        ~w(BASH BASH_VERSION BASH_VERSINFO PWD HOME USER LOGNAME PATH HOSTNAME
           HOSTTYPE MACHTYPE OSTYPE TERM SHELL SHLVL IFS PS1 PS2 PS4 HISTSIZE
           HISTFILESIZE LANG LC_ALL TMPDIR RANDOM SECONDS LINENO PPID UID EUID
           GROUPS OPTERR OPTIND COLUMNS LINES COMP_WORDBREAKS)

      non_default =
        Enum.find(sys_env, fn {k, _v} ->
          k not in bash_default_keys and not String.starts_with?(k, "_")
        end)

      if non_default do
        {key, _value} = non_default
        state = Session.get_state(session)

        assert Map.get(state.variables, key) == nil,
               "Expected system env var #{key} to NOT be in session by default"
      end
    end
  end

  describe "env_include option" do
    test "includes specified system env variables", %{test: test} do
      key = "HOME"
      expected = System.get_env(key)
      assert expected != nil, "HOME must be set for this test"

      {:ok, session} =
        Session.start_link(
          id: "env_include_#{test}",
          env_include: [key]
        )

      state = Session.get_state(session)
      assert Variable.get(state.variables[key], nil) == expected
    end

    test "excludes system env variables not in the include list", %{test: test} do
      sys_env = System.get_env()

      bash_default_keys =
        ~w(BASH BASH_VERSION BASH_VERSINFO PWD HOME USER LOGNAME PATH HOSTNAME
           HOSTTYPE MACHTYPE OSTYPE TERM SHELL SHLVL IFS PS1 PS2 PS4 HISTSIZE
           HISTFILESIZE LANG LC_ALL TMPDIR RANDOM SECONDS LINENO PPID UID EUID
           GROUPS OPTERR OPTIND COLUMNS LINES COMP_WORDBREAKS)

      non_default_keys =
        sys_env
        |> Enum.map(fn {k, _v} -> k end)
        |> Enum.reject(fn k -> k in bash_default_keys or String.starts_with?(k, "_") end)

      assert length(non_default_keys) >= 2,
             "Need at least 2 non-default env vars for this test"

      [included_key | excluded_keys] = non_default_keys

      {:ok, session} =
        Session.start_link(
          id: "env_include_filter_#{test}",
          env_include: [included_key]
        )

      state = Session.get_state(session)

      assert Map.get(state.variables, included_key) != nil

      for key <- Enum.take(excluded_keys, 3) do
        assert Map.get(state.variables, key) == nil,
               "Expected #{key} to NOT be in session with env_include"
      end
    end

    test "bash defaults are still layered on top", %{test: test} do
      {:ok, session} =
        Session.start_link(
          id: "env_include_defaults_#{test}",
          env_include: []
        )

      state = Session.get_state(session)
      assert Variable.get(state.variables["TERM"], nil) == "dumb"
      assert Variable.get(state.variables["BASH_VERSION"], nil) == "5.3"
    end
  end

  describe "env_exclude option" do
    test "inherits system env except excluded variables", %{test: test} do
      sys_env = System.get_env()

      bash_default_keys =
        ~w(BASH BASH_VERSION BASH_VERSINFO PWD HOME USER LOGNAME PATH HOSTNAME
           HOSTTYPE MACHTYPE OSTYPE TERM SHELL SHLVL IFS PS1 PS2 PS4 HISTSIZE
           HISTFILESIZE LANG LC_ALL TMPDIR RANDOM SECONDS LINENO PPID UID EUID
           GROUPS OPTERR OPTIND COLUMNS LINES COMP_WORDBREAKS)

      non_default =
        Enum.find(sys_env, fn {k, _v} ->
          k not in bash_default_keys and not String.starts_with?(k, "_")
        end)

      assert non_default != nil, "Need at least 1 non-default env var for this test"
      {excluded_key, _} = non_default

      {:ok, session} =
        Session.start_link(
          id: "env_exclude_#{test}",
          env_exclude: [excluded_key]
        )

      state = Session.get_state(session)

      assert Map.get(state.variables, excluded_key) == nil,
             "Expected #{excluded_key} to be excluded from session"
    end

    test "non-excluded system env variables are present", %{test: test} do
      sys_env = System.get_env()

      bash_default_keys =
        ~w(BASH BASH_VERSION BASH_VERSINFO PWD HOME USER LOGNAME PATH HOSTNAME
           HOSTTYPE MACHTYPE OSTYPE TERM SHELL SHLVL IFS PS1 PS2 PS4 HISTSIZE
           HISTFILESIZE LANG LC_ALL TMPDIR RANDOM SECONDS LINENO PPID UID EUID
           GROUPS OPTERR OPTIND COLUMNS LINES COMP_WORDBREAKS)

      non_defaults =
        sys_env
        |> Enum.reject(fn {k, _v} -> k in bash_default_keys or String.starts_with?(k, "_") end)

      assert length(non_defaults) >= 2,
             "Need at least 2 non-default env vars for this test"

      [{excluded_key, _} | kept] = non_defaults
      {kept_key, kept_value} = hd(kept)

      {:ok, session} =
        Session.start_link(
          id: "env_exclude_kept_#{test}",
          env_exclude: [excluded_key]
        )

      state = Session.get_state(session)
      assert Variable.get(state.variables[kept_key], nil) == kept_value
    end

    test "bash defaults are still layered on top", %{test: test} do
      {:ok, session} =
        Session.start_link(
          id: "env_exclude_defaults_#{test}",
          env_exclude: []
        )

      state = Session.get_state(session)
      assert Variable.get(state.variables["TERM"], nil) == "dumb"
    end
  end

  describe "env_include and env_exclude mutual exclusivity" do
    test "returns error when both env_include and env_exclude are provided", %{test: test} do
      assert {:error, %ArgumentError{message: message}} =
               Session.start_link(
                 id: "env_both_#{test}",
                 env_include: ["HOME"],
                 env_exclude: ["PATH"]
               )

      assert message =~ "cannot specify both"
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
