defmodule Bash.FuzzTest do
  @moduledoc """
  Property-based fuzz tests for the Bash interpreter.

  Uses StreamData to generate random and semi-valid Bash inputs,
  verifying that the tokenizer, parser, and executor never crash
  on arbitrary input. They may return errors, but must not raise
  or exit unexpectedly.
  """

  use Bash.SessionCase, async: true
  use ExUnitProperties

  setup :start_session

  @bash_special_chars ~c[ |&;()<>$`"'\\!{}*?\#~=%\n\t]
  @bash_keywords ~w[if then else elif fi for while until do done case esac in
                     function select coproc time break continue return exit] ++
                   ["{", "}", "!", "[[", "]]"]

  defp bash_char do
    frequency([
      {5, member_of(Enum.concat([?a..?z, ?A..?Z, ?0..?9]))},
      {3, member_of(@bash_special_chars)},
      {1, member_of(~c[-_./,+:@^])}
    ])
  end

  defp safe_word_char do
    frequency([
      {5, member_of(Enum.concat([?a..?z, ?A..?Z, ?0..?9]))},
      {2, member_of(~c[-_./:@^+=,])},
      {1, member_of(~c[ \t])}
    ])
  end

  defp safe_word do
    gen all(chars <- list_of(safe_word_char(), min_length: 1, max_length: 12)) do
      String.trim(List.to_string(chars))
    end
  end

  defp bash_string do
    gen all(chars <- list_of(bash_char(), max_length: 200)) do
      List.to_string(chars)
    end
  end

  defp simple_command do
    gen all(
          cmd <- member_of(~w[echo printf true false test]),
          args <- list_of(safe_word(), max_length: 5)
        ) do
      Enum.join([cmd | args], " ")
    end
  end

  defp assignment do
    gen all(
          name <- string(?a..?z, min_length: 1, max_length: 8),
          value <- safe_word()
        ) do
      "#{name}=#{value}"
    end
  end

  defp variable_expansion do
    gen all(
          name <- string(?a..?z, min_length: 1, max_length: 8),
          op <-
            member_of([
              "$#{name}",
              "${#{name}}",
              "${#{name}:-default}",
              "${#{name}:+alt}",
              "${#{name}:?err}",
              "${##{name}}",
              "${#{name}^^}",
              "${#{name},,}",
              "${#{name}%pat}",
              "${#{name}#pat}",
              "${#{name}/old/new}"
            ])
        ) do
      "echo #{op}"
    end
  end

  defp arithmetic_expression do
    gen all(
          a <- integer(-100..100),
          op <- member_of(~w[+ - * / % ** == != < > <= >= & | ^ << >>]),
          b <- integer(-100..100)
        ) do
      "echo $(( #{a} #{op} #{b} ))"
    end
  end

  defp if_statement do
    gen all(
          condition <- simple_command(),
          body <- simple_command()
        ) do
      "if #{condition}; then #{body}; fi"
    end
  end

  defp for_loop do
    gen all(
          var <- string(?a..?z, min_length: 1, max_length: 4),
          items <- list_of(safe_word(), min_length: 1, max_length: 5),
          body <- simple_command()
        ) do
      "for #{var} in #{Enum.join(items, " ")}; do #{body}; done"
    end
  end

  defp while_loop do
    gen all(body <- simple_command()) do
      "i=0; while [ $i -lt 3 ]; do #{body}; i=$((i+1)); done"
    end
  end

  defp case_statement do
    gen all(
          word <- safe_word(),
          pattern <- safe_word(),
          body <- simple_command()
        ) do
      "case #{word} in #{pattern}) #{body};; esac"
    end
  end

  defp pipeline do
    gen all(cmds <- list_of(simple_command(), min_length: 2, max_length: 4)) do
      Enum.join(cmds, " | ")
    end
  end

  defp compound_list do
    gen all(
          cmds <- list_of(simple_command(), min_length: 1, max_length: 5),
          sep <- member_of(["; ", " && ", " || "])
        ) do
      Enum.join(cmds, sep)
    end
  end

  defp redirect do
    gen all(
          cmd <- simple_command(),
          op <- member_of(~w[> >> < 2> 2>> &> &>>]),
          target <- member_of(["/dev/null", "/tmp/fuzz_out"])
        ) do
      "#{cmd} #{op} #{target}"
    end
  end

  defp subshell do
    gen all(cmd <- simple_command()) do
      "(#{cmd})"
    end
  end

  defp command_substitution do
    gen all(
          cmd <- simple_command(),
          style <- member_of([:dollar, :backtick])
        ) do
      case style do
        :dollar -> "echo $(#{cmd})"
        :backtick -> "echo `#{cmd}`"
      end
    end
  end

  defp keyword_soup do
    gen all(words <- list_of(member_of(@bash_keywords), min_length: 1, max_length: 10)) do
      Enum.join(words, " ")
    end
  end

  defp bash_script do
    one_of([
      bash_string(),
      simple_command(),
      assignment(),
      variable_expansion(),
      arithmetic_expression(),
      if_statement(),
      for_loop(),
      while_loop(),
      case_statement(),
      pipeline(),
      compound_list(),
      redirect(),
      subshell(),
      command_substitution(),
      keyword_soup()
    ])
  end

  defp assert_no_crash(input, fun) do
    try do
      fun.()
    rescue
      exception ->
        flunk("""
        Crashed on input: #{inspect(input)}
        Exception: #{Exception.format(:error, exception, __STACKTRACE__)}
        """)
    catch
      kind, reason ->
        flunk("""
        Crashed on input: #{inspect(input)}
        #{Exception.format(kind, reason, __STACKTRACE__)}
        """)
    end
  end

  defp fuzz_parse(input) do
    assert_no_crash(input, fn ->
      Bash.Parser.parse(input)
    end)
  end

  defp fuzz_tokenize(input) do
    assert_no_crash(input, fn ->
      Bash.Tokenizer.tokenize(input)
    end)
  end

  defp new_session(context) do
    registry_name = Module.concat([context.module, FuzzRegistry, context.test])
    supervisor_name = Module.concat([context.module, FuzzSupervisor, context.test])

    unless Process.whereis(registry_name) do
      start_supervised!({Registry, keys: :unique, name: registry_name})
    end

    unless Process.whereis(supervisor_name) do
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})
    end

    {:ok, session} =
      Bash.Session.new(
        id: "fuzz_#{System.unique_integer([:positive])}",
        registry: registry_name,
        supervisor: supervisor_name
      )

    session
  end

  defp fuzz_execute(context, input) do
    session = new_session(context)

    try do
      assert_no_crash(input, fn ->
        case Bash.Parser.parse(input) do
          {:ok, ast} -> Bash.Session.execute(session, ast)
          {:error, _, _, _} -> :parse_error
        end
      end)
    after
      if Process.alive?(session), do: GenServer.stop(session, :normal, 1000)
    end
  end

  describe "tokenizer" do
    property "never crashes on arbitrary input" do
      check all(input <- bash_string(), max_runs: 500) do
        fuzz_tokenize(input)
      end
    end

    property "never crashes on binary noise" do
      check all(input <- binary(max_length: 200), max_runs: 500) do
        fuzz_tokenize(input)
      end
    end
  end

  describe "parser" do
    property "never crashes on arbitrary input" do
      check all(input <- bash_string(), max_runs: 500) do
        fuzz_parse(input)
      end
    end

    property "never crashes on generated scripts" do
      check all(input <- bash_script(), max_runs: 500) do
        fuzz_parse(input)
      end
    end

    property "never crashes on keyword combinations" do
      check all(input <- keyword_soup(), max_runs: 200) do
        fuzz_parse(input)
      end
    end
  end

  describe "tokenizer into parser roundtrip" do
    property "tokenize then parse never crashes" do
      check all(input <- bash_string(), max_runs: 500) do
        assert_no_crash(input, fn ->
          case Bash.Tokenizer.tokenize(input) do
            {:ok, tokens} -> Bash.Parser.parse_tokens(tokens)
            {:error, _, _, _} -> :tokenize_error
          end
        end)
      end
    end
  end

  describe "executor" do
    property "never crashes on generated scripts", context do
      check all(input <- bash_script(), max_runs: 200) do
        fuzz_execute(context, input)
      end
    end

    property "variable expansions never crash", context do
      check all(input <- variable_expansion(), max_runs: 200) do
        fuzz_execute(context, input)
      end
    end

    property "arithmetic never crashes", context do
      check all(input <- arithmetic_expression(), max_runs: 200) do
        fuzz_execute(context, input)
      end
    end

    property "control flow never crashes", context do
      check all(
              input <-
                one_of([if_statement(), for_loop(), while_loop(), case_statement()]),
              max_runs: 100
            ) do
        fuzz_execute(context, input)
      end
    end

    property "pipelines never crash", context do
      check all(input <- pipeline(), max_runs: 100) do
        fuzz_execute(context, input)
      end
    end
  end
end
