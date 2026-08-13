-- Core.lua - addon table, DB init, event hub, Safety state machine, peers, slash.
local ADDON, PG = ...

_G.PengyouGames = PG -- debugging handle; the only global table this addon creates
                     -- (the SLASH_* names and PengyouGamesDB are platform-required)

-- Flat English string table, no localization machinery in v1: PG.L["Some text"]
-- passes the key through, so user-visible strings stay inline in English.
PG.L = setmetatable({}, { __index = function(_, k) return k end })

PG.debug = false

-------------------------------------------------------------------------------
-- Event hub + init pipeline.
-- Bootstrap exception to file-scope purity: Core must own the frame that
-- catches ADDON_LOADED so it can run every module's init callbacks.
-------------------------------------------------------------------------------

local hub = CreateFrame("Frame")
local handlers = {} -- event -> array of fn(event, ...)
local inits = {}
local initDone = false

-- fn() runs at ADDON_LOADED (own addon), in registration order == file load
-- order. If registered after init already ran, fn runs immediately.
function PG.RegisterInit(fn)
  if initDone then
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
    return
  end
  inits[#inits + 1] = fn
end

-- Multiplexed event hub. Handlers are called as fn(event, ...), pcall-wrapped.
-- The RegisterEvent call itself is pcall-guarded because unknown events
-- hard-error on 12.x (e.g. ADDON_RESTRICTION_STATE_CHANGED may be absent on
-- some builds). Returns true if the event is registered.
function PG.RegisterEvent(event, fn)
  if event == "COMBAT_LOG_EVENT_UNFILTERED" then return false end -- Lua error on 12.x; never allowed
  if not handlers[event] then
    local ok = pcall(hub.RegisterEvent, hub, event)
    if not ok then return false end
    handlers[event] = {}
  end
  local list = handlers[event]
  list[#list + 1] = fn
  return true
end

hub:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" and not initDone then
    local name = ...
    if name == ADDON then
      initDone = true
      for i = 1, #inits do
        local ok, err = pcall(inits[i])
        if not ok then geterrorhandler()(err) end
      end
      if not handlers["ADDON_LOADED"] then hub:UnregisterEvent("ADDON_LOADED") end
    end
  end
  local list = handlers[event]
  if list then
    for i = 1, #list do
      local ok, err = pcall(list[i], event, ...)
      if not ok then geterrorhandler()(err) end
    end
  end
end)
hub:RegisterEvent("ADDON_LOADED")

-- C_Timer wrappers. PG.Ticker returns the ticker handle (:Cancel() to stop).
function PG.After(sec, fn) C_Timer.After(sec, fn) end
function PG.Ticker(sec, fn) return C_Timer.NewTicker(sec, fn) end

-------------------------------------------------------------------------------
-- SavedVariables
-------------------------------------------------------------------------------

local DB_DEFAULTS = {
  -- profile.scope: last audience the user picked per game (SCOPE.md 5.5).
  -- Written by PG.UI.ScopePicker on an explicit click only; a fallback to an
  -- available scope never overwrites it.
  profile = {
    sounds = false, dnd = false, scale = 1, positions = {}, hideInCombat = false,
    -- profile.scopeIn: which wider audiences may reach us at all (SCOPE.md 5.6).
    -- Guild defaults ON, matching Comm's guildScopeOn(); copyDefaults only fills
    -- nils, so a user who turned it off keeps it off across sessions.
    -- profile.publicOptIn is deliberately NOT seeded: its default is off, absent
    -- reads as false everywhere, and a stray `true` here would silently join the
    -- public channel on first login.
    scopeIn = { guild = true },
    -- Every entry is seeded to "group", the NARROWEST audience, and that is the
    -- rule rather than a per-game fact: a wider default would put a first-time
    -- host in front of their guild - or the whole realm - before they knew the
    -- picker existed. LG, RPS, QZ, DR and GB all offer all three segments now
    -- (DR and GB gained guild and public when the roll started travelling over
    -- the wire instead of relying on a /roll line nobody outside the party
    -- could see), so for those five this really is a PREFERENCE and the picker
    -- writes back whatever the user last clicked. PB is the one game with a
    -- single segment, and it is seeded on the same line for the same reason it
    -- always was: one entry per shipped game reads as a complete list, where a
    -- half-seeded table invites the next reader to conclude the missing games
    -- have no picker at all. copyDefaults only fills nils, so no existing user
    -- preference is touched either way.
    scope = { LG = "group", RPS = "group", PB = "group",
              DR = "group", GB = "group", QZ = "group" },
  },
  ledger = { sessions = {}, lifetime = {} },
}

local function copyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      copyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

PG.RegisterInit(function()
  if type(_G.PengyouGamesDB) ~= "table" then _G.PengyouGamesDB = {} end
  copyDefaults(_G.PengyouGamesDB, DB_DEFAULTS)
  PG.db = _G.PengyouGamesDB
end)

function PG.IsDND()
  return PG.db and PG.db.profile and PG.db.profile.dnd or false
end

-- Toggles DND, prints the new state locally (never public chat), returns it.
function PG.ToggleDND()
  local p = PG.db.profile
  p.dnd = not p.dnd
  DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: DND " .. (p.dnd and "ON (popups and toasts suppressed)" or "OFF"))
  -- an open Settings window re-syncs its DND checkbox immediately
  if PG.Settings and PG.Settings.Refresh then PG.Settings.Refresh() end
  return p.dnd
end

-------------------------------------------------------------------------------
-- Session tokens (CONCURRENCY.md 3.2).
--
-- Identity is the PAIR (host, token): `sender` is server-vouched and realm-
-- qualified, so a token only has to be unique inside ONE character's history.
-- The mechanism is the persisted monotonic counter; the three random base-36
-- characters after it are a seatbelt for a SavedVariables rollback, where the
-- counter can go backwards, and nothing else. The counter is incremented AND
-- persisted BEFORE the caller receives its token, so a client that dies between
-- minting and broadcasting can never reissue a number it already used.
--
-- Typical result "1a-7f3": 6 bytes on every message of a session, against up to
-- 18 for the realm-less "Thrall-48120" form this replaced.
--
-- This shipped late. CONCURRENCY.md 3.2 specified PG.NextToken, Core never
-- provided it, and Loot Goblins, Pull Book and Rock Paper Scissors each grew a
-- private fallback minter that PREFERS PG.NextToken when it exists. All three
-- therefore start sharing this counter the moment this function is defined,
-- with no edit to any of them - which is the point: one counter across every
-- module is more monotonic than three, never less.
-------------------------------------------------------------------------------

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

-- Never returns nil: every caller's local fallback minter is the same code with
-- the same limits, so refusing here would buy nothing and cost a session its
-- identity. Always satisfies the shipped wire validation (CONCURRENCY.md 3.4:
-- non-empty, <= 24 bytes, no "|") - the counter would need 36^11 sessions on one
-- character to reach even half that length.
function PG.NextToken()
  local p = PG.db and PG.db.profile
  local seq = 1
  if p then
    seq = (PG.SafeNum(p.seq) or 0) + 1
    -- A corrupt or hand-edited profile could hold a negative or non-numeric
    -- seq; without this, b36() floors every one of them to "0" and the counter
    -- silently stops being a counter.
    if seq < 1 then seq = 1 end
    p.seq = seq
  end
  -- Padded, unlike the game files' fallbacks: one draw in 36 lands below 36 and
  -- would otherwise carry a one-character seatbelt, which is not the three
  -- characters the format claims and is 1296 times weaker.
  local r = b36(math.random(0, 46655))
  while #r < 3 do r = "0" .. r end
  return b36(seq) .. "-" .. r
end

PG.RegisterInit(function()
  -- One seed for the whole addon, before anything can mint. Lua's generator is
  -- deterministic from a fixed seed, so unseeded every client draws the SAME
  -- "random" sequence after login - exactly the case the seatbelt exists to
  -- cover. The first draws after a seed are weakly distributed in some builds;
  -- three throwaways cost nothing.
  local base = (type(time) == "function" and tonumber(time())) or 0
  local frac = (type(GetTimePreciseSec) == "function" and tonumber(GetTimePreciseSec()))
    or (type(GetTime) == "function" and tonumber(GetTime())) or 0
  math.randomseed(math.floor((base * 1000 + frac * 1000) % 2147483647))
  math.random() math.random() math.random()
end)

-------------------------------------------------------------------------------
-- Safety state machine: hides all registered UI the instant any raid-critical
-- state begins (encounter, ready check, countdown, restriction; plain combat
-- only when the user opts in via profile.hideInCombat), and re-shows exactly
-- what IT hid once everything is clear. A frame can veto its own resume by
-- defining frame.__pgResume() -> boolean (e.g. "only if my session is live").
-------------------------------------------------------------------------------

PG.Safety = {
  -- restricted (from ADDON_RESTRICTION_STATE_CHANGED) tracked alongside the
  -- four spec fields.
  state = { inCombat = false, inEncounter = false, readyCheck = false, countdown = false, restricted = false },
}

local safetyWindows = {}
local safetyCbs = {}

-- frame is hidden instantly on any *_ON trigger; NOT auto-reshown.
function PG.Safety.RegisterWindow(frame)
  safetyWindows[#safetyWindows + 1] = frame
end

-- fn(state, trigger) on every transition; triggers: COMBAT_ON/OFF,
-- ENCOUNTER_ON/OFF, READY_ON/OFF, COUNTDOWN_ON/OFF, RESTRICT_ON/OFF.
function PG.Safety.OnChange(fn)
  safetyCbs[#safetyCbs + 1] = fn
end

local safetyHidden = {} -- frames WE hid while they were shown, for auto-resume

local function hideInCombatOn()
  return (PG.db and PG.db.profile and PG.db.profile.hideInCombat) and true or false
end

-- true while any state that currently mandates hiding is active
local function mustHide()
  local s = PG.Safety.state
  if s.inEncounter or s.readyCheck or s.countdown or s.restricted then return true end
  return s.inCombat and hideInCombatOn()
end

local function setFlag(field, value, trigger)
  local s = PG.Safety.state
  if s[field] == value then return end
  s[field] = value
  if value then
    -- plain combat hides only when the user opted in (Settings); comms and
    -- game progression are legal during plain combat, so by default the
    -- windows simply stay up
    if field ~= "inCombat" or hideInCombatOn() then
      for i = 1, #safetyWindows do
        local w = safetyWindows[i]
        if w and w.Hide and w.IsShown and w:IsShown() then
          safetyHidden[w] = true
          pcall(w.Hide, w)
        end
      end
    end
  elseif not mustHide() then
    -- auto-resume: re-show exactly what we hid, unless the frame's owner
    -- vetoes (dead session, expired popup, ...)
    for w in pairs(safetyHidden) do
      local wants = true
      if w.__pgResume then
        local ok, res = pcall(w.__pgResume)
        wants = (ok and res) and true or false
      end
      if wants and w.Show then pcall(w.Show, w) end
    end
    wipe(safetyHidden)
  end
  for i = 1, #safetyCbs do
    local ok, err = pcall(safetyCbs[i], s, trigger)
    if not ok then geterrorhandler()(err) end
  end
end

local cdGen = 0 -- invalidates stale countdown fallback timers

PG.RegisterInit(function()
  PG.RegisterEvent("PLAYER_REGEN_DISABLED", function() setFlag("inCombat", true, "COMBAT_ON") end)
  PG.RegisterEvent("PLAYER_REGEN_ENABLED", function() setFlag("inCombat", false, "COMBAT_OFF") end)
  PG.RegisterEvent("ENCOUNTER_START", function() setFlag("inEncounter", true, "ENCOUNTER_ON") end)
  PG.RegisterEvent("ENCOUNTER_END", function() setFlag("inEncounter", false, "ENCOUNTER_OFF") end)
  PG.RegisterEvent("READY_CHECK", function() setFlag("readyCheck", true, "READY_ON") end)
  PG.RegisterEvent("READY_CHECK_FINISHED", function() setFlag("readyCheck", false, "READY_OFF") end)

  PG.RegisterEvent("START_PLAYER_COUNTDOWN", function(_, _, timeRemaining, totalTime)
    -- payload is secret only during lockdown (never in our pre-pull window);
    -- guard anyway per platform rule 4
    local secs = PG.SafeNum(totalTime) or PG.SafeNum(timeRemaining) or 10
    cdGen = cdGen + 1
    local gen = cdGen
    setFlag("countdown", true, "COUNTDOWN_ON")
    -- countdown completion fires no cancel event; self-clear as fallback
    PG.After(secs + 1, function()
      if cdGen == gen then setFlag("countdown", false, "COUNTDOWN_OFF") end
    end)
  end)
  PG.RegisterEvent("CANCEL_PLAYER_COUNTDOWN", function()
    cdGen = cdGen + 1
    setFlag("countdown", false, "COUNTDOWN_OFF")
  end)

  -- Fires BEFORE a restriction activates. State semantics are undocumented:
  -- boolean true / nonzero number is treated as active; any restriction type
  -- maps onto the single 'restricted' flag in v1.
  PG.RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", function(_, _, state)
    if PG.IsSecret(state) then return end
    local on = (state == true) or (type(state) == "number" and state ~= 0)
    setFlag("restricted", on, on and "RESTRICT_ON" or "RESTRICT_OFF")
  end)
end)

-------------------------------------------------------------------------------
-- PG.Session - the single round-based seat (CONCURRENCY.md 1.2, 2.3).
--
-- A person PLAYS at most one round-based game at a time. That is the ONLY
-- exclusivity in the suite: unlimited sessions may exist around you, hosting is
-- never blocked, and every pending invitation stays visible until one is
-- accepted. This holder is the whole mechanism.
--
--   I1  One seat, globally, across every round-based module - LG, RPS, DR, GB
--       and QZ as of 1.1.0 (BRIEF 1.1). `seat` below is single-valued or nil,
--       and PG.Session.Claim / PG.Session.Release are its only writers - no
--       module may write it directly. Each of the three new games demands a
--       timed decision from a human, which is the whole test in
--       CONCURRENCY.md 1.1; QZ claims despite being points-only, exactly as
--       RPS does, because the seat is a rule about ATTENTION, not about gold.
--   I2  The seat spans join (or self-seating host) through phase == "done" and
--       nothing else. Release from endSession and the withdrawal path only; the
--       reveal stage, podium, results window and record memory never hold it.
--   I5  Referee hosting: a player seated in one module may HOST another
--       without taking a second seat. PG.Session.ClaimHost is that rule; it
--       cannot refuse, so hosting is never blocked (I4).
--   I10 The Pull Book is the ONLY module that neither claims nor consults the
--       seat - it is passive pre-pull betting and runs alongside anything.
--       PullBook.lua must contain zero CALLS into this table, permanently.
--       Check it with `grep -n 'PG%.Session%.' PengyouGames/Games/PullBook.lua`
--       and not with a search for the bare name: the comment that documents
--       the invariant contains the string "PG.Session" itself.
--
-- Same shape as PG.Safety.OnChange above: register a callback, get told.
-------------------------------------------------------------------------------

PG.Session = {}

local seat = nil  -- { module = "LG", token = "1a-7f3", host = "Name-Realm" } or nil
local seatCbs = {}

-- Callers get a copy, never the holder itself: "read-only view" is an
-- invariant (I1), not a request.
local function seatView()
  if not seat then return nil end
  return { module = seat.module, token = seat.token, host = seat.host }
end

-- fn(seat, prev): both are views or nil. Errors in one listener never stop the
-- others (a module that blows up while withdrawing its invitations must not
-- strand the seat).
local function fireSeatChange(prev)
  local view = seatView()
  for i = 1, #seatCbs do
    local ok, err = pcall(seatCbs[i], view, prev)
    if not ok then geterrorhandler()(err) end
  end
end

-- module and token identify the seat; host is carried for user-facing text
-- ("You're playing Grizzle's Loot Goblins game."). All three arrive from the
-- wire on the client accept path, so all three are validated here.
local function seatArgs(module, token, host)
  module, token, host = PG.SafeStr(module), PG.SafeStr(token), PG.SafeStr(host)
  if not module or module == "" then return nil end
  if not token or token == "" then return nil end
  return module, token, (host ~= "" and host) or "?"
end

-- Take the single round-based seat. Idempotent for the same (module, token).
-- Returns:
--   true                             seat taken (or already ours)
--   false, heldModule, heldHost      someone else's session holds it
--   false                            arguments rejected (secret/empty)
function PG.Session.Claim(module, token, host)
  local m, t, h = seatArgs(module, token, host)
  if not m then return false end
  if seat then
    if seat.module == m and seat.token == t then return true end
    return false, seat.module, seat.host
  end
  seat = { module = m, token = t, host = h }
  fireSeatChange(nil)
  return true
end

-- Referee hosting (I5). Hosting is NEVER blocked by the seat (I4), so this
-- always lets the caller proceed; it only reports which way.
--   true                          the host is a player in its own game
--   false, heldModule, heldHost   the host referees: no seat, no roster entry,
--                                 no buy-in, no pick, no ledger row for itself
-- hostOpen's single permitted PG.Session reference is this call, and it must
-- not be able to return early on the result.
function PG.Session.ClaimHost(module, token, host)
  local ok, heldModule, heldHost = PG.Session.Claim(module, token, host)
  if ok then return true end
  return false, heldModule, heldHost
end

-- No-op unless (module, token) currently holds the seat, so every teardown path
-- may call it unconditionally. Returns true if a seat was actually freed.
function PG.Session.Release(module, token)
  local m, t = seatArgs(module, token, nil)
  if not m then return false end
  if not seat or seat.module ~= m or seat.token ~= t then return false end
  local prev = seatView()
  seat = nil
  fireSeatChange(prev)
  return true
end

-- Read-only view of the seat, or nil. Copy: mutating it changes nothing.
function PG.Session.Seat() return seatView() end

-- "Busy" in CONCURRENCY.md 6.1 means exactly this and nothing else. Hosting is
-- not busy; holding lite records is not busy; a Pull Book is not busy.
function PG.Session.IsSeated() return seat ~= nil end

-- Does this exact session hold the seat? The cheap form of Seat() for the
-- per-record tests (a referee host answers false for its own session).
function PG.Session.Holds(module, token)
  local m, t = seatArgs(module, token, nil)
  if not m or not seat then return false end
  return seat.module == m and seat.token == t
end

-- fn(seat, prev) on every transition. This is how a module learns to withdraw
-- its outstanding invitations when the player seats themselves elsewhere
-- (CONCURRENCY.md 5.6 rule 3).
function PG.Session.OnChange(fn)
  if type(fn) ~= "function" then return end
  seatCbs[#seatCbs + 1] = fn
end

-------------------------------------------------------------------------------
-- Peers: who else in the group runs the addon, learned from CO|HELLO.
-------------------------------------------------------------------------------

PG.Peers = {} -- [fullName] = versionString, LIVE group members only (see peerPrune)

local peerSeen = {} -- [fullName] = GetTime() of last HELLO received
local lastHelloSent = 0
-- Fallback only: overwritten at init from the .toc via GetAddOnMetadata. It
-- still goes on the wire in CO HELLO on any build without that API, so it has
-- to be bumped with the .toc every release.
local addonVersion = "1.2.0"

-- PG.Peers answers exactly one question - "who else IN MY GROUP runs this
-- addon" - and both readers count the table DIRECTLY (LootGoblins.lua and
-- RockPaperScissors.lua each do `for _ in pairs(PG.Peers)` for the join
-- window's "N of M addon users" line, CONCURRENCY.md 6.3). So the table itself
-- has to shrink; a filtered accessor beside it would leave both shipped counts
-- wrong. Until 1.1.0 nothing removed an entry at all: leave the raid, change
-- groups, let a peer log out, and they stayed counted forever - inflating M in
-- the optimistic direction, telling a host that more people can join than can.
--
-- The proof of presence is the LIVE group, re-derived here rather than trusted
-- from a cache. An age-based expiry on peerSeen is deliberately NOT used as
-- well: HELLO is sparse by design (one per roster change, at most one a
-- minute), so a stable raid can run all night without a single one and any TTL
-- short enough to be useful would evict peers who never left.
local function peerPrune()
  if next(PG.Peers) == nil then return end
  local live = {}
  local function mark(unit)
    if not UnitExists(unit) then return end
    -- The one thing GROUP_ROSTER_UPDATE alone cannot tell us: an offline raid
    -- member keeps their slot in the roster, so presence is not membership.
    -- Only a definite `false` removes anyone: a secret or missing answer means
    -- "unknown", and unknown must not delete a peer who is standing right there.
    if UnitIsConnected then
      local conn = UnitIsConnected(unit)
      if not PG.IsSecret(conn) and conn == false then return end
    end
    local n = PG.FullName(unit)
    if n then live[n] = true end
  end
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do mark("raid" .. i) end
  elseif IsInGroup() then
    for i = 1, GetNumGroupMembers() - 1 do mark("party" .. i) end
  end
  -- "player" is deliberately absent: Comm drops self-delivered messages, so we
  -- are never in PG.Peers, which is why both readers render `peers + 1`. Solo,
  -- `live` stays empty and every entry goes, which is the correct answer for a
  -- group fact held by someone who is in no group.
  for name in pairs(PG.Peers) do
    if not live[name] then
      PG.Peers[name] = nil
      peerSeen[name] = nil
    end
  end
end

local function sendHello()
  if not (PG.Comm and PG.Comm.Broadcast) then return end
  lastHelloSent = GetTime()
  -- Scope LEADS on Broadcast since 0.6.0 (SCOPE.md 2.2). CO HELLO is always a
  -- group fact: it answers "who else in my party/raid runs this addon", which is
  -- what the host's join-window line counts (CONCURRENCY.md 6.3).
  PG.Comm.Broadcast("group", "CO", "HELLO", "-", addonVersion)
end

-- scope is the router's derived audience ("group"/"guild"/"public"/"private"),
-- passed to every handler since 0.6.0; ver is the peer's addon version.
local function onCoMessage(mtype, token, sender, scope, ver)
  if mtype ~= "HELLO" then return end
  -- PG.Peers is a group-scope fact and is rendered as "(N of M addon users)" in
  -- the host's join window: a guild or public HELLO must never inflate it.
  if scope ~= "group" and scope ~= "private" then return end
  if PG.IsSecret(ver) or type(ver) ~= "string" or ver == "" then ver = "?" end
  local now = GetTime()
  local last = peerSeen[sender]
  PG.Peers[sender] = ver
  peerSeen[sender] = now
  if not last or (now - last) > 60 then
    -- reply once, by whisper (never broadcast) to avoid reply storms, so the
    -- newly seen peer learns our version too
    PG.Comm.Whisper(sender, "CO", "HELLO", "-", addonVersion)
  end
end

PG.RegisterInit(function()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    addonVersion = C_AddOns.GetAddOnMetadata(ADDON, "Version") or addonVersion
  end
  if PG.Comm and PG.Comm.Register then PG.Comm.Register("CO", onCoMessage) end
  PG.RegisterEvent("GROUP_ROSTER_UPDATE", function()
    -- The only event that reports somebody arriving, leaving or going offline,
    -- so it is the only hook the prune needs; it fires long before any join
    -- window is drawn from the result.
    peerPrune()
    if GetTime() - lastHelloSent > 60 then sendHello() end
  end)
  PG.After(5, sendHello) -- initial hello, deferred past Comm's prefix registration
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function onSlash(msg)
  local cmd = tostring(msg or ""):lower():match("^%s*(%S*)") or ""
  if cmd == "lg" then
    if PG.LG and PG.LG.OpenDialog then PG.LG.OpenDialog() end
  elseif cmd == "book" then
    if PG.PB and PG.PB.OpenDialog then PG.PB.OpenDialog() end
  elseif cmd == "rps" then
    if PG.RPS and PG.RPS.OpenDialog then PG.RPS.OpenDialog() end
  -- Two-letter code AND a word for each of the 1.1.0 games: lg/book/rps
  -- established no single convention, and "gb" on its own is unguessable.
  elseif cmd == "dr" or cmd == "deathroll" then
    if PG.DR and PG.DR.OpenDialog then PG.DR.OpenDialog() end
  elseif cmd == "gb" or cmd == "gambler" then
    if PG.GB and PG.GB.OpenDialog then PG.GB.OpenDialog() end
  elseif cmd == "qz" or cmd == "quiz" then
    if PG.QZ and PG.QZ.OpenDialog then PG.QZ.OpenDialog() end
  elseif cmd == "rules" then
    if PG.Rules and PG.Rules.Toggle then PG.Rules.Toggle() end
  elseif cmd == "settings" then
    if PG.Settings and PG.Settings.Show then PG.Settings.Show() end
  elseif cmd == "ledger" then
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  elseif cmd == "dnd" then
    PG.ToggleDND()
  elseif cmd == "minimap" then
    if PG.Launcher and PG.Launcher.ToggleMinimap then PG.Launcher.ToggleMinimap() end
  elseif cmd == "comm" then
    local ld, pub = "n/a", "n/a"
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
      ld = tostring(C_ChatInfo.InChatMessagingLockdown())
    end
    if C_ChatInfo and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted then
      pub = tostring(C_ChatInfo.AreOutgoingAddonChatMessagesRestricted())
    end
    DEFAULT_CHAT_FRAME:AddMessage("PengyouGames comm: lockdown=" .. ld
      .. "  publicChatRestricted=" .. pub .. " (info only, not used as a gate)"
      .. "  -> Locked=" .. tostring(PG.Comm.Locked()))
    -- SCOPE.md 5.7: the audience diagnostic. Availability is a live query, so
    -- this line is the one place a user can see why a segment is greyed out.
    if PG.Comm.ScopeAvailable then
      local parts = {}
      local names = { "group", "guild", "public" }
      for i = 1, #names do
        local okS, why = PG.Comm.ScopeAvailable(names[i])
        parts[i] = names[i] .. "=" .. (okS and "ok" or tostring(why or "no"))
      end
      local idx = PG.Comm.PublicIndex and PG.Comm.PublicIndex()
      DEFAULT_CHAT_FRAME:AddMessage("PengyouGames scope: " .. table.concat(parts, "  ")
        .. "  publicIndex=" .. (idx and tostring(idx) or "none"))
    end
  elseif cmd == "rolls" then
    -- The /roll parser is built from this client's own RANDOM_ROLL_RESULT and
    -- self-tests at init (BRIEF 3.2). When it fails, Death Roll and Gambler
    -- refuse to start and the cause is a locale string nobody can see, so this
    -- makes it visible in one command - the same job /pg comm does for the send
    -- gates. It is also the fastest way to answer "did my roll register?".
    if not (PG.Rolls and PG.Rolls.Ready) then
      DEFAULT_CHAT_FRAME:AddMessage("PengyouGames rolls: module not loaded.")
    else
      local ready = PG.Rolls.Ready()
      DEFAULT_CHAT_FRAME:AddMessage("PengyouGames rolls: patternSelfTest="
        .. (ready and "PASSED" or "FAILED")
        .. "  canRollForYou=" .. tostring(PG.Rolls.Available())
        .. "  RandomRoll=" .. type(_G.RandomRoll))
      DEFAULT_CHAT_FRAME:AddMessage("PengyouGames rolls: format=" .. tostring(_G.RANDOM_ROLL_RESULT)
        .. (ready and "" or "  -> Death Roll and Gambler will refuse to start on this client"))
      local seen = PG.Rolls.Since(0)
      DEFAULT_CHAT_FRAME:AddMessage("PengyouGames rolls: " .. #seen .. " observed recently"
        .. " (only while out of encounter, ready check and pull timer)")
      for i = math.max(1, #seen - 2), #seen do
        local r = seen[i]
        DEFAULT_CHAT_FRAME:AddMessage("  " .. r.name .. " rolled " .. r.value
          .. " (" .. r.low .. "-" .. r.high .. ")")
      end
    end
  elseif cmd == "help" then
    -- Six games make "an unrecognized subcommand just opens the launcher" stop
    -- being discoverable.
    local f = DEFAULT_CHAT_FRAME
    f:AddMessage("PengyouGames commands (everything prints only to you):")
    f:AddMessage("  /pg                                    open the launcher")
    f:AddMessage("  /pg lg | book | rps | dr | gb | quiz   start that game")
    f:AddMessage("  /pg rules                              how to play")
    f:AddMessage("  /pg ledger                             tonight's nets and Settle Up")
    f:AddMessage("  /pg settings                           sounds, DND, minimap, scale")
    f:AddMessage("  /pg dnd | minimap | comm | rolls | debug")
  elseif cmd == "debug" then
    PG.debug = not PG.debug
    DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: debug " .. (PG.debug and "ON" or "OFF"))
  else
    if PG.Launcher and PG.Launcher.Toggle then PG.Launcher.Toggle() end
  end
end

PG.RegisterInit(function()
  -- SLASH_* globals + a SlashCmdList entry are the platform's slash mechanism
  _G.SLASH_PENGYOU1 = "/pengyou"
  _G.SLASH_PENGYOU2 = "/pg"
  SlashCmdList["PENGYOU"] = onSlash
end)
