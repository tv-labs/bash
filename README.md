# Bash

[![Hex.pm Version](http://img.shields.io/hexpm/v/bash.svg)](https://hex.pm/packages/bash)
[![Hex docs](http://img.shields.io/badge/hex.pm-docs-blue.svg?style=flat)](https://hexdocs.pm/bash)
[![License: Apache](https://img.shields.io/badge/License-Apache-yellow.svg)](./LICENSE.md)

You're currently looking at the main branch. [Check out the docs for the latest
published version.](https://hexdocs.pm/bash)

---

<!-- MDOC -->

A Bash interpreter written in pure Elixir.

Execute shell scripts from Elixir with compile-time validation, persistent sessions,
and the ability to extend Bash with Elixir functions.

## Quick Start

```elixir
# Add to mix.exs
{:bash, "~> 0.2.1"}
```

```elixir
# Run a command
{:ok, result, _session} = Bash.run("echo hello")
Bash.stdout(result)
#=> "hello\n"

# Start a session and run many commands
result = Bash.with_session(fn session ->
  session
  |> Bash.run("echo hello")
  |> Bash.run("echo uhoh >&2")
  |> Bash.stdout()
end)
#=> "hello\n"

# Or use the sigil for compile-time parsing
import Bash.Sigil
iex> ~BASH"echo 'uh oh' >&2 && echo 'heyo'"O  # 'O' modifier executes and returns both stdout and stderr
"uh oh\nheyo\n"

iex> ~BASH"ls -la | head -5"S  # 'S' modifier executes and returns only stdout
"total 12536\ndrwxr-xr-x@   4 dbern  staff      128 Jan 20 02:27 _build\ndrwxr-xr-x@  23 dbern  staff      736 Jan 27 12:10 .\ndrwxr-x---+ 178 dbern  staff     5696 Jan 27 12:09 ..\ndrwxr-xr-x@   3 dbern  staff       96 Jan 22 13:29 .git\n"

iex> ~BASH"echo 'uh oh' >&2 && echo 'heyo'"E  # 'E' modifier executes and returns only stderr
"uh oh\n"

iex> ~BASH"echo { foo"
** (Bash.SyntaxError) [SC1056] Bash syntax error at line 1:

> 1 | echo { foo
              ^

  hint: expected '}' to close brace group
```

Use as your Bash formatter.

```elixir
# ./formatter.exs
[
  plugins: [Bash.Formatter],
  inputs: [
    # ...
    "**/*.{sh,bash}"
  ],
  bash: [
    indent_style: :spaces,  # :spaces or :tabs (but you know which one is correct)
    indent_width: 2,        # number of spaces (ignored if :tabs)
    line_length: 100        # max line length before wrapping
  ]
  # ...
]
```


## Why Use This?

**For DevOps & Infrastructure**: Embed shell scripts in Elixir applications with
proper error handling, without shelling out to `/bin/bash`.

**For Testing**: Create reproducible shell environments with controlled state
and captured output.

**For Scripting**: Write scripts that combine Bash's text processing with Elixir's
power - call Elixir functions directly from Bash pipelines.

**For fun**: because YOLO

## Features

| Feature | Description |
|---------|-------------|
| **Compile-time parsing** | `~BASH` and `~b` sigil validates scripts at compile time with ShellCheck-compatible errors |
| **Persistent sessions** | Maintain environment variables, working directory, aliases, functions, and history |
| **Elixir interop** | Define Elixir functions callable from Bash using `defbash` |
| **Full I/O support** | Redirections, pipes, heredocs, process substitution |
| **Job control** | Background jobs, fg/bg switching, signal handling |
| **Streaming output** | Process stdout/stderr incrementally with configurable sinks |

## Usage

### Running Scripts

```elixir
# Simple execution
{:ok, result, _} = Bash.run(~b"echo hello")
Bash.stdout(result)
#=> "hello\n"

# With environment variables
{:ok, result, _} = Bash.run(~b"echo $USER", env: %{"USER" => "alice"})
Bash.stdout(result)
#=> "alice\n"

# Multi-line scripts with arithmetic
{:ok, result, _} = Bash.run("""
x=5
y=10
echo $((x + y))
""")
Bash.stdout(result)
#=> "15\n"
```

### The Sigil

```elixir
import Bash.Sigil

# Parse at compile time, execute at runtime
~BASH"echo hello"S           # returns stdout string
~BASH"echo error >&2"E       # returns stderr string
~BASH"echo hello"            # returns %Bash.Script{} AST (no execution)
person = "world"
~BASH"echo 'Hello #{person}'"O  # returns "Hello #{person}\n"
~b"echo 'Hello #{person}'"O     # returns "Hello world\n"
```

### Sessions

Sessions maintain state across multiple commands:

```elixir
{:ok, session} = Bash.Session.new()

# Set variables
Bash.run("export GREETING=hello", session)

# Use them later
{:ok, result, _} = Bash.run("echo $GREETING", session)
Bash.stdout(result)
#=> "hello\n"

# Working directory persists
Bash.run("cd /tmp", session)
{:ok, result, _} = Bash.run("pwd", session)
Bash.stdout(result)
#=> "/tmp\n"
```

### Elixir Interop

Define Elixir functions callable from Bash:

```elixir
defmodule MyApp.BashAPI do
  use Bash.Interop, namespace: "myapp"

  defbash greet(args, _state) do
    case args do
      [name | _] -> 
        Bash.puts(:stderr, "uhoh!")
        # Appended to stdout, and exits 0
        {:ok, "Hello #{name}!\n"}
      [] -> 
        # Appended to stderr, and exits 1
        {:error, "usage: myapp.greet NAME"}
    end
  end

  defbash upcase(_args, _state) do
    Bash.stream(:stdin)
    |> Stream.each(fn line ->
      Bash.puts(String.upcase(String.trim(line)) <> "\n")
      :ok
    end)
    |> Stream.run()

    :ok
  end
end
```

Load the API into a session:

```elixir
# Option 1: Load at session creation
{:ok, session} = Bash.Session.new(apis: [MyApp.BashAPI])

# Option 2: Load into existing session
{:ok, session} = Bash.Session.new()
:ok = Bash.Session.load_api(session, MyApp.BashAPI)

# Now callable from Bash
{:ok, result, _} = Bash.run("myapp.greet World", session)
Bash.stdout(result)
#=> "Hello World!\n"

# Works in pipelines
{:ok, result, _} = Bash.run("echo hello | myapp.upcase", session)
Bash.stdout(result)
#=> "HELLO\n"
```

## Supported Features

### Control Flow
- `if`/`then`/`elif`/`else`/`fi`
- `for` loops (word lists and C-style)
- `while` and `until` loops
- `case` statements
- `&&`, `||`, `;` operators
- Command groups `{ }` and subshells `( )`

### Variables
- Simple variables (`$VAR`, `${VAR}`)
- Arrays (indexed and associative)
- Parameter expansion (`${VAR:-default}`, `${VAR:+alt}`, `${#VAR}`, etc.)
- Arithmetic expansion (`$((expr))`)

### Builtins
`alias`, `bg`, `break`, `builtin`, `cd`, `command`, `continue`, `declare`,
`dirs`, `disown`, `echo`, `enable`, `eval`, `exec`, `exit`, `export`, `false`,
`fg`, `getopts`, `hash`, `help`, `history`, `jobs`, `kill`, `let`, `local`,
`mapfile`, `popd`, `printf`, `pushd`, `pwd`, `read`, `readonly`, `return`,
`set`, `shift`, `shopt`, `source`, `test`, `times`, `trap`, `true`, `type`,
`ulimit`, `umask`, `unalias`, `unset`, `wait`

### I/O
- Redirections (`>`, `>>`, `<`, `2>&1`, etc.)
- Pipelines
- Here documents and here strings
- Process substitution (`<(cmd)`, `>(cmd)`)

### Other
- Functions
- Brace expansion (`{a,b,c}`, `{1..10}`)
- Glob patterns
- Quoting (single, double, `$'...'`)
- Command substitution (`` `cmd` `` and `$(cmd)`)

<!-- MDOC -->

## Ideas & Use Cases

### Monitor Script Execution with Telemetry

```elixir
defmodule ScriptMonitor do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    :telemetry.attach_many(
      "script-monitor",
      [
        ~w[bash command stop]a,
        ~w[bash session run stop]a
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{commands: %{}, slow_threshold_ms: 100}}
  end

  def handle_event([:bash, :command, :stop], %{duration: duration}, metadata, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    if duration_ms > 100 do
      Logger.warning("Slow command: #{metadata.command} took #{duration_ms}ms")
    end
  end

  def handle_event([:bash, :session, :run, :stop], %{duration: duration}, metadata, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("Script completed in #{duration_ms}ms (exit: #{metadata.exit_code})")
  end
end

iex> ScriptMonitor.start_link()
{:ok, #PID<...>}

iex> ~b"sleep 4"O
11:51:26.658 [warning] Slow command: sleep took 4017ms
11:51:26.658 [info] Script completed in 4018ms (exit: 0)
```

### Create a Git Automation Tool

```elixir
defmodule GitHelper do
  def commit_and_push(message, user) do
    {:ok, session} = 
      Bash.Session.new(env: %{
        "GIT_AUTHOR_NAME" => user.name,
        "GIT_AUTHOR_EMAIL" => user.email,
      })

    script = ~b"""
    git add -A
    git commit -m "#{message}"
    git push origin HEAD
    """

    case Bash.run(script, session) do
      {:ok, result, _} -> {:ok, Bash.stdout(result)}
      {:error, result} -> {:error, Bash.stderr(result)}
    end
  end

  def branch_status do
    ~b"""
    echo "Branch: $(git branch --show-current)"
    echo "Status:"
    git status --short
    """O
  end
end
```

### Build a CI/CD Pipeline DSL

```elixir
defmodule CI.Pipeline do
  defmacro step(name, do: script) do
    quote do
      IO.puts("▶ #{unquote(name)}")

      case Bash.run(unquote(script)) do
        {:ok, result, _} ->
          IO.puts(Bash.stdout(result))
          :ok

        {:error, result} ->
          IO.puts(:stderr, Bash.stderr(result))
          raise "Step '#{unquote(name)}' failed"
      end
    end
  end
end

# Usage:
# import CI.Pipeline
# step "Install deps" do
#   ~b"mix deps.get"
# end
```

### Log File Analyzer

Mix Bash's imperative syntax with Elixir's standard library:

```elixir
defmodule LogAnalyzer do
  use Bash.Interop, namespace: "log"

  defbash parse_timestamp(args, _state) do
    case args do
      [timestamp] ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, dt, _} -> 
            Bash.puts("#{DateTime.to_unix(dt)}\n")
            :ok

          _ -> 
            {:error, "Invalid timestamp: #{timestamp}"}
        end

      _ -> {:error, "usage: log.parse_timestamp TIMESTAMP"}
    end
  end

  def errors_per_hour(log_file) do
    {:ok, session} = Bash.Session.new(apis: [__MODULE__])

    script = ~b"""
    grep ERROR #{log_file} | \\
      awk '{print $1}' | \\
      while read ts; do
        log.parse_timestamp "$ts"
      done | \\
      sort | uniq -c | sort -rn
    """

    {:ok, result, _} = Bash.run(script, session)
    Bash.stdout(result)
  end
end
```

### Docker Compose Helper

Post-process Bash scripts' outputs with native Elixir, which might
be easier than writing sed or awk scripts.

```elixir
defmodule DockerHelper do
  import Bash.Sigil

  def services_status do
    ~b"""
    docker compose ps --format json | \\
      while read line; do
        name=$(echo "$line" | jq -r '.Name')
        state=$(echo "$line" | jq -r '.State')
        echo "$name: $state"
      done
    """euoO
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, state] = String.split(line, ": ")
      {name, state}
    end)
  end

  def restart_unhealthy do
    for {name, "unhealthy"} <- services_status() do
      Bash.run(~b"docker compose restart #{name}")
    end
  end
end
```

## Editor Support

### Neovim Syntax Highlighting

To get Bash syntax highlighting inside `~BASH` and `~b` sigils with Neovim and
treesitter, add this to `~/.config/nvim/after/queries/elixir/injections.scm`:

```scheme
; Bash sigil highlighting for ~BASH and ~b
(sigil
  (sigil_name) @_sigil_name
  (quoted_content) @injection.content
  (#any-of? @_sigil_name "BASH" "b")
  (#set! injection.language "bash"))
```

This injects the `bash` language parser into sigil content, giving you:
- Syntax highlighting for Bash commands, variables, and operators
- Proper highlighting of `$VAR`, pipes, redirections, etc.
- Works with both `~BASH"..."` and `~b"..."` variants

Requires the Bash treesitter parser: `:TSInstall bash`

## AI Disclaimer

This code was largely created with AI assistance, particularly Claude Opus 4.5.
It almost certainly has been inspired by other public sources, such as the original
Bash source. While this repo is licensed to Apache 2.0, please be aware that
while nothing was copied from other source code, it's very likely to have strong
resemblance to other public source code, and that source code has their own
license.

## License

[Apache License 2.0](LICENSE.md)
