-- net/Net.lua -- the A.12 reliability shim. M4.
--
-- One endpoint per client: it owns a Sim instance, speaks net/Wire.lua's
-- messages through whatever send function it is given (net/Transport.lua in
-- M4, the addon channel in M5), and implements A.12 in full:
--
--   * per-sender monotonic seq from 1; dedup on (sender, seq); the COMPLETE
--     ordered command history retained for the whole match, both directions
--   * acks are the ackThru field on every message; no standalone ACK exists
--   * resend: receiver-driven N on a visible gap (primary), sender-driven
--     backstop once after 2 heartbeats unacked, stop after 4 -- N is still
--     answered forever, so a gap can always be repaired
--   * the input-delay contract: a local order issued at tick T is queued for
--     exec T + ORDER_DELAY on the local sim and shipped as an atom; a peer
--     atom arriving AFTER its exec tick triggers BOUNDED ROLLBACK -- restore
--     the newest snapshot at or before the exec tick, splice, re-simulate
--     forward, and re-record every epoch hash and snapshot on the way
--   * snapshots every SNAPSHOT_EPOCH ticks, keeping SNAPSHOT_KEEP (C.1: 60
--     and 5 -- 24 to 30 s of depth), plus one at tick 0 while the ring fills
--   * epoch hash exchange: H every HEARTBEAT_TICKS carrying the last epoch
--     boundary's stateHash; a SETTLED disagreement (both histories provably
--     complete for that epoch -- the exact test is at adjudicate()) is a
--     detected desync: M, then the Q path
--   * Q full-log recovery: on a detected desync, or on a gap too wide for N
--     (a peer too far behind), or on a late command beyond snapshot depth:
--     send Q; the peer answers with a fresh S (its loadout -- the rebuild
--     NEEDS both loadouts, which is Ruling 1's concrete payoff), a fresh H
--     (the lastSeq watermark that tells the requester when it holds
--     everything), and its entire command history as verbatim C batches;
--     the requester then rebuilds from tick 0 -- Sim.new(rules, seed,
--     loadout1, loadout2), every held command re-queued, re-simulated to the
--     present -- and proves convergence by hash on the next exchanges.
--
-- WHAT THIS FILE IS NOT. It is not the halt/resume machinery: X, K, G and V
-- are decoded and counted but not acted on (M6). It is not a scheduler: the
-- caller owns the clock and calls step(now); nothing here reads a clock.
--
-- Held to the sim's determinism rules: integers only, no pairs, no
-- math.random, no clock, and both seats run this same code with the side
-- index as data (A.2 at the shim layer).

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local SimM = IB_SIM_MODULES and IB_SIM_MODULES.Sim or require("sim.Sim")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Wire = IB_SIM_MODULES and IB_SIM_MODULES.Wire or require("net.Wire")
local Snap = IB_SIM_MODULES and IB_SIM_MODULES.Snap or require("net.Snap")

local floor = math.floor

local M = {}

local Net = {}
Net.__index = Net

-- A.11.4's module-level send bucket for C: capacity 4, refill 1 per 4 s.
local C_BUCKET_CAP = 4
local C_BUCKET_REFILL = 40      -- ticks per token
-- Q replay pacing: A.12 says ~20 messages is "above the 10-token burst, so
-- pace them across two burst windows" -- read as at most 10 replay messages
-- per 100-tick (10 s) window, bypassing the order bucket (INTERPRETATIONS).
local REPLAY_BURST = 10
local REPLAY_WINDOW = 100
local HELLO_EVERY = 60          -- S retry cadence until the peer's S is held
local N_EVERY = 30              -- re-request an open gap at most this often.
                                -- A.12 says N goes out "immediately" on the
                                -- inbound that shows the gap; the cadence
                                -- only stops one gap spamming N per message
local BACKSTOP_AT = 2           -- heartbeats unacked -> resend once
local BACKSTOP_STOP = 4         -- heartbeats unacked -> stop resending
local Q_COOLDOWN = 100          -- SYNC_COOLDOWN = 10 s, reused verbatim (A.12)
local Q_GAP = 32                -- a gap wider than this is "too far behind":
                                -- N would ship it a batch per bucket token,
                                -- which is the slow path; Q is the built one
local RECOVERY_GRACE = 120      -- ignore stale hash claims this long after a
                                -- rebuild (2 heartbeats > any transit)

-- opts: rules (default sim/Rules), side 1|2, seed, loadout (array of 5, or
-- nil for cardless), send (function(str)), matchTicks (default rules.C).
function M.new(opts)
  local rules = opts.rules or Rules
  local side = opts.side
  if side ~= 1 and side ~= 2 then error("Net: side must be 1 or 2") end
  local lo = {}
  for i = 1, 5 do lo[i] = (opts.loadout and opts.loadout[i]) or 0 end
  local ep = setmetatable({
    rules = rules,
    C = rules.C,
    side = side,
    peer = 3 - side,
    seed = opts.seed or 0,
    matchTicks = opts.matchTicks or rules.C.MATCH_TICKS,
    token = Wire.token(opts.seed or 0),
    sendFn = opts.send,
    -- handshake
    loadouts = { false, false },      -- [side] = array(5) once known
    peerHello = false,                -- peer's S held
    peerBuilt = false,                -- peer proven live (any H or C received),
                                      -- which is the proof it holds OUR S and
                                      -- the S offer cadence can stop
    lastHello = -1000000,
    -- the sim (built when both loadouts are held)
    sim = false,
    t0 = 0,
    -- outbound commands: seq -> atom record, retained all match
    outSeq = 0,
    outBuf = {},
    sendQ = {},                       -- NEW atom seqs awaiting a C batch
    repairQ = {},                     -- RESEND seqs (N answers, backstop).
                                      -- Repair traffic has its own A.11.4
                                      -- budget row and does not queue behind
                                      -- the order-coalescing bucket
    peerAckThru = 0,
    tokens = C_BUCKET_CAP,
    lastRefill = 0,
    -- inbound commands: seq -> atom record, retained all match
    inHave = {},
    inContig = 0,
    peerLastSeq = 0,
    lastNSent = -1000000,
    -- epoch trace and snapshots
    epochHash = {},                   -- absolute epoch -> full 31-bit hash
    epochMax = 0,
    snaps = {},                       -- ascending by tick, <= SNAPSHOT_KEEP+1
    -- heartbeats and recovery
    lastHb = 0,
    recovering = false,
    qCooldownUntil = -1000000,
    graceUntil = -1000000,
    replayQ = {},                     -- { seq0, atoms } awaiting paced send
    replayHead = 1,
    replayWindowUntil = -1000000,
    replayInWindow = 0,
    -- instrumentation (all integers, all deterministic)
    st = {
      sent = 0, recv = 0, malformed = 0, wrongToken = 0, deferred = 0,
      sSent = 0, cSent = 0, hSent = 0, nSent = 0, mSent = 0, qSent = 0,
      dupAtoms = 0, refusedAtoms = 0,
      late = 0, rollbacks = 0, rollbackDepthMax = 0, lateBeyondDepth = 0,
      gapsSeen = 0, nAnswered = 0, backstopResends = 0,
      settledCompares = 0, mismatches = 0,
      qAnswered = 0, deepRecoveries = 0,
    },
  }, Net)
  ep.loadouts[side] = lo
  return ep
end

-- ---------------------------------------------------------------------------
-- small internals
-- ---------------------------------------------------------------------------

local function send(ep, str)
  ep.st.sent = ep.st.sent + 1
  ep.sendFn(str)
end

local function sendS(ep, now)
  ep.lastHello = now
  ep.st.sSent = ep.st.sSent + 1
  send(ep, Wire.encodeS(ep.token, {
    seed = ep.seed, rulesHash = ep.rules.rulesHash, matchTicks = ep.matchTicks,
    loadout = ep.loadouts[ep.side],
  }))
end

local function sendH(ep, now)
  ep.lastHb = now
  local sim = ep.sim
  local e = floor(sim.clock / ep.C.SNAPSHOT_EPOCH)
  ep.st.hSent = ep.st.hSent + 1
  send(ep, Wire.encodeH(ep.token, {
    tick = sim.clock, ackThru = ep.inContig, lastSeq = ep.outSeq,
    epoch = e, stateHash = ep.epochHash[e], logDigest = Hash.log(sim),
  }))
end

local function pushSnap(ep, tick)
  local snaps = ep.snaps
  local n = #snaps
  -- Re-taking a tick already in the ring (a rollback re-simulating through
  -- it) replaces the entry: the repaired trajectory's snapshot is the one
  -- that must serve the next rollback.
  for i = n, 1, -1 do
    if snaps[i].tick == tick then
      snaps[i] = { tick = tick, snap = Snap.take(ep.sim) }
      return
    end
    if snaps[i].tick < tick then break end
  end
  snaps[n + 1] = { tick = tick, snap = Snap.take(ep.sim) }
  -- keep the last SNAPSHOT_KEEP epoch snapshots, plus tick 0 only while the
  -- ring has room (A.12: "keep the last 5")
  while #snaps > ep.C.SNAPSHOT_KEEP do
    for i = 1, #snaps - 1 do snaps[i] = snaps[i + 1] end
    snaps[#snaps] = nil
  end
end

-- One sim tick plus the epoch bookkeeping that must follow it everywhere a
-- tick can happen (live stepping, rollback re-simulation, rebuild).
local function tickOnce(ep)
  local sim = ep.sim
  if not sim:tick() then return false end
  if sim.clock % ep.C.SNAPSHOT_EPOCH == 0 then
    local e = floor(sim.clock / ep.C.SNAPSHOT_EPOCH)
    ep.epochHash[e] = Hash.state(sim)
    if e > ep.epochMax then ep.epochMax = e end
    pushSnap(ep, sim.clock)
  end
  return true
end

-- Drop recorded epochs above the sim's current position (after a rollback
-- whose repaired trajectory ended EARLIER than the provisional one did --
-- the boundary at floor(clock/EPOCH) itself has run and stays).
local function trimEpochs(ep)
  local top = floor(ep.sim.clock / ep.C.SNAPSHOT_EPOCH)
  for e = top + 1, ep.epochMax do ep.epochHash[e] = nil end
  if ep.epochMax > top then ep.epochMax = top end
end

local function buildSim(ep, now)
  ep.sim = SimM.new(ep.rules, ep.seed, ep.loadouts[1], ep.loadouts[2])
  ep.t0 = now
  ep.lastHb = now
  ep.lastRefill = now
  ep.epochHash[0] = Hash.state(ep.sim)
  ep.epochMax = 0
  pushSnap(ep, 0)
  -- Atoms that arrived before the handshake completed (their C outran the
  -- peer's S) were parked in inHave; every one is a normal future queue now.
  for seq = 1, ep.peerLastSeq do
    local a = ep.inHave[seq]
    if a then
      ep.sim:queueCommand({ side = ep.peer, seq = seq, tick = a.exec,
                            kind = a.kind, target = a.target, count = a.count })
    end
  end
end

-- ---------------------------------------------------------------------------
-- rollback (A.12 bounded rewind) and rebuild (the Q path)
-- ---------------------------------------------------------------------------

-- Re-offer every retained command with exec at or after `fromTick` to the
-- current sim. Anything already inside it is refused as a duplicate by the
-- sim's own (side, seq) dedup, which is the idempotence A.12 requires.
local function offerAll(ep, fromTick)
  local sim = ep.sim
  for seq = 1, ep.outSeq do
    local a = ep.outBuf[seq]
    if a and a.exec >= fromTick then
      sim:queueCommand({ side = ep.side, seq = seq, tick = a.exec,
                        kind = a.kind, target = a.target, count = a.count })
    end
  end
  for seq = 1, ep.peerLastSeq do
    local a = ep.inHave[seq]
    if a and a.exec >= fromTick then
      sim:queueCommand({ side = ep.peer, seq = seq, tick = a.exec,
                        kind = a.kind, target = a.target, count = a.count })
    end
  end
end

-- A peer atom with exec below the sim clock: restore the newest snapshot at
-- or before its exec tick, splice everything known back in, re-simulate to
-- where the sim stood. Every epoch hash and snapshot on the way is
-- re-recorded, so the trace and the ring always describe the REPAIRED
-- trajectory -- a second late command must never meet a stale snapshot.
local function rollback(ep, execTick)
  local snaps = ep.snaps
  local best = nil
  for i = #snaps, 1, -1 do
    if snaps[i].tick <= execTick then best = snaps[i]; break end
  end
  if not best then return false end
  local sim = ep.sim
  local target = sim.clock
  local depth = target - best.tick
  ep.st.rollbacks = ep.st.rollbacks + 1
  if depth > ep.st.rollbackDepthMax then ep.st.rollbackDepthMax = depth end
  -- prune ring entries newer than the restore point; the re-simulation below
  -- re-takes them on the repaired trajectory
  while #snaps > 0 and snaps[#snaps].tick > best.tick do snaps[#snaps] = nil end
  Snap.restore(sim, best.snap)
  offerAll(ep, best.tick)
  while sim.clock < target do
    if not tickOnce(ep) then break end
  end
  trimEpochs(ep)
  return true
end

-- The Q rebuild: a fresh sim from the handshake triple (rules, seed, BOTH
-- loadouts -- Ruling 1's concrete payoff), the entire retained history
-- replayed from tick 0, re-simulated to the present. The old sim object is
-- discarded whole; there is nothing in it worth keeping, which is the point.
local function rebuild(ep, now)
  ep.st.deepRecoveries = ep.st.deepRecoveries + 1
  ep.sim = SimM.new(ep.rules, ep.seed, ep.loadouts[1], ep.loadouts[2])
  ep.epochHash = {}
  ep.epochHash[0] = Hash.state(ep.sim)
  ep.epochMax = 0
  ep.snaps = {}
  pushSnap(ep, 0)
  offerAll(ep, 0)
  local target = now - ep.t0
  if target > ep.matchTicks then target = ep.matchTicks end
  while ep.sim.clock < target do
    if not tickOnce(ep) then break end
  end
  ep.recovering = false
  ep.graceUntil = now + RECOVERY_GRACE
end

local function maybeRequestRecovery(ep, now)
  ep.recovering = true
  if now < ep.qCooldownUntil then return end   -- <= 1 Q per 10 s (A.11.3)
  ep.qCooldownUntil = now + Q_COOLDOWN
  ep.st.qSent = ep.st.qSent + 1
  send(ep, Wire.encodeQ(ep.token, { tick = ep.sim.clock, ackThru = ep.inContig }))
end

-- Recovery completes the moment the peer's history is contiguously held up
-- to its announced watermark; everything else needed was retained locally.
local function checkRecovery(ep, now)
  if ep.recovering and ep.sim and ep.inContig >= ep.peerLastSeq then
    rebuild(ep, now)
  end
end

-- ---------------------------------------------------------------------------
-- inbound
-- ---------------------------------------------------------------------------

local function handleAck(ep, ackThru)
  if ackThru > ep.peerAckThru then ep.peerAckThru = ackThru end
end

-- A gap below the peer's announced watermark: request everything missing in
-- ONE spanning range (receiver-driven resend, A.12's primary path; a span
-- may cover seqs already held, whose resends dedup away -- one round trip
-- beats one N per hole when losses burst). A gap wider than Q_GAP is a
-- peer-too-far-behind case and escalates to the Q path -- N repairs
-- potholes, not a missing road.
local function gapCheck(ep, now)
  if ep.inContig >= ep.peerLastSeq then return end
  ep.st.gapsSeen = ep.st.gapsSeen + 1
  if ep.peerLastSeq - ep.inContig > Q_GAP then
    maybeRequestRecovery(ep, now)
    return
  end
  if now - ep.lastNSent < N_EVERY then return end
  local from = ep.inContig + 1
  local to = from
  for s = ep.peerLastSeq, from + 1, -1 do
    if ep.inHave[s] == nil then to = s; break end
  end
  ep.lastNSent = now
  ep.st.nSent = ep.st.nSent + 1
  send(ep, Wire.encodeN(ep.token, { tick = ep.sim and ep.sim.clock or 0,
                                    ackThru = ep.inContig, from = from, to = to }))
end

local function receiveAtom(ep, a, now)
  if a.seq <= ep.inContig or ep.inHave[a.seq] then
    ep.st.dupAtoms = ep.st.dupAtoms + 1   -- resend after the original: idempotent
    return
  end
  ep.inHave[a.seq] = a
  if a.seq > ep.peerLastSeq then ep.peerLastSeq = a.seq end
  while ep.inHave[ep.inContig + 1] do ep.inContig = ep.inContig + 1 end
  if not ep.sim then return end            -- parked; buildSim queues it
  if ep.recovering then return end         -- parked; rebuild consumes it
  if a.exec >= ep.sim.clock then
    local ok, err = ep.sim:queueCommand({ side = ep.peer, seq = a.seq, tick = a.exec,
                                          kind = a.kind, target = a.target, count = a.count })
    if not ok and err ~= "duplicate" then
      ep.st.refusedAtoms = ep.st.refusedAtoms + 1
    end
  else
    ep.st.late = ep.st.late + 1
    if not rollback(ep, a.exec) then
      -- older than the snapshot depth: unrepairable by rewind; escalate
      -- (A.12: "and that escalates") to the full-log path
      ep.st.lateBeyondDepth = ep.st.lateBeyondDepth + 1
      maybeRequestRecovery(ep, now)
    end
  end
end

-- Is epoch E settled between the two of us, given the peer's claim
-- (lastSeq, ackThru)? Settled means both histories are provably complete
-- below the epoch tick: I hold their whole history to lastSeq, and nothing
-- of mine they lack can land at or before the epoch tick. Only a settled
-- disagreement is a desync; an unsettled one is just light still in flight.
local function adjudicate(ep, now, absEpoch, epochChar, wireHash, claimLastSeq, claimAckThru)
  if now < ep.graceUntil or ep.recovering then return end
  if absEpoch % 36 ~= epochChar then ep.st.malformed = ep.st.malformed + 1; return end
  local mine = ep.epochHash[absEpoch]
  if mine == nil then return end
  if ep.inContig < claimLastSeq then return end
  local epochTick = absEpoch * ep.C.SNAPSHOT_EPOCH
  for seq = claimAckThru + 1, ep.outSeq do
    local a = ep.outBuf[seq]
    if a and a.exec <= epochTick then return end
  end
  ep.st.settledCompares = ep.st.settledCompares + 1
  if mine % Wire.HASH_MOD ~= wireHash then
    ep.st.mismatches = ep.st.mismatches + 1
    ep.st.mSent = ep.st.mSent + 1
    send(ep, Wire.encodeM(ep.token, { tick = ep.sim.clock, ackThru = ep.inContig,
                                      epoch = absEpoch, stateHash = mine,
                                      logDigest = Hash.log(ep.sim) }))
    maybeRequestRecovery(ep, now)
  end
end

-- Answer a Q: a fresh S (the loadout half of the rebuild), a fresh H (the
-- watermark that tells the requester when it holds everything), and the
-- own-command history FROM THE Q'S OWN ackThru CLAIM as verbatim C batches,
-- paced by flushReplay. The claim in the row itself -- NOT the monotone
-- peerAckThru -- is the right floor, and the difference is the deep-wipe
-- case the M4 gate forces: acks only ever rise, so after the requester
-- wipes its held history peerAckThru still says "holds everything" while
-- the Q honestly claims the new low watermark and needs the atoms below the
-- old one re-streamed. Healthy mid-match recovery claims high and gets the
-- gap alone (the M5 review measured the old full-history replay at ~63 s of
-- saturated shared bucket); a repeat Q (10 s cooldown) rebuilds from the
-- requester's CURRENT claim, so restarts shrink instead of starting over.
local function answerQ(ep, now, fromAck)
  ep.st.qAnswered = ep.st.qAnswered + 1
  sendS(ep, now)
  sendH(ep, now)
  local q, nq = {}, 0
  local i = (fromAck or 0) + 1
  while i <= ep.outSeq do
    local atoms, n = {}, 0
    while n < Wire.MAX_BATCH and i <= ep.outSeq do
      local a = ep.outBuf[i]
      if not a then break end
      n = n + 1
      atoms[n] = { exec = a.exec, kind = a.kind, target = a.target, count = a.count }
      i = i + 1
    end
    if n == 0 then break end
    nq = nq + 1
    q[nq] = { seq0 = i - n, atoms = atoms }
  end
  ep.replayQ = q
  ep.replayHead = 1
end

local function flushReplay(ep, now)
  if ep.replayHead > #ep.replayQ then return end
  if now >= ep.replayWindowUntil then
    ep.replayWindowUntil = now + REPLAY_WINDOW
    ep.replayInWindow = 0
  end
  -- No skip-by-peerAckThru clause here, and that is deliberate: acks are
  -- monotone, so after a deep wipe the watermark still claims the requester
  -- holds atoms it just discarded -- a "cancel the residual stream" shortcut
  -- keyed on it would starve exactly the rebuild it was pacing. The stream
  -- shrinks the honest way: a repeat Q re-queues from the requester's
  -- current claim.
  while ep.replayInWindow < REPLAY_BURST and ep.replayHead <= #ep.replayQ do
    local b = ep.replayQ[ep.replayHead]
    ep.replayHead = ep.replayHead + 1
    ep.replayInWindow = ep.replayInWindow + 1
    ep.st.cSent = ep.st.cSent + 1
    send(ep, Wire.encodeC(ep.token, { tick = ep.sim.clock, ackThru = ep.inContig,
                                      seq = b.seq0, atoms = b.atoms }))
  end
  if ep.replayHead > #ep.replayQ then
    ep.replayQ = {}
    ep.replayHead = 1
  end
end

function Net.onWire(ep, msg, now)
  local m, why = Wire.decode(msg)
  if not m then
    ep.st.malformed = ep.st.malformed + 1
    ep.lastDecodeError = why
    return
  end
  if m.token ~= ep.token then
    ep.st.wrongToken = ep.st.wrongToken + 1   -- another match's traffic
    return
  end
  ep.st.recv = ep.st.recv + 1

  if m.mtype == "S" then
    if m.rulesHash ~= ep.rules.rulesHash or m.seed ~= ep.seed
      or m.matchTicks ~= ep.matchTicks or m.proto ~= Wire.PROTO then
      -- A.11.1: two refusal classes. M4 counts them; M5 words them.
      ep.st.malformed = ep.st.malformed + 1
      return
    end
    ep.peerHello = true
    ep.loadouts[ep.peer] = m.loadout
    if not ep.sim then buildSim(ep, now) end
    return
  end

  -- Any H or C proves the peer's sim exists, which proves it holds our S;
  -- the S offer cadence in step() keys off this rather than off a reply
  -- rule, which is what makes the exchange terminate with no ping-pong.
  if m.mtype == "H" or m.mtype == "C" then ep.peerBuilt = true end

  if not ep.sim then
    -- In-match traffic outrunning the handshake: park what can be parked.
    if m.mtype == "C" then
      handleAck(ep, m.ackThru)
      for i = 1, #m.atoms do receiveAtom(ep, m.atoms[i], now) end
    elseif m.mtype == "H" then
      handleAck(ep, m.ackThru)
      if m.lastSeq > ep.peerLastSeq then ep.peerLastSeq = m.lastSeq end
    end
    return
  end

  if m.mtype == "C" then
    handleAck(ep, m.ackThru)
    for i = 1, #m.atoms do receiveAtom(ep, m.atoms[i], now) end
    gapCheck(ep, now)
    checkRecovery(ep, now)
    return
  end

  if m.mtype == "H" then
    handleAck(ep, m.ackThru)
    if m.lastSeq > ep.peerLastSeq then ep.peerLastSeq = m.lastSeq end
    gapCheck(ep, now)
    checkRecovery(ep, now)
    adjudicate(ep, now, floor(m.tick / ep.C.SNAPSHOT_EPOCH), m.epoch,
      m.stateHash, m.lastSeq, m.ackThru)
    return
  end

  if m.mtype == "N" then
    handleAck(ep, m.ackThru)
    ep.st.nAnswered = ep.st.nAnswered + 1
    local to = m.to
    if to > ep.outSeq then to = ep.outSeq end
    for seq = m.from, to do
      if ep.outBuf[seq] then ep.repairQ[#ep.repairQ + 1] = seq end
    end
    return
  end

  if m.mtype == "M" then
    handleAck(ep, m.ackThru)
    -- The disputed epoch: the 1-char field is mod 36; the nearest epoch at
    -- or below the sender's own tick that matches it is the one meant
    -- (disputes are always recent -- settledness lags by heartbeats, not by
    -- the 36-epoch ambiguity distance).
    local base = floor(m.tick / ep.C.SNAPSHOT_EPOCH)
    local absEpoch = base - ((base - m.epoch) % 36)
    if absEpoch >= 0 and not ep.recovering and now >= ep.graceUntil then
      local mine = ep.epochHash[absEpoch]
      if mine ~= nil and mine % Wire.HASH_MOD ~= m.stateHash then
        maybeRequestRecovery(ep, now)
      end
    end
    return
  end

  if m.mtype == "Q" then
    handleAck(ep, m.ackThru)
    answerQ(ep, now, m.ackThru)
    return
  end

  -- X, K, G, V: recognised, counted, deferred to M6 (halt/resume) by design.
  ep.st.deferred = ep.st.deferred + 1
end

-- ---------------------------------------------------------------------------
-- outbound
-- ---------------------------------------------------------------------------

-- ascending unique, in place of table.sort (grep 4 flags it): insertion sort
-- over integers with duplicates collapsed (a seq can be queued by both the
-- backstop and an N answer inside one window).
local function sortedUnique(q)
  local sorted, n = {}, 0
  for i = 1, #q do
    local v = q[i]
    local j = n
    while j >= 1 and sorted[j] > v do
      sorted[j + 1] = sorted[j]
      j = j - 1
    end
    if j >= 1 and sorted[j] == v then
      for k = j + 1, n do sorted[k] = sorted[k + 1] end
      sorted[n + 1] = nil
    else
      sorted[j + 1] = v
      n = n + 1
    end
  end
  return sorted, n
end

-- Emit C batches of consecutive-seq runs from `sorted[i..n]`, stopping when
-- `budget` messages have been sent. Returns the next unsent index and the
-- number of messages actually sent.
local function emitBatches(ep, sorted, n, i, budget, now)
  local msgs = 0
  while i <= n and budget > 0 do
    local first = sorted[i]
    local atoms, an = {}, 0
    while i <= n and an < Wire.MAX_BATCH and sorted[i] == first + an do
      local a = ep.outBuf[sorted[i]]
      an = an + 1
      atoms[an] = { exec = a.exec, kind = a.kind, target = a.target, count = a.count }
      if a.firstSent < 0 then a.firstSent = now end
      i = i + 1
    end
    budget = budget - 1
    msgs = msgs + 1
    ep.st.cSent = ep.st.cSent + 1
    send(ep, Wire.encodeC(ep.token, { tick = ep.sim.clock, ackThru = ep.inContig,
                                      seq = first, atoms = atoms }))
  end
  return i, msgs
end

-- Flush the two outbound queues. NEW atoms ride the A.11.4 module bucket
-- (capacity 4, one per 4 s, C only -- a frantic clicker is coalesced, never
-- dropped). RESENDS are repair traffic with their own A.11.4 budget row and
-- go out at once, verbatim (same seq, same exec), capped per flush so a
-- pathological gap cannot burst-flood the channel. Forward-declared:
-- issue() below flushes too.
local flushSend

flushSend = function(ep, now)
  if not ep.sim then return end
  if #ep.repairQ > 0 then
    local sorted, n = sortedUnique(ep.repairQ)
    local i = emitBatches(ep, sorted, n, 1, 4, now)
    local rest, rn = {}, 0
    for k = i, n do
      rn = rn + 1
      rest[rn] = sorted[k]
    end
    ep.repairQ = rest
  end
  if #ep.sendQ > 0 then
    local sorted, n = sortedUnique(ep.sendQ)
    local i, msgs = emitBatches(ep, sorted, n, 1, ep.tokens, now)
    ep.tokens = ep.tokens - msgs
    local rest, rn = {}, 0
    for k = i, n do
      rn = rn + 1
      rest[rn] = sorted[k]
    end
    ep.sendQ = rest
  end
end

-- Issue a local order at the current sim tick. The input-delay contract in
-- one line: exec = clock + ORDER_DELAY, validated by the sim's own gate.
function Net.issue(ep, kind, target, count)
  local sim = ep.sim
  if not sim or sim.over then return false end
  local exec = sim.clock + ep.C.ORDER_DELAY
  if exec >= ep.matchTicks then return false end
  local seq = ep.outSeq + 1
  if seq > Wire.MAX_SEQ then error("Net: seq space exhausted") end
  local ok, err = sim:queueCommand({ side = ep.side, seq = seq, tick = exec,
                                    kind = kind, target = target, count = count,
                                    issueTick = sim.clock })
  if not ok then
    error("Net: the local sim refused a local order: " .. (err or "?"))
  end
  ep.outSeq = seq
  ep.outBuf[seq] = { exec = exec, kind = kind, target = target, count = count,
                     firstSent = -1, backstopped = false }
  ep.sendQ[#ep.sendQ + 1] = seq
  flushSend(ep, ep.t0 + sim.clock)
  return true
end

-- Sender-driven backstop (A.12 resend rule ii and iii): unacked after
-- BACKSTOP_AT heartbeats -> queue one resend; after BACKSTOP_STOP, stop --
-- the state hash (and the receiver's N) adjudicate from there.
local function backstop(ep, now)
  local hb = ep.C.HEARTBEAT_TICKS
  for seq = ep.peerAckThru + 1, ep.outSeq do
    local a = ep.outBuf[seq]
    if a and not a.backstopped and a.firstSent >= 0 then
      local age = now - a.firstSent
      if age >= BACKSTOP_AT * hb and age < BACKSTOP_STOP * hb then
        a.backstopped = true
        ep.st.backstopResends = ep.st.backstopResends + 1
        ep.repairQ[#ep.repairQ + 1] = seq
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- the clock
-- ---------------------------------------------------------------------------

-- Advance to harness tick `now`. The caller calls this once per tick per
-- endpoint, after delivering that tick's inbound messages.
function Net.step(ep, now)
  -- Offer our S on a cadence until the peer is PROVEN built (its first H or
  -- C), which is the one observable fact that implies it holds our S. This
  -- covers both directions of handshake loss with no reply rule to loop.
  if not ep.peerBuilt and now - ep.lastHello >= HELLO_EVERY then
    sendS(ep, now)
  end
  if not ep.sim then return end

  -- bucket refill
  while now - ep.lastRefill >= C_BUCKET_REFILL do
    ep.lastRefill = ep.lastRefill + C_BUCKET_REFILL
    if ep.tokens < C_BUCKET_CAP then ep.tokens = ep.tokens + 1 end
  end

  -- advance the sim to its harness-aligned clock (T0 skew: this endpoint's
  -- tick N happens at harness tick t0 + N). A sim un-finished by a rollback
  -- catches back up here, which is A.10's re-simulate-forward in miniature.
  local target = now - ep.t0
  if target > ep.matchTicks then target = ep.matchTicks end
  while not ep.sim.over and ep.sim.clock < target do
    if not tickOnce(ep) then break end
  end

  -- re-request recovery if the last Q (or its answer) was lost
  if ep.recovering and now >= ep.qCooldownUntil then
    maybeRequestRecovery(ep, now)
  end

  backstop(ep, now)
  flushSend(ep, now)
  flushReplay(ep, now)

  if now - ep.lastHb >= ep.C.HEARTBEAT_TICKS then
    sendH(ep, now)
  end
end

-- ---------------------------------------------------------------------------
-- read-only surface for the harness
-- ---------------------------------------------------------------------------

function Net.terminalHash(ep) return Hash.state(ep.sim) end
function Net.terminalDigest(ep) return Hash.log(ep.sim) end

-- True when this endpoint believes nothing about the match is outstanding.
function Net.settled(ep, peerEp)
  if not ep.sim or not ep.sim.over then return false end
  if ep.recovering then return false end
  if #ep.sendQ > 0 or #ep.repairQ > 0 or ep.replayHead <= #ep.replayQ then return false end
  if ep.inContig < peerEp.outSeq then return false end
  if ep.peerAckThru < ep.outSeq then return false end
  return true
end

-- True when this endpoint has nothing left in flight: everything it issued
-- is acked, everything the peer claims is held, no recovery is running and
-- no queued/repair/replay traffic remains. The addon's end-of-match settle
-- window (M5 review) reads endpoint health through this ONE surface instead
-- of reaching into the fields, so the bridge's only-the-harness-surfaces
-- rule survives the fix.
function Net.quiescent(ep)
  return ep.peerAckThru >= ep.outSeq
    and ep.inContig >= ep.peerLastSeq
    and not ep.recovering
    and #ep.sendQ == 0
    and #ep.repairQ == 0
    and ep.replayHead > #ep.replayQ
end

-- Registration tail (M5): hands this module to IB_SIM_MODULES when the addon
-- created it (WoW discards a chunk's return value); headless it does not
-- exist and nothing here runs. Full argument in sim/Hash.lua's tail.
local IB_REG = rawget(_G, "IB_SIM_MODULES")
if IB_REG then IB_REG.Net = M end

return M
