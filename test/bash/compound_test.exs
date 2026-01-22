defmodule Bash.CompoundTest do
  use Bash.SessionCase, async: true

  alias Bash.AST
  alias Bash.Parser
  alias Bash.Script
  alias Bash.Session

  describe "parsing && and ||" do
    test "parses && operator" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello && echo world")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 3

      [cmd1, {:operator, :and}, cmd2] = statements
      assert %AST.Command{} = cmd1
      assert %AST.Command{} = cmd2
    end

    test "parses || operator" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("false || echo fallback")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 3

      [cmd1, {:operator, :or}, cmd2] = statements
      assert %AST.Command{} = cmd1
      assert %AST.Command{} = cmd2
    end

    test "parses mixed && and ||" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd1 && cmd2 || cmd3")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 5

      [_cmd1, {:operator, :and}, _cmd2, {:operator, :or}, _cmd3] = statements
    end

    test "parses pipeline with &&" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo a | wc -c && echo done")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 3

      [pipeline, {:operator, :and}, cmd] = statements
      assert %AST.Pipeline{} = pipeline
      assert %AST.Command{} = cmd
    end

    test "simple command without operators returns Command, not Compound" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello")
      assert %AST.Command{} = ast
    end

    test "pipeline without operators returns Pipeline, not Compound" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello | wc -c")
      assert %AST.Pipeline{} = ast
    end
  end

  describe "serialization" do
    test "serializes && operator" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo hello && echo world")
      assert "echo hello && echo world" == to_string(ast)
    end

    test "serializes || operator" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("false || echo fallback")
      assert "false || echo fallback" == to_string(ast)
    end

    test "serializes mixed operators" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("cmd1 && cmd2 || cmd3")
      assert "cmd1 && cmd2 || cmd3" == to_string(ast)
    end

    test "serializes pipeline with &&" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo a | wc -c && echo done")
      assert "echo a | wc -c && echo done" == to_string(ast)
    end
  end

  describe "execution with &&" do
    setup do
      {:ok, session} = Session.start_link(id: "compound_test_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "executes second command when first succeeds", %{session: session} do
      result = run_script(session, "true && echo success")

      assert result.exit_code == 0
      assert get_stdout(result) == "success\n"
    end

    test "skips second command when first fails", %{session: session} do
      result = run_script(session, "false && echo should_not_run")

      assert result.exit_code == 1
      assert get_stdout(result) == ""
    end

    test "chains multiple && operators", %{session: session} do
      result = run_script(session, "true && true && echo all_passed")

      assert result.exit_code == 0
      assert get_stdout(result) == "all_passed\n"
    end

    test "stops at first failure in chain", %{session: session} do
      result = run_script(session, "true && false && echo should_not_run")

      assert result.exit_code == 1
      assert get_stdout(result) == ""
    end
  end

  describe "execution with ||" do
    setup do
      {:ok, session} = Session.start_link(id: "compound_test_or_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "skips second command when first succeeds", %{session: session} do
      result = run_script(session, "true || echo should_not_run")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end

    test "executes second command when first fails", %{session: session} do
      result = run_script(session, "false || echo fallback")

      assert result.exit_code == 0
      assert get_stdout(result) == "fallback\n"
    end

    test "chains multiple || operators", %{session: session} do
      result = run_script(session, "false || false || echo last_resort")

      assert result.exit_code == 0
      assert get_stdout(result) == "last_resort\n"
    end

    test "stops at first success in chain", %{session: session} do
      result = run_script(session, "false || true || echo should_not_run")

      assert result.exit_code == 0
      assert get_stdout(result) == ""
    end
  end

  describe "execution with mixed && and ||" do
    setup do
      {:ok, session} = Session.start_link(id: "compound_test_mixed_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "common pattern: cmd && success || fallback - success path", %{session: session} do
      result = run_script(session, "true && echo success || echo fallback")

      assert result.exit_code == 0
      # success runs, then || sees success so fallback doesn't run
      assert get_stdout(result) == "success\n"
    end

    test "common pattern: cmd && success || fallback - failure path", %{session: session} do
      result = run_script(session, "false && echo success || echo fallback")

      assert result.exit_code == 0
      # false fails, && skips success, || sees failure so fallback runs
      assert get_stdout(result) == "fallback\n"
    end
  end

  describe "test commands with && and ||" do
    test "parses test command with &&" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("[ -d /tmp ] && echo exists")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 3

      [test_cmd, {:operator, :and}, cmd] = statements
      assert %AST.TestCommand{} = test_cmd
      assert %AST.Command{} = cmd
    end

    test "parses test command with ||" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("[ -f /nonexistent ] || echo missing")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      [test_cmd, {:operator, :or}, cmd] = statements
      assert %AST.TestCommand{} = test_cmd
      assert %AST.Command{} = cmd
    end

    test "parses chained test commands" do
      {:ok, %Script{statements: [ast]}} =
        Parser.parse("[ -d /tmp ] && [ -w /tmp ] && echo writable")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 5

      [test1, {:operator, :and}, test2, {:operator, :and}, cmd] = statements
      assert %AST.TestCommand{} = test1
      assert %AST.TestCommand{} = test2
      assert %AST.Command{} = cmd
    end

    test "serializes test command with &&" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("[ -d /tmp ] && echo exists")
      assert "[ -d /tmp ] && echo exists" == to_string(ast)
    end
  end

  describe "test expressions with && and ||" do
    test "parses test expression with &&" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("[[ -n foo ]] && echo not_empty")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      [test_expr, {:operator, :and}, cmd] = statements
      assert %AST.TestExpression{} = test_expr
      assert %AST.Command{} = cmd
    end

    test "parses test expression with ||" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("[[ -z \"\" ]] || echo has_content")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      [test_expr, {:operator, :or}, cmd] = statements
      assert %AST.TestExpression{} = test_expr
      assert %AST.Command{} = cmd
    end

    test "serializes test expression with &&" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("[[ -n foo ]] && echo not_empty")
      assert "[[ -n foo ]] && echo not_empty" == to_string(ast)
    end
  end

  describe "multiline compounds" do
    test "parses && with trailing newline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("echo one &&\necho two")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 3
      [cmd1, {:operator, :and}, cmd2] = statements
      assert %AST.Command{} = cmd1
      assert %AST.Command{} = cmd2
    end

    test "parses || with trailing newline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("false ||\necho fallback")

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      [cmd1, {:operator, :or}, cmd2] = statements
      assert %AST.Command{} = cmd1
      assert %AST.Command{} = cmd2
    end

    test "parses multiline chain" do
      input = """
      echo one &&
      echo two &&
      echo three
      """

      {:ok, %Script{statements: [ast]}} = Parser.parse(String.trim(input))

      assert %AST.Compound{kind: :operand, statements: statements} = ast
      assert length(statements) == 5
    end
  end

  describe "execution with test commands" do
    setup do
      {:ok, session} = Session.start_link(id: "compound_test_tcmd_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "test command success continues with &&", %{session: session} do
      result = run_script(session, "[ -d /tmp ] && echo dir_exists")

      assert result.exit_code == 0
      assert get_stdout(result) == "dir_exists\n"
    end

    test "test command failure triggers ||", %{session: session} do
      result = run_script(session, "[ -f /nonexistent_file_12345 ] || echo not_found")

      assert result.exit_code == 0
      assert get_stdout(result) == "not_found\n"
    end

    test "test command failure skips &&", %{session: session} do
      result = run_script(session, "[ -f /nonexistent_file_12345 ] && echo should_not_run")

      assert result.exit_code == 1
      assert get_stdout(result) == ""
    end
  end

  describe "execution with test expressions" do
    setup do
      {:ok, session} = Session.start_link(id: "compound_test_texpr_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "test expression success continues with &&", %{session: session} do
      result = run_script(session, "[[ -n foo ]] && echo not_empty")

      assert result.exit_code == 0
      assert get_stdout(result) == "not_empty\n"
    end

    test "test expression failure triggers ||", %{session: session} do
      result = run_script(session, "[[ -z foo ]] || echo has_content")

      assert result.exit_code == 0
      assert get_stdout(result) == "has_content\n"
    end
  end

  describe "execution with multiline" do
    setup do
      {:ok, session} = Session.start_link(id: "compound_test_multi_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "multiline && executes correctly", %{session: session} do
      result = run_script(session, "echo one &&\necho two")

      assert result.exit_code == 0
      assert get_stdout(result) == "one\ntwo\n"
    end
  end

  # ==========================================================================
  # Subshell Tests: ( commands )
  # ==========================================================================

  describe "subshell parsing" do
    test "parses simple subshell" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo hello)")

      assert %AST.Compound{kind: :subshell, statements: statements} = ast
      assert length(statements) == 1
      assert %AST.Command{} = hd(statements)
    end

    test "parses subshell with multiple commands" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo one; echo two)")

      assert %AST.Compound{kind: :subshell, statements: statements} = ast
      # Filter separators for assertion (they're preserved for formatting)
      executable_stmts = Enum.reject(statements, &match?({:separator, _}, &1))
      assert length(executable_stmts) == 2
    end

    test "parses subshell with variable assignment" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(FOO=bar)")

      assert %AST.Compound{kind: :subshell, statements: statements} = ast
      assert length(statements) == 1
      assert %AST.Assignment{} = hd(statements)
    end

    test "parses subshell in pipeline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo hello) | wc -c")

      assert %AST.Pipeline{commands: commands} = ast
      assert [%AST.Compound{kind: :subshell}, %AST.Command{}] = commands
    end

    test "parses nested subshells" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo outer; (echo inner))")

      assert %AST.Compound{kind: :subshell, statements: statements} = ast
      # Filter separators for assertion (they're preserved for formatting)
      executable_stmts = Enum.reject(statements, &match?({:separator, _}, &1))
      assert length(executable_stmts) == 2
      assert %AST.Command{} = Enum.at(executable_stmts, 0)
      assert %AST.Compound{kind: :subshell} = Enum.at(executable_stmts, 1)
    end
  end

  describe "subshell serialization" do
    test "serializes simple subshell" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo hello)")
      assert "(echo hello)" == to_string(ast)
    end

    test "serializes subshell with multiple commands" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo one; echo two)")
      assert "(echo one; echo two)" == to_string(ast)
    end

    test "serializes subshell in pipeline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("(echo hello) | wc -c")
      assert "(echo hello) | wc -c" == to_string(ast)
    end
  end

  describe "subshell execution" do
    setup do
      {:ok, session} = Session.start_link(id: "subshell_test_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "executes commands in subshell", %{session: session} do
      result = run_script(session, "(echo hello)")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "executes multiple commands in subshell", %{session: session} do
      result = run_script(session, "(echo one; echo two)")

      assert result.exit_code == 0
      assert get_stdout(result) == "one\ntwo\n"
    end

    test "subshell var changes do NOT affect parent", %{session: session} do
      result = run_script(session, "(TEST_VAR=child_value; echo $TEST_VAR)")

      # Subshell should see child_value
      assert result.exit_code == 0
      assert get_stdout(result) == "child_value\n"

      # Parent should not have the subshell variable
      assert Session.get_var(session, "TEST_VAR") == ""
    end

    test "subshell can read parent env", %{session: session} do
      # Set value in parent
      Session.set_env(session, "PARENT_VAR", "inherited")

      result = run_script(session, "(echo $PARENT_VAR)")

      assert result.exit_code == 0
      assert get_stdout(result) == "inherited\n"
    end

    test "subshell working directory changes do NOT affect parent", %{session: session} do
      # Remember parent's cwd
      parent_cwd = Session.get_cwd(session)

      result = run_script(session, "(cd /tmp; pwd)")

      # Subshell should see /tmp
      assert result.exit_code == 0
      stdout = get_stdout(result) |> String.trim()
      assert stdout == "/tmp" or String.contains?(stdout, "tmp")

      # Parent should still have original cwd
      assert Session.get_cwd(session) == parent_cwd
    end

    test "subshell returns last command's exit code", %{session: session} do
      result = run_script(session, "(true; false)")

      assert result.exit_code == 1
    end
  end

  # ==========================================================================
  # Command Group Tests: { commands; }
  # ==========================================================================

  describe "command group parsing" do
    test "parses simple command group" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ echo hello; }")

      assert %AST.Compound{kind: :group, statements: statements} = ast
      assert length(statements) == 1
      assert %AST.Command{} = hd(statements)
    end

    test "parses command group with multiple commands" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ echo one; echo two; }")

      assert %AST.Compound{kind: :group, statements: statements} = ast
      # Filter separators for assertion (they're preserved for formatting)
      executable_stmts = Enum.reject(statements, &match?({:separator, _}, &1))
      assert length(executable_stmts) == 2
    end

    test "parses command group with variable assignment" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ FOO=bar; }")

      assert %AST.Compound{kind: :group, statements: statements} = ast
      assert length(statements) == 1
      assert %AST.Assignment{} = hd(statements)
    end

    test "parses command group in pipeline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ echo hello; } | wc -c")

      assert %AST.Pipeline{commands: commands} = ast
      assert [%AST.Compound{kind: :group}, %AST.Command{}] = commands
    end
  end

  describe "command group serialization" do
    test "serializes simple command group" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ echo hello; }")
      assert "{ echo hello; }" == to_string(ast)
    end

    test "serializes command group with multiple commands" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ echo one; echo two; }")
      assert "{ echo one; echo two; }" == to_string(ast)
    end

    test "serializes command group in pipeline" do
      {:ok, %Script{statements: [ast]}} = Parser.parse("{ echo hello; } | wc -c")
      assert "{ echo hello; } | wc -c" == to_string(ast)
    end
  end

  describe "command group execution" do
    setup do
      {:ok, session} = Session.start_link(id: "group_test_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "executes commands in group", %{session: session} do
      result = run_script(session, "{ echo hello; }")

      assert result.exit_code == 0
      assert get_stdout(result) == "hello\n"
    end

    test "executes multiple commands in group", %{session: session} do
      result = run_script(session, "{ echo one; echo two; }")

      assert result.exit_code == 0
      assert get_stdout(result) == "one\ntwo\n"
    end

    test "group var changes DO affect parent", %{session: session} do
      result = run_script(session, "{ GROUP_VAR=modified; echo $GROUP_VAR; }")

      # Group should see modified
      assert result.exit_code == 0
      assert get_stdout(result) == "modified\n"

      # Parent should also have modified (groups persist changes)
      assert Session.get_var(session, "GROUP_VAR") == "modified"
    end

    test "group can set new vars in parent", %{session: session} do
      # Verify var doesn't exist
      assert Session.get_var(session, "NEW_GROUP_VAR") == ""

      # Set in group
      run_script(session, "{ NEW_GROUP_VAR=created; }")

      # Parent should have the new var
      assert Session.get_var(session, "NEW_GROUP_VAR") == "created"
    end

    test "group returns last command's exit code", %{session: session} do
      result = run_script(session, "{ true; false; }")

      assert result.exit_code == 1
    end
  end

  # ==========================================================================
  # Subshell vs Group Comparison Tests
  # ==========================================================================

  describe "subshell vs group isolation comparison" do
    setup do
      {:ok, session} = Session.start_link(id: "comparison_test_#{:erlang.unique_integer()}")
      {:ok, session: session}
    end

    test "subshell isolates vars, group does not", %{session: session} do
      # Test subshell - should NOT persist
      run_script(session, "(SUB_VAR=subshell)")
      assert Session.get_var(session, "SUB_VAR") == ""

      # Test group - should persist
      run_script(session, "{ GRP_VAR=group; }")
      assert Session.get_var(session, "GRP_VAR") == "group"
    end
  end
end
