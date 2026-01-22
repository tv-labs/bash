defmodule Bash.Builtin.Unset do
  @moduledoc """
  `unset [-fvn] [name ...]`

  Remove variables or functions.

  Each NAME refers to a variable; if there is no variable by that name,
  a function with that name, if any, is unset.

  Options:
  - `-f` - treat each NAME as a shell function
  - `-v` - treat each NAME as a shell variable
  - `-n` - treat each NAME as a name reference and unset the variable itself
           rather than the variable it references

  Without options, unset first tries to unset a variable, and if that fails,
  tries to unset a function.

  Exit Status:
  Returns success unless an invalid option is given or a NAME is read-only.

  Reference: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
  """
  use Bash.Builtin

  alias Bash.Variable

  @type mode :: :variable | :function | :nameref

  defbash execute(args, state) do
    {mode, names} = parse_args(args)
    unset_names(names, mode, state)
  end

  # Parse command arguments into mode and names
  @spec parse_args([String.t()]) :: {mode(), [String.t()]}
  defp parse_args(args) do
    parse_options(args, :auto, [])
  end

  # Parse options and collect names
  defp parse_options([], mode, names), do: {mode, Enum.reverse(names)}

  defp parse_options(["--" | rest], mode, names) do
    # -- ends option parsing, rest are all names
    {mode, Enum.reverse(names) ++ rest}
  end

  defp parse_options(["-" <> flags | rest], mode, names) when flags != "" do
    # Parse combined flags like -fv
    new_mode = parse_flags(String.graphemes(flags), mode)
    parse_options(rest, new_mode, names)
  end

  defp parse_options([name | rest], mode, names) do
    parse_options(rest, mode, [name | names])
  end

  # Parse individual flag characters
  defp parse_flags([], mode), do: mode
  defp parse_flags(["f" | rest], _mode), do: parse_flags(rest, :function)
  defp parse_flags(["v" | rest], _mode), do: parse_flags(rest, :variable)
  defp parse_flags(["n" | rest], _mode), do: parse_flags(rest, :nameref)
  # Unknown flags are ignored (bash behavior)
  defp parse_flags([_ | rest], mode), do: parse_flags(rest, mode)

  # Unset the given names according to mode
  defp unset_names(names, mode, session_state) do
    {var_deletes, func_deletes, array_updates, errors} =
      Enum.reduce(names, {[], [], %{}, []}, fn name, {vars, funcs, arr_updates, errs} ->
        case unset_name(name, mode, session_state) do
          {:ok, :variable} ->
            {[name | vars], funcs, arr_updates, errs}

          {:ok, :function} ->
            {vars, [name | funcs], arr_updates, errs}

          {:ok, :array_element, var_name, updated_var} ->
            # Track array element update
            {vars, funcs, Map.put(arr_updates, var_name, updated_var), errs}

          {:ok, :none} ->
            # Name didn't exist - this is not an error in bash
            {vars, funcs, arr_updates, errs}

          {:error, message} ->
            {vars, funcs, arr_updates, [message | errs]}
        end
      end)

    # Report errors
    Enum.each(Enum.reverse(errors), fn err -> error(err) end)

    # Build and apply updates
    updates = build_updates(var_deletes, func_deletes, array_updates, session_state)

    if map_size(updates) > 0 do
      Enum.each(updates, fn {key, value} -> update_state([{key, value}]) end)
    end

    exit_code = if Enum.empty?(errors), do: 0, else: 1
    {:ok, exit_code}
  end

  # Try to unset a single name
  defp unset_name(name, :variable, session_state) do
    unset_variable(name, session_state)
  end

  defp unset_name(name, :function, session_state) do
    unset_function(name, session_state)
  end

  defp unset_name(name, :nameref, session_state) do
    # For nameref, we unset the nameref variable itself, not what it references
    # Since we don't fully support namerefs yet, just treat as variable
    unset_variable(name, session_state)
  end

  defp unset_name(name, :auto, session_state) do
    # Try variable first, then function
    case unset_variable(name, session_state) do
      {:ok, :variable} -> {:ok, :variable}
      {:ok, :array_element, _, _} = result -> result
      {:ok, :none} -> unset_function(name, session_state)
      {:error, _} = error -> error
    end
  end

  # Unset a variable (or array element if name contains subscript)
  defp unset_variable(name, session_state) do
    case parse_array_subscript(name) do
      {:array_element, var_name, subscript} ->
        unset_array_element(var_name, subscript, session_state)

      :not_array ->
        case Map.get(session_state.variables, name) do
          nil ->
            {:ok, :none}

          %Variable{attributes: %{readonly: true}} ->
            {:error, "unset: #{name}: cannot unset: readonly variable"}

          %Variable{} ->
            {:ok, :variable}
        end
    end
  end

  # Parse name to detect array element reference: hash[key] -> {:array_element, "hash", "key"}
  defp parse_array_subscript(name) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\[([^\]]*)\]$/, name) do
      [_, var_name, subscript] ->
        # Strip quotes from subscript (same as parser does)
        clean_subscript = strip_subscript_quotes(subscript)
        {:array_element, var_name, clean_subscript}

      nil ->
        :not_array
    end
  end

  # Strip surrounding quotes from subscript
  defp strip_subscript_quotes(str) do
    cond do
      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        String.slice(str, 1..-2//1)

      String.starts_with?(str, "'") and String.ends_with?(str, "'") ->
        String.slice(str, 1..-2//1)

      true ->
        str
    end
  end

  # Unset a single array element
  defp unset_array_element(var_name, subscript, session_state) do
    case Map.get(session_state.variables, var_name) do
      nil ->
        {:ok, :none}

      %Variable{attributes: %{readonly: true}} ->
        {:error, "unset: #{var_name}[#{subscript}]: cannot unset: readonly variable"}

      %Variable{attributes: %{array_type: :associative}, value: map} = var when is_map(map) ->
        # For associative arrays, use string key
        if Map.has_key?(map, subscript) do
          {:ok, :array_element, var_name, %{var | value: Map.delete(map, subscript)}}
        else
          {:ok, :none}
        end

      %Variable{attributes: %{array_type: :indexed}, value: map} = var when is_map(map) ->
        # For indexed arrays, convert subscript to integer
        case Integer.parse(subscript) do
          {idx, _} ->
            if Map.has_key?(map, idx) do
              {:ok, :array_element, var_name, %{var | value: Map.delete(map, idx)}}
            else
              {:ok, :none}
            end

          :error ->
            {:ok, :none}
        end

      %Variable{} ->
        # Scalar variable - unset treats arr[0] as full unset
        if subscript == "0" do
          {:ok, :variable}
        else
          {:ok, :none}
        end
    end
  end

  # Unset a function
  defp unset_function(name, session_state) do
    if Map.has_key?(session_state.functions, name) do
      {:ok, :function}
    else
      {:ok, :none}
    end
  end

  # Build state updates for deleted variables, functions, and array element updates
  defp build_updates(var_deletes, func_deletes, array_updates, session_state) do
    updates = %{}

    # Start with array element updates (modified variables)
    base_variables =
      if map_size(array_updates) > 0 do
        Map.merge(session_state.variables, array_updates)
      else
        session_state.variables
      end

    # For variables, we need to track which ones to delete
    updates =
      if Enum.empty?(var_deletes) and map_size(array_updates) == 0 do
        updates
      else
        new_variables =
          Enum.reduce(var_deletes, base_variables, fn name, vars ->
            Map.delete(vars, name)
          end)

        Map.put(updates, :var_updates, new_variables)
      end

    # For functions, we track which ones to delete
    updates =
      if Enum.empty?(func_deletes) do
        updates
      else
        new_functions =
          Enum.reduce(func_deletes, session_state.functions, fn name, funcs ->
            Map.delete(funcs, name)
          end)

        Map.put(updates, :function_updates, new_functions)
      end

    updates
  end
end
