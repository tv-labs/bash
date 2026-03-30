defmodule Bash.Filesystem.ETS do
  @moduledoc """
  In-memory filesystem implementation backed by an ETS table.

  Implements `Bash.Filesystem` using ETS for fast, concurrent reads.
  Each entry in the table is a 4-tuple:

      {path :: String.t(), type :: :file | :dir, content :: binary() | nil, stat :: File.Stat.t()}

  ## Usage

      # Create with POSIX skeleton directories pre-seeded
      tid = Bash.Filesystem.ETS.new()
      {:ok, session} = Bash.Session.new(filesystem: {Bash.Filesystem.ETS, tid})

      # Create with custom seed files and directories
      tid =
        Bash.Filesystem.ETS.new(%{
          "/home/user/.bashrc" => "export PATH=/usr/bin:\\$PATH",
          "/usr/local/bin/myscript" => %{content: "#!/bin/bash\\necho hi", mode: 0o755},
          "/var/data" => {:dir, nil}
        })

      {:ok, session} = Bash.Session.new(filesystem: {Bash.Filesystem.ETS, tid})

  ## Magic device paths

  `/dev/null`, `/dev/stdin`, `/dev/stdout`, and `/dev/stderr` are intercepted
  at the callback level and never stored in the ETS table. `/dev/null` is
  readable (returns `""`), while `/dev/stdout` and `/dev/stderr` return
  `{:error, :eacces}` on read.

  ## ETS table lifecycle

  The caller owns the ETS table and is responsible for deleting it via
  `:ets.delete/1` when it is no longer needed.
  """

  @behaviour Bash.Filesystem

  @magic_devices ["/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr"]

  @posix_skeleton ["/", "/tmp", "/dev", "/bin", "/usr", "/usr/bin", "/home"]

  @doc """
  Creates a new ETS table seeded with the POSIX skeleton directories.

  The table is created with `:public` access and `{:keypos, 1}` so the path
  string is the lookup key.
  """
  @spec new() :: :ets.tid()
  def new do
    new(%{})
  end

  @doc """
  Creates a new ETS table seeded with POSIX skeleton dirs plus the given `seed` map.

  Seed value forms:

    - `"content"` — a regular file with mode `0o644`
    - `%{content: "...", mode: 0o755}` — a regular file with explicit mode (defaults to `0o644`)
    - `{:dir, nil}` — an empty directory with mode `0o755`

  Parent directories are auto-created for all seeded paths.
  """
  @spec new(seed :: map()) :: :ets.tid()
  def new(seed) when is_map(seed) do
    tid = :ets.new(:bash_filesystem, [:set, :public, {:keypos, 1}])

    Enum.each(@posix_skeleton, &insert_dir(tid, &1, 0o755))

    Enum.each(seed, fn {path, value} ->
      Enum.each(parent_paths(path), fn parent ->
        unless :ets.member(tid, parent) do
          insert_dir(tid, parent, 0o755)
        end
      end)

      insert_seed(tid, path, value)
    end)

    tid
  end

  @impl true
  def exists?(_tid, path) when path in @magic_devices, do: true

  def exists?(tid, path) do
    :ets.member(tid, path)
  end

  @impl true
  def dir?(_tid, path) when path in @magic_devices, do: false

  def dir?(tid, path) do
    case :ets.lookup(tid, path) do
      [{^path, :dir, _content, _stat}] -> true
      _ -> false
    end
  end

  @impl true
  def regular?(_tid, path) when path in @magic_devices, do: false

  def regular?(tid, path) do
    case :ets.lookup(tid, path) do
      [{^path, :file, _content, _stat}] -> true
      _ -> false
    end
  end

  @impl true
  def stat(_tid, path) when path in @magic_devices do
    {:ok, device_stat()}
  end

  def stat(tid, path) do
    case :ets.lookup(tid, path) do
      [{^path, _type, _content, stat}] -> {:ok, stat}
      [] -> {:error, :enoent}
    end
  end

  @impl true
  def lstat(tid, path), do: stat(tid, path)

  @impl true
  def read(_tid, "/dev/null"), do: {:ok, ""}
  def read(_tid, path) when path in ["/dev/stdout", "/dev/stderr"], do: {:error, :eacces}
  def read(_tid, "/dev/stdin"), do: {:error, :eacces}

  def read(tid, path) do
    case :ets.lookup(tid, path) do
      [{^path, :file, content, _stat}] -> {:ok, content}
      [{^path, :dir, _content, _stat}] -> {:error, :eisdir}
      [] -> {:error, :enoent}
    end
  end

  @impl true
  def write(_tid, "/dev/null", _content, _opts), do: :ok

  def write(tid, path, content, opts) do
    binary = IO.iodata_to_binary(content)

    Enum.each(parent_paths(path), fn parent ->
      :ets.insert_new(tid, {parent, :dir, nil, dir_stat(0o755)})
    end)

    case :ets.lookup(tid, path) do
      [{^path, :dir, _, _}] ->
        {:error, :eisdir}

      [{^path, :file, existing, existing_stat}] ->
        final_content =
          if Keyword.get(opts, :append, false), do: existing <> binary, else: binary

        :ets.insert(
          tid,
          {path, :file, final_content, file_stat(final_content, existing_stat.mode)}
        )

        :ok

      [] ->
        :ets.insert(tid, {path, :file, binary, file_stat(binary, 0o644)})
        :ok
    end
  end

  @impl true
  def mkdir_p(tid, path) do
    Enum.each([path | parent_paths(path)], fn dir ->
      :ets.insert_new(tid, {dir, :dir, nil, dir_stat(0o755)})
    end)

    :ok
  end

  @impl true
  def rm(tid, path) do
    case :ets.lookup(tid, path) do
      [{^path, :file, _, _}] ->
        :ets.delete(tid, path)
        :ok

      [{^path, :dir, _, _}] ->
        {:error, :eisdir}

      [] ->
        {:error, :enoent}
    end
  end

  @impl true
  def open(tid, "/dev/null", _modes) do
    {:ok, device} = StringIO.open("")
    :ets.insert(tid, {{:_device, device}, :dev_null})
    {:ok, device}
  end

  def open(tid, path, modes) when is_list(modes) do
    cond do
      :write in modes or :append in modes -> open_for_write(tid, path, modes)
      :read in modes -> open_for_read(tid, path)
      true -> {:error, :einval}
    end
  end

  def open(_tid, _path, _modes), do: {:error, :einval}

  defp open_for_write(tid, path, modes) do
    is_append = :append in modes

    existing_content =
      if is_append do
        case :ets.lookup(tid, path) do
          [{^path, :file, content, _stat}] -> content
          _ -> ""
        end
      else
        ""
      end

    {:ok, device} = StringIO.open("")
    :ets.insert(tid, {{:_device, device}, {:write_to, path, is_append, existing_content}})
    {:ok, device}
  end

  defp open_for_read(tid, path) do
    case :ets.lookup(tid, path) do
      [{^path, :file, content, _stat}] ->
        {:ok, device} = StringIO.open(content)
        {:ok, device}

      [{^path, :dir, _content, _stat}] ->
        {:error, :eisdir}

      [] ->
        {:error, :enoent}
    end
  end

  @impl true
  def handle_write(_tid, device, data) do
    IO.binwrite(device, data)
  end

  @impl true
  def handle_close(tid, device) do
    case :ets.lookup(tid, {:_device, device}) do
      [{{:_device, ^device}, :dev_null}] ->
        :ets.delete(tid, {:_device, device})
        StringIO.close(device)
        :ok

      [{{:_device, ^device}, {:write_to, path, is_append, existing_content}}] ->
        {_input, output} = StringIO.contents(device)

        final_content =
          if is_append, do: existing_content <> output, else: output

        Enum.each(parent_paths(path), fn parent ->
          :ets.insert_new(tid, {parent, :dir, nil, dir_stat(0o755)})
        end)

        :ets.insert(tid, {path, :file, final_content, file_stat(final_content, 0o644)})
        :ets.delete(tid, {:_device, device})
        StringIO.close(device)
        :ok

      [] ->
        StringIO.close(device)
        :ok
    end
  end

  @impl true
  def ls(tid, dir_path) do
    if :ets.member(tid, dir_path) and dir?(tid, dir_path) do
      entries =
        :ets.foldl(
          fn
            {{:_device, _}, _}, acc ->
              acc

            {path, _type, _content, _stat}, acc ->
              parent = Path.dirname(path)

              if parent == dir_path and path != dir_path do
                [Path.basename(path) | acc]
              else
                acc
              end
          end,
          [],
          tid
        )

      {:ok, Enum.sort(entries)}
    else
      {:error, :enoent}
    end
  end

  @impl true
  def wildcard(tid, pattern, _opts) do
    regex_source =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    case Regex.compile("^" <> regex_source <> "$") do
      {:ok, regex} ->
        :ets.foldl(
          fn
            {{:_device, _}, _}, acc ->
              acc

            {path, _type, _content, _stat}, acc ->
              if Regex.match?(regex, path), do: [path | acc], else: acc
          end,
          [],
          tid
        )
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @impl true
  def read_link(_tid, _path), do: {:error, :enotsup}

  @impl true
  def read_link_all(_tid, _path), do: {:error, :enotsup}

  defp insert_dir(tid, path, mode) do
    stat = dir_stat(mode)
    :ets.insert(tid, {path, :dir, nil, stat})
  end

  defp insert_seed(tid, path, content) when is_binary(content) do
    stat = file_stat(content, 0o644)
    :ets.insert(tid, {path, :file, content, stat})
  end

  defp insert_seed(tid, path, %{content: content} = spec) do
    mode = Map.get(spec, :mode, 0o644)
    stat = file_stat(content, mode)
    :ets.insert(tid, {path, :file, content, stat})
  end

  defp insert_seed(tid, path, {:dir, nil}) do
    insert_dir(tid, path, 0o755)
  end

  defp file_stat(content, mode) do
    now = :calendar.universal_time()

    %File.Stat{
      type: :regular,
      size: byte_size(content),
      access: :read_write,
      mode: mode,
      mtime: now,
      atime: now,
      ctime: now
    }
  end

  defp dir_stat(mode) do
    now = :calendar.universal_time()

    %File.Stat{
      type: :directory,
      size: 0,
      access: :read_write,
      mode: mode,
      mtime: now,
      atime: now,
      ctime: now
    }
  end

  defp device_stat do
    now = :calendar.universal_time()

    %File.Stat{
      type: :device,
      size: 0,
      access: :read_write,
      mode: 0o666,
      mtime: now,
      atime: now,
      ctime: now
    }
  end

  defp parent_paths(path) do
    parts = Path.split(path)

    parents =
      parts
      |> Enum.drop(-1)
      |> Enum.scan([], fn part, acc -> [part | acc] end)
      |> Enum.map(fn reversed -> reversed |> Enum.reverse() |> Path.join() end)

    case parents do
      [] ->
        ["/"]

      ["/" | _] = list ->
        list

      list ->
        ["/" | list]
    end
  end
end
