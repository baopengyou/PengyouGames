-- tools/fogtest.lua -- every rule in ../docs/IDLE_BATTLE_FOG.md, proved one at
-- a time against fog/Fog.lua.
--
-- WHY EACH RULE GETS ITS OWN TEST RATHER THAN ONE END-TO-END MATCH. A fog model
-- is a pile of independent predicates that interact only at the edges, and an
-- end-to-end assertion over a real match passes for the wrong reason all the
-- time: the front-slot shield "works" in any match where nobody reaches
-- section 7, and memory "freezes" in any match where nothing is ever built.
-- Every test below therefore hand-builds the exact board its rule is about,
-- names the doc section it comes from, and asserts the rule and its NEGATION --
-- visible here, invisible one section away -- because a predicate that returns
-- false everywhere passes half of these otherwise.
--
-- THE BOARDS ARE BUILT THROUGH THE SIM, not by hand-writing state: units are
-- deployed with real commands and buildings with real build orders, then walked
-- forward with sim:tick(). A test that fabricates a unit table proves the fog
-- model agrees with the test's idea of sim state rather than with the sim's.
-- The two exceptions are stated where they occur: a unit's `pos` is written
-- directly when the test needs it at a precise section boundary (marching it
-- there would take hundreds of ticks and would engage whatever is in front of
-- it), and a keep's HP likewise.
--
-- THIS FILE IS A TOOL. It may use pairs, io and os freely; the module it tests
-- may not, and tools/greps.sh + tools/comptest.sh over fog/ are what enforce
-- that.
--
--   usage: lua tools/fogtest.lua
--   exit:  0 = every rule holds, 1 = at least one failed

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local SimM = require("sim.Sim")
local Hash = require("sim.Hash")
local Fog = require("fog.Fog")
local Policy = require("policy.Policy")

local C = Rules.C
local floor = math.floor
local format = string.format

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------

local failures = 0
local checks = 0
local group = ""

local function G(name) group = name; print("== " .. name) end

local function ok(cond, what)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print(format("  FAIL  [%s] %s", group, what))
  end
end

local function eq(a, b, what)
  checks = checks + 1
  if a ~= b then
    failures = failures + 1
    print(format("  FAIL  [%s] %s: got %s, want %s", group, what,
      tostring(a), tostring(b)))
  end
end

-- ---------------------------------------------------------------------------
-- board construction
-- ---------------------------------------------------------------------------

-- PINNING, and it is the one piece of harness machinery worth explaining.
--
-- Every helper below that touches the sim ADVANCES it, and a sim that advances
-- MOVES units -- which is the whole point of the sim and a menace to a test that
-- wants two units 500 units apart in specific sections. Placing a second unit
-- therefore marches the first one, and a build order marches everything for the
-- length of the build. So each placed unit records where the test wants it, and
-- repin() puts them all back. Call it after any helper and before any
-- assertion; it is idempotent and cheap.
local pinned = {}

local function newSim(seed)
  pinned = {}
  return SimM.new(Rules, seed or 1)
end

local function repin()
  for i = 1, #pinned do pinned[i].u.pos = pinned[i].pos end
end

-- Give a side enough Levy to buy anything a test needs. Banked directly: the
-- economy is not what any of these tests is about, and waiting 40 s of sim for
-- a Palisade would make every case below a hundred times slower for nothing.
local function fund(sim, side, amt)
  sim.sides[side].bank = amt
end

local seq = 0
local function order(sim, side, kind, target, count, atTick)
  seq = seq + 1
  local t = atTick or (sim.clock + C.ORDER_DELAY)
  return sim:queueCommand({ side = side, seq = seq, tick = t,
    kind = kind, target = target, count = count or 1 })
end

local function run(sim, n)
  for _ = 1, n do
    if not sim:tick() then return end
  end
end

-- Put a living unit of `side` in `lane` at own-frame `pos`.
--
-- Deployed by a real command so the sim allocates it, charges for it and owns
-- it; `pos` is then written, which is the one thing a test cannot do by
-- marching (a unit walked toward the enemy stops at range of the first thing it
-- meets, which is exactly the interaction several of these tests exist to hold
-- constant). Nothing downstream of fog reads anything else about it.
local function place(sim, side, lane, pos, kind)
  fund(sim, side, 1000)
  order(sim, side, kind or "S", lane, 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + 1)
  local us = sim.sides[side].lanes[lane].units
  local u = us[#us]
  u.pos = pos
  pinned[#pinned + 1] = { u = u, pos = pos }
  return u
end

-- Deploy a unit and let it MARCH, pinning nothing.
--
-- place() above writes a position and holds it there, which is right for a test
-- about a section boundary and WRONG for every test in section 15: those are
-- about where the SIM stops a unit -- at range of the thing it is fighting --
-- and a test that writes that position down has assumed the answer it is
-- checking. Run the sim afterwards and read u.pos.
local function deploy(sim, side, lane, kind)
  fund(sim, side, 1000)
  order(sim, side, kind or "S", lane, 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + 1)
  local us = sim.sides[side].lanes[lane].units
  return us[#us]
end

-- Build `key` into `slot` for `side` and run it to completion.
local function build(sim, side, key, slot)
  local bi = nil
  for i = 1, #Rules.BUILDINGS do
    if Rules.BUILDINGS[i].key == key then bi = i end
  end
  if bi == nil then error("fogtest: no such building " .. key) end
  fund(sim, side, 1000)
  order(sim, side, Rules.BUILDINGS[bi].letter, slot, 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + Rules.BUILDINGS[bi].build + 10)
  local b = sim.sides[side].slots[slot]
  if not b then error("fogtest: build of " .. key .. " into slot " .. slot .. " fizzled") end
  return b
end

local function vis(sim, side, lane)
  return Fog.visibleSections(sim, side, lane, {})
end

local FS = Fog.frontSlot
local BS = Fog.backSlot

-- ===========================================================================
-- 1. SECTION ARITHMETIC (doc section 1)
-- ===========================================================================

G("1. the section table is the doc's, derived from the ruleset")

eq(Fog.SECTIONS, 8, "8 sections per lane")
eq(Fog.SECTION_LEN, 250, "250 units per section")
eq(Fog.SECTIONS * Fog.SECTION_LEN, C.LANE_LEN, "the sections tile the lane exactly")
eq(Fog.OWN_SECTIONS, 4, "4 always-visible sections")

-- The doc's table, cell by cell, in the OBSERVER's numbering.
eq(Fog.sectionOfOwn(C.POS_OWN_KEEP), 1, "1 holds your keep (0)")
eq(Fog.sectionOfOwn(C.POS_BACK_SLOT), 2, "2 holds your back slot (300)")
eq(Fog.sectionOfOwn(C.POS_FRONT_SLOT), 3, "3 holds your front slot (700)")
eq(Fog.sectionOfOwn(999), 4, "4 ends at the midline (999)")
eq(Fog.sectionOfOwn(C.POS_MIDLINE), 5, "5 starts at the midline (1000)")
eq(Fog.sectionOfEnemy(C.POS_FRONT_SLOT), 6, "6 holds their front slot (1300)")
eq(Fog.sectionOfEnemy(C.POS_BACK_SLOT), 7, "7 holds their back slot (1700)")
eq(Fog.sectionOfEnemy(C.POS_OWN_KEEP), 8, "8 holds their keep (2000)")

-- Every boundary, both directions, so an off-by-one in the floor cannot hide.
for s = 1, Fog.SECTIONS do
  local lo = (s - 1) * Fog.SECTION_LEN
  local hi = lo + Fog.SECTION_LEN - 1
  eq(Fog.sectionOfOwn(lo), s, format("section %d starts at %d", s, lo))
  eq(Fog.sectionOfOwn(hi), s, format("section %d ends at %d", s, hi))
end
eq(Fog.sectionOfOwn(C.LANE_LEN), Fog.SECTIONS, "the far end clamps into the last section")

-- The frame conversion is an involution: what I call section s, they call
-- SECTIONS + 1 - s. If it were not, the model would not be side-agnostic.
for p = 0, C.LANE_LEN, 37 do
  eq(Fog.sectionOfEnemy(p), Fog.SECTIONS + 1 - Fog.sectionOfOwn(p),
    format("frames mirror at pos %d", p))
end

-- ===========================================================================
-- 2. DEFAULT SIGHT STOPS AT THE MIDLINE (doc section 2)
-- ===========================================================================

G("2. default sight is sections 1-4 and stops dead at the midline")

do
  local sim = newSim(2)
  for lane = 1, C.LANES do
    local v = vis(sim, 1, lane)
    for s = 1, 4 do eq(v[s], 1, format("lane %d section %d visible by default", lane, s)) end
    for s = 5, 8 do eq(v[s], 0, format("lane %d section %d DARK by default", lane, s)) end
  end
end

do
  -- An enemy marching at me. Invisible at 999 (their frame), which is my 1001;
  -- visible one unit later, at my 1000... which is my section 5, still dark.
  -- The first position I see them at is where they enter MY section 4.
  local sim = newSim(3)
  local u = place(sim, 2, 1, 0)

  local firstSeen = nil
  for p = 0, C.LANE_LEN do
    u.pos = p
    if Fog.seesEnemyUnit(sim, 1, u) then firstSeen = p; break end
  end
  eq(firstSeen, C.POS_MIDLINE + 1,
    "an approaching enemy is first seen one unit past the midline")
  eq(firstSeen, Fog.DEFAULT_SIGHT, "...which is what DEFAULT_SIGHT names")

  -- And the negation, walked the whole way in: invisible everywhere below.
  local seenBelow = 0
  for p = 0, C.POS_MIDLINE do
    u.pos = p
    if Fog.seesEnemyUnit(sim, 1, u) then seenBelow = seenBelow + 1 end
  end
  eq(seenBelow, 0, "invisible at every one of the 1001 positions up to the midline")

  -- Once inside my half it is exact at every position, not just at the edge.
  local seenAbove = 0
  for p = C.POS_MIDLINE + 1, C.LANE_LEN do
    u.pos = p
    if Fog.seesEnemyUnit(sim, 1, u) then seenAbove = seenAbove + 1 end
  end
  eq(seenAbove, C.LANE_LEN - C.POS_MIDLINE, "visible at every position inside my half")
end

do
  -- Vision is PER LANE. A unit of mine deep in lane 1 tells me nothing at all
  -- about lane 2, which the doc states in section 1 and which is the easiest
  -- thing for an implementation to get wrong by hoisting a loop.
  local sim = newSim(4)
  place(sim, 1, 1, 1400)
  eq(vis(sim, 1, 1)[6], 1, "my unit in lane 1 lights lane 1 section 6")
  eq(vis(sim, 1, 2)[6], 0, "...and lights nothing in lane 2")
  eq(vis(sim, 1, 3)[6], 0, "...nor in lane 3")
end

-- ===========================================================================
-- 3. A UNIT LIGHTS ONLY THE SECTION IT OCCUPIES (doc section 3)
-- ===========================================================================

G("3. one of your units lights its own section and nothing else")

do
  local sim = newSim(5)
  local u = place(sim, 1, 1, 0)
  -- The doc's own example: "A unit at position 1,400 reveals section 6 and
  -- nothing else."
  u.pos = 1400
  local v = vis(sim, 1, 1)
  eq(v[6], 1, "a unit at 1400 lights section 6")
  eq(v[5], 0, "...not the section before it")
  eq(v[7], 0, "...not the section after it")
  eq(v[8], 0, "...and not their keep")

  -- Walk it the whole length of the lane. At every position, EXACTLY the four
  -- home sections plus the one it stands in are lit -- never more.
  for p = 0, C.LANE_LEN do
    u.pos = p
    local vv = vis(sim, 1, 1)
    local want = Fog.sectionOfOwn(p)
    local lit = 0
    local wrong = 0
    for s = 1, Fog.SECTIONS do
      if vv[s] == 1 then
        lit = lit + 1
        if s > Fog.OWN_SECTIONS and s ~= want then wrong = wrong + 1 end
      end
    end
    if wrong ~= 0 then ok(false, format("pos %d lit a section it is not in", p)) end
    local expect = (want > Fog.OWN_SECTIONS) and (Fog.OWN_SECTIONS + 1) or Fog.OWN_SECTIONS
    if lit ~= expect then
      ok(false, format("pos %d lit %d sections, want %d", p, lit, expect))
    end
  end
  ok(true, "a unit lights exactly one enemy section, at every position in the lane")
end

do
  -- Two units light two sections; a dead unit lights none. "For exactly as long
  -- as it lives" (doc section 3).
  local sim = newSim(6)
  local a = place(sim, 1, 2, 1300)
  local b = place(sim, 1, 2, 1800)
  repin()
  local v = vis(sim, 1, 2)
  eq(v[6], 1, "two units light both their sections (6)")
  eq(v[8], 1, "two units light both their sections (8)")
  eq(v[7], 0, "...and not the gap between them")

  -- Remove them the way the sim does and the light goes out.
  local us = sim.sides[1].lanes[2].units
  for i = #us, 1, -1 do table.remove(us, i) end
  local v2 = vis(sim, 1, 2)
  eq(v2[6], 0, "sight dies with the unit (6)")
  eq(v2[8], 0, "sight dies with the unit (8)")
  ok(a ~= nil and b ~= nil, "both scouts existed")
end

-- ===========================================================================
-- 4. THE SCOUT: FOUR SECTIONS OF MEMORY (doc sections 3 and 4)
-- ===========================================================================

G("4. a scout that walks to their keep leaves memory of four sections")

do
  local sim = newSim(7)
  -- Give side 2 a full board so there is something to remember in every
  -- section: a front building, a back building and a keep taking damage.
  build(sim, 2, "palisade", FS(1))
  build(sim, 2, "granary", BS(1))
  sim.sides[2].keepHp = 40000

  local mem = Fog.newMemory(Rules)
  local u = place(sim, 1, 1, 0)

  -- Nothing seen yet.
  for s = 5, 8 do
    ok(not Fog.sectionSeen(mem, 1, s), format("section %d unseen before the walk", s))
  end

  -- WALK IT. One observation per position, which is Fog.OBSERVE_EVERY = 1 in
  -- the small: memory folds the state at every step.
  for p = 0, 1940 do
    u.pos = p
    Fog.observe(mem, sim, 1)
  end

  for s = 1, 8 do
    ok(Fog.sectionSeen(mem, 1, s), format("section %d seen after the walk", s))
  end
  eq(Fog.sectionSeen(mem, 2, 5), false, "and nothing at all was learned about lane 2")

  local b, hp, mhp, done, tick = Fog.rememberedBuilding(mem, FS(1))
  ok(b > 0, "their front building is remembered")
  eq(hp, mhp, "...at full HP, which is what it had")
  eq(done, 1, "...completed")
  ok(tick >= 0, "...with a last-seen tick")

  -- Their back slot: the front Palisade is still standing, so the shield in doc
  -- section 5 held for the whole walk and the Granary was never seen.
  local bb = Fog.rememberedBuilding(mem, BS(1))
  eq(bb, 0, "their back building was NOT seen through an intact front slot")

  eq(Fog.rememberedKeepHp(mem), 40000, "their keep HP is remembered from the walk")
end

-- ===========================================================================
-- 5. THE FRONT SLOT SHIELDS THE BACK SLOT (doc section 5)
-- ===========================================================================

G("5. the back slot is hidden behind an intact front slot and shows when it falls")

do
  local sim = newSim(8)
  build(sim, 2, "palisade", FS(2))
  build(sim, 2, "granary", BS(2))

  -- My unit standing right in their back slot's section.
  local u = place(sim, 1, 2, 1700)
  repin()
  eq(vis(sim, 1, 2)[7], 1, "I am in section 7")
  eq(Fog.seesEnemyBuilding(sim, 1, BS(2)), false,
    "their back building is invisible behind an intact front slot")

  -- ...and their front building, which I am nowhere near, is invisible too.
  eq(Fog.seesEnemyBuilding(sim, 1, FS(2)), false,
    "their front building is invisible from section 7")

  -- Raze the front slot the way the sim does.
  sim.sides[2].slots[FS(2)] = false
  eq(Fog.seesEnemyBuilding(sim, 1, BS(2)), true,
    "the back building appears the moment the front slot is empty")

  -- But only while I am standing there: the shield is not the only condition.
  u.pos = 1400
  eq(vis(sim, 1, 2)[7], 0, "I stepped out of section 7")
  eq(Fog.seesEnemyBuilding(sim, 1, BS(2)), false,
    "an empty front slot alone does not reveal the back one")

  -- An UNDER-CONSTRUCTION front building still shields (Rules INTERPRETATION 4:
  -- it occupies the slot and blocks). This is a stated reading, so it is
  -- asserted rather than assumed.
  u.pos = 1700
  eq(Fog.seesEnemyBuilding(sim, 1, BS(2)), true, "back slot visible with the front empty")
  local sim2 = newSim(9)
  -- Order matters: the Granary is finished FIRST, because completing it takes
  -- 130 ticks and would finish a Palisade started before it.
  build(sim2, 2, "granary", BS(2))
  place(sim2, 1, 2, 1700)
  fund(sim2, 2, 1000)
  order(sim2, 2, "c", FS(2), 1, sim2.clock + C.ORDER_DELAY)
  run(sim2, C.ORDER_DELAY + 5)
  repin()
  local fb = sim2.sides[2].slots[FS(2)]
  ok(fb ~= nil and fb.done == 0, "a Palisade is still under construction")
  eq(Fog.seesEnemyBuilding(sim2, 1, BS(2)), false,
    "an under-construction front building shields too")
end

do
  -- The front slot itself follows the plain section rule: section 6, no shield.
  local sim = newSim(10)
  build(sim, 2, "palisade", FS(3))
  local u = place(sim, 1, 3, 1300)
  repin()
  eq(Fog.seesEnemyBuilding(sim, 1, FS(3)), true, "their front building is visible from section 6")

  -- THIS ASSERTION CHANGED WITH THE OWNER'S SECTION 3a, AND THE OLD ONE IS
  -- QUOTED SO THE CHANGE IS READABLE. It used to say the front building is NOT
  -- visible from 1240 -- "section 5, 60 units away from it" -- which was open
  -- item 13: the exact position BUILD_BLOCKS_ADVANCE parks a melee attacker at.
  -- Contact reveal makes it visible, and the negation moves ONE UNIT: at 1239
  -- the gap is 61 against a 60 range, so there is no contact and section 5
  -- renders nothing.
  u.pos = 1240
  eq(Fog.seesEnemyBuilding(sim, 1, FS(3)), true,
    "their front building IS visible from 1240, which is exactly melee range")
  u.pos = 1239
  eq(Fog.seesEnemyBuilding(sim, 1, FS(3)), false,
    "...and not from 1239, one unit outside it, with section 5 dark")
end

-- ===========================================================================
-- 6. MEMORY FREEZES AND DOES NOT UPDATE (doc section 4)
-- ===========================================================================

G("6. memory freezes at last sight and never updates until seen again")

do
  local sim = newSim(11)
  local b = build(sim, 2, "palisade", FS(1))
  local full = b.hp

  local mem = Fog.newMemory(Rules)
  local u = place(sim, 1, 1, 1300)
  repin()
  Fog.observe(mem, sim, 1)

  local rb, rhp = Fog.rememberedBuilding(mem, FS(1))
  ok(rb > 0, "the front building is recorded on sight")
  eq(rhp, full, "...at its true HP")

  -- Walk out of the section, then wreck the building. Memory must not move.
  u.pos = 400
  Fog.observe(mem, sim, 1)
  b.hp = 1
  for _ = 1, 50 do Fog.observe(mem, sim, 1) end
  local _, hp2 = Fog.rememberedBuilding(mem, FS(1))
  eq(hp2, full, "HP is FROZEN while unobserved, not tracked")

  -- Destroy it entirely. The doc: "A building destroyed while unobserved still
  -- shows, intact, until you next see that section."
  sim.sides[2].slots[FS(1)] = false
  for _ = 1, 50 do Fog.observe(mem, sim, 1) end
  local b3, hp3 = Fog.rememberedBuilding(mem, FS(1))
  ok(b3 > 0, "a building destroyed unobserved still shows")
  eq(hp3, full, "...intact")

  -- Re-sight overwrites.
  u.pos = 1300
  Fog.observe(mem, sim, 1)
  local b4 = Fog.rememberedBuilding(mem, FS(1))
  eq(b4, 0, "the record is overwritten on re-sight, and the slot is now empty")
end

do
  -- The other direction: "A building constructed while unobserved does not
  -- appear at all."
  local sim = newSim(12)
  local mem = Fog.newMemory(Rules)
  local u = place(sim, 1, 2, 1300)
  Fog.observe(mem, sim, 1)
  eq(Fog.rememberedBuilding(mem, FS(2)), 0, "an empty slot, seen empty")

  u.pos = 100
  pinned[1].pos = 100
  build(sim, 2, "arrowTower", FS(2))
  repin()
  for _ = 1, 20 do Fog.observe(mem, sim, 1) end
  eq(Fog.rememberedBuilding(mem, FS(2)), 0,
    "a building constructed while unobserved does not appear")

  u.pos = 1300
  Fog.observe(mem, sim, 1)
  ok(Fog.rememberedBuilding(mem, FS(2)) > 0, "...and appears on the next sight")
end

do
  -- Keep HP is remembered, not live (doc section 4's third row).
  local sim = newSim(13)
  local mem = Fog.newMemory(Rules)
  eq(Fog.rememberedKeepHp(mem), C.KEEP_HP, "the keep starts remembered at full, which is public")

  local u = place(sim, 1, 3, 1900)
  sim.sides[2].keepHp = 30000
  Fog.observe(mem, sim, 1)
  eq(Fog.rememberedKeepHp(mem), 30000, "keep HP is recorded on sight")

  u.pos = 100
  sim.sides[2].keepHp = 10
  for _ = 1, 30 do Fog.observe(mem, sim, 1) end
  eq(Fog.rememberedKeepHp(mem), 30000, "keep HP is frozen once out of sight")

  u.pos = 1900
  Fog.observe(mem, sim, 1)
  eq(Fog.rememberedKeepHp(mem), 10, "...and updates on re-sight")
end

-- ===========================================================================
-- 7. UNITS ARE NOT GHOSTED (doc section 4)
-- ===========================================================================

G("7. enemy units are never remembered")

do
  local sim = newSim(14)
  local mem = Fog.newMemory(Rules)
  local scout = place(sim, 1, 1, 1400)
  local foeUnit = place(sim, 2, 1, 600)   -- their frame 600 == my 1400, section 6
  repin()

  eq(Fog.seesEnemyUnit(sim, 1, foeUnit), true, "their unit is visible while I stand in its section")
  Fog.observe(mem, sim, 1)

  -- Step away. The unit must vanish outright, with nothing left behind.
  scout.pos = 200
  eq(Fog.seesEnemyUnit(sim, 1, foeUnit), false, "their unit vanishes when I leave the section")

  -- And there is no accessor that would return it, and no field in the store
  -- that could hold it. This is structural rather than behavioural on purpose:
  -- the doc's rule is that unit memory MUST NOT EXIST, and a test that only
  -- checked the current answer would pass against an implementation that kept
  -- ghosts and simply did not return them yet.
  ok(Fog.rememberedUnits == nil, "there is no rememberedUnits accessor")
  ok(Fog.rememberedUnit == nil, "there is no rememberedUnit accessor")
  local unitish = {}
  for k, _ in pairs(mem) do
    local lk = k:lower()
    if lk:find("unit") or lk:find("army") or lk:find("stack") then
      unitish[#unitish + 1] = k
    end
  end
  eq(#unitish, 0, "no field in the memory store could hold a unit")
end

-- ===========================================================================
-- 8. ECONOMY IS NEVER VISIBLE (doc section 7)
-- ===========================================================================

G("8. enemy economy and loadout are never visible, by any route")

do
  eq(Fog.ECONOMY_EVER_VISIBLE, 0, "the model declares the economy unrenderable")

  -- Through the actual consumer, which is what would leak if anything did.
  local sim = newSim(15)
  local sd = sim.sides[2]
  sd.bank = 1234; sd.earned = 5678; sd.spent = 999; sd.wasted = 42
  build(sim, 2, "granary", BS(1))     -- gives them a non-zero cacheLevyFlat
  ok(sd.cacheLevyFlat > 0, "their Granary is paying them, so there IS something to leak")

  Policy.setVision(Policy.VISION_FOG)
  local mem1 = Fog.newMemory(Rules)
  local v = Policy.newView(Rules)

  -- The most privileged board a scout can buy: one of my units in EVERY section
  -- of every lane, front slots empty, so nothing is shielded anywhere.
  for lane = 1, C.LANES do
    for s = 5, 8 do
      place(sim, 1, lane, (s - 1) * Fog.SECTION_LEN + 10)
    end
  end
  repin()
  Fog.observe(mem1, sim, 1)
  Policy.fillView(v, sim, 1, nil, mem1)

  eq(v.foe.bank, 0, "bank is not rendered")
  eq(v.foe.earned, 0, "earned is not rendered")
  eq(v.foe.spent, 0, "spent is not rendered")
  eq(v.foe.wasted, 0, "wasted is not rendered")
  eq(v.foe.levyFlat, 0, "income is not rendered")
  eq(v.foe.spendable, 0, "spendable is not rendered")
  eq(v.foe.slotCap, C.SLOT_CAP, "their slot cap is the public default, not their loadout's")

  -- ...and full sight really was bought, so the zeros above are the rule and
  -- not an accident of an unlit board.
  local anySeen = 0
  for lane = 1, C.LANES do
    if v.me.lanes[lane].lit == Fog.SECTIONS then anySeen = anySeen + 1 end
  end
  eq(anySeen, C.LANES, "every section of every lane was lit for that check")
  ok(v.foe.lanes[1].backB > 0, "and their Granary IS rendered, so the board is not simply blank")
end

-- ===========================================================================
-- 9. THE WATCHTOWER (doc section 6)
-- ===========================================================================

G("9. a Watchtower makes sections 5 and 6 of its own lane permanently visible")

do
  local sim = newSim(16)
  local v0 = vis(sim, 1, 1)
  eq(v0[5], 0, "section 5 dark before the tower")

  local b = build(sim, 1, "watchtower", FS(1))
  eq(b.done, 1, "the tower is complete")
  local v1 = vis(sim, 1, 1)
  eq(v1[5], 1, "section 5 lit by the tower")
  eq(v1[6], 1, "section 6 lit by the tower")
  eq(v1[7], 0, "section 7 is NOT")
  eq(v1[8], 0, "section 8 is NOT")
  eq(vis(sim, 1, 2)[5], 0, "its own lane only")

  -- "Dies with the building."
  sim.sides[1].slots[FS(1)] = false
  eq(vis(sim, 1, 1)[5], 0, "and the sight dies with the building")

  -- A front building with no vision grants none.
  local sim2 = newSim(17)
  build(sim2, 1, "palisade", FS(1))
  eq(vis(sim2, 1, 1)[5], 0, "a Palisade grants no sight")
end

-- ===========================================================================
-- 10. THE OBSERVER IS SYMMETRIC (A.2)
-- ===========================================================================

G("10. the model is side-agnostic: the mirrored board mirrors exactly")

do
  -- The same physical situation, seated the other way round, must produce the
  -- same answers. If any of the frame arithmetic named a side, this fails.
  local a = newSim(18)
  place(a, 1, 2, 1400)
  build(a, 2, "palisade", FS(2))

  repin()
  local pinnedA = pinned

  local b = newSim(18)
  place(b, 2, 2, 1400)
  build(b, 1, "palisade", FS(2))
  repin()
  pinned = pinnedA
  repin()

  for s = 1, Fog.SECTIONS do
    eq(vis(a, 1, 2)[s], vis(b, 2, 2)[s], format("section %d reads the same from either seat", s))
  end
  eq(Fog.seesEnemyBuilding(a, 1, FS(2)), Fog.seesEnemyBuilding(b, 2, FS(2)),
    "the building predicate reads the same from either seat")

  local ma, mb = Fog.newMemory(Rules), Fog.newMemory(Rules)
  Fog.observe(ma, a, 1)
  Fog.observe(mb, b, 2)
  eq(Fog.memHash(ma), Fog.memHash(mb), "and the two memories are bit-identical")
end

-- ===========================================================================
-- 11. MEMORY IS DETERMINISTIC AND IS NOT IN THE STATE HASH
-- ===========================================================================

G("11. memory is a deterministic fold, and it is outside stateHash by design")

do
  -- Two independent replays of the same match produce the same memory, bit for
  -- bit, for both sides. This is the property that makes keeping memory out of
  -- Hash.state safe rather than merely convenient (fog/Fog.lua's MEMORY block).
  -- The two runs differ by the COMMAND LOG, not by the seed: the M1 ruleset
  -- consumes no randomness at all (sim/Rand.lua exists for the harness and the
  -- reserved seed field), so a seed change alone would move stateHash and
  -- nothing else, and "memory differs" would be untested.
  local function playAndFold(kind)
    local sim = newSim(4242)
    local m = { Fog.newMemory(Rules), Fog.newMemory(Rules) }
    local s = 0
    for tick = 0, 1500 do
      if tick % 50 == 0 then
        for side = 1, 2 do
          fund(sim, side, 500)
          s = s + 1
          sim:queueCommand({ side = side, seq = s, tick = tick + C.ORDER_DELAY,
            kind = (side == 1) and kind or "S", target = (tick % 3) + 1, count = 3 })
        end
      end
      if not sim:tick() then break end
      Fog.observe(m[1], sim, 1)
      Fog.observe(m[2], sim, 2)
    end
    return Fog.memHash(m[1]), Fog.memHash(m[2]), sim:stateHash()
  end

  local a1, a2, sh1 = playAndFold("H")
  local b1, b2, sh2 = playAndFold("H")
  eq(sh1, sh2, "the two replays are the same match")
  eq(a1, b1, "side 1's memory replays bit-identically")
  eq(a2, b2, "side 2's memory replays bit-identically")

  local c1, c2, sh3 = playAndFold("B")
  ok(sh3 ~= sh1, "a different command log is a different match")
  ok(c1 ~= a1 or c2 ~= a2, "...and produces a different memory, so memHash is not constant")
end

do
  -- THE EXCLUSION, ASSERTED. Mutating a memory store must not move stateHash,
  -- and the sim must hold no reference to one. A.5 grep 1 makes the second
  -- structural; this is the behavioural half.
  local sim = newSim(19)
  run(sim, 40)
  local before = sim:stateHash()
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  mem.keepHp = 1
  mem.slotB[1] = 7
  mem.secSeen[1][8] = 1
  eq(sim:stateHash(), before, "no amount of memory mutation moves stateHash")
  ok(Hash.state ~= nil and Fog.memHash ~= nil, "the two digests are separate functions")
end

-- ===========================================================================
-- 12. WHAT THE POLICY VIEW ACTUALLY SHOWS (the consumer, end to end)
-- ===========================================================================

G("12. the policy view is built from the model and from nothing else")

do
  Policy.setVision(Policy.VISION_FOG)
  local sim = newSim(20)
  build(sim, 2, "palisade", FS(1))
  build(sim, 2, "granary", BS(1))
  local mem = Fog.newMemory(Rules)
  local v = Policy.newView(Rules)

  -- A blank board: their whole army and both their buildings are hidden.
  -- Their frame 600 is MY 1400, which is section 6 -- the same section my scout
  -- takes below. (Their 500 would be my 1500, which is section 7: the
  -- boundaries are 250 apart and this is exactly the off-by-one the section
  -- table in test 1 exists to pin down.)
  place(sim, 2, 1, 600, "S")
  place(sim, 2, 1, 600, "S")
  repin()
  Fog.observe(mem, sim, 1)
  Policy.fillView(v, sim, 1, nil, mem)
  eq(v.foe.lanes[1].n, 0, "their units in their own half are not rendered")
  eq(v.foe.lanes[1].supply, 0, "...and contribute no supply")
  eq(v.foe.lanes[1].frontB, 0, "their unseen front building is not rendered")
  eq(v.foe.lanes[1].backB, 0, "their unseen back building is not rendered")
  eq(v.foe.occupied, 0, "...and their slot count reads empty, which is the doc's rule")
  eq(v.me.lanes[1].lit, Fog.OWN_SECTIONS, "I am looking at four sections")

  -- Now scout section 6 and only section 6. Their two units are in it, and so
  -- is their front slot, so one scout renders all three.
  place(sim, 1, 1, 1300)
  repin()
  Fog.observe(mem, sim, 1)
  Policy.fillView(v, sim, 1, nil, mem)
  eq(v.me.lanes[1].lit, Fog.OWN_SECTIONS + 1, "five sections lit")
  ok(v.foe.lanes[1].frontB > 0, "their front building is now rendered")
  eq(v.foe.lanes[1].backB, 0, "their back building is still shielded")
  eq(v.foe.lanes[1].n, 2, "their two units at my 1300 are rendered")
  eq(v.foe.lanes[1].supply, 2 * Rules.UNITS[1].cost, "...and now count toward supply")

  -- The keep HP the view carries is REMEMBERED, not live -- which is a change
  -- from the model this replaces, where it was exact from tick 0.
  sim.sides[2].keepHp = 100
  Fog.observe(mem, sim, 1)
  Policy.fillView(v, sim, 1, nil, mem)
  eq(v.foe.keepHp, C.KEEP_HP, "their keep HP is the remembered one, not the live one")

  -- Under full information, everything.
  Policy.setVision(Policy.VISION_FULL)
  Policy.fillView(v, sim, 1, nil, mem)
  ok(v.foe.lanes[1].backB > 0, "full information renders the back building")
  eq(v.foe.keepHp, 100, "full information renders live keep HP")
  ok(v.foe.bank >= 0, "full information renders the purse")
  eq(v.me.lanes[1].lit, Fog.SECTIONS, "and calls every section lit, so it stays a superset")
  Policy.setVision(Policy.VISION_FOG)
end

do
  -- The fogged regime REFUSES to build a view without a memory store, rather
  -- than quietly rendering every enemy building as an empty slot forever.
  Policy.setVision(Policy.VISION_FOG)
  local sim = newSim(21)
  local v = Policy.newView(Rules)
  local okCall = pcall(Policy.fillView, v, sim, 1, nil, nil)
  eq(okCall, false, "fillView without a memory store is an error, not a silent blank board")
end

-- ===========================================================================
-- 13. THE MUSTER BAR IS GONE
-- ===========================================================================

G("13. the muster bar and its thresholds are deleted, not disabled")

do
  ok(Policy.MUSTER_HP_PRESSURE == nil, "no MUSTER_HP_PRESSURE constant survives")
  ok(Policy.MUSTER_HP_HEAVY == nil, "no MUSTER_HP_HEAVY constant survives")
  ok(Policy.MUSTER_SUPPLY_PRESSURE == nil, "no MUSTER_SUPPLY_PRESSURE constant survives")
  ok(Policy.ALARM_PRESSURE == nil, "no ALARM_PRESSURE constant survives")
  ok(Policy.ALARM_HEAVY == nil, "no ALARM_HEAVY constant survives")
  ok(Policy.ALARM_NEVER == nil, "no ALARM_NEVER constant survives")
  ok(Policy.VISION_A3 == nil, "the old regime name is gone too")

  local v = Policy.newView(Rules)
  ok(rawget(v.foe.lanes[1], "muster") == nil, "no muster field in the lane view")

  local linesM = require("policy.lines")
  for i = 1, #linesM.CFG_FIELDS do
    ok(linesM.CFG_FIELDS[i] ~= "alarm", "no `alarm` in the canonical cfg field list")
  end
  for i = 1, #linesM.LINES do
    local cfg = linesM.LINES[i].cfg
    ok(cfg.alarm == nil, format("%s declares no alarm", linesM.LINES[i].name))
    -- TWO FLOORS, NOT ONE, because the section model has two kinds of line: a
    -- threshold below the midline is not dead, it is BOUGHT. A line that buys
    -- nothing may not name one; a line that declares a scout may go as deep as
    -- the first bought section renders and no deeper.
    local floorPos = (cfg.scout == 1) and Policy.SCOUT_SIGHT or Policy.REACT_MIN
    ok(cfg.reactAt >= floorPos,
      format("%s declares a reactAt its declared sight can deliver",
        linesM.LINES[i].name))
  end

  -- The derived 2,800 / 5,600 HP thresholds are void: nothing anywhere may
  -- still compute them.
  local laneHp = C.LANE_SUPPLY_CAP * floor(Rules.UNITS[1].hp / Rules.UNITS[1].cost)
  eq(laneHp, 8400, "the arithmetic those thresholds came from still exists in the ruleset")
  ok(Policy.MUSTER_LANE_HP == nil, "...but nothing in the policy layer computes it any more")
end

-- ===========================================================================
-- 14. SIGHT IS A PURCHASE: THE GEOMETRY OF A SCOUT (doc section 3)
-- ===========================================================================

G("14. what one body past the midline is worth, and what it is not")

do
  -- The inverse of the section table: the deepest enemy own-frame position each
  -- observer section renders. Asserted against the doc's own numbers rather
  -- than against the formula that produced them.
  eq(Fog.enemyPosLowOfSection(5), 751, "section 5 reaches their own-frame 751")
  eq(Fog.enemyPosLowOfSection(6), 501, "section 6 reaches their own-frame 501")
  eq(Fog.enemyPosLowOfSection(7), 251, "section 7 reaches their own-frame 251")
  eq(Fog.enemyPosLowOfSection(8), 0, "section 8 reaches their keep")
  eq(Fog.SCOUT_SIGHT, Fog.enemyPosLowOfSection(Fog.OWN_SECTIONS + 1),
    "SCOUT_SIGHT is the first bought section's deep edge")
  ok(Fog.SCOUT_SIGHT > 0 and Fog.SCOUT_SIGHT < Fog.DEFAULT_SIGHT,
    "buying the first section is strictly better than not, and not unlimited")

  -- AND THE NEGATION, which is the half that matters: one section deeper is
  -- NOT rendered. A body at the midline does not see their staging ground.
  eq(Fog.sectionOfEnemy(Fog.SCOUT_SIGHT), Fog.OWN_SECTIONS + 1,
    "SCOUT_SIGHT lands in the section the tripwire lights")
  eq(Fog.sectionOfEnemy(Fog.SCOUT_SIGHT - 1), Fog.OWN_SECTIONS + 2,
    "one unit deeper is a section the tripwire does NOT light")
end

do
  -- The same claim end to end, on a real board: my body at own-frame 1100 is in
  -- section 5, and it renders their unit at own-frame 900 (also section 5) and
  -- NOT their unit at own-frame 700 (section 6).
  local sim = newSim(14)
  place(sim, 1, 1, 1100, "S")
  place(sim, 2, 1, 900, "S")
  place(sim, 2, 1, 700, "S")
  repin()
  local v = vis(sim, 1, 1)
  eq(v[5], 1, "my body at 1100 lights section 5")
  eq(v[6], 0, "...and not section 6")
  local es = sim.sides[2].lanes[1].units
  local seen900, seen700 = 0, 0
  for i = 1, #es do
    if es[i].pos == 900 and Fog.seesEnemyUnit(sim, 1, es[i]) then seen900 = 1 end
    if es[i].pos == 700 and Fog.seesEnemyUnit(sim, 1, es[i]) then seen700 = 1 end
  end
  eq(seen900, 1, "their unit at 900 is rendered by the bought section")
  eq(seen700, 0, "their unit at 700 is not: the tripwire bought one section")
end

do
  -- THE COST SIDE, asserted rather than asserted-in-a-comment: the sight dies
  -- with the body. Kill the scout and the section goes dark again, and nothing
  -- of the enemy UNITS is remembered (doc section 4).
  local sim = newSim(15)
  place(sim, 1, 2, 1100, "S")
  place(sim, 2, 2, 900, "S")
  repin()
  eq(vis(sim, 1, 2)[5], 1, "section 5 is lit while the body stands there")
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  local us = sim.sides[1].lanes[2].units
  for i = #us, 1, -1 do us[i] = nil end
  pinned = {}
  eq(vis(sim, 1, 2)[5], 0, "the body dies and section 5 goes dark")
  local es = sim.sides[2].lanes[2].units
  eq(Fog.seesEnemyUnit(sim, 1, es[1]) and 1 or 0, 0,
    "their unit is no longer rendered")
  ok(mem.secSeen[2][5] == 1, "the SECTION is remembered as explored")
  -- ...and there is no accessor that would hand back the unit.
  ok(Fog.rememberedUnit == nil, "there is no remembered-unit accessor at all")
end

do
  -- THE ROSTER'S SIDE OF THE CONTRACT. Scouting is a declared, per-line
  -- property and most lines must NOT have it, or the column measures nothing.
  local linesM = require("policy.lines")
  local nScout = 0
  for i = 1, #linesM.LINES do
    local cfg = linesM.LINES[i].cfg
    ok(cfg.scout == 0 or cfg.scout == 1,
      format("%s declares scout as 0 or 1", linesM.LINES[i].name))
    if cfg.scout == 1 then
      nScout = nScout + 1
      ok(cfg.holdUntilBuilt == 0,
        format("%s does not also refuse to field anything", linesM.LINES[i].name))
    end
  end
  ok(nScout > 0, "at least one line buys sight")
  ok(nScout < #linesM.LINES,
    "...and not every line does, or there is no control to read it against")

  -- The scout body and its two cadences are DERIVED from the ruleset, not
  -- chosen. SCOUT_EVERY holds one lane watched; SCOUT_EVERY_MIN holds all of
  -- them, and is the floor a line may declare down to.
  eq(Policy.SCOUT_TYPE, 1, "the scout is the cheapest body in the catalogue")
  local traversal = floor(C.LANE_LEN / Rules.UNITS[Policy.SCOUT_TYPE].march)
  eq(Policy.SCOUT_EVERY, traversal + C.ORDER_DELAY,
    "the default cadence is one lane traversal plus one order delay")
  eq(Policy.SCOUT_EVERY_MIN, floor(traversal / C.LANES) + C.ORDER_DELAY,
    "the floor is that traversal split across the lanes there are to watch")
  ok(Policy.SCOUT_EVERY_MIN < Policy.SCOUT_EVERY,
    "...which is strictly faster, or there would be no axis")

  -- THE AXIS IS SPANNED, WHICH IS THE PROPERTY THE ROSTER LACKED. A boolean
  -- scout flag with every scout at one cadence cannot price looking; this
  -- asserts that at least one line sits at each end and that most sit at
  -- neither.
  local atFloor, atDefault = 0, 0
  for i = 1, #linesM.LINES do
    local cfg = linesM.LINES[i].cfg
    ok(cfg.scoutEvery >= Policy.SCOUT_EVERY_MIN,
      format("%s declares a cadence the derivation allows", linesM.LINES[i].name))
    if cfg.scout == 0 then
      eq(cfg.scoutEvery, Policy.SCOUT_EVERY,
        format("%s buys no sight, so it carries the default cadence and no other",
          linesM.LINES[i].name))
    elseif cfg.scoutEvery == Policy.SCOUT_EVERY_MIN then
      atFloor = atFloor + 1
    else
      atDefault = atDefault + 1
    end
  end
  ok(atFloor >= 1, "at least one line buys sight at the floor")
  ok(atDefault >= 1, "...and at least one buys it at the default, so the two differ")
  ok(atFloor + atDefault < #linesM.LINES,
    "...and the roster is not all scouts")
end

do
  -- WHERE THE NEXT TRIPWIRE GOES. Policy.darkLane is a pure function of the
  -- OBSERVER's own lanes, so it can be tested exactly. The case that matters is
  -- the one the old rule got wrong: it ranked on `seen`, which is cumulative and
  -- never falls, so a line that scouts for a whole match saturates all three
  -- lanes, ties, and sends every remaining body to lane 1.
  local v = Policy.newView(Rules)
  for l = 1, C.LANES do
    v.me.lanes[l].lit = Fog.OWN_SECTIONS
    v.me.lanes[l].seen = Fog.OWN_SECTIONS
    v.me.lanes[l].maxPos = 0
  end
  eq(Policy.darkLane(v), 1, "three equally dark lanes tie to the lowest index")

  v.me.lanes[1].lit = 5; v.me.lanes[1].seen = 5
  eq(Policy.darkLane(v), 2, "a lane I can already see is not where the next one goes")
  v.me.lanes[2].lit = 5; v.me.lanes[2].seen = 5
  eq(Policy.darkLane(v), 3, "...and coverage rotates to the third")

  -- Every lane explored, so `seen` is saturated and carries nothing; lane 1's
  -- body has died and its section has gone dark again.
  for l = 1, C.LANES do v.me.lanes[l].seen = Fog.SECTIONS end
  v.me.lanes[1].lit = Fog.OWN_SECTIONS
  eq(Policy.darkLane(v), 1, "the lane whose scout just died is the one to re-light")
  v.me.lanes[1].lit = 5; v.me.lanes[3].lit = Fog.OWN_SECTIONS
  eq(Policy.darkLane(v), 3, "...and it follows the dark rather than a fixed lane")

  -- A lane my own army is already standing in buys nothing: it is lit by the
  -- attack.
  v.me.lanes[3].maxPos = C.POS_MIDLINE + 1
  eq(Policy.darkLane(v), 1,
    "no tripwire into a lane my army is already past the midline in")

  -- And under full information every lane is fully lit, so a scouting line
  -- spends nothing there and that regime stays an upper bound.
  for l = 1, C.LANES do
    v.me.lanes[l].lit = Fog.SECTIONS
    v.me.lanes[l].maxPos = 0
  end
  eq(Policy.darkLane(v), 0, "a fully visible board buys no scout at all")
end

do
  -- THE ONE DISCLOSURE ROUTE THE VIEW STILL CARRIES, PINNED SO THE CLAIM ABOUT
  -- IT CANNOT ROT. `me.keepDamageDealt` makes the enemy keep's exact live HP
  -- derivable with no sight at all (nothing heals a keep, nothing but units
  -- damages one), which contradicts doc section 4's "HP remembered from last
  -- sight". It is left in the view because it is also this side's own statistic
  -- and Rules.C.SCORE_SHOW_TICK exists to display the Q10 score live -- two
  -- documents, and README open item 18 asks for the ruling. What this file can
  -- assert is the thing the README claims: NO LINE READS IT. A source-text
  -- check, because there is no runtime signal for "a field nobody looked at".
  local f = io.open(here .. "/../policy/lines.lua", "r")
  ok(f ~= nil, "policy/lines.lua is readable")
  if f then
    local src = f:read("*a")
    f:close()
    ok(src:find("keepDamageDealt", 1, true) == nil,
      "no line reads keepDamageDealt (open item 18's escape hatch stays unused)")
    ok(src:find("penetration", 1, true) == nil,
      "no line reads the foe's penetration total")
    ok(src:find("foe.bank", 1, true) == nil and src:find("foe.earned", 1, true) == nil
       and src:find("foe.levyFlat", 1, true) == nil,
      "no line reads the foe's purse, income or flat Levy")
  end
end

-- ===========================================================================
-- 15. CONTACT REVEALS: YOU SEE WHAT YOU ARE FIGHTING (doc section 3a)
--
-- The owner's ruling of 2026-08-13. Every board below is MARCHED rather than
-- written, because the whole rule is about the position the sim parks a unit at
-- when it engages something, and that position is the thing under test.
-- ===========================================================================

G("15. contact reveals the entity you are in combat with, and only that entity")

do
  -- THE RULE'S OWN GEOMETRY, from the ruleset. This is open item 13 stated as
  -- arithmetic: melee range 60, their wall at observer 1300, so an attacker
  -- stands in section 5 and hits a building in section 6.
  eq(Fog.OBS_ENEMY_FRONT, 1300, "their front slot is at observer coordinate 1300")
  eq(Fog.OBS_ENEMY_BACK, 1700, "their back slot is at observer coordinate 1700")
  eq(Fog.OBS_ENEMY_KEEP, C.LANE_LEN, "their keep is at the far end")
  eq(Fog.CONTACT_HITS_BUILDINGS, C.BUILD_BLOCKS_ADVANCE,
    "units can be in contact with buildings exactly when the ruleset lets them attack one")
  eq(Fog.sectionOfOwn(Fog.OBS_ENEMY_FRONT - Rules.UNITS[1].range), Fog.OWN_SECTIONS + 1,
    "a melee attacker halted by their wall stands one section SHORT of it")
end

do
  -- (1) THE ATTACKER SEES THE BUILDING IT IS GRINDING. Marched in from 0.
  local sim = newSim(30)
  build(sim, 2, "palisade", FS(1))
  local u = deploy(sim, 1, 1, "S")
  run(sim, 200)
  eq(u.pos, Fog.OBS_ENEMY_FRONT - Rules.UNITS[1].range,
    "BUILD_BLOCKS_ADVANCE stops the Spear at 1240")
  eq(Fog.sectionOfOwn(u.pos), 5, "...which is section 5")
  local v = vis(sim, 1, 1)
  eq(v[6], 0, "their wall's section is NOT lit -- contact is entity-scoped")
  eq(v[5], 1, "only the section the attacker is standing in is lit")
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), true,
    "and the attacker SEES the wall it is destroying (open item 13, closed)")

  -- The negation, and it costs one unit of ground: 61 away is not contact.
  u.pos = u.pos - 1
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), false, "one unit out of range and it is dark again")
  u.pos = Fog.OBS_ENEMY_FRONT - Rules.UNITS[1].range

  -- ...and it dies with the body, exactly as section 3's sight does.
  local us = sim.sides[1].lanes[1].units
  for i = #us, 1, -1 do us[i] = nil end
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), false, "the sight dies with the attacker")
end

do
  -- (2) THE DEFENDER SEES ITS ATTACKER, which is the same defect on the other
  -- side of the midline and was never written down. Two Spears deployed on the
  -- SAME tick meet 60 apart at 970 / 970 -- mine in my section 4, theirs in my
  -- section 5 -- so under the section rule alone a defender is killed by a stack
  -- it cannot see.
  local sim = newSim(31)
  fund(sim, 1, 1000); fund(sim, 2, 1000)
  order(sim, 1, "S", 1, 1, C.ORDER_DELAY)
  order(sim, 2, "S", 1, 1, C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + 220)
  local mine = sim.sides[1].lanes[1].units[1]
  local theirs = sim.sides[2].lanes[1].units[1]
  eq(mine.pos, 970, "my Spear halts at 970")
  eq(theirs.pos, 970, "theirs halts at their own 970, which is my 1030")
  eq(Fog.sectionOfOwn(mine.pos), 4, "mine is in my own half")
  eq(Fog.sectionOfEnemy(theirs.pos), 5, "theirs is one section past the midline")
  eq(vis(sim, 1, 1)[5], 0, "and I light nothing over there")
  eq(Fog.seesEnemyUnit(sim, 1, theirs), true, "I see the stack that is killing me")
  eq(Fog.seesEnemyUnit(sim, 2, mine), true, "...and it sees me: equal ranges, symmetric")

  -- The negation at the boundary: one unit further back is 61 away.
  local keep = theirs.pos
  theirs.pos = keep - 1
  eq(Fog.seesEnemyUnit(sim, 1, theirs), false, "one unit outside melee range, invisible again")
  theirs.pos = keep
end

do
  -- (3) CONTACT DOES NOT REVEAL NEIGHBOURS IN THE SAME SECTION. My attacker at
  -- 1240 is in contact with their wall at 1300 and with a body at 1290; a second
  -- body at 1400 is in the SAME section 6 as both and stays dark, and so does
  -- their back building.
  local sim = newSim(32)
  build(sim, 2, "palisade", FS(1))
  build(sim, 2, "granary", BS(1))
  place(sim, 1, 1, 1240)
  local near = place(sim, 2, 1, 710)    -- their frame 710 == my 1290
  local far  = place(sim, 2, 1, 600)    -- their frame 600 == my 1400
  repin()
  eq(Fog.sectionOfEnemy(near.pos), 6, "their near body is in section 6")
  eq(Fog.sectionOfEnemy(far.pos), 6, "...and so is their far one")
  eq(vis(sim, 1, 1)[6], 0, "section 6 is not lit by anything")
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), true, "the wall I am hitting is visible")
  eq(Fog.seesEnemyUnit(sim, 1, near), true, "so is the body 50 units away, which I am also hitting")
  eq(Fog.seesEnemyUnit(sim, 1, far), false,
    "the body 160 units away is NOT, though it stands in the same section")
  eq(Fog.seesEnemyBuilding(sim, 1, BS(1)), false, "and their back building is NOT")
end

do
  -- (4) THE FRONT-SLOT SHIELD SURVIVES, SWEPT RATHER THAN ASSERTED. For every
  -- body in C.3, every position it can hold on the near side of an intact wall
  -- is checked against the back building. The reachable set is bounded by
  -- BUILD_BLOCKS_ADVANCE at 1300 - range, which is what makes this a proof about
  -- the geometry the doc reasons from rather than about one placement.
  for t = 1, #Rules.UNITS do
    local sim = newSim(33 + t)
    build(sim, 2, "palisade", FS(1))
    build(sim, 2, "granary", BS(1))
    local reach = Rules.UNITS[t].range
    local stop = Fog.OBS_ENEMY_FRONT - reach
    local u = place(sim, 1, 1, 0, Rules.UNITS[t].kind)
    repin()
    eq(Fog.unitReach(sim, 1, u), reach,
      format("a %s reaches %d units, as C.3 says", Rules.UNITS[t].key, reach))
    local leaks = 0
    for p = 0, stop do
      u.pos = p
      if Fog.seesEnemyBuilding(sim, 1, BS(1)) then leaks = leaks + 1 end
    end
    ok(leaks == 0, format(
      "a %s sees the shielded back building from NONE of the %d positions it can reach",
      Rules.UNITS[t].key, stop + 1))

    -- AND THE SWEEP IS NOT VACUOUS. Raze the front slot and the same predicate,
    -- on the same board, answers true from the position the unit can now walk
    -- to -- which for a Bow is section 6, so the contact route is doing work the
    -- section rule cannot do.
    u.pos = Fog.OBS_ENEMY_BACK - reach
    eq(Fog.seesEnemyBuilding(sim, 1, BS(1)), false,
      format("...still not, at %d, while the wall stands", u.pos))
    sim.sides[2].slots[FS(1)] = false
    eq(Fog.seesEnemyBuilding(sim, 1, BS(1)), true,
      format("...and it does see it once the wall is gone (%s at %d)",
        Rules.UNITS[t].key, u.pos))
  end
end

do
  -- (4b) THE ONE BOARD WHERE THE TWO SENTENCES OF THE DOC DISAGREE, PINNED.
  -- Section 5: the shield holds "even from a unit standing right next to it".
  -- Section 3a: you see what you are fighting. A unit already past their front
  -- slot when they REBUILD it is both. The implementation gives section 5 the
  -- decision -- it is the sentence that describes this exact distance -- so the
  -- shield is unconditional and a unit is hitting something it cannot see.
  -- README open item 19 asks for the ruling; this test exists so the answer
  -- cannot change by accident.
  local sim = newSim(37)
  build(sim, 2, "granary", BS(2))
  local u = place(sim, 1, 2, Fog.OBS_ENEMY_BACK)
  repin()
  eq(vis(sim, 1, 2)[7], 1, "my infiltrator is standing in section 7")
  eq(Fog.seesEnemyBuilding(sim, 1, BS(2)), true, "with no wall, it sees their back building")
  build(sim, 2, "palisade", FS(2))
  repin()
  eq(Fog.seesEnemyBuilding(sim, 1, BS(2)), false,
    "they rebuild the wall BEHIND it and the back building goes dark again")
  eq(Fog.inContactWithBuilding(sim, 1, BS(2)), false,
    "...and contact refuses it too: the shield outranks 3a, by ruling")

  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  eq(Fog.rememberedBuilding(mem, BS(2)), 0, "and nothing about it reaches memory either")
end

do
  -- (5) A BOW STOPS AT 980 -- INSIDE ITS OWN HALF, TWO SECTIONS SHORT OF WHAT IT
  -- IS SHOOTING -- AND STILL SEES IT. This is the case that makes the rule
  -- entity-scoped rather than "light the section in front of you": a rule that
  -- granted the shot section would hand a Bow two sections of free vision from
  -- inside its own territory.
  local sim = newSim(38)
  build(sim, 2, "palisade", FS(3))
  local u = deploy(sim, 1, 3, "B")
  run(sim, 300)
  eq(u.pos, Fog.OBS_ENEMY_FRONT - Rules.UNITS[3].range, "the sim stops the Bow at 980")
  eq(Fog.sectionOfOwn(u.pos), Fog.OWN_SECTIONS, "...inside its own half")
  local v = vis(sim, 1, 3)
  local lit = 0
  for s = 1, Fog.SECTIONS do lit = lit + v[s] end
  eq(lit, Fog.OWN_SECTIONS, "it has bought no section at all")
  eq(v[5], 0, "section 5 dark")
  eq(v[6], 0, "section 6, where the wall is, dark")
  eq(Fog.seesEnemyBuilding(sim, 1, FS(3)), true, "and it sees the wall it is shooting")
end

do
  -- (5b) THE ENVELOPE IS THE SIM'S, INCLUDING THE ONE THING THAT MOVES IT. A
  -- Fletcher gives that lane's Bows +6 range, and Fog.unitReach mirrors
  -- Sim.unitRangeOf rather than reading the catalogue flat. The check is
  -- BEHAVIOURAL: the sim itself parks the Bow 326 short of the wall, so if the
  -- two ever disagreed this test would show it as a position mismatch rather
  -- than as an opinion about which file is right.
  local sim = newSim(44)
  build(sim, 1, "fletcher", BS(3))
  build(sim, 2, "palisade", FS(3))
  local u = deploy(sim, 1, 3, "B")
  run(sim, 300)
  local reach = Rules.UNITS[3].range + Rules.BUILDINGS[Policy.BLD_INDEX.fletcher].auraBowRange
  eq(Fog.unitReach(sim, 1, u), reach, "a Bow behind a Fletcher reaches 326")
  eq(u.pos, Fog.OBS_ENEMY_FRONT - reach, "and the SIM stops it 326 short of the wall")
  eq(Fog.seesEnemyBuilding(sim, 1, FS(3)), true, "it sees what it is shooting")
  u.pos = u.pos - 1
  eq(Fog.seesEnemyBuilding(sim, 1, FS(3)), false, "one unit further back, it does not")
end

do
  -- (6) MEMORY TAKES THE CONTACT ROUTE, AND TAKES ONLY THE ENTITY. The wall an
  -- attacker grinds is recorded; the ground it stands on is not marked explored,
  -- which is what stops `seen` from quietly starting to measure combat.
  local sim = newSim(39)
  local b = build(sim, 2, "palisade", FS(1))
  local mem = Fog.newMemory(Rules)
  local u = deploy(sim, 1, 1, "S")
  run(sim, 220)
  Fog.observe(mem, sim, 1)
  local rb, rhp, rmax, rdone = Fog.rememberedBuilding(mem, FS(1))
  ok(rb > 0, "the wall an attacker is hitting enters memory")
  eq(rdone, 1, "...completed")
  eq(rhp, b.hp, "...at the HP it has right now, which is below full")
  ok(b.hp < b.maxHp, "...and it really is below full, so that check is not trivial")
  eq(rmax, b.maxHp, "...with its maximum")
  eq(Fog.sectionSeen(mem, 1, 5), true, "the section the ATTACKER stands in is explored")
  eq(Fog.sectionSeen(mem, 1, 6), false,
    "the section the WALL stands in is NOT: contact records the entity, not the ground")
  ok(u.pos > 0, "the attacker marched")

  -- An EMPTY slot cannot be fought, so contact never discloses one -- doc
  -- section 5's "an empty slot is indistinguishable from an unseen one".
  eq(Fog.inContactWithBuilding(sim, 1, BS(1)), false, "an empty back slot is not in contact")
  eq(Fog.rememberedBuilding(mem, BS(1)), 0, "...and nothing about it is remembered")
end

do
  -- (7) THE KEEP. A Bow razing it halts at 1680, which is section 7, so under
  -- the section rule alone the unit killing the keep could not watch it fall.
  local sim = newSim(40)
  local u = deploy(sim, 1, 2, "B")
  run(sim, 320)
  eq(u.pos, C.LANE_LEN - Rules.UNITS[3].range, "the Bow halts at 1680")
  eq(Fog.sectionOfOwn(u.pos), 7, "...which is section 7, not the keep's section")
  eq(vis(sim, 1, 2)[8], 0, "section 8 is dark")
  eq(Fog.seesEnemyKeep(sim, 1), true, "and it sees the keep it is shooting")

  sim.sides[2].keepHp = 12345
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  eq(Fog.rememberedKeepHp(mem), 12345, "keep HP is recorded through the contact route")

  u.pos = u.pos - 1
  eq(Fog.seesEnemyKeep(sim, 1), false, "one unit further back and the keep is a memory again")
end

do
  -- (8) THE ASYMMETRY, STATED AND PINNED. Contact is the OBSERVER's envelope, so
  -- a shooter that outranges its target is not revealed to it: you do not see
  -- what is shooting you if you cannot shoot back. Their Bow at my 1220 is in
  -- contact with my Spear at 900 from ITS seat and not from mine.
  local sim = newSim(41)
  local mine = place(sim, 1, 1, 900, "S")
  local theirs = place(sim, 2, 1, 780, "B")   -- their frame 780 == my 1220
  repin()
  eq(Fog.seesEnemyUnit(sim, 2, mine), true, "their Bow is in contact with my Spear")
  eq(Fog.seesEnemyUnit(sim, 1, theirs), false, "and my Spear cannot see the Bow shooting it")

  -- Give the same seat the same weapon and the relation is symmetric again.
  local myBow = place(sim, 1, 2, 900, "B")
  local theirBow = place(sim, 2, 2, 780, "B")
  repin()
  eq(Fog.seesEnemyUnit(sim, 1, theirBow), true, "Bow against Bow, I see them")
  eq(Fog.seesEnemyUnit(sim, 2, myBow), true, "...and they see me")
end

do
  -- (9) CONTACT IS SIDE-AGNOSTIC (A.2). The same physical board seated the other
  -- way round gives the same answers and the same memory.
  local a = newSim(42)
  build(a, 2, "palisade", FS(1))
  place(a, 1, 1, 1240)
  repin()
  local pinnedA = pinned

  local b = newSim(42)
  build(b, 1, "palisade", FS(1))
  place(b, 2, 1, 1240)
  repin()
  pinned = pinnedA
  repin()

  eq(Fog.seesEnemyBuilding(a, 1, FS(1)), Fog.seesEnemyBuilding(b, 2, FS(1)),
    "the contact route reads the same from either seat")
  eq(Fog.seesEnemyBuilding(a, 1, FS(1)), true, "...and it is true, so that is not vacuous")
  local ma, mb = Fog.newMemory(Rules), Fog.newMemory(Rules)
  Fog.observe(ma, a, 1)
  Fog.observe(mb, b, 2)
  eq(Fog.memHash(ma), Fog.memHash(mb), "and the two memories are bit-identical")
end

do
  -- (10) THE CONSUMER, END TO END. The policy view must show the wall an
  -- attacker is grinding -- that is the whole point of the ruling -- while `lit`
  -- stays at the four free sections, which is the whole point of it being
  -- entity-scoped.
  Policy.setVision(Policy.VISION_FOG)
  local sim = newSim(43)
  build(sim, 2, "palisade", FS(2))
  build(sim, 2, "granary", BS(2))
  local mem = Fog.newMemory(Rules)
  local v = Policy.newView(Rules)
  local u = deploy(sim, 1, 2, "S")
  run(sim, 200)
  Fog.observe(mem, sim, 1)
  Policy.fillView(v, sim, 1, nil, mem)
  ok(v.foe.lanes[2].frontB > 0, "the view renders the wall the attacker is hitting")
  eq(v.foe.lanes[2].backB, 0, "...and not the building behind it")
  eq(v.me.lanes[2].lit, Fog.OWN_SECTIONS + 1,
    "and the attacker has lit only the section it is standing in")
  eq(v.me.lanes[2].seen, Fog.OWN_SECTIONS + 1, "...and explored only that one")
  ok(u.pos == Fog.OBS_ENEMY_FRONT - Rules.UNITS[1].range, "the attacker is at the wall")
end

-- ---------------------------------------------------------------------------

print("")
if failures == 0 then
  print(format("FOG: PASS -- %d checks, every rule in IDLE_BATTLE_FOG.md holds", checks))
  os.exit(0)
end
print(format("FOG: FAIL -- %d of %d checks failed", failures, checks))
os.exit(1)
