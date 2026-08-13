-- harness/selftest.lua -- the fast suite. Seconds, not minutes.
--
-- The fuzzer proves that two runs of the same input agree. That is necessary and
-- it is not sufficient: two runs of a sim that computes the WRONG answer agree
-- just as happily. This file is the other half -- it asserts outcomes derived by
-- hand from Part C, so a rule that changes silently is caught here rather than
-- being certified as "deterministically wrong" by the fuzzer.
--
-- Sections:
--   1  PRNG: known-answer test against an independent re-implementation
--   2  hash: rendering, and that every accumulator actually moves the state hash
--   3  the hand-written log, asserted tick by tick
--   4  economy: stipend, Levy cadence, bank cap, waste accounting, spoils
--   5  combat and terminal conditions: mutual kill, razed keep, double raze
--   6  the clock: every tier of the Q10 ladder, and one that cannot fire
--   7  caps: lane supply, slot count, slot class, card gate
--   8  queueCommand's refusals
--   9  determinism in miniature, including a reordered arrival
--
-- Scenarios that poke state directly (a keep pre-damaged so the raze is 300
-- ticks rather than 30,000) do it through helpers that keep the sim's accounting
-- identities true, so runner.invariants stays meaningful on them.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local SimM = require("sim.Sim")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")
local logfmt = require("harness.logfmt")
local runner = require("harness.runner")
local gen = require("harness.gen")

local C = Rules.C
local floor = math.floor

-- ---------------------------------------------------------------------------
-- tiny test scaffolding
-- ---------------------------------------------------------------------------

local nChecks, nFails = 0, 0
local section = "?"

local function sec(name)
  section = name
  print("  " .. name)
end

local function ck(cond, fmt, ...)
  nChecks = nChecks + 1
  if not cond then
    nFails = nFails + 1
    print(string.format("    FAIL [%s] " .. fmt, section, ...))
  end
end

local function eq(got, want, what)
  ck(got == want, "%s: got %s, want %s", what, tostring(got), tostring(want))
end

-- ---------------------------------------------------------------------------
-- sim helpers
-- ---------------------------------------------------------------------------

local function fresh(seed)
  return SimM.new(Rules, seed or 1)
end

local function q(sim, side, seq, tick, kind, target, count)
  return sim:queueCommand({ side = side, seq = seq, tick = tick,
                            kind = kind, target = target, count = count })
end

local function runTo(sim, n)
  for _ = 1, n do
    if not sim:tick() then return false end
  end
  return true
end

-- Grant Levy the way credit() does minus the cap, so bank == earned - wasted -
-- spent still holds and runner.invariants stays usable on the scenario.
local function grant(sd, amt)
  sd.bank = sd.bank + amt
  sd.earned = sd.earned + amt
end

-- Pre-damage a keep. Booking the same amount as damage dealt by the other side
-- keeps the tier-1 counter the exact complement of keep HP, which is the
-- identity the sim maintains and runner.invariants checks.
local function weakenKeep(sim, side, hp)
  local sd, es = sim.sides[side], sim.sides[3 - side]
  es.keepDamageDealt = es.keepDamageDealt + (sd.keepHp - hp)
  sd.keepHp = hp
end

local function invariantsOk(sim, what)
  local ok, problems = runner.invariants(sim)
  ck(ok, "%s: invariants failed", what)
  if not ok then
    for i = 1, #problems do print("      " .. problems[i]) end
  end
end

print(string.format("selftest: ruleset %s  rulesHash %s (%s)",
  Rules.RULESET_VERSION, Hash.dec(Rules.rulesHash), Rules.rulesHash36))

-- ===========================================================================
sec("1  PRNG -- known answers, independent implementation, bounds")
-- ===========================================================================

-- Re-implemented from the parameters documented in sim/Rand.lua, not copied from
-- its code: A = 1664525, C = 1013904223, modulus 2^32, seed folded by
-- +2463534242, and every public draw assembled from the HIGH 16 bits of a step
-- (the low bits of a power-of-two LCG have short periods and must never be
-- exposed). If the two implementations agree for 10,000 draws, the generator in
-- the sim is the one that was specified.
local REF_A, REF_C, REF_M = 1664525, 1013904223, 4294967296

local function refNew(seed)
  return ((seed % REF_M) + 2463534242) % REF_M
end
local function refStep(s)
  return (REF_A * s + REF_C) % REF_M
end
local function refNext32(s)
  local a = refStep(s)
  local b = refStep(a)
  return floor(a / 65536) * 65536 + floor(b / 65536), b
end

do
  ck(Rand.selftest(), "sim/Rand.lua self-test failed")

  -- The generator's own golden vector, verified against the reference here so
  -- the vector cannot drift with the code it is meant to pin.
  local s = refNew(Rand.SELFTEST_SEED)
  local okVec = true
  for i = 1, #Rand.SELFTEST_EXPECT do
    local v
    v, s = refNext32(s)
    if v ~= Rand.SELFTEST_EXPECT[i] then okVec = false end
  end
  ck(okVec, "Rand.SELFTEST_EXPECT disagrees with an independent implementation")

  local r = Rand.new(20260812)
  s = refNew(20260812)
  local same, intOk, rangeOk = true, true, true
  for _ = 1, 10000 do
    local got = Rand.next32(r)
    local want
    want, s = refNext32(s)
    if got ~= want then same = false end
    if got ~= floor(got) then intOk = false end
    if got < 0 or got >= REF_M then rangeOk = false end
  end
  ck(same, "Rand.next32 diverged from the reference LCG inside 10,000 draws")
  ck(intOk, "Rand.next32 produced a non-integer")
  ck(rangeOk, "Rand.next32 left [0, 2^32)")

  -- range() must stay inside its bounds and must reach both ends.
  local r2 = Rand.new(99)
  local lo, hi = 3, 7
  local seen = { 0, 0, 0, 0, 0, 0, 0 }
  local inBounds = true
  for _ = 1, 4000 do
    local v = Rand.range(r2, lo, hi)
    if v < lo or v > hi then inBounds = false else seen[v] = seen[v] + 1 end
  end
  ck(inBounds, "Rand.range left its bounds")
  local allHit = true
  for v = lo, hi do
    if seen[v] == 0 then allHit = false end
  end
  ck(allHit, "Rand.range never produced some value in [%d, %d]", lo, hi)
  eq(Rand.range(Rand.new(5), 4, 4), 4, "Rand.range on a single-value span")

  -- Clones must not share state, and the same seed must replay exactly.
  local a, b = Rand.new(31337), Rand.new(31337)
  local match = true
  for _ = 1, 500 do
    if Rand.next32(a) ~= Rand.next32(b) then match = false end
  end
  ck(match, "two generators on one seed diverged")

  -- The permutation the fuzzer shuffles arrival order with must be reproducible
  -- and must actually be a permutation.
  local p1 = gen.permutation(50, 12345)
  local p2 = gen.permutation(50, 12345)
  local samePerm, isPerm = true, true
  local mark = {}
  for i = 1, 50 do
    if p1[i] ~= p2[i] then samePerm = false end
    if mark[p1[i]] then isPerm = false end
    mark[p1[i]] = true
  end
  for i = 1, 50 do
    if not mark[i] then isPerm = false end
  end
  ck(samePerm, "gen.permutation is not reproducible from its seed")
  ck(isPerm, "gen.permutation is not a permutation")
end

-- ===========================================================================
sec("2  hash -- rendering, and coverage of every accumulator")
-- ===========================================================================

do
  -- Rendering must not go through tostring or %d on a number: 5.1 and 5.3 print
  -- numbers differently, and the wire carries these characters.
  local h = Rules.rulesHash
  eq(#Hash.base36(h, 6), 6, "base36 width 6")
  eq(#Hash.base36(h, 5), 5, "base36 width 5")
  eq(Hash.base36(0, 5), "00000", "base36 of zero")
  eq(Hash.dec(0), "0", "dec of zero")
  eq(Hash.dec(1234567), "1234567", "dec of a known value")
  eq(Hash.dec(h), string.format("%d", h % Hash.MOD), "dec matches the platform formatter")
  local alphabetOk = true
  local s36 = Hash.base36(h, 6)
  for i = 1, #s36 do
    local c = string.sub(s36, i, i)
    if not string.find("0123456789abcdefghijklmnopqrstuvwxyz", c, 1, true) then alphabetOk = false end
  end
  ck(alphabetOk, "base36 produced a character outside the alphabet")

  -- Folding must be order sensitive and value sensitive.
  ck(Hash.int(Hash.int(Hash.new(), 1), 2) ~= Hash.int(Hash.int(Hash.new(), 2), 1),
    "Hash.int is order insensitive")
  ck(Hash.str(Hash.new(), "ab") ~= Hash.str(Hash.new(), "ba"), "Hash.str is order insensitive")
  ck(Hash.str(Hash.new(), "a") ~= Hash.str(Hash.new(), ""), "Hash.str ignores content")
  ck(Hash.int(Hash.new(), -1) ~= Hash.int(Hash.new(), 1), "Hash.int folds -1 and 1 alike")
  eq(Hash.int(Hash.new(), 7), Hash.int(Hash.new(), 7), "Hash.int is not a pure function")

  -- M1's headline requirement: the state hash covers Levy, bank, every
  -- accumulator and every tiebreak counter, not just the board. Each mutation
  -- below is one field, on a fresh sim, and every one of them must move it.
  local muts = {
    { "bank",            function(s) s.sides[1].bank = s.sides[1].bank + 1 end },
    { "earned",          function(s) s.sides[1].earned = s.sides[1].earned + 1 end },
    { "wasted",          function(s) s.sides[2].wasted = s.sides[2].wasted + 1 end },
    { "spent",           function(s) s.sides[1].spent = s.sides[1].spent + 1 end },
    { "keepHp",          function(s) s.sides[2].keepHp = s.sides[2].keepHp - 1 end },
    { "keepDamageDealt", function(s) s.sides[1].keepDamageDealt = 1 end },
    { "slotsDestroyed",  function(s) s.sides[1].slotsDestroyed = 1 end },
    { "unitsDeployed",   function(s) s.sides[2].unitsDeployed = 1 end },
    { "unitsLost",       function(s) s.sides[1].unitsLost = 1 end },
    { "unitsKilled",     function(s) s.sides[1].unitsKilled = 1 end },
    { "bldLost",         function(s) s.sides[2].bldLost = 1 end },
    { "cmdsExecuted",    function(s) s.sides[1].cmdsExecuted = 1 end },
    { "cmdsFizzled",     function(s) s.sides[2].cmdsFizzled = 1 end },
    { "wheelNum",        function(s) s.sides[1].wheelNum = 5 end },
    { "lane supply",     function(s) s.sides[1].lanes[2].supply = 10 end },
    { "lane depth",      function(s) s.sides[2].lanes[3].depth = 1 end },
    { "hold1",           function(s) s.sides[1].lanes[1].hold1 = 1 end },
    { "hold2",           function(s) s.sides[1].lanes[1].hold2 = 1 end },
    { "hold3",           function(s) s.sides[2].lanes[2].hold3 = 1 end },
    { "muster",          function(s) s.sides[1].lanes[1].muster = 1 end },
    { "bypass",          function(s) s.sides[1].lanes[1].bypass = 1 end },
    { "cwAcc",           function(s) s.sides[2].lanes[1].cwAcc = 1 end },
    { "rubble",          function(s) s.sides[1].rubble[3] = 1 end },
    { "channel points",  function(s) s.sides[1].chan[1] = 5 end },
    { "loadout",         function(s) s.sides[2].loadout[3] = 9 end },
    { "clock",           function(s) s.clock = s.clock + 1 end },
    { "winner",          function(s) s.winner = 1 end },
    { "over",            function(s) s.over = true end },
    { "tier",            function(s) s.tier = 3 end },
    { "reasonCode",      function(s) s.reasonCode = 2 end },
    { "nextEntityId",    function(s) s.nextEntityId = s.nextEntityId + 1 end },
    { "rng state",       function(s) s.rng.s = s.rng.s + 1 end },
    { "seed",            function(s) s.seed = s.seed + 1 end },
  }
  for i = 1, #muts do
    local sim = fresh(5)
    local h0 = sim:stateHash()
    muts[i][2](sim)
    ck(sim:stateHash() ~= h0, "stateHash does not cover %s", muts[i][1])
  end

  -- Board content: a deployed unit and a placed building must both move it.
  do
    local sim = fresh(5)
    local h0 = sim:stateHash()
    q(sim, 1, 1, 0, "S", 1, 1)
    sim:tick()
    ck(sim:stateHash() ~= h0, "stateHash does not cover a deployed unit")
    local h1 = sim:stateHash()
    sim.sides[1].lanes[1].units[1].hp = sim.sides[1].lanes[1].units[1].hp - 1
    ck(sim:stateHash() ~= h1, "stateHash does not cover unit HP")
    local h2 = sim:stateHash()
    sim.sides[1].lanes[1].units[1].pos = sim.sides[1].lanes[1].units[1].pos + 1
    ck(sim:stateHash() ~= h2, "stateHash does not cover unit position")
  end
  do
    local sim = fresh(5)
    grant(sim.sides[2], 200)
    q(sim, 2, 1, 0, "a", 1, 1)
    sim:tick()
    ck(sim.sides[2].slots[1] ~= false, "the trap pit was not placed")
    local h1 = sim:stateHash()
    sim.sides[2].slots[1].prog = sim.sides[2].slots[1].prog + 1
    ck(sim:stateHash() ~= h1, "stateHash does not cover construction progress")
    local h2 = sim:stateHash()
    sim.sides[2].slots[1].hp = sim.sides[2].slots[1].hp - 1
    ck(sim:stateHash() ~= h2, "stateHash does not cover building HP")
  end

  -- The log digest is a separate artifact and must track the ordered log.
  do
    local s1, s2 = fresh(5), fresh(5)
    q(s1, 1, 1, 30, "S", 1, 1)
    q(s2, 1, 1, 31, "S", 1, 1)
    ck(s1:logDigest() ~= s2:logDigest(), "logDigest does not cover the exec tick")
    local s3, s4 = fresh(5), fresh(5)
    q(s3, 1, 1, 30, "S", 1, 1); q(s3, 2, 1, 30, "S", 2, 1)
    q(s4, 2, 1, 30, "S", 2, 1); q(s4, 1, 1, 30, "S", 1, 1)
    eq(s3:logDigest(), s4:logDigest(), "logDigest depends on arrival order")
  end
end

-- ===========================================================================
sec("3  the hand-written log, asserted tick by tick")
-- ===========================================================================

-- Golden values, keyed to the ruleset they were computed under.
--
-- These are the ONLY committed expected hashes in the tree, and they are what
-- makes the whole harness more than a self-consistency check. Every other test
-- runs the sim two or three times in one process and compares the runs against
-- each other: if the arithmetic itself differed -- a different interpreter, a
-- different CPU, a perturbed Hash.MUL -- every hash in the run would move
-- together, all the intra-process comparisons would still agree, and the gate
-- would go green while two real clients computed different matches. Comparing
-- against a NUMBER WRITTEN DOWN is the only thing that catches that.
--
-- Recorded on an arm64 macOS build of Lua 5.5. Part E's milestone is bit-identical
-- state on two machines with different CPUs; running this file on the second
-- machine and getting the same three numbers is the cheapest version of that
-- test, and it is also the artifact WoW's Lua 5.1 must reproduce later.
--
-- THESE ARE ASSERTED, NOT SKIPPED. The old code disabled the comparison whenever
-- rulesHash moved, which meant a change to the hash layer silently switched the
-- only cross-machine check off. A ruleset change is a deliberate act (G.4 makes
-- it a hard compatibility break), so it must go RED until all three values are
-- regenerated in the same commit -- the failure path prints the new numbers.
local GOLDEN_RULESHASH = 297242539     -- 4wyxt7
local GOLDEN_STATE = 353655329         -- stateHash of hand.iblog at tick 260
local GOLDEN_LOGDIGEST = 1455081792

do
  local log, err = logfmt.load(here .. "/logs/hand.iblog")
  ck(log ~= nil, "hand.iblog did not parse: %s", tostring(err))
  if log then
    eq(#log.cmds, 2, "hand log command count")
    eq(log.seed, 4242, "hand log seed")
    eq(log.cmds[1].arrive, 5, "hand log arrive tick")

    -- Round trip: render then re-parse must be identical, or the replay artifact
    -- is not an artifact.
    local text = logfmt.render(log)
    local log2 = logfmt.parse(text, "roundtrip")
    ck(log2 ~= nil, "rendered log did not re-parse")
    if log2 then
      eq(#log2.cmds, #log.cmds, "round-trip command count")
      eq(log2.cmds[2].tick, log.cmds[2].tick, "round-trip exec tick")
      eq(log2.seed, log.seed, "round-trip seed")
    end

    -- tick 250: 26 hits of 16 have landed since tick 120, both spears on 4 HP.
    local t = runner.run(log, { ticks = 250, keepSim = true })
    local sim = t.sim
    eq(sim.clock, 250, "clock after 250 ticks")
    for s = 1, 2 do
      local us = sim.sides[s].lanes[1].units
      eq(#us, 1, string.format("side %d still has its spear at tick 250", s))
      if us[1] then
        eq(us[1].pos, 970, string.format("side %d spear halted at 970", s))
        eq(us[1].hp, 4, string.format("side %d spear HP after 26 hits", s))
        eq(us[1].maxHp, 420, string.format("side %d spear max HP", s))
      end
      eq(sim.sides[s].lanes[1].supply, 10, string.format("side %d lane supply", s))
    end
    invariantsOk(sim, "hand log at tick 250")

    -- tick 251: the 27th hit kills both on the same resolve tick.
    sim:tick()
    eq(sim.clock, 251, "clock after the killing tick")
    for s = 1, 2 do
      local sd = sim.sides[s]
      eq(#sd.lanes[1].units, 0, string.format("side %d lane is empty", s))
      eq(sd.lanes[1].supply, 0, string.format("side %d supply returned to zero", s))
      eq(sd.unitsDeployed, 1, string.format("side %d unitsDeployed", s))
      eq(sd.unitsLost, 1, string.format("side %d unitsLost", s))
      eq(sd.unitsKilled, 1, string.format("side %d unitsKilled", s))
      eq(sd.cmdsExecuted, 1, string.format("side %d cmdsExecuted", s))
      eq(sd.cmdsFizzled, 0, string.format("side %d cmdsFizzled", s))
      -- 30 stipend + 7 Levy ticks of 10 (35..245) - 10 spent
      eq(sd.bank, 90, string.format("side %d bank", s))
      eq(sd.earned, 100, string.format("side %d earned", s))
      eq(sd.spent, 10, string.format("side %d spent", s))
      eq(sd.wasted, 0, string.format("side %d wasted", s))
      eq(sd.keepHp, C.KEEP_HP, string.format("side %d keep untouched", s))
      eq(sd.keepDamageDealt, 0, string.format("side %d dealt no keep damage", s))
    end
    ck(not sim.over, "the match ended early")
    invariantsOk(sim, "hand log at tick 251")

    -- No repel refund: the mutual kill happened at 970, inside both own halves.
    eq(sim.sides[1].earned, sim.sides[2].earned, "the two sides earned differently")

    -- Full budget: golden hashes.
    local full = runner.run(log, { keepSim = true })
    eq(full.terminalTick, 260, "hand log terminal tick")
    if Rules.rulesHash ~= GOLDEN_RULESHASH
      or full.terminal ~= GOLDEN_STATE
      or full.logDigest ~= GOLDEN_LOGDIGEST then
      -- Printed on the FAILURE path so the new values are visible while the
      -- build stays red. Copy all three together or not at all.
      print(string.format("    regenerate together: rulesHash %s (%s)  stateHash %s  logDigest %s",
        Hash.dec(Rules.rulesHash), Rules.rulesHash36,
        Hash.dec(full.terminal), Hash.dec(full.logDigest)))
    end
    eq(Rules.rulesHash, GOLDEN_RULESHASH,
      "rulesHash changed -- regenerate GOLDEN_STATE and GOLDEN_LOGDIGEST in the same commit")
    eq(full.terminal, GOLDEN_STATE, "hand log golden stateHash")
    eq(full.logDigest, GOLDEN_LOGDIGEST, "hand log golden logDigest")

    -- The same log delivered on its arrive ticks, and shuffled, is the same match.
    local arr = runner.run(log, { arrival = true })
    local okA, _, det = runner.compare(full, arr)
    ck(okA, "hand log diverged when delivered on arrival ticks: %s", det)
    local rev = runner.run(log, { order = { 2, 1 } })
    local okB, _, det2 = runner.compare(full, rev)
    ck(okB, "hand log diverged when queued in reverse: %s", det2)
  end
end

-- ===========================================================================
sec("4  economy -- stipend, Levy cadence, bank cap, waste, spoils")
-- ===========================================================================

do
  -- The stipend lands at tick 0 and Levy ticks fire at 35, 70, ... (C.2 and the
  -- interpretation note in Rules.lua).
  local sim = fresh(2)
  eq(sim.sides[1].bank, C.OPENING_STIPEND, "opening stipend")
  eq(sim.sides[1].earned, C.OPENING_STIPEND, "stipend counted as earned")
  runTo(sim, 35)                      -- ticks 0..34, no Levy tick yet
  eq(sim.sides[1].bank, 30, "bank before the first Levy tick")
  sim:tick()                          -- tick 35
  eq(sim.sides[1].bank, 40, "bank after the first Levy tick")
  runTo(sim, 35)                      -- through tick 70
  eq(sim.sides[1].bank, 50, "bank after the second Levy tick")

  -- 171 Levy ticks over a full match: 30 + 1710 = 1740 base Levy (C.2).
  local n = floor((C.MATCH_TICKS - 1) / C.LEVY_EVERY)
  eq(n, 171, "Levy ticks in a match")
  eq(C.OPENING_STIPEND + n * C.BASE_INCOME, 1740, "total base Levy in a match")
end

do
  -- The bank cap clips, and everything clipped is booked as wasted so the ledger
  -- still balances. Golden Age reads `earned`, which is why it must not be
  -- clipped (the interpretation note in Rules.lua, item 8).
  local sim = fresh(3)
  local sd = sim.sides[1]
  sd.bank = C.BANK_CAP - 5
  sd.earned = sd.earned + (C.BANK_CAP - 5 - C.OPENING_STIPEND)
  runTo(sim, 36)                      -- one Levy tick of 10 into a bank 5 short
  eq(sd.bank, C.BANK_CAP, "bank clipped at the cap")
  eq(sd.wasted, 5, "the clipped Levy was booked as wasted")
  eq(sd.earned, C.BANK_CAP - 5 + 10, "earned counts Levy the cap threw away")
  invariantsOk(sim, "bank cap")

  -- A completed Granary raises the cap by 150 and income by 1 (C.4).
  local s2 = fresh(3)
  grant(s2.sides[1], 170)             -- 200 in hand, enough for a 100 Granary
  q(s2, 1, 1, 0, "d", 2, 1)           -- slot 2 is lane 1's back slot
  -- The order EXECUTES on tick 0, which is itself a resolve tick. That resolve
  -- pass pays for the 5 ticks that just elapsed, and the Granary existed for none
  -- of them, so it is not credited (b.startTick). Progress therefore comes from
  -- the resolve ticks 5, 10, ... 120 -- 24 of them, 24 * 5 = 120 = its build
  -- time. It completes on tick 120 exactly, not on tick 115.
  runTo(s2, 120)                      -- executes ticks 0 .. 119
  eq(s2.sides[1].slots[2].done, 0, "Granary complete before its C.4 build time")
  runTo(s2, 1)                        -- executes tick 120, the 24th resolve tick
  eq(s2.sides[1].slots[2].done, 1, "Granary not complete at its build time")
  eq(s2.sides[1].cacheLevyFlat, 1, "Granary levyFlat")
  eq(s2.sides[1].cacheBankCap, 150, "Granary bankCapFlat")
  -- 200 - 100 spent, Levy ticks at 35, 70, 105 of 10, then 140 of 11
  runTo(s2, 20)                       -- through tick 140
  eq(s2.sides[1].bank, 100 + 30 + 11, "bank after the Granary's first Levy tick")
  invariantsOk(s2, "granary")
end

do
  -- Spoils: razing a building pays 75 percent of what it cost (C.2, Q1).
  local sim = fresh(4)
  local sd = sim.sides[2]
  grant(sd, 200)
  q(sim, 2, 1, 0, "c", 1, 1)          -- palisade, 90 Levy, 8800 HP, front slot
  runTo(sim, 130)                     -- built at tick 115
  eq(sd.slots[1].done, 1, "palisade complete")
  local b = sd.slots[1]
  b.hp = 1                            -- one hit from destruction
  local before = sim.sides[1].bank
  grant(sim.sides[1], 0)
  q(sim, 1, 1, 200, "S", 1, 1)
  runTo(sim, 600)                     -- the spear walks up and knocks it over
  eq(sd.slots[1], false, "palisade survived")
  eq(sim.sides[1].slotsDestroyed, 1, "tier-2 counter")
  eq(sd.bldLost, 1, "bldLost")
  eq(sd.rubble[1], 1, "rubble mark left behind")
  ck(sim.sides[1].earned > before, "spoils were not paid")
  eq(floor(90 * C.SPOILS_PCT / 100), 67, "spoils arithmetic")
  invariantsOk(sim, "spoils")
end

do
  -- Repel refund: a unit that dies past the midline pays the defender 15 percent
  -- of what it ACTUALLY cost (C.2) -- cost paid, not catalogue cost, so a
  -- discounted unit refunds less. Side 1's spear is walked over the midline and
  -- left on 1 HP; side 2's spear meets it and kills it in its own half.
  local sim = fresh(9)
  q(sim, 1, 1, 0, "S", 1, 1)
  q(sim, 2, 1, 1, "S", 1, 1)
  sim:tick()
  local unit = sim.sides[1].lanes[1].units[1]
  unit.pos = C.POS_MIDLINE + 100
  unit.hp = 1
  runTo(sim, 399)
  eq(sim.sides[1].unitsLost, 1, "the deep spear survived")
  ck(sim.sides[2].lanes[1].units[1] ~= nil, "the defending spear died too")
  eq(floor(10 * C.REPEL_REFUND_PCT / 100), 1, "repel refund arithmetic")
  -- 30 stipend + 11 Levy ticks of 10 by tick 400 + the 1 Levy refund
  local levyTicks = floor((sim.clock - 1) / C.LEVY_EVERY)
  eq(sim.sides[2].earned, 30 + 10 * levyTicks + 1, "repel refund credited")
  eq(sim.sides[1].earned, 30 + 10 * levyTicks, "the attacker was paid a refund")
  invariantsOk(sim, "repel refund")
end

-- ===========================================================================
sec("5  combat and terminal conditions")
-- ===========================================================================

do
  -- The counter triangle: spear into horse is 150 percent, horse into spear is
  -- flat (C.3: no penalty term, only the bonus into your prey).
  local base = Rules.UNITS
  eq(base[1].prey, 2, "spear preys on horse")
  eq(base[2].prey, 3, "horse preys on bow")
  eq(base[3].prey, 1, "bow preys on spear")
  eq(floor(base[1].dmg * C.COUNTER_PCT / 100), 24, "spear into horse")
  eq(floor(base[2].dmg * C.COUNTER_PCT / 100), 66, "horse into bow")
  -- Every unit deals half damage to structures.
  eq(floor(base[1].dmg * C.STRUCTURE_DMG_PCT * 100 / 10000), 8, "spear into a structure")
end

do
  -- Razed keep. The keep is pre-damaged so the test costs 300 ticks instead of
  -- 30,000; the raze path is what is under test, not the grind.
  local sim = fresh(11)
  weakenKeep(sim, 2, 200)
  q(sim, 1, 1, 0, "S", 1, 1)
  runTo(sim, 400)
  ck(sim.over, "the keep did not fall")
  eq(sim.winner, 1, "winner by raze")
  eq(sim.reason, "keep", "terminal reason")
  eq(sim.reasonCode, Rules.REASON.KEEP, "terminal reason code")
  eq(sim.tier, 0, "tier is zero for a raze")
  eq(sim.clock, 316, "the tick the keep fell")
  eq(sim.sides[2].keepHp, 0, "keep HP floor")
  eq(sim.sides[1].keepDamageDealt, C.KEEP_HP, "tier-1 counter after the raze")
  eq(sim:tick(), false, "a terminal sim kept ticking")
  eq(sim.clock, 316, "a terminal sim advanced its clock")
  invariantsOk(sim, "razed keep")

  -- The unit halted at spear range from the keep and got there when it should.
  local u = sim.sides[1].lanes[1].units[1]
  eq(u.pos, C.LANE_LEN - Rules.UNITS[1].range, "spear halted at range from the keep")
end

do
  -- Both keeps falling on the same resolve tick is a draw, not a win for
  -- whichever side the loop happened to visit second. Symmetric lanes, so the
  -- two spears never meet.
  local sim = fresh(12)
  weakenKeep(sim, 1, 200)
  weakenKeep(sim, 2, 200)
  q(sim, 1, 1, 0, "S", 1, 1)
  q(sim, 2, 1, 0, "S", 2, 1)
  runTo(sim, 400)
  ck(sim.over, "neither keep fell")
  eq(sim.winner, 0, "a simultaneous double raze is a draw")
  eq(sim.reason, "keep", "double raze reason")
  eq(sim.clock, 316, "double raze tick")
  invariantsOk(sim, "double raze")
end

do
  -- Tier-3 depth is "held for 50 consecutive ticks", never a final snapshot.
  -- One spear walking an empty lane crosses 1300 at tick 129, 1500 at 149 and
  -- 1700 at 169, so the three bands latch 49 ticks after each.
  local sim = fresh(13)
  q(sim, 1, 1, 0, "S", 1, 1)
  runTo(sim, 178)
  eq(sim.sides[1].lanes[1].depth, 0, "depth latched before its hold completed")
  runTo(sim, 1)
  eq(sim.sides[1].lanes[1].depth, 1, "depth band 1 did not latch at 50 held ticks")
  runTo(sim, 20)
  eq(sim.sides[1].lanes[1].depth, 2, "depth band 2")
  runTo(sim, 20)
  eq(sim.sides[1].lanes[1].depth, 3, "depth band 3")
  eq(sim.sides[2].lanes[1].depth, 0, "the idle side latched depth")
  invariantsOk(sim, "depth hold")

  -- A unit that touches a band and dies banks nothing.
  local s2 = fresh(14)
  q(s2, 1, 1, 0, "S", 1, 1)
  runTo(s2, 140)                      -- past 1300, well short of 50 held ticks
  local u = s2.sides[1].lanes[1].units[1]
  ck(u.pos >= C.DEPTH_X1, "the spear never reached the first band")
  ck(s2.sides[1].lanes[1].hold1 > 0, "the hold timer never started")
  -- Remove it from the board and confirm the timer resets rather than latching.
  s2.sides[1].lanes[1].units = {}
  s2.sides[1].lanes[1].supply = 0
  runTo(s2, 60)
  eq(s2.sides[1].lanes[1].hold1, 0, "the hold timer did not reset")
  eq(s2.sides[1].lanes[1].depth, 0, "a touched band latched without being held")
end

-- ===========================================================================
sec("6  the clock -- every tier of the Q10 ladder")
-- ===========================================================================

-- Drive a sim to the hard cap with the ladder inputs set by hand. Setting the
-- clock directly is exactly what the sim does between ticks, and it keeps each
-- tier isolated: what is under test is finishByClock's ordering, not the ability
-- to construct an elaborate match that happens to reach it.
local function atClock(setup)
  local sim = fresh(21)
  sim.clock = C.MATCH_TICKS - 1
  if setup then setup(sim) end
  sim:tick()
  return sim
end

do
  local s1 = atClock(function(s) weakenKeep(s, 2, C.KEEP_HP - 5); weakenKeep(s, 1, C.KEEP_HP - 3) end)
  ck(s1.over, "the match did not end on the clock")
  eq(s1.reason, "clock", "clock reason")
  eq(s1.reasonCode, Rules.REASON.CLOCK, "clock reason code")
  eq(s1.tier, 1, "tier 1 fires on keep HP removed")
  eq(s1.winner, 1, "tier 1 winner")

  local s1b = atClock(function(s) weakenKeep(s, 1, C.KEEP_HP - 9) end)
  eq(s1b.tier, 1, "tier 1 for the other side")
  eq(s1b.winner, 2, "tier 1 winner is the side that dealt more")

  local s2 = atClock(function(s)
    s.sides[1].slotsDestroyed = 2; s.sides[2].bldLost = 2
  end)
  eq(s2.tier, 2, "tier 2 fires on slots destroyed")
  eq(s2.winner, 1, "tier 2 winner")

  local s3 = atClock(function(s)
    s.sides[1].slotsDestroyed = 1; s.sides[2].bldLost = 1
    s.sides[2].slotsDestroyed = 1; s.sides[1].bldLost = 1
    s.sides[2].lanes[1].depth = 3; s.sides[2].lanes[2].depth = 1
    s.sides[1].lanes[1].depth = 2
  end)
  eq(s3.tier, 3, "tier 3 fires on penetration")
  eq(s3.winner, 2, "tier 3 winner (4 bands to 2)")

  local s5 = atClock(nil)
  eq(s5.tier, 5, "an untouched match is a draw")
  eq(s5.winner, 0, "draw winner")

  -- Ordering: a higher tier decides even when a lower one disagrees.
  local prec = atClock(function(s)
    weakenKeep(s, 2, C.KEEP_HP - 1)   -- side 1 is ahead on tier 1
    s.sides[2].slotsDestroyed = 5     -- side 2 is ahead on tier 2
    s.sides[1].bldLost = 5
    s.sides[2].lanes[1].depth = 3     -- and on tier 3
  end)
  eq(prec.tier, 1, "the ladder is evaluated out of order")
  eq(prec.winner, 1, "the wrong side won a laddered match")

  -- TIER 4 IS UNREACHABLE, and this test pins the finding rather than the wish.
  -- Tier 1 is cumulative damage dealt to the ENEMY keep; keeps never heal and
  -- damage is capped at the remaining pool before it is banked, so
  --     a.keepDamageDealt == KEEP_HP - b.keepHp   exactly, all match.
  -- Tier 1 therefore ties if and only if the two keeps are on equal HP, which is
  -- exactly the condition under which tier 4 would have to decide. Reaching tier
  -- 4 requires an inconsistent state that this sim cannot produce.
  local t4 = atClock(function(s)
    s.sides[1].keepHp = C.KEEP_HP - 100         -- inconsistent on purpose
  end)
  eq(t4.tier, 4, "tier 4 does not fire even from an inconsistent state")
  eq(t4.winner, 2, "tier 4 winner")
  local consistent = atClock(function(s) weakenKeep(s, 1, C.KEEP_HP - 100) end)
  eq(consistent.tier, 1, "a real keep-HP difference resolves at tier 1, not 4")
  eq(Rules.TIERS[4], "ownKeepHp", "tier 4's name moved")
end

-- ===========================================================================
sec("7  caps -- lane supply, slot count, slot class, card gate")
-- ===========================================================================

do
  -- Lane supply cap: 200 Levy of units per side per lane, charged at BASE cost
  -- and immune to every modifier (Q4). Money is taken out of the picture so the
  -- cap is the only thing that can bind.
  local sim = fresh(31)
  grant(sim.sides[1], 5000)
  q(sim, 1, 1, 0, "S", 1, 9)
  q(sim, 1, 2, 0, "S", 1, 9)
  q(sim, 1, 3, 0, "S", 1, 9)          -- only 2 of these 9 fit
  q(sim, 1, 4, 0, "S", 1, 9)          -- and this one cannot place a single unit
  sim:tick()
  local ln = sim.sides[1].lanes[1]
  eq(#ln.units, 20, "units placed before the supply cap bound")
  eq(ln.supply, C.LANE_SUPPLY_CAP, "lane supply at the cap")
  eq(sim.sides[1].cmdsExecuted, 3, "orders that placed at least one unit")
  eq(sim.sides[1].cmdsFizzled, 1, "the order that could place nothing")
  eq(sim.sides[1].spent, 200, "Levy spent on 20 spears")
  -- The cap is per lane, not per side.
  q(sim, 1, 5, 1, "S", 2, 9)
  sim:tick()
  eq(#sim.sides[1].lanes[2].units, 9, "the cap leaked across lanes")
  invariantsOk(sim, "supply cap")

  -- The count field is capped at 9 by the atom (A.11.2), so a 12 is not a 12.
  local s2 = fresh(32)
  grant(s2.sides[1], 5000)
  q(s2, 1, 1, 0, "S", 3, 12)
  s2:tick()
  eq(#s2.sides[1].lanes[3].units, C.MAX_UNITS_PER_ORDER, "count was not capped at 9")
end

do
  -- Slot cap: 4 occupied slots per side. A fifth order fizzles.
  local sim = fresh(33)
  grant(sim.sides[1], 5000)
  q(sim, 1, 1, 0, "a", 1, 1)          -- front
  q(sim, 1, 2, 0, "d", 2, 1)          -- back
  q(sim, 1, 3, 0, "a", 3, 1)          -- front
  q(sim, 1, 4, 0, "d", 4, 1)          -- back
  q(sim, 1, 5, 0, "a", 5, 1)          -- a legal fifth building, but the cap binds
  sim:tick()
  local occ = 0
  for s = 1, C.SLOTS do
    if sim.sides[1].slots[s] then occ = occ + 1 end
  end
  eq(occ, C.SLOT_CAP, "occupied slots")
  eq(sim.sides[1].slots[5], false, "the fifth building was placed anyway")
  eq(sim.sides[1].cmdsFizzled, 1, "the capped order did not fizzle")
  eq(sim.sides[1].cmdsExecuted, 4, "executed build orders")
  invariantsOk(sim, "slot cap")
end

do
  -- Slot class, occupied slot, card gate and affordability each fizzle on their
  -- own, in their own sim, so one rule cannot mask another.
  local cls = fresh(34)
  grant(cls.sides[1], 5000)
  q(cls, 1, 1, 0, "a", 2, 1)          -- trap pit is front class, slot 2 is back
  cls:tick()
  eq(cls.sides[1].slots[2], false, "a front building entered a back slot")
  eq(cls.sides[1].cmdsFizzled, 1, "slot class did not fizzle")

  local cls2 = fresh(34)
  grant(cls2.sides[1], 5000)
  q(cls2, 1, 1, 0, "d", 1, 1)         -- granary is back class, slot 1 is front
  cls2:tick()
  eq(cls2.sides[1].slots[1], false, "a back building entered a front slot")

  local occ = fresh(35)
  grant(occ.sides[1], 5000)
  q(occ, 1, 1, 0, "a", 1, 1)
  q(occ, 1, 2, 0, "b", 1, 1)          -- same slot, same tick
  occ:tick()
  eq(occ.sides[1].slots[1].b, Rules.BUILDING_BY_LETTER["a"], "the second build won the slot")
  eq(occ.sides[1].cmdsFizzled, 1, "the occupied slot did not fizzle")

  local gate = fresh(36)
  grant(gate.sides[1], 5000)
  q(gate, 1, 1, 0, "n", 2, 1)         -- caravan is card-gated until M3
  gate:tick()
  eq(gate.sides[1].slots[2], false, "a card-gated building was raised without the card")
  eq(gate.sides[1].cmdsFizzled, 1, "the card gate did not fizzle")

  local poor = fresh(37)              -- 30 Levy in hand, a 100 Levy granary
  q(poor, 1, 1, 0, "d", 2, 1)
  poor:tick()
  eq(poor.sides[1].slots[2], false, "an unaffordable building was raised")
  eq(poor.sides[1].cmdsFizzled, 1, "an unaffordable build did not fizzle")
  eq(poor.sides[1].bank, 30, "an unaffordable build still charged the bank")

  -- A fizzle has no side effect other than the counter, which is what lets the
  -- generator drop refused orders without changing the match.
  local ref = fresh(37)
  q(ref, 1, 1, 0, "d", 2, 1)
  ref:tick()
  local clean = fresh(37)
  clean:tick()
  clean.sides[1].cmdsFizzled = 1
  eq(ref:stateHash(), clean:stateHash(), "a fizzle moved state other than its counter")
end

do
  -- Under-construction buildings occupy the slot, carry full HP and block, but
  -- produce nothing (interpretation 4 in Rules.lua).
  local sim = fresh(38)
  grant(sim.sides[1], 5000)
  q(sim, 1, 1, 0, "d", 2, 1)
  sim:tick()
  local b = sim.sides[1].slots[2]
  ck(b ~= false, "the granary was not placed")
  eq(b.done, 0, "a fresh building is complete")
  eq(b.hp, b.maxHp, "a fresh building is not at full HP")
  eq(sim.sides[1].cacheLevyFlat, 0, "an unfinished granary is already paying out")
  eq(b.need, Rules.BUILDINGS[Rules.BUILDING_BY_LETTER["d"]].build, "build time")
end

-- ===========================================================================
sec("8  queueCommand refusals")
-- ===========================================================================

do
  local sim = fresh(41)
  local ok, err
  ok, err = sim:queueCommand({ side = 3, seq = 1, tick = 10, kind = "S", target = 1, count = 1 })
  eq(ok, false, "side 3 was accepted"); eq(err, "side", "side error")
  ok, err = sim:queueCommand({ side = 1, seq = 0, tick = 10, kind = "S", target = 1, count = 1 })
  eq(ok, false, "seq 0 was accepted"); eq(err, "seq", "seq error")
  ok = sim:queueCommand({ side = 1, seq = 1, tick = 10, kind = "S", target = 1, count = 1 })
  eq(ok, true, "a legal command was refused")
  ok, err = sim:queueCommand({ side = 1, seq = 1, tick = 11, kind = "S", target = 1, count = 1 })
  eq(ok, false, "a duplicate seq was accepted"); eq(err, "duplicate", "duplicate error")
  ok, err = sim:queueCommand({ side = 1, seq = 2, tick = C.MATCH_TICKS, kind = "S", target = 1, count = 1 })
  eq(ok, false, "a command past the clock was accepted"); eq(err, "afterClock", "afterClock error")
  ok, err = sim:queueCommand({ side = 1, seq = 3, tick = 10, kind = "z", target = 1, count = 1 })
  eq(ok, false, "an unknown kind was accepted"); eq(err, "kind", "kind error")
  runTo(sim, 20)
  ok, err = sim:queueCommand({ side = 1, seq = 4, tick = 5, kind = "S", target = 1, count = 1 })
  eq(ok, false, "a late command was accepted"); eq(err, "late", "late error")
  -- Same seq from the other side is a different sender and must be accepted.
  ok = sim:queueCommand({ side = 2, seq = 1, tick = 30, kind = "S", target = 1, count = 1 })
  eq(ok, true, "per-sender sequencing is not per sender")
  -- The M3 verbs parse and fizzle, rather than being refused.
  ok = sim:queueCommand({ side = 2, seq = 2, tick = 30, kind = "i", target = 1, count = 1 })
  eq(ok, true, "an M3 verb was refused at queue time")
  runTo(sim, 20)
  eq(sim.sides[2].cmdsFizzled, 1, "an M3 verb did not fizzle in M1")

  -- target and count must be INTEGRAL. queueCommand is the only input gate and
  -- nothing downstream re-validates: a fractional target slips past the range
  -- guards and indexes sd.lanes / sd.slots off the integer grid, and a fractional
  -- count makes Hash.log's accumulator non-integral -- which throws inside
  -- string.sub on 5.3+ but truncates SILENTLY on 5.1, so one client would raise
  -- and the other would put a quietly wrong logDigest on the heartbeat.
  local g = fresh(42)
  local n = 0
  local function gate(label, cmd, want)
    n = n + 1
    cmd.side = 1; cmd.seq = n; cmd.tick = 100
    local gok, gerr = g:queueCommand(cmd)
    eq(gok and "accepted" or gerr, want, label)
  end
  gate("a fractional lane was accepted", { kind = "S", target = 1.5, count = 1 }, "target")
  gate("a fractional slot was accepted", { kind = "d", target = 2.5, count = 1 }, "target")
  gate("a string target was accepted", { kind = "S", target = "1", count = 1 }, "target")
  gate("a fractional count was accepted", { kind = "S", target = 1, count = 2.5 }, "count")
  gate("a string count was accepted", { kind = "S", target = 1, count = "2" }, "count")
  -- Range is NOT checked here on purpose: A.4 evaluates legality at the exec
  -- tick, so an out-of-range lane must still be accepted and fizzle in the sim.
  gate("an out-of-range lane was refused at the gate instead of fizzling",
    { kind = "S", target = 9, count = 1 }, "accepted")
  runTo(g, 120)
  eq(g.sides[1].cmdsFizzled, 1, "the out-of-range lane did not fizzle at exec")
  local dg = g:logDigest()
  ck(dg == floor(dg), "the log digest went non-integral")

  -- ORDER_DELAY is enforced when the caller supplies the atom's issue tick.
  local d = fresh(43)
  eq(select(2, d:queueCommand({ side = 1, seq = 1, tick = 100 + C.ORDER_DELAY - 1,
    issueTick = 100, kind = "S", target = 1, count = 1 })), "tooSoon",
    "an atom inside the order delay was accepted")
  eq(select(2, d:queueCommand({ side = 1, seq = 2, tick = 100 + C.ORDER_DELAY_CLAMP + 1,
    issueTick = 100, kind = "S", target = 1, count = 1 })), "tooLate",
    "an atom past the order-delay clamp was accepted")
  eq(d:queueCommand({ side = 1, seq = 3, tick = 100 + C.ORDER_DELAY,
    issueTick = 100, kind = "S", target = 1, count = 1 }), true,
    "an atom exactly at issue + ORDER_DELAY was refused")
end

do
  -- TWO DIVERGENCE SOURCES THAT LIVE OUTSIDE THE SIM'S CONTRACT. Neither is a
  -- bug in the simulation -- the sim is a pure function of (ruleset, seed, the
  -- set of atoms with their exec ticks) and both of these are about which atoms
  -- end up in that set. They are pinned here so they stay known, because no hash
  -- comparison anywhere in this harness can see them.
  --
  -- 1. LATE ARRIVAL. queueCommand refuses an atom whose exec tick has already
  --    passed. That decision reads the LOCAL clock, so two clients whose clocks
  --    are a tick apart -- which A.11.1 says is normal, T0 is set locally and the
  --    skew is one one-way latency -- can disagree about whether the same atom is
  --    in the set. This is exactly what A.12's bounded rollback exists to repair
  --    and it is M4 work; until then it is a real desync path.
  local intime, late = fresh(51), fresh(51)
  local cmd = { side = 1, seq = 1, tick = 30, kind = "S", target = 1, count = 3 }
  eq(intime:queueCommand(cmd), true, "the in-time client refused the atom")
  runTo(late, 31)                      -- this client is one tick further on
  local ok, err = late:queueCommand(cmd)
  eq(ok, false, "the late client accepted an atom whose exec tick had passed")
  eq(err, "late", "late refusal reason")
  runTo(intime, 40)
  runTo(late, 9)
  eq(intime.clock, late.clock, "the two clients are not on the same tick")
  ck(intime:stateHash() ~= late:stateHash(),
    "a refused-because-late atom left the two clients identical, which would mean "
    .. "the atom did nothing")
  eq(#intime.sides[1].lanes[1].units, 3, "the in-time client did not deploy")
  eq(#late.sides[1].lanes[1].units, 0, "the late client deployed anyway")

  -- 2. SEQ REUSE. A.12 dedups on (sender, seq) and first-wins. If a sender ever
  --    reuses a seq for a DIFFERENT atom, which client keeps which atom depends
  --    on arrival order, so the two clients diverge without either doing anything
  --    wrong. The rule this pins is: a sender must never reuse a seq.
  local a1, a2 = fresh(52), fresh(52)
  local first = { side = 1, seq = 1, tick = 30, kind = "S", target = 1, count = 1 }
  local clash = { side = 1, seq = 1, tick = 30, kind = "H", target = 2, count = 1 }
  a1:queueCommand(first); a1:queueCommand(clash)
  a2:queueCommand(clash); a2:queueCommand(first)
  ck(a1:logDigest() ~= a2:logDigest(),
    "seq reuse resolved the same way from both arrival orders")
  runTo(a1, 40); runTo(a2, 40)
  ck(a1:stateHash() ~= a2:stateHash(), "seq reuse did not actually diverge the state")
end

do
  -- The parser rejects malformed logs rather than half-reading them.
  local bad = {
    "seed 1\n",                                         -- no version
    "version 2\nseed 1\n",                              -- wrong version
    "version 1\nseed x\n",                              -- non-integer
    "version 1\ncmd 10 1 1 SS 1 1\n",                   -- two-character kind
    "version 1\ncmd 10 1 1 S 1\n",                      -- short command
    "version 1\ncmd 10 1 1 S 1 1 20\n",                 -- arrive after exec
    "version 1\nnonsense 4\n",                          -- unknown directive
  }
  for i = 1, #bad do
    local log = logfmt.parse(bad[i], "bad" .. i)
    ck(log == nil, "the parser accepted malformed log %d", i)
  end
  local good = logfmt.parse("version 1\nseed 7\nticks 100\n# comment\n\ncmd 10 1 1 S 1 2 3\n", "good")
  ck(good ~= nil, "the parser rejected a good log")
  if good then
    eq(good.seed, 7, "parsed seed")
    eq(good.ticks, 100, "parsed ticks")
    eq(#good.cmds, 1, "parsed command count")
    eq(good.cmds[1].count, 2, "parsed count")
    eq(good.cmds[1].arrive, 3, "parsed arrive")
  end
end

-- ===========================================================================
sec("9  determinism in miniature")
-- ===========================================================================

do
  -- A generated log, run four ways, exactly as the fuzzer does it -- so a broken
  -- runner or generator is caught here in a second rather than in the long run.
  local log = gen.make(20260812, { ticks = 1200 })
  ck(#log.cmds > 5, "the generator produced almost nothing (%d commands)", #log.cmds)
  local a = runner.run(log, { keepSim = true })
  local b = runner.run(log, {})
  local okAB, _, dAB = runner.compare(a, b)
  ck(okAB, "two runs of one log disagreed: %s", dAB)
  local perm = gen.permutation(#log.cmds, 5)
  local c = runner.run(log, { order = perm })
  local okAC, _, dAC = runner.compare(a, c)
  ck(okAC, "a reordered queue disagreed: %s", dAC)
  local d = runner.run(log, { order = gen.permutation(#log.cmds, 6), arrival = true })
  local okAD, _, dAD = runner.compare(a, d)
  ck(okAD, "mid-run arrival disagreed: %s", dAD)
  eq(a.result.sides[1].cmdsFizzled + a.result.sides[2].cmdsFizzled, 0,
    "the generator emitted an order that fizzled")
  invariantsOk(a.sim, "generated log")

  -- Sim:run(n) must be exactly n calls to Sim:tick(), and the tick budget must
  -- not change the answer: the UI will drive the sim in ragged chunks (a frame
  -- that ran long, a resume after a pause), and a sim that answers differently
  -- when advanced 1-at-a-time versus 300-at-a-time is a desync with a stopwatch
  -- on it.
  local chunked = fresh(79)
  local single = fresh(79)
  q(chunked, 1, 1, 20, "S", 1, 3); q(chunked, 2, 1, 25, "S", 1, 2)
  q(single, 1, 1, 20, "S", 1, 3); q(single, 2, 1, 25, "S", 1, 2)
  eq(chunked:run(300), 300, "Sim:run reported the wrong tick count")
  local sizes = { 7, 43, 1, 99, 150 }
  local total = 0
  for i = 1, #sizes do
    for _ = 1, sizes[i] do single:tick() end
    total = total + sizes[i]
  end
  eq(total, 300, "the chunk sizes do not add up")
  eq(chunked:stateHash(), single:stateHash(), "chunked ticking diverged from single ticking")

  -- Two sims built one after the other must not share anything.
  local s1 = fresh(77)
  runTo(s1, 500)
  local s2 = fresh(77)
  runTo(s2, 500)
  eq(s1:stateHash(), s2:stateHash(), "a second sim inherited state from the first")

  -- Hashing must not perturb the sim it hashes.
  local s3 = fresh(78)
  runTo(s3, 300)
  local h1 = s3:stateHash()
  s3:stateHash(); s3:logDigest(); runner.dump(s3)
  eq(s3:stateHash(), h1, "hashing the state changed it")
end

-- ===========================================================================
sec("10 the Lua 5.1 number model")
-- ===========================================================================

-- WoW runs Lua 5.1, where every number is a double and there is no integer
-- subtype; this harness runs on 5.5, where integer arithmetic is exact and
-- separate. The same code must produce the same bits on both, which is true only
-- while every intermediate stays inside 2^53. These checks re-run the two pieces
-- of arithmetic that carry the whole milestone -- the hash fold and the LCG step
-- -- in FLOAT arithmetic alongside the integer arithmetic and require the two to
-- agree, which is as close to running WoW's 5.1 as can be done from here.
do
  local TWO53 = 9007199254740992

  local MOD, MUL = Hash.MOD, Hash.MUL
  local r = Rand.new(20260812)
  local h, hf = Hash.new(), Hash.new() * 1.0
  local sameHash, maxFold = true, 0
  for _ = 1, 200000 do
    local v = Rand.next32(r)
    local fold = h * MUL + (v % MOD) + 1
    if fold > maxFold then maxFold = fold end
    h = Hash.int(h, v)
    hf = ((hf * 1.0) * MUL + (v % MOD) + 1) % MOD
    if hf ~= h then sameHash = false end
  end
  ck(sameHash, "Hash.int in double arithmetic diverged from integer arithmetic")
  ck(maxFold < TWO53, "the hash fold reached %s, at or past 2^53", tostring(maxFold))

  local A, CC, M32 = 1664525, 1013904223, 4294967296
  local si, sf = 12345, 12345 * 1.0
  local sameLcg, maxStep = true, 0
  for _ = 1, 200000 do
    local p = A * si + CC
    if p > maxStep then maxStep = p end
    si = p % M32
    sf = ((sf * 1.0) * A + CC) % M32
    if sf ~= si then sameLcg = false end
  end
  ck(sameLcg, "the LCG step in double arithmetic diverged from integer arithmetic")
  ck(maxStep < TWO53, "an LCG step reached %s, at or past 2^53", tostring(maxStep))
  -- The bound the comment in sim/Rand.lua claims: A * (2^32 - 1) + C.
  eq(A * (M32 - 1) + CC, 7149081450614098, "the LCG's worst-case product")
  ck(A * (M32 - 1) + CC < TWO53, "the LCG's worst case is at or past 2^53")

  -- Modulo of a negative must be floor-mod, identically in 5.1 and 5.3+. The
  -- hash folds negative values (aura points, the wheel numerator) through it.
  eq(-7 % 5, 3, "Lua's %% is not floor-mod here")
  eq(Hash.int(Hash.new(), -1), Hash.int(Hash.new(), MOD - 1), "negative folding")

  -- The largest quantities the sim itself multiplies, well inside the bound.
  local maxDmg = 200
  ck(maxDmg * C.STRUCTURE_DMG_PCT * 200 < TWO53, "structure damage arithmetic bound")
  ck(maxDmg * (C.WHEEL_EDGE_DEN * 1000 + C.WHEEL_K_PERMILLE * 225) < TWO53, "wheel arithmetic bound")
  ck(C.KEEP_HP * 100 < TWO53, "keep HP arithmetic bound")

  -- Nothing in a terminal state may be a non-integer, on either number model.
  local log = gen.make(31415, { ticks = 1500 })
  local t = runner.run(log, { keepSim = true })
  local d = runner.dump(t.sim)
  local clean = true
  for i = 1, #d do
    if string.find(d[i], "%.", 1, false) then clean = false end
  end
  ck(clean, "a fractional value reached the state dump")
end

-- ===========================================================================
sec("11 side symmetry (A.2)")
-- ===========================================================================

do
  -- Flip every command's side and the whole match must mirror. This is the one
  -- property that every hash comparison in the fuzzer would pass even if it were
  -- broken: a sim that quietly favours the host is perfectly deterministic.
  local bad = 0
  for i = 1, 12 do
    local log = gen.make(880000 + i * 13, { ticks = 3000 })
    local a = runner.run(log, {})
    local m = runner.run(runner.mirrorLog(log), {})
    local ok, det = runner.mirrorCompare(a, m)
    if not ok then
      bad = bad + 1
      print("    " .. det)
    end
  end
  eq(bad, 0, "matches that did not mirror")
end

print("")
if nFails == 0 then
  print(string.format("SELFTEST PASS: %d checks", nChecks))
  os.exit(0)
end
print(string.format("SELFTEST FAILED: %d of %d checks", nFails, nChecks))
os.exit(1)
