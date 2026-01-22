defmodule Bash.Builtin.Pwd do
  @moduledoc """
  `pwd [-LP]`

  Print the current working directory.  With the -P option, pwd prints the physical directory, without any symbolic links; the -L option makes pwd follow symbolic links.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/cd.def?h=bash-5.3
  """
  use Bash.Builtin

  defbash execute(args, state) do
    # Get default physical mode from session options (set by `set -P`)
    options = Map.get(state, :options) || %{}
    session_physical = Map.get(options, :physical, false)
    flags = parse_args(args, session_physical)

    output =
      if flags.physical do
        # Physical mode: resolve symlinks to get real path
        resolve_physical_path(state.working_dir)
      else
        # Logical mode: return working_dir as-is
        state.working_dir
      end

    puts(output)
    :ok
  end

  # Parse flags and arguments
  # session_physical is the default physical mode from session options (set -P)
  defp parse_args(args, session_physical) do
    default_flags = %{
      logical: not session_physical,
      physical: session_physical
    }

    parse_flags(args, default_flags)
  end

  defp parse_flags([], flags), do: flags

  defp parse_flags(["-L" | rest], flags) do
    parse_flags(rest, %{flags | logical: true, physical: false})
  end

  defp parse_flags(["-P" | rest], flags) do
    parse_flags(rest, %{flags | logical: false, physical: true})
  end

  defp parse_flags(["-LP" | rest], flags) do
    # Last flag wins, so -LP means -P
    parse_flags(rest, %{flags | logical: false, physical: true})
  end

  defp parse_flags(["-PL" | rest], flags) do
    # Last flag wins, so -PL means -L
    parse_flags(rest, %{flags | logical: true, physical: false})
  end

  defp parse_flags([_arg | rest], flags) do
    # Ignore unknown arguments
    parse_flags(rest, flags)
  end

  # Resolve symlinks in a path to get the physical path (for -P flag)
  # This resolves the path component by component, following symlinks
  defp resolve_physical_path(path) do
    try do
      expanded = Path.expand(path)
      resolve_path_components(String.split(expanded, "/", trim: true), "/")
    rescue
      _ -> path
    end
  end

  # Resolve path component by component, following any symlinks
  defp resolve_path_components([], acc), do: acc

  defp resolve_path_components([component | rest], acc) do
    current = Path.join(acc, component)

    case :file.read_link(to_charlist(current)) do
      {:ok, target} ->
        # It's a symlink - follow it
        target_str = List.to_string(target)

        resolved =
          if String.starts_with?(target_str, "/") do
            target_str
          else
            Path.join(acc, target_str) |> Path.expand()
          end

        resolve_path_components(rest, resolved)

      {:error, _} ->
        # Not a symlink, continue
        resolve_path_components(rest, current)
    end
  end
end
