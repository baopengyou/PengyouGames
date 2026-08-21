#!/bin/sh
# tools/m3.sh -- THE M3 GATE, sitting beside ci.sh and m2.sh where gates live.
#
# WHY M3 IS A THIRD SIBLING AND NOT A STEP INSIDE ci.sh. The same reasoning as
# m2.sh's header, applied the other way round: this gate and ci.sh ask the SAME
# kind of question (bit-identical determinism, one acceptable answer), so
# unlike M2 it could never turn ci.sh red for a tuning opinion -- what it would
# do instead is make the pre-commit loop several minutes longer for coverage
# ci.sh already samples. ci.sh's 1,000-log fuzz plays random 5-card loadouts in
# half its sample and the selftest replays every card alone through an arrival
# test; those are the FAST, sampled versions of the two halves below. This gate
# is the MILESTONE'S OWN SHAPE, run to certify M3 rather than to guard a
# commit:
#
#   1  CARDS     each of the 40 cards INDIVIDUALLY -- Part E's words -- in two
#                pairings (card-vs-empty, the minimal delta from the proven M1
#                game and the asymmetric-install case, A.2-mirrored to prove
#                it; card-mirror, two live copies of one mechanism), each at
#                the FULL 6,000 ticks through replay, reordered queueing and
#                mid-run arrival, on fixed seeds, with seeded verb atoms
#                injected for the three verb cards so their dispatch is
#                actually on the wire being replayed.
#   2  LOADOUTS  200 random legal 5-card loadouts on BOTH sides (the milestone
#                number), full length, same four arrival patterns, zero hash
#                mismatches allowed, every 8th pair A.2-mirrored, verb atoms
#                injected wherever a drawn side holds a verb card.
#   3  CLAMP     the saturation report over the same 200 drawn pairs: per
#                channel, the summed potential of every side's loadout against
#                its Q4 clamp, the saturating combinations named and counted
#                (D.2's warning population), plus the APPLIED-VALUE PROBE --
#                every drawn side that saturates unitCost deploys real Spears
#                on a fresh sim and the charged cost must equal independently
#                clamped arithmetic, proving the sim applies the clamp rather
#                than this tool asserting its own copy of it.
#   4  VERDICT   below, with hard exit codes.
#
# TWO INTERPRETERS ARE THE POINT. Run this twice --
#
#   sh tools/m3.sh 200                     # Lua 5.x (native integers)
#   sh tools/m3.sh 200 "$(which luajit)"   # LuaJIT (5.1 semantics, doubles)
#
# -- and compare the two printed CARDS/LOADOUTS SUITE HASHes. They fold every
# terminal stateHash, terminal tick, logDigest and accept tally of every run,
# so two interpreters printing the same two numbers agreed on every integer of
# every match. The hashes this produced on the shipped tree are recorded in
# the README's M3 section.
#
# WHAT A GREEN RUN DOES NOT PROVE, stated here rather than discovered:
#   * the four information cards' PERCEPTION effects (fog/Fog.lua). They are
#     render/policy-side by design (A.5 grep 1) and are proved by
#     tools/fogtest.lua sections 16-22 INSIDE the M1 gate; in this gate those
#     cards are the field-inert passengers the selftest pins them to be.
#   * cross-machine agreement. Everything here ran on one host; the suite
#     hashes exist so a second machine's run is a mechanical diff.
#   * balance. Whether 40 cards make a fair game is M2's kind of question and
#     needs open item 24's roster ruling first. This gate is correctness only.
#
#   usage: tools/m3.sh [loadouts] [lua]
#     loadouts  random dual-loadout pairs (default 200 -- the milestone; less
#               is a smoke test and the verdict says so)
#     lua       path to the interpreter (default /opt/homebrew/bin/lua)
#
# exit: 0 = every step passed, non-zero = at least one failed.

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
N=${1:-200}
LUA=${2:-/opt/homebrew/bin/lua}

if [ ! -x "$LUA" ] && ! command -v "$LUA" >/dev/null 2>&1; then
  echo "m3.sh: no Lua interpreter at $LUA" >&2
  exit 2
fi
if [ ! -f "$DIR/m3gate.lua" ]; then
  echo "m3.sh: missing $DIR/m3gate.lua -- M3 is NOT verified" >&2
  exit 2
fi

LUAVER=$("$LUA" -v 2>&1 | head -1)
echo "Idle Battle M3 gate"
echo "  root        $ROOT"
echo "  interpreter $LUA ($LUAVER)"
echo "  host        $(uname -srm) $(hostname 2>/dev/null)"
echo "  loadouts    $N"
echo

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

step "each of the 40 cards individually (vs-empty + mirror, 4 arrival patterns)" \
  "$LUA" "$DIR/m3gate.lua" cards
step "$N random 5-card loadouts on both sides (4 arrival patterns)" \
  "$LUA" "$DIR/m3gate.lua" loadouts "$N"
step "clamp-saturation report over the same $N pairs" \
  "$LUA" "$DIR/m3gate.lua" clamp "$N"

echo "=============================================================="
if [ -n "$FAILED" ]; then
  echo "M3 GATE: RED --$FAILED"
  echo "=============================================================="
  exit 1
fi

CAVEATS="
  * The perception half of Divination, Omen, Veil and the Shrine pulse is
    fog/policy-side and is proved by tools/fogtest.lua inside the M1 gate
    (sh $DIR/ci.sh), not here.
  * CROSS-MACHINE and cross-interpreter agreement is proved by comparing this
    run's two SUITE HASH lines against another run's. One green run alone
    proves self-consistency on one arithmetic.
  * Balance is M2's question (sh $DIR/m2.sh) and open item 24's ruling; a green
    M3 says the cards compute identically, not that they are fair.
  * D.3 CONFORMANCE. A green run proves the cards compute IDENTICALLY on both
    clients, not that they compute what D.3 says -- a card wrong the same way
    on both machines sails through every hash here. That the numbers are the
    DOCUMENT'S numbers is harness/selftest.lua's job (sections 12-21, one
    exact pin per card mechanism, inside sh $DIR/ci.sh)."

if [ "$N" -lt 200 ] 2>/dev/null; then
  echo "M3 GATE: GREEN, but with $N loadout pairs. The milestone is 200."
  echo "not verified by this run:$CAVEATS"
  echo "=============================================================="
  exit 0
fi
echo "M3 GATE: GREEN ($STEPS/$STEPS steps, 40 cards x 2 pairings, $N loadout pairs)"
echo "not verified by this run:$CAVEATS"
echo "=============================================================="
exit 0
