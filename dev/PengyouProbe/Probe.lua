-- PengyouProbe/Probe.lua -- the M0 field probe from the Idle Battle build
-- order ("P - the Probe. Half a day in a real raid, off the critical path,
-- calibrates every rate"). A standalone micro-addon, deliberately NOT part of
-- PengyouGames or the dev build: install just this folder on the raiding
-- machine, raid one normal night, then /probe export and paste the dump back.
--
-- WHAT IT MEASURES, and why each matters to the netcode:
--   * WHEN C_ChatInfo.InChatMessagingLockdown() actually flips, sampled at
--     10 Hz, stamped against the events around it (ENCOUNTER_START/END, ready
--     check, countdown, combat edges, M+). The design assumes the lockdown is
--     encounter/M+/PvP-scoped; this measures the real boundaries and the
--     ORDER of flip vs event, which M6's halt/resume timing needs.
--   * WHAT SendAddonMessage RETURNS across those boundaries: a 5-second
--     self-whisper records the Enum.SendAddonMessageResult code of a real
--     send attempt in every state, plus whether the message was actually
--     DELIVERED (its own echo coming back) -- "refused with code X" vs
--     "accepted and eaten" are different failure modes and only a live realm
--     answers which one lockdown produces.
--   * THE PER-PREFIX THROTTLE, on demand only: /probe burst sends 15
--     back-to-back and records where results turn from success to throttled
--     (the assumed 10-burst / 1-per-second bucket). Refuses to run in a group
--     or instance -- never stress the channel during somebody's raid.
--
-- WHAT IT NEVER DOES: no public chat, no sounds, no secure frames, no
-- combat-log registration (CLEU registration is restricted in 12.1), no
-- traffic beyond the 0.2 msg/s self-whisper and the manual burst. Everything
-- lands in PengyouProbeDB as flat strings; /probe export shows a copyable
-- window. Entries: SESS login header, LOCK lockdown flip, EV event, SEND
-- probe result, RECV echo, BURST result, MARK user note, ERR.

local PREFIX = "PGPROBE"
local CAP = 20000         -- ring buffer cap. NOT "well under" territory: the
                          -- probe's own SEND+RECV pairs alone run ~1,450
                          -- lines/hour outside lockdown (M5 review, measured),
                          -- and the log persists across sessions -- 20,000
                          -- lines (~1.5 MB of SavedVariables) holds a long
                          -- night plus pre-raid play without evicting the
                          -- early hours
local PROBE_EVERY = 5     -- seconds between self-whisper probes
local POLL = 0.1          -- lockdown poll cadence

local f = CreateFrame("Frame")
local db
local lastLock = nil      -- last observed lockdown state (nil = not yet read)
local seq = 0             -- self-whisper sequence
local sentAt = {}         -- [seq] = precise send time, for echo deltas
local active = true       -- the 5 s probe ticker state (persisted)
local exportWin

local function now()
  if GetTimePreciseSec then return GetTimePreciseSec() end
  return GetTime()
end

local function say(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffProbe|r " .. text)
end

-- 12.1 secret values hard-error on compare/index; anything that came out of
-- an event payload goes through these before it is compared or concatenated.
local function isSecret(v)
  local f = rawget(_G, "issecretvalue")
  return (f and f(v)) and true or false
end

local function safeStr(v)
  if isSecret(v) then return "<secret>" end
  return tostring(v)
end

-- One compact context snapshot: group kind+size, instance type+difficulty,
-- combat flag, our own encounter flag (tracked from ENCOUNTER_START/END).
local inEncounter = false
local function ctx()
  local grp = "solo"
  if IsInRaid() then grp = "raid" .. GetNumGroupMembers()
  elseif IsInGroup() then grp = "party" .. GetNumGroupMembers() end
  local _, itype, diff = GetInstanceInfo()
  local c = InCombatLockdown() and "combat" or "calm"
  local e = inEncounter and "enc" or "noenc"
  return grp .. "," .. tostring(itype) .. tostring(diff or "") .. "," .. c .. "," .. e
end

local function log(code, detail)
  if not db then return end
  local line = string.format("%.3f|%s|%s", now(), code, detail or "")
  local n = #db.log
  if n >= CAP then
    table.remove(db.log, 1)
    n = n - 1
  end
  db.log[n + 1] = line
end

-- Reverse map of Enum.SendAddonMessageResult, built once so SEND lines carry
-- the name beside the number (numbers are the ground truth if the map is
-- empty on this client).
local RESULT_NAME = {}
do
  local E = rawget(_G, "Enum")
  local T = E and E.SendAddonMessageResult
  if type(T) == "table" then
    for name, v in pairs(T) do
      if type(v) == "number" then RESULT_NAME[v] = name end
    end
  end
end
local function resultStr(r)
  if r == nil then return "nil" end
  local n = tonumber(r)
  if n and RESULT_NAME[n] then return n .. ":" .. RESULT_NAME[n] end
  return tostring(r)
end

local function myFullName()
  local name, realm = UnitFullName("player")
  if not name then return nil end
  if realm and realm ~= "" then return name .. "-" .. realm end
  -- own realm can come back empty at early login; GetNormalizedRealmName is
  -- the documented fallback for the player's own realm
  local r = GetNormalizedRealmName and GetNormalizedRealmName()
  if r and r ~= "" then return name .. "-" .. r end
  return name
end

local function lockdownNow()
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    return C_ChatInfo.InChatMessagingLockdown() == true
  end
  return nil
end

-------------------------------------------------------------------------------
-- The 10 Hz lockdown poll: log only the FLIPS, with context both sides.
-------------------------------------------------------------------------------

local acc = 0
f:SetScript("OnUpdate", function(_, dt)
  acc = acc + dt
  if acc < POLL then return end
  acc = 0
  local lock = lockdownNow()
  if lock == nil then return end
  if lastLock == nil then
    lastLock = lock
    log("LOCK", "initial " .. tostring(lock) .. " [" .. ctx() .. "]")
    return
  end
  if lock ~= lastLock then
    lastLock = lock
    log("LOCK", tostring(lock) .. " [" .. ctx() .. "]")
  end
end)

-------------------------------------------------------------------------------
-- The 5-second self-whisper: result code on send, echo on delivery.
-------------------------------------------------------------------------------

local function probeSend(tag)
  local me = myFullName()
  if not me then return end
  seq = seq + 1
  sentAt[seq] = now()
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, "p" .. seq, "WHISPER", me)
  if not ok then
    log("ERR", "send raised: " .. tostring(res))
    return
  end
  log(tag or "SEND", "#" .. seq .. " -> " .. resultStr(res)
    .. " lock=" .. tostring(lockdownNow()) .. " [" .. ctx() .. "]")
end

local ticker
local function syncTicker()
  if active and not ticker then
    ticker = C_Timer.NewTicker(PROBE_EVERY, function() probeSend("SEND") end)
  elseif not active and ticker then
    ticker:Cancel()
    ticker = nil
  end
end

-------------------------------------------------------------------------------
-- Events. pcall every registration and LOG a refused one -- "this event no
-- longer exists / may not be registered in 12.1" is itself field data.
-------------------------------------------------------------------------------

local EVENTS = {
  "ENCOUNTER_START", "ENCOUNTER_END",
  "READY_CHECK", "READY_CHECK_FINISHED",
  -- both countdown events: START_PLAYER_COUNTDOWN is what a retail raid
  -- pull countdown (C_PartyInfo.DoCountdown, DBM/BigWigs /pull) actually
  -- fires; START_TIMER is instance/PvP start timers (M5 review)
  "START_TIMER", "START_PLAYER_COUNTDOWN", "CANCEL_PLAYER_COUNTDOWN",
  "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET",
  "PLAYER_ENTERING_WORLD",
  -- the design's own named confirmation target: does this fire, and does it
  -- fire BEFORE the restriction activates (the pre-activation send below
  -- measures exactly that)
  "ADDON_RESTRICTION_STATE_CHANGED",
  "CHAT_MSG_ADDON",
}

local function onEvent(_, event, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, msg, channel, sender = ...
    if isSecret(prefix) or prefix ~= PREFIX then return end
    if isSecret(sender) or isSecret(msg) then return end
    local me = myFullName()
    if sender ~= me and sender ~= (UnitName("player")) then return end
    local n = tonumber(tostring(msg):match("^p(%d+)$") or "")
    local dt = ""
    if n and sentAt[n] then
      dt = string.format(" +%.0fms", (now() - sentAt[n]) * 1000)
      sentAt[n] = nil
    end
    log("RECV", "#" .. tostring(n or "?") .. dt .. " via " .. safeStr(channel))
    return
  end
  if event == "ENCOUNTER_START" then inEncounter = true end
  if event == "ENCOUNTER_END" then inEncounter = false end
  local parts = { event }
  local args = { ... }
  for i = 1, math.min(#args, 6) do
    parts[#parts + 1] = safeStr(args[i])
  end
  log("EV", table.concat(parts, " ") .. " lock=" .. tostring(lockdownNow()))
  -- an event that can flank a lockdown flip is worth a send result RIGHT
  -- HERE, not up to 5 s later -- but never from inside the encounter itself:
  -- passive observation is the contract mid-fight, and the 5 s cadence still
  -- samples that state. ADDON_RESTRICTION_STATE_CHANGED is the prize: it is
  -- documented to fire BEFORE the restriction activates, and this send is
  -- the direct measurement of whether that pre-activation window is usable.
  if event == "READY_CHECK" or event == "START_TIMER"
    or event == "START_PLAYER_COUNTDOWN" or event == "CANCEL_PLAYER_COUNTDOWN"
    or event == "ADDON_RESTRICTION_STATE_CHANGED" or event == "ENCOUNTER_END" then
    if active then probeSend("SEND") end
  end
end

-------------------------------------------------------------------------------
-- Export window: last N lines in a copyable box.
-------------------------------------------------------------------------------

local function showExport(n)
  -- default is the WHOLE log: a silent 1000-line default was under an hour
  -- of a raid night, and the truncated dump looked complete (M5 review)
  n = math.min(n or #db.log, #db.log)
  if not exportWin then
    exportWin = CreateFrame("Frame", "PengyouProbeExport", UIParent, "BasicFrameTemplateWithInset")
    exportWin:SetSize(560, 420)
    exportWin:SetPoint("CENTER")
    exportWin:SetMovable(true)
    exportWin:EnableMouse(true)
    exportWin:RegisterForDrag("LeftButton")
    exportWin:SetScript("OnDragStart", exportWin.StartMoving)
    exportWin:SetScript("OnDragStop", exportWin.StopMovingOrSizing)
    local scroll = CreateFrame("ScrollFrame", nil, exportWin, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(500)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function(b) b:ClearFocus() end)
    scroll:SetScrollChild(box)
    exportWin.box = box
  end
  -- truncation is visible in the title, never silent
  if exportWin.TitleText then
    exportWin.TitleText:SetText(string.format(
      "Pengyou Probe export - %d of %d lines (Ctrl-A, Ctrl-C)", n, #db.log))
  end
  local from = #db.log - n + 1
  local out = {}
  for i = math.max(1, from), #db.log do
    out[#out + 1] = db.log[i]
  end
  exportWin.box:SetText(table.concat(out, "\n"))
  exportWin.box:HighlightText()
  exportWin:Show()
end

-------------------------------------------------------------------------------
-- /probe
-------------------------------------------------------------------------------

SLASH_PENGYOUPROBE1 = "/probe"
SlashCmdList.PENGYOUPROBE = function(msg)
  msg = tostring(msg or "")
  local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "export" then
    showExport(tonumber(rest))
  elseif cmd == "wipe" then
    db.log = {}
    say("log wiped.")
  elseif cmd == "mark" then
    log("MARK", rest ~= "" and rest or "(mark)")
    say("marked: " .. (rest ~= "" and rest or "(mark)"))
  elseif cmd == "active" then
    if rest == "on" then active = true elseif rest == "off" then active = false end
    db.active = active
    syncTicker()
    say("probe sends " .. (active and "ON (every " .. PROBE_EVERY .. "s)" or "OFF") .. ".")
  elseif cmd == "burst" then
    if IsInGroup() or IsInInstance() then
      say("burst refused: leave the group/instance first -- never stress the channel mid-raid.")
      return
    end
    say("burst: 15 back-to-back sends, watching for the throttle edge...")
    for i = 1, 15 do probeSend("BURST") end
  else
    say(#db.log .. "/" .. CAP .. " entries; sends " .. (active and "ON" or "OFF")
      .. "; lockdown " .. tostring(lockdownNow()) .. ".")
    say("/probe export [n] | mark <note> | active on|off | burst | wipe")
    say("SavedVariables flush only on /reload or logout - an occasional /reload"
      .. " between pulls checkpoints the night against a client crash.")
  end
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, arg1, ...)
  if event == "ADDON_LOADED" then
    if arg1 ~= "PengyouProbe" then return end
    self:UnregisterEvent("ADDON_LOADED")
    PengyouProbeDB = PengyouProbeDB or { v = 1, log = {} }
    db = PengyouProbeDB
    db.log = db.log or {}
    if db.active == false then active = false end
    local reg = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix
      and C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    -- a /reload mid-boss must not leave the encounter flag stale (M5 review)
    if IsEncounterInProgress then
      local ok, inEnc = pcall(IsEncounterInProgress)
      inEncounter = (ok and inEnc) and true or false
    end
    log("SESS", date("%Y-%m-%d %H:%M:%S") .. " login, prefix reg " .. tostring(reg)
      .. ", build " .. tostring((GetBuildInfo())) .. " [" .. ctx() .. "]")
    if #db.log > CAP / 2 then
      say("log " .. #db.log .. "/" .. CAP .. " lines - consider /probe wipe before the raid.")
    end
    -- hourly wall-clock anchor: however the ring turns over, a capped log
    -- always retains at least one line that ties the monotonic stamps to
    -- the clock on the wall (M5 review: eviction is oldest-first and the
    -- login SESS header was the first casualty)
    C_Timer.NewTicker(3600, function()
      log("SESS", date("%Y-%m-%d %H:%M:%S") .. " hourly anchor [" .. ctx() .. "]")
    end)
    for i = 1, #EVENTS do
      local ok, err = pcall(self.RegisterEvent, self, EVENTS[i])
      if not ok then
        log("ERR", "cannot register " .. EVENTS[i] .. ": " .. tostring(err))
      end
    end
    self:SetScript("OnEvent", onEvent)
    syncTicker()
    say("logging. /probe for status, /probe export after the raid.")
    return
  end
end)
