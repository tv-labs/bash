defmodule Bash.Builtin.Type do
  @moduledoc """
  `type [-afptP] name [name ...]`

  For each NAME, indicate how it would be interpreted if used as a command name.

  If the -t option is used, `type` outputs a single word which is one of `alias`, `keyword`, `function`, `builtin`, `file`, if NAME is an alias, shell reserved word, shell function, shell builtin, disk file, or unfound, respectively.

  If the -p flag is used, `type` either returns the name of the disk file that would be executed, or nothing if `type -t NAME` would not return `file`.

  If the -a flag is used, `type` displays all of the places that contain an executable named `file`.  This includes aliases, builtins, and functions, if and only if the -p flag is not also used.

  The -f flag suppresses shell function lookup.

  The -P flag forces a PATH search for each NAME, even if it is an alias, builtin, or function, and returns the name of the disk file that would be executed.

  typeset [-afFirtx] [-p] name[=value] ...

  Obsolete. See `declare`.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/type.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Builtin, as: BuiltinRegistry
  alias Bash.Variable

  defbash execute(args, state) do
    if args == [] do
      error("type: usage: type [-afptP] name [name ...]")
      {:ok, 1}
    else
      {opts, names} = parse_args(args)

      if Enum.empty?(names) do
        error("type: usage: type [-afptP] name [name ...]")
        {:ok, 1}
      else
        {exit_code, output_acc, error_acc} =
          Enum.reduce(names, {0, [], []}, fn name, {code, out_acc, err_acc} ->
            case lookup_name(name, state, opts) do
              {:ok, results} ->
                lines = format_results_as_strings(name, results, opts)
                {code, [Enum.join(lines, "") | out_acc], err_acc}

              :not_found ->
                new_err =
                  if not opts.type_only do
                    ["type: #{name}: not found" | err_acc]
                  else
                    err_acc
                  end

                {1, out_acc, new_err}
            end
          end)

        # Write accumulated output in correct order
        stdout_text = output_acc |> Enum.reverse() |> Enum.join("")
        stderr_text = error_acc |> Enum.reverse() |> Enum.join("\n")

        if stdout_text != "", do: write(stdout_text)
        if stderr_text != "", do: error(stderr_text)

        {:ok, exit_code}
      end
    end
  end

  defp parse_args(args) do
    {opts, names, _} =
      Enum.reduce(args, {%{}, [], false}, fn
        arg, {opts, names, finished_flags} ->
          cond do
            finished_flags ->
              {opts, names ++ [arg], finished_flags}

            arg == "--" ->
              {opts, names, true}

            String.starts_with?(arg, "-") and arg != "-" ->
              flag_opts = parse_flags(String.slice(arg, 1..-1//1))
              {Map.merge(opts, flag_opts), names, finished_flags}

            true ->
              {opts, names ++ [arg], finished_flags}
          end
      end)

    {normalize_opts(opts), names}
  end

  defp parse_flags(flags) do
    flags
    |> String.graphemes()
    |> Enum.reduce(%{}, fn
      "a", opts -> Map.put(opts, :all, true)
      "f", opts -> Map.put(opts, :no_functions, true)
      "p", opts -> Map.put(opts, :path_only, true)
      "t", opts -> Map.put(opts, :type_only, true)
      "P", opts -> Map.put(opts, :force_path, true)
      _, opts -> opts
    end)
  end

  defp normalize_opts(opts) do
    %{
      all: Map.get(opts, :all, false),
      no_functions: Map.get(opts, :no_functions, false),
      path_only: Map.get(opts, :path_only, false),
      type_only: Map.get(opts, :type_only, false),
      force_path: Map.get(opts, :force_path, false)
    }
  end

  defp lookup_name(name, state, opts) do
    if opts.force_path do
      case find_in_path(name, state) do
        nil -> :not_found
        path -> {:ok, [{:file, path}]}
      end
    else
      results = []
      # Check alias (unless path_only)
      results =
        if not opts.path_only and Map.has_key?(state.aliases, name) do
          [{:alias, state.aliases[name]} | results]
        else
          results
        end

      # Check reserved words
      results =
        if BuiltinRegistry.reserved_word?(name) do
          [{:keyword, name} | results]
        else
          results
        end

      # Check functions (unless no_functions or path_only)
      results =
        if not opts.no_functions and not opts.path_only and
             Map.has_key?(state.functions, name) do
          [{:function, state.functions[name]} | results]
        else
          results
        end

      # Check builtins (unless path_only)
      results =
        if not opts.path_only and BuiltinRegistry.builtin?(name) do
          [{:builtin, name} | results]
        else
          results
        end

      # Check PATH
      results =
        case find_in_path(name, state) do
          nil -> results
          path -> [{:file, path} | results]
        end

      case Enum.reverse(results) do
        [] ->
          :not_found

        reversed when opts.all ->
          {:ok, reversed}

        [first | _] ->
          {:ok, [first]}
      end
    end
  end

  defp find_in_path(name, state) do
    if String.contains?(name, "/") do
      if File.exists?(name) and not File.dir?(name), do: name, else: nil
    else
      path_var = Map.get(state.variables, "PATH", Variable.new("/usr/bin:/bin"))
      path_dirs = path_var |> Variable.get(nil) |> String.split(":")

      Enum.find_value(path_dirs, fn dir ->
        full_path = Path.join(dir, name)

        if File.exists?(full_path) and not File.dir?(full_path) do
          full_path
        end
      end)
    end
  end

  defp format_results_as_strings(name, results, opts) do
    Enum.map(results, fn result ->
      format_single_result(name, result, opts) <> "\n"
    end)
  end

  defp format_single_result(_name, {type, _}, %{type_only: true}) do
    Atom.to_string(type)
  end

  defp format_single_result(name, {:alias, value}, _), do: "#{name} is aliased to `#{value}'"
  defp format_single_result(name, {:keyword, _}, _), do: "#{name} is a shell keyword"
  defp format_single_result(name, {:function, _}, _), do: "#{name} is a function"
  defp format_single_result(name, {:builtin, _}, _), do: "#{name} is a shell builtin"
  defp format_single_result(_name, {:file, path}, %{path_only: true}), do: path
  defp format_single_result(name, {:file, path}, _), do: "#{name} is #{path}"
end
