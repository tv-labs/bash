defmodule Bash.Telemetry do
  @moduledoc """
  Telemetry instrumentation for the Bash interpreter.

  This module emits telemetry events for script execution, allowing you to
  monitor performance, track usage, and integrate with observability tools.

  ## Available Events

  All events follow the span pattern with `:start`, `:stop`, and `:exception` suffixes.

  ### Session Execution

  * `[:bash, :session, :run, :start]` - Emitted when `Bash.run/3` begins execution
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{session: pid}`

  * `[:bash, :session, :run, :stop]` - Emitted when `Bash.run/3` completes
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{session: pid, status: :ok | :error | :exit | :exec, exit_code: integer | nil}`

  * `[:bash, :session, :run, :exception]` - Emitted when `Bash.run/3` raises an exception
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{session: pid, kind: :error | :exit | :throw, reason: term, stacktrace: list}`

  ### Command Execution

  * `[:bash, :command, :start]` - Emitted before a command executes
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{command: String.t, args: list(String.t)}`

  * `[:bash, :command, :stop]` - Emitted after a command completes
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{command: String.t, args: list(String.t), exit_code: integer | nil}`

  * `[:bash, :command, :exception]` - Emitted when a command raises an exception
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{command: String.t, args: list(String.t), kind: atom, reason: term, stacktrace: list}`

  ### For Loop Execution

  * `[:bash, :for_loop, :start]` - Emitted before a for loop begins
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{variable: String.t, item_count: integer}`

  * `[:bash, :for_loop, :stop]` - Emitted after a for loop completes
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{variable: String.t, item_count: integer, iteration_count: integer, exit_code: integer | nil}`

  * `[:bash, :for_loop, :exception]` - Emitted when a for loop raises an exception
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{variable: String.t, item_count: integer, kind: atom, reason: term, stacktrace: list}`

  ### While/Until Loop Execution

  * `[:bash, :while_loop, :start]` - Emitted before a while/until loop begins
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{until: boolean}`

  * `[:bash, :while_loop, :stop]` - Emitted after a while/until loop completes
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{until: boolean, iteration_count: integer, exit_code: integer | nil}`

  * `[:bash, :while_loop, :exception]` - Emitted when a while/until loop raises an exception
    * Measurement: `%{duration: native_time}`
    * Metadata: `%{until: boolean, kind: atom, reason: term, stacktrace: list}`

  ## Usage Example

  Attach handlers to receive telemetry events:

      :telemetry.attach_many(
        "bash-telemetry-handler",
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
        &MyApp.TelemetryHandler.handle_event/4,
        nil
      )

  ## Note on Output

  Output (stdout/stderr) is intentionally NOT included in telemetry metadata
  to avoid memory issues with large outputs. Use output collectors or sinks
  if you need to capture command output.
  """

  @doc """
  Execute a function with span telemetry for `Bash.run/3`.

  Emits:
  - `[:bash, :session, :run, :start]` before execution
  - `[:bash, :session, :run, :stop]` on successful completion
  - `[:bash, :session, :run, :exception]` if an exception is raised (then re-raises)
  """
  @spec span(pid(), (-> {term(), map()})) :: term()
  def span(session_pid, fun) when is_pid(session_pid) and is_function(fun, 0) do
    start_metadata = %{session: session_pid}
    do_span([:bash, :session, :run], start_metadata, fun)
  end

  @doc """
  Execute a command with span telemetry.

  Emits:
  - `[:bash, :command, :start]` before execution
  - `[:bash, :command, :stop]` on successful completion
  - `[:bash, :command, :exception]` if an exception is raised (then re-raises)
  """
  @spec command_span(String.t(), list(String.t()), (-> {term(), map()})) :: term()
  def command_span(command, args, fun)
      when is_binary(command) and is_list(args) and is_function(fun, 0) do
    start_metadata = %{command: command, args: args}
    do_span([:bash, :command], start_metadata, fun)
  end

  @doc """
  Execute a for loop with span telemetry.

  Emits:
  - `[:bash, :for_loop, :start]` before execution
  - `[:bash, :for_loop, :stop]` on successful completion
  - `[:bash, :for_loop, :exception]` if an exception is raised (then re-raises)
  """
  @spec for_loop_span(String.t() | nil, non_neg_integer(), (-> {term(), map()})) :: term()
  def for_loop_span(variable, item_count, fun)
      when (is_binary(variable) or is_nil(variable)) and is_integer(item_count) and
             is_function(fun, 0) do
    # C-style for loops may have nil variable name
    var_name = variable || "(c-style)"
    start_metadata = %{variable: var_name, item_count: item_count}
    do_span([:bash, :for_loop], start_metadata, fun)
  end

  @doc """
  Execute a while/until loop with span telemetry.

  Emits:
  - `[:bash, :while_loop, :start]` before execution
  - `[:bash, :while_loop, :stop]` on successful completion
  - `[:bash, :while_loop, :exception]` if an exception is raised (then re-raises)
  """
  @spec while_loop_span(boolean(), (-> {term(), map()})) :: term()
  def while_loop_span(until_mode, fun) when is_boolean(until_mode) and is_function(fun, 0) do
    start_metadata = %{until: until_mode}
    do_span([:bash, :while_loop], start_metadata, fun)
  end

  # Internal span implementation that manually emits start/stop/exception events
  defp do_span(event_prefix, start_metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: System.system_time()},
      start_metadata
    )

    try do
      {result, stop_metadata} = fun.()

      :telemetry.execute(
        event_prefix ++ [:stop],
        %{duration: System.monotonic_time() - start_time},
        Map.merge(start_metadata, stop_metadata)
      )

      result
    rescue
      e ->
        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(start_metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(start_metadata, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end
