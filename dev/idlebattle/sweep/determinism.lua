-- sweep/determinism.lua -- the policy layer's own M1.
--
-- M1 proved that the SIM is bit-identical over a fixed command log. M2 replaces
-- the fixed log with two programs that WRITE the log while the match runs, which
-- is a strictly larger determinism surface: a policy that reads a clock, calls
-- math.random, or iterates a map with pairs() produces a different command log
-- on the other client, and the two sims then agree perfectly about two different
-- matches. That failure is invisible to every M1 check, because M1 is handed the
-- log rather than generating it.
--
-- Four properties, each one a way the layer could be wrong:
--
--   A REPLAY      the same pairing at the same seed issues BYTE-IDENTICAL atoms
--                 and reaches the same stateHash and logDigest. This is the one
--                 that catches a policy reading anything it should not.
--   B ISOLATION   playing other matches in between changes nothing. Definitions
--                 are stateless and every instance owns its own memory and PRNG
--                 stream, so match n cannot depend on match n-1.
--   C MIRROR      seating the same pairing the other way round produces the
--                 exact mirror -- same winner (by SLOT), same length, same
--                 numbers with the two seats exchanged. This is A.2 at the
--                 policy layer: proof that no line can tell which side it is.
--   D GATE        no order is ever refused by Sim:queueCommand and no order is
--                 dropped for being unexpressible. If either happens the driver
--                 is issuing something a real client could not, and every number
--                 the sweep prints is measured against a hand that cheats.
--
--   usage: lua sweep/determinism.lua [pairings]     (default 40)
--
-- Tool-grade (it prints), but holds every other sim discipline; failure is
-- error(), which exits non-zero.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Rand = IB_SIM_MODULES and IB_SIM_MODULES.Rand or require("sim.Rand")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local lines = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local driver = IB_SIM_MODULES and IB_SIM_MODULES.driver or require("sweep.driver")

local floor = math.floor
local format = string.format

local NPAIR = tonumber(arg and arg[1]) or 40
-- BOTH REGIMES MUST REPLAY. M2 publishes two information regimes and each one is
-- a different set of reads inside Policy.fillView, so proving one deterministic
-- proves nothing about the other. The M2 gate runs this file once per regime.
if arg and arg[2] then Policy.setVision(arg[2]) end
local L = lines.LINES
local NL = #L

local fails = {}
local function fail(msg)
  fails[#fails + 1] = msg
  print("  FAIL " .. msg)
end

-- Fields that must survive every one of the four properties. Deliberately the
-- whole verdict plus the whole economy: a divergence that shows only in `wasted`
-- is still two clients watching two different matches.
local FIELDS = { "keepHp", "keepDamageDealt", "slotsDestroyed", "penetration",
                 "bank", "earned", "spent", "wasted", "levyFlat",
                 "unitsDeployed", "unitsLost", "unitsKilled", "bldLost",
                 "buildsDone", "cmdsExecuted", "cmdsFizzled",
                 "issued", "accepted", "refused" }

local function sameMatch(x, y, tag, mirror)
  local bad = 0
  if x.ticks ~= y.ticks then
    fail(format("%s: length %d vs %d", tag, x.ticks, y.ticks)); bad = bad + 1
  end
  if x.reason ~= y.reason or x.tier ~= y.tier then
    fail(format("%s: verdict %s/T%d vs %s/T%d", tag, x.reason, x.tier, y.reason, y.tier))
    bad = bad + 1
  end
  if x.winnerSlot ~= y.winnerSlot then
    fail(format("%s: winner slot %d vs %d", tag, x.winnerSlot, y.winnerSlot)); bad = bad + 1
  end
  if not mirror then
    if x.stateHash ~= y.stateHash then
      fail(format("%s: stateHash %s vs %s", tag, Hash.dec(x.stateHash), Hash.dec(y.stateHash)))
      bad = bad + 1
    end
    if x.logDigest ~= y.logDigest then
      fail(format("%s: logDigest %s vs %s", tag, Hash.dec(x.logDigest), Hash.dec(y.logDigest)))
      bad = bad + 1
    end
    -- FOG MEMORY, SIDE BY SIDE. It is deliberately OUTSIDE Hash.state
    -- (fog/Fog.lua's MEMORY block argues why), so a divergence in what a side
    -- REMEMBERS would be invisible to the two hashes above. This is the check
    -- that makes keeping it out of the state hash safe rather than merely
    -- convenient: memory is a fold over the shared state and the side index, so
    -- two runs of the same match must produce the same fold, bit for bit, on
    -- both sides. NOT checked under `mirror`, where the seats are swapped and
    -- the two stores swap with them -- the mirror case asserts the whole
    -- verdict and economy instead.
    for k = 1, 2 do
      if x.memHash[k] ~= y.memHash[k] then
        fail(format("%s: fog memory side %d %s vs %s", tag, k,
          Hash.dec(x.memHash[k]), Hash.dec(y.memHash[k])))
        bad = bad + 1
      end
    end
  end
  for k = 1, 2 do
    local a, b = x.slots[k], y.slots[k]
    for f = 1, #FIELDS do
      local key = FIELDS[f]
      if a[key] ~= b[key] then
        fail(format("%s: slot %d %s %d vs %d", tag, k, key, a[key], b[key]))
        bad = bad + 1
        if bad > 6 then return bad end
      end
    end
  end
  return bad
end

local function sameAtoms(x, y, tag)
  if x.nAtoms ~= y.nAtoms then
    fail(format("%s: %d atoms vs %d", tag, x.nAtoms, y.nAtoms))
    return 1
  end
  for i = 1, x.nAtoms do
    local a, b = x.atoms[i], y.atoms[i]
    if a.tick ~= b.tick or a.side ~= b.side or a.seq ~= b.seq
      or a.kind ~= b.kind or a.target ~= b.target or a.count ~= b.count then
      fail(format("%s: atom %d differs: t%d s%d #%d %s %d x%d  vs  t%d s%d #%d %s %d x%d",
        tag, i, a.tick, a.side, a.seq, a.kind, a.target, a.count,
        b.tick, b.side, b.seq, b.kind, b.target, b.count))
      return 1
    end
  end
  return 0
end

print("Idle Battle M2 -- policy determinism")
print(format("  rulesHash %s (%s)   lines %d   pairings %d",
  Hash.dec(Rules.rulesHash), Rules.rulesHash36, NL, NPAIR))
print(format("  vision %s   poll %d ticks, <= %d orders/poll = %d atoms/min (A.11.4 %d)",
  Policy.VISION, Policy.POLL, Policy.MAX_ORDERS_PER_POLL,
  Policy.CEILING_ATOMS_PER_MIN, Policy.WIRE_ATOMS_PER_MIN))

-- Deterministic pairing selection, from the portable PRNG. A test whose sample
-- changes between runs cannot be used to reproduce the failure it just found.
local r = Rand.new(20260812)
local checked, gateBad, mirrorBad = 0, 0, 0

for p = 1, NPAIR do
  local ia = Rand.range(r, 1, NL)
  local ib = Rand.range(r, 1, NL)
  if ib == ia then ib = (ib % NL) + 1 end
  local seed = 700000 + p * 613

  -- A. replay
  local x = driver.run({ a = L[ia], b = L[ib], seed = seed, record = true })
  local y = driver.run({ a = L[ia], b = L[ib], seed = seed, record = true })
  local tag = format("%s vs %s @%d", L[ia].name, L[ib].name, seed)
  sameMatch(x, y, "replay " .. tag, false)
  sameAtoms(x, y, "replay " .. tag)

  -- B. isolation: two unrelated matches in between, then the same pairing again
  driver.run({ a = L[(ia % NL) + 1], b = L[ib], seed = seed + 1 })
  driver.run({ a = L[ib], b = L[(ib % NL) + 1], seed = seed + 2 })
  local z = driver.run({ a = L[ia], b = L[ib], seed = seed, record = true })
  sameMatch(x, z, "isolation " .. tag, false)
  sameAtoms(x, z, "isolation " .. tag)

  -- C. mirror: the same pairing seated the other way round
  local m = driver.run({ a = L[ia], b = L[ib], seed = seed, swap = true })
  local before = #fails
  sameMatch(x, m, "mirror " .. tag, true)
  if #fails > before then mirrorBad = mirrorBad + 1 end

  -- D. gate. The same five counters and the same rate the M2 verdict asserts --
  -- mirrored here deliberately, because this file runs on 40 random pairings
  -- that the round-robin's frozen schedule may not contain, and a line that
  -- out-clicks the wire or gets its counts clamped is a line whose measured win
  -- rate belongs to a strategy nobody wrote.
  for k = 1, 2 do
    local d = x.slots[k]
    if d.refused ~= 0 or d.badKind ~= 0 or d.badTarget ~= 0
      or d.declinedRate ~= 0 or d.clampedCount ~= 0
      or d.atomsPerMin > Policy.WIRE_ATOMS_PER_MIN then
      gateBad = gateBad + 1
      fail(format("gate %s: slot %d refused %d, badKind %d, badTarget %d, "
        .. "declinedRate %d, clamped %d, %d atoms/min (budget %d)",
        tag, k, d.refused, d.badKind, d.badTarget, d.declinedRate,
        d.clampedCount, d.atomsPerMin, Policy.WIRE_ATOMS_PER_MIN))
    end
    if not x.over then
      fail(format("%s: match did not terminate", tag))
    end
  end

  checked = checked + 1
  if p % 10 == 0 then print(format("  %d pairings checked, %d failures", p, #fails)) end
end

-- Every line must at least be able to play a match, including against itself:
-- a line only ever seen in a random pairing sample can sit unexercised.
for i = 1, NL do
  local a = driver.run({ a = L[i], b = L[i], seed = 424242 + i, record = true })
  local b = driver.run({ a = L[i], b = L[i], seed = 424242 + i, record = true })
  sameMatch(a, b, "self " .. L[i].name, false)
  sameAtoms(a, b, "self " .. L[i].name)
  if a.slots[1].issued == 0 then
    fail(format("%s issued no orders at all in a mirror match", L[i].name))
  end
end

print("")
if #fails > 0 then
  print(format("FAILED: %d divergence(s) over %d pairings", #fails, checked))
  error("policy determinism red", 0)
end
print(format("PASS: %d pairings replay byte-identically, survive interleaving, "
  .. "and mirror when the seats are swapped; all %d lines play themselves",
  checked, NL))
