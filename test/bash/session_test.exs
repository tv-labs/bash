defmodule Bash.SessionTest do
  use Bash.SessionCase, async: true

  alias Bash.Session
  alias Bash.Variable

  setup :start_session

  describe "variables" do
    test "simple assignment sets variable in session state", %{session: session} do
      run_script(session, "x=hello")
      assert get_var(session, "x") == "hello"
    end

    test "assignment with expansion resolves value", %{session: session} do
      run_script(session, "a=world; b=\"hello $a\"")
      assert get_var(session, "b") == "hello world"
    end

    test "reassignment overwrites previous value", %{session: session} do
      run_script(session, "x=first; x=second")
      assert get_var(session, "x") == "second"
    end

    test "unset removes variable", %{session: session} do
      run_script(session, "x=hello; unset x")
      assert get_var(session, "x") == nil
    end

    test "readonly variable preserves value", %{session: session} do
      run_script(session, "readonly RO=locked")
      state = Session.get_state(session)
      var = Map.get(state.variables, "RO")
      assert Variable.get(var, nil) == "locked"
      assert var.attributes[:readonly] == true
    end

    test "export marks variable with export attribute", %{session: session} do
      run_script(session, "export EXPORTED=yes")
      state = Session.get_state(session)
      var = Map.get(state.variables, "EXPORTED")
      assert Variable.get(var, nil) == "yes"
      assert var.attributes[:export] == true
    end

    test "declare -i creates integer variable", %{session: session} do
      run_script(session, "declare -i num=42")
      state = Session.get_state(session)
      var = Map.get(state.variables, "num")
      assert Variable.get(var, nil) == "42"
      assert var.attributes[:integer] == true
    end

    test "array assignment creates indexed array", %{session: session} do
      run_script(session, "arr=(one two three)")
      state = Session.get_state(session)
      arr = Map.get(state.variables, "arr")
      assert Variable.get(arr, 0) == "one"
      assert Variable.get(arr, 1) == "two"
      assert Variable.get(arr, 2) == "three"
    end

    test "special variable $? tracks last exit code", %{session: session} do
      run_script(session, "true")
      state = Session.get_state(session)
      assert state.special_vars["?"] == 0

      run_script(session, "false")
      state = Session.get_state(session)
      assert state.special_vars["?"] == 1
    end

    test "positional parameters set by set --", %{session: session} do
      run_script(session, "set -- a b c")
      result = run_script(session, "echo $1 $2 $3")
      assert get_stdout(result) == "a b c\n"
    end

    test "variable persists across separate script executions", %{session: session} do
      run_script(session, "x=persistent")
      result = run_script(session, "echo $x")
      assert get_stdout(result) == "persistent\n"
    end
  end

  describe "working directory" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    test "starts at configured working directory", %{session: session, tmp_dir: tmp_dir} do
      state = Session.get_state(session)
      assert state.working_dir == tmp_dir
    end

    test "cd changes working directory", %{session: session, tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      run_script(session, "cd #{subdir}")
      state = Session.get_state(session)
      assert state.working_dir == subdir
    end

    test "cd updates PWD variable", %{session: session, tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      run_script(session, "cd #{subdir}")
      assert get_var(session, "PWD") == subdir
    end

    test "cd to nonexistent directory fails without changing state", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      run_script(session, "cd /nonexistent_dir_xyz")
      state = Session.get_state(session)
      assert state.working_dir == tmp_dir
    end

    test "cd - returns to previous directory", %{session: session, tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      run_script(session, "cd #{subdir}")
      run_script(session, "cd -")
      state = Session.get_state(session)
      assert state.working_dir == tmp_dir
    end

    test "working directory persists across executions", %{session: session, tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "persisted")
      File.mkdir_p!(subdir)
      run_script(session, "cd #{subdir}")
      result = run_script(session, "pwd")
      assert get_stdout(result) == "#{subdir}\n"
    end
  end

  describe "executions" do
    test "command history records executions", %{session: session} do
      run_script(session, "echo first")
      run_script(session, "echo second")
      history = Session.get_command_history(session)
      assert length(history) >= 2
    end

    test "stdout is captured in execution result", %{session: session} do
      result = run_script(session, "echo captured")
      assert get_stdout(result) == "captured\n"
    end

    test "stderr is captured in execution result", %{session: session} do
      result = run_script(session, "echo error >&2")
      assert get_stderr(result) == "error\n"
    end

    test "get_output accumulates across executions", %{session: session} do
      run_script(session, "echo one")
      run_script(session, "echo two")
      {stdout, _stderr} = Session.get_output(session)
      assert stdout =~ "one"
      assert stdout =~ "two"
    end

    test "flush_output clears accumulated output", %{session: session} do
      run_script(session, "echo before")
      {stdout, _} = Session.flush_output(session)
      assert stdout =~ "before"

      {stdout_after, _} = Session.get_output(session)
      refute stdout_after =~ "before"
    end

    test "exit code is available on result", %{session: session} do
      result_ok = run_script(session, "true")
      assert result_ok.exit_code == 0

      result_fail = run_script(session, "false")
      assert result_fail.exit_code == 1
    end
  end

  describe "options" do
    test "default options include hashall and braceexpand", %{session: session} do
      state = Session.get_state(session)
      assert state.options[:hashall] == true
      assert state.options[:braceexpand] == true
    end

    test "set -e enables errexit", %{session: session} do
      run_script(session, "set -e")
      state = Session.get_state(session)
      assert state.options[:errexit] == true
    end

    test "set +e disables errexit", %{session: session} do
      run_script(session, "set -e")
      run_script(session, "set +e")
      state = Session.get_state(session)
      assert state.options[:errexit] != true
    end

    test "set -u enables nounset", %{session: session} do
      run_script(session, "set -u")
      state = Session.get_state(session)
      assert state.options[:nounset] == true
    end

    test "set -o pipefail enables pipefail", %{session: session} do
      run_script(session, "set -o pipefail")
      state = Session.get_state(session)
      assert state.options[:pipefail] == true
    end

    test "set -v enables verbose", %{session: session} do
      run_script(session, "set -v")
      state = Session.get_state(session)
      assert state.options[:verbose] == true
    end

    test "errexit causes early exit on failure", %{session: session} do
      result = run_script(session, "set -e; false; echo should_not_reach")
      assert get_stdout(result) == ""
    end

    test "nounset exits on undefined variable", %{session: session} do
      result = run_script(session, "set -u; echo $undefined_xyz")
      assert get_stdout(result) == ""
      assert result.exit_code != 0
    end

    test "pipefail reports failure from any pipeline stage", %{session: session} do
      result = run_script(session, "set -o pipefail; false | true; echo $?")
      assert get_stdout(result) == "1\n"
    end

    test "options passed at session creation are applied" do
      {:ok, session} =
        Session.new(
          id: "options_init_test",
          options: %{errexit: true, nounset: true}
        )

      state = Session.get_state(session)
      assert state.options[:errexit] == true
      assert state.options[:nounset] == true
      Session.stop(session)
    end

    test "options persist across separate executions", %{session: session} do
      run_script(session, "set -e")
      result = run_script(session, "false; echo should_not_reach")
      assert get_stdout(result) == ""
    end
  end

  describe "functions" do
    test "function definition registers in session state", %{session: session} do
      run_script(session, "greet() { echo hello; }")
      state = Session.get_state(session)
      assert Map.has_key?(state.functions, "greet")
    end

    test "function keyword syntax registers in session state", %{session: session} do
      run_script(session, "function say_hi { echo hi; }")
      state = Session.get_state(session)
      assert Map.has_key?(state.functions, "say_hi")
    end

    test "function is callable within same script", %{session: session} do
      result = run_script(session, """
      add() { local a=$1; local b=$2; local sum=$((a + b)); echo $sum; }
      add 3 4
      """)

      assert get_stdout(result) == "7\n"
    end

    test "function persists across separate executions", %{session: session} do
      run_script(session, "greet() { echo hello; }")
      result = run_script(session, "greet")
      assert get_stdout(result) == "hello\n"
    end

    test "function receives positional parameters", %{session: session} do
      result = run_script(session, """
      show() { echo "one=$1 two=$2"; }
      show a b
      """)

      assert get_stdout(result) == "one=a two=b\n"
    end

    test "local variables in functions do not leak", %{session: session} do
      result = run_script(session, """
      myfn() { local inner=secret; echo "inside=$inner"; }
      myfn
      echo "outside=${inner:-empty}"
      """)

      stdout = get_stdout(result)
      assert stdout =~ "inside=secret"
      assert stdout =~ "outside=empty"
    end

    test "unset -f removes function", %{session: session} do
      run_script(session, "foo() { echo foo; }; unset -f foo")
      state = Session.get_state(session)
      refute Map.has_key?(state.functions, "foo")
    end

    test "recursive function works", %{session: session} do
      result = run_script(session, """
      factorial() {
        if [ $1 -le 1 ]; then
          echo 1
        else
          local prev=$(factorial $(($1 - 1)))
          echo $(($1 * prev))
        fi
      }
      factorial 5
      """)

      assert get_stdout(result) == "120\n"
    end

    test "multiple functions can be defined and called", %{session: session} do
      result = run_script(session, """
      first() { echo "first"; }
      second() { echo "second"; }
      first
      second
      """)

      assert get_stdout(result) == "first\nsecond\n"
    end
  end

  describe "aliases" do
    test "alias definition is stored in session state", %{session: session} do
      run_script(session, "alias ll='ls -la'")
      state = Session.get_state(session)
      assert state.aliases["ll"] == "ls -la"
    end

    test "unalias removes alias in separate execution", %{session: session} do
      run_script(session, "alias ll='ls -la'")
      run_script(session, "unalias ll")
      state = Session.get_state(session)
      refute Map.has_key?(state.aliases, "ll")
    end

    test "alias persists across executions", %{session: session} do
      run_script(session, "alias greet='echo hello'")
      state = Session.get_state(session)
      assert state.aliases["greet"] == "echo hello"
    end

    test "multiple aliases can coexist", %{session: session} do
      run_script(session, "alias a='echo alpha'")
      run_script(session, "alias b='echo beta'")
      state = Session.get_state(session)
      assert state.aliases["a"] == "echo alpha"
      assert state.aliases["b"] == "echo beta"
    end
  end

  describe "session initialization options" do
    test "env option sets initial variables" do
      {:ok, session} =
        Session.new(
          id: "env_init_test",
          env: %{"FOO" => "bar", "BAZ" => "qux"}
        )

      assert Session.get_env(session, "FOO") == "bar"
      assert Session.get_env(session, "BAZ") == "qux"
      Session.stop(session)
    end

    test "working_dir option sets initial directory" do
      {:ok, session} = Session.new(id: "wd_init_test", working_dir: "/tmp")
      state = Session.get_state(session)
      assert state.working_dir == "/tmp"
      Session.stop(session)
    end

    test "args option sets positional parameters" do
      {:ok, session} = Session.new(id: "args_init_test", args: ["a", "b", "c"])
      result = run_script(session, "echo $1 $2 $3")
      assert get_stdout(result) == "a b c\n"
      Session.stop(session)
    end

    test "script_name option sets $0" do
      {:ok, session} = Session.new(id: "sn_init_test", script_name: "myscript.sh")
      result = run_script(session, "echo $0")
      assert get_stdout(result) == "myscript.sh\n"
      Session.stop(session)
    end

    test "call_timeout option is stored in session state" do
      {:ok, session} = Session.new(id: "ct_init_test", call_timeout: 5000)
      state = Session.get_state(session)
      assert state.call_timeout == 5000
      Session.stop(session)
    end

    test "call_timeout defaults to infinity" do
      {:ok, session} = Session.new(id: "ct_default_test")
      state = Session.get_state(session)
      assert state.call_timeout == :infinity
      Session.stop(session)
    end

    test "apis option loads elixir interop modules" do
      {:ok, session} = Session.new(id: "api_init_test", apis: [Bash.SessionTest.TestAPI])
      state = Session.get_state(session)
      assert Map.has_key?(state.elixir_modules, "session_test")
      Session.stop(session)
    end

    test "load_api adds module after creation", %{session: session} do
      Session.load_api(session, Bash.SessionTest.TestAPI)
      state = Session.get_state(session)
      assert Map.has_key?(state.elixir_modules, "session_test")
    end

    test "loaded api function is callable from scripts", %{session: session} do
      Session.load_api(session, Bash.SessionTest.TestAPI)
      result = run_script(session, "session_test.ping")
      assert get_stdout(result) == "pong\n"
    end
  end

  describe "call_timeout propagation" do
    test "call_timeout is available to builtins via session state" do
      {:ok, session} = Session.new(id: "ct_builtin_test", call_timeout: 7000)
      state = Session.get_state(session)
      assert state.call_timeout == 7000
      Session.stop(session)
    end

    test "child session gets its own call_timeout" do
      {:ok, parent} = Session.new(id: "ct_parent_test", call_timeout: 3000)
      {:ok, child} = Session.new_child(parent, id: "ct_child_test")
      child_state = Session.get_state(child)
      assert child_state.call_timeout == :infinity
      Session.stop(child)
      Session.stop(parent)
    end
  end

  describe "child sessions" do
    test "child inherits variables", %{session: session} do
      run_script(session, "export PARENT_VAR=inherited")
      {:ok, child} = Session.new_child(session)
      assert Session.get_env(child, "PARENT_VAR") == "inherited"
      Session.stop(child)
    end

    test "child inherits functions", %{session: session} do
      run_script(session, "myfn() { echo from_parent; }")
      {:ok, child} = Session.new_child(session)
      result = run_script(child, "myfn")
      assert get_stdout(result) == "from_parent\n"
      Session.stop(child)
    end

    test "child inherits options", %{session: session} do
      run_script(session, "set -e")
      {:ok, child} = Session.new_child(session)
      child_state = Session.get_state(child)
      assert child_state.options[:errexit] == true
      Session.stop(child)
    end

    test "child inherits working directory", %{session: session} do
      Session.chdir(session, "/tmp")
      {:ok, child} = Session.new_child(session)
      child_state = Session.get_state(child)
      assert child_state.working_dir =~ "tmp"
      Session.stop(child)
    end

    test "child does not inherit aliases", %{session: session} do
      run_script(session, "alias foo='echo bar'")
      {:ok, child} = Session.new_child(session)
      child_state = Session.get_state(child)
      assert child_state.aliases == %{}
      Session.stop(child)
    end

    test "child modifications do not affect parent", %{session: session} do
      run_script(session, "export SHARED=original")
      {:ok, child} = Session.new_child(session)
      run_script(child, "SHARED=modified")
      assert Session.get_env(session, "SHARED") == "original"
      Session.stop(child)
    end
  end

  describe "directory stack" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    test "pushd adds to directory stack", %{session: session, tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "pushed")
      File.mkdir_p!(subdir)
      run_script(session, "pushd #{subdir} > /dev/null")
      state = Session.get_state(session)
      assert state.working_dir == subdir
      assert length(state.dir_stack) > 0
    end

    test "popd restores previous directory", %{session: session, tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "pushed")
      File.mkdir_p!(subdir)
      run_script(session, "pushd #{subdir} > /dev/null")
      run_script(session, "popd > /dev/null")
      state = Session.get_state(session)
      assert state.working_dir == tmp_dir
    end
  end

  describe "traps" do
    test "trap registers handler in session state", %{session: session} do
      run_script(session, "trap 'echo exiting' EXIT")
      state = Session.get_state(session)
      assert Map.has_key?(state.traps, "EXIT")
    end

    test "trap - removes handler within same script", %{session: session} do
      run_script(session, "trap 'echo exiting' EXIT; trap - EXIT")
      state = Session.get_state(session)
      refute Map.has_key?(state.traps, "EXIT")
    end
  end

  describe "hash table" do
    test "hash caches command paths", %{session: session} do
      run_script(session, "hash ls 2>/dev/null")
      state = Session.get_state(session)
      assert is_map(state.hash)
    end

    test "hash -r clears the hash table", %{session: session} do
      run_script(session, "hash ls 2>/dev/null; hash -r")
      state = Session.get_state(session)
      assert state.hash == %{}
    end
  end

  describe "set_env and get_env API" do
    test "set_env sets a variable via GenServer call", %{session: session} do
      Session.set_env(session, "API_KEY", "abc123")
      assert Session.get_env(session, "API_KEY") == "abc123"
    end

    test "set_env variable is visible to scripts", %{session: session} do
      Session.set_env(session, "GREETING", "howdy")
      result = run_script(session, "echo $GREETING")
      assert get_stdout(result) == "howdy\n"
    end

    test "get_env returns nil for unset variable", %{session: session} do
      assert Session.get_env(session, "NONEXISTENT_VAR_XYZ") == nil
    end

    test "get_all_env returns all variables", %{session: session} do
      env = Session.get_all_env(session)
      assert is_map(env)
      assert Map.has_key?(env, "PATH")
    end
  end

  describe "chdir API" do
    test "chdir changes working directory", %{session: session} do
      assert :ok = Session.chdir(session, "/tmp")
      assert Session.get_cwd(session) =~ "tmp"
    end

    test "chdir to nonexistent path returns error", %{session: session} do
      assert {:error, :enoent} = Session.chdir(session, "/nonexistent_xyz")
    end
  end

  defmodule TestAPI do
    @moduledoc false
    use Bash.Interop, namespace: "session_test"

    defbash ping(_args, _state) do
      Bash.puts("pong\n")
      :ok
    end
  end
end
