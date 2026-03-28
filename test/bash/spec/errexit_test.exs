defmodule Bash.Spec.ErrexitTest do
  @moduledoc "Spec tests for errexit (set -e) from the Oils test suite."

  use Bash.SpecCase, file: "test/fixtures/errexit.test.sh"
end
