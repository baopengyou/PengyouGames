-- harness/m4run.lua -- THE M4 MILESTONE, and the implementation tools/m4.sh
-- fronts.
--
--   "Two instances of the sim in one addon session, fed the same log through
--    a fake transport that can drop, delay and reorder messages on command.
--    MILESTONE: state hashes match at every epoch for 6,000 ticks with 10%
--    packet loss and up to 3 s of jitter. Rollback repairs every late
--    command. A forced deep desync is repaired by the Q full-log replay path
--    from tick 0 -- which requires both loadouts."
--
-- HOW A NET MATCH IS DRIVEN. A generated legal log (harness/gen.lua -- the
-- same generator the M1 milestone trusts) is split into each side's ORDERS:
-- an atom with exec tick E is issued by its own endpoint at sim tick
-- E - ORDER_DELAY, the fastest legal client (the same reading sweep/driver.lua
-- uses). The endpoint queues it locally, ships it through net/Transport.lua's
-- seeded drop/delay/reorder verdicts, and the peer repairs whatever that does
-- to it. An endpoint whose sim is (provisionally) finished stops issuing --
-- a real hand cannot click on a match it believes is over -- so the ISSUED
-- SET, not the source log, is the ground truth for that run.
--
-- WHAT EVERY RUN ASSERTS, whatever the scenario:
--   * ep1's per-epoch hash trace == ep2's == a REFERENCE run of the issued
--     set through harness/runner.lua with NO netcode, at every epoch, plus
--     terminal stateHash, terminal tick and logDigest, all three ways. The
--     reference is what proves the netcode DELIVERED the game unchanged
--     rather than merely agreeing with itself.
--   * runner.invariants on both terminal sims -- unhashed derived state is
--     re-derived, which is what catches a snapshot/restore that missed a
--     cache no hash can see.
--   * both endpoints performed settled hash comparisons (the divergence
--     detector was live, not vacuously green).
--
-- Every number here is deterministic: seeds are fixed schedules, the
-- transport draws from sim/Rand.lua, and the whole run folds into one
-- M4 SUITE HASH per step -- compare it across interpreters and machines
-- exactly like the M1 fuzz's.
--
-- USAGE
--   lua harness/m4run.lua codec
--   lua harness/m4run.lua milestone [N]   default 100
--   lua harness/m4run.lua rollback  [N]   default 40
--   lua harness/m4run.lua deep      [N]   default 12
--   lua harness/m4run.lua stress    [N]   default 25
--   lua harness/m4run.lua all       (codec + the four, milestone sizes)

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")
local runner = require("harness.runner")
local gen = require("harness.gen")
local Wire = require("net.Wire")
local Transport = require("net.Transport")
local Net = require("net.Net")

local C = Rules.C
local floor = math.floor

local function hx(h) return string.format("%s (%s)", Hash.dec(h), Hash.base36(h, 5)) end

local failures = 0
local function fail(fmt, ...)
  failures = failures + 1
  print(string.format("FAIL: " .. fmt, ...))
end

-- ===========================================================================
-- one net match
-- ===========================================================================

-- Split a generated log into per-side order books, issue-tick ascending.
-- Per side, gen assigns seqs in issue order, so the per-side subsequence of
-- log.cmds is already ascending in issue tick; no sort is needed.
local function orderBooks(log)
  local books = { {}, {} }
  for i = 1, #log.cmds do
    local c = log.cmds[i]
    local b = books[c.side]
    b[#b + 1] = { issue = c.tick - C.ORDER_DELAY, kind = c.kind,
                  target = c.target, count = c.count }
  end
  return books
end

-- Run one net match.
--   genSeed   the drive log's seed (and the sims')
--   topts     transport options (nil = the milestone scenario)
--   opts:
--     styleA/styleB    force the generator's policies
--     loadoutA/B       force loadouts (deep step: the rebuild needs them)
--     corruptAt        harness tick from which ep2's sim state is mutated
--                      OUTSIDE the shim (the forced-desync test hook). The
--                      mutation RECURS every tick until the first Q is sent:
--                      a one-off mutation turned out to be HEALED as a side
--                      effect of the next routine rollback (restore from a
--                      pre-corruption snapshot erases it), so what a real
--                      divergence needs modelling as is a code path that
--                      keeps disagreeing, not a bit that flipped once
--     corruptWipe      also wipe ep2's held peer history, so the Q replay is
--                      load-bearing rather than redundant
-- Returns a result record; rec.void = true means the scenario precondition
-- failed (e.g. the match ended before corruptAt) and the caller must re-seed.
local function netMatch(genSeed, topts, opts)
  opts = opts or {}
  local log = gen.make(genSeed, { ticks = C.MATCH_TICKS,
    styleA = opts.styleA, styleB = opts.styleB,
    loadoutA = opts.loadoutA, loadoutB = opts.loadoutB })
  local books = orderBooks(log)
  local cursor = { 1, 1 }

  local tr = Transport.new(genSeed + 13, topts)
  local eps = {}
  eps[1] = Net.new{ rules = Rules, side = 1, seed = log.seed,
    loadout = log.loadout[1], send = function(s) tr:send(1, s) end }
  eps[2] = Net.new{ rules = Rules, side = 2, seed = log.seed,
    loadout = log.loadout[2], send = function(s) tr:send(2, s) end }

  local issued = {}          -- the ground-truth atom set, collected at issue
  local corrupted = false
  local firstQtick = -1
  local wipeSpan = -1

  local cap = C.MATCH_TICKS + 3000
  local settledAt = -1
  for now = 0, cap do
    for side = 1, 2 do
      local msgs = tr:deliver(side, now)
      for i = 1, #msgs do eps[side]:onWire(msgs[i], now) end
    end

    -- the forced-desync test hook: OUTSIDE the shim, direct state mutation,
    -- recurring until detection (see the netMatch header for why recurring)
    if opts.corruptAt and now >= opts.corruptAt and firstQtick < 0 then
      local sim = eps[2].sim
      if now == opts.corruptAt then
        if not sim or sim.over then
          return { void = true, why = "match not live at corruptAt" }
        end
        corrupted = true
        if opts.corruptWipe then
          -- state AND history damage: the rebuild can only come off the wire.
          -- The span wiped is recorded: a hole inside N's spanning reach is
          -- legally healed by the LOWER rung of the ladder, so the caller
          -- re-seeds until the wipe is genuinely too wide for anything but Q.
          wipeSpan = eps[2].peerLastSeq
          eps[2].inHave = {}
          eps[2].inContig = 0
          eps[2].peerLastSeq = 0
        end
      end
      if sim then
        local sd = sim.sides[1]
        sd.bank = sd.bank + 47
        sd.earned = sd.earned + 47   -- books still balance: a PURE hash divergence
      end
    end

    for side = 1, 2 do
      local ep = eps[side]
      ep:step(now)
      if ep.sim then
        local book, cur = books[side], cursor[side]
        while cur <= #book and book[cur].issue <= ep.sim.clock do
          local a = book[cur]
          if a.issue == ep.sim.clock and not ep.sim.over then
            if ep:issue(a.kind, a.target, a.count) then
              issued[#issued + 1] = { tick = a.issue + C.ORDER_DELAY, side = side,
                seq = ep.outSeq, kind = a.kind, target = a.target, count = a.count,
                arrive = 0 }
            elseif a.issue + C.ORDER_DELAY < C.MATCH_TICKS then
              -- review finding 1: the reference is built FROM the issued set, so
              -- a shim that quietly eats orders would drag the reference down
              -- with it and stay green. A refusal while the sim is live and the
              -- exec tick is in-window is therefore a gate failure, not a skip.
              error(("m4run: shim refused a live in-window issue (side %d tick %d %s)")
                :format(side, a.issue, tostring(a.kind)))
            end
          end
          -- issue ticks the sim has already passed (a fast-forward after an
          -- un-finishing rollback) or sat out (provisionally over) are
          -- forfeit, exactly as a hand that could not click forfeits them
          cur = cur + 1
        end
        cursor[side] = cur
      end
      if firstQtick < 0 and (eps[1].st.qSent + eps[2].st.qSent) > 0 then
        firstQtick = now
      end
    end

    if eps[1].sim and eps[2].sim and eps[1].sim.over and eps[2].sim.over
      and tr:idle() and not eps[1].recovering and not eps[2].recovering
      and eps[1]:settled(eps[2]) and eps[2]:settled(eps[1]) then
      settledAt = now
      break
    end
  end

  -- the reference: the issued set, queued upfront, no netcode at all
  local refLog = { version = 1, seed = log.seed, ticks = C.MATCH_TICKS,
    loadout = log.loadout, cmds = issued, name = "m4ref:" .. genSeed }
  local ref = runner.run(refLog, { epoch = C.SNAPSHOT_EPOCH, keepSim = true })

  return {
    log = log, eps = eps, tr = tr, ref = ref,
    issued = #issued, settledAt = settledAt,
    corrupted = corrupted, firstQtick = firstQtick, wipeSpan = wipeSpan,
  }
end

-- Compare a finished net match three ways and run the invariants. Every
-- failure is printed with the seed that reproduces it. `wantQ` marks the
-- scenarios where escalation is expected/allowed; `requireCompares` demands
-- per-run settled comparisons (the milestone; under heavy loss or recovery
-- the settle window can legitimately never align inside one short match, so
-- the other steps assert compare-liveness in aggregate instead).
local function checkRun(rec, seed, wantQ, requireCompares)
  local ok = true
  local function bad(fmt, ...)
    ok = false
    fail("seed %d: " .. fmt, seed, ...)
  end
  if rec.settledAt < 0 then
    bad("did not settle inside the drain window")
    return false
  end
  local e1, e2, ref = rec.eps[1], rec.eps[2], rec.ref

  local t1, t2 = e1:terminalHash(), e2:terminalHash()
  if t1 ~= t2 then bad("terminal stateHash %s vs %s", Hash.dec(t1), Hash.dec(t2)) end
  if t1 ~= ref.terminal then
    bad("terminal %s but the no-netcode reference says %s -- the netcode changed the game",
      Hash.dec(t1), Hash.dec(ref.terminal))
  end
  if e1.sim.clock ~= ref.terminalTick or e2.sim.clock ~= ref.terminalTick then
    bad("terminal ticks %d/%d vs reference %d", e1.sim.clock, e2.sim.clock, ref.terminalTick)
  end
  local d1, d2 = e1:terminalDigest(), e2:terminalDigest()
  if d1 ~= d2 or d1 ~= ref.logDigest then
    bad("logDigest %s / %s vs reference %s", Hash.dec(d1), Hash.dec(d2), Hash.dec(ref.logDigest))
  end

  -- every epoch, all three ways
  if e1.epochMax ~= ref.n or e2.epochMax ~= ref.n then
    bad("epoch counts %d/%d vs reference %d", e1.epochMax, e2.epochMax, ref.n)
  else
    for e = 1, ref.n do
      local h1, h2, hr = e1.epochHash[e], e2.epochHash[e], ref.hashes[e]
      if h1 ~= hr or h2 ~= hr then
        bad("epoch %d (tick %d): ep1 %s ep2 %s reference %s", e, e * C.SNAPSHOT_EPOCH,
          Hash.dec(h1 or 0), Hash.dec(h2 or 0), Hash.dec(hr))
        break
      end
    end
  end

  for i = 1, 2 do
    local iok, problems = runner.invariants(rec.eps[i].sim)
    if not iok then
      bad("ep%d terminal invariants:", i)
      for k = 1, #problems do print("    " .. problems[k]) end
    end
  end

  for i = 1, 2 do
    local st = rec.eps[i].st
    if st.malformed > 0 then bad("ep%d saw %d malformed messages", i, st.malformed) end
    if st.refusedAtoms > 0 then bad("ep%d had %d atoms refused by the sim", i, st.refusedAtoms) end
    if st.settledCompares == 0 and requireCompares then
      bad("ep%d made no settled hash comparison -- detection was never live", i)
    end
    if st.late ~= st.rollbacks + st.lateBeyondDepth then
      bad("ep%d late %d but rollbacks %d + beyond-depth %d -- a late command went unrepaired",
        i, st.late, st.rollbacks, st.lateBeyondDepth)
    end
    if not wantQ then
      if st.mismatches > 0 then bad("ep%d detected %d hash mismatches in a clean scenario", i, st.mismatches) end
      if st.qSent > 0 or st.deepRecoveries > 0 then
        bad("ep%d escalated to Q (%d sent, %d rebuilds) in a scenario that must stay bounded",
          i, st.qSent, st.deepRecoveries)
      end
      if st.lateBeyondDepth > 0 then
        bad("ep%d saw %d commands beyond snapshot depth in a bounded scenario", i, st.lateBeyondDepth)
      end
    end
  end
  return ok
end

-- Fold one run into a step's suite accumulator. Counts are folded as well as
-- hashes: an interpreter that repaired one more command than the other must
-- not print the same suite hash.
local function foldRun(acc, seed, rec)
  acc = Hash.int(acc, seed)
  acc = Hash.int(acc, rec.eps[1]:terminalHash())
  acc = Hash.int(acc, rec.eps[1].sim.clock)
  acc = Hash.int(acc, rec.eps[1]:terminalDigest())
  acc = Hash.int(acc, rec.settledAt)
  for i = 1, 2 do
    local st = rec.eps[i].st
    acc = Hash.int(acc, st.late)
    acc = Hash.int(acc, st.rollbacks)
    acc = Hash.int(acc, st.dupAtoms)
    acc = Hash.int(acc, st.nSent)
    acc = Hash.int(acc, st.backstopResends)
    acc = Hash.int(acc, st.qSent)
    acc = Hash.int(acc, st.deepRecoveries)
    acc = Hash.int(acc, st.sent)
  end
  acc = Hash.int(acc, rec.tr.stat.dropped)
  acc = Hash.int(acc, rec.tr.stat.inverted)
  acc = Hash.int(acc, rec.tr.stat.bytesMax)
  return acc
end

-- Aggregate counters across a step, for the summary table.
local function tally(agg, rec)
  for i = 1, 2 do
    local st = rec.eps[i].st
    agg.late = agg.late + st.late
    agg.rollbacks = agg.rollbacks + st.rollbacks
    agg.depthMax = (st.rollbackDepthMax > agg.depthMax) and st.rollbackDepthMax or agg.depthMax
    agg.dups = agg.dups + st.dupAtoms
    agg.nSent = agg.nSent + st.nSent
    agg.nAnswered = agg.nAnswered + st.nAnswered
    agg.backstop = agg.backstop + st.backstopResends
    agg.mismatches = agg.mismatches + st.mismatches
    agg.qSent = agg.qSent + st.qSent
    agg.qAnswered = agg.qAnswered + st.qAnswered
    agg.deep = agg.deep + st.deepRecoveries
    agg.compares = agg.compares + st.settledCompares
    agg.msgs = agg.msgs + st.sent
  end
  local ts = rec.tr.stat
  agg.dropped = agg.dropped + ts.dropped
  agg.inverted = agg.inverted + ts.inverted
  agg.bytesMax = (ts.bytesMax > agg.bytesMax) and ts.bytesMax or agg.bytesMax
  agg.issued = agg.issued + rec.issued
  if rec.ref.terminalTick >= C.MATCH_TICKS then agg.full = agg.full + 1 end
  agg.epochs = agg.epochs + rec.ref.n
end

local function newTally()
  return { late = 0, rollbacks = 0, depthMax = 0, dups = 0, nSent = 0,
    nAnswered = 0, backstop = 0, mismatches = 0, qSent = 0, qAnswered = 0,
    deep = 0, compares = 0, msgs = 0, dropped = 0, inverted = 0, bytesMax = 0,
    issued = 0, full = 0, epochs = 0 }
end

local function printTally(a, runs)
  print(string.format("  runs tallied %d   atoms issued %d   epochs compared x3 %d   full-length %d",
    runs, a.issued, a.epochs, a.full))
  print(string.format("  late commands %d   rollbacks %d   max rewind depth %d ticks",
    a.late, a.rollbacks, a.depthMax))
  print(string.format("  duplicate atoms %d   N sent/answered %d/%d   backstop resends %d",
    a.dups, a.nSent, a.nAnswered, a.backstop))
  print(string.format("  settled hash compares %d   mismatches %d   Q sent/answered %d/%d   rebuilds from tick 0 %d",
    a.compares, a.mismatches, a.qSent, a.qAnswered, a.deep))
  print(string.format("  messages %d   dropped by channel %d   deliveries inverted %d   largest message %d bytes",
    a.msgs, a.dropped, a.inverted, a.bytesMax))
end

-- ===========================================================================
-- step: codec
-- ===========================================================================

local function stepCodec()
  print("== codec: round-trip, byte budgets, malformed-input fuzz ==")
  local checks = 0
  local function is(cond, what)
    checks = checks + 1
    if not cond then fail("codec: %s", what) end
  end

  local tok = Wire.token(4242)
  is(#tok == 6 and tok:sub(3, 3) == "-", "token shape")

  -- exact byte sizes against A.11.3's own table (14-byte envelope + payload)
  local sizes = {
    { Wire.encodeS(tok, { seed = Wire.MAX_SEED, rulesHash = Rules.rulesHash,
        matchTicks = 6000, loadout = { 40, 39, 1, 0, 12 } }), 39, "S" },
    { Wire.encodeH(tok, { tick = 5999, ackThru = 1295, lastSeq = 1295, epoch = 99,
        stateHash = Hash.MOD - 1, logDigest = Hash.MOD - 1 }), 31, "H" },
    { Wire.encodeN(tok, { tick = 0, ackThru = 0, from = 1, to = 1295 }), 23, "N" },
    { Wire.encodeM(tok, { tick = 5999, ackThru = 9, epoch = 3,
        stateHash = 12345, logDigest = 999 }), 29, "M" },
    { Wire.encodeQ(tok, { tick = 100, ackThru = 5 }), 19, "Q" },
    { Wire.encodeX(tok, { tick = 100, ackThru = 5, reason = "R" }), 20, "X" },
    { Wire.encodeK(tok, { tick = 100, ackThru = 5 }), 19, "K" },
    { Wire.encodeG(tok, { tick = 100, ackThru = 5, resumeTick = 4000 }), 22, "G" },
    { Wire.encodeV(tok, { tick = 100, ackThru = 5, reason = "D" }), 20, "V" },
  }
  for i = 1, #sizes do
    local msg, want, name = sizes[i][1], sizes[i][2], sizes[i][3]
    is(#msg == want, name .. " is " .. #msg .. " bytes, A.11.3 says " .. want)
    is(#msg <= Wire.MSG_BUDGET, name .. " inside the 200-byte budget")
  end
  -- C at n=1 and n=8: 28 and 70 bytes, the table's own bounds
  local a1 = { { exec = 46655, kind = "S", target = 3, count = 9 } }
  local c1 = Wire.encodeC(tok, { tick = 0, ackThru = 0, seq = 1, atoms = a1 })
  is(#c1 == 28, "C n=1 is 28 bytes")
  local a8 = {}
  for i = 1, 8 do a8[i] = { exec = 100 + i, kind = (i % 2 == 0) and "H" or "l", target = (i % 2 == 0) and 3 or 6, count = i } end
  local c8 = Wire.encodeC(tok, { tick = 5999, ackThru = 1295, seq = 1288, atoms = a8 })
  is(#c8 == 70, "C n=8 is 70 bytes -- the largest message in the protocol")

  -- round-trip every type, field for field
  local m = Wire.decode(sizes[1][1])
  is(m and m.mtype == "S" and m.seed == Wire.MAX_SEED and m.rulesHash == Rules.rulesHash
    and m.matchTicks == 6000 and m.loadout[1] == 40 and m.loadout[5] == 12, "S round-trip")
  m = Wire.decode(sizes[2][1])
  is(m and m.mtype == "H" and m.tick == 5999 and m.ackThru == 1295 and m.lastSeq == 1295
    and m.epoch == 99 % 36 and m.stateHash == (Hash.MOD - 1) % Wire.HASH_MOD
    and m.logDigest == (Hash.MOD - 1) % Wire.DIGEST_MOD, "H round-trip with truncation")
  m = Wire.decode(c8)
  is(m and m.mtype == "C" and m.seq == 1288 and #m.atoms == 8
    and m.atoms[3].exec == 103 and m.atoms[3].kind == "l" and m.atoms[3].seq == 1290
    and m.atoms[4].kind == "H" and m.atoms[4].target == 3, "C round-trip")
  m = Wire.decode(sizes[3][1])
  is(m and m.mtype == "N" and m.from == 1 and m.to == 1295, "N round-trip")
  m = Wire.decode(sizes[4][1])
  is(m and m.mtype == "M" and m.epoch == 3 and m.stateHash == 12345 and m.logDigest == 999, "M round-trip")
  m = Wire.decode(sizes[6][1])
  is(m and m.mtype == "X" and m.reason == "R", "X round-trip")
  m = Wire.decode(sizes[8][1])
  is(m and m.mtype == "G" and m.resumeTick == 4000, "G round-trip")

  -- seeded round-trip fuzz over the whole atom alphabet
  local r = Rand.new(9091)
  local letters = {}
  for i = 1, #Rules.UNITS do letters[#letters + 1] = Rules.UNITS[i].kind end
  for i = 1, #Rules.BUILDINGS do letters[#letters + 1] = Rules.BUILDINGS[i].letter end
  letters[#letters + 1] = "I"; letters[#letters + 1] = "E"; letters[#letters + 1] = "L"
  for _ = 1, 500 do
    local n = Rand.range(r, 1, 8)
    local atoms = {}
    for i = 1, n do
      local kind = letters[Rand.range(r, 1, #letters)]
      local top = (Wire.KIND_TARGET[kind] == "lane") and C.LANES or C.SLOTS
      atoms[i] = { exec = Rand.range(r, 0, Wire.MAX_TICK), kind = kind,
                   target = Rand.range(r, 1, top), count = Rand.range(r, 1, 9) }
    end
    local seq = Rand.range(r, 1, Wire.MAX_SEQ - n)
    local enc = Wire.encodeC(tok, { tick = Rand.range(r, 0, Wire.MAX_TICK),
      ackThru = Rand.range(r, 0, Wire.MAX_SEQ), seq = seq, atoms = atoms })
    local dm = Wire.decode(enc)
    is(dm ~= nil and dm.mtype == "C" and #dm.atoms == n, "C fuzz decode")
    if dm then
      for i = 1, n do
        local x, y = atoms[i], dm.atoms[i]
        if x.exec ~= y.exec or x.kind ~= y.kind or x.target ~= y.target
          or x.count ~= y.count or y.seq ~= seq + i - 1 then
          fail("codec: C fuzz atom %d does not round-trip", i)
        end
      end
      checks = checks + 1
    end
  end

  -- malformed corpus: every one must be REJECTED (nil), never a crash
  local badc = {
    "", "x", "4|IB", "4|IB|C|aa-bbb", "4|IB|C|aa-bbb|",
    "3|IB|H|aa-bbb|00000000000000000",          -- wrong wire version
    "4|LG|H|aa-bbb|00000000000000000",          -- wrong module
    "4|IB|Y|aa-bbb|0000000",                    -- unknown mtype
    "4|IB|H|aabbbb|00000000000000000",          -- token without the dash
    "4|IB|H|aa-bbb|0000000000000000",           -- H one char short
    "4|IB|H|aa-bbb|000000000000000000",         -- H one char long
    "4|IB|H|aa-bbb|0000000000000000!",          -- H with a non-alphabet char
    "4|IB|C|aa-bbb|0000000",                    -- C shorter than one atom
    "4|IB|C|aa-bbb|00000012001S11",             -- C n=2 but one atom present
    "4|IB|C|aa-bbb|00000011001s11",             -- lowercase s: NOT a unit (case)
    "4|IB|C|aa-bbb|00000011001A11",             -- uppercase A: NOT a building
    "4|IB|C|aa-bbb|00000011001S01",             -- lane target 0
    "4|IB|C|aa-bbb|00000011001S41",             -- lane target 4 (board has 3)
    "4|IB|C|aa-bbb|00000011001a71",             -- slot target 7 (board has 6)
    "4|IB|C|aa-bbb|00000011001S10",             -- count 0
    "4|IB|C|aa-bbb|00000010001S11",             -- batch count 0
    "4|IB|C|aa-bbb|00000001000S11",             -- seq 0
    "4|IB|N|aa-bbb|000000000200001",            -- N range inverted (from 2 to 1)
    "4|IB|X|aa-bbb|00000w",                     -- unknown halt reason letter
    "4|IB|S|aa-bbb|000000000000000000000000",   -- S one short
    "4|IB|C|aa-bbb|00000011001S11|x",           -- pipe inside payload
  }
  for i = 1, #badc do
    local okc, dm, why = pcall(Wire.decode, badc[i])
    is(okc, "decode raised on malformed input #" .. i)
    if okc then
      is(dm == nil and type(why) == "string", "malformed #" .. i .. " accepted: " .. tostring(why))
    end
  end
  -- random garbage, seeded: never a crash, and (being unframed) never accepted
  for i = 1, 2000 do
    local len = Rand.range(r, 0, 90)
    local s = ""
    for _ = 1, len do s = s .. string.char(Rand.range(r, 32, 126)) end
    local okc, dm = pcall(Wire.decode, s)
    is(okc, "decode raised on random garbage")
    if okc and dm ~= nil and s:sub(1, 5) ~= "4|IB|" then
      fail("codec: random garbage decoded as a message: %q", s)
    end
  end

  -- construction-time guards: oversized and out-of-range must ERROR (ours),
  -- and the transport must hard-error over 255 rather than deliver
  local okc = pcall(Wire.encodeC, tok, { tick = 0, ackThru = 0, seq = 1, atoms = {} })
  is(not okc, "encodeC accepted an empty batch")
  okc = pcall(Wire.encodeC, tok, { tick = 0, ackThru = 0, seq = 1,
    atoms = { { exec = 0, kind = "S", target = 4, count = 1 } } })
  is(not okc, "encodeC accepted lane 4")
  okc = pcall(Wire.encodeS, tok, { seed = Wire.MAX_SEED + 1, rulesHash = 1, matchTicks = 1, loadout = {} })
  is(not okc, "encodeS accepted an over-wide seed")
  local tr = Transport.new(1, {})
  okc = pcall(function() tr:send(1, string.rep("x", 256)) end)
  is(not okc, "transport delivered a 256-byte message instead of erroring")
  okc = pcall(function() tr:send(1, string.rep("x", 255)) end)
  is(okc, "transport refused a legal 255-byte message")

  -- the transport is a pure function of its seed: identical schedules twice
  local function schedule(seed)
    local t = Transport.new(seed, { dropPct = 30, latMin = 1, latMax = 30, reorderPct = 20, dupPct = 10 })
    local rr = Rand.new(seed + 1)
    local eventsAcc = Hash.new()
    for i = 1, 300 do
      t.now = i
      t:send(1 + (i % 2), "4|IB|Q|aa-bbb|" .. string.rep("0", 5))
      for side = 1, 2 do
        local got = t:deliver(side, i)
        eventsAcc = Hash.int(eventsAcc, #got)
      end
      local _ = rr
    end
    for i = 301, 400 do
      for side = 1, 2 do eventsAcc = Hash.int(eventsAcc, #t:deliver(side, i)) end
    end
    eventsAcc = Hash.int(eventsAcc, t.stat.dropped)
    eventsAcc = Hash.int(eventsAcc, t.stat.reordered)
    eventsAcc = Hash.int(eventsAcc, t.stat.duplicated)
    eventsAcc = Hash.int(eventsAcc, t.stat.inverted)
    return eventsAcc
  end
  is(schedule(777) == schedule(777), "transport schedule reproduces from its seed")
  is(schedule(777) ~= schedule(778), "transport schedule moves with its seed")

  print(string.format("  %d codec checks, %d failures", checks, failures))
  return failures == 0
end

-- ===========================================================================
-- the four scenario steps
-- ===========================================================================

-- Deterministic re-seed rule for scenario preconditions (a run with no late
-- command proves nothing about rollback; a match that ends before the
-- corruption tick proves nothing about recovery): try seed, then seed+7777,
-- up to 5 times, and FAIL the step if none qualifies. The offsets are part
-- of the schedule, so both interpreters walk identical seed sequences.
local RESEED = 7777
local RESEED_TRIES = 5

local function runScenario(name, n, base, topts, opts, qualify, wantQ, extraChecks)
  print(string.format("== %s: %d runs, base seed %d ==", name, n, base))
  print(string.format("  transport: drop %d%%  delay %d..%d ticks  reorder %d%%  dup %d%%",
    topts.dropPct or 10, topts.latMin or 1, topts.latMax or 30,
    topts.reorderPct or 10, topts.dupPct or 0))
  local agg = newTally()
  local suite = Hash.new()
  local before = failures
  local completed = 0
  for i = 1, n do
    local seed = base + i * 97
    local rec = nil
    for try = 0, RESEED_TRIES - 1 do
      local s = seed + try * RESEED
      local r = netMatch(s, topts, opts)
      if not r.void and (qualify == nil or qualify(r)) then
        rec = r
        seed = s
        break
      end
    end
    if not rec then
      fail("%s: no qualifying seed in %d tries from %d (the run would have proved nothing)",
        name, RESEED_TRIES, seed)
    else
      checkRun(rec, seed, wantQ, not wantQ and name == "milestone")
      if extraChecks then extraChecks(rec, seed) end
      suite = foldRun(suite, seed, rec)
      tally(agg, rec)
      completed = completed + 1
    end
    if failures >= before + 5 then
      print("  stopping this step after 5 failures")
      break
    end
  end
  printTally(agg, completed)
  print(string.format("  %s SUITE HASH %s", string.upper(name), hx(suite)))
  return agg, suite, completed
end

local MILESTONE_TOPTS = { dropPct = 10, latMin = 1, latMax = 30, reorderPct = 10, dupPct = 0 }

local function stepMilestone(n)
  local agg, _, completed = runScenario("milestone", n, 41000, MILESTONE_TOPTS, nil, nil, false, nil)
  -- floors that keep the step meaningful rather than lucky (the schedule's
  -- own generator mix measures ~14% full-length at this base; require half)
  if agg.late < completed * 2 then
    fail("milestone: only %d late commands over %d runs -- the scenario is not exercising rollback", agg.late, completed)
  end
  if agg.full < floor(completed / 14) then
    fail("milestone: only %d of %d runs reached the full 6,000 ticks", agg.full, completed)
  end
  if agg.inverted == 0 then fail("milestone: the channel never delivered out of order") end
  if agg.mismatches ~= 0 or agg.qSent ~= 0 or agg.deep ~= 0 then
    fail("milestone: escalations in the clean scenario (mismatch %d, Q %d, rebuilds %d)",
      agg.mismatches, agg.qSent, agg.deep)
  end
  if agg.bytesMax > Wire.MSG_BUDGET then
    fail("milestone: a %d-byte message crossed the wire", agg.bytesMax)
  end
end

local function stepRollback(n)
  -- harsher reordering and explicit duplication: every A.12 boundary case
  -- must actually OCCUR, and a run with no late command is re-seeded because
  -- it proves nothing (the step's own rule, applied per run)
  local topts = { dropPct = 10, latMin = 1, latMax = 30, reorderPct = 25, dupPct = 5 }
  local function qualify(rec)
    return (rec.eps[1].st.late + rec.eps[2].st.late) >= 1
  end
  local agg, _, completed = runScenario("rollback", n, 52000, topts, nil, qualify, false, nil)
  if agg.dups == 0 then fail("rollback: no duplicate atom was ever delivered (dup idempotence untested)") end
  if agg.nSent == 0 or agg.nAnswered == 0 then fail("rollback: the receiver-driven resend path never ran") end
  if agg.backstop == 0 then fail("rollback: the sender-driven backstop never fired") end
  if agg.inverted == 0 then fail("rollback: no delivery was ever inverted") end
  if agg.compares < completed then
    fail("rollback: %d settled compares over %d runs -- detection was barely live", agg.compares, completed)
  end
end

-- Fixed carded loadouts for the deep step: one card of each family per side,
-- distinct ids, so the rebuilt sims carry REAL loadout state to assert on.
local DEEP_LO_A = { 1, 9, 17, 25, 33 }
local DEEP_LO_B = { 2, 10, 18, 26, 34 }

local function stepDeep(n)
  local corruptAt = 2600
  print(string.format("== deep: forced state corruption from harness tick %d (ep2, +47 Levy per tick,", corruptAt))
  print("   books kept balanced, recurring until detected); every second run ALSO wipes ep2's")
  print("   held peer history -- and is re-seeded until the wiped span is too wide for the")
  print("   spanning N, so the Q replay is LOAD-BEARING rather than a formality ==")
  local agg = newTally()
  local suite = Hash.new()
  local before = failures
  local completed = 0
  for i = 1, n do
    local seed = 63000 + i * 97
    local wipe = (i % 2 == 0)
    local o = { styleA = "guard", styleB = "guard",
      loadoutA = DEEP_LO_A, loadoutB = DEEP_LO_B,
      corruptAt = corruptAt, corruptWipe = wipe }
    local rec = nil
    for try = 0, RESEED_TRIES - 1 do
      local s = seed + try * RESEED
      local r = netMatch(s, MILESTONE_TOPTS, o)
      -- scenario preconditions, re-seeded like the rollback step's: the
      -- match must be alive at the corruption tick and survive it long
      -- enough that detection is possible at all; a wipe must be wider
      -- than N's spanning reach, or the ladder legally heals it a rung
      -- early and the run demonstrates nothing about Q
      if not r.void and r.corrupted
        and r.ref.terminalTick >= corruptAt + 300
        and (not wipe or r.wipeSpan > 32) then
        rec = r
        seed = s
        break
      end
    end
    if not rec then
      fail("deep: no qualifying seed in %d tries from %d", RESEED_TRIES, seed)
    else
      checkRun(rec, seed, true, false)
      local st1, st2 = rec.eps[1].st, rec.eps[2].st
      if st1.mismatches + st2.mismatches + st1.qSent + st2.qSent == 0 then
        fail("deep seed %d: the corruption was never detected", seed)
      end
      if st1.qSent + st2.qSent == 0 then
        fail("deep seed %d: no Q was ever requested", seed)
      end
      if wipe and st1.qAnswered + st2.qAnswered == 0 then
        -- with a wiped span past N's reach, recovery is impossible without
        -- the answered replay -- this is the assertion that the Q path is
        -- real, not merely reachable
        fail("deep seed %d: history wiped (span %d) but no Q was ever answered", seed, rec.wipeSpan)
      end
      if st1.deepRecoveries + st2.deepRecoveries == 0 then
        fail("deep seed %d: no rebuild from tick 0 happened", seed)
      end
      if rec.firstQtick >= 0 and rec.firstQtick - corruptAt > 900 then
        fail("deep seed %d: detection took %d ticks (over 15 epochs)", seed, rec.firstQtick - corruptAt)
      end
      -- the rebuild NEEDS both loadouts: the rebuilt sims must carry them
      for si = 1, 2 do
        local want = (si == 1) and DEEP_LO_A or DEEP_LO_B
        for k = 1, 5 do
          if rec.eps[1].sim.sides[si].loadout[k] ~= want[k]
            or rec.eps[2].sim.sides[si].loadout[k] ~= want[k] then
            fail("deep seed %d: rebuilt side-%d loadout slot %d does not match the handshake", seed, si, k)
          end
        end
      end
      suite = foldRun(suite, seed, rec)
      tally(agg, rec)
      completed = completed + 1
    end
    if failures >= before + 5 then
      print("  stopping this step after 5 failures")
      break
    end
  end
  printTally(agg, completed)
  print(string.format("  DEEP SUITE HASH %s", hx(suite)))
  if agg.deep == 0 then fail("deep: zero rebuilds across the whole step") end
  if agg.qAnswered == 0 then fail("deep: no Q was ever answered across the whole step") end
  if agg.mismatches == 0 then fail("deep: the epoch-hash exchange never detected the corruption") end
end

local function stepStress(n)
  -- harsher than the milestone in every dial. A.12's design converges here
  -- too -- what loss adds is repair traffic and, at the extreme, escalation
  -- through the documented ladder (N -> backstop -> hash adjudication -> Q
  -- rebuild), which is allowed and COUNTED, never a failure. What is still
  -- asserted, unchanged: both endpoints end bit-identical to the no-netcode
  -- reference at every epoch. The failure mode past this ladder is V (void),
  -- which M4 never reaches on a lossy-but-alive channel.
  local topts = { dropPct = 30, latMin = 1, latMax = 40, reorderPct = 20, dupPct = 10 }
  runScenario("stress", n, 74000, topts, nil, nil, true, nil)
end

-- ===========================================================================
-- main
-- ===========================================================================

local mode = arg[1] or "all"
local n = tonumber(arg[2])

print(string.format("ruleset %s   rulesHash %s (%s)",
  Rules.RULESET_VERSION, Hash.dec(Rules.rulesHash), Rules.rulesHash36))
print(string.format("order delay %d   snapshot epoch %d x keep %d   heartbeat %d   match %d ticks",
  C.ORDER_DELAY, C.SNAPSHOT_EPOCH, C.SNAPSHOT_KEEP, C.HEARTBEAT_TICKS, C.MATCH_TICKS))
print("")

if not Rand.selftest() then
  print("FAIL: sim/Rand.lua self-test did not pass; nothing below is meaningful")
  os.exit(1)
end

if mode == "codec" then
  stepCodec()
elseif mode == "milestone" then
  stepMilestone(n or 100)
elseif mode == "rollback" then
  stepRollback(n or 40)
elseif mode == "deep" then
  stepDeep(n or 12)
elseif mode == "stress" then
  stepStress(n or 25)
elseif mode == "all" then
  stepCodec()
  print("")
  stepMilestone(100)
  print("")
  stepRollback(40)
  print("")
  stepDeep(12)
  print("")
  stepStress(25)
else
  io.stderr:write("m4run: unknown mode " .. tostring(mode) .. "\n")
  os.exit(2)
end

print("")
if failures > 0 then
  print(string.format("M4 RUN: FAILED (%d failures)", failures))
  os.exit(1)
end
print("M4 RUN: PASS")
os.exit(0)
