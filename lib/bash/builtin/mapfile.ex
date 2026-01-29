defmodule Bash.Builtin.Mapfile do
  @moduledoc """
  `mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]`

  Read lines from the standard input into the indexed array variable ARRAY, or
  from file descriptor FD if the -u option is supplied. The variable MAPFILE is
  the default ARRAY.

  Options:
    -d delim    Use DELIM to terminate lines, instead of newline. DELIM is a single character.
    -n count    Copy at most COUNT lines. If COUNT is 0, all lines are copied.
    -O origin   Begin assigning to ARRAY at index ORIGIN. The default index is 0.
    -s count    Discard the first COUNT lines read.
    -t          Remove a trailing DELIM from each line read (default newline).
    -u fd       Read lines from file descriptor FD instead of the standard input.
    -C callback Evaluate CALLBACK each time QUANTUM lines are read.
    -c quantum  Specify the number of lines read between each call to CALLBACK.

  If -C is specified without -c, the default quantum is 5000.
  When CALLBACK is evaluated, it is supplied the index of the next array
  element to be assigned and the line to be assigned to that element as
  additional arguments.

  If not supplied with an explicit origin, mapfile will clear ARRAY before
  assigning to it.

  mapfile returns successfully unless an invalid option or option argument is
  supplied, ARRAY is invalid or unassignable, or if ARRAY is not an indexed array.

  `readarray` is a synonym for `mapfile`.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/mapfile.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Variable

  @default_array "MAPFILE"

  # Execute the mapfile/readarray builtin.
  #
  # ## Arguments
  #
  # * `args` - Command arguments including flags and array name
  # * `stdin` - Input string to read lines from
  # * `session_state` - Current session state with variables
  #
  # ## Returns
  #
  # * `{:ok, result, state_updates}` - Success with array variable updates
  # * `{:error, result}` - Error occurred
  #
  # ## Examples
  #
  # # Read lines into MAPFILE (default)
  # iex> Mapfile.execute([], "line1\\nline2\\n", %{variables: %{}})
  # {:ok, %CommandResult{exit_code: 0}, %{var_updates: %{"MAPFILE" => %Variable{...}}}}
  #
  # # Read lines into named array with -t (strip newlines)
  # iex> Mapfile.execute(["-t", "myarray"], "line1\\nline2\\n", %{variables: %{}})
  # {:ok, %CommandResult{exit_code: 0}, %{var_updates: %{"myarray" => %Variable{...}}}}
  #
  @doc false
  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, opts, array_name} ->
        stdin_input =
          case Map.get(state, :stdin_device) do
            nil ->
              case read(:all) do
                {:ok, data} -> data
                :eof -> nil
                {:error, _} -> nil
              end

            device when is_pid(device) ->
              case IO.binread(device, :eof) do
                :eof -> nil
                {:error, _} -> nil
                data -> data
              end
          end

        do_mapfile(opts, array_name, stdin_input, state)

      {:error, msg} ->
        error("mapfile: #{msg}")
        {:ok, 1}
    end
  end

  # Parse command-line arguments
  defp parse_args(args) do
    default_opts = %{
      delimiter: "\n",
      count: 0,
      origin: nil,
      skip: 0,
      trim: false,
      fd: nil,
      callback: nil,
      quantum: nil
    }

    parse_args(args, default_opts, nil)
  end

  defp parse_args([], opts, array_name) do
    array = array_name || @default_array
    {:ok, opts, array}
  end

  # -d delim: use delim as line terminator
  defp parse_args(["-d", delim | rest], opts, array_name) do
    # Use first character of delim, or null byte for empty string
    delimiter = if delim == "", do: <<0>>, else: String.first(delim)
    parse_args(rest, %{opts | delimiter: delimiter}, array_name)
  end

  defp parse_args(["-d"], _opts, _array_name) do
    {:error, "-d: option requires an argument"}
  end

  # -n count: read at most count lines (0 = all)
  defp parse_args(["-n", count_str | rest], opts, array_name) do
    case Integer.parse(count_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, %{opts | count: n}, array_name)

      _ ->
        {:error, "#{count_str}: invalid line count"}
    end
  end

  defp parse_args(["-n"], _opts, _array_name) do
    {:error, "-n: option requires an argument"}
  end

  # -O origin: start at array index origin
  defp parse_args(["-O", origin_str | rest], opts, array_name) do
    case Integer.parse(origin_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, %{opts | origin: n}, array_name)

      _ ->
        {:error, "#{origin_str}: invalid array origin"}
    end
  end

  defp parse_args(["-O"], _opts, _array_name) do
    {:error, "-O: option requires an argument"}
  end

  # -s count: skip first count lines
  defp parse_args(["-s", count_str | rest], opts, array_name) do
    case Integer.parse(count_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, %{opts | skip: n}, array_name)

      _ ->
        {:error, "#{count_str}: invalid line count"}
    end
  end

  defp parse_args(["-s"], _opts, _array_name) do
    {:error, "-s: option requires an argument"}
  end

  # -t: remove trailing delimiter from each line
  defp parse_args(["-t" | rest], opts, array_name) do
    parse_args(rest, %{opts | trim: true}, array_name)
  end

  # -u fd: read from file descriptor
  defp parse_args(["-u", fd_str | rest], opts, array_name) do
    case Integer.parse(fd_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, %{opts | fd: n}, array_name)

      _ ->
        {:error, "#{fd_str}: invalid file descriptor"}
    end
  end

  defp parse_args(["-u"], _opts, _array_name) do
    {:error, "-u: option requires an argument"}
  end

  # -C callback: call callback for each quantum lines
  defp parse_args(["-C", callback | rest], opts, array_name) do
    parse_args(rest, %{opts | callback: callback}, array_name)
  end

  defp parse_args(["-C"], _opts, _array_name) do
    {:error, "-C: option requires an argument"}
  end

  # -c quantum: call callback every quantum lines
  defp parse_args(["-c", quantum_str | rest], opts, array_name) do
    case Integer.parse(quantum_str) do
      {n, ""} when n > 0 ->
        parse_args(rest, %{opts | quantum: n}, array_name)

      _ ->
        {:error, "#{quantum_str}: invalid callback quantum"}
    end
  end

  defp parse_args(["-c"], _opts, _array_name) do
    {:error, "-c: option requires an argument"}
  end

  # -- stops option processing
  defp parse_args(["--" | rest], opts, _array_name) do
    case rest do
      [] -> {:ok, opts, @default_array}
      [name] -> validate_array_name(name, opts)
      _ -> {:error, "too many arguments"}
    end
  end

  # Unknown option
  defp parse_args(["-" <> _ = opt | _rest], _opts, _array_name) do
    {:error, "#{opt}: invalid option"}
  end

  # Array name (positional argument)
  defp parse_args([name | rest], opts, _array_name) do
    case validate_array_name(name, opts) do
      {:ok, opts, name} ->
        if rest == [] do
          {:ok, opts, name}
        else
          {:error, "too many arguments"}
        end

      error ->
        error
    end
  end

  defp validate_array_name(name, opts) do
    if valid_var_name?(name) do
      {:ok, opts, name}
    else
      {:error, "`#{name}': not a valid identifier"}
    end
  end

  # Validate variable name
  defp valid_var_name?(name) when is_binary(name) do
    String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)
  end

  defp valid_var_name?(_), do: false

  # Main mapfile logic
  defp do_mapfile(opts, array_name, stdin_input, session_state) do
    # Resolve input from file descriptor
    case resolve_input(opts.fd, stdin_input, session_state) do
      {:ok, input} ->
        do_mapfile_from_input(opts, array_name, input, session_state)

      {:error, msg} ->
        error("mapfile: #{msg}")
        {:ok, 1}
    end
  end

  # Resolve input from file descriptor
  # fd nil or 0 = stdin (default)
  # fd 1/2 = stdout/stderr (not readable)
  # fd 3+ = look up in session_state.file_descriptors
  defp resolve_input(nil, stdin, _session_state), do: {:ok, stdin}
  defp resolve_input(0, stdin, _session_state), do: {:ok, stdin}

  defp resolve_input(fd, _stdin, _session_state) when fd in [1, 2] do
    {:error, "#{fd}: Bad file descriptor"}
  end

  defp resolve_input(fd, _stdin, session_state) do
    file_descriptors = Map.get(session_state, :file_descriptors, %{})

    case Map.get(file_descriptors, fd) do
      nil -> {:error, "#{fd}: Bad file descriptor"}
      content -> {:ok, content}
    end
  end

  # Mapfile from resolved input
  defp do_mapfile_from_input(opts, array_name, input, session_state) do
    # Check if input is empty
    if input == nil or input == "" do
      # No input - create empty array or preserve origin
      var_updates = build_empty_array(array_name, opts, session_state)
      update_state(var_updates: var_updates)
      :ok
    else
      # Check if existing variable is readonly
      existing = Map.get(session_state.variables, array_name)

      if existing && Variable.readonly?(existing) do
        error("mapfile: #{array_name}: readonly variable")
        {:ok, 1}
      else
        # Check if existing variable is associative array
        if existing && existing.attributes[:array_type] == :associative do
          error("mapfile: #{array_name}: not an indexed array")
          {:ok, 1}
        else
          # Read and process lines
          lines = split_lines(input, opts.delimiter)

          # Skip first N lines
          lines = Enum.drop(lines, opts.skip)

          # Take at most N lines (0 = all)
          lines =
            if opts.count > 0 do
              Enum.take(lines, opts.count)
            else
              lines
            end

          # Optionally trim delimiter from each line
          lines =
            if opts.trim do
              Enum.map(lines, &String.trim_trailing(&1, opts.delimiter))
            else
              lines
            end

          # Build array
          var_updates = build_array(array_name, lines, opts, session_state)
          update_state(var_updates: var_updates)
          :ok
        end
      end
    end
  end

  # Split input into lines by delimiter
  defp split_lines(input, delimiter) do
    # Split by delimiter but keep delimiter at end of each line (except possibly last)
    parts = String.split(input, delimiter)

    case parts do
      [] ->
        []

      [single] ->
        # No delimiter found - single line without delimiter
        if single == "" do
          []
        else
          [single]
        end

      multiple ->
        # Add delimiter back to all but last part
        {init, [last]} = Enum.split(multiple, -1)

        lines_with_delim = Enum.map(init, &(&1 <> delimiter))

        # Only include last if non-empty (it would be empty if input ended with delimiter)
        if last == "" do
          lines_with_delim
        else
          lines_with_delim ++ [last]
        end
    end
  end

  # Build empty array update
  defp build_empty_array(array_name, opts, session_state) do
    if opts.origin != nil do
      # -O specified: preserve existing array, just don't add anything
      existing = Map.get(session_state.variables, array_name)

      case existing do
        %Variable{attributes: %{array_type: :indexed}} ->
          # Keep existing array as-is
          %{}

        _ ->
          # Create new empty array
          %{array_name => Variable.new_indexed_array(%{})}
      end
    else
      # No origin: clear array
      %{array_name => Variable.new_indexed_array(%{})}
    end
  end

  # Build array from lines
  defp build_array(array_name, lines, opts, session_state) do
    origin = opts.origin || 0

    # Get base array if origin specified
    base_map =
      if opts.origin != nil do
        existing = Map.get(session_state.variables, array_name)

        case existing do
          %Variable{attributes: %{array_type: :indexed}, value: map} when is_map(map) ->
            map

          _ ->
            %{}
        end
      else
        # No origin: start fresh
        %{}
      end

    # Build array map from lines
    array_map =
      lines
      |> Enum.with_index(origin)
      |> Enum.reduce(base_map, fn {line, idx}, acc ->
        Map.put(acc, idx, line)
      end)

    %{array_name => Variable.new_indexed_array(array_map)}
  end
end
