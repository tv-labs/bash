defmodule Bash.CommandPolicy do
  @moduledoc """
  Policy engine for controlling command execution and (future) filesystem access.

  A `%CommandPolicy{}` struct is stored as a top-level field on `Bash.Session` state.
  It is immutable once the session is initialized — `set`, `shopt`, and other runtime
  mechanisms cannot modify it.

  ## Fields

    * `:commands` — gates external (OS) command execution. Builtins, shell functions,
      and Elixir interop calls are never restricted.

    * `:paths` — reserved for future filesystem path restrictions (not enforced yet).

    * `:files` — reserved for future file access restrictions (not enforced yet).

  ## Command Policy Types

    * `:unrestricted` — all external commands are allowed (default).
    * `:no_external` — block all external command execution.
    * A list of rules — evaluated in order, first match wins.
    * A function `(String.t() -> boolean())` — dynamic evaluation per command.

  ## Rule Evaluation

  When `commands` is a list, each rule is tried in order:

    * `{:allow, items}` — if the command matches any item, it is **allowed**.
    * `{:disallow, items}` — if the command matches any item, it is **denied**.
    * `fun/1` — if the function returns `true`, the command is **allowed**;
      `false` continues to the next rule.

  Items can be strings (exact match or basename match) or `Regex` patterns.
  If no rule matches, the command is **denied**.

  ## Examples

      # Block all external commands
      %CommandPolicy{commands: :no_external}

      # Allow only specific commands
      %CommandPolicy{commands: [{:allow, ["cat", "grep", "sort"]}]}

      # Deny specific dangerous commands, allow everything else
      %CommandPolicy{commands: [{:disallow, ["rm", "dd"]}, {:allow, :all}]}

      # Regex-based rules
      %CommandPolicy{commands: [{:allow, [~r/^git-/]}]}

      # Function-based rules
      %CommandPolicy{commands: fn cmd -> String.starts_with?(cmd, "safe-") end}
  """

  defstruct commands: :unrestricted,
            paths: nil,
            files: nil

  @type rule_item :: String.t() | Regex.t()

  @type command_rule ::
          :unrestricted
          | :no_external
          | [
              {:allow, :all | [rule_item()]}
              | {:disallow, [rule_item()]}
              | (String.t() -> boolean())
            ]
          | (String.t() -> boolean())

  @type path_rule ::
          nil
          | [
              {:allow, :all | [rule_item()]}
              | {:disallow, [rule_item()]}
              | (String.t() -> boolean())
            ]
          | (String.t() -> boolean())

  @type t :: %__MODULE__{
          commands: command_rule(),
          paths: path_rule(),
          files: path_rule()
        }

  @doc """
  Builds a `%CommandPolicy{}` from a keyword list, map, or existing struct.

  String lists inside `{:allow, list}` and `{:disallow, list}` are partitioned
  into a `MapSet` (for O(1) string lookup) and a list of non-string matchers
  (regex, functions).

      iex> CommandPolicy.new(commands: :no_external)
      %CommandPolicy{commands: :no_external}

      iex> CommandPolicy.new(commands: [{:allow, ["cat", ~r/^git-/]}])
      # strings -> MapSet, regex kept separately
  """
  @spec new(keyword() | map() | t()) :: t()
  def new(%__MODULE__{} = policy), do: finalize(policy)
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts) |> finalize()
  def new(opts) when is_map(opts), do: struct!(__MODULE__, Map.to_list(opts)) |> finalize()

  @doc """
  Extracts the command policy from session state.

  Returns the default (unrestricted) policy when none is configured.
  """
  @spec from_state(map()) :: t()
  def from_state(%{command_policy: %__MODULE__{} = policy}), do: policy
  def from_state(_), do: %__MODULE__{}

  @doc """
  Checks whether the given external command is allowed under the policy.

  Returns `:ok` or `{:error, message}` with a descriptive error string.
  """
  @spec check_command(t(), String.t()) :: :ok | {:error, String.t()}
  def check_command(%__MODULE__{commands: :unrestricted}, _command_name), do: :ok

  def check_command(%__MODULE__{commands: :no_external}, command_name),
    do: {:error, "bash: #{command_name}: restricted"}

  def check_command(%__MODULE__{commands: fun}, command_name) when is_function(fun, 1) do
    if fun.(command_name),
      do: :ok,
      else: {:error, "bash: #{command_name}: command not allowed"}
  end

  def check_command(%__MODULE__{commands: rules}, command_name) when is_list(rules) do
    case evaluate_rules(rules, command_name) do
      :allow -> :ok
      :deny -> {:error, "bash: #{command_name}: command not allowed"}
    end
  end

  @doc """
  Returns `true` if the specific command is allowed under the policy.
  """
  @spec command_allowed?(t(), String.t()) :: boolean()
  def command_allowed?(policy, command_name), do: check_command(policy, command_name) == :ok

  @doc """
  Returns `true` if the policy allows any external commands at all.

  Used by pipeline optimization to decide if the streaming path is viable.
  """
  @spec allows_external?(t()) :: boolean()
  def allows_external?(%__MODULE__{commands: :unrestricted}), do: true
  def allows_external?(%__MODULE__{commands: :no_external}), do: false
  def allows_external?(%__MODULE__{}), do: true

  # -- Rule evaluation engine --

  defp evaluate_rules([], _value), do: :deny

  defp evaluate_rules([{:allow, :all} | _rest], _value), do: :allow

  defp evaluate_rules([{:allow, items} | rest], value) do
    if match_any?(items, value), do: :allow, else: evaluate_rules(rest, value)
  end

  defp evaluate_rules([{:disallow, items} | rest], value) do
    if match_any?(items, value), do: :deny, else: evaluate_rules(rest, value)
  end

  defp evaluate_rules([fun | rest], value) when is_function(fun, 1) do
    if fun.(value), do: :allow, else: evaluate_rules(rest, value)
  end

  defp match_any?({strings, matchers}, value) do
    base = Path.basename(value)

    MapSet.member?(strings, value) or MapSet.member?(strings, base) or
      Enum.any?(matchers, &match_item?(&1, value))
  end

  defp match_item?(%Regex{} = regex, value), do: Regex.match?(regex, value)
  defp match_item?(fun, value) when is_function(fun, 1), do: fun.(value)

  # -- Normalization --

  defp finalize(%__MODULE__{commands: rules} = policy) when is_list(rules) do
    %{policy | commands: Enum.map(rules, &normalize_rule/1)}
  end

  defp finalize(policy), do: policy

  defp normalize_rule({tag, :all}) when tag in [:allow, :disallow], do: {tag, :all}

  defp normalize_rule({tag, items}) when tag in [:allow, :disallow] and is_list(items) do
    {strings, matchers} =
      Enum.split_with(items, fn
        item when is_binary(item) -> true
        _ -> false
      end)

    {tag, {MapSet.new(strings), matchers}}
  end

  defp normalize_rule(fun) when is_function(fun, 1), do: fun
end
