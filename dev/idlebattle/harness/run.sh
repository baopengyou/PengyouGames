#!/bin/sh
# harness/run.sh -- the one entry point. Runs every M1 check in order and exits
# non-zero on the first failure, so it is usable unchanged as a CI step.
#
#   usage: harness/run.sh [logs] [lua]
#     logs   randomised command logs for the milestone run (default 1000)
#     lua    path to the interpreter (default $IB_LUA, else /opt/homebrew/bin/lua)
#
# Order is deliberate: the cheap mechanical checks first, so a syntax error or a
# stray pairs() fails in a second rather than three minutes into the fuzzer.
#
#   1  luac -p over sim/ and harness/     does it even parse
#   2  the four greps of A.5              twice, by two independent checkers
#   3  selftest                           are the answers RIGHT (seconds)
#   4  replay of the hand-written log     does the CLI artifact path work
#   5  fuzz                               are the answers the SAME (the milestone)

set -e

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
LOGS=${1:-1000}
LUA=${2:-${IB_LUA:-/opt/homebrew/bin/lua}}
LUAC=$(dirname "$LUA")/luac

START=$(date +%s)

echo "== 1. syntax (luac -p) =="
for f in "$ROOT"/sim/*.lua "$DIR"/*.lua; do
  "$LUAC" -p "$f"
done
echo "  ok: $(ls "$ROOT"/sim/*.lua "$DIR"/*.lua | wc -l | tr -d ' ') files parse"

echo
echo "== 2. A.5 greps =="
"$LUA" "$DIR/greps.lua"
if [ -f "$ROOT/tools/greps.lua" ]; then
  # The sim author's own checker. Two independent implementations of the same
  # four greps: agreement is evidence, one checker alone is an assertion.
  "$LUA" "$ROOT/tools/greps.lua"
else
  echo "  NOTE: tools/greps.lua not present; ran the harness checker only"
fi

echo
echo "== 2b. ruleset coverage =="
# Both directions of rulesHash coverage: an order array naming a missing key
# (Rules already errors on that) AND a ruleset value that no order array names,
# which is silently unhashed and lets a mismatched peer pass the handshake.
if [ -f "$ROOT/tools/rulescover.lua" ]; then
  "$LUA" "$ROOT/tools/rulescover.lua"
else
  echo "  NOTE: tools/rulescover.lua not present"
fi

echo
echo "== 3. selftest (includes the committed golden hashes) =="
"$LUA" "$DIR/selftest.lua"

echo
echo "== 4. replay of the hand-written log =="
"$LUA" "$DIR/replay.lua" "$DIR/logs/hand.iblog" --brief

echo
echo "== 5. M1 MILESTONE: $LOGS randomised legal logs =="
"$LUA" "$DIR/fuzz.lua" "$LOGS"

END=$(date +%s)
echo
echo "M1 HARNESS: GREEN in $((END - START))s"
