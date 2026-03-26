defmodule Bash.CommandPolicy do
  @moduledoc """
  Command execution policy for restricting external command access.

  Policies control which external (OS) commands a session is allowed to execute.
  Builtins, shell functions, and Elixir interop calls are never restricted by
  command policy -- they always execute regardless of the active policy.

  ## Policy Types

    * `:unrestricted` -- No restrictions. All external commands are allowed.
    * `:disallow_external` -- Block all external command execution.
    * `{:allow, commands}` -- Only allow external commands in the given `MapSet`.

  ## Immutability

  Once set during session initialization, the command policy cannot be changed
  by `set`, `shopt`, or any other runtime mechanism.
  """

  @type t ::
          :unrestricted
          | :disallow_external
          | {:allow, MapSet.t(String.t())}

  @doc """
  Extracts the command policy from session state options.

  Returns `:unrestricted` when no policy is configured.
  """
  @spec from_state(map()) :: t()
  def from_state(%{options: %{command_policy: policy}}), do: policy
  def from_state(_), do: :unrestricted

  @doc """
  Checks whether the given external command name is allowed under the policy.

  Returns `:ok` or `{:error, message}` with a descriptive error string.
  """
  @spec check(t(), String.t()) :: :ok | {:error, String.t()}
  def check(:unrestricted, _command_name), do: :ok

  def check(:disallow_external, command_name),
    do: {:error, "bash: #{command_name}: restricted"}

  def check({:allow, allowed}, command_name) do
    base = Path.basename(command_name)

    if MapSet.member?(allowed, command_name) or MapSet.member?(allowed, base) do
      :ok
    else
      {:error, "bash: #{command_name}: command not allowed"}
    end
  end

  @doc """
  Returns true if the policy allows any external commands at all.

  Used by pipeline optimization to decide if the streaming path is viable.
  """
  @spec allows_external?(t()) :: boolean()
  def allows_external?(:unrestricted), do: true
  def allows_external?(:disallow_external), do: false
  def allows_external?({:allow, _}), do: true

  @doc """
  Returns true if the specific command is allowed under the policy.
  """
  @spec allowed?(t(), String.t()) :: boolean()
  def allowed?(policy, command_name), do: check(policy, command_name) == :ok

  @doc """
  Normalizes legacy `restricted: true` option into `command_policy: :disallow_external`.

  Called during session initialization to support backwards compatibility.
  """
  @spec normalize_options(map()) :: map()
  def normalize_options(%{restricted: true} = options) do
    options
    |> Map.delete(:restricted)
    |> Map.put_new(:command_policy, :disallow_external)
  end

  def normalize_options(options), do: options
end
