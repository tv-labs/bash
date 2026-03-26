defmodule Bash.CommandRestrictionsTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  defmodule TestAPI do
    @moduledoc false
    use Bash.Interop, namespace: "restrict_test"

    defbash greet(args, _state) do
      name = List.first(args, "world")
      Bash.puts("hello #{name}\n")
      :ok
    end
  end

  defp start_disallow_session(context) do
    registry_name = Module.concat([context.module, DisallowRegistry, context.test])
    supervisor_name = Module.concat([context.module, DisallowSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    {:ok, session} =
      Session.new(
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name,
        options: %{command_policy: :disallow_external}
      )

    {:ok, %{session: session}}
  end

  defp start_allowlist_session(context) do
    registry_name = Module.concat([context.module, AllowlistRegistry, context.test])
    supervisor_name = Module.concat([context.module, AllowlistSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    {:ok, session} =
      Session.new(
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name,
        options: %{command_policy: {:allow, ["cat", "echo"]}}
      )

    {:ok, %{session: session}}
  end

  defp start_restricted_compat_session(context) do
    registry_name = Module.concat([context.module, CompatRegistry, context.test])
    supervisor_name = Module.concat([context.module, CompatSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    {:ok, session} =
      Session.new(
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name,
        options: %{restricted: true}
      )

    {:ok, %{session: session}}
  end

  describe "builtins work with :disallow_external" do
    setup :start_disallow_session

    test "echo produces output", %{session: session} do
      result = run_script(session, "echo hello world")
      assert get_stdout(result) == "hello world\n"
    end

    test "printf produces formatted output", %{session: session} do
      result = run_script(session, ~s(printf "%s %s\\n" foo bar))
      assert get_stdout(result) == "foo bar\n"
    end

    test "cd and pwd work", %{session: session} do
      result = run_script(session, "cd /tmp && pwd")
      assert get_stdout(result) =~ "/tmp"
    end

    test "variable assignment and expansion", %{session: session} do
      result = run_script(session, ~s(x=hello; echo "$x"))
      assert get_stdout(result) == "hello\n"
    end

    test "arithmetic evaluation", %{session: session} do
      result = run_script(session, "echo $((2 + 3))")
      assert get_stdout(result) == "5\n"
    end

    test "if/else conditional", %{session: session} do
      result = run_script(session, ~s(if true; then echo yes; else echo no; fi))
      assert get_stdout(result) == "yes\n"
    end

    test "for loop", %{session: session} do
      result = run_script(session, "for i in a b c; do echo $i; done")
      assert get_stdout(result) == "a\nb\nc\n"
    end

    test "while loop", %{session: session} do
      script = """
      i=0
      while [ $i -lt 3 ]; do
        echo $i
        i=$((i + 1))
      done
      """

      result = run_script(session, script)
      assert get_stdout(result) == "0\n1\n2\n"
    end

    test "function definition and invocation", %{session: session} do
      script = """
      greet() { echo "hi $1"; }
      greet alice
      """

      result = run_script(session, script)
      assert get_stdout(result) == "hi alice\n"
    end

    test "array operations", %{session: session} do
      script = """
      arr=(one two three)
      echo ${arr[1]}
      """

      result = run_script(session, script)
      assert get_stdout(result) == "two\n"
    end

    test "string manipulation via parameter expansion", %{session: session} do
      script = """
      str="hello world"
      echo ${str^^}
      """

      result = run_script(session, script)
      assert get_stdout(result) == "HELLO WORLD\n"
    end
  end

  describe "external commands blocked with :disallow_external" do
    setup :start_disallow_session

    test "simple external command is rejected", %{session: session} do
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "absolute path command is rejected", %{session: session} do
      result = run_script(session, "/bin/ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "command builtin with external is rejected", %{session: session} do
      result = run_script(session, "command ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "command -v for external returns failure", %{session: session} do
      result = run_script(session, "command -v ls; echo $?")
      assert get_stdout(result) == "1\n"
    end

    test "exec with external is rejected", %{session: session} do
      result = run_script(session, "exec ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "pipeline containing external command is rejected", %{session: session} do
      result = run_script(session, "echo hello | cat")
      assert get_stderr(result) =~ "restricted"
    end

    test "pipeline of only external commands is rejected", %{session: session} do
      result = run_script(session, "ls | cat")
      assert get_stderr(result) =~ "restricted"
    end

    test "command substitution with external is rejected", %{session: session} do
      result = run_script(session, ~s[echo "$(ls)"])
      assert get_stderr(result) =~ "restricted"
    end

    test "subshell with external is rejected", %{session: session} do
      result = run_script(session, "(ls)")
      assert get_stderr(result) =~ "restricted"
    end

    test "external command returns non-zero exit code", %{session: session} do
      result = run_script(session, "ls; echo $?")
      stdout = get_stdout(result)
      refute stdout =~ "0\n"
    end

    test "background job with external is rejected", %{session: session} do
      run_script(session, "ls & wait")
      {_stdout, stderr} = Session.get_output(session)
      assert stderr =~ "restricted"
    end
  end

  describe "interop works with :disallow_external" do
    setup :start_disallow_session

    setup %{session: session} do
      Session.load_api(session, TestAPI)
      :ok
    end

    test "interop function executes normally", %{session: session} do
      result = run_script(session, "restrict_test.greet alice")
      assert get_stdout(result) == "hello alice\n"
    end

    test "mixing builtins and interop in a script", %{session: session} do
      script = """
      name="world"
      restrict_test.greet $name
      echo "done"
      """

      result = run_script(session, script)
      assert get_stdout(result) =~ "hello world"
      assert get_stdout(result) =~ "done"
    end

    test "external command still blocked alongside interop", %{session: session} do
      script = """
      restrict_test.greet ok
      ls
      """

      result = run_script(session, script)
      assert get_stderr(result) =~ "restricted"
    end
  end

  describe "restricted mode inherits to child contexts" do
    setup :start_disallow_session

    test "subshell inherits restricted mode", %{session: session} do
      result = run_script(session, "(ls)")
      assert get_stderr(result) =~ "restricted"
    end

    test "command substitution inherits restricted mode", %{session: session} do
      result = run_script(session, ~s[x=$(ls); echo "$x"])
      assert get_stderr(result) =~ "restricted"
    end

    test "eval inherits restricted mode", %{session: session} do
      result = run_script(session, ~s[eval "ls"])
      assert get_stderr(result) =~ "restricted"
    end

    test "nested subshell inherits restricted mode", %{session: session} do
      result = run_script(session, "( (ls) )")
      assert get_stderr(result) =~ "restricted"
    end
  end

  describe "command_policy is immutable" do
    setup :start_disallow_session

    test "set +o restricted does not disable restricted mode", %{session: session} do
      run_script(session, "set +o restricted")
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "shopt -u restricted_shell does not disable restricted mode", %{session: session} do
      run_script(session, "shopt -u restricted_shell")
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "shopt restricted_shell reflects actual state", %{session: session} do
      result = run_script(session, "shopt restricted_shell")
      assert get_stdout(result) =~ "on"
    end

    test "shopt restricted_shell shows off when unrestricted" do
      {:ok, session} = start_session_with_opts(%{})
      result = run_script(session, "shopt restricted_shell")
      assert get_stdout(result) =~ "off"
    end
  end

  describe "{:allow, whitelist} policy" do
    setup :start_allowlist_session

    test "whitelisted command executes", %{session: session} do
      result = run_script(session, "echo hello | cat")
      assert get_stdout(result) =~ "hello"
    end

    test "non-whitelisted command is blocked", %{session: session} do
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "builtins still work", %{session: session} do
      result = run_script(session, "echo test && true")
      assert get_stdout(result) == "test\n"
    end

    test "command -v for whitelisted returns path", %{session: session} do
      result = run_script(session, "command -v cat")
      assert get_stdout(result) =~ "cat"
    end

    test "command -v for non-whitelisted returns failure", %{session: session} do
      result = run_script(session, "command -v ls; echo $?")
      assert get_stdout(result) == "1\n"
    end

    test "shopt restricted_shell shows on", %{session: session} do
      result = run_script(session, "shopt restricted_shell")
      assert get_stdout(result) =~ "on"
    end
  end

  describe "backwards compatibility: restricted: true" do
    setup :start_restricted_compat_session

    test "external commands are blocked", %{session: session} do
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "builtins still work", %{session: session} do
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "session has command_policy set", %{session: session} do
      state = Session.get_state(session)
      assert state.options[:command_policy] == :disallow_external
      refute Map.has_key?(state.options, :restricted)
    end
  end

  describe "unrestricted mode is unaffected" do
    setup :start_session

    test "external commands work in unrestricted mode", %{session: session} do
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "session options do not include command_policy by default", %{session: session} do
      state = Session.get_state(session)
      refute Map.has_key?(state.options, :command_policy)
    end
  end

  describe "CommandPolicy module" do
    alias Bash.CommandPolicy

    test "from_state returns :unrestricted for bare state" do
      assert CommandPolicy.from_state(%{}) == :unrestricted
    end

    test "from_state extracts command_policy" do
      state = %{options: %{command_policy: :disallow_external}}
      assert CommandPolicy.from_state(state) == :disallow_external
    end

    test "check :unrestricted always returns :ok" do
      assert :ok = CommandPolicy.check(:unrestricted, "anything")
    end

    test "check :disallow_external returns error" do
      assert {:error, msg} = CommandPolicy.check(:disallow_external, "ls")
      assert msg =~ "restricted"
    end

    test "check {:allow, whitelist} allows whitelisted" do
      policy = {:allow, MapSet.new(["cat", "grep"])}
      assert :ok = CommandPolicy.check(policy, "cat")
      assert :ok = CommandPolicy.check(policy, "grep")
    end

    test "check {:allow, whitelist} blocks non-whitelisted" do
      policy = {:allow, MapSet.new(["cat"])}
      assert {:error, msg} = CommandPolicy.check(policy, "ls")
      assert msg =~ "command not allowed"
    end

    test "check {:allow, whitelist} matches basename" do
      policy = {:allow, MapSet.new(["cat"])}
      assert :ok = CommandPolicy.check(policy, "/usr/bin/cat")
    end

    test "normalize_options converts restricted: true" do
      opts = %{restricted: true, hashall: true}
      result = CommandPolicy.normalize_options(opts)
      assert result[:command_policy] == :disallow_external
      refute Map.has_key?(result, :restricted)
      assert result[:hashall] == true
    end

    test "normalize_options is no-op without restricted" do
      opts = %{hashall: true}
      assert CommandPolicy.normalize_options(opts) == opts
    end

    test "normalize_options preserves existing command_policy" do
      policy = {:allow, MapSet.new(["cat"])}
      opts = %{restricted: true, command_policy: policy}
      result = CommandPolicy.normalize_options(opts)
      assert result[:command_policy] == policy
    end

    test "normalize_options converts allow list to MapSet" do
      opts = %{command_policy: {:allow, ["cat", "grep"]}}
      result = CommandPolicy.normalize_options(opts)
      assert result[:command_policy] == {:allow, MapSet.new(["cat", "grep"])}
    end
  end

  defp start_session_with_opts(options) do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    supervisor_name = :"test_supervisor_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    Session.new(
      id: "test_#{System.unique_integer([:positive])}",
      registry: registry_name,
      supervisor: supervisor_name,
      options: options
    )
  end
end
