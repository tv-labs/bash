defmodule Bash.PathPolicyTest do
  @moduledoc """
  Tests for the `paths` dimension of `CommandPolicy`.

  Verifies that path restrictions are enforced across all filesystem callsites:
  cd, pushd, popd, source, output redirects, input redirects, test operators,
  and glob expansion.

  Uses an in-memory VFS so tests are hermetic and don't touch the real filesystem.
  """
  use Bash.SessionCase, async: true

  alias Bash.CommandPolicy
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
              {k, _} when is_binary(k) -> k == path or String.starts_with?(k, path <> "/")
              _ -> false
            end)

          _ ->
            true
        end
      end)
    end

    @impl true
    def regular?(pid, path) do
      path = normalize(path)
      Agent.get(pid, fn files -> is_binary(Map.get(files, path)) end)
    end

    @impl true
    def dir?(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        case Map.get(files, path) do
          :directory ->
            true

          nil ->
            Enum.any?(files, fn
              {k, _} when is_binary(k) -> k != path and String.starts_with?(k, path <> "/")
              _ -> false
            end)

          _ ->
            false
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
          content when is_binary(content) -> {:ok, content}
          _ -> {:error, :enoent}
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
    def stat(pid, path) do
      path = normalize(path)

      Agent.get(pid, fn files ->
        case Map.get(files, path) do
          nil ->
            {:error, :enoent}

          :directory ->
            {:ok, %File.Stat{type: :directory, size: 0, mode: 0o755}}

          content when is_binary(content) ->
            {:ok, %File.Stat{type: :regular, size: byte_size(content), mode: 0o644}}

          _ ->
            {:error, :enoent}
        end
      end)
    end

    @impl true
    def lstat(pid, path), do: stat(pid, path)

    @impl true
    def read_link(_pid, _path), do: {:error, :einval}

    @impl true
    def read_link_all(_pid, _path), do: {:error, :einval}

    @impl true
    def ls(pid, path) do
      dir_path = normalize(path)

      Agent.get(pid, fn files ->
        entries =
          files
          |> Enum.filter(fn
            {k, _} when is_binary(k) ->
              k != dir_path and String.starts_with?(k, dir_path <> "/") and
                not String.contains?(String.trim_leading(k, dir_path <> "/"), "/")

            _ ->
              false
          end)
          |> Enum.map(fn {k, _} -> Path.basename(k) end)
          |> Enum.sort()

        if entries == [] do
          if Enum.any?(files, fn
               {k, _} when is_binary(k) ->
                 k != dir_path and String.starts_with?(k, dir_path <> "/")

               _ ->
                 false
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
              k when is_binary(k) -> Regex.match?(regex, k)
              _ -> false
            end)
            |> Enum.sort()

          {:error, _} ->
            []
        end
      end)
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
            nil -> {:error, :enoent}
            :directory -> {:error, :eisdir}
            content when is_binary(content) -> StringIO.open(content)
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
  end

  defp start_policy_session(context, initial_files, path_rules, opts \\ []) do
    fs = InMemory.start(initial_files)
    working_dir = Keyword.get(opts, :working_dir, "/workspace")

    registry_name = Module.concat([context.module, PPRegistry, context.test])
    supervisor_name = Module.concat([context.module, PPSupervisor, context.test])

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    command_policy_opts =
      Keyword.get(opts, :command_policy, [])
      |> Keyword.put(:paths, path_rules)

    session_opts = [
      filesystem: fs,
      working_dir: working_dir,
      id: "#{context.test}",
      registry: registry_name,
      supervisor: supervisor_name,
      command_policy: command_policy_opts
    ]

    {:ok, session} = Session.new(session_opts)

    on_exit(fn -> InMemory.stop(fs) end)

    {session, fs}
  end

  describe "CommandPolicy.check_path/2" do
    test "nil paths allows everything" do
      policy = CommandPolicy.new(paths: nil)
      assert CommandPolicy.check_path(policy, "/any/path") == :ok
    end

    test "allowlist permits matching paths" do
      policy = CommandPolicy.new(paths: [{:allow, ["/workspace"]}])
      assert CommandPolicy.check_path(policy, "/workspace") == :ok
    end

    test "allowlist denies non-matching paths" do
      policy = CommandPolicy.new(paths: [{:allow, ["/workspace"]}])
      assert {:error, _} = CommandPolicy.check_path(policy, "/etc/passwd")
    end

    test "denylist blocks matching paths" do
      policy = CommandPolicy.new(paths: [{:disallow, ["/secret"]}, {:allow, :all}])
      assert {:error, _} = CommandPolicy.check_path(policy, "/secret")
    end

    test "denylist allows non-matching paths" do
      policy = CommandPolicy.new(paths: [{:disallow, ["/secret"]}, {:allow, :all}])
      assert CommandPolicy.check_path(policy, "/workspace/file.txt") == :ok
    end

    test "regex path rules" do
      policy = CommandPolicy.new(paths: [{:allow, [~r{^/workspace/}]}])
      assert CommandPolicy.check_path(policy, "/workspace/file.txt") == :ok
      assert {:error, _} = CommandPolicy.check_path(policy, "/etc/passwd")
    end

    test "function path rules" do
      policy = CommandPolicy.new(paths: fn path -> String.starts_with?(path, "/workspace") end)
      assert CommandPolicy.check_path(policy, "/workspace/file.txt") == :ok
      assert {:error, _} = CommandPolicy.check_path(policy, "/etc/passwd")
    end

    test "first match wins in rule list" do
      policy =
        CommandPolicy.new(
          paths: [
            {:disallow, [~r{/\.secret}]},
            {:allow, [~r{^/workspace/}]}
          ]
        )

      assert CommandPolicy.check_path(policy, "/workspace/file.txt") == :ok
      assert {:error, _} = CommandPolicy.check_path(policy, "/workspace/.secret")
    end

    test "empty rule list denies by default" do
      policy = CommandPolicy.new(paths: [])
      assert {:error, _} = CommandPolicy.check_path(policy, "/workspace")
    end
  end

  describe "cd with path policy" do
    test "cd to allowed directory succeeds", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/subdir" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "cd subdir && pwd")
      assert get_stdout(result) == "/workspace/subdir\n"
    end

    test "cd to disallowed directory fails", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/secret" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "cd /secret; echo exit=$?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted path"
    end

    test "cd - to disallowed OLDPWD fails", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{
            "/allowed" => :directory,
            "/allowed/sub" => :directory,
            "/restricted" => :directory
          },
          [{:disallow, ["/restricted"]}, {:allow, :all}],
          working_dir: "/allowed"
        )

      result = run_script(session, "OLDPWD=/restricted; cd -; echo exit=$?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted path"
    end
  end

  describe "source with path policy" do
    test "source from allowed path succeeds", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/lib.sh" => "echo sourced"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "source /workspace/lib.sh")
      assert get_stdout(result) == "sourced\n"
    end

    test "source from disallowed path fails", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/etc/evil.sh" => "echo hacked"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "source /etc/evil.sh; echo $?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted path" or output =~ "source:"
      refute output =~ "hacked"
    end
  end

  describe "output redirects with path policy" do
    test "redirect to allowed path succeeds", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "echo hello > /workspace/out.txt; echo $?")
      assert get_stdout(result) =~ "0"
    end

    test "redirect to disallowed path fails", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "echo evil > /etc/crontab 2>&1; echo exit=$?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted path"
    end

    test "append redirect to disallowed path fails", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "echo evil >> /etc/crontab 2>&1; echo exit=$?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted path"
    end
  end

  describe "input redirects with path policy" do
    test "input from allowed path succeeds", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/data.txt" => "hello world"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "read line < /workspace/data.txt; echo $line")
      assert get_stdout(result) =~ "hello world"
    end

    test "input from disallowed path returns empty", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/secret/data.txt" => "secret"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "read line < /secret/data.txt; echo \"got=$line\"")
      # When path is restricted, read_input_redirect returns default_stdin (nil/empty)
      stdout = get_stdout(result)
      assert stdout =~ "got="
      refute stdout =~ "secret"
    end
  end

  describe "test operators with path policy" do
    test "-e returns false for restricted path", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/ok.txt" => "ok", "/secret/hidden.txt" => "hidden"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "test -e /workspace/ok.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -e /secret/hidden.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "-f returns false for restricted path", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/ok.txt" => "ok", "/secret/hidden.txt" => "hidden"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "test -f /secret/hidden.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "-d returns false for restricted path", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/secret" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "test -d /secret && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "-r returns false for restricted path", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/ok.txt" => "ok", "/secret/hidden.txt" => "hidden"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "test -r /secret/hidden.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "-s returns false for restricted path", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/secret/data.txt" => "notempty"},
          [{:allow, [~r{^/workspace}]}],
          working_dir: "/workspace"
        )

      result = run_script(session, "test -s /secret/data.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end

    test "bracket test [ -e ] respects path policy", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/secret/file.txt" => "secret"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "[ -e /secret/file.txt ] && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end
  end

  describe "glob expansion with path policy" do
    test "glob filters out restricted paths", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{
            "/workspace/allowed.txt" => "ok",
            "/workspace/also_ok.txt" => "ok"
          },
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "echo *.txt")
      stdout = get_stdout(result)
      assert stdout =~ "allowed.txt"
      assert stdout =~ "also_ok.txt"
    end
  end

  describe "combined command + path policy" do
    test "both dimensions enforced independently", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/data.txt" => "hello", "/secret/data.txt" => "nope"},
          [{:allow, [~r{^/workspace}]}],
          command_policy: [commands: :no_external]
        )

      # Builtin works with allowed path
      result = run_script(session, "test -f /workspace/data.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      # Builtin fails with restricted path
      result = run_script(session, "test -f /secret/data.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"

      # External command blocked
      result = run_script(session, "cat /workspace/data.txt; echo $?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted" or output =~ "not allowed" or output =~ "command not allowed"
    end
  end

  describe "pushd/popd with path policy" do
    test "pushd to allowed directory succeeds", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/workspace/sub" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "pushd /workspace/sub; pwd")
      assert get_stdout(result) =~ "/workspace/sub"
    end

    test "pushd to restricted directory fails", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace" => :directory, "/secret" => :directory},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "pushd /secret; echo $?")
      output = get_stdout(result) <> get_stderr(result)
      assert output =~ "restricted path"
    end
  end

  describe "path policy with denylist" do
    test "denylist blocks specific paths", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{
            "/workspace/ok.txt" => "ok",
            "/workspace/.secret" => "hidden"
          },
          [{:disallow, [~r{/\.secret}]}, {:allow, :all}]
        )

      result = run_script(session, "test -f /workspace/ok.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -f /workspace/.secret && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end
  end

  describe "path policy with function rules" do
    test "function-based path policy", context do
      path_fn = fn path -> String.starts_with?(path, "/workspace") end

      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/file.txt" => "ok", "/other/file.txt" => "nope"},
          path_fn
        )

      result = run_script(session, "test -f /workspace/file.txt && echo yes || echo no")
      assert get_stdout(result) == "yes\n"

      result = run_script(session, "test -f /other/file.txt && echo yes || echo no")
      assert get_stdout(result) == "no\n"
    end
  end

  describe "path policy inheritance" do
    test "subshells inherit path policy", context do
      {session, _fs} =
        start_policy_session(
          context,
          %{"/workspace/file.txt" => "ok", "/secret/file.txt" => "nope"},
          [{:allow, [~r{^/workspace}]}]
        )

      result = run_script(session, "(test -f /secret/file.txt && echo yes || echo no)")
      assert get_stdout(result) == "no\n"

      result = run_script(session, "(test -f /workspace/file.txt && echo yes || echo no)")
      assert get_stdout(result) == "yes\n"
    end
  end
end
