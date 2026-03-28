defmodule Bash.Spec.FuncTest do
  @moduledoc "Spec tests for shell functions from the Oils test suite."

  use Bash.SpecCase, file: "test/fixtures/sh-func.test.sh"
end
