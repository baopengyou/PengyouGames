-- tools/determinism.lua -- the M1 milestone test.
--
--   "the same rulesHash and the same command log produce a bit-identical
--    stateHash after 6,000 ticks, over 1,000 randomised logs"
--
-- For each randomised log it runs the sim THREE times:
--   A  straight through, hashing at every snapshot epoch (60 ticks)
--   B  identical, to prove a second run of the same process agrees
--   C  the same commands queued in a DIFFERENT ARRIVAL ORDER, which is what
--      actually happens over a lossy channel. A.4 makes intra-tick order a
--      hashed invariant -- sort by (side, seq) -- so C must agree with A at
--      every epoch. If it does not, the canonical ordering is broken and two
--      clients that received the same commands in different orders would
--      silently disagree about money.
--
-- Usage:  lua tools/determinism.lua [logs] [ticks]
--         defaults 1000 logs, 6000 ticks.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Sim = require("sim.Sim")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")

local NLOGS = tonumber(arg and arg[1]) or 1000
local NTICKS = tonumber(arg and arg[2]) or Rules.C.MATCH_TICKS
local EPOCH = Rules.C.SNAPSHOT_EPOCH

local UNIT_KINDS = { "S", "H", "B" }
local BLD_LETTERS = {}
for i = 1, #Rules.BUILDINGS do BLD_LETTERS[i] = Rules.BUILDINGS[i].letter end
local VERBS = { "i", "s", "l" }

-- Build one randomised command log. Deliberately includes illegal and
-- unaffordable orders: a fizzle is a defined outcome (A.4) and both clients must
-- fizzle identically, so the harness has to exercise that path.
--
-- TWO COHORTS, and the reason is coverage rather than realism. The original
-- generator made 60 percent of atoms unit deploys with count up to 12, so both
-- sides mass-deployed, a keep fell around tick 3100, and only 4 logs in 1000 ever
-- reached tick 6000. The milestone says 6,000 ticks; the second half of the match
-- clock -- bank-cap waste, the DEPTH_X2/X3 hold latches, the late ladder -- was
-- being exercised by a handful of logs.
--
--   * every third log is a LONG cohort: fewer atoms, a quarter of them units,
--     deploy counts of 1-2. Alone this lifts logs reaching 6000 from 4 to ~260.
--   * every log then gets same-side BURSTS on a shared exec tick, half of them
--     weighted into ticks 3000-5999. This is the load-bearing part: long sparse
--     logs almost never collide, and a same-tick same-side collision is the ONLY
--     thing that exercises A.4's canonical (side, seq) order -- the ordering that
--     under Ruling 1 decides which of two deploys gets the last of the money.
local function makeLog(seed, index)
  local r = Rand.new(seed)
  local log = {}
  local seq = { 0, 0 }
  local longGame = (index % 3) == 0
  local n = longGame and Rand.range(r, 20, 60) or Rand.range(r, 20, 160)
  local unitShare = longGame and 25 or 60
  local maxCount = longGame and 2 or 12

  local function emit(side, tick)
    seq[side] = seq[side] + 1
    local roll = Rand.range(r, 1, 100)
    local kind, target, count
    if roll <= unitShare then
      kind = UNIT_KINDS[Rand.range(r, 1, 3)]
      target = Rand.range(r, 1, 4)          -- 4 is illegal, and must fizzle
      count = Rand.range(r, 1, maxCount)    -- above 9, and must be capped
    elseif roll <= 95 then
      kind = BLD_LETTERS[Rand.range(r, 1, #BLD_LETTERS)]
      target = Rand.range(r, 1, 7)          -- 7 is illegal, and must fizzle
      count = 1
    else
      kind = VERBS[Rand.range(r, 1, 3)]     -- M3 verbs, no-ops in M1
      target = Rand.range(r, 1, 3)
      count = Rand.range(r, 1, 4)
    end
    log[#log + 1] = { side = side, seq = seq[side], tick = tick,
                      kind = kind, target = target, count = count }
  end

  for _ = 1, n do
    emit(Rand.range(r, 1, 2), Rand.range(r, Rules.C.ORDER_DELAY, NTICKS - 1))
  end

  -- Bursts: several atoms from ONE side all carrying ONE exec tick.
  for _ = 1, Rand.range(r, 3, 6) do
    local side = Rand.range(r, 1, 2)
    local tick
    if Rand.range(r, 1, 2) == 1 and NTICKS > 3000 then
      tick = Rand.range(r, 3000, NTICKS - 1)
    else
      tick = Rand.range(r, Rules.C.ORDER_DELAY, math.min(2999, NTICKS - 1))
    end
    for _ = 1, Rand.range(r, 2, 5) do emit(side, tick) end
  end
  return log
end

-- A different arrival order for the same set. Commands are shuffled with the
-- portable PRNG, then queued; queueCommand refuses anything already past, so the
-- shuffle is applied before any ticking.
local function shuffled(log, seed)
  local r = Rand.new(seed + 7777)
  local out = {}
  for i = 1, #log do out[i] = log[i] end
  for i = #out, 2, -1 do
    local j = Rand.range(r, 1, i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

local function runOne(log, seed, checkpoints)
  local sm = Sim.new(Rules, seed)
  local accepted = 0
  for i = 1, #log do
    if sm:queueCommand(log[i]) then accepted = accepted + 1 end
  end
  local hs, nh = checkpoints, 0
  for t = 1, NTICKS do
    sm:tick()
    if t % EPOCH == 0 or sm:isOver() then
      nh = nh + 1
      hs[nh] = sm:stateHash()
    end
    if sm:isOver() then break end
  end
  nh = nh + 1
  hs[nh] = sm:stateHash()
  hs.n = nh
  hs.log = sm:logDigest()
  hs.accepted = accepted
  return sm
end

local function sameCheckpoints(a, b)
  if a.n ~= b.n or a.log ~= b.log or a.accepted ~= b.accepted then return false, 0 end
  for i = 1, a.n do
    if a[i] ~= b[i] then return false, i end
  end
  return true, 0
end

print(string.format("rulesHash %s (%s)   logs %d   ticks %d",
  Hash.dec(Rules.rulesHash), Rules.rulesHash36, NLOGS, NTICKS))

local okRand = Rand.selftest()
if not okRand then print("FAIL Rand.selftest"); os.exit(1) end

-- Coverage floors. A gate whose depth can silently collapse to 4 logs of real
-- match length is not evidence, so the run REFUSES to certify unless it actually
-- reached the depth the milestone names. These numbers are floors with headroom,
-- not targets: a balance change that shortens matches must trip them and be
-- looked at, rather than quietly reducing what the milestone covers.
local FLOOR_FULL_LOGS = 100        -- logs that ran the whole MATCH_TICKS
local FLOOR_LATE_COLLISIONS = 200  -- executed same-side same-tick atoms at t >= 3000

-- Count atoms that share (side, exec tick) with another and that the match
-- actually reached. That is the population which exercises A.4's canonical order
-- late in the game.
local function lateCollisions(log, terminalTick)
  local seen, extra = {}, 0
  for i = 1, #log do
    local c = log[i]
    if c.tick >= 3000 and c.tick < terminalTick then
      local key = c.side * 100000 + c.tick
      if seen[key] then extra = extra + 1 else seen[key] = true end
    end
  end
  return extra
end

local ha, hb, hc = {}, {}, {}
local fails, keepWins, clockWins, draws = 0, 0, 0, 0
local tierCount = { 0, 0, 0, 0, 0 }
local lengths = {}
local fullLogs, lateColl = 0, 0

for i = 1, NLOGS do
  local seed = 100000 + i * 37
  local log = makeLog(seed, i)
  local sa = runOne(log, seed, ha)
  runOne(log, seed, hb)
  runOne(shuffled(log, seed), seed, hc)

  local ok1, at1 = sameCheckpoints(ha, hb)
  local ok2, at2 = sameCheckpoints(ha, hc)
  if not ok1 or not ok2 then
    fails = fails + 1
    print(string.format("DESYNC log %d (seed %d): replay=%s at %d, reordered=%s at %d",
      i, seed, tostring(ok1), at1, tostring(ok2), at2))
    if fails > 5 then break end
  end

  local r = sa:result()
  if r.reason == "keep" then keepWins = keepWins + 1
  elseif r.reason == "clock" then clockWins = clockWins + 1 end
  if r.winner == 0 then draws = draws + 1 end
  if r.tier >= 1 and r.tier <= 5 then tierCount[r.tier] = tierCount[r.tier] + 1 end
  lengths[#lengths + 1] = r.tick
  if r.tick >= NTICKS then fullLogs = fullLogs + 1 end
  lateColl = lateColl + lateCollisions(log, r.tick)

  if i % 100 == 0 then
    io.write(string.format("  %d logs, %d desyncs\n", i, fails))
    io.flush()
  end
end

table.sort(lengths)
local function pct(p)
  if #lengths == 0 then return 0 end
  local k = math.floor(#lengths * p / 100)
  if k < 1 then k = 1 end
  return lengths[k]
end

print(string.format("decided by keep %d, on the clock %d, draws %d",
  keepWins, clockWins, draws))
print(string.format("clock tiers T1 %d T2 %d T3 %d T4 %d draw %d",
  tierCount[1], tierCount[2], tierCount[3], tierCount[4], tierCount[5]))
print(string.format("match length ticks p10 %d median %d p90 %d",
  pct(10), pct(50), pct(90)))
print(string.format("depth coverage: %d logs ran the full %d ticks; "
  .. "%d executed same-side same-tick atoms at t >= 3000",
  fullLogs, NTICKS, lateColl))

local shortfall = 0
-- The floors are scaled to the run size, so a 100-log smoke test is not held to
-- the 1000-log milestone's coverage. Below 100 logs the floors are not
-- meaningful and are skipped outright.
if NLOGS >= 100 and NTICKS >= Rules.C.MATCH_TICKS then
  local wantFull = math.floor(FLOOR_FULL_LOGS * NLOGS / 1000)
  local wantColl = math.floor(FLOOR_LATE_COLLISIONS * NLOGS / 1000)
  if fullLogs < wantFull then
    print(string.format("COVERAGE FAIL: only %d logs reached tick %d, floor is %d. "
      .. "The milestone's tick depth is not being exercised.", fullLogs, NTICKS, wantFull))
    shortfall = shortfall + 1
  end
  if lateColl < wantColl then
    print(string.format("COVERAGE FAIL: only %d late same-side collisions, floor is %d. "
      .. "A.4's canonical intra-tick order is barely exercised after tick 3000.",
      lateColl, wantColl))
    shortfall = shortfall + 1
  end
end

if fails > 0 then
  print("FAILED: " .. fails .. " desyncs")
  os.exit(1)
end
if shortfall > 0 then
  print("FAILED: the run is self-consistent but does not cover the milestone's depth")
  os.exit(1)
end
print("PASS: " .. NLOGS .. " logs, bit-identical over replay and over reordered arrival")
