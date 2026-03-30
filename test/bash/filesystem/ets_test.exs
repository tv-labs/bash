defmodule Bash.Filesystem.ETSTest do
  use ExUnit.Case, async: true

  alias Bash.Filesystem.ETS

  describe "new/0" do
    test "returns an ETS table id" do
      tid = ETS.new()
      assert is_reference(tid) or is_integer(tid)
      :ets.delete(tid)
    end

    test "seeds POSIX skeleton directories" do
      tid = ETS.new()

      for path <- ["/", "/tmp", "/dev", "/bin", "/usr", "/usr/bin", "/home"] do
        assert ETS.exists?(tid, path), "expected #{path} to exist"
        assert ETS.dir?(tid, path), "expected #{path} to be a directory"
      end

      :ets.delete(tid)
    end

    test "skeleton directories have mode 0o755" do
      tid = ETS.new()
      {:ok, stat} = ETS.stat(tid, "/tmp")
      assert stat.mode == 0o755
      :ets.delete(tid)
    end
  end

  describe "new/1 with string seed value" do
    test "creates file with default mode 0o644" do
      tid = ETS.new(%{"/home/user/hello.txt" => "hello world"})
      assert ETS.exists?(tid, "/home/user/hello.txt")
      assert ETS.regular?(tid, "/home/user/hello.txt")
      {:ok, stat} = ETS.stat(tid, "/home/user/hello.txt")
      assert stat.mode == 0o644
      :ets.delete(tid)
    end

    test "stores content readable via read/2" do
      tid = ETS.new(%{"/tmp/greeting.txt" => "hi there"})
      assert {:ok, "hi there"} = ETS.read(tid, "/tmp/greeting.txt")
      :ets.delete(tid)
    end
  end

  describe "new/1 with map seed value" do
    test "creates file with explicit mode" do
      tid = ETS.new(%{"/usr/bin/myscript" => %{content: "#!/bin/bash", mode: 0o755}})
      assert ETS.exists?(tid, "/usr/bin/myscript")
      {:ok, stat} = ETS.stat(tid, "/usr/bin/myscript")
      assert stat.mode == 0o755
      :ets.delete(tid)
    end

    test "defaults to mode 0o644 when mode omitted in map" do
      tid = ETS.new(%{"/tmp/data.txt" => %{content: "data"}})
      {:ok, stat} = ETS.stat(tid, "/tmp/data.txt")
      assert stat.mode == 0o644
      :ets.delete(tid)
    end

    test "stores content readable via read/2" do
      tid = ETS.new(%{"/tmp/script.sh" => %{content: "echo hi", mode: 0o755}})
      assert {:ok, "echo hi"} = ETS.read(tid, "/tmp/script.sh")
      :ets.delete(tid)
    end
  end

  describe "new/1 with {:dir, nil} seed value" do
    test "creates an empty directory" do
      tid = ETS.new(%{"/tmp/mydir" => {:dir, nil}})
      assert ETS.exists?(tid, "/tmp/mydir")
      assert ETS.dir?(tid, "/tmp/mydir")
      refute ETS.regular?(tid, "/tmp/mydir")
      :ets.delete(tid)
    end
  end

  describe "new/1 parent directory auto-creation" do
    test "auto-creates intermediate directories" do
      tid = ETS.new(%{"/a/b/c/file.txt" => "content"})

      for path <- ["/", "/a", "/a/b", "/a/b/c"] do
        assert ETS.exists?(tid, path), "expected parent #{path} to exist"
        assert ETS.dir?(tid, path), "expected parent #{path} to be a dir"
      end

      assert ETS.regular?(tid, "/a/b/c/file.txt")
      :ets.delete(tid)
    end

    test "does not overwrite existing directories when auto-creating" do
      tid = ETS.new(%{"/tmp/subdir/file.txt" => "content"})
      assert ETS.dir?(tid, "/tmp")
      assert ETS.dir?(tid, "/tmp/subdir")
      :ets.delete(tid)
    end
  end

  describe "exists?/2" do
    test "returns true for existing file" do
      tid = ETS.new(%{"/tmp/file.txt" => "hello"})
      assert ETS.exists?(tid, "/tmp/file.txt")
      :ets.delete(tid)
    end

    test "returns false for non-existent path" do
      tid = ETS.new()
      refute ETS.exists?(tid, "/nonexistent/path.txt")
      :ets.delete(tid)
    end

    test "returns true for magic device paths" do
      tid = ETS.new()

      for path <- ["/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr"] do
        assert ETS.exists?(tid, path), "expected #{path} to exist"
      end

      :ets.delete(tid)
    end
  end

  describe "dir?/2" do
    test "returns true for seeded directory" do
      tid = ETS.new()
      assert ETS.dir?(tid, "/tmp")
      :ets.delete(tid)
    end

    test "returns false for a file" do
      tid = ETS.new(%{"/tmp/file.txt" => "data"})
      refute ETS.dir?(tid, "/tmp/file.txt")
      :ets.delete(tid)
    end

    test "returns false for non-existent path" do
      tid = ETS.new()
      refute ETS.dir?(tid, "/nonexistent")
      :ets.delete(tid)
    end
  end

  describe "regular?/2" do
    test "returns true for a file" do
      tid = ETS.new(%{"/tmp/data.txt" => "data"})
      assert ETS.regular?(tid, "/tmp/data.txt")
      :ets.delete(tid)
    end

    test "returns false for a directory" do
      tid = ETS.new()
      refute ETS.regular?(tid, "/tmp")
      :ets.delete(tid)
    end

    test "returns false for non-existent path" do
      tid = ETS.new()
      refute ETS.regular?(tid, "/nonexistent/file.txt")
      :ets.delete(tid)
    end
  end

  describe "stat/2" do
    test "file stat has correct type and size" do
      content = "hello world"
      tid = ETS.new(%{"/tmp/test.txt" => content})
      {:ok, stat} = ETS.stat(tid, "/tmp/test.txt")
      assert stat.type == :regular
      assert stat.size == byte_size(content)
      assert stat.access == :read_write
      :ets.delete(tid)
    end

    test "directory stat has correct type" do
      tid = ETS.new()
      {:ok, stat} = ETS.stat(tid, "/tmp")
      assert stat.type == :directory
      assert stat.size == 0
      assert stat.access == :read_write
      :ets.delete(tid)
    end

    test "returns error for non-existent path" do
      tid = ETS.new()
      assert {:error, _} = ETS.stat(tid, "/nonexistent")
      :ets.delete(tid)
    end

    test "/dev/null returns device stat" do
      tid = ETS.new()
      assert {:ok, stat} = ETS.stat(tid, "/dev/null")
      assert stat.type == :device
      :ets.delete(tid)
    end

    test "/dev/stdin returns device stat" do
      tid = ETS.new()
      assert {:ok, stat} = ETS.stat(tid, "/dev/stdin")
      assert stat.type == :device
      :ets.delete(tid)
    end
  end

  describe "lstat/2" do
    test "delegates to stat/2" do
      tid = ETS.new(%{"/tmp/file.txt" => "content"})
      assert ETS.lstat(tid, "/tmp/file.txt") == ETS.stat(tid, "/tmp/file.txt")
      :ets.delete(tid)
    end
  end

  describe "read/2" do
    test "reads file content" do
      tid = ETS.new(%{"/tmp/readme.txt" => "readme content"})
      assert {:ok, "readme content"} = ETS.read(tid, "/tmp/readme.txt")
      :ets.delete(tid)
    end

    test "/dev/null returns empty binary" do
      tid = ETS.new()
      assert {:ok, ""} = ETS.read(tid, "/dev/null")
      :ets.delete(tid)
    end

    test "/dev/stdout returns :eacces error" do
      tid = ETS.new()
      assert {:error, :eacces} = ETS.read(tid, "/dev/stdout")
      :ets.delete(tid)
    end

    test "/dev/stderr returns :eacces error" do
      tid = ETS.new()
      assert {:error, :eacces} = ETS.read(tid, "/dev/stderr")
      :ets.delete(tid)
    end

    test "returns error for non-existent file" do
      tid = ETS.new()
      assert {:error, _} = ETS.read(tid, "/nonexistent/file.txt")
      :ets.delete(tid)
    end

    test "returns error when reading a directory" do
      tid = ETS.new()
      assert {:error, _} = ETS.read(tid, "/tmp")
      :ets.delete(tid)
    end
  end
end
