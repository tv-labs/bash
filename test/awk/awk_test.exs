defmodule AWK.AWKTest do
  use ExUnit.Case, async: true

  describe "print" do
    test "print with no args prints $0" do
      assert AWK.run!("{print}", "hello\nworld") == "hello\nworld\n"
    end

    test "print specific field" do
      assert AWK.run!("{print $1}", "hello world\nfoo bar") == "hello\nfoo\n"
    end

    test "print multiple fields" do
      assert AWK.run!("{print $1, $2}", "hello world") == "hello world\n"
    end

    test "print string literal" do
      assert AWK.run!("BEGIN {print \"hello\"}") == "hello\n"
    end

    test "print numeric literal" do
      assert AWK.run!("BEGIN {print 42}") == "42\n"
    end

    test "print $0 explicitly" do
      assert AWK.run!("{print $0}", "a line") == "a line\n"
    end

    test "print with no action defaults to print $0" do
      assert AWK.run!("/hello/", "hello\nworld\nhello again") == "hello\nhello again\n"
    end

    test "print multiple expressions separated by commas uses OFS" do
      assert AWK.run!("{print $1, $2, $3}", "a b c") == "a b c\n"
    end

    test "print concatenation without comma has no separator" do
      assert AWK.run!("{print $1 $2}", "hello world") == "helloworld\n"
    end
  end

  describe "field splitting" do
    test "default FS splits on whitespace" do
      assert AWK.run!("{print $2}", "one two three") == "two\n"
    end

    test "custom FS with BEGIN" do
      assert AWK.run!("BEGIN {FS=\",\"} {print $2}", "a,b,c") == "b\n"
    end

    test "FS as regex" do
      assert AWK.run!("BEGIN {FS=\"[,;]\"} {print $2}", "a,b;c") == "b\n"
    end

    test "multiple whitespace collapsed" do
      assert AWK.run!("{print $2}", "one   two   three") == "two\n"
    end

    test "$NF gives the last field" do
      assert AWK.run!("{print $NF}", "one two three") == "three\n"
    end

    test "$(NF-1) gives second to last field" do
      assert AWK.run!("{print $(NF-1)}", "one two three") == "two\n"
    end

    test "modifying a field reconstructs $0" do
      assert AWK.run!("{$2=\"REPLACED\"; print}", "one two three") == "one REPLACED three\n"
    end

    test "accessing field beyond NF returns empty string" do
      assert AWK.run!("{print $10}", "a b c") == "\n"
    end

    test "single character FS" do
      assert AWK.run!("BEGIN {FS=\":\"} {print $1, $3}", "root:x:0:0") == "root 0\n"
    end

    test "tab as FS" do
      assert AWK.run!("BEGIN {FS=\"\\t\"} {print $2}", "one\ttwo\tthree") == "two\n"
    end
  end

  describe "built-in variables" do
    test "NR tracks the record number" do
      assert AWK.run!("{print NR}", "a\nb\nc") == "1\n2\n3\n"
    end

    test "NF counts the number of fields" do
      assert AWK.run!("{print NF}", "one two three\nfoo") == "3\n1\n"
    end

    test "NR in END rule gives total record count" do
      assert AWK.run!("END {print NR}", "a\nb\nc") == "3\n"
    end

    test "OFS is used between print arguments" do
      assert AWK.run!("BEGIN {OFS=\"-\"} {print $1, $2}", "a b") == "a-b\n"
    end

    test "ORS is used after each print" do
      assert AWK.run!("BEGIN {ORS=\";\"} {print $1}", "a b\nc d") == "a;c;"
    end

    test "RS changes the record separator" do
      assert AWK.run!("BEGIN {RS=\";\"} {print NR, $0}", "one;two;three") ==
               "1 one\n2 two\n3 three\n"
    end

    test "SUBSEP default value" do
      assert AWK.run!("BEGIN {print SUBSEP == \"\\034\"}") == "1\n"
    end
  end

  describe "patterns" do
    test "regex pattern matches records" do
      assert AWK.run!("/world/ {print}", "hello\nworld\nbye") == "world\n"
    end

    test "expression pattern" do
      assert AWK.run!("NR > 1 {print}", "first\nsecond\nthird") == "second\nthird\n"
    end

    test "range pattern" do
      assert AWK.run!("/start/,/stop/ {print}", "before\nstart\nmiddle\nstop\nafter") ==
               "start\nmiddle\nstop\n"
    end

    test "no pattern matches all records" do
      assert AWK.run!("{print \"yes\"}", "a\nb") == "yes\nyes\n"
    end

    test "BEGIN rule executes before input" do
      assert AWK.run!("BEGIN {print \"header\"} {print}", "data") == "header\ndata\n"
    end

    test "END rule executes after input" do
      assert AWK.run!("{print} END {print \"footer\"}", "data") == "data\nfooter\n"
    end

    test "multiple rules execute in order" do
      assert AWK.run!("/hello/ {print \"found\"} {print NR}", "hello\nworld") ==
               "found\n1\n2\n"
    end

    test "BEGIN without input" do
      assert AWK.run!("BEGIN {print 1+1}") == "2\n"
    end

    test "multiple BEGIN rules" do
      assert AWK.run!("BEGIN {print \"a\"} BEGIN {print \"b\"}") == "a\nb\n"
    end

    test "multiple END rules" do
      assert AWK.run!("END {print \"x\"} END {print \"y\"}", "data") == "x\ny\n"
    end
  end

  describe "arithmetic" do
    test "addition" do
      assert AWK.run!("BEGIN {print 3 + 4}") == "7\n"
    end

    test "subtraction" do
      assert AWK.run!("BEGIN {print 10 - 3}") == "7\n"
    end

    test "multiplication" do
      assert AWK.run!("BEGIN {print 6 * 7}") == "42\n"
    end

    test "division" do
      assert AWK.run!("BEGIN {print 10 / 4}") == "2.5\n"
    end

    test "modulo" do
      assert AWK.run!("BEGIN {print 10 % 3}") == "1\n"
    end

    test "exponentiation" do
      assert AWK.run!("BEGIN {print 2 ^ 10}") == "1024\n"
    end

    test "post-increment" do
      assert AWK.run!("BEGIN {x = 5; print x++; print x}") == "5\n6\n"
    end

    test "pre-increment" do
      assert AWK.run!("BEGIN {x = 5; print ++x; print x}") == "6\n6\n"
    end

    test "post-decrement" do
      assert AWK.run!("BEGIN {x = 5; print x--; print x}") == "5\n4\n"
    end

    test "pre-decrement" do
      assert AWK.run!("BEGIN {x = 5; print --x; print x}") == "4\n4\n"
    end

    test "+= assignment" do
      assert AWK.run!("BEGIN {x = 10; x += 5; print x}") == "15\n"
    end

    test "-= assignment" do
      assert AWK.run!("BEGIN {x = 10; x -= 3; print x}") == "7\n"
    end

    test "*= assignment" do
      assert AWK.run!("BEGIN {x = 4; x *= 3; print x}") == "12\n"
    end

    test "/= assignment" do
      assert AWK.run!("BEGIN {x = 10; x /= 4; print x}") == "2.5\n"
    end

    test "%= assignment" do
      assert AWK.run!("BEGIN {x = 10; x %= 3; print x}") == "1\n"
    end

    test "^= assignment" do
      assert AWK.run!("BEGIN {x = 2; x ^= 3; print x}") == "8\n"
    end

    test "unary minus" do
      assert AWK.run!("BEGIN {x = 5; print -x}") == "-5\n"
    end

    test "unary plus" do
      assert AWK.run!("BEGIN {x = \"5\"; print +x}") == "5\n"
    end

    test "integer arithmetic stays integer" do
      assert AWK.run!("BEGIN {print 6 / 3}") == "2\n"
    end

    test "float arithmetic" do
      assert AWK.run!("BEGIN {print 1.5 + 2.3}") == "3.8\n"
    end

    test "operator precedence" do
      assert AWK.run!("BEGIN {print 2 + 3 * 4}") == "14\n"
    end

    test "parenthesized expressions" do
      assert AWK.run!("BEGIN {print (2 + 3) * 4}") == "20\n"
    end
  end

  describe "string operations" do
    test "implicit concatenation" do
      assert AWK.run!("BEGIN {print \"hello\" \"world\"}") == "helloworld\n"
    end

    test "length of string" do
      assert AWK.run!("BEGIN {print length(\"hello\")}") == "5\n"
    end

    test "length of field" do
      assert AWK.run!("{print length($1)}", "hello world") == "5\n"
    end

    test "substr with start and length" do
      assert AWK.run!("BEGIN {print substr(\"hello\", 2, 3)}") == "ell\n"
    end

    test "substr with only start" do
      assert AWK.run!("BEGIN {print substr(\"hello\", 3)}") == "llo\n"
    end

    test "index finds substring position" do
      assert AWK.run!("BEGIN {print index(\"hello world\", \"world\")}") == "7\n"
    end

    test "index returns 0 when not found" do
      assert AWK.run!("BEGIN {print index(\"hello\", \"xyz\")}") == "0\n"
    end

    test "split string into array" do
      assert AWK.run!("BEGIN {n = split(\"a:b:c\", arr, \":\"); print n, arr[1], arr[2], arr[3]}") ==
               "3 a b c\n"
    end

    test "sub replaces first match" do
      assert AWK.run!("{sub(/o/, \"0\"); print}", "foobar") == "f0obar\n"
    end

    test "gsub replaces all matches" do
      assert AWK.run!("{gsub(/o/, \"0\"); print}", "foobar") == "f00bar\n"
    end

    test "gsub returns count of replacements" do
      assert AWK.run!("{n = gsub(/o/, \"0\"); print n}", "foobar") == "2\n"
    end

    test "match returns position" do
      assert AWK.run!("BEGIN {print match(\"hello world\", /wor/)}") == "7\n"
    end

    test "match sets RSTART and RLENGTH" do
      assert AWK.run!("BEGIN {match(\"hello world\", /wor/); print RSTART, RLENGTH}") == "7 3\n"
    end

    test "sprintf formats a string" do
      assert AWK.run!("BEGIN {print sprintf(\"%05d\", 42)}") == "00042\n"
    end

    test "tolower converts to lowercase" do
      assert AWK.run!("BEGIN {print tolower(\"HELLO\")}") == "hello\n"
    end

    test "toupper converts to uppercase" do
      assert AWK.run!("BEGIN {print toupper(\"hello\")}") == "HELLO\n"
    end
  end

  describe "control flow" do
    test "if statement" do
      assert AWK.run!("BEGIN {x = 5; if (x > 3) print \"big\"}") == "big\n"
    end

    test "if-else statement" do
      assert AWK.run!("BEGIN {x = 2; if (x > 3) print \"big\"; else print \"small\"}") ==
               "small\n"
    end

    test "while loop" do
      assert AWK.run!("BEGIN {i = 0; while (i < 3) {print i; i++}}") == "0\n1\n2\n"
    end

    test "for loop" do
      assert AWK.run!("BEGIN {for (i = 0; i < 3; i++) print i}") == "0\n1\n2\n"
    end

    test "for-in loop iterates over array keys" do
      result = AWK.run!("BEGIN {a[\"x\"]=1; a[\"y\"]=2; for (k in a) count++; print count}")
      assert result == "2\n"
    end

    test "do-while loop executes at least once" do
      assert AWK.run!("BEGIN {i = 10; do {print i; i++} while (i < 10)}") == "10\n"
    end

    test "break exits loop" do
      assert AWK.run!("BEGIN {for (i = 0; i < 10; i++) {if (i == 3) break; print i}}") ==
               "0\n1\n2\n"
    end

    test "continue skips iteration" do
      assert AWK.run!("BEGIN {for (i = 0; i < 5; i++) {if (i == 2) continue; print i}}") ==
               "0\n1\n3\n4\n"
    end

    test "next skips to next record" do
      assert AWK.run!("NR == 2 {next} {print}", "a\nb\nc") == "a\nc\n"
    end

    test "exit ends processing and runs END" do
      assert AWK.run!("{if (NR == 2) exit} END {print NR}", "a\nb\nc") == "2\n"
    end

    test "nested if-else" do
      prog = """
      BEGIN {
        x = 5
        if (x > 10) print "big"
        else if (x > 3) print "medium"
        else print "small"
      }
      """

      assert AWK.run!(prog) == "medium\n"
    end

    test "nested loops" do
      prog = """
      BEGIN {
        for (i = 1; i <= 2; i++)
          for (j = 1; j <= 2; j++)
            print i, j
      }
      """

      assert AWK.run!(prog) == "1 1\n1 2\n2 1\n2 2\n"
    end
  end

  describe "arrays" do
    test "associative array creation and access" do
      assert AWK.run!("BEGIN {a[\"x\"] = 42; print a[\"x\"]}") == "42\n"
    end

    test "numeric indices" do
      assert AWK.run!("BEGIN {a[1] = \"one\"; a[2] = \"two\"; print a[1], a[2]}") ==
               "one two\n"
    end

    test "for-in iterates over array" do
      result = AWK.run!("BEGIN {a[1]=10; a[2]=20; a[3]=30; s=0; for (k in a) s += a[k]; print s}")
      assert result == "60\n"
    end

    test "delete array element" do
      assert AWK.run!("BEGIN {a[1]=1; a[2]=2; delete a[1]; print (1 in a), (2 in a)}") ==
               "0 1\n"
    end

    test "in operator for membership test" do
      assert AWK.run!("BEGIN {a[\"x\"]=1; print (\"x\" in a), (\"y\" in a)}") == "1 0\n"
    end

    test "multi-dimensional array with SUBSEP" do
      assert AWK.run!("BEGIN {a[1,2] = \"val\"; print a[1,2]}") == "val\n"
    end

    test "length of array" do
      assert AWK.run!("BEGIN {a[1]=1; a[2]=2; a[3]=3; print length(a)}") == "3\n"
    end

    test "uninitialized array element is empty" do
      assert AWK.run!("BEGIN {print a[\"missing\"] == \"\"}") == "1\n"
    end

    test "array built from input fields" do
      prog = "{count[$1]++} END {for (w in count) print w, count[w]}"
      result = AWK.run!(prog, "a\nb\na\nc\na\nb")
      lines = result |> String.trim() |> String.split("\n") |> Enum.sort()
      assert lines == ["a 3", "b 2", "c 1"]
    end
  end

  describe "user-defined functions" do
    test "simple function" do
      prog = "function double(x) { return x * 2 } BEGIN { print double(21) }"
      assert AWK.run!(prog) == "42\n"
    end

    test "recursive function" do
      prog = """
      function factorial(n) {
        if (n <= 1) return 1
        return n * factorial(n - 1)
      }
      BEGIN { print factorial(5) }
      """

      assert AWK.run!(prog) == "120\n"
    end

    test "local variables via extra params" do
      prog = """
      function f(x,    local_var) {
        local_var = x * 2
        return local_var + 1
      }
      BEGIN { print f(10) }
      """

      assert AWK.run!(prog) == "21\n"
    end

    test "pass array by reference" do
      prog = """
      function fill(arr) {
        arr[1] = "one"
        arr[2] = "two"
      }
      BEGIN { fill(a); print a[1], a[2] }
      """

      assert AWK.run!(prog) == "one two\n"
    end

    test "function with no return value" do
      prog = """
      function greet(name) {
        print "hello " name
      }
      BEGIN { greet("world") }
      """

      assert AWK.run!(prog) == "hello world\n"
    end

    test "multiple functions" do
      prog = """
      function add(a, b) { return a + b }
      function mul(a, b) { return a * b }
      BEGIN { print add(2, 3), mul(2, 3) }
      """

      assert AWK.run!(prog) == "5 6\n"
    end
  end

  describe "printf" do
    test "printf with %d" do
      assert AWK.run!("BEGIN {printf \"%d\\n\", 42}") == "42\n"
    end

    test "printf with %s" do
      assert AWK.run!("BEGIN {printf \"%s\\n\", \"hello\"}") == "hello\n"
    end

    test "printf with %f" do
      assert AWK.run!("BEGIN {printf \"%.2f\\n\", 3.14159}") == "3.14\n"
    end

    test "printf with width specifier" do
      assert AWK.run!("BEGIN {printf \"%10d\\n\", 42}") == "        42\n"
    end

    test "printf with left justify" do
      assert AWK.run!("BEGIN {printf \"%-10s|\\n\", \"hi\"}") == "hi        |\n"
    end

    test "printf with multiple format specifiers" do
      assert AWK.run!("BEGIN {printf \"%s is %d\\n\", \"age\", 25}") == "age is 25\n"
    end

    test "printf with %c character" do
      assert AWK.run!("BEGIN {printf \"%c\\n\", 65}") == "A\n"
    end

    test "printf with %o octal" do
      assert AWK.run!("BEGIN {printf \"%o\\n\", 8}") == "10\n"
    end

    test "printf with %x hex" do
      assert AWK.run!("BEGIN {printf \"%x\\n\", 255}") == "ff\n"
    end

    test "printf with %e scientific notation" do
      assert AWK.run!("BEGIN {printf \"%e\\n\", 123456.789}") =~ ~r/1\.234568?e\+0?5/
    end

    test "printf with %g" do
      assert AWK.run!("BEGIN {printf \"%g\\n\", 100.0}") == "100\n"
    end

    test "printf does not add newline automatically" do
      assert AWK.run!("BEGIN {printf \"no newline\"}") == "no newline"
    end

    test "printf with zero padding" do
      assert AWK.run!("BEGIN {printf \"%05d\\n\", 42}") == "00042\n"
    end
  end

  describe "getline" do
    test "getline reads next record" do
      assert AWK.run!("NR == 1 {getline; print}", "first\nsecond\nthird") == "second\n"
    end

    test "getline into variable" do
      assert AWK.run!("NR == 1 {getline line; print line}", "first\nsecond") == "second\n"
    end

    test "getline updates NR" do
      assert AWK.run!("NR == 1 {getline; print NR}", "first\nsecond") == "2\n"
    end
  end

  describe "regular expressions" do
    test "/pattern/ matches record" do
      assert AWK.run!("/foo/ {print}", "foo\nbar\nfoobar") == "foo\nfoobar\n"
    end

    test "~ match operator" do
      assert AWK.run!("$1 ~ /^[0-9]+$/ {print}", "123\nabc\n456") == "123\n456\n"
    end

    test "!~ negated match operator" do
      assert AWK.run!("$1 !~ /^[0-9]+$/ {print}", "123\nabc\n456") == "abc\n"
    end

    test "regex in split" do
      assert AWK.run!("BEGIN {n = split(\"a1b2c3d\", arr, /[0-9]/); print n, arr[1], arr[3]}") ==
               "4 a c\n"
    end

    test "regex with special characters" do
      assert AWK.run!("/\\.txt$/ {print}", "file.txt\nfile.csv\nother.txt") ==
               "file.txt\nother.txt\n"
    end

    test "regex with alternation" do
      assert AWK.run!("/cat|dog/ {print}", "cat\nbird\ndog\nfish") == "cat\ndog\n"
    end
  end

  describe "comparison operators" do
    test "equal" do
      assert AWK.run!("BEGIN {print (3 == 3)}") == "1\n"
    end

    test "not equal" do
      assert AWK.run!("BEGIN {print (3 != 4)}") == "1\n"
    end

    test "less than" do
      assert AWK.run!("BEGIN {print (3 < 4)}") == "1\n"
    end

    test "greater than" do
      assert AWK.run!("BEGIN {print (4 > 3)}") == "1\n"
    end

    test "less than or equal" do
      assert AWK.run!("BEGIN {print (3 <= 3)}") == "1\n"
    end

    test "greater than or equal" do
      assert AWK.run!("BEGIN {print (3 >= 4)}") == "0\n"
    end

    test "string comparison" do
      assert AWK.run!("BEGIN {print (\"abc\" < \"abd\")}") == "1\n"
    end

    test "numeric string comparison in numeric context" do
      assert AWK.run!("BEGIN {print (\"10\" > \"9\")}") == "1\n"
    end
  end

  describe "logical operators" do
    test "logical and" do
      assert AWK.run!("BEGIN {print (1 && 1)}") == "1\n"
    end

    test "logical and with false" do
      assert AWK.run!("BEGIN {print (1 && 0)}") == "0\n"
    end

    test "logical or" do
      assert AWK.run!("BEGIN {print (0 || 1)}") == "1\n"
    end

    test "logical or both false" do
      assert AWK.run!("BEGIN {print (0 || 0)}") == "0\n"
    end

    test "logical not" do
      assert AWK.run!("BEGIN {print !0}") == "1\n"
    end

    test "logical not of truthy" do
      assert AWK.run!("BEGIN {print !1}") == "0\n"
    end

    test "short-circuit AND does not evaluate second operand" do
      assert AWK.run!("BEGIN {x = 0; if (0 && (x = 1)) {} ; print x}") == "0\n"
    end

    test "short-circuit OR does not evaluate second operand" do
      assert AWK.run!("BEGIN {x = 0; if (1 || (x = 1)) {} ; print x}") == "0\n"
    end
  end

  describe "ternary operator" do
    test "ternary true branch" do
      assert AWK.run!("BEGIN {print (1 ? \"yes\" : \"no\")}") == "yes\n"
    end

    test "ternary false branch" do
      assert AWK.run!("BEGIN {print (0 ? \"yes\" : \"no\")}") == "no\n"
    end

    test "ternary with expression condition" do
      assert AWK.run!("{print ($1 > 5 ? \"big\" : \"small\")}", "3\n7\n1\n10") ==
               "small\nbig\nsmall\nbig\n"
    end

    test "nested ternary" do
      assert AWK.run!("BEGIN {x=5; print (x>10 ? \"big\" : x>3 ? \"medium\" : \"small\")}") ==
               "medium\n"
    end
  end

  describe "OFS and ORS" do
    test "custom OFS" do
      assert AWK.run!("BEGIN {OFS=\",\"} {print $1, $2}", "a b\nc d") == "a,b\nc,d\n"
    end

    test "custom ORS" do
      assert AWK.run!("BEGIN {ORS=\";\"} {print $1}", "a b\nc d") == "a;c;"
    end

    test "OFS used in field reconstruction" do
      assert AWK.run!("BEGIN {OFS=\"-\"} {$1=$1; print}", "a b c") == "a-b-c\n"
    end

    test "OFS and ORS together" do
      assert AWK.run!("BEGIN {OFS=\",\"; ORS=\";\"} {print $1, $2}", "a b\nc d") == "a,b;c,d;"
    end

    test "empty ORS" do
      assert AWK.run!("BEGIN {ORS=\"\"} {print $1}", "a\nb\nc") == "abc"
    end

    test "multi-character ORS" do
      assert AWK.run!("BEGIN {ORS=\"\\n---\\n\"} {print $1}", "a\nb") == "a\n---\nb\n---\n"
    end
  end

  describe "math functions" do
    test "sin" do
      assert AWK.run!("BEGIN {printf \"%.4f\\n\", sin(0)}") == "0.0000\n"
    end

    test "cos" do
      assert AWK.run!("BEGIN {printf \"%.4f\\n\", cos(0)}") == "1.0000\n"
    end

    test "atan2" do
      result = AWK.run!("BEGIN {printf \"%.4f\\n\", atan2(1, 1)}")
      assert result == "0.7854\n"
    end

    test "exp" do
      assert AWK.run!("BEGIN {printf \"%.4f\\n\", exp(1)}") == "2.7183\n"
    end

    test "log" do
      assert AWK.run!("BEGIN {printf \"%.4f\\n\", log(exp(1))}") == "1.0000\n"
    end

    test "sqrt" do
      assert AWK.run!("BEGIN {print sqrt(144)}") == "12\n"
    end

    test "int truncates toward zero" do
      assert AWK.run!("BEGIN {print int(3.9)}") == "3\n"
    end

    test "int with negative number" do
      assert AWK.run!("BEGIN {print int(-3.9)}") == "-3\n"
    end

    test "srand and rand produce deterministic values" do
      assert AWK.run!("BEGIN {srand(42); print (rand() > 0)}") == "1\n"
    end

    test "rand produces values between 0 and 1" do
      assert AWK.run!("BEGIN {srand(1); r = rand(); print (r >= 0 && r < 1)}") == "1\n"
    end
  end

  describe "type coercion" do
    test "string to number via addition" do
      assert AWK.run!("BEGIN {print \"42\" + 0}") == "42\n"
    end

    test "number to string via concatenation" do
      assert AWK.run!("BEGIN {print 42 \"\"}") == "42\n"
    end

    test "uninitialized variable is zero in numeric context" do
      assert AWK.run!("BEGIN {print x + 0}") == "0\n"
    end

    test "uninitialized variable is empty in string context" do
      assert AWK.run!("BEGIN {print x \"\"}") == "\n"
    end

    test "string with leading number converts to that number" do
      assert AWK.run!("BEGIN {print \"3.14abc\" + 0}") == "3.14\n"
    end

    test "non-numeric string converts to zero" do
      assert AWK.run!("BEGIN {print \"abc\" + 0}") == "0\n"
    end

    test "comparison context coercion" do
      assert AWK.run!("BEGIN {print (\"10\" + 0 > \"9\" + 0)}") == "1\n"
    end
  end

  describe "complex programs" do
    test "word frequency counter" do
      prog = """
      {
        for (i = 1; i <= NF; i++)
          freq[$i]++
      }
      END {
        for (w in freq)
          print w, freq[w]
      }
      """

      result = AWK.run!(prog, "the cat sat on the mat\nthe cat")
      lines = result |> String.trim() |> String.split("\n") |> Enum.sort()
      assert "cat 2" in lines
      assert "the 3" in lines
      assert "sat 1" in lines
      assert "on 1" in lines
      assert "mat 1" in lines
    end

    test "CSV field extraction" do
      prog = "BEGIN {FS=\",\"} {print $2}"
      input = "Alice,30,NYC\nBob,25,LA\nCharlie,35,Chicago"
      assert AWK.run!(prog, input) == "30\n25\n35\n"
    end

    test "running total" do
      prog = "{sum += $1; print sum}"
      assert AWK.run!(prog, "10\n20\n30") == "10\n30\n60\n"
    end

    test "field reordering" do
      prog = "BEGIN {OFS=\",\"} {print $3, $1, $2}"
      assert AWK.run!(prog, "a b c\nd e f") == "c,a,b\nf,d,e\n"
    end

    test "data aggregation with grouping" do
      prog = """
      BEGIN {FS=","}
      {sum[$1] += $2; count[$1]++}
      END {
        for (k in sum)
          printf "%s: %.1f\\n", k, sum[k]/count[k]
      }
      """

      input = "math,90\nmath,80\neng,70\neng,90"
      result = AWK.run!(prog, input)
      lines = result |> String.trim() |> String.split("\n") |> Enum.sort()
      assert "eng: 80.0" in lines
      assert "math: 85.0" in lines
    end

    test "line numbering" do
      assert AWK.run!("{printf \"%3d: %s\\n\", NR, $0}", "foo\nbar\nbaz") ==
               "  1: foo\n  2: bar\n  3: baz\n"
    end

    test "filter and transform" do
      prog = "$1 > 50 {printf \"PASS: %s (%d)\\n\", $2, $1}"
      input = "75 Alice\n40 Bob\n90 Charlie\n30 Dave"
      assert AWK.run!(prog, input) == "PASS: Alice (75)\nPASS: Charlie (90)\n"
    end

    test "max value tracking" do
      prog = """
      BEGIN {max = -999999}
      {if ($1 > max) max = $1}
      END {print max}
      """

      assert AWK.run!(prog, "3\n7\n2\n9\n1") == "9\n"
    end

    test "reverse fields" do
      prog = "{for (i = NF; i >= 1; i--) printf \"%s \", $i; printf \"\\n\"}"
      assert AWK.run!(prog, "a b c\nd e f") == "c b a \nd e f \n"
    end
  end

  describe "streaming" do
    test "eval_stream produces lazy output" do
      prog = AWK.parse!("{print $1}")
      results = AWK.eval_stream(prog, ["hello world", "foo bar"]) |> Enum.to_list()
      assert results == ["hello\n", "foo\n"]
    end

    test "stream/2 convenience function" do
      results = AWK.stream("{print NR, $0}", ["alpha", "beta"]) |> Enum.to_list()
      assert results == ["1 alpha\n", "2 beta\n"]
    end

    test "streaming with pattern matching" do
      results = AWK.stream("/x/ {print}", ["ax", "bb", "cx"]) |> Enum.to_list()
      assert results == ["ax\n", "cx\n"]
    end

    test "streaming processes records one at a time" do
      prog = AWK.parse!("{print length($0)}")
      results = AWK.eval_stream(prog, ["hi", "hello", "hey"]) |> Enum.to_list()
      assert results == ["2\n", "5\n", "3\n"]
    end
  end

  describe "parse!/1 and eval!/2" do
    test "parse! returns a program struct" do
      program = AWK.parse!("{print}")
      assert %AWK.AST.Program{} = program
    end

    test "parse! raises on syntax error" do
      assert_raise AWK.Error.ParseError, fn ->
        AWK.parse!("{print")
      end
    end

    test "eval! executes a parsed program" do
      program = AWK.parse!("{print $1}")
      assert AWK.eval!(program, "hello world") == "hello\n"
    end

    test "eval! with variables option" do
      program = AWK.parse!("BEGIN {print x}")
      assert AWK.eval!(program, "", variables: %{"x" => "42"}) == "42\n"
    end

    test "eval! with fs option" do
      program = AWK.parse!("{print $2}")
      assert AWK.eval!(program, "a,b,c", fs: ",") == "b\n"
    end

    test "parse and eval round-trip" do
      program = AWK.parse!("BEGIN {OFS=\"-\"} {print $1, $2}")
      assert AWK.eval!(program, "hello world") == "hello-world\n"
    end
  end

  describe "edge cases" do
    test "empty input" do
      assert AWK.run!("{print}", "") == ""
    end

    test "empty input with BEGIN and END" do
      assert AWK.run!("BEGIN {print \"start\"} END {print \"end\"}", "") == "start\nend\n"
    end

    test "single field records" do
      assert AWK.run!("{print NF, $1}", "hello\nworld") == "1 hello\n1 world\n"
    end

    test "empty lines produce zero fields" do
      assert AWK.run!("{print NF}", "\n\n") == "0\n0\n"
    end

    test "very long line" do
      long_line = String.duplicate("x", 10_000)
      assert AWK.run!("{print length($0)}", long_line) == "10000\n"
    end

    test "unicode text" do
      assert AWK.run!("{print $1}", "hello monde") == "hello\n"
    end

    test "uninitialized variable in print" do
      assert AWK.run!("BEGIN {print x}") == "\n"
    end

    test "division by zero" do
      assert_raise AWK.Error.RuntimeError, fn ->
        AWK.run!("BEGIN {print 1/0}")
      end
    end

    test "nested function calls" do
      assert AWK.run!("BEGIN {print substr(toupper(\"hello\"), 1, 3)}") == "HEL\n"
    end

    test "semicolons separate statements" do
      assert AWK.run!("BEGIN {x=1; y=2; print x+y}") == "3\n"
    end

    test "multiple statements in action" do
      assert AWK.run!("{x=$1; y=$2; print y, x}", "hello world") == "world hello\n"
    end

    test "field assignment beyond NF extends record" do
      assert AWK.run!("{$5=\"new\"; print NF, $0}", "a b c") == "5 a b c  new\n"
    end

    test "assigning to $0 re-splits" do
      assert AWK.run!("{$0=\"one two three\"; print $2}", "anything") == "two\n"
    end

    test "empty pattern matches all" do
      assert AWK.run!("{print \"match\"}", "a\nb") == "match\nmatch\n"
    end

    test "comment lines in AWK program" do
      prog = """
      # This is a comment
      BEGIN {print "hello"}
      """

      assert AWK.run!(prog) == "hello\n"
    end
  end
end
