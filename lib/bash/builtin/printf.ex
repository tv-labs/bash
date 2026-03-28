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

  @unsigned_modulus 18_446_744_073_709_551_616

  @doc false
  defbash execute(args, _state) do
    case parse_args(args) do
      {:ok, var_name, format, arguments} ->
        case format_string(format, arguments) do
          {:ok, output, had_error} ->
            if var_name do
              var = Variable.new(output)
              update_state(variables: %{var_name => var})
            else
              write(output)
            end

            if had_error, do: {:ok, 1}, else: :ok

          {:error, message} ->
            error("printf: " <> message)
            {:ok, 1}
        end

      {:error, exit_code, message} ->
        error("printf: " <> message)
        {:ok, exit_code}

      {:error, message} ->
        error("printf: " <> message)
        {:ok, 1}
    end
  end

  defp parse_args([]), do: {:error, 2, "usage: printf [-v var] format [arguments]"}
  defp parse_args(["-v"]), do: {:error, "-v: option requires an argument"}

  defp parse_args(["-v", var_name | rest]) when rest != [],
    do: {:ok, var_name, hd(rest), tl(rest)}

  defp parse_args(["-v", _var_name]), do: {:error, 2, "usage: printf [-v var] format [arguments]"}
  defp parse_args(["--" | rest]) when rest != [], do: {:ok, nil, hd(rest), tl(rest)}
  defp parse_args(["--"]), do: {:error, 2, "usage: printf [-v var] format [arguments]"}
  defp parse_args([format | args]), do: {:ok, nil, format, args}

  @doc false
  def format_string(format, arguments) do
    format = process_escapes(format)
    {segments, spec_count} = parse_format(format)

    if spec_count == 0 do
      {:ok, format, false}
    else
      format_with_args(segments, arguments, spec_count, [], false)
    end
  end

  defp process_escapes(string) do
    string
    |> String.replace("\\\\", "\x00BACKSLASH\x00")
    |> process_unicode_escapes()
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\a", "\a")
    |> String.replace("\\b", "\b")
    |> String.replace("\\f", "\f")
    |> String.replace("\\v", "\v")
    |> String.replace("\\e", "\e")
    |> String.replace("\\033", "\e")
    |> process_octal_escapes()
    |> process_hex_escapes()
    |> String.replace("\x00BACKSLASH\x00", "\\")
  end

  defp process_unicode_escapes(string) do
    string
    |> process_big_unicode_escapes()
    |> process_small_unicode_escapes()
  end

  defp process_small_unicode_escapes(string) do
    Regex.replace(~r/\\u([0-9a-fA-F]{1,4})/, string, fn _, digits ->
      <<String.to_integer(digits, 16)::utf8>>
    end)
  end

  defp process_big_unicode_escapes(string) do
    Regex.replace(~r/\\U([0-9a-fA-F]{1,8})/, string, fn _, digits ->
      <<String.to_integer(digits, 16)::utf8>>
    end)
  end

  defp process_octal_escapes(string) do
    Regex.replace(~r/\\0([0-7]{0,3})/, string, fn _, digits ->
      case digits do
        "" -> <<0>>
        _ -> <<String.to_integer(digits, 8)::size(8)>>
      end
    end)
  end

  defp process_hex_escapes(string) do
    Regex.replace(~r/\\x([0-9a-fA-F]{1,2})/, string, fn _, digits ->
      <<String.to_integer(digits, 16)::size(8)>>
    end)
  end

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

  defp parse_format(<<byte::size(8), rest::binary>>, acc, count) do
    case acc do
      [{:literal, str} | rest_acc] ->
        parse_format(rest, [{:literal, str <> <<byte>>} | rest_acc], count)

      _ ->
        parse_format(rest, [{:literal, <<byte>>} | acc], count)
    end
  end

  defp parse_format_spec(string) do
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

  defp parse_flags(string), do: parse_flags(string, [])

  defp parse_flags("-" <> rest, acc), do: parse_flags(rest, [:minus | acc])
  defp parse_flags("+" <> rest, acc), do: parse_flags(rest, [:plus | acc])
  defp parse_flags(" " <> rest, acc), do: parse_flags(rest, [:space | acc])
  defp parse_flags("#" <> rest, acc), do: parse_flags(rest, [:hash | acc])
  defp parse_flags("0" <> rest, acc), do: parse_flags(rest, [:zero | acc])
  defp parse_flags(rest, acc), do: {acc, rest}

  defp parse_width("*" <> rest), do: {:dynamic, rest}

  defp parse_width(string) do
    case Integer.parse(string) do
      {width, rest} -> {width, rest}
      :error -> {nil, string}
    end
  end

  defp parse_precision(".*" <> rest), do: {:dynamic, rest}

  defp parse_precision("." <> rest) do
    case Integer.parse(rest) do
      {precision, remaining} -> {precision, remaining}
      :error -> {0, rest}
    end
  end

  defp parse_precision(rest), do: {nil, rest}

  defp parse_specifier("s" <> rest), do: {:ok, :string, rest}
  defp parse_specifier("d" <> rest), do: {:ok, :decimal, rest}
  defp parse_specifier("i" <> rest), do: {:ok, :decimal, rest}
  defp parse_specifier("u" <> rest), do: {:ok, :unsigned, rest}
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

  defp format_with_args(_segments, [], _spec_count, acc, had_error) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), had_error}
  end

  defp format_with_args(segments, args, spec_count, acc, had_error) do
    {output, remaining_args, iteration_error} = format_once(segments, args)
    new_acc = [output | acc]
    new_error = had_error or iteration_error

    if remaining_args == [] do
      {:ok, new_acc |> Enum.reverse() |> IO.iodata_to_binary(), new_error}
    else
      format_with_args(segments, remaining_args, spec_count, new_acc, new_error)
    end
  end

  defp format_once(segments, args) do
    format_once(segments, args, [], false)
  end

  defp format_once([], args, acc, had_error) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), args, had_error}
  end

  defp format_once([{:literal, str} | rest], args, acc, had_error) do
    format_once(rest, args, [str | acc], had_error)
  end

  defp format_once([{:spec, spec} | rest], args, acc, had_error) do
    {arg, remaining_args} =
      case args do
        [a | r] -> {a, r}
        [] -> {default_for_spec(spec.specifier), []}
      end

    {formatted, arg_error} = format_arg(spec, arg)
    format_once(rest, remaining_args, [formatted | acc], had_error or arg_error)
  end

  defp default_for_spec(spec) when spec in [:string, :escape_string, :quoted, :char], do: ""
  defp default_for_spec(_), do: "0"

  defp format_arg(%{specifier: :string} = spec, arg) do
    str = to_string(arg)
    {apply_width_precision(str, spec), false}
  end

  defp format_arg(%{specifier: :decimal} = spec, arg) do
    {num, err} = parse_number(arg)
    str = format_decimal_with_precision(num, spec.precision)
    {apply_numeric_format(str, num, spec), err}
  end

  defp format_arg(%{specifier: :unsigned} = spec, arg) do
    {num, err} = parse_number(arg)
    num = to_unsigned(num)
    str = Integer.to_string(num)
    str = apply_integer_precision(str, spec.precision)
    {apply_numeric_format(str, num, spec), err}
  end

  defp format_arg(%{specifier: :octal} = spec, arg) do
    {num, err} = parse_number(arg)
    unsigned = to_unsigned(num)
    str = Integer.to_string(unsigned, 8)
    str = apply_integer_precision(str, spec.precision)
    prefix = if :hash in spec.flags and unsigned != 0, do: "0", else: ""
    {apply_numeric_format(prefix <> str, unsigned, spec), err}
  end

  defp format_arg(%{specifier: :hex_lower} = spec, arg) do
    {num, err} = parse_number(arg)
    unsigned = to_unsigned(num)
    str = Integer.to_string(unsigned, 16) |> String.downcase()
    str = apply_integer_precision(str, spec.precision)
    prefix = if :hash in spec.flags and unsigned != 0, do: "0x", else: ""
    {apply_numeric_format(prefix <> str, unsigned, spec), err}
  end

  defp format_arg(%{specifier: :hex_upper} = spec, arg) do
    {num, err} = parse_number(arg)
    unsigned = to_unsigned(num)
    str = Integer.to_string(unsigned, 16) |> String.upcase()
    str = apply_integer_precision(str, spec.precision)
    prefix = if :hash in spec.flags and unsigned != 0, do: "0X", else: ""
    {apply_numeric_format(prefix <> str, unsigned, spec), err}
  end

  defp format_arg(%{specifier: :float} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6

    str =
      if :hash in spec.flags and precision == 0 do
        :erlang.float_to_binary(num * 1.0, decimals: 0) <> "."
      else
        :erlang.float_to_binary(num * 1.0, decimals: precision)
      end

    {apply_numeric_format(str, num, spec), false}
  end

  defp format_arg(%{specifier: :scientific_lower} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6
    str = format_scientific(num * 1.0, precision) |> String.downcase()
    {apply_numeric_format(str, num, spec), false}
  end

  defp format_arg(%{specifier: :scientific_upper} = spec, arg) do
    num = parse_float(arg)
    precision = spec.precision || 6
    str = format_scientific(num * 1.0, precision) |> String.upcase()
    {apply_numeric_format(str, num, spec), false}
  end

  defp format_arg(%{specifier: :general_lower} = spec, arg) do
    num = parse_float(arg)
    precision = max(spec.precision || 6, 1)
    str = format_general(num * 1.0, precision, :hash in spec.flags)
    {apply_numeric_format(str, num, spec), false}
  end

  defp format_arg(%{specifier: :general_upper} = spec, arg) do
    num = parse_float(arg)
    precision = max(spec.precision || 6, 1)
    str = format_general(num * 1.0, precision, :hash in spec.flags) |> String.upcase()
    {apply_numeric_format(str, num, spec), false}
  end

  defp format_arg(%{specifier: :char}, arg) do
    str = to_string(arg)

    result =
      case str do
        "" -> ""
        _ -> String.first(str)
      end

    {result, false}
  end

  defp format_arg(%{specifier: :escape_string} = spec, arg) do
    str = to_string(arg) |> process_b_escapes()
    {apply_width_precision(str, spec), false}
  end

  defp format_arg(%{specifier: :quoted} = spec, arg) do
    str = to_string(arg) |> quote_for_shell()
    {apply_width_precision(str, spec), false}
  end

  defp format_decimal_with_precision(num, precision) do
    abs_str = Integer.to_string(abs(num))

    abs_str =
      case precision do
        nil ->
          abs_str

        p when is_integer(p) and p > 0 ->
          String.pad_leading(abs_str, p, "0")

        0 ->
          abs_str

        _ ->
          abs_str
      end

    if num < 0, do: "-" <> abs_str, else: abs_str
  end

  defp apply_integer_precision(str, nil), do: str
  defp apply_integer_precision(str, :dynamic), do: str

  defp apply_integer_precision(str, p) when is_integer(p) and p > 0 do
    String.pad_leading(str, p, "0")
  end

  defp apply_integer_precision(str, _), do: str

  defp to_unsigned(num) when num >= 0, do: num

  defp to_unsigned(num) do
    Integer.mod(num, @unsigned_modulus)
  end

  defp apply_width_precision(str, spec) do
    str =
      case spec.precision do
        nil -> str
        :dynamic -> str
        n when is_integer(n) -> String.slice(str, 0, n)
      end

    apply_width(str, spec)
  end

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
          if :zero in spec.flags and :minus not in spec.flags and spec.precision == nil do
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

  defp format_scientific(num, precision) do
    :io_lib.format("~.*e", [precision, num]) |> IO.iodata_to_binary()
  end

  defp format_general(num, precision, hash_flag) do
    # %g: use %e if exponent < -4 or >= precision, else %f
    # Then strip trailing zeros (unless # flag)
    sci = :io_lib.format("~.*e", [precision - 1, num]) |> IO.iodata_to_binary()

    exp =
      case Regex.run(~r/[eE]([+-]?\d+)$/, sci) do
        [_, exp_str] -> String.to_integer(exp_str)
        _ -> 0
      end

    result =
      if exp < -4 or exp >= precision do
        sci
      else
        frac_digits = max(precision - exp - 1, 0)
        :erlang.float_to_binary(num, decimals: frac_digits)
      end

    if hash_flag do
      result
    else
      strip_trailing_zeros(result)
    end
  end

  defp strip_trailing_zeros(str) do
    if String.contains?(str, ".") do
      str
      |> String.replace(~r/0+$/, "")
      |> String.replace(~r/\.$/, "")
    else
      str
    end
  end

  defp parse_number(arg) when is_integer(arg), do: {arg, false}

  defp parse_number(arg) do
    str = to_string(arg) |> String.trim_leading()

    cond do
      str == "" ->
        {0, false}

      String.starts_with?(str, "'") or String.starts_with?(str, "\"") ->
        parse_char_code(String.slice(str, 1..-1//1))

      true ->
        {sign, rest} = extract_sign(str)
        parse_number_value(rest, sign)
    end
  end

  defp extract_sign("+" <> rest), do: {1, rest}
  defp extract_sign("-" <> rest), do: {-1, rest}
  defp extract_sign(rest), do: {1, rest}

  defp parse_number_value(str, sign) do
    cond do
      String.starts_with?(str, "0x") or String.starts_with?(str, "0X") ->
        hex_part = String.slice(str, 2..-1//1)

        case Integer.parse(hex_part, 16) do
          {n, ""} -> {sign * n, false}
          {n, rest} -> {sign * n, has_trailing_content?(rest)}
          :error -> {0, true}
        end

      String.starts_with?(str, "0") and byte_size(str) > 1 ->
        octal_part = String.slice(str, 1..-1//1)

        case Integer.parse(octal_part, 8) do
          {n, ""} -> {sign * n, false}
          {n, rest} -> {sign * n, has_trailing_content?(rest)}
          :error -> {0, true}
        end

      true ->
        case Integer.parse(str) do
          {n, ""} -> {sign * n, false}
          {n, rest} -> {sign * n, has_trailing_content?(rest)}
          :error -> {0, true}
        end
    end
  end

  defp has_trailing_content?(rest) do
    String.trim(rest) != ""
  end

  defp parse_char_code("") do
    {0, false}
  end

  defp parse_char_code(str) do
    case String.next_codepoint(str) do
      {char, _rest} ->
        <<code::utf8>> = char
        {code, false}

      nil ->
        {0, false}
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

  defp quote_for_shell(""), do: "''"

  defp quote_for_shell(str) do
    if String.match?(str, ~r/^[a-zA-Z0-9@%_+=:,.\/-]+$/) do
      str
    else
      "$'" <> escape_for_dollar_single_quote(str) <> "'"
    end
  end

  defp escape_for_dollar_single_quote(str) do
    str
    |> String.to_charlist()
    |> Enum.map(fn
      ?\\ -> "\\\\"
      ?' -> "\\'"
      ?\n -> "\\n"
      ?\t -> "\\t"
      ?\r -> "\\r"
      ?\a -> "\\a"
      ?\b -> "\\b"
      ?\f -> "\\f"
      ?\v -> "\\v"
      ?\e -> "\\E"
      c when c >= 0x20 and c <= 0x7E -> <<c>>
      c when c > 0x7E -> <<c::utf8>>
      c -> "\\x" <> String.pad_leading(Integer.to_string(c, 16), 2, "0")
    end)
    |> IO.iodata_to_binary()
  end

  defp process_b_escapes(string) do
    process_b_escapes(string, [])
  end

  defp process_b_escapes("", acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp process_b_escapes("\\c" <> _rest, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp process_b_escapes("\\\\" <> rest, acc) do
    process_b_escapes(rest, ["\\" | acc])
  end

  defp process_b_escapes("\\n" <> rest, acc) do
    process_b_escapes(rest, ["\n" | acc])
  end

  defp process_b_escapes("\\t" <> rest, acc) do
    process_b_escapes(rest, ["\t" | acc])
  end

  defp process_b_escapes("\\r" <> rest, acc) do
    process_b_escapes(rest, ["\r" | acc])
  end

  defp process_b_escapes("\\a" <> rest, acc) do
    process_b_escapes(rest, ["\a" | acc])
  end

  defp process_b_escapes("\\b" <> rest, acc) do
    process_b_escapes(rest, ["\b" | acc])
  end

  defp process_b_escapes("\\f" <> rest, acc) do
    process_b_escapes(rest, ["\f" | acc])
  end

  defp process_b_escapes("\\v" <> rest, acc) do
    process_b_escapes(rest, ["\v" | acc])
  end

  defp process_b_escapes("\\e" <> rest, acc) do
    process_b_escapes(rest, ["\e" | acc])
  end

  defp process_b_escapes("\\0" <> rest, acc) do
    {digits, remaining} = consume_octal_digits(rest, 3)

    byte =
      case digits do
        "" -> 0
        _ -> String.to_integer(digits, 8)
      end

    process_b_escapes(remaining, [<<byte::size(8)>> | acc])
  end

  defp process_b_escapes("\\" <> rest, acc) do
    case rest do
      "x" <> hex_rest ->
        {digits, remaining} = consume_hex_digits(hex_rest, 2)

        if digits == "" do
          process_b_escapes(remaining, ["\\x" | acc])
        else
          byte = String.to_integer(digits, 16)
          process_b_escapes(remaining, [<<byte::size(8)>> | acc])
        end

      "u" <> uni_rest ->
        {digits, remaining} = consume_hex_digits(uni_rest, 4)

        if digits == "" do
          process_b_escapes(remaining, ["\\u" | acc])
        else
          codepoint = String.to_integer(digits, 16)
          process_b_escapes(remaining, [<<codepoint::utf8>> | acc])
        end

      "U" <> uni_rest ->
        {digits, remaining} = consume_hex_digits(uni_rest, 8)

        if digits == "" do
          process_b_escapes(remaining, ["\\U" | acc])
        else
          codepoint = String.to_integer(digits, 16)
          process_b_escapes(remaining, [<<codepoint::utf8>> | acc])
        end

      <<digit, _::binary>> when digit >= ?1 and digit <= ?7 ->
        {digits, remaining} = consume_octal_digits(rest, 3)
        byte = String.to_integer(digits, 8)
        process_b_escapes(remaining, [<<byte::size(8)>> | acc])

      _ ->
        process_b_escapes(rest, ["\\" | acc])
    end
  end

  defp process_b_escapes(<<c::utf8, rest::binary>>, acc) do
    process_b_escapes(rest, [<<c::utf8>> | acc])
  end

  defp process_b_escapes(<<byte::size(8), rest::binary>>, acc) do
    process_b_escapes(rest, [<<byte>> | acc])
  end

  defp consume_octal_digits(str, max) do
    consume_digits(str, max, fn c -> c >= ?0 and c <= ?7 end, "")
  end

  defp consume_hex_digits(str, max) do
    consume_digits(
      str,
      max,
      fn c ->
        (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F)
      end,
      ""
    )
  end

  defp consume_digits(str, 0, _pred, acc), do: {acc, str}
  defp consume_digits("", _max, _pred, acc), do: {acc, ""}

  defp consume_digits(<<c, rest::binary>>, max, pred, acc) do
    if pred.(c) do
      consume_digits(rest, max - 1, pred, acc <> <<c>>)
    else
      {acc, <<c, rest::binary>>}
    end
  end
end
