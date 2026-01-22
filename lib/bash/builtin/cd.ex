defmodule Bash.Builtin.Cd do
  @moduledoc """
  `cd [-L|-P] [dir]`

  Change the current directory to DIR.  The variable $HOME is the default DIR.  The variable CDPATH defines the search path for the directory containing DIR.  Alternative directory names in CDPATH are separated by a colon (:).  A null directory name is the same as the current directory, i.e. `.`.  If DIR begins with a slash (/), then CDPATH is not used.  If the directory is not found, and the shell option `cdable_vars` is set, then try the word as a variable name.  If that variable has a value, then cd to the value of that variable.  The -P option says to use the physical directory structure instead of following symbolic links; the -L option forces symbolic links to be followed.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/cd.def?h=bash-5.3

  Supports:
  - `cd` - Change to HOME directory
  - `cd -` - Change to OLDPWD (previous directory) and print it
  - `cd <dir>` - Change to specified directory
  - `-L` - Follow symbolic links (default unless `set -P` is active)
  - `-P` - Use physical directory structure (resolve symlinks)
  - CDPATH - Search path for directories
  - Tilde expansion (`~`, `~/path`)

  Updates environment variables:
  - PWD - Current working directory
  - OLDPWD - Previous working directory
  """
  use Bash.Builtin

  alias Bash.Variable

  defbash execute(args, state) do
    # Get default physical mode from session options (set by `set -P`)
    # Use Map.get instead of get_in because Session struct doesn't implement Access
    session_physical = (Map.get(state, :options) || %{})[:physical] || false
    {flags, paths} = parse_args(args, session_physical)

    case paths do
      # Too many arguments - return error early
      [_, _ | _] ->
        return_error("cd: too many arguments")

      # Empty string - null directory error
      [""] ->
        return_error("cd: null directory")

      # No args: go to HOME
      [] ->
        case get_var(state, "HOME") do
          nil -> return_error("cd: HOME not set")
          home -> change_directory(home, flags, state, false)
        end

      # cd -: go to OLDPWD
      ["-"] ->
        case get_var(state, "OLDPWD") do
          nil -> return_error("cd: OLDPWD not set")
          oldpwd -> change_directory(oldpwd, flags, state, true)
        end

      # cd <path>
      [path] ->
        change_directory(path, flags, state, false)
    end
  end

  # Parse flags and arguments
  # session_physical is the default physical mode from session options (set -P)
  defp parse_args(args, session_physical) do
    default_flags = %{
      logical: not session_physical,
      physical: session_physical,
      print_on_error: false
    }

    parse_args(args, default_flags, [])
  end

  defp parse_args([], flags, acc) do
    {flags, Enum.reverse(acc)}
  end

  defp parse_args(["-L" | rest], flags, acc) do
    parse_args(rest, %{flags | logical: true, physical: false}, acc)
  end

  defp parse_args(["-P" | rest], flags, acc) do
    parse_args(rest, %{flags | logical: false, physical: true}, acc)
  end

  defp parse_args(["-e" | rest], flags, acc) do
    parse_args(rest, %{flags | print_on_error: true}, acc)
  end

  defp parse_args([arg | rest], flags, acc) do
    {flags, Enum.reverse(acc, [arg | rest])}
  end

  # Change to the target directory
  defp change_directory(target, flags, session_state, print_new_dir?) do
    # Expand tilde
    expanded_target = expand_tilde(target, session_state)

    # Resolve the path
    resolved_path = resolve_path(expanded_target, session_state, flags)

    # Check if it's a directory and exists
    case validate_directory(resolved_path, flags) do
      :ok ->
        # Success - prepare state updates
        old_pwd = session_state.working_dir

        new_pwd =
          if flags.physical do
            # Resolve all symlinks for physical path
            case resolve_symlinks(Path.expand(resolved_path)) do
              {:ok, real_path} -> real_path
              {:error, _} -> Path.expand(resolved_path)
            end
          else
            # Logical path - just expand
            Path.expand(resolved_path)
          end

        # Print new directory if cd -
        if print_new_dir? do
          puts(new_pwd)
        end

        # Update state
        update_state(
          working_dir: new_pwd,
          env_updates: %{
            "PWD" => new_pwd,
            "OLDPWD" => old_pwd
          }
        )

        :ok

      {:error, reason} ->
        return_error("cd: #{target}: #{reason}")
    end
  end

  # Resolve path based on flags and current state
  defp resolve_path(path, session_state, _flags) do
    if String.starts_with?(path, "/") do
      path
    else
      candidate = Path.join(session_state.working_dir, path)

      if File.dir?(candidate) do
        candidate
      else
        # Try CDPATH if not starting with . or /
        if not String.starts_with?(path, ".") and not String.starts_with?(path, "/") do
          search_cdpath(path, session_state)
        else
          candidate
        end
      end
    end
  end

  # Search CDPATH for the directory
  defp search_cdpath(dir, session_state) do
    cdpath = get_var(session_state, "CDPATH")

    if cdpath in ["", nil] do
      # No CDPATH, use relative to current dir
      Path.join(session_state.working_dir, dir)
    else
      # Split CDPATH and search
      paths = String.split(cdpath, ":", trim: false)

      Enum.find_value(paths, Path.join(session_state.working_dir, dir), fn search_path ->
        search_path = if search_path == "", do: ".", else: search_path
        candidate = Path.join(search_path, dir)

        if File.dir?(candidate) do
          candidate
        end
      end)
    end
  end

  # Expand tilde in path
  defp expand_tilde("~", session_state) do
    get_var(session_state, "HOME", "~")
  end

  defp expand_tilde("~/" <> path, session_state) do
    home = get_var(session_state, "HOME", "~")
    Path.join(home, path)
  end

  defp expand_tilde("~" <> username, _session_state) do
    # ~username - would need getpwnam, not implemented
    "~" <> username
  end

  defp expand_tilde(path, _session_state), do: path

  # Validate that the path is a directory
  defp validate_directory(path, _flags) do
    cond do
      not File.exists?(path) ->
        {:error, "No such file or directory"}

      not File.dir?(path) ->
        {:error, "Not a directory"}

      true ->
        :ok
    end
  end

  # Resolve symlinks in a path (for -P flag)
  defp resolve_symlinks(path) do
    case :file.read_link_all(to_charlist(path)) do
      {:ok, real_path} -> {:ok, List.to_string(real_path)}
      {:error, :einval} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  # Return error result
  defp return_error(message) do
    error(message)
    {:ok, 1}
  end

  # Helper to get variable value as string
  defp get_var(session_state, name, default \\ nil) do
    case Map.get(session_state.variables, name) do
      nil -> default
      %Variable{} = var -> Variable.get(var, nil) || default
    end
  end
end
