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
  end

  describe "named coproc" do
    test "sets up named array and PID variable", %{session: session} do
      result = run_script(session, "coproc MYPROC cat")

      assert result.exit_code == 0

      state = Bash.Session.get_state(session)
      assert state.variables["MYPROC"] != nil
      assert state.variables["MYPROC_PID"] != nil

      pid_str = Bash.Variable.get(state.variables["MYPROC_PID"], nil)
      {pid_int, ""} = Integer.parse(pid_str)
      assert pid_int > 0
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

    test "named coproc has correct fd variables", %{session: session} do
      result =
        run_script(session, ~S"""
        coproc MYCAT cat
        echo "${MYCAT[0]} ${MYCAT[1]}"
        """)

      stdout = get_stdout(result) |> String.trim()
      [fd0, fd1] = String.split(stdout, " ")
      assert {_, ""} = Integer.parse(fd0)
      assert {_, ""} = Integer.parse(fd1)
      refute fd0 == fd1
    end
  end

  describe "error cases" do
    test "no arguments returns error", %{session: session} do
      result = run_script(session, "coproc")

      assert result.exit_code != 0
    end
  end
end
