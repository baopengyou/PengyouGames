-- harness/fuzz.lua -- THE M1 MILESTONE.
--
--   "the same ruleset and the same command log produce a bit-identical stateHash
--    after 6,000 ticks, across 1,000 randomised command logs"
--
-- Each log is generated LEGAL (see harness/gen.lua: every atom will actually
-- execute) and then run FOUR times:
--
--   A  baseline. Atoms queued before tick 0 in canonical order.
--   B  a second, independent sim instance over the identical input. Proves the
--      sim carries no state between instances -- no module-level accumulator, no
--      shared scratch table, nothing that a second match on one client would
--      inherit from the first.
--   C  the identical atoms queued in a SHUFFLED order, still before tick 0.
--      A.4 elevates canonical intra-tick order -- (side, seq) -- to a hashed
--      invariant precisely because under Ruling 1 it decides MONEY: two deploys
--      on one tick where only one is affordable. If C ever disagrees with A, two
--      clients that received the same commands in a different order would
--      silently disagree about a bank balance.
--   D  the identical atoms DELIVERED MID-RUN, each at its own arrive tick and
--      shuffled within a tick. This is what the wire really does (A.12: batches,
--      resends, gaps, a resend landing on the exec tick itself). Same exec ticks,
--      different arrival history, and the result must still be bit-identical.
--
-- Every run is compared on the per-epoch hash trace (60 ticks, A.12's snapshot
-- cadence), the terminal hash, the logDigest and the accept tally -- not just the
-- terminal hash, because a divergence that heals before tick 6000 would already
-- have voided a real match on the heartbeat.
--
-- Two more assertions ride along, and they are the ones that make the hash
-- comparison mean something:
--   * cmdsFizzled == 0 over every match. The generator's model of cost, supply
--     cap, slot cap and slot class has to agree with the sim's, order for order.
--   * runner.invariants on the terminal state: the books balance, every cached
--     value the state hash does NOT cover is re-derived from the state it does,
--     and every paired counter pairs.
--
-- The run ends by folding every terminal hash into one SUITE HASH. Part E's
-- milestone is bit-identical state on two machines with different CPUs; that
-- reduces to running this one command on the second machine and comparing one
-- printed number.
--
-- Three more checks ride along on top of those four:
--   * every log is replayed with both sides' commands swapped, and the whole
--     match must mirror (A.2). This is the one property a hash comparison can
--     never catch: a sim that quietly favours the host is deterministic.
--   * the first --fine=N logs are also run as TWO SIMS ADVANCED ALTERNATELY in
--     one process, hashed at EVERY tick rather than every 60. Interleaving is
--     what would expose state shared between instances; per-tick hashing catches
--     a divergence that heals inside an epoch.
--   * the written log must reproduce the generator's own run, in which every
--     atom was queued mid-run at its issue tick -- a fifth arrival pattern.
--
-- USAGE
--   lua harness/fuzz.lua [N] [--seed=S] [--ticks=T] [--epoch=E]
--                        [--chaos=N] [--fine=N] [--mirror=0] [--progress=K]
--                        [--maxfail=K] [--style=guard/brawl]
--                        [--emit=SEED --out=PATH]
--
--   --style forces both sides' policy (guard, turtle or brawl) instead of the
--   randomised mix; it is a coverage tool, not part of the milestone run.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")
local logfmt = require("harness.logfmt")
local runner = require("harness.runner")
local gen = require("harness.gen")

local NLOGS = 1000
local BASE_SEED = 700001
local TICKS = Rules.C.MATCH_TICKS
local EPOCH = Rules.C.SNAPSHOT_EPOCH
local CHAOS = 100
local PROGRESS = 100
local MAXFAIL = 3
local FINE = 25          -- logs also checked at EVERY tick, two sims interleaved
local STYLE_A, STYLE_B = nil, nil   -- force both sides' policy, for coverage work
local MIRROR = true      -- also run every log with both sides' commands swapped
local EMIT, OUT = nil, nil

for i = 1, #arg do
  local a = arg[i]
  local k, v = a:match("^%-%-([%w]+)=(.+)$")
  if k then
    if k == "seed" then BASE_SEED = tonumber(v)
    elseif k == "ticks" then TICKS = tonumber(v)
    elseif k == "epoch" then EPOCH = tonumber(v)
    elseif k == "chaos" then CHAOS = tonumber(v)
    elseif k == "fine" then FINE = tonumber(v)
    elseif k == "mirror" then MIRROR = (v ~= "0")
    elseif k == "style" then
      STYLE_A = v:match("^([%a]+)")
      STYLE_B = v:match("/([%a]+)$") or STYLE_A
    elseif k == "progress" then PROGRESS = tonumber(v)
    elseif k == "maxfail" then MAXFAIL = tonumber(v)
    elseif k == "emit" then EMIT = tonumber(v)
    elseif k == "out" then OUT = v
    else io.stderr:write("fuzz: unknown option " .. a .. "\n"); os.exit(1) end
  elseif tonumber(a) then
    NLOGS = tonumber(a)
  else
    io.stderr:write("fuzz: unknown argument " .. a .. "\n"); os.exit(1)
  end
end

local LOGDIR = here .. "/logs"

-- Emit mode: write one generated log to disk and stop. This is how a failing
-- seed becomes a file that replay.lua can chew on.
if EMIT then
  local log = gen.make(EMIT, { ticks = TICKS })
  local path = OUT or (LOGDIR .. "/gen-" .. EMIT .. ".iblog")
  local ok, err = logfmt.save(path, log, "generated by harness/fuzz.lua --emit=" .. EMIT)
  if not ok then io.stderr:write("fuzz: " .. tostring(err) .. "\n"); os.exit(1) end
  print(string.format("wrote %s (%d commands)", path, #log.cmds))
  os.exit(0)
end

local function hx(h) return string.format("%s (%s)", Hash.dec(h), Hash.base36(h, 5)) end

-- ---------------------------------------------------------------------------
-- failure reporting: everything needed to debug, on the terminal and on disk
-- ---------------------------------------------------------------------------

local failures = 0

local function report(idx, seed, log, mode, where, detail, optsA, optsB, ta, tb)
  failures = failures + 1
  print("")
  print("================ DESYNC ================")
  print(string.format("log #%d  seed %d  mode %s", idx, seed, mode))
  print(string.format("  %s", detail))
  if where > 0 and ta and tb then
    local lo = where - 2
    if lo < 1 then lo = 1 end
    print("  epoch trace around the divergence:")
    for i = lo, where do
      print(string.format("    epoch %3d  tick %5d   A %s   %s %s",
        i, ta.ticks[i], Hash.dec(ta.hashes[i]), mode, Hash.dec(tb.hashes[i])))
    end
  end
  local path = LOGDIR .. "/fail-" .. seed .. ".iblog"
  local ok = logfmt.save(path, log, string.format("DESYNC seed %d mode %s: %s", seed, mode, detail))
  if ok then
    print(string.format("  log written to %s", path))
    print(string.format("  reproduce: lua harness/replay.lua %s", path))
  end
  -- Narrow the epoch down to the exact tick, then diff the two states.
  local t, simA, simB, prevA, prevB, why = runner.bisect(log, optsA, optsB)
  print(string.format("  bisect: %s at tick %s", why, tostring(t)))
  if t >= 0 then
    local da, db = runner.dump(simA), runner.dump(simB)
    local lines = runner.dumpDiff(da, db)
    if #lines == 0 and prevA then
      print("  states are field-identical but hash differently -- suspect an")
      print("  unhashed field or a hash walker that reads something not dumped.")
    end
    for i = 1, #lines do print(lines[i]) end
  end
  print("========================================")
  print("")
end

-- ---------------------------------------------------------------------------
-- one log
-- ---------------------------------------------------------------------------

local stat = {
  logs = 0, cmds = 0, accepted = 0, ticks = 0, simRuns = 0,
  full = 0, keep = 0, clock = 0, draws = 0, running = 0,
  deployed = 0, fizzled = 0, fine = 0, mirrored = 0,
  suite = Hash.new(), firstSeed = 0, firstHash = 0, firstDigest = 0,
  tiers = { 0, 0, 0, 0, 0 },
  lengths = {},
  invFails = 0,
}

local function doOne(idx, seed, log, label)
  local optsA = { epoch = EPOCH, keepSim = true }
  local optsB = { epoch = EPOCH }
  local perm1 = gen.permutation(#log.cmds, seed + 11)
  local perm2 = gen.permutation(#log.cmds, seed + 22)
  local optsC = { epoch = EPOCH, order = perm1 }
  local optsD = { epoch = EPOCH, order = perm2, arrival = true }

  local A = runner.run(log, optsA)
  local B = runner.run(log, optsB)
  local Cc = runner.run(log, optsC)
  local D = runner.run(log, optsD)
  stat.simRuns = stat.simRuns + 4
  stat.ticks = stat.ticks + A.terminalTick + B.terminalTick + Cc.terminalTick + D.terminalTick

  local ok, where, detail = runner.compare(A, B)
  if not ok then report(idx, seed, log, "replay", where, detail, optsA, optsB, A, B) end
  local ok2, where2, detail2 = runner.compare(A, Cc)
  if not ok2 then report(idx, seed, log, "reordered", where2, detail2, optsA, optsC, A, Cc) end
  local ok3, where3, detail3 = runner.compare(A, D)
  if not ok3 then report(idx, seed, log, "arrival", where3, detail3, optsA, optsD, A, D) end

  -- generator legality: every atom must have executed
  local fz = A.result.sides[1].cmdsFizzled + A.result.sides[2].cmdsFizzled
  stat.fizzled = stat.fizzled + fz
  if label == "legal" and fz > 0 then
    failures = failures + 1
    print(string.format("LEGALITY log #%d seed %d: %d commands fizzled in a log that "
      .. "was generated to be legal -- the generator's model and the sim's rules disagree",
      idx, seed, fz))
  end

  -- A.2: the same match with every atom's side flipped must mirror exactly.
  if MIRROR then
    local mrun = runner.run(runner.mirrorLog(log), { epoch = EPOCH })
    stat.simRuns = stat.simRuns + 1
    stat.ticks = stat.ticks + mrun.terminalTick
    stat.mirrored = stat.mirrored + 1
    local mok, mdet = runner.mirrorCompare(A, mrun)
    if not mok then
      failures = failures + 1
      print(string.format("SIDE ASYMMETRY log #%d seed %d: %s", idx, seed, mdet))
    end
  end

  -- The written log must reproduce the match the generator itself watched, in
  -- which every atom was queued mid-run at its issue tick.
  if log.genHash and A.terminal ~= log.genHash then
    failures = failures + 1
    print(string.format("GENERATOR log #%d seed %d: replaying the written log gives %s at tick %d,"
      .. " the generator's own run ended %s at tick %d",
      idx, seed, Hash.dec(A.terminal), A.terminalTick, Hash.dec(log.genHash), log.genTick))
  end

  -- The fine pass: two sim instances advanced ALTERNATELY in one process, hashed
  -- at every tick rather than every 60. Interleaving is what would expose state
  -- shared between instances (a file-local scratch table, a module-level
  -- counter) -- running one match to completion and then the next never can, and
  -- per-tick hashing catches a divergence that heals inside an epoch.
  if idx <= FINE then
    local t, simA, simB = runner.bisect(log, optsA, optsD)
    stat.fine = stat.fine + 1
    stat.simRuns = stat.simRuns + 2
    stat.ticks = stat.ticks + simA.clock + simB.clock
    if t >= 0 then
      failures = failures + 1
      print(string.format("INTERLEAVED log #%d seed %d: two sims advanced alternately"
        .. " diverged at tick %d", idx, seed, t))
      local lines = runner.dumpDiff(runner.dump(simA), runner.dump(simB))
      for i = 1, #lines do print(lines[i]) end
    end
  end

  local iok, problems = runner.invariants(A.sim)
  if not iok then
    failures = failures + 1
    stat.invFails = stat.invFails + 1
    print(string.format("INVARIANT log #%d seed %d:", idx, seed))
    for i = 1, #problems do print("  " .. problems[i]) end
  end

  -- The SUITE HASH: every terminal state hash of the run, in order, folded into
  -- one 31-bit number. Part E's milestone is bit-identical state on two machines
  -- with different CPUs, and this reduces the entire 1,000-log run to a single
  -- value to compare -- run the same command on the second machine and this line
  -- must match, character for character.
  stat.suite = Hash.int(stat.suite, A.terminal)
  stat.suite = Hash.int(stat.suite, A.terminalTick)
  stat.suite = Hash.int(stat.suite, A.logDigest)
  if stat.firstSeed == 0 then
    stat.firstSeed, stat.firstHash, stat.firstDigest = seed, A.terminal, A.logDigest
  end

  -- statistics
  local r = A.result
  stat.logs = stat.logs + 1
  stat.cmds = stat.cmds + #log.cmds
  stat.accepted = stat.accepted + A.accepted
  stat.lengths[#stat.lengths + 1] = A.terminalTick
  if A.terminalTick >= TICKS then stat.full = stat.full + 1 end
  if r.reason == "keep" then
    stat.keep = stat.keep + 1
  elseif r.reason == "clock" then
    stat.clock = stat.clock + 1
    if r.tier >= 1 and r.tier <= 5 then stat.tiers[r.tier] = stat.tiers[r.tier] + 1 end
  else
    stat.running = stat.running + 1
  end
  if r.winner == 0 and r.over then stat.draws = stat.draws + 1 end
  for s = 1, 2 do
    stat.deployed = stat.deployed + r.sides[s].unitsDeployed
  end
  return failures
end

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

print(string.format("ruleset %s   rulesHash %s (%s)",
  Rules.RULESET_VERSION, Hash.dec(Rules.rulesHash), Rules.rulesHash36))
print(string.format("logs %d   ticks %d   epoch %d   base seed %d",
  NLOGS, TICKS, EPOCH, BASE_SEED))
print(string.format("each log: 4 runs (replay, reordered arrival, mid-run arrival) = %d matches;"
  .. " the first %d also run interleaved and hashed every tick", NLOGS * 4, FINE))

if not Rand.selftest() then
  print("FAIL: sim/Rand.lua self-test did not pass; nothing below is meaningful")
  os.exit(1)
end

for i = 1, NLOGS do
  local seed = BASE_SEED + i * 37
  local log = gen.make(seed, { ticks = TICKS, styleA = STYLE_A, styleB = STYLE_B })
  doOne(i, seed, log, "legal")
  if failures >= MAXFAIL then
    print(string.format("stopping after %d failures at log #%d", failures, i))
    break
  end
  if PROGRESS > 0 and i % PROGRESS == 0 then
    io.write(string.format("  %d/%d logs, %d desyncs, %d ticks simulated\n",
      i, NLOGS, failures, stat.ticks))
    io.flush()
  end
end

-- The chaos pass: illegal, unaffordable and M3-verb atoms. Every one of these is
-- a fizzle, which is a weaker test than the legal pass -- but the fizzle path is
-- sim code too, and two clients must fizzle identically.
local chaosLogs, chaosFizzles = 0, 0
if CHAOS > 0 and failures < MAXFAIL then
  print(string.format("chaos pass: %d illegal/unaffordable logs", CHAOS))
  for i = 1, CHAOS do
    local seed = BASE_SEED + 500000 + i * 37
    local log = gen.makeChaos(seed, { ticks = TICKS })
    local before = stat.fizzled
    doOne(i, seed, log, "chaos")
    chaosLogs = chaosLogs + 1
    chaosFizzles = chaosFizzles + (stat.fizzled - before)
    if failures >= MAXFAIL then break end
  end
end

local L = stat.lengths
table.sort(L)
local function pct(p)
  if #L == 0 then return 0 end
  local k = math.floor(#L * p / 100)
  if k < 1 then k = 1 end
  if k > #L then k = #L end
  return L[k]
end

print("")
print("---------------- SUMMARY ----------------")
print(string.format("logs run              %d  (%d legal, %d chaos)",
  stat.logs, stat.logs - chaosLogs, chaosLogs))
print(string.format("matches simulated     %d", stat.simRuns))
print(string.format("interleaved per-tick  %d logs (two sims alternating, hashed every tick)", stat.fine))
print(string.format("side-mirrored (A.2)   %d logs replayed with both sides' commands swapped", stat.mirrored))
print(string.format("ticks simulated       %d", stat.ticks))
print(string.format("commands generated    %d  (%d accepted by queueCommand)", stat.cmds, stat.accepted))
print(string.format("commands fizzled      %d  (%d in the legal pass -- must be 0)",
  stat.fizzled, stat.fizzled - chaosFizzles))
print(string.format("units deployed        %d", stat.deployed))
print(string.format("terminal: keep %d, clock %d, still running %d, draws %d",
  stat.keep, stat.clock, stat.running, stat.draws))
print(string.format("clock tiers           T1 %d  T2 %d  T3 %d  T4 %d  draw %d",
  stat.tiers[1], stat.tiers[2], stat.tiers[3], stat.tiers[4], stat.tiers[5]))
print(string.format("match length ticks    p10 %d  median %d  p90 %d  ran the full %d: %d",
  pct(10), pct(50), pct(90), TICKS, stat.full))
print(string.format("invariant failures    %d", stat.invFails))
print(string.format("first log             seed %d  stateHash %s  logDigest %s",
  stat.firstSeed, hx(stat.firstHash), hx(stat.firstDigest)))
print(string.format("SUITE HASH            %s   <- compare this between machines", hx(stat.suite)))

-- COMMITTED SUITE HASH. The line above invited a cross-machine comparison but
-- asserted nothing, so it could only ever be checked by a human copying digits
-- between two terminals. Recorded on an arm64 macOS build of Lua 5.5 at the
-- milestone parameters; keyed to (rulesHash, NLOGS, TICKS, BASE_SEED, EPOCH)
-- because every one of those changes the number legitimately. Any other move is
-- an arithmetic difference between this machine and the one that recorded it --
-- which is precisely the failure the milestone exists to detect, and which no
-- amount of intra-process comparison can see.
local GOLDEN_SUITE_RULESHASH = 333968378
local GOLDEN_SUITE_LOGS = 1000
local GOLDEN_SUITE_SEED = 700001
local GOLDEN_SUITE_CHAOS = 100     -- the chaos pass folds into stat.suite too
local GOLDEN_SUITE = 2005649413     -- 640zp, wire letters per the A.11.2 ruling
local atMilestone = (NLOGS == GOLDEN_SUITE_LOGS and TICKS == Rules.C.MATCH_TICKS
  and BASE_SEED == GOLDEN_SUITE_SEED and EPOCH == Rules.C.SNAPSHOT_EPOCH
  and CHAOS == GOLDEN_SUITE_CHAOS and MIRROR == true and FINE == 25)
if atMilestone and Rules.rulesHash == GOLDEN_SUITE_RULESHASH then
  if stat.suite ~= GOLDEN_SUITE then
    print(string.format("SUITE HASH MISMATCH   got %s want %s -- this machine does not agree"
      .. " with the recorded run", hx(stat.suite), hx(GOLDEN_SUITE)))
    failures = failures + 1
  else
    print("SUITE HASH            matches the committed golden")
  end
elseif atMilestone then
  print(string.format("SUITE HASH            NOT CHECKED: rulesHash is %s, golden was recorded"
    .. " under %s -- regenerate GOLDEN_SUITE", hx(Rules.rulesHash), hx(GOLDEN_SUITE_RULESHASH)))
else
  print("SUITE HASH            NOT CHECKED: not the milestone parameters")
end
print(string.format("HASH MISMATCHES       %d", failures))
print("-----------------------------------------")

if failures > 0 then
  print("M1 FUZZ: FAILED")
  os.exit(1)
end
print("M1 FUZZ: PASS -- every log bit-identical across replay, reordered queueing"
  .. " and mid-run arrival, at every epoch and at the terminal state")
os.exit(0)
