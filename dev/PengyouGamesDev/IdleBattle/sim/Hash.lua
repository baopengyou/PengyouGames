-- Hash.lua -- deterministic integer hashing for the Idle Battle simulation.
--
-- WHY THIS FILE EXISTS
-- The M1 milestone is "bit-identical stateHash after 6000 ticks". A hash is only
-- useful for that if it is *identical across Lua versions and platforms*, which
-- rules out every convenient shortcut:
--   * no string.format on numbers  (5.1 prints 3.0 as "3", 5.3 prints "3.0")
--   * no tostring on numbers       (same reason)
--   * no bitwise operators         (5.3 plus only; grep 3 and Lua 5.1 forbid them)
--   * no floats anywhere           (a float that differs in the last bit desyncs)
-- So this is a polynomial rolling hash over integers, modulo a prime, with every
-- intermediate product kept below 2^53 so it is exact both as a 5.1 double and as
-- a 5.3 plus integer.
--
-- WIDTH: 31 bits. A.11.1 specifies a 31-bit rulesHash carried as 6 base-36 chars
-- (36^6 = 2176782336 > 2^31), and a 5-char stateHash on the heartbeat.
--
-- ARITHMETIC BOUND: h < MOD = 2147483647 and MUL = 1000003, so the largest
-- intermediate is h * MUL + v + 1, under 2148000000000000, comfortably below
-- 2^53 = 9007199254740992. Exact in both number models.

local M = {}

local floor = math.floor
local sbyte = string.byte
local ssub = string.sub

local MOD = 2147483647   -- 2^31 - 1, prime
local MUL = 1000003      -- prime multiplier

M.MOD = MOD
M.MUL = MUL

-- Arbitrary non-zero seed (the FNV offset basis, reduced into range). Its only
-- job is to make an empty stream hash to something other than zero.
M.INIT = 2166136261 % MOD

function M.new()
  return M.INIT
end

-- Fold one integer into the accumulator.
-- v may be negative; Lua's % is floor-mod in every version, so v % MOD lands in
-- [0, MOD) identically under 5.1 doubles and 5.3 plus integers.
function M.int(h, v)
  return (h * MUL + (v % MOD) + 1) % MOD
end

-- Fold a boolean (or nil) as 1 or 0.
function M.bool(h, b)
  if b then return M.int(h, 1) end
  return M.int(h, 0)
end

-- Fold a string by its bytes. Length is folded first so that "ab" and "a".."b"
-- in different framings cannot collide.
function M.str(h, s)
  local n = #s
  h = M.int(h, n)
  for i = 1, n do
    h = M.int(h, sbyte(s, i))
  end
  return h
end

-- Fold a value of unknown scalar type (used by the rules walker, where a field
-- may be an integer or a short ASCII string).
function M.any(h, v)
  local t = type(v)
  if t == "number" then
    return M.int(M.int(h, 1), v)
  elseif t == "string" then
    return M.str(M.int(h, 2), v)
  elseif t == "boolean" then
    return M.bool(M.int(h, 3), v)
  elseif t == "nil" then
    return M.int(h, 4)
  end
  -- Tables and functions are never hashable content: a table address is not
  -- reproducible across machines. Reaching here is a programming error.
  error("Hash.any: unhashable type " .. t)
end

-- ---------------------------------------------------------------------------
-- Rendering. Only ever applied to an already-integral accumulator.
-- ---------------------------------------------------------------------------

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

-- Low `width` base-36 digits of h, zero padded. This is the wire form
-- (A.11.1 rulesHash is 6 chars, A.11.3 stateHash is 5).
function M.base36(h, width)
  local out = ""
  local v = h % MOD
  for i = 1, width do
    local d = v % 36
    out = ssub(B36, d + 1, d + 1) .. out
    v = floor(v / 36)
  end
  return out
end

-- Decimal rendering without tostring, so a 5.1 float accumulator and a 5.3
-- integer accumulator print the same characters.
function M.dec(h)
  local v = h % MOD
  if v == 0 then return "0" end
  local out = ""
  while v > 0 do
    local d = v % 10
    out = ssub(B36, d + 1, d + 1) .. out
    v = floor(v / 10)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The state hash (M1 milestone: it must cover EVERYTHING, not just the board).
--
-- Covered: match clock and terminal verdict, both loadouts, both banks, both
-- earned and wasted Levy accumulators, both keeps, every unit, every building
-- including construction progress and its start tick, per-lane supply, per-lane
-- rule accumulators, every tiebreak ladder counter including the depth-hold
-- timers, the command execution and fizzle counters, the card-gated building
-- unlocks, the PRNG state, and the per-side modifier runtime block.
--
-- DELIBERATELY NOT COVERED, and this is the one exclusion list: sd.cacheLevyFlat,
-- sd.cacheBankCap and sd.lanes[n].aura. All three are pure functions of the slots
-- (see Sim.recomputeSideDerived), so hashing them could only ever HIDE a stale
-- cache -- both clients would compute the same wrong number and agree. They are
-- checked instead by harness/runner.lua's `invariants`, which re-derives each one
-- from the hashed state. That is why the M1 gate must run harness/ and not only
-- the hash comparison.
--
-- Iteration is by numeric for over arrays and over explicit ordered key lists.
-- There is no pairs() anywhere: a hash that depended on table iteration order
-- would be the exact bug this file exists to catch.
-- ---------------------------------------------------------------------------

local function hashUnit(h, u)
  h = M.int(h, u.id)
  h = M.int(h, u.t)
  h = M.int(h, u.pos)
  h = M.int(h, u.hp)
  h = M.int(h, u.maxHp)
  h = M.int(h, u.cost)
  h = M.int(h, u.vg)
  return h
end

local function hashBuilding(h, b)
  if not b then
    return M.int(h, 0)
  end
  h = M.int(h, 1)
  h = M.int(h, b.id)
  h = M.int(h, b.b)
  h = M.int(h, b.hp)
  h = M.int(h, b.maxHp)
  h = M.int(h, b.cost)
  h = M.int(h, b.prog)
  h = M.int(h, b.startTick)
  h = M.int(h, b.need)
  h = M.int(h, b.done)
  h = M.int(h, b.spent)
  return h
end

local function hashSide(h, sd, R)
  local C = R.C
  h = M.int(h, sd.index)
  for i = 1, 5 do
    h = M.int(h, sd.loadout[i])
  end
  h = M.int(h, sd.bank)
  h = M.int(h, sd.earned)
  h = M.int(h, sd.wasted)
  h = M.int(h, sd.spent)
  h = M.int(h, sd.keepId)
  h = M.int(h, sd.keepHp)
  h = M.int(h, sd.keepDamageDealt)
  h = M.int(h, sd.slotsDestroyed)
  h = M.int(h, sd.unitsDeployed)
  h = M.int(h, sd.unitsLost)
  h = M.int(h, sd.unitsKilled)
  h = M.int(h, sd.bldLost)
  h = M.int(h, sd.cmdsExecuted)
  h = M.int(h, sd.cmdsFizzled)
  h = M.int(h, sd.wheelNum)

  -- static channel points (all zero until M3 loads modifiers)
  for i = 1, #sd.chan do
    h = M.int(h, sd.chan[i])
  end

  for lane = 1, C.LANES do
    local ln = sd.lanes[lane]
    h = M.int(h, ln.supply)
    h = M.int(h, ln.depth)
    h = M.int(h, ln.hold1)
    h = M.int(h, ln.hold2)
    h = M.int(h, ln.hold3)
    h = M.int(h, ln.muster)
    h = M.int(h, ln.bypass)
    h = M.int(h, ln.cwAcc)
    local us = ln.units
    h = M.int(h, #us)
    for i = 1, #us do
      h = hashUnit(h, us[i])
    end
  end

  for slot = 1, C.SLOTS do
    h = hashBuilding(h, sd.slots[slot])
    h = M.int(h, sd.rubble[slot])
  end

  -- Card-gated building unlocks. OWNED state (M3 cards write it, execBuild reads
  -- it), so it belongs in the hash: two clients disagreeing about whether a
  -- Caravan is buildable would otherwise hash equal until one of them built one.
  -- Walked over the catalogue length so a twelfth-plus building is covered for
  -- free.
  for b = 1, #R.BUILDINGS do
    h = M.int(h, sd.unlocks[b])
  end

  -- Modifier runtime block. M1 leaves modsOrder empty; M3 appends its latch and
  -- countdown names to modsOrder and the hash picks them up with no edit here.
  local order = sd.modsOrder
  h = M.int(h, #order)
  for i = 1, #order do
    local k = order[i]
    h = M.str(h, k)
    h = M.any(h, sd.mods[k])
  end
  return h
end

function M.state(sim)
  local R = sim.rules
  local C = R.C
  local h = M.new()
  h = M.int(h, sim.rules.rulesHash)
  h = M.int(h, sim.seed)
  h = M.int(h, C.MATCH_TICKS)
  h = M.int(h, sim.clock)
  h = M.bool(h, sim.over)
  h = M.int(h, sim.winner)
  h = M.int(h, sim.reasonCode)
  h = M.int(h, sim.tier)
  h = M.int(h, sim.nextEntityId)
  h = M.int(h, sim.rng.s)
  h = hashSide(h, sim.sides[1], R)
  h = hashSide(h, sim.sides[2], R)
  return h
end

-- Digest of the ordered command log (A.11.3 logDigest). Canonical order is
-- (execTick, side, seq) -- A.4 makes intra-tick order a hashed invariant, and
-- sim.log is kept in exactly that order by insertion.
function M.log(sim)
  local h = M.new()
  local log = sim.log
  h = M.int(h, #log)
  for i = 1, #log do
    local c = log[i]
    h = M.int(h, c.tick)
    h = M.int(h, c.side)
    h = M.int(h, c.seq)
    h = M.int(h, c.kindIdx)
    h = M.int(h, c.target)
    h = M.int(h, c.count)
  end
  return h
end

-- ---------------------------------------------------------------------------
-- REGISTRATION TAIL (M5), and the full argument for it -- the other engine
-- files carry a pointer here because this is the first of them the addon's
-- .toc loads. Inside WoW there is no require() and the loader DISCARDS a
-- chunk's return value, so the `return M` below reaches nobody in the addon;
-- the .toc's next file would then find nothing where its import looks.
-- dev/PengyouGamesDev/IdleBattle/Loader.lua creates the IB_SIM_MODULES global
-- before any engine file loads, and this tail hands the module over to the
-- files after it. That is the entire mechanism, and it is why the engine block
-- of that .toc is DEPENDENCY ORDER rather than grouping.
--
-- Under the headless harness IB_SIM_MODULES does not exist, the `if` is false,
-- and require() keeps working exactly as it always did. The tail adds no
-- state, touches no number, reads no clock, runs once at load, and is not on
-- the tick path, which is what makes it safe against the committed goldens
-- and tools/ci.sh. rawget rather than a bare read because absence is the
-- expected case. Same idiom, same argument, as the arcade's AR_SIM_MODULES
-- tails (devarcade/PengyouArcade/sim/Fixed.lua).
-- ---------------------------------------------------------------------------

local IB_REG = rawget(_G, "IB_SIM_MODULES")
if IB_REG then IB_REG.Hash = M end

return M
