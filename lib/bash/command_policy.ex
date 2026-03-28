defmodule Bash.CommandPolicy do
  @moduledoc """
  Policy engine for controlling command execution and (future) filesystem access.

  A `%CommandPolicy{}` struct is stored as a top-level field on `Bash.Session` state.
  It is immutable once the session is initialized — `set`, `shopt`, and other runtime
  mechanisms cannot modify it.

  ## Fields

    * `:commands` — gates command execution across all categories: builtins, externals,
      shell functions, and Elixir interop calls.

    * `:paths` — reserved for future filesystem path restrictions (not enforced yet).

    * `:files` — reserved for future file access restrictions (not enforced yet).

  ## Command Categories

  Every command resolved by the interpreter falls into one of four categories:

    * `:builtin` — built-in shell commands (`echo`, `cd`, `export`, etc.)
    * `:external` — external OS commands (`cat`, `grep`, `/usr/bin/sort`, etc.)
    * `:function` — user-defined shell functions
    * `:interop` — Elixir interop commands registered via `Bash.Interop`

  ## Command Policy Types

    * `:unrestricted` — all commands in all categories are allowed (default).
    * `:no_external` — block all external command execution; other categories allowed.
    * A list of rules — evaluated in order, first match wins.
    * A function `(String.t(), command_category() -> boolean())` — dynamic evaluation
      per command and category.
    * A function `(String.t() -> boolean())` — legacy dynamic evaluation, only applied
      to external commands.

  ## Rule Evaluation

  When `commands` is a list, each rule is tried in order:

    * `{:allow, items}` — if the command matches any item, it is **allowed**.
    * `{:disallow, items}` — if the command matches any item, it is **denied**.
    * `{:allow, :all}` — allows all commands unconditionally.
    * `{:disallow, :all}` — denies all commands unconditionally.
    * `fun/2` — receives `(name, category)`, if it returns `true`, the command is
      **allowed**; `false` continues to the next rule.
    * `fun/1` — legacy; only evaluated for `:external` commands, skipped for others.

  Items can be strings (exact or basename match), `Regex` patterns, or category atoms:

    * `:builtins` — matches all commands in the `:builtin` category
    * `:externals` — matches all commands in the `:external` category
    * `:functions` — matches all commands in the `:function` category
    * `:interop` — matches all commands in the `:interop` category

  If no rule matches, the command is **denied**.

  ## Common Recipes

  The table below shows how to set up policies for common scenarios. Categories
  not listed in an `{:allow, [...]}` rule are denied by default (fail-closed).

  | Goal                                  | Policy                                                            |
  |---------------------------------------|-------------------------------------------------------------------|
  | Allow everything (default)            | `commands: :unrestricted`                                         |
  | Block all externals                   | `commands: :no_external`                                          |
  | Builtins only                         | `commands: [{:allow, [:builtins]}]`                               |
  | Externals only                        | `commands: [{:allow, [:externals]}]`                              |
  | Builtins + functions                  | `commands: [{:allow, [:builtins, :functions]}]`                   |
  | Builtins + externals                  | `commands: [{:allow, [:builtins, :externals]}]`                   |
  | Builtins + interop                    | `commands: [{:allow, [:builtins, :interop]}]`                     |
  | Builtins + functions + interop        | `commands: [{:allow, [:builtins, :functions, :interop]}]`         |
  | Everything except externals           | `commands: [{:disallow, [:externals]}, {:allow, :all}]`           |
  | Everything except interop             | `commands: [{:disallow, [:interop]}, {:allow, :all}]`             |
  | Block specific builtins               | `commands: [{:disallow, ["eval", "source"]}, {:allow, :all}]`     |
  | Builtins + specific externals         | `commands: [{:allow, [:builtins, "cat", "grep"]}]`                |
  | Block everything                      | `commands: [{:disallow, :all}]`                                   |

  ## Examples

      # Block all external commands (shorthand)
      %CommandPolicy{commands: :no_external}

      # Allow only builtins and specific externals
      %CommandPolicy{commands: [{:allow, [:builtins, "cat", "grep"]}]}

      # Allow builtins and functions, block everything else
      %CommandPolicy{commands: [{:allow, [:builtins, :functions]}]}

      # Block eval and source, allow everything else
      %CommandPolicy{commands: [{:disallow, ["eval", "source"]}, {:allow, :all}]}

      # Regex-based rules
      %CommandPolicy{commands: [{:allow, [~r/^git-/]}]}

      # Category-aware function
      %CommandPolicy{commands: fn _cmd, cat -> cat in [:builtin, :function] end}
  """

  defstruct commands: :unrestricted,
            paths: nil,
            files: nil

  @type command_category :: :builtin | :external | :function | :interop

  @category_atoms [:builtins, :externals, :functions, :interop]

  @category_to_singular %{
    builtins: :builtin,
    externals: :external,
    functions: :function,
    interop: :interop
  }

  @type rule_item :: String.t() | Regex.t() | :builtins | :externals | :functions | :interop

  @type command_rule ::
          :unrestricted
          | :no_external
          | [
              {:allow, :all | [rule_item()]}
              | {:disallow, :all | [rule_item()]}
              | (String.t(), command_category() -> boolean())
              | (String.t() -> boolean())
            ]
          | (String.t(), command_category() -> boolean())
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
  into a `MapSet` (for O(1) string lookup), a list of non-string matchers
  (regex, functions), and a `MapSet` of category atoms.

      iex> CommandPolicy.new(commands: :no_external)
      %CommandPolicy{commands: :no_external}

      iex> CommandPolicy.new(commands: [{:allow, [:builtins, "cat", ~r/^git-/]}])
      # categories -> MapSet, strings -> MapSet, regex kept separately
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
  Checks whether the given command is allowed under the policy.

  The `category` argument identifies what kind of command is being checked:
  `:builtin`, `:external`, `:function`, or `:interop`. Defaults to `:external`
  for backwards compatibility.

  Returns `:ok` or `{:error, message}` with a descriptive error string.
  """
  @spec check_command(t(), String.t(), command_category()) :: :ok | {:error, String.t()}
  def check_command(policy, command_name, category \\ :external)

  def check_command(%__MODULE__{commands: :unrestricted}, _command_name, _category), do: :ok

  def check_command(%__MODULE__{commands: :no_external}, command_name, :external),
    do: {:error, "bash: #{command_name}: restricted"}

  def check_command(%__MODULE__{commands: :no_external}, _command_name, _category), do: :ok

  def check_command(%__MODULE__{commands: fun}, command_name, category)
      when is_function(fun, 2) do
    if fun.(command_name, category),
      do: :ok,
      else: {:error, "bash: #{command_name}: command not allowed"}
  end

  def check_command(%__MODULE__{commands: fun}, command_name, :external)
      when is_function(fun, 1) do
    if fun.(command_name),
      do: :ok,
      else: {:error, "bash: #{command_name}: command not allowed"}
  end

  def check_command(%__MODULE__{commands: fun}, _command_name, _category)
      when is_function(fun, 1),
      do: :ok

  def check_command(%__MODULE__{commands: rules}, command_name, category)
      when is_list(rules) do
    case evaluate_rules(rules, command_name, category) do
      :allow -> :ok
      :deny -> {:error, "bash: #{command_name}: command not allowed"}
    end
  end

  @doc """
  Returns `true` if the specific command is allowed under the policy.
  """
  @spec command_allowed?(t(), String.t(), command_category()) :: boolean()
  def command_allowed?(policy, command_name, category \\ :external),
    do: check_command(policy, command_name, category) == :ok

  @doc """
  Returns `true` if the policy allows any external commands at all.

  Used by pipeline optimization to decide if the streaming path is viable.
  """
  @spec allows_external?(t()) :: boolean()
  def allows_external?(%__MODULE__{commands: :unrestricted}), do: true
  def allows_external?(%__MODULE__{commands: :no_external}), do: false
  def allows_external?(%__MODULE__{}), do: true

  # -- Rule evaluation engine --

  defp evaluate_rules([], _value, _category), do: :deny

  defp evaluate_rules([{:allow, :all} | _rest], _value, _category), do: :allow

  defp evaluate_rules([{:disallow, :all} | _rest], _value, _category), do: :deny

  defp evaluate_rules([{:allow, items} | rest], value, category) do
    if match_any?(items, value, category),
      do: :allow,
      else: evaluate_rules(rest, value, category)
  end

  defp evaluate_rules([{:disallow, items} | rest], value, category) do
    if match_any?(items, value, category),
      do: :deny,
      else: evaluate_rules(rest, value, category)
  end

  defp evaluate_rules([fun | rest], value, category) when is_function(fun, 2) do
    if fun.(value, category), do: :allow, else: evaluate_rules(rest, value, category)
  end

  defp evaluate_rules([fun | rest], value, :external = category) when is_function(fun, 1) do
    if fun.(value), do: :allow, else: evaluate_rules(rest, value, category)
  end

  defp evaluate_rules([fun | rest], value, category) when is_function(fun, 1) do
    evaluate_rules(rest, value, category)
  end

  defp match_any?({strings, matchers, categories}, value, category) do
    base = Path.basename(value)

    MapSet.member?(categories, category) or
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
    {strings, non_strings} =
      Enum.split_with(items, fn
        item when is_binary(item) -> true
        _ -> false
      end)

    {category_atoms, matchers} =
      Enum.split_with(non_strings, fn
        item when item in @category_atoms -> true
        _ -> false
      end)

    categories = MapSet.new(category_atoms, &Map.fetch!(@category_to_singular, &1))

    {tag, {MapSet.new(strings), matchers, categories}}
  end

  defp normalize_rule(fun) when is_function(fun, 1), do: fun
  defp normalize_rule(fun) when is_function(fun, 2), do: fun
end
