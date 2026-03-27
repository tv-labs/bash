defmodule AWK.Builtins do
  @moduledoc """
  Built-in function implementations for the AWK interpreter.

  Provides string, math, I/O, bitwise, and type introspection functions
  matching POSIX AWK and common gawk extensions.
  """

  import Bitwise

  alias AWK.Evaluator.State

  @spec call(String.t(), [term()], State.t()) :: {term(), State.t()}
  def call(name, args, state)

  # ---------------------------------------------------------------------------
  # String functions
  # ---------------------------------------------------------------------------

  def call("length", [], state) do
    {String.length(get_field(state, 0)), state}
  end

  def call("length", [arg], state) when is_map(arg) do
    {map_size(arg), state}
  end

  def call("length", [arg], state) do
    {String.length(to_string_val(arg)), state}
  end

  def call("substr", [str, start | rest], state) do
    s = to_string_val(str)
    pos = max(to_integer(start), 1)
    len = case rest do
      [l] -> to_integer(l)
      [] -> String.length(s)
    end

    result = if pos > String.length(s) do
      ""
    else
      String.slice(s, pos - 1, max(len, 0))
    end

    {result, state}
  end

  def call("index", [haystack, needle], state) do
    h = to_string_val(haystack)
    n = to_string_val(needle)

    case :binary.match(h, n) do
      {pos, _len} -> {pos + 1, state}
      :nomatch -> {0, state}
    end
  end

  def call("split", [str, array_name, sep | _rest], state) when is_binary(array_name) do
    s = to_string_val(str)
    parts = split_by_separator(s, sep)
    arr = parts
      |> Enum.with_index(1)
      |> Enum.into(%{}, fn {val, idx} -> {Integer.to_string(idx), val} end)

    arrays = Map.put(state.arrays, array_name, arr)
    {length(parts), %{state | arrays: arrays}}
  end

  def call("split", [str, array_name], state) when is_binary(array_name) do
    call("split", [str, array_name, state.fs], state)
  end

  def call("sub", [pattern, replacement, target_name], state) when is_binary(target_name) do
    regex = to_regex(pattern)
    current = get_variable(state, target_name)
    repl = to_string_val(replacement)
    repl_escaped = awk_replacement_to_elixir(repl)

    case Regex.run(regex, current, return: :index) do
      nil ->
        {0, state}

      [{pos, len} | _] ->
        before = binary_part(current, 0, pos)
        after_part = binary_part(current, pos + len, byte_size(current) - pos - len)
        matched = binary_part(current, pos, len)
        substituted = String.replace(repl_escaped, "\\0", matched)
        new_val = before <> substituted <> after_part
        state = set_variable(state, target_name, new_val)
        {1, state}
    end
  end

  def call("sub", [pattern, replacement], state) do
    call("sub", [pattern, replacement, :field_zero], state)
  end

  def call("gsub", [pattern, replacement, target_name], state) when is_binary(target_name) do
    regex = to_regex(pattern)
    current = get_variable(state, target_name)
    repl = to_string_val(replacement)
    repl_escaped = awk_replacement_to_elixir(repl)

    matches = Regex.scan(regex, current, return: :index) |> length()

    if matches == 0 do
      {0, state}
    else
      new_val = Regex.replace(regex, current, fn matched -> String.replace(repl_escaped, "\\0", matched) end)
      state = set_variable(state, target_name, new_val)
      {matches, state}
    end
  end

  def call("gsub", [pattern, replacement], state) do
    call("gsub", [pattern, replacement, :field_zero], state)
  end

  def call("match", [str, pattern], state) do
    s = to_string_val(str)
    regex = to_regex(pattern)

    case Regex.run(regex, s, return: :index) do
      nil ->
        state = state
          |> set_builtin_var("RSTART", 0)
          |> set_builtin_var("RLENGTH", -1)
        {0, state}

      [{pos, len} | _] ->
        state = state
          |> set_builtin_var("RSTART", pos + 1)
          |> set_builtin_var("RLENGTH", len)
        {pos + 1, state}
    end
  end

  def call("sprintf", [format | args], state) do
    {format_printf(to_string_val(format), args), state}
  end

  def call("tolower", [str], state) do
    {String.downcase(to_string_val(str)), state}
  end

  def call("toupper", [str], state) do
    {String.upcase(to_string_val(str)), state}
  end

  def call("patsplit", [str, array_name, pattern | rest], state) when is_binary(array_name) do
    s = to_string_val(str)
    regex = to_regex(pattern)
    matches = Regex.scan(regex, s) |> Enum.map(&hd/1)

    arr = matches
      |> Enum.with_index(1)
      |> Enum.into(%{}, fn {val, idx} -> {Integer.to_string(idx), val} end)

    state = %{state | arrays: Map.put(state.arrays, array_name, arr)}

    state = case rest do
      [sep_array] when is_binary(sep_array) ->
        separators = Regex.split(regex, s, include_captures: true)
          |> Enum.reject(fn part -> Enum.member?(matches, part) end)
          |> Enum.with_index(0)
          |> Enum.into(%{}, fn {val, idx} -> {Integer.to_string(idx), val} end)
        %{state | arrays: Map.put(state.arrays, sep_array, separators)}
      _ ->
        state
    end

    {length(matches), state}
  end

  # ---------------------------------------------------------------------------
  # Math functions
  # ---------------------------------------------------------------------------

  def call("sin", [x], state), do: {:math.sin(to_number(x)), state}
  def call("cos", [x], state), do: {:math.cos(to_number(x)), state}

  def call("atan2", [y, x], state) do
    {:math.atan2(to_number(y), to_number(x)), state}
  end

  def call("exp", [x], state), do: {:math.exp(to_number(x)), state}
  def call("log", [x], state), do: {:math.log(to_number(x)), state}
  def call("sqrt", [x], state), do: {:math.sqrt(to_number(x)), state}

  def call("int", [x], state), do: {trunc(to_number(x)), state}

  def call("rand", [], state) do
    {val, new_rng} = case state.rng_state do
      nil ->
        rng = :rand.seed_s(:exsss)
        :rand.uniform_s(rng)

      rng ->
        :rand.uniform_s(rng)
    end

    {val, %{state | rng_state: new_rng}}
  end

  def call("srand", [], state) do
    prev = case state.rng_state do
      nil -> 0
      _ -> 0
    end

    rng = :rand.seed_s(:exsss)
    {prev, %{state | rng_state: rng}}
  end

  def call("srand", [seed], state) do
    prev = case state.rng_state do
      nil -> 0
      _ -> 0
    end

    int_seed = to_integer(seed)
    rng = :rand.seed_s(:exsss, {int_seed, int_seed, int_seed})
    {prev, %{state | rng_state: rng}}
  end

  # ---------------------------------------------------------------------------
  # I/O functions (pure mode stubs)
  # ---------------------------------------------------------------------------

  def call("close", [_file], state), do: {0, state}
  def call("system", [_cmd], state), do: {0, state}
  def call("fflush", _args, state), do: {0, state}

  # ---------------------------------------------------------------------------
  # Bitwise operations (gawk)
  # ---------------------------------------------------------------------------

  def call("and", [a, b], state) do
    {Bitwise.band(to_integer(a), to_integer(b)), state}
  end

  def call("or", [a, b], state) do
    {Bitwise.bor(to_integer(a), to_integer(b)), state}
  end

  def call("xor", [a, b], state) do
    {Bitwise.bxor(to_integer(a), to_integer(b)), state}
  end

  def call("lshift", [val, count], state) do
    {Bitwise.bsl(to_integer(val), to_integer(count)), state}
  end

  def call("rshift", [val, count], state) do
    {Bitwise.bsr(to_integer(val), to_integer(count)), state}
  end

  def call("compl", [val], state) do
    {Bitwise.bnot(to_integer(val)), state}
  end

  # ---------------------------------------------------------------------------
  # Type functions (gawk)
  # ---------------------------------------------------------------------------

  def call("typeof", [val], state) do
    result = cond do
      is_map(val) -> "array"
      is_number(val) -> "number"
      is_binary(val) and val == "" -> "uninitialized"
      is_binary(val) -> "string"
      true -> "uninitialized"
    end

    {result, state}
  end

  def call("isarray", [val], state) do
    {if(is_map(val), do: 1, else: 0), state}
  end

  def call(name, _args, _state) do
    raise "AWK: unknown builtin function '#{name}'"
  end

  # ---------------------------------------------------------------------------
  # Printf format
  # ---------------------------------------------------------------------------

  @spec format_printf(String.t(), [term()]) :: String.t()
  def format_printf(format, args) do
    do_format(format, args, [])
    |> IO.iodata_to_binary()
  end

  defp do_format("", _args, acc), do: Enum.reverse(acc)

  defp do_format("%" <> rest, args, acc) do
    {spec, remaining} = parse_format_spec(rest)

    case spec.conversion do
      ?% ->
        do_format(remaining, args, ["%" | acc])

      _ ->
        {arg, rest_args} = case args do
          [a | t] -> {a, t}
          [] -> {"", []}
        end

        formatted = apply_format_spec(spec, arg)
        do_format(remaining, rest_args, [formatted | acc])
    end
  end

  defp do_format(<<c, rest::binary>>, args, acc) do
    {literal, remaining} = collect_literal(rest, [c])
    do_format(remaining, args, [literal | acc])
  end

  defp collect_literal("%" <> _ = rest, chars), do: {IO.iodata_to_binary(Enum.reverse(chars)), rest}
  defp collect_literal("", chars), do: {IO.iodata_to_binary(Enum.reverse(chars)), ""}
  defp collect_literal(<<c, rest::binary>>, chars), do: collect_literal(rest, [c | chars])

  defmodule FormatSpec do
    @moduledoc false
    defstruct flags: [], width: nil, precision: nil, conversion: nil
  end

  defp parse_format_spec(str) do
    {flags, str} = parse_flags(str, [])
    {width, str} = parse_number(str)
    {precision, str} = parse_precision(str)
    {conversion, str} = parse_conversion(str)
    {%FormatSpec{flags: flags, width: width, precision: precision, conversion: conversion}, str}
  end

  defp parse_flags(<<c, rest::binary>>, acc) when c in [?-, ?+, ?\s, ?0, ?#] do
    parse_flags(rest, [c | acc])
  end

  defp parse_flags(str, acc), do: {Enum.reverse(acc), str}

  defp parse_number(<<c, _::binary>> = str) when c in ?0..?9 do
    {digits, rest} = take_digits(str, [])
    {String.to_integer(IO.iodata_to_binary(digits)), rest}
  end

  defp parse_number(<<"*", rest::binary>>), do: {:star, rest}
  defp parse_number(str), do: {nil, str}

  defp parse_precision(<<".", rest::binary>>) do
    case parse_number(rest) do
      {nil, rest2} -> {0, rest2}
      {n, rest2} -> {n, rest2}
    end
  end

  defp parse_precision(str), do: {nil, str}

  defp parse_conversion(<<c, rest::binary>>), do: {c, rest}
  defp parse_conversion(""), do: {?s, ""}

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: take_digits(rest, [c | acc])
  defp take_digits(str, acc), do: {Enum.reverse(acc), str}

  defp apply_format_spec(%FormatSpec{conversion: conv} = spec, arg)
       when conv in [?d, ?i] do
    n = to_integer(arg)
    formatted = Integer.to_string(n)
    apply_width_and_flags(spec, formatted, true)
  end

  defp apply_format_spec(%FormatSpec{conversion: ?u} = spec, arg) do
    n = to_integer(arg)
    val = if n < 0, do: n + 4_294_967_296, else: n
    formatted = Integer.to_string(val)
    apply_width_and_flags(spec, formatted, true)
  end

  defp apply_format_spec(%FormatSpec{conversion: ?o} = spec, arg) do
    n = to_integer(arg)
    formatted = Integer.to_string(n, 8)
    prefix = if ?# in spec.flags, do: "0", else: ""
    apply_width_and_flags(spec, prefix <> formatted, true)
  end

  defp apply_format_spec(%FormatSpec{conversion: conv} = spec, arg) when conv in [?x, ?X] do
    n = to_integer(arg)
    formatted = Integer.to_string(abs(n), 16)
    formatted = if conv == ?x, do: String.downcase(formatted), else: String.upcase(formatted)
    prefix = if ?# in spec.flags and n != 0, do: (if conv == ?x, do: "0x", else: "0X"), else: ""
    sign = if n < 0, do: "-", else: ""
    apply_width_and_flags(spec, sign <> prefix <> formatted, true)
  end

  defp apply_format_spec(%FormatSpec{conversion: ?c} = _spec, arg) do
    case arg do
      n when is_number(n) -> <<trunc(n)::utf8>>
      s when is_binary(s) and byte_size(s) > 0 -> String.first(s)
      _ -> ""
    end
  end

  defp apply_format_spec(%FormatSpec{conversion: ?s} = spec, arg) do
    s = to_string_val(arg)
    s = case spec.precision do
      nil -> s
      n when is_integer(n) -> String.slice(s, 0, n)
      _ -> s
    end
    apply_width_and_flags(spec, s, false)
  end

  defp apply_format_spec(%FormatSpec{conversion: ?f} = spec, arg) do
    n = to_number(arg) * 1.0
    prec = spec.precision || 6
    formatted = :io_lib.format(~c"~.#{prec}f", [n]) |> to_string()
    apply_width_and_flags(spec, formatted, true)
  end

  defp apply_format_spec(%FormatSpec{conversion: conv} = spec, arg)
       when conv in [?e, ?E] do
    n = to_number(arg) * 1.0
    prec = spec.precision || 6
    formatted = :io_lib.format(~c"~.#{prec}e", [n]) |> to_string()
    formatted = if conv == ?E, do: String.upcase(formatted), else: formatted
    apply_width_and_flags(spec, formatted, true)
  end

  defp apply_format_spec(%FormatSpec{conversion: conv} = spec, arg)
       when conv in [?g, ?G] do
    n = to_number(arg) * 1.0
    prec = max(spec.precision || 6, 1)
    formatted = format_g(n, prec)
    formatted = if conv == ?G, do: String.upcase(formatted), else: formatted
    apply_width_and_flags(spec, formatted, true)
  end

  defp apply_format_spec(_spec, arg), do: to_string_val(arg)

  defp format_g(n, prec) do
    abs_n = abs(n)

    if abs_n == 0.0 or (abs_n >= 1.0e-4 and abs_n < :math.pow(10, prec)) do
      f_str = :io_lib.format(~c"~.#{prec}f", [n]) |> to_string()
      strip_trailing_zeros(f_str)
    else
      e_str = :io_lib.format(~c"~.#{prec - 1}e", [n]) |> to_string()
      strip_trailing_zeros_exp(e_str)
    end
  end

  defp strip_trailing_zeros(str) do
    if String.contains?(str, ".") do
      str |> String.trim_trailing("0") |> String.trim_trailing(".")
    else
      str
    end
  end

  defp strip_trailing_zeros_exp(str) do
    case String.split(str, ~r/[eE]/, parts: 2) do
      [mantissa, exp] ->
        m = strip_trailing_zeros(mantissa)
        e_char = if String.contains?(str, "E"), do: "E", else: "e"
        m <> e_char <> exp

      _ ->
        str
    end
  end

  defp apply_width_and_flags(spec, str, numeric?) do
    str = if numeric? and ?+ in spec.flags and not String.starts_with?(str, "-") do
      "+" <> str
    else
      if numeric? and ?\s in spec.flags and not String.starts_with?(str, "-") and not (?+ in spec.flags) do
        " " <> str
      else
        str
      end
    end

    case spec.width do
      nil -> str
      w when is_integer(w) ->
        pad_char = if ?0 in spec.flags and numeric? and not (?- in spec.flags), do: "0", else: " "

        if ?- in spec.flags do
          String.pad_trailing(str, w)
        else
          if pad_char == "0" and (String.starts_with?(str, "-") or String.starts_with?(str, "+")) do
            <<sign, rest_str::binary>> = str
            <<sign>> <> String.pad_leading(rest_str, w - 1, pad_char)
          else
            String.pad_leading(str, w, pad_char)
          end
        end

      _ -> str
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp to_number(v) when is_number(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, _} -> if trunc(n) == n, do: trunc(n), else: n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp to_integer(v), do: trunc(to_number(v))

  defp to_string_val(v) when is_binary(v), do: v
  defp to_string_val(v) when is_integer(v), do: Integer.to_string(v)
  defp to_string_val(v) when is_float(v), do: :io_lib.format(~c"%.6g", [v]) |> to_string()
  defp to_string_val(_), do: ""

  defp to_regex(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, r} -> r
      {:error, _} -> ~r/(?!)/
    end
  end

  defp to_regex(%Regex{} = r), do: r

  defp split_by_separator(str, " "), do: String.split(str)

  defp split_by_separator(str, sep) when is_binary(sep) and byte_size(sep) == 1 do
    String.split(str, sep)
  end

  defp split_by_separator(str, sep) when is_binary(sep) do
    case Regex.compile(sep) do
      {:ok, r} -> Regex.split(r, str)
      {:error, _} -> String.split(str, sep)
    end
  end

  defp split_by_separator(str, _), do: String.split(str)

  defp awk_replacement_to_elixir(repl) do
    repl
    |> String.replace("&", "\\0")
    |> String.replace("\\\\", "\\")
  end

  defp get_field(state, 0), do: state.record

  defp get_field(state, n) when is_integer(n) and n > 0 do
    Enum.at(state.fields, n - 1, "")
  end

  defp get_field(_state, _), do: ""

  defp get_variable(state, :field_zero), do: state.record

  defp get_variable(state, name) when is_binary(name) do
    Map.get(state.variables, name, "")
  end

  defp set_variable(state, :field_zero, value) do
    %{state | record: value}
    |> reparse_fields()
  end

  defp set_variable(state, name, value) when is_binary(name) do
    %{state | variables: Map.put(state.variables, name, value)}
  end

  defp set_builtin_var(state, name, value) do
    %{state | variables: Map.put(state.variables, name, value)}
  end

  defp reparse_fields(state) do
    fields = case state.fs do
      " " -> String.split(state.record)
      fs when byte_size(fs) == 1 -> String.split(state.record, fs)
      fs ->
        case Regex.compile(fs) do
          {:ok, r} -> Regex.split(r, state.record)
          _ -> String.split(state.record, fs)
        end
    end

    %{state | fields: fields, nf: length(fields)}
  end
end
