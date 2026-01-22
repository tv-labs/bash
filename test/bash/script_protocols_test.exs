defmodule Bash.ScriptProtocolsTest do
  use ExUnit.Case, async: true

  alias Bash.AST
  alias Bash.Script
  alias Bash.Parser

  describe "Enumerable for Script" do
    test "counts executable statements" do
      {:ok, %Script{} = script} = Parser.parse("x=1; y=2; echo hello")

      # Should count 3 statements (assignment, assignment, command)
      # but not the separators
      assert Enum.count(script) == 3
    end

    test "iterates over executable statements only" do
      {:ok, %Script{} = script} = Parser.parse("x=1; y=2; echo hello")

      statements = Enum.to_list(script)
      assert length(statements) == 3

      # Should not include separators
      refute Enum.any?(statements, fn
               {:separator, _} -> true
               _ -> false
             end)
    end

    test "filters comments and separators" do
      script_text = """
      # This is a comment
      x=1
      y=2
      # Another comment
      echo hello
      """

      {:ok, %Script{} = script} = Parser.parse(script_text)

      # Should only enumerate non-comment, non-separator statements
      statements = Enum.to_list(script)
      assert length(statements) == 3

      # None should be comments
      refute Enum.any?(statements, fn
               %AST.Comment{} -> true
               _ -> false
             end)
    end

    test "maps over statements" do
      {:ok, %Script{} = script} = Parser.parse("echo a; echo b; echo c")

      # Extract command names
      names =
        Enum.map(script, fn
          %AST.Command{name: %AST.Word{parts: [{:literal, name}]}} -> name
          _ -> nil
        end)

      assert names == ["echo", "echo", "echo"]
    end

    test "filters statements by type" do
      {:ok, %Script{} = script} = Parser.parse("x=1; echo hello; y=2; echo world")

      # Filter only commands
      commands =
        Enum.filter(script, fn
          %AST.Command{} -> true
          _ -> false
        end)

      assert length(commands) == 2

      # Filter only assignments
      assignments =
        Enum.filter(script, fn
          %AST.Assignment{} -> true
          _ -> false
        end)

      assert length(assignments) == 2
    end

    test "reduces over statements" do
      {:ok, %Script{} = script} = Parser.parse("echo a; echo b; echo c")

      # Count commands
      count =
        Enum.reduce(script, 0, fn
          %AST.Command{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert count == 3
    end

    test "works with Enum.find" do
      {:ok, %Script{} = script} = Parser.parse("x=1; y=2; echo hello")

      # Find first command
      command =
        Enum.find(script, fn
          %AST.Command{} -> true
          _ -> false
        end)

      assert %AST.Command{} = command
    end

    test "works with Enum.any? and Enum.all?" do
      {:ok, %Script{} = script} = Parser.parse("echo a; echo b; echo c")

      # All are commands
      assert Enum.all?(script, fn
               %AST.Command{} -> true
               _ -> false
             end)

      {:ok, %Script{} = mixed_script} = Parser.parse("x=1; echo hello")

      # Not all are commands
      refute Enum.all?(mixed_script, fn
               %AST.Command{} -> true
               _ -> false
             end)

      # But there is at least one command
      assert Enum.any?(mixed_script, fn
               %AST.Command{} -> true
               _ -> false
             end)
    end
  end

  describe "Collectable for Script" do
    test "builds script from list of statements" do
      {:ok, %Script{} = parsed} = Parser.parse("echo a; echo b")
      # Enum.to_list filters out separators (Enumerable implementation)
      statements = Enum.to_list(parsed)

      # Collect back into a script
      assert %Script{} = collected = Enum.into(statements, %Script{})

      # 2 commands + 1 separator between them (auto-added)
      assert length(collected.statements) == 3
    end

    test "builds script with for comprehension" do
      {:ok, %Script{} = parsed} = Parser.parse("echo a; echo b; echo c")

      # Filter only commands and collect
      script =
        for statement <- parsed,
            match?(%AST.Command{}, statement),
            into: %Script{} do
          statement
        end

      assert %Script{} = script
      # Should have 3 commands with 2 separators between them
      assert Enum.count(script) == 3
    end

    test "automatically adds separators between statements" do
      cmd1 = %AST.Command{
        meta: %AST.Meta{},
        name: %AST.Word{meta: %AST.Meta{}, parts: [{:literal, "echo"}]},
        args: []
      }

      cmd2 = %AST.Command{
        meta: %AST.Meta{},
        name: %AST.Word{meta: %AST.Meta{}, parts: [{:literal, "echo"}]},
        args: []
      }

      script = Enum.into([cmd1, cmd2], %Script{})

      assert %Script{statements: statements} = script
      # Should have: cmd1, separator, cmd2
      assert length(statements) == 3
      assert match?([%AST.Command{}, {:separator, "\n"}, %AST.Command{}], statements)
    end

    test "preserves explicit separators" do
      cmd1 = %AST.Command{
        meta: %AST.Meta{},
        name: %AST.Word{meta: %AST.Meta{}, parts: [{:literal, "echo"}]},
        args: []
      }

      items = [cmd1, {:separator, ";"}, cmd1]

      script = Enum.into(items, %Script{meta: %AST.Meta{}})

      assert %Script{statements: statements} = script
      # Should have: cmd1, sep(;), cmd2
      assert length(statements) == 3
      assert match?([%AST.Command{}, {:separator, ";"}, %AST.Command{}], statements)
    end

    test "works with Enum.into and transformations" do
      {:ok, %Script{} = parsed} = Parser.parse("echo a; echo b; echo c; x=1")

      # Filter only commands and build a new script
      commands_only =
        parsed
        |> Enum.filter(fn
          %AST.Command{} -> true
          _ -> false
        end)
        |> Enum.into(%Script{meta: %AST.Meta{}})

      # Should only have commands, no assignments
      assert Enum.count(commands_only) == 3
      assert Enum.all?(commands_only, &match?(%AST.Command{}, &1))
    end
  end

  describe "Inspect for Script" do
    test "shows tree structure with node count" do
      {:ok, script} = Parser.parse("echo hello; echo world")

      inspected = inspect(script)

      assert inspected =~ "#Script(2 nodes)"
      assert inspected =~ "├── [command] echo"
      assert inspected =~ "└── [command] echo"
    end

    test "shows exit code after execution" do
      {:ok, script} = Parser.parse("echo hello")
      alias Bash.Session

      {:ok, session} = Session.new()
      {:ok, executed} = Session.execute(session, script)

      inspected = inspect(executed)

      assert inspected =~ "#Script(1 nodes) => 0"
      assert inspected =~ "[command] echo => 0"
    end

    test "truncates at 10 elements" do
      script_text = Enum.map_join(1..15, "\n", fn i -> "echo #{i}" end)
      {:ok, script} = Parser.parse(script_text)

      inspected = inspect(script)

      assert inspected =~ "#Script(15 nodes)"
      assert inspected =~ "...and 5 more"
      # Should show first 10
      refute inspected =~ "echo 11"
    end

    test "shows various node types" do
      {:ok, script} =
        Parser.parse("""
        x=1
        echo hello | grep h
        for i in 1 2 3; do echo $i; done
        if true; then echo yes; fi
        """)

      inspected = inspect(script)

      assert inspected =~ "[assignment]"
      assert inspected =~ "[pipeline]"
      assert inspected =~ "[for]"
      assert inspected =~ "[if]"
    end

    test "shows empty script" do
      script = %Script{meta: %AST.Meta{}, statements: []}

      inspected = inspect(script)

      assert inspected =~ "#Script(0 nodes)"
      # No tree for empty
      refute inspected =~ "<"
    end
  end

  describe "Enumerable and Collectable together" do
    test "can transform scripts using Enum pipeline" do
      {:ok, %Script{} = script} = Parser.parse("echo a; x=1; echo b; y=2; echo c")

      # Extract only commands, transform, and build new script
      new_script =
        script
        |> Enum.filter(&match?(%AST.Command{}, &1))
        |> Enum.into(%Script{meta: %AST.Meta{}})

      # Should have 3 commands
      assert Enum.count(new_script) == 3
      assert Enum.all?(new_script, &match?(%AST.Command{}, &1))
    end

    test "can combine statements from multiple scripts" do
      {:ok, %Script{} = script1} = Parser.parse("echo a; echo b")
      {:ok, %Script{} = script2} = Parser.parse("echo c; echo d")

      # Combine statements from both scripts
      combined =
        [script1, script2]
        |> Enum.flat_map(&Enum.to_list/1)
        |> Enum.into(%Script{meta: %AST.Meta{}})

      assert Enum.count(combined) == 4
    end

    test "serializes correctly after collect" do
      {:ok, %Script{} = script} = Parser.parse("echo hello\necho world")

      # Extract statements and rebuild
      rebuilt =
        script
        |> Enum.to_list()
        |> Enum.into(%Script{meta: %AST.Meta{}})

      # Should serialize back to something reasonable
      serialized = to_string(rebuilt)
      assert serialized =~ "echo hello"
      assert serialized =~ "echo world"
    end
  end
end
