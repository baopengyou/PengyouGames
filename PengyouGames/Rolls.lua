-- Rolls.lua - the /roll observer: the addon's ONE reader of CHAT_MSG_SYSTEM.
-- Death Roll and Gambler are settled by a REAL in-game /roll rather than by a
-- number the addon invents, because the system line is PUBLIC: everyone in the
-- group sees the identical text, addon or no addon, so the result is evidence
-- instead of a claim. That is the whole reason those two games exist, and it is
-- what lets every client re-derive the outcome from the rolls IT saw before it
-- writes a single ledger row (BRIEF 2) - the one place this suite is stronger
-- than "the host says so".
local ADDON, PG = ...

PG.Rolls = {}

-------------------------------------------------------------------------------
-- THE PUBLIC CONTRACT (BRIEF 3). There is no docs/ROLLS.md; this block is it.
--
--   PG.Rolls.OnRoll(module, fn)
--       fn(roll) on every ACCEPTED roll, roll = { name, value, low, high, at }.
--       name is canonical "Name-Realm", value/low/high are plain integers, at
--       is the GetTime() when it was observed. One callback per module code;
--       registering again replaces it. Dispatch is pcall-wrapped per listener,
--       so a broken game never stops the other one and never errors out of the
--       event handler.
--   PG.Rolls.Since(t)
--       Accepted rolls with at >= t, oldest first, out of a bounded ring
--       (RING_MAX entries, RING_TTL seconds). This exists because a window can
--       open LATE - the host's TURN/ROUND queued behind the shared 10-token
--       bucket - and without it the player watches their own correct roll get
--       ignored. A game drains this the instant it opens a window.
--   PG.Rolls.Request(low, high) -> ok, why
--       Asks the CLIENT to roll for real. ok == true means RandomRoll was
--       called and nothing more: the number arrives later down the same
--       CHAT_MSG_SYSTEM path as a hand-typed /roll, or it never arrives.
--       ok == false carries a short player-facing `why` that is always
--       actionable, so a refusal is never a dead button.
--   PG.Rolls.Available() -> true if Request() is expected to work right now.
--   PG.Rolls.Ready()     -> true if the parser built and self-tested (3.2).
--
-- Three rules live HERE so that no game can opt out of them:
--
--   1. NOTHING IS EVER FABRICATED. There is no code path in this file that
--      produces a value. Request() calls RandomRoll behind an existence guard
--      and a pcall and then forgets about it; only an OBSERVATION proves a roll.
--   2. NO SIDE CHANNEL (SPEC 2.12). Observations are DISCARDED - not queued,
--      not delivered late - while addon messaging is locked or any raid-critical
--      state is up. Chat keeps flowing during an encounter, so a game that kept
--      advancing on rolls while the wire refuses sends would be exactly the
--      in-encounter signalling the spec bans absolutely, arrived at by accident.
--      It has to be impossible by construction, not by convention.
--   3. NO GUESSING AT NAMES. This file normalizes the name the system line gave
--      it (PG.NormalizeSender) and reports that. It does not know what a roster
--      is: matching a roll to a player is the GAME's job against its own frozen
--      roster, and the game drops the roll on any ambiguity (BRIEF 3.3). A wrong
--      guess here moves gold to the wrong character with no error anywhere,
--      which is strictly worse than a window the players can watch time out.
--
-- "First valid roll per actor per window wins" is NOT enforced here: this file
-- reports every accepted roll and the games hold the windows (BRIEF 3.5).
-------------------------------------------------------------------------------

local RING_MAX = 24        -- observed rolls kept at once
local RING_TTL = 20        -- ... and for how many seconds
local MAX_ROLL = 1000000   -- the client's own /roll ceiling; anything past it is not ours
local MAX_NAME = 48        -- "Name-Realm" bound: stops a greedy capture becoming a name
local VERIFY_SECS = 4      -- how long a Request waits for its own roll to show up

local function debugLine(text)
  if PG.debug and DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffPG rolls|r " .. text)
  end
end

-------------------------------------------------------------------------------
-- Pattern construction and the mandatory self-test (BRIEF 3.2).
--
-- The system line is built by the CLIENT from its own RANDOM_ROLL_RESULT, so an
-- English literal would work on exactly one locale and fail on the rest in the
-- one way that must never happen: silently, indistinguishably from "nobody
-- rolled". Everything below exists to make that failure loud instead.
-------------------------------------------------------------------------------

-- Used only when the global is missing entirely - see acceptFallback().
local FALLBACK_FMT = "%s rolls %d (%d-%d)"

-- The string is formatted as (name, roll, minimum, maximum). Locales reorder
-- those freely and several do it with ORDINAL specifiers, e.g. the shape
-- "%1$s ... %3$d~%4$d ... %2$d", so the k-th CAPTURE is NOT the k-th ARGUMENT.
-- The mapping has to be read out of the format string, never assumed.
local ARG_NAME, ARG_VALUE, ARG_LOW, ARG_HIGH = 1, 2, 3, 4

-- Distinct on purpose: a swapped mapping (roll <-> maximum is the realistic
-- one) has to change at least one of these, or the self-test proves nothing.
local T_NAME, T_VALUE, T_LOW, T_HIGH = "Rollcheck-Testrealm", 73, 1, 100

-- Walks the format string left to right and returns the ARGUMENT INDEX of each
-- specifier in the order they appear. "%s rolls %d (%d-%d)" -> {1,2,3,4};
-- an ordinal locale can return {1,3,4,2}.
local function scanArgs(fmt)
  local order, pos, seq = {}, 1, 0
  while true do
    local s, e = fmt:find("%%%d*%$?[sd]", pos)
    if not s then break end
    local num = fmt:sub(s, e):match("^%%(%d+)%$")
    if num then
      order[#order + 1] = tonumber(num)
    else
      seq = seq + 1
      order[#order + 1] = seq
    end
    pos = e + 1
  end
  return order
end

-- Inverts that into capture-position-by-argument, and refuses anything that is
-- not exactly the four arguments we know how to read, each used once.
local function capsFrom(order)
  if #order ~= 4 then return nil end
  local cap = {}
  for k = 1, 4 do
    local a = order[k]
    if type(a) ~= "number" or a < 1 or a > 4 or cap[a] then return nil end
    cap[a] = k
  end
  return cap
end

-- Escape ALL magic characters FIRST, then substitute the (now-escaped) format
-- specifiers. The other order inserts "(.+)" and "(%d+)" into the string and the
-- escape pass then mangles the capture groups it just created.
-- After escaping, "%s" reads as "%%s" and "%1$s" as "%%1%$s"; ordinals are
-- substituted first so the sequential pass cannot chew a piece of one.
local function toPattern(fmt)
  local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  p = p:gsub("%%%%(%d+)%%%$s", "(.+)")
  p = p:gsub("%%%%(%d+)%%%$d", "(%%d+)")
  p = p:gsub("%%%%s", "(.+)")
  p = p:gsub("%%%%d", "(%%d+)")
  return "^" .. p .. "$"
end

-- Renders a synthetic line and reads it back through the pattern we just built,
-- checking all four captures land in the right ARGUMENT slots with the right
-- values. Rendered with string.format - Blizzard's, the same one the locale
-- string was written for, ordinal specifiers included - and deliberately NOT
-- with our own substitution code: a self-test that shares the parser it is
-- testing agrees with itself and proves nothing.
local function selfTest(fmt, pat, cap)
  local okF, line = pcall(string.format, fmt, T_NAME, T_VALUE, T_LOW, T_HIGH)
  if not okF or type(line) ~= "string" then return false, "format" end
  local okM, c1, c2, c3, c4 = pcall(string.match, line, pat)
  if not okM or c1 == nil then return false, "match" end
  local c = { c1, c2, c3, c4 }
  if c[cap[ARG_NAME]] ~= T_NAME then return false, "name" end
  if tonumber(c[cap[ARG_VALUE]]) ~= T_VALUE then return false, "value" end
  if tonumber(c[cap[ARG_LOW]]) ~= T_LOW then return false, "low" end
  if tonumber(c[cap[ARG_HIGH]]) ~= T_HIGH then return false, "high" end
  return true
end

local pattern = nil      -- compiled Lua pattern, or nil while unusable
local capIndex = nil     -- capture position by argument index
local patternSrc = "none"
local ready = false

-- Compiles fmt and keeps it only if the self-test passes.
local function compile(fmt, src)
  if type(fmt) ~= "string" or fmt == "" then return false, "missing" end
  local cap = capsFrom(scanArgs(fmt))
  if not cap then return false, "specifiers" end
  local pat = toPattern(fmt)
  local ok, why = selfTest(fmt, pat, cap)
  if not ok then return false, why end
  pattern, capIndex, patternSrc = pat, cap, src
  return true
end

-- Taking the English literal on a client whose OWN RANDOM_ROLL_RESULT we failed
-- to parse would be the silent failure this whole section exists to prevent:
-- that string is what the client builds its system lines from, so a pattern
-- that cannot read it will not read them either. The fallback is therefore
-- accepted in exactly two situations - the global is missing (we know nothing,
-- and English is the only guess left), or the English pattern can actually read
-- a line rendered from the locale format (it parsed badly but is English-shaped
-- anyway). This is a deliberate tightening of BRIEF 3.2's "fall back and
-- re-test"; re-testing the fallback against ITSELF always passes and would
-- report Ready() on a client that can never see a roll.
local function acceptFallback(localeFmt)
  local ok, why = compile(FALLBACK_FMT, "english")
  if not ok then return false, why end
  if localeFmt == nil then return true end
  local okF, line = pcall(string.format, localeFmt, T_NAME, T_VALUE, T_LOW, T_HIGH)
  if not okF or type(line) ~= "string" then return false, "locale-unrenderable" end
  local okM, c1 = pcall(string.match, line, pattern)
  if not okM or c1 == nil then return false, "locale-unreadable" end
  return true
end

local function buildPattern()
  local fmt = PG.SafeStr(_G.RANDOM_ROLL_RESULT)
  if fmt and fmt ~= "" then
    local ok, why = compile(fmt, "locale")
    if ok then return true end
    debugLine("locale format rejected (" .. tostring(why) .. "), trying English")
    return acceptFallback(fmt)
  end
  return acceptFallback(nil)
end

-------------------------------------------------------------------------------
-- Gating (BRIEF 3.4). Both halves are needed: Locked() reports the 12.1 comms
-- lockdown (encounter / M+ / PvP) and says nothing about a ready check, a pull
-- countdown or an addon restriction, which are exactly the moments a raid does
-- not want a minigame advancing.
-------------------------------------------------------------------------------

local function allClear()
  local s = PG.Safety and PG.Safety.state
  if not s then return true end
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

local function gateOpen()
  if PG.Comm and PG.Comm.Locked and PG.Comm.Locked() then return false end
  return allClear()
end

-------------------------------------------------------------------------------
-- The ring, the listeners, and the observation path.
-------------------------------------------------------------------------------

local ring = {}       -- accepted rolls, oldest first
local cbOrder = {}    -- module codes in registration order: dispatch is deterministic
local cbFn = {}       -- [module] = fn

-- Every consumer gets a copy. The ring recycles and a game is entitled to stash
-- what it was handed; same reasoning as PG.Session's seatView.
local function rollView(r)
  return { name = r.name, value = r.value, low = r.low, high = r.high, at = r.at }
end

local function pruneRing(now)
  while ring[1] and (now - ring[1].at) > RING_TTL do table.remove(ring, 1) end
  while #ring > RING_MAX do table.remove(ring, 1) end
end

-- Request's observational verification (see Request below).
local pending = nil     -- { low, high, gen } of the Request awaiting its own roll
local pendingGen = 0    -- invalidates a stale verify timer, same shape as Core's cdGen
local apiBroken = false

local function noteSelfRoll(rec)
  if not pending then return end
  if rec.low ~= pending.low or rec.high ~= pending.high then return end
  local me = PG.FullName("player")
  if me and rec.name == me then pending = nil end
end

-- The system line is generated locally by the client, but it is still parsed
-- text: validate every field before anything downstream can put it in a
-- sentence, let alone in a gold outcome.
local function parseRoll(msg)
  local c1, c2, c3, c4 = msg:match(pattern)
  if c1 == nil then return nil end
  local c = { c1, c2, c3, c4 }
  local raw = c[capIndex[ARG_NAME]]
  local value = tonumber(c[capIndex[ARG_VALUE]])
  local low = tonumber(c[capIndex[ARG_LOW]])
  local high = tonumber(c[capIndex[ARG_HIGH]])
  if type(raw) ~= "string" or not value or not low or not high then return nil end
  if math.floor(value) ~= value or math.floor(low) ~= low or math.floor(high) ~= high then return nil end
  if low < 0 or high < low or high > MAX_ROLL then return nil end
  if value < low or value > high then return nil end
  local name = raw:match("^%s*(.-)%s*$")
  if name == "" or #name > MAX_NAME then return nil end
  -- Names never contain these (SPEC 3) and a captured one that does is a
  -- mis-parse, not a player - dropping it keeps it out of every wire field.
  if name:find("[|,;]") then return nil end
  name = PG.NormalizeSender(name)
  if not name then return nil end
  return { name = name, value = value, low = low, high = high, at = GetTime() }
end

local function onSystem(_, msg)
  if not pattern then return end
  msg = PG.SafeStr(msg)
  if not msg then return end
  -- SPEC 2.12: discarded outright, never buffered for later delivery. A roll
  -- made during an encounter did not happen as far as this addon is concerned.
  if not gateOpen() then return end
  local rec = parseRoll(msg)
  if not rec then return end
  ring[#ring + 1] = rec
  pruneRing(rec.at)
  noteSelfRoll(rec)
  debugLine(rec.name .. " rolled " .. rec.value .. " (" .. rec.low .. "-" .. rec.high .. ")")
  -- Stored BEFORE dispatch, so a listener that calls Since() from inside its
  -- own callback sees the roll that woke it.
  for i = 1, #cbOrder do
    local fn = cbFn[cbOrder[i]]
    if fn then
      local ok, err = pcall(fn, rollView(rec))
      if not ok then geterrorhandler()(err) end
    end
  end
end

-------------------------------------------------------------------------------
-- Public API - exactly the five functions of BRIEF 3.1.
-------------------------------------------------------------------------------

-- One callback per module code, replaced on re-registration. Returns true when
-- the callback was accepted; every caller in the suite registers once at init.
function PG.Rolls.OnRoll(module, fn)
  local m = PG.SafeStr(module)
  if not m or m == "" or type(fn) ~= "function" then return false end
  if not cbFn[m] then cbOrder[#cbOrder + 1] = m end
  cbFn[m] = fn
  return true
end

-- Accepted rolls with at >= t, oldest first. Since(0) is the whole ring.
function PG.Rolls.Since(t)
  local from = PG.SafeNum(t) or 0
  pruneRing(GetTime())
  local out = {}
  for i = 1, #ring do
    if ring[i].at >= from then out[#out + 1] = rollView(ring[i]) end
  end
  return out
end

-- The manual instruction is always true and always works, so every refusal
-- returns it: the player is never left looking at a button that does nothing.
local function hint(low, high)
  if low <= 1 then return "Type /roll " .. high .. " in chat." end
  return "Type /roll " .. low .. " " .. high .. " in chat."
end

-- RandomRoll can exist, accept the call, return nothing and do nothing (a
-- protected build). No return value reports that, so the only proof is
-- observational: our own roll, in our own range, inside VERIFY_SECS. A miss
-- latches Available() off for the session and the UI falls back to the typed
-- instruction. Two ways to be wrong, both safe in the same direction: the test
-- only runs while Ready() (a client that cannot read rolls could never confirm
-- one) and it is abandoned if the gate closed underneath it, because a roll made
-- half a second before a ready check is discarded by design, not by breakage.
local function armVerify(low, high)
  if not ready then return end
  pendingGen = pendingGen + 1
  local gen = pendingGen
  pending = { low = low, high = high, gen = gen }
  PG.After(VERIFY_SECS, function()
    -- A newer Request owns the latch now; this timer is stale.
    if not pending or pending.gen ~= gen then return end
    if not gateOpen() then pending = nil return end
    pending = nil
    apiBroken = true
    debugLine("RandomRoll produced no observable roll; falling back to typed rolls")
  end)
end

-- Attempts a real roll on the player's behalf. NEVER fabricates a value: on
-- success the number arrives later through onSystem like any other roll.
-- A false is not necessarily permanent - the gate reopens - so a caller that
-- wants to know whether the button is worth showing at all asks Available().
function PG.Rolls.Request(low, high)
  local lo, hi = PG.SafeNum(low), PG.SafeNum(high)
  if not lo or not hi or math.floor(lo) ~= lo or math.floor(hi) ~= hi
     or lo < 1 or hi < lo or hi > MAX_ROLL then
    -- The range itself is unusable, so there is no /roll worth naming. This is
    -- a caller bug rather than a player situation; still say something the
    -- player can act on rather than leaving a button that does nothing.
    return false, "This game sent a roll range this client can't use - ask the host to restart it."
  end
  if not gateOpen() then
    return false, "Rolls don't count during a pull, ready check or encounter - wait for it to clear."
  end
  if apiBroken or type(_G.RandomRoll) ~= "function" then return false, hint(lo, hi) end
  local ok = pcall(_G.RandomRoll, lo, hi)
  if not ok then
    apiBroken = true
    return false, hint(lo, hi)
  end
  armVerify(lo, hi)
  return true
end

-- UI copy only: whether Request() is expected to work right now.
function PG.Rolls.Available()
  if apiBroken or type(_G.RandomRoll) ~= "function" then return false end
  return gateOpen()
end

-- Whether this client can read roll results at all. A module that is not Ready()
-- must refuse to START and say why, rather than open a table that can never
-- resolve.
function PG.Rolls.Ready() return ready end

-------------------------------------------------------------------------------
-- Init. This is the only file permitted to register CHAT_MSG_SYSTEM.
-------------------------------------------------------------------------------

PG.RegisterInit(function()
  local ok, why = buildPattern()
  if ok then
    -- PG.RegisterEvent answers false if the platform refused the registration;
    -- a pattern we cannot feed is not Ready either.
    if not PG.RegisterEvent("CHAT_MSG_SYSTEM", onSystem) then
      ok, why = false, "event"
    end
  end
  ready = ok and true or false
  if ready then
    debugLine("pattern ok (" .. patternSrc .. ") " .. pattern)
    return
  end
  -- Silence is the one outcome that is not acceptable here (BRIEF 3.2): one
  -- debug line carrying the raw format string for a bug report, and one plain
  -- line so the player learns it from the addon instead of from a game that
  -- mysteriously never starts. CHAT_MSG_SYSTEM stays unregistered - there is
  -- nothing we could do with the messages and it is a noisy event.
  pattern, capIndex = nil, nil
  debugLine("pattern FAILED (" .. tostring(why) .. ") RANDOM_ROLL_RESULT="
    .. tostring(_G.RANDOM_ROLL_RESULT))
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: this client's /roll result messages can't be read,"
      .. " so Death Roll and Gambler are unavailable. Every other game works normally."
      .. " Please report this with your game language (/pg rolls has the details).")
  end
end)
