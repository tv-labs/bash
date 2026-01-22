defmodule Bash.Builtin.Unalias do
  @moduledoc """
  `unalias [-a] name [name ...]`

  Remove each NAME from the list of defined aliases. If -a is supplied, remove
  all alias definitions.

  Exit Status:
  Returns success (0) unless a NAME is not an existing alias, in which case
  it returns failure (1).

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/alias.def?h=bash-5.3
  """
  use Bash.Builtin

  defbash execute(args, state) do
    case parse_args(args) do
      {:remove_all} ->
        remove_all_aliases()

      {:remove, names} when names != [] ->
        remove_aliases(names, state)

      {:error, message} ->
        error("unalias: #{message}")
        {:ok, 1}
    end
  end

  # Parse command arguments
  defp parse_args([]), do: {:error, "usage: unalias [-a] name [name ...]"}
  defp parse_args(["-a"]), do: {:remove_all}
  defp parse_args(["-a" | rest]) when rest != [], do: {:remove_all}
  defp parse_args(["--" | rest]) when rest != [], do: {:remove, rest}
  defp parse_args(["--"]), do: {:error, "usage: unalias [-a] name [name ...]"}
  defp parse_args(args), do: {:remove, args}

  # Remove all aliases
  defp remove_all_aliases do
    update_state(alias_updates: :clear_all)
    :ok
  end

  # Remove specific aliases
  defp remove_aliases(names, session_state) do
    aliases = Map.get(session_state, :aliases, %{})

    {found, not_found} =
      Enum.split_with(names, fn name -> Map.has_key?(aliases, name) end)

    # Report errors for aliases that weren't found
    Enum.each(not_found, fn name ->
      error("unalias: #{name}: not found")
    end)

    # Build alias removals map
    alias_removals =
      found
      |> Enum.map(fn name -> {name, :remove} end)
      |> Map.new()

    if map_size(alias_removals) > 0 do
      update_state(alias_updates: alias_removals)
    end

    exit_code = if not_found == [], do: 0, else: 1
    {:ok, exit_code}
  end
end
