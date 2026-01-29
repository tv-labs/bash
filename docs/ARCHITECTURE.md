# Architecture Guide

This document describes the process architecture, supervision tree, and output streaming system for the Elixir Bash shell implementation.

## Overview

The shell is built around GenServer-based session management with a multi-layer output streaming system. Key components:

- **Session** - Central GenServer managing execution context
- **OutputCollector** - GenServer accumulating stdout/stderr
- **JobProcess** - GenServer managing background OS processes
- **Coproc** - GenServer managing coprocess I/O in external or internal mode
- **ProcessSubst** - GenServer managing process substitution FIFOs
- **Sink** - Pluggable output destinations

## Supervision Tree

```mermaid
graph TB
    subgraph Application["Bash.Application"]
        SR[SessionRegistry<br/>Registry]
        SS[SessionSupervisor<br/>DynamicSupervisor]
        OS[OrphanSupervisor<br/>GenServer]
    end

    subgraph Session1["Session"]
        S1[Session GenServer]
        JS1[JobSupervisor<br/>DynamicSupervisor]
        OC1[OutputCollector<br/>GenServer]

        subgraph Jobs1["Background Jobs"]
            JP1[JobProcess 1]
            JP2[JobProcess 2]
        end

        subgraph Coprocs1["Coprocesses"]
            CP1[Coproc GenServer]
        end
    end

    SS --> S1
    S1 -.->|links| JS1
    S1 -.->|links| OC1
    JS1 --> JP1
    JS1 --> JP2
    JS1 --> CP1
    OS -->|orphaned jobs| JP3[Disowned JobProcess]

    style S1 fill:#e1f5fe
    style OC1 fill:#fff3e0
    style JP1 fill:#f3e5f5
    style JP2 fill:#f3e5f5
    style JP3 fill:#ffebee
    style CP1 fill:#e8f5e9
```

## GenServers

### Session GenServer

The central execution context managing all session state.

```mermaid
stateDiagram-v2
    [*] --> Idle: Session.new()

    Idle --> Executing: execute(ast)
    Executing --> Idle: result returned

    Idle --> BackgroundJob: command &
    BackgroundJob --> Idle: job started

    Idle --> Foreground: fg %n
    Foreground --> Idle: job completed

    Idle --> [*]: stop()

    note right of Executing
        Creates OutputCollector
        Runs Executor
        Applies state updates
    end note
```

**State fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `id` | String | Unique session identifier |
| `working_dir` | String | Current directory (PWD) |
| `variables` | Map | Environment variables as `Variable.t()` |
| `functions` | Map | Defined bash functions |
| `aliases` | Map | Command aliases |
| `jobs` | Map | Active background jobs |
| `job_supervisor` | pid | DynamicSupervisor for jobs |
| `output_collector` | pid | Current OutputCollector |
| `stdout_sink` / `stderr_sink` | function | Output destination functions |
| `executions` | list | Per-command execution records |
| `current` | Execution.t | Active execution context |
| `special_vars` | Map | `$?`, `$!`, `$$`, `$0`, `$_` |
| `positional_params` | list | Function argument stack |
| `file_descriptors` | Map | FD number to pid or `{:coproc, pid, :read \| :write}` |

**Internal fields (opaque):**
- `job_supervisor`, `output_collector` - Process pids
- `stdout_sink`, `stderr_sink` - Sink functions
- `executions`, `current`, `is_pipeline_tail` - Execution tracking
- `file_descriptors` - Routes FD reads/writes to coproc GenServers or StringIO devices

### OutputCollector GenServer

Accumulates interleaved stdout/stderr output with async writes.

```mermaid
sequenceDiagram
    participant E as Executor
    participant OC as OutputCollector
    participant U as User

    E->>OC: cast {:write, :stdout, "hello"}
    E->>OC: cast {:write, :stderr, "warning"}
    E->>OC: cast {:write, :stdout, "world"}

    Note over OC: Chunks stored reversed<br/>for efficiency

    U->>OC: call :chunks
    OC-->>U: [{:stdout, "hello"}, {:stderr, "warning"}, {:stdout, "world"}]
```

**Operations:**
- `write/3` - Async cast (non-blocking)
- `chunks/1` - Get interleaved output in order
- `stdout/1`, `stderr/1` - Get filtered streams
- `flush/1` - Get and clear

### JobProcess GenServer

Manages a single background OS process lifecycle.

```mermaid
stateDiagram-v2
    [*] --> Starting: init()
    Starting --> Running: worker started
    Running --> Running: output received
    Running --> Stopped: SIGSTOP
    Stopped --> Running: SIGCONT
    Running --> Done: process exit
    Stopped --> Done: process exit
    Done --> [*]

    note right of Running
        Accumulates output
        Notifies session
    end note
```

**Process model:**
```mermaid
graph LR
    subgraph JobProcess["JobProcess GenServer"]
        JP[State Management]
    end

    subgraph Worker["Worker Process (spawn)"]
        W[ExCmd Owner]
    end

    subgraph OS["OS Process"]
        P[External Command]
    end

    JP -->|spawn| W
    W -->|"ExCmd.start_link"| P
    P -->|"stdout/stderr"| W
    W -->|"{:stdout, data}"| JP
    W -->|"{:process_exit, code}"| JP
    JP -->|"{:job_completed, job}"| Session

    style JP fill:#f3e5f5
    style W fill:#e8f5e9
    style P fill:#fff3e0
```

### Coproc GenServer

Manages a coprocess — a command running asynchronously with its stdin/stdout connected to the session via file descriptors. Operates in two modes:

- **External** — simple commands (e.g., `coproc cat`) backed by `ExCmd.Process`
- **Internal** — compound commands (e.g., `coproc NAME { cat; }`) backed by spawned BEAM processes with `Bash.Pipe` FIFOs

```mermaid
stateDiagram-v2
    [*] --> running: start_link(:external | :internal)
    running --> running: read/write I/O
    running --> closing: close_stdin
    closing --> stopped: process exits
    running --> stopped: process exits
    stopped --> [*]
```

The session registers coproc file descriptors in `file_descriptors` as `{:coproc, pid, :read | :write}` tuples. Reads and writes on those FDs are routed through this GenServer. On session termination, all coproc FDs are closed and the coproc processes are stopped.

**Operations:**
- `read_output/2` - Read from coproc stdout
- `write_input/3` - Write to coproc stdin
- `close_read/2`, `close_write/2` - Close pipe ends
- `get_status/2` - Query coproc state

### ProcessSubst GenServer

Manages process substitution (`<(command)` and `>(command)`). Creates a named pipe (FIFO) and runs a background command connected to it. The FIFO path is substituted into the parent command as a filename.

```mermaid
sequenceDiagram
    participant P as Parent Command
    participant PS as ProcessSubst
    participant FIFO as Named Pipe
    participant C as Substituted Command

    PS->>FIFO: mkfifo
    PS->>C: spawn command
    PS-->>P: /path/to/fifo
    P->>FIFO: read or write
    C->>FIFO: write or read
    C->>PS: exit
    PS->>FIFO: rm fifo
```

**State fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `fifo_path` | String | Path to the named pipe |
| `direction` | `:input \| :output` | Whether parent reads or writes the FIFO |
| `command_ast` | term | AST of the substituted command |
| `session_state` | map | Snapshot of session state for execution |
| `worker_pid` | pid | Spawned process running the command |
| `os_pid` | integer | OS pid when using external commands |

## Output Flow

### Sink System

Sinks are functions that receive output chunks and route them to destinations.

```mermaid
graph TB
    subgraph Execution
        CMD[Command/Builtin]
    end

    subgraph Sinks["Sink Functions"]
        SC[Sink.collector]
        SS[Sink.stream]
        SF[Sink.file]
        SN[Sink.null]
    end

    subgraph Destinations
        OC[OutputCollector]
        FS[File.Stream]
        FH[File Handle]
        DEV["/dev/null"]
    end

    CMD -->|write| SC
    CMD -->|write| SS
    CMD -->|write| SF
    CMD -->|write| SN

    SC -->|cast| OC
    SS -->|Collectable| FS
    SF -->|:file.write| FH
    SN -->|discard| DEV

    style CMD fill:#e3f2fd
    style SC fill:#fff3e0
    style SS fill:#fff3e0
    style SF fill:#fff3e0
    style SN fill:#fff3e0
```

### Command Execution Output Flow

```mermaid
sequenceDiagram
    participant U as User
    participant S as Session
    participant OC as OutputCollector
    participant E as Executor
    participant C as Command

    U->>S: execute(ast)
    S->>OC: start_link()
    S->>S: link(collector)
    S->>S: create sinks
    S->>E: execute(ast, state_with_sinks)

    loop Each output chunk
        C->>E: output data
        E->>OC: cast write(:stdout, data)
        Note over OC: Accumulates async
    end

    E-->>S: {:ok, result}
    S->>S: append_to_history
    S->>S: update $?

    alt Script result
        S->>S: keep collector alive
        Note over S,OC: Script.collector = pid
    else Other result
        S->>OC: stop (cleanup)
    end

    S-->>U: {:ok, result}

    opt Read output later
        U->>OC: stdout()
        OC-->>U: ["data", ...]
    end
```

### Pipeline Output Flow

Intermediate commands write to StringIO for piping; the final command writes to sinks.

```mermaid
graph LR
    subgraph Cmd1["Command 1"]
        C1[echo hello]
        O1[stdout: StringIO]
    end

    subgraph Cmd2["Command 2"]
        I2[stdin: StringIO]
        C2[tr a-z A-Z]
        O2[stdout: StringIO]
    end

    subgraph Cmd3["Command 3 (tail)"]
        I3[stdin: StringIO]
        C3[wc -c]
        O3[stdout: sink]
    end

    C1 -->|write| O1
    O1 -->|pipe_forward| I2
    C2 -->|read| I2
    C2 -->|write| O2
    O2 -->|pipe_forward| I3
    C3 -->|read| I3
    C3 -->|write| O3

    style O1 fill:#e8f5e9
    style I2 fill:#e3f2fd
    style O2 fill:#e8f5e9
    style I3 fill:#e3f2fd
    style O3 fill:#fff3e0
```

## Background Job Lifecycle

```mermaid
sequenceDiagram
    participant U as User
    participant S as Session
    participant JS as JobSupervisor
    participant JP as JobProcess
    participant W as Worker
    participant OSP as OS Process
    participant OC as OutputCollector

    U->>S: execute "sleep 10 &"
    S->>JS: start_child(JobProcess)
    JS->>JP: init()
    JP->>JP: {:continue, :start_process}
    JP->>W: spawn worker
    W->>OSP: ExCmd.start_link
    W-->>JP: {:worker_started, os_pid}
    JP-->>S: {:job_started, job}
    S-->>U: {:ok, "[1] 12345"}

    Note over S,U: User continues working

    loop Output streaming
        OSP->>W: stdout/stderr data
        W->>JP: {:stdout, data}
        JP->>OC: write to sink
    end

    OSP->>W: exit(0)
    W->>JP: {:process_exit, {:ok, 0}}
    JP->>JP: Job.complete
    JP-->>S: {:job_completed, job}

    Note over S: Adds to completed_jobs

    opt User calls fg
        U->>S: foreground_job(1)
        S->>JP: foreground()
        Note over JP: Already done
        JP-->>S: {:ok, result}
        S-->>U: {:ok, result}
    end
```

## Process Linking and Fault Tolerance

```mermaid
graph TB
    subgraph Links["Process Links"]
        S[Session]
        JS[JobSupervisor]
        OC[OutputCollector]
        JP[JobProcess]
        CP[Coproc]
        W[Worker]
        EX[ExCmd.Process]
    end

    S ---|link| JS
    S ---|link| OC
    JS -->|supervises| JP
    JS -->|supervises| CP
    JP -.->|spawn, no link| W
    W ---|owns| EX

    subgraph Behavior["On Crash"]
        B1["Session dies → JobSupervisor dies, OutputCollector dies"]
        B2["JobSupervisor dies → Session dies"]
        B3["OutputCollector dies → Session continues (trap_exit)"]
        B4["JobProcess dies → removed from JobSupervisor"]
        B5["Worker dies → JobProcess handles gracefully"]
        B6["Coproc dies → removed from JobSupervisor, FDs become stale"]
    end
```

## Key Data Structures

### Execution

Per-command I/O context with StringIO devices:

```elixir
%Execution{
  command: "echo hello",
  stdout: #PID<0.123.0>,     # StringIO device
  stderr: #PID<0.124.0>,     # StringIO device
  exit_code: 0,
  started_at: ~U[2024-01-01 12:00:00Z],
  completed_at: ~U[2024-01-01 12:00:01Z]
}
```

### Job

Background job state (output flows to OutputCollector via sinks):

```elixir
%Job{
  job_number: 1,
  os_pid: 12345,
  erlang_pid: #PID<0.200.0>,  # JobProcess GenServer
  command: "sleep 100",
  status: :running,           # :running | :stopped | :done
  exit_code: nil
}
```

### Script (with collector reference)

```elixir
%Script{
  statements: [...],
  exit_code: 0,
  state_updates: %{},
  collector: #PID<0.150.0>   # OutputCollector for post-exec reading
}
```

## Design Patterns

### Async Output Collection

OutputCollector uses `GenServer.cast` for writes, preventing output buffering from blocking execution:

```elixir
# Non-blocking write
def write(pid, stream, data) do
  GenServer.cast(pid, {:write, stream, data})
end
```

### Worker Process Isolation

JobProcess spawns a separate worker to own ExCmd, keeping the GenServer responsive:

```elixir
# JobProcess stays responsive
spawn(fn ->
  {:ok, process} = ExCmd.Process.start_link(cmd, args)
  send(parent, {:worker_started, ExCmd.Process.os_pid(process)})
  read_output_loop(process, parent)
  exit_code = ExCmd.Process.await_exit(process)
  send(parent, {:process_exit, {:ok, exit_code}})
end)
```

### Pluggable Sinks

Output destinations are functions, enabling runtime routing:

```elixir
{:ok, session} = Bash.Session.new()

# Route stdout to file (pass Collectable directly, not a sink)
Bash.Session.execute(session, ast, stdout_into: File.stream!("/tmp/output.txt"))

# Real-time callback (receives {:stdout, data} or {:stderr, data} tuples)
Bash.Session.execute(session, ast, on_output: fn
  {:stdout, data} -> IO.write(data)
  {:stderr, data} -> IO.write(:stderr, data)
end)
```

### Variable Scoping Stack

Positional parameters use a stack for function call isolation:

```elixir
# Before function call
positional_params: [["arg1", "arg2"]]

# During function call (pushed)
positional_params: [["func_arg1"], ["arg1", "arg2"]]

# After function return (popped)
positional_params: [["arg1", "arg2"]]
```
