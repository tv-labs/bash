defmodule Bash.HeredocTest do
  use ExUnit.Case, async: true

  alias Bash.AST
  alias Bash.Executor
  alias Bash.OutputCollector
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Sink
  alias Bash.Variable

  # Helper to create session state with collector for output capture
  defp session_state_with_collector(variables \\ %{}) do
    {:ok, collector} = OutputCollector.start_link()
    sink = Sink.collector(collector)

    state = %{
      variables: variables,
      working_dir: System.tmp_dir!(),
      aliases: %{},
      hash: %{},
      functions: %{},
      output_collector: collector,
      stdout_sink: sink,
      stderr_sink: sink
    }

    {state, collector}
  end

  # Helper to handle both {:ok, result} and {:ok, result, state} returns
  # Returns {:ok, result, collector}
  defp execute_command(ast, session_state, collector) do
    result =
      case Executor.execute(ast, session_state) do
        {:ok, result, _state} -> {:ok, result}
        {:ok, result} -> {:ok, result}
        other -> other
      end

    case result do
      {:ok, r} -> {:ok, r, collector}
      {:error, r} -> {:error, r, collector}
      other -> other
    end
  end

  # Helper to get stdout from collector
  defp get_stdout(collector) when is_pid(collector) do
    collector
    |> OutputCollector.stdout()
    |> IO.iodata_to_binary()
  end

  # Helper to extract first command from statements (skipping separators)
  defp first_command(statements) do
    Enum.find(statements, &match?(%AST.Command{}, &1))
  end

  # Helper to extract first pipeline from statements (skipping separators)
  defp first_pipeline(statements) do
    Enum.find(statements, &match?(%AST.Pipeline{}, &1))
  end

  describe "herestring parsing (<<<)" do
    test "parses basic herestring" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<< hello")

      assert %AST.Command{
               name: %AST.Word{parts: [{:literal, "cat"}]},
               redirects: [
                 %AST.Redirect{
                   direction: :herestring,
                   fd: 0,
                   target: {:word, %AST.Word{parts: [{:literal, "hello"}]}}
                 }
               ]
             } = ast
    end

    test "parses herestring with quoted string" do
      {:ok, %Script{statements: [ast]}} = Parser.parse(~s(cat <<< "hello world"))

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :herestring,
                   target: {:word, %AST.Word{parts: [{:literal, "hello world"}], quoted: :double}}
                 }
               ]
             } = ast
    end

    test "parses herestring with variable" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<< $VAR")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :herestring,
                   target: {:word, %AST.Word{parts: [{:variable, %AST.Variable{name: "VAR"}}]}}
                 }
               ]
             } = ast
    end

    test "parses herestring with custom fd" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat 3<<< data")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :herestring,
                   fd: 3,
                   target: {:word, %AST.Word{parts: [{:literal, "data"}]}}
                 }
               ]
             } = ast
    end

    test "serializes herestring" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<< hello")
      assert to_string(ast) == "cat <<< hello"
    end

    test "serializes herestring with quoted string" do
      {:ok, %Script{statements: [ast]}} = Parser.parse(~s(cat <<< "hello world"))
      assert to_string(ast) == ~s(cat <<< "hello world")
    end
  end

  describe "heredoc parsing (<<)" do
    test "parses basic heredoc marker" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<EOF")

      assert %AST.Command{
               name: %AST.Word{parts: [{:literal, "cat"}]},
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   fd: 0,
                   target: {:heredoc_pending, "EOF", false, true}
                 }
               ]
             } = ast
    end

    test "parses heredoc marker with tab stripping" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<-EOF")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc_pending, "EOF", true, true}
                 }
               ]
             } = ast
    end

    test "parses heredoc with single-quoted delimiter (no expansion)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<'EOF'")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc_pending, "EOF", false, false}
                 }
               ]
             } = ast
    end

    test "parses heredoc with double-quoted delimiter (no expansion)" do
      {:ok, %Script{statements: [ast]}} = Parser.parse(~s(cat <<"EOF"))

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc_pending, "EOF", false, false}
                 }
               ]
             } = ast
    end

    test "parses heredoc with custom fd" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat 3<<DELIM")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   fd: 3,
                   target: {:heredoc_pending, "DELIM", false, true}
                 }
               ]
             } = ast
    end

    test "parses heredoc with command arguments" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat -n <<EOF")

      assert %AST.Command{
               name: %AST.Word{parts: [{:literal, "cat"}]},
               args: [%AST.Word{parts: [{:literal, "-n"}]}],
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc_pending, "EOF", false, true}
                 }
               ]
             } = ast
    end

    test "serializes heredoc pending marker" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<EOF")
      assert to_string(ast) == "cat <<EOF"
    end

    test "serializes heredoc pending marker with tab stripping" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<-EOF")
      assert to_string(ast) == "cat <<-EOF"
    end
  end

  describe "heredoc content processing" do
    test "processes heredoc content from remaining input" do
      input = "cat <<EOF\nhello\nworld\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc, %AST.Word{parts: parts}, "EOF", _}
                 }
               ]
             } = ast

      assert parts == [{:literal, "hello\nworld\n"}]
    end

    test "processes heredoc with tab stripping" do
      # Use explicit tab character
      input = "cat <<-EOF\n\thello\n\tworld\n\tEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc, %AST.Word{parts: parts}, "EOF", _}
                 }
               ]
             } = ast

      assert parts == [{:literal, "hello\nworld\n"}]
    end

    test "processes heredoc preserving content without tab stripping" do
      input = "cat <<EOF\n\thello\n\tworld\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc, %AST.Word{parts: parts}, "EOF", _}
                 }
               ]
             } = ast

      assert parts == [{:literal, "\thello\n\tworld\n"}]
    end

    test "handles empty heredoc" do
      input = "cat <<EOF\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{
                   direction: :heredoc,
                   target: {:heredoc, %AST.Word{parts: parts}, "EOF", _}
                 }
               ]
             } = ast

      # Empty heredocs have empty parts (execution provides empty stdin)
      assert parts == []
    end

    test "handles content after heredoc in same script" do
      input = "cat <<EOF\ncontent\nEOF\necho done\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)

      # Filter out separators to get actual commands
      commands = Enum.filter(statements, &match?(%AST.Command{}, &1))

      assert [cat_cmd, echo_cmd] = commands

      assert %AST.Command{
               redirects: [%AST.Redirect{direction: :heredoc}]
             } = cat_cmd

      assert %AST.Command{name: %AST.Word{parts: [{:literal, "echo"}]}} = echo_cmd
    end

    test "serializes processed heredoc" do
      input = "cat <<EOF\nhello\nworld\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)

      serialized = to_string(ast)
      assert serialized == "cat <<EOF\nhello\nworld\nEOF"
    end
  end

  describe "heredoc in pipelines" do
    test "parses heredoc in pipeline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<EOF | grep hello")

      assert %AST.Pipeline{
               commands: [
                 %AST.Command{
                   name: %AST.Word{parts: [{:literal, "cat"}]},
                   redirects: [%AST.Redirect{direction: :heredoc}]
                 },
                 %AST.Command{
                   name: %AST.Word{parts: [{:literal, "grep"}]},
                   args: [%AST.Word{parts: [{:literal, "hello"}]}]
                 }
               ]
             } = ast
    end

    test "processes heredoc content in pipeline" do
      input = "cat <<EOF | grep hello\nhello world\ngoodbye world\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_pipeline(statements)

      assert %AST.Pipeline{
               commands: [
                 %AST.Command{
                   redirects: [
                     %AST.Redirect{
                       direction: :heredoc,
                       target: {:heredoc, %AST.Word{parts: parts}, "EOF", _}
                     }
                   ]
                 },
                 _grep_cmd
               ]
             } = ast

      assert parts == [{:literal, "hello world\ngoodbye world\n"}]
    end
  end

  describe "herestring execution" do
    test "herestring provides stdin to command" do
      {session_state, collector} = session_state_with_collector()

      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<< hello")
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "hello"
    end

    test "herestring expands variables" do
      {session_state, collector} =
        session_state_with_collector(%{"NAME" => Variable.new("world")})

      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<< $NAME")
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "world"
    end

    test "herestring with double-quoted variable expansion" do
      {session_state, collector} =
        session_state_with_collector(%{"MSG" => Variable.new("hello there")})

      {:ok, %Script{statements: [ast]}} = Parser.parse(~s(cat <<< "$MSG"))
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "hello there"
    end
  end

  describe "heredoc execution" do
    test "heredoc provides stdin to command" do
      {session_state, collector} = session_state_with_collector()

      input = "cat <<EOF\nhello world\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "hello world"
    end

    test "heredoc expands variables" do
      {session_state, collector} =
        session_state_with_collector(%{"NAME" => Variable.new("world")})

      input = "cat <<EOF\nhello $NAME\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "hello world"
    end

    test "heredoc with braced variable expansion" do
      {session_state, collector} =
        session_state_with_collector(%{"NAME" => Variable.new("everyone")})

      input = "cat <<EOF\nhello ${NAME}!\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "hello everyone!"
    end

    test "multiline heredoc content" do
      {session_state, collector} = session_state_with_collector()

      input = "cat <<EOF\nline one\nline two\nline three\nEOF\n"

      {:ok, %Script{statements: statements}} = Parser.parse(input)
      ast = first_command(statements)
      {:ok, _result, collector} = execute_command(ast, session_state, collector)

      stdout = get_stdout(collector)
      assert stdout =~ "line one"
      assert stdout =~ "line two"
      assert stdout =~ "line three"
    end
  end

  describe "multiple heredocs" do
    test "parses command with multiple heredocs" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd <<EOF1 <<EOF2")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :heredoc, target: {:heredoc_pending, "EOF1", _, _}},
                 %AST.Redirect{direction: :heredoc, target: {:heredoc_pending, "EOF2", _, _}}
               ]
             } = ast
    end
  end

  describe "mixed redirects" do
    test "parses heredoc with output redirect" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<EOF > output.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :heredoc},
                 %AST.Redirect{
                   direction: :output,
                   target: {:file, %AST.Word{parts: [{:literal, "output.txt"}]}}
                 }
               ]
             } = ast
    end

    test "parses herestring with output redirect" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cat <<< hello > output.txt")

      assert %AST.Command{
               redirects: [
                 %AST.Redirect{direction: :herestring},
                 %AST.Redirect{direction: :output}
               ]
             } = ast
    end
  end
end
