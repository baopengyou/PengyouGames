-- sweep/measure.lua -- the round-robin, as a MEASUREMENT and not as a report.
--
-- WHY THIS FILE EXISTS AS A SEPARATE MODULE. M2 has four consumers of the same
-- 1,440 matches -- the report (sweep.lua), the CI gate (verdict.lua), the
-- family-spread statistics (famstat.lua) and the building probe (probe.lua) --
-- and the one thing worse than four programs disagreeing with Part C is four
-- programs disagreeing with EACH OTHER about what the sweep measured. So the
-- round-robin is defined exactly once, here, and returns integers. It prints
-- nothing and asserts nothing: printing is sweep.lua's job and failing is
-- verdict.lua's.
--
-- THE SEED SCHEDULE IS PART OF THE MEASUREMENT. Every match's seed is a pure
-- function of (seedBase, the ordinal of the ordered pair, the seed index), so
-- the whole sweep is reproducible from three integers and a line roster. Change
-- the formula and every number M2 ever reported becomes incomparable, which is
-- why it lives in one place with this note on it.
--
-- Held to sim/'s determinism rules like the rest of policy/ and sweep/: integer
-- arithmetic only, every "/" inside a floor, no pairs(), no math.random, no
-- os/io, no knowledge of which side is local.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local linesM = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local driver = IB_SIM_MODULES and IB_SIM_MODULES.driver or require("sweep.driver")

local M = {}

local floor = math.floor

-- The seed schedule. Frozen: see the header.
M.SEED_BASE = 500000
M.SEED_PAIR_STRIDE = 977
M.SEED_INDEX_STRIDE = 31

function M.seedFor(seedBase, pairOrdinal, seedIndex)
  return seedBase + pairOrdinal * M.SEED_PAIR_STRIDE + seedIndex * M.SEED_INDEX_STRIDE
end

-- The 5-10 minute band of Ruling 4, in ticks. Defined here rather than in a
-- consumer because "inside the band" must mean ONE thing across all of them.
M.BAND_LO = 3000
M.BAND_HI = 6000

function M.secs(ticks)
  return floor(ticks * Rules.C.SIM_TICK_MS / 1000)
end

-- ---------------------------------------------------------------------------
-- Part C.6, transcribed once
--
-- The single copy of the Python model's published result. sweep.lua prints it
-- beside the measurement, verdict.lua gates on the Part E thresholds derived
-- from it, and famstat.lua tests whether one of its clauses is measurable at
-- all. Three programs quoting three transcriptions of the same table is how a
-- cross-check quietly stops being one.
--
-- Lengths are TICKS (C.6 publishes seconds; x10 at 100 ms per sim tick).
-- Shares are PERMILLE.
-- ---------------------------------------------------------------------------

M.C6 = {
  p10 = 2330, p25 = 3100, median = 4060, p75 = 5260, p90 = 6000, mean = 4120,
  band = 770, keep = 850, clock = 150,
  -- of clock matches
  t1 = 540, t2 = 250, t3 = 170, t4 = 0, draw = 40,
  -- aggro / economy / defence / mixed
  fam = { 481, 512, 546, 476 },
  famSpread = 70,
  bestName = { "Rush-horse", "Greed-pure", "Turtle-eco", "Balanced" },
  bestPm = { 778, 733, 714, 592 },
  -- "decision leverage": the spread between variants of one archetype
  leverageLo = 269, leverageHi = 550,
  peakMedian = 17, peakP90 = 47, peakMax = 57,
  matches = 1440,
}

-- Part E's M2 milestone, as the gate reads it.
M.TARGET = {
  matchesMin = 1000,
  medianLo = 3800, medianHi = 4300,   -- ticks (380-430 s)
  bandPctMin = 750,                   -- permille: >= 75%
  keepPctMin = 800,                   -- permille: >= 80%
  familySpreadMax = 100,              -- permille: under 10pp
}

-- ---------------------------------------------------------------------------
-- integer statistics, shared by every consumer so they cannot drift
-- ---------------------------------------------------------------------------

-- Insertion sort. Small n, and a comparator-free total order over integers --
-- table.sort is flagged by grep 4 precisely because a comparator is where a
-- table-identity comparison hides.
function M.sortAsc(a, n)
  for i = 2, n do
    local v = a[i]
    local j = i - 1
    while j >= 1 and a[j] > v do
      a[j + 1] = a[j]
      j = j - 1
    end
    a[j + 1] = v
  end
end

-- p-th percentile of an ASCENDING array, by nearest-rank. Deliberately the
-- same rule everywhere, including in the C.6 comparison, so a percentile
-- disagreement is never an artefact of two definitions.
function M.pctl(a, n, p)
  if n == 0 then return 0 end
  local k = floor(n * p / 100)
  if k < 1 then k = 1 end
  if k > n then k = n end
  return a[k]
end

-- Percentages are carried as PERMILLE throughout M2 and printed as tenths, so
-- no percentage is ever a float and two runs cannot round it differently.
function M.permille(num, den)
  if den == 0 then return 0 end
  return floor(num * 1000 / den)
end

function M.mean(a, n)
  if n == 0 then return 0 end
  local s = 0
  for i = 1, n do s = s + a[i] end
  return floor(s / n)
end

-- ---------------------------------------------------------------------------
-- one round-robin
-- ---------------------------------------------------------------------------

-- declinedRate and declinedLate are kept APART, and that is the whole point of
-- this table. They are two completely different events: `late` is an order the
-- clock made unexecutable, which is benign and happens ~400 times a sweep;
-- `rate` is a line trying to out-click A.11.4's wire budget, which invalidates
-- that line's win rate because the sweep then measured a THROTTLED version of
-- the strategy its author wrote. Summed together, the one that matters is
-- invisible behind the one that does not.
local function newStat()
  return { matches = 0, score = 0, wins = 0, draws = 0, losses = 0,
           keepWins = 0, tickSum = 0, earned = 0, wasted = 0, spent = 0,
           builds = 0, bldSpend = 0, bldLost = 0, deployed = 0, lost = 0,
           fizzled = 0, refused = 0, declinedRate = 0, declinedLate = 0,
           clamped = 0, badKind = 0, badTarget = 0, atomsPerMinMax = 0,
           peakSum = 0 }
end

-- opts:
--   lines      the roster (default policy/lines.lua's LINES)
--   seeds      seeds per ordered pair (default 6 -> 1,440 matches at 16 lines)
--   seedBase   default M.SEED_BASE. Changing ONLY this re-rolls every match
--              while holding the roster fixed, which is how famstat.lua
--              separates match noise from line-selection noise.
--   only       a line name, to play one line against the whole pool instead
--   onLine     optional progress callback f(lineIndex, name, nMatches)
--   onPoll     optional read-only measurement tap, passed straight to the
--              driver (see its header). Nil on every gate path. It cannot move
--              a match: the driver discards its return value, so a run WITH a
--              tap and a run WITHOUT one produce the same integers -- which is
--              what makes sweep/fogaudit.lua's counts describe the sweep the
--              gate measured rather than a second, differently-driven one.
--
-- Returns a table of integers. Nothing in it is a reference to a sim.
function M.roundRobin(opts)
  opts = opts or {}
  local L = opts.lines or linesM.LINES
  local NL = #L
  local seeds = opts.seeds or 6
  local seedBase = opts.seedBase or M.SEED_BASE
  local only = opts.only

  local stat = {}
  local score = {}      -- score[ia][ib] = points ia took off ib (2 win, 1 draw)
  local played = {}     -- played[ia][ib] = matches between them, both seats
  for i = 1, NL do
    stat[i] = newStat()
    score[i] = {}
    played[i] = {}
    for j = 1, NL do score[i][j] = 0; played[i][j] = 0 end
  end

  local r = {
    lines = L,
    nLines = NL,
    seeds = seeds,
    seedBase = seedBase,
    -- THE INFORMATION REGIME IS PART OF THE MEASUREMENT, exactly as the seed
    -- schedule is. Two round-robins over the same roster and the same seeds are
    -- not comparable across regimes, so the regime travels WITH the numbers and
    -- every consumer prints it.
    vision = Policy.VISION,
    stat = stat,
    score = score,
    played = played,
    lengths = {}, nLen = 0,
    peaks = {}, nPeak = 0,
    nMatches = 0, nKeep = 0, nClock = 0, nDraw = 0, nUnfinished = 0,
    tiers = { 0, 0, 0, 0, 0 },
  }

  local nBld = #Rules.BUILDINGS

  local function play(ia, ib, seed)
    local m = driver.run({ a = L[ia], b = L[ib], seed = seed, onPoll = opts.onPoll })
    r.nMatches = r.nMatches + 1
    if not m.over then r.nUnfinished = r.nUnfinished + 1 end
    r.nLen = r.nLen + 1
    r.lengths[r.nLen] = m.ticks
    if m.reason == "keep" then
      r.nKeep = r.nKeep + 1
    elseif m.reason == "clock" then
      r.nClock = r.nClock + 1
      if m.tier >= 1 and m.tier <= 5 then r.tiers[m.tier] = r.tiers[m.tier] + 1 end
    end
    if m.winnerSlot == 0 then r.nDraw = r.nDraw + 1 end

    local idx = { ia, ib }
    for k = 1, 2 do
      local i = idx[k]
      local j = idx[3 - k]
      local s = stat[i]
      local d = m.slots[k]
      s.matches = s.matches + 1
      played[i][j] = played[i][j] + 1
      if m.winnerSlot == k then
        s.score = s.score + 2; s.wins = s.wins + 1
        score[i][j] = score[i][j] + 2
        if m.reason == "keep" then s.keepWins = s.keepWins + 1 end
      elseif m.winnerSlot == 0 then
        s.score = s.score + 1; s.draws = s.draws + 1
        score[i][j] = score[i][j] + 1
      else
        s.losses = s.losses + 1
      end
      s.tickSum = s.tickSum + m.ticks
      s.earned = s.earned + d.earned
      s.wasted = s.wasted + d.wasted
      s.spent = s.spent + d.spent
      s.builds = s.builds + d.buildsDone
      s.bldLost = s.bldLost + d.bldLost
      -- Levy actually converted into standing buildings. Walked over the
      -- ruleset's own index order, never over the sparse table's key order.
      for b = 1, nBld do
        local c = d.built[b]
        if c then s.bldSpend = s.bldSpend + c * Rules.BUILDINGS[b].cost end
      end
      s.deployed = s.deployed + d.unitsDeployed
      s.lost = s.lost + d.unitsLost
      s.fizzled = s.fizzled + d.cmdsFizzled
      s.refused = s.refused + d.refused
      s.declinedRate = s.declinedRate + d.declinedRate
      s.declinedLate = s.declinedLate + d.declinedLate
      s.clamped = s.clamped + d.clampedCount
      if d.atomsPerMin > s.atomsPerMinMax then s.atomsPerMinMax = d.atomsPerMin end
      s.badKind = s.badKind + d.badKind
      s.badTarget = s.badTarget + d.badTarget
      s.peakSum = s.peakSum + d.peakUnits
      r.nPeak = r.nPeak + 1
      r.peaks[r.nPeak] = d.peakUnits
    end
  end

  local pairsPlayed = 0
  if only == nil then
    for ia = 1, NL do
      for ib = 1, NL do
        if ia ~= ib then
          pairsPlayed = pairsPlayed + 1
          for s = 1, seeds do
            play(ia, ib, M.seedFor(seedBase, pairsPlayed, s))
          end
        end
      end
      if opts.onLine then opts.onLine(ia, L[ia].name, r.nMatches) end
    end
  else
    local ione = 0
    for i = 1, NL do if L[i].name == only then ione = i end end
    if ione == 0 then error("measure: no such line: " .. tostring(only), 0) end
    r.only = only
    for ib = 1, NL do
      if ib ~= ione then
        pairsPlayed = pairsPlayed + 1
        for s = 1, seeds do
          local seed = M.seedFor(seedBase, pairsPlayed, s)
          play(ione, ib, seed)
          play(ib, ione, seed)
        end
      end
    end
    if opts.onLine then opts.onLine(ione, only, r.nMatches) end
  end

  M.sortAsc(r.lengths, r.nLen)
  M.sortAsc(r.peaks, r.nPeak)

  -- Derived aggregates every consumer wants, computed once.
  r.median = M.pctl(r.lengths, r.nLen, 50)
  r.p10 = M.pctl(r.lengths, r.nLen, 10)
  r.p25 = M.pctl(r.lengths, r.nLen, 25)
  r.p75 = M.pctl(r.lengths, r.nLen, 75)
  r.p90 = M.pctl(r.lengths, r.nLen, 90)
  r.meanLen = M.mean(r.lengths, r.nLen)

  local inBand, under = 0, 0
  for i = 1, r.nLen do
    local v = r.lengths[i]
    if v >= M.BAND_LO and v <= M.BAND_HI then inBand = inBand + 1 end
    if v < M.BAND_LO then under = under + 1 end
  end
  r.inBand = inBand
  r.underBand = under
  r.overBand = r.nLen - inBand - under
  r.bandPm = M.permille(inBand, r.nLen)
  r.underPm = M.permille(under, r.nLen)
  r.overPm = M.permille(r.overBand, r.nLen)
  r.keepPm = M.permille(r.nKeep, r.nMatches)
  r.clockPm = M.permille(r.nClock, r.nMatches)
  r.drawPm = M.permille(r.nDraw, r.nMatches)

  -- Per-line win rate in permille, over ALL its matches (a draw is half a win,
  -- which is what score/2 already encodes).
  r.linePm = {}
  for i = 1, NL do
    r.linePm[i] = M.permille(stat[i].score, stat[i].matches * 2)
  end

  -- Families.
  r.famPm, r.famBestName, r.famBestPm, r.famWorstPm = {}, {}, {}, {}
  local lo, hi = 1001, -1
  for f = 1, #Policy.FAMILIES do
    local mem = linesM.FAMILY_MEMBERS[f]
    local sc, mt = 0, 0
    local bn, bp, wp = "-", -1, 1001
    for k = 1, #mem do
      local i = mem[k]
      sc = sc + stat[i].score
      mt = mt + stat[i].matches
      local pm = r.linePm[i]
      if pm > bp then bp = pm; bn = L[i].name end
      if pm < wp then wp = pm end
    end
    local pm = M.permille(sc, mt * 2)
    r.famPm[f] = pm
    r.famBestName[f] = bn
    r.famBestPm[f] = bp
    r.famWorstPm[f] = wp
    if pm < lo then lo = pm end
    if pm > hi then hi = pm end
  end
  r.famLo, r.famHi = lo, hi
  r.famSpread = hi - lo

  -- The command path, summed. A non-zero total in any of the FATAL classes
  -- means the driver, not the sim, decided something -- which the gate refuses.
  -- declinedLate is the one benign class and is therefore reported apart from
  -- every other one rather than added into a total nobody can read.
  local fizz, refu, dRate, dLate, clmp, bk, bt, apm = 0, 0, 0, 0, 0, 0, 0, 0
  for i = 1, NL do
    fizz = fizz + stat[i].fizzled
    refu = refu + stat[i].refused
    dRate = dRate + stat[i].declinedRate
    dLate = dLate + stat[i].declinedLate
    clmp = clmp + stat[i].clamped
    bk = bk + stat[i].badKind
    bt = bt + stat[i].badTarget
    if stat[i].atomsPerMinMax > apm then apm = stat[i].atomsPerMinMax end
  end
  r.fizzled, r.refused, r.badKind, r.badTarget = fizz, refu, bk, bt
  r.declinedRate, r.declinedLate, r.clamped = dRate, dLate, clmp
  r.declined = dRate + dLate    -- the total, for anything that still wants one
  r.atomsPerMinMax = apm

  return r
end

return M
