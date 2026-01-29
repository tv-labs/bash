defmodule Bash.MixProject do
  use Mix.Project

  @source_url "https://github.com/tv-labs/bash"
  @version "0.2.0"

  def project do
    [
      app: :bash,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Bash",
      description:
        "A Bash interpreter written in pure Elixir with compile-time parsing, session management, and Elixir interop",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  defp package do
    [
      name: "bash",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["David Bernheisel"],
      source_ref: "v#{@version}",
      files: ~w[lib .formatter.exs mix.exs docs CHANGELOG.md LICENSE.md]
    ]
  end

  @mermaid_js """
  <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js"></script>
  <script>
    let initialized = false;

    window.addEventListener("exdoc:loaded", () => {
      if (!initialized) {
        mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
        });
        initialized = true;
      }

      let id = 0;
      for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
        const preEl = codeEl.parentElement;
        const graphDefinition = codeEl.textContent;
        const graphEl = document.createElement("div");
        const graphId = "mermaid-graph-" + id++;
        mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
          graphEl.innerHTML = svg;
          bindFunctions?.(graphEl);
          preEl.insertAdjacentElement("afterend", graphEl);
          preEl.remove();
        });
      }
    });
  </script>
  """

  defp docs do
    [
      main: "Bash",
      extras: ["LICENSE.md", "docs/ARCHITECTURE.md"],
      source_url: "https://github.com/tv-labs/bash",
      before_closing_body_tag: %{html: @mermaid_js},
      groups_for_modules: [
        "Core API": [
          Bash,
          Bash.Script,
          Bash.Session,
          Bash.Sigil,
          Bash.Formatter,
          Bash.Telemetry
        ],
        "Elixir Interop": [
          Bash.Interop,
          Bash.Interop.Context,
          Bash.Interop.Result
        ],
        Parsing: [
          Bash.Parser,
          Bash.Parser.Arithmetic,
          Bash.Parser.VariableExpander,
          Bash.Tokenizer
        ],
        "AST Nodes": [
          Bash.AST,
          Bash.AST.Arithmetic,
          Bash.AST.ArrayAssignment,
          Bash.AST.Assignment,
          Bash.AST.BraceExpand,
          Bash.AST.Case,
          Bash.AST.Command,
          Bash.AST.Comment,
          Bash.AST.Compound,
          Bash.AST.Coproc,
          Bash.AST.ForLoop,
          Bash.AST.If,
          Bash.AST.Meta,
          Bash.AST.Pipeline,
          Bash.AST.Redirect,
          Bash.AST.RegexPattern,
          Bash.AST.TestCommand,
          Bash.AST.TestExpression,
          Bash.AST.Variable,
          Bash.AST.Walkable,
          Bash.AST.WhileLoop,
          Bash.AST.Word
        ],
        Execution: [
          Bash.Arithmetic,
          Bash.CommandPort,
          Bash.CommandResult,
          Bash.Execution,
          Bash.ExecutionResult,
          Bash.Executor,
          Bash.Function,
          Bash.OrphanSupervisor,
          Bash.ProcessSubst,
          Bash.SessionSupervisor,
          Bash.Statement,
          Bash.Variable
        ],
        "I/O & Output": [
          Bash.Output,
          Bash.Sink,
          Bash.Pipe
        ],
        "Job Control": [
          Bash.Job,
          Bash.JobProcess
        ],
        Builtins: [
          Bash.Builtin,
          Bash.Builtin.Alias,
          Bash.Builtin.Bg,
          Bash.Builtin.Break,
          Bash.Builtin.Builtin,
          Bash.Builtin.Caller,
          Bash.Builtin.Cd,
          Bash.Builtin.Colon,
          Bash.Builtin.Command,
          Bash.Builtin.Complete,
          Bash.Builtin.Continue,
          Bash.Builtin.Coproc,
          Bash.Builtin.Declare,
          Bash.Builtin.Dirs,
          Bash.Builtin.Disown,
          Bash.Builtin.Echo,
          Bash.Builtin.Enable,
          Bash.Builtin.Eval,
          Bash.Builtin.Exec,
          Bash.Builtin.Exit,
          Bash.Builtin.Export,
          Bash.Builtin.False,
          Bash.Builtin.Fc,
          Bash.Builtin.Fg,
          Bash.Builtin.Getopts,
          Bash.Builtin.Hash,
          Bash.Builtin.Help,
          Bash.Builtin.History,
          Bash.Builtin.Jobs,
          Bash.Builtin.Kill,
          Bash.Builtin.Let,
          Bash.Builtin.Local,
          Bash.Builtin.Mapfile,
          Bash.Builtin.Popd,
          Bash.Builtin.Printf,
          Bash.Builtin.Pushd,
          Bash.Builtin.Pwd,
          Bash.Builtin.Read,
          Bash.Builtin.Readonly,
          Bash.Builtin.Return,
          Bash.Builtin.Set,
          Bash.Builtin.Shift,
          Bash.Builtin.Shopt,
          Bash.Builtin.Source,
          Bash.Builtin.Suspend,
          Bash.Builtin.Test,
          Bash.Builtin.TestCommand,
          Bash.Builtin.Times,
          Bash.Builtin.Trap,
          Bash.Builtin.True,
          Bash.Builtin.Type,
          Bash.Builtin.Ulimit,
          Bash.Builtin.Umask,
          Bash.Builtin.Unalias,
          Bash.Builtin.Unset,
          Bash.Builtin.Unsupported,
          Bash.Builtin.Wait
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Bash.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_cmd, "~> 0.12"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false, warn_if_outdated: true},
      {:tidewave, "~> 0.5", only: :dev, warn_if_outdated: true},
      {:exsync, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4011) end)'"
    ]
  end
end
