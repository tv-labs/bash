defmodule Bash.Builtin.Help do
  @moduledoc """
  `help [-dms] [pattern ...]`

  Display helpful information about builtin commands.

  If PATTERN is specified, gives detailed help on all commands matching PATTERN,
  otherwise a list of the builtins is printed.

  Options:
    -d    output short description for each topic
    -m    display usage in pseudo-manpage format
    -s    output only a short usage synopsis for each topic matching PATTERN

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html#index-help
  """
  use Bash.Builtin

  alias Bash.Builtin, as: BuiltinRegistry

  # Help text for implemented builtins
  @builtin_help %{
    "." => %{
      synopsis: ". filename [arguments]",
      short: "Execute commands from a file in the current shell."
    },
    ":" => %{
      synopsis: ":",
      short: "Null command."
    },
    "[" => %{
      synopsis: "[ arg... ]",
      short: "Evaluate conditional expression."
    },
    "alias" => %{
      synopsis: "alias [-p] [name[=value] ... ]",
      short: "Define or display aliases."
    },
    "bg" => %{
      synopsis: "bg [job_spec ...]",
      short: "Move jobs to the background."
    },
    "break" => %{
      synopsis: "break [n]",
      short: "Exit for, while, or until loops."
    },
    "builtin" => %{
      synopsis: "builtin [shell-builtin [arg ...]]",
      short: "Execute shell builtins."
    },
    "cd" => %{
      synopsis: "cd [-L|[-P [-e]] [-@]] [dir]",
      short: "Change the shell working directory."
    },
    "command" => %{
      synopsis: "command [-pVv] command [arg ...]",
      short: "Execute a simple command or display information about commands."
    },
    "continue" => %{
      synopsis: "continue [n]",
      short: "Resume for, while, or until loops."
    },
    "declare" => %{
      synopsis: "declare [-aAfFgiIlnrtux] [-p] [name[=value] ...]",
      short: "Set variable values and attributes."
    },
    "dirs" => %{
      synopsis: "dirs [-clpv] [+N] [-N]",
      short: "Display directory stack."
    },
    "echo" => %{
      synopsis: "echo [-neE] [arg ...]",
      short: "Write arguments to the standard output."
    },
    "eval" => %{
      synopsis: "eval [arg ...]",
      short: "Execute arguments as a shell command."
    },
    "exit" => %{
      synopsis: "exit [n]",
      short: "Exit the shell."
    },
    "export" => %{
      synopsis: "export [-fn] [name[=value] ...] or export -p",
      short: "Set export attribute for shell variables."
    },
    "false" => %{
      synopsis: "false",
      short: "Return an unsuccessful result."
    },
    "fg" => %{
      synopsis: "fg [job_spec]",
      short: "Move job to the foreground."
    },
    "getopts" => %{
      synopsis: "getopts optstring name [arg ...]",
      short: "Parse option arguments."
    },
    "hash" => %{
      synopsis: "hash [-lr] [-p pathname] [-dt] [name ...]",
      short: "Remember or display program locations."
    },
    "help" => %{
      synopsis: "help [-dms] [pattern ...]",
      short: "Display information about builtin commands."
    },
    "history" => %{
      synopsis: "history [-c] [-d offset] [n] or history -awrn [filename]",
      short: "Display or manipulate the history list."
    },
    "jobs" => %{
      synopsis: "jobs [-lnprs] [jobspec ...] or jobs -x command [args]",
      short: "Display status of jobs."
    },
    "kill" => %{
      synopsis: "kill [-s sigspec | -n signum | -sigspec] pid | jobspec ...",
      short: "Send a signal to a job."
    },
    "let" => %{
      synopsis: "let arg [arg ...]",
      short: "Evaluate arithmetic expressions."
    },
    "local" => %{
      synopsis: "local [option] name[=value] ...",
      short: "Define local variables."
    },
    "popd" => %{
      synopsis: "popd [-n] [+N | -N]",
      short: "Remove directories from stack."
    },
    "printf" => %{
      synopsis: "printf [-v var] format [arguments]",
      short: "Formats and prints ARGUMENTS under control of the FORMAT."
    },
    "pushd" => %{
      synopsis: "pushd [-n] [+N | -N | dir]",
      short: "Add directories to stack."
    },
    "pwd" => %{
      synopsis: "pwd [-LP]",
      short: "Print the name of the current working directory."
    },
    "read" => %{
      synopsis:
        "read [-ers] [-a array] [-d delim] [-n nchars] [-p prompt] [-t timeout] [name ...]",
      short: "Read a line from the standard input and split it into fields."
    },
    "readonly" => %{
      synopsis: "readonly [-aAf] [name[=value] ...] or readonly -p",
      short: "Mark shell variables as unchangeable."
    },
    "return" => %{
      synopsis: "return [n]",
      short: "Return from a shell function."
    },
    "set" => %{
      synopsis: "set [-abefhkmnptuvxBCHP] [-o option-name] [--] [arg ...]",
      short: "Set or unset values of shell options and positional parameters."
    },
    "shift" => %{
      synopsis: "shift [n]",
      short: "Shift positional parameters."
    },
    "shopt" => %{
      synopsis: "shopt [-pqsu] [-o] [optname ...]",
      short: "Set and unset shell options."
    },
    "source" => %{
      synopsis: "source filename [arguments]",
      short: "Execute commands from a file in the current shell."
    },
    "test" => %{
      synopsis: "test [expr]",
      short: "Evaluate conditional expression."
    },
    "times" => %{
      synopsis: "times",
      short: "Display process times."
    },
    "trap" => %{
      synopsis: "trap [-lp] [[arg] signal_spec ...]",
      short: "Trap signals and other events."
    },
    "true" => %{
      synopsis: "true",
      short: "Return a successful result."
    },
    "type" => %{
      synopsis: "type [-afptP] name [name ...]",
      short: "Display information about command type."
    },
    "typeset" => %{
      synopsis: "typeset [-aAfFgiIlnrtux] [-p] name[=value] ...",
      short: "Set variable values and attributes."
    },
    "unalias" => %{
      synopsis: "unalias [-a] name [name ...]",
      short: "Remove each NAME from the list of defined aliases."
    },
    "unset" => %{
      synopsis: "unset [-f] [-v] [-n] [name ...]",
      short: "Unset values and attributes of shell variables and functions."
    },
    "wait" => %{
      synopsis: "wait [-fn] [-p var] [id ...]",
      short: "Wait for job completion and return exit status."
    }
  }

  defbash execute(args, _state) do
    {opts, patterns} = parse_args(args)

    if Enum.empty?(patterns) do
      # No patterns - list all builtins
      list_all_builtins()
    else
      # Show help for matching builtins
      show_help_for_patterns(patterns, opts)
    end
  end

  defp parse_args(args) do
    parse_args(args, %{short_desc: false, manpage: false, synopsis: false}, [])
  end

  defp parse_args([], opts, patterns) do
    {opts, Enum.reverse(patterns)}
  end

  defp parse_args(["-d" | rest], opts, patterns) do
    parse_args(rest, %{opts | short_desc: true}, patterns)
  end

  defp parse_args(["-m" | rest], opts, patterns) do
    parse_args(rest, %{opts | manpage: true}, patterns)
  end

  defp parse_args(["-s" | rest], opts, patterns) do
    parse_args(rest, %{opts | synopsis: true}, patterns)
  end

  defp parse_args(["-" <> flags | rest], opts, patterns) when byte_size(flags) > 0 do
    new_opts = process_flags(String.graphemes(flags), opts)
    parse_args(rest, new_opts, patterns)
  end

  defp parse_args([pattern | rest], opts, patterns) do
    parse_args(rest, opts, [pattern | patterns])
  end

  defp process_flags([], opts), do: opts

  defp process_flags(["d" | rest], opts) do
    process_flags(rest, %{opts | short_desc: true})
  end

  defp process_flags(["m" | rest], opts) do
    process_flags(rest, %{opts | manpage: true})
  end

  defp process_flags(["s" | rest], opts) do
    process_flags(rest, %{opts | synopsis: true})
  end

  defp process_flags([_ | rest], opts) do
    process_flags(rest, opts)
  end

  defp list_all_builtins do
    builtins =
      BuiltinRegistry.implemented_builtins()
      |> Enum.sort()
      |> Enum.chunk_every(6)
      |> Enum.map(fn chunk ->
        Enum.map_join(chunk, " ", fn name ->
          String.pad_trailing(name, 12)
        end)
      end)
      |> Enum.join("\n")

    header = """
    GNU bash, version 5.3.0(1)-release (bash-elixir)
    These shell commands are defined internally. Type `help' to see this list.
    Type `help name' to find out more about the function `name'.

    """

    write(header <> builtins <> "\n")
    :ok
  end

  defp show_help_for_patterns(patterns, opts) do
    {exit_code, output_acc, error_acc} =
      Enum.reduce(patterns, {0, [], []}, fn pattern, {code, out_acc, err_acc} ->
        matching = find_matching_builtins(pattern)

        if Enum.empty?(matching) do
          {1, out_acc, ["help: no help topics match `#{pattern}'." | err_acc]}
        else
          help_text = Enum.map_join(matching, "", fn name -> format_help(name, opts) end)
          {code, [help_text | out_acc], err_acc}
        end
      end)

    stdout_text = output_acc |> Enum.reverse() |> Enum.join("")
    stderr_text = error_acc |> Enum.reverse() |> Enum.join("\n")

    if stdout_text != "", do: write(stdout_text)
    if stderr_text != "", do: error(stderr_text)

    {:ok, exit_code}
  end

  defp find_matching_builtins(pattern) do
    # Simple glob-style matching (support * and ?)
    # Escape regex special characters first, then convert glob wildcards
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    regex = "^#{regex}$"

    BuiltinRegistry.implemented_builtins()
    |> Enum.filter(fn name -> String.match?(name, ~r/#{regex}/) end)
    |> Enum.sort()
  end

  defp format_help(name, opts) do
    help = Map.get(@builtin_help, name, default_help(name))

    cond do
      opts.synopsis ->
        # -s: Just the synopsis
        "#{name}: #{help.synopsis}\n"

      opts.short_desc ->
        # -d: Short description
        "#{name} - #{help.short}\n"

      opts.manpage ->
        # -m: Man page format
        """
        NAME
            #{name} - #{help.short}

        SYNOPSIS
            #{help.synopsis}

        """

      true ->
        # Default: synopsis and description
        "#{name}: #{help.synopsis}\n    #{help.short}\n"
    end
  end

  defp default_help(name) do
    %{
      synopsis: name,
      short: "No help available for #{name}."
    }
  end
end
