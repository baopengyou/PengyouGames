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

M.RULESET_VERSION = "IB-v2-M1"

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
  "MAX_UNITS_PER_ORDER", "ENFORCE_SLOT_CLASS", "BUILD_BLOCKS_ADVANCE",
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
-- 9. The Q3 type wheel scopes to UNIT damage only. Sim.unitDamage applies
--    sd.wheelNum; building damage (Arrow Tower, Watchtower) and the Trap Pit
--    burst do not. Rationale: Q3 calls the wheel a matchup edge between the two
--    ARMIES, and a tower has no type, so there is no edge to read. Recorded here
--    because it is a choice, not a reading -- M3 writes wheelNum and would
--    otherwise have to guess.
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
-- ---------------------------------------------------------------------------

return M
