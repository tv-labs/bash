defmodule Bash.Builtin.Echo do
  @moduledoc ~S"""
  `echo [-neE] [arg ...]`

  Output the ARGs.  If -n is specified, the trailing newline is suppressed.  If the -e option is given, interpretation of the following backslash-escaped characters is turned on:

  - `\a` - alert (bell)
  - `\b` - backspace
  - `\c` - suppress trailing newline
  - `\E` - escape character
  - `\f` - form feed
  - `\n` - new line
  - `\r` - carriage return
  - `\t` - horizontal tab
  - `\v` - vertical tab
  - `\\` - backslash
  - `\0nnn` -the character whose ASCII code is NNN (octal).  NNN can be 0 to 3 octal digits

  You can explicitly turn off the interpretation of the above characters with the -E option.
  """
  use Bash.Builtin

  defbash execute(args, _state) do
    {flags, text_args} = parse_flags(args)

    text = Enum.join(text_args, " ")

    # Apply escape sequence interpretation if enabled
    {text, suppress_output} =
      if flags.interpret_escapes do
        interpret_escapes(text)
      else
        {text, false}
      end

    cond do
      suppress_output -> write(text)
      flags.no_newline -> write(text)
      true -> puts(text)
    end

    :ok
  end

  # Parse echo flags (-n, -e, -E)
  defp parse_flags(args) do
    parse_flags(args, %{no_newline: false, interpret_escapes: false}, [])
  end

  defp parse_flags([], flags, acc) do
    {flags, Enum.reverse(acc)}
  end

  defp parse_flags(["-n" | rest], flags, acc) do
    parse_flags(rest, %{flags | no_newline: true}, acc)
  end

  defp parse_flags(["-e" | rest], flags, acc) do
    parse_flags(rest, %{flags | interpret_escapes: true}, acc)
  end

  defp parse_flags(["-E" | rest], flags, acc) do
    parse_flags(rest, %{flags | interpret_escapes: false}, acc)
  end

  defp parse_flags(["-" <> arg | rest], flags, acc) when byte_size(arg) > 0 do
    # Could be combined flags like "-ne"
    case parse_combined_flags(arg, flags) do
      {:ok, new_flags} ->
        parse_flags(rest, new_flags, acc)

      :error ->
        # Not valid flags, treat as regular argument
        {flags, Enum.reverse(acc, ["-" <> arg | rest])}
    end
  end

  defp parse_flags([arg | rest], flags, acc) do
    # Not a flag, rest are all arguments
    {flags, Enum.reverse(acc, [arg | rest])}
  end

  # Parse combined flags like "-ne" or "-en"
  # Input is the characters after the dash (e.g., "ne" for "-ne")
  defp parse_combined_flags(chars, flags) do
    chars
    |> String.graphemes()
    |> Enum.reduce_while({:ok, flags}, fn
      "n", {:ok, f} -> {:cont, {:ok, %{f | no_newline: true}}}
      "e", {:ok, f} -> {:cont, {:ok, %{f | interpret_escapes: true}}}
      "E", {:ok, f} -> {:cont, {:ok, %{f | interpret_escapes: false}}}
      _, _ -> {:halt, :error}
    end)
  end

  # Interpret backslash escape sequences
  # Returns {processed_string, suppress_remaining_output?}
  defp interpret_escapes(text) do
    interpret_escapes(text, [], false)
  end

  defp interpret_escapes("", acc, suppress) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), suppress}
  end

  defp interpret_escapes(<<"\\c", _rest::binary>>, acc, _suppress) do
    # \c suppresses further output including newline
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), true}
  end

  defp interpret_escapes(<<"\\a", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\a" | acc], suppress)
  end

  defp interpret_escapes(<<"\\b", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\b" | acc], suppress)
  end

  defp interpret_escapes(<<"\\e", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\e" | acc], suppress)
  end

  defp interpret_escapes(<<"\\E", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\e" | acc], suppress)
  end

  defp interpret_escapes(<<"\\f", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\f" | acc], suppress)
  end

  defp interpret_escapes(<<"\\n", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\n" | acc], suppress)
  end

  defp interpret_escapes(<<"\\r", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\r" | acc], suppress)
  end

  defp interpret_escapes(<<"\\t", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\t" | acc], suppress)
  end

  defp interpret_escapes(<<"\\v", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\v" | acc], suppress)
  end

  defp interpret_escapes(<<"\\\\", rest::binary>>, acc, suppress) do
    interpret_escapes(rest, ["\\" | acc], suppress)
  end

  # Octal: \0nnn (0-3 digits)
  defp interpret_escapes(<<"\\0", rest::binary>>, acc, suppress) do
    case parse_octal(rest) do
      {char, remaining} -> interpret_escapes(remaining, [<<char::utf8>> | acc], suppress)
      :error -> interpret_escapes(rest, ["\\0" | acc], suppress)
    end
  end

  # Hex: \xHH (1-2 hex digits)
  defp interpret_escapes(<<"\\x", rest::binary>>, acc, suppress) do
    case parse_hex(rest, 2) do
      {byte_value, remaining} when byte_value < 256 ->
        interpret_escapes(remaining, [<<byte_value::8>> | acc], suppress)

      :error ->
        interpret_escapes(rest, ["\\x" | acc], suppress)
    end
  end

  # Unicode: \uHHHH (1-4 hex digits)
  defp interpret_escapes(<<"\\u", rest::binary>>, acc, suppress) do
    case parse_hex(rest, 4) do
      {codepoint, remaining} ->
        interpret_escapes(remaining, [<<codepoint::utf8>> | acc], suppress)

      :error ->
        interpret_escapes(rest, ["\\u" | acc], suppress)
    end
  end

  # Unicode: \UHHHHHHHH (1-8 hex digits)
  defp interpret_escapes(<<"\\U", rest::binary>>, acc, suppress) do
    case parse_hex(rest, 8) do
      {codepoint, remaining} ->
        interpret_escapes(remaining, [<<codepoint::utf8>> | acc], suppress)

      :error ->
        interpret_escapes(rest, ["\\U" | acc], suppress)
    end
  end

  defp interpret_escapes(<<char, rest::binary>>, acc, suppress) do
    interpret_escapes(rest, [<<char>> | acc], suppress)
  end

  # Parse up to 3 octal digits
  defp parse_octal(str), do: parse_octal(str, 0, 0)

  defp parse_octal(<<digit, rest::binary>>, value, count)
       when digit >= ?0 and digit <= ?7 and count < 3 do
    parse_octal(rest, value * 8 + (digit - ?0), count + 1)
  end

  defp parse_octal(rest, value, count) when count > 0 do
    {value, rest}
  end

  defp parse_octal(_, _, _), do: :error

  # Parse hex digits (up to max_digits)
  defp parse_hex(str, max_digits), do: parse_hex(str, 0, 0, max_digits)

  defp parse_hex(<<digit, rest::binary>>, value, count, max)
       when count < max and digit >= ?0 and digit <= ?9 do
    parse_hex(rest, value * 16 + (digit - ?0), count + 1, max)
  end

  defp parse_hex(<<digit, rest::binary>>, value, count, max)
       when count < max and digit >= ?a and digit <= ?f do
    parse_hex(rest, value * 16 + (digit - ?a + 10), count + 1, max)
  end

  defp parse_hex(<<digit, rest::binary>>, value, count, max)
       when count < max and digit >= ?A and digit <= ?F do
    parse_hex(rest, value * 16 + (digit - ?A + 10), count + 1, max)
  end

  defp parse_hex(rest, value, count, _max) when count > 0 do
    {value, rest}
  end

  defp parse_hex(_, _, _, _), do: :error
end
