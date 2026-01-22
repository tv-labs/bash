defmodule Bash.EscapeTest do
  use ExUnit.Case, async: true

  describe "escape!/2 with double quotes (?\")" do
    test "returns unchanged string when no special chars" do
      assert Bash.escape!("hello world", ?") == "hello world"
    end

    test "escapes double quotes" do
      assert Bash.escape!("say \"hello\"", ?") == "say \\\"hello\\\""
    end

    test "escapes backslashes" do
      assert Bash.escape!("path\\to\\file", ?") == "path\\\\to\\\\file"
    end

    test "escapes both quotes and backslashes" do
      assert Bash.escape!("say \\\"hi\\\"", ?") == "say \\\\\\\"hi\\\\\\\""
    end

    test "does not escape dollar signs" do
      assert Bash.escape!("$HOME", ?") == "$HOME"
    end

    test "does not escape backticks" do
      assert Bash.escape!("`cmd`", ?") == "`cmd`"
    end

    test "handles empty string" do
      assert Bash.escape!("", ?") == ""
    end

    test "handles newlines" do
      assert Bash.escape!("line1\nline2", ?") == "line1\nline2"
    end
  end

  describe "escape!/2 with single quotes (?')" do
    test "returns unchanged string when no special chars" do
      assert Bash.escape!("hello world", ?') == "hello world"
    end

    test "escapes single quotes using end/restart technique" do
      assert Bash.escape!("it's here", ?') == "it'\\''s here"
    end

    test "escapes multiple single quotes" do
      assert Bash.escape!("'hello'", ?') == "'\\''hello'\\''"
    end

    test "does not escape double quotes" do
      assert Bash.escape!("say \"hello\"", ?') == "say \"hello\""
    end

    test "does not escape backslashes" do
      assert Bash.escape!("path\\to\\file", ?') == "path\\to\\file"
    end

    test "does not escape dollar signs" do
      assert Bash.escape!("$HOME", ?') == "$HOME"
    end

    test "handles empty string" do
      assert Bash.escape!("", ?') == ""
    end
  end

  describe "escape!/2 with heredoc delimiter" do
    test "returns unchanged string when delimiter not present" do
      assert Bash.escape!("hello world", "EOF") == "hello world"
    end

    test "returns unchanged when delimiter appears as substring" do
      assert Bash.escape!("this is an EOF-like word", "EOF") == "this is an EOF-like word"
    end

    test "returns unchanged when delimiter appears with prefix" do
      assert Bash.escape!("prefix EOF", "EOF") == "prefix EOF"
    end

    test "returns unchanged when delimiter appears with suffix" do
      assert Bash.escape!("EOF suffix", "EOF") == "EOF suffix"
    end

    test "raises when delimiter appears on its own line" do
      assert_raise Bash.EscapeError, fn ->
        Bash.escape!("line1\nEOF\nline2", "EOF")
      end
    end

    test "raises when delimiter is the only content" do
      assert_raise Bash.EscapeError, fn ->
        Bash.escape!("EOF", "EOF")
      end
    end

    test "raises when delimiter is at start" do
      assert_raise Bash.EscapeError, fn ->
        Bash.escape!("EOF\nmore content", "EOF")
      end
    end

    test "raises when delimiter is at end" do
      assert_raise Bash.EscapeError, fn ->
        Bash.escape!("content\nEOF", "EOF")
      end
    end

    test "error contains useful information" do
      error =
        assert_raise Bash.EscapeError, fn ->
          Bash.escape!("before\nMYDELIM\nafter", "MYDELIM")
        end

      assert error.reason == :delimiter_in_content
      assert error.content == "before\nMYDELIM\nafter"
      assert error.context == "MYDELIM"
      assert Exception.message(error) =~ "MYDELIM"
    end

    test "handles empty string" do
      assert Bash.escape!("", "EOF") == ""
    end

    test "handles multiline content without delimiter" do
      content = "line1\nline2\nline3"
      assert Bash.escape!(content, "EOF") == content
    end
  end
end
