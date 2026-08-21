-- net/Transport.lua -- the fake lossy channel. M4.
--
-- Two endpoints in one process, joined by a channel that can DROP, DELAY,
-- REORDER and DUPLICATE messages on command. Part E's M4 milestone runs the
-- whole reliability shim over this before a single real message is sent, so
-- the one property this file must have above all others is REPRODUCIBILITY:
--
--   EVERY VERDICT IS A PURE FUNCTION OF THE TRANSPORT'S SEED AND THE SEND
--   SEQUENCE. No math.random (sim/Rand.lua only), no clock, no floats, no
--   pairs. "3 s of jitter" is UP TO 30 SIM TICKS of the harness clock, never
--   a wall-clock quantity. A failing M4 seed replays exactly.
--
-- Each direction (1->2, 2->1) draws from its OWN sim/Rand.lua stream, so the
-- verdicts one direction's traffic receives cannot depend on how the other
-- direction's sends interleave with it.
--
-- VERDICTS, drawn per message in send order:
--   drop     dropPct percent: the message vanishes. First copy only -- the
--            duplicate of a duplicated message is never dropped, so dup
--            always means "delivered at least twice", which is the case the
--            dedup logic has to survive.
--   delay    every delivered message: latMin..latMax ticks of transit
--            (defaults 1..30 -- the milestone's "up to 3 s of jitter").
--            Independent per-message delays already invert order routinely
--            (sent-at-10/delay-25 loses to sent-at-12/delay-3).
--   reorder  reorderPct percent: the transit is pushed a further 1..latMax
--            ticks PAST the jitter window, so anything sent within the next
--            window overtakes it -- a guaranteed inversion against the
--            following traffic, on top of the incidental ones. The harness
--            measures realised inversions and asserts they occurred, rather
--            than trusting this knob.
--   dup      dupPct percent: delivered twice, the second copy on its own
--            independent delay. Resends already produce natural duplicates;
--            this knob produces them without needing a resend to fire.
--
-- THE CHANNEL'S SHAPE IS ENFORCED, NOT ASSUMED: a message over 255 bytes is a
-- hard error at send() -- the addon channel would refuse it, so an M4 message
-- that big must never be CONSTRUCTED, and a test that silently truncated or
-- delivered it would be testing a channel that does not exist.
--
-- Delivery order at a tick: by (dueTick, global send index) -- the stable,
-- deterministic order a single-threaded event loop would produce.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rand = IB_SIM_MODULES and IB_SIM_MODULES.Rand or require("sim.Rand")

local M = {}

local Transport = {}
Transport.__index = Transport

M.HARD_LIMIT = 255

-- opts (all integers; every default is the milestone scenario):
--   dropPct     percent of messages dropped            (default 10)
--   latMin      minimum transit in ticks               (default 1)
--   latMax      maximum transit in ticks               (default 30)
--   reorderPct  percent pushed past the jitter window  (default 10)
--   dupPct      percent delivered twice                (default 0)
function M.new(seed, opts)
  opts = opts or {}
  local t = setmetatable({
    dropPct = opts.dropPct or 10,
    latMin = opts.latMin or 1,
    latMax = opts.latMax or 30,
    reorderPct = opts.reorderPct or 10,
    dupPct = opts.dupPct or 0,
    -- One verdict stream per direction, split off the one seed.
    rng = { Rand.new(seed * 2 + 1), Rand.new(seed * 2 + 2) },
    -- Per-destination in-flight queues, insertion-sorted by (due, idx).
    queue = { {}, {} },
    sendIdx = 0,
    now = 0,
    -- Instrumentation the gate reads. All integers, all deterministic.
    stat = {
      sent = 0, delivered = 0, dropped = 0, reordered = 0, duplicated = 0,
      bytes = 0, bytesMax = 0, inverted = 0,
      -- highest send index already delivered, per destination, to count
      -- realised inversions (a delivery whose send index is below one
      -- already delivered to the same endpoint).
      hiDelivered = { 0, 0 },
    },
  }, Transport)
  if t.latMin < 1 then t.latMin = 1 end
  if t.latMax < t.latMin then t.latMax = t.latMin end
  return t
end

local function enqueue(self, to, due, idx, msg)
  local q = self.queue[to]
  local n = #q
  local i = n
  while i >= 1 do
    local o = q[i]
    if o.due < due or (o.due == due and o.idx < idx) then break end
    q[i + 1] = o
    i = i - 1
  end
  q[i + 1] = { due = due, idx = idx, msg = msg }
end

-- Send `msg` from endpoint `from` (1 or 2). The verdict is drawn NOW, in send
-- order, from the sending direction's own stream -- so a run's entire fate is
-- (seed, send sequence) and nothing else.
function Transport.send(self, from, msg)
  if type(msg) ~= "string" then
    error("Transport: message must be a string")
  end
  if #msg > M.HARD_LIMIT then
    -- The real channel's hard limit. This is deliberately an ERROR and not a
    -- drop: a message this big must never be constructed, and a transport
    -- that quietly ate it would hide the bug the limit exists to catch.
    error("Transport: message over the 255-byte hard limit")
  end
  local to = 3 - from
  local r = self.rng[from]
  local st = self.stat
  st.sent = st.sent + 1
  st.bytes = st.bytes + #msg
  if #msg > st.bytesMax then st.bytesMax = #msg end
  self.sendIdx = self.sendIdx + 1
  local idx = self.sendIdx

  if Rand.range(r, 1, 100) <= self.dropPct then
    st.dropped = st.dropped + 1
    return false
  end
  local lat = Rand.range(r, self.latMin, self.latMax)
  if Rand.range(r, 1, 100) <= self.reorderPct then
    lat = lat + Rand.range(r, 1, self.latMax)
    st.reordered = st.reordered + 1
  end
  enqueue(self, to, self.now + lat, idx, msg)
  if self.dupPct > 0 and Rand.range(r, 1, 100) <= self.dupPct then
    st.duplicated = st.duplicated + 1
    self.sendIdx = self.sendIdx + 1
    enqueue(self, to, self.now + Rand.range(r, self.latMin, self.latMax), self.sendIdx, msg)
  end
  return true
end

-- Advance the channel clock to `now` and return every message due for
-- endpoint `to` at or before it, oldest first. The caller drives the clock;
-- the transport never reads one (determinism rule 4).
function Transport.deliver(self, to, now)
  self.now = now
  local q = self.queue[to]
  local out, n = {}, 0
  while q[1] ~= nil and q[1].due <= now do
    local e = q[1]
    -- shift-down pop; queues are short (tens of messages in flight)
    local qn = #q
    for i = 1, qn - 1 do q[i] = q[i + 1] end
    q[qn] = nil
    n = n + 1
    out[n] = e.msg
    local st = self.stat
    st.delivered = st.delivered + 1
    if e.idx < st.hiDelivered[to] then
      st.inverted = st.inverted + 1   -- realised out-of-order delivery
    elseif e.idx > st.hiDelivered[to] then
      st.hiDelivered[to] = e.idx
    end
  end
  return out
end

-- True when nothing is in flight in either direction.
function Transport.idle(self)
  return self.queue[1][1] == nil and self.queue[2][1] == nil
end

return M
