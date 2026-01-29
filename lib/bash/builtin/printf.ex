defmodule Bash.Builtin.Printf do
  @moduledoc """
  `printf [-v var] format [arguments]`

  printf formats and prints ARGUMENTS under control of the FORMAT. FORMAT is a character string which contains three types of objects: plain characters, which are simply copied to standard output, character escape sequences which are converted and copied to the standard output, and format specifications, each of which causes printing of the next successive argument. In addition to the standard printf(1) formats, %b means to expand backslash escape sequences in the corresponding argument, and %q means to quote the argument in a way that can be reused as shell input. If the -v option is supplied, the output is placed into the value of the shell variable VAR rather than being sent to the standard output.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/printf.def?h=bash-5.3

  ## Examples

      printf "Hello %s\\n" "World"
      # => Hello World

      printf "Count: %d\\n" 42
      # => Count: 42

      printf "=%.0s" 1 2 3
      # => ===

  """
  use Bash.Builtin

  alias Bash.Variable

  # Execute the printf builtin command.
  @doc false
  defbash execute(args, _state) do
    case parse_args(args) do
      {:ok, var_name, format, arguments} ->
        case format_string(format, arguments) do
          {:ok, output} ->
            if var_name do
              # -v option: assign to variable instead of printing
              var = Variable.new(output)
              update_state(var_updates: %{var_name => var})
            else
              write(output)
            end

            :ok

          {:error, message} ->
            error("printf: " <> message)
            {:ok, 1}
        end

      {:error, message} ->
        error("printf: " <> message)
        {:ok, 1}
    end
  end

  # Parse arguments, extracting -v option if present
  defp parse_args([]), do: {:error, "usage: printf [-v var] format [arguments]"}
  defp parse_args(["-v"]), do: {:error, "-v: option requires an argument"}

  defp parse_args(["-v", var_name | rest]) when rest != [],
    do: {:ok, var_name, hd(rest), tl(rest)}

  defp parse_args(["-v", _var_name]), do: {:error, "usage: printf [-v var] format [arguments]"}
  defp parse_args([format | args]), do: {:ok, nil, format, args}

  # Format a string with the given arguments, repeating the format if necessary.
  @doc false
  def format_string(format, arguments) do
    # First, process escape sequences in the format string
    format = process_escapes(format)

    # Parse the format string to find format specifiers
    {segments, spec_count} = parse_format(format)

    if spec_count == 0 do
      # No format specifiers, just output the format string once
      {:ok, format}
    else
      # Format with arguments, repeating as needed
      format_with_args(segments, arguments, spec_count, [])
    end
  end

  # Process escape sequences in the format string
  defp process_escapes(string) do
    string
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\a", "\a")
    |> String.replace("\\b", "\b")
    |> String.replace("\\f", "\f")
    |> String.replace("\\v", "\v")
    |> String.replace("\\\\", "\x00BACKSLASH\x00")
    |> String.replace("\\e", "\e")
    |> String.replace("\\033", "\e")
    |> String.replace("\\x1b", "\e")
    |> String.replace("\\x1B", "\e")
    |> process_octal_escapes()
    |> process_hex_escapes()
    |> String.replace("\x00BACKSLASH\x00", "\\")
  end

  # Process octal escapes like \0123
  defp process_octal_escapes(string) do
    Regex.replace(~r/\\0([0-7]{0,3})/, string, fn _, digits ->
      case digits do
        "" -> <<0>>
        _ -> <<String.to_integer(digits, 8)>>
      end
    end)
  end

  # Process hex escapes like \x1B
  defp process_hex_escapes(string) do
    Regex.replace(~r/\\x([0-9a-fA-F]{1,2})/, string, fn _, digits ->
      <<String.to_integer(digits, 16)::utf8>>
    end)
  end

  # Parse format string into segments (literal strings and format specs)
  defp parse_format(format) do
    parse_format(format, [], 0)
  end

  defp parse_format("", acc, count), do: {Enum.reverse(acc), count}

  defp parse_format("%%" <> rest, acc, count) do
    parse_format(rest, [{:literal, "%"} | acc], count)
  end

  defp parse_format("%" <> rest, acc, count) do
    case parse_format_spec(rest) do
      {:ok, spec, remaining} ->
        parse_format(remaining, [{:spec, spec} | acc], count + 1)

      :error ->
        # Invalid format spec, treat % as literal
        parse_format(rest, [{:literal, "%"} | acc], count)
    end
  end

  defp parse_format(<<c::utf8, rest::binary>>, acc, count) do
    case acc do
      [{:literal, str} | rest_acc] ->
        parse_format(rest, [{:literal, str <> <<c::utf8>>} | rest_acc], count)

      _ ->
        parse_format(rest, [{:literal, <<c::utf8>>} | acc], count)
    end
  end

  # Parse a format specifier after the %
  # Returns {:ok, spec_map, remaining_string} or :error
  defp parse_format_spec(string) do
    # Format: %[flags][width][.precision]specifier
    {flags, rest} = parse_flags(string)
    {width, rest} = parse_width(rest)
    {precision, rest} = parse_precision(rest)

    case parse_specifier(rest) do
      {:ok, specifier, remaining} ->
        {:ok, %{flags: flags, width: width, precision: precision, specifier: specifier},
         remaining}

      :error ->
        :error
    end
  end

  # Parse flags: -, +, space, #, 0
  defp parse_flags(string), do: parse_flags(string, [])

  defp parse_flags("-" <> rest, acc), do: parse_flags(rest, [:minus | acc])
  defp parse_flags("+" <> rest, acc), do: parse_flags(rest, [:plus | acc])
  defp parse_flags(" " <> rest, acc), do: parse_flags(rest, [:space | acc])
  defp parse_flags("#" <> rest, acc), do: parse_flags(rest, [:hash | acc])
  defp parse_flags("0" <> rest, acc), do: parse_flags(rest, [:zero | acc])
  defp parse_flags(rest, acc), do: {acc, rest}

  # Parse width (digits or *)
  defp parse_width("*" <> rest), do: {:dynamic, rest}

  defp parse_width(string) do
    case Integer.parse(string) do
      {width, rest} -> {width, rest}
      :error -> {nil, string}
    end
  end

  # Parse precision (.digits or .*)
  defp parse_precision(".*" <> rest), do: {:dynamic, rest}

  defp parse_precision("." <> rest) do
    case Integer.parse(rest) do
      {precision, remaining} -> {precision, remaining}
      :error -> {0, rest}
    end
  end

  defp parse_precision(rest), do: {nil, rest}

  # Parse the specifier character
  defp parse_specifier("s" <> rest), do: {:ok, :string, rest}
  defp parse_specifier("d" <> rest), do: {:ok, :decimal, rest}
  defp parse_specifier("i" <> rest), do: {:ok, :decimal, rest}
  defp parse_specifier("o" <> rest), do: {:ok, :octal, rest}
  defp parse_specifier("x" <> rest), do: {:ok, :hex_lower, rest}
  defp parse_specifier("X" <> rest), do: {:ok, :hex_upper, rest}
  defp parse_specifier("f" <> rest), do: {:ok, :float, rest}
  defp parse_specifier("e" <> rest), do: {:ok, :scientific_lower, rest}
  defp parse_specifier("E" <> rest), do: {:ok, :scientific_upper, rest}
  defp parse_specifier("g" <> rest), do: {:ok, :general_lower, rest}
  defp parse_specifier("G" <> rest), do: {:ok, :general_upper, rest}
  defp parse_specifier("c" <> rest), do: {:ok, :char, rest}
  defp parse_specifier("b" <> rest), do: {:ok, :escape_string, rest}
  defp parse_specifier("q" <> rest), do: {:ok, :quoted, rest}
  defp parse_specifier(_), do: :error

  # Format with arguments, repeating the format as needed
  defp format_with_args(_segments, [], _spec_count, acc) do
    {:ok, acc |> Enum.reverse() |> Enum.join("")}
  end

  defp format_with_args(segments, args, spec_count, acc) do
    {output, remaining_args} = format_once(segments, args)
    new_acc = [output | acc]

    if remaining_args == [] do
      {:ok, new_acc |> Enum.reverse() |> Enum.join("")}
    else
      format_with_args(segments, remaining_args, spec_count, new_acc)
    end
  end

  # Format the segments once, consuming arguments as needed
  defp format_once(segments, args) do
    format_once(segments, args, [])
  end

  defp format_once([], args, acc) do
    {acc |> Enum.reverse() |> Enum.join(""), args}
  end

  defp format_once([{:literal, str} | rest], args, acc) do
    format_once(rest, args, [str | acc])
  end

  defp format_once([{:spec, spec} | rest], args, acc) do
    {arg, remaining_args} =
      case args do
        [a | r] -> {a, r}
        [] -> {"", []}
      end

    formatted = format_arg(spec, arg)
    format_once(rest, remaining_args, [formatted | acc])
  end

  # Format a single argument according to the spec
  defp format_arg(%{specifier: :string} = spec, arg) do
    str = to_string(arg)
    apply_width_precision(str, spec)
  end

  defp format_arg(%{specifier: :decimal} = spec, arg) do
    num = parse_number(arg)
    str = Integer.to_string(num)
    apply_numeric_format(str, num, spec)
  end

  defp format_arg(%{specifier: :octal} = spec, arg) do
    num = parse_number(arg)
    str = Integer.to_string(num, 8)
    prefix = if :hash in spec.flags and num != 0, do: "0", else: ""
    apply_numeric_format(prefix <> str, num, spec)
  end

  defp format_arg(%{specifier: :hex_lower} = spec, arg) do
    num = parse_number(arg)
    str = Integer.to_string(num, 16) |> String.downcase()
    prefix = if :hash in spec.flags and num != 0, do: "0x", else: ""
    apply_numeric_format(prefix <> str, num, spec)
  end

  defp format_arg(%{specifier: :hex_upper} = spec, arg) do
    num = parse_number(arg)
    str = Integer.to_string(num, 16) |> String.upcase()
    prefix = if :hash in spec.flags and num != 0, do: "0X", else: ""
    apply_numeric_format(prefix <> str, num, spec)
  end

  defp format_arg(%{specifier: :float} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6
    str = :erlang.float_to_binary(num * 1.0, decimals: precision)
    apply_numeric_format(str, num, spec)
  end

  defp format_arg(%{specifier: :scientific_lower} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6

    str =
      :erlang.float_to_binary(num * 1.0, [:scientific, {:decimals, precision}])
      |> String.downcase()

    apply_numeric_format(str, num, spec)
  end

  defp format_arg(%{specifier: :scientific_upper} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6

    str =
      :erlang.float_to_binary(num * 1.0, [:scientific, {:decimals, precision}]) |> String.upcase()

    apply_numeric_format(str, num, spec)
  end

  defp format_arg(%{specifier: :general_lower} = spec, arg) do
    # %g uses shorter of %e or %f
    num = parse_float(arg)
    precision = spec.precision || 6
    str = :erlang.float_to_binary(num * 1.0, [{:decimals, precision}, :compact])
    apply_numeric_format(str, num, spec)
  end

  defp format_arg(%{specifier: :general_upper} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6

    str =
      :erlang.float_to_binary(num * 1.0, [{:decimals, precision}, :compact]) |> String.upcase()

    apply_numeric_format(str, num, spec)
  end

  defp format_arg(%{specifier: :char}, arg) do
    str = to_string(arg)

    case str do
      "" -> ""
      _ -> String.first(str)
    end
  end

  defp format_arg(%{specifier: :escape_string} = spec, arg) do
    str = to_string(arg) |> process_escapes()
    apply_width_precision(str, spec)
  end

  defp format_arg(%{specifier: :quoted} = spec, arg) do
    str = to_string(arg) |> quote_for_shell()
    apply_width_precision(str, spec)
  end

  # Apply width and precision to a string
  defp apply_width_precision(str, spec) do
    str =
      case spec.precision do
        nil -> str
        :dynamic -> str
        n when is_integer(n) -> String.slice(str, 0, n)
      end

    apply_width(str, spec)
  end

  # Apply width and padding
  defp apply_width(str, spec) do
    case spec.width do
      nil ->
        str

      :dynamic ->
        str

      width when is_integer(width) ->
        len = String.length(str)

        if len >= width do
          str
        else
          padding = String.duplicate(" ", width - len)

          if :minus in spec.flags do
            str <> padding
          else
            padding <> str
          end
        end
    end
  end

  # Apply numeric formatting (sign, padding)
  defp apply_numeric_format(str, num, spec) do
    str =
      cond do
        num < 0 -> str
        :plus in spec.flags -> "+" <> str
        :space in spec.flags -> " " <> str
        true -> str
      end

    case spec.width do
      nil ->
        str

      :dynamic ->
        str

      width when is_integer(width) ->
        len = String.length(str)

        if len >= width do
          str
        else
          if :zero in spec.flags and :minus not in spec.flags do
            # Zero padding
            {sign, rest} =
              case str do
                "+" <> r -> {"+", r}
                "-" <> r -> {"-", r}
                " " <> r -> {" ", r}
                r -> {"", r}
              end

            sign <> String.duplicate("0", width - len) <> rest
          else
            apply_width(str, spec)
          end
        end
    end
  end

  # Parse a string as an integer
  defp parse_number(arg) when is_integer(arg), do: arg

  defp parse_number(arg) do
    str = to_string(arg) |> String.trim()

    cond do
      str == "" ->
        0

      String.starts_with?(str, "0x") or String.starts_with?(str, "0X") ->
        case Integer.parse(String.slice(str, 2..-1//1), 16) do
          {n, _} -> n
          :error -> 0
        end

      String.starts_with?(str, "0") and String.length(str) > 1 ->
        case Integer.parse(String.slice(str, 1..-1//1), 8) do
          {n, _} -> n
          :error -> 0
        end

      true ->
        case Integer.parse(str) do
          {n, _} -> n
          :error -> 0
        end
    end
  end

  defp parse_float(arg) when is_float(arg), do: arg
  defp parse_float(arg) when is_integer(arg), do: arg * 1.0

  defp parse_float(arg) do
    str = to_string(arg) |> String.trim()

    case Float.parse(str) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp quote_for_shell(str) do
    if String.match?(str, ~r/^[a-zA-Z0-9_\-\.\/]+$/) do
      str
    else
      "'" <> String.replace(str, "'", "'\\''") <> "'"
    end
  end
end
