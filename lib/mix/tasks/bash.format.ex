defmodule Mix.Tasks.Bash.Format do
  @shortdoc "Formats Bash script files"
  @moduledoc """
  Formats Bash script files.

  ## Usage

      mix bash.format [options] file1.sh file2.sh

  ## Options

    * `--indent` - indentation style, either `spaces` or `tabs` (default: `spaces`)
    * `--indent-width` - number of spaces per indent level (default: `2`, ignored for tabs)
    * `--wrap` - max line length before wrapping (default: `80`)

  Formats each file in place using `Bash.format_file/2`.
  """

  use Mix.Task

  @switches [indent: :string, indent_width: :integer, wrap: :integer]
  @aliases [w: :wrap]

  @impl Mix.Task
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    if files == [], do: Mix.raise("Expected at least one file path, got none")

    format_opts = build_opts(opts)
    Enum.each(files, &Bash.format_file(&1, format_opts))
  end

  defp build_opts(opts) do
    bash_opts =
      []
      |> put_indent_style(opts[:indent])
      |> put_opt(:indent_width, opts[:indent_width])
      |> put_opt(:line_length, opts[:wrap])

    [bash: bash_opts]
  end

  defp put_indent_style(acc, nil), do: acc
  defp put_indent_style(acc, "spaces"), do: [{:indent_style, :spaces} | acc]
  defp put_indent_style(acc, "tabs"), do: [{:indent_style, :tabs} | acc]

  defp put_indent_style(_acc, other),
    do: Mix.raise("Invalid --indent value: #{other}. Expected \"spaces\" or \"tabs\"")

  defp put_opt(acc, _key, nil), do: acc
  defp put_opt(acc, key, value), do: [{key, value} | acc]
end
