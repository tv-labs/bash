defmodule Bash.Builtin.Shift do
  @moduledoc """
  `shift [n]`

  The positional parameters from $N+1 ... are renamed to $1 ...  If N is
  not given, it is assumed to be 1.

  Exit status: 0 on success, 1 if n is greater than the number of positional
  parameters or less than zero.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/shift.def?h=bash-5.3
  """
  use Bash.Builtin

  defbash execute(args, state) do
    case args do
      [] ->
        do_shift(1, state)

      [n_str] ->
        case Integer.parse(n_str) do
          {n, ""} when n >= 0 ->
            do_shift(n, state)

          {n, ""} when n < 0 ->
            error("shift: #{n}: shift count out of range")
            {:ok, 1}

          _ ->
            error("shift: #{n_str}: numeric argument required")
            {:ok, 1}
        end

      [_ | _] ->
        error("shift: too many arguments")
        {:ok, 1}
    end
  end

  defp do_shift(n, session_state) do
    [current_scope | rest_scopes] = session_state.positional_params

    case drop_n(current_scope, n) do
      {:ok, new_scope} ->
        new_positional_params = [new_scope | rest_scopes]
        update_state(positional_params: new_positional_params)
        :ok

      :error ->
        error("shift: #{n}: shift count out of range")
        {:ok, 1}
    end
  end

  # Drop n elements from list without using length()
  # Returns {:ok, rest} on success, :error if n > list length
  defp drop_n(list, 0), do: {:ok, list}
  defp drop_n([], _n), do: :error
  defp drop_n([_ | rest], n), do: drop_n(rest, n - 1)
end
