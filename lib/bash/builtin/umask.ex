defmodule Bash.Builtin.Umask do
  import Bitwise

  @moduledoc """
  `umask [-p] [-S] [mode]`

  Display or set the file mode creation mask.

  Options:
  - No args: display the current file mode creation mask in octal
  - `-S`: display in symbolic form (u=rwx,g=rx,o=rx)
  - `-p`: display in a form that can be reused as input
  - `mode`: set the file mode mask to the specified mode (octal or symbolic)

  The default umask is 0022 (files get 644, directories get 755).

  ## Octal Mode

  The mask is specified as an octal number (e.g., 022, 077, 0000).
  The mask determines which permission bits are turned OFF when creating files.

  ## Symbolic Mode

  Symbolic mode is specified as [ugoa][+-=][rwxXst]:
  - u: user/owner
  - g: group
  - o: other
  - a: all (ugo)

  Example: u=rwx,g=rx,o=rx sets umask to allow rwx for user, rx for group/other.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/umask.def?h=bash-5.3
  """
  use Bash.Builtin

  # Default umask (022 = files get 644, dirs get 755)
  @default_umask 0o022

  defbash execute(args, state) do
    {flags, rest} = parse_flags(args)

    umask = get_umask(state)

    cond do
      # No mode argument - display current umask
      rest == [] ->
        display_umask(umask, flags)

      # Set mode
      true ->
        case parse_mode(hd(rest), umask) do
          {:ok, new_umask} ->
            set_umask(new_umask, flags)

          {:error, msg} ->
            Bash.Builtin.Context.error(msg)
            {:ok, 1}
        end
    end
  end

  # Get the current umask from session state, or use default
  defp get_umask(session_state) do
    Map.get(session_state, :umask, @default_umask)
  end

  # Parse command flags
  defp parse_flags(args) do
    Enum.reduce(args, {%{symbolic: false, print: false}, []}, fn arg, {flags, rest} ->
      case arg do
        "-S" -> {Map.put(flags, :symbolic, true), rest}
        "-p" -> {Map.put(flags, :print, true), rest}
        "-pS" -> {%{flags | symbolic: true, print: true}, rest}
        "-Sp" -> {%{flags | symbolic: true, print: true}, rest}
        _ -> {flags, rest ++ [arg]}
      end
    end)
  end

  # Display the current umask
  defp display_umask(umask, flags) do
    stdout =
      cond do
        flags.symbolic and flags.print ->
          "umask -S #{format_symbolic(umask)}\n"

        flags.symbolic ->
          "#{format_symbolic(umask)}\n"

        flags.print ->
          "umask #{format_octal(umask)}\n"

        true ->
          "#{format_octal(umask)}\n"
      end

    Bash.Builtin.Context.write(stdout)
    :ok
  end

  # Set the umask and optionally display it
  defp set_umask(new_umask, flags) do
    stdout =
      cond do
        flags.symbolic and flags.print ->
          "umask -S #{format_symbolic(new_umask)}\n"

        flags.symbolic ->
          "#{format_symbolic(new_umask)}\n"

        flags.print ->
          "umask #{format_octal(new_umask)}\n"

        true ->
          ""
      end

    if stdout != "", do: Bash.Builtin.Context.write(stdout)
    Bash.Builtin.Context.update_state(umask: new_umask)
    :ok
  end

  # Format umask as octal string (4 digits)
  defp format_octal(umask) do
    umask
    |> Integer.to_string(8)
    |> String.pad_leading(4, "0")
  end

  # Format umask as symbolic string
  # The mask specifies which bits are REMOVED, so we show what IS allowed
  defp format_symbolic(umask) do
    # Convert umask to permissions that ARE allowed (complement)
    # Full permissions is 0777, so allowed = 0777 & ~umask
    allowed = 0o777 - umask

    u = permission_string(allowed >>> 6 &&& 7)
    g = permission_string(allowed >>> 3 &&& 7)
    o = permission_string(allowed &&& 7)

    "u=#{u},g=#{g},o=#{o}"
  end

  # Convert a 3-bit permission value to rwx string
  defp permission_string(bits) do
    r = if (bits &&& 4) != 0, do: "r", else: ""
    w = if (bits &&& 2) != 0, do: "w", else: ""
    x = if (bits &&& 1) != 0, do: "x", else: ""
    r <> w <> x
  end

  # Parse mode - either octal or symbolic
  defp parse_mode(mode, current_umask) do
    cond do
      # Octal mode (e.g., "022", "0022", "77")
      String.match?(mode, ~r/^[0-7]+$/) ->
        parse_octal_mode(mode)

      # Symbolic mode (e.g., "u=rwx,g=rx,o=rx")
      String.match?(mode, ~r/^[ugoa=+-rwxXst,]+$/) ->
        parse_symbolic_mode(mode, current_umask)

      true ->
        {:error, "umask: #{mode}: invalid mode"}
    end
  end

  # Parse octal mode
  defp parse_octal_mode(mode) do
    case Integer.parse(mode, 8) do
      {value, ""} when value >= 0 and value <= 0o777 ->
        {:ok, value}

      _ ->
        {:error, "umask: #{mode}: octal number out of range"}
    end
  end

  # Parse symbolic mode
  # Format: [ugoa][+-=][rwxXst] (comma-separated for multiple)
  defp parse_symbolic_mode(mode, current_umask) do
    # In symbolic mode for umask, we're setting what permissions ARE allowed
    # So the umask itself is 0777 minus the symbolic permissions
    specs = String.split(mode, ",")

    # Start with current allowed permissions (inverse of umask)
    current_allowed = 0o777 - current_umask

    result =
      Enum.reduce_while(specs, {:ok, current_allowed}, fn spec, {:ok, allowed} ->
        case parse_single_symbolic(spec, allowed) do
          {:ok, new_allowed} -> {:cont, {:ok, new_allowed}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, final_allowed} ->
        # Convert back to umask (what's removed)
        {:ok, 0o777 - final_allowed}

      error ->
        error
    end
  end

  # Parse a single symbolic specification (e.g., "u=rwx" or "go-w")
  defp parse_single_symbolic(spec, allowed) do
    # Match: [ugoa]*[+-=][rwxXst]*
    case Regex.run(~r/^([ugoa]*)([+=-])([rwxXst]*)$/, spec) do
      [_, who, op, perms] ->
        who = if who == "", do: "a", else: who
        apply_symbolic_op(who, op, perms, allowed)

      _ ->
        {:error, "umask: #{spec}: invalid symbolic mode"}
    end
  end

  # Apply symbolic operation to permissions
  defp apply_symbolic_op(who, op, perms, allowed) do
    # Calculate the permission bits
    perm_bits = calculate_perm_bits(perms)

    # Calculate which positions to affect
    masks = calculate_who_masks(who)

    # Apply operation
    new_allowed =
      Enum.reduce(masks, allowed, fn {shift, _mask}, acc ->
        shifted_bits = perm_bits <<< shift

        case op do
          "+" -> acc ||| shifted_bits
          "-" -> acc &&& bnot(shifted_bits)
          "=" -> (acc &&& bnot(7 <<< shift)) ||| shifted_bits
        end
      end)

    {:ok, new_allowed &&& 0o777}
  end

  # Calculate permission bits from rwx string
  defp calculate_perm_bits(perms) do
    chars = String.graphemes(perms)

    Enum.reduce(chars, 0, fn char, acc ->
      case char do
        "r" -> acc ||| 4
        "w" -> acc ||| 2
        "x" -> acc ||| 1
        # Treat X as x for umask
        "X" -> acc ||| 1
        # setuid/setgid not applicable to umask
        "s" -> acc
        # sticky bit not applicable to umask
        "t" -> acc
        _ -> acc
      end
    end)
  end

  # Calculate which bit positions to affect based on who (ugoa)
  defp calculate_who_masks(who) do
    chars = String.graphemes(who)

    if "a" in chars do
      [{6, 0o700}, {3, 0o070}, {0, 0o007}]
    else
      masks = []
      masks = if "u" in chars, do: [{6, 0o700} | masks], else: masks
      masks = if "g" in chars, do: [{3, 0o070} | masks], else: masks
      masks = if "o" in chars, do: [{0, 0o007} | masks], else: masks
      masks
    end
  end
end
