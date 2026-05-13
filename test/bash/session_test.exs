defmodule Bash.SessionTest do
  use Bash.SessionCase, async: true
  import ExUnit.CaptureLog

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
      result =
        run_script(session, """
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
      result =
        run_script(session, """
        show() { echo "one=$1 two=$2"; }
        show a b
        """)

      assert get_stdout(result) == "one=a two=b\n"
    end

    test "local variables in functions do not leak", %{session: session} do
      result =
        run_script(session, """
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
      result =
        run_script(session, """
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
      result =
        run_script(session, """
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

    test "returns clear error when module does not exist" do
      capture_log(fn ->
        assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
                 Session.new(apis: [DoesNotExist.Module.AtAll])

        assert message =~ "could not be loaded"
      end)
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

  describe "execute_async/3 and await/2" do
    test "returns ExecRef and resolves via await", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("echo hello")
      assert {:ok, %Session.ExecRef{} = ref} = Session.execute_async(session, ast)
      assert {:ok, _result} = Session.await(ref)
    end

    test "await with timeout returns {:error, :timeout} for long script", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("while true; do :; done")
      {:ok, ref} = Session.execute_async(session, ast)
      assert {:error, :timeout} = Session.await(ref, 50)
      Session.signal(ref, :sigint)
    end

    test "await reports session_down if session crashes mid-execution", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("while true; do :; done")
      {:ok, ref} = Session.execute_async(session, ast)

      capture_log(fn ->
        Process.exit(session, :kill)
        assert {:error, {:session_down, :killed}} = Session.await(ref, 1000)
      end)
    end

    test "concurrent execute_async calls queue and run sequentially", %{session: session} do
      Session.load_api(session, Bash.SessionTest.TestAPI)
      pid = pid_arg(self())

      # Each chunk reports when it starts. Sequential execution implies
      # ast1 reports start, finishes, ast2 reports start. Any parallel
      # execution would interleave or deliver ast2's start before ast1's
      # body completes.
      {:ok, ast1} =
        Bash.Parser.parse("session_test.notify '#{pid}'; echo a; echo b")

      {:ok, ast2} =
        Bash.Parser.parse("session_test.notify '#{pid}'; echo c; echo d")

      {:ok, ref1} = Session.execute_async(session, ast1)
      {:ok, ref2} = Session.execute_async(session, ast2)
      assert ref1 != ref2

      # ast1 begins immediately; ast2 must NOT have started yet
      assert_receive :script_running, 1000
      refute_received :script_running

      # await ast1; only after that does ast2 start
      assert {:ok, _} = Session.await(ref1, 1000)
      assert_receive :script_running, 1000

      assert {:ok, _} = Session.await(ref2, 1000)

      # Output appears in strictly sequential order.
      assert session_stdout(session) == "a\nb\nc\nd\n"
    end
  end

  describe "signal/2" do
    setup %{session: session} do
      Session.load_api(session, Bash.SessionTest.TestAPI)
      :ok
    end

    defp running_loop_script(test_pid) do
      """
      session_test.notify '#{pid_arg(test_pid)}'
      while true; do :; done
      """
    end

    defp start_loop(session) do
      {:ok, ast} = Bash.Parser.parse(running_loop_script(self()))
      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      ref
    end

    test "signal(session, :sigint) cancels foreground with exit 130", %{session: session} do
      ref = start_loop(session)
      assert :ok = Session.signal(session, :sigint)
      assert {:error, %{exit_code: 130, error: :cancelled}} = Session.await(ref, 1000)
    end

    test "signal(ref, :sigint) cancels that specific execution", %{session: session} do
      ref = start_loop(session)
      assert :ok = Session.signal(ref, :sigint)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 1000)
    end

    test "signal(ref, :sigkill) returns exit code 137", %{session: session} do
      ref = start_loop(session)
      assert :ok = Session.signal(ref, :sigkill)
      assert {:error, %{exit_code: 137}} = Session.await(ref, 1000)
    end

    test "signal(session, :sigint) is {:error, :not_found} when idle", %{session: session} do
      assert {:error, :not_found} = Session.signal(session, :sigint)
    end

    test "signal(stale_ref, :sigint) returns :not_found after that execution finishes",
         %{session: session} do
      {:ok, ast} = Bash.Parser.parse("echo done")
      {:ok, ref} = Session.execute_async(session, ast)
      {:ok, _} = Session.await(ref)
      assert {:error, :not_found} = Session.signal(ref, :sigint)
    end

    test "session state is preserved after cancellation", %{session: session} do
      run_script(session, "x=42")
      ref = start_loop(session)
      Session.signal(ref, :sigint)
      Session.await(ref, 1000)

      assert get_var(session, "x") == "42"
    end

    test "session is usable after cancellation", %{session: session} do
      ref = start_loop(session)
      Session.signal(ref, :sigint)
      Session.await(ref, 1000)

      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "stdout written before cancel is preserved on the session", %{session: session} do
      pid = pid_arg(self())

      {:ok, ast} =
        Bash.Parser.parse("""
        echo before-cancel
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      Session.signal(ref, :sigint)
      Session.await(ref, 1000)

      assert session_stdout(session) =~ "before-cancel"
    end

    test "stderr written before cancel is preserved on the session", %{session: session} do
      pid = pid_arg(self())

      {:ok, ast} =
        Bash.Parser.parse("""
        echo oops >&2
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      Session.signal(ref, :sigint)
      Session.await(ref, 1000)

      assert session_stderr(session) =~ "oops"
    end

    test "INT trap runs on :sigint and its output is collected", %{session: session} do
      pid = pid_arg(self())

      {:ok, ast} =
        Bash.Parser.parse("""
        trap 'echo trap-ran' INT
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      Session.signal(ref, :sigint)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 1000)

      assert session_stdout(session) =~ "trap-ran"
    end

    test "EXIT trap also runs on :sigint", %{session: session} do
      pid = pid_arg(self())

      {:ok, ast} =
        Bash.Parser.parse("""
        trap 'echo on-exit' EXIT
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      Session.signal(ref, :sigint)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 1000)

      assert session_stdout(session) =~ "on-exit"
    end

    test ":sigterm runs TERM trap and exits 143", %{session: session} do
      pid = pid_arg(self())

      {:ok, ast} =
        Bash.Parser.parse("""
        trap 'echo term-ran' TERM
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      Session.signal(ref, :sigterm)
      assert {:error, %{exit_code: 143}} = Session.await(ref, 1000)

      assert session_stdout(session) =~ "term-ran"
    end

    test ":sigkill bypasses traps", %{session: session} do
      pid = pid_arg(self())

      {:ok, ast} =
        Bash.Parser.parse("""
        trap 'echo should-not-run' INT
        trap 'echo also-not' EXIT
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000
      Session.signal(ref, :sigkill)
      assert {:error, %{exit_code: 137}} = Session.await(ref, 1000)

      refute session_stdout(session) =~ "should-not-run"
      refute session_stdout(session) =~ "also-not"
    end

    test "non-loop scripts also yield to cancellation between statements",
         %{session: session} do
      pid = pid_arg(session)

      {:ok, ast} =
        Bash.Parser.parse("""
        echo first
        session_test.cancel_now '#{pid}'
        echo should-not-run
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 1000)

      stdout = session_stdout(session)
      assert stdout =~ "first"
      refute stdout =~ "should-not-run"
    end

    test ":grace escalates to :sigkill when cooperative cancel doesn't land",
         %{session: session} do
      pid = pid_arg(self())

      # session_test.spin is a defbash with no yield points — cooperative
      # cancel can't land while it's running.
      {:ok, ast} =
        Bash.Parser.parse("""
        session_test.notify '#{pid}'
        session_test.spin
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000

      Session.signal(ref, :sigint, grace: 50)
      assert {:error, %{exit_code: 137, error: :cancelled}} = Session.await(ref, 1000)
    end

    test ":grace does not escalate when cancel lands within the window",
         %{session: session} do
      pid = pid_arg(self())

      # while-true yields every iteration — cancel lands fast.
      {:ok, ast} =
        Bash.Parser.parse("""
        session_test.notify '#{pid}'
        while true; do :; done
        """)

      {:ok, %Session.ExecRef{ref: internal_ref} = ref} = Session.execute_async(session, ast)
      assert_receive :script_running, 1000

      Session.signal(ref, :sigint, grace: 5_000)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 1000)

      # Simulate the stale force_kill timer firing after the cooperative
      # cancel already cleared current_execution. The catch-all handle_info
      # clause must absorb it without affecting subsequent work.
      send(session, {:force_kill, internal_ref})

      assert {:error, :not_found} = Session.signal(session, :sigint)
      assert {:ok, _} = Session.execute(session, elem(Bash.Parser.parse("echo ok"), 1))
    end

    test "abnormal Task crash surfaces an error and clears current_execution",
         %{session: session} do
      {:ok, ast} = Bash.Parser.parse("session_test.boom")

      capture_log(fn ->
        {:ok, ref} = Session.execute_async(session, ast)
        assert {:error, %{error: {:task_crashed, _}}} = Session.await(ref, 1000)
      end)

      # Session is still alive and accepts new executions
      assert {:error, :not_found} = Session.signal(session, :sigint)
      assert {:ok, _result} = Session.execute(session, elem(Bash.Parser.parse("echo ok"), 1))
    end
  end

  describe "execute_async queue" do
    setup %{session: session} do
      Session.load_api(session, Bash.SessionTest.TestAPI)
      :ok
    end

    test "cancelling current drains pending and runs the next", %{session: session} do
      pid_self = pid_arg(self())
      pid_session = pid_arg(session)

      {:ok, looping} =
        Bash.Parser.parse("""
        session_test.notify '#{pid_self}'
        while true; do :; done
        """)

      {:ok, follow_up} = Bash.Parser.parse("echo follow-up")

      {:ok, ref1} = Session.execute_async(session, looping)
      {:ok, ref2} = Session.execute_async(session, follow_up)

      assert_receive :script_running, 1000
      Session.signal(session, :sigint)

      assert {:error, %{exit_code: 130}} = Session.await(ref1, 1000)
      assert {:ok, _} = Session.await(ref2, 1000)
      assert session_stdout(session) =~ "follow-up"

      # State after cancel + drain: idle, ready for more
      assert {:error, :not_found} = Session.signal(session, :sigint)
      _ = pid_session
    end

    test "signal(pending_ref, :sigint) cancels a queued execution with exit 130",
         %{session: session} do
      {:ok, ast1} =
        Bash.Parser.parse(
          "session_test.notify '#{pid_arg(self())}'; sleep_loop=true; while $sleep_loop; do :; done"
        )

      {:ok, ast2} = Bash.Parser.parse("echo should-not-run")

      {:ok, ref1} = Session.execute_async(session, ast1)
      {:ok, ref2} = Session.execute_async(session, ast2)

      assert_receive :script_running, 1000
      assert :ok = Session.signal(ref2, :sigint)
      assert {:error, %{exit_code: 130, error: :cancelled}} = Session.await(ref2, 1000)

      Session.signal(ref1, :sigint)
      Session.await(ref1, 1000)

      refute session_stdout(session) =~ "should-not-run"
    end

    test "signal(pending_ref, :sigterm) yields exit 143", %{session: session} do
      {:ok, ast1} =
        Bash.Parser.parse("session_test.notify '#{pid_arg(self())}'; while true; do :; done")

      {:ok, ast2} = Bash.Parser.parse("echo never")

      {:ok, ref1} = Session.execute_async(session, ast1)
      {:ok, ref2} = Session.execute_async(session, ast2)

      assert_receive :script_running, 1000
      assert :ok = Session.signal(ref2, :sigterm)
      assert {:error, %{exit_code: 143}} = Session.await(ref2, 1000)

      Session.signal(ref1, :sigint)
      Session.await(ref1, 1000)
    end

    test "signal(unknown_ref, :sigint) returns :not_found", %{session: session} do
      stale = %Session.ExecRef{
        session: session,
        ref: make_ref(),
        monitor: Process.monitor(session)
      }

      assert {:error, :not_found} = Session.signal(stale, :sigint)
    end

    test "cancelling pending does not affect current or other pending", %{session: session} do
      {:ok, looping} =
        Bash.Parser.parse("session_test.notify '#{pid_arg(self())}'; while true; do :; done")

      {:ok, ast2} = Bash.Parser.parse("echo two")
      {:ok, ast3} = Bash.Parser.parse("echo three")

      {:ok, ref1} = Session.execute_async(session, looping)
      {:ok, ref2} = Session.execute_async(session, ast2)
      {:ok, ref3} = Session.execute_async(session, ast3)

      assert_receive :script_running, 1000
      assert :ok = Session.signal(ref2, :sigint)

      Session.signal(ref1, :sigint)
      assert {:error, %{exit_code: 130}} = Session.await(ref1, 1000)
      assert {:error, %{exit_code: 130}} = Session.await(ref2, 1000)
      assert {:ok, _} = Session.await(ref3, 1000)

      assert session_stdout(session) =~ "three"
      refute session_stdout(session) =~ "two"
    end
  end

  describe "cancellation with command policy and virtual filesystem" do
    alias Bash.Filesystem.ETS, as: FS

    defp start_restricted_ets_session(context) do
      table = FS.new(%{"/workspace/data.txt" => "seed\n"})

      registry_name = Module.concat([context.module, ETSRegistry, context.test])
      supervisor_name = Module.concat([context.module, ETSSupervisor, context.test])

      start_supervised!({Registry, keys: :unique, name: registry_name}, id: registry_name)

      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: supervisor_name},
        id: supervisor_name
      )

      {:ok, session} =
        Session.new(
          id: "#{context.test}",
          filesystem: {FS, table},
          working_dir: "/workspace",
          registry: registry_name,
          supervisor: supervisor_name,
          command_policy: [commands: :no_external],
          apis: [Bash.SessionTest.TestAPI]
        )

      {session, table}
    end

    defp pid_arg(pid), do: pid |> :erlang.pid_to_list() |> to_string()

    test "cancels mid-stream while writing to virtual filesystem", context do
      {session, table} = start_restricted_ets_session(context)
      pid = pid_arg(session)

      {:ok, ast} =
        Bash.Parser.parse("""
        i=0
        while [ $i -lt 100 ]; do
          echo "line $i" >> output.txt
          if [ $i -eq 5 ]; then
            session_test.cancel_now '#{pid}'
          fi
          i=$((i + 1))
        done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 5000)

      # Partial writes that landed before the cancel are preserved in the VFS
      assert {:ok, contents} = FS.read(table, "/workspace/output.txt")
      for i <- 1..5, do: assert(contents =~ "line #{i}")
      refute contents =~ "line 6"

      # The session is still alive and the VFS still works
      run_script(session, "echo done >> done.txt")
      assert {:ok, "done\n"} = FS.read(table, "/workspace/done.txt")
    end

    test "cancels mid-stream while reading from virtual filesystem", context do
      {session, _table} = start_restricted_ets_session(context)
      pid = pid_arg(session)

      run_script(session, "echo content > big.txt")

      {:ok, ast} =
        Bash.Parser.parse("""
        n=0
        while [ $n -lt 100 ]; do
          contents=$(cat big.txt)
          echo "$contents" >> log.txt
          n=$((n + 1))
          if [ $n -eq 10 ]; then
            session_test.cancel_now '#{pid}'
          fi
        done
        """)

      {:ok, ref} = Session.execute_async(session, ast)
      assert {:error, %{exit_code: 130}} = Session.await(ref, 5000)

      result = run_script(session, "echo still-here")
      assert get_stdout(result) =~ "still-here"
    end

    test "command policy still enforces after cancellation", context do
      {session, _table} = start_restricted_ets_session(context)
      pid = pid_arg(session)

      {:ok, ast} = Bash.Parser.parse("session_test.cancel_now '#{pid}'; :")
      {:ok, ref} = Session.execute_async(session, ast)
      Session.await(ref, 5000)

      # External commands remain blocked by policy after cancel
      result = run_script(session, "ls /etc")
      assert result.exit_code != 0
    end

    test "session state persists across cancel with VFS + policy", context do
      {session, table} = start_restricted_ets_session(context)
      pid = pid_arg(session)
      run_script(session, "x=hello-world")

      {:ok, ast} = Bash.Parser.parse("session_test.cancel_now '#{pid}'; :")
      {:ok, ref} = Session.execute_async(session, ast)
      Session.await(ref, 5000)

      assert get_var(session, "x") == "hello-world"
      assert {:ok, "seed\n"} = FS.read(table, "/workspace/data.txt")
    end
  end

  defmodule TestAPI do
    @moduledoc false
    use Bash.Interop, namespace: "session_test"

    defbash ping(_args, _state) do
      Bash.puts("pong\n")
      :ok
    end

    defbash cancel_now([pid_str], _state) do
      pid = pid_str |> String.to_charlist() |> :erlang.list_to_pid()
      Bash.Session.signal(pid, :sigint)
      :ok
    end

    defbash notify([pid_str], _state) do
      pid = pid_str |> String.to_charlist() |> :erlang.list_to_pid()
      send(pid, :script_running)
      :ok
    end

    defbash boom(_args, _state) do
      raise "boom"
    end

    defbash spin(_args, _state) do
      spin_loop()
    end

    defp spin_loop, do: spin_loop()
  end
end
