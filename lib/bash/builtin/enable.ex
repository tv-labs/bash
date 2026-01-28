defmodule Bash.Builtin.Enable do
  @moduledoc """
  `enable [-a] [-dnps] [-f filename] [name ...]`

  Enable and disable builtin shell commands. This allows you to use a disk
  command which has the same name as a shell builtin without specifying a
  full pathname.

  Options:
    -a    Print every builtin with an indication of whether it is enabled
    -n    Disable the named builtins
    -p    Print a list of builtins (default if no names given)
    -s    Restrict output to POSIX special builtins

  The -f and -d options for dynamic loading are not supported in this
  implementation.

  Exit Status:
  Returns success unless NAME is not a shell builtin or an error occurs.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/enable.def?h=bash-5.3
  """
  use Bash.Builtin

  alias Bash.Builtin, as: BuiltinModule

  @special_builtins ~w[: . break continue eval exec exit export readonly return set shift trap unset]

  defbash execute(args, state) do
    {opts, names} = parse_args(args)

    cond do
      opts.help ->
        print_help()

      opts.load_file != nil or opts.delete ->
        unsupported_dynamic_loading()

      opts.disable and names != [] ->
        disable_builtins(names, state)

      names != [] ->
        enable_builtins(names, state)

      opts.all ->
        list_all_builtins(state, opts.special_only)

      true ->
        list_enabled_builtins(state, opts.special_only)
    end
  end

  defp parse_args(args) do
    parse_args(
      args,
      %{
        all: false,
        disable: false,
        print: false,
        special_only: false,
        load_file: nil,
        delete: false,
        help: false
      },
      []
    )
  end

  defp parse_args([], opts, names), do: {opts, Enum.reverse(names)}

  defp parse_args(["-a" | rest], opts, names), do: parse_args(rest, %{opts | all: true}, names)

  defp parse_args(["-n" | rest], opts, names),
    do: parse_args(rest, %{opts | disable: true}, names)

  defp parse_args(["-p" | rest], opts, names), do: parse_args(rest, %{opts | print: true}, names)

  defp parse_args(["-s" | rest], opts, names),
    do: parse_args(rest, %{opts | special_only: true}, names)

  defp parse_args(["-d" | rest], opts, names), do: parse_args(rest, %{opts | delete: true}, names)

  defp parse_args(["-f", file | rest], opts, names),
    do: parse_args(rest, %{opts | load_file: file}, names)

  defp parse_args(["--help" | rest], opts, names),
    do: parse_args(rest, %{opts | help: true}, names)

  defp parse_args(["-" <> flags | rest], opts, names) when byte_size(flags) > 1 do
    # Handle combined flags like -an
    new_opts =
      String.graphemes(flags)
      |> Enum.reduce(opts, fn
        "a", acc -> %{acc | all: true}
        "n", acc -> %{acc | disable: true}
        "p", acc -> %{acc | print: true}
        "s", acc -> %{acc | special_only: true}
        "d", acc -> %{acc | delete: true}
        _, acc -> acc
      end)

    parse_args(rest, new_opts, names)
  end

  defp parse_args(["--" | rest], opts, names), do: {opts, Enum.reverse(names) ++ rest}
  defp parse_args([name | rest], opts, names), do: parse_args(rest, opts, [name | names])

  defp disable_builtins(names, session_state) do
    disabled = Map.get(session_state, :disabled_builtins, MapSet.new())
    all_builtins = BuiltinModule.implemented_builtins()

    {valid, invalid} = Enum.split_with(names, &(&1 in all_builtins))

    case invalid do
      [] ->
        new_disabled = Enum.reduce(valid, disabled, &MapSet.put(&2, &1))
        Bash.Builtin.Context.update_state(disabled_builtins: new_disabled)
        :ok

      [first | _] ->
        Bash.Builtin.Context.error("enable: #{first}: not a shell builtin")
        {:ok, 1}
    end
  end

  defp enable_builtins(names, session_state) do
    disabled = Map.get(session_state, :disabled_builtins, MapSet.new())
    all_builtins = BuiltinModule.implemented_builtins()

    {valid, invalid} = Enum.split_with(names, &(&1 in all_builtins))

    case invalid do
      [] ->
        new_disabled = Enum.reduce(valid, disabled, &MapSet.delete(&2, &1))
        Bash.Builtin.Context.update_state(disabled_builtins: new_disabled)
        :ok

      [first | _] ->
        Bash.Builtin.Context.error("enable: #{first}: not a shell builtin")
        {:ok, 1}
    end
  end

  defp list_all_builtins(session_state, special_only) do
    disabled = Map.get(session_state, :disabled_builtins, MapSet.new())

    builtins =
      if special_only do
        @special_builtins
      else
        BuiltinModule.implemented_builtins() |> Enum.sort()
      end

    output =
      builtins
      |> Enum.map(fn name ->
        status = if MapSet.member?(disabled, name), do: "disable", else: "enable"
        "#{status} #{name}\n"
      end)
      |> Enum.join()

    if output != "", do: Bash.Builtin.Context.write(output)
    :ok
  end

  defp list_enabled_builtins(session_state, special_only) do
    disabled = Map.get(session_state, :disabled_builtins, MapSet.new())

    builtins =
      if special_only do
        @special_builtins
      else
        BuiltinModule.implemented_builtins() |> Enum.sort()
      end

    output =
      builtins
      |> Enum.reject(&MapSet.member?(disabled, &1))
      |> Enum.map(&"enable #{&1}\n")
      |> Enum.join()

    if output != "", do: Bash.Builtin.Context.write(output)
    :ok
  end

  defp print_help do
    help = """
    enable: enable [-a] [-dnps] [-f filename] [name ...]
        Enable and disable shell builtins.

        Allows you to use a disk command which has the same name as a shell
        builtin without specifying a full pathname.

        Options:
          -a        print a list of builtins showing whether each is enabled
          -n        disable each NAME or display a list of disabled builtins
          -p        print the list of builtins in a reusable format
          -s        print only the names of Posix 'special' builtins

        Options to enable/disable loadable builtins:
          -f        (not supported) Load builtin NAME from shared object FILENAME
          -d        (not supported) Remove a builtin loaded with -f

        Without options, each NAME is enabled.

        Exit Status:
        Returns success unless NAME is not a shell builtin or an error occurs.
    """

    Bash.Builtin.Context.write(help)
    :ok
  end

  defp unsupported_dynamic_loading do
    Bash.Builtin.Context.error("enable: dynamic loading of builtins is not supported")
    {:ok, 1}
  end
end
