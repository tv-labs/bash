defmodule Bash.Builtin.Dirs do
  @moduledoc """
  `dirs [-clpv] [+N] [-N]`
  Display directory stack.

  Display the list of currently remembered directories. Directories find their way onto the list with the `pushd` command; you can get back up through the list with the `popd` command.

  Options:
  - `-c` - clear the directory stack by deleting all of the elements
  - `-l` - do not print tilde-prefixed versions of directories relative to your home directory
  - `-p` - print the directory stack with one entry per line
  - `-v` - print the directory stack with one entry per line prefixed with its position in the stack

  Arguments:
  - `+N`  Displays the Nth entry counting from the left of the list shown by dirs when invoked without options, starting with zero.

  - `-N ` Displays the Nth entry counting from the right of the list shown by dirs when invoked without options, starting with zero.

  Exit Status:
  Returns success unless an invalid option is supplied or an error occurs.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Directory-Stack-Builtins.html
  """
  use Bash.Builtin

  alias Bash.Variable

  defbash execute(args, state) do
    case parse_args(args) do
      {:clear} ->
        clear_stack()

      {:display, opts} ->
        display_stack(opts, state)

      {:index, :left, n} ->
        display_nth(n, :left, state)

      {:index, :right, n} ->
        display_nth(n, :right, state)

      {:error, message} ->
        error("dirs: #{message}")
        {:ok, 1}
    end
  end

  # Parse command arguments
  defp parse_args(args) do
    parse_args(args, %{long_format: false, per_line: false, with_index: false})
  end

  defp parse_args([], opts), do: {:display, opts}

  defp parse_args(["-c" | _rest], _opts), do: {:clear}

  defp parse_args(["-l" | rest], opts) do
    parse_args(rest, %{opts | long_format: true})
  end

  defp parse_args(["-p" | rest], opts) do
    parse_args(rest, %{opts | per_line: true})
  end

  defp parse_args(["-v" | rest], opts) do
    parse_args(rest, %{opts | per_line: true, with_index: true})
  end

  # Combined options like -lp, -pv, etc.
  defp parse_args(["-" <> flags | rest], opts) when byte_size(flags) > 1 do
    case parse_combined_flags(flags, opts) do
      {:ok, new_opts} -> parse_args(rest, new_opts)
      {:error, _} = err -> err
      {:clear} -> {:clear}
    end
  end

  # +N index from left
  defp parse_args(["+" <> n_str | _rest], _opts) do
    case Integer.parse(n_str) do
      {n, ""} when n >= 0 -> {:index, :left, n}
      _ -> {:error, "#{n_str}: invalid number"}
    end
  end

  # -N index from right (only if it's a number)
  defp parse_args(["-" <> n_str | _rest], _opts) do
    case Integer.parse(n_str) do
      {n, ""} when n >= 0 -> {:index, :right, n}
      _ -> {:error, "-#{n_str}: invalid option"}
    end
  end

  defp parse_args([arg | _rest], _opts) do
    {:error, "#{arg}: invalid argument"}
  end

  # Parse combined flags like -lp, -pv
  defp parse_combined_flags("", opts), do: {:ok, opts}

  defp parse_combined_flags("c" <> _rest, _opts), do: {:clear}

  defp parse_combined_flags("l" <> rest, opts) do
    parse_combined_flags(rest, %{opts | long_format: true})
  end

  defp parse_combined_flags("p" <> rest, opts) do
    parse_combined_flags(rest, %{opts | per_line: true})
  end

  defp parse_combined_flags("v" <> rest, opts) do
    parse_combined_flags(rest, %{opts | per_line: true, with_index: true})
  end

  defp parse_combined_flags(<<char, _rest::binary>>, _opts) do
    {:error, "-#{<<char>>}: invalid option"}
  end

  # Clear the directory stack
  defp clear_stack do
    update_state(dir_stack: [])
    :ok
  end

  # Display the directory stack
  defp display_stack(opts, session_state) do
    # The stack includes the current directory at position 0
    stack = get_full_stack(session_state)
    home = get_home(session_state)

    formatted =
      stack
      |> Enum.with_index()
      |> Enum.map(fn {dir, index} ->
        formatted_dir =
          if opts.long_format do
            dir
          else
            maybe_tilde_contract(dir, home)
          end

        if opts.with_index do
          " #{index}  #{formatted_dir}"
        else
          formatted_dir
        end
      end)

    output =
      if opts.per_line do
        Enum.map_join(formatted, "", &"#{&1}\n")
      else
        Enum.join(formatted, " ") <> "\n"
      end

    write(output)
    :ok
  end

  # Display Nth entry from the stack
  defp display_nth(n, direction, session_state) do
    stack = get_full_stack(session_state)
    stack_size = length(stack)

    index =
      case direction do
        :left -> n
        :right -> stack_size - 1 - n
      end

    if index < 0 or index >= stack_size do
      sign = if direction == :left, do: "+", else: "-"
      error("dirs: #{sign}#{n}: directory stack index out of range")
      {:ok, 1}
    else
      dir = Enum.at(stack, index)
      home = get_home(session_state)
      formatted_dir = maybe_tilde_contract(dir, home)
      puts(formatted_dir)
      :ok
    end
  end

  # Get the full directory stack including current directory at position 0
  @doc false
  def get_full_stack(session_state) do
    cwd = session_state.working_dir
    stack = Map.get(session_state, :dir_stack, [])
    [cwd | stack]
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
