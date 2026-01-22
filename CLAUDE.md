# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Bash interpreter written in pure Elixir. Parses and executes Bash scripts with compile-time validation, session state management, and Elixir interoperability.

## Commands

```bash
# Run all tests
mix test

# Run a single test file
mix test test/bash/session_test.exs

# Run a specific test by line number
mix test test/bash/session_test.exs:42

# Run tests matching a pattern
mix test --only describe:"pattern matching"

# Compile the project
mix compile

# Format code
mix format

# Start IEx with project loaded
iex -S mix

# Compile NimbleParsec (after editing .ex.exs files)
./compile.nimble.sh
```

## Architecture

### Core Flow
```
Input String → Tokenizer → Parser → AST → Executor → Result
                                      ↓
                                   Session (state)
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `Bash` | Main API - `run/3`, `parse/1`, `stdout/1`, `stderr/1` |
| `Bash.Session` | GenServer managing execution context (variables, functions, jobs, working_dir) |
| `Bash.Parser` | Converts tokens to AST (uses NimbleParsec) |
| `Bash.Tokenizer` | Converts input string to tokens |
| `Bash.Executor` | Executes AST nodes against session state |
| `Bash.Interop` | `defbash` macro for Elixir-callable-from-Bash functions |

### AST Nodes (`lib/bash/ast/`)

Each node type (`Command`, `Pipeline`, `If`, `ForLoop`, `WhileLoop`, `Case`, etc.) is a struct implementing the `Bash.Statement` protocol for execution.

### Builtins (`lib/bash/builtin/`)

Each Bash builtin is a separate module implementing `execute/3` - receives args, redirects, and session state.

### Output System

Commands write to sinks (`Bash.Sink`) which route to `OutputCollector` GenServer. The collector accumulates interleaved stdout/stderr chunks asynchronously.

### Testing

Use `Bash.SessionCase` for tests requiring a session:
```elixir
use Bash.SessionCase, async: true
setup :start_session

test "example", %{session: session} do
  result = run_script(session, "echo hello")
  assert get_stdout(result) == "hello\n"
end
```

For testing builtins directly:
```elixir
{result, stdout, stderr} = with_output_capture(fn state ->
  Echo.execute(["hello"], nil, state)
end)
```

## Coding Standards

**Always** allow GenServers and any that it starts to consume options for asynchronous testing. Tests should never rely or be affected by global state.
**Always** document modules. If a Genserver or gen_statem, also provide a mermaid graph.
**Always** reference protocol sources (such as datatracker) when implementing or debugging protocols.
**Always** fix compilation errors before thinking you are done.
**Always** verify with tests before thinking you are done.

**Never** use `Process.sleep`, use GenServer messages
**Never** alias, import, or require modules inside a function; always place it at the top of the module
**Never** leave one line comments above self-explanatory functions.
**Never** leave commented divider blocks about sections of code.
**Never** Use System.unique_integer in ex_unit tests for uniqueness, instead use the test's `context.test` which will be unique. When creating mock modules for async tests, use Module.concat.

**Avoid** Aliasing modules as different names. If there is a conflict in names, alias to its parent module and qualify with the parent at callsites.

**Prefer** a small public API. Typically there are high-level APIs and low-level APIs.
**Prefer** pipes and `with` statements for composing functions.
**Prefer** structs for building state, and then pipelines to progressively build state
**Prefer** returning error tuple with the value as an exception struct
**Prefer** pattern-matching function heads instead of cond statements
**Prefer** defguard to extract common questions in function heads
