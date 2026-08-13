-- sweep/driver.lua -- one match: two scripted lines, a seed, a ruleset.
--
-- The driver is the hand that clicks. It polls each line once a second (M2's
-- Policy.POLL), turns whatever it returns into 6-byte command atoms, and hands
-- them to Sim:queueCommand exactly as the wire will in M5. Then it ticks the sim
-- to termination and returns a structured result.
--
-- IT IS THE ONLY PLACE THE TWO WORLDS MEET, and that is deliberate: everything
-- that could make a scripted match easier than a real one has to be visible in
-- this one file.
--
--   * ORDER DELAY IS ENFORCED BY THE SIM, NOT BY POLITENESS. Every atom carries
--     `issueTick`, so Sim:queueCommand itself checks C.1's window (A.11: exec in
--     [issue + ORDER_DELAY, issue + ORDER_DELAY_CLAMP]) and REFUSES anything
--     outside it. The driver asks for issue + ORDER_DELAY exactly -- the fastest
--     a real client can be, never faster. Refusals are counted, and the sweep
--     fails on a non-zero count rather than shrugging.
--   * NOTHING IS PRE-PAID AND NOTHING IS PRE-APPROVED. Affordability, the slot
--     cap, the slot class, the lane supply cap, card gating and the count cap
--     are evaluated by the SIM at the exec tick (A.4). The driver never writes
--     to sim state; it calls exactly three sim methods -- queueCommand, tick and
--     result -- plus the hashes, and reads sides only to fill the view.
--   * THE GATE ONLY REMOVES THINGS A UI COULD NOT EXPRESS: an unknown kind
--     letter, a target off the board, a count outside 1..MAX_UNITS_PER_ORDER, an
--     order that would execute after the match clock, and anything past
--     MAX_ORDERS_PER_POLL. Each class is counted separately and reported, so a
--     line that leans on the gate is visible in the results table rather than
--     silently trimmed.
--   * RESERVATIONS ARE THE LINE'S OWN OUTSTANDING ORDERS, nothing more. A client
--     knows what it has just sent, so `spendable` subtracts it. It never
--     subtracts anything about the opponent, whose in-flight orders are not in
--     the view at all.
--   * SEATS ARE INTERCHANGEABLE. `swap` seats slot 1 on side 2. Policy streams
--     are keyed to the SLOT, so the same pairing at the same seed must produce
--     the exact mirror -- which sweep/determinism.lua asserts, and which is the
--     policy-layer half of A.2.
--   * FOG MEMORY IS OWNED HERE, ONE STORE PER SIDE, AND IT IS NOT SIM STATE.
--     fog/Fog.lua's memory is what a side has SEEN and still believes; it is a
--     fold over the shared state and the side index, so both clients compute it
--     and agree, and it is deliberately outside Hash.state (Fog.lua's MEMORY
--     block argues why at length). The driver advances both stores once per sim
--     tick -- Fog.OBSERVE_EVERY, the declared cadence -- immediately after
--     sim:tick() returns, and once before the first tick for the tick-0 board.
--     THE CADENCE IS NOT THE POLL CADENCE ON PURPOSE: memory would otherwise
--     depend on how often a policy happens to look, which would make "what this
--     side remembers" a parameter of the roster rather than of the game.
--     Nothing in the memory store can reach the sim: it is written from sim
--     reads and read only by Policy.fillView.
--   * opts.onPoll IS A MEASUREMENT TAP AND CANNOT BE ANYTHING ELSE. It is handed
--     the same view the line is about to be handed, one call per poll per slot,
--     and its RETURN VALUE IS DISCARDED -- there is no path from it to an order,
--     to the sim, or to the line's memory. It exists so sweep/fogaudit.lua can
--     count what each line could actually SEE without a second copy of this loop
--     drifting away from the one the sweep measures. It is nil in every gate
--     path, and a line cannot install one: only the caller of driver.run can.
--
-- Held to sim/'s determinism rules like policy/: this file decides what the sim
-- is fed, so a float or a pairs() in here is a desync in M5 just as surely as
-- one in Sim.lua.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local SimM = IB_SIM_MODULES and IB_SIM_MODULES.Sim or require("sim.Sim")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local Fog = IB_SIM_MODULES and IB_SIM_MODULES.Fog or require("fog.Fog")

local M = {}

local floor = math.floor

local CLS_UNIT, CLS_BUILD = 1, 2

-- ---------------------------------------------------------------------------
-- reservations: what this side has ordered and the sim has not yet executed
-- ---------------------------------------------------------------------------

local function newRes(R)
  local r = { levy = 0, occ = 0, slot = {}, supply = {} }
  for s = 1, R.C.SLOTS do r.slot[s] = 0 end
  for lane = 1, R.C.LANES do r.supply[lane] = 0 end
  return r
end

local function newTally()
  return {
    issued = 0,        -- orders the line returned
    accepted = 0,      -- atoms the sim queued
    declinedRate = 0,  -- over MAX_ORDERS_PER_POLL in one poll
    declinedLate = 0,  -- would execute at or after the match clock
    badKind = 0, badTarget = 0, clampedCount = 0,
    refused = 0,       -- queueCommand said no. Should never happen; reported.
    peakUnits = 0,
    buildsDone = 0,
    built = {},
  }
end

-- ---------------------------------------------------------------------------
-- the run
-- ---------------------------------------------------------------------------

-- opts:
--   a, b      policy DEFINITIONS (policy/lines.lua entries). Slot 1 and slot 2.
--   seed      match seed; also the sim seed
--   rules     ruleset table (default sim/Rules.lua)
--   swap      true to seat slot 1 on side 2
--   maxTicks  tick budget (default MATCH_TICKS)
--   poll      ticks between decisions (default Policy.POLL)
--   record    true to keep every issued atom, for the determinism test
--   onPoll    optional read-only measurement tap f(lineName, view, tick); header
function M.run(opts)
  local R = opts.rules or Rules
  if R.rulesHash ~= Rules.rulesHash then
    -- policy/Policy.lua's name tables are derived from the module-level ruleset;
    -- a second ruleset would map a letter to a different building here than in
    -- the sim, which is the drift rulesHash exists to make impossible.
    error("driver: opts.rules is not the ruleset the policy layer was built from")
  end
  local C = R.C
  local seed = opts.seed or 0
  local maxTicks = opts.maxTicks or C.MATCH_TICKS
  local poll = opts.poll or Policy.POLL
  local swap = opts.swap and true or false

  local defs = { opts.a, opts.b }
  if defs[1] == nil or defs[2] == nil then error("driver: needs two policies") end

  -- slot -> side. The ONLY place a seat number is decided; nothing downstream of
  -- here, and nothing at all inside a policy, can see it.
  local sideOf = { 1, 2 }
  if swap then sideOf = { 2, 1 } end
  local slotOf = { 0, 0 }
  slotOf[sideOf[1]] = 1
  slotOf[sideOf[2]] = 2

  local sim = SimM.new(R, seed)
  local inst = {
    Policy.instance(defs[1], seed, 1),
    Policy.instance(defs[2], seed, 2),
  }

  local views = { Policy.newView(R), Policy.newView(R) }  -- indexed by SIDE
  local mem = { Fog.newMemory(R), Fog.newMemory(R) }      -- indexed by SIDE
  local res = { newRes(R), newRes(R) }                    -- indexed by SIDE
  local tally = { newTally(), newTally() }                -- indexed by SLOT
  local seq = { 0, 0 }                                    -- indexed by SIDE
  local inflight = {}                                     -- [execTick] = array
  local out = {}
  local atoms = opts.record and {} or nil
  local nAtoms = 0

  -- Building bookkeeping, for diagnosis: which buildings each slot actually got
  -- finished. Sampled at poll cadence, which is finer than the shortest build
  -- time in C.4 (60 ticks) by a factor of six.
  local lastBldId = { {}, {} }
  local lastBldDone = { {}, {} }
  for s = 1, 2 do
    for slot = 1, C.SLOTS do lastBldId[s][slot] = 0; lastBldDone[s][slot] = 0 end
  end

  local function reserve(side, cls, idx, target, count)
    local r = res[side]
    local rec
    if cls == CLS_UNIT then
      local base = R.UNITS[idx].cost * count
      r.levy = r.levy + base
      r.supply[target] = r.supply[target] + base
      rec = { side = side, levy = base, lane = target, supply = base, slot = 0 }
    else
      local cost = R.BUILDINGS[idx].cost
      r.levy = r.levy + cost
      r.slot[target] = 1
      r.occ = r.occ + 1
      rec = { side = side, levy = cost, lane = 0, supply = 0, slot = target }
    end
    return rec
  end

  -- THERE IS NO intra-poll VIEW PATCH HERE, and there used to be. It was dead
  -- code: `issue` runs only after `decide` has returned the WHOLE poll's orders,
  -- so nothing reads the view again before `fillView` overwrites every field at
  -- the next poll. The intra-poll accounting contract it claimed to enforce is
  -- real and lives where it can actually bind -- `claimed` in policy/lines.lua's
  -- decide(), which sizes the deploy against the Levy the building order in the
  -- same poll has already taken. Removing the patch changed no number in the
  -- sweep, which is the definition of dead.
  local function issue(slot, side, tick, o, accepted)
    local t = tally[slot]
    t.issued = t.issued + 1
    if accepted >= Policy.MAX_ORDERS_PER_POLL then
      t.declinedRate = t.declinedRate + 1
      return accepted
    end
    local kind = o.kind
    local cls, idx = 0, 0
    local ui = R.UNIT_BY_KIND[kind]
    if ui then
      cls, idx = CLS_UNIT, ui
    else
      local bi = R.BUILDING_BY_LETTER[kind]
      if bi then cls, idx = CLS_BUILD, bi end
    end
    if cls == 0 then
      -- No UI affordance exists for a kind letter that is not in the catalogue,
      -- and the M3 verbs are not unlocked in M2.
      t.badKind = t.badKind + 1
      return accepted
    end
    local target = o.target
    if type(target) ~= "number" or floor(target) ~= target
      or target < 1
      or (cls == CLS_UNIT and target > C.LANES)
      or (cls == CLS_BUILD and target > C.SLOTS) then
      t.badTarget = t.badTarget + 1
      return accepted
    end
    local count = o.count or 1
    if cls == CLS_BUILD then
      count = 1
    else
      if type(count) ~= "number" or floor(count) ~= count then
        t.badTarget = t.badTarget + 1
        return accepted
      end
      if count < 1 then count = 1; t.clampedCount = t.clampedCount + 1 end
      if count > C.MAX_UNITS_PER_ORDER then
        count = C.MAX_UNITS_PER_ORDER
        t.clampedCount = t.clampedCount + 1
      end
    end
    -- The soonest a real client can have it land (C.1). Never sooner.
    local exec = tick + C.ORDER_DELAY
    if exec >= maxTicks then
      t.declinedLate = t.declinedLate + 1
      return accepted
    end
    seq[side] = seq[side] + 1
    local ok = sim:queueCommand({
      side = side, seq = seq[side], tick = exec, issueTick = tick,
      kind = kind, target = target, count = count,
    })
    if not ok then
      -- The sim refused the atom outright. Under M2 this cannot happen unless
      -- the driver itself is wrong (a bad seq, a stale tick, a delay outside the
      -- window), so it is counted and surfaced rather than retried.
      t.refused = t.refused + 1
      seq[side] = seq[side] - 1
      return accepted
    end
    t.accepted = t.accepted + 1
    local rec = reserve(side, cls, idx, target, count)
    local b = inflight[exec]
    if not b then b = {}; inflight[exec] = b end
    b[#b + 1] = rec
    if atoms then
      nAtoms = nAtoms + 1
      atoms[nAtoms] = { tick = exec, side = side, seq = seq[side],
                        kind = kind, target = target, count = count, slot = slot }
    end
    return accepted + 1
  end

  local function sampleBuildings()
    for s = 1, 2 do
      local sd = sim.sides[s]
      local t = tally[slotOf[s]]
      for slot = 1, C.SLOTS do
        local b = sd.slots[slot]
        local id = b and b.id or 0
        if id ~= lastBldId[s][slot] then
          lastBldId[s][slot] = id
          lastBldDone[s][slot] = 0
        end
        if b and b.done == 1 and lastBldDone[s][slot] == 0 then
          lastBldDone[s][slot] = 1
          t.buildsDone = t.buildsDone + 1
          t.built[b.b] = (t.built[b.b] or 0) + 1
        end
      end
    end
  end

  -- The tick-0 observation. Both sides see the opening board, which is public
  -- (six empty slots, two full keeps) and is what Fog.newMemory already holds,
  -- so this only stamps the tick -- but it is here so that the fold starts at
  -- the same place on every client rather than at the first tick that happens
  -- to run.
  Fog.observe(mem[1], sim, 1)
  Fog.observe(mem[2], sim, 2)

  for tick = 0, maxTicks - 1 do
    if tick % poll == 0 then
      Policy.fillView(views[1], sim, 1, res[1], mem[1])
      Policy.fillView(views[2], sim, 2, res[2], mem[2])
      for k = 1, 2 do
        local side = sideOf[k]
        local t = tally[k]
        if views[side].me.units > t.peakUnits then t.peakUnits = views[side].me.units end
        -- The measurement tap. Return value discarded, on purpose (see header).
        if opts.onPoll then opts.onPoll(inst[k].name, views[side], tick) end
        local n = inst[k]:decide(views[side], tick, out)
        if type(n) ~= "number" or n < 0 then
          error("driver: " .. inst[k].name .. " returned a bad order count")
        end
        local accepted = 0
        for i = 1, n do accepted = issue(k, side, tick, out[i], accepted) end
      end
      sampleBuildings()
    end

    if not sim:tick() then break end

    -- Fog memory, once per sim tick, AFTER the tick (see the header). Both
    -- sides, always, whichever regime is running: the store is cheap, and
    -- building it under "full" too is what keeps "full" a strict superset of
    -- the fogged regime rather than a differently-parameterised one -- the exact
    -- instrument bug Finding 7 found in the muster bar.
    Fog.observe(mem[1], sim, 1)
    Fog.observe(mem[2], sim, 2)

    -- Release the reservations for the tick that has just executed. AFTER the
    -- tick, per harness/gen.lua: during tick t the bank has not yet been charged
    -- for the orders executing on tick t.
    local done = inflight[tick]
    if done then
      for i = 1, #done do
        local d = done[i]
        local r = res[d.side]
        r.levy = r.levy - d.levy
        if d.lane > 0 then r.supply[d.lane] = r.supply[d.lane] - d.supply end
        if d.slot > 0 then r.slot[d.slot] = 0; r.occ = r.occ - 1 end
      end
      inflight[tick] = nil
    end
    if sim.over then break end
  end
  sampleBuildings()

  -- ---------------------------------------------------------------------
  -- result
  -- ---------------------------------------------------------------------

  local rs = sim:result()
  local slots = {}
  for k = 1, 2 do
    local side = sideOf[k]
    local sr = rs.sides[side]
    local t = tally[k]
    slots[k] = {
      name = inst[k].name,
      family = inst[k].family,
      side = side,
      -- verdict inputs (Q10's ladder, in tier order)
      keepHp = sr.keepHp,
      keepDamageDealt = sr.keepDamageDealt,
      slotsDestroyed = sr.slotsDestroyed,
      penetration = sr.penetration,
      -- economy, which is what a weird outcome is nearly always about
      bank = sr.bank, earned = sr.earned, spent = sr.spent, wasted = sr.wasted,
      levyFlat = sim.sides[side].cacheLevyFlat,
      unitsDeployed = sr.unitsDeployed,
      unitsLost = sr.unitsLost,
      unitsKilled = sr.unitsKilled,
      bldLost = sr.bldLost,
      buildsDone = t.buildsDone,
      built = t.built,
      peakUnits = t.peakUnits,
      -- the command path
      cmdsExecuted = sr.cmdsExecuted,
      cmdsFizzled = sr.cmdsFizzled,
      issued = t.issued,
      accepted = t.accepted,
      refused = t.refused,
      declinedRate = t.declinedRate,
      declinedLate = t.declinedLate,
      badKind = t.badKind,
      badTarget = t.badTarget,
      clampedCount = t.clampedCount,
      -- THE REALIZED RATE, not the ceiling. Policy.POLL and
      -- MAX_ORDERS_PER_POLL bound what the layer CAN ask for and Policy.lua
      -- asserts that bound at load; this is what this line actually sent,
      -- which is the only thing that catches a single saturating LINE while
      -- the constants are still correct. Atoms per minute of MATCH CLOCK.
      atomsPerMin = floor(t.accepted * floor(60000 / C.SIM_TICK_MS)
                          / (rs.tick > 0 and rs.tick or 1)),
    }
  end

  local winnerSlot = 0
  if rs.winner ~= 0 then winnerSlot = slotOf[rs.winner] end

  return {
    seed = seed,
    swap = swap,
    poll = poll,
    ticks = rs.tick,
    seconds = floor(rs.tick * C.SIM_TICK_MS / 1000),
    over = rs.over,
    reason = rs.reason,
    reasonCode = rs.reasonCode,
    tier = rs.tier,
    winnerSide = rs.winner,
    winnerSlot = winnerSlot,
    stateHash = sim:stateHash(),
    logDigest = sim:logDigest(),
    -- The two fog memories, digested. NOT part of stateHash and never will be
    -- (fog/Fog.lua's MEMORY block); reported so sweep/determinism.lua can assert
    -- that a replay reproduces what each side REMEMBERS as well as what the sim
    -- computed, which is the property that makes memory safe to keep out of the
    -- hash rather than merely convenient.
    memHash = { Fog.memHash(mem[1]), Fog.memHash(mem[2]) },
    slots = slots,
    atoms = atoms,
    nAtoms = nAtoms,
  }
end

return M
