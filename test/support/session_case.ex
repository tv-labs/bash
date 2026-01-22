defmodule Bash.SessionCase do
  @moduledoc """
  Test case template for tests that need a Bash session.

  Provides a `start_session/1` setup helper that creates an isolated
  session with its own registry and supervisor for each test.

  ## Usage

      defmodule MyTest do
        use Bash.SessionCase, async: true

        setup :start_session

        test "does something", %{session: session} do
          # Use session here
        end
      end

  ## Options

  You can configure the session by adding tags to your tests:

      @describetag :tmp_dir  # Provides a tmp_dir in context
      @describetag working_dir: :tmp_dir  # Sets session working_dir to tmp_dir

  """

  alias Bash.Session

  use ExUnit.CaseTemplate

  using do
    quote do
      import Bash.SessionCase
      alias Bash.Output
      alias Bash.ExecutionResult
    end
  end

  @doc """
  Helper to run a script through session and return result.
  Parses the script and executes through Session.execute.

  Handles all execution outcomes:
  - `{:ok, result}` - Normal completion
  - `{:exit, result}` - Early exit (errexit, onecmd, etc.)
  - `{:error, result}` - Error completion
  """
  def run_script(session, script) do
    {:ok, ast} = Bash.Parser.parse(String.trim(script))

    case Session.execute(session, ast) do
      {:ok, result} -> result
      {:exit, result} -> result
      {:error, result} -> result
    end
  end

  @doc """
  Get stdout from an execution result.

  Note: With the sink-based architecture, CommandResult no longer stores output.
  For tests, use `Session.get_output/1` or `Session.flush_output/1` instead to
  get accumulated output from the session.
  """
  def get_stdout(result), do: Bash.ExecutionResult.stdout(result)

  @doc """
  Get stderr from an execution result.

  Note: With the sink-based architecture, CommandResult no longer stores output.
  For tests, use `Session.get_output/1` or `Session.flush_output/1` instead to
  get accumulated output from the session.
  """
  def get_stderr(result), do: Bash.ExecutionResult.stderr(result)

  @doc """
  Get accumulated stdout from a session.

  Returns all stdout captured by the session since it was started or last flushed.
  """
  def session_stdout(session) do
    {stdout, _stderr} = Session.get_output(session)
    stdout
  end

  @doc """
  Get accumulated stderr from a session.

  Returns all stderr captured by the session since it was started or last flushed.
  """
  def session_stderr(session) do
    {_stdout, stderr} = Session.get_output(session)
    stderr
  end

  @doc """
  Flush and return accumulated output from a session.

  Clears the output buffer and returns {stdout, stderr}.
  """
  def flush_session_output(session), do: Session.flush_output(session)

  @doc """
  Execute a builtin function with sink-based output capture.

  This is for testing builtins directly without going through a full Session.
  Returns {result, stdout, stderr} where result is the builtin's return value.

  ## Example

      {result, stdout, stderr} = with_output_capture(fn state ->
        Echo.execute(["hello"], nil, state)
      end)
      assert {:ok, %CommandResult{exit_code: 0}} = result
      assert stdout == "hello\\n"
  """
  def with_output_capture(fun) when is_function(fun, 1) do
    with_output_capture(%{}, fun)
  end

  def with_output_capture(base_state, fun) when is_map(base_state) and is_function(fun, 1) do
    {:ok, collector} = Bash.OutputCollector.start_link()
    sink = Bash.Sink.collector(collector)

    state =
      Map.merge(
        base_state,
        %{
          stdout_sink: sink,
          stderr_sink: sink
        }
      )
      |> Map.put_new(:variables, %{})
      |> Map.put_new(:working_dir, System.tmp_dir!())

    result = fun.(state)

    {stdout_iodata, stderr_iodata} = Bash.OutputCollector.output(collector)
    GenServer.stop(collector)

    {result, IO.iodata_to_binary(stdout_iodata), IO.iodata_to_binary(stderr_iodata)}
  end

  @doc """
  Create a session state suitable for direct builtin testing.

  Returns a state map with sinks configured for output capture.
  Use `get_captured_output/1` to retrieve the output afterwards.
  """
  def test_state(opts \\ []) do
    {:ok, collector} = Bash.OutputCollector.start_link()
    sink = Bash.Sink.collector(collector)

    base_state = %{
      variables: Keyword.get(opts, :variables, %{}),
      working_dir: Keyword.get(opts, :working_dir, System.tmp_dir!()),
      stdout_sink: sink,
      stderr_sink: sink,
      _test_collector: collector
    }

    Map.merge(base_state, Map.new(opts))
  end

  @doc """
  Get captured output from a test state created with `test_state/1`.
  """
  def get_captured_output(%{_test_collector: collector}) do
    {stdout_iodata, stderr_iodata} = Bash.OutputCollector.output(collector)
    {IO.iodata_to_binary(stdout_iodata), IO.iodata_to_binary(stderr_iodata)}
  end

  @doc """
  Get a variable value from the session.
  """
  def get_var(session, name) do
    state = Session.get_state(session)

    case state.variables[name] do
      nil -> nil
      var -> Bash.Variable.get(var, nil)
    end
  end

  @doc """
  Setup helper that creates an isolated Bash session for a test.

  The session is automatically cleaned up after the test completes.

  Adds `session` to the test context.

  ## Options from context

  - `:working_dir` - If set to `:tmp_dir`, uses the tmp_dir as working directory
  - `:tmp_dir` - Automatically provided by `@describetag :tmp_dir`

  ## Examples

      setup :start_session

      test "with custom working dir", %{session: session, tmp_dir: tmp_dir} do
        # Session is in tmp_dir
      end
  """
  def start_session(context) do
    opts =
      if context[:working_dir] == :tmp_dir do
        [working_dir: context.tmp_dir]
      else
        []
      end

    # Create unique registry and supervisor names for this test
    # This ensures complete isolation between concurrent tests
    registry_name = Module.concat([context.module, SessionRegistry, context.test])
    supervisor_name = Module.concat([context.module, SessionSupervisor, context.test])

    # Start registry for session name registration
    _registry = start_supervised!({Registry, keys: :unique, name: registry_name})

    # Start supervisor for managing the session process
    _supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    # Create session with isolated registry and supervisor
    {:ok, session} =
      Session.new(
        [
          id: "#{context.describe}_#{context.test}",
          registry: registry_name,
          supervisor: supervisor_name
        ] ++ opts
      )

    {:ok, %{session: session}}
  end
end
