-- Ledger.lua - provenance-stamped session ledger: the four gates (SCOPE.md
-- 4.4), the ver=2 persisted shape (SCOPE.md 4.5), lifetime totals, settlement,
-- and the ledger window.
--
-- The ledger is ADVISORY: no gold ever moves, settlement is a list of manual
-- trades. What it must never do is let a session this client did not sit at
-- put a row into SavedVariables, because a row silently changes the amount and
-- the counterparty of an otherwise legitimate settle-up. Every write goes
-- through PG.Ledger.Commit and every write carries its provenance.
--
-- There is deliberately NO blanket "public scope cannot write gold" stop here:
-- per the owner decision of 2026-08-12 (SCOPE.md 1.2 as amended) a public
-- session is made safe by gate G1 - a client writes rows only for a session it
-- actually joined and played - not by forbidding the audience.
local ADDON, PG = ...

PG.Ledger = {}

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local LEDGER_VER = 2

-- THE SUITE-WIDE absolute ceiling on one player's net from one session. It is
-- not any single game's arithmetic: every gold game's own clamps must satisfy
--     stakeMax * (rosterCap - 1) * roundsMax <= MAX_ROW_GOLD
-- and every game must pass its OWN exact bound as meta.cap, because meta.cap is
-- the tight check and this constant is only the backstop. Worked out against
-- what the three gold games can actually produce at 1.1.0:
--   LG  buy-in 100000 * roster 40                     = 4,000,000  (at the ceiling)
--   DR  wager 100000 * (roster 40 - 1), one survivor   = 3,900,000
--   GB  |delta| <= wager - 1, wager <= 100000          =    99,999
-- (DR pays the survivor one wager from each of the other n-1 players and takes
-- one wager from each of them, so n=40 at the maximum wager is the largest row
-- it can write. The Gambler is one round in which the lowest roll pays the
-- highest the DIFFERENCE between two rolls of 1..wager, so its largest possible
-- row is wager-1 - by far the tightest of the three.) The constant therefore
-- holds unchanged and MUST NOT be raised here: an older client would refuse a
-- row a newer one writes for a game both versions can play, which is exactly
-- the cross-version ledger divergence the v2->v3 wire bump was spent on. Raise
-- it only in a release that also bumps WIRE_VERSION.
local MAX_ROW_GOLD = 100000 * 40 -- 4,000,000
local MAX_ROWS_PER_SESSION = 40  -- roster cap
local MAX_SESSIONS_PER_DAY = 250
local DAYS_KEPT = 30             -- older day buckets are dropped (lifetime kept)
local MAX_ID = 96
local MAX_NAME = 64
local MAX_LABEL = 48

local SCOPES = { group = true, guild = true, public = true }
local SCOPE_LABEL = { group = "Party", guild = "Guild", public = "Public" }

-- Deliberately this file's OWN copy of the code -> name mapping, never a read
-- of a game module's: these labels render PERSISTED rows, which outlive the
-- module that wrote them. A row from a game removed in a future release must
-- still say what it was, and a SavedVariables file hand-edited or carried over
-- from an install that lacked a module must still render a name rather than a
-- bare code. RPS and QZ never write a row - they are listed for exactly that
-- second reason. DR and GB must match the `label` those two modules pass, or
-- every row they write carries a redundant per-entry label string.
local GAME_LABEL = { LG = "Loot Goblins", PB = "Pull Book",
                     RPS = "Rock Paper Scissors", DR = "Death Roll",
                     GB = "The Gambler", QZ = "Quiz" }

-- forward declaration: the core refreshes an open window after a write
local Refresh

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local function today() return date("%Y-%m-%d") end

local function nowStamp()
  local t = time and time() or 0
  if type(t) ~= "number" or t ~= t then return 0 end
  return math.floor(t)
end

-- A number that can be persisted and summed: NaN/inf would poison the totals
-- and secrets silently become nil in SavedVariables (SPEC 2.5).
local function finite(n)
  if PG.IsSecret(n) then return false end
  if type(n) ~= "number" then return false end
  if n ~= n or n == math.huge or n == -math.huge then return false end
  return true
end

-- Plain, non-secret, bounded string or nil. '|' is the wire separator and
-- ',' / ';' are our CSV separators; a name or id never contains them (SPEC 3),
-- so anything that does is hostile input, not a name.
local function plainStr(v, maxLen)
  local s = PG.SafeStr(v)
  if not s or s == "" or #s > (maxLen or MAX_NAME) then return nil end
  if s:find("[|,;\n\r]") then return nil end
  return s
end

local function plainName(v, needRealm)
  local s = plainStr(v, MAX_NAME)
  if not s then return nil end
  if needRealm and not s:find("-", 1, true) then return nil end
  return s
end

local function debugLine(text)
  if PG.debug and DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffPG ledger|r " .. text)
  end
end

local function toast(text)
  if PG.UI and PG.UI.Toast then PG.UI.Toast(text) end
end

-- Short display name: "Grizzle-Illidan" -> "Grizzle".
local function shortName(full)
  if type(full) ~= "string" then return "?" end
  local short = full:match("^([^%-]+)")
  return short or full
end

-------------------------------------------------------------------------------
-- Vouching sources (gate G2)
--
-- A ledger-bound name must be one this client can point at independently. The
-- group roster is rebuilt on demand (bounded by the 40-player raid cap); the
-- guild roster is cached and refreshed on GUILD_ROSTER_UPDATE with a throttled
-- request, because a cold cache in the first seconds after login would
-- otherwise refuse legitimate guild-scope commits.
-------------------------------------------------------------------------------

local function groupSet()
  local set = {}
  local me = PG.FullName("player")
  if me then set[me] = true end
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local n = PG.FullName("raid" .. i)
      if n then set[n] = true end
    end
  elseif IsInGroup() then
    for i = 1, GetNumGroupMembers() - 1 do
      local n = PG.FullName("party" .. i)
      if n then set[n] = true end
    end
  end
  return set
end

local guildCache = {}
local guildDirty = true
local guildAsked = 0

local function markGuildDirty() guildDirty = true end

-- Rebuilt lazily, never from the event itself: GUILD_ROSTER_UPDATE fires in
-- bursts and a 2000-member loop per burst during raid content is exactly the
-- kind of cost this addon must not impose.
local function rebuildGuild()
  wipe(guildCache)
  guildDirty = false
  if not IsInGuild or not IsInGuild() then return end
  if not GetNumGuildMembers or not GetGuildRosterInfo then return end
  local ok, count = pcall(GetNumGuildMembers)
  if not ok then return end
  count = tonumber(count) or 0
  if count > 2000 then count = 2000 end -- bounded loop, never the whole world
  for i = 1, count do
    local got, raw = pcall(GetGuildRosterInfo, i)
    if got then
      local name = PG.NormalizeSender(raw)
      if name and #name <= MAX_NAME then guildCache[name] = true end
    end
  end
end

-- Server-side roster request, throttled to once per 10s (SCOPE.md 4.4 G2).
local function requestGuild()
  if not IsInGuild or not IsInGuild() then return end
  local t = (GetTime and GetTime()) or 0
  if type(t) ~= "number" then return end
  if guildAsked > 0 and (t - guildAsked) < 10 then return end
  guildAsked = t
  if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
end

local function guildSet()
  -- an empty cache is always worth one rebuild attempt: the roster can arrive
  -- (or the player can join a guild) without us having seen the event yet
  if guildDirty or (not next(guildCache) and IsInGuild and IsInGuild()) then rebuildGuild() end
  -- a cold roster cache right after login must not refuse a legitimate commit
  -- forever: ask the server (throttled) so the next one succeeds
  if not next(guildCache) then requestGuild() end
  return guildCache
end

-------------------------------------------------------------------------------
-- Persisted shape (SCOPE.md 4.5) and migration from the v1 (0.5.0) shape
--
--   PG.db.ledger = {
--     ver = 2,
--     sessions = { ["YYYY-MM-DD"] = { <entry>, ... } },   -- ARRAY per day
--     lifetime = { ["Name-Realm"] = net },
--   }
--   <entry> = { id, game, host, scope, at, rows = { [name]=delta }, dismissed }
-------------------------------------------------------------------------------

local function sanitizeRows(src, cap)
  local out, n = {}, 0
  if type(src) ~= "table" then return out, 0 end
  for name, delta in pairs(src) do
    if not PG.IsSecret(name) and type(name) == "string" and name ~= ""
      and #name <= MAX_NAME and finite(delta) then
      if not cap or n < cap then
        out[name] = math.floor(delta)
        n = n + 1
      end
    end
  end
  return out, n
end

local function sanitizeEntry(e)
  if type(e) ~= "table" then return nil end
  local id = plainStr(e.id, MAX_ID)
  if not id then return nil end
  local rows, n = sanitizeRows(e.rows)
  if n == 0 then return nil end
  local scope = plainStr(e.scope, 8)
  if not scope or not SCOPES[scope] then scope = "group" end
  local at = tonumber(e.at)
  if not finite(at) or at < 0 then at = 0 end
  return {
    id = id,
    game = plainStr(e.game, 8) or "?",
    host = plainStr(e.host, MAX_NAME) or "?",
    scope = scope,
    at = math.floor(at),
    label = plainStr(e.label, MAX_LABEL),
    rows = rows,
    dismissed = (e.dismissed == true) or nil,
  }
end

-- A whole day in the v1 shape (a flat name -> net map) becomes ONE legacy
-- entry. Anything that fails to match a known shape is discarded, not guessed
-- at: a half-understood row is exactly the phantom debt the gates exist for.
local function legacyEntry(day, map)
  local rows, n = sanitizeRows(map)
  if n == 0 then return nil end
  return { id = "legacy:" .. day, game = "?", host = "?", scope = "group", at = 0, rows = rows }
end

local function isDayKey(day)
  return type(day) == "string" and day:find("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function prune(led)
  local stamp = nowStamp()
  if stamp <= 0 then return end
  local cutoff = date("%Y-%m-%d", stamp - DAYS_KEPT * 86400)
  if type(cutoff) ~= "string" then return end
  local drop = {}
  for day in pairs(led.sessions) do
    if type(day) ~= "string" or day < cutoff then drop[#drop + 1] = day end
  end
  for i = 1, #drop do led.sessions[drop[i]] = nil end
end

local function migrate(led)
  local days = {}
  for day in pairs(led.sessions) do days[#days + 1] = day end
  for i = 1, #days do
    local day = days[i]
    local val = led.sessions[day]
    local keep
    if isDayKey(day) and type(val) == "table" then
      if val[1] ~= nil then
        -- already an array of entries: keep the ones that still validate
        keep = {}
        for j = 1, #val do
          local e = sanitizeEntry(val[j])
          if e then keep[#keep + 1] = e end
        end
        if not keep[1] then keep = nil end
      elseif next(val) ~= nil then
        local e = legacyEntry(day, val)
        keep = e and { e } or nil
      end
    end
    led.sessions[day] = keep
  end
  led.ver = LEDGER_VER
  prune(led)
  debugLine("migrated saved ledger to ver " .. LEDGER_VER)
end

local prunedThisSession = false

-- The day we have already told the player their ledger is full, NOT a boolean.
-- MAX_SESSIONS_PER_DAY used to refuse silently, which was tolerable when three
-- games shared the cap; six games - and a Death Roll duel can finish inside a
-- minute - make 250 recorded sessions in one night imaginable, and a silent
-- stop means gold quietly stops being recorded with nothing on screen to say
-- so. A plain `fullWarned = true` would fire once per LOGIN, so a raid that
-- hits the cap before midnight and keeps playing past it would be dropped
-- silently for the whole of the next day - the precise failure the warning
-- exists to end. Keyed by date(), it warns once per day instead.
local fullWarnedDay = nil

local function ensureDB()
  local led = PG.db and PG.db.ledger
  if type(led) ~= "table" then return nil end
  if type(led.sessions) ~= "table" then led.sessions = {} end
  if type(led.lifetime) ~= "table" then led.lifetime = {} end
  if led.ver ~= LEDGER_VER then
    migrate(led) -- migrate prunes on its way through
    prunedThisSession = true
  elseif not prunedThisSession then
    -- DAYS_KEPT retention is a per-session job, not a one-time upgrade step:
    -- running it only inside migrate() meant an already-migrated file kept
    -- growing forever. One pass over the day keys, once, at load.
    prunedThisSession = true
    prune(led)
  end
  return led
end

-- Today's entry array, converting a stray v1 map in place (belt and braces:
-- migrate() has normally already done this at init).
local function dayList(led, day)
  local val = led.sessions[day]
  if type(val) ~= "table" then
    val = {}
    led.sessions[day] = val
  elseif val[1] == nil and next(val) ~= nil then
    local e = legacyEntry(day, val)
    val = e and { e } or {}
    led.sessions[day] = val
  end
  return val
end

-------------------------------------------------------------------------------
-- PG.Ledger.Commit - the ONLY writer, and the place the four gates live
-------------------------------------------------------------------------------

local REFUSAL_TEXT = {
  sum   = "this game's numbers don't add up - nothing was recorded.",
  bound = "this game's numbers don't add up - nothing was recorded.",
  row   = "this game's numbers don't add up - nothing was recorded.",
  vouch = "this game listed players this client can't verify - nothing was recorded.",
}

local function refuse(reason, label)
  local text = REFUSAL_TEXT[reason]
  if text then toast((label or "Pengyou Games") .. ": " .. text) end
  debugLine("refused commit (" .. reason .. ")")
  return false, reason
end

-- Commits one session's rows, all-or-nothing, with provenance.
--
-- meta = {
--   id     = "LG:Grizzle-Illidan:1a-7f3"   (required) game:host:token, unique
--   game   = "LG"                          (required) module code
--   host   = "Grizzle-Illidan"             (required) realm-qualified
--   scope  = "group"|"guild"|"public"      (required)
--   at     = time()                        (optional, defaults to now)
--   played = true                          (required) G1: I sat at this table
--   vouch  = { ["Name-Realm"] = true }     (roster snapshot; REQUIRED at public)
--   cap    = buyin * #roster               (optional) G3 per-row bound
--   label  = "Loot Goblins"                (optional) display label
-- }
-- rows = { ["Name-Realm"] = integerGoldDelta, ... }
--
-- Returns ok, reason. reason is one of "db", "meta", "scope", "notplayed",
-- "dup", "full", "vouch", "row", "bound", "sum". Refusals that mean "the
-- numbers or the names are wrong" toast; refusals that are normal traffic
-- (not a participant, duplicate commit) are silent.
function PG.Ledger.Commit(meta, rows)
  local led = ensureDB()
  if not led then return false, "db" end
  if type(meta) ~= "table" or type(rows) ~= "table" then return false, "meta" end

  -- G4 PROVENANCE. Every persisted row belongs to exactly one session, with
  -- the game, the host, the audience and the wall-clock time it was played, so
  -- a disputed row can be traced and dismissed on its own.
  local id = plainStr(meta.id, MAX_ID)
  local game = plainStr(meta.game, 8)
  local host = plainName(meta.host, true)
  local scope = plainStr(meta.scope, 8)
  if not id or not game or not host then return false, "meta" end
  if not game:find("^%a[%w]*$") then return false, "meta" end
  if not scope or not SCOPES[scope] then return false, "scope" end
  local at = PG.SafeNum(meta.at)
  if not finite(at) or at <= 0 then at = nowStamp() end
  at = math.floor(at)
  local label = plainStr(meta.label, MAX_LABEL) or GAME_LABEL[game] or game

  -- G1 PARTICIPATION. Rows are written ONLY for a session this client actually
  -- joined and played - at EVERY scope, party included. The caller declares it
  -- with meta.played, and the declaration must be corroborated by the rows
  -- themselves: a player who played has a row. Decliners, passers-by,
  -- spectators, referee hosts (CONCURRENCY.md I5) and clients merely
  -- overhearing a session keep their UI mirror and write nothing. This is what
  -- makes a public session safe and what keeps two concurrent sessions from
  -- producing divergent ledgers (CONCURRENCY.md 0.4).
  if meta.played ~= true then return false, "notplayed" end
  local me = PG.FullName("player")
  if not me or not finite(rows[me]) then return false, "notplayed" end

  local day = today()
  local list = dayList(led, day)
  for i = 1, #list do
    local e = list[i]
    if type(e) == "table" and e.id == id then return false, "dup" end
  end
  if #list >= MAX_SESSIONS_PER_DAY then
    -- Deliberately NOT routed through refuse(): "full" is not a claim that the
    -- numbers or the names are wrong, it is a capacity limit, and it needs to
    -- be said once per day rather than once per refused session - a raid that
    -- keeps playing would otherwise get one toast per game for the rest of the
    -- night. The cap NUMBER stays at 250 for the compatibility reason written
    -- above MAX_ROW_GOLD: raising it would make a 1.0.0 client refuse a row a
    -- 1.1.0 client writes for the same Loot Goblins game.
    if fullWarnedDay ~= day then
      fullWarnedDay = day
      toast("Pengyou Games: " .. MAX_SESSIONS_PER_DAY .. " games already recorded "
        .. "today - nothing more is being written to the ledger.")
    end
    return false, "full"
  end

  -- G2 VOUCHING sources. meta.vouch is the roster this client itself watched
  -- fill up (frozen at BEGIN); the live group and the guild cache are the
  -- independent ones. At public scope there is no independent source at all,
  -- so the witnessed roster is mandatory - a caller that forgets it writes
  -- nothing rather than persisting forty strings a stranger chose.
  local vouch = (type(meta.vouch) == "table") and meta.vouch or nil
  if scope == "public" and not vouch then return false, "vouch" end
  local group = groupSet()
  local guild = (scope ~= "group") and guildSet() or nil

  -- G3 BOUND. cap is the caller's own arithmetic bound (buyin * roster); the
  -- absolute ceiling applies regardless of what the caller claims.
  local cap = PG.SafeNum(meta.cap)
  if not finite(cap) or cap <= 0 or cap > MAX_ROW_GOLD then cap = MAX_ROW_GOLD end

  local out, count, sum = {}, 0, 0
  for name, delta in pairs(rows) do
    if PG.IsSecret(name) then return refuse("row", label) end
    local nm = plainName(name, true) -- G2: realm-qualified or it is not a player
    if not nm then return refuse("row", label) end
    if not finite(delta) or math.floor(delta) ~= delta then return refuse("row", label) end
    if delta > cap or delta < -cap then return refuse("bound", label) end
    if nm ~= me and not (vouch and vouch[nm] == true) and not group[nm]
      and not (guild and guild[nm]) then
      return refuse("vouch", label)
    end
    count = count + 1
    if count > MAX_ROWS_PER_SESSION then return refuse("row", label) end
    sum = sum + delta
    out[nm] = delta
  end
  if count == 0 then return false, "row" end
  -- G3 ZERO-SUM. Clients never recompute the host's parimutuel math, so this
  -- is the only statement they can check: gold moved between the players at
  -- this table and nowhere else. Refusal is all-or-nothing for the whole
  -- session, never per-row - a partial write is not zero-sum and produces
  -- exactly the phantom debt the check exists to prevent.
  if sum ~= 0 then return refuse("sum", label) end

  local entry = { id = id, game = game, host = host, scope = scope, at = at, rows = out }
  if label ~= (GAME_LABEL[game] or game) then entry.label = label end
  list[#list + 1] = entry

  local life = led.lifetime
  for name, delta in pairs(out) do
    life[name] = (tonumber(life[name]) or 0) + delta
  end

  debugLine("committed " .. id .. " (" .. count .. " rows, " .. scope .. ")")
  if Refresh then Refresh() end
  return true
end

-- True if this session id has already been committed today (dismissed or not).
-- Callers use it to stay idempotent across a resync replay of the same END.
function PG.Ledger.Committed(id)
  local led = ensureDB()
  local key = plainStr(id, MAX_ID)
  if not led or not key then return false end
  local list = dayList(led, today())
  for i = 1, #list do
    local e = list[i]
    if type(e) == "table" and e.id == key then return true end
  end
  return false
end

-- Today's non-dismissed session entries, newest first. Rows are copies: the
-- caller can sort/annotate them without touching SavedVariables.
function PG.Ledger.Sessions()
  local led = ensureDB()
  local out = {}
  if not led then return out end
  local list = dayList(led, today())
  for i = 1, #list do
    local e = list[i]
    if type(e) == "table" and not e.dismissed then
      local rows = sanitizeRows(e.rows)
      out[#out + 1] = {
        id = e.id, game = e.game, host = e.host, scope = e.scope,
        at = tonumber(e.at) or 0, label = e.label, rows = rows, seq = i,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.seq > b.seq
  end)
  return out
end

-- Unwinds one session entry from the lifetime totals and marks it dismissed;
-- Tonight/Settle Up stop counting it immediately. The entry itself is kept so
-- a replayed commit of the same id cannot resurrect it.
function PG.Ledger.Dismiss(id)
  local led = ensureDB()
  local key = plainStr(id, MAX_ID)
  if not led or not key then return false end
  local list = dayList(led, today())
  for i = 1, #list do
    local e = list[i]
    if type(e) == "table" and e.id == key and not e.dismissed then
      local life = led.lifetime
      for name, delta in pairs(e.rows or {}) do
        if type(name) == "string" and finite(delta) then
          local net = (tonumber(life[name]) or 0) - delta
          life[name] = (net ~= 0) and net or nil
        end
      end
      e.dismissed = true
      debugLine("dismissed " .. key)
      if Refresh then Refresh() end
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- PG.Ledger.Add is GONE (SCOPE.md 4.5).
--
-- A single row cannot be zero-sum and carries no provenance, so it could never
-- pass the gates on its own; the 0.5.x shim that batched Add calls into a
-- Commit had to assert `played = true` on the caller's behalf, which is a G1
-- bypass sitting in the public API. Every caller now uses PG.Ledger.Commit,
-- which is the only way to supply a real session id, host, scope and roster
-- snapshot - and the only writer.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Reads: tonight's nets and the settlement plan
-------------------------------------------------------------------------------

-- Tonight's nets: array of { name = "Name-Realm", net = integerGold }, sorted
-- net descending, ties by name (byte order). Sums every non-dismissed session
-- entry of today; includes zero-net entries.
function PG.Ledger.Tonight()
  local nets = {}
  for _, s in ipairs(PG.Ledger.Sessions()) do
    for name, delta in pairs(s.rows) do
      nets[name] = (nets[name] or 0) + delta
    end
  end
  local out = {}
  for name, net in pairs(nets) do
    out[#out + 1] = { name = name, net = net }
  end
  table.sort(out, function(a, b)
    if a.net ~= b.net then return a.net > b.net end
    return a.name < b.name
  end)
  return out
end

-- Greedy deterministic settlement of tonight's nets: array of
-- { from = debtorName, to = creditorName, amount = integerGold }.
-- Repeatedly matches the largest debtor with the largest creditor (ties ->
-- alphabetical), transferring min(|debt|, credit) until all zero.
function PG.Ledger.Settlement()
  local debtors, creditors = {}, {}
  for _, row in ipairs(PG.Ledger.Tonight()) do
    if row.net < 0 then
      debtors[#debtors + 1] = { name = row.name, amt = -row.net }
    elseif row.net > 0 then
      creditors[#creditors + 1] = { name = row.name, amt = row.net }
    end
  end
  local function takeLargest(list)
    local best
    for i = 1, #list do
      local e = list[i]
      if not best or e.amt > best.amt or (e.amt == best.amt and e.name < best.name) then
        best = e
      end
    end
    return best
  end
  local function removeZero(list)
    for i = #list, 1, -1 do
      if list[i].amt == 0 then table.remove(list, i) end
    end
  end
  local out = {}
  while debtors[1] and creditors[1] do
    local d = takeLargest(debtors)
    local c = takeLargest(creditors)
    local x = math.min(d.amt, c.amt)
    out[#out + 1] = { from = d.name, to = c.name, amount = x }
    d.amt = d.amt - x
    c.amt = c.amt - x
    removeZero(debtors)
    removeZero(creditors)
  end
  return out
end

-- Local effect only: wipes tonight's session entries. Lifetime totals keep
-- their history (unchanged semantics).
function PG.Ledger.ClearTonight()
  local led = ensureDB()
  if led then led.sessions[today()] = nil end
end

-------------------------------------------------------------------------------
-- Ledger window: "Tonight" (grouped by session, per-session dismiss) and
-- "Settle Up" tabs + "Clear tonight" confirm.
-------------------------------------------------------------------------------

local ensureWindow

-- 420x548: the same rect the Rules window uses, so the two list-bearing hub
-- windows are one size, one inset and one rhythm.
local WIN_W, WIN_H = 420, 548

local win, tabTonightBtn, tabSettleBtn, confirm
local rows, values, dismissBtns = {}, {}, {}
local emptyFS
local dismissMax = 0 -- dismissBtns is sparse (headers only): '#' would lie
local activeTab = "tonight"

-- EVERY ONE OF THESE IS DERIVED. MAX_LINES used to be the literal 15, which is
-- what hid the second session of the night: a 40-player game is 42 display
-- items, so a second session's header - and therefore its [x], the only route
-- to PG.Ledger.Dismiss - simply never rendered, and the only way out was
-- "Clear tonight", which wipes everything. The sheet meanwhile stretched to
-- fill the window while the cap stayed 15, leaving a slab of empty parchment
-- under the last row. ensureWindow computes all four from the window it just
-- built; the literals here are only what a Refresh before the first build
-- would see, and that path returns early anyway.
local INSET      = 24
local ROWS_TOP   = -102 -- first row's TOPLEFT y, 8px inside the sheet
local ROW_PITCH  = 20   -- 12pt line + 8 leading: the one well-tuned rhythm here
local ROW_LINE_H = 14   -- a 12pt line including its descenders
local SHEET_BOT  = 54   -- the sheet's BOTTOMRIGHT y offset (footer + its gap)
local AMT_W      = 100  -- the money column: "+4,000,000g" with its coin glyph
local AMT_GAP    = 8
local ROW_INDENT = 16   -- a real hanging indent, not three proportional spaces
local MAX_LINES  = 15
local ROW_W      = WIN_W - INSET * 2
local HEAD_W     = ROW_W - 32 -- clears the header's own dismiss button
local EMPTY_Y    = ROWS_TOP - 60 -- the empty state sits mid-sheet, not at row 1

-- Bright defaults (today's look). When the theme layer is present the init
-- block swaps them for the parchment palette and sets INK, matching the
-- parchment sheet the rows then render on. The sheet and its ink are the one
-- sanctioned dark-on-light surface in the addon (with the ticket-stub card
-- face); nothing else in this file may reach for a parchment colour.
-- Presentation only; every value is a plain escape-code string.
local GREEN, RED, GRAY, GOLD = "|cff40ff40", "|cffff5050", "|cffaaaaaa", "|cffffd200"
-- The empty state is the only line that is ever alone on screen, so it does not
-- take GRAY: on the parchment sheet GRAY resolves to FADE (#6b5c42), which is
-- ~3.5:1 and was the lowest-contrast text in the window. It takes AMBER.
local EMPTY = "|cffaaaaaa"
local INK -- floats; nil -> rows keep the plain white look

local function mark(key)
  if PG.Theme and PG.Theme.Mark then return PG.Theme.Mark(key) end
  return ""
end

local function tmoney(g)
  if PG.Theme and PG.Theme.Money then return PG.Theme.Money(g) end
  return PG.Money(g)
end

local function fontOf(which)
  if PG.Theme and PG.Theme.FontTemplate then return PG.Theme.FontTemplate(which) end
  return "GameFontHighlight"
end

local function inkify(fs)
  if INK then fs:SetTextColor(INK[1], INK[2], INK[3]) end -- ink on parchment
  return fs
end

-- The label column. Anchored per refresh rather than at creation, because the
-- indent is per item now (a session's player rows hang under their header).
local function rowAt(i)
  if not rows[i] then
    local fs = win:CreateFontString(nil, "OVERLAY", fontOf("B"))
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    inkify(fs)
    rows[i] = fs
  end
  return rows[i]
end

-- THE MONEY COLUMN. Money is right-aligned in its own column and the NAME is
-- what truncates now. Before this, a settle line was one no-wrap string ending
-- in the amount - "Name-Realm pays Name-Realm 1,250g" - so two cross-realm
-- names (the common case in a pug raid, not the edge case) pushed the line past
-- its width and the ellipsis ate the number the player opened the window for.
-- A line that says who pays whom and refuses to say how much is the worst
-- possible failure for this window.
local function valueAt(i)
  if not values[i] then
    local fs = win:CreateFontString(nil, "OVERLAY", fontOf("B"))
    fs:SetWidth(AMT_W)
    fs:SetJustifyH("RIGHT")
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    inkify(fs)
    values[i] = fs
  end
  return values[i]
end

-- One [x] per visible session header. The pool is indexed by LINE, so a button
-- is only ever created for a line that has actually shown a header.
--
-- UIPanelCloseButton at 24x24, not an 18x18 UIPanelButtonTemplate labelled with
-- a lowercase "x": that template's nine-slice art is drawn for >=22px and
-- squashed at 18, and every other dismiss in the addon is a close button.
-- Closing something is one gesture with one shape.
local function dismissAt(i)
  if not dismissBtns[i] then
    local b = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    b:SetSize(24, 24)
    -- the template ships an OnClick that hides its parent; ours dismisses one
    -- session and must replace it, or the button would close the whole window
    b:SetScript("OnClick", function(self)
      if self.__pgId then PG.Ledger.Dismiss(self.__pgId) end
    end)
    dismissBtns[i] = b
    if i > dismissMax then dismissMax = i end
  end
  return dismissBtns[i]
end

-- The empty state gets its own centred line across the sheet instead of being
-- written into roster row 1, where it inherited the row inset and the left
-- justification of a list and read as "here is item zero" rather than "there
-- is nothing here". It is also the one time a line is the only thing on
-- screen, so it takes AMBER rather than the ~3.5:1 FADE it used to have.
local function emptyAt()
  if not emptyFS then
    emptyFS = win:CreateFontString(nil, "OVERLAY", fontOf("B"))
    emptyFS:SetPoint("TOPLEFT", INSET, EMPTY_Y)
    emptyFS:SetPoint("TOPRIGHT", -INSET, EMPTY_Y)
    emptyFS:SetJustifyH("CENTER")
    emptyFS:SetWordWrap(true)
    emptyFS:SetMaxLines(2)
  end
  return emptyFS
end

local function netText(net)
  local color = (net > 0 and GREEN) or (net < 0 and RED) or GRAY
  return color .. ((net > 0 and "+" or "") .. tmoney(net)) .. "|r"
end

-- ONE selection idiom for the whole addon: the selected tab is PAINTED, never
-- forbidden. This window used to grey its selected tab out with SetEnabled
-- while the Rules window, two clicks away, brightened its selected tab and
-- dimmed the rest - two opposite answers to one question. The scope picker's
-- reasoning wins everywhere: a disabled face plus the accent tint plus a gold
-- label, so "selected" can never be read as "forbidden". The colour escape is
-- load-bearing; it is what renders gold through the disabled font object.
local function paintTabs()
  if not (tabTonightBtn and tabSettleBtn) then return end
  local c = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local sel = (c and c.chgold) or "|cffffd876"
  local pair = { { tabTonightBtn, "tonight" }, { tabSettleBtn, "settle" } }
  for i = 1, #pair do
    local b, tab = pair[i][1], pair[i][2]
    if activeTab == tab then
      b:SetEnabled(false)
      b:SetText(sel .. b.__pgLabel .. "|r")
      if b.tint then b.tint:Show() end
    else
      b:SetEnabled(true)
      b:SetText(b.__pgLabel)
      if b.tint then b.tint:Hide() end
    end
    b:SetAlpha(1)
  end
end

-- "Loot Goblins - Grizzle - Party - 21:34". The audience is spelled out
-- because "who was this game with" is the first question a disputed row
-- raises; imported pre-0.6.0 rows say so instead of inventing provenance.
--
-- THE NAME POLICY, stated so it stops reading as an accident: a header names
-- the host with shortName because the host here is PROVENANCE - context for the
-- session - while every row and every settle line carries the full Name-Realm
-- because those name a COUNTERPARTY you are about to trade gold with, and two
-- Grizzles on two realms settling different amounts is a wrong-person-paid bug.
-- Full names in the header instead would push the worst real header
-- ("Loot Goblins - Name-BlackwaterRaiders - Public - 23:59", ~347px) past the
-- 340px this line has once its dismiss button is reserved, i.e. it would trade
-- a cosmetic inconsistency for a real truncation.
--
-- The line is BOUND (HEAD_W, wrap off, one line), so meta.label's 48-character
-- allowance can only ever cost an ellipsis here, never an overflow.
local function headerText(s)
  if s.game == "?" then return GOLD .. "Earlier games (imported)|r" end
  local text = (s.label or GAME_LABEL[s.game] or s.game)
    .. " - " .. shortName(s.host)
    .. " - " .. (SCOPE_LABEL[s.scope] or s.scope)
  if s.at and s.at > 0 then
    local when = date("%H:%M", s.at)
    if type(when) == "string" then text = text .. " - " .. when end
  end
  return GOLD .. text .. "|r"
end

-- Display items for the Tonight tab: one header per session (dismissable),
-- then that session's rows, net descending.
--
-- An item is { text = <label column>, value = <money column>, indent = <px>,
-- head = true, id = <session id> }. The empty case returns NOTHING and lets
-- Refresh show the centred empty state; it used to be items[1], which also
-- meant the settle tab's section glyph was prepended to the empty message and
-- a section marker sometimes rendered as a bullet on a sentence.
local function tonightItems()
  local items = {}
  local sessions = PG.Ledger.Sessions()
  if not sessions[1] then return items end
  local me = PG.FullName("player")
  local mine
  for _, row in ipairs(PG.Ledger.Tonight()) do
    if row.name == me then mine = row.net end
  end
  if mine then
    items[#items + 1] = { text = "Tonight you are at", value = netText(mine) }
  end
  for _, s in ipairs(sessions) do
    items[#items + 1] = { head = true, id = s.id, text = headerText(s) }
    local list = {}
    for name, net in pairs(s.rows) do
      list[#list + 1] = { name = name, net = net }
    end
    table.sort(list, function(a, b)
      if a.net ~= b.net then return a.net > b.net end
      return a.name < b.name
    end)
    for _, r in ipairs(list) do
      -- a real anchor offset, not three literal spaces: the old indent was
      -- three PROPORTIONAL spaces, so it changed size with the font
      items[#items + 1] = { text = r.name, value = netText(r.net), indent = ROW_INDENT }
    end
  end
  return items
end

local function settleItems()
  local me = PG.FullName("player")
  local items = {}
  for _, t in ipairs(PG.Ledger.Settlement()) do
    local line
    if t.from == me then
      line = GOLD .. "YOU pay " .. t.to .. "|r"
    elseif t.to == me then
      line = GOLD .. t.from .. " pays YOU|r"
    else
      line = t.from .. " pays " .. t.to
    end
    items[#items + 1] = { text = line, value = tmoney(t.amount) }
  end
  -- treasure-sack section glyph heads the settle list: markup, zero frames.
  -- It can only ever head a real transfer now, never the empty state.
  if items[1] then
    local glyph = mark("sack")
    if glyph ~= "" then items[1].text = glyph .. " " .. items[1].text end
  end
  return items
end

Refresh = function()
  if not win then return end
  paintTabs()
  local items = activeTab == "tonight" and tonightItems() or settleItems()
  local shown = math.min(#items, MAX_LINES)
  if #items > MAX_LINES then
    items[MAX_LINES] = { text = GRAY .. "... and " .. (#items - MAX_LINES + 1) .. " more|r" }
  end
  -- every [x] goes down first: a stale id on a hidden-then-reshown button
  -- would dismiss the wrong session
  for i = 1, dismissMax do
    local b = dismissBtns[i]
    if b then
      b.__pgId = nil
      b:Hide()
    end
  end
  for i = 1, shown do
    local item = items[i]
    local y = ROWS_TOP - (i - 1) * ROW_PITCH
    local indent = item.indent or 0
    local fs = rowAt(i)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", INSET + indent, y)
    if item.head then
      fs:SetWidth(HEAD_W - indent)
    elseif item.value then
      fs:SetWidth(ROW_W - indent - AMT_W - AMT_GAP)
    else
      fs:SetWidth(ROW_W - indent)
    end
    fs:SetText(item.text)
    fs:Show()
    -- one value FontString per shown line, always, so the pool stays dense and
    -- the hide sweep below can trust '#values'
    local v = valueAt(i)
    v:ClearAllPoints()
    v:SetPoint("TOPRIGHT", -INSET, y)
    v:SetText(item.value or "")
    v:Show()
    if item.head then
      local b = dismissAt(i)
      b.__pgId = item.id
      -- centred on the header's own line: the row is ROW_LINE_H tall and the
      -- button is 24, so it rides (24 - ROW_LINE_H) / 2 above the row's top
      b:ClearAllPoints()
      b:SetPoint("TOPRIGHT", -(INSET - 4), y + math.floor((24 - ROW_LINE_H) / 2))
      b:Show()
    end
  end
  for i = shown + 1, #rows do
    rows[i]:Hide()
  end
  for i = shown + 1, #values do
    values[i]:Hide()
  end
  local empty = emptyAt()
  if shown == 0 then
    empty:SetText(EMPTY .. ((activeTab == "tonight")
      and "No games recorded tonight."
      or "All square - nothing to settle.") .. "|r")
    empty:Show()
  else
    empty:Hide()
  end
end

local function buildConfirm()
  confirm = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  confirm:SetSize(300, 100)
  confirm:SetPoint("CENTER", 0, 60)
  confirm:SetFrameStrata("DIALOG")
  confirm:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  confirm:SetBackdropColor(0, 0, 0, 0.9)
  local text = confirm:CreateFontString(nil, "OVERLAY", fontOf("B"))
  text:SetPoint("TOPLEFT", 16, -16)
  text:SetPoint("TOPRIGHT", -16, -16)
  -- one self-contained sentence on a symmetric popup: centred, like the Ask
  text:SetJustifyH("CENTER")
  text:SetWordWrap(true)
  text:SetMaxLines(3)
  text:SetText("Clear tonight's ledger? This only affects what you see.")
  local yes = PG.UI.Button(confirm, "Clear", 105, 22, function()
    PG.Ledger.ClearTonight()
    confirm:Hide()
    Refresh()
  end)
  yes:SetPoint("BOTTOMLEFT", 20, 16)
  local no = PG.UI.Button(confirm, "Cancel", 105, 22, function() confirm:Hide() end)
  no:SetPoint("BOTTOMRIGHT", -20, 16)
  -- the one skin + a parchment inset behind the warning text; the plain dark
  -- look above stays the fallback. No animation beyond Pop.
  if PG.Theme and PG.Theme.Skin then
    PG.Theme.Skin(confirm, "PG")
    if PG.Theme.Tex then
      local inset = confirm:CreateTexture(nil, "ARTWORK", nil, -8)
      inset:SetPoint("TOPLEFT", 8, -8)
      inset:SetPoint("BOTTOMRIGHT", -8, 44)
      PG.Theme.Tex(inset, "parchment") -- fail -> solid PARCH (applied by Tex)
    end
    local c = PG.Theme.C()
    text:SetTextColor(c.INK[1], c.INK[2], c.INK[3])
    -- CHRED, not LOSS. LOSS (#8f1600) is a parchment colour and this label sits
    -- on the dark UIPanelButtonTemplate face, where it measured ~1.8:1 -
    -- effectively unreadable, on the one button in the addon that destroys
    -- data. The launcher already uses the bright CHRED for the same semantic
    -- on the same button art.
    yes:SetText(c.chred .. "Clear|r")
  end
  PG.Safety.RegisterWindow(confirm)
  confirm:Hide()
end

ensureWindow = function()
  if win then return end
  win = PG.UI.Window("ledger", "Pengyou Ledger", WIN_W, WIN_H, "PG")

  local M = (PG.Theme and PG.Theme.METRIC) or nil
  INSET = (M and M.INSET) or INSET
  ROW_PITCH = (M and M.ROW_PITCH) or ROW_PITCH
  local FOOTER = (M and M.FOOTER) or 16
  local SECTION = (M and M.SECTION) or 16
  local BTN_H = (M and M.BTN_H) or 22
  local BTN_W = (M and M.BTN_W) or 105
  local first = ((M and M.TITLE_TOP) or -12) - ((M and M.TITLE_H) or 24)
                - ((M and M.TITLE_GAP) or 20)
  local TAB_GAP = 12
  local TAB_W = math.floor((WIN_W - INSET * 2 - TAB_GAP * 2) / 3) -- Rules' tab

  -- the sheet's bottom clears the footer button and its own section gap
  SHEET_BOT = FOOTER + BTN_H + SECTION
  local sheetTop = first - BTN_H - SECTION
  ROWS_TOP = sheetTop - 8
  ROW_W = WIN_W - INSET * 2
  HEAD_W = ROW_W - 32
  -- DERIVED, and this is the whole point: the band between the first row and
  -- the bottom of the sheet, divided by the row pitch. It follows the window
  -- instead of being a literal that stopped matching it.
  local band = (WIN_H - SHEET_BOT) + ROWS_TOP
  MAX_LINES = math.max(1, math.floor((band - ROW_LINE_H) / ROW_PITCH) + 1)
  EMPTY_Y = ROWS_TOP - math.floor(band / 2)

  -- parchment sheet under the rows area; the asset chain in Theme.Tex ends in
  -- solid PARCH, so the ink rows always sit on parchment. This and the confirm
  -- dialog's inset are the addon's only sanctioned parchment surfaces.
  if PG.Theme and PG.Theme.Tex then
    local sheet = win:CreateTexture(nil, "ARTWORK", nil, -8)
    sheet:SetPoint("TOPLEFT", 16, sheetTop)
    sheet:SetPoint("BOTTOMRIGHT", -16, SHEET_BOT)
    PG.Theme.Tex(sheet, "sheet")
  end

  local function tab(label, x, onClick)
    local b = PG.UI.Button(win, label, TAB_W, BTN_H, onClick)
    b:SetPoint("TOPLEFT", x, first)
    b.__pgLabel = label
    local c = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
    local t = (c and c.VIOLET) or { 0.45, 0.32, 0.68 }
    b.tint = b:CreateTexture(nil, "OVERLAY")
    b.tint:SetAllPoints()
    b.tint:SetColorTexture(t[1], t[2], t[3], 0.16)
    b.tint:SetBlendMode("ADD")
    b.tint:Hide()
    return b
  end

  tabTonightBtn = tab("Tonight", INSET, function()
    activeTab = "tonight"
    Refresh()
  end)
  tabSettleBtn = tab("Settle Up", INSET + TAB_W + TAB_GAP, function()
    activeTab = "settle"
    Refresh()
  end)
  -- page-turn garnish on manual tab switches (gated inside Theme.Sound)
  if PG.Theme and PG.Theme.Sound then
    tabTonightBtn:HookScript("OnClick", function() PG.Theme.Sound("page") end)
    tabSettleBtn:HookScript("OnClick", function() PG.Theme.Sound("page") end)
  end
  local clearBtn = PG.UI.Button(win, "Clear tonight", BTN_W, BTN_H, function()
    if not confirm then buildConfirm() end
    confirm:Show()
  end)
  clearBtn:SetPoint("BOTTOMLEFT", INSET, FOOTER)
end

-- Opens (and refreshes) the ledger window.
function PG.Ledger.Show()
  ensureWindow()
  Refresh()
  local wasShown = win:IsShown()
  win:Show()
  if not wasShown and PG.Theme and PG.Theme.Sound then
    PG.Theme.Sound("parchment") -- manual open only; gated inside Theme.Sound
  end
end

PG.RegisterInit(function()
  -- Swap to the dark-on-parchment palette when the theme layer is present;
  -- without it the bright defaults above remain. THESE STAY PARCHMENT COLOURS:
  -- the rows sit on the parchment sheet, which is the one sanctioned
  -- dark-on-light surface. EMPTY is the exception - FADE on parchment is
  -- ~3.5:1, and the empty state is the one line that is ever alone on screen.
  if PG.Theme and PG.Theme.C then
    local c = PG.Theme.C()
    GREEN, RED, GRAY, GOLD = c.win, c.loss, c.fade, c.amber
    EMPTY = c.amber
    INK = c.INK
  end
  -- migrate the saved ledger to ver 2 once, at load, before anything reads it
  ensureDB()
  -- guild roster cache for name vouching (SCOPE.md 4.4 G2): one request at
  -- login, refreshed whenever the server sends the roster
  requestGuild()
  PG.RegisterEvent("GUILD_ROSTER_UPDATE", markGuildDirty)
end)
