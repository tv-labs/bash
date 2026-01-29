defmodule Bash.Builtin.CoprocTest do
  use Bash.SessionCase, async: false

  setup :start_session

  describe "basic coproc" do
    test "starts a background process and sets COPROC array", %{session: session} do
      result = run_script(session, "coproc cat")

      assert result.exit_code == 0

      state = Bash.Session.get_state(session)
      assert state.variables["COPROC"] != nil
      assert state.variables["COPROC_PID"] != nil

      coproc_var = state.variables["COPROC"]
      assert coproc_var.value[0] != nil
      assert coproc_var.value[1] != nil
    end

    test "COPROC_PID is a numeric value", %{session: session} do
      result = run_script(session, "coproc cat")

      assert result.exit_code == 0

      pid_str = get_var(session, "COPROC_PID")
      assert pid_str != nil
      {pid_int, ""} = Integer.parse(pid_str)
      assert pid_int > 0
    end

    test "default name is COPROC even when command looks like identifier", %{session: session} do
      result = run_script(session, "coproc cat -n")

      assert result.exit_code == 0

      state = Bash.Session.get_state(session)
      assert state.variables["COPROC"] != nil
      assert state.variables["COPROC_PID"] != nil
    end
  end

  describe "named coproc with compound command" do
    test "sets up named array and PID variable", %{session: session} do
      result = run_script(session, "coproc MYPROC { cat; }")

      assert result.exit_code == 0

      state = Bash.Session.get_state(session)
      assert state.variables["MYPROC"] != nil
      assert state.variables["MYPROC_PID"] != nil

      pid_str = Bash.Variable.get(state.variables["MYPROC_PID"], nil)
      {pid_int, ""} = Integer.parse(pid_str)
      assert pid_int > 0
    end

    test "named coproc has correct fd variables", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc MYCAT { cat; }
        echo "${MYCAT[0]} ${MYCAT[1]}"
        """)

      stdout = get_stdout(result) |> String.trim()
      [fd0, fd1] = String.split(stdout, " ")
      assert {_, ""} = Integer.parse(fd0)
      assert {_, ""} = Integer.parse(fd1)
      refute fd0 == fd1
    end

    test "unnamed compound coproc uses COPROC name", %{session: session} do
      result = run_script(session, "coproc { cat; }")

      assert result.exit_code == 0

      state = Bash.Session.get_state(session)
      assert state.variables["COPROC"] != nil
      assert state.variables["COPROC_PID"] != nil
    end
  end

  describe "coproc file descriptors" do
    test "COPROC[0] and COPROC[1] are numeric fd values", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc cat
        echo "${COPROC[0]} ${COPROC[1]}"
        """)

      stdout = get_stdout(result) |> String.trim()
      [fd0, fd1] = String.split(stdout, " ")
      assert {_, ""} = Integer.parse(fd0)
      assert {_, ""} = Integer.parse(fd1)
    end

    test "COPROC[0] and COPROC[1] are different", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc cat
        echo "${COPROC[0]} ${COPROC[1]}"
        """)

      stdout = get_stdout(result) |> String.trim()
      [fd0, fd1] = String.split(stdout, " ")
      refute fd0 == fd1
    end
  end

  describe "coproc I/O" do
    test "write to coproc stdin and read from coproc stdout", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc cat
        echo hello >&${COPROC[1]}
        eval "exec ${COPROC[1]}>&-"
        read -u ${COPROC[0]} line
        echo "$line"
        """)

      assert get_stdout(result) |> String.trim() == "hello"
    end

    test "FDs are registered in session file_descriptors", %{session: session} do
      run_script(session, "coproc cat")

      state = Bash.Session.get_state(session)
      coproc_var = state.variables["COPROC"]
      read_fd_str = coproc_var.value[0]
      write_fd_str = coproc_var.value[1]
      {read_fd, ""} = Integer.parse(read_fd_str)
      {write_fd, ""} = Integer.parse(write_fd_str)

      assert {:coproc, _pid, :read} = Map.get(state.file_descriptors, read_fd)
      assert {:coproc, _pid, :write} = Map.get(state.file_descriptors, write_fd)
    end
  end

  describe "coproc I/O integration" do
    test "multi-round conversation proves streaming through OS pipes", %{session: session} do
      # Use bash read loop as coproc — cat fully buffers when stdout is a pipe.
      # Bash read/echo is line-buffered, enabling multi-round conversation.
      result =
        run_script(session, ~S"""
        coproc bash -c 'while IFS= read -r line; do echo "$line"; done'
        echo first >&${COPROC[1]}
        read -u ${COPROC[0]} line1
        echo second >&${COPROC[1]}
        read -u ${COPROC[0]} line2
        echo third >&${COPROC[1]}
        read -u ${COPROC[0]} line3
        eval "exec ${COPROC[1]}>&-"
        echo "$line1 $line2 $line3"
        """)

      assert get_stdout(result) |> String.trim() == "first second third"
    end

    test "FDs are backed by coproc tuples, not in-memory buffers", %{session: session} do
      run_script(session, "coproc cat")

      state = Bash.Session.get_state(session)
      coproc_var = state.variables["COPROC"]
      {read_fd, ""} = Integer.parse(coproc_var.value[0])
      {write_fd, ""} = Integer.parse(coproc_var.value[1])

      read_entry = Map.fetch!(state.file_descriptors, read_fd)
      write_entry = Map.fetch!(state.file_descriptors, write_fd)

      assert {:coproc, coproc_pid, :read} = read_entry
      assert {:coproc, ^coproc_pid, :write} = write_entry

      assert Process.alive?(coproc_pid)
      refute is_pid(read_entry)
    end

    test "large data streams through OS pipes without growing BEAM memory", %{session: session} do
      line_count = 10_000

      :erlang.garbage_collect()
      memory_before = :erlang.memory(:processes)

      result =
        run_script(session, """
        coproc bash -c 'while IFS= read -r line; do echo "$line"; done'
        i=0
        while [ $i -lt #{line_count} ]; do
          echo "AAAAAAAAAA" >&${COPROC[1]}
          read -u ${COPROC[0]} discard
          i=$((i + 1))
        done
        eval "exec ${COPROC[1]}>&-"
        echo "$i"
        """)

      :erlang.garbage_collect()
      memory_after = :erlang.memory(:processes)

      assert get_stdout(result) |> String.trim() == "#{line_count}"

      memory_growth = memory_after - memory_before

      assert memory_growth < 1 * 1024 * 1024,
             "BEAM process memory grew by #{div(memory_growth, 1024)}KB — data may be buffered"
    end

    test "random data from /dev/urandom streams without growing BEAM memory", %{session: session} do
      line_count = 1_000

      :erlang.garbage_collect()
      memory_before = :erlang.memory(:processes)

      result =
        run_script(session, """
        coproc cat
        i=0
        while [ $i -lt #{line_count} ]; do
          head -c 64 /dev/urandom | xxd -p | tr -d '\\n' >&${COPROC[1]}
          echo >&${COPROC[1]}
          read -u ${COPROC[0]} discard
          i=$((i + 1))
        done
        eval "exec ${COPROC[1]}>&-"
        echo "$i"
        """)

      :erlang.garbage_collect()
      memory_after = :erlang.memory(:processes)

      assert get_stdout(result) |> String.trim() == "#{line_count}"

      memory_growth = memory_after - memory_before

      assert memory_growth < 2 * 1024 * 1024,
             "BEAM process memory grew by #{div(memory_growth, 1024)}KB — data may be buffered"
    end

    test "closing write FD signals EOF to coproc", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc cat
        echo done >&${COPROC[1]}
        eval "exec ${COPROC[1]}>&-"
        read -u ${COPROC[0]} line
        echo "$line"
        """)

      assert get_stdout(result) |> String.trim() == "done"

      state = Bash.Session.get_state(session)
      coproc_var = state.variables["COPROC"]
      {write_fd, ""} = Integer.parse(coproc_var.value[1])
      refute Map.has_key?(state.file_descriptors, write_fd)
    end
  end

  describe "error cases" do
    test "no arguments returns error", %{session: session} do
      result = run_script(session, "coproc")
      assert result.exit_code != 0
    end
  end
end
