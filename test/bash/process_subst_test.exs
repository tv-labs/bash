defmodule Bash.ProcessSubstTest do
  use ExUnit.Case, async: false

  alias Bash.ProcessSubst
  alias Bash.Parser
  alias Bash.Session

  @moduletag :tmp_dir

  setup do
    # Clean up any leftover FIFOs from previous runs
    Path.wildcard("/tmp/runcom_proc_subst_*") |> Enum.each(&File.rm/1)
    :ok
  end

  describe "FIFO basics" do
    test "mkfifo creates named pipe that allows read/write" do
      fifo_path = "/tmp/test_fifo_#{:rand.uniform(999_999)}"

      # Create FIFO
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      assert File.exists?(fifo_path)

      # Start writer first (will block until reader opens)
      # Use :raw mode for FIFO compatibility - Elixir's buffered I/O doesn't work with FIFOs
      parent = self()

      spawn(fn ->
        {:ok, fd} = :file.open(fifo_path, [:write, :raw])
        :file.write(fd, "hello from fifo\n")
        :file.close(fd)
        send(parent, :writer_done)
      end)

      # Give writer time to start (it will block on open)
      Process.sleep(50)

      # Now reader opens - this unblocks writer
      {:ok, fd} = :file.open(fifo_path, [:read, :raw])
      {:ok, data} = :file.read(fd, 1024)
      :file.close(fd)
      content = to_string(data)

      # Wait for writer to confirm
      receive do
        :writer_done -> :ok
      after
        1000 -> flunk("Writer didn't complete")
      end

      assert content == "hello from fifo\n"

      # Cleanup
      File.rm(fifo_path)
    end
  end

  describe "ProcessSubst GenServer" do
    test "creates FIFO and returns path" do
      # Create a simple session state for testing
      {:ok, session} = Session.start_link(id: "proc-subst-test-1")
      state = :sys.get_state(session)

      # Parse a simple command
      {:ok, ast} = Parser.parse("echo hello")
      %Bash.Script{statements: [cmd]} = ast

      # Start process substitution
      {:ok, pid, fifo_path} =
        ProcessSubst.start_link(
          direction: :input,
          command_ast: cmd,
          session_state: state,
          temp_dir: "/tmp"
        )

      assert is_pid(pid)
      assert is_binary(fifo_path)
      assert String.starts_with?(fifo_path, "/tmp/runcom_proc_subst_")
      assert File.exists?(fifo_path)

      # The FIFO should be a named pipe
      {:ok, stat} = File.stat(fifo_path)
      # FIFOs show as :other in Elixir
      assert stat.type == :other

      # Read from the FIFO (worker should have written "hello\n")
      # Use :raw mode for FIFO compatibility
      {:ok, fd} = :file.open(fifo_path, [:read, :raw])
      {:ok, data} = :file.read(fd, 1024)
      :file.close(fd)
      content = to_string(data)

      assert content == "hello\n"

      # Cleanup
      ProcessSubst.stop(pid)
      Session.stop(session)
    end
  end

  describe "word expansion with process substitution" do
    test "expands process substitution to FIFO path" do
      {:ok, session} = Session.start_link(id: "proc-subst-test-2")
      state = :sys.get_state(session)

      # Parse command with process substitution
      {:ok, ast} = Parser.parse("cat <(echo hello)")
      %Bash.Script{statements: [cmd]} = ast

      # Get the argument word with process substitution
      [arg_word] = cmd.args

      # Expand the word
      expanded = Bash.AST.Helpers.word_to_string(arg_word, state)

      # Should be a FIFO path
      assert is_binary(expanded)
      assert String.starts_with?(expanded, "/tmp/runcom_proc_subst_")

      # Read from the FIFO to verify worker wrote to it
      # Use :raw mode for FIFO compatibility
      {:ok, fd} = :file.open(expanded, [:read, :raw])
      {:ok, data} = :file.read(fd, 1024)
      :file.close(fd)
      content = to_string(data)

      assert content == "hello\n"

      # Cleanup
      File.rm(expanded)
      Session.stop(session)
    end
  end

  describe "streaming large data" do
    @tag timeout: 120_000
    test "20MB piped through process substitution does not accumulate in memory" do
      # Test as a user would - execute a bash script through Session
      # Generate 20MB of random data, pipe through process substitution to wc -c
      # All processes should stream data, not accumulate it

      {:ok, session} = Session.start_link(id: "streaming-test")

      # Parse the script first
      {:ok, ast} = Parser.parse("wc -c <(dd if=/dev/urandom bs=1M count=20 2>/dev/null)")

      # Force garbage collection to get baseline
      :erlang.garbage_collect()
      Process.sleep(100)

      # Track max memory during execution by sampling total VM memory
      # This captures ALL process memory, not just session-linked processes
      memory_samples = :ets.new(:memory_samples, [:bag, :public])

      monitor =
        spawn_link(fn ->
          monitor_total_memory(memory_samples, self())
        end)

      # Execute the parsed AST
      result = Session.execute(session, ast)

      # Stop the monitor
      send(monitor, :stop)

      receive do
        :monitor_stopped -> :ok
      after
        1000 -> :ok
      end

      # Check result succeeded (Session.execute returns {:ok, script_result})
      assert {:ok, %Bash.Script{} = script} = result
      stdout = Bash.ExecutionResult.stdout(script)
      # wc -c outputs "COUNT FILENAME", extract just the count
      [count_str | _] = String.split(String.trim(stdout), ~r/\s+/)
      byte_count = String.to_integer(count_str)

      assert byte_count >= 20 * 1024 * 1024,
             "Expected ~20MB but got #{byte_count} bytes"

      assert byte_count <= 21 * 1024 * 1024,
             "Expected ~20MB but got #{byte_count} bytes"

      # Check memory growth - get all samples and find max
      samples = :ets.tab2list(memory_samples)

      {min_mem, max_mem} =
        Enum.reduce(samples, {nil, 0}, fn {mem}, {min_acc, max_acc} ->
          new_min = if min_acc == nil, do: mem, else: min(min_acc, mem)
          {new_min, max(mem, max_acc)}
        end)

      memory_growth = if min_mem, do: max_mem - min_mem, else: 0

      # If streaming, memory growth should be much less than 20MB
      # Allow 5MB for overhead but not 20MB accumulation
      assert memory_growth < 5 * 1024 * 1024,
             "Memory grew by #{div(memory_growth, 1024 * 1024)}MB during execution - " <>
               "data is being accumulated instead of streamed! " <>
               "(min: #{div(min_mem || 0, 1024 * 1024)}MB, max: #{div(max_mem, 1024 * 1024)}MB)"

      :ets.delete(memory_samples)
      Session.stop(session)
    end

    @tag timeout: 120_000
    test "streaming through session with simple process substitution" do
      # Simpler test - just verify process substitution works end-to-end
      {:ok, session} = Session.start_link(id: "simple-stream-test")

      # Parse the command first
      {:ok, ast} = Parser.parse("cat <(echo hello)")

      # Execute through session
      result = Session.execute(session, ast)

      # Session.execute returns {:ok, script_result} for Script AST
      assert {:ok, %Bash.Script{} = script} = result
      stdout = Bash.ExecutionResult.stdout(script)
      assert stdout == "hello\n"

      Session.stop(session)
    end
  end

  defp monitor_total_memory(ets_table, parent) do
    # Sample total VM memory every 10ms for more granular data
    receive do
      :stop ->
        send(parent, :monitor_stopped)
    after
      10 ->
        total = :erlang.memory(:total)
        :ets.insert(ets_table, {total})
        monitor_total_memory(ets_table, parent)
    end
  end
end
