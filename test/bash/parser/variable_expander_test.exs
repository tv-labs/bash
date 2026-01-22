defmodule Bash.Parser.VariableExpanderTest do
  use ExUnit.Case

  alias Bash.Parser.VariableExpander
  alias Bash.Variable

  setup do
    session_state = %{
      variables: %{
        "FOO" => Variable.new("bar"),
        "EMPTY" => Variable.new(""),
        "PATH" => Variable.new("/usr/bin:/usr/local/bin"),
        "FILENAME" => Variable.new("test.txt.backup"),
        "VERSION" => Variable.new("1.2.3")
      }
    }

    {:ok, session_state: session_state}
  end

  describe "Simple variable expansion" do
    test "expands simple $VAR", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("$FOO", session_state)
      assert result == "bar"
    end

    test "expands ${VAR}", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO}", session_state)
      assert result == "bar"
    end

    test "returns empty string for unset variable", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("$UNSET", session_state)
      assert result == ""
    end
  end

  describe "${var:-default} - Use default value" do
    test "uses default when variable is unset", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${UNSET:-default}", session_state)

      assert result == "default"
    end

    test "uses default when variable is empty", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${EMPTY:-default}", session_state)

      assert result == "default"
    end

    test "uses variable value when set and not empty", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO:-default}", session_state)
      assert result == "bar"
    end

    test "handles empty default value", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${UNSET:-}", session_state)
      assert result == ""
    end
  end

  describe "${var:=default} - Assign default value" do
    test "returns default when variable is unset", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${UNSET:=default}", session_state)

      assert result == "default"
    end

    test "returns default when variable is empty", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${EMPTY:=default}", session_state)

      assert result == "default"
    end

    test "uses variable value when set and not empty", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO:=default}", session_state)
      assert result == "bar"
    end

    test "returns env_updates when variable is unset", %{session_state: session_state} do
      {result, env_updates} =
        VariableExpander.expand_variables("${UNSET:=myvalue}", session_state)

      assert result == "myvalue"
      assert env_updates == %{"UNSET" => "myvalue"}
    end

    test "returns env_updates when variable is empty", %{session_state: session_state} do
      {result, env_updates} =
        VariableExpander.expand_variables("${EMPTY:=newvalue}", session_state)

      assert result == "newvalue"
      assert env_updates == %{"EMPTY" => "newvalue"}
    end

    test "returns empty env_updates when variable is already set", %{session_state: session_state} do
      {result, env_updates} = VariableExpander.expand_variables("${FOO:=ignored}", session_state)
      assert result == "bar"
      assert env_updates == %{}
    end

    test "accumulates multiple assignments", %{session_state: session_state} do
      # Test that multiple :=  operators in one expansion accumulate updates
      {result, env_updates} =
        VariableExpander.expand_variables("${VAR1:=val1}-${VAR2:=val2}", session_state)

      assert result == "val1-val2"
      assert env_updates == %{"VAR1" => "val1", "VAR2" => "val2"}
    end
  end

  describe "${var:?error} - Error if unset or null" do
    test "raises error when variable is unset" do
      session_state = %{variables: %{}}

      assert_raise RuntimeError, ~r/bash: UNSET: custom error/, fn ->
        VariableExpander.expand_variables("${UNSET:?custom error}", session_state)
      end
    end

    test "raises error with default message when no error text provided" do
      session_state = %{variables: %{}}

      assert_raise RuntimeError, ~r/bash: UNSET: parameter null or not set/, fn ->
        VariableExpander.expand_variables("${UNSET:?}", session_state)
      end
    end

    test "returns value when variable is set and not empty", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO:?error}", session_state)
      assert result == "bar"
    end
  end

  describe "${var:+alternate} - Use alternate if set" do
    test "returns empty string when variable is unset", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${UNSET:+alternate}", session_state)

      assert result == ""
    end

    test "returns empty string when variable is empty", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${EMPTY:+alternate}", session_state)

      assert result == ""
    end

    test "returns alternate when variable is set and not empty", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("${FOO:+alternate}", session_state)

      assert result == "alternate"
    end
  end

  describe "${#var} - String length" do
    test "returns length of variable value", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${#FOO}", session_state)
      assert result == "3"
    end

    test "returns 0 for empty variable", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${#EMPTY}", session_state)
      assert result == "0"
    end

    test "returns 0 for unset variable", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${#UNSET}", session_state)
      assert result == "0"
    end

    test "returns correct length for longer strings", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${#PATH}", session_state)
      assert result == "23"
    end
  end

  describe "${var:offset:length} - Substring expansion" do
    test "extracts substring from offset to end", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${VERSION:2}", session_state)
      assert result == "2.3"
    end

    test "extracts substring with length", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${VERSION:0:3}", session_state)
      assert result == "1.2"
    end

    test "handles offset at start", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO:0:2}", session_state)
      assert result == "ba"
    end

    test "returns empty for offset beyond string length", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO:10}", session_state)
      assert result == ""
    end
  end

  describe "${var#pattern} - Remove shortest match from beginning" do
    test "removes shortest prefix match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FILENAME#*.}", session_state)
      assert result == "txt.backup"
    end

    test "returns original string when no match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO#xyz}", session_state)
      assert result == "bar"
    end
  end

  describe "${var##pattern} - Remove longest match from beginning" do
    test "removes longest prefix match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FILENAME##*.}", session_state)
      assert result == "backup"
    end

    test "returns original string when no match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO##xyz}", session_state)
      assert result == "bar"
    end
  end

  describe "${var%pattern} - Remove shortest match from end" do
    test "removes shortest suffix match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FILENAME%.*}", session_state)
      assert result == "test.txt"
    end

    test "returns original string when no match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO%xyz}", session_state)
      assert result == "bar"
    end
  end

  describe "${var%%pattern} - Remove longest match from end" do
    test "removes longest suffix match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FILENAME%%.*}", session_state)
      assert result == "test"
    end

    test "returns original string when no match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO%%xyz}", session_state)
      assert result == "bar"
    end
  end

  describe "${var/pattern/replacement} - Pattern substitution (first match)" do
    test "replaces first occurrence", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${PATH/:/;}", session_state)
      assert result == "/usr/bin;/usr/local/bin"
    end

    test "returns original string when no match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO/xyz/abc}", session_state)
      assert result == "bar"
    end

    test "removes pattern when replacement is empty", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO/a/}", session_state)
      assert result == "br"
    end
  end

  describe "${var//pattern/replacement} - Pattern substitution (all matches)" do
    test "replaces all occurrences", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${PATH//:/ }", session_state)
      assert result == "/usr/bin /usr/local/bin"
    end

    test "returns original string when no match", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("${FOO//xyz/abc}", session_state)
      assert result == "bar"
    end

    test "removes all pattern occurrences when replacement is empty", %{
      session_state: session_state
    } do
      {result, _env_updates} = VariableExpander.expand_variables("${VERSION//./}", session_state)
      assert result == "123"
    end
  end

  describe "Complex expansions" do
    test "works within quoted strings from BashParser tokens", %{session_state: session_state} do
      # Simulate tokens from BashParser
      tokens = ["Hello ", {:var_ref_braced, [var_name: "FOO", default_op: ":-", word: "default"]}]
      {result, _env_updates} = VariableExpander.expand_variables(tokens, session_state)
      assert result == "Hello bar"
    end

    test "handles multiple expansions in text", %{session_state: session_state} do
      {result, _env_updates} = VariableExpander.expand_variables("$FOO-${VERSION}", session_state)
      assert result == "bar-1.2.3"
    end

    test "handles expansion with literals", %{session_state: session_state} do
      {result, _env_updates} =
        VariableExpander.expand_variables("prefix-${FOO:-default}-suffix", session_state)

      assert result == "prefix-bar-suffix"
    end
  end

  describe "Bash integration tests" do
    test "default value operator matches bash behavior" do
      # Test with set variable
      bash_result = run_bash("FOO=bar; echo ${FOO:-default}")
      our_result = with_vars(%{"FOO" => "bar"}, "${FOO:-default}")
      assert our_result == bash_result

      # Test with unset variable
      bash_result = run_bash("echo ${UNSET:-default}")
      our_result = with_vars(%{}, "${UNSET:-default}")
      assert our_result == bash_result

      # Test with empty variable
      bash_result = run_bash("EMPTY=''; echo ${EMPTY:-default}")
      our_result = with_vars(%{"EMPTY" => ""}, "${EMPTY:-default}")
      assert our_result == bash_result
    end

    test "alternate value operator matches bash behavior" do
      # Test with set variable
      bash_result = run_bash("FOO=bar; echo ${FOO:+alternate}")
      our_result = with_vars(%{"FOO" => "bar"}, "${FOO:+alternate}")
      assert our_result == bash_result

      # Test with unset variable
      bash_result = run_bash("echo ${UNSET:+alternate}")
      our_result = with_vars(%{}, "${UNSET:+alternate}")
      assert our_result == bash_result
    end

    test "string length operator matches bash behavior" do
      bash_result = run_bash("FOO=hello; echo ${#FOO}")
      our_result = with_vars(%{"FOO" => "hello"}, "${#FOO}")
      assert our_result == bash_result

      bash_result = run_bash("echo ${#UNSET}")
      our_result = with_vars(%{}, "${#UNSET}")
      assert our_result == bash_result
    end

    test "substring operator matches bash behavior" do
      bash_result = run_bash("VERSION=1.2.3; echo ${VERSION:2}")
      our_result = with_vars(%{"VERSION" => "1.2.3"}, "${VERSION:2}")
      assert our_result == bash_result

      bash_result = run_bash("VERSION=1.2.3; echo ${VERSION:0:3}")
      our_result = with_vars(%{"VERSION" => "1.2.3"}, "${VERSION:0:3}")
      assert our_result == bash_result
    end

    test "prefix removal matches bash behavior" do
      bash_result = run_bash("FILENAME=test.txt.backup; echo ${FILENAME#*.}")
      our_result = with_vars(%{"FILENAME" => "test.txt.backup"}, "${FILENAME#*.}")
      assert our_result == bash_result

      bash_result = run_bash("FILENAME=test.txt.backup; echo ${FILENAME##*.}")
      our_result = with_vars(%{"FILENAME" => "test.txt.backup"}, "${FILENAME##*.}")
      assert our_result == bash_result
    end

    test "suffix removal matches bash behavior" do
      bash_result = run_bash("FILENAME=test.txt.backup; echo ${FILENAME%.*}")
      our_result = with_vars(%{"FILENAME" => "test.txt.backup"}, "${FILENAME%.*}")
      assert our_result == bash_result

      bash_result = run_bash("FILENAME=test.txt.backup; echo ${FILENAME%%.*}")
      our_result = with_vars(%{"FILENAME" => "test.txt.backup"}, "${FILENAME%%.*}")
      assert our_result == bash_result
    end

    test "pattern substitution matches bash behavior" do
      bash_result = run_bash("PATH=/usr/bin:/usr/local/bin; echo ${PATH/:/;}")
      our_result = with_vars(%{"PATH" => "/usr/bin:/usr/local/bin"}, "${PATH/:/;}")
      assert our_result == bash_result

      bash_result = run_bash("PATH=/usr/bin:/usr/local/bin; echo ${PATH//:/ }")
      our_result = with_vars(%{"PATH" => "/usr/bin:/usr/local/bin"}, "${PATH//:/ }")
      assert our_result == bash_result
    end
  end

  # Helper: Run bash command and return output
  defp run_bash(command) do
    {output, 0} = System.cmd("bash", ["-c", command])
    String.trim(output)
  end

  # Helper: Expand variables with given env vars
  # Returns just the expanded value (not the env_updates)
  defp with_vars(env_vars, expansion) do
    variables = Map.new(env_vars, fn {k, v} -> {k, Variable.new(v)} end)
    session_state = %{variables: variables}
    {result, _env_updates} = VariableExpander.expand_variables(expansion, session_state)
    result
  end
end
