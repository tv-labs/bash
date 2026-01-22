defmodule Bash.FormatterTest do
  use ExUnit.Case, async: true

  alias Bash.Formatter

  describe "roundtrip - redirect operators" do
    test "preserves input redirect <" do
      assert_roundtrip("cat < file.txt")
    end

    test "preserves output redirect >" do
      assert_roundtrip("echo hello > file.txt")
    end

    test "preserves append redirect >>" do
      assert_roundtrip("echo hello >> file.txt")
    end

    test "preserves fd output redirect 2>" do
      assert_roundtrip("command 2> errors.txt")
    end

    test "preserves fd input redirect 0<" do
      assert_roundtrip("command 0< input.txt")
    end

    test "preserves fd duplication >&" do
      assert_roundtrip("command 2>&1")
    end

    test "preserves combined stdout/stderr &>" do
      assert_roundtrip("command &> output.txt")
    end

    test "preserves combined append &>>" do
      assert_roundtrip("command &>> output.txt")
    end

    test "preserves heredoc <<" do
      assert_roundtrip("cat <<EOF\nhello\nEOF")
    end

    test "preserves heredoc with tab stripping <<-" do
      assert_roundtrip("cat <<-EOF\nhello\nEOF")
    end

    test "preserves herestring <<<" do
      assert_roundtrip(~s{cat <<< "hello world"})
    end

    test "preserves multiple redirects" do
      assert_roundtrip("command < input.txt > output.txt 2>&1")
    end
  end

  describe "roundtrip - logical operators" do
    test "preserves pipe |" do
      assert_roundtrip("echo hello | cat")
    end

    test "preserves logical or ||" do
      assert_roundtrip("true || echo failed")
    end

    test "preserves logical and &&" do
      assert_roundtrip("true && echo success")
    end

    test "preserves chained logical operators" do
      assert_roundtrip("cmd1 && cmd2 || cmd3")
    end

    test "preserves pipeline with multiple pipes" do
      assert_roundtrip("cat file | grep pattern | wc -l")
    end
  end

  describe "roundtrip - control structures" do
    test "preserves if statement" do
      assert_roundtrip("if true; then echo yes; fi")
    end

    test "preserves if-else statement" do
      assert_roundtrip("if true; then echo yes; else echo no; fi")
    end

    test "preserves if-elif-else statement" do
      assert_roundtrip("if true; then echo 1; elif false; then echo 2; else echo 3; fi")
    end

    test "preserves for loop with list" do
      assert_roundtrip("for i in 1 2 3; do echo $i; done")
    end

    test "preserves while loop" do
      assert_roundtrip("while true; do echo loop; done")
    end

    test "preserves until loop" do
      assert_roundtrip("until false; do echo loop; done")
    end

    test "preserves case statement" do
      input = """
      case $x in
        a) echo a;;
        b) echo b;;
        *) echo other;;
      esac
      """

      assert_roundtrip(String.trim(input))
    end

    test "preserves while with heredoc redirect" do
      input = """
      while read line; do
        echo "$line"
      done <<EOF
      line1
      line2
      EOF
      """

      assert_roundtrip(String.trim(input))
    end

    test "preserves while with file redirect" do
      assert_roundtrip("while read line; do echo $line; done < file.txt")
    end
  end

  describe "roundtrip - functions" do
    test "preserves function definition with parens" do
      input = """
      foo() {
        echo hello
      }
      """

      assert_roundtrip(String.trim(input))
    end

    test "preserves function keyword syntax" do
      input = """
      function foo {
        echo hello
      }
      """

      assert_roundtrip(String.trim(input))
    end

    test "preserves function with local variables" do
      input = """
      function myfunc {
        local x=1
        echo $x
      }
      """

      assert_roundtrip(String.trim(input))
    end
  end

  describe "roundtrip - subshells and groups" do
    test "preserves subshell" do
      assert_roundtrip("(echo hello; echo world)")
    end

    test "preserves brace group" do
      assert_roundtrip("{ echo hello; echo world; }")
    end
  end

  describe "roundtrip - variable operations" do
    test "preserves simple assignment" do
      assert_roundtrip("x=value")
    end

    test "preserves export" do
      assert_roundtrip("export FOO=bar")
    end

    test "preserves array assignment" do
      assert_roundtrip("arr=(one two three)")
    end

    test "preserves variable expansion" do
      assert_roundtrip("echo $VAR")
    end

    test "preserves braced variable expansion" do
      assert_roundtrip("echo ${VAR}")
    end

    test "preserves default value expansion" do
      assert_roundtrip("echo ${VAR:-default}")
    end

    test "preserves command substitution" do
      assert_roundtrip("echo $(date)")
    end

    test "preserves arithmetic expansion" do
      assert_roundtrip("echo $((1 + 2))")
    end
  end

  describe "roundtrip - test constructs" do
    test "preserves test command [ ]" do
      assert_roundtrip("[ -f file.txt ]")
    end

    test "preserves test expression [[ ]]" do
      assert_roundtrip("[[ -f file.txt ]]")
    end

    test "preserves arithmetic test (( ))" do
      assert_roundtrip("(( x > 5 ))")
    end
  end

  describe "roundtrip - quoting" do
    test "preserves double quotes" do
      assert_roundtrip(~s{echo "hello world"})
    end

    test "preserves single quotes" do
      assert_roundtrip("echo 'hello world'")
    end

    test "preserves escaped characters" do
      assert_roundtrip(~s{echo "hello\\nworld"})
    end
  end

  describe "roundtrip - comments" do
    test "preserves inline comment" do
      assert_roundtrip("echo hello # comment")
    end

    test "preserves standalone comment" do
      assert_roundtrip("# this is a comment")
    end
  end

  describe "blank line preservation" do
    test "preserves single blank line between statements" do
      input = "echo first\n\necho second"
      formatted = Formatter.format(input, [])
      assert formatted =~ "\n\n"
    end

    test "normalizes multiple blank lines to single" do
      input = "echo first\n\n\n\necho second"
      formatted = Formatter.format(input, [])
      refute formatted =~ "\n\n\n"
    end
  end

  describe "complex combinations" do
    test "preserves pipeline with redirects" do
      assert_roundtrip("cat file.txt | grep pattern > output.txt 2>&1")
    end

    test "preserves conditional with redirects" do
      assert_roundtrip("if [ -f file ]; then cat file > out.txt; fi")
    end

    test "preserves function calling function" do
      input = """
      function inner {
        echo inner
      }

      function outer {
        inner
        echo outer
      }
      """

      assert_roundtrip(String.trim(input))
    end

    test "preserves nested loops" do
      input = """
      for i in 1 2; do
        for j in a b; do
          echo $i$j
        done
      done
      """

      assert_roundtrip(String.trim(input))
    end

    test "preserves if inside while" do
      input = """
      while read line; do
        if [ -n "$line" ]; then
          echo "$line"
        fi
      done < file.txt
      """

      assert_roundtrip(String.trim(input))
    end
  end

  # Helper to verify that formatting produces parseable output with same semantics
  defp assert_roundtrip(input) do
    # Parse original
    {:ok, original_ast} = Bash.parse(input)

    # Format
    formatted = Formatter.format(input, [])

    # Parse formatted
    case Bash.parse(formatted) do
      {:ok, formatted_ast} ->
        # Compare serialized forms (which should be equivalent)
        original_str = to_string(original_ast)
        formatted_str = to_string(formatted_ast)

        # Normalize whitespace for comparison
        original_normalized = normalize_for_comparison(original_str)
        formatted_normalized = normalize_for_comparison(formatted_str)

        assert original_normalized == formatted_normalized,
               """
               Roundtrip failed - AST differs after formatting

               Original input:
               #{inspect(input)}

               Formatted output:
               #{inspect(formatted)}

               Original AST string:
               #{inspect(original_str)}

               Formatted AST string:
               #{inspect(formatted_str)}
               """

      {:error, error} ->
        flunk("""
        Formatted output failed to parse

        Original input:
        #{inspect(input)}

        Formatted output:
        #{inspect(formatted)}

        Parse error:
        #{inspect(error)}
        """)
    end
  end

  # Normalize whitespace for comparison (collapse multiple spaces, trim)
  defp normalize_for_comparison(str) do
    str
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n+/, "\n")
    |> String.trim()
  end
end
