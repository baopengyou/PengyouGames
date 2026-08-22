-- Games/IdleBattle.lua - Idle Battle mounted in the DEV addon. M5 PART 1:
-- matchmaking through the shipped session system, the real-channel comm
-- bridge onto net/Net.lua, the OnUpdate tick driver, the in-game determinism
-- selftest, and a STUB match surface. The real board UI is M5 part 2 and
-- replaces exactly the window section at the bottom of this file.
--
-- WHAT THIS FILE IS. The addon-side half of dev/idlebattle/: the headless
-- engine (byte-identical copies under IdleBattle\, synced and checked by
-- dev/idlebattle/tools/syncaddon.sh) supplies the sim, the A.11 codec and the
-- A.12 reliability shim; this file supplies everything the engine was built
-- NOT to contain -- WoW frames, the Comm channel, session identity, consent.
-- Nothing here reaches into engine internals beyond the surfaces the M4
-- harness itself uses (Net.new / issue / step / onWire, Wire encode/decode,
-- Sim.new / queueCommand / tick, Hash.state / Hash.log).
--
-- THE COMM BRIDGE (A.11 family -> addon send path). net/Wire.lua encodes a
-- complete envelope "4|IB|<mtype>|<wireToken>|<payload>"; the addon channel
-- already has its own envelope (Comm.lua's WIRE_VERSION.."|IB|..") -- so the
-- bridge DECOMPOSES the engine string and ships mtype + payload as the
-- addon's own fields, with the SESSION token (CONCURRENCY.md 3.2) in the
-- envelope's token slot. On receipt it re-frames the payload with Wire's own
-- version and the match's seed-derived wire token before handing it to
-- Net.onWire. Consequences, all deliberate:
--   * the on-wire bytes are ONE envelope, exactly A.11's shape, and the
--     addon-wide WIRE_VERSION is never bumped for this game (the A.11 ruling;
--     the game's own layout version is IBPROTO inside S);
--   * cross-match separation is the registry's (host, sessionToken) pair plus
--     the server-vouched sender -- strictly stronger than the 6-byte wire
--     token, which never travels and can never mismatch on re-frame;
--   * every payload is pipe-free by Wire's own alphabet, so it rides one
--     Comm field; the largest message is a C batch of 8 = 56 payload bytes
--     inside a ~75-byte addon message, far under the 200-byte discipline.
-- Send paths: S C H N M -> party-scope BROADCAST (one route, server-vouched
-- distribution, bystanders drop at the registry in one lookup; deviation from
-- A.11.1's "S whispered" recorded in the README -- party scope shares all
-- state under Ruling 1, so there is nothing to hide from the party). Q (the
-- full-log REQUEST) -> WHISPER to the peer: it concerns exactly one client,
-- like the shipped resync's SYNCQ. The ANSWER stream (fresh S + H + paced C
-- batches) is made of ordinary S/H/C rows and rides the broadcast path by
-- family rule -- the bridge routes by mtype and holds no per-message context,
-- and in a 1v1 every in-match row has exactly one consumer either way.
-- OPEN/JOIN/BEGIN/CANCEL/NO are ADDON rows (pre-sim lifecycle, the shipped
-- games' shapes); V is the one Wire row the ADDON acts on (Net defers it to
-- M6 by design), because M5's answer to every mid-match interruption is VOID.
--
-- THE REAL-BUDGET RESOLUTION (M4 review flag: repair "4 per flush" vs
-- A.11.4). Net already meters NEW commands through A.11.4's module bucket
-- (capacity 4, refill 1 per 4 s = the 15/min worst row). Repair traffic
-- bypasses that bucket capped at 4 messages per flush, which against the FAKE
-- channel could burst; against the REAL channel it is bounded by two facts
-- the shim lacked: (1) Comm.lua's shared bucket (capacity 10, refill 1/s)
-- QUEUES overflow instead of refusing it, so an instantaneous repair burst
-- drains at 1/s and never trips the server throttle; (2) transit loss does
-- not exist on the addon channel -- messages die only at SEND time (throttle
-- entries are requeued by Comm itself; lockdown/audience drops void the match
-- below) -- so the repair path is idle in every healthy match. Steady state
-- per side is H 10/min + C <= 15/min ~ 0.42/s, inside the 1/s refill with
-- more than half left for the other games. The one transient exception is a
-- Q recovery (~20 messages paced by Net at 10 per 10 s): it saturates the
-- refill for ~20 s and other modules' traffic queues behind it by a few
-- seconds -- accepted, rare, bounded, and CONCURRENCY.md 9.9 places shared-
-- bucket capacity work outside game modules. No second bridge-side bucket.
--
-- VOID ON LOCKDOWN (M5 rule; M6 replaces this with halt/resume X/K/G). There
-- is deliberately NO halt path here. The match VOIDS cleanly on both sides:
--   * our own trigger: encounter start / addon restriction (PG.Safety), the
--     comms lockdown observed by the driver, or any queued IB message dropped
--     (onDrop: lockdown, vanished audience, failed send) -> void locally and
--     best-effort a V row (which may itself be dropped -- harmless);
--   * the peer's trigger: their V row, or 35 s of silence (H arrives every
--     6 s, so a locked peer goes quiet) -> void locally.
-- Both sides converge on "done" with no ledger effect (IB never touches the
-- ledger). M6 mounts X/K/G on the same bridge and deletes the void triggers.
--
-- CONCURRENCY: a full session registry in the shipped shape -- lite records
-- for overheard OPENs, one involved record, recent-token poisoning,
-- supersession, the single round-based seat (an IB match takes your one
-- seat). One deliberate deviation, recorded in dev/idlebattle/README.md: an
-- IB host must be SEATED (refuses to open while seated elsewhere), because a
-- 1v1 match has no referee role for I5 to fall back on.
local ADDON, PG = ...

PG.IB = {}

-- D.1: the first playable is PARTY SCOPE ONLY. The picker renders Guild and
-- Public disabled with the reason below (SCOPE.md 1.3: never hidden).
PG.IB.SCOPES = { group = true, guild = false, public = false }
-- An Idle Battle takes the single round-based seat (CONCURRENCY.md 1.1: it
-- demands timed human decisions for ten minutes).
PG.IB.SEAT = true

local TICK_SECS = 0.5        -- module ticker (sweeps, deadlines, stub repaint)
local SIM_TICK = 0.1         -- one sim tick per 100 ms (Rules.C.SIM_TICK_MS)
local JOIN_SECS = 45         -- join window (fixed in the M5 stub dialog)
local HANDSHAKE_SECS = 30    -- the S offer cadence is 6 s (Net's HELLO_EVERY),
                             -- so this covers five attempts: enough that a
                             -- couple of silently eaten sends cannot kill a
                             -- viable handshake, short enough that a peer who
                             -- vanished mid-join fails the table fast
local HB_TIMEOUT = 35        -- group scope liveness (H every 6 s), the LG/RPS number
local MAX_CATCHUP = 2000     -- driver: max ticks advanced per frame (loading-
                             -- screen catch-up; ~200 s of stall, a few ms of CPU)

-- Registry budgets, the CONCURRENCY.md 2.1 constants verbatim.
local MAX_LITE = 8
local MAX_RECENT = 16
local RECENT_TTL = 120
local DONE_TTL = 60
local LITE_TTL_PAD = 10
local LITE_TTL_MIN = 15
local LITE_TTL_MAX = 180
local SWEEP_EVERY = 4
local BUSY_THROTTLE = 60

-- Engine handles, resolved at init from PG.IBEngine (IdleBattle\Loader.lua).
local Rules, SimM, Hash, Wire, NetM, HandLog

local sessions = {}   -- [key] = record, key = host .. "|" .. token
local mine            -- key of the ONE full record, or nil
local recent = {}
local recentQ = {}
local regCount = 0
local liteCount = 0
local sweepTicks = 0

local ticker
local driver          -- the OnUpdate frame; created once, shown only mid-match
local win, dialog, dlgScope
local ui = {}
local busyToastAt = 0
local overflowToastAt = 0

local RefreshUI, ShowWindow, onTick, hostOpen, evict, endSession, voidMatch
local ensureDriver

local function keyOf(host, token) return host .. "|" .. token end
local function mySession() return mine and sessions[mine] or nil end
local function myName() return PG.FullName("player") end

local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

local function engineOK()
  return Rules ~= nil and SimM ~= nil and Hash ~= nil and Wire ~= nil
    and NetM ~= nil and HandLog ~= nil
end

local function num(v, lo, hi)
  local n = PG.SafeNum(v)
  if not n then return nil end
  n = math.floor(n)
  if lo and n < lo then return nil end
  if hi and n > hi then return nil end
  return n
end

local function toast(text, host, opts)
  local name = "Idle Battle"
  if host and regCount > 1 then name = name .. " (" .. shortOf(host) .. ")" end
  PG.UI.Toast(name .. ": " .. text, opts)
end

local function live()
  local S = mySession()
  return S ~= nil and S.phase ~= "done"
end

-------------------------------------------------------------------------------
-- Registry primitives (CONCURRENCY.md 2.1/4.5), the RPS idioms verbatim.
-------------------------------------------------------------------------------

local function validToken(v)
  local t = PG.SafeStr(v)
  if not t or t == "" or #t > 24 then return nil end
  if t:find("|", 1, true) then return nil end
  return t
end

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function b36(n)
  n = math.floor(PG.SafeNum(n) or 0)
  if n <= 0 then return "0" end
  local out = ""
  while n > 0 do
    local d = n % 36
    out = B36:sub(d + 1, d + 1) .. out
    n = math.floor(n / 36)
  end
  return out
end

local function nextToken()
  if type(PG.NextToken) == "function" then
    local ok, t = pcall(PG.NextToken)
    if ok then
      t = validToken(t)
      if t then return t end
    end
  end
  local p = PG.db and PG.db.profile
  local seq = 1
  if p then
    seq = (PG.SafeNum(p.seq) or 0) + 1
    p.seq = seq
  end
  return b36(seq) .. "-" .. b36(math.random(0, 46655))
end

local function poison(key)
  if recent[key] then return end
  recent[key] = GetTime()
  recentQ[#recentQ + 1] = key
  while #recentQ > MAX_RECENT do
    local old = table.remove(recentQ, 1)
    if old ~= key then recent[old] = nil end
  end
end

local function isRecent(key)
  local t = recent[key]
  if not t then return false end
  if (GetTime() - t) < RECENT_TTL then return true end
  recent[key] = nil
  return false
end

local function listOpen(rec)
  rec.listed = true
  if PG.Launcher and PG.Launcher.AddOpenGame then
    pcall(PG.Launcher.AddOpenGame, {
      game = "IB", host = rec.host, token = rec.token, scope = rec.scope,
      expires = rec.expires, key = rec.key,
    })
  end
end

local function unlistOpen(rec)
  if not rec.listed then return end
  rec.listed = false
  if PG.Launcher and PG.Launcher.RemoveOpenGame then
    pcall(PG.Launcher.RemoveOpenGame, "IB", rec.host, rec.token)
  end
end

local function startTicker()
  if ticker then return end
  ticker = PG.Ticker(TICK_SECS, function()
    local ok, err = pcall(onTick)
    if not ok then geterrorhandler()(err) end
  end)
end

local function stopTicker()
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
end

local function syncTicker()
  if regCount > 0 then startTicker() else stopTicker() end
end

local function register(rec)
  sessions[rec.key] = rec
  regCount = regCount + 1
  if rec.kind == "lite" then liteCount = liteCount + 1 end
  syncTicker()
end

evict = function(key, keepWindow)
  local rec = sessions[key]
  if not rec then return end
  sessions[key] = nil
  regCount = regCount - 1
  if rec.kind == "lite" then liteCount = liteCount - 1 end
  PG.UI.Dismiss(rec.askKey)
  rec.askKey = nil
  unlistOpen(rec)
  if mine == key then
    mine = nil
    PG.Session.Release("IB", rec.token)
    if driver then driver:Hide() end
    if win and not keepWindow then win:Hide() end
  end
  poison(key)
  syncTicker()
end

-- Teardown (CONCURRENCY.md 7.1): the instant phase becomes "done" the seat is
-- released, the invitation comes down, the launcher row goes, the driver
-- stops. The record lingers DONE_TTL so the stub window can show the verdict.
endSession = function(text)
  local S = mySession()
  if not S or S.phase == "done" then return end
  S.phase = "done"
  S.endText = text
  S.doneAt = GetTime()
  PG.Session.Release("IB", S.token)
  PG.UI.Dismiss(S.askKey)
  S.askKey = nil
  unlistOpen(S)
  if driver then driver:Hide() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- The comm bridge: engine wire string <-> addon envelope.
-------------------------------------------------------------------------------

-- "4|IB|<mtype>|<wtoken>|<payload>" -> mtype, payload. The engine guarantees
-- the payload alphabet excludes "|", so this split is exact.
local function decompose(s)
  if type(s) ~= "string" then return nil end
  local _, mod, mtype, _, payload = strsplit("|", s)
  if mod ~= "IB" or type(mtype) ~= "string" or #mtype ~= 1 then return nil end
  return mtype, payload or ""
end

-- Re-frame an addon-delivered payload for Wire.decode/Net.onWire. wtoken is
-- the match's seed-derived Wire token (rec.ep.token) -- or the placeholder
-- when decoding a first S, whose seed we do not know yet.
local function reframe(mtype, wtoken, payload)
  return Wire.WIRE_VERSION .. "|IB|" .. mtype .. "|" .. (wtoken or "00-000")
    .. "|" .. (payload or "")
end

-- Outbound routing for everything net/Net.lua emits. Family map per the
-- header: Q -> whisper to the peer; S C H N M -> party broadcast. A refused
-- send (audience gone, lockdown at submit) is terminal for M5: void.
local function outSend(rec, s)
  local mtype, payload = decompose(s)
  if not mtype then return end
  local ok
  if mtype == "Q" then
    ok = PG.Comm.Whisper(rec.opp, "IB", mtype, rec.token, payload)
  else
    ok = PG.Comm.Broadcast(rec.scope, "IB", mtype, rec.token, payload)
  end
  if not ok and rec.phase ~= "done" then
    voidMatch("Voided - could not reach your opponent (messages blocked).", false)
  end
end

-- Best-effort V (A.11.3's terminal row; reason letter from Wire's own set).
-- Under an active lockdown the send is dropped -- fine, the peer voids on its
-- own trigger or on the 35 s silence.
local function sendVoid(rec)
  if not (rec and rec.ep and rec.ep.sim) then return end
  local ok, s = pcall(Wire.encodeV, rec.ep.token, {
    tick = rec.ep.sim.clock, ackThru = rec.ep.inContig, reason = "V",
  })
  if ok and s then
    local mtype, payload = decompose(s)
    if mtype then PG.Comm.Broadcast(rec.scope, "IB", mtype, rec.token, payload) end
  end
end

voidMatch = function(text, withV)
  local S = mySession()
  if not S or S.phase == "done" then return end
  if withV then sendVoid(S) end
  toast(text, S.host)
  endSession(text)
end

-------------------------------------------------------------------------------
-- The tick driver: an OnUpdate accumulator advancing the endpoint on the
-- 100 ms grid from its own locally-anchored T0 (A.11.1: T0 is set the moment
-- both loadouts are held -- inside Net.buildSim -- so the two clients' clocks
-- are offset by one-way latency and nothing corrects for it; atoms and hashes
-- live in shared sim-tick time). The frame is module-global, parent-less and
-- NEVER registered with PG.Safety: raid-safety hides UI, not state, so the
-- sim keeps advancing while the window is hidden. (M5 voids on lockdown
-- anyway; M6's halt/resume will stop the clock through X/K/G instead.)
-------------------------------------------------------------------------------

local function nowTick(rec)
  return math.floor((GetTime() - rec.wall0) * 10)
end

local function finishMatch(rec)
  local sim = rec.ep and rec.ep.sim
  if not sim then return end
  local mySide = rec.isHost and 1 or 2
  local text
  if sim.winner == 0 then
    text = "Draw (" .. tostring(sim.reason) .. ")."
  elseif sim.winner == mySide then
    text = "You WIN (" .. tostring(sim.reason) .. ")."
  else
    text = "You lose (" .. tostring(sim.reason) .. ")."
  end
  toast(text, rec.host, { priority = "result" })
  endSession("Final: " .. text)
end

local function onDriverUpdate()
  local S = mySession()
  if not S or S.phase == "done" or not S.ep then
    if driver then driver:Hide() end
    return
  end
  -- M5's lockdown rule, polled at the source: the instant sends are refused,
  -- the match cannot continue and voids (M6 halts here instead).
  if PG.Comm.Locked() then
    voidMatch("Voided - addon messages are locked down. (M6 will pause instead.)", false)
    return
  end
  local now = nowTick(S)
  if S.lastStep and now <= S.lastStep then return end
  -- Bound a catch-up after a long OnUpdate stall (loading screen): the sim
  -- advances MAX_CATCHUP ticks per frame at most and finishes catching up
  -- over the next frames.
  if S.lastStep and (now - S.lastStep) > MAX_CATCHUP then
    now = S.lastStep + MAX_CATCHUP
  end
  S.lastStep = now
  local ok, err = pcall(S.ep.step, S.ep, now)
  if not ok then
    geterrorhandler()(err)
    voidMatch("Voided - internal engine error (see error frame).", true)
    return
  end
  local sim = S.ep.sim
  if sim and sim.over then finishMatch(S) end
end

ensureDriver = function()
  if driver then return driver end
  driver = CreateFrame("Frame")
  driver:Hide()
  driver:SetScript("OnUpdate", onDriverUpdate)
  return driver
end

local function startDriver(rec)
  rec.wall0 = rec.wall0 or GetTime()
  rec.lastStep = nil
  ensureDriver()
  driver:Show()
end

-------------------------------------------------------------------------------
-- Handshake helpers (A.11.1). The endpoint owns the S cadence; the addon owns
-- the WORDING of the two refusal classes (A.11.1: two fields, two failure
-- modes, two distinct strings -- the G.4 pattern).
-------------------------------------------------------------------------------

local function buildEndpoint(rec, side, seed, matchTicks)
  rec.seed = seed
  rec.matchTicks = matchTicks
  rec.ep = NetM.new{
    rules = Rules, side = side, seed = seed, matchTicks = matchTicks,
    loadout = nil,   -- D.1: ZERO modifiers -- the field ships, empty (A.11.1)
    send = function(s) outSend(rec, s) end,
  }
  rec.mySide = side
  startDriver(rec)
end

-- Decode an S payload without an endpoint (the client's first look, before
-- the seed is known): re-frame with the placeholder token. Wire.decode never
-- raises on wire input.
local function peekS(payload)
  local m = Wire.decode(reframe("S", nil, payload))
  if not m or m.mtype ~= "S" then return nil end
  return m
end

-- The two refusal strings. Distinct on purpose: a player who sees the second
-- knows exactly what to do (G.4 mitigation 2).
local function refuseS(rec, m)
  if m.proto ~= Wire.PROTO then
    PG.Comm.Whisper(rec.opp, "IB", "NO", rec.token, "proto")
    return "Different Idle Battle protocol version - both players need the same dev build."
  end
  if m.rulesHash ~= Rules.rulesHash then
    PG.Comm.Whisper(rec.opp, "IB", "NO", rec.token, "rules")
    return "Your opponent is on a different balance patch - everyone needs the same ruleset (yours "
      .. tostring(Rules.rulesHash36) .. ")."
  end
  if not num(m.matchTicks, 600, Wire.MAX_TICK) then
    PG.Comm.Whisper(rec.opp, "IB", "NO", rec.token, "proto")
    return "Malformed handshake."
  end
  return nil
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

-- I3 in the shipped wording; plus the one recorded IB deviation from I4/I5
-- (see the header): a 1v1 host is always a combatant, so hosting requires the
-- seat and refuses -- with the reason -- when another module holds it.
local function involvement()
  local S = mySession()
  if S and S.phase ~= "done" then
    if S.isHost then
      return "you're already running an Idle Battle. Cancel it first.", false
    end
    return "you're already in " .. shortOf(S.host) .. "'s battle - finish it first.", false
  end
  local seat = PG.Session.Seat()
  if seat and seat.module ~= "IB" then
    return "you're playing " .. shortOf(seat.host)
      .. "'s game - an Idle Battle host plays in their own match, so finish that first.", false
  end
  return nil, true
end

hostOpen = function(scope)
  if not engineOK() then
    toast("engine not loaded (see IdleBattle\\Loader.lua).")
    return
  end
  local note, canStart = involvement()
  if not canStart then
    toast(note)
    return
  end
  local host = myName()
  if not host then return end
  scope = PG.SafeStr(scope) or "group"
  if not PG.IB.SCOPES[scope] then return end
  local okScope, why = PG.Comm.ScopeAvailable(scope)
  if not okScope then
    toast(why or "that audience isn't available.")
    if dlgScope and dialog and dialog:IsShown() then pcall(dlgScope.Refresh, dlgScope) end
    return
  end
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  local token = nextToken()
  local matchTicks = Rules.C.MATCH_TICKS
  -- OPEN before any record exists: a submit-time lockdown drop fires onDrop
  -- with a token no record owns, which is ignored there (the RPS ordering).
  if not PG.Comm.Broadcast(scope, "IB", "OPEN", token, JOIN_SECS, matchTicks, code) then
    toast("cannot start right now (addon messages are blocked).")
    return
  end
  local prev = mySession()
  if prev then evict(prev.key, true) end   -- superseding our own finished match
  local seated = PG.Session.ClaimHost("IB", token, host)
  if not seated then
    -- involvement() checked the seat before the broadcast; losing it in
    -- between is a same-frame race that cannot happen, but fail closed.
    toast("could not take the seat - not starting.")
    return
  end
  local key = keyOf(host, token)
  local rec = {
    kind = "full",
    key = key, token = token, host = host, scope = scope,
    isHost = true, seated = true,
    phase = "join",
    joinSecs = JOIN_SECS,
    matchTicks = matchTicks,
    -- the reserved A.11.1 seed field: minted here, carried in S, consumed by
    -- no shipped system (Q5) -- but the wire token and any future card draw
    -- derive from it, so it is real plumbing.
    seed = math.random(0, Wire.MAX_SEED),
    opp = nil, ep = nil,
    joinDeadline = GetTime() + JOIN_SECS,
    lastRecv = GetTime(),
  }
  register(rec)
  mine = key
  ShowWindow()
  RefreshUI()
end

-- First JOIN wins the seat opposite the host; everyone later is told so.
local function hostOnJoin(rec, sender)
  if rec.phase ~= "join" then
    PG.Comm.Whisper(sender, "IB", "NO", rec.token, "full")
    return
  end
  rec.opp = sender
  rec.phase = "handshake"
  rec.handshakeDeadline = GetTime() + HANDSHAKE_SECS
  -- BEGIN: bystander lite records die on it (CONCURRENCY.md 7.3) and their
  -- invitations come down; the field names the one who got the seat.
  PG.Comm.Broadcast(rec.scope, "IB", "BEGIN", rec.token, sender)
  -- a submit-time lockdown drop of BEGIN runs onDrop synchronously and may
  -- have just ended this session; do not build an endpoint on a dead record
  if rec.phase ~= "handshake" then return end
  buildEndpoint(rec, 1, rec.seed, rec.matchTicks)
  -- the endpoint's own cadence sends S (and re-sends it on loss) from the
  -- first driver step; nothing more to do here.
  toast(shortOf(sender) .. " joined - handshaking.", rec.host)
  RefreshUI()
end

local function hostOnNo(rec, sender, reason)
  if sender ~= rec.opp then return end
  reason = PG.SafeStr(reason) or "?"
  local why
  if reason == "rules" then
    why = shortOf(sender) .. " is on a different balance patch - everyone needs the same ruleset."
  elseif reason == "proto" then
    why = shortOf(sender) .. " runs a different Idle Battle protocol version."
  else
    why = shortOf(sender) .. " could not join."
  end
  toast(why, rec.host)
  -- back to the join window; the deadline still applies and may cancel.
  rec.opp = nil
  rec.ep = nil
  rec.phase = "join"
  if driver then driver:Hide() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

-- The full-record constructor (I7): reachable from the invitation's Accept
-- and the launcher's Join, and nowhere else.
local function clientAccept(rec)
  if not engineOK() then
    toast("engine not loaded.")
    return false
  end
  if not rec or rec.kind ~= "lite" or sessions[rec.key] ~= rec then return false end
  local cur = mySession()
  if cur and cur.phase == "done" then
    evict(cur.key, true)
    cur = nil
  end
  if cur then
    toast("you're already in " .. (cur.isHost and "your own battle"
      or (shortOf(cur.host) .. "'s battle")) .. " - finish it first.", rec.host)
    return false
  end
  if not PG.Session.Claim("IB", rec.token, rec.host) then
    toast("you just joined another game - not joining this one.", rec.host)
    return false
  end
  local cfg = rec.cfg
  PG.UI.Dismiss(rec.askKey)
  unlistOpen(rec)
  sessions[rec.key] = nil
  regCount = regCount - 1
  liteCount = liteCount - 1
  local S = {
    kind = "full",
    key = rec.key, token = rec.token, host = rec.host, scope = rec.scope,
    isHost = false, seated = true,
    phase = "handshake",
    joinSecs = cfg.joinSecs,
    matchTicks = cfg.matchTicks,
    opp = rec.host,       -- the peer is the host, from the first moment
    ep = nil,
    handshakeDeadline = GetTime() + HANDSHAKE_SECS,
    lastRecv = GetTime(),
  }
  register(S)
  mine = S.key
  PG.Comm.Whisper(S.host, "IB", "JOIN", S.token)
  ShowWindow()
  RefreshUI()
  return true
end

function PG.IB.JoinOpen(key)
  return clientAccept(sessions[tostring(key or "")])
end

function PG.IB.OpenGames()
  local out = {}
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      out[#out + 1] = { key = rec.key, host = rec.host, token = rec.token,
                        scope = rec.scope, expires = rec.expires, game = "IB" }
    end
  end
  return out
end

-- The peer's S: on the client's FIRST one, the refusal gate and endpoint
-- construction; afterwards (repeats, the Q answer's fresh S) it flows into
-- the endpoint like every other row.
local function onWireS(rec, payload)
  if rec.ep then
    rec.ep:onWire(reframe("S", rec.ep.token, payload), nowTick(rec))
    if rec.phase == "handshake" and rec.ep.sim then
      rec.phase = "play"
      toast("battle begins against " .. shortOf(rec.opp) .. ".", rec.host)
      RefreshUI()
    end
    return
  end
  -- client, first S
  local m = peekS(payload)
  if not m then return end
  local why = refuseS(rec, m)
  if why then
    toast(why, rec.host)
    endSession(why)
    return
  end
  buildEndpoint(rec, 2, m.seed, m.matchTicks)
  -- feed the same S through the endpoint: peer loadout lands, the sim is
  -- built, and T0 anchors locally (A.11.1)
  rec.ep:onWire(reframe("S", rec.ep.token, payload), nowTick(rec))
  if rec.ep.sim then
    rec.phase = "play"
    toast("battle begins against " .. shortOf(rec.opp) .. ".", rec.host)
  end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Inbound OPEN: the CONCURRENCY.md 4.2 decision table.
-------------------------------------------------------------------------------

local function supersede(rec)
  if rec.kind == "lite" then
    evict(rec.key)
  elseif rec.phase == "done" then
    evict(rec.key, true)
  elseif mine == rec.key then
    toast("the host started a new battle - your previous one is over.", rec.host)
    endSession("The host started a new battle.")
    evict(rec.key)
  else
    evict(rec.key)
  end
end

local function raiseInvite(rec)
  local remain = math.max(1, rec.expires - GetTime())
  local busy = PG.Session.IsSeated()
  if busy then
    -- CONCURRENCY.md 6.2: no popup you cannot accept; row + one throttled
    -- group-scope toast per minute however many arrive.
    local now = GetTime()
    if now - busyToastAt >= BUSY_THROTTLE then
      busyToastAt = now
      toast(shortOf(rec.host) .. " opened a battle - you're in another game right now."
        .. " It's in the Pengyou Games window.", rec.host)
    end
    return
  end
  if PG.UI.AskCount and PG.UI.AskCount() >= 3 then
    local now = GetTime()
    if now - overflowToastAt >= BUSY_THROTTLE then
      overflowToastAt = now
      toast("more games are open - see the Pengyou Games window.")
    end
    return
  end
  rec.askKey = "IB:" .. rec.key
  PG.UI.Ask(rec.askKey,
    shortOf(rec.host) .. " opened an IDLE BATTLE (dev) - a 1v1, first to join plays. Join?",
    "Join", "Pass", remain,
    function()
      local r = sessions[rec.key]
      if r then clientAccept(r) end
    end,
    function()
      local r = sessions[rec.key]
      if r then r.askKey = nil end
    end)
end

local function onOpen(token, sender, scope, f1, f2, f3)
  if not engineOK() then return end
  -- IB plays to the party only (D.1); a wider delivery is not an audience
  -- this game accepts, whatever the declared byte says.
  if scope ~= "group" then return end
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f3))
  if declared ~= scope then return end                    -- row 2
  local joinSecs = num(f1, 5, 300)
  local matchTicks = num(f2, 600, Wire.MAX_TICK)
  if not joinSecs or not matchTicks then return end       -- row 2
  local key = keyOf(sender, token)
  if isRecent(key) then return end                        -- row 3
  local existing = sessions[key]
  if existing then                                        -- row 4: idempotent
    if existing.kind == "lite" then
      existing.expires = GetTime() + math.min(LITE_TTL_MAX,
        math.max(LITE_TTL_MIN, joinSecs + LITE_TTL_PAD))
    end
    return
  end
  for k, rec in pairs(sessions) do                        -- row 5: supersession
    if rec.host == sender and rec.token ~= token then supersede(rec) end
  end
  if liteCount >= MAX_LITE then                           -- row 6
    local oldest, oldestAt
    for k, rec in pairs(sessions) do
      if rec.kind == "lite" and not rec.askKey then
        if not oldestAt or rec.openedAt < oldestAt then oldest, oldestAt = k, rec.openedAt end
      end
    end
    if oldest then evict(oldest) else return end
  end
  local rec = {                                           -- row 7
    kind = "lite",
    key = key, token = token, host = sender, scope = scope,
    cfg = { joinSecs = joinSecs, matchTicks = matchTicks },
    openedAt = GetTime(),
    expires = GetTime() + math.min(LITE_TTL_MAX, math.max(LITE_TTL_MIN, joinSecs + LITE_TTL_PAD)),
  }
  register(rec)
  listOpen(rec)
  raiseInvite(rec)
end

-------------------------------------------------------------------------------
-- The router (CONCURRENCY.md 5.2 gates f..l, IB's shape).
-------------------------------------------------------------------------------

-- Wire rows the endpoint consumes, plus V which the ADDON consumes (M5 voids;
-- Net defers X/K/G/V to M6 by design and X/K/G are ignored here entirely).
local WIRE_BROADCAST = { S = true, C = true, H = true, N = true, M = true }

local function onComm(mtype, token, sender, scope, f1, f2, f3)
  token = validToken(token)
  if not token then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3) end

  -- Gate f FIRST (CONCURRENCY.md 5.2): the whispered rows resolve against
  -- the involved record only, never through a (sender, token) lookup --
  -- tokens are only host-unique, so the sender's own hosted session could
  -- legitimately share the token string.
  if mtype == "JOIN" or mtype == "NO" then
    local S = mySession()
    if not S or S.phase == "done" then return end
    if S.token ~= token or scope ~= "private" then return end
    if S.isHost then
      if mtype == "JOIN" then hostOnJoin(S, sender) else hostOnNo(S, sender, f1) end
    elseif mtype == "NO" and sender == S.host and PG.SafeStr(f1) == "full" then
      -- the host's refusal to a joiner who lost the race (the BEGIN broadcast
      -- usually says it first; this is the belt for a lost BEGIN)
      toast("someone else joined first.", S.host)
      endSession("Someone else joined first.")
    end
    return
  end

  local key = keyOf(sender, token)

  -- lite records: a BEGIN or CANCEL for an overheard session evicts it (its
  -- invitation dies with it); nothing else reaches them (gate h).
  local lite = sessions[key]
  if lite and lite.kind == "lite" then
    if mtype == "BEGIN" or mtype == "CANCEL" then evict(key) end
    return
  end

  local S = mySession()
  if not S or S.phase == "done" then return end
  if S.token ~= token then return end                      -- gate g

  -- host-authored addon rows
  if mtype == "BEGIN" then
    -- our own full record: as a client mid-handshake, BEGIN naming somebody
    -- else means the host paired before our JOIN landed.
    if not S.isHost and sender == S.host and S.phase == "handshake" then
      local who = PG.SafeStr(f1)
      if who and who ~= myName() then
        toast(shortOf(who) .. " joined first.", S.host)
        endSession("Someone else joined first.")
      end
    end
    return
  end
  if mtype == "CANCEL" then
    if not S.isHost and sender == S.host then
      toast("the host cancelled the battle.", S.host)
      endSession("The host cancelled the battle.")
    end
    return
  end

  -- in-match wire rows: from the one peer, on the session's own scope (gate
  -- i; Q arrives as a whisper, everything else on the party distribution).
  if sender ~= S.opp then return end
  if mtype == "Q" then
    if scope ~= "private" then return end
  elseif WIRE_BROADCAST[mtype] or mtype == "V" then
    if scope ~= S.scope then return end
  else
    return                                                -- gate f: unknown
  end
  if S.phase ~= "handshake" and S.phase ~= "play" then return end
  S.lastRecv = GetTime()

  local payload = PG.SafeStr(f1) or ""
  if mtype == "V" then
    -- the peer's terminal row: whatever the reason letter, M5's answer is the
    -- same. Validate the frame (never trust a raw field), then void locally.
    local wt = S.ep and S.ep.token or nil
    local m = Wire.decode(reframe("V", wt, payload))
    if m or not S.ep then
      toast("your opponent's match ended - voided. No result.", S.host)
      endSession("Voided by your opponent.")
    end
    return
  end
  if mtype == "S" then
    onWireS(S, payload)
    return
  end
  if not S.ep then return end   -- C/H outrunning the first S: the resend
                                -- machinery re-delivers, nothing to park here
  S.ep:onWire(reframe(mtype, S.ep.token, payload), nowTick(S))
  if S.phase == "handshake" and S.ep.sim then
    -- any H or C implies the peer built (Net tracks this too); the host's
    -- sim exists once the echoed S landed, so this is the host-side flip
    S.phase = "play"
    RefreshUI()
  end
end

-- A dropped outgoing message is permanent (lockdown, vanished audience, or a
-- failed send) and for M5 it is terminal: the peer will never see it, so the
-- match cannot stay bit-identical -- void now, cleanly, on our side; the peer
-- voids on its own trigger or the 35 s silence. Token-scoped (CONCURRENCY.md
-- 5.5): a drop for another session's token is ignored.
local function onDrop(mtype, token)
  local S = mySession()
  if not S or S.phase == "done" then return end
  if S.token ~= tostring(token or "") then return end
  if S.phase == "join" then
    endSession("Aborted - addon messages were blocked.")
    toast("aborted - addon messages were blocked.", S.host)
  else
    voidMatch("Voided - addon messages were blocked. (M6 will pause instead.)", false)
  end
end

-------------------------------------------------------------------------------
-- The module ticker: deadlines, liveness, sweeping, stub repaint.
-------------------------------------------------------------------------------

onTick = function()
  local S = mySession()
  if S and S.phase ~= "done" then
    local now = GetTime()
    if S.isHost and S.phase == "join" and now > S.joinDeadline then
      PG.Comm.Broadcast(S.scope, "IB", "CANCEL", S.token, "few")
      toast("nobody joined.", S.host)
      endSession("Nobody joined.")
    elseif S.phase == "handshake" and S.handshakeDeadline and now > S.handshakeDeadline then
      if S.isHost then PG.Comm.Broadcast(S.scope, "IB", "CANCEL", S.token, "hs") end
      toast("handshake failed - no compatible answer.", S.host)
      endSession("Handshake failed.")
    elseif S.phase == "play" and (now - S.lastRecv) > HB_TIMEOUT then
      voidMatch("Voided - lost contact with your opponent.", false)
    end
  end

  sweepTicks = sweepTicks + 1
  if sweepTicks >= SWEEP_EVERY then
    sweepTicks = 0
    local now = GetTime()
    local kill
    for k, rec in pairs(sessions) do
      if rec.kind == "lite" and now > rec.expires then
        kill = kill or {}
        kill[#kill + 1] = k
      elseif rec.kind == "full" and rec.phase == "done"
        and rec.doneAt and (now - rec.doneAt) > DONE_TTL then
        kill = kill or {}
        kill[#kill + 1] = k
      end
    end
    if kill then
      for i = 1, #kill do evict(kill[i], true) end
    end
    for k, t in pairs(recent) do
      if (now - t) >= RECENT_TTL then recent[k] = nil end
    end
  end

  if win and win:IsShown() then RefreshUI() end
end

-------------------------------------------------------------------------------
-- IN-GAME DETERMINISM SELFTEST (/pgd ib selftest). Runs the committed
-- hand-written log (harness/logs/hand.iblog, embedded as IdleBattle\
-- HandLog.lua by syncaddon.sh together with the three committed goldens from
-- harness/selftest.lua -- extracted, never hand-copied) INSIDE the WoW
-- client, and compares rulesHash + terminal stateHash + logDigest. One
-- match, 260 ticks, no fuzz: runnable solo in a fraction of a second, and it
-- turns "we believe WoW Lua matches LuaJIT" into a one-command check.
-------------------------------------------------------------------------------

local function say(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffIB|r " .. text)
end

function PG.IB.Selftest()
  if not engineOK() then
    say("selftest: RED - engine not loaded (IB_SIM_MODULES incomplete; check the .toc order)")
    return false
  end
  local L = HandLog
  local t0 = GetTimePreciseSec and GetTimePreciseSec() or 0
  local ok, err = pcall(function()
    local sim = SimM.new(Rules, L.seed, L.loadout1, L.loadout2)
    for i = 1, #L.cmds do
      local c = L.cmds[i]
      local qok, qerr = sim:queueCommand({ side = c.side, seq = c.seq, tick = c.exec,
                                           kind = c.kind, target = c.target, count = c.count })
      if not qok then error("hand log atom " .. i .. " refused: " .. tostring(qerr), 0) end
    end
    -- the tick-250 landmark selftest.lua section 3 asserts by hand: both
    -- spears halted at own-frame 970 on 4 HP after 26 hits of 16
    while sim.clock < 250 do
      if not sim:tick() then error("match ended before tick 250", 0) end
    end
    for s = 1, 2 do
      local us = sim.sides[s].lanes[1].units
      if #us ~= 1 or us[1].pos ~= 970 or us[1].hp ~= 4 then
        error("tick-250 landmark failed on side " .. s
          .. " (want one spear at 970 on 4 HP)", 0)
      end
    end
    while sim.clock < L.ticks do
      if not sim:tick() then break end
    end
    if sim.clock ~= L.ticks then error("terminal tick " .. sim.clock .. ", want " .. L.ticks, 0) end
    local state = Hash.state(sim)
    local digest = Hash.log(sim)
    local pass = true
    local function line(name, got, want)
      local okv = (got == want)
      pass = pass and okv
      say("  " .. name .. " " .. tostring(got) .. " (want " .. tostring(want) .. ") "
        .. (okv and "|cff7deda4OK|r" or "|cffff8a70MISMATCH|r"))
    end
    say("selftest: the committed hand log, inside this WoW client")
    line("rulesHash", Rules.rulesHash, L.goldenRulesHash)
    say("  tick-250 landmarks |cff7deda4OK|r (both spears at 970 on 4 HP)")
    line("stateHash", state, L.goldenState)
    line("logDigest", digest, L.goldenLogDigest)
    if not pass then error("golden mismatch", 0) end
  end)
  local ms = 0
  if GetTimePreciseSec then ms = math.floor((GetTimePreciseSec() - t0) * 1000) end
  if ok then
    say("selftest: |cff7deda4GREEN|r - this client computes the committed goldens ("
      .. tostring(ms) .. " ms). WoW Lua == LuaJIT == Lua 5.5 on this ruleset.")
    return true
  end
  say("selftest: |cffff8a70RED|r - " .. tostring(err))
  say("  a mismatch here means THIS CLIENT would desync a real match: report it")
  return false
end

function PG.IB.Diagnose()
  say("engine: " .. (engineOK() and "loaded" or "MISSING") ..
    (engineOK() and ("  rulesHash " .. tostring(Rules.rulesHash) .. " (" .. tostring(Rules.rulesHash36) .. ")") or ""))
  local S = mySession()
  if not S then
    say("session: none  (lite records " .. tostring(liteCount) .. ")")
    return
  end
  say("session: " .. S.key .. "  phase " .. tostring(S.phase)
    .. (S.opp and ("  vs " .. S.opp) or "") .. "  scope " .. tostring(S.scope))
  local ep = S.ep
  if ep then
    local st = ep.st
    say("  tick " .. tostring(ep.sim and ep.sim.clock or "-")
      .. "  sent " .. st.sent .. " recv " .. st.recv
      .. "  late " .. st.late .. " rollbacks " .. st.rollbacks
      .. " (max depth " .. st.rollbackDepthMax .. ")")
    say("  seq out " .. ep.outSeq .. " ackThru " .. ep.peerAckThru
      .. "  in " .. ep.inContig .. "/" .. ep.peerLastSeq
      .. "  mismatches " .. st.mismatches .. "  Q " .. st.qSent .. "/" .. st.qAnswered
      .. "  rebuilds " .. st.deepRecoveries)
  end
end

-------------------------------------------------------------------------------
-- STUB MATCH SURFACE -- M5 PART 1 PLACEHOLDER. Part 2 replaces everything
-- from here to the dialog with the real board; keep the wiring (ShowWindow /
-- RefreshUI names, the issue() calls, the Safety registration) and delete the
-- rest. Just enough to drive a real match end-to-end between two clients:
-- status, tick, Levy and keep HP both sides, one deploy and one build button.
-------------------------------------------------------------------------------

local function fmtClock(ticks)
  local s = math.floor(ticks / 10)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- One order per click through the endpoint's own gate: exec = now + 2 s
-- (C.1's order delay), shipped as an A.11.2 atom, validated by BOTH sims at
-- the exec tick (A.4). Palisade is D.1 first-playable content; its letter
-- comes from the hashed catalogue, never hardcoded (A.11.2).
local function issueOrder(kind, target, count)
  local S = mySession()
  if not S or S.phase ~= "play" or not S.ep then return end
  local ok, err = pcall(S.ep.issue, S.ep, kind, target, count)
  if not ok then
    geterrorhandler()(err)
    voidMatch("Voided - internal engine error on an order.", true)
  elseif err == false then
    -- issue() returned false: past the clock edge; nothing to do
    toast("too late - the match clock is nearly out.", S.host)
  end
end

local function palisadeLetter()
  for i = 1, #Rules.BUILDINGS do
    if Rules.BUILDINGS[i].key == "palisade" then return Rules.BUILDINGS[i].letter end
  end
  return nil
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("ib", "Idle Battle (DEV)", 360, 250, "neutral")
  -- resume after a raid-safety hide only while the session still matters
  win.__pgResume = function() return live() end

  ui.stub = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.stub:SetPoint("TOP", 0, -36)
  ui.stub:SetText("M5 part 1 STUB - the real board arrives in part 2")
  ui.stub:SetTextColor(0.8, 0.68, 0.42)

  ui.status = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ui.status:SetPoint("TOPLEFT", 16, -56)
  ui.status:SetPoint("TOPRIGHT", -16, -56)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(true)

  ui.clock = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.clock:SetPoint("TOPLEFT", 16, -92)
  ui.clock:SetJustifyH("LEFT")

  ui.me = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.me:SetPoint("TOPLEFT", 16, -110)
  ui.me:SetJustifyH("LEFT")

  ui.foe = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.foe:SetPoint("TOPLEFT", 16, -128)
  ui.foe:SetJustifyH("LEFT")

  ui.net = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.net:SetPoint("TOPLEFT", 16, -146)
  ui.net:SetJustifyH("LEFT")
  ui.net:SetTextColor(0.66, 0.66, 0.61)

  ui.deploy = PG.UI.Button(win, "Deploy Spear (lane 1)", 156, 24, function()
    issueOrder("S", 1, 1)
  end)
  ui.deploy:SetPoint("BOTTOMLEFT", 16, 46)

  ui.build = PG.UI.Button(win, "Build Palisade (slot 1)", 156, 24, function()
    local letter = palisadeLetter()
    if letter then issueOrder(letter, 1, 1) end
  end)
  ui.build:SetPoint("BOTTOMRIGHT", -16, 46)

  ui.cancel = PG.UI.Button(win, "Cancel / concede", 156, 24, function()
    local S = mySession()
    if not S or S.phase == "done" then
      if win then win:Hide() end
      return
    end
    if S.phase == "join" or S.phase == "handshake" then
      if S.isHost then PG.Comm.Broadcast(S.scope, "IB", "CANCEL", S.token, "host") end
      endSession("Cancelled.")
    else
      voidMatch("Voided - you conceded. (No winner in M5; scoring lands with the real board.)", true)
    end
  end)
  ui.cancel:SetPoint("BOTTOM", 0, 14)
end

ShowWindow = function()
  ensureWindow()
  win:Show()
  RefreshUI()
end

RefreshUI = function()
  if not win then return end
  local S = mySession()
  if not S then
    ui.status:SetText("No battle. /pgd ib to open one.")
    ui.clock:SetText("")
    ui.me:SetText("")
    ui.foe:SetText("")
    ui.net:SetText("")
    return
  end
  if S.phase == "join" then
    ui.status:SetText("Waiting for an opponent... ("
      .. math.max(0, math.floor(S.joinDeadline - GetTime())) .. "s)")
  elseif S.phase == "handshake" then
    ui.status:SetText("Handshaking with " .. shortOf(S.opp or "?") .. "...")
  elseif S.phase == "play" then
    ui.status:SetText("BATTLE vs " .. shortOf(S.opp or "?")
      .. (S.isHost and "  (host, side 1)" or "  (side 2)"))
  else
    ui.status:SetText(tostring(S.endText or "Done."))
  end
  local sim = S.ep and S.ep.sim
  if sim then
    local mySide = S.mySide or (S.isHost and 1 or 2)
    local m = sim.sides[mySide]
    local f = sim.sides[3 - mySide]
    ui.clock:SetText("tick " .. sim.clock .. " / " .. S.matchTicks
      .. "   clock " .. fmtClock(sim.clock))
    ui.me:SetText("You:  Levy " .. m.bank .. "   Keep " .. m.keepHp .. " / " .. Rules.C.KEEP_HP)
    ui.foe:SetText("Foe:  Levy " .. f.bank .. "   Keep " .. f.keepHp .. " / " .. Rules.C.KEEP_HP)
    local st = S.ep.st
    ui.net:SetText("net: sent " .. st.sent .. "  recv " .. st.recv
      .. "  late " .. st.late .. "  rollbacks " .. st.rollbacks)
  else
    ui.clock:SetText("")
    ui.me:SetText("")
    ui.foe:SetText("")
    ui.net:SetText("")
  end
  local playing = S.phase == "play"
  ui.deploy:SetEnabled(playing)
  ui.build:SetEnabled(playing)
end

-------------------------------------------------------------------------------
-- Start dialog: the ScopePicker with party-only enabled (D.1), the other two
-- segments visible-but-disabled with the reason (SCOPE.md 1.3).
-------------------------------------------------------------------------------

local function ensureDialog()
  if dialog then return end
  dialog = PG.UI.Window("ib-dialog", "Start Idle Battle (DEV)", 320, 200, "neutral")
  local note = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  note:SetPoint("TOPLEFT", 16, -36)
  note:SetPoint("TOPRIGHT", -16, -36)
  note:SetJustifyH("LEFT")
  note:SetWordWrap(true)
  note:SetText("1v1. First party member to join plays. Join window "
    .. JOIN_SECS .. "s; match up to 10 minutes of active play. DEV build - no gold, no ledger.")
  dlgScope = PG.UI.ScopePicker(dialog, {
    key = "IB",
    allowed = PG.IB.SCOPES,
    reasons = function(scope)
      if scope ~= "group" then
        return "Idle Battle is party-only in the first playable (D.1). Guild and public come with matchmaking (M9)."
      end
      return nil
    end,
  })
  dlgScope:SetPoint("TOPLEFT", dialog, "TOPLEFT", 0, -84)
  local start = PG.UI.Button(dialog, "Open battle", 140, 26, function()
    local scope = dlgScope and dlgScope:Get()
    if not scope then
      toast("no audience available - join a party first.")
      return
    end
    dialog:Hide()
    hostOpen(scope)
  end)
  start:SetPoint("BOTTOM", 0, 16)
end

function PG.IB.OpenDialog()
  if not engineOK() then
    toast("engine not loaded - check the .toc / syncaddon.sh.")
    return
  end
  ensureDialog()
  dialog:Show()
  if dlgScope then pcall(dlgScope.Refresh, dlgScope) end
end

-- The dialog's Start path, public so the launcher-less routes (slash, tests)
-- can host too -- the JoinOpen/OpenGames precedent.
function PG.IB.Host(scope)
  hostOpen(scope or "group")
end

function PG.IB.Slash(sub)
  sub = tostring(sub or ""):lower()
  if sub == "selftest" then
    PG.IB.Selftest()
  elseif sub == "status" then
    PG.IB.Diagnose()
  elseif sub == "show" then
    ShowWindow()
  elseif sub == "host" then
    PG.IB.Host("group")
  else
    PG.IB.OpenDialog()
  end
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

PG.RegisterInit(function()
  local E = PG.IBEngine
  if E then
    Rules, SimM, Hash, Wire, NetM, HandLog =
      E.Rules, E.Sim, E.Hash, E.Wire, E.Net, E.HandLog
  end
  if not engineOK() then
    say("Idle Battle engine did not load - IB_SIM_MODULES is incomplete."
      .. " Check the IdleBattle block of the .toc and run tools/syncaddon.sh --check.")
  end

  PG.Comm.Register("IB", onComm, onDrop)
  if PG.Comm.RegisterTrust then
    -- Party-only game: every legitimate whisperer (JOIN/NO/Q) is in the group
    -- and passes Comm's roster test; a whisper from outside it is not ours.
    PG.Comm.RegisterTrust("IB", function() return false end)
  end

  -- Accepting a seat elsewhere withdraws our outstanding invitations
  -- (CONCURRENCY.md 5.6 rule 3); the lite records stay listed until expiry.
  PG.Session.OnChange(function(seat)
    if not seat or seat.module == "IB" then return end
    for _, rec in pairs(sessions) do
      if rec.kind == "lite" and rec.askKey then
        PG.UI.Dismiss(rec.askKey)
        rec.askKey = nil
      end
    end
  end)

  -- M5's encounter rule: an encounter or addon restriction voids the live
  -- match on the spot (both sides converge: the peer sees our V, its own
  -- trigger, or 35 s of silence). M6 replaces exactly this callback with the
  -- halt path (X on RESTRICT_ON, K/G on clear).
  PG.Safety.OnChange(function(state, trigger)
    if trigger == "ENCOUNTER_ON" or trigger == "RESTRICT_ON" then
      local S = mySession()
      if S and (S.phase == "play" or S.phase == "handshake") then
        voidMatch("Voided - a raid encounter started. (M6 adds pause/resume.)", true)
      elseif S and S.phase == "join" then
        if S.isHost then PG.Comm.Broadcast(S.scope, "IB", "CANCEL", S.token, "enc") end
        endSession("Cancelled - a raid encounter started.")
      end
    end
  end)
end)
