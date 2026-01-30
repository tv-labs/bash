defmodule Bash.ASTTest do
  use ExUnit.Case, async: true

  import Bash.AST, only: [command_name: 1, is_command: 2, is_assignment: 2, assignment_name: 1]
  import Bash.Sigil

  alias Bash.AST
  alias Bash.AST.Command
  alias Bash.AST.Pipeline
  alias Bash.AST.Compound
  alias Bash.AST.If
  alias Bash.AST.WhileLoop
  alias Bash.AST.ForLoop
  alias Bash.AST.Case
  alias Bash.AST.Coproc
  alias Bash.AST.Word
  alias Bash.AST.Function
  alias Bash.Script

  describe "prewalk/2" do
    test "removes commands by returning nil" do
      script = %Script{
        statements: [cmd("echo", ["hello"]), cmd("rm", ["-rf", "/"]), cmd("ls")]
      }

      result =
        AST.prewalk(script, fn
          %Command{} = c ->
            if command_name(c) == "rm", do: nil, else: c

          node ->
            node
        end)

      names = Enum.map(result.statements, &command_name/1)
      assert names == ["echo", "ls"]
    end

    test "transforms commands top-down" do
      script = %Script{statements: [cmd("foo"), cmd("bar")]}

      result =
        AST.prewalk(script, fn
          %Command{} = c ->
            if command_name(c) == "foo" do
              %{c | name: word("replaced")}
            else
              c
            end

          node ->
            node
        end)

      names = Enum.map(result.statements, &command_name/1)
      assert names == ["replaced", "bar"]
    end
  end

  describe "postwalk/2" do
    test "renames commands bottom-up" do
      pipeline = %Pipeline{
        commands: [cmd("grep"), cmd("sort"), cmd("uniq")]
      }

      result =
        AST.postwalk(pipeline, fn
          %Command{} = c ->
            %{c | name: word(command_name(c) <> "_v2")}

          node ->
            node
        end)

      names = Enum.map(result.commands, &command_name/1)
      assert names == ["grep_v2", "sort_v2", "uniq_v2"]
    end
  end

  describe "reduce/3" do
    test "collects all command names" do
      script = %Script{
        statements: [
          cmd("echo"),
          %Pipeline{commands: [cmd("cat"), cmd("grep")]},
          cmd("ls")
        ]
      }

      names =
        AST.reduce(script, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert Enum.sort(names) == ["cat", "echo", "grep", "ls"]
    end
  end

  describe "walk_tree/4" do
    test "counts all nodes with accumulator" do
      script = %Script{
        statements: [cmd("a"), cmd("b"), cmd("c")]
      }

      {_node, count} =
        AST.walk_tree(script, 0, fn node, acc -> {node, acc + 1} end, fn node, acc ->
          {node, acc}
        end)

      # 1 Script + 3 Commands = 4
      assert count == 4
    end
  end

  describe "nested structures" do
    test "walks if inside while inside pipeline" do
      inner_if = %If{
        condition: cmd("test"),
        body: [cmd("inner")],
        elif_clauses: [],
        else_body: nil
      }

      while_loop = %WhileLoop{
        condition: cmd("true"),
        body: [inner_if]
      }

      script = %Script{statements: [while_loop]}

      names =
        AST.reduce(script, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert Enum.sort(names) == ["inner", "test", "true"]
    end

    test "walks if with elif and else" do
      if_node = %If{
        condition: cmd("cond1"),
        body: [cmd("body1")],
        elif_clauses: [{cmd("cond2"), [cmd("body2")]}],
        else_body: [cmd("else_body")]
      }

      names =
        AST.reduce(if_node, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert Enum.sort(names) == ["body1", "body2", "cond1", "cond2", "else_body"]
    end

    test "walks for loop body" do
      for_loop = %ForLoop{
        variable: "i",
        items: [word("1"), word("2")],
        body: [cmd("echo"), cmd("ls")]
      }

      names =
        AST.reduce(for_loop, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert Enum.sort(names) == ["echo", "ls"]
    end

    test "walks case clause bodies" do
      case_node = %Case{
        word: word("x"),
        cases: [
          {[word("a")], [cmd("echo"), cmd("ls")], :break},
          {[word("b")], [cmd("rm")], :break}
        ]
      }

      names =
        AST.reduce(case_node, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert Enum.sort(names) == ["echo", "ls", "rm"]
    end

    test "walks compound preserving operators" do
      compound = %Compound{
        kind: :operand,
        statements: [cmd("a"), {:operator, :and}, cmd("b"), {:operator, :or}, cmd("c")]
      }

      # Replacement without removal — rename b to b2
      result =
        AST.prewalk(compound, fn
          %Command{} = c ->
            if command_name(c) == "b", do: %{c | name: word("b2")}, else: c

          node ->
            node
        end)

      names = result.statements |> Enum.filter(&is_struct/1) |> Enum.map(&command_name/1)
      assert names == ["a", "b2", "c"]

      # Operators preserved
      operators = Enum.filter(result.statements, &match?({:operator, _}, &1))
      assert operators == [{:operator, :and}, {:operator, :or}]
    end

    test "walks compound with node removal" do
      compound = %Compound{
        kind: :operand,
        statements: [cmd("a"), {:operator, :and}, cmd("b"), {:operator, :or}, cmd("c")]
      }

      result =
        AST.prewalk(compound, fn
          %Command{} = c ->
            if command_name(c) == "b", do: nil, else: c

          node ->
            node
        end)

      # With positional replacement, removing middle node shifts remaining children
      struct_names = result.statements |> Enum.filter(&is_struct/1) |> Enum.map(&command_name/1)
      assert struct_names == ["a", "c"]
    end

    test "walks coproc body" do
      coproc = %Coproc{body: cmd("sleep")}

      names =
        AST.reduce(coproc, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert names == ["sleep"]
    end

    test "walks function body" do
      func = %Function{name: "myfn", body: %Compound{kind: :group, statements: [cmd("echo")]}}

      names =
        AST.reduce(func, [], fn
          %Command{} = c, acc -> [command_name(c) | acc]
          _node, acc -> acc
        end)

      assert names == ["echo"]
    end
  end

  describe "leaf nodes" do
    test "leaf nodes pass through unchanged" do
      command = cmd("echo", ["hello"])

      result = AST.prewalk(command, fn node -> node end)
      assert result == command

      result = AST.postwalk(command, fn node -> node end)
      assert result == command
    end
  end

  describe "parsed scripts" do
    defp collect_commands(script) do
      AST.reduce(script, [], fn
        %Command{name: %Word{parts: [{:literal, name}]}}, acc -> [name | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()
    end

    defp collect_node_types(script) do
      AST.reduce(script, [], fn node, acc -> [node.__struct__ | acc] end)
      |> Enum.reverse()
    end

    defp count_struct_type(script, type) do
      AST.reduce(script, 0, fn
        %{__struct__: ^type}, acc -> acc + 1
        _, acc -> acc
      end)
    end

    test "simple sequential commands" do
      script = ~BASH"""
      echo hello
      ls -la
      pwd
      """

      assert collect_commands(script) == ["echo", "ls", "pwd"]
    end

    test "pipeline" do
      script = ~BASH"cat file.txt | grep pattern | sort | uniq -c"

      commands = collect_commands(script)
      assert commands == ["cat", "grep", "sort", "uniq"]
    end

    test "if/elif/else" do
      script = ~BASH"""
      if test -f foo; then
        echo found_foo
      elif test -f bar; then
        echo found_bar
      else
        echo not_found
      fi
      """

      commands = collect_commands(script)
      assert "test" in commands
      assert "echo" in commands
    end

    test "for loop" do
      script = ~BASH"""
      for i in 1 2 3; do
        echo $i
        touch file_$i
      done
      """

      commands = collect_commands(script)
      assert "echo" in commands
      assert "touch" in commands
    end

    test "while loop" do
      script = ~BASH"""
      while true; do
        echo looping
        sleep 1
      done
      """

      commands = collect_commands(script)
      assert "true" in commands
      assert "echo" in commands
      assert "sleep" in commands
    end

    test "case statement" do
      script = ~BASH"""
      case $x in
        a) echo alpha ;;
        b) echo bravo ;;
        *) echo unknown ;;
      esac
      """

      commands = collect_commands(script)
      assert length(Enum.filter(commands, &(&1 == "echo"))) == 3
    end

    test "function definition" do
      script = ~BASH"""
      greet() {
        echo hello
        echo world
      }
      """

      commands = collect_commands(script)
      assert "echo" in commands
    end

    test "subshell and group" do
      script = ~BASH"(echo sub1; echo sub2)"

      commands = collect_commands(script)
      assert commands == ["echo", "echo"]
    end

    test "logical operators" do
      script = ~BASH"mkdir -p dir && cd dir || echo failed"

      commands = collect_commands(script)
      assert "mkdir" in commands
      assert "cd" in commands
      assert "echo" in commands
    end

    test "nested control flow" do
      script = ~BASH"""
      for f in a b c; do
        if test -f $f; then
          cat $f | grep pattern
        else
          echo missing
        fi
      done
      """

      commands = collect_commands(script)
      assert "test" in commands
      assert "cat" in commands
      assert "grep" in commands
      assert "echo" in commands
    end

    test "reduce counts node types" do
      script = ~BASH"""
      echo hello
      if true; then
        ls
      fi
      for i in 1 2; do
        pwd
      done
      """

      assert count_struct_type(script, Script) == 1
      assert count_struct_type(script, Command) >= 3
      assert count_struct_type(script, If) == 1
      assert count_struct_type(script, ForLoop) == 1
    end

    test "prewalk removes dangerous commands from parsed script" do
      script = ~BASH"""
      echo safe
      rm -rf /
      ls -la
      """

      result =
        AST.prewalk(script, fn
          %Command{name: %Word{parts: [{:literal, "rm"}]}} -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert "rm" not in commands
      assert "echo" in commands
      assert "ls" in commands
    end

    test "postwalk adds prefix to all commands in parsed script" do
      script = ~BASH"""
      echo hello
      ls
      pwd
      """

      result =
        AST.postwalk(script, fn
          %Command{name: %Word{parts: [{:literal, name}]}} = c ->
            %{c | name: %Word{parts: [{:literal, "safe_" <> name}]}}

          node ->
            node
        end)

      commands = collect_commands(result)
      assert commands == ["safe_echo", "safe_ls", "safe_pwd"]
    end

    test "walk_tree accumulates depth information" do
      script = ~BASH"""
      if true; then
        while false; do
          echo deep
        done
      fi
      """

      {_node, max_depth} =
        AST.walk_tree(
          script,
          {0, 0},
          fn node, {depth, max} ->
            new_depth = depth + 1
            {node, {new_depth, max(new_depth, max)}}
          end,
          fn node, {depth, max} ->
            {node, {depth - 1, max}}
          end
        )

      {_, max} = max_depth
      # Script > If > WhileLoop > Command = depth 4
      assert max >= 4
    end

    test "prewalk replaces pipeline commands" do
      script = ~BASH"cat file | grep err | wc -l"

      result =
        AST.prewalk(script, fn
          %Command{name: %Word{parts: [{:literal, "grep"}]}} = c ->
            %{c | name: %Word{parts: [{:literal, "rg"}]}}

          node ->
            node
        end)

      commands = collect_commands(result)
      assert commands == ["cat", "rg", "wc"]
    end

    test "identity walk preserves parsed script structure" do
      script = ~BASH"""
      for i in 1 2 3; do
        if test $i; then
          echo $i | cat
        fi
      done
      """

      result = AST.prewalk(script, fn node -> node end)
      assert result == script

      result = AST.postwalk(script, fn node -> node end)
      assert result == script
    end

    test "remove commands from inside case clauses" do
      script = ~BASH"""
      case $x in
        a) echo alpha; rm temp ;;
        b) echo bravo ;;
      esac
      """

      result =
        AST.prewalk(script, fn
          %Command{name: %Word{parts: [{:literal, "rm"}]}} -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert "rm" not in commands
      assert "echo" in commands
    end

    test "remove commands from for loop body" do
      script = ~BASH"""
      for f in a b c; do
        echo $f
        rm $f
        ls
      done
      """

      result =
        AST.prewalk(script, fn
          %Command{name: %Word{parts: [{:literal, "rm"}]}} -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert commands == ["echo", "ls"]
    end

    test "reduce collects unique command names from complex script" do
      script = ~BASH"""
      echo start
      for i in 1 2; do
        echo $i
        if test -f $i; then
          cat $i | sort | uniq
        else
          touch $i
        fi
      done
      echo done
      """

      unique_commands =
        AST.reduce(script, MapSet.new(), fn
          %Command{name: %Word{parts: [{:literal, name}]}}, acc -> MapSet.put(acc, name)
          _, acc -> acc
        end)

      assert MapSet.equal?(
               unique_commands,
               MapSet.new(["echo", "test", "cat", "sort", "uniq", "touch"])
             )
    end

    test "walk_tree collects commands with their nesting depth" do
      script = ~BASH"""
      echo top
      if true; then
        echo nested
        for i in 1; do
          echo deep
        done
      fi
      """

      {_node, {_, collected}} =
        AST.walk_tree(
          script,
          {0, []},
          fn node, {depth, acc} ->
            acc =
              case node do
                %Command{args: [%Word{parts: [{:literal, label}]}]} ->
                  [{label, depth} | acc]

                _ ->
                  acc
              end

            {node, {depth + 1, acc}}
          end,
          fn node, {depth, acc} ->
            {node, {depth - 1, acc}}
          end
        )

      depth_of = Map.new(collected)

      assert depth_of["top"] < depth_of["nested"]
      assert depth_of["nested"] < depth_of["deep"]
    end

    test "postwalk can wrap commands in pipeline" do
      script = ~BASH"echo hello | grep h"

      result =
        AST.postwalk(script, fn
          %Pipeline{} = p ->
            %{p | negate: true}

          node ->
            node
        end)

      [%Pipeline{negate: true}] = result.statements
    end

    test "prewalk removes entire if block" do
      script = ~BASH"""
      echo before
      if true; then echo inside; fi
      echo after
      """

      result =
        AST.prewalk(script, fn
          %If{} -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert commands == ["echo", "echo"]
    end

    test "prewalk removes entire while loop" do
      script = ~BASH"""
      echo before
      while true; do echo looping; done
      echo after
      """

      result =
        AST.prewalk(script, fn
          %WhileLoop{} -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert commands == ["echo", "echo"]
    end

    test "assignments are leaf nodes" do
      script = ~BASH"""
      X=1
      echo $X
      # comments
      Y=2
      """

      types = collect_node_types(script)
      assert Bash.AST.Assignment in types
      assert Command in types

      # Identity walk preserves assignments and comments
      result = AST.prewalk(script, fn node -> node end)
      assert result == script
    end
  end

  describe "guards" do
    test "command_name/1 in walker" do
      script = ~BASH"""
      echo hello
      rm -rf /
      ls -la
      """

      result =
        AST.prewalk(script, fn
          node when command_name(node) == "rm" -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert "rm" not in commands
      assert commands == ["echo", "ls"]
    end

    test "is_command/2 in walker" do
      script = ~BASH"echo safe; rm danger; ls files"

      result =
        AST.prewalk(script, fn
          node when is_command(node, "rm") -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert commands == ["echo", "ls"]
    end

    test "is_command/2 does not match non-command nodes" do
      script = ~BASH"""
      X=1
      echo hello
      """

      count =
        AST.reduce(script, 0, fn
          node, _acc when is_command(node, "echo") -> 1
          _, acc -> acc
        end)

      assert count == 1
    end

    test "command_name/1 in reduce" do
      script = ~BASH"cat file | grep pattern | sort"

      names =
        AST.reduce(script, [], fn
          node, acc when is_struct(node, Command) -> [command_name(node) | acc]
          _, acc -> acc
        end)

      assert Enum.sort(names) == ["cat", "grep", "sort"]
    end

    test "assignment_name/1 in walker" do
      script = ~BASH"""
      PATH=/usr/bin
      HOME=/root
      echo hello
      """

      names =
        AST.reduce(script, [], fn
          node, acc when is_assignment(node, "PATH") -> ["PATH" | acc]
          node, acc when is_struct(node, Bash.AST.Assignment) -> [assignment_name(node) | acc]
          _, acc -> acc
        end)

      assert "PATH" in names
      assert "HOME" in names
    end

    test "is_assignment/2 filters specific assignments" do
      script = ~BASH"""
      X=1
      Y=2
      Z=3
      """

      result =
        AST.prewalk(script, fn
          node when is_assignment(node, "Y") -> nil
          node -> node
        end)

      names =
        AST.reduce(result, [], fn
          node, acc when is_struct(node, Bash.AST.Assignment) -> [assignment_name(node) | acc]
          _, acc -> acc
        end)

      assert Enum.sort(names) == ["X", "Z"]
    end

    test "guards compose in complex walkers" do
      script = ~BASH"""
      echo start
      rm -rf /tmp
      X=secret
      ls -la
      echo end
      """

      result =
        AST.prewalk(script, fn
          node when is_command(node, "rm") -> nil
          node when is_assignment(node, "X") -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert commands == ["echo", "ls", "echo"]

      assignments =
        AST.reduce(result, [], fn
          node, acc when is_struct(node, Bash.AST.Assignment) -> [assignment_name(node) | acc]
          _, acc -> acc
        end)

      assert assignments == []
    end

    test "is_command/2 works in nested structures" do
      script = ~BASH"""
      if true; then
        rm file
        echo kept
      fi
      """

      result =
        AST.prewalk(script, fn
          node when is_command(node, "rm") -> nil
          node -> node
        end)

      commands = collect_commands(result)
      assert "rm" not in commands
      assert "echo" in commands
    end
  end

  defp word(text), do: %Word{parts: [{:literal, text}]}
  defp cmd(name), do: %Command{name: word(name), args: []}
  defp cmd(name, args), do: %Command{name: word(name), args: Enum.map(args, &word/1)}
end
