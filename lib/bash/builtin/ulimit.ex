defmodule Bash.Builtin.Ulimit do
  @moduledoc """
  `ulimit [-SHacdfilmnpqstuvx] [limit]`

  Ulimit provides control over the resources available to processes started by the shell,
  on systems that allow such control. If an option is given, it is interpreted as follows:

  - `-S` - use the `soft' resource limit
  - `-H` - use the `hard' resource limit
  - `-a` - all current limits are reported
  - `-c` - the maximum size of core files created
  - `-d` - the maximum size of a process's data segment
  - `-e` - the maximum scheduling priority (`nice`)
  - `-f` - the maximum size of files written by the shell and its children
  - `-i` - the maximum number of pending signals
  - `-l` - the maximum size a process may lock into memory
  - `-m` - the maximum resident set size
  - `-n` - the maximum number of open file descriptors
  - `-p` - the pipe buffer size
  - `-q` - the maximum number of bytes in POSIX message queues
  - `-r` - the maximum real-time scheduling priority
  - `-s` - the maximum stack size
  - `-t` - the maximum amount of cpu time in seconds
  - `-u` - the maximum number of user processes
  - `-v` - the size of virtual memory
  - `-x` - the maximum number of file locks

  If LIMIT is given, it is the new value of the specified resource; the special LIMIT values
  `soft`, `hard`, and `unlimited` stand for the current soft limit, the current hard limit,
  and no limit, respectively. Otherwise, the current value of the specified resource is printed.
  If no option is given, then -f is assumed. Values are in 1024-byte increments, except for -t,
  which is in seconds, -p, which is in increments of 512 bytes, and -u, which is an unscaled
  number of processes.

  Note: Since the Erlang VM manages its own resources, setting limits is a no-op (values are
  stored but not enforced). Getting limits returns system values where available.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/ulimit.def?h=bash-5.3
  """
  use Bash.Builtin

  # Resource definitions: {flag, name, description, unit}
  @resources %{
    "c" => {:core_size, "core file size", "(blocks, -c)"},
    "d" => {:data_size, "data seg size", "(kbytes, -d)"},
    "e" => {:nice, "scheduling priority", "(-e)"},
    "f" => {:file_size, "file size", "(blocks, -f)"},
    "i" => {:pending_signals, "pending signals", "(-i)"},
    "l" => {:locked_memory, "max locked memory", "(kbytes, -l)"},
    "m" => {:resident_size, "max memory size", "(kbytes, -m)"},
    "n" => {:open_files, "open files", "(-n)"},
    "p" => {:pipe_size, "pipe size", "(512 bytes, -p)"},
    "q" => {:message_queues, "POSIX message queues", "(bytes, -q)"},
    "r" => {:realtime_priority, "real-time priority", "(-r)"},
    "s" => {:stack_size, "stack size", "(kbytes, -s)"},
    "t" => {:cpu_time, "cpu time", "(seconds, -t)"},
    "u" => {:processes, "max user processes", "(-u)"},
    "v" => {:virtual_memory, "virtual memory", "(kbytes, -v)"},
    "x" => {:file_locks, "file locks", "(-x)"}
  }

  # Order for -a output
  @resource_order ~w[c d e f i l m n p q r s t u v x]

  defbash execute(args, state) do
    {flags, limit_value} = parse_args(args)

    cond do
      # Check for invalid option first
      flags.invalid_option != nil ->
        error("ulimit: -#{flags.invalid_option}: invalid option")
        {:ok, 1}

      # Show all limits
      flags.show_all ->
        show_all_limits(state, flags)

      # No resource flag specified, default to -f
      flags.resource == nil and limit_value == nil ->
        show_limit("f", state, flags)

      # Set a limit value
      limit_value != nil ->
        resource = flags.resource || "f"
        set_limit(resource, limit_value, state, flags)

      # Show a specific limit
      true ->
        show_limit(flags.resource, state, flags)
    end
  end

  # Parse command arguments
  defp parse_args(args) do
    initial_flags = %{
      soft: false,
      hard: false,
      show_all: false,
      resource: nil,
      invalid_option: nil
    }

    {flags, remaining} =
      Enum.reduce(args, {initial_flags, []}, fn arg, {flags, rest} ->
        cond do
          # Already found an invalid option, skip processing
          flags.invalid_option != nil ->
            {flags, rest}

          arg == "-S" ->
            {%{flags | soft: true}, rest}

          arg == "-H" ->
            {%{flags | hard: true}, rest}

          arg == "-a" ->
            {%{flags | show_all: true}, rest}

          String.starts_with?(arg, "-") and String.length(arg) == 2 ->
            flag = String.at(arg, 1)

            cond do
              flag in ["S", "H", "a"] ->
                # Already handled above, but in case
                {flags, rest}

              Map.has_key?(@resources, flag) ->
                {%{flags | resource: flag}, rest}

              true ->
                # Unknown flag
                {%{flags | invalid_option: flag}, rest}
            end

          # Handle combined flags like -Sn or -Hn
          String.starts_with?(arg, "-") and String.length(arg) > 2 ->
            parse_combined_flags(arg, flags, rest)

          true ->
            {flags, rest ++ [arg]}
        end
      end)

    limit_value = List.first(remaining)
    {flags, limit_value}
  end

  defp parse_combined_flags(arg, flags, rest) do
    chars = String.graphemes(String.slice(arg, 1..-1//1))

    Enum.reduce_while(chars, {flags, rest}, fn char, {f, r} ->
      cond do
        char == "S" -> {:cont, {%{f | soft: true}, r}}
        char == "H" -> {:cont, {%{f | hard: true}, r}}
        char == "a" -> {:cont, {%{f | show_all: true}, r}}
        Map.has_key?(@resources, char) -> {:cont, {%{f | resource: char}, r}}
        true -> {:halt, {%{f | invalid_option: char}, r}}
      end
    end)
  end

  # Show all limits
  defp show_all_limits(session_state, flags) do
    limits = get_limits(session_state)

    lines =
      @resource_order
      |> Enum.map(fn flag ->
        {resource_atom, name, unit} = Map.fetch!(@resources, flag)
        value = get_limit_value(resource_atom, limits, flags)
        format_limit_line(name, unit, value)
      end)
      |> Enum.join("\n")

    Bash.Builtin.Context.write(lines <> "\n")
    :ok
  end

  # Show a specific limit
  defp show_limit(flag, session_state, flags) do
    case Map.get(@resources, flag) do
      nil ->
        Bash.Builtin.Context.error("ulimit: -#{flag}: invalid option")
        {:ok, 1}

      {resource_atom, _name, _unit} ->
        limits = get_limits(session_state)
        value = get_limit_value(resource_atom, limits, flags)
        Bash.Builtin.Context.write("#{value}\n")
        :ok
    end
  end

  # Set a limit value
  defp set_limit(flag, value_str, session_state, flags) do
    case Map.get(@resources, flag) do
      nil ->
        Bash.Builtin.Context.error("ulimit: -#{flag}: invalid option")
        {:ok, 1}

      {resource_atom, _name, _unit} ->
        case parse_limit_value(value_str, resource_atom, session_state) do
          {:ok, value} ->
            # Store the limit in session state
            limits = get_limits(session_state)
            limit_type = get_limit_type(flags)

            new_limits =
              case Map.get(limits, resource_atom) do
                nil ->
                  Map.put(limits, resource_atom, %{limit_type => value})

                existing when is_map(existing) ->
                  Map.put(limits, resource_atom, Map.put(existing, limit_type, value))
              end

            Bash.Builtin.Context.update_state(ulimits: new_limits)
            :ok

          {:error, msg} ->
            Bash.Builtin.Context.error("ulimit: #{msg}")
            {:ok, 1}
        end
    end
  end

  # Parse limit value from string
  defp parse_limit_value("unlimited", _resource, _state), do: {:ok, :unlimited}

  defp parse_limit_value("soft", resource, state) do
    limits = get_limits(state)
    {:ok, get_limit_value(resource, limits, %{soft: true, hard: false})}
  end

  defp parse_limit_value("hard", resource, state) do
    limits = get_limits(state)
    {:ok, get_limit_value(resource, limits, %{soft: false, hard: true})}
  end

  defp parse_limit_value(value_str, _resource, _state) do
    case Integer.parse(value_str) do
      {value, ""} when value >= 0 ->
        {:ok, value}

      _ ->
        {:error, "#{value_str}: invalid limit value"}
    end
  end

  # Get the limit type to set/get
  defp get_limit_type(%{hard: true}), do: :hard
  defp get_limit_type(%{soft: true}), do: :soft
  defp get_limit_type(_), do: :soft

  # Get limits from session state
  defp get_limits(session_state) do
    Map.get(session_state, :ulimits, get_default_limits())
  end

  # Get default limits (using system values where available)
  defp get_default_limits do
    %{
      core_size: %{soft: 0, hard: :unlimited},
      data_size: %{soft: :unlimited, hard: :unlimited},
      nice: %{soft: 0, hard: 0},
      file_size: %{soft: :unlimited, hard: :unlimited},
      pending_signals: %{
        soft: get_system_limit(:pending_signals),
        hard: get_system_limit(:pending_signals)
      },
      locked_memory: %{soft: 64, hard: 64},
      resident_size: %{soft: :unlimited, hard: :unlimited},
      open_files: %{soft: get_system_limit(:open_files), hard: get_system_limit(:open_files)},
      pipe_size: %{soft: 8, hard: 8},
      message_queues: %{soft: 819_200, hard: 819_200},
      realtime_priority: %{soft: 0, hard: 0},
      stack_size: %{soft: 8192, hard: :unlimited},
      cpu_time: %{soft: :unlimited, hard: :unlimited},
      processes: %{soft: get_system_limit(:processes), hard: get_system_limit(:processes)},
      virtual_memory: %{soft: :unlimited, hard: :unlimited},
      file_locks: %{soft: :unlimited, hard: :unlimited}
    }
  end

  # Get a specific limit value
  defp get_limit_value(resource_atom, limits, flags) do
    case Map.get(limits, resource_atom) do
      nil ->
        :unlimited

      limit_map when is_map(limit_map) ->
        type = get_limit_type(flags)
        Map.get(limit_map, type, :unlimited)

      value ->
        value
    end
  end

  defp get_system_limit(:open_files) do
    try do
      :erlang.system_info(:check_io) |> Keyword.get(:max_fds, 1024)
    rescue
      _ -> 1024
    end
  end

  defp get_system_limit(:processes) do
    try do
      :erlang.system_info(:process_limit)
    rescue
      _ -> 262_144
    end
  end

  defp get_system_limit(:pending_signals) do
    15649
  end

  # Format a limit line for -a output
  defp format_limit_line(name, unit, value) do
    value_str = format_value(value)
    padded_name = String.pad_trailing(name, 25)
    "#{padded_name} #{unit} #{value_str}"
  end

  defp format_value(:unlimited), do: "unlimited"
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value), do: to_string(value)
end
