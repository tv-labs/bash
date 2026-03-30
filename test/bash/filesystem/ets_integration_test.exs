defmodule Bash.Filesystem.ETSIntegrationTest do
  use Bash.SessionCase, async: true

  alias Bash.Filesystem.ETS, as: FS
  alias Bash.Session

  defp start_ets_session(context, seed, opts \\ []) do
    table = FS.new(seed)
    working_dir = Keyword.get(opts, :working_dir, "/workspace")

    registry_name = Module.concat([context.module, ETSRegistry, context.test])
    supervisor_name = Module.concat([context.module, ETSSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name}, id: registry_name)

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: supervisor_name},
      id: supervisor_name
    )

    {:ok, session} =
      Session.new(
        filesystem: {FS, table},
        working_dir: working_dir,
        id: "#{context.test}",
        registry: registry_name,
        supervisor: supervisor_name
      )

    {session, table}
  end

  describe "echo and redirection" do
    test "echo writes to stdout", context do
      {session, _table} = start_ets_session(context, %{})
      result = run_script(session, "echo hello")
      assert get_stdout(result) == "hello\n"
    end

    test "echo redirected to file writes to VFS", context do
      {session, table} = start_ets_session(context, %{})
      run_script(session, "echo hello > /tmp/out.txt")
      assert {:ok, "hello\n"} = FS.read(table, "/tmp/out.txt")
    end

    test "echo append operator appends to existing VFS file", context do
      {session, table} = start_ets_session(context, %{"/workspace/log" => "line1\n"})
      run_script(session, "echo line2 >> log")
      assert {:ok, "line1\nline2\n"} = FS.read(table, "/workspace/log")
    end
  end

  describe "file test operators" do
    test "test -f returns true for existing file", context do
      {session, _table} =
        start_ets_session(context, %{"/workspace/file.txt" => "content"})

      result = run_script(session, "test -f file.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -d returns true for directory", context do
      {session, _table} =
        start_ets_session(context, %{"/workspace/dir" => {:dir, nil}})

      result = run_script(session, "test -d dir && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "test -e returns false for non-existent path", context do
      {session, _table} = start_ets_session(context, %{})
      result = run_script(session, "test -e missing && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end
  end

  describe "read file content from VFS" do
    test "reads seeded file content via redirect into builtin", context do
      {session, _table} =
        start_ets_session(context, %{"/workspace/data.txt" => "hello from vfs\n"})

      # cat is an external OS process and cannot access the in-memory VFS;
      # use a builtin redirect loop instead.
      result =
        run_script(session, "while read -r line; do echo \"$line\"; done < data.txt")

      assert get_stdout(result) == "hello from vfs\n"
    end
  end

  describe "/dev/null" do
    test "redirect to /dev/null suppresses output but does not affect subsequent commands",
         context do
      {session, _table} = start_ets_session(context, %{})
      result = run_script(session, "echo hidden > /dev/null; echo visible")
      assert get_stdout(result) == "visible\n"
    end
  end

  describe "source from VFS" do
    test "source executes script from VFS and sets variables", context do
      {session, _table} =
        start_ets_session(context, %{"/workspace/lib.sh" => "MY_VAR=hello"})

      # Use ./lib.sh so resolve_path joins working_dir + filename.
      # Source state updates apply after the script completes, so echo must be a
      # separate run_script call to see the updated variable.
      run_script(session, "source ./lib.sh")
      result = run_script(session, "echo $MY_VAR")
      assert get_stdout(result) == "hello\n"
    end
  end
end
