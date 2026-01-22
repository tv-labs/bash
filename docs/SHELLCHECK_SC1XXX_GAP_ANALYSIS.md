# ShellCheck SC1xxx Gap Analysis

This document compares ShellCheck's SC1xxx warnings (syntax errors in the 1000-1999 range) against what our Bash parser and tokenizer catch.

Reference: https://www.shellcheck.net/wiki/

## Summary

| Category | Caught | Gaps |
|----------|--------|------|
| Quote errors | 4 | 3 |
| Control flow (if/fi/etc) | 13 | 0 |
| Loop keywords | 4 | 2 |
| Brace groups | 4 | 0 |
| Heredoc errors | 8 | 4 |
| Unicode detection | 7 | 3 |
| Assignment errors | 3 | 0 |
| Positional params | 1 | 0 |
| Test expressions | 8 | 1 |
| Shebang issues | 5 | 4 |
| Escape sequences | 0 | 5 |
| Misc syntax | 6 | ~37 |

**Total: ~63 caught, ~59 gaps**

---

## What We Catch

### Tokenizer-Level Detection

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1003 | Unterminated single quote | `read_single_quoted_content` returns error |
| SC1009 | Unterminated double quote | `read_double_quoted_content` returns error |
| SC1041 | Heredoc end token not on separate line | `check_heredoc_delimiter` detects prefix |
| SC1043 | Heredoc delimiter case mismatch | `check_heredoc_delimiter` compares case |
| SC1044 | Heredoc delimiter not found | `read_heredoc_lines` returns error on EOF |
| SC1045 | `&;` is not valid | `read_amp` checks for `;` after `&` |
| SC1054 | Missing space after `{` | `read_lbrace_or_brace_expansion` checks next char |
| SC1069 | Missing space before `[` | `check_keyword_bracket_collision` in `read_word` |
| SC1078 | Unclosed double-quoted string | Same as SC1009 |
| SC1118 | Trailing whitespace after heredoc end | `check_heredoc_delimiter` detects trailing ws |
| SC1119 | Missing linefeed before `)` in heredoc | `check_heredoc_delimiter` detects `)` suffix |
| SC1120 | Comment after heredoc end token | `check_heredoc_delimiter` detects `#` suffix |
| SC1122 | Syntax after heredoc end token | `check_heredoc_delimiter` detects operators |
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
| SC1060 | `in` outside case/for | `parse_tokens` checks orphan keywords |
| SC1061 | Missing `done` for loop | `parse_while`/`parse_for` expect done |
| SC1062 | `do` outside loop | `parse_tokens` checks orphan keywords |
| SC1063 | `done` without loop | `parse_tokens` checks orphan keywords |
| SC1056 | `{` as command, missing `}` | Validator detects `{` as command name |
| SC1057 | `}` without `{` | `parse_tokens` checks for orphan `}` |
| SC1095 | `function foo{` missing space | `parse_function` checks for `{` in function name |

### Unicode Detection (Tokenizer)

| Code | Description | Our Detection |
|------|-------------|---------------|
| SC1015 | Unicode double quote `"` `"` | `check_unicode_lookalike` in tokenizer |
| SC1016 | Unicode single quote `'` `'` | `check_unicode_lookalike` in tokenizer |
| SC1018 | Non-breaking space | `check_unicode_lookalike` in tokenizer |
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
| SC1026 | `[` `]` used for grouping | `collect_test_*` detects `[` token |
| SC1027 | Missing argument for binary | `validate_test_args` checks binary ops |
| SC1028 | Unescaped `(` `)` in `[ ]` | `collect_test_bracket_args` detects `:lparen`/`:rparen` |
| SC1029 | Escaped parens in `[[ ]]` | `collect_test_expression` detects literal `(`/`)` words |
| SC1033 | `[[` closed with `]` | `collect_test_expression` detects mismatch |
| SC1034 | `[` closed with `]]` | `collect_test_bracket_args` detects mismatch |
| SC1080 | Newline in `[ ]` without `\` | `collect_test_bracket_args` detects `:newline` |

### SyntaxError Code Mapping

The `Bash.SyntaxError` module translates parser errors to ShellCheck codes:

```elixir
# lib/bash/syntax_error.ex (automatically extracted from (SCxxxx) prefix)
"SC1007" -> Space after = in assignment
"SC1015" -> Unicode double quote
"SC1016" -> Unicode single quote
"SC1018" -> Non-breaking space
"SC1019" -> Unary operator missing argument
"SC1026" -> [ ] used for grouping in test
"SC1027" -> Binary operator missing argument
"SC1028" -> Unescaped ( ) in [ ]
"SC1029" -> Escaped \( \) in [[ ]]
"SC1033" -> [[ closed with ] or missing ]]
"SC1034" -> [ closed with ]] or missing ]
"SC1037" -> Positional param > 9 without braces
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
"SC1066" -> $VAR= assignment error
"SC1068" -> Spaces around = in assignment
"SC1069" -> missing space between keyword and [
"SC1080" -> Newline in [ ] without continuation
"SC1081" -> unclosed command substitution
"SC1082" -> UTF-8 BOM detected
"SC1084" -> !# instead of #! in shebang
"SC1095" -> missing space between function name and {
"SC1100" -> Unicode dash
"SC1102" -> unclosed arithmetic expansion
"SC1114" -> Leading whitespace before shebang
"SC1115" -> Space between # and ! in shebang
"SC1118" -> Heredoc end token has trailing whitespace
"SC1119" -> Missing linefeed before ) in heredoc
"SC1120" -> Comment after heredoc end token
"SC1122" -> Syntax after heredoc end token
"SC1128" -> Shebang not on first line
```

---

## Gaps (What We Don't Catch)

### Priority 2: Medium Impact

#### Test Expression Issues (Remaining)

| Code | Description | Example |
|------|-------------|---------|
| SC1020 | Missing space before `]` | `[ -f foo]` |

**Note on SC1020:** Our tokenizer incorrectly treats `]` as a metacharacter, so `[ -f foo]` is
tokenized as `[ -f foo ]` (correct) instead of `[ -f foo]` (incorrect word). This means we
*accept* invalid scripts that real Bash would reject. Fixing this requires context-aware
tokenization where `]` is only special inside `[ ... ]` context.

#### Heredoc Issues (Remaining)

| Code | Description | Example |
|------|-------------|---------|
| SC1039 | Indentation before end token | Indented `EOF` without `<<-` |
| SC1040 | Use tabs with `<<-` | Spaces instead of tabs |
| SC1121 | Put syntax on `<<` line | `& ` after heredoc body but before `<<` |

**Note:** SC1121 is detected when operators appear after the end token (as SC1122), but the
original SC1121 is specifically about the syntax belonging on the `<<` line. The remaining
gaps are about validating indentation rules for `<<-` heredocs.

**Note on SC1119:** Our detection works for top-level heredocs but not for heredocs inside
command substitutions `$(...)`, since those are captured as raw text without full parsing.

#### Shebang Issues

| Code | Description | Example |
|------|-------------|---------|
| SC1008 | Unrecognized shebang interpreter | `#!/usr/bin/node` |
| SC1082 | UTF-8 BOM detected | BOM before shebang |
| SC1084 | Use `#!` not `!#` | `!#/bin/bash` |
| SC1104 | Use `#!` not `#` | `#/bin/bash` |
| SC1113 | Use `#!` not just `#` | `#bin/bash` |
| SC1114 | Leading spaces before shebang | `  #!/bin/bash` |
| SC1115 | Spaces between `#` and `!` | `# !/bin/bash` |
| SC1128 | Shebang must be on first line | Shebang on line 2 |

**Implementation Suggestion:** The tokenizer already handles shebangs in `read_comment`. Enhance to:
- Validate shebang position (must be line 1, column 1)
- Check for common malformations
- Warn about BOM

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
| SC1064 | Expected `{` for function body | `func () echo` |
| SC1065 | Don't declare params in `()` | `func(x, y) {}` |
| SC1070 | Parsing stopped, mismatch | Generic mismatch |
| SC1072 | Unexpected syntax element | Generic error |
| SC1073 | Unable to parse construct | Generic error |
| SC1074 | Missing `;;` in case | Case fall-through |
| SC1075 | Use `elif` not `else if` | `else if` pattern |
| SC1076 | Use `$((..))` for math | Math in conditions |
| SC1077 | Backticks slant wrong | `` vs `` |
| SC1081 | Scripts are case-sensitive | `If` vs `if` |
| SC1083 | `{}` is literal | Missing `;` or quote |
| SC1085 | Move `;;` after extending item | Case item syntax |
| SC1086 | Don't use `$` on loop var | `for $i in` |
| SC1087 | Use braces for arrays | `$arr[0]` vs `${arr[0]}` |
| SC1097 | Unexpected `==` | Assignment vs comparison |
| SC1101 | Trailing spaces after `\` | Broken line continuation |
| SC1102 | `$((` disambiguation | Add space after `$(` |
| SC1105 | Add space after `(` | Subshell disambiguation |
| SC1106 | Use `<` not `-lt` in `((` | Arithmetic comparison |
| SC1109 | Unquoted HTML entity | `&amp;` in script |
| SC1116 | Missing `$` on `$(())` | `((expr))` vs `$((expr))` |
| SC1129 | Missing space before `!` | `if!` |
| SC1130 | Missing space before `:` | Syntax error |
| SC1131 | Use `elif` for else branch | `else` misuse |
| SC1132 | `&` terminates command | Escape or space needed |
| SC1133 | Unexpected line start | Pipe should end prev line |
| SC1135 | Use `\` to escape `$` | Dollar at end of quote |
| SC1136 | Unexpected chars after `]` | Missing separator |
| SC1137 | Missing second `(` for `((;;))` | Arithmetic for loop |
| SC1138 | Remove spaces in `(( ))` | Arithmetic loop syntax |
| SC1139 | Use `\|\|` not `-o` | Test command syntax |
| SC1140 | Unexpected params after condition | Extra args |
| SC1141 | Unexpected tokens after compound | Trailing syntax |
| SC1142 | Use `done < <(cmd)` | Process substitution |

---

## Implementation Roadmap

### Phase 1: Unicode Detection (High Value, Low Effort)
Add to tokenizer:
```elixir
defp check_unicode_lookalikes(input) do
  # Check for curly quotes, dashes, non-breaking spaces
  # Return {:error, code, char, line, col} or :ok
end
```

### Phase 2: Assignment Validation (High Value, Medium Effort)
Enhance tokenizer's assignment detection to catch:
- `$VAR=` pattern (SC1066)
- `VAR =` pattern with space (SC1068)
- `VAR= ` pattern with trailing space (SC1007)

### Phase 3: Test Expression Validation (Medium Value, Medium Effort)
Enhance parser's test command handling:
- Bracket matching validation
- Spacing requirements
- Operator argument counts

### Phase 4: Heredoc Enhancement (Medium Value, Medium Effort)
Enhance heredoc parsing:
- Delimiter case sensitivity warning
- Trailing whitespace detection
- Proper `<<-` tab validation

### Phase 5: Comprehensive Coverage (Lower Value, Higher Effort)
Add remaining checks as warnings (not hard errors):
- Escape sequence warnings
- Style/spacing warnings
- Shebang validation

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
