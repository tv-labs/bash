defmodule Bash.Builtin.Set do
  @moduledoc """
  `set [--abefhkmnptuvxBCHP] [-o option] [arg ...]`

  This should update the special variable `$-` with the enabled flags, eg:

     $ echo $-
     himBHs

  This should update the special variable SHELLOPTS with the enabled flags, eg:

    $ echo $SHELLOPTS
    braceexpand:emacs:hashall:histexpand:history:interactive-comments:monitor

  Options:

  - `-a` - Mark variables which are modified or created for export.
  - `-b` - Notify of job termination immediately.
  - `-e` - Exit immediately if a command exits with a non-zero status.
  - `-f` - Disable file name generation (globbing).
  - `-h` - (Default on) Remember the location of commands as they are looked up.
  - `-k` - All assignment arguments are placed in the environment for a command, not just those that precede the command name.
  - `-m` - (Default on) Job control is enabled.
  - `-n` - Read commands but do not execute them.
  - `-p` - Turned on whenever the real and effective user ids do not match. Disables processing of the $ENV file and importing of shell functions.  Turning this option off causes the effective uid and gid to be set to the real uid and gid.
  - `-t` - Exit after reading and executing one command.
  - `-u` - Treat unset variables as an error when substituting.
  - `-v` - Print shell input lines as they are read.
  - `-x` - Print commands and their arguments as they are executed.
  - `-B` - (Default on) the shell will perform brace expansion
  - `-C` - If set, disallow existing regular files to be overwritten by redirection of output.
  - `-E` - If set, the ERR trap is inherited by shell functions.
  - `-H` - (Unsupported) Enable ! style history substitution.  This flag is on by default when the shell is interactive.
  - `-P` - If set, do not follow symbolic links when executing commands such as cd which change the current directory.
  - `-T` - If set, the DEBUG trap is inherited by shell functions.
  - `-` - Assign any remaining arguments to the positional parameters. The `-x` and `-v` options are turned off.
  - `-o option-name` Set the variable corresponding to option-name:
    - `allexport` - same as `-a`
    - `braceexpand` - same as `-B`
    - `emacs` - use an emacs-style line editing interface (Unsupported)
    - `errexit` - same as `-e`
    - `errtrace` - same as `-E`
    - `functrace` - same as `-T`
    - `hashall` - same as `-h`
    - `histexpand` - same as `-H`
    - `history` - enable command history
    - `ignoreeof` - the shell will not exit upon reading EOF
    - `interactive-comments` - allow comments to appear in interactive commands (Unsupported)
    - `keyword` - same as `-k`
    - `monitor` - same as `-m`
    - `noclobber` - same as `-C`
    - `noexec` - same as `-n`
    - `noglob` - same as `-f`
    - `nolog` - currently accepted but ignored
    - `notify` - same as `-b`
    - `nounset` - same as `-u`
    - `onecmd` - same as `-t`
    - `physical` - same as `-P`
    - `pipefail` - the return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status
    - `posix` - change the behavior of bash where the default operation differs from the 1003.2 standard to match the standard
    - `privileged` - same as `-p`
    - `verbose` - same as `-v`
    - `vi` - use a vi-style line editing interface (Unsupported)
    - `xtrace` - same as `-x`

  Using `+` rather than `-` causes these flags to be turned off. The flags can also be used upon invocation of the shell.  The current set of flags may be found in $-.  The remaining n ARGs are positional parameters and are assigned, in order, to $1, $2, .. $n.  If no ARGs are given, all shell variables are printed.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/set.def?h=bash-5.3
  """

  use Bash.Builtin

  alias Bash.Variable

  # Map short flags to option names
  @flag_to_option %{
    "a" => :allexport,
    "b" => :notify,
    "e" => :errexit,
    "f" => :noglob,
    "h" => :hashall,
    "k" => :keyword,
    "m" => :monitor,
    "n" => :noexec,
    "p" => :privileged,
    "t" => :onecmd,
    "u" => :nounset,
    "v" => :verbose,
    "x" => :xtrace,
    "B" => :braceexpand,
    "C" => :noclobber,
    "E" => :errtrace,
    "P" => :physical,
    "T" => :functrace
  }

  # Map long option names to canonical names
  @long_options %{
    "allexport" => :allexport,
    "braceexpand" => :braceexpand,
    "errexit" => :errexit,
    "errtrace" => :errtrace,
    "functrace" => :functrace,
    "hashall" => :hashall,
    "history" => :history,
    "ignoreeof" => :ignoreeof,
    "keyword" => :keyword,
    "monitor" => :monitor,
    "noclobber" => :noclobber,
    "noexec" => :noexec,
    "noglob" => :noglob,
    "nolog" => :nolog,
    "notify" => :notify,
    "nounset" => :nounset,
    "onecmd" => :onecmd,
    "physical" => :physical,
    "pipefail" => :pipefail,
    "posix" => :posix,
    "privileged" => :privileged,
    "verbose" => :verbose,
    "xtrace" => :xtrace
  }

  # Default options (h, m, B are on by default)
  @default_options %{
    hashall: true,
    monitor: true,
    braceexpand: true
  }

  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, options_to_set, options_to_unset, positional_args} ->
        # Get current options, starting with defaults
        current_options = Map.merge(@default_options, state.options || %{})

        # Apply changes
        # Set options to true for set, and false for unset (not drop, so merge works correctly)
        new_options =
          current_options
          |> Map.merge(Map.new(options_to_set, fn opt -> {opt, true} end))
          |> Map.merge(Map.new(options_to_unset, fn opt -> {opt, false} end))

        # Build updates
        update_state(options: new_options)

        # Handle positional parameters if provided after --
        # Wrap in list to maintain scope stack structure (set replaces current scope)
        if positional_args != nil do
          update_state(positional_params: [positional_args])
        end

        :ok

      {:print_vars} ->
        # No args - print all variables
        output = format_variables(state.variables || %{})
        write(output)
        :ok

      {:error, message} ->
        error("set: #{message}")
        {:ok, 1}
    end
  end

  defp parse_args([]), do: {:print_vars}

  defp parse_args(args) do
    parse_args(args, [], [], nil)
  end

  defp parse_args([], set_opts, unset_opts, positional) do
    {:ok, set_opts, unset_opts, positional}
  end

  # Handle -- to mark end of options and start of positional params
  defp parse_args(["--" | rest], set_opts, unset_opts, _positional) do
    {:ok, set_opts, unset_opts, rest}
  end

  # Handle -o option-name
  defp parse_args(["-o", option_name | rest], set_opts, unset_opts, positional) do
    case Map.get(@long_options, option_name) do
      nil ->
        {:error, "invalid option name: #{option_name}"}

      opt ->
        parse_args(rest, [opt | set_opts], unset_opts, positional)
    end
  end

  # Handle +o option-name (unset)
  defp parse_args(["+o", option_name | rest], set_opts, unset_opts, positional) do
    case Map.get(@long_options, option_name) do
      nil ->
        {:error, "invalid option name: #{option_name}"}

      opt ->
        parse_args(rest, set_opts, [opt | unset_opts], positional)
    end
  end

  # Handle -abc flags (possibly containing -o which needs next arg)
  defp parse_args(["-" <> flags | rest], set_opts, unset_opts, positional) when flags != "" do
    case parse_combined_flags(flags, rest, :set) do
      {:ok, opts, remaining_args} ->
        parse_args(remaining_args, opts ++ set_opts, unset_opts, positional)

      {:error, _} = err ->
        err
    end
  end

  # Handle +abc flags (unset, possibly containing +o which needs next arg)
  defp parse_args(["+" <> flags | rest], set_opts, unset_opts, positional) when flags != "" do
    case parse_combined_flags(flags, rest, :unset) do
      {:ok, opts, remaining_args} ->
        parse_args(remaining_args, set_opts, opts ++ unset_opts, positional)

      {:error, _} = err ->
        err
    end
  end

  # Anything else is treated as positional params (after implicit --)
  defp parse_args(args, set_opts, unset_opts, _positional) do
    {:ok, set_opts, unset_opts, args}
  end

  # Parse combined flags like "-euo" where "o" needs the next argument as option name
  # Returns {:ok, opts, remaining_args} or {:error, message}
  defp parse_combined_flags(flags, remaining_args, mode) do
    parse_combined_flags(String.graphemes(flags), remaining_args, [], mode)
  end

  defp parse_combined_flags([], remaining_args, opts, _mode) do
    {:ok, opts, remaining_args}
  end

  # Handle 'o' specially - it consumes the rest of the flags string as option name if non-empty,
  # otherwise consumes the next argument
  defp parse_combined_flags(["o" | rest_flags], remaining_args, opts, mode) do
    cond do
      # If there are more characters after 'o', they form the option name (like in "-opipefail")
      rest_flags != [] ->
        option_name = Enum.join(rest_flags, "")

        case Map.get(@long_options, option_name) do
          nil ->
            {:error, "invalid option name: #{option_name}"}

          opt ->
            new_opts =
              case mode do
                :set -> [opt | opts]
                :unset -> [opt | opts]
              end

            {:ok, new_opts, remaining_args}
        end

      # Otherwise consume the next argument as the option name
      true ->
        case remaining_args do
          [option_name | rest] ->
            case Map.get(@long_options, option_name) do
              nil ->
                {:error, "invalid option name: #{option_name}"}

              opt ->
                {:ok, [opt | opts], rest}
            end

          [] ->
            {:error, "-o requires an option name"}
        end
    end
  end

  defp parse_combined_flags([flag | rest], remaining_args, opts, mode) do
    case Map.get(@flag_to_option, flag) do
      nil ->
        {:error, "invalid option: -#{flag}"}

      opt ->
        parse_combined_flags(rest, remaining_args, [opt | opts], mode)
    end
  end

  defp format_variables(variables) do
    variables
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, var} ->
      value = Variable.get(var, nil)
      "#{name}=#{format_value(value)}"
    end)
    |> Kernel.<>("\n")
  end

  defp format_value(value) when is_binary(value) do
    if String.contains?(value, [" ", "\t", "\n", "'", "\""]) do
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    else
      value
    end
  end

  defp format_value(value) when is_list(value) do
    "(" <> Enum.map_join(value, " ", &format_value/1) <> ")"
  end

  defp format_value(value), do: to_string(value)

  @doc """
  Get the current shell options as a string for $- variable.
  """
  def get_flags_string(options) do
    @flag_to_option
    |> Enum.filter(fn {_flag, opt} -> Map.get(options, opt, false) end)
    |> Enum.map(fn {flag, _opt} -> flag end)
    |> Enum.sort()
    |> Enum.join("")
  end

  @doc """
  Get the current shell options as SHELLOPTS format.
  """
  def get_shellopts_string(options) do
    options
    |> Enum.filter(fn {_opt, value} -> value == true end)
    |> Enum.map(fn {opt, _} -> Atom.to_string(opt) end)
    |> Enum.sort()
    |> Enum.join(":")
  end
end
