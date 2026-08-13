-- sweep/verdict.lua -- THE M2 GATE. Part E's milestone, asserted, nothing else.
--
--   "1,000 simulated matches terminate -- by razed keep or by clock --
--    reproducing C.6 within a few points: median 380-430 s, >=75% inside the
--    5-10 minute band, >=80% decided by a razed keep, family spread under 10pp."
--
-- WHY THIS IS A SEPARATE FILE FROM sweep.lua. A gate and a report want opposite
-- things. A report must print everything and never abort, or the reader loses
-- the eleven metrics below the first bad one. A gate must be one screen, must
-- exit non-zero, and must not be something CI has to parse prose out of. Merging
-- them produces a file that either stops printing halfway down or never fails.
--
-- It re-runs the round-robin rather than reading sweep.lua's output, and that is
-- deliberate: the two programs then walk the SAME frozen seed schedule
-- (sweep/measure.lua) through separate processes, so a number that differs
-- between the report and the gate is a determinism bug in the policy layer that
-- neither file could have caught alone. They cost ~45 s each; the M2 gate is not
-- on anybody's edit loop.
--
-- TWO INFORMATION REGIMES, AND THE GATE IS THE FOGGED ONE. Part E's milestone
-- is a claim about matches PEOPLE play, so the column it is judged on is the one
-- where the lines see what ../docs/IDLE_BATTLE_FOG.md renders. The
-- full-information column -- Ruling 1's shared state, unfiltered, which is what
-- M2's first pass silently measured -- is printed beside it as the UPPER BOUND
-- and is not gated on. Both are printed because the difference between them is
-- larger than the margin on two of the clauses, so a published number that does
-- not say which regime produced it is not a number anyone can act on.
--
--   usage: lua sweep/verdict.lua [seedsPerPair] [seedBase] [vision]
--          seedsPerPair  default 6 (1,440 matches, C.6's own sample size).
--                        The milestone is 1,000 matches, so a smaller run is a
--                        smoke test and the verdict says so out loud.
--          seedBase      default 500000. Changing ONLY this re-rolls every
--                        match against the same roster, which is how a clause
--                        is checked for being seed luck.
--          vision        "both" (default), "fog" or "full". "both" runs the
--                        round-robin twice and costs twice as long; the gate is
--                        the fogged column either way.
--
-- exit: 0 = every clause passed, non-zero = at least one failed.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local Fog = IB_SIM_MODULES and IB_SIM_MODULES.Fog or require("fog.Fog")
local measure = IB_SIM_MODULES and IB_SIM_MODULES.measure or require("sweep.measure")

local floor = math.floor
local format = string.format

local SEEDS = tonumber(arg and arg[1]) or 6
local SEEDBASE = tonumber(arg and arg[2]) or measure.SEED_BASE
local VISION = (arg and arg[3]) or "both"
if VISION ~= "both" and VISION ~= Policy.VISION_FOG and VISION ~= Policy.VISION_FULL then
  error("verdict: vision must be both / " .. Policy.VISION_FOG
    .. " / " .. Policy.VISION_FULL, 0)
end

local T = measure.TARGET
local secs = measure.secs

local function pmStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%d%%", neg and "-" or "", whole, a - whole * 10)
end

print("Idle Battle M2 verdict -- Part E's milestone, asserted")
print(format("  rulesHash   %s (%s)", Hash.dec(Rules.rulesHash), Rules.rulesHash36))
print(format("  seeds       base %d, %d per ordered pair", SEEDBASE, SEEDS))
print(format("  cadence     poll %d ticks, <= %d orders/poll = %d atoms/min (A.11.4 %d)",
  Policy.POLL, Policy.MAX_ORDERS_PER_POLL,
  Policy.CEILING_ATOMS_PER_MIN, Policy.WIRE_ATOMS_PER_MIN))
print(format("  fog         %d sections of %d units per lane; %d always visible, "
  .. "enemy units rendered from %d",
  Fog.SECTIONS, Fog.SECTION_LEN, Fog.OWN_SECTIONS, Fog.DEFAULT_SIGHT))
print("  NOTE        the muster bar is GONE (IDLE_BATTLE_FOG.md section 8.1) and")
print("              every pre-fog M2 number in the README is void, not a baseline.")

local function runAt(mode)
  Policy.setVision(mode)
  return measure.roundRobin({ seeds = SEEDS, seedBase = SEEDBASE })
end

-- The GATE regime is the fogged one unless the caller explicitly asks for the
-- other: Part E's milestone is a claim about matches people play, and
-- IDLE_BATTLE_FOG.md is what they are shown. `full` is the upper bound and is
-- printed beside it.
local gate, upper
if VISION == Policy.VISION_FULL then
  gate = runAt(Policy.VISION_FULL)          -- gate on the upper bound, and say so
elseif VISION == Policy.VISION_FOG then
  gate = runAt(Policy.VISION_FOG)
else
  gate = runAt(Policy.VISION_FOG)
  upper = runAt(Policy.VISION_FULL)
end

print(format("  matches     %d per regime", gate.nMatches))
print(format("  GATED ON    %s%s", gate.vision,
  upper and "   (\"full\" printed beside it as the upper bound, not gated)" or ""))
print("")

local bad, nBad = {}, 0
local function clause(ok, name, measured, target, other)
  print(format("  %-4s  %-32s %-14s %-14s %s",
    ok and "PASS" or "FAIL", name, measured, other or "", target))
  if not ok then nBad = nBad + 1; bad[nBad] = name end
end

print(format("  %-4s  %-32s %-14s %-14s %s",
  "", "clause", gate.vision .. " (GATE)", upper and "full" or "", "milestone"))
print("  ------------------------------------------------------------------------------")

local function u(f) if upper == nil then return nil end return f(upper) end

clause(gate.nMatches >= T.matchesMin, "matches simulated",
  format("%d", gate.nMatches), format(">= %d", T.matchesMin),
  u(function(x) return format("%d", x.nMatches) end))
-- STRUCTURALLY UNFAILABLE AT DEFAULT SETTINGS, and said so out loud below, so
-- nobody reads it as an independent measurement: the driver ticks to maxTicks
-- and the sim resolves the clock at MATCH_TICKS, so `over` is set on every path.
-- The clause is kept as cheap insurance against a future maxTicks regression,
-- and the sibling assertion -- that every match is accounted for by exactly one
-- of the two termination reasons -- is the part that can actually fail.
clause(gate.nUnfinished == 0 and (gate.nKeep + gate.nClock) == gate.nMatches,
  "every match terminated",
  format("%d unfin", gate.nUnfinished),
  "0 unfin, keep+clock==n",
  u(function(x) return format("%d unfin", x.nUnfinished) end))
clause(gate.median >= T.medianLo and gate.median <= T.medianHi,
  "median match length", format("%d s", secs(gate.median)),
  format("%d-%d s", secs(T.medianLo), secs(T.medianHi)),
  u(function(x) return format("%d s", secs(x.median)) end))
clause(gate.bandPm >= T.bandPctMin,
  "inside the 5-10 minute band", pmStr(gate.bandPm),
  format(">= %s", pmStr(T.bandPctMin)),
  u(function(x) return pmStr(x.bandPm) end))
clause(gate.keepPm >= T.keepPctMin,
  "decided by a razed keep", pmStr(gate.keepPm),
  format(">= %s", pmStr(T.keepPctMin)),
  u(function(x) return pmStr(x.keepPm) end))
clause(gate.famSpread < T.familySpreadMax,
  "family spread", pmStr(gate.famSpread),
  format("< %s", pmStr(T.familySpreadMax)),
  u(function(x) return pmStr(x.famSpread) end))

-- Not in Part E's wording, and it belongs here anyway: a sweep whose policies
-- can reach past the sim's input gate measures nothing at all, so every clause
-- above is conditional on this one.
--
-- FIVE COUNTERS AND A RATE, not three. `refused/badKind/badTarget` catch an
-- order the sim or the gate could not express. They do NOT catch the two ways a
-- line can be silently rewritten before the sim ever sees it: `declinedRate`
-- (the driver threw away everything past MAX_ORDERS_PER_POLL, so the sweep
-- measured a throttled version of the strategy) and `clamped` (a count outside
-- 1..MAX_UNITS_PER_ORDER was silently trimmed). And none of the five catch a
-- line that stays inside the per-poll cap while still exceeding A.11.4's wire
-- budget over the match, which is what atomsPerMinMax is for.
clause(gate.refused == 0 and gate.badKind == 0 and gate.badTarget == 0
       and gate.declinedRate == 0 and gate.clamped == 0
       and gate.atomsPerMinMax <= Policy.WIRE_ATOMS_PER_MIN,
  "no order bypassed the input gate",
  format("%d/%d/%d/%d/%d @%d", gate.refused, gate.badKind, gate.badTarget,
         gate.declinedRate, gate.clamped, gate.atomsPerMinMax),
  format("0/0/0/0/0 @<=%d", Policy.WIRE_ATOMS_PER_MIN),
  u(function(x) return format("%d/%d/%d/%d/%d @%d", x.refused, x.badKind,
      x.badTarget, x.declinedRate, x.clamped, x.atomsPerMinMax) end))

print("")
print("  read these two before you read the table:")
print("  * \"every match terminated\" is SATISFIED BY CONSTRUCTION at default")
print("    settings -- the driver ticks to maxTicks and the sim resolves the")
print("    clock at MATCH_TICKS, so no path leaves a match unfinished. It is")
print("    kept as insurance against a maxTicks regression, not read as a")
print("    measurement. The half that can fail is keep + clock == matches.")
print(format("  * %d orders were declined for landing after the clock. That class is",
  gate.declinedLate))
print("    benign, so it is neither in the gate clause nor summed into it -- it")
print("    moves for reasons that have nothing to do with reaching past the gate.")
print("")
if nBad > 0 then
  print(format("M2 VERDICT: RED -- %d clause(s) failed:", nBad))
  for i = 1, nBad do print("  * " .. bad[i]) end
  print("")
  print("Part E: a disagreement between the Lua sim and the Python model is a")
  print("FINDING, not a nuisance. Before changing a number in sim/Rules.lua to")
  print("close a clause, run these, in this order:")
  print("  lua sweep/famstat.lua   -- is the failing clause even measurable at")
  print("                             four hand-written lines per family?")
  print("  lua sweep/probe.lua     -- what does one building actually cost, held")
  print("                             against an otherwise identical line?")
  print("  lua sweep/sweep.lua     -- the full C.6 cross-check, metric by metric")
  if upper then
    print("")
    print("AND BEFORE ANY OF THAT, read the two columns above against each other.")
    print("The information regime moves these clauses by more than their margins,")
    print("and it is not a property of sim/Rules.lua: a clause that passes under")
    print("\"full\" and fails under \"fog\" is telling you the sixteen lines were")
    print("calibrated against a board no player is ever shown, not that the")
    print("ruleset is wrong. policy/lines.lua is the thing to change there.")
  end
  error("M2 verdict red", 0)
end

if gate.nMatches < T.matchesMin then
  print(format("M2 VERDICT: GREEN, but on %d matches. The milestone is %d.",
    gate.nMatches, T.matchesMin))
else
  print(format("M2 VERDICT: GREEN (%d matches, seed base %d, vision %s)",
    gate.nMatches, SEEDBASE, gate.vision))
end
print("not verified by this run:")
print("  * that M1 still passes. Run tools/ci.sh.")
print("  * that the policy layer replays byte-identically. Run sweep/determinism.lua.")
print("  * anything about HUMAN play. Sixteen scripted lines are sixteen scripted")
print("    lines, and C.6 says the same about its own numbers (F.1).")
