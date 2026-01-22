defmodule Bash.Builtin do
  @moduledoc """
  Central registry for Bash builtin commands and reserved words.

  This module provides:
  - List of reserved words (keywords)
  - List of all standard bash builtins
  - Map of implemented builtins to their modules
  - `defbash` macro for implementing builtins with streaming I/O

  Reference: https://cgit.git.savannah.gnu.org/plain/bash.git/tree/builtins?h=bash-5.3

  ## Implementing Builtins with defbash

  Use `use Bash.Builtin` and the `defbash` macro to implement builtins
  with automatic streaming I/O through sinks:

      defmodule Bash.Builtin.Echo do
        use Bash.Builtin

        defbash execute(args, state) do
          text = Enum.join(args, " ")
          puts(text)
          :ok
        end
      end

  ## I/O Functions

  Inside `defbash`, the following functions are available:

    * `puts(message)` - Write to stdout with newline
    * `write(data)` - Write raw data to stdout
    * `error(message)` - Write to stderr with newline
    * `gets()` - Read a line from stdin
    * `read(:all)` - Read all stdin

  ## State Updates

  Use `update_state/1` to request state changes:

      defbash execute(args, state) do
        update_state(working_dir: "/new/path", env: %{"FOO" => "bar"})
        :ok
      end

  ## Return Values

    * `:ok` - Exit code 0
    * `{:ok, n}` - Exit code n
    * `{:error, message}` - Exit code 1, message to stderr
  """

  alias Bash.Builtin

  @doc """
  Sets up a module as a builtin implementation with streaming I/O.

  ## Example

      defmodule Bash.Builtin.MyBuiltin do
        use Bash.Builtin

        defbash execute(args, state) do
          puts("Hello from builtin!")
          :ok
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      import Bash.Builtin, only: [defbash: 2]

      # Store state update requests during execution
      @before_compile Bash.Builtin
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      # Default no-op if module doesn't define custom behavior
    end
  end

  @doc """
  Define a builtin's execute function with streaming I/O support.

  The function receives:
    * `args` - List of string arguments
    * `state` - The session state map (with sinks, variables, etc.)

  Inside the body, use:
    * `puts/1` - Write line to stdout
    * `write/1` - Write raw to stdout
    * `error/1` - Write line to stderr
    * `gets/0` - Read line from stdin
    * `read/1` - Read from stdin
    * `update_state/1` - Request state changes

  Return values:
    * `:ok` - Success, exit code 0
    * `{:ok, n}` - Success, exit code n
    * `{:error, message}` - Failure, writes message to stderr
  """
  defmacro defbash({:execute, _meta, [args_var, state_var]}, do: body) do
    # Use fresh hygienic variables for the function signature to avoid warnings
    # when user declares underscored variables like _state or _args.
    # Then bind user's variable names to allow them to reference args/state in body.
    quote do
      @doc false
      def execute(args_internal__, stdin, state_internal__) do
        # Merge stdin into state if provided and not already present
        state_with_stdin =
          if stdin != nil and not Map.has_key?(state_internal__, :stdin) do
            Map.put(state_internal__, :stdin, stdin)
          else
            state_internal__
          end

        # Bind user's variable names so their body can reference them
        # Important: bind to state_with_stdin so user code has access to stdin
        unquote(args_var) = args_internal__
        unquote(state_var) = state_with_stdin

        # Initialize execution context in process dictionary
        Bash.Builtin.Context.init(state_with_stdin)

        try do
          result = unquote(body)
          Bash.Builtin.Context.finalize(result)
        rescue
          e ->
            Bash.Builtin.Context.cleanup()
            reraise e, __STACKTRACE__
        end
      end

      # I/O helper functions injected into module scope
      defp puts(message) do
        Bash.Builtin.Context.puts(message)
      end

      defp write(data) do
        Bash.Builtin.Context.write(data)
      end

      defp error(message) do
        Bash.Builtin.Context.error(message)
      end

      defp gets do
        Bash.Builtin.Context.gets()
      end

      defp read(mode) do
        Bash.Builtin.Context.read(mode)
      end

      defp update_state(updates) do
        Bash.Builtin.Context.update_state(updates)
      end

      defp get_state do
        Bash.Builtin.Context.get_state()
      end
    end
  end

  # Reserved words (keywords) in bash
  @reserved_words ~w[
    if then else elif fi
    case esac
    for while until do done in
    function select time coproc
  ]

  # All standard bash builtins (whether implemented or not)
  @all_builtins ~w[
    : . break cd continue dirs echo eval exec exit export false
    getopts hash help history jobs kill let local logout
    mapfile popd printf pushd pwd read readarray return
    set shift shopt source test times trap true type
    typeset ulimit umask unalias unset wait declare bg fg
  ]

  # Map of implemented builtins to their module implementations
  @builtin_modules %{
    # ! PIPELINE is tokenized
    # (( Arithmetic )) is tokenized
    "." => Builtin.Source,
    ":" => Builtin.Colon,
    "[" => Builtin.TestCommand,
    "alias" => Builtin.Alias,
    "bg" => Builtin.Bg,
    "bind" => Builtin.Unsupported,
    "break" => Builtin.Break,
    "builtin" => Builtin.Builtin,
    "caller" => Builtin.Caller,
    "cd" => Builtin.Cd,
    "command" => Builtin.Command,
    "compgen" => Builtin.Unsupported,
    "complete" => Builtin.Unsupported,
    "compopt" => Builtin.Unsupported,
    "continue" => Builtin.Continue,
    "coproc" => Builtin.Coproc,
    "declare" => Builtin.Declare,
    "dirs" => Builtin.Dirs,
    "disown" => Builtin.Disown,
    "echo" => Builtin.Echo,
    "enable" => Builtin.Enable,
    "eval" => Builtin.Eval,
    "exec" => Builtin.Exec,
    "exit" => Builtin.Exit,
    "export" => Builtin.Export,
    "false" => Builtin.False,
    "fc" => Builtin.Fc,
    "fg" => Builtin.Fg,
    "getopts" => Builtin.Getopts,
    "hash" => Builtin.Hash,
    "help" => Builtin.Help,
    "history" => Builtin.History,
    "jobs" => Builtin.Jobs,
    "kill" => Builtin.Kill,
    "let" => Builtin.Let,
    "local" => Builtin.Local,
    "logout" => Builtin.Exit,
    "mapfile" => Builtin.Mapfile,
    "popd" => Builtin.Popd,
    "printf" => Builtin.Printf,
    "pushd" => Builtin.Pushd,
    "pwd" => Builtin.Pwd,
    "read" => Builtin.Read,
    "readarray" => Builtin.Mapfile,
    "readonly" => Builtin.Readonly,
    "return" => Builtin.Return,
    "select" => Builtin.Unsupported,
    "set" => Builtin.Set,
    "shift" => Builtin.Shift,
    "shopt" => Builtin.Shopt,
    "source" => Builtin.Source,
    "suspend" => Builtin.Suspend,
    "test" => Builtin.TestCommand,
    "times" => Builtin.Times,
    "trap" => Builtin.Trap,
    "true" => Builtin.True,
    "type" => Builtin.Type,
    "typeset" => Builtin.Declare,
    "ulimit" => Builtin.Ulimit,
    "umask" => Builtin.Umask,
    "unalias" => Builtin.Unalias,
    "unset" => Builtin.Unset,
    "wait" => Builtin.Wait
  }

  @doc """
  Returns the list of bash reserved words.
  """
  def reserved_words, do: @reserved_words

  @doc """
  Returns the list of all bash builtins (implemented and unimplemented).
  """
  def all_builtins, do: @all_builtins

  @doc """
  Returns the map of implemented builtins to their module implementations.
  """
  def builtin_modules, do: @builtin_modules

  @doc """
  Returns the list of implemented builtin names.
  """
  def implemented_builtins, do: Map.keys(@builtin_modules)

  @doc """
  Check if a name is a reserved word.
  """
  def reserved_word?(name), do: name in @reserved_words

  @doc """
  Check if a name is a builtin (implemented or not).
  """
  def builtin?(name), do: name in @all_builtins

  @doc """
  Check if a builtin is implemented.
  """
  def implemented?(name), do: Map.has_key?(@builtin_modules, name)

  @doc """
  Get the module for a builtin, if implemented.
  """
  def get_module(name), do: Map.get(@builtin_modules, name)
end
