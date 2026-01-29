# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [unreleased]

- Remove redundant `Bash.Validator`
- Update documentation

## 0.2.0 (2026-01-29)

- Add `mix bash.format` and `mix bash.validate` tasks
- Improve formatter to not rely on regex
- Support extglob
- Support file descriptors 3+.
- Full support for coprocs.
- `wait` command now properly waits.
- Add `Bash.AST.Walkable` protocol and `Macro`-style AST traversal functions.

  **`Bash.AST.prewalk/2`** — top-down transformation. Visit each node before
  its children. Return `nil` to remove a node from its parent list.

  ```elixir
  import Bash.AST

  # Remove all `rm` commands from a parsed script
  safe_script = Bash.AST.prewalk(script, fn
    node when is_command(node, "rm") -> nil
    node -> node
  end)
  ```

  **`Bash.AST.postwalk/2`** — bottom-up transformation. Visit each node after
  its children have been processed.

  ```elixir
  # Rename all commands by appending a suffix
  result = Bash.AST.postwalk(script, fn
    cmd when is_command(cmd) ->
      %{cmd | name: %Bash.AST.Word{parts: [{:literal, name <> "_v2"}]}}
    node -> node
  end)
  ```

  **`Bash.AST.reduce/3`** — fold over all nodes without modifying the tree.

  ```elixir
  # Collect all command names in a script
  names = Bash.AST.reduce(script, [], fn
    node when is_command(node) -> [command_name(node) | acc]
    _, acc -> acc
  end)
  ```

  **`Bash.AST.walk_tree/4`** — full traversal with accumulator and separate
  `pre`/`post` callbacks for maximum control.

  ```elixir
  # Count total AST nodes
  {_script, count} =
    Bash.AST.walk_tree(script, 0,
      fn node, acc -> {node, acc + 1} end,
      fn node, acc -> {node, acc} end
    )
  ```

- Add guard macros for concise AST pattern matching: `command_name/1`,
  `is_command/1/2`, `assignment_name/1`, and `is_assignment/1/2`.

  These work in `when` clauses, making walker callbacks much more readable:

  ```elixir
  import Bash.AST

  # Remove dangerous commands using a guard
  Bash.AST.prewalk(script, fn
    node when is_command(node, "rm") -> nil
    node when is_command(node, "sudo") -> nil
    node -> node
  end)

  # Collect command names using a guard
  Bash.AST.reduce(script, [], fn
    node, acc when is_command(node) -> [command_name(node) | acc]
    _, acc -> acc
  end)

  # Filter assignments by name
  Bash.AST.prewalk(script, fn
    node when is_assignment(node, "SECRET") -> nil
    node -> node
  end)
  ```

## 0.1.0 (2026-01-28)

Initial Release. A Bash interpreter written in pure Elixir. Parses and executes Bash scripts with compile-time validation, session state management, and Elixir interoperability.

### Added

#### Core API

- `Bash.run/1,2,3` - Execute Bash scripts with optional session
- `Bash.run_file/1,2,3` - Execute Bash script files
- `Bash.parse/1` - Parse Bash scripts to AST at runtime
- `Bash.parse_file/1` - Parse Bash script files
- `Bash.validate/1` - Validate Bash syntax without execution
- `Bash.with_session/1,2` - Manage session lifecycle with auto-cleanup
- `Bash.format/1,2` - Format Bash code
- `Bash.stdout/1`, `Bash.stderr/1`, `Bash.output/1` - Extract command output
- `Bash.exit_code/1`, `Bash.success?/1` - Check command results

#### Compile-time Sigils

- `~BASH"script"` - Parse at compile time, return AST
- `~b"script"` - String interpolation variant with Elixir variable embedding
- Modifiers: `S` (stdout), `E` (stderr), `O` (combined output) and common Bash
set options such as `e` (errexit) `v` (verbose) `p` (pipefail` and `u` nounset
to error with undefined variables.
- ShellCheck-compatible error messages with line/column info

#### Language Constructs

- **Control Flow**: `if/elif/else/fi`, `case/esac`, `while`, `until`, `for`, C-style `for ((;;))`
- **Compound Commands**: `{ ... }` groups and `( ... )` subshells
- **Pipelines**: Multi-stage pipes with `|`, background execution with `&`
- **Logical Operators**: `&&` and `||` with short-circuit evaluation
- **Functions**: `function name { }` and `name() { }` syntax with local variables

#### Variable Expansion

- Basic expansion: `$VAR`, `${VAR}`
- Default values: `${VAR:-default}`, `${VAR:=default}`, `${VAR:?error}`, `${VAR:+alternate}`
- String operations: `${#VAR}`, `${VAR:offset:length}`
- Pattern removal: `${VAR#pattern}`, `${VAR##pattern}`, `${VAR%pattern}`, `${VAR%%pattern}`
- Substitution: `${VAR/pattern/replacement}`, `${VAR//pattern/replacement}`
- Case modification: `${VAR^}`, `${VAR^^}`, `${VAR,}`, `${VAR,,}`
- Prefix expansion: `${!prefix*}`, `${!prefix@}`
- Parameter transforms: `${VAR@Q}`, `${VAR@a}`, `${VAR@E}`, `${VAR@A}`, `${VAR@u}`, `${VAR@L}`
- Indirect expansion: `${!VAR}`

#### Arrays

- Indexed arrays: `arr=(a b c)`, `arr[0]=value`
- Associative arrays via `declare -A`
- Array access: `${arr[0]}`, `${arr[@]}`, `${arr[*]}`
- Array length: `${#arr[@]}`
- Array key listing: `${!arr[@]}`

#### Arithmetic

- Arithmetic expansion: `$((expression))`
- Arithmetic command: `(( expression ))`
- Full operator support: `+`, `-`, `*`, `/`, `%`, `**`
- Bitwise operators: `&`, `|`, `^`, `~`, `<<`, `>>`
- Comparison: `<`, `>`, `<=`, `>=`, `==`, `!=`
- Logical: `&&`, `||`, `!`
- Ternary: `? :`
- Increment/decrement: `++x`, `x++`, `--x`, `x--`
- Assignment operators: `=`, `+=`, `-=`, `*=`, `/=`, `%=`, etc.
- Base conversion: `16#FF`, `8#77`, `2#1010` (bases 2-64)

#### Command Substitution

- Modern syntax: `$(command)`
- Nested substitution support
- Process substitution: `<(command)`, `>(command)`

#### Brace Expansion

- List expansion: `{a,b,c}`
- Sequences: `{1..10}`, `{a..z}`
- Step sequences: `{1..10..2}`
- Zero-padding: `{01..10}`
- Nested braces: `{a,b{1,2}}`

#### Quoting

- Single quotes (literal)
- Double quotes (with expansion)
- ANSI-C quoting: `$'...'`
- Escape sequences

#### Redirections

- Input/output: `<`, `>`, `>>`
- File descriptor duplication: `2>&1`, `>&2`
- Combined: `&>`, `&>>`
- Heredoc: `<<`, `<<-` (with tab stripping)
- Herestring: `<<<`

#### Test Expressions

- `test` / `[ ... ]` - POSIX test
- `[[ ... ]]` - Extended test with:
  - File tests: `-f`, `-d`, `-e`, `-r`, `-w`, `-x`, `-s`, `-L`, etc.
  - String tests: `-z`, `-n`, `=`, `!=`, `<`, `>`
  - Numeric tests: `-eq`, `-ne`, `-lt`, `-le`, `-gt`, `-ge`
  - Variable tests: `-v` (isset), `-R` (nameref)
  - Pattern matching: `==`, `!=` with glob patterns
  - Regex matching: `=~` with `BASH_REMATCH` capture

#### Builtin Commands (53 total)

**I/O**
- `echo` - Output with `-n`, `-e` flags
- `printf` - Formatted output with `-v` variable assignment
- `read` - Input with `-r`, `-p`, `-t`, `-n`, `-d`, `-a`, `-s` options

**Variables**
- `export`, `declare`, `local`, `readonly`, `unset`
- Full attribute support: `-a`, `-A`, `-i`, `-r`, `-x`, `-n`, `-u`, `-l`

**Directory**
- `cd` - With `-L`, `-P` flags and `CDPATH` support
- `pwd`, `pushd`, `popd`, `dirs`

**Control Flow**
- `break`, `continue`, `return`, `exit`

**Job Control**
- `jobs`, `bg`, `fg`, `wait`, `disown`, `kill`

**Shell Options**
- `set` - Shell options (`-e`, `-u`, `-x`, `-a`, `-o pipefail`, etc.)
- `shopt` - Extended options (`dotglob`, `extglob`, `nullglob`, etc.)

**Execution**
- `source` / `.` - Execute in current shell
- `eval` - Parse and execute string
- `exec` - Replace shell process
- `command`, `builtin` - Bypass aliases/functions

**Other**
- `type`, `hash`, `help`, `true`, `false`, `:`, `alias`, `unalias`
- `trap` - Signal handlers for EXIT, DEBUG, RETURN, signals
- `getopts` - Option parsing
- `mapfile` / `readarray` - Read lines to array
- `let` - Arithmetic evaluation
- `times`, `ulimit`, `umask`, `caller`, `enable`, `suspend`
- `complete`, `history`, `fc`
- `coproc` - Coprocess management

#### Session Management

- Persistent environment across commands
- Working directory tracking
- Command history
- Function and alias storage
- Job table for background processes
- Directory stack
- Shell options state

#### Elixir Interop

- `defbash` macro for Elixir functions callable from Bash
- Namespace-based function calls: `namespace.function args`
- State access and modification from Elixir
- Multiple return value formats (`:ok`, `{:ok, msg}`, `{:error, msg}`)

#### Special Variables

- `$?` - Last exit status
- `$$` - Shell PID
- `$!` - Last background PID
- `$0`, `$1`-`$9`, `$@`, `$*`, `$#` - Positional parameters
- `PIPESTATUS` - Pipeline exit codes
- `BASH_REMATCH` - Regex captures
- `RANDOM`, `LINENO`, `SECONDS`, `EPOCHSECONDS`, `EPOCHREALTIME`
- `BASH_VERSION`, `HOME`, `PWD`, `OLDPWD`, `PATH`, `IFS`

#### Error Handling

- `set -e` / `errexit` - Exit on error
- `set -u` / `nounset` - Error on unbound variables
- `set -o pipefail` - Pipeline failure propagation
- ShellCheck-compatible error codes and messages

### Architecture

- Recursive descent parser following Bash grammar
- Token-based lexer with proper quoting/escaping
- AST-based execution model
- GenServer-based session management
- Supervisor hierarchy for job and process management
- Asynchronous output collection with streaming support
