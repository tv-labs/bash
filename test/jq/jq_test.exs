defmodule JQ.JQTest do
  use ExUnit.Case, async: true

  describe "identity" do
    test "passes through any value" do
      assert JQ.run!(".", 42) == [42]
      assert JQ.run!(".", "hello") == ["hello"]
      assert JQ.run!(".", nil) == [nil]
      assert JQ.run!(".", true) == [true]
      assert JQ.run!(".", [1, 2]) == [[1, 2]]
      assert JQ.run!(".", %{"a" => 1}) == [%{"a" => 1}]
    end
  end

  describe "type" do
    test "returns type name for each type" do
      assert JQ.run!("type", nil) == ["null"]
      assert JQ.run!("type", true) == ["boolean"]
      assert JQ.run!("type", false) == ["boolean"]
      assert JQ.run!("type", 42) == ["number"]
      assert JQ.run!("type", 3.14) == ["number"]
      assert JQ.run!("type", "hello") == ["string"]
      assert JQ.run!("type", [1, 2]) == ["array"]
      assert JQ.run!("type", %{"a" => 1}) == ["object"]
    end
  end

  describe "length" do
    test "null length is 0" do
      assert JQ.run!("length", nil) == [0]
    end

    test "boolean length" do
      assert JQ.run!("length", false) == [0]
      assert JQ.run!("length", true) == [1]
    end

    test "number length is absolute value" do
      assert JQ.run!("length", 42) == [42]
      assert JQ.run!("length", -5) == [5]
      assert JQ.run!("length", 3.14) == [3.14]
    end

    test "string length is codepoint count" do
      assert JQ.run!("length", "hello") == [5]
      assert JQ.run!("length", "") == [0]
    end

    test "array length is element count" do
      assert JQ.run!("length", [1, 2, 3]) == [3]
      assert JQ.run!("length", []) == [0]
    end

    test "object length is key count" do
      assert JQ.run!("length", %{"a" => 1, "b" => 2}) == [2]
      assert JQ.run!("length", %{}) == [0]
    end
  end

  describe "field access" do
    test ".field on object" do
      assert JQ.run!(".name", %{"name" => "Alice"}) == ["Alice"]
    end

    test ".field on null returns null" do
      assert JQ.run!(".name", nil) == [nil]
    end

    test "nested field access" do
      input = %{"a" => %{"b" => 42}}
      assert JQ.run!(".a.b", input) == [42]
    end

    test "missing field returns null" do
      assert JQ.run!(".missing", %{"a" => 1}) == [nil]
    end
  end

  describe "array index" do
    test "positive index" do
      assert JQ.run!(".[0]", [10, 20, 30]) == [10]
      assert JQ.run!(".[2]", [10, 20, 30]) == [30]
    end

    test "negative index" do
      assert JQ.run!(".[-1]", [10, 20, 30]) == [30]
    end

    test "out of bounds returns null" do
      assert JQ.run!(".[5]", [10, 20]) == [nil]
    end
  end

  describe "iteration" do
    test ".[] on array produces each element" do
      assert JQ.run!(".[]", [1, 2, 3]) == [1, 2, 3]
    end

    test ".[] on object produces each value" do
      result = JQ.run!(".[]", %{"a" => 1, "b" => 2})
      assert Enum.sort(result) == [1, 2]
    end
  end

  describe "pipe" do
    test "chains filters" do
      assert JQ.run!(".a | .b", %{"a" => %{"b" => 42}}) == [42]
    end

    test "iterate then transform" do
      assert JQ.run!(".[] | . + 1", [1, 2, 3]) == [2, 3, 4]
    end
  end

  describe "comma" do
    test "produces multiple outputs" do
      assert JQ.run!(".a, .b", %{"a" => 1, "b" => 2}) == [1, 2]
    end
  end

  describe "literals" do
    test "null, true, false" do
      assert JQ.run!("null", 0) == [nil]
      assert JQ.run!("true", 0) == [true]
      assert JQ.run!("false", 0) == [false]
    end

    test "numbers" do
      assert JQ.run!("42", 0) == [42]
      assert JQ.run!("3.14", 0) == [3.14]
    end
  end

  describe "array construction" do
    test "collects outputs into array" do
      assert JQ.run!("[.[] | . * 2]", [1, 2, 3]) == [[2, 4, 6]]
    end

    test "empty array" do
      assert JQ.run!("[]", 0) == [[]]
    end
  end

  describe "object construction" do
    test "builds object from expressions" do
      input = %{"x" => 1, "y" => 2}
      assert JQ.run!("{a: .x, b: .y}", input) == [%{"a" => 1, "b" => 2}]
    end
  end

  describe "arithmetic" do
    test "basic operations" do
      assert JQ.run!(". + 1", 5) == [6]
      assert JQ.run!(". - 1", 5) == [4]
      assert JQ.run!(". * 2", 5) == [10]
      assert JQ.run!(". / 2", 10) == [5.0]
      assert JQ.run!(". % 3", 10) == [1]
    end

    test "string concatenation" do
      assert JQ.run!(". + \" world\"", "hello") == ["hello world"]
    end

    test "array concatenation" do
      assert JQ.run!(". + [3, 4]", [1, 2]) == [[1, 2, 3, 4]]
    end

    test "object merge" do
      assert JQ.run!(". + {b: 2}", %{"a" => 1}) == [%{"a" => 1, "b" => 2}]
    end
  end

  describe "comparison" do
    test "equality" do
      assert JQ.run!(". == 1", 1) == [true]
      assert JQ.run!(". == 1", 2) == [false]
      assert JQ.run!(". != 1", 2) == [true]
    end

    test "ordering" do
      assert JQ.run!(". < 5", 3) == [true]
      assert JQ.run!(". > 5", 3) == [false]
      assert JQ.run!(". <= 5", 5) == [true]
      assert JQ.run!(". >= 5", 5) == [true]
    end
  end

  describe "conditionals" do
    test "if-then-else" do
      assert JQ.run!("if . > 0 then \"pos\" else \"non\" end", 1) == ["pos"]
      assert JQ.run!("if . > 0 then \"pos\" else \"non\" end", -1) == ["non"]
    end
  end

  describe "alternative operator" do
    test "null falls through" do
      assert JQ.run!(".a // \"default\"", %{}) == ["default"]
    end

    test "false falls through" do
      assert JQ.run!("false // \"default\"", nil) == ["default"]
    end

    test "non-null passes" do
      assert JQ.run!(".a // \"default\"", %{"a" => 42}) == [42]
    end
  end

  describe "keys and values" do
    test "keys returns sorted keys" do
      result = JQ.run!("keys", %{"b" => 2, "a" => 1})
      assert result == [["a", "b"]]
    end

    test "values returns values" do
      result = JQ.run!("values", %{"a" => 1, "b" => 2})
      assert [values] = result
      assert Enum.sort(values) == [1, 2]
    end
  end

  describe "select" do
    test "passes through when truthy" do
      assert JQ.run!(".[] | select(. > 2)", [1, 2, 3, 4]) == [3, 4]
    end
  end

  describe "map" do
    test "transforms each element" do
      assert JQ.run!("map(. + 1)", [1, 2, 3]) == [[2, 3, 4]]
    end

    test "map with select filters" do
      assert JQ.run!("map(select(. > 2))", [1, 2, 3, 4]) == [[3, 4]]
    end
  end

  describe "empty" do
    test "produces no output" do
      assert JQ.run!("empty", 42) == []
    end
  end

  describe "not" do
    test "inverts truthiness" do
      assert JQ.run!("true | not", nil) == [false]
      assert JQ.run!("false | not", nil) == [true]
      assert JQ.run!("null | not", nil) == [true]
    end
  end

  describe "has" do
    test "object has key" do
      assert JQ.run!("has(\"a\")", %{"a" => 1}) == [true]
      assert JQ.run!("has(\"b\")", %{"a" => 1}) == [false]
    end

    test "array has index" do
      assert JQ.run!("has(0)", [1, 2]) == [true]
      assert JQ.run!("has(5)", [1, 2]) == [false]
    end
  end

  describe "add" do
    test "sums numbers" do
      assert JQ.run!("add", [1, 2, 3]) == [6]
    end

    test "concatenates strings" do
      assert JQ.run!("add", ["a", "b", "c"]) == ["abc"]
    end

    test "empty array returns null" do
      assert JQ.run!("add", []) == [nil]
    end
  end

  describe "sort" do
    test "sorts array" do
      assert JQ.run!("sort", [3, 1, 2]) == [[1, 2, 3]]
    end
  end

  describe "sort_by" do
    test "sorts by key" do
      input = [%{"a" => 3}, %{"a" => 1}, %{"a" => 2}]
      assert JQ.run!("sort_by(.a)", input) == [[%{"a" => 1}, %{"a" => 2}, %{"a" => 3}]]
    end
  end

  describe "reverse" do
    test "reverses array" do
      assert JQ.run!("reverse", [1, 2, 3]) == [[3, 2, 1]]
    end

    test "reverses string" do
      assert JQ.run!("reverse", "hello") == ["olleh"]
    end
  end

  describe "unique" do
    test "removes duplicates" do
      assert JQ.run!("unique", [1, 2, 1, 3, 2]) == [[1, 2, 3]]
    end
  end

  describe "flatten" do
    test "flattens nested arrays" do
      assert JQ.run!("flatten", [[1, [2]], [3]]) == [[1, 2, 3]]
    end

    test "flatten with depth" do
      assert JQ.run!("flatten(1)", [[1, [2]], [3]]) == [[1, [2], 3]]
    end
  end

  describe "min and max" do
    test "min of array" do
      assert JQ.run!("min", [3, 1, 2]) == [1]
    end

    test "max of array" do
      assert JQ.run!("max", [3, 1, 2]) == [3]
    end
  end

  describe "range" do
    test "range with one arg" do
      assert JQ.run!("[range(4)]", nil) == [[0, 1, 2, 3]]
    end

    test "range with two args" do
      assert JQ.run!("[range(2; 5)]", nil) == [[2, 3, 4]]
    end

    test "range with step" do
      assert JQ.run!("[range(0; 10; 3)]", nil) == [[0, 3, 6, 9]]
    end
  end

  describe "string builtins" do
    test "ascii_downcase" do
      assert JQ.run!("ascii_downcase", "HELLO") == ["hello"]
    end

    test "ascii_upcase" do
      assert JQ.run!("ascii_upcase", "hello") == ["HELLO"]
    end

    test "split" do
      assert JQ.run!("split(\",\")", "a,b,c") == [["a", "b", "c"]]
    end

    test "join" do
      assert JQ.run!("join(\",\")", ["a", "b", "c"]) == ["a,b,c"]
    end

    test "startswith" do
      assert JQ.run!("startswith(\"he\")", "hello") == [true]
      assert JQ.run!("startswith(\"xx\")", "hello") == [false]
    end

    test "endswith" do
      assert JQ.run!("endswith(\"lo\")", "hello") == [true]
    end

    test "ltrimstr" do
      assert JQ.run!("ltrimstr(\"he\")", "hello") == ["llo"]
    end

    test "rtrimstr" do
      assert JQ.run!("rtrimstr(\"lo\")", "hello") == ["hel"]
    end

    test "tostring" do
      assert JQ.run!("tostring", 42) == ["42"]
      assert JQ.run!("tostring", "hello") == ["hello"]
    end

    test "tonumber" do
      assert JQ.run!("tonumber", "42") == [42]
      assert JQ.run!("tonumber", "3.14") == [3.14]
      assert JQ.run!("tonumber", 5) == [5]
    end

    test "test regex" do
      assert JQ.run!("test(\"foo\")", "foobar") == [true]
      assert JQ.run!("test(\"baz\")", "foobar") == [false]
    end

    test "explode and implode" do
      assert JQ.run!("explode", "AB") == [[65, 66]]
      assert JQ.run!("implode", [65, 66]) == ["AB"]
    end

    test "tojson and fromjson" do
      assert JQ.run!("tojson", [1, 2]) == ["[1,2]"]
      assert JQ.run!("fromjson", "[1,2]") == [[1, 2]]
    end
  end

  describe "to_entries and from_entries" do
    test "to_entries" do
      result = JQ.run!("to_entries", %{"a" => 1})
      assert result == [[%{"key" => "a", "value" => 1}]]
    end

    test "from_entries" do
      input = [%{"key" => "a", "value" => 1}]
      assert JQ.run!("from_entries", input) == [%{"a" => 1}]
    end
  end

  describe "any and all" do
    test "any without args" do
      assert JQ.run!("any", [false, true, false]) == [true]
      assert JQ.run!("any", [false, false]) == [false]
    end

    test "all without args" do
      assert JQ.run!("all", [true, true]) == [true]
      assert JQ.run!("all", [true, false]) == [false]
    end

    test "any with filter" do
      assert JQ.run!("any(. > 3)", [1, 2, 5]) == [true]
      assert JQ.run!("any(. > 10)", [1, 2, 5]) == [false]
    end

    test "all with filter" do
      assert JQ.run!("all(. > 0)", [1, 2, 3]) == [true]
      assert JQ.run!("all(. > 2)", [1, 2, 3]) == [false]
    end
  end

  describe "math builtins" do
    test "floor" do
      assert JQ.run!("floor", 3.7) == [3]
    end

    test "ceil" do
      assert JQ.run!("ceil", 3.2) == [4]
    end

    test "round" do
      assert JQ.run!("round", 3.5) == [4]
    end

    test "sqrt" do
      assert JQ.run!("sqrt", 9) == [3.0]
    end

    test "fabs" do
      assert JQ.run!("fabs", -3.5) == [3.5]
    end
  end

  describe "reduce" do
    test "sum array" do
      assert JQ.run!("reduce .[] as $x (0; . + $x)", [1, 2, 3]) == [6]
    end
  end

  describe "variable binding" do
    test "as pattern" do
      assert JQ.run!(".[] as $x | $x * $x", [2, 3]) == [4, 9]
    end
  end

  describe "try-catch" do
    test "try suppresses errors" do
      assert JQ.run!("[.[] | try .a]", [1, %{"a" => 2}]) == [[2]]
    end
  end

  describe "function definition" do
    test "def and use" do
      assert JQ.run!("def double: . * 2; [.[] | double]", [1, 2, 3]) == [[2, 4, 6]]
    end
  end

  describe "recursive descent" do
    test ".. finds all values" do
      input = %{"a" => %{"b" => 1}, "c" => 2}
      results = JQ.run!("[.. | numbers]", input)
      assert [nums] = results
      assert Enum.sort(nums) == [1, 2]
    end
  end

  describe "path operations" do
    test "getpath" do
      assert JQ.run!("getpath([\"a\", \"b\"])", %{"a" => %{"b" => 42}}) == [42]
    end

    test "setpath" do
      assert JQ.run!("setpath([\"a\"]; 1)", %{}) == [%{"a" => 1}]
    end
  end

  describe "del" do
    test "delete field" do
      assert JQ.run!("del(.a)", %{"a" => 1, "b" => 2}) == [%{"b" => 2}]
    end
  end

  describe "group_by" do
    test "groups by key" do
      input = [%{"a" => 1}, %{"a" => 2}, %{"a" => 1}]
      result = JQ.run!("group_by(.a)", input)
      assert result == [[[%{"a" => 1}, %{"a" => 1}], [%{"a" => 2}]]]
    end
  end

  describe "unique_by" do
    test "unique by key" do
      input = [%{"a" => 1, "b" => "x"}, %{"a" => 1, "b" => "y"}, %{"a" => 2, "b" => "z"}]
      result = JQ.run!("unique_by(.a)", input)
      assert [uniq] = result
      assert length(uniq) == 2
    end
  end

  describe "indices" do
    test "finds indices in array" do
      assert JQ.run!("indices(1)", [0, 1, 2, 1, 3]) == [[1, 3]]
    end

    test "finds indices in string" do
      assert JQ.run!("indices(\"ab\")", "abcabc") == [[0, 3]]
    end
  end

  describe "contains and inside" do
    test "contains" do
      assert JQ.run!("contains([2, 0])", [2, 0, 1]) == [true]
      assert JQ.run!("contains([5])", [1, 2]) == [false]
    end

    test "inside" do
      assert JQ.run!("inside([2, 1])", [1]) == [true]
    end
  end

  describe "format strings" do
    test "@base64 encode and decode" do
      assert JQ.run!("@base64", "hello") == [Base.encode64("hello")]
      encoded = Base.encode64("hello")
      assert JQ.run!("@base64d", encoded) == ["hello"]
    end

    test "@html escapes" do
      assert JQ.run!("@html", "<b>hi</b>") == ["&lt;b&gt;hi&lt;/b&gt;"]
    end

    test "@uri encodes" do
      result = JQ.run!("@uri", "hello world")
      assert result == ["hello%20world"]
    end
  end

  describe "streaming" do
    test "eval_stream processes lazily" do
      filter = JQ.parse!(". + 1")
      results = JQ.eval_stream(filter, [1, 2, 3]) |> Enum.to_list()
      assert results == [2, 3, 4]
    end
  end

  describe "walk" do
    test "transforms all values bottom-up" do
      input = %{"a" => [1, 2], "b" => 3}
      result = JQ.run!("walk(if type == \"number\" then . * 2 else . end)", input)
      assert result == [%{"a" => [2, 4], "b" => 6}]
    end
  end

  describe "transpose" do
    test "transposes array of arrays" do
      assert JQ.run!("transpose", [[1, 2], [3, 4]]) == [[[1, 3], [2, 4]]]
    end
  end

  describe "sub and gsub" do
    test "sub replaces first" do
      assert JQ.run!("sub(\"o\"; \"0\")", "foobar") == ["f0obar"]
    end

    test "gsub replaces all" do
      assert JQ.run!("gsub(\"o\"; \"0\")", "foobar") == ["f00bar"]
    end
  end

  describe "limit and first and last" do
    test "first" do
      assert JQ.run!("first(.[])", [1, 2, 3]) == [1]
    end

    test "last" do
      assert JQ.run!("last(.[])", [1, 2, 3]) == [3]
    end

    test "limit" do
      assert JQ.run!("[limit(2; .[])]", [1, 2, 3, 4]) == [[1, 2]]
    end
  end

  describe "isempty" do
    test "true when filter produces nothing" do
      assert JQ.run!("isempty(empty)", nil) == [true]
    end

    test "false when filter produces output" do
      assert JQ.run!("isempty(.)", nil) == [false]
    end
  end
end
