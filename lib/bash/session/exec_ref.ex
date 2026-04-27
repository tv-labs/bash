defmodule Bash.Session.ExecRef do
  @moduledoc """
  Opaque handle to an in-flight execution.

  Returned by `Bash.Session.execute_async/3` and accepted by
  `Bash.Session.await/2` and `Bash.Session.signal/2`.

  The caller holds `:monitor` so `await/2` can detect a session crash
  without a round-trip through the GenServer.
  """

  @enforce_keys [:session, :ref, :monitor]
  defstruct [:session, :ref, :monitor]

  @type t :: %__MODULE__{
          session: pid(),
          ref: reference(),
          monitor: reference()
        }
end
