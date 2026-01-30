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

      {:ok, session} = Bash.Session.new()
      Bash.Session.load_api(session, MyApp.BashAPI)

  Then callable from Bash as `myapp.greet "World"`.

  ## I/O Functions

  Inside `defbash` functions, use the `Bash` module for I/O:

    * `Bash.puts(message)` - Write raw data to stdout (no newline added)
    * `Bash.puts(:stderr, message)` - Write raw data to stderr (no newline added)
    * `Bash.stream(:stdin)` - Get stdin as a lazy `Stream`
    * `Bash.stream(:stdout, enumerable)` - Stream each element to stdout
    * `Bash.stream(:stderr, enumerable)` - Stream each element to stderr
    * `Bash.get_state()` - Get the current session state map
    * `Bash.update_state(updates)` - Accumulate state update deltas

  ## Return Values

  `defbash` functions must return one of:

  ### Success

    * `:ok` - Exit code 0, no additional output
    * `{:ok, message}` - Exit code 0, `message` (binary) written to stdout
    * `{:ok, stream}` - Exit code 0, lazy stream consumed to stdout
    * `{:ok, exit_code}` - Exit with `exit_code` (integer), no additional output

  ### Error

    * `{:error, exit_code}` - Exit with `exit_code` (integer), no output
    * `{:error, message}` - Exit code 1, `message` (binary) written to stderr
    * `{:error, stream}` - Exit code 1, lazy stream consumed to stderr

  ### Loop Control

  Only valid when the function is called inside a `for`, `while`, or `until` loop:

    * `:continue` - Skip to the next loop iteration
    * `:break` - Break out of the enclosing loop

  ## State Updates

  Use `Bash.update_state/1` to request changes to session state. Updates are
  accumulated as deltas and applied after execution completes. Common keys:

    * `:variables` - Map of variable name to string or `Bash.Variable` (merged, strings auto-wrapped as exported)
    * `:working_dir` - New working directory (replaced)
    * `:options` - Shell options map (merged)

  ## Examples

  ### Simple output

      defbash hello(_args, _state) do
        Bash.puts("hello world\n")
        :ok
      end

  ### Return-based output

      defbash version(_args, _state) do
        {:ok, "1.0.0\n"}
      end

  ### Error handling

      defbash divide(args, _state) do
        case args do
          [a, b] ->
            b = String.to_integer(b)

            if b == 0 do
              {:error, "divide: division by zero\n"}
            else
              {:ok, "#{div(String.to_integer(a), b)}\n"}
            end

          _ ->
            {:error, "usage: math.divide A B\n"}
        end
      end

  ### Streaming stdin

      defbash upcase(_args, _state) do
        Bash.stream(:stdin)
        |> Stream.each(fn chunk ->
          Bash.puts(String.upcase(chunk))
        end)
        |> Stream.run()

        :ok
      end

  ### Streaming output

      defbash count(_args, _state) do
        {:ok, Stream.map(1..5, &"#{&1}\n")}
      end

  ### Custom exit code

      defbash check(args, _state) do
        if File.exists?(List.first(args, "")) do
          :ok
        else
          {:ok, 1}
        end
      end

  ### State updates

      defbash set_var(args, _state) do
        case args do
          [name, value] ->
            Bash.update_state(%{variables: %{name => Bash.Variable.new(value)}})
            :ok

          _ ->
            {:error, "usage: myapp.set_var NAME VALUE\n"}
        end
      end

  ### Loop control

      # In a bash loop: for i in 1 2 3; do myapp.skip_even "$i"; done
      defbash skip_even(args, _state) do
        n = args |> List.first() |> String.to_integer()

        if rem(n, 2) == 0 do
          :continue
        else
          Bash.puts("#{n}\n")
          :ok
        end
      end
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

    * `args` - List of string arguments passed from bash
    * `state` - The current session state map

  ## I/O

  Inside the function body, use the `Bash` module for I/O:

    * `Bash.puts(message)` - Write raw data to stdout
    * `Bash.puts(:stderr, message)` - Write raw data to stderr
    * `Bash.stream(:stdin)` - Get stdin as a lazy `Stream`
    * `Bash.stream(:stdout, enumerable)` - Stream each element to stdout
    * `Bash.stream(:stderr, enumerable)` - Stream each element to stderr
    * `Bash.get_state()` - Get current session state
    * `Bash.update_state(updates)` - Accumulate state update deltas

  ## Return Values

  ### Success

    * `:ok` - Exit code 0, no additional output
    * `{:ok, binary}` - Exit code 0, binary written to stdout
    * `{:ok, stream}` - Exit code 0, lazy stream consumed to stdout
    * `{:ok, exit_code}` - Exit with integer code, no additional output

  ### Error

    * `{:error, exit_code}` - Exit with integer code, no output
    * `{:error, binary}` - Exit code 1, binary written to stderr
    * `{:error, stream}` - Exit code 1, lazy stream consumed to stderr

  ### Loop Control

    * `:continue` - Skip to next loop iteration (only valid inside loops)
    * `:break` - Break out of enclosing loop (only valid inside loops)

  ## Examples

      defbash greet(args, _state) do
        case args do
          [name | _] ->
            Bash.puts("Hello #{name}!\n")
            :ok

          [] ->
            {:error, "usage: myapp.greet NAME\n"}
        end
      end

      defbash upcase(_args, _state) do
        Bash.stream(:stdin)
        |> Stream.each(fn chunk ->
          Bash.puts(String.upcase(chunk))
        end)
        |> Stream.run()

        :ok
      end

      defbash count(_args, _state) do
        {:ok, Stream.map(1..5, &"#{&1}\n")}
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
    state_with_stdin =
      if stdin != nil do
        Map.put(state, :stdin, stdin)
      else
        state
      end

    Bash.Context.init(state_with_stdin)

    try do
      result = body_fn.()
      state_updates = Bash.Context.get_state_updates()
      write_result_output(result, state_with_stdin)
      Bash.Context.delete_context()
      normalized = normalize_result(result)

      case state_updates do
        empty when empty == %{} -> normalized
        updates -> {normalized, updates}
      end
    rescue
      e ->
        Bash.Context.delete_context()
        reraise e, __STACKTRACE__
    end
  end

  defp write_result_output({:ok, message}, state) when is_binary(message) do
    Bash.Sink.write_stdout(state, message)
  end

  defp write_result_output({:ok, enumerable}, state) do
    if Enumerable.impl_for(enumerable) do
      Enum.each(enumerable, fn chunk ->
        Bash.Sink.write_stdout(state, to_string(chunk))
      end)
    end
  end

  defp write_result_output({:error, exit_code}, _state) when is_integer(exit_code), do: :ok

  defp write_result_output({:error, msg}, state) when is_binary(msg) do
    Bash.Sink.write_stderr(state, msg)
  end

  defp write_result_output({:error, enumerable}, state) do
    if Enumerable.impl_for(enumerable) do
      Enum.each(enumerable, fn chunk ->
        Bash.Sink.write_stderr(state, to_string(chunk))
      end)
    else
      Bash.Sink.write_stderr(state, to_string(enumerable))
    end
  end

  defp write_result_output(_, _), do: :ok

  @doc false
  def normalize_result(result) do
    case result do
      :ok ->
        {:ok, 0}

      {:ok, message} when is_binary(message) ->
        {:ok, 0}

      {:ok, exit_code} when is_integer(exit_code) ->
        {:ok, exit_code}

      {:ok, _enumerable} ->
        {:ok, 0}

      {:error, exit_code} when is_integer(exit_code) ->
        {:error, exit_code}

      {:error, msg} when is_binary(msg) ->
        {:error, msg}

      {:error, _enumerable} ->
        {:error, ""}

      :continue ->
        :continue

      :break ->
        :break

      other ->
        raise ArgumentError,
              "defbash function must return :ok, {:ok, value}, {:error, value}, " <>
                ":continue, or :break. Got: #{inspect(other)}"
    end
  end
end
