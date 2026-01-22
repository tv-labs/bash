defmodule Bash.InteropTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Bash.Session

  import Bash.Sigil

  # Test API module defined inline
  defmodule TestAPI do
    use Bash.Interop, namespace: "test"

    @doc "Echo arguments back"
    defbash echo(args, state) do
      _ = state
      Bash.puts(Enum.join(args, " ") <> "\n")
      :ok
    end

    @doc "Return an error"
    defbash fail(args, state) do
      _ = {args, state}
      {:error, "intentional failure\n"}
    end

    @doc "Return a custom exit code"
    defbash exit_code(args, state) do
      _ = state
      code = args |> List.first() |> String.to_integer()
      {:ok, code}
    end

    @doc "Use Bash.puts for output"
    defbash greet(args, state) do
      _ = state

      case args do
        [name | _] ->
          Bash.puts("Hello ")
          Bash.puts("#{name}!\n")
          :ok

        [] ->
          Bash.puts(:stderr, "usage: test.greet NAME\n")
          {:ok, 1}
      end
    end

    @doc "Only puts output"
    defbash only_puts(args, state) do
      _ = {args, state}
      Bash.puts("from puts\n")
      :ok
    end

    @doc "Access session state"
    defbash get_assign(args, state) do
      case args do
        [key | _] ->
          value = get_in(state, [:assigns, String.to_atom(key)]) || ""
          Bash.puts("#{value}\n")
          :ok

        [] ->
          {:error, "usage: test.get_assign KEY"}
      end
    end
  end

  describe "defbash macro" do
    test "generates __bash_namespace__/0" do
      assert TestAPI.__bash_namespace__() == "test"
    end

    test "generates __bash_functions__/0" do
      functions = TestAPI.__bash_functions__()
      assert "echo" in functions
      assert "fail" in functions
      assert "greet" in functions
    end

    test "generates catch-all for undefined functions" do
      result = TestAPI.__bash_call__("nonexistent", [], nil, %{})
      assert {:exit, 127, opts} = result
      assert opts[:stderr] =~ "function not found"
    end
  end

  describe "defbash function calls" do
    test "echo returns arguments via Bash.puts" do
      assert {:ok, 0, opts} = TestAPI.__bash_call__("echo", ["hello", "world"], nil, %{})
      assert Keyword.get(opts, :stdout) == "hello world\n"
    end

    test "fail returns error" do
      result = TestAPI.__bash_call__("fail", [], nil, %{})
      assert {:error, "intentional failure\n"} = result
    end

    test "exit_code returns custom code" do
      assert {:ok, 42, opts} = TestAPI.__bash_call__("exit_code", ["42"], nil, %{})
      assert Keyword.get(opts, :stdout) == ""
      assert Keyword.get(opts, :stderr) == ""
    end

    test "Bash.puts accumulates output" do
      assert {:ok, 0, opts} = TestAPI.__bash_call__("greet", ["World"], nil, %{})
      assert Keyword.get(opts, :stdout) == "Hello World!\n"
    end

    test "Bash.puts(:stderr, ...) accumulates stderr" do
      assert {:ok, 1, opts} = TestAPI.__bash_call__("greet", [], nil, %{})
      assert Keyword.get(opts, :stdout) == ""
      assert Keyword.get(opts, :stderr) == "usage: test.greet NAME\n"
    end

    test "only puts output" do
      assert {:ok, 0, opts} = TestAPI.__bash_call__("only_puts", [], nil, %{})
      assert Keyword.get(opts, :stdout) == "from puts\n"
    end
  end

  describe "Session.load_api/2" do
    test "loads module into session state" do
      {:ok, pid} = Session.new()

      Session.load_api(pid, TestAPI)
      state = Session.get_state(pid)

      assert Map.has_key?(state.elixir_modules, "test")
      assert state.elixir_modules["test"] == TestAPI
    end

    test "raises for invalid module" do
      {:ok, pid} = Session.new()

      # Since load_api goes through GenServer, the ArgumentError is wrapped in an exit
      capture_log(fn ->
        assert catch_exit(Session.load_api(pid, Enum))
      end)
    end

    test "list_apis returns loaded namespaces" do
      {:ok, pid} = Session.new()

      Session.load_api(pid, TestAPI)
      state = Session.get_state(pid)
      namespaces = Session.list_apis(state)

      assert "test" in namespaces
    end
  end

  describe "integration with Bash.run" do
    setup do
      {:ok, pid} = Session.new()
      Session.load_api(pid, TestAPI)
      state = Session.get_state(pid)

      {:ok, session_pid: pid, state: state}
    end

    # Helper to execute with sinks set up for output collection
    defp execute_with_sinks(ast, state) do
      {:ok, collector} = Bash.OutputCollector.start_link()
      sink = Bash.Sink.collector(collector)

      state_with_sinks = %{
        state
        | output_collector: collector,
          stdout_sink: sink,
          stderr_sink: sink
      }

      result =
        case Bash.Executor.execute(ast, state_with_sinks) do
          {:ok, executed, updated_state} -> {:ok, executed, updated_state}
          {:error, executed, updated_state} -> {:error, executed, updated_state}
          other -> other
        end

      {result, collector}
    end

    test "calls defbash function via command resolution", %{state: state} do
      ast = ~BASH"test.echo hello world"

      {{:ok, result, _updated_state}, collector} = execute_with_sinks(ast, state)

      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) == "hello world\n"
      assert result.exit_code == 0
    end

    test "undefined function returns exit 127", %{state: state} do
      ast = ~BASH"test.nonexistent"

      {{status, result, _updated_state}, collector} = execute_with_sinks(ast, state)

      assert status in [:ok, :error]
      assert result.exit_code == 127
      assert IO.iodata_to_binary(Bash.OutputCollector.stderr(collector)) =~ "function not found"
    end

    test "error function returns exit 1", %{state: state} do
      ast = ~BASH"test.fail"

      {{status, result, _updated_state}, collector} = execute_with_sinks(ast, state)

      assert status in [:ok, :error]
      assert result.exit_code == 1

      assert IO.iodata_to_binary(Bash.OutputCollector.stderr(collector)) ==
               "intentional failure\n"
    end
  end
end
