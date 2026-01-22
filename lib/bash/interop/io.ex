defmodule Bash.Interop.IO do
  @moduledoc false
  # Internal module for managing I/O context within defbash functions.
  # Users should call the public API on the Bash module instead.

  @context_key :bash_interop_context

  @doc false
  def init_context(stdin, state) do
    context = %{
      stdin: stdin,
      state: state,
      stdout: [],
      stderr: []
    }

    Process.put(@context_key, context)
    :ok
  end

  @doc false
  def finalize_context do
    case Process.delete(@context_key) do
      nil ->
        {"", "", %{}}

      context ->
        stdout = context.stdout |> Enum.reverse() |> IO.iodata_to_binary()
        stderr = context.stderr |> Enum.reverse() |> IO.iodata_to_binary()
        {stdout, stderr, context.state}
    end
  end

  @doc false
  def puts(message) do
    update_context(fn context ->
      %{context | stdout: [message | context.stdout]}
    end)

    :ok
  end

  @doc false
  def puts(:stdout, message), do: puts(message)

  def puts(:stderr, message) do
    update_context(fn context ->
      %{context | stderr: [message | context.stderr]}
    end)

    :ok
  end

  @doc false
  def stream(:stdin) do
    case get_context() do
      nil ->
        Stream.map([], & &1)

      context ->
        case context.stdin do
          nil -> Stream.map([], & &1)
          list when is_list(list) -> Stream.map(list, & &1)
          stream -> stream
        end
    end
  end

  @doc false
  def get_state do
    case get_context() do
      nil -> %{}
      context -> context.state
    end
  end

  @doc false
  def put_state(new_state) do
    update_context(fn context ->
      %{context | state: new_state}
    end)

    :ok
  end

  defp get_context, do: Process.get(@context_key)

  defp update_context(fun) do
    case get_context() do
      nil ->
        :ok

      context ->
        Process.put(@context_key, fun.(context))
        :ok
    end
  end
end
