defmodule Bash.Builtin.Suspend do
  @moduledoc """
  `suspend [-f]`

  Suspend the execution of this shell until it receives a SIGCONT signal.

  If the -f option is given, do not complain about this being a login shell;
  just suspend anyway.

  In this implementation, suspend returns a control flow signal that tells
  the session/executor to pause execution. The session should wait for a
  resume message before continuing.

  Exit Status:
  Returns success unless job control is not enabled or an error occurs.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/suspend.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.CommandResult

  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, opts} ->
        do_suspend(opts, state)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{force: false})
  end

  defp parse_args([], opts), do: {:ok, opts}
  defp parse_args(["-f" | rest], opts), do: parse_args(rest, %{opts | force: true})
  defp parse_args(["--" | _], opts), do: {:ok, opts}

  defp parse_args(["-" <> flags | rest], opts) when byte_size(flags) > 0 do
    if String.contains?(flags, "f") do
      parse_args(rest, %{opts | force: true})
    else
      {:error, "suspend: -#{String.first(flags)}: invalid option"}
    end
  end

  defp parse_args([arg | _], _opts) do
    {:error, "suspend: #{arg}: invalid argument"}
  end

  defp do_suspend(opts, session_state) do
    # Check if this is a login shell (unless -f is given)
    is_login_shell = Map.get(session_state, :login_shell, false)

    if is_login_shell and not opts.force do
      {:error, "suspend: cannot suspend a login shell"}
    else
      # Return the suspend control flow signal
      # The session/executor should handle this by pausing execution
      # and waiting for a resume message
      {:suspend, %CommandResult{command: "suspend", exit_code: 0}}
    end
  end
end
