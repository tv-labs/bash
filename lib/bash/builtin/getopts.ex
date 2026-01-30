defmodule Bash.Builtin.Getopts do
  @moduledoc """
  `getopts optstring name [arg]`

  Getopts is used by shell procedures to parse positional parameters.

  OPTSTRING contains the option letters to be recognized; if a letter is followed by a colon, the option is expected to have an argument, which should be separated from it by white space.

  Each time it is invoked, getopts will place the next option in the shell variable $name, initializing name if it does not exist, and the index of the next argument to be processed into the shell variable OPTIND.  OPTIND is initialized to 1 each time the shell or a shell script is invoked.  When an option requires an argument, getopts places that argument into the shell variable OPTARG.

  getopts reports errors in one of two ways.  If the first character of OPTSTRING is a colon, getopts uses silent error reporting.  In this mode, no error messages are printed.  If an invalid option is seen, getopts places the option character found into OPTARG.  If a required argument is not found, getopts places a ':' into NAME and sets OPTARG to the option character found.  If getopts is not in silent mode, and an invalid option is seen, getopts places '?' into NAME and unsets OPTARG.  If a required argument is not found, a '?' is placed in NAME, OPTARG is unset, and a diagnostic message is printed.

  If the shell variable OPTERR has the value 0, getopts disables the printing of error messages, even if the first character of OPTSTRING is not a colon.  OPTERR has the value 1 by default.

  Getopts normally parses the positional parameters ($0 - $9), but if more arguments are given, they are parsed instead.

  References:
  - https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/getopt.c?h=bash-5.3
  - https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/getopts.def?h=bash-5.3
  - https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/bashgetopt?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Variable

  defbash execute(args, state) do
    case args do
      [] ->
        error("getopts: usage: getopts optstring name [arg ...]")
        {:ok, 2}

      [_optstring] ->
        error("getopts: usage: getopts optstring name [arg ...]")
        {:ok, 2}

      [optstring, name | rest_args] ->
        # Validate variable name
        if not valid_var_name?(name) do
          error("getopts: `#{name}': not a valid identifier")
          {:ok, 2}
        else
          # Get the arguments to parse
          parse_args =
            if Enum.empty?(rest_args) do
              # Use positional parameters
              get_positional_params(state)
            else
              rest_args
            end

          # Parse optstring
          {silent_mode, opts_with_args, valid_opts} = parse_optstring(optstring)

          # Check OPTERR - if set to 0, also use silent mode
          opterr = get_variable_value(state, "OPTERR")
          silent_mode = silent_mode || opterr == "0"

          # Get current OPTIND (1-based, defaults to 1)
          optind = get_optind(state)

          # Process the next option
          process_option(parse_args, optind, name, valid_opts, opts_with_args, silent_mode, state)
        end
    end
  end

  # Parse the optstring to extract:
  # - silent_mode: true if optstring starts with ':'
  # - opts_with_args: set of option characters that require arguments
  # - valid_opts: set of all valid option characters
  defp parse_optstring(optstring) do
    {silent_mode, rest} =
      case optstring do
        ":" <> rest -> {true, rest}
        other -> {false, other}
      end

    {valid_opts, opts_with_args} = parse_opts(rest, MapSet.new(), MapSet.new())

    {silent_mode, opts_with_args, valid_opts}
  end

  # Parse option characters from the optstring
  defp parse_opts("", valid_opts, opts_with_args) do
    {valid_opts, opts_with_args}
  end

  defp parse_opts(<<opt::utf8, ":", rest::binary>>, valid_opts, opts_with_args) do
    opt_char = <<opt::utf8>>
    parse_opts(rest, MapSet.put(valid_opts, opt_char), MapSet.put(opts_with_args, opt_char))
  end

  defp parse_opts(<<opt::utf8, rest::binary>>, valid_opts, opts_with_args) do
    opt_char = <<opt::utf8>>
    parse_opts(rest, MapSet.put(valid_opts, opt_char), opts_with_args)
  end

  # Process the next option from args
  defp process_option(args, optind, name, valid_opts, opts_with_args, silent_mode, session_state) do
    # OPTIND is 1-based, args is 0-indexed
    arg_index = optind - 1

    cond do
      # No more arguments
      arg_index >= length(args) ->
        finish_processing(name, optind)

      true ->
        arg = Enum.at(args, arg_index)

        process_arg(
          arg,
          args,
          arg_index,
          optind,
          name,
          valid_opts,
          opts_with_args,
          silent_mode,
          session_state
        )
    end
  end

  # Process a single argument
  defp process_arg(
         arg,
         args,
         arg_index,
         optind,
         name,
         valid_opts,
         opts_with_args,
         silent_mode,
         session_state
       ) do
    cond do
      # End of options marker
      arg == "--" ->
        finish_processing(name, optind + 1)

      # Not an option (doesn't start with -)
      not String.starts_with?(arg, "-") ->
        finish_processing(name, optind)

      # Just "-" is not an option
      arg == "-" ->
        finish_processing(name, optind)

      # Option argument
      true ->
        # Get the option character(s) after the -
        # We need to track position within the option string for bundled options
        opt_offset = get_opt_offset(session_state)
        opt_chars = String.slice(arg, 1..-1//1)

        if opt_offset >= String.length(opt_chars) do
          # Move to next argument and reset offset
          new_session_state = clear_opt_offset(session_state)

          process_option(
            args,
            optind + 1,
            name,
            valid_opts,
            opts_with_args,
            silent_mode,
            new_session_state
          )
        else
          opt_char = String.at(opt_chars, opt_offset)
          remaining_in_arg = String.slice(opt_chars, (opt_offset + 1)..-1//1)

          handle_option(
            opt_char,
            remaining_in_arg,
            args,
            arg_index,
            optind,
            opt_offset,
            name,
            valid_opts,
            opts_with_args,
            silent_mode,
            session_state
          )
        end
    end
  end

  # Handle a single option character
  defp handle_option(
         opt_char,
         remaining_in_arg,
         args,
         arg_index,
         optind,
         opt_offset,
         name,
         valid_opts,
         opts_with_args,
         silent_mode,
         session_state
       ) do
    cond do
      # Invalid option
      not MapSet.member?(valid_opts, opt_char) ->
        handle_invalid_option(
          opt_char,
          remaining_in_arg,
          optind,
          opt_offset,
          name,
          silent_mode,
          session_state
        )

      # Option requires argument
      MapSet.member?(opts_with_args, opt_char) ->
        handle_option_with_arg(
          opt_char,
          remaining_in_arg,
          args,
          arg_index,
          optind,
          name,
          silent_mode
        )

      # Option without argument
      true ->
        handle_simple_option(opt_char, remaining_in_arg, optind, opt_offset, name)
    end
  end

  # Handle an invalid option
  defp handle_invalid_option(
         opt_char,
         remaining_in_arg,
         optind,
         opt_offset,
         name,
         silent_mode,
         session_state
       ) do
    {new_optind, new_offset} =
      if remaining_in_arg == "" do
        {optind + 1, 0}
      else
        {optind, opt_offset + 1}
      end

    var_updates =
      if silent_mode do
        # Silent mode: set name to ?, OPTARG to the invalid option
        %{
          name => Variable.new("?"),
          "OPTARG" => Variable.new(opt_char),
          "OPTIND" => Variable.new(to_string(new_optind)),
          "__GETOPTS_OFFSET__" => Variable.new(to_string(new_offset))
        }
      else
        # Normal mode: set name to ?, unset OPTARG, print error
        base_updates = %{
          name => Variable.new("?"),
          "OPTIND" => Variable.new(to_string(new_optind)),
          "__GETOPTS_OFFSET__" => Variable.new(to_string(new_offset))
        }

        # Clear OPTARG in normal mode
        if Map.has_key?(session_state.variables, "OPTARG") do
          Map.put(base_updates, "OPTARG", Variable.new(""))
        else
          base_updates
        end
      end

    unless silent_mode do
      Bash.Context.error("getopts: illegal option -- #{opt_char}")
    end

    Bash.Context.update_state(variables: var_updates)
    :ok
  end

  # Handle an option that requires an argument
  defp handle_option_with_arg(
         opt_char,
         remaining_in_arg,
         args,
         arg_index,
         optind,
         name,
         silent_mode
       ) do
    cond do
      # Argument attached to option (e.g., -bARG)
      remaining_in_arg != "" ->
        var_updates = %{
          name => Variable.new(opt_char),
          "OPTARG" => Variable.new(remaining_in_arg),
          "OPTIND" => Variable.new(to_string(optind + 1)),
          "__GETOPTS_OFFSET__" => Variable.new("0")
        }

        Bash.Context.update_state(variables: var_updates)
        :ok

      # Argument is the next word
      arg_index + 1 < length(args) ->
        optarg = Enum.at(args, arg_index + 1)

        var_updates = %{
          name => Variable.new(opt_char),
          "OPTARG" => Variable.new(optarg),
          "OPTIND" => Variable.new(to_string(optind + 2)),
          "__GETOPTS_OFFSET__" => Variable.new("0")
        }

        Bash.Context.update_state(variables: var_updates)
        :ok

      # Missing required argument
      true ->
        handle_missing_argument(opt_char, optind, name, silent_mode)
    end
  end

  # Handle missing required argument
  defp handle_missing_argument(opt_char, optind, name, silent_mode) do
    var_updates =
      if silent_mode do
        # Silent mode: set name to :, OPTARG to the option character
        %{
          name => Variable.new(":"),
          "OPTARG" => Variable.new(opt_char),
          "OPTIND" => Variable.new(to_string(optind + 1)),
          "__GETOPTS_OFFSET__" => Variable.new("0")
        }
      else
        # Normal mode: set name to ?, unset OPTARG, print error
        %{
          name => Variable.new("?"),
          "OPTARG" => Variable.new(""),
          "OPTIND" => Variable.new(to_string(optind + 1)),
          "__GETOPTS_OFFSET__" => Variable.new("0")
        }
      end

    unless silent_mode do
      Bash.Context.error("getopts: option requires an argument -- #{opt_char}")
    end

    Bash.Context.update_state(variables: var_updates)
    :ok
  end

  # Handle a simple option (no argument required)
  defp handle_simple_option(opt_char, remaining_in_arg, optind, opt_offset, name) do
    {new_optind, new_offset} =
      if remaining_in_arg == "" do
        {optind + 1, 0}
      else
        {optind, opt_offset + 1}
      end

    # Clear OPTARG for options without arguments (bash behavior)
    var_updates = %{
      name => Variable.new(opt_char),
      "OPTARG" => Variable.new(""),
      "OPTIND" => Variable.new(to_string(new_optind)),
      "__GETOPTS_OFFSET__" => Variable.new(to_string(new_offset))
    }

    Bash.Context.update_state(variables: var_updates)
    :ok
  end

  # Called when there are no more options to process
  defp finish_processing(name, optind) do
    var_updates = %{
      name => Variable.new("?"),
      "OPTIND" => Variable.new(to_string(optind)),
      "__GETOPTS_OFFSET__" => Variable.new("0")
    }

    Bash.Context.update_state(variables: var_updates)
    {:ok, 1}
  end

  # Helper to get OPTIND value (defaults to 1)
  defp get_optind(session_state) do
    case get_variable_value(session_state, "OPTIND") do
      nil ->
        1

      "" ->
        1

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 1 -> n
          _ -> 1
        end
    end
  end

  # Helper to get the offset within a bundled option (e.g., -abc)
  defp get_opt_offset(session_state) do
    case get_variable_value(session_state, "__GETOPTS_OFFSET__") do
      nil ->
        0

      "" ->
        0

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end
    end
  end

  # Helper to clear the offset when moving to next argument
  defp clear_opt_offset(session_state) do
    # We don't actually modify session_state here, we just return it
    # The offset will be handled via var_updates in the result
    session_state
  end

  # Helper to get positional parameters from session state
  defp get_positional_params(session_state) do
    case session_state.positional_params do
      [params | _] when is_list(params) -> params
      _ -> []
    end
  end

  # Helper to get a variable value from session state
  defp get_variable_value(session_state, var_name) do
    case Map.get(session_state.variables, var_name) do
      nil -> nil
      %Variable{} = var -> Variable.get(var, nil)
      value when is_binary(value) -> value
    end
  end

  # Validate variable name
  defp valid_var_name?(name) do
    String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)
  end
end
