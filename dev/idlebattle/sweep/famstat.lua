-- sweep/famstat.lua -- is "family spread under 10pp" a measurement or a coin flip?
--
-- THE QUESTION THIS FILE EXISTS TO ANSWER. sweep/verdict.lua fails one clause of
-- Part E's M2 milestone: family spread comes out at 16.5pp against C.6's 7.0pp
-- and a 10pp threshold. The obvious reading is "the Lua ruleset is less balanced
-- than the Python one, so change the ruleset". That reading is only valid if the
-- STATISTIC can tell those two states apart, and a family win rate here is the
-- mean of FOUR hand-written lines whose individual win rates range over 40-83
-- points. A mean of four samples drawn from a 40-83 point spread has a standard
-- error of the same order as the threshold being tested.
--
-- So before anything in sim/Rules.lua is touched, four tests, each answering a
-- different way the number could be an artefact:
--
--   1 PERMUTATION. Deal the sixteen measured line win rates into four arbitrary
--     groups of four, thousands of times, and build the distribution of family
--     spread under the null hypothesis THAT THE FAMILY LABEL CARRIES NO
--     INFORMATION AT ALL. If the measured 16.5pp sits in the middle of that
--     distribution, the sweep has not detected a family effect -- it has
--     detected that four numbers drawn from a wide spread rarely have equal
--     means. This is the load-bearing test.
--   2 SEED NOISE. Re-run the whole round-robin at several seed bases with the
--     roster held EXACTLY fixed. Whatever the spread does here is the noise
--     floor from match randomness alone, with line selection removed.
--   3 ROSTER JACKKNIFE. Drop each line in turn and recompute, exactly, from the
--     pair matrix. If deleting one of sixteen lines moves the spread by more
--     than the threshold, the statistic is a property of the roster and not of
--     the ruleset.
--   4 BUILDING SPEND. The standing explanation for the failure (README Finding
--     1) is that win rate is nearly a linear function of building spend, so the
--     building-heavy families are structurally punished. Tested here as a rank
--     correlation with its own permutation null, because "nearly linear" across
--     sixteen points is a claim that needs an error bar before it justifies
--     repricing a catalogue.
--
-- Everything is integer: shares in permille, correlation as Kendall's S (a count
-- of concordant minus discordant pairs), significance as a rank out of K
-- shuffles. No float appears anywhere, so this file passes the same greps as the
-- sim and its output is bit-reproducible from the seed printed at the top.
--
--   usage: lua sweep/famstat.lua [seedsPerPair] [seedBases] [shuffles]
--          seedsPerPair  default 6 (1,440 matches per replicate)
--          seedBases     default 4 replicates for test 2. 1 skips it.
--          shuffles      default 20000 permutations for tests 1 and 4
--
-- This is a DIAGNOSTIC, not a gate: it always exits 0. It has no opinion about
-- whether M2 passes -- that is sweep/verdict.lua -- only about whether the
-- clause that failed is capable of being passed on purpose.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Rand = IB_SIM_MODULES and IB_SIM_MODULES.Rand or require("sim.Rand")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local linesM = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local measure = IB_SIM_MODULES and IB_SIM_MODULES.measure or require("sweep.measure")

local floor = math.floor
local format = string.format

local SEEDS = tonumber(arg and arg[1]) or 6
local BASES = tonumber(arg and arg[2]) or 4
local SHUFFLES = tonumber(arg and arg[3]) or 20000

-- The permutation stream. Fixed, so this file's p-values are reproducible.
local STAT_SEED = 20260812

local NF = #Policy.FAMILIES
local permille = measure.permille
local sortAsc = measure.sortAsc
local pctl = measure.pctl

local function pmStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%d%%", neg and "-" or "", whole, a - whole * 10)
end

local function ppStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%dpp", neg and "-" or "", whole, a - whole * 10)
end

-- ---------------------------------------------------------------------------
-- the measurement everything below is computed from
-- ---------------------------------------------------------------------------

print("Idle Battle M2 -- is the family-spread clause measurable?")
print(format("  rulesHash   %s (%s)", Hash.dec(Rules.rulesHash), Rules.rulesHash36))
print(format("  seeds/pair  %d      replicates %d      shuffles %d",
  SEEDS, BASES, SHUFFLES))
print(format("  stat seed   %d (sim/Rand.lua, so every p-value below replays)",
  STAT_SEED))
print(format("  vision      %s   (the information regime is part of the measurement;",
  Policy.VISION))
print("              every number below is conditional on it)")
print("")

local r = measure.roundRobin({ seeds = SEEDS })
local NL = r.nLines

print(format("MEASURED: family spread %s over %d matches   (C.6 %s, milestone < %s)",
  pmStr(r.famSpread), r.nMatches, pmStr(measure.C6.famSpread),
  pmStr(measure.TARGET.familySpreadMax)))
print("")

-- ---------------------------------------------------------------------------
-- 1. PERMUTATION: what would four ARBITRARY groups of four have produced?
-- ---------------------------------------------------------------------------

print("== 1. permutation test: does the family label carry any information? ==")
print(format("  H0: the %d lines are exchangeable and the %d labels mean nothing.",
  NL, NF))
print("  Under H0, deal them into groups OF THE REAL FAMILY SIZES and measure")
print("  the spread. The sizes matter and used to be hardcoded at four: a null")
print("  whose groups are a different shape from the observed grouping is not a")
print("  null for the observed statistic, and the roster is no longer 4/4/4/4.")
print("")

local rng = Rand.new(STAT_SEED)

-- Fisher-Yates over an explicit index array. Rand.range only, per rule 3.
local perm = {}
local function shuffle(n)
  for i = 1, n do perm[i] = i end
  for i = n, 2, -1 do
    local j = Rand.range(rng, 1, i)
    perm[i], perm[j] = perm[j], perm[i]
  end
end

-- Spread of the group means, when the shuffled order is cut into blocks OF THE
-- REAL FAMILY SIZES. Weighted exactly as the sweep weights it: every line plays
-- the same number of matches, so a group mean is the mean of its win rates.
--
-- THE SIZES ARE READ OFF THE ROSTER, and that is a correction rather than a
-- generalisation. They were hardcoded as floor(NL / NF), which was right only
-- while the roster was 4/4/4/4: at 4/4/4/5 it dealt sixteen of the seventeen
-- rates into four groups of four and dropped one line per shuffle, so the null
-- described a roster nobody was measuring and one line's win rate was silently
-- excluded from its own null.
local groupSizes = {}
do
  local tot = 0
  for f = 1, NF do
    groupSizes[f] = #linesM.FAMILY_MEMBERS[f]
    tot = tot + groupSizes[f]
  end
  if tot ~= NL then
    error(format("famstat: the family members total %d, the roster is %d", tot, NL), 0)
  end
end
local function spreadOfPermutation(pm)
  local lo, hi = 1001, -1
  local at = 0
  for g = 1, NF do
    local s = 0
    local sz = groupSizes[g]
    for _ = 1, sz do
      at = at + 1
      s = s + pm[perm[at]]
    end
    local m = floor(s / sz)
    if m < lo then lo = m end
    if m > hi then hi = m end
  end
  return hi - lo
end

local nullSpread, nNull = {}, 0
local atLeast = 0
for _ = 1, SHUFFLES do
  shuffle(NL)
  local sp = spreadOfPermutation(r.linePm)
  nNull = nNull + 1
  nullSpread[nNull] = sp
  if sp >= r.famSpread then atLeast = atLeast + 1 end
end
sortAsc(nullSpread, nNull)

local pValue = permille(atLeast, nNull)
print(format("  null distribution of family spread, %d shuffles:", nNull))
print(format("    p05 %s   p25 %s   median %s   p75 %s   p95 %s",
  ppStr(pctl(nullSpread, nNull, 5)), ppStr(pctl(nullSpread, nNull, 25)),
  ppStr(pctl(nullSpread, nNull, 50)), ppStr(pctl(nullSpread, nNull, 75)),
  ppStr(pctl(nullSpread, nNull, 95))))
print(format("  measured %s;  P(null spread >= measured) = %s",
  ppStr(r.famSpread), pmStr(pValue)))

local underThreshold = 0
for i = 1, nNull do
  if nullSpread[i] < measure.TARGET.familySpreadMax then underThreshold = underThreshold + 1 end
end
print(format("  P(null spread < the %s milestone threshold) = %s",
  pmStr(measure.TARGET.familySpreadMax), pmStr(permille(underThreshold, nNull))))
print("")
if pValue >= 100 then
  print("  READ: the measured spread is NOT distinguishable from four arbitrary")
  print("  groups of four. The sweep has not detected a family effect. Whatever")
  print("  this clause is measuring, it is not the balance of the ruleset --")
  print("  and it cannot be fixed by changing one, because the same roster would")
  print("  produce a spread of this size with the ruleset's families erased.")
else
  print("  READ: the measured spread is larger than arbitrary grouping explains,")
  print("  so there is a real family effect on top of the roster's dispersion.")
end
-- ---------------------------------------------------------------------------
-- 1b. IS THE CLAUSE PASSABLE AT ALL? The null above answers "not by THIS
-- roster", and an earlier version of README Finding 1 read it as "not by any
-- ruleset". Those are different statements and only the first is shown, because
-- the null is computed from sixteen win rates the ruleset and the roster produce
-- JOINTLY. Shrinking the same sixteen rates toward 50% -- which is exactly what
-- a roster of more comparable lines would look like -- and re-running the same
-- null separates them, at no extra matches.
-- ---------------------------------------------------------------------------

print("")
print("== 1b. the same null, at lower roster dispersion ==")
print("  Each line's win rate pulled toward 50% by a factor, then the identical")
print("  permutation re-run. This changes the ROSTER's dispersion and nothing")
print("  about the ruleset, so a large move here says the clause is a statement")
print("  about how far apart somebody wrote the lines.")
print("")
print("  (`spread` here is the mean-of-rates form the permutation uses, so it can")
print("   differ from the match-weighted headline figure by a tenth of a point.)")
print("")
print(format("  %-34s %-9s %-9s %s", "roster dispersion", "spread", "null med",
  "P(null < " .. pmStr(measure.TARGET.familySpreadMax) .. ")"))

local shrunk = {}
local function shrinkTest(label, num, den)
  for i = 1, NL do
    -- 500 + (pm - 500) * num / den, in integers, floor toward the same side for
    -- every line so the transform is monotone and adds no ordering noise.
    shrunk[i] = 500 + floor((r.linePm[i] - 500) * num / den)
  end
  local lo, hi = 1001, -1
  for f = 1, NF do
    local mem = linesM.FAMILY_MEMBERS[f]
    local s = 0
    for k = 1, #mem do s = s + shrunk[mem[k]] end
    local m = floor(s / #mem)
    if m < lo then lo = m end
    if m > hi then hi = m end
  end
  local under, med, nS = 0, 0, 0
  local dist = {}
  local rng2 = Rand.new(STAT_SEED)
  local savedPerm = {}
  for i = 1, NL do savedPerm[i] = perm[i] end
  for _ = 1, SHUFFLES do
    for i = 1, NL do perm[i] = i end
    for i = NL, 2, -1 do
      local j = Rand.range(rng2, 1, i)
      perm[i], perm[j] = perm[j], perm[i]
    end
    local sp = spreadOfPermutation(shrunk)
    nS = nS + 1
    dist[nS] = sp
    if sp < measure.TARGET.familySpreadMax then under = under + 1 end
  end
  sortAsc(dist, nS)
  med = pctl(dist, nS, 50)
  for i = 1, NL do perm[i] = savedPerm[i] end
  print(format("  %-34s %-9s %-9s %s", label, ppStr(hi - lo), ppStr(med),
    pmStr(permille(under, nS))))
end

shrinkTest("as measured", 1, 1)
-- C.6 reports leverage 26.9-55.0pp against this roster's own; the ratio of the
-- two upper ends is the crude rescaling README Finding 1 gestured at, run here
-- properly instead of asserted.
local levHi = -1
for f = 1, NF do
  local mem = linesM.FAMILY_MEMBERS[f]
  local blo, bhi = 1001, -1
  for k = 1, #mem do
    local pm = r.linePm[mem[k]]
    if pm < blo then blo = pm end
    if pm > bhi then bhi = pm end
  end
  if bhi - blo > levHi then levHi = bhi - blo end
end
shrinkTest(format("at C.6's leverage (%s->%s)",
  pmStr(levHi), pmStr(measure.C6.leverageHi)), measure.C6.leverageHi, levHi)
shrinkTest("at half this dispersion", 1, 2)
shrinkTest("at a quarter of it", 1, 4)
print("")
print("  READ: if P(null < threshold) climbs steeply as the roster tightens, the")
print("  clause is PASSABLE and the failure is a statement about this roster's")
print("  dispersion -- not, as an earlier reading had it, about the ruleset. Both")
print("  readings fail the clause today; only one of them justifies asking for")
print("  the clause to be deleted.")

print("")
print(format("  For scale: C.6 publishes its own decision leverage as %s-%s and its",
  pmStr(measure.C6.leverageLo), pmStr(measure.C6.leverageHi)))
print(format("  family spread as %s. The same test applied to C.6's numbers cannot be",
  pmStr(measure.C6.famSpread)))
print("  run here, because Part C never recorded its sixteen policies -- only four")
print("  of their names. That is itself the finding: the clause compares two")
print("  different rosters and calls the difference a property of the sim.")

-- ---------------------------------------------------------------------------
-- 2. SEED NOISE: the same sixteen lines, different matches
-- ---------------------------------------------------------------------------

print("")
print("== 2. seed noise: the roster held fixed, every match re-rolled ==")
if BASES <= 1 then
  print("  skipped (seedBases <= 1)")
else
  print(format("  %d replicates of %d matches each. Line selection is identical in",
    BASES, r.nMatches))
  print("  every row, so all the movement here is match randomness.")
  print("")
  -- BAND AND KEEP ARE PRINTED HERE TOO, and that is not padding. This loop
  -- already computes a full round-robin per replicate and used to throw away
  -- every clause except family spread -- which is how a seed base at which the
  -- BAND clause fails was measured four times and reported as passing. A
  -- replicate that would fail a milestone clause can never again be computed
  -- and discarded: the per-row verdict column says so on the row.
  print(format("  %-12s %-8s %-8s %-8s %-8s %-8s %-7s %-7s %-7s %s",
    "seed base", "aggro", "economy", "defence", "mixed", "SPREAD",
    "band", "keep", "median", "clauses"))
  local spreads, nSp = {}, 0
  local bandLo, bandHi, keepLo, keepHi = 1001, -1, 1001, -1
  local anyBandFail, anyKeepFail, anyMedianFail = 0, 0, 0
  for b = 1, BASES do
    local base = measure.SEED_BASE + (b - 1) * 100000
    local rep = (b == 1) and r or measure.roundRobin({ seeds = SEEDS, seedBase = base })
    nSp = nSp + 1
    spreads[nSp] = rep.famSpread
    if rep.bandPm < bandLo then bandLo = rep.bandPm end
    if rep.bandPm > bandHi then bandHi = rep.bandPm end
    if rep.keepPm < keepLo then keepLo = rep.keepPm end
    if rep.keepPm > keepHi then keepHi = rep.keepPm end
    local red = {}
    if rep.median < measure.TARGET.medianLo or rep.median > measure.TARGET.medianHi then
      red[#red + 1] = "median"; anyMedianFail = anyMedianFail + 1
    end
    if rep.bandPm < measure.TARGET.bandPctMin then
      red[#red + 1] = "band"; anyBandFail = anyBandFail + 1
    end
    if rep.keepPm < measure.TARGET.keepPctMin then
      red[#red + 1] = "keep"; anyKeepFail = anyKeepFail + 1
    end
    if rep.famSpread >= measure.TARGET.familySpreadMax then red[#red + 1] = "spread" end
    print(format("  %-12d %-8s %-8s %-8s %-8s %-8s %-7s %-7s %-7d %s",
      base, pmStr(rep.famPm[1]), pmStr(rep.famPm[2]), pmStr(rep.famPm[3]),
      pmStr(rep.famPm[4]), ppStr(rep.famSpread),
      pmStr(rep.bandPm), pmStr(rep.keepPm), measure.secs(rep.median),
      #red == 0 and "all pass" or ("RED: " .. table.concat(red, " "))))
  end
  sortAsc(spreads, nSp)
  print("")
  print(format("  spread across replicates: min %s, max %s, range %s",
    ppStr(spreads[1]), ppStr(spreads[nSp]), ppStr(spreads[nSp] - spreads[1])))
  print(format("  band   across replicates: min %s, max %s   (milestone >= %s)",
    pmStr(bandLo), pmStr(bandHi), pmStr(measure.TARGET.bandPctMin)))
  print(format("  keep   across replicates: min %s, max %s   (milestone >= %s)",
    pmStr(keepLo), pmStr(keepHi), pmStr(measure.TARGET.keepPctMin)))
  if anyBandFail > 0 or anyKeepFail > 0 or anyMedianFail > 0 then
    print(format("  WARNING: %d of %d replicates fail the band clause, %d fail keep,",
      anyBandFail, BASES, anyKeepFail))
    print(format("  %d fail the median band. A clause that passes at the default seed",
      anyMedianFail))
    print("  base and fails at another is SEED-DEPENDENT, not passing.")
  end
  print("  READ: this is the noise floor with line selection REMOVED. Compare it")
  print("  with the permutation width in test 1: if test 1 is far wider, the")
  print("  uncertainty in this clause is dominated by WHICH SIXTEEN LINES someone")
  print("  wrote, not by how many matches they played.")
end

-- ---------------------------------------------------------------------------
-- 3. ROSTER JACKKNIFE: drop one line, exactly
-- ---------------------------------------------------------------------------

print("")
print("== 3. roster jackknife: delete one line of sixteen and re-measure ==")
print("  Win rates recomputed EXACTLY from the pair matrix, so the dropped line")
print("  is removed as an opponent too, not just as a member of its family.")
print("")

-- Win rate of line i over the pool excluding line `drop`.
local function pmExcluding(i, drop)
  local sc, mt = 0, 0
  for j = 1, NL do
    if j ~= i and j ~= drop then
      sc = sc + r.score[i][j]
      mt = mt + r.played[i][j]
    end
  end
  return permille(sc, mt * 2), sc, mt
end

local famOf = {}
for f = 1, NF do
  local mem = linesM.FAMILY_MEMBERS[f]
  for k = 1, #mem do famOf[mem[k]] = f end
end

local jkLo, jkHi, jkLoName, jkHiName = 1001, -1, "-", "-"
local jkList, nJk = {}, 0
for drop = 1, NL do
  local sc, mt = {}, {}
  for f = 1, NF do sc[f] = 0; mt[f] = 0 end
  for i = 1, NL do
    if i ~= drop then
      local _, s, m = pmExcluding(i, drop)
      local f = famOf[i]
      sc[f] = sc[f] + s
      mt[f] = mt[f] + m
    end
  end
  local lo, hi = 1001, -1
  for f = 1, NF do
    local pm = permille(sc[f], mt[f] * 2)
    if pm < lo then lo = pm end
    if pm > hi then hi = pm end
  end
  local sp = hi - lo
  nJk = nJk + 1
  jkList[nJk] = sp
  if sp < jkLo then jkLo = sp; jkLoName = r.lines[drop].name end
  if sp > jkHi then jkHi = sp; jkHiName = r.lines[drop].name end
  print(format("  without %-14s (%-7s)  spread %s",
    r.lines[drop].name, r.lines[drop].family, ppStr(sp)))
end
print("")
print(format("  spread ranges %s to %s over one deletion.", ppStr(jkLo), ppStr(jkHi)))
print(format("  Lowest with %s dropped; highest with %s dropped.", jkLoName, jkHiName))
local passers = 0
for i = 1, nJk do
  if jkList[i] < measure.TARGET.familySpreadMax then passers = passers + 1 end
end
print(format("  %d of %d single deletions would PASS the %s clause.",
  passers, nJk, pmStr(measure.TARGET.familySpreadMax)))
print("  READ: if deleting one line of sixteen can flip the milestone, the clause")
print("  is a statement about the roster.")

-- ---------------------------------------------------------------------------
-- 4. BUILDING SPEND vs WIN RATE -- the standing explanation, with an error bar
-- ---------------------------------------------------------------------------

print("")
print("== 4. does building spend predict win rate? ==")
print("  README Finding 1 says family win rate is nearly a linear function of")
print("  building spend. Kendall's S over the sixteen lines: concordant pairs")
print("  minus discordant pairs, against a permutation null.")
print("")

local spend, win = {}, {}
for i = 1, NL do
  spend[i] = floor(r.stat[i].bldSpend / r.stat[i].matches)
  win[i] = r.linePm[i]
end

local function kendallS(x, y, n)
  local s = 0
  for i = 1, n - 1 do
    for j = i + 1, n do
      local dx = x[i] - x[j]
      local dy = y[i] - y[j]
      if dx ~= 0 and dy ~= 0 then
        if (dx > 0) == (dy > 0) then s = s + 1 else s = s - 1 end
      end
    end
  end
  return s
end

local sObs = kendallS(spend, win, NL)
local nPairs = floor(NL * (NL - 1) / 2)
print(format("  Kendall S = %d over %d comparable pairs (tau ~ %s)",
  sObs, nPairs, ppStr(permille(sObs, nPairs))))

local shuffled = {}
local moreExtreme = 0
for _ = 1, SHUFFLES do
  shuffle(NL)
  for i = 1, NL do shuffled[i] = win[perm[i]] end
  local s = kendallS(spend, shuffled, NL)
  local a = s < 0 and -s or s
  local b = sObs < 0 and -sObs or sObs
  if a >= b then moreExtreme = moreExtreme + 1 end
end
local pSpend = permille(moreExtreme, SHUFFLES)
print(format("  two-sided p = %s over %d shuffles", pmStr(pSpend), SHUFFLES))
print("")
print("  the sixteen lines, by building Levy per match:")
local order = {}
for i = 1, NL do order[i] = i end
for a = 2, NL do
  local v = order[a]
  local b = a - 1
  while b >= 1 and spend[order[b]] > spend[v] do
    order[b + 1] = order[b]
    b = b - 1
  end
  order[b + 1] = v
end
for k = 1, NL do
  local i = order[k]
  print(format("    %-14s %-8s  bldLevy %-5d  win %s",
    r.lines[i].name, r.lines[i].family, spend[i], pmStr(win[i])))
end
print("")
if pSpend < 50 then
  print("  READ: building spend really does predict win rate. The catalogue is")
  print("  mispriced against these policies and Finding 1 stands.")
else
  print("  READ: the association is NOT significant at these sixteen points. The")
  print("  building-price explanation is not supported by the round-robin alone;")
  print("  it needs the controlled comparison in sweep/probe.lua, where only the")
  print("  opening building varies and everything else is held identical.")
end

print("")
print("== what this file does NOT settle ================================")
print("  * Whether the RULESET is balanced. None of the four tests above can")
print("    tell you that, because every one of them is computed from sixteen")
print("    policies somebody chose. They only tell you whether THIS statistic,")
print("    at THIS roster size, can distinguish a balanced ruleset from an")
print("    unbalanced one.")
print("  * Anything about human play (F.1).")
