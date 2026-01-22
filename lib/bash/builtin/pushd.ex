defmodule Bash.Builtin.Pushd do
  @moduledoc """
  `pushd [-n] [dir | +N | -N]`
  Add directories to the directory stack.

  Adds a directory to the top of the directory stack, or rotates the stack, making the new top of the stack the current working directory. With no arguments, exchanges the top two directories.

  Arguments:
  - `dir` - Adds DIR to the directory stack at the top, making it the new current working directory.

  - `+N` - Rotates the stack so that the Nth directory (counting from the left of the list shown by `dirs', starting with zero) is at the top.

  - `-N` - Rotates the stack so that the Nth directory (counting from the right of the list shown by `dirs', starting with zero) is at the top.

  Options:
  - `-n` - Suppresses the normal change of directory when adding directories to the stack, so only the stack is manipulated.

  You can see the directory stack with the `dirs` command.

  Exit Status:
  Returns success unless an invalid argument is supplied or the directory change fails.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Directory-Stack-Builtins.html
  """
  use Bash.Builtin

  alias Bash.Variable
  alias Bash.Builtin.Dirs

  defbash execute(args, state) do
    case parse_args(args) do
      {:swap, opts} ->
        swap_top_two(opts, state)

      {:push, dir, opts} ->
        push_directory(dir, opts, state)

      {:rotate, :left, n, opts} ->
        rotate_stack(n, :left, opts, state)

      {:rotate, :right, n, opts} ->
        rotate_stack(n, :right, opts, state)

      {:error, message} ->
        error("pushd: #{message}")
        {:ok, 1}
    end
  end

  # Parse command arguments
  defp parse_args(args) do
    parse_args(args, %{no_cd: false}, nil)
  end

  defp parse_args([], opts, nil), do: {:swap, opts}
  defp parse_args([], opts, {:dir, dir}), do: {:push, dir, opts}
  defp parse_args([], opts, {:rotate, direction, n}), do: {:rotate, direction, n, opts}

  defp parse_args(["-n" | rest], opts, target) do
    parse_args(rest, %{opts | no_cd: true}, target)
  end

  # +N index from left
  defp parse_args(["+" <> n_str | rest], opts, _target) do
    case Integer.parse(n_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, opts, {:rotate, :left, n})

      _ ->
        {:error, "#{n_str}: invalid number"}
    end
  end

  # -N index from right (if it's a number)
  defp parse_args(["-" <> n_str | rest], opts, _target) do
    case Integer.parse(n_str) do
      {n, ""} when n >= 0 ->
        parse_args(rest, opts, {:rotate, :right, n})

      _ ->
        {:error, "-#{n_str}: invalid option"}
    end
  end

  # Directory argument
  defp parse_args([dir | rest], opts, _target) do
    parse_args(rest, opts, {:dir, dir})
  end

  # Swap the top two directories
  defp swap_top_two(opts, session_state) do
    stack = Map.get(session_state, :dir_stack, [])

    case stack do
      [] ->
        error("pushd: no other directory")
        {:ok, 1}

      [second | rest] ->
        cwd = session_state.working_dir

        if opts.no_cd do
          # Only manipulate stack, don't change directory
          new_stack = [cwd | rest]
          write(format_stack_output(second, new_stack, session_state))
          update_state(dir_stack: new_stack)
          :ok
        else
          # Swap and change directory
          case validate_directory(second) do
            :ok ->
              new_stack = [cwd | rest]
              write(format_stack_output(second, new_stack, session_state))

              update_state(
                working_dir: second,
                dir_stack: new_stack,
                env_updates: %{
                  "PWD" => second,
                  "OLDPWD" => cwd
                }
              )

              :ok

            {:error, reason} ->
              error("pushd: #{second}: #{reason}")
              {:ok, 1}
          end
        end
    end
  end

  # Push a new directory onto the stack
  defp push_directory(dir, opts, session_state) do
    # Expand tilde
    expanded_dir = expand_tilde(dir, session_state)

    # Resolve relative paths
    resolved_dir = resolve_path(expanded_dir, session_state)

    case validate_directory(resolved_dir) do
      :ok ->
        cwd = session_state.working_dir
        stack = Map.get(session_state, :dir_stack, [])

        if opts.no_cd do
          # Only push to stack, don't change directory
          new_stack = [resolved_dir | stack]
          write(format_stack_output(cwd, new_stack, session_state))
          update_state(dir_stack: new_stack)
          :ok
        else
          # Push current directory to stack and change to new directory
          new_stack = [cwd | stack]
          write(format_stack_output(resolved_dir, new_stack, session_state))

          update_state(
            working_dir: resolved_dir,
            dir_stack: new_stack,
            env_updates: %{
              "PWD" => resolved_dir,
              "OLDPWD" => cwd
            }
          )

          :ok
        end

      {:error, reason} ->
        error("pushd: #{dir}: #{reason}")
        {:ok, 1}
    end
  end

  # Rotate the stack to bring Nth entry to top
  defp rotate_stack(n, direction, opts, session_state) do
    full_stack = Dirs.get_full_stack(session_state)
    stack_size = length(full_stack)

    index =
      case direction do
        :left -> n
        :right -> stack_size - 1 - n
      end

    if index < 0 or index >= stack_size do
      sign = if direction == :left, do: "+", else: "-"
      error("pushd: #{sign}#{n}: directory stack index out of range")
      {:ok, 1}
    else
      # Rotate the stack
      {left, right} = Enum.split(full_stack, index)
      [new_cwd | rest_right] = right
      rotated_stack = rest_right ++ left

      if opts.no_cd do
        # Only rotate, don't change directory (put new_cwd back on stack)
        # This is a weird case - with -n, the rotation still happens but we don't cd
        new_stack = [new_cwd | rotated_stack]
        # But the output still shows the rotated stack with cwd at position 0
        write(
          format_stack_output(
            session_state.working_dir,
            List.delete_at(new_stack, 0),
            session_state
          )
        )

        update_state(
          dir_stack:
            (rotated_stack ++ [new_cwd]) |> List.delete_at(-1) |> then(&[new_cwd | &1]) |> tl()
        )

        :ok
      else
        case validate_directory(new_cwd) do
          :ok ->
            write(format_stack_output(new_cwd, rotated_stack, session_state))

            update_state(
              working_dir: new_cwd,
              dir_stack: rotated_stack,
              env_updates: %{
                "PWD" => new_cwd,
                "OLDPWD" => session_state.working_dir
              }
            )

            :ok

          {:error, reason} ->
            error("pushd: #{new_cwd}: #{reason}")
            {:ok, 1}
        end
      end
    end
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

  # Expand tilde in path
  defp expand_tilde("~", session_state) do
    get_home(session_state) || "~"
  end

  defp expand_tilde("~/" <> path, session_state) do
    home = get_home(session_state) || "~"
    Path.join(home, path)
  end

  defp expand_tilde(path, _session_state), do: path

  # Resolve path relative to current directory
  defp resolve_path(path, session_state) do
    if String.starts_with?(path, "/") do
      Path.expand(path)
    else
      Path.expand(Path.join(session_state.working_dir, path))
    end
  end

  # Format the stack output after operation
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
