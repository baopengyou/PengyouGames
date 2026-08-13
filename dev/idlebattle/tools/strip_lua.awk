# strip_lua.awk -- blank out every Lua comment and string literal, preserving
# line numbers AND column positions (every removed byte becomes a space).
#
# WHY THIS EXISTS
# The A.5 greps are about CODE. A naive `grep -n "pairs("` over sim/ reports the
# word "pairs()" in the comment that explains why pairs() is banned; a naive
# float-literal grep reports "Lua 5.1" in prose and "A.11.2" in a doc reference;
# a naive division grep reports every "and/or" written as "x/y" in a sentence.
# Those false positives are what make a checker get switched off, so both
# tools/greps.sh and tools/comptest.sh match against this filter's output and
# only fall back to the raw source where a string literal is itself the thing
# being looked for (the "player" unit token).
#
# Handles: -- line comments, --[[ ]] and --[==[ ]==] long comments, "..." and
# '...' short strings with backslash escapes, [[ ]] and [==[ ]==] long strings.
# Long forms carry state across lines.
#
# usage: awk -f strip_lua.awk FILE

function sp(k,   s, i) { s = ""; for (i = 0; i < k; i++) s = s " "; return s }
function mkcloser(lvl,   s, i) { s = "]"; for (i = 0; i < lvl; i++) s = s "="; return s "]" }

BEGIN { inlong = -1; closer = "" }

{
  line = $0; out = ""; i = 1; n = length(line)
  while (i <= n) {
    if (inlong >= 0) {
      rest = substr(line, i)
      idx = index(rest, closer)
      if (idx == 0) { out = out sp(n - i + 1); i = n + 1 }
      else {
        out = out sp(idx - 1 + length(closer))
        i = i + idx - 1 + length(closer)
        inlong = -1
      }
      continue
    }
    c = substr(line, i, 1)
    two = substr(line, i, 2)
    if (two == "--") {
      rest = substr(line, i + 2)
      if (match(rest, /^\[=*\[/)) {
        inlong = RLENGTH - 2; closer = mkcloser(inlong)
        out = out sp(2 + RLENGTH); i = i + 2 + RLENGTH
      } else {
        out = out sp(n - i + 1); i = n + 1
      }
      continue
    }
    if (c == "\"" || c == "'") {
      j = i + 1
      while (j <= n) {
        d = substr(line, j, 1)
        if (d == "\\") j = j + 2
        else if (d == c) break
        else j = j + 1
      }
      if (j > n) j = n
      out = out sp(j - i + 1); i = j + 1
      continue
    }
    if (c == "[") {
      rest = substr(line, i)
      if (match(rest, /^\[=*\[/)) {
        inlong = RLENGTH - 2; closer = mkcloser(inlong)
        out = out sp(RLENGTH); i = i + RLENGTH
        continue
      }
    }
    out = out c; i = i + 1
  }
  print out
}
