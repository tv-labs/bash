defmodule Bash.TokenizerTest do
  use ExUnit.Case, async: true

  alias Bash.Tokenizer

  describe "tokenize/1 basic tokens" do
    test "simple word" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo")
      assert [{:word, [{:literal, "echo"}], 1, 1}, {:eof, 1, 5}] = tokens
    end

    test "multiple words" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo hello world")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:literal, "hello"}], 1, 6},
               {:word, [{:literal, "world"}], 1, 12},
               {:eof, 1, 17}
             ] = tokens
    end

    test "reserved words" do
      assert {:ok, tokens} = Tokenizer.tokenize("if then else elif fi")

      assert [
               {:if, 1, 1},
               {:then, 1, 4},
               {:else, 1, 9},
               {:elif, 1, 14},
               {:fi, 1, 19},
               {:eof, 1, 21}
             ] = tokens
    end

    test "newlines" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo\necho")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:newline, 1, 5},
               {:word, [{:literal, "echo"}], 2, 1},
               {:eof, 2, 5}
             ] = tokens
    end

    test "comment" do
      assert {:ok, tokens} = Tokenizer.tokenize("# this is a comment")
      assert [{:comment, " this is a comment", 1, 1}, {:eof, 1, 20}] = tokens
    end

    test "comment followed by newline and command" do
      assert {:ok, tokens} = Tokenizer.tokenize("# comment\necho")

      assert [
               {:comment, " comment", 1, 1},
               {:newline, 1, 10},
               {:word, [{:literal, "echo"}], 2, 1},
               {:eof, 2, 5}
             ] = tokens
    end
  end

  describe "tokenize/1 operators" do
    test "pipe" do
      assert {:ok, tokens} = Tokenizer.tokenize("a | b")

      assert [
               {:word, [{:literal, "a"}], 1, 1},
               {:pipe, 1, 3},
               {:word, [{:literal, "b"}], 1, 5},
               {:eof, 1, 6}
             ] = tokens
    end

    test "or_if (||)" do
      assert {:ok, tokens} = Tokenizer.tokenize("a || b")

      assert [
               {:word, [{:literal, "a"}], 1, 1},
               {:or_if, 1, 3},
               {:word, [{:literal, "b"}], 1, 6},
               {:eof, 1, 7}
             ] = tokens
    end

    test "and_if (&&)" do
      assert {:ok, tokens} = Tokenizer.tokenize("a && b")

      assert [
               {:word, [{:literal, "a"}], 1, 1},
               {:and_if, 1, 3},
               {:word, [{:literal, "b"}], 1, 6},
               {:eof, 1, 7}
             ] = tokens
    end

    test "background (&)" do
      assert {:ok, tokens} = Tokenizer.tokenize("a &")

      assert [
               {:word, [{:literal, "a"}], 1, 1},
               {:background, 1, 3},
               {:eof, 1, 4}
             ] = tokens
    end

    test "semicolon" do
      assert {:ok, tokens} = Tokenizer.tokenize("a; b")

      assert [
               {:word, [{:literal, "a"}], 1, 1},
               {:semi, 1, 2},
               {:word, [{:literal, "b"}], 1, 4},
               {:eof, 1, 5}
             ] = tokens
    end

    test "double semicolon (;;)" do
      assert {:ok, tokens} = Tokenizer.tokenize(";;")
      assert [{:dsemi, 1, 1}, {:eof, 1, 3}] = tokens
    end

    test "semi_and (;&)" do
      assert {:ok, tokens} = Tokenizer.tokenize(";&")
      assert [{:semi_and, 1, 1}, {:eof, 1, 3}] = tokens
    end

    test "dsemi_and (;;&)" do
      assert {:ok, tokens} = Tokenizer.tokenize(";;&")
      assert [{:dsemi_and, 1, 1}, {:eof, 1, 4}] = tokens
    end

    test "parentheses" do
      assert {:ok, tokens} = Tokenizer.tokenize("(a)")

      assert [
               {:lparen, 1, 1},
               {:word, [{:literal, "a"}], 1, 2},
               {:rparen, 1, 3},
               {:eof, 1, 4}
             ] = tokens
    end

    test "braces" do
      assert {:ok, tokens} = Tokenizer.tokenize("{ a; }")

      assert [
               {:lbrace, 1, 1},
               {:word, [{:literal, "a"}], 1, 3},
               {:semi, 1, 4},
               {:rbrace, 1, 6},
               {:eof, 1, 7}
             ] = tokens
    end

    test "double parentheses (arithmetic)" do
      # Complete arithmetic command
      assert {:ok, tokens} = Tokenizer.tokenize("((x+1))")
      assert [{:arith_command, "x+1", 1, 1}, {:eof, 1, 8}] = tokens

      # Unclosed arithmetic command
      assert {:error, "unterminated arithmetic command", 1, 1} = Tokenizer.tokenize("((x+1")
    end

    test "bang (!)" do
      assert {:ok, tokens} = Tokenizer.tokenize("! cmd")

      assert [
               {:bang, 1, 1},
               {:word, [{:literal, "cmd"}], 1, 3},
               {:eof, 1, 6}
             ] = tokens
    end
  end

  describe "tokenize/1 redirections" do
    test "input redirect (<)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd < file")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:less, 0, 1, 5},
               {:word, [{:literal, "file"}], 1, 7},
               {:eof, 1, 11}
             ] = tokens
    end

    test "output redirect (>)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd > file")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:greater, 1, 1, 5},
               {:word, [{:literal, "file"}], 1, 7},
               {:eof, 1, 11}
             ] = tokens
    end

    test "append redirect (>>)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd >> file")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:dgreater, 1, 1, 5},
               {:word, [{:literal, "file"}], 1, 8},
               {:eof, 1, 12}
             ] = tokens
    end

    test "heredoc (<<)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd << EOF")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:dless, 0, 1, 5},
               {:word, [{:literal, "EOF"}], 1, 8},
               {:eof, 1, 11}
             ] = tokens
    end

    test "heredoc with dash (<<-)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd <<- EOF")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:dlessdash, 0, 1, 5},
               {:word, [{:literal, "EOF"}], 1, 9},
               {:eof, 1, 12}
             ] = tokens
    end

    test "herestring (<<<)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd <<< word")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:tless, 0, 1, 5},
               {:word, [{:literal, "word"}], 1, 9},
               {:eof, 1, 13}
             ] = tokens
    end

    test "fd duplication (<&)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd <& 0")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:lessand, 0, 1, 5},
               {:word, [{:literal, "0"}], 1, 8},
               {:eof, 1, 9}
             ] = tokens
    end

    test "fd duplication (>&)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd >& 2")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:greaterand, 1, 1, 5},
               {:word, [{:literal, "2"}], 1, 8},
               {:eof, 1, 9}
             ] = tokens
    end

    test "both redirect (&>)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd &> file")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:andgreat, 1, 5},
               {:word, [{:literal, "file"}], 1, 8},
               {:eof, 1, 12}
             ] = tokens
    end

    test "both append redirect (&>>)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd &>> file")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:anddgreat, 1, 5},
               {:word, [{:literal, "file"}], 1, 9},
               {:eof, 1, 13}
             ] = tokens
    end
  end

  describe "tokenize/1 test brackets" do
    test "single brackets" do
      assert {:ok, tokens} = Tokenizer.tokenize("[ -f file ]")

      assert [
               {:lbracket, 1, 1},
               {:word, [{:literal, "-f"}], 1, 3},
               {:word, [{:literal, "file"}], 1, 6},
               {:rbracket, 1, 11},
               {:eof, 1, 12}
             ] = tokens
    end

    test "double brackets" do
      assert {:ok, tokens} = Tokenizer.tokenize("[[ -f file ]]")

      assert [
               {:dlbracket, 1, 1},
               {:word, [{:literal, "-f"}], 1, 4},
               {:word, [{:literal, "file"}], 1, 7},
               {:drbracket, 1, 12},
               {:eof, 1, 14}
             ] = tokens
    end
  end

  describe "tokenize/1 quoting" do
    test "single quoted string" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo 'hello world'")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:single_quoted, "hello world"}], 1, 6},
               {:eof, 1, 19}
             ] = tokens
    end

    test "double quoted string" do
      assert {:ok, tokens} = Tokenizer.tokenize(~s(echo "hello world"))

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:double_quoted, [{:literal, "hello world"}]}], 1, 6},
               {:eof, 1, 19}
             ] = tokens
    end

    test "escaped characters in double quotes" do
      assert {:ok, tokens} = Tokenizer.tokenize(~s(echo "hello\\"world"))

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:double_quoted, [{:literal, "hello\"world"}]}], 1, 6},
               {:eof, 1, 20}
             ] = tokens
    end

    test "unterminated single quote returns error" do
      assert {:error, "unterminated single quote", 1, 6} = Tokenizer.tokenize("echo 'hello")
    end

    test "unterminated double quote returns error" do
      assert {:error, "unterminated double quote", 1, 6} = Tokenizer.tokenize(~s(echo "hello))
    end

    test "backslash escape outside quotes" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo hello\\ world")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:literal, "hello world"}], 1, 6},
               {:eof, 1, 18}
             ] = tokens
    end
  end

  describe "tokenize/1 line continuation" do
    test "backslash-newline between tokens is skipped" do
      # Backslash-newline at top level should be treated as whitespace
      assert {:ok, tokens} = Tokenizer.tokenize("echo \\\nhello")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:literal, "hello"}], 2, 1},
               {:eof, 2, 6}
             ] = tokens
    end

    test "backslash-newline after pipe continues pipeline" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo hello | \\\n  cat")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:literal, "hello"}], 1, 6},
               {:pipe, 1, 12},
               {:word, [{:literal, "cat"}], 2, 3},
               {:eof, 2, 6}
             ] = tokens
    end

    test "backslash-newline with multiple continuation lines" do
      assert {:ok, tokens} = Tokenizer.tokenize("a | \\\n  \\\n  b")

      assert [
               {:word, [{:literal, "a"}], 1, 1},
               {:pipe, 1, 3},
               {:word, [{:literal, "b"}], 3, 3},
               {:eof, 3, 4}
             ] = tokens
    end

    test "backslash followed by non-newline is not continuation" do
      # Backslash followed by space is escape, not continuation
      assert {:ok, tokens} = Tokenizer.tokenize("echo hello\\ world")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:literal, "hello world"}], 1, 6},
               {:eof, 1, 18}
             ] = tokens
    end
  end

  describe "tokenize/1 variables" do
    test "simple variable" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo $VAR")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable, "VAR"}], 1, 6},
               {:eof, 1, 10}
             ] = tokens
    end

    test "special variables" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo $? $$ $! $# $@ $* $0 $1 $_")

      # Check each special var is captured
      word_parts =
        tokens
        |> Enum.filter(fn
          {:word, _, _, _} -> true
          _ -> false
        end)
        |> Enum.flat_map(fn {:word, parts, _, _} -> parts end)
        |> Enum.filter(fn {type, _} -> type == :variable end)
        |> Enum.map(fn {:variable, name} -> name end)

      assert word_parts == ["?", "$", "!", "#", "@", "*", "0", "1", "_"]
    end

    test "braced variable" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", []}], 1, 6},
               {:eof, 1, 12}
             ] = tokens
    end

    test "variable with default" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR:-default}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [default: "default"]}], 1, 6},
               {:eof, 1, 21}
             ] = tokens
    end

    test "variable with assign default" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR:=value}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [assign_default: "value"]}], 1, 6},
               {:eof, 1, 19}
             ] = tokens
    end

    test "variable with error" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR:?message}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [error: "message"]}], 1, 6},
               {:eof, 1, 21}
             ] = tokens
    end

    test "variable with alternate" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR:+alt}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [alternate: "alt"]}], 1, 6},
               {:eof, 1, 17}
             ] = tokens
    end

    test "variable length" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${#VAR}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [length: true]}], 1, 6},
               {:eof, 1, 13}
             ] = tokens
    end

    test "variable prefix removal" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR#pattern}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [{:remove_prefix, "pattern", :shortest}]}], 1,
                6},
               {:eof, 1, 20}
             ] = tokens
    end

    test "variable suffix removal" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR%%pattern}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [{:remove_suffix, "pattern", :longest}]}], 1,
                6},
               {:eof, 1, 21}
             ] = tokens
    end

    test "variable substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR/old/new}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [{:substitute, "old", "new", :first}]}], 1, 6},
               {:eof, 1, 20}
             ] = tokens
    end

    test "variable global substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR//old/new}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [{:substitute, "old", "new", :all}]}], 1, 6},
               {:eof, 1, 21}
             ] = tokens
    end

    test "variable substring" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${VAR:1:3}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "VAR", [{:substring, 1, 3}]}], 1, 6},
               {:eof, 1, 16}
             ] = tokens
    end

    test "variable array subscript" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${ARR[0]}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "ARR", [subscript: {:index, "0"}]}], 1, 6},
               {:eof, 1, 15}
             ] = tokens
    end

    test "variable array all values" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo ${ARR[@]}")

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:variable_braced, "ARR", [subscript: :all_values]}], 1, 6},
               {:eof, 1, 15}
             ] = tokens
    end

    test "variable in double quotes" do
      assert {:ok, tokens} = Tokenizer.tokenize(~s(echo "$VAR"))

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:double_quoted, [{:variable, "VAR"}]}], 1, 6},
               {:eof, 1, 12}
             ] = tokens
    end
  end

  describe "tokenize/1 command substitution" do
    test "dollar paren command substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo $(pwd)")

      # Command substitution now contains recursively tokenized content
      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:command_subst, [{:word, [{:literal, "pwd"}], 1, 8}]}], 1, 6},
               {:eof, 1, 12}
             ] = tokens
    end

    test "backtick command substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo `pwd`")

      # Backticks still use raw string (not recursively tokenized)
      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:backtick, "pwd"}], 1, 6},
               {:eof, 1, 11}
             ] = tokens
    end

    test "nested command substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("echo $(echo $(pwd))")

      # Nested command substitutions are recursively tokenized
      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word,
                [
                  {:command_subst,
                   [
                     {:word, [{:literal, "echo"}], 1, 8},
                     {:word, [{:command_subst, [{:word, [{:literal, "pwd"}], 1, 15}]}], 1, 13}
                   ]}
                ], 1, 6},
               {:eof, 1, 20}
             ] = tokens
    end

    test "command substitution in double quotes" do
      assert {:ok, tokens} = Tokenizer.tokenize(~s[echo "$(pwd)"])

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word,
                [{:double_quoted, [{:command_subst, [{:word, [{:literal, "pwd"}], 1, 9}]}]}], 1,
                6},
               {:eof, 1, 14}
             ] = tokens
    end
  end

  describe "tokenize/1 arithmetic expansion" do
    test "arithmetic expansion" do
      assert {:ok, tokens} = Tokenizer.tokenize(~S[echo $((1 + 2))])

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:arith_expand, "1 + 2"}], 1, 6},
               {:eof, 1, 16}
             ] = tokens
    end

    test "nested parentheses in arithmetic" do
      assert {:ok, tokens} = Tokenizer.tokenize(~S[echo $((x * (y + z)))])

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word, [{:arith_expand, "x * (y + z)"}], 1, 6},
               {:eof, 1, 22}
             ] = tokens
    end
  end

  describe "tokenize/1 assignments" do
    test "simple assignment" do
      assert {:ok, tokens} = Tokenizer.tokenize("VAR=value")
      assert [{:assignment_word, "VAR", [{:literal, "value"}], 1, 1}, {:eof, 1, 10}] = tokens
    end

    test "assignment with quoted value" do
      assert {:ok, tokens} = Tokenizer.tokenize(~s(VAR="hello world"))

      assert [
               {:assignment_word, "VAR", [{:double_quoted, [{:literal, "hello world"}]}], 1, 1},
               {:eof, 1, 18}
             ] = tokens
    end

    test "assignment with variable" do
      assert {:ok, tokens} = Tokenizer.tokenize("VAR=$OTHER")

      assert [
               {:assignment_word, "VAR", [{:variable, "OTHER"}], 1, 1},
               {:eof, 1, 11}
             ] = tokens
    end

    test "empty assignment" do
      assert {:ok, tokens} = Tokenizer.tokenize("VAR=")
      assert [{:assignment_word, "VAR", [], 1, 1}, {:eof, 1, 5}] = tokens
    end
  end

  describe "tokenize/1 complex cases" do
    test "if statement" do
      assert {:ok, tokens} = Tokenizer.tokenize("if true; then echo yes; fi")

      assert [
               {:if, 1, 1},
               {:word, [{:literal, "true"}], 1, 4},
               {:semi, 1, 8},
               {:then, 1, 10},
               {:word, [{:literal, "echo"}], 1, 15},
               {:word, [{:literal, "yes"}], 1, 20},
               {:semi, 1, 23},
               {:fi, 1, 25},
               {:eof, 1, 27}
             ] = tokens
    end

    test "for loop" do
      assert {:ok, tokens} = Tokenizer.tokenize("for i in a b c; do echo $i; done")

      assert [
               {:for, 1, 1},
               {:word, [{:literal, "i"}], 1, 5},
               {:in, 1, 7},
               {:word, [{:literal, "a"}], 1, 10},
               {:word, [{:literal, "b"}], 1, 12},
               {:word, [{:literal, "c"}], 1, 14},
               {:semi, 1, 15},
               {:do, 1, 17},
               {:word, [{:literal, "echo"}], 1, 20},
               {:word, [{:variable, "i"}], 1, 25},
               {:semi, 1, 27},
               {:done, 1, 29},
               {:eof, 1, 33}
             ] = tokens
    end

    test "pipeline with redirection" do
      assert {:ok, tokens} = Tokenizer.tokenize("cat file | grep pattern > output")

      assert [
               {:word, [{:literal, "cat"}], 1, 1},
               {:word, [{:literal, "file"}], 1, 5},
               {:pipe, 1, 10},
               {:word, [{:literal, "grep"}], 1, 12},
               {:word, [{:literal, "pattern"}], 1, 17},
               {:greater, 1, 1, 25},
               {:word, [{:literal, "output"}], 1, 27},
               {:eof, 1, 33}
             ] = tokens
    end

    test "mixed quoting in word" do
      assert {:ok, tokens} = Tokenizer.tokenize(~s(echo 'single'"double"$VAR))

      assert [
               {:word, [{:literal, "echo"}], 1, 1},
               {:word,
                [
                  {:single_quoted, "single"},
                  {:double_quoted, [{:literal, "double"}]},
                  {:variable, "VAR"}
                ], 1, 6},
               {:eof, 1, 26}
             ] = tokens
    end
  end

  describe "tokenize/1 process substitution" do
    test "input process substitution <(...)" do
      assert {:ok, tokens} = Tokenizer.tokenize("cat <(echo hello)")

      # Process substitution now contains recursively tokenized content
      assert [
               {:word, [{:literal, "cat"}], 1, 1},
               {:word,
                [
                  {:process_subst_in,
                   [{:word, [{:literal, "echo"}], 1, 7}, {:word, [{:literal, "hello"}], 1, 12}]}
                ], 1, 5},
               {:eof, 1, 18}
             ] = tokens
    end

    test "output process substitution >(...)" do
      assert {:ok, tokens} = Tokenizer.tokenize("tee >(cat > /dev/null)")

      assert [
               {:word, [{:literal, "tee"}], 1, 1},
               {:word,
                [
                  {:process_subst_out,
                   [
                     {:word, [{:literal, "cat"}], 1, 7},
                     {:greater, 1, 1, 11},
                     {:word, [{:literal, "/dev/null"}], 1, 13}
                   ]}
                ], 1, 5},
               {:eof, 1, 23}
             ] = tokens
    end

    test "nested process substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("diff <(sort file1) <(sort file2)")

      # Process substitutions now contain recursively tokenized content
      assert [
               {:word, [{:literal, "diff"}], 1, 1},
               {:word,
                [
                  {:process_subst_in,
                   [{:word, [{:literal, "sort"}], 1, 8}, {:word, [{:literal, "file1"}], 1, 13}]}
                ], 1, 6},
               {:word,
                [
                  {:process_subst_in,
                   [{:word, [{:literal, "sort"}], 1, 22}, {:word, [{:literal, "file2"}], 1, 27}]}
                ], 1, 20},
               {:eof, 1, 33}
             ] = tokens
    end

    test "process substitution with pipes inside" do
      assert {:ok, tokens} = Tokenizer.tokenize("cat <(echo foo | sort)")

      # Process substitution now contains recursively tokenized content including pipe
      assert [
               {:word, [{:literal, "cat"}], 1, 1},
               {:word,
                [
                  {:process_subst_in,
                   [
                     {:word, [{:literal, "echo"}], 1, 7},
                     {:word, [{:literal, "foo"}], 1, 12},
                     {:pipe, 1, 16},
                     {:word, [{:literal, "sort"}], 1, 18}
                   ]}
                ], 1, 5},
               {:eof, 1, 23}
             ] = tokens
    end

    test "process substitution with nested parens" do
      assert {:ok, tokens} = Tokenizer.tokenize("cat <(echo $(pwd))")

      # Process substitution with nested command substitution
      assert [
               {:word, [{:literal, "cat"}], 1, 1},
               {:word,
                [
                  {:process_subst_in,
                   [
                     {:word, [{:literal, "echo"}], 1, 7},
                     {:word, [{:command_subst, [{:word, [{:literal, "pwd"}], 1, 14}]}], 1, 12}
                   ]}
                ], 1, 5},
               {:eof, 1, 19}
             ] = tokens
    end

    test "both input and output process substitution" do
      assert {:ok, tokens} = Tokenizer.tokenize("cmd <(input) >(output)")

      assert [
               {:word, [{:literal, "cmd"}], 1, 1},
               {:word, [{:process_subst_in, [{:word, [{:literal, "input"}], 1, 7}]}], 1, 5},
               {:word, [{:process_subst_out, [{:word, [{:literal, "output"}], 1, 16}]}], 1, 14},
               {:eof, 1, 23}
             ] = tokens
    end
  end

  describe "unicode lookalike detection" do
    test "rejects left curly double quote (SC1015)" do
      # U+201C left double quotation mark at start of token
      assert {:error, msg, 1, 6} = Tokenizer.tokenize("echo \u201Chello")
      assert msg =~ "SC1015"
      assert msg =~ "double quote"
    end

    test "rejects right curly double quote in word (SC1015)" do
      # U+201D right double quotation mark inside a word
      assert {:error, msg, 1, 9} = Tokenizer.tokenize("echo hel\u201Dlo")
      assert msg =~ "SC1015"
    end

    test "rejects left curly single quote (SC1016)" do
      # U+2018 left single quotation mark at start of token
      assert {:error, msg, 1, 6} = Tokenizer.tokenize("echo \u2018hello")
      assert msg =~ "SC1016"
      assert msg =~ "single quote"
    end

    test "rejects right curly single quote in word (SC1016)" do
      # U+2019 right single quotation mark inside a word
      assert {:error, msg, 1, 9} = Tokenizer.tokenize("echo hel\u2019lo")
      assert msg =~ "SC1016"
    end

    test "rejects non-breaking space in word (SC1018)" do
      # U+00A0 non-breaking space inside a word
      assert {:error, msg, 1, 5} = Tokenizer.tokenize("echo\u00A0hello")
      assert msg =~ "SC1018"
      assert msg =~ "non-breaking space"
    end

    test "rejects en-dash (SC1100)" do
      # U+2013 en-dash instead of hyphen
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("\u2013flag")
      assert msg =~ "SC1100"
      assert msg =~ "en-dash"
    end

    test "rejects em-dash (SC1100)" do
      # U+2014 em-dash instead of hyphen
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("\u2014flag")
      assert msg =~ "SC1100"
      assert msg =~ "em-dash"
    end

    test "accepts valid ASCII quotes" do
      assert {:ok, _tokens} = Tokenizer.tokenize("echo \"hello\"")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo 'hello'")
    end
  end

  describe "positional parameter detection (SC1037)" do
    test "rejects $10 - suggests ${10}" do
      assert {:error, msg, 1, 6} = Tokenizer.tokenize("echo $10")
      assert msg =~ "SC1037"
      assert msg =~ "$10"
      assert msg =~ "${10}"
    end

    test "rejects $99 - suggests ${99}" do
      assert {:error, msg, 1, 6} = Tokenizer.tokenize("echo $99")
      assert msg =~ "SC1037"
      assert msg =~ "$99"
      assert msg =~ "${99}"
    end

    test "rejects $123 - suggests ${123}" do
      assert {:error, msg, 1, 6} = Tokenizer.tokenize("echo $123")
      assert msg =~ "SC1037"
      assert msg =~ "$123"
      assert msg =~ "${123}"
    end

    test "accepts single digit positional params" do
      assert {:ok, _tokens} = Tokenizer.tokenize("echo $1")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo $9")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo $0")
    end

    test "accepts braced multi-digit params" do
      assert {:ok, _tokens} = Tokenizer.tokenize("echo ${10}")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo ${99}")
    end
  end

  describe "assignment error detection (SC1066)" do
    test "rejects $VAR=value" do
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("$VAR=hello")
      assert msg =~ "SC1066"
      assert msg =~ "VAR=value"
      assert msg =~ "$VAR=value"
    end

    test "rejects $FOO=" do
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("$FOO=")
      assert msg =~ "SC1066"
    end

    test "accepts normal variable expansion" do
      assert {:ok, _tokens} = Tokenizer.tokenize("echo $VAR")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo $FOO")
    end

    test "accepts normal assignment" do
      assert {:ok, tokens} = Tokenizer.tokenize("VAR=hello")
      assert [{:assignment_word, "VAR", [{:literal, "hello"}], 1, 1}, {:eof, 1, 10}] = tokens
    end
  end

  describe "shebang validation" do
    test "SC1082: rejects UTF-8 BOM at start" do
      # UTF-8 BOM followed by shebang
      input = <<0xEF, 0xBB, 0xBF, "#!/bin/bash"::binary>>
      assert {:error, msg, 1, 1} = Tokenizer.tokenize(input)
      assert msg =~ "SC1082"
      assert msg =~ "BOM"
    end

    test "SC1084: rejects !# instead of #!" do
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("!#/bin/bash")
      assert msg =~ "SC1084"
      assert msg =~ "!#"
    end

    test "SC1114: rejects leading whitespace before shebang" do
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("  #!/bin/bash")
      assert msg =~ "SC1114"
      assert msg =~ "whitespace"
    end

    test "SC1114: rejects tab before shebang" do
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("\t#!/bin/bash")
      assert msg =~ "SC1114"
    end

    test "SC1115: rejects space between # and !" do
      assert {:error, msg, 1, 1} = Tokenizer.tokenize("# !/bin/bash")
      assert msg =~ "SC1115"
      assert msg =~ "Space"
    end

    test "SC1128: rejects shebang not on first line" do
      assert {:error, msg, 2, 1} = Tokenizer.tokenize("# comment\n#!/bin/bash")
      assert msg =~ "SC1128"
      assert msg =~ "first line"
    end

    test "accepts valid shebang" do
      assert {:ok, tokens} = Tokenizer.tokenize("#!/bin/bash\necho hello")
      assert [{:shebang, "/bin/bash", 1, 1}, {:newline, 1, 12} | _rest] = tokens
    end

    test "accepts script without shebang" do
      assert {:ok, _tokens} = Tokenizer.tokenize("echo hello")
    end
  end

  describe "assignment spacing errors" do
    test "SC1007: rejects space after = in assignment" do
      assert {:error, msg, 1, 6} = Tokenizer.tokenize("VAR= value")
      assert msg =~ "SC1007"
      assert msg =~ "space after"
    end

    test "SC1068: rejects spaces around = in assignment" do
      assert {:error, msg, 1, 5} = Tokenizer.tokenize("VAR = value")
      assert msg =~ "SC1068"
      assert msg =~ "spaces around"
    end

    test "SC1068: rejects VAR =" do
      assert {:error, msg, 1, 5} = Tokenizer.tokenize("VAR =")
      assert msg =~ "SC1068"
    end

    test "accepts valid assignment" do
      assert {:ok, _tokens} = Tokenizer.tokenize("VAR=value")
      assert {:ok, _tokens} = Tokenizer.tokenize("VAR=")
      assert {:ok, _tokens} = Tokenizer.tokenize("VAR=\"value with spaces\"")
    end

    test "does not flag = in non-assignment context" do
      # = as part of test expression is OK
      assert {:ok, _tokens} = Tokenizer.tokenize("[ a = b ]")
      # == in test is OK
      assert {:ok, _tokens} = Tokenizer.tokenize("[[ $a == $b ]]")
    end
  end

  describe "heredoc error detection" do
    test "SC1041: rejects end token not on separate line" do
      script = """
      cat <<EOF
      hello
      -EOF
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1041"
      assert msg =~ "not on a separate line"
    end

    test "SC1043: rejects case mismatch in delimiter" do
      script = """
      cat <<EOF
      hello
      Eof
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1043"
      assert msg =~ "case mismatch"
    end

    test "SC1043: rejects all-lowercase when expecting uppercase" do
      script = """
      cat <<EOF
      hello
      eof
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1043"
    end

    test "SC1118: rejects trailing whitespace after end token" do
      # Note: trailing space after EOF
      script = "cat <<EOF\nhello\nEOF \n"

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1118"
      assert msg =~ "trailing whitespace"
    end

    # SC1119 is specifically about heredocs inside $(...) or (...).
    # Our tokenizer captures command substitution content as raw text without
    # parsing heredocs inside them, so we can't detect this error there.
    # This test verifies we detect it for top-level heredocs ending with )
    test "SC1119: rejects delimiter immediately followed by )" do
      # This would be invalid at the shell level but we detect it
      script = "cat <<EOF\nhello\nEOF)\n"

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1119"
      assert msg =~ "linefeed"
    end

    test "SC1120: rejects comment after end token" do
      script = """
      cat <<EOF
      hello
      EOF # comment
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1120"
      assert msg =~ "comment"
    end

    test "SC1122: rejects pipe after end token" do
      script = """
      cat <<EOF
      hello
      EOF | nl
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1122"
      assert msg =~ "Move"
    end

    test "SC1122: rejects ampersand after end token" do
      script = """
      cat <<EOF
      hello
      EOF &
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1122"
    end

    test "SC1122: rejects semicolon after end token" do
      script = """
      cat <<EOF
      hello
      EOF; echo done
      """

      assert {:error, msg, _line, _col} = Tokenizer.tokenize(script)
      assert msg =~ "SC1122"
    end

    test "accepts valid heredoc" do
      script = """
      cat <<EOF
      hello world
      EOF
      """

      assert {:ok, _tokens} = Tokenizer.tokenize(script)
    end

    test "accepts heredoc with strip tabs" do
      script = """
      cat <<-EOF
      \thello world
      \tEOF
      """

      assert {:ok, _tokens} = Tokenizer.tokenize(script)
    end

    test "accepts heredoc followed by newline then command" do
      script = """
      cat <<EOF
      hello
      EOF
      echo done
      """

      assert {:ok, _tokens} = Tokenizer.tokenize(script)
    end
  end

  describe "syntax spacing errors" do
    test "SC1045: &; is not valid" do
      assert {:error, msg, 1, _col} = Tokenizer.tokenize("echo hello &; echo world")
      assert msg =~ "SC1045"
      assert msg =~ "&"
    end

    test "SC1045: & followed by other chars is valid" do
      assert {:ok, _tokens} = Tokenizer.tokenize("echo hello & echo world")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo hello && echo world")
      assert {:ok, _tokens} = Tokenizer.tokenize("echo hello &> /dev/null")
    end

    test "SC1054: missing space after {" do
      assert {:error, msg, 1, _col} = Tokenizer.tokenize("{echo hello; }")
      assert msg =~ "SC1054"
      assert msg =~ "{"
    end

    test "SC1054: { with space is valid" do
      assert {:ok, _tokens} = Tokenizer.tokenize("{ echo hello; }")
    end

    test "SC1054: { followed by } or # is valid" do
      # {} is empty brace (caught by parser, not tokenizer)
      assert {:ok, _tokens} = Tokenizer.tokenize("{ }")
      # {# starts a comment line in brace context
      assert {:ok, _tokens} = Tokenizer.tokenize("{\n# comment\necho; }")
    end

    test "SC1069: missing space between keyword and [" do
      assert {:error, msg, 1, _col} = Tokenizer.tokenize("if[ -f file ]")
      assert msg =~ "SC1069"
      assert msg =~ "if"
    end

    test "SC1069: while[ without space" do
      assert {:error, msg, 1, _col} = Tokenizer.tokenize("while[ true ]")
      assert msg =~ "SC1069"
      assert msg =~ "while"
    end

    test "SC1069: keyword with space before [ is valid" do
      assert {:ok, _tokens} = Tokenizer.tokenize("if [ -f file ]")
      assert {:ok, _tokens} = Tokenizer.tokenize("while [ true ]")
    end
  end
end
