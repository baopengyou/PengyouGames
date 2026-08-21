#!/bin/sh
# Offline verification for Games/MythicParley.lua. Needs luajit (WoW is Lua 5.1).
#
# The module's file scope only defines things and registers an init callback, and
# its init hands onMessage to PG.Comm.Register - so a stub Comm captures the wire
# handler and the whole game can be driven from outside with no client at all.
# Each "client" is a separate load of the file against a separate PG table, which
# is what makes the two-client convergence test in converge.lua mean anything.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
echo "--- wire, card codec, gates and settlement ---"
luajit tools/parley/wire.lua "$ROOT"
echo
echo "--- LOCK convergence, and the bookie's whole M+ path ---"
luajit tools/parley/converge.lua "$ROOT"
