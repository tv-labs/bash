defmodule Bash.Builtin.Read do
  @moduledoc """
  `read [-ers] [-a array] [-d delim] [-i text] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]`

  One line is read from the standard input, or from file descriptor FD if the
  -u option is supplied, and the first word is assigned to the first NAME,
  the second word to the second NAME, and so on, with leftover words assigned
  to the last NAME. Only the characters found in $IFS are recognized as word
  delimiters. If no NAMEs are supplied, the line read is stored in the REPLY
  variable. If the -r option is given, this signifies `raw` input, and backslash
  escaping is disabled. The -d option causes read to continue until the first
  character of DELIM is read, rather than newline. If the -p option is supplied,
  the string PROMPT is output without a trailing newline before attempting to
  read. If -a is supplied, the words read are assigned to sequential indices
  of ARRAY, starting at zero. If -e is supplied and the shell is interactive,
  readline is used to obtain the line. If -n is supplied with a non-zero NCHARS
  argument, read returns after NCHARS characters have been read. The -s option
  causes input coming from a terminal to not be echoed.

  The -t option causes read to time out and return failure if a complete line
  of input is not read within TIMEOUT seconds. If the TMOUT variable is set,
  its value is the default timeout. The return code is zero, unless end-of-file
  is encountered, read times out, or an invalid file descriptor is supplied as
  the argument to -u.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/read.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Variable

  @default_ifs " \t\n"

  @doc """
  Execute the read builtin.

  ## Arguments

    * `args` - Command arguments including flags and variable names
    * `stdin` - Input string to read from (nil means no input available)
    * `session_state` - Current session state with variables

  ## Returns

    * `{:ok, result, state_updates}` - Success with variable updates
    * `{:ok, result}` - Success with no state changes (e.g., EOF)
    * `{:error, result}` - Error occurred

  ## Examples

      # Read into REPLY (default)
      iex> Read.execute([], "hello world", %{variables: %{}})
      {:ok, %CommandResult{exit_code: 0}, %{var_updates: %{"REPLY" => %Variable{value: "hello world"}}}}

      # Read into named variable
      iex> Read.execute(["myvar"], "hello", %{variables: %{}})
      {:ok, %CommandResult{exit_code: 0}, %{var_updates: %{"myvar" => %Variable{value: "hello"}}}}

      # Read into multiple variables
      iex> Read.execute(["a", "b"], "one two three", %{variables: %{}})
      {:ok, %CommandResult{exit_code: 0}, %{var_updates: %{"a" => %Variable{value: "one"}, "b" => %Variable{value: "two three"}}}}

  """
  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, opts, var_names} ->
        # Check for stdin_device first (set by while loops with redirects)
        # This allows line-by-line reading from a StringIO device
        stdin_input =
          case Map.get(state, :stdin_device) do
            nil ->
              # No device, read from parameter stdin
              case read(:all) do
                {:ok, data} -> data
                :eof -> nil
                {:error, _} -> nil
              end

            device when is_pid(device) ->
              # Read one line from the StringIO device
              case IO.binread(device, :line) do
                :eof -> nil
                {:error, _} -> nil
                line -> line
              end
          end

        do_read(opts, var_names, stdin_input, state)

      {:error, msg} ->
        error("read: #{msg}")
        {:ok, 2}
    end
  end

  # Parse command-line arguments
  defp parse_args(args) do
    default_opts = %{
      raw: false,
      array: nil,
      delimiter: "\n",
      nchars: nil,
      prompt: nil,
      silent: false,
      timeout: nil,
      fd: nil
    }

    parse_args(args, default_opts, [])
  end

  defp parse_args([], opts, names) do
    {:ok, opts, Enum.reverse(names)}
  end

  # -r: raw mode (don't interpret backslashes)
  defp parse_args(["-r" | rest], opts, names) do
    parse_args(rest, %{opts | raw: true}, names)
  end

  # -a array: read into indexed array
  defp parse_args(["-a", array_name | rest], opts, names) do
    if valid_var_name?(array_name) do
      parse_args(rest, %{opts | array: array_name}, names)
    else
      {:error, "#{array_name}: invalid identifier"}
    end
  end

  defp parse_args(["-a"], _opts, _names) do
    {:error, "-a: option requires an argument"}
  end

  # -d delim: use delim as line terminator
  defp parse_args(["-d", delim | rest], opts, names) do
    # Use first character of delim, or empty string for null delimiter
    delimiter = if delim == "", do: "", else: String.first(delim)
    parse_args(rest, %{opts | delimiter: delimiter}, names)
  end

  defp parse_args(["-d"], _opts, _names) do
    {:error, "-d: option requires an argument"}
  end

  # -n nchars: read exactly n characters
  defp parse_args(["-n", nchars_str | rest], opts, names) do
    case Integer.parse(nchars_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, %{opts | nchars: n}, names)

      _ ->
        {:error, "#{nchars_str}: invalid number"}
    end
  end

  defp parse_args(["-n"], _opts, _names) do
    {:error, "-n: option requires an argument"}
  end

  # -N nchars: read exactly n characters (ignoring delimiter)
  # For simplicity, treat same as -n in this implementation
  defp parse_args(["-N", nchars_str | rest], opts, names) do
    case Integer.parse(nchars_str) do
      {n, ""} when n >= 0 ->
        # -N ignores delimiter, so we set delimiter to empty
        parse_args(rest, %{opts | nchars: n, delimiter: ""}, names)

      _ ->
        {:error, "#{nchars_str}: invalid number"}
    end
  end

  defp parse_args(["-N"], _opts, _names) do
    {:error, "-N: option requires an argument"}
  end

  # -p prompt: display prompt (no-op for non-interactive)
  defp parse_args(["-p", prompt | rest], opts, names) do
    parse_args(rest, %{opts | prompt: prompt}, names)
  end

  defp parse_args(["-p"], _opts, _names) do
    {:error, "-p: option requires an argument"}
  end

  # -s: silent mode (no echo)
  defp parse_args(["-s" | rest], opts, names) do
    parse_args(rest, %{opts | silent: true}, names)
  end

  # -e: readline (no-op for non-interactive)
  defp parse_args(["-e" | rest], opts, names) do
    parse_args(rest, opts, names)
  end

  # -t timeout: timeout in seconds
  defp parse_args(["-t", timeout_str | rest], opts, names) do
    case Float.parse(timeout_str) do
      {t, ""} when t >= 0 ->
        parse_args(rest, %{opts | timeout: t}, names)

      _ ->
        case Integer.parse(timeout_str) do
          {t, ""} when t >= 0 ->
            parse_args(rest, %{opts | timeout: t * 1.0}, names)

          _ ->
            {:error, "#{timeout_str}: invalid timeout specification"}
        end
    end
  end

  defp parse_args(["-t"], _opts, _names) do
    {:error, "-t: option requires an argument"}
  end

  # -u fd: read from file descriptor
  defp parse_args(["-u", fd_str | rest], opts, names) do
    case Integer.parse(fd_str) do
      {fd, ""} when fd >= 0 ->
        parse_args(rest, %{opts | fd: fd}, names)

      _ ->
        {:error, "#{fd_str}: invalid file descriptor"}
    end
  end

  defp parse_args(["-u"], _opts, _names) do
    {:error, "-u: option requires an argument"}
  end

  # -i text: initial text for readline (no-op for non-interactive)
  defp parse_args(["-i", _text | rest], opts, names) do
    parse_args(rest, opts, names)
  end

  defp parse_args(["-i"], _opts, _names) do
    {:error, "-i: option requires an argument"}
  end

  # Combined flags like -rs
  defp parse_args(["-" <> flags | rest], opts, names) when byte_size(flags) > 1 do
    case expand_combined_flags(flags) do
      {:ok, expanded} ->
        parse_args(expanded ++ rest, opts, names)

      :not_combined ->
        # Unknown option
        {:error, "-#{flags}: invalid option"}
    end
  end

  # -- stops option processing
  defp parse_args(["--" | rest], opts, names) do
    # Everything after -- is a variable name
    valid_names = Enum.filter(rest, &valid_var_name?/1)

    if length(valid_names) == length(rest) do
      {:ok, opts, Enum.reverse(names) ++ rest}
    else
      invalid = Enum.find(rest, &(not valid_var_name?(&1)))
      {:error, "#{invalid}: invalid identifier"}
    end
  end

  # Variable name (not starting with -)
  defp parse_args([name | rest], opts, names) do
    if valid_var_name?(name) do
      parse_args(rest, opts, [name | names])
    else
      {:error, "#{name}: invalid identifier"}
    end
  end

  # Expand combined flags like "rs" to ["-r", "-s"]
  defp expand_combined_flags(flags) do
    chars = String.graphemes(flags)

    if Enum.all?(chars, &(&1 in ~w[r s e a])) do
      {:ok, Enum.map(chars, &("-" <> &1))}
    else
      :not_combined
    end
  end

  # Validate variable name
  defp valid_var_name?(name) when is_binary(name) do
    String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)
  end

  defp valid_var_name?(_), do: false

  # Main read logic
  defp do_read(opts, var_names, stdin_input, session_state) do
    # Handle timeout (for non-blocking environments, this is a no-op check)
    # In a real implementation, this would involve async I/O

    # Resolve input from file descriptor
    case resolve_input(opts.fd, stdin_input, session_state) do
      {:ok, input} ->
        do_read_from_input(opts, var_names, input, session_state)

      {:error, msg} ->
        error("read: #{msg}")
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
      nil ->
        {:error, "#{fd}: Bad file descriptor"}

      device when is_pid(device) ->
        case IO.binread(device, :line) do
          :eof -> {:ok, nil}
          {:error, _} -> {:error, "#{fd}: Bad file descriptor"}
          line -> {:ok, line}
        end

      content ->
        {:ok, content}
    end
  end

  # Read from resolved input
  defp do_read_from_input(opts, var_names, input, session_state) do
    # Check for empty/nil input (EOF)
    if input == nil or input == "" do
      # EOF - set variables to empty and return 1
      var_updates = build_eof_updates(opts, var_names, session_state)
      update_state(var_updates: var_updates)
      {:ok, 1}
    else
      # Read the input (for device-based reading, input is already one line)
      {line, _rest} = read_input(input, opts)

      # Process backslash escapes unless -r is specified
      line = if opts.raw, do: line, else: process_escapes(line)

      # Build variable updates
      var_updates = build_var_updates(opts, var_names, line, session_state)

      # Output prompt if specified (for interactive, would be written before read)
      if opts.prompt do
        write(opts.prompt)
      end

      update_state(var_updates: var_updates)
      :ok
    end
  end

  # Read input based on options
  defp read_input(stdin, opts) do
    cond do
      # -n: read exactly n characters
      opts.nchars != nil ->
        chars = String.slice(stdin, 0, opts.nchars)
        rest = String.slice(stdin, opts.nchars..-1//1)
        {chars, rest}

      # -d: use custom delimiter
      opts.delimiter == "" ->
        # Null delimiter - read until null byte or end
        case String.split(stdin, <<0>>, parts: 2) do
          [line, rest] -> {line, rest}
          [line] -> {line, ""}
        end

      # Non-raw mode with newline delimiter: handle line continuations
      not opts.raw and opts.delimiter == "\n" ->
        read_with_continuations(stdin)

      true ->
        # Read until delimiter (default newline)
        case String.split(stdin, opts.delimiter, parts: 2) do
          [line, rest] -> {line, rest}
          [line] -> {String.trim_trailing(line, opts.delimiter), ""}
        end
    end
  end

  # Read handling line continuations (backslash-newline)
  # In non-raw mode, backslash-newline causes read to continue to next line
  defp read_with_continuations(stdin) do
    read_with_continuations(stdin, [])
  end

  defp read_with_continuations("", acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  end

  defp read_with_continuations("\\\n" <> rest, acc) do
    # Line continuation - continue reading
    read_with_continuations(rest, acc)
  end

  defp read_with_continuations("\n" <> rest, acc) do
    # End of logical line
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp read_with_continuations(<<char, rest::binary>>, acc) do
    read_with_continuations(rest, [<<char>> | acc])
  end

  # Process backslash escapes (for non-raw mode)
  # In bash, backslash followed by any char removes the backslash
  defp process_escapes(str) do
    process_escapes(str, [])
  end

  defp process_escapes("", acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # Line continuation: backslash at end of line followed by newline
  defp process_escapes("\\\n" <> rest, acc) do
    process_escapes(rest, acc)
  end

  # Escaped character - keep the character, drop the backslash
  defp process_escapes("\\" <> <<char, rest::binary>>, acc) do
    process_escapes(rest, [<<char>> | acc])
  end

  # Trailing backslash with no following char - keep it
  defp process_escapes("\\", acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # Regular character
  defp process_escapes(<<char, rest::binary>>, acc) do
    process_escapes(rest, [<<char>> | acc])
  end

  # Build variable updates for EOF case
  defp build_eof_updates(opts, var_names, session_state) do
    if opts.array do
      # -a: create empty array
      %{opts.array => Variable.new_indexed_array(%{})}
    else
      names = if Enum.empty?(var_names), do: ["REPLY"], else: var_names
      build_empty_vars(names, session_state)
    end
  end

  defp build_empty_vars(names, session_state) do
    Enum.reduce(names, %{}, fn name, acc ->
      existing = Map.get(session_state.variables, name)

      # Check readonly
      if existing && Variable.readonly?(existing) do
        acc
      else
        Map.put(acc, name, Variable.new(""))
      end
    end)
  end

  # Build variable updates from read line
  defp build_var_updates(opts, var_names, line, session_state) do
    # Get IFS from session state, default to space/tab/newline
    ifs = get_ifs(session_state)

    if opts.array do
      # -a: read into indexed array
      words = split_by_ifs(line, ifs)
      build_array_update(opts.array, words, session_state)
    else
      # Read into named variables
      names = if Enum.empty?(var_names), do: ["REPLY"], else: var_names
      words = split_by_ifs(line, ifs)
      build_scalar_updates(names, words, session_state)
    end
  end

  # Get IFS from session state
  defp get_ifs(session_state) do
    case Map.get(session_state.variables, "IFS") do
      nil -> @default_ifs
      %Variable{value: val} when is_binary(val) -> val
      _ -> @default_ifs
    end
  end

  # Split string by IFS characters
  # Bash IFS splitting rules:
  # - Leading/trailing IFS whitespace is stripped
  # - Multiple IFS whitespace chars are treated as one delimiter
  # - Non-whitespace IFS chars are individual delimiters
  defp split_by_ifs(str, ifs) do
    if ifs == "" do
      # Empty IFS means no word splitting
      [str]
    else
      # Build a pattern from IFS characters
      # Whitespace chars (space, tab, newline) in IFS get special treatment
      ifs_whitespace = for <<c <- ifs>>, c in [?\s, ?\t, ?\n], do: <<c>>
      ifs_non_whitespace = for <<c <- ifs>>, c not in [?\s, ?\t, ?\n], do: <<c>>

      # First, trim leading/trailing IFS whitespace
      str = trim_ifs_whitespace(str, ifs_whitespace)

      # Split by IFS characters
      if ifs_whitespace == [] and ifs_non_whitespace == [] do
        [str]
      else
        do_split_by_ifs(str, ifs_whitespace, ifs_non_whitespace, [], [])
      end
    end
  end

  defp trim_ifs_whitespace(str, []) do
    str
  end

  defp trim_ifs_whitespace(str, ifs_whitespace) do
    pattern = "[" <> Enum.join(Enum.map(ifs_whitespace, &Regex.escape/1)) <> "]+"

    str
    |> String.replace(~r/^#{pattern}/, "")
    |> String.replace(~r/#{pattern}$/, "")
  end

  defp do_split_by_ifs("", _ws, _nws, [], words) do
    Enum.reverse(words)
  end

  defp do_split_by_ifs("", _ws, _nws, current, words) do
    word = current |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([word | words])
  end

  defp do_split_by_ifs(<<char, rest::binary>>, ifs_ws, ifs_nws, current, words) do
    char_str = <<char>>

    cond do
      # IFS whitespace - skip consecutive, ends current word
      char_str in ifs_ws ->
        case current do
          [] ->
            # Skip leading whitespace within the string
            do_split_by_ifs(skip_ifs_whitespace(rest, ifs_ws), ifs_ws, ifs_nws, [], words)

          _ ->
            word = current |> Enum.reverse() |> IO.iodata_to_binary()

            do_split_by_ifs(
              skip_ifs_whitespace(rest, ifs_ws),
              ifs_ws,
              ifs_nws,
              [],
              [word | words]
            )
        end

      # IFS non-whitespace - always a delimiter
      char_str in ifs_nws ->
        case current do
          [] ->
            # Empty field before delimiter
            do_split_by_ifs(rest, ifs_ws, ifs_nws, [], ["" | words])

          _ ->
            word = current |> Enum.reverse() |> IO.iodata_to_binary()
            do_split_by_ifs(rest, ifs_ws, ifs_nws, [], [word | words])
        end

      # Regular character
      true ->
        do_split_by_ifs(rest, ifs_ws, ifs_nws, [char_str | current], words)
    end
  end

  defp skip_ifs_whitespace(<<char, rest::binary>>, ifs_ws) do
    if <<char>> in ifs_ws do
      skip_ifs_whitespace(rest, ifs_ws)
    else
      <<char, rest::binary>>
    end
  end

  defp skip_ifs_whitespace("", _ifs_ws), do: ""

  # Build array update
  defp build_array_update(array_name, words, session_state) do
    existing = Map.get(session_state.variables, array_name)

    # Check readonly
    if existing && Variable.readonly?(existing) do
      %{}
    else
      array_map =
        words
        |> Enum.with_index()
        |> Enum.map(fn {word, idx} -> {idx, word} end)
        |> Map.new()

      %{array_name => Variable.new_indexed_array(array_map)}
    end
  end

  # Build scalar variable updates
  defp build_scalar_updates(names, words, session_state) do
    # Number of variables vs number of words
    num_names = length(names)
    num_words = length(words)

    cond do
      num_words == 0 ->
        # No words - all variables get empty string
        build_empty_vars(names, session_state)

      num_words <= num_names ->
        # Fewer words than variables - extra vars get empty string
        words_padded = words ++ List.duplicate("", num_names - num_words)
        assign_words_to_names(names, words_padded, session_state)

      true ->
        # More words than variables - last var gets remaining words
        {first_words, rest_words} = Enum.split(words, num_names - 1)
        last_word = Enum.join(rest_words, " ")
        assign_words_to_names(names, first_words ++ [last_word], session_state)
    end
  end

  defp assign_words_to_names(names, words, session_state) do
    Enum.zip(names, words)
    |> Enum.reduce(%{}, fn {name, word}, acc ->
      existing = Map.get(session_state.variables, name)

      # Check readonly
      if existing && Variable.readonly?(existing) do
        acc
      else
        Map.put(acc, name, Variable.new(word))
      end
    end)
  end
end
