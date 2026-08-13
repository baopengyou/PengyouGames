-- policy/lines.lua -- the sixteen scripted lines of the M2 sweep.
--
-- C.6 measured "sixteen scripted policies across four families (pure aggression,
-- pure economy, pure defence, mixed) playing a full round-robin" and named four
-- of them by their result: Rush-horse 77.8, Greed-pure 73.3, Turtle-eco 71.4,
-- Balanced 59.2. This file covers the same ground in the shipping language, with
-- those four carrying their C.6 names so the two models can be compared line for
-- line rather than only in aggregate.
--
-- WHAT A LINE IS FOR. Every one of them exists to put pressure on a DIFFERENT
-- claim in Part B or Part C, and each carries a note saying which. The sweep is
-- not a tournament, it is sixteen probes: if the median match length is wrong,
-- the per-line table says which claim moved.
--
-- WHY ONE PARAMETRIC ENGINE AND NOT SIXTEEN HAND-WRITTEN decide()s. Sixteen
-- bespoke functions is sixteen places for a determinism hazard to hide, and a
-- difference between two lines then has two possible causes -- the line, or the
-- code that implements it. One engine, sixteen configurations, means a
-- difference in the results table is a difference in the CONFIG and nothing
-- else. The engine itself is deliberately dull: it can place a building, react
-- to pressure with a defensive building, SPEND A CHEAP BODY ON SIGHT, and deploy
-- into a lane. That is the whole verb set a human has -- and the third of them
-- is new, because the owner's fog model made LOOKING a thing you buy with the
-- same Levy and the same clicks as fighting (../docs/IDLE_BATTLE_FOG.md
-- section 3). Four of the sixteen lines buy it, twelve do not, and which is
-- which is declared per line rather than emergent. See THE ATTENTION PARAMETER
-- below.
--
-- Held to sim/'s determinism rules (see policy/Policy.lua's header), because a
-- policy that drives a determinism test is sim-affecting code.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")

local M = {}

local floor = math.floor
local B = Policy.BLD_INDEX
-- Unit indices are written as the `mix` triple { spear, horse, bow } below, in
-- Rules.UNITS order. Named here so a reordering of that table is caught by the
-- assertion rather than by a line quietly buying the wrong unit.
if Policy.SPEAR ~= 1 or Policy.HORSE ~= 2 or Policy.BOW ~= 3 then
  error("lines: Rules.UNITS order moved; every mix triple in this file is wrong")
end

-- ---------------------------------------------------------------------------
-- the engine
-- ---------------------------------------------------------------------------

-- One poll produces at most one BUILDING order and at most one DEPLOY order, in
-- that order. The cap is not arbitrary: the view is rebuilt once per poll, so
-- two buildings chosen from one snapshot could both claim the same free slot or
-- the same Levy. Levy spent earlier in the poll is tracked in `claimed` and the
-- deploy is sized against what is left, which is exactly what the driver's
-- reservation will hold a moment later.
local function countDefensive(v)
  local n = 0
  for slot = 1, v.slotCount do
    local b = v.me.slots[slot].b
    if b > 0 and v.bldDefensive[b] == 1 then n = n + 1 end
  end
  return n
end

local function pickOpenSlot(v, st)
  if st.front == 1 then
    if st.lane > 0 then return Policy.freeSlot(v, true, st.lane) end
    -- An unscripted front slot goes where the pressure is; if that lane is
    -- taken, the lowest free front slot, so the choice never depends on
    -- anything but board numbers and slot order.
    local slot = Policy.freeSlot(v, true, Policy.pressedLane(v))
    if slot > 0 then return slot end
    return Policy.freeSlot(v, true, nil)
  end
  if st.lane > 0 then return Policy.freeSlot(v, false, st.lane) end
  return Policy.freeSlot(v, false, nil)
end

-- THE LEVY A LINE MAY NOT SPEND ON UNITS THIS POLL: what a building order in
-- this same poll has already taken, plus the whole price of the next opening
-- step once its notBefore has passed, plus any declared hoard. Hoisted out of
-- the deploy so the SCOUT is bought out of the same purse and after the same
-- reserve -- a tripwire that could be paid for with money the line is saving for
-- a Palisade would be free sight, which is the one thing the fog doc is explicit
-- that it must not be.
local function reserveFor(v, cfg, mem, tick, claimed)
  local r = claimed
  if mem.step <= cfg.nOpen and tick >= cfg.open[mem.step].notBefore then
    r = r + v.bldCost[cfg.open[mem.step].bi]
  end
  if tick < cfg.bankUntil then r = r + cfg.bankHold end
  return r
end

-- THE DEFENSIVE REFLEX, and it is the single most consequential parameter in
-- this file. A lane in this sim has exactly two states: contested, where two
-- fronts meet and grind at the midline and neither side advances, or FREE, where
-- one side walks 2,000 units to an undefended keep. So the question every line
-- answers, every second, is "do I answer what is coming at me, or do I keep
-- pushing where they are not?" -- and `react` is how much attention this line
-- pays. It is the knob that separates the four families in practice: an aggro
-- line answers late and rarely, a defensive line answers early and always.
--
-- WHAT THE LINE IS ALLOWED TO POINT THAT ATTENTION AT is a POSITION, reported
-- only for enemy units standing in a section this side can currently see. The
-- three-bucket muster bar the previous version leaned on was an invention of the
-- implementation and the owner's fog doc deletes it. What the doc puts in its
-- place is not another signal but a PURCHASE: sections 1-4 are free, so a line
-- that buys nothing sees a push at the midline and no sooner, and a line that
-- parks a body past the midline sees the same push SCOUT_SIGHT deep -- 250 units
-- and 25 Spear-ticks earlier -- for as long as that body lives. Which of the two
-- a line is, is declared (`cfg.scout`) and enforced by line() below.
--
-- Returns a lane to reinforce, or 0 for "nothing worth answering".
local function threatLane(self, v, cfg)
  if cfg.react <= 0 then return 0 end
  local best, bestScore = 0, -1
  for lane = 1, v.laneCount do
    local f = v.foe.lanes[lane]
    -- TRIGGER 1, CROSSED. f.maxPos is own-frame: how far their leading unit has
    -- advanced. Compared against a threshold in the SAME frame, so this reads
    -- identically from either seat -- there is no "my end" of the lane anywhere
    -- in it. Under DEFAULT vision an enemy unit is rendered only once it has
    -- crossed the midline (fog/Fog.lua's DEFAULT_SIGHT), so
    -- cfg.reactAt is a position in MY OWN HALF and line() below refuses to build
    -- a line that names one lower. Under the muster model a lower threshold was
    -- structurally DEAD; under the section model it is CONDITIONAL -- satisfiable
    -- only while one of this line's own units stands in that section -- which is
    -- a different failure, not the absence of one. The floor is kept for that
    -- reason and its message says so.
    local crossed = (f.n > 0 and f.maxPos >= cfg.reactAt)
    -- AND THERE IS NO TRIGGER 2 ANY MORE. There used to be one: a per-lane
    -- muster bar, which the previous fog model invented and the owner's fog doc
    -- deletes outright ("There is no early warning, no aggregate, and no
    -- 'something is coming' indicator", section 2; "This replaces the muster bar
    -- entirely ... the derived 2,800/5,600 HP thresholds are void", section 8).
    -- So a line's only warning is a unit it can actually SEE, and for a line
    -- that buys no sight that is very nearly too late: from the midline a Horse
    -- reaches the keep in 5 s against a 2 s order delay and a 1,000-unit march
    -- for the answer.
    --
    -- THE SAME LINE OF CODE IS AN EARLY-WARNING TRIGGER FOR A LINE THAT SCOUTS,
    -- and that is the whole of what the doc offers instead of the bar. f.maxPos
    -- is a maximum over units this side can SEE, so parking a body in the first
    -- fogged section pulls the earliest satisfiable reactAt from DEFAULT_SIGHT
    -- (1001, "they are already in my half") down to SCOUT_SIGHT (751, "they are
    -- still 250 units short of my half"). It is not a free rung: it lasts
    -- exactly as long as the body does, and the body is 10 Levy that did not
    -- become pressure.
    if crossed then
      local mine = v.me.lanes[lane]
      local deficit = f.supply - mine.supply
      if deficit > 0 and mine.room >= 10 then
        local over = f.maxPos - cfg.reactAt
        if over < 0 then over = 0 end
        local score = deficit + over
        if score > bestScore then best = lane; bestScore = score end
      end
    end
  end
  if best == 0 then return 0 end
  if not self:chance(cfg.react) then return 0 end
  return best
end

-- Returns the lane, and 1 if the choice was a THREAT answer. A threat answer
-- overrides minStack below: a line cannot wait for the perfect stack while they
-- are already in its half.
local function pickLane(self, v, cfg, tick)
  local mem = self.mem
  local mode = cfg.target
  -- Q10's constraint on the Fortress made mechanical: "a Fortress that repels
  -- the first waves must have a real conversion window". After convertAt the
  -- line stops guarding and starts pushing the lane they left open. Without
  -- this a defensive line has no path to a razed keep at all, and the ladder is
  -- the only thing it can win on -- which is precisely the pure-turtle exploit
  -- Q10 says must not exist.
  if tick >= cfg.convertAt then mode = cfg.convertTo end
  local minRoom = 10   -- the cheapest body, so "room" means room for something
  local threat = threatLane(self, v, cfg)
  if threat > 0 then return threat, 1 end
  if mode == "open" then
    local l = Policy.openLane(v)
    if l > 0 and v.me.lanes[l].room >= minRoom then return l end
  elseif mode == "focus" then
    local l = mem.favLane
    if v.me.lanes[l].room >= minRoom then return l end
  elseif mode == "twin" then
    local a, b = mem.favLane, mem.favLane2
    if mem.twinFlip == 1 then a, b = b, a end
    mem.twinFlip = 1 - mem.twinFlip
    if v.me.lanes[a].room >= minRoom then return a end
    if v.me.lanes[b].room >= minRoom then return b end
  elseif mode == "spread" then
    for k = 0, v.laneCount - 1 do
      local c = ((mem.nextLane - 1 + k) % v.laneCount) + 1
      if v.me.lanes[c].room >= minRoom then
        mem.nextLane = (c % v.laneCount) + 1
        return c
      end
    end
    return 0
  elseif mode == "guard" then
    local l = Policy.pressedLane(v)
    if l > 0 and v.me.lanes[l].room >= minRoom then return l end
  end
  -- Fallback: the emptiest lane. Ties by lowest lane index (determinism rule 6).
  local best, bestRoom = 0, minRoom - 1
  for lane = 1, v.laneCount do
    local r = v.me.lanes[lane].room
    if r > bestRoom then best = lane; bestRoom = r end
  end
  return best
end

local function pickType(self, v, cfg, lane, reserve)
  -- The counter draw first: Q3's triangle is the only in-sim reason to change
  -- type, and a line that never reads it cannot test whether the triangle is
  -- load-bearing (C.3 says Bow's multi-target makes it so).
  if cfg.counter == 1 and self:chance(cfg.counterPct) then
    local t = Policy.counterType(v, lane)
    if t > 0 and Policy.affordCount(v, lane, t, reserve) >= 1 then return t end
  end
  local w1, w2, w3 = 0, 0, 0
  if cfg.mix[1] > 0 and Policy.affordCount(v, lane, 1, reserve) >= 1 then w1 = cfg.mix[1] end
  if cfg.mix[2] > 0 and Policy.affordCount(v, lane, 2, reserve) >= 1 then w2 = cfg.mix[2] end
  if cfg.mix[3] > 0 and Policy.affordCount(v, lane, 3, reserve) >= 1 then w3 = cfg.mix[3] end
  local total = w1 + w2 + w3
  if total == 0 then return 0 end
  local roll = self:roll(1, total)
  if roll <= w1 then return 1 end
  if roll <= w1 + w2 then return 2 end
  return 3
end

local function decide(self, v, tick, out)
  local cfg = self.def.cfg
  local mem = self.mem
  local me = v.me
  local n = 0
  local claimed = 0

  -- 1. THE SCRIPTED OPENING, in order, one step at a time.
  -- Affordability is checked at BASE cost against `spendable`, which already
  -- excludes every order still in flight, and every M1 cost modifier is a
  -- discount -- so a step judged affordable here is still affordable when the
  -- sim judges it 20 ticks later. The sweep asserts cmdsFizzled stays low, which
  -- is what keeps that claim honest.
  if mem.step <= cfg.nOpen and tick <= cfg.stopBuildAt then
    local st = cfg.open[mem.step]
    if tick >= st.notBefore then
      local cost = v.bldCost[st.bi]
      if me.spendable >= cost then
        local slot = pickOpenSlot(v, st)
        if slot > 0 then
          n = Policy.buildOrder(out, n, st.bi, slot)
          claimed = cost
          mem.step = mem.step + 1
        end
      end
    end
  end

  -- 2. REACTIVE DEFENCE. Only if the opening did not already spend this poll:
  -- two buildings chosen from one snapshot can collide on a slot.
  if n == 0 and cfg.defend ~= nil and tick >= cfg.defend.notBefore
    and tick <= cfg.stopBuildAt and countDefensive(v) < cfg.defend.max then
    local lane = Policy.pressedLane(v)
    if lane > 0 and v.foe.lanes[lane].supply >= cfg.defend.at then
      local slot = Policy.freeSlot(v, true, lane)
      local cost = v.bldCost[cfg.defend.bi]
      if slot > 0 and me.spendable >= cost then
        n = Policy.buildOrder(out, n, cfg.defend.bi, slot)
        claimed = cost
      end
    end
  end

  -- 3. SCOUT -- a cheap body spent on SIGHT instead of on pressure.
  --
  -- THE FOG DOC'S CENTRAL NEW MECHANIC, AND UNTIL THIS PASS NO LINE IN THE
  -- ROSTER TOUCHED IT. Section 3: "send one cheap body forward and you buy sight
  -- of exactly where it is standing, for exactly as long as it lives... vision
  -- is earned and lost continuously through a match rather than being a fixed
  -- property of a build."
  --
  -- FOUR PROPERTIES, EACH OF WHICH IS THE ANSWER TO A WAY THIS COULD BE CHEATING
  -- RATHER THAN PLAYING:
  --
  --   1 IT IS DECLARED, PER LINE, AND MOST LINES DO NOT DECLARE IT. `cfg.scout`
  --     is 0 for twelve of the sixteen. A roster where everybody scouts measures
  --     the mechanic no better than one where nobody does: it has to COST
  --     something to somebody, and the twelve that pay nothing for it are the
  --     controls that make the four that do readable.
  --   2 IT IS PAID FOR OUT OF THE SAME PURSE, AFTER THE SAME RESERVE. The scout
  --     goes through Policy.affordCount against reserveFor(), exactly as the
  --     army does, so a tripwire is a Spear that did not go into the push and a
  --     building it delays is a building bought later.
  --   3 IT COSTS A CLICK. It is one of the at most MAX_ORDERS_PER_POLL orders a
  --     poll may carry, and the deploy below is skipped when the scout has taken
  --     the second one. A line cannot look and swing in the same second.
  --   4 IT LOOKS ONLY AT ITS OWN BOARD. Policy.darkLane reads `lit`, `seen` and
  --     `maxPos` of THIS side's lanes and nothing else -- a rule that read the
  --     enemy half to decide where to scout would be answering the question the
  --     scout exists to ask. It also returns 0 when every lane is fully visible,
  --     which is what stops a scouting line from spending bodies for nothing
  --     under the "full" regime and keeps that column an upper bound.
  --
  --   5 HOW OFTEN IT LOOKS IS DECLARED TOO, AND IT IS THE AXIS THE ROSTER USED
  --     TO HAVE ONLY ONE POINT ON. `cfg.scoutEvery` defaults to
  --     Policy.SCOUT_EVERY (220 ticks, one lane held continuously) and may go
  --     down to Policy.SCOUT_EVERY_MIN (86, every lane held at once). A line
  --     that pays three times as much for eyes is a different strategy from one
  --     that keeps a single tripwire alive, and until this pass the roster could
  --     not express the difference: four lines all bought sight at exactly the
  --     same rate, so `lit` measured where the roster FOUGHT and nothing else.
  if cfg.scout == 1 and n < Policy.MAX_ORDERS_PER_POLL and tick >= mem.nextScout then
    local lane = Policy.darkLane(v)
    if lane > 0 then
      local t = Policy.SCOUT_TYPE
      local reserve = reserveFor(v, cfg, mem, tick, claimed)
      if Policy.affordCount(v, lane, t, reserve) >= 1 then
        n = Policy.deployOrder(out, n, t, lane, 1)
        claimed = claimed + v.unitCost[t]
        mem.nextScout = tick + cfg.scoutEvery
      end
    end
  end

  -- 4. DEPLOY.
  if n < Policy.MAX_ORDERS_PER_POLL and tick >= cfg.hold and tick >= mem.nextDeploy
    and (cfg.holdUntilBuilt == 0 or mem.step > cfg.nOpen) then
    -- THE RESERVE. Levy being saved for the next building is not available for
    -- units, and it has to be the WHOLE price: a partial reserve cannot buy
    -- anything, because at 10 Levy per 3.5 s Levy tick against a deploy every
    -- second, holding back half of a 110-Levy tower leaves the bank hovering
    -- just above 55 forever -- every Levy above the reserve is spent the moment
    -- it lands. So a building is bought by going QUIET for the ~40 s it takes to
    -- save its price, and that lost army tempo, not the Levy, is what a building
    -- really costs. Measuring it honestly is the whole point of the re-sweep.
    --
    -- TRIED AND REJECTED: suspending the reserve while answering a breakthrough,
    -- on the theory that a line which keeps saving through one is broken. It
    -- makes every building line strictly better at no cost (it both builds and
    -- defends), and the sweep moves the wrong way on all four C.6 clauses at
    -- once -- median 407 -> 481 s, razed keeps 82.9% -> 67.0%, family spread
    -- 15.2 -> 23.7pp, because the whole board stops breaking open. Recorded here
    -- because it reads like an obvious improvement and is not.
    --
    -- (Those three figures were measured under the FULL-INFORMATION regime and
    -- against the roster before the Counterpunch fix, so they are the right
    -- order of magnitude and not this tree's current numbers. The direction is
    -- what the note is for and the direction is not in doubt.)
    local reserve = reserveFor(v, cfg, mem, tick, claimed)
    local lane, answering = pickLane(self, v, cfg, tick)
    if lane > 0 then
      local t = pickType(self, v, cfg, lane, reserve)
      if t > 0 then
        local mx = Policy.affordCount(v, lane, t, reserve)
        -- MINIMUM STACK. Units arrive one at a time into a lane that is already
        -- fighting and are killed one at a time; the same Levy delivered
        -- together survives the trip. This is what C.5's "3-Horse opening" is:
        -- 90 Levy held until it can go in as one wave, not three Horses fed in
        -- over 30 s. Waived when answering a threat -- nobody waits for a
        -- perfect stack while the enemy is already inside their half -- and
        -- waived when the lane could not hold the stack anyway.
        local want = cfg.minStack
        if answering == 1 or v.me.lanes[lane].room < want * v.unitCost[t] then want = 1 end
        if mx >= want and mx >= 1 then
          local count = mx
          if not self:chance(cfg.mass) then count = self:roll(1, mx) end
          if count < want then count = want end
          n = Policy.deployOrder(out, n, t, lane, count)
          mem.nextDeploy = tick + cfg.cadence
        end
      end
    end
  end

  return n
end

local function init(self)
  local mem = self.mem
  -- The favourite lane is drawn once per match from this instance's own stream.
  -- It is a lane INDEX, which means the same thing to both sides -- no side is
  -- ever named, so the line plays seat 1 and seat 2 identically.
  mem.favLane = self:roll(1, 3)
  mem.favLane2 = (mem.favLane % 3) + 1
  mem.twinFlip = 0
  mem.nextLane = mem.favLane
  mem.step = 1
  mem.nextDeploy = 0
  -- The scout clock. 0 means "the first poll may buy eyes", which is where a
  -- tripwire has to start: a Horse rush deployed at tick 20 is at the midline by
  -- tick 120, and a Spear ordered at tick 0 is past it at tick 121.
  mem.nextScout = 0
end

-- ---------------------------------------------------------------------------
-- configuration
-- ---------------------------------------------------------------------------

-- open steps are written as { "levyPost", "back" } or { "trapPit", "front", lane, notBefore }.
local function step(t)
  local key = t[1]
  local bi = B[key]
  if bi == nil then error("lines: no such building: " .. tostring(key)) end
  return {
    bi = bi,
    front = (t[2] == "front") and 1 or 0,
    lane = t[3] or 0,
    notBefore = t[4] or 0,
  }
end

-- THE CANONICAL cfg FIELD LIST, and it is authoritative rather than descriptive:
-- line() below rebuilds every cfg THROUGH this list, so a cfg's key set IS this
-- list by construction. sweep/probe.lua asserts its own copy against it in both
-- directions, which is what stops a controlled probe from silently inheriting an
-- engine default for a field it has never heard of and calling the result
-- controlled. Ordered, so neither comparison needs pairs().
M.CFG_FIELDS = {
  "open", "nOpen", "holdUntilBuilt", "hold", "bankUntil", "bankHold",
  "stopBuildAt", "defend", "mix", "counter", "counterPct", "target", "mass",
  "cadence", "react", "reactAt", "minStack", "convertAt", "convertTo", "scout",
  "scoutEvery",
}

-- The only field that is legitimately absent: a line with no reactive building.
local CFG_OPTIONAL = { defend = true }

local function line(t)
  local cfg = {
    open = {},
    nOpen = 0,
    holdUntilBuilt = t.holdUntilBuilt or 0,
    hold = t.hold or 0,
    -- Hoarding, expressed the way a person would: keep this much unspent until
    -- this tick, and answer threats out of what is left. C.2 claims a hoard
    -- cannot be converted fast enough to buy tempo at a 200 bank cap, so a line
    -- using this should mostly produce WASTE, and the sweep prints that column.
    bankUntil = t.bankUntil or 0,
    bankHold = t.bankHold or 0,
    -- C.4: "a Levy Post purchased after t = 370 s never pays for itself".
    -- Past the two-thirds mark every line stops buying and spends.
    stopBuildAt = t.stopBuildAt or 3700,
    defend = nil,
    mix = t.mix or { 1, 1, 1 },
    counter = t.counter or 0,
    counterPct = t.counterPct or 70,
    target = t.target or "open",
    mass = t.mass or 90,
    cadence = t.cadence or 10,
    react = t.react or 0,
    -- Own-frame position their leading unit must have reached before this line
    -- calls it a threat, and now the ONLY attention parameter a line has: the
    -- muster bar is deleted and the fog doc replaces it with nothing at all
    -- (section 2, "There is no early warning, no aggregate, and no 'something
    -- is coming' indicator"). REACT_MIN -- Fog.DEFAULT_SIGHT, the midline plus
    -- one, "the instant anything crosses" -- is both the default and the floor
    -- asserted below.
    reactAt = t.reactAt or Policy.REACT_MIN,
    minStack = t.minStack or 1,
    convertAt = t.convertAt or 999999,
    convertTo = t.convertTo or "open",
    -- DOES THIS LINE BUY SIGHT? 1 or 0, and the default is 0 on purpose: a
    -- roster where scouting is the default measures a mechanic nobody is paying
    -- for just as surely as one where it is absent. Twelve of the seventeen
    -- leave it 0 and are the controls.
    scout = t.scout or 0,
    -- AND HOW OFTEN. Ticks between tripwires, defaulting to the one-lane
    -- cadence and floored at the all-lanes one; both are derived in Policy.lua
    -- from C.1 and C.3. This is the axis that separates a line keeping a single
    -- body alive somewhere from a line whose whole plan is eyes.
    scoutEvery = t.scoutEvery or Policy.SCOUT_EVERY,
  }
  if t.open then
    for i = 1, #t.open do cfg.open[i] = step(t.open[i]) end
    cfg.nOpen = #t.open
  end
  if t.defend then
    local bi = B[t.defend[1]]
    if bi == nil then error("lines: no such building: " .. tostring(t.defend[1])) end
    cfg.defend = { bi = bi, at = t.defend[2], max = t.defend[3], notBefore = t.defend[4] or 0 }
  end
  -- THE ASSERTION THAT MAKES THIS STICK, AND IT NOW HAS TWO FLOORS BECAUSE THE
  -- FOG MODEL HAS TWO KINDS OF LINE. M2's first fogged measurement was taken
  -- with eleven of sixteen lines naming a position nothing ever rendered at, and
  -- nothing anywhere went red: the predicate does not fail, it quietly becomes a
  -- different one. That is the same failure mode as the duplicate table key
  -- grep 8 now catches -- a value the source declares and the run does not have
  -- -- so it gets the same treatment: the build stops.
  --
  --   a line that buys NO sight  -> REACT_MIN (1001). Its first free section
  --                                 begins at the midline and there is nothing
  --                                 below it to react to.
  --   a line that DECLARES A SCOUT -> SCOUT_SIGHT (751), the deepest enemy
  --                                 own-frame position the first bought section
  --                                 renders. Below that the threshold needs a
  --                                 body deeper than the midline, which is not
  --                                 what a tripwire is, and it would be back to
  --                                 naming a position the line has not paid for.
  local floorPos = (cfg.scout == 1) and Policy.SCOUT_SIGHT or Policy.REACT_MIN
  if cfg.reactAt < floorPos then
    error("lines: " .. tostring(t.name) .. " declares reactAt " .. cfg.reactAt
      .. ", below the " .. floorPos .. " its declared sight can deliver."
      .. " Under the fog model an enemy unit down there is rendered only while"
      .. " one of THIS line's own bodies stands in the same 250-unit section,"
      .. " so the threshold is not dead -- it is CONDITIONAL on ground this line"
      .. " has bought, which is a different strategy again from the one the"
      .. " source describes. Declare scout = 1 and pay for it, or raise the"
      .. " threshold; it may not be crossed by accident.")
  end
  -- A tripwire is not the army, but `holdUntilBuilt` says "field NOTHING until
  -- the opening stands", and a line cannot mean both. Refused rather than
  -- silently resolved, because either resolution would be an unstated choice
  -- about what the line is.
  if cfg.scout == 1 and cfg.holdUntilBuilt == 1 then
    error("lines: " .. tostring(t.name) .. " declares both scout = 1 and"
      .. " holdUntilBuilt = 1. The second says it fields nothing until its"
      .. " opening stands and the first spends a body on sight before then.")
  end
  -- A cadence is a property of buying eyes, so a line that buys none may not
  -- name one: it would be a configuration field the run does not have, which is
  -- the class of defect grep 8 exists for.
  if cfg.scout == 0 and t.scoutEvery ~= nil then
    error("lines: " .. tostring(t.name) .. " declares scoutEvery without"
      .. " scout = 1, so it names a cadence for something it never does.")
  end
  if cfg.scoutEvery < Policy.SCOUT_EVERY_MIN then
    error("lines: " .. tostring(t.name) .. " declares scoutEvery "
      .. cfg.scoutEvery .. ", under the " .. Policy.SCOUT_EVERY_MIN
      .. " it takes one cheapest body to traverse a lane, divided by the number"
      .. " of lanes there are to watch, plus one order delay."
      .. " Faster than that is a second pair of eyes standing on ground the"
      .. " first pair already lights, which is not sight bought but Levy burnt.")
  end
  -- Rebuild through the canonical list. A name in the list that the literal
  -- above does not produce errors here; a key the literal produces that the list
  -- does not name does not survive, so it cannot reach the engine and be read as
  -- configuration nobody declared.
  local out = {}
  for i = 1, #M.CFG_FIELDS do
    local k = M.CFG_FIELDS[i]
    local v = cfg[k]
    if v == nil and not CFG_OPTIONAL[k] then
      error("lines: line() produced no cfg." .. k .. " for " .. tostring(t.name))
    end
    out[k] = v
  end
  return Policy.define({
    name = t.name,
    family = t.family,
    note = t.note,
    cfg = out,
    init = init,
    decide = decide,
  })
end

-- ---------------------------------------------------------------------------
-- THE SEVENTEEN LINES
--
-- Four per family, and a fifth in `mixed`: `Pathfinder`, whose whole identity is
-- buying sight. It is an ADDITION and not a replacement, and that is deliberate
-- -- every other line carries a Part B or Part C claim nothing else tests, and
-- README open item 10 says in terms that deleting lines biases family means.
-- The cost of adding rather than replacing is stated where it lands: the sweep
-- is 1,632 matches instead of 1,440, `mixed` is a five-line family, and every
-- match seed moves because the seed schedule is keyed to the ordinal of the
-- ordered pair. So the before/after of the scouting pass is a ROSTER change
-- measured at the same seed base, not the same matches replayed.
--
-- Within a family the lines are deliberately far apart, because
-- C.6's headline finding is that the spread WITHIN an archetype (26.9-55.0pp) is
-- five times the spread BETWEEN archetypes (7.0pp) -- a sweep whose four aggro
-- lines all play the same way cannot reproduce that and would report a family
-- spread that means nothing.
--
-- ===========================================================================
-- THE ATTENTION PARAMETER, AND THE FOUR LINES THAT NOW PAY FOR IT
--
-- HISTORY, because three successive corrections have moved these sixteen lines
-- and the fourth reader deserves the whole chain rather than the last link.
--
--   1 ORIGINALLY every line declared one `reactAt`, an own-frame position their
--     leading unit had to reach before the line answered. Eleven of the sixteen
--     put it in the ENEMY's half. Nothing rendered there, so all eleven
--     silently became "the instant anything crosses" (README Finding 7).
--   2 THE SECOND PASS split the intent in two: `reactAt` at REACT_MIN plus an
--     `alarm` against a three-bucket muster bar, so a line that wanted to answer
--     BEFORE contact still could.
--   3 THE THIRD PASS DELETED THE ALARM, because the owner's fog doc deletes the
--     bar it read (section 8.1). That left six lines -- Turtle-pure, Turtle-eco,
--     Wall, Counterpunch, Greed-pure, Adaptive -- carrying an intent to answer
--     pressure early with no channel of any kind to express it, and the roster
--     was published in that state with the gap named as an open item.
--   4 THIS PASS CLOSES IT THE WAY THE DOC SAYS TO: by BUYING sight. Section 3
--     makes vision a purchase -- "send one cheap body forward and you buy sight
--     of exactly where it is standing, for exactly as long as it lives" -- and a
--     body parked in the first fogged section pulls the earliest satisfiable
--     threshold from 1001 to 751. So "answer a push before it arrives" is
--     expressible again, at a price, and FOUR lines pay it.
--
--   5 THE FIFTH PASS -- this one -- ADDED THE MISSING END OF THE AXIS AND THE
--     AXIS ITSELF. The four lines above all bought sight at exactly one rate,
--     the derived 220-tick default, and `sweep/fogaudit.lua` measured the
--     consequence: `lit` ran 4.2-4.9 sections out of 8 across all sixteen
--     against a free floor of 4.00, with the scouts indistinguishable from the
--     attackers. A roster in which every line that looks at all looks the same
--     amount cannot price looking. So `scoutEvery` is now a declared per-line
--     field, and `Pathfinder` -- a new line whose entire plan is eyes, at the
--     derived floor of 86 ticks -- is the far end of it. The other four keep the
--     default rate, unchanged, because their intent is a tripwire and not a
--     survey; twelve lines still buy nothing.
--
-- WHO SCOUTS, AND WHY EACH ONE AND NOT THE OTHER TWELVE. The test applied to
-- every line was one question: does this line's OWN STATED INTENT require a
-- perception the fog grants only to a body standing in the enemy half? Five
-- answer yes, and each one is a different reason:
--
--   Pathfinder    it is the question. Every other line spends on sight only what
--                 its own plan needs; this one is the control at the far end,
--                 spending about 40% of its income on bodies that cannot kill.
--                 It is the only line whose `scoutEvery` is not the default.
--
--   Raid-counter  "buys the counter to what it SEES in the lane". Under fog it
--                 can only counter what has already crossed, which is the one
--                 moment the counter is worth least. A body in the lane it is
--                 about to hit is the only way the sentence stays true.
--   Turtle-eco    "meet every push". A push is met at the midline or it is not
--                 met; its old 700 was 300 units inside their half. The tripwire
--                 is what a defender buys instead of guessing.
--   Counterpunch  its entire idea is holding a reserve and SWINGING it at the
--                 right moment. There is no right moment without sight; without
--                 a scout the line is just a slow attacker with a hoard.
--   Adaptive      "the closest thing here to a person", and a person scouts. It
--                 also has the roster's only two sight-hungry sub-decisions at
--                 once: a reactive Arrow Tower keyed to enemy Levy in a lane,
--                 and a counter-type draw.
--
-- AND THE TWELVE THAT DO NOT ARE NOT AN OVERSIGHT -- they are what makes the
-- four measurable:
--
--   * Turtle-pure and Wall are the DEFENCE CONTROLS. Same family, same
--     buildings-first shape, no sight bought. Their old 600 and 800 are dropped
--     outright rather than re-expressed: a pure turtle that spends bodies
--     forward is not a pure turtle, and the line exists to probe Q10's "no
--     defensive victory" claim, which needs it to stay pure.
--   * Trader is the REACTIVE-BUILD CONTROL for Adaptive. The two are near-twins
--     -- both build defensively only where a lane is pressed -- and exactly one
--     of them buys the sight that makes the trigger fire in time. That pair is
--     the cleanest thing in the roster for pricing what a scout is worth.
--   * Skirmish is the EXPLORATION CONTROL. It spreads small deploys over all
--     three lanes and therefore lights more of the board than anyone, without
--     ever spending a body ON sight. It is what separates "explores" from
--     "scouts" in sweep/fogaudit.lua's `lit` column.
--   * THE WHOLE ECONOMY FAMILY BUYS NOTHING. Greed-pure's identity is "not a
--     single unit before the curve is up" and a tripwire is a unit; the other
--     three never claimed to pre-empt anything. So the economy lines pay for
--     their blindness in full, which is a statement about the family and is
--     reported rather than smoothed away.
--   * The three remaining aggro lines and Balanced attack on their own clock and
--     never claimed to read the enemy before contact.
--
-- WHAT WAS NOT DONE, STATED BECAUSE IT IS THE THING TO CHECK. No line's `react`,
-- `mix`, `cadence`, `mass`, `minStack`, `convertAt`, opening or family was
-- touched in this pass. The only fields that moved are `scout` (0 -> 1 on four
-- lines) and `reactAt` (back to a value those four can now actually deliver).
-- Nothing was chosen by running the sweep and looking at what moved, and the
-- two clauses that were failing were still failing afterwards.
-- ===========================================================================

M.LINES = {

  -- == AGGRO: no economy, no buildings, everything converted into bodies ====

  line{ name = "Rush-horse", family = "aggro",
    -- C.6's strongest single line (77.8) and the one it says to watch rather
    -- than pre-emptively nerf. Tests C.5's opening chain (1 Horse at 0.0 s,
    -- 2 at 10.5 s, 3 at 21.0 s) and whether 2x march is worth 3x cost. Answers
    -- a threat only once it is at the gates, which is the whole aggro bet --
    -- 1,400 is 400 past the midline and 100 past its own front slot, so it is
    -- rendered by free vision and this line survives every fog correction
    -- untouched: it never wanted a pre-contact warning and it buys none.
    --
    -- THE NOTE USED TO SAY "the least-defended lane" AND THAT IS A READ IT
    -- CANNOT MAKE. `target = "open"` scores lanes off Policy.openLane, whose
    -- enemy terms are all fogged: remembered buildings it has never stood beside
    -- and enemy Levy it can currently see. On a dark board every enemy term is
    -- 0 and the only surviving term is its OWN supply, so the rule degrades to
    -- "keep feeding the lane I am already in" -- which is a defensible rusher
    -- and is not what the old note described. NOTHING IN THE CONFIG CHANGED;
    -- the sentence did, because the sentence was wrong.
    note = "mass Horse into one lane, blind, no buildings, ever",
    mix = { 0, 1, 0 }, target = "open", mass = 100, cadence = 10,
    react = 28, reactAt = 1400, minStack = 3 },

  line{ name = "Rush-spear", family = "aggro",
    -- C.3 claims Spear is the best body per Levy (42 HP/Levy) and that the
    -- cheap body must not be worthless. This is that claim as a whole strategy:
    -- if Rush-spear collapses, the supply cap is behaving like v1's headcount
    -- cap, which is the exact defect Q4 reversed.
    --
    -- It also happens to be the roster's price list for scouting: the body this
    -- line masses IS the body the four scouting lines spend one at a time, so
    -- its win rate is what 10 Levy of pressure is worth against what 10 Levy of
    -- sight is worth. reactAt 1,250 is inside its own half and free: unchanged.
    note = "mass Spear, the cheapest body, from tick 0 -- the price list for a scout",
    mix = { 1, 0, 0 }, target = "open", mass = 100, cadence = 10,
    react = 36, reactAt = 1250, minStack = 1 },

  line{ name = "Split-push", family = "aggro",
    -- Slot cap 4 of 6 means at most two lanes can hold two buildings, so a
    -- two-lane attack must find a soft one. Tests whether splitting beats
    -- concentrating against a defence that can only be strong in two places.
    --
    -- AND IT IS THE ONE LINE IN THE ROSTER WHOSE LANE RULE READS NOTHING ABOUT
    -- THE ENEMY AT ALL: `target = "twin"` alternates two lanes drawn from its
    -- own PRNG at match start. It therefore plays IDENTICALLY under fog and
    -- under full information except for its threat answers, which makes it the
    -- natural control for how much the regime is worth to everyone else.
    -- reactAt 1,300 is exactly its own front slot: free vision, unchanged.
    note = "alternates two fixed lanes so the defence cannot cover both",
    mix = { 6, 3, 1 }, target = "twin", mass = 85, cadence = 10,
    react = 32, reactAt = 1300, minStack = 1 },

  line{ name = "Raid-counter", family = "aggro", scout = 1,
    -- Q3/C.3: the counter triangle is x1.5 into prey with no penalty term, and
    -- Bow hits 3. A line that always answers the lane's dominant type measures
    -- how much the triangle is worth to someone who reads the board.
    --
    -- IT SCOUTS, AND THE REASON IS ITS OWN NOTE. "The counter to what it SEES in
    -- the lane" is exact, and Policy.counterType has always counted only
    -- rendered units -- but under fog what it sees, with no sight bought, is
    -- whatever has ALREADY CROSSED into its own half. That is the single moment
    -- a counter draw is worth least: the wave is built, it is here, and the
    -- answer arrives two seconds and a march later. A raid that picks its type
    -- off the lane has to look at the lane first, so this line spends one Spear
    -- on the lane it is about to hit. THE COUNTER-DRAW ITSELF IS UNTOUCHED
    -- (counter = 1, counterPct = 85) and so is reactAt 1,150: the scout is
    -- bought for the TYPE decision and for openLane's lane choice, not to move
    -- the threat threshold, which is why this is the one scouting line whose
    -- reactAt did not change.
    note = "aggression that scouts a lane, then buys the counter to what is in it",
    mix = { 4, 3, 3 }, counter = 1, counterPct = 85, target = "open",
    mass = 90, cadence = 10, react = 44, reactAt = 1150,
    minStack = 1 },

  -- == ECONOMY: buy the curve first, convert later =========================

  line{ name = "Greed-pure", family = "economy",
    -- C.4's committed economy build: 2 Levy Posts + a Granary, nothing else
    -- until they stand. Earliest Levy Post at t = 31.5 s (C.4), so this line is
    -- defenceless for the first two minutes -- it is the direct test of "pure
    -- economy must have a live path to victory" and of the 370 s deadline.
    --
    -- HISTORY, AND THE ONE PLACE THIS PASS DELIBERATELY LEFT AN INTENT DEAD.
    -- reactAt was 900, 100 short of the midline: the line was written to answer
    -- just before contact and could not. Under the section model that intent is
    -- expressible again -- for 10 Levy -- and this line is REFUSED it, because
    -- its identity is the words "before a single unit". `holdUntilBuilt = 1` is
    -- the same statement in configuration, and line() now refuses a line that
    -- declares both that and a scout rather than resolving the contradiction
    -- quietly. So Greed-pure answers on the crossing trigger alone and pays for
    -- its blindness in full. THIS IS THE LINE THE FOG COSTS MOST AND IT IS NOT
    -- COMPENSATED ANYWHERE; the alternative was to make the pure-economy probe
    -- impure in order to improve its result, which is the trade this whole pass
    -- exists to refuse.
    note = "two Levy Posts and a Granary before a single unit, then all-in",
    open = { { "levyPost", "back" }, { "levyPost", "back" }, { "granary", "back" } },
    holdUntilBuilt = 1, mix = { 7, 2, 1 }, target = "open", mass = 100, cadence = 10,
    react = 56, reactAt = Policy.REACT_MIN, minStack = 1 },

  line{ name = "Greed-lite", family = "economy",
    -- One Levy Post, bought while still defending. C.4 prices the yield at +20%
    -- of base income with a 258 s payback; the question this line asks is
    -- whether ONE post is the efficient amount of greed.
    -- reactAt was the midline exactly -- "they are in my half" -- so it is
    -- REACT_MIN now, the same instant spelled in terms the fogged board
    -- reports. This line never asked to pre-empt, so it loses nothing.
    note = "one Levy Post held back for, then ordinary aggression",
    open = { { "levyPost", "back" } },
    mix = { 6, 3, 1 }, target = "open", mass = 90, cadence = 12,
    react = 48, reactAt = Policy.REACT_MIN, minStack = 1 },

  line{ name = "Granary-bank", family = "economy",
    -- Granary first (+1 Levy/tick and bank cap 200 -> 350), then deploys on a
    -- 4.5 s cadence with a 4-unit minimum stack, so its Levy goes in as big
    -- infrequent waves rather than a trickle.
    --
    -- IT DOES NOT TEST C.2's BANK CAP EITHER, and the note used to claim it
    -- would produce a large wasted-Levy column. It does not: measured over all
    -- 1,440 matches its `wasted` is 0 and its peak bank is ~220 against a 350
    -- cap, because `cadence` delays a deploy without ever asking the line to
    -- STOP spending -- `bankUntil`/`bankHold` are 0 here, so there is no hoard
    -- at all. C.2's "a cap on waste" claim is UNTESTED by M2; see README.
    note = "Granary first for the 350 cap, then deploys in big infrequent stacks",
    open = { { "granary", "back" } },
    mix = { 5, 3, 2 }, target = "open", mass = 100, cadence = 45,
    react = 44, reactAt = Policy.REACT_MIN, minStack = 4 },

  line{ name = "Late-eco", family = "economy",
    -- The other side of the 370 s deadline: fight first, buy the curve at
    -- t = 150 s and t = 250 s. If Late-eco beats Greed-pure the payback horizon
    -- in C.4 is too generous; if it is crushed, greed has to be early or not
    -- at all.
    note = "fights first, buys the economy at 150 s and 250 s",
    open = { { "levyPost", "back", 0, 1500 }, { "granary", "back", 0, 2500 } },
    mix = { 6, 2, 2 }, target = "open", mass = 85, cadence = 12,
    react = 52, reactAt = Policy.REACT_MIN, minStack = 1 },

  -- == DEFENCE: buildings first, and a conversion window ====================

  line{ name = "Turtle-eco", family = "defence", scout = 1,
    -- C.6's named defence line (71.4). Q10's constraint made concrete: a
    -- Fortress that repels the first waves must have a real conversion window,
    -- funded by repel refunds and Spoils. Trap Pit at 7 s (C.4), then a Levy
    -- Post, then a tower, then it attacks.
    --
    -- IT SCOUTS, AND "MEET EVERY PUSH" IS WHY. Meeting a push means being in the
    -- lane when it lands, and the answer takes 2 s of order delay plus a march;
    -- a defender who first learns of a wave when it crosses the midline is
    -- meeting it inside their own half or not at all. Its original 700 is not
    -- deliverable -- a body would have to hold section 6, 250 units past the
    -- midline, which is not a tripwire but an attack -- so the threshold is
    -- SCOUT_SIGHT (751), the nearest honest equivalent and the deepest warning
    -- one body parked past the midline can give. That is a 50-unit concession
    -- against the source's 700 and it is stated rather than rounded away.
    --
    -- IT IS ALSO THE LINE WHOSE `target = "guard"` NEEDED SIGHT MOST: Policy
    -- .pressedLane answers 0 on a board showing nothing, and this line deploys
    -- where that points. A tripwire is what turns "guard the pressed lane" back
    -- into a sentence with a referent.
    note = "Trap Pit, Levy Post, Arrow Tower, a tripwire to see the push, convert late",
    open = { { "trapPit", "front", 1 }, { "trapPit", "front", 2, 600 },
             { "trapPit", "front", 3, 1200 }, { "levyPost", "back", 0, 1800 } },
    mix = { 5, 2, 3 }, target = "guard", mass = 85, cadence = 15,
    react = 76, reactAt = Policy.SCOUT_SIGHT, minStack = 1, convertAt = 1800 },

  line{ name = "Turtle-pure", family = "defence",
    -- The pure-turtle exploit probe. Q10 says there is NO defensive victory and
    -- that every tier above 4 requires offence. This line fills its slot cap
    -- with defence and barely attacks; if it wins on the clock, the ladder has
    -- a hole in it. Its result is the most load-bearing single number here.
    -- HISTORY, AND WHY IT IS A CONTROL RATHER THAN A SECOND SCOUT. reactAt 600
    -- was the earliest threshold in the roster and the most thoroughly
    -- unreachable -- 13.1% of this line's threat detections under full
    -- information happen at or below the midline. Under the section model a
    -- tripwire would restore part of it, and this line is deliberately NOT given
    -- one: it exists to ask whether a side that commits NOTHING forward can win
    -- on Q10's ladder, and a body sent past the midline is a commitment forward.
    -- The 600 is dropped outright, not re-expressed. Turtle-eco, one line above,
    -- is the same family with the same buildings-first shape and a tripwire,
    -- which is what makes the pair readable.
    note = "four defensive buildings, minimal offence, nothing forward, plays for the ladder",
    open = { { "palisade", "front", 1 }, { "palisade", "front", 2, 700 },
             { "palisade", "front", 3, 1400 }, { "redoubt", "back", 0, 2100 } },
    mix = { 5, 1, 4 }, target = "guard", mass = 60, cadence = 25,
    react = 80, reactAt = Policy.REACT_MIN, minStack = 1, convertAt = 3000 },

  line{ name = "Wall", family = "defence",
    -- BUILD_BLOCKS_ADVANCE (Rules INTERPRETATION 3) plus an 8,800 HP Palisade
    -- in every lane: three slots of pure blocking, no damage at all. Tests
    -- whether "blocks advance" alone buys enough time to matter, and how long a
    -- full lane actually needs to chew through it.
    -- HISTORY: reactAt 800, inside the enemy half, so unreachable without a
    -- scout, and it is not given one. The claim under test is about the
    -- BUILDING -- does 8,800 HP of blocking buy enough time on its own -- so a
    -- version of this line that also bought early warning would be testing two
    -- things and attributing the result to one. The crossing trigger at
    -- REACT_MIN is all it has, and that is the experiment.
    note = "a Palisade in all three lanes, no towers, no eyes, then Bow pressure behind it",
    open = { { "palisade", "front", 1 }, { "palisade", "front", 2, 600 },
             { "palisade", "front", 3, 1200 } },
    mix = { 3, 1, 6 }, target = "guard", mass = 80, cadence = 20,
    react = 72, reactAt = Policy.REACT_MIN, minStack = 1, convertAt = 2400 },

  line{ name = "Counterpunch", family = "defence", scout = 1,
    -- A small standing reserve under Rules.BANK_CAP = 200, spent as one stack.
    -- It is the control that makes Granary-bank's result readable: same "hold
    -- some Levy back and swing it" idea at a tenth of the hoard.
    --
    -- IT DOES NOT TEST C.2's BANK CAP, and the note used to claim it did. See
    -- the note on Granary-bank and README's "what is NOT a finding" list: a
    -- `bankHold` is a RESERVE subtracted from spendable, not a hoard TARGET, so
    -- every Levy above the reserve is spent the tick it lands and the bank never
    -- approaches a cap. Measuring C.2 needs a BANK_CAP sweep, which nothing in
    -- this tree does yet.
    -- IT SCOUTS, AND IT IS THE CLEAREST CASE IN THE ROSTER. reactAt 900 was
    -- inside the enemy half. A line whose whole idea is to hold a reserve and
    -- SWING it has to know when to swing; with no sight bought, the only notice
    -- it gets is a unit already in its own half, at which point the reserve is
    -- not a counterpunch, it is a late block. 900 is inside the window one
    -- tripwire past the midline renders (SCOUT_SIGHT is 751), so the ORIGINAL
    -- THRESHOLD IS RESTORED VERBATIM rather than approximated -- the fog did not
    -- make it unreachable, it made it expensive, and this line pays.
    --
    -- The sight is bought out of the SAME 60-Levy reserve it is holding: the
    -- scout goes through reserveFor() like everything else, so a tripwire is 10
    -- Levy the swing no longer has. That is the trade the doc describes and it
    -- is not subsidised anywhere.
    note = "a Trap Pit in all three lanes, a tripwire to time the swing, 60 Levy held to 200 s",
    open = { { "trapPit", "front", 1 }, { "trapPit", "front", 2, 500 },
             { "trapPit", "front", 3, 1000 } },
    bankUntil = 2000, bankHold = 60, minStack = 3,
    mix = { 6, 3, 1 }, target = "open", mass = 100, cadence = 10,
    react = 56, reactAt = 900 },

  -- == MIXED: a bit of each, which is what a person actually does ===========

  line{ name = "Balanced", family = "mixed",
    -- C.6's named mixed line (59.2) and the sweep's reference point: one
    -- economy building, one defensive building, steady pressure. If Balanced
    -- swings hard when a rule changes, the change was structural.
    --
    -- ITS TRAP PIT IS THE OTHER HALF OF THE pressedLane FIX. The step declares
    -- no lane, so pickOpenSlot sends it wherever the pressure is -- and under
    -- fog there is no pressure to read for the first minutes of the match, so
    -- it used to go into lane 1 in every single match on both seats. It now
    -- goes to the lowest free front slot until the board says otherwise, which
    -- is a tiebreak rather than a fabricated read.
    --
    -- IT DOES NOT SCOUT, AND THE REASON IS THAT IT IS THE REFERENCE POINT.
    -- Balanced is one of the four lines C.6 names, and it is the line this
    -- README compares metric by metric against Part C. Its result is only worth
    -- something if the thing being compared is still "one economy building, one
    -- defensive building, steady pressure" -- adding a strategic axis C.6's
    -- policy certainly did not have would make the comparison meaningless in
    -- exactly the way open item 12 already complains about. "Into the open lane"
    -- is left in the note with this correction attached: on a dark board
    -- openLane has no enemy term to read, so what it actually means here is
    -- "into the lane I am already committed to".
    note = "one Levy Post, one Trap Pit, steady pressure, no eyes bought",
    open = { { "levyPost", "back" }, { "trapPit", "front" } },
    mix = { 5, 3, 2 }, target = "open", mass = 80, cadence = 15,
    react = 56, reactAt = Policy.REACT_MIN, minStack = 1 },

  line{ name = "Trader", family = "mixed",
    -- Economy plus REACTIVE defence: it only spends on a Trap Pit when a lane
    -- is actually threatened. Tests whether reacting is cheaper than pre-building
    -- -- the Spoils rule (Q1) says razing pays 75%, so building early into a
    -- lane that never gets attacked is a gift to the attacker.
    --
    -- ITS `defend` THRESHOLD IS READ OFF THE FOGGED BOARD AND ALWAYS WAS, which
    -- is why it is not restated here: cfg.defend.at is compared against
    -- v.foe.lanes[l].supply, and Policy.fillView has ALREADY fogged that field
    -- -- under the section model it is the base cost of the enemy units this
    -- side can actually SEE in that lane, not their true standing Levy.
    --
    -- IT IS THE NON-SCOUTING HALF OF A MATCHED PAIR, AND THAT IS THE POINT OF
    -- LEAVING IT ALONE. Trader and Adaptive are near-twins: both buy economy and
    -- both build a defensive front slot only where a lane is pressed, keyed to
    -- essentially the same number (80 here, 90 there). Adaptive buys the sight
    -- that makes the trigger fire while there is still time to lay a 60-tick
    -- Trap Pit; Trader does not, so its trigger fires when 80 Levy of enemy
    -- units are ALREADY IN ITS OWN HALF and the building lands behind them. That
    -- is the honest fogged reading of "reacting is cheaper than pre-building",
    -- and if the answer is now "no", the pair is what says so.
    note = "Granary and Levy Post, Trap Pits only once a push is already in its half",
    open = { { "granary", "back" }, { "levyPost", "back" } },
    defend = { "trapPit", 80, 2 },
    mix = { 5, 2, 3 }, target = "open", mass = 85, cadence = 15,
    react = 52, reactAt = Policy.REACT_MIN, minStack = 1 },

  line{ name = "Skirmish", family = "mixed",
    -- Q4's "a cost discount buys FLOW, never a bigger stack": supply is charged
    -- at base cost, so a line that never masses should still convert its whole
    -- income. Constant small deploys across all three lanes, nothing held back.
    --
    -- AND IT IS THE EXPLORATION CONTROL, WHICH IS A ROLE THE FOG MODEL GAVE IT
    -- FOR FREE. Trickling small stacks into all three lanes lights more of the
    -- board than any other line in the roster -- it topped `seen` at 7.72 of 8
    -- in the last audit -- without ever spending a single body ON sight. So
    -- Skirmish is what separates the two things sweep/fogaudit.lua's columns
    -- could otherwise be confused about: a high `lit` from an attack that
    -- happens to illuminate the ground it stands on, versus a high `lit` from a
    -- line that paid for it. It is deliberately NOT given a scout for that
    -- reason. reactAt 1,100 is inside its own half and free: kept verbatim.
    note = "small deploys spread over all three lanes, never masses, never scouts",
    mix = { 6, 2, 2 }, target = "spread", mass = 15, cadence = 10,
    react = 40, reactAt = 1100, minStack = 1 },

  line{ name = "Pathfinder", family = "mixed", scout = 1,
    scoutEvery = Policy.SCOUT_EVERY_MIN,
    -- THE LINE WHOSE WHOLE IDENTITY IS SIGHT, and the reason it exists is a
    -- measurement rather than a strategy. `sweep/fogaudit.lua` measured `lit`
    -- across the whole roster at 4.2-4.9 sections out of 8 against a FREE FLOOR
    -- OF 4.00: every line was within a section of buying nothing, and the four
    -- that declared a scout were indistinguishable from the twelve that did not.
    -- So the sweep was measuring the owner's fog model played by a roster that
    -- never used its central mechanic, and no delta in the table could be
    -- attributed to sight because nothing in the table had any.
    --
    -- THIS IS THE OTHER END OF THAT AXIS. A tripwire into the lane it is
    -- currently blindest in every SCOUT_EVERY_MIN ticks -- three times the rate
    -- any other line pays, which is the rate at which all three lanes are
    -- watched at once -- and everything left over into the cheapest bodies.
    -- No buildings, no economy, no hoard: it buys eyes and Spears and nothing
    -- else, so its result is the cleanest price this roster can put on
    -- information. MEASURED: 42.8 tripwires and 428 Levy a match, about a
    -- quarter of a side's base income, spent on bodies bought to look rather
    -- than to fight.
    --
    -- IT USES WHAT IT BUYS, WHICH IS WHAT MAKES IT A LINE AND NOT A PROP.
    -- reactAt is SCOUT_SIGHT, the deepest warning a body past the midline can
    -- deliver, and `react` 72 is high: this line answers a push it can see
    -- forming rather than one that has arrived. Its lane choice is
    -- Policy.openLane, whose enemy terms are dark for everybody else and are the
    -- one thing this line has actually paid to read.
    --
    -- WHY `mixed` AND NOT `aggro`, STATED BECAUSE THE LABEL IS AN INPUT TO A
    -- MILESTONE CLAUSE. By SHAPE it is an aggro line -- no buildings, no
    -- economy, everything converted into bodies. By INTENT it is not aggression
    -- at all: a third of its income buys nothing that can kill anything. The
    -- taxonomy has no information family, and `mixed` is the one whose
    -- definition is "a bit of each, which is what a person actually does", so
    -- that is where it goes. The family-spread clause moves on this choice, and
    -- README Finding 2 is the reason that is reported rather than solved: the
    -- clause cannot distinguish the real family labels from random ones.
    note = "eyes first: a fresh tripwire in its blindest lane three times as often as anyone, then cheap bodies into whatever the sight found",
    mix = { 8, 1, 1 }, target = "open", mass = 75, cadence = 12,
    react = 72, reactAt = Policy.SCOUT_SIGHT, minStack = 1 },

  line{ name = "Adaptive", family = "mixed", scout = 1,
    -- The closest thing here to a person: answer the lane being pressed with an
    -- Arrow Tower, attack whichever lane they left open, and buy the counter
    -- type. It is the line whose result says most about whether the scripted
    -- pool is under-defending Horse (C.6's stated caveat).
    --
    -- IT WAS THE LINE THE FOG DAMAGED MOST -- 20.2% of its threat detections
    -- under full information happen at or below the midline, the highest share
    -- in the roster -- BECAUSE IT IS THE LINE WITH THE MOST TO SEE. Three of its
    -- four decisions want the enemy half: a reactive Arrow Tower keyed to enemy
    -- Levy in a lane, a counter-type draw, and "attack the lane they left open"
    -- through Policy.openLane. All three are blind by default and all three
    -- become sentences again with one body past the midline, so this is the
    -- roster's clearest "a person would scout here".
    --
    -- reactAt 900 IS RESTORED VERBATIM: it sits inside the window one tripwire
    -- renders (SCOUT_SIGHT 751), so nothing about it is approximated. Every
    -- other field -- react 64, counterPct 60, the Arrow Tower at 90, the mix,
    -- the cadence -- is untouched. Trader is the same idea without the eyes and
    -- is left that way on purpose; the pair is the measurement.
    note = "scouts, answers pressure with a tower, attacks the lane they left open",
    defend = { "arrowTower", 90, 2 },
    mix = { 4, 3, 3 }, counter = 1, counterPct = 60, target = "open",
    mass = 85, cadence = 12, react = 64, reactAt = 900,
    minStack = 1 },
}

-- name -> definition, for the CLI. Direct index only, never iterated.
M.BY_NAME = {}
for i = 1, #M.LINES do M.BY_NAME[M.LINES[i].name] = M.LINES[i] end

-- Family membership as parallel arrays, so the sweep can walk families without
-- pairs() (determinism rule 2 -- the sweep is not sim code, but a report whose
-- row order changes between runs is a report nobody can diff).
M.FAMILY_MEMBERS = {}
for f = 1, #Policy.FAMILIES do M.FAMILY_MEMBERS[f] = {} end
for i = 1, #M.LINES do
  local f = Policy.FAMILY_INDEX[M.LINES[i].family]
  local t = M.FAMILY_MEMBERS[f]
  t[#t + 1] = i
end

return M
