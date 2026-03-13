defmodule Bash.ExternalProcess do
  @moduledoc """
  Centralized gateway for all user-facing OS process spawning.

  All external command execution flows through this module, enabling
  restricted mode enforcement at a single point. Internal plumbing
  (signal delivery, hostname lookup, named pipe creation) is exempt
  and continues to use `System.cmd` directly.

  ```mermaid
  graph TD
    CP[CommandPort] --> EP[ExternalProcess]
    JP[JobProcess] --> EP
    CO[Coproc] --> EP
    PL[Pipeline] --> EP
    CM[Command builtin] --> EP
    EP -->|restricted?| ERR["{:error, :restricted}"]
    EP -->|allowed| EX[ExCmd / System.cmd]
  ```
  """

  defguardp is_restricted(restricted) when restricted == true

  @doc """
  Returns whether restricted mode is active for the given session state.

  Safely traverses the nested options map, defaulting to `false` when keys
  are absent (e.g. bare state maps in tests).
  """
  @spec restricted?(map()) :: boolean()
  def restricted?(state), do: state |> Map.get(:options, %{}) |> Map.get(:restricted, false)

  @doc """
  Starts an OS process via `ExCmd.Process.start_link/2`.

  Returns `{:error, :restricted}` when restricted mode is active.
  """
  @spec start_link(list(String.t()), keyword(), boolean()) ::
          {:ok, pid()} | {:error, :restricted} | {:error, term()}
  def start_link(_cmd_parts, _opts, restricted) when is_restricted(restricted),
    do: {:error, :restricted}

  def start_link(cmd_parts, opts, _restricted),
    do: ExCmd.Process.start_link(cmd_parts, opts)

  @doc """
  Creates an OS process stream via `ExCmd.stream/2`.

  Returns `{:error, :restricted}` when restricted mode is active.
  """
  @spec stream(list(String.t()), keyword(), boolean()) ::
          Enumerable.t() | {:error, :restricted}
  def stream(_cmd_parts, _opts, restricted) when is_restricted(restricted),
    do: {:error, :restricted}

  def stream(cmd_parts, opts, _restricted),
    do: ExCmd.stream(cmd_parts, opts)

  @doc """
  Executes a command via `System.cmd/3`.

  Returns `{:error, :restricted}` when restricted mode is active.
  """
  @spec system_cmd(String.t(), list(String.t()), keyword(), boolean()) ::
          {String.t(), non_neg_integer()} | {:error, :restricted}
  def system_cmd(_path, _args, _opts, restricted) when is_restricted(restricted),
    do: {:error, :restricted}

  def system_cmd(path, args, opts, _restricted),
    do: System.cmd(path, args, opts)
end
