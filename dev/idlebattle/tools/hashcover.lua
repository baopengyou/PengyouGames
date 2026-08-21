-- tools/hashcover.lua -- proves the state hash covers what M1 says it must.
--
-- The milestone is explicit: "The hash must cover Levy, bank, every accumulator
-- and every tiebreak counter, not just the board." A hash that silently omits a
-- field is worse than no hash, because it reports agreement while the two
-- clients disagree -- which is exactly the failure v1 shipped with (it could not
-- detect a disagreement about who won).
--
-- Method: run a real match to a mid-game state, take the hash, perturb ONE field
-- by one, take the hash again, and require it to change. Then restore.
--
-- Also checks that the hash is identical when the accumulator is forced through
-- Lua 5.1's number model (all doubles) rather than 5.3-plus integers, which is
-- the one arithmetic difference between the interpreter this runs on and the one
-- the addon will run on.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Sim = require("sim.Sim")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")

local fails = 0
local function fail(msg)
  fails = fails + 1
  print("FAIL  " .. msg)
end

-- ---------------------------------------------------------------------------
-- 1. number-model equivalence for the hash primitives
-- ---------------------------------------------------------------------------
do
  -- Force the accumulator to a float at every step, which is what Lua 5.1 does
  -- with every number. The results must be bit-identical.
  local h1 = Hash.new()
  local h2 = Hash.new() + 0.0
  local r = Rand.new(99)
  for i = 1, 20000 do
    local v = Rand.range(r, -1000000, 1000000)
    h1 = Hash.int(h1, v)
    h2 = Hash.int(h2 + 0.0, v + 0.0) + 0.0
  end
  if h1 ~= h2 then
    fail(string.format("hash differs under the float number model: %s vs %s",
      Hash.dec(h1), Hash.dec(h2)))
  else
    print("ok    hash identical under integer and float number models  " .. Hash.dec(h1))
  end
  if Hash.dec(h1) ~= Hash.dec(h2) or Hash.base36(h1, 6) ~= Hash.base36(h2, 6) then
    fail("hash rendering differs under the float number model")
  end
end

-- ---------------------------------------------------------------------------
-- 2. field coverage
-- ---------------------------------------------------------------------------

-- Drive a match into a rich mid-game state: both sides with units in every lane,
-- buildings up, damage exchanged, ladder counters moving.
local function midgame()
  local sm = Sim.new(Rules, 555, { 1, 2, 3, 4, 5 }, { 6, 7, 8, 9, 10 })
  local seq = { 0, 0 }
  local function q(side, tick, kind, target, count)
    seq[side] = seq[side] + 1
    sm:queueCommand({ side = side, seq = seq[side], tick = tick,
                      kind = kind, target = target, count = count })
  end
  q(1, 70, "a", 1, 1)      -- Trap Pit, lane 1 front
  q(2, 70, "a", 3, 1)      -- Trap Pit, lane 2 front
  q(1, 320, "i", 2, 1)     -- Levy Post, lane 1 back
  q(2, 320, "d", 4, 1)     -- Granary, lane 2 back
  -- Symmetric deployments, so neither keep falls and the match is still live
  -- when the probes run. The probes need a NON-terminal state, otherwise the
  -- terminal latch makes the `over` flag unperturbable.
  for t = 400, 1800, 100 do
    q(1, t, "S", 1 + (t % 3), 3)
    q(2, t, "S", 1 + (t % 3), 3)
    q(1, t + 40, "B", 1 + ((t + 1) % 3), 1)
    q(2, t + 40, "B", 1 + ((t + 1) % 3), 1)
  end
  sm:run(2200)
  return sm
end

local base = midgame()
if base:isOver() then
  fail("hashcover fixture ended early; probes need a live match")
  os.exit(1)
end
local h0 = base:stateHash()
print(string.format("      midgame at tick %d  hash %s  bank %d %d  keeps %d %d",
  base.clock, Hash.dec(h0), base:levy(1), base:levy(2), base:keepHp(1), base:keepHp(2)))

local function probe(label, mutate, restore)
  mutate()
  local h = base:stateHash()
  restore()
  if h == h0 then
    fail("state hash does NOT cover " .. label)
    return
  end
  local back = base:stateHash()
  if back ~= h0 then
    fail("restore failed while probing " .. label)
    return
  end
  print("ok    covered: " .. label)
end

local function probeNum(label, tbl, key)
  local old = tbl[key]
  probe(label, function() tbl[key] = old + 1 end, function() tbl[key] = old end)
end

-- top level
probeNum("clock", base, "clock")
probeNum("winner", base, "winner")
probeNum("tier", base, "tier")
probeNum("reasonCode", base, "reasonCode")
probeNum("nextEntityId", base, "nextEntityId")
probeNum("seed", base, "seed")
probeNum("rng state", base.rng, "s")
do
  local was = base.over
  probe("over flag", function() base.over = not was end, function() base.over = was end)
end

-- per side
for s = 1, 2 do
  local sd = base.sides[s]
  local tag = " (side " .. s .. ")"
  probeNum("bank" .. tag, sd, "bank")
  probeNum("earned" .. tag, sd, "earned")
  probeNum("wasted" .. tag, sd, "wasted")
  probeNum("spent" .. tag, sd, "spent")
  probeNum("keep HP" .. tag, sd, "keepHp")
  probeNum("keepDamageDealt, ladder T1" .. tag, sd, "keepDamageDealt")
  probeNum("slotsDestroyed, ladder T2" .. tag, sd, "slotsDestroyed")
  probeNum("unitsDeployed" .. tag, sd, "unitsDeployed")
  probeNum("unitsLost" .. tag, sd, "unitsLost")
  probeNum("unitsKilled" .. tag, sd, "unitsKilled")
  probeNum("bldLost" .. tag, sd, "bldLost")
  probeNum("cmdsExecuted" .. tag, sd, "cmdsExecuted")
  probeNum("cmdsFizzled" .. tag, sd, "cmdsFizzled")
  probeNum("wheel edge numerator" .. tag, sd, "wheelNum")
  probeNum("loadout slot 1" .. tag, sd.loadout, 1)
  probeNum("loadout slot 5" .. tag, sd.loadout, 5)
  for ch = 1, #Rules.CHANNELS do
    probeNum("channel " .. Rules.CHANNELS[ch] .. tag, sd.chan, ch)
  end
  for lane = 1, Rules.C.LANES do
    local ln = sd.lanes[lane]
    local lt = tag .. " lane " .. lane
    probeNum("supply" .. lt, ln, "supply")
    probeNum("depth, ladder T3" .. lt, ln, "depth")
    probeNum("depth hold band 1" .. lt, ln, "hold1")
    probeNum("depth hold band 2" .. lt, ln, "hold2")
    probeNum("depth hold band 3" .. lt, ln, "hold3")
    probeNum("muster charges (M3)" .. lt, ln, "muster")
    probeNum("bypass flag (M3)" .. lt, ln, "bypass")
    probeNum("counterwall accumulator (M3)" .. lt, ln, "cwAcc")
    local u = ln.units[1]
    if u then
      probeNum("unit id" .. lt, u, "id")
      probeNum("unit type" .. lt, u, "t")
      probeNum("unit pos" .. lt, u, "pos")
      probeNum("unit hp" .. lt, u, "hp")
      probeNum("unit maxHp" .. lt, u, "maxHp")
      probeNum("unit paid cost" .. lt, u, "cost")
      probeNum("unit vanguard flag (M3)" .. lt, u, "vg")
      probe("unit count" .. lt,
        function() ln.units[#ln.units + 1] = u end,
        function() ln.units[#ln.units] = nil end)
    end
  end
  for slot = 1, Rules.C.SLOTS do
    local b = sd.slots[slot]
    local st = tag .. " slot " .. slot
    probeNum("rubble mark (M3)" .. st, sd.rubble, slot)
    if b then
      probeNum("building id" .. st, b, "id")
      probeNum("building type" .. st, b, "b")
      probeNum("building hp" .. st, b, "hp")
      probeNum("building maxHp" .. st, b, "maxHp")
      probeNum("building paid cost" .. st, b, "cost")
      probeNum("build progress" .. st, b, "prog")
      probeNum("build start tick" .. st, b, "startTick")
      probeNum("build time needed" .. st, b, "need")
      probeNum("build complete flag" .. st, b, "done")
      probeNum("trap spent flag" .. st, b, "spent")
    else
      probe("empty slot occupancy" .. st,
        function() sd.slots[slot] = { id = 9, b = 1, hp = 1, maxHp = 1, cost = 1,
                                      prog = 0, startTick = 0, need = 1,
                                      done = 0, spent = 0 } end,
        function() sd.slots[slot] = false end)
    end
  end
  -- Card-gated unlocks are OWNED state (M3 writes them, execBuild reads them),
  -- so the hash has to see them.
  for b = 1, #Rules.BUILDINGS do
    probeNum("building unlock " .. Rules.BUILDINGS[b].key .. tag, sd.unlocks, b)
  end
  -- the M3 modifier runtime block, which is empty in M1 but must be walked
  probe("modifier runtime block" .. tag,
    function() sd.modsOrder[1] = "goldenAge"; sd.mods.goldenAge = 1 end,
    function() sd.modsOrder[1] = nil; sd.mods.goldenAge = nil end)
end

-- rulesHash participates too: a balance patch must change the state hash.
do
  local old = Rules.rulesHash
  probe("rulesHash", function() Rules.rulesHash = old + 1 end,
                     function() Rules.rulesHash = old end)
end

-- ---------------------------------------------------------------------------
-- 3. M3 card runtime state. A second fixture whose loadouts own every card
-- that keeps per-side runtime state, so each mods key exists and each must
-- move the hash -- a latch or cooldown outside the hash would let two clients
-- disagree about a pending payout and agree about everything visible.
-- ---------------------------------------------------------------------------

local carded = Sim.new(Rules, 777,
  { 18, 19, 27, 31, 39 },   -- Golden Age, Investment, War Drums, Scorched Earth, Ley Line
  { 29, 5, 11, 32, 12 })    -- Vanguard, Endless Ranks, Counterwall, Raiding Party, Deep Foundations
carded.sides[1].bank = 400
carded.sides[1].earned = carded.sides[1].earned + 370
carded:queueCommand({ side = 1, seq = 1, tick = 25, kind = "I", target = 1, count = 2 })
carded:queueCommand({ side = 1, seq = 2, tick = 30, kind = "S", target = 1, count = 3 })
carded:queueCommand({ side = 2, seq = 1, tick = 30, kind = "S", target = 1, count = 3 })
carded:run(400)
if carded:isOver() then
  fail("M3 hashcover fixture ended early; probes need a live match")
  os.exit(1)
end

do
  local h1 = carded:stateHash()
  local function cprobe(label, mutate, restore)
    mutate()
    local h = carded:stateHash()
    restore()
    if h == h1 then
      fail("state hash does NOT cover " .. label)
      return
    end
    if carded:stateHash() ~= h1 then
      fail("restore failed while probing " .. label)
      return
    end
    print("ok    covered: " .. label)
  end
  local function modProbe(side, key)
    local sd = carded.sides[side]
    if sd.mods[key] == nil then
      fail("M3 fixture never created mods." .. key .. " on side " .. side)
      return
    end
    local old = sd.mods[key]
    cprobe("card runtime mods." .. key .. " (side " .. side .. ")",
      function() sd.mods[key] = old + 1 end,
      function() sd.mods[key] = old end)
  end
  modProbe(1, "gaLatch")
  modProbe(1, "invAmt")
  modProbe(1, "invDue")
  modProbe(1, "wdUntil")
  modProbe(1, "seCd")
  modProbe(1, "llCd")
  modProbe(2, "vg1")
  modProbe(2, "vg2")
  modProbe(2, "vg3")
  -- The wheel edge is non-zero here (Boom-heavy against a Fortress-heavy
  -- loadout) and hashed per side; the M1 probe above only ever saw 0.
  local w = carded.sides[1].wheelNum
  if w == 0 then fail("M3 fixture's wheel edge is unexpectedly zero") end
  cprobe("non-zero wheel edge",
    function() carded.sides[1].wheelNum = w + 1 end,
    function() carded.sides[1].wheelNum = w end)
  -- Static card channel points are folded into sd.chan, which the per-channel
  -- probes above cover on the M1 fixture; prove the carded fixture actually
  -- HAS non-zero card state so this section cannot silently probe a blank.
  if carded.sides[1].mods.invDue == 0 then
    fail("M3 fixture's Investment never became outstanding")
  end
end

if fails > 0 then
  print("FAILURES: " .. fails)
  os.exit(1)
end
-- Deliberately NOT the word "complete": this file proves that every field it
-- PROBES moves the hash, which is not the same as proving nothing was left out.
-- The three derived caches (cacheLevyFlat, cacheBankCap, lanes[n].aura) are
-- excluded on purpose and are covered instead by harness/runner.lua's invariants,
-- and the ruleset side of the question is tools/rulescover.lua's job.
print("hash coverage: every probed field moves the state hash "
  .. "(derived caches excluded by design -- see harness/runner.lua invariants)")
