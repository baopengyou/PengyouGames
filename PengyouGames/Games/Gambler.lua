-- Games/Gambler.lua - The Gambler: everyone rolls once, the lowest roll pays the
-- highest roll the difference between them.
--
-- REAL GOLD, and the only game in the suite whose raw data does not travel on
-- the wire. The host sets a max wager N; every seated player types /roll N (or
-- presses ROLL, which asks the client to type it for them) inside one timed
-- window; when the window closes the host publishes ONE positional pattern over
-- the sorted roster plus the two extreme rolls, and every client turns that into
-- the same integer rows and commits them once.
--
-- HOW A ROLL REACHES THE HOST (ROLLBRIEF 2, and it used to be otherwise):
--
--   EVERY CLIENT OBSERVES ONLY ITS OWN ROLL AND REPORTS IT OVER THE WIRE, as a
--   ROLLED whisper to the host. The host adjudicates from those reports plus its
--   own roll; it never tries to read anybody else's system line.
--
-- The version this replaced had the host watch CHAT_MSG_SYSTEM for EVERY
-- player's /roll and resolve the printed name against the frozen roster. That
-- lookup misses whenever a line arrives without a realm, and the roll was then
-- dropped in silence: a real two-player test read as "my rolls count, theirs
-- never do". Nothing about the fix is a compromise. You always know your own
-- name, and the SENDER of an addon message is vouched by the delivery itself, so
-- the whole name-matching path - and the ambiguity rule that broke the game -
-- is simply gone.
--
-- What the local observation still buys, and it is the reason this game uses a
-- real /roll rather than a number the addon invents: the number on your screen
-- is the one the client rolled, in public, and you watched it land. The addon
-- NEVER generates a number and never types in chat. The player types /roll, or
-- presses a button that calls RandomRoll behind an existence guard - and even
-- then nothing is assumed until the system line is observed.
--
-- THE HOST IS TRUSTED here, exactly as it is in Loot Goblins, The Pull Book and
-- Rock Paper Scissors: clients commit the ledger from its RESULT. A client may
-- TELL its player that the host scored their own roll differently from what they
-- watched, but it must never refuse to record a game over it. The refusal that
-- used to live here is what turned a hardening pass into an unplayable game.
--
-- A player without the addon can no longer take part: there is nobody to report
-- their roll. That is a real, small loss and it is the honest price.
--
-- ONE ROUND PER SESSION. Play again mints a new session (same-host supersession,
-- CONCURRENCY.md 4.3), so there is no round number anywhere in this file, one
-- commit point, and no way for a resync to double-count gold.
--
-- WARNING FOR THE NEXT READER: S.rolls lives only in memory. A /reload mid-game
-- takes the registry with it (CONCURRENCY.md 9.6), so the host's session simply
-- ends and every client times out with NO ledger. Nothing is resumed and nothing
-- is owed - do not "fix" that by persisting rolls.
local ADDON, PG = ...

PG.GB = {}

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local TICK = 0.5             -- master ticker period (drives all session timing)
local HB_INTERVAL = 10       -- host heartbeat cadence
local HB_PROBE = 15          -- client: host silence that triggers one SYNCQ
local HB_TIMEOUT = 35        -- client, GROUP scope: host is dead after this silence
-- Wide scope (SCOPE.md 6.2), the Rock Paper Scissors constants and reasoning:
-- outside our own group the host can be inside an encounter (or a whole M+ run)
-- where the 12.1 comms lockdown refuses every send, while we stand in a city
-- with a clear safety state. Silence there is a paused game, not a dead host.
local HB_QUIET_WIDE = 150
local HB_GIVEUP_WIDE = 300
local QUIET_SYNC_EVERY = 60  -- at most one heal request per minute while quiet
local BEGIN_PAUSE_SECS = 2   -- BEGIN -> ROLL, so the roster lands before the timer
local ROLL_WAIT_PROBE = 6    -- client: BEGIN with no ROLL for this long -> SYNCQ
local MIN_REOPEN_SECS = 3    -- floor when re-opening a frozen roll window
local SYNC_COOLDOWN = 10     -- min secs between SYNCQ per sender (and per client send)
local SYNC_MAX_REPLAY = 20   -- resync deltas above this many messages -> SYNCNO
local ROLL_CONFIRM = 2       -- ROLL button: secs before it is offered again
local WARN_THROTTLE = 3      -- min secs between wrong-ceiling warnings
local MAX_ROWS = 10          -- roster lines drawn in the window: derived from
                             -- the band between ROSTER_Y and the result block
                             -- at the shared Theme.METRIC.ROW_PITCH of 20

-- ONE ROUND PER SESSION (see the file header), so the ROLLED report's `seq`
-- field - the round number - only ever holds this. The field exists so both roll
-- games carry the identical wire shape; ROLLBRIEF 3 fixes it and neither module
-- improvises its own.
local GB_ROUND = 1

local MAX_WAGER = 100000     -- gold; matches the Loot Goblins buy-in cap
local MIN_WAGER = 2          -- N == 1 makes every roll identical
local ROSTER_CAP = 40
local MAX_NAME_W = 64        -- inbound name-field bound (Ledger's MAX_NAME)

-- The wide-scope heartbeat pair above is not decoration. It used to be absent
-- with a comment saying it was not needed because this game was group-only; the
-- moment guild and public opened, 35s of silence stopped meaning "dead host"
-- and started meaning "the host pulled a boss two zones away". Do not remove it
-- again without closing the scopes first.

-- Concurrency budgets (CONCURRENCY.md 2.1), identical to LG/RPS: one FULL record
-- plus bounded lite records for sessions we merely overhear.
local MAX_LITE = 8
local MAX_RECENT = 16
local RECENT_TTL = 120
local DONE_TTL = 60
local LITE_TTL_PAD = 10
local LITE_TTL_MIN = 15
local LITE_TTL_MAX = 180
local SWEEP_EVERY = 4
local BUSY_THROTTLE = 60

-- PARTY, GUILD AND PUBLIC. This was group-only because a /roll system line
-- reaches nobody outside your party or raid, so no wider audience could see the
-- evidence the game was made of. The roll now travels as an addon message
-- (ROLLBRIEF 2) and that restriction has no technical basis left, so all three
-- audiences are open. The rest of that one change: the wide heartbeat pair
-- above, the RPS-shaped trust predicate at the bottom of this file, the ledger
-- vouch in applyResult (a table at every scope, which is what Commit demands at
-- public), the picker copy, the Rules page and the README.
PG.GB.SCOPES = { group = true, guild = true, public = true }

-- BRIEF 1.1: the launcher reads this instead of special-casing module codes.
-- The Gambler demands a timed decision from a human, so it takes the seat.
PG.GB.SEAT = true

local MODULE_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors",
                      PB = "The Pull Book", DR = "Death Roll",
                      GB = "The Gambler", QZ = "Quiz" }

-- Faire palette, literal spec values; refreshed from PG.Theme.C at init when the
-- theme layer is present (the values are identical). Presentation only.
local P = {
  chgold = "|cffffd876", chgreen = "|cff7deda4", chred = "|cffff8a70",
  chgray = "|cffa8a89c",
  CHALK = { 0.95, 0.93, 0.87 }, CHGOLD = { 1.00, 0.85, 0.46 },
  CHGRAY = { 0.66, 0.66, 0.61 },
}

-------------------------------------------------------------------------------
-- WIRE PROTOCOL (v3 envelope, unchanged: "3|GB|<mtype>|<token>" + "|" fields).
--
--   OPEN   B host  wager, joinSecs, rollSecs, scopeCode
--   JOIN   W ->host                       "deal me in"
--   UNJOIN W ->host                       withdraw, join phase only
--   JOINED B host  fullName               roster add
--   LEFT   B host  fullName               roster remove
--   BEGIN  B host  count, wager, digest   join closed, roster frozen
--   ROLL   B host  secs                   window open (a repeat = timer refresh)
--   ROLLED W ->host  seq, value, low, high   MY OWN roll, nobody else's
--   RESULT B host  pattern, lowRoll, highRoll   TERMINAL, the sole commit point
--   CANCEL B host  reason                 aborted; no ledger, ever
--   HB     B host  phase                  heartbeat, every 10s, never in lockdown
--   SYNCQ  W ->host  phase, rosterN, digest    resync request (10s cooldown)
--   SYNCOK W host->  nothing missed
--   SYNCNO W host->  delta too large: spectate this session
--
-- ROLLED is the one message this game gained and it is shared verbatim with
-- Death Roll (ROLLBRIEF 3): same name, same field order, same validation order.
-- `seq` is the round number (always GB_ROUND here), `value`/`low`/`high` are the
-- roll exactly as this client observed it, and `low` must be 1. It is WHISPERED
-- in every scope, like every other 1:1 message in this addon. The host's own
-- roll is applied locally at observe time and never whispered to itself.
--
-- `pattern` is one char per participant in sorted-roster order:
--   L  rolled, tied for the lowest valid roll   - pays
--   H  rolled, tied for the highest valid roll  - receives
--   -  rolled, strictly between (or everyone tied) - pays and receives nothing
--   X  never put a valid roll on the correct ceiling inside the window
-- When lowRoll == highRoll the host emits "-" for every roller and no L/H at
-- all, so "everybody tied" is representable without a char meaning both.
--
-- BYTE BUDGET (SPEC 2.6; submit() refuses over 250, the target is 200). Worst
-- case is RESULT at the 40-player roster cap with a 24-byte token and 6-digit
-- rolls: "3|GB|RESULT|" (12) + 24 + "|" + 40 + "|" + 6 + "|" + 6 = 91 bytes.
-- JOINED with a 64-byte name is 12 + 24 + 1 + 64 = 101. ROLLED is
-- "3|GB|ROLLED|" (12) + 24 + "|1" (seq, 2) + "|" + 6 (value) + "|1" (low, 2)
-- + "|" + 6 (high) = 54, and it does NOT grow with the roster - one client
-- reports one roll, so the 40-player case is still 54. Everything else is under
-- 60. Nothing is multipart.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- The session registry (CONCURRENCY.md 2.1). Identical in shape and in constants
-- to RockPaperScissors.lua: one FULL record (hosted or seated) plus bounded LITE
-- records for overheard sessions. Identity is the PAIR (host, token), never the
-- token alone, so two hosts may mint the same token and never collide.
-------------------------------------------------------------------------------

local sessions = {}   -- [key] = record, key = host .. "|" .. token
local mine            -- key of the ONE full record (hosted or seated), or nil
local recent = {}     -- [key] = GetTime() when it died; replay defence
local recentQ = {}    -- FIFO of poisoned keys, capped at MAX_RECENT
local regCount = 0    -- #sessions, kept incrementally (pairs() is never counted)
local liteCount = 0
local sweepTicks = 0

local ticker
-- `win` is the play window and stays its own window. `page` is the setup panel,
-- which is no longer a window at all: it is a level-2 page inside the one shell
-- (PLAN 1.1), handed to us by PG.UI.Shell.
local win, page, dlgInputs, dlgScope, dlgNote, dlgStart
local ui = {}
local rows = {}
local Theme           -- PG.Theme (nil if the theme layer is absent)

local busyToastAt, busyPending = 0, 0
local overflowToastAt = 0

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt, hostOpen, clientRequestSync
local freezeWindow, thawWindow
local evict, endSession, refreshDialog, maybeEarlyFinish
local fxJoined, fxBegin, fxRoll, fxMyRoll, fxResult

local function keyOf(host, token) return host .. "|" .. token end

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

-- inbound roster name: non-secret, non-empty, bounded (Ledger refuses longer)
local function validName(v)
  local s = PG.SafeStr(v)
  if not s or s == "" or #s > MAX_NAME_W then return nil end
  return s
end

-- RESULT pattern: one char per participant in sorted-roster order, L/H/-/X
local function validPattern(p)
  if type(p) ~= "string" or #p < 1 or #p > ROSTER_CAP then return false end
  for i = 1, #p do
    local c = p:sub(i, i)
    if c ~= "L" and c ~= "H" and c ~= "-" and c ~= "X" then return false end
  end
  return true
end

-- Roster agreement fingerprint, copied verbatim from RockPaperScissors.lua.
-- MANDATORY here (BRIEF 4.1): RESULT is positional over the sorted roster and no
-- name travels with it, so a mirror with the right SIZE but the wrong MEMBERS
-- would pay the wrong players real gold - and the rows it wrote would still be
-- zero-sum, still inside the cap, still fully vouched, and would pass all four
-- ledger gates. A count comparison cannot see that; this can.
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

local function isDigest(v)
  return type(v) == "string" and v:match("^%x%x%x%x$") ~= nil
end

local function allClear()
  -- Plain combat is deliberately absent: it neither blocks addon sends (the 12.1
  -- comms lockdown is encounter/M+/PvP-scoped, gated separately through
  -- PG.Comm.Locked()) nor pauses the game.
  local s = PG.Safety.state
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

-- The one gate that matters to a roll window: while it is shut, PG.Rolls
-- DISCARDS every observation (BRIEF 3.4), so the window must stop rather than
-- burn down on rolls that can never be seen.
local function rollGateOpen()
  return allClear() and not PG.Comm.Locked()
end

local function live()
  local S = mySession()
  return S ~= nil and S.phase ~= "done"
end

local function rollsReady()
  return (PG.Rolls and PG.Rolls.Ready and PG.Rolls.Ready()) and true or false
end

local function rollsAvailable()
  return (PG.Rolls and PG.Rolls.Available and PG.Rolls.Available()) and true or false
end

-- Attribution (CONCURRENCY.md 5.7): with more than one record known, a bare
-- "The Gambler: ..." cannot say WHICH game the line is about.
local function toast(text, host, opts)
  local name = "The Gambler"
  if host and regCount > 1 then name = name .. " (" .. shortOf(host) .. ")" end
  local line = name .. ": " .. text
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then line = m .. " " .. line end
  end
  PG.UI.Toast(line, opts)
end

-- FX runner: decoration only - errors are reported and swallowed, so no
-- animation or sound problem can ever touch game state, gold or the wire.
local function runFX(fn, arg)
  if not Theme or not fn then return end
  local ok, err = pcall(fn, arg)
  if not ok then geterrorhandler()(err) end
end

-- Every send carries the session's own scope (SCOPE.md 2.2). Only the involved
-- record ever broadcasts; a lite record has nothing to say and never spends a
-- token from the shared 10-token bucket.
local function broadcast(mtype, ...)
  local S = mySession()
  if not S then return false end
  return PG.Comm.Broadcast(S.scope, "GB", mtype, S.token, ...)
end

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
-- Registry primitives: identity, poisoning, listing, eviction. RPS's, verbatim
-- apart from the module string.
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

-- PG.NextToken is the real minter (CONCURRENCY.md 3.2, shipped in Core 1.1.0):
-- one persisted, monotonic counter shared by every module plus a 3-char random
-- seatbelt for a SavedVariables rollback. The local fallback exists only so this
-- file cannot be broken by a Core that predates it; it is the same shape.
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

-- A finished session's key can never be resurrected (4.5).
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

-- The launcher's Open games list is a VIEW of the lite records (5.10 rule 2).
-- Both calls are existence-guarded: this file has no dependency on the launcher
-- having learned about GB yet.
local function listOpen(rec)
  rec.listed = true
  if PG.Launcher and PG.Launcher.AddOpenGame then
    pcall(PG.Launcher.AddOpenGame, {
      game = "GB", host = rec.host, token = rec.token, scope = rec.scope,
      expires = rec.expires, key = rec.key,
    })
  end
end

local function unlistOpen(rec)
  if not rec.listed then return end
  rec.listed = false
  if PG.Launcher and PG.Launcher.RemoveOpenGame then
    pcall(PG.Launcher.RemoveOpenGame, "GB", rec.host, rec.token)
  end
end

local function register(rec)
  sessions[rec.key] = rec
  regCount = regCount + 1
  if rec.kind == "lite" then liteCount = liteCount + 1 end
  syncTicker()
end

-- The ONLY place a record leaves the registry, and it always poisons the key.
-- Evicting the involved record frees the seat and hides the window (5.9), so a
-- replaced session can never leave a live-looking one on screen. keepWindow
-- leaves a FINISHED game's numbers up while its record steps aside for the next.
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
    PG.Session.Release("GB", rec.token)
    -- guarded on the record the window is actually showing. Unguarded, this hid
    -- whatever window happened to be up, including one belonging to a different
    -- record (PLAN 5.3). A frozen result has already cleared __pgRec, so it is
    -- never hidden here either.
    if win and win.__pgRec == rec and not keepWindow then
      win.__pgRec = false
      win:Hide()
    end
  end
  poison(key)
  syncTicker()
end

-------------------------------------------------------------------------------
-- Teardown (CONCURRENCY.md 7.1). The instant phase becomes "done": the seat is
-- released (I2), the invitation comes down, the launcher row goes, and the
-- window keeps its final numbers until DONE_TTL sweeps the record away.
-------------------------------------------------------------------------------

endSession = function(text)
  local S = mySession()
  if not S then return end
  S.phase = "done"
  S.rollOpen = false
  S.frozen = false
  S.endText = text
  S.doneAt = GetTime()
  PG.Session.Release("GB", S.token)
  PG.UI.Dismiss(S.askKey)
  S.askKey = nil
  unlistOpen(S)
  if win then ui.bar:Stop() end
  RefreshUI()
end

-- THERE IS NO NAME RESOLUTION IN THIS FILE ANY MORE, and that is the fix.
--
-- What stood here matched a name printed in a system line against the frozen
-- roster, with a short-name fallback for cross-realm players and a refusal to
-- BEGIN at all when two members shared a short name. Every part of it existed
-- because the host was reading OTHER PLAYERS' rolls off CHAT_MSG_SYSTEM. It
-- misses on the realm-less common case, and the round-1 resolution - "on
-- ambiguity, DROP the roll" - was safe for gold and identical, from the seat of
-- the player it dropped, to "you cannot play".
--
-- Every client now observes only ITS OWN roll, where the name is
-- PG.FullName("player") and cannot be wrong, and reports it as a ROLLED whisper
-- whose sender the delivery vouches for. Do not reintroduce a system-message
-- fallback for players without the addon: that is the exact machinery this
-- deleted, and it brings the bug back with it.

-------------------------------------------------------------------------------
-- The gold math (design ledger section 2). Integers throughout, exact by
-- construction: no dust bucket, no discarded remainder, no division whose result
-- is thrown away, so PG.Ledger.Commit's sum ~= 0 gate is a genuine assertion
-- rather than decoration.
-------------------------------------------------------------------------------

-- Loot Goblins' exact-integer floor; a % b is exact for integer-valued floats.
local function idiv(a, b) return (a - a % b) / b end

-- pattern + the two extremes -> { name = integerDelta } for EVERY roster member,
-- zeros included, plus the two role groups for the UI.
--
-- TIES: the total moved is exactly D = highRoll - lowRoll whatever the shape of
-- the tie. The L group collectively pays D, the H group collectively receives D,
-- each split evenly with the remainder going to the first r members in
-- sorted-roster order. A tie shares the ROLE and leaves the AMOUNT alone, so a
-- game advertised as "up to N" never moves more than N-1 gold and no player's
-- exposure changes because somebody else happened to match them.
--
-- sum(payments) = qL*k + rL = D and sum(receipts) = qH*m + rH = D are integer
-- identities, so the rows sum to zero exactly. Nothing here rounds.
local function outcomeRows(S)
  local res = S.result
  local rows2, L, H = {}, {}, {}
  for i = 1, #S.roster do rows2[S.roster[i]] = 0 end
  if not res or #res.pattern ~= #S.roster then return rows2, L, H end
  for i = 1, #S.roster do
    local c = res.pattern:sub(i, i)
    if c == "L" then
      L[#L + 1] = S.roster[i]
    elseif c == "H" then
      H[#H + 1] = S.roster[i]
    end
  end
  local D = res.high - res.low
  local k, m = #L, #H
  -- k and m are both >= 1 whenever D > 0 (wire rule 5, checked on receipt); the
  -- guard is belt and braces so a pattern that slipped through cannot divide by
  -- zero or produce a non-zero-sum table.
  if D <= 0 or k < 1 or m < 1 then return rows2, L, H end
  local qL = idiv(D, k)
  local rL = D - qL * k
  local qH = idiv(D, m)
  local rH = D - qH * m
  for j = 1, k do rows2[L[j]] = -(qL + ((j <= rL) and 1 or 0)) end
  for j = 1, m do rows2[H[j]] = (qH + ((j <= rH) and 1 or 0)) end
  return rows2, L, H
end

-------------------------------------------------------------------------------
-- WHAT USED TO BE HERE: THE CROSS-CHECK, AND WHY IT IS GONE (ROLLBRIEF 4).
--
-- Three functions - crossCheckOK, sawDecidingRolls and resultOnTime - let a
-- client REFUSE to write the ledger when the host's RESULT disagreed with the
-- rolls that client had watched, when it had not watched both deciding rolls,
-- or when the RESULT arrived before its own window had run out. They were built
-- on the assumption that every client sees every /roll, which is exactly the
-- assumption this rework deletes: a client now only ever watches its own roll,
-- so it holds no evidence about anybody else and there is nothing left to
-- contradict the host with.
--
-- They are not being replaced by a wire-borne equivalent, deliberately. The
-- owner's ruling is that the host is TRUSTED here, exactly as it already is in
-- Loot Goblins, The Pull Book and Rock Paper Scissors, and that a mechanism
-- which can stop an honest game settling costs more than the cheating it
-- prevents. If you are about to add a check that can refuse a commit, you are
-- rebuilding this block.
--
-- ownRollNote below is the one survivor and it is INFORMATION, never a refusal:
-- your own slot, your own roll, and it catches the failure that actually
-- happens - your report never reached the host.
-------------------------------------------------------------------------------

-- Returns a sentence when the host's RESULT says something about OUR OWN slot
-- that our own roll does not support, or nil. It reads one character and one
-- number, it is only ever shown to the player it is about, and NOTHING in this
-- file branches on it: the ledger is written either way.
--
-- The case worth the code is the first one. A ROLLED whisper that the comms
-- lockdown swallowed leaves us marked "X" while our own chat frame shows the
-- roll, and "your roll never reached the host" is the difference between a bug
-- report and a shrug.
local function ownRollNote(S)
  local me, res = myName(), S.result
  if not (me and res) then return nil end
  local v = S.rolls[me]
  if not v then return nil end
  local idx
  for i = 1, #S.roster do
    if S.roster[i] == me then idx = i end
  end
  if not idx or idx > #res.pattern then return nil end
  local c = res.pattern:sub(idx, idx)
  if c == "X" then
    return "your roll of " .. v .. " never reached the host, so you were scored"
      .. " as not having rolled."
  end
  local want
  if c == "L" then want = res.low elseif c == "H" then want = res.high end
  if want and v ~= want then
    return "the host recorded " .. want .. " for your roll; this client saw " .. v .. "."
  end
  if c == "-" then
    -- Our slot pays and collects nothing. That is wrong two ways: a roll outside
    -- the published range was never in this round at all, and a roll EQUAL to an
    -- extreme (with the two extremes distinct) is a slot that should have been
    -- L or H.
    if v < res.low or v > res.high then
      return "the host scored your roll inside " .. res.low .. "-" .. res.high
        .. "; this client saw " .. v .. "."
    end
    if res.low ~= res.high and (v == res.low or v == res.high) then
      return "the host scored your roll as neither the low nor the high;"
        .. " this client saw " .. v .. "."
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Shared state transitions. The host applies these locally at send time (the
-- loopback rule); clients apply them on receipt of host broadcasts.
-------------------------------------------------------------------------------

local function applyJoined(name)
  local S = mySession()
  if not S then return end
  -- normal path: join phase. Resync replays land here too, so a desynced
  -- spectator mid-window can repair its roster (idempotent set-add).
  if S.phase ~= "join" and not (S.phase == "roll" and S.spectator) then return end
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
  if S.phase ~= "join" and not (S.phase == "roll" and S.spectator) then return end
  if S.joined[name] then
    S.joined[name] = nil
    for i = #S.roster, 1, -1 do
      if S.roster[i] == name then table.remove(S.roster, i) end
    end
  end
  if name == myName() and not S.isHost then
    -- Withdrawal (CONCURRENCY.md 7.2): one of the two paths besides endSession
    -- allowed to free the seat (I2). There is no withdrawal after BEGIN.
    S.joinAccepted = false
    evict(S.key)
    return
  end
  RefreshUI()
end

-- dig (optional): the host's roster fingerprint at BEGIN.
local function applyBegin(count, wager, dig)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" then
    -- A client that missed BEGIN entirely (forced spectator, S.count == nil)
    -- absorbs the original fields so resync agreement can be evaluated at all.
    if S.phase == "roll" and S.spectator and S.count == nil then
      S.count = count
      S.wager = wager
      S.digest = dig
      RefreshUI()
    end
    return
  end
  -- WAGER INTEGRITY. This is a gold game: the number you agreed to when you
  -- pressed Play is the number you play for. A host that changed it after we
  -- opted in does not get our consent by default.
  if not S.isHost and S.wager and wager ~= S.wager then
    toast("the host changed the wager after you joined - you are out.", S.host,
      { key = "gb-status" })
    endSession("The host changed the wager after you joined.")
    evict(S.key)
    return
  end
  S.phase = "roll"
  S.count = count
  S.wager = wager
  S.digest = dig
  S.beganAt = GetTime()    -- the ROLL is due BEGIN_PAUSE_SECS after this
  -- S.rolls / S.rollN are NOT initialized here. Two paths reach the roll phase
  -- without ever running applyBegin - the comm prologue's forced-spectator
  -- branch, and the absorb-and-return branch above - and a nil index there is
  -- swallowed by Comm's pcall, so the client silently records nothing. They are
  -- built with the record instead. Nothing can be lost by not clearing them:
  -- rolls are only ever recorded while the window is open.
  local me = myName()
  -- Size AND membership, never size alone: dig is guaranteed present by the
  -- prologue, so there is no "no digest sent" case to fall back to and a mirror
  -- that merely counts right is not a mirror we can read a pattern off.
  local agrees = (#S.roster == count) and rosterDigest(S.roster) == dig
  if not S.isHost and agrees and not (me and S.joined[me]) then
    -- Our mirror agrees with the host in size AND membership and we are not in
    -- it: our JOIN never landed. Tracking a game we cannot play is pointless,
    -- and the seat is not.
    toast("your join did not reach the host - you are not in this game.", S.host,
      { key = "gb-status" })
    endSession("You are not in this game.")
    evict(S.key)
    return
  end
  if not S.isHost and not agrees then
    -- We cannot map a positional pattern onto a roster we do not share, so we
    -- spectate (and write no ledger) while asking the host to replay what we
    -- missed. The flag also gates the repair: applyJoined/applyLeft only accept
    -- replayed ops for a spectator mid-window.
    S.spectator = true
    toast("out of sync with the host - resyncing...", S.host, { key = "gb-status" })
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxBegin)
end

-- Forward: applyRoll drains the ring through the observer, and the observer
-- calls maybeEarlyFinish, which can end the session mid-drain.
local drainRolls

local function applyRoll(secs)
  local S = mySession()
  if not S or S.phase ~= "roll" then return end
  local now = GetTime()
  local first = not S.rollOpenedAt
  S.rollOpen = true
  -- FORWARD ONLY, and DELIBERATELY KEPT (ROLLBRIEF 4 asked whether it also
  -- protects an honest re-open; it does). onRollObserved drops our own roll at
  -- or after this deadline, so anything that moves it backward costs the player
  -- their roll. Two honest ways that happens, both ordinary:
  --   - a resync replay whispers ROLL(remain) while a broadcast ROLL(rollSecs)
  --     is in flight, and whispers and party messages do not share a delivery
  --     order. The stale one must not shorten a window the fresh one extended.
  --   - a duplicated or late ROLL restating an instant we have already passed.
  -- Nothing honest needs a SHORTER window: a re-open after a freeze re-bases the
  -- REMAINING seconds from a LATER instant (hostReopenRoll), so its new deadline
  -- is always at or after the old one and this never blocks it.
  local newDeadline = now + secs
  if not S.deadline or newDeadline > S.deadline then S.deadline = newDeadline end
  -- Clearing the freeze HERE as well as in hostReopenRoll is deliberate: an
  -- interrupted window that never gets its re-open cleared is a session that
  -- hangs forever with no RESULT, no CANCEL and no ledger.
  S.frozen = false
  S.rollRemaining = nil
  if first then
    -- WHERE THE DRAIN REACHES BACK TO, and it is not "now" any more.
    --
    -- The host opened this window (rollSecs - secs) seconds ago: ROLL(remain) is
    -- exactly how a client that lost the broadcast is told about a window that
    -- is already running (hostHandleSyncQ's replay), and a player looking at a
    -- raid full of /roll lines will very reasonably have rolled during that gap.
    -- The host used to see that roll on its own screen; it does not any more, so
    -- if the drain below starts at `now` the roll is dropped in silence - which
    -- is the precise failure this whole rework exists to remove.
    --
    -- Bounded by the host's OWN window and never further, so a roll made before
    -- the game began still cannot count (harness scenario 29) and the ring's own
    -- TTL caps it again behind that.
    local opened = now
    local full = S.rollSecs
    if full and secs < full then opened = now - (full - secs) end
    S.rollOpenedAt = opened
  end
  ShowWindow()
  -- The bar shows the deadline we are actually keeping, which is `secs` whenever
  -- the deadline moved and less when a stale ROLL failed to move it. Clamped
  -- because a stale ROLL arriving AFTER the deadline makes that difference
  -- negative, and a negative duration is not a bar (Widgets clamps it too).
  if win then ui.bar:Start(math.max(1, S.deadline - now)) end
  -- A window that opens LATE - the host's ROLL queued behind the shared token
  -- bucket, or a re-open after a freeze - would otherwise ignore a roll the
  -- player already made and watched land in their own chat frame (BRIEF 3.1).
  drainRolls(S)
  S = mySession()
  if not S or S.phase ~= "roll" then
    RefreshUI()
    return -- the drain completed the round (everyone had already rolled)
  end
  RefreshUI()
  runFX(fxRoll)
end

local function applyResult(pattern, lowRoll, highRoll)
  local S = mySession()
  if not S or S.phase ~= "roll" then return end
  S.result = { pattern = pattern, low = lowRoll, high = highRoll }
  S.rollOpen = false
  S.frozen = false
  local me = myName()
  local D = highRoll - lowRoll

  -- The pattern maps onto our roster one-for-one, or it does not map at all.
  local mapped = (#pattern == #S.roster)
  if not mapped and not S.spectator then
    S.spectator = true
    S.syncMissed = true
  end
  local rows2, L, H = outcomeRows(S)
  S.rows, S.lowNames, S.highNames = rows2, L, H

  local nRolled = 0
  for i = 1, #pattern do
    if pattern:sub(i, i) ~= "X" then nRolled = nRolled + 1 end
  end
  S.nRolled = nRolled

  -- G1 PARTICIPATION, applied before anything is written: a referee host (I5)
  -- has no stake in its own game, a spectator could not map the pattern, and a
  -- client that is not in the roster never sat at this table. That is the WHOLE
  -- gate now - ROLLBRIEF 4 deleted the three verdicts that used to sit inside
  -- it, and a client commits from the host's RESULT like every other game.
  local played = (not S.spectator) and S.seated and me and S.joined[me] and true or false
  local committed = false
  if played and mapped and D > 0 then
    -- Every name is realm-qualified and came from the JOINED stream this client
    -- watched itself. vouch is built from the LIVE roster rather than a snapshot
    -- frozen at BEGIN: a spectator repaired by a resync replay has a corrected
    -- roster and would otherwise carry a stale vouch into Commit's G2 gate and
    -- be refused for names it can see in front of it.
    local vouch = {}
    for i = 1, #S.roster do vouch[S.roster[i]] = true end
    committed = PG.Ledger.Commit({
      id = "GB:" .. S.host .. ":" .. S.token,
      game = "GB",
      host = S.host,
      scope = S.scope,
      at = (type(time) == "function") and time() or nil,
      played = true,
      vouch = vouch,
      -- Every |delta| <= D <= wager - 1, so this is honest and it is the
      -- tightest bound available - far tighter than LG's buyin * roster.
      cap = S.wager,
      label = "The Gambler",
    }, rows2) and true or false
  end
  S.committed = committed

  -- The one line the player actually reads.
  local text
  if S.syncMissed or (S.spectator and not S.isHost) then
    text = "You missed part of this game, so no gold was recorded."
  elseif S.isHost and not S.seated then
    text = "You ran this one, so no gold was recorded for you."
  elseif nRolled == 0 then
    text = "Nobody rolled - no gold changes."
  elseif D <= 0 then
    if nRolled == 1 then
      text = "Only one player rolled - no contest, no gold changes."
    else
      text = "Everyone rolled " .. highRoll .. " - nobody pays anybody."
    end
  else
    local mineDelta = (me and rows2[me]) or 0
    if mineDelta < 0 then
      local to = (#H == 1) and shortOf(H[1]) or "the high rolls"
      text = "You pay " .. to .. " " .. PG.Money(-mineDelta) .. "."
    elseif mineDelta > 0 then
      text = "You collect " .. PG.Money(mineDelta) .. "."
    else
      text = "You broke even."
    end
  end

  S.ended = true
  ShowWindow()
  toast(text, S.host, { priority = "result" })
  -- INFORMATION, after the result and never instead of it (ROLLBRIEF 4).
  if mapped and not S.spectator then
    local note = ownRollNote(S)
    if note then toast(note, S.host, { key = "gb-mismatch" }) end
  end
  endSession(text)
  runFX(fxResult)
end

local function applyCancel(reason)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local text
  if reason == "few" then
    -- CONCURRENCY.md 6.3: no BUSY message exists and none will, so the honest
    -- version of "nobody joined" says why that can happen.
    text = "Cancelled - not enough players joined. Others may be busy or away."
  elseif reason == "host" then
    text = "Cancelled by the host - no gold changes."
  else
    text = "Cancelled (" .. tostring(reason) .. ") - no gold changes."
  end
  toast(text, S.host)
  endSession(text)
end

-------------------------------------------------------------------------------
-- Roll observation: OUR OWN ROLL, AND NOTHING ELSE.
--
-- Registered ONCE at init: a /roll in a raid is common enough that churning
-- registrations per session would cost more than the early return on the first
-- line.
--
-- PG.Rolls still hands us every /roll line this client can see. Exactly one of
-- them means anything now - the one with our own name on it - and that name
-- needs no resolving, because PG.FullName("player") cannot be wrong about who we
-- are. Everybody else's roll reaches the host as a ROLLED whisper or not at all.
-------------------------------------------------------------------------------

local function warnWrongCeiling(S, low, high)
  local now = GetTime()
  if now - (S.warnAt or 0) < WARN_THROTTLE then return end
  S.warnAt = now
  toast("that was /roll " .. low .. "-" .. high .. ". This game is /roll "
    .. (S.wager or "?") .. " - roll again.", S.host, { key = "gb-roll" })
end

-- Our own roll, to the host, over the wire (ROLLBRIEF 3). Whispered in EVERY
-- scope, like every other 1:1 message in this addon. Returns whether it was
-- accepted for sending; a false leaves S.rollSent false and the client ticker
-- tries again while the window is open, which is the whole reason a lost report
-- is no longer silent.
local function reportRoll(S, value)
  return PG.Comm.Whisper(S.host, "GB", "ROLLED", S.token,
    GB_ROUND, value, 1, S.wager) and true or false
end

-- One accepted roll from PG.Rolls, live or drained from its ring. roll is a
-- fresh copy: { name = "Name-Realm", value, low, high, at }. Everything is
-- re-validated here anyway - it is parsed text, and it decides gold.
local function onRollObserved(roll)
  local S = mySession()
  if not S or type(roll) ~= "table" then return end
  local name = PG.SafeStr(roll.name)
  local value = PG.SafeNum(roll.value)
  local low = PG.SafeNum(roll.low)
  local high = PG.SafeNum(roll.high)
  local at = PG.SafeNum(roll.at) or GetTime()
  if not name or name == "" or not value or not low or not high then return end
  if math.floor(value) ~= value then return end
  local me = myName()
  if not me or name ~= me then return end   -- ours, or it is not our business

  if S.phase == "join" then
    if low == 1 and high == (S.wager or 0) then
      toast("the roll window isn't open yet - wait for the timer.", S.host,
        { key = "gb-roll" })
    end
    return
  end
  if S.phase ~= "roll" or not S.rollOpen then return end
  -- A referee host (I5) has no seat in its own game, so its /roll is not a play.
  -- A SPECTATOR is deliberately not excluded: its roster is out of sync, which
  -- says nothing about whether its own roll happened, and the host - whose
  -- roster is the frozen truth - decides. Refusing to report here would recreate
  -- the exact failure this rework exists to remove.
  if not S.seated then return end
  -- A crisp cutoff on the roll's OWN observation time, not on "now": a roll
  -- drained out of the ring after a late re-open is judged by when it happened.
  -- This is the ONLY place our deadline is enforced against our own roll. The
  -- host accepts whatever reaches it while its window is open, which is the
  -- generous direction and costs nobody anything: the reporter already proved
  -- it rolled in time on its own clock.
  if at >= (S.deadline or 0) then return end
  if low ~= 1 or high ~= S.wager then
    -- WRONG CEILING, rejected decisively. A /roll 100 in a 1000 game is not a
    -- slot in this lottery: it is near-certainly the lowest roll, so accepting
    -- it with a warning would cost a typo up to 999 gold, irreversibly. It does
    -- NOT consume the player's one-roll slot, so they can roll correctly at
    -- once, and nothing goes on the wire.
    warnWrongCeiling(S, low, high)
    return
  end
  if S.rolls[me] then return end   -- FIRST valid roll locks (BRIEF 3.5)
  S.rolls[me] = value
  S.rollN = S.rollN + 1
  if S.isHost then
    -- The loopback rule: the host applies its own roll locally at observe time
    -- and never whispers itself.
    S.rollSent = true
    RefreshUI()
    runFX(fxMyRoll, value)
    maybeEarlyFinish()
    return
  end
  S.rollSent = reportRoll(S, value)
  RefreshUI()
  runFX(fxMyRoll, value)
end

drainRolls = function(S)
  if not (PG.Rolls and PG.Rolls.Since) then return end
  local list = PG.Rolls.Since(S.rollOpenedAt or 0)
  for i = 1, #list do onRollObserved(list[i]) end
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

-- Resync history: the ordered JOINED/LEFT stream plus BEGIN's exact fields, so a
-- client with a genuine gap is healed by replaying precisely what it missed.
local function hostRecordOp(op, name)
  local S = mySession()
  if not S then return end
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

local function hostStartRoll()
  local S = mySession()
  if not S or S.phase ~= "roll" then return end
  if broadcast("ROLL", S.rollSecs) then
    applyRoll(S.rollSecs)
  else
    S.nextRollAt = GetTime() + 2 -- send refused; the ticker retries
  end
end

local function hostReopenRoll()
  local S = mySession()
  if not S then return end
  -- A re-open must never resurrect a window that has already resolved: RESULT is
  -- terminal, and re-opening after it would leave nextRollAt and the deadline
  -- both meaningless while the host kept heart-beating, so no client would ever
  -- time out either. Clearing the flag on the way out is the other half of the
  -- same fix - a frozen flag that nothing clears is a permanent hang.
  if S.phase ~= "roll" or S.resultSent or not S.rollOpen then
    S.frozen = false
    return
  end
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.rollRemaining or 0))
  if broadcast("ROLL", secs) then
    -- applyRoll clears frozen, re-bases the deadline, restarts the bar and
    -- drains any roll that landed while we were re-opening.
    applyRoll(secs)
    -- The last roll may have landed during the freeze window's tail, in which
    -- case nobody is left to wait for and the re-opened timer would just burn.
    maybeEarlyFinish()
  end
end

local function hostCancel(reason)
  local S = mySession()
  if not S then return end
  -- RESULT is already on the wire: clients will commit when it lands, so the
  -- host must complete too. No abort may interleave after RESULT is queued.
  if S.resultSent then return end
  broadcast("CANCEL", reason)
  applyCancel(reason)
end

-- The one place the outcome is computed. Everything else in this file only
-- reads it.
local function buildOutcome(S)
  local lowRoll, highRoll
  for i = 1, #S.roster do
    local v = S.rolls[S.roster[i]]
    if v then
      if not lowRoll or v < lowRoll then lowRoll = v end
      if not highRoll or v > highRoll then highRoll = v end
    end
  end
  if not lowRoll then lowRoll, highRoll = 0, 0 end
  local chars = {}
  for i = 1, #S.roster do
    local v = S.rolls[S.roster[i]]
    if not v then
      -- A NON-ROLL IS NOT A ROLL OF ZERO. Treating a no-show as 0 would make
      -- every disconnect, loading screen and death an automatic maximum loss for
      -- something the player never did.
      chars[i] = "X"
    elseif highRoll == lowRoll then
      chars[i] = "-"
    elseif v == lowRoll then
      chars[i] = "L"
    elseif v == highRoll then
      chars[i] = "H"
    else
      chars[i] = "-"
    end
  end
  return table.concat(chars), lowRoll, highRoll
end

local function hostResolve()
  local S = mySession()
  if not S or S.phase ~= "roll" or S.resultSent then return end
  if #S.roster < 2 then
    -- Unreachable: the roster is frozen at BEGIN and BEGIN needs two. Left in
    -- because an empty pattern would be dropped by every client's validator and
    -- the session would hang instead of ending.
    hostCancel("few")
    return
  end
  local pattern, lowRoll, highRoll = buildOutcome(S)
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      -- LG's hostEnd shape: the ledger is written only once RESULT has actually
      -- LEFT THE WIRE. A queued-then-lockdown-dropped RESULT aborts through
      -- onDrop instead, with no ledger anywhere. The callback can fire a second
      -- later, so re-resolve and refuse unless this exact record is still ours.
      local cur = mySession()
      if cur ~= sess or sessions[sess.key] ~= sess or cur.phase ~= "roll" then return end
      applyResult(pattern, lowRoll, highRoll)
    end,
  }, "GB", "RESULT", S.token, pattern, lowRoll, highRoll)
  if ok then S.resultSent = true end
end

local function hostCloseJoin()
  local S = mySession()
  if not S or S.phase ~= "join" then return end
  -- A referee host is absent from its own roster (I5), so this minimum means two
  -- OTHER players, which is exactly what a game needs.
  local count = #S.roster
  if count < 2 then
    if broadcast("CANCEL", "few") then
      applyCancel("few")
    else
      S.joinDeadline = GetTime() + 2 -- send refused; retry shortly
    end
    return
  end
  -- The duplicate-short-name CANCEL that stood here is gone (ROLLBRIEF 6): a
  -- table must not refuse to start over something this rare. What survives is a
  -- warning, because the ambiguity itself did NOT go away and the comment that
  -- stood here claiming it had was wrong.
  --
  -- The HOST no longer resolves anybody's name - reports arrive by whisper and
  -- the sender is vouched. But each CLIENT still has to pick its OWN roll out of
  -- a chat line that prints a bare short name, and PG.NormalizeSender appends
  -- the LOCAL realm to it. So with Alice-Stormrage and Alice-Illidan at the same
  -- table, both clients read the first "Alice" line as their own and report it:
  -- one roll gets counted twice and the other never arrives. Nobody is cheating
  -- and the game still settles - it just settles on the wrong numbers.
  --
  -- Death Roll is immune (only the seat whose turn is open ever reports, so two
  -- Alices are never both listening), which is why this warning lives here and
  -- not there. Telling the table is proportionate; refusing to play is not.
  local shortSeen, clash = {}, nil
  for i = 1, #S.roster do
    local full = S.roster[i]
    local short = full:match("^([^%-]+)") or full
    if shortSeen[short] then clash = short else shortSeen[short] = true end
  end
  if clash then
    toast("two players here are both called " .. clash
      .. " - their rolls may be counted wrong. Fine to play; check the result.",
      S.host, { priority = "result" })
  end
  local dig = rosterDigest(S.roster)
  if broadcast("BEGIN", count, S.wager, dig) then
    S.hist.beginCount, S.hist.beginWager, S.hist.beginDigest = count, S.wager, dig
    applyBegin(count, S.wager, dig)
    S.nextRollAt = GetTime() + BEGIN_PAUSE_SECS
  else
    S.joinDeadline = GetTime() + 2
  end
end

local function hostHandleJoin(sender)
  local S = mySession()
  if not S or S.phase ~= "join" or S.joined[sender] then return end -- idempotent
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

-- A client reported ITS OWN roll (ROLLBRIEF 3). This is the whole inbound roll
-- path now: the host never reads anybody else's system line, so nothing here
-- matches a printed name against the roster and the bug that dropped one
-- player's rolls for an entire game has no surface left.
--
-- `sender` is vouched by the delivery - Comm resolved it from the addon message
-- itself - so membership is a table lookup rather than a guess.
--
-- Validation runs in the order ROLLBRIEF 3 fixes and ANY failure drops the whole
-- message in silence. Death Roll implements the identical sequence; if you
-- change one, change both.
local function hostHandleRolled(sender, f1, f2, f3, f4)
  local S = mySession()
  if not S or not S.isHost then return end
  -- Wire fields first: this is parsed text that decides gold, so nothing is read
  -- before it is a bounded integer.
  local seq = num(f1, 1, 999)
  local value = num(f2, 1, MAX_WAGER)
  local low = num(f3, 1, MAX_WAGER)
  local high = num(f4, MIN_WAGER, MAX_WAGER)
  if not (seq and value and low and high) then return end
  -- The round this host currently expects. One round per session, so GB's seq is
  -- always GB_ROUND; the field is here because both roll games carry the same
  -- wire shape.
  if seq ~= GB_ROUND then return end
  -- 1. the sender is in the FROZEN roster
  if not S.joined[sender] then return end
  -- 2. low is 1 and high is the ceiling THIS host is running. A report on any
  --    other ceiling is the same typo onRollObserved refuses locally, and it
  --    does not consume the sender's one-roll slot either.
  if low ~= 1 or high ~= (S.wager or 0) then return end
  if value > high then return end
  -- 3. (Death Roll only: the sender is the seat whose turn is open.)
  -- 4. first report wins, exactly as the first observed roll used to
  if S.rolls[sender] then return end
  -- 5. the window is open. NOT gated on S.frozen: a roll observed a moment
  --    before a freeze is honest and its whisper can easily land inside one.
  --    resultSent is the real close - past it the pattern is already fixed.
  if S.phase ~= "roll" or not S.rollOpen or S.resultSent then return end
  S.rolls[sender] = value
  S.rollN = S.rollN + 1
  RefreshUI()
  maybeEarlyFinish()
end

-- Everyone on the roster has rolled: nobody is waiting on anybody, so the window
-- closes now instead of burning the rest of the timer (which is also the whole
-- mitigation for "this game induces a lot of public /roll spam"). Never while
-- frozen, and never while the gate that feeds us observations is shut.
maybeEarlyFinish = function()
  local S = mySession()
  if not S or not S.isHost then return end
  if S.phase ~= "roll" or not S.rollOpen or S.frozen or S.resultSent then return end
  if #S.roster < 2 then return end
  for i = 1, #S.roster do
    if not S.rolls[S.roster[i]] then return end
  end
  if not rollGateOpen() then return end
  hostResolve()
end

-- one replay entry; the explicit arity keeps trailing nils out of the wire
local function pushMsg(out, ...)
  local m = { ... }
  m.n = select("#", ...)
  out[#out + 1] = m
end

-- Resync: a client whispered SYNCQ (its phase, roster count and roster digest).
-- Replay whatever it missed BY WHISPER using the ORIGINAL message types and
-- field layouts.
--
-- There is deliberately NO replay of a terminal RESULT here. The shared comm
-- prologue drops every message for a record whose phase is "done" (gate k)
-- BEFORE the host dispatch, so a done host cannot answer a SYNCQ at all and any
-- such branch would be dead code. A client that missed RESULT therefore falls
-- back to its heartbeat watchdog and ends with NO ledger, which is the safe
-- direction: nothing is recorded rather than something being recorded wrongly.
local function hostHandleSyncQ(sender, phase, rosterN, dig)
  local S = mySession()
  if not S then return end
  if phase ~= "join" and phase ~= "roll" then return end
  if not rosterN then return end
  if dig ~= nil and not isDigest(dig) then return end -- malformed field: reject
  if PG.Comm.Locked() then return end -- the client retries after its cooldown
  local now = GetTime()
  local last = S.syncAsk[sender]
  if last and (now - last) < SYNC_COOLDOWN then return end -- per-sender rate limit
  S.syncAsk[sender] = now
  local out = {}
  if rosterN ~= #S.roster or (dig and dig ~= rosterDigest(S.roster)) then
    -- The full ordered stream converges any subset roster onto ours exactly
    -- (each name ends in the state of its last op). A same-size, wrong-members
    -- roster is caught by the digest alone.
    for i = 1, #S.hist.ops do
      local op = S.hist.ops[i]
      pushMsg(out, (op.op == "J") and "JOINED" or "LEFT", op.name)
    end
  end
  if S.phase == "roll" then
    if phase == "join" then
      -- the roster cannot change after BEGIN, so the live digest IS the BEGIN one
      pushMsg(out, "BEGIN", S.hist.beginCount or S.count or #S.roster,
              S.hist.beginWager or S.wager,
              S.hist.beginDigest or rosterDigest(S.roster))
    end
    -- Unlike RPS this is NOT gated on the replay list being non-empty. GB has
    -- exactly one window and no per-round message to reveal a gap, so a client
    -- that lost only the ROLL broadcast is in the right phase with the right
    -- roster and would be told "you missed nothing" while its window never
    -- opens and its player never rolls.
    if S.rollOpen and not S.frozen then
      local remain = math.max(1, math.ceil((S.deadline or now) - now))
      pushMsg(out, "ROLL", remain)
    end
  end
  if #out > SYNC_MAX_REPLAY then
    PG.Comm.Whisper(sender, "GB", "SYNCNO", S.token)
    return
  end
  if #out == 0 then
    PG.Comm.Whisper(sender, "GB", "SYNCOK", S.token)
    return
  end
  -- replay whispers reuse CRITICAL_DROP mtypes: shield onDrop while the send
  -- queue drains, so a lockdown-dropped replay never aborts the live game
  S.syncReplayUntil = now + 30
  for i = 1, #out do
    local m = out[i]
    PG.Comm.Whisper(sender, "GB", m[1], S.token, unpack(m, 2, m.n))
  end
end

-- Why Start may be blocked, and whether it is blocked at all (CONCURRENCY.md
-- 6.4). Hosting is never blocked by another module or by anyone else's session
-- (I4); the only refusal is I3 - this module already holds a full record.
local function involvement()
  local S = mySession()
  if S and S.phase ~= "done" then
    if S.isHost then
      return "You're already running a Gambler game. Cancel it first, or wait for it to finish.", false
    end
    return "You're playing " .. shortOf(S.host)
      .. "'s Gambler game. You can start your own when it's over.", false
  end
  local seat = PG.Session.Seat()
  if seat and seat.module ~= "GB" then
    -- Referee hosting (I5): you play one round-based game and run the other.
    return "You're playing " .. (MODULE_NAME[seat.module] or seat.module)
      .. ", so you'll run this game without playing in it.", true
  end
  return nil, true
end

hostOpen = function(wager, joinSecs, rollSecs, scope)
  local note, canStart = involvement()
  if not canStart then
    toast(note)
    return
  end
  -- A client that cannot read its own /roll line cannot PLAY: there is nothing
  -- for it to report, so it would sit at its own table marked as never having
  -- rolled. The refusal is unchanged and still host-only, but its reason has
  -- flipped with the rest of this file - it is no longer about scoring anybody
  -- else, since the host scores from ROLLED reports it can always read.
  if not rollsReady() then
    toast("this client can't read /roll results, so it can't play a game.")
    return
  end
  local host = myName()
  if not host then return end
  scope = PG.SafeStr(scope) or "group"
  if not PG.GB.SCOPES[scope] then return end
  -- availability is re-checked at the moment Start is pressed (SCOPE.md 1.3);
  -- never fall back to another audience
  local okScope, why = PG.Comm.ScopeAvailable(scope)
  if not okScope then
    toast(why or "that audience isn't available.")
    -- IsVisible, not IsShown: a page frame is "shown" whenever it is the
    -- selected page, including while the whole shell is hidden.
    if dlgScope and page and page:IsVisible() then pcall(dlgScope.Refresh, dlgScope) end
    return
  end
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  local token = nextToken()
  -- broadcast OPEN before touching any record: a submit-time lockdown drop
  -- invokes onDrop synchronously, and a token with no record is ignored there,
  -- so a refusal leaves everything exactly as it was and the retry is legitimate
  if not PG.Comm.Broadcast(scope, "GB", "OPEN", token, wager, joinSecs, rollSecs, code) then
    toast("cannot start right now (addon messages are blocked).")
    return
  end
  local prev = mySession()
  -- the previous record can only be a FINISHED one (a live one refused above),
  -- so its numbers stay up until ShowWindow repaints them for the new game
  if prev then evict(prev.key, true) end
  -- I5: hosting never fails on the seat. ClaimHost cannot refuse; it only
  -- reports whether we are a player in our own game or its referee.
  local seated = PG.Session.ClaimHost("GB", token, host)
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
    wager = wager,
    joinSecs = joinSecs,
    rollSecs = rollSecs,
    phase = "join",
    roster = {},
    joined = {},
    rolls = {},              -- built HERE, not in applyBegin (see applyBegin)
    rollN = 0,
    hist = { ops = {} },     -- resync replay history
    syncAsk = {},            -- per-sender SYNCQ rate limiting
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
  -- a lockdown drop of JOINED (critical) aborts synchronously via onDrop above
  if not live() then return end
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

-- The ROLL button. It NEVER locks anything: only an observation does. A refusal
-- is not necessarily permanent (the safety gate reopens), so nothing latches
-- here - RefreshUI asks PG.Rolls.Available() every paint, and the typed
-- "/roll N" instruction is visually primary in every state anyway.
local function doRoll()
  local S = mySession()
  if not S or not S.seated or S.spectator then return end
  if S.phase ~= "roll" or not S.rollOpen then return end
  local me = myName()
  if not me or not S.joined[me] or S.rolls[me] then return end
  if not (PG.Rolls and PG.Rolls.Request) then return end
  local ok, why = PG.Rolls.Request(1, S.wager)
  if ok then
    -- "Called without error", never "a roll happened". The number arrives (or
    -- does not) through the same CHAT_MSG_SYSTEM path as a typed one.
    S.rollAskedAt = GetTime()
    PG.After(ROLL_CONFIRM + 0.1, function() RefreshUI() end)
  else
    toast(why or ("this client can't roll for you - type /roll " .. S.wager .. " in chat."),
      S.host, { key = "gb-roll" })
  end
  RefreshUI()
end

-- The full-record constructor (I7), reachable from exactly two places: the
-- invitation's Accept callback and the launcher's Join button. An overheard OPEN
-- creates a lite record and nothing more - no session state without consent.
local function clientAccept(rec)
  if not rec or rec.kind ~= "lite" or sessions[rec.key] ~= rec then return false end
  local cur = mySession()
  if cur and cur.phase == "done" then
    -- a finished record is not an INVOLVED one: replace it, and keep its numbers
    -- up until the new game's window repaints them
    evict(cur.key, true)
    cur = nil
  end
  if cur then
    toast("you're already in " .. (cur.isHost and "your own game"
      or (shortOf(cur.host) .. "'s game")) .. " - finish it first.", rec.host)
    return false
  end
  -- 5.6 rule 3: the seat is claimed FIRST. A genuine race loses here and nothing
  -- is whispered.
  if not PG.Session.Claim("GB", rec.token, rec.host) then
    toast("you just joined another game - not joining this one.", rec.host)
    return false
  end
  local cfg = rec.cfg
  local openedAt = rec.openedAt
  PG.UI.Dismiss(rec.askKey)
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
    wager = cfg.wager,
    joinSecs = cfg.joinSecs,
    rollSecs = cfg.rollSecs,
    phase = "join",
    roster = {},
    joined = {},
    rolls = {},
    rollN = 0,
    syncAllClear = allClear(), -- tracks all-clear transitions for resync
    lastHB = GetTime(),
    joinDeadlineDisplay = openedAt + cfg.joinSecs,
    joinAccepted = true,       -- provisional; the host's JOINED confirms
  }
  register(S)
  mine = S.key
  PG.Comm.Whisper(S.host, "GB", "JOIN", S.token)
  ShowWindow()
  if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
  -- The record is built at ACCEPT time, so every JOINED that landed while the
  -- invitation sat on screen was missed; the resync protocol replays exactly
  -- that stream.
  clientRequestSync()
  RefreshUI()
  return true
end

-- The launcher's Open games list joins through the same path as the popup.
function PG.GB.JoinOpen(key)
  return clientAccept(sessions[tostring(key or "")])
end

-- Read-only view of what this module is overhearing, for the launcher list.
function PG.GB.OpenGames()
  local out = {}
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      out[#out + 1] = { key = rec.key, host = rec.host, token = rec.token,
                        scope = rec.scope, expires = rec.expires, game = "GB" }
    end
  end
  return out
end

local function clientHostDead()
  local S = mySession()
  if not S then return end
  toast("lost contact with the host - game abandoned.", S.host)
  endSession("Abandoned - the host stopped responding. No gold was recorded.")
end

-- Resync request. At most one per SYNC_COOLDOWN; a refused or cooling-down
-- request stays pending and the ticker retries it.
clientRequestSync = function()
  local S = mySession()
  if not S or S.isHost or S.phase == "done" or S.syncDead then return end
  local now = GetTime()
  if now - (S.lastSyncQ or 0) < SYNC_COOLDOWN or PG.Comm.Locked() then
    S.syncNeeded = true
    return
  end
  -- We report the phase we can PROVE we reached, not the one a message pushed us
  -- into. The forced-spectator branch in the comm prologue flips S.phase to
  -- "roll" on a ROLL or RESULT without ever having seen BEGIN, and a host told
  -- "roll" has no reason to replay BEGIN - so S.count stays nil,
  -- maybeClearSpectator returns on it forever, and a client that joined
  -- spectates the whole game with no ledger and no way back.
  local phase = (S.phase == "roll" and not S.count) and "join" or S.phase
  -- the digest rides along so the host can spot a same-size, wrong-membership
  -- roster, which a count comparison alone can never see
  if PG.Comm.Whisper(S.host, "GB", "SYNCQ", S.token, phase, #S.roster,
                     rosterDigest(S.roster)) then
    S.lastSyncQ = now
    S.syncNeeded = false
  else
    S.syncNeeded = true
  end
end

-- A resynced spectator rejoins once its mirror agrees with the host again. Its
-- own roll observations were never wire-dependent, so a healed spectator can
-- commit normally.
local function maybeClearSpectator()
  local S = mySession()
  if not S or S.isHost or not S.spectator or S.syncDead then return end
  if S.phase ~= "roll" or not S.count then return end
  if #S.roster ~= S.count then return end
  -- Size agreement is not membership agreement, and this is unconditional: the
  -- guard above proves BEGIN was absorbed, absorbing BEGIN requires a digest, so
  -- a nil S.digest here is impossible and treating one as "close enough" would
  -- heal a spectator onto a same-count wrong-member roster one hop later.
  if rosterDigest(S.roster) ~= S.digest then return end
  local me = myName()
  if not (me and S.joined[me]) then
    -- The same test applyBegin makes, one hop later: converged on the host's
    -- roster and not in it.
    toast("your join did not reach the host - you are not in this game.", S.host,
      { key = "gb-status" })
    endSession("You are not in this game.")
    evict(S.key)
    return
  end
  S.spectator = false
  toast("back in sync - you are back in the game.", S.host, { key = "gb-status" })
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

local function askMax()
  return PG.UI.ASK_MAX or 3
end

-- Busy means the SEAT is held, and nothing else (6.1). A busy client is never
-- deaf: it still records the session and still lists it.
local function busyToast(host)
  local now = GetTime()
  if (now - busyToastAt) < BUSY_THROTTLE then
    busyPending = busyPending + 1
    return
  end
  if (now - busyToastAt) > (BUSY_THROTTLE * 2) then busyPending = 0 end
  busyToastAt = now
  if busyPending > 0 then
    local n = busyPending + 1
    busyPending = 0
    toast(n .. " more games are open - see the Pengyou Games window.", host)
  else
    toast(shortOf(host) .. " started a game - you're in another game right now."
      .. " It's in the Pengyou Games window.", host, { key = "gb-busy" })
  end
end

local function overflowToast()
  local now = GetTime()
  if (now - overflowToastAt) < BUSY_THROTTLE then return end
  overflowToastAt = now
  toast("another game is open - see the Pengyou Games window.", nil, { key = "gb-busy" })
end

-- Toast / popup policy for an inbound OPEN (4.4), identical to LG and RPS.
-- These branches used to be documented as inert because the game was group
-- only; they are live now. PUBLIC never pops - a stranger on the realm channel
-- must not be able to put a popup on your screen, and the launcher's list is
-- the whole surface. GUILD spends the shared popup budget (SCOPE.md 6.3), which
-- is counted in Widgets rather than per module so it cannot be spent twice.
local function raiseInvite(rec)
  listOpen(rec)     -- every lite record gets a launcher row
  if PG.Session.IsSeated() then
    if rec.scope == "group" then busyToast(rec.host) end
    return
  end
  if rec.scope == "public" then return end
  if rec.scope == "guild" and PG.UI.GuildAskOK and not PG.UI.GuildAskOK(rec.host) then return end
  if PG.UI.AskCount() >= askMax() then
    if rec.scope == "group" then overflowToast() end
    return
  end
  local askKey = "GB:" .. rec.key
  local acceptLabel = "Roll"
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then acceptLabel = m .. " Roll" end
  end
  local ok, why = PG.UI.Ask(askKey,
    shortOf(rec.host) .. " started The Gambler - /roll " .. rec.cfg.wager
      .. ", lowest pays highest. Play?",
    acceptLabel, "Pass", math.max(1, rec.expires - GetTime()),
    function() clientAccept(rec) end,
    function() if sessions[rec.key] == rec then rec.askKey = nil end end,
    "GB")
  if ok then
    rec.askKey = askKey
    if rec.scope == "guild" and PG.UI.GuildAskSpend then PG.UI.GuildAskSpend(rec.host) end
  elseif why == "full" and rec.scope == "group" then
    overflowToast()
  end
  -- why == "dnd": PG.UI.Ask already declined, so a DND player never seats. The
  -- lite record stays in the launcher list either way (5.6 rule 7).
end

-- 4.3: the newest OPEN from a given host replaces that host's previous session
-- on every client, unconditionally. The host is the sole authority for its own
-- sessions, so no comparison and no election is needed.
local function supersede(host, newToken)
  for k, rec in pairs(sessions) do
    if rec.host == host and rec.token ~= newToken then
      local keepWindow = (rec.kind == "full" and rec.phase == "done")
      if rec.kind == "full" and rec.phase ~= "done" then
        -- I6's only exception. We are never auto-seated into the new game.
        toast(shortOf(host) .. " started a new game - your previous game is over.",
          host, { priority = "result" })
        endSession("The host started a new game. No gold was recorded.")
      end
      -- and DECLARE the kept window: this path used to leave a fully drawn,
      -- live-looking frame behind a record that no longer existed (5.9)
      if keepWindow then freezeWindow(rec) end
      evict(k, keepWindow)
    end
  end
end

-- Cap enforcement (4.2 row 6): drop the oldest lite record with no popup ON
-- SCREEN. Liveness is PG.UI.IsAsking, not the cached askKey.
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

-- The inbound OPEN decision table (4.2), evaluated in order.
local function onOpen(token, sender, scope, f1, f2, f3, f4)
  if sender == myName() then return end                     -- row 1, belt and braces
  -- row 2 (SCOPE.md 3.1): the declared scope exists to be CHECKED against the
  -- delivered distribution, never trusted. A wire field can claim anything; a
  -- distribution cannot.
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f4))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end                     -- an OPEN never arrives by whisper
  if not PG.GB.SCOPES[scope] then return end
  local wager = num(f1, MIN_WAGER, MAX_WAGER)
  local joinSecs = num(f2, 5, 600)
  local rollSecs = num(f3, 5, 600)
  if not (wager and joinSecs and rollSecs) then return end
  local key = keyOf(sender, token)
  if isRecent(key) then return end                          -- row 3: dead token
  local now = GetTime()
  local existing = sessions[key]
  if existing then                                          -- row 4: idempotent
    if existing.kind == "lite" then
      existing.expires = now
        + math.max(LITE_TTL_MIN, math.min(LITE_TTL_MAX, joinSecs)) + LITE_TTL_PAD
    end
    return
  end
  supersede(sender, token)                                  -- row 5
  if liteCount >= MAX_LITE and not makeLiteRoom() then return end  -- row 6
  local rec = {                                             -- row 7
    kind = "lite",
    key = key,
    token = token,
    host = sender,
    scope = scope,
    cfg = { wager = wager, joinSecs = joinSecs, rollSecs = rollSecs },
    openedAt = now,
    expires = now
      + math.max(LITE_TTL_MIN, math.min(LITE_TTL_MAX, joinSecs)) + LITE_TTL_PAD,
  }
  register(rec)
  raiseInvite(rec)
end

-- Gate h (5.2). A lite record holds no roster, no rolls, no history and no
-- frame, and it never reaches an applier. BEGIN, CANCEL or RESULT kills it: a
-- game we did not join has started or finished, so we have no reason to know it
-- exists any more.
local function liteObserve(rec, mtype)
  if mtype == "HB" then
    rec.expires = math.max(rec.expires, GetTime() + LITE_TTL_PAD)
  elseif mtype == "BEGIN" or mtype == "CANCEL" or mtype == "RESULT" then
    evict(rec.key)
  end
end

-- Message classes (gate f). Splitting by class rather than falling back between
-- lookups removes the last ambiguity: a peer hosting a session whose token
-- happens to equal ours can never have its whisper resolve against our record.
local HOST_AUTHORED = {
  HB = true, JOINED = true, LEFT = true, BEGIN = true, ROLL = true,
  RESULT = true, CANCEL = true, SYNCOK = true, SYNCNO = true,
}
local CLIENT_AUTHORED = { JOIN = true, UNJOIN = true, SYNCQ = true, ROLLED = true }

-- The only host-authored mtypes that legitimately arrive by WHISPER: exactly
-- what hostHandleSyncQ sends (JOINED / LEFT / BEGIN / ROLL in the replay loop)
-- plus its two answers. RESULT, CANCEL and HB are BROADCAST BY CONSTRUCTION and
-- are never replayed - a done session serves nothing, and CANCEL/HB carry no
-- replayable state - so a whispered one is a private view of a game everybody
-- else is being told about differently. KEPT (ROLLBRIEF 4): it costs nothing at
-- the table and it stops the silliest per-victim tricks.
--
-- The SYNCQ-credit provenance window that used to sit behind this allowlist is
-- GONE. Gate g already proves a host-authored message came from THE HOST of this
-- exact session, so everything the window rationed was the host talking to us,
-- and the host is trusted here now. It was fifteen lines and two record fields
-- to ration a channel we have decided to believe.
local WHISPERABLE = {
  JOINED = true, LEFT = true, BEGIN = true, ROLL = true,
  SYNCOK = true, SYNCNO = true,
}

-- BRIEF 4.3: declare enough parameters for the LARGEST message plus a spare.
-- Comm dispatches unpack(parts, 5), so the fields are there - a handler that
-- declares too few silently reads nil and drops every OPEN.
local function onComm(mtype, token, sender, scope, f1, f2, f3, f4, f5)
  token = validToken(token)                                  -- 3.4
  if not token then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3, f4) end

  local rec
  if HOST_AUTHORED[mtype] then
    -- gate g: identity is the PAIR. Sender authority (gate j) is free here -
    -- sender IS rec.host, because it is half the key.
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
  -- gate i: "private" is exempt because resync replays legitimately arrive by
  -- whisper - but ONLY the replay mtypes (see WHISPERABLE). The non-private line
  -- is what stops a live session's token being re-broadcast into a different
  -- distribution. Client-authored whispers (JOIN/UNJOIN/SYNCQ/ROLLED, inbound to
  -- the host) are untouched: they are the client's own traffic, and ROLLED is
  -- whispered BY DESIGN in every scope.
  if scope == "private" then
    if HOST_AUTHORED[mtype] and not WHISPERABLE[mtype] then return end
  elseif scope ~= rec.scope then return end

  local S = rec
  if S.isHost then
    if mtype == "JOIN" then
      hostHandleJoin(sender)
    elseif mtype == "UNJOIN" then
      hostHandleUnjoin(sender)
    elseif mtype == "ROLLED" then
      hostHandleRolled(sender, f1, f2, f3, f4)
    elseif mtype == "SYNCQ" then
      hostHandleSyncQ(sender, PG.SafeStr(f1), num(f2, 0, ROSTER_CAP), PG.SafeStr(f3))
    end
    return
  end
  -- sender == S.host is guaranteed by gate g's key; nothing else reaches here
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  -- ... and it clears the wide-scope "they may be in a boss fight" state the
  -- moment the host speaks again (SCOPE.md 6.2).
  if S.hostQuiet then S.hostQuiet = false end
  if S.phase == "join" and (mtype == "ROLL" or mtype == "RESULT") then
    -- we missed BEGIN entirely: spectate for now and ask the host to replay it.
    -- S.rolls already exists (built with the record), so the window that opens
    -- underneath us can record normally the moment resync clears the flag.
    S.phase = "roll"
    S.spectator = true
    toast("out of sync with the host - resyncing...", S.host, { key = "gb-status" })
    clientRequestSync()
  end
  if mtype == "HB" then
    -- nothing but the heartbeat stamp above
  elseif mtype == "JOINED" then
    local name = validName(f1)
    if name then applyJoined(name) end
  elseif mtype == "LEFT" then
    local name = validName(f1)
    if name then applyLeft(name) end
  elseif mtype == "BEGIN" then
    local count = num(f1, 2, ROSTER_CAP)
    local wager = num(f2, MIN_WAGER, MAX_WAGER)
    local dig = PG.SafeStr(f3)
    -- The digest is MANDATORY here, unlike LG's optional trailing field: GB did
    -- not exist in 1.0.0, so there are no pre-digest peers to tolerate and no
    -- honest GB host can omit it. Accepting it as absent left agreement resting
    -- on the COUNT alone, which is exactly the same-size wrong-members mirror
    -- rosterDigest exists to catch - and RESULT is positional over that roster.
    if count and wager and isDigest(dig) then
      applyBegin(count, wager, dig)
    end
  elseif mtype == "ROLL" then
    local secs = num(f1, 1, 600)
    if secs then applyRoll(secs) end
  elseif mtype == "RESULT" then
    local pattern = PG.SafeStr(f1)
    local cap = S.wager or MAX_WAGER
    local lowRoll = num(f2, 0, cap)
    local highRoll = num(f3, 0, cap)
    if pattern and validPattern(pattern) and lowRoll and highRoll then
      -- STRUCTURAL CHECK. A RESULT that fails any of these is dropped whole and
      -- the heartbeat watchdog ends the session with no ledger - the same
      -- "malformed fields drop" doctrine LG uses, whose failure mode is "no gold
      -- recorded", never "wrong gold recorded".
      local nRoll = 0
      local nL, nH = 0, 0
      for i = 1, #pattern do
        local c = pattern:sub(i, i)
        if c ~= "X" then nRoll = nRoll + 1 end
        if c == "L" then nL = nL + 1 elseif c == "H" then nH = nH + 1 end
      end
      local okStruct
      if nRoll == 0 then
        okStruct = (lowRoll == 0 and highRoll == 0)
      else
        okStruct = (lowRoll >= 1 and lowRoll <= highRoll)
      end
      if okStruct then
        if highRoll == lowRoll then
          okStruct = (nL == 0 and nH == 0)
        else
          okStruct = (nL >= 1 and nH >= 1)
        end
      end
      if okStruct then applyResult(pattern, lowRoll, highRoll) end
    end
  elseif mtype == "CANCEL" then
    applyCancel(PG.SafeStr(f1) or "?")
  elseif mtype == "SYNCOK" then
    S.syncNeeded = false -- host confirms we missed nothing
  elseif mtype == "SYNCNO" then
    if not S.syncDead then
      S.syncDead = true
      S.syncNeeded = false
      if not S.spectator then
        S.spectator = true
        toast("too far out of sync to catch up - spectating this game.", S.host,
          { key = "gb-status" })
      end
      RefreshUI()
    end
  end
  maybeClearSpectator()
end

-- An OUTGOING message of ours was permanently dropped by the comms lockdown.
-- For the host, losing a state-bearing broadcast desyncs every client, so the
-- session dies locally; clients notice via the heartbeat timeout. NOTHING is
-- owed on abort - the all-or-nothing ledger contract gains no exception here.
local CRITICAL_DROP = {
  OPEN = true, JOINED = true, LEFT = true, BEGIN = true, ROLL = true, RESULT = true,
}

-- Resync replay whispers reuse the original mtypes, so onDrop cannot tell a
-- dropped replay from a dropped live broadcast. While a replay may still be
-- draining, a drop of one of these must not abort the game. RESULT is absent by
-- construction: a replay never contains one (a done session serves nothing).
local REPLAYABLE = { JOINED = true, LEFT = true, BEGIN = true, ROLL = true }

local function onDrop(mtype, token)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local t = validToken(token)
  if not t or t ~= S.token then return end
  if mtype == "ROLLED" then
    -- Our own roll report never left this client. It is not an abort - the game
    -- is fine and everyone else's rolls are landing - so clear the sent flag and
    -- let the client ticker re-send it while the window is open. A lost report
    -- being SILENT is the entire bug this rework exists to fix; it does not get
    -- to come back as a dropped whisper.
    S.rollSent = false
    return
  end
  local me = myName()
  if not (me and S.isHost) or keyOf(me, t) ~= S.key then return end
  if not CRITICAL_DROP[mtype] then return end
  if REPLAYABLE[mtype] and S.syncReplayUntil and GetTime() < S.syncReplayUntil then return end
  toast("game aborted - addon messages were blocked mid-send.", S.host)
  endSession("Aborted - addon messages were blocked. No gold was recorded.")
end

-------------------------------------------------------------------------------
-- Safety transitions.
--
-- There is NO VOID in this game and no re-roll: an interruption freezes the
-- window, it never discards a roll that was already observed. What it DOES cost
-- is the observations made while the gate is shut - PG.Rolls discards those
-- outright (BRIEF 3.4, SPEC 2.12), so the clock has to stop or the window would
-- burn down on rolls nobody can see.
--
-- S.gapAt and noteGap were deleted with the cross-check (ROLLBRIEF 4). They
-- recorded when our own observation stream first had a hole, so that the removed
-- crossCheckOK could decline to accuse the host over a roll we might have missed
-- around the edge of a freeze. We no longer watch anybody else's rolls, so there
-- is no such hole to reason about: the only roll we can miss is our own, and we
-- can see for ourselves whether we made it.
--
-- CAREFUL: S.rollOpen stays TRUE through a freeze. Only the clock stops. Do not
-- "fix" that by clearing it - the re-open path and the drain both depend on the
-- window still being the same window.
-------------------------------------------------------------------------------

local function hostFreeze(S)
  if S.frozen then return end
  S.frozen = true
  S.rollRemaining = math.max(0, (S.deadline or GetTime()) - GetTime())
end

local function onSafetyChange(state, trigger)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local isOn = trigger:match("_ON$") ~= nil
  -- plain combat neither blocks sends nor pauses the game
  if trigger == "COMBAT_ON" or trigger == "COMBAT_OFF" then return end
  if not S.isHost then
    -- resync trigger: the session just emerged from a safety interruption
    local cur = allClear()
    if cur and S.syncAllClear == false then S.syncNeeded = true end
    S.syncAllClear = cur
    return
  end
  if not isOn then return end
  if S.phase == "join" then
    if not S.joinFrozen then
      S.joinFrozen = true
      S.joinRemaining = math.max(0, (S.joinDeadline or GetTime()) - GetTime())
    end
  elseif S.phase == "roll" and S.rollOpen then
    hostFreeze(S)
  end
end

-------------------------------------------------------------------------------
-- Master ticker: host timing (join window, roll deadline, re-open, heartbeat)
-- and the client-side host-death watchdog.
-------------------------------------------------------------------------------

local function sweepRegistry()
  local now = GetTime()
  for key, rec in pairs(sessions) do
    if rec.kind == "lite" then
      if now >= rec.expires then evict(key) end
    elseif rec.phase == "done" and rec.doneAt and (now - rec.doneAt) > DONE_TTL then
      -- 7.3: the RECORD goes at DONE_TTL, on schedule, exactly as before - an
      -- IsShown() exemption here is the bug this suite already paid to remove.
      -- The WINDOW is what stops going with it (PLAN 5): it freezes into a
      -- detached, marked, inert result and waits for the player's X.
      freezeWindow(rec)
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
    -- Scope-aware host abort (SCOPE.md 6.1). At group scope this is "you left
    -- the party"; the 8s grace argument is carried for uniformity with LG/RPS
    -- and is inert here (only the public channel can flicker).
    local okScope, why = PG.Comm.ScopeAvailable(S.scope, 8)
    if not okScope then
      why = why or "That audience is gone."
      toast(why .. " Game abandoned.", S.host)
      endSession("Abandoned - " .. why .. " No gold was recorded.")
      return
    end
    if now - (S.lastHBSent or 0) >= HB_INTERVAL and not PG.Comm.Locked() then
      if broadcast("HB", S.phase) then S.lastHBSent = now end
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
    elseif S.phase == "roll" then
      local gate = rollGateOpen()
      -- The comms lockdown (M+, PvP, an encounter that raised no ENCOUNTER_START
      -- we saw) has no Safety transition of its own, so the freeze is polled
      -- here as well as driven from onSafetyChange. Without this the window
      -- keeps counting down while PG.Rolls is discarding every roll, and the
      -- host would resolve a game nobody was allowed to play.
      -- resultSent excluded: that window is over, it simply has not been applied
      -- yet (BroadcastEx's onSent lands when the message really goes out), and
      -- freezing a resolved window only makes hostReopenRoll clear the flag again
      -- on the next tick.
      if S.rollOpen and not gate and not S.frozen and not S.resultSent then
        hostFreeze(S)
        RefreshUI()
      end
      if S.frozen then
        if gate then hostReopenRoll() end
      elseif S.nextRollAt then
        if now >= S.nextRollAt and gate then
          S.nextRollAt = nil
          hostStartRoll()
        end
      elseif S.rollOpen and now >= (S.deadline or 0) and not PG.Comm.Locked() then
        hostResolve()
      end
    end
  else
    -- BEGIN LANDED AND THE ROLL DID NOT. Nothing else in this file notices that:
    -- the client is in the right phase with the right roster, the host's
    -- heartbeat is healthy, so the watchdog is quiet and there is no per-round
    -- message to reveal the gap - the window simply never opens and the player
    -- cannot roll at all. The host used to score that player's /roll off its own
    -- screen, which hid the whole problem; it cannot any more, so the gap has to
    -- be asked about. hostHandleSyncQ replays ROLL(remain) for exactly this,
    -- and clientRequestSync is rate-limited inside.
    if S.phase == "roll" and not S.rollOpen and not S.spectator
      and S.beganAt and (now - S.beganAt) > ROLL_WAIT_PROBE then
      clientRequestSync()
    end
    -- Our own roll report has not left this client yet - a comms lockdown, an
    -- empty send bucket, or a queued whisper the lockdown then swallowed
    -- (onDrop clears the flag). Keep offering it for as long as the window is
    -- open. reportRoll answers false immediately when the wire refuses, so a
    -- long lockdown costs one function call per tick and nothing else.
    if S.phase == "roll" and S.rollOpen and not S.rollSent then
      local me = myName()
      local v = me and S.rolls[me]
      if v then S.rollSent = reportRoll(S, v) end
    end
    local st = PG.Safety.state
    if st.inEncounter or st.restricted or PG.Comm.Locked() then
      -- the host cannot legally heartbeat here: suspend the watchdog instead of
      -- declaring it dead.
      S.lastHB = (S.lastHB or now) + TICK
    elseif S.scope == "group" then
      local quiet = now - (S.lastHB or now)
      if quiet > HB_TIMEOUT then
        clientHostDead()
        return
      end
      if quiet > HB_PROBE then
        -- A quiet host that is merely between messages answers the probe and the
        -- mirror heals; one that has died stays silent and the timeout above
        -- ends the session with no ledger. Rate-limited inside.
        clientRequestSync()
      end
    else
      -- SCOPE.md 6.2. Our own safety state says nothing about the host's when
      -- we are not in the same content, so quiet is PAUSED first and dead only
      -- much later. Nothing changes state on the way through: a game that is
      -- merely waiting must not be able to end itself.
      local quiet = now - (S.lastHB or now)
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
          clientRequestSync()
        end
      end
    end
    if S.syncNeeded and allClear() then clientRequestSync() end
  end
  if win and win:IsShown() then RefreshUI() end
end

-------------------------------------------------------------------------------
-- FX (faire carnival garnish). Pure decoration behind runFX: the text state is
-- always final BEFORE any of this plays, and nothing here ever re-shows a
-- Safety-hidden frame.
-------------------------------------------------------------------------------

fxJoined = function(name)
  if not (win and win:IsShown()) then return end
  if name == myName() then Theme.Sound("click") end
end

fxBegin = function()
  local S = mySession()
  if not (win and win:IsShown() and S) then return end
  Theme.Banner(win, "ROLL 1 - " .. (S.wager or "?"), "GB")
  Theme.Sound("stamp")
end

fxRoll = function()
  if not (win and win:IsShown()) then return end
  Theme.Banner(win, "ROLL NOW", "GB")
  Theme.Sound("ticket")
end

fxMyRoll = function()
  if not (win and win:IsShown()) then return end
  if ui.wager then Theme.Pulse(ui.wager) end
  Theme.Sound("stamp")
end

-- Reveal rows: winners first (they are the story), then payers, then the field,
-- then the no-shows. Presentation only - the scoring already ran in applyResult
-- and this runs well after it, behind a pcall.
local function revealRows(S)
  local me = myName()
  local res = S.result
  local out = {}
  if not res or #res.pattern ~= #S.roster then
    out[1] = { text = "Out of sync - result unavailable.", role = "fade" }
    return out
  end
  -- The number we can honestly print. A client only ever observed its OWN roll,
  -- so for anybody else it comes from the RESULT itself: an L slot rolled the
  -- low and an H slot rolled the high, by definition. A middling slot's exact
  -- number is not on the wire and is not invented here.
  local function valueOf(name, c)
    local v = S.rolls[name]
    if v then return tostring(v) end
    if c == "L" then return tostring(res.low) end
    if c == "H" then return tostring(res.high) end
    return "-"
  end
  local function add(want, role, place)
    for i = 1, #S.roster do
      local name = S.roster[i]
      if res.pattern:sub(i, i) == want then
        local delta = (S.rows and S.rows[name]) or 0
        local text = name .. "  -  " .. valueOf(name, want)
        if delta > 0 then
          text = text .. "  collects " .. PG.Money(delta)
        elseif delta < 0 then
          text = text .. "  pays " .. PG.Money(-delta)
        elseif want == "X" then
          text = name .. "  -  no roll"
        end
        out[#out + 1] = { text = text, role = role,
                          place = (place and #out == 0) and 1 or nil,
                          personal = (name == me) }
      end
    end
  end
  add("H", "win", true)
  add("L", "loss")
  add("-", "body")
  add("X", "fade")
  return out
end

fxResult = function()
  local S = mySession()
  if not (win and win:IsShown() and S and S.result) then return end
  local sess = S
  local res = S.result
  local D = res.high - res.low
  local marquee
  if D > 0 and S.lowNames and S.highNames then
    if #S.lowNames == 1 and #S.highNames == 1 then
      marquee = shortOf(S.lowNames[1]) .. " PAYS " .. shortOf(S.highNames[1])
        .. " " .. PG.Money(D)
    else
      marquee = "THE LOW ROLLS PAY THE HIGH ROLLS " .. PG.Money(D)
    end
  else
    marquee = "NO CONTEST"
  end
  Theme.RevealQueue({
    game = "GB",
    anchor = { mode = "window", host = win },
    variant = "podium",
    title = "THE GAMBLER",
    subtitle = "roll 1 - " .. (S.wager or "?") .. "  -  " .. (S.nRolled or 0) .. " rolled",
    rows = revealRows(S),
    marquee = marquee,
    burst = "coins",
    burstCount = 12,
    sound = "coins",
    burstSound = "fanfare",
    -- Reveal ownership (CONCURRENCY.md 5.8 rule 2): the payload belongs to THIS
    -- record. One superseded, withdrawn from or swept before the stage drains is
    -- culled rather than played over whatever replaced it.
    validate = function() return sessions[sess.key] == sess and sess.ended == true end,
    -- precedence (rule 3): the game we PLAYED drains ahead of one we refereed
    priority = sess.seated and 1 or 0,
  })
end

-------------------------------------------------------------------------------
-- Game window
--
-- Laid out on the shared grid (Theme.METRIC) and the shared five-role ramp
-- (Theme.FontTemplate). Every y offset below is a multiple of METRIC.GRID, and
-- the inset, roster pitch, audience offset and footer geometry are the shared
-- numbers, read through mt() rather than copied.
--
-- The bottom block (headline / result / mine) is anchored BOTTOM-up like the
-- other four games, not to absolute offsets: ui.mine used to be pinned at -470
-- in a 520-tall window and drew its descenders through the whole footer button
-- row.
-------------------------------------------------------------------------------

-- 560, not 520, and it is the same height as Death Roll: the bottom block owes
-- the player three separate statements (the verdict, the detail, and the line
-- about them), and at 520 they were bought with roster rows.
local WIN_W, WIN_H = 380, 560
local ROSTER_Y = -196

-- The shared ramp and grid, read at call time. The literals are only what a
-- client with no theme layer would see; this file never carries its own copy of
-- a shared number (Widgets.lua reads METRIC the same way).
local FONT_FALLBACK = {
  D1 = "GameFontNormalHuge", D2 = "GameFontNormalLarge", T = "GameFontNormal",
  B = "GameFontHighlight", S = "GameFontHighlightSmall",
}
local METRIC_FALLBACK = {
  INSET = 24, ROW_PITCH = 20, AUD_Y = -34, FOOTER = 16, BTN_W = 105, BTN_H = 22,
  BTN_PRI_W = 150, BTN_PRI_H = 26,
}
local function ft(role)
  if Theme and Theme.FontTemplate then return Theme.FontTemplate(role) end
  return FONT_FALLBACK[role] or "GameFontHighlight"
end
local function mt(key)
  local M = Theme and Theme.METRIC
  local v = M and M[key]
  if type(v) == "number" then return v end
  return METRIC_FALLBACK[key]
end

rowAt = function(i)
  if not rows[i] then
    local inset = mt("INSET")
    local fs = win:CreateFontString(nil, "OVERLAY", ft("S"))
    fs:SetPoint("TOPLEFT", inset, ROSTER_Y - (i - 1) * mt("ROW_PITCH"))
    fs:SetWidth(WIN_W - 2 * inset)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
    if Theme then Theme.Shadow(fs) end
    rows[i] = fs
  end
  return rows[i]
end

local function chalk(fs)
  fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  if Theme then Theme.Shadow(fs) end
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("gb", "The Gambler", WIN_W, WIN_H, "GB")
  -- The window's two pieces of state, declared here so they always EXIST:
  -- __pgRec is the record it is showing (5.9), __pgFrozen says it has stopped
  -- being a game and become a dismissible record (PLAN 5). Both are set false
  -- rather than left nil so no reader ever has to distinguish "not yet" from
  -- "not any more", and so neither is ever resolved through a metatable.
  win.__pgRec = false
  win.__pgFrozen = false
  -- Core re-shows Safety-hidden windows whose __pgResume() returns true. Two
  -- clauses, and the second is the fix for the way a raid used to eat your
  -- result (PLAN 5, M4): the pull hides the window, the fight outlasts
  -- DONE_TTL, the sweep evicts mid-fight, and there was no session left to
  -- vouch for the frame. A frozen result has no session by definition and is
  -- exactly the thing that has to come back. The live clause is now LG/DR's
  -- stricter one (F19) - the window is bound to ONE record, so it never
  -- resurrects for a session it is not showing.
  win.__pgResume = function()
    local S = mySession()
    if S then return win.__pgRec == S end
    return win.__pgFrozen and true or false
  end

  -- The X is the one dismiss gesture in the addon, and on a frozen result it
  -- is also what ENDS it. Hooked on the button rather than on OnHide, because
  -- OnHide also fires for a Safety hide - the opposite of a dismissal.
  if PG.UI.OnClose then PG.UI.OnClose(win, function() thawWindow() end) end

  local inset = mt("INSET")

  -- the audience, under the title (SCOPE.md 5.4)
  ui.audience = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.audience:SetPoint("TOPLEFT", inset, mt("AUD_Y"))
  ui.audience:SetPoint("TOPRIGHT", -inset, mt("AUD_Y"))
  ui.audience:SetJustifyH("CENTER")
  ui.audience:SetWordWrap(false)
  ui.audience:SetMaxLines(1)
  ui.audience:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.audience) end

  -- The literal command, and the biggest thing in the window: the typed /roll is
  -- the primary path in every state and must never look like a fallback. This is
  -- the one D1 element the window is allowed.
  ui.wager = win:CreateFontString(nil, "OVERLAY", ft("D1"))
  ui.wager:SetPoint("TOPLEFT", inset, -52)
  ui.wager:SetPoint("TOPRIGHT", -inset, -52)
  ui.wager:SetJustifyH("CENTER")
  ui.wager:SetWordWrap(false)
  ui.wager:SetMaxLines(1)
  if Theme then
    Theme.SetFont(ui.wager, "D1")
    Theme.Shadow(ui.wager)
  end
  ui.wager:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])

  -- The rule, plus the loot-roll warning on a second line when it applies. One
  -- region, not two: ui.warn was a second unbounded fontstring saying the same
  -- kind of thing 16px lower, and the colour code carries the alarm.
  ui.hint = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.hint:SetPoint("TOPLEFT", inset, -84)
  ui.hint:SetPoint("TOPRIGHT", -inset, -84)
  ui.hint:SetHeight(28)
  ui.hint:SetJustifyH("LEFT")
  ui.hint:SetJustifyV("TOP")
  ui.hint:SetWordWrap(true)
  ui.hint:SetMaxLines(2)
  chalk(ui.hint)

  ui.rollBtn = PG.UI.CardButton(win, "ROLL", 140, 30, doRoll)
  ui.rollBtn:SetPoint("TOP", 0, -116)
  ui.rollBtn.baseLabel = "ROLL"

  -- TOPLEFT at the inset and the full content width, like every other bar in
  -- the suite: centred, it was the only one that did not line up with the text
  -- column underneath it.
  ui.bar = PG.UI.TimerBar(win, WIN_W - 2 * inset)
  ui.bar:SetPoint("TOPLEFT", inset, -152)

  ui.status = win:CreateFontString(nil, "OVERLAY", ft("B"))
  ui.status:SetPoint("TOPLEFT", inset, -176)
  ui.status:SetPoint("TOPRIGHT", -inset, -176)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(false)
  ui.status:SetMaxLines(1)
  chalk(ui.status)

  -- The empty state is NOT list item zero: its own centred line across the
  -- roster band instead of row 1's left inset (PLAN 4).
  ui.empty = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.empty:SetPoint("TOPLEFT", inset, ROSTER_Y)
  ui.empty:SetPoint("TOPRIGHT", -inset, ROSTER_Y)
  ui.empty:SetJustifyH("CENTER")
  ui.empty:SetWordWrap(false)
  ui.empty:SetMaxLines(1)
  ui.empty:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.empty) end

  -- The grey "Also rolled (not in the game): ..." line stood here. It listed
  -- non-roster players whose /roll we had watched, which this client can no
  -- longer see at all - it reads its own roll and nothing else. Nothing moved to
  -- fill the band: every region below is anchored BOTTOM-up and none of them
  -- shifted.

  -- THE RESULT HEADLINE, on its own line and centred. The money sentence used
  -- to be the third |n-separated clause of ui.result, so three full Name-Realm
  -- entries a side pushed it past SetMaxLines(3) and the game's headline result
  -- - the only line that says how much moved - simply vanished.
  -- D2, not B: this headline is the line that now stays on screen until the
  -- player dismisses the result, so it is the same component RPS renders at D2.
  -- Three games were rendering one component at three sizes.
  ui.headline = win:CreateFontString(nil, "OVERLAY", ft("D2"))
  ui.headline:SetPoint("BOTTOMLEFT", inset, 118)
  ui.headline:SetPoint("BOTTOMRIGHT", -inset, 118)
  ui.headline:SetJustifyH("CENTER")
  ui.headline:SetWordWrap(false)
  ui.headline:SetMaxLines(1)
  ui.headline:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(ui.headline) end

  -- the detail under the headline: body copy, so LEFT and wrapped
  ui.result = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.result:SetPoint("BOTTOMLEFT", inset, 82)
  ui.result:SetPoint("BOTTOMRIGHT", -inset, 82)
  ui.result:SetHeight(28)
  ui.result:SetJustifyH("LEFT")
  ui.result:SetJustifyV("TOP")
  ui.result:SetWordWrap(true)
  ui.result:SetMaxLines(2)
  chalk(ui.result)

  -- The sentence about you, centred, above a centred button row, and anchored
  -- BOTTOM like the other four games rather than at the absolute -470 that put
  -- its descenders through the whole footer.
  --
  -- Two lines, growing UPWARD (JustifyV BOTTOM): every other game repeats its
  -- end text in a wrapped info block, this window has none, and the ones that
  -- explain why nothing was recorded are the longest strings the game owns.
  -- One line lost the tail of exactly those.
  ui.mine = win:CreateFontString(nil, "OVERLAY", ft("B"))
  ui.mine:SetPoint("BOTTOMLEFT", inset, 46)
  ui.mine:SetPoint("BOTTOMRIGHT", -inset, 46)
  ui.mine:SetHeight(28)
  ui.mine:SetJustifyH("CENTER")
  ui.mine:SetJustifyV("BOTTOM")
  ui.mine:SetWordWrap(true)
  ui.mine:SetMaxLines(2)
  ui.mine:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(ui.mine) end

  local btnW, btnH, foot = mt("BTN_W"), mt("BTN_H"), mt("FOOTER")
  ui.rulesBtn = PG.UI.Button(win, "Rules", btnW, btnH, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("GB") end
  end)
  ui.rulesBtn:SetPoint("BOTTOMLEFT", inset, foot)

  ui.startBtn = PG.UI.Button(win, "Start now", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and S.phase == "join" then hostCloseJoin() end
  end)
  ui.startBtn:SetPoint("BOTTOM", 0, foot)

  ui.cancelBtn = PG.UI.Button(win, "Cancel game", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and live() then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOM", 0, foot)

  ui.againBtn = PG.UI.Button(win, "Play again", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and S.phase == "done" and S.ended then
      -- fresh session, same config and same audience; hostOpen supersedes this
      -- finished record locally and mints a new token
      hostOpen(S.wager, S.joinSecs, S.rollSecs, S.scope)
    end
  end)
  ui.againBtn:SetPoint("BOTTOM", 0, foot)

  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", btnW, btnH, function()
    local S = mySession()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "GB", "UNJOIN", S.token)
      -- the local press is authoritative for this client (7.2): the seat frees
      -- and the record goes now, rather than waiting on a LEFT a lockdown may
      -- swallow. Nothing is owed before BEGIN.
      applyLeft(myName())
    end
  end)
  ui.withdrawBtn:SetPoint("BOTTOM", 0, foot) -- shares the host-only slot

  -- one label and one size for the Ledger button across the suite; the shared
  -- inset is also what lifts it off the resize grip, which used to own a 3x3
  -- corner of it and win the click
  ui.ledgerBtn = PG.UI.Button(win, "Open Ledger", btnW, btnH, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ui.ledgerBtn:SetPoint("BOTTOMRIGHT", -inset, foot)

  if Theme then
    win.__pgBannerSlot = rowAt(1) -- banners slide in over the roster area
  end
end

-------------------------------------------------------------------------------
-- THE FROZEN RESULT (PLAN 5)
--
-- A finished record is evicted on schedule and the memory contract does not
-- move. What stops being swept away is the WINDOW: it stays until the player
-- closes it. The hazard is not persistence, it is a dead window that LOOKS
-- live (CONCURRENCY.md 5.9), so the frame stops being a game and becomes a
-- record: every affordance that could send anything goes, the timer is stopped
-- AND hidden (a bar sitting at 0 reads as about to start), and the state is
-- said out loud in the title and in the status line.
--
-- It holds NO reference to the record it describes. RefreshUI has already
-- written every final string into the fontstrings, so the pixels are the
-- storage; even the timestamp is derived from doneAt at freeze time rather
-- than stashed on the record. One boolean per module, addon-wide.
-------------------------------------------------------------------------------

freezeWindow = function(rec)
  -- Only the window that is CURRENTLY showing this finished record - and only
  -- while it is on screen, OR while Safety has it hidden. That second case is
  -- the whole point: a game that ends during a boss pull has its window hidden
  -- by Core and its record swept mid-fight, which is the commonest way a
  -- player loses a result they never saw. IsShown() alone gets it wrong there.
  if not (win and rec and rec.phase == "done" and win.__pgRec == rec) then return end
  local hidden = PG.Safety.HidBy and PG.Safety.HidBy(win)
  if not (win:IsShown() or hidden) then return end
  win.__pgRec = false        -- the record dies here; the window outlives it
  win.__pgFrozen = true
  ui.bar:Stop()
  ui.bar:Hide()
  -- everything that touches the wire, or that a player could read as "this is
  -- still going". "Play again" goes with them: that button would start a wire
  -- transaction from a dead record's window (PLAN 5.3). Rules goes too - a
  -- frozen result keeps Open Ledger and the X, and nothing else, in all six.
  ui.rollBtn:Hide()
  ui.startBtn:Hide()
  ui.cancelBtn:Hide()
  ui.againBtn:Hide()
  ui.withdrawBtn:Hide()
  ui.rulesBtn:Hide()
  -- Open Ledger is left exactly as RefreshUI last set it: a game that committed
  -- to the ledger keeps its button, an abandoned one never had one to keep.
  local clock = PG.UI.ClockAgo and PG.UI.ClockAgo(GetTime() - (rec.doneAt or GetTime()))
  if PG.UI.SetTitle then
    PG.UI.SetTitle(win, "The Gambler - final" .. (clock and (" (" .. clock .. ")") or ""))
  end
  ui.status:SetText("Final result - "
    .. (rec.isHost and "your game" or (shortOf(rec.host) .. "'s game"))
    .. ". " .. P.chgray .. "Close to dismiss.|r")
  if Theme and Theme.Stamp then Theme.Stamp(win, "FINAL") end
end

-- A live session always reclaims the frame (RefreshUI's first act), and so does
-- the X. Whatever freezeWindow hid that RefreshUI does not drive itself comes
-- back here - the bar, the title, and Rules, which is the one button in the
-- suite that is window furniture rather than game state.
thawWindow = function()
  if not (win and win.__pgFrozen) then return end
  win.__pgFrozen = false
  if PG.UI.SetTitle then PG.UI.SetTitle(win, "The Gambler") end
  ui.bar:Show()
  ui.rulesBtn:Show()
end

-- The rule, and under it the line the loot-roll collision needs (edge case 5).
-- One region: the rule is trimmed to a single line at the content width so the
-- warning always has the second one.
local HINT_RULE = "Lowest pays highest the difference. Your FIRST roll counts."
local function hintText(S)
  if (S.wager or 0) ~= 100 then return HINT_RULE end
  return HINT_RULE .. "|n" .. P.chred
    .. "100 is also the default /roll - a loot roll will count against you.|r"
end

local function rosterLines(S, me)
  local lines = {}
  local res = S.result
  local mapped = res and (#res.pattern == #S.roster) or false
  for i = 1, #S.roster do
    local name = S.roster[i]
    local o = S.rolls[name]
    local tag = (name == me) and (P.chgold .. " (you)|r") or ""
    local line
    if S.phase == "join" then
      line = name .. tag
    elseif S.phase == "done" and mapped then
      local c = res.pattern:sub(i, i)
      local delta = (S.rows and S.rows[name]) or 0
      if c == "X" then
        line = P.chgray .. name .. "   no roll|r"
      elseif delta < 0 then
        line = P.chred .. name .. "   " .. (o or res.low)
          .. "   pays " .. PG.Money(-delta) .. "|r"
      elseif delta > 0 then
        line = P.chgreen .. name .. "   " .. (o or res.high)
          .. "   collects " .. PG.Money(delta) .. "|r"
      else
        line = name .. "   " .. (o or "-") .. tag
      end
    elseif o then
      line = name .. "   " .. o .. tag
    elseif S.isHost then
      -- the host holds every report, so a blank really is "has not rolled yet"
      line = P.chgray .. name .. "   -|r"
    else
      -- ...and a client holds only its own, so it says nothing about anybody
      -- else's roll rather than greying them out as if they had not made one.
      line = name .. tag
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- The audience, named in the window itself so nobody has to remember which one
-- they picked. Loot Goblins' wording: at the two wide scopes the line carries
-- the settling-up reality rather than just the label.
local SCOPE_HEADER = {
  group = "Party",
  guild = "Guild game - settle up with people you can find again.",
  public = "Public - realm-wide. Virtual gold, honour-system settling.",
}

RefreshUI = function()
  local S = mySession()
  -- No session, no repaint: this is also what leaves a frozen result's pixels
  -- alone, because a frozen window's record has been evicted by definition.
  if not win or not S then return end
  -- ...and a LIVE session always reclaims the frame, so a frozen result can
  -- never be left labelled "final" over a game that is actually running.
  if win.__pgFrozen then thawWindow() end
  win.__pgRec = S            -- 5.9: the window is bound to the involved record
  local now = GetTime()
  local me = myName()
  local isJoin = S.phase == "join"
  local isRoll = S.phase == "roll"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false
  local refereed = (S.isHost and not S.seated) and true or false

  ui.audience:SetText(SCOPE_HEADER[S.scope] or "")
  ui.wager:SetText("/roll " .. (S.wager or "?"))
  ui.hint:SetText(hintText(S))

  local status
  if isJoin then
    if S.isHost then
      local remaining = S.joinFrozen and (S.joinRemaining or 0)
        or math.max(0, (S.joinDeadline or now) - now)
      -- CONCURRENCY.md 6.3: no BUSY message exists, so the host is shown what
      -- this client already knows for free - who else here runs the addon.
      -- PG.Peers counts GROUP and private traffic only and is pruned against
      -- the live group, so it is shown at group scope only; at guild or public
      -- it would be a confident number about the wrong room.
      local peers = 0
      if S.scope == "group" then
        for _ in pairs(PG.Peers or {}) do peers = peers + 1 end
      end
      status = #S.roster .. " in"
        .. ((peers > 0) and (" of " .. (peers + 1) .. " addon users") or "")
        .. " - rolls start in " .. math.ceil(remaining) .. "s"
        .. (S.joinFrozen and " (paused)" or "")
    else
      status = #S.roster .. " in - waiting for the host to start"
    end
  elseif isRoll then
    if S.hostQuiet then
      -- SCOPE.md 6.2: quiet is not dead, and nothing has been lost. Your own
      -- roll is already reported (or will re-send from the ticker), so this is
      -- genuinely just waiting.
      status = "Waiting for the host - they may be in a boss fight."
    elseif S.spectator then
      status = "Spectating - your roster is out of sync."
    elseif not S.rollOpen then
      status = "Roster locked - the roll window opens in a moment..."
    elseif S.frozen or not rollGateOpen() then
      status = "Paused - rolls don't count until this clears."
    elseif S.isHost then
      -- Only the host has the count: every other client reports its own roll and
      -- hears nothing back until RESULT. Claiming a tally we do not hold would be
      -- the sort of confident lie this file spent three passes removing.
      status = S.rollN .. " of " .. #S.roster .. " rolled"
    else
      status = #S.roster .. " playing - the host is counting the rolls"
    end
  else
    -- the end text itself is ui.mine's line, not this one; repeating it in both
    -- places just makes the window say the same sentence twice
    status = "Game over"
  end
  ui.status:SetText(status)

  local lines = rosterLines(S, me)
  -- emptyText goes to the centred ui.empty, never into roster row 1: an empty
  -- state is not list item zero. One string across all six games (PLAN 4).
  local emptyText
  if not lines[1] then emptyText = "Nobody has joined yet." end
  if refereed then
    table.insert(lines, 1, P.chgray .. shortOf(S.host) .. " (running the game)|r")
    -- the referee line occupies the band, so the notice is no longer the only
    -- thing on screen and goes back into the list where it reads as one
    if emptyText then
      lines[2] = P.chgray .. emptyText .. "|r"
      emptyText = nil
    end
  end
  -- The local player's row is the one row the collapse may not eat: when it
  -- falls past the cut it is lifted into the last visible slot, the rule Death
  -- Roll and the reveal stage already apply (PLAN 3, F6).
  if #lines > MAX_ROWS and me then
    local mineAt
    for i = MAX_ROWS, #lines do
      if lines[i]:find(me, 1, true) then
        mineAt = i
        break
      end
    end
    if mineAt then
      local row = table.remove(lines, mineAt)
      table.insert(lines, MAX_ROWS - 1, row)
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
  ui.empty:SetText(emptyText or "")
  ui.empty:SetShown(emptyText ~= nil)

  -- The outcome. The verdict - the sentence that says how much moved - is its
  -- own centred headline; the names that produced it are the detail under it.
  -- They used to be one string with the money last, so three full Name-Realm
  -- entries a side pushed the money clause off the end of SetMaxLines(3).
  local headText, resultText = "", ""
  if isDone and S.result then
    local res = S.result
    local D = res.high - res.low
    if #res.pattern ~= #S.roster then
      -- the pattern never mapped onto our roster, so we cannot name anybody in
      -- it; the numbers below would be sentences with holes where names go
      resultText = "Out of sync with the host - this client could not match the"
        .. " result to its own roster, so nothing was recorded."
    elseif (S.nRolled or 0) == 0 then
      headText = "Nobody rolled - no gold changes."
    elseif D <= 0 then
      headText = (S.nRolled == 1)
        and ("Only one player rolled " .. res.high .. " - no contest.")
        or ("Everyone rolled " .. res.high .. " - nobody pays anybody.")
    else
      local lowNames = S.lowNames or {}
      local highNames = S.highNames or {}
      local function nameList(list)
        local n = math.min(#list, 3)
        local parts = {}
        for i = 1, n do parts[i] = list[i] end
        local s = table.concat(parts, ", ")
        if #list > n then s = s .. " and " .. (#list - n) .. " more" end
        return s
      end
      headText = PG.Money(D) .. " moves from the low rolls to the high rolls."
      resultText = nameList(lowNames) .. " rolled " .. res.low .. ". "
        .. nameList(highNames) .. " rolled " .. res.high .. "."
    end
  elseif isRoll and not S.rollOpen then
    resultText = "No roll = no stake. You cannot lose by sitting still."
  end
  -- No join-phase line here any more: it restated ui.hint's rule word for word,
  -- 300px lower in the same window.
  ui.headline:SetText(headText)
  ui.result:SetText(resultText)

  -- the one line the player actually reads
  local mineText
  if isDone then
    mineText = S.endText or ""
  elseif refereed then
    mineText = P.chgray .. "You're running this one - no roll for you.|r"
  elseif S.spectator then
    mineText = P.chgray .. "Spectating - no gold will be recorded.|r"
  elseif isJoin then
    mineText = inRoster and "You are in - good luck!"
      or (P.chgray .. "You have not joined this game.|r")
  elseif not inRoster then
    mineText = P.chgray .. "You are sitting this one out.|r"
  elseif me and S.rolls[me] then
    mineText = "You rolled " .. P.chgold .. S.rolls[me] .. "|r."
  elseif not rollsReady() then
    -- Honest, and NOT the player's fault - but the consequence changed with the
    -- roll path: a client that cannot parse its own /roll line has nothing to
    -- report, and the host cannot score a roll nobody told it about.
    mineText = P.chgray .. "This client can't read /roll results, so your roll can't be reported.|r"
  else
    mineText = "Type " .. P.chgold .. "/roll " .. (S.wager or "?") .. "|r in chat."
  end
  ui.mine:SetText(mineText)

  -- The ROLL button is a convenience over the typed command and never the only
  -- way in: it is simply absent when the client cannot roll for you.
  local canRoll = (isRoll and S.rollOpen and S.seated and not S.spectator and inRoster
    and me and not S.rolls[me] and not S.frozen) and true or false
  local waiting = (S.rollAskedAt and (now - S.rollAskedAt) < ROLL_CONFIRM) and true or false
  ui.rollBtn:SetShown(canRoll and rollsAvailable())
  ui.rollBtn:SetEnabled(canRoll and not waiting)
  ui.rollBtn:SetText(waiting and "ROLLING..." or ui.rollBtn.baseLabel)

  ui.startBtn:SetShown(isJoin and S.isHost)
  -- no cancel once RESULT is queued: the ledger lands all-or-nothing
  ui.cancelBtn:SetShown((S.isHost and isRoll and not S.resultSent) and true or false)
  ui.againBtn:SetShown((isDone and S.ended and S.isHost) and true or false)
  ui.withdrawBtn:SetShown((isJoin and not S.isHost and S.joinAccepted) and true or false)
  ui.ledgerBtn:SetShown((isDone and S.committed) and true or false)
end

ShowWindow = function()
  -- 5.9: one window per module, bound to the INVOLVED record. An overheard
  -- session renders an invitation and nothing else.
  local S = mySession()
  if not S then return end
  if not (S.isHost or S.joinAccepted) then return end
  local st = PG.Safety.state
  if st.inEncounter or st.readyCheck or st.countdown or st.restricted then return end
  if st.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return end
  ensureWindow()
  RefreshUI()
  win:Show()
end

-------------------------------------------------------------------------------
-- Host setup panel (a shell page, not a window)
-------------------------------------------------------------------------------

-- The setup panel's own geometry. 420x548 is the shell's content slot
-- (PG.UI.Shell.CONTENT_W / CONTENT_H), which the shell clamps anything larger
-- to; the page is created at exactly that size so its action row lands on the
-- slot's floor like every other page's bottom element. A left label column
-- against a right-anchored input column, both at the shared inset, so the two
-- edges agree.
local PAGE_ID = "setup:GB"
local PAGE_W, PAGE_H = 420, 548
local FIELD_W = 70
local FIELD_PITCH = 32   -- the shipped row pitch: a 20px input plus 12
local function makeField(parent, label, y, default, maxLetters)
  local inset = mt("INSET")
  local fs = parent:CreateFontString(nil, "OVERLAY", ft("T"))
  fs:SetPoint("TOPLEFT", inset, y)
  -- bounded: the label column is what the input column leaves, and no
  -- FontString in this file is allowed to be unbounded
  fs:SetWidth(PAGE_W - 2 * inset - FIELD_W - 8)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:SetMaxLines(1)
  fs:SetText(label)
  fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  if Theme then Theme.Shadow(fs) end
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(FIELD_W, 20)
  eb:SetPoint("TOPRIGHT", -inset, y + 2)
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

-- SCOPE.md 5.2 cfg.reasons. This used to REFUSE guild and public ("a /roll only
-- reaches your party or raid"), which stopped being true the moment each client
-- began reporting its own roll over the wire. Now every segment is playable and
-- these ride along as information; the public wording is Loot Goblins' in
-- substance, because the ledger is a claim and not a transfer.
local function scopeNote(scope)
  if scope == "public" then
    return "Public - anyone on your realm. Gold here is virtual and settling up is"
      .. " on the honour system, so a stranger who loses can simply log out."
      .. " Fine for fun; keep the wager small with people you do not know."
  elseif scope == "guild" then
    return "Everyone in your guild who runs the addon, on any realm. Each player"
      .. " rolls in their own chat and their addon reports it to the table."
  end
  return nil
end

refreshDialog = function()
  if not (page and dlgNote and dlgStart) then return end
  local note, canStart = involvement()
  local scope = dlgScope and dlgScope:Get() or nil
  local why
  if not canStart then
    why = note
  elseif not rollsReady() then
    canStart = false
    why = "This client can't read /roll results, so it can't score a game."
    note = why
  elseif not scope then
    canStart = false
    why = "Nowhere to start a game: you're not in a group or a guild."
    note = why
  end
  -- The loot-roll collision is signposted, not forbidden: a wager of exactly 100
  -- is the ceiling of a bare /roll, so a raider rolling on loot would be scored.
  if dlgInputs and dlgInputs.wager
    and math.floor(tonumber(dlgInputs.wager:GetText()) or 0) == 100 then
    note = "100 is also the default /roll - a loot roll will count against you."
      .. (note and ("|n" .. note) or "")
  end
  dlgNote:SetText(note or "")
  dlgStart:SetEnabled(canStart and true or false)
  dlgStart:SetAlpha(canStart and 1 or 0.6)
  dlgStart.__pgWhy = why
end

-- The play window is opening, so the shell steps back to the games grid - which
-- is what the old dialog did by closing over a still-open launcher. Guarded on
-- being the page actually on screen, so a Start fired from anywhere else can
-- never navigate the shell out from under the player. With no shell at all (a
-- headless harness) the panel just hides, as before.
local function closeSetup()
  local S = PG.UI and PG.UI.Shell
  if S then
    if S.Current() == PAGE_ID then S.Back() end
  elseif page then
    page:Hide()
  end
end

-- THE SETUP PANEL IS A PAGE NOW, not a window. `f` is the frame the shell hands
-- in, and every control below is the shipped dialog with its geometry moved by
-- exactly two things:
--   * `top` - the page's own first-element offset (page.__pgTop, -8). It
--     replaces the -56 that used to clear a title bar this panel no longer has,
--     and every offset below is stated relative to it, so the 48px dead-band
--     reclaim is one constant per file (PLAN 1.5);
--   * the action row hangs off the page's BOTTOM at the shared FOOTER offset,
--     because the page is the full height of the slot rather than 344 of it.
-- Nothing a control DOES changed, including Start's availability re-check
-- (SCOPE.md 1.3).
local function buildSetup(f)
  if page then return end
  page = f
  -- tonumber, not a bare `or`: the page contract says __pgTop is a number, and
  -- a frame that answers with anything else must not silently poison every
  -- offset below it.
  local top = tonumber(f.__pgTop) or -8
  local inset = mt("INSET")
  local hint = page:CreateFontString(nil, "OVERLAY", ft("S"))
  hint:SetPoint("TOPLEFT", inset, top)
  hint:SetPoint("TOPRIGHT", -inset, top)
  hint:SetHeight(24)
  hint:SetJustifyH("LEFT")
  hint:SetJustifyV("TOP")
  hint:SetWordWrap(true)
  hint:SetMaxLines(2)
  hint:SetText("Everyone rolls once. The lowest roll pays the highest roll the difference.")
  hint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(hint) end
  dlgInputs = {
    -- 1000, not 100, and that is not a taste call: 100 is exactly the ceiling of
    -- a bare /roll, so a 100g default would enroll loot rolls by accident on
    -- day one.
    wager = makeField(page, "Max wager (gold)", top - FIELD_PITCH, 1000, 6),
    joinSecs = makeField(page, "Join window (sec)", top - FIELD_PITCH * 2, 30, 3),
    rollSecs = makeField(page, "Roll window (sec)", top - FIELD_PITCH * 3, 30, 3),
  }
  -- HookScript, never SetScript: InputBoxTemplate binds its own OnTextChanged
  -- and clobbering it breaks the edit box's own behaviour.
  dlgInputs.wager:HookScript("OnTextChanged", function() refreshDialog() end)
  -- The audience picker: a segmented control, never a dropdown (SCOPE.md 5.1).
  -- Guild and Public stay VISIBLE and greyed with their reason, because "why
  -- can't I?" is information the user wants.
  dlgScope = PG.UI.ScopePicker(page, {
    key = "GB",
    allowed = PG.GB.SCOPES,
    reasons = scopeNote,
    onChange = function() refreshDialog() end,
  })
  -- 124 below the first element, which is where the shipped -180 sat against a
  -- -56 hint: the three field rows plus the picker's own top gap.
  dlgScope:SetPoint("TOPLEFT", page, "TOPLEFT", 0, top - 124)
  dlgScope:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, top - 124)

  -- Anchored to the picker's own bottom, not to an absolute offset that has to
  -- be re-guessed every time the control changes height.
  dlgNote = page:CreateFontString(nil, "OVERLAY", ft("S"))
  dlgNote:SetPoint("TOPLEFT", dlgScope, "BOTTOMLEFT", inset, -8)
  dlgNote:SetPoint("TOPRIGHT", dlgScope, "BOTTOMRIGHT", -inset, -8)
  dlgNote:SetJustifyH("LEFT")
  dlgNote:SetJustifyV("TOP")
  dlgNote:SetWordWrap(true)
  dlgNote:SetHeight(36)
  dlgNote:SetMaxLines(3)
  dlgNote:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(dlgNote) end

  local startLabel = "Start game"
  if Theme then
    local m = Theme.Mark("dice")
    if m ~= "" then startLabel = m .. " Start game" end
  end
  dlgStart = PG.UI.Button(page, startLabel, mt("BTN_PRI_W"), mt("BTN_PRI_H"), function()
    local scope = dlgScope and dlgScope:Get() or nil
    if not scope then
      toast("nowhere to start a game - you're not in a group or a guild.")
      return
    end
    local wager = fieldValue(dlgInputs.wager, MIN_WAGER, MAX_WAGER)
    local joinSecs = fieldValue(dlgInputs.joinSecs, 15, 120)
    local rollSecs = fieldValue(dlgInputs.rollSecs, 10, 120)
    if Theme then Theme.Sound("stamp") end
    closeSetup()
    hostOpen(wager, joinSecs, rollSecs, scope)
  end)
  dlgStart:SetPoint("BOTTOM", 0, mt("FOOTER"))
  local dlgRules = PG.UI.Button(page, "Rules", mt("BTN_W"), mt("BTN_H"), function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("GB") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", inset, mt("FOOTER"))
  dlgStart:SetScript("OnEnter", function(self)
    if not self.__pgWhy then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.__pgWhy, 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  dlgStart:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- No OnShow hook here any more: the shell's page contract promises def.onShow
  -- on every appearance, including a shell re-open onto a page that never hid,
  -- which a frame's own OnShow does not.
end

-- Launcher / slash entry point, signature unchanged: it now focuses the shell
-- on this game's setup page. The page ALWAYS opens (CONCURRENCY.md 0.2): Start
-- is what explains itself.
function PG.GB.OpenDialog()
  local S = PG.UI and PG.UI.Shell
  if S then return S.Push(PAGE_ID) end
  -- No shell at all. Widgets.lua defines PG.UI.Shell at file scope, so the
  -- addon never takes this branch; the headless harnesses stub PG.UI without
  -- one and the panel still has to build and still has to work.
  if not page then buildSetup(CreateFrame("Frame", nil, UIParent)) end
  if dlgScope then dlgScope:Refresh() end
  refreshDialog()
  page:Show()
  return true
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

PG.RegisterInit(function()
  if PG.Theme and PG.Theme.C then
    Theme = PG.Theme
    local c = Theme.C()
    for k in pairs(P) do
      if c[k] ~= nil then P[k] = c[k] end
    end
  end
  PG.Comm.Register("GB", onComm, onDrop)

  -- The setup panel is a page in the one shell window. Registered here, built
  -- lazily on its first focus; the launcher's tile bridges to it by id, so
  -- registering is the whole of the hand-off (PLAN 1.1 / 1.2).
  if PG.UI and PG.UI.Shell then
    PG.UI.Shell.RegisterPage(PAGE_ID, {
      build = buildSetup,
      -- Availability is re-read on every appearance (SCOPE.md 1.3). The
      -- picker's own parent-OnShow hook covers a page switch; this covers
      -- re-opening the shell onto a page that never hid.
      onShow = function()
        if dlgScope then dlgScope:Refresh() end
        refreshDialog()
      end,
      title = "The Gambler",
      level = 2,
      nav = "games",
      accent = "GB",
      width = PAGE_W,
      height = PAGE_H,
    })
  end
  -- The gbdialog window is gone; its saved position is dead data.
  if PG.db and PG.db.profile and type(PG.db.profile.positions) == "table" then
    PG.db.profile.positions.gbdialog = nil
  end

  -- Whisper trust (SCOPE.md 4.3, retargeted at the registry by CONCURRENCY.md
  -- 5.4). This was The Pull Book's blanket `false` while the game was group
  -- only, and that was right: the predicate is consulted only for whispers that
  -- already failed the group test, and inside a group there was no such thing as
  -- a legitimate GB whisper from outside it. At guild and public the group test
  -- vouches for nobody, so a blanket false drops the first JOIN, every ROLLED
  -- report and every SYNCQ - the scopes would be dead on arrival. Rock Paper
  -- Scissors' shape: the host, anybody already in the roster, and a stranger's
  -- opening JOIN while OUR join window is open at a wider scope. Coarse on
  -- purpose - every message behind it still passes the full gate chain and its
  -- own field validation, and the router's rate limiter bounds the last case.
  if PG.Comm.RegisterTrust then
    PG.Comm.RegisterTrust("GB", function(sender)
      local S = mySession()
      if not S or S.phase == "done" then return false end
      if sender == S.host then return true end
      if S.joined[sender] then return true end
      if S.isHost and S.phase == "join" and S.scope ~= "group" then return true end
      return false
    end)
  end
  -- Registered once, for the life of the session: a /roll in a raid is common
  -- enough that churning registrations would cost more than onRollObserved's
  -- first line, which returns immediately when no game is running.
  if PG.Rolls and PG.Rolls.OnRoll then
    PG.Rolls.OnRoll("GB", onRollObserved)
  end
  PG.Safety.OnChange(onSafetyChange)
  -- Accepting one invitation withdraws the rest (CONCURRENCY.md 5.6 rule 3).
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
