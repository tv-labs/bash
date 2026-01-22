defmodule Bash.SerializerTest do
  @moduledoc """
  Tests for AST String.Chars protocol implementations (serialization).
  """
  use ExUnit.Case

  import Bash.Sigil

  alias Bash.Parser
  alias Bash.Script

  describe "Serializing AST back to Bash via String.Chars" do
    test "serializes simple command" do
      assert_roundtrip("echo hello world")
    end

    test "serializes command with flags" do
      assert_roundtrip("ls -la /tmp")
    end

    test "serializes pipeline" do
      assert_roundtrip("echo hello | wc -c")
    end
  end

  describe "String.Chars protocol for Command and Pipeline" do
    test "Command can be converted to string" do
      %Script{statements: [cmd]} = ~BASH"echo hello world"
      assert to_string(cmd) == "echo hello world"
    end

    test "Pipeline can be converted to string" do
      %Script{statements: [cmd1]} = ~BASH"echo hello"
      %Script{statements: [cmd2]} = ~BASH"wc -c"

      pipeline = %Bash.AST.Pipeline{
        meta: %Bash.AST.Meta{},
        commands: [cmd1, cmd2]
      }

      assert to_string(pipeline) == "echo hello | wc -c"
    end
  end

  describe "test command [ ] serialization" do
    test "simple file test" do
      script = "[ -f file.txt ]"
      assert_roundtrip(script)
    end

    test "string equality" do
      script = ~s([ "hello" = "world" ])
      assert_roundtrip(script)
    end

    test "numeric comparison" do
      script = "[ 5 -eq 5 ]"
      assert_roundtrip(script)
    end

    test "file comparison" do
      script = "[ file1.txt -nt file2.txt ]"
      assert_roundtrip(script)
    end

    test "in a script with newlines" do
      script = """
      [ -f file.txt ]
      echo hello
      """

      assert_roundtrip(script)
    end

    test "with semicolon separator" do
      script = "[ -f file.txt ]; echo done"
      assert_roundtrip(script)
    end
  end

  describe "test expression [[ ]] serialization" do
    test "simple file test" do
      script = "[[ -f file.txt ]]"
      assert_roundtrip(script)
    end

    test "string equality" do
      script = ~s([[ "hello" = "world" ]])
      assert_roundtrip(script)
    end

    test "pattern matching with ==" do
      script = "[[ \"file.txt\" == *.txt ]]"
      assert_roundtrip(script)
    end

    test "regex matching with =~" do
      script = ~s([[ "hello123" =~ "[0-9]+" ]])
      assert_roundtrip(script)
    end

    test "with && operator" do
      script = "[[ -f file.txt && -r file.txt ]]"
      assert_roundtrip(script)
    end

    test "with || operator" do
      script = "[[ -f file.txt || -d file.txt ]]"
      assert_roundtrip(script)
    end

    test "with ! operator" do
      script = "[[ ! -f file.txt ]]"
      assert_roundtrip(script)
    end

    test "complex expression" do
      script = "[[ ! -f file.txt && -d dir ]]"
      assert_roundtrip(script)
    end

    test "numeric comparison" do
      script = "[[ 5 -eq 5 ]]"
      assert_roundtrip(script)
    end

    test "in a script with newlines" do
      script = """
      [[ -f file.txt ]]
      echo hello
      """

      assert_roundtrip(script)
    end

    test "with semicolon separator" do
      script = "[[ -f file.txt ]]; echo done"
      assert_roundtrip(script)
    end
  end

  defp assert_roundtrip(script) do
    alias Bash.Script

    {:ok, %Script{} = ast} = Parser.parse(script)

    # Use to_string/1 which calls the String.Chars protocol
    serialized = to_string(ast)

    {:ok, %Script{} = ast2} = Parser.parse(serialized)

    assert ast == ast2,
           """
           Roundtrip failed!
           Original: #{inspect(script)}
           Serialized: #{inspect(serialized)}
           Original AST: #{inspect(ast, pretty: true)}
           Roundtrip AST: #{inspect(ast2, pretty: true)}
           """
  end
end
