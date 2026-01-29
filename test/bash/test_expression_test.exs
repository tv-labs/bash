defmodule Bash.TestExpressionTest do
  use Bash.SessionCase, async: true

  alias Bash.AST.RegexPattern

  setup :start_session

  describe "regex pattern tokenization" do
    test "unquoted regex pattern preserves metacharacters", %{session: session} do
      result = run_script(session, "[[ \"hello123\" =~ [0-9]+ ]] && echo match || echo nomatch")
      assert get_stdout(result) == "match\n"
    end

    test "complex unquoted regex with anchors", %{session: session} do
      result =
        run_script(session, "[[ \"test123end\" =~ ^[a-z]+[0-9]+end$ ]] && echo yes || echo no")

      assert get_stdout(result) == "yes\n"
    end

    test "unquoted regex with alternation", %{session: session} do
      result = run_script(session, "[[ \"cat\" =~ ^(cat|dog)$ ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "unquoted regex with character class", %{session: session} do
      result = run_script(session, "[[ \"ABC\" =~ ^[A-Z]+$ ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "unquoted regex with quantifiers", %{session: session} do
      result = run_script(session, "[[ \"aaa\" =~ a+ ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "unquoted regex with optional", %{session: session} do
      result = run_script(session, "[[ \"ac\" =~ ab?c ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "POSIX character class [[:space:]]", %{session: session} do
      result = run_script(session, "[[ \"hello world\" =~ [[:space:]] ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "POSIX character class [[:digit:]]", %{session: session} do
      result = run_script(session, "[[ \"abc123\" =~ [[:digit:]]+ ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "complex pattern with nested POSIX classes", %{session: session} do
      result =
        run_script(
          session,
          "[[ \"  123  \" =~ ^[[:space:]]*[[:digit:]]+[[:space:]]*$ ]] && echo yes || echo no"
        )

      assert get_stdout(result) == "yes\n"
    end
  end

  describe "quoted regex patterns (literal matching)" do
    test "double-quoted pattern is literal match", %{session: session} do
      # In bash, quoted patterns after =~ are literal substring matches
      result = run_script(session, ~s([[ "hello[0-9]+" =~ "[0-9]+" ]] && echo yes || echo no))
      assert get_stdout(result) == "yes\n"
    end

    test "single-quoted pattern is literal match", %{session: session} do
      result = run_script(session, "[[ \"hello[0-9]+\" =~ '[0-9]+' ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "literal match does not interpret regex metacharacters", %{session: session} do
      # This tests that "[0-9]+" is not a regex but a literal string
      result = run_script(session, ~s([[ "hello123" =~ "[0-9]+" ]] && echo yes || echo no))
      assert get_stdout(result) == "no\n"
    end
  end

  describe "BASH_REMATCH" do
    test "BASH_REMATCH[0] contains entire match", %{session: session} do
      script = """
      [[ "hello123world" =~ [0-9]+ ]]
      echo "${BASH_REMATCH[0]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "123\n"
    end

    test "BASH_REMATCH[1..n] contains capture groups", %{session: session} do
      script = """
      [[ "hello123world456" =~ ([a-z]+)([0-9]+) ]]
      echo "${BASH_REMATCH[0]}"
      echo "${BASH_REMATCH[1]}"
      echo "${BASH_REMATCH[2]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "hello123\nhello\n123\n"
    end

    test "nested capture groups", %{session: session} do
      script = """
      [[ "abc123" =~ (([a-z]+)([0-9]+)) ]]
      echo "${BASH_REMATCH[0]}"
      echo "${BASH_REMATCH[1]}"
      echo "${BASH_REMATCH[2]}"
      echo "${BASH_REMATCH[3]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "abc123\nabc123\nabc\n123\n"
    end

    test "BASH_REMATCH is cleared on no match", %{session: session} do
      script = """
      [[ "abc" =~ ([0-9]+) ]]
      echo "count=${#BASH_REMATCH[@]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "count=0\n"
    end

    test "BASH_REMATCH persists until next regex", %{session: session} do
      script = """
      [[ "hello123" =~ ([a-z]+)([0-9]+) ]]
      first="${BASH_REMATCH[1]}"
      [[ "world456" =~ ([a-z]+)([0-9]+) ]]
      echo "$first ${BASH_REMATCH[1]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "hello world\n"
    end

    test "BASH_REMATCH with quoted pattern (literal match)", %{session: session} do
      script = ~s"""
      [[ "hello[test]world" =~ "[test]" ]]
      echo "${BASH_REMATCH[0]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "[test]\n"
    end
  end

  describe "regex with variables" do
    test "variable expansion in regex pattern", %{session: session} do
      script = """
      pattern="[0-9]+"
      [[ "abc123def" =~ $pattern ]] && echo "${BASH_REMATCH[0]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "123\n"
    end

    test "variable as part of regex", %{session: session} do
      script = """
      prefix="hello"
      [[ "hello123" =~ ^${prefix}([0-9]+) ]]
      echo "${BASH_REMATCH[1]}"
      """

      result = run_script(session, script)
      assert get_stdout(result) == "123\n"
    end
  end

  describe "regex edge cases" do
    test "empty string match", %{session: session} do
      result = run_script(session, "[[ \"\" =~ ^$ ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "special characters in input", %{session: session} do
      result = run_script(session, "[[ \"hello.world\" =~ \\\\. ]] && echo yes || echo no")
      assert get_stdout(result) == "yes\n"
    end

    test "regex with && in expression", %{session: session} do
      script = "[[ \"abc\" =~ ^[a-z]+$ && \"123\" =~ ^[0-9]+$ ]] && echo yes || echo no"
      result = run_script(session, script)
      assert get_stdout(result) == "yes\n"
    end

    test "regex with || in expression", %{session: session} do
      script = "[[ \"abc\" =~ ^[0-9]+$ || \"abc\" =~ ^[a-z]+$ ]] && echo yes || echo no"
      result = run_script(session, script)
      assert get_stdout(result) == "yes\n"
    end

    test "negated regex match", %{session: session} do
      script = "[[ ! \"abc\" =~ ^[0-9]+$ ]] && echo yes || echo no"
      result = run_script(session, script)
      assert get_stdout(result) == "yes\n"
    end
  end

  describe "parser produces RegexPattern" do
    test "unquoted regex produces RegexPattern AST" do
      {:ok, script} = Bash.Parser.parse("[[ \"test\" =~ [0-9]+ ]]")
      [test_expr] = script.statements

      # The third element (index 2) should be a RegexPattern
      regex = Enum.at(test_expr.expression, 2)
      assert %RegexPattern{} = regex
    end

    test "quoted regex produces RegexPattern with quoted parts" do
      {:ok, script} = Bash.Parser.parse(~s([[ "test" =~ "[0-9]+" ]]))
      [test_expr] = script.statements

      regex = Enum.at(test_expr.expression, 2)
      assert %RegexPattern{parts: [{:double_quoted, _}]} = regex
    end
  end

  describe "-R test operator for namerefs" do
    test "[[ -R nameref ]] returns true for nameref variable", %{session: session} do
      result =
        run_script(session, ~S"""
        declare -n nameref=myvar
        [[ -R nameref ]] && echo "-R: nameref is a nameref"
        """)

      assert get_stdout(result) |> String.trim() == "-R: nameref is a nameref"
    end

    test "[[ -R normalvar ]] returns false for regular variable", %{session: session} do
      result =
        run_script(session, ~S"""
        normalvar="hello"
        [[ -R normalvar ]] && echo "yes" || echo "no"
        """)

      assert get_stdout(result) |> String.trim() == "no"
    end
  end
end
