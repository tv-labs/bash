defmodule Bash.Filesystem.LocalDisk do
  @moduledoc """
  Default filesystem implementation that delegates to the host OS filesystem.

  All operations pass through to Elixir's `File` module or Erlang's `:file`
  module. This is the default adapter used when no `filesystem:` option is
  provided to `Bash.Session.new/1`.

  Config is unused (`nil`).
  """

  @behaviour Bash.Filesystem

  @impl true
  def exists?(_config, path), do: File.exists?(path)

  @impl true
  def dir?(_config, path), do: File.dir?(path)

  @impl true
  def regular?(_config, path), do: File.regular?(path)

  @impl true
  def stat(_config, path), do: File.stat(path)

  @impl true
  def lstat(_config, path), do: File.lstat(path)

  @impl true
  def read(_config, path), do: File.read(path)

  @impl true
  def write(_config, path, content, opts) do
    if Keyword.get(opts, :append, false),
      do: File.write(path, content, [:append]),
      else: File.write(path, content)
  end

  @impl true
  def mkdir_p(_config, path), do: File.mkdir_p(path)

  @impl true
  def rm(_config, path), do: File.rm(path)

  @impl true
  def open(_config, path, modes), do: File.open(path, modes)

  @impl true
  def handle_write(_config, device, data), do: :file.write(device, data)

  @impl true
  def handle_close(_config, device), do: :file.close(device)

  @impl true
  def ls(_config, path), do: File.ls(path)

  @impl true
  def wildcard(_config, pattern, opts), do: Path.wildcard(pattern, opts)

  @impl true
  def read_link(_config, path) do
    case :file.read_link(to_charlist(path)) do
      {:ok, target} -> {:ok, List.to_string(target)}
      error -> error
    end
  end

  @impl true
  def read_link_all(_config, path) do
    case :file.read_link_all(to_charlist(path)) do
      {:ok, target} -> {:ok, List.to_string(target)}
      error -> error
    end
  end
end
