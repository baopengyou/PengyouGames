-- Sim.lua -- the one deterministic simulation (Part A.1).
--
-- It covers BOTH sides symmetrically: units, buildings, both keeps, Levy, bank,
-- income, costs, per-lane supply, and the Q10 tiebreak ladder's counters. It runs
-- identically on both clients over a fully shared input set. Nothing here is
-- owner-only, and nothing here knows which side is the local player (A.2) -- the
-- two sides are indices 1 and 2 and every loop runs `for s = 1, 2`.
--
-- COORDINATES. Each side's entities carry `pos`, the distance from THAT SIDE's
-- own keep, so 0 is home and LANE_LEN is the enemy keep. Two opposing entities at
-- own-frame p and q are LANE_LEN - p - q apart, a formula that is identical from
-- either side's point of view. That symmetry is the reason the file needs no
-- notion of "my half" beyond `pos < POS_MIDLINE`, which is true for whoever asks.
--
-- TICK STRUCTURE, and this ordering is a hashed invariant, not a preference.
-- `sim.clock` is the match clock in ACTIVE sim ticks (A.9); `sim:tick()` executes
-- tick index `clock` and then advances it.
--   1 income      when clock > 0 and clock mod LEVY_EVERY == 0
--   2 commands    those whose exec tick is this tick, in canonical order (A.4):
--                 sort by (side, seq) -- side 1 is the host, side 2 the client
--   3 movement    every sim tick, SIMULTANEOUS for both sides (see phaseMove)
--   4 resolve     when clock mod RESOLVE_EVERY == 0: construction, then combat
--                 under the S9 tick-start snapshot, then deaths
--   5 bookkeeping the Q10 tier-3 depth-hold counters
--   then clock = clock + 1, and the match-clock check.
--
-- DETERMINISM RULES OBEYED HERE (they are the point of the file):
--   * integer arithmetic only; every "/" is inside a math.floor(...)
--   * no pairs(); arrays are walked with numeric for, maps are only ever indexed
--   * no math.random (see Rand.lua), no clock of any kind
--   * no table used as a key, no ordering that depends on a table address
--   * every tie breaks by lowest entity id (S10)
--
-- M3 HOOKS. Modifiers are out of scope for M1. Every place a card needs to reach
-- into is already a named call site: sim.hooks.<name>, nil by default. They are
-- listed at the bottom of this file. Adding the 40 cards must not reshape any
-- structure above.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Rand = IB_SIM_MODULES and IB_SIM_MODULES.Rand or require("sim.Rand")
local Mods = IB_SIM_MODULES and IB_SIM_MODULES.Mods or require("sim.Mods")

local floor = math.floor
local setmetatable = setmetatable

local M = {}
local Sim = {}
Sim.__index = Sim
M.Sim = Sim
M.Hash = Hash

-- Channel indices, fixed by Rules.CHANNELS order. Verified against the ruleset
-- in M.new, so a reordering there is caught immediately rather than silently
-- applying the wrong clamp.
local CH_UNITCOST, CH_UNITHP, CH_UNITDMG, CH_DMGTAKEN, CH_MARCH = 1, 2, 3, 4, 5
local CH_BLDHP, CH_BLDCOST, CH_BLDTIME = 6, 7, 8
local CH_LEVYTICK, CH_LEVYFLAT, CH_BANKCAP, CH_DMGVSBLD, CH_PRODUCTION = 9, 10, 11, 12, 13
local CH_REPELREFUND, CH_SLOTCAP = 14, 15

-- Entity kinds used by the target candidate arrays.
local K_UNIT, K_BUILDING, K_KEEP = 1, 2, 3

-- Command classes. cmd.kindIdx is cls * 100 + index, so one integer identifies
-- the verb for both dispatch and the log digest.
local CLS_UNIT, CLS_BUILD, CLS_VERB = 1, 2, 3

local UNIT_HORSE = 2
local UNIT_BOW = 3

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function clampCh(R, ch, v)
  local c = R.CLAMPS[ch]
  if v < c[1] then return c[1] end
  if v > c[2] then return c[2] end
  return v
end

-- Slot numbering: front slot of a lane is odd, back slot is even.
local function frontSlot(lane) return (lane - 1) * 2 + 1 end
local function laneOfSlot(slot) return floor((slot - 1) / 2) + 1 end
local function isFrontSlot(slot) return (slot % 2) == 1 end

local function nextId(sim)
  local id = sim.nextEntityId
  sim.nextEntityId = id + 1
  return id
end

-- ---------------------------------------------------------------------------
-- economy primitives
-- ---------------------------------------------------------------------------

local function bankCapOf(sim, sd)
  local R = sim.rules
  local base = R.C.BANK_CAP + sd.cacheBankCap
  local pts = clampCh(R, CH_BANKCAP, sd.chan[CH_BANKCAP])
  if pts == 0 then return base end
  return floor(base * (100 + pts) / 100)
end

-- Every Levy a side ever receives goes through here: income, repel refunds,
-- spoils, and (M3) Investment payouts and Plunder. `earned` is the cumulative
-- total BEFORE bank-cap clipping, which is what Golden Age's threshold reads --
-- "earned, not banked", so the threshold never interacts with the cap.
local function credit(sim, sd, amt)
  if amt <= 0 then return end
  sd.earned = sd.earned + amt
  local cap = bankCapOf(sim, sd)
  if sd.bank >= cap then
    sd.wasted = sd.wasted + amt
    return
  end
  local nb = sd.bank + amt
  if nb > cap then
    sd.wasted = sd.wasted + (nb - cap)
    nb = cap
  end
  sd.bank = nb
end

local function spend(sd, amt)
  sd.bank = sd.bank - amt
  sd.spent = sd.spent + amt
end

-- ---------------------------------------------------------------------------
-- derived stats. Every one of these is "base, plus the summed points of every
-- source in one channel, clamped once, applied once" (Q4 S2, S3, S7). Building
-- auras and modifier points travel the same path so there is only ever one
-- implementation of "something changed this number".
-- ---------------------------------------------------------------------------

local function unitCostOf(sim, sd, lane, t)
  local R = sim.rules
  local pts = sd.chan[CH_UNITCOST] + sd.lanes[lane].aura.cost[t]
  if sim.hooks.unitCostPoints then
    pts = pts + sim.hooks.unitCostPoints(sim, sd, lane, t)   -- M3: Late Levy
  end
  pts = clampCh(R, CH_UNITCOST, pts)
  local c = R.UNITS[t].cost
  if pts ~= 0 then c = floor(c * (100 + pts) / 100) end
  if c < 1 then c = 1 end  -- absolute floor of 1 Levy (Q4 S4)
  return c
end

local function unitHpOf(sim, sd, t)
  local R = sim.rules
  local pts = sd.chan[CH_UNITHP]
  if sim.hooks.unitHpPoints then
    pts = pts + sim.hooks.unitHpPoints(sim, sd, t)   -- M3: Bulwark Line, Chaff
  end
  pts = clampCh(R, CH_UNITHP, pts)
  local hp = R.UNITS[t].hp
  if pts ~= 0 then hp = floor(hp * (100 + pts) / 100) end
  if hp < 1 then hp = 1 end
  return hp
end

local function marchOf(sim, sd, u)
  local R = sim.rules
  local pts = sd.chan[CH_MARCH] + sd.lanes[u.lane].aura.march
  if sim.hooks.marchPoints then
    pts = pts + sim.hooks.marchPoints(sim, sd, u)    -- M3: Raiding Party (Horse)
  end
  pts = clampCh(R, CH_MARCH, pts)
  local m = R.UNITS[u.t].march
  if pts ~= 0 then m = floor(m * (100 + pts) / 100) end
  if m < 1 then m = 1 end
  return m
end

local function unitRangeOf(sim, sd, u)
  local r = sim.rules.UNITS[u.t].range
  if u.t == UNIT_BOW then r = r + sd.lanes[u.lane].aura.bowRange end  -- Fletcher
  return r
end

-- Defender-side mitigation. Redoubt and Iron Discipline are both scoped to the
-- defender's own half, read from the tick-start position (S9): during a resolve
-- phase nothing moves, so `pos` IS the tick-start value.
local function dmgTakenPts(sim, sd, u)
  local pts = sd.chan[CH_DMGTAKEN]
  if u.pos < sim.rules.C.POS_MIDLINE then
    pts = pts + sd.lanes[u.lane].aura.dmgTaken
  end
  if sim.hooks.dmgTakenPoints then
    pts = pts + sim.hooks.dmgTakenPoints(sim, sd, u) -- M3: Iron Discipline
  end
  return clampCh(sim.rules, CH_DMGTAKEN, pts)
end

local function slotCapOf(sim, sd)
  local R = sim.rules
  return clampCh(R, CH_SLOTCAP, R.C.SLOT_CAP + sd.chan[CH_SLOTCAP])  -- Boomtown
end

local function bldCostOf(sim, sd, slot, bi)
  local R = sim.rules
  local pts = sd.chan[CH_BLDCOST]
  if sd.rubble[slot] == 1 and sim.hooks.rubbleCostPoints then
    pts = pts + sim.hooks.rubbleCostPoints(sim, sd, slot)  -- M3: Rapid Masonry
  end
  pts = clampCh(R, CH_BLDCOST, pts)
  local c = R.BUILDINGS[bi].cost
  if pts ~= 0 then c = floor(c * (100 + pts) / 100) end
  if c < 1 then c = 1 end
  return c
end

local function bldHpOf(sim, sd, bi)
  local R = sim.rules
  local pts = sd.chan[CH_BLDHP]
  if sim.hooks.bldHpPoints then
    pts = pts + sim.hooks.bldHpPoints(sim, sd, bi)  -- M3: Bastion Walls, Rickety
  end
  pts = clampCh(R, CH_BLDHP, pts)
  local hp = R.BUILDINGS[bi].hp
  if pts ~= 0 then hp = floor(hp * (100 + pts) / 100) end
  if hp < 1 then hp = 1 end
  return hp
end

local function bldTimeOf(sim, sd, bi)
  local R = sim.rules
  local pts = clampCh(R, CH_BLDTIME, sd.chan[CH_BLDTIME])
  local n = R.BUILDINGS[bi].build
  if pts ~= 0 then n = floor(n * (100 + pts) / 100) end
  if n < 1 then n = 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- lane auras and flat yields, recomputed only when a building completes or dies
-- ---------------------------------------------------------------------------

local function recomputeSideDerived(sim, sd)
  local R, C = sim.rules, sim.rules.C
  sd.cacheLevyFlat = 0
  sd.cacheBankCap = 0
  for lane = 1, C.LANES do
    local a = sd.lanes[lane].aura
    a.unitDmg = 0; a.dmgTaken = 0; a.march = 0; a.bowRange = 0
    a.cost[1] = 0; a.cost[2] = 0; a.cost[3] = 0
    local fs = frontSlot(lane)
    for k = 0, 1 do
      local b = sd.slots[fs + k]
      if b and b.done == 1 then
        local br = R.BUILDINGS[b.b]
        a.unitDmg = a.unitDmg + br.auraUnitDmg
        a.dmgTaken = a.dmgTaken + br.auraDmgTaken
        a.march = a.march + br.auraMarch
        a.bowRange = a.bowRange + br.auraBowRange
        if br.auraCostUnit > 0 then
          a.cost[br.auraCostUnit] = a.cost[br.auraCostUnit] + br.auraCostPct
        end
        sd.cacheLevyFlat = sd.cacheLevyFlat + br.levyFlat
        sd.cacheBankCap = sd.cacheBankCap + br.bankCapFlat
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- construction of a side
-- ---------------------------------------------------------------------------

local function newSide(sim, index, loadout)
  local R, C = sim.rules, sim.rules.C
  local sd = {
    index = index,
    loadout = {},
    bank = 0, earned = 0, wasted = 0, spent = 0,
    keepId = 0, keepHp = C.KEEP_HP,
    keepPend = 0, keepPendSrc = 0,
    keepDamageDealt = 0,   -- Q10 tier 1: HP removed from the ENEMY keep, cumulative
    slotsDestroyed = 0,    -- Q10 tier 2: enemy building slots destroyed, cumulative
    unitsDeployed = 0, unitsLost = 0, unitsKilled = 0, bldLost = 0,
    cmdsExecuted = 0, cmdsFizzled = 0,
    wheelNum = 0,          -- Q3 edge numerator in [-225, 225]; M3 computes it
    -- DERIVED CACHES, not owned state. The `cache` prefix is load-bearing: these
    -- and lanes[n].aura are pure functions of the slots and are deliberately NOT
    -- in the state hash, because hashing a value you can re-derive hides a stale
    -- cache rather than exposing it. harness/runner.lua's `invariants` re-derives
    -- all of them from the hashed state and is the only thing that can catch a
    -- missed recomputeSideDerived call -- which is why the M1 gate has to run it.
    cacheLevyFlat = 0, cacheBankCap = 0,
    chan = {}, lanes = {}, slots = {}, rubble = {}, unlocks = {},
    mods = {}, modsOrder = {},
  }
  for i = 1, 5 do
    sd.loadout[i] = (loadout and loadout[i]) or 0
  end
  for i = 1, #R.CHANNELS do sd.chan[i] = 0 end
  for lane = 1, C.LANES do
    sd.lanes[lane] = {
      units = {},
      supply = 0,        -- Levy of living units, charged at BASE cost (Q4)
      depth = 0,         -- Q10 tier 3, latched 0 to 3
      hold1 = 0, hold2 = 0, hold3 = 0,
      muster = 0,        -- M3: Endless Ranks charges, max 3
      bypass = 0,        -- M3: Raiding Party, one per lane per match
      cwAcc = 0,         -- M3: Counterwall accumulator
      aura = { unitDmg = 0, dmgTaken = 0, march = 0, bowRange = 0, cost = { 0, 0, 0 } },
    }
  end
  for s = 1, C.SLOTS do sd.slots[s] = false; sd.rubble[s] = 0 end
  for b = 1, #R.BUILDINGS do sd.unlocks[b] = 0 end
  return sd
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

-- Canonical intra-tick order (A.4): by side (1 = host, 2 = client), then seq.
local function bucketInsert(b, c)
  local i = #b
  while i >= 1 do
    local o = b[i]
    if o.side < c.side or (o.side == c.side and o.seq < c.seq) then break end
    b[i + 1] = o
    i = i - 1
  end
  b[i + 1] = c
end

-- Whole-match log order for the digest: by exec tick, then side, then seq.
local function logInsert(log, c)
  local i = #log
  while i >= 1 do
    local o = log[i]
    if o.tick < c.tick
      or (o.tick == c.tick and (o.side < c.side or (o.side == c.side and o.seq < c.seq))) then
      break
    end
    log[i + 1] = o
    i = i - 1
  end
  log[i + 1] = c
end

local function newUnit(sim, sd, lane, t, paid)
  local u = {
    id = nextId(sim),
    t = t,
    lane = lane,
    pos = sim.rules.C.POS_OWN_KEEP,
    hp = 0, maxHp = 0,
    cost = paid,   -- Levy ACTUALLY paid; repel refund reads this, not the base
    vg = 0,        -- M3: Vanguard flag
    snapHp = 0, pend = 0, pendSrc = 0,
    step = 0,      -- transient: this tick's intended movement, always 0 between ticks
  }
  local hp = unitHpOf(sim, sd, t)
  u.hp = hp
  u.maxHp = hp
  return u
end

local function execDeploy(sim, sd, c)
  local R, C = sim.rules, sim.rules.C
  local lane = c.target
  local t = c.kindIdx - CLS_UNIT * 100
  if lane < 1 or lane > C.LANES or t < 1 or t > #R.UNITS then
    sd.cmdsFizzled = sd.cmdsFizzled + 1
    return
  end
  local n = c.count
  if n > C.MAX_UNITS_PER_ORDER then n = C.MAX_UNITS_PER_ORDER end
  local ln = sd.lanes[lane]
  local baseCost = R.UNITS[t].cost
  local us = ln.units
  local placed = 0
  for i = 1, n do
    local cost = unitCostOf(sim, sd, lane, t)
    if sim.hooks.deployCost then
      -- M3: Conscription and Endless Ranks arbitrate here; S5 allows at most one
      -- free-deployment effect per order, so the hook owns that decision.
      cost = sim.hooks.deployCost(sim, sd, lane, t, cost, i)
    end
    -- Supply is charged at BASE cost and is immune to every modifier (Q4): a
    -- cost discount buys flow, never a bigger stack.
    if sd.bank < cost or ln.supply + baseCost > C.LANE_SUPPLY_CAP then break end
    spend(sd, cost)
    ln.supply = ln.supply + baseCost
    local u = newUnit(sim, sd, lane, t, cost)
    us[#us + 1] = u
    sd.unitsDeployed = sd.unitsDeployed + 1
    if sim.hooks.onDeploy then sim.hooks.onDeploy(sim, sd, u) end  -- M3: Vanguard
    placed = placed + 1
  end
  if placed == 0 then
    sd.cmdsFizzled = sd.cmdsFizzled + 1
  else
    sd.cmdsExecuted = sd.cmdsExecuted + 1
  end
end

local function occupiedSlots(sd, nslots)
  local n = 0
  for s = 1, nslots do
    if sd.slots[s] then n = n + 1 end
  end
  return n
end

local function execBuild(sim, sd, c)
  local R, C = sim.rules, sim.rules.C
  local slot = c.target
  local bi = c.kindIdx - CLS_BUILD * 100
  if slot < 1 or slot > C.SLOTS or bi < 1 or bi > #R.BUILDINGS then
    sd.cmdsFizzled = sd.cmdsFizzled + 1
    return
  end
  local br = R.BUILDINGS[bi]
  local ok = true
  if sd.slots[slot] then ok = false end
  if ok and C.ENFORCE_SLOT_CLASS == 1 then
    local front = isFrontSlot(slot)
    if (br.slotClass == "front") ~= front then ok = false end
  end
  if ok and br.cardGated == 1 and sd.unlocks[bi] == 0 then ok = false end
  if ok and occupiedSlots(sd, C.SLOTS) >= slotCapOf(sim, sd) then ok = false end
  local cost = 0
  if ok then
    cost = bldCostOf(sim, sd, slot, bi)
    if sd.bank < cost then ok = false end
  end
  if not ok then
    sd.cmdsFizzled = sd.cmdsFizzled + 1
    return
  end
  spend(sd, cost)
  local hp = bldHpOf(sim, sd, bi)
  sd.slots[slot] = {
    id = nextId(sim),
    b = bi,
    slot = slot,
    lane = laneOfSlot(slot),
    hp = hp, maxHp = hp,
    cost = cost,
    prog = 0,
    -- WHY: commands execute BEFORE phaseResolve inside the same tick (Sim:tick),
    -- and a resolve pass credits the RESOLVE_EVERY ticks that have just elapsed.
    -- A building created during THIS tick's command phase performed none of them,
    -- so without this stamp it would be paid for construction it never did --
    -- a full resolve tick early whenever the exec tick is a multiple of 5, which
    -- is the DEFAULT case (ORDER_DELAY 20 is itself a multiple of 5).
    startTick = sim.clock,
    need = bldTimeOf(sim, sd, bi),
    done = 0,
    spent = 0,   -- Trap Pit one-shot burst consumed
    snapHp = 0, pend = 0, pendSrc = 0,
  }
  -- The Rubble mark is consumed by placing into the slot (M3, Rapid Masonry).
  sd.rubble[slot] = 0
  sd.cmdsExecuted = sd.cmdsExecuted + 1
end

local function execCommand(sim, c)
  local sd = sim.sides[c.side]
  if c.cls == CLS_UNIT then
    execDeploy(sim, sd, c)
  elseif c.cls == CLS_BUILD then
    execBuild(sim, sd, c)
  else
    -- M3 verbs: I Investment, E Scorched Earth, L Ley Line. Until they exist a
    -- verb is a defined no-op, counted as a fizzle so the hash still moves.
    if sim.hooks.execVerb then
      sim.hooks.execVerb(sim, sd, c)
    else
      sd.cmdsFizzled = sd.cmdsFizzled + 1
    end
  end
end

-- ---------------------------------------------------------------------------
-- target candidates
--
-- Everything a side can bump into down one lane, in the ORDER IT SITS ON THE
-- AXIS: the enemy's units first (they are between us), then the enemy's front
-- slot, then its back slot, then its keep. `cg` is the candidate's position
-- measured in the ASKING side's frame, so a unit at own-frame p is `cg - p`
-- away. That is the front-then-back-then-keep ordering the design asks for, and
-- it falls out of the geometry rather than being coded as a special case.
-- ---------------------------------------------------------------------------

local function buildCands(sim, es, lane)
  local C = sim.rules.C
  local L = C.LANE_LEN
  local cg, ci, cr, ck = sim.cg, sim.ci, sim.cr, sim.ck
  local n = 0
  local us = es.lanes[lane].units
  for i = 1, #us do
    local u = us[i]
    n = n + 1
    cg[n] = L - u.pos; ci[n] = u.id; cr[n] = u; ck[n] = K_UNIT
  end
  if C.BUILD_BLOCKS_ADVANCE == 1 then
    local fs = frontSlot(lane)
    local b = es.slots[fs]
    if b then
      n = n + 1
      cg[n] = L - C.POS_FRONT_SLOT; ci[n] = b.id; cr[n] = b; ck[n] = K_BUILDING
    end
    b = es.slots[fs + 1]
    if b then
      n = n + 1
      cg[n] = L - C.POS_BACK_SLOT; ci[n] = b.id; cr[n] = b; ck[n] = K_BUILDING
    end
  end
  n = n + 1
  cg[n] = L - C.POS_OWN_KEEP; ci[n] = es.keepId; cr[n] = es; ck[n] = K_KEEP
  sim.cn = n
end

-- ---------------------------------------------------------------------------
-- movement
-- ---------------------------------------------------------------------------

-- Movement is SIMULTANEOUS, in two passes: every unit's step is computed from
-- the tick-start positions, then every step is applied. Moving side 1 first and
-- side 2 second would let side 2 read positions side 1 had already updated,
-- which is a real host-versus-client asymmetry -- deterministic, but not
-- side-agnostic (A.2). Two passes cost one extra field and remove it.
--
-- Positions can never cross under this rule: a step is capped both by the gap to
-- the target minus range AND by march speed (at most 20), so two units closing
-- on each other can at worst end up slightly inside range, never past one
-- another.
local function phaseMove(sim)
  local C = sim.rules.C
  for s = 1, 2 do
    local sd = sim.sides[s]
    local es = sim.sides[3 - s]
    for lane = 1, C.LANES do
      local us = sd.lanes[lane].units
      local nu = #us
      if nu > 0 then
        buildCands(sim, es, lane)
        local cg, ci, cn = sim.cg, sim.ci, sim.cn
        -- M3 Raiding Party: a consumed Bypass flag holds the entity id of the
        -- one enemy front building this side's HORSES walk past rather than
        -- engage. 0 (the default, and the whole of M1) matches no candidate.
        local byp = sd.lanes[lane].bypass
        for i = 1, nu do
          local u = us[i]
          local p = u.pos
          u.step = 0
          local skipId = 0
          if byp ~= 0 and u.t == UNIT_HORSE then skipId = byp end
          -- Nearest thing ahead: smallest cg not behind us, ties by lowest id.
          local bg, bid = -1, 0
          for k = 1, cn do
            local g = cg[k]
            if ci[k] ~= skipId and g >= p and (bg < 0 or g < bg or (g == bg and ci[k] < bid)) then
              bg = g; bid = ci[k]
            end
          end
          if bg >= 0 then
            local gap = bg - p - unitRangeOf(sim, sd, u)
            if gap > 0 then
              local m = marchOf(sim, sd, u)
              if m > gap then m = gap end   -- never walk through the target
              u.step = m
            end
          end
        end
      end
    end
  end
  for s = 1, 2 do
    local sd = sim.sides[s]
    for lane = 1, C.LANES do
      local us = sd.lanes[lane].units
      for i = 1, #us do
        local u = us[i]
        if u.step ~= 0 then u.pos = u.pos + u.step; u.step = 0 end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- damage accumulation. Nothing below writes hp: every source adds into `pend`
-- and reads `snapHp` and `pos` from the tick-start snapshot (S9). That is what
-- makes mutual kills symmetric, and what makes No Retreat, Tide of Bodies, Iron
-- Discipline and Ward deterministic for free when M3 arrives.
-- ---------------------------------------------------------------------------

local function addDamage(kind, ref, amt, srcId)
  if amt <= 0 then return end
  if kind == K_KEEP then
    ref.keepPend = ref.keepPend + amt
    if ref.keepPendSrc == 0 or srcId < ref.keepPendSrc then ref.keepPendSrc = srcId end
  else
    ref.pend = ref.pend + amt
    if ref.pendSrc == 0 or srcId < ref.pendSrc then ref.pendSrc = srcId end
  end
end

-- Damage from a unit of `sd` into one target. `es` owns the target.
local function unitDamage(sim, sd, es, u, kind, ref)
  local R, C = sim.rules, sim.rules.C
  local ub = R.UNITS[u.t]
  local d = ub.dmg
  local pts = sd.chan[CH_UNITDMG] + sd.lanes[u.lane].aura.unitDmg
  if sim.hooks.unitDmgPoints then
    -- M3: Tide of Bodies, War Drums, Vanguard, No Retreat all add points here and
    -- are clamped together exactly once (S2). None of them may floor separately.
    pts = pts + sim.hooks.unitDmgPoints(sim, sd, u)
  end
  pts = clampCh(R, CH_UNITDMG, pts)
  if pts ~= 0 then d = floor(d * (100 + pts) / 100) end
  if kind == K_UNIT then
    if ub.prey == ref.t then d = floor(d * C.COUNTER_PCT / 100) end
    local m = dmgTakenPts(sim, es, ref)
    if m ~= 0 then d = floor(d * (100 + m) / 100) end
  else
    -- All units deal half damage to every structure, keep included; Sappers
    -- takes the dmgVsBuildings channel to +100 and that back to full.
    if kind == K_BUILDING and sim.hooks.onStructHit then
      -- M3: Ward. The reflect reads the PRE-mitigation figure -- after the
      -- attacker's own unitDmg channel, before the structure step and the
      -- wheel (INTERPRETATIONS 22) -- and writes into pend like every other
      -- source, so it rides the same tick-start snapshot (S9).
      sim.hooks.onStructHit(sim, sd, es, u, ref, d)
    end
    local dvb = clampCh(R, CH_DMGVSBLD, sd.chan[CH_DMGVSBLD])
    d = floor(d * C.STRUCTURE_DMG_PCT * (100 + dvb) / 10000)
  end
  if sd.wheelNum ~= 0 then
    -- Q3 and Q12: the wheel is a single final multiplier, after and OUTSIDE
    -- every clamp. Held as an integer numerator so no fraction exists.
    local den = C.WHEEL_EDGE_DEN * 1000
    d = floor(d * (den + C.WHEEL_K_PERMILLE * sd.wheelNum) / den)
  end
  return d
end

local function unitAttacks(sim, s)
  local C = sim.rules.C
  local R = sim.rules
  local sd = sim.sides[s]
  local es = sim.sides[3 - s]
  for lane = 1, C.LANES do
    local us = sd.lanes[lane].units
    local nu = #us
    if nu > 0 then
      buildCands(sim, es, lane)
      local cg, ci, cr, ck, cn, cm = sim.cg, sim.ci, sim.cr, sim.ck, sim.cn, sim.cm
      local byp = sd.lanes[lane].bypass   -- M3 Raiding Party; 0 in M1, matches nothing
      -- M3 Deep Foundations: a hit chosen onto an immune back building is
      -- LOST -- the attacker does not retarget and a Bow's target slot is
      -- consumed (INTERPRETATIONS 25). The guard sits between target choice
      -- and damage so "cannot be damaged" never becomes "cannot be attacked".
      local immune = sim.hooks.bldImmune
      for i = 1, nu do
        local u = us[i]
        if u.snapHp > 0 then
          local p = u.pos
          local range = unitRangeOf(sim, sd, u)
          local nt = R.UNITS[u.t].targets
          local skipId = 0
          if byp ~= 0 and u.t == UNIT_HORSE then skipId = byp end
          if nt == 1 then
            local bk, bd = 0, -1
            for k = 1, cn do
              if ci[k] ~= skipId then
                local g = cg[k] - p
                if g < 0 then g = -g end
                if g <= range and (bk == 0 or g < bd or (g == bd and ci[k] < ci[bk])) then
                  bk = k; bd = g
                end
              end
            end
            if bk ~= 0 then
              if ck[bk] == K_BUILDING and immune and immune(sim, es, cr[bk]) then
                -- the swing lands on Deep Foundations and removes nothing
              else
                addDamage(ck[bk], cr[bk], unitDamage(sim, sd, es, u, ck[bk], cr[bk]), u.id)
              end
            end
          else
            -- Bow hits up to 3. Multi-target is structural, not decorative: it is
            -- the only thing that makes "strong versus massed cheap units" exist.
            local mk = sim.markSeq + 1
            sim.markSeq = mk
            for _ = 1, nt do
              local bk, bd = 0, -1
              for k = 1, cn do
                if cm[k] ~= mk and ci[k] ~= skipId then
                  local g = cg[k] - p
                  if g < 0 then g = -g end
                  if g <= range and (bk == 0 or g < bd or (g == bd and ci[k] < ci[bk])) then
                    bk = k; bd = g
                  end
                end
              end
              if bk == 0 then break end
              cm[bk] = mk
              if ck[bk] == K_BUILDING and immune and immune(sim, es, cr[bk]) then
                -- the arrow lands on Deep Foundations and removes nothing
              else
                addDamage(ck[bk], cr[bk], unitDamage(sim, sd, es, u, ck[bk], cr[bk]), u.id)
              end
            end
          end
        end
      end
    end
  end
end

local function buildingAttacks(sim, s)
  local R, C = sim.rules, sim.rules.C
  local sd = sim.sides[s]
  local es = sim.sides[3 - s]
  local L = C.LANE_LEN
  for slot = 1, C.SLOTS do
    local b = sd.slots[slot]
    if b and b.done == 1 and b.snapHp > 0 then
      local br = R.BUILDINGS[b.b]
      if br.dmg > 0 then
        local myPos = isFrontSlot(slot) and C.POS_FRONT_SLOT or C.POS_BACK_SLOT
        local range = br.dmgRange
        if sim.hooks.bldRangePoints then
          -- M3: Watchfires, +50 percent damage range on defensive buildings.
          range = range + sim.hooks.bldRangePoints(sim, sd, b)
        end
        local us = es.lanes[b.lane].units
        local bu, bd = nil, -1
        for i = 1, #us do
          local u = us[i]
          if u.snapHp > 0 then
            local g = (L - u.pos) - myPos
            if g < 0 then g = -g end
            if g <= range and (bu == nil or g < bd or (g == bd and u.id < bu.id)) then
              bu = u; bd = g
            end
          end
        end
        if bu ~= nil then
          local d = br.dmg
          local m = dmgTakenPts(sim, es, bu)
          if m ~= 0 then d = floor(d * (100 + m) / 100) end
          -- Kill attribution for non-unit damage credits the OWNER (S8), which
          -- is what lets Blood Tithe and War Drums fire off a tower kill.
          addDamage(K_UNIT, bu, d, b.id)
        end
      end
    end
  end
end

local function trapAttacks(sim, s)
  local R, C = sim.rules, sim.rules.C
  local sd = sim.sides[s]
  local es = sim.sides[3 - s]
  local L = C.LANE_LEN
  for slot = 1, C.SLOTS do
    local b = sd.slots[slot]
    if b and b.done == 1 and b.spent == 0 and b.snapHp > 0 then
      local br = R.BUILDINGS[b.b]
      if br.trapBurst > 0 then
        local myPos = isFrontSlot(slot) and C.POS_FRONT_SLOT or C.POS_BACK_SLOT
        local us = es.lanes[b.lane].units
        -- Collect everything inside the trigger radius, nearest first, ties by
        -- lowest id (S10). This runs at most once per pit per match.
        local hits, nh = {}, 0
        for i = 1, #us do
          local u = us[i]
          if u.snapHp > 0 then
            local g = (L - u.pos) - myPos
            if g < 0 then g = -g end
            if g <= br.trapRadius then
              nh = nh + 1
              local j = nh - 1
              while j >= 1 and (hits[j].d > g or (hits[j].d == g and hits[j].u.id > u.id)) do
                hits[j + 1] = hits[j]; j = j - 1
              end
              hits[j + 1] = { d = g, u = u }
            end
          end
        end
        if nh > 0 then
          local budget = br.trapBurst
          local left = br.trapTargets
          local fired = false
          for i = 1, nh do
            if budget <= 0 or left <= 0 then break end
            local u = hits[i].u
            -- NO OVERKILL: cap at this target's remaining HP before moving on.
            -- C.4 flags this as a real defect if skipped -- a burst meant to
            -- punish massed cheap units is otherwise wasted on the first three.
            local room = u.snapHp - u.pend
            if room > 0 then
              local d = br.trapPerTarget
              if d > budget then d = budget end
              -- The burst is damage TAKEN, so it rides the dmgTaken channel like
              -- every other source (Q4 S1/S2); Redoubt, Iron Discipline and any
              -- future dmgTaken debuff must reach it. Mitigation is applied
              -- BEFORE the no-overkill cap because that cap bounds HP ACTUALLY
              -- removed -- against a mitigated target the pit must not spend
              -- burst it never deals.
              local m = dmgTakenPts(sim, es, u)
              if m ~= 0 then d = floor(d * (100 + m) / 100) end
              if d > room then d = room end
              addDamage(K_UNIT, u, d, b.id)
              budget = budget - d
              left = left - 1
              fired = true
            end
          end
          -- Spent only if the burst actually landed: a pit whose only candidates
          -- were already dead this tick has not fired.
          if fired then b.spent = 1 end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- deaths
-- ---------------------------------------------------------------------------

-- A.2: a credit is CLIPPED against the RECEIVER's bank cap, and a building that
-- dies on this same resolve tick changes that cap. Paying inside the `for s = 1, 2`
-- walk of applyDamage clips side 2's Levy against its PRE-destruction cap and
-- side 1's against its POST-destruction one, purely because of loop order --
-- which hands the client a measurable edge in an otherwise identical position.
-- Park every credit and pay them all once both sides' cacheBankCap values are
-- current.
--
-- M3 NOTE: every future Levy payout that can fire during a resolve tick (Blood
-- Tithe, Plunder, Counterwall) must route through queueCredit for the same
-- reason, or it reintroduces the ordering.
local function queueCredit(sim, sd, amt)
  if amt <= 0 then return end
  local n = sim.qcN + 1
  sim.qcN = n
  sim.qcSide[n] = sd.index          -- the INDEX, never the table (determinism rule 6)
  sim.qcAmt[n] = amt
end

-- Order inside the flush is collection order, which is deterministic and now
-- harmless: a credit cannot move a bank cap, so every credit here sees the same
-- final caps regardless of its position in the queue.
local function flushCredits(sim)
  for i = 1, sim.qcN do
    credit(sim, sim.sides[sim.qcSide[i]], sim.qcAmt[i])
  end
  sim.qcN = 0
end

local function onUnitDeath(sim, sd, es, ln, u)
  local R, C = sim.rules, sim.rules.C
  sd.unitsLost = sd.unitsLost + 1
  es.unitsKilled = es.unitsKilled + 1
  ln.supply = ln.supply - R.UNITS[u.t].cost
  if ln.supply < 0 then ln.supply = 0 end
  -- Repel refund: the unit died inside the OTHER side's own half, which in this
  -- unit's own frame means it had crossed the midline.
  if u.pos > C.POS_MIDLINE then
    local pts = clampCh(R, CH_REPELREFUND, es.chan[CH_REPELREFUND])
    local amt = floor(u.cost * (C.REPEL_REFUND_PCT + pts) / 100)
    queueCredit(sim, es, amt)
  end
  if sim.hooks.onUnitDeath then
    -- M3: Blood Tithe, Counterwall's accumulator, Endless Ranks' muster charge.
    sim.hooks.onUnitDeath(sim, sd, es, u)
  end
end

local function onBuildingDestroyed(sim, sd, es, slot, b)
  local C = sim.rules.C
  sd.slots[slot] = false
  sd.bldLost = sd.bldLost + 1
  sd.rubble[slot] = 1                      -- M3: Rapid Masonry mark
  es.slotsDestroyed = es.slotsDestroyed + 1  -- Q10 tier 2
  local amt = floor(b.cost * C.SPOILS_PCT / 100)  -- Q1 Spoils, the offence dial
  if sim.hooks.onBuildingDestroyed then
    -- M3: Plunder REPLACES the spoils baseline rather than stacking with it.
    amt = sim.hooks.onBuildingDestroyed(sim, sd, es, b, amt)
  end
  queueCredit(sim, es, amt)
  recomputeSideDerived(sim, sd)
end

local function finish(sim, winner, reasonCode, reason, tier)
  sim.over = true
  sim.winner = winner
  sim.reasonCode = reasonCode
  sim.reason = reason
  sim.tier = tier
end

local function applyDamage(sim)
  local C = sim.rules.C
  local down1, down2 = false, false
  for s = 1, 2 do
    local sd = sim.sides[s]
    local es = sim.sides[3 - s]
    if sd.keepPend > 0 then
      local d = sd.keepPend
      if d > sd.keepHp then d = sd.keepHp end
      sd.keepHp = sd.keepHp - d
      es.keepDamageDealt = es.keepDamageDealt + d   -- Q10 tier 1, cumulative
      if sd.keepHp <= 0 then
        if s == 1 then down1 = true else down2 = true end
      end
    end
  end
  for s = 1, 2 do
    local sd = sim.sides[s]
    local es = sim.sides[3 - s]
    for lane = 1, C.LANES do
      local ln = sd.lanes[lane]
      local us = ln.units
      local n = #us
      local w = 0
      for i = 1, n do
        local u = us[i]
        if u.pend > 0 then u.hp = u.hp - u.pend end
        if u.hp <= 0 then
          onUnitDeath(sim, sd, es, ln, u)
        else
          w = w + 1
          if w ~= i then us[w] = u end
        end
      end
      for i = n, w + 1, -1 do us[i] = nil end
    end
    for slot = 1, C.SLOTS do
      local b = sd.slots[slot]
      if b then
        if b.pend > 0 then b.hp = b.hp - b.pend end
        if b.hp <= 0 then onBuildingDestroyed(sim, sd, es, slot, b) end
      end
    end
  end
  -- Both sides' derived caches are current now, so the parked Levy can be paid
  -- and every credit is clipped against the SAME post-destruction caps (A.2).
  flushCredits(sim)
  -- Both keeps can fall on the same resolve tick under the snapshot rule. That
  -- is a draw, not a win for whichever side the loop happened to visit second.
  if down1 and down2 then
    finish(sim, 0, sim.rules.REASON.KEEP, "keep", 0)
  elseif down1 then
    finish(sim, 2, sim.rules.REASON.KEEP, "keep", 0)
  elseif down2 then
    finish(sim, 1, sim.rules.REASON.KEEP, "keep", 0)
  end
end

-- ---------------------------------------------------------------------------
-- phases
-- ---------------------------------------------------------------------------

local function phaseIncome(sim)
  local R, C = sim.rules, sim.rules.C
  for s = 1, 2 do
    local sd = sim.sides[s]
    if sim.hooks.onLevyTickStart then
      -- M3: Golden Age latch, Surplus, Granary Reserves, Trade Routes, Hex, and
      -- the Investment countdown all evaluate at the start of a Levy tick.
      sim.hooks.onLevyTickStart(sim, sd)
    end
    local flat = sd.cacheLevyFlat
    local prod = clampCh(R, CH_PRODUCTION, sd.chan[CH_PRODUCTION])  -- Master Masons
    if prod ~= 0 then flat = floor(flat * (100 + prod) / 100) end
    local mflat = sd.chan[CH_LEVYFLAT]
    if sim.hooks.levyFlatPoints then
      -- M3: Trade Routes and Surplus join the levyFlat channel sum here and
      -- are clamped with it, once (S2).
      mflat = mflat + sim.hooks.levyFlatPoints(sim, sd)
    end
    local amt = C.BASE_INCOME + flat + clampCh(R, CH_LEVYFLAT, mflat)
    local pts = sd.chan[CH_LEVYTICK]
    if sim.hooks.levyTickPoints then
      -- M3: Golden Age's latched bonus, Granary Reserves' conditional bonus
      -- and Hex's windowed debuff -- ordinary points in the levyTick channel,
      -- summed with the static ones and clamped once (S2).
      pts = pts + sim.hooks.levyTickPoints(sim, sd)
    end
    pts = clampCh(R, CH_LEVYTICK, pts)
    if pts ~= 0 then amt = floor(amt * (100 + pts) / 100) end
    if amt < 0 then amt = 0 end
    credit(sim, sd, amt)
  end
end

local function phaseResolve(sim)
  local C = sim.rules.C
  -- construction
  for s = 1, 2 do
    local sd = sim.sides[s]
    local completed = false
    for slot = 1, C.SLOTS do
      local b = sd.slots[slot]
      -- sim.clock is still this tick's index during the phases (it is advanced
      -- after them), so the guard is false ONLY on the placement tick.
      if b and b.done == 0 and sim.clock > b.startTick then
        b.prog = b.prog + C.RESOLVE_EVERY
        if b.prog >= b.need then
          b.done = 1
          completed = true
        end
      end
    end
    if completed then recomputeSideDerived(sim, sd) end
  end
  -- tick-start snapshot (S9)
  for s = 1, 2 do
    local sd = sim.sides[s]
    sd.keepPend = 0
    sd.keepPendSrc = 0
    for lane = 1, C.LANES do
      local us = sd.lanes[lane].units
      for i = 1, #us do
        local u = us[i]
        u.snapHp = u.hp; u.pend = 0; u.pendSrc = 0
      end
    end
    for slot = 1, C.SLOTS do
      local b = sd.slots[slot]
      if b then b.snapHp = b.hp; b.pend = 0; b.pendSrc = 0 end
    end
  end
  if sim.hooks.onResolveStart then
    -- M3: Tide of Bodies counts, War Drums expiry, Vanguard bookkeeping.
    sim.hooks.onResolveStart(sim)
  end
  -- accumulation, in a fixed source order
  trapAttacks(sim, 1); trapAttacks(sim, 2)
  buildingAttacks(sim, 1); buildingAttacks(sim, 2)
  unitAttacks(sim, 1); unitAttacks(sim, 2)
  if sim.hooks.onExtraDamage then
    -- M3: Miasma decay, Ward reflect. Both must write into `pend` like everyone
    -- else so they read the same snapshot.
    sim.hooks.onExtraDamage(sim)
  end
  applyDamage(sim)
end

-- Q10 tier 3. "Greatest depth ever HELD for at least 50 sim ticks" -- read as
-- 50 CONSECUTIVE ticks, so a unit that touches a band and dies immediately banks
-- nothing. Never a final-tick snapshot.
local function phaseBookkeeping(sim)
  local C = sim.rules.C
  for s = 1, 2 do
    local sd = sim.sides[s]
    for lane = 1, C.LANES do
      local ln = sd.lanes[lane]
      local us = ln.units
      local mx = -1
      for i = 1, #us do
        local p = us[i].pos
        if p > mx then mx = p end
      end
      if mx >= C.DEPTH_X1 then
        ln.hold1 = ln.hold1 + 1
        if ln.hold1 >= C.DEPTH_HOLD_TICKS and ln.depth < 1 then ln.depth = 1 end
      else
        ln.hold1 = 0
      end
      if mx >= C.DEPTH_X2 then
        ln.hold2 = ln.hold2 + 1
        if ln.hold2 >= C.DEPTH_HOLD_TICKS and ln.depth < 2 then ln.depth = 2 end
      else
        ln.hold2 = 0
      end
      if mx >= C.DEPTH_X3 then
        ln.hold3 = ln.hold3 + 1
        if ln.hold3 >= C.DEPTH_HOLD_TICKS and ln.depth < 3 then ln.depth = 3 end
      else
        ln.hold3 = 0
      end
    end
  end
end

local function depthSum(sim, sd)
  local n = 0
  for lane = 1, sim.rules.C.LANES do n = n + sd.lanes[lane].depth end
  return n
end

-- Q10: on the clock, the player who came closer to winning wins. Evaluate in
-- order, first non-tie decides. Unit kills are deliberately never a tier -- that
-- is the pure-turtle exploit and it must not exist anywhere in the ladder.
local function finishByClock(sim)
  local a, b = sim.sides[1], sim.sides[2]
  local R = sim.rules
  if a.keepDamageDealt ~= b.keepDamageDealt then
    finish(sim, a.keepDamageDealt > b.keepDamageDealt and 1 or 2, R.REASON.CLOCK, "clock", 1)
  elseif a.slotsDestroyed ~= b.slotsDestroyed then
    finish(sim, a.slotsDestroyed > b.slotsDestroyed and 1 or 2, R.REASON.CLOCK, "clock", 2)
  else
    local da, db = depthSum(sim, a), depthSum(sim, b)
    if da ~= db then
      finish(sim, da > db and 1 or 2, R.REASON.CLOCK, "clock", 3)
    elseif a.keepHp ~= b.keepHp then
      finish(sim, a.keepHp > b.keepHp and 1 or 2, R.REASON.CLOCK, "clock", 4)
    else
      finish(sim, 0, R.REASON.CLOCK, "clock", 5)
    end
  end
end

-- ---------------------------------------------------------------------------
-- the internals handed to the modifier layer
--
-- sim/Mods.lua implements the forty cards through the named hooks, and some of
-- them (the verbs, Ward, the payouts) need the sim's OWN primitives -- there
-- must never be a second implementation of a death, a credit or a clamp. The
-- table is built here, after everything in it exists, and passed to
-- Mods.install by value, so Mods.lua requires nothing and no module cycle
-- exists. These are internals on loan, not API: nothing outside sim/ may
-- touch them.
-- ---------------------------------------------------------------------------

local INTERNAL = {
  clampCh = clampCh,
  credit = credit,
  spend = spend,
  queueCredit = queueCredit,
  flushCredits = flushCredits,
  onUnitDeath = onUnitDeath,
  dmgTakenPts = dmgTakenPts,
  addDamage = addDamage,
  bankCapOf = bankCapOf,
  recomputeSideDerived = recomputeSideDerived,
  frontSlot = frontSlot,
  K_UNIT = K_UNIT, K_BUILDING = K_BUILDING, K_KEEP = K_KEEP,
}

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

-- Sim.new(rules, seed, loadoutA, loadoutB) -> sim
--   rules    the Rules module table (one artifact, hashed as rulesHash)
--   seed     integer; the handshake's 4-char seed field. No v1.0 system consumes
--            it (Q5), but it seeds sim.rng and is inside the state hash.
--   loadoutA the side-1 (host) loadout: an array of 5 modifier ids, or nil
--   loadoutB the side-2 (client) loadout
function M.new(rules, seed, loadoutA, loadoutB)
  local C = rules.C
  -- Fail loudly if the channel order ever moves out from under these indices.
  if rules.CH.unitCost ~= CH_UNITCOST or rules.CH.march ~= CH_MARCH
    or rules.CH.slotCap ~= CH_SLOTCAP or rules.CH.repelRefund ~= CH_REPELREFUND then
    error("Sim: Rules.CHANNELS order does not match this file's channel indices")
  end
  if rules.UNITS[UNIT_BOW].key ~= "bow" or rules.UNITS[UNIT_HORSE].key ~= "horse" then
    error("Sim: Rules.UNITS order does not match this file's unit indices")
  end

  local sim = setmetatable({
    rules = rules,
    seed = seed or 0,
    rng = Rand.new(seed or 0),
    clock = 0,   -- the match clock, in ACTIVE sim ticks (A.9)
    over = false,
    winner = 0,
    tier = 0,
    reason = "none",
    reasonCode = rules.REASON.NONE,
    nextEntityId = 1,
    sides = {},
    log = {},        -- every accepted command, in (tick, side, seq) order
    bucket = {},     -- [execTick] = array in (side, seq) order; indexed, never iterated
    seen = { {}, {} },  -- [side][seq] dedup, per A.12
    hooks = {},      -- M3 attaches here; every field is nil in M1
    -- scratch, reused every phase and never read across phases
    cg = {}, ci = {}, cr = {}, ck = {}, cm = {}, cn = 0,
    markSeq = 0,
    qcSide = {}, qcAmt = {}, qcN = 0,   -- deferred credits, see queueCredit
  }, Sim)

  sim.sides[1] = newSide(sim, 1, loadoutA)
  sim.sides[2] = newSide(sim, 2, loadoutB)
  -- Entity ids are allocated in a fixed order: keeps first, side 1 then side 2.
  sim.sides[1].keepId = nextId(sim)
  sim.sides[2].keepId = nextId(sim)

  -- M3: the modifier layer. Validates both loadouts (a malformed loadout is a
  -- broken handshake and errors here), and registers exactly the hooks the
  -- cards present need -- including onMatchStart, which the next line fires.
  -- TWO EMPTY LOADOUTS INSTALL NOTHING: every hook stays nil and the tick
  -- path below is the M1 tick path, instruction for instruction.
  Mods.install(sim, INTERNAL)

  if sim.hooks.onMatchStart then sim.hooks.onMatchStart(sim) end

  -- Opening stipend: 30 Levy, three Levy ticks' worth, granted at tick 0. It is
  -- what makes a Trap Pit affordable at 7 s so second zero holds a real decision;
  -- it does not violate "both players begin from zero", which is about
  -- progression. Levy ticks then fire at tick 35, 70, ... for 171 ticks, giving
  -- 30 + 1710 = 1740 total base Levy (C.2).
  credit(sim, sim.sides[1], C.OPENING_STIPEND)
  credit(sim, sim.sides[2], C.OPENING_STIPEND)
  return sim
end

-- Accept a command for future execution.
-- cmd = { side = 1|2, seq = n, tick = execTick, kind = "S"|"H"|"B"|<letter>,
--         target = n, count = n, issueTick = n (optional) }
-- `kind` is the wire atom's kind field: S, H, B deploy units; a building letter
-- builds; I, E, L are the M3 verbs (uppercase: case is the namespace, per the
-- A.11.2 ruling). `target` is a lane 1-3 for units and verbs,
-- a slot 1-6 for buildings. `issueTick`, when present, is the tick the order was
-- clicked on, and the ORDER_DELAY window is enforced against it. Returns ok, err.
--
-- Legality and affordability are NOT checked here: A.4 inverts v1 and evaluates
-- them at the exec tick, in the sim, on both clients, from state both hold. A
-- command that cannot be paid for is a defined no-op, not an error.
function Sim:queueCommand(cmd)
  local R, C = self.rules, self.rules.C
  local side = cmd.side
  if side ~= 1 and side ~= 2 then return false, "side" end
  local seq = cmd.seq
  if type(seq) ~= "number" or seq < 1 or floor(seq) ~= seq then return false, "seq" end
  if self.seen[side][seq] then return false, "duplicate" end
  local t = cmd.tick
  if type(t) ~= "number" or floor(t) ~= t or t < 0 then return false, "tick" end
  if t < self.clock then
    -- M4 repairs this by rewinding to a snapshot and splicing; M1 has no
    -- rollback, so a late command is refused rather than silently reordered.
    return false, "late"
  end
  if t >= C.MATCH_TICKS then return false, "afterClock" end

  local kind = cmd.kind
  local cls, idx
  local ui = R.UNIT_BY_KIND[kind]
  if ui then
    cls, idx = CLS_UNIT, ui
  else
    local bi = R.BUILDING_BY_LETTER[kind]
    if bi then
      cls, idx = CLS_BUILD, bi
    elseif kind == "I" or kind == "E" or kind == "L" then
      -- A.11.2 ruling: verbs are UPPERCASE (case is the namespace - uppercase
      -- targets a lane, lowercase targets a slot). Case-sensitive on purpose.
      cls = CLS_VERB
      idx = (kind == "I") and 1 or ((kind == "E") and 2 or 3)
    else
      return false, "kind"
    end
  end

  -- ORDER DELAY (C.1). An atom carries the tick it was ISSUED on; A.11 requires
  -- its exec tick to sit in [issue + ORDER_DELAY, issue + ORDER_DELAY_CLAMP].
  -- Both clients hold the same atom, so both reach the same verdict, which is why
  -- this is a refusal at the gate rather than a fizzle in the sim. Checked only
  -- when the caller supplies issueTick: a replay artifact or a test may legally
  -- describe an atom by its exec tick alone, and the sim's contract is a pure
  -- function of (ruleset, seed, atoms with their EXEC ticks).
  local issue = cmd.issueTick
  if issue ~= nil then
    if type(issue) ~= "number" or floor(issue) ~= issue then return false, "issueTick" end
    if t < issue + C.ORDER_DELAY then return false, "tooSoon" end
    if t > issue + C.ORDER_DELAY_CLAMP then return false, "tooLate" end
  end

  -- target and count must be INTEGERS, checked here for the same reason seq and
  -- tick are: queueCommand is the sim's only input gate and nothing downstream
  -- re-validates. A fractional target slips past the `< 1 or > LANES` range
  -- guards and indexes sd.lanes/sd.slots off the integer grid -- it either errors
  -- mid-tick or writes a building to sd.slots[2.5] that Hash.state's
  -- `for slot = 1, C.SLOTS` loop cannot see, so two clients could hold different
  -- state and still agree on stateHash. A fractional count makes Hash.log's
  -- accumulator non-integral, which errors in string.sub on 5.3+ but truncates
  -- silently on 5.1 -- exactly the cross-version divergence Hash.lua exists to
  -- prevent.
  -- RANGE is deliberately NOT checked: A.4 evaluates legality at the exec tick,
  -- so an out-of-range lane must still fizzle in the sim, not be refused here.
  local target = cmd.target
  if target == nil then target = 0 end
  if type(target) ~= "number" or floor(target) ~= target then return false, "target" end
  local count = cmd.count
  if count == nil then count = 1 end
  if type(count) ~= "number" or floor(count) ~= count then return false, "count" end
  if count < 1 then count = 1 end

  local c = {
    side = side, seq = seq, tick = t,
    cls = cls,
    kindIdx = cls * 100 + idx,
    target = target,
    count = count,
  }
  self.seen[side][seq] = true
  local b = self.bucket[t]
  if not b then b = {}; self.bucket[t] = b end
  bucketInsert(b, c)
  logInsert(self.log, c)
  return true
end

-- Advance exactly one sim tick. Returns false once terminal.
function Sim:tick()
  if self.over then return false end
  local C = self.rules.C
  local t = self.clock

  if t > 0 and t % C.LEVY_EVERY == 0 then phaseIncome(self) end

  local b = self.bucket[t]
  if b then
    for i = 1, #b do execCommand(self, b[i]) end
    self.bucket[t] = nil
  end

  phaseMove(self)
  if t % C.RESOLVE_EVERY == 0 then phaseResolve(self) end
  if not self.over then phaseBookkeeping(self) end

  self.clock = t + 1
  if not self.over and self.clock >= C.MATCH_TICKS then finishByClock(self) end
  return true
end

-- Advance up to n ticks, stopping early if the match ends. Returns ticks run.
function Sim:run(n)
  local ran = 0
  for _ = 1, n do
    if not self:tick() then break end
    ran = ran + 1
  end
  return ran
end

function Sim:isOver() return self.over end

function Sim:stateHash() return Hash.state(self) end
function Sim:logDigest() return Hash.log(self) end

-- Terminal verdict plus every ladder input, so a caller can show the live score
-- from the 20 percent mark (Q10) without reaching into sim internals.
function Sim:result()
  local sides = {}
  for s = 1, 2 do
    local sd = self.sides[s]
    sides[s] = {
      keepHp = sd.keepHp,
      keepDamageDealt = sd.keepDamageDealt,
      slotsDestroyed = sd.slotsDestroyed,
      penetration = depthSum(self, sd),
      bank = sd.bank,
      earned = sd.earned,
      wasted = sd.wasted,
      spent = sd.spent,
      unitsDeployed = sd.unitsDeployed,
      unitsLost = sd.unitsLost,
      unitsKilled = sd.unitsKilled,
      bldLost = sd.bldLost,
      cmdsExecuted = sd.cmdsExecuted,
      cmdsFizzled = sd.cmdsFizzled,
    }
  end
  return {
    over = self.over,
    tick = self.clock,
    winner = self.winner,        -- 1, 2, or 0 for a draw
    reason = self.reason,        -- "none", "keep", "clock"
    reasonCode = self.reasonCode,
    tier = self.tier,            -- Q10 ladder tier that decided it, 0 if by keep
    sides = sides,
  }
end

-- Read-only conveniences for a harness or a renderer. Neither is used by the
-- sim itself, and neither may ever be consulted by sim logic.
function Sim:unitCount(side, lane) return #self.sides[side].lanes[lane].units end
function Sim:levy(side) return self.sides[side].bank end
function Sim:keepHp(side) return self.sides[side].keepHp end

-- ---------------------------------------------------------------------------
-- M3 HOOK POINTS (sim.hooks.<name>; registered by sim/Mods.lua at Sim.new,
-- ONLY those the cards present actually need -- with two empty loadouts every
-- one of them is nil and this file runs its M1 tick path unchanged)
--
--   onMatchStart(sim)                            loadouts to channel points,
--                                                Discord's foe write, Caravan's
--                                                unlock, the runtime mods keys,
--                                                the Q3 wheel edge into
--                                                sd.wheelNum
--   onLevyTickStart(sim, sd)                     Golden Age latch, then the
--                                                Investment payout (fixed
--                                                order, INTERPRETATIONS 19)
--   levyTickPoints(sim, sd) -> pts               NEW IN M3: Golden Age's +40,
--                                                Granary Reserves' conditional
--                                                +20, Hex's windowed -30 --
--                                                dynamic levyTick sources join
--                                                the channel sum in
--                                                phaseIncome and clamp once
--   levyFlatPoints(sim, sd) -> flat              NEW IN M3: Trade Routes,
--                                                Surplus -- dynamic levyFlat
--                                                sources, same clamp rule
--   unitCostPoints(sim, sd, lane, t) -> pts      NEW IN M3: Late Levy's time-
--                                                gated discount joins the
--                                                unitCost sum in unitCostOf
--   deployCost(sim, sd, lane, t, cost, i) -> n   Conscription, Endless Ranks
--                                                (S5: one free deploy per order)
--   onDeploy(sim, sd, unit)                      Vanguard's per-unit flag
--   unitHpPoints(sim, sd, t) -> pts              Bulwark Line (Chaff is static
--                                                chan, being unconditional)
--   unitDmgPoints(sim, sd, u) -> pts             Tide of Bodies, War Drums,
--                                                Vanguard, No Retreat
--   dmgTakenPoints(sim, sd, u) -> pts            Iron Discipline
--   marchPoints(sim, sd, u) -> pts               Raiding Party (the march half)
--   bldHpPoints(sim, sd, bi) -> pts              Bastion Walls (Rickety is
--                                                static chan)
--   bldRangePoints(sim, sd, b) -> units          Watchfires (the range half;
--                                                the reveal is fog-side, M3
--                                                part 2)
--   rubbleCostPoints(sim, sd, slot) -> pts       Rapid Masonry
--   onResolveStart(sim)                          Tide's tick-start lane counts,
--                                                Raiding Party's Bypass
--                                                trigger, Counterwall's
--                                                clear-transition check
--   bldImmune(sim, sd, b) -> bool                NEW IN M3: Deep Foundations'
--                                                target filter; sd is the
--                                                building's OWNER. A true
--                                                verdict loses the hit --
--                                                no retargeting
--   onStructHit(sim, sd, es, u, b, pre)          NEW IN M3: Ward's reflect,
--                                                fed the pre-mitigation figure
--                                                by unitDamage; writes into
--                                                pend via addDamage
--   onExtraDamage(sim)                           Miasma decay
--   onUnitDeath(sim, sd, es, u)                  Blood Tithe, Counterwall's
--                                                accumulator, Endless Ranks
--                                                charges, War Drums' timer
--   onBuildingDestroyed(sim, sd, es, b, amt) -> amt   Plunder replaces Spoils
--   execVerb(sim, sd, cmd)                       I Investment (target ignored),
--                                                E Scorched Earth (target =
--                                                lane), L Ley Line (target =
--                                                source lane, count =
--                                                destination lane). A side
--                                                without the card fizzles,
--                                                exactly like the M1 default
--
-- Raiding Party's Bypass SKIP is native to this file rather than a hook: once
-- ln.bypass holds a building id (hashed lane state), phaseMove and unitAttacks
-- skip that candidate for this side's Horses -- pure geometry off hashed
-- state, needing no card table, and free when bypass is 0.
--
-- Every hook returns integers only and must not read anything outside `sim`.
-- Still deliberately NOT here:
--   * Divination / Omen / Veil / Shrine pulse -- perception effects; fog-side,
--     M3 part 2 (see Mods.INFO_EFFECTS). Their sim-side existence (ids,
--     affinity, hashing, legality, the pulse constants) is complete.
--   * Shrine's ward charge               -- effect still undefined (D.5)
--   * rollback snapshots (A.12)          -- M4
--   * fog (A.3)                          -- render only, must never be here
-- ---------------------------------------------------------------------------

-- Registration tail (M5): hands this module to IB_SIM_MODULES when the addon
-- created it (WoW discards a chunk's return value); headless it does not
-- exist and nothing here runs. Full argument in sim/Hash.lua's tail.
local IB_REG = rawget(_G, "IB_SIM_MODULES")
if IB_REG then IB_REG.Sim = M end

return M
