-- harness/runner.lua -- run a command log against a fresh sim and collect hashes.
--
-- This is the only place in the harness that touches the sim, so every checker
-- (replay, fuzz, selftest) observes the match through exactly one lens and a
-- disagreement between them cannot be an artifact of two different drivers.
--
-- THREE ARRIVAL MODES, because M1 has to prove more than "the same code twice
-- gives the same answer":
--   upfront   every atom is queued before tick 0, in file order. The baseline.
--   order     every atom is queued before tick 0, in a caller-supplied
--             permutation. A.4 says canonical intra-tick order is (side, seq)
--             and is a hashed invariant, so the permutation must not matter.
--   arrival   each atom is queued at its own `arrive` tick, mid-run, in the
--             caller's permutation within a tick. This is what the wire actually
--             does (A.12: batches, resends, gaps), and it is the mode that would
--             expose a sim that reads the command queue for anything other than
--             "what executes on this tick".
--
-- WHAT IS COMPARED. Not just the terminal hash: a per-epoch trace at
-- SNAPSHOT_EPOCH (60 ticks, A.12's rollback cadence), the terminal hash, the
-- logDigest and the accept/reject tally. A divergence that heals before tick
-- 6000 is still a divergence -- two clients would already have voided the match
-- on the heartbeat's stateHash.

local Rules = require("sim.Rules")
local SimM = require("sim.Sim")
local Hash = require("sim.Hash")

local M = {}

local floor = math.floor
local C = Rules.C

M.Rules = Rules
M.Hash = Hash

local function frontSlot(lane) return (lane - 1) * 2 + 1 end
local function laneOfSlot(slot) return floor((slot - 1) / 2) + 1 end

function M.newSim(log)
  return SimM.new(Rules, log.seed or 0, log.loadout and log.loadout[1], log.loadout and log.loadout[2])
end

-- ---------------------------------------------------------------------------
-- run
-- ---------------------------------------------------------------------------

-- opts:
--   order    array of command indices giving arrival order (default 1..n)
--   arrival  true to deliver each command at its own `arrive` tick
--   epoch    hash cadence in ticks (default SNAPSHOT_EPOCH)
--   ticks    tick budget (default log.ticks)
--   keepSim  keep the sim object on the trace for debugging
function M.run(log, opts)
  opts = opts or {}
  local cmds = log.cmds
  local n = #cmds
  local order = opts.order
  if not order then
    order = {}
    for i = 1, n do order[i] = i end
  end
  local epoch = opts.epoch or C.SNAPSHOT_EPOCH
  local budget = opts.ticks or log.ticks or C.MATCH_TICKS

  local sim = M.newSim(log)
  local accepted, rejected = 0, 0
  local firstReject = nil

  local function queue(i)
    local c = cmds[i]
    local ok, err = sim:queueCommand(c)
    if ok then
      accepted = accepted + 1
    else
      rejected = rejected + 1
      if not firstReject then
        firstReject = string.format("cmd #%d (exec %d side %d seq %d %s %d x%d): %s",
          i, c.tick, c.side, c.seq, c.kind, c.target, c.count, tostring(err))
      end
    end
  end

  -- Group by arrival tick, preserving the caller's order within a tick.
  local byArrival = nil
  if opts.arrival then
    byArrival = {}
    for k = 1, n do
      local i = order[k]
      local a = cmds[i].arrive or 0
      local b = byArrival[a]
      if not b then b = {}; byArrival[a] = b end
      b[#b + 1] = i
    end
  else
    for k = 1, n do queue(order[k]) end
  end

  local trace = { ticks = {}, hashes = {}, n = 0 }
  for t = 0, budget - 1 do
    if byArrival then
      local b = byArrival[t]
      if b then
        for j = 1, #b do queue(b[j]) end
        byArrival[t] = nil
      end
    end
    if not sim:tick() then break end
    if sim.clock % epoch == 0 then
      local k = trace.n + 1
      trace.n = k
      trace.ticks[k] = sim.clock
      trace.hashes[k] = sim:stateHash()
    end
    if sim.over then break end
  end
  -- Anything still undelivered never made it before the match ended; that is a
  -- legitimate outcome (the peer stopped listening), and it must be identical in
  -- every mode, so it is folded into the tally rather than silently dropped.
  if byArrival then
    for t = 0, budget - 1 do
      local b = byArrival[t]
      if b then
        for j = 1, #b do
          rejected = rejected + 1
          if not firstReject then firstReject = "undelivered at end of match" end
        end
      end
    end
  end

  trace.terminal = sim:stateHash()
  trace.terminalTick = sim.clock
  trace.logDigest = sim:logDigest()
  trace.accepted = accepted
  trace.rejected = rejected
  trace.firstReject = firstReject
  trace.result = sim:result()
  trace.over = sim.over
  if opts.keepSim then trace.sim = sim end
  return trace
end

-- ---------------------------------------------------------------------------
-- A.2, the strongest invariant in the design: the sim does not know which side
-- is "me". Flip every atom's side field and the whole match must come out
-- mirrored -- side 1's numbers in the flipped run equal side 2's in the
-- original, and the winner swaps. A phase that moved side 1 before side 2 and
-- read positions side 2 had not updated yet, or a tiebreak that resolved the
-- host's way, shows up here and NOWHERE ELSE: it is perfectly deterministic, so
-- every hash comparison in this file would pass it.
--
-- The state hashes deliberately are NOT compared: entity ids are handed out in
-- (side, seq) order, so the mirrored run legitimately numbers its entities
-- differently. What must mirror is every observable quantity.
-- ---------------------------------------------------------------------------

local RESULT_FIELDS = {
  "keepHp", "keepDamageDealt", "slotsDestroyed", "penetration",
  "bank", "earned", "wasted", "spent",
  "unitsDeployed", "unitsLost", "unitsKilled", "bldLost",
  "cmdsExecuted", "cmdsFizzled",
}

function M.mirrorLog(log)
  local m = {
    version = log.version, seed = log.seed, ticks = log.ticks,
    loadout = { {}, {} }, cmds = {}, name = (log.name or "log") .. "|mirrored",
  }
  for i = 1, 5 do
    m.loadout[1][i] = log.loadout[2][i]
    m.loadout[2][i] = log.loadout[1][i]
  end
  for i = 1, #log.cmds do
    local c = log.cmds[i]
    m.cmds[i] = { tick = c.tick, side = 3 - c.side, seq = c.seq,
                  kind = c.kind, target = c.target, count = c.count, arrive = c.arrive }
  end
  return m
end

-- Compare an original trace with the trace of its mirrored log.
function M.mirrorCompare(a, m)
  if a.terminalTick ~= m.terminalTick then
    return false, string.format("terminal tick %d vs mirrored %d", a.terminalTick, m.terminalTick)
  end
  local ra, rm = a.result, m.result
  local wantWinner = (ra.winner == 0) and 0 or (3 - ra.winner)
  if rm.winner ~= wantWinner then
    return false, string.format("winner %d should mirror to %d, got %d", ra.winner, wantWinner, rm.winner)
  end
  if rm.reason ~= ra.reason or rm.tier ~= ra.tier then
    return false, string.format("terminal %s tier %d vs mirrored %s tier %d",
      ra.reason, ra.tier, rm.reason, rm.tier)
  end
  for s = 1, 2 do
    local x, y = ra.sides[s], rm.sides[3 - s]
    for f = 1, #RESULT_FIELDS do
      local k = RESULT_FIELDS[f]
      if x[k] ~= y[k] then
        return false, string.format("side %d %s = %d, mirrored side %d = %d",
          s, k, x[k], 3 - s, y[k])
      end
    end
  end
  return true, "mirrored"
end

-- Compare two traces. Returns ok, where, detail.
function M.compare(a, b)
  if a.n ~= b.n then
    return false, 0, string.format("epoch count %d vs %d", a.n, b.n)
  end
  if a.accepted ~= b.accepted or a.rejected ~= b.rejected then
    return false, 0, string.format("accept tally %d/%d vs %d/%d",
      a.accepted, a.rejected, b.accepted, b.rejected)
  end
  if a.logDigest ~= b.logDigest then
    return false, 0, string.format("logDigest %s vs %s", Hash.dec(a.logDigest), Hash.dec(b.logDigest))
  end
  for i = 1, a.n do
    if a.ticks[i] ~= b.ticks[i] then
      return false, i, string.format("epoch %d tick %d vs %d", i, a.ticks[i], b.ticks[i])
    end
    if a.hashes[i] ~= b.hashes[i] then
      return false, i, string.format("epoch %d (tick %d): stateHash %s vs %s",
        i, a.ticks[i], Hash.dec(a.hashes[i]), Hash.dec(b.hashes[i]))
    end
  end
  if a.terminalTick ~= b.terminalTick then
    return false, a.n, string.format("terminal tick %d vs %d", a.terminalTick, b.terminalTick)
  end
  if a.terminal ~= b.terminal then
    return false, a.n, string.format("terminal stateHash %s vs %s",
      Hash.dec(a.terminal), Hash.dec(b.terminal))
  end
  return true, 0, "identical"
end

-- ---------------------------------------------------------------------------
-- invariants
--
-- WHY THIS EXISTS, and it is the part of M1 that a hash comparison cannot do on
-- its own: comparing two stateHashes only proves the two runs agree about the
-- fields the hash covers. Anything the sim keeps outside the hash -- the cached
-- lane auras, cacheLevyFlat, cacheBankCap, a unit's `lane` back-pointer, the
-- transient `step` -- could diverge silently and still hash equal, and would then
-- desync two real clients on the very next tick. So every unhashed piece of
-- state is checked here to be a pure function of hashed state, and every
-- accounting identity the sim maintains by hand is re-derived independently.
-- ---------------------------------------------------------------------------

local function isInt(v) return type(v) == "number" and v == floor(v) end

function M.invariants(sim)
  local problems, np = {}, 0
  local function bad(fmt, ...)
    np = np + 1
    problems[np] = string.format(fmt, ...)
  end

  for s = 1, 2 do
    local sd = sim.sides[s]
    local es = sim.sides[3 - s]

    -- economy books: every Levy is credited, wasted or spent, and nothing else
    -- moves the bank. bank == earned - wasted - spent, exactly, all match.
    if sd.bank ~= sd.earned - sd.wasted - sd.spent then
      bad("side %d books do not balance: bank %d ~= earned %d - wasted %d - spent %d",
        s, sd.bank, sd.earned, sd.wasted, sd.spent)
    end
    if sd.bank < 0 then bad("side %d bank is negative: %d", s, sd.bank) end
    if not isInt(sd.bank) or not isInt(sd.earned) or not isInt(sd.wasted) or not isInt(sd.spent) then
      bad("side %d economy field is not an integer", s)
    end

    -- keeps: never heal, damage is capped at the remaining pool before being
    -- banked as tier-1 credit, so the two counters must agree to the unit.
    if sd.keepHp < 0 or sd.keepHp > C.KEEP_HP then
      bad("side %d keepHp out of range: %d", s, sd.keepHp)
    end
    if es.keepDamageDealt ~= C.KEEP_HP - sd.keepHp then
      bad("tier-1 counter drift: side %d dealt %d but side %d keep is missing %d",
        3 - s, es.keepDamageDealt, s, C.KEEP_HP - sd.keepHp)
    end

    -- paired counters: one side's loss is the other side's credit
    if es.unitsKilled ~= sd.unitsLost then
      bad("side %d unitsKilled %d ~= side %d unitsLost %d", 3 - s, es.unitsKilled, s, sd.unitsLost)
    end
    if es.slotsDestroyed ~= sd.bldLost then
      bad("tier-2 counter drift: side %d slotsDestroyed %d ~= side %d bldLost %d",
        3 - s, es.slotsDestroyed, s, sd.bldLost)
    end

    -- derived-from-slots cache: recomputed here from the Rules tables alone
    local expLevy, expBank = 0, 0
    for lane = 1, C.LANES do
      local eUnitDmg, eDmgTaken, eMarch, eBowRange = 0, 0, 0, 0
      local eCost = { 0, 0, 0 }
      local fs = frontSlot(lane)
      for k = 0, 1 do
        local b = sd.slots[fs + k]
        if b and b.done == 1 then
          local br = Rules.BUILDINGS[b.b]
          eUnitDmg = eUnitDmg + br.auraUnitDmg
          eDmgTaken = eDmgTaken + br.auraDmgTaken
          eMarch = eMarch + br.auraMarch
          eBowRange = eBowRange + br.auraBowRange
          if br.auraCostUnit > 0 then
            eCost[br.auraCostUnit] = eCost[br.auraCostUnit] + br.auraCostPct
          end
          expLevy = expLevy + br.levyFlat
          expBank = expBank + br.bankCapFlat
        end
      end
      local a = sd.lanes[lane].aura
      if a.unitDmg ~= eUnitDmg or a.dmgTaken ~= eDmgTaken or a.march ~= eMarch
        or a.bowRange ~= eBowRange or a.cost[1] ~= eCost[1] or a.cost[2] ~= eCost[2]
        or a.cost[3] ~= eCost[3] then
        bad("side %d lane %d cached aura disagrees with the slots it is derived from", s, lane)
      end
    end
    if sd.cacheLevyFlat ~= expLevy then
      bad("side %d cacheLevyFlat cache %d ~= %d derived from slots", s, sd.cacheLevyFlat, expLevy)
    end
    if sd.cacheBankCap ~= expBank then
      bad("side %d cacheBankCap cache %d ~= %d derived from slots", s, sd.cacheBankCap, expBank)
    end

    -- lanes, units and supply
    for lane = 1, C.LANES do
      local ln = sd.lanes[lane]
      local us = ln.units
      local sup = 0
      for i = 1, #us do
        local u = us[i]
        sup = sup + Rules.UNITS[u.t].cost
        if u.lane ~= lane then
          bad("side %d lane %d holds unit %d whose lane field says %d", s, lane, u.id, u.lane)
        end
        if u.step ~= 0 then
          bad("side %d unit %d left a movement step of %d between ticks", s, u.id, u.step)
        end
        if u.hp <= 0 or u.hp > u.maxHp then
          bad("side %d unit %d hp %d out of (0, %d]", s, u.id, u.hp, u.maxHp)
        end
        if u.pos < 0 or u.pos > C.LANE_LEN then
          bad("side %d unit %d pos %d off the axis", s, u.id, u.pos)
        end
        if u.id >= sim.nextEntityId then
          bad("side %d unit id %d is not below nextEntityId %d", s, u.id, sim.nextEntityId)
        end
      end
      -- Supply is charged at BASE cost on deploy and refunded at BASE cost on
      -- death, so it must equal the base cost of exactly the living units. The
      -- sim clamps it at zero on the way down, which would hide a leak; this
      -- check is what makes the clamp safe.
      if ln.supply ~= sup then
        bad("side %d lane %d supply %d ~= %d from living units", s, lane, ln.supply, sup)
      end
      if ln.supply > C.LANE_SUPPLY_CAP then
        bad("side %d lane %d supply %d over the cap %d", s, lane, ln.supply, C.LANE_SUPPLY_CAP)
      end
      if ln.depth < 0 or ln.depth > 3 then
        bad("side %d lane %d depth %d outside 0..3", s, lane, ln.depth)
      end
    end

    -- slots
    local occ = 0
    for slot = 1, C.SLOTS do
      local b = sd.slots[slot]
      if b then
        occ = occ + 1
        if b.slot ~= slot then bad("side %d slot %d holds a building that thinks it is in %d", s, slot, b.slot) end
        if b.lane ~= laneOfSlot(slot) then
          bad("side %d slot %d building lane %d ~= %d", s, slot, b.lane, laneOfSlot(slot))
        end
        if b.hp <= 0 or b.hp > b.maxHp then
          bad("side %d slot %d hp %d out of (0, %d]", s, slot, b.hp, b.maxHp)
        end
        if (b.prog >= b.need) ~= (b.done == 1) then
          bad("side %d slot %d done=%d with prog %d of %d", s, slot, b.done, b.prog, b.need)
        end
        if sd.rubble[slot] ~= 0 then
          bad("side %d slot %d is occupied and still marked rubble", s, slot)
        end
        if Rules.C.ENFORCE_SLOT_CLASS == 1 then
          local isFront = (slot % 2) == 1
          if (Rules.BUILDINGS[b.b].slotClass == "front") ~= isFront then
            bad("side %d slot %d holds a %s-class building", s, slot, Rules.BUILDINGS[b.b].slotClass)
          end
        end
      end
      if sd.rubble[slot] ~= 0 and sd.rubble[slot] ~= 1 then
        bad("side %d rubble[%d] is %d, not 0 or 1", s, slot, sd.rubble[slot])
      end
    end
    -- The slot cap is soft (Q7): Boomtown raises it through the slotCap
    -- channel, clamped exactly as Sim.slotCapOf clamps it.
    local capC = Rules.CLAMPS[Rules.CH.slotCap]
    local slotCap = C.SLOT_CAP + sd.chan[Rules.CH.slotCap]
    if slotCap < capC[1] then slotCap = capC[1] end
    if slotCap > capC[2] then slotCap = capC[2] end
    if occ > slotCap then
      bad("side %d holds %d buildings, over the slot cap %d", s, occ, slotCap)
    end

    -- M3 card runtime block: modsOrder must be sorted and unique (the hash
    -- walks it in order), every named key must exist as an integer, and no
    -- mods key may sit outside modsOrder -- a value there would be invisible
    -- to the hash. The harness bans pairs() like the sim does (a log must be
    -- replayable), so the outside-the-order direction is checked against the
    -- ROSTER of keys sim/Mods.lua can create, which is the only writer.
    local named = {}
    for i = 1, #sd.modsOrder do
      local k = sd.modsOrder[i]
      if named[k] then bad("side %d modsOrder repeats %s", s, tostring(k)) end
      named[k] = true
      if i > 1 and not (sd.modsOrder[i - 1] < k) then
        bad("side %d modsOrder is not sorted at %d", s, i)
      end
      local v = sd.mods[k]
      if not isInt(v) then
        bad("side %d mods.%s is not an integer", s, tostring(k))
      end
    end
    local MOD_KEYS = { "gaLatch", "invAmt", "invDue", "wdUntil", "seCd", "llCd",
                       "vg1", "vg2", "vg3" }
    for i = 1, #MOD_KEYS do
      local k = MOD_KEYS[i]
      if sd.mods[k] ~= nil and not named[k] then
        bad("side %d mods.%s is OUTSIDE modsOrder -- invisible to the hash", s, k)
      end
    end
    for lane = 1, C.LANES do
      local ln = sd.lanes[lane]
      if ln.muster < 0 or ln.muster > 3 then
        bad("side %d lane %d muster %d outside 0..3", s, lane, ln.muster)
      end
      if ln.cwAcc < 0 then
        bad("side %d lane %d Counterwall accumulator is negative", s, lane)
      end
    end
  end

  if sim.over then
    if sim.winner ~= 0 and sim.winner ~= 1 and sim.winner ~= 2 then
      bad("terminal with winner %s", tostring(sim.winner))
    end
    if sim.reasonCode == Rules.REASON.NONE then
      bad("terminal with reason code NONE")
    end
  end

  return np == 0, problems
end

-- ---------------------------------------------------------------------------
-- state dump, for diffing two diverged sims field by field
-- ---------------------------------------------------------------------------

function M.dump(sim)
  local out, n = {}, 0
  local function put(fmt, ...) n = n + 1; out[n] = string.format(fmt, ...) end
  put("clock=%d over=%s winner=%d reason=%d tier=%d nextId=%d rng=%d",
    sim.clock, tostring(sim.over), sim.winner, sim.reasonCode, sim.tier, sim.nextEntityId, sim.rng.s)
  for s = 1, 2 do
    local sd = sim.sides[s]
    put("side%d bank=%d earned=%d wasted=%d spent=%d keepHp=%d dealt=%d",
      s, sd.bank, sd.earned, sd.wasted, sd.spent, sd.keepHp, sd.keepDamageDealt)
    put("side%d slotsDestroyed=%d deployed=%d lost=%d killed=%d bldLost=%d exec=%d fizzle=%d",
      s, sd.slotsDestroyed, sd.unitsDeployed, sd.unitsLost, sd.unitsKilled, sd.bldLost,
      sd.cmdsExecuted, sd.cmdsFizzled)
    for lane = 1, C.LANES do
      local ln = sd.lanes[lane]
      put("side%d lane%d supply=%d depth=%d hold=%d/%d/%d units=%d",
        s, lane, ln.supply, ln.depth, ln.hold1, ln.hold2, ln.hold3, #ln.units)
      for i = 1, #ln.units do
        local u = ln.units[i]
        put("side%d lane%d unit[%d] id=%d t=%d pos=%d hp=%d/%d cost=%d",
          s, lane, i, u.id, u.t, u.pos, u.hp, u.maxHp, u.cost)
      end
    end
    for slot = 1, C.SLOTS do
      local b = sd.slots[slot]
      if b then
        put("side%d slot%d id=%d b=%d hp=%d/%d prog=%d/%d done=%d spent=%d rubble=%d",
          s, slot, b.id, b.b, b.hp, b.maxHp, b.prog, b.need, b.done, b.spent, sd.rubble[slot])
      else
        put("side%d slot%d empty rubble=%d", s, slot, sd.rubble[slot])
      end
    end
  end
  return out
end

-- First index at which two dumps differ, 0 if identical.
function M.dumpDiff(a, b)
  local n = #a
  if #b > n then n = #b end
  local lines, k = {}, 0
  for i = 1, n do
    if a[i] ~= b[i] then
      k = k + 1
      lines[k] = "  A: " .. tostring(a[i])
      k = k + 1
      lines[k] = "  B: " .. tostring(b[i])
      if k >= 24 then break end
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- tick-level bisect: re-run two configurations in lockstep and report the first
-- tick whose stateHash differs. Only called after a divergence is already known,
-- so the cost does not matter and the precision does.
-- ---------------------------------------------------------------------------

function M.bisect(log, optsA, optsB)
  local function prep(opts)
    opts = opts or {}
    local cmds, n = log.cmds, #log.cmds
    local order = opts.order
    if not order then
      order = {}
      for i = 1, n do order[i] = i end
    end
    local sim = M.newSim(log)
    local pending = nil
    if opts.arrival then
      pending = {}
      for k = 1, n do
        local i = order[k]
        local a = cmds[i].arrive or 0
        local b = pending[a]
        if not b then b = {}; pending[a] = b end
        b[#b + 1] = i
      end
    else
      for k = 1, n do sim:queueCommand(cmds[order[k]]) end
    end
    return sim, pending
  end
  local simA, penA = prep(optsA)
  local simB, penB = prep(optsB)
  local budget = log.ticks or C.MATCH_TICKS
  local prevA, prevB = nil, nil
  for t = 0, budget - 1 do
    if penA and penA[t] then for j = 1, #penA[t] do simA:queueCommand(log.cmds[penA[t][j]]) end end
    if penB and penB[t] then for j = 1, #penB[t] do simB:queueCommand(log.cmds[penB[t][j]]) end end
    local ra = simA:tick()
    local rb = simB:tick()
    if ra ~= rb then
      return t, simA, simB, prevA, prevB, "one sim was already terminal"
    end
    if not ra then break end
    if simA:stateHash() ~= simB:stateHash() then
      return t, simA, simB, prevA, prevB, "stateHash diverged on this tick"
    end
    prevA, prevB = M.dump(simA), M.dump(simB)
  end
  return -1, simA, simB, prevA, prevB, "no per-tick divergence found"
end

return M
