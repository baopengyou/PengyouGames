#!/bin/sh
# tools/m2.sh -- THE M2 GATE, sitting beside tools/ci.sh where gates live.
#
# WHY M2 IS A SIBLING OF ci.sh AND NOT A SIXTH STEP INSIDE IT. Both were
# considered; this is the reasoning, so nobody has to redo it.
#
#   1 THE TWO GATES ANSWER DIFFERENT QUESTIONS AND FAIL FOR DIFFERENT REASONS.
#     M1 asks "do two clients compute the same integers?" -- a correctness
#     property with exactly one acceptable answer. M2 asks "do these numbers
#     produce the match Part C describes?" -- a BALANCE property whose answer is
#     a distribution and whose target is a provisional document. Folding a
#     balance measurement into a correctness gate means a tuning question turns
#     the determinism gate red, and a determinism gate that is red for reasons
#     nobody intends to fix immediately is a gate people learn to ignore. That
#     is how M1's guarantee actually dies.
#
#   2 M2 IS RED RIGHT NOW, ON PURPOSE, AND M1 IS GREEN. And as of the fog pass
#     EVERY M2 NUMBER IN THE README IS VOID rather than merely red: the owner's
#     IDLE_BATTLE_FOG.md replaced the muster bar this roster was calibrated
#     against with nothing at all, and section 8.4 of that doc says in terms to
#     expect the distribution to move and to treat pre-fog measurements as void.
#     Run this gate to get the new numbers; do not quote the old ones. See the
#     README's M2 section, Findings 1, 2 and 8, and sweep/famstat.lua for why
#     the family clause may not be measurable at all. If M2 were a step of
#     ci.sh, the README's central
#     instruction -- "run tools/ci.sh and read the last line" -- would print RED
#     while every determinism property it names is intact. The one number a
#     future agent uses to decide whether the sim is trustworthy would stop
#     meaning that.
#
#   3 COST. ci.sh at 1,000 logs is the pre-commit gate for anything touching
#     sim/. M2 adds several minutes of match simulation -- two information
#     regimes, each a full round-robin, plus the policy determinism suite twice
#     -- that cannot tell you anything about a change to Hash.lua. Keeping it
#     out keeps the M1 loop fast, which is what keeps it run.
#
# RUN BOTH BEFORE CLAIMING ANYTHING. M2 green with M1 red means 1,632 matches
# were simulated by a sim that does not agree with itself.
#
#   tools/ci.sh              M1: determinism.        Run for any change to sim/.
#   tools/m2.sh              M2: the numbers.        Run for any change to
#                            sim/Rules.lua, policy/ or sweep/.
#
# The implementation lives in sweep/run.sh, which is the M2 tree's own entry
# point and stays the single definition of what the gate does. This file is the
# front door: a future engineer who knows tools/ci.sh exists will look for the
# next gate beside it, not three directories away.
#
#   usage: tools/m2.sh [seedsPerPair] [lua]
#     seedsPerPair  default 6 -> 1,632 matches at the shipped 17-line roster
#                   (C.6's own sample size was 1,440 at sixteen).
#                   1 gives 240, a smoke test, and the verdict says so.
#     lua           path to the interpreter (default /opt/homebrew/bin/lua)
#
# exit: 0 = every step passed, non-zero = at least one failed.

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
SEEDS=${1:-6}
LUA=${2:-/opt/homebrew/bin/lua}

if [ ! -f "$ROOT/sweep/run.sh" ]; then
  echo "m2.sh: missing $ROOT/sweep/run.sh -- M2 is NOT verified" >&2
  exit 2
fi

sh "$ROOT/sweep/run.sh" "$SEEDS" "$LUA"
rc=$?

echo
echo "=============================================================="
echo "M1 IS A SEPARATE GATE AND THIS RUN SAYS NOTHING ABOUT IT."
echo "  sh $DIR/ci.sh 1000"
echo "=============================================================="
exit $rc
