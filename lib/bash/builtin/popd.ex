defmodule Bash.Builtin.Popd do
  @moduledoc """
  `popd [-n] [+N | -N]`
  Remove entries from the directory stack.

  Removes entries from the directory stack. With no arguments, removes the top directory from the stack, and changes to the new top directory.

  Options:
  - `-n` - Suppresses the normal change of directory when removing directories from the stack, so only the stack is manipulated.

  Arguments:
  - `+N` - Removes the Nth entry counting from the left of the list shown by `dirs`, starting with zero. For example: `popd +0` removes the first directory, `popd +1` the second.

  - `-N` - Removes the Nth entry counting from the right of the list shown by `dirs`, starting with zero. For example: `popd -0` removes the last directory, `popd -1` the next to last.

  Exit Status:
  Returns success unless an invalid argument is supplied or the directory change fails.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Directory-Stack-Builtins.html
  """
  use Bash.Builtin

  alias Bash.Variable
  alias Bash.Builtin.Dirs

  defbash execute(args, state) do
    case parse_args(args) do
      {:pop, opts} ->
        pop_directory(opts, state)

      {:remove, :left, n, opts} ->
        remove_nth(n, :left, opts, state)

      {:remove, :right, n, opts} ->
        remove_nth(n, :right, opts, state)

      {:error, message} ->
        error("popd: #{message}")
        {:ok, 1}
    end
  end

  # Parse command arguments
  defp parse_args(args) do
    parse_args(args, %{no_cd: false})
  end

  defp parse_args([], opts), do: {:pop, opts}

  defp parse_args(["-n" | rest], opts) do
    parse_args(rest, %{opts | no_cd: true})
  end

  # +N index from left
  defp parse_args(["+" <> n_str | rest], opts) do
    case Integer.parse(n_str) do
      {n, ""} when n >= 0 ->
        # Check for any remaining -n flag
        opts = check_remaining_flags(rest, opts)
        {:remove, :left, n, opts}

      _ ->
        {:error, "#{n_str}: invalid number"}
    end
  end

  # -N index from right (if it's a number)
  defp parse_args(["-" <> n_str | rest], opts) do
    case Integer.parse(n_str) do
      {n, ""} when n >= 0 ->
        # Check for any remaining -n flag
        opts = check_remaining_flags(rest, opts)
        {:remove, :right, n, opts}

      _ ->
        {:error, "-#{n_str}: invalid option"}
    end
  end

  defp parse_args([arg | _rest], _opts) do
    {:error, "#{arg}: invalid argument"}
  end

  # Check for -n flag in remaining arguments
  defp check_remaining_flags([], opts), do: opts

  defp check_remaining_flags(["-n" | rest], opts) do
    check_remaining_flags(rest, %{opts | no_cd: true})
  end

  defp check_remaining_flags([_ | rest], opts), do: check_remaining_flags(rest, opts)

  # Pop the top directory from the stack
  defp pop_directory(opts, session_state) do
    stack = Map.get(session_state, :dir_stack, [])

    case stack do
      [] ->
        error("popd: directory stack empty")
        {:ok, 1}

      [new_top | rest] ->
        if opts.no_cd do
          # Only manipulate stack, don't change directory
          write(format_stack_output(session_state.working_dir, rest, session_state))
          update_state(dir_stack: rest)
          :ok
        else
          # Change to new top and update stack
          case validate_directory(new_top) do
            :ok ->
              write(format_stack_output(new_top, rest, session_state))
              old_pwd = session_state.working_dir

              update_state(
                working_dir: new_top,
                dir_stack: rest,
                env_updates: %{
                  "PWD" => new_top,
                  "OLDPWD" => old_pwd
                }
              )

              :ok

            {:error, reason} ->
              error("popd: #{new_top}: #{reason}")
              {:ok, 1}
          end
        end
    end
  end

  # Remove Nth entry from the stack
  defp remove_nth(n, direction, opts, session_state) do
    full_stack = Dirs.get_full_stack(session_state)
    stack_size = length(full_stack)

    index =
      case direction do
        :left -> n
        :right -> stack_size - 1 - n
      end

    if index < 0 or index >= stack_size do
      sign = if direction == :left, do: "+", else: "-"
      error("popd: #{sign}#{n}: directory stack index out of range")
      {:ok, 1}
    else
      # Remove the entry at index
      # full_stack = [cwd | dir_stack], so index 0 is cwd, index 1+ is dir_stack
      cond do
        # Removing current directory (index 0)
        index == 0 ->
          remove_current_directory(opts, session_state)

        # Removing from dir_stack
        true ->
          dir_stack = Map.get(session_state, :dir_stack, [])
          # Adjust index since dir_stack doesn't include cwd
          stack_index = index - 1
          new_stack = List.delete_at(dir_stack, stack_index)
          write(format_stack_output(session_state.working_dir, new_stack, session_state))
          update_state(dir_stack: new_stack)
          :ok
      end
    end
  end

  # Remove current directory (index 0) - same as regular popd
  defp remove_current_directory(opts, session_state) do
    pop_directory(opts, session_state)
  end

  # Validate that the path is a directory
  defp validate_directory(path) do
    cond do
      not File.exists?(path) ->
        {:error, "No such file or directory"}

      not File.dir?(path) ->
        {:error, "Not a directory"}

      true ->
        :ok
    end
  end

  # Format the stack output after popping
  defp format_stack_output(cwd, stack, session_state) do
    home = get_home(session_state)
    full_stack = [cwd | stack]

    formatted =
      full_stack
      |> Enum.map(&maybe_tilde_contract(&1, home))
      |> Enum.join(" ")

    formatted <> "\n"
  end

  # Get HOME directory
  defp get_home(session_state) do
    case Map.get(session_state.variables, "HOME") do
      nil -> nil
      %Variable{} = var -> Variable.get(var, nil)
    end
  end

  # Contract path with ~ if it starts with HOME
  defp maybe_tilde_contract(path, nil), do: path

  defp maybe_tilde_contract(path, home) do
    if String.starts_with?(path, home) do
      case String.trim_leading(path, home) do
        "" -> "~"
        "/" <> rest -> "~/" <> rest
        rest -> "~" <> rest
      end
    else
      path
    end
  end
end
