defmodule Bash.BuiltinTestHelper do
  @moduledoc """
  Test helper for calling builtins with proper sink setup.

  Since builtins using defbash stream output to sinks rather than accumulating
  in CommandResult.output, unit tests need to set up sinks to capture output.

  ## Usage

      import Bash.BuiltinTestHelper

      test "echo outputs text" do
        {result, stdout, stderr} = execute_builtin(Echo, ["hello"], %{})
        assert result.exit_code == 0
        assert stdout == "hello\n"
      end

  """

  alias Bash.Sink
  alias Bash.Variable

  @doc """
  Execute a builtin module with output capture.

  Returns `{result, stdout, stderr}` tuple where:
  - `result` is the CommandResult or exit code from the builtin
  - `stdout` is captured stdout as a string
  - `stderr` is captured stderr as a string

  ## Examples

      {result, stdout, stderr} = execute_builtin(Echo, ["hello"], %{})
      assert stdout == "hello\\n"

      {result, stdout, _stderr} = execute_builtin(Pwd, [], state)
      assert stdout =~ state.working_dir

  """
  def execute_builtin(module, args, state) do
    {sink, get_result} = Sink.Accumulator.new_separated()

    state_with_sinks =
      state
      |> Map.put(:stdout_sink, sink)
      |> Map.put(:stderr_sink, sink)
      |> ensure_defaults()

    result = module.execute(args, nil, state_with_sinks)
    {stdout, stderr} = get_result.()

    # Normalize result to just get the CommandResult or exit info
    normalized_result = normalize_result(result)

    {normalized_result, stdout, stderr}
  end

  @doc """
  Execute a builtin and return only the result (ignoring output).

  Useful when you only care about the exit code or state updates.
  """
  def execute_builtin_result(module, args, state) do
    {result, _stdout, _stderr} = execute_builtin(module, args, state)
    result
  end

  @doc """
  Execute a builtin and return only the stdout.

  Useful for simple output tests.
  """
  def execute_builtin_stdout(module, args, state) do
    {_result, stdout, _stderr} = execute_builtin(module, args, state)
    stdout
  end

  @doc """
  Create a minimal valid state for testing builtins.

  Includes working_dir, variables, aliases, functions, etc.
  """
  def minimal_state(overrides \\ %{}) do
    %{
      working_dir: File.cwd!(),
      variables: %{
        "PATH" => Variable.new("/usr/bin:/bin"),
        "HOME" => Variable.new(System.user_home!())
      },
      aliases: %{},
      functions: %{},
      options: %{},
      dir_stack: [],
      positional_params: [],
      last_exit_code: 0,
      jobs: %{},
      current_job: nil,
      previous_job: nil,
      in_function: false,
      loop_depth: 0
    }
    |> Map.merge(overrides)
  end

  # Ensure the state has minimal required fields
  defp ensure_defaults(state) do
    state
    |> Map.put_new(:working_dir, File.cwd!())
    |> Map.put_new(:variables, %{})
    |> Map.put_new(:aliases, %{})
    |> Map.put_new(:functions, %{})
    |> Map.put_new(:options, %{})
    |> Map.put_new(:dir_stack, [])
    |> Map.put_new(:positional_params, [])
    |> Map.put_new(:last_exit_code, 0)
    |> Map.put_new(:jobs, %{})
    |> Map.put_new(:current_job, nil)
    |> Map.put_new(:previous_job, nil)
    |> Map.put_new(:in_function, false)
    |> Map.put_new(:loop_depth, 0)
  end

  # Normalize various result formats to a consistent structure
  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:ok, result, updates}), do: {:ok, result, updates}
  defp normalize_result({:error, result}), do: {:error, result}
  defp normalize_result({:error, result, updates}), do: {:error, result, updates}
  defp normalize_result({:exit, result}), do: {:exit, result}
  defp normalize_result({:break, result, levels}), do: {:break, result, levels}
  defp normalize_result({:continue, result, levels}), do: {:continue, result, levels}
  defp normalize_result({:background_job, nums}), do: {:background_job, nums}
  defp normalize_result({:foreground_job, num}), do: {:foreground_job, num}
  defp normalize_result({:signal_jobs, signal, targets}), do: {:signal_jobs, signal, targets}
  defp normalize_result({:wait_for_jobs, specs}), do: {:wait_for_jobs, specs}
  defp normalize_result(other), do: other
end
