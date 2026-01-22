defmodule Bash.Parser.RedirectTest do
  use ExUnit.Case, async: true

  alias Bash.AST
  alias Bash.Parser
  alias Bash.Script

  describe "input redirection parsing" do
    test "parses < file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat < input.txt")

      assert %AST.Command{
               name: %AST.Word{parts: [{:literal, "cat"}]},
               redirects: [
                 %AST.Redirect{
                   direction: :input,
                   fd: 0,
                   target: {:file, %AST.Word{parts: [{:literal, "input.txt"}]}}
                 }
               ]
             } = ast
    end

    test "parses 0< file (explicit fd)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat 0< input.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :input, fd: 0}
               ]
             } = ast
    end

    test "parses < with variable in filename" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat < $FILE")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :input,
                   fd: 0,
                   target: {:file, %AST.Word{parts: [{:variable, %AST.Variable{name: "FILE"}}]}}
                 }
               ]
             } = ast
    end
  end

  describe "output redirection parsing" do
    test "parses > file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello > output.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :output,
                   fd: 1,
                   target: {:file, %AST.Word{parts: [{:literal, "output.txt"}]}}
                 }
               ]
             } = ast
    end

    test "parses 1> file (explicit fd)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello 1> output.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :output, fd: 1}
               ]
             } = ast
    end

    test "parses 2> file (stderr)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd 2> errors.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :output,
                   fd: 2,
                   target: {:file, %AST.Word{parts: [{:literal, "errors.txt"}]}}
                 }
               ]
             } = ast
    end
  end

  describe "append redirection parsing" do
    test "parses >> file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo line >> log.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :append,
                   fd: 1,
                   target: {:file, %AST.Word{parts: [{:literal, "log.txt"}]}}
                 }
               ]
             } = ast
    end

    test "parses 2>> file (stderr append)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd 2>> errors.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :append, fd: 2}
               ]
             } = ast
    end
  end

  describe "file descriptor duplication parsing" do
    test "parses 2>&1 (stderr to stdout)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd 2>&1")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :duplicate,
                   fd: 2,
                   target: {:fd, 1}
                 }
               ]
             } = ast
    end

    test "parses 1>&2 (stdout to stderr)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo error 1>&2")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :duplicate,
                   fd: 1,
                   target: {:fd, 2}
                 }
               ]
             } = ast
    end

    test "parses >&2 (shorthand stdout to stderr)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo error >&2")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :duplicate,
                   fd: 1,
                   target: {:fd, 2}
                 }
               ]
             } = ast
    end
  end

  describe "combined redirections parsing" do
    test "parses &> file (stdout and stderr to file)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd &> all.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :output,
                   fd: :both,
                   target: {:file, %AST.Word{parts: [{:literal, "all.txt"}]}}
                 }
               ]
             } = ast
    end

    test "parses &>> file (append stdout and stderr)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd &>> all.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :append,
                   fd: :both,
                   target: {:file, %AST.Word{parts: [{:literal, "all.txt"}]}}
                 }
               ]
             } = ast
    end
  end

  describe "multiple redirections parsing" do
    test "parses input and output together" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat < in.txt > out.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :input, fd: 0},
                 %AST.Redirect{direction: :output, fd: 1}
               ]
             } = ast
    end

    test "parses output and stderr redirect" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd > out.txt 2>&1")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :output, fd: 1},
                 %AST.Redirect{direction: :duplicate, fd: 2, target: {:fd, 1}}
               ]
             } = ast
    end

    test "parses three redirections" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd < in.txt > out.txt 2> err.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :input, fd: 0},
                 %AST.Redirect{direction: :output, fd: 1},
                 %AST.Redirect{direction: :output, fd: 2}
               ]
             } = ast
    end
  end

  describe "redirection with arguments" do
    test "redirections after arguments" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello world > output.txt")

      assert %AST.Command{
               name: %AST.Word{parts: [{:literal, "echo"}]},
               args: [
                 %AST.Word{parts: [{:literal, "hello"}]},
                 %AST.Word{parts: [{:literal, "world"}]}
               ],
               redirects: [%AST.Redirect{direction: :output}]
             } = ast
    end

    test "redirections before arguments" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo > output.txt hello world")

      assert %AST.Command{
               name: %AST.Word{parts: [{:literal, "echo"}]},
               args: [
                 %AST.Word{parts: [{:literal, "hello"}]},
                 %AST.Word{parts: [{:literal, "world"}]}
               ],
               redirects: [%AST.Redirect{direction: :output}]
             } = ast
    end

    test "redirections between arguments" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello > output.txt world")

      assert %AST.Command{
               args: [
                 %AST.Word{parts: [{:literal, "hello"}]},
                 %AST.Word{parts: [{:literal, "world"}]}
               ],
               redirects: [%AST.Redirect{direction: :output}]
             } = ast
    end
  end

  describe "redirection serialization" do
    test "serializes < file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat < input.txt")
      assert "cat < input.txt" == to_string(ast)
    end

    test "serializes > file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello > output.txt")
      assert "echo hello > output.txt" == to_string(ast)
    end

    test "serializes >> file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo line >> log.txt")
      assert "echo line >> log.txt" == to_string(ast)
    end

    test "serializes 2>&1" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd 2>&1")
      assert "cmd 2>&1" == to_string(ast)
    end

    test "serializes &> file" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd &> all.txt")
      assert "cmd &> all.txt" == to_string(ast)
    end

    test "serializes multiple redirections" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd < in.txt > out.txt 2>&1")
      assert "cmd < in.txt > out.txt 2>&1" == to_string(ast)
    end
  end
end
