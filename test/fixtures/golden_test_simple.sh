#!/bin/bash
# Simplified Bash Golden Test
# Only uses currently implemented features

echo "=== GOLDEN TEST START ==="

# 1. Comments work
# This is a comment
echo "1. Comments: OK"

# 2. Simple commands
echo "2. Simple commands: OK"

# 3. Variable assignment and expansion
FOO="bar"
echo "3. Variables: $FOO"

# 4. Arithmetic expansion
NUM=$((5 + 3))
echo "4. Arithmetic: $NUM"

# 5. Let command
let SUM=10+5
echo "5. Let: $SUM"

# 6. Array assignment
ARRAY=(one two three)
echo "6. Arrays: ${ARRAY[0]} ${ARRAY[1]} ${ARRAY[2]}"

# 7. Pipeline
echo "hello world" | wc -w

# 8. For loop
for i in 1 2 3; do
  echo "$i"
done

# 9. While loop
COUNT=1
while [ $COUNT -le 3 ]; do
  echo "$COUNT"
  COUNT=$((COUNT + 1))
done

# 10. If statement
if [ "test" = "test" ]; then
  echo "10. If: true"
fi

# 11. If-else
VAL=2
if [ $VAL -eq 2 ]; then
  echo "11. If-else: equals 2"
else
  echo "11. If-else: not 2"
fi

# 12. Case statement
FRUIT="apple"
case $FRUIT in
  apple)
    echo "12. Case: apple"
    ;;
  banana)
    echo "12. Case: banana"
    ;;
esac

# 13. Function
my_func() {
  echo "13. Function: OK"
}
my_func

# 14. Compound &&
echo "test" && echo "14. Compound &&: OK"

# 15. Compound ||
false || echo "15. Compound ||: OK"

# 16. Test operators
if [ 5 -gt 3 ]; then
  echo "16. Test -gt: OK"
fi

# 17. Negation
if [ ! -f /nonexistent ]; then
  echo "17. Negation: OK"
fi

# 18. Arithmetic with variables
X=5
Y=3
RESULT=$((X * Y))
echo "18. Arithmetic vars: $RESULT"

# 19. Subshell
(echo "19. Subshell: OK")

# 20. Multiple assignments
A=1
B=2
C=3
echo "20. Assignments: $A $B $C"

echo "=== GOLDEN TEST END ==="
