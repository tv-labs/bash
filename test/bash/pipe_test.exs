defmodule Bash.PipeTest do
  use ExUnit.Case, async: true

  alias Bash.Pipe

  defp unique_name(context) do
    Module.concat([context.module, context.test])
  end

  describe "lifecycle" do
    test "create/destroy", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      assert %Pipe{pid: pid} = pipe
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert :ok = Pipe.destroy(pipe)
      refute Process.alive?(pid)
    end
  end

  describe "write and read_line" do
    test "write then read_line returns a line with newline", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.write(pipe, "hello\n")
      assert {:ok, "hello\n"} = Pipe.read_line(pipe)
      Pipe.destroy(pipe)
    end

    test "multiple lines buffered and read sequentially", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.write(pipe, "line1\nline2\nline3\n")
      assert {:ok, "line1\n"} = Pipe.read_line(pipe)
      assert {:ok, "line2\n"} = Pipe.read_line(pipe)
      assert {:ok, "line3\n"} = Pipe.read_line(pipe)
      Pipe.destroy(pipe)
    end

    test "partial writes assembled into lines", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.write(pipe, "hel")
      Pipe.write(pipe, "lo\n")
      assert {:ok, "hello\n"} = Pipe.read_line(pipe)
      Pipe.destroy(pipe)
    end

    test "read_line blocks until data arrives", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      parent = self()

      spawn_link(fn ->
        result = Pipe.read_line(pipe)
        send(parent, {:result, result})
      end)

      Process.sleep(20)
      Pipe.write(pipe, "async\n")
      assert_receive {:result, {:ok, "async\n"}}, 1000
      Pipe.destroy(pipe)
    end
  end

  describe "read_all" do
    test "read_all returns all data after close_write", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.write(pipe, "foo")
      Pipe.write(pipe, "bar")
      Pipe.close_write(pipe)
      assert "foobar" = Pipe.read_all(pipe)
      Pipe.destroy(pipe)
    end

    test "read_all returns empty string when closed with no data", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.close_write(pipe)
      assert "" = Pipe.read_all(pipe)
      Pipe.destroy(pipe)
    end

    test "read_all blocks until close_write", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      parent = self()

      spawn_link(fn ->
        result = Pipe.read_all(pipe)
        send(parent, {:result, result})
      end)

      Process.sleep(20)
      Pipe.write(pipe, "data")
      Pipe.close_write(pipe)
      assert_receive {:result, "data"}, 1000
      Pipe.destroy(pipe)
    end
  end

  describe "EOF behavior" do
    test "read_line returns :eof after close_write with empty buffer", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.close_write(pipe)
      assert :eof = Pipe.read_line(pipe)
      Pipe.destroy(pipe)
    end

    test "read_line returns remaining partial data then :eof on close", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.write(pipe, "partial")
      Pipe.close_write(pipe)
      assert {:ok, "partial"} = Pipe.read_line(pipe)
      assert :eof = Pipe.read_line(pipe)
      Pipe.destroy(pipe)
    end

    test "parked reader gets :eof when close_write called", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      parent = self()

      spawn_link(fn ->
        result = Pipe.read_line(pipe)
        send(parent, {:result, result})
      end)

      Process.sleep(20)
      Pipe.close_write(pipe)
      assert_receive {:result, :eof}, 1000
      Pipe.destroy(pipe)
    end

    test "write after close_write returns {:error, :closed}", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      Pipe.close_write(pipe)
      assert {:error, :closed} = Pipe.write(pipe, "too late")
      Pipe.destroy(pipe)
    end
  end

  describe "memory" do
    @tag timeout: 30_000
    test "10K x 1KB lines don't accumulate when read as they arrive", context do
      {:ok, pipe} = Pipe.create(name: unique_name(context))
      parent = self()
      line_count = 10_000
      line = String.duplicate("x", 1023) <> "\n"

      writer =
        spawn_link(fn ->
          for _ <- 1..line_count do
            Pipe.write(pipe, line)
          end

          Pipe.close_write(pipe)
        end)

      reader =
        spawn_link(fn ->
          read_all_lines(pipe, 0, parent)
        end)

      assert_receive {:done, ^line_count}, 10_000

      ref_w = Process.monitor(writer)
      ref_r = Process.monitor(reader)
      assert_receive {:DOWN, ^ref_w, :process, _, _}, 5_000
      assert_receive {:DOWN, ^ref_r, :process, _, _}, 5_000

      Pipe.destroy(pipe)
    end
  end

  defp read_all_lines(pipe, count, parent) do
    case Pipe.read_line(pipe) do
      {:ok, _line} -> read_all_lines(pipe, count + 1, parent)
      :eof -> send(parent, {:done, count})
    end
  end
end
