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

    @doc "Return a stream as stdout"
    defbash stream_out(args, state) do
      _ = {args, state}
      {:ok, Stream.map(1..3, &"line #{&1}\n")}
    end

    @doc "Return a stream as stderr"
    defbash stream_err(args, state) do
      _ = {args, state}
      {:error, Stream.map(1..2, &"err #{&1}\n")}
    end

    @doc "Use Bash.stream(:stdout, ...) explicitly"
    defbash explicit_stream(args, state) do
      _ = {args, state}
      Bash.stream(:stdout, Stream.map(1..3, &"chunk #{&1}\n"))
      :ok
    end

    @doc "Use Bash.stream(:stderr, ...) explicitly"
    defbash explicit_err_stream(args, state) do
      _ = {args, state}
      Bash.stream(:stderr, ["warn 1\n", "warn 2\n"])
      :ok
    end

    @doc "Update state via deep merge"
    defbash set_var(args, _state) do
      case args do
        [name, value] ->
          Bash.update_state(%{variables: %{name => Bash.Variable.new(value)}})
          :ok

        _ ->
          {:error, "usage: test.set_var NAME VALUE"}
      end
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
    defp call_with_sinks(function, args \\ []) do
      {:ok, collector} = Bash.OutputCollector.start_link()
      sink = Bash.Sink.collector(collector)
      state = %{stdout_sink: sink, stderr_sink: sink}

      result = TestAPI.__bash_call__(function, args, nil, state)
      {result, collector}
    end

    test "echo returns arguments via Bash.puts" do
      {result, collector} = call_with_sinks("echo", ["hello", "world"])
      assert {:ok, 0} = result
      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) == "hello world\n"
    end

    test "fail returns error" do
      {result, collector} = call_with_sinks("fail")
      assert {:error, "intentional failure\n"} = result

      assert IO.iodata_to_binary(Bash.OutputCollector.stderr(collector)) ==
               "intentional failure\n"
    end

    test "exit_code returns custom code" do
      {result, collector} = call_with_sinks("exit_code", ["42"])
      assert {:ok, 42} = result
      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) == ""
    end

    test "Bash.puts streams to stdout sink" do
      {result, collector} = call_with_sinks("greet", ["World"])
      assert {:ok, 0} = result
      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) == "Hello World!\n"
    end

    test "Bash.puts(:stderr, ...) streams to stderr sink" do
      {result, collector} = call_with_sinks("greet")
      assert {:ok, 1} = result

      assert IO.iodata_to_binary(Bash.OutputCollector.stderr(collector)) ==
               "usage: test.greet NAME\n"
    end

    test "only puts output" do
      {result, collector} = call_with_sinks("only_puts")
      assert {:ok, 0} = result
      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) == "from puts\n"
    end

    test "{:ok, stream} consumes stream to stdout" do
      {result, collector} = call_with_sinks("stream_out")
      assert {:ok, 0} = result

      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) ==
               "line 1\nline 2\nline 3\n"
    end

    test "{:error, stream} consumes stream to stderr" do
      {result, collector} = call_with_sinks("stream_err")
      assert {:error, ""} = result
      assert IO.iodata_to_binary(Bash.OutputCollector.stderr(collector)) == "err 1\nerr 2\n"
    end

    test "Bash.stream(:stdout, enumerable) writes to stdout sink" do
      {result, collector} = call_with_sinks("explicit_stream")
      assert {:ok, 0} = result

      assert IO.iodata_to_binary(Bash.OutputCollector.stdout(collector)) ==
               "chunk 1\nchunk 2\nchunk 3\n"
    end

    test "Bash.stream(:stderr, enumerable) writes to stderr sink" do
      {result, collector} = call_with_sinks("explicit_err_stream")
      assert {:ok, 0} = result
      assert IO.iodata_to_binary(Bash.OutputCollector.stderr(collector)) == "warn 1\nwarn 2\n"
    end

    test "Bash.update_state deep-merges into session state" do
      {:ok, collector} = Bash.OutputCollector.start_link()
      sink = Bash.Sink.collector(collector)

      state = %{
        stdout_sink: sink,
        stderr_sink: sink,
        variables: %{"EXISTING" => Bash.Variable.new("kept")}
      }

      result = TestAPI.__bash_call__("set_var", ["NEW", "value"], nil, state)

      assert {{:ok, 0}, updates} = result
      assert %{variables: variables} = updates
      assert %{"NEW" => %Bash.Variable{}} = variables
      refute Map.has_key?(variables, "EXISTING")
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
end
