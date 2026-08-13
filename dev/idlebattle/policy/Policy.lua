-- policy/Policy.lua -- the interface a scripted line implements (M2).
--
-- WHAT A POLICY IS
-- A policy is a scripted hand on the mouse. Given a read-only view of the board
-- and the current tick it returns ZERO OR MORE ORDERS -- exactly the intents a
-- human could click -- and nothing else. It does not move a unit, does not spend
-- a Levy, does not resolve anything and does not decide whether its own order is
-- legal. sweep/driver.lua turns each order into a 6-byte command atom and hands
-- it to Sim:queueCommand with an issueTick, which is the same gate the wire uses
-- in M5. Everything after that happens inside the sim, on both clients.
--
-- THE NO-CHEATING ARGUMENT, which is the entire point of M2. A sweep run by
-- policies that can see or do more than a person is a measurement of nothing.
-- Five structural properties, in the order they matter:
--
--   1 A POLICY HOLDS NO REFERENCE TO THE SIM. The view below is a flat table of
--     INTEGERS, rebuilt by the driver from the sim each poll. There is no sim
--     table, no side table, no unit and no building object anywhere inside it,
--     so there is no path from policy code to sim state at all -- not by
--     accident, not by upvalue, not by a stray write. Anything a policy writes
--     into the view is overwritten at the next poll and read by no one. This is
--     strictly stronger than a read-only proxy, which still hands over a
--     reference and relies on a metatable staying correct.
--   2 EVERY ORDER GOES THROUGH queueCommand WITH issueTick SET. The sim then
--     enforces C.1's order-delay window itself (A.11: exec must sit inside
--     [issue + ORDER_DELAY, issue + ORDER_DELAY_CLAMP]); the driver asks for
--     exactly issue + ORDER_DELAY, the fastest a real client can be. A policy
--     cannot act on what it sees for two full seconds, same as a person.
--   3 AFFORDABILITY, THE SLOT CAP, THE SLOT CLASS, THE LANE SUPPLY CAP, THE
--     COUNT CAP AND CARD GATING ARE NEVER EVALUATED HERE. A.4 puts all of them
--     at the exec tick, inside the sim, and M2 keeps it that way: an order a
--     policy cannot pay for is a fizzle, counted and reported, never a silently
--     granted unit. The driver never pre-pays and never writes to sim state.
--   4 A POLICY CANNOT TELL WHICH SIDE IT IS. The view names its two halves `me`
--     and `foe` and carries no side index, no host flag and no seat number, so
--     the same policy code plays side 1 and side 2 identically (A.2). The driver
--     can swap the seats and the sweep asserts the result mirrors.
--   5 A POLICY IS DETERMINISTIC. Its only randomness is its own sim/Rand.lua
--     stream, seeded from the match seed and its SLOT (not its side), so two
--     runs of the same pairing at the same seed issue byte-identical commands.
--     math.random is unreachable from here and tools/comptest.sh proves it.
--
-- WHAT A POLICY MAY LOOK AT. There are TWO different questions here and M2's
-- first pass answered only the easier one.
--
--   * WHAT THE CLIENT HOLDS. Ruling 1 shares the whole state and fog is a
--     pure RENDER filter, so both clients genuinely hold the enemy's lanes,
--     buildings and bank. Nothing in this view is something a real client could
--     not have, and the view still deliberately carries nothing NO client holds:
--     the enemy's in-flight orders, the contents of a future tick, or the
--     enemy's policy state.
--   * WHAT THE PLAYER SEES. That is ../docs/IDLE_BATTLE_FOG.md, and it is a
--     strictly smaller set: no enemy Levy ever, no enemy building except the one
--     you remember from having stood in its section or from having hit it, and
--     no individual enemy unit until it is in a section you can see or in combat
--     with one of yours -- which without either means not until it has crossed
--     the midline.
--   * AND WHAT THE PLAYER CAN BUY. The set is not fixed. A body standing in a
--     fogged section renders it for as long as it lives, so a line may PAY for
--     perception with the same Levy and the same order budget it fights with.
--     That is the third question and it is the one the roster ignored until the
--     scouting pass: a view filter alone measures a game in which nobody ever
--     chooses to look.
--
-- THE MILESTONE IS A CLAIM ABOUT MATCHES PEOPLE PLAY, so the second question is
-- the one that governs. Until this was fixed every line in the sweep chose its
-- attack lane from the enemy's undisclosed building occupancy and their exact
-- hidden unit supply -- which is what `target = "open"` means for 9 of the 16
-- lines, including the three strongest. See M.VISION below: the regime is now a
-- NAMED, MEASURED parameter with both settings runnable, rather than an unstated
-- default nobody had priced.
--
-- THE FOG MODEL IS NOT WRITTEN HERE. It is fog/Fog.lua, which implements the
-- owner's binding IDLE_BATTLE_FOG.md, and this file is a CONSUMER of it. That
-- separation is deliberate: the renderer (M7) has to apply the same rules, and
-- two implementations of "what can be seen" would be two different games.
--
-- DETERMINISM RULES. This file drives the sim, so it is held to sim/'s rules,
-- and tools/greps.sh + tools/comptest.sh are run over policy/ exactly as they
-- are over sim/: integer arithmetic only, every "/" inside math.floor, no
-- pairs(), no math.random, no clock, no knowledge of which side is local.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Rand = IB_SIM_MODULES and IB_SIM_MODULES.Rand or require("sim.Rand")
local Fog = IB_SIM_MODULES and IB_SIM_MODULES.Fog or require("fog.Fog")

local M = {}

local floor = math.floor
local setmetatable = setmetatable

-- ---------------------------------------------------------------------------
-- the driver's contract with the policy layer
-- ---------------------------------------------------------------------------

-- Ticks between decisions. One second. A policy is asked for orders on ticks
-- that are multiples of this and never in between, which is both a cost saving
-- (the view is built once per second, not ten times) and a fairness rule: no
-- line may react faster than a person watching a 10 Hz board.
M.POLL = 10

-- Orders one side may issue in one poll. Two, so "place a building AND reinforce
-- a lane" is expressible in the same second, and no higher: at 2 per second the
-- worst case is 120 atoms per minute, which the `C` batch carries in ~15
-- messages (8 atoms each) against A.11.4's ~32 messages/min budget. A line that
-- returns more than this has the excess DECLINED by the driver and the count is
-- reported, so a policy cannot quietly out-click the wire.
M.MAX_ORDERS_PER_POLL = 2

-- ...AND THE BOUND IS ASSERTED HERE, NOT ARGUED IN A COMMENT.
--
-- These two constants are the ONLY things that bound what the policy layer asks
-- of the wire, and the sim cannot check them: Sim:queueCommand validates the
-- delay WINDOW per atom, never the atom RATE, so raising the poll rate produces
-- no refusal and every M2 clause -- including the one that exists to prove no
-- order bypassed the input gate -- goes on reporting all-zero while every line
-- in the pool clicks five times faster than a person. It was demonstrated during
-- review that setting POLL = 2 leaves the whole gate green and moves the family
-- spread the milestone turns on. An unasserted fairness rule is not a rule.
--
-- A.11.4's `C` bucket: capacity 4, refill 1 per 4 s, <= 8 atoms per batch =
-- 15 batches/min = 120 atoms/min sustained per side.
M.WIRE_ATOMS_PER_MIN = 120
local TICKS_PER_MIN = floor(60000 / Rules.C.SIM_TICK_MS)          -- 600 at 100 ms
M.CEILING_ATOMS_PER_MIN = floor(M.MAX_ORDERS_PER_POLL * TICKS_PER_MIN / M.POLL)
if M.MAX_ORDERS_PER_POLL * TICKS_PER_MIN > M.WIRE_ATOMS_PER_MIN * M.POLL then
  error("Policy: " .. M.MAX_ORDERS_PER_POLL .. " orders every " .. M.POLL
    .. " ticks is " .. M.CEILING_ATOMS_PER_MIN .. " atoms/min, over A.11.4's "
    .. M.WIRE_ATOMS_PER_MIN .. ". The sweep would measure a hand the wire cannot carry.")
end
-- The human-cadence half of the same rule. A poll faster than once a second lets
-- a line react to a board a person has not finished reading; A.11's order delay
-- bounds when an order LANDS and says nothing about how fresh the board it was
-- chosen from is.
if M.POLL * Rules.C.SIM_TICK_MS < 1000 then
  error("Policy: POLL=" .. M.POLL .. " decides faster than once a second")
end

-- ---------------------------------------------------------------------------
-- THE INFORMATION REGIME
--
-- IDLE_BATTLE_FOG.md is what a PLAYER sees. Ruling 1's full state sharing is
-- what a CLIENT holds. M2's first pass measured 1,440 matches under the second,
-- which is an upper bound on how well anyone can play and is not the thing
-- Part E's milestone is a statement about. Both regimes are kept runnable and
-- both are published, because the difference between them is larger than the
-- margin on two of the milestone's clauses and a number nobody can attribute to
-- a regime is a number nobody can act on.
--
--   "fog"  the owner's fog model, applied to the FOE half of the view only,
--          entirely through fog/Fog.lua:
--            * enemy Levy / bank / income / spend / loadout -> 0. NEVER
--              rendered by any route (fog doc section 7).
--            * enemy unit          -> visible while it stands in a section this
--                                     side can see, OR while one of this side's
--                                     units is in combat with it (doc section
--                                     3a). Sections 1-4 are always visible, so by
--                                     default the first route means "once it has
--                                     crossed the midline", and a section of the
--                                     enemy half is visible only while one of
--                                     this side's own units is inside it.
--                                     UNITS ARE NEVER REMEMBERED.
--            * enemy building      -> whatever this side last SAW in that slot,
--                                     frozen; their back slot is shielded by
--                                     their front slot. Since 3a, "saw" includes
--                                     "was hitting", which is how the wall an
--                                     attacker is grinding gets into memory at
--                                     all.
--            * enemy keep          -> position always; HP as last seen.
--   "full" Ruling 1's shared state, unfiltered. The upper bound, kept so the two
--          columns can be compared in one run of the tooling.
--
-- THE REGIME NAME CHANGED FROM "a3" TO "fog" ON PURPOSE. "a3" named a section of
-- IDLE_BATTLE_DECISIONS.md whose fog model (Q9a's three-bucket muster bar) was
-- an invention of this implementation and has been superseded. A published
-- number carrying the old label would be read as comparable with the pre-fog
-- measurements, and it is not: see the README's M2 section.
--
-- This is a GLOBAL regime, not per match: every line in a sweep must see the
-- board the same way or the win rates are not comparable. Every M2 report prints
-- it in its header so no published number is ever ambiguous about which one it
-- came from.
M.VISION_FOG = "fog"
M.VISION_FULL = "full"
M.VISION = M.VISION_FOG

function M.setVision(mode)
  if mode ~= M.VISION_FOG and mode ~= M.VISION_FULL then
    error("Policy.setVision: unknown regime " .. tostring(mode))
  end
  M.VISION = mode
end

-- ---------------------------------------------------------------------------
-- THE ONE THING A LINE IS ALLOWED TO POINT ITS ATTENTION AT, AND THE ONE WAY IT
-- CAN BUY MORE OF IT
--
-- THE MUSTER BAR IS GONE. The fog doc, section 8.1: "This replaces the muster
-- bar entirely. There is no aggregate signal about the enemy half. Any policy or
-- UI element built on `alarm` / `muster` levels must be rewritten against
-- sections, and the derived 2,800/5,600 HP thresholds are void." So a line has
-- exactly ONE channel about an attack -- a POSITION, reported only for units
-- standing in a section it can see -- and there is no free pre-crossing warning
-- of any kind. That is deliberate in the doc (section 2: "There is no early
-- warning, no aggregate, and no 'something is coming' indicator. That is what
-- makes scouting worth doing").
--
-- AND THE SECOND HALF OF THAT SENTENCE IS THE PART THE ROSTER USED TO IGNORE.
-- The channel is not fixed: it is bought. A body standing in a fogged section
-- renders that section, so where a line's attention CAN point is a function of
-- what it has paid for, and "answer a push before it arrives" is expressible
-- again -- for anyone willing to spend a Spear on it. That is why REACT_MIN
-- below is a floor on the UNPAID case and SCOUT_SIGHT is the floor on the paid
-- one, and why policy/lines.lua's constructor now asks which of the two a line
-- is before it accepts a threshold.
--
-- REACT_MIN IS NOT A STRUCTURAL FLOOR, IT IS A FLOOR ON WHAT YOU HAVE PAID FOR,
-- AND THAT IS THE WHOLE SHAPE OF THE FOG MODEL. Under the muster model an enemy
-- unit was NEVER rendered below the midline, so a `reactAt` down there named a
-- position that could not occur and eleven lines silently collapsed onto one
-- behaviour (Finding 7). Under the section model a threshold in the enemy half
-- IS satisfiable -- for exactly as long as one of your own bodies stands in that
-- section. So there are now two honest kinds of line and policy/lines.lua's
-- constructor enforces the difference:
--
--   * A LINE THAT BUYS NO SIGHT may not name a threshold below REACT_MIN. Its
--     earliest possible warning is the instant something crosses the midline,
--     because that is the first section it can see for free.
--   * A LINE THAT DECLARES A SCOUT may go down to SCOUT_SIGHT, which is the
--     deepest enemy own-frame position the FIRST bought section renders. Below
--     that the threshold needs a body deeper than the midline, which is a
--     different and much more expensive bet.
--
-- Both numbers are derived in fog/Fog.lua from the ruleset's own landmarks, so
-- neither can drift from the section table.
M.MIDLINE = Rules.C.POS_MIDLINE
M.REACT_MIN = Fog.DEFAULT_SIGHT
M.SCOUT_SIGHT = Fog.SCOUT_SIGHT

-- ---------------------------------------------------------------------------
-- SCOUTING, WHICH THE FOG DOC MAKES A REAL PURCHASE AND WHICH THE ROSTER HAD
-- NEVER MADE
--
-- Fog doc section 3: "send one cheap body forward and you buy sight of exactly
-- where it is standing, for exactly as long as it lives... vision is earned and
-- lost continuously through a match rather than being a fixed property of a
-- build." Section 8.4 prices it: "a cheap body spent on sight is a body not
-- spent on pressure."
--
-- Both constants are DERIVED, and that is the point -- nothing here was chosen
-- by looking at a win rate:
--
--   SCOUT_TYPE   the cheapest body in the ruleset, read off the hashed UNITS
--                table rather than named. "One cheap body" is the doc's phrase;
--                which unit that is belongs to C.3, not to this file.
--   SCOUT_EVERY  one full lane traversal by that body, plus one order delay --
--                the longest a single scout could still be alive and walking
--                ground it has not already lit IN ONE LANE. At C.3's Spear
--                (10 units/tick over a 2,000-unit lane) that is 220 ticks, which
--                bounds a line refreshing at this rate at MATCH_TICKS /
--                SCOUT_EVERY bodies -- 27 Spears, 270 Levy, about a sixth of a
--                match's income. It is the DEFAULT cadence and it is the right
--                one for a line that wants one lane watched.
--   SCOUT_EVERY_MIN
--                the same traversal DIVIDED BY THE NUMBER OF LANES, plus the
--                order delay: 86 ticks. It is the floor a line may declare down
--                to, and the derivation is the reason the floor exists at all.
--                Refreshing faster than one traversal is only wasteful when
--                there is one lane to watch; with LANES of them, a body every
--                traversal/LANES ticks is the rate at which a line holds a
--                tripwire in EVERY lane at once and no faster. Below that it is
--                buying a second pair of eyes for ground the first pair is
--                standing on, which is the thing the constant exists to refuse.
--                At 86 ticks a full 6,000-tick match would afford 69 Spears --
--                690 Levy -- so the floor is not a free rung either. MEASURED on
--                the shipped roster it comes out at 42.8 bodies and 428 Levy a
--                match, about a quarter of a side's base income, because matches
--                end early and because no scout is bought into a lane this side
--                already lights. Both constants are derived; neither was chosen
--                by looking at a result.
local cheapT, cheapCost = 1, Rules.UNITS[1].cost
for i = 2, #Rules.UNITS do
  if Rules.UNITS[i].cost < cheapCost then cheapT = i; cheapCost = Rules.UNITS[i].cost end
end
M.SCOUT_TYPE = cheapT
local traversal = floor(Rules.C.LANE_LEN / Rules.UNITS[cheapT].march)
M.SCOUT_EVERY = traversal + Rules.C.ORDER_DELAY
M.SCOUT_EVERY_MIN = floor(traversal / Rules.C.LANES) + Rules.C.ORDER_DELAY

M.FAMILIES = { "aggro", "economy", "defence", "mixed" }
M.FAMILY_INDEX = { aggro = 1, economy = 2, defence = 3, mixed = 4 }

-- ---------------------------------------------------------------------------
-- name tables, derived from the ONE hashed ruleset artifact
--
-- Derived, never hand-copied: a second copy of a wire letter is a ruleset value
-- rulesHash cannot see, and a drifted copy would order the wrong building on one
-- build only. Direct-index lookup, never iterated.
-- ---------------------------------------------------------------------------

M.UNIT_KIND, M.UNIT_INDEX = {}, {}
for i = 1, #Rules.UNITS do
  M.UNIT_KIND[i] = Rules.UNITS[i].kind
  M.UNIT_INDEX[Rules.UNITS[i].key] = i
end
M.SPEAR = M.UNIT_INDEX.spear
M.HORSE = M.UNIT_INDEX.horse
M.BOW = M.UNIT_INDEX.bow

M.BLD_LETTER, M.BLD_INDEX = {}, {}
for i = 1, #Rules.BUILDINGS do
  M.BLD_LETTER[i] = Rules.BUILDINGS[i].letter
  M.BLD_INDEX[Rules.BUILDINGS[i].key] = i
end

-- Slot numbering (Rules INTERPRETATIONS 1): odd is a lane's front slot.
function M.frontSlot(lane) return (lane - 1) * 2 + 1 end
function M.backSlot(lane) return (lane - 1) * 2 + 2 end
function M.laneOfSlot(slot) return floor((slot - 1) / 2) + 1 end
function M.isFrontSlot(slot) return (slot % 2) == 1 end

-- ---------------------------------------------------------------------------
-- the view
--
-- A flat integer snapshot of the board, rebuilt each poll into the SAME tables
-- so a match allocates them once. Every field is an integer; there is not one
-- reference to sim state anywhere in it.
--
-- POSITIONS ARE OWN-FRAME, exactly as they are in the sim: `pos` is a unit's
-- distance from ITS OWN keep, so me.lanes[l].maxPos is how far my leading unit
-- has advanced and foe.lanes[l].maxPos is how far theirs has. Two opposing
-- entities are laneLen - p - q apart. There is no shared "left to right", which
-- is what makes the whole thing side-agnostic.
-- ---------------------------------------------------------------------------

-- Writing a NEW key into the view is a policy bug (the driver only ever fills
-- keys created here), so it errors instead of being silently ignored. Writing an
-- EXISTING key is harmless by construction -- the view is a copy and the sim
-- never reads it back -- and is overwritten at the next poll.
local RO = {
  __newindex = function(_, k)
    error("policy wrote a new field into the read-only view: " .. tostring(k))
  end,
}

local function newLaneView()
  return setmetatable({
    supply = 0,     -- Levy of living units, at BASE cost (Q4)
    room = 0,       -- supply headroom left, minus this side's own in-flight orders
    n = 0,          -- living units
    hp = 0,         -- their summed current HP
    maxPos = 0,     -- own-frame position of the leading unit, 0 if the lane is empty
    nS = 0, nH = 0, nB = 0,
    frontB = 0, frontDone = 0, frontHp = 0,   -- 0 = the slot is empty
    backB = 0, backDone = 0, backHp = 0,
    depth = 0,      -- Q10 tier 3 latch, 0..3
    -- SIGHT, and it is a property of the OBSERVER, not of the side this lane
    -- view describes: `lit` is how many of this lane's 8 vision sections the
    -- polled side can see right now, `seen` how many it has ever seen. Filled
    -- on `me` only and left 0 on `foe`, because "how much of lane 2 can I see"
    -- is a fact about me. It is the ONLY aggregate the fog model permits, it
    -- says nothing whatever about what is standing there, and it replaces
    -- nothing: the muster bar was an aggregate about the ENEMY and the doc
    -- deletes that outright.
    lit = 0, seen = 0,
  }, RO)
end

local function newSideView(R)
  local sv = {
    bank = 0,
    committed = 0,   -- Levy this side's own un-executed orders have already claimed
    spendable = 0,   -- bank - committed, floored at 0. What a real client can commit.
    earned = 0, spent = 0, wasted = 0,
    keepHp = 0, keepDamageDealt = 0, slotsDestroyed = 0, penetration = 0,
    occupied = 0,    -- occupied slots, counting this side's own in-flight builds
    slotCap = 0,
    levyFlat = 0,    -- flat Levy per Levy tick from completed buildings
    units = 0, supplyTotal = 0,
    lanes = {}, slots = {},
  }
  for lane = 1, R.C.LANES do sv.lanes[lane] = newLaneView() end
  for slot = 1, R.C.SLOTS do
    sv.slots[slot] = setmetatable({ b = 0, done = 0, hp = 0, free = 1 }, RO)
  end
  return setmetatable(sv, RO)
end

-- The ruleset numbers a line is allowed to plan against: BASE costs and BASE
-- build times. Deliberately not the effective, modifier-adjusted cost: every M1
-- source that touches a cost is a DISCOUNT (Fletcher, Stables), so planning at
-- base is the conservative side and an order judged affordable at issue is still
-- affordable at exec. Reproducing the sim's cost arithmetic out here would be a
-- second implementation of it, which is how two models drift apart.
function M.newView(R)
  R = R or Rules
  local v = {
    tick = 0,
    ticksLeft = 0,
    matchTicks = R.C.MATCH_TICKS,
    laneCount = R.C.LANES,
    slotCount = R.C.SLOTS,
    laneLen = R.C.LANE_LEN,
    midline = R.C.POS_MIDLINE,
    -- The fog model's geometry, so a line can reason in sections without a
    -- second copy of the arithmetic. `defaultSight` is the lowest own-frame
    -- position an ENEMY unit can be rendered at with none of your own units
    -- past the midline -- i.e. what a threshold below it is really asking for.
    sections = Fog.SECTIONS,
    sectionLen = Fog.SECTION_LEN,
    ownSections = Fog.OWN_SECTIONS,
    defaultSight = Fog.DEFAULT_SIGHT,
    -- The deepest enemy own-frame position the FIRST bought section renders --
    -- i.e. what a body parked immediately past the midline is worth as early
    -- warning. A line that scouts may name a threshold down to here; a line that
    -- does not may not (see REACT_MIN above).
    scoutSight = Fog.SCOUT_SIGHT,
    scoutType = M.SCOUT_TYPE,
    scoutEvery = M.SCOUT_EVERY,
    supplyCap = R.C.LANE_SUPPLY_CAP,
    maxPerOrder = R.C.MAX_UNITS_PER_ORDER,
    levyEvery = R.C.LEVY_EVERY,
    orderDelay = R.C.ORDER_DELAY,
    unitCost = {}, unitPrey = {}, unitMarch = {},
    bldCost = {}, bldTime = {}, bldFront = {}, bldDefensive = {}, bldGated = {},
    me = nil, foe = nil,
  }
  for t = 1, #R.UNITS do
    v.unitCost[t] = R.UNITS[t].cost
    v.unitPrey[t] = R.UNITS[t].prey
    v.unitMarch[t] = R.UNITS[t].march
  end
  for b = 1, #R.BUILDINGS do
    local br = R.BUILDINGS[b]
    v.bldCost[b] = br.cost
    v.bldTime[b] = br.build
    v.bldFront[b] = (br.slotClass == "front") and 1 or 0
    v.bldDefensive[b] = br.defensive
    v.bldGated[b] = br.cardGated
  end
  v.me = newSideView(R)
  v.foe = newSideView(R)
  return setmetatable(v, RO)
end

-- slotCap re-derived through the ruleset's own clamp, so M3's Boomtown lands
-- here without a second clamp table appearing in the policy layer.
local function slotCapOf(R, sd)
  local ch = R.CH.slotCap
  local c = R.CLAMPS[ch]
  local n = R.C.SLOT_CAP + sd.chan[ch]
  if n < c[1] then n = c[1] end
  if n > c[2] then n = c[2] end
  return n
end

-- Scratch for the per-lane visible-section set. Written before it is read
-- inside one lane's pass and never read across calls, so no table address can
-- reach a result (the same argument as sim.cg).
local VIS = {}
for s = 1, Fog.SECTIONS do VIS[s] = 0 end

-- The same, for the per-lane CONTACT set of doc section 3a: the observer's own
-- units in that lane and the reach of each. Built once per lane per poll and
-- read inside that lane's pass only, on the same argument as VIS.
local CTC = { n = 0, p = {}, r = {}, lo = 0, hi = -1 }

-- MY OWN HALF. Exact, always: your own board is never fogged.
local function fillOwn(R, sv, sim, side, res)
  local C = R.C
  local sd = sim.sides[side]

  sv.bank = sd.bank
  sv.earned = sd.earned
  sv.spent = sd.spent
  sv.wasted = sd.wasted
  sv.levyFlat = sd.cacheLevyFlat
  sv.slotCap = slotCapOf(R, sd)
  local committed = res and res.levy or 0
  sv.committed = committed
  local sp = sd.bank - committed
  if sp < 0 then sp = 0 end
  sv.spendable = sp

  sv.keepHp = sd.keepHp
  -- ESCALATED RATHER THAN PATCHED, because it is a contradiction between two
  -- documents and not a bug in this file. `me.keepDamageDealt` is the cumulative
  -- damage MY OWN units have done to THEIR keep. Nothing else damages a keep and
  -- nothing heals one, so KEEP_HP - me.keepDamageDealt is the enemy keep's EXACT
  -- live HP -- a second, always-fresh route to the one number the fog doc's
  -- section 4 says is only ever REMEMBERED. It is left in place because it is
  -- also a statistic about this side's own work, and because Rules.C has a
  -- SCORE_SHOW_TICK constant whose entire purpose is showing the Q10 tiebreak
  -- score (of which this is a term) live from the 20 percent mark. Which of the
  -- two documents wins is a ruling, not an implementation choice.
  -- NO LINE IN THE ROSTER READS IT, and that is structural rather than a promise:
  -- policy/lines.lua's engine never touches the field. README open item 18.
  sv.keepDamageDealt = sd.keepDamageDealt
  sv.slotsDestroyed = sd.slotsDestroyed

  local occ = 0
  for slot = 1, C.SLOTS do
    local b = sd.slots[slot]
    local s = sv.slots[slot]
    if b then
      s.b = b.b; s.done = b.done; s.hp = b.hp; s.free = 0
      occ = occ + 1
    else
      s.b = 0; s.done = 0; s.hp = 0
      -- An in-flight build of my own already claims the slot: a client knows
      -- what it has just sent.
      if res and res.slot[slot] == 1 then
        s.free = 0
        occ = occ + 1
      else
        s.free = 1
      end
    end
  end
  sv.occupied = occ

  local units, supplyTotal, pen = 0, 0, 0
  for lane = 1, C.LANES do
    local ln = sd.lanes[lane]
    local lv = sv.lanes[lane]
    local us = ln.units
    local n, hp, mx = 0, 0, 0
    local nS, nH, nB = 0, 0, 0
    for i = 1, #us do
      local u = us[i]
      n = n + 1
      hp = hp + u.hp
      if u.pos > mx then mx = u.pos end
      if u.t == 1 then nS = nS + 1
      elseif u.t == 2 then nH = nH + 1
      else nB = nB + 1 end
    end
    lv.supply = ln.supply
    local reserved = res and res.supply[lane] or 0
    local room = C.LANE_SUPPLY_CAP - ln.supply - reserved
    if room < 0 then room = 0 end
    lv.room = room
    lv.n = n; lv.hp = hp; lv.maxPos = mx
    lv.nS = nS; lv.nH = nH; lv.nB = nB
    lv.depth = ln.depth
    local fs = (lane - 1) * 2 + 1
    local fsv, bsv = sv.slots[fs], sv.slots[fs + 1]
    lv.frontB = fsv.b; lv.frontDone = fsv.done; lv.frontHp = fsv.hp
    lv.backB = bsv.b; lv.backDone = bsv.done; lv.backHp = bsv.hp
    units = units + n
    supplyTotal = supplyTotal + lv.supply
    pen = pen + ln.depth
  end
  sv.units = units
  sv.supplyTotal = supplyTotal
  sv.penetration = pen
end

-- THE ENEMY HALF.
--
-- `fog` is true under M.VISION == "fog" and false under "full"; `mem` is this
-- side's fog memory store (fog/Fog.lua), required when fog is on and ignored
-- when it is off. Everything fog does is SUBTRACTION: no field gains
-- information under it, which is what makes "full" an actual upper bound.
--
-- The three groups below are the fog doc's three object classes, and each one
-- is filled from a different source on purpose:
--
--   units      LIVE state, filtered by the section rule. Units are NEVER
--              remembered (doc section 4), so there is no memory read here and
--              a unit that walks back out of sight simply vanishes.
--   buildings  MEMORY ONLY. Never live. A building destroyed while unobserved
--              still shows intact, one built while unobserved does not show at
--              all, and both fall out of "read the frozen record" rather than
--              from a special case.
--   keep       position is structural (it is always there); HP from MEMORY.
--
-- No side is named anywhere in it: `side` is the index of whoever is being
-- polled and every position test goes through fog/Fog.lua's frame conversion,
-- so this reads identically from either chair (A.2).
local function fillFoe(R, sv, sim, side, fog, mem)
  local C = R.C
  local foe = 3 - side
  local sd = sim.sides[foe]

  if fog then
    -- Fog doc section 7: "Enemy Levy, bank, income, spending and loadout are
    -- not spatial and are never rendered under any circumstance." There is no
    -- route -- no building, no modifier, no pulse -- that turns any of these on,
    -- which is why this is a flat assignment and not a filtered one.
    sv.bank = 0; sv.earned = 0; sv.spent = 0; sv.wasted = 0; sv.levyFlat = 0
    sv.committed = 0; sv.spendable = 0
    -- The slot cap is a function of their loadout, so the public default is all
    -- anyone knows. Identical to slotCapOf in M2, which has no modifiers; it
    -- stops being identical in M3.
    sv.slotCap = C.SLOT_CAP
  else
    sv.bank = sd.bank
    sv.earned = sd.earned
    sv.spent = sd.spent
    sv.wasted = sd.wasted
    sv.levyFlat = sd.cacheLevyFlat
    sv.slotCap = slotCapOf(R, sd)
    sv.committed = 0
    sv.spendable = sd.bank
  end

  -- keepDamageDealt and slotsDestroyed are restatements of damage done to MY
  -- OWN board, which I can see: the HP missing from my keep, and the count of
  -- my own razed slots. Never fogged.
  sv.keepDamageDealt = sd.keepDamageDealt
  sv.slotsDestroyed = sd.slotsDestroyed
  if fog then
    sv.keepHp = Fog.rememberedKeepHp(mem)
  else
    sv.keepHp = sd.keepHp
  end

  local occ = 0
  for slot = 1, C.SLOTS do
    local s = sv.slots[slot]
    local bi, hp, maxHp, done
    if fog then
      bi, hp, maxHp, done = Fog.rememberedBuilding(mem, slot)
    else
      local b = sd.slots[slot]
      if b then bi, hp, done = b.b, b.hp, b.done else bi, hp, done = 0, 0, 0 end
    end
    if bi > 0 then
      s.b = bi; s.done = done; s.hp = hp; s.free = 0
      occ = occ + 1
    else
      -- Doc section 5: "An empty enemy slot is indistinguishable from an unseen
      -- one at range." Both land here, and nothing downstream can tell them
      -- apart, which is the rule rather than an approximation of it.
      s.b = 0; s.done = 0; s.hp = 0; s.free = 1
    end
  end
  sv.occupied = occ

  local units, supplyTotal, pen = 0, 0, 0
  for lane = 1, C.LANES do
    local ln = sd.lanes[lane]
    local lv = sv.lanes[lane]
    local us = ln.units
    local n, hp, mx = 0, 0, 0
    local nS, nH, nB = 0, 0, 0
    local supply = 0
    local vis, cs = nil, nil
    if fog then
      vis = Fog.visibleSections(sim, side, lane, VIS)
      -- This side's own weapon envelopes in this lane, built ONCE for the lane
      -- and handed to every test below. It is the doc's section 3a -- "you can
      -- see what you are fighting" -- and it is Fog's arithmetic, not a second
      -- copy of it here.
      cs = Fog.contactSet(sim, side, lane, CTC)
    end
    for i = 1, #us do
      local u = us[i]
      -- The ONE visibility test on a unit, and it is Fog's, not a second copy
      -- of the rule. u.pos is own-frame (their distance from THEIR keep); Fog
      -- converts it into the observer's section numbering.
      local shown = true
      if fog then shown = Fog.seesEnemyUnit(sim, side, u, vis, cs) end
      if shown then
        n = n + 1
        hp = hp + u.hp
        if u.pos > mx then mx = u.pos end
        if u.t == 1 then nS = nS + 1
        elseif u.t == 2 then nH = nH + 1
        else nB = nB + 1 end
        supply = supply + R.UNITS[u.t].cost
      end
    end
    if not fog then supply = ln.supply end
    lv.supply = supply
    -- Their headroom, from what can be seen of their lane. Under fog this is an
    -- OVER-estimate of the room they have left, because what is hidden is not
    -- counted -- which is the honest direction: an unseen lane looks empty, and
    -- believing an empty lane is empty is exactly the mistake the doc wants
    -- available.
    local room = C.LANE_SUPPLY_CAP - supply
    if room < 0 then room = 0 end
    lv.room = room
    lv.n = n; lv.hp = hp; lv.maxPos = mx
    lv.nS = nS; lv.nH = nH; lv.nB = nB
    lv.depth = ln.depth
    -- Read back out of sv.slots, which has already applied memory, so a lane's
    -- frontB and the slot table can never disagree about what is there.
    local fs = (lane - 1) * 2 + 1
    local fsv, bsv = sv.slots[fs], sv.slots[fs + 1]
    lv.frontB = fsv.b; lv.frontDone = fsv.done; lv.frontHp = fsv.hp
    lv.backB = bsv.b; lv.backDone = bsv.done; lv.backHp = bsv.hp
    units = units + n
    supplyTotal = supplyTotal + supply
    pen = pen + ln.depth
  end
  sv.units = units
  sv.supplyTotal = supplyTotal
  sv.penetration = pen
end

-- Fill `v` for `side`. The ONLY function in the policy layer that touches a sim,
-- it only ever READS, and it is called by the driver, never by a policy.
--
-- `mem` is the fog memory store the DRIVER owns for this side and advances once
-- per sim tick (fog/Fog.lua's OBSERVE_EVERY). It is required under the fogged
-- regime and it is an error to omit it: a view built without memory would
-- silently render every enemy building as an empty slot forever, which is a
-- DIFFERENT game rather than a missing feature -- exactly the failure mode
-- Finding 7 was about.
function M.fillView(v, sim, side, res, mem)
  local R = sim.rules
  local fog = M.VISION ~= M.VISION_FULL
  if fog and mem == nil then
    error("Policy.fillView: the fogged regime needs this side's Fog memory store")
  end
  v.tick = sim.clock
  local left = R.C.MATCH_TICKS - sim.clock
  if left < 0 then left = 0 end
  v.ticksLeft = left
  fillOwn(R, v.me, sim, side, res)
  fillFoe(R, v.foe, sim, side, fog, mem)

  -- Own sight, per lane. Under "full" every section counts as lit and seen,
  -- which keeps that regime a strict superset: a field the fogged view carries
  -- must not be missing from the upper bound (the mistake Finding 7 found in
  -- the muster bar).
  for lane = 1, R.C.LANES do
    local lv = v.me.lanes[lane]
    if fog then
      local vis = Fog.visibleSections(sim, side, lane, VIS)
      local lit, seen = 0, 0
      for s = 1, Fog.SECTIONS do
        if vis[s] == 1 then lit = lit + 1 end
        if vis[s] == 1 or Fog.sectionSeen(mem, lane, s) then seen = seen + 1 end
      end
      lv.lit = lit
      lv.seen = seen
    else
      lv.lit = Fog.SECTIONS
      lv.seen = Fog.SECTIONS
    end
  end
end

-- ---------------------------------------------------------------------------
-- orders
--
-- An order is the 6-byte command atom's payload and nothing else: a kind letter,
-- a target (lane 1-3 for units, slot 1-6 for buildings) and a count. There is no
-- field here the wire does not carry, so a policy cannot express an intent M5
-- could not send.
-- ---------------------------------------------------------------------------

function M.deployOrder(out, n, t, lane, count)
  n = n + 1
  local o = out[n]
  if not o then o = {}; out[n] = o end
  o.kind = M.UNIT_KIND[t]
  o.target = lane
  o.count = count
  return n
end

function M.buildOrder(out, n, bi, slot)
  n = n + 1
  local o = out[n]
  if not o then o = {}; out[n] = o end
  o.kind = M.BLD_LETTER[bi]
  o.target = slot
  o.count = 1
  return n
end

-- ---------------------------------------------------------------------------
-- definitions and instances
--
-- A DEFINITION is stateless and shared by every match. An INSTANCE is per match
-- and owns the two things that must never leak between matches: the memory the
-- line writes to and the PRNG stream it draws from. A definition that kept state
-- would make match n depend on match n-1, which is the same class of bug as a
-- sim that reads a clock.
-- ---------------------------------------------------------------------------

local Inst = {}
Inst.__index = Inst

function Inst:roll(lo, hi) return Rand.range(self.rng, lo, hi) end
function Inst:chance(pct)
  if pct >= 100 then return true end
  if pct <= 0 then return false end
  return Rand.range(self.rng, 1, 100) <= pct
end
function Inst:decide(v, tick, out) return self.def.decide(self, v, tick, out) end

function M.define(def)
  if type(def) ~= "table" then error("Policy.define: not a table") end
  if type(def.name) ~= "string" or def.name == "" then
    error("Policy.define: a line needs a name")
  end
  if M.FAMILY_INDEX[def.family] == nil then
    error("Policy.define: " .. def.name .. " has no family (aggro/economy/defence/mixed)")
  end
  if type(def.note) ~= "string" or def.note == "" then
    -- Every line states what it is TESTING. A line nobody can explain is a line
    -- nobody can act on when the sweep moves.
    error("Policy.define: " .. def.name .. " has no note saying what it tests")
  end
  if type(def.decide) ~= "function" then
    error("Policy.define: " .. def.name .. " has no decide()")
  end
  return def
end

-- Seed mixing. The stream is keyed to the SLOT (which argument of a pairing this
-- line is), never to the side it was seated on, so seating the same pairing the
-- other way round replays the same two streams and the match must mirror.
function M.seedFor(matchSeed, slot)
  return matchSeed * 4 + slot * 1013
end

function M.instance(def, matchSeed, slot)
  local inst = setmetatable({
    def = def,
    name = def.name,
    family = def.family,
    slot = slot,
    rng = Rand.new(M.seedFor(matchSeed, slot)),
    mem = {},
  }, Inst)
  if def.init then def.init(inst) end
  return inst
end

-- ---------------------------------------------------------------------------
-- shared read helpers. Pure functions of the view: they can no more reach the
-- sim than the line that calls them can.
-- ---------------------------------------------------------------------------

-- How many of type `t` this side can put into `lane` right now, capped by the
-- atom, by spendable Levy and by lane supply room. Base cost, per the note on
-- M.newView.
function M.affordCount(v, lane, t, reserve)
  local base = v.unitCost[t]
  local avail = v.me.spendable - (reserve or 0)
  if avail < base then return 0 end
  local n = floor(avail / base)
  if n > v.maxPerOrder then n = v.maxPerOrder end
  local byRoom = floor(v.me.lanes[lane].room / base)
  if byRoom < n then n = byRoom end
  if n < 0 then n = 0 end
  return n
end

-- The lowest free slot of a class, or 0. Ties by lowest slot index, never by
-- anything an address could reach.
function M.freeSlot(v, front, lane)
  local me = v.me
  if me.occupied >= me.slotCap then return 0 end
  if lane and lane > 0 then
    local slot = front and M.frontSlot(lane) or M.backSlot(lane)
    if me.slots[slot].free == 1 then return slot end
    return 0
  end
  for slot = 1, v.slotCount do
    if M.isFrontSlot(slot) == front and me.slots[slot].free == 1 then return slot end
  end
  return 0
end

-- The enemy lane that is cheapest to break into: least standing Levy, and a
-- standing building is worth a lot of Levy because it must be chewed through
-- before anything reaches the keep (BUILD_BLOCKS_ADVANCE). Own presence is a
-- mild pull, so a line concentrates rather than trickling into three lanes.
--
-- EVERY FIELD IT READS IS ALREADY FOGGED BY fillFoe, so this is legal as it
-- stands and it is deliberately NOT rewritten in this pass: changing it is a
-- change to how well the roster PLAYS, which is a different job from making it
-- play something it can perceive (open item 10). Two things about it are worth
-- recording against the new model:
--
--   1 The 120 / 60 terms now fire on a REMEMBERED building, which is the honest
--     signal -- "I once stood in that section and there was a wall" -- and no
--     longer on the old disclosure hack, where a building became visible by
--     being damaged and the term therefore meant "there is a wall here AND I
--     have already started chewing it". That inversion is gone. What replaces
--     it is a different bias worth stating: since a front building can only be
--     remembered from a section a unit of yours has stood in, the term mostly
--     fires for lanes this side has already fought through.
--   2 Its ties break to the lowest lane index, which is correct here and not
--     the pressedLane defect below: on a board showing nothing, "the lane
--     cheapest to break into" is genuinely answered by any lane, whereas "the
--     lane they are pressing" is not answered by any lane. A tiebreak between
--     equals is determinism rule 6; a tiebreak between unknowns is an
--     invention.
function M.openLane(v)
  local best, bestScore = 0, 0
  for lane = 1, v.laneCount do
    local f = v.foe.lanes[lane]
    local mine = v.me.lanes[lane]
    if mine.room > 0 then
      local score = f.supply + 120 * (f.frontB > 0 and 1 or 0) + 60 * (f.backB > 0 and 1 or 0)
        - floor(mine.supply / 2)
      if best == 0 or score < bestScore then best = lane; bestScore = score end
    end
  end
  return best
end

-- The lane the enemy is pressing hardest, measured the way a defender reads the
-- board: standing Levy first, and how deep it has come as the tiebreak.
--
-- RETURNS 0 FOR "NOTHING IS PRESSING", AND THAT IS THE WHOLE FIX HERE. The
-- starting score used to be -1, which no lane can fail to beat, so on a board
-- where every lane scored 0 the function answered "lane 1" -- ties broken to the
-- lowest index, exactly as determinism rule 6 asks, applied to a comparison
-- between three lanes that are indistinguishable because there is nothing to
-- distinguish. Under full information that state lasts until the enemy's first
-- deploy. UNDER FOG IT IS MOST OF THE MATCH, and MORE of it than under the
-- muster model this replaces: the bar was at least lit occasionally, whereas an
-- unscouted enemy half now reports literally nothing at all until they cross.
-- sweep/fogaudit.lua measures the share.
--
-- That is not a tiebreak, it is an invention, and three consumers act on it as
-- fact: `target = "guard"` deploys there (Turtle-eco, Turtle-pure, Wall), the
-- reactive building is placed there (Trader, Adaptive) and every unscripted
-- front slot in an opening goes there (Balanced's Trap Pit). A defence roster
-- that silently plays "focus lane 1" for the first minutes of every match is
-- measuring something nobody wrote.
--
-- Every caller already handles 0 by falling back to something that does not
-- claim to know where they are, so this is subtraction and not a new behaviour.
function M.pressedLane(v)
  local best, bestScore = 0, 0
  for lane = 1, v.laneCount do
    local f = v.foe.lanes[lane]
    local score = f.supply * 4 + floor(f.maxPos / 10)
    if score > bestScore then best = lane; bestScore = score end
  end
  return best
end

-- THE LANE THIS SIDE IS MOST BLIND IN, or 0 if there is no sight worth buying.
--
-- EVERY TERM IN IT IS A FACT ABOUT THE OBSERVER, and that is what makes it legal
-- to compute at all. `lit` is how many of this lane's 8 sections I can see right
-- now and `maxPos` is where my own leading body is; nothing about the enemy
-- enters it. A scout is sent BECAUSE the enemy half is dark, so a rule that read
-- the enemy half to decide where to scout would be answering the question it
-- exists to ask -- which is precisely the mistake `pressedLane` used to make on
-- a blank board.
--
-- Two conditions, and each one removes a lane for a different reason:
--
--   1 lit == v.sections -- I can already see the whole lane, so there is nothing
--     to buy. Under the "full" regime EVERY lane is fully lit, so a scouting line
--     sends NO scout there at all. That is deliberate: it keeps `full` an actual
--     upper bound on how well anyone can play rather than the same roster paying
--     for something it is being given, which is the instrument bug Finding 7
--     found in the muster bar and which would be much worse here.
--   2 my own leading body is already past the midline -- I am looking at that
--     lane with the army I have there, and a second body buys the same section
--     twice.
--
-- THE ORDER IS "WHERE AM I BLINDEST NOW", THEN "WHAT HAVE I EXPLORED LEAST",
-- THEN LOWEST LANE INDEX -- AND THE FIRST TERM IS A FIX, NOT A PREFERENCE.
-- This used to rank on `seen` alone. `seen` is CUMULATIVE and never falls, so
-- once a line had walked a lane the term stopped moving, and a line that scouts
-- often ends up with three saturated lanes and a tie -- which the lowest-index
-- rule then resolves to lane 1, for the rest of the match. That is the same
-- defect `pressedLane` had (README Finding 7): a tiebreak standing in for an
-- answer. `lit` is the live term the mechanic is actually about -- "vision is
-- earned and lost continuously" -- so a line refreshing a tripwire sends the
-- next one to the lane whose section has just gone dark, and coverage rotates
-- instead of piling up. `seen` survives as the second key, where least-explored
-- ground is a genuine tiebreak between two equally dark lanes.
function M.darkLane(v)
  local best, bestLit, bestSeen = 0, 0, 0
  for lane = 1, v.laneCount do
    local mine = v.me.lanes[lane]
    if mine.lit < v.sections and mine.maxPos <= v.midline then
      if best == 0 or mine.lit < bestLit
        or (mine.lit == bestLit and mine.seen < bestSeen) then
        best = lane; bestLit = mine.lit; bestSeen = mine.seen
      end
    end
  end
  return best
end

-- The type that preys on whatever the enemy has most of in this lane, or 0 if
-- the lane is empty. Q3's triangle is the only in-sim reason to change type.
function M.counterType(v, lane)
  local f = v.foe.lanes[lane]
  local n, t = f.nS, 1
  if f.nH > n then n = f.nH; t = 2 end
  if f.nB > n then n = f.nB; t = 3 end
  if n == 0 then return 0 end
  for i = 1, #v.unitPrey do
    if v.unitPrey[i] == t then return i end
  end
  return 0
end

return M
