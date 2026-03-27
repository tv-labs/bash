defmodule Bash.CommandPortTest do
  use ExUnit.Case, async: true

  alias Bash.CommandPort

  describe "low-level process API" do
    test "start_link + os_pid + read + await_exit" do
      {:ok, proc} =
        CommandPort.start_link(["echo", "hello"], [stderr: :redirect_to_stdout], false)

      os_pid =
        case CommandPort.os_pid(proc) do
          {:ok, pid} -> pid
          pid when is_integer(pid) -> pid
        end

      assert is_integer(os_pid)
      assert {:ok, "hello\n"} = CommandPort.read(proc)
      assert :eof = CommandPort.read(proc)
      assert {:ok, 0} = CommandPort.await_exit(proc, 5000)
    end

    test "write + close_stdin" do
      {:ok, proc} = CommandPort.start_link(["cat"], [stderr: :redirect_to_stdout], false)
      assert :ok = CommandPort.write(proc, "test data")
      CommandPort.close_stdin(proc)
      assert {:ok, "test data"} = CommandPort.read(proc)
      assert {:ok, 0} = CommandPort.await_exit(proc, 5000)
    end

    test "stream returns enumerable" do
      stream = CommandPort.stream(["echo", "hello"], [stderr: :redirect_to_stdout], false)
      chunks = Enum.to_list(stream)
      assert Enum.any?(chunks, &is_binary/1)
    end

    test "system_cmd delegates to System.cmd" do
      {output, 0} = CommandPort.system_cmd("echo", ["hi"], [], false)
      assert String.trim(output) == "hi"
    end
  end

  describe "restricted mode" do
    test "start_link returns error when restricted" do
      assert {:error, :restricted} = CommandPort.start_link(["ls"], [], true)
    end

    test "stream returns error when restricted" do
      assert {:error, :restricted} = CommandPort.stream(["ls"], [], true)
    end

    test "system_cmd returns error when restricted" do
      assert {:error, :restricted} = CommandPort.system_cmd("ls", [], [], true)
    end
  end

  describe "restricted? helper (on Session)" do
    test "returns false for unrestricted state" do
      refute Bash.Session.restricted?(%{options: %{restricted: false}})
    end

    test "returns true for restricted state" do
      assert Bash.Session.restricted?(%{options: %{restricted: true}})
    end

    test "returns false when options missing" do
      refute Bash.Session.restricted?(%{})
    end
  end
end
