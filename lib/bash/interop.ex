defmodule Bash.Interop do
  @moduledoc ~S"""
  Define Elixir functions callable from Bash scripts.

  This module provides the `defbash` macro for creating functions that can be
  invoked from bash scripts using the `namespace.function` syntax.

  ## Usage

      defmodule MyApp.BashAPI do
        use Bash.Interop, namespace: "myapp"

        defbash greet(args, _state) do
          case args do
            [name | _] ->
              Bash.puts("Hello #{name}!\n")
              :ok

            [] ->
              {:error, "usage: myapp.greet NAME"}
          end
        end
      end

  Functions are loaded into a session with `Bash.Session.load_api/2`:

      session = Bash.Session.new()
      session = Bash.Session.load_api(session, MyApp.BashAPI)

  Then callable from Bash as `myapp.greet "World"`.

  ## I/O Functions

  Inside defbash functions, use the `Bash` module for I/O:

    * `Bash.puts(message)` - Write to stdout
    * `Bash.puts(:stderr, message)` - Write to stderr
    * `Bash.stream(:stdin)` - Get stdin as a lazy Stream
    * `Bash.get_state()` - Get current session state
    * `Bash.put_state(state)` - Update session state

  ## Return Values

  defbash functions must return one of:

    * `:ok` - Exit 0
    * `{:ok, message}` - Exit 0, output to stdout
    * `{:ok, exit_code}` - Exit n when exit code is an integer
    * `{:ok, exit_code, new_state}` - Exit n, update state
    * `{:error, message}` - Exit 1 and stop execution chain regardless of Bash session flags
    * `:continue` - Only valid in loops
    * `:break` - Only valid in loops
  """

  @doc """
  Sets up a module to define bash-callable functions.

  ## Options

    * `:namespace` - Required. The namespace prefix for bash calls.
    * `:on_define` - Optional. A callback function invoked at compile time when
      each `defbash` function is defined. Receives `(function_name, module)` and
      should return a metadata map or `nil`. This allows external modules to
      annotate functions using module attributes.

  ## Example

      defmodule MyApp.BashAPI do
        use Bash.Interop, namespace: "myapp"
      end

  ## Example with on_define callback

      defmodule MyApp.RemoteBashAPI do
        use Bash.Interop,
          namespace: "remote",
          on_define: fn name, module ->
            execute_on = Module.get_attribute(module, :execute_on) || :guest
            Module.delete_attribute(module, :execute_on)
            %{execute_on: execute_on}
          end

        @execute_on :server
        defbash server_func(args, _state), do: {:ok, "runs on server"}

        defbash guest_func(args, _state), do: {:ok, "runs on guest"}
      end
  """
  defmacro __using__(opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    on_define = Keyword.get(opts, :on_define)

    quote bind_quoted: [namespace: namespace, on_define: on_define] do
      @namespace namespace
      @bash_functions []
      @bash_function_meta %{}
      @bash_on_define on_define
      @before_compile Bash.Interop
      import Bash.Interop, only: [defbash: 2]

      @doc false
      def __bash_namespace__, do: @namespace
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    functions = Module.get_attribute(env.module, :bash_functions)
    function_meta = Module.get_attribute(env.module, :bash_function_meta)

    meta_func =
      if function_meta == %{} do
        quote do
          @doc false
          def __bash_function_meta__(_name), do: nil
        end
      else
        quote do
          @doc false
          def __bash_function_meta__(name) when is_binary(name) do
            Map.get(unquote(Macro.escape(function_meta)), name)
          end

          def __bash_function_meta__(name) when is_atom(name) do
            __bash_function_meta__(Atom.to_string(name))
          end
        end
      end

    quote do
      @doc false
      def __bash_functions__, do: unquote(Macro.escape(functions))

      unquote(meta_func)

      @doc false
      def __bash_call__(name, _args, _stdin, _state) do
        {:exit, 127, stderr: "#{@namespace}.#{name}: function not found\n"}
      end
    end
  end

  @doc ~S"""
  Define a bash-callable function.

  The function receives two arguments:

    * `args` - List of string arguments from bash
    * `state` - The current session state

  Inside the function body, you can use:

    * `Bash.puts/1`, `Bash.puts/2` - Write output
    * `Bash.stream(:stdin)` - Read stdin as a Stream
    * `Bash.get_state/0`, `Bash.put_state/1` - Access state

  ## Return Values

    * `:ok` - Exit 0 (output goes to stdout via `Bash.puts`)
    * `{:ok, exit_code}` - Exit with code
    * `{:ok, exit_code, new_state}` - Exit with code, update session state
    * `{:error, message}` - Exit 1, message written to stderr
    * `:continue` - Continue to next loop iteration (only valid in loops)
    * `:break` - Break out of loop (only valid in loops)

  ## Examples

      defbash greet(args, _state) do
        case args do
          [name | _] ->
            Bash.puts("Hello #{name}!\n")
            :ok

          [] ->
            {:error, "usage: myapp.greet NAME"}
        end
      end

      defbash upcase(_args, _state) do
        Bash.stream(:stdin)
        |> Stream.flat_map(&String.split(&1, "\n", trim: true))
        |> Stream.each(fn line ->
          Bash.puts(String.upcase(line) <> "\n")
        end)
        |> Stream.run()

        :ok
      end
  """
  defmacro defbash({name, _meta, [args_var, state_var]}, do: body) do
    name_str = Atom.to_string(name)

    quote do
      @bash_functions [unquote(name_str) | @bash_functions]
      @bash_function_meta (case @bash_on_define do
                             nil ->
                               @bash_function_meta

                             callback when is_function(callback, 2) ->
                               result =
                                 try do
                                   callback.(unquote(name_str), __MODULE__)
                                 rescue
                                   e ->
                                     reraise ArgumentError,
                                             "on_define callback for #{unquote(name_str)} raised: #{Exception.message(e)}",
                                             __STACKTRACE__
                                 end

                               case result do
                                 nil ->
                                   @bash_function_meta

                                 meta when is_map(meta) ->
                                   Map.put(@bash_function_meta, unquote(name_str), meta)

                                 other ->
                                   raise ArgumentError,
                                         "on_define callback must return a map or nil, got: #{inspect(other)}"
                               end
                           end)

      @doc false
      def __bash_call__(unquote(name_str), unquote(args_var), stdin, bash_interop_state__) do
        unquote(state_var) = bash_interop_state__

        Bash.Interop.execute_with_context(stdin, bash_interop_state__, fn ->
          unquote(body)
        end)
      end
    end
  end

  @doc false
  def execute_with_context(stdin, state, body_fn) do
    Bash.Interop.IO.init_context(stdin, state)

    try do
      result = body_fn.()
      {stdout, stderr, final_state} = Bash.Interop.IO.finalize_context()
      normalize_result(result, stdout, stderr, final_state)
    rescue
      e ->
        Process.delete(:bash_interop_context)
        reraise e, __STACKTRACE__
    end
  end

  @doc false
  def normalize_result(result, stdout, stderr, _final_state) do
    case result do
      :ok ->
        {:ok, 0, stdout: stdout}

      {:ok, message} when is_binary(message) ->
        {:ok, 0, stdout: stdout}

      {:ok, exit_code} when is_integer(exit_code) ->
        {:ok, exit_code, stdout: stdout, stderr: stderr}

      {:ok, exit_code, new_state} when is_integer(exit_code) ->
        {:ok, exit_code, stdout: stdout, stderr: stderr, state: new_state}

      {:error, msg} ->
        {:error, stderr <> to_string(msg)}

      :continue ->
        :continue

      :break ->
        :break

      other ->
        raise ArgumentError,
              "defbash function must return :ok, {:ok, exit_code, state}, {:error, message}, " <>
                ":continue, or :break. Got: #{inspect(other)}"
    end
  end
end
