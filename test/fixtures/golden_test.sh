#!/bin/bash
# Comprehensive Bash Integration Test
# This script exercises all implemented Bash features

echo "=== GOLDEN TEST START ==="

# 1. Comments
# This is a comment
echo "1. Comments: OK"

# 2. Simple commands
echo "2. Simple commands: OK"

# 3. Variable assignment and expansion
FOO="bar"
echo "3. Variables: FOO=$FOO"

# 4. Environment variables (export)
export BAZ=qux
echo "4. Export: BAZ=$BAZ"

# 5. Command substitution
RESULT=$(echo "command substitution")
echo "5. Command substitution: $RESULT"

# 6. Arithmetic expansion
NUM=$((5 + 3))
echo "6. Arithmetic: 5 + 3 = $NUM"

# 7. Arithmetic operations
let SUM=10+5
echo "7. Let: 10 + 5 = $SUM"

# 8. Array assignment
ARRAY=(one two three)
echo "8. Arrays: ${ARRAY[0]} ${ARRAY[1]} ${ARRAY[2]}"

# 9. Array expansion
echo "9. Array expansion: ${ARRAY[@]}"

# 10. Pipeline
echo "hello world" | wc -w
echo "10. Pipeline: word count = 2"

# 11. Redirection (stdout to file)
echo "redirect test" > /tmp/bash_test_redirect.txt
cat /tmp/bash_test_redirect.txt
echo "11. Redirect: OK"
rm -f /tmp/bash_test_redirect.txt

# 12. For loop (no trailing space)
echo -n "12. For loop:"
for i in 1 2 3; do
  echo -n " $i"
done
echo ""

# 13. While loop (no trailing space)
echo -n "13. While loop:"
COUNT=1
while [ $COUNT -le 3 ]; do
  echo -n " $COUNT"
  COUNT=$((COUNT + 1))
done
echo ""

# 14. If statement
if [ "test" = "test" ]; then
  echo "14. If statement: condition true"
else
  echo "14. If statement: condition false"
fi

# 15. If-elif-else
VAL=2
if [ $VAL -eq 1 ]; then
  echo "15. If-elif-else: val is 1"
elif [ $VAL -eq 2 ]; then
  echo "15. If-elif-else: val is 2"
else
  echo "15. If-elif-else: val is other"
fi

# 16. Test expressions
if [ -n "string" ]; then
  echo "16. Test -n: string is not empty"
fi

# 17. Test command [[ ]]
if [[ "abc" == "abc" ]]; then
  echo "17. Test [[...]]: strings match"
fi

# 18. Case statement
FRUIT="apple"
case $FRUIT in
  apple)
    echo "18. Case: found apple"
    ;;
  banana)
    echo "18. Case: found banana"
    ;;
  *)
    echo "18. Case: found other"
    ;;
esac

# 19. Function definition and call
my_function() {
  echo "19. Function: called successfully"
  return 42
}
my_function
RETVAL=$?
echo "19. Function return code: $RETVAL"

# 20. Function with parameters
greet() {
  echo "20. Function params: Hello $1"
}
greet "World"

# 21. Compound commands (&&)
echo "test" && echo "21. Compound &&: both executed"

# 22. Compound commands (||)
false || echo "22. Compound ||: second executed"

# 23. Compound commands (;)
echo -n "23. Compound ;: "; echo "both executed"

# 24. Logical AND in if
if [ 1 -eq 1 ] && [ 2 -eq 2 ]; then
  echo "24. Logical AND: both conditions true"
fi

# 25. Logical OR in if
if [ 1 -eq 2 ] || [ 2 -eq 2 ]; then
  echo "25. Logical OR: second condition true"
fi

# 26. Test file operators
touch /tmp/bash_test_file.txt
if [ -f /tmp/bash_test_file.txt ]; then
  echo "26. Test -f: file exists"
fi
rm -f /tmp/bash_test_file.txt

# 27. Test directory operators
if [ -d /tmp ]; then
  echo "27. Test -d: directory exists"
fi

# 28. Negation in test
if [ ! -f /nonexistent ]; then
  echo "28. Test negation: file does not exist"
fi

# 29. String comparison operators
if [ "abc" \< "def" ]; then
  echo "29. String comparison: abc < def"
fi

# 30. Numeric comparison operators
if [ 5 -gt 3 ]; then
  echo "30. Numeric comparison: 5 > 3"
fi

# 31. Multiple arithmetic operations
CALC=$((10 * 2 + 5 - 3))
echo "31. Arithmetic complex: 10 * 2 + 5 - 3 = $CALC"

# 32. Variable in arithmetic
X=5
Y=3
RESULT=$((X * Y))
echo "32. Arithmetic variables: $X * $Y = $RESULT"

# 33. Increment/decrement
N=10
N=$((N + 1))
echo "33. Increment: N++ = $N"

# 34. Subshell
(echo "34. Subshell: executed in subshell")

# 35. Subshell with variable isolation
OUTER="outer"
(OUTER="inner"; echo "35. Subshell inner: OUTER=$OUTER")
echo "35. Subshell outer: OUTER=$OUTER"

# 36. Exit codes
true
echo "36. Exit code true: $?"

# 37. Exit codes (false)
false
echo "37. Exit code false: $?"

# 38. Command existence check (type builtin)
if type echo >/dev/null 2>&1; then
  echo "38. Type builtin: echo is a builtin"
fi

# 39. Working directory (cd and pwd)
OLDPWD=$(pwd)
cd /tmp
NEWPWD=$(pwd)
echo "39. CD/PWD: changed to $NEWPWD"
cd "$OLDPWD"

# 40. Multiple variable assignments
A=1 B=2 C=3
echo "40. Multiple assignments: A=$A B=$B C=$C"

# 41. Variable in command
CMD="echo"
$CMD "41. Variable as command: OK"

# 42. Quoted strings
echo "42. Quoted strings: double and single"

# 43. Escape sequences (single quotes preserve literals)
echo '43. Escape sequences: $VAR `cmd`'

# 44. Empty variable
EMPTY=""
if [ -z "$EMPTY" ]; then
  echo "44. Test -z: variable is empty"
fi

# 45. Default value expansion
UNSET_VAR_TEST="${UNSET_DEFAULT_VAR:-default}"
echo "45. Default value: $UNSET_VAR_TEST"

# 46. String length
STR="hello"
LEN=${#STR}
echo "46. String length: $LEN"

# 47. Array length
ARR=(a b c d)
ARRLEN=${#ARR[@]}
echo "47. Array length: $ARRLEN elements"

# 48. For loop with array (no trailing space)
echo -n "48. For with array:"
for item in "${ARR[@]}"; do
  echo -n " $item"
done
echo ""

# 49. Nested if
if [ 1 -eq 1 ]; then
  if [ 2 -eq 2 ]; then
    echo "49. Nested if: both conditions true"
  fi
fi

# 50. For loop with range (brace expansion)
echo -n "50. For with range:"
for i in {1..3}; do
  echo -n " $i"
done
echo ""

# 51. Break statement
echo -n "51. Break:"
for i in 1 2 3 4 5; do
  if [ $i -eq 3 ]; then
    break
  fi
  echo -n " $i"
done
echo " (stopped at 3)"

# 52. Continue statement
echo -n "52. Continue:"
for i in 1 2 3 4 5; do
  if [ $i -eq 3 ]; then
    continue
  fi
  echo -n " $i"
done
echo " (skipped 3)"

# 53. Local variables in function
test_local() {
  local LOCALVAR="local_value"
  echo "53. Local inside: $LOCALVAR"
}
LOCALVAR="global_value"
test_local
echo "53. Local outside: $LOCALVAR"

# 54. Readonly variable
readonly CONSTVAR="constant"
echo "54. Readonly: $CONSTVAR"

# 55. Shift command
test_shift() {
  echo -n "55. Shift: first=$1"
  shift
  echo " after_shift=$1"
}
test_shift "A" "B"

# 56. Printf
printf "56. Printf: %s %d\n" "formatted" 42

# 57. Declare integer
declare -i INTVAR=5+3
echo "57. Declare -i: $INTVAR"

# 58. Nested loops
echo -n "58. Nested loops:"
for i in 1 2; do
  for j in a b; do
    echo -n " $i$j"
  done
done
echo ""

# 59. Case with glob pattern
TESTFILE="script.sh"
case $TESTFILE in
  *.sh)
    echo "59. Case glob: shell script"
    ;;
  *.txt)
    echo "59. Case glob: text file"
    ;;
esac

# 60. Append to array
APPENDARR=(first)
APPENDARR+=(second third)
echo "60. Array append: ${APPENDARR[@]}"

# 61. Associative array
declare -A ASSOC
ASSOC[key1]="value1"
ASSOC[key2]="value2"
echo "61. Associative array: ${ASSOC[key1]} ${ASSOC[key2]}"

# 62. Nested command substitution
NESTED=$(echo $(echo "nested"))
echo "62. Nested cmd sub: $NESTED"

# 63. Arithmetic in condition
if (( 5 > 3 )); then
  echo "63. Arithmetic condition: 5 > 3"
fi

# 64. Return value propagation
get_val() {
  echo "returned_value"
}
GOTVAL=$(get_val)
echo "64. Return value: $GOTVAL"

# 65. set -e effect (should continue in subshell)
(set -e; true; echo "65. set -e: reached end")

# 66. Brace expansion in command
echo 66. Brace expansion: {a,b,c}

# 67. Sequence expansion
echo 67. Sequence: {1..3}

echo "=== GOLDEN TEST END ==="
echo "Exit code: 0"
exit 0
