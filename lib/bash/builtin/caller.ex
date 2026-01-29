defmodule Bash.Builtin.Caller do
  @moduledoc """
  `caller [EXPR]`

  Returns the context of the current subroutine call.

  Without EXPR, returns "$line $filename".  With EXPR, returns "$line $subroutine $filename";
  this extra information can be used to provide a stack trace.

  The value of EXPR indicates how many call frames to go back before the
  current one; the top frame is frame 0.

  ## Call Stack Entry Format

  Each entry in the session's `call_stack` should be a map with:
  - `:line_number` - The line number where the function was called from
  - `:function_name` - The name of the function being called
  - `:source_file` - The source file containing the call

  ## Exit Status

  Returns 0 if the specified frame exists, 1 otherwise (including when not in a function).

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/caller.def?h=bash-5.3
  """
  use Bash.Builtin

  # Execute the caller builtin.
  @doc false
  defbash execute(args, state) do
    case args do
      [] ->
        # caller with no arguments: returns "$line $filename"
        case get_call_frame(state, 0) do
          {:ok, frame} ->
            puts("#{frame.line_number} #{frame.source_file}")
            :ok

          :error ->
            # Not in a function or no call stack
            {:ok, 1}
        end

      [expr_str] ->
        # caller with EXPR: returns "$line $subroutine $filename"
        case Integer.parse(String.trim(expr_str)) do
          {frame_num, ""} when frame_num >= 0 ->
            case get_call_frame(state, frame_num) do
              {:ok, frame} ->
                puts("#{frame.line_number} #{frame.function_name} #{frame.source_file}")
                :ok

              :error ->
                # Frame doesn't exist or not in a function
                {:ok, 1}
            end

          {frame_num, ""} when frame_num < 0 ->
            # Negative frame number is treated as invalid option by bash (exit code 2)
            error("caller: #{frame_num}: invalid option\ncaller: usage: caller [expr]")
            {:ok, 2}

          _ ->
            # Non-numeric argument - bash treats as invalid number (exit code 2)
            trimmed = String.trim(expr_str)
            error("caller: #{trimmed}: invalid number\ncaller: usage: caller [expr]")
            {:ok, 2}
        end

      [_ | _] ->
        # Too many arguments - caller only accepts 0 or 1 argument
        error("caller: too many arguments")
        {:ok, 1}
    end
  end

  # Get the call frame at the specified depth from the call stack.
  # Returns {:ok, frame} if found, :error otherwise.
  defp get_call_frame(state, frame_num) do
    # Check if we're in a function
    in_function = Map.get(state, :in_function, false)

    if in_function do
      # Get the call stack - it should be a list where index 0 is the most recent call
      call_stack = Map.get(state, :call_stack, [])

      case Enum.at(call_stack, frame_num) do
        nil -> :error
        frame -> {:ok, normalize_frame(frame)}
      end
    else
      :error
    end
  end

  # Normalize a frame to ensure it has required keys with defaults
  defp normalize_frame(frame) when is_map(frame) do
    %{
      line_number: Map.get(frame, :line_number, 0),
      function_name: Map.get(frame, :function_name, "main"),
      source_file: Map.get(frame, :source_file, "bash")
    }
  end

  defp normalize_frame(_), do: %{line_number: 0, function_name: "main", source_file: "bash"}
end
