defmodule Bash.CommandRestrictionsTest do
  use Bash.SessionCase, async: true

  alias Bash.CommandPolicy
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

  defp start_no_external_session(context) do
    registry_name = Module.concat([context.module, NoExtRegistry, context.test])
    supervisor_name = Module.concat([context.module, NoExtSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    {:ok, session} =
      Session.new(
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name,
        command_policy: [commands: :no_external]
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
        command_policy: [commands: [{:allow, [:builtins, "cat", "echo"]}]]
      )

    {:ok, %{session: session}}
  end

  defp start_denylist_session(context) do
    registry_name = Module.concat([context.module, DenylistRegistry, context.test])
    supervisor_name = Module.concat([context.module, DenylistSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    {:ok, session} =
      Session.new(
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name,
        command_policy: [commands: [{:disallow, ["rm", "dd"]}, {:allow, :all}]]
      )

    {:ok, %{session: session}}
  end

  describe "builtins work with :no_external" do
    setup :start_no_external_session

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

  describe "external commands blocked with :no_external" do
    setup :start_no_external_session

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

  describe "interop works with :no_external" do
    setup :start_no_external_session

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

  describe "policy inherits to child contexts" do
    setup :start_no_external_session

    test "subshell inherits policy", %{session: session} do
      result = run_script(session, "(ls)")
      assert get_stderr(result) =~ "restricted"
    end

    test "command substitution inherits policy", %{session: session} do
      result = run_script(session, ~s[x=$(ls); echo "$x"])
      assert get_stderr(result) =~ "restricted"
    end

    test "eval inherits policy", %{session: session} do
      result = run_script(session, ~s[eval "ls"])
      assert get_stderr(result) =~ "restricted"
    end

    test "nested subshell inherits policy", %{session: session} do
      result = run_script(session, "( (ls) )")
      assert get_stderr(result) =~ "restricted"
    end
  end

  describe "command_policy is immutable" do
    setup :start_no_external_session

    test "set +o restricted does not disable policy", %{session: session} do
      run_script(session, "set +o restricted")
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "shopt -u restricted_shell does not disable policy", %{session: session} do
      run_script(session, "shopt -u restricted_shell")
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "shopt restricted_shell reflects actual state", %{session: session} do
      result = run_script(session, "shopt restricted_shell")
      assert get_stdout(result) =~ "on"
    end

    test "shopt restricted_shell shows off when unrestricted" do
      {:ok, session} = start_session_with_policy(nil)
      result = run_script(session, "shopt restricted_shell")
      assert get_stdout(result) =~ "off"
    end
  end

  describe "allowlist policy" do
    setup :start_allowlist_session

    test "allowed command executes", %{session: session} do
      result = run_script(session, "echo hello | cat")
      assert get_stdout(result) =~ "hello"
    end

    test "non-allowed command is blocked", %{session: session} do
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "builtins still work", %{session: session} do
      result = run_script(session, "echo test && true")
      assert get_stdout(result) == "test\n"
    end

    test "command -v for allowed returns path", %{session: session} do
      result = run_script(session, "command -v cat")
      assert get_stdout(result) =~ "cat"
    end

    test "command -v for non-allowed returns failure", %{session: session} do
      result = run_script(session, "command -v ls; echo $?")
      assert get_stdout(result) == "1\n"
    end

    test "shopt restricted_shell shows on", %{session: session} do
      result = run_script(session, "shopt restricted_shell")
      assert get_stdout(result) =~ "on"
    end
  end

  describe "denylist policy" do
    setup :start_denylist_session

    test "denied command is blocked", %{session: session} do
      result = run_script(session, "rm /nonexistent")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "non-denied command executes", %{session: session} do
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "another denied command is blocked", %{session: session} do
      result = run_script(session, "dd if=/dev/zero of=/dev/null count=1")
      assert get_stderr(result) =~ "command not allowed"
    end
  end

  describe "regex-based policy" do
    setup context do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [~r/^echo$/, ~r/^git-/]}])

      {:ok, %{session: session, test: context.test}}
    end

    test "regex match allows command", %{session: session} do
      result = run_script(session, "git-status")
      # command not found is fine — we're testing policy, not execution
      stderr = get_stderr(result)
      refute stderr =~ "command not allowed"
    end

    test "non-matching command is blocked", %{session: session} do
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "command not allowed"
    end
  end

  describe "function-based policy" do
    setup context do
      {:ok, session} =
        start_session_with_policy(commands: fn cmd -> String.starts_with?(cmd, "safe-") end)

      {:ok, %{session: session, test: context.test}}
    end

    test "function returning true allows command", %{session: session} do
      result = run_script(session, "safe-echo")
      stderr = get_stderr(result)
      refute stderr =~ "command not allowed"
    end

    test "function returning false blocks command", %{session: session} do
      result = run_script(session, "rm something")
      assert get_stderr(result) =~ "command not allowed"
    end
  end

  describe "mixed rule list" do
    setup context do
      {:ok, session} =
        start_session_with_policy(
          commands: [
            {:disallow, ["rm"]},
            {:allow, [~r/^git/]},
            fn cmd -> String.ends_with?(cmd, "-safe") end
          ]
        )

      {:ok, %{session: session, test: context.test}}
    end

    test "first matching rule wins — disallow before allow", %{session: session} do
      result = run_script(session, "rm file")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "regex allow rule matches", %{session: session} do
      result = run_script(session, "git-status")
      stderr = get_stderr(result)
      refute stderr =~ "command not allowed"
    end

    test "function rule matches", %{session: session} do
      result = run_script(session, "deploy-safe")
      stderr = get_stderr(result)
      refute stderr =~ "command not allowed"
    end

    test "no match defaults to deny", %{session: session} do
      result = run_script(session, "curl http://example.com")
      assert get_stderr(result) =~ "command not allowed"
    end
  end

  describe "exec respects all policy types" do
    test "exec with allowlist allows listed command" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins, "cat"]}])
      result = run_script(session, "exec cat /dev/null")
      refute get_stderr(result) =~ "command not allowed"
    end

    test "exec with allowlist blocks unlisted command" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins, "cat"]}])
      result = run_script(session, "exec ls")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "exec with denylist blocks denied command" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, ["rm"]}, {:allow, :all}])
      result = run_script(session, "exec rm /nonexistent")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "exec with function policy" do
      {:ok, session} =
        start_session_with_policy(commands: fn cmd -> cmd == "cat" end)

      result = run_script(session, "exec ls")
      assert get_stderr(result) =~ "command not allowed"
    end
  end

  describe "coproc respects policy" do
    test "coproc blocked with :no_external" do
      {:ok, session} = start_session_with_policy(commands: :no_external)
      result = run_script(session, "coproc cat")
      assert get_stderr(result) =~ "restricted"
    end

    test "coproc blocked with allowlist when not listed" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, ["echo"]}])
      result = run_script(session, "coproc cat")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "coproc allowed with allowlist when listed" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins, "cat"]}])
      result = run_script(session, "coproc cat; echo ok")
      refute get_stderr(result) =~ "command not allowed"
    end

    test "coproc blocked with denylist" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, ["cat"]}, {:allow, :all}])
      result = run_script(session, "coproc cat")
      assert get_stderr(result) =~ "command not allowed"
    end
  end

  describe "background jobs respect all policy types" do
    test "background job blocked with allowlist" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, ["echo"]}])
      run_script(session, "ls & wait")
      {_stdout, stderr} = Session.get_output(session)
      assert stderr =~ "command not allowed"
    end

    test "background job blocked with denylist" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, ["ls"]}, {:allow, :all}])
      run_script(session, "ls & wait")
      {_stdout, stderr} = Session.get_output(session)
      assert stderr =~ "command not allowed"
    end

    test "background job blocked with function policy" do
      {:ok, session} =
        start_session_with_policy(commands: fn cmd -> cmd == "echo" end)

      run_script(session, "ls & wait")
      {_stdout, stderr} = Session.get_output(session)
      assert stderr =~ "command not allowed"
    end
  end

  describe "pipeline respects all policy types" do
    test "pipeline with denylist blocks denied command" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, ["cat"]}, {:allow, :all}])
      result = run_script(session, "echo hello | cat")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "pipeline with function policy blocks non-matching" do
      {:ok, session} =
        start_session_with_policy(commands: fn cmd -> cmd == "sort" end)

      result = run_script(session, "echo hello | cat")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "pipeline with regex policy allows matching" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, ~r/^cat$/, ~r/^sort$/]}])

      result = run_script(session, "echo hello | cat")
      assert get_stdout(result) =~ "hello"
    end
  end

  describe "command -v respects all policy types" do
    test "command -v with denylist hides denied command" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, ["ls"]}, {:allow, :all}])
      result = run_script(session, "command -v ls; echo $?")
      assert get_stdout(result) == "1\n"
    end

    test "command -v with denylist shows non-denied command" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, ["rm"]}, {:allow, :all}])
      result = run_script(session, "command -v cat")
      assert get_stdout(result) =~ "cat"
    end

    test "command -v with function policy" do
      {:ok, session} =
        start_session_with_policy(commands: fn cmd -> cmd == "cat" end)

      result = run_script(session, "command -v cat")
      assert get_stdout(result) =~ "cat"
    end
  end

  describe "session inheritance" do
    test "new_child inherits struct policy" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, ["echo"]}])
      state = Session.get_state(session)
      assert %CommandPolicy{commands: [{:allow, _}]} = state.command_policy

      result = run_script(session, "(ls)")
      assert get_stderr(result) =~ "command not allowed"
    end

    test "session accepts pre-built struct" do
      policy = CommandPolicy.new(commands: :no_external)

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      supervisor_name = :"test_supervisor_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

      {:ok, session} =
        Session.new(
          id: "test_#{System.unique_integer([:positive])}",
          registry: registry_name,
          supervisor: supervisor_name,
          command_policy: policy
        )

      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end
  end

  describe "unrestricted mode" do
    setup :start_session

    test "external commands work", %{session: session} do
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "session has default policy", %{session: session} do
      state = Session.get_state(session)
      assert %CommandPolicy{commands: :unrestricted} = state.command_policy
    end
  end

  describe "CommandPolicy struct" do
    test "new/1 from keyword list" do
      policy = CommandPolicy.new(commands: :no_external)
      assert %CommandPolicy{commands: :no_external, paths: nil, files: nil} = policy
    end

    test "new/1 normalizes string lists to MapSet" do
      policy = CommandPolicy.new(commands: [{:allow, ["cat", "grep"]}])
      [{:allow, {strings, matchers, categories}}] = policy.commands
      assert MapSet.member?(strings, "cat")
      assert MapSet.member?(strings, "grep")
      assert matchers == []
      assert MapSet.size(categories) == 0
    end

    test "new/1 partitions strings and regex" do
      policy = CommandPolicy.new(commands: [{:allow, ["cat", ~r/^git-/]}])
      [{:allow, {strings, matchers, categories}}] = policy.commands
      assert MapSet.member?(strings, "cat")
      assert [%Regex{}] = matchers
      assert MapSet.size(categories) == 0
    end

    test "new/1 passes through struct" do
      original = %CommandPolicy{commands: :no_external}
      assert CommandPolicy.new(original) == original
    end

    test "from_state extracts command_policy" do
      policy = %CommandPolicy{commands: :no_external}
      state = %{command_policy: policy}
      assert CommandPolicy.from_state(state) == policy
    end

    test "from_state returns default for bare state" do
      assert %CommandPolicy{commands: :unrestricted} = CommandPolicy.from_state(%{})
    end

    test "check_command with :unrestricted always returns :ok" do
      policy = %CommandPolicy{}
      assert :ok = CommandPolicy.check_command(policy, "anything")
    end

    test "check_command with :no_external returns error" do
      policy = %CommandPolicy{commands: :no_external}
      assert {:error, msg} = CommandPolicy.check_command(policy, "ls")
      assert msg =~ "restricted"
    end

    test "check_command with allowlist allows listed" do
      policy = CommandPolicy.new(commands: [{:allow, ["cat", "grep"]}])
      assert :ok = CommandPolicy.check_command(policy, "cat")
      assert :ok = CommandPolicy.check_command(policy, "grep")
    end

    test "check_command with allowlist blocks unlisted" do
      policy = CommandPolicy.new(commands: [{:allow, ["cat"]}])
      assert {:error, msg} = CommandPolicy.check_command(policy, "ls")
      assert msg =~ "command not allowed"
    end

    test "check_command matches basename" do
      policy = CommandPolicy.new(commands: [{:allow, ["cat"]}])
      assert :ok = CommandPolicy.check_command(policy, "/usr/bin/cat")
    end

    test "allows_external? for :unrestricted" do
      assert CommandPolicy.allows_external?(%CommandPolicy{})
    end

    test "allows_external? for :no_external" do
      refute CommandPolicy.allows_external?(%CommandPolicy{commands: :no_external})
    end

    test "allows_external? for rule list" do
      policy = CommandPolicy.new(commands: [{:allow, ["cat"]}])
      assert CommandPolicy.allows_external?(policy)
    end

    test "allows_external? for function" do
      policy = %CommandPolicy{commands: fn _ -> true end}
      assert CommandPolicy.allows_external?(policy)
    end

    test "{:allow, :all} acts as catch-all allow" do
      policy = CommandPolicy.new(commands: [{:disallow, ["rm"]}, {:allow, :all}])
      assert :ok = CommandPolicy.check_command(policy, "ls")
      assert {:error, _} = CommandPolicy.check_command(policy, "rm")
    end

    test "rule evaluation order — first match wins" do
      policy =
        CommandPolicy.new(
          commands: [
            {:disallow, ["cat"]},
            {:allow, ["cat"]}
          ]
        )

      assert {:error, _} = CommandPolicy.check_command(policy, "cat")
    end

    test "empty rule list denies all" do
      policy = CommandPolicy.new(commands: [])
      assert {:error, _} = CommandPolicy.check_command(policy, "ls")
    end

    test "{:allow, []} with empty items skips to next rule" do
      policy = CommandPolicy.new(commands: [{:allow, []}, {:allow, ["cat"]}])
      assert :ok = CommandPolicy.check_command(policy, "cat")
      assert {:error, _} = CommandPolicy.check_command(policy, "ls")
    end

    test "{:disallow, []} with empty items skips to next rule" do
      policy = CommandPolicy.new(commands: [{:disallow, []}, {:allow, ["cat"]}])
      assert :ok = CommandPolicy.check_command(policy, "cat")
    end

    test "{:allow, :all} as sole policy allows everything" do
      policy = CommandPolicy.new(commands: [{:allow, :all}])
      assert :ok = CommandPolicy.check_command(policy, "rm")
      assert :ok = CommandPolicy.check_command(policy, "anything")
    end

    test "multiple disallow rules in sequence" do
      policy =
        CommandPolicy.new(commands: [{:disallow, ["rm"]}, {:disallow, ["dd"]}, {:allow, :all}])

      assert {:error, _} = CommandPolicy.check_command(policy, "rm")
      assert {:error, _} = CommandPolicy.check_command(policy, "dd")
      assert :ok = CommandPolicy.check_command(policy, "ls")
    end

    test "regex matches full path" do
      policy = CommandPolicy.new(commands: [{:allow, [~r/^\/usr\/bin\//]}])
      assert :ok = CommandPolicy.check_command(policy, "/usr/bin/cat")
      assert {:error, _} = CommandPolicy.check_command(policy, "/usr/local/bin/cat")
    end

    test "from_state returns default for non-struct command_policy" do
      assert %CommandPolicy{commands: :unrestricted} =
               CommandPolicy.from_state(%{command_policy: :stale_atom})
    end

    test "from_state returns default for nil command_policy" do
      assert %CommandPolicy{commands: :unrestricted} =
               CommandPolicy.from_state(%{command_policy: nil})
    end

    test "new/1 from map" do
      policy = CommandPolicy.new(%{commands: :no_external})
      assert %CommandPolicy{commands: :no_external} = policy
    end

    test "check_command with function that rejects" do
      policy = %CommandPolicy{commands: fn _cmd -> false end}
      assert {:error, msg} = CommandPolicy.check_command(policy, "anything")
      assert msg =~ "command not allowed"
    end

    test "new/1 normalizes category atoms to singular form" do
      policy = CommandPolicy.new(commands: [{:allow, [:builtins, :externals, "cat"]}])
      [{:allow, {strings, _matchers, categories}}] = policy.commands
      assert MapSet.member?(strings, "cat")
      assert MapSet.member?(categories, :builtin)
      assert MapSet.member?(categories, :external)
    end

    test "check_command/3 with :no_external allows non-external categories" do
      policy = %CommandPolicy{commands: :no_external}
      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert :ok = CommandPolicy.check_command(policy, "myfunc", :function)
      assert :ok = CommandPolicy.check_command(policy, "mymod.call", :interop)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
    end

    test "check_command/3 with category allowlist" do
      policy = CommandPolicy.new(commands: [{:allow, [:builtins]}])
      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
      assert {:error, _} = CommandPolicy.check_command(policy, "myfunc", :function)
      assert {:error, _} = CommandPolicy.check_command(policy, "mymod.call", :interop)
    end

    test "check_command/3 with mixed category and string items" do
      policy = CommandPolicy.new(commands: [{:allow, [:builtins, "cat"]}])
      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert :ok = CommandPolicy.check_command(policy, "cat", :external)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
    end

    test "check_command/3 with {:disallow, :all}" do
      policy = CommandPolicy.new(commands: [{:disallow, :all}])
      assert {:error, _} = CommandPolicy.check_command(policy, "echo", :builtin)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
      assert {:error, _} = CommandPolicy.check_command(policy, "myfunc", :function)
    end

    test "check_command/3 disallow category then allow :all" do
      policy = CommandPolicy.new(commands: [{:disallow, [:externals]}, {:allow, :all}])
      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
      assert :ok = CommandPolicy.check_command(policy, "myfunc", :function)
    end

    test "check_command/3 with fun/2 receives category" do
      policy = %CommandPolicy{
        commands: fn _name, category -> category in [:builtin, :function] end
      }

      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert :ok = CommandPolicy.check_command(policy, "myfunc", :function)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
      assert {:error, _} = CommandPolicy.check_command(policy, "mymod.call", :interop)
    end

    test "check_command/3 with fun/1 only fires for :external" do
      policy = %CommandPolicy{commands: fn _cmd -> false end}
      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert :ok = CommandPolicy.check_command(policy, "myfunc", :function)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
    end

    test "fun/1 in rule list only evaluates for :external" do
      policy = CommandPolicy.new(commands: [fn _cmd -> false end])
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
      # fun/1 is skipped for non-external, falls through to implicit deny
      assert {:error, _} = CommandPolicy.check_command(policy, "echo", :builtin)
    end

    test "fun/2 in rule list evaluates for all categories" do
      policy =
        CommandPolicy.new(commands: [fn _name, category -> category == :builtin end])

      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
    end

    test "check_command/2 defaults to :external" do
      policy = CommandPolicy.new(commands: [{:allow, [:builtins]}])
      assert {:error, _} = CommandPolicy.check_command(policy, "ls")
    end

    test "command_allowed?/3 works with category" do
      policy = CommandPolicy.new(commands: [{:allow, [:builtins]}])
      assert CommandPolicy.command_allowed?(policy, "echo", :builtin)
      refute CommandPolicy.command_allowed?(policy, "ls", :external)
    end

    test "category atoms with :disallow block by category" do
      policy =
        CommandPolicy.new(commands: [{:disallow, [:builtins]}, {:allow, :all}])

      assert {:error, _} = CommandPolicy.check_command(policy, "echo", :builtin)
      assert :ok = CommandPolicy.check_command(policy, "ls", :external)
    end

    test "multiple categories in one rule" do
      policy =
        CommandPolicy.new(commands: [{:allow, [:builtins, :functions, :interop]}])

      assert :ok = CommandPolicy.check_command(policy, "echo", :builtin)
      assert :ok = CommandPolicy.check_command(policy, "myfunc", :function)
      assert :ok = CommandPolicy.check_command(policy, "mymod.call", :interop)
      assert {:error, _} = CommandPolicy.check_command(policy, "ls", :external)
    end
  end

  describe "category-aware: builtins only" do
    test "allows builtins" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins]}])
      assert get_stdout(run_script(session, "echo hello")) == "hello\n"
    end

    test "blocks externals" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins]}])
      assert get_stderr(run_script(session, "cat /dev/null")) =~ "command not allowed"
    end

    test "blocks functions" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins]}])

      assert get_stderr(run_script(session, "greet() { echo hi; }; greet")) =~
               "command not allowed"
    end

    test "blocks interop" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:builtins]}])
      Session.load_api(session, TestAPI)

      assert get_stderr(run_script(session, "restrict_test.greet alice")) =~
               "command not allowed"
    end
  end

  describe "category-aware: externals only" do
    test "allows externals" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:externals]}])
      result = run_script(session, "cat /dev/null")
      refute get_stderr(result) =~ "command not allowed"
    end

    test "blocks builtins" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:externals]}])
      assert get_stderr(run_script(session, "echo hello")) =~ "command not allowed"
    end

    test "blocks functions" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:externals]}])

      assert get_stderr(run_script(session, "greet() { echo hi; }; greet")) =~
               "command not allowed"
    end

    test "blocks interop" do
      {:ok, session} = start_session_with_policy(commands: [{:allow, [:externals]}])
      Session.load_api(session, TestAPI)

      assert get_stderr(run_script(session, "restrict_test.greet alice")) =~
               "command not allowed"
    end
  end

  describe "category-aware: functions only" do
    test "allows functions" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :functions]}])

      assert get_stdout(run_script(session, "greet() { echo hi; }; greet")) == "hi\n"
    end

    test "blocks externals" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :functions]}])

      assert get_stderr(run_script(session, "cat /dev/null")) =~ "command not allowed"
    end

    test "blocks interop" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :functions]}])

      Session.load_api(session, TestAPI)

      assert get_stderr(run_script(session, "restrict_test.greet alice")) =~
               "command not allowed"
    end
  end

  describe "category-aware: interop only" do
    test "allows interop" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :interop]}])

      Session.load_api(session, TestAPI)

      assert get_stdout(run_script(session, "restrict_test.greet alice")) ==
               "hello alice\n"
    end

    test "blocks externals" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :interop]}])

      assert get_stderr(run_script(session, "cat /dev/null")) =~ "command not allowed"
    end

    test "blocks functions" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :interop]}])

      assert get_stderr(run_script(session, "greet() { echo hi; }; greet")) =~
               "command not allowed"
    end
  end

  describe "category-aware: builtins + externals" do
    test "allows both builtins and externals" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :externals]}])

      assert get_stdout(run_script(session, "echo hello")) == "hello\n"
      result = run_script(session, "cat /dev/null")
      refute get_stderr(result) =~ "command not allowed"
    end

    test "blocks functions" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :externals]}])

      assert get_stderr(run_script(session, "greet() { echo hi; }; greet")) =~
               "command not allowed"
    end

    test "blocks interop" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :externals]}])

      Session.load_api(session, TestAPI)

      assert get_stderr(run_script(session, "restrict_test.greet alice")) =~
               "command not allowed"
    end
  end

  describe "category-aware: builtins + functions + interop (no externals)" do
    test "allows builtins, functions, and interop" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :functions, :interop]}])

      Session.load_api(session, TestAPI)
      assert get_stdout(run_script(session, "echo hello")) == "hello\n"

      assert get_stdout(run_script(session, "greet() { echo hi; }; greet")) == "hi\n"

      assert get_stdout(run_script(session, "restrict_test.greet alice")) ==
               "hello alice\n"
    end

    test "blocks externals" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, :functions, :interop]}])

      assert get_stderr(run_script(session, "cat /dev/null")) =~ "command not allowed"
    end
  end

  describe "category-aware: disallow specific categories" do
    test "disallow externals, allow everything else" do
      {:ok, session} =
        start_session_with_policy(commands: [{:disallow, [:externals]}, {:allow, :all}])

      assert get_stdout(run_script(session, "echo hello")) == "hello\n"
      assert get_stderr(run_script(session, "cat /dev/null")) =~ "command not allowed"
    end

    test "disallow interop, allow everything else" do
      {:ok, session} =
        start_session_with_policy(commands: [{:disallow, [:interop]}, {:allow, :all}])

      Session.load_api(session, TestAPI)
      assert get_stdout(run_script(session, "echo hello")) == "hello\n"

      assert get_stderr(run_script(session, "restrict_test.greet alice")) =~
               "command not allowed"
    end

    test "disallow functions, allow everything else" do
      {:ok, session} =
        start_session_with_policy(commands: [{:disallow, [:functions]}, {:allow, :all}])

      assert get_stdout(run_script(session, "echo hello")) == "hello\n"

      assert get_stderr(run_script(session, "greet() { echo hi; }; greet")) =~
               "command not allowed"
    end

    test "disallow builtins, allow everything else" do
      {:ok, session} =
        start_session_with_policy(commands: [{:disallow, [:builtins]}, {:allow, :all}])

      assert get_stderr(run_script(session, "echo hello")) =~ "command not allowed"
    end
  end

  describe "category-aware: disallow specific commands by name" do
    test "block specific builtin by name" do
      {:ok, session} =
        start_session_with_policy(commands: [{:disallow, ["eval"]}, {:allow, :all}])

      assert get_stderr(run_script(session, "eval 'echo hi'")) =~ "command not allowed"
      assert get_stdout(run_script(session, "echo works")) == "works\n"
    end

    test "block specific external by name with categories allowed" do
      {:ok, session} =
        start_session_with_policy(
          commands: [{:disallow, ["rm"]}, {:allow, [:builtins, :externals]}]
        )

      result = run_script(session, "cat /dev/null")
      refute get_stderr(result) =~ "command not allowed"
      assert get_stderr(run_script(session, "rm /nonexistent")) =~ "command not allowed"
    end
  end

  describe "category-aware: block everything" do
    test "{:disallow, :all} blocks all categories" do
      {:ok, session} = start_session_with_policy(commands: [{:disallow, :all}])
      assert get_stderr(run_script(session, "echo hello")) =~ "command not allowed"
    end
  end

  describe "category-aware: builtins + specific externals" do
    test "allows builtins and named externals" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, "cat"]}])

      assert get_stdout(run_script(session, "echo hello")) == "hello\n"
      result = run_script(session, "cat /dev/null")
      refute get_stderr(result) =~ "command not allowed"
    end

    test "blocks unlisted externals" do
      {:ok, session} =
        start_session_with_policy(commands: [{:allow, [:builtins, "cat"]}])

      assert get_stderr(run_script(session, "ls /tmp")) =~ "command not allowed"
    end
  end

  describe "category-aware: fun/2 policy" do
    test "fun/2 receives category for gating" do
      {:ok, session} =
        start_session_with_policy(
          commands: fn _name, category -> category in [:builtin, :function] end
        )

      assert get_stdout(run_script(session, "echo hello")) == "hello\n"
      assert get_stderr(run_script(session, "cat /dev/null")) =~ "command not allowed"
    end

    test "fun/2 can gate by both name and category" do
      {:ok, session} =
        start_session_with_policy(
          commands: fn name, category ->
            category == :builtin or (category == :external and name == "cat")
          end
        )

      assert get_stdout(run_script(session, "echo hello")) == "hello\n"
      result = run_script(session, "cat /dev/null")
      refute get_stderr(result) =~ "command not allowed"
      assert get_stderr(run_script(session, "ls /tmp")) =~ "command not allowed"
    end
  end

  defp start_session_with_policy(nil) do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    supervisor_name = :"test_supervisor_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    Session.new(
      id: "test_#{System.unique_integer([:positive])}",
      registry: registry_name,
      supervisor: supervisor_name
    )
  end

  defp start_session_with_policy(policy_opts) do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    supervisor_name = :"test_supervisor_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    Session.new(
      id: "test_#{System.unique_integer([:positive])}",
      registry: registry_name,
      supervisor: supervisor_name,
      command_policy: policy_opts
    )
  end
end
