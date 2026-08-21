-- tools/smoke.lua -- quick sanity run against the numbers Part C states.
-- Not the determinism harness (that is tools/determinism.lua); this file just
-- checks the sim reproduces the doc's own arithmetic landmarks.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Sim = require("sim.Sim")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")
local floor = math.floor

local fails = 0
local function check(name, got, want)
  if got ~= want then
    fails = fails + 1
    print(string.format("FAIL  %-46s got %s want %s", name, tostring(got), tostring(want)))
  else
    print(string.format("ok    %-46s %s", name, tostring(got)))
  end
end

print("rulesHash = " .. Hash.dec(Rules.rulesHash) .. "  (" .. Rules.rulesHash36 .. ")")
print("Rand selftest = " .. tostring(Rand.selftest()))

-- 1. Levy schedule. Stipend 30 at tick 0, then 10 on every 35th tick.
-- sim.clock counts ticks EXECUTED, so running 36 ticks has executed tick 35.
local s = Sim.new(Rules, 1)
check("bank at tick 0", s:levy(1), 30)
s:run(36)
check("bank after 1 Levy tick", s:levy(1), 40)
s:run(35)
check("bank at tick 70 (Trap Pit affordable)", s:levy(1), 50)
s:run(245)                                  -- through tick 315
check("bank at tick 315 (Levy Post affordable)", s:levy(1), 120)

-- 2. Total base Levy over a full match: 30 + 171 * 10 = 1740.
local s2 = Sim.new(Rules, 1)
s2:run(6000)
check("earned over a full match", s2.sides[1].earned, 1740)
check("match ended", s2:isOver(), true)
local r = s2:result()
check("empty match is a draw", r.winner, 0)
check("empty match ends on the clock", r.reason, "clock")
check("empty match falls to the draw tier", r.tier, 5)
check("bank capped at 200", s2:levy(1), 200)
check("waste accrues once capped", s2.sides[1].wasted, 1540)

-- 3. Marching. A Spear crosses 2000 units at 10 per tick, stopping at its own
--    range from the enemy keep: 1940 after 194 ticks.
local s3 = Sim.new(Rules, 1)
s3:queueCommand({ side = 1, seq = 1, tick = 20, kind = "S", target = 1, count = 1 })
s3:run(20 + 194)
check("Spear reaches the enemy keep", s3.sides[1].lanes[1].units[1].pos, 1940)
check("Spear cost 10 Levy", s3.sides[1].spent, 10)

-- 4. Keep chewing. One Spear does 16 damage, halved against structures, every
--    5th tick: 8 per resolve tick.
local s4 = Sim.new(Rules, 1)
s4:queueCommand({ side = 1, seq = 1, tick = 20, kind = "S", target = 1, count = 1 })
s4:run(20 + 195)
local hpBefore = s4:keepHp(2)
s4:run(5)
check("Spear deals 8 to a keep per resolve tick", hpBefore - s4:keepHp(2), 8)
check("tier 1 counter tracks it", s4.sides[1].keepDamageDealt, 48000 - s4:keepHp(2))

-- 5. Supply cap: 200 Levy per lane at BASE cost = 20 Spears, and the 21st is
--    refused even though the bank could pay for it.
local s5 = Sim.new(Rules, 1)
-- The bank must NOT be the binding constraint, or this measures affordability
-- instead of the supply cap. (It did: with the default bank it stopped at 4
-- Spears, and the old `<= 20` bound passed anyway.)
s5.sides[1].bank = 100000
for i = 1, 30 do
  s5:queueCommand({ side = 1, seq = i, tick = 20 + i, kind = "S", target = 1, count = 9 })
end
s5:run(3000)
-- Exact equalities, not bounds: 200 Levy of supply at a base cost of 10 is
-- exactly 20 Spears, and a bound would pass at 3 Spears too.
check("lane 1 holds exactly 20 Spears", s5:unitCount(1, 1), 20)
check("lane 1 supply exactly at cap", s5.sides[1].lanes[1].supply, 200)

-- 6. Buildings: legality, construction, and the slot cap.
local s6 = Sim.new(Rules, 1)
s6:queueCommand({ side = 1, seq = 1, tick = 70, kind = "a", target = 1, count = 1 })  -- Trap Pit, front
s6:queueCommand({ side = 1, seq = 2, tick = 71, kind = "a", target = 2, count = 1 })  -- into a back slot
-- Assert the TICK, not just `done == 1`. The old assertion ran 140 ticks and
-- checked the flag, which is true at 125 and at 130 alike -- so it could not fail
-- either way, and did not notice construction finishing a whole resolve tick
-- early. C.4 says 60 ticks, the order executes on tick 70, so it completes on
-- tick 130 and not before.
local pitDone
for _ = 1, 140 do
  s6:tick()
  if s6.sides[1].slots[1] and s6.sides[1].slots[1].done == 1 then
    pitDone = s6.clock - 1
    break
  end
end
check("Trap Pit placed in a front slot", s6.sides[1].slots[1] ~= false, true)
check("Trap Pit refused by a back slot", s6.sides[1].slots[2], false)
check("that refusal is a fizzle", s6.sides[1].cmdsFizzled, 1)
check("Trap Pit complete on tick 130 (60 ticks after placement)", pitDone, 130)

-- 6b. C.5's opening landmarks, pinned so the doc and the sim cannot drift apart.
-- Income is the 30 stipend at tick 0 then 10 on every 35th tick, so
-- bank(t) = 30 + 10 * floor(t / 35) and the Horse chain lands at:
--   1 Horse (30) tick   0 =  0.0 s
--   2 Horses (60) tick 105 = 10.5 s
--   3 Horses (90) tick 210 = 21.0 s
-- Part C.5 still prints "3-Horse opening affordable t = 24.5 s", which is stale
-- v1 arithmetic computed against a 20-Levy stipend. The sim is right and the DOC
-- is wrong; dev/docs/IDLE_BATTLE_DECISIONS.md C.5 needs the correction, and this
-- test is what makes the claim checkable rather than asserted.
local function firstTickWithBank(want)
  local sm = Sim.new(Rules, 1)
  if sm:levy(1) >= want then return 0 end
  for _ = 1, 6000 do
    sm:tick()
    if sm:levy(1) >= want then return sm.clock - 1 end
  end
  return -1
end
check("1 Horse (30 Levy) affordable at tick 0 (0.0 s)", firstTickWithBank(30), 0)
check("2 Horses (60 Levy) affordable at tick 105 (10.5 s)", firstTickWithBank(60), 105)
check("3 Horses (90 Levy) affordable at tick 210 (21.0 s, doc says 24.5)",
  firstTickWithBank(90), 210)
check("Trap Pit (50 Levy) affordable at tick 70", firstTickWithBank(50), 70)
check("Levy Post (120 Levy) affordable at tick 315", firstTickWithBank(120), 315)

-- 7. C.5's two keep-chewing figures, which pin the resolve cadence and the
--    half-damage-to-structures rule simultaneously.
--    20 Spears: 20 * floor(16 * 50 / 100) = 160 per resolve tick = 320 per second
--    -> 48000 / 320 = 150 s. 6 Horses: 6 * 22 = 132 -> 181.8 s.
local function chewTicks(kind, n)
  local sm = Sim.new(Rules, 1)
  sm.sides[1].bank = 100000
  for i = 1, n do
    sm:queueCommand({ side = 1, seq = i, tick = 20, kind = kind, target = 1, count = 1 })
  end
  local t0 = nil
  for i = 1, 6000 do
    sm:tick()
    if t0 == nil and sm:keepHp(2) < 48000 then t0 = sm.clock end
    -- resolve ticks of chewing, inclusive of the first and the last
    if sm:isOver() then return floor((sm.clock - t0) / 5) + 1 end
  end
  return -1
end
check("20 Spears raze a keep in 300 resolve ticks", chewTicks("S", 20), 300)
check("6 Horses raze a keep in 364 resolve ticks", chewTicks("H", 6), 364)

-- 8. The counter triangle at equal Levy, informational (C.3 states the prey is
--    wiped in every direction and the winner retains 39 to 78 percent).
local function duel(k1, n1, k2, n2)
  local sm = Sim.new(Rules, 1)
  sm.sides[1].bank = 100000
  sm.sides[2].bank = 100000
  for i = 1, n1 do
    sm:queueCommand({ side = 1, seq = i, tick = 20, kind = k1, target = 1, count = 1 })
  end
  for i = 1, n2 do
    sm:queueCommand({ side = 2, seq = i, tick = 20, kind = k2, target = 1, count = 1 })
  end
  local started = false
  for _ = 1, 4000 do
    sm:tick()
    local a, b = sm:unitCount(1, 1), sm:unitCount(2, 1)
    if a > 0 and b > 0 then started = true end
    if started and (a == 0 or b == 0) then break end
  end
  return sm:unitCount(1, 1), sm:unitCount(2, 1)
end
-- These ASSERT rather than print. C.3 states the prey is wiped in every
-- direction and the winner retains 39 to 78 percent of its stack, so both halves
-- are checkable: the loser must reach exactly zero, and the winner's survivors
-- must land inside the stated band. A block that printed six numbers and checked
-- none of them could not fail, which made it decoration.
local function tri(k1, n1, k2, n2, levy)
  local a, b = duel(k1, n1, k2, n2)
  print(string.format("      triangle %3d Levy: %d %s vs %d %s -> %d left vs %d left",
    levy, n1, k1, n2, k2, a, b))
  check(string.format("%d %s beats %d %s: prey wiped", n1, k1, n2, k2), b, 0)
  local lo = floor(n1 * 39 / 100)
  local hi = floor(n1 * 78 / 100) + 1   -- +1 so the band is inclusive of rounding
  check(string.format("%d %s survivors in the C.3 band [%d, %d]", n1, k1, lo, hi),
    a >= lo and a <= hi, true)
end
tri("S", 6, "H", 2, 60);  tri("H", 2, "B", 3, 60);  tri("B", 3, "S", 6, 60)
tri("S", 12, "H", 4, 120); tri("H", 4, "B", 6, 120); tri("B", 6, "S", 12, 120)

-- 9. Determinism: two sims, same seed, same log, same hash at every checkpoint.
local function scripted(seed)
  local sm = Sim.new(Rules, seed)
  local r = Rand.new(seed)
  local seq = { 0, 0 }
  for t = 20, 5900, 37 do
    local side = Rand.range(r, 1, 2)
    seq[side] = seq[side] + 1
    local roll = Rand.range(r, 1, 10)
    if roll <= 7 then
      local kinds = { "S", "H", "B" }
      sm:queueCommand({ side = side, seq = seq[side], tick = t,
                        kind = kinds[Rand.range(r, 1, 3)],
                        target = Rand.range(r, 1, 3), count = Rand.range(r, 1, 9) })
    else
      local letters = { "a", "b", "c", "d", "e", "i" }
      sm:queueCommand({ side = side, seq = seq[side], tick = t,
                        kind = letters[Rand.range(r, 1, 6)],
                        target = Rand.range(r, 1, 6), count = 1 })
    end
  end
  return sm
end

local a, b = scripted(4242), scripted(4242)
local same = true
for i = 1, 6000 do
  a:tick(); b:tick()
  if i % 500 == 0 and a:stateHash() ~= b:stateHash() then same = false; break end
end
check("replayed match hashes identically", same, true)
check("log digests match", a:logDigest(), b:logDigest())
local ra = a:result()
print(string.format("      scripted match: tick %d winner %d reason %s tier %d hash %s",
  ra.tick, ra.winner, ra.reason, ra.tier, Hash.dec(a:stateHash())))
print(string.format("      side 1: keepHp %d dealt %d razed %d pen %d | side 2: keepHp %d dealt %d razed %d pen %d",
  ra.sides[1].keepHp, ra.sides[1].keepDamageDealt, ra.sides[1].slotsDestroyed, ra.sides[1].penetration,
  ra.sides[2].keepHp, ra.sides[2].keepDamageDealt, ra.sides[2].slotsDestroyed, ra.sides[2].penetration))

if fails > 0 then
  print("FAILURES: " .. fails)
  os.exit(1)
end
print("all smoke checks passed")
