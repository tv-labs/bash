defmodule Bash.Spec.EvalSourceTest do
  @moduledoc "Spec tests for eval and source builtins from the Oils test suite."

  use Bash.SpecCase, file: "test/fixtures/builtin-eval-source.test.sh"
end
