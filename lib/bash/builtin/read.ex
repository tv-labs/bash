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

  @doc false
  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, opts, var_names} ->
        if opts.prompt, do: write(opts.prompt)
        do_read(opts, var_names, state)

      {:error, msg} ->
        error("read: #{msg}")
        {:ok, 1}
    end
  end

  defp parse_args(args) do
    default_opts = %{
      raw: false,
      array: nil,
      delimiter: "\n",
      nchars: nil,
      nchars_mode: nil,
      prompt: nil,
      silent: false,
      timeout: nil,
      fd: nil
    }

    parse_args(args, default_opts, [])
  end

  defp parse_args([], opts, names), do: {:ok, opts, Enum.reverse(names)}

  defp parse_args(["-r" | rest], opts, names),
    do: parse_args(rest, %{opts | raw: true}, names)

  defp parse_args(["-a", array_name | rest], opts, names) do
    if valid_var_name?(array_name),
      do: parse_args(rest, %{opts | array: array_name}, names),
      else: {:error, "#{array_name}: invalid identifier"}
  end

  defp parse_args(["-a"], _opts, _names), do: {:error, "-a: option requires an argument"}

  defp parse_args(["-d", delim | rest], opts, names) do
    delimiter = if delim == "", do: "", else: String.first(delim)
    parse_args(rest, %{opts | delimiter: delimiter}, names)
  end

  defp parse_args(["-d"], _opts, _names), do: {:error, "-d: option requires an argument"}

  defp parse_args(["-n", nchars_str | rest], opts, names) do
    case Integer.parse(nchars_str) do
      {n, ""} when n >= 0 -> parse_args(rest, %{opts | nchars: n, nchars_mode: :n}, names)
      _ -> {:error, "#{nchars_str}: invalid number"}
    end
  end

  defp parse_args(["-n"], _opts, _names), do: {:error, "-n: option requires an argument"}

  defp parse_args(["-N", nchars_str | rest], opts, names) do
    case Integer.parse(nchars_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, %{opts | nchars: n, nchars_mode: :big_n, delimiter: ""}, names)

      _ ->
        {:error, "#{nchars_str}: invalid number"}
    end
  end

  defp parse_args(["-N"], _opts, _names), do: {:error, "-N: option requires an argument"}

  defp parse_args(["-p", prompt | rest], opts, names),
    do: parse_args(rest, %{opts | prompt: prompt}, names)

  defp parse_args(["-p"], _opts, _names), do: {:error, "-p: option requires an argument"}

  defp parse_args(["-s" | rest], opts, names),
    do: parse_args(rest, %{opts | silent: true}, names)

  defp parse_args(["-e" | rest], opts, names),
    do: parse_args(rest, opts, names)

  defp parse_args(["-t", timeout_str | rest], opts, names) do
    case Float.parse(timeout_str) do
      {t, ""} when t >= 0 ->
        parse_args(rest, %{opts | timeout: t}, names)

      _ ->
        case Integer.parse(timeout_str) do
          {t, ""} when t >= 0 -> parse_args(rest, %{opts | timeout: t * 1.0}, names)
          _ -> {:error, "#{timeout_str}: invalid timeout specification"}
        end
    end
  end

  defp parse_args(["-t"], _opts, _names), do: {:error, "-t: option requires an argument"}

  defp parse_args(["-u", fd_str | rest], opts, names) do
    case Integer.parse(fd_str) do
      {fd, ""} when fd >= 0 -> parse_args(rest, %{opts | fd: fd}, names)
      _ -> {:error, "#{fd_str}: invalid file descriptor"}
    end
  end

  defp parse_args(["-u"], _opts, _names), do: {:error, "-u: option requires an argument"}

  defp parse_args(["-i", _text | rest], opts, names),
    do: parse_args(rest, opts, names)

  defp parse_args(["-i"], _opts, _names), do: {:error, "-i: option requires an argument"}

  defp parse_args(["-" <> flags | rest], opts, names) when byte_size(flags) > 1 do
    case expand_combined_flags(flags) do
      {:ok, expanded} -> parse_args(expanded ++ rest, opts, names)
      :not_combined -> {:error, "-#{flags}: invalid option"}
    end
  end

  defp parse_args(["--" | rest], opts, names) do
    valid_names = Enum.filter(rest, &valid_var_name?/1)

    if length(valid_names) == length(rest) do
      {:ok, opts, Enum.reverse(names) ++ rest}
    else
      invalid = Enum.find(rest, &(not valid_var_name?(&1)))
      {:error, "#{invalid}: invalid identifier"}
    end
  end

  defp parse_args([name | rest], opts, names) do
    if valid_var_name?(name),
      do: parse_args(rest, opts, [name | names]),
      else: {:error, "#{name}: invalid identifier"}
  end

  defp expand_combined_flags(flags),
    do: expand_combined_flags(String.graphemes(flags), [])

  defp expand_combined_flags([], acc), do: {:ok, Enum.reverse(acc)}

  defp expand_combined_flags([c | rest], acc) when c in ~w[r s e] do
    expand_combined_flags(rest, ["-" <> c | acc])
  end

  defp expand_combined_flags([c | rest], acc) when c in ~w[n N d t u p a i] do
    arg = Enum.join(rest)

    if arg == "",
      do: {:ok, Enum.reverse(["-" <> c | acc])},
      else: {:ok, Enum.reverse(acc) ++ ["-" <> c, arg]}
  end

  defp expand_combined_flags(_, _), do: :not_combined

  defp valid_var_name?(name) when is_binary(name),
    do: String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)

  defp valid_var_name?(_), do: false

  defp do_read(opts, var_names, session_state) do
    case read_raw_input(opts, session_state) do
      {:ok, line, found_delimiter} ->
        ifs = get_ifs(session_state)
        var_updates = build_var_updates(opts, var_names, line, ifs, session_state)
        update_state(variables: var_updates)
        if found_delimiter, do: :ok, else: {:ok, 1}

      :eof ->
        var_updates = build_eof_updates(opts, var_names, session_state)
        update_state(variables: var_updates)
        {:ok, 1}

      {:error, msg} ->
        error("read: #{msg}")
        {:ok, 1}
    end
  end

  defp read_raw_input(opts, session_state) do
    case resolve_fd_input(opts.fd, session_state) do
      {:ok, :use_context} ->
        case Map.get(session_state, :stdin_device) do
          device when is_pid(device) -> read_from_device(device, opts)
          _ -> read_from_context(opts)
        end

      {:ok, {:device, device}} ->
        read_from_device(device, opts)

      {:ok, {:raw_data, data}} ->
        {:ok, device} = StringIO.open(data)
        read_from_device(device, opts)

      {:error, _} = err ->
        err
    end
  end

  defp resolve_fd_input(nil, _state), do: {:ok, :use_context}
  defp resolve_fd_input(0, _state), do: {:ok, :use_context}
  defp resolve_fd_input(fd, _state) when fd in [1, 2], do: {:error, "#{fd}: Bad file descriptor"}

  defp resolve_fd_input(fd, state) do
    file_descriptors = Map.get(state, :file_descriptors, %{})

    case Map.get(file_descriptors, fd) do
      nil ->
        {:error, "#{fd}: Bad file descriptor"}

      {:coproc, coproc_pid, :read} ->
        case Bash.Builtin.Coproc.read_output(coproc_pid, state.call_timeout) do
          {:ok, data} -> {:ok, {:raw_data, data}}
          :eof -> {:error, "#{fd}: Bad file descriptor"}
          {:error, _} -> {:error, "#{fd}: Bad file descriptor"}
        end

      device when is_pid(device) ->
        {:ok, {:device, device}}
    end
  end

  defp read_from_context(opts) do
    cond do
      opts.nchars != nil -> read_nchars_from_context(opts)
      opts.delimiter != "\n" -> read_until_delimiter_from_context(opts)
      true -> read_line_from_context(opts)
    end
  end

  defp read_line_from_context(opts) do
    case gets() do
      {:ok, data} ->
        {line, found_newline} = strip_trailing_newline(data)

        if not opts.raw,
          do: read_continuations_from_context(line, found_newline),
          else: {:ok, line, found_newline}

      :eof ->
        :eof

      {:error, reason} ->
        {:error, "#{inspect(reason)}"}
    end
  end

  defp read_continuations_from_context(line, found_newline) do
    if String.ends_with?(line, "\\") and found_newline do
      continued = String.slice(line, 0, byte_size(line) - 1)

      case gets() do
        {:ok, next_data} ->
          {next_line, next_found} = strip_trailing_newline(next_data)
          read_continuations_from_context(continued <> next_line, next_found)

        :eof ->
          {:ok, continued, false}

        {:error, _} ->
          {:ok, continued, false}
      end
    else
      {:ok, line, found_newline}
    end
  end

  defp read_nchars_from_context(opts) do
    if opts.nchars == 0 do
      {:ok, "", true}
    else
      case read_n_chars_loop(opts.nchars, opts, []) do
        {:ok, data} ->
          found_delim = byte_size(data) >= opts.nchars
          {:ok, data, found_delim}

        :eof ->
          :eof
      end
    end
  end

  defp read_n_chars_loop(0, _opts, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_n_chars_loop(remaining, opts, acc) do
    case read(1) do
      {:ok, <<char>>} ->
        cond do
          opts.nchars_mode == :n and opts.delimiter != "" and <<char>> == opts.delimiter ->
            {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

          opts.nchars_mode == :n and not opts.raw and char == ?\\ ->
            case read(1) do
              {:ok, <<?\n>>} ->
                read_n_chars_loop(remaining, opts, acc)

              {:ok, <<next_char>>} ->
                read_n_chars_loop(remaining - 1, opts, [<<next_char>> | acc])

              _ ->
                {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
            end

          true ->
            read_n_chars_loop(remaining - 1, opts, [<<char>> | acc])
        end

      _ ->
        if acc == [], do: :eof, else: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp read_until_delimiter_from_context(opts),
    do: read_until_delim_loop(opts, [])

  defp read_until_delim_loop(opts, acc) do
    case read(1) do
      {:ok, <<char>>} ->
        delim_char = if opts.delimiter == "", do: 0, else: :binary.first(opts.delimiter)

        cond do
          char == delim_char ->
            {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), true}

          not opts.raw and char == ?\\ ->
            case read(1) do
              {:ok, <<?\n>>} ->
                read_until_delim_loop(opts, acc)

              {:ok, <<next>>} ->
                read_until_delim_loop(opts, [<<next>> | acc])

              _ ->
                {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), false}
            end

          true ->
            read_until_delim_loop(opts, [<<char>> | acc])
        end

      _ ->
        if acc == [],
          do: :eof,
          else: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), false}
    end
  end

  defp read_from_device(device, opts) do
    cond do
      opts.nchars != nil -> read_nchars_from_device(device, opts)
      opts.delimiter != "\n" -> read_until_delimiter_from_device(device, opts)
      true -> read_line_from_device(device, opts)
    end
  end

  defp read_line_from_device(device, opts) do
    case IO.binread(device, :line) do
      :eof ->
        :eof

      {:error, reason} ->
        {:error, "#{inspect(reason)}"}

      data ->
        {line, found_newline} = strip_trailing_newline(data)

        if not opts.raw,
          do: read_device_continuations(device, line, found_newline),
          else: {:ok, line, found_newline}
    end
  end

  defp read_device_continuations(device, line, found_newline) do
    if String.ends_with?(line, "\\") and found_newline do
      continued = String.slice(line, 0, byte_size(line) - 1)

      case IO.binread(device, :line) do
        :eof ->
          {:ok, continued, false}

        {:error, _} ->
          {:ok, continued, false}

        next_data ->
          {next_line, next_found} = strip_trailing_newline(next_data)
          read_device_continuations(device, continued <> next_line, next_found)
      end
    else
      {:ok, line, found_newline}
    end
  end

  defp read_nchars_from_device(device, opts) do
    if opts.nchars == 0 do
      {:ok, "", true}
    else
      case IO.binread(device, opts.nchars) do
        :eof -> :eof
        {:error, reason} -> {:error, "#{inspect(reason)}"}
        data -> {:ok, data, byte_size(data) >= opts.nchars}
      end
    end
  end

  defp read_until_delimiter_from_device(device, opts),
    do: read_device_delim_loop(device, opts, [])

  defp read_device_delim_loop(device, opts, acc) do
    case IO.binread(device, 1) do
      :eof ->
        if acc == [],
          do: :eof,
          else: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), false}

      {:error, _} ->
        if acc == [],
          do: :eof,
          else: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), false}

      <<char>> ->
        delim_char = if opts.delimiter == "", do: 0, else: :binary.first(opts.delimiter)

        cond do
          char == delim_char ->
            {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), true}

          not opts.raw and char == ?\\ ->
            case IO.binread(device, 1) do
              :eof ->
                {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), false}

              <<?\n>> ->
                read_device_delim_loop(device, opts, acc)

              <<next>> ->
                read_device_delim_loop(device, opts, [<<next>> | acc])

              _ ->
                {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), false}
            end

          true ->
            read_device_delim_loop(device, opts, [<<char>> | acc])
        end
    end
  end

  defp strip_trailing_newline(data) do
    if String.ends_with?(data, "\n"),
      do: {String.trim_trailing(data, "\n"), true},
      else: {data, false}
  end

  defp get_ifs(session_state) do
    case Map.get(session_state.variables, "IFS") do
      nil -> @default_ifs
      %Variable{value: val} when is_binary(val) -> val
      _ -> @default_ifs
    end
  end

  defp build_eof_updates(opts, var_names, session_state) do
    if opts.array do
      %{opts.array => Variable.new_indexed_array(%{})}
    else
      names = if Enum.empty?(var_names), do: ["REPLY"], else: var_names
      build_empty_vars(names, session_state)
    end
  end

  defp build_empty_vars(names, session_state) do
    Enum.reduce(names, %{}, fn name, acc ->
      existing = Map.get(session_state.variables, name)

      if existing && Variable.readonly?(existing),
        do: acc,
        else: Map.put(acc, name, Variable.new(""))
    end)
  end

  defp build_var_updates(opts, var_names, line, ifs, session_state) do
    if opts.array do
      words = split_by_ifs(line, ifs, opts.raw, :unlimited)
      build_array_update(opts.array, words, session_state)
    else
      names = if Enum.empty?(var_names), do: ["REPLY"], else: var_names

      if Enum.empty?(var_names) do
        value = if opts.raw, do: line, else: process_escapes(line)
        assign_words_to_names(names, [value], session_state)
      else
        assign_split_to_names(names, line, ifs, opts.raw, session_state)
      end
    end
  end

  defp assign_split_to_names(names, line, ifs, raw, session_state) do
    num_names = length(names)

    if num_names == 1 do
      value = trim_ifs_whitespace_only(line, ifs, raw)
      assign_words_to_names(names, [value], session_state)
    else
      words = split_by_ifs(line, ifs, raw, num_names)
      num_words = length(words)

      cond do
        num_words == 0 ->
          build_empty_vars(names, session_state)

        num_words <= num_names ->
          words_padded = words ++ List.duplicate("", num_names - num_words)
          assign_words_to_names(names, words_padded, session_state)

        true ->
          {first_words, rest_words} = Enum.split(words, num_names - 1)
          last_word = Enum.join(rest_words, " ")
          assign_words_to_names(names, first_words ++ [last_word], session_state)
      end
    end
  end

  defp trim_ifs_whitespace_only(str, ifs, raw) do
    if ifs == "" do
      if raw, do: str, else: process_escapes(str)
    else
      ifs_ws = for <<c <- ifs>>, c in [?\s, ?\t, ?\n], do: c

      trimmed =
        str
        |> skip_leading_ifs_ws(ifs_ws)
        |> strip_trailing_ifs_ws(ifs_ws)

      if raw, do: trimmed, else: process_escapes(trimmed)
    end
  end

  defp split_by_ifs(str, ifs, raw, max_fields) do
    if ifs == "" do
      [if(raw, do: str, else: process_escapes(str))]
    else
      ifs_ws = for <<c <- ifs>>, c in [?\s, ?\t, ?\n], do: c
      ifs_nws = for <<c <- ifs>>, c not in [?\s, ?\t, ?\n], do: c
      do_ifs_split(str, ifs_ws, ifs_nws, raw, max_fields)
    end
  end

  defp do_ifs_split(str, ifs_ws, ifs_nws, raw, max_fields) do
    str = skip_leading_ifs_ws(str, ifs_ws)
    do_ifs_split_loop(str, ifs_ws, ifs_nws, raw, max_fields, [], [])
  end

  defp do_ifs_split_loop("", _ws, _nws, _raw, _max, [], words),
    do: Enum.reverse(words)

  defp do_ifs_split_loop("", _ws, _nws, _raw, _max, current, words) do
    word = current |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([word | words])
  end

  defp do_ifs_split_loop(str, ifs_ws, ifs_nws, raw, max_fields, current, words) do
    word_count = length(words) + if(current != [], do: 1, else: 0)

    case max_fields do
      n when is_integer(n) and word_count >= n ->
        remaining = current |> Enum.reverse() |> IO.iodata_to_binary()
        rest = if raw, do: str, else: process_escapes(str)
        last_value = strip_trailing_ifs_ws(remaining <> rest, ifs_ws)
        Enum.reverse([last_value | words])

      _ ->
        split_next_char(str, ifs_ws, ifs_nws, raw, max_fields, current, words)
    end
  end

  defp split_next_char(<<char, rest::binary>>, ifs_ws, ifs_nws, raw, max_fields, current, words) do
    cond do
      not raw and char == ?\\ ->
        case rest do
          <<next, rest2::binary>> ->
            do_ifs_split_loop(
              rest2,
              ifs_ws,
              ifs_nws,
              raw,
              max_fields,
              [<<next>> | current],
              words
            )

          "" ->
            do_ifs_split_loop("", ifs_ws, ifs_nws, raw, max_fields, current, words)
        end

      char in ifs_ws ->
        case current do
          [] ->
            remaining = skip_leading_ifs_ws(rest, ifs_ws)
            do_ifs_split_loop(remaining, ifs_ws, ifs_nws, raw, max_fields, [], words)

          _ ->
            word = current |> Enum.reverse() |> IO.iodata_to_binary()
            new_words = [word | words]

            if at_max_fields?(max_fields, new_words) do
              last = strip_trailing_ifs_ws(if(raw, do: rest, else: process_escapes(rest)), ifs_ws)
              Enum.reverse([last | new_words])
            else
              remaining = skip_leading_ifs_ws(rest, ifs_ws)
              do_ifs_split_loop(remaining, ifs_ws, ifs_nws, raw, max_fields, [], new_words)
            end
        end

      char in ifs_nws ->
        word =
          case current do
            [] -> ""
            _ -> current |> Enum.reverse() |> IO.iodata_to_binary()
          end

        new_words = [word | words]

        if at_max_fields?(max_fields, new_words) do
          last = strip_trailing_ifs_ws(if(raw, do: rest, else: process_escapes(rest)), ifs_ws)
          Enum.reverse([last | new_words])
        else
          do_ifs_split_loop(rest, ifs_ws, ifs_nws, raw, max_fields, [], new_words)
        end

      true ->
        do_ifs_split_loop(rest, ifs_ws, ifs_nws, raw, max_fields, [<<char>> | current], words)
    end
  end

  defp at_max_fields?(:unlimited, _words), do: false
  defp at_max_fields?(n, words) when is_integer(n), do: length(words) >= n - 1

  defp skip_leading_ifs_ws("", _ws), do: ""

  defp skip_leading_ifs_ws(<<char, rest::binary>>, ifs_ws) do
    if char in ifs_ws,
      do: skip_leading_ifs_ws(rest, ifs_ws),
      else: <<char, rest::binary>>
  end

  defp strip_trailing_ifs_ws(str, []), do: str

  defp strip_trailing_ifs_ws(str, ifs_ws) do
    str
    |> String.reverse()
    |> skip_leading_ifs_ws(ifs_ws)
    |> String.reverse()
  end

  defp process_escapes(str), do: process_escapes(str, [])
  defp process_escapes("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp process_escapes("\\\n" <> rest, acc), do: process_escapes(rest, acc)

  defp process_escapes("\\" <> <<char, rest::binary>>, acc),
    do: process_escapes(rest, [<<char>> | acc])

  defp process_escapes("\\", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp process_escapes(<<char, rest::binary>>, acc),
    do: process_escapes(rest, [<<char>> | acc])

  defp build_array_update(array_name, words, session_state) do
    existing = Map.get(session_state.variables, array_name)

    if existing && Variable.readonly?(existing) do
      %{}
    else
      array_map =
        words
        |> Enum.with_index()
        |> Map.new(fn {word, idx} -> {idx, word} end)

      %{array_name => Variable.new_indexed_array(array_map)}
    end
  end

  defp assign_words_to_names(names, words, session_state) do
    num_names = length(names)
    num_words = length(words)

    padded =
      if num_words >= num_names,
        do: Enum.take(words, num_names),
        else: words ++ List.duplicate("", num_names - num_words)

    Enum.zip(names, padded)
    |> Enum.reduce(%{}, fn {name, word}, acc ->
      existing = Map.get(session_state.variables, name)

      if existing && Variable.readonly?(existing),
        do: acc,
        else: Map.put(acc, name, Variable.new(word))
    end)
  end
end
