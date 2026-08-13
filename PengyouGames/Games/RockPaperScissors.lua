-- Games/RockPaperScissors.lua - group Rock Paper Scissors over addon messages.
-- Points only, ZERO gold: the ledger is never touched. Exactly one host (the
-- starter, who also plays); clients mirror the host's broadcasts and derive
-- ALL scoring locally from RESULT patterns, so every client lands on the same
-- standings deterministically. Sessions are stateless fun: an abort just ends
-- the game with a toast - nothing is ever "owed".
local ADDON, PG = ...

PG.RPS = {}

local TICK = 0.5            -- master ticker period (drives all session timing)
local HB_INTERVAL = 10      -- host heartbeat cadence
local HB_TIMEOUT = 35       -- client, group scope: host is dead after this silence
-- Wide scope (SCOPE.md 6.2): host and clients are no longer in the same content
-- by definition. The host can be inside an encounter (or an entire M+ run) where
-- the 12.1 comms lockdown refuses every send, while the client stands in a city
-- with a clear safety state. 35s of silence there is a paused game, not a dead
-- host, so the give-up point moves out and the quiet point only repaints.
local HB_QUIET_WIDE = 150
local HB_GIVEUP_WIDE = 300
local QUIET_SYNC_EVERY = 60 -- at most one heal request per minute while quiet
local REVEAL_SECS = 6       -- pause between RESULT and the next ROUND
local VOID_PAUSE_SECS = 3   -- pause between VOID and the replayed round
local BEGIN_PAUSE_SECS = 2  -- pause between BEGIN and round 1
local MIN_REOPEN_SECS = 3   -- floor for the timer when re-opening a frozen round
local MAX_ROWS = 14
local MAX_ROUNDS = 9
local ROSTER_CAP = 40
local SYNC_COOLDOWN = 10    -- min secs between SYNCQ handling per sender (and per client send)
local SYNC_MAX_REPLAY = 20  -- resync deltas above this many messages -> SYNCNO

-- Concurrency budgets (CONCURRENCY.md 2.1). Unlimited sessions may exist around
-- you, but this client tracks exactly ONE of them in full and keeps everything
-- else as a lightweight record: enough to show the invitation, drop its traffic
-- cheaply and resolve identity. These caps are what make "overheard sessions can
-- never accumulate" (7.3) checkable rather than hopeful.
local MAX_LITE = 8          -- overheard sessions remembered at once
local MAX_RECENT = 16       -- dead keys remembered
local RECENT_TTL = 120      -- secs a dead key stays poisoned against replay
local DONE_TTL = 60         -- secs a finished full record lingers before eviction
local LITE_TTL_PAD = 10     -- lite record lives (clamped joinSecs) + this
local LITE_TTL_MIN = 15
local LITE_TTL_MAX = 180
local SWEEP_EVERY = 4       -- ticks between registry sweeps (2s at TICK 0.5)
-- Busy / overflow throttles (CONCURRENCY.md 6.2): a popular guild starting five
-- games must never produce five lines.
local BUSY_THROTTLE = 60
-- The SCOPE.md 6.3 guild invite budget is shared by every module and lives in
-- Widgets next to AskCount: PG.UI.GuildAskOK / PG.UI.GuildAskSpend.

-- SCOPE.md 1.2: RPS is the one game permitted on every audience. Zero gold,
-- points only, medals persisted locally - the worst outcome of a hostile public
-- session is ninety wasted seconds and a bogus medal in your own SavedVariables.
-- Declared here and read by the picker; the OPEN handler drops any scope absent
-- from this table, so a game can never be dragged onto an audience it refuses.
PG.RPS.SCOPES = { group = true, guild = true, public = true }

-- Rock Paper Scissors CLAIMS the single round-based seat (CONCURRENCY.md I1)
-- despite being points-only: the seat is a rule about human attention, not
-- about gold. Declared here since 1.1.0 so the launcher's Join gate reads a
-- flag off the module rather than a list of module codes (BRIEF 1.1).
PG.RPS.SEAT = true

local MODULE_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors",
                      PB = "The Pull Book", DR = "Death Roll",
                      GB = "The Gambler", QZ = "Quiz" }

local THROW_WORD = { R = "ROCK", P = "PAPER", S = "SCISSORS" }
local VALID_THROW = { R = true, P = true, S = true }
-- Theme ASSETS keys (never raw paths; SKIN.md rule 0): all art routes
-- through PG.Theme so a pruned file has one central place to fix.
local CARD_ICON = { R = "rps_rock", P = "rps_paper", S = "rps_scissors" }
-- podium colors (literal, final standings places 1/2/3)
local PODIUM = { "|cffffd700", "|cffc0c0c0", "|cffcd7f32" }
local WHITE = "|cffffffff"

-- Faire palette, literal spec values; refreshed from PG.Theme.C at init when
-- the theme layer is present (the values are identical). Presentation only.
local P = {
  chgold = "|cffffd876", chgreen = "|cff7deda4", chred = "|cffff8a70",
  chgray = "|cffa8a89c",
  CHALK = { 0.95, 0.93, 0.87 }, CHGOLD = { 1.00, 0.85, 0.46 },
  CHGRAY = { 0.66, 0.66, 0.61 },
}

-------------------------------------------------------------------------------
-- The session registry (CONCURRENCY.md 2.1).
--
-- The single module-global `S` is gone. In its place: one FULL record (the one
-- session we host or sit in) plus bounded LITE records for sessions we merely
-- overhear. `S` itself does NOT disappear as a name - every function below still
-- opens with `local S = mySession()`, which is the whole point: the appliers,
-- the host logic, the resync machinery and the UI are untouched, and only the
-- OPEN path, the comm prologue and teardown had to learn about the registry.
--
-- Identity is the PAIR (host, token), never the token alone (3.2). The host name
-- is server-vouched and realm-qualified, so two hosts may mint the same token
-- and still never collide; the token only has to be unique within one
-- character's own history, which is what makes the new compact format safe.
-------------------------------------------------------------------------------

local sessions = {}   -- [key] = record, key = host .. "|" .. token
local mine            -- key of the ONE full record (hosted or seated), or nil
local recent = {}     -- [key] = GetTime() when it died; replay defence
local recentQ = {}    -- FIFO of poisoned keys, capped at MAX_RECENT
local regCount = 0    -- #sessions, kept incrementally (pairs() is never counted)
local liteCount = 0   -- lite records among them
local sweepTicks = 0

local ticker
local win, dialog, dlgInputs, dlgScope, dlgNote, dlgStart
local ui = {}
local rows = {}
local cardBtns = {}   -- pick char -> CardButton
local Theme           -- PG.Theme (nil if the theme layer is absent)

-- invitation throttles, all bounded (the guild budget itself is in Widgets)
local busyToastAt, busyPending = 0, 0
local overflowToastAt = 0

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt, hostOpen, clientRequestSync
local evict, endSession, refreshDialog
local fxJoined, fxBegin, fxRound, fxPick, fxResult, fxVoid, fxEnd

local function keyOf(host, token) return host .. "|" .. token end

-- The one full record, or nil. Every function that used to read the module
-- global reads this instead, and the body below it is unchanged.
local function mySession() return mine and sessions[mine] or nil end

local function myName() return PG.FullName("player") end

local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

-- wire-field validation: non-secret, numeric, floored, in [lo, hi]; else nil
local function num(v, lo, hi)
  local n = PG.SafeNum(v)
  if not n then return nil end
  n = math.floor(n)
  if lo and n < lo then return nil end
  if hi and n > hi then return nil end
  return n
end

-- RESULT pattern: one char per participant in sorted-roster order, R/P/S/X
local function validPattern(p)
  if type(p) ~= "string" or #p < 1 or #p > ROSTER_CAP then return false end
  for i = 1, #p do
    local c = p:sub(i, i)
    if c ~= "R" and c ~= "P" and c ~= "S" and c ~= "X" then return false end
  end
  return true
end

-- Roster agreement fingerprint. RESULT patterns are positional over the sorted
-- roster and no name ever travels with an outcome, so a mirror whose roster has
-- the right SIZE but the wrong MEMBERS would score the wrong players (and
-- persist the wrong medals) with no error anywhere - a count comparison cannot
-- see it. Bytes are weighted by position inside a name (so anagrams differ) and
-- names by position in the list (so a swap is caught). O(roster bytes),
-- computed only at BEGIN/SYNCQ.
local function rosterDigest(list)
  local h = 0
  for i = 1, #list do
    local name = tostring(list[i] or "")
    local s = 0
    for k = 1, #name do s = s + name:byte(k) * k end
    h = (h + i * (s % 65536)) % 65536
  end
  return string.format("%04x", h)
end

-- wire-field validation for a digest: exactly four hex digits, or reject
local function isDigest(v)
  return type(v) == "string" and v:match("^%x%x%x%x$") ~= nil
end

local function allClear()
  -- Plain combat is deliberately absent here: it neither blocks addon sends
  -- (the 12.1 comms lockdown is encounter/M+/PvP-scoped, gated separately via
  -- PG.Comm.Locked()) nor pauses the game. Only an encounter, a ready check,
  -- a pull countdown or an addon restriction gates game progression.
  local s = PG.Safety.state
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

-- UI predicate only. It is NOT a gate any more: CONCURRENCY.md 0.2 deletes every
-- "a game is already running" refusal, because concurrent sessions are the point.
-- What survives is "does the one session I am in still matter to the window".
local function live()
  local S = mySession()
  return S ~= nil and S.phase ~= "done"
end

-- RPS toasts carry the dice mark; plain text when Theme is absent.
-- Attribution (CONCURRENCY.md 5.7): once this module knows about more than one
-- session, a bare "Rock Paper Scissors: ..." cannot tell a player in two
-- audiences WHICH game the line is about, so the host's name rides along. With a
-- single record the text is exactly what it always was.
local function toast(text, host, opts)
  local name = "Rock Paper Scissors"
  if host and regCount > 1 then name = name .. " (" .. shortOf(host) .. ")" end
  local line = name .. ": " .. text
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then line = m .. " " .. line end
  end
  PG.UI.Toast(line, opts)
end

-- FX runner: decoration only - errors are reported and swallowed, so no
-- animation/sound problem can ever touch game state or the wire.
local function runFX(fn, arg)
  if not Theme or not fn then return end
  local ok, err = pcall(fn, arg)
  if not ok then geterrorhandler()(err) end
end

-- Every send carries the session's own scope (SCOPE.md 2.2). Only the involved
-- record ever broadcasts - a lite record has nothing to say and never consumes a
-- token from the shared 10-token bucket - so resolving mySession() here keeps all
-- fifteen call sites below byte-identical to 0.5.x.
local function broadcast(mtype, ...)
  local S = mySession()
  if not S then return false end
  return PG.Comm.Broadcast(S.scope, "RPS", mtype, S.token, ...)
end

-- One ticker per module, as before (I9). It now runs while the REGISTRY is
-- non-empty rather than while a session is live, because sweeping lite and dead
-- records is its second job; it stops the moment the last record goes.
local function startTicker()
  if ticker then return end
  ticker = PG.Ticker(TICK, function()
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

-------------------------------------------------------------------------------
-- Registry primitives: identity, poisoning, listing, eviction.
-------------------------------------------------------------------------------

-- Wire token validation (CONCURRENCY.md 3.4). Tokens are opaque strings to every
-- reader; only the length and the field separator matter.
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

-- Token format of CONCURRENCY.md 3.2: a persisted, monotonic per-character
-- counter plus a 3-char random seatbelt, base-36. Typically 6 bytes against the
-- old realm-less "Thrall-48120" (up to 18), so the format pays for the scope
-- byte several times over. The counter is incremented AND persisted before the
-- OPEN is broadcast, so a crash cannot reissue a number; the random suffix only
-- covers a SavedVariables rollback, where the counter can go backwards.
-- PG.NextToken is preferred when Core provides it, so the counter stays shared
-- across modules (which only makes it more monotonic, never less).
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

-- A finished session's key can never be resurrected (4.5): re-broadcasting its
-- OPEN after the fact does nothing on any client for RECENT_TTL.
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

-- The launcher's Open games list is a VIEW of the lite records (5.10 rule 2),
-- never a second store: rows appear with the record and vanish with it. Both
-- calls are existence-guarded, so this file has no dependency on the launcher
-- shipping its list.
local function listOpen(rec)
  rec.listed = true
  if PG.Launcher and PG.Launcher.AddOpenGame then
    pcall(PG.Launcher.AddOpenGame, {
      game = "RPS", host = rec.host, token = rec.token, scope = rec.scope,
      expires = rec.expires, key = rec.key,
    })
  end
end

local function unlistOpen(rec)
  if not rec.listed then return end
  rec.listed = false
  if PG.Launcher and PG.Launcher.RemoveOpenGame then
    pcall(PG.Launcher.RemoveOpenGame, "RPS", rec.host, rec.token)
  end
end

local function register(rec)
  sessions[rec.key] = rec
  regCount = regCount + 1
  if rec.kind == "lite" then liteCount = liteCount + 1 end
  syncTicker()
end

-- The ONLY place a record leaves the registry, and it always poisons the key.
-- A dead session takes its invitation and its launcher row with it (5.6 rule 4):
-- a cancelled game must never leave a live countdown popup inviting you into
-- nothing. Evicting the involved record also frees the seat and hides the window
-- (5.9), so a replaced session cannot leave a fully drawn, live-looking one.
-- keepWindow leaves a FINISHED game's final standings on screen while its
-- record steps aside for a new one (4.3): superseding a done session, or
-- starting/joining the next game, must not yank the podium and the standings
-- out from under the player who is still reading them. Every other caller -
-- withdrawal, a live session replaced, the DONE_TTL sweep - hides, because a
-- window left behind by a session that no longer exists looks live (5.9).
evict = function(key, keepWindow)
  local rec = sessions[key]
  if not rec then return end
  sessions[key] = nil
  regCount = regCount - 1
  if rec.kind == "lite" then
    liteCount = liteCount - 1
  end
  PG.UI.Dismiss(rec.askKey)
  rec.askKey = nil
  unlistOpen(rec)
  if mine == key then
    mine = nil
    PG.Session.Release("RPS", rec.token)
    if win and not keepWindow then win:Hide() end
  end
  poison(key)
  syncTicker()
end

-------------------------------------------------------------------------------
-- Teardown (CONCURRENCY.md 7.1). The instant phase becomes "done", in order:
-- the seat is released (a new game may start NOW - the reveal stage, the podium
-- and the results window are decoration and never hold it), the invitation comes
-- down, the launcher row goes, and the window keeps its final standings until
-- DONE_TTL sweeps the record away.
-------------------------------------------------------------------------------

endSession = function(text)
  local S = mySession()
  if not S then return end
  S.phase = "done"
  S.roundOpen = false
  S.endText = text
  S.doneAt = GetTime()
  PG.Session.Release("RPS", S.token)
  PG.UI.Dismiss(S.askKey)
  S.askKey = nil
  unlistOpen(S)
  if win then ui.bar:Stop() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Standings: cumulative points, dense ranking (ties share a place: 1,1,2,3).
-- Sorted points desc then name asc (byte order) - identical on every client.
-------------------------------------------------------------------------------

local function computeStandings()
  local S = mySession()
  if not S then return {} end
  local list = {}
  for _, name in ipairs(S.roster) do
    list[#list + 1] = { name = name, pts = S.totals[name] or 0 }
  end
  table.sort(list, function(a, b)
    if a.pts ~= b.pts then return a.pts > b.pts end
    return a.name < b.name
  end)
  local place, lastPts = 0, nil
  for i = 1, #list do
    if list[i].pts ~= lastPts then
      place = place + 1
      lastPts = list[i].pts
    end
    list[i].place = place
  end
  return list
end

-- Tiny persisted medal tally: +1 for every player tied for 1st at session END.
-- Only plain strings/numbers ever reach SavedVariables (platform rule 2.5).
local function persistMedals(winners)
  if type(PG.db) ~= "table" then return end
  if type(PG.db.rps) ~= "table" then PG.db.rps = { medals = {} } end
  if type(PG.db.rps.medals) ~= "table" then PG.db.rps.medals = {} end
  local m = PG.db.rps.medals
  for i = 1, #winners do
    local name = winners[i]
    if not PG.IsSecret(name) and type(name) == "string" and name ~= "" then
      local cur = m[name]
      if PG.IsSecret(cur) or type(cur) ~= "number" then cur = 0 end
      m[name] = math.floor(cur) + 1
    end
  end
end

local function myMedalCount()
  local me = myName()
  local db = PG.db and PG.db.rps
  local m = (type(db) == "table") and db.medals or nil
  local n = (me and type(m) == "table") and m[me] or nil
  if not PG.IsSecret(n) and type(n) == "number" then return math.floor(n) end
  return 0
end

-------------------------------------------------------------------------------
-- Shared state transitions. The host applies these locally at send time (the
-- section-6 loopback rule); clients apply them on receipt of host broadcasts.
-------------------------------------------------------------------------------

local function applyJoined(name)
  local S = mySession()
  if not S then return end
  -- normal path: join phase. Resync replays land here too: a desynced
  -- spectator mid-play accepts the replayed JOINED/LEFT stream to repair
  -- its roster (idempotent - a duplicate JOINED never double-adds).
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if not S.joined[name] then
    S.joined[name] = true
    S.roster[#S.roster + 1] = name
    table.sort(S.roster) -- plain byte-order sort: the spec's "sorted roster"
  end
  if name == myName() and S.phase == "join" then
    S.joinAccepted = true
    ShowWindow()
    if win then ui.bar:Start(math.max(1, (S.joinDeadlineDisplay or GetTime()) - GetTime())) end
  end
  RefreshUI()
  if S.phase == "join" then runFX(fxJoined, name) end
end

local function applyLeft(name)
  local S = mySession()
  if not S then return end
  -- same relaxation as applyJoined: resync replays repair a spectator roster
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if S.joined[name] then
    S.joined[name] = nil
    for i = #S.roster, 1, -1 do
      if S.roster[i] == name then table.remove(S.roster, i) end
    end
  end
  if name == myName() and not S.isHost then
    -- Withdrawal (CONCURRENCY.md 7.2): leaving now STOPS this client tracking
    -- the game. It is one of the two paths besides endSession allowed to free
    -- the seat (I2), and it evicts rather than lingering, because a mirror of a
    -- game you walked out of is exactly the state 0.5.x accumulated forever.
    -- Rejoining afterwards is out of scope (9.5).
    S.joinAccepted = false
    evict(S.key)
    return
  end
  RefreshUI()
end

-- dig (optional): the host's roster fingerprint at BEGIN. Absent (a peer that
-- predates the field) degrades to the count-only check.
local function applyBegin(count, rounds, dig)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" then
    -- BEGIN while playing is ignored (totals are never re-built once play
    -- has begun, so replayed RESULTs can never double-count) - EXCEPT that a
    -- client which missed BEGIN entirely (forced spectator, S.count == nil)
    -- absorbs the original fields so resync agreement can be evaluated.
    if S.phase == "play" and S.spectator and S.count == nil then
      S.count = count
      S.rounds = rounds
      S.digest = dig
      RefreshUI()
    end
    return
  end
  S.phase = "play"
  S.count = count
  S.rounds = rounds
  S.digest = dig
  S.totals = {}
  for _, n in ipairs(S.roster) do S.totals[n] = 0 end
  local me = myName()
  -- Our mirror agrees with the host in SIZE and in MEMBERSHIP, so it is not a
  -- desync we could resync out of - it is the host's roster, and we are not in
  -- it. Our JOIN never landed (a lockdown ate the whisper, or the join window
  -- closed first). Tracking a game we cannot play is pointless, and the seat is
  -- not: while we hold it every other invitation is silently downgraded to a
  -- launcher row for the whole session (CONCURRENCY.md 7.2, every scope). A
  -- referee host is absent from its own roster by design (I5), hence isHost.
  local agrees = (#S.roster == count) and (not dig or rosterDigest(S.roster) == dig)
  if not S.isHost and agrees and not (me and S.joined[me]) then
    toast("your join did not reach the host - you are not in this game.", S.host,
      { key = "rps-status" })
    endSession("You are not in this game.")
    evict(S.key)
    return
  end
  if not S.isHost and not agrees then
    -- our JOINED/LEFT stream disagrees with the host in size or in membership:
    -- we cannot map the pattern to names, so we spectate - and immediately ask
    -- the host to replay what we missed (resync can restore us to a player).
    -- The flag also gates the repair: applyJoined/applyLeft only accept
    -- replayed ops for a spectator mid-play.
    S.spectator = true
    toast("out of sync with the host - resyncing...", S.host, { key = "rps-status" })
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxBegin)
end

local function applyRound(r, secs)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  if r < S.r then return end -- stale/late resync replay: never regress the round
  if r ~= S.r then
    S.r = r
    S.myPick = nil
    S.picks = {}
  end
  -- a repeat ROUND for the current r is just a timer refresh (freeze re-open):
  -- locked throws stay locked. A replay after VOID reads as a fresh round
  -- because applyVoid rewinds S.r.
  S.deadline = GetTime() + secs
  S.roundOpen = true
  ShowWindow()
  if win then ui.bar:Start(secs) end
  RefreshUI()
  runFX(fxRound)
end

local function applyResult(r, pattern)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  -- resync idempotency: a RESULT for a round whose points were already
  -- applied is skipped outright - standings/medals derive from accumulated
  -- RESULTs, so a point must never count twice
  if S.appliedResults[r] then return end
  -- resync replays of PAST rounds only accumulate points; only a result at
  -- or ahead of the round we are in touches the live round state
  local current = r >= S.r
  if current then
    S.roundOpen = false
    S.myPick = nil
  end
  local nR, nP, nSc, nX = 0, 0, 0, 0
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    if c == "R" then nR = nR + 1
    elseif c == "P" then nP = nP + 1
    elseif c == "S" then nSc = nSc + 1
    else nX = nX + 1 end
  end
  -- group-RPS scoring: one point per player you beat. Rock beats each
  -- scissors, paper beats each rock, scissors beats each paper; X beats
  -- nobody and scores 0. Everyone identical -> the beaten count is 0 anyway.
  local gain = { R = nSc, P = nR, S = nP, X = 0 }
  local me = myName()
  local myGain, myChar
  if #pattern == #S.roster then -- never true while the roster is desynced
    S.appliedResults[r] = true
    for i, name in ipairs(S.roster) do
      local c = pattern:sub(i, i)
      S.totals[name] = (S.totals[name] or 0) + gain[c]
      if name == me then
        myGain, myChar = gain[c], c
      end
    end
  end
  if current then
    S.lastResult = { r = r, pattern = pattern, nR = nR, nP = nP, nS = nSc, nX = nX,
                     myGain = myGain, myChar = myChar }
    S.lastResultText = "Round " .. r .. ": Rock " .. nR .. " - Paper " .. nP
      .. " - Scissors " .. nSc .. (nX > 0 and (" - " .. nX .. " sat out") or "")
    ShowWindow()
    if win then ui.bar:Stop() end
  end
  RefreshUI()
  if r == S.r then runFX(fxResult) end
end

local function applyVoid(r)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  S.roundOpen = false
  S.myPick = nil
  S.picks = {} -- previous throws for this round are discarded
  S.lastResult = nil
  S.lastResultText = "Round " .. r .. " was interrupted by the encounter - it will be replayed."
  S.r = r - 1 -- the re-broadcast ROUND r then reads as a fresh round everywhere
  ShowWindow()
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxVoid)
end

local function applyEnd()
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  local standings = computeStandings()
  S.standings = standings
  local winners = {}
  for i = 1, #standings do
    if standings[i].place == 1 then winners[#winners + 1] = standings[i].name end
  end
  local me = myName()
  -- Participation gate, SCOPE.md 4.4 G1 applied to medals. Three refusals in
  -- one test: a desynced spectator never applied RESULTs so its totals are
  -- wrong; a referee host (I5) has no stake in its own game; and a client that
  -- merely overheard the session never had a record to begin with. Outside the
  -- party, only the local player's medal is persisted - a stranger's medal count
  -- is not local-hall-of-fame material.
  if (not S.spectator) and S.joinAccepted and me and S.joined[me] then
    if S.scope == "group" then
      persistMedals(winners)
    else
      for i = 1, #winners do
        if winners[i] == me then persistMedals({ me }) end
      end
    end
  end
  S.ended = true
  local text
  if S.spectator then
    text = "Game over."
  else
    local mine = false
    for i = 1, #winners do
      if winners[i] == me then mine = true end
    end
    if mine then
      text = (#winners > 1) and "you tied for the win!" or "you win!"
    elseif winners[1] then
      text = shortOf(winners[1]) .. ((#winners > 1) and " and friends take it." or " takes it.")
    else
      text = "done!"
    end
    text = "Game over - " .. text
  end
  -- medals are this game's money: the line is never dropped for queue space
  toast(text, S.host, { priority = "result" })
  ShowWindow()
  endSession(text)
  runFX(fxEnd)
end

local function applyCancel(reason)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local text
  if reason == "few" then
    -- CONCURRENCY.md 6.3: no BUSY message exists and none will, so the honest
    -- version of "nobody joined" says why that can happen.
    text = "Cancelled - not enough players joined. Others may be busy or away."
    if S.isHost and S.scope == "guild" then
      -- SCOPE.md 2.4: an open Blizzard bug means a rank that cannot speak in
      -- guild chat cannot SEND on the GUILD distribution either, so the host's
      -- OPEN reached nobody. There is no probe for it; this is the diagnostic.
      text = "Nobody joined. If your guild rank can't speak in guild chat, guild games can't be started from this character."
    end
  elseif reason == "host" then
    text = "Cancelled by the host."
  else
    text = "Cancelled (" .. tostring(reason) .. ")."
  end
  toast(text, S.host)
  endSession(text)
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

-- Resync history: the host retains the ordered JOINED/LEFT stream, BEGIN's
-- fields and every RESULT's exact original fields so desynced clients
-- (loading screens, encounter gaps) can be healed by replaying precisely
-- what they missed (see hostHandleSyncQ).
local function hostRecordOp(op, name)
  local S = mySession()
  if not S then return end
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

local function hostStartRound(r)
  local S = mySession()
  if not S then return end
  if broadcast("ROUND", r, S.roundSecs) then
    applyRound(r, S.roundSecs)
  else
    S.nextRoundAt = GetTime() + 2 -- send refused; the ticker retries
  end
end

local function hostAdvance(delay)
  local S = mySession()
  if not S then return end
  if S.r >= S.rounds then
    S.endPending = true -- END goes out on the next clear tick
  else
    S.nextRoundAt = GetTime() + delay
  end
end

local function hostResolveRound()
  local S = mySession()
  if not S then return end
  local chars = {}
  for i, name in ipairs(S.roster) do
    local p = S.picks[name]
    if not VALID_THROW[p] then p = "X" end
    chars[i] = p
  end
  local pattern = table.concat(chars)
  if not broadcast("RESULT", S.r, pattern) then
    return -- send refused; the ticker re-resolves next clear tick
  end
  S.hist.results[S.r] = pattern -- exact original fields, retained for resync
  if S.r > S.hist.resultTop then S.hist.resultTop = S.r end
  applyResult(S.r, pattern)
  hostAdvance(REVEAL_SECS)
end

-- Encounter/restriction broke the round: VOID it, then replay the SAME round
-- number fresh (applyVoid rewinds S.r, so the ticker's r+1 is the same round).
local function hostVoidRound()
  local S = mySession()
  if not S then return end
  local r = S.r
  if broadcast("VOID", r) then
    S.broken = false
    S.frozen = false
    applyVoid(r)
    S.nextRoundAt = GetTime() + VOID_PAUSE_SECS
  end
end

-- assigned below, once allPicked and hostResolveRound exist; declared here so
-- hostReopenRound can call it
local maybeEarlyFinish

local function hostReopenRound()
  local S = mySession()
  if not S then return end
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.freezeRemaining or 0))
  -- clients treat a repeat ROUND for a known r as a timer refresh
  if broadcast("ROUND", S.r, secs) then
    S.frozen = false
    S.deadline = GetTime() + secs
    ShowWindow()
    if win then ui.bar:Start(secs) end
    RefreshUI()
    -- the last throw may have landed DURING the freeze, in which case there is
    -- nobody left to wait for and the re-opened timer would just burn down
    maybeEarlyFinish()
  end
end

local function hostEnd()
  local S = mySession()
  if not S then return end
  if S.endSent then return end -- END is already on the wire; onSent finishes up
  -- Medals persist (and the podium reveals) only once END has actually left
  -- the wire: a queued-then-lockdown-dropped END aborts via onDrop instead,
  -- with no medals anywhere - the same all-or-nothing shape as LG's ledger.
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      -- the callback can fire a second or more later: re-resolve, and refuse
      -- unless this exact record is still the involved one (5.8 rule 2's
      -- ownership test, applied to a send rather than to a reveal payload)
      local cur = mySession()
      if cur ~= sess or sessions[sess.key] ~= sess or cur.phase ~= "play" then return end
      cur.endPending = nil
      applyEnd()
    end,
  }, "RPS", "END", S.token)
  if ok then S.endSent = true end
end

local function hostCancel(reason)
  local S = mySession()
  if not S then return end
  -- END is already on the wire: clients will persist medals when it lands, so
  -- the host must complete too - no abort may interleave after END is queued
  if S.endSent then return end
  -- best effort: if the broadcast is refused, clients fall back to the
  -- heartbeat timeout; either way nothing is owed
  broadcast("CANCEL", reason)
  applyCancel(reason)
end

local function hostCloseJoin()
  local S = mySession()
  if not S or S.phase ~= "join" then return end
  -- a referee host is absent from its own roster (I5), so this minimum now
  -- means two OTHER players, which is exactly what a game needs
  local count = #S.roster
  if count < 2 then
    if broadcast("CANCEL", "few") then
      applyCancel("few")
    else
      S.joinDeadline = GetTime() + 2 -- send refused; retry shortly
    end
    return
  end
  local dig = rosterDigest(S.roster) -- membership, not just size (4 bytes)
  if broadcast("BEGIN", count, S.rounds, dig) then
    -- BEGIN fields retained for resync replays
    S.hist.beginCount, S.hist.beginDigest = count, dig
    applyBegin(count, S.rounds, dig)
    S.nextRoundAt = GetTime() + BEGIN_PAUSE_SECS
  else
    S.joinDeadline = GetTime() + 2
  end
end

local function hostHandleJoin(sender)
  local S = mySession()
  if not S or S.phase ~= "join" or S.joined[sender] then return end -- duplicate JOINs idempotent
  if #S.roster >= ROSTER_CAP then return end
  if broadcast("JOINED", sender) then
    hostRecordOp("J", sender)
    applyJoined(sender)
  end
end

local function hostHandleUnjoin(sender)
  local S = mySession()
  if not S or S.phase ~= "join" or sender == S.host or not S.joined[sender] then return end
  if broadcast("LEFT", sender) then
    hostRecordOp("L", sender)
    applyLeft(sender)
  end
end

-- Everyone seated has thrown: nobody is waiting on anybody, so the round
-- resolves now instead of burning the rest of the timer. The deadline stays
-- as the fallback for anyone AFK (a missing throw is an X, as always). A
-- resynced player held out of the open round simply never completes the set,
-- so that round quietly falls back to the timer - never an early resolve that
-- would strand them.
local function allPicked()
  local S = mySession()
  if not S then return false end
  local n = #S.roster
  if n < 2 then return false end
  for i = 1, n do
    if not S.picks[S.roster[i]] then return false end
  end
  return true
end

-- The early-finish test, in one place: both entry points (a throw landing, and
-- a frozen round re-opening with every throw already in) use exactly the
-- ticker's deadline-branch gating - never while frozen/broken or during an
-- encounter/lockdown.
maybeEarlyFinish = function()
  local S = mySession()
  if not S or S.phase ~= "play" or not S.roundOpen or S.broken or S.frozen then return end
  if not (allPicked() and allClear() and not PG.Comm.Locked()) then return end
  hostResolveRound()
end

local function hostHandlePick(sender, r, c)
  local S = mySession()
  if not S or S.phase ~= "play" or not S.roundOpen or S.broken then return end
  if r ~= S.r or not VALID_THROW[c] then return end
  if not S.joined[sender] then return end
  if S.picks[sender] then return end -- first click locks
  S.picks[sender] = c
  RefreshUI()
  maybeEarlyFinish()
end

-- one replay entry; the explicit arity keeps trailing nils out of the wire
-- (a literal "nil" field used to travel on every JOINED/LEFT replay)
local function pushMsg(out, ...)
  local m = { ... }
  m.n = select("#", ...)
  out[#out + 1] = m
end

-- Resync: a client whispered SYNCQ (its phase, contiguously-applied RESULT
-- round, roster count and roster digest). Replay whatever it missed BY WHISPER using the
-- ORIGINAL message types and field layouts - the full JOINED/LEFT stream if
-- its roster count disagrees, BEGIN if its phase trails, the missing RESULTs
-- in order, then the live ROUND with its real remaining seconds. Nothing
-- missing -> SYNCOK; a delta over SYNC_MAX_REPLAY messages -> SYNCNO (the
-- client stays spectator for the session).
local function hostHandleSyncQ(sender, phase, rApplied, rosterN, dig)
  local S = mySession()
  if not S then return end
  if phase ~= "join" and phase ~= "play" then return end
  if not (rApplied and rosterN) then return end
  if dig ~= nil and not isDigest(dig) then return end -- malformed field: reject
  if PG.Comm.Locked() then return end -- the client retries after its cooldown
  local now = GetTime()
  local last = S.syncAsk[sender]
  if last and (now - last) < SYNC_COOLDOWN then return end -- per-sender rate limit
  S.syncAsk[sender] = now
  local out = {}
  if rosterN ~= #S.roster or (dig and dig ~= rosterDigest(S.roster)) then
    -- replay the full ordered stream: idempotent application converges any
    -- subset roster onto the host roster exactly (each name ends in the
    -- state of its last op). A same-size/different-membership roster is
    -- caught by the digest alone.
    for i = 1, #S.hist.ops do
      local op = S.hist.ops[i]
      pushMsg(out, (op.op == "J") and "JOINED" or "LEFT", op.name)
    end
  end
  if S.phase == "play" then
    if phase == "join" then
      -- the roster cannot change after BEGIN, so the live digest IS the BEGIN
      -- one; the fallback only covers a history that predates the field
      pushMsg(out, "BEGIN", S.hist.beginCount or S.count, S.rounds,
              S.hist.beginDigest or rosterDigest(S.roster))
    end
    for r = rApplied + 1, S.hist.resultTop do
      if S.hist.results[r] then
        pushMsg(out, "RESULT", r, S.hist.results[r])
      end
    end
    if #out > 0 and S.roundOpen and not S.broken and not S.frozen and S.r >= 1 then
      local remain = math.max(1, math.ceil((S.deadline or now) - now))
      pushMsg(out, "ROUND", S.r, remain)
    end
  end
  if #out > SYNC_MAX_REPLAY then
    PG.Comm.Whisper(sender, "RPS", "SYNCNO", S.token)
    return
  end
  if #out == 0 then
    PG.Comm.Whisper(sender, "RPS", "SYNCOK", S.token)
    return
  end
  -- replay whispers reuse CRITICAL_DROP mtypes: shield onDrop while the send
  -- queue drains (see REPLAYABLE) so a lockdown-dropped replay whisper never
  -- aborts the live game - the asking client simply retries later
  S.syncReplayUntil = now + 30
  for i = 1, #out do
    local m = out[i]
    PG.Comm.Whisper(sender, "RPS", m[1], S.token, unpack(m, 2, m.n))
  end
end

-- Why Start may be blocked, and whether it is blocked at all (CONCURRENCY.md
-- 6.4). Returns (note, canStart). The old blanket "a game is already running" is
-- gone: hosting is never blocked by another module or by anyone else's session
-- (I4), and the ONLY refusal left is I3 - this module already holds a full
-- record, because its window, roster rows and card buttons are singletons.
local function involvement()
  local S = mySession()
  if S and S.phase ~= "done" then
    if S.isHost then
      return "You're already running a Rock Paper Scissors game. Cancel it first, or wait for it to finish.", false
    end
    return "You're playing " .. shortOf(S.host)
      .. "'s Rock Paper Scissors game. You can start your own when it's over.", false
  end
  local seat = PG.Session.Seat()
  if seat and seat.module ~= "RPS" then
    -- Referee hosting (I5): you play one round-based game and run the other.
    return "You're playing " .. (MODULE_NAME[seat.module] or seat.module)
      .. ", so you'll run this game without playing in it.", true
  end
  return nil, true
end

hostOpen = function(rounds, joinSecs, roundSecs, scope)
  local note, canStart = involvement()
  if not canStart then
    toast(note)
    return
  end
  local host = myName()
  if not host then return end
  scope = PG.SafeStr(scope) or "group"
  if not PG.RPS.SCOPES[scope] then return end
  -- availability is re-checked at the moment Start is pressed (SCOPE.md 1.3):
  -- the player can /gquit, leave the group or hit the channel cap between
  -- opening the dialog and clicking. Never fall back to another audience.
  local okScope, why = PG.Comm.ScopeAvailable(scope)
  if not okScope then
    toast(why or "that audience isn't available.")
    if dlgScope and dialog and dialog:IsShown() then pcall(dlgScope.Refresh, dlgScope) end
    return
  end
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  -- The counter behind the token is persisted BEFORE the OPEN goes out, so a
  -- crash cannot reissue a number (3.2).
  local token = nextToken()
  -- broadcast OPEN before touching any record: a submit-time lockdown drop
  -- invokes onDrop synchronously, and a token with no record is ignored there.
  -- A refused broadcast therefore leaves everything exactly as it was and the
  -- retry is legitimate (4.3).
  if not PG.Comm.Broadcast(scope, "RPS", "OPEN", token, rounds, joinSecs, roundSecs, code) then
    toast("cannot start right now (addon messages are blocked).")
    return
  end
  -- Superseding OURSELVES (4.3): the finished record is replaced by the new
  -- game, which is what Play again does. A LIVE one refused above, so a
  -- double-click can never emit two OPENs.
  local prev = mySession()
  -- the previous record can only be a FINISHED one (a live one refused above),
  -- so its standings stay up until ShowWindow repaints them for the new game
  if prev then evict(prev.key, true) end
  -- I5: hosting never fails on the seat. ClaimHost cannot refuse; it only
  -- reports whether we are a player in our own game or its referee.
  local seated = PG.Session.ClaimHost("RPS", token, host)
  local key = keyOf(host, token)
  local rec = {
    kind = "full",
    key = key,
    token = token,
    host = host,
    scope = scope,           -- immutable for the life of the session (SCOPE.md 3.1)
    isHost = true,
    seated = seated,
    refereed = not seated,
    rounds = rounds,
    joinSecs = joinSecs,
    roundSecs = roundSecs,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    picks = {},
    r = 0,
    appliedResults = {},
    hist = { ops = {}, results = {}, resultTop = 0 }, -- resync replay history
    syncAsk = {}, -- per-sender SYNCQ rate limiting
    joinDeadline = GetTime() + joinSecs,
    joinDeadlineDisplay = GetTime() + joinSecs,
    lastHBSent = GetTime(),
  }
  register(rec)
  mine = key
  if seated then
    if broadcast("JOINED", host) then
      hostRecordOp("J", host)
      applyJoined(host) -- host auto-joins
    end
  end
  -- a sync lockdown drop of JOINED (critical) aborts via onDrop above
  if not live() then return end
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

local function doThrow(c)
  local S = mySession()
  -- gate l (5.2): a local action requires the INVOLVED record and a seat in it.
  -- A referee host has no throw, which is what "runs the game" means.
  if not S or not S.seated then return end
  if S.phase ~= "play" or not S.roundOpen then return end
  if S.spectator or S.myPick then return end
  if S.syncHoldR == S.r then return end -- resynced mid-round: back in NEXT round
  local me = myName()
  if not me or not S.joined[me] then return end
  if S.isHost then
    S.myPick = c
    hostHandlePick(me, S.r, c)
  else
    -- lock only if the whisper was actually accepted for send, so the UI
    -- never claims a lock the host can never have seen
    if PG.Comm.Whisper(S.host, "RPS", "PICK", S.token, S.r, c) then
      S.myPick = c
    end
  end
  RefreshUI()
  if S.myPick == c then runFX(fxPick, c) end
end

-- The full-record constructor (I7). It is reachable from exactly two places -
-- the invitation's Accept callback and the launcher's Join button - and from
-- nowhere else, which is what "no session state without consent" means: an
-- overheard OPEN at ANY scope, group included, creates a lite record and
-- nothing more.
local function clientAccept(rec)
  if not rec or rec.kind ~= "lite" or sessions[rec.key] ~= rec then return false end
  local cur = mySession()
  if cur and cur.phase == "done" then
    -- a finished record is not an INVOLVED one: the seat went at endSession and
    -- it survives only to show final standings. Replace it rather than refusing,
    -- and keep those standings up until the new game's window repaints them.
    evict(cur.key, true)
    cur = nil
  end
  if cur then
    -- I3: one involved session per module. Explanatory, never the old blanket
    -- line, and never a refusal caused by somebody else's session existing.
    toast("you're already in " .. (cur.isHost and "your own game"
      or (shortOf(cur.host) .. "'s game")) .. " - finish it first.", rec.host)
    return false
  end
  -- 5.6 rule 3: the seat is claimed FIRST. A genuine race (a JOINED landing
  -- from elsewhere in the same instant) loses here, and nothing is whispered.
  if not PG.Session.Claim("RPS", rec.token, rec.host) then
    toast("you just joined another game - not joining this one.", rec.host)
    return false
  end
  local cfg = rec.cfg
  local openedAt = rec.openedAt
  local askKey = rec.askKey
  PG.UI.Dismiss(askKey)
  unlistOpen(rec)
  sessions[rec.key] = nil
  regCount = regCount - 1
  liteCount = liteCount - 1
  local S = {
    kind = "full",
    key = rec.key,          -- same identity: lite and full are one session
    token = rec.token,
    host = rec.host,
    scope = rec.scope,
    isHost = false,
    seated = true,
    refereed = false,
    rounds = cfg.rounds,
    joinSecs = cfg.joinSecs,
    roundSecs = cfg.roundSecs,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    picks = {},
    r = 0,
    appliedResults = {},
    syncAllClear = allClear(), -- tracks all-clear transitions for resync
    lastHB = GetTime(),
    joinDeadlineDisplay = openedAt + cfg.joinSecs,
    joinAccepted = true,       -- provisional; the host's JOINED broadcast confirms
  }
  register(S)
  mine = S.key
  PG.Comm.Whisper(S.host, "RPS", "JOIN", S.token)
  ShowWindow()
  if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
  -- The record is built at ACCEPT time now, not when the OPEN arrived, so every
  -- JOINED that landed while the invitation sat on screen was missed. The
  -- existing resync protocol replays exactly that stream, so a late constructor
  -- converges on the host's roster with no new machinery (SCOPE.md 6.3).
  clientRequestSync()
  RefreshUI()
  return true
end

-- The launcher's Open games list joins through the same path as the popup.
function PG.RPS.JoinOpen(key)
  return clientAccept(sessions[tostring(key or "")])
end

-- Read-only view of what this module is overhearing, for the launcher list.
-- Lite records are the store; this is a projection of them (5.10 rule 2).
function PG.RPS.OpenGames()
  local out = {}
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      out[#out + 1] = { key = rec.key, host = rec.host, token = rec.token,
                        scope = rec.scope, expires = rec.expires, game = "RPS" }
    end
  end
  return out
end

local function clientHostDead()
  local S = mySession()
  if not S then return end
  toast("lost contact with the host - game abandoned.", S.host)
  endSession("Abandoned - the host stopped responding.")
end

-- highest round R such that RESULTs 1..R have all been applied locally
local function appliedThrough()
  local S = mySession()
  if not S then return 0 end
  local r = 0
  while S.appliedResults[r + 1] do r = r + 1 end
  return r
end

-- Resync request: ask the host to replay whatever we missed (loading
-- screens, encounter gaps). At most one SYNCQ per SYNC_COOLDOWN; a refused
-- or cooling-down request stays pending and the ticker retries it. Never
-- sent by the host, after SYNCNO, or for a finished session.
clientRequestSync = function()
  local S = mySession()
  if not S or S.isHost or S.phase == "done" or S.syncDead then return end
  local now = GetTime()
  if now - (S.lastSyncQ or 0) < SYNC_COOLDOWN or PG.Comm.Locked() then
    S.syncNeeded = true
    return
  end
  -- the digest rides along so the host can spot a same-size/wrong-membership
  -- roster, which a count comparison alone can never see
  if PG.Comm.Whisper(S.host, "RPS", "SYNCQ", S.token, S.phase, appliedThrough(),
                     #S.roster, rosterDigest(S.roster)) then
    S.lastSyncQ = now
    S.syncNeeded = false
  else
    S.syncNeeded = true
  end
end

-- A resynced spectator rejoins once its mirror agrees with the host again:
-- roster count matches BEGIN's count and every completed round's RESULT is
-- applied. It participates from the NEXT round (syncHoldR blocks the round
-- already open at heal time) and never scores retroactively - the replayed
-- patterns carry X for every round it missed, worth zero points.
local function maybeClearSpectator()
  local S = mySession()
  if not S or S.isHost or not S.spectator or S.syncDead then return end
  if S.phase ~= "play" or not S.count then return end
  if #S.roster ~= S.count then return end
  -- size agreement is not membership agreement: without this a spectator heals
  -- onto a same-count/wrong-member roster and scores (and persists medals for)
  -- the wrong players - the very bug the digest exists to catch, one hop later
  if S.digest and rosterDigest(S.roster) ~= S.digest then return end
  local need = S.roundOpen and (S.r - 1) or S.r
  if need < 0 then need = 0 end
  if appliedThrough() < need then return end
  -- The same test applyBegin makes, one hop later: a mirror that converged on
  -- the host's roster through a resync replay and finds itself absent was never
  -- in this game. It stops here rather than clearing the spectator flag, toasting
  -- "you are back in the game" and then holding the seat through a session whose
  -- cards doThrow refuses for the rest of its life.
  local me = myName()
  if not (me and S.joined[me]) then
    toast("your join did not reach the host - you are not in this game.", S.host,
      { key = "rps-status" })
    endSession("You are not in this game.")
    evict(S.key)
    return
  end
  S.spectator = false
  if S.roundOpen and S.r >= 1 then S.syncHoldR = S.r end
  toast("back in sync - you are back in the game.", S.host, { key = "rps-status" })
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

local function askMax()
  return PG.UI.ASK_MAX or 3
end

-- Busy means the SEAT is held, and nothing else (6.1). Hosting is not busy,
-- holding lite records is not busy, a Pull Book is not busy. A busy client is
-- never deaf - it still records the session and still lists it - it just gets no
-- popup it could not accept, and at group scope one line per minute at most.
local function busyToast(host)
  local now = GetTime()
  if (now - busyToastAt) < BUSY_THROTTLE then
    busyPending = busyPending + 1
    return
  end
  -- a pending count older than two throttle windows counts games that have long
  -- since expired: "4 more games are open" must be true when it is said
  if (now - busyToastAt) > (BUSY_THROTTLE * 2) then busyPending = 0 end
  busyToastAt = now
  if busyPending > 0 then
    local n = busyPending + 1
    busyPending = 0
    toast(n .. " more games are open - see the Pengyou Games window.", host)
  else
    toast(shortOf(host) .. " started a game - you're in another game right now."
      .. " It's in the Pengyou Games window.", host, { key = "rps-busy" })
  end
end

-- Invitation number ASK_MAX+1 does not pop: it goes to the launcher list plus
-- one throttled line (5.6 rule 1). An Ask you cannot see must never silently
-- decline itself, which is why PG.UI.Ask reports "full" instead of declining.
local function overflowToast()
  local now = GetTime()
  if (now - overflowToastAt) < BUSY_THROTTLE then return end
  overflowToastAt = now
  toast("another game is open - see the Pengyou Games window.", nil, { key = "rps-busy" })
end

-- SCOPE.md 6.3: at most one guild popup per sender per 60s and three per five
-- minutes. Two hundred guildmates with no budget is a denial of service on the
-- user's screen whose only remedy would be disabling the addon.
-- The counter itself lives in Widgets, next to AskCount, because the budget is
-- on the user's SCREEN and not on a module: one per module meant Loot Goblins
-- and Rock Paper Scissors each allowed three, so the real ceiling was six.
local function guildBudgetOk(host)
  if PG.UI.GuildAskOK then return PG.UI.GuildAskOK(host) end
  return true
end

local function guildBudgetSpend(host)
  if PG.UI.GuildAskSpend then PG.UI.GuildAskSpend(host) end
end

-- Toast / popup policy for an inbound OPEN (4.4). No OPEN is ever refused
-- because a session exists; what varies is only how loudly we mention it.
local function raiseInvite(rec)
  listOpen(rec)     -- every lite record gets a launcher row, at every scope
  if PG.Session.IsSeated() then
    if rec.scope == "group" then busyToast(rec.host) end
    return          -- guild and public stay silent while busy
  end
  if rec.scope == "public" then return end          -- never a popup (SCOPE.md 6.3)
  if rec.scope == "guild" and not guildBudgetOk(rec.host) then return end
  if PG.UI.AskCount() >= askMax() then
    -- group scope only, exactly like the busy line above: a popular guild
    -- starting five games must not produce five toasts (4.4), and a guild open
    -- over the budget is specified to be silent, not merely quieter
    if rec.scope == "group" then overflowToast() end
    return
  end
  -- Per-SESSION key (5.6). The old "rps-invite" was the bug behind owner rule 3:
  -- a second invitation hit the replacement path and silently auto-declined the
  -- first, so two hosts starting a second apart cost you the choice.
  local askKey = "RPS:" .. rec.key
  local acceptLabel = "Play"
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then acceptLabel = m .. " Play" end
  end
  local where = ""
  if rec.scope == "guild" then where = " (guild)"
  elseif rec.scope == "public" then where = " (public)" end
  -- the timeout is the invitation's REMAINING life, never the raw joinSecs, so
  -- a popup raised late cannot outlive its own join window (5.6 rule 5)
  local ok, why = PG.UI.Ask(askKey,
    shortOf(rec.host) .. " started Rock Paper Scissors" .. where
      .. " - best of " .. rec.cfg.rounds .. ". Play?",
    acceptLabel, "Pass", math.max(1, rec.expires - GetTime()),
    function() clientAccept(rec) end,
    -- Pass, or the countdown expiring, takes the popup down - and askKey must
    -- come down with it, or the record goes on claiming a popup it no longer
    -- has and row 6's eviction scan can find no victim at all. The identity
    -- guard stops a late callback resurrecting the field on an evicted record.
    function() if sessions[rec.key] == rec then rec.askKey = nil end end,
    "faire")
  if ok then
    rec.askKey = askKey
    if rec.scope == "guild" then guildBudgetSpend(rec.host) end
  elseif why == "full" and rec.scope == "group" then
    overflowToast()
  end
  -- why == "dnd": PG.UI.Ask already declined, so a DND player never seats. The
  -- lite record stays in the launcher list either way (5.6 rule 7).
end

-- 4.3, the one deterministic convergence rule in the design: the newest OPEN
-- from a given host replaces that host's previous session on every client,
-- unconditionally, at any age. No comparison and no election is needed, because
-- the host is the sole authority for its own sessions - if it is sending a new
-- OPEN, the old one is over on the host whatever we still believe. This is what
-- rescues a client that missed END and would otherwise be silently excluded from
-- every future game by the token gate.
local function supersede(host, newToken)
  for k, rec in pairs(sessions) do
    if rec.host == host and rec.token ~= newToken then
      -- a superseded FINISHED record keeps its final standings on screen (4.3);
      -- a live one loses its window, because it is no longer a game
      local keepWindow = (rec.kind == "full" and rec.phase == "done")
      if rec.kind == "full" and rec.phase ~= "done" then
        -- I6's only exception. We are never auto-seated into the new game: the
        -- OPEN that follows raises a normal invitation we may decline.
        toast(shortOf(host) .. " started a new game - your previous game is over.",
          host, { priority = "result" })
        endSession("The host started a new game.")
      end
      evict(k, keepWindow) -- a lite record dies silently: no toast, no line
    end
  end
end

-- Cap enforcement (4.2 row 6): drop the oldest lite record with no popup ON
-- SCREEN. Liveness is PG.UI.IsAsking, not the cached askKey - the field is the
-- record's belief, the frame is the fact - and if every record still claims a
-- popup the oldest goes anyway: evict() takes its popup down with it, and
-- dropping the new OPEN instead would leave it with no record, no popup and no
-- launcher row (a row with no record behind it cannot be joined).
local function makeLiteRoom()
  local victim, oldest, anyVictim, anyOldest
  for k, rec in pairs(sessions) do
    if rec.kind == "lite" then
      local asking = rec.askKey ~= nil
      if PG.UI.IsAsking then asking = PG.UI.IsAsking(rec.askKey) end
      if not asking and (not oldest or rec.openedAt < oldest) then
        victim, oldest = k, rec.openedAt
      end
      if not anyOldest or rec.openedAt < anyOldest then
        anyVictim, anyOldest = k, rec.openedAt
      end
    end
  end
  victim = victim or anyVictim
  if not victim then return false end
  evict(victim)
  return true
end

-- The inbound OPEN decision table (4.2), evaluated in order. There is no
-- collision window and no arbitration between different hosts: two hosts
-- pressing Start in the same second produce two games, which is the intended
-- outcome. Every client that hears both shows both and lets its human choose,
-- so no two clients can choose differently - convergence by construction rather
-- than by election.
local function onOpen(token, sender, scope, f1, f2, f3, f4)
  if sender == myName() then return end                     -- row 1, belt and braces
  -- row 2: the declared scope exists to be CHECKED against the delivered
  -- distribution, never trusted. A wire field can claim guild on a party
  -- message; a distribution cannot.
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f4))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end                     -- an OPEN never arrives by whisper
  if not PG.RPS.SCOPES[scope] then return end               -- not an audience this game plays to
  local rounds = num(f1, 1, MAX_ROUNDS)
  local joinSecs = num(f2, 5, 600)
  local roundSecs = num(f3, 5, 600)
  if not (rounds and joinSecs and roundSecs) then return end
  local key = keyOf(sender, token)
  if isRecent(key) then return end                          -- row 3: dead token, poisoned
  local now = GetTime()
  local existing = sessions[key]
  if existing then                                          -- row 4: idempotent
    if existing.kind == "lite" then
      existing.expires = now
        + math.max(LITE_TTL_MIN, math.min(LITE_TTL_MAX, joinSecs)) + LITE_TTL_PAD
    end
    return   -- a retransmitted OPEN raises no second invitation and no toast
  end
  supersede(sender, token)                                  -- row 5
  if liteCount >= MAX_LITE and not makeLiteRoom() then return end  -- row 6
  local rec = {                                             -- row 7
    kind = "lite",
    key = key,
    token = token,
    host = sender,
    scope = scope,
    cfg = { rounds = rounds, joinSecs = joinSecs, roundSecs = roundSecs },
    openedAt = now,
    expires = now
      + math.max(LITE_TTL_MIN, math.min(LITE_TTL_MAX, joinSecs)) + LITE_TTL_PAD,
  }
  register(rec)
  raiseInvite(rec)
end

-- Gate h (5.2). A lite record holds no roster, no totals, no picks, no history,
-- no ticker and no frame, and it never reaches an applier. It accepts exactly
-- four message types, and three of them only kill it: once a game we did not
-- join has started, we have no reason to know it exists. This is the single
-- largest state reduction in the design - group-scope bystanders stop mirroring
-- games they declined.
local function liteObserve(rec, mtype)
  if mtype == "HB" then
    rec.expires = math.max(rec.expires, GetTime() + LITE_TTL_PAD)
  elseif mtype == "BEGIN" or mtype == "CANCEL" or mtype == "END" then
    evict(rec.key)
  end
end

-- Message classes (gate f). Splitting by class rather than falling back between
-- lookups removes the last ambiguity: a peer who hosts a session whose token
-- happens to equal ours can never have its whisper resolve against our hosted
-- record, and vice versa.
local HOST_AUTHORED = {
  HB = true, JOINED = true, LEFT = true, BEGIN = true, ROUND = true,
  RESULT = true, VOID = true, END = true, CANCEL = true,
  SYNCOK = true, SYNCNO = true,
}
local CLIENT_AUTHORED = { JOIN = true, UNJOIN = true, PICK = true, SYNCQ = true }

local function onComm(mtype, token, sender, scope, f1, f2, f3, f4)
  token = validToken(token)                                  -- 3.4
  if not token then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3, f4) end

  local rec
  if HOST_AUTHORED[mtype] then
    -- gate g: identity is the PAIR. This one lookup replaces the old
    -- `token ~= S.token` filter and is what makes two sessions non-interfering:
    -- a filter cannot express "this belongs to a session I know about but am not
    -- in", so its only answer was to discard the message AND stay permanently
    -- deaf to that session. Sender authority (gate j) is free here - sender IS
    -- rec.host, because it is half the key.
    rec = sessions[keyOf(sender, token)]
  elseif CLIENT_AUTHORED[mtype] then
    local m = mySession()
    if m and m.isHost and m.token == token and scope == "private" then rec = m end
  else
    return                                                   -- unknown mtype
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype) end
  if rec ~= mySession() then return end   -- I3: the only full record is the involved one
  if rec.phase == "done" then return end                     -- gate k
  -- gate i: "private" is exempt because resync replays of BEGIN/RESULT/ROUND
  -- legitimately arrive by whisper. This line is what stops a live guild
  -- session's token being re-broadcast into party chat.
  if scope ~= "private" and scope ~= rec.scope then return end

  local S = rec
  if S.isHost then
    if mtype == "JOIN" then
      hostHandleJoin(sender)
    elseif mtype == "UNJOIN" then
      hostHandleUnjoin(sender)
    elseif mtype == "PICK" then
      hostHandlePick(sender, num(f1, 1, MAX_ROUNDS), PG.SafeStr(f2))
    elseif mtype == "SYNCQ" then
      hostHandleSyncQ(sender, PG.SafeStr(f1), num(f2, 0, MAX_ROUNDS),
                      num(f3, 0, ROSTER_CAP), PG.SafeStr(f4))
    end
    return
  end
  -- sender == S.host is guaranteed by gate g's key; nothing else can reach here
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  S.hostQuiet = false  -- ... and clears the wide-scope "they may be in a boss fight"
  if S.phase == "join"
    and (mtype == "ROUND" or mtype == "RESULT" or mtype == "VOID" or mtype == "END") then
    -- we missed BEGIN entirely: spectate for now and ask the host to replay
    -- what we missed - resync can fully restore us (roster stream + BEGIN +
    -- RESULTs), unlike the old permanent sit-out
    S.phase = "play"
    S.spectator = true
    toast("out of sync with the host - resyncing...", S.host, { key = "rps-status" })
    clientRequestSync()
  end
  if mtype == "HB" then
    return
  elseif mtype == "JOINED" then
    local name = PG.SafeStr(f1)
    if name and name ~= "" then applyJoined(name) end
  elseif mtype == "LEFT" then
    local name = PG.SafeStr(f1)
    if name and name ~= "" then applyLeft(name) end
  elseif mtype == "BEGIN" then
    local count = num(f1, 2, ROSTER_CAP)
    local rounds = num(f2, 1, MAX_ROUNDS)
    -- optional trailing field: absent means a peer without it (count-only
    -- check, exactly as before); present but malformed drops the message
    local dig = PG.SafeStr(f3)
    if count and rounds and (dig == nil or isDigest(dig)) then
      applyBegin(count, rounds, dig)
    end
  elseif mtype == "CANCEL" then
    applyCancel(PG.SafeStr(f1) or "?")
  elseif mtype == "ROUND" then
    local r = num(f1, 1, MAX_ROUNDS)
    local secs = num(f2, 1, 600)
    if r and secs then
      if r > S.r + 1 then clientRequestSync() end -- unexpected round: we missed traffic
      applyRound(r, secs)
    end
  elseif mtype == "RESULT" then
    local r = num(f1, 1, MAX_ROUNDS)
    local pattern = PG.SafeStr(f2)
    if r and pattern and validPattern(pattern) then
      if r > S.r then clientRequestSync() end -- result for a round we never saw open
      applyResult(r, pattern)
    end
  elseif mtype == "VOID" then
    local r = num(f1, 1, MAX_ROUNDS)
    if r then applyVoid(r) end
  elseif mtype == "END" then
    applyEnd()
  elseif mtype == "SYNCOK" then
    S.syncNeeded = false -- host confirms we missed nothing
  elseif mtype == "SYNCNO" then
    -- the delta is too large to replay: spectator locks for this session
    if not S.syncDead then
      S.syncDead = true
      S.syncNeeded = false
      if not S.spectator then
        S.spectator = true
        toast("too far out of sync to catch up - spectating this game.", S.host,
          { key = "rps-status" })
      end
      RefreshUI()
    end
  end
  maybeClearSpectator()
end

-- An OUTGOING message of ours was permanently dropped by the comms lockdown.
-- For the host, losing a state-bearing broadcast desyncs every client, so the
-- session dies locally in the rare queued-then-lockdown race; clients notice
-- via the 35s heartbeat timeout. Sessions are stateless fun - nothing is owed
-- on abort. The sync messages (SYNCQ/SYNCOK/SYNCNO) are deliberately NOT
-- critical: a dropped one just means the client asks again later.
local CRITICAL_DROP = {
  OPEN = true, JOINED = true, LEFT = true, BEGIN = true,
  ROUND = true, RESULT = true, VOID = true, END = true,
}

-- Resync replay whispers reuse the original mtypes above, so onDrop cannot
-- tell a dropped replay whisper from a dropped live broadcast. While a replay
-- may still be draining from the send queue (syncReplayUntil window) a drop
-- of one of these must not abort the game: the asking client simply retries,
-- and even a live broadcast lost in that window now self-heals through the
-- same resync path once the lockdown clears.
local REPLAYABLE = {
  JOINED = true, LEFT = true, BEGIN = true, RESULT = true, ROUND = true,
}

-- The queue and its 10-token bucket are shared by the whole addon, so onDrop
-- used to be a live grenade: it carried no session identity and killed whatever
-- session happened to be current. With two live sessions that is one session
-- killing another. The token now rides on the queue entry (CONCURRENCY.md 5.5),
-- so a drop aborts ONLY the record that lost the message, and a drop for a
-- foreign or already-evicted token is ignored.
local function onDrop(mtype, token)
  local S = mySession()
  if not (S and S.isHost and S.phase ~= "done") then return end
  local me = myName()
  local t = validToken(token)
  if not (me and t) or keyOf(me, t) ~= S.key then return end
  if not CRITICAL_DROP[mtype] then return end
  if REPLAYABLE[mtype] and S.syncReplayUntil and GetTime() < S.syncReplayUntil then return end
  toast("game aborted - addon messages were blocked mid-send.", S.host)
  endSession("Aborted - addon messages were blocked.")
end

-------------------------------------------------------------------------------
-- Safety transitions. Encounter/restriction breaks the open round (VOID once
-- clear, then the SAME round replays fresh); ready check / countdown merely
-- freezes its timer (repeat ROUND r = refresh, locks stay). Plain combat is
-- deliberately NOT here: it neither blocks addon sends (the 12.1 lockdown is
-- encounter/M+/PvP-scoped) nor pauses the game - the old "combat pauses the
-- game" doctrine is gone. Resumption is driven by the ticker once every
-- gating flag clears; clients that missed traffic during a genuine gap ask
-- the host to replay it (SYNCQ resync).
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local isOn = trigger:match("_ON$") ~= nil
  if not S.isHost then
    if trigger == "ENCOUNTER_ON" then
      S.myPick = nil -- discard pending throw; the host will void this round
    end
    -- resync trigger: the session just emerged from a safety interruption
    -- (allClear() transitioned false -> true); ask the host what we missed
    local cur = allClear()
    if cur and S.syncAllClear == false then S.syncNeeded = true end
    S.syncAllClear = cur
    return
  end
  if not isOn then return end
  -- plain combat neither freezes the join window nor the round timer
  if trigger == "COMBAT_ON" then return end
  if S.phase == "join" then
    if not S.joinFrozen then
      S.joinFrozen = true
      S.joinRemaining = math.max(0, (S.joinDeadline or GetTime()) - GetTime())
    end
  elseif S.phase == "play" and S.roundOpen then
    if trigger == "ENCOUNTER_ON" or trigger == "RESTRICT_ON" then
      S.broken = true -- this round is dead; VOID + replay after the encounter
      S.frozen = false
      S.picks = {}
      S.myPick = nil
    elseif not S.broken and not S.frozen then
      S.frozen = true
      S.freezeRemaining = math.max(0, (S.deadline or GetTime()) - GetTime())
    end
  end
end

-------------------------------------------------------------------------------
-- Master ticker: host timing (join window, round deadline, void/reopen/end
-- retries, heartbeat) and the client-side host-death watchdog.
-------------------------------------------------------------------------------

-- Registry sweep (2.5), every 4th tick. Worst case 1 + 8 + 16 = 25 table
-- entries once per 2 seconds - the whole cost of knowing about other people's
-- games. Eviction is the only way a record leaves, and it always poisons.
local function sweepRegistry()
  local now = GetTime()
  for key, rec in pairs(sessions) do
    if rec.kind == "lite" then
      if now >= rec.expires then evict(key) end
    elseif rec.phase == "done" and rec.doneAt and (now - rec.doneAt) > DONE_TTL then
      -- 7.3: a done record goes at DONE_TTL, and the window goes with it. The
      -- old IsShown() exemption meant a finished game whose window the user
      -- never closed was never swept at all - the record lived forever and the
      -- registry's "at most one full record" contract quietly depended on the
      -- next game replacing it. LG has always evicted-and-hidden here.
      evict(key)
    end
  end
  for key, t in pairs(recent) do
    if (now - t) > RECENT_TTL then recent[key] = nil end
  end
  local i = 1
  while i <= #recentQ do
    if recent[recentQ[i]] == nil then table.remove(recentQ, i) else i = i + 1 end
  end
end

onTick = function()
  sweepTicks = sweepTicks + 1
  if sweepTicks >= SWEEP_EVERY then
    sweepTicks = 0
    sweepRegistry()
  end
  local S = mySession()
  if not S or S.phase == "done" then
    if win and win:IsShown() then RefreshUI() end
    return
  end
  local now = GetTime()
  if S.isHost then
    -- Scope-aware host abort (SCOPE.md 6.1): left the party at group scope,
    -- /gquit or gkick at guild scope, or the public channel index gone for a
    -- continuous 8 seconds. The grace is essential - a temporary channel is
    -- dropped across EVERY loading screen, so a zero-grace check would abort
    -- every public session the first time the host took a portal.
    local okScope, why = PG.Comm.ScopeAvailable(S.scope, 8)
    if not okScope then
      why = why or "That audience is gone."
      toast(why .. " Game abandoned.", S.host)
      endSession("Abandoned - " .. why)
      return
    end
    if now - (S.lastHBSent or 0) >= HB_INTERVAL and not PG.Comm.Locked() then
      if broadcast("HB", S.phase, S.r) then S.lastHBSent = now end
    end
    if S.phase == "join" then
      if S.joinFrozen then
        if allClear() then
          S.joinFrozen = false
          S.joinDeadline = now + (S.joinRemaining or 0)
          S.joinDeadlineDisplay = S.joinDeadline
        end
      elseif now >= (S.joinDeadline or 0) then
        hostCloseJoin()
      end
    elseif S.phase == "play" then
      if S.broken then
        if allClear() and not PG.Comm.Locked() then hostVoidRound() end
      elseif S.frozen then
        if allClear() and not PG.Comm.Locked() then hostReopenRound() end
      elseif S.endPending then
        if allClear() and not PG.Comm.Locked() then hostEnd() end
      elseif S.roundOpen then
        if now >= (S.deadline or 0) and not PG.Comm.Locked() then hostResolveRound() end
      elseif S.nextRoundAt and now >= S.nextRoundAt and allClear() and not PG.Comm.Locked() then
        S.nextRoundAt = nil
        hostStartRound(S.r + 1)
      end
    end
  else
    local st = PG.Safety.state
    if st.inEncounter or st.restricted or PG.Comm.Locked() then
      -- the host cannot legally heartbeat here (encounter, or the M+/PvP
      -- comms lockdown, or the pre-activation restriction window): suspend
      -- the watchdog instead of declaring the host dead
      S.lastHB = (S.lastHB or now) + TICK
    else
      local quiet = now - (S.lastHB or now)
      if S.scope == "group" then
        -- host and client are in the same content by definition: unchanged
        if quiet > HB_TIMEOUT then
          clientHostDead()
          return
        end
      else
        -- SCOPE.md 6.2. OUR safety state says nothing about the host's when we
        -- are not in the same instance, so silence is treated as paused first
        -- and dead only much later. No state change, no spectator flip.
        if quiet > HB_GIVEUP_WIDE then
          clientHostDead()
          return
        end
        if quiet > HB_QUIET_WIDE then
          if not S.hostQuiet then
            S.hostQuiet = true
            RefreshUI()
          end
          if (now - (S.quietSyncAt or 0)) > QUIET_SYNC_EVERY then
            S.quietSyncAt = now
            clientRequestSync() -- the mirror heals the instant they come back
          end
        end
      end
    end
    -- pending resync request (cooldown or refused send): retry once clear
    if S.syncNeeded and allClear() then clientRequestSync() end
  end
  if win and win:IsShown() then RefreshUI() end
end

-------------------------------------------------------------------------------
-- FX (faire carnival garnish). Pure decoration behind runFX: text state is
-- always final BEFORE any of this plays, groups register into the Theme
-- OnHide contract via Banner/Stamp/Pulse/Reveal, and nothing here ever
-- re-shows a Safety-hidden frame (Theme.After is generation-checked and
-- IsShown-gated; the reveal stage is Safety-registered and vetoes its own
-- auto-resume). Round and final results go through the shared reveal stage
-- (REVEAL.md 6.3 / 6.4), which supersedes the old result banners.
-------------------------------------------------------------------------------

fxJoined = function(name)
  if not (win and win:IsShown()) then return end
  if name == myName() then Theme.Sound("click") end
end

fxBegin = function()
  local S = mySession()
  if not (win and win:IsShown() and S) then return end
  Theme.Banner(win, "BEST OF " .. S.rounds, "faire")
  Theme.Sound("stamp")
end

fxRound = function()
  if not (win and win:IsShown()) then return end
  Theme.Sound("page")
end

fxPick = function(c)
  if not (win and win:IsShown()) then return end
  local btn = cardBtns[c]
  if btn then Theme.Pulse(btn) end
  Theme.Sound("click")
end

-- Reveal payload helpers. Presentation only: both READ live state and write
-- nothing - the authoritative scoring already ran inside applyResult, and
-- these run behind runFX (errors are swallowed) well after it.

-- name -> the throw char this round applied, or nil when the pattern cannot be
-- mapped onto our roster (exactly the condition under which applyResult
-- refuses to score, so an unmapped round simply shows no per-player gains).
local function revealThrows(lr)
  local S = mySession()
  if not (S and lr) then return nil end
  local pattern = lr.pattern
  if type(pattern) ~= "string" or #pattern ~= #S.roster then return nil end
  local out = {}
  for i, name in ipairs(S.roster) do out[name] = pattern:sub(i, i) end
  return out
end

-- name -> dense place BEFORE this round's points landed: the same comparator
-- and dense ranking computeStandings uses, run on totals minus this round's
-- gains. Used only to render standings movement on the reveal rows.
local function revealPrevPlaces(throws, gainOf)
  local S = mySession()
  if not S then return {} end
  local list = {}
  for _, name in ipairs(S.roster) do
    list[#list + 1] = { name = name,
                        pts = (S.totals[name] or 0) - (gainOf[throws[name]] or 0) }
  end
  table.sort(list, function(a, b)
    if a.pts ~= b.pts then return a.pts > b.pts end
    return a.name < b.name
  end)
  local out, place, lastPts = {}, 0, nil
  for i = 1, #list do
    if list[i].pts ~= lastPts then
      place = place + 1
      lastPts = list[i].pts
    end
    out[list[i].name] = place
  end
  return out
end

-- Round result: the shared reveal stage, cascade variant (REVEAL.md 6.3) -
-- throw counts on the subtitle, one row per player carrying the points gained
-- and the places moved, your row emphasized, the leader on the marquee.
-- Theme.Reveal drops the payload silently when a window would not be allowed
-- (any Safety flag) or the stage is busy; the window text is already final
-- either way (RefreshUI ran before this, SKIN.md rule 6.7).
fxResult = function()
  local S = mySession()
  if not (win and win:IsShown() and S and S.lastResult) then return end
  local lr = S.lastResult
  local rows, marquee, scored = {}, nil, 0
  if S.spectator then
    -- mirrors the window: a desynced mirror never applied points, so its
    -- standings are meaningless and must not be paraded as results
    rows[1] = { text = "Out of sync - standings unavailable.", role = "fade" }
  else
    local me = myName()
    local gainOf = { R = lr.nS, P = lr.nR, S = lr.nP, X = 0 }
    local throws = revealThrows(lr)
    local prev = throws and revealPrevPlaces(throws, gainOf) or nil
    local standings = computeStandings()
    local leaders = 0
    for i = 1, #standings do
      local e = standings[i]
      local text = e.place .. ". " .. e.name .. "  -  " .. e.pts .. " pts"
      local c = throws and throws[e.name]
      if c == "X" then
        text = text .. "  " .. P.chgray .. "sat out|r"
      elseif c then
        local g = gainOf[c] or 0
        scored = scored + g
        text = text .. "  " .. ((g > 0) and (P.chgreen .. "+" .. g .. "|r")
                                or (P.chgray .. "+0|r"))
      end
      local was = prev and prev[e.name]
      if was and was ~= e.place then
        text = text .. "  " .. ((e.place < was)
          and (P.chgreen .. "^" .. (was - e.place) .. "|r")
          or (P.chred .. "v" .. (e.place - was) .. "|r"))
      end
      if e.place == 1 then leaders = leaders + 1 end
      rows[#rows + 1] = { text = text,
                          role = (e.place == 1) and "gold" or "body",
                          personal = (e.name == me) }
    end
    local top = standings[1]
    if top then
      if leaders > 1 then
        marquee = leaders .. "-WAY TIE FOR THE LEAD"
      elseif prev and (prev[top.name] or 1) > 1 then
        marquee = shortOf(top.name) .. " TAKES THE LEAD"
      else
        marquee = shortOf(top.name) .. " LEADS"
      end
    end
  end
  local sess = S
  Theme.Reveal({
    theme = "faire",
    anchor = { mode = "window", host = win },
    title = "ROUND " .. lr.r,
    subtitle = "Rock " .. lr.nR .. " - Paper " .. lr.nP .. " - Scissors " .. lr.nS
      .. ((lr.nX > 0) and (" - " .. lr.nX .. " sat out") or ""),
    rows = rows,
    marquee = marquee,
    burst = (scored > 0) and "stars" or "none",
    burstCount = 8,
    sound = ((lr.myGain or 0) > 0) and "settled" or "page",
    -- ownership (CONCURRENCY.md 5.8 rule 2): a moment whose session was
    -- superseded, withdrawn or swept between the applier and the stage is
    -- culled rather than played over whatever window is up by then
    validate = function() return sessions[sess.key] == sess end,
    -- precedence (rule 3): the session we are PLAYING outranks one we referee
    priority = sess.seated and 1 or 0,
  })
end

fxVoid = function()
  if not (win and win:IsShown()) then return end
  Theme.Stamp(win, "ROUND VOID")
  Theme.Sound("coincancel")
end

-- Final standings: the podium variant (REVEAL.md 6.4) - bronze, silver and
-- gold rise in sequence with the winner last and the big burst, the champion
-- line on the marquee, the medal tally on the subtitle. QUEUED, not played
-- directly: the last round's cascade is usually still on the stage when END
-- lands, and the podium is the one moment that must eventually show. Its
-- validate culls it if this session is replaced (Play again) or never ended
-- before the queue drains.
fxEnd = function()
  local S = mySession()
  if not (win and win:IsShown() and S) then return end
  local sess = S
  local me = myName()
  local subtitle = "Best of " .. S.rounds
  local rows, marquee, mine = {}, nil, false
  if S.spectator then
    rows[1] = { text = "Out of sync - standings unavailable.", role = "fade" }
  else
    local standings = S.standings or computeStandings()
    local champ, winners = nil, 0
    for i = 1, #standings do
      local e = standings[i]
      if e.place == 1 then
        winners = winners + 1
        champ = champ or e.name
        if e.name == me then mine = true end
      end
      rows[#rows + 1] = {
        text = e.place .. ". " .. e.name .. "  -  " .. e.pts .. " pts",
        -- "fade" is CHGRAY, the exact tone of the silver medal, so a podium
        -- full of fade rows made second place read as an also-ran. Field rows
        -- that are still on points get CHALK ("body"); only the pointless ones
        -- fade. (The role -> color mapping itself is REVEAL.md 2.3's.)
        role = (e.place == 1 and "gold") or (e.place == 2 and "silver")
          or (e.place == 3 and "bronze") or (((e.pts or 0) > 0) and "body")
          or "fade",
        place = (e.place <= 3) and e.place or nil,
        personal = (e.name == me),
      }
    end
    if champ then
      marquee = shortOf(champ)
        .. ((winners > 1) and " AND FRIENDS TIE" or " TAKES THE CROWN")
    end
    -- medals are persisted by applyEnd before this runs, and never for a
    -- spectator - the tally line only appears where the count is real
    if me and S.joined[me] then
      subtitle = subtitle .. " - your medals: " .. myMedalCount()
    end
  end
  Theme.RevealQueue({
    theme = "faire",
    anchor = { mode = "window", host = win },
    variant = "podium",
    title = "FINAL RESULTS",
    subtitle = subtitle,
    rows = rows,
    marquee = marquee,
    burst = "stars",
    burstCount = 12,
    sound = mine and "cheer" or "page",
    burstSound = "fanfare",
    -- Reveal ownership (CONCURRENCY.md 5.8 rule 2): the payload belongs to THIS
    -- record, not to "the current session". A podium whose session was
    -- superseded, withdrawn from or swept is culled at drain time rather than
    -- playing over whatever replaced it.
    validate = function() return sessions[sess.key] == sess and sess.ended == true end,
    -- precedence (rule 3): a podium from the game we PLAYED drains ahead of one
    -- from a game we merely refereed
    priority = sess.seated and 1 or 0,
  })
end

-------------------------------------------------------------------------------
-- Game window
-------------------------------------------------------------------------------

rowAt = function(i)
  if not rows[i] then
    local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 26, -244 - (i - 1) * 17)
    fs:SetWidth(368)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
    if Theme then Theme.Shadow(fs) end
    rows[i] = fs
  end
  return rows[i]
end

-- Icon above the card label, via the Theme asset table (decoration only:
-- Theme.Tex returning false means only the solid fallback applied, so we hide
-- the texture and the centered label alone carries the meaning - the same
-- pattern as PullBook's market emblems. No theme layer -> no icon, same
-- centered-label layout; a missing icon can never break the layout.
local function addCardIcon(btn, key)
  local ok, tex = pcall(btn.CreateTexture, btn, nil, "ARTWORK")
  if not (ok and tex) then return end
  tex:SetSize(26, 26)
  tex:SetPoint("TOP", 0, -7)
  if not (Theme and Theme.Tex(tex, key)) then
    tex:Hide()
    return
  end
  -- icon rendered: drop the label to the bottom so both read
  local fs = btn.text
  if not fs then
    local okF, got = pcall(btn.GetFontString, btn)
    if okF then fs = got end
  end
  if fs then
    pcall(fs.ClearAllPoints, fs)
    pcall(fs.SetPoint, fs, "BOTTOM", btn, "BOTTOM", 0, 9)
  end
end

local function chalk(fs)
  fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  if Theme then Theme.Shadow(fs) end
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("rps", "Rock Paper Scissors", 420, 560, "faire")
  -- Core re-shows Safety-hidden windows whose __pgResume() returns true once
  -- every safety flag clears, so a combat/safety hide resumes on its own
  -- whenever a session exists (even a finished one showing final standings)
  win.__pgResume = function() return mySession() ~= nil end

  -- the audience, under the title (SCOPE.md 5.4): "who is this game with" is the
  -- first question a wide-scope session raises
  ui.scope = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ui.scope:SetPoint("TOP", 0, -34)
  ui.scope:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.scope) end

  ui.info = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ui.info:SetPoint("TOPLEFT", 24, -44)
  ui.info:SetPoint("TOPRIGHT", -24, -44)
  ui.info:SetHeight(32)
  ui.info:SetJustifyH("LEFT")
  ui.info:SetJustifyV("TOP")
  ui.info:SetWordWrap(true)
  ui.info:SetMaxLines(2)
  ui.info:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(ui.info) end

  ui.bar = PG.UI.TimerBar(win, 372)
  ui.bar:SetPoint("TOPLEFT", 24, -84)

  -- three big throw cards in a row; first click locks
  local defs = {
    { c = "R", label = "ROCK", x = 18 },
    { c = "P", label = "PAPER", x = 150 },
    { c = "S", label = "SCISSORS", x = 282 },
  }
  for i = 1, #defs do
    local d = defs[i]
    local b = PG.UI.CardButton(win, d.label, 120, 64, function() doThrow(d.c) end)
    b:SetPoint("TOPLEFT", d.x, -108)
    b.baseLabel = d.label
    b.pick = d.c
    addCardIcon(b, CARD_ICON[d.c])
    cardBtns[d.c] = b
  end

  ui.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  ui.status:SetPoint("TOPLEFT", 24, -182)
  ui.status:SetPoint("TOPRIGHT", -24, -182)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(false)
  chalk(ui.status)

  ui.reveal = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ui.reveal:SetPoint("TOPLEFT", 24, -204)
  ui.reveal:SetPoint("TOPRIGHT", -24, -204)
  ui.reveal:SetJustifyH("LEFT")
  ui.reveal:SetWordWrap(false)
  chalk(ui.reveal)

  ui.gain = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ui.gain:SetPoint("TOPLEFT", 24, -222)
  ui.gain:SetPoint("TOPRIGHT", -24, -222)
  ui.gain:SetJustifyH("LEFT")
  ui.gain:SetWordWrap(false)
  chalk(ui.gain)

  ui.mine = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ui.mine:SetPoint("BOTTOMLEFT", 24, 46)
  ui.mine:SetPoint("BOTTOMRIGHT", -24, 46)
  ui.mine:SetJustifyH("LEFT")
  ui.mine:SetWordWrap(false)
  chalk(ui.mine)

  ui.startBtn = PG.UI.Button(win, "Start now", 105, 22, function()
    local S = mySession()
    if S and S.isHost and S.phase == "join" then hostCloseJoin() end
  end)
  ui.startBtn:SetPoint("BOTTOMLEFT", 20, 16)
  ui.cancelBtn = PG.UI.Button(win, "Cancel game", 105, 22, function()
    local S = mySession()
    if S and S.isHost and live() then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOMRIGHT", -20, 16)
  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", 105, 22, function()
    local S = mySession()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "RPS", "UNJOIN", S.token)
      -- the local press is authoritative for this client (7.2): the seat frees
      -- and the record goes now, rather than waiting on a LEFT that a lockdown
      -- may swallow. Nothing is owed in RPS either way.
      applyLeft(myName())
    end
  end)
  ui.withdrawBtn:SetPoint("BOTTOMLEFT", 20, 16) -- shares the host-only Start slot
  ui.againBtn = PG.UI.Button(win, "Play again", 105, 22, function()
    local S = mySession()
    if S and S.isHost and S.phase == "done" and S.ended then
      -- fresh session, same config and same audience; hostOpen supersedes this
      -- finished record locally and mints a new token for the new game
      hostOpen(S.rounds, S.joinSecs, S.roundSecs, S.scope)
    end
  end)
  ui.againBtn:SetPoint("BOTTOM", 0, 16)

  if Theme then
    win.__pgBannerSlot = rowAt(1) -- banners slide in over the standings area
  end
end

local SCOPE_HEADER = { group = "Party", guild = "Guild", public = "Public - realm-wide" }

RefreshUI = function()
  local S = mySession()
  if not win or not S then return end
  win.__pgRec = S            -- 5.9: the window is bound to the involved record
  local now = GetTime()
  local me = myName()
  local isJoin = S.phase == "join"
  local isPlay = S.phase == "play"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false
  local refereed = (S.isHost and not S.seated) and true or false

  ui.scope:SetText(SCOPE_HEADER[S.scope] or "")

  if isJoin then
    local second = #S.roster .. " in so far"
    -- CONCURRENCY.md 6.3: no BUSY message exists, so the host is shown what the
    -- client already knows for free - who else here runs the addon (PG.Peers,
    -- populated by CO HELLO, which is group-scoped).
    if S.isHost and S.scope == "group" then
      local peers = 0
      for _ in pairs(PG.Peers or {}) do peers = peers + 1 end
      if peers > 0 then
        second = #S.roster .. " of " .. (peers + 1) .. " addon users have joined"
      end
    end
    ui.info:SetText("Best of " .. S.rounds .. " - " .. S.roundSecs .. "s rounds|n" .. second)
  elseif isPlay then
    if S.r >= 1 then
      ui.info:SetText("Round " .. S.r .. " of " .. S.rounds)
    else
      ui.info:SetText("Best of " .. S.rounds .. " - get ready...")
    end
  else
    ui.info:SetText(S.endText or "Game over.")
  end

  local status
  if isJoin then
    if S.isHost then
      local remaining = S.joinFrozen and (S.joinRemaining or 0)
        or math.max(0, (S.joinDeadline or now) - now)
      status = #S.roster .. " joined - throws start in " .. math.ceil(remaining) .. "s"
        .. (S.joinFrozen and " (paused)" or "")
    else
      status = #S.roster .. " joined - waiting for the host to start"
    end
  elseif isPlay then
    if S.hostQuiet then
      -- SCOPE.md 6.2: quiet is not dead. No state changed and nothing was lost;
      -- the mirror heals the instant they come back.
      status = "Waiting for the host - they may be in a boss fight."
    elseif S.spectator then
      status = "Spectating - your roster is out of sync."
    elseif S.roundOpen then
      if S.isHost then
        -- only the host sees the live count; clients know just their own lock
        local k = 0
        for _ in pairs(S.picks) do k = k + 1 end
        status = k .. "/" .. #S.roster .. " have thrown"
        if S.myPick then
          status = status .. " - you locked " .. THROW_WORD[S.myPick]
        end
      elseif S.myPick then
        status = "You locked " .. THROW_WORD[S.myPick] .. " - waiting for the reveal"
      elseif S.syncHoldR == S.r and inRoster then
        status = "Resynced - you are back in from the next round."
      elseif inRoster then
        status = "Make your throw!"
      else
        status = "Watching this one."
      end
    else
      status = "Next round starting soon..."
    end
  else
    status = S.spectator and "Spectated - out of sync." or "Thanks for playing!"
  end
  ui.status:SetText(status)

  -- reveal + personal gain lines (persist through the pause after a RESULT)
  local lr = S.lastResult
  if isJoin then
    ui.reveal:SetText("")
    ui.gain:SetText("")
  elseif isDone and S.ended then
    ui.reveal:SetText(P.chgold .. "Final standings - best of " .. S.rounds .. "|r")
    local mineLine = ""
    if not S.spectator and S.standings then
      for i = 1, #S.standings do
        local e = S.standings[i]
        if e.name == me then
          mineLine = "You finished " .. (PODIUM[e.place] or WHITE) .. "#" .. e.place
            .. "|r with " .. e.pts .. (e.pts == 1 and " point." or " points.")
        end
      end
    end
    ui.gain:SetText(mineLine)
  else
    ui.reveal:SetText(S.lastResultText or "")
    local gainLine = ""
    if lr and lr.myChar then
      if lr.myChar == "X" then
        gainLine = P.chgray .. "You sat that round out (no throw)." .. "|r"
      elseif (lr.myGain or 0) > 0 then
        gainLine = "You threw " .. THROW_WORD[lr.myChar] .. ": " .. P.chgreen .. "+"
          .. lr.myGain .. (lr.myGain == 1 and " point" or " points") .. "|r"
      else
        gainLine = "You threw " .. THROW_WORD[lr.myChar] .. ": " .. P.chgray .. "+0 points|r"
      end
    end
    ui.gain:SetText(gainLine)
  end

  -- roster / standings rows
  local lines = {}
  if S.spectator and not isJoin then
    lines[1] = P.chgray .. "Out of sync - standings unavailable this game.|r"
  elseif isJoin then
    for _, name in ipairs(S.roster) do
      lines[#lines + 1] = name
        .. (name == me and (P.chgold .. " (you)|r") or "")
    end
    if not lines[1] then lines[1] = P.chgray .. "Nobody has joined yet.|r" end
  else
    local standings = (isDone and S.standings) or computeStandings()
    for i = 1, #standings do
      local e = standings[i]
      local placeColor = PODIUM[e.place] or "|cffa8a89c"
      local line = placeColor .. e.place .. ".|r " .. e.name
        .. (e.name == me and (P.chgold .. " (you)|r") or "")
        .. "  -  " .. e.pts .. " pts"
      if isDone and S.ended and e.place == 1 then
        line = line .. "  " .. PODIUM[1] .. "*|r"
      end
      lines[#lines + 1] = line
    end
  end
  -- Referee host (6.5): shown outside the numbered roster, because it holds no
  -- seat, makes no throw and wins no medal - it is running the game, not in it.
  if refereed then
    table.insert(lines, 1, P.chgray .. shortOf(S.host) .. " (running the game)|r")
  end
  local shown = math.min(#lines, MAX_ROWS)
  if #lines > MAX_ROWS then
    lines[MAX_ROWS] = P.chgray .. "... and " .. (#lines - MAX_ROWS + 1) .. " more|r"
  end
  for i = 1, shown do
    rowAt(i):SetText(lines[i])
    rowAt(i):Show()
  end
  for i = shown + 1, #rows do rows[i]:Hide() end

  -- bottom line: your total, or your medal tally after the final reveal
  if refereed then
    ui.mine:SetText(P.chgray .. "You're running this one - no throws for you.|r")
  elseif S.spectator then
    ui.mine:SetText(P.chgray .. "Spectating - no throws this game.|r")
  elseif isJoin then
    ui.mine:SetText(inRoster and "You are in - good luck!"
      or (P.chgray .. "You have not joined this game.|r"))
  elseif inRoster then
    if isDone and S.ended then
      local medals = myMedalCount()
      ui.mine:SetText(shortOf(me) .. "'s medal count: " .. P.chgold .. medals .. "|r")
    else
      local total = (me and S.totals[me]) or 0
      ui.mine:SetText("Your total: " .. P.chgold .. total .. "|r "
        .. (total == 1 and "point" or "points"))
    end
  else
    ui.mine:SetText(P.chgray .. "You are sitting this one out.|r")
  end

  -- cards: shown during play; your locked throw keeps its full card (plus a
  -- one-shot Pulse from fxPick), the others dim to 0.45 - PB's lock treatment
  local showCards = (isPlay and not S.spectator) and true or false
  local canThrow = (isPlay and S.roundOpen and inRoster and not S.myPick and not S.spectator
    and S.syncHoldR ~= S.r) and true or false
  for c, b in pairs(cardBtns) do
    b:SetShown(showCards)
    if S.myPick then
      b:SetEnabled(false)
      if c == S.myPick then
        b:SetText((b.__pgCard and "|cff145214" or "|cff40ff40") .. b.baseLabel .. "|r")
        b:SetAlpha(1)
      else
        b:SetText(b.baseLabel)
        b:SetAlpha(0.45)
      end
    else
      b:SetEnabled(canThrow)
      b:SetText(b.baseLabel)
      b:SetAlpha(1)
    end
  end

  ui.startBtn:SetShown(isJoin and S.isHost)
  -- no cancel once END is pending/queued: medals must land all-or-nothing
  ui.cancelBtn:SetShown(S.isHost and not isDone and not (S.endPending or S.endSent))
  ui.withdrawBtn:SetShown((isJoin and not S.isHost and S.joinAccepted) and true or false)
  ui.againBtn:SetShown((isDone and S.ended and S.isHost) and true or false)
end

ShowWindow = function()
  -- 5.9: one window per module, bound to the INVOLVED record. An overheard
  -- session renders an invitation and nothing else (9.7) - no window, no
  -- roster, no standings - which is the reason the memory contract is bounded.
  local S = mySession()
  if not S then return end
  if not (S.isHost or S.joinAccepted) then return end
  local st = PG.Safety.state
  -- encounter/ready-check/countdown/restriction always block; plain combat
  -- blocks only when the hideInCombat profile setting (default off, defined
  -- in Core/Settings) asks for it - combat no longer hides the game per se
  if st.inEncounter or st.readyCheck or st.countdown or st.restricted then return end
  if st.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return end
  ensureWindow()
  RefreshUI()
  win:Show()
end

-------------------------------------------------------------------------------
-- Host config dialog
-------------------------------------------------------------------------------

local function makeField(parent, label, y, default, maxLetters)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", 20, y)
  fs:SetText(label)
  fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3]) -- chalk on the board
  if Theme then Theme.Shadow(fs) end
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(70, 20)
  eb:SetPoint("TOPRIGHT", -24, y + 2)
  eb:SetAutoFocus(false)
  eb:SetNumeric(true)
  eb:SetMaxLetters(maxLetters or 3)
  eb:SetText(tostring(default))
  eb:SetCursorPosition(0)
  eb.default = default
  return eb
end

local function fieldValue(eb, lo, hi)
  local n = math.floor(tonumber(eb:GetText()) or eb.default)
  if n < lo then n = lo elseif n > hi then n = hi end
  eb:SetText(tostring(n))
  return n
end

-- Advisory notes on the audience segments (SCOPE.md 5.2 cfg.reasons). RPS
-- forbids nothing - it is the one game permitted everywhere - so these ride
-- along with an ENABLED segment rather than replacing an actionable reason.
local function scopeNote(scope)
  if scope == "public" then
    return "Points only - no gold is ever recorded, so a stranger's game costs you nothing but the time."
  elseif scope == "guild" then
    return "Everyone in your guild who runs the addon, on any realm."
  end
  return nil
end

-- Start is disabled only for I3 (this module already holds a full record) or
-- because there is no audience at all. Being in the OTHER game leaves it
-- enabled and explains that you will referee (6.4).
refreshDialog = function()
  if not (dialog and dlgNote and dlgStart) then return end
  local note, canStart = involvement()
  local scope = dlgScope and dlgScope:Get() or nil
  local why
  if not canStart then
    why = note
  elseif not scope then
    canStart = false
    why = "Nowhere to start a game: you're not in a group or a guild."
    note = why
  end
  dlgNote:SetText(note or "")
  dlgStart:SetEnabled(canStart and true or false)
  dlgStart:SetAlpha(canStart and 1 or 0.6)
  dlgStart.__pgWhy = why
end

local function ensureDialog()
  if dialog then return end
  -- SCOPE.md 5.3 sizes this at 320x290 for the picker; CONCURRENCY.md 6.4 adds
  -- the required explanatory line under it, which is the extra 30px.
  dialog = PG.UI.Window("rpsdialog", "Start Rock Paper Scissors", 320, 320, "faire")
  local hint = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hint:SetPoint("TOPLEFT", 20, -40)
  hint:SetPoint("TOPRIGHT", -20, -40)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(true)
  hint:SetText("Points only, no gold. One point per player you beat each round.")
  hint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(hint) end
  dlgInputs = {
    rounds = makeField(dialog, "Best of (rounds)", -78, 3, 1),
    joinSecs = makeField(dialog, "Join window (sec)", -108, 30, 3),
    roundSecs = makeField(dialog, "Round timer (sec)", -138, 15, 2),
  }
  -- The audience picker: a segmented control, never a dropdown (SCOPE.md 5.1).
  -- Every segment stays visible; an unavailable one greys out with its reason,
  -- because "why can't I?" is information the user wants.
  dlgScope = PG.UI.ScopePicker(dialog, {
    key = "RPS",
    allowed = PG.RPS.SCOPES,
    reasons = scopeNote,
    onChange = function() refreshDialog() end,
  })
  dlgScope:SetPoint("TOPLEFT", dialog, "TOPLEFT", 0, -170)

  dlgNote = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  dlgNote:SetPoint("TOPLEFT", 20, -228)
  dlgNote:SetPoint("TOPRIGHT", -20, -228)
  dlgNote:SetJustifyH("LEFT")
  dlgNote:SetWordWrap(true)
  dlgNote:SetHeight(32)
  dlgNote:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(dlgNote) end

  local startLabel = "Start game"
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then startLabel = m .. " Start game" end
  end
  dlgStart = PG.UI.Button(dialog, startLabel, 150, 26, function()
    local scope = dlgScope and dlgScope:Get() or nil
    if not scope then
      toast("nowhere to start a game - you're not in a group or a guild.")
      return
    end
    local rounds = fieldValue(dlgInputs.rounds, 1, MAX_ROUNDS)
    local joinSecs = fieldValue(dlgInputs.joinSecs, 15, 120)
    local roundSecs = fieldValue(dlgInputs.roundSecs, 10, 60)
    if Theme then Theme.Sound("stamp") end
    dialog:Hide()
    hostOpen(rounds, joinSecs, roundSecs, scope)
  end)
  dlgStart:SetPoint("BOTTOM", 0, 18)
  -- "how does this work?" lives next to Start, where a new player looks
  local dlgRules = PG.UI.Button(dialog, "Rules", 60, 22, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("RPS") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", 16, 18)
  dlgStart:SetScript("OnEnter", function(self)
    if not self.__pgWhy then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.__pgWhy, 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  dlgStart:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- HookScript, never SetScript: the skin and the picker already hooked OnShow
  dialog:HookScript("OnShow", refreshDialog)
end

-- Launcher / slash entry point. The dialog ALWAYS opens now (CONCURRENCY.md
-- 0.2): the old refusals - "a game is already running" and "needs a party or
-- raid" - are gone, because concurrent sessions are allowed and the audience
-- control explains its own state. Start is what explains itself.
function PG.RPS.OpenDialog()
  ensureDialog()
  if dlgScope then dlgScope:Refresh() end
  refreshDialog()
  dialog:Show()
end

PG.RegisterInit(function()
  -- capture the faire palette from the theme layer; the literal defaults
  -- above are the same values, so this is a formality, not a branch
  if PG.Theme and PG.Theme.C then
    Theme = PG.Theme
    local c = Theme.C("faire")
    for k in pairs(P) do
      if c[k] ~= nil then P[k] = c[k] end
    end
  end
  -- medal tally lives in its own tiny table; never touches the ledger
  if PG.db then
    if type(PG.db.rps) ~= "table" then PG.db.rps = { medals = {} } end
    if type(PG.db.rps.medals) ~= "table" then PG.db.rps.medals = {} end
  end
  PG.Comm.Register("RPS", onComm, onDrop)
  -- Whisper trust (SCOPE.md 4.3, retargeted at the registry by CONCURRENCY.md
  -- 5.4). A whisper carries no audience proof at all, so outside the group only
  -- the INVOLVED session vouches for one. Lite records never do: we never
  -- whispered them anything, so they can never legitimately expect a reply.
  if PG.Comm.RegisterTrust then
    PG.Comm.RegisterTrust("RPS", function(sender)
      local S = mySession()
      if not S or S.phase == "done" then return false end
      if sender == S.host then return true end
      if S.joined[sender] then return true end
      -- host side, wide scope, join window open: the first JOIN from a stranger
      -- is the entire point of a wider audience. The router's rate limiter
      -- bounds the abuse.
      if S.isHost and S.phase == "join" and S.scope ~= "group" then return true end
      return false
    end)
  end
  PG.Safety.OnChange(onSafetyChange)
  -- Accepting one invitation withdraws the rest (CONCURRENCY.md 5.6 rule 3).
  -- Until you accept one you see them all and choose; the moment a seat is
  -- taken - here or in the other game - every other popup this module raised
  -- comes down. Their lite records stay in the launcher list until they expire.
  PG.Session.OnChange(function(seat)
    if not seat then return end
    local held = keyOf(seat.host or "?", seat.token or "")
    for _, rec in pairs(sessions) do
      if rec.kind == "lite" and rec.askKey and rec.key ~= held then
        PG.UI.Dismiss(rec.askKey)
        rec.askKey = nil
      end
    end
  end)
end)
