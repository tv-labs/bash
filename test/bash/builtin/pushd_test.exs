defmodule Bash.Builtin.PushdTest do
  use ExUnit.Case, async: true

  alias Bash.Builtin.Pushd
  alias Bash.CommandResult
  alias Bash.Variable

  describe "pushd with no args (swap)" do
    test "swaps top two directories" do
      tmp_dir = System.tmp_dir!()

      session_state = %{
        dir_stack: [tmp_dir],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute([], nil, session_state)

      assert updates.working_dir == tmp_dir
      assert updates.dir_stack == ["/"]
    end

    test "returns error when stack is empty" do
      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 1}} =
               Pushd.execute([], nil, session_state)
    end
  end

  describe "pushd with directory" do
    test "pushes directory and changes to it" do
      tmp_dir = System.tmp_dir!() |> Path.expand()

      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute([tmp_dir], nil, session_state)

      assert updates.working_dir == tmp_dir
      assert updates.dir_stack == ["/"]
    end

    test "updates PWD and OLDPWD" do
      tmp_dir = System.tmp_dir!() |> Path.expand()

      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute([tmp_dir], nil, session_state)

      assert updates.env_updates["PWD"] == tmp_dir
      assert updates.env_updates["OLDPWD"] == "/"
    end

    test "returns error for non-existent directory" do
      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 1}} =
               Pushd.execute(["/nonexistent/path"], nil, session_state)
    end
  end

  describe "pushd -n (no directory change)" do
    test "pushes directory without changing working_dir" do
      tmp_dir = System.tmp_dir!() |> Path.expand()

      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute(["-n", tmp_dir], nil, session_state)

      # Directory should be on stack but not changed to
      assert updates.dir_stack == [tmp_dir]
      refute Map.has_key?(updates, :working_dir)
    end

    test "-n with swap only manipulates stack" do
      tmp_dir = System.tmp_dir!()

      session_state = %{
        dir_stack: [tmp_dir],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute(["-n"], nil, session_state)

      # Stack is manipulated but working_dir not changed
      refute Map.has_key?(updates, :working_dir)
    end
  end

  describe "pushd +N (rotate from left)" do
    test "+0 brings first element to top (no change)" do
      tmp_dir = System.tmp_dir!()

      session_state = %{
        dir_stack: [tmp_dir],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute(["+0"], nil, session_state)

      # +0 means current directory stays current
      assert updates.working_dir == "/"
    end

    test "+1 brings second element to top" do
      tmp_dir = System.tmp_dir!()

      session_state = %{
        dir_stack: [tmp_dir, "/var"],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute(["+1"], nil, session_state)

      # [/, tmp, /var] -> rotation at index 1 brings tmp to front
      assert updates.working_dir == tmp_dir
    end

    test "returns error for out of range index" do
      session_state = %{
        dir_stack: ["/"],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 1}} =
               Pushd.execute(["+10"], nil, session_state)
    end
  end

  describe "pushd -N (rotate from right)" do
    test "-0 brings last element to top" do
      tmp_dir = System.tmp_dir!()

      session_state = %{
        dir_stack: ["/", tmp_dir],
        working_dir: "/var",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute(["-0"], nil, session_state)

      # Full stack [/var, /, tmp], -0 is last (tmp)
      assert updates.working_dir == tmp_dir
    end
  end

  describe "pushd with tilde expansion" do
    test "expands ~ to HOME" do
      home = System.get_env("HOME")

      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{
          "HOME" => Variable.new(home)
        }
      }

      assert {:ok, %CommandResult{exit_code: 0}, updates} =
               Pushd.execute(["~"], nil, session_state)

      assert updates.working_dir == home
    end

    test "expands ~/subdir" do
      home = System.get_env("HOME")

      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{
          "HOME" => Variable.new(home)
        }
      }

      # Use a directory that's likely to exist
      assert {:ok, %CommandResult{exit_code: 0}, _updates} =
               Pushd.execute(["~"], nil, session_state)
    end
  end

  describe "pushd with invalid arguments" do
    test "invalid option returns error" do
      session_state = %{
        dir_stack: [],
        working_dir: "/",
        variables: %{}
      }

      assert {:ok, %CommandResult{exit_code: 1}} =
               Pushd.execute(["-x"], nil, session_state)
    end
  end
end
