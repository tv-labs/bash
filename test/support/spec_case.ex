defmodule Bash.SpecCase do
  @moduledoc """
  Test case template that generates ExUnit tests from Oils-format spec files.

  Parses a `.test.sh` spec file at compile time and generates one test per
  `####` case. Each test runs the shell code through `Bash.run/1` and asserts
  against expected stdout and exit status.

  ## Usage

      defmodule Bash.Spec.ArithTest do
        use Bash.SpecCase, file: "test/fixtures/arith.test.sh"
      end

  ## Filtering

  All generated tests are tagged `spec: true`, so you can run them with:

      mix test --only spec

  Tests are automatically skipped when the spec case has `skip: true` or when
  neither `stdout` nor `status` expectations are defined.
  """

  alias Bash.ExecutionResult

  @doc false
  def run_and_assert(%Bash.SpecParser{} = spec) do
    task =
      Task.async(fn ->
        Bash.run(spec.code)
      end)

    run_result =
      case Task.yield(task, 5_000) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:timeout, nil, nil}
      end

    case run_result do
      {:timeout, _, _} ->
        ExUnit.Assertions.flunk("Spec \"#{spec.name}\" (line #{spec.line}) timed out after 5s")

      {status, result, _session} ->
        actual_stdout = ExecutionResult.stdout(result)

        actual_exit_code =
          case status do
            :error -> ExecutionResult.exit_code(result) || 1
            _ -> ExecutionResult.exit_code(result) || 0
          end

        assert_stdout(spec, actual_stdout)
        assert_status(spec, actual_exit_code)
    end
  end

  defp assert_stdout(%{stdout: nil}, _actual), do: :ok

  defp assert_stdout(spec, actual) do
    unless actual == spec.stdout do
      ExUnit.Assertions.flunk("""
      Spec "#{spec.name}" (line #{spec.line}) stdout mismatch

      Code:
        #{spec.code}

      Expected stdout:
        #{inspect(spec.stdout)}

      Actual stdout:
        #{inspect(actual)}
      """)
    end
  end

  defp assert_status(%{status: nil}, _actual), do: :ok

  defp assert_status(spec, actual) do
    unless actual == spec.status do
      ExUnit.Assertions.flunk("""
      Spec "#{spec.name}" (line #{spec.line}) status mismatch

      Code:
        #{spec.code}

      Expected status: #{spec.status}
      Actual status:   #{actual}
      """)
    end
  end

  defmacro __using__(opts) do
    file = Keyword.fetch!(opts, :file)
    moduletag = Keyword.get(opts, :moduletag)

    quote do
      use ExUnit.Case, async: true

      if unquote(moduletag), do: @moduletag(unquote(moduletag))

      @external_resource unquote(file)
      @spec_cases Bash.SpecParser.parse_file(unquote(file))

      for spec <- @spec_cases do
        @spec_case spec

        if spec.skip or (is_nil(spec.stdout) and is_nil(spec.status)) do
          @tag :skip
        end

        @tag spec: true
        @tag spec_line: spec.line
        test "spec: #{spec.name} (line #{spec.line})" do
          Bash.SpecCase.run_and_assert(@spec_case)
        end
      end
    end
  end
end
