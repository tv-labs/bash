defmodule Bash.CaseTest do
  use Bash.SessionCase, async: true

  alias Bash.AST
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session

  describe "case statement parsing" do
    test "parses empty case statement" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("case x in esac")

      assert %AST.Case{
               word: %AST.Word{parts: [literal: "x"]},
               cases: []
             } = ast
    end

    test "parses case with single pattern" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("case x in foo) echo foo ;; esac")

      assert %AST.Case{
               word: %AST.Word{parts: [literal: "x"]},
               cases: [{[%AST.Word{parts: [literal: "foo"]}], [%AST.Command{}], :break}]
             } = ast
    end

    test "parses case with multiple patterns" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("case x in foo|bar) echo foobar ;; esac")

      assert %AST.Case{
               cases: [
                 {[%AST.Word{parts: [literal: "foo"]}, %AST.Word{parts: [literal: "bar"]}],
                  [%AST.Command{}], :break}
               ]
             } = ast
    end

    test "parses case with wildcard pattern" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("case x in *) echo default ;; esac")

      assert %AST.Case{
               cases: [{[%AST.Word{parts: [literal: "*"]}], [%AST.Command{}], :break}]
             } = ast
    end

    test "parses case with glob patterns" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("case x in a*) echo a ;; b?) echo b ;; esac")

      assert %AST.Case{
               cases: [
                 {[%AST.Word{parts: [literal: "a*"]}], [%AST.Command{}], :break},
                 {[%AST.Word{parts: [literal: "b?"]}], [%AST.Command{}], :break}
               ]
             } = ast
    end

    test "parses case with variable word" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("case $var in foo) echo foo ;; esac")

      assert %AST.Case{
               word: %AST.Word{parts: [variable: %AST.Variable{name: "var"}]}
             } = ast
    end

    test "parses multiline case statement" do
      script = """
      case $var in
        foo)
          echo foo
          ;;
        bar|baz)
          echo barbaz
          ;;
        *)
          echo default
          ;;
      esac
      """

      {:ok, %Script{statements: [ast]}} = Parser.parse(String.trim(script))

      assert %AST.Case{
               word: %AST.Word{parts: [variable: %AST.Variable{name: "var"}]},
               cases: [
                 {[%AST.Word{parts: [literal: "foo"]}], [%AST.Command{}], :break},
                 {[%AST.Word{parts: [literal: "bar"]}, %AST.Word{parts: [literal: "baz"]}],
                  [%AST.Command{}], :break},
                 {[%AST.Word{parts: [literal: "*"]}], [%AST.Command{}], :break}
               ]
             } = ast
    end
  end

  describe "case statement execution" do
    setup do
      {:ok, session} = Session.start_link(id: "case_exec_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "executes first matching pattern", %{session: session} do
      Session.set_env(session, "var", "foo")
      result = run_script(session, "case $var in foo) echo matched ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "matched\n"
    end

    test "executes default pattern when no match", %{session: session} do
      Session.set_env(session, "var", "xyz")
      result = run_script(session, "case $var in foo) echo foo ;; *) echo default ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "default\n"
    end

    test "returns empty output when no pattern matches", %{session: session} do
      Session.set_env(session, "var", "xyz")
      result = run_script(session, "case $var in foo) echo foo ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end

    test "executes alternate patterns (|)", %{session: session} do
      Session.set_env(session, "var", "baz")
      result = run_script(session, "case $var in foo) echo foo ;; bar|baz) echo barbaz ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "barbaz\n"
    end

    test "matches glob pattern with *", %{session: session} do
      Session.set_env(session, "var", "hello_world")
      result = run_script(session, "case $var in hello*) echo starts_with_hello ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "starts_with_hello\n"
    end

    test "matches glob pattern with ?", %{session: session} do
      Session.set_env(session, "var", "ab")
      result = run_script(session, "case $var in a?) echo matches ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "matches\n"
    end

    test "? does not match multiple characters", %{session: session} do
      Session.set_env(session, "var", "abc")
      result = run_script(session, "case $var in a?) echo matches ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end

    test "matches character class [...]", %{session: session} do
      Session.set_env(session, "var", "b")
      result = run_script(session, "case $var in [abc]) echo in_class ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "in_class\n"
    end

    test "matches negated character class [!...]", %{session: session} do
      Session.set_env(session, "var", "x")
      result = run_script(session, "case $var in [!abc]) echo not_in_class ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "not_in_class\n"
    end

    test "stops at first matching pattern", %{session: session} do
      Session.set_env(session, "var", "foo")
      result = run_script(session, "case $var in foo) echo first ;; foo) echo second ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "first\n"
    end

    test "executes multiple commands in matched clause", %{session: session} do
      Session.set_env(session, "var", "foo")

      result =
        run_script(session, """
        case $var in
          foo)
            echo line1
            echo line2
            ;;
        esac
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "line1\nline2\n"
    end

    test "case with literal word (not variable)", %{session: session} do
      result = run_script(session, "case foo in foo) echo matched ;; esac")

      assert result.exit_code == 0
      assert get_stdout(result) == "matched\n"
    end
  end

  describe ";& fallthrough" do
    setup do
      {:ok, session} = Session.start_link(id: "case_fallthrough_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test ";& executes the next clause unconditionally", %{session: session} do
      result =
        run_script(session, """
        case foo in
          foo) echo first ;&
          bar) echo second ;;
          baz) echo third ;;
        esac
        """)

      assert get_stdout(result) == "first\nsecond\n"
    end

    test ";& falls through multiple clauses", %{session: session} do
      result =
        run_script(session, """
        case foo in
          foo) echo first ;&
          bar) echo second ;&
          baz) echo third ;;
        esac
        """)

      assert get_stdout(result) == "first\nsecond\nthird\n"
    end
  end

  describe ";;& continue matching" do
    setup do
      {:ok, session} = Session.start_link(id: "case_continue_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test ";;& continues testing subsequent patterns", %{session: session} do
      result =
        run_script(session, """
        case foo in
          f*) echo glob_match ;;&
          foo) echo exact_match ;;&
          bar) echo no_match ;;
        esac
        """)

      assert get_stdout(result) == "glob_match\nexact_match\n"
    end

    test ";;& skips non-matching clauses", %{session: session} do
      result =
        run_script(session, """
        case foo in
          f*) echo first ;;&
          bar) echo second ;;&
          *) echo default ;;
        esac
        """)

      assert get_stdout(result) == "first\ndefault\n"
    end

    test ";;& stops at ;; terminator", %{session: session} do
      result =
        run_script(session, """
        case foo in
          f*) echo first ;;&
          foo) echo second ;;
          *) echo default ;;
        esac
        """)

      assert get_stdout(result) == "first\nsecond\n"
    end
  end
end
