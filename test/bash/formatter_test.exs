defmodule Bash.FormatterTest do
  use ExUnit.Case, async: true

  alias Bash.Formatter

  describe "redirect operators" do
    test "input redirect <" do
      assert format("cat < file.txt") == "cat < file.txt"
    end

    test "output redirect >" do
      assert format("echo hello > file.txt") == "echo hello > file.txt"
    end

    test "append redirect >>" do
      assert format("echo hello >> file.txt") == "echo hello >> file.txt"
    end

    test "fd output redirect 2>" do
      assert format("command 2> errors.txt") == "command 2> errors.txt"
    end

    test "fd input redirect 0<" do
      assert format("command 0< input.txt") == "command < input.txt"
    end

    test "fd duplication >&" do
      assert format("command 2>&1") == "command 2>&1"
    end

    test "combined stdout/stderr &>" do
      assert format("command &> output.txt") == "command &> output.txt"
    end

    test "combined append &>>" do
      assert format("command &>> output.txt") == "command &>> output.txt"
    end

    test "heredoc <<" do
      assert format("cat <<EOF\nhello\nEOF") == "cat <<EOF\nhello\nEOF\n"
    end

    test "heredoc with tab stripping <<-" do
      assert format("cat <<-EOF\nhello\nEOF") == "cat <<-EOF\nhello\nEOF\n"
    end

    test "herestring <<<" do
      assert format(~s{cat <<< "hello world"}) == ~s{cat <<< "hello world"}
    end

    test "multiple redirects" do
      assert format("command < input.txt > output.txt 2>&1") ==
               "command < input.txt > output.txt 2>&1"
    end
  end

  describe "logical operators" do
    test "pipe |" do
      assert format("echo hello | cat") == "echo hello | cat"
    end

    test "logical or ||" do
      assert format("true || echo failed") == "true || echo failed"
    end

    test "logical and &&" do
      assert format("true && echo success") == "true && echo success"
    end

    test "chained logical operators" do
      assert format("cmd1 && cmd2 || cmd3") == "cmd1 && cmd2 || cmd3"
    end

    test "pipeline with multiple pipes" do
      assert format("cat file | grep pattern | wc -l") == "cat file | grep pattern | wc -l"
    end
  end

  describe "control structures" do
    test "if statement expands to multiline" do
      assert format("if true; then echo yes; fi") ==
               "if true; then\n  echo yes\nfi"
    end

    test "if-else expands to multiline" do
      assert format("if true; then echo yes; else echo no; fi") ==
               "if true; then\n  echo yes\nelse\n  echo no\nfi"
    end

    test "if-elif-else expands to multiline" do
      assert format("if true; then echo 1; elif false; then echo 2; else echo 3; fi") ==
               "if true; then\n  echo 1\nelif false; then\n  echo 2\nelse\n  echo 3\nfi"
    end

    test "for loop expands to multiline" do
      assert format("for i in 1 2 3; do echo $i; done") ==
               "for i in 1 2 3; do\n  echo $i\ndone"
    end

    test "while loop expands to multiline" do
      assert format("while true; do echo loop; done") ==
               "while true; do\n  echo loop\ndone"
    end

    test "until loop expands to multiline" do
      assert format("until false; do echo loop; done") ==
               "until false; do\n  echo loop\ndone"
    end

    test "case statement" do
      assert format("case $x in\n  a) echo a;;\n  b) echo b;;\n  *) echo other;;\nesac") ==
               "case $x in\n  a)\n    echo a\n    ;;\n  b)\n    echo b\n    ;;\n  *)\n    echo other\n    ;;\nesac"
    end

    test "while with heredoc redirect" do
      input = "while read line; do\n  echo \"$line\"\ndone <<EOF\nline1\nline2\nEOF"

      assert format(input) ==
               "while read line; do\n  echo \"$line\"\ndone <<EOF\nline1\nline2\nEOF\n"
    end

    test "while with file redirect" do
      assert format("while read line; do echo $line; done < file.txt") ==
               "while read line; do\n  echo $line\ndone < file.txt"
    end
  end

  describe "functions" do
    test "parens syntax normalizes to function keyword" do
      assert format("foo() {\n  echo hello\n}") ==
               "function foo {\n  echo hello\n}"
    end

    test "function keyword syntax" do
      assert format("function foo {\n  echo hello\n}") ==
               "function foo {\n  echo hello\n}"
    end

    test "function with local variables" do
      assert format("function myfunc {\n  local x=1\n  echo $x\n}") ==
               "function myfunc {\n  local x=1\n  echo $x\n}"
    end
  end

  describe "subshells and groups" do
    test "subshell" do
      assert format("(echo hello; echo world)") == "(echo hello; echo world)"
    end

    test "brace group" do
      assert format("{ echo hello; echo world; }") == "{ echo hello; echo world; }"
    end
  end

  describe "variable operations" do
    test "simple assignment" do
      assert format("x=value") == "x=value"
    end

    test "export" do
      assert format("export FOO=bar") == "export FOO=bar"
    end

    test "array assignment" do
      assert format("arr=(one two three)") == "arr=(one two three)"
    end

    test "variable expansion" do
      assert format("echo $VAR") == "echo $VAR"
    end

    test "braced variable expansion normalizes to bare" do
      assert format("echo ${VAR}") == "echo $VAR"
    end

    test "default value expansion" do
      assert format("echo ${VAR:-default}") == "echo ${VAR:-default}"
    end

    test "command substitution" do
      assert format("echo $(date)") == "echo $(date)"
    end

    test "arithmetic expansion" do
      assert format("echo $((1 + 2))") == "echo $((1 + 2))"
    end
  end

  describe "test constructs" do
    test "test command [ ]" do
      assert format("[ -f file.txt ]") == "[ -f file.txt ]"
    end

    test "test expression [[ ]]" do
      assert format("[[ -f file.txt ]]") == "[[ -f file.txt ]]"
    end

    test "arithmetic test (( ))" do
      assert format("(( x > 5 ))") == "((  x > 5  ))"
    end
  end

  describe "quoting" do
    test "double quotes" do
      assert format(~s{echo "hello world"}) == ~s{echo "hello world"}
    end

    test "single quotes" do
      assert format("echo 'hello world'") == "echo 'hello world'"
    end

    test "escaped characters" do
      assert format(~s{echo "hello\\nworld"}) == ~s{echo "hello\\nworld"}
    end
  end

  describe "comments" do
    test "inline comment" do
      assert format("echo hello # comment") == "echo hello# comment"
    end

    test "standalone comment" do
      assert format("# this is a comment") == "# this is a comment"
    end
  end

  describe "coproc" do
    test "coproc with default name" do
      assert format("coproc cat") == "coproc cat"
    end

    test "coproc with named process" do
      assert format("coproc mycoproc { cat; }") == "coproc mycoproc { cat; }"
    end
  end

  describe "arithmetic" do
    test "arithmetic assignment" do
      assert format("(( x = 5 + 3 ))") == "((  x = 5 + 3  ))"
    end

    test "arithmetic increment" do
      assert format("(( x++ ))") == "((  x++  ))"
    end

    test "arithmetic comparison" do
      assert format("(( x > 5 ))") == "((  x > 5  ))"
    end

    test "let command" do
      assert format("let x=5+3") == "let x=5+3"
    end
  end

  describe "array operations" do
    test "array literal" do
      assert format("arr=(one two three)") == "arr=(one two three)"
    end

    test "array element assignment" do
      assert format("arr[0]=value") == "arr[0]=value"
    end

    test "array append" do
      assert format("arr+=(four five)") == "arr+=(four five)"
    end

    test "array element access" do
      assert format("echo ${arr[0]}") == "echo ${arr[0]}"
    end

    test "array all elements" do
      assert format("echo ${arr[@]}") == "echo ${arr[@]}"
    end

    test "array length" do
      assert format("echo ${#arr[@]}") == "echo ${#arr[@]}"
    end
  end

  describe "process substitution" do
    test "input process substitution" do
      assert format("diff <(sort file1) <(sort file2)") ==
               "diff <(sort file1) <(sort file2)"
    end

    test "output process substitution" do
      assert format("tee >(grep error > errors.log)") ==
               "tee >(grep error > errors.log)"
    end
  end

  describe "parameter expansion" do
    test "substring removal #" do
      assert format("echo ${var#pattern}") == "echo ${var#pattern}"
    end

    test "greedy substring removal ##" do
      assert format("echo ${var##pattern}") == "echo ${var##pattern}"
    end

    test "suffix removal %" do
      assert format("echo ${var%pattern}") == "echo ${var%pattern}"
    end

    test "greedy suffix removal %%" do
      assert format("echo ${var%%pattern}") == "echo ${var%%pattern}"
    end

    test "substitution /" do
      assert format("echo ${var/old/new}") == "echo ${var/old/new}"
    end

    test "global substitution //" do
      assert format("echo ${var//old/new}") == "echo ${var//old/new}"
    end

    test "string length #" do
      assert format("echo ${#var}") == "echo ${#var}"
    end

    test "assign if unset :=" do
      assert format("echo ${var:=default}") == "echo ${var:=default}"
    end

    test "error if unset :?" do
      assert format("echo ${var:?error message}") == "echo ${var:?error message}"
    end

    test "use alternative :+" do
      assert format("echo ${var:+alternative}") == "echo ${var:+alternative}"
    end

    test "substring extraction :0:5" do
      assert format("echo ${var:0:5}") == "echo ${var:0:5}"
    end
  end

  describe "special constructs" do
    test "negated command" do
      assert format("! grep -q pattern file") == "! grep -q pattern file"
    end

    test "background job" do
      assert format("sleep 10 &") == "sleep 10 &"
    end

    test "semicolon-separated commands" do
      assert format("echo a; echo b; echo c") == "echo a; echo b; echo c"
    end

    test "command with env var prefix" do
      assert format("FOO=bar command") == "FOO=bar command"
    end
  end

  describe "shebang" do
    test "preserves #!/bin/bash" do
      assert format("#!/bin/bash\necho hello") == "#!/bin/bash\necho hello"
    end

    test "preserves #!/usr/bin/env bash" do
      assert format("#!/usr/bin/env bash\necho hello") == "#!/usr/bin/env bash\necho hello"
    end
  end

  describe "blank line handling" do
    test "preserves single blank line between statements" do
      assert format("echo first\n\necho second") == "echo first\n\necho second"
    end

    test "normalizes multiple blank lines to single" do
      assert format("echo first\n\n\n\necho second") == "echo first\n\necho second"
    end
  end

  describe "complex combinations" do
    test "pipeline with redirects" do
      assert format("cat file.txt | grep pattern > output.txt 2>&1") ==
               "cat file.txt | grep pattern > output.txt 2>&1"
    end

    test "conditional with redirects" do
      assert format("if [ -f file ]; then cat file > out.txt; fi") ==
               "if [ -f file ]; then\n  cat file > out.txt\nfi"
    end

    test "function calling function" do
      input = "function inner {\n  echo inner\n}\n\nfunction outer {\n  inner\n  echo outer\n}"

      assert format(input) == input
    end

    test "nested loops" do
      input = "for i in 1 2; do\n  for j in a b; do\n    echo $i$j\n  done\ndone"
      assert format(input) == input
    end

    test "if inside while" do
      input =
        "while read line; do\n  if [ -n \"$line\" ]; then\n    echo \"$line\"\n  fi\ndone < file.txt"

      assert format(input) == input
    end
  end

  describe "tab indentation" do
    test "single level" do
      assert format("if true; then\n  echo yes\nfi", indent_style: :tabs) ==
               "if true; then\n\techo yes\nfi"
    end

    test "nested levels" do
      input = "for i in 1 2; do\n  if true; then\n    echo $i\n  fi\ndone"

      assert format(input, indent_style: :tabs) ==
               "for i in 1 2; do\n\tif true; then\n\t\techo $i\n\tfi\ndone"
    end
  end

  describe "indent width" do
    test "4-space indent single level" do
      assert format("if true; then\n  echo yes\nfi", indent_width: 4) ==
               "if true; then\n    echo yes\nfi"
    end

    test "4-space indent nested" do
      input = "for i in 1 2; do\n  if true; then\n    echo $i\n  fi\ndone"

      assert format(input, indent_width: 4) ==
               "for i in 1 2; do\n    if true; then\n        echo $i\n    fi\ndone"
    end
  end

  describe "line wrapping" do
    test "wraps long pipeline" do
      input =
        "cat very_long_filename.txt | grep some_pattern | sort | uniq -c | sort -rn | head -20"

      assert format(input, line_length: 50) ==
               "cat very_long_filename.txt | grep some_pattern | \\\n  sort | uniq -c | sort -rn | head -20"
    end

    test "does not wrap short lines" do
      assert format("echo hello | cat", line_length: 80) == "echo hello | cat"
    end

    test "wraps at logical operators" do
      input =
        "very_long_command_name --with-flag arg1 && another_long_command --flag arg2 || fallback_command --flag arg3"

      assert format(input, line_length: 60) ==
               "very_long_command_name --with-flag arg1 && \\\n  another_long_command --flag arg2 || \\\n  fallback_command --flag arg3"
    end
  end

  describe "sigil mode" do
    test "does not add trailing newline" do
      assert Formatter.format("echo hello", sigil: :BASH) == "echo hello"
    end
  end

  describe "brace expansion" do
    test "comma-separated brace expansion" do
      assert format("echo {a,b,c}") == "echo {a,b,c}"
    end

    test "sequence brace expansion" do
      assert format("echo {1..10}") == "echo {1..10}"
    end

    test "nested brace expansion" do
      assert format("echo {a,{b,c}}") == "echo {a,{b,c}}"
    end
  end

  describe "regex pattern" do
    test "regex in test expression" do
      assert format("[[ $x =~ ^[0-9]+$ ]]") == "[[ $x =~ ^[0-9]+\\$ ]]"
    end
  end

  describe "graceful degradation" do
    test "returns input unchanged on parse error" do
      input = "if then fi done esac"
      assert format(input) == input
    end
  end

  describe "AST roundtrip - formatted output parses to equivalent AST" do
    @roundtrip_inputs %{
      "simple command" => "echo hello world",
      "pipeline" => "cat file | grep pattern | wc -l",
      "compound &&" => "cmd1 && cmd2 && cmd3",
      "compound ||" => "cmd1 || cmd2 || cmd3",
      "mixed compound" => "cmd1 && cmd2 || cmd3",
      "if" => "if true; then echo yes; fi",
      "if-else" => "if true; then echo yes; else echo no; fi",
      "if-elif-else" =>
        "if true; then echo 1; elif false; then echo 2; else echo 3; fi",
      "for loop" => "for i in 1 2 3; do echo $i; done",
      "while loop" => "while true; do echo loop; done",
      "until loop" => "until false; do echo loop; done",
      "case" => "case $x in\n  a) echo a;;\n  *) echo other;;\nesac",
      "function" => "function foo {\n  echo hello\n}",
      "subshell" => "(echo hello; echo world)",
      "brace group" => "{ echo hello; echo world; }",
      "assignment" => "x=value",
      "export" => "export FOO=bar",
      "array literal" => "arr=(one two three)",
      "array element" => "arr[0]=value",
      "array append" => "arr+=(four)",
      "variable expansion" => "echo $VAR",
      "parameter default" => "echo ${VAR:-default}",
      "parameter substring" => "echo ${var#pattern}",
      "parameter substitution" => "echo ${var/old/new}",
      "parameter length" => "echo ${#var}",
      "command substitution" => "echo $(date)",
      "arithmetic expansion" => "echo $((1 + 2))",
      "arithmetic statement" => "(( x = 5 + 3 ))",
      "let" => "let x=5+3",
      "test command" => "[ -f file.txt ]",
      "test expression" => "[[ -f file.txt ]]",
      "redirect out" => "echo hello > file.txt",
      "redirect append" => "echo hello >> file.txt",
      "redirect in" => "cat < file.txt",
      "redirect fd dup" => "command 2>&1",
      "redirect combined" => "command &> output.txt",
      "heredoc" => "cat <<EOF\nhello\nEOF",
      "herestring" => ~s{cat <<< "hello world"},
      "coproc" => "coproc cat",
      "coproc named" => "coproc mycoproc { cat; }",
      "brace expand" => "echo {a,b,c}",
      "process substitution" => "diff <(sort file1) <(sort file2)",
      "background" => "sleep 10 &",
      "negation" => "! grep -q pattern file",
      "comment" => "# this is a comment",
      "double quotes" => ~s{echo "hello world"},
      "single quotes" => "echo 'hello world'",
      "nested loops" =>
        "for i in 1 2; do\n  for j in a b; do\n    echo $i$j\n  done\ndone",
      "pipeline with redirects" =>
        "cat file.txt | grep pattern > output.txt 2>&1"
    }

    for {label, input} <- @roundtrip_inputs do
      @tag input: input
      test "#{label}", %{input: input} do
        formatted = format(input)

        {:ok, original_ast} = Bash.parse(input)
        {:ok, formatted_ast} = Bash.parse(formatted)

        original_normalized = original_ast |> to_string() |> normalize_whitespace()
        formatted_normalized = formatted_ast |> to_string() |> normalize_whitespace()

        assert original_normalized == formatted_normalized,
               """
               AST roundtrip failed for: #{inspect(input)}

               Formatted: #{inspect(formatted)}
               Original AST:  #{inspect(to_string(original_ast))}
               Formatted AST: #{inspect(to_string(formatted_ast))}
               """
      end
    end
  end

  defp format(input, bash_opts \\ []) do
    Formatter.format(input, bash: bash_opts)
  end

  defp normalize_whitespace(str) do
    str
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n+/, "\n")
    |> String.trim()
  end
end
