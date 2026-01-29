defmodule Bash.Builtin.Shopt do
  @moduledoc """
  `shopt [-pqsu] [-o] [optname ...]`

  Toggle the values of variables controlling optional shell behavior.

  Options:
  - `-s` - Enable (set) each optname
  - `-u` - Disable (unset) each optname
  - `-q` - Quiet mode: suppress output, exit status indicates whether option is set
  - `-p` - Print in reusable format (default when no optnames given)
  - `-o` - Operate on set -o options instead of shopt options

  With no options, or with the -p option, a list of all settable options
  is displayed, with an indication of whether or not each is set.

  Exit Status:
  - 0 if all optnames are enabled (with -s/-u, if operation succeeded)
  - 1 if any optname is not a valid option or is disabled (when querying)
  - 2 if an invalid option is given

  Reference: https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html
  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/shopt.def?h=bash-5.3
  """
  use Bash.Builtin

  # Default shopt options - these are distinct from set -o options
  # Format: {name, default_value, description}
  @shopt_options %{
    # Globbing options
    "extglob" => {false, "extended pattern matching"},
    "nullglob" => {false, "globs with no matches expand to nothing"},
    "dotglob" => {false, "globs match dotfiles"},
    "nocaseglob" => {false, "case-insensitive globbing"},
    "globstar" => {false, "** matches directories recursively"},
    "failglob" => {false, "failed globs cause error"},
    "globasciiranges" => {false, "use C locale for range expressions in glob"},

    # Alias expansion
    "expand_aliases" => {false, "expand aliases in non-interactive shells"},

    # Source/path options
    "sourcepath" => {true, "search PATH for source command"},
    "extdebug" => {false, "extended debugging mode"},
    "extquote" => {true, "$'...' and $\"...\" in ${...} expansions"},

    # Directory options
    "cdable_vars" => {false, "cd to variable values"},
    "cdspell" => {false, "correct minor spelling errors in cd"},
    "autocd" => {false, "cd to directory names typed as commands"},
    "dirspell" => {false, "correct spelling during completion"},
    "direxpand" => {false, "expand directory names during completion"},

    # History options
    "cmdhist" => {true, "save multi-line commands as single entry"},
    "lithist" => {false, "preserve newlines in multi-line history"},
    "histappend" => {false, "append to history file"},
    "histreedit" => {false, "allow re-edit of failed history substitution"},
    "histverify" => {false, "allow review of history substitution"},

    # Completion options
    "hostcomplete" => {true, "hostname completion"},
    "no_empty_cmd_completion" => {false, "don't complete on empty line"},
    "progcomp" => {true, "programmable completion"},
    "progcomp_alias" => {false, "allow alias expansion for completion"},
    "complete_fullquote" => {true, "quote completions with metacharacters"},
    "force_fignore" => {true, "FIGNORE applies to completion"},

    # Shell behavior
    "checkhash" => {false, "check hash table before executing"},
    "checkjobs" => {false, "check for jobs before exit"},
    "checkwinsize" => {true, "check window size after each command"},
    "execfail" => {false, "don't exit if exec fails"},
    "huponexit" => {false, "send SIGHUP on shell exit"},
    "interactive_comments" => {true, "allow comments in interactive mode"},
    "lastpipe" => {false, "run last pipeline command in current shell"},
    "login_shell" => {false, "shell is a login shell (read-only)"},
    "mailwarn" => {false, "warn if mail file has been accessed"},
    "gnu_errfmt" => {false, "use GNU error format"},
    "shift_verbose" => {false, "shift prints error when count exceeds $#"},
    "xpg_echo" => {false, "echo expands backslash-escape sequences"},

    # Prompting
    "promptvars" => {true, "prompt strings undergo expansion"},

    # Restricted shell
    "restricted_shell" => {false, "shell is restricted (read-only)"},

    # Compat options
    "compat31" => {false, "bash 3.1 compatibility"},
    "compat32" => {false, "bash 3.2 compatibility"},
    "compat40" => {false, "bash 4.0 compatibility"},
    "compat41" => {false, "bash 4.1 compatibility"},
    "compat42" => {false, "bash 4.2 compatibility"},
    "compat43" => {false, "bash 4.3 compatibility"},
    "compat44" => {false, "bash 4.4 compatibility"},

    # Other
    "inherit_errexit" => {false, "inherit errexit in command substitution"},
    "localvar_inherit" => {false, "local variables inherit from previous scope"},
    "localvar_unset" => {false, "unset local variables at function exit"},
    "assoc_expand_once" => {false, "evaluate associative array subscripts once"}
  }

  # Map set -o option names for -o flag support
  @set_o_options %{
    "allexport" => :allexport,
    "braceexpand" => :braceexpand,
    "emacs" => :emacs,
    "errexit" => :errexit,
    "errtrace" => :errtrace,
    "functrace" => :functrace,
    "hashall" => :hashall,
    "histexpand" => :histexpand,
    "history" => :history,
    "ignoreeof" => :ignoreeof,
    "interactive-comments" => :interactive_comments,
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
    "vi" => :vi,
    "xtrace" => :xtrace
  }

  defbash execute(args, state) do
    case parse_args(args) do
      {:ok, opts, optnames} ->
        case execute_shopt(opts, optnames, state) do
          {:error, message} ->
            error(message)
            {:ok, 2}

          result ->
            result
        end

      {:error, message} ->
        error("shopt: #{message}")
        {:ok, 2}
    end
  end

  # Parse command line arguments
  defp parse_args(args) do
    parse_args(
      args,
      %{set: false, unset: false, quiet: false, print: false, use_set_o: false},
      []
    )
  end

  defp parse_args([], opts, optnames) do
    {:ok, opts, optnames}
  end

  defp parse_args(["-s" | rest], opts, optnames) do
    parse_args(rest, %{opts | set: true}, optnames)
  end

  defp parse_args(["-u" | rest], opts, optnames) do
    parse_args(rest, %{opts | unset: true}, optnames)
  end

  defp parse_args(["-q" | rest], opts, optnames) do
    parse_args(rest, %{opts | quiet: true}, optnames)
  end

  defp parse_args(["-p" | rest], opts, optnames) do
    parse_args(rest, %{opts | print: true}, optnames)
  end

  defp parse_args(["-o" | rest], opts, optnames) do
    parse_args(rest, %{opts | use_set_o: true}, optnames)
  end

  # Handle combined flags like -su, -pq, -so, etc. or single flags like -x
  defp parse_args(["-" <> flags | rest], opts, optnames) when flags != "" do
    case parse_combined_flags(flags, opts) do
      {:ok, new_opts} ->
        parse_args(rest, new_opts, optnames)

      {:error, _} = err ->
        err
    end
  end

  defp parse_args([arg | rest], opts, optnames) do
    # Anything else is an option name
    parse_args(rest, opts, optnames ++ [arg])
  end

  # Parse combined flags
  defp parse_combined_flags(flags, opts) when is_binary(flags) do
    parse_combined_flags(String.graphemes(flags), opts)
  end

  defp parse_combined_flags(flags, opts) when is_list(flags) do
    do_parse_combined_flags(flags, opts)
  end

  defp do_parse_combined_flags([], opts), do: {:ok, opts}

  defp do_parse_combined_flags(["s" | rest], opts) do
    do_parse_combined_flags(rest, %{opts | set: true})
  end

  defp do_parse_combined_flags(["u" | rest], opts) do
    do_parse_combined_flags(rest, %{opts | unset: true})
  end

  defp do_parse_combined_flags(["q" | rest], opts) do
    do_parse_combined_flags(rest, %{opts | quiet: true})
  end

  defp do_parse_combined_flags(["p" | rest], opts) do
    do_parse_combined_flags(rest, %{opts | print: true})
  end

  defp do_parse_combined_flags(["o" | rest], opts) do
    do_parse_combined_flags(rest, %{opts | use_set_o: true})
  end

  defp do_parse_combined_flags([flag | _], _opts) do
    {:error, "-#{flag}: invalid option"}
  end

  # Execute shopt command based on parsed options
  defp execute_shopt(opts, optnames, session_state) do
    cond do
      # -s and -u are mutually exclusive
      opts.set and opts.unset ->
        {:error, "shopt: cannot set and unset shell options simultaneously"}

      # Set options
      opts.set ->
        set_options(optnames, opts, session_state)

      # Unset options
      opts.unset ->
        unset_options(optnames, opts, session_state)

      # Query or print options
      true ->
        query_options(optnames, opts, session_state)
    end
  end

  # Set (enable) options
  defp set_options(optnames, opts, session_state) do
    if Enum.empty?(optnames) do
      :ok
    else
      {valid, invalid} = validate_optnames(optnames, opts.use_set_o)

      if Enum.empty?(invalid) do
        # Build option updates
        option_updates =
          Enum.reduce(valid, %{}, fn optname, acc ->
            key = option_key(optname, opts.use_set_o)
            Map.put(acc, key, true)
          end)

        new_options = Map.merge(session_state.options || %{}, option_updates)
        update_state(options: new_options)
        :ok
      else
        Enum.each(invalid, fn name -> error("shopt: #{name}: invalid shell option name") end)
        {:ok, 1}
      end
    end
  end

  # Unset (disable) options
  defp unset_options(optnames, opts, session_state) do
    if Enum.empty?(optnames) do
      :ok
    else
      {valid, invalid} = validate_optnames(optnames, opts.use_set_o)

      if Enum.empty?(invalid) do
        # Build option updates
        option_updates =
          Enum.reduce(valid, %{}, fn optname, acc ->
            key = option_key(optname, opts.use_set_o)
            Map.put(acc, key, false)
          end)

        new_options = Map.merge(session_state.options || %{}, option_updates)
        update_state(options: new_options)
        :ok
      else
        Enum.each(invalid, fn name -> error("shopt: #{name}: invalid shell option name") end)
        {:ok, 1}
      end
    end
  end

  # Query options
  defp query_options(optnames, opts, session_state) do
    if Enum.empty?(optnames) do
      # Print all options
      print_all_options(opts, session_state)
    else
      # Query specific options
      query_specific_options(optnames, opts, session_state)
    end
  end

  # Print all options
  defp print_all_options(opts, session_state) do
    options_map = if opts.use_set_o, do: @set_o_options, else: @shopt_options

    options_map
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn optname ->
      is_on = get_option_value(optname, opts.use_set_o, session_state)

      line =
        if opts.print do
          # Reusable format: shopt -s/-u optname
          flag = if is_on, do: "-s", else: "-u"
          prefix = if opts.use_set_o, do: "shopt -o ", else: "shopt "
          "#{prefix}#{flag} #{optname}"
        else
          # Standard format: optname on/off
          status = if is_on, do: "on", else: "off"
          String.pad_trailing(optname, 20) <> "\t" <> status
        end

      puts(line)
    end)

    :ok
  end

  # Query specific options
  defp query_specific_options(optnames, opts, session_state) do
    {valid, invalid} = validate_optnames(optnames, opts.use_set_o)

    if not Enum.empty?(invalid) do
      Enum.each(invalid, fn name -> error("shopt: #{name}: invalid shell option name") end)
      {:ok, 1}
    else
      # Check if all requested options are enabled
      all_enabled =
        Enum.all?(valid, fn optname ->
          get_option_value(optname, opts.use_set_o, session_state)
        end)

      unless opts.quiet do
        Enum.each(valid, fn optname ->
          is_on = get_option_value(optname, opts.use_set_o, session_state)

          line =
            if opts.print do
              flag = if is_on, do: "-s", else: "-u"
              prefix = if opts.use_set_o, do: "shopt -o ", else: "shopt "
              "#{prefix}#{flag} #{optname}"
            else
              status = if is_on, do: "on", else: "off"
              String.pad_trailing(optname, 20) <> "\t" <> status
            end

          puts(line)
        end)
      end

      exit_code = if all_enabled, do: 0, else: 1
      {:ok, exit_code}
    end
  end

  # Validate option names and return {valid, invalid}
  defp validate_optnames(optnames, use_set_o) do
    valid_options = if use_set_o, do: Map.keys(@set_o_options), else: Map.keys(@shopt_options)

    Enum.split_with(optnames, fn name ->
      name in valid_options
    end)
  end

  # Get the key to use in the options map
  defp option_key(optname, true = _use_set_o) do
    # For set -o options, use the atom key
    Map.get(@set_o_options, optname, String.to_atom(optname))
  end

  defp option_key(optname, false = _use_set_o) do
    # For shopt options, prefix with :shopt_ to distinguish from set options
    String.to_atom("shopt_" <> optname)
  end

  # Get the current value of an option
  defp get_option_value(optname, true = _use_set_o, session_state) do
    key = Map.get(@set_o_options, optname)
    Map.get(session_state.options || %{}, key, false)
  end

  defp get_option_value(optname, false = _use_set_o, session_state) do
    key = String.to_atom("shopt_" <> optname)
    # Get default value from @shopt_options if not set
    default =
      case Map.get(@shopt_options, optname) do
        {default_val, _desc} -> default_val
        nil -> false
      end

    Map.get(session_state.options || %{}, key, default)
  end

  # Get all shopt option names.
  @doc false
  def shopt_option_names do
    Map.keys(@shopt_options)
  end

  # Get the default value for a shopt option.
  @doc false
  def default_value(optname) do
    case Map.get(@shopt_options, optname) do
      {default, _desc} -> default
      nil -> nil
    end
  end

  # Check if an option name is valid.
  @doc false
  def valid_option?(optname, use_set_o \\ false) do
    if use_set_o do
      Map.has_key?(@set_o_options, optname)
    else
      Map.has_key?(@shopt_options, optname)
    end
  end
end
