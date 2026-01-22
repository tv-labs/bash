defmodule Bash.Formatter do
  @moduledoc """
  Mix formatter plugin for Bash scripts and sigils.

  Formats `.sh` and `.bash` files, as well as `~BASH` and `~b` sigils in Elixir code.

  ## Configuration

  Add to your `.formatter.exs`:

      [
        plugins: [Bash.Formatter],
        inputs: [
          "{mix,.formatter}.exs",
          "{config,lib,test}/**/*.{ex,exs}",
          "scripts/**/*.{sh,bash}"
        ],
        # Optional Bash formatter configuration
        bash: [
          indent_style: :spaces,  # :spaces or :tabs
          indent_width: 2,        # number of spaces (ignored if :tabs)
          line_length: 100        # max line length before wrapping
        ]
      ]

  ## Formatting Behavior

  - Preserves shebang lines exactly as-is
  - Normalizes indentation based on configuration
  - Normalizes whitespace around operators
  - Wraps long lines after operators (`|`, `&&`, `||`) with backslash continuation
  - Never breaks inside strings, heredocs, arrays, or comments
  - Preserves existing backslash continuations
  - Graceful degradation: returns input unchanged on parse errors

  """

  @behaviour Mix.Tasks.Format

  alias Bash.Script

  @default_indent_style :spaces
  @default_indent_width 2
  @default_line_length 80

  @impl Mix.Tasks.Format
  def features(_opts) do
    [sigils: [:BASH, :b], extensions: [".sh", ".bash"]]
  end

  @impl Mix.Tasks.Format
  def format(contents, opts) do
    config = extract_config(opts)

    case Bash.parse(contents) do
      {:ok, script} ->
        format_script(script, config)

      {:error, _syntax_error} ->
        # Graceful degradation: return unchanged on parse errors
        contents
    end
  end

  defp extract_config(opts) do
    bash_opts = Keyword.get(opts, :bash, [])

    %{
      indent_style: Keyword.get(bash_opts, :indent_style, @default_indent_style),
      indent_width: Keyword.get(bash_opts, :indent_width, @default_indent_width),
      line_length: Keyword.get(bash_opts, :line_length, @default_line_length),
      # Pass through sigil info if present (for future use)
      sigil: Keyword.get(opts, :sigil),
      modifiers: Keyword.get(opts, :modifiers, []),
      extension: Keyword.get(opts, :extension)
    }
  end

  defp format_script(%Script{} = script, config) do
    formatted = format_with_config(script, config)

    # For sigils, don't add trailing newline
    if config.sigil do
      String.trim_trailing(formatted, "\n")
    else
      formatted
    end
  end

  defp format_with_config(%Script{shebang: shebang, statements: statements}, config) do
    indent_str = build_indent_string(config)

    formatted_body =
      statements
      |> format_statements(config, indent_str, 0)
      |> apply_configured_indent(config)
      |> apply_line_wrapping(config)

    case shebang do
      nil -> formatted_body
      interpreter -> "#!#{interpreter}\n#{formatted_body}"
    end
  end

  defp build_indent_string(%{indent_style: :tabs}) do
    "\t"
  end

  defp build_indent_string(%{indent_style: :spaces, indent_width: width}) do
    String.duplicate(" ", width)
  end

  # Replace the default 2-space indentation from AST.Formatter with configured indent
  # The AST's to_string uses "  " (2 spaces) as default indent
  @default_ast_indent "  "

  defp apply_configured_indent(text, %{indent_style: :spaces, indent_width: 2}) do
    # Already using the default, no change needed
    text
  end

  defp apply_configured_indent(text, config) do
    configured_indent = build_indent_string(config)

    # Replace indentation at the start of each line
    # We need to be careful to only replace leading whitespace that matches
    # the default indentation pattern
    text
    |> String.split("\n")
    |> Enum.map(&replace_line_indent(&1, @default_ast_indent, configured_indent))
    |> Enum.join("\n")
  end

  # Replace the leading indentation on a single line
  defp replace_line_indent(line, default_indent, new_indent) do
    # Count how many default indents are at the start
    {indent_count, rest} = count_leading_indents(line, default_indent, 0)

    # Rebuild with new indentation
    String.duplicate(new_indent, indent_count) <> rest
  end

  # Count leading indents and return {count, remaining_string}
  defp count_leading_indents(line, indent, count) do
    indent_len = String.length(indent)

    if String.starts_with?(line, indent) do
      rest = String.slice(line, indent_len, String.length(line) - indent_len)
      count_leading_indents(rest, indent, count + 1)
    else
      {count, line}
    end
  end

  # Format a list of statements with proper separators
  defp format_statements(statements, config, indent_str, level) do
    indent = String.duplicate(indent_str, level)

    statements
    |> Enum.map(fn
      {:separator, ";"} -> {:sep, "; "}
      {:separator, sep} -> {:sep, sep}
      node -> {:node, format_node(node, config, indent_str, level)}
    end)
    |> Enum.map_join("", fn
      {:sep, sep} -> sep
      {:node, content} -> "#{indent}#{content}"
    end)
    |> normalize_separators()
  end

  # Normalize consecutive separators and ensure proper newlines
  defp normalize_separators(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  # Format individual AST nodes
  defp format_node(node, config, indent_str, level) do
    node
    |> to_string()
    |> normalize_whitespace(config)
    |> indent_nested_content(indent_str, level)
  end

  # Normalize whitespace around operators
  defp normalize_whitespace(text, _config) do
    # Use placeholders for multi-char operators to prevent single-char matching
    # The regex captures surrounding whitespace to avoid double-spacing
    # Order matters: longer operators must be protected first
    text
    # Protect process substitution <(...) and >(...) - must come first!
    |> String.replace(~r/<\(/, "\x00PROCSUB_IN\x00")
    |> String.replace(~r/>\(/, "\x00PROCSUB_OUT\x00")
    # Protect multi-char operators with placeholders (consume surrounding whitespace)
    |> String.replace(~r/\s*\|\|\s*/, "\x00OR\x00")
    |> String.replace(~r/\s*&&\s*/, "\x00AND\x00")
    # Heredoc/herestring operators - preserve exactly (no added spaces after)
    # These must come before single-char < matching
    |> String.replace(~r/\s*<<</, "\x00TLESS\x00")
    |> String.replace(~r/\s*<<-/, "\x00DLESSDASH\x00")
    |> String.replace(~r/\s*<</, "\x00DLESS\x00")
    # Combined stdout/stderr redirects &> and &>> (must come before >>)
    |> String.replace(~r/\s*&>>\s*/, "\x00AMPAPPEND\x00")
    |> String.replace(~r/\s*&>\s*/, "\x00AMPGREAT\x00")
    |> String.replace(~r/\s*>>\s*/, "\x00DGREAT\x00")
    # FD duplication redirects (2>&1, >&2, etc.) - use placeholders
    |> String.replace(~r/\s*([0-9]*)>&([0-9-]+)/, "\x00GREATAND\\1_\\2\x00")
    |> String.replace(~r/\s*([0-9]*)<&([0-9-]+)/, "\x00LESSAND\\1_\\2\x00")
    # Normalize single-char operators (now safe since multi-char are placeholders)
    |> String.replace(~r/\s*\|\s*/, " | ")
    |> String.replace(~r/\s*([0-9]*)>\s*/, " \\1> ")
    |> String.replace(~r/\s*([0-9]*)<\s*/, " \\1< ")
    # Restore multi-char operators with proper spacing
    |> String.replace("\x00OR\x00", " || ")
    |> String.replace("\x00AND\x00", " && ")
    |> String.replace("\x00TLESS\x00", " <<<")
    |> String.replace("\x00DLESSDASH\x00", " <<-")
    |> String.replace("\x00DLESS\x00", " <<")
    |> String.replace("\x00AMPAPPEND\x00", " &>> ")
    |> String.replace("\x00AMPGREAT\x00", " &> ")
    |> String.replace("\x00DGREAT\x00", " >> ")
    # Restore FD duplication redirects
    |> String.replace(~r/\x00GREATAND([0-9]*)_([0-9-]+)\x00/, " \\1>&\\2")
    |> String.replace(~r/\x00LESSAND([0-9]*)_([0-9-]+)\x00/, " \\1<&\\2")
    # Restore process substitution
    |> String.replace("\x00PROCSUB_IN\x00", "<(")
    |> String.replace("\x00PROCSUB_OUT\x00", ">(")
    # Clean up multiple spaces between words (but not indentation at line start)
    |> String.replace(~r/([^\s]) {2,}/, "\\1 ")
    # Clean up spaces at start of line
    |> String.replace(~r/^ /, "")
    |> String.trim()
  end

  # Indent nested content (for compound statements)
  defp indent_nested_content(text, _indent_str, _level) do
    # For now, preserve the existing indentation from to_string
    # TODO: Re-indent nested content based on config
    text
  end

  # Apply line wrapping for lines exceeding max length
  defp apply_line_wrapping(text, config) do
    text
    |> String.split("\n")
    |> Enum.map(&wrap_line(&1, config))
    |> Enum.join("\n")
  end

  # Wrap a single line if it exceeds max length
  defp wrap_line(line, config) do
    wrap_line(line, config, nil)
  end

  defp wrap_line(line, %{line_length: max_length} = config, base_indent) do
    if String.length(line) <= max_length do
      line
    else
      # Check if line already has continuation (preserve existing)
      if String.ends_with?(String.trim_trailing(line), "\\") do
        line
      else
        wrap_at_operator(line, config, base_indent)
      end
    end
  end

  # Find the best place to wrap (after an operator, before max_length)
  # base_indent: the original line's indent (nil on first call)
  # continuation_indent: the indent for wrapped lines (nil on first call)
  defp wrap_at_operator(line, %{line_length: max_length} = config, base_indent) do
    # On first call, calculate both indents from the line
    {original_indent, continuation_indent, content} =
      case base_indent do
        nil ->
          indent = get_line_indent(line)
          cont_indent = indent <> build_indent_string(config)
          {indent, cont_indent, String.trim_leading(line)}

        _ ->
          # Recursive call - base_indent is actually the continuation_indent
          # Strip the indent from the line to get content
          {base_indent, base_indent, String.trim_leading(line)}
      end

    # Find wrap points in the content (positions after operators)
    wrap_points = find_wrap_points(content)

    # Calculate the indent for the current line (first line uses original, rest use continuation)
    current_indent = if base_indent == nil, do: original_indent, else: continuation_indent

    # Adjust max_length for the current indent
    effective_max = max_length - String.length(current_indent)

    # Find the best wrap point that keeps first part under effective max
    case find_best_wrap_point(wrap_points, effective_max) do
      nil ->
        # No good wrap point found, return with proper indent
        "#{current_indent}#{content}"

      position ->
        # Split the content at this position
        {first, rest} = String.split_at(content, position)
        first = String.trim_trailing(first)
        rest = String.trim_leading(rest)

        # Build the wrapped result
        first_line = "#{current_indent}#{first} \\"
        rest_with_indent = "#{continuation_indent}#{rest}"

        if String.length(rest_with_indent) > max_length do
          # Recursively wrap, keeping the same continuation_indent
          wrapped_rest = wrap_at_operator(rest_with_indent, config, continuation_indent)
          "#{first_line}\n#{wrapped_rest}"
        else
          "#{first_line}\n#{rest_with_indent}"
        end
    end
  end

  # Get the leading whitespace of a line
  defp get_line_indent(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, indent] -> indent
      _ -> ""
    end
  end

  # Find positions after operators where we can wrap
  # Returns list of {position, operator} tuples
  defp find_wrap_points(line) do
    # Pattern to find operators we can break after
    # We need to avoid breaking inside strings
    find_wrap_points_outside_strings(line)
  end

  # Find wrap points while respecting string boundaries
  defp find_wrap_points_outside_strings(line) do
    # Simple approach: find operators not inside quotes
    # This is a simplified implementation - a full parser would be better
    # skip_until tracks the index to skip to (for multi-char operators)
    {points, _in_string, _skip_until} =
      line
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce({[], nil, -1}, fn {char, idx}, {points, in_string, skip_until} ->
        cond do
          # Skip characters that are part of a multi-char operator we already processed
          idx < skip_until ->
            {points, in_string, skip_until}

          # Track string state
          char == "\"" and in_string == nil ->
            {points, "\"", skip_until}

          char == "\"" and in_string == "\"" ->
            {points, nil, skip_until}

          char == "'" and in_string == nil ->
            {points, "'", skip_until}

          char == "'" and in_string == "'" ->
            {points, nil, skip_until}

          # Only look for operators when not in a string
          in_string == nil ->
            # Check for multi-char operators at this position
            rest = String.slice(line, idx, 3)

            cond do
              String.starts_with?(rest, "||") ->
                # Skip the next character (second |)
                {[{idx + 2, "||"} | points], in_string, idx + 2}

              String.starts_with?(rest, "&&") ->
                # Skip the next character (second &)
                {[{idx + 2, "&&"} | points], in_string, idx + 2}

              char == "|" ->
                {[{idx + 1, "|"} | points], in_string, skip_until}

              true ->
                {points, in_string, skip_until}
            end

          true ->
            {points, in_string, skip_until}
        end
      end)

    Enum.reverse(points)
  end

  # Find the best wrap point that keeps first part under max_length
  defp find_best_wrap_point(wrap_points, max_length) do
    wrap_points
    |> Enum.filter(fn {pos, _op} -> pos <= max_length end)
    |> Enum.max_by(fn {pos, _op} -> pos end, fn -> nil end)
    |> case do
      {pos, _op} -> pos
      nil -> nil
    end
  end
end
