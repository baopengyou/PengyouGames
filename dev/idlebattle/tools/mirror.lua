-- tools/mirror.lua -- the A.2 side-agnosticism test.
--
-- "The sim does not know which side is 'me'. It computes both halves with the
--  same code over side = 0 | 1."
--
-- The four greps prove no sim file MENTIONS local identity. This proves the
-- stronger, behavioural property: play a randomised match, then play the same
-- match with EVERY command's side flipped, and require the outcome to be the
-- exact mirror -- side 1's final numbers in the flipped run equal side 2's in
-- the original, and the winner swaps.
--
-- Anything that favours the host shows up here: a phase that moves side 1 first
-- and reads positions side 2 has not updated yet, a tiebreak that resolves the
-- host's way, an economy step evaluated in side order.
--
-- Usage: lua tools/mirror.lua [logs] [ticks]

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Sim = require("sim.Sim")
local Rand = require("sim.Rand")

local NLOGS = tonumber(arg and arg[1]) or 300
local NTICKS = tonumber(arg and arg[2]) or Rules.C.MATCH_TICKS

local UNIT_KINDS = { "S", "H", "B" }
local BLD = {}
for i = 1, #Rules.BUILDINGS do BLD[i] = Rules.BUILDINGS[i].letter end

local function makeLog(seed)
  local r = Rand.new(seed)
  local log, seq = {}, { 0, 0 }
  for _ = 1, Rand.range(r, 30, 140) do
    local side = Rand.range(r, 1, 2)
    seq[side] = seq[side] + 1
    local roll = Rand.range(r, 1, 100)
    local kind, target
    if roll <= 65 then
      kind = UNIT_KINDS[Rand.range(r, 1, 3)]; target = Rand.range(r, 1, 3)
    else
      kind = BLD[Rand.range(r, 1, #BLD)]; target = Rand.range(r, 1, 6)
    end
    log[#log + 1] = { side = side, seq = seq[side],
                      tick = Rand.range(r, Rules.C.ORDER_DELAY, NTICKS - 1),
                      kind = kind, target = target, count = Rand.range(r, 1, 9) }
  end
  return log
end

local function flip(log)
  local out = {}
  for i = 1, #log do
    local c = log[i]
    out[i] = { side = 3 - c.side, seq = c.seq, tick = c.tick,
               kind = c.kind, target = c.target, count = c.count }
  end
  return out
end

local function play(log, seed)
  local sm = Sim.new(Rules, seed)
  for i = 1, #log do sm:queueCommand(log[i]) end
  sm:run(NTICKS)
  return sm:result()
end

local FIELDS = { "keepHp", "keepDamageDealt", "slotsDestroyed", "penetration",
                 "bank", "earned", "wasted", "spent", "unitsDeployed",
                 "unitsLost", "unitsKilled", "bldLost",
                 "cmdsExecuted", "cmdsFizzled" }

-- ---------------------------------------------------------------------------
-- DETERMINISTIC REGRESSION: the resolve-tick credit ordering.
--
-- A credit is clipped against the RECEIVER's bank cap, and a building that dies
-- on the same resolve tick changes that cap. Paying Levy inside applyDamage's
-- `for s = 1, 2` walk clipped side 2's spoils against its PRE-destruction cap and
-- side 1's against its POST-destruction one, purely because of loop order.
--
-- The random-log path above finds this about 1 time in 2000. This case finds it
-- EVERY run: an exactly mirror-symmetric position where both sides raze the
-- other's Granary on one resolve tick, so any asymmetry in the payout is the
-- ordering and nothing else.
-- ---------------------------------------------------------------------------
local function symmetricCreditCase()
  local sm = Sim.new(Rules, 12345)
  local C = Rules.C
  local gi = Rules.BUILDING_BY_LETTER["d"]          -- Granary: cap +150, cost 100
  local bad = {}
  for s = 1, 2 do
    local sd = sm.sides[s]
    -- A finished Granary in each side's lane-1 BACK slot, byte-identical.
    sd.slots[2] = {
      id = 100 + s, b = gi, slot = 2, lane = 1,
      hp = 1, maxHp = Rules.BUILDINGS[gi].hp,
      cost = Rules.BUILDINGS[gi].cost,
      prog = 999, startTick = 0, need = 1, done = 1, spent = 0,
      snapHp = 0, pend = 0, pendSrc = 0,
    }
    sd.bank = 349                                    -- one under the 350 cap
    sd.earned = 349
  end
  for s = 1, 2 do sm.sides[s].cacheBankCap = 150; sm.sides[s].cacheLevyFlat = 1 end

  -- Kill both granaries on the same resolve tick, from the enemy, symmetrically.
  for s = 1, 2 do
    local sd = sm.sides[s]
    sd.slots[2].hp = 1
    sd.slots[2].pend = 0
  end
  -- Drive one resolve tick by hand: snapshot, then lethal damage to both, then
  -- let the sim's own applyDamage run through a normal tick.
  sm.clock = 100                                     -- a resolve tick
  for s = 1, 2 do sm.sides[s].slots[2].hp = 1 end
  -- Deal the damage the way the sim does: through pend, applied by phaseResolve.
  local savedHook = sm.hooks.onResolveStart
  sm.hooks.onResolveStart = function(sim)
    for s = 1, 2 do
      local b = sim.sides[s].slots[2]
      if b then b.pend = b.pend + 9999 end
    end
  end
  sm:tick()
  sm.hooks.onResolveStart = savedHook

  local a, b = sm.sides[1], sm.sides[2]
  if a.bank ~= b.bank then
    bad[#bad + 1] = string.format("bank %d vs %d", a.bank, b.bank)
  end
  if a.wasted ~= b.wasted then
    bad[#bad + 1] = string.format("wasted %d vs %d", a.wasted, b.wasted)
  end
  if a.earned ~= b.earned then
    bad[#bad + 1] = string.format("earned %d vs %d", a.earned, b.earned)
  end
  if a.slotsDestroyed ~= b.slotsDestroyed then
    bad[#bad + 1] = string.format("slotsDestroyed %d vs %d", a.slotsDestroyed, b.slotsDestroyed)
  end
  return bad, a.bank, a.wasted
end

local synthFails = 0
do
  local bad, bank, wasted = symmetricCreditCase()
  if #bad > 0 then
    synthFails = 1
    print("ASYMMETRY in the synthetic same-tick spoils case:")
    for j = 1, #bad do print("   " .. bad[j]) end
  else
    print(string.format(
      "ok   same-tick mutual Granary raze pays both sides identically (bank %d, wasted %d)",
      bank, wasted))
  end
end

local fails, checked = 0, 0
for i = 1, NLOGS do
  local seed = 900000 + i * 13
  local log = makeLog(seed)
  local a = play(log, seed)
  local b = play(flip(log), seed)
  checked = checked + 1

  local bad = {}
  if a.tick ~= b.tick then bad[#bad + 1] = "tick " .. a.tick .. " vs " .. b.tick end
  if a.reason ~= b.reason then bad[#bad + 1] = "reason " .. a.reason .. " vs " .. b.reason end
  if a.tier ~= b.tier then bad[#bad + 1] = "tier " .. a.tier .. " vs " .. b.tier end
  local wantWinner = (a.winner == 0) and 0 or (3 - a.winner)
  if b.winner ~= wantWinner then
    bad[#bad + 1] = "winner " .. a.winner .. " should mirror to " .. wantWinner .. ", got " .. b.winner
  end
  for s = 1, 2 do
    for f = 1, #FIELDS do
      local k = FIELDS[f]
      if a.sides[s][k] ~= b.sides[3 - s][k] then
        bad[#bad + 1] = string.format("%s side %d: %d vs %d", k, s,
          a.sides[s][k], b.sides[3 - s][k])
      end
    end
  end
  if #bad > 0 then
    fails = fails + 1
    print(string.format("ASYMMETRY log %d (seed %d):", i, seed))
    for j = 1, math.min(#bad, 6) do print("   " .. bad[j]) end
    if fails > 4 then break end
  end
end

if fails > 0 or synthFails > 0 then
  if fails > 0 then
    print(string.format("FAILED: %d of %d matches are not side-symmetric", fails, checked))
  end
  if synthFails > 0 then
    print("FAILED: the synthetic same-tick spoils case is not side-symmetric")
  end
  os.exit(1)
end
print(string.format("PASS: %d matches replay to the exact mirror with the sides swapped, "
  .. "plus the synthetic same-tick spoils case", checked))
