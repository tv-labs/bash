defmodule Bash.ParserTest do
  use ExUnit.Case

  alias Bash.AST
  alias Bash.Parser
  alias Bash.Script

  describe "Parsing Bash scripts to AST" do
    test "parses simple echo command" do
      script = "echo hello world"
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Command{} = ast
      assert %AST.Word{parts: [literal: "echo"]} = ast.name
      assert length(ast.args) == 2
    end

    test "parses command with double-quoted string" do
      script = ~s|echo "hello world"|
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Command{} = ast
      [arg] = ast.args
      assert %AST.Word{parts: [literal: "hello world"], quoted: :double} = arg
    end

    test "parses command with single-quoted string" do
      script = ~s|echo 'hello world'|
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Command{} = ast
      [arg] = ast.args
      assert %AST.Word{parts: [literal: "hello world"], quoted: :single} = arg
    end

    test "single-quoted strings preserve literal $VAR" do
      script = ~s|echo 'The value is $VAR'|
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      # Single quotes should preserve $VAR literally (no variable expansion)
      assert %AST.Command{} = ast
      [arg] = ast.args
      assert %AST.Word{parts: [literal: "The value is $VAR"], quoted: :single} = arg
    end

    test "double-quoted strings expand $VAR" do
      script = ~s|echo "The value is $VAR"|
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      # Double quotes should parse $VAR as a variable reference
      assert %AST.Command{} = ast
      [arg] = ast.args
      assert %AST.Word{quoted: :double} = arg
      assert [{:literal, "The value is "}, {:variable, %AST.Variable{name: "VAR"}}] = arg.parts
    end

    test "single-quoted strings preserve backslashes literally" do
      script = ~s|echo 'hello\\nworld'|
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      # Single quotes preserve backslash-n literally (no escape processing)
      assert %AST.Command{} = ast
      [arg] = ast.args
      assert %AST.Word{parts: [literal: "hello\\nworld"], quoted: :single} = arg
    end

    test "parses command with flags" do
      script = "ls -la /tmp"
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Command{} = ast
      assert %AST.Word{parts: [literal: "ls"]} = ast.name
      assert length(ast.args) == 2
    end

    test "parses pipeline" do
      script = "echo hello | wc -c"
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Pipeline{} = ast
      assert length(ast.commands) == 2
    end

    test "parses variable assignment" do
      script = ~s|VAR="value"|
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Assignment{name: "VAR"} = ast
    end

    test "parses conditional statement" do
      script = "if [ -f /tmp/file ]; then echo exists; fi"
      {:ok, %Script{} = script_ast} = Parser.parse(script)

      # Conditionals are not yet fully implemented, just check it parses
      assert is_list(script_ast.statements)
    end

    test "parses comment" do
      script = "# This is a comment"
      {:ok, %Script{} = script_ast} = Parser.parse(script)

      # Comments are not yet implemented as AST nodes, just check it parses without error
      assert is_list(script_ast.statements)
    end

    test "parses comment with special characters" do
      script = "# TODO: fix this bug (issue #123)"
      {:ok, %Script{} = script_ast} = Parser.parse(script)

      # Comments are not yet implemented as AST nodes, just check it parses without error
      assert is_list(script_ast.statements)
    end

    test "parses empty comment" do
      script = "#"
      {:ok, %Script{statements: [ast]}} = Parser.parse(script)

      assert %AST.Comment{text: ""} = ast
    end
  end

  describe "Serializing AST back to Bash" do
    test "serializes comment" do
      ast = %AST.Comment{meta: %AST.Meta{line: 1, column: 0}, text: " Configuration comment"}
      bash = to_string(ast)

      assert bash == "# Configuration comment"
    end

    test "roundtrip: comment preservation" do
      original = "# This is a comment"
      {:ok, %Script{statements: [ast]}} = Parser.parse(original)
      serialized = to_string(ast)

      assert serialized == original

      {:ok, %Script{statements: [ast2]}} = Parser.parse(serialized)
      assert ast == ast2
    end
  end

  describe "Roundtrip parsing and serializing" do
    test "parse and serialize multiline script" do
      script = """
      echo Starting
      ls -la /tmp
      echo Done
      """

      {:ok, %Script{} = script_ast} = Parser.parse(script)
      assert to_string(script_ast) == script

      for line <- String.split(script, "\n", trim: true) do
        {:ok, %Script{statements: [ast]}} = Parser.parse(line)
        assert to_string(ast) == line
      end
    end

    test "parse and serialize semicolon-separated commands" do
      # Note: trailing whitespace from input is not preserved
      # Scripts with only semicolons don't get a trailing newline
      script = "echo hello; echo world; echo done"

      {:ok, %Script{} = script_ast} = Parser.parse(script)
      assert to_string(script_ast) == script
    end

    test "parse and serialize mixed newline and semicolon separators" do
      # Note: trailing newlines are not preserved in the AST
      # The serializer adds "\n" for scripts ending with a statement
      script = """
      echo hello
      echo world; echo done
      """

      {:ok, %Script{} = script_ast} = Parser.parse(script)
      serialized = to_string(script_ast)
      assert serialized == script
    end
  end

  describe "test expression bracket mismatch detection" do
    test "SC1033: [[ closed with ] instead of ]]" do
      assert {:error, error} = Bash.parse("[[ -f file ]")
      assert error.code == "SC1033"
      assert error.hint =~ "[["
      assert error.hint =~ "]"
    end

    test "SC1033: missing ]] to close [[" do
      assert {:error, error} = Bash.parse("[[ -f file")
      assert error.code == "SC1033"
      assert error.hint =~ "missing"
    end

    test "SC1034: [ closed with ]] instead of ]" do
      assert {:error, error} = Bash.parse("[ -f file ]]")
      assert error.code == "SC1034"
      assert error.hint =~ "["
      assert error.hint =~ "]]"
    end

    test "SC1034: missing ] to close [" do
      assert {:error, error} = Bash.parse("[ -f file")
      assert error.code == "SC1034"
      assert error.hint =~ "missing"
    end

    test "valid [[ ]] test expression parses" do
      assert {:ok, _} = Bash.parse("[[ -f file ]]")
      assert {:ok, _} = Bash.parse("[[ $a == $b ]]")
    end

    test "valid [ ] test command parses" do
      assert {:ok, _} = Bash.parse("[ -f file ]")
      assert {:ok, _} = Bash.parse("[ \"$a\" = \"$b\" ]")
    end
  end

  describe "test expression semantic validation" do
    test "SC1019: unary operator missing argument" do
      assert {:error, error} = Bash.parse("[ -f ]")
      assert error.code == "SC1019"
      assert error.hint =~ "unary"
    end

    test "SC1019: unary -d missing argument" do
      assert {:error, error} = Bash.parse("[ -d ]")
      assert error.code == "SC1019"
    end

    test "SC1019: unary -z missing argument" do
      assert {:error, error} = Bash.parse("[ -z ]")
      assert error.code == "SC1019"
    end

    test "SC1027: binary operator missing right argument" do
      assert {:error, error} = Bash.parse("[ foo = ]")
      assert error.code == "SC1027"
      assert error.hint =~ "binary"
    end

    test "SC1027: binary operator missing left argument" do
      assert {:error, error} = Bash.parse("[ = bar ]")
      assert error.code == "SC1027"
    end

    test "SC1027: -eq missing argument" do
      assert {:error, error} = Bash.parse("[ 1 -eq ]")
      assert error.code == "SC1027"
    end

    test "SC1020: missing space before ]" do
      assert {:error, error} = Bash.parse("[ -f foo]")
      assert error.code == "SC1020"
      assert error.hint =~ "space"
    end

    test "SC1020: missing space before ] in binary test" do
      assert {:error, error} = Bash.parse("[ a = b]")
      assert error.code == "SC1020"
    end

    test "SC1020: missing space before ] in variable test" do
      assert {:error, error} = Bash.parse("[ -z $var]")
      assert error.code == "SC1020"
    end

    test "valid unary test parses" do
      assert {:ok, _} = Bash.parse("[ -f file ]")
      assert {:ok, _} = Bash.parse("[ -d dir ]")
      assert {:ok, _} = Bash.parse("[ -z \"\" ]")
    end

    test "valid binary test parses" do
      assert {:ok, _} = Bash.parse("[ foo = bar ]")
      assert {:ok, _} = Bash.parse("[ 1 -eq 1 ]")
      assert {:ok, _} = Bash.parse("[ \"$a\" != \"$b\" ]")
    end
  end

  describe "test expression grouping and syntax errors" do
    test "SC1026: rejects [ for grouping in [[ ]]" do
      assert {:error, error} = Bash.parse("[[ [ a || b ] && c ]]")
      assert error.code == "SC1026"
      assert error.hint =~ "grouping"
    end

    test "SC1026: rejects [ for grouping in [ ]" do
      assert {:error, error} = Bash.parse("[ [ a -o b ] -a c ]")
      assert error.code == "SC1026"
      assert error.hint =~ "grouping"
    end

    test "SC1028: rejects unescaped ( in [ ]" do
      assert {:error, error} = Bash.parse("[ -f file -a ( -x prog ) ]")
      assert error.code == "SC1028"
      assert error.hint =~ "Unescaped"
    end

    test "SC1028: rejects unescaped ) in [ ]" do
      # Just ) by itself
      assert {:error, error} = Bash.parse("[ -f file ) ]")
      assert error.code == "SC1028"
    end

    test "SC1029: rejects escaped parens in [[ ]]" do
      assert {:error, error} = Bash.parse("[[ -f file && \\( -x prog \\) ]]")
      assert error.code == "SC1029"
      assert error.hint =~ "Escaped"
    end

    test "SC1080: rejects newline inside [ ]" do
      script = "[ -f file\n-a -d dir ]"
      assert {:error, error} = Bash.parse(script)
      assert error.code == "SC1080"
      assert error.hint =~ "line break"
    end

    test "valid grouping with ( ) in [[ ]] parses" do
      assert {:ok, _} = Bash.parse("[[ ( -f file || -d dir ) && -r file ]]")
    end

    test "valid escaped parens in [ ] parses" do
      assert {:ok, _} = Bash.parse("[ \\( -f file -o -d dir \\) -a -r file ]")
    end

    test "[[ ]] allows newlines" do
      script = "[[ -f file &&\n-d dir ]]"
      assert {:ok, _} = Bash.parse(script)
    end

    test "[ ] with backslash continuation parses" do
      script = "[ -f file \\\n-a -d dir ]"
      assert {:ok, _} = Bash.parse(script)
    end
  end

  describe "missing terminators" do
    test "rejects if without fi" do
      assert {:error, "expected 'elif', 'else', or 'fi'", 1, _col} =
               Bash.Parser.parse("if true; then echo hi")
    end

    test "rejects while without done" do
      assert {:error, "expected 'done' to close while loop", 1, _col} =
               Bash.Parser.parse("while true; do echo hi")
    end

    test "rejects for without done" do
      assert {:error, "expected 'done' to close for loop", 1, _col} =
               Bash.Parser.parse("for i in a b; do echo $i")
    end

    test "rejects unclosed command group" do
      assert {:error, "expected '}' to close group", 1, 13} =
               Bash.Parser.parse("{ echo hello")
    end

    test "rejects bare case keyword" do
      assert {:error, "expected word after 'case'", 1, 5} = Bash.Parser.parse("case")
    end
  end

  describe "orphan keywords" do
    test "rejects orphan then" do
      assert {:error, "'then' outside of if/elif block", 1, 1} =
               Bash.Parser.parse("then echo hi")
    end

    test "rejects orphan else" do
      assert {:error, "'else' outside of if block", 1, 1} =
               Bash.Parser.parse("else echo hi")
    end

    test "rejects orphan fi" do
      assert {:error, "'fi' without matching 'if'", 1, 1} = Bash.Parser.parse("fi")
    end

    test "rejects orphan do" do
      assert {:error, "'do' outside of loop context", 1, 1} =
               Bash.Parser.parse("do echo hi; done")
    end

    test "rejects orphan done" do
      assert {:error, "'done' without matching loop", 1, 1} = Bash.Parser.parse("done")
    end

    test "rejects orphan esac" do
      assert {:error, "'esac' without matching 'case'", 1, 1} = Bash.Parser.parse("esac")
    end

    test "rejects standalone closing brace" do
      assert {:error, "unexpected '}' - no matching '{'", 1, 1} = Bash.Parser.parse("}")
    end

    test "rejects orphan in" do
      assert {:error, _msg, 1, 1} = Bash.Parser.parse("in a b c")
    end
  end

  describe "control flow syntax errors" do
    test "SC1051: semicolon after then" do
      assert {:error, error} = Bash.parse("if true; then; echo hi; fi")
      assert error.code == "SC1051"
      assert error.hint =~ "then"
    end

    test "SC1051: semicolon after then in elif" do
      assert {:error, error} = Bash.parse("if false; then echo a; elif true; then; echo b; fi")
      assert error.code == "SC1051"
    end

    test "SC1053: semicolon after else" do
      assert {:error, error} = Bash.parse("if true; then echo a; else; echo b; fi")
      assert error.code == "SC1053"
      assert error.hint =~ "else"
    end

    test "valid if-then-else parses" do
      assert {:ok, _} = Bash.parse("if true; then echo a; else echo b; fi")
      assert {:ok, _} = Bash.parse("if true; then\necho a\nelse\necho b\nfi")
    end

    test "SC1075: use elif instead of else if" do
      assert {:error, error} =
               Bash.parse("if true; then echo a; else if false; then echo b; fi; fi")

      assert error.code == "SC1075"
      assert error.hint =~ "elif"
    end

    test "SC1075: detects else if in elif chain" do
      assert {:error, error} =
               Bash.parse(
                 "if true; then echo a; elif false; then echo b; else if true; then echo c; fi; fi; fi"
               )

      assert error.code == "SC1075"
    end

    test "valid elif parses" do
      assert {:ok, _} = Bash.parse("if true; then echo a; elif false; then echo b; fi")

      assert {:ok, _} =
               Bash.parse("if true; then echo a; elif false; then echo b; else echo c; fi")
    end
  end

  describe "for loop syntax errors" do
    test "SC1086: don't use $ on for loop variable" do
      assert {:error, error} = Bash.parse("for $i in a b c; do echo $i; done")
      assert error.code == "SC1086"
      assert error.hint =~ "Don't use"
    end

    test "valid for loop parses" do
      assert {:ok, _} = Bash.parse("for i in a b c; do echo $i; done")
      assert {:ok, _} = Bash.parse("for file in *.txt; do cat $file; done")
    end

    test "SC1137: missing second ( for C-style for loop" do
      assert {:error, error} = Bash.parse("for (i=0; i<10; i++); do echo; done")
      assert error.code == "SC1137"
      assert error.hint =~ "double parentheses"
    end

    test "SC1137: space between ( ( triggers error" do
      assert {:error, error} = Bash.parse("for ( (i=0; i<10; i++) ); do echo; done")
      assert error.code == "SC1137"
    end

    test "valid C-style for loop parses" do
      assert {:ok, _} = Bash.parse("for ((i=0; i<10; i++)); do echo $i; done")
    end
  end

  describe "brace group syntax errors" do
    test "SC1055: empty brace group" do
      assert {:error, error} = Bash.parse("{ }")
      assert error.code == "SC1055"
      assert error.hint =~ "at least one command"
    end

    test "valid brace group parses" do
      assert {:ok, _} = Bash.parse("{ echo hello; }")
      assert {:ok, _} = Bash.parse("{ true; }")
    end
  end

  describe "case statement syntax errors" do
    test "SC1074: missing ;; between case items" do
      assert {:error, error} = Bash.parse("case $x in a) echo a b) echo b;; esac")
      assert error.code == "SC1074"
      assert error.hint =~ ";;"
    end

    test "SC1074: missing ;; with newline" do
      script = """
      case $x in
        a) echo a
        b) echo b;;
      esac
      """

      assert {:error, error} = Bash.parse(script)
      assert error.code == "SC1074"
    end

    test "valid case with ;; parses" do
      assert {:ok, _} = Bash.parse("case $x in a) echo a;; b) echo b;; esac")
    end

    test "valid case without ;; on last item parses" do
      # Last case item can omit ;; if there's a newline before esac
      script = """
      case $x in
        a) echo a;;
        b) echo b
      esac
      """

      assert {:ok, _} = Bash.parse(script)
    end

    test "valid case with fallthrough ;& parses" do
      assert {:ok, _} = Bash.parse("case $x in a) echo a;& b) echo b;; esac")
    end

    test "valid case with continue ;;& parses" do
      assert {:ok, _} = Bash.parse("case $x in a) echo a;;& b) echo b;; esac")
    end
  end

  describe "function definition syntax errors" do
    test "SC1095: function name contains {" do
      assert {:error, error} = Bash.parse("function foo{echo}")
      assert error.code == "SC1095"
      assert error.hint =~ "function"
    end

    test "SC1064: function body must be compound command - name() style" do
      assert {:error, error} = Bash.parse("foo() echo hello")
      assert error.code == "SC1064"
      assert error.hint =~ "{"
    end

    test "SC1064: function body must be compound command - function keyword style" do
      assert {:error, error} = Bash.parse("function bar echo hello")
      assert error.code == "SC1064"
      assert error.hint =~ "{"
    end

    test "SC1065: function params not allowed - name() style" do
      assert {:error, error} = Bash.parse("foo(x, y) { echo; }")
      assert error.code == "SC1065"
      assert error.hint =~ "parameters"
    end

    test "SC1065: function params not allowed - function keyword style" do
      assert {:error, error} = Bash.parse("function bar(a, b) { echo; }")
      assert error.code == "SC1065"
      assert error.hint =~ "parameters"
    end

    test "valid function definitions parse" do
      assert {:ok, _} = Bash.parse("function foo { echo; }")
      assert {:ok, _} = Bash.parse("function foo() { echo; }")
      assert {:ok, _} = Bash.parse("foo() { echo; }")
    end

    test "valid function with subshell body parses" do
      assert {:ok, _} = Bash.parse("foo() (echo hello)")
    end

    test "valid function with if body parses" do
      assert {:ok, _} = Bash.parse("foo() if true; then echo; fi")
    end
  end

  describe "pipe syntax errors" do
    test "SC1133: pipe at start of line" do
      script = """
      echo foo
      | grep bar
      """

      assert {:error, error} = Bash.parse(script)
      assert error.code == "SC1133"
      assert error.hint =~ "start of line"
    end

    test "SC1133: pipe at start of script" do
      assert {:error, error} = Bash.parse("| grep bar")
      assert error.code == "SC1133"
    end

    test "valid pipe at end of line parses" do
      script = """
      echo foo |
        grep bar
      """

      assert {:ok, _} = Bash.parse(script)
    end
  end
end
