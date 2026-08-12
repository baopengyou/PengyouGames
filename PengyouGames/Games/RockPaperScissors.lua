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
local HB_TIMEOUT = 35       -- client: host is dead after this much silence
local REVEAL_SECS = 6       -- pause between RESULT and the next ROUND
local VOID_PAUSE_SECS = 3   -- pause between VOID and the replayed round
local BEGIN_PAUSE_SECS = 2  -- pause between BEGIN and round 1
local MIN_REOPEN_SECS = 3   -- floor for the timer when re-opening a frozen round
local MAX_ROWS = 14
local MAX_ROUNDS = 9
local ROSTER_CAP = 40
local SYNC_COOLDOWN = 10    -- min secs between SYNCQ handling per sender (and per client send)
local SYNC_MAX_REPLAY = 20  -- resync deltas above this many messages -> SYNCNO

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

local S       -- session state; nil until the first session, phase=="done" after it
local ticker
local win, dialog, dlgInputs
local ui = {}
local rows = {}
local cardBtns = {}   -- pick char -> CardButton
local Theme           -- PG.Theme (nil if the theme layer is absent)

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt, hostOpen, clientRequestSync
local fxJoined, fxBegin, fxRound, fxPick, fxResult, fxVoid, fxEnd

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

local function live() return S ~= nil and S.phase ~= "done" end

-- RPS toasts carry the dice mark; plain text when Theme is absent
local function toast(text)
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then text = m .. " " .. text end
  end
  PG.UI.Toast(text)
end

-- FX runner: decoration only - errors are reported and swallowed, so no
-- animation/sound problem can ever touch game state or the wire.
local function runFX(fn, arg)
  if not Theme or not fn then return end
  local ok, err = pcall(fn, arg)
  if not ok then geterrorhandler()(err) end
end

local function broadcast(mtype, ...)
  return PG.Comm.Broadcast("RPS", mtype, S.token, ...)
end

local function startTicker()
  if ticker then ticker:Cancel() end
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

local function endSession(text)
  S.phase = "done"
  S.roundOpen = false
  S.endText = text
  stopTicker()
  if win then ui.bar:Stop() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Standings: cumulative points, dense ranking (ties share a place: 1,1,2,3).
-- Sorted points desc then name asc (byte order) - identical on every client.
-------------------------------------------------------------------------------

local function computeStandings()
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
  -- same relaxation as applyJoined: resync replays repair a spectator roster
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if S.joined[name] then
    S.joined[name] = nil
    for i = #S.roster, 1, -1 do
      if S.roster[i] == name then table.remove(S.roster, i) end
    end
  end
  if name == myName() then
    S.joinAccepted = false
    if win then win:Hide() end
  end
  RefreshUI()
end

-- dig (optional): the host's roster fingerprint at BEGIN. Absent (a peer that
-- predates the field) degrades to the count-only check.
local function applyBegin(count, rounds, dig)
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
  if not S.isHost and (#S.roster ~= count
    or (dig and rosterDigest(S.roster) ~= dig)) then
    -- our JOINED/LEFT stream disagrees with the host in size or in membership:
    -- we cannot map the pattern to names, so we spectate - and immediately ask
    -- the host to replay what we missed (resync can restore us to a player).
    -- The flag also gates the repair: applyJoined/applyLeft only accept
    -- replayed ops for a spectator mid-play.
    S.spectator = true
    toast("Rock Paper Scissors: out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxBegin)
end

local function applyRound(r, secs)
  if S.phase ~= "play" then return end
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
  if S.phase ~= "play" then return end
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
  if S.phase ~= "play" then return end
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
  if S.phase ~= "play" then return end
  local standings = computeStandings()
  S.standings = standings
  local winners = {}
  for i = 1, #standings do
    if standings[i].place == 1 then winners[#winners + 1] = standings[i].name end
  end
  -- a desynced spectator never applied RESULTs, so its totals are wrong:
  -- it must not write medals either (mirrors LG's spectator/ledger rule)
  if not S.spectator then persistMedals(winners) end
  S.ended = true
  local me = myName()
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
  toast("Rock Paper Scissors: " .. text)
  ShowWindow()
  endSession(text)
  runFX(fxEnd)
end

local function applyCancel(reason)
  if S.phase == "done" then return end
  local text
  if reason == "few" then
    text = "Cancelled - not enough players joined."
  elseif reason == "host" then
    text = "Cancelled by the host."
  else
    text = "Cancelled (" .. tostring(reason) .. ")."
  end
  toast("Rock Paper Scissors: " .. text)
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
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

local function hostStartRound(r)
  if broadcast("ROUND", r, S.roundSecs) then
    applyRound(r, S.roundSecs)
  else
    S.nextRoundAt = GetTime() + 2 -- send refused; the ticker retries
  end
end

local function hostAdvance(delay)
  if S.r >= S.rounds then
    S.endPending = true -- END goes out on the next clear tick
  else
    S.nextRoundAt = GetTime() + delay
  end
end

local function hostResolveRound()
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
  local r = S.r
  if broadcast("VOID", r) then
    S.broken = false
    S.frozen = false
    applyVoid(r)
    S.nextRoundAt = GetTime() + VOID_PAUSE_SECS
  end
end

local function hostReopenRound()
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.freezeRemaining or 0))
  -- clients treat a repeat ROUND for a known r as a timer refresh
  if broadcast("ROUND", S.r, secs) then
    S.frozen = false
    S.deadline = GetTime() + secs
    ShowWindow()
    if win then ui.bar:Start(secs) end
    RefreshUI()
  end
end

local function hostEnd()
  if S.endSent then return end -- END is already on the wire; onSent finishes up
  -- Medals persist (and the podium reveals) only once END has actually left
  -- the wire: a queued-then-lockdown-dropped END aborts via onDrop instead,
  -- with no medals anywhere - the same all-or-nothing shape as LG's ledger.
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    onSent = function()
      if S ~= sess or S.phase ~= "play" then return end
      S.endPending = nil
      applyEnd()
    end,
  }, "RPS", "END", S.token)
  if ok then S.endSent = true end
end

local function hostCancel(reason)
  -- END is already on the wire: clients will persist medals when it lands, so
  -- the host must complete too - no abort may interleave after END is queued
  if S.endSent then return end
  -- best effort: if the broadcast is refused, clients fall back to the
  -- heartbeat timeout; either way nothing is owed
  broadcast("CANCEL", reason)
  applyCancel(reason)
end

local function hostCloseJoin()
  if S.phase ~= "join" then return end
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
  if S.phase ~= "join" or S.joined[sender] then return end -- duplicate JOINs idempotent
  if broadcast("JOINED", sender) then
    hostRecordOp("J", sender)
    applyJoined(sender)
  end
end

local function hostHandleUnjoin(sender)
  if S.phase ~= "join" or sender == S.host or not S.joined[sender] then return end
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
  local n = #S.roster
  if n < 2 then return false end
  for i = 1, n do
    if not S.picks[S.roster[i]] then return false end
  end
  return true
end

local function hostHandlePick(sender, r, c)
  if S.phase ~= "play" or not S.roundOpen or S.broken then return end
  if r ~= S.r or not VALID_THROW[c] then return end
  if not S.joined[sender] then return end
  if S.picks[sender] then return end -- first click locks
  S.picks[sender] = c
  RefreshUI()
  -- early finish: same resolve path and gating as the ticker's deadline branch
  if not S.frozen and allPicked() and allClear() and not PG.Comm.Locked() then
    hostResolveRound()
  end
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

hostOpen = function(rounds, joinSecs, roundSecs)
  if live() then
    toast("Rock Paper Scissors: a game is already running.")
    return
  end
  local host = myName()
  if not host then return end
  if not IsInGroup() then
    toast("Rock Paper Scissors needs a party or raid.")
    return
  end
  local token = shortOf(host) .. "-" .. math.random(10000, 99999)
  -- broadcast OPEN before constructing S: submit-time lockdown drops invoke
  -- our onDrop synchronously, which must not see a half-built live session
  if not PG.Comm.Broadcast("RPS", "OPEN", token, rounds, joinSecs, roundSecs) then
    toast("Rock Paper Scissors: cannot start right now (addon messages are blocked).")
    return
  end
  S = {
    token = token,
    host = host,
    isHost = true,
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
  if broadcast("JOINED", host) then
    hostRecordOp("J", host)
    applyJoined(host) -- host auto-joins
  end
  -- a sync lockdown drop of JOINED (critical) aborts via onDrop above
  if not live() then return end
  startTicker()
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

local function doThrow(c)
  if not S or S.phase ~= "play" or not S.roundOpen then return end
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

local function clientOpen(token, sender, rounds, joinSecs, roundSecs)
  -- every addon client mirrors the session (even decliners), so the whole
  -- group agrees one session is live and sees identical standings
  S = {
    token = token,
    host = sender,
    isHost = false,
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
    syncAllClear = allClear(), -- tracks all-clear transitions for resync
    lastHB = GetTime(),
    joinDeadlineDisplay = GetTime() + joinSecs,
  }
  startTicker()
  local acceptLabel = "Play"
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then acceptLabel = m .. " Play" end
  end
  PG.UI.Ask("rps-invite",
    shortOf(sender) .. " started Rock Paper Scissors - best of " .. rounds .. ". Play?",
    acceptLabel, "Pass", joinSecs,
    function()
      if S and S.token == token and S.phase == "join" then
        PG.Comm.Whisper(S.host, "RPS", "JOIN", S.token)
        S.joinAccepted = true -- provisional; the host's JOINED broadcast confirms
        ShowWindow()
        if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
      end
    end,
    nil, "faire")
end

local function clientHostDead()
  toast("Rock Paper Scissors: lost contact with the host - game abandoned.")
  endSession("Abandoned - the host stopped responding.")
end

-- highest round R such that RESULTs 1..R have all been applied locally
local function appliedThrough()
  local r = 0
  while S.appliedResults[r + 1] do r = r + 1 end
  return r
end

-- Resync request: ask the host to replay whatever we missed (loading
-- screens, encounter gaps). At most one SYNCQ per SYNC_COOLDOWN; a refused
-- or cooling-down request stays pending and the ticker retries it. Never
-- sent by the host, after SYNCNO, or for a finished session.
clientRequestSync = function()
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
  S.spectator = false
  if S.roundOpen and S.r >= 1 then S.syncHoldR = S.r end
  toast("Rock Paper Scissors: back in sync - you are back in the game.")
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

local function onComm(mtype, token, sender, f1, f2, f3, f4)
  if mtype == "OPEN" then
    if live() then
      -- one active RPS session per group; a stray OPEN is ignored with a toast
      toast("Rock Paper Scissors: " .. shortOf(sender) .. " tried to start a game, but one is already running.")
      return
    end
    local rounds = num(f1, 1, MAX_ROUNDS)
    local joinSecs = num(f2, 5, 600)
    local roundSecs = num(f3, 5, 600)
    if not (rounds and joinSecs and roundSecs) then return end
    if type(token) ~= "string" or token == "" then return end
    clientOpen(token, sender, rounds, joinSecs, roundSecs)
    return
  end
  if not S or S.phase == "done" or token ~= S.token then return end
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
  if sender ~= S.host then return end -- only the host may drive the session
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  if S.phase == "join"
    and (mtype == "ROUND" or mtype == "RESULT" or mtype == "VOID" or mtype == "END") then
    -- we missed BEGIN entirely: spectate for now and ask the host to replay
    -- what we missed - resync can fully restore us (roster stream + BEGIN +
    -- RESULTs), unlike the old permanent sit-out
    S.phase = "play"
    S.spectator = true
    toast("Rock Paper Scissors: out of sync with the host - resyncing...")
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
        toast("Rock Paper Scissors: too far out of sync to catch up - spectating this game.")
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

local function onDrop(mtype)
  if not (S and S.isHost and live()) then return end
  if not CRITICAL_DROP[mtype] then return end
  if REPLAYABLE[mtype] and S.syncReplayUntil and GetTime() < S.syncReplayUntil then return end
  toast("Rock Paper Scissors: game aborted - addon messages were blocked mid-send.")
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
  if not live() then return end
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

onTick = function()
  if not S or S.phase == "done" then return end
  local now = GetTime()
  if S.isHost then
    if not IsInGroup() then
      toast("Rock Paper Scissors: you left the group - game abandoned.")
      endSession("Abandoned - you left the group.")
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
    elseif now - (S.lastHB or now) > HB_TIMEOUT then
      clientHostDead()
      return
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
    validate = function() return S == sess and sess.ended == true end,
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
  win.__pgResume = function() return S ~= nil end

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
    if S and S.isHost and S.phase == "join" then hostCloseJoin() end
  end)
  ui.startBtn:SetPoint("BOTTOMLEFT", 20, 16)
  ui.cancelBtn = PG.UI.Button(win, "Cancel game", 105, 22, function()
    if S and S.isHost and live() then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOMRIGHT", -20, 16)
  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", 105, 22, function()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "RPS", "UNJOIN", S.token)
    end
  end)
  ui.withdrawBtn:SetPoint("BOTTOMLEFT", 20, 16) -- shares the host-only Start slot
  ui.againBtn = PG.UI.Button(win, "Play again", 105, 22, function()
    if S and S.isHost and S.phase == "done" and S.ended then
      -- fresh session, same config (S is replaced inside hostOpen)
      hostOpen(S.rounds, S.joinSecs, S.roundSecs)
    end
  end)
  ui.againBtn:SetPoint("BOTTOM", 0, 16)

  if Theme then
    win.__pgBannerSlot = rowAt(1) -- banners slide in over the standings area
  end
end

RefreshUI = function()
  if not win or not S then return end
  local now = GetTime()
  local me = myName()
  local isJoin = S.phase == "join"
  local isPlay = S.phase == "play"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false

  if isJoin then
    ui.info:SetText("Best of " .. S.rounds .. " - " .. S.roundSecs .. "s rounds|n"
      .. #S.roster .. " in so far")
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
    if S.spectator then
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
  if S.spectator then
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
  if not S then return end
  if not (S.isHost or S.joinAccepted) then return end -- mirrors stay windowless
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

local function ensureDialog()
  if dialog then return end
  dialog = PG.UI.Window("rpsdialog", "Start Rock Paper Scissors", 320, 240, "faire")
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
  local startLabel = "Start game"
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then startLabel = m .. " Start game" end
  end
  local startBtn = PG.UI.Button(dialog, startLabel, 150, 26, function()
    local rounds = fieldValue(dlgInputs.rounds, 1, MAX_ROUNDS)
    local joinSecs = fieldValue(dlgInputs.joinSecs, 15, 120)
    local roundSecs = fieldValue(dlgInputs.roundSecs, 10, 60)
    if Theme then Theme.Sound("stamp") end
    dialog:Hide()
    hostOpen(rounds, joinSecs, roundSecs)
  end)
  startBtn:SetPoint("BOTTOM", 0, 18)
end

-- Launcher / slash entry point: host config dialog (or the running game).
function PG.RPS.OpenDialog()
  if live() then
    toast("Rock Paper Scissors: a game is already running.")
    ShowWindow()
    return
  end
  if not IsInGroup() then
    toast("Rock Paper Scissors needs a party or raid.")
    return
  end
  ensureDialog()
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
  PG.Safety.OnChange(onSafetyChange)
end)
