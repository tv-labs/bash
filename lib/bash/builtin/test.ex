defmodule Bash.Builtin.Test do
  @moduledoc """
  `test [expr]`

  Shared helper functions for test command and test expression builtins.

  Exits with a status of 0 (true) or 1 (false) depending on the evaluation of EXPR. Expressions may be unary or binary. Unary expressions are often used to examine the status of a file. There are string operators as well, and numeric comparison operators.

  File operators:

  - `-a FILE` - True if file exists.
  - `-b FILE` - True if file is block special.
  - `-c FILE` - True if file is character special.
  - `-d FILE` - True if file is a directory.
  - `-e FILE` - True if file exists.
  - `-f FILE` - True if file exists and is a regular file.
  - `-g FILE` - True if file is set-group-id.
  - `-h FILE` - True if file is a symbolic link.
  - `-L FILE` - True if file is a symbolic link.
  - `-k FILE` - True if file has its "sticky" bit set.
  - `-p FILE` - True if file is a named pipe.
  - `-r FILE` - True if file is readable by you.
  - `-s FILE` - True if file exists and is not empty.
  - `-S FILE` - True if file is a socket.
  - `-t FD  ` - True if FD is opened on a terminal.
  - `-u FILE` - True if the file is set-user-id.
  - `-w FILE` - True if the file is writable by you.
  - `-x FILE` - True if the file is executable by you.
  - `-O FILE` - True if the file is effectively owned by you.
  - `-G FILE` - True if the file is effectively owned by your group.
  - `-N FILE` - True if the file has been modified since it was last read.
  - `FILE1 -nt FILE2` - True if file1 is newer than file2 (according to modification date).
  - `FILE1 -ot FILE2` - True if file1 is older than file2.
  - `FILE1 -ef FILE2` - True if file1 is a hard link to file2.

  String operators:

  - `-z STRING` - True if string is empty.
  - `-n STRING` - True if string is not empty.
  - `STRING` - True if string is not empty.
  - `STRING1 = STRING2` - True if the strings are equal.
  - `STRING1 != STRING2` - True if the strings are not equal.
  - `STRING1 < STRING2` - True if STRING1 sorts before STRING2 lexicographically.
  - `STRING1 > STRING2` - True if STRING1 sorts after STRING2 lexicographically.

  Other operators:

  - `-o OPTION` - True if the shell option OPTION is enabled.
  - `! EXPR` - True if expr is false.
  - `EXPR1 -a EXPR2` - True if both expr1 AND expr2 are true.
  - `EXPR1 -o EXPR2` - True if either expr1 OR expr2 is true.
  - `arg1 OP arg2` - Arithmetic tests. OP is one of `-eq`, `-ne`, `-lt`, `-le`, `-gt`, or `-ge`.

  Arithmetic binary operators return true if ARG1 is equal, not-equal, less-than, less-than-or-equal, greater-than, or greater-than-or-equal than ARG2.
  """

  import Bitwise

  @doc """
  Resolve a path relative to the working directory.
  """
  def resolve_path(path, working_dir) do
    if Path.absname(path) == path do
      path
    else
      Path.join(working_dir, path)
    end
  end

  @doc """
  Convert a string to an integer, returning 0 for invalid strings.
  """
  def to_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> 0
    end
  end

  def to_integer(val), do: val

  # File existence and type checks
  def file_exists?(path, state) do
    full_path = resolve_path(path, state.working_dir)
    File.exists?(full_path)
  end

  def file_regular?(path, state) do
    full_path = resolve_path(path, state.working_dir)
    File.regular?(full_path)
  end

  def file_directory?(path, state) do
    full_path = resolve_path(path, state.working_dir)
    File.dir?(full_path)
  end

  def file_symlink?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.lstat(full_path) do
      {:ok, stat} -> stat.type == :symlink
      _ -> false
    end
  end

  # File permission checks
  def file_readable?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> (stat.mode &&& 0o444) != 0
      _ -> false
    end
  end

  def file_writable?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> (stat.mode &&& 0o222) != 0
      _ -> false
    end
  end

  def file_executable?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> (stat.mode &&& 0o111) != 0
      _ -> false
    end
  end

  # File attribute checks
  def file_not_empty?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> stat.size > 0
      _ -> false
    end
  end

  def file_block_special?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.lstat(full_path) do
      {:ok, stat} -> stat.type == :device
      _ -> false
    end
  end

  def file_char_special?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.lstat(full_path) do
      {:ok, stat} -> stat.type == :device
      _ -> false
    end
  end

  def file_named_pipe?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.lstat(full_path) do
      {:ok, stat} -> stat.type == :other
      _ -> false
    end
  end

  def file_socket?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.lstat(full_path) do
      {:ok, stat} -> stat.type == :other
      _ -> false
    end
  end

  def file_setgid?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> (stat.mode &&& 0o2000) != 0
      _ -> false
    end
  end

  def file_sticky_bit?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> (stat.mode &&& 0o1000) != 0
      _ -> false
    end
  end

  def file_setuid?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> (stat.mode &&& 0o4000) != 0
      _ -> false
    end
  end

  def file_owned_by_user?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> stat.uid == "UID" |> System.get_env("0") |> String.to_integer()
      _ -> false
    end
  end

  def file_owned_by_group?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> stat.gid == "GID" |> System.get_env("0") |> String.to_integer()
      _ -> false
    end
  end

  def file_modified_since_read?(path, state) do
    full_path = resolve_path(path, state.working_dir)

    case File.stat(full_path) do
      {:ok, stat} -> stat.mtime > stat.atime
      _ -> false
    end
  end

  # File comparison checks
  def file_newer_than?(file1, file2, state) do
    path1 = resolve_path(file1, state.working_dir)
    path2 = resolve_path(file2, state.working_dir)

    with {:ok, stat1} <- File.stat(path1),
         {:ok, stat2} <- File.stat(path2) do
      stat1.mtime > stat2.mtime
    else
      _ -> false
    end
  end

  def file_older_than?(file1, file2, state) do
    path1 = resolve_path(file1, state.working_dir)
    path2 = resolve_path(file2, state.working_dir)

    with {:ok, stat1} <- File.stat(path1),
         {:ok, stat2} <- File.stat(path2) do
      stat1.mtime < stat2.mtime
    else
      _ -> false
    end
  end

  def file_same_file?(file1, file2, state) do
    path1 = resolve_path(file1, state.working_dir)
    path2 = resolve_path(file2, state.working_dir)

    with {:ok, stat1} <- File.stat(path1),
         {:ok, stat2} <- File.stat(path2) do
      stat1.inode == stat2.inode and stat1.major_device == stat2.major_device
    else
      _ -> false
    end
  end

  # Terminal check
  def fd_is_terminal?(fd) do
    case Integer.parse(fd) do
      {0, _} -> true
      {1, _} -> true
      {2, _} -> true
      _ -> false
    end
  end
end
