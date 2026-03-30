defmodule Bash.VirtualFilesystemTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  defmodule InMemory do
    @moduledoc false
    @behaviour Bash.Filesystem

    def start(initial_files \\ %{}) do
      {:ok, pid} = Agent.start(fn -> initial_files end)
      {__MODULE__, pid}
    end

    def stop({__MODULE__, pid}) do
      Agent.stop(pid)
    catch
      :exit, _ -> :ok
    end

    defp normalize(path), do: Path.expand(path)

    @impl true
    def exists?(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        case Map.get(files, path) do
          nil ->
            Enum.any?(files, fn
              {{:_device, _}, _} -> false
              {k, _v} -> String.starts_with?(k, path <> "/")
            end)

          _ ->
            true
        end
      end)
    end

    @impl true
    def dir?(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        Map.get(files, path) == :directory or
          Enum.any?(files, fn
            {{:_device, _}, _} ->
              false

            {k, _v} ->
              k != path and String.starts_with?(k, path <> "/")
          end)
      end)
    end

    @impl true
    def regular?(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        case Map.get(files, path) do
          nil -> false
          :directory -> false
          {_content, opts} when is_list(opts) -> Keyword.get(opts, :type, :regular) != :directory
          _ -> true
        end
      end)
    end

    @impl true
    def stat(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        case Map.get(files, path) do
          nil ->
            if Enum.any?(files, fn
                 {{:_device, _}, _} -> false
                 {k, _} -> k != path and String.starts_with?(k, path <> "/")
               end) do
              {:ok,
               %File.Stat{
                 type: :directory,
                 size: 0,
                 mode: 0o755,
                 mtime: {{2024, 1, 1}, {0, 0, 0}},
                 atime: {{2024, 1, 1}, {0, 0, 0}},
                 inode: 0,
                 major_device: 0
               }}
            else
              {:error, :enoent}
            end

          :directory ->
            {:ok,
             %File.Stat{
               type: :directory,
               size: 0,
               mode: 0o755,
               mtime: {{2024, 1, 1}, {0, 0, 0}},
               atime: {{2024, 1, 1}, {0, 0, 0}},
               inode: 0,
               major_device: 0
             }}

          {content, opts} when is_binary(content) and is_list(opts) ->
            {:ok,
             %File.Stat{
               type: Keyword.get(opts, :type, :regular),
               size: byte_size(content),
               mode: Keyword.get(opts, :mode, 0o644),
               mtime: Keyword.get(opts, :mtime, {{2024, 1, 1}, {0, 0, 0}}),
               atime: Keyword.get(opts, :atime, {{2024, 1, 1}, {0, 0, 0}}),
               inode: Keyword.get(opts, :inode, 0),
               major_device: Keyword.get(opts, :major_device, 0)
             }}

          content when is_binary(content) ->
            {:ok,
             %File.Stat{
               type: :regular,
               size: byte_size(content),
               mode: 0o644,
               mtime: {{2024, 1, 1}, {0, 0, 0}},
               atime: {{2024, 1, 1}, {0, 0, 0}},
               inode: 0,
               major_device: 0
             }}
        end
      end)
    end

    @impl true
    def read(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        case Map.get(files, path) do
          nil -> {:error, :enoent}
          :directory -> {:error, :eisdir}
          {content, opts} when is_binary(content) and is_list(opts) -> {:ok, content}
          content when is_binary(content) -> {:ok, content}
        end
      end)
    end

    @impl true
    def write(pid, path, content, opts) do
      path = normalize(path)

      Agent.update(pid, fn files ->
        current = Map.get(files, path, "")

        current_content =
          case current do
            {bin, _opts} when is_binary(bin) -> bin
            bin when is_binary(bin) -> bin
            _ -> ""
          end

        new_content =
          if Keyword.get(opts, :append, false) do
            current_content <> IO.iodata_to_binary(content)
          else
            IO.iodata_to_binary(content)
          end

        Map.put(files, path, new_content)
      end)
    end

    @impl true
    def mkdir_p(pid, path) do
      path = normalize(path)
      Agent.update(pid, fn files -> Map.put(files, path, :directory) end)
    end

    @impl true
    def rm(pid, path) do
      path = normalize(path)
      Agent.update(pid, fn files -> Map.delete(files, path) end)
    end

    @impl true
    def open(pid, path, modes) do
      path = normalize(path)

      cond do
        :write in modes or :append in modes ->
          is_append = :append in modes

          existing_content =
            if is_append do
              case Agent.get(pid, &Map.get(&1, path, "")) do
                {bin, _opts} when is_binary(bin) -> bin
                bin when is_binary(bin) -> bin
                _ -> ""
              end
            else
              ""
            end

          {:ok, device} = StringIO.open("")

          Agent.update(pid, fn files ->
            Map.put(files, {:_device, device}, {:write_to, path, is_append, existing_content})
          end)

          {:ok, device}

        :read in modes ->
          case Agent.get(pid, &Map.get(&1, path)) do
            nil ->
              {:error, :enoent}

            :directory ->
              {:error, :eisdir}

            {content, _opts} when is_binary(content) ->
              {:ok, device} = StringIO.open(content)
              {:ok, device}

            content when is_binary(content) ->
              {:ok, device} = StringIO.open(content)
              {:ok, device}
          end

        true ->
          {:error, :einval}
      end
    end

    @impl true
    def handle_write(_pid, device, data) do
      IO.binwrite(device, data)
    end

    @impl true
    def handle_close(pid, device) do
      case Agent.get(pid, &Map.get(&1, {:_device, device})) do
        {:write_to, path, is_append, existing_content} ->
          {_input, output} = StringIO.contents(device)

          final_content =
            if is_append do
              existing_content <> output
            else
              output
            end

          Agent.update(pid, fn files ->
            files
            |> Map.delete({:_device, device})
            |> Map.put(path, final_content)
          end)

          StringIO.close(device)
          :ok

        nil ->
          StringIO.close(device)
          :ok
      end
    end

    @impl true
    def ls(pid, dir_path) do
      dir_path = normalize(dir_path)

      Agent.get(pid, fn files ->
        entries =
          files
          |> Enum.filter(fn
            {{:_device, _}, _} ->
              false

            {k, _v} ->
              parent = Path.dirname(k)
              parent == dir_path or (dir_path == "/" and parent == "/")
          end)
          |> Enum.map(fn {k, _v} -> Path.basename(k) end)
          |> Enum.uniq()
          |> Enum.sort()

        if entries == [] do
          if Map.has_key?(files, dir_path) or
               Enum.any?(files, fn
                 {{:_device, _}, _} -> false
                 {k, _} -> k != dir_path and String.starts_with?(k, dir_path <> "/")
               end) do
            {:ok, []}
          else
            {:error, :enoent}
          end
        else
          {:ok, entries}
        end
      end)
    end

    @impl true
    def wildcard(pid, pattern, _opts) do
      Agent.get(pid, fn files ->
        regex_str =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", "[^/]*")
          |> String.replace("\\?", "[^/]")

        case Regex.compile("^#{regex_str}$") do
          {:ok, regex} ->
            files
            |> Map.keys()
            |> Enum.filter(fn
              {:_device, _} -> false
              k when is_binary(k) -> Regex.match?(regex, k)
              _ -> false
            end)
            |> Enum.sort()

          {:error, _} ->
            []
        end
      end)
    end
  end

  @enforcement_base "/nonexistent_vfs_enforcement_path/workspace"

  defp start_enforcement_session(context, initial_files, opts \\ []) do
    start_vfs_session(context, initial_files, [{:working_dir, @enforcement_base} | opts])
  end

  defp start_vfs_session(context, initial_files, opts \\ []) do
    fs = InMemory.start(initial_files)
    working_dir = Keyword.get(opts, :working_dir, "/workspace")

    registry_name = Module.concat([context.module, VFSRegistry, context.test])
    supervisor_name = Module.concat([context.module, VFSSupervisor, context.test])

    _registry =
      start_supervised!({Registry, keys: :unique, name: registry_name}, id: registry_name)

    _supervisor =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: supervisor_name},
        id: supervisor_name
      )

    command_policy_opt = Keyword.get(opts, :command_policy, nil)

    session_opts =
      [
        filesystem: fs,
        working_dir: working_dir,
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name
      ] ++
        if(command_policy_opt, do: [command_policy: command_policy_opt], else: [])

    {:ok, session} = Session.new(session_opts)

    on_exit(fn -> InMemory.stop(fs) end)

    {session, fs}
  end

  describe "default (no filesystem option) is unchanged" do
    setup :start_session

    test "sessions without filesystem option work identically", %{session: session} do
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end
  end

  describe "file test operators with virtual filesystem" do
    test "test -e checks VFS for existence", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/existing.txt" => "content"
        })

      result = run_script(session, "test -e existing.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -e missing.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -f checks VFS for regular file", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/file.txt" => "content",
          "/workspace/dir" => :directory
        })

      result = run_script(session, "test -f file.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -f dir && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -d checks VFS for directory", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/dir" => :directory,
          "/workspace/file.txt" => "content"
        })

      result = run_script(session, "test -d dir && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -d file.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -s checks VFS for non-empty file", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/notempty.txt" => "content",
          "/workspace/empty.txt" => ""
        })

      result = run_script(session, "test -s notempty.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -s empty.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -r checks VFS for readable file", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/readable.txt" => "content"
        })

      result = run_script(session, "test -r readable.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end
  end

  describe "source builtin with virtual filesystem" do
    test "source reads from VFS", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/config.sh" => "MY_VAR=hello_from_vfs"
        })

      run_script(session, "source ./config.sh")
      result = run_script(session, "echo $MY_VAR")
      assert get_stdout(result) == "hello_from_vfs\n"
    end

    test "source reports error for missing VFS file", context do
      {session, _fs} = start_vfs_session(context, %{})

      result = run_script(session, "source ./missing.sh")
      assert get_stderr(result) =~ "No such file or directory"
    end
  end

  describe "output redirections with virtual filesystem" do
    test "echo > file writes to VFS", context do
      {session, fs} =
        start_vfs_session(context, %{"/workspace" => :directory})

      run_script(session, "echo hello > output.txt")

      {_, pid} = fs
      content = Agent.get(pid, &Map.get(&1, "/workspace/output.txt"))
      assert content == "hello\n"
    end

    test "echo >> file appends to VFS", context do
      {session, fs} =
        start_vfs_session(context, %{
          "/workspace" => :directory,
          "/workspace/output.txt" => "first\n"
        })

      run_script(session, "echo second >> output.txt")

      {_, pid} = fs
      content = Agent.get(pid, &Map.get(&1, "/workspace/output.txt"))
      assert content == "first\nsecond\n"
    end
  end

  describe "input redirections with virtual filesystem" do
    test "read builtin receives input from VFS redirect", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/input.txt" => "hello from vfs\n"
        })

      result = run_script(session, "read line < input.txt && echo $line")
      assert get_stdout(result) =~ "hello from vfs"
    end
  end

  describe "cd / pwd with virtual filesystem" do
    test "cd validates against VFS directories", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/subdir" => :directory
        })

      result = run_script(session, "cd subdir && pwd")
      assert get_stdout(result) == "/workspace/subdir\n"
    end

    test "cd rejects non-existent VFS directory", context do
      {session, _fs} = start_vfs_session(context, %{})

      result = run_script(session, "cd nonexistent 2>&1")
      assert get_stdout(result) =~ "No such file or directory"
    end
  end

  describe "filesystem propagates to child contexts" do
    test "subshell inherits VFS", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/data.txt" => "vfs_content"
        })

      result = run_script(session, "(test -f data.txt && echo yes || echo no)")
      assert get_stdout(result) == "yes\n"
    end

    test "command substitution inherits VFS", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/data.txt" => "vfs_content"
        })

      result =
        run_script(session, "result=$(test -f data.txt && echo yes || echo no); echo $result")

      assert get_stdout(result) == "yes\n"
    end
  end

  describe "restricted VFS session" do
    test "command_policy + VFS blocks commands and uses virtual files", context do
      {session, _fs} =
        start_vfs_session(
          context,
          %{"/workspace/data.txt" => "sandboxed"},
          command_policy: [commands: :no_external]
        )

      result = run_script(session, "test -f data.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end
  end

  describe "glob expansion with virtual filesystem" do
    test "*.txt expands against VFS files", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/a.txt" => "a",
          "/workspace/b.txt" => "b",
          "/workspace/c.log" => "c"
        })

      result = run_script(session, "echo *.txt")
      stdout = get_stdout(result)
      assert stdout =~ "a.txt"
      assert stdout =~ "b.txt"
      refute stdout =~ "c.log"
    end

    test "glob with no matches returns pattern literally", context do
      {session, _fs} = start_vfs_session(context, %{})

      result = run_script(session, "echo *.xyz")
      assert get_stdout(result) == "*.xyz\n"
    end
  end

  describe "VFS enforcement: file test operators on non-host paths" do
    test "test -e detects file that only exists in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/data.txt") => "exists only in VFS"
        })

      result = run_script(session, "test -e data.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -f detects regular file in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/file.txt") => "regular file"
        })

      result = run_script(session, "test -f file.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -d detects directory in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/mydir") => :directory
        })

      result = run_script(session, "test -d mydir && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -s detects non-empty file in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/notempty.txt") => "has content"
        })

      result = run_script(session, "test -s notempty.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -r detects readable file via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/readable.txt") => {"content", mode: 0o644}
        })

      result = run_script(session, "test -r readable.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -w detects writable file via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/writable.txt") => {"content", mode: 0o644},
          (@enforcement_base <> "/readonly.txt") => {"content", mode: 0o444}
        })

      result = run_script(session, "test -w writable.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -w readonly.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -x detects executable file via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/script.sh") => {"#!/bin/bash", mode: 0o755},
          (@enforcement_base <> "/data.txt") => {"content", mode: 0o644}
        })

      result = run_script(session, "test -x script.sh && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -x data.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -g detects setgid via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/setgid_file") => {"content", mode: 0o2755}
        })

      result = run_script(session, "test -g setgid_file && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -u detects setuid via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/setuid_file") => {"content", mode: 0o4755}
        })

      result = run_script(session, "test -u setuid_file && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -k detects sticky bit via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/sticky_dir") => {"content", mode: 0o1755}
        })

      result = run_script(session, "test -k sticky_dir && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -N detects file modified since read via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/modified.txt") =>
            {"content", mtime: {{2024, 6, 1}, {12, 0, 0}}, atime: {{2024, 1, 1}, {0, 0, 0}}}
        })

      result = run_script(session, "test -N modified.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test file1 -nt file2 compares via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/newer.txt") => {"content", mtime: {{2024, 6, 1}, {0, 0, 0}}},
          (@enforcement_base <> "/older.txt") => {"content", mtime: {{2024, 1, 1}, {0, 0, 0}}}
        })

      result = run_script(session, "test newer.txt -nt older.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test file1 -ot file2 compares via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/newer.txt") => {"content", mtime: {{2024, 6, 1}, {0, 0, 0}}},
          (@enforcement_base <> "/older.txt") => {"content", mtime: {{2024, 1, 1}, {0, 0, 0}}}
        })

      result = run_script(session, "test older.txt -ot newer.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test file1 -ef file2 compares inode via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/file1.txt") => {"content", inode: 42, major_device: 1},
          (@enforcement_base <> "/hardlink.txt") => {"content", inode: 42, major_device: 1}
        })

      result = run_script(session, "test file1.txt -ef hardlink.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "[[ ]] test form also uses VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/data.txt") => "content"
        })

      result = run_script(session, "[[ -f data.txt ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end
  end

  describe "VFS enforcement: source builtin on non-host paths" do
    test "source reads script content from VFS only", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/setup.sh") => "SOURCED_VAR=from_vfs"
        })

      run_script(session, "source ./setup.sh")
      result = run_script(session, "echo $SOURCED_VAR")
      assert get_stdout(result) == "from_vfs\n"
    end
  end

  describe "VFS enforcement: output redirections on non-host paths" do
    test "echo > file writes to VFS, not host", context do
      {session, fs} =
        start_enforcement_session(context, %{
          @enforcement_base => :directory
        })

      run_script(session, "echo enforced > output.txt")

      {_, pid} = fs
      content = Agent.get(pid, &Map.get(&1, @enforcement_base <> "/output.txt"))
      assert content == "enforced\n"
      refute File.exists?(@enforcement_base <> "/output.txt")
    end

    test "echo >> file appends to VFS, not host", context do
      {session, fs} =
        start_enforcement_session(context, %{
          @enforcement_base => :directory,
          (@enforcement_base <> "/log.txt") => "line1\n"
        })

      run_script(session, "echo line2 >> log.txt")

      {_, pid} = fs
      content = Agent.get(pid, &Map.get(&1, @enforcement_base <> "/log.txt"))
      assert content == "line1\nline2\n"
    end
  end

  describe "VFS enforcement: input redirections on non-host paths" do
    test "read < file reads from VFS only", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/input.txt") => "vfs_input_data\n"
        })

      result = run_script(session, "read line < input.txt && echo $line")
      assert get_stdout(result) == "vfs_input_data\n"
    end
  end

  describe "VFS enforcement: glob expansion on non-host paths" do
    test "glob expands against VFS files only", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/alpha.txt") => "a",
          (@enforcement_base <> "/beta.txt") => "b",
          (@enforcement_base <> "/gamma.log") => "c"
        })

      result = run_script(session, "echo *.txt")
      stdout = get_stdout(result)
      assert stdout =~ "alpha.txt"
      assert stdout =~ "beta.txt"
      refute stdout =~ "gamma.log"
    end
  end

  describe "VFS enforcement: cd/pwd on non-host paths" do
    test "cd validates directory existence in VFS only", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/vfs_only_dir") => :directory
        })

      result = run_script(session, "cd vfs_only_dir && pwd")
      assert get_stdout(result) == @enforcement_base <> "/vfs_only_dir\n"
    end

    test "cd - switches to previous VFS directory", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/dir_a") => :directory,
          (@enforcement_base <> "/dir_b") => :directory
        })

      run_script(session, "cd dir_a")
      run_script(session, "cd #{@enforcement_base}/dir_b")
      result = run_script(session, "cd - && pwd")
      stdout = get_stdout(result)
      assert stdout =~ "dir_a"
    end
  end

  describe "VFS enforcement: noclobber on non-host paths" do
    test "set -C checks file existence in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/existing.txt") => "original"
        })

      result = run_script(session, "set -C; echo overwrite > existing.txt")
      assert get_stderr(result) =~ "cannot overwrite existing file"

      result = run_script(session, "set -C; echo new > fresh.txt; echo $?")
      assert get_stdout(result) =~ "0"
    end
  end

  describe "VFS enforcement: while loop input redirect on non-host paths" do
    test "while read line; done < file reads from VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/lines.txt") => "line1\nline2\nline3\n"
        })

      result =
        run_script(session, ~s|while read line; do echo "got: $line"; done < lines.txt|)

      stdout = get_stdout(result)
      assert stdout =~ "got: line1"
      assert stdout =~ "got: line2"
      assert stdout =~ "got: line3"
    end
  end

  describe "VFS enforcement: subshell and command substitution on non-host paths" do
    test "subshell inherits VFS with non-host paths", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/vfs_only.txt") => "content"
        })

      result = run_script(session, "(test -f vfs_only.txt && echo yes || echo no)")
      assert get_stdout(result) == "yes\n"
    end

    test "command substitution inherits VFS with non-host paths", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/vfs_only.txt") => "content"
        })

      result =
        run_script(session, "x=$(test -f vfs_only.txt && echo yes || echo no); echo $x")

      assert get_stdout(result) == "yes\n"
    end

    test "subshell cd validates against VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/sub") => :directory
        })

      result = run_script(session, "(cd sub && pwd)")
      assert get_stdout(result) == @enforcement_base <> "/sub\n"
    end
  end

  describe "VFS enforcement: pushd/popd on non-host paths" do
    test "pushd validates directory in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/pushdir") => :directory
        })

      result = run_script(session, "pushd pushdir && pwd")
      assert get_stdout(result) =~ @enforcement_base <> "/pushdir"
    end

    test "pushd rejects non-existent VFS directory", context do
      {session, _fs} = start_enforcement_session(context, %{})

      result = run_script(session, "pushd ghost 2>&1")
      assert get_stdout(result) =~ "No such file or directory"
    end

    test "popd validates directory in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/first") => :directory,
          (@enforcement_base <> "/second") => :directory
        })

      run_script(session, "pushd first")
      run_script(session, "pushd #{@enforcement_base}/second")
      result = run_script(session, "popd && pwd")
      assert get_stdout(result) =~ "first"
    end
  end

  describe "VFS enforcement: file descriptors on non-host paths" do
    test "exec 3>file writes through VFS", context do
      {session, fs} =
        start_enforcement_session(context, %{
          @enforcement_base => :directory
        })

      run_script(session, "exec 3> fdout.txt; echo hello >&3; exec 3>&-")

      {_, pid} = fs
      content = Agent.get(pid, &Map.get(&1, @enforcement_base <> "/fdout.txt"))
      assert content =~ "hello"
    end

    test "read < file reads through VFS file descriptor", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/fdinput.txt") => "fd_line1\nfd_line2\n"
        })

      result = run_script(session, "read line < fdinput.txt; echo $line")
      assert get_stdout(result) =~ "fd_line1"
    end
  end

  describe "VFS enforcement: CDPATH on non-host paths" do
    test "cd searches CDPATH directories in VFS", context do
      cdpath_base = "/nonexistent_vfs_enforcement_path/cdpath_root"

      {session, _fs} =
        start_enforcement_session(context, %{
          (cdpath_base <> "/target") => :directory
        })

      run_script(session, "export CDPATH=#{cdpath_base}")
      result = run_script(session, "cd target && pwd")
      assert get_stdout(result) =~ cdpath_base <> "/target"
    end
  end

  describe "VFS enforcement: eval and function VFS inheritance" do
    test "eval inherits VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/evaldata.txt") => "eval_content"
        })

      result = run_script(session, "eval 'test -f evaldata.txt && echo yes || echo no'")
      assert get_stdout(result) == "yes\n"
    end

    test "function calls inherit VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/funcdata.txt") => "func_content"
        })

      result =
        run_script(session, """
        check_file() { test -f funcdata.txt && echo yes || echo no; }
        check_file
        """)

      assert get_stdout(result) == "yes\n"
    end
  end

  describe "VFS enforcement: symlink test fallback" do
    test "test -L returns false for regular VFS files (no lstat support)", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/regular.txt") => "content"
        })

      result = run_script(session, "test -L regular.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end
  end

  describe "VFS enforcement: command/type/hash PATH lookup on non-host paths" do
    test "type finds command in VFS PATH", context do
      vfs_bin = "/nonexistent_vfs_enforcement_path/bin"

      {session, _fs} =
        start_enforcement_session(context, %{
          (vfs_bin <> "/mycmd") => {"#!/bin/bash", mode: 0o755}
        })

      run_script(session, "export PATH=#{vfs_bin}")
      result = run_script(session, "type -t mycmd")
      assert get_stdout(result) == "file\n"
    end

    test "command -v finds command in VFS PATH", context do
      vfs_bin = "/nonexistent_vfs_enforcement_path/bin"

      {session, _fs} =
        start_enforcement_session(context, %{
          (vfs_bin <> "/findme") => {"#!/bin/bash", mode: 0o755}
        })

      run_script(session, "export PATH=#{vfs_bin}")
      result = run_script(session, "command -v findme")
      assert get_stdout(result) =~ "findme"
    end

    test "hash caches command path from VFS", context do
      vfs_bin = "/nonexistent_vfs_enforcement_path/bin"

      {session, _fs} =
        start_enforcement_session(context, %{
          (vfs_bin <> "/hashme") => {"#!/bin/bash", mode: 0o755}
        })

      run_script(session, "export PATH=#{vfs_bin}")
      result = run_script(session, "hash hashme && hash -t hashme")
      assert get_stdout(result) =~ vfs_bin <> "/hashme"
    end
  end
end
