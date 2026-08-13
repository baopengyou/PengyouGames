-- Games/LootGoblins.lua - Loot Goblins: buy-in social deduction over addon
-- messages. Exactly one host (the starter, who also plays); clients mirror the
-- host's broadcasts. The ledger applies only at END (all-or-nothing): CANCEL,
-- host death or a local abort leaves every ledger untouched.
-- Genuine message gaps (encounter comms lockdowns, loading screens) self-heal
-- through the SYNCQ resync protocol (spec 9b): the host replays exactly the
-- ORIGINAL messages a client missed, every application is idempotent, and a
-- client that cannot prove it applied every round writes no ledger delta at all.
local ADDON, PG = ...

PG.LG = {}

local TICK = 0.5            -- master ticker period (drives all session timing)
local HB_INTERVAL = 10      -- host heartbeat cadence
local HB_TIMEOUT = 35       -- client: host is dead after this much silence
local REVEAL_SECS = 5       -- pause between RESULT and the next ROUND
local VOID_PAUSE_SECS = 3   -- pause between VOID and the next ROUND
local BEGIN_PAUSE_SECS = 2  -- pause between BEGIN and round 1
local MIN_REOPEN_SECS = 3   -- floor for the timer when re-opening a frozen round
-- Window layout, on the shared spacing grid (PG.Theme.METRIC). These mirror
-- METRIC.INSET / ROW_PITCH / ROW_H as literals because file scope may not read
-- another module's tables; every offset in this file is a multiple of GRID = 4.
--
-- The roster band runs from ROWS_TOP downwards at ROW_PITCH, and its last row
-- must clear ui.mine (whose top edge is MINE_TOP) by one row plus a 12px gap.
-- MAX_ROWS is DERIVED from that band rather than hand-set (PLAN 2.4 / F5), so
-- the cap and the geometry can never disagree.
local INSET = 24            -- METRIC.INSET: side inset AND roster row inset
local ROW_PITCH = 20        -- METRIC.ROW_PITCH: 12px line + 8 leading
local ROW_H = 12            -- METRIC.ROW_H
local ROWS_TOP = 292        -- first roster row, 8px under the status line
local MINE_TOP = 560        -- 620 window - 46 bottom anchor - 14 line
local MAX_ROWS = math.floor((MINE_TOP - ROW_H - 12 - ROWS_TOP) / ROW_PITCH) + 1
local NPC_RESERVE = 150     -- 120 NPC container + 18 right margin + 12 gap
local MAX_GOLD = 100000 * 40 -- buy-in cap * roster cap: bound for every
                             -- pot/pay/carry/dust wire field (keeps huge/inf
                             -- out of the persisted ledger)
local SYNC_COOLDOWN = 10     -- min seconds between SYNCQ sends/serves per peer
local SYNC_MAX_REPLAY = 20   -- resync gaps larger than this get SYNCNO (spectate)

local GREEN, RED, GRAY, GOLD = "|cff40ff40", "|cffff5050", "|cffaaaaaa", "|cffffd200"

-------------------------------------------------------------------------------
-- The session registry (CONCURRENCY.md 2).
--
-- The single module-global `S` is gone. A person PLAYS one round-based game at
-- a time, but unlimited sessions may exist around them - two Loot Goblins games
-- in one raid, a Rock Paper Scissors game alongside both - and none of them may
-- block another. So this file keeps:
--   * ONE full record: the session it hosts or sits in. That record is exactly
--     the old `S` table plus kind/key/scope/seated.
--   * Bounded LITE records for sessions it merely overhears: an invitation and
--     a clean identity, nothing else. No roster, no totals, no picks, no
--     history, no ticker, no frame. A lite record never sends anything, never
--     writes the ledger, and never reaches an applier.
--
-- `S` did not disappear: every function that used the old upvalue opens with
-- `local S = mySession()`, so the appliers, the FX and the window below are the
-- code they always were. Only the OPEN path, the comm prologue, the sends and
-- teardown changed.
-------------------------------------------------------------------------------

local sessions = {}   -- [key] = record, key = host .. "|" .. token
local mine            -- key of the ONE full record (hosted or seated), or nil
local recent = {}     -- [key] = GetTime() when it died: replay defence
local recentQ = {}    -- FIFO of poisoned keys, capped at MAX_RECENT

local MAX_LITE = 8          -- overheard sessions remembered at once
local MAX_RECENT = 16       -- dead keys remembered
local RECENT_TTL = 120      -- seconds a dead key stays poisoned
local DONE_TTL = 60         -- seconds a finished full record lingers
local LITE_TTL_PAD = 10     -- a lite record lives joinSecs + this ...
local LITE_TTL_MIN = 15     -- ... clamped into this range
local LITE_TTL_MAX = 180
local ASK_MAX = 3           -- refreshed from PG.UI.ASK_MAX at init
local BUSY_TOAST_EVERY = 60 -- busy client: at most one group line per minute
-- The guild popup budget (SCOPE.md 6.3) is shared by every module and lives in
-- Widgets next to AskCount: PG.UI.GuildAskOK / PG.UI.GuildAskSpend.
local HB_QUIET_WIDE = 150   -- wide scope: the host is quiet, not dead
local HB_GIVEUP_WIDE = 300  -- wide scope: now they are dead

-- Loot Goblins plays to every audience (SCOPE.md 1.2 as amended by the owner
-- decision of 2026-08-12). Public is made safe by the participation gate inside
-- PG.Ledger.Commit - rows are written only for a session this client joined and
-- played - not by forbidding the audience.
PG.LG.SCOPES = { group = true, guild = true, public = true }

-- Loot Goblins CLAIMS the single round-based seat (CONCURRENCY.md I1). Declared
-- here since 1.1.0 so the launcher's Join gate can read a flag off the module
-- instead of carrying a list of module codes that somebody has to remember to
-- extend (BRIEF 1.1). This is a declaration, not a new behaviour: the claim
-- itself has always happened in the accept path and in hostOpen.
PG.LG.SEAT = true

-- The advisory that rides along on the Public segment: honest about what the
-- ledger is (a claim, not a transfer) instead of refusing the audience.
local PUBLIC_NOTE = "Public - anyone on your realm. Gold here is virtual and "
  .. "settling up is on the honour system, so a stranger who loses can simply "
  .. "log out. Fine for fun; keep buy-ins small with people you do not know."

local ticker
local tickN = 0
local win, dialog, dlgInputs, dlgScope, dlgNote, dlgOpen
local ui = {}
local rows = {}
local rowOffset = 0 -- roster rows start one line lower under a referee host
local rowLifted = false -- the local player's row was hoisted past the cut (F6),
                        -- so that slot no longer matches its roster index

-- Presentation layer (SKIN.md). Captured at init / built with the window; ALL
-- of it is decoration - game logic never branches on any of these, and every
-- Blizzard art/sound/model call routes through PG.Theme.
local Theme, TC        -- PG.Theme and the one palette (nil if Theme absent)
local npc              -- Grizzle, the 3D goblin host (Theme.NPC handle)
local stampPool             -- A6: up to 8 pooled red-X hoarder stamps
local sparkFrame, sparkGroup -- A9 END sparkles
-- The round/session result moment itself belongs to the shared reveal stage
-- (REVEAL.md 6.1/6.2, PG.Theme.Reveal / PG.Theme.RevealQueue), so this file
-- owns no glow/starburst/coin-shower/banner of its own for those beats.
local greetToken            -- session KEY the host model has greeted already
local lastNodAt, lastClinkAt = 0, 0 -- fx rate limits (join nods / pot clinks)

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt
local clientRequestSync, appliedThrough
local buildRevealFX, hideStamps, placeStamps, fxGreet
local fxJoined, fxBegin, fxRound, fxResult, fxVoid, fxEnd, fxPick

-- floor(a / b) for non-negative integers; exact in float math (a % b is exact
-- for integer-valued floats, so no 0.8-style rounding drift can creep in)
local function idiv(a, b) return (a - a % b) / b end

local function myName() return PG.FullName("player") end

-- wire-field validation: non-secret, numeric, floored, in [lo, hi]; else nil
local function num(v, lo, hi)
  local n = PG.SafeNum(v)
  if not n then return nil end
  n = math.floor(n)
  if lo and n < lo then return nil end
  if hi and n > hi then return nil end
  return n
end

-- Roster agreement fingerprint. RESULT patterns are positional over the sorted
-- roster and no name ever travels with an outcome, so a mirror whose roster has
-- the right SIZE but the wrong MEMBERS would credit the wrong players with no
-- error anywhere - a count comparison cannot see it. Bytes are weighted by
-- position inside a name (so anagrams differ) and names by position in the list
-- (so a swap is caught). O(roster bytes), computed only at BEGIN/SYNCQ.
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

-- Plain combat (open world, raid trash) neither blocks addon messaging nor
-- pauses the game: the 12.1 lockdown is encounter/M+/PvP-scoped and is checked
-- separately via PG.Comm.Locked(). Only the encounter/pre-pull states pause us.
local function allClear()
  local s = PG.Safety.state
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

-- Identity is the PAIR (host, token) plus the derived scope (CONCURRENCY.md
-- 3.2). `sender` is server-vouched and realm-qualified, so a token only has to
-- be unique inside one character's history - two Thralls on connected realms
-- can no longer collide, and the wire gets smaller rather than larger.
local function keyOf(host, token) return host .. "|" .. token end

-- The ONE session this module fully tracks. Nil when it is in none.
local function mySession() return mine and sessions[mine] or nil end

-- Sessions we know about at all (full + lite): drives toast attribution.
local function recordCount()
  local n = 0
  for _ in pairs(sessions) do n = n + 1 end
  return n
end

-- "Name-Realm" -> "Name" (names never contain "-"; realms do).
local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function b36(n)
  n = math.floor(tonumber(n) or 0)
  if n <= 0 then return "0" end
  local out = ""
  while n > 0 do
    local d = n % 36
    out = B36:sub(d + 1, d + 1) .. out
    n = (n - d) / 36
  end
  return out
end

-- Token minting. A persisted monotonic counter per character plus a three-char
-- random suffix; the suffix is a seatbelt for a SavedVariables rollback (where
-- the counter can go backwards), not the mechanism. The counter is incremented
-- AND persisted before the OPEN is broadcast, so a crash cannot reissue a
-- number. Typical token "1a-7f3" (6 bytes) against up to 18 for the old
-- shortName-random form. PG.NextToken is used when Core provides it, so the
-- counter stays shared and monotonic across modules.
local function nextToken()
  if type(PG.NextToken) == "function" then
    local ok, t = pcall(PG.NextToken)
    t = ok and PG.SafeStr(t) or nil
    if t and t ~= "" then return t end
  end
  local p = PG.db and PG.db.profile
  local seq = 1
  if p then
    seq = (PG.SafeNum(p.seq) or 0) + 1
    p.seq = seq
  end
  return b36(seq) .. "-" .. b36(math.random(0, 46655))
end

-- Wire token validation (CONCURRENCY.md 3.4): opaque to every version,
-- bounded, and never carrying the field separator.
local function validToken(v)
  return type(v) == "string" and v ~= "" and #v <= 24 and not v:find("|", 1, true)
end

-- A lite record's whole purpose is its invitation window, so it dies with it.
local function liteLife(joinSecs)
  local t = (joinSecs or 0) + LITE_TTL_PAD
  if t < LITE_TTL_MIN then t = LITE_TTL_MIN end
  if t > LITE_TTL_MAX then t = LITE_TTL_MAX end
  return t
end

-- live() survives ONLY as a UI predicate: it is no longer a gate on hosting, on
-- an inbound OPEN, or on opening the dialog (CONCURRENCY.md 0.2).
local function live()
  local S = mySession()
  return S ~= nil and S.phase ~= "done"
end

-- LG toasts carry the coin mark (SKIN.md 2.8); plain text when Theme absent
local function toast(text, opts)
  if Theme then text = Theme.Mark("coin") .. " " .. text end
  PG.UI.Toast(text, opts)
end

-- Attribution (CONCURRENCY.md 5.7): while this module holds more than one
-- record its lines name the host, because a player in two audiences cannot
-- otherwise tell which game a line refers to. With a single record the text is
-- exactly what it always was.
local function sname(S)
  if S and S.host and recordCount() > 1 then
    return "Loot Goblins (" .. shortOf(S.host) .. ")"
  end
  return "Loot Goblins"
end

-- Session-attributed status line. Keyed so a burst of status chatter replaces
-- itself in the shared queue instead of pushing the money lines off it.
local function stoast(S, text, opts)
  toast(sname(S) .. ": " .. text, opts or { key = "lg-status" })
end

-- pot amounts inside the window get the coin mark (SKIN.md 2.4)
local function tmoney(g)
  if Theme then return Theme.Money(g) end
  return PG.Money(g)
end

-- FX runner: decoration only - errors are reported and swallowed, so no
-- animation/sound/model problem can ever touch game state or the wire.
local function runFX(fn, arg)
  if not Theme or not fn then return end
  local ok, err = pcall(fn, arg)
  if not ok then geterrorhandler()(err) end
end

-- Every send carries the session's own audience (SCOPE.md 2.2). Only the ONE
-- involved record ever broadcasts - lite records never send at all, which is
-- also why they cannot consume the shared send bucket.
local function broadcast(mtype, ...)
  local S = mySession()
  if not S then return false end
  return PG.Comm.Broadcast(S.scope, "LG", mtype, S.token, ...)
end

-- One ticker for the module, as always (I9). It runs while the registry is
-- non-empty and stops when it empties; no per-session timers exist.
local function ensureTicker()
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

-------------------------------------------------------------------------------
-- Records: the launcher list, invitations, eviction, sweeping.
-------------------------------------------------------------------------------

-- The launcher's Open games list is a VIEW of the lite records, not a second
-- store: one row per record, gone when the record is evicted. Existence-guarded
-- because the list is Launcher-side work and this file must not depend on it.
local function launcherAdd(rec)
  rec.listed = true
  if PG.Launcher and PG.Launcher.AddOpenGame then
    pcall(PG.Launcher.AddOpenGame, {
      game = "LG", host = rec.host, token = rec.token, scope = rec.scope,
      expires = rec.expires, key = rec.key,
    })
  end
end

local function launcherDrop(rec)
  if not rec.listed then return end
  rec.listed = nil
  if PG.Launcher and PG.Launcher.RemoveOpenGame then
    pcall(PG.Launcher.RemoveOpenGame, "LG", rec.host, rec.token)
  end
end

-- A dead session takes its invitation with it (CONCURRENCY.md 5.6 rule 4): a
-- cancelled game must never leave a live countdown popup inviting you into
-- nothing, where clicking Buy in silently does something to no session.
local function dropInvite(rec)
  if rec.askKey then
    local key = rec.askKey
    rec.askKey = nil
    PG.UI.Dismiss(key)
  end
  launcherDrop(rec)
end

-- Eviction is the ONLY place a record leaves the registry, and it ALWAYS
-- poisons the key into `recent`, so a finished session's token can never be
-- resurrected by a replayed or re-broadcast OPEN (CONCURRENCY.md 4.5).
-- keepWindow leaves a finished game's final standings on screen (4.3).
local function evictSession(rec, keepWindow)
  local key = rec.key
  if sessions[key] ~= rec then return end
  sessions[key] = nil
  dropInvite(rec)
  if mine == key then
    mine = nil
    PG.Session.Release("LG", rec.token)
    if win and win.__pgRec == rec and not keepWindow then
      win.__pgRec = nil
      win:Hide()
    end
  end
  if not recent[key] then
    recentQ[#recentQ + 1] = key
    if #recentQ > MAX_RECENT then
      local oldest = table.remove(recentQ, 1)
      recent[oldest] = nil
    end
  end
  recent[key] = GetTime()
end

-- The memory contract (CONCURRENCY.md 7.3), on the module ticker at 2-second
-- granularity: at most 1 + 8 + 16 = 25 entries are ever walked.
local function sweep()
  local now = GetTime()
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      if now > (rec.expires or 0) then evictSession(rec) end
    elseif rec.phase == "done" and (now - (rec.doneAt or now)) > DONE_TTL then
      -- a finished game keeps its window - final standings, Ledger button -
      -- until the user closes it, a new session replaces it, or this fires a
      -- minute later. The podium has long since drained by then, and its
      -- validate closure culls it if it somehow has not (5.8).
      evictSession(rec)
    end
  end
  for key, at in pairs(recent) do
    if (now - at) > RECENT_TTL then
      recent[key] = nil
      for i = #recentQ, 1, -1 do
        if recentQ[i] == key then table.remove(recentQ, i) end
      end
    end
  end
end

-- A session stops being active the instant phase becomes "done" (7.1), in this
-- order: state, then the SEAT (a new game may start immediately), then the
-- invitation and the launcher row. The window keeps its final standings and a
-- queued podium still plays: decoration never holds the seat, and never delays
-- the next game.
local function endSession(text)
  local S = mySession()
  if not S then return end
  S.phase = "done"
  S.roundOpen = false
  S.endText = text
  S.doneAt = GetTime()
  PG.Session.Release("LG", S.token)
  dropInvite(S)
  if win then ui.bar:Stop() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Shared state transitions. The host applies these locally at send time (the
-- section-6 loopback rule); clients apply them on receipt of host broadcasts.
-------------------------------------------------------------------------------

local function applyJoined(name)
  local S = mySession()
  if not S then return end
  -- normal path: the join phase. Resync replays land here too: a desynced
  -- spectator mid-play accepts the replayed JOINED/LEFT stream to repair its
  -- roster (idempotent - a duplicate JOINED never double-adds), which is what
  -- lets it map RESULT patterns to the same names as everybody else.
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
    -- WITHDRAWAL (CONCURRENCY.md 7.2). Leaving a game now stops this client
    -- tracking it: the seat is freed, the window goes, and the record is
    -- evicted immediately rather than lingering as a mirror of a game we are
    -- not in. Nothing is written anywhere - a withdrawal is an abort.
    S.joinAccepted = false
    if win and win.__pgRec == S then win:Hide() end
    evictSession(S)
    return
  end
  RefreshUI()
end

-- dig (optional): the host's roster fingerprint at BEGIN. Absent (a peer that
-- predates the field) degrades to the count-only check.
local function applyBegin(count, pot, rounds, dig)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" then
    -- BEGIN while playing is ignored: totals are NEVER rebuilt once play has
    -- begun, so a replayed BEGIN can never wipe (or re-zero) applied winnings.
    -- The one exception is a client that missed BEGIN entirely (forced
    -- spectator, S.count == nil): it absorbs the original fields so resync
    -- agreement (roster count vs BEGIN count) can be evaluated at all.
    if S.phase == "play" and S.spectator and S.count == nil then
      S.count = count
      S.basePot = pot
      S.rounds = rounds
      S.digest = dig
      RefreshUI()
    end
    return
  end
  S.phase = "play"
  S.count = count
  S.basePot = pot
  S.rounds = rounds
  S.digest = dig
  S.totals = {}
  for _, n in ipairs(S.roster) do S.totals[n] = 0 end
  -- G2 VOUCHING (SCOPE.md 4.4): the roster this client itself watched fill up,
  -- frozen here because the roster cannot change after BEGIN. It is the only
  -- independent source of names at public scope, where nobody in the game need
  -- be in our group or our guild.
  S.vouched = {}
  for _, n in ipairs(S.roster) do S.vouched[n] = true end
  local me = myName()
  local agrees = (#S.roster == count) and (not dig or rosterDigest(S.roster) == dig)
  if not S.isHost and agrees and not (me and S.joined[me]) then
    -- NOT SEATED AT BEGIN (CONCURRENCY.md 7.2/7.3, generalised to every scope):
    -- our mirror agrees with the host in size AND membership and we are not in
    -- it, so our buy-in never landed. There is no reason to track a game we are
    -- not playing - stop, free the seat, and be ready for the next OPEN.
    stoast(S, "your buy-in did not reach the host - you are not in this game.")
    endSession("You are not in this game.")
    evictSession(S)
    return
  end
  if not S.isHost and (#S.roster ~= count
    or (dig and rosterDigest(S.roster) ~= dig)) then
    -- our JOINED/LEFT stream disagrees with the host in size or in membership:
    -- we cannot map the pattern to names, so we spectate (and never touch the
    -- ledger) while asking the host to replay what we missed - resync can
    -- restore us. Setting spectator here is also what lets the repair land:
    -- applyJoined/applyLeft only accept replays for a spectator mid-play.
    S.spectator = true
    stoast(S, "out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxBegin)
end

local function applyRound(r, pot, secs)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  if r < S.r then return end -- stale/late resync replay: never regress the round
  if r ~= S.r then
    S.r = r
    S.myPick = nil
    S.picks = {}
  end
  -- a repeat ROUND for the current r is just a timer refresh (freeze re-open):
  -- locked picks stay locked
  S.roundPot = pot
  S.deadline = GetTime() + secs
  S.roundOpen = true
  ShowWindow()
  if win then ui.bar:Start(secs) end
  RefreshUI()
  runFX(fxRound)
end

local function applyResult(r, pattern, hoardPay, sharePay, carry)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  -- RESYNC IDEMPOTENCY, and the reason the ledger can never double-count: the
  -- END ledger delta is (session winnings - buy-in), and session winnings are
  -- accumulated here from RESULT patterns. A round whose payouts have already
  -- been applied is therefore skipped outright, no matter how often the host
  -- replays it (resync whispers reuse the ORIGINAL RESULT message).
  if S.appliedResults[r] then return end
  -- a replay of a PAST round only accumulates winnings; only a result at or
  -- ahead of the round we are in may touch the live round / reveal state
  local current = r >= S.r
  if current then
    S.roundOpen = false
    S.myPick = nil
    S.lastResult = { r = r, pattern = pattern, hoardPay = hoardPay, sharePay = sharePay, carry = carry }
  end
  local nh, ns = 0, 0
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    if c == "H" then nh = nh + 1 elseif c == "S" then ns = ns + 1 end
  end
  if #pattern == #S.roster then -- never true while our roster is desynced
    S.appliedResults[r] = true
    for i, name in ipairs(S.roster) do
      local c = pattern:sub(i, i)
      if c == "H" then
        S.totals[name] = (S.totals[name] or 0) + hoardPay
      elseif c == "S" then
        S.totals[name] = (S.totals[name] or 0) + sharePay
      end
    end
  elseif not S.isHost and not S.spectator then
    -- the pattern cannot be mapped onto our roster, so our winnings would be
    -- wrong: stop playing (and stop qualifying for the ledger) until resync
    -- repairs the roster, at which point this same RESULT is replayed
    S.spectator = true
    stoast(S, "out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if not current then
    RefreshUI()
    return -- past round: winnings banked, nothing about the live round changes
  end
  if nh + ns == 0 then
    S.lastResultText = "Round " .. r .. ": nobody picked - the whole pot carries over!"
  elseif nh > 0 and hoardPay > 0 then
    S.lastResultText = "Round " .. r .. ": " .. RED .. nh .. " hoarded " .. PG.Money(hoardPay) .. " each|r"
      .. (ns > 0 and ("; " .. ns .. " shared " .. PG.Money(sharePay) .. " each") or "")
  elseif nh > 0 then
    S.lastResultText = "Round " .. r .. ": " .. RED .. nh .. " greedy hoarders got nothing|r"
      .. (ns > 0 and ("; " .. ns .. " shared " .. PG.Money(sharePay) .. " each")
          or " - the pot carries over")
  else
    S.lastResultText = "Round " .. r .. ": everyone shared - " .. PG.Money(sharePay) .. " each"
  end
  ShowWindow()
  if win then ui.bar:Stop() end
  RefreshUI()
  if r == S.r then runFX(fxResult) end
end

local function applyVoid(r)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  -- A voided round pays nothing, so "applied" for it means "seen": the flag
  -- keeps the applied-round run contiguous across the hole a VOID leaves in
  -- the RESULT stream (rounds 1..n each end in exactly one RESULT or one
  -- VOID), and makes a replayed VOID a no-op.
  if S.appliedResults[r] then return end
  S.appliedResults[r] = true
  if r < S.r then return end -- stale replay: the live round is untouched
  S.roundOpen = false
  S.myPick = nil
  S.lastResult = nil
  S.lastResultText = "Round " .. r .. " was voided by the encounter - its pot carries over."
  ShowWindow()
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxVoid)
end

local function applyEnd(dustIdx, dustAmt)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  -- LEDGER INTEGRITY GATE. The ledger is written here, identically on every
  -- client, from locally accumulated winnings - so only a mirror that can
  -- prove it applied EVERY round may write it. Rounds 1..S.rounds each end in
  -- exactly one RESULT or VOID, both of which mark the round applied, so
  -- appliedThrough() == S.rounds is exactly "I missed nothing". Anyone else
  -- (spectator, or a resync that never completed) sits the ledger out rather
  -- than push totals nobody else agrees with into SavedVariables.
  if not S.isHost and not S.spectator and appliedThrough() < (S.rounds or 0) then
    S.spectator = true
    S.syncMissed = true
  end
  if not S.spectator and dustIdx >= 1 and dustAmt > 0 then
    local name = S.roster[dustIdx] -- 1-based index into the sorted roster
    if name then S.totals[name] = (S.totals[name] or 0) + dustAmt end
  end
  local me = myName()
  local myNet
  -- G1 PARTICIPATION (SCOPE.md 4.4, CONCURRENCY.md 0.4). Rows go to
  -- SavedVariables only for a session this client actually SAT AT: seated (a
  -- referee host is not), in the roster, and not spectating. Everyone else -
  -- passers-by, decliners, out-of-sync mirrors - keeps its UI and writes
  -- nothing, which is exactly what lets two concurrent games produce two
  -- disjoint, internally consistent ledgers instead of one divergent one.
  local played = (not S.spectator) and S.seated and me and S.joined[me] and true or false
  if not S.spectator then
    local rows2 = {}
    for _, name in ipairs(S.roster) do
      local netN = (S.totals[name] or 0) - S.buyin
      rows2[name] = netN
      if name == me then myNet = netN end
    end
    if played then
      -- The gates live in the persistence layer: participation, name vouching,
      -- the per-row bound and the zero-sum check are all applied by Commit,
      -- all-or-nothing, and the provenance id carries the HOST now that tokens
      -- are only unique per host (CONCURRENCY.md 3.4).
      PG.Ledger.Commit({
        id = "LG:" .. S.host .. ":" .. S.token,
        game = "LG",
        host = S.host,
        scope = S.scope,
        at = (type(time) == "function") and time() or nil,
        played = true,
        vouch = S.vouched,
        cap = (S.buyin or 0) * #S.roster,
        label = "Loot Goblins",
      }, rows2)
    end
  end
  S.ended = true
  local text = "Game over!"
  if myNet and played then
    text = "Game over - you " .. (myNet >= 0
      and ("came out +" .. PG.Money(myNet)) or ("are down " .. PG.Money(-myNet)))
  elseif S.refereed then
    text = "Game over - you ran this one, so no gold was recorded for you."
  elseif S.syncMissed then
    text = "Game over - you missed part of the game, so no gold was recorded."
  elseif S.spectator then
    text = "Game over - you sat this one out (out of sync). No gold changes."
  end
  stoast(S, text, { priority = "result" })
  ShowWindow()
  endSession(text)
  runFX(fxEnd)
end

local function applyCancel(reason)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local text
  if reason == "few" then
    -- Honest text (CONCURRENCY.md 6.3): nobody is told you are busy, so the
    -- host is told what silence actually means. At guild scope it also names
    -- the one cause a host cannot otherwise diagnose (SCOPE.md 2.4): a rank
    -- that cannot speak in guild chat cannot SEND on the GUILD distribution.
    if S.scope == "guild" and S.isHost then
      text = "Nobody joined. If your guild rank can't speak in guild chat, guild games can't be started from this character."
    else
      text = "Cancelled - not enough players joined. Others may be busy or away."
    end
  elseif reason == "host" then
    text = "Cancelled by the host - no gold changes."
  else
    text = "Cancelled (" .. tostring(reason) .. ") - no gold changes."
  end
  stoast(S, text)
  endSession(text)
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

-- Resync history: the host retains the ordered JOINED/LEFT stream, BEGIN's
-- fields and every round's exact outcome fields (RESULT verbatim, or the VOID
-- that replaced it), so a client with a genuine gap can be healed by replaying
-- precisely what it missed - see hostHandleSyncQ. Nothing is ever re-derived:
-- the replayed fields are the bytes the group already agreed on.
local function hostRecordOp(op, name)
  local S = mySession()
  if not S then return end
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

local function hostRecordTop(r)
  local S = mySession()
  if not S then return end
  if r > S.hist.top then S.hist.top = r end
end

local function hostStartRound(r)
  local S = mySession()
  if not S then return end
  local pot = idiv(S.basePot, S.rounds) + S.carry
  if broadcast("ROUND", r, pot, S.roundSecs) then
    S.carry = 0
    applyRound(r, pot, S.roundSecs)
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
  local k, h, sN = 0, 0, 0
  for i, name in ipairs(S.roster) do
    local p = S.picks[name]
    if p == "H" then
      h = h + 1
      k = k + 1
    elseif p == "S" then
      sN = sN + 1
      k = k + 1
    else
      p = "X"
    end
    chars[i] = p
  end
  local pattern = table.concat(chars)
  local pot = S.roundPot
  local hoardPay, sharePay, carryOut = 0, 0, 0
  if k == 0 then
    carryOut = pot
  elseif h == 0 then
    sharePay = idiv(pot, k) -- k == sN here
    carryOut = pot - sN * sharePay
  elseif h <= math.max(1, idiv(k, 5)) then -- floor(k * 0.2)
    if sN == 0 then
      hoardPay = idiv(pot, h) -- no sharers: hoarders split the whole round pot
      carryOut = pot - h * hoardPay
    else
      hoardPay = idiv(idiv(pot * 4, 5), h) -- floor(floor(pot * 0.8) / h)
      local remainder = pot - h * hoardPay
      sharePay = idiv(remainder, sN)
      carryOut = remainder - sN * sharePay
    end
  else
    -- too many hoarders: they get nothing
    if sN == 0 then
      carryOut = pot
    else
      sharePay = idiv(pot, sN)
      carryOut = pot - sN * sharePay
    end
  end
  local newCarry = S.carry + carryOut
  if not broadcast("RESULT", S.r, pattern, hoardPay, sharePay, newCarry) then
    return -- send refused; the ticker re-resolves next clear tick
  end
  S.carry = newCarry
  -- exact wire fields, retained verbatim for resync replays
  S.hist.results[S.r] = { pattern, hoardPay, sharePay, newCarry }
  hostRecordTop(S.r)
  applyResult(S.r, pattern, hoardPay, sharePay, newCarry)
  hostAdvance(REVEAL_SECS)
end

-- Everyone seated has locked a pick: nobody is waiting on anybody, so the
-- round resolves now instead of burning the rest of the timer. The deadline
-- stays as the fallback for anyone AFK (a missing pick is an X, as always). A
-- resynced player held out of the already-open round never completes the set,
-- so that round quietly falls back to its timer - never an early resolve that
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

-- The early-finish test, in one place: both entry points (a pick landing, and
-- a frozen round re-opening with every pick already in) use exactly the
-- ticker's deadline-branch gating - never while frozen/broken or during an
-- encounter/lockdown.
local function maybeEarlyFinish()
  local S = mySession()
  if not S or S.phase ~= "play" or not S.roundOpen or S.broken or S.frozen then return end
  if not (allPicked() and allClear() and not PG.Comm.Locked()) then return end
  hostResolveRound()
end

local function hostVoidRound()
  local S = mySession()
  if not S then return end
  if broadcast("VOID", S.r) then
    S.carry = S.carry + S.roundPot
    S.hist.voids[S.r] = true -- this round leaves no RESULT: replayed as VOID
    hostRecordTop(S.r)
    S.broken = false
    S.frozen = false
    applyVoid(S.r)
    hostAdvance(VOID_PAUSE_SECS)
  end
end

local function hostReopenRound()
  local S = mySession()
  if not S then return end
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.freezeRemaining or 0))
  -- clients treat a repeat ROUND for a known r as a timer refresh
  if broadcast("ROUND", S.r, S.roundPot, secs) then
    S.frozen = false
    S.deadline = GetTime() + secs
    ShowWindow()
    if win then ui.bar:Start(secs) end
    RefreshUI()
    -- the last pick may have landed DURING the freeze, in which case there is
    -- nobody left to wait for and the re-opened timer would just burn down
    maybeEarlyFinish()
  end
end

local function hostEnd()
  local S = mySession()
  if not S then return end
  if S.endSent then return end -- END is already on the wire; onSent finishes up
  local dustAmt = S.carry or 0
  local dustIdx = -1
  if dustAmt > 0 then
    -- lowest total winnings; strict < keeps the first sorted-roster entry on ties
    local bestVal
    for i, name in ipairs(S.roster) do
      local t = S.totals[name] or 0
      if bestVal == nil or t < bestVal then
        bestVal = t
        dustIdx = i
      end
    end
  end
  -- The ledger applies only once END has actually left the wire: a broadcast
  -- that is merely queued and later dropped by the lockdown aborts via onDrop
  -- with no ledger anywhere instead (all-or-nothing in every branch).
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      -- the record must still be the one we are in: a superseded or withdrawn
      -- session never commits a result on the strength of an old callback
      if mySession() ~= sess or sess.phase ~= "play" then return end
      sess.endPending = nil
      sess.carry = 0
      applyEnd(dustIdx, dustAmt)
    end,
  }, "LG", "END", S.token, dustIdx, dustAmt)
  if ok then S.endSent = true end
end

local function hostCancel(reason)
  local S = mySession()
  if not S then return end
  -- END is already on the wire: clients will write the ledger when it lands, so
  -- the host must complete too - no abort may interleave after END is queued.
  -- (endPending alone is fine: nothing has been submitted yet, so cancelling
  -- there is still all-or-nothing safe.)
  if S.endSent then return end
  -- best effort: if the broadcast is refused, clients fall back to the
  -- heartbeat timeout; either way there is no ledger effect
  broadcast("CANCEL", reason)
  applyCancel(reason)
end

local function hostCloseJoin()
  local S = mySession()
  if not S or S.phase ~= "join" then return end
  local count = #S.roster
  if count < 2 then
    if broadcast("CANCEL", "few") then
      applyCancel("few")
    else
      S.joinDeadline = GetTime() + 2 -- send refused; retry shortly
    end
    return
  end
  local pot = S.buyin * count
  local dig = rosterDigest(S.roster) -- membership, not just size (4 bytes)
  if broadcast("BEGIN", count, pot, S.rounds, dig) then
    -- BEGIN fields for replays
    S.hist.beginCount, S.hist.beginPot, S.hist.beginDigest = count, pot, dig
    applyBegin(count, pot, S.rounds, dig)
    -- seed the carry with the base pot's undistributed remainder
    -- (basePot - rounds * floor(basePot / rounds)) so the game is zero-sum:
    -- it is round 1's carryIn per "roundPot(r) = floor(basePot/rounds) + carryIn"
    S.carry = pot - S.rounds * idiv(pot, S.rounds)
    S.nextRoundAt = GetTime() + BEGIN_PAUSE_SECS
  else
    S.joinDeadline = GetTime() + 2
  end
end

local function hostHandleJoin(sender)
  local S = mySession()
  if not S or S.phase ~= "join" or S.joined[sender] then return end -- duplicate JOINs idempotent
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

local function hostHandlePick(sender, r, p)
  local S = mySession()
  if not S or S.phase ~= "play" or not S.roundOpen or S.broken then return end
  if r ~= S.r or (p ~= "S" and p ~= "H") then return end
  if not S.joined[sender] then return end
  if S.picks[sender] then return end -- first click locks
  S.picks[sender] = p
  RefreshUI()
  maybeEarlyFinish()
end

-- one replay entry; the explicit arity keeps trailing nils out of the wire
local function pushMsg(out, ...)
  local m = { ... }
  m.n = select("#", ...)
  out[#out + 1] = m
end

-- Resync: a client whispered SYNCQ (the phase it has applied, the round
-- through which it has applied every outcome, its roster count). Replay
-- whatever it missed BY WHISPER using the ORIGINAL message types and field
-- layouts - the full JOINED/LEFT stream if its roster count disagrees, BEGIN
-- if its phase trails, every missing RESULT/VOID in round order, then the live
-- ROUND with its real remaining seconds. Nothing missing -> SYNCOK; a delta
-- over SYNC_MAX_REPLAY messages -> SYNCNO (that client spectates the session
-- out, so it never writes a ledger delta).
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
    -- subset roster onto the host roster exactly (each name ends in the state
    -- of its last op), which is what makes the patterns mappable again. A
    -- same-size/different-membership roster is caught by the digest alone.
    for i = 1, #S.hist.ops do
      local op = S.hist.ops[i]
      pushMsg(out, (op.op == "J") and "JOINED" or "LEFT", op.name)
    end
  end
  if S.phase == "play" then
    if phase == "join" then
      -- the roster cannot change after BEGIN, so the live digest IS the BEGIN
      -- one; the fallback only covers a history that predates the field
      pushMsg(out, "BEGIN", S.hist.beginCount or S.count, S.hist.beginPot or S.basePot,
              S.rounds, S.hist.beginDigest or rosterDigest(S.roster))
    end
    for r = rApplied + 1, S.hist.top do
      local res = S.hist.results[r]
      if res then
        pushMsg(out, "RESULT", r, res[1], res[2], res[3], res[4])
      elseif S.hist.voids[r] then
        pushMsg(out, "VOID", r)
      end
    end
    if #out > 0 and S.roundOpen and not S.broken and not S.frozen and S.r >= 1 then
      local remain = math.max(1, math.ceil((S.deadline or now) - now))
      pushMsg(out, "ROUND", S.r, S.roundPot or 0, remain)
    end
  end
  if #out > SYNC_MAX_REPLAY then
    PG.Comm.Whisper(sender, "LG", "SYNCNO", S.token)
    return
  end
  if #out == 0 then
    PG.Comm.Whisper(sender, "LG", "SYNCOK", S.token)
    return
  end
  -- Replay whispers reuse CRITICAL_DROP mtypes, so onDrop cannot tell a
  -- dropped replay from a dropped live broadcast: shield it for a bounded
  -- window while the send queue drains (see REPLAYABLE) so a lockdown-dropped
  -- replay can never abort the session (and its ledger) - the asking client
  -- simply asks again after its cooldown.
  S.syncReplayUntil = now + 30
  for i = 1, #out do
    local m = out[i]
    PG.Comm.Whisper(sender, "LG", m[1], S.token, unpack(m, 2, m.n))
  end
end

-- Hosting is NEVER blocked by another module, by the seat, or by anybody
-- else's session (I4). It refuses for exactly three reasons: this module is
-- already involved in a live session (I3), the audience does not exist, or the
-- OPEN broadcast was refused. The old blanket "a game is already running" line
-- is gone with the model that produced it.
local function hostOpen(buyin, rounds, joinSecs, roundSecs, scope)
  local prev = mySession()
  if prev and prev.phase ~= "done" then
    -- I3 is a scope limit, not a policy: the window, the row pool, the stamp
    -- pool and the Grizzle model are module singletons, so the explanation is
    -- specific and actionable rather than a shrug.
    if prev.isHost then
      stoast(prev, "you're already running a game. Cancel it first, or wait for it to finish.")
    else
      stoast(prev, "you're playing " .. shortOf(prev.host)
        .. "'s game. You can start your own when it's over.")
    end
    ShowWindow()
    return
  end
  local host = myName()
  if not host then return end
  scope = PG.SafeStr(scope) or "group"
  if not PG.LG.SCOPES[scope] then return end
  -- availability is re-checked at the moment Start is pressed: the player can
  -- /gquit or leave the group between opening the dialog and clicking
  local avail, why = PG.Comm.ScopeAvailable(scope)
  if not avail then
    toast("Loot Goblins: " .. (why or "that audience isn't available."))
    return
  end
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  if prev then evictSession(prev, true) end -- the finished record steps aside
  local token = nextToken()
  local key = keyOf(host, token)
  -- broadcast OPEN before constructing the record: submit-time lockdown drops
  -- invoke our onDrop synchronously, which must not see a half-built session.
  -- The scope code is the trailing field, checked (never trusted) on receipt.
  if not PG.Comm.Broadcast(scope, "LG", "OPEN", token, buyin, rounds, joinSecs, code) then
    toast("Loot Goblins: cannot start right now (addon messages are blocked).")
    return
  end
  -- I5 REFEREE HOSTING. If the single round-based seat is held by the other
  -- module, this host runs the game without playing in it: no roster entry, no
  -- buy-in, no pick, no ledger row for itself. ClaimHost cannot refuse, so this
  -- call can never return early and hosting stays unblocked.
  local seated = PG.Session.ClaimHost("LG", token, host)
  local S = {
    kind = "full",
    key = key,
    token = token,
    host = host,
    scope = scope,
    seated = seated and true or false,
    refereed = (not seated) and true or false,
    isHost = true,
    buyin = buyin,
    rounds = rounds,
    joinSecs = joinSecs,
    roundSecs = roundSecs,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    picks = {},
    r = 0,
    carry = 0,
    appliedResults = {},
    hist = { ops = {}, results = {}, voids = {}, top = 0 }, -- resync replay history
    syncAsk = {}, -- per-sender SYNCQ rate limiting
    joinDeadline = GetTime() + joinSecs,
    joinDeadlineDisplay = GetTime() + joinSecs,
    lastHBSent = GetTime(),
  }
  sessions[key] = S
  mine = key
  ensureTicker()
  if seated then
    if broadcast("JOINED", host) then
      hostRecordOp("J", host)
      applyJoined(host) -- host auto-joins
    end
    -- a sync lockdown drop of JOINED (critical) aborts via onDrop above
    if not live() then return end
  else
    stoast(S, "you're playing another game, so you're running this one without playing in it.")
  end
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

local function doPick(p)
  local S = mySession()
  if not S or S.phase ~= "play" or not S.roundOpen then return end
  -- gate l (CONCURRENCY.md 5.2): a local action needs the record we are IN and
  -- a seat in it. A referee host runs the game and makes no pick.
  if not S.seated then return end
  if S.spectator or S.myPick then return end
  if S.syncHoldR == S.r then return end -- resynced mid-round: back in NEXT round
  local me = myName()
  if not me or not S.joined[me] then return end
  if S.isHost then
    S.myPick = p
    hostHandlePick(me, S.r, p)
  else
    -- lock only if the whisper was actually accepted for send, so the UI
    -- never claims a lock the host can never have seen
    if PG.Comm.Whisper(S.host, "LG", "PICK", S.token, S.r, p) then
      S.myPick = p
    end
  end
  RefreshUI()
  if S.myPick == p then runFX(fxPick, p) end
end

-- The FULL-record constructor (I7). Called from the Ask accept callback and the
-- launcher's Join button, and NOWHERE else: an OPEN at any scope - group
-- included now - creates a lite record only, so no session state exists on this
-- client without an explicit click. Decliners and passers-by hold nothing.
local function clientOpen(rec)
  local now = GetTime()
  local S = {
    kind = "full",
    key = rec.key,
    token = rec.token,
    host = rec.host,
    scope = rec.scope,
    seated = true,
    refereed = false,
    isHost = false,
    buyin = rec.cfg.buyin,
    rounds = rec.cfg.rounds,
    joinSecs = rec.cfg.joinSecs,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    picks = {},
    r = 0,
    carry = 0,
    appliedResults = {},
    syncAllClear = allClear(), -- tracks all-clear transitions for resync
    lastHB = now,
    joinAccepted = true, -- provisional; the host's JOINED broadcast confirms
    joinDeadlineDisplay = (rec.openedAt or now) + rec.cfg.joinSecs,
  }
  sessions[S.key] = S -- replaces the lite record under the same key
  mine = S.key
  ensureTicker()
  PG.Comm.Whisper(S.host, "LG", "JOIN", S.token)
  -- a constructor this late converges on the host's roster through the existing
  -- resync protocol (it replays the JOINED stream and BEGIN) - no new machinery
  clientRequestSync()
  ShowWindow()
  if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
end

-- Accepting an invitation. The seat is claimed FIRST: on success every other
-- module withdraws its outstanding invitations through PG.Session.OnChange, and
-- on failure - a genuine race with a JOINED landing from elsewhere - the accept
-- is abandoned and nothing is whispered (CONCURRENCY.md 5.6 rule 3).
local function clientAccept(rec)
  if not rec or sessions[rec.key] ~= rec or rec.kind ~= "lite" then return false end
  local prev = mySession()
  if prev and prev.phase ~= "done" then
    if prev.isHost then
      stoast(prev, "you're running your own game right now - finish it first.")
    else
      stoast(prev, "you're already in " .. shortOf(prev.host) .. "'s game.")
    end
    return false
  end
  if prev then evictSession(prev, true) end -- a finished record steps aside
  if not PG.Session.Claim("LG", rec.token, rec.host) then
    toast("Loot Goblins: you just joined another game - not buying in here.")
    return false
  end
  rec.askKey = nil -- its popup has already closed; nothing to dismiss
  launcherDrop(rec)
  clientOpen(rec)
  return true
end

-- The launcher's Open games list joins through the same path as the popup.
function PG.LG.JoinOpen(key)
  return clientAccept(sessions[tostring(key or "")])
end

-- Read-only view of what this module is overhearing, for the launcher list.
-- Lite records are the store; this is a projection of them (5.10 rule 2).
function PG.LG.OpenGames()
  local out = {}
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      out[#out + 1] = { key = rec.key, host = rec.host, token = rec.token,
                        scope = rec.scope, expires = rec.expires, game = "LG",
                        buyin = rec.cfg.buyin, rounds = rec.cfg.rounds }
    end
  end
  return out
end

-- Busy means the seat is held, and nothing else (CONCURRENCY.md 6.1): hosting
-- is not busy, holding lite records is not busy, a Pull Book is not busy.
local busyToastAt, busyPending = 0, 0

-- One line per minute at group scope however many opens arrive in it; guild and
-- public are silent, because a popular guild starting five games must not
-- produce five lines. With more than one open in the window the line collapses
-- to a count: the launcher list is where the detail lives.
local function listedToast(rec, seated)
  local now = GetTime()
  if (now - busyToastAt) < BUSY_TOAST_EVERY then
    busyPending = busyPending + 1
    return
  end
  -- a pending count older than the throttle window belongs to games that have
  -- long since expired: "4 more games are open" must never be counted from
  -- opens that closed ten minutes ago
  if (now - busyToastAt) > (BUSY_TOAST_EVERY * 2) then busyPending = 0 end
  busyToastAt = now
  local extra = busyPending
  busyPending = 0
  if extra > 0 then
    toast((extra + 1) .. " more games are open - see the Pengyou Games window.",
      { key = "lg-busy" })
  elseif seated then
    toast("Loot Goblins: " .. shortOf(rec.host)
      .. " started a game - you're in another game right now. It's in the Pengyou Games window.",
      { key = "lg-busy" })
  else
    toast("Loot Goblins: " .. shortOf(rec.host)
      .. " started a game - it's in the Pengyou Games window.", { key = "lg-busy" })
  end
end

-- Guild invite budget (SCOPE.md 6.3): at most one popup per sender per minute
-- and three per five minutes. Two hundred guildmates with no budget is a denial
-- of service on the user's screen.
--
-- The counter lives in Widgets, next to AskCount, because it is a budget on the
-- SCREEN and not on a module: kept per module it was spent twice over, so the
-- real ceiling was six popups per five minutes against a spec that says three.
-- The local fallbacks only matter if Widgets somehow predates this API.
local function guildBudgetOK(host)
  if PG.UI.GuildAskOK then return PG.UI.GuildAskOK(host) end
  return true
end

local function guildBudgetSpend(host)
  if PG.UI.GuildAskSpend then PG.UI.GuildAskSpend(host) end
end

-- One invitation per SESSION, keyed by (game, host, token): several are on
-- screen at once and accepting one withdraws the rest. The old per-game
-- "lg-invite" key silently auto-declined the first invitation whenever a second
-- arrived, which is the bug behind "every pending invitation stays visible".
local function raiseInvite(rec)
  launcherAdd(rec) -- the list is the one surface every open reaches
  -- Busy: no popup at all. An Ask you cannot accept is worse than no Ask, and
  -- being busy never means being deaf - the record and the row still exist.
  -- Public never pops. Over ASK_MAX the launcher list is the overflow target.
  -- The guild budget is only TESTED here and is spent below, once the popup is
  -- actually on screen, so a DND or capped-out invitation costs nothing.
  local seated = PG.Session.IsSeated()
  if seated
    or rec.scope == "public"
    or PG.UI.AskCount() >= ASK_MAX
    or (rec.scope == "guild" and not guildBudgetOK(rec.host)) then
    if rec.scope == "group" then listedToast(rec, seated) end
    return
  end
  local acceptLabel = "Buy in"
  if Theme then acceptLabel = Theme.Mark("coin") .. " Buy in" end
  local key = "LG:" .. rec.key
  -- the timeout is the invitation's REMAINING life, so a popup raised late
  -- never outlives its join window
  local secs = math.max(1, (rec.expires or GetTime()) - GetTime())
  local ok = PG.UI.Ask(key,
    shortOf(rec.host) .. " started Loot Goblins - buy-in "
      .. PG.Money(rec.cfg.buyin) .. ", " .. rec.cfg.rounds .. " rounds. Buy in?",
    acceptLabel, "Pass", secs,
    function() clientAccept(rec) end,
    -- Pass, or the countdown running out, takes the popup down - and askKey has
    -- to come down with it. A stale askKey makes the record claim a popup it no
    -- longer has, and row 6 of the OPEN table picks its eviction victim by
    -- exactly that field: eight passed-on invitations used to leave eight
    -- records all claiming popups, after which the next OPEN was discarded
    -- outright. The identity guard stops a late callback resurrecting the field
    -- on a record that has since been evicted or replaced.
    function() if sessions[rec.key] == rec then rec.askKey = nil end end,
    "LG")
  if ok then
    rec.askKey = key
    -- spent only on a popup that actually appeared: PG.UI.Ask's DND branch runs
    -- onDecline and returns false, and a full screen returns false too
    if rec.scope == "guild" then guildBudgetSpend(rec.host) end
  end
end

-- SUPERSESSION (CONCURRENCY.md 4.3): the newest OPEN from a given host replaces
-- that host's previous session on every client, unconditionally, at any age.
-- This is deterministic and client-independent without any comparison, because
-- the host is the sole authority for its own sessions - if it is sending a new
-- OPEN, its previous one is over whatever any client still believes. It is the
-- fix for a client stuck at phase == "play" that missed END and was silently
-- excluded from every future game.
local function supersedeHost(host)
  for _, rec in pairs(sessions) do
    if rec.host == host then
      if rec.kind == "lite" then
        evictSession(rec) -- silently: no toast, its popup just goes
      elseif rec.phase == "done" then
        evictSession(rec, true) -- keep the final standings on screen
      else
        -- we are seated in it; we can never HOST it, because our own OPEN is
        -- dropped before it reaches here. Never auto-seat into the new game:
        -- the replacement raises a normal invitation we may decline.
        stoast(rec, shortOf(host)
          .. " started a new game - your previous game is over. No gold changes.",
          { priority = "result" })
        endSession("The host started a new game. No gold changes.")
        evictSession(rec)
      end
    end
  end
end

-- The inbound OPEN decision table (CONCURRENCY.md 4.2), evaluated in order.
-- There is no collision window and no arbitration between hosts: two hosts
-- pressing Start in the same second produce two games, two lite records and two
-- invitations, and the human picks. No client silently elects a winner, so no
-- two clients can elect differently.
local function onOpen(token, sender, scope, f1, f2, f3, f4)
  -- row 2: malformed fields, bad token, declared scope != delivered scope, or
  -- an audience this game does not play to
  local buyin = num(f1, 1, 100000)
  local rounds = num(f2, 1, 20)
  local joinSecs = num(f3, 5, 600)
  if not (buyin and rounds and joinSecs) then return end
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f4))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end -- an OPEN must never arrive by whisper
  if not PG.LG.SCOPES[scope] then return end
  -- row 1: our own OPEN. Comm already refuses self-delivery; belt and braces.
  local me = myName()
  if not me or sender == me then return end
  local key = keyOf(sender, token)
  -- row 3: a finished session's key stays poisoned, so its token can never be
  -- resurrected by a replayed or re-broadcast OPEN
  local died = recent[key]
  if died and (GetTime() - died) < RECENT_TTL then return end
  -- row 4: idempotent. A retransmitted OPEN refreshes the invitation window and
  -- raises no second popup and no toast.
  local rec = sessions[key]
  if rec then
    if rec.kind == "lite" then rec.expires = GetTime() + liteLife(joinSecs) end
    return
  end
  -- row 5: same host, different token
  supersedeHost(sender)
  -- row 6: at the cap, the oldest lite record with no popup ON SCREEN goes.
  -- Liveness is PG.UI.IsAsking, not the cached askKey: the cached field is the
  -- record's belief and the popup frame is the fact. If every record still
  -- claims one, the oldest goes anyway - its popup comes down with it through
  -- dropInvite - because dropping the new OPEN outright would leave it with no
  -- record, no popup AND no launcher row, and a launcher row with no record
  -- behind it is unjoinable (JoinOpen resolves through sessions[key]).
  local nLite, oldest, oldestAny = 0, nil, nil
  for _, r in pairs(sessions) do
    if r.kind == "lite" then
      nLite = nLite + 1
      local asking = r.askKey ~= nil
      if PG.UI.IsAsking then asking = PG.UI.IsAsking(r.askKey) end
      if not asking and (not oldest or (r.openedAt or 0) < (oldest.openedAt or 0)) then
        oldest = r
      end
      if not oldestAny or (r.openedAt or 0) < (oldestAny.openedAt or 0) then
        oldestAny = r
      end
    end
  end
  if nLite >= MAX_LITE then
    local victim = oldest or oldestAny
    if not victim then return end
    evictSession(victim)
  end
  -- row 7: a lite record. One small table: no roster, no totals, no picks, no
  -- history, no ticker, no frame, and nothing it can ever send.
  local now = GetTime()
  rec = {
    kind = "lite",
    key = key,
    token = token,
    host = sender,
    scope = scope,
    cfg = { buyin = buyin, rounds = rounds, joinSecs = joinSecs },
    openedAt = now,
    expires = now + liteLife(joinSecs),
  }
  sessions[key] = rec
  ensureTicker()
  raiseInvite(rec)
end

local function clientHostDead()
  stoast(mySession(), "lost contact with the host - game abandoned, no gold changes.")
  endSession("Abandoned - the host stopped responding. No gold changes.")
end

-- Highest round R such that every round 1..R has been applied locally. A
-- voided round counts (it pays nothing and produces no RESULT), so this is
-- exactly "the outcomes I hold with no holes in them".
appliedThrough = function()
  local S = mySession()
  if not S then return 0 end
  local r = 0
  while S.appliedResults[r + 1] do r = r + 1 end
  return r
end

-- Resync request: ask the host to replay whatever we missed (loading screens,
-- encounter comms gaps). At most one SYNCQ per SYNC_COOLDOWN; a refused or
-- cooling-down request stays pending and the ticker retries it once clear.
-- Never sent by the host, after SYNCNO, or for a finished session.
clientRequestSync = function()
  local S = mySession()
  if not S or S.isHost or S.phase == "done" or S.syncDead then return end
  local now = GetTime()
  if now - (S.lastSyncQ or 0) < SYNC_COOLDOWN or PG.Comm.Locked() then
    S.syncNeeded = true
    return
  end
  -- Report the phase we have actually APPLIED, not the one we forced ourselves
  -- into: a client that never saw BEGIN (S.count == nil) flipped itself to
  -- "play" the moment a round message arrived, but it still needs BEGIN
  -- replayed - that is the message carrying the roster count we must agree on.
  local phase = S.count and "play" or "join"
  -- the digest rides along so the host can spot a same-size/wrong-membership
  -- roster, which a count comparison alone can never see
  if PG.Comm.Whisper(S.host, "LG", "SYNCQ", S.token, phase, appliedThrough(),
                     #S.roster, rosterDigest(S.roster)) then
    S.lastSyncQ = now
    S.syncNeeded = false
  else
    S.syncNeeded = true
  end
end

-- A resynced spectator rejoins once its mirror agrees with the host again:
-- roster count matches BEGIN's count and every completed round is applied. It
-- plays from the NEXT round (syncHoldR blocks the round already open at heal
-- time) and never scores retroactively - the replayed patterns carry X for
-- every round it missed, worth nothing. Its winnings are therefore identical
-- to everyone else's, which is what makes it safe to write the END ledger.
local function maybeClearSpectator()
  local S = mySession()
  if not S or S.isHost or not S.spectator or S.syncDead then return end
  if S.phase ~= "play" or not S.count then return end
  if #S.roster ~= S.count then return end
  -- size agreement is not membership agreement: without this a spectator heals
  -- onto a same-count/wrong-member roster and writes the ledger for the wrong
  -- players - the very bug the digest exists to catch, one hop later
  if S.digest and rosterDigest(S.roster) ~= S.digest then return end
  local need = S.roundOpen and (S.r - 1) or S.r
  if need < 0 then need = 0 end
  if appliedThrough() < need then return end
  -- The same test applyBegin makes, one hop later: a mirror that converges on
  -- the host's roster and finds itself absent was never in this game (its JOIN
  -- was lost, or the host closed the window without it). It stops here rather
  -- than holding the seat and watching a game it cannot play (CONCURRENCY.md
  -- 7.2/7.3) - and the seat matters, because the next invitation needs it.
  local me = myName()
  if not (me and S.joined[me]) then
    stoast(S, "your buy-in did not reach the host - you are not in this game.")
    endSession("You are not in this game.")
    evictSession(S)
    return
  end
  S.spectator = false
  if S.roundOpen and S.r >= 1 then S.syncHoldR = S.r end
  stoast(S, "back in sync - you are back in the game.")
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

-- Messages split by AUTHOR, not by a fallback between lookups: a peer who hosts
-- a session whose token happens to equal ours can never have its whisper
-- resolve against our hosted record, and vice versa.
local HOST_AUTHORED = {
  HB = true, JOINED = true, LEFT = true, BEGIN = true, ROUND = true,
  RESULT = true, VOID = true, END = true, CANCEL = true,
  SYNCOK = true, SYNCNO = true,
}
local CLIENT_AUTHORED = { JOIN = true, UNJOIN = true, PICK = true, SYNCQ = true }

-- Gate h: a lite record is an invitation, not a mirror. It accepts exactly the
-- messages that tell it to stop existing (a game we did not join has begun,
-- been cancelled or finished - we have no reason to know it exists any more)
-- and the heartbeat that keeps it alive. Nothing else, ever.
local function liteObserve(rec, mtype)
  if mtype == "HB" then
    -- a heartbeat keeps a still-open invitation alive, but never past the
    -- clamp: a record whose BEGIN we missed must still age out on its own
    local cap = (rec.openedAt or GetTime()) + LITE_TTL_MAX
    local want = GetTime() + LITE_TTL_MIN
    if want > cap then want = cap end
    if want > (rec.expires or 0) then rec.expires = want end
  elseif mtype == "BEGIN" or mtype == "CANCEL" or mtype == "END" then
    evictSession(rec)
  end
end

-- The inbound gate order of CONCURRENCY.md 5.2, applied verbatim. Gates a-e
-- (version, distribution -> scope, accept/trust, rate limit, module route) are
-- Comm's; f-l are here, and nothing before a gate may write state.
local function onComm(mtype, token, sender, scope, f1, f2, f3, f4, f5)
  if not validToken(token) then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3, f4) end

  local rec
  if HOST_AUTHORED[mtype] then
    -- gate g: identity is the pair. This single lookup replaces the old
    -- `token ~= S.token` test and is what makes two sessions non-interfering:
    -- it ROUTES a message instead of merely filtering it, so a message for a
    -- session we know about but are not in is dropped without also deafening
    -- us to the session we are in.
    rec = sessions[keyOf(sender, token)]
  elseif CLIENT_AUTHORED[mtype] then
    local m = mySession()
    if m and m.isHost and m.token == token and scope == "private" then rec = m end
  else
    return -- gate f: unknown mtype
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype) end -- gate h
  if rec.phase == "done" then return end                        -- gate k
  -- gate i: scope equality. This is what stops someone re-broadcasting a live
  -- guild session's token in party chat; "private" is exempt because resync
  -- replays of BEGIN/RESULT/ROUND legitimately arrive by whisper.
  if scope ~= "private" and scope ~= rec.scope then return end
  local S = rec
  if S.isHost then
    -- gate j, client-authored: PICK and UNJOIN must come from a seated player
    if mtype == "JOIN" then
      hostHandleJoin(sender)
    elseif mtype == "UNJOIN" then
      if S.joined[sender] then hostHandleUnjoin(sender) end
    elseif mtype == "PICK" then
      if S.joined[sender] then hostHandlePick(sender, num(f1, 1, 20), PG.SafeStr(f2)) end
    elseif mtype == "SYNCQ" then
      hostHandleSyncQ(sender, PG.SafeStr(f1), num(f2, 0, 20), num(f3, 0, 40),
                      PG.SafeStr(f4))
    end
    return
  end
  -- gate j, host-authored: guaranteed by gate g's key - sender IS rec.host
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  S.hostQuiet = nil    -- ... and ends a wide-scope quiet spell (SCOPE.md 6.2)
  if S.phase == "join"
    and (mtype == "ROUND" or mtype == "RESULT" or mtype == "VOID" or mtype == "END") then
    -- we missed BEGIN entirely: spectate for now (no ledger) and ask the host
    -- to replay what we missed - resync can fully restore us (roster stream +
    -- BEGIN + outcomes), unlike the old permanent sit-out
    S.phase = "play"
    S.spectator = true
    stoast(S, "out of sync with the host - resyncing...")
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
    local count = num(f1, 2, 40)
    local pot = num(f2, 0, MAX_GOLD)
    local rounds = num(f3, 1, 20)
    -- optional trailing field: absent means a peer without it (count-only
    -- check, exactly as before); present but malformed drops the message
    local dig = PG.SafeStr(f4)
    if count and pot and rounds and (dig == nil or isDigest(dig)) then
      applyBegin(count, pot, rounds, dig)
    end
  elseif mtype == "CANCEL" then
    applyCancel(PG.SafeStr(f1) or "?")
  elseif mtype == "ROUND" then
    local r = num(f1, 1, 20)
    local pot = num(f2, 0, MAX_GOLD)
    local secs = num(f3, 1, 600)
    if r and pot and secs then
      if r > S.r + 1 then clientRequestSync() end -- unexpected round: we missed traffic
      applyRound(r, pot, secs)
    end
  elseif mtype == "RESULT" then
    local r = num(f1, 1, 20)
    local pattern = PG.SafeStr(f2)
    local hoardPay = num(f3, 0, MAX_GOLD)
    local sharePay = num(f4, 0, MAX_GOLD)
    local carry = num(f5, 0, MAX_GOLD)
    if r and pattern and pattern ~= "" and hoardPay and sharePay and carry then
      if r > S.r then clientRequestSync() end -- result for a round we never saw open
      applyResult(r, pattern, hoardPay, sharePay, carry)
    end
  elseif mtype == "VOID" then
    local r = num(f1, 1, 20)
    if r then applyVoid(r) end
  elseif mtype == "END" then
    local dustIdx = num(f1, -1, 40)
    local dustAmt = num(f2, 0, MAX_GOLD)
    if dustIdx and dustAmt then applyEnd(dustIdx, dustAmt) end
  elseif mtype == "SYNCOK" then
    S.syncNeeded = false -- host confirms we missed nothing
  elseif mtype == "SYNCNO" then
    -- the delta is too large to replay: spectator locks for this session, so
    -- this client sits out both the picks and the END ledger
    if not S.syncDead then
      S.syncDead = true
      S.syncNeeded = false
      if not S.spectator then
        S.spectator = true
        stoast(S, "too far out of sync to catch up - spectating this game.")
      end
      RefreshUI()
    end
  end
  maybeClearSpectator()
end

-- An OUTGOING message of ours was permanently dropped by the comms lockdown.
-- For the host, losing a state-bearing broadcast desyncs every client with no
-- legal way to repair it mid-lockdown, so the session dies locally with no
-- ledger effect; clients notice via the 35s heartbeat timeout (all-or-nothing
-- holds). This only happens in the rare queued-then-lockdown race: normal
-- interruptions are handled by the freeze/VOID flow before anything is sent.
-- JOINED/LEFT are critical too: a lost roster broadcast leaves the host with
-- a roster no client shares, so BEGIN's count check would lock every client
-- to spectator and END would apply the ledger on the host alone. The sync
-- messages (SYNCQ/SYNCOK/SYNCNO) are deliberately NOT critical: a dropped one
-- just means the client asks again after its cooldown.
local CRITICAL_DROP = {
  OPEN = true, JOINED = true, LEFT = true, BEGIN = true,
  ROUND = true, RESULT = true, VOID = true, END = true,
}

-- Resync replay whispers reuse the original mtypes above, so onDrop cannot
-- tell a dropped replay whisper from a dropped live broadcast. While a replay
-- may still be draining from the send queue (the syncReplayUntil window) a
-- drop of one of these must NOT abort the game and its pending ledger: the
-- asking client simply retries, and even a live broadcast lost in that window
-- now self-heals through the same resync path once the lockdown clears.
local REPLAYABLE = {
  JOINED = true, LEFT = true, BEGIN = true, RESULT = true, VOID = true, ROUND = true,
}

-- The send queue and its 10-token bucket are shared by the whole addon, so a
-- drop must say WHICH session lost the message: with two live sessions an
-- unqualified drop is one session killing another (CONCURRENCY.md 5.5). A drop
-- for a foreign or unknown token is ignored.
local function onDrop(mtype, token)
  local S = mySession()
  if not (S and S.isHost and S.phase ~= "done") then return end
  if S.token ~= token then return end
  if not CRITICAL_DROP[mtype] then return end
  if REPLAYABLE[mtype] and S.syncReplayUntil and GetTime() < S.syncReplayUntil then return end
  stoast(S, "game aborted - addon messages were blocked mid-send. No gold changes.")
  endSession("Aborted - addon messages were blocked. No gold changes.")
end

-------------------------------------------------------------------------------
-- Safety transitions. Encounter/restriction breaks the open round (VOID once
-- clear); ready check / countdown merely freezes its timer. Plain combat does
-- NOTHING: messaging stays legal there, so the game just keeps running.
-- Resumption is driven by the ticker once every flag is clear again; clients
-- that missed traffic during a genuine gap ask the host to replay it (SYNCQ).
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
  local S = mySession()
  if not S or S.phase == "done" then return end
  -- plain combat neither freezes the round nor discards picks, and it can
  -- never change allClear() (so no resync bookkeeping is missed by returning
  -- here); without this every trash pull would churn the round
  if trigger == "COMBAT_ON" or trigger == "COMBAT_OFF" then return end
  local isOn = trigger:match("_ON$") ~= nil
  if not S.isHost then
    if trigger == "ENCOUNTER_ON" then
      S.myPick = nil -- discard pending pick state; the host will void this round
    end
    -- resync trigger: the session just emerged from a safety interruption
    -- (allClear() transitioned false -> true), which is exactly where messages
    -- go missing; ask the host what we missed
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
  elseif S.phase == "play" and S.roundOpen then
    if trigger == "ENCOUNTER_ON" or trigger == "RESTRICT_ON" then
      S.broken = true -- this round is dead; VOID goes out after the encounter
      S.frozen = false
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

-- One tick of the session this client is in. Split out of onTick so the sweep
-- (which must run whether or not we are in a session) is not entangled with the
-- early returns below.
local function serviceMine(S, now)
  if S.isHost then
    -- Scope-aware host abort (SCOPE.md 6.1): left the party at group scope,
    -- /gquit at guild scope, the public channel gone for 8 continuous seconds
    -- (the grace absorbs loading screens, which drop a temporary channel every
    -- time). The session is immutable in its scope: it aborts, never migrates.
    local ok, why = PG.Comm.ScopeAvailable(S.scope, 8)
    if not ok then
      why = why or "the audience is gone."
      stoast(S, why .. " Game abandoned, no gold changes.", { priority = "result" })
      endSession("Abandoned - " .. why .. " No gold changes.")
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
    elseif S.scope ~= "group" then
      -- Wide scope: the host can be pulling a boss while we stand in a city, so
      -- OUR safety state proves nothing about theirs (SCOPE.md 6.2). Silence is
      -- "quiet, and probably in an encounter" for 150s - no state change, no
      -- spectator flip, no ledger effect - and only then are they dead.
      local quiet = now - (S.lastHB or now)
      if quiet > HB_GIVEUP_WIDE then
        clientHostDead()
        return
      elseif quiet > HB_QUIET_WIDE then
        if not S.hostQuiet then
          S.hostQuiet = true
          RefreshUI()
        end
        if now - (S.quietSyncAt or 0) > 60 then
          S.quietSyncAt = now
          clientRequestSync() -- heal the instant they come back
        end
      end
    elseif now - (S.lastHB or now) > HB_TIMEOUT then
      clientHostDead()
      return
    end
    -- pending resync request (cooling down, or a refused send): retry once clear
    if S.syncNeeded and allClear() then clientRequestSync() end
  end
end

onTick = function()
  tickN = tickN + 1
  -- every 4th tick (2s): lite records past their invitation window, finished
  -- records past DONE_TTL, poisoned keys past RECENT_TTL. Bounded at 25 entries.
  if tickN % 4 == 0 then sweep() end
  local S = mySession()
  if S and S.phase ~= "done" then
    serviceMine(S, GetTime())
    if win and win:IsShown() then RefreshUI() end
  end
  -- the ticker exists only while the registry does
  if not next(sessions) then stopTicker() end
end

-------------------------------------------------------------------------------
-- Reveal FX and goblin reactions (SKIN.md 2.4/2.5, choreography table 3).
-- Pure decoration: groups are built ONCE with the window and replayed via
-- Restart; every group/region is registered into the Theme OnHide contract so
-- a Safety hide Stop()s and hides everything instantly. Text state is always
-- final BEFORE any of this plays - a player with all FX failed loses nothing.
--
-- Round and session results are presented by the SHARED REVEAL STAGE
-- (REVEAL.md 6.1/6.2): fxResult builds a payload and hands it to Theme.Reveal
-- (per-round - a missed one is superseded by the next round, so it is dropped
-- rather than replayed), fxEnd hands its podium to Theme.RevealQueue (it must
-- eventually show, so it waits out an encounter/ready-check instead). The
-- stage self-gates on all five Safety flags, plays only over a shown window,
-- and never touches game state: every string below is read from state the
-- appliers already settled, and nothing here writes anything.
-------------------------------------------------------------------------------

-- guarded AnimationGroup primitives (decor only; nil on failure)
local function newGroup(region)
  local ok, g = pcall(region.CreateAnimationGroup, region)
  if ok and g then return g end
  return nil
end

local function newAnim(g, kind)
  local ok, a = pcall(g.CreateAnimation, g, kind)
  if ok and a then return a end
  return nil
end

local function setScaleRange(a, fx, fy, tx, ty)
  if not a then return end
  if pcall(a.SetScaleFrom, a, fx, fy) then
    pcall(a.SetScaleTo, a, tx, ty)
  else
    pcall(a.SetFromScale, a, fx, fy)
    pcall(a.SetToScale, a, tx, ty)
  end
end

local function setAlphaRange(a, from, to)
  if not a then return end
  pcall(a.SetFromAlpha, a, from)
  pcall(a.SetToAlpha, a, to)
end

local function restartGroup(g)
  if not g then return end
  if not pcall(g.Restart, g) then
    pcall(g.Stop, g)
    pcall(g.Play, g)
  end
end

-- Builds the A6 stamp pool and the A9 END sparkles. Called once from
-- ensureWindow after the chest (win.__pgFXOrigin) exists. The A3 glow, A4
-- starburst and A5 coin shower are NOT built here any more: the shared reveal
-- stage owns the result moment (REVEAL.md 7) and would only cover them.
buildRevealFX = function()
  if not Theme or not win then return end
  local fx = win.__pgFX or win
  local origin = win.__pgFXOrigin or win

  -- A6 hoarder stamps: pool of 8 red X marks. Without the atlas there is no
  -- fallback texture - the LOSS-colored "HOARD +x" annotation carries meaning.
  if Theme.Mark("redx") ~= "" then
    stampPool = {}
    for i = 1, 8 do
      local t = fx:CreateTexture(nil, "OVERLAY")
      t:SetSize(26, 26)
      Theme.Tex(t, "redx")
      pcall(t.SetRotation, t, -0.14)
      t:Hide()
      local g = newGroup(t)
      if g then
        local sc = newAnim(g, "Scale")
        if sc then
          setScaleRange(sc, 2.2, 2.2, 1, 1)
          sc:SetDuration(0.18)
          sc:SetOrder(1)
          pcall(sc.SetSmoothing, sc, "IN")
          pcall(sc.SetStartDelay, sc, 0.06 * (i - 1)) -- stagger baked at build
        end
        local al = newAnim(g, "Alpha")
        if al then
          setAlphaRange(al, 0, 1)
          al:SetDuration(0.12)
          al:SetOrder(1)
          pcall(al.SetStartDelay, al, 0.06 * (i - 1))
        end
        pcall(g.SetToFinalAlpha, g, true) -- the stamp persists after the slam
        Theme.RegisterGroup(win, g)
      end
      Theme.RegisterRegion(win, t)
      stampPool[i] = { tex = t, group = g }
    end
  end

  -- A9 END sparkles: two stars in one bouncing frame; a 4 s gen-checked
  -- timer stops the loop (and OnHide Stop always can)
  local okS, sf = pcall(CreateFrame, "Frame", nil, fx)
  if okS and sf then
    sf:SetSize(64, 64)
    sf:SetPoint("CENTER", origin, "CENTER", 0, 0)
    local t1 = sf:CreateTexture(nil, "OVERLAY")
    t1:SetSize(20, 20)
    t1:SetPoint("CENTER", origin, "TOPLEFT", 2, -2)
    Theme.Tex(t1, "star")
    pcall(t1.SetBlendMode, t1, "ADD")
    local t2 = sf:CreateTexture(nil, "OVERLAY")
    t2:SetSize(20, 20)
    t2:SetPoint("CENTER", origin, "BOTTOMRIGHT", -2, 2)
    Theme.Tex(t2, "star")
    pcall(t2.SetBlendMode, t2, "ADD")
    local g = newGroup(sf)
    if g then
      local a = newAnim(g, "Alpha")
      if a then
        setAlphaRange(a, 0.15, 0.75)
        a:SetDuration(0.5)
        a:SetOrder(1)
        pcall(a.SetSmoothing, a, "IN_OUT")
      end
      pcall(g.SetLooping, g, "BOUNCE")
      Theme.RegisterGroup(win, g)
      sparkGroup = g
    end
    Theme.RegisterRegion(win, sf)
    sf:Hide()
    sparkFrame = sf
  end
end

hideStamps = function()
  if not stampPool then return end
  for i = 1, #stampPool do
    local sp = stampPool[i]
    if sp.group then pcall(sp.group.Stop, sp.group) end
    sp.tex:Hide()
  end
end

placeStamps = function(pattern)
  if not stampPool or not win then return end
  hideStamps()
  local limit = #pattern
  -- last visible row is the "... and more" line, a referee host has pushed the
  -- roster down by one, and a hoisted local-player row (F6) no longer holds
  -- the roster entry its index says it does - stop before all three
  if limit + rowOffset > MAX_ROWS then
    limit = MAX_ROWS - 1 - rowOffset
    if rowLifted then limit = limit - 1 end
  end
  local used = 0
  for i = 1, limit do
    if pattern:sub(i, i) == "H" then
      used = used + 1
      if used > #stampPool then break end -- hoarders 9+: text-only LOSS color
      local sp = stampPool[used]
      sp.tex:ClearAllPoints()
      sp.tex:SetPoint("CENTER", rowAt(i + rowOffset), "LEFT", -2, 0)
      if sp.group then
        sp.tex:SetAlpha(0) -- invisible through the stagger; the slam raises it
        sp.tex:Show()
        restartGroup(sp.group)
      else
        sp.tex:SetAlpha(1)
        sp.tex:Show()
      end
    end
  end
end

-- Window first shows for a session: wave hello (once per token). Also clears
-- stamps a re-used window may still be showing from the previous session.
fxGreet = function()
  hideStamps()
  if npc then npc:Emote("greet") end
  Theme.Sound("greet")
end

-- Join phase: nod + chest pulse per join (1/s), coin clink for others (1/2s),
-- lock-in confirmation for self.
fxJoined = function(name)
  if not (win and win:IsShown()) then return end
  local now = GetTime()
  if now - lastNodAt >= 1 then
    lastNodAt = now
    if npc then npc:Emote("nod") end
    if ui.chest then Theme.Pulse(ui.chest) end
  end
  if name == myName() then
    Theme.Sound("coinlock")
  elseif now - lastClinkAt >= 2 then
    lastClinkAt = now
    Theme.Sound("potclink")
  end
end

-- Buy-in closes: banner + stamp sound + the goblin gets excited.
fxBegin = function()
  if not (win and win:IsShown()) then return end
  Theme.Banner(win, "BUY-IN CLOSED", "LG")
  Theme.Sound("stamp")
  Theme.After(win, 0.2, function()
    if npc then npc:Emote("excited") end
  end)
end

-- Round opens: stale stamps go, the goblin talks up the round (loops).
fxRound = function()
  if not (win and win:IsShown()) then return end
  hideStamps()
  if npc then npc:Emote("talk") end
end

-- Local pick locked: button pop + nod. Never touches the timer bar or text.
fxPick = function(p)
  if not (win and win:IsShown()) then return end
  local btn = (p == "S") and ui.shareBtn or ui.hoardBtn
  if btn then Theme.Pulse(btn) end
  if npc then npc:Emote("nod") end
  Theme.Sound("click")
end

-- The stage shows 9 result rows plus a "... and N more" line once a payload
-- carries more than 10 (REVEAL.md 2.3), which on a 20-man roster can swallow
-- the local player's row - and "your delta emphasized" is the point of it.
-- Move that one row up into the last visible slot; everyone else keeps their
-- relative order and the collapse line still counts the same rows.
local RV_VISIBLE = 9

local function hoistPersonal(list)
  if #list <= RV_VISIBLE + 1 then return list end -- all rows fit as they are
  for i = RV_VISIBLE + 1, #list do
    if list[i].personal then
      table.insert(list, RV_VISIBLE, table.remove(list, i))
      return list
    end
  end
  return list
end

-- Per-player payout rows for the round reveal, in roster order. Empty whenever
-- the pattern cannot be mapped onto our roster (spectator / desync) - exactly
-- the case where RefreshUI also refuses to annotate the roster, so the stage
-- shows the headline alone rather than invent payouts nobody agrees with.
local function resultRows(lr)
  local list = {}
  local S = mySession()
  if not S or S.spectator or #lr.pattern ~= #S.roster then return list end
  local me = myName()
  for i, name in ipairs(S.roster) do
    local c = lr.pattern:sub(i, i)
    local row
    if c == "H" then
      row = { text = name .. "  HOARD +" .. PG.Money(lr.hoardPay), role = "loss" }
    elseif c == "S" then
      row = { text = name .. "  share +" .. PG.Money(lr.sharePay), role = "win" }
    else
      row = { text = name .. "  no pick", role = "fade" }
    end
    row.personal = (name == me)
    list[#list + 1] = row
  end
  return hoistPersonal(list)
end

-- The money moment (SKIN.md 2.5, REVEAL.md 6.1). Timeline zero = RefreshUI has
-- already set every final string; the stage decorates, never precedes, the
-- information. Reveal (not RevealQueue): a round result that could not play is
-- superseded by the next round, and a late replay would be a lie.
fxResult = function()
  local S = mySession()
  if not (win and win:IsShown() and S and S.lastResult) then return end
  local lr = S.lastResult
  local nh, ns = 0, 0
  for i = 1, #lr.pattern do
    local ch = lr.pattern:sub(i, i)
    if ch == "H" then nh = nh + 1 elseif ch == "S" then ns = ns + 1 end
  end
  -- t=0.1: red stamps still slam onto the hoarder rows. They are the one
  -- reveal artifact that OUTLIVES the stage - the roster keeps its marks after
  -- the scrim fades - and they land even when the stage declines to play.
  if nh > 0 and not S.spectator and #lr.pattern == #S.roster then
    local pattern = lr.pattern
    Theme.After(win, 0.1, function() placeStamps(pattern) end)
  end
  -- the headline the banner used to carry, now the stage's slam title
  local title
  if nh > 0 and lr.hoardPay == 0 then
    title = "GREED PUNISHED"
  elseif nh == 0 and ns > 0 then
    title = "EVERYONE SHARED"
  else
    title = "ROUND " .. lr.r
  end
  local paid = (lr.hoardPay > 0 or lr.sharePay > 0)
  local sess = S
  Theme.Reveal({
    game = "LG",
    -- OWNERSHIP (CONCURRENCY.md 5.8 rule 2): the payload belongs to ONE record.
    -- A round moment whose session was superseded, withdrawn or swept between
    -- the applier and the stage is culled instead of playing over whatever
    -- window is up by then.
    validate = function() return sessions[sess.key] == sess end,
    -- PRECEDENCE (rule 3): when a seated session and a refereed one both want
    -- the stage, the one the player is actually PLAYING wins. S.seated is the
    -- record's own copy of that fact and, unlike PG.Session.Holds, it is still
    -- true at END - where the seat was released a few lines before the podium.
    priority = sess.seated and 1 or 0,
    anchor = { mode = "window", host = win },
    title = title,
    subtitle = "Round " .. lr.r .. " of " .. (S.rounds or "?") .. " - pot "
      .. PG.Money(S.roundPot or 0),
    rows = resultRows(lr),
    marquee = (nh > 0)
      and (nh .. (nh == 1 and " HOARDER EXPOSED" or " HOARDERS EXPOSED")) or nil,
    -- same coin budget the A5 shower used: 10 on a share payout, 6 on a
    -- hoard-only payout, none when the whole pot carried over
    burst = paid and "coins" or "none",
    burstCount = (lr.sharePay > 0) and 10 or 6,
    -- sounds are default-off and self-gated inside Theme.Sound
    sound = paid and "coins" or nil,
    burstSound = (nh > 0 and lr.hoardPay > 0) and "laugh"
      or ((nh == 0 and lr.sharePay > 0) and "settled" or nil),
    npc = npc,
    -- nobody picked -> he asks; any hoarder (rich or busted) amuses him; he
    -- only golf-claps for a clean share
    emote = (nh + ns == 0) and "ask" or ((nh > 0) and "laugh" or "applaud"),
  })
end

-- Round voided by an encounter: red VOIDED stamp, no celebration.
fxVoid = function()
  if not (win and win:IsShown()) then return end
  hideStamps()
  Theme.Stamp(win, "VOIDED")
  Theme.Sound("coincancel")
  Theme.After(win, 0.2, function()
    if npc then npc:Emote("ask") end
  end)
end

-- Final standings for the podium: the roster ranked by net winnings desc, then
-- name asc, read straight out of the totals the window already displays. Rank
-- numbers are part of the row text so a hoisted personal row stays honest.
-- Returns the row list, the leader's name and the leader's net.
local function endRows()
  local S = mySession()
  local order, net = {}, {}
  if not S then return {} end
  for i, name in ipairs(S.roster) do
    order[i] = name
    net[name] = (S.totals[name] or 0) - (S.buyin or 0)
  end
  table.sort(order, function(a, b)
    if net[a] ~= net[b] then return net[a] > net[b] end
    return a < b
  end)
  local me = myName()
  local list = {}
  for i = 1, #order do
    local name = order[i]
    local n = net[name]
    local role
    if i == 1 then role = "gold"
    elseif i == 2 then role = "silver"
    elseif i == 3 then role = "bronze"
    else role = (n >= 0) and "win" or "loss" end
    list[i] = {
      text = i .. ". " .. name .. "  net "
        .. ((n >= 0) and ("+" .. PG.Money(n)) or ("-" .. PG.Money(-n))),
      role = role,
      place = (i <= 3) and i or nil,
      personal = (name == me),
    }
  end
  return hoistPersonal(list), order[1], net[order[1]]
end

-- Session end (REVEAL.md 6.2): sparkles in the window, and the podium of net
-- winnings on the stage. RevealQueue, not Reveal: the final result must
-- eventually show, so it waits out an encounter/ready-check rather than being
-- dropped - and its validate culls it if this session is gone by then.
fxEnd = function()
  local S = mySession()
  if not (win and win:IsShown() and S) then return end
  -- A9 sparkles stay in the window: they are its own end-state decoration and
  -- the one celebration that still plays while the podium is held back. They
  -- start after the stage's longest possible life (podium 4.80 s) instead of at
  -- 0.4 s, where they used to play entirely underneath its 0.85 scrim and were
  -- over before it faded. Theme.After is gen-checked, so a hide in between
  -- simply drops them.
  Theme.After(win, 5.2, function()
    if sparkFrame and sparkGroup then
      sparkFrame:Show()
      restartGroup(sparkGroup)
      Theme.After(win, 4, function()
        pcall(sparkGroup.Stop, sparkGroup)
        sparkFrame:Hide()
      end)
    end
  end)
  -- a spectator's totals are exactly the ones nobody agreed on (that is why it
  -- wrote no ledger), so it gets no podium - its window text says so instead
  if S.spectator then return end
  local list, topName, topNet = endRows()
  if not list[1] then return end
  local bigWin = S.basePot ~= nil and topNet >= S.basePot / 2
  local sess = S
  Theme.RevealQueue({
    game = "LG",
    anchor = { mode = "window", host = win },
    variant = "podium",
    title = "FINAL RESULTS",
    subtitle = #S.roster .. " goblins - pot " .. PG.Money(S.basePot or 0),
    rows = list,
    -- nets always sum to zero, so a top net of 0 means the pot came back out
    -- exactly as it went in - nobody to crown
    marquee = (topNet > 0) and (shortOf(topName) .. " TAKES THE HOARD")
      or "NOBODY BEAT THE BUY-IN",
    burst = "coins",
    burstCount = 12,
    sound = "coins",
    burstSound = "fanfare",
    npc = npc,
    emote = bigWin and "dance" or "cheer",
    -- ownership (CONCURRENCY.md 5.8): a payload whose session has since been
    -- evicted - superseded, withdrawn, swept - is culled at drain time rather
    -- than played over whatever is on screen by then
    validate = function()
      return sessions[sess.key] == sess and sess.ended == true
    end,
    -- precedence (5.8 rule 3): a podium from the game we PLAYED drains ahead of
    -- one from a game we merely refereed
    priority = sess.seated and 1 or 0,
  })
end

-------------------------------------------------------------------------------
-- Game window
-------------------------------------------------------------------------------

-- Chalk on the board: the one body colour, with the standard over-art shadow.
-- Text is never INK anywhere but the Ledger sheet and a card face (PLAN 2.1).
local function chalk(fs)
  if not fs then return end
  if TC then fs:SetTextColor(TC.CHALK[1], TC.CHALK[2], TC.CHALK[3]) end
  if Theme then Theme.Shadow(fs) end
end

-- The roster row: LEFT, always (a ragged name column is unscannable), at the
-- same inset as the status line above it and the full derived width.
rowAt = function(i)
  if not rows[i] then
    local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- S
    fs:SetPoint("TOPLEFT", INSET, -ROWS_TOP - (i - 1) * ROW_PITCH)
    fs:SetWidth(440 - 2 * INSET)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    chalk(fs)
    rows[i] = fs
  end
  return rows[i]
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("lg", "Loot Goblins", 440, 620, "LG")
  -- Safety auto-resume: come back after an encounter/ready-check/countdown,
  -- but never resurrect for a session that has since died OR been replaced -
  -- the window is bound to one record (win.__pgRec) and shows nothing else.
  win.__pgResume = function()
    local S = mySession()
    return S ~= nil and win.__pgRec == S
  end

  -- the audience, under the title (SCOPE.md 5.4): "who can see this game" is
  -- the first thing a player needs to know about a session they did not start.
  -- Centred at the shared -34, like every other game: it used to sit at -100
  -- and LEFT, which drew its first eleven characters INSIDE the treasure chest
  -- in amber-on-gold (F2 / A5).
  ui.aud = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")   -- S
  ui.aud:SetPoint("TOPLEFT", INSET, -34)                          -- METRIC.AUD_Y
  ui.aud:SetPoint("TOPRIGHT", -INSET, -34)
  ui.aud:SetJustifyH("CENTER")
  ui.aud:SetWordWrap(false)
  ui.aud:SetMaxLines(1)
  if TC then ui.aud:SetTextColor(TC.CHGRAY[1], TC.CHGRAY[2], TC.CHGRAY[3]) end
  if Theme then Theme.Shadow(ui.aud) end

  -- Treasure chest in a fixed 56x56 slot (art may fall back to a coin icon;
  -- layout never depends on which rendered) - also the origin every coin
  -- shower, glow, and sparkle anchors to.
  if Theme then
    ui.chest = Theme.Icon(win, "chest", 56)
    ui.chest:SetPoint("TOPLEFT", INSET, -52)
    win.__pgFXOrigin = ui.chest
  end

  ui.info = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")        -- B
  -- 3-line money column: the ~200px between chest and goblin model cannot fit
  -- the one-line join string, which ellipsized the pot (the headline number).
  -- RefreshUI leads with the pot on its own short line; wrap-within-48px
  -- guards the rare overlong case (huge pots, 3-digit rosters). The right edge
  -- is the shared NPC reserve, which is what keeps this column off the model.
  -- Body copy: LEFT (PLAN 4).
  ui.info:SetPoint("TOPLEFT", 88, -52)
  ui.info:SetPoint("TOPRIGHT", -NPC_RESERVE, -52)
  ui.info:SetHeight(48)
  ui.info:SetJustifyH("LEFT")
  ui.info:SetJustifyV("TOP")
  ui.info:SetWordWrap(true)
  ui.info:SetMaxLines(3)
  if TC then ui.info:SetTextColor(TC.CHGOLD[1], TC.CHGOLD[2], TC.CHGOLD[3]) end
  if Theme then Theme.Shadow(ui.info) end

  -- The timer bar: shared inset, shared 18px height, and its right edge on the
  -- NPC reserve so the one bar in the suite that shares a band with a model
  -- still lines up with the money column above it.
  ui.bar = PG.UI.TimerBar(win, 440 - INSET - NPC_RESERVE)
  ui.bar:SetPoint("TOPLEFT", INSET, -116)

  -- Grizzle the Pit Boss: 3D goblin host, reacts to the game (pure decor;
  -- Theme.NPC falls back to a static coin-pile icon in the same container)
  if Theme then
    npc = Theme.NPC(win, "host")
    npc.frame:SetPoint("TOPRIGHT", -18, -44)
    -- the nameplate hangs 4px under the container and the cards start 6px
    -- below it: it used to be 1px above the HOARD card, which Theme.Shadow
    -- closed to zero, so any change to the container height put "Grizzle the
    -- Pit Boss" on the card face (A6).
    ui.plate = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")    -- S
    ui.plate:SetPoint("TOP", npc.frame, "BOTTOM", 0, -4)
    ui.plate:SetWidth(140)
    ui.plate:SetJustifyH("CENTER")
    ui.plate:SetWordWrap(false)
    ui.plate:SetMaxLines(1)
    ui.plate:SetText("Grizzle the Pit Boss")
    chalk(ui.plate)
  end

  ui.shareBtn = PG.UI.CardButton(win, "SHARE", 190, 46, function() doPick("S") end)
  ui.shareBtn:SetPoint("TOPLEFT", INSET, -216)
  ui.hoardBtn = PG.UI.CardButton(win, "HOARD", 190, 46, function() doPick("H") end)
  ui.hoardBtn:SetPoint("TOPRIGHT", -INSET, -216)
  -- the status line ticks ("...45s" -> "...44s"), so it is LEFT with a width
  -- pair: centred, it would shuffle sideways once per second (PLAN 4).
  ui.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")      -- B
  ui.status:SetPoint("TOPLEFT", INSET, -270)
  ui.status:SetPoint("TOPRIGHT", -INSET, -270)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(false)
  chalk(ui.status)
  -- The empty state is not list item zero: it gets its own centred line in the
  -- first free roster slot instead of being written into rowAt(1) with the
  -- roster's LEFT justification (T3-2 / F7).
  ui.empty = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")  -- S
  ui.empty:SetPoint("TOPLEFT", INSET, -ROWS_TOP)
  ui.empty:SetPoint("TOPRIGHT", -INSET, -ROWS_TOP)
  ui.empty:SetJustifyH("CENTER")
  ui.empty:SetWordWrap(false)
  ui.empty:SetMaxLines(1)
  if TC then ui.empty:SetTextColor(TC.CHGRAY[1], TC.CHGRAY[2], TC.CHGRAY[3]) end
  if Theme then Theme.Shadow(ui.empty) end
  ui.empty:Hide()
  -- one short sentence about YOU, alone above a centred button row: centred
  -- (PLAN 4), and bounded so a long one truncates instead of spilling
  ui.mine = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")        -- B
  ui.mine:SetPoint("BOTTOMLEFT", INSET, 46)
  ui.mine:SetPoint("BOTTOMRIGHT", -INSET, 46)
  ui.mine:SetJustifyH("CENTER")
  ui.mine:SetWordWrap(false)
  ui.mine:SetMaxLines(1)
  chalk(ui.mine)
  ui.startBtn = PG.UI.Button(win, "Start now", 105, 22, function()
    local S = mySession()
    if S and S.isHost and S.phase == "join" then hostCloseJoin() end
  end)
  -- Footer: 105x22 at the shared 24 inset and 16 bottom margin. The old 20
  -- left 1px between "Cancel game" and the frame-level +10 resize grip, so at
  -- fractional scales the button's right edge became a resize handle (A12).
  ui.startBtn:SetPoint("BOTTOMLEFT", INSET, 16)
  ui.cancelBtn = PG.UI.Button(win, "Cancel game", 105, 22, function()
    local S = mySession()
    if S and S.isHost and S.phase ~= "done" then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOMRIGHT", -INSET, 16)
  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", 105, 22, function()
    local S = mySession()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "LG", "UNJOIN", S.token)
      -- withdrawing stops this client tracking the game at all (7.2): the seat
      -- is freed here rather than when the host's LEFT comes back, so the next
      -- invitation is accept-able immediately
      local me = myName()
      if me then applyLeft(me) end
    end
  end)
  ui.withdrawBtn:SetPoint("BOTTOMLEFT", INSET, 16) -- shares the host-only Start slot
  ui.ledgerBtn = PG.UI.Button(win, "Open Ledger", 105, 22, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ui.ledgerBtn:SetPoint("BOTTOM", 0, 16)

  if Theme then
    -- gold-pile decor behind the bottom buttons, on the board (an icon is
    -- identity, a background is a theme: the decor stays, the parchment ground
    -- it used to sit on does not); hidden entirely if the art fails
    local pile = win:CreateTexture(nil, "ARTWORK", nil, -7)
    pile:SetSize(220, 48)
    pile:SetPoint("BOTTOM", 0, 10)
    pile:SetAlpha(0.35)
    if not Theme.Tex(pile, "goldpile") then pile:Hide() end

    win.__pgBannerSlot = rowAt(1) -- banners slide in over the roster area
    buildRevealFX()

    -- farewell bark: manual close of a FINISHED session only. Safety hides
    -- always arrive with a flag set, so allClear() filters every auto path
    -- (and Theme.Sound re-applies the same gates plus the default-off pref).
    win:HookScript("OnHide", function()
      local S = mySession()
      if S and S.phase == "done" and S.ended and allClear() then
        Theme.Sound("farewell")
      end
    end)
  end
end

local SCOPE_HEADER = {
  group = "Party",
  guild = "Guild game - settle up with people you can find again.",
  public = "Public - realm-wide. Virtual gold, honour-system settling.",
}

RefreshUI = function()
  local S = mySession()
  if not win or not S then return end
  if win.__pgRec and win.__pgRec ~= S then return end -- another record's window
  local now = GetTime()
  ui.aud:SetText(SCOPE_HEADER[S.scope] or "")
  local me = myName()
  local isJoin = S.phase == "join"
  local isPlay = S.phase == "play"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false

  -- explicit |n breaks keep each line inside the ~200px column, pot first
  if isJoin then
    ui.info:SetText("Pot " .. tmoney(S.buyin * #S.roster) .. "|nBuy-in "
      .. PG.Money(S.buyin) .. " - " .. #S.roster .. " in|n" .. S.rounds .. " rounds")
  elseif isPlay then
    if S.r >= 1 then
      ui.info:SetText("Round " .. S.r .. "/" .. S.rounds .. "|nround pot "
        .. tmoney(S.roundPot or 0))
    else
      ui.info:SetText("Pot " .. tmoney(S.basePot or 0) .. "|n" .. #S.roster
        .. " goblins - buy-in closed")
    end
  else
    ui.info:SetText(S.endText or "Game over.")
  end

  local status
  if isJoin then
    if S.isHost then
      local remaining = S.joinFrozen and (S.joinRemaining or 0)
        or math.max(0, (S.joinDeadline or now) - now)
      status = #S.roster .. " joined - buy-in closes in " .. math.ceil(remaining) .. "s"
        .. (S.joinFrozen and " (paused)" or "")
      -- Show what we already know (CONCURRENCY.md 6.3): nobody replies "busy",
      -- so the host is at least told how many addon users are in earshot. Group
      -- scope only - PG.Peers is a group-scope fact and would mislead elsewhere.
      if S.scope == "group" and PG.Peers then
        local peers = 0
        for _ in pairs(PG.Peers) do peers = peers + 1 end
        if peers > 0 then
          status = status .. GRAY .. "  (" .. #S.roster .. " of " .. (peers + 1)
            .. " addon users)|r"
        end
      end
    else
      status = #S.roster .. " joined - waiting for the host to start"
    end
  elseif isPlay then
    if S.hostQuiet then
      -- wide scope: the host is in content we cannot see (SCOPE.md 6.2). This
      -- is a repaint and nothing else - no state change, no spectator flip.
      status = "Waiting for the host - they may be in a boss fight."
    elseif S.spectator then
      status = S.syncDead and "Spectating - too far out of sync to catch up."
        or "Spectating - out of sync, resyncing with the host..."
    elseif S.roundOpen then
      if S.isHost then
        local k = 0
        for _ in pairs(S.picks) do k = k + 1 end
        status = k .. "/" .. #S.roster .. " picked"
        if S.myPick then
          status = status .. " - you locked " .. (S.myPick == "S" and "SHARE" or "HOARD")
        end
      elseif S.myPick then
        status = "You locked " .. (S.myPick == "S" and "SHARE" or "HOARD") .. " - waiting for the reveal"
      elseif S.syncHoldR == S.r and inRoster then
        status = "Back in sync - you are back in from the next round."
      elseif inRoster then
        status = "Make your pick: SHARE the pot, or HOARD it for yourself!"
      else
        status = "Watching this one."
      end
    else
      status = S.lastResultText or "Next round starting soon..."
    end
  else
    status = S.lastResultText or ""
  end
  ui.status:SetText(status)

  local lines = {}
  -- the referee host sits OUTSIDE the numbered roster: it has no buy-in, no
  -- pick and no ledger row, and the pot arithmetic never counts it (I5)
  rowOffset = 0
  if S.refereed then
    lines[1] = GRAY .. shortOf(S.host) .. " (running the game)|r"
    rowOffset = 1 -- hoarder stamps follow the roster down one row
  end
  local emptyMsg = nil
  if S.spectator and not isJoin then
    lines[#lines + 1] = GRAY .. "Out of sync - results are shown in the status line only.|r"
  elseif isJoin then
    for _, name in ipairs(S.roster) do
      lines[#lines + 1] = name .. (name == me and (GOLD .. " (you)|r") or "")
    end
    -- one string, one treatment, in every game (F7): centred in the first free
    -- roster slot, never written into row 1 as though it were a player
    if #S.roster == 0 then emptyMsg = "Nobody has joined yet." end
  else
    local lr = S.lastResult
    local annotate = lr and #lr.pattern == #S.roster
    for i, name in ipairs(S.roster) do
      local ann = ""
      if annotate then
        local c = lr.pattern:sub(i, i)
        if c == "H" then
          ann = RED .. "  HOARD +" .. PG.Money(lr.hoardPay) .. "|r"
        elseif c == "S" then
          ann = GREEN .. "  share +" .. PG.Money(lr.sharePay) .. "|r"
        else
          ann = GRAY .. "  no pick|r"
        end
      end
      local total = S.totals[name] or 0
      local line = name .. (name == me and (GOLD .. " (you)|r") or "") .. ann
      if isDone and S.ended then
        -- the running total is buy-in + net, so printing BOTH pushed the row
        -- past its width and the ellipsis ate the (+net) figure - the one
        -- number the player is looking for (B1). Final rows show the net.
        local netN = total - S.buyin
        line = line .. "  (" .. (netN >= 0 and (GREEN .. "+" .. PG.Money(netN))
          or (RED .. "-" .. PG.Money(-netN))) .. "|r)"
      else
        line = line .. "  -  " .. PG.Money(total)
      end
      lines[#lines + 1] = line
    end
  end
  -- The local player's row is the one row the collapse may not eat: when it
  -- falls past the cut it is lifted into the last visible slot, the same rule
  -- Death Roll and the reveal stage already apply. Without it you can be
  -- player 20 of 40 and simply not appear in your own window (F6).
  rowLifted = false
  if #lines > MAX_ROWS and me then
    local mineAt
    for i = MAX_ROWS, #lines do
      if lines[i]:find(me, 1, true) then
        mineAt = i
        break
      end
    end
    if mineAt then
      table.insert(lines, MAX_ROWS - 1, table.remove(lines, mineAt))
      rowLifted = true
    end
  end
  local shown = math.min(#lines, MAX_ROWS)
  if #lines > MAX_ROWS then
    lines[MAX_ROWS] = GRAY .. "... and " .. (#lines - MAX_ROWS + 1) .. " more|r"
  end
  for i = 1, shown do
    rowAt(i):SetText(lines[i])
    rowAt(i):Show()
  end
  for i = shown + 1, #rows do rows[i]:Hide() end
  -- the empty line lands in the first slot the roster did not use, so a
  -- refereed game shows "(running the game)" and then the message under it
  if emptyMsg then
    local y = -ROWS_TOP - shown * ROW_PITCH
    ui.empty:ClearAllPoints()
    ui.empty:SetPoint("TOPLEFT", INSET, y)
    ui.empty:SetPoint("TOPRIGHT", -INSET, y)
    ui.empty:SetText(emptyMsg)
  end
  ui.empty:SetShown(emptyMsg ~= nil)

  if S.spectator then
    ui.mine:SetText(GRAY .. "No stake this game (spectating).|r")
  elseif S.refereed then
    ui.mine:SetText(GRAY .. "You have no stake in this game - you're running it.|r")
  elseif inRoster then
    if isJoin then
      ui.mine:SetText("You are in for " .. GOLD .. PG.Money(S.buyin) .. "|r.")
    else
      local won = S.totals[me] or 0
      local netN = won - S.buyin
      ui.mine:SetText("Your winnings: " .. GOLD .. PG.Money(won) .. "|r  (net "
        .. (netN >= 0 and (GREEN .. "+" .. PG.Money(netN))
            or (RED .. "-" .. PG.Money(-netN))) .. "|r)")
    end
  else
    ui.mine:SetText(GRAY .. "You have no stake in this game.|r")
  end

  ui.shareBtn:SetShown(isPlay and not S.spectator)
  ui.hoardBtn:SetShown(isPlay and not S.spectator)
  local canPick = (isPlay and S.roundOpen and inRoster and not S.myPick and not S.spectator
    and S.syncHoldR ~= S.r) and true or false
  ui.shareBtn:SetEnabled(canPick)
  ui.hoardBtn:SetEnabled(canPick)
  ui.startBtn:SetShown(isJoin and S.isHost)
  -- no live Cancel button while END is queued or sent: hostCancel refuses there
  -- (the ledger is already committed to), so the affordance would silently lie
  ui.cancelBtn:SetShown(S.isHost and not isDone
    and not (S.endPending or S.endSent))
  ui.withdrawBtn:SetShown((isJoin and not S.isHost and S.joinAccepted) and true or false)
  ui.ledgerBtn:SetShown((isDone and S.ended) and true or false)
end

ShowWindow = function()
  local S = mySession()
  if not S then return end -- only the session we are IN ever gets the window
  if not (S.isHost or S.joinAccepted) then return end -- mirrors stay windowless
  local st = PG.Safety.state
  if st.inEncounter or st.readyCheck or st.countdown or st.restricted then return end
  -- plain combat hides the window only when the user opted in (Settings)
  if st.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return end
  ensureWindow()
  -- one window per module, bound to the involved record: a replaced session can
  -- never leave a fully drawn, live-looking window behind (CONCURRENCY.md 5.9)
  win.__pgRec = S
  RefreshUI()
  win:Show()
  -- first show for this session: the host waves hello (once per session, and
  -- identity is the whole key now that tokens are only unique per host)
  if Theme and greetToken ~= S.key then
    greetToken = S.key
    runFX(fxGreet)
  end
end

-------------------------------------------------------------------------------
-- Host config dialog
-------------------------------------------------------------------------------

local function makeField(parent, label, y, default)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")        -- T
  fs:SetPoint("TOPLEFT", INSET, y)
  fs:SetText(label)
  chalk(fs) -- chalk on the board, with the over-art shadow
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(70, 20)
  eb:SetPoint("TOPRIGHT", -INSET, y + 2)
  eb:SetAutoFocus(false)
  eb:SetNumeric(true)
  eb:SetMaxLetters(6)
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

-- Every module that can hold the seat, so the "you'll run this game without
-- playing in it" line below names the game the player is actually in. A missing
-- entry does not error, it degrades to "another game" - true but useless.
local GAME_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors",
                    PB = "The Pull Book", DR = "Death Roll",
                    GB = "The Gambler", QZ = "Quiz" }

-- The dialog always opens and Start explains itself (CONCURRENCY.md 6.4). It
-- never refuses to appear: "why can't I?" is information the user wants, and
-- the old blanket refusal answered it with a toast and a shrug.
local function refreshDialog()
  if not dialog then return end
  local note, canStart = "", true
  local S = mySession()
  local seat = PG.Session.Seat()
  if S and S.phase ~= "done" then
    canStart = false
    if S.isHost then
      note = "You're already running a Loot Goblins game. Cancel it first, or wait for it to finish."
    else
      note = "You're playing " .. shortOf(S.host)
        .. "'s Loot Goblins game. You can start your own when it's over."
    end
  elseif seat then
    -- seated in the OTHER module: Start stays ENABLED (I4/I5) and this is a
    -- statement of what will happen, not a refusal
    note = "You're playing " .. (GAME_NAME[seat.module] or "another game")
      .. ", so you'll run this game without playing in it."
  end
  local scope = dlgScope and dlgScope:Get()
  if not scope then
    canStart = false
    if note == "" then
      note = "Nowhere to start a game: you're not in a group or a guild."
    end
  end
  if dlgNote then dlgNote:SetText(note) end
  if dlgOpen then
    dlgOpen.__pgWhy = (not canStart) and note or nil
    dlgOpen:SetEnabled(canStart)
  end
end

local function ensureDialog()
  if dialog then return end
  -- 320x320 -> 320x340: the audience block is 58 tall now (its hint used to
  -- render outside the rect it declared), and the note under it has to clear
  -- the button row. The title is the factory's bounded, centred container -
  -- the gold crown header and its INK recolour went with the one design.
  dialog = PG.UI.Window("lgdialog", "Start Loot Goblins", 320, 340, "LG")
  -- one 32px field pitch, starting 20 under the title container (-36)
  dlgInputs = {
    buyin = makeField(dialog, "Buy-in (gold)", -56, 100),
    rounds = makeField(dialog, "Rounds", -88, 5),
    joinSecs = makeField(dialog, "Join window (sec)", -120, 45),
    roundSecs = makeField(dialog, "Round timer (sec)", -152, 20),
  }
  -- Audience picker (SCOPE.md 5.3): one 58px block - centred label, centred
  -- 216px segment row, hint inside. Every segment renders at every moment - an
  -- unavailable one is greyed with its reason on hover, because the disabled
  -- state IS the message.
  dlgScope = PG.UI.ScopePicker(dialog, {
    key = "LG",
    allowed = PG.LG.SCOPES,
    reasons = function(scope)
      if scope == "public" then return PUBLIC_NOTE end
      return nil
    end,
    onChange = function() refreshDialog() end,
  })
  dlgScope:SetPoint("TOPLEFT", dialog, "TOPLEFT", 0, -184)
  dlgScope:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", 0, -184)

  -- anchored to the picker's bottom, not to an absolute offset: the picker
  -- grew 44 -> 58 and every dialog in the suite was one copy edit away from
  -- the note and the picker hint sharing a band (T1-8). Two wrapped lines of
  -- explanation: LEFT, top-aligned in its box so a one-line note does not
  -- float (F14).
  dlgNote = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")   -- S
  dlgNote:SetPoint("TOPLEFT", dlgScope, "BOTTOMLEFT", INSET, -8)
  dlgNote:SetPoint("TOPRIGHT", dlgScope, "BOTTOMRIGHT", -INSET, -8)
  dlgNote:SetJustifyH("LEFT")
  dlgNote:SetJustifyV("TOP")
  dlgNote:SetHeight(40)
  dlgNote:SetWordWrap(true)
  dlgNote:SetMaxLines(3)
  -- CHGOLD, which is what RPS, Gambler and Quiz already use for this line
  if TC then dlgNote:SetTextColor(TC.CHGOLD[1], TC.CHGOLD[2], TC.CHGOLD[3]) end
  if Theme then Theme.Shadow(dlgNote) end

  local openLabel = "Open buy-in"
  if Theme then openLabel = Theme.Mark("coin") .. " Open buy-in" end
  dlgOpen = PG.UI.Button(dialog, openLabel, 150, 26, function()
    local buyin = fieldValue(dlgInputs.buyin, 1, 100000)
    local rounds = fieldValue(dlgInputs.rounds, 1, 20)
    local joinSecs = fieldValue(dlgInputs.joinSecs, 10, 300)
    local roundSecs = fieldValue(dlgInputs.roundSecs, 10, 60)
    local scope = dlgScope and dlgScope:Get()
    if not scope then
      toast("Loot Goblins: nowhere to start a game - you're not in a group or a guild.")
      return
    end
    -- availability is re-checked at the moment Start is pressed: never fall
    -- back to another audience, say why and repaint (SCOPE.md 1.3)
    local ok, why = PG.Comm.ScopeAvailable(scope)
    if not ok then
      toast("Loot Goblins: " .. (why or "that audience isn't available."))
      dlgScope:Refresh()
      refreshDialog()
      return
    end
    if Theme then Theme.Sound("stamp") end
    dialog:Hide()
    hostOpen(buyin, rounds, joinSecs, roundSecs, scope)
  end)
  dlgOpen:SetPoint("BOTTOM", 0, 18)
  -- "how does this work?" lives next to Start, where a new player looks
  local dlgRules = PG.UI.Button(dialog, "Rules", 60, 22, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("LG") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", 16, 18)
  -- the same reason, on hover, for a Start that cannot be pressed
  dlgOpen:SetScript("OnEnter", function(self)
    if not self.__pgWhy then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.__pgWhy, 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  dlgOpen:SetScript("OnLeave", function() GameTooltip:Hide() end)
  dialog:HookScript("OnShow", refreshDialog)
end

-- Launcher / slash entry point. The dialog ALWAYS opens (CONCURRENCY.md 0.2):
-- the refusals that used to live here are gone, and the control explains
-- itself instead.
function PG.LG.OpenDialog()
  ensureDialog()
  refreshDialog()
  dialog:Show()
end

PG.RegisterInit(function()
  -- capture the skin layer once (SKIN.md 1.1/5.8). ONE DESIGN: the ground is
  -- the board in every window, so the inline codes are the board ramp
  -- (Theme.ROLE), never the parchment ramp. win/loss/fade/amber here used to
  -- put #145214, #8f1600, #6b5c42 and #7a4a00 straight on #12141a - between
  -- 1.4:1 and 2.4:1 - across the roster, the status line and every toast.
  -- Everything degrades to the plain look when Theme is absent.
  if PG.Theme and PG.Theme.C then
    Theme = PG.Theme
    TC = Theme.C()
    GREEN, RED, GRAY, GOLD = TC.chgreen, TC.chred, TC.chgray, TC.chgold
  end
  PG.Comm.Register("LG", onComm, onDrop)
  PG.Safety.OnChange(onSafetyChange)

  ASK_MAX = PG.UI.ASK_MAX or ASK_MAX
  -- the random suffix in a token is a seatbelt against a SavedVariables
  -- rollback, and math.random is unseeded on a fresh client. Core owns this
  -- once it ships PG.NextToken; until then the fallback minter seeds itself.
  if type(PG.NextToken) ~= "function" then
    pcall(math.randomseed, time())
  end

  -- Whisper trust (SCOPE.md 4.3, retargeted at the registry). A whisper
  -- carries no audience proof at all, so only the session we are INVOLVED in
  -- vouches for one. Lite records never do: we never whispered them anything,
  -- so they can never legitimately expect a reply.
  PG.Comm.RegisterTrust("LG", function(sender)
    local S = mySession()
    if not S or S.phase == "done" then return false end
    if sender == S.host then return true end
    if S.joined[sender] then return true end
    -- host side, wide scope, join window open: the first JOIN from a stranger
    -- is the entire point of a wider audience. Comm's rate limiting bounds it.
    if S.isHost and S.phase == "join" and S.scope ~= "group" then return true end
    return false
  end)

  -- Accepting one invitation withdraws the rest (CONCURRENCY.md 5.6 rule 3):
  -- the moment the single round-based seat is taken - here or in the other
  -- module - every invitation this module still has on screen comes down. The
  -- lite records stay in the launcher list until they expire.
  PG.Session.OnChange(function(seat)
    if not seat then return end
    for _, rec in pairs(sessions) do
      if rec.kind == "lite" and rec.askKey then
        local key = rec.askKey
        rec.askKey = nil
        PG.UI.Dismiss(key)
      end
    end
    if dialog and dialog:IsShown() then refreshDialog() end
  end)
end)
