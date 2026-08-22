-- Rules.lua -- the entire ruleset, in one file, as integers.
--
-- WHY ONE FILE (decisions G.4 mitigation 3): rulesHash covers the whole ruleset,
-- so it must be computed over a single artifact that cannot drift silently. A
-- balance change is a hard compatibility break by design; the hash is what makes
-- it a polite refusal at handshake instead of a desync at the first engagement.
--
-- WHY EVERY VALUE IS AN INTEGER (determinism rule 1): a float literal that
-- rounds differently on two machines desyncs the match at the first arithmetic.
-- Every fraction in the design doc is stored here scaled up, and the scale is
-- named in the comment beside it:
--   percentages          -> whole percent, applied as floor(v * (100 + p) 100)
--   the counter triangle -> COUNTER_PCT 150 means multiply by 150 then divide by
--                           100 inside one floor, never multiply by a fraction
--   half damage to structures -> STRUCTURE_DMG_PCT 50
--   the wheel constant K -> WHEEL_K_PERMILLE 60 over WHEEL_EDGE_DEN 225
--
-- WHY THE ORDER ARRAYS EXIST: rulesHash must walk this table in a fixed order,
-- and pairs() is forbidden in sim code (determinism rule 2). Every map here has
-- a parallel ordered key array, and the hash walker uses only those.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")

local M = {}

M.RULESET_VERSION = "IB-v2-M3"

-- ---------------------------------------------------------------------------
-- Scalar constants. Part C.1 (clocks and space), C.2 (economy), C.3 and C.5
-- (combat scalars), Q3 and Q12 (the wheel), plus the two interpretation flags.
-- ---------------------------------------------------------------------------

M.C = {
  -- C.1 clocks. Every clock is an integer multiple of the sim tick counter.
  SIM_TICK_MS       = 100,    -- 10 Hz
  RESOLVE_EVERY     = 5,      -- combat, build progress, ability triggers
  LEVY_EVERY        = 35,     -- income (3500 ms). The master balance lever, Q2.
  ORDER_DELAY       = 20,     -- orders at tick t execute no earlier than t + 20
  ORDER_DELAY_CLAMP = 40,     -- effective-delay clamp; exceeding it is halt reason D
  MATCH_TICKS       = 6000,   -- 600 s of ACTIVE sim, hard cap
  SNAPSHOT_EPOCH    = 60,     -- rollback snapshot cadence (M4 consumes this)
  SNAPSHOT_KEEP     = 5,      -- 30 s of rollback depth
  HEARTBEAT_TICKS   = 60,

  -- C.1 space. One shared 1-D axis per lane, expressed in each side's OWN frame:
  -- a unit's pos is its distance from its OWN keep, so 0 is home and LANE_LEN is
  -- the enemy keep. Two opposing entities at own-frame p and q are separated by
  -- LANE_LEN - p - q. This is what makes the sim side-agnostic (A.2): neither
  -- side has a privileged coordinate system.
  LANE_LEN          = 2000,
  POS_OWN_KEEP      = 0,
  POS_BACK_SLOT     = 300,
  POS_FRONT_SLOT    = 700,
  POS_MIDLINE       = 1000,   -- own half is pos < POS_MIDLINE
  LANES             = 3,
  SLOTS             = 6,      -- front and back for each lane
  SLOT_CAP          = 4,      -- occupied slots per side, Boomtown may raise to 5
  LANE_SUPPLY_CAP   = 200,    -- Levy per side per lane, charged at BASE cost (Q4)

  -- C.2 economy.
  OPENING_STIPEND   = 30,     -- 3 Levy ticks, granted at tick 0
  BASE_INCOME       = 10,     -- flat, every Levy tick, all match (Q1)
  BANK_CAP          = 200,
  REPEL_REFUND_PCT  = 15,     -- of an enemy unit's build cost, dying in your half
  SPOILS_PCT        = 75,     -- of an enemy building's cost, to whoever razes it

  -- C.3 and C.5 combat scalars.
  COUNTER_PCT       = 150,    -- into your prey only; no penalty term
  STRUCTURE_DMG_PCT = 50,     -- all unit damage to all structures, keep included
  KEEP_HP           = 48000,  -- the length dial; never cut the clock instead

  -- Q10 tiebreak ladder, tier 3 penetration bands and the hold requirement.
  DEPTH_HOLD_TICKS  = 50,     -- greatest depth held for at least 50 sim ticks
  DEPTH_X1          = 1300,   -- their front slot
  DEPTH_X2          = 1500,
  DEPTH_X3          = 1700,   -- their back slot
  SCORE_SHOW_TICK   = 1200,   -- live tiebreak score from the 20 percent mark

  -- Q3 and Q12, the type wheel. edge is an integer in [-225, +225]; the damage
  -- multiplier is 1 + K * edge over WHEEL_EDGE_DEN, evaluated as
  -- floor(d * (WHEEL_EDGE_DEN * 1000 + WHEEL_K_PERMILLE * edge) over
  --          (WHEEL_EDGE_DEN * 1000)) so no fraction is ever materialised.
  WHEEL_K_PERMILLE  = 60,     -- Q12's K, in permille: 60 permille of edge
  WHEEL_EDGE_DEN    = 225,
  AFFINITY_POINTS   = 3,      -- per modifier; a loadout always totals 15

  MAX_UNITS_PER_ORDER = 9,    -- the atom's count field is capped at 9 by the UI

  -- D.2 Shrine reveal pulse, in sim ticks (Q11: every timer is sim ticks). The
  -- pulse itself is a PERCEPTION effect and is implemented by the fog layer
  -- (M3 part 2), never by the sim -- these two numbers live here so the whole
  -- ruleset is hashed, including the part only the renderer consumes.
  SHRINE_PULSE_EVERY  = 200,
  SHRINE_PULSE_TICKS  = 30,

  -- Interpretation flags. Both are hashed, so flipping one is a compatibility
  -- break, which is the correct treatment for a rule the two clients must agree
  -- on. See the INTERPRETATIONS block at the bottom of this file.
  ENFORCE_SLOT_CLASS  = 1,    -- front-slot buildings may only enter front slots
  BUILD_BLOCKS_ADVANCE = 1,   -- any standing building blocks and is auto-engaged
}

M.CONST_ORDER = {
  "SIM_TICK_MS", "RESOLVE_EVERY", "LEVY_EVERY", "ORDER_DELAY", "ORDER_DELAY_CLAMP",
  "MATCH_TICKS", "SNAPSHOT_EPOCH", "SNAPSHOT_KEEP", "HEARTBEAT_TICKS",
  "LANE_LEN", "POS_OWN_KEEP", "POS_BACK_SLOT", "POS_FRONT_SLOT", "POS_MIDLINE",
  "LANES", "SLOTS", "SLOT_CAP", "LANE_SUPPLY_CAP",
  "OPENING_STIPEND", "BASE_INCOME", "BANK_CAP", "REPEL_REFUND_PCT", "SPOILS_PCT",
  "COUNTER_PCT", "STRUCTURE_DMG_PCT", "KEEP_HP",
  "DEPTH_HOLD_TICKS", "DEPTH_X1", "DEPTH_X2", "DEPTH_X3", "SCORE_SHOW_TICK",
  "WHEEL_K_PERMILLE", "WHEEL_EDGE_DEN", "AFFINITY_POINTS",
  "MAX_UNITS_PER_ORDER", "SHRINE_PULSE_EVERY", "SHRINE_PULSE_TICKS",
  "ENFORCE_SLOT_CLASS", "BUILD_BLOCKS_ADVANCE",
}

-- ---------------------------------------------------------------------------
-- C.3 units. HP is on a scale where damage lands every resolve tick.
-- `prey` is the unit index this one hits for COUNTER_PCT: Spear beats Horse,
-- Horse beats Bow, Bow beats Spear.
-- Index order matches the wire kind letters S, H, B (A.11.2).
-- ---------------------------------------------------------------------------

M.UNIT_FIELDS = { "key", "kind", "cost", "hp", "dmg", "targets", "range", "march", "prey" }

M.UNITS = {
  { key = "spear", kind = "S", cost = 10, hp =  420, dmg = 16, targets = 1, range =  60, march = 10, prey = 2 },
  { key = "horse", kind = "H", cost = 30, hp = 1020, dmg = 44, targets = 1, range =  60, march = 20, prey = 3 },
  { key = "bow",   kind = "B", cost = 20, hp =  360, dmg = 12, targets = 3, range = 320, march =  7, prey = 1 },
}

M.UNIT_SPEAR, M.UNIT_HORSE, M.UNIT_BOW = 1, 2, 3

-- Direct-index lookup only; never iterated. DERIVED from the hashed UNITS table
-- on purpose: a hand-written copy is a ruleset value rulesHash cannot see, and
-- Sim:queueCommand decodes every wire kind letter through it, so a drifted copy
-- would silently map a letter to the wrong unit on one build only.
M.UNIT_BY_KIND = {}
for i = 1, #M.UNITS do
  M.UNIT_BY_KIND[M.UNITS[i].kind] = i
end

-- ---------------------------------------------------------------------------
-- C.4 buildings.
--
-- WIRE LETTERS, per the A.11.2 ruling of 2026-08-12 (implemented 2026-08-13,
-- deferred past the M2 sweep so the goldens would not move mid-measurement):
-- CASE IS THE NAMESPACE. Uppercase kinds target a LANE (units S/H/B, verbs
-- I Investment, E Scorched Earth, L Ley Line - E because S is Spear);
-- lowercase kinds target a SLOT (this catalogue, contiguous a-l, no gaps).
-- The decoder is case-sensitive on purpose; never lower() an incoming kind.
--
-- slotClass is enforced when C.ENFORCE_SLOT_CLASS is 1.
-- defensive is the flag Bastion Walls and Watchfires scope to (M3).
-- levyFlat is Levy per Levy tick; bankCapFlat is a flat bank cap addition.
-- The aura fields are lane-scoped channel contributions in whole percent, all
-- applied through the same clamp machinery a modifier uses, so there is exactly
-- one code path for "something modified this number" (S1 to S3).
-- firstPlayable marks D.1's six-building subset.
-- ---------------------------------------------------------------------------

M.BUILDING_FIELDS = {
  "key", "letter", "cost", "hp", "build", "slotClass", "defensive",
  "dmg", "dmgRange", "vision",
  "levyFlat", "bankCapFlat",
  "trapBurst", "trapPerTarget", "trapTargets", "trapRadius",
  "auraUnitDmg", "auraDmgTaken", "auraMarch", "auraCostUnit", "auraCostPct",
  "auraBowRange", "cardGated", "firstPlayable",
}

local function B(t)
  t.dmg = t.dmg or 0
  t.dmgRange = t.dmgRange or 0
  t.vision = t.vision or 0
  t.levyFlat = t.levyFlat or 0
  t.bankCapFlat = t.bankCapFlat or 0
  t.trapBurst = t.trapBurst or 0
  t.trapPerTarget = t.trapPerTarget or 0
  t.trapTargets = t.trapTargets or 0
  t.trapRadius = t.trapRadius or 0
  t.auraUnitDmg = t.auraUnitDmg or 0
  t.auraDmgTaken = t.auraDmgTaken or 0
  t.auraMarch = t.auraMarch or 0
  t.auraCostUnit = t.auraCostUnit or 0
  t.auraCostPct = t.auraCostPct or 0
  t.auraBowRange = t.auraBowRange or 0
  t.cardGated = t.cardGated or 0
  t.firstPlayable = t.firstPlayable or 0
  return t
end

M.BUILDINGS = {
  B{ key = "trapPit",    letter = "a", cost =  50, hp = 1000, build =  60, slotClass = "front", defensive = 1,
     trapBurst = 3600, trapPerTarget = 1100, trapTargets = 6, trapRadius = 120, firstPlayable = 1 },
  B{ key = "watchtower", letter = "b", cost =  70, hp = 1250, build =  90, slotClass = "front", defensive = 1,
     dmg = 38, dmgRange = 300, vision = 600, firstPlayable = 1 },
  B{ key = "palisade",   letter = "c", cost =  90, hp = 8800, build = 120, slotClass = "front", defensive = 1,
     firstPlayable = 1 },
  B{ key = "granary",    letter = "d", cost = 100, hp = 1200, build = 120, slotClass = "back",  defensive = 0,
     levyFlat = 1, bankCapFlat = 150, firstPlayable = 1 },
  B{ key = "arrowTower", letter = "e", cost = 110, hp = 1900, build = 120, slotClass = "front", defensive = 1,
     dmg = 112, dmgRange = 320, firstPlayable = 1 },
  B{ key = "redoubt",    letter = "f", cost = 110, hp = 2250, build = 150, slotClass = "back",  defensive = 1,
     auraDmgTaken = -30 },
  B{ key = "smithy",     letter = "g", cost = 110, hp = 1200, build = 150, slotClass = "back",  defensive = 0,
     auraUnitDmg = 25 },
  B{ key = "fletcher",   letter = "h", cost = 110, hp = 1200, build = 150, slotClass = "back",  defensive = 0,
     auraCostUnit = 3, auraCostPct = -30, auraBowRange = 6 },
  B{ key = "levyPost",   letter = "i", cost = 120, hp = 1400, build = 150, slotClass = "back",  defensive = 0,
     levyFlat = 2, firstPlayable = 1 },
  B{ key = "stables",    letter = "j", cost = 120, hp = 1200, build = 150, slotClass = "back",  defensive = 0,
     auraMarch = 50, auraCostUnit = 2, auraCostPct = -30 },
  B{ key = "shrine",     letter = "k", cost = 140, hp = 1200, build = 180, slotClass = "back",  defensive = 0 },
  B{ key = "caravan",    letter = "l", cost = 120, hp =  400, build = 120, slotClass = "back",  defensive = 0,
     levyFlat = 4, cardGated = 1 },
}

-- Direct-index lookup only; never iterated.
M.BUILDING_BY_LETTER = {}
for i = 1, #M.BUILDINGS do
  M.BUILDING_BY_LETTER[M.BUILDINGS[i].letter] = i
end

-- ---------------------------------------------------------------------------
-- Q4 S1 channels and S4 clamps.
--
-- Sources sum as integer percentage POINTS inside a channel, are clamped once,
-- and are applied exactly once as floor(base * (100 + sum) 100). Three channels
-- are not percentages and are marked absolute: levyFlat is whole Levy per Levy
-- tick, repelRefund is percentage POINTS added to the 15 baseline, and slotCap
-- is an absolute occupied-slot count clamped into [4, 5].
-- ---------------------------------------------------------------------------

M.CHANNELS = {
  "unitCost", "unitHP", "unitDmg", "dmgTaken", "march",
  "bldHP", "bldCost", "bldTime",
  "levyTick", "levyFlat", "bankCap", "dmgVsBuildings", "production",
  "repelRefund", "slotCap",
}

M.CH = {}
for i = 1, #M.CHANNELS do
  M.CH[M.CHANNELS[i]] = i
end

-- { lo, hi, absolute }
M.CLAMPS = {
  { -20,  40, 0 },  -- unitCost   (absolute floor of 1 Levy applied at the call site)
  { -40,  40, 0 },  -- unitHP
  { -35,  35, 0 },  -- unitDmg
  { -30,  30, 0 },  -- dmgTaken
  { -40,  50, 0 },  -- march
  { -50,  80, 0 },  -- bldHP
  { -50, 100, 0 },  -- bldCost
  { -50, 100, 0 },  -- bldTime
  { -30,  40, 0 },  -- levyTick
  {  -4,  12, 1 },  -- levyFlat, whole Levy per Levy tick
  { -50, 150, 0 },  -- bankCap
  { -50, 100, 0 },  -- dmgVsBuildings
  { -50, 100, 0 },  -- production
  {   0,  30, 1 },  -- repelRefund, points on top of the 15 baseline
  {   4,   5, 1 },  -- slotCap, absolute occupied-slot count
}

-- ---------------------------------------------------------------------------
-- Q3 / Q12 / IDLE_BATTLE.md section 8: the five-type wheel.
--
-- WHEEL_TYPES is the Q3 vector order -- (Swarm, Boom, Mystic, Fortress, Raider)
-- -- and WHEEL[i][j] is +1 when type i beats type j, -1 when it loses, 0 on the
-- diagonal. The matrix is the symmetric five-cycle of section 8, so every row
-- and column sums to zero: a uniform loadout is neutral against everything,
-- mirrors resolve to exactly 0, and one integer edge drives both sides (the
-- opponent's edge is the exact negative). All three properties are asserted at
-- load in the CHECKS block below.
--
-- There is NO dominant-type label anywhere. Q3's ruling is that affinity is a
-- VECTOR and the label is killed entirely -- "there is no tie because there is
-- no label" -- so the sim stores only the bilinear edge (sd.wheelNum) and no
-- code path ever computes, stores or exposes a type name for a side.
-- ---------------------------------------------------------------------------

M.WHEEL_TYPES = { "swarm", "boom", "mystic", "fortress", "raider" }

M.WHEEL = {
  {  0,  1,  1, -1, -1 },   -- Swarm    beats Boom, Mystic
  { -1,  0,  1,  1, -1 },   -- Boom     beats Mystic, Fortress
  { -1, -1,  0,  1,  1 },   -- Mystic   beats Fortress, Raider
  {  1, -1, -1,  0,  1 },   -- Fortress beats Raider, Swarm
  {  1,  1, -1, -1,  0 },   -- Raider   beats Swarm, Boom
}

-- ---------------------------------------------------------------------------
-- D.3: the forty cards, normative wording, as hashed integer data.
--
-- Index IS the card id (the loadout arrays and the handshake carry these ids),
-- in D.3's own order: Swarm 1-8, Fortress 9-16, Boom 17-24, Raider 25-32,
-- Mystic 33-40. 0 in a loadout slot means "empty slot".
--
-- affSwarm..affRaider is the card's Q3 affinity vector: exactly 3 points, 3/0
-- pure or 2/1 split across at most two types. Every card is pure in its home
-- archetype EXCEPT Granary Reserves (2 Fortress / 1 Boom) -- the one split the
-- documents force: IDLE_BATTLE.md section 9's "Turtle Bank" must total 8F/7B
-- with pure-Boom as its worst matchup (Q3's worked example), which only that
-- assignment reproduces. See INTERPRETATIONS item 14.
--
-- class is "stat" or "rule" per D.3's own labels (Press-Gang, Surplus and
-- Boomtown ship as [Stat]; Tide of Bodies and Endless Ranks as [Rule]).
--
-- The payload fields are the card's numbers in this file's integer conventions:
-- whole percentage points on a named channel (ch1/pts1, ch2/pts2, foeCh/foePts
-- for a value written into the OPPONENT's channel), whole Levy, sim ticks,
-- permille of the match clock for time gates (Q11: every time gate is a
-- fraction of the clock, never an absolute). Scope flags select what a scoped
-- [Stat] applies to. Semantics live in sim/Mods.lua; every NUMBER lives here,
-- inside rulesHash, so two builds that disagree about any card value refuse
-- each other at the handshake instead of desyncing (A.11.1).
-- ---------------------------------------------------------------------------

M.CARD_FIELDS = {
  "key", "name", "class",
  "affSwarm", "affBoom", "affMystic", "affFortress", "affRaider",
  "ch1", "pts1", "ch2", "pts2", "foeCh", "foePts",
  "scopeUnit", "scopeDefensive", "scopeOwnHalf", "scopeRubble", "condHalfBank",
  "gatePermille", "gateEarned", "per", "perBank", "every", "cap", "window",
  "pct", "flat", "dmg", "costPerBlock", "blocksMax", "dmgPerBlock",
  "targetsMax", "cooldown", "perLaneMax", "unlockBld", "info",
}

local function CARD(t)
  for i = 1, #M.CARD_FIELDS do
    local f = M.CARD_FIELDS[i]
    if t[f] == nil then t[f] = 0 end
  end
  return t
end

M.CARDS = {
  -- SWARM (1-8)
  CARD{ key = "breedingPits", name = "Breeding Pits", class = "stat", affSwarm = 3,
        ch1 = M.CH.unitCost, pts1 = -10 },
  CARD{ key = "chaff", name = "Chaff", class = "stat", affSwarm = 3,
        ch1 = M.CH.unitCost, pts1 = -20, ch2 = M.CH.unitHP, pts2 = -30 },
  CARD{ key = "scentTrails", name = "Scent Trails", class = "stat", affSwarm = 3,
        ch1 = M.CH.march, pts1 = 25 },
  CARD{ key = "tideOfBodies", name = "Tide of Bodies", class = "rule", affSwarm = 3,
        ch1 = M.CH.unitDmg, per = 2, cap = 30 },        -- +per x N in lane, own-source ceiling
  CARD{ key = "endlessRanks", name = "Endless Ranks", class = "rule", affSwarm = 3,
        perLaneMax = 3 },                               -- Muster charges per lane
  CARD{ key = "ricketyScaffolds", name = "Rickety Scaffolds", class = "stat", affSwarm = 3,
        ch1 = M.CH.bldTime, pts1 = -50, ch2 = M.CH.bldHP, pts2 = -40 },
  CARD{ key = "pressGang", name = "Press-Gang", class = "stat", affSwarm = 3,
        ch1 = M.CH.levyTick, pts1 = 15, ch2 = M.CH.bankCap, pts2 = -50 },
  CARD{ key = "conscription", name = "Conscription", class = "rule", affSwarm = 3,
        per = 3 },                                      -- every per-th deploy is free

  -- FORTRESS (9-16)
  CARD{ key = "bastionWalls", name = "Bastion Walls", class = "stat", affFortress = 3,
        ch1 = M.CH.bldHP, pts1 = 50, scopeDefensive = 1 },
  CARD{ key = "ironDiscipline", name = "Iron Discipline", class = "stat", affFortress = 3,
        ch1 = M.CH.dmgTaken, pts1 = -25, scopeOwnHalf = 1 },
  CARD{ key = "counterwall", name = "Counterwall", class = "rule", affFortress = 3,
        pct = 20 },                                     -- % of the lane accumulator on a clean repel
  CARD{ key = "deepFoundations", name = "Deep Foundations", class = "rule", affFortress = 3 },
  CARD{ key = "rapidMasonry", name = "Rapid Masonry", class = "stat", affFortress = 3,
        ch1 = M.CH.bldCost, pts1 = -50, scopeRubble = 1 },
  CARD{ key = "watchfires", name = "Watchfires", class = "stat", affFortress = 3,
        pct = 50, scopeDefensive = 1 },                 -- +% damage range; the reveal is fog-side
  CARD{ key = "granaryReserves", name = "Granary Reserves", class = "stat",
        affFortress = 2, affBoom = 1,                   -- the one 2/1 split; see the header
        ch1 = M.CH.bankCap, pts1 = 50, ch2 = M.CH.levyTick, pts2 = 20, condHalfBank = 1 },
  CARD{ key = "bulwarkLine", name = "Bulwark Line", class = "stat", affFortress = 3,
        ch1 = M.CH.unitHP, pts1 = 40, scopeUnit = 1 },  -- Spear

  -- BOOM (17-24)
  CARD{ key = "tradeRoutes", name = "Trade Routes", class = "stat", affBoom = 3,
        ch1 = M.CH.levyFlat, per = 1, every = 600, cap = 6 },
  CARD{ key = "goldenAge", name = "Golden Age", class = "rule", affBoom = 3,
        ch1 = M.CH.levyTick, pts1 = 40, gateEarned = 700 },
  CARD{ key = "investment", name = "Investment", class = "rule", affBoom = 3,
        costPerBlock = 25, blocksMax = 4, window = 450, pct = 180 },
  CARD{ key = "masterMasons", name = "Master Masons", class = "stat", affBoom = 3,
        ch1 = M.CH.production, pts1 = 35 },
  CARD{ key = "surplus", name = "Surplus", class = "stat", affBoom = 3,
        ch1 = M.CH.levyFlat, per = 1, perBank = 50, cap = 6 },
  CARD{ key = "caravan", name = "Caravan", class = "rule", affBoom = 3,
        unlockBld = 12 },                               -- the Caravan building's index
  CARD{ key = "lateLevy", name = "Late Levy", class = "stat", affBoom = 3,
        ch1 = M.CH.unitCost, pts1 = -20, gatePermille = 500 },
  CARD{ key = "boomtown", name = "Boomtown", class = "stat", affBoom = 3,
        ch1 = M.CH.slotCap, pts1 = 1 },

  -- RAIDER (25-32)
  CARD{ key = "plunder", name = "Plunder", class = "rule", affRaider = 3,
        pct = 100, flat = 20 },                         -- replaces the Spoils baseline
  CARD{ key = "bloodTithe", name = "Blood Tithe", class = "rule", affRaider = 3,
        pct = 20 },
  CARD{ key = "warDrums", name = "War Drums", class = "stat", affRaider = 3,
        ch1 = M.CH.unitDmg, pts1 = 15, window = 200 },
  CARD{ key = "sappers", name = "Sappers", class = "stat", affRaider = 3,
        ch1 = M.CH.dmgVsBuildings, pts1 = 100 },
  CARD{ key = "vanguard", name = "Vanguard", class = "stat", affRaider = 3,
        ch1 = M.CH.unitDmg, pts1 = 35, perLaneMax = 3 },
  CARD{ key = "noRetreat", name = "No Retreat", class = "stat", affRaider = 3,
        ch1 = M.CH.unitDmg, pts1 = 35 },                -- floor(pts1 * (maxHp - hp) / maxHp)
  CARD{ key = "scorchedEarth", name = "Scorched Earth", class = "rule", affRaider = 3,
        costPerBlock = 25, blocksMax = 4, dmgPerBlock = 600, targetsMax = 3, cooldown = 300 },
  CARD{ key = "raidingParty", name = "Raiding Party", class = "rule", affRaider = 3,
        ch1 = M.CH.march, pts1 = 40, scopeUnit = 2, perLaneMax = 1 },  -- Horse; 1 Bypass per lane

  -- MYSTIC (33-40)
  CARD{ key = "hex", name = "Hex", class = "rule", affMystic = 3,
        foeCh = M.CH.levyTick, foePts = -30, every = 400, window = 200 },
  CARD{ key = "divination", name = "Divination", class = "rule", affMystic = 3, info = 1 },
  CARD{ key = "omen", name = "Omen", class = "rule", affMystic = 3, info = 1 },
  CARD{ key = "veil", name = "Veil", class = "rule", affMystic = 3, info = 1 },
  CARD{ key = "ward", name = "Ward", class = "stat", affMystic = 3,
        pct = 25 },                                     -- % of pre-mitigation damage reflected
  CARD{ key = "miasma", name = "Miasma", class = "stat", affMystic = 3,
        dmg = 8 },                                      -- per resolve tick, in the owner's half
  CARD{ key = "leyLine", name = "Ley Line", class = "rule", affMystic = 3,
        cooldown = 450 },
  CARD{ key = "discord", name = "Discord", class = "stat", affMystic = 3,
        foeCh = M.CH.unitCost, foePts = 15 },
}

-- Direct-index lookup only; never iterated. Derived from the hashed CARDS table
-- for the same reason UNIT_BY_KIND is.
M.CARD_BY_KEY = {}
for i = 1, #M.CARDS do
  M.CARD_BY_KEY[M.CARDS[i].key] = i
end

-- ---------------------------------------------------------------------------
-- CHECKS: the card table and the wheel refuse to load wrong, rather than
-- computing a wrong match. Everything here is structural -- the numbers
-- themselves are pinned by harness/selftest.lua's M3 sections.
-- ---------------------------------------------------------------------------

do
  if #M.CARDS ~= 40 then error("Rules: the card pool must hold exactly 40 cards") end
  if #M.WHEEL_TYPES ~= 5 or #M.WHEEL ~= 5 then error("Rules: the wheel is five types") end
  for i = 1, 5 do
    if #M.WHEEL[i] ~= 5 then error("Rules: wheel row is not five wide") end
    if M.WHEEL[i][i] ~= 0 then error("Rules: wheel diagonal must be zero") end
    local sum = 0
    for j = 1, 5 do
      local w = M.WHEEL[i][j]
      if w ~= -1 and w ~= 0 and w ~= 1 then error("Rules: wheel entry outside -1..1") end
      if M.WHEEL[j][i] ~= -w then error("Rules: wheel is not antisymmetric") end
      sum = sum + w
    end
    if sum ~= 0 then
      -- A row that does not sum to zero breaks Q3's three free properties:
      -- neutral rainbow, exact-zero mirrors, one edge driving both sides.
      error("Rules: wheel row does not sum to zero")
    end
  end
  -- D.3's class distribution: [Rule] per archetype block is 3/2/3/4/5 = 17.
  local ruleWant = { 3, 2, 3, 4, 5 }
  local ruleTotal = 0
  for blk = 1, 5 do
    local n = 0
    for i = (blk - 1) * 8 + 1, blk * 8 do
      local cd = M.CARDS[i]
      if cd.class == "rule" then n = n + 1
      elseif cd.class ~= "stat" then error("Rules: card class must be stat or rule") end
    end
    if n ~= ruleWant[blk] then error("Rules: [Rule] count per archetype does not match D.3") end
    ruleTotal = ruleTotal + n
  end
  if ruleTotal ~= 17 then error("Rules: Q5 says 17 [Rule] of 40") end
  -- Q3: exactly AFFINITY_POINTS per card, split across at most two types.
  for i = 1, #M.CARDS do
    local cd = M.CARDS[i]
    local a = { cd.affSwarm, cd.affBoom, cd.affMystic, cd.affFortress, cd.affRaider }
    local sum, nz = 0, 0
    for j = 1, 5 do
      if a[j] < 0 then error("Rules: negative affinity points") end
      if a[j] > 0 then nz = nz + 1 end
      sum = sum + a[j]
    end
    if sum ~= M.C.AFFINITY_POINTS then error("Rules: a card must carry exactly 3 affinity points") end
    if nz > 2 then error("Rules: affinity splits across at most two types (Q3)") end
  end
  -- The one worked example the documents give: Granary Reserves is the 2F/1B
  -- split that makes section 9's Turtle Bank total 8F/7B.
  local gr = M.CARDS[M.CARD_BY_KEY.granaryReserves]
  if gr.affFortress ~= 2 or gr.affBoom ~= 1 then
    error("Rules: Granary Reserves must be 2 Fortress / 1 Boom (INTERPRETATIONS 14)")
  end
  -- Caravan's unlock index must actually be the Caravan building.
  if M.BUILDINGS[M.CARDS[M.CARD_BY_KEY.caravan].unlockBld].key ~= "caravan" then
    error("Rules: the Caravan card unlocks a building that is not the Caravan")
  end
end

-- Q10 ladder tier names, hashed so a reordering is a compatibility break.
M.TIERS = { "keepHpRemoved", "slotsDestroyed", "penetration", "ownKeepHp", "draw" }

-- Terminal reason codes. Integers because the state hash must not depend on
-- string identity for a value that crosses the wire as a code.
M.REASON = { NONE = 0, KEEP = 1, CLOCK = 2, VOID = 3 }

-- REASON must be hashed like every other ruleset value: reasonCode is inside
-- Hash.state and crosses the wire in the X and V atoms, so a build that
-- renumbered a code while the handshake still accepted would surface as a
-- heartbeat mismatch mid-match instead of G.4's polite refusal.
M.REASON_ORDER = { "NONE", "KEEP", "CLOCK", "VOID" }

-- ---------------------------------------------------------------------------
-- rulesHash. 31 bits, deterministic, computed over EVERY value above in a fixed
-- order. A.11.1: it gates the simulation content, while `proto` gates the wire
-- layout, and the two get different refusal strings.
-- ---------------------------------------------------------------------------

local function computeRulesHash(R)
  local h = Hash.new()
  h = Hash.str(h, R.RULESET_VERSION)

  local order = R.CONST_ORDER
  h = Hash.int(h, #order)
  for i = 1, #order do
    local k = order[i]
    h = Hash.str(h, k)
    local v = R.C[k]
    if v == nil then
      error("Rules: CONST_ORDER names a constant that does not exist: " .. k)
    end
    h = Hash.int(h, v)
  end

  local uf = R.UNIT_FIELDS
  h = Hash.int(h, #R.UNITS)
  for i = 1, #R.UNITS do
    local u = R.UNITS[i]
    for f = 1, #uf do
      h = Hash.str(h, uf[f])
      h = Hash.any(h, u[uf[f]])
    end
  end

  local bf = R.BUILDING_FIELDS
  h = Hash.int(h, #R.BUILDINGS)
  for i = 1, #R.BUILDINGS do
    local b = R.BUILDINGS[i]
    for f = 1, #bf do
      h = Hash.str(h, bf[f])
      h = Hash.any(h, b[bf[f]])
    end
  end

  h = Hash.int(h, #R.CHANNELS)
  for i = 1, #R.CHANNELS do
    h = Hash.str(h, R.CHANNELS[i])
    local c = R.CLAMPS[i]
    if c == nil then
      error("Rules: channel without a clamp: " .. R.CHANNELS[i])
    end
    h = Hash.int(h, c[1])
    h = Hash.int(h, c[2])
    h = Hash.int(h, c[3])
  end

  -- The wheel: type order, then every matrix entry.
  h = Hash.int(h, #R.WHEEL_TYPES)
  for i = 1, #R.WHEEL_TYPES do
    h = Hash.str(h, R.WHEEL_TYPES[i])
    for j = 1, #R.WHEEL_TYPES do
      h = Hash.int(h, R.WHEEL[i][j])
    end
  end

  -- The forty cards: every field of every card, in CARD_FIELDS order.
  local cf = R.CARD_FIELDS
  h = Hash.int(h, #R.CARDS)
  for i = 1, #R.CARDS do
    local cd = R.CARDS[i]
    for f = 1, #cf do
      h = Hash.str(h, cf[f])
      h = Hash.any(h, cd[cf[f]])
    end
  end

  h = Hash.int(h, #R.TIERS)
  for i = 1, #R.TIERS do
    h = Hash.str(h, R.TIERS[i])
  end

  local ro = R.REASON_ORDER
  h = Hash.int(h, #ro)
  for i = 1, #ro do
    h = Hash.str(h, ro[i])
    local v = R.REASON[ro[i]]
    if v == nil then
      error("Rules: REASON_ORDER names a code that does not exist: " .. ro[i])
    end
    h = Hash.int(h, v)
  end
  return h
end

M.rulesHash = computeRulesHash(M)
M.rulesHash36 = Hash.base36(M.rulesHash, 6)

-- Recompute after a deliberate table edit (tests, or a future balance patch
-- loader). Never call this to "fix" a mismatch at runtime.
function M.recomputeHash()
  M.rulesHash = computeRulesHash(M)
  M.rulesHash36 = Hash.base36(M.rulesHash, 6)
  return M.rulesHash
end

-- ---------------------------------------------------------------------------
-- INTERPRETATIONS -- places where the design documents were silent or in
-- conflict and this implementation had to choose. Each is a hashed constant or
-- a documented rule so both clients cannot disagree.
--
-- 1. Slot numbering. Slot = (lane - 1) * 2 + 1 is that lane's FRONT slot,
--    + 2 is its BACK slot. The atom's target field carries 1 to 6 (A.11.2).
-- 2. Levy tick timing. The stipend lands at tick 0 and Levy ticks fire when
--    tick > 0 and tick mod 35 == 0, giving 171 ticks and 30 + 1710 = 1740 total
--    base Levy (C.2), the Trap Pit affordable at exactly 7 s and the Levy Post
--    at exactly 31 s and a half. All three doc figures reproduce exactly.
-- 3. Buildings block advance. C.4 lists "blocks advance" only against Palisade,
--    but Raiding Party's Bypass ("not blocked by that building") only makes
--    sense if buildings block generally. BUILD_BLOCKS_ADVANCE = 1.
-- 4. Under-construction buildings occupy the slot, carry full HP, are valid
--    targets and block, but produce no effect until complete.
-- 5. Slot class enforcement. The catalogue's natural slot is enforced, since a
--    rule both clients evaluate is safer than a convention. ENFORCE_SLOT_CLASS.
-- 6. Income composition. income = floor((BASE_INCOME + building levyFlat scaled
--    by `production` + modifier levyFlat) * (100 + levyTick) over 100). One
--    multiply, one floor, per S7.
-- 7. Kill attribution under the S9 tick-start snapshot. All damage in a resolve
--    tick is computed from the snapshot and applied together, so "the killing
--    blow" is ambiguous; the killer is the LOWEST entity id among the sources
--    that damaged the victim that tick, per S10.
-- 8. Earned Levy (Golden Age's threshold) counts income, repel refunds and
--    spoils alike -- everything credited, before bank-cap clipping.
-- 9. The Q3 type wheel multiplies ALL damage a unit DEALS -- into enemy
--    units, buildings and the keep alike. This is a reading, not a choice:
--    Q3's normative sentence is "applied as a single final multiplier on
--    damage dealt", Q12 repeats it ("6% damage dealt at maximum focus"),
--    and neither carves out a target type -- so Sim.unitDamage applies
--    sd.wheelNum as the last factor of everything the unit deals, and a
--    favourable matchup also razes structures ~6% faster, which is coherent
--    with Q12's quiet global edge. What carries no wheel is damage no ARMY
--    dealt: building damage (Arrow Tower, Watchtower), the Trap Pit burst,
--    Ward's reflect, Miasma and Scorched Earth -- a tower has no type, so
--    there is no edge to read. Pinned at HORSE scale by selftest section 19
--    (a max-edge horse deals 23 per resolve to a palisade and to the keep,
--    not the unwheeled 22); spear scale cannot falsify the structure half,
--    because floor(8 * 1.06) is 8 again. (An earlier revision of this item
--    said "UNIT damage only", contradicting Q3's sentence and the code,
--    which has applied the wheel to structure damage since M3 part 1.)
-- 10. A bank cap REDUCTION does not claw back Levy already banked. Razing a
--    Granary drops the cap by 150, and an owner sitting on 350 keeps all 350;
--    the excess is simply unspendable-on-top rather than destroyed, and the next
--    credit is fully wasted until the balance falls back under the cap. The
--    alternative (clip on the way down and count the difference as waste) would
--    let an attacker delete banked Levy retroactively, which no design document
--    asks for. M3's cap-moving cards are designed against THIS rule. See
--    tools/mechanics.lua, "bank cap reduction".
-- 11. Construction credit. A resolve pass pays for the RESOLVE_EVERY ticks that
--    have just elapsed, and commands execute BEFORE resolve inside one tick, so
--    a building placed on a resolve tick has performed none of them: b.startTick
--    suppresses that first credit. A building therefore takes exactly its C.4
--    build time when the exec tick is on the resolve grid, and up to 4 ticks less
--    when it is not -- irreducible 5-tick-grid quantization, never more.
-- 12. The ORDER_DELAY window is enforced in queueCommand, but only when the
--    caller supplies issueTick. The sim's contract is a pure function of
--    (ruleset, seed, atoms with their EXEC ticks); the issue tick is wire
--    metadata that a replay artifact need not carry. M5 must supply it.
--
-- M3 (the forty cards). Items 13-28. Each is a place D.3's normative wording,
-- Q3/Q4/Q5 or the older IDLE_BATTLE.md was silent, ambiguous or in conflict,
-- and this implementation chose. Every choice is either hashed data (so a
-- future ruling is a deliberate compatibility break) or a documented rule in
-- sim/Mods.lua with a selftest pinning it.
--
-- 13. Loadout validation. A loadout is an array of exactly 5 integer slots;
--    each slot is 0 (empty) or a card id 1..40; a non-zero id may appear only
--    once (Q6's "ten cards gives 252 loadouts" is C(10,5) -- combinations
--    WITHOUT repetition -- and D.2's saturation table treats a second copy as
--    unrepresentable). PARTIAL loadouts are legal in the SIM: the M3 milestone
--    tests every card alone, and the first playable is "zero modifiers", so
--    emptiness must be expressible. "Exactly 5 real cards" is the loadout UI's
--    rule and is enforced at M8's handshake, not here. Violations error() at
--    Sim.new -- a malformed loadout is a broken handshake, not a fizzle.
-- 14. Affinity splits. Q3 allows 3/0 or 2/1 and no document assigns per-card
--    splits. Every card is pure 3/0 in its home archetype except GRANARY
--    RESERVES = 2 Fortress / 1 Boom, which is forced: IDLE_BATTLE.md section 9
--    "Turtle Bank" (Bastion Walls, Rapid Masonry, Trade Routes, Master Masons,
--    Granary Reserves) must total 8F/7B with pure Boom as its worst matchup
--    (Q3's own worked example), and 2F/1B on Granary Reserves is the unique
--    assignment that reproduces both. Asserted in CHECKS and in selftest.
-- 15. S5's "event". Q4 S5 says "per event"; D.3's Swarm note says "only one
--    free-deployment effect may fire per DEPLOY ORDER". The note is the more
--    specific gloss and is what bounds the Swarm cost stack, so: at most ONE
--    free unit per deploy order, from whichever effect fires first in
--    ascending card-id order (Endless Ranks 5 before Conscription 8). A
--    Conscription entitlement blocked by S5 is LOST, not deferred -- deferral
--    would need a pending-freebie mechanism no document describes. An Endless
--    Ranks charge is NOT consumed when the order's first unit cannot be placed
--    (supply cap), per S5's "a non-firing effect does not consume its counter".
-- 16. Conscription's counter IS sd.unitsDeployed -- "a match-long count of
--    units you have deployed" already exists as a hashed accumulator, and a
--    second copy of it would be a divergence waiting to disagree. The unit
--    being deployed is number unitsDeployed + 1.
-- 17. Counterwall. "That lane was last clear of enemy units" reads the WHOLE
--    lane, both halves -- the sentence scopes the lane, not your half of it.
--    The accumulator counts the PAID cost of each enemy unit that died past
--    its own midline (u.cost, the same field the repel refund reads), the
--    clear-transition check runs at the start of each resolve tick from the
--    tick-start board, and the burst routes through queueCredit like every
--    resolve-tick payout.
-- 18. Scorched Earth hits UNITS only -- its target clause is "the up to three
--    enemy units in that lane nearest your own keep", so the "structures take
--    the standard x0.5" sentence has nothing to apply to and is implemented as
--    dead wording (escalated in the README). Blocks clamp to blocksMax like a
--    deploy count clamps to 9. A cast into a lane with no enemy units is a
--    fizzle -- no spend, no cooldown -- matching the deploy rule that an order
--    which places nothing fizzles. The damage rides the dmgTaken channel like
--    the Trap Pit burst (Q4 S1/S2), and the wheel does not apply (item 9: the
--    wheel multiplies what a UNIT deals, and the burst is card-sourced).
-- 19. Investment matures 450 ticks after its exec tick and pays at the FIRST
--    Levy tick at or after maturity -- "credited at that Levy tick" only
--    parses if the credit waits for a Levy tick, since exec+450 is generally
--    not on the Levy grid. Fixed order inside a Levy tick: Golden Age's latch
--    check first (reading earned as it stood before the payout), then the
--    Investment payout, then income -- so Surplus and Granary Reserves read
--    the post-payout, pre-income bank, which satisfies Surplus's "before
--    income is added" literally.
-- 20. Ley Line moves units in ascending entity id, each unit moving iff the
--    destination's supply (base cost, Q4) still has room for IT -- a horse
--    that does not fit is skipped and a later spear that fits still moves.
--    source == destination, an off-board lane, or a cast that moves nothing is
--    a fizzle and does NOT consume the cooldown. A moved unit keeps its pos,
--    its Vanguard flag and its identity; it does not re-trigger deploy-time
--    effects and does not count against the destination lane's Vanguard three.
-- 21. War Drums' "any kill by any source of yours" means enemy UNIT deaths.
--    S8's attribution list (tower, trap, Ward reflect, Miasma, Scorched Earth)
--    is a list of unit-killers; razing a building is never called a kill
--    anywhere in the documents. Escalated in the README.
-- 22. Ward. "Pre-mitigation damage" = the attacker's damage after its own
--    unitDmg channel, BEFORE the structure x0.5 / dmgVsBuildings step and
--    before the wheel (the wheel is an army edge and the reflect is
--    building-sourced, item 9). "Your buildings" excludes the keep, which is
--    not a building anywhere in the catalogue. The reflect rides the dmgTaken
--    channel like every other damage source, writes into pend in the same
--    resolve phase (S9), and the no-reflect flag is structural: reflect hits
--    units, only building damage reflects, so reflected damage can never
--    reflect again by construction.
-- 23. Miasma's "x < 1000" is the CARD OWNER's frame: an enemy unit at owner-
--    frame x < 1000 is a unit past its own midline, which is IDLE_BATTLE.md's
--    "inside your half of a lane". (Iron Discipline's x < 1000 is the unit
--    OWNER's frame -- "your own half" -- so the two cards read the same words
--    in the frame of the side the card protects or punishes into.)
-- 24. Hex's schedule from tick 0 is: the debuff is live at tick t iff
--    t mod every < window -- windows [0,200), [400,600), ... A Levy tick at
--    t = 35 is inside the first window, so Hex bites from the first income.
-- 25. Deep Foundations. A hit on an immune back building is LOST -- the
--    attacker does not retarget, and a Bow's target slot is consumed -- the
--    building "cannot be damaged", not "cannot be attacked". With
--    BUILD_BLOCKS_ADVANCE the case is reachable only by an infiltrator
--    standing past a front slot that is then rebuilt (the same board as fog
--    open item 19b).
-- 26. Raiding Party's Bypass triggers at the start of a resolve tick, when any
--    Horse of yours is within its weapon range of the standing enemy front
--    building in that lane (the same envelope Sim.unitAttacks applies) --
--    "reach the enemy front slot" cannot mean standing ON it, because
--    BUILD_BLOCKS_ADVANCE parks the horse at range. The consumed flag stores
--    THAT building's entity id: those horses ignore that building for blocking
--    and targeting; a replacement built later has a new id and blocks
--    normally, which is what "once per lane per match" buys. "A building
--    stands" includes under construction (interpretation 4: it occupies, has
--    HP and blocks).
-- 27. Late Levy's gate is stored as permille of the match clock (Q11's rule
--    that every time gate is a fraction), and "after 50% of the match clock
--    (tick 3,000)" includes tick 3,000 itself: ticks 0..2999 are the first
--    half of a 6,000-tick match, so exec tick >= floor(MATCH_TICKS * 500 /
--    1000) qualifies.
-- 28. Granary Reserves' "at or above half your modified bank cap" is
--    bank * 2 >= cap, which is exact for odd caps without choosing a rounding
--    direction for "half".
-- ---------------------------------------------------------------------------

-- Registration tail (M5): hands this module to IB_SIM_MODULES when the addon
-- created it (WoW discards a chunk's return value); headless it does not
-- exist and nothing here runs. Full argument in sim/Hash.lua's tail. It adds
-- no key to M, so rulescover and rulesHash are untouched.
local IB_REG = rawget(_G, "IB_SIM_MODULES")
if IB_REG then IB_REG.Rules = M end

return M
