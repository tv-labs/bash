defmodule Bash.Builtin.Unsupported do
  @moduledoc """
  Handler for builtins that are not supported in this implementation.

  Some bash builtins require interactive terminal features (like tab completion
  or readline bindings) or OS-level features (like process suspension) that
  are not applicable to a non-interactive bash interpreter.

  Returns an appropriate error message explaining why the builtin is not supported.
  """
  use Bash.Builtin

  # Builtins that require interactive terminal features
  @interactive_builtins %{
    "bind" => "readline key bindings require an interactive terminal",
    "compgen" => "completion generation requires an interactive terminal",
    "complete" => "programmable completion requires an interactive terminal",
    "compopt" => "completion options require an interactive terminal",
    "select" => "menu selection requires an interactive terminal"
  }

  # Builtins that require OS-level features we don't support
  # Note: coproc and suspend are now implemented in their own modules
  @os_builtins %{}

  defbash execute(args, _state) do
    # Determine command name from context
    # The builtin registry passes the command name as the first implicit context
    # but we receive args. We need to figure out which builtin was called.
    # Since we can't easily get this, we check args or use a generic message.

    # Try to extract builtin name from process dictionary if set by dispatcher
    cmd_name = Process.get(:current_builtin_name) || extract_builtin_name(args)
    message = get_message(cmd_name)
    error("#{cmd_name}: #{message}")
    {:ok, 1}
  end

  # Execute with explicit command name (called by dispatcher when known).
  @doc false
  def execute_named(cmd_name, args, stdin, state) when is_binary(cmd_name) do
    Process.put(:current_builtin_name, cmd_name)
    result = execute(args, stdin, state)
    Process.delete(:current_builtin_name)
    result
  end

  defp extract_builtin_name([]), do: "builtin"
  defp extract_builtin_name([first | _]) when is_binary(first), do: first
  defp extract_builtin_name(_), do: "builtin"

  defp get_message(cmd_name) do
    cond do
      Map.has_key?(@interactive_builtins, cmd_name) ->
        @interactive_builtins[cmd_name]

      Map.has_key?(@os_builtins, cmd_name) ->
        @os_builtins[cmd_name]

      true ->
        "not supported in this implementation"
    end
  end

  # Returns list of all unsupported builtin names.
  @doc false
  def unsupported_builtins do
    Map.keys(@interactive_builtins) ++ Map.keys(@os_builtins)
  end

  # Check if a builtin is unsupported.
  @doc false
  def unsupported?(name) do
    Map.has_key?(@interactive_builtins, name) or Map.has_key?(@os_builtins, name)
  end

  # Get the reason a builtin is unsupported.
  @doc false
  def reason(name), do: get_message(name)
end
