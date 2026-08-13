-- Comm.lua - protocol codec, send queue (token bucket), lockdown gating,
-- scope-aware transport (party / guild / public realm channel), router.
local ADDON, PG = ...

PG.Comm = {}

local PREFIX = "PENGYOU"
-- v3 (0.6.0): the scope selector plus the trust and ledger rules that ship
-- with it. The two extra bytes on OPEN are not the reason for the bump: a v2
-- client would mirror a wide-scope session under v2 rules and persist ledger
-- rows every v3 participant deliberately refused to write, so v2 and v3 must
-- never play together (SCOPE.md 3.4).
-- v4 (1.2.0): Death Roll and Gambler stopped adjudicating rolls from
-- CHAT_MSG_SYSTEM and now take a ROLLED whisper from each player's own client.
-- The bump is NOT because a field moved - a v3 client would simply drop an
-- unknown mtype. It is because of what a v3 client would DO at a v4 table: it
-- never sends ROLLED, the v4 host no longer watches chat for anybody else, so
-- that player is scored as a no-show and PAYS THE WAGER, silently, with no way
-- to know why. That is a divergent ledger between participants of one game,
-- which is the same thing the v2->v3 bump was made for (SCOPE.md 3.4). The cost
-- is that v3 and v4 cannot play Loot Goblins, Pull Book or RPS together either;
-- a visible "everyone needs to update" beats quietly taking somebody's gold.
local WIRE_VERSION = "4"
local MAX_BYTES = 250

-- Scope (audience) enum. Exactly three values; the wire code travels as the
-- trailing field of OPEN and exists to be CHECKED against the delivered
-- distribution, never trusted (SCOPE.md 3.1). "private" is a router output for
-- WHISPER traffic only: never a session scope, never on the wire.
local SCOPES = { group = "P", guild = "G", public = "R" }
local SCOPE_OF = { P = "group", G = "guild", R = "public" }

-- Channel names may not contain "-". The password is not a secret and is not
-- pretending to be one: it stops a squatter who created the channel without
-- one from locking us out cheaply, and keeps casual /join-ers out.
local PUBLIC_CHANNEL = "PengyouGamesRealm"
local PUBLIC_PASSWORD = "pgv1"
local PUBLIC_LOWER = PUBLIC_CHANNEL:lower()

-- Send result codes. Existence-guarded with the literal fallbacks from
-- SPEC.md 2.1 / SCOPE.md 2.1, because Enum may be absent or renamed:
--   lockdown (11)        permanent for that message  -> drop, never retry
--   throttle (3)         transient                   -> requeue with backoff
--   ChannelThrottle (8)  transient                   -> requeue with backoff
--   InvalidChannel (7)   our channel index went stale -> drop + rejoin
--   InvalidChatType (4)  CHANNEL unusable on this client -> permanent, never retry
local sarEnum = Enum and Enum.SendAddonMessageResult

local function sarCode(name, fallback)
  local v = sarEnum and sarEnum[name]
  if type(v) == "number" then return v end
  return fallback
end

local RESULT_SUCCESS = sarCode("Success", 0)
local RESULT_THROTTLE = sarCode("AddonMessageThrottle", 3)
local RESULT_INVALID_CHAT_TYPE = sarCode("InvalidChatType", 4)
local RESULT_INVALID_CHANNEL = sarCode("InvalidChannel", 7)
local RESULT_CHANNEL_THROTTLE = sarCode("ChannelThrottle", 8)
local RESULT_LOCKDOWN = sarCode("AddOnMessageLockdown", 11)

local moduleHandlers = {} -- module -> handler(mtype, token, sender, scope, f1, f2, ...)
local moduleDrops = {}    -- module -> onDrop(mtype, token)
local moduleTrust = {}    -- module -> fn(sender) -> boolean, for WHISPER only

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

-------------------------------------------------------------------------------
-- Scope accessors. Games never hardcode a wire letter.
-------------------------------------------------------------------------------

function PG.Comm.ScopeCode(scope)
  local s = PG.SafeStr(scope)
  return s and SCOPES[s] or nil
end

function PG.Comm.ScopeOfCode(code)
  local c = PG.SafeStr(code)
  return c and SCOPE_OF[c] or nil
end

-------------------------------------------------------------------------------
-- The public realm channel.
--
-- Joined with JoinTemporaryChannel, never JoinPermanentChannel: a permanent
-- join is written into the user's saved channel list and re-joined after every
-- relog, INCLUDING after the addon is uninstalled. A temporary channel is
-- dropped at logout and never touches the user's config.
-------------------------------------------------------------------------------

local publicWanted = false      -- we want to be in the channel (opt-in / explicit join)
local publicBroken = false      -- InvalidChatType seen: permanent capability failure
local publicBanned = false      -- BANNED notice: no grace, abort live sessions
local publicAttemptAt = 0       -- GetTime() of the last completed join attempt
local publicSeenAt = 0          -- GetTime() when the index last resolved non-zero
local publicBackoffUntil = 0    -- never hammer a join
local publicUsePassword = true  -- WRONG_PASSWORD alternates this
local joinPending = false
local joinDeadline = 0
local scheduleJoin

-- Ten seconds of settle-detection belongs to the LOGIN join only: that is when
-- the General/Trade/LocalDefense channels trickle in and an early join steals a
-- low /N slot from the user's own channels. A rejoin after a loading screen has
-- to LAND inside the 8s host-abort grace (SCOPE.md 6.1), so its window must fit
-- inside it - otherwise the host of a public game who takes a portal watches
-- serviceMine abandon the session while the rejoin is still waiting to settle.
local SETTLE_LOGIN = 10
local SETTLE_REJOIN = 2
-- A join issued inside the 12.1 comms lockdown (encounter / M+ / PvP) can fail
-- with no signal at all, which burns an attempt AND latches the wrong
-- diagnostic. Wait it out - but never longer than this, because an entire M+ run
-- is one lockdown and a client deaf to every OPEN for that whole run is worse
-- than one that tried and failed. A REJOIN waits only its own settle window
-- (SETTLE_REJOIN): it has to land inside the 8s host-abort grace, so trading
-- that grace for a tidier join would abort the very session it protects.
local JOIN_LOCK_WAIT = 30
-- The join is asynchronous and "index still 0" is the only failure signal there
-- is, so believe it only after a bounded number of verified attempts.
local JOIN_VERIFY = 5
local JOIN_MAX_TRIES = 3
local joinTries = 0
local joinLockUntil = 0

local function publicOptIn()
  local p = PG.db and PG.db.profile
  return (p and p.publicOptIn) and true or false
end

-- Numeric /N index, never the name. Indices shift whenever the player joins or
-- leaves any channel (Trade is joined and left on every city boundary), so this
-- is re-resolved on EVERY send and never cached anywhere.
function PG.Comm.PublicIndex()
  if type(GetChannelName) ~= "function" then return nil end
  local ok, id = pcall(GetChannelName, PUBLIC_CHANNEL)
  if not ok then return nil end
  if PG.IsSecret(id) or type(id) ~= "number" or id == 0 then return nil end
  publicSeenAt = GetTime()
  return id
end

local function isPublicChannelName(v)
  local s = PG.SafeStr(v)
  if not s then return false end
  s = s:lower()
  if s == PUBLIC_LOWER then return true end
  -- chat events carry "5. pengyougamesrealm" in the "channel" argument
  local tail = s:match("^%s*%d+%.%s*(.+)$")
  return tail == PUBLIC_LOWER
end

-- One helper for both shapes: CHAT_MSG_ADDON carries the channel name in arg8,
-- the CHAT_MSG_CHANNEL_* display events carry it in arg9 (and decorated in arg4).
local function aboutPublic(a4, a8, a9)
  return isPublicChannelName(a9) or isPublicChannelName(a8) or isPublicChannelName(a4)
end

-- Suppression 1: drop the channel out of every chat frame's message list.
local function hideChannel()
  if type(ChatFrame_RemoveChannel) ~= "function" then return end
  local n = NUM_CHAT_WINDOWS or 10
  for i = 1, n do
    local f = _G["ChatFrame" .. i]
    if f then pcall(ChatFrame_RemoveChannel, f, PUBLIC_CHANNEL) end
  end
end

-- Suppression 2: the five channel display events, filtered only for our channel.
local FILTER_EVENTS = {
  "CHAT_MSG_CHANNEL_JOIN",
  "CHAT_MSG_CHANNEL_LEAVE",
  "CHAT_MSG_CHANNEL_NOTICE",
  "CHAT_MSG_CHANNEL_NOTICE_USER",
  "CHAT_MSG_CHANNEL_LIST",
}

local function channelDisplayFilter(_, _, _, _, _, a4, _, _, _, a8, a9)
  if aboutPublic(a4, a8, a9) then return true end
  return false
end

-- Suppression 3: the password popup, only across our own join call. The
-- original value (which may legitimately be nil) is restored either way.
local popupSuppressed = false
local popupSaved = nil

local function suppressPasswordPopup()
  if popupSuppressed then return end
  if type(StaticPopupDialogs) ~= "table" then return end
  popupSuppressed = true
  popupSaved = StaticPopupDialogs["CHAT_CHANNEL_PASSWORD"]
  StaticPopupDialogs["CHAT_CHANNEL_PASSWORD"] = nil
  PG.After(1, function()
    if not popupSuppressed then return end
    popupSuppressed = false
    StaticPopupDialogs["CHAT_CHANNEL_PASSWORD"] = popupSaved
    popupSaved = nil
  end)
end

-- At login the General/Trade/LocalDefense channels trickle in over several
-- seconds. Joining early grabs a low /N slot and pushes every one of the user's
-- own channels up a number, which is exactly the kind of thing that gets addons
-- blacklisted. Readiness test: no gap (an empty slot below a filled one).
local function channelsSettled()
  if not (C_ChatInfo and C_ChatInfo.GetChannelShortcut) then return true end
  local maxc = MAX_WOW_CHAT_CHANNELS or 10
  local seenEmpty = false
  for i = 1, maxc do
    local ok, sc = pcall(C_ChatInfo.GetChannelShortcut, i)
    if not ok then return true end
    sc = PG.SafeStr(sc)
    if not sc or sc == "" then
      seenEmpty = true
    elseif seenEmpty then
      return false
    end
  end
  return true
end

local function doJoin()
  if type(JoinTemporaryChannel) ~= "function" then
    publicBroken = true
    return
  end
  suppressPasswordPopup()
  if publicUsePassword then
    pcall(JoinTemporaryChannel, PUBLIC_CHANNEL, PUBLIC_PASSWORD)
  else
    pcall(JoinTemporaryChannel, PUBLIC_CHANNEL)
  end
  publicAttemptAt = GetTime()
  debugLine("public join attempted (password=" .. tostring(publicUsePassword) .. ")")
  -- the join is asynchronous; hide again once it has landed even if the
  -- YOU_JOINED notice is missed
  PG.After(2, hideChannel)
end

local function joinAttempt()
  joinPending = false
  if not publicWanted or publicBroken or publicBanned then return end
  if PG.Comm.PublicIndex() then
    hideChannel()
    joinTries = 0 -- we are in: the next cycle starts with a full retry budget
    return
  end
  local now = GetTime()
  if now < publicBackoffUntil then
    scheduleJoin(publicBackoffUntil - now + 0.1)
    return
  end
  if PG.Comm.Locked() and now < joinLockUntil then
    scheduleJoin(2)
    return
  end
  if now < joinDeadline and not channelsSettled() then
    scheduleJoin(0.5) -- a 2s rejoin window is still sampled four times
    return
  end
  joinTries = joinTries + 1
  doJoin()
  -- verify rather than latch: re-check the index a few seconds later and try
  -- again, so one silently refused join does not report "you're in 10 channels
  -- already" for the rest of the session (see ScopeAvailable).
  if joinTries < JOIN_MAX_TRIES then scheduleJoin(JOIN_VERIFY) end
end

scheduleJoin = function(delay)
  if joinPending then return end
  joinPending = true
  PG.After(delay or 0, joinAttempt)
end

-- fast: this is a rejoin after a loading screen, not the login join, so use the
-- short settle window that fits inside the host-abort grace.
function PG.Comm.PublicJoin(fast)
  if publicBroken then return false end
  publicWanted = true
  publicBanned = false
  joinTries = 0
  local now = GetTime()
  -- settle-detection from now, then force the join regardless
  joinDeadline = now + (fast and SETTLE_REJOIN or SETTLE_LOGIN)
  joinLockUntil = now + (fast and SETTLE_REJOIN or JOIN_LOCK_WAIT)
  scheduleJoin(0)
  return true
end

function PG.Comm.PublicLeave()
  publicWanted = false
  joinDeadline = 0
  joinLockUntil = 0
  joinTries = 0
  if type(LeaveChannelByName) == "function" then
    pcall(LeaveChannelByName, PUBLIC_CHANNEL)
  end
  publicSeenAt = 0
  publicAttemptAt = 0
  return true
end

local function onChannelNotice(_, a1, _, _, a4, _, _, _, a8, a9)
  if not aboutPublic(a4, a8, a9) then return end
  local notice = PG.SafeStr(a1) or ""
  if notice == "YOU_JOINED" then
    publicBackoffUntil = 0
    publicBanned = false
    publicUsePassword = true
    publicAttemptAt = GetTime()
    joinTries = 0
    hideChannel()
    if PG.Settings and PG.Settings.Refresh then PG.Settings.Refresh() end
    if PG.UI and PG.UI.RefreshScopePickers then PG.UI.RefreshScopePickers() end
  elseif notice == "YOU_LEFT" then
    -- mark unavailable; a PLAYER_ENTERING_WORLD rejoin heals it. We do not
    -- rejoin here: the user may have left the channel deliberately.
    -- A deliberate leave still kills the host-abort grace, but a channel dropped
    -- by a loading screen must not: zeroing it there makes the 8s grace
    -- unreachable exactly when it exists to be used. "Deliberate" is
    -- publicWanted, not the notice - PublicLeave clears the flag before the
    -- notice arrives, and the ordering of a zoning drop against
    -- PLAYER_ENTERING_WORLD is not something to depend on.
    if not publicWanted then publicSeenAt = 0 end
  elseif notice == "WRONG_PASSWORD" then
    -- an owner may have cleared the password: alternate on each retry
    publicBackoffUntil = GetTime() + 300
    publicUsePassword = not publicUsePassword
    scheduleJoin(301)
  elseif notice == "BANNED" then
    publicBanned = true
    publicBackoffUntil = GetTime() + 300
    publicSeenAt = 0
    if PG.Settings and PG.Settings.Refresh then PG.Settings.Refresh() end
    if PG.UI and PG.UI.RefreshScopePickers then PG.UI.RefreshScopePickers() end
  end
end

-------------------------------------------------------------------------------
-- Scope availability. Always a live query, never cached: the player can
-- /gquit, leave the group or hit the ten-channel cap at any moment.
-- graceSecs (default 0) tolerates a brief public-channel gap across a loading
-- screen; only the host-abort watchdog passes it.
-------------------------------------------------------------------------------

function PG.Comm.ScopeAvailable(scope, graceSecs)
  local s = PG.SafeStr(scope)
  if s == "group" then
    if IsInGroup() then return true end
    return false, "You're not in a party or raid."
  elseif s == "guild" then
    if not IsInGuild() then return false, "You're not in a guild." end
    -- open Blizzard bug: a rank that cannot speak in guild chat also cannot
    -- SEND on the GUILD addon distribution. Receiving is unaffected. If the
    -- API is absent on a build, fall through and allow the attempt.
    if C_GuildInfo and C_GuildInfo.CanSpeakInGuildChat
      and C_GuildInfo.CanSpeakInGuildChat() == false then
      return false, "Your guild rank can't speak in guild chat."
    end
    return true
  elseif s == "public" then
    if not publicOptIn() then
      return false, "Turn on 'Join the public games channel' in Settings first."
    end
    if publicBroken then return false, "This client can't use custom channels." end
    if publicBanned then return false, "You can't use the public games channel." end
    if PG.Comm.PublicIndex() then return true end
    local grace = PG.SafeNum(graceSecs) or 0
    if grace > 0 and publicSeenAt > 0 and (GetTime() - publicSeenAt) < grace then
      return true
    end
    -- only once the bounded verification retries are spent: "index still 0" is
    -- the sole failure signal there is, and one silently refused attempt is not
    -- evidence of a full channel list
    if publicAttemptAt > 0 and joinTries >= JOIN_MAX_TRIES
      and (GetTime() - publicAttemptAt) > 3 then
      return false, "You're in 10 chat channels already. Leave one to use Public."
    end
    return false, "Still joining the public channel - try again in a moment."
  end
  return false, "That audience isn't available."
end

-------------------------------------------------------------------------------
-- Encode / queue / send
-------------------------------------------------------------------------------

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

-- onDrop carries the token so one session's dropped message can never abort
-- another session sharing the queue (CONCURRENCY.md 5.5).
local function dropEntry(entry, why)
  debugLine("dropped (" .. why .. ") " .. entry.msg)
  local onDrop = moduleDrops[entry.module]
  if onDrop then pcall(onDrop, entry.mtype, entry.token) end
end

-- Late resolution is mandatory: a queued message can sit in the FIFO through a
-- channel rejoin (indices shift) or a party->raid conversion, so chatType and
-- target are derived here, at send time, from entry.scope. Never at submit().
local function resolveOut(entry)
  if entry.chatType == "WHISPER" then return "WHISPER", entry.target end
  local s = entry.scope
  if s == "guild" then
    if not IsInGuild() then return nil end
    return "GUILD", nil
  elseif s == "public" then
    local idx = PG.Comm.PublicIndex()
    if not idx then return nil end
    return "CHANNEL", idx
  end
  if IsInRaid() then return "RAID", nil end
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT", nil end
  if IsInGroup() then return "PARTY", nil end
  return nil
end

-- Returns nil when the audience vanished: the entry is ALREADY dropped
-- (onDrop fired) and pump must not call onSent.
local function rawSend(entry)
  local chatType, target = resolveOut(entry)
  if not chatType then
    dropEntry(entry, "no audience")
    return nil
  end
  local result = C_ChatInfo.SendAddonMessage(PREFIX, entry.msg, chatType, target)
  debugLine("sent [" .. (entry.scope or "whisper") .. "/" .. chatType
    .. (target and (":" .. tostring(target)) or "") .. "] " .. entry.msg)
  if PG.IsSecret(result) or type(result) ~= "number" then
    return RESULT_SUCCESS -- non-Enum API shapes: treat as success
  end
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

-- CHANNEL is disabled as an addon-message chat type on Classic and can fail on
-- any client that does not support it. It is not a throttle and it will not
-- heal: mark the capability dead and stop trying forever.
local function onInvalidChatType(entry)
  if entry.scope == "public" then
    publicBroken = true
    publicWanted = false
    if PG.Settings and PG.Settings.Refresh then PG.Settings.Refresh() end
  end
end

-- The index we resolved a moment ago is already stale (someone joined or left
-- a channel between resolve and send, or we were dropped from ours). Drop this
-- message -- a critical send must never look like it went out -- and get back
-- into the channel for the next one.
local function onInvalidChannel(entry)
  if entry.scope == "public" then
    publicSeenAt = 0
    if publicWanted and not publicBroken and not publicBanned then scheduleJoin(1) end
  end
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
      if result == nil then
        -- audience vanished; rawSend already dropped it. Never onSent.
      elseif result == RESULT_THROTTLE or result == RESULT_CHANNEL_THROTTLE then
        table.insert(queue, 1, entry) -- transient: same message retries after backoff
        schedulePump(1.2)
        return
      elseif result == RESULT_LOCKDOWN then
        dropEntry(entry, "lockdown")
      elseif result == RESULT_INVALID_CHAT_TYPE then
        onInvalidChatType(entry)
        dropEntry(entry, "chat type unsupported")
      elseif result == RESULT_INVALID_CHANNEL then
        onInvalidChannel(entry)
        dropEntry(entry, "invalid channel")
      elseif result ~= RESULT_SUCCESS then
        -- anything else (NotInGroup, TargetRequired, GeneralError, ...) is a
        -- failed send. It must NOT reach onSent: a game would commit a result
        -- that never left this client.
        dropEntry(entry, "send failed (" .. tostring(result) .. ")")
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

-- handler(mtype, token, sender, scope, f1, f2, ...) receives every message for
-- 'module' ("CO", "LG", "PB", "RPS"); scope is derived from the delivery
-- distribution and is one of "group"/"guild"/"public"/"private".
-- onDrop(mtype, token), optional, is called when an OUTGOING message of this
-- module is dropped (comms lockdown, vanished audience, or a failed send). The
-- drop is permanent; the message is gone. The token identifies WHICH session
-- lost the message, so a drop for another session is ignored by the caller.
function PG.Comm.Register(module, handler, onDrop)
  moduleHandlers[module] = handler
  moduleDrops[module] = onDrop
end

-- fn(sender) -> boolean. Consulted ONLY for WHISPER traffic that fails the
-- group test, because a whisper carries no audience proof at all. Coarse by
-- design: it decides whether the message reaches the handler, which still
-- validates token, phase and sender exactly as before.
function PG.Comm.RegisterTrust(module, fn)
  moduleTrust[module] = fn
end

local function normalizeScope(scope, module, mtype)
  local s = PG.SafeStr(scope)
  if s and SCOPES[s] then return s end
  -- A missing scope is a programming bug at the call site. Fall back to the
  -- narrowest audience rather than guessing wider: a receiver drops an OPEN
  -- whose declared code disagrees with its delivery, so this fails safe.
  debugLine("scope missing on " .. tostring(module) .. " " .. tostring(mtype) .. ", using group")
  return "group"
end

-- The audience is checked up front so a caller learns immediately that there
-- is nobody to talk to (the same abort path callers already handle for "not
-- grouped"); the transport itself is resolved late, at send time.
local function broadcastInner(scope, onSent, module, mtype, token, ...)
  scope = normalizeScope(scope, module, mtype)
  if not PG.Comm.ScopeAvailable(scope) then return false end
  return submit({
    msg = encode(module, mtype, token, ...),
    scope = scope,
    module = module,
    mtype = mtype,
    token = tostring(token),
    onSent = onSent,
  })
end

-- Broadcast with per-message callbacks: opts.scope selects the audience,
-- opts.onSent fires exactly once, after the message has actually gone out
-- (never for a message that was queued and later dropped, nor for one the
-- server refused; may fire synchronously inside this call when the bucket has
-- tokens). Returns true if the message was queued/sent.
function PG.Comm.BroadcastEx(opts, module, mtype, token, ...)
  return broadcastInner(opts and opts.scope, opts and opts.onSent,
    module, mtype, token, ...)
end

-- Scope leads, like target does on Whisper.
function PG.Comm.Broadcast(scope, module, mtype, token, ...)
  return broadcastInner(scope, nil, module, mtype, token, ...)
end

-- Private 1:1 traffic uses WHISPER in EVERY scope, no exceptions: PICK is the
-- whole game and must not be readable by the audience, and a resync replay is
-- point-to-point by design. Signature unchanged.
function PG.Comm.Whisper(target, module, mtype, token, ...)
  if type(target) ~= "string" or target == "" then return false end
  return submit({
    msg = encode(module, mtype, token, ...),
    chatType = "WHISPER",
    target = target,
    module = module,
    mtype = mtype,
    token = tostring(token),
  })
end

-------------------------------------------------------------------------------
-- Inbound: provenance, trust, rate limiting, routing.
--
-- The delivery distribution is the only server-vouched fact about a message.
-- CHAT_MSG_ADDON also delivers WHISPERs from arbitrary non-group players once
-- the prefix is registered, so a whisper proves nothing on its own and is
-- gated by the group roster first and a module predicate second.
-------------------------------------------------------------------------------

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

local DIST_SCOPE = {
  RAID = "group",
  RAID_LEADER = "group",
  PARTY = "group",
  PARTY_LEADER = "group",
  INSTANCE_CHAT = "group",
  INSTANCE_CHAT_LEADER = "group",
  GUILD = "guild",
  OFFICER = "guild",
  WHISPER = "private",
}

-- SAY, YELL, BATTLEGROUND, a CHANNEL that is not ours, anything unknown: drop.
local function deriveScope(dist, a4, a8, a9)
  local d = PG.SafeStr(dist)
  if not d then return nil end
  local s = DIST_SCOPE[d]
  if s then return s end
  if d == "CHANNEL" and aboutPublic(a4, a8, a9) then return "public" end
  return nil
end

local function guildScopeOn()
  local p = PG.db and PG.db.profile
  local si = p and p.scopeIn
  if type(si) ~= "table" then return true end -- default on (SCOPE.md 5.6)
  return si.guild ~= false
end

local function trustFn(module, sender)
  local fn = moduleTrust[module]
  if not fn then return false end
  local ok, res = pcall(fn, sender)
  return (ok and res == true) and true or false
end

-- group: the roster is the proof, unchanged from 0.5.x.
-- guild: the GUILD distribution is server-vouched -- only an actual guildmate
--        can send on it -- so a roster lookup would add nothing against forgery
--        and would eat legitimate OPENs against a cold cache. The only gate is
--        the user's own preference.
-- public: no authentication of any kind exists. The router gate is only "opted
--        in and arrived on our channel"; public is backstopped at the session
--        layer, which never constructs state without an explicit user click.
-- private: no audience proof whatsoever, so group membership first, then the
--        module's own predicate.
local function accept(sender, scope, module)
  if scope == "group" then return isGroupSender(sender) end
  if scope == "guild" then return guildScopeOn() end
  if scope == "public" then return publicOptIn() end
  if isGroupSender(sender) then return true end
  return trustFn(module, sender)
end

local function isIgnored(sender)
  if not (C_FriendList and C_FriendList.IsIgnored) then return false end
  local ok, res = pcall(C_FriendList.IsIgnored, sender)
  if ok and res == true then return true end
  local short = sender:match("^([^%-]+)")
  if short and short ~= sender then
    ok, res = pcall(C_FriendList.IsIgnored, short)
    if ok and res == true then return true end
  end
  return false
end

-- Inbound rate limiting. The server throttle is per sender, so N senders scale
-- linearly: two hundred guildmates or an unbounded public channel can otherwise
-- drive a roster apply plus a UI refresh once per message, during raid content.
local IN_SENDER_CAP, IN_SENDER_RATE = 12, 2
local IN_GLOBAL_CAP, IN_GLOBAL_RATE = 60, 20
local IN_SENDER_MAX = 64 -- bounded memory: buckets tracked at once

local inSender = {}
local inSenderCount = 0
local inGlobal = IN_GLOBAL_CAP
local inGlobalAt = nil

-- Bounded memory, LRU. Wiping the whole table at the cap refilled every bucket
-- to the full 12-token capacity, which is the one thing the limiter must never
-- do: a flood from 64 senders would hand the loudest of them a fresh budget.
-- Idle buckets go first; if that is not enough, the least recently used half of
-- what is left goes, so an active sender keeps its accumulated debt.
local function pruneSenders(now)
  for name, b in pairs(inSender) do
    if (now - b.at) > 30 then
      inSender[name] = nil
      inSenderCount = inSenderCount - 1
    end
  end
  if inSenderCount < IN_SENDER_MAX then return end
  local order = {}
  for name, b in pairs(inSender) do
    order[#order + 1] = { name = name, at = b.at }
  end
  table.sort(order, function(x, y)
    if x.at ~= y.at then return x.at < y.at end
    return x.name < y.name -- deterministic, and #order is bounded at 64
  end)
  local drop = math.floor(#order / 2)
  for i = 1, drop do
    inSender[order[i].name] = nil
    inSenderCount = inSenderCount - 1
  end
end

local function rateOk(sender)
  local now = GetTime()
  if inGlobalAt then
    inGlobal = math.min(IN_GLOBAL_CAP, inGlobal + (now - inGlobalAt) * IN_GLOBAL_RATE)
  end
  inGlobalAt = now
  if inGlobal < 1 then return false end
  local b = inSender[sender]
  if not b then
    if inSenderCount >= IN_SENDER_MAX then pruneSenders(now) end
    b = { t = IN_SENDER_CAP, at = now }
    inSender[sender] = b
    inSenderCount = inSenderCount + 1
  else
    b.t = math.min(IN_SENDER_CAP, b.t + (now - b.at) * IN_SENDER_RATE)
    b.at = now
  end
  if b.t < 1 then return false end
  b.t = b.t - 1
  inGlobal = inGlobal - 1
  return true
end

-- CHAT_MSG_ADDON payload: prefix, text, distribution, sender, target,
-- zoneChannelID, localID, channelName, instanceID. The distribution argument
-- (previously discarded) is the server-vouched trust signal; the channel name
-- at arg8 is what distinguishes our public channel from any other.
local function onChatMsgAddon(_, prefix, message, dist, sender, _, _, _, a8, a9)
  if PG.IsSecret(prefix) or prefix ~= PREFIX then return end
  if PG.IsSecret(message) or type(message) ~= "string" then return end
  sender = PG.NormalizeSender(sender)
  if not sender then return end
  -- self-broadcast ignore: behavior must never depend on self-delivery; every
  -- host/bookie processes its own outgoing state locally at send time
  if sender == PG.FullName("player") then return end
  -- the ignore list is the user's only remedy against a guild or public nuisance
  if isIgnored(sender) then return end
  if not rateOk(sender) then return end
  local scope = deriveScope(dist, nil, a8, a9)
  if not scope then return end
  local parts = { strsplit("|", message) }
  if parts[1] ~= WIRE_VERSION then
    if not warnedVersion then
      warnedVersion = true
      if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: ignoring messages from a different protocol version - everyone needs 1.2.0 or later to play together.")
      end
    end
    return
  end
  local module, mtype, token = parts[2], parts[3], parts[4]
  if not (module and mtype and token) then return end
  if module == "" or mtype == "" or token == "" then return end
  if not accept(sender, scope, module) then return end
  debugLine("recv [" .. sender .. "/" .. scope .. "] " .. message)
  local handler = moduleHandlers[module]
  if handler then
    local ok, err = pcall(handler, mtype, token, sender, scope, unpack(parts, 5))
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

  -- Public channel: chat suppression first, so nothing can leak into a chat
  -- window even if a join lands before the rest of init finishes.
  if type(ChatFrame_AddMessageEventFilter) == "function" then
    for i = 1, #FILTER_EVENTS do
      pcall(ChatFrame_AddMessageEventFilter, FILTER_EVENTS[i], channelDisplayFilter)
    end
  end
  PG.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", onChannelNotice)
  local firstEnter = true
  PG.RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
    hideChannel()
    -- The 8s host-abort grace is measured from publicSeenAt, which stopped
    -- advancing the moment the loading screen dropped the channel. Re-anchor it
    -- here so the grace covers the REJOIN below rather than the loading screen
    -- we just sat through. It never anchors from zero: a player who never
    -- joined, or who left deliberately, still gets no grace.
    if publicSeenAt > 0 then publicSeenAt = GetTime() end
    -- a temporary channel is dropped across every loading screen; you can only
    -- RECEIVE an OPEN if you were already in the channel when it was sent, so
    -- the rejoin is unconditional on the opt-in, never lazy on a game starting
    if publicOptIn() then
      -- compared with == true so a secret or absent payload degrades to the
      -- safe branch (treated as a rejoin, the shorter settle window)
      local login = firstEnter or (isLogin == true) or (isReload == true)
      firstEnter = false
      PG.Comm.PublicJoin(not login)
    end
  end)
end)
