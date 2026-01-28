defmodule Bash.ArithmeticExpansionTest do
  @moduledoc """
  Tests for arithmetic expansion with side effects like increment/decrement.
  """
  use Bash.SessionCase, async: true

  alias Bash.Arithmetic

  describe "Arithmetic.evaluate comma operator" do
    test "evaluates expressions left to right, returns last value" do
      assert {:ok, 3, %{"a" => "1", "b" => "2"}} = Arithmetic.evaluate("a=1,b=2,a+b", %{})
    end

    test "multiple assignments in comma expression" do
      assert {:ok, 15, %{"x" => "5", "y" => "10"}} = Arithmetic.evaluate("x=5,y=10,x+y", %{})
    end
  end

  describe "comma operator in expansion" do
    setup :start_session

    test "comma operator in arithmetic expansion", %{session: session} do
      result = run_script(session, ~S|echo "Comma: $((a=1,b=2,a+b))"|)
      assert get_stdout(result) == "Comma: 3\n"
    end
  end

  describe "pre/post increment/decrement in expansion" do
    setup :start_session

    test "pre-increment updates and returns new value", %{session: session} do
      result = run_script(session, ~S|n=5;echo "$((++n))"|)
      assert get_stdout(result) == "6\n"
    end

    test "post-increment returns old value, updates variable", %{session: session} do
      result = run_script(session, ~S|n=5;echo "$((n++)) $n"|)
      assert get_stdout(result) == "5 6\n"
    end

    test "pre-decrement updates and returns new value", %{session: session} do
      result = run_script(session, ~S|n=5;echo "$((--n))"|)
      assert get_stdout(result) == "4\n"
    end

    test "post-decrement returns old value, updates variable", %{session: session} do
      result = run_script(session, ~S|n=5;echo "$((n--)) $n"|)
      assert get_stdout(result) == "5 4\n"
    end

    test "multiple increments in one expansion thread state", %{session: session} do
      result = run_script(session, ~S|n=5;echo "Pre++: $((++n)) Post++: $((n++)) now: $n"|)
      assert get_stdout(result) == "Pre++: 6 Post++: 6 now: 7\n"
    end

    test "multiple decrements in one expansion thread state", %{session: session} do
      result = run_script(session, ~S|n=5;echo "Pre--: $((--n)) Post--: $((n--)) now: $n"|)
      assert get_stdout(result) == "Pre--: 4 Post--: 4 now: 3\n"
    end

    test "assignment resets variable between lines", %{session: session} do
      result =
        run_script(session, """
          n=5;echo "$((n++)) now: $n"
          n=5;echo "$((n++)) now: $n"
        """)

      assert get_stdout(result) == "5 now: 6\n5 now: 6\n"
    end
  end

  describe "substring expansion" do
    setup :start_session

    test "positive offset", %{session: session} do
      result = run_script(session, ~S|myvar="hello world";echo "${myvar:6}"|)
      assert get_stdout(result) == "world\n"
    end

    test "positive offset and length", %{session: session} do
      result = run_script(session, ~S|myvar="hello world";echo "${myvar:0:5}"|)
      assert get_stdout(result) == "hello\n"
    end

    test "negative offset with parentheses", %{session: session} do
      result = run_script(session, ~S|myvar="hello world";echo "${myvar:(-5)}"|)
      assert get_stdout(result) == "world\n"
    end

    test "negative offset with space", %{session: session} do
      result = run_script(session, ~S|myvar="hello world";echo "${myvar: -5}"|)
      assert get_stdout(result) == "world\n"
    end

    test "combined variable expansions", %{session: session} do
      result =
        run_script(
          session,
          ~S|myvar="hello world";echo "${myvar}" "${#myvar}" "${myvar:0:5}" "${myvar:6}" "${myvar:(-5)}"|
        )

      assert get_stdout(result) == "hello world 11 hello world world\n"
    end
  end

  describe "pattern replacement" do
    setup :start_session

    test "first occurrence replacement ${str/a/X}", %{session: session} do
      result = run_script(session, ~S|str="banana";echo "${str/a/X}"|)
      assert get_stdout(result) == "bXnana\n"
    end

    test "all occurrences replacement ${str//a/X}", %{session: session} do
      result = run_script(session, ~S|str="banana";echo "${str//a/X}"|)
      assert get_stdout(result) == "bXnXnX\n"
    end

    test "prefix replacement ${str/#b/X}", %{session: session} do
      result = run_script(session, ~S|str="banana";echo "${str/#b/X}"|)
      assert get_stdout(result) == "Xanana\n"
    end

    test "suffix replacement ${str/%a/X}", %{session: session} do
      result = run_script(session, ~S|str="banana";echo "${str/%a/X}"|)
      assert get_stdout(result) == "bananX\n"
    end

    test "combined pattern replacements", %{session: session} do
      result =
        run_script(
          session,
          ~S|str="banana";echo "${str/a/X}" "${str//a/X}" "${str/#b/X}" "${str/%a/X}"|
        )

      assert get_stdout(result) == "bXnana bXnXnX Xanana bananX\n"
    end

    test "pattern removal with slash", %{session: session} do
      result =
        run_script(
          session,
          ~S|path="/usr/local/bin/bash";echo "${path#*/}" "${path##*/}" "${path%/*}" "${path%%/*}"|
        )

      assert get_stdout(result) == "usr/local/bin/bash bash /usr/local/bin \n"
    end
  end

  describe "case modification" do
    setup :start_session

    test "uppercase first ${word^}", %{session: session} do
      result = run_script(session, ~S|word="hElLo";echo "${word^}"|)
      assert get_stdout(result) == "HElLo\n"
    end

    test "uppercase all ${word^^}", %{session: session} do
      result = run_script(session, ~S|word="hElLo";echo "${word^^}"|)
      assert get_stdout(result) == "HELLO\n"
    end

    test "lowercase first ${word,}", %{session: session} do
      result = run_script(session, ~S|word="hElLo";echo "${word,}"|)
      assert get_stdout(result) == "hElLo\n"
    end

    test "lowercase all ${word,,}", %{session: session} do
      result = run_script(session, ~S|word="hElLo";echo "${word,,}"|)
      assert get_stdout(result) == "hello\n"
    end

    test "combined case modifications", %{session: session} do
      result =
        run_script(session, ~S|word="hElLo";echo "${word^}" "${word^^}" "${word,}" "${word,,}"|)

      assert get_stdout(result) == "HElLo HELLO hElLo hello\n"
    end
  end

  describe "array index expansion" do
    setup :start_session

    test "indexed array element access ${arr[0]}", %{session: session} do
      result =
        run_script(session, ~S|arr=(one two three);echo "${arr[0]}" "${arr[1]}" "${arr[2]}"|)

      assert get_stdout(result) == "one two three\n"
    end

    test "indexed array all elements ${arr[@]}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three);echo "${arr[@]}"|)
      assert get_stdout(result) == "one two three\n"
    end

    test "indexed array length ${#arr[@]}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three);echo "${#arr[@]}"|)
      assert get_stdout(result) == "3\n"
    end
  end

  describe "array slicing" do
    setup :start_session

    test "array slice ${arr[@]:1:2}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three four five);echo "${arr[@]:1:2}"|)
      assert get_stdout(result) == "two three\n"
    end

    test "array slice from offset ${arr[@]:2}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three four five);echo "${arr[@]:2}"|)
      assert get_stdout(result) == "three four five\n"
    end

    test "array slice with negative offset ${arr[@]: -2}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three four five);echo "${arr[@]: -2}"|)
      assert get_stdout(result) == "four five\n"
    end
  end

  describe "array index/key listing" do
    setup :start_session

    test "list array indices ${!arr[@]}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three);echo "${!arr[@]}"|)
      assert get_stdout(result) == "0 1 2\n"
    end

    test "list array indices with gaps", %{session: session} do
      result = run_script(session, ~S|arr=();arr[0]=a;arr[2]=b;arr[5]=c;echo "${!arr[@]}"|)
      assert get_stdout(result) == "0 2 5\n"
    end

    test "list array indices with append after gap", %{session: session} do
      result =
        run_script(
          session,
          ~S|arr=(one two three four five);arr[10]="ten";arr+=("appended");echo "${!arr[@]}"|
        )

      assert get_stdout(result) == "0 1 2 3 4 10 11\n"
    end

    test "list associative array keys ${!hash[@]}", %{session: session} do
      result = run_script(session, ~S|declare -A hash;hash[foo]=1;hash[bar]=2;echo "${!hash[@]}"|)
      # Keys can be in any order, so check both are present
      output = get_stdout(result) |> String.trim() |> String.split() |> Enum.sort()
      assert output == ["bar", "foo"]
    end
  end

  describe "indirect reference" do
    setup :start_session

    test "indirect reference ${!ref}", %{session: session} do
      result = run_script(session, ~S|myvar="hello world";ref="myvar";echo "${!ref}"|)
      assert get_stdout(result) == "hello world\n"
    end

    test "indirect reference to unset variable", %{session: session} do
      result = run_script(session, ~S|ref="nonexistent";echo ">${!ref}<"|)
      assert get_stdout(result) == "><\n"
    end
  end

  describe "shell options" do
    setup :start_session

    test "shell options variable $-", %{session: session} do
      # By default, hashall (h) and braceexpand (B) should be enabled
      result = run_script(session, ~S|echo "Options: $-"|)
      output = get_stdout(result)
      # Should contain h and B
      assert output =~ ~r/h/
      assert output =~ ~r/B/
    end
  end

  describe "comprehensive array operations" do
    setup :start_session

    test "array with gaps - all values", %{session: session} do
      result =
        run_script(
          session,
          ~S|arr=(one two three four five);arr[10]="ten";arr+=("appended");echo "Array: ${arr[@]}"|
        )

      assert get_stdout(result) == "Array: one two three four five ten appended\n"
    end

    test "array with gaps - length", %{session: session} do
      result =
        run_script(
          session,
          ~S|arr=(one two three four five);arr[10]="ten";arr+=("appended");echo "Length: ${#arr[@]}"|
        )

      assert get_stdout(result) == "Length: 7\n"
    end

    test "array element length ${#arr[0]}", %{session: session} do
      result = run_script(session, ~S|arr=(one two three);echo "Element: ${#arr[0]}"|)
      assert get_stdout(result) == "Element: 3\n"
    end

    test "array slice with gaps", %{session: session} do
      result =
        run_script(
          session,
          ~S|arr=(one two three four five);arr[10]="ten";echo "Slice: ${arr[@]:1:3}"|
        )

      assert get_stdout(result) == "Slice: two three four\n"
    end
  end

  describe "ANSI-C quoting" do
    setup :start_session

    test "basic escape sequences \\t \\n", %{session: session} do
      result = run_script(session, ~S|echo $'hello\tworld\n'|)
      assert get_stdout(result) == "hello\tworld\n\n"
    end

    test "hex escape \\xNN", %{session: session} do
      # \x41 is 'A'
      result = run_script(session, ~S|echo $'\x41\x42\x43'|)
      assert get_stdout(result) == "ABC\n"
    end

    test "octal escape \\NNN", %{session: session} do
      # \101 is 'A' (65 in decimal)
      result = run_script(session, ~S|echo $'\101\102\103'|)
      assert get_stdout(result) == "ABC\n"
    end

    test "mixed escapes", %{session: session} do
      # Tab, newline, and 'A' via hex
      result = run_script(session, ~S|echo $'ANSI-C:\t\n\x41'|)
      assert get_stdout(result) == "ANSI-C:\t\nA\n"
    end

    test "escaped single quote", %{session: session} do
      result = run_script(session, ~S|echo $'it\'s working'|)
      assert get_stdout(result) == "it's working\n"
    end

    test "escaped backslash", %{session: session} do
      result = run_script(session, ~S|echo $'back\\slash'|)
      assert get_stdout(result) == "back\\slash\n"
    end
  end

  describe "parameter transformation operators" do
    setup :start_session

    test "${var@Q} quotes scalar for reuse", %{session: session} do
      result = run_script(session, ~S|x="hello world"; echo "${x@Q}"|)
      assert get_stdout(result) == "'hello world'\n"
    end

    test "${arr[@]@Q} quotes each array element", %{session: session} do
      result = run_script(session, ~S|arr=(one two three); echo "${arr[@]@Q}"|)
      assert get_stdout(result) == "'one' 'two' 'three'\n"
    end

    test "${arr[0]@E} expands escape sequences in element", %{session: session} do
      result = run_script(session, ~S|arr=(one two); echo "${arr[0]@E}"|)
      assert get_stdout(result) == "one\n"
    end

    test "${arr[@]@A} produces assignment statement for indexed array", %{session: session} do
      result = run_script(session, ~S|arr=(one two three); echo "${arr[@]@A}"|)
      assert get_stdout(result) == ~s|declare -a arr=([0]="one" [1]="two" [2]="three")\n|
    end

    test "${arr[@]@a} shows attribute flags for each element", %{session: session} do
      result = run_script(session, ~S|arr=(one two three); echo "${arr[@]@a}"|)
      assert get_stdout(result) == "a a a\n"
    end

    test "${var@a} shows attribute flags for scalar", %{session: session} do
      result = run_script(session, ~S|x=hello; echo "${x@a}"|)
      assert get_stdout(result) == "\n"
    end

    test "${arr[-1]} negative index accesses from end", %{session: session} do
      result = run_script(session, ~S|arr=(a b c d e); echo "${arr[-1]} ${arr[-2]}"|)
      assert get_stdout(result) == "e d\n"
    end

    test "${arr[i]} works inside C-style for loop", %{session: session} do
      result = run_script(session, ~S|arr=(a b c); for ((i=0; i<3; i++)); do printf "%s" "${arr[i]}"; done; echo|)
      assert get_stdout(result) == "abc\n"
    end

    test "${#arr[@]} works in C-style for loop init", %{session: session} do
      result =
        run_script(session, """
        arr=(a b c d e)
        for ((i=${#arr[@]}-1; i>=0; i--)); do printf "%s" "${arr[i]}"; done; echo
        """)

      assert get_stdout(result) == "edcba\n"
    end
  end
end
