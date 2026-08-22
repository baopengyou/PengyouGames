-- Games/IdleBattle.lua - Idle Battle mounted in the DEV addon. M5 part 1
-- built the plumbing: matchmaking through the shipped session system, the
-- real-channel comm bridge onto net/Net.lua, the OnUpdate tick driver and
-- the in-game determinism selftest. M5 part 2 replaced part 1's stub with
-- the REAL BOARD (the window section at the bottom of this file): side-on
-- lanes per docs/IDLE_BATTLE_VISUAL.md, D.1's full command surface, and the
-- shared reveal stage on a real result.
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

local TICK_SECS = 0.5        -- module ticker (sweeps, deadlines, board repaint)
local SIM_TICK = 0.1         -- one sim tick per 100 ms (Rules.C.SIM_TICK_MS)
local JOIN_SECS = 45         -- join window (fixed in the M5 dialog)
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
-- stops. The record lingers DONE_TTL so the board can show the verdict (and
-- the final state of the field) before it is swept.
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
-- The module ticker: deadlines, liveness, sweeping, board repaint.
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
-- THE BOARD -- M5 PART 2, the real match surface (replacing part 1's stub).
--
-- Side-on battlefield per docs/IDLE_BATTLE_VISUAL.md: three lanes stacked
-- vertically, each lane drawn as the FULL shared axis with an explicit
-- midline, both keeps flanking the field. THE VIEWING PLAYER'S HALF IS
-- ALWAYS THE LEFT HALF, whichever engine side they hold: the sim is
-- side-agnostic (A.2) and stores every position in its owner's OWN frame
-- (0 = own keep, LANE_LEN = the enemy keep), so own entities plot at
-- pos/LANE_LEN of the lane width and enemy entities at 1 - pos/LANE_LEN --
-- ONE formula for both seats. The side-2 render mirrors by construction,
-- never by an "am I the host" branch (the classic lockstep rendering bug).
--
-- READ-ONLY RENDER. Every repaint derives what it shows -- names, letters,
-- costs, counts, caps, slot geometry, income -- from Rules and from
-- S.ep.sim's hashed state, never from a duplicated table (display names
-- derive from the catalogue keys; the one presentation map is TIER_WORD,
-- prose keyed by the hashed tier names). The board never writes into the
-- sim: the only mutation path is issueOrder -> ep:issue -> the endpoint's
-- own gate, and BOTH sims validate every order at its exec tick (A.4). A
-- refused order is a counted fizzle on the net line, never a client veto;
-- affordability greying is advisory paint, not a gate.
--
-- NO FOG. fog/ is deliberately not mounted in M5: a permanent board label
-- says both players currently see the whole board. The fog render filter
-- mounts at a later milestone in front of exactly this read path.
--
-- Layout floats never reach the sim: everything handed to issue() is an
-- integer the buttons were BUILT with (lane, slot, count).
-------------------------------------------------------------------------------

local floor = math.floor

-- Window geometry. The window resizes BY SCALE (the factory corner grip,
-- 0.6..1.6), so these are design-time pixels: nothing below reads GetWidth
-- at repaint, and the layout never reflows.
local BW, BH = 980, 560
local KEEP_W = 60                 -- keep column width
local BF_X = 82                   -- battlefield left edge (16 + KEEP_W + 6)
local LANE_W = BW - 2 * BF_X      -- 816
local BF_Y = 64                   -- battlefield top, below the header
local LANE_H = 96
local LANE_GAP = 6
local BF_H = 3 * LANE_H + 2 * LANE_GAP
local SLOT_S = 44                 -- slot square side
local MARK_W, MARK_H = 40, 22     -- unit stack marker
local MARK_Y_MINE, MARK_Y_FOE = -16, -70
local BUCKETS = 16                -- stack grouping: 1/16th of the lane axis

-- Presentation only. Art keys would route through PG.Theme (SKIN.md rule 0);
-- the board draws plain color blocks and bars until the owner's deferred
-- asset pass (IDLE_BATTLE_VISUAL.md ruling 2) -- legible and honest beats
-- guessed atlases. Unit colors are indexed by Rules unit index.
local CLR = {
  laneBG  = { 0.070, 0.075, 0.095, 0.92 },
  midline = { 0.85, 0.72, 0.35, 0.45 },
  mine    = { 0.45, 0.86, 0.55 },
  foe     = { 0.95, 0.42, 0.34 },
  unit    = { { 0.72, 0.80, 1.00 }, { 1.00, 0.75, 0.35 }, { 0.62, 0.93, 0.62 } },
  slotBG  = { 0.13, 0.13, 0.15, 0.85 },
  slotHi  = { 1.00, 0.82, 0.20 },
  barBG   = { 0, 0, 0, 0.65 },
  grey    = { 0.66, 0.66, 0.61 },
  gold    = { 1.00, 0.85, 0.46 },
  amber   = { 0.95, 0.78, 0.35 },
}

-- UI-only selection state (never sim state): what the next board click will
-- order. Cleared whenever no match is in the play phase.
local armed                       -- { unit = i } or { bld = i }, Rules indices
local deployCount = 1             -- 1 .. Rules.C.MAX_UNITS_PER_ORDER

local function fmtClock(ticks)
  local s = math.floor(ticks / 10)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function fmtSecs1(ticks)
  return string.format("%.1f", ticks / 10)
end

-- "trapPit" -> "Trap Pit": display names DERIVE from the hashed catalogue
-- key. Rules carries no display-name field, and a hand-kept name table would
-- be exactly the duplicated data the determinism doctrine bans.
local function titleCase(key)
  local s = tostring(key or ""):gsub("(%u)", " %1")
  s = s:gsub("^%l", string.upper)
  return s
end

-- Decoration runner (the RPS runFX idiom): theme calls are pcall'd and
-- swallowed so no skin problem can ever touch game state or the wire.
local function fx(name, ...)
  local T = PG.Theme
  local f = T and T[name]
  if f then
    local ok, err = pcall(f, ...)
    if not ok then geterrorhandler()(err) end
  end
end

-- One order per click through the endpoint's own gate: exec = now + 2 s
-- (C.1's order delay), shipped as an A.11.2 atom, validated by BOTH sims at
-- the exec tick (A.4). On success the order is remembered ADDON-side
-- (kind/target/count/exec) so the delay is VISIBLE: queued markers on the
-- lane or slot resolve when the sim clock reaches the exec tick. The
-- engine's own buffers are never reached into for this.
local function issueOrder(kind, target, count)
  local S = mySession()
  if not S or S.phase ~= "play" or not S.ep then return end
  local execAt = (S.ep.sim and (S.ep.sim.clock + Rules.C.ORDER_DELAY)) or 0
  local ok, err = pcall(S.ep.issue, S.ep, kind, target, count)
  if not ok then
    geterrorhandler()(err)
    voidMatch("Voided - internal engine error on an order.", true)
    return
  end
  if err == false then
    -- issue() returned false: past the clock edge; nothing to do
    toast("too late - the match clock is nearly out.", S.host)
    return
  end
  S.pending = S.pending or {}
  S.pending[#S.pending + 1] = { kind = kind, target = target, count = count, exec = execAt }
  fx("Sound", "click")
  RefreshUI()
end

local function prunePending(S, sim)
  local p = S.pending
  if not p then return end
  local w = 0
  for i = 1, #p do
    if p[i].exec >= sim.clock then
      w = w + 1
      p[w] = p[i]
    end
  end
  for i = #p, w + 1, -1 do p[i] = nil end
end

local function pendingLaneText(S, sim, lane)
  local p = S.pending
  if not p then return "" end
  local out
  for i = 1, #p do
    local e = p[i]
    if e.target == lane and Rules.UNIT_BY_KIND[e.kind] then
      local piece = e.count .. "x" .. e.kind .. " in " .. fmtSecs1(e.exec - sim.clock) .. "s"
      out = out and (out .. "  " .. piece) or piece
    end
  end
  return out and ("queued " .. out) or ""
end

local function pendingSlotLetter(S, slot)
  local p = S.pending
  if not p then return nil end
  for i = 1, #p do
    local e = p[i]
    if e.target == slot and Rules.BUILDING_BY_LETTER[e.kind] then return e.kind end
  end
  return nil
end

-- Income and cap cues, derived from the slots the same way phaseIncome and
-- bankCapOf derive them -- for a D.1 (cardless) match the channel and
-- production terms are structurally zero, so these are exact.
local function incomeOf(sd)
  local flat = 0
  for s = 1, Rules.C.SLOTS do
    local b = sd.slots[s]
    if b and b.done == 1 then flat = flat + Rules.BUILDINGS[b.b].levyFlat end
  end
  return Rules.C.BASE_INCOME + flat
end

local function bankCapOfSide(sd)
  local cap = Rules.C.BANK_CAP
  for s = 1, Rules.C.SLOTS do
    local b = sd.slots[s]
    if b and b.done == 1 then cap = cap + Rules.BUILDINGS[b.b].bankCapFlat end
  end
  return cap
end

local function depthSumOf(sd)
  local n = 0
  for lane = 1, Rules.C.LANES do n = n + sd.lanes[lane].depth end
  return n
end

local function mySideOf(S)
  return S.mySide or (S.isHost and 1 or 2)
end

-- Board clicks. A unit order targets the LANE (uppercase kind, A.11.2), a
-- building order targets one of MY six slots (lowercase). No legality is
-- pre-checked here beyond what the buttons painted: the sims judge at exec.
local function laneClicked(lane)
  local S = mySession()
  if not (S and S.phase == "play" and S.ep) then return end
  if armed and armed.unit then
    issueOrder(Rules.UNITS[armed.unit].kind, lane, deployCount)
  end
end

local function slotClicked(slot, lane)
  local S = mySession()
  if not (S and S.phase == "play" and S.ep) then return end
  if armed and armed.bld then
    issueOrder(Rules.BUILDINGS[armed.bld].letter, slot, 1)
    armed = nil
    RefreshUI()
  elseif armed and armed.unit then
    -- a unit order targets the lane; clicking a square still reads as "here"
    issueOrder(Rules.UNITS[armed.unit].kind, lane, deployCount)
  end
end

-------------------------------------------------------------------------------
-- Tooltips: every number read live from Rules (and the bank from the sim).
-------------------------------------------------------------------------------

local function tipHide()
  GameTooltip:Hide()
end

local function affordLine(cost)
  local S = mySession()
  local sim = S and S.ep and S.ep.sim
  if sim then
    local bank = sim.sides[mySideOf(S)].bank
    if bank < cost then
      GameTooltip:AddLine("Bank " .. bank .. " - short by " .. (cost - bank)
        .. ". Orders still send: both sims judge at execution (A.4).", 1, 0.45, 0.35, true)
    end
  end
end

local function unitTip(owner, i)
  local u = Rules.UNITS[i]
  local C = Rules.C
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine(titleCase(u.key))
  GameTooltip:AddLine("Cost " .. u.cost .. " Levy"
    .. ((deployCount > 1) and ("  (x" .. deployCount .. " = " .. (u.cost * deployCount) .. ")") or ""),
    1, 0.82, 0, true)
  GameTooltip:AddLine("HP " .. u.hp .. "  -  " .. u.dmg .. " damage every resolve ("
    .. fmtSecs1(C.RESOLVE_EVERY) .. " s)"
    .. ((u.targets > 1) and (", up to " .. u.targets .. " targets") or ""), 1, 1, 1, true)
  GameTooltip:AddLine("Range " .. u.range .. "  -  march " .. u.march .. " per tick", 1, 1, 1, true)
  GameTooltip:AddLine("Beats " .. titleCase(Rules.UNITS[u.prey].key)
    .. " (+" .. (C.COUNTER_PCT - 100) .. "% into it)", 0.49, 0.93, 0.64, true)
  for j = 1, #Rules.UNITS do
    if Rules.UNITS[j].prey == i then
      GameTooltip:AddLine("Hunted by " .. titleCase(Rules.UNITS[j].key), 1, 0.54, 0.44, true)
    end
  end
  GameTooltip:AddLine("Supply " .. u.cost .. " of the lane's " .. C.LANE_SUPPLY_CAP
    .. " (base cost)", 0.66, 0.66, 0.61, true)
  affordLine(u.cost)
  GameTooltip:Show()
end

local function bldTip(owner, bi)
  local b = Rules.BUILDINGS[bi]
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine(titleCase(b.key))
  GameTooltip:AddLine("Cost " .. b.cost .. " Levy  -  builds in " .. fmtSecs1(b.build) .. " s",
    1, 0.82, 0, true)
  GameTooltip:AddLine("HP " .. b.hp .. "  -  "
    .. ((b.slotClass == "front") and "FRONT square (F)" or "BACK square (B)")
    .. ((b.defensive == 1) and "  -  defensive" or ""), 1, 1, 1, true)
  if b.dmg > 0 then
    GameTooltip:AddLine("Shoots for " .. b.dmg .. " every resolve, range " .. b.dmgRange,
      1, 1, 1, true)
  end
  if b.trapBurst > 0 then
    GameTooltip:AddLine("One-shot burst: " .. b.trapBurst .. " damage over up to "
      .. b.trapTargets .. " targets within " .. b.trapRadius, 1, 1, 1, true)
  end
  if b.levyFlat > 0 then
    GameTooltip:AddLine("+" .. b.levyFlat .. " Levy per Levy tick", 0.49, 0.93, 0.64, true)
  end
  if b.bankCapFlat > 0 then
    GameTooltip:AddLine("+" .. b.bankCapFlat .. " bank cap", 0.49, 0.93, 0.64, true)
  end
  if b.vision > 0 then
    GameTooltip:AddLine("Vision " .. b.vision .. " - real once fog mounts (later milestone)",
      0.66, 0.66, 0.61, true)
  end
  affordLine(b.cost)
  GameTooltip:Show()
end

local function slotTip(owner, slot)
  local S = mySession()
  local sim = S and S.ep and S.ep.sim
  if not sim then return end
  local b = sim.sides[mySideOf(S)].slots[slot]
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  local front = (slot % 2) == 1     -- interpretation 1: odd slots are front
  if b then
    local br = Rules.BUILDINGS[b.b]
    GameTooltip:AddLine(titleCase(br.key) .. " (" .. br.letter .. ")")
    if b.done == 0 then
      GameTooltip:AddLine("Under construction - " .. floor(b.prog * 100 / b.need) .. "%",
        1, 0.82, 0, true)
    end
    GameTooltip:AddLine("HP " .. b.hp .. " / " .. b.maxHp, 1, 1, 1, true)
    if b.spent == 1 then GameTooltip:AddLine("Spent (one-shot fired)", 0.66, 0.66, 0.61, true) end
  else
    GameTooltip:AddLine((front and "Front" or "Back") .. " square - empty")
    GameTooltip:AddLine("Pick a building below, then click here.", 0.66, 0.66, 0.61, true)
  end
  GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Widget builders. Pools are built once per lane and reused every repaint;
-- markers grow on demand and hide when idle, so a busy lane never allocates
-- per frame.
-------------------------------------------------------------------------------

local function mkTex(parent, layer, c)
  local t = parent:CreateTexture(nil, layer)
  t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  return t
end

local function mkFS(parent, template, c)
  local s = parent:CreateFontString(nil, "OVERLAY", template)
  if c then s:SetTextColor(c[1], c[2], c[3]) end
  return s
end

local function mkBar(parent, w, h)
  local bar = { w = w }
  bar.bg = mkTex(parent, "ARTWORK", CLR.barBG)
  bar.bg:SetSize(w, h)
  bar.fill = mkTex(parent, "OVERLAY", CLR.mine)
  bar.fill:SetSize(w, h)
  bar.fill:SetPoint("LEFT", bar.bg, "LEFT", 0, 0)
  return bar
end

local function barSet(bar, num, den, c)
  if den <= 0 then den = 1 end
  if num < 0 then num = 0 end
  local w = floor(bar.w * num / den)
  if w < 1 then
    bar.fill:Hide()
  else
    bar.fill:SetWidth(w)
    bar.fill:Show()
  end
  if c then bar.fill:SetColorTexture(c[1], c[2], c[3], 1) end
end

local function mkKeep(onRight)
  local f = CreateFrame("Frame", nil, win)
  f:SetSize(KEEP_W, BF_H)
  if onRight then
    f:SetPoint("TOPRIGHT", -16, -BF_Y)
  else
    f:SetPoint("TOPLEFT", 16, -BF_Y)
  end
  local k = { frame = f }
  local bg = mkTex(f, "BACKGROUND", CLR.slotBG)
  bg:SetAllPoints()
  k.name = mkFS(f, "GameFontNormalSmall", onRight and CLR.foe or CLR.mine)
  k.name:SetPoint("TOP", 0, -4)
  k.name:SetWidth(KEEP_W - 4)
  k.label = mkFS(f, "GameFontNormalSmall", CLR.grey)
  k.label:SetPoint("TOP", 0, -18)
  k.label:SetText("KEEP")
  k.barBG = mkTex(f, "ARTWORK", CLR.barBG)
  k.barBG:SetSize(14, BF_H - 64)
  k.barBG:SetPoint("TOP", 0, -34)
  k.fill = mkTex(f, "OVERLAY", onRight and CLR.foe or CLR.mine)
  k.fill:SetSize(14, BF_H - 64)
  k.fill:SetPoint("BOTTOM", k.barBG, "BOTTOM", 0, 0)
  k.hp = mkFS(f, "GameFontNormalSmall", nil)
  k.hp:SetPoint("BOTTOM", 0, 16)
  k.max = mkFS(f, "GameFontNormalSmall", CLR.grey)
  k.max:SetPoint("BOTTOM", 0, 4)
  return k
end

local function keepSet(k, hp)
  local h = floor((BF_H - 64) * hp / Rules.C.KEEP_HP)
  if h < 1 then
    k.fill:Hide()
  else
    k.fill:SetHeight(h)
    k.fill:Show()
  end
  k.hp:SetText(tostring(hp))
end

-- One slot square. `frac` is the slot's position on the shared axis in THIS
-- VIEWER's screen frame, handed in by mkLane from the hashed POS_* constants
-- (own slots at pos/LANE_LEN, enemy slots mirrored to 1 - pos/LANE_LEN).
local function mkSlotBox(L, laneIdx, slotIdx, frac, mineFlag)
  local f = CreateFrame("Frame", nil, L.frame)
  f:SetSize(SLOT_S, SLOT_S)
  f:SetPoint("TOPLEFT", floor(frac * LANE_W) - floor(SLOT_S / 2), -30)
  f:SetFrameLevel(L.frame:GetFrameLevel() + 1)
  f.__ibBoxFrac = frac              -- read by the headless m5 drive
  local box = { frame = f, mine = mineFlag, slot = slotIdx }
  box.bg = mkTex(f, "BACKGROUND", CLR.slotBG)
  box.bg:SetAllPoints()
  box.hi = mkTex(f, "BACKGROUND", CLR.slotHi)
  box.hi:SetAllPoints()
  box.hi:SetAlpha(0)
  box.tag = mkFS(f, "GameFontNormalSmall", mineFlag and CLR.mine or CLR.foe)
  box.tag:SetPoint("TOPLEFT", 2, -1)
  box.tag:SetText(((slotIdx % 2) == 1) and "F" or "B")   -- interpretation 1
  box.letter = mkFS(f, "GameFontNormalLarge", CLR.gold)
  box.letter:SetPoint("CENTER", 0, 2)
  box.sub = mkFS(f, "GameFontNormalSmall", CLR.grey)
  box.sub:SetPoint("BOTTOM", 0, 6)
  box.bar = mkBar(f, SLOT_S - 6, 3)
  box.bar.bg:SetPoint("BOTTOMLEFT", 3, 2)
  if mineFlag then
    local hit = CreateFrame("Button", nil, f)
    hit:SetAllPoints()
    hit:SetFrameLevel(f:GetFrameLevel() + 5)
    hit.__ibSlot = slotIdx            -- read by the headless m5 drive
    hit.__ibLane = laneIdx
    hit:SetScript("OnClick", function() slotClicked(slotIdx, laneIdx) end)
    hit:SetScript("OnEnter", function(self) slotTip(self, slotIdx) end)
    hit:SetScript("OnLeave", tipHide)
    box.hit = hit
  end
  return box
end

local function mkMark(L)
  local f = CreateFrame("Frame", nil, L.frame)
  f:SetSize(MARK_W, MARK_H)
  f:SetFrameLevel(L.frame:GetFrameLevel() + 3)
  local m = { frame = f }
  m.txt = mkFS(f, "GameFontNormalSmall", nil)
  m.txt:SetPoint("TOP", 0, 0)
  m.bar = mkBar(f, MARK_W - 6, 3)
  m.bar.bg:SetPoint("BOTTOMLEFT", 3, 2)
  return m
end

local function mkLane(i)
  local f = CreateFrame("Frame", nil, win)
  f:SetSize(LANE_W, LANE_H)
  f:SetPoint("TOPLEFT", BF_X, -(BF_Y + (i - 1) * (LANE_H + LANE_GAP)))
  local L = { frame = f, marks = {}, boxes = {} }
  local bg = mkTex(f, "BACKGROUND", CLR.laneBG)
  bg:SetAllPoints()
  -- the explicit midline: the shared axis's centre, identical from both seats
  local mid = mkTex(f, "ARTWORK", CLR.midline)
  mid:SetSize(2, LANE_H - 16)
  mid:SetPoint("TOPLEFT", floor(LANE_W / 2) - 1, -14)
  L.head = mkFS(f, "GameFontNormalSmall", CLR.mine)
  L.head:SetPoint("TOPLEFT", 4, -1)
  L.headFoe = mkFS(f, "GameFontNormalSmall", CLR.foe)
  L.headFoe:SetPoint("TOPRIGHT", -4, -1)
  L.ghost = mkFS(f, "GameFontNormalSmall", CLR.amber)
  L.ghost:SetPoint("TOP", 0, -1)
  -- slot squares: geometry from the hashed constants, enemy mirrored
  local C = Rules.C
  local backF = C.POS_BACK_SLOT / C.LANE_LEN
  local frontF = C.POS_FRONT_SLOT / C.LANE_LEN
  local fsIdx = (i - 1) * 2 + 1     -- interpretation 1: this lane's front slot
  L.boxes[1] = mkSlotBox(L, i, fsIdx + 1, backF, true)
  L.boxes[2] = mkSlotBox(L, i, fsIdx, frontF, true)
  L.boxes[3] = mkSlotBox(L, i, fsIdx, 1 - frontF, false)
  L.boxes[4] = mkSlotBox(L, i, fsIdx + 1, 1 - backF, false)
  -- the lane-wide click target, UNDER the slot hits, over everything else
  local hit = CreateFrame("Button", nil, f)
  hit:SetPoint("TOPLEFT", 0, -14)
  hit:SetPoint("BOTTOMRIGHT", 0, 0)
  hit:SetFrameLevel(f:GetFrameLevel() + 4)
  hit.__ibLane = i                  -- read by the headless m5 drive
  hit.__ibGhost = L.ghost
  hit:SetScript("OnClick", function() laneClicked(i) end)
  L.hit = hit
  return L
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("ib", "Idle Battle (DEV)", BW, BH, "neutral")
  -- resume after a raid-safety hide only while the session still matters
  win.__pgResume = function() return live() end

  ui.status = mkFS(win, "GameFontNormal", CLR.gold)
  ui.status:SetPoint("TOPLEFT", 16, -30)
  ui.status:SetJustifyH("LEFT")

  ui.clock = mkFS(win, "GameFontNormal", nil)
  ui.clock:SetPoint("TOPRIGHT", -30, -30)
  ui.clock:SetJustifyH("RIGHT")

  -- the permanent no-fog label (fog/ mounts at a later milestone)
  ui.fog = mkFS(win, "GameFontNormalSmall", CLR.grey)
  ui.fog:SetPoint("TOPLEFT", 16, -46)
  ui.fog:SetText("Full information: both players see the whole board. Fog of war is a later milestone.")

  ui.keepMine = mkKeep(false)
  ui.keepFoe = mkKeep(true)
  ui.lane = {}
  for i = 1, Rules.C.LANES do ui.lane[i] = mkLane(i) end

  -- big centre text for join / handshake / verdict, over the battlefield
  ui.overlay = mkFS(win, "GameFontNormalLarge", nil)
  ui.overlay:SetPoint("TOP", 0, -(BF_Y + 110))
  ui.overlay:SetWidth(LANE_W - 80)
  ui.overlay:SetJustifyH("CENTER")
  ui.overlay:SetWordWrap(true)

  local ecoY = BF_Y + BF_H + 8
  ui.eco = mkFS(win, "GameFontNormalSmall", CLR.mine)
  ui.eco:SetPoint("TOPLEFT", 16, -ecoY)
  ui.eco:SetJustifyH("LEFT")
  ui.ecoFoe = mkFS(win, "GameFontNormalSmall", CLR.foe)
  ui.ecoFoe:SetPoint("TOPRIGHT", -16, -ecoY)
  ui.ecoFoe:SetJustifyH("RIGHT")
  ui.score = mkFS(win, "GameFontNormalSmall", CLR.gold)
  ui.score:SetPoint("TOP", 0, -(ecoY + 16))

  -- MUSTER row: one button per Rules.UNITS entry, count stepper capped by
  -- the hashed MAX_UNITS_PER_ORDER. Kind letters ride the buttons from the
  -- catalogue (the stub's palisadeLetter idiom, generalised).
  local rowY = ecoY + 34
  ui.musterLabel = mkFS(win, "GameFontNormalSmall", CLR.grey)
  ui.musterLabel:SetPoint("TOPLEFT", 16, -rowY)
  ui.musterLabel:SetText("MUSTER - pick a unit and a count, then click a lane")
  ui.armedText = mkFS(win, "GameFontNormalSmall", CLR.amber)
  ui.armedText:SetPoint("TOPRIGHT", -86, -rowY)
  ui.armedText:SetJustifyH("RIGHT")
  ui.clearBtn = PG.UI.Button(win, "Clear", 60, 20, function()
    armed = nil
    RefreshUI()
  end)
  ui.clearBtn:SetPoint("TOPRIGHT", -16, -(rowY - 2))
  ui.clearBtn.__ibClear = true

  local by = rowY + 16
  ui.unitBtns = {}
  local x = 16
  for i = 1, #Rules.UNITS do
    local u = Rules.UNITS[i]
    local idx = i
    local b = PG.UI.Button(win, titleCase(u.key) .. "  " .. u.cost, 118, 24, function()
      armed = { unit = idx }
      fx("Sound", "click")
      RefreshUI()
    end)
    b:SetPoint("TOPLEFT", x, -by)
    b.__ibKind = u.kind               -- read by the headless m5 drive
    b:SetScript("OnEnter", function(self) unitTip(self, idx) end)
    b:SetScript("OnLeave", tipHide)
    ui.unitBtns[i] = b
    x = x + 124
  end
  ui.cntMinus = PG.UI.Button(win, "-", 24, 24, function()
    if deployCount > 1 then deployCount = deployCount - 1 end
    RefreshUI()
  end)
  ui.cntMinus:SetPoint("TOPLEFT", x + 8, -by)
  ui.cntMinus.__ibCountBtn = -1
  ui.cntText = mkFS(win, "GameFontNormal", nil)
  ui.cntText:SetPoint("TOPLEFT", x + 40, -(by + 5))
  ui.cntPlus = PG.UI.Button(win, "+", 24, 24, function()
    if deployCount < Rules.C.MAX_UNITS_PER_ORDER then deployCount = deployCount + 1 end
    RefreshUI()
  end)
  ui.cntPlus:SetPoint("TOPLEFT", x + 68, -by)
  ui.cntPlus.__ibCountBtn = 1

  -- BUILD row: exactly D.1's first playable subset, DISCOVERED from the
  -- hashed catalogue's own firstPlayable flag -- never a hand-kept list.
  local by2 = by + 46
  ui.buildLabel = mkFS(win, "GameFontNormalSmall", CLR.grey)
  ui.buildLabel:SetPoint("TOPLEFT", 16, -(by2 - 14))
  ui.buildLabel:SetText("BUILD - pick a building, then click one of your squares (F front, B back)")
  ui.bldBtns = {}
  x = 16
  for bi = 1, #Rules.BUILDINGS do
    local br = Rules.BUILDINGS[bi]
    if br.firstPlayable == 1 then
      local idx = bi
      local b = PG.UI.Button(win, titleCase(br.key) .. "  " .. br.cost, 150, 24, function()
        armed = { bld = idx }
        fx("Sound", "click")
        RefreshUI()
      end)
      b:SetPoint("TOPLEFT", x, -by2)
      b.__ibKind = br.letter            -- read by the headless m5 drive
      b.__ibBld = bi
      b:SetScript("OnEnter", function(self) bldTip(self, idx) end)
      b:SetScript("OnLeave", tipHide)
      ui.bldBtns[#ui.bldBtns + 1] = b
      x = x + 156
    end
  end

  -- the part-1 net diagnostic line, kept, unobtrusive
  ui.net = mkFS(win, "GameFontNormalSmall", CLR.grey)
  ui.net:SetPoint("BOTTOMLEFT", 16, 12)
  ui.net:SetJustifyH("LEFT")

  ui.cancel = PG.UI.Button(win, "Cancel / concede", 150, 24, function()
    local S = mySession()
    if not S or S.phase == "done" then
      if win then win:Hide() end
      return
    end
    if S.phase == "join" or S.phase == "handshake" then
      if S.isHost then PG.Comm.Broadcast(S.scope, "IB", "CANCEL", S.token, "host") end
      endSession("Cancelled.")
    else
      voidMatch("Voided - you conceded. (A concede is a VOID in M5: no winner is"
        .. " recorded until a surrender row exists on the wire.)", true)
    end
  end)
  ui.cancel:SetPoint("BOTTOMRIGHT", -16, 10)
  ui.cancel.__ibCancel = true
end

-------------------------------------------------------------------------------
-- Repaints, all READ-ONLY over S.ep.sim. Driven by onTick (0.5 s, the resolve
-- cadence the visual doc leans on) and by the click paths.
-------------------------------------------------------------------------------

local function paintBoxContent(box, sd, S)
  local b = sd.slots[box.slot]
  local pendL = box.mine and pendingSlotLetter(S, box.slot) or nil
  local f = box.frame
  if b then
    local br = Rules.BUILDINGS[b.b]
    box.letter:SetText(br.letter)
    if b.done == 0 then
      f:SetAlpha(0.75)
      box.sub:SetText(floor(b.prog * 100 / b.need) .. "%")
    elseif b.spent == 1 then
      f:SetAlpha(0.8)
      box.sub:SetText("spent")
    else
      f:SetAlpha(1)
      box.sub:SetText("")
    end
    box.bar.bg:Show()
    barSet(box.bar, b.hp, b.maxHp, box.mine and CLR.mine or CLR.foe)
  elseif pendL then
    f:SetAlpha(0.9)
    box.letter:SetText(pendL)
    box.sub:SetText("queued")
    box.bar.bg:Hide()
    box.bar.fill:Hide()
  else
    f:SetAlpha(0.8)
    box.letter:SetText("")
    box.sub:SetText("")
    box.bar.bg:Hide()
    box.bar.fill:Hide()
  end
  -- armed-build affordance: my empty squares light, the matching class
  -- (hashed slotClass against interpretation 1's odd-front numbering)
  -- brighter. Affordance only: every square stays clickable and the sims
  -- alone judge legality at the exec tick (A.4).
  local hi = 0
  if box.mine and not b and not pendL and armed and armed.bld and S.phase == "play" then
    local wantFront = Rules.BUILDINGS[armed.bld].slotClass == "front"
    hi = (wantFront == ((box.slot % 2) == 1)) and 0.30 or 0.10
  end
  box.hi:SetAlpha(hi)
end

local function paintLane(i, S, sim, mySide)
  local L = ui.lane[i]
  local C = Rules.C
  local m = sim.sides[mySide]
  local e = sim.sides[3 - mySide]
  L.head:SetText("Lane " .. i .. "   supply " .. m.lanes[i].supply .. "/" .. C.LANE_SUPPLY_CAP)
  L.headFoe:SetText(e.lanes[i].supply .. "/" .. C.LANE_SUPPLY_CAP .. " supply")
  L.ghost:SetText(pendingLaneText(S, sim, i))
  paintBoxContent(L.boxes[1], m, S)
  paintBoxContent(L.boxes[2], m, S)
  paintBoxContent(L.boxes[3], e, S)
  paintBoxContent(L.boxes[4], e, S)
  -- unit stacks: grouped by (type, 1/16th of the axis), a marker per stack --
  -- one marker per STACK, never per unit (the visual doc's own rule)
  local used = 0
  for pass = 1, 2 do
    local mineFlag = (pass == 1)
    local sd = mineFlag and m or e
    local us = sd.lanes[i].units
    local order, agg = {}, {}
    for k = 1, #us do
      local u = us[k]
      local bucket = floor(u.pos * BUCKETS / C.LANE_LEN)
      if bucket >= BUCKETS then bucket = BUCKETS - 1 end
      local key = u.t * BUCKETS + bucket
      local a = agg[key]
      if not a then
        a = { t = u.t, n = 0, hp = 0, maxHp = 0, pos = 0 }
        agg[key] = a
        order[#order + 1] = key
      end
      a.n = a.n + 1
      a.hp = a.hp + u.hp
      a.maxHp = a.maxHp + u.maxHp
      a.pos = a.pos + u.pos
    end
    for k = 1, #order do
      local a = agg[order[k]]
      used = used + 1
      local mk = L.marks[used]
      if not mk then
        mk = mkMark(L)
        L.marks[used] = mk
      end
      -- the one mirroring rule: mine at pos/LANE_LEN, the enemy at 1 - that
      local frac = a.pos / (a.n * C.LANE_LEN)
      if not mineFlag then frac = 1 - frac end
      mk.frame:ClearAllPoints()
      mk.frame:SetPoint("TOPLEFT", floor(frac * (LANE_W - MARK_W)),
        mineFlag and MARK_Y_MINE or MARK_Y_FOE)
      mk.frame.__ibMark = mineFlag and "mine" or "foe"   -- headless m5 drive
      mk.frame.__ibFrac = frac
      local ub = Rules.UNITS[a.t]
      mk.txt:SetText(ub.kind .. ((a.n > 1) and ("x" .. a.n) or ""))
      local uc = CLR.unit[a.t] or CLR.grey
      mk.txt:SetTextColor(uc[1], uc[2], uc[3])
      barSet(mk.bar, a.hp, a.maxHp, mineFlag and CLR.mine or CLR.foe)
      mk.frame:Show()
    end
  end
  for k = used + 1, #L.marks do L.marks[k].frame:Hide() end
end

local function paintEmptyLane(i)
  local L = ui.lane[i]
  L.head:SetText("Lane " .. i)
  L.headFoe:SetText("")
  L.ghost:SetText("")
  for k = 1, 4 do
    local box = L.boxes[k]
    box.letter:SetText("")
    box.sub:SetText("")
    box.bar.bg:Hide()
    box.bar.fill:Hide()
    box.hi:SetAlpha(0)
    box.frame:SetAlpha(0.5)
  end
  for k = 1, #L.marks do L.marks[k].frame:Hide() end
end

local function paintHeader(S, sim)
  if not S then
    ui.status:SetText("No battle. /pgd ib to open one.")
    ui.clock:SetText("")
    return
  end
  local who = S.opp and shortOf(S.opp) or "?"
  if S.phase == "join" then
    ui.status:SetText("Recruiting - party scope")
  elseif S.phase == "handshake" then
    ui.status:SetText("Handshaking with " .. who)
  elseif S.phase == "play" then
    ui.status:SetText("BATTLE vs " .. who .. "  -  you are the LEFT army"
      .. (S.isHost and "  (host)" or ""))
  else
    ui.status:SetText("Battle over")
  end
  if sim then
    ui.clock:SetText(fmtClock(sim.clock) .. " / " .. fmtClock(S.matchTicks)
      .. "   tick " .. sim.clock .. " / " .. S.matchTicks)
  else
    ui.clock:SetText("")
  end
end

local function paintKeeps(S, sim, mySide)
  ui.keepMine.name:SetText(S and shortOf(myName() or "You") or "")
  ui.keepFoe.name:SetText((S and S.opp) and shortOf(S.opp) or "")
  if not sim then
    ui.keepMine.hp:SetText("")
    ui.keepFoe.hp:SetText("")
    ui.keepMine.max:SetText("")
    ui.keepFoe.max:SetText("")
    ui.keepMine.fill:Hide()
    ui.keepFoe.fill:Hide()
    return
  end
  ui.keepMine.max:SetText("/ " .. Rules.C.KEEP_HP)
  ui.keepFoe.max:SetText("/ " .. Rules.C.KEEP_HP)
  keepSet(ui.keepMine, sim.sides[mySide].keepHp)
  keepSet(ui.keepFoe, sim.sides[3 - mySide].keepHp)
end

local function paintEco(S, sim, mySide)
  if not sim then
    ui.eco:SetText("")
    ui.ecoFoe:SetText("")
    ui.score:SetText("")
    return
  end
  local C = Rules.C
  local m = sim.sides[mySide]
  local e = sim.sides[3 - mySide]
  local secs = fmtSecs1(C.LEVY_EVERY)
  ui.eco:SetText("You   Levy " .. m.bank .. " / " .. bankCapOfSide(m)
    .. "    +" .. incomeOf(m) .. " every " .. secs .. " s")
  ui.ecoFoe:SetText("Foe   Levy " .. e.bank .. " / " .. bankCapOfSide(e)
    .. "    +" .. incomeOf(e) .. " every " .. secs .. " s")
  -- the live tiebreak score, from the 20% mark (Q10's SCORE_SHOW_TICK)
  if sim.clock >= C.SCORE_SHOW_TICK or sim.over then
    ui.score:SetText("Score (you : foe)   keep damage " .. m.keepDamageDealt
      .. " : " .. e.keepDamageDealt
      .. "  -  slots razed " .. m.slotsDestroyed .. " : " .. e.slotsDestroyed
      .. "  -  deepest hold " .. depthSumOf(m) .. " : " .. depthSumOf(e))
  else
    ui.score:SetText("")
  end
end

local function paintCommands(S, sim, mySide)
  local playing = (S ~= nil) and S.phase == "play" and (sim ~= nil)
  local bank = playing and sim.sides[mySide].bank or 0
  for i = 1, #ui.unitBtns do
    local b = ui.unitBtns[i]
    b:SetEnabled(playing)
    -- affordability greying only: an unaffordable order still sends, and the
    -- sims judge it at the exec tick (the bank may have risen by then)
    b:SetAlpha((playing and bank < Rules.UNITS[i].cost) and 0.5 or 1)
  end
  for k = 1, #ui.bldBtns do
    local b = ui.bldBtns[k]
    b:SetEnabled(playing)
    b:SetAlpha((playing and bank < Rules.BUILDINGS[b.__ibBld].cost) and 0.5 or 1)
  end
  ui.cntText:SetText("x" .. deployCount)
  ui.cntMinus:SetEnabled(playing and deployCount > 1)
  ui.cntPlus:SetEnabled(playing and deployCount < Rules.C.MAX_UNITS_PER_ORDER)
  ui.clearBtn:SetEnabled(playing and armed ~= nil)
  if not playing then
    ui.armedText:SetText("")
  elseif armed and armed.unit then
    local u = Rules.UNITS[armed.unit]
    ui.armedText:SetText("Armed: " .. deployCount .. "x " .. titleCase(u.key)
      .. " (" .. (u.cost * deployCount) .. ") - click a lane")
  elseif armed and armed.bld then
    local br = Rules.BUILDINGS[armed.bld]
    ui.armedText:SetText("Armed: " .. titleCase(br.key) .. " (" .. br.cost
      .. ") - click one of your " .. ((br.slotClass == "front") and "F" or "B") .. " squares")
  else
    ui.armedText:SetText("Pick a unit or a building, then click the board")
  end
  -- the cancel button's label tracks the phase; the SEMANTICS are part 1's,
  -- unchanged (join/handshake cancel, play concede-void, done close)
  if not S or S.phase == "done" then
    ui.cancel:SetText("Close")
  elseif S.phase == "play" then
    ui.cancel:SetText("Concede (void)")
  else
    ui.cancel:SetText("Cancel battle")
  end
end

local function paintNet(S, sim, mySide)
  if not (S and S.ep) then
    ui.net:SetText("")
    return
  end
  local st = S.ep.st
  local orders = ""
  if sim then
    local sd = sim.sides[mySide]
    orders = "   orders ok " .. sd.cmdsExecuted .. " fizzled " .. sd.cmdsFizzled
  end
  ui.net:SetText("net sent " .. st.sent .. " recv " .. st.recv
    .. "  late " .. st.late .. " rollbacks " .. st.rollbacks .. orders)
end

local function paintOverlay(S)
  if not S then
    ui.overlay:SetText("No battle.\n/pgd ib opens the start dialog.")
    ui.overlay:Show()
    return
  end
  if S.phase == "join" then
    ui.overlay:SetText("Waiting for an opponent... "
      .. math.max(0, floor(S.joinDeadline - GetTime())) .. " s\n"
      .. "Any party member on the DEV addon can join - the first to accept plays.")
    ui.overlay:Show()
  elseif S.phase == "handshake" then
    ui.overlay:SetText("Handshaking with " .. shortOf(S.opp or "?") .. "...")
    ui.overlay:Show()
  elseif S.phase == "done" then
    ui.overlay:SetText(tostring(S.endText or "Done."))
    ui.overlay:Show()
  else
    ui.overlay:Hide()
  end
end

-------------------------------------------------------------------------------
-- The result moment: the shared reveal stage (REVEAL.md) on a REAL verdict
-- (sim.over), queued so it must eventually show; a void ending gets a plain
-- stamp and no fanfare. Both are decoration behind fx-style pcall guards --
-- the authoritative outcome already landed in finishMatch's toast and the
-- window text (SKIN.md 6.7).
-------------------------------------------------------------------------------

-- Presentation prose for the hashed Q10 tier identifiers (Rules.TIERS): the
-- one display map keyed by ruleset values, because the ruleset stores
-- identifiers, not sentences.
local TIER_WORD = {
  keepHpRemoved = "keep damage dealt",
  slotsDestroyed = "buildings razed",
  penetration = "deepest push held",
  ownKeepHp = "keep left standing",
  draw = "dead even",
}

local function statRow(name, e, role, personal, place)
  return {
    text = name .. "  -  keep dmg " .. e.keepDamageDealt
      .. "  slots " .. e.slotsDestroyed .. "  depth " .. e.penetration
      .. "  kills " .. e.unitsKilled,
    role = role, personal = personal, place = place,
  }
end

local function maybeResult(S)
  local sim = S and S.ep and S.ep.sim
  if not (S and S.phase == "done" and sim and sim.over) then return end
  if S.uiResultShown then return end
  S.uiResultShown = true
  if not (PG.Theme and PG.Theme.RevealQueue) then return end
  local mySide = mySideOf(S)
  local r = sim:result()
  local me, foe = r.sides[mySide], r.sides[3 - mySide]
  local myN = shortOf(myName() or "You")
  local foeN = shortOf(S.opp or "Opponent")
  local won = (r.winner == mySide)
  local drew = (r.winner == 0)
  local subtitle
  if r.reason == "keep" then
    subtitle = drew and "Both keeps fell on the same tick"
      or (won and ("You razed " .. foeN .. "'s keep") or (foeN .. " razed your keep"))
  else
    local tierKey = Rules.TIERS[r.tier]
    subtitle = "The clock ran out - decided by " .. (TIER_WORD[tierKey or ""] or tostring(tierKey))
  end
  local rec = S
  local ok, err = pcall(PG.Theme.RevealQueue, {
    theme = "faire",
    variant = drew and "cascade" or "podium",
    anchor = { mode = "window", host = win },
    title = drew and "DRAW" or (won and "VICTORY" or "DEFEAT"),
    subtitle = subtitle,
    rows = {
      statRow(myN, me, drew and "body" or (won and "gold" or "loss"), true,
        (not drew) and (won and 1 or 2) or nil),
      statRow(foeN, foe, drew and "body" or (won and "loss" or "gold"), false,
        (not drew) and (won and 2 or 1) or nil),
      { text = fmtClock(r.tick) .. " of battle  -  "
          .. (me.unitsDeployed + foe.unitsDeployed) .. " units raised  -  "
          .. (me.cmdsExecuted + foe.cmdsExecuted) .. " orders", role = "fade" },
    },
    marquee = drew and "AN HONOURABLE DRAW"
      or ((won and myN or foeN):upper() .. " TAKES THE FIELD"),
    burst = won and "stars" or nil,
    burstCount = 12,
    sound = won and "cheer" or "page",
    -- ownership (CONCURRENCY.md 5.8 rule 2): culled if this record is gone
    validate = function() return sessions[rec.key] == rec end,
    priority = 1,   -- a 1v1 combatant is always seated in their own match
  })
  if not ok then geterrorhandler()(err) end
end

local function maybeVoidStamp(S)
  local sim = S and S.ep and S.ep.sim
  if not (S and S.phase == "done") then return end
  if sim and sim.over then return end
  if S.uiVoidShown then return end
  S.uiVoidShown = true
  fx("Stamp", win, "NO RESULT")
end

ShowWindow = function()
  if not engineOK() then
    toast("engine not loaded - check the .toc / syncaddon.sh.")
    return
  end
  ensureWindow()
  win:Show()
  RefreshUI()
end

RefreshUI = function()
  if not win then return end
  local S = mySession()
  local sim = S and S.ep and S.ep.sim or nil
  local mySide = S and mySideOf(S) or 1
  if not (S and S.phase == "play") then armed = nil end
  if S and S.phase == "play" and not S.uiBegun then
    S.uiBegun = true
    fx("Sound", "stamp")
  end
  if S and sim then prunePending(S, sim) end
  paintHeader(S, sim)
  paintOverlay(S)
  paintKeeps(S, sim, mySide)
  if sim then
    for i = 1, Rules.C.LANES do paintLane(i, S, sim, mySide) end
  else
    for i = 1, Rules.C.LANES do paintEmptyLane(i) end
  end
  paintEco(S, sim, mySide)
  paintCommands(S, sim, mySide)
  paintNet(S, sim, mySide)
  maybeVoidStamp(S)
  maybeResult(S)
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
