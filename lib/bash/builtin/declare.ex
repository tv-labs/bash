defmodule Bash.Builtin.Declare do
  @moduledoc """
  `declare [-afFirtx] [-p] [name[=value] ...]`

  Declare variables and/or give them attributes.  If no NAMEs are given, then display the values of variables instead.  The -p option will display the attributes and values of each NAME.

  The flags are:

  - `-a` - to make NAMEs indexed arrays
  - `-A` - to make NAMEs associative arrays
  - `-f` - to select from among function names only
  - `-F` - to display function names without definitions
  - `-i` - to make NAMEs have the "integer" attribute
  - `-r` - to make NAMEs readonly
  - `-x` - to make NAMEs export
  - `-p` - display variable declarations

  Variables with the integer attribute have arithmetic evaluation (see `let`) done when the variable is assigned to.

  When displaying values of variables, -f displays a function's name and definition.  The -F option restricts the display to function name only.

  Using `+` instead of `-` turns off the given attribute instead.  When used in a function, makes NAMEs local, as with the `local` command.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/declare.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Arithmetic
  alias Bash.AST
  alias Bash.AST.Helpers
  alias Bash.Variable

  @flags %{
    "a" => {:array_type, :indexed},
    "A" => {:array_type, :associative},
    "i" => {:integer, true},
    "l" => {:lowercase, true},
    "u" => {:uppercase, true},
    "r" => {:readonly, true},
    "x" => {:export, true},
    "n" => :nameref_mode,
    "f" => :function_mode,
    "F" => :function_names_only,
    "p" => :print_mode
  }

  defbash execute(args, state) do
    {opts, names} = parse_args(args)

    cond do
      # Function mode (with or without names) - list/show functions
      opts.function_mode ->
        handle_functions(names, state, opts)

      # No names and no special mode - print all variables
      Enum.empty?(names) ->
        print_all_variables(state)

      # Print mode with names - print specific variables
      opts.print_mode and not Enum.empty?(names) ->
        print_variables(names, state)

      # Default - declare/modify variables
      true ->
        declare_variables(names, state, opts)
    end
  end

  # Parse command-line arguments into options and names
  defp parse_args(args) do
    {opts, names} =
      Enum.reduce(args, {%{set_attrs: %{}, remove_attrs: MapSet.new()}, []}, fn arg,
                                                                                {opts, names} ->
        cond do
          # Non-string arguments (like ArrayAssignment nodes) - pass through as names
          not is_binary(arg) ->
            {opts, names ++ [arg]}

          # Option flags: -abc or +abc
          String.starts_with?(arg, "-") and String.length(arg) > 1 and
              not String.contains?(arg, "=") ->
            flags = String.graphemes(String.slice(arg, 1..-1//1))
            new_opts = process_flags(flags, opts, :set)
            {new_opts, names}

          String.starts_with?(arg, "+") and String.length(arg) > 1 and
              not String.contains?(arg, "=") ->
            flags = String.graphemes(String.slice(arg, 1..-1//1))
            new_opts = process_flags(flags, opts, :unset)
            {new_opts, names}

          # Name or name=value
          true ->
            {opts, names ++ [arg]}
        end
      end)

    # Set boolean flags
    opts =
      opts
      |> Map.put(:print_mode, opts[:print_mode] || false)
      |> Map.put(:function_mode, opts[:function_mode] || false)
      |> Map.put(:function_names_only, opts[:function_names_only] || false)
      |> Map.put(:nameref_mode, opts[:nameref_mode] || false)

    {opts, names}
  end

  # Process individual flags
  defp process_flags([], opts, _mode), do: opts

  defp process_flags([flag | rest], opts, mode) do
    case Map.get(@flags, flag) do
      nil ->
        # Unknown flag - ignore for now
        process_flags(rest, opts, mode)

      :print_mode ->
        process_flags(rest, Map.put(opts, :print_mode, true), mode)

      :function_mode ->
        process_flags(rest, Map.put(opts, :function_mode, true), mode)

      :function_names_only ->
        # -F implies function mode (just like -f, but names only)
        new_opts = opts |> Map.put(:function_names_only, true) |> Map.put(:function_mode, true)
        process_flags(rest, new_opts, mode)

      :nameref_mode ->
        process_flags(rest, Map.put(opts, :nameref_mode, mode == :set), mode)

      {attr_key, attr_value} ->
        new_opts =
          case mode do
            :set ->
              update_in(opts.set_attrs, &Map.put(&1, attr_key, attr_value))

            :unset ->
              update_in(opts.remove_attrs, &MapSet.put(&1, attr_key))
          end

        process_flags(rest, new_opts, mode)
    end
  end

  # Declare variables with attributes
  defp declare_variables(names, session_state, opts) do
    {var_updates, errors} =
      Enum.reduce(names, {%{}, []}, fn name_expr, {updates, errs} ->
        case parse_name_or_array(name_expr, session_state) do
          {:array, name, array_value} ->
            case apply_array_declaration(name, array_value, session_state, opts, updates) do
              {:ok, updated_var} ->
                {Map.put(updates, name, updated_var), errs}

              {:error, msg} ->
                {updates, errs ++ [msg]}
            end

          {:scalar, name, value} ->
            case apply_declaration(name, value, session_state, opts, updates) do
              {:ok, updated_var} ->
                {Map.put(updates, name, updated_var), errs}

              {:error, msg} ->
                {updates, errs ++ [msg]}
            end

          :error ->
            {updates, errs ++ ["declare: invalid variable name: #{inspect(name_expr)}"]}
        end
      end)

    # Report errors
    Enum.each(errors, fn err -> error(err) end)

    if map_size(var_updates) > 0 do
      update_state(variables: var_updates)
    end

    exit_code = if Enum.empty?(errors), do: 0, else: 1
    {:ok, exit_code}
  end

  # Parse name=value, just name, or ArrayAssignment AST node
  defp parse_name_or_array(%AST.ArrayAssignment{name: name, elements: elements}, session_state) do
    # ArrayAssignment node from parser - expand elements to values
    expanded_elements = expand_array_elements(elements, session_state)
    {:array, name, expanded_elements}
  end

  defp parse_name_or_array(expr, _session_state) when is_binary(expr) do
    case String.split(expr, "=", parts: 2) do
      [name, value] ->
        if valid_var_name?(name) do
          {:scalar, name, value}
        else
          :error
        end

      [name] ->
        if valid_var_name?(name) do
          {:scalar, name, nil}
        else
          :error
        end
    end
  end

  defp parse_name_or_array(_other, _session_state), do: :error

  # Expand array elements (Words or {key, value} tuples for associative arrays)
  defp expand_array_elements(elements, session_state) do
    Enum.map(elements, fn
      {%AST.Word{} = key, %AST.Word{} = value} ->
        # Associative array: [key]=value
        key_str = Helpers.word_to_string(key, session_state)
        value_str = Helpers.word_to_string(value, session_state)
        {key_str, value_str}

      %AST.Word{} = word ->
        # Indexed array element
        Helpers.word_to_string(word, session_state)
    end)
  end

  # Apply array declaration
  defp apply_array_declaration(name, elements, session_state, opts, pending_updates) do
    # Get existing variable (check pending updates first, then session state)
    existing =
      case Map.get(pending_updates, name) do
        nil -> Map.get(session_state.variables, name)
        var -> var
      end

    # Check if readonly
    case existing do
      %Variable{attributes: %{readonly: true}} ->
        {:error, "declare: #{name}: readonly variable"}

      _ ->
        # Determine array type from opts or infer from elements
        array_type = opts.set_attrs[:array_type] || infer_array_type(elements)

        # Build the array value
        array_value = build_array_value(elements, array_type)

        # Build attributes
        base_attrs =
          case existing do
            %Variable{attributes: attrs} -> attrs
            nil -> %{integer: false, export: false, readonly: false, array_type: nil}
          end

        # Apply set attributes
        new_attrs =
          Enum.reduce(opts.set_attrs, base_attrs, fn {key, val}, acc ->
            Map.put(acc, key, val)
          end)

        # Apply remove attributes
        new_attrs =
          Enum.reduce(opts.remove_attrs, new_attrs, fn key, acc ->
            Map.put(acc, key, nil)
          end)

        # Set array_type
        new_attrs = Map.put(new_attrs, :array_type, array_type)

        {:ok, %Variable{value: array_value, attributes: new_attrs}}
    end
  end

  # Infer array type from elements
  defp infer_array_type(elements) do
    if Enum.any?(elements, &is_tuple/1) do
      :associative
    else
      :indexed
    end
  end

  # Build array value from elements
  defp build_array_value(elements, :associative) do
    elements
    |> Enum.map(fn
      {key, value} -> {key, value}
      value -> {to_string(value), value}
    end)
    |> Map.new()
  end

  defp build_array_value(elements, :indexed) do
    elements
    |> Enum.with_index()
    |> Enum.map(fn {value, idx} -> {idx, value} end)
    |> Map.new()
  end

  # Validate variable name
  defp valid_var_name?(name) do
    String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)
  end

  # Apply declaration to a variable
  defp apply_declaration(name, value, session_state, opts, pending_updates) do
    # Get existing variable (check pending updates first, then session state)
    existing =
      case Map.get(pending_updates, name) do
        nil -> Map.get(session_state.variables, name)
        var -> var
      end

    # Check if readonly
    case existing do
      %Variable{attributes: %{readonly: true}} ->
        {:error, "declare: #{name}: readonly variable"}

      _ ->
        # Handle nameref mode: declare -n ref=target creates a nameref
        if opts.nameref_mode and value do
          # Create a nameref variable pointing to the target variable name
          {:ok, Variable.new_nameref(value)}
        else
          # Create or update variable
          var = existing || Variable.new()

          # Apply attribute changes
          var = apply_attributes(var, opts)

          # Set value if provided
          # Note: Array literals like `declare -a arr=(1 2 3)` are handled by the parser,
          # which recognizes the `name=(...)` pattern and creates an ArrayAssignment AST node.
          # The value here is already expanded to a scalar string.
          var =
            if value do
              # If variable has integer attribute, evaluate value as arithmetic
              final_value =
                if var.attributes[:integer] do
                  # Build env from session variables for arithmetic evaluation
                  env_vars = build_env_for_arithmetic(session_state, pending_updates)

                  case Arithmetic.evaluate(value, env_vars) do
                    {:ok, result, _} -> to_string(result)
                    {:error, _} -> value
                  end
                else
                  value
                end

              # Apply case conversion based on attributes
              final_value = apply_case_conversion(final_value, var.attributes)

              Variable.set(var, final_value, nil)
            else
              var
            end

          {:ok, var}
        end
    end
  end

  # Apply case conversion based on lowercase/uppercase attributes
  defp apply_case_conversion(value, %{lowercase: true}), do: String.downcase(value)
  defp apply_case_conversion(value, %{uppercase: true}), do: String.upcase(value)
  defp apply_case_conversion(value, _attrs), do: value

  # Apply attributes to variable
  defp apply_attributes(var, opts) do
    # Apply set_attrs
    var =
      Enum.reduce(opts.set_attrs, var, fn {attr_key, attr_value}, acc ->
        acc = put_in(acc.attributes[attr_key], attr_value)

        # When setting array_type, ensure value is a map
        case {attr_key, attr_value} do
          {:array_type, type} when type in [:indexed, :associative] ->
            if is_binary(acc.value) do
              %{acc | value: %{}}
            else
              acc
            end

          _ ->
            acc
        end
      end)

    # Apply remove_attrs
    Enum.reduce(opts.remove_attrs, var, fn attr_key, acc ->
      case attr_key do
        :array_type ->
          put_in(acc.attributes[:array_type], nil)

        key ->
          put_in(acc.attributes[key], false)
      end
    end)
  end

  # Build environment map for arithmetic evaluation
  # Merges session variables with pending updates, converting to string values
  defp build_env_for_arithmetic(session_state, pending_updates) do
    session_vars =
      Map.new(session_state.variables, fn {k, v} -> {k, Variable.get(v, nil) || ""} end)

    pending_vars =
      Map.new(pending_updates, fn {k, v} -> {k, Variable.get(v, nil) || ""} end)

    Map.merge(session_vars, pending_vars)
  end

  # Print all variables
  defp print_all_variables(session_state) do
    session_state.variables
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {name, var} -> puts(format_declare_output(name, var)) end)

    :ok
  end

  # Print specific variables
  defp print_variables(names, session_state) do
    exit_code =
      Enum.reduce(names, 0, fn name, code ->
        case Map.get(session_state.variables, name) do
          nil ->
            error("declare: #{name}: not found")
            1

          var ->
            puts(format_declare_output(name, var))
            code
        end
      end)

    {:ok, exit_code}
  end

  # Format variable for declare output
  defp format_declare_output(name, %Variable{} = var) do
    flags = build_flag_string(var.attributes)
    value_str = format_value(var)
    "declare #{flags}#{name}#{value_str}"
  end

  # Build flag string from attributes
  defp build_flag_string(attributes) do
    flags =
      []
      |> maybe_add_flag(attributes.array_type == :indexed, "a")
      |> maybe_add_flag(attributes.array_type == :associative, "A")
      |> maybe_add_flag(attributes.integer, "i")
      |> maybe_add_flag(attributes[:nameref] != nil, "n")
      |> maybe_add_flag(attributes.readonly, "r")
      |> maybe_add_flag(attributes.export, "x")

    if Enum.empty?(flags) do
      "-- "
    else
      "-" <> Enum.join(flags, "") <> " "
    end
  end

  defp maybe_add_flag(list, true, flag), do: list ++ [flag]
  defp maybe_add_flag(list, false, _flag), do: list
  defp maybe_add_flag(list, nil, _flag), do: list

  # Format variable value for output
  defp format_value(%Variable{attributes: %{array_type: nil}, value: v}) when is_binary(v) do
    "=\"#{escape_value(v)}\""
  end

  defp format_value(%Variable{attributes: %{array_type: :indexed}, value: map})
       when is_map(map) do
    if map_size(map) == 0 do
      "=()"
    else
      elements =
        map
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {idx, val} -> "[#{idx}]=\"#{escape_value(val)}\"" end)
        |> Enum.join(" ")

      "=(#{elements})"
    end
  end

  defp format_value(%Variable{attributes: %{array_type: :associative}, value: map})
       when is_map(map) do
    if map_size(map) == 0 do
      "=()"
    else
      elements =
        map
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.map(fn {key, val} -> "[#{key}]=\"#{escape_value(val)}\"" end)
        |> Enum.join(" ")

      "=(#{elements})"
    end
  end

  defp format_value(_), do: ""

  # Escape special characters in values
  defp escape_value(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end

  # Handle function-related operations
  # -f: Display function definitions
  # -F: Display only function names (with attributes)
  defp handle_functions(names, session_state, opts) do
    functions = session_state.functions || %{}

    if Enum.empty?(names) do
      # No names specified - list all functions
      functions
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {name, func} ->
        puts(format_function_output(name, func, opts.function_names_only))
      end)

      :ok
    else
      # Specific function names requested
      exit_code =
        Enum.reduce(names, 0, fn name, code ->
          case Map.get(functions, name) do
            nil ->
              error("declare: #{name}: not found")
              1

            func ->
              puts(format_function_output(name, func, opts.function_names_only))
              code
          end
        end)

      {:ok, exit_code}
    end
  end

  # Format function output based on -f or -F flag
  # -F (function_names_only: true): "declare -f funcname" or "declare -fx funcname"
  # -f (function_names_only: false): Full function definition
  defp format_function_output(name, func, true = _names_only) do
    # -F mode: just show declare line with attributes
    flags = build_function_flag_string(func)
    "declare #{flags}#{name}"
  end

  defp format_function_output(_name, func, false = _names_only) do
    # -f mode: show full function definition
    to_string(func)
  end

  # Build flag string for function declaration
  # Always includes -f, may include -x if exported
  defp build_function_flag_string(func) do
    if func.exported do
      "-fx "
    else
      "-f "
    end
  end
end
