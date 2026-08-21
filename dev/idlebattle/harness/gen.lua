-- harness/gen.lua -- randomised but LEGAL command logs.
--
-- WHY LEGALITY IS THE WHOLE POINT
-- A fuzzer that fires random atoms at the sim mostly measures the fizzle path:
-- an unaffordable order is a defined no-op (A.4), so two runs agree about it
-- trivially and the determinism result is much weaker than it looks. What has to
-- be exercised is the path where money actually moves -- where two deploys land
-- on one tick and only one is affordable, where a lane hits the supply cap
-- mid-order, where a building completes and changes income. So this generator
-- produces only orders that will actually EXECUTE, and the fuzzer asserts
-- cmdsFizzled == 0 over the whole match. That assertion is itself a test: it
-- says this file's model of cost, slot cap, supply cap and slot class agrees
-- with the sim's, command for command, over millions of ticks.
--
-- HOW LEGALITY IS GUARANTEED ACROSS THE INPUT DELAY
-- An order issued at tick t executes at t + 20..40 (C.1), and the sim judges it
-- at the exec tick, from state that has moved on. The generator therefore runs
-- its own sim forward and keeps a RESERVATION per side: every in-flight order
-- holds its BASE cost, its lane supply, and its slot, until the tick it
-- executes. Two facts make the reservation sufficient rather than optimistic:
--   * bank only ever falls through a command's own spend, and every in-flight
--     spend is reserved; income and refunds only add.
--   * lane supply and slot occupancy only ever rise through a command's own
--     effect, and every in-flight one is reserved. Deaths and razings only free
--     capacity.
-- So "bank >= sum of in-flight base costs" is an invariant of this file, and the
-- worst case at exec is exactly the case checked at issue. Costs are reserved at
-- BASE because every M1 modifier of a cost is a discount (Fletcher, Stables),
-- never a surcharge -- reserving the base is the conservative side.
--
-- Determinism of the GENERATOR matters too: a log that cannot be regenerated
-- from its seed cannot be used to reproduce a failure. It draws only from
-- sim/Rand.lua, iterates only arrays, and reads no clock.

local Rules = require("sim.Rules")
local SimM = require("sim.Sim")
local Rand = require("sim.Rand")
local logfmt = require("harness.logfmt")

local M = {}

local floor = math.floor
local C = Rules.C

local UNIT_KIND = { "S", "H", "B" }   -- index order matches Rules.UNITS

-- Buildings that a bare M1 side may actually raise: everything not card-gated
-- (Caravan needs an unlock only M3 can grant, so ordering it is a guaranteed
-- fizzle and it is excluded here on purpose).
local FRONT_B, BACK_B = {}, {}
for i = 1, #Rules.BUILDINGS do
  local b = Rules.BUILDINGS[i]
  if b.cardGated == 0 then
    if b.slotClass == "front" then
      FRONT_B[#FRONT_B + 1] = i
    else
      BACK_B[#BACK_B + 1] = i
    end
  end
end

local function isFrontSlot(slot) return (slot % 2) == 1 end

local function occupied(sd)
  local n = 0
  for s = 1, C.SLOTS do
    if sd.slots[s] then n = n + 1 end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- one side's issuing policy
-- ---------------------------------------------------------------------------

-- Two temperaments, because one is not enough to cover the sim.
--   brawl  spends on units the moment it can. Produces the razed-keep ending,
--          big lane stacks, the supply cap, and the repel refund.
--   turtle spends on buildings and holds Levy. Produces long matches that reach
--          the match clock, which is the ONLY way the Q10 tiebreak ladder and
--          the tier-3 depth-hold timers get exercised at all -- a fuzzer made
--          purely of brawlers never executes finishByClock once.
local function newPolicy(r, style)
  local p
  if style == "guard" then
    p = {
      buildBias = Rand.range(r, 15, 60),
      cadence = Rand.range(r, 15, 60),
      jitter = Rand.range(r, 0, 25),
      favLane = Rand.range(r, 1, C.LANES),
      massBias = Rand.range(r, 20, 80),
      hold = Rand.range(r, 0, 30),
      guard = 1,
      typeW = { 0, 0, 0 },
    }
  elseif style == "turtle" then
    p = {
      buildBias = Rand.range(r, 45, 90),
      cadence = Rand.range(r, 45, 130),
      jitter = Rand.range(r, 0, 40),
      favLane = Rand.range(r, 1, C.LANES),
      massBias = Rand.range(r, 5, 35),
      hold = Rand.range(r, 35, 80),
      typeW = { 0, 0, 0 },
    }
  else
    p = {
      buildBias = Rand.range(r, 5, 40),    -- percent of attempts that try a building
      cadence = Rand.range(r, 12, 60),     -- ticks between attempts
      jitter = Rand.range(r, 0, 30),
      favLane = Rand.range(r, 1, C.LANES),
      massBias = Rand.range(r, 30, 95),    -- percent of deploys that take the max stack
      hold = Rand.range(r, 0, 45),         -- percent of attempts skipped outright
      typeW = { 0, 0, 0 },
    }
  end
  -- Type preference, as integer weights. Every side gets a non-zero weight on
  -- every type so the counter triangle (S beats H beats B beats S) is exercised.
  for t = 1, 3 do p.typeW[t] = Rand.range(r, 1, 10) end
  return p
end

-- Lane preference. A `guard` reinforces whichever lane the enemy has the most
-- Levy standing in, which is the only policy that reliably CONTESTS lanes: two
-- sides picking favourite lanes at random leave a lane empty most matches, one
-- side walks a stack into an undefended keep, and the match never reaches the
-- clock. Reading the enemy's lane supply is legitimate here -- Ruling 1 shares
-- the whole state and A.3 makes fog a render filter, so a policy may see it.
local function laneWeight(g, side, p, lane)
  if p.guard == 1 then
    local es = g.sim.sides[3 - side]
    local best, bestLane = -1, 1
    for i = 1, C.LANES do
      local sup = es.lanes[i].supply
      if sup > best then best = sup; bestLane = i end
    end
    if lane == bestLane then return 10 end
    return 1
  end
  if lane == p.favLane then return 6 end
  return 2
end

-- ---------------------------------------------------------------------------
-- candidate orders
-- ---------------------------------------------------------------------------

local function pickDeploy(g, side, avail)
  local r = g.rand
  local sd = g.sim.sides[side]
  local p = g.pol[side]
  local res = g.res[side]
  local cand, nc, total = {}, 0, 0
  for t = 1, 3 do
    local base = Rules.UNITS[t].cost
    local byBank = floor(avail / base)
    if byBank > C.MAX_UNITS_PER_ORDER then byBank = C.MAX_UNITS_PER_ORDER end
    if byBank >= 1 then
      for lane = 1, C.LANES do
        local room = C.LANE_SUPPLY_CAP - sd.lanes[lane].supply - res.supply[lane]
        local byRoom = floor(room / base)
        local mx = byBank
        if byRoom < mx then mx = byRoom end
        if mx >= 1 then
          nc = nc + 1
          local w = laneWeight(g, side, p, lane) * p.typeW[t]
          total = total + w
          cand[nc] = { t = t, lane = lane, mx = mx, w = w }
        end
      end
    end
  end
  if nc == 0 then return nil end
  local roll = Rand.range(r, 1, total)
  local acc, pick = 0, cand[nc]
  for i = 1, nc do
    acc = acc + cand[i].w
    if roll <= acc then pick = cand[i]; break end
  end
  local count
  if Rand.range(r, 1, 100) <= p.massBias then
    count = pick.mx
  else
    count = Rand.range(r, 1, pick.mx)
  end
  local base = Rules.UNITS[pick.t].cost
  return {
    kind = UNIT_KIND[pick.t], target = pick.lane, count = count,
    levy = base * count, lane = pick.lane, supply = base * count, slot = 0,
  }
end

local function pickBuild(g, side, avail)
  local r = g.rand
  local sd = g.sim.sides[side]
  local res = g.res[side]
  if occupied(sd) + res.occ >= C.SLOT_CAP then return nil end
  local cand, nc = {}, 0
  for slot = 1, C.SLOTS do
    if (not sd.slots[slot]) and res.slot[slot] == 0 then
      local list = isFrontSlot(slot) and FRONT_B or BACK_B
      for k = 1, #list do
        local bi = list[k]
        -- In M1 bldCostOf() is the catalogue cost exactly: the bldCost channel is
        -- zero and the rubble hook is nil until M3.
        if Rules.BUILDINGS[bi].cost <= avail then
          nc = nc + 1
          cand[nc] = { slot = slot, bi = bi }
        end
      end
    end
  end
  if nc == 0 then return nil end
  local pick = cand[Rand.range(r, 1, nc)]
  return {
    kind = Rules.BUILDINGS[pick.bi].letter, target = pick.slot, count = 1,
    levy = Rules.BUILDINGS[pick.bi].cost, lane = 0, supply = 0, slot = pick.slot,
  }
end

-- ---------------------------------------------------------------------------
-- the generator
-- ---------------------------------------------------------------------------

-- M.make(seed, opts) -> log
--   opts.ticks   match length (default MATCH_TICKS)
--   opts.maxCmds hard stop on log size (default 400)
function M.make(seed, opts)
  opts = opts or {}
  local ticks = opts.ticks or C.MATCH_TICKS
  local maxCmds = opts.maxCmds or 400
  local r = Rand.new(seed)

  local log = logfmt.newLog(seed, ticks)
  log.name = "gen:" .. seed

  -- Match style. Guard-versus-guard contests every lane and is what drives a
  -- match to the clock and through the Q10 tiebreak ladder; brawl-versus-brawl
  -- razes keeps. Both endings have to be in the sample, because they run
  -- different terminal code.
  -- Measured over 60 logs of each pairing: guard/guard reaches the match clock
  -- 30% of the time (median 4601 ticks), turtle/turtle 2%, brawl/brawl never.
  -- Half the sample is therefore guard/guard, which buys ~18% of matches running
  -- the full 6000 ticks through finishByClock while still leaving ~80% decided
  -- by a razed keep -- which is also what C.6 says the balance should produce.
  local roll = Rand.range(r, 1, 100)
  local styleA, styleB = "brawl", "brawl"
  if roll <= 50 then styleA, styleB = "guard", "guard"
  elseif roll <= 58 then styleA, styleB = "turtle", "turtle"
  elseif roll <= 66 then styleA, styleB = "turtle", "brawl"
  elseif roll <= 73 then styleA, styleB = "guard", "brawl"
  elseif roll <= 80 then styleA, styleB = "brawl", "guard" end
  if opts.styleA then styleA = opts.styleA end
  if opts.styleB then styleB = opts.styleB end
  log.style = styleA .. "/" .. styleB

  local g = {
    rand = r,
    sim = SimM.new(Rules, seed),
    pol = { newPolicy(r, styleA), newPolicy(r, styleB) },
    res = {
      { levy = 0, occ = 0, slot = { 0, 0, 0, 0, 0, 0 }, supply = { 0, 0, 0 } },
      { levy = 0, occ = 0, slot = { 0, 0, 0, 0, 0, 0 }, supply = { 0, 0, 0 } },
    },
  }
  local seq = { 0, 0 }
  local nextAt = { Rand.range(r, 0, 40), Rand.range(r, 0, 40) }
  local inflight = {}   -- [execTick] = array of reservation records

  local sim = g.sim
  for t = 0, ticks - 1 do
    for side = 1, 2 do
      if t >= nextAt[side] and #log.cmds < maxCmds then
        local p = g.pol[side]
        nextAt[side] = t + p.cadence + Rand.range(r, 0, p.jitter)
        if Rand.range(r, 1, 100) > p.hold then
          local sd = sim.sides[side]
          local res = g.res[side]
          local avail = sd.bank - res.levy
          local order = nil
          if avail >= 1 then
            local wantBuild = Rand.range(r, 1, 100) <= p.buildBias
            if wantBuild then
              order = pickBuild(g, side, avail)
              if not order then order = pickDeploy(g, side, avail) end
            else
              order = pickDeploy(g, side, avail)
              if not order then order = pickBuild(g, side, avail) end
            end
          end
          if order then
            -- Input delay (C.1): an order issued at t executes no earlier than
            -- t + ORDER_DELAY, and never later than the ORDER_DELAY_CLAMP.
            local exec = t + Rand.range(r, C.ORDER_DELAY, C.ORDER_DELAY_CLAMP)
            if exec < ticks then
              seq[side] = seq[side] + 1
              -- Arrival is anywhere from "the same tick it was issued" to "the
              -- exec tick itself" -- the latter is the resend that only just
              -- made it, which is the case A.12 has to survive.
              local arrive = Rand.range(r, t, exec)
              logfmt.add(log, exec, side, seq[side], order.kind, order.target, order.count, arrive)
              local ok = sim:queueCommand({
                side = side, seq = seq[side], tick = exec,
                kind = order.kind, target = order.target, count = order.count,
              })
              if not ok then
                error("gen: the generator produced a command the sim refused to queue")
              end
              res.levy = res.levy + order.levy
              if order.lane > 0 then
                res.supply[order.lane] = res.supply[order.lane] + order.supply
              end
              if order.slot > 0 then
                res.slot[order.slot] = 1
                res.occ = res.occ + 1
              end
              local b = inflight[exec]
              if not b then b = {}; inflight[exec] = b end
              b[#b + 1] = { side = side, levy = order.levy, lane = order.lane,
                            supply = order.supply, slot = order.slot }
            end
          end
        end
      end
    end

    if not sim:tick() then break end

    -- Release reservations for the tick that just executed. Doing this AFTER the
    -- tick is what keeps the invariant honest: during tick t the bank has not
    -- yet been charged for the orders executing on tick t.
    local done = inflight[t]
    if done then
      for i = 1, #done do
        local d = done[i]
        local res = g.res[d.side]
        res.levy = res.levy - d.levy
        if d.lane > 0 then res.supply[d.lane] = res.supply[d.lane] - d.supply end
        if d.slot > 0 then res.slot[d.slot] = 0; res.occ = res.occ - 1 end
      end
      inflight[t] = nil
    end
    if sim.over then break end
  end

  -- The generator's own sim is a FIFTH arrival pattern: every atom was queued at
  -- its issue tick, mid-run, interleaved with ticking. Recording its terminal
  -- hash lets the fuzzer check that replaying the written log reproduces the
  -- match the generator actually watched -- which is the property that makes a
  -- log an artifact rather than a suggestion.
  log.genHash = sim:stateHash()
  log.genTick = sim.clock

  return M.trim(log, sim.clock)
end

-- Drop the atoms whose exec tick falls at or after the tick the match ended on.
--
-- WHY THIS IS NOT CHEATING. Those atoms can never execute -- the sim is terminal
-- and Sim:tick() returns false -- so removing them changes no state and no
-- stateHash. What it removes is a HARNESS artifact: an atom that arrives after
-- the last tick is queued by a run that pre-delivers everything and is never
-- queued by a run that delivers on arrival ticks, so the two runs would report
-- different logDigests over a set of commands that neither one executed. The
-- interesting comparison is over the atoms that actually took part, and every
-- surviving atom has arrive <= exec < endTick, so all four arrival modes see the
-- identical set. A real client behaves the same way: the match is over, the peer
-- has stopped simulating, and a late atom is discarded rather than replayed.
function M.trim(log, endTick)
  local keep, n = {}, 0
  for i = 1, #log.cmds do
    local c = log.cmds[i]
    if c.tick < endTick then
      n = n + 1
      keep[n] = c
    end
  end
  log.cmds = keep
  log.endTick = endTick
  return log
end

-- Same trim for a log built without a sim: run it once to find the end.
function M.trimToMatch(log)
  local sim = SimM.new(Rules, log.seed, log.loadout[1], log.loadout[2])
  for i = 1, #log.cmds do sim:queueCommand(log.cmds[i]) end
  local budget = log.ticks or C.MATCH_TICKS
  for _ = 1, budget do
    if not sim:tick() then break end
  end
  return M.trim(log, sim.clock)
end

-- A deliberately ILLEGAL log: unaffordable orders, occupied slots, wrong slot
-- class, lane 4, count 12, the three M3 verbs (uppercase I/E/L per A.11.2). Not part of the milestone run --
-- every one of these is a fizzle, which is a much weaker test -- but the fizzle
-- path is still sim code and both clients must fizzle identically, so the
-- fuzzer runs a smaller chaos pass over it.
function M.makeChaos(seed, opts)
  opts = opts or {}
  local ticks = opts.ticks or C.MATCH_TICKS
  local r = Rand.new(seed + 99991)
  local log = logfmt.newLog(seed, ticks)
  log.name = "chaos:" .. seed
  local seq = { 0, 0 }
  local letters = {}
  for i = 1, #Rules.BUILDINGS do letters[i] = Rules.BUILDINGS[i].letter end
  local verbs = { "I", "E", "L" }
  local n = Rand.range(r, 20, 200)
  local list = {}
  for i = 1, n do
    local side = Rand.range(r, 1, 2)
    local exec = Rand.range(r, C.ORDER_DELAY, ticks - 1)
    local roll = Rand.range(r, 1, 100)
    local kind, target, count
    if roll <= 55 then
      kind = UNIT_KIND[Rand.range(r, 1, 3)]
      target = Rand.range(r, 1, 4)                    -- 4 is off the board
      count = Rand.range(r, 1, 12)                    -- above the atom's cap of 9
    elseif roll <= 90 then
      kind = letters[Rand.range(r, 1, #letters)]
      target = Rand.range(r, 1, 7)                    -- 7 is off the board
      count = 1
    else
      kind = verbs[Rand.range(r, 1, 3)]               -- M3 verbs: no-ops in M1
      target = Rand.range(r, 1, 3)
      count = Rand.range(r, 1, 4)
    end
    list[i] = { side = side, exec = exec, kind = kind, target = target, count = count }
  end
  -- seq must be monotonic per sender in ISSUE order, and issue order is exec
  -- order here, so sort by exec tick with a stable insertion sort before
  -- numbering. Sorting by anything but a value would be a determinism bug in the
  -- harness itself.
  for i = 2, n do
    local v = list[i]
    local j = i - 1
    while j >= 1 and list[j].exec > v.exec do
      list[j + 1] = list[j]
      j = j - 1
    end
    list[j + 1] = v
  end
  for i = 1, n do
    local c = list[i]
    seq[c.side] = seq[c.side] + 1
    local arrive = Rand.range(r, 0, c.exec)
    logfmt.add(log, c.exec, c.side, seq[c.side], c.kind, c.target, c.count, arrive)
  end
  return M.trimToMatch(log)
end

-- A permutation of 1..n, from the portable PRNG. Fisher-Yates, drawn downward so
-- the same seed gives the same permutation on every Lua build.
function M.permutation(n, seed)
  local r = Rand.new(seed)
  local p = {}
  for i = 1, n do p[i] = i end
  for i = n, 2, -1 do
    local j = Rand.range(r, 1, i)
    p[i], p[j] = p[j], p[i]
  end
  return p
end

return M
