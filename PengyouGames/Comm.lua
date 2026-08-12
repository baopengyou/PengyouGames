-- Comm.lua - protocol codec, send queue (token bucket), lockdown gating, router.
local ADDON, PG = ...

PG.Comm = {}

local PREFIX = "PENGYOU"
local WIRE_VERSION = "2" -- v2: adds the RPS module (0.1.x clients politely excluded)
local MAX_BYTES = 250

-- Refusal codes with literal fallbacks per spec 2.1: lockdown (11) is a
-- permanent refusal for that message, throttle (3) is transient.
local sarEnum = Enum and Enum.SendAddonMessageResult
local RESULT_LOCKDOWN = (sarEnum and sarEnum.AddOnMessageLockdown) or 11
local RESULT_THROTTLE = (sarEnum and sarEnum.AddonMessageThrottle) or 3

local moduleHandlers = {} -- module -> handler(mtype, token, sender, f1, f2, ...)
local moduleDrops = {}    -- module -> onDrop(mtype)

-- Client-side token bucket matching the per-prefix server throttle:
-- capacity 10, regenerating 1/sec.
local BUCKET_CAP = 10
local tokens = BUCKET_CAP
local lastRefill = nil
local queue = {}
local pumpScheduled = false
local warnedVersion = false

local function debugLine(text)
  if PG.debug and DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffPG|r " .. text)
  end
end

-- True while the 12.1 comms lockdown refuses addon sends (encounter / M+ / PvP).
-- ONLY InChatMessagingLockdown may be consulted here: the similarly named
-- AreOutgoingAddonChatMessagesRestricted() governs addons sending PUBLIC chat
-- (SendChatMessage) and is true on every normal realm, always -- gating on it
-- blocked every send everywhere (the v0.1.1 "addon messages are blocked" bug).
-- Result code 11 (AddOnMessageLockdown) on actual sends remains the backstop.
function PG.Comm.Locked()
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    return C_ChatInfo.InChatMessagingLockdown() == true
  end
  return false
end

local function encode(module, mtype, token, ...)
  local msg = WIRE_VERSION .. "|" .. module .. "|" .. mtype .. "|" .. tostring(token)
  local n = select("#", ...)
  if n > 0 then
    local fields = {}
    for i = 1, n do fields[i] = tostring((select(i, ...))) end
    msg = msg .. "|" .. table.concat(fields, "|")
  end
  return msg
end

local function dropEntry(entry, why)
  debugLine("dropped (" .. why .. ") " .. entry.msg)
  local onDrop = moduleDrops[entry.module]
  if onDrop then pcall(onDrop, entry.mtype) end
end

local function rawSend(entry)
  local result
  if entry.target then
    result = C_ChatInfo.SendAddonMessage(PREFIX, entry.msg, "WHISPER", entry.target)
  else
    result = C_ChatInfo.SendAddonMessage(PREFIX, entry.msg, entry.channel)
  end
  debugLine("sent [" .. (entry.target and ("whisper:" .. entry.target) or entry.channel) .. "] " .. entry.msg)
  if type(result) ~= "number" then return 0 end -- non-Enum API shapes: treat as success
  return result
end

local pump

local function schedulePump(delay)
  if pumpScheduled then return end
  pumpScheduled = true
  PG.After(delay, function()
    pumpScheduled = false
    pump()
  end)
end

local function refill()
  local now = GetTime()
  if lastRefill then
    tokens = math.min(BUCKET_CAP, tokens + (now - lastRefill))
  end
  lastRefill = now
end

pump = function()
  refill()
  while queue[1] do
    if PG.Comm.Locked() then
      -- lockdown refusal is permanent for this message: drop, never retry
      dropEntry(table.remove(queue, 1), "lockdown")
    elseif tokens < 1 then
      schedulePump(1 - tokens + 0.05)
      return
    else
      local entry = table.remove(queue, 1)
      tokens = tokens - 1
      local result = rawSend(entry)
      if result == RESULT_THROTTLE then
        table.insert(queue, 1, entry) -- transient: same message retries after backoff
        schedulePump(1.2)
        return
      elseif result == RESULT_LOCKDOWN then
        dropEntry(entry, "lockdown")
      elseif entry.onSent then
        -- the message actually left the wire (queued-then-dropped ones never
        -- get here): senders that must not act on a merely-queued message
        -- (LG END, PB FD/BET) commit their local state from this callback
        local ok, err = pcall(entry.onSent)
        if not ok then geterrorhandler()(err) end
      end
    end
  end
end

local function submit(entry)
  if #entry.msg > MAX_BYTES then
    -- oversized wire message is a programming bug: loud in debug, drop in release
    if PG.debug then
      geterrorhandler()("PengyouGames: message over " .. MAX_BYTES .. " bytes: " .. entry.msg)
    end
    return false
  end
  if PG.Comm.Locked() then
    dropEntry(entry, "lockdown")
    return false
  end
  queue[#queue + 1] = entry
  if not pumpScheduled then pump() end
  return true
end

-- handler(mtype, token, sender, f1, f2, ...) receives every message for
-- 'module' ("CO", "LG", "PB"). onDrop(mtype), optional, is called when an
-- OUTGOING message of this module is dropped by the comms lockdown (the drop
-- is permanent; the message is gone).
function PG.Comm.Register(module, handler, onDrop)
  moduleHandlers[module] = handler
  moduleDrops[module] = onDrop
end

local function pickChannel()
  if IsInRaid() then
    return "RAID"
  elseif IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  elseif IsInGroup() then
    return "PARTY"
  end
  return nil
end

-- Group broadcast with per-message callbacks: opts.onSent fires exactly once,
-- after the message has actually gone out (never for a message that was
-- queued and later dropped by the lockdown; may fire synchronously inside
-- this call when the bucket has tokens). Channel: RAID > INSTANCE_CHAT >
-- PARTY; not grouped -> dropped. Returns true if the message was queued/sent.
function PG.Comm.BroadcastEx(opts, module, mtype, token, ...)
  local channel = pickChannel()
  if not channel then return false end
  return submit({
    msg = encode(module, mtype, token, ...),
    channel = channel,
    module = module,
    mtype = mtype,
    onSent = opts and opts.onSent,
  })
end

function PG.Comm.Broadcast(module, mtype, token, ...)
  return PG.Comm.BroadcastEx(nil, module, mtype, token, ...)
end

function PG.Comm.Whisper(target, module, mtype, token, ...)
  if type(target) ~= "string" or target == "" then return false end
  return submit({ msg = encode(module, mtype, token, ...), target = target, module = module, mtype = mtype })
end

-- Provenance guard: CHAT_MSG_ADDON also delivers WHISPERs from arbitrary
-- non-group players once the prefix is registered, but every legitimate
-- sender for every module (host/bookie broadcasts, JOIN/UNJOIN/PICK whispers,
-- CO HELLO replies) is by definition in our group. Anything else is dropped
-- before it reaches a game handler - a stranger must never be able to drive
-- a fake session into the persisted ledger. Names are built with PG.FullName
-- so realm normalization matches PG.NormalizeSender exactly.
local groupNames = {}

local function rebuildGroupNames()
  wipe(groupNames)
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local n = PG.FullName("raid" .. i)
      if n then groupNames[n] = true end
    end
  elseif IsInGroup() then
    local n = PG.FullName("player")
    if n then groupNames[n] = true end
    for i = 1, GetNumGroupMembers() - 1 do
      n = PG.FullName("party" .. i)
      if n then groupNames[n] = true end
    end
  end
end

local function isGroupSender(sender)
  if groupNames[sender] then return true end
  rebuildGroupNames() -- a message can beat our GROUP_ROSTER_UPDATE handler
  return groupNames[sender] == true
end

local function onChatMsgAddon(_, prefix, message, _, sender)
  if PG.IsSecret(prefix) or prefix ~= PREFIX then return end
  if PG.IsSecret(message) or type(message) ~= "string" then return end
  sender = PG.NormalizeSender(sender)
  if not sender then return end
  -- self-broadcast ignore: behavior must never depend on self-delivery; every
  -- host/bookie processes its own outgoing state locally at send time
  if sender == PG.FullName("player") then return end
  if not isGroupSender(sender) then return end
  local parts = { strsplit("|", message) }
  if parts[1] ~= WIRE_VERSION then
    if not warnedVersion then
      warnedVersion = true
      DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: ignoring messages from an unknown protocol version (a raid member may run a newer addon).")
    end
    return
  end
  local module, mtype, token = parts[2], parts[3], parts[4]
  if not (module and mtype and token) then return end
  debugLine("recv [" .. sender .. "] " .. message)
  local handler = moduleHandlers[module]
  if handler then
    local ok, err = pcall(handler, mtype, token, sender, unpack(parts, 5))
    if not ok then geterrorhandler()(err) end
  end
end

PG.RegisterInit(function()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  end
  rebuildGroupNames()
  PG.RegisterEvent("GROUP_ROSTER_UPDATE", rebuildGroupNames)
  PG.RegisterEvent("CHAT_MSG_ADDON", onChatMsgAddon)
end)
