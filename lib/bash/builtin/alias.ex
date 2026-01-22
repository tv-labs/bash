defmodule Bash.Builtin.Alias do
  @moduledoc """
  `alias [-p] [name[=value] ... ]`

  `alias` with no arguments or with the -p option prints the list of aliases
  in the form alias NAME=VALUE on standard output. When arguments are
  supplied, an alias is defined for each NAME whose VALUE is given.

  A trailing space in VALUE causes the next word to be checked for alias
  substitution when the alias is expanded.

  Exit Status:
  Returns success (0) unless a NAME is supplied for which no alias has been
  defined, in which case it returns failure (1).

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/alias.def?h=bash-5.3
  """
  use Bash.Builtin

  defbash execute(args, state) do
    case parse_args(args) do
      {:list_all} ->
        list_all_aliases(state)

      {:mixed, items} ->
        handle_mixed_args(items, state)
    end
  end

  # Parse command arguments
  # Returns {:list_all} or {:mixed, items} where items is a list of
  # {:define, name, value} or {:print, name}
  defp parse_args([]), do: {:list_all}
  defp parse_args(["-p"]), do: {:list_all}
  defp parse_args(["-p" | rest]), do: parse_args(rest)

  defp parse_args(args) do
    items =
      Enum.map(args, fn arg ->
        case String.split(arg, "=", parts: 2) do
          [name, value] -> {:define, name, value}
          [name] -> {:print, name}
        end
      end)

    {:mixed, items}
  end

  # List all defined aliases
  defp list_all_aliases(session_state) do
    aliases = Map.get(session_state, :aliases, %{})

    output =
      aliases
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("", fn {name, value} -> format_alias(name, value) end)

    if output != "", do: write(output)

    :ok
  end

  # Handle a mix of definitions and print requests
  defp handle_mixed_args(items, session_state) do
    aliases = Map.get(session_state, :aliases, %{})

    # Accumulate output, errors, exit code, and updates
    {exit_code, updates, stdout_acc, stderr_acc} =
      Enum.reduce(items, {0, %{}, [], []}, fn
        {:define, name, value}, {code, upd, stdout, stderr} ->
          # Add alias to updates
          {code, Map.put(upd, name, value), stdout, stderr}

        {:print, name}, {code, upd, stdout, stderr} ->
          # Print alias if it exists, or record error
          case Map.get(updates_or_aliases(upd, aliases), name) do
            nil ->
              {1, upd, stdout, ["alias: #{name}: not found" | stderr]}

            value ->
              {code, upd, [format_alias(name, value) | stdout], stderr}
          end
      end)

    # Write accumulated output in correct order
    # stdout strings already have trailing newlines from format_alias
    stdout_text = stdout_acc |> Enum.reverse() |> Enum.join("")
    # stderr messages don't have newlines - error() adds one, so join with newlines
    stderr_text = stderr_acc |> Enum.reverse() |> Enum.join("\n")

    if stdout_text != "", do: write(stdout_text)
    if stderr_text != "", do: error(stderr_text)

    if map_size(updates) > 0 do
      update_state(alias_updates: updates)
    end

    {:ok, exit_code}
  end

  # Helper to check updates first (for aliases defined in the same call),
  # then fall back to existing aliases
  defp updates_or_aliases(updates, aliases) do
    Map.merge(aliases, updates)
  end

  # Format an alias for output
  # Bash outputs: alias NAME='VALUE'
  defp format_alias(name, value) do
    # Escape single quotes in value by replacing ' with '\''
    escaped_value = String.replace(value, "'", "'\\''")
    "alias #{name}='#{escaped_value}'\n"
  end
end
