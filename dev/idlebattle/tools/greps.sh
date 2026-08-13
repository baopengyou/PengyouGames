#!/bin/sh
# tools/greps.sh -- THE FOUR GREPS OF A.5, mechanised over the sim directory.
#
#   1  sim files contain ZERO references to Fog. or any view accessor      (A.3)
#   2  sim files contain ZERO references to local player identity          (A.2)
#   3  sim files contain NO float literals and NO "/" outside math.floor() (rule 1)
#   4  sim files contain NO pairs()                                        (rule 2)
#
# WHY EACH ONE MATTERS, in one line, because a checker nobody understands gets
# commented out the first time it is inconvenient:
#   1  fog is a render filter; a sim that can ask what is visible can branch on
#      what is visible, and the two clients do not have the same renderer state.
#   2  a sim that knows which side is "me" can behave differently on the two
#      machines -- the single most reliable way to desync a lockstep design.
#   3  floats round differently across Lua builds and CPUs; one last-bit
#      difference is a divergent match. "/" always produces a float in 5.1.
#   4  pairs() order depends on table addresses, which differ per machine and
#      per run, so any loop over it can apply the same effects in a different
#      order and produce a different state.
#
# Every match is made against tools/strip_lua.awk's output (comments and string
# literals blanked, line numbers preserved), so prose is never reported as code.
# The ONE exception is the "player" unit token, which is only ever an identity
# accessor as a string literal, so that check reads the raw source.
#
# FALSE POSITIVES ARE PREFERRED TO MISSES, and where a check is deliberately
# over-broad it says so in its own output. Nothing here is silenced by a
# per-line pragma on purpose: an exception mechanism is how these greps die.
#
#   usage: tools/greps.sh [simdir]      (default: the sibling sim/ directory)
#   exit:  0 = zero hits, 1 = at least one hit, 2 = the checker could not run

DIR=$(cd "$(dirname "$0")" && pwd)
SIM=${1:-$DIR/../sim}
STRIP="$DIR/strip_lua.awk"

if [ ! -d "$SIM" ]; then
  echo "greps.sh: no such sim directory: $SIM" >&2
  exit 2
fi
if [ ! -f "$STRIP" ]; then
  echo "greps.sh: missing $STRIP" >&2
  exit 2
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ibgreps) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
HITS="$TMP/hits"
: > "$HITS"

LIST="$TMP/files"
find "$SIM" -type f -name '*.lua' | sort > "$LIST"
NFILES=$(wc -l < "$LIST" | tr -d ' ')
if [ "$NFILES" -eq 0 ]; then
  # A checker that passes because it found nothing to check is worse than no
  # checker at all. The file list is DISCOVERED, never hardcoded: a hardcoded
  # list silently stops covering the next file somebody adds to sim/.
  echo "greps.sh: found no .lua files under $SIM" >&2
  exit 2
fi

# record <grep-number> <file> <line> <message>
record() {
  src=$2; ln=$3
  ctx=$(awk -v n="$ln" 'NR==n{sub(/^[ \t]+/,""); print; exit}' "$src")
  printf '  [grep %s] %s:%s  %s\n' "$1" "$src" "$ln" "$4" >> "$HITS"
  printf '            | %s\n' "$ctx" >> "$HITS"
}

# scan <grep-number> <haystack> <source> <ERE> <message>
scan() {
  n=$1; hay=$2; src=$3; pat=$4; msg=$5
  grep -nE "$pat" "$hay" 2>/dev/null | cut -d: -f1 | while read -r ln; do
    record "$n" "$src" "$ln" "$msg"
  done
}

while IFS= read -r f; do
  code="$TMP/$(basename "$f").stripped"
  awk -f "$STRIP" "$f" > "$code" || { echo "greps.sh: could not strip $f" >&2; exit 2; }

  # -- grep 1 -------------------------------------------------------------
  # Fog.Visible is the named accessor (A.3); the rest are the shapes a view
  # accessor takes if somebody renames it. Deliberately broad.
  scan 1 "$code" "$f" '(^|[^A-Za-z0-9_])Fog[[:space:]]*\.' 'view accessor: Fog.'
  scan 1 "$code" "$f" 'IBFog' 'view accessor: IBFog'
  scan 1 "$code" "$f" '(^|[^A-Za-z0-9_])(Visible|IsVisible|CanSee|Reveal)[[:space:]]*\(' 'view accessor: visibility predicate'
  scan 1 "$code" "$f" '(View|Render|Draw|Frame|Overlay|Tooltip)[A-Z]' 'view accessor: render-layer symbol'
  scan 1 "$code" "$f" '(^|[^A-Za-z0-9_])(UIParent|CreateFrame|GetTexture)' 'view accessor: WoW UI API'

  # -- grep 2 -------------------------------------------------------------
  # A.2: the sim computes both halves over side = 1 | 2 and may not know which
  # one is the local player.
  scan 2 "$code" "$f" 'FullName' 'identity: FullName'
  scan 2 "$code" "$f" '(^|[^A-Za-z0-9_])(myName|mySide|myIdx|localPlayer|localSide|thisPlayer|isMe|amHost|amI[A-Z])' 'identity: local-player variable'
  scan 2 "$code" "$f" '(^|[^A-Za-z0-9_])(UnitName|UnitGUID|UnitIsUnit|UnitIsPlayer|GetUnitName|GetRealmName)' 'identity: WoW unit API'
  # Over-broad ON PURPOSE: any identifier containing "player" in a sim file is
  # suspect, because sides are 1 and 2 and nothing else. A legitimate use does
  # not exist today; if one ever appears, rename it rather than weakening this.
  scan 2 "$code" "$f" '(^|[^A-Za-z0-9_])[Pp]layer' 'identity: the word "player" in sim code (over-broad by design)'
  # The unit token is only an identity accessor AS A STRING, so this one reads
  # the raw source, where a string literal has not been blanked.
  scan 2 "$f" "$f" "[\"']player[\"']" 'identity: the "player" unit token'

  # -- grep 3a ------------------------------------------------------------
  # Float literals. The leading (^|[^A-Za-z0-9_.]) keeps field access (a.b),
  # concat (x..1) and version-ish tokens out of the report.
  scan 3 "$code" "$f" '(^|[^A-Za-z0-9_.])[0-9]*\.[0-9]' 'float literal'
  scan 3 "$code" "$f" '(^|[^A-Za-z0-9_.])[0-9]+\.([^A-Za-z0-9_.]|$)' 'float literal (trailing dot)'
  scan 3 "$code" "$f" '(^|[^A-Za-z0-9_.])[0-9]+[eE][-+]?[0-9]' 'exponent literal (a float in every Lua)'
  scan 3 "$code" "$f" '0[xX][0-9a-fA-F]*[.pP]' 'hex float literal'

  # -- grep 3b ------------------------------------------------------------
  # Every "/" must sit directly inside a math.floor(...) call. A paren stack is
  # needed rather than a regex: the innermost enclosing open paren has to be the
  # floor call, so `floor(a * (100 + p) / 100)` passes and `(a / b)` does not.
  awk '
    { line = $0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "(") {
          pre = substr(line, 1, i - 1); tok = ""
          if (match(pre, /[A-Za-z0-9_.]+[ \t]*$/)) {
            tok = substr(pre, RSTART, RLENGTH); sub(/[ \t]+$/, "", tok)
          }
          depth++; st[depth] = (tok == "math.floor" || tok == "floor") ? 1 : 0
        } else if (c == ")") {
          if (depth > 0) depth--
        } else if (c == "/") {
          if (depth == 0 || st[depth] != 1) print NR
        }
      }
    }
  ' "$code" | while read -r ln; do
    record 3 "$f" "$ln" 'division outside math.floor(...)'
  done

  # A bare floor(...) is only acceptable as an alias of math.floor. If the file
  # divides inside floor() it must define that alias, or grep 3 is being passed
  # by a local function that is not math.floor at all.
  if grep -qE '(^|[^A-Za-z0-9_.])floor[[:space:]]*\(' "$code"; then
    if ! grep -qE '(^|[^A-Za-z0-9_.])floor[[:space:]]*=[[:space:]]*math\.floor' "$code"; then
      record 3 "$f" 1 'uses bare floor(...) without "local floor = math.floor"'
    fi
  fi

  # -- grep 4 -------------------------------------------------------------
  # ipairs is fine (ordered); pairs and next are not.
  scan 4 "$code" "$f" '(^|[^A-Za-z0-9_])pairs[[:space:]]*\(' 'pairs()'
  scan 4 "$code" "$f" '(^|[^A-Za-z0-9_])next[[:space:]]*\(' 'next() -- the same table-order hazard as pairs()'
  scan 4 "$code" "$f" '(^|[^A-Za-z0-9_])table\.sort[[:space:]]*\(' 'table.sort -- only safe with a total order that never compares table identity; verify by hand'
done < "$LIST"

N=$(grep '^  \[grep' "$HITS" 2>/dev/null | wc -l | tr -d ' ')
[ -n "$N" ] || N=0
if [ "$N" -eq 0 ]; then
  echo "A.5 greps: 0 hits over $NFILES sim file(s) in $SIM"
  exit 0
fi

echo "A.5 greps: $N hit(s) over $NFILES sim file(s) in $SIM"
cat "$HITS"
echo
echo "Each hit is a determinism or leakage hazard, not a style note. Fix the code;"
echo "do not add an exception to this script."
exit 1
