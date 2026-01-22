defmodule Bash.Builtin.Fc do
  @moduledoc """
  `fc [-e ename] [-lnr] [first] [last] or fc -s [pat=rep] [cmd]`

  fc is used to list or edit and re-execute commands from the history list.
  FIRST and LAST can be numbers specifying the range, or FIRST can be a
  string, which means the most recent command beginning with that string.

  Options:
    -e ENAME  Select which editor to use (default: $FCEDIT, $EDITOR, or vi)
    -l        List lines instead of editing
    -n        Suppress line numbers when listing
    -r        Reverse the order of the lines

  With the `fc -s [pat=rep ...] [command]` format, the command is
  re-executed after the substitution OLD=NEW is performed.

  A useful alias to use with this is r='fc -s', so that typing `r cc`
  runs the last command beginning with `cc` and typing `r` re-executes
  the last command.

  Note: Interactive editing with -e is not supported in this implementation.
  Use fc -l to list and fc -s to re-execute with substitution.

  Exit Status:
  Returns success unless an invalid option is supplied or an error occurs.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/fc.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.CommandResult

  defbash execute(args, state) do
    case parse_args(args) do
      {:list, opts, first, last} ->
        list_history(opts, first, last, state)

      {:substitute, replacements, cmd_spec} ->
        substitute_and_execute(replacements, cmd_spec, state)

      {:edit, _editor, _first, _last} ->
        unsupported_edit()

      {:error, msg} ->
        error(msg)
        {:ok, 1}
    end
  end

  defp parse_args(args) do
    parse_args(
      args,
      %{list: false, no_numbers: false, reverse: false, editor: nil, substitute: false},
      []
    )
  end

  defp parse_args([], opts, rest) do
    finalize_parse(opts, Enum.reverse(rest))
  end

  defp parse_args(["-l" | rest], opts, acc), do: parse_args(rest, %{opts | list: true}, acc)
  defp parse_args(["-n" | rest], opts, acc), do: parse_args(rest, %{opts | no_numbers: true}, acc)
  defp parse_args(["-r" | rest], opts, acc), do: parse_args(rest, %{opts | reverse: true}, acc)
  defp parse_args(["-s" | rest], opts, acc), do: parse_args(rest, %{opts | substitute: true}, acc)

  defp parse_args(["-e", editor | rest], opts, acc),
    do: parse_args(rest, %{opts | editor: editor}, acc)

  defp parse_args(["-" <> flags | rest], opts, acc) when byte_size(flags) > 1 do
    new_opts =
      String.graphemes(flags)
      |> Enum.reduce(opts, fn
        "l", o -> %{o | list: true}
        "n", o -> %{o | no_numbers: true}
        "r", o -> %{o | reverse: true}
        "s", o -> %{o | substitute: true}
        _, o -> o
      end)

    parse_args(rest, new_opts, acc)
  end

  defp parse_args(["--" | rest], opts, acc), do: {opts, Enum.reverse(acc) ++ rest}
  defp parse_args([arg | rest], opts, acc), do: parse_args(rest, opts, [arg | acc])

  defp finalize_parse(opts, rest) do
    cond do
      opts.substitute ->
        {replacements, cmd_spec} = parse_substitutions(rest)
        {:substitute, replacements, cmd_spec}

      opts.list ->
        {first, last} = parse_range(rest)
        {:list, opts, first, last}

      opts.editor != nil or rest != [] ->
        {first, last} = parse_range(rest)
        {:edit, opts.editor, first, last}

      true ->
        # Default: edit last command (unsupported)
        {:edit, nil, -1, -1}
    end
  end

  defp parse_substitutions(args) do
    {replacements, rest} = Enum.split_with(args, &String.contains?(&1, "="))

    replacements =
      Enum.map(replacements, fn r ->
        case String.split(r, "=", parts: 2) do
          [old, new] -> {old, new}
          [old] -> {old, ""}
        end
      end)

    cmd_spec =
      case rest do
        [] -> nil
        [spec | _] -> spec
      end

    {replacements, cmd_spec}
  end

  defp parse_range([]), do: {-16, -1}
  defp parse_range([first]), do: {parse_spec(first), parse_spec(first)}
  defp parse_range([first, last | _]), do: {parse_spec(first), parse_spec(last)}

  defp parse_spec(spec) do
    case Integer.parse(spec) do
      {num, ""} -> num
      _ -> {:prefix, spec}
    end
  end

  defp list_history(opts, first, last, session_state) do
    history = Map.get(session_state, :command_history, [])

    entries =
      history
      |> Enum.with_index(1)
      |> select_range(first, last, length(history))
      |> maybe_reverse(opts.reverse)

    output =
      entries
      |> Enum.map(fn {entry, index} ->
        cmd_str = extract_command(entry)

        if opts.no_numbers do
          "#{cmd_str}\n"
        else
          "#{String.pad_leading(Integer.to_string(index), 5)}\t#{cmd_str}\n"
        end
      end)
      |> Enum.join()

    if output != "", do: write(output)
    :ok
  end

  defp select_range(entries, first, last, total) do
    first_idx = resolve_index(first, entries, total)
    last_idx = resolve_index(last, entries, total)

    {start_idx, end_idx} =
      if first_idx <= last_idx do
        {first_idx, last_idx}
      else
        {last_idx, first_idx}
      end

    Enum.filter(entries, fn {_, idx} -> idx >= start_idx and idx <= end_idx end)
  end

  defp resolve_index(n, _entries, total) when is_integer(n) and n < 0, do: max(1, total + n + 1)
  defp resolve_index(n, _entries, total) when is_integer(n), do: min(max(1, n), total)

  defp resolve_index({:prefix, prefix}, entries, _total) do
    case Enum.find(entries, fn {entry, _} ->
           String.starts_with?(extract_command(entry), prefix)
         end) do
      {_, idx} -> idx
      nil -> 1
    end
  end

  defp maybe_reverse(entries, true), do: Enum.reverse(entries)
  defp maybe_reverse(entries, false), do: entries

  defp substitute_and_execute(replacements, cmd_spec, session_state) do
    history = Map.get(session_state, :command_history, [])

    # Find the command to re-execute
    cmd_entry = find_command(history, cmd_spec)

    case cmd_entry do
      nil ->
        error("fc: no command found")
        {:ok, 1}

      entry ->
        original = extract_command(entry)

        # Apply substitutions
        modified =
          Enum.reduce(replacements, original, fn {old, new}, cmd ->
            String.replace(cmd, old, new)
          end)

        # Output the command being executed
        write("#{modified}\n")

        # Return the command to be re-executed
        # The session will need to handle this
        update_state(reexecute_command: modified)
        :ok
    end
  end

  defp find_command([], _spec), do: nil
  defp find_command(history, nil), do: List.last(history)

  defp find_command(history, spec) when is_binary(spec) do
    # Find most recent command starting with prefix
    history
    |> Enum.reverse()
    |> Enum.find(fn entry ->
      String.starts_with?(extract_command(entry), spec)
    end)
  end

  defp unsupported_edit do
    error("fc: interactive editing is not supported; use fc -l to list or fc -s to re-execute")
    {:ok, 1}
  end

  defp extract_command(%CommandResult{command: cmd}) when is_binary(cmd), do: cmd
  defp extract_command(%{__struct__: _} = ast), do: to_string(ast)
  defp extract_command(cmd) when is_binary(cmd), do: cmd
  defp extract_command(_), do: "(unknown)"
end
