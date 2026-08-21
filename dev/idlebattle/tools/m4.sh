#!/bin/sh
# tools/m4.sh -- THE M4 GATE, sitting beside ci.sh, m2.sh and m3.sh where
# gates live.
#
# WHY M4 IS A FOURTH SIBLING AND NOT A STEP INSIDE ci.sh. Same reasoning as
# m3.sh's header: this gate asks ci.sh's KIND of question (bit-identical
# determinism, one acceptable answer), so it could never turn ci.sh red for a
# tuning opinion -- but folding it in would put several minutes of transport
# scenarios into the pre-commit loop for coverage the M1 gate does not need:
# ci.sh proves the SIM deterministic under every arrival order, and this gate
# proves the RELIABILITY SHIM delivers exactly those arrivals over a channel
# that drops, delays, duplicates and reorders. Different layer, same style of
# verdict, own front door. Part E's milestone, verbatim:
#
#   "Two instances of the sim in one addon session, fed the same log through
#    a fake transport that can drop, delay and reorder messages on command.
#    MILESTONE: state hashes match at every epoch for 6,000 ticks with 10%
#    packet loss and up to 3 s of jitter. Rollback repairs every late
#    command. A forced deep desync is repaired by the Q full-log replay path
#    from tick 0 -- which requires both loadouts, and is the concrete
#    demonstration that Ruling 1 made recovery real."
#
# THE STEPS (harness/m4run.lua is the implementation):
#
#   0  net/ is held to the SIM'S OWN determinism rules -- the A.5 greps and
#      comptest run over it exactly as they run over sim/, because the
#      transport's verdicts and the shim's rollbacks decide sim outcomes,
#      and a pairs() or a clock in either is a desync with extra steps.
#   1  CODEC      A.11 round-trip for every message row, byte sizes asserted
#                 against A.11.3's own table (the 70-byte C batch is the
#                 protocol's largest message), malformed-input fuzz under
#                 pcall (reject, never crash), case-sensitivity of the kind
#                 letters, the transport's 255-byte hard error, and the
#                 transport reproducing its schedule from its seed.
#   2  MILESTONE  100 runs x 2 sims x up to 6,000 ticks at 10% loss, 1..30
#                 ticks of jitter, 10% reorder: every epoch hash equal
#                 between the two endpoints AND equal to a no-netcode
#                 reference run of the same issued atoms -- plus terminal
#                 hash, terminal tick and logDigest, all three ways, plus
#                 runner.invariants on both terminal sims. Rollback repairs
#                 every late command; escalation (M/Q) must NOT fire.
#   3  ROLLBACK   40 runs at 25% reorder + 5% duplication, every run
#                 REQUIRED to contain late commands (re-seeded by a fixed
#                 rule if not -- a run with zero late commands proves
#                 nothing). The A.12 boundary cases must all OCCUR and be
#                 counted: duplicate delivery, resend after the original,
#                 lost acks (backstop resends), commands lost until resent
#                 (N answered).
#   4  DEEP       12 runs, carded loadouts both sides. ep2's sim state is
#                 corrupted OUTSIDE the shim from tick 2600 until detection
#                 (recurring, because a one-off mutation is quietly healed
#                 by the next routine rollback -- measured, and worth
#                 knowing). Epoch-hash exchange must detect it, Q must fire
#                 and be answered, both sides rebuild from tick 0 -- which
#                 NEEDS both loadouts, asserted on the rebuilt sims -- and
#                 the finished match must be bit-identical to the reference.
#                 Every second run also wipes ep2's held peer history first,
#                 so the Q replay is load-bearing, not a formality.
#   5  STRESS     25 runs at 30% loss, 1..40 jitter, 20% reorder, 10%
#                 duplication. A.12's ladder (N -> backstop -> hash
#                 adjudication -> Q rebuild) may escalate as far as it
#                 needs; convergence to the reference is still asserted.
#
# TWO INTERPRETERS ARE THE POINT. Run this twice --
#
#   sh tools/m4.sh                      # Lua 5.x (native integers)
#   sh tools/m4.sh "$(which luajit)"    # LuaJIT (5.1 semantics, doubles)
#
# -- and compare the per-step SUITE HASH lines. They fold every terminal
# state, tick, digest, repair count and byte-size maximum of every run, so
# two interpreters printing the same hashes agreed on every repair decision
# of every match, not merely on the final states.
#
# WHAT A GREEN RUN DOES NOT PROVE, stated here rather than discovered:
#   * no real WoW channel: the transport is a model (seeded verdicts, tick
#     delays), not CHAT_MSG_ADDON. M5 is the first real message.
#   * no halt/resume: X/K/G/V are encoded, decoded and counted, never acted
#     on. That protocol is M6's milestone.
#   * one process, one host: both endpoints share one interpreter run. The
#     cross-interpreter comparison above is the strongest split available
#     before M5; cross-machine still needs a second machine.
#   * matchmaking rows OPEN/JOIN are deferred to M5 entirely.
#
#   usage: tools/m4.sh [lua]
#     lua  path to the interpreter (default /opt/homebrew/bin/lua)
#
# exit: 0 = every step passed, non-zero = at least one failed.

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
LUA=${1:-/opt/homebrew/bin/lua}

if [ ! -x "$LUA" ] && ! command -v "$LUA" >/dev/null 2>&1; then
  echo "m4.sh: no Lua interpreter at $LUA" >&2
  exit 2
fi
if [ ! -f "$ROOT/harness/m4run.lua" ]; then
  echo "m4.sh: missing harness/m4run.lua -- M4 is NOT verified" >&2
  exit 2
fi

LUAVER=$("$LUA" -v 2>&1 | head -1)
echo "Idle Battle M4 gate"
echo "  root        $ROOT"
echo "  interpreter $LUA ($LUAVER)"
echo "  host        $(uname -srm) $(hostname 2>/dev/null)"
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

# net/ is sim-affecting and held to the sim's own rules; the checkers
# DISCOVER their file lists, so a new net file is covered automatically.
step "A.5 greps over net/ (mode sim)" sh "$DIR/greps.sh" "$ROOT/net"
# review finding 6: the README's rule is BOTH grep implementations plus the
# dup-key/clock/RNG greps over every sim-affecting directory -- so run them.
step "A.5 greps over net/ (second implementation)" "$LUA" "$DIR/greps.lua" "$ROOT/net"
step "harness greps over net/" "$LUA" "$ROOT/harness/greps.lua" "$ROOT/net"
step "Lua 5.1 compatibility and determinism hazards over net/" sh "$DIR/comptest.sh" "$ROOT/net"

luac_net() {
  LUAC=$(dirname "$LUA")/luac
  if [ ! -x "$LUAC" ] && ! command -v "$LUAC" >/dev/null 2>&1; then
    echo "  no luac at $LUAC -- syntax check skipped, which means M4 is NOT verified"
    return 1
  fi
  rc=0
  for f in "$ROOT/net"/*.lua "$ROOT/harness/m4run.lua"; do
    short=$(echo "$f" | sed "s|$ROOT/||")
    if "$LUAC" -p "$f"; then
      echo "  ok   $short"
    else
      echo "  FAIL $short"
      rc=1
    fi
  done
  return $rc
}
step "luac -p over net/ and harness/m4run.lua" luac_net

step "codec: round-trip, budgets, malformed fuzz" "$LUA" "$ROOT/harness/m4run.lua" codec
step "MILESTONE: 100 runs at 10% loss, 1..30-tick jitter" "$LUA" "$ROOT/harness/m4run.lua" milestone 100
step "rollback: 40 runs, late commands required and repaired" "$LUA" "$ROOT/harness/m4run.lua" rollback 40
step "deep desync: forced corruption -> detect -> Q -> rebuild from 0" "$LUA" "$ROOT/harness/m4run.lua" deep 12
step "stress: 30% loss, escalation allowed, convergence still required" "$LUA" "$ROOT/harness/m4run.lua" stress 25

echo "=============================================================="
if [ -n "$FAILED" ]; then
  echo "M4 GATE: RED --$FAILED"
  echo "=============================================================="
  exit 1
fi

echo "M4 GATE: GREEN ($STEPS/$STEPS steps)"
echo "not verified by this run:
  * NO REAL CHANNEL. The transport is a seeded model of drop/delay/reorder/
    duplication; CHAT_MSG_ADDON, the Comm bucket and real refusal codes are
    M5 (and the Probe's field data feeds the constants).
  * NO HALT/RESUME. X/K/G/V round-trip through the codec but nothing acts on
    them; A.6-A.10 land in M6.
  * ONE PROCESS, ONE HOST. Run this same command under a second interpreter
    (and on a second machine) and compare the printed SUITE HASH lines; that
    comparison, not any single green run, is the cross-platform evidence.
  * NO CORRUPTION MODEL. The transport drops, delays, reorders and
    duplicates, but never flips bytes -- and A.11 has no checksum, so an
    in-flight corruption that lands on another legal message would be
    detected by the hash exchange yet is NOT recoverable (review finding 2).
    The real WoW channel is reliable transport, so this models it; it does
    not prove robustness against a corrupting channel.
  * The sim itself is proved by sh $DIR/ci.sh (M1-M3); this gate proves the
    shim DELIVERS that sim over a bad channel, not the sim."
echo "=============================================================="
exit 0
