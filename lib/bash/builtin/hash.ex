defmodule Bash.Builtin.Hash do
  @moduledoc """
  `hash [-lr] [-p pathname] [-dt] [name ...]`

  Remember or display program locations.

  For each NAME, the full pathname of the command is determined and remembered.
  If the -p option is supplied, PATHNAME is used as the full pathname of NAME,
  and no path search is done.  The -r option causes the shell to forget all
  remembered locations.  The -d option causes the shell to forget the remembered
  location of each NAME.  If the -t option is supplied the full pathname to which
  each NAME corresponds is printed.  If multiple NAME arguments are supplied with
  -t, the NAME is printed before the hashed full pathname.  The -l option causes
  output to be displayed in a format that may be reused as input.  If no arguments
  are given, information about remembered commands is displayed.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-hash
  """
  use Bash.Builtin

  alias Bash.Variable

  defbash execute(args, state) do
    {opts, names} = parse_args(args)

    cond do
      opts.clear_all ->
        # hash -r: Clear all remembered locations
        clear_hash_table()

      opts.delete && not Enum.empty?(names) ->
        # hash -d name: Remove specific names from hash table
        delete_from_hash(names, state)

      opts.print_path && not Enum.empty?(names) ->
        # hash -t name: Print path for specific names
        print_paths(names, state)

      opts.pathname && not Enum.empty?(names) ->
        # hash -p pathname name: Associate pathname with name
        add_pathname(opts.pathname, names)

      not Enum.empty?(names) ->
        # hash name: Look up names in PATH and remember
        lookup_and_hash(names, state)

      true ->
        # hash (no args): List all remembered commands
        list_hash_table(state, opts)
    end
  end

  defp parse_args(args) do
    parse_args(
      args,
      %{
        clear_all: false,
        delete: false,
        print_path: false,
        list_format: false,
        pathname: nil
      },
      []
    )
  end

  defp parse_args([], opts, names) do
    {opts, Enum.reverse(names)}
  end

  defp parse_args(["-r" | rest], opts, names) do
    parse_args(rest, %{opts | clear_all: true}, names)
  end

  defp parse_args(["-d" | rest], opts, names) do
    parse_args(rest, %{opts | delete: true}, names)
  end

  defp parse_args(["-t" | rest], opts, names) do
    parse_args(rest, %{opts | print_path: true}, names)
  end

  defp parse_args(["-l" | rest], opts, names) do
    parse_args(rest, %{opts | list_format: true}, names)
  end

  defp parse_args(["-p", pathname | rest], opts, names) do
    parse_args(rest, %{opts | pathname: pathname}, names)
  end

  defp parse_args(["-" <> flags | rest], opts, names) when byte_size(flags) > 0 do
    # Handle combined flags like -lr, -dt
    new_opts = process_flags(String.graphemes(flags), opts)
    parse_args(rest, new_opts, names)
  end

  defp parse_args([name | rest], opts, names) do
    parse_args(rest, opts, [name | names])
  end

  defp process_flags([], opts), do: opts

  defp process_flags(["r" | rest], opts) do
    process_flags(rest, %{opts | clear_all: true})
  end

  defp process_flags(["d" | rest], opts) do
    process_flags(rest, %{opts | delete: true})
  end

  defp process_flags(["t" | rest], opts) do
    process_flags(rest, %{opts | print_path: true})
  end

  defp process_flags(["l" | rest], opts) do
    process_flags(rest, %{opts | list_format: true})
  end

  defp process_flags([_ | rest], opts) do
    # Skip unknown flags
    process_flags(rest, opts)
  end

  defp clear_hash_table do
    update_state(hash_updates: :clear)
    :ok
  end

  defp delete_from_hash(names, session_state) do
    {updates, exit_code} =
      Enum.reduce(names, {%{}, 0}, fn name, {updates, code} ->
        if Map.has_key?(session_state.hash, name) do
          {Map.put(updates, name, :delete), code}
        else
          error("hash: #{name}: not found")
          {updates, 1}
        end
      end)

    if map_size(updates) > 0 do
      update_state(hash_updates: updates)
    end

    {:ok, exit_code}
  end

  defp print_paths(names, session_state) do
    exit_code =
      Enum.reduce(names, 0, fn name, code ->
        case Map.get(session_state.hash, name) do
          nil ->
            # Not in hash table - try to find in PATH
            case find_in_path(name, session_state) do
              nil ->
                error("hash: #{name}: not found")
                1

              path ->
                if length(names) > 1 do
                  puts("#{name}\t#{path}")
                else
                  puts(path)
                end

                code
            end

          {_hits, path} ->
            if length(names) > 1 do
              puts("#{name}\t#{path}")
            else
              puts(path)
            end

            code
        end
      end)

    {:ok, exit_code}
  end

  defp add_pathname(pathname, names) do
    # hash -p pathname name: Associate pathname with first name
    name = List.first(names)

    if name do
      update_state(hash_updates: %{name => {0, pathname}})
      :ok
    else
      error("hash: usage: hash [-lr] [-p pathname] [-dt] [name ...]")
      {:ok, 1}
    end
  end

  defp lookup_and_hash(names, session_state) do
    {updates, exit_code} =
      Enum.reduce(names, {%{}, 0}, fn name, {updates, code} ->
        case find_in_path(name, session_state) do
          nil ->
            error("hash: #{name}: not found")
            {updates, 1}

          path ->
            # Store with hit count of 0 initially
            {Map.put(updates, name, {0, path}), code}
        end
      end)

    if map_size(updates) > 0 do
      update_state(hash_updates: updates)
    end

    {:ok, exit_code}
  end

  defp list_hash_table(session_state, opts) do
    if map_size(session_state.hash) == 0 do
      error("hash: hash table empty")
      :ok
    else
      if not opts.list_format do
        puts("hits\tcommand")
      end

      session_state.hash
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {name, {hits, path}} ->
        if opts.list_format do
          # -l format: builtin hash -p /path/to/cmd name
          puts("builtin hash -p #{path} #{name}")
        else
          # Default format: hits\tcommand
          puts("#{hits}\t#{path}")
        end
      end)

      :ok
    end
  end

  defp find_in_path(name, session_state) do
    if String.contains?(name, "/") do
      # Contains slash - treat as path
      if File.exists?(name) and not File.dir?(name), do: name, else: nil
    else
      path_var = Map.get(session_state.variables, "PATH", Variable.new("/usr/bin:/bin"))
      path_dirs = path_var |> Variable.get(nil) |> String.split(":")

      Enum.find_value(path_dirs, fn dir ->
        full_path = Path.join(dir, name)

        if File.exists?(full_path) and not File.dir?(full_path) do
          full_path
        end
      end)
    end
  end
end
