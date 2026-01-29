defmodule Bash.Sigil do
  @moduledoc """
  Sigil implementation for ~BASH and ~bash.

  This module provides the ~BASH/bash sigil that parses Bash scripts at compile time
  and returns a Script struct for execution.

  ## Validation

  The sigil performs structural validation on the parsed AST, detecting common errors:

  - Unclosed quotes (`"hello` or `'hello`)
  - Unclosed command groups (`{ echo hello`)
  - Missing control flow terminators (`if` without `fi`, `do` without `done`)

  Errors include ShellCheck-compatible codes and helpful hints.

  ## Examples

      # Valid scripts parse successfully:
      ~BASH"echo hello"
      ~BASH"if true; then echo hi; fi"

      # Invalid scripts raise SyntaxError:
      ~BASH"{ echo hello"
      # => ** (Bash.SyntaxError) [SC1056] Bash syntax error at line 1, column 0:
      #        { echo hello
      #        ^
      #      hint: '{' starts a command group - missing '}'
  """

  alias Bash.Parser
  alias Bash.SyntaxError

  @doc ~S"""
  The ~BASH sigil for parsing Bash scripts into a Script AST struct.

  Returns a Script struct that can be serialized back to bash strings.

  ## Modifiers

  Modifiers can be combined. Lowercase modifiers set session options,
  uppercase modifiers control output.

  ### Output modifiers (uppercase, mutually exclusive)

  - No output modifier: Returns `%Bash.Script{}` struct (default)
  - `S`: Execute and return stdout as string
  - `E`: Execute and return stderr as string
  - `O`: Execute and return combined output as string

  ### Session option modifiers (lowercase, can combine)

  - `e`: Enable errexit (exit on error)
  - `v`: Enable verbose mode
  - `p`: Enable pipefail
  - `u`: Enable nounset (error on undefined variables)

  ## Examples

      # Single command returns a Script:
      iex> ~BASH"echo hello world"
      %Bash.Script{statements: [%Bash.AST.Command{...}]}

      # Serialize back to string:
      iex> script = ~BASH"echo hello"
      iex> to_string(script)
      "echo hello"

      # Execute and get stdout:
      iex> ~BASH"echo hello"S
      "hello\n"

      # Execute and get stderr:
      iex> ~BASH"echo error >&2"E
      "error\n"

      # Execute and get combined output:
      iex> ~BASH"echo out; echo err >&2"O
      "out\nerr\n"

      # Execute with errexit and return stdout:
      iex> ~BASH"echo hello"eS
      "hello\n"

      # Execute with pipefail and errexit:
      iex> ~BASH"false | echo hi"epS
      "hi\n"

  """
  defmacro sigil_b(term, modifiers) do
    handle_sigil(term, modifiers)
  end

  defmacro sigil_BASH(term, modifiers) do
    handle_sigil(term, modifiers)
  end

  defp handle_sigil(term, modifiers) do
    case term do
      {:<<>>, _, [script]} when is_binary(script) ->
        case parse_and_validate(script) do
          {:ok, ast} ->
            wrap_with_modifier(Macro.escape(ast), modifiers)

          {:error, %SyntaxError{} = error} ->
            raise error
        end

      {:<<>>, _, _parts} ->
        parsed =
          quote do
            Bash.Sigil.parse_at_runtime(unquote(term))
          end

        wrap_with_modifier(parsed, modifiers)
    end
  end

  defp wrap_with_modifier(ast_quoted, []), do: ast_quoted

  defp wrap_with_modifier(ast_quoted, modifiers) do
    {output_type, session_opts} = parse_modifiers(modifiers)

    case output_type do
      nil ->
        # No output modifier - just return the AST (but still apply session options if any)
        if session_opts == [] do
          ast_quoted
        else
          raise ArgumentError,
                "session option modifiers (e, v, p, u) require an output modifier (S, E, or O)"
        end

      output ->
        quote do
          Bash.Sigil.run_and_extract(unquote(ast_quoted), unquote(output), unquote(session_opts))
        end
    end
  end

  # Parse modifiers into {output_type, session_options}
  # Output modifiers: S (stdout), E (stderr), O (combined)
  # Session modifiers: e (errexit), v (verbose), p (pipefail), u (nounset)
  defp parse_modifiers(modifiers) do
    Enum.reduce(modifiers, {nil, []}, fn
      ?S, {nil, opts} ->
        {:stdout, opts}

      ?E, {nil, opts} ->
        {:stderr, opts}

      ?O, {nil, opts} ->
        {:output, opts}

      ?S, {_, _} ->
        raise ArgumentError,
              "multiple output modifiers specified (S, E, O are mutually exclusive)"

      ?E, {_, _} ->
        raise ArgumentError,
              "multiple output modifiers specified (S, E, O are mutually exclusive)"

      ?O, {_, _} ->
        raise ArgumentError,
              "multiple output modifiers specified (S, E, O are mutually exclusive)"

      ?e, {out, opts} ->
        {out, [{:errexit, true} | opts]}

      ?v, {out, opts} ->
        {out, [{:verbose, true} | opts]}

      ?p, {out, opts} ->
        {out, [{:pipefail, true} | opts]}

      ?u, {out, opts} ->
        {out, [{:nounset, true} | opts]}

      char, _ ->
        raise ArgumentError,
              "unknown sigil modifier: #{<<char>>}. " <>
                "Output: S (stdout), E (stderr), O (combined). " <>
                "Options: e (errexit), v (verbose), p (pipefail), u (nounset)"
    end)
  end

  @doc false
  def parse_at_runtime(script) when is_binary(script) do
    case parse_and_validate(script) do
      {:ok, ast} ->
        ast

      {:error, %SyntaxError{} = error} ->
        raise error
    end
  end

  @doc false
  def run_and_extract(script, output_type, session_opts \\ []) do
    options =
      if session_opts == [] do
        []
      else
        [options: Map.new(session_opts)]
      end

    case Bash.run(script, options) do
      {status, result, session} when status in [:ok, :exit, :error] ->
        output = extract_output(result, output_type)
        Bash.Session.stop(session)
        output

      {:exec, result, session} ->
        output = extract_output(result, output_type)
        Bash.Session.stop(session)
        output
    end
  end

  defp extract_output(result, :stdout), do: Bash.ExecutionResult.stdout(result)
  defp extract_output(result, :stderr), do: Bash.ExecutionResult.stderr(result)
  defp extract_output(result, :output), do: Bash.ExecutionResult.all_output(result)

  defp parse_and_validate(script) do
    case Parser.parse(script) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, reason, line, column} ->
        {:error, SyntaxError.from_parse_error(script, reason, line, column)}
    end
  end
end
