#!/bin/sh
# tools/ci.sh -- THE M1 GATE. Run this before claiming M1 still passes.
#
# It runs, in order:
#   1  tools/greps.sh      the four A.5 greps over sim/ AND over fog/
#   2  tools/comptest.sh   Lua 5.1 / 5.4 compatibility and determinism hazards,
#                          over sim/ and fog/
#   3  luac -p             every .lua file under sim/, fog/, tools/ and harness/
#                          parses
#   4  tools/run_all.sh    the tools harness: Rand selftest, greps.lua (an
#                          independent second implementation of check 1), smoke,
#                          mechanics, ruleset coverage, hash coverage, the A.2
#                          mirror test, and the M1 milestone itself -- N
#                          randomised command logs replayed to a bit-identical
#                          stateHash at every epoch.
#   4b tools/fogtest.lua   runs INSIDE step 4 (run_all.sh): every rule in
#                          ../docs/IDLE_BATTLE_FOG.md, proved one at a time
#                          against fog/Fog.lua, plus the assertions that keep
#                          the model out of the state hash. It is in the M1 gate
#                          rather than the M2 one because it is a CORRECTNESS
#                          property with one acceptable answer -- the same
#                          reason the M1/M2 split exists at all -- and because
#                          fog/ is held to the sim's determinism rules and a
#                          float or a pairs() in it is an M5 desync.
#
#   5  harness/run.sh      the harness/ tree. NOT redundant with step 4: it owns
#                          the ONLY invariant checks on unhashed derived state
#                          (runner.invariants -- cacheLevyFlat, cacheBankCap, the
#                          per-lane aura caches, u.lane/u.step, economy
#                          integrality), the ONLY mid-run command-arrival mode,
#                          which is what the wire actually does, and the ONLY
#                          committed golden hashes. A gate that skips it is green
#                          on any bug the two replays share -- delete the cache
#                          refresh in onBuildingDestroyed and steps 1-4 stay
#                          GREEN while this one goes red.
#
# Every step runs even if an earlier one failed, because when a change breaks
# three things at once you want to see all three. The exit code is non-zero if
# ANY step failed.
#
#   usage: tools/ci.sh [logs] [lua]
#     logs  randomised command logs for the milestone run (default 1000; the
#           milestone IS 1000, so anything less is a smoke test, and the summary
#           says so out loud)
#     lua   path to the interpreter (default /opt/homebrew/bin/lua). luac is
#           looked for beside it.
#
# The gate ends by printing what it did NOT verify -- 5.1 execution when no 5.1
# interpreter was used, and the cross-machine clause, which by construction needs
# a second machine. A green line that stays silent about those invites the
# milestone to be read as fully proven when two of its clauses are out of reach
# of any single run.

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
LOGS=${1:-1000}
LUA=${2:-/opt/homebrew/bin/lua}
LUAC=$(dirname "$LUA")/luac

FAILED=""
STEPS=0

step() {   # step <name> <command...>
  name=$1; shift
  STEPS=$((STEPS + 1))
  echo "=============================================================="
  echo "== $STEPS. $name"
  echo "=============================================================="
  if "$@"; then
    echo "-- $name: OK"
  else
    echo "-- $name: FAILED"
    FAILED="$FAILED $name"
  fi
  echo
}

if [ ! -x "$LUA" ] && ! command -v "$LUA" >/dev/null 2>&1; then
  echo "ci.sh: no Lua interpreter at $LUA" >&2
  echo "ci.sh: pass one as the second argument, e.g. tools/ci.sh 1000 /usr/bin/lua" >&2
  exit 2
fi

# The environment fingerprint. Two machines' gate runs have to be diffable
# MECHANICALLY, because Part E's milestone ("bit-identical on two machines with
# different CPUs") is otherwise checked by a human copying digits between
# terminals. rulesHash pins the ruleset, uname pins the hardware, and the
# interpreter version pins the arithmetic model.
LUAVER=$("$LUA" -v 2>&1 | head -1)
RULESHASH=$("$LUA" -e "package.path='$ROOT/?.lua;'..package.path;
  local R=require('sim.Rules'); local H=require('sim.Hash');
  io.write(H.dec(R.rulesHash),' (',R.rulesHash36,')')" 2>/dev/null)

echo "Idle Battle M1 gate"
echo "  root        $ROOT"
echo "  interpreter $LUA ($LUAVER)"
echo "  host        $(uname -srm) $(hostname 2>/dev/null)"
echo "  rulesHash   ${RULESHASH:-UNKNOWN}"
echo "  logs        $LOGS"
echo

# fog/ runs at the STRICTEST setting (mode "sim", the default) and passes with
# zero hits: fog/Fog.lua defines the model through a plain module table and never
# reaches for a render layer, a WoW API or a home-made visibility predicate, so
# even grep 1's accessor patterns find nothing in it. policy/ and sweep/ are
# CLIENTS of it and run in mode "client" from sweep/run.sh; tools/greps.sh's
# header argues the scope.
greps_all() {
  rc=0
  sh "$DIR/greps.sh" || rc=1
  sh "$DIR/greps.sh" "$ROOT/fog" || rc=1
  return $rc
}
step "A.5 greps over sim/ and fog/" greps_all
step "Lua 5.1 compatibility and determinism hazards" sh "$DIR/comptest.sh" "$ROOT/sim" "$ROOT/fog"

# luac -p over EVERY file, sim and tools alike. The tools are not held to the
# sim's determinism rules, but they still have to parse.
luac_all() {
  if [ ! -x "$LUAC" ] && ! command -v "$LUAC" >/dev/null 2>&1; then
    echo "  no luac at $LUAC -- syntax check skipped, which means M1 is NOT verified"
    return 1
  fi
  rc=0
  bad=$(mktemp) || return 1
  find "$ROOT/sim" "$ROOT/fog" "$DIR" "$ROOT/harness" -type f -name '*.lua' | sort | while IFS= read -r f; do
    short=$(echo "$f" | sed "s|$ROOT/||")
    if "$LUAC" -p "$f"; then
      echo "  ok   $short"
    else
      echo "  FAIL $short"
      echo "$short" >> "$bad"
    fi
  done
  if [ -s "$bad" ]; then rc=1; fi
  rm -f "$bad"
  return $rc
}
step "luac -p over every file" luac_all

# The harness. run_all.sh is the entry point; if it is ever removed, fall back
# to the milestone test on its own rather than silently reporting a green gate.
harness() {
  if [ -f "$DIR/run_all.sh" ]; then
    sh "$DIR/run_all.sh" "$LUA" "$LOGS"
  else
    echo "  run_all.sh missing -- running determinism.lua directly"
    "$LUA" "$DIR/determinism.lua" "$LOGS"
  fi
}
step "tools harness (M1 milestone: $LOGS logs x 6000 ticks)" harness

# harness/run.sh: selftest + replay + fuzz. It owns the ONLY invariant checks on
# unhashed derived state (runner.invariants), the ONLY mid-run command-arrival
# mode -- which is what the wire actually does -- and the ONLY committed golden
# hashes, which are the only thing here that can detect a PLATFORM disagreement
# rather than a self-inconsistency. A gate that skips it is green on any bug both
# replays share.
# NOTE: harness/run.sh takes (logs, lua) -- the REVERSE of run_all.sh.
harness_tree() {
  if [ ! -f "$ROOT/harness/run.sh" ]; then
    echo "  harness/run.sh missing -- M1 is NOT verified"
    return 1
  fi
  sh "$ROOT/harness/run.sh" "$LOGS" "$LUA"
}
step "harness/ tree (selftest, replay, fuzz: invariants + mid-run arrival + goldens)" harness_tree

echo "=============================================================="
if [ -n "$FAILED" ]; then
  echo "M1 GATE: RED --$FAILED"
  echo "=============================================================="
  exit 1
fi

# CAVEATS THE GATE CAN DETECT ABOUT ITSELF. A green line that does not name what
# it did NOT check invites the milestone to be read as fully proven when two of
# Part E's clauses are structurally out of reach of one machine's run.
CAVEATS=""
case "$LUAVER" in
  *5.1*) ;;
  *) CAVEATS="$CAVEATS
  * Lua 5.1 compatibility is STATIC ONLY. No 5.1 interpreter was used: this run
    was $LUAVER, and 5.1 was checked by comptest.sh and the greps, which read the
    source rather than executing it. Install lua5.1 and re-run
    'tools/ci.sh $LOGS \$(which lua5.1)' to close this." ;;
esac
CAVEATS="$CAVEATS
  * CROSS-MACHINE agreement is checked against COMMITTED goldens on this one host
    (harness/selftest.lua's rulesHash/stateHash/logDigest and harness/fuzz.lua's
    SUITE HASH). That catches a platform disagreement only once a SECOND machine
    runs the same command and compares the same numbers. Nothing here can prove
    it alone. Host: $(uname -srm), rulesHash ${RULESHASH:-UNKNOWN}."

if [ "$LOGS" -lt 1000 ] 2>/dev/null; then
  echo "M1 GATE: GREEN, but with $LOGS logs. The milestone is 1000."
  echo "not verified by this run:$CAVEATS"
  echo "=============================================================="
  exit 0
fi
echo "M1 GATE: GREEN ($STEPS/$STEPS steps, $LOGS logs)"
echo "not verified by this run:$CAVEATS"
echo "=============================================================="
exit 0
