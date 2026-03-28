defmodule Bash.Spec.EchoTest do
  @moduledoc "Spec tests for echo builtin from the Oils test suite."

  use Bash.SpecCase, file: "test/fixtures/builtin-echo.test.sh"
end
