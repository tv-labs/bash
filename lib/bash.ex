defmodule Bash do
  @external_resource "README.md"
  @moduledoc File.read!("README.md") |> String.split("<!-- MDOC -->") |> Enum.at(1)

  alias Bash.ExecutionResult
  alias Bash.Script
  alias Bash.Session
  alias Bash.SyntaxError
  alias Bash.Telemetry

  @doc """
  Executes a Bash script, AST, or string.

  Accepts:
  - `script`: Can be:
    - A string - will be parsed and executed
    - An AST struct (Script, Command, Pipeline, etc.) - will be executed in sequence
    - A result tuple `{:ok | :error | :exit, result, session}` - continues with that session
  - `session_or_opts`: Can be:
    - `nil` - creates a new session with default options
    - A PID - uses an existing session
    - Keyword list - creates a new session with these initialization options
  - `opts`: Execution options:
    - `await: true|false` - whether to wait for result (default: true)

  Returns:
  - When `await: true` (default): `{:ok, result, session_pid}` or `{:error, result, session_pid}`
  - When `await: false`: `{:ok, session_pid}`

  ## Examples

      # Execute a string
      {:ok, result, session_pid} = Bash.run("echo hello")

      # Execute an AST
      {:ok, result, session_pid} = Bash.run(~BASH"echo hello")

      # Execute a multi-line script
      {:ok, result, session_pid} = Bash.run(\"\"\"
      x=5
      y=10
      echo $x $y
      \"\"\")

      # With existing session PID
      {:ok, session} = Session.new()
      {:ok, result, ^session} = Bash.run(~BASH"echo hello", session)

      # With session initialization options
      {:ok, result, session_pid} = Bash.run(~BASH"echo $USER", env: %{"USER" => "alice"})

      # Async execution
      {:ok, ref, session_pid} = Bash.run(~BASH"sleep 10", nil, await: false)

      # Pipe-friendly chaining - continues with the same session
      Bash.run("x=5")
      |> Bash.run("echo $x")
      |> Bash.stdout()
      #=> "5\\n"

  """
  # 1-arity: just a script, creates new session
  def run(script) when is_binary(script), do: run(script, nil, [])
  def run(%Script{} = script), do: run(script, nil, [])

  # 2-arity: script + session/opts OR result tuple + script (for piping)
  def run({status, _result, session}, script)
      when status in [:ok, :error, :exit, :exec] and is_pid(session) do
    run(script, session, [])
  end

  def run(script, session_or_opts), do: run(script, session_or_opts, [])

  # 3-arity: result tuple + script + opts (for piping with options)
  def run({status, _result, session}, script, opts)
      when status in [:ok, :error, :exit, :exec] and is_pid(session) do
    run(script, session, opts)
  end

  def run(script, session_or_opts, opts) when is_binary(script) do
    case parse(script) do
      {:ok, %Script{} = ast} ->
        run(ast, session_or_opts, opts)

      {:error, %SyntaxError{} = error} ->
        {:error,
         %__MODULE__.CommandResult{
           command: "parse",
           exit_code: 1,
           error: error.message
         }, nil}
    end
  end

  def run(%Script{} = script, session_or_opts, _opts) do
    {session_pid, _resolved_opts} = resolve_session(session_or_opts)

    Telemetry.span(session_pid, fn ->
      result =
        case Session.execute(session_pid, script) do
          {:ok, executed_script} ->
            {:ok, executed_script, session_pid}

          {:exit, executed_script} ->
            {:exit, executed_script, session_pid}

          {:exec, executed_script} ->
            {:exec, executed_script, session_pid}

          {:error, executed_script} ->
            {:error, executed_script, session_pid}
        end

      stop_metadata = telemetry_stop_metadata(result)
      {result, stop_metadata}
    end)
  end

  def run(ast, session_or_opts, opts) do
    {session_pid, _resolved_opts} = resolve_session(session_or_opts)
    await = Keyword.get(opts, :await, true)

    if await do
      Telemetry.span(session_pid, fn ->
        result =
          case Session.execute(session_pid, ast) do
            {:ok, result} ->
              {:ok, result, session_pid}

            {:exit, result} ->
              {:exit, result, session_pid}

            {:exec, result} ->
              {:exec, result, session_pid}

            {:error, result} ->
              {:error, result, session_pid}
          end

        stop_metadata = telemetry_stop_metadata(result)
        {result, stop_metadata}
      end)
    else
      Session.execute_async(session_pid, ast)
      {:ok, session_pid}
    end
  end

  @doc """
  Execute a Bash script file.

  Reads and parses the file, then executes it. Accepts the same session and
  execution options as `run/3`.

  Returns:
  - `{:ok, result, session_pid}` on success
  - `{:error, result, session_pid}` on execution error
  - `{:error, %SyntaxError{}, nil}` on parse error
  - `{:error, posix_error, nil}` on file read error

  ## Examples

      # Execute a script file
      {:ok, result, session_pid} = Bash.run_file("script.sh")

      # With session options
      {:ok, result, session_pid} = Bash.run_file("script.sh", env: %{"DEBUG" => "1"})

      # With existing session
      {:ok, session} = Bash.Session.new()
      {:ok, result, ^session} = Bash.run_file("script.sh", session)

  """
  @spec run_file(Path.t(), pid() | keyword() | map() | nil, keyword()) ::
          {:ok, term(), pid()}
          | {:error, term(), pid() | nil}
          | {:exit, term(), pid()}
          | {:exec, term(), pid()}
  def run_file(path, session_or_opts \\ nil, opts \\ [])

  def run_file(path, session_or_opts, opts) when is_binary(path) do
    case parse_file(path) do
      {:ok, %Script{} = ast} ->
        run(ast, session_or_opts, opts)

      {:error, %SyntaxError{} = error} ->
        {:error,
         %__MODULE__.CommandResult{
           command: "parse",
           exit_code: 1,
           error: error.message
         }, nil}

      {:error, posix_error} ->
        {:error,
         %__MODULE__.CommandResult{
           command: "read",
           exit_code: 1,
           error: "#{path}: #{:file.format_error(posix_error)}"
         }, nil}
    end
  end

  defp resolve_session(pid) when is_pid(pid), do: {pid, []}

  defp resolve_session(opts) when is_list(opts) or is_map(opts) or is_nil(opts) do
    opts_list = if is_map(opts), do: Map.to_list(opts), else: opts || []

    case Keyword.get(opts_list, :session) do
      pid when is_pid(pid) ->
        remaining_opts = Keyword.delete(opts_list, :session)
        {pid, remaining_opts}

      nil ->
        {:ok, pid} = Session.new(opts_list)
        {pid, opts_list}
    end
  end

  defp telemetry_stop_metadata({status, result, _session_pid}) do
    %{status: status, exit_code: ExecutionResult.exit_code(result)}
  end

  @doc """
  Parse a Bash script string into an AST.

  Returns `{:ok, %Script{}}` on success, or `{:error, %SyntaxError{}}` on failure.

  ## Examples

      iex> {:ok, script} = Bash.parse("echo hello")
      iex> script.statements
      [%Bash.AST.Command{name: "echo", args: ["hello"]}]

      iex> {:error, %Bash.SyntaxError{}} = Bash.parse("if true")
      # Missing 'then' and 'fi'

  """
  @spec parse(String.t()) :: {:ok, Script.t()} | {:error, SyntaxError.t()}
  def parse(script) when is_binary(script) do
    case __MODULE__.Parser.parse(script) do
      {:ok, %Script{} = ast} ->
        {:ok, ast}

      {:error, reason, line, column} ->
        {:error, SyntaxError.from_parse_error(script, reason, line, column)}
    end
  end

  @doc """
  Parse a Bash script file into an AST.

  Reads the file and parses its contents. Returns `{:ok, %Script{}}` on success,
  or `{:error, reason}` on failure (either file read error or syntax error).

  ## Examples

      iex> {:ok, script} = Bash.parse_file("script.sh")
      iex> script.statements
      [%Bash.AST.Command{...}]

      iex> {:error, %Bash.SyntaxError{}} = Bash.parse_file("invalid.sh")

      iex> {:error, :enoent} = Bash.parse_file("missing.sh")

  """
  @spec parse_file(Path.t()) :: {:ok, Script.t()} | {:error, SyntaxError.t() | File.posix()}
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validate a Bash script without executing it.

  Parses the script and returns `:ok` if valid, or `{:error, %SyntaxError{}}`
  if the script has syntax errors.

  ## Examples

      iex> Bash.validate("echo hello")
      :ok

      iex> {:error, %Bash.SyntaxError{}} = Bash.validate("if true")
      # Missing 'then' and 'fi'

  """
  @spec validate(String.t()) :: :ok | {:error, SyntaxError.t()}
  def validate(script) when is_binary(script) do
    case parse(script) do
      {:ok, %Script{}} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc ~S"""
  Escape a string for safe interpolation within a Bash quoted context.

  This function ensures the string won't break out of its quote context.
  It does NOT escape expansion characters like `$` - users should choose
  the appropriate quote type (single quotes for literal content, double
  quotes when expansion is desired).

  ## Arguments

  - `string` - the string to escape
  - `context` - the quote context:
    - `?"` - double quotes: escapes `"` and `\`
    - `?'` - single quotes: escapes `'` using end/restart technique
    - `"DELIM"` - heredoc: validates delimiter doesn't appear on its own line

  ## Examples

      # Double quotes - escape " and \
      iex> Bash.escape!("say \"hello\"", ?")
      "say \\\"hello\\\""

      iex> Bash.escape!("path\\to\\file", ?")
      "path\\\\to\\\\file"

      # Single quotes - escape ' using end/restart technique
      iex> Bash.escape!("it's here", ?')
      "it'\\''s here"

      # Heredoc - validates delimiter doesn't appear
      iex> Bash.escape!("safe content", "EOF")
      "safe content"

  ## Raises

  Raises `Bash.EscapeError` if the string cannot be safely escaped,
  such as when a heredoc delimiter appears on its own line.

      Bash.escape!("line1\nEOF\nline2", "EOF")
      #=> raises Bash.EscapeError

  """
  @spec escape!(String.t(), integer() | String.t()) :: String.t()
  def escape!(string, context)

  def escape!(string, ?") when is_binary(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  def escape!(string, ?') when is_binary(string) do
    String.replace(string, "'", "'\\''")
  end

  def escape!(string, delimiter) when is_binary(string) and is_binary(delimiter) do
    if heredoc_contains_delimiter?(string, delimiter) do
      raise Bash.EscapeError,
        reason: :delimiter_in_content,
        content: string,
        context: delimiter
    else
      string
    end
  end

  defp heredoc_contains_delimiter?(string, delimiter) do
    string
    |> String.split("\n")
    |> Enum.any?(&(&1 == delimiter))
  end

  @doc "Format a file"
  @spec format_file(Path.t(), Keyword.t()) :: :ok
  def format_file(file, opts \\ []) do
    content = File.read!(file)
    formatted = Bash.Formatter.format(content, opts)
    File.write!(file, formatted)
  end

  @spec format_file(String.t(), Keyword.t()) :: String.t()
  def format(content, opts \\ []) do
    Bash.Formatter.format(content, opts)
  end

  @doc """
  Execute a function with a session that is automatically stopped afterwards.

  Creates a new session, passes it to the function, and ensures the session
  is stopped when the function returns or raises. Returns whatever the
  function returns.

  ## Examples

      # Simple usage
      result = Bash.with_session(fn session ->
        {:ok, result, _} = Bash.run("echo hello", session)
        Bash.stdout(result)
      end)
      #=> "hello\\n"

      # With session options
      result = Bash.with_session([env: %{"USER" => "alice"}], fn session ->
        {:ok, result, _} = Bash.run("echo $USER", session)
        Bash.stdout(result)
      end)
      #=> "alice\\n"

      # With APIs
      Bash.with_session([apis: [MyApp.BashAPI]], fn session ->
        Bash.run("myapp.greet World", session)
      end)

  """
  @spec with_session((pid() -> result)) :: result when result: term()
  def with_session(fun) when is_function(fun, 1) do
    with_session([], fun)
  end

  @spec with_session(keyword(), (pid() -> result)) :: result when result: term()
  def with_session(opts, fun) when is_list(opts) and is_function(fun, 1) do
    {:ok, session} = Session.new(opts)

    try do
      fun.(session)
    after
      Session.stop(session)
    end
  end

  @doc ~S"""
  Get stdout output from an executed script, AST node, or session.

  Accepts:
  - A result struct
  - A result tuple `{:ok | :error, result, session}` for pipe chaining
  - A session PID to get accumulated stdout

  ## Examples

      {:ok, script, _} = Bash.run("echo hello")
      Bash.stdout(script)
      #=> "hello\n"

      # Pipe-friendly
      Bash.run("echo hello") |> Bash.stdout()
      #=> "hello\n"

      # From session
      {:ok, session} = Bash.Session.new()
      Bash.run("echo hello", session)
      Bash.stdout(session)
      #=> "hello\n"

  """
  @spec stdout(ExecutionResult.t() | {atom(), ExecutionResult.t(), pid()} | pid()) :: String.t()
  def stdout({_status, result, _session}), do: ExecutionResult.stdout(result)
  def stdout(session) when is_pid(session), do: Session.get_output(session) |> elem(0)
  def stdout(result), do: ExecutionResult.stdout(result)

  @doc ~S"""
  Get stderr output from an executed script, AST node, or session.

  Accepts:
  - A result struct
  - A result tuple `{:ok | :error, result, session}` for pipe chaining
  - A session PID to get accumulated stderr

  ## Examples

      {:ok, script, _} = Bash.run("echo error >&2")
      Bash.stderr(script)
      #=> "error\n"

      # Pipe-friendly
      Bash.run("echo error >&2") |> Bash.stderr()
      #=> "error\n"

      # From session
      {:ok, session} = Bash.Session.new()
      Bash.run("echo error >&2", session)
      Bash.stderr(session)
      #=> "error\n"

  """
  @spec stderr(ExecutionResult.t() | {atom(), ExecutionResult.t(), pid()} | pid()) :: String.t()
  def stderr({_status, result, _session}), do: ExecutionResult.stderr(result)
  def stderr(session) when is_pid(session), do: Session.get_output(session) |> elem(1)
  def stderr(result), do: ExecutionResult.stderr(result)

  @doc ~S"""
  Get all output (stdout + stderr) from an executed script, AST node, or session.

  Accepts:
  - A result struct
  - A result tuple `{:ok | :error, result, session}` for pipe chaining
  - A session PID to get accumulated output

  ## Examples

      {:ok, script, _} = Bash.run("echo out; echo err >&2")
      Bash.output(script)
      #=> "out\nerr\n"

      # Pipe-friendly
      Bash.run("echo out; echo err >&2") |> Bash.output()
      #=> "out\nerr\n"

      # From session
      {:ok, session} = Bash.Session.new()
      Bash.run("echo out; echo err >&2", session)
      Bash.output(session)
      #=> "out\nerr\n"

  """
  @spec output(ExecutionResult.t() | {atom(), ExecutionResult.t(), pid()} | pid()) :: String.t()
  def output({_status, result, _session}), do: ExecutionResult.all_output(result)
  def output(session) when is_pid(session), do: stdout(session) <> stderr(session)
  def output(result), do: ExecutionResult.all_output(result)

  @doc """
  Get the exit code from an executed script or AST node.

  Accepts either a result struct or a result tuple for pipe chaining.

  ## Examples

      {:ok, script, _} = Bash.run("exit 42")
      Bash.exit_code(script)
      #=> 42

      # Pipe-friendly
      Bash.run("exit 42") |> Bash.exit_code()
      #=> 42

  """
  @spec exit_code(ExecutionResult.t() | {atom(), ExecutionResult.t(), pid()}) ::
          non_neg_integer() | nil
  def exit_code({_status, result, _session}), do: ExecutionResult.exit_code(result)
  def exit_code(result), do: ExecutionResult.exit_code(result)

  @doc """
  Check if execution was successful (exit code 0).

  Accepts either a result struct or a result tuple for pipe chaining.

  ## Examples

      {:ok, script, _} = Bash.run("true")
      Bash.success?(script)
      #=> true

      # Pipe-friendly
      Bash.run("true") |> Bash.success?()
      #=> true

  """
  @spec success?(ExecutionResult.t() | {atom(), ExecutionResult.t(), pid()}) :: boolean()
  def success?({_status, result, _session}), do: ExecutionResult.success?(result)
  def success?(result), do: ExecutionResult.success?(result)

  # ===========================================================================
  # Interop I/O Functions
  # ===========================================================================
  # These functions are for use within `defbash` function bodies.
  # They operate on process-local context set up by the defbash macro.

  @doc """
  Write to stdout within a `defbash` function.

  This function is only valid inside `defbash` function bodies.

  ## Examples

      defbash greet(args, _state) do
        name = List.first(args, "world")
        Bash.puts("Hello \#{name}!\\n")
        :ok
      end

  """
  defdelegate puts(message), to: Bash.Interop.IO

  @doc """
  Write to stdout or stderr within a `defbash` function.

  This function is only valid inside `defbash` function bodies.

  ## Examples

      defbash example(_args, _state) do
        Bash.puts(:stdout, "normal output\\n")
        Bash.puts(:stderr, "error output\\n")
        :ok
      end

  """
  defdelegate puts(stream, message), to: Bash.Interop.IO

  @doc """
  Get stdin as a lazy stream within a `defbash` function.

  This function is only valid inside `defbash` function bodies.
  Returns an empty stream if no stdin is available.

  ## Examples

      defbash upcase(_args, _state) do
        Bash.stream(:stdin)
        |> Stream.each(fn line ->
          Bash.puts(String.upcase(line))
        end)
        |> Stream.run()

        :ok
      end

  """
  defdelegate stream(source), to: Bash.Interop.IO

  @doc """
  Get the current session state within a `defbash` function.

  This function is only valid inside `defbash` function bodies.

  ## Examples

      defbash show_var(args, _state) do
        state = Bash.get_state()
        var_name = List.first(args)
        value = get_in(state, [:variables, var_name])
        Bash.puts("\#{var_name}=\#{inspect(value)}\\n")
        :ok
      end

  """
  defdelegate get_state(), to: Bash.Interop.IO

  @doc """
  Update the session state within a `defbash` function.

  This function is only valid inside `defbash` function bodies.
  The updated state will be returned after the function completes.

  ## Examples

      defbash set_var(args, _state) do
        [name, value] = args
        state = Bash.get_state()
        new_state = put_in(state, [:variables, name], Bash.Variable.new(value))
        Bash.put_state(new_state)
        :ok
      end

  """
  defdelegate put_state(new_state), to: Bash.Interop.IO
end
