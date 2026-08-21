-- net/Snap.lua -- full-sim snapshot and restore for A.12's bounded rollback. M4.
--
-- WHY THIS LIVES OUTSIDE sim/, WHICH WAS A DECISION AND NOT A DEFAULT.
-- A.12's snapshot is consumer state: the sim itself never rolls back --
-- net/Net.lua does, the way the renderer owns fog memory and the driver owns
-- the policy view. Putting a clone API inside sim/ would have been permitted
-- as a behaviour-neutral addition, but it was not needed: everything a
-- snapshot must carry is either (a) hashed state, whose layout Hash.state
-- already fixes, or (b) derived caches the checklist names, or (c) protocol
-- bookkeeping (the log) the sim exposes. So sim/ is UNTOUCHED by M4, the
-- cardless game stays byte-identical by construction rather than by test, and
-- the one risk of an outside copy -- a NEW sim field this file silently fails
-- to carry -- is covered by a guard no inside implementation would get for
-- free: RESTORE RE-HASHES. Snap.take records Hash.state at capture, and
-- Snap.restore errors unless the restored sim re-hashes to exactly that
-- number. A field added to the sim AND the hash (the checklist's rule 3)
-- fails the very next rollback loudly. A field added outside the hash is
-- invisible to two real clients too -- and harness/runner.lua's invariants,
-- which the M4 gate runs on repaired sims, is the net that catches that
-- class, exactly as it does for M1.
--
-- WHAT IS COPIED, WHAT IS REBUILT, WHAT IS RESET:
--   copied    every hashed field (Hash.state's walk, field for field), the
--             derived caches (cacheLevyFlat, cacheBankCap, lane auras -- they
--             are pure functions of the slots, and copying them beats
--             re-deriving them here, which would be a second implementation
--             of sim logic), and the accepted-command log (fresh array,
--             SHARING the immutable command records).
--   rebuilt   sim.bucket and sim.seen, from the copied log: a bucket entry is
--             exactly "an accepted command whose exec tick has not run", and
--             the log is kept in canonical (tick, side, seq) order, so
--             appending log entries in log order rebuilds each tick's bucket
--             already in A.4's (side, seq) order with no second comparator.
--   reset     the per-phase scratch (cg/ci/cr/ck/cm, markSeq, the credit
--             queue). All of it is dead between ticks -- take() asserts the
--             parts that must be quiescent -- and a restored sim with fresh
--             scratch is indistinguishable from a fresh sim with fresh
--             scratch, which M1's instance-independence run (fuzz mode B)
--             already proves harmless.
--
-- RESTORE IS IN PLACE, and that is load-bearing: sim/Mods.lua's hook closures
-- capture the per-side card SPECS (immutable Rules rows) and read everything
-- else off the sim they are passed -- its own header says rollback "reruns
-- install and lands on the identical spec" for the rebuild-from-zero path,
-- and for the bounded path we keep the installed hooks and overwrite the
-- state under them. Side tables, lane tables and aura tables keep their
-- identity; units, buildings and arrays are replaced wholesale (nothing
-- captures those across ticks -- they are hook ARGUMENTS, not upvalues).
--
-- Held to the sim's determinism rules: integer walks only, no pairs (every
-- map copied here has a fixed field list or a parallel order array), no
-- clock, no randomness, side-agnostic (`for s = 1, 2`).

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")

local M = {}

local SIDE_INTS = {
  "index", "bank", "earned", "wasted", "spent",
  "keepId", "keepHp", "keepDamageDealt", "slotsDestroyed",
  "unitsDeployed", "unitsLost", "unitsKilled", "bldLost",
  "cmdsExecuted", "cmdsFizzled", "wheelNum",
  "cacheLevyFlat", "cacheBankCap",
}

local UNIT_INTS = { "id", "t", "lane", "pos", "hp", "maxHp", "cost", "vg" }
local BLD_INTS = { "id", "b", "slot", "lane", "hp", "maxHp", "cost",
                   "prog", "startTick", "need", "done", "spent" }
local LANE_INTS = { "supply", "depth", "hold1", "hold2", "hold3",
                    "muster", "bypass", "cwAcc" }
local AURA_INTS = { "unitDmg", "dmgTaken", "march", "bowRange" }

local function copyUnit(u)
  local c = { snapHp = 0, pend = 0, pendSrc = 0, step = 0 }
  for i = 1, #UNIT_INTS do
    local k = UNIT_INTS[i]
    c[k] = u[k]
  end
  return c
end

local function copyBuilding(b)
  if not b then return false end
  local c = { snapHp = 0, pend = 0, pendSrc = 0 }
  for i = 1, #BLD_INTS do
    local k = BLD_INTS[i]
    c[k] = b[k]
  end
  return c
end

local function takeSide(sim, sd)
  local C = sim.rules.C
  local s = { loadout = {}, chan = {}, lanes = {}, slots = {}, rubble = {},
              unlocks = {}, mods = {}, modsOrder = {} }
  for i = 1, #SIDE_INTS do
    local k = SIDE_INTS[i]
    s[k] = sd[k]
  end
  for i = 1, 5 do s.loadout[i] = sd.loadout[i] end
  for i = 1, #sd.chan do s.chan[i] = sd.chan[i] end
  for lane = 1, C.LANES do
    local ln = sd.lanes[lane]
    local l = { units = {}, aura = { cost = { 0, 0, 0 } } }
    for i = 1, #LANE_INTS do
      local k = LANE_INTS[i]
      l[k] = ln[k]
    end
    for i = 1, #AURA_INTS do
      local k = AURA_INTS[i]
      l.aura[k] = ln.aura[k]
    end
    for i = 1, 3 do l.aura.cost[i] = ln.aura.cost[i] end
    local us = ln.units
    for i = 1, #us do l.units[i] = copyUnit(us[i]) end
    s.lanes[lane] = l
  end
  for slot = 1, C.SLOTS do
    s.slots[slot] = copyBuilding(sd.slots[slot])
    s.rubble[slot] = sd.rubble[slot]
  end
  for b = 1, #sim.rules.BUILDINGS do s.unlocks[b] = sd.unlocks[b] end
  local order = sd.modsOrder
  for i = 1, #order do
    local k = order[i]
    s.modsOrder[i] = k
    s.mods[k] = sd.mods[k]
  end
  return s
end

local function restoreSide(sim, sd, s)
  local C = sim.rules.C
  for i = 1, #SIDE_INTS do
    local k = SIDE_INTS[i]
    sd[k] = s[k]
  end
  for i = 1, 5 do sd.loadout[i] = s.loadout[i] end
  for i = 1, #s.chan do sd.chan[i] = s.chan[i] end
  for lane = 1, C.LANES do
    local ln = sd.lanes[lane]   -- table identity kept; fields overwritten
    local l = s.lanes[lane]
    for i = 1, #LANE_INTS do
      local k = LANE_INTS[i]
      ln[k] = l[k]
    end
    for i = 1, #AURA_INTS do
      local k = AURA_INTS[i]
      ln.aura[k] = l.aura[k]
    end
    for i = 1, 3 do ln.aura.cost[i] = l.aura.cost[i] end
    local us = {}
    for i = 1, #l.units do us[i] = copyUnit(l.units[i]) end
    ln.units = us
  end
  for slot = 1, C.SLOTS do
    sd.slots[slot] = copyBuilding(s.slots[slot])
    sd.rubble[slot] = s.rubble[slot]
  end
  for b = 1, #sim.rules.BUILDINGS do sd.unlocks[b] = s.unlocks[b] end
  -- mods: overwrite the copied keys, then truncate modsOrder to the snapshot's
  -- length. Keys are only ever ADDED at install (match start), so a snapshot
  -- of the same match can never hold fewer keys than the live sim -- asserted,
  -- because a key that appeared mid-match would otherwise survive a restore.
  local order = s.modsOrder
  if #sd.modsOrder ~= #order then
    error("Snap: modsOrder grew mid-match; the restore cannot be trusted")
  end
  for i = 1, #order do
    local k = order[i]
    sd.modsOrder[i] = k
    sd.mods[k] = s.mods[k]
  end
end

-- Take a snapshot. Must be called BETWEEN ticks (never mid-phase): the
-- per-tick scratch has to be quiescent, and the two cheap assertions below
-- catch a caller that drifts into taking one anywhere else.
function M.take(sim)
  if sim.qcN ~= 0 then
    error("Snap: credit queue not empty; snapshots are taken between ticks only")
  end
  local snap = {
    clock = sim.clock,
    over = sim.over,
    winner = sim.winner,
    tier = sim.tier,
    reason = sim.reason,
    reasonCode = sim.reasonCode,
    nextEntityId = sim.nextEntityId,
    rngS = sim.rng.s,
    sides = { takeSide(sim, sim.sides[1]), takeSide(sim, sim.sides[2]) },
    log = {},
    hash = 0,
  }
  local log = sim.log
  for i = 1, #log do
    snap.log[i] = log[i]   -- records are immutable after queueCommand; shared
  end
  snap.hash = Hash.state(sim)
  return snap
end

-- Restore `sim` to `snap`, in place. Errors -- never returns wrong -- if the
-- restored sim does not re-hash to the captured hash: that is the copy-
-- coverage guard described in the header, and it runs on EVERY rollback.
function M.restore(sim, snap)
  sim.clock = snap.clock
  sim.over = snap.over
  sim.winner = snap.winner
  sim.tier = snap.tier
  sim.reason = snap.reason
  sim.reasonCode = snap.reasonCode
  sim.nextEntityId = snap.nextEntityId
  sim.rng.s = snap.rngS
  restoreSide(sim, sim.sides[1], snap.sides[1])
  restoreSide(sim, sim.sides[2], snap.sides[2])

  -- The accepted-command log, then bucket and seen rebuilt from it. The log
  -- is in canonical (tick, side, seq) order, so per-tick appends land in
  -- A.4's (side, seq) order with no second comparator to drift.
  local log, seen1, seen2, bucket = {}, {}, {}, {}
  local sl = snap.log
  for i = 1, #sl do
    local c = sl[i]
    log[i] = c
    if c.side == 1 then seen1[c.seq] = true else seen2[c.seq] = true end
    if c.tick >= snap.clock then
      local b = bucket[c.tick]
      if not b then b = {}; bucket[c.tick] = b end
      b[#b + 1] = c
    end
  end
  sim.log = log
  sim.seen = { seen1, seen2 }
  sim.bucket = bucket

  -- Per-phase scratch: dead between ticks; fresh is indistinguishable.
  sim.cg, sim.ci, sim.cr, sim.ck, sim.cm, sim.cn = {}, {}, {}, {}, {}, 0
  sim.markSeq = 0
  sim.qcSide, sim.qcAmt, sim.qcN = {}, {}, 0

  local got = Hash.state(sim)
  if got ~= snap.hash then
    error("Snap: restored sim hashes to " .. Hash.dec(got) .. ", captured "
      .. Hash.dec(snap.hash) .. " -- a sim field this file does not copy")
  end
end

return M
