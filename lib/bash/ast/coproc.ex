defmodule Bash.AST.Coproc do
  @moduledoc """
  Coproc AST node.

  Represents `coproc [NAME] command` where command can be simple or compound.

  When a NAME is provided (only valid with compound commands in real bash),
  the coproc array variable and PID variable use that name. Otherwise,
  the default name "COPROC" is used.

  Simple commands are executed via `ExCmd.Process` (external OS process).
  Compound commands are executed within the Elixir bash interpreter in a
  spawned BEAM process with message-passing I/O.

  ## Examples

      # coproc cat
      %Coproc{body: %Command{name: "cat"}}

      # coproc MYPROC { cat; }
      %Coproc{name: "MYPROC", body: %Compound{kind: :group, ...}}
  """

  alias Bash.AST
  alias Bash.Builtin.Coproc, as: CoprocBuiltin

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          name: String.t(),
          body: Bash.Statement.t(),
          exit_code: 0..255 | nil,
          state_updates: map()
        }

  defstruct [
    :meta,
    :body,
    name: "COPROC",
    exit_code: nil,
    state_updates: %{}
  ]

  def execute(%__MODULE__{name: name, body: %AST.Command{} = cmd} = ast, _stdin, session_state) do
    cmd_name = AST.Helpers.word_to_string(cmd.name, session_state)
    cmd_args = Enum.map(cmd.args, &AST.Helpers.word_to_string(&1, session_state))

    case CoprocBuiltin.start_external_coproc(name, cmd_name, cmd_args, session_state) do
      {:ok, updates} ->
        {:ok, %{ast | exit_code: 0, state_updates: updates}, updates}

      {:error, exit_code} ->
        {:ok, %{ast | exit_code: exit_code}, %{}}
    end
  end

  def execute(%__MODULE__{name: name, body: body} = ast, _stdin, session_state) do
    case CoprocBuiltin.start_internal_coproc(name, body, session_state) do
      {:ok, updates} ->
        {:ok, %{ast | exit_code: 0, state_updates: updates}, updates}

      {:error, exit_code} ->
        {:ok, %{ast | exit_code: exit_code}, %{}}
    end
  end

  defimpl String.Chars do
    def to_string(%{name: "COPROC", body: body}), do: "coproc #{body}"
    def to_string(%{name: name, body: body}), do: "coproc #{name} #{body}"
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{name: name, exit_code: exit_code}, opts) do
      base = concat(["#Coproc{", color(name, :string, opts), "}"])

      if exit_code do
        concat([base, " => ", color("#{exit_code}", :number, opts)])
      else
        base
      end
    end
  end
end
