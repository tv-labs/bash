defmodule Bash.Builtin.History do
  @moduledoc """
  `history [-c] [-d offset] [n] or history -awrn [filename] or history -ps arg [arg...]`

  Display the history list with line numbers.  Lines listed with
  with a `*` have been modified.  Argument of N says to list only
  the last N lines.  The `-c` option causes the history list to be
  cleared by deleting all of the entries.  The `-d` option deletes
  the history entry at offset OFFSET.  The `-w` option writes out the
  current history to the history file;  `-r` means to read the file and
  append the contents to the history list instead.  `-a` means
  to append history lines from this session to the history file.
  Argument `-n` means to read all history lines not already read
  from the history file and append them to the history list.

  If FILENAME is given, then that is used as the history file else
  if $HISTFILE has a value, that is used, else ~/.bash_history.
  If the -s option is supplied, the non-option ARGs are appended to
  the history list as a single entry.  The -p option means to perform
  history expansion on each ARG and display the result, without storing
  anything in the history list.

  If the $HISTTIMEFORMAT variable is set and not null, its value is used
  as a format string for strftime(3) to print the time stamp associated
  with each displayed history entry.  No time stamps are printed otherwise.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/history.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.CommandResult

  defbash execute(args, state) do
    case parse_args(args) do
      {:clear} ->
        clear_history()

      {:delete, offset} ->
        delete_entry(offset, state)

      {:list, count} ->
        list_history(count, state)

      {:error, message} ->
        error("history: #{message}")
        {:ok, 1}
    end
  end

  # Parse command arguments
  defp parse_args([]) do
    {:list, :all}
  end

  defp parse_args(["-c"]) do
    {:clear}
  end

  defp parse_args(["-d", offset | _]) do
    case Integer.parse(offset) do
      {num, ""} -> {:delete, num}
      _ -> {:error, "numeric argument required"}
    end
  end

  defp parse_args([count]) do
    case Integer.parse(count) do
      {num, ""} when num > 0 -> {:list, num}
      {num, ""} -> {:error, "#{num}: invalid option"}
      _ -> {:error, "#{count}: numeric argument required"}
    end
  end

  defp parse_args([flag | _]) when is_binary(flag) and byte_size(flag) > 0 do
    case String.first(flag) do
      "-" -> {:error, "#{flag}: invalid option"}
      _ -> {:error, "too many arguments"}
    end
  end

  # Clear command history
  defp clear_history do
    Bash.Context.update_state(clear_history: true)
    :ok
  end

  # Delete a specific history entry
  defp delete_entry(offset, session_state) do
    history = Map.get(session_state, :command_history, [])
    history_length = length(history)

    # Bash history uses 1-based indexing
    # Negative offsets count from the end
    actual_index =
      cond do
        offset > 0 and offset <= history_length -> offset - 1
        offset < 0 and abs(offset) <= history_length -> history_length + offset
        true -> nil
      end

    case actual_index do
      nil ->
        Bash.Context.error("history: #{offset}: history position out of range")
        {:ok, 1}

      index ->
        Bash.Context.update_state(delete_history_entry: index)
        :ok
    end
  end

  # List command history
  defp list_history(count, session_state) do
    output = format_history_from_state(session_state, count)
    if output != "", do: Bash.Context.write(output)
    :ok
  end

  # Format history from session state
  defp format_history_from_state(session_state, count) do
    # Access command_history from session_state
    history = Map.get(session_state, :command_history, [])

    format_history(history, count: count)
  end

  # Formats command history for display with line numbers.
  #
  # This is a utility function that formats history entries
  # in the standard bash history format.
  #
  # ## Examples
  #
  # history = Session.get_command_history(session_pid)
  # formatted = History.format_history(history)
  # # Returns: "  1  echo hello\\n  2  pwd\\n"
  #
  @doc false
  def format_history(command_results, opts \\ []) do
    count = Keyword.get(opts, :count, :all)
    start_offset = Keyword.get(opts, :offset, 1)

    entries =
      case count do
        :all -> command_results
        n when is_integer(n) -> Enum.take(command_results, -n)
      end

    entries
    |> Enum.with_index(start_offset)
    |> Enum.map(fn {result, index} ->
      # Extract the command from the CommandResult
      # This is a simplification - real bash stores the actual command string
      command_str = extract_command_string(result)
      "#{String.pad_leading(Integer.to_string(index), 5)}  #{command_str}\n"
    end)
    |> Enum.join("")
  end

  # Extract command string from CommandResult or AST node
  # This is a best-effort extraction
  defp extract_command_string(%CommandResult{command: command}) when is_binary(command) do
    command
  end

  # For AST nodes, serialize them back to string
  defp extract_command_string(%{__struct__: _} = ast) do
    to_string(ast)
  end

  defp extract_command_string(_result) do
    "(unknown)"
  end
end
