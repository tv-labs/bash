defmodule Bash.VirtualFilesystemTest do
  use Bash.SessionCase, async: true

  alias Bash.Session

  @enforcement_base "/nonexistent_vfs_enforcement_path/workspace"

  defp start_enforcement_session(context, initial_files, opts \\ []) do
    start_vfs_session(context, initial_files, [{:working_dir, @enforcement_base} | opts])
  end

  defp start_vfs_session(context, initial_files, opts \\ []) do
    table = Bash.Filesystem.ETS.new(initial_files)
    working_dir = Keyword.get(opts, :working_dir, "/workspace")

    registry_name = Module.concat([context.module, VFSRegistry, context.test])
    supervisor_name = Module.concat([context.module, VFSSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name}, id: registry_name)

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: supervisor_name},
      id: supervisor_name
    )

    command_policy_opt = Keyword.get(opts, :command_policy, nil)

    session_opts =
      [
        filesystem: {Bash.Filesystem.ETS, table},
        working_dir: working_dir,
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name
      ] ++
        if(command_policy_opt, do: [command_policy: command_policy_opt], else: [])

    {:ok, session} = Session.new(session_opts)

    {session, {Bash.Filesystem.ETS, table}}
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
          "/workspace/dir" => {:dir, nil}
        })

      result = run_script(session, "test -f file.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -f dir && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -d checks VFS for directory", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace/dir" => {:dir, nil},
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
      {session, {Bash.Filesystem.ETS, table}} =
        start_vfs_session(context, %{"/workspace" => {:dir, nil}})

      run_script(session, "echo hello > output.txt")

      assert Bash.Filesystem.ETS.read(table, "/workspace/output.txt") == {:ok, "hello\n"}
    end

    test "echo >> file appends to VFS", context do
      {session, {Bash.Filesystem.ETS, table}} =
        start_vfs_session(context, %{
          "/workspace" => {:dir, nil},
          "/workspace/output.txt" => "first\n"
        })

      run_script(session, "echo second >> output.txt")

      assert Bash.Filesystem.ETS.read(table, "/workspace/output.txt") == {:ok, "first\nsecond\n"}
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
          "/workspace/subdir" => {:dir, nil}
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
          (@enforcement_base <> "/mydir") => {:dir, nil}
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
          (@enforcement_base <> "/readable.txt") => %{content: "content", mode: 0o644}
        })

      result = run_script(session, "test -r readable.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -w detects writable file via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/writable.txt") => %{content: "content", mode: 0o644},
          (@enforcement_base <> "/readonly.txt") => %{content: "content", mode: 0o444}
        })

      result = run_script(session, "test -w writable.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -w readonly.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -x detects executable file via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/script.sh") => %{content: "#!/bin/bash", mode: 0o755},
          (@enforcement_base <> "/data.txt") => %{content: "content", mode: 0o644}
        })

      result = run_script(session, "test -x script.sh && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -x data.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "test -g detects setgid via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/setgid_file") => %{content: "content", mode: 0o2755}
        })

      result = run_script(session, "test -g setgid_file && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -u detects setuid via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/setuid_file") => %{content: "content", mode: 0o4755}
        })

      result = run_script(session, "test -u setuid_file && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -k detects sticky bit via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/sticky_dir") => %{content: "content", mode: 0o1755}
        })

      result = run_script(session, "test -k sticky_dir && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -N detects file modified since read via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/modified.txt") => %{
            content: "content",
            mtime: {{2024, 6, 1}, {12, 0, 0}},
            atime: {{2024, 1, 1}, {0, 0, 0}}
          }
        })

      result = run_script(session, "test -N modified.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test file1 -nt file2 compares via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/newer.txt") => %{
            content: "content",
            mtime: {{2024, 6, 1}, {0, 0, 0}}
          },
          (@enforcement_base <> "/older.txt") => %{
            content: "content",
            mtime: {{2024, 1, 1}, {0, 0, 0}}
          }
        })

      result = run_script(session, "test newer.txt -nt older.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test file1 -ot file2 compares via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/newer.txt") => %{
            content: "content",
            mtime: {{2024, 6, 1}, {0, 0, 0}}
          },
          (@enforcement_base <> "/older.txt") => %{
            content: "content",
            mtime: {{2024, 1, 1}, {0, 0, 0}}
          }
        })

      result = run_script(session, "test older.txt -ot newer.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test file1 -ef file2 compares inode via VFS stat", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/file1.txt") => %{content: "content", inode: 42, major_device: 1},
          (@enforcement_base <> "/hardlink.txt") => %{
            content: "content",
            inode: 42,
            major_device: 1
          }
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
      {session, {Bash.Filesystem.ETS, table}} =
        start_enforcement_session(context, %{
          @enforcement_base => {:dir, nil}
        })

      run_script(session, "echo enforced > output.txt")

      assert Bash.Filesystem.ETS.read(table, @enforcement_base <> "/output.txt") ==
               {:ok, "enforced\n"}

      refute File.exists?(@enforcement_base <> "/output.txt")
    end

    test "echo >> file appends to VFS, not host", context do
      {session, {Bash.Filesystem.ETS, table}} =
        start_enforcement_session(context, %{
          @enforcement_base => {:dir, nil},
          (@enforcement_base <> "/log.txt") => "line1\n"
        })

      run_script(session, "echo line2 >> log.txt")

      assert Bash.Filesystem.ETS.read(table, @enforcement_base <> "/log.txt") ==
               {:ok, "line1\nline2\n"}
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
          (@enforcement_base <> "/vfs_only_dir") => {:dir, nil}
        })

      result = run_script(session, "cd vfs_only_dir && pwd")
      assert get_stdout(result) == @enforcement_base <> "/vfs_only_dir\n"
    end

    test "cd - switches to previous VFS directory", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/dir_a") => {:dir, nil},
          (@enforcement_base <> "/dir_b") => {:dir, nil}
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
          (@enforcement_base <> "/sub") => {:dir, nil}
        })

      result = run_script(session, "(cd sub && pwd)")
      assert get_stdout(result) == @enforcement_base <> "/sub\n"
    end
  end

  describe "VFS enforcement: pushd/popd on non-host paths" do
    test "pushd validates directory in VFS", context do
      {session, _fs} =
        start_enforcement_session(context, %{
          (@enforcement_base <> "/pushdir") => {:dir, nil}
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
          (@enforcement_base <> "/first") => {:dir, nil},
          (@enforcement_base <> "/second") => {:dir, nil}
        })

      run_script(session, "pushd first")
      run_script(session, "pushd #{@enforcement_base}/second")
      result = run_script(session, "popd && pwd")
      assert get_stdout(result) =~ "first"
    end
  end

  describe "VFS enforcement: file descriptors on non-host paths" do
    test "exec 3>file writes through VFS", context do
      {session, {Bash.Filesystem.ETS, table}} =
        start_enforcement_session(context, %{
          @enforcement_base => {:dir, nil}
        })

      run_script(session, "exec 3> fdout.txt; echo hello >&3; exec 3>&-")

      {:ok, content} = Bash.Filesystem.ETS.read(table, @enforcement_base <> "/fdout.txt")
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
          (cdpath_base <> "/target") => {:dir, nil}
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
          (vfs_bin <> "/mycmd") => %{content: "#!/bin/bash", mode: 0o755}
        })

      run_script(session, "export PATH=#{vfs_bin}")
      result = run_script(session, "type -t mycmd")
      assert get_stdout(result) == "file\n"
    end

    test "command -v finds command in VFS PATH", context do
      vfs_bin = "/nonexistent_vfs_enforcement_path/bin"

      {session, _fs} =
        start_enforcement_session(context, %{
          (vfs_bin <> "/findme") => %{content: "#!/bin/bash", mode: 0o755}
        })

      run_script(session, "export PATH=#{vfs_bin}")
      result = run_script(session, "command -v findme")
      assert get_stdout(result) =~ "findme"
    end

    test "hash caches command path from VFS", context do
      vfs_bin = "/nonexistent_vfs_enforcement_path/bin"

      {session, _fs} =
        start_enforcement_session(context, %{
          (vfs_bin <> "/hashme") => %{content: "#!/bin/bash", mode: 0o755}
        })

      run_script(session, "export PATH=#{vfs_bin}")
      result = run_script(session, "hash hashme && hash -t hashme")
      assert get_stdout(result) =~ vfs_bin <> "/hashme"
    end
  end

  describe "process substitution with virtual filesystem" do
    test "input process substitution writes temp file to VFS", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace" => {:dir, nil},
          "/tmp" => {:dir, nil}
        })

      # Snapshot host /tmp before — stale files from prior runs must not skew the check.
      before_subst = MapSet.new(Path.wildcard("/tmp/runcom_proc_subst_*"))

      # Use a redirect into a builtin loop rather than external cat — the
      # VFS temp file exists only in memory and cannot be opened by an OS process.
      result =
        run_script(
          session,
          "while read line; do echo \"$line\"; done < <(echo hello_from_vfs)"
        )

      assert get_stdout(result) == "hello_from_vfs\n"

      after_subst = MapSet.new(Path.wildcard("/tmp/runcom_proc_subst_*"))
      new_files = MapSet.difference(after_subst, before_subst) |> MapSet.to_list()
      assert new_files == [], "ProcessSubst created host files: #{inspect(new_files)}"
    end
  end

  describe "full VFS sandboxing — no host filesystem access" do
    test "coproc with VFS creates no host pipe files", context do
      # Use working_dir: "/tmp" so the external coproc process can start on the host.
      # The goal of this test is to verify no host bash_pipe_* FIFOs are created —
      # coproc I/O is handled by BeamPipe, not OS FIFOs.
      {session, _fs} =
        start_vfs_session(
          context,
          %{
            "/tmp" => {:dir, nil}
          },
          working_dir: "/tmp"
        )

      before_pipes = MapSet.new(Path.wildcard("/tmp/bash_pipe_*"))

      result =
        run_script(session, ~S"""
        coproc cat
        echo hello >&${COPROC[1]}
        eval "exec ${COPROC[1]}>&-"
        read -u ${COPROC[0]} reply
        echo "$reply"
        """)

      assert get_stdout(result) =~ "hello"

      after_pipes = MapSet.new(Path.wildcard("/tmp/bash_pipe_*"))
      new_pipes = MapSet.difference(after_pipes, before_pipes) |> MapSet.to_list()
      assert new_pipes == [], "Coproc created host pipes: #{inspect(new_pipes)}"
    end

    test "process substitution with VFS creates no host files", context do
      {session, _fs} =
        start_vfs_session(context, %{
          "/workspace" => {:dir, nil},
          "/tmp" => {:dir, nil}
        })

      before_subst = MapSet.new(Path.wildcard("/tmp/runcom_proc_subst_*"))

      result =
        run_script(
          session,
          "while read line; do echo \"$line\"; done < <(echo sandboxed)"
        )

      assert get_stdout(result) == "sandboxed\n"

      after_subst = MapSet.new(Path.wildcard("/tmp/runcom_proc_subst_*"))
      new_files = MapSet.difference(after_subst, before_subst) |> MapSet.to_list()
      assert new_files == [], "ProcessSubst created host files: #{inspect(new_files)}"
    end
  end
end
