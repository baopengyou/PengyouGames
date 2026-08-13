-- sweep/sweep.lua -- THE M2 REPORT. The sim playing itself, N times, against C.6.
--
--   "1,000 simulated matches terminate -- by razed keep or by clock --
--    reproducing C.6 within a few points: median 380-430 s, >=75% inside the
--    5-10 minute band, >=80% decided by a razed keep, family spread under 10pp."
--
-- Sixteen lines (policy/lines.lua), a full round-robin over every ORDERED pair
-- (240 of them, so every pairing is played from both seats), N seeds each. The
-- default N = 6 gives 1,440 matches, which is C.6's own sample size.
--
-- WHAT THIS IS ACTUALLY TESTING, and it is not the policies. Part C's numbers
-- came out of a purpose-built Python simulator. This is the first time they are
-- measured in the shipping language, by a different implementation, written from
-- the same document. Part E is explicit that a disagreement between the two is a
-- FINDING: the numbers below are evidence about Part C, not a score for the
-- lines. If the median comes out at 250 s, the correct response is to work out
-- which model is wrong, not to slow the lines down until the number looks right.
--
-- THE REPORT WALKS C.6's OWN TABLE, IN C.6's OWN ORDER, three columns wide:
-- measured, published, delta -- with every delta past a few points marked "!"
-- and every delta past ten points marked "!!" in a column of its own, so a
-- disagreement cannot be missed by someone skimming. A metric C.6 does not
-- publish is printed in the detail sections below the cross-check and nowhere
-- above it, so the cross-check is never padded with things that cannot disagree.
--
-- THE GATE LIVES IN sweep/verdict.lua, not here. This file measures and prints
-- and always exits 0; verdict.lua asserts Part E's thresholds and exits non-zero.
-- Splitting them is what lets CI fail on the milestone without anyone having to
-- parse this report, and lets a human read this report without it aborting
-- halfway down the first failing clause.
--
--   usage: lua sweep/sweep.lua [seedsPerPair] [line]
--          seedsPerPair  default 6 (1,440 matches). 1 gives 240, for iteration.
--          line          "all" (default) or one line name to play against the
--                        whole pool from both seats, for diagnosing one line.
--
-- Tool-grade, like tools/: it may print. It deliberately keeps the sim's other
-- disciplines anyway (no floats, no pairs(), no table.sort, every "/" inside a
-- floor) so tools/greps.sh runs over sweep/ with zero hits and the one file that
-- IS sim-affecting -- driver.lua -- is not sitting alone in an unchecked
-- directory. Failure is signalled with error(), which exits non-zero, rather
-- than os.exit, so no os.* call appears anywhere under policy/ or sweep/.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local lines = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local measure = IB_SIM_MODULES and IB_SIM_MODULES.measure or require("sweep.measure")

local floor = math.floor
local format = string.format

local SEEDS = tonumber(arg and arg[1]) or 6
local ONLY = arg and arg[2] or "all"

local C6 = measure.C6
local secs = measure.secs
local permille = measure.permille
local pctl = measure.pctl

-- ---------------------------------------------------------------------------
-- printing. Permille in, tenths out; nothing here is ever a float.
-- ---------------------------------------------------------------------------

local function pmStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%d%%", neg and "-" or "", whole, a - whole * 10)
end

-- A signed delta in percentage POINTS, always with its sign, so a column of
-- them reads as a column of disagreements rather than a column of numbers.
local function dpm(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%dpp", neg and "-" or "+", whole, a - whole * 10)
end

local function dsec(s)
  return format("%s%d s", s < 0 and "-" or "+", s < 0 and -s or s)
end

-- The marker column. "a few points" is Part E's own tolerance; 5 points earns a
-- "!" and 10 points a "!!". Lengths use 30 s / 60 s, which is the same fraction
-- of the 380-430 s target band.
local function markPm(d)
  local a = d < 0 and -d or d
  if a >= 100 then return "!!" end
  if a >= 50 then return "!" end
  return ""
end

local function markSec(d)
  local a = d < 0 and -d or d
  if a >= 60 then return "!!" end
  if a >= 30 then return "!" end
  return ""
end

-- One cross-check row: label, measured, published, delta, marker. Wide enough
-- for "Granary-bank 88.8%", because a column that overflows turns the whole
-- table into something nobody can scan down.
local function row(label, got, want, delta, mark)
  print(format("  %-24s %-19s %-19s %-9s %s", label, got, want, delta, mark))
end

local function rowPm(label, gotPm, wantPm)
  local d = gotPm - wantPm
  row(label, pmStr(gotPm), pmStr(wantPm), dpm(d), markPm(d))
end

local function rowSec(label, gotTicks, wantTicks)
  local g, w = secs(gotTicks), secs(wantTicks)
  row(label, format("%d s", g), format("%d s", w), dsec(g - w), markSec(g - w))
end

-- A COUNT row -- concurrent units -- whose marker is PROPORTIONAL, because
-- "5 percentage points" means nothing about a headcount. Permille of the
-- published value: 250 (25% out) earns "!", 500 (50% out) earns "!!".
local function markCount(got, want)
  if want == 0 then return "" end
  local d = permille(got, want) - 1000
  local a = d < 0 and -d or d
  if a >= 500 then return "!!" end
  if a >= 250 then return "!" end
  return ""
end

local function rowCount(label, got, want)
  row(label, format("%d", got), format("%d", want),
    format("%+d", got - want), markCount(got, want))
end

-- ---------------------------------------------------------------------------
-- run it
-- ---------------------------------------------------------------------------

print("Idle Battle M2 sweep -- the sim playing itself")
print(format("  rulesHash   %s (%s)", Hash.dec(Rules.rulesHash), Rules.rulesHash36))
print(format("  lines       %d over %d families", #lines.LINES, #Policy.FAMILIES))
print(format("  poll        every %d ticks, at most %d orders per poll per side "
  .. "= %d atoms/min (A.11.4 %d)",
  Policy.POLL, Policy.MAX_ORDERS_PER_POLL,
  Policy.CEILING_ATOMS_PER_MIN, Policy.WIRE_ATOMS_PER_MIN))
print(format("  vision      %s  (\"fog\" = IDLE_BATTLE_FOG.md on the foe half; "
  .. "\"full\" = Ruling 1 unfiltered)", Policy.VISION))
print(format("  seeds       base %d, %d per ordered pair", measure.SEED_BASE, SEEDS))

local only = nil
if ONLY ~= "all" then
  if lines.BY_NAME[ONLY] == nil then
    error("sweep: no such line: " .. tostring(ONLY), 0)
  end
  only = ONLY
  print(format("  pairings    %s against the pool, both seats, %d seeds", ONLY, SEEDS))
else
  print(format("  pairings    %d ordered x %d seeds",
    #lines.LINES * (#lines.LINES - 1), SEEDS))
end
print("")

local r = measure.roundRobin({
  seeds = SEEDS,
  only = only,
  onLine = function(_, name, n)
    if only == nil then print(format("  ...%s done (%d matches)", name, n)) end
  end,
})

-- ---------------------------------------------------------------------------
-- the cross-check: C.6's table, C.6's order
--
-- ONLY IN ALL-PLAY-ALL MODE. In single-line mode measure.roundRobin plays the
-- named line against the pool from both seats, so it accumulates 30*seeds
-- matches while EVERY OTHER LINE accumulates 2*seeds, all of them against the
-- same opponent. Family win rates, the family spread, decision leverage, the
-- best-line rows and the whole length distribution computed off that table are
-- not this roster's numbers and cannot disagree with C.6 -- but printed in
-- C.6's own table, in C.6's own order, with the same "!!" markers, they read
-- exactly like a real disagreement. They are SUPPRESSED rather than annotated,
-- because the marker column is defined by this file's own header as the thing
-- that makes a disagreement impossible to miss when skimming, and a caveat
-- paragraph does not survive someone reading only that column.
-- ---------------------------------------------------------------------------

if only ~= nil then
  print("")
  print("== NO C.6 CROSS-CHECK IN SINGLE-LINE MODE ========================")
  print(format("  All %d matches have %s in one seat; the other %d lines played",
    r.nMatches, only, #lines.LINES - 1))
  print(format("  %d matches each and ALL of them against %s. Family win rates,",
    2 * SEEDS, only))
  print("  the FAMILY SPREAD, decision leverage, the best-line rows and the")
  print("  length distribution are therefore not this roster's numbers and")
  print("  cannot disagree with C.6. They are suppressed rather than flagged,")
  print("  because a wrong number with a \"!!\" beside it is worse than no")
  print(format("  number at all. For the cross-check run: lua sweep/sweep.lua %d", SEEDS))
  print(format("  What is readable below is %s's own row in the == lines == table.", only))
else
  print("")
  print("== C.6 CROSS-CHECK ===============================================")
  print(format("  %d matches here, %d in C.6. \"!\" = 5 points out, \"!!\" = 10.",
    r.nMatches, C6.matches))
  print(format("  information regime: %s. C.6 does not record its own.", r.vision))
  print("")
  row("metric", "this sim", "C.6 (Python)", "delta", "")
  print("  --------------------------------------------------------------------------")
  rowSec("length p10", r.p10, C6.p10)
  rowSec("length p25", r.p25, C6.p25)
  rowSec("length median", r.median, C6.median)
  rowSec("length p75", r.p75, C6.p75)
  rowSec("length p90", r.p90, C6.p90)
  rowSec("length mean", r.meanLen, C6.mean)
  rowPm("inside 5-10 min band", r.bandPm, C6.band)
  rowPm("decided by razed keep", r.keepPm, C6.keep)
  rowPm("reached the clock", r.clockPm, C6.clock)
  if r.nClock > 0 then
    rowPm("  ...T1 resolved", permille(r.tiers[1], r.nClock), C6.t1)
    rowPm("  ...T2 resolved", permille(r.tiers[2], r.nClock), C6.t2)
    rowPm("  ...T3 resolved", permille(r.tiers[3], r.nClock), C6.t3)
    rowPm("  ...T4 resolved", permille(r.tiers[4], r.nClock), C6.t4)
    rowPm("  ...drawn", permille(r.tiers[5], r.nClock), C6.draw)
  end
  for f = 1, #Policy.FAMILIES do
    rowPm("family " .. Policy.FAMILIES[f], r.famPm[f], C6.fam[f])
  end
  rowPm("FAMILY SPREAD", r.famSpread, C6.famSpread)
  for f = 1, #Policy.FAMILIES do
    -- C.6 names one line per family and publishes its win rate. Where this
    -- sweep's best line has a DIFFERENT name the comparison is between two
    -- different policies and the delta is not a disagreement about the sim --
    -- so the name is printed and the row says so.
    local got, want = r.famBestPm[f], C6.bestPm[f]
    local d = got - want
    local same = (r.famBestName[f] == C6.bestName[f])
    row("best " .. Policy.FAMILIES[f] .. " line",
      format("%s %s", r.famBestName[f], pmStr(got)),
      format("%s %s", C6.bestName[f], pmStr(want)),
      same and dpm(d) or "n/a",
      same and markPm(d) or "(different line)")
  end
  local levLo, levHi = 1001, -1
  for f = 1, #Policy.FAMILIES do
    local lev = r.famBestPm[f] - r.famWorstPm[f]
    if lev < levLo then levLo = lev end
    if lev > levHi then levHi = lev end
  end
  row("decision leverage lo", pmStr(levLo), pmStr(C6.leverageLo),
    dpm(levLo - C6.leverageLo), markPm(levLo - C6.leverageLo))
  row("decision leverage hi", pmStr(levHi), pmStr(C6.leverageHi),
    dpm(levHi - C6.leverageHi), markPm(levHi - C6.leverageHi))
  -- The peak rows get a marker rule OF THEIR OWN. They are counts, not shares,
  -- so a percentage-POINT threshold is meaningless on them -- which is why they
  -- were the only three rows in the cross-check printed with no marker at all,
  -- and why the largest proportional disagreement in the whole table (median
  -- peak 25 against C.6's 17, +47%) went unflagged. The rule is proportional:
  -- 25% out earns "!", 50% out earns "!!".
  rowCount("peak units median", pctl(r.peaks, r.nPeak, 50), C6.peakMedian)
  rowCount("peak units p90", pctl(r.peaks, r.nPeak, 90), C6.peakP90)
  rowCount("peak units max", r.peaks[r.nPeak], C6.peakMax)
end

-- ---------------------------------------------------------------------------
-- detail C.6 does not publish
-- ---------------------------------------------------------------------------

print("")
print("== match length, and what fell outside the band ==================")
print(format("  under 5 min  %s (%d)   inside %s (%d)   over 10 min %s (%d)",
  pmStr(r.underPm), r.underBand, pmStr(r.bandPm), r.inBand,
  pmStr(r.overPm), r.overBand))
print(format("  draws %s (%d)   matches that did not terminate %d",
  pmStr(r.drawPm), r.nDraw, r.nUnfinished))
if only ~= nil then
  print(format("  (this is %s's own length distribution, not the roster's -- it is", only))
  print("   every match that line played and nothing else.)")
end

print("")
print("== lines =========================================================")
print("  line           family   matches  win     keepwins  len(s)  earned  wastedTot  bldLevy")
for f = 1, #Policy.FAMILIES do
  local mem = lines.FAMILY_MEMBERS[f]
  for k = 1, #mem do
    local i = mem[k]
    local s = r.stat[i]
    print(format("  %-14s %-8s %-8d %-7s %-9s %-7d %-7d %-10d %d",
      r.lines[i].name, r.lines[i].family, s.matches,
      pmStr(r.linePm[i]),
      s.wins > 0 and pmStr(permille(s.keepWins, s.wins)) or "-",
      secs(floor(s.tickSum / s.matches)),
      floor(s.earned / s.matches),
      -- THE RAW TOTAL, NOT A PER-MATCH MEAN. Waste is rare: at 180 matches a
      -- line any total under 180 floors to 0, so the per-match figure rendered
      -- a real-but-modest effect as absent. It is the column two lines in this
      -- roster exist to produce, so it may not be the one column that can only
      -- show zero.
      s.wasted,
      floor(s.bldSpend / s.matches)))
  end
end
print("  (keepwins  = share of that line's wins that razed a keep;")
print("   wastedTot = Levy lost to the bank cap over ALL that line's matches, raw;")
print("   bldLevy   = Levy per match converted into buildings that finished)")

print("")
print("== families ======================================================")
if only ~= nil then
  print(format("  suppressed: every line but %s played %d matches, all against",
    only, 2 * SEEDS))
  print(format("  %s. A family mean off that table is not this roster's.", only))
else
  for f = 1, #Policy.FAMILIES do
    print(format("  %-9s %s (C.6 %s)   best %s %s   worst %s   leverage %s",
      Policy.FAMILIES[f], pmStr(r.famPm[f]), pmStr(C6.fam[f]),
      r.famBestName[f], pmStr(r.famBestPm[f]), pmStr(r.famWorstPm[f]),
      pmStr(r.famBestPm[f] - r.famWorstPm[f])))
  end
  print(format("  family spread       %s (C.6 %s)   delta %s",
    pmStr(r.famSpread), pmStr(C6.famSpread), dpm(r.famSpread - C6.famSpread)))
  print("  NOTE: a family win rate is the mean of FOUR hand-written lines. See")
  print("  sweep/famstat.lua for whether that spread is distinguishable from the")
  print("  spread four arbitrary lines would produce with no family effect at all.")
end

print("")
print("== board load and the command path ===============================")
print(format("  concurrent units per side: median peak %d, p90 %d, max %d (C.6 %d / %d / %d)",
  pctl(r.peaks, r.nPeak, 50), pctl(r.peaks, r.nPeak, 90), r.peaks[r.nPeak],
  C6.peakMedian, C6.peakP90, C6.peakMax))
-- Five separate numbers, because they are five separate events and only four of
-- them are fatal. `declined late` is an order the clock made unexecutable and is
-- expected in the hundreds; `declined rate` is a line trying to out-click
-- A.11.4's budget and must be 0. Printed as one merged figure, the second is
-- invisible behind the first.
print(format("  orders: %d fizzled in the sim, %d refused at the gate,",
  r.fizzled, r.refused))
print(format("          %d declined RATE (must be 0), %d declined late (benign),",
  r.declinedRate, r.declinedLate))
print(format("          %d count-clamped, %d bad kind, %d bad target",
  r.clamped, r.badKind, r.badTarget))
print(format("  wire:   worst line sent %d atoms/min of match clock "
  .. "(A.11.4 budget %d, layer ceiling %d)",
  r.atomsPerMinMax, Policy.WIRE_ATOMS_PER_MIN, Policy.CEILING_ATOMS_PER_MIN))

print("")
print("Milestone clauses are asserted by sweep/verdict.lua, which exits non-zero.")
