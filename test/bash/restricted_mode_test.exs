defmodule Bash.RestrictedModeTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  defmodule TestAPI do
    @moduledoc false
    use Bash.Interop, namespace: "restricted_test"

    defbash greet(args, _state) do
      name = List.first(args, "world")
      Bash.puts("hello #{name}\n")
      :ok
    end

    defbash add(args, _state) do
      sum =
        args
        |> Enum.map(&String.to_integer/1)
        |> Enum.sum()

      Bash.puts("#{sum}\n")
      :ok
    end
  end

  defp start_restricted_session(context) do
    registry_name = Module.concat([context.module, RestrictedRegistry, context.test])
    supervisor_name = Module.concat([context.module, RestrictedSupervisor, context.test])

    _registry = start_supervised!({Registry, keys: :unique, name: registry_name})

    _supervisor =
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

  describe "builtins work in restricted mode" do
    setup :start_restricted_session

    test "echo produces output", %{session: session} do
      result = run_script(session, "echo hello world")
      assert get_stdout(result) == "hello world\n"
    end

    test "printf produces formatted output", %{session: session} do
      result = run_script(session, ~s(printf "%s %s\\n" foo bar))
      assert get_stdout(result) == "foo bar\n"
    end

    test "cd to relative path works", %{session: session} do
      result = run_script(session, "cd /tmp && pwd")
      assert get_stdout(result) =~ "/tmp"
    end

    test "pwd prints working directory", %{session: session} do
      result = run_script(session, "pwd")
      assert get_stdout(result) != ""
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

  describe "external commands blocked in restricted mode" do
    setup :start_restricted_session

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

  describe "interop works in restricted mode" do
    setup :start_restricted_session

    setup %{session: session} do
      Session.load_api(session, TestAPI)
      :ok
    end

    test "interop function executes normally", %{session: session} do
      result = run_script(session, "restricted_test.greet alice")
      assert get_stdout(result) == "hello alice\n"
    end

    test "interop function with computation", %{session: session} do
      result = run_script(session, "restricted_test.add 10 20")
      assert get_stdout(result) == "30\n"
    end

    test "mixing builtins and interop in a script", %{session: session} do
      script = """
      name="world"
      restricted_test.greet $name
      echo "done"
      """

      result = run_script(session, script)
      assert get_stdout(result) =~ "hello world"
      assert get_stdout(result) =~ "done"
    end

    test "external command still blocked alongside interop", %{session: session} do
      script = """
      restricted_test.greet ok
      ls
      """

      result = run_script(session, script)
      assert get_stderr(result) =~ "restricted"
    end
  end

  describe "restricted mode inherits to child contexts" do
    setup :start_restricted_session

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

    test "eval in subshell inherits restricted mode", %{session: session} do
      result = run_script(session, ~s[(eval "ls")])
      assert get_stderr(result) =~ "restricted"
    end
  end

  describe "restricted flag is immutable" do
    setup :start_restricted_session

    test "set +o restricted does not disable restricted mode", %{session: session} do
      run_script(session, "set +o restricted")
      result = run_script(session, "ls")
      assert get_stderr(result) =~ "restricted"
    end

    test "set -o restricted is a no-op when already restricted", %{session: session} do
      run_script(session, "set -o restricted")
      state = Session.get_state(session)
      assert state.options[:restricted] == true
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
  end

  describe "unrestricted mode is unaffected" do
    setup :start_session

    test "external commands work in unrestricted mode", %{session: session} do
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "session options do not include restricted by default", %{session: session} do
      state = Session.get_state(session)
      refute state.options[:restricted]
    end

    test "builtins work normally in unrestricted mode", %{session: session} do
      result = run_script(session, "echo test && true")
      assert get_stdout(result) == "test\n"
    end
  end
end
