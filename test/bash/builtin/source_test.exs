defmodule Bash.Builtin.SourceTest do
  use Bash.SessionCase, async: true
  setup :start_session

  describe "source" do
    @describetag :tmp_dir
    @describetag working_dir: :tmp_dir

    test "sources a file and runs its commands", %{session: session} do
      result = run_script(session, "echo 'echo sourced' > sourceme.sh; source ./sourceme.sh")
      assert result.exit_code == 0
      assert get_stdout(result) == "sourced\n"
    end

    test "errors on nonexistent file", %{session: session} do
      result = run_script(session, "source /nonexistent_file_xyz 2>/dev/null; echo $?")
      assert get_stdout(result) == "1\n"
    end

    test "sourced file affects current environment", %{session: session} do
      result =
        run_script(session, "echo 'MY_VAR=hello' > setvar.sh; source ./setvar.sh; echo $MY_VAR")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "return inside sourced file exits the sourced script", %{session: session} do
      result =
        run_script(session, """
        echo 'echo before; return 0; echo after' > return_test.sh
        source ./return_test.sh && echo "source returned successfully"
        """)

      assert result.exit_code == 0
      stdout = get_stdout(result)
      assert stdout =~ "before"
      assert stdout =~ "source returned successfully"
      refute stdout =~ "after"
    end

    test "return with nonzero code inside sourced file", %{session: session} do
      result =
        run_script(session, """
        echo 'return 42' > return_test.sh
        source ./return_test.sh
        echo $?
        """)

      assert get_stdout(result) == "42\n"
    end

    test "sources bare filename from working directory", %{session: session} do
      result =
        run_script(session, """
        echo 'export SOURCED_VAR=it_worked' > myconfig.sh
        source myconfig.sh
        echo $SOURCED_VAR
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "it_worked\n"
    end
  end

  describe "source with virtual filesystem" do
    setup context do
      alias Bash.Filesystem.ETS, as: FS

      table =
        FS.new(%{
          "/app/config.sh" => "export DB_HOST=localhost\nexport DB_PORT=5432"
        })

      registry_name = Module.concat([context.module, VFSRegistry, context.test])
      supervisor_name = Module.concat([context.module, VFSSupervisor, context.test])
      start_supervised!({Registry, keys: :unique, name: registry_name})
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

      {:ok, session} =
        Bash.Session.new(
          id: "vfs_#{context.test}",
          filesystem: {FS, table},
          working_dir: "/app",
          registry: registry_name,
          supervisor: supervisor_name
        )

      {:ok, %{session: session}}
    end

    test "sources bare filename from working directory in VFS", %{session: session} do
      result = run_script(session, "source config.sh && echo $DB_HOST:$DB_PORT")
      assert result.exit_code == 0
      assert get_stdout(result) == "localhost:5432\n"
    end
  end
end
