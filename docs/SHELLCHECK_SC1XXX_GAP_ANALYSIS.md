# ShellCheck SC1xxx Gap Analysis

This document compares ShellCheck's SC1xxx warnings (syntax errors in the 1000-1999 range) against what our Bash parser and tokenizer catch.

Reference: https://www.shellcheck.net/wiki/

## Summary

| Category | Caught | Gaps |
|----------|--------|------|
| Quote errors | 4 | 3 |
| Control flow (if/fi/etc) | 13 | 0 |
| Loop keywords | 5 | 1 |
| Brace groups | 4 | 0 |
| Heredoc errors | 10 | 1 |
| Unicode detection | 8 | 2 |
| Assignment errors | 3 | 0 |
| Positional params | 1 | 0 |
| Test expressions | 9 | 0 |
| Shebang issues | 8 | 0 |
| Escape sequences | 0 | 5 |
| Misc syntax | 24 | ~17 |

**Total: ~89 caught, ~29 gaps**

---

## What We Catch

### Tokenizer-Level Detection

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1003 | Unterminated single quote | `read_single_quoted_content` returns error |
| SC1009 | Unterminated double quote | `read_double_quoted_content` returns error |
| SC1039 | Indented heredoc end token with `<<` | `check_heredoc_delimiter` detects leading whitespace |
| SC1040 | Spaces instead of tabs with `<<-` | `check_heredoc_delimiter` + `has_leading_spaces?` |
| SC1041 | Heredoc end token not on separate line | `check_heredoc_delimiter` detects prefix |
| SC1043 | Heredoc delimiter case mismatch | `check_heredoc_delimiter` compares case |
| SC1044 | Heredoc delimiter not found | `read_heredoc_lines` returns error on EOF |
| SC1045 | `&;` is not valid | `read_amp` checks for `;` after `&` |
| SC1054 | Missing space after `{` | `read_lbrace_or_brace_expansion` checks next char |
| SC1069 | Missing space before `[` | `check_keyword_bracket_collision` in `read_word` |
| SC1087 | Use braces for arrays `$arr[0]` | `read_simple_variable` detects `[` after variable |
| SC1097 | Unexpected `==` in assignment | `build_word_token` detects `VAR==value` pattern |
| SC1129 | Missing space before `!` | `check_keyword_bracket_collision` detects `keyword!` |
| SC1130 | Missing space before `:` | `check_keyword_bracket_collision` detects `keyword:` |
| SC1078 | Unclosed double-quoted string | Same as SC1009 |
| SC1118 | Trailing whitespace after heredoc end | `check_heredoc_delimiter` detects trailing ws |
| SC1119 | Missing linefeed before `)` in heredoc | `check_heredoc_delimiter` detects `)` suffix |
| SC1120 | Comment after heredoc end token | `check_heredoc_delimiter` detects `#` suffix |
| SC1122 | Syntax after heredoc end token | `check_heredoc_delimiter` detects operators |
| SC1101 | Trailing spaces after `\` | `skip_blanks` detects `\ \n` pattern |
| - | Unterminated backtick | `read_backtick_content` returns error |
| - | Unterminated `$()` | `read_matched_pair` for `)` returns error |
| - | Unterminated `$(())` | `read_arith_content` returns error |
| - | Unterminated `${}` | `read_braced_content` returns error |

### Parser-Level Detection

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1046 | Missing `fi` for `if` | `parse_if_body` expects fi/elif/else |
| SC1047 | `then` outside if/elif | `parse_tokens` checks orphan keywords |
| SC1048 | `else` outside if | `parse_tokens` checks orphan keywords |
| SC1049 | `elif` outside if | `parse_tokens` checks orphan keywords |
| SC1050 | `fi` without matching `if` | `parse_tokens` checks orphan keywords |
| SC1051 | Semicolon after `then` | `parse_if`/`parse_elif_body` check after advancing |
| SC1052 | Same as SC1051 | Same detection as SC1051 |
| SC1053 | Semicolon after `else` | `parse_if_body`/`parse_elif_body` check after advancing |
| SC1055 | Empty brace group `{ }` | `parse_brace_group` checks for empty `stmts` |
| SC1058 | Missing `esac` for `case` | `parse_case` expects esac |
| SC1059 | `esac` without `case` | `parse_tokens` checks orphan keywords |
| SC1074 | Missing `;;` in case | `parse_case_item` detects missing terminator |
| SC1060 | `in` outside case/for | `parse_tokens` checks orphan keywords |
| SC1061 | Missing `done` for loop | `parse_while`/`parse_for` expect done |
| SC1062 | `do` outside loop | `parse_tokens` checks orphan keywords |
| SC1063 | `done` without loop | `parse_tokens` checks orphan keywords |
| SC1056 | `{` as command, missing `}` | Validator detects `{` as command name |
| SC1057 | `}` without `{` | `parse_tokens` checks for orphan `}` |
| SC1064 | Expected `{` for function body | `parse_function_body_with_check` validates compound command |
| SC1065 | Don't declare params in `()` | `parse_function` detects content between `()` |
| SC1075 | Use `elif` not `else if` | `parse_if_body`/`parse_elif_body` detect `if` after `else` |
| SC1086 | Don't use `$` on loop var | `parse_for` detects variable in loop var position |
| SC1095 | `function foo{` missing space | `parse_function` checks for `{` in function name |
| SC1133 | Pipe at start of line | `parse_simple_command` detects `:pipe` token |
| SC1109 | HTML entities in script | `check_html_entity_at_amp` in tokenizer |
| SC1132 | `&` terminates command unexpectedly | `read_amp` detects `foo&bar` pattern |
| SC1136 | Chars after `]` without separator | `check_chars_after_bracket` in tokenizer |
| SC1137 | Missing `(` in `((;;))` for loop | `parse_for` detects `:lparen` instead of `:arith_command` |

### Unicode Detection (Tokenizer)

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1015 | Unicode double quote `"` `"` | `check_unicode_lookalike` in tokenizer |
| SC1016 | Unicode single quote `'` `'` | `check_unicode_lookalike` in tokenizer |
| SC1018 | Non-breaking space | `check_unicode_lookalike` in tokenizer |
| SC1077 | Acute accent instead of backtick | `check_unicode_lookalike` in tokenizer |
| SC1100 | Unicode dash `–` `—` | `check_unicode_lookalike` in tokenizer |

### Assignment & Parameter Detection (Tokenizer)

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1037 | Positional params > 9 need braces | `read_simple_variable` detects `$10` etc. |
| SC1066 | `$` on left side of assignment | `read_simple_variable` detects `$VAR=` |

### Test Expression Validation (Parser)

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1019 | Missing argument to unary | `validate_test_args` checks unary ops |
| SC1020 | Missing space before `]` | `read_rbracket` emits `:rbracket_no_space`, parser detects in test context |
| SC1026 | `[` `]` used for grouping | `collect_test_*` detects `[` token |
| SC1027 | Missing argument for binary | `validate_test_args` checks binary ops |
| SC1028 | Unescaped `(` `)` in `[ ]` | `collect_test_bracket_args` detects `:lparen`/`:rparen` |
| SC1029 | Escaped parens in `[[ ]]` | `collect_test_expression` detects literal `(`/`)` words |
| SC1033 | `[[` closed with `]` | `collect_test_expression` detects mismatch |
| SC1034 | `[` closed with `]]` | `collect_test_bracket_args` detects mismatch |
| SC1080 | Newline in `[ ]` without `\` | `collect_test_bracket_args` detects `:newline` |

### Shebang Validation (Tokenizer)

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1008 | Unrecognized shebang interpreter | `validate_shebang_interpreter` checks shell name |
| SC1082 | UTF-8 BOM before shebang | `check_script_start` at start of tokenization |
| SC1084 | `!#` instead of `#!` | `check_script_start` detects inverted shebang |
| SC1104 | `!/bin/bash` missing `#` | `check_script_start` detects `!` without `#` |
| SC1113 | `#/bin/bash` missing `!` | `check_script_start` detects `#` followed by path |
| SC1114 | Leading whitespace before shebang | `check_script_start` detects prefix spaces |
| SC1115 | Space between `#` and `!` | `check_script_start` detects `# !` |
| SC1128 | Shebang not on first line | `read_comment` detects `#!` on line > 1 |

### SyntaxError Code Mapping

The `Bash.SyntaxError` module translates parser errors to ShellCheck codes:

```elixir
# lib/bash/syntax_error.ex (automatically extracted from (SCxxxx) prefix)
"SC1007" -> Space after = in assignment
"SC1008" -> Unrecognized shebang interpreter
"SC1015" -> Unicode double quote
"SC1016" -> Unicode single quote
"SC1018" -> Non-breaking space
"SC1019" -> Unary operator missing argument
"SC1020" -> Missing space before ]
"SC1026" -> [ ] used for grouping in test
"SC1027" -> Binary operator missing argument
"SC1028" -> Unescaped ( ) in [ ]
"SC1029" -> Escaped \( \) in [[ ]]
"SC1033" -> [[ closed with ] or missing ]]
"SC1034" -> [ closed with ]] or missing ]
"SC1037" -> Positional param > 9 without braces
"SC1039" -> Indented heredoc end token with <<
"SC1040" -> Spaces instead of tabs with <<-
"SC1041" -> Heredoc end token not on separate line
"SC1043" -> Heredoc delimiter case mismatch
"SC1045" -> &; is not valid
"SC1046" -> if/fi errors
"SC1047" -> orphan then
"SC1048" -> orphan else
"SC1049" -> orphan elif
"SC1050" -> orphan fi
"SC1051" -> semicolon after then
"SC1053" -> semicolon after else
"SC1054" -> missing space after {
"SC1055" -> empty brace group
"SC1056" -> unclosed brace group
"SC1057" -> unexpected }
"SC1058" -> case without esac
"SC1059" -> esac without case
"SC1060" -> orphan in
"SC1061" -> loop without done
"SC1062" -> orphan do
"SC1063" -> orphan done
"SC1064" -> expected { for function body
"SC1065" -> function params not allowed
"SC1066" -> $VAR= assignment error
"SC1068" -> Spaces around = in assignment
"SC1069" -> missing space between keyword and [
"SC1074" -> missing ;; in case
"SC1075" -> use elif instead of else if
"SC1077" -> acute accent instead of backtick
"SC1080" -> Newline in [ ] without continuation
"SC1081" -> unclosed command substitution (Note: ShellCheck uses SC1081 for case-sensitivity)
"SC1082" -> UTF-8 BOM detected
"SC1084" -> !# instead of #! in shebang
"SC1086" -> $ on for loop variable
"SC1087" -> use braces for array access
"SC1095" -> missing space between function name and {
"SC1097" -> unexpected == in assignment
"SC1100" -> Unicode dash
"SC1101" -> trailing spaces after backslash
"SC1102" -> unclosed arithmetic expansion
"SC1104" -> !/bin/bash missing #
"SC1113" -> #/bin/bash missing !
"SC1114" -> Leading whitespace before shebang
"SC1115" -> Space between # and ! in shebang
"SC1118" -> Heredoc end token has trailing whitespace
"SC1119" -> Missing linefeed before ) in heredoc
"SC1120" -> Comment after heredoc end token
"SC1122" -> Syntax after heredoc end token
"SC1128" -> Shebang not on first line
"SC1129" -> missing space before !
"SC1130" -> missing space before :
"SC1133" -> pipe at start of line
"SC1136" -> chars after ] without separator
"SC1109" -> HTML entity in script
"SC1132" -> & terminates command unexpectedly
"SC1137" -> missing ( for C-style for loop
```

---

## Gaps (What We Don't Catch)

### Priority 2: Medium Impact

#### Heredoc Issues (Remaining)

| Code | Description | Example |
|------|-------------|---------|
| SC1121 | Put syntax on `<<` line | `& ` after heredoc body but before `<<` |

**Note:** SC1121 is detected when operators appear after the end token (as SC1122), but the
original SC1121 is specifically about the syntax belonging on the `<<` line.

### Priority 3: Lower Impact

#### Escape Sequence Issues

| Code | Description | Example |
|------|-------------|---------|
| SC1001 | Backslash-letter treated as literal | `\o` is literal `o` |
| SC1004 | Backslash+linefeed is literal | Line continuation issues |
| SC1012 | `\t` is literal `t` | Use `$'\t'` or printf |
| SC1117 | Backslash literal in `\n` | Explicit escaping preferred |
| SC1143 | Backslash in comment doesn't continue | `# comment \` |

#### Misc Syntax

| Code | Description | Example |
|------|-------------|---------|
| SC1036 | Invalid `(` usage | Unexpected parenthesis |
| SC1070 | Parsing stopped, mismatch | Generic mismatch |
| SC1072 | Unexpected syntax element | Generic error |
| SC1073 | Unable to parse construct | Generic error |
| SC1076 | Use `$((..))` for math | Math in conditions |
| SC1083 | `{}` is literal | Missing `;` or quote |
| SC1085 | Move `;;` after extending item | Case item syntax |
| SC1102 | `$((` disambiguation | Add space after `$(` |
| SC1105 | Add space after `(` | Subshell disambiguation |
| SC1106 | Use `<` not `-lt` in `((` | Arithmetic comparison |
| SC1116 | Missing `$` on `$(())` | `((expr))` vs `$((expr))` |
| SC1131 | Use `elif` for else branch | `else` misuse |
| SC1135 | Use `\` to escape `$` | Dollar at end of quote |
| SC1138 | Remove spaces in `(( ))` | Arithmetic loop syntax |
| SC1139 | Use `\|\|` not `-o` | Test command syntax |
| SC1140 | Unexpected params after condition | Extra args |
| SC1141 | Unexpected tokens after compound | Trailing syntax |
| SC1142 | Use `done < <(cmd)` | Process substitution |


### Remaining Work

**Lower Value:**
- Escape sequence warnings (SC1001, SC1004, SC1012, SC1117, SC1143)
- Remaining misc syntax checks (~13 items)

---

## Testing Strategy

For each new check, add tests in `test/bash/syntax_error_test.exs` and/or `test/bash/validator_test.exs`:

```elixir
describe "unicode detection" do
  test "rejects curly double quotes" do
    assert {:error, msg, 1, 5} = Parser.parse(~S|echo "hello"|)
    assert msg =~ "SC1015" or msg =~ "Unicode"
  end
end
```

---

## References

- ShellCheck Wiki: https://www.shellcheck.net/wiki/
- ShellCheck Source: https://github.com/koalaman/shellcheck
- Bash Reference Manual: https://www.gnu.org/software/bash/manual/
