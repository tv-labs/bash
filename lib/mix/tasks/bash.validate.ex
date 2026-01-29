defmodule Mix.Tasks.Bash.Validate do
  @shortdoc "Validates Bash script files"
  @moduledoc """
  Validates Bash script files for syntax errors.

  ## Usage

      mix bash.validate file1.sh file2.sh

  Validates each file using `Bash.validate_file/1` and reports any errors.
  Exits with status 1 if any file is invalid.
  """

  use Mix.Task

  @impl Mix.Task
  def run([]), do: Mix.raise("Expected at least one file path, got none")

  def run(files) do
    results =
      Enum.map(files, fn file ->
        case Bash.validate_file(file) do
          :ok ->
            :ok

          {:error, %Bash.SyntaxError{} = error} ->
            Mix.shell().error("#{file}: #{Exception.message(error)}")
            :error

          {:error, reason} ->
            Mix.shell().error("#{file}: #{:file.format_error(reason)}")
            :error
        end
      end)

    if Enum.any?(results, &(&1 == :error)) do
      Mix.raise("Validation failed")
    end
  end
end
