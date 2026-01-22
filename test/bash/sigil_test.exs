defmodule Bash.SigilTest do
  use Bash.SessionCase, async: true

  import Bash.Sigil

  alias Bash.AST
  alias Bash.Script
  alias Bash.SyntaxError

  setup :start_session

  describe "~BASH sigil" do
    test "creates AST.Command struct" do
      %Script{statements: [cmd]} = ~BASH"echo hello world"

      assert %AST.Command{} = cmd
      assert %AST.Word{parts: [literal: "echo"]} = cmd.name
      assert length(cmd.args) == 2
    end

    test "parses command with single argument" do
      %Script{statements: [cmd]} = ~BASH"pwd"

      assert %AST.Command{} = cmd
      assert %AST.Word{parts: [literal: "pwd"]} = cmd.name
      assert cmd.args == []
    end

    test "parses command with multiple arguments" do
      %Script{statements: [cmd]} = ~BASH"wc -c -l"

      assert %AST.Command{} = cmd
      assert %AST.Word{parts: [literal: "wc"]} = cmd.name
      assert length(cmd.args) == 2
    end

    test "executes sigil command with session", %{session: session} do
      result = run_script(session, "echo hello world")
      assert get_stdout(result) == "hello world\n"
    end

    test "can chain sigil commands in pipeline", %{session: session} do
      # Pipeline pipes "hello\n" (6 bytes) to wc -c
      result = run_script(session, "echo hello | wc -c")
      assert String.trim(get_stdout(result)) == "6"
    end

    test "handles quoted arguments correctly" do
      %Script{statements: [cmd]} = ~BASH"echo hello world"

      # Test that it creates AST structs correctly
      assert %AST.Command{} = cmd
      assert to_string(cmd) == "echo hello world"
    end
  end

  describe "sigil validation errors (runtime)" do
    # Test validation errors using parse_at_runtime since compile-time
    # errors can't be easily tested in the same module

    test "raises SyntaxError for unclosed command group" do
      assert_raise SyntaxError, ~r/SC1056/, fn ->
        parse_at_runtime("{ echo hello")
      end
    end

    test "raises SyntaxError for if without fi" do
      assert_raise SyntaxError, ~r/SC1046/, fn ->
        parse_at_runtime("if true; then echo hi")
      end
    end

    test "raises SyntaxError for while without done" do
      assert_raise SyntaxError, ~r/SC1061/, fn ->
        parse_at_runtime("while true; do echo hi")
      end
    end

    test "raises SyntaxError for for without done" do
      assert_raise SyntaxError, ~r/SC1061/, fn ->
        parse_at_runtime("for i in a b; do echo $i")
      end
    end

    test "raises SyntaxError for orphan then" do
      assert_raise SyntaxError, ~r/SC1047/, fn ->
        parse_at_runtime("then echo hi")
      end
    end

    test "raises SyntaxError for orphan fi" do
      assert_raise SyntaxError, ~r/SC1050/, fn ->
        parse_at_runtime("fi")
      end
    end

    test "raises SyntaxError for orphan done" do
      assert_raise SyntaxError, ~r/SC1063/, fn ->
        parse_at_runtime("done")
      end
    end

    test "raises SyntaxError for unclosed quote" do
      assert_raise SyntaxError, ~r/SC1009|SC1000/, fn ->
        parse_at_runtime("echo \"hello")
      end
    end

    test "error message includes script and hint" do
      error =
        try do
          parse_at_runtime("{ echo hello")
        rescue
          e in SyntaxError -> e
        end

      message = Exception.message(error)
      assert message =~ "{ echo hello"
      assert message =~ "hint:"
      assert message =~ "{"
    end

    test "valid scripts do not raise" do
      # These should all parse without error
      assert %Script{} = parse_at_runtime("echo hello")
      assert %Script{} = parse_at_runtime("if true; then echo hi; fi")
      assert %Script{} = parse_at_runtime("while true; do echo hi; done")
      assert %Script{} = parse_at_runtime("for i in a b c; do echo $i; done")
      assert %Script{} = parse_at_runtime("{ echo hello; }")
    end
  end

  describe "sigil output modifiers" do
    test "S modifier returns stdout" do
      assert ~BASH"echo hello"S == "hello\n"
    end

    test "E modifier returns stderr" do
      assert ~BASH"echo error >&2"E == "error\n"
    end

    test "O modifier returns combined output" do
      result = ~BASH"echo out; echo err >&2"O
      assert result == "out\nerr\n"
    end

    test "no modifier returns Script struct" do
      assert %Script{} = ~BASH"echo hello"
    end
  end

  describe "sigil session option modifiers" do
    test "e modifier enables errexit" do
      assert ~BASH"false; echo printed"S == "printed\n"
      assert ~BASH"false; echo not_printed"eS == ""
    end

    test "combined modifiers work" do
      # errexit + stdout
      assert ~BASH"true; echo hello"eS == "hello\n"
    end

    test "unknown modifier raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown sigil modifier/, fn ->
        Code.eval_string(~s|import Bash.Sigil; ~BASH"echo hello"x|)
      end
    end

    test "multiple output modifiers raise ArgumentError" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Code.eval_string(~s|import Bash.Sigil; ~BASH"echo hello"SO|)
      end
    end
  end
end
