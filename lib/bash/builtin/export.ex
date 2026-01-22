defmodule Bash.Builtin.Export do
  @moduledoc """
  `export [-fn] [name[=value] ...] or export -p [-f]`
  Set export attribute for shell variables.

  Marks each NAME for automatic export to the environment of subsequently executed commands. If VALUE is supplied, assign VALUE before exporting.

  Options:
  - `-f` - refer to shell functions
  - `-n` - remove the export property from each NAME
  - `-p` - display a list of all exported variables or functions

  An argument of `--` disables further option processing.

  Exit Status:
  Returns success unless an invalid option is given or NAME is invalid.
  """
  use Bash.Builtin

  alias Bash.Variable
  alias Bash.Function

  defbash execute(args, state) do
    case parse_args(args) do
      {:list, :variables} ->
        list_exported_variables(state)

      {:list, :functions} ->
        list_exported_functions(state)

      {:export, :variables, names} ->
        export_variables(names, state)

      {:export, :functions, names} ->
        export_functions(names, state)

      {:unexport, :variables, names} ->
        unexport_variables(names, state)

      {:unexport, :functions, names} ->
        unexport_functions(names, state)

      {:error, message} ->
        error("export: #{message}")
        {:ok, 1}
    end
  end

  # Parse command arguments
  # Returns: {:list, type} | {:export, type, names} | {:unexport, type, names} | {:error, msg}
  defp parse_args(args) do
    {opts, names} = parse_options(args)

    cond do
      # Invalid option combination
      opts[:error] ->
        {:error, opts[:error]}

      # List mode: -p or -pf
      opts[:list] && Enum.empty?(names) ->
        type = if opts[:functions], do: :functions, else: :variables
        {:list, type}

      # Un-export mode: -n
      opts[:unexport] ->
        type = if opts[:functions], do: :functions, else: :variables
        {:unexport, type, names}

      # Export mode (default)
      true ->
        type = if opts[:functions], do: :functions, else: :variables
        {:export, type, names}
    end
  end

  # Parse option flags from arguments
  # Returns {opts_map, remaining_args}
  defp parse_options(args) do
    parse_options(args, %{list: false, functions: false, unexport: false}, [])
  end

  defp parse_options([], opts, acc) do
    {opts, Enum.reverse(acc)}
  end

  # Stop processing options after --
  defp parse_options(["--" | rest], opts, acc) do
    {opts, Enum.reverse(acc) ++ rest}
  end

  # Handle combined flags like -pf, -fn, -nf
  defp parse_options(["-" <> flags | rest], opts, acc) when flags != "" do
    case parse_flags(flags, opts) do
      {:ok, new_opts} -> parse_options(rest, new_opts, acc)
      {:error, _} = err -> {%{error: elem(err, 1)}, []}
    end
  end

  # Non-option argument
  defp parse_options([arg | rest], opts, acc) do
    parse_options(rest, opts, [arg | acc])
  end

  # Parse individual flag characters
  defp parse_flags("", opts), do: {:ok, opts}

  defp parse_flags("p" <> rest, opts) do
    parse_flags(rest, Map.put(opts, :list, true))
  end

  defp parse_flags("f" <> rest, opts) do
    parse_flags(rest, Map.put(opts, :functions, true))
  end

  defp parse_flags("n" <> rest, opts) do
    parse_flags(rest, Map.put(opts, :unexport, true))
  end

  defp parse_flags(<<char::utf8, _rest::binary>>, _opts) do
    {:error, "-#{<<char::utf8>>}: invalid option"}
  end

  # List all exported variables
  defp list_exported_variables(session_state) do
    exported =
      session_state.variables
      |> Enum.filter(fn {_name, var} ->
        var.attributes[:export] == true
      end)
      |> Enum.sort_by(fn {name, _var} -> name end)

    # If no variables have export attribute set, list all variables
    # (mimicking bash behavior where all variables are implicitly exported to children)
    vars_to_list =
      if Enum.empty?(exported) do
        session_state.variables
        |> Enum.sort_by(fn {name, _var} -> name end)
      else
        exported
      end

    Enum.each(vars_to_list, fn {name, var} ->
      value = Variable.get(var, nil)
      puts("declare -x #{name}=\"#{escape_value(value)}\"")
    end)

    :ok
  end

  # List all exported functions
  defp list_exported_functions(session_state) do
    session_state.functions
    |> Enum.filter(fn {_name, func} ->
      func.exported == true
    end)
    |> Enum.sort_by(fn {name, _func} -> name end)
    |> Enum.each(fn {name, func} ->
      body_str = format_function_body(func.body)
      puts("declare -fx #{name}")
      puts("#{name} () ")
      puts("{ ")
      puts(body_str)
      puts("}")
    end)

    :ok
  end

  # Export variables (with or without assignment)
  defp export_variables(names, session_state) do
    # Build var_updates with export attribute set
    var_updates =
      names
      |> Enum.reduce(%{}, fn name, updates ->
        {var_name, value} = parse_assignment(name)
        # Create or update variable with export attribute
        existing = Map.get(session_state.variables, var_name)

        var =
          case existing do
            nil ->
              %Variable{
                value: value,
                attributes: %{readonly: false, export: true, integer: false, array_type: nil}
              }

            %Variable{} = v ->
              new_attrs = Map.put(v.attributes, :export, true)
              new_value = if value != "", do: value, else: v.value
              %{v | value: new_value, attributes: new_attrs}
          end

        Map.put(updates, var_name, var)
      end)

    if map_size(var_updates) > 0 do
      update_state(var_updates: var_updates)
    end

    :ok
  end

  # Export functions (mark them as exported for subshells)
  defp export_functions(names, session_state) do
    {function_updates, errors} =
      names
      |> Enum.reduce({%{}, []}, fn name, {updates, errs} ->
        case Map.get(session_state.functions, name) do
          nil ->
            {updates, ["#{name}: not a function" | errs]}

          %Function{} = func ->
            exported_func = %{func | exported: true}
            {Map.put(updates, name, exported_func), errs}
        end
      end)

    # Report errors
    Enum.each(Enum.reverse(errors), fn err -> error("export: #{err}") end)

    if map_size(function_updates) > 0 do
      update_state(function_updates: function_updates)
    end

    exit_code = if Enum.empty?(errors), do: 0, else: 1
    {:ok, exit_code}
  end

  # Un-export variables (remove export attribute)
  defp unexport_variables(names, session_state) do
    var_updates =
      names
      |> Enum.reduce(%{}, fn name, updates ->
        case Map.get(session_state.variables, name) do
          nil ->
            # Variable doesn't exist - create it without export
            var = %Variable{
              value: "",
              attributes: %{readonly: false, export: false, integer: false, array_type: nil}
            }

            Map.put(updates, name, var)

          %Variable{} = v ->
            # Remove export attribute
            new_attrs = Map.put(v.attributes, :export, false)
            Map.put(updates, name, %{v | attributes: new_attrs})
        end
      end)

    if map_size(var_updates) > 0 do
      update_state(var_updates: var_updates)
    end

    :ok
  end

  # Un-export functions (remove exported flag)
  defp unexport_functions(names, session_state) do
    {function_updates, errors} =
      names
      |> Enum.reduce({%{}, []}, fn name, {updates, errs} ->
        case Map.get(session_state.functions, name) do
          nil ->
            {updates, ["#{name}: not a function" | errs]}

          %Function{} = func ->
            unexported_func = %{func | exported: false}
            {Map.put(updates, name, unexported_func), errs}
        end
      end)

    # Report errors
    Enum.each(Enum.reverse(errors), fn err -> error("export: #{err}") end)

    if map_size(function_updates) > 0 do
      update_state(function_updates: function_updates)
    end

    exit_code = if Enum.empty?(errors), do: 0, else: 1
    {:ok, exit_code}
  end

  # Parse a single assignment (NAME=VALUE or just NAME)
  defp parse_assignment(arg) do
    case String.split(arg, "=", parts: 2) do
      [name, value] -> {name, value}
      [name] -> {name, ""}
    end
  end

  # Escape special characters in values for display
  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end

  defp escape_value(value), do: to_string(value)

  # Format function body for display
  defp format_function_body(body) when is_list(body) do
    body
    |> Enum.map(fn stmt -> "    " <> to_string(stmt) end)
    |> Enum.join("\n")
  end

  defp format_function_body(body) do
    "    " <> to_string(body)
  end
end
