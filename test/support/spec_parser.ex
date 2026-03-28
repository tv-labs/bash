defmodule Bash.SpecParser do
  @moduledoc """
  Parses Oils-format spec test files into structured test case data.

  The Oils spec format uses `#### Test Name` markers to delimit test cases,
  followed by shell code and metadata lines starting with `## `.

  ## Example

      iex> content = \"""
      ...> #### Echo test
      ...> echo hello
      ...> ## stdout: hello
      ...> \"""
      iex> [test_case] = Bash.SpecParser.parse_string(content)
      iex> test_case.name
      "Echo test"
      iex> test_case.stdout
      "hello\\n"

  ## Metadata directives

  - `## stdout: value` — single-line expected stdout (appends `\\n`)
  - `## stdout-json: "value"` — JSON-encoded stdout (no `\\n` appended)
  - `## STDOUT:` ... `## END` — multi-line expected stdout block
  - `## status: N` — expected exit code (integer)
  - `## OK bash stdout: value` — bash-specific override for stdout
  - `## OK bash/zsh stdout: value` — also applies to bash
  - `## OK bash STDOUT:` ... `## END` — bash-specific multi-line override
  - `## N-I bash ...` — marks the test as skipped for bash
  """

  defstruct [:name, :code, :stdout, :status, :line, skip: false]

  @doc """
  Parses a spec test file at the given path and returns a list of test cases.
  """
  @spec parse_file(String.t()) :: [%__MODULE__{}]
  def parse_file(path) do
    path
    |> File.read!()
    |> parse_string()
  end

  @doc """
  Parses a spec test string and returns a list of test cases.
  """
  @spec parse_string(String.t()) :: [%__MODULE__{}]
  def parse_string(content) do
    lines = String.split(content, "\n")

    lines
    |> split_test_cases()
    |> Enum.map(&parse_test_case/1)
    |> Enum.reject(&is_nil/1)
  end

  defp split_test_cases(lines) do
    {cases, current} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn
        {"#### " <> name, line_num}, {cases, nil} ->
          {cases, {String.trim(name), line_num, []}}

        {"#### " <> name, line_num}, {cases, {prev_name, prev_line, prev_lines}} ->
          {[{prev_name, prev_line, Enum.reverse(prev_lines)} | cases],
           {String.trim(name), line_num, []}}

        {line, _line_num}, {cases, nil} ->
          # Preamble — ignore lines before the first ####
          _ = line
          {cases, nil}

        {line, _line_num}, {cases, {name, case_line, acc}} ->
          {cases, {name, case_line, [line | acc]}}
      end)

    all_cases =
      case current do
        nil -> cases
        {name, line, lines_acc} -> [{name, line, Enum.reverse(lines_acc)} | cases]
      end

    Enum.reverse(all_cases)
  end

  defp parse_test_case({name, line, lines}) do
    {code_lines, metadata_lines} = split_code_and_metadata(lines)

    code =
      code_lines
      |> Enum.join("\n")
      |> String.trim()

    if code == "" do
      nil
    else
      skip = skip?(code, metadata_lines)
      {stdout, status} = extract_expectations(metadata_lines)

      %__MODULE__{
        name: name,
        code: code,
        stdout: stdout,
        status: status,
        line: line,
        skip: skip
      }
    end
  end

  defp split_code_and_metadata(lines) do
    # Find the first line starting with "## " that is a metadata directive.
    # Lines before that are code; lines from that point on are metadata.
    split_index =
      Enum.find_index(lines, fn line ->
        metadata_line?(line)
      end)

    case split_index do
      nil -> {lines, []}
      idx -> Enum.split(lines, idx)
    end
  end

  defp metadata_line?("## " <> _), do: true
  defp metadata_line?(_), do: false

  defp skip?(code, metadata_lines) do
    sh_in_code?(code) || ni_bash?(metadata_lines)
  end

  defp sh_in_code?(code) do
    String.contains?(code, "$SH") || String.contains?(code, "case $SH in")
  end

  defp ni_bash?(metadata_lines) do
    Enum.any?(metadata_lines, fn line ->
      case line do
        "## N-I bash" <> _ -> true
        "## N-I bash/" <> _ -> true
        "## N-I " <> rest -> bash_in_shell_list?(rest)
        _ -> false
      end
    end)
  end

  defp bash_in_shell_list?(rest) do
    # Handle patterns like "## N-I zsh/bash stdout: ..."
    case String.split(rest, " ", parts: 2) do
      [shells | _] ->
        shells
        |> String.split("/")
        |> Enum.member?("bash")

      _ ->
        false
    end
  end

  defp extract_expectations(metadata_lines) do
    defaults = parse_default_expectations(metadata_lines)
    bash_overrides = parse_bash_overrides(metadata_lines)

    stdout = Map.get(bash_overrides, :stdout, Map.get(defaults, :stdout))
    status = Map.get(bash_overrides, :status, Map.get(defaults, :status))

    {stdout, status}
  end

  defp parse_default_expectations(lines) do
    acc = %{}

    acc = parse_inline_stdout(lines, "## stdout: ", acc)
    acc = parse_stdout_json(lines, "## stdout-json: ", acc)
    acc = parse_multiline_stdout(lines, "## STDOUT:", acc)
    parse_status(lines, "## status: ", acc)
  end

  defp parse_bash_overrides(lines) do
    acc = %{}

    acc = parse_inline_stdout(lines, "## OK bash stdout: ", acc)
    acc = parse_inline_stdout_for_bash_in_list(lines, acc)
    acc = parse_stdout_json(lines, "## OK bash stdout-json: ", acc)
    acc = parse_stdout_json_for_bash_in_list(lines, acc)
    acc = parse_multiline_stdout(lines, "## OK bash STDOUT:", acc)
    acc = parse_multiline_stdout_for_bash_in_list(lines, acc)
    acc = parse_status(lines, "## OK bash status: ", acc)
    parse_status_for_bash_in_list(lines, acc)
  end

  defp parse_inline_stdout(lines, prefix, acc) do
    case find_prefixed_value(lines, prefix) do
      nil -> acc
      value -> Map.put(acc, :stdout, value <> "\n")
    end
  end

  defp parse_inline_stdout_for_bash_in_list(lines, acc) do
    case find_bash_in_list_value(lines, "stdout: ") do
      nil -> acc
      value -> Map.put(acc, :stdout, value <> "\n")
    end
  end

  defp parse_stdout_json(lines, prefix, acc) do
    case find_prefixed_value(lines, prefix) do
      nil -> acc
      json_str -> Map.put(acc, :stdout, JSON.decode!(json_str))
    end
  end

  defp parse_stdout_json_for_bash_in_list(lines, acc) do
    case find_bash_in_list_value(lines, "stdout-json: ") do
      nil -> acc
      json_str -> Map.put(acc, :stdout, JSON.decode!(json_str))
    end
  end

  defp parse_multiline_stdout(lines, marker, acc) do
    case extract_multiline_block(lines, marker) do
      nil -> acc
      content -> Map.put(acc, :stdout, content)
    end
  end

  defp parse_multiline_stdout_for_bash_in_list(lines, acc) do
    # Look for patterns like "## OK bash/zsh STDOUT:" or "## OK zsh/bash STDOUT:"
    marker =
      Enum.find(lines, fn line ->
        String.starts_with?(line, "## OK ") &&
          String.ends_with?(line, "STDOUT:") &&
          bash_in_ok_shell_list?(line)
      end)

    case marker do
      nil -> acc
      m -> parse_multiline_stdout(lines, m, acc)
    end
  end

  defp parse_status(lines, prefix, acc) do
    case find_prefixed_value(lines, prefix) do
      nil -> acc
      value -> Map.put(acc, :status, String.to_integer(value))
    end
  end

  defp parse_status_for_bash_in_list(lines, acc) do
    case find_bash_in_list_value(lines, "status: ") do
      nil -> acc
      value -> Map.put(acc, :status, String.to_integer(value))
    end
  end

  defp find_prefixed_value(lines, prefix) do
    Enum.find_value(lines, fn line ->
      case String.split(line, prefix, parts: 2) do
        ["", value] -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp find_bash_in_list_value(lines, suffix) do
    # Match patterns like "## OK bash/zsh stdout: value" or "## OK zsh/bash stdout: value"
    Enum.find_value(lines, fn line ->
      with "## OK " <> rest <- line,
           [shells, directive_rest] <- String.split(rest, " ", parts: 2),
           true <- String.contains?(shells, "/"),
           true <- "bash" in String.split(shells, "/"),
           true <- String.starts_with?(directive_rest, suffix) do
        String.trim_leading(directive_rest, suffix) |> String.trim()
      else
        _ -> nil
      end
    end)
  end

  defp bash_in_ok_shell_list?(line) do
    case Regex.run(~r/^## OK ([a-z\/]+) STDOUT:$/, line) do
      [_, shells] -> "bash" in String.split(shells, "/")
      _ -> false
    end
  end

  defp extract_multiline_block(lines, marker) do
    with start_idx when not is_nil(start_idx) <-
           Enum.find_index(lines, &(&1 == marker)),
         rest = Enum.drop(lines, start_idx + 1),
         end_idx when not is_nil(end_idx) <-
           Enum.find_index(rest, &(&1 == "## END")) do
      rest
      |> Enum.take(end_idx)
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    else
      _ -> nil
    end
  end
end
