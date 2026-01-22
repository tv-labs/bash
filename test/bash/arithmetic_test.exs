defmodule Bash.ArithmeticTest do
  use ExUnit.Case, async: true

  alias Bash.Arithmetic
  alias Bash.AST.Command
  alias Bash.AST.Word
  alias Bash.Executor
  alias Bash.OutputCollector
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session
  alias Bash.Sink
  alias Bash.Variable

  # Helper to create a session state with a collector for capturing output
  defp session_state_with_collector(env_vars \\ %{}) do
    variables = Map.new(env_vars, fn {k, v} -> {k, Variable.new(v)} end)
    {:ok, collector} = OutputCollector.start_link()
    sink = Sink.collector(collector)

    state = %Session{
      id: "test",
      variables: variables,
      working_dir: "/tmp",
      functions: %{},
      aliases: %{},
      options: %{},
      hash: %{},
      in_function: false,
      jobs: %{},
      next_job_number: 1,
      current_job: nil,
      previous_job: nil,
      completed_jobs: [],
      output_collector: collector,
      stdout_sink: sink,
      stderr_sink: sink
    }

    {state, collector}
  end

  # Helper to parse and execute a command, returns result and collector
  # Returns {:ok, result, collector} or {:error, result, collector}
  defp run_command(cmd, session_state_or_env \\ nil) do
    {state, collector} =
      case session_state_or_env do
        nil -> session_state_with_collector()
        %Session{} = s -> {s, s.output_collector}
        env when is_map(env) -> session_state_with_collector(env)
      end

    {:ok, %Script{statements: [ast]}} = Parser.parse(cmd)

    result =
      case Executor.execute(ast, state) do
        {:ok, result, _updates} -> {:ok, result}
        {:ok, result} -> {:ok, result}
        {:error, result, _updates} -> {:error, result}
        {:error, result} -> {:error, result}
      end

    case result do
      {:ok, r} -> {:ok, r, collector}
      {:error, r} -> {:error, r, collector}
    end
  end

  # Helper to get stdout from collector
  defp get_output(collector) when is_pid(collector) do
    collector
    |> OutputCollector.stdout()
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  describe "Arithmetic.evaluate/2" do
    test "basic addition" do
      assert {:ok, 3, %{}} = Arithmetic.evaluate("1 + 2", %{})
    end

    test "basic subtraction" do
      assert {:ok, 5, %{}} = Arithmetic.evaluate("10 - 5", %{})
    end

    test "basic multiplication" do
      assert {:ok, 12, %{}} = Arithmetic.evaluate("3 * 4", %{})
    end

    test "basic division" do
      assert {:ok, 5, %{}} = Arithmetic.evaluate("15 / 3", %{})
    end

    test "integer division truncates" do
      assert {:ok, 3, %{}} = Arithmetic.evaluate("10 / 3", %{})
    end

    test "modulo" do
      assert {:ok, 1, %{}} = Arithmetic.evaluate("10 % 3", %{})
    end

    test "exponentiation" do
      assert {:ok, 8, %{}} = Arithmetic.evaluate("2 ** 3", %{})
      assert {:ok, 1024, %{}} = Arithmetic.evaluate("2 ** 10", %{})
    end

    test "operator precedence" do
      assert {:ok, 14, %{}} = Arithmetic.evaluate("2 + 3 * 4", %{})
      assert {:ok, 20, %{}} = Arithmetic.evaluate("(2 + 3) * 4", %{})
    end

    test "variable expansion" do
      env = %{"x" => "5", "y" => "3"}
      assert {:ok, 8, ^env} = Arithmetic.evaluate("x + y", env)
    end

    test "undefined variable defaults to 0" do
      assert {:ok, 5, %{}} = Arithmetic.evaluate("x + 5", %{})
    end

    test "assignment operator" do
      assert {:ok, 5, %{"x" => "5"}} = Arithmetic.evaluate("x = 5", %{})
    end

    test "compound assignment operators" do
      env = %{"x" => "10"}
      assert {:ok, 15, %{"x" => "15"}} = Arithmetic.evaluate("x += 5", env)
      assert {:ok, 5, %{"x" => "5"}} = Arithmetic.evaluate("x -= 5", env)
      assert {:ok, 20, %{"x" => "20"}} = Arithmetic.evaluate("x *= 2", env)
      assert {:ok, 5, %{"x" => "5"}} = Arithmetic.evaluate("x /= 2", env)
      assert {:ok, 1, %{"x" => "1"}} = Arithmetic.evaluate("x %= 3", env)
    end

    test "pre-increment" do
      assert {:ok, 6, %{"x" => "6"}} = Arithmetic.evaluate("++x", %{"x" => "5"})
    end

    test "pre-decrement" do
      assert {:ok, 4, %{"x" => "4"}} = Arithmetic.evaluate("--x", %{"x" => "5"})
    end

    test "post-increment returns original value" do
      assert {:ok, 5, %{"x" => "6"}} = Arithmetic.evaluate("x++", %{"x" => "5"})
    end

    test "post-decrement returns original value" do
      assert {:ok, 5, %{"x" => "4"}} = Arithmetic.evaluate("x--", %{"x" => "5"})
    end

    test "unary plus" do
      assert {:ok, 5, %{}} = Arithmetic.evaluate("+5", %{})
    end

    test "unary minus" do
      assert {:ok, -5, %{}} = Arithmetic.evaluate("-5", %{})
    end

    test "logical NOT" do
      assert {:ok, 0, %{}} = Arithmetic.evaluate("!5", %{})
      assert {:ok, 1, %{}} = Arithmetic.evaluate("!0", %{})
    end

    test "bitwise NOT" do
      assert {:ok, -6, %{}} = Arithmetic.evaluate("~5", %{})
    end

    test "comparison operators" do
      assert {:ok, 1, %{}} = Arithmetic.evaluate("5 > 3", %{})
      assert {:ok, 0, %{}} = Arithmetic.evaluate("5 < 3", %{})
      assert {:ok, 1, %{}} = Arithmetic.evaluate("5 >= 5", %{})
      assert {:ok, 1, %{}} = Arithmetic.evaluate("5 <= 5", %{})
      assert {:ok, 1, %{}} = Arithmetic.evaluate("5 == 5", %{})
      assert {:ok, 1, %{}} = Arithmetic.evaluate("5 != 3", %{})
    end

    test "logical AND" do
      assert {:ok, 1, %{}} = Arithmetic.evaluate("1 && 1", %{})
      assert {:ok, 0, %{}} = Arithmetic.evaluate("1 && 0", %{})
      assert {:ok, 0, %{}} = Arithmetic.evaluate("0 && 1", %{})
    end

    test "logical OR" do
      assert {:ok, 1, %{}} = Arithmetic.evaluate("1 || 0", %{})
      assert {:ok, 1, %{}} = Arithmetic.evaluate("0 || 1", %{})
      assert {:ok, 0, %{}} = Arithmetic.evaluate("0 || 0", %{})
    end

    test "bitwise AND" do
      assert {:ok, 4, %{}} = Arithmetic.evaluate("5 & 6", %{})
    end

    test "bitwise OR" do
      assert {:ok, 7, %{}} = Arithmetic.evaluate("5 | 6", %{})
    end

    test "bitwise XOR" do
      assert {:ok, 3, %{}} = Arithmetic.evaluate("5 ^ 6", %{})
    end

    test "left shift" do
      assert {:ok, 16, %{}} = Arithmetic.evaluate("2 << 3", %{})
    end

    test "right shift" do
      assert {:ok, 2, %{}} = Arithmetic.evaluate("16 >> 3", %{})
    end

    test "ternary operator" do
      assert {:ok, 10, %{}} = Arithmetic.evaluate("1 ? 10 : 20", %{})
      assert {:ok, 20, %{}} = Arithmetic.evaluate("0 ? 10 : 20", %{})
    end

    test "nested ternary" do
      assert {:ok, 1, %{}} = Arithmetic.evaluate("1 ? 1 ? 1 : 2 : 3", %{})
      assert {:ok, 3, %{}} = Arithmetic.evaluate("0 ? 1 : 1 ? 3 : 4", %{})
    end

    test "complex expression" do
      env = %{"a" => "10", "b" => "5"}
      assert {:ok, 17, ^env} = Arithmetic.evaluate("a + b * 2 - 3", env)
    end

    test "parentheses grouping" do
      assert {:ok, 9, %{}} = Arithmetic.evaluate("(1 + 2) * 3", %{})
    end

    test "nested parentheses" do
      assert {:ok, 21, %{}} = Arithmetic.evaluate("((1 + 2) * (3 + 4))", %{})
    end
  end

  describe "arithmetic expansion in commands $(())" do
    test "basic arithmetic expansion" do
      {:ok, _result, collector} = run_command("echo $((1+2))")
      assert get_output(collector) == "3"
    end

    test "arithmetic with spaces" do
      {:ok, _result, collector} = run_command("echo $((1 + 2))")
      assert get_output(collector) == "3"
    end

    test "subtraction" do
      {:ok, _result, collector} = run_command("echo $((10 - 3))")
      assert get_output(collector) == "7"
    end

    test "multiplication" do
      {:ok, _result, collector} = run_command("echo $((4 * 5))")
      assert get_output(collector) == "20"
    end

    test "division" do
      {:ok, _result, collector} = run_command("echo $((20 / 4))")
      assert get_output(collector) == "5"
    end

    test "modulo" do
      {:ok, _result, collector} = run_command("echo $((17 % 5))")
      assert get_output(collector) == "2"
    end

    test "exponentiation" do
      {:ok, _result, collector} = run_command("echo $((2 ** 8))")
      assert get_output(collector) == "256"
    end

    test "variable expansion in arithmetic" do
      {:ok, _result, collector} = run_command("echo $((x + y))", %{"x" => "5", "y" => "3"})
      assert get_output(collector) == "8"
    end

    test "variable multiplication" do
      {:ok, _result, collector} = run_command("echo $((a * b))", %{"a" => "6", "b" => "7"})
      assert get_output(collector) == "42"
    end

    test "comparison operators" do
      {:ok, _result, collector} = run_command("echo $((5 > 3))")
      assert get_output(collector) == "1"

      {:ok, _result, collector} = run_command("echo $((5 < 3))")
      assert get_output(collector) == "0"

      {:ok, _result, collector} = run_command("echo $((5 == 5))")
      assert get_output(collector) == "1"

      {:ok, _result, collector} = run_command("echo $((5 != 5))")
      assert get_output(collector) == "0"
    end

    test "ternary operator" do
      {:ok, _result, collector} = run_command("echo $((5 > 3 ? 10 : 20))")
      assert get_output(collector) == "10"

      {:ok, _result, collector} = run_command("echo $((5 < 3 ? 10 : 20))")
      assert get_output(collector) == "20"
    end

    test "bitwise operators" do
      {:ok, _result, collector} = run_command("echo $((5 & 3))")
      assert get_output(collector) == "1"

      {:ok, _result, collector} = run_command("echo $((5 | 3))")
      assert get_output(collector) == "7"

      {:ok, _result, collector} = run_command("echo $((5 ^ 3))")
      assert get_output(collector) == "6"

      {:ok, _result, collector} = run_command("echo $((1 << 4))")
      assert get_output(collector) == "16"

      {:ok, _result, collector} = run_command("echo $((16 >> 2))")
      assert get_output(collector) == "4"
    end

    test "logical operators" do
      {:ok, _result, collector} = run_command("echo $((1 && 1))")
      assert get_output(collector) == "1"

      {:ok, _result, collector} = run_command("echo $((1 && 0))")
      assert get_output(collector) == "0"

      {:ok, _result, collector} = run_command("echo $((0 || 1))")
      assert get_output(collector) == "1"

      {:ok, _result, collector} = run_command("echo $((0 || 0))")
      assert get_output(collector) == "0"
    end

    test "unary operators" do
      {:ok, _result, collector} = run_command("echo $((-5))")
      assert get_output(collector) == "-5"

      {:ok, _result, collector} = run_command("echo $((+5))")
      assert get_output(collector) == "5"

      {:ok, _result, collector} = run_command("echo $((!0))")
      assert get_output(collector) == "1"

      {:ok, _result, collector} = run_command("echo $((!5))")
      assert get_output(collector) == "0"
    end

    test "arithmetic expansion with surrounding text" do
      {:ok, _result, collector} = run_command("echo result=$((2+3))")
      assert get_output(collector) == "result=5"
    end

    test "multiple arithmetic expansions" do
      {:ok, _result, collector} = run_command("echo $((1+2)) $((3+4))")
      assert get_output(collector) == "3 7"
    end

    test "nested parentheses in arithmetic" do
      {:ok, _result, collector} = run_command("echo $(((2+3)*4))")
      assert get_output(collector) == "20"
    end

    test "complex expression with precedence" do
      {:ok, _result, collector} = run_command("echo $((2 + 3 * 4 - 1))")
      assert get_output(collector) == "13"
    end

    test "arithmetic with undefined variable defaults to 0" do
      {:ok, _result, collector} = run_command("echo $((undefined_var + 5))")
      assert get_output(collector) == "5"
    end
  end

  describe "parser: arithmetic expansion AST" do
    test "parses $((expr)) as arith_expand" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo $((1+2))")

      assert %Command{
               name: %Word{parts: [literal: "echo"]},
               args: [%Word{parts: [arith_expand: "1+2"]}]
             } = ast
    end

    test "parses arithmetic expansion with spaces" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo $((x + y))")

      assert %Command{
               args: [%Word{parts: [arith_expand: "x + y"]}]
             } = ast
    end

    test "parses mixed word with arithmetic expansion" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo prefix$((1+2))suffix")

      assert %Command{
               args: [
                 %Word{
                   parts: [
                     {:literal, "prefix"},
                     {:arith_expand, "1+2"},
                     {:literal, "suffix"}
                   ]
                 }
               ]
             } = ast
    end

    test "distinguishes $((...)) from $(cmd)" do
      {:ok, %Script{statements: [cmd_subst]}} = Parser.parse("echo $(echo test)")
      {:ok, %Script{statements: [arith_exp]}} = Parser.parse("echo $((1+2))")

      # Command substitution has :command_subst
      assert %Command{
               args: [%Word{parts: [{:command_subst, _}]}]
             } = cmd_subst

      # Arithmetic expansion has :arith_expand
      assert %Command{
               args: [%Word{parts: [{:arith_expand, _}]}]
             } = arith_exp
    end
  end

  describe "arithmetic conditions in if statements" do
    test "if (( 5 > 3 )) true branch" do
      {:ok, _result, collector} =
        run_command(~S"""
          if (( 5 > 3 )); then
            echo "yes"
          fi
        """)

      assert get_output(collector) == "yes"
    end

    test "if (( 3 > 5 )) false branch" do
      {:ok, _result, collector} =
        run_command(~S"""
          if (( 3 > 5 )); then
            echo "yes"
          else
            echo "no"
          fi
        """)

      assert get_output(collector) == "no"
    end

    test "arithmetic condition with variable" do
      {:ok, _result, collector} =
        run_command(
          ~S"""
            if (( x > 5 )); then
              echo "big"
            fi
          """,
          %{"x" => "10"}
        )

      assert get_output(collector) == "big"
    end

    test "arithmetic equality condition" do
      {:ok, _result, collector} =
        run_command(~S"""
          if (( 5 == 5 )); then
            echo "equal"
          fi
        """)

      assert get_output(collector) == "equal"
    end
  end
end
