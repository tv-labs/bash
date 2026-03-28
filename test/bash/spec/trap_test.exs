defmodule Bash.Spec.TrapTest do
  @moduledoc "Spec tests for trap builtin from the Oils test suite."

  # Excluded by default: trap spec tests send real signals (SIGUSR1, SIGINT)
  # which crash the BEAM VM. Run explicitly with: mix test --include trap_spec
  use Bash.SpecCase, file: "test/fixtures/builtin-trap.test.sh", moduletag: :trap_spec
end
