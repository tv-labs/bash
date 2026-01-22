defmodule Bash.BraceExpansionTest do
  use ExUnit.Case, async: true

  alias Bash
  alias Bash.Session
  alias Bash.AST.BraceExpand

  describe "BraceExpand.expand/1 - list type" do
    test "expands simple comma list" do
      brace = %BraceExpand{
        type: :list,
        items: [[{:literal, "a"}], [{:literal, "b"}], [{:literal, "c"}]]
      }

      assert BraceExpand.expand(brace) == ["a", "b", "c"]
    end

    test "expands list with empty items" do
      # {a,} produces "a" and ""
      brace = %BraceExpand{
        type: :list,
        items: [[{:literal, "a"}], []]
      }

      assert BraceExpand.expand(brace) == ["a", ""]
    end

    test "expands nested brace expansions" do
      # {a,b{1,2}} produces a, b1, b2
      inner_brace = %BraceExpand{
        type: :list,
        items: [[{:literal, "1"}], [{:literal, "2"}]]
      }

      brace = %BraceExpand{
        type: :list,
        items: [
          [{:literal, "a"}],
          [{:literal, "b"}, {:brace_expand, inner_brace}]
        ]
      }

      assert BraceExpand.expand(brace) == ["a", "b1", "b2"]
    end
  end

  describe "BraceExpand.expand/1 - range type" do
    test "expands numeric range" do
      brace = %BraceExpand{
        type: :range,
        range_start: "1",
        range_end: "5"
      }

      assert BraceExpand.expand(brace) == ["1", "2", "3", "4", "5"]
    end

    test "expands descending numeric range" do
      brace = %BraceExpand{
        type: :range,
        range_start: "5",
        range_end: "1"
      }

      assert BraceExpand.expand(brace) == ["5", "4", "3", "2", "1"]
    end

    test "expands numeric range with step" do
      brace = %BraceExpand{
        type: :range,
        range_start: "1",
        range_end: "10",
        step: 2
      }

      assert BraceExpand.expand(brace) == ["1", "3", "5", "7", "9"]
    end

    test "expands zero-padded range" do
      brace = %BraceExpand{
        type: :range,
        range_start: "01",
        range_end: "05",
        zero_pad: 2
      }

      assert BraceExpand.expand(brace) == ["01", "02", "03", "04", "05"]
    end

    test "expands alpha range" do
      brace = %BraceExpand{
        type: :range,
        range_start: "a",
        range_end: "e"
      }

      assert BraceExpand.expand(brace) == ["a", "b", "c", "d", "e"]
    end

    test "expands descending alpha range" do
      brace = %BraceExpand{
        type: :range,
        range_start: "e",
        range_end: "a"
      }

      assert BraceExpand.expand(brace) == ["e", "d", "c", "b", "a"]
    end

    test "expands alpha range with step" do
      brace = %BraceExpand{
        type: :range,
        range_start: "a",
        range_end: "z",
        step: 5
      }

      assert BraceExpand.expand(brace) == ["a", "f", "k", "p", "u", "z"]
    end

    test "invalid range returns literal" do
      # Mixed types like {1..z} return as literal
      brace = %BraceExpand{
        type: :range,
        range_start: "1",
        range_end: "z"
      }

      assert BraceExpand.expand(brace) == ["{1..z}"]
    end
  end

  describe "integration - echo with brace expansion" do
    setup do
      {:ok, session} = Session.new(id: "brace_test_#{:erlang.unique_integer()}")
      %{session: session}
    end

    test "expands {a,b,c} in echo command", %{session: session} do
      {:ok, result, _} = Bash.run("echo {a,b,c}", session)
      assert Bash.stdout(result) == "a b c\n"
    end

    test "expands numeric range in echo command", %{session: session} do
      {:ok, result, _} = Bash.run("echo {1..5}", session)
      assert Bash.stdout(result) == "1 2 3 4 5\n"
    end

    test "expands prefix/suffix pattern", %{session: session} do
      {:ok, result, _} = Bash.run("echo file{1,2,3}.txt", session)
      assert Bash.stdout(result) == "file1.txt file2.txt file3.txt\n"
    end

    test "expands multiple braces with cartesian product", %{session: session} do
      {:ok, result, _} = Bash.run("echo {a,b}{1,2}", session)
      assert Bash.stdout(result) == "a1 a2 b1 b2\n"
    end

    test "does not expand braces in double quotes", %{session: session} do
      {:ok, result, _} = Bash.run(~s|echo "{a,b,c}"|, session)
      assert Bash.stdout(result) == "{a,b,c}\n"
    end

    test "does not expand braces in single quotes", %{session: session} do
      {:ok, result, _} = Bash.run("echo '{a,b,c}'", session)
      assert Bash.stdout(result) == "{a,b,c}\n"
    end

    test "expands zero-padded range", %{session: session} do
      {:ok, result, _} = Bash.run("echo {01..03}", session)
      assert Bash.stdout(result) == "01 02 03\n"
    end

    test "expands alpha range", %{session: session} do
      {:ok, result, _} = Bash.run("echo {a..e}", session)
      assert Bash.stdout(result) == "a b c d e\n"
    end

    test "expands range with step", %{session: session} do
      {:ok, result, _} = Bash.run("echo {1..10..2}", session)
      assert Bash.stdout(result) == "1 3 5 7 9\n"
    end

    test "treats invalid patterns as literal", %{session: session} do
      # Single item - no expansion
      {:ok, result, _} = Bash.run("echo {a}", session)
      assert Bash.stdout(result) == "{a}\n"
    end

    test "nested brace expansion", %{session: session} do
      {:ok, result, _} = Bash.run("echo {a,b{1,2}}", session)
      assert Bash.stdout(result) == "a b1 b2\n"
    end

    test "empty item in list produces empty string", %{session: session} do
      {:ok, result, _} = Bash.run("echo x{,y}", session)
      assert Bash.stdout(result) == "x xy\n"
    end
  end
end
