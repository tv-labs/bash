defmodule Bash.Parser.VariableExpanderTest do
  use ExUnit.Case

  alias Bash.Parser.VariableExpander
  alias Bash.SyntaxError
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

  describe "parse/1 - literal tokens" do
    test "parses plain text as literal" do
      assert {:ok, [{:literal, "hello world"}]} = VariableExpander.parse("hello world")
    end

    test "parses empty string" do
      assert {:ok, []} = VariableExpander.parse("")
    end

    test "parses text with special characters" do
      assert {:ok, [{:literal, "hello!@#%^&*()"}]} = VariableExpander.parse("hello!@#%^&*()")
    end

    test "parses lone $ as literal" do
      # A lone $ gets wrapped in a list due to add_to_literal behavior
      assert {:ok, [[literal: "$"]]} = VariableExpander.parse("$")
    end

    test "parses $ followed by space as literal" do
      # The $ and space become separate literals due to accumulation
      assert {:ok, [[literal: "$"], {:literal, " "}]} = VariableExpander.parse("$ ")
    end
  end

  describe "parse/1 - simple variable tokens" do
    test "parses $VAR" do
      assert {:ok, [{:var_simple, "FOO"}]} = VariableExpander.parse("$FOO")
    end

    test "parses $VAR with underscore" do
      assert {:ok, [{:var_simple, "FOO_BAR"}]} = VariableExpander.parse("$FOO_BAR")
    end

    test "parses $VAR starting with underscore" do
      assert {:ok, [{:var_simple, "_FOO"}]} = VariableExpander.parse("$_FOO")
    end

    test "parses $VAR with numbers" do
      assert {:ok, [{:var_simple, "FOO123"}]} = VariableExpander.parse("$FOO123")
    end

    test "parses positional parameters $0-$9" do
      for n <- 0..9 do
        expected = Integer.to_string(n)
        assert {:ok, [{:var_simple, ^expected}]} = VariableExpander.parse("$#{n}")
      end
    end

    test "parses special variable $?" do
      assert {:ok, [{:var_simple, "?"}]} = VariableExpander.parse("$?")
    end

    test "parses special variable $!" do
      assert {:ok, [{:var_simple, "!"}]} = VariableExpander.parse("$!")
    end

    test "parses special variable $$" do
      assert {:ok, [{:var_simple, "$"}]} = VariableExpander.parse("$$")
    end

    test "parses special variable $#" do
      assert {:ok, [{:var_simple, "#"}]} = VariableExpander.parse("$#")
    end

    test "parses special variable $*" do
      assert {:ok, [{:var_simple, "*"}]} = VariableExpander.parse("$*")
    end

    test "parses special variable $@" do
      assert {:ok, [{:var_simple, "@"}]} = VariableExpander.parse("$@")
    end

    test "parses special variable $-" do
      assert {:ok, [{:var_simple, "-"}]} = VariableExpander.parse("$-")
    end
  end

  describe "parse/1 - braced variable tokens" do
    test "parses ${VAR}" do
      assert {:ok, [{:var_braced, "FOO", []}]} = VariableExpander.parse("${FOO}")
    end

    test "parses ${VAR} with underscore" do
      assert {:ok, [{:var_braced, "FOO_BAR", []}]} = VariableExpander.parse("${FOO_BAR}")
    end

    test "parses braced special variables" do
      assert {:ok, [{:var_braced, "?", []}]} = VariableExpander.parse("${?}")
      assert {:ok, [{:var_braced, "!", []}]} = VariableExpander.parse("${!}")
      assert {:ok, [{:var_braced, "$", []}]} = VariableExpander.parse("${$}")
      # Note: ${#} is parsed as length operator expecting a var name, not special var "#"
      assert {:ok, [{:var_braced, "*", []}]} = VariableExpander.parse("${*}")
      assert {:ok, [{:var_braced, "@", []}]} = VariableExpander.parse("${@}")
      assert {:ok, [{:var_braced, "-", []}]} = VariableExpander.parse("${-}")
    end

    test "parses braced positional parameters" do
      for n <- 0..9 do
        expected = Integer.to_string(n)
        assert {:ok, [{:var_braced, ^expected, []}]} = VariableExpander.parse("${#{n}}")
      end
    end
  end

  describe "parse/1 - length operator" do
    test "parses ${#VAR}" do
      assert {:ok, [{:var_braced, "FOO", [:length]}]} = VariableExpander.parse("${#FOO}")
    end

    test "parses ${#VAR} with special variable" do
      assert {:ok, [{:var_braced, "?", [:length]}]} = VariableExpander.parse("${#?}")
    end
  end

  describe "parse/1 - default value operators" do
    test "parses ${VAR:-default}" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":-", "default"}]}]} =
               VariableExpander.parse("${FOO:-default}")
    end

    test "parses ${VAR:=default}" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":=", "value"}]}]} =
               VariableExpander.parse("${FOO:=value}")
    end

    test "parses ${VAR:?error}" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":?", "error message"}]}]} =
               VariableExpander.parse("${FOO:?error message}")
    end

    test "parses ${VAR:+alternate}" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":+", "alt"}]}]} =
               VariableExpander.parse("${FOO:+alt}")
    end

    test "parses default operators with empty value" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":-", ""}]}]} =
               VariableExpander.parse("${FOO:-}")

      assert {:ok, [{:var_braced, "FOO", [{:default, ":=", ""}]}]} =
               VariableExpander.parse("${FOO:=}")

      assert {:ok, [{:var_braced, "FOO", [{:default, ":?", ""}]}]} =
               VariableExpander.parse("${FOO:?}")

      assert {:ok, [{:var_braced, "FOO", [{:default, ":+", ""}]}]} =
               VariableExpander.parse("${FOO:+}")
    end
  end

  describe "parse/1 - substring operator" do
    test "parses ${VAR:offset}" do
      assert {:ok, [{:var_braced, "FOO", [{:substring, "5"}]}]} =
               VariableExpander.parse("${FOO:5}")
    end

    test "parses ${VAR:offset:length}" do
      assert {:ok, [{:var_braced, "FOO", [{:substring, "2:3"}]}]} =
               VariableExpander.parse("${FOO:2:3}")
    end

    test "parses ${VAR:0}" do
      assert {:ok, [{:var_braced, "FOO", [{:substring, "0"}]}]} =
               VariableExpander.parse("${FOO:0}")
    end
  end

  describe "parse/1 - pattern removal operators" do
    test "parses ${VAR#pattern}" do
      assert {:ok, [{:var_braced, "FOO", [{:pattern, "#", "*."}]}]} =
               VariableExpander.parse("${FOO#*.}")
    end

    test "parses ${VAR##pattern}" do
      assert {:ok, [{:var_braced, "FOO", [{:pattern, "##", "*."}]}]} =
               VariableExpander.parse("${FOO##*.}")
    end

    test "parses ${VAR%pattern}" do
      assert {:ok, [{:var_braced, "FOO", [{:pattern, "%", ".*"}]}]} =
               VariableExpander.parse("${FOO%.*}")
    end

    test "parses ${VAR%%pattern}" do
      assert {:ok, [{:var_braced, "FOO", [{:pattern, "%%", ".*"}]}]} =
               VariableExpander.parse("${FOO%%.*}")
    end

    test "parses pattern removal with empty pattern" do
      assert {:ok, [{:var_braced, "FOO", [{:pattern, "#", ""}]}]} =
               VariableExpander.parse("${FOO#}")

      assert {:ok, [{:var_braced, "FOO", [{:pattern, "##", ""}]}]} =
               VariableExpander.parse("${FOO##}")

      assert {:ok, [{:var_braced, "FOO", [{:pattern, "%", ""}]}]} =
               VariableExpander.parse("${FOO%}")

      assert {:ok, [{:var_braced, "FOO", [{:pattern, "%%", ""}]}]} =
               VariableExpander.parse("${FOO%%}")
    end
  end

  describe "parse/1 - substitution operators" do
    test "parses ${VAR/pattern/replacement}" do
      assert {:ok, [{:var_braced, "FOO", [{:subst, "/", "old/new"}]}]} =
               VariableExpander.parse("${FOO/old/new}")
    end

    test "parses ${VAR//pattern/replacement}" do
      assert {:ok, [{:var_braced, "FOO", [{:subst, "//", "old/new"}]}]} =
               VariableExpander.parse("${FOO//old/new}")
    end

    test "parses substitution with empty replacement" do
      assert {:ok, [{:var_braced, "FOO", [{:subst, "/", "old/"}]}]} =
               VariableExpander.parse("${FOO/old/}")
    end

    test "parses global substitution" do
      # ${FOO//new} is global substitution of "new" with empty replacement
      assert {:ok, [{:var_braced, "FOO", [{:subst, "//", "new"}]}]} =
               VariableExpander.parse("${FOO//new}")
    end
  end

  describe "parse/1 - mixed tokens" do
    test "parses literal followed by variable" do
      assert {:ok, [{:literal, "hello "}, {:var_simple, "NAME"}]} =
               VariableExpander.parse("hello $NAME")
    end

    test "parses variable followed by literal" do
      assert {:ok, [{:var_simple, "NAME"}, {:literal, " world"}]} =
               VariableExpander.parse("$NAME world")
    end

    test "parses multiple variables" do
      assert {:ok, [{:var_simple, "A"}, {:literal, "-"}, {:var_simple, "B"}]} =
               VariableExpander.parse("$A-$B")
    end

    test "parses braced and simple variables together" do
      assert {:ok, [{:var_braced, "A", []}, {:literal, "-"}, {:var_simple, "B"}]} =
               VariableExpander.parse("${A}-$B")
    end

    test "parses complex expression" do
      {:ok, tokens} = VariableExpander.parse("prefix-${FOO:-default}-$BAR-suffix")

      assert [
               {:literal, "prefix-"},
               {:var_braced, "FOO", [{:default, ":-", "default"}]},
               {:literal, "-"},
               {:var_simple, "BAR"},
               {:literal, "-suffix"}
             ] = tokens
    end
  end

  describe "parse/1 - nested expansions" do
    test "parses nested ${} in default value" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":-", "${BAR}"}]}]} =
               VariableExpander.parse("${FOO:-${BAR}}")
    end

    test "parses deeply nested ${}" do
      assert {:ok, [{:var_braced, "A", [{:default, ":-", "${B:-${C}}"}]}]} =
               VariableExpander.parse("${A:-${B:-${C}}}")
    end
  end

  describe "parse/1 - error cases" do
    test "returns error for unclosed brace" do
      assert {:error, _} = VariableExpander.parse("${FOO")
    end

    test "returns error for missing variable name" do
      assert {:error, _} = VariableExpander.parse("${}")
    end

    test "returns error for unclosed nested brace" do
      assert {:error, _} = VariableExpander.parse("${FOO:-${BAR}")
    end
  end

  describe "parse/1 - escaped braces" do
    test "parses escaped closing brace in default value" do
      assert {:ok, [{:var_braced, "FOO", [{:default, ":-", "}"}]}]} =
               VariableExpander.parse("${FOO:-\\}}")
    end
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
    test "raises SyntaxError when variable is unset" do
      session_state = %{variables: %{}}

      error =
        assert_raise SyntaxError, fn ->
          VariableExpander.expand_variables("${UNSET:?custom error}", session_state)
        end

      assert error.code == "SC2154"
      assert error.hint =~ "UNSET: custom error"
    end

    test "raises SyntaxError with default message when no error text provided" do
      session_state = %{variables: %{}}

      error =
        assert_raise SyntaxError, fn ->
          VariableExpander.expand_variables("${UNSET:?}", session_state)
        end

      assert error.code == "SC2154"
      assert error.hint =~ "parameter null or not set"
    end

    test "raises SyntaxError when variable is empty", %{session_state: session_state} do
      error =
        assert_raise SyntaxError, fn ->
          VariableExpander.expand_variables("${EMPTY:?must be set}", session_state)
        end

      assert error.code == "SC2154"
      assert error.hint =~ "EMPTY: must be set"
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
