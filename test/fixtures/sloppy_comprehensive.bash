#!/opt/homebrew/bin/bash
# The sloppiest, most comprehensive bash script ever
# Exercises every builtin, operator, and quirk imaginable

# ARITHMETIC OPERATORS - all of them
x=5;y=3
echo "Basic: $((x+y)) $((x-y)) $((x*y)) $((x/y)) $((x%y)) $((x**y))"
echo "Bitwise: $((x&y)) $((x|y)) $((x^y)) $((~x)) $((x<<2)) $((x>>1))"
echo "Comparison: $((x<y)) $((x>y)) $((x<=y)) $((x>=y)) $((x==y)) $((x!=y))"
echo "Logical: $((x&&y)) $((x||y)) $((!x))"
echo "Ternary: $((x>y?1:0))"
echo "Comma: $((a=1,b=2,a+b))"
# Compound assignment
z=10;((z+=5));((z-=2));((z*=3));((z/=2));((z%=7))
echo "Compound: $z"
# Pre/post increment/decrement
n=5;echo "Pre++: $((++n)) Post++: $((n++)) now: $n"
n=5;echo "Pre--: $((--n)) Post--: $((n--)) now: $n"
# Bitwise compound
m=255;((m&=15));((m|=16));((m^=8));((m<<=1));((m>>=2))
echo "Bitwise compound: $m"

# let builtin
let "p=10+5" 'q=p*2' r=q/3
echo "let: $p $q $r"

# VARIABLE EXPANSION - every form
unset myvar;myvar="hello world"
echo "${myvar}" "${#myvar}" "${myvar:0:5}" "${myvar:6}" "${myvar:(-5)}"
echo "${myvar:-default}" "${myvar:=assigned}" "${myvar:+alternative}"
# Pattern removal
path="/usr/local/bin/bash"
echo "${path#*/}" "${path##*/}" "${path%/*}" "${path%%/*}"
# Pattern replacement
str="banana"
echo "${str/a/X}" "${str//a/X}" "${str/#b/X}" "${str/%a/X}"
# Case modification
word="hElLo"
echo "${word^}" "${word^^}" "${word,}" "${word,,}"
# Indirect reference
ref="myvar";echo "${!ref}"
# Default with error (comment out to not exit)
# echo "${nonexistent:?this would fail}"

# ARRAYS - indexed
arr=(one two three four five)
arr[10]="ten";arr+=("appended")
echo "Array: ${arr[@]} ${arr[*]}"
echo "Length: ${#arr[@]} Element: ${#arr[0]}"
echo "Indices: ${!arr[@]}"
echo "Slice: ${arr[@]:1:3}"
# Associative arrays
declare -A hash
hash["key1"]="value1";hash[key2]=value2;hash["key three"]="value three"
echo "Hash: ${hash[@]}"
echo "Keys: ${!hash[@]}"
unset 'hash[key2]'
echo "After unset: ${!hash[@]}"

# SPECIAL PARAMETERS
echo "Script: $0 Args: $# All: $@ Star: $*"
echo "PID: $$ PPID: $PPID"
true;echo "Exit status: $?"
echo "Options: $-"
# $! requires background job
sleep 0.01 & echo "Background PID: $!"
wait
echo "BASH_VERSION: $BASH_VERSION"
echo "RANDOM: $RANDOM LINENO: $LINENO SECONDS: $SECONDS"

# QUOTING - every style
echo 'single quotes: $HOME ~'
echo "double quotes: $HOME $(pwd)"
echo $'ANSI-C:\t\n\x41'
echo "backslash escape: \$HOME \`cmd\`"

# BRACE EXPANSION
echo {a,b,c}{1,2,3}
echo {1..5} {a..e} {10..1} {01..10}
echo {1..10..2} {a..z..5}
echo pre{fix,sent,tend}

# TILDE EXPANSION
echo ~ ~+ ~-

# COMMAND SUBSTITUTION
echo "Date: $(date +%Y)"
echo "Legacy: `echo backticks`"
echo "Nested: $(echo $(echo nested))"

# PROCESS SUBSTITUTION
diff <(echo "line1") <(echo "line1") && echo "Same"
cat <(echo "from process sub")

# HERE DOCUMENTS
cat <<EOF
Here doc with $myvar expansion
and $(echo command substitution)
EOF
cat <<'EOF'
Here doc NO expansion: $myvar $(pwd)
EOF
cat <<-EOF
	indented here doc (tabs stripped)
	second line
EOF
cat <<<'here string'

# REDIRECTION
echo "to stdout"
echo "to stderr" >&2
echo "to file" > /dev/null
echo "append" >> /dev/null
cat < /dev/null
# Multiple redirections
{ echo out; echo err >&2; } > /dev/null 2>&1
# File descriptor manipulation
exec 3>&1
echo "to fd 3" >&3
exec 3>&-

# PIPELINES
echo hello | cat | tr a-z A-Z
echo "Pipeline status: ${PIPESTATUS[@]}"
set -o pipefail
false | true;echo "Pipefail exit: $?"
set +o pipefail
# Pipe to while
echo -e "a\nb\nc" | while read line;do echo "Read: $line";done

# CONTROL FLOW - if/elif/else
if [ 1 -eq 1 ];then echo "if true"
elif [ 1 -eq 2 ];then echo "elif"
else echo "else";fi
# Compact form
if true;then echo "compact if";fi
# [[ ]] conditionals
[[ "hello" == h* ]] && echo "pattern match"
[[ "abc" < "abd" ]] && echo "string compare"
[[ -n "nonempty" && -z "" ]] && echo "string tests"
[[ 5 -gt 3 && 3 -lt 10 ]] && echo "numeric in [["
# (( )) conditionals
((5>3)) && echo "arithmetic conditional"

# LOOPS - for
for i in 1 2 3; do echo "for: $i";done
for i in {1..3};do echo "brace for: $i";done
for ((i=0;i<3;i++));do echo "C-style for: $i";done
for f in *.bash;do echo "glob for: $f";break;done
# while
count=0;while ((count<3));do echo "while: $count";((count++));done
# until
count=0;until ((count>=3));do echo "until: $count";((count++));done
# break and continue
for i in 1 2 3 4 5;do
  ((i==2)) && continue
  ((i==4)) && break
  echo "break/continue: $i"
done
# Nested loop break
for i in 1 2;do for j in a b;do
  echo "nested: $i$j"
  [[ $j == a ]] && continue 1
  break 2
done;done

# CASE statement
word="bar"
case $word in
  foo) echo "matched foo";;
  bar|baz) echo "matched bar or baz";&  # fallthrough
  qux) echo "also qux";;&  # continue matching
  *) echo "default";;
esac

# SELECT (commented out - requires interaction)
# select opt in one two three; do echo $opt; break; done

# FUNCTIONS
function func1 { echo "function keyword: $1"; }
func2() { echo "parens style: $1"; return 42; }
func1 "arg1"
func2 "arg2";echo "Return value: $?"
# Local variables
outer="global"
func3() { local outer="local"; echo "Inside: $outer"; }
func3;echo "Outside: $outer"
# Recursion
factorial() { (($1<=1)) && echo 1 && return;echo $(($1 * $(factorial $(($1-1))))); }
echo "Factorial 5: $(factorial 5)"

# TRAPS
trap 'echo "EXIT trap"' EXIT
trap 'echo "DEBUG trap"' DEBUG
# Run a command to trigger DEBUG
true
trap - DEBUG  # remove debug trap

# BUILTINS - comprehensive list
# echo, printf
printf "Printf: %s %d %x\n" "string" 42 255
printf -v formatted "Formatted: %05d" 7
echo "$formatted"

# read
echo "hello" | { read var; echo "read: $var"; }
echo "a:b:c" | { IFS=: read -a parts; echo "parts: ${parts[@]}"; }

# test / [ / [[
test -f /dev/null && echo "test -f works"
[ -d /tmp ] && echo "[ -d works"
[[ -e /dev/null ]] && echo "[[ -e works"

# true, false, :
true && echo "true works"
false || echo "false works"
: && echo "colon works"

# pwd, cd
oldpwd=$(pwd)
cd /tmp && echo "cd works: $(pwd)"
cd - > /dev/null
cd "$oldpwd"

# export, declare, local, readonly, unset
export EXPORTED_VAR="exported"
declare -i intvar=10
declare -r constvar="constant"
declare -l lowervar="UPPER";echo "lowercase: $lowervar"
declare -u uppervar="lower";echo "uppercase: $uppervar"
declare -a arrayvar=(1 2 3)
declare -A assocvar=([a]=1 [b]=2)
declare -p intvar 2>/dev/null | head -1

# set and shopt
set -e;set +e  # errexit
set -u;set +u  # nounset
set -o noclobber;set +o noclobber
shopt -s extglob;shopt -u extglob
shopt -s nullglob;shopt -u nullglob

# eval
evalcmd="echo evaluated"
eval $evalcmd

# command, builtin, type
command echo "command echo"
builtin echo "builtin echo"
type echo | head -1

# alias (limited in scripts)
shopt -s expand_aliases
alias ll='ls -la'
unalias ll 2>/dev/null  # might not work in script

# source / .
echo 'sourced_var=123' > /tmp/source_test.sh
source /tmp/source_test.sh
echo "Sourced: $sourced_var"
. /tmp/source_test.sh
rm /tmp/source_test.sh

# getopts
args="-a -b arg -c"
OPTIND=1
while getopts "ab:c" opt $args; do
  echo "getopts: $opt $OPTARG"
done

# shift
set -- one two three
echo "Before shift: $@"
shift
echo "After shift: $@"
shift 2 2>/dev/null || shift $#

# hash
hash -r 2>/dev/null  # clear hash table
hash cat 2>/dev/null  # hash a command

# umask
oldumask=$(umask)
umask 022
echo "umask: $(umask)"
umask $oldumask

# times (may show zeros)
times 2>/dev/null | head -1 || true

# wait
sleep 0.01 &
wait $!
echo "wait completed"

# jobs, bg, fg, disown (job control)
set -m 2>/dev/null || true  # enable job control
sleep 0.02 &
jobs 2>/dev/null || true
disown 2>/dev/null || true
set +m 2>/dev/null || true

# kill
sleep 100 &
pid=$!
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true

# dirs, pushd, popd
pushd /tmp > /dev/null
dirs
popd > /dev/null

# mapfile / readarray
echo -e "line1\nline2\nline3" | { mapfile -t lines; echo "mapfile: ${lines[@]}"; }

# printf -v
printf -v myprintf "formatted %d" 42
echo "printf -v: $myprintf"

# caller (in function)
showcaller() { caller 0 2>/dev/null || echo "caller: n/a"; }
showcaller

# enable
enable -n test 2>/dev/null || true
enable test 2>/dev/null || true

# help (truncated output)
help echo 2>/dev/null | head -1 || true

# EXTENDED GLOBBING
shopt -s extglob
touch /tmp/glob_{a,b,c,ab,abc}.txt 2>/dev/null || true
echo "Extended: /tmp/glob_?(a|b).txt"
ls /tmp/glob_?(a|b).txt 2>/dev/null || true
echo "Extended: /tmp/glob_*(a|b).txt"
ls /tmp/glob_*(a|b).txt 2>/dev/null || true
echo "Extended: /tmp/glob_+(a|b).txt"
ls /tmp/glob_+(a|b).txt 2>/dev/null || true
echo "Extended: /tmp/glob_@(a|b).txt"
ls /tmp/glob_@(a|b).txt 2>/dev/null || true
echo "Extended: /tmp/glob_!(ab).txt"
ls /tmp/glob_!(ab).txt 2>/dev/null || true
rm /tmp/glob_*.txt 2>/dev/null || true
shopt -u extglob

# GLOBSTAR
shopt -s globstar
mkdir -p /tmp/globtest/a/b/c
touch /tmp/globtest/a/b/c/file.txt
echo "Globstar: $(ls /tmp/globtest/**/file.txt 2>/dev/null | head -1)"
rm -rf /tmp/globtest
shopt -u globstar

# COPROCESS
coproc MYCP { cat; } 2>/dev/null
if [[ -n "${MYCP[1]:-}" ]]; then
  echo "hello coproc" >&${MYCP[1]}
  exec {MYCP[1]}>&-
  read -t 1 reply <&${MYCP[0]} && echo "Coproc reply: $reply"
  wait $MYCP_PID 2>/dev/null || true
else
  echo "Coproc: skipped"
fi

# NAMEREF
declare -n nameref=myvar
echo "Nameref: $nameref"
nameref="modified via nameref"
echo "Modified: $myvar"

# SUBSHELLS
(cd /tmp; echo "Subshell pwd: $(pwd)")
echo "Parent pwd: $(pwd)"
result=$(( subshell_var=42 ))
echo "Subshell arithmetic: $result"

# COMMAND GROUPING
{ echo "grouped"; echo "commands"; } | cat
( echo "subshell"; echo "group" ) | cat

# CONDITIONAL OPERATORS
true && echo "and-then"
false || echo "or-else"
! false && echo "negation"

# ARITHMETIC FOR LOOP edge cases
for ((;;)); do echo "infinite"; break; done
for ((i=0; i<1; )); do echo "no increment"; ((i++)); done

# STRING OPERATORS in [[
[[ "foobar" == *bar ]] && echo "suffix match"
[[ "foobar" == foo* ]] && echo "prefix match"
[[ "foobar" =~ ^foo ]] && echo "regex match"
[[ "foobar" =~ (foo)(bar) ]] && echo "regex groups: ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"

# SPECIAL ARRAY OPERATIONS
arr=(a b c d e)
echo "Array copy: ${arr[@]:0}"
echo "Array reverse iteration:"
for ((i=${#arr[@]}-1; i>=0; i--)); do echo "  ${arr[i]}"; done

# NEGATIVE ARRAY INDICES (Bash 4.3+)
arr=(1 2 3 4 5)
echo "Negative index: ${arr[-1]} ${arr[-2]}"

# UPPERCASE/LOWERCASE in parameter expansion
mixed="HeLLo WoRLD"
echo "First upper: ${mixed^}"
echo "All upper: ${mixed^^}"
echo "First lower: ${mixed,}"
echo "All lower: ${mixed,,}"

# PARAMETER TRANSFORMATION (Bash 5.1+)
arr=(one two three)
echo "Quoted: ${arr[@]@Q}"
echo "Escaped: ${arr[0]@E}"
echo "Prompt: ${arr[0]@P}" 2>/dev/null || true
echo "Assignment: ${arr[@]@A}"
echo "Attributes: ${arr[@]@a}"

# APPEND TO ARRAY
arr=()
arr+=(one)
arr+=(two three)
echo "Appended array: ${arr[@]}"

# MULTIPLE ASSIGNMENT
a=1 b=2 c=3
echo "Multi assign: $a $b $c"

# COMMAND AS ARRAY
cmd=(echo "hello" "world")
"${cmd[@]}"

# EMPTY EXPANSION
empty=""
echo "Empty expansion: [${empty:-}]"

# NULL BYTE HANDLING
printf 'before\0after' | cat -v

# WEIRD BUT VALID SYNTAX
echo $((
  1+
  2+
  3
))

# MULTIPLE SEMICOLONS (with commands between)
:;:;:; echo "after semicolons" ;:;:;:

# COMMENTS EVERYWHERE
echo "before" # inline comment
# standalone comment
echo "after" # another # inline # comment

# CONTINUATION LINES
echo \
  "continued" \
  "line"

# MULTILINE STRING
multiline="line 1
line 2
line 3"
echo "$multiline"

# COMMAND TERMINATION VARIATIONS
echo a; echo b
echo c & echo d
wait

# EMPTY COMMANDS (using no-op)
:
: ""
: : :

# SUBSHELL VARIABLE ISOLATION
outer=1
( outer=2; echo "inner: $outer" )
echo "outer after subshell: $outer"

# FUNCTION OVERRIDING BUILTINS (then restore)
echo() { builtin echo "WRAPPED: $@"; }
echo "custom echo"
unset -f echo
echo "normal echo"

# ARRAY SLICING EDGE CASES
arr=(0 1 2 3 4 5 6 7 8 9)
echo "Slice from 5: ${arr[@]:5}"
echo "Slice 2 from end: ${arr[@]:(-2)}"
echo "Slice 3 items from 2: ${arr[@]:2:3}"

# ARITHMETIC BASE CONVERSION
echo "Hex: $((16#FF))"
echo "Octal: $((8#77))"
echo "Binary: $((2#1010))"
echo "Base 36: $((36#ZZ))"

# FLOATING POINT VIA bc (not native)
echo "Float via bc: $(echo "scale=2; 10/3" | bc)"

# POSITIONAL PARAMETERS
set -- arg1 arg2 arg3
echo "All: $@"
echo "Count: $#"
echo "First: $1 Second: $2"

# IFS MANIPULATION
original_IFS="$IFS"
IFS=:
parts="a:b:c"
read -ra arr <<< "$parts"
echo "IFS split: ${arr[@]}"
IFS="$original_IFS"

# TRAP SIGNALS
trap 'echo "SIGINT caught"' INT
trap 'echo "SIGTERM caught"' TERM
# Trigger via kill would test this

# RETURN FROM SOURCED FILE
echo 'return 0' > /tmp/return_test.sh
source /tmp/return_test.sh && echo "source returned successfully"
rm /tmp/return_test.sh

# EXEC WITHOUT COMMAND (redirections only)
exec 4>&1
echo "to fd 4" >&4
exec 4>&-

# READONLY ARRAYS
declare -ra ro_arr=(one two three)
echo "Readonly array: ${ro_arr[@]}"

# DECLARE PRINT
declare -p myvar 2>/dev/null || true

# PARAMETER LENGTH ON ARRAYS
arr=(supercalifragilisticexpialidocious short)
echo "First length: ${#arr[0]}"
echo "Second length: ${#arr[1]}"
echo "Array count: ${#arr[@]}"

# ASSOCIATIVE ARRAY ITERATION
declare -A aa=([one]=1 [two]=2 [three]=3)
for key in "${!aa[@]}"; do
  echo "aa[$key]=${aa[$key]}"
done

# NESTED EXPANSION
var="PATH"
echo "Indirect: ${!var}"

# BASH 5 FEATURES
# Epoch seconds
echo "EPOCHSECONDS: ${EPOCHSECONDS:-not available}"
echo "EPOCHREALTIME: ${EPOCHREALTIME:-not available}"

# EXTENDED TEST OPERATORS
[[ -v myvar ]] && echo "-v: myvar is set"
[[ -R nameref ]] && echo "-R: nameref is a nameref" || true

# COMPLETED
echo "===================="
echo "All tests completed!"
echo "===================="

# Explicit exit
exit 0
