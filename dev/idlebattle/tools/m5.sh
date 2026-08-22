#!/bin/sh
# tools/m5.sh -- THE M5 GATE, sitting beside ci.sh, m2.sh, m3.sh and m4.sh
# where gates live.
#
# WHY M5 IS A FIFTH SIBLING AND NOT A STEP INSIDE m4.sh. Same reasoning as
# every gate before it: one layer, one front door. ci.sh proves the SIM,
# m4.sh proves the RELIABILITY SHIM over a hostile channel; this gate proves
# the ADDON LAYER -- the comm bridge, matchmaking, the tick driver and the
# REAL BOARD that M5 part 2 put on top of them -- delivers that proven engine
# between two module instances end to end. Part E's milestone, verbatim:
#
#   "First playable, over the wire: register IB on Comm.lua. OPEN/JOIN/S/C/H
#    only. Party scope. Two real characters. Content per D.1. MILESTONE: a
#    complete 600-second match between two accounts, state hashes matching at
#    every heartbeat, total addon traffic for the match under 32 messages per
#    minute per player."
#
# What THIS run can prove of that is everything except "two real characters":
# the two module instances are real (the shipped Games/IdleBattle.lua, loaded
# twice), the engine is real, the lifecycle is real, and the bus is HOSTILE
# (loss, delay, reorder, duplication -- strictly worse than the real addon
# channel, which never loses in transit). The two-account clause needs two
# WoW clients and stays open below.
#
# THE STEPS:
#
#   1  SYNC        tools/syncaddon.sh --check: every engine copy inside the
#                  addon byte-identical to the headless original, the derived
#                  HandLog.lua identical to its sources, and the .toc engine
#                  block still loads headless with require() disabled,
#                  reproducing the committed goldens.
#   2  SYNTAX     luac -p over the game's addon file and this drive.
#   3  GLOBALS    the no-accidental-globals pass, by BYTECODE: luac -l -l
#                 lists every function in Games/IdleBattle.lua and the scan
#                 asserts ZERO writes through _ENV (SETTABUP ... _ENV). The
#                 addon convention is file-local state + the PG namespace;
#                 part 1's one documented global (IB_SIM_MODULES) lives in
#                 the generated Loader.lua, not here.
#   4  THE DRIVE  tools/ibshim.lua: two module instances over an in-memory
#                 bus that delivers STRINGS for every field, exactly as the
#                 real channel does. Selftest; OPEN -> lite -> invitation ->
#                 join -> handshake -> play; the board asserted on BOTH
#                 clients (slot geometry from the hashed constants, the
#                 side-2 MIRROR, the no-fog label, a Rules-derived tooltip,
#                 the queued-order ghost); concede/V, lockdown void, silence
#                 void; a COMPLETE 6,000-tick match over a bus that drops
#                 15%, delays 0.1..3.5 s, reorders and duplicates -- every
#                 unit kind and every first-playable building letter issued
#                 through the board by both seats, orders pressed ALL THE
#                 WAY TO THE CLOCK EDGE (the M5-review settle window keeps
#                 the endpoint splicing until both sides are quiescent),
#                 every late atom repaired by rollback through the bridge,
#                 ZERO settled hash mismatches with a floor of 30 real
#                 comparisons per client, both terminal sims bit-identical,
#                 per-client traffic under 32 messages/min; and phase D, a
#                 forced deep recovery -- 20 s inbound blackhole, the atom
#                 gap pushed past Q_GAP -- proving the Q leg of the BRIDGE
#                 (whispered request, broadcast replay) end to end.
#
#   usage: tools/m5.sh [lua]
#     lua  path to the interpreter (default /opt/homebrew/bin/lua)
#
# exit: 0 = every step passed, non-zero = at least one failed.

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
REPO=$(cd "$ROOT/../.." && pwd)
GAME="$REPO/dev/PengyouGamesDev/Games/IdleBattle.lua"
LUA=${1:-/opt/homebrew/bin/lua}

if [ ! -x "$LUA" ] && ! command -v "$LUA" >/dev/null 2>&1; then
  echo "m5.sh: no Lua interpreter at $LUA" >&2
  exit 2
fi
if [ ! -f "$GAME" ]; then
  echo "m5.sh: missing $GAME -- M5 is NOT verified" >&2
  exit 2
fi
if [ ! -f "$DIR/ibshim.lua" ]; then
  echo "m5.sh: missing tools/ibshim.lua -- M5 is NOT verified" >&2
  exit 2
fi

LUAVER=$("$LUA" -v 2>&1 | head -1)
echo "Idle Battle M5 gate"
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

step "engine copies in sync, .toc order loads, goldens reproduce" \
  sh "$DIR/syncaddon.sh" --check

luac_step() {
  LUAC=$(dirname "$LUA")/luac
  if [ ! -x "$LUAC" ] && ! command -v "$LUAC" >/dev/null 2>&1; then
    echo "  no luac at $LUAC -- syntax check skipped, which means M5 is NOT verified"
    return 1
  fi
  rc=0
  for f in "$GAME" "$DIR/ibshim.lua"; do
    short=$(echo "$f" | sed "s|$REPO/||")
    if "$LUAC" -p "$f"; then
      echo "  ok   $short"
    else
      echo "  FAIL $short"
      rc=1
    fi
  done
  return $rc
}
step "luac -p over Games/IdleBattle.lua and tools/ibshim.lua" luac_step

globals_step() {
  LUAC=$(dirname "$LUA")/luac
  if [ ! -x "$LUAC" ] && ! command -v "$LUAC" >/dev/null 2>&1; then
    echo "  no luac at $LUAC -- the bytecode scan cannot run"
    return 1
  fi
  # -l -l lists EVERY function's bytecode; a write through _ENV in any of
  # them is an accidental global. Zero is the only acceptable answer.
  hits=$("$LUAC" -p -l -l "$GAME" | grep 'SETTABUP.*_ENV')
  if [ -n "$hits" ]; then
    echo "  GLOBAL WRITES FOUND in Games/IdleBattle.lua:"
    echo "$hits" | sed 's/^/    /'
    return 1
  fi
  echo "  0 writes through _ENV across every function of Games/IdleBattle.lua"
  return 0
}
step "no accidental globals in Games/IdleBattle.lua (bytecode scan)" globals_step

step "two-client drive: lifecycle, board, every order kind, full lossy match" \
  "$LUA" "$DIR/ibshim.lua" "$REPO"

echo "=============================================================="
if [ -n "$FAILED" ]; then
  echo "M5 GATE: RED --$FAILED"
  echo "=============================================================="
  exit 1
fi

echo "M5 GATE: GREEN ($STEPS/$STEPS steps)"
echo "not verified by this run:
  * TWO REAL CHARACTERS. The milestone's own clause. Both module instances
    ran in one interpreter over a stubbed platform; the real CHAT_MSG_ADDON
    channel, the shipped Comm.lua bucket/queue, server throttles, lockdown
    boundaries and cross-account timing need two logged-in WoW clients.
  * /pgd ib selftest ON WOW LUA. The selftest ran GREEN here under the gate
    interpreter (see the header), but its whole point is the WoW client's
    own interpreter: run it in game on every machine that will play.
  * PIXELS. Fonts, textures, colors, anchors, the scale grip, the overlap
    solver, Safety hide/resume and tooltip rendering are real Widgets.lua /
    Theme.lua / Blizzard code paths the stubs only shape-check. The board's
    LOGIC (what is drawn where, from which sim fields, mirrored per seat) is
    asserted; how it LOOKS is not.
  * THE REVEAL STAGE PLAYBACK. The result payloads are built and captured
    (titles, rows, personal flags asserted); the stage animation itself is
    Theme.lua on a real client.
  * THE SETTLE WINDOW'S REAL-WORLD TIMING. The clock-edge window itself is
    closed (the M5-review settle window; the drive now issues to tick 5,960
    and converges), but SETTLE_MIN/SETTLE_MAX are tuned against this bus's
    0.1..3.5 s delays -- the raid-night probe's measured latencies are what
    confirm those two constants on the live channel.
  * ci.sh / m2.sh / m3.sh / m4.sh own the engine. This gate proves the ADDON
    LAYER above them; run those gates for the sim and the shim themselves."
echo "=============================================================="
exit 0
