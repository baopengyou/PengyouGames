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
    scope = { LG = "group", RPS = "group", PB = "group" },
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
  if type(_G.PengyouGamesDevDB) ~= "table" then _G.PengyouGamesDevDB = {} end
  copyDefaults(_G.PengyouGamesDevDB, DB_DEFAULTS)
  PG.db = _G.PengyouGamesDevDB
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
--   I1  One seat, globally, across LG and RPS combined. `seat` below is
--       single-valued or nil, and PG.Session.Claim / PG.Session.Release are its
--       only writers - no module may write it directly.
--   I2  The seat spans join (or self-seating host) through phase == "done" and
--       nothing else. Release from endSession and the withdrawal path only; the
--       reveal stage, podium, results window and record memory never hold it.
--   I5  Referee hosting: a player seated in one module may HOST in the other
--       without taking a second seat. PG.Session.ClaimHost is that rule; it
--       cannot refuse, so hosting is never blocked (I4).
--   I10 The Pull Book neither claims nor consults the seat - it is passive
--       pre-pull betting and runs alongside anything. PullBook.lua must contain
--       zero references to PG.Session, permanently.
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

PG.Peers = {} -- [fullName] = versionString

local peerSeen = {} -- [fullName] = GetTime() of last HELLO received
local lastHelloSent = 0
local addonVersion = "0.6.0"

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
  elseif cmd == "ib" then
    -- Idle Battle (DEV, M5): "/pgd ib" opens the start dialog, "/pgd ib
    -- selftest" runs the in-game determinism check, "/pgd ib status" the
    -- session/netcode diagnostic.
    local sub = tostring(msg or ""):lower():match("^%s*%S+%s+(%S+)") or ""
    if PG.IB and PG.IB.Slash then PG.IB.Slash(sub) end
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
  elseif cmd == "debug" then
    PG.debug = not PG.debug
    DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: debug " .. (PG.debug and "ON" or "OFF"))
  else
    if PG.Launcher and PG.Launcher.Toggle then PG.Launcher.Toggle() end
  end
end

PG.RegisterInit(function()
  -- SLASH_* globals + a SlashCmdList entry are the platform's slash mechanism
  _G.SLASH_PENGYOUDEV1 = "/pengyoudev"
  _G.SLASH_PENGYOUDEV2 = "/pgd"
  SlashCmdList["PENGYOUDEV"] = onSlash
end)
