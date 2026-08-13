#!/bin/sh
# tools/comptest.sh -- "will this file behave identically under WoW's Lua 5.1 and
# under the 5.4/5.5 interpreter the harness runs on?"
#
# WHY A SEPARATE CHECKER FROM luac -p
# luac -p only proves the file PARSES under the interpreter you happen to have.
# The harness runs 5.5, where `goto`, `//`, `&`, `~`, `<<`, `table.unpack` and
# `math.type` all parse perfectly and then do not exist inside WoW. The failure
# would surface as a runtime error on a player's machine, or -- far worse -- as
# one client computing a different number from the other. Everything below is a
# construct that either does not exist in 5.1, does not exist in 5.4+, or means
# something different in the two.
#
# It also carries the DETERMINISM HAZARDS that are not syntax at all: any clock,
# any stdlib RNG, any I/O. Two clients that read a clock or roll math.random are
# running two different simulations by construction, whatever the greps say.
#
# Matching is against tools/strip_lua.awk's output, so the prose in these very
# files ("no goto", "no math.random") is not reported as code.
#
#   usage: tools/comptest.sh [dir ...]   (default: the sibling sim/ directory)
#   exit:  0 = clean (warnings may still be printed), 1 = at least one FAIL,
#          2 = the checker could not run

DIR=$(cd "$(dirname "$0")" && pwd)
STRIP="$DIR/strip_lua.awk"

if [ $# -eq 0 ]; then set -- "$DIR/../sim"; fi
if [ ! -f "$STRIP" ]; then echo "comptest.sh: missing $STRIP" >&2; exit 2; fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ibcomp) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
FAILS="$TMP/fail"; WARNS="$TMP/warn"
: > "$FAILS"; : > "$WARNS"

LIST="$TMP/files"
: > "$LIST"
for d in "$@"; do
  if [ ! -d "$d" ]; then echo "comptest.sh: no such directory: $d" >&2; exit 2; fi
  find "$d" -type f -name '*.lua' >> "$LIST"
done
sort -o "$LIST" "$LIST"
NFILES=$(wc -l < "$LIST" | tr -d ' ')
if [ "$NFILES" -eq 0 ]; then echo "comptest.sh: found no .lua files in $*" >&2; exit 2; fi

# emit <sink> <tag> <file> <line> <message>
emit() {
  ctx=$(awk -v n="$4" 'NR==n{sub(/^[ \t]+/,""); print; exit}' "$3")
  printf '  [%s] %s:%s  %s\n' "$2" "$3" "$4" "$5" >> "$1"
  printf '         | %s\n' "$ctx" >> "$1"
}

# hunt <sink> <tag> <haystack> <file> <ERE> <message>
hunt() {
  grep -nE "$5" "$3" 2>/dev/null | cut -d: -f1 | while read -r ln; do
    emit "$1" "$2" "$4" "$ln" "$6"
  done
}

while IFS= read -r f; do
  code="$TMP/$(basename "$f").stripped"
  awk -f "$STRIP" "$f" > "$code" || { echo "comptest.sh: could not strip $f" >&2; exit 2; }

  # ---- syntax and operators that do not exist in Lua 5.1 -----------------
  hunt "$FAILS" "5.1" "$code" "$f" '(^|[^A-Za-z0-9_])goto[[:space:]]' 'goto -- 5.2+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '::[A-Za-z_]' 'goto label -- 5.2+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '//' 'integer division // -- 5.3+ only; use math.floor(a / b)'
  hunt "$FAILS" "5.1" "$code" "$f" '<<|>>' 'bitwise shift -- 5.3+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '&' 'bitwise and -- 5.3+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '\|' 'bitwise or -- 5.3+ only'
  # "~=" is not-equal in every version and must not be reported.
  hunt "$FAILS" "5.1" "$code" "$f" '~([^=]|$)' 'bitwise not/xor -- 5.3+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '<[[:space:]]*(const|close)[[:space:]]*>' 'local attribute -- 5.4+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '(^|[^A-Za-z0-9_.])_ENV([^A-Za-z0-9_]|$)' '_ENV -- 5.2+ only'

  # ---- library functions missing from 5.1 --------------------------------
  hunt "$FAILS" "5.1" "$code" "$f" 'table\.(unpack|pack|move)' 'table.unpack/pack/move -- 5.2+; 5.1 spells it unpack(). Write a compat local.'
  hunt "$FAILS" "5.1" "$code" "$f" 'math\.(type|tointeger|maxinteger|mininteger|ult)' 'math.* integer API -- 5.3+ only'
  hunt "$FAILS" "5.1" "$code" "$f" 'string\.(pack|unpack|packsize)' 'string.pack family -- 5.3+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '(^|[^A-Za-z0-9_.])(rawlen|select[[:space:]]*\([[:space:]]*-)' 'rawlen / negative select -- 5.2+ only'
  hunt "$FAILS" "5.1" "$code" "$f" '(^|[^A-Za-z0-9_.])(bit32|utf8)[[:space:]]*\.' 'bit32 / utf8 library -- 5.2+ only, and absent from WoW'
  hunt "$FAILS" "5.1" "$code" "$f" 'coroutine\.(isyieldable|close|running)' 'coroutine.isyieldable/close/running -- 5.2+ semantics'

  # ---- library functions missing from 5.4+, i.e. the harness -------------
  # These are the mirror image: they work in WoW and break in CI, which is just
  # as bad, because then the harness cannot test the shipping code.
  hunt "$FAILS" "5.4" "$code" "$f" '(^|[^A-Za-z0-9_.])unpack[[:space:]]*\(' 'bare unpack() -- removed in 5.4. Write a compat local: local unpack = table.unpack or unpack'
  hunt "$FAILS" "5.4" "$code" "$f" '(^|[^A-Za-z0-9_.])(setfenv|getfenv|loadstring|module)[[:space:]]*\(' '5.1-only global -- removed in 5.2+'
  hunt "$FAILS" "5.4" "$code" "$f" 'math\.(pow|mod|log10)' 'math.pow/mod/log10 -- removed in 5.3+'
  hunt "$FAILS" "5.4" "$code" "$f" 'table\.(getn|setn|foreach|foreachi)' 'table.getn family -- removed in 5.2+'

  # ---- determinism hazards (rules 3 and 4) -------------------------------
  hunt "$FAILS" "det" "$code" "$f" 'math\.random(seed)?' 'math.random/randomseed -- different algorithm per Lua build; use sim/Rand.lua'
  hunt "$FAILS" "det" "$code" "$f" '(^|[^A-Za-z0-9_.])(os|io)[[:space:]]*\.' 'os.* / io.* in sim code -- a clock or I/O the other client does not have'
  hunt "$FAILS" "det" "$code" "$f" '(^|[^A-Za-z0-9_.])(GetTime|GetTimePreciseSec|GetServerTime|debugprofilestop|GetFramerate|time|date)[[:space:]]*\(' 'clock read -- the sim advances only by explicit tick() calls'
  hunt "$FAILS" "det" "$code" "$f" '(^|[^A-Za-z0-9_.])C_Timer[[:space:]]*\.' 'C_Timer -- wall-clock scheduling cannot be part of a deterministic sim'
  hunt "$FAILS" "det" "$code" "$f" '(^|[^A-Za-z0-9_.])collectgarbage[[:space:]]*\(' 'collectgarbage -- observing GC state makes behaviour machine-dependent'

  # ---- warnings: legal, but each one has bitten a lockstep sim before ----
  hunt "$WARNS" "warn" "$code" "$f" '(^|[^A-Za-z0-9_.])tostring[[:space:]]*\(' 'tostring on a number prints "3" in 5.1 and "3.0" in 5.3+. Never let it reach a hash or the wire.'
  hunt "$WARNS" "warn" "$code" "$f" 'string\.format' 'string.format %d/%g on a number differs across versions. Never let it reach a hash or the wire.'
  hunt "$WARNS" "warn" "$code" "$f" '(^|[^A-Za-z0-9_.])print[[:space:]]*\(' 'print() in sim code -- a side effect the other client does not perform'
  hunt "$WARNS" "warn" "$code" "$f" '(^|[^A-Za-z0-9_.])(#|\.\.)[[:space:]]*[0-9]' 'concatenating a number: 5.1 gives "3", 5.3+ can give "3.0"'

  # ---- require(): there is no require inside WoW -------------------------
  if grep -qE '(^|[^A-Za-z0-9_.])require[[:space:]]*\(' "$code"; then
    if grep -q 'IB_SIM_MODULES' "$code"; then
      ln=$(grep -nE '(^|[^A-Za-z0-9_.])require[[:space:]]*\(' "$code" | head -1 | cut -d: -f1)
      emit "$WARNS" "warn" "$f" "$ln" 'require() present but guarded by IB_SIM_MODULES; the WoW loader MUST populate that table before this file loads'
    else
      hunt "$FAILS" "5.1" "$code" "$f" '(^|[^A-Za-z0-9_.])require[[:space:]]*\(' 'unguarded require() -- WoW has no package loader'
    fi
  fi
done < "$LIST"

NF=$(grep -c '^  \[' "$FAILS" 2>/dev/null | tr -d ' '); [ -n "$NF" ] || NF=0
NW=$(grep -c '^  \[' "$WARNS" 2>/dev/null | tr -d ' '); [ -n "$NW" ] || NW=0

if [ "$NW" -gt 0 ]; then
  echo "comptest: $NW warning(s) -- legal in both versions, verify by hand:"
  cat "$WARNS"
  echo
fi

if [ "$NF" -eq 0 ]; then
  echo "comptest: 0 failures over $NFILES file(s) in $*"
  exit 0
fi

echo "comptest: $NF failure(s) over $NFILES file(s) in $*"
cat "$FAILS"
echo
echo "[5.1] breaks inside WoW. [5.4] breaks in this harness. [det] desyncs a real"
echo "match. None of the three is a style preference."
exit 1
