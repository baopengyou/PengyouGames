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
-- SINCE M3 PART 2 it also covers the four INFORMATION EFFECTS of doc section 6
-- (sections 16-21: Divination, Omen, Veil with its precedence rule, the Shrine
-- pulse, the three-layer memory composition, and the tower/card compositions
-- from both seats) and section 22, the MUTATION suite: a copy of fog/Fog.lua
-- with one effect surgically disabled is loaded from /tmp and the checks that
-- effect carries must flip -- the proof that none of 16-19 passes vacuously.
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

-- loA / loB are 5-slot loadout arrays (M3 part 2's sections hand them in);
-- partial loadouts are legal in the sim (Rules INTERPRETATIONS 13).
local function newSim(seed, loA, loB)
  pinned = {}
  return SimM.new(Rules, seed or 1, loA, loB)
end

-- Loadout literals for the info-card sections. Card ids come from the hashed
-- pool, never hand-written.
local CARD_DIV = Rules.CARD_BY_KEY.divination
local CARD_OMEN = Rules.CARD_BY_KEY.omen
local CARD_VEIL = Rules.CARD_BY_KEY.veil
local function lo(...) return { ... } end

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

-- ===========================================================================
-- 16. DIVINATION (doc section 6; D.3 Mystic card 2) -- M3 part 2
--
-- "All COMPLETED enemy buildings -- slot and identity, continuously, in every
-- lane, ignoring both the section rule and the front-slot shield. Never HP,
-- never buildings under construction."
-- ===========================================================================

G("16. Divination scries slot and identity, continuously, and nothing else")

do
  -- Every lane, ignoring the section rule: no unit of mine anywhere, and every
  -- completed building of theirs is scried anyway. (Two boards, because the
  -- C.SLOT_CAP of 4 will not hold every case at once.)
  local sim = newSim(50, lo(CARD_DIV), nil)
  local pal = build(sim, 2, "palisade", FS(1))
  build(sim, 2, "granary", BS(2))
  eq(Fog.divinedBuilding(sim, 1, FS(1)), pal.b, "their lane-1 front building is scried with no sight at all")
  ok(Fog.divinedBuilding(sim, 1, BS(2)) > 0, "...and their lane-2 back building, a different lane")
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), false, "while the full-sight predicate still says dark")

  -- Identity means identity: two different buildings scry as their two
  -- different catalogue indices.
  ok(Fog.divinedBuilding(sim, 1, FS(1)) ~= Fog.divinedBuilding(sim, 1, BS(2)),
    "the scry names WHICH building, not merely occupancy")

  -- An empty slot scries 0 -- and so does everything else that must: the card
  -- gate and the missing card.
  eq(Fog.divinedBuilding(sim, 1, FS(2)), 0, "an empty slot scries empty")
  eq(Fog.divinedBuilding(sim, 2, FS(1)), 0, "the side without the card scries nothing")

  -- Never under construction: scaffolding scries 0 until the tick it completes.
  fund(sim, 2, 1000)
  order(sim, 2, "c", FS(2), 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + 5)
  local sc = sim.sides[2].slots[FS(2)]
  ok(sc ~= false and sc.done == 0, "a Palisade is under construction")
  eq(Fog.divinedBuilding(sim, 1, FS(2)), 0, "scaffolding is never scried (D.3's own amendment)")
  run(sim, Rules.BUILDINGS[sc.b].build + 5)
  eq(sim.sides[2].slots[FS(2)].done, 1, "the build completed")
  ok(Fog.divinedBuilding(sim, 1, FS(2)) > 0, "...and the completed building appears -- 'including rebuilds'")
end

do
  -- Ignoring the front-slot shield: the section rule cannot show a back slot
  -- behind an intact front slot even to a body in section 7 (test 5); the scry
  -- ignores the wall entirely.
  local sim = newSim(53, lo(CARD_DIV), nil)
  build(sim, 2, "palisade", FS(3))
  build(sim, 2, "granary", BS(3))
  ok(Fog.divinedBuilding(sim, 1, BS(3)) > 0, "the scry pierces the front-slot shield")
  place(sim, 1, 3, 1700)
  repin()
  eq(Fog.seesEnemyBuilding(sim, 1, BS(3)), false, "...which full sight, standing right there, cannot")
end

do
  -- NEVER HP, structurally: the live predicate returns one integer (identity),
  -- the scry layer of the memory store holds identity and tick and NOTHING
  -- else, and the composed belief carries hp 0 for a building known only
  -- through the scry.
  local sim = newSim(51, lo(CARD_DIV), nil)
  local pal = build(sim, 2, "palisade", FS(1))
  pal.hp = 123                      -- something a leak would show
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  local b, hp, mhp, done, occ = Fog.believedBuilding(mem, FS(1))
  eq(b, pal.b, "the scried identity reaches the belief")
  eq(hp, 0, "...with NO HP figure, ever")
  eq(mhp, 0, "...and no maxHp either")
  eq(done, 1, "...and done by definition: only completed buildings are scried")
  eq(occ, 1, "...and the slot believed occupied")
  ok(mem.slotScryHp == nil, "there is no field in the scry layer an HP could travel in")

  -- Continuously: a razed wall disappears from the scry on the very next
  -- observation -- the freeze of doc section 4 never shows while the card is
  -- held, because every observation restamps the layer.
  sim.sides[2].slots[FS(1)] = false
  Fog.observe(mem, sim, 1)
  local b2, _, _, _, occ2 = Fog.believedBuilding(mem, FS(1))
  eq(b2, 0, "a razed building is gone from the scry at the next observation")
  eq(occ2, 0, "...and the slot believed empty: this is how a diviner learns a wall fell")
end

do
  -- The self-announcing mark (Q9b: "seeing costs being seen"): the WATCHED side
  -- knows it is being scried, from tick 0, persistently -- and the watcher
  -- carries no mark, and a cardless match carries none anywhere.
  local sim = newSim(52, lo(CARD_DIV), nil)
  local scried, omened, scanned = Fog.marks(sim, 2)
  eq(scried, 1, "the scried side carries the 'you are being scried' mark from tick 0")
  eq(omened, 0, "...and no omen mark: nobody holds Omen")
  eq(scanned, 0, "...and no scan mark: nobody has a Shrine")
  local s2 = Fog.marks(sim, 1)
  eq(s2, 0, "the DIVINER is not marked: the disclosure points at the watched side only")
end

-- ===========================================================================
-- 17. OMEN (doc section 6; D.3 Mystic card 3) -- M3 part 2
--
-- "Enemy deploy orders surfaced as they are issued: lane and count only, never
-- unit type." Temporal, not spatial: a filter over the shared command queue,
-- never new data.
-- ===========================================================================

G("17. Omen surfaces enemy deploy orders as issued -- lane and count, never type")

do
  local sim = newSim(60, lo(CARD_OMEN), nil)
  fund(sim, 2, 1000)
  fund(sim, 1, 1000)
  run(sim, 5)
  local exec = sim.clock + C.ORDER_DELAY
  order(sim, 2, "H", 2, 3, exec)      -- their Horses into lane 2
  order(sim, 2, "S", 2, 12, exec)     -- their Spears, count over the atom cap
  order(sim, 2, "b", FS(1), 1, exec)  -- their BUILD order: not a deploy
  order(sim, 1, "S", 2, 4, exec)      -- MY deploy: not an enemy order
  local nOrders, nUnits = Fog.omenPending(sim, 1, 2)
  eq(nOrders, 2, "two enemy deploy orders surfaced at their issue tick")
  eq(nUnits, 3 + C.MAX_UNITS_PER_ORDER,
    "the count is the count that can take the field: 3 + the atom cap, not 3 + 12")
  eq(select(1, Fog.omenPending(sim, 1, 1)), 0, "nothing surfaced for a lane nothing is bound for")
  eq(select(1, Fog.omenPending(sim, 2, 2)), 0, "the side without the card gets nothing")

  -- The window closes when the order executes: what lands on the field is the
  -- section rule's problem, and no omen signal outlives its pending order.
  run(sim, C.ORDER_DELAY + 1)
  local o2, u2 = Fog.omenPending(sim, 1, 2)
  eq(o2, 0, "the signal is gone once the order executes")
  eq(u2, 0, "...units included")
end

do
  -- NEVER UNIT TYPE, proved by indistinguishability rather than by inspection:
  -- two pending waves that differ ONLY in unit type produce bit-identical omen
  -- signals. If any field carried the type, these two would differ somewhere.
  local function signal(kind)
    local sim = newSim(61, lo(CARD_OMEN), nil)
    fund(sim, 2, 1000)
    run(sim, 3)
    order(sim, 2, kind, 3, 5, sim.clock + C.ORDER_DELAY)
    local o, u = Fog.omenPending(sim, 1, 3)
    return o * 1000 + u
  end
  eq(signal("H"), signal("B"), "five Horses and five Bows read identically")
  eq(signal("S"), signal("H"), "...and five Spears too: lane and count only")
end

do
  -- A FILTER OVER THE SHARED QUEUE, NOT NEW DATA. pendingDeploys is the raw
  -- filter and the card only gates it: with the card the two agree exactly, and
  -- under the FULL regime the same channel is filled with no card at all --
  -- the queue is on every client under Ruling 1, so the upper bound must stay a
  -- strict superset of anything a card can buy (the muster-bar lesson).
  local sim = newSim(62, lo(CARD_OMEN), nil)
  fund(sim, 2, 1000)
  run(sim, 4)
  order(sim, 2, "S", 1, 6, sim.clock + C.ORDER_DELAY)
  local ro, ru = Fog.pendingDeploys(sim, 1, 1)
  local co, cu = Fog.omenPending(sim, 1, 1)
  eq(co, ro, "the carded signal IS the raw filter, order for order")
  eq(cu, ru, "...and unit for unit: the card adds no data, it unlocks a filter")

  Policy.setVision(Policy.VISION_FULL)
  local v = Policy.newView(Rules)
  Policy.fillView(v, sim, 2, nil, nil)      -- side 2 has NO card
  eq(v.foe.lanes[1].omenN, 0, "side 2 has issued nothing, so its foe channel is empty")
  Policy.fillView(v, sim, 1, nil, nil)
  eq(v.foe.lanes[1].omenN, ro, "under full information the channel fills with no card")
  eq(v.foe.lanes[1].omen, ru, "...because the pending queue is on every client anyway")

  Policy.setVision(Policy.VISION_FOG)
  local mem = Fog.newMemory(Rules)
  local v2 = Policy.newView(Rules)
  Policy.fillView(v2, sim, 1, nil, mem)
  eq(v2.foe.lanes[1].omen, ru, "under fog the carded side gets the same number")
  local mem2 = Fog.newMemory(Rules)
  Policy.fillView(v2, sim, 2, nil, mem2)
  eq(v2.foe.lanes[1].omen, 0, "...and the cardless side gets zero through the same view")
end

do
  -- THE WINDOW IS "ONE ORDER-DELAY BEFORE IT TAKES THE FIELD", derived from the
  -- exec tick. An atom issued at the minimum delay surfaces from its issue tick
  -- (the M2 driver's case, exact); one issued with a LONGER delay surfaces from
  -- exec - ORDER_DELAY, later than its true issue tick -- the under-estimate,
  -- stated in fog/Fog.lua's own caveats and pinned here so it cannot drift into
  -- an over-estimate.
  local sim = newSim(63, lo(CARD_OMEN), nil)
  fund(sim, 2, 1000)
  run(sim, 2)
  local issue = sim.clock
  order(sim, 2, "S", 2, 2, issue + C.ORDER_DELAY_CLAMP)   -- slowest legal exec
  eq(select(1, Fog.omenPending(sim, 1, 2)), 0,
    "an atom with a padded delay is NOT surfaced at its issue tick")
  run(sim, C.ORDER_DELAY_CLAMP - C.ORDER_DELAY)
  eq(select(1, Fog.omenPending(sim, 1, 2)), 1,
    "...and surfaces exactly one order-delay before it takes the field")

  -- NO OMEN MEMORY. A stale wave warning is a ghosted stack wearing a bell
  -- (doc section 4), so there is no omen field in the memory store at all.
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  local omenish = {}
  for k, _ in pairs(mem) do
    local lk = k:lower()
    if lk:find("omen") or lk:find("pending") or lk:find("order") then
      omenish[#omenish + 1] = k
    end
  end
  eq(#omenish, 0, "no field in the memory store could hold an omen signal")

  -- The mark, from the watched chair.
  local scried, omened = Fog.marks(sim, 2)
  eq(omened, 1, "the watched side knows its orders are being read")
  eq(scried, 0, "...and is not scried: the marks are per card")
end

-- ===========================================================================
-- 18. VEIL (doc section 6; D.3 Mystic card 4) -- M3 part 2
--
-- THE PRECEDENCE RULE, as implemented and pinned: VEIL BEATS EVERY ROUTE THAT
-- DOES NOT PUT A BODY THERE -- Divination's scry, the Shrine pulse's occupancy
-- scan, and the Watchtower's remote section light -- and LOSES to physical
-- presence: a unit of yours standing in the section, and contact (D.3: "every
-- source except contact reveal and destruction"). Veil conceals BUILDINGS
-- ONLY, never units, and is the one information card with no mark.
-- ===========================================================================

G("18. Veil: remote scrying is beaten absolutely, a body there is not")

do
  -- Route 1, Divination: the empty scry. The diviner gets 0 for every slot of a
  -- veiled enemy, live and in memory -- and the memory layer is NOT stamped, so
  -- knowledge earned through routes Veil cannot beat is never overwritten by a
  -- lying refresh.
  local sim = newSim(70, lo(CARD_DIV), lo(CARD_VEIL))
  local pal = build(sim, 2, "palisade", FS(1))
  eq(Fog.divinedBuilding(sim, 1, FS(1)), 0, "a diviner facing Veil gets an empty scry")
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  eq(mem.slotScryTick[FS(1)], Fog.NEVER_SEEN,
    "the scry layer is not stamped at all: suppression is absence, not a recorded zero")

  -- Route 2, the body. A unit of mine standing in the section sees the veiled
  -- wall -- the doc's own base model (sections 2-3) is not a "disclosure route
  -- above" and D.3's sentence predates the section model; fog/Fog.lua argues
  -- the reading and the README escalates it.
  local u = place(sim, 1, 1, 1300)
  repin()
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), true, "a body in the section sees a veiled building")
  Fog.observe(mem, sim, 1)
  local rb, rhp = Fog.rememberedBuilding(mem, FS(1))
  eq(rb, pal.b, "...and it enters FULL memory, HP included")
  eq(rhp, pal.hp, "...at the HP the body can see")

  -- ...and once earned, the empty scry cannot erase it: the observation after
  -- the body leaves keeps the body-earned record.
  u.pos = 100
  Fog.observe(mem, sim, 1)
  local rb2, rhp2 = Fog.rememberedBuilding(mem, FS(1))
  eq(rb2, pal.b, "the frozen record survives the empty scry")
  eq(rhp2, rhp, "...HP included: a veiled scry never fabricates an observation")
  local bb = Fog.believedBuilding(mem, FS(1))
  eq(bb, pal.b, "...and the composed belief still draws the wall a body once touched")
end

do
  -- Route 3, contact: grinding a veiled wall shows the wall (D.3's explicit
  -- exception). The attacker is in section 5, the wall in section 6, nothing
  -- lit -- the contact route alone carries it, straight through Veil.
  local sim = newSim(71, nil, lo(CARD_VEIL))
  build(sim, 2, "palisade", FS(1))
  local u = deploy(sim, 1, 1, "S")
  run(sim, 200)
  eq(u.pos, Fog.OBS_ENEMY_FRONT - Rules.UNITS[1].range, "the Spear is parked at the veiled wall")
  eq(vis(sim, 1, 1)[6], 0, "its section is not lit")
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), true, "contact reveal beats Veil")
  u.pos = u.pos - 1
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), false, "...by exactly the weapon envelope, as ever")
end

do
  -- Route 4, the Watchtower: REMOTE light loses to Veil. The same board with
  -- and without the card, so the check is the difference and nothing else.
  local function towerSees(veiled)
    local sim = newSim(72, nil, veiled and lo(CARD_VEIL) or nil)
    build(sim, 2, "palisade", FS(1))
    build(sim, 1, "watchtower", FS(1))
    local lit = vis(sim, 1, 1)[6] == 1
    return lit, Fog.seesEnemyBuilding(sim, 1, FS(1))
  end
  local litV, seesV = towerSees(true)
  local litN, seesN = towerSees(false)
  eq(litV, true, "the tower lights section 6 either way -- Veil hides buildings, not ground")
  eq(litN, true, "...")
  eq(seesN, true, "an unveiled wall shows in the tower-lit section")
  eq(seesV, false, "a veiled one does NOT: remote light is not a body")

  -- ...and a body in the tower-lit section still wins, so the two routes into
  -- one lit section are genuinely distinguished.
  local sim = newSim(73, nil, lo(CARD_VEIL))
  build(sim, 2, "palisade", FS(1))
  build(sim, 1, "watchtower", FS(1))
  place(sim, 1, 1, 1300)
  repin()
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), true,
    "a body standing in the same section shows the veiled wall the tower could not")
end

do
  -- Route 5, the Shrine pulse: the scan comes back with NOTHING against Veil --
  -- the occ layer is never stamped, so a body-earned record is not erased and
  -- no fabricated "empty" appears.
  local sim = newSim(74, nil, lo(CARD_VEIL))
  build(sim, 2, "palisade", FS(2))
  build(sim, 1, "shrine", BS(1))
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  eq(Fog.shrinePulseActive(sim, 1), true, "my pulse is live")
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  eq(mem.slotOccTick[FS(2)], Fog.NEVER_SEEN, "the occupancy scan is not stamped against Veil")
  local _, _, _, _, occ = Fog.believedBuilding(mem, FS(2))
  eq(occ, 0, "...so the veiled slot stays believed empty, not scanned-empty")

  -- VEIL CONCEALS BUILDINGS ONLY: their units are pulse-revealed exactly as an
  -- unveiled side's are (the doc: "it never conceals units"). place() advances
  -- the sim 21 ticks, which stays inside the 30-tick window just entered.
  local eu = place(sim, 2, 3, 0)
  repin()
  eu.pos = 100
  ok(sim.clock % C.SHRINE_PULSE_EVERY < C.SHRINE_PULSE_TICKS, "still inside the window")
  eq(Fog.seesEnemyUnit(sim, 1, eu), true, "a veiled side's units are revealed by the pulse anyway")

  -- ...and the plain section rule never consults Veil for units either: window
  -- over, a body of mine lights section 5, their unit stands in it.
  while sim.clock % C.SHRINE_PULSE_EVERY < C.SHRINE_PULSE_TICKS do sim:tick() end
  place(sim, 1, 3, 1100)
  repin()
  eu.pos = 900                                -- their 900 = my 1100, my section 5
  eq(Fog.shrinePulseActive(sim, 1), false, "the pulse is over")
  eq(Fog.seesEnemyUnit(sim, 1, eu), true, "...nor does the section rule: Veil is about buildings")
end

do
  -- NO MARK. Veil is the sole non-announcing source (Q9b), so the veiled side's
  -- opponent learns nothing from the marks -- inference through an empty scry is
  -- the only route, and that is the design.
  local sim = newSim(75, lo(CARD_DIV, CARD_OMEN), lo(CARD_VEIL))
  local scried, omened, scanned = Fog.marks(sim, 1)
  eq(scried, 0, "the diviner is not told it is scried (it is not)")
  eq(omened, 0, "...nor omened")
  eq(scanned, 0, "...nor scanned: Veil announces nothing, in either direction")
  ok(Fog.CARD_VEIL > 0, "and the card is real, so those zeros are the rule and not a stub")
end

-- ===========================================================================
-- 19. THE SHRINE'S REVEAL PULSE (doc section 6; Q9b; D.2's hashed constants)
--
-- "While a completed Shrine stands, every SHRINE_PULSE_EVERY ticks for
-- SHRINE_PULSE_TICKS: all enemy units in all lanes at full detail, plus enemy
-- building OCCUPANCY only -- not identity, not HP."
-- ===========================================================================

G("19. the Shrine pulse: every unit everywhere, buildings as occupancy only")

do
  -- The schedule is the hashed constants, anchored at tick 0, and nothing else:
  -- live at t iff t mod EVERY < TICKS. Swept over two full periods.
  local sim = newSim(80)
  build(sim, 1, "shrine", BS(1))
  local base = floor(sim.clock / C.SHRINE_PULSE_EVERY) * C.SHRINE_PULSE_EVERY
    + C.SHRINE_PULSE_EVERY
  while sim.clock < base do sim:tick() end
  local mismatches = 0
  for t = base, base + 2 * C.SHRINE_PULSE_EVERY - 1 do
    local want = (t % C.SHRINE_PULSE_EVERY) < C.SHRINE_PULSE_TICKS
    if Fog.shrinePulseActive(sim, 1) ~= want then mismatches = mismatches + 1 end
    sim:tick()
  end
  eq(mismatches, 0, format("the window is [0, %d) mod %d, swept tick by tick over two periods",
    C.SHRINE_PULSE_TICKS, C.SHRINE_PULSE_EVERY))
  eq(Fog.shrinePulseActive(sim, 2), false, "the shrineless side never pulses")
end

do
  -- ALL enemy units, ALL lanes, at full detail -- and the negation one tick
  -- after the window shuts.
  local sim = newSim(81)
  build(sim, 1, "shrine", BS(2))
  local eus = {}
  for lane = 1, C.LANES do
    eus[lane] = place(sim, 2, lane, 100 + lane)   -- deep in their own half
  end
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  repin()
  for lane = 1, C.LANES do
    eq(Fog.seesEnemyUnit(sim, 1, eus[lane]), true,
      format("their unit deep in lane %d is revealed by the pulse", lane))
  end
  while sim.clock % C.SHRINE_PULSE_EVERY < C.SHRINE_PULSE_TICKS do sim:tick() end
  repin()
  for lane = 1, C.LANES do
    eq(Fog.seesEnemyUnit(sim, 1, eus[lane]), false,
      format("...and vanishes the tick the window shuts (lane %d)", lane))
  end
end

do
  -- OCCUPANCY ONLY. A pulse over an enemy board with a completed building, a
  -- scaffolding and an empty slot: the first two scan as OCCUPIED -- occupancy
  -- is a fact about the SLOT, and scaffolding occupies it -- with no identity
  -- and no HP; the third as empty.
  local sim = newSim(82)
  build(sim, 1, "shrine", BS(3))
  build(sim, 2, "granary", BS(1))
  fund(sim, 2, 1000)
  order(sim, 2, "c", FS(2), 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + 3)
  ok(sim.sides[2].slots[FS(2)] ~= nil and sim.sides[2].slots[FS(2)].done == 0,
    "their lane-2 front slot holds scaffolding")
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  ok(sim.sides[2].slots[FS(2)] ~= nil and sim.sides[2].slots[FS(2)].done == 0,
    "...still under construction on the pulse tick")
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  local b, hp, mhp, done, occ = Fog.believedBuilding(mem, BS(1))
  eq(occ, 1, "a completed building scans as occupied")
  eq(b, 0, "...with NO identity")
  eq(hp, 0, "...and no HP")
  eq(done, 0, "...and no completion flag: occupancy is all the scan carries")
  local b2, _, _, _, occ2 = Fog.believedBuilding(mem, FS(2))
  eq(occ2, 1, "scaffolding scans as occupied too -- it occupies the slot")
  eq(b2, 0, "...identity-free like everything the pulse touches")
  local _, _, _, _, occ3 = Fog.believedBuilding(mem, FS(1))
  eq(occ3, 0, "an empty slot scans as empty")
  ok(mem.slotOccTick[BS(1)] >= 0, "the scan really was stamped, so those zeros are the rule")

  -- The scan FREEZES until the next pulse: raze the Granary between windows and
  -- the belief keeps its occupied ping until a new scan says otherwise.
  while sim.clock % C.SHRINE_PULSE_EVERY < C.SHRINE_PULSE_TICKS do sim:tick() end
  sim.sides[2].slots[BS(1)] = false
  Fog.observe(mem, sim, 1)
  local _, _, _, _, occ4 = Fog.believedBuilding(mem, BS(1))
  eq(occ4, 1, "between pulses the occupancy ping is frozen, doc section 4's rule verbatim")
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  Fog.observe(mem, sim, 1)
  local _, _, _, _, occ5 = Fog.believedBuilding(mem, BS(1))
  eq(occ5, 0, "...and the next pulse's scan updates it")
end

do
  -- THE PULSE DOES NOT LIGHT SECTIONS AND DOES NOT MARK GROUND EXPLORED. It
  -- shows units (not remembered, doc section 4) and occupancy (its own layer);
  -- a section-model `seen` that ticked up during a pulse would claim knowledge
  -- -- building identity, HP -- that the pulse never disclosed. Same argument as
  -- contact being entity-scoped, and pinned the same way.
  local sim = newSim(83)
  build(sim, 1, "shrine", BS(1))
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  eq(Fog.shrinePulseActive(sim, 1), true, "the pulse is live")
  local v = vis(sim, 1, 2)
  for s = 5, 8 do
    eq(v[s], 0, format("section %d stays dark during the pulse", s))
  end
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  for s = 5, 8 do
    eq(Fog.sectionSeen(mem, 2, s), false,
      format("...and section %d is not marked explored by it", s))
  end
  -- The keep is not a building: the pulse never touches its remembered HP.
  sim.sides[2].keepHp = 777
  Fog.observe(mem, sim, 1)
  eq(Fog.rememberedKeepHp(mem), C.KEEP_HP, "the pulse does not read the enemy keep's HP")
end

do
  -- SELF-ANNOUNCING ("you were scanned"), live during the window, gone after,
  -- and the policy view carries both halves: the watched side's mark and the
  -- scanning side's own scan flag.
  Policy.setVision(Policy.VISION_FOG)
  local sim = newSim(84)
  build(sim, 1, "shrine", BS(2))
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  local _, _, scanned = Fog.marks(sim, 2)
  eq(scanned, 1, "the scanned side is told, while it is happening")
  local memA, memB = Fog.newMemory(Rules), Fog.newMemory(Rules)
  local v = Policy.newView(Rules)
  Policy.fillView(v, sim, 2, nil, memB)
  eq(v.me.scanned, 1, "...and its view says so")
  eq(v.foe.scan, 0, "its own pulse flag is 0: it has no Shrine")
  Policy.fillView(v, sim, 1, nil, memA)
  eq(v.me.scanned, 0, "the scanning side is not scanned")
  eq(v.foe.scan, 1, "...and its view knows its own pulse is rendering their board")
  run(sim, C.SHRINE_PULSE_TICKS)
  local _, _, after = Fog.marks(sim, 2)
  eq(after, 0, "the mark ends with the window")
end

-- ===========================================================================
-- 20. THE THREE MEMORY LAYERS COMPOSE, AND NO LAYER PROMOTES ANOTHER
--
-- Full sight (slot, identity, HP), Divination's scry (identity only), the
-- pulse's scan (occupancy only). The rule, written once in
-- Fog.believedBuilding: the freshest layer wins; a tie goes to the layer that
-- knows more; an empty scry never beats a same-tick occupancy scan.
-- ===========================================================================

G("20. memory: full sight, the scry and the scan compose without promotion")

do
  local sim = newSim(90, lo(CARD_DIV), nil)
  local pal = build(sim, 2, "palisade", FS(1))
  local full = pal.hp

  -- A body at the wall: full record and scry stamped the same tick; the full
  -- record wins the tie and the belief carries HP.
  local mem = Fog.newMemory(Rules)
  local u = place(sim, 1, 1, 1300)
  repin()
  Fog.observe(mem, sim, 1)
  local b, hp = Fog.believedBuilding(mem, FS(1))
  eq(b, pal.b, "tie at one tick: the full record wins")
  eq(hp, full, "...so the belief carries the HP only full sight knows")

  -- The body leaves (killed the way the sim kills, so the walks below run over
  -- an empty lane); the wall is damaged; the scry stays fresher than the frozen
  -- record and agrees about identity: live identity over STALE HP -- the screen
  -- keeps its old HP bar under a fresh nameplate.
  local us = sim.sides[1].lanes[1].units
  for i = #us, 1, -1 do us[i] = nil end
  pinned = {}
  run(sim, 1)
  pal.hp = 200
  Fog.observe(mem, sim, 1)
  local b2, hp2, _, done2, occ2 = Fog.believedBuilding(mem, FS(1))
  eq(b2, pal.b, "a fresher scry that agrees keeps the identity live")
  eq(hp2, full, "...over the FROZEN HP, not the live 200: the scry never carries HP")
  eq(done2, 1, "...done, by scry definition")
  eq(occ2, 1, "...occupied")

  -- They raze it and complete something else while nothing of mine is there:
  -- the scry alone reports the NEW identity, with no HP at all -- the building
  -- the record knew is gone and its HP died with it.
  sim.sides[2].slots[FS(1)] = false
  fund(sim, 2, 1000)
  local at = Policy.BLD_INDEX.arrowTower
  order(sim, 2, Rules.BUILDINGS[at].letter, FS(1), 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + Rules.BUILDINGS[at].build + 5)
  eq(sim.sides[2].slots[FS(1)].done, 1, "an Arrow Tower now stands where the Palisade was")
  Fog.observe(mem, sim, 1)
  local b3, hp3 = Fog.believedBuilding(mem, FS(1))
  eq(b3, at, "the scry reports the rebuild's identity")
  eq(hp3, 0, "...with no HP: the stale record's HP belonged to a different building")
end

do
  -- The scan under a remembered wall, and the scan over one. A pulse ping
  -- CONFIRMS occupancy but names nothing, so a remembered identity fills it in;
  -- a pulse ping of EMPTY out-votes a stale record however confident.
  local sim = newSim(91)
  build(sim, 1, "shrine", BS(1))
  local pal = build(sim, 2, "palisade", FS(2))
  local mem = Fog.newMemory(Rules)
  local u = place(sim, 1, 2, 1300)
  repin()
  Fog.observe(mem, sim, 1)                       -- full record of the wall
  local frozenHp = pal.hp
  ok(u ~= nil, "the recording body existed")
  local us = sim.sides[1].lanes[2].units         -- ...and dies, so the walks below
  for i = #us, 1, -1 do us[i] = nil end          -- run over an empty lane
  pinned = {}
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  Fog.observe(mem, sim, 1)                       -- pulse: ping over the same wall
  local b, hp, _, _, occ, tick = Fog.believedBuilding(mem, FS(2))
  eq(b, pal.b, "a scan ping under a remembered palisade draws the palisade")
  eq(hp, frozenHp, "...with the frozen HP the record holds")
  eq(occ, 1, "...occupied, which is what the ping added")
  eq(tick, mem.slotOccTick[FS(2)], "...at the scan's freshness")

  -- Now raze it while unobserved and let the NEXT pulse scan the empty slot.
  sim.sides[2].slots[FS(2)] = false
  while sim.clock % C.SHRINE_PULSE_EVERY < C.SHRINE_PULSE_TICKS do sim:tick() end
  Fog.observe(mem, sim, 1)                       -- between windows: frozen
  local bF = Fog.believedBuilding(mem, FS(2))
  eq(bF, pal.b, "between pulses the razed wall still shows -- memory, doc section 4")
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  Fog.observe(mem, sim, 1)                       -- pulse: ping of EMPTY
  local b2, hp2, _, done2, occ2 = Fog.believedBuilding(mem, FS(2))
  eq(occ2, 0, "a fresher scan of EMPTY out-votes the stale record")
  eq(b2, 0, "...identity gone from the screen")
  eq(hp2, 0, "...HP gone with it")
  eq(done2, 0, "...everything gone: the slot is drawn empty")
  ok(mem.slotB[FS(2)] == pal.b, "while the FULL layer itself still holds the frozen record underneath")
end

do
  -- THE STATED TIE EXCEPTION: an empty scry never beats a same-tick occupancy
  -- scan, because "nothing completed stands there" does not contradict
  -- "something stands there" -- scaffolding satisfies both, and the scan saw it.
  local sim = newSim(92, lo(CARD_DIV), nil)
  build(sim, 1, "shrine", BS(1))
  -- Time the build so the scaffolding is still scaffolding on the pulse tick:
  -- start it 50 ticks before the window opens (a Palisade builds for 90).
  while sim.clock % C.SHRINE_PULSE_EVERY ~= C.SHRINE_PULSE_EVERY - 50 do sim:tick() end
  fund(sim, 2, 1000)
  order(sim, 2, "c", FS(3), 1, sim.clock + C.ORDER_DELAY)
  run(sim, C.ORDER_DELAY + 3)
  ok(sim.sides[2].slots[FS(3)] ~= nil and sim.sides[2].slots[FS(3)].done == 0,
    "their lane-3 front slot holds scaffolding")
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  ok(sim.sides[2].slots[FS(3)] ~= nil and sim.sides[2].slots[FS(3)].done == 0,
    "...still scaffolding on the pulse tick")
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)                       -- scry says empty, scan says occupied, one tick
  eq(mem.slotScryTick[FS(3)], mem.slotOccTick[FS(3)], "both layers stamped on one observation")
  local b, _, _, _, occ = Fog.believedBuilding(mem, FS(3))
  eq(occ, 1, "the same-tick scan wins over the empty scry: the slot is known occupied")
  eq(b, 0, "...with no identity, which is the razed-vs-scaffolding tension Divination preserves")

  -- ...but an empty scry FRESHER than the last scan draws empty (rule 4, the
  -- under-estimate): the pulse window closes, the scaffolding is razed, and the
  -- still-running scry reports nothing there.
  while sim.clock % C.SHRINE_PULSE_EVERY < C.SHRINE_PULSE_TICKS do sim:tick() end
  sim.sides[2].slots[FS(3)] = false
  Fog.observe(mem, sim, 1)
  local b2, _, _, _, occ2 = Fog.believedBuilding(mem, FS(3))
  eq(occ2, 0, "a fresher empty scry draws the slot empty over the older ping")
  eq(b2, 0, "...the diviner's under-estimate, exactly as documented")
end

do
  -- NO PROMOTION, asserted at the layer level across one whole story: nothing a
  -- scry or a scan writes ever reaches the FULL record's fields.
  local sim = newSim(93, lo(CARD_DIV), nil)
  build(sim, 1, "shrine", BS(1))
  build(sim, 2, "granary", BS(2))
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)                       -- scry sees the Granary
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  Fog.observe(mem, sim, 1)                       -- scan pings it
  eq(mem.slotB[BS(2)], 0, "the FULL record never learned an identity from either layer")
  eq(mem.slotHp[BS(2)], 0, "...nor an HP")
  eq(mem.slotSeen[BS(2)], 0, "...nor a sighting")
  eq(mem.slotTick[BS(2)], Fog.NEVER_SEEN, "...nor a tick: partial sight is never promoted")
  ok(mem.slotScryB[BS(2)] > 0, "while the scry layer holds the identity")
  eq(mem.slotOcc[BS(2)], 1, "...and the scan layer holds the ping, each in its own lane")
end

-- ===========================================================================
-- 21. THE FOUR EFFECTS AND THE WATCHTOWER COMPOSE, SYMMETRICALLY,
--     AND CARDED MEMORY IS STILL A DETERMINISTIC FOLD OUTSIDE THE HASH
-- ===========================================================================

G("21. composition: tower + cards, both seats, and the carded memory replays")

do
  -- Watchtower + Divination against an unveiled enemy: the tower's sections
  -- show the front slot at full fidelity (HP and all), the scry adds the back
  -- slot the shield hides from everything else. Each route contributes exactly
  -- its own grade of sight.
  local sim = newSim(100, lo(CARD_DIV), nil)
  build(sim, 1, "watchtower", FS(1))
  local pal = build(sim, 2, "palisade", FS(1))
  local gra = build(sim, 2, "granary", BS(1))
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  eq(Fog.seesEnemyBuilding(sim, 1, FS(1)), true, "the tower-lit section shows their wall")
  eq(Fog.seesEnemyBuilding(sim, 1, BS(1)), false, "the shield still hides the back slot from SIGHT")
  local bF, hpF = Fog.believedBuilding(mem, FS(1))
  eq(bF, pal.b, "front: full fidelity through the tower's section")
  eq(hpF, pal.hp, "...HP included")
  local bB, hpB = Fog.believedBuilding(mem, BS(1))
  eq(bB, gra.b, "back: identity through the scry, past the shield")
  eq(hpB, 0, "...and no HP, because only the scry has been there")
end

do
  -- Watchtower + Omen are independent axes: the tower changes nothing about the
  -- temporal channel, the card changes nothing about the sections. The orders
  -- go into lane 3 so the horses they field never meet the lane-1 tower.
  local sim = newSim(101, lo(CARD_OMEN), nil)
  fund(sim, 2, 1000)
  run(sim, 3)
  order(sim, 2, "H", 3, 4, sim.clock + C.ORDER_DELAY)
  local o1, u1 = Fog.omenPending(sim, 1, 3)
  build(sim, 1, "watchtower", FS(1))
  fund(sim, 2, 1000)
  order(sim, 2, "H", 3, 4, sim.clock + C.ORDER_DELAY)
  local o2, u2 = Fog.omenPending(sim, 1, 3)
  eq(o1, 1, "one order pending before the tower")
  eq(o2, 1, "...and one after: the tower does not touch the omen channel")
  eq(u1, u2, "...unit for unit")
  eq(vis(sim, 1, 1)[5], 1, "the tower lights its sections regardless of the card")
end

do
  -- All four at once, from both seats, and A.2 exactly: the same physical board
  -- seated the other way round answers identically, and the two memories hash
  -- identically. Side 1 holds Divination + Omen and a Shrine; side 2 holds Veil
  -- and a Watchtower.
  local function boardHash(sim, side)
    local mem = Fog.newMemory(Rules)
    Fog.observe(mem, sim, side)
    return Fog.memHash(mem)
  end
  local function makeBoard(flip)
    local a, b = flip and 2 or 1, flip and 1 or 2
    local sim = newSim(102,
      flip and lo(CARD_VEIL) or lo(CARD_DIV, CARD_OMEN),
      flip and lo(CARD_DIV, CARD_OMEN) or lo(CARD_VEIL))
    -- built in a FIXED physical order so the two boards are the same match
    build(sim, a, "shrine", BS(1))
    build(sim, a, "watchtower", FS(2))          -- the diviner also owns a tower
    build(sim, b, "palisade", FS(1))
    build(sim, b, "granary", BS(1))
    while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
    fund(sim, b, 1000)
    order(sim, b, "H", 2, 3, sim.clock + C.ORDER_DELAY)   -- pending at check time
    return sim, a, b
  end
  local s1, a1, b1 = makeBoard(false)
  local s2, a2, b2 = makeBoard(true)
  eq(Fog.shrinePulseActive(s1, a1), Fog.shrinePulseActive(s2, a2), "the pulse reads the same from either seat")
  eq(Fog.divinedBuilding(s1, a1, FS(1)), Fog.divinedBuilding(s2, a2, FS(1)),
    "the scry reads the same from either seat (and it is empty: Veil)")
  eq(Fog.divinedBuilding(s1, a1, FS(1)), 0, "...empty, to be exact")
  local o1, u1 = Fog.omenPending(s1, a1, 2)
  local o2, u2 = Fog.omenPending(s2, a2, 2)
  eq(o1, o2, "the omen channel reads the same from either seat")
  eq(u1, u2, "...unit for unit")
  ok(o1 == 1 and u1 == 3, "...and it is carrying the real pending wave")
  eq(boardHash(s1, a1), boardHash(s2, a2), "the diviner's memory hashes identically from either seat")
  eq(boardHash(s1, b1), boardHash(s2, b2), "...and so does the veiled side's")
end

do
  -- CARDED MEMORY IS STILL A DETERMINISTIC FOLD AND STILL OUTSIDE stateHash.
  -- The section-11 property, re-proved with all four effects live: two replays
  -- of a carded match produce bit-identical memories for both sides, a
  -- different log produces different ones, and mutating every NEW layer of a
  -- store moves no stateHash.
  local function playAndFold(kind)
    local sim = newSim(4243, lo(CARD_DIV, CARD_OMEN), lo(CARD_VEIL))
    local m = { Fog.newMemory(Rules), Fog.newMemory(Rules) }
    local s = 0
    -- One shrine each, so both memories carry occupancy scans.
    fund(sim, 1, 1000); fund(sim, 2, 1000)
    s = s + 1; sim:queueCommand({ side = 1, seq = s, tick = C.ORDER_DELAY,
      kind = Rules.BUILDINGS[Policy.BLD_INDEX.shrine].letter, target = BS(1), count = 1 })
    s = s + 1; sim:queueCommand({ side = 2, seq = s, tick = C.ORDER_DELAY,
      kind = Rules.BUILDINGS[Policy.BLD_INDEX.shrine].letter, target = BS(2), count = 1 })
    for tick = 0, 900 do
      if tick % 60 == 0 then
        for side = 1, 2 do
          fund(sim, side, 500)
          s = s + 1
          sim:queueCommand({ side = side, seq = s, tick = tick + C.ORDER_DELAY,
            kind = (side == 1) and kind or "S", target = (tick % 3) + 1, count = 2 })
        end
      end
      if not sim:tick() then break end
      Fog.observe(m[1], sim, 1)
      Fog.observe(m[2], sim, 2)
    end
    return Fog.memHash(m[1]), Fog.memHash(m[2]), sim:stateHash(), m
  end
  local a1, a2, sh1 = playAndFold("H")
  local b1, b2, sh2 = playAndFold("H")
  eq(sh1, sh2, "the two carded replays are the same match")
  eq(a1, b1, "the diviner's memory replays bit-identically, scry and scan included")
  eq(a2, b2, "...and the veiled side's")
  local c1, c2, sh3 = playAndFold("B")
  ok(sh3 ~= sh1, "a different log is a different match")
  ok(c1 ~= a1 or c2 ~= a2, "...and a different memory, so the digest is not constant")

  local sim = newSim(103, lo(CARD_DIV), nil)
  build(sim, 1, "shrine", BS(1))
  while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
  local before = sim:stateHash()
  local mem = Fog.newMemory(Rules)
  Fog.observe(mem, sim, 1)
  mem.slotScryB[1] = 9
  mem.slotScryTick[1] = 5
  mem.slotOcc[2] = 1
  mem.slotOccTick[2] = 5
  eq(sim:stateHash(), before, "no mutation of the scry or scan layers moves stateHash")

  -- ...and the new layers are INSIDE memHash, or sweep/determinism.lua could
  -- not catch a divergence in them: each mutation moves the digest.
  local base = Fog.memHash(mem)
  mem.slotScryB[3] = 7
  ok(Fog.memHash(mem) ~= base, "the scry layer is inside memHash")
  local base2 = Fog.memHash(mem)
  mem.slotOccTick[3] = 9
  ok(Fog.memHash(mem) ~= base2, "...and the scan layer too")
end

-- ===========================================================================
-- 22. MUTATION: EACH INFO EFFECT IS LOAD-BEARING
--
-- The proof that sections 16-19 cannot pass vacuously: a copy of fog/Fog.lua
-- with ONE effect surgically disabled is loaded from /tmp (never the tree), and
-- the named check that section proved must now come out the other way. A
-- mutation whose needle no longer matches the source FAILS the suite, so a
-- refactor cannot quietly defuse these.
-- ===========================================================================

G("22. mutation: disable each effect and its named checks flip")

do
  local src
  do
    local f = io.open(here .. "/../fog/Fog.lua", "r")
    ok(f ~= nil, "fog/Fog.lua is readable")
    src = f:read("*a")
    f:close()
  end

  -- Plain-text replace-all with a count; no Lua patterns, so the needles above
  -- cannot be bent by magic characters.
  local function plainReplace(s, from, to)
    local out, n, pos = {}, 0, 1
    while true do
      local i = s:find(from, pos, true)
      if not i then break end
      out[#out + 1] = s:sub(pos, i - 1)
      out[#out + 1] = to
      pos = i + #from
      n = n + 1
    end
    out[#out + 1] = s:sub(pos)
    return table.concat(out), n
  end

  -- Load a mutated module from /tmp. Everything it requires is already in
  -- package.loaded, so the mutant shares the real Rules/Hash/Mods.
  local function loadMutant(mutSrc, label)
    local path = os.tmpname()
    local f = io.open(path, "w")
    ok(f ~= nil, "a /tmp scratch file is writable for " .. label)
    f:write(mutSrc)
    f:close()
    local okLoad, mod = pcall(dofile, path)
    os.remove(path)
    ok(okLoad, label .. " mutant still loads (the mutation must not trip the CHECKS block)")
    return okLoad and mod or nil
  end

  -- DIVINATION OFF: every hasCard gate on the card asks for an id no loadout
  -- can hold.
  do
    local mutSrc, n = plainReplace(src, ", M.CARD_DIVINATION)", ", -1)")
    eq(n, 3, "the Divination gate appears at its three sites (scry, live, mark)")
    local mut = loadMutant(mutSrc, "divination-off")
    if mut then
      local sim = newSim(110, lo(CARD_DIV), nil)
      local pal = build(sim, 2, "palisade", FS(1))
      eq(Fog.divinedBuilding(sim, 1, FS(1)), pal.b, "the real model scries the wall")
      eq(mut.divinedBuilding(sim, 1, FS(1)), 0, "the mutant does not: section 16's check is load-bearing")
      local mem = mut.newMemory(Rules)
      mut.observe(mem, sim, 1)
      eq(mem.slotScryTick[FS(1)], mut.NEVER_SEEN, "...its scry layer never stamps")
      local scried = mut.marks(sim, 2)
      eq(scried, 0, "...and its mark is gone")
    end
  end

  -- OMEN OFF: same shape.
  do
    local mutSrc, n = plainReplace(src, ", M.CARD_OMEN)", ", -1)")
    eq(n, 2, "the Omen gate appears at its two sites (channel, mark)")
    local mut = loadMutant(mutSrc, "omen-off")
    if mut then
      local sim = newSim(111, lo(CARD_OMEN), nil)
      fund(sim, 2, 1000)
      run(sim, 3)
      order(sim, 2, "S", 1, 5, sim.clock + C.ORDER_DELAY)
      eq(select(1, Fog.omenPending(sim, 1, 1)), 1, "the real model surfaces the order")
      eq(select(1, mut.omenPending(sim, 1, 1)), 0, "the mutant does not: section 17 is load-bearing")
      eq(select(1, mut.pendingDeploys(sim, 1, 1)), 1,
        "...while its raw filter still works: the mutation is surgical")
      local _, omened = mut.marks(sim, 2)
      eq(omened, 0, "...and its mark is gone")
    end
  end

  -- VEIL OFF: veiled() answers false for everyone.
  do
    local mutSrc, n = plainReplace(src,
      "return M.hasCard(sim, side, M.CARD_VEIL)", "return false")
    eq(n, 1, "the Veil predicate has exactly one body")
    local mut = loadMutant(mutSrc, "veil-off")
    if mut then
      local sim = newSim(112, lo(CARD_DIV), lo(CARD_VEIL))
      local pal = build(sim, 2, "palisade", FS(1))
      eq(Fog.divinedBuilding(sim, 1, FS(1)), 0, "the real model's scry is blanked by Veil")
      eq(mut.divinedBuilding(sim, 1, FS(1)), pal.b,
        "the mutant scries straight through it: section 18 is load-bearing")
      local mem = mut.newMemory(Rules)
      mut.observe(mem, sim, 1)
      ok(mem.slotScryTick[FS(1)] >= 0, "...its scry layer stamps against a veiled enemy")
    end
  end

  -- PULSE OFF: the window predicate never opens.
  do
    local mutSrc, n = plainReplace(src,
      "if sim.clock % C.SHRINE_PULSE_EVERY >= C.SHRINE_PULSE_TICKS then return false end",
      "if true then return false end")
    eq(n, 1, "the pulse window predicate has exactly one gate")
    local mut = loadMutant(mutSrc, "pulse-off")
    if mut then
      local sim = newSim(113)
      build(sim, 1, "shrine", BS(1))
      local eu = place(sim, 2, 2, 0)
      while sim.clock % C.SHRINE_PULSE_EVERY ~= 0 do sim:tick() end
      repin()
      eu.pos = 100
      eq(Fog.shrinePulseActive(sim, 1), true, "the real model's pulse is live in the window")
      eq(mut.shrinePulseActive(sim, 1), false, "the mutant's never is: section 19 is load-bearing")
      eq(Fog.seesEnemyUnit(sim, 1, eu), true, "the real model reveals the deep unit")
      eq(mut.seesEnemyUnit(sim, 1, eu), false, "...the mutant does not")
      local mem = mut.newMemory(Rules)
      mut.observe(mem, sim, 1)
      eq(mem.slotOccTick[FS(1)], mut.NEVER_SEEN, "...and its scan layer never stamps")
      local _, _, scanned = mut.marks(sim, 2)
      eq(scanned, 0, "...and its mark is gone")
    end
  end

  -- WATCHTOWER OFF, the M1 modifier, held to the same standard: the section-9
  -- and section-18 checks that lean on tower light must flip.
  do
    local mutSrc, n = plainReplace(src,
      "M.GRANTS_VISION[i] = (Rules.BUILDINGS[i].vision > 0) and 1 or 0",
      "M.GRANTS_VISION[i] = 0")
    eq(n, 1, "the vision-grant derivation has exactly one site")
    local mut = loadMutant(mutSrc, "watchtower-off")
    if mut then
      local sim = newSim(114)
      build(sim, 1, "watchtower", FS(1))
      eq(vis(sim, 1, 1)[5], 1, "the real model's tower lights section 5")
      local mv = mut.visibleSections(sim, 1, 1, {})
      eq(mv[5], 0, "the mutant's does not: section 9 is load-bearing")
      eq(mv[6], 0, "...section 6 included")
    end
  end
end

-- ---------------------------------------------------------------------------

print("")
if failures == 0 then
  print(format("FOG: PASS -- %d checks, every rule in IDLE_BATTLE_FOG.md holds", checks))
  os.exit(0)
end
print(format("FOG: FAIL -- %d of %d checks failed", failures, checks))
os.exit(1)
