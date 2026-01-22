defmodule Bash.TelemetryTest do
  # Run serially to avoid test interference via global telemetry handlers
  use Bash.SessionCase, async: false

  setup :start_session

  setup context do
    test_pid = self()
    handler_id = "telemetry-test-#{context.test}"

    :telemetry.attach_many(
      handler_id,
      [
        [:bash, :session, :run, :start],
        [:bash, :session, :run, :stop],
        [:bash, :session, :run, :exception],
        [:bash, :command, :start],
        [:bash, :command, :stop],
        [:bash, :command, :exception],
        [:bash, :for_loop, :start],
        [:bash, :for_loop, :stop],
        [:bash, :for_loop, :exception],
        [:bash, :while_loop, :start],
        [:bash, :while_loop, :stop],
        [:bash, :while_loop, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "session run telemetry" do
    test "emits start and stop events", %{session: session} do
      {:ok, _result, ^session} = Bash.run("echo hello", session)

      assert_receive {:telemetry, [:bash, :session, :run, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.session == session

      assert_receive {:telemetry, [:bash, :session, :run, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.session == session
      assert metadata.status == :ok
      assert metadata.exit_code == 0
    end

    test "includes exit_code in stop metadata", %{session: session} do
      {:exit, _result, ^session} = Bash.run("exit 42", session)

      assert_receive {:telemetry, [:bash, :session, :run, :stop], _measurements, metadata}
      assert metadata.status == :exit
      assert metadata.exit_code == 42
    end

    test "includes error status for failed commands", %{session: session} do
      {:ok, _result, ^session} = Bash.run("false", session)

      assert_receive {:telemetry, [:bash, :session, :run, :stop], _measurements, metadata}
      assert metadata.status == :ok
      assert metadata.exit_code == 1
    end
  end

  describe "command telemetry" do
    test "emits start and stop events for commands", %{session: session} do
      run_script(session, "echo hello world")

      assert_receive {:telemetry, [:bash, :command, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.command == "echo"
      assert metadata.args == ["hello", "world"]

      assert_receive {:telemetry, [:bash, :command, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.command == "echo"
      assert metadata.args == ["hello", "world"]
      assert metadata.exit_code == 0
    end

    test "includes exit_code for failed commands", %{session: session} do
      run_script(session, "false")

      assert_receive {:telemetry, [:bash, :command, :stop], _measurements, metadata}
      assert metadata.command == "false"
      assert metadata.exit_code == 1
    end

    test "emits events for multiple sequential commands", %{session: session} do
      run_script(session, "echo hello; echo world")

      # Should get start/stop for both echo commands
      assert_receive {:telemetry, [:bash, :command, :start], _,
                      %{command: "echo", args: ["hello"]}}

      assert_receive {:telemetry, [:bash, :command, :stop], _,
                      %{command: "echo", args: ["hello"]}}

      assert_receive {:telemetry, [:bash, :command, :start], _,
                      %{command: "echo", args: ["world"]}}

      assert_receive {:telemetry, [:bash, :command, :stop], _,
                      %{command: "echo", args: ["world"]}}
    end
  end

  describe "for_loop telemetry" do
    test "emits start and stop events", %{session: session} do
      run_script(session, "for i in a b c; do echo $i; done")

      assert_receive {:telemetry, [:bash, :for_loop, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.variable == "i"
      assert metadata.item_count == 3

      assert_receive {:telemetry, [:bash, :for_loop, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.variable == "i"
      assert metadata.item_count == 3
      assert metadata.iteration_count == 3
      assert metadata.exit_code == 0
    end

    test "reports correct iteration_count when break is used", %{session: session} do
      run_script(session, "for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then break; fi; done")

      assert_receive {:telemetry, [:bash, :for_loop, :stop], _measurements, metadata}
      assert metadata.item_count == 5
      assert metadata.iteration_count == 3
    end

    test "handles empty item list", %{session: session} do
      run_script(session, ~s|for i in ; do echo $i; done|)

      assert_receive {:telemetry, [:bash, :for_loop, :start], _, %{item_count: 0}}
      assert_receive {:telemetry, [:bash, :for_loop, :stop], _, %{iteration_count: 0}}
    end
  end

  describe "while_loop telemetry" do
    test "emits start and stop events for while loop", %{session: session} do
      run_script(session, "i=0; while [ $i -lt 3 ]; do i=$((i+1)); done")

      assert_receive {:telemetry, [:bash, :while_loop, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.until == false

      assert_receive {:telemetry, [:bash, :while_loop, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.until == false
      assert metadata.iteration_count == 3
      assert metadata.exit_code == 0
    end

    test "emits events for until loop with until flag", %{session: session} do
      run_script(session, "i=0; until [ $i -ge 2 ]; do i=$((i+1)); done")

      assert_receive {:telemetry, [:bash, :while_loop, :start], _, %{until: true}}
      assert_receive {:telemetry, [:bash, :while_loop, :stop], _, metadata}
      assert metadata.until == true
      assert metadata.iteration_count == 2
    end

    test "reports correct iteration_count when break is used", %{session: session} do
      run_script(session, "i=0; while true; do i=$((i+1)); if [ $i -eq 5 ]; then break; fi; done")

      assert_receive {:telemetry, [:bash, :while_loop, :stop], _, metadata}
      assert metadata.iteration_count == 5
    end

    test "handles zero iterations", %{session: session} do
      run_script(session, "while false; do echo never; done")

      assert_receive {:telemetry, [:bash, :while_loop, :stop], _, %{iteration_count: 0}}
    end
  end

  describe "nested constructs" do
    test "emits events for nested loops", %{session: session} do
      run_script(session, """
      for i in 1 2; do
        for j in a b; do
          echo $i$j
        done
      done
      """)

      # Outer for loop start
      assert_receive {:telemetry, [:bash, :for_loop, :start], _, %{variable: "i", item_count: 2}}

      # First inner for loop
      assert_receive {:telemetry, [:bash, :for_loop, :start], _, %{variable: "j", item_count: 2}}
      # Commands inside inner loop
      assert_receive {:telemetry, [:bash, :command, :start], _, %{command: "echo"}}
      assert_receive {:telemetry, [:bash, :command, :stop], _, %{command: "echo"}}
      assert_receive {:telemetry, [:bash, :command, :start], _, %{command: "echo"}}
      assert_receive {:telemetry, [:bash, :command, :stop], _, %{command: "echo"}}

      assert_receive {:telemetry, [:bash, :for_loop, :stop], _,
                      %{variable: "j", iteration_count: 2}}

      # Second inner for loop
      assert_receive {:telemetry, [:bash, :for_loop, :start], _, %{variable: "j", item_count: 2}}
      assert_receive {:telemetry, [:bash, :command, :start], _, %{command: "echo"}}
      assert_receive {:telemetry, [:bash, :command, :stop], _, %{command: "echo"}}
      assert_receive {:telemetry, [:bash, :command, :start], _, %{command: "echo"}}
      assert_receive {:telemetry, [:bash, :command, :stop], _, %{command: "echo"}}

      assert_receive {:telemetry, [:bash, :for_loop, :stop], _,
                      %{variable: "j", iteration_count: 2}}

      # Outer for loop stop
      assert_receive {:telemetry, [:bash, :for_loop, :stop], _,
                      %{variable: "i", iteration_count: 2}}
    end
  end
end
