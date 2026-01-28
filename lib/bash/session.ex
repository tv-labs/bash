defmodule Bash.Session do
  @bash_version "5.3"

  @moduledoc """
  Session GenServer for maintaining Bash execution context.

  Each session maintains its own environment variables, working directory,
  and I/O context for executing Bash commands.

  | Variable          | Description |
  |:------------------|:------------|
  | `BASH_VERSION`    | #{inspect(@bash_version)} Version information for this Bash. |
  | `CDPATH`          | A colon-separated list of directories to search for directories given as arguments to `cd`. |
  | `GLOBIGNORE`      | A colon-separated list of patterns describing filenames to be ignored by pathname expansion. |
  | `HISTFILE`        | The name of the file where your command history is stored. |
  | `HISTFILESIZE`    | The maximum number of lines this file can contain. |
  | `HISTSIZE`        | The maximum number of history lines that a running shell can access. |
  | `HOME`            | The complete pathname to your login directory. |
  | `HOSTNAME`        | The name of the current host. |
  | `HOSTTYPE`        | The type of CPU this version of Bash is running under. |
  | `IGNOREEOF`       | Controls the action of the shell on receipt of an EOF character as the sole input.  If set, then the value of it is the number of EOF characters that can be seen in a row on an empty line before the shell will exit (default 10).  When unset, EOF signifies the end of input. |
  | `MACHTYPE`        | A string describing the current system Bash is running on. |
  | `MAILCHECK`       | How often, in seconds, Bash checks for new mail. |
  | `MAILPATH`        | (Unsupported) A colon-separated list of filenames which Bash checks for new mail. |
  | `OSTYPE`          | The version of Unix this version of Bash is running on. |
  | `PATH`            | A colon-separated list of directories to search when looking for commands. |
  | `PROMPT_COMMAND`  | (Unsupported) A command to be executed before the printing of each primary prompt. |
  | `PS1`             | (Unsupported) The primary prompt string. |
  | `PS2`             | (Unsupported) The secondary prompt string. |
  | `PWD`             | The full pathname of the current directory. |
  | `SHELLOPTS`       | A colon-separated list of enabled shell options. |
  | `TERM`            | (Always set to "dumb") The name of the current terminal type. |
  | `TIMEFORMAT`      | The output format for timing statistics displayed by the `time` reserved word. |
  | `auto_resume`     | (Unsupported) Non-null means a command word appearing on a line by itself is first looked for in the list of currently stopped jobs.  If found there, that job is foregrounded. A value of `exact` means that the command word must exactly match a command in the list of stopped jobs.  A value of `substring` means that the command word must match a substring of the job.  Any other value means that the command must be a prefix of a stopped job. |
  | `histchars`       | (Unsupported) Characters controlling history expansion and quick substitution.  The first character is the history substitution character, usually `!`.  The second is the `quick substitution` character, usually `^`.  The third is the `history comment` character, usually `#`. |
  | `HISTIGNORE`      | A colon-separated list of patterns used to decide which commands should be saved on the history
  list. |
  """

  use GenServer

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  alias Bash.AST
  alias Bash.AST.Compound
  alias Bash.AST.Pipeline
  alias Bash.Executor
  alias Bash.CommandResult
  alias Bash.Script
  alias Bash.Job
  alias Bash.JobProcess
  alias Bash.OutputCollector
  alias Bash.SessionRegistry
  alias Bash.SessionSupervisor
  alias Bash.Sink
  alias Bash.Variable
  alias Bash.Function
  alias Bash.Execution

  defstruct [
    :id,
    :working_dir,
    :stdin,
    :stdout,
    :stderr,
    :job_supervisor,
    # Output collector GenServer (linked to session)
    :output_collector,
    # Sink functions for streaming output (user-provided final destinations)
    :stdout_sink,
    :stderr_sink,
    # Per-execution streams (for inspection)
    executions: [],
    # Current execution being written to
    current: nil,
    # Whether current command is pipeline tail (should forward to user sinks)
    is_pipeline_tail: true,
    variables: %{},
    hash: %{},
    options: %{},
    aliases: %{},
    functions: %{},
    elixir_modules: %{},
    jobs: %{},
    next_job_number: 1,
    current_job: nil,
    previous_job: nil,
    completed_jobs: [],
    command_history: [],
    in_function: false,
    in_loop: false,
    # Directory stack for pushd/popd/dirs
    dir_stack: [],
    # Traps for signals (EXIT, ERR, DEBUG, RETURN, INT, etc.)
    traps: %{},
    # File descriptors for read -u / mapfile -u (fd number => content string)
    # fd 0 is always stdin (passed as parameter), 1/2 are stdout/stderr (not readable)
    file_descriptors: %{},
    # StringIO device for streaming stdin (used by while loops with redirects)
    # When set, read builtin uses IO.read(device, :line) for line-by-line reading
    stdin_device: nil,
    # Special variables (updated after each command)
    special_vars: %{
      "?" => 0,
      "$" => nil,
      "!" => nil,
      "0" => "bash",
      "_" => ""
    },
    # Positional parameters (scope stack for functions)
    positional_params: [[]],
    # Callback for starting background jobs synchronously (used by Script executor)
    start_background_job_fn: nil,
    signal_jobs_fn: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          variables: %{String.t() => Variable.t()},
          working_dir: String.t(),
          stdin: pid() | nil,
          stdout: pid() | nil,
          stderr: pid() | nil,
          job_supervisor: pid() | nil,
          output_collector: pid() | nil,
          stdout_sink: Sink.t() | nil,
          stderr_sink: Sink.t() | nil,
          executions: [Execution.t()],
          current: Execution.t() | nil,
          is_pipeline_tail: boolean(),
          options: %{String.t() => boolean()},
          hash: %{String.t() => {pos_integer, String.t()}},
          aliases: %{String.t() => String.t()},
          functions: %{String.t() => Function.t()},
          elixir_modules: %{String.t() => module()},
          in_function: boolean(),
          in_loop: boolean(),
          dir_stack: [String.t()],
          traps: %{String.t() => String.t() | :ignore},
          file_descriptors: %{non_neg_integer() => String.t()},
          stdin_device: pid() | nil,
          jobs: %{pos_integer() => pid()},
          next_job_number: pos_integer(),
          current_job: pos_integer() | nil,
          previous_job: pos_integer() | nil,
          completed_jobs: [Job.t()],
          command_history: [CommandResult.t()],
          special_vars: %{String.t() => integer() | String.t() | nil},
          positional_params: [[String.t()]]
        }

  # Client API

  @doc """
  Creates a new session with default environment.
  """
  def new(opts \\ []) do
    id = opts[:id] || generate_session_id()
    supervisor = opts[:supervisor] || SessionSupervisor

    # Ensure id is set only once by putting it at the front and removing any duplicate
    child_opts = Keyword.put(Keyword.delete(opts, :id), :id, id)

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
      {:ok, pid} ->
        Process.register(pid, String.to_atom("session_#{id}"))
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Creates a child session that inherits state from a parent.

  The child session inherits (per bash behavior):
  - Environment variables
  - Working directory
  - Functions
  - Shell options

  The child session does NOT inherit (per bash behavior):
  - Aliases
  - Hash table (command path cache)

  The child session gets its own:
  - Job supervisor and job table
  - Session ID

  This is used for subshell execution where changes to env/cwd
  should not propagate back to the parent.
  """
  @spec new_child(t() | pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def new_child(parent, opts \\ [])

  def new_child(%__MODULE__{} = parent_state, opts) do
    id = opts[:id] || generate_session_id()
    supervisor = opts[:supervisor] || SessionSupervisor

    child_opts = [
      id: id,
      # Inherit from parent (bash behavior)
      working_dir: parent_state.working_dir,
      variables: parent_state.variables,
      functions: parent_state.functions,
      options: parent_state.options,
      # NOT inherited in subshells (bash behavior):
      # - aliases are NOT inherited
      # - hash table is NOT inherited
      # Mark as child session (for potential future use)
      parent_id: parent_state.id
    ]

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
      {:ok, pid} ->
        {:ok, pid}

      error ->
        error
    end
  end

  def new_child(parent_pid, opts) when is_pid(parent_pid) do
    parent_state = get_state(parent_pid)
    new_child(parent_state, opts)
  end

  @doc """
  Stops a session and its job supervisor.
  """
  @spec stop(pid()) :: :ok
  def stop(session) do
    GenServer.stop(session, :normal)
  end

  @doc """
  Lists all running sessions.

  Returns a list of tuples containing the session ID and pid.

  ## Options

    * `:registry` - The registry to query (default: `Bash.SessionRegistry`)

  ## Examples

      iex> {:ok, session} = Bash.Session.new()
      iex> sessions = Bash.Session.list()
      iex> Enum.any?(sessions, fn {_id, pid} -> pid == session end)
      true

  """
  @spec list(keyword()) :: [{String.t(), pid()}]
  def list(opts \\ []) do
    registry = opts[:registry] || SessionRegistry

    Registry.select(registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Gets the current working directory for the session.
  """
  def get_cwd(session) do
    GenServer.call(session, :get_cwd)
  end

  @doc """
  Changes the working directory for the session.
  """
  def chdir(session, path) do
    GenServer.call(session, {:chdir, path})
  end

  @doc """
  Gets an environment variable from the session.
  """
  def get_env(session, key) do
    GenServer.call(session, {:get_env, key})
  end

  @doc """
  Gets a variable value from the session, with optional index/key for arrays.

  Retrieves the session state and delegates to Variable.get/2 or Variable.get/3.

  ## Examples

      Session.get_var(session, "myvar")
      Session.get_var(session, "myarray", 0)
      Session.get_var(session, "myassoc", "key")

  """
  def get_var(session, var_name) do
    state = get_state(session)
    Variable.get(state, var_name)
  end

  def get_var(session, var_name, index_or_key) do
    state = get_state(session)
    Variable.get(state, var_name, index_or_key)
  end

  @doc """
  Sets an environment variable in the session.
  """
  def set_env(session, key, value) do
    GenServer.call(session, {:set_env, key, value})
  end

  @doc """
  Gets all environment variables from the session.
  """
  def get_all_env(session) do
    GenServer.call(session, :get_all_env)
  end

  @doc """
  Executes a command AST within this session synchronously.

  Blocks until the command completes and returns the result.

  ## Options

    * `:on_output` - Callback function for streaming output. When provided,
      output is streamed to the callback as it arrives instead of being
      accumulated in the result. The callback receives `{:stdout, binary}`
      or `{:stderr, binary}` tuples.

  ## Examples

      # Standard execution (accumulates output)
      {:ok, session} = Session.new()
      {:ok, result} = Session.execute(session, ast)

      # Streaming execution (output flows to callback)
      {:ok, session} = Session.new()
      {:ok, result} = Session.execute(session, ast, on_output: fn
        {:stdout, data} -> IO.write(data)
        {:stderr, data} -> IO.write(:stderr, data)
      end)

  """
  def execute(session, ast, opts \\ []) do
    GenServer.call(session, {:execute, ast, opts})
  end

  @doc """
  Executes a command AST within this session asynchronously.

  Returns immediately without waiting for the command to complete.
  The result will be stored in the session's command history.

  ## Examples

      {:ok, session} = Session.new()
      :ok = Session.execute_async(session, ast)
      # Command executes in background

  """
  def execute_async(session, ast) do
    GenServer.cast(session, {:execute_async, ast})
  end

  @doc """
  Start a background job and return its job number and OS PID.

  ## Options

  - `:command` - Command name to execute (required)
  - `:args` - List of arguments (default: [])
  """
  @spec start_background_job(pid(), keyword()) ::
          {:ok, job_number :: pos_integer(), os_pid :: pos_integer() | nil} | {:error, term()}
  def start_background_job(session, opts) do
    GenServer.call(session, {:start_background_job, opts})
  end

  @doc """
  Get all jobs for this session.
  """
  @spec list_jobs(pid()) :: [Job.t()]
  def list_jobs(session) do
    GenServer.call(session, :list_jobs)
  end

  @doc """
  Get a specific job by number.
  """
  @spec get_job(pid(), pos_integer()) :: {:ok, Job.t()} | {:error, :not_found}
  def get_job(session, job_number) do
    GenServer.call(session, {:get_job, job_number})
  end

  @doc """
  Bring job to foreground.

  Blocks until the job completes and returns a CommandResult.
  """
  @spec foreground_job(pid(), pos_integer() | nil) :: {:ok, CommandResult.t()} | {:error, term()}
  def foreground_job(session, job_spec \\ nil) do
    GenServer.call(session, {:foreground_job, job_spec}, :infinity)
  end

  @doc """
  Send job to background (resume if stopped).
  """
  @spec background_job(pid(), pos_integer() | nil) :: :ok | {:error, term()}
  def background_job(session, job_spec \\ nil) do
    GenServer.call(session, {:background_job, job_spec})
  end

  @doc """
  Wait for job(s) to complete.
  """
  @spec wait_for_jobs(pid(), [pos_integer()] | nil) :: {:ok, [integer()]} | {:error, term()}
  def wait_for_jobs(session, job_specs \\ nil) do
    GenServer.call(session, {:wait_for_jobs, job_specs}, :infinity)
  end

  @doc """
  Send signal to job.
  """
  @spec signal_job(pid(), pos_integer(), atom() | integer()) :: :ok | {:error, term()}
  def signal_job(session, job_spec, signal) do
    GenServer.call(session, {:signal_job, job_spec, signal})
  end

  @doc """
  Get and clear completed jobs for notification display.
  """
  @spec pop_completed_jobs(pid()) :: [Job.t()]
  def pop_completed_jobs(session) do
    GenServer.call(session, :pop_completed_jobs)
  end

  @doc """
  Get the session state (for builtins that need direct access).
  """
  @spec get_state(pid()) :: t()
  def get_state(session) do
    GenServer.call(session, :get_state)
  end

  @doc """
  Load an Elixir API module into a session.

  The module must `use Bash.Interop` and define a namespace.
  Once loaded, functions defined with `defbash` become callable from
  bash scripts as `namespace.function_name`.

  ## Examples

      # Load into a running session (recommended)
      {:ok, session} = Session.new()
      :ok = Session.load_api(session, MyApp.BashAPI)

      # Or load at session creation
      {:ok, session} = Session.new(apis: [MyApp.BashAPI])

      # Now myapp.* functions are available in bash scripts

  """
  @spec load_api(pid(), module()) :: :ok
  def load_api(session, module) when is_pid(session) and is_atom(module) do
    GenServer.call(session, {:load_api, module})
  end

  # Internal: load API into state struct (used by GenServer and init)
  @doc false
  @spec do_load_api(t(), module()) :: t()
  def do_load_api(%__MODULE__{} = state, module) when is_atom(module) do
    unless function_exported?(module, :__bash_namespace__, 0) do
      raise ArgumentError,
            "#{inspect(module)} does not use Bash.Interop"
    end

    namespace = module.__bash_namespace__()
    elixir_modules = Map.put(state.elixir_modules, namespace, module)
    %{state | elixir_modules: elixir_modules}
  end

  @doc """
  List loaded API namespaces.
  """
  @spec list_apis(pid() | t()) :: [String.t()]
  def list_apis(session) when is_pid(session) do
    state = get_state(session)
    Map.keys(state.elixir_modules)
  end

  def list_apis(%__MODULE__{} = state) do
    Map.keys(state.elixir_modules)
  end

  @doc """
  Read from an input source.

  ## Sources
    * `:stdin` - Read from session's stdin
    * `{:fd, n}` - Read from file descriptor n

  ## Modes
    * `:line` - Read a single line (default)
    * `:all` - Read all available content
    * `n` when is_integer(n) - Read n bytes

  ## Examples

      {:ok, line} = Session.read(session, :stdin, :line)
      {:ok, all} = Session.read(session, :stdin, :all)
      {:ok, chunk} = Session.read(session, {:fd, 3}, 1024)

  """
  @spec read(t(), :stdin | {:fd, non_neg_integer()}, :line | :all | non_neg_integer()) ::
          {:ok, String.t()} | :eof | {:error, term()}
  def read(session, source \\ :stdin, mode \\ :line)

  def read(%__MODULE__{stdin: stdin}, :stdin, mode) when is_pid(stdin) do
    do_read(stdin, mode)
  end

  def read(%__MODULE__{stdin: nil}, :stdin, _mode) do
    :eof
  end

  def read(%__MODULE__{} = session, {:fd, 0}, mode) do
    read(session, :stdin, mode)
  end

  def read(%__MODULE__{}, {:fd, fd}, _mode) when fd in [1, 2] do
    {:error, "#{fd}: Bad file descriptor"}
  end

  def read(%__MODULE__{file_descriptors: fds}, {:fd, fd}, mode) do
    case Map.get(fds, fd) do
      nil ->
        {:error, "#{fd}: Bad file descriptor"}

      device when is_pid(device) ->
        do_read(device, mode)

      content when is_binary(content) ->
        # Legacy string content - wrap in StringIO for reading
        {:ok, string_io} = StringIO.open(content)
        result = do_read(string_io, mode)
        StringIO.close(string_io)
        result
    end
  end

  defp do_read(device, :line) do
    case IO.read(device, :line) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      data -> {:ok, data}
    end
  end

  defp do_read(device, :all) do
    case IO.read(device, :eof) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      data -> {:ok, data}
    end
  end

  defp do_read(device, n) when is_integer(n) and n > 0 do
    case IO.read(device, n) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      data -> {:ok, data}
    end
  end

  @doc """
  Write to an output destination.

  Writes to the current execution's StringIO stream. If the session is
  at the pipeline tail and has user-provided sinks, also forwards to those.

  ## Destinations
    * `:stdout` - Write to stdout
    * `:stderr` - Write to stderr
    * `{:fd, n}` - Write to file descriptor n

  ## Examples

      session = Session.write(session, :stdout, "hello\\n")
      session = Session.write(session, :stderr, "error message\\n")
      session = Session.write(session, {:fd, 3}, data)

  """
  @spec write(t(), :stdout | :stderr | {:fd, non_neg_integer()}, iodata()) :: t()
  def write(%__MODULE__{current: nil} = session, _dest, _data) do
    session
  end

  def write(%__MODULE__{current: exec} = session, :stdout, data) do
    IO.write(exec.stdout, data)

    # Forward to user sink if pipeline tail
    if session.is_pipeline_tail && session.stdout_sink do
      session.stdout_sink.({:stdout, data})
    end

    session
  end

  def write(%__MODULE__{current: exec} = session, :stderr, data) do
    IO.write(exec.stderr, data)

    # Forward to user sink if pipeline tail
    if session.is_pipeline_tail && session.stderr_sink do
      session.stderr_sink.({:stderr, data})
    end

    session
  end

  def write(%__MODULE__{} = session, {:fd, 1}, data), do: write(session, :stdout, data)
  def write(%__MODULE__{} = session, {:fd, 2}, data), do: write(session, :stderr, data)

  def write(%__MODULE__{file_descriptors: fds} = session, {:fd, fd}, data) do
    case Map.get(fds, fd) do
      # Bad fd - silently ignore like bash
      nil ->
        session

      device when is_pid(device) ->
        IO.write(device, data)
        session
    end
  end

  @doc ~S"""
  Read a line from stdin (convenience wrapper for read/3).

  ## Options
    * `:source` - Source to read from (default: :stdin)
    * `:delimiter` - Line delimiter (default: "\n")

  ## Examples

      {:ok, line} = Session.gets(session)
      {:ok, line} = Session.gets(session, source: {:fd, 3})

  """
  @spec gets(t(), keyword()) :: {:ok, String.t()} | :eof | {:error, term()}
  def gets(%__MODULE__{} = session, opts \\ []) do
    source = Keyword.get(opts, :source, :stdin)
    read(session, source, :line)
  end

  @doc ~S"""
  Write a line to stdout (convenience wrapper for write/3).

  Appends a newline to the data.

  ## Examples

      session = Session.puts(session, "hello")  # writes "hello\n"

  """
  @spec puts(t(), iodata()) :: t()
  def puts(%__MODULE__{} = session, data) do
    write(session, :stdout, [data, "\n"])
  end

  @doc """
  Begin a new command execution with fresh StringIO streams.

  Creates a new Execution struct with separate stdout/stderr streams
  and sets it as the current execution.

  ## Options
    * `:pipeline_tail` - Whether this command is at the end of a pipeline
      (default: true). Only pipeline tail commands forward to user sinks.

  ## Examples

      session = Session.begin_execution(session, "echo hello")
      session = Session.begin_execution(session, "cat", pipeline_tail: false)

  """
  @spec begin_execution(t(), String.t(), keyword()) :: t()
  def begin_execution(%__MODULE__{} = session, command, opts \\ []) do
    pipeline_tail = Keyword.get(opts, :pipeline_tail, true)

    case Execution.new(command) do
      {:ok, exec} ->
        %{session | current: exec, is_pipeline_tail: pipeline_tail}

      {:error, _reason} ->
        session
    end
  end

  @doc """
  End the current execution and move it to completed executions.

  Marks the execution with the given exit code and timestamp,
  then appends it to the executions list.

  ## Options
    * `:exit_code` - The exit code for the execution (default: 0)

  ## Examples

      session = Session.end_execution(session, exit_code: 0)
      session = Session.end_execution(session, exit_code: 1)

  """
  @spec end_execution(t(), keyword()) :: t()
  def end_execution(%__MODULE__{current: nil} = session, _opts) do
    session
  end

  def end_execution(%__MODULE__{current: exec, executions: executions} = session, opts) do
    exit_code = Keyword.get(opts, :exit_code, 0)
    completed_exec = Execution.complete(exec, exit_code)

    %{session | current: nil, executions: executions ++ [completed_exec]}
  end

  @doc """
  Wire the previous execution's stdout to the current stdin for pipeline stages.

  Takes the stdout content from the last completed execution and creates
  a new StringIO device for reading as the next command's stdin.

  ## Examples

      # After cmd1 completes:
      session = Session.pipe_forward(session)
      # Now stdin reads from cmd1's stdout

  """
  @spec pipe_forward(t()) :: t()
  def pipe_forward(%__MODULE__{executions: []} = session) do
    # No previous execution to pipe from
    session
  end

  def pipe_forward(%__MODULE__{executions: executions} = session) do
    prev_exec = List.last(executions)
    output = Execution.stdout_contents(prev_exec)

    {:ok, new_stdin} = StringIO.open(output)

    %{session | stdin: new_stdin}
  end

  @doc """
  Open a StringIO device for stdin from a string.

  Useful for providing initial input to a session or pipeline.

  ## Examples

      session = Session.open_stdin(session, "line1\\nline2\\n")

  """
  @spec open_stdin(t(), String.t()) :: t()
  def open_stdin(%__MODULE__{} = session, content) when is_binary(content) do
    {:ok, stdin} = StringIO.open(content)
    %{session | stdin: stdin}
  end

  @doc """
  Get the merged stdout content from all completed executions.

  ## Options
    * `:index` - Get stdout from a specific execution by index

  ## Examples

      # All stdout as a stream
      Session.stdout(session) |> Enum.to_list()

      # Specific execution's stdout
      Session.stdout(session, index: 0)

  """
  @spec stdout(t(), keyword()) :: Enumerable.t() | String.t()
  def stdout(%__MODULE__{executions: executions}, opts \\ []) do
    case Keyword.get(opts, :index) do
      nil ->
        # Stream all executions' stdout
        Stream.map(executions, &Execution.stdout_contents/1)

      index when is_integer(index) ->
        case Enum.at(executions, index) do
          nil -> ""
          exec -> Execution.stdout_contents(exec)
        end
    end
  end

  @doc """
  Get the merged stderr content from all completed executions.

  ## Options
    * `:index` - Get stderr from a specific execution by index

  ## Examples

      # All stderr as a stream
      Session.stderr(session) |> Enum.to_list()

      # Specific execution's stderr
      Session.stderr(session, index: 0)

  """
  @spec stderr(t(), keyword()) :: Enumerable.t() | String.t()
  def stderr(%__MODULE__{executions: executions}, opts \\ []) do
    case Keyword.get(opts, :index) do
      nil ->
        Stream.map(executions, &Execution.stderr_contents/1)

      index when is_integer(index) ->
        case Enum.at(executions, index) do
          nil -> ""
          exec -> Execution.stderr_contents(exec)
        end
    end
  end

  @doc """
  Get a specific execution by index.

  ## Examples

      exec = Session.execution(session, 0)
      Execution.stdout_contents(exec)

  """
  @spec execution(t(), non_neg_integer()) :: Execution.t() | nil
  def execution(%__MODULE__{executions: executions}, index) do
    Enum.at(executions, index)
  end

  @doc """
  Open a file descriptor for reading or writing.

  ## Examples

      session = Session.open_fd(session, 3, "/path/to/file", [:read])
      session = Session.open_fd(session, 4, "/path/to/output", [:write])

  """
  @spec open_fd(t(), non_neg_integer(), String.t(), [atom()]) :: {:ok, t()} | {:error, term()}
  def open_fd(%__MODULE__{} = session, fd, path, modes) when fd >= 3 do
    case File.open(path, modes) do
      {:ok, device} ->
        new_fds = Map.put(session.file_descriptors, fd, device)
        {:ok, %{session | file_descriptors: new_fds}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def open_fd(%__MODULE__{}, fd, _path, _modes) when fd in [0, 1, 2] do
    {:error, "Cannot override standard file descriptors"}
  end

  @doc """
  Close a file descriptor.

  ## Examples

      session = Session.close_fd(session, 3)

  """
  @spec close_fd(t(), non_neg_integer()) :: t()
  def close_fd(%__MODULE__{file_descriptors: fds} = session, fd) do
    case Map.get(fds, fd) do
      nil ->
        session

      device when is_pid(device) ->
        File.close(device)
        %{session | file_descriptors: Map.delete(fds, fd)}

      _content ->
        # Legacy string content
        %{session | file_descriptors: Map.delete(fds, fd)}
    end
  end

  @doc """
  Get the command history for this session.
  """
  @spec get_command_history(pid()) :: [CommandResult.t()]
  def get_command_history(session) do
    GenServer.call(session, :get_command_history)
  end

  @doc """
  Get accumulated output from the session's output collector.

  Returns `{stdout, stderr}` tuple with all output captured during execution.
  This is the primary way to retrieve output in tests.

  ## Examples

      {:ok, session} = Session.new()
      {:ok, _, _} = Bash.run(~b"echo hello", session)
      {stdout, stderr} = Session.get_output(session)
      assert stdout =~ "hello"
  """
  @spec get_output(pid()) :: {String.t(), String.t()}
  def get_output(session) do
    GenServer.call(session, :get_output)
  end

  @doc """
  Clear the accumulated output and return what was collected.

  Useful for tests that want to run multiple commands and check output after each.
  """
  @spec flush_output(pid()) :: {String.t(), String.t()}
  def flush_output(session) do
    GenServer.call(session, :flush_output)
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    registry = opts[:registry] || SessionRegistry
    GenServer.start_link(__MODULE__, opts, name: via(registry, id))
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    working_dir = opts[:working_dir] || System.get_env("PWD") || "/"

    # Use inherited variables if provided (for child sessions), otherwise use Bash defaults
    base_variables =
      case opts[:variables] do
        nil -> get_bash_default_variables(working_dir)
        vars -> vars
      end

    variables =
      case opts[:env] do
        nil ->
          base_variables

        env when is_map(env) ->
          env_vars = Map.new(env, fn {k, v} -> {k, Variable.new(v)} end)
          Map.merge(base_variables, env_vars)
      end

    aliases = opts[:aliases] || %{}
    functions = opts[:functions] || %{}
    default_options = %{hashall: true, braceexpand: true}
    options = Map.merge(default_options, opts[:options] || %{})

    {:ok, job_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    special_vars = %{
      "?" => 0,
      "$" => System.pid() |> String.to_integer(),
      "!" => nil,
      "0" => opts[:script_name] || "bash",
      "_" => ""
    }

    positional_params = [opts[:args] || []]
    {:ok, output_collector} = OutputCollector.start_link()

    state = %__MODULE__{
      id: id,
      variables: variables,
      working_dir: working_dir,
      stdin: nil,
      stdout: nil,
      stderr: nil,
      job_supervisor: job_supervisor,
      output_collector: output_collector,
      aliases: aliases,
      functions: functions,
      options: options,
      hash: %{},
      jobs: %{},
      next_job_number: 1,
      current_job: nil,
      previous_job: nil,
      completed_jobs: [],
      command_history: [],
      special_vars: special_vars,
      positional_params: positional_params
    }

    # Load any API modules provided at creation
    state =
      case opts[:apis] do
        nil -> state
        apis when is_list(apis) -> Enum.reduce(apis, state, &do_load_api(&2, &1))
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_cwd, _from, state) do
    {:reply, state.working_dir, state}
  end

  def handle_call({:chdir, path}, _from, state) do
    if File.dir?(path) do
      new_state = %{state | working_dir: Path.expand(path)}
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :enoent}, state}
    end
  end

  def handle_call({:get_env, key}, _from, state) do
    value =
      case Map.get(state.variables, key) do
        nil -> nil
        %Variable{} = var -> Variable.get(var, nil)
      end

    {:reply, value, state}
  end

  def handle_call({:set_env, key, value}, _from, state) do
    case Map.get(state.variables, key) do
      %Variable{attributes: %{readonly: true}} ->
        {:reply, {:error, :readonly}, state}

      existing ->
        var = existing || Variable.new()
        new_var = Variable.set(var, value, nil)
        new_variables = Map.put(state.variables, key, new_var)
        new_state = %{state | variables: new_variables}
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:get_all_env, _from, state) do
    # Return as plain map for compatibility
    env_map =
      Map.new(state.variables, fn {k, v} ->
        {k, Variable.get(v, nil)}
      end)

    {:reply, env_map, state}
  end

  # Backwards compatibility: handle execute without opts
  def handle_call({:execute, ast}, from, state) do
    handle_call({:execute, ast, []}, from, state)
  end

  def handle_call({:execute, ast, opts}, from, state) do
    # Spawn a linked OutputCollector for this execution
    {:ok, collector} = OutputCollector.start_link()
    Process.link(collector)

    # Create sinks from opts or use collector-backed sinks
    stdout_sink =
      case Keyword.get(opts, :stdout_into) do
        nil -> Sink.collector(collector)
        collectable -> Sink.stream(collectable, stream_type: :stdout)
      end

    stderr_sink =
      case Keyword.get(opts, :stderr_into) do
        nil -> Sink.collector(collector)
        collectable -> Sink.stream(collectable, stream_type: :stderr)
      end

    # Also support on_output callback by wrapping both sinks
    {stdout_sink, stderr_sink} =
      case Keyword.get(opts, :on_output) do
        nil ->
          {stdout_sink, stderr_sink}

        callback when is_function(callback, 1) ->
          # Create sinks that write to both collector and callback
          wrapped_stdout = fn chunk ->
            stdout_sink.(chunk)
            callback.(chunk)
            :ok
          end

          wrapped_stderr = fn chunk ->
            stderr_sink.(chunk)
            callback.(chunk)
            :ok
          end

          {wrapped_stdout, wrapped_stderr}
      end

    # Create a callback function for starting background jobs synchronously
    # This allows Scripts to start jobs immediately and get the OS PID for $!
    start_bg_job_fn = fn foreground_ast, current_state ->
      start_background_job_sync(foreground_ast, current_state, state)
    end

    # Create a callback function for sending signals to jobs/processes synchronously
    # This allows Scripts to send signals immediately (kill builtin)
    signal_jobs_fn = fn signal, targets, current_state ->
      send_signals_sync(signal, targets, current_state, state)
    end

    state_with_sinks = %{
      state
      | output_collector: collector,
        stdout_sink: stdout_sink,
        stderr_sink: stderr_sink,
        start_background_job_fn: start_bg_job_fn,
        signal_jobs_fn: signal_jobs_fn
    }

    # No executor_opts needed - sinks are on state now
    case execute_command_in_session(ast, state_with_sinks, []) do
      {:background, foreground_ast, _session_state} ->
        # Command should be run in the background
        # Create sinks backed by the session's PERSISTENT output_collector for the job
        # The temporary sinks are used for the job notification [1], then transferred
        persistent_stdout_sink = Sink.collector(state.output_collector)
        persistent_stderr_sink = Sink.collector(state.output_collector)

        bg_state = %{
          state
          | stdout_sink: persistent_stdout_sink,
            stderr_sink: persistent_stderr_sink
        }

        # Use temp sinks for job notification output (the [1] message)
        if state_with_sinks.stdout_sink do
          state_with_sinks.stdout_sink.({:stdout, ""})
        end

        {:reply, reply_value, new_state} = do_start_background_job(foreground_ast, bg_state)
        # Transfer job notification output to session's persistent collector
        transfer_and_cleanup_collector(collector, state.output_collector)
        {:reply, reply_value, new_state}

      {:background, executed_script, state_updates,
       {:background, foreground_ast, _bg_session_state}} ->
        # Background command from within a Script - apply state updates and start the job
        # Create sinks backed by the session's PERSISTENT output_collector for the job
        persistent_stdout_sink = Sink.collector(state.output_collector)
        persistent_stderr_sink = Sink.collector(state.output_collector)

        bg_state = apply_state_updates(state, state_updates)

        bg_state = %{
          bg_state
          | stdout_sink: persistent_stdout_sink,
            stderr_sink: persistent_stderr_sink
        }

        {:reply, _bg_result, new_state} = do_start_background_job(foreground_ast, bg_state)

        # Transfer output (including job notification [1]) to session's persistent collector
        # so it can be read after the command completes
        transfer_and_cleanup_collector(collector, state.output_collector)

        # Update executed_script to use session's persistent collector since temp was cleaned up
        executed_script_with_collector = %{executed_script | collector: state.output_collector}

        final_state =
          new_state
          |> append_to_history(executed_script_with_collector)
          |> update_exit_status(executed_script_with_collector)

        {:reply, {:ok, executed_script_with_collector}, final_state}

      # Handle special job control builtin return values from Script execution
      # These include the executed_script so we can return it with proper collector
      {:foreground_job, job_number, executed_script, script_updates} ->
        # Keep collector alive for Script result
        handle_foreground_job_with_script(
          job_number,
          executed_script,
          script_updates,
          collector,
          from,
          state
        )

      {:background_job, job_numbers, executed_script, script_updates} ->
        # Keep collector alive for Script result
        handle_background_jobs_with_script(
          job_numbers,
          executed_script,
          script_updates,
          collector,
          state
        )

      {:wait_for_jobs, job_specs, executed_script, script_updates} ->
        # Transfer collected output to persistent collector
        transfer_and_cleanup_collector(collector, state.output_collector)
        # Update script to use persistent collector
        executed_script_with_collector = %{executed_script | collector: state.output_collector}

        handle_wait_for_jobs_with_script(
          job_specs,
          executed_script_with_collector,
          script_updates,
          from,
          state
        )

      {:signal_jobs, signal, targets, executed_script, script_updates} ->
        # Keep collector alive for Script result, perform signal operation
        handle_signal_jobs_with_script(
          signal,
          targets,
          executed_script,
          script_updates,
          collector,
          state
        )

      # Legacy job control returns (without script) - for non-Script callers
      {:foreground_job, job_number} ->
        cleanup_collector(collector)
        handle_foreground_job(job_number, from, state)

      {:background_job, job_numbers} ->
        cleanup_collector(collector)
        handle_background_jobs(job_numbers, state)

      {:wait_for_jobs, job_specs} ->
        # Transfer collected output to persistent collector before cleaning up
        transfer_and_cleanup_collector(collector, state.output_collector)
        handle_wait_for_jobs(job_specs, from, state)

      {:signal_jobs, signal, targets} ->
        cleanup_collector(collector)
        handle_signal_jobs(signal, targets, state)

      {:ok, result, state_updates} ->
        # Command succeeded with state updates (e.g., cd, ForLoop, history)
        # Transfer output to session's persistent collector for session_stdout access
        transfer_to_persistent_collector(collector, state.output_collector, result)

        # Note: append to history first, then apply updates
        # This allows history -c to clear including itself
        new_state =
          state
          |> append_to_history(result)
          |> apply_state_updates(state_updates)
          |> update_exit_status(result)

        # Check errexit - exit if enabled and command had non-zero exit
        # Check onecmd (-t) - exit after reading and executing one command
        # Pass state_updates to avoid triggering on the command that sets onecmd
        cond do
          should_errexit?(result, new_state) ->
            {:reply, {:exit, result}, new_state}

          should_onecmd_exit?(new_state, state_updates) ->
            {:reply, {:exit, result}, new_state}

          true ->
            {:reply, {:ok, result}, new_state}
        end

      {:ok, result} ->
        # Normal result without state updates
        # Transfer output to session's persistent collector for session_stdout access
        transfer_to_persistent_collector(collector, state.output_collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> update_exit_status(result)

        # Check errexit
        # Check onecmd (-t) - exit after reading and executing one command
        cond do
          should_errexit?(result, new_state) ->
            {:reply, {:exit, result}, new_state}

          should_onecmd_exit?(new_state) ->
            {:reply, {:exit, result}, new_state}

          true ->
            {:reply, {:ok, result}, new_state}
        end

      {:error, result, state_updates} ->
        # Error result with state updates
        # For Script results, keep collector alive for output reading
        handle_collector_for_result(collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> apply_state_updates(state_updates)
          |> update_exit_status(result)

        # Check errexit
        # Check onecmd (-t) - exit after reading and executing one command
        # Pass state_updates to avoid triggering on the command that sets onecmd
        cond do
          should_errexit?(result, new_state) ->
            {:reply, {:exit, result}, new_state}

          should_onecmd_exit?(new_state, state_updates) ->
            {:reply, {:exit, result}, new_state}

          true ->
            {:reply, {:error, result}, new_state}
        end

      {:error, result} ->
        # Error result without state updates
        # For Script results, keep collector alive for output reading
        handle_collector_for_result(collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> update_exit_status(result)

        # Check errexit
        # Check onecmd (-t) - exit after reading and executing one command
        cond do
          should_errexit?(result, new_state) ->
            {:reply, {:exit, result}, new_state}

          should_onecmd_exit?(new_state) ->
            {:reply, {:exit, result}, new_state}

          true ->
            {:reply, {:error, result}, new_state}
        end

      {:exit, result, state_updates} ->
        # Script exit with state updates
        # For Script results, keep collector alive for output reading
        handle_collector_for_result(collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> apply_state_updates(state_updates)
          |> update_exit_status(result)

        {:reply, {:exit, result}, new_state}

      {:exit, result} ->
        # Script exit without state updates
        # For Script results, keep collector alive for output reading
        handle_collector_for_result(collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> update_exit_status(result)

        {:reply, {:exit, result}, new_state}

      {:exec, result, state_updates} ->
        # Exec replaces shell with command - with state updates
        # For Script results, keep collector alive for output reading
        handle_collector_for_result(collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> apply_state_updates(state_updates)
          |> update_exit_status(result)

        {:reply, {:exec, result}, new_state}

      {:exec, result} ->
        # Exec replaces shell with command - without state updates
        # For Script results, keep collector alive for output reading
        handle_collector_for_result(collector, result)

        new_state =
          state
          |> append_to_history(result)
          |> update_exit_status(result)

        {:reply, {:exec, result}, new_state}

      result ->
        # Other result patterns - cleanup collector
        cleanup_collector(collector)
        {:reply, result, state}
    end
  end

  def handle_call({:start_background_job, opts}, _from, state) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])

    job_number = state.next_job_number

    job_opts = [
      job_number: job_number,
      command: command,
      args: args,
      session_pid: self(),
      working_dir: state.working_dir,
      env:
        Map.new(state.variables, fn {k, v} ->
          {k, Variable.get(v, nil)}
        end)
        |> Map.to_list(),
      # Pass sinks so job output streams directly to destination
      stdout_sink: state.stdout_sink,
      stderr_sink: state.stderr_sink,
      # Also pass the session's persistent output collector for later retrieval
      output_collector: state.output_collector
    ]

    case DynamicSupervisor.start_child(state.job_supervisor, {JobProcess, job_opts}) do
      {:ok, job_pid} ->
        # Update state with new job
        new_jobs = Map.put(state.jobs, job_number, job_pid)

        new_state = %{
          state
          | jobs: new_jobs,
            next_job_number: job_number + 1,
            previous_job: state.current_job,
            current_job: job_number
        }

        # We don't know the OS PID yet - it will come via job_started message
        {:reply, {:ok, job_number, nil}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_jobs, _from, state) do
    jobs =
      state.jobs
      |> Enum.map(fn {_job_num, pid} ->
        try do
          JobProcess.get_job(pid)
        catch
          :exit, _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.job_number)

    {:reply, jobs, state}
  end

  def handle_call({:get_job, job_number}, _from, state) do
    case Map.get(state.jobs, job_number) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        try do
          job = JobProcess.get_job(pid)
          {:reply, {:ok, job}, state}
        catch
          :exit, _ -> {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call({:foreground_job, job_spec}, _from, state) do
    job_number = resolve_job_spec(job_spec, state)

    case Map.get(state.jobs, job_number) do
      nil ->
        {:reply, {:error, :no_such_job}, state}

      pid ->
        # This blocks until the job completes
        result = JobProcess.foreground(pid)
        {:reply, result, state}
    end
  end

  def handle_call({:background_job, job_spec}, _from, state) do
    job_number = resolve_job_spec(job_spec, state)

    case Map.get(state.jobs, job_number) do
      nil ->
        {:reply, {:error, :no_such_job}, state}

      pid ->
        result = JobProcess.background(pid)
        {:reply, result, state}
    end
  end

  def handle_call({:wait_for_jobs, nil}, _from, state) do
    # Wait for all jobs
    exit_codes =
      Enum.map(state.jobs, fn {_job_num, pid} ->
        case JobProcess.wait(pid) do
          {:ok, code} -> code
          {:error, _} -> 1
        end
      end)

    {:reply, {:ok, exit_codes}, state}
  end

  def handle_call({:wait_for_jobs, job_specs}, _from, state) do
    exit_codes =
      Enum.map(job_specs, fn job_spec ->
        job_number = resolve_job_spec(job_spec, state)

        case Map.get(state.jobs, job_number) do
          nil ->
            127

          pid ->
            case JobProcess.wait(pid) do
              {:ok, code} -> code
              {:error, _} -> 1
            end
        end
      end)

    {:reply, {:ok, exit_codes}, state}
  end

  def handle_call({:signal_job, job_spec, signal}, _from, state) do
    job_number = resolve_job_spec(job_spec, state)

    case Map.get(state.jobs, job_number) do
      nil ->
        {:reply, {:error, :no_such_job}, state}

      pid ->
        result = JobProcess.signal(pid, signal)
        {:reply, result, state}
    end
  end

  def handle_call(:pop_completed_jobs, _from, state) do
    {:reply, state.completed_jobs, %{state | completed_jobs: []}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:load_api, module}, _from, state) do
    new_state = do_load_api(state, module)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_command_history, _from, state) do
    {:reply, state.command_history, state}
  end

  def handle_call(:get_output, _from, state) do
    {stdout, stderr} = OutputCollector.output(state.output_collector)
    {:reply, {IO.iodata_to_binary(stdout), IO.iodata_to_binary(stderr)}, state}
  end

  def handle_call(:flush_output, _from, state) do
    chunks = OutputCollector.flush(state.output_collector)

    {stdout, stderr} =
      Enum.reduce(chunks, {[], []}, fn
        {:stdout, data}, {out, err} -> {[data | out], err}
        {:stderr, data}, {out, err} -> {out, [data | err]}
      end)

    {:reply,
     {stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr |> Enum.reverse() |> IO.iodata_to_binary()}, state}
  end

  @impl GenServer
  def handle_cast({:execute_async, ast}, state) do
    # Execute command asynchronously - don't reply to caller
    case execute_command_in_session(ast, state) do
      {:ok, result, state_updates} ->
        # Note: append to history first, then apply updates
        # This allows history -c to clear including itself
        new_state =
          state
          |> append_to_history(result)
          |> apply_state_updates(state_updates)

        {:noreply, new_state}

      {:ok, result} ->
        new_state = append_to_history(state, result)
        {:noreply, new_state}

      {:error, result} ->
        new_state = append_to_history(state, result)
        {:noreply, new_state}

      _other ->
        # For background jobs and other special cases, just continue
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:job_started, %Job{} = job}, state) do
    # Update $! to the OS PID of the most recent background job
    new_state =
      if job.os_pid do
        %{state | special_vars: Map.put(state.special_vars, "!", to_string(job.os_pid))}
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info({:job_completed, %Job{} = job}, state) do
    # Remove from active jobs and add to completed for notification
    new_jobs = Map.delete(state.jobs, job.job_number)
    new_completed = [job | state.completed_jobs]

    # Update current/previous job references
    new_state =
      cond do
        state.current_job == job.job_number ->
          %{state | current_job: state.previous_job, previous_job: nil}

        state.previous_job == job.job_number ->
          %{state | previous_job: nil}

        true ->
          state
      end

    {:noreply, %{new_state | jobs: new_jobs, completed_jobs: new_completed}}
  end

  def handle_info({:job_stopped, %Job{} = _job}, state), do: {:noreply, state}
  def handle_info({:job_resumed, %Job{} = _job}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    # Check if it's our job_supervisor - if so, we need to stop
    if pid == state.job_supervisor do
      {:stop, reason, state}
    else
      # Other linked processes exiting normally (like ports) - ignore
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.job_supervisor do
      DynamicSupervisor.stop(state.job_supervisor, :shutdown)
    end

    :ok
  end

  defp via(registry, id), do: {:via, Registry, {registry, id}}

  defp generate_session_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  # Resolve a job spec to a job number
  # Supports: nil (current job), integer, %% or %+ (current), %- (previous)
  defp resolve_job_spec(nil, state), do: state.current_job
  defp resolve_job_spec(job_number, _state) when is_integer(job_number), do: job_number

  defp resolve_job_spec("%%" <> _, state), do: state.current_job
  defp resolve_job_spec("%+" <> _, state), do: state.current_job
  defp resolve_job_spec("%-" <> _, state), do: state.previous_job

  defp resolve_job_spec("%" <> rest, state) do
    case Integer.parse(rest) do
      {num, ""} -> num
      _ -> state.current_job
    end
  end

  defp resolve_job_spec(_, state), do: state.current_job

  defp execute_command_in_session(ast, state, opts \\ []),
    do: Executor.execute(ast, state, nil, opts)

  # Check if errexit should cause shell to exit
  # Returns true if errexit is enabled and result has non-zero exit code
  defp should_errexit?(%CommandResult{exit_code: exit_code}, state) when exit_code != 0 do
    (state.options || %{})[:errexit] == true
  end

  defp should_errexit?(%{exit_code: exit_code}, state)
       when is_integer(exit_code) and exit_code != 0 do
    (state.options || %{})[:errexit] == true
  end

  defp should_errexit?(_, _), do: false

  # Check if onecmd option should cause shell to exit after this command
  # Returns true if onecmd (-t) is enabled
  # The state_updates parameter is used to avoid triggering on the command that sets onecmd
  defp should_onecmd_exit?(state, state_updates \\ %{}) do
    # Check if this command just set onecmd - if so, don't trigger yet
    options_updates = Map.get(state_updates, :options, %{})
    just_set_onecmd = Map.get(options_updates, :onecmd, nil) == true

    if just_set_onecmd do
      # Don't trigger for the command that sets onecmd
      false
    else
      (state.options || %{})[:onecmd] == true
    end
  end

  # Update the $? special variable with the exit code from the result
  # Also update PIPESTATUS array with pipeline exit codes
  # Accept both CommandResult (legacy) and AST nodes with execution results
  defp update_exit_status(state, %CommandResult{exit_code: exit_code})
       when is_integer(exit_code) do
    state
    |> set_exit_code(exit_code)
    |> update_pipestatus([exit_code])
  end

  # Script - extract pipestatus from last executed statement if it's a Pipeline
  defp update_exit_status(state, %Script{exit_code: exit_code, statements: statements})
       when is_integer(exit_code) do
    pipestatus = extract_pipestatus_from_statements(statements, exit_code)

    state
    |> set_exit_code(exit_code)
    |> update_pipestatus(pipestatus)
  end

  # Pipeline with pipestatus array
  defp update_exit_status(state, %{exit_code: exit_code, pipestatus: pipestatus})
       when is_integer(exit_code) and is_list(pipestatus) do
    state
    |> set_exit_code(exit_code)
    |> update_pipestatus(pipestatus)
  end

  defp update_exit_status(state, %{exit_code: exit_code}) when is_integer(exit_code) do
    # AST node with execution results (non-pipeline)
    state
    |> set_exit_code(exit_code)
    |> update_pipestatus([exit_code])
  end

  defp update_exit_status(state, _result), do: state

  # Set the $? special variable
  defp set_exit_code(state, exit_code) do
    %{state | special_vars: Map.put(state.special_vars, "?", exit_code)}
  end

  # Extract pipestatus from last executed statement in a script
  defp extract_pipestatus_from_statements(statements, default_exit_code) do
    # Find the last non-separator, non-comment statement
    last_stmt =
      statements
      |> Enum.reject(fn
        {:separator, _} -> true
        %AST.Comment{} -> true
        _ -> false
      end)
      |> List.last()

    case last_stmt do
      %Pipeline{pipestatus: pipestatus} when is_list(pipestatus) -> pipestatus
      _ -> [default_exit_code]
    end
  end

  # Update PIPESTATUS variable as an indexed array
  defp update_pipestatus(state, exit_codes) when is_list(exit_codes) do
    # Convert exit codes to indexed array: %{0 => "0", 1 => "1", ...}
    indexed_values =
      exit_codes
      |> Enum.with_index()
      |> Map.new(fn {code, idx} -> {idx, Integer.to_string(code)} end)

    pipestatus_var = Variable.new_indexed_array(indexed_values)
    %{state | variables: Map.put(state.variables, "PIPESTATUS", pipestatus_var)}
  end

  # Start a background job from a foreground AST (internal helper for handle_call)
  defp do_start_background_job(foreground_ast, state) do
    # For compound commands, run through bash to preserve && and || logic
    {command, args, command_string} =
      case foreground_ast do
        %Compound{} ->
          # Compound command - run through bash -c
          script = build_command_string(foreground_ast)
          {"bash", ["-c", script], script}

        _ ->
          # Simple command - extract directly
          {cmd, cmd_args} = extract_command_info(foreground_ast, state)
          {cmd, cmd_args, build_command_string(foreground_ast)}
      end

    job_opts = [
      job_number: state.next_job_number,
      command: command,
      args: args,
      session_pid: self(),
      working_dir: state.working_dir,
      env:
        Enum.map(state.variables, fn {k, v} ->
          {k, Variable.get(v, nil)}
        end),
      # Pass sinks so job output streams directly to destination
      stdout_sink: state.stdout_sink,
      stderr_sink: state.stderr_sink,
      # Also pass the session's persistent output collector for later retrieval
      output_collector: state.output_collector
    ]

    case DynamicSupervisor.start_child(state.job_supervisor, {JobProcess, job_opts}) do
      {:ok, job_pid} ->
        job_number = state.next_job_number

        # Wait for the OS process to actually start to get the real PID
        os_pid_str =
          case JobProcess.await_start(job_pid) do
            {:ok, os_pid} -> to_string(os_pid)
            {:error, _} -> ""
          end

        new_state = %{
          state
          | jobs: Map.put(state.jobs, job_number, job_pid),
            next_job_number: job_number + 1,
            previous_job: state.current_job,
            current_job: job_number,
            special_vars: Map.put(state.special_vars, "!", os_pid_str)
        }

        # Return a result indicating the job was backgrounded
        # For display, show the original command (not "bash -c ...")
        display_cmd = build_command_string(foreground_ast)

        # Write job notification to stdout sink
        if new_state.stdout_sink, do: new_state.stdout_sink.({:stdout, "[#{job_number}]\n"})

        result = %CommandResult{
          command: display_cmd,
          exit_code: 0,
          error: nil
        }

        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        # Write error message to stderr sink
        if state.stderr_sink,
          do:
            state.stderr_sink.({:stderr, "Failed to start background job: #{inspect(reason)}\n"})

        error_result = %CommandResult{
          command: command_string,
          exit_code: 1,
          error: :background_failed
        }

        {:reply, {:error, error_result}, state}
    end
  end

  # Start a background job synchronously and return the OS PID
  # This is used by Script executor to get $! immediately when & is encountered
  # Returns {os_pid_string, updated_session_state} or {:error, reason}
  defp start_background_job_sync(foreground_ast, current_session_state, original_state) do
    # For compound commands, run through bash to preserve && and || logic
    {command, args, _command_string} =
      case foreground_ast do
        %Compound{} ->
          script = build_command_string(foreground_ast)
          {"bash", ["-c", script], script}

        _ ->
          {cmd, cmd_args} = extract_command_info(foreground_ast, current_session_state)
          {cmd, cmd_args, build_command_string(foreground_ast)}
      end

    job_number = original_state.next_job_number

    # Create sinks that write to the session's PERSISTENT collector, not the temp one
    persistent_stdout_sink = Sink.collector(original_state.output_collector)
    persistent_stderr_sink = Sink.collector(original_state.output_collector)

    job_opts = [
      job_number: job_number,
      command: command,
      args: args,
      session_pid: self(),
      working_dir: current_session_state.working_dir,
      env:
        Enum.map(current_session_state.variables, fn {k, v} ->
          {k, Variable.get(v, nil)}
        end),
      stdout_sink: persistent_stdout_sink,
      stderr_sink: persistent_stderr_sink,
      output_collector: original_state.output_collector
    ]

    case DynamicSupervisor.start_child(original_state.job_supervisor, {JobProcess, job_opts}) do
      {:ok, job_pid} ->
        # Wait for the OS process to actually start
        os_pid_str =
          case JobProcess.await_start(job_pid) do
            {:ok, os_pid} -> to_string(os_pid)
            {:error, _} -> ""
          end

        # Write job notification
        if current_session_state.stdout_sink do
          current_session_state.stdout_sink.({:stdout, "[#{job_number}]\n"})
        end

        # Update session state with job info and $!
        updated_special_vars = Map.put(current_session_state.special_vars, "!", os_pid_str)

        updated_state = %{
          current_session_state
          | special_vars: updated_special_vars
        }

        # Return the OS PID string and a map of updates to apply to Session GenServer
        state_updates = %{
          jobs: Map.put(original_state.jobs, job_number, job_pid),
          next_job_number: job_number + 1,
          previous_job: original_state.current_job,
          current_job: job_number
        }

        {:ok, os_pid_str, updated_state, state_updates}

      {:error, reason} ->
        if current_session_state.stderr_sink do
          current_session_state.stderr_sink.(
            {:stderr, "Failed to start background job: #{inspect(reason)}\n"}
          )
        end

        {:error, reason}
    end
  end

  # Handle fg builtin - brings job to foreground and blocks until completion
  defp handle_foreground_job(job_number, from, state) do
    case Map.get(state.jobs, job_number) do
      nil ->
        # Write error message to stderr sink
        if state.stderr_sink,
          do: state.stderr_sink.({:stderr, "fg: %#{job_number}: no such job\n"})

        result = %CommandResult{
          command: "fg",
          exit_code: 1,
          error: :no_such_job
        }

        {:reply, {:error, result}, state}

      pid ->
        # Spawn a task to wait for the job and reply when done
        # This allows the Session to continue processing other messages
        caller = from
        stderr_sink = state.stderr_sink

        spawn(fn ->
          case JobProcess.foreground(pid) do
            {:ok, job_result} ->
              GenServer.reply(caller, {:ok, job_result})

            {:error, reason} ->
              # Write error message to stderr sink
              if stderr_sink, do: stderr_sink.({:stderr, "fg: error: #{inspect(reason)}\n"})

              result = %CommandResult{
                command: "fg",
                exit_code: 1,
                error: reason
              }

              GenServer.reply(caller, {:error, result})
          end
        end)

        {:noreply, state}
    end
  end

  # Handle bg builtin - resumes stopped jobs in background
  defp handle_background_jobs(job_numbers, state) do
    results =
      Enum.map(job_numbers, fn job_num ->
        case Map.get(state.jobs, job_num) do
          nil -> {:error, job_num}
          pid -> JobProcess.background(pid)
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      result = %CommandResult{
        command: "bg",
        exit_code: 0,
        error: nil
      }

      {:reply, {:ok, result}, state}
    else
      # Write error message to stderr sink
      if state.stderr_sink, do: state.stderr_sink.({:stderr, "bg: error resuming jobs\n"})

      result = %CommandResult{
        command: "bg",
        exit_code: 1,
        error: :job_error
      }

      {:reply, {:error, result}, state}
    end
  end

  # Handle wait builtin - waits for jobs to complete
  defp handle_wait_for_jobs(nil, from, state) do
    # Wait for all jobs
    if map_size(state.jobs) == 0 do
      result = %CommandResult{
        command: "wait",
        exit_code: 0,
        error: nil
      }

      {:reply, {:ok, result}, state}
    else
      # Spawn a task to wait for all jobs
      job_pids = Map.values(state.jobs)
      caller = from

      spawn(fn ->
        exit_codes =
          Enum.map(job_pids, fn pid ->
            try do
              case JobProcess.wait(pid) do
                # Job was running and completed - returns CommandResult
                {:ok, %CommandResult{exit_code: code}} -> code
                # Job was already done - returns just exit code
                {:ok, code} when is_integer(code) -> code
                {:error, _} -> 1
              end
            catch
              :exit, _ -> 1
            end
          end)

        last_code = List.last(exit_codes) || 0

        result = %CommandResult{
          command: "wait",
          exit_code: last_code,
          error: nil
        }

        GenServer.reply(caller, {:ok, result})
      end)

      {:noreply, state}
    end
  end

  defp handle_wait_for_jobs(job_specs, from, state) do
    # Resolve job specs to PIDs
    job_pids =
      job_specs
      |> Enum.map(fn
        :current -> Map.get(state.jobs, state.current_job)
        :previous -> Map.get(state.jobs, state.previous_job)
        num when is_integer(num) -> Map.get(state.jobs, num)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(job_pids) do
      result = %CommandResult{
        command: "wait",
        exit_code: 0,
        error: nil
      }

      {:reply, {:ok, result}, state}
    else
      caller = from

      spawn(fn ->
        exit_codes =
          Enum.map(job_pids, fn pid ->
            try do
              case JobProcess.wait(pid) do
                # Job was running and completed - returns CommandResult
                {:ok, %CommandResult{exit_code: code}} -> code
                # Job was already done - returns just exit code
                {:ok, code} when is_integer(code) -> code
                {:error, _} -> 1
              end
            catch
              :exit, _ -> 1
            end
          end)

        last_code = List.last(exit_codes) || 0

        result = %CommandResult{
          command: "wait",
          exit_code: last_code,
          error: nil
        }

        GenServer.reply(caller, {:ok, result})
      end)

      {:noreply, state}
    end
  end

  # Send signals synchronously for Script executor
  # Returns {:ok, exit_code} or {:error, exit_code, error_message}
  defp send_signals_sync(signal, targets, current_session_state, _original_state) do
    results =
      Enum.map(targets, fn
        {:job, job_num} ->
          case Map.get(current_session_state.jobs, job_num) do
            nil -> {:error, "no such job: %#{job_num}"}
            pid -> JobProcess.signal(pid, signal)
          end

        {:pid, os_pid} ->
          sig_num = signal_to_number(signal)

          case System.cmd("kill", ["-#{sig_num}", "#{os_pid}"], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {output, _} -> {:error, String.trim(output)}
          end
      end)

    errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, 0}
    else
      error_msg = Enum.map_join(errors, "\n", fn {:error, msg} -> msg end)

      if current_session_state.stderr_sink do
        current_session_state.stderr_sink.({:stderr, error_msg <> "\n"})
      end

      {:error, 1, error_msg}
    end
  end

  # Handle kill builtin - sends signals to jobs/processes
  defp handle_signal_jobs(signal, targets, state) do
    results =
      Enum.map(targets, fn
        {:job, job_num} ->
          case Map.get(state.jobs, job_num) do
            nil -> {:error, "no such job: %#{job_num}"}
            pid -> JobProcess.signal(pid, signal)
          end

        {:pid, os_pid} ->
          # For raw PIDs, use the kill command directly
          sig_num = signal_to_number(signal)

          case System.cmd("kill", ["-#{sig_num}", "#{os_pid}"], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {output, _} -> {:error, String.trim(output)}
          end
      end)

    errors =
      results
      |> Enum.with_index()
      |> Enum.filter(fn {result, _} -> match?({:error, _}, result) end)

    if Enum.empty?(errors) do
      result = %CommandResult{
        command: "kill",
        exit_code: 0,
        error: nil
      }

      {:reply, {:ok, result}, state}
    else
      error_msgs =
        Enum.map_join(errors, "\n", fn {{:error, msg}, _idx} -> msg end)

      # Write error message to stderr sink
      if state.stderr_sink, do: state.stderr_sink.({:stderr, error_msgs <> "\n"})

      result = %CommandResult{
        command: "kill",
        exit_code: 1,
        error: :signal_failed
      }

      {:reply, {:error, result}, state}
    end
  end

  # Extract command name and args from AST for background job execution
  defp extract_command_info(%Bash.AST.Command{name: name, args: args}, state) do
    command_name = word_to_string(name, state)
    expanded_args = Enum.map(args, &word_to_string(&1, state))
    {command_name, expanded_args}
  end

  defp extract_command_info(%Bash.AST.Pipeline{commands: [first | _]}, state) do
    extract_command_info(first, state)
  end

  defp extract_command_info(%Compound{statements: statements}, state) do
    # Find the first actual command (skip operators)
    first_cmd =
      Enum.find(statements, fn
        {:operator, _} -> false
        _ -> true
      end)

    if first_cmd do
      extract_command_info(first_cmd, state)
    else
      {"", []}
    end
  end

  defp extract_command_info(_ast, _state), do: {"", []}

  # Build a command string from AST for display
  defp build_command_string(ast) do
    to_string(ast)
  end

  # Convert a Word to string, expanding variables
  defp word_to_string(%Bash.AST.Word{parts: parts}, state) do
    Enum.map_join(parts, "", fn
      {:literal, text} ->
        text

      {:variable, %Bash.AST.Variable{name: var_name}} ->
        case Map.get(state.variables, var_name) do
          nil -> ""
          %Variable{} = var -> Variable.get(var, nil) || ""
        end

      _ ->
        ""
    end)
  end

  defp word_to_string(str, _state) when is_binary(str), do: str

  # Apply state updates from builtins (like cd) and function definitions
  defp apply_state_updates(state, updates) do
    state
    |> maybe_update_working_dir(updates)
    # Apply var_updates first, then env_updates (env_updates may come from
    # arithmetic statements that update variables after initial assignments)
    |> maybe_update_variables(updates)
    |> maybe_update_env_vars(updates)
    |> maybe_update_functions(updates)
    |> maybe_update_aliases(updates)
    |> maybe_update_positional_params(updates)
    |> maybe_update_dir_stack(updates)
    |> maybe_update_hash(updates)
    |> maybe_update_options(updates)
    |> maybe_clear_history(updates)
    |> maybe_delete_history_entry(updates)
    |> maybe_update_jobs(updates)
  end

  defp maybe_update_jobs(state, %{
         jobs: jobs,
         next_job_number: njn,
         current_job: cj,
         previous_job: pj
       }) do
    %{state | jobs: jobs, next_job_number: njn, current_job: cj, previous_job: pj}
  end

  defp maybe_update_jobs(state, _), do: state

  defp maybe_update_working_dir(state, %{working_dir: new_dir}) do
    %{state | working_dir: new_dir}
  end

  defp maybe_update_working_dir(state, _), do: state

  defp maybe_update_env_vars(state, %{env_updates: env_updates}) do
    # Convert env_updates to Variable structs with export attribute set
    exported_vars =
      Map.new(env_updates, fn {k, v} ->
        {k,
         %Variable{
           value: v,
           attributes: %{export: true, readonly: false, integer: false, array_type: nil}
         }}
      end)

    new_variables = Map.merge(state.variables, exported_vars)

    %{state | variables: new_variables}
  end

  defp maybe_update_env_vars(state, _), do: state

  defp maybe_update_variables(state, %{var_updates: var_updates}) do
    new_variables = Map.merge(state.variables, var_updates)
    %{state | variables: new_variables}
  end

  defp maybe_update_variables(state, _), do: state

  defp maybe_update_functions(state, %{function_updates: function_updates}) do
    new_functions = Map.merge(state.functions, function_updates)
    %{state | functions: new_functions}
  end

  defp maybe_update_functions(state, _), do: state

  defp maybe_update_aliases(state, %{alias_updates: :clear_all}) do
    %{state | aliases: %{}}
  end

  defp maybe_update_aliases(state, %{alias_updates: alias_updates}) when is_map(alias_updates) do
    # Remove aliases marked with :remove, add/update others
    new_aliases =
      Enum.reduce(alias_updates, state.aliases, fn
        {name, :remove}, acc -> Map.delete(acc, name)
        {name, value}, acc -> Map.put(acc, name, value)
      end)

    %{state | aliases: new_aliases}
  end

  defp maybe_update_aliases(state, _), do: state

  defp maybe_update_positional_params(state, %{positional_params: positional_params}) do
    %{state | positional_params: positional_params}
  end

  defp maybe_update_positional_params(state, _), do: state

  defp maybe_update_dir_stack(state, %{dir_stack: dir_stack}) do
    %{state | dir_stack: dir_stack}
  end

  defp maybe_update_dir_stack(state, _), do: state

  defp maybe_update_hash(state, %{hash_updates: :clear}) do
    %{state | hash: %{}}
  end

  defp maybe_update_hash(state, %{hash_updates: hash_updates}) when is_map(hash_updates) do
    # Remove entries marked with :delete, add/update others
    new_hash =
      Enum.reduce(hash_updates, state.hash, fn
        {name, :delete}, acc -> Map.delete(acc, name)
        {name, value}, acc -> Map.put(acc, name, value)
      end)

    %{state | hash: new_hash}
  end

  defp maybe_update_hash(state, _), do: state

  defp maybe_update_options(state, %{options: new_options}) do
    %{state | options: new_options}
  end

  defp maybe_update_options(state, _), do: state

  defp maybe_clear_history(state, %{clear_history: true}) do
    %{state | command_history: []}
  end

  defp maybe_clear_history(state, _), do: state

  defp maybe_delete_history_entry(state, %{delete_history_entry: index}) do
    new_history = List.delete_at(state.command_history, index)
    %{state | command_history: new_history}
  end

  defp maybe_delete_history_entry(state, _), do: state

  # Get default Bash environment variables
  defp get_bash_default_variables(working_dir) do
    # Detect system information
    {hostname, _} = System.cmd("hostname", [])
    hostname = String.trim(hostname)

    # Get architecture information
    {uname_m, _} = System.cmd("uname", ["-m"])
    hosttype = String.trim(uname_m)

    {uname_s, _} = System.cmd("uname", ["-s"])
    ostype = String.trim(uname_s) |> String.downcase()

    {uname_r, _} = System.cmd("uname", ["-r"])
    uname_release = String.trim(uname_r)
    # MACHTYPE format: cpu-company-system (e.g., x86_64-apple-darwin23.0.0)
    machtype = System.get_env("MACHTYPE") || "#{hosttype}-unknown-#{ostype}#{uname_release}"

    home = System.get_env("HOME", "/")
    path = System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")

    %{
      # Bash version info
      "BASH_VERSION" => Variable.new(@bash_version),

      # Directory and path related
      "PWD" => Variable.new(working_dir),
      "OLDPWD" => Variable.new(working_dir),
      "HOME" => Variable.new(home),
      "PATH" => Variable.new(path),
      "CDPATH" => Variable.new(""),

      # System info
      "HOSTNAME" => Variable.new(hostname),
      "HOSTTYPE" => Variable.new(hosttype),
      "MACHTYPE" => Variable.new(machtype),
      "OSTYPE" => Variable.new(ostype),

      # Terminal
      "TERM" => Variable.new("dumb"),

      # History settings
      "HISTFILE" => Variable.new(""),
      "HISTSIZE" => Variable.new("500"),
      "HISTFILESIZE" => Variable.new("500"),
      "HISTIGNORE" => Variable.new(""),

      # Shell options
      "SHELLOPTS" => Variable.new(""),

      # Pattern matching
      "GLOBIGNORE" => Variable.new(""),

      # Input Field Separator (space, tab, newline)
      "IFS" => Variable.new(" \t\n"),

      # Other bash settings
      "IGNOREEOF" => Variable.new(""),
      "MAILCHECK" => Variable.new("60"),
      "TIMEFORMAT" => Variable.new("")
    }
  end

  # Clean up collector without reading from it
  defp cleanup_collector(collector) do
    Process.unlink(collector)
    GenServer.stop(collector, :normal)
  end

  # Transfer output from temporary collector to session's persistent collector before cleanup
  defp transfer_and_cleanup_collector(temp_collector, session_collector) do
    # Get output from temporary collector
    {stdout_iodata, stderr_iodata} = OutputCollector.output(temp_collector)

    # Write to session's persistent collector (convert iodata to binary)
    if IO.iodata_length(stdout_iodata) > 0 do
      OutputCollector.write(session_collector, :stdout, IO.iodata_to_binary(stdout_iodata))
    end

    if IO.iodata_length(stderr_iodata) > 0 do
      OutputCollector.write(session_collector, :stderr, IO.iodata_to_binary(stderr_iodata))
    end

    # Now cleanup the temporary collector
    cleanup_collector(temp_collector)
  end

  # Handle collector based on result type
  # Script results keep their collector alive for output reading (dies with session)
  # Other results cleanup immediately
  defp handle_collector_for_result(_collector, %Bash.Script{}), do: :ok
  defp handle_collector_for_result(collector, _result), do: cleanup_collector(collector)

  # Transfer output from temp collector to session's persistent collector
  # For Scripts, also keep the temp collector alive for result.collector access
  defp transfer_to_persistent_collector(temp_collector, session_collector, %Bash.Script{}) do
    # Copy output to session's persistent collector (for session_stdout access)
    {stdout_iodata, stderr_iodata} = OutputCollector.output(temp_collector)

    if IO.iodata_length(stdout_iodata) > 0 do
      OutputCollector.write(session_collector, :stdout, IO.iodata_to_binary(stdout_iodata))
    end

    if IO.iodata_length(stderr_iodata) > 0 do
      OutputCollector.write(session_collector, :stderr, IO.iodata_to_binary(stderr_iodata))
    end

    # Keep temp collector alive for result.collector access (get_stdout/get_stderr)
    :ok
  end

  defp transfer_to_persistent_collector(temp_collector, session_collector, _result) do
    # Non-Script results: transfer and cleanup
    transfer_and_cleanup_collector(temp_collector, session_collector)
  end

  # Helper to append command result to history
  # Accept both CommandResult (legacy) and AST nodes with execution results
  defp append_to_history(state, %CommandResult{} = result) do
    %{state | command_history: state.command_history ++ [result]}
  end

  defp append_to_history(state, %{exit_code: exit_code} = result) when not is_nil(exit_code) do
    # AST node with execution results
    %{state | command_history: state.command_history ++ [result]}
  end

  defp append_to_history(state, _result), do: state

  # Convert signal name to number
  defp signal_to_number(sig) when is_integer(sig), do: sig
  defp signal_to_number(:sigterm), do: 15
  defp signal_to_number(:sigkill), do: 9
  defp signal_to_number(:sigstop), do: 19
  defp signal_to_number(:sigcont), do: 18
  defp signal_to_number(:sighup), do: 1
  defp signal_to_number(:sigint), do: 2
  defp signal_to_number(:sigquit), do: 3
  defp signal_to_number(:sigusr1), do: 10
  defp signal_to_number(:sigusr2), do: 12
  defp signal_to_number(other), do: other
end
