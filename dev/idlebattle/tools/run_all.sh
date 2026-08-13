#!/bin/sh
# tools/run_all.sh -- the M1 gate. Every check the milestone names, in order.
# Exits non-zero on the first failure, so it is usable as a CI step.
#
#   usage: tools/run_all.sh [lua] [logs]
#     lua   path to the interpreter (default /opt/homebrew/bin/lua)
#     logs  randomised command logs for the determinism run (default 1000)
#
# The four greps of A.5 run FIRST and from day one, per Part E.

set -e

DIR=$(cd "$(dirname "$0")" && pwd)
LUA=${1:-/opt/homebrew/bin/lua}
LOGS=${2:-1000}
LUAC=$(dirname "$LUA")/luac

echo "== syntax check (luac -p) =="
for f in "$DIR"/../sim/*.lua; do
  "$LUAC" -p "$f" && echo "  ok $(basename "$f")"
done

echo
echo "== A.5 greps (plus clock, RNG and Lua 5.1 compatibility) =="
"$LUA" "$DIR/greps.lua"

echo
echo "== smoke: Part C arithmetic landmarks =="
"$LUA" "$DIR/smoke.lua"

echo
echo "== mechanics: the rules random logs rarely reach =="
"$LUA" "$DIR/mechanics.lua"

echo
echo "== ruleset coverage: every ruleset value is inside rulesHash =="
"$LUA" "$DIR/rulescover.lua"

echo
echo "== hash coverage: every field moves the state hash =="
# NOT piped into tail. Under `set -e` a pipeline's status is the LAST command's,
# so `lua ... | tail -3` would report tail's success and swallow a real failure --
# turning a verbose check into a silent one.
quiet() {   # quiet <command...> : print only the tail, but still fail on failure
  out=$(mktemp) || return 1
  if "$@" > "$out" 2>&1; then
    tail -3 "$out"; rm -f "$out"
  else
    rc=$?
    cat "$out"; rm -f "$out"
    return $rc
  fi
}
quiet "$LUA" "$DIR/hashcover.lua"

echo
echo "== golden hashes: committed stateHash/logDigest for hand.iblog =="
# The ONLY check here that compares against a number written down rather than
# against another run of the same process. Everything else in this file is
# self-consistency, which cannot see an arithmetic difference between machines.
quiet "$LUA" "$DIR/../harness/selftest.lua"

echo
echo "== A.2 side symmetry: the mirrored match mirrors exactly =="
# 2000, not 100. The resolve-tick credit-ordering asymmetry showed up in exactly
# 1 of 2000 random logs, so a 100-log run reported A.2 as PASS while it was
# broken. The deterministic synthetic case inside mirror.lua catches that one
# every run; the random logs are what find the NEXT one.
"$LUA" "$DIR/mirror.lua" 2000

echo
echo "== M1 MILESTONE: $LOGS randomised logs, 6000 ticks, bit-identical =="
"$LUA" "$DIR/determinism.lua" "$LOGS"

echo
echo "M1 GATE: GREEN"
