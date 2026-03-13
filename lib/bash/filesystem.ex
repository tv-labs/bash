defmodule Bash.Filesystem do
  @moduledoc """
  Behaviour and dispatcher for pluggable filesystem implementations.

  The filesystem is stored in session state as a `{module, config}` tuple. Every
  filesystem callback takes `config` as the first argument. This module provides
  convenience functions that unwrap the tuple and dispatch to the appropriate
  implementation.

  ## Default

  When no filesystem option is provided, sessions use
  `{Bash.Filesystem.LocalDisk, nil}` which passes through to Elixir's `File`
  and Erlang's `:file` modules.

  ## Custom Implementations

  Implement the `Bash.Filesystem` behaviour to provide a virtual filesystem:

      defmodule MyVFS do
        @behaviour Bash.Filesystem

        @impl true
        def exists?(config, path), do: ...
        # ... implement all required callbacks
      end

      {:ok, session} = Bash.Session.new(filesystem: {MyVFS, my_config})

  Non-LocalDisk filesystems automatically enable restricted mode in the
  session, blocking external process execution. This prevents a split-brain
  state where builtins see the VFS while commands like `ls` hit the real OS.
  See `local_disk?/1`.
  """

  @type fs :: {module(), config :: term()}

  @callback exists?(config :: term(), path :: String.t()) :: boolean()
  @callback dir?(config :: term(), path :: String.t()) :: boolean()
  @callback regular?(config :: term(), path :: String.t()) :: boolean()
  @callback stat(config :: term(), path :: String.t()) ::
              {:ok, File.Stat.t()} | {:error, term()}
  @callback lstat(config :: term(), path :: String.t()) ::
              {:ok, File.Stat.t()} | {:error, term()}

  @callback read(config :: term(), path :: String.t()) ::
              {:ok, binary()} | {:error, term()}

  @callback write(config :: term(), path :: String.t(), content :: iodata(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback mkdir_p(config :: term(), path :: String.t()) :: :ok | {:error, term()}
  @callback rm(config :: term(), path :: String.t()) :: :ok | {:error, term()}

  @callback open(config :: term(), path :: String.t(), modes :: [atom()]) ::
              {:ok, io_device :: term()} | {:error, term()}
  @callback handle_write(config :: term(), io_device :: term(), data :: iodata()) ::
              :ok | {:error, term()}
  @callback handle_close(config :: term(), io_device :: term()) ::
              :ok | {:error, term()}

  @callback ls(config :: term(), path :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @callback wildcard(config :: term(), pattern :: String.t(), opts :: keyword()) ::
              [String.t()]

  @callback read_link(config :: term(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback read_link_all(config :: term(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks [lstat: 2, read_link: 2, read_link_all: 2]

  @spec local_disk?(fs()) :: boolean()
  def local_disk?({Bash.Filesystem.LocalDisk, _}), do: true
  def local_disk?(_), do: false

  @spec exists?(fs(), String.t()) :: boolean()
  def exists?({mod, config}, path), do: mod.exists?(config, path)

  @spec dir?(fs(), String.t()) :: boolean()
  def dir?({mod, config}, path), do: mod.dir?(config, path)

  @spec regular?(fs(), String.t()) :: boolean()
  def regular?({mod, config}, path), do: mod.regular?(config, path)

  @spec stat(fs(), String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  def stat({mod, config}, path), do: mod.stat(config, path)

  @spec lstat(fs(), String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  def lstat({mod, config}, path) do
    if function_exported?(mod, :lstat, 2),
      do: mod.lstat(config, path),
      else: mod.stat(config, path)
  end

  @spec read(fs(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read({mod, config}, path), do: mod.read(config, path)

  @spec write(fs(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write({mod, config}, path, content, opts), do: mod.write(config, path, content, opts)

  @spec mkdir_p(fs(), String.t()) :: :ok | {:error, term()}
  def mkdir_p({mod, config}, path), do: mod.mkdir_p(config, path)

  @spec rm(fs(), String.t()) :: :ok | {:error, term()}
  def rm({mod, config}, path), do: mod.rm(config, path)

  @spec open(fs(), String.t(), [atom()]) :: {:ok, term()} | {:error, term()}
  def open({mod, config}, path, modes), do: mod.open(config, path, modes)

  @spec handle_write(fs(), term(), iodata()) :: :ok | {:error, term()}
  def handle_write({mod, config}, device, data), do: mod.handle_write(config, device, data)

  @spec handle_close(fs(), term()) :: :ok | {:error, term()}
  def handle_close({mod, config}, device), do: mod.handle_close(config, device)

  @spec ls(fs(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ls({mod, config}, path), do: mod.ls(config, path)

  @spec wildcard(fs(), String.t(), keyword()) :: [String.t()]
  def wildcard({mod, config}, pattern, opts), do: mod.wildcard(config, pattern, opts)

  @spec read_link(fs(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_link({mod, config}, path) do
    if function_exported?(mod, :read_link, 2),
      do: mod.read_link(config, path),
      else: {:error, :enotsup}
  end

  @spec read_link_all(fs(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_link_all({mod, config}, path) do
    if function_exported?(mod, :read_link_all, 2),
      do: mod.read_link_all(config, path),
      else: {:error, :enotsup}
  end
end
