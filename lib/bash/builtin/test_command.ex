defmodule Bash.Builtin.TestCommand do
  @moduledoc """
  Implementation of the POSIX test builtin.

  [ arg... ]
  test [arg...]

  `[` is a synonym for the "test" builtin, but the last argument must be a literal `]`, to match the opening `[`.

  See `Bash.Builtins.Test`

  Evaluates conditional expressions with operator precedence: ! > -a > -o
  """
  use Bash.Builtin

  alias Bash.Builtin.Test

  @doc """
  Execute the test command with the given arguments.

  Returns exit code 0 (true) or 1 (false).
  """
  defbash execute(args, state) do
    case args do
      [] ->
        {:ok, 1}

      _ ->
        case parse_args(args, state) do
          {:ok, result, []} ->
            exit_code = if result, do: 0, else: 1
            {:ok, exit_code}

          {:ok, _result, remaining} ->
            error("test: unexpected arguments: #{inspect(remaining)}")
            {:ok, 2}

          {:error, reason} ->
            error("test: #{reason}")
            {:ok, 2}
        end
    end
  end

  # Operator precedence: -o (OR) - lowest precedence
  defp parse_args(args, state) do
    case parse_and_arg(args, state) do
      {:ok, left_result, ["-o" | rest]} ->
        case parse_args(rest, state) do
          {:ok, right_result, remaining} ->
            {:ok, left_result or right_result, remaining}

          error ->
            error
        end

      {:ok, result, []} ->
        {:ok, result, []}

      {:ok, _result, remaining} ->
        {:error, "unexpected arguments: #{inspect(remaining)}"}

      error ->
        error
    end
  end

  # Operator precedence: -a (AND) - medium precedence
  defp parse_and_arg(args, state) do
    case parse_unary(args, state) do
      {:ok, left_result, ["-a" | rest]} ->
        case parse_and_arg(rest, state) do
          {:ok, right_result, remaining} ->
            {:ok, left_result and right_result, remaining}

          error ->
            error
        end

      result ->
        result
    end
  end

  # Operator precedence: ! (NOT) - highest precedence
  defp parse_unary(["!" | rest], state) do
    case parse_unary(rest, state) do
      {:ok, result, remaining} -> {:ok, !result, remaining}
      error -> error
    end
  end

  defp parse_unary(args, state) do
    parse(args, state)
  end

  # String comparisons
  defp parse([left, "=", right | rest], _state) do
    {:ok, left == right, rest}
  end

  defp parse([left, "!=", right | rest], _state) do
    {:ok, left != right, rest}
  end

  # String comparisons (lexicographic)
  defp parse([left, "<", right | rest], _state) do
    {:ok, left < right, rest}
  end

  defp parse([left, ">", right | rest], _state) do
    {:ok, left > right, rest}
  end

  # Numeric comparisons
  defp parse([left, "-eq", right | rest], _state) do
    {:ok, Test.to_integer(left) == Test.to_integer(right), rest}
  end

  defp parse([left, "-ne", right | rest], _state) do
    {:ok, Test.to_integer(left) != Test.to_integer(right), rest}
  end

  defp parse([left, "-lt", right | rest], _state) do
    {:ok, Test.to_integer(left) < Test.to_integer(right), rest}
  end

  defp parse([left, "-le", right | rest], _state) do
    {:ok, Test.to_integer(left) <= Test.to_integer(right), rest}
  end

  defp parse([left, "-gt", right | rest], _state) do
    {:ok, Test.to_integer(left) > Test.to_integer(right), rest}
  end

  defp parse([left, "-ge", right | rest], _state) do
    {:ok, Test.to_integer(left) >= Test.to_integer(right), rest}
  end

  # File comparisons
  defp parse([file1, "-nt", file2 | rest], state) do
    {:ok, Test.file_newer_than?(file1, file2, state), rest}
  end

  defp parse([file1, "-ot", file2 | rest], state) do
    {:ok, Test.file_older_than?(file1, file2, state), rest}
  end

  defp parse([file1, "-ef", file2 | rest], state) do
    {:ok, Test.file_same_file?(file1, file2, state), rest}
  end

  # Primary expressions - unary operators

  # File type tests
  defp parse(["-f", path | rest], state) do
    {:ok, Test.file_regular?(path, state), rest}
  end

  defp parse(["-d", path | rest], state) do
    {:ok, Test.file_directory?(path, state), rest}
  end

  defp parse(["-e", path | rest], state) do
    {:ok, Test.file_exists?(path, state), rest}
  end

  defp parse(["-a", path | rest], state) do
    {:ok, Test.file_exists?(path, state), rest}
  end

  defp parse(["-L", path | rest], state) do
    {:ok, Test.file_symlink?(path, state), rest}
  end

  defp parse(["-h", path | rest], state) do
    {:ok, Test.file_symlink?(path, state), rest}
  end

  defp parse(["-b", path | rest], state) do
    {:ok, Test.file_block_special?(path, state), rest}
  end

  defp parse(["-c", path | rest], state) do
    {:ok, Test.file_char_special?(path, state), rest}
  end

  defp parse(["-p", path | rest], state) do
    {:ok, Test.file_named_pipe?(path, state), rest}
  end

  defp parse(["-S", path | rest], state) do
    {:ok, Test.file_socket?(path, state), rest}
  end

  # File permission tests
  defp parse(["-r", path | rest], state) do
    {:ok, Test.file_readable?(path, state), rest}
  end

  defp parse(["-w", path | rest], state) do
    {:ok, Test.file_writable?(path, state), rest}
  end

  defp parse(["-x", path | rest], state) do
    {:ok, Test.file_executable?(path, state), rest}
  end

  # File attribute tests
  defp parse(["-s", path | rest], state) do
    {:ok, Test.file_not_empty?(path, state), rest}
  end

  defp parse(["-g", path | rest], state) do
    {:ok, Test.file_setgid?(path, state), rest}
  end

  defp parse(["-k", path | rest], state) do
    {:ok, Test.file_sticky_bit?(path, state), rest}
  end

  defp parse(["-u", path | rest], state) do
    {:ok, Test.file_setuid?(path, state), rest}
  end

  defp parse(["-O", path | rest], state) do
    {:ok, Test.file_owned_by_user?(path, state), rest}
  end

  defp parse(["-G", path | rest], state) do
    {:ok, Test.file_owned_by_group?(path, state), rest}
  end

  defp parse(["-N", path | rest], state) do
    {:ok, Test.file_modified_since_read?(path, state), rest}
  end

  defp parse(["-t", fd | rest], _state) do
    {:ok, Test.fd_is_terminal?(fd), rest}
  end

  # String tests
  defp parse(["-z", str | rest], _state) do
    {:ok, str == "", rest}
  end

  defp parse(["-n", str | rest], _state) do
    {:ok, str != "", rest}
  end

  # Unary operator without argument - error
  defp parse([op], _state)
       when op in ~w[-f -d -e -a -r -w -x -s -z -n -b -c -g -h -k -p -t -u -L -O -G -N -S] do
    {:error, "unary operator expected argument"}
  end

  # String alone - true if not empty
  defp parse([str], _state) when is_binary(str) do
    {:ok, str != "", []}
  end

  defp parse([str | rest], _state) when is_binary(str) do
    {:ok, str != "", rest}
  end

  defp parse([], _state) do
    {:error, "too few arguments"}
  end
end
