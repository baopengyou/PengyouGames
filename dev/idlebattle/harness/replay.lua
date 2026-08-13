-- harness/replay.lua -- replay one command log and print its hash trace.
--
-- This is the tool a bug report is filed with. A.12 makes the ordered command
-- log the replay artifact for the whole match, so "seed + rulesHash + log" is a
-- complete description of a desync; this reruns it and prints the per-epoch
-- stateHash trace so the exact epoch where two machines parted company can be
-- read off two terminals side by side.
--
-- USAGE
--   lua harness/replay.lua <log> [options]
--     --epoch=N      hash cadence in ticks (default 60, A.12's snapshot epoch)
--     --ticks=N      tick budget (default the log's own)
--     --brief        print the first and last few epochs instead of all of them
--     --arrival      deliver each atom at its own arrive tick instead of up front
--     --shuffle=S    queue the atoms in a permutation drawn from seed S
--     --dump         print the full terminal state, field by field
--     --quiet        terminal line only, for scripting
--
-- Exit status is 0 on a completed replay, 1 on a bad log or a failed invariant,
-- so it is usable in a pipeline.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Hash = require("sim.Hash")
local logfmt = require("harness.logfmt")
local runner = require("harness.runner")
local gen = require("harness.gen")

local function die(msg)
  io.stderr:write("replay: " .. msg .. "\n")
  os.exit(1)
end

local opts = { brief = false, quiet = false, dump = false, arrival = false }
local path = nil
for i = 1, #arg do
  local a = arg[i]
  local k, v = a:match("^%-%-([%w]+)=(.+)$")
  if k then
    if k == "epoch" then opts.epoch = tonumber(v)
    elseif k == "ticks" then opts.ticks = tonumber(v)
    elseif k == "shuffle" then opts.shuffle = tonumber(v)
    else die("unknown option " .. a) end
  elseif a == "--brief" then opts.brief = true
  elseif a == "--quiet" then opts.quiet = true
  elseif a == "--dump" then opts.dump = true
  elseif a == "--arrival" then opts.arrival = true
  elseif a == "--help" or a == "-h" then
    print("usage: lua harness/replay.lua <log> [--epoch=N] [--ticks=N] [--brief]"
      .. " [--arrival] [--shuffle=S] [--dump] [--quiet]")
    os.exit(0)
  elseif a:sub(1, 1) == "-" then
    die("unknown option " .. a)
  else
    path = a
  end
end
if not path then die("no log file given (try --help)") end

local log, err = logfmt.load(path)
if not log then die(err) end

local order = nil
if opts.shuffle then
  order = gen.permutation(#log.cmds, opts.shuffle)
end

local trace = runner.run(log, {
  epoch = opts.epoch, ticks = opts.ticks, order = order,
  arrival = opts.arrival, keepSim = true,
})

local function hx(h) return string.format("%s (%s)", Hash.dec(h), Hash.base36(h, 5)) end

if not opts.quiet then
  print(string.format("log        %s", path))
  print(string.format("ruleset    %s  rulesHash %s (%s)",
    Rules.RULESET_VERSION, Hash.dec(Rules.rulesHash), Rules.rulesHash36))
  print(string.format("seed       %d   match ticks %d   epoch %d",
    log.seed, log.ticks, opts.epoch or Rules.C.SNAPSHOT_EPOCH))
  print(string.format("commands   %d in file, %d accepted, %d refused%s",
    #log.cmds, trace.accepted, trace.rejected,
    trace.firstReject and ("  (first: " .. trace.firstReject .. ")") or ""))
  print(string.format("arrival    %s%s",
    opts.arrival and "at each atom's arrive tick" or "all queued before tick 0",
    order and ", shuffled" or ""))
  print("")
  print("  epoch    tick   stateHash")
  local n = trace.n
  local function line(i)
    print(string.format("  %5d  %6d   %s", i, trace.ticks[i], hx(trace.hashes[i])))
  end
  if opts.brief and n > 12 then
    for i = 1, 5 do line(i) end
    print(string.format("  %5s  %6s   ... %d epochs elided ...", "", "", n - 10))
    for i = n - 4, n do line(i) end
  else
    for i = 1, n do line(i) end
  end
  print("")
end

local r = trace.result
print(string.format("terminal   tick %d  over=%s  winner=%d  reason=%s  tier=%d",
  trace.terminalTick, tostring(r.over), r.winner, r.reason, r.tier))
print(string.format("stateHash  %s", hx(trace.terminal)))
print(string.format("logDigest  %s", hx(trace.logDigest)))

if not opts.quiet then
  print("")
  print("  side   bank earned wasted  spent   keepHp  dealt slots pen  depl lost kill bld  exec fizz")
  for s = 1, 2 do
    local x = r.sides[s]
    print(string.format("  %4d %6d %6d %6d %6d %8d %6d %5d %3d %5d %4d %4d %3d %5d %4d",
      s, x.bank, x.earned, x.wasted, x.spent, x.keepHp, x.keepDamageDealt,
      x.slotsDestroyed, x.penetration, x.unitsDeployed, x.unitsLost, x.unitsKilled,
      x.bldLost, x.cmdsExecuted, x.cmdsFizzled))
  end
end

local ok, problems = runner.invariants(trace.sim)
if not ok then
  print("")
  print("INVARIANTS FAILED:")
  for i = 1, #problems do print("  " .. problems[i]) end
  os.exit(1)
end
if not opts.quiet then
  print("")
  print("invariants pass (books balance, caches derive, counters pair)")
end

if opts.dump then
  print("")
  print("terminal state:")
  local d = runner.dump(trace.sim)
  for i = 1, #d do print("  " .. d[i]) end
end

os.exit(0)
