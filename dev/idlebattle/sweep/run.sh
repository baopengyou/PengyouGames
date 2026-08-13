#!/bin/sh
# sweep/run.sh -- THE M2 GATE. Run this before claiming M2 passes.
#
# It runs, in order:
#   1  tools/greps.sh AND tools/greps.lua over        the A.5 greps, both
#      policy/ and over sweep/                        implementations. greps.lua
#                                                     is the only one carrying
#                                                     grep 8 (duplicate key in a
#                                                     table constructor), which
#                                                     luac -p accepts and which
#                                                     shipped a line running a
#                                                     value its source did not
#                                                     declare.
#   2  tools/comptest.sh over policy/ and sweep/      5.1/5.4 + determinism
#   3  luac -p over both directories                  it parses
#   4  sweep/determinism.lua x2 (steps 4 and 5)       once per INFORMATION
#      (fog, then full)                               REGIME, because each is a
#                                                     different set of reads
#                                                     inside Policy.fillView.
#                                                     The POLICY layer's own M1:
#                                                     byte-identical atoms on a
#                                                     replay, isolation between
#                                                     matches, an exact mirror
#                                                     when the seats are swapped,
#                                                     and no order bypassing the
#                                                     sim's input gate
#   6  sweep/sweep.lua                                the round-robin against C.6,
#                                                     printed metric by metric,
#                                                     under the DEFAULT regime.
#                                                     INFORMATIONAL: it always
#                                                     exits 0, because a report
#                                                     that aborts on the first
#                                                     bad clause hides the ten
#                                                     metrics below it.
#   7  sweep/verdict.lua                              THE MILESTONE, asserted,
#                                                     under BOTH regimes with the
#                                                     FOGGED one as the gate. This
#                                                     is
#                                                     the step that can make the
#                                                     gate red.
#
# Steps 6 and 7 each re-run the same frozen seed schedule (sweep/measure.lua) in
# their own process. That is not waste: the report and the gate must produce the
# same numbers, and a divergence between two processes walking one seed schedule
# is a determinism bug in the policy layer that neither step could catch alone.
#
# WHY THE GREPS RUN OVER policy/ AND sweep/ AT ALL. They are written for sim/,
# and neither directory ships inside WoW. But a policy WRITES THE COMMAND LOG,
# so a policy that reads a clock or rolls math.random makes the two clients play
# two different matches while every M1 check stays green -- M1 is handed the log
# rather than generating it. Sim-affecting code is not only the code under sim/.
# The one concession is that the two CLI files may print; comptest reports that
# as a warning and not a failure, which is exactly the line tools/ draws too.
#
#   usage: sweep/run.sh [seedsPerPair] [lua]
#     seedsPerPair  default 6 -> 1,632 matches at the shipped 17-line roster
#                   (C.6's own sample size was 1,440 at sixteen).
#                   1 gives 272, which is a smoke test and says so.
#     lua           path to the interpreter (default /opt/homebrew/bin/lua)
#
# Every step runs even if an earlier one failed; the exit code is non-zero if any
# step failed. RUN tools/ci.sh TOO -- M2 must not have broken M1, and nothing in
# this file checks that.

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
SEEDS=${1:-6}
LUA=${2:-/opt/homebrew/bin/lua}
LUAC=$(dirname "$LUA")/luac

FAILED=""
STEPS=0

step() {
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
  echo "sweep/run.sh: no Lua interpreter at $LUA" >&2
  exit 2
fi

RULESHASH=$("$LUA" -e "package.path='$ROOT/?.lua;'..package.path;
  local R=require('sim.Rules'); local H=require('sim.Hash');
  io.write(H.dec(R.rulesHash),' (',R.rulesHash36,')')" 2>/dev/null)

echo "Idle Battle M2 gate"
echo "  root        $ROOT"
echo "  interpreter $LUA ($("$LUA" -v 2>&1 | head -1))"
echo "  host        $(uname -srm)"
echo "  rulesHash   ${RULESHASH:-UNKNOWN}"
echo "  seeds/pair  $SEEDS"
echo

# BOTH implementations of the greps, over both new sim-affecting directories.
# tools/greps.sh is the shell one; tools/greps.lua is the independent Lua one and
# is the only one that carries grep 8 (a duplicate key in one table constructor,
# which luac -p accepts and which shipped a defence line running a value its own
# source did not declare). Running one of the two over policy/ and sweep/ was the
# same gap the M1 gate exists to rule out for sim/.
# MODE "client", and the mode matters. policy/ and sweep/ are CLIENTS of the fog
# model, not the simulation, so grep 1 there is not "never mention Fog." -- that
# was vacuously true before fog/Fog.lua existed and would now be satisfied by
# renaming an import, which is a miss rather than a pass. In client mode grep 1
# instead demands that any file saying Fog. requires "fog.Fog", the single
# audited model, while every other grep-1 pattern (a home-made visibility
# predicate, a render-layer symbol, a WoW UI call) still fires. tools/greps.sh's
# header argues the scope in full. sim/ still runs in mode "sim" and must.
greps_both() {
  rc=0
  sh "$ROOT/tools/greps.sh" "$ROOT/policy" client || rc=1
  sh "$ROOT/tools/greps.sh" "$ROOT/sweep" client || rc=1
  sh "$ROOT/tools/greps.sh" "$ROOT/fog" || rc=1
  "$LUA" "$ROOT/tools/greps.lua" "$ROOT/policy" client || rc=1
  "$LUA" "$ROOT/tools/greps.lua" "$ROOT/sweep" client || rc=1
  "$LUA" "$ROOT/tools/greps.lua" "$ROOT/fog" || rc=1
  return $rc
}
step "A.5 greps over policy/, sweep/ and fog/, both implementations" greps_both
step "Lua 5.1 compatibility and determinism hazards" \
  sh "$ROOT/tools/comptest.sh" "$ROOT/policy" "$ROOT/sweep" "$ROOT/fog"

luac_all() {
  if [ ! -x "$LUAC" ] && ! command -v "$LUAC" >/dev/null 2>&1; then
    echo "  no luac at $LUAC -- syntax check skipped, so M2 is NOT verified"
    return 1
  fi
  rc=0
  # find, not a glob: a glob silently expands to the literal pattern when a
  # directory has no .lua in it, and the loop then "checks" a file that does not
  # exist. tools/ci.sh already uses this form; the two gates should not differ.
  for f in $(find "$ROOT/policy" "$ROOT/sweep" "$ROOT/fog" -name '*.lua' | sort); do
    if "$LUAC" -p "$f"; then
      echo "  ok   $(echo "$f" | sed "s|$ROOT/||")"
    else
      echo "  FAIL $(echo "$f" | sed "s|$ROOT/||")"
      rc=1
    fi
  done
  return $rc
}
step "luac -p over policy/, sweep/ and fog/" luac_all

step "policy determinism, FOG vision (replay, isolation, mirror, gate)" \
  "$LUA" "$DIR/determinism.lua" 40 fog
step "policy determinism, full vision (replay, isolation, mirror, gate)" \
  "$LUA" "$DIR/determinism.lua" 40 full

step "C.6 cross-check report ($SEEDS seeds per ordered pair)" \
  "$LUA" "$DIR/sweep.lua" "$SEEDS"

step "M2 milestone verdict" "$LUA" "$DIR/verdict.lua" "$SEEDS"

echo "=============================================================="
if [ -n "$FAILED" ]; then
  echo "M2 GATE: RED --$FAILED"
  echo
  echo "Before changing a number in sim/Rules.lua to close a clause -- which is a"
  echo "hard compatibility break under A.11.1 and invalidates every recorded match"
  echo "log -- establish that the clause is measurable and that the mechanism you"
  echo "are about to reprice is the one that moves it:"
  echo "  $LUA $DIR/famstat.lua      is the failing clause distinguishable from noise?"
  echo "  $LUA $DIR/probe.lua        what does one building cost against a control?"
  echo "  $LUA $DIR/probe.lua 6 Turtle-eco   ...and against a second control"
  echo "=============================================================="
  exit 1
fi
echo "M2 GATE: GREEN ($STEPS/$STEPS steps)"
echo "not verified by this run:"
echo "  * that M1 still passes. Run tools/ci.sh."
echo "  * whether the family-spread clause is measurable at four lines per family."
echo "    Run sweep/famstat.lua. It passing is not the same as it meaning anything."
echo "  * anything about HUMAN play. Seventeen scripted lines are seventeen"
echo "    scripted lines; C.6 says so about its own numbers too (F.1)."
echo "=============================================================="
exit 0
