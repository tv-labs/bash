defmodule Bash.SessionSupervisor do
  @moduledoc false
  # DynamicSupervisor for managing Bash execution sessions.
  #
  # This supervisor manages the lifecycle of session processes, allowing
  # for dynamic creation and termination of sessions as needed.

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
