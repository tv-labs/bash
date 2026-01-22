defmodule Bash.ForLoopTest do
  use Bash.SessionCase, async: true

  import Bash.Sigil

  alias Bash
  alias Bash.AST.ForLoop
  alias Bash.Script
  alias Bash.Session

  setup :start_session

  describe "ForLoop parsing" do
    test "parses simple for loop with literal items" do
      assert %Script{
               statements: [
                 %ForLoop{
                   variable: "x",
                   body: [_],
                   items: [_, _, _]
                 }
               ]
             } = ~BASH"for x in one two three; do echo $x; done"
    end

    test "parses for loop with command substitution" do
      assert %Script{
               statements: [
                 %ForLoop{
                   variable: "file",
                   body: [_],
                   items: [
                     %Bash.AST.Word{
                       parts: [{:command_subst, %Bash.AST.Command{}}]
                     }
                   ]
                 }
               ]
             } = ~BASH"for file in $(echo a b c); do echo $file; done"
    end

    test "roundtrip: parse and serialize" do
      original = """
      for item in one two three; do
        echo $item
      done
      """

      {:ok, %Script{statements: [ast]}} = Bash.Parser.parse(original)
      serialized = to_string(ast)

      # Should contain the key parts
      assert serialized =~ "for item in"
      assert serialized =~ "one two three"
      assert serialized =~ "do"
      assert serialized =~ "echo"
      assert serialized =~ "done"
    end
  end

  describe "ForLoop execution with literals" do
    test "executes simple for loop", %{session: session} do
      # Set up a counter variable
      Session.set_env(session, "count", "0")

      %Script{statements: [script]} = ~BASH"""
      for x in one two three; do
        echo $x
      done
      """

      {:ok, result, ^session} = Bash.run(script, session)
      assert result.exit_code == 0
      assert Session.get_var(session, "x") == "three"
    end

    test "loop variable is accessible in body", %{session: session} do
      result =
        run_script(session, """
        for num in 1 2 3; do
          echo "num=$num"
        done
        """)

      # Loop variable should be set to last value
      assert Session.get_var(session, "num") == "3"
      assert result.exit_code == 0

      assert get_stdout(result) == "num=1\nnum=2\nnum=3\n"
    end

    test "modifies variable in loop body", %{session: session} do
      Session.set_env(session, "count", "0")

      %Script{statements: [script]} = ~BASH"""
      for x in a b c; do
         count=$x
      done
      """

      {:ok, result, ^session} = Bash.run(script, session)
      assert result.exit_code == 0
      assert Session.get_var(session, "count") == "c"
    end
  end

  describe "ForLoop execution with command substitution" do
    @tag :tmp_dir
    test "iterates over files from command substitution", %{session: session, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.md"), "content a")
      File.write!(Path.join(tmp_dir, "b.md"), "content b")
      File.write!(Path.join(tmp_dir, "c.md"), "content c")

      Session.chdir(session, tmp_dir)
      Session.set_env(session, "count", "0")

      result =
        run_script(session, """
        for file in $(ls *.md); do
          echo $file
        done
        """)

      assert result.exit_code == 0
      assert Session.get_var(session, "file") in ~w[a.md b.md c.md]
      # Check that all three files are echoed
      stdout = get_stdout(result)

      for filename <- ~w[a.md b.md c.md] do
        assert String.contains?(stdout, "#{filename}\n")
      end
    end

    test "command substitution splits on whitespace", %{session: session} do
      result =
        run_script(session, """
        for item in $(echo "one   two   three"); do
          echo $item
        done
        """)

      assert get_stdout(result) == "one\ntwo\nthree\n"

      assert Session.get_var(session, "item") == "three"
    end

    test "nested command substitution in variable", %{session: session} do
      Session.set_env(session, "result", "")

      %Script{statements: [ast]} = ~BASH"""
      for x in $(echo a b c); do
        result=$x
      done
      """

      {:ok, _result, ^session} = Bash.run(ast, session)
      assert Session.get_var(session, "result") == "c"
    end
  end

  describe "ForLoop variable scope" do
    test "loop variable persists after loop", %{session: session} do
      %Script{statements: [script]} = ~BASH"""
      for x in alpha beta gamma; do
        echo $x
      done
      """

      {:ok, _result, ^session} = Bash.run(script, session)
      assert Session.get_var(session, "x") == "gamma"
    end

    test "modifications in loop body persist", %{session: session} do
      %Script{statements: [script]} = ~BASH"""
      for x in 1 2 3; do
        total=${total}$x
      done
      """

      {:ok, _result, ^session} = Bash.run(script, session)
      assert Session.get_var(session, "total") == "123"
      assert Session.get_var(session, "x") == "3"
    end
  end
end
