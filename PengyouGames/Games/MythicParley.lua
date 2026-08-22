-- Games/MythicParley.lua - The Mythic Parley: pre-key betting on a whole M+ run.
--
-- The Pull Book's second mode (PARLEY.md), and a sibling of PullBook.lua rather
-- than a branch inside it. The two share a shape - keyed registry, one full
-- record, lite records for overheard tables, parimutuel settlement, the frozen
-- report - and share no mutable state at all. That is deliberate: a raid book
-- and a guild parley can legitimately be live at the same time (you are raiding
-- while a guildmate pushes a key), and folding them into one `mine` slot would
-- make the suite's most common cross-mode case the one it forbids.
--
-- THE FIRST FACT THIS FILE EXISTS FOR: inside an active keystone,
-- C_ChatInfo.InChatMessagingLockdown() is true for the WHOLE RUN and every send
-- is refused permanently. There is no in-run message, no fallback, and none is
-- coming (Blizzard actively closes in-lockdown side channels). So:
--
--   * every bet is committed BEFORE the key starts,
--   * the run is observed by the bookie's own client with zero traffic,
--   * exactly one broadcast - RES - crosses back when the lockdown lifts.
--
-- THE SECOND FACT, and the one that decided this file's whole shape: A MYTHIC+
-- ROUTE DOES NOT VISIT BOSSES IN A FIXED ORDER. Skips, route choice and plain
-- preference mean "the second boss" is not a thing that exists. Every per-boss
-- market therefore keys on that boss's own dungeonEncounterID - the same number
-- ENCOUNTER_END reports - and never on the position it was met in. Order
-- appears in exactly two places here: the order buttons are drawn in, and the
-- single question "which boss did we wall on FIRST", which still resolves to an
-- id. Nothing else in this file may use a boss's index for anything.
--
-- The Mythic Parley NEVER takes the round-based seat (CONCURRENCY.md I10, the
-- Pull Book's exemption for the Pull Book's reason): it is passive betting and
-- runs alongside anything. This file contains ZERO calls into the session
-- layer, permanently, verified with the escaped-dot pattern
--     grep -n 'PG\.Session\.' PengyouGames/Games/MythicParley.lua
-- and never with a search for the bare word: the comment that documents an
-- invariant contains the invariant's own name, so a bare-name grep can never
-- come back empty and stops being a check at all.
local ADDON, PG = ...

-- TUNING (K) and WINDOW GEOMETRY (G) are two tables rather than fifty locals,
-- and that is a language limit rather than a style: Lua 5.1 allows 200 locals
-- per function and this file's main chunk is one function with a hundred-odd
-- named functions already in it. Grouping the numbers is what buys the room,
-- and grouping them by JOB - what the game does, and where it draws - keeps
-- them findable. Each still carries the comment that explains it.
local K, G = {}, {}

PG.MP = {}

-- Read by PG.UI.ScopePicker (SCOPE.md 1.2 / 5.2, PARLEY.md 3.3). Guild is the
-- POINT of this mode - the three people running the key are not the seventeen
-- who want to bet on it - and it is available here, and only here, because a
-- key produces one discrete machine-read result at one known moment.
PG.MP.SCOPES = { group = true, guild = true, public = false }

-- The launcher's Join gate reads this flag rather than naming a module code in
-- its own source (BRIEF 1.1). Declaring it is not a USE of the session layer,
-- so the zero-calls invariant above still holds.
PG.MP.SEAT = false

K.INSET = 24            -- METRIC.INSET, mirrored (file scope may not read
                            -- another module's tables)

K.STAKE_MIN, K.STAKE_MAX = 1, 100000

K.HB_SECS = 15
K.HB_MISS_SECS = 50     -- group scope: the Pull Book's number
-- Guild scope: the RPS/DR/GB number (SCOPE.md 6.2). Outside the group our own
-- safety state says nothing about the bookie's, so a bookie in an encounter or
-- a loading screen must read as quiet, not dead.
K.HB_MISS_WIDE = 300
-- The roster rides its own message and is re-sent every fourth heartbeat - once
-- a minute - so a guildmate who joins from the launcher two minutes late still
-- gets boss names on their board.
K.ROSTER_EVERY_HB = 4

-- PARLEY.md 5: every client stops SENDING bets at its own LOCK moment and keeps
-- ACCEPTING them for this long afterwards. Since no client sends past its own
-- receipt, and receipts are within delivery latency of each other, two seconds
-- of symmetric grace makes every client accept the identical bet set.
K.LOCK_GRACE = 2
-- A locked parley whose RES never arrives (the bookie disconnected mid-key)
-- voids and returns every stake. 90 minutes clears any real key.
K.LOCK_MAX = 5400
-- Ticks the active-key probe must come back empty before the run is declared
-- abandoned. 6 ticks = 3 seconds: a loading screen and then some, and
-- CHALLENGE_MODE_COMPLETED gets every chance to land first, because this branch
-- VOIDS and a false void refunds a key that really was run.
K.GONE_TICKS = 6
-- RES resend schedule, in seconds after completion.
local RES_RETRIES = { 0, 2, 6, 12, 25 }

-- Registry budget (CONCURRENCY.md 2.1 / 7.3), the Pull Book's numbers.
K.MAX_LITE = 8
K.MAX_RECENT = 16
K.RECENT_TTL = 120
K.LITE_TTL = K.HB_MISS_WIDE + 10
K.TICK = 0.5            -- the module's ONE ticker; sweeps every 4th tick
K.MAX_REVEAL_Q = 6

-- THE CARD. The bookie posts up to five lines and no more, and the number is a
-- rule about the POOL rather than about the screen. A parimutuel market needs
-- at least one backer on each side or it voids; spread five people across a
-- dozen markets and most of them void, which is a worse game than four markets
-- that all pay. Five is what a five-person party can actually fill, and it
-- makes a guild parley concentrate rather than sprawl for the same reason.
K.MAX_LINES = 5

-- Bosses per dungeon. Retail M+ dungeons run three or four; six is headroom,
-- and it is also the widest option row the board can draw (see G.OPT_GEO).
K.MAX_BOSSES = 6
K.MAX_BOSS_NAME = 24    -- wire budget for one name

K.RES_COUNT_MAX = 999   -- upper bound on any count arriving over the wire

-- Ledger.lua's MAX_ROWS_PER_SESSION, mirrored as a literal (file scope may not
-- read another module's locals). A line with more backers than this voids
-- rather than being refused at commit time - see settleLine.
K.MAX_LEDGER_ROWS = 40

-------------------------------------------------------------------------------
-- THE MARKET CATALOGUE
--
-- Ten line types. A card LINE is { t = <type>, boss = <dungeonEncounterID>,
-- line = <number> }; which of the two optional fields a type carries is
-- declared HERE and nowhere else, because the wire codec reads this table to
-- decide how many fields an encoded entry has. Add a type and the codec, the
-- builder and the board all learn it; add one without a `bet` string and the
-- settlement sentence says nil.
--
--   boss = "one"   the line is about ONE named boss and carries its id
--   boss = "pick"  the line's OPTIONS are the bosses; it carries no id
--   line = n       the line carries an over/under value, defaulting to n
--
-- `bet` is the noun a settlement sentence is built from ("Deaths bet: 2 winners
-- split 400g"); `label` is what fits the board's label column. Separate fields
-- because they are separate jobs - a label that also read as a sentence
-- fragment would be too wide for the row.
-------------------------------------------------------------------------------

local OU = { { "OVER", "O" }, { "UNDER", "U" } }

local MARKET = {
  T = { label = "Timed?",      bet = "Time the key",
        opts = { { "YES", "Y" }, { "NO", "N" } } },
  X = { label = "Deaths",      bet = "Deaths",       opts = OU,
        line = 6, min = 0, max = 99 },
  A = { label = "Boss wipes",  bet = "Boss wipes",   opts = OU,
        line = 1, min = 0, max = 20 },
  M = { label = "Time left",   bet = "Time left",    opts = OU,
        line = 5, min = 0, max = 90, unit = "m" },
  F = { label = "First death", bet = "First death",
        opts = { { "TANK", "T" }, { "HEALER", "H" }, { "DPS", "D" } } },
  L = { label = "First wall",  bet = "First wall",   boss = "pick" },
  W = { label = "Worst boss",  bet = "Worst boss",   boss = "pick" },
  O = { label = "%s one-shot?", bet = "%s one-shot", boss = "one",
        opts = { { "YES", "Y" }, { "NO", "N" } } },
  P = { label = "%s attempts",  bet = "%s attempts", boss = "one", opts = OU,
        line = 1, min = 1, max = 20 },
  D = { label = "%s deaths",    bet = "%s deaths",   boss = "one", opts = OU,
        line = 2, min = 0, max = 50 },
}

-- Display order in the card builder: run-level first (they need nothing at
-- all), then the two whole-dungeon boss markets, then three per boss.
local RUN_TYPES = { "T", "X", "A", "M", "F" }
local DUNGEON_TYPES = { "L", "W" }
local PER_BOSS_TYPES = { "O", "P", "D" }

-- Only these arrive from the bookie, and gate g resolves them against
-- (sender, token) - so the sender IS the record's bookie by construction.
local BOOKIE_AUTHORED = { CLOSE = true, HB = true, LOCK = true, RES = true,
                          ROSTER = true }

-------------------------------------------------------------------------------
-- Presentation. Markup and colour only: every helper degrades to plain text /
-- today's look when the theme layer is absent, and no gameplay path branches on
-- any of it.
-------------------------------------------------------------------------------

local P = {
  chgold = "|cffffd876", chgreen = "|cff7deda4", chred = "|cffff8a70",
  chgray = "|cffa8a89c", win = "|cff145214",
  CHALK = { 0.95, 0.93, 0.87 }, CHGOLD = { 1.00, 0.85, 0.46 },
  CHGRAY = { 0.66, 0.66, 0.61 }, INK = { 0.25, 0.17, 0.08 },
}

local function mark(key)
  if PG.Theme and PG.Theme.Mark then return PG.Theme.Mark(key) end
  return ""
end

local function tmoney(g)
  if PG.Theme and PG.Theme.Money then return PG.Theme.Money(g) end
  return PG.Money(g)
end

local function shadow(fs)
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(fs) end
end

local MARKET_ICON = { T = "keystone", X = "skull", A = "tarotW", M = "keystone",
                      F = "tarotD", L = "tarotK", W = "tarotK",
                      O = "tarotK", P = "tarotW", D = "skull" }

-- Where a roster came from, in words. Declared up here with the other constant
-- tables because BOTH the card page and /pg keys read it, and the card page is
-- built long before the diagnostic is defined.
local SRC_WORD = {
  shipped = "shipped with the addon", saved = "remembered",
  journal = "Encounter Journal", map = "Encounter Journal (this map)",
  learned = "learned from a run",
}

local WIDE_SCOPE_REASON =
  "The Mythic Parley pays out from one client's read of one key. Your guild can "
  .. "check who ran it; a stranger on the realm channel cannot."

-------------------------------------------------------------------------------
-- State
--
-- parleys[key] = record, key = bookie .. "|" .. token.
--   full record: the ONE parley we are in (ours or adopted), plus its bets.
--   lite record: a parley we merely overheard.
--
-- A full record carries:
--   phase     "open" | "locked"
--   card      the parsed line list (decodeCard)
--   roster    { { id =, name = }, ... } for this parley's dungeon, or nil
--   bets      [fullName] = { [lineIndex] = pick }
--   lockAt    GetTime() of OUR lock moment; bets accepted until +K.LOCK_GRACE
--   nets      presentation-only settled tally
--   run       bookie only, see runOf()
-------------------------------------------------------------------------------

local parleys = {}
local mine
local recent, recentQ = {}, {}

local dlg, stakeBox, statusHead, statusFS, noteFS
local configWidgets, liveWidgets, picker, lockBtn, cancelBtn, openBtn
local boardRows, cardRows, cardBody, dungeonFS, dungeonNote, cardHead
local regTicker, tickN = nil, 0

local refreshDialog, freezeDialog, thawDialog, ensureTicker, sendRES
local refreshBoard, refreshCard

local function shortOf(full)
  return (strsplit("-", tostring(full or "?")))
end

-------------------------------------------------------------------------------
-- Identity and the registry (CONCURRENCY.md 2.1, 3.2)
-------------------------------------------------------------------------------

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function b36(n)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  if n == 0 then return "0" end
  local out = ""
  while n > 0 do
    local d = n % 36
    out = B36:sub(d + 1, d + 1) .. out
    n = math.floor(n / 36)
  end
  return out
end

local function nextToken()
  if type(PG.NextToken) == "function" then
    local ok, t = pcall(PG.NextToken)
    if ok and type(t) == "string" and t ~= "" then return t end
  end
  local p = PG.db and PG.db.profile
  local seq = 1
  if p then
    seq = (tonumber(p.seq) or 0) + 1
    p.seq = seq
  end
  return b36(seq) .. "-" .. b36(math.random(0, 46655))
end

local function keyOf(host, token)
  return tostring(host) .. "|" .. tostring(token)
end

local function myParley()
  return mine and parleys[mine] or nil
end

local function recordCount()
  local n = 0
  for _ in pairs(parleys) do n = n + 1 end
  return n
end

local function liteCount()
  local n = 0
  for _, rec in pairs(parleys) do
    if rec.kind == "lite" then n = n + 1 end
  end
  return n
end

local function poison(key)
  for i = 1, #recentQ do
    if recentQ[i] == key then
      table.remove(recentQ, i)
      break
    end
  end
  recent[key] = GetTime()
  recentQ[#recentQ + 1] = key
  while #recentQ > K.MAX_RECENT do
    local old = table.remove(recentQ, 1)
    recent[old] = nil
  end
end

local function validToken(token)
  if PG.IsSecret(token) or type(token) ~= "string" then return false end
  if token == "" or #token > 24 then return false end
  if token:find("|", 1, true) then return false end
  return true
end

-- "the sender is in the current group snapshot" (CONCURRENCY.md 4.5). Used for
-- gate j at GROUP scope only: at guild scope the GUILD distribution is itself
-- the proof that the sender is a guildmate, which is strictly stronger than any
-- roster lookup this client could do against a cache that may be cold.
local function inGroupNow(name)
  if type(name) ~= "string" then return false end
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      if PG.FullName("raid" .. i) == name then return true end
    end
  elseif IsInGroup() then
    if PG.FullName("player") == name then return true end
    for i = 1, GetNumGroupMembers() - 1 do
      if PG.FullName("party" .. i) == name then return true end
    end
  end
  return false
end

local function betSenderOK(rec, sender)
  if rec.scope == "group" then return inGroupNow(sender) end
  if rec.scope == "guild" then return true end
  return false
end

-------------------------------------------------------------------------------
-- The dungeon list and the boss roster.
--
-- THE SEASON ROTATION IS NOT SHIPPED DATA. C_ChallengeMode.GetMapTable() is the
-- live list of this season's keystone dungeons, straight from the client, so
-- there is no table here to go stale in six months and no dependency on another
-- addon to keep one current.
--
-- THE BOSS ROSTER IS A CHAIN, in the style of Theme.Tex's asset chains: try,
-- check what came back, fall back, and have an honest bottom. Every step is
-- pcall'd, because the Encounter Journal is the least stable surface this addon
-- touches and a betting window is not worth a Lua error.
--
--   1. the runtime memo
--   2. db.mp.bosses[mapId], resolved or learned on a previous session
--   3. the Encounter Journal, matched to the challenge map BY NAME (both
--      strings come from the same client in the same locale, so they agree)
--   4. what a completed run taught us - every ENCOUNTER_END during a key
--      records (id, name) for the dungeon it happened in
--   5. nil, and the per-boss lines are simply not offered, with a reason on the
--      card page saying why and what fixes it
--
-- Whatever the source, a roster is an ordered list of boss NAMES, and a boss's
-- IDENTITY IS ITS POSITION IN THAT LIST. Not its dungeonEncounterID, which
-- 1.5.1 stopped using: those numbers live in DungeonEncounter.db2, no guide
-- publishes them, and a wrong one does not fail loudly - it attributes nothing
-- to that boss and every line about it voids with "that boss was never fought",
-- which is a lie told to a bettor about their own run. Names are the one thing
-- both the shipped table and the client agree on (ENCOUNTER_END reports one).
--
-- POSITION IS NOT ORDER-OF-KILL, and the distinction is the whole point. The
-- roster is a fixed identity list for the DUNGEON, published once by the bookie
-- in its ROSTER message, so "boss 2" means the same named boss on every client
-- no matter what order the route took them in. A route that opens on the last
-- boss and wipes still walls on THAT boss.
-------------------------------------------------------------------------------

local rosterMemo = {}   -- [mapId] = list | false (tried and failed this session)
local rosterSrc = {}    -- [mapId] = "saved" | "journal" | "map" | "learned"
local learning = {}     -- [mapId] = { [id] = name } accumulated during a run

local function mpdb()
  if not PG.db then return nil end
  if type(PG.db.mp) ~= "table" then PG.db.mp = {} end
  if type(PG.db.mp.bosses) ~= "table" then PG.db.mp.bosses = {} end
  return PG.db.mp
end

local function mapName(mapId)
  local id = PG.SafeNum(mapId)
  if not (id and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return nil end
  local ok, name = pcall(C_ChallengeMode.GetMapUIInfo, math.floor(id))
  local s = ok and PG.SafeStr(name) or nil
  if s == "" then return nil end
  return s
end

local function mapTimeLimit(mapId)
  local id = PG.SafeNum(mapId)
  if not (id and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return nil end
  local ok, _, _, limit = pcall(C_ChallengeMode.GetMapUIInfo, math.floor(id))
  local n = ok and PG.SafeNum(limit) or nil
  if n and n > 0 then return n end
  return nil
end

-- GetMapTable() is populated from the server and can be EMPTY on a fresh login
-- until it is asked for. Without this the picker reads "no dungeons this season"
-- for the first minute of every session, which looks exactly like a broken
-- addon. Idempotent and free to repeat, so it is called at init, on every window
-- show, and whenever the list comes back empty.
local function requestMaps()
  if C_ChallengeMode and C_ChallengeMode.RequestMapInfo then
    pcall(C_ChallengeMode.RequestMapInfo)
  end
end

-- This season's keystone dungeons, name-sorted. Re-read rather than cached: a
-- season can roll over under a running client, and this is a handful of calls
-- on a window repaint rather than anything hot.
local function seasonMaps()
  local out = {}
  if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then return out end
  local ok, list = pcall(C_ChallengeMode.GetMapTable)
  if not (ok and type(list) == "table") then return out end
  for i = 1, #list do
    local id = PG.SafeNum(list[i])
    if id and id > 0 and mapName(id) then out[#out + 1] = math.floor(id) end
  end
  table.sort(out, function(a, b)
    local na, nb = mapName(a) or "", mapName(b) or ""
    if na ~= nb then return na < nb end
    return a < b
  end)
  if not out[1] then requestMaps() end
  return out
end

local function sanitizeName(v)
  local s = PG.SafeStr(v)
  if not s or s == "" then return nil end
  -- The wire packs a roster as id~name pairs joined by commas, so a name
  -- carrying either separator would re-parse into a different roster on the far
  -- side. Neither character appears in a boss name; stripping them is a
  -- belt-and-braces against a localisation that proves otherwise.
  s = s:gsub("[,~|]", " ")
  if #s > K.MAX_BOSS_NAME then s = s:sub(1, K.MAX_BOSS_NAME) end
  return s
end

-- Accepts a plain array of names or an array of { name = }, and returns a plain
-- array of names. Duplicates are dropped: two identically named bosses could
-- not be told apart at settlement anyway.
local function normalizeRoster(list)
  if type(list) ~= "table" or #list < 2 then return nil end
  local out, seen = {}, {}
  for i = 1, #list do
    local e = list[i]
    local nm = sanitizeName((type(e) == "table") and e.name or e)
    if nm and not seen[nm] then
      seen[nm] = true
      out[#out + 1] = nm
      if #out >= K.MAX_BOSSES then break end
    end
  end
  -- A one-boss "roster" is not one: every boss market either needs two options
  -- to have two sides, or is about a boss among others.
  if #out < 2 then return nil end
  return out
end

-- Case- and punctuation-insensitive key, for every name comparison this file
-- makes: dungeon against the shipped table, and ENCOUNTER_END's boss against
-- the roster. Applied to both sides, so it never makes two different names
-- compare equal.
local function nameKey(v)
  return (tostring(v or ""):lower():gsub("[^%w]", ""))
end

-- THE ENCOUNTER JOURNAL IS LOAD-ON-DEMAND, and this is the line that was
-- missing. The EJ_* functions live in the base client and answer calls all day,
-- but their DATA does not exist until Blizzard_EncounterJournal has been loaded
-- once - so on a client where the player has not opened the journal this
-- session (which is most of them, most of the time) the tier walk returns an
-- empty list and every dungeon reports its bosses as unknown. Loaded lazily, on
-- the first roster question rather than at login, because it is a real chunk of
-- memory to spend on a mode nobody may open.
local ejTried = false

local function ensureJournal()
  if ejTried then return end
  ejTried = true
  local loader = (C_AddOns and C_AddOns.LoadAddOn) or _G.LoadAddOn
  if type(loader) == "function" then
    pcall(loader, "Blizzard_EncounterJournal")
  end
end

-- Case- and punctuation-insensitive comparison, used only after an exact match
-- has failed. Both strings come from the same client in the same locale so they
-- normally agree exactly; this catches the cases where one side spells a
-- separator differently ("Operation: Floodgate" against "Operation Floodgate").
-- Applied to BOTH sides, so it never makes two genuinely different dungeons
-- compare equal.
local function normName(v)
  local str = tostring(v or ""):lower()
  str = str:gsub("[^%w]", "")
  return str
end

-- The encounters of one journal instance. dungeonEncounterID is the one that
-- matters and the one that is easy to get wrong: journalEncounterID is the
-- journal's own key and does NOT match what ENCOUNTER_END reports, so a roster
-- built from it would name bosses correctly and then never resolve a bet.
local function encountersOf(instanceID)
  if type(EJ_GetEncounterInfoByIndex) ~= "function" then return nil end
  local list = {}
  for i = 1, 20 do
    local ok, name = pcall(EJ_GetEncounterInfoByIndex, i, instanceID)
    if not ok or not name then break end
    list[#list + 1] = name
  end
  return normalizeRoster(list)
end

-- Step 1 of the chain, and the one that works on a client whose Encounter
-- Journal never answers: the roster shipped in Data/DungeonData.lua, matched on
-- the DUNGEON's name. English only, by construction - a non-English client
-- misses here and falls through to the journal or to a run, both of which are
-- already localised.
local function shippedRoster(mapId)
  local want = mapName(mapId)
  if not (want and PG.DungeonsByKey) then return nil end
  return normalizeRoster(PG.DungeonsByKey[nameKey(want)])
end

-- Step 3. Walks the journal's tiers for a dungeon whose name matches the
-- challenge map's. The current tier is saved and restored: an open Encounter
-- Journal is a window the player may be reading, and moving it out from under
-- them to answer a betting question would be rude.
local function journalRoster(mapId)
  local want = mapName(mapId)
  if not want then return nil end
  if type(EJ_GetNumTiers) ~= "function" or type(EJ_GetInstanceByIndex) ~= "function"
    or type(EJ_SelectTier) ~= "function" then
    return nil
  end
  ensureJournal()
  local okT, nTiers = pcall(EJ_GetNumTiers)
  if not (okT and type(nTiers) == "number" and nTiers > 0) then return nil end
  local saved
  if type(EJ_GetCurrentTier) == "function" then
    local ok, t = pcall(EJ_GetCurrentTier)
    if ok then saved = t end
  end
  local wantN = normName(want)
  local found, fuzzy
  for tier = 1, nTiers do
    if not pcall(EJ_SelectTier, tier) then break end
    for i = 1, 60 do
      local ok, instanceID, instName = pcall(EJ_GetInstanceByIndex, i, false)
      if not ok or not instanceID then break end
      local nm = PG.SafeStr(instName)
      if nm == want then
        found = instanceID
        break
      elseif not fuzzy and nm and normName(nm) == wantN then
        fuzzy = instanceID
      end
    end
    if found then break end
  end
  if saved then pcall(EJ_SelectTier, saved) end
  found = found or fuzzy
  if not found then return nil end
  return encountersOf(found)
end

-- Step 3b: the SAME journal, reached without walking the tiers.
--
-- The tier walk is the fragile half of step 3 - it iterates an unbounded,
-- undocumented list and mutates journal state to do it. This path asks the map
-- you are standing in which journal instance it is: one call, no iteration, and
-- available at exactly the moment it is most wanted - at the dungeon door,
-- opening a parley for the key you are about to run.
--
-- It still verifies BY NAME. Standing in a dungeon proves nothing about which
-- challenge map the picker has selected, and a roster silently attached to the
-- wrong dungeon would name bosses that never appear and void every per-boss
-- line at settlement.
local function journalRosterHere(mapId)
  local want = mapName(mapId)
  if not want then return nil end
  ensureJournal()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  if type(EJ_GetInstanceForMap) ~= "function"
    or type(EJ_GetInstanceInfo) ~= "function" then return nil end
  local okU, uiMap = pcall(C_Map.GetBestMapForUnit, "player")
  local u = okU and PG.SafeNum(uiMap) or nil
  if not u then return nil end
  local okI, instanceID = pcall(EJ_GetInstanceForMap, u)
  if not (okI and instanceID) then return nil end
  local okN, nm = pcall(EJ_GetInstanceInfo, instanceID)
  nm = okN and PG.SafeStr(nm) or nil
  if not nm or (nm ~= want and normName(nm) ~= normName(want)) then return nil end
  return encountersOf(instanceID)
end

local function rosterOf(mapId)
  local id = PG.SafeNum(mapId)
  if not id then return nil end
  id = math.floor(id)
  local memo = rosterMemo[id]
  if memo ~= nil then return memo or nil end
  local shipped = shippedRoster(id)
  if shipped then
    rosterMemo[id] = shipped
    rosterSrc[id] = "shipped"
    return shipped
  end
  local db = mpdb()
  local norm = normalizeRoster(db and db.bosses[id])
  if norm then
    rosterMemo[id] = norm
    rosterSrc[id] = rosterSrc[id] or "saved"
    return norm
  end
  local here = journalRosterHere(id)
  if here then
    rosterMemo[id] = here
    rosterSrc[id] = "map"
    if db then db.bosses[id] = here end
    return here
  end
  local fromJournal = journalRoster(id)
  if fromJournal then
    rosterMemo[id] = fromJournal
    rosterSrc[id] = "journal"
    if db then db.bosses[id] = fromJournal end
    return fromJournal
  end
  rosterMemo[id] = false   -- do not re-walk ten tiers on every repaint
  return nil
end

-- Walking into the dungeon is new evidence, and rosterOf memoises its FAILURES
-- so nothing would ever ask again. Cleared on a zone change, which is the only
-- moment step 3b can start working when it did not a minute ago.
local function forgetRosterMisses()
  for id, v in pairs(rosterMemo) do
    if v == false then rosterMemo[id] = nil end
  end
end

-- Step 4. A run teaches us the dungeon it was in. Order here is KILL order,
-- which is not a property of the dungeon, so the learned list is sorted by id -
-- arbitrary but STABLE, which is all a display needs. The journal's answer
-- always wins; this only fills a gap it left.
local function learnBoss(mapId, encounterID, encounterName)
  local id = PG.SafeNum(mapId)
  local eid = PG.SafeNum(encounterID)
  local nm = sanitizeName(encounterName)
  if not (id and eid and nm) or eid <= 0 then return end
  id = math.floor(id)
  learning[id] = learning[id] or {}
  learning[id][math.floor(eid)] = nm
end

-- MERGES what this run has seen into whatever is already known, and is safe to
-- call after every single boss rather than only at completion. Three properties
-- earn it that:
--
--   * it never destroys `learning`, so a two-boss dungeon still reaches the
--     two-entry minimum a roster needs;
--   * it unions with the saved list, so a key that is abandoned after one boss
--     still contributes that boss, and next week's run adds the rest;
--   * it will not overwrite a JOURNAL roster, which has the canonical boss
--     order - a learned list is sorted by id, which is stable but arbitrary.
local function flushLearned(mapId)
  local id = PG.SafeNum(mapId)
  if not id then return end
  id = math.floor(id)
  local seen = learning[id]
  if not seen then return end
  if rosterSrc[id] == "journal" or rosterSrc[id] == "map"
    or rosterSrc[id] == "shipped" then return end
  -- `learning` is keyed by encounterID purely to give the accumulated names a
  -- STABLE order across sessions; the id is not carried into the roster and is
  -- never compared to anything. Merged with what a previous run left behind, so
  -- a key abandoned after one boss still contributes.
  local db = mpdb()
  local byId = (db and type(db.seen) == "table" and db.seen[id]) or {}
  for eid, nm in pairs(seen) do byId[eid] = nm end
  if db then
    if type(db.seen) ~= "table" then db.seen = {} end
    db.seen[id] = byId
  end
  local order = {}
  for eid in pairs(byId) do order[#order + 1] = eid end
  table.sort(order)
  local list = {}
  for i = 1, #order do list[#list + 1] = byId[order[i]] end
  local norm = normalizeRoster(list)
  if not norm then return end
  rosterMemo[id] = norm
  rosterSrc[id] = "learned"
  local db = mpdb()
  if db then db.bosses[id] = norm end
end

-- rec.roster is an array of names, so a boss reference is just an index into it
local function bossName(rec, idx)
  local list = rec and rec.roster
  return (list and type(idx) == "number") and list[idx] or nil
end

-- Which roster position an ENCOUNTER_END belongs to, by name. Both strings come
-- from the same client here - its own roster against its own event - so this is
-- the one comparison that is guaranteed to be like-for-like.
local function bossIndexOf(roster, encounterName)
  if not roster then return nil end
  local k = nameKey(encounterName)
  if k == "" then return nil end
  for i = 1, #roster do
    if nameKey(roster[i]) == k then return i end
  end
  return nil
end

-- The label for one boss on a narrow button: the first word, which distinguishes
-- almost every boss name in the game, capped so a five-option row still fits.
-- The full name rides the tooltip.
local function shortBoss(name)
  local s = tostring(name or "?")
  local first = s:match("^(%S+)")
  if first and #first >= 4 then s = first end
  if #s > 10 then s = s:sub(1, 9) .. "." end
  return s
end

-------------------------------------------------------------------------------
-- The card codec.
--
-- "T,X.6,O.2926,P.2906.2,W" - entries by comma, fields inside an entry by dot.
-- How many fields an entry has is NOT encoded: it is read out of MARKET, which
-- both sides have in their own source. That is what keeps a five-line card
-- short enough to ride on OPEN beside the stake and the dungeon.
--
-- decodeCard is strict to the point of rudeness - one bad entry drops the whole
-- OPEN - and it has to be. A BET names its line by INDEX, so two clients that
-- disagreed about how many entries the card holds would apply every bet after
-- the disagreement to the wrong pool, silently, and pay the wrong people.
-- Refusing the parley outright is the only failure mode that cannot do that.
-------------------------------------------------------------------------------

local function encodeCard(card)
  local out = {}
  for i = 1, #card do
    local e = card[i]
    local s = e.t
    if e.boss then s = s .. "." .. e.boss end
    if e.line then s = s .. "." .. e.line end
    out[i] = s
  end
  return table.concat(out, ",")
end

local function decodeCard(str)
  local s = PG.SafeStr(str)
  if not s or s == "" or #s > 120 then return nil end
  local out, seen = {}, {}
  local parts = { strsplit(",", s) }
  if #parts > K.MAX_LINES then return nil end
  for i = 1, #parts do
    local f = { strsplit(".", parts[i]) }
    local t = f[1]
    local def = MARKET[t]
    if not def then return nil end
    local e, n = { t = t }, 2
    if def.boss == "one" then
      -- a ROSTER POSITION, not an encounter id: 1..MAX_BOSSES and nothing else
      local b = tonumber(f[n]); n = n + 1
      if not b or b ~= math.floor(b) or b < 1 or b > K.MAX_BOSSES then return nil end
      e.boss = b
    end
    if def.line then
      local v = tonumber(f[n]); n = n + 1
      if not v or v ~= math.floor(v) or v < def.min or v > def.max then return nil end
      e.line = v
    end
    if f[n] ~= nil then return nil end   -- trailing junk is a different card
    -- Two lines with the same (type, boss) would be two pools writing the same
    -- ledger id, and with different over/under values they would disagree about
    -- who won. One of each.
    local k = t .. ":" .. tostring(e.boss or "")
    if seen[k] then return nil end
    seen[k] = true
    out[#out + 1] = e
  end
  if #out == 0 then return nil end
  return out
end

-- Just the names, in order. The order IS the identity, so nothing else needs to
-- travel - and sanitizeName has already stripped the separator from each.
local function encodeRoster(list)
  return table.concat(list, ",")
end

local function decodeRoster(str)
  local s = PG.SafeStr(str)
  if not s or s == "" or #s > 200 then return nil end
  return normalizeRoster({ strsplit(",", s) })
end

-- A line the local client can render AND bet on. A boss-keyed line with no
-- roster is neither: it would be a button with no name on it, and a pick nobody
-- could check.
local function lineReady(rec, e)
  local def = MARKET[e.t]
  if not def.boss then return true end
  if not rec.roster then return false end
  if def.boss == "one" then return bossName(rec, e.boss) ~= nil end
  return #rec.roster >= 2
end

local function lineOptions(rec, e)
  local def = MARKET[e.t]
  if def.opts then return def.opts end
  -- boss = "pick": the options ARE the dungeon's bosses, in roster order.
  -- { shortLabel, wirePick, fullName } - the pick is the id as a string,
  -- because that is the identity and the position is not.
  local out = {}
  for i = 1, #(rec.roster or {}) do
    out[i] = { shortBoss(rec.roster[i]), tostring(i), rec.roster[i] }
  end
  return out
end

local function lineLabel(rec, e)
  local def = MARKET[e.t]
  local label = def.label
  if def.boss == "one" then
    label = string.format(label, shortBoss(bossName(rec, e.boss) or "?"))
  end
  if e.line then label = label .. " " .. e.line .. (def.unit or "") end
  return label
end

local function lineNoun(rec, e)
  local def = MARKET[e.t]
  if def.boss == "one" then
    return string.format(def.bet, bossName(rec, e.boss) or "that boss")
  end
  return def.bet
end

-------------------------------------------------------------------------------
-- Toasts and the results stage.
-------------------------------------------------------------------------------

local revealQ = {}

local function toast(text, rec, opts)
  if type(text) ~= "string" then return end
  if rec and rec.bookie and recordCount() > 1 then
    text = "(" .. shortOf(rec.bookie) .. ") " .. text
  end
  local pre = mark("keystone")
  if pre ~= "" then text = pre .. " " .. text end
  PG.UI.Toast(text, opts)
end

local function stageGatesOK()
  local s = PG.Safety.state
  if s.readyCheck or s.countdown then return false end
  return true
end

local function canRevealNow()
  local s = PG.Safety.state
  if s.inCombat or s.inEncounter or s.restricted then return false end
  if not stageGatesOK() then return false end
  if PG.UI.ToastPending then
    local pending, onScreen = PG.UI.ToastPending()
    if (pending or 0) > 0 or onScreen then return false end
  end
  return true
end

local function queueReveal(payload)
  revealQ[#revealQ + 1] = payload
  while #revealQ > K.MAX_REVEAL_Q do table.remove(revealQ, 1) end
  if ensureTicker then ensureTicker() end
end

local function pumpReveal()
  if not revealQ[1] then return end
  if not canRevealNow() then return end
  local payload = table.remove(revealQ, 1)
  if PG.Theme and PG.Theme.RevealQueue then PG.Theme.RevealQueue(payload) end
end

-- Drain-time gate. Handing a payload to the engine only relinquishes OUR gate;
-- the engine can drain at the exact moment a ready check starts, so the gate is
-- re-applied there. A veto puts the payload back in our own queue, because the
-- engine DISCARDS what it vetoes and a settlement must eventually show.
local function stageValidate(payload)
  if stageGatesOK() then return true end
  queueReveal(payload)
  return false
end

-------------------------------------------------------------------------------
-- Settlement presentation (REVEAL.md 6.5)
-------------------------------------------------------------------------------

local function tally(rec, name, delta)
  if not rec then return end
  local nets = rec.nets
  if not nets then
    nets = {}
    rec.nets = nets
  end
  nets[name] = (nets[name] or 0) + delta
end

local function newReport() return { lines = {}, paid = 0 } end

local function repAdd(rep, toastText, snd, rowText, rowRole, key, prio)
  rep.lines[#rep.lines + 1] = {
    toast = toastText, snd = snd, row = rowText, role = rowRole,
    key = key, prio = prio,
  }
end

local function flushToasts(rep, rec)
  if rep.head then
    toast(rep.head, rec, {
      key = "mp-outcome",
      priority = (rep.paid > 0) and "result" or nil,
    })
  end
  for i = 1, #rep.lines do
    local ln = rep.lines[i]
    if ln.toast then
      toast(ln.toast, rec, { key = ln.key, sound = ln.snd, priority = ln.prio })
    end
  end
end

local function emitReport(rep, rec, title)
  if rep.paid < 1 or not (PG.Theme and PG.Theme.RevealQueue) then
    flushToasts(rep, rec)
    return
  end
  local rows = {}
  for i = 1, #rep.lines do
    rows[#rows + 1] = { text = rep.lines[i].row, role = rep.lines[i].role }
  end
  if rep.mine then
    rows[#rows + 1] = {
      text = "You " .. (rep.mine >= 0 and "+" or "") .. PG.Money(rep.mine),
      role = (rep.mine > 0 and "win") or (rep.mine < 0 and "loss") or "body",
      personal = true,
    }
  end
  local payload = {
    game = "MP", anchor = { mode = "screen" },
    title = title, subtitle = rep.sub, rows = rows,
    marquee = "STAKE " .. PG.Money(rec.stake) .. " A BET",
    burst = "tickets", burstCount = 10, sound = "settled",
    -- no npc/emote: there is no goblin on this window (see buildDialog), and
    -- the stage type-checks the handle and drops the emote with it anyway
  }
  payload.validate = function() return stageValidate(payload) end
  queueReveal(payload)
end

-------------------------------------------------------------------------------
-- Parimutuel math.
--
-- The Pull Book's arithmetic, re-stated rather than shared with it. The
-- invariant that matters is that every client of ONE parley computes the
-- identical split, which is guaranteed by every client running THIS code over
-- the identical bet map. Two games never share a pot, so agreement BETWEEN the
-- modules would buy nothing.
-------------------------------------------------------------------------------

local function lineBetCount(bets, idx)
  local n = 0
  for _, picks in pairs(bets) do
    if picks[idx] then n = n + 1 end
  end
  return n
end

local function totalBetCount(bets)
  local n = 0
  for _, picks in pairs(bets) do
    if next(picks) then n = n + 1 end
  end
  return n
end

local function resolveLine(bets, idx, winPick, stake)
  local winners, losers = {}, {}
  for name, picks in pairs(bets) do
    local p = picks[idx]
    if p == winPick then
      winners[#winners + 1] = name
    elseif p then
      losers[#losers + 1] = name
    end
  end
  if (#winners + #losers) < 2 or #winners == 0 or #losers == 0 then return nil end
  table.sort(winners)
  local pot = stake * #losers
  local share = math.floor(pot / #winners)
  local dust = pot - share * #winners
  local deltas = {}
  for i = 1, #losers do deltas[losers[i]] = -stake end
  for i = 1, #winners do
    deltas[winners[i]] = share + (i == 1 and dust or 0)
  end
  return deltas, #winners, pot, #losers
end

local function vouchOf(rec)
  local v = {}
  for name in pairs(rec.bets or {}) do v[name] = true end
  local me = PG.FullName("player")
  if me then v[me] = true end
  return v
end

-- Settles one card line. winPick == nil means void by rule. Silent when nobody
-- backed it.
local function settleLine(rec, idx, winPick, label, rep, voidWhy)
  if lineBetCount(rec.bets, idx) == 0 then return end
  if not winPick then
    local why = voidWhy and (": void (" .. voidWhy .. "), stakes returned")
      or ": void, stakes returned"
    repAdd(rep, P.chgray .. label .. why .. ".|r", nil,
      label .. why, "fade", "mp-" .. idx)
    return
  end
  local deltas, nWin, pot, nLose = resolveLine(rec.bets, idx, winPick, rec.stake)
  if not deltas then
    repAdd(rep, P.chgray .. label .. ": void (not enough action), stakes returned.|r", nil,
      label .. ": void (not enough action)", "fade", "mp-" .. idx)
    return
  end
  -- Ledger.Commit refuses a session with more than MAX_ROWS_PER_SESSION rows,
  -- and at GUILD scope that ceiling is reachable in a way it never was for a
  -- five-player party. Caught here rather than at commit time, because the
  -- refusal's own toast says "this game's numbers don't add up" - which is
  -- untrue and alarming - and because a refused commit leaves the UI having
  -- shown a payout the ledger did not record. Decided from the row count alone,
  -- so every client reaches the same verdict from the same bet map.
  if (nWin + (nLose or 0)) > K.MAX_LEDGER_ROWS then
    repAdd(rep, P.chgray .. label .. ": void (too many bettors to record), stakes returned.|r",
      nil, label .. ": void (too many bettors)", "fade", "mp-" .. idx)
    return
  end
  local me = PG.FullName("player")
  local myDelta = me and deltas[me]
  PG.Ledger.Commit({
    -- The card INDEX, not the market code: "MP:<bookie>:<token>:<n>" stays
    -- inside Ledger's 96-byte id field even for a 64-character realm-qualified
    -- name, where a per-boss code (P2926) would not.
    id = "MP:" .. rec.bookie .. ":" .. rec.token .. ":" .. idx,
    game = "MP",
    host = rec.bookie,
    scope = rec.scope,
    at = (type(time) == "function") and time() or nil,
    played = (myDelta ~= nil),
    vouch = vouchOf(rec),
    cap = rec.stake * math.max(1, nWin + (nLose or 0)),
    label = rec.reason,
  }, deltas)
  for name, delta in pairs(deltas) do tally(rec, name, delta) end
  local won = nWin .. (nWin == 1 and " winner takes " or " winners split ")
  local line = label .. ": " .. won .. P.chgold .. PG.Money(pot) .. "|r"
  local snd
  if myDelta then
    line = line .. " - you " .. (myDelta >= 0 and (P.chgreen .. "+" .. PG.Money(myDelta) .. "|r")
      or (P.chred .. PG.Money(myDelta) .. "|r"))
    snd = "settled"
    rep.mine = (rep.mine or 0) + myDelta
  end
  rep.paid = rep.paid + 1
  repAdd(rep, line, snd, label .. ": " .. won .. tmoney(pot), "win", "mp-" .. idx, "result")
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function addLauncherRow(rec)
  if not (PG.Launcher and PG.Launcher.AddOpenGame) then return end
  pcall(PG.Launcher.AddOpenGame, {
    game = "MP", host = rec.bookie, token = rec.token,
    scope = rec.scope, expires = rec.expires,
  })
end

local function removeLauncherRow(rec)
  if not (PG.Launcher and PG.Launcher.RemoveOpenGame) then return end
  pcall(PG.Launcher.RemoveOpenGame, "MP", rec.bookie, rec.token)
end

local function evict(rec)
  if not rec or parleys[rec.key] ~= rec then return end
  parleys[rec.key] = nil
  poison(rec.key)
  if rec.askKey then PG.UI.Dismiss(rec.askKey) end
  removeLauncherRow(rec)
  if mine == rec.key then mine = nil end
end

K.REPORT_ROWS = 4

local function rankedNets(rec)
  if not (rec and rec.nets) then return nil end
  local list, any = {}, false
  for name, net in pairs(rec.nets) do
    list[#list + 1] = { name = name, net = net }
    if net ~= 0 then any = true end
  end
  if not any then return nil end
  table.sort(list, function(x, y)
    if x.net ~= y.net then return x.net > y.net end
    return x.name < y.name
  end)
  return list
end

-- THERE IS NO CLOSING PODIUM HERE, and the Pull Book's having one is the reason
-- to say so out loud. A raid book settles once per pull and closes hours later,
-- so its per-pull report and its closing podium are two moments and both earn
-- the stage. A parley settles and closes in the SAME INSTANT (PARLEY.md 3.4),
-- so a podium could only be a second takeover landing on the report that just
-- played. The ranked tally is not lost: it is what the frozen panel shows, on a
-- surface the player dismisses in their own time.
--
-- `quiet` means the closing line has already been said by that report.
local function closeParley(rec, text, quiet)
  if not rec then return end
  local wasMine = (rec.key == mine)
  evict(rec)
  if wasMine and freezeDialog then freezeDialog(rec, text) end
  if text and not quiet then toast(text, rec) end
  if refreshDialog then refreshDialog() end
end

local function adoptFull(rec)
  rec.kind = "full"
  rec.expires = nil
  rec.lastHB = GetTime()
  rec.bets = rec.bets or {}
  rec.phase = rec.phase or "open"
  parleys[rec.key] = rec
  mine = rec.key
  removeLauncherRow(rec)
  ensureTicker()
  if refreshDialog then refreshDialog() end
end

local function addLite(rec)
  rec.kind = "lite"
  rec.expires = GetTime() + K.LITE_TTL
  parleys[rec.key] = rec
  addLauncherRow(rec)
  ensureTicker()
end

local function evictOldestLite()
  local oldest
  for _, rec in pairs(parleys) do
    if rec.kind == "lite" and (not oldest or (rec.openedAt or 0) < (oldest.openedAt or 0)) then
      oldest = rec
    end
  end
  if oldest then evict(oldest) end
end

-- CONCURRENCY.md 4.3: the newest OPEN from a bookie replaces that bookie's
-- previous parley on every client, unconditionally, at any age.
local function supersede(sender, token)
  for _, rec in pairs(parleys) do
    if rec.bookie == sender and rec.token ~= token then
      if rec.kind == "full" then
        closeParley(rec, shortOf(sender) .. " opened a new Mythic Parley - the old one is off.")
      else
        evict(rec)
      end
    end
  end
end

local function sweep()
  local now = GetTime()
  for _, rec in pairs(parleys) do
    if rec.kind == "lite" and now > (rec.expires or 0) then evict(rec) end
  end
  while recentQ[1] and (now - (recent[recentQ[1]] or 0)) > K.RECENT_TTL do
    local key = table.remove(recentQ, 1)
    recent[key] = nil
  end
end

local function stopTickerIfIdle()
  if not regTicker then return end
  if next(parleys) or revealQ[1] then return end
  regTicker:Cancel()
  regTicker = nil
end

-------------------------------------------------------------------------------
-- The lock (PARLEY.md 5)
-------------------------------------------------------------------------------

local function lockLocally(rec)
  if rec.phase ~= "open" then return false end
  rec.phase = "locked"
  rec.lockAt = GetTime()
  return true
end

local function betsOpen(rec)
  if not rec or rec.kind ~= "full" then return false end
  return rec.phase == "open"
end

-- Bets stop being SENT at our own lock moment and stop being ACCEPTED
-- K.LOCK_GRACE later. The asymmetry is the whole convergence argument: no client
-- sends past its own LOCK receipt, so every bet any client accepts was in
-- flight before the bookie's lock plus one delivery latency.
local function betsAccepted(rec)
  if not rec or rec.kind ~= "full" then return false end
  if rec.phase == "open" then return true end
  return (GetTime() - (rec.lockAt or 0)) <= K.LOCK_GRACE
end

local function activeMapId()
  if not (C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID) then return nil end
  local ok, id = pcall(C_ChallengeMode.GetActiveChallengeMapID)
  if not ok then return nil end
  local n = PG.SafeNum(id)
  if n and n > 0 then return math.floor(n) end
  return nil
end

local function slottedMapId()
  if not (C_ChallengeMode and C_ChallengeMode.GetSlottedKeystoneInfo) then return nil end
  local ok, id = pcall(C_ChallengeMode.GetSlottedKeystoneInfo)
  if not ok then return nil end
  local n = PG.SafeNum(id)
  if n and n > 0 then return math.floor(n) end
  return nil
end

local function activeKeyLevel()
  if not (C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo) then return nil end
  local ok, lvl = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
  if not ok then return nil end
  local n = PG.SafeNum(lvl)
  if n and n > 0 then return math.floor(n) end
  return nil
end

local function runOf(rec)
  if not rec.run then
    rec.run = { active = false, wipes = 0, deaths = 0, bosses = {}, order = {},
                done = false }
  end
  return rec.run
end

-- The bookie's lock: freeze, snapshot the roster the first-death market needs,
-- note whether the key that is starting is the key that was declared, then say
-- so on the wire.
local function bookieLock(rec, why)
  if not (rec and rec.isBookie) then return end
  if not lockLocally(rec) then return end
  local run = runOf(rec)
  -- The roster snapshot has to be taken while it is still readable: this fires
  -- at the door, out of combat, which is the hygiene rule the Pull Book applies
  -- to exactly the same UNIT_DIED lookup.
  run.snap = PG.RosterSnapshot()
  local actual = activeMapId()
  if actual then
    rec.actualMapId = actual
    -- only a DECLARED dungeon can be contradicted; an undeclared parley (mapId
    -- nil, see tryOpenParley) has nothing to compare against and must not void
    if rec.mapId and actual ~= rec.mapId then rec.mapMismatch = true end
  end
  rec.keyLevel = activeKeyLevel() or rec.keyLevel
  PG.Comm.Broadcast(rec.scope, "MP", "LOCK", rec.token,
    tostring(actual or rec.mapId or "-"), tostring(rec.keyLevel or "-"))
  toast(why or "Bets are locked - good luck.", rec, { key = "mp-lock" })
  if refreshDialog then refreshDialog() end
end

-------------------------------------------------------------------------------
-- The run, observed locally by the bookie with zero traffic (PARLEY.md 1).
--
-- EVERYTHING HERE IS KEYED ON dungeonEncounterID. A route may take the bosses
-- in any order it likes and skip what it is allowed to skip; the only stable
-- fact about "the Avanoxx bet" is Avanoxx's own id. run.order exists for one
-- purpose - remembering which boss was walled FIRST - and even that resolves to
-- an id, never to a position.
-------------------------------------------------------------------------------

local function readDeaths()
  if not (C_ChallengeMode and C_ChallengeMode.GetDeathCount) then return nil end
  local ok, n = pcall(C_ChallengeMode.GetDeathCount)
  if not ok then return nil end
  local d = PG.SafeNum(n)
  if not d or d < 0 then return nil end
  return math.floor(d)
end

local function bossStat(run, idx)
  local b = run.bosses[idx]
  if not b then
    b = { att = 0, deaths = 0 }
    run.bosses[idx] = b
    run.order[#run.order + 1] = idx
  end
  return b
end

local function onEncounterStart(_, encounterID, encounterName)
  pcall(function()
    local rec = myParley()
    if not (rec and rec.isBookie and rec.phase == "locked") then return end
    local run = runOf(rec)
    if not run.active or run.done then return end
    -- resolved to a ROSTER POSITION by name; an encounter this dungeon's roster
    -- does not name contributes to nothing, which is the honest outcome
    local idx = bossIndexOf(rec.roster, encounterName)
    if not idx then return end
    -- Per-boss deaths are the party death count DIFFERENCED across the
    -- encounter: GetDeathCount is a run total and there is no per-encounter
    -- API. A missing reading at either end leaves that attempt contributing
    -- nothing rather than contributing a guess.
    run.markId = idx
    run.markDeaths = readDeaths()
  end)
end

local function onEncounterEnd(_, encounterID, encounterName, _, _, success)
  pcall(function()
    -- LEARNING IS ALWAYS ON and needs no parley. Every keystone this character
    -- runs teaches its client that dungeon's bosses, by identity and by name,
    -- whether or not anybody is betting. This is what makes the mode self-heal
    -- on a client whose Encounter Journal never answers: play your keys as
    -- normal and the per-boss lines turn up on their own, one dungeon at a
    -- time. Flushed per boss rather than at completion, so an abandoned key
    -- still contributes what it showed us.
    local liveMap = activeMapId()
    if liveMap then
      learnBoss(liveMap, encounterID, encounterName)
      flushLearned(liveMap)
    end
    local rec = myParley()
    if not (rec and rec.isBookie and rec.phase == "locked") then return end
    local run = runOf(rec)
    if not run.active or run.done then return end
    local idx = bossIndexOf(rec.roster, encounterName)
    if not idx then return end
    local succ = PG.SafeNum(success)
    -- succ nil (secret or unreadable) counts as neither a kill nor a wipe: an
    -- encounter this client could not read is not evidence of anything, and
    -- inventing a wipe would move real gold.
    if succ ~= 1 and succ ~= 0 then
      run.markId, run.markDeaths = nil, nil
      return
    end
    local b = bossStat(run, idx)
    b.att = b.att + 1
    local now = readDeaths()
    if run.markId == idx and run.markDeaths and now then
      b.deaths = b.deaths + math.max(0, now - run.markDeaths)
    end
    run.markId, run.markDeaths = nil, nil
    if now and now > (run.deaths or 0) then run.deaths = now end
    if succ == 0 then
      run.wipes = run.wipes + 1
      -- FIRST WALL is a ROSTER POSITION, captured the first time any boss is
      -- failed - which is not "the first boss": a group that opens on the last
      -- boss and wipes has walled on THAT boss, and settling it as boss 1 would
      -- pay a bet nobody placed.
      if not run.firstWall then run.firstWall = idx end
    end
  end)
end

local function onUnitDied(_, guid)
  pcall(function()
    local rec = myParley()
    if not (rec and rec.isBookie and rec.phase == "locked") then return end
    local run = runOf(rec)
    if not run.active or run.done or run.firstDeath then return end
    if PG.IsSecret(guid) or type(guid) ~= "string" then return end
    local entry = run.snap and run.snap[guid]
    if entry then run.firstDeath = entry.role end
  end)
end

local function onChallengeStart()
  pcall(function()
    local rec = myParley()
    if not (rec and rec.isBookie) then return end
    local run = runOf(rec)
    run.active = true
    run.done = false
    local actual = activeMapId()
    if actual then
      rec.actualMapId = actual
      if rec.mapId and actual ~= rec.mapId then rec.mapMismatch = true end
    end
    rec.keyLevel = activeKeyLevel() or rec.keyLevel
    if rec.phase == "open" then
      bookieLock(rec, "The key started - bets are locked.")
    elseif not run.snap then
      run.snap = PG.RosterSnapshot()
    end
  end)
end

local function onDeathCount()
  pcall(function()
    local rec = myParley()
    if not (rec and rec.isBookie and rec.phase == "locked") then return end
    local run = runOf(rec)
    if run.done then return end
    local d = readDeaths()
    if d and d > (run.deaths or 0) then run.deaths = d end
  end)
end

-- The worst boss: most attempts, ties broken by the LOWEST id. Only the bookie
-- computes it, but a tie-break that depended on table iteration order would be
-- a bug waiting for a second implementation to disagree with it.
local function worstBossOf(run)
  local best, bestAtt
  for idx, b in pairs(run.bosses) do
    if not bestAtt or b.att > bestAtt or (b.att == bestAtt and idx < best) then
      best, bestAtt = idx, b.att
    end
  end
  if best and bestAtt and bestAtt > 0 then return best end
  return nil
end

local function encodeBossData(run)
  local out = {}
  for i = 1, #run.order do
    local idx = run.order[i]
    local b = run.bosses[idx]
    if b then out[#out + 1] = idx .. "." .. b.att .. "." .. b.deaths end
    if #out >= K.MAX_BOSSES then break end
  end
  return (out[1] and table.concat(out, ",")) or "-"
end

local function readCompletion(rec)
  local run = runOf(rec)
  local timed, secsLeft = "-", "-"
  if C_ChallengeMode and C_ChallengeMode.GetCompletionInfo then
    local ok, mapId, level, elapsedMs, onTime = pcall(C_ChallengeMode.GetCompletionInfo)
    if ok then
      local m = PG.SafeNum(mapId)
      if m and m > 0 then
        rec.actualMapId = math.floor(m)
        if rec.mapId and rec.actualMapId ~= rec.mapId then rec.mapMismatch = true end
      end
      local l = PG.SafeNum(level)
      if l and l > 0 then rec.keyLevel = math.floor(l) end
      if onTime == true then timed = "Y" elseif onTime == false then timed = "N" end
      local ms = PG.SafeNum(elapsedMs)
      local limit = mapTimeLimit(rec.actualMapId or rec.mapId)
      if ms and ms > 0 and limit then
        -- seconds remaining on the dungeon's own timer; negative when over
        secsLeft = tostring(math.floor(limit - (ms / 1000)))
      end
    end
  end
  local d = readDeaths()
  if d and d > (run.deaths or 0) then run.deaths = d end
  return {
    outcome = "C",
    t = timed,
    d = tostring(run.deaths or 0),
    w = tostring(run.wipes or 0),
    s = secsLeft,
    fd = run.firstDeath or "-",
    fw = tostring(run.firstWall or 0),
    wb = tostring(worstBossOf(run) or 0),
    bd = encodeBossData(run),
  }
end

local function voidPayload()
  return { outcome = "A", t = "-", d = "-", w = "-", s = "-",
           fd = "-", fw = "-", wb = "-", bd = "-" }
end

local function scheduleRES(rec, payload)
  local run = runOf(rec)
  if run.sent then return end
  run.payload = payload
  for i = 1, #RES_RETRIES do
    PG.After(RES_RETRIES[i], function()
      if myParley() ~= rec then return end
      sendRES(rec)
    end)
  end
end

local function onChallengeCompleted()
  pcall(function()
    local rec = myParley()
    if not (rec and rec.isBookie and rec.phase == "locked") then return end
    local run = runOf(rec)
    if run.done then return end
    run.done = true
    run.active = false
    flushLearned(rec.actualMapId or rec.mapId)
    scheduleRES(rec, readCompletion(rec))
  end)
end

local function onChallengeReset()
  pcall(function()
    local rec = myParley()
    if not (rec and rec.isBookie and rec.phase == "locked") then return end
    local run = runOf(rec)
    if run.done then return end
    run.done = true
    run.active = false
    -- PARLEY.md 3.1: an abandoned key voids every market. Not because the facts
    -- are unreadable, but because settling one is manipulable by the five
    -- people who can see the board and end the run.
    scheduleRES(rec, voidPayload())
  end)
end

-------------------------------------------------------------------------------
-- Settlement (every client, from the bookie's RES)
-------------------------------------------------------------------------------

local function dungeonName(rec)
  return mapName(rec.actualMapId or rec.mapId) or "the key"
end

local function keyTitle(rec)
  local lvl = PG.SafeNum(rec.keyLevel)
  if lvl and lvl > 0 then return dungeonName(rec) .. " +" .. math.floor(lvl) end
  return dungeonName(rec)
end

-- The dungeon the CARD was posted for, which is only ever different from
-- keyTitle when the group ran something else - the one moment both names have
-- to appear in the same sentence.
local function declaredTitle(rec)
  return mapName(rec.mapId) or "that key"
end

local function decodeBossData(s)
  local out = {}
  local str = PG.SafeStr(s)
  if not str or str == "" or str == "-" or #str > 140 then return out end
  local parts = { strsplit(",", str) }
  for i = 1, #parts do
    local idx, att, dth = parts[i]:match("^(%d+)%.(%d+)%.(%d+)$")
    idx, att, dth = tonumber(idx), tonumber(att), tonumber(dth)
    if idx and att and dth and idx >= 1 and idx <= K.MAX_BOSSES
      and att <= K.RES_COUNT_MAX and dth <= K.RES_COUNT_MAX then
      out[idx] = { att = att, deaths = dth }
    end
  end
  return out
end

-- RES is bookie-authored: gate g proved WHO sent it, not that the numbers
-- inside are sane. Every count is bounded here exactly as OPEN's are, because a
-- fractional or absurd value would otherwise reach the report and pick a
-- winning side off arithmetic nobody can check. Out of range reads as
-- unreadable, which voids the line and returns the stakes.
local function settleParley(rec, res)
  if rec.settled then return end
  rec.settled = true
  rec.reason = "Mythic Parley: " .. keyTitle(rec)

  -- THE WHOLE CARD VOIDS in two cases, and they differ only in the sentence.
  --
  -- An abandoned key: PARLEY.md 3.1. A DIFFERENT key: PARLEY.md 3.5, and it took
  -- a correction to get here. The first draft voided only the boss-keyed lines
  -- and settled the rest, on the reasoning that "did we time it" does not care
  -- which dungeon it was. It does. A card is priced against ONE dungeon - its
  -- timer, its boss count, its difficulty - so a deaths line of 6 is a different
  -- bet on a three-boss key than on a four-boss one, and a Timed? line is a
  -- different bet against a 33-minute timer than a 35-minute one. Worse, the
  -- partial rule left a lever: a group that can see the board could swap the
  -- key to kill the lines it was losing and keep the ones it was winning.
  -- Voiding everything is the only outcome no participant can steer, which is
  -- the same argument 3.1 rests on.
  local abandoned = (res.outcome == "A")
  local wrongKey = (not abandoned) and rec.mapMismatch or false
  local voidAll = abandoned or wrongKey
  local function count(v, hi)
    if voidAll then return nil end
    local n = PG.SafeNum(v)
    if not n or n ~= math.floor(n) or n < 0 or n > hi then return nil end
    return n
  end
  local function signedCount(v, hi)
    if voidAll then return nil end
    local n = PG.SafeNum(v)
    if not n or n ~= math.floor(n) or n < -hi or n > hi then return nil end
    return n
  end
  local function bossId(v)
    if voidAll then return nil end
    local n = PG.SafeNum(v)
    if not n or n ~= math.floor(n) or n < 0 or n > K.MAX_BOSSES then return nil end
    return n   -- a roster position; 0 means "there wasn't one"
  end

  local deaths = count(res.d, K.RES_COUNT_MAX)
  local wipes = count(res.w, K.RES_COUNT_MAX)
  local secsLeft = signedCount(res.s, 36000)
  local firstDeath = (not voidAll) and PG.SafeStr(res.fd) or nil
  if firstDeath ~= "T" and firstDeath ~= "H" and firstDeath ~= "D" then firstDeath = nil end
  local firstWall = bossId(res.fw)
  local worst = bossId(res.wb)
  local bd = voidAll and {} or decodeBossData(res.bd)

  local rep = newReport()
  local anyBets = totalBetCount(rec.bets) > 0
  if anyBets then
    if wrongKey then
      rep.head = "Mythic Parley: " .. P.chgray .. "a different key was run - every bet is void.|r"
      rep.sub = declaredTitle(rec) .. " - a different key was run"
    elseif abandoned then
      rep.head = "Mythic Parley: " .. P.chgray .. "the key was abandoned - every bet is void.|r"
      rep.sub = keyTitle(rec) .. " - abandoned"
    elseif res.t == "Y" then
      rep.head = "Mythic Parley: " .. P.chgreen .. "timed!|r"
      rep.sub = keyTitle(rec) .. " - timed"
    elseif res.t == "N" then
      rep.head = "Mythic Parley: " .. P.chred .. "over time.|r"
      rep.sub = keyTitle(rec) .. " - over time"
    else
      rep.head = "Mythic Parley: could not read the key's result."
      rep.sub = keyTitle(rec) .. " - result unreadable"
    end
  end

  local voidWhy = (wrongKey and "a different key was run")
    or (abandoned and "the key was abandoned") or nil

  for i = 1, #rec.card do
    local e = rec.card[i]
    local t = e.t
    local pick, why = nil, voidWhy
    if voidAll then
      pick = nil
    elseif t == "T" then
      pick = (res.t == "Y" and "Y") or (res.t == "N" and "N") or nil
    elseif t == "X" then
      -- OVER is strict: a run that lands exactly on the line is UNDER
      pick = deaths and (deaths > e.line and "O" or "U") or nil
    elseif t == "A" then
      pick = wipes and (wipes > e.line and "O" or "U") or nil
    elseif t == "M" then
      pick = secsLeft and (secsLeft > e.line * 60 and "O" or "U") or nil
    elseif t == "F" then
      pick = firstDeath
      if not pick then why = why or "nobody died" end
    elseif t == "L" then
      if firstWall == 0 then
        pick, why = nil, "nobody walled"
      elseif firstWall then
        pick = tostring(firstWall)
      end
    elseif t == "W" then
      if worst == 0 then
        pick, why = nil, "no boss was engaged"
      elseif worst then
        pick = tostring(worst)
      end
    elseif t == "O" then
      local b = bd[e.boss]
      if b then pick = (b.att == 1) and "Y" or "N"
      else why = why or "that boss was never fought" end
    elseif t == "P" then
      local b = bd[e.boss]
      if b then pick = (b.att > e.line) and "O" or "U"
      else why = why or "that boss was never fought" end
    elseif t == "D" then
      local b = bd[e.boss]
      if b then pick = (b.deaths > e.line) and "O" or "U"
      else why = why or "that boss was never fought" end
    end
    settleLine(rec, i, pick, lineNoun(rec, e) .. " bet", rep, why)
  end

  emitReport(rep, rec, "THE PARLEY SETTLES")

  local closing
  if wrongKey then
    -- names BOTH dungeons: "the parley is void" with one name in it invites the
    -- reply "but we ran that", and the whole point is that the card was for a
    -- different one
    closing = "The parley is off - the card was for " .. declaredTitle(rec)
      .. " but " .. dungeonName(rec) .. " was run. Stakes returned."
  elseif abandoned then
    closing = "The parley is off - " .. keyTitle(rec) .. " was abandoned, stakes returned."
  else
    local parts = {}
    if res.t == "Y" then parts[#parts + 1] = "timed"
    elseif res.t == "N" then parts[#parts + 1] = "over time" end
    if deaths then parts[#parts + 1] = deaths .. (deaths == 1 and " death" or " deaths") end
    if wipes and wipes > 0 then
      parts[#parts + 1] = wipes .. (wipes == 1 and " boss wipe" or " boss wipes")
    end
    closing = keyTitle(rec) .. (parts[1] and (" - " .. table.concat(parts, ", ")) or "") .. "."
  end
  -- quiet exactly when the report above said something: with bets on the table
  -- it emitted a stage payload or a run of toasts that already carry the
  -- outcome, and with none it emitted nothing at all - and a player sitting at
  -- a parley they did not bet on still has to be told it is over.
  closeParley(rec, closing, anyBets)
end

-- The bookie's own settlement rides onSent, never the queued-ok return value: a
-- queued-then-dropped RES must not leave the bookie having settled numbers
-- nobody at the table received. `inflight` stops the schedule (and the ticker's
-- own retry) from emitting five copies of a message merely sitting in the
-- queue: a queued RES either goes out (onSent) or is dropped (onDrop clears the
-- flag), and only then is another attempt made.
sendRES = function(rec)
  if not (rec and rec.isBookie and rec.phase == "locked") then return end
  local run = runOf(rec)
  if run.sent or run.inflight or not run.payload then return end
  if PG.Comm.Locked() then return end
  local p = run.payload
  -- re-read: GetCompletionInfo can lag the event, and a line that is readable
  -- now must not settle void because the first attempt was early
  if p.outcome == "C" then
    p = readCompletion(rec)
    run.payload = p
  end
  run.inflight = true
  local queued = PG.Comm.BroadcastEx({
    scope = rec.scope,
    onSent = function()
      if myParley() ~= rec or run.sent then return end
      run.sent = true
      run.inflight = false
      settleParley(rec, p)
    end,
  }, "MP", "RES", rec.token, p.outcome, p.t, p.d, p.w, p.s, p.fd, p.fw, p.wb, p.bd)
  if not queued then run.inflight = false end
end

local function sendRoster(rec)
  if not (rec and rec.isBookie and rec.roster) then return end
  if PG.Comm.Locked() then return end
  PG.Comm.Broadcast(rec.scope, "MP", "ROSTER", rec.token,
    tostring(rec.mapId or "-"), encodeRoster(rec.roster))
end

-------------------------------------------------------------------------------
-- The one ticker (I9)
-------------------------------------------------------------------------------

local function tickBookie(rec, now)
  if rec.phase == "open" then
    local ok, why = PG.Comm.ScopeAvailable(rec.scope, 8)
    if not ok then
      rec.scopeLostAt = rec.scopeLostAt or now
      if (now - rec.scopeLostAt) >= 5 then
        closeParley(rec, "The Mythic Parley closed - " .. (why or "that audience is gone."))
      end
      return
    end
    rec.scopeLostAt = nil
    if not PG.Comm.Locked() and (now - (rec.lastSend or 0)) >= K.HB_SECS then
      rec.lastSend = now
      PG.Comm.Broadcast(rec.scope, "MP", "HB", rec.token)
      rec.hbN = (rec.hbN or 0) + 1
      if rec.roster and (rec.hbN % K.ROSTER_EVERY_HB) == 0 then sendRoster(rec) end
    end
    return
  end

  local run = runOf(rec)
  if run.active and not run.done and not activeMapId() then
    run.gone = (run.gone or 0) + 1
    if run.gone >= K.GONE_TICKS then
      run.done = true
      run.active = false
      scheduleRES(rec, voidPayload())
    end
  elseif run.active then
    run.gone = 0
  end
  if not run.sent and run.payload and not PG.Comm.Locked() then sendRES(rec) end
  if (now - (rec.lockAt or now)) > K.LOCK_MAX then
    closeParley(rec, "The Mythic Parley timed out - the key never reported, stakes returned.")
  end
end

local function tickClient(rec, now)
  if rec.phase == "locked" then
    -- A locked bookie is inside a lockdown by definition and cannot heartbeat.
    -- Suspending the deadline here is what stops every parley from dying 50
    -- seconds into every key.
    if (now - (rec.lockAt or now)) > K.LOCK_MAX then
      closeParley(rec, "The Mythic Parley timed out - the key never reported, stakes returned.")
    end
    return
  end
  local s = PG.Safety.state
  local miss = (rec.scope == "group") and K.HB_MISS_SECS or K.HB_MISS_WIDE
  if s.inEncounter or s.restricted or PG.Comm.Locked() then
    rec.lastHB = now
  elseif (now - (rec.lastHB or 0)) > miss then
    closeParley(rec, "The Mythic Parley closed (lost contact with the bookie).")
  end
end

local function onTick()
  tickN = tickN + 1
  local rec = myParley()
  if rec then
    local now = GetTime()
    if rec.isBookie then tickBookie(rec, now) else tickClient(rec, now) end
  end
  if (tickN % 4) == 0 then sweep() end
  pumpReveal()
  stopTickerIfIdle()
end

ensureTicker = function()
  if regTicker then return end
  regTicker = PG.Ticker(K.TICK, onTick)
end

-------------------------------------------------------------------------------
-- Betting
-------------------------------------------------------------------------------

-- A2, the button lock pop (SKIN.md 3): the ONE animation this board spends, on
-- the one moment worth marking - your bet going in. Decoration only; the lock is
-- already committed by the time this runs, and Theme.Pulse no-ops on a hidden
-- region, so a bet placed while Safety owns the screen simply does not pop.
local function popLock(idx, pick)
  if not (boardRows and PG.Theme and PG.Theme.Pulse) then return end
  local row = boardRows[idx]
  if not row then return end
  for i = 1, G.MAX_OPTS do
    local b = row.btns[i]
    if b and b.pick == pick then PG.Theme.Pulse(b) end
  end
end

local function placeBet(idx, pick)
  local rec = myParley()
  if not (rec and betsOpen(rec)) then return end
  if PG.Comm.Locked() then return end
  local e = rec.card[idx]
  if not (e and lineReady(rec, e)) then return end
  local me = PG.FullName("player")
  if not me then return end
  local picks = rec.bets[me]
  if picks and picks[idx] then return end   -- first click per line locks
  PG.Comm.BroadcastEx({
    scope = rec.scope,
    -- loopback rule: our own broadcasts are ignored on receipt, so record the
    -- pick locally - but only from onSent (the BET actually went out), never at
    -- queue time: a queued-then-dropped BET must not leave us settling a bet
    -- nobody else saw.
    onSent = function()
      if myParley() ~= rec or not betsOpen(rec) then return end
      local pk = rec.bets[me]
      if not pk then
        pk = {}
        rec.bets[me] = pk
      end
      if not pk[idx] then pk[idx] = pick end
      if refreshBoard then refreshBoard() end
      popLock(idx, pick)
      -- NO SOUND HERE, and that is a rule rather than an omission. SKIN.md 4
      -- makes the Pull Book's bet strip silent BY CONSTRUCTION: it only ever
      -- appears during a ready check or a countdown, where Theme.Sound's own
      -- gates mute every key. This board has no such structure - betting
      -- happens at the dungeon door, out of combat, with every gate clear - so
      -- a sound on the bet click would be a new noise in a suite that
      -- deliberately has none there. The pop above is the feedback.
    end,
    -- The bookie rides along as the LAST field. Identity is the PAIR
    -- (CONCURRENCY.md 4.5): tokens are only host-unique, and a BET is a
    -- BROADCAST every client in earshot applies, so without the bookie a
    -- colliding token folds another table's bettors into ours.
  }, "MP", "BET", rec.token, idx, pick, rec.bookie)
end

-------------------------------------------------------------------------------
-- THE WINDOW
--
-- One window, four states, the configWidgets/liveWidgets SetShown dance every
-- game in the suite uses - and TWO HEIGHTS, which no other game needs. The two
-- halves genuinely want different rooms: the card builder is a scrolling list
-- of up to twenty-three lines, and the betting board is at most five rows. A
-- 620px window with two market rows in it reads as broken, so the height
-- follows the state and the reason is written here rather than left as a
-- mystery constant.
-------------------------------------------------------------------------------

G.BOARD_W = 520
G.SETUP_H = 620
G.BOARD_TOP = 124        -- y of the first board row
G.BOARD_PITCH = 44
G.BOARD_TAIL = 130       -- note + button row + margin under the last row

G.CARD_ROW_H = 22
G.CARD_LIST_TOP = -238
G.CARD_LIST_H = 300
G.SCROLLBAR_RESERVE = 38
G.MAX_CARD_ROWS = #RUN_TYPES + #DUNGEON_TYPES + K.MAX_BOSSES * #PER_BOSS_TYPES

-- Board option geometry BY OPTION COUNT. The block is right-aligned to the same
-- edge whatever it holds, so five rows of different widths still read as one
-- column, and a four-or-more row steps down to the small font because a
-- ten-character boss name at display size does not fit in 72px.
G.OPT_GEO = {
  [1] = { w = 96, gap = 8 },
  [2] = { w = 96, gap = 8 },
  [3] = { w = 88, gap = 8 },
  [4] = { w = 72, gap = 6, font = "S" },
  [5] = { w = 62, gap = 5, font = "S" },
  [6] = { w = 51, gap = 4, font = "S" },
}
G.OPT_RIGHT = G.BOARD_W - 16
G.MAX_OPTS = K.MAX_BOSSES

local function boardHeight(n)
  return G.BOARD_TOP + math.max(1, n) * G.BOARD_PITCH + G.BOARD_TAIL
end

-------------------------------------------------------------------------------
-- The setup side: dungeon, stake, audience, and the card
-------------------------------------------------------------------------------

local setup = { mapIdx = 1, maps = {}, mapId = nil, ticks = {}, values = {} }

local function setupRoster()
  return setup.mapId and rosterOf(setup.mapId) or nil
end

-- Every line the bookie could tick for the currently selected dungeon.
local function availableLines()
  local out = {}
  for i = 1, #RUN_TYPES do out[#out + 1] = { t = RUN_TYPES[i] } end
  local roster = setupRoster()
  if roster then
    for i = 1, #DUNGEON_TYPES do out[#out + 1] = { t = DUNGEON_TYPES[i] } end
    for b = 1, #roster do
      for i = 1, #PER_BOSS_TYPES do
        out[#out + 1] = { t = PER_BOSS_TYPES[i], boss = b, name = roster[b] }
      end
    end
  end
  return out
end

local function lineKey(e) return e.t .. ":" .. tostring(e.boss or "") end

local function tickedCount()
  local n = 0
  for _, v in pairs(setup.ticks) do if v then n = n + 1 end end
  return n
end

-- The card as the bookie has it ticked, in availableLines order, so the board
-- rows come out in the order the builder listed them.
local function buildCard()
  local card = {}
  local avail = availableLines()
  for i = 1, #avail do
    local e = avail[i]
    local k = lineKey(e)
    if setup.ticks[k] then
      local def = MARKET[e.t]
      local entry = { t = e.t, boss = e.boss }
      if def.line then
        local v = math.floor(tonumber(setup.values[k]) or def.line)
        if v < def.min then v = def.min elseif v > def.max then v = def.max end
        entry.line = v
      end
      card[#card + 1] = entry
      if #card >= K.MAX_LINES then break end
    end
  end
  return card
end

-- A dungeon change invalidates every boss-keyed tick, because those ids belong
-- to the dungeon that was selected when they were ticked. Keeping them would
-- post a card naming Ara-Kara's bosses on a Dawnbreaker key.
local function dropBossTicks()
  for k in pairs(setup.ticks) do
    if k:find(":%d") then setup.ticks[k] = nil end
  end
end

local function setMap(mapId)
  if setup.mapId == mapId then return end
  setup.mapId = mapId
  dropBossTicks()
  local db = mpdb()
  if db then db.lastMap = mapId end
  if refreshCard then refreshCard() end
end

local function cycleMap(step)
  if #setup.maps == 0 then return end
  setup.mapIdx = ((setup.mapIdx - 1 + step) % #setup.maps) + 1
  setMap(setup.maps[setup.mapIdx])
end

local function syncMaps()
  setup.maps = seasonMaps()
  local db = mpdb()
  -- Default, in order: the key actually slotted in the font of power, the key
  -- already running, the last one this character posted a card for, the first
  -- of the season. The slotted keystone leads because it is the only one of the
  -- four that is evidence about what is ABOUT to be run.
  local want = slottedMapId() or activeMapId() or (db and db.lastMap) or setup.maps[1]
  setup.mapIdx = 1
  for i = 1, #setup.maps do
    if setup.maps[i] == want then setup.mapIdx = i break end
  end
  local pick = setup.maps[setup.mapIdx] or want
  if pick ~= setup.mapId then
    setup.mapId = pick
    dropBossTicks()
  end
end

-------------------------------------------------------------------------------
-- Window construction
-------------------------------------------------------------------------------

local function pickedScope()
  if picker and picker.Get then
    local s = picker:Get()
    if s and PG.MP.SCOPES[s] then return s end
    return nil
  end
  return "group"
end

local function tryOpenParley()
  if myParley() then
    refreshDialog()
    return
  end
  local scope = pickedScope()
  if not scope then
    local _, why = PG.Comm.ScopeAvailable("group")
    toast("The Mythic Parley: " .. (why or "you're not in a party or raid."))
    if picker then picker:Refresh() end
    return
  end
  local ok, why = PG.Comm.ScopeAvailable(scope)
  if not ok then
    toast("The Mythic Parley: " .. (why or "that audience isn't available."))
    if picker then picker:Refresh() end
    return
  end
  if PG.Comm.Locked() then
    toast("Cannot open a parley right now (messaging is locked).")
    return
  end
  local card = buildCard()
  if #card == 0 then
    toast("Tick at least one line before opening the parley.")
    return
  end
  local me = PG.FullName("player")
  if not me then return end
  local stake = math.floor(tonumber(stakeBox:GetText() or "") or 100)
  if stake < K.STAKE_MIN then stake = K.STAKE_MIN elseif stake > K.STAKE_MAX then stake = K.STAKE_MAX end
  stakeBox:SetText(tostring(stake))
  local token = nextToken()
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  -- mapId 0 is "no dungeon declared", and it is a real state rather than an
  -- error: GetMapTable() can be empty on a fresh login, or a season can be
  -- between rotations. The run-level lines do not need a dungeon to settle, so
  -- the mode still works - what is lost is the per-boss lines (there is no
  -- roster to draw) and the wrong-key void (there is nothing to compare
  -- against). Refusing to open at all would be a worse answer to a transient
  -- server-data gap.
  local declared = setup.mapId or 0
  if PG.Comm.Broadcast(scope, "MP", "OPEN", token, stake, declared,
      encodeCard(card), code) then
    -- built synchronously in the frame that broadcast it, so a double click
    -- cannot emit two OPENs: the check at the top of this function now sees it
    local key = keyOf(me, token)
    parleys[key] = {
      kind = "full", key = key, token = token, bookie = me, scope = scope,
      stake = stake, mapId = (declared > 0) and declared or nil, card = card,
      roster = setupRoster(), isBookie = true,
      phase = "open", bets = {},
      openedAt = GetTime(), lastSend = GetTime(), lastHB = GetTime(),
    }
    mine = key
    ensureTicker()
    sendRoster(parleys[key])
    refreshDialog()
    toast("The Mythic Parley is open - " .. P.chgold .. PG.Money(stake) .. "|r a bet on "
      .. (mapName(declared) or "the key") .. ".")
  end
end

local function bookieCancel()
  local rec = myParley()
  if not (rec and rec.isBookie) then return end
  PG.Comm.Broadcast(rec.scope, "MP", "CLOSE", rec.token)
  -- SKIN.md 4: `bookclose` is the bookie closing the book, MANUAL ONLY. Every
  -- other way a parley ends - a timeout, an abandoned key, a settlement - is
  -- something that happened TO the table, and none of them play it.
  if PG.Theme and PG.Theme.Sound then PG.Theme.Sound("bookclose") end
  closeParley(rec, "You called the parley off - stakes returned.")
end

local function bookieLockClick()
  local rec = myParley()
  if not (rec and rec.isBookie and rec.phase == "open") then return end
  bookieLock(rec, "You locked the parley - no more bets.")
end

local function bossTip(btn)
  if not btn.__pgFull then return end
  GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
  GameTooltip:AddLine(btn.__pgFull)
  GameTooltip:Show()
end

local function buildBoardRow(parent, r)
  local y = -G.BOARD_TOP - (r - 1) * G.BOARD_PITCH
  local row = { btns = {} }
  row.emblem = parent:CreateTexture(nil, "ARTWORK")
  row.emblem:SetSize(18, 18)
  row.emblem:SetPoint("TOPLEFT", 16, y - 2)
  row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")     -- B
  row.label:SetPoint("TOPLEFT", 42, y)
  row.label:SetWidth(130)
  row.label:SetJustifyH("LEFT")
  row.label:SetWordWrap(false)
  row.label:SetMaxLines(1)
  row.label:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  shadow(row.label)
  -- The backer tally sits UNDER the label rather than at the right edge: a
  -- six-option row needs every pixel from 174 to the margin, and a tally
  -- sharing that band would either overlap the last button or push the block
  -- off the window.
  row.tally = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- S
  row.tally:SetPoint("TOPLEFT", 42, y - 16)
  row.tally:SetWidth(130)
  row.tally:SetJustifyH("LEFT")
  row.tally:SetWordWrap(false)
  row.tally:SetMaxLines(1)
  row.tally:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  for i = 1, G.MAX_OPTS do
    local b
    b = PG.UI.CardButton(parent, "", 96, 24, function()
      placeBet(row.__pgIdx or 0, b.pick)
    end)
    b:HookScript("OnEnter", bossTip)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    row.btns[i] = b
  end
  row.rule = parent:CreateTexture(nil, "BORDER")
  row.rule:SetHeight(1)
  row.rule:SetPoint("TOPLEFT", 14, y - 36)
  row.rule:SetPoint("TOPRIGHT", -14, y - 36)
  row.rule:SetColorTexture(P.CHALK[1], P.CHALK[2], P.CHALK[3], 0.30)
  row.parts = { row.emblem, row.label, row.tally, row.rule }
  return row
end

local function buildCardRow(parent, r)
  local row = {}
  row.cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  row.cb:SetSize(20, 20)
  row.cb:SetPoint("TOPLEFT", 0, -(r - 1) * G.CARD_ROW_H)
  row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")     -- B
  row.label:SetPoint("LEFT", row.cb, "RIGHT", 4, 0)
  row.label:SetWidth(300)
  row.label:SetJustifyH("LEFT")
  row.label:SetWordWrap(false)
  row.label:SetMaxLines(1)
  row.box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  row.box:SetSize(44, 18)
  row.box:SetPoint("LEFT", row.cb, "RIGHT", 316, 0)
  row.box:SetAutoFocus(false)
  row.box:SetNumeric(true)
  row.box:SetMaxLetters(3)
  row.cb:SetScript("OnClick", function(self)
    local k = row.__pgKey
    if not k then return end
    if self:GetChecked() then
      -- The cap is enforced HERE rather than by graying the rest of the list,
      -- because a checkbox that silently refuses is worse than one that says
      -- why. Un-ticking it back is what keeps the control honest about what
      -- actually happened.
      if tickedCount() >= K.MAX_LINES then
        self:SetChecked(false)
        toast("A card holds " .. K.MAX_LINES .. " lines. Untick one first.",
          nil, { key = "mp-cardfull" })
        return
      end
      setup.ticks[k] = true
    else
      setup.ticks[k] = nil
    end
    if refreshCard then refreshCard() end
  end)
  row.box:SetScript("OnTextChanged", function(self)
    local k = row.__pgKey
    if k then setup.values[k] = self:GetText() end
  end)
  return row
end

local function buildDialog()
  dlg = PG.UI.Window("parley", "Mythic Parley", G.BOARD_W, G.SETUP_H, "MP")
  dlg.__pgFrozen = false
  if PG.UI.OnClose then
    PG.UI.OnClose(dlg, function()
      thawDialog()
      refreshDialog()
    end)
  end

  local stakeLabel = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormal")    -- T
  stakeLabel:SetPoint("TOPLEFT", K.INSET, -48)
  stakeLabel:SetText("Stake per bet (gold)")
  stakeLabel:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  shadow(stakeLabel)
  stakeBox = CreateFrame("EditBox", nil, dlg, "InputBoxTemplate")
  stakeBox:SetSize(70, 20)
  stakeBox:SetPoint("TOPRIGHT", -K.INSET, -46)
  stakeBox:SetAutoFocus(false)
  stakeBox:SetNumeric(true)
  stakeBox:SetMaxLetters(6)
  stakeBox:SetText("100")

  local dungeonLabel = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormal")  -- T
  dungeonLabel:SetPoint("TOPLEFT", K.INSET, -80)
  dungeonLabel:SetText("Dungeon")
  dungeonLabel:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  shadow(dungeonLabel)

  -- Prev/next rather than a dropdown, for SCOPE.md 5.1's reason: this addon
  -- does not import UIDropDownMenu, and a season is eight dungeons - two clicks
  -- from anywhere in the list.
  local prevBtn = PG.UI.Button(dlg, "<", 24, 20, function() cycleMap(-1) end)
  prevBtn:SetPoint("TOPLEFT", K.INSET + 90, -78)
  local nextBtn = PG.UI.Button(dlg, ">", 24, 20, function() cycleMap(1) end)
  nextBtn:SetPoint("TOPRIGHT", -K.INSET, -78)
  dungeonFS = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")        -- B
  dungeonFS:SetPoint("LEFT", prevBtn, "RIGHT", 6, 0)
  dungeonFS:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
  dungeonFS:SetJustifyH("CENTER")
  dungeonFS:SetWordWrap(false)
  dungeonFS:SetMaxLines(1)
  dungeonFS:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  shadow(dungeonFS)

  dungeonNote = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- S
  dungeonNote:SetPoint("TOPLEFT", K.INSET, -104)
  dungeonNote:SetPoint("TOPRIGHT", -K.INSET, -104)
  dungeonNote:SetJustifyH("CENTER")
  dungeonNote:SetJustifyV("TOP")
  dungeonNote:SetHeight(26)
  dungeonNote:SetWordWrap(true)
  dungeonNote:SetMaxLines(2)
  dungeonNote:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])

  if PG.UI.ScopePicker then
    picker = PG.UI.ScopePicker(dlg, {
      key = "MP",
      allowed = PG.MP.SCOPES,
      width = G.BOARD_W,
      reasons = function(scope)
        if scope == "public" then return WIDE_SCOPE_REASON end
        return nil
      end,
    })
    picker:SetPoint("TOPLEFT", dlg, "TOPLEFT", 0, -136)
    picker:SetPoint("TOPRIGHT", dlg, "TOPRIGHT", 0, -136)
  end

  local div = dlg:CreateTexture(nil, "ARTWORK")
  div:SetPoint("TOPLEFT", K.INSET, -204)
  div:SetPoint("TOPRIGHT", -K.INSET, -204)
  div:SetHeight(1)
  div:SetColorTexture(0.12, 0.12, 0.13, 1)

  -- A header plate behind the card's title. The setup side is a form and a
  -- list, which left it the only surface in the suite with no art on it at all;
  -- this is the smallest thing that fixes that without putting parchment under
  -- Blizzard's own checkbox textures, where chalk-on-parchment stops being
  -- readable. Positioned whether or not it renders, so the layout never depends
  -- on the art (the SKIN.md 2.6 rule the Pull Book's poster follows).
  local plate = dlg:CreateTexture(nil, "ARTWORK")
  plate:SetSize(260, 24)
  plate:SetPoint("TOP", dlg, "TOP", 0, -212)
  if not ((PG.Theme and PG.Theme.Tex) and PG.Theme.Tex(plate, "goldheader")) then
    plate:Hide()
  end

  cardHead = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormal")            -- T
  cardHead:SetPoint("TOPLEFT", K.INSET, -216)
  cardHead:SetPoint("TOPRIGHT", -K.INSET, -216)
  cardHead:SetJustifyH("CENTER")
  cardHead:SetWordWrap(false)
  cardHead:SetMaxLines(1)
  cardHead:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  shadow(cardHead)

  local scroll = CreateFrame("ScrollFrame", nil, dlg, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", K.INSET, G.CARD_LIST_TOP)
  scroll:SetSize(G.BOARD_W - K.INSET - G.SCROLLBAR_RESERVE, G.CARD_LIST_H)
  cardBody = CreateFrame("Frame", nil, scroll)
  -- Sized to the POOL here and re-sized to the offered rows on every repaint
  -- (refreshCard). The pool is 25 rows because a six-boss dungeon needs them;
  -- a dungeon with no known bosses offers five. Leaving the child at pool
  -- height gave the scrollbar 550px of travel over 110px of content - two and a
  -- half pages of nothing, which is exactly what it looked like.
  cardBody:SetSize(G.BOARD_W - K.INSET - G.SCROLLBAR_RESERVE,
    G.MAX_CARD_ROWS * G.CARD_ROW_H)
  scroll:SetScrollChild(cardBody)
  cardRows = {}
  for r = 1, G.MAX_CARD_ROWS do cardRows[r] = buildCardRow(cardBody, r) end

  local cardHint = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- S
  cardHint:SetPoint("TOPLEFT", K.INSET, G.CARD_LIST_TOP - G.CARD_LIST_H - 8)
  cardHint:SetPoint("TOPRIGHT", -K.INSET, G.CARD_LIST_TOP - G.CARD_LIST_H - 8)
  cardHint:SetJustifyH("CENTER")
  cardHint:SetJustifyV("TOP")
  cardHint:SetHeight(28)
  cardHint:SetWordWrap(true)
  cardHint:SetMaxLines(2)
  cardHint:SetText("Bets lock the moment the key starts - your addons go silent for "
    .. "the whole run.")
  cardHint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])

  openBtn = PG.UI.Button(dlg, mark("keystone") .. " Open parley", 150, 26, tryOpenParley)
  openBtn:SetPoint("BOTTOM", 0, 18)
  local dlgRules = PG.UI.Button(dlg, "Rules", 60, 22, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("MP") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", 16, 18)

  -- the live board
  statusHead = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")     -- D2
  statusHead:SetPoint("TOPLEFT", K.INSET, -56)
  statusHead:SetPoint("TOPRIGHT", -K.INSET, -56)
  statusHead:SetJustifyH("CENTER")
  statusHead:SetWordWrap(false)
  statusHead:SetMaxLines(1)
  if PG.Theme and PG.Theme.SetFont then PG.Theme.SetFont(statusHead, "D2") end
  statusHead:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  shadow(statusHead)

  statusFS = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")         -- B
  statusFS:SetPoint("TOPLEFT", K.INSET, -86)
  statusFS:SetPoint("TOPRIGHT", -K.INSET, -86)
  statusFS:SetJustifyH("CENTER")
  statusFS:SetJustifyV("TOP")
  statusFS:SetHeight(32)
  statusFS:SetWordWrap(true)
  statusFS:SetMaxLines(2)
  statusFS:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  shadow(statusFS)

  boardRows = {}
  for r = 1, K.MAX_LINES do boardRows[r] = buildBoardRow(dlg, r) end

  noteFS = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")      -- S
  noteFS:SetJustifyH("CENTER")
  noteFS:SetJustifyV("TOP")
  noteFS:SetHeight(32)
  noteFS:SetWordWrap(true)
  noteFS:SetMaxLines(2)
  noteFS:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])

  lockBtn = PG.UI.Button(dlg, "Lock bets", 130, 26, bookieLockClick)
  lockBtn:SetPoint("BOTTOM", dlg, "BOTTOM", -68, 18)
  cancelBtn = PG.UI.Button(dlg, "Cancel parley", 130, 26, bookieCancel)
  cancelBtn:SetPoint("BOTTOM", dlg, "BOTTOM", 68, 18)

  configWidgets = { stakeLabel, stakeBox, dungeonLabel, prevBtn, nextBtn,
                    dungeonFS, dungeonNote, div, plate, cardHead, scroll,
                    cardHint, openBtn }
  if picker then configWidgets[#configWidgets + 1] = picker end

  liveWidgets = { statusHead, statusFS, noteFS }

  -- THERE IS NO GOBLIN ON THIS WINDOW, and the Pull Book having one is the
  -- reason to say why.
  --
  -- The first cut put him bottom-right and hid him whenever a parley went live,
  -- because the board spends its full width on option buttons and its full
  -- height on rows and there is genuinely nowhere for him to stand. Hiding him
  -- meant putting his container in configWidgets, so every repaint toggled it -
  -- and Theme.NPC hooks OnShow on that container to RE-PROBE a model load that
  -- a hide interrupted (SetDisplayInfo again, camera and rotation re-applied on
  -- the next OnModelLoaded). SKIN.md A10 is explicit that the hide path makes
  -- no model call; a surface that hides him on every state change is not a
  -- surface that can have him. The visible result was a goblin spinning in the
  -- corner.
  --
  -- So he is not here at all rather than here-and-toggled, and the reveal
  -- payload carries no npc handle: the stage type-checks it and drops the emote
  -- along with it, so a nil would have been silently ignored - a field that
  -- reads as if a goblin exists is worse than no field.

  if PG.Theme then
    openBtn:HookScript("OnClick", function()
      local rec = myParley()
      if rec and rec.isBookie then
        if PG.Theme.Sound then PG.Theme.Sound("stamp") end
        if PG.Theme.Stamp then PG.Theme.Stamp(dlg, "PARLEY OPEN") end
      end
    end)
    lockBtn:HookScript("OnClick", function()
      local rec = myParley()
      if rec and rec.phase == "locked" then
        if PG.Theme.Sound then PG.Theme.Sound("stamp") end
        if PG.Theme.Stamp then PG.Theme.Stamp(dlg, "NO MORE BETS") end
      end
    end)
  end
end

-------------------------------------------------------------------------------
-- Repaint
-------------------------------------------------------------------------------

refreshCard = function()
  if not (dlg and cardRows) then return end
  local avail = availableLines()
  local n = tickedCount()
  -- the scroll child is exactly as tall as the rows on offer, never as tall as
  -- the pool: a scrollbar that travels past the last row is a page of nothing
  if cardBody then
    cardBody:SetHeight(math.max(G.CARD_LIST_H, #avail * G.CARD_ROW_H))
  end
  cardHead:SetText("THE CARD   " .. n .. " / " .. K.MAX_LINES)
  dungeonFS:SetText(setup.mapId and (mapName(setup.mapId) or ("Dungeon " .. setup.mapId))
    or "no dungeons this season")
  local roster = setupRoster()
  if not setup.mapId then
    dungeonNote:SetText(P.chgray .. "No Mythic+ dungeons reported yet - the run-level "
      .. "lines still work, and the list fills itself in when the server answers.|r")
  elseif roster then
    dungeonNote:SetText(#roster .. " bosses known ("
      .. (SRC_WORD[rosterSrc[setup.mapId]] or "?") .. ") - per-boss lines are available.")
  else
    dungeonNote:SetText(P.chgray .. "Bosses unknown here - run-level lines only. "
      .. "Just run this key once and they appear; /pg keys says why.|r")
  end
  for r = 1, G.MAX_CARD_ROWS do
    local row = cardRows[r]
    local e = avail[r]
    if not e then
      row.__pgKey = nil
      row.cb:Hide()
      row.label:Hide()
      row.box:Hide()
    else
      local def = MARKET[e.t]
      local k = lineKey(e)
      row.__pgKey = k
      local label = def.label
      if def.boss == "one" then label = string.format(label, e.name or "?") end
      row.label:SetText(label)
      row.cb:SetChecked(setup.ticks[k] and true or false)
      row.cb:Show()
      row.label:Show()
      if def.line then
        if setup.values[k] == nil then setup.values[k] = tostring(def.line) end
        if row.box:GetText() ~= setup.values[k] then row.box:SetText(setup.values[k]) end
        row.box:Show()
      else
        row.box:Hide()
      end
      local dim = (n >= K.MAX_LINES) and not setup.ticks[k]
      row.label:SetTextColor(dim and P.CHGRAY[1] or P.CHALK[1],
        dim and P.CHGRAY[2] or P.CHALK[2], dim and P.CHGRAY[3] or P.CHALK[3])
    end
  end
  -- a dungeon is optional (see tryOpenParley); a line is not
  if openBtn then openBtn:SetEnabled(n > 0) end
end

local function hideBoard()
  if not boardRows then return end
  for r = 1, K.MAX_LINES do
    local row = boardRows[r]
    for i = 1, #row.parts do row.parts[i]:Hide() end
    for i = 1, G.MAX_OPTS do row.btns[i]:Hide() end
  end
end

refreshBoard = function()
  local rec = myParley()
  if not (dlg and boardRows and rec) then return end
  local me = PG.FullName("player")
  local myPicks = me and rec.bets[me] or nil
  local open = betsOpen(rec)
  for r = 1, K.MAX_LINES do
    local row = boardRows[r]
    local e = rec.card[r]
    row.__pgIdx = r
    if not e then
      for i = 1, #row.parts do row.parts[i]:Hide() end
      for i = 1, G.MAX_OPTS do row.btns[i]:Hide() end
    else
      for i = 1, #row.parts do row.parts[i]:Show() end
      if PG.Theme and PG.Theme.Tex then
        if not PG.Theme.Tex(row.emblem, MARKET_ICON[e.t]) then row.emblem:Hide() end
      else
        row.emblem:Hide()
      end
      local ready = lineReady(rec, e)
      row.label:SetText(ready and lineLabel(rec, e)
        or (MARKET[e.t].label:gsub("%%s", "...")))
      local opts = ready and lineOptions(rec, e) or {}
      local nOpt = math.min(#opts, G.MAX_OPTS)
      local geo = G.OPT_GEO[nOpt] or G.OPT_GEO[2]
      local locked = myPicks and myPicks[r]
      local counts = {}
      for _, picks in pairs(rec.bets) do
        local p = picks[r]
        if p then counts[p] = (counts[p] or 0) + 1 end
      end
      local parts = {}
      for i = 1, G.MAX_OPTS do
        local b = row.btns[i]
        local opt = (i <= nOpt) and opts[i] or nil
        if not opt then
          b:Hide()
        else
          b:SetSize(geo.w, 24)
          b:ClearAllPoints()
          local x = G.OPT_RIGHT - (nOpt - i) * (geo.w + geo.gap) - geo.w
          b:SetPoint("TOPLEFT", dlg, "TOPLEFT", x,
            -G.BOARD_TOP - (r - 1) * G.BOARD_PITCH - 2)
          if geo.font and PG.Theme and PG.Theme.SetFont and b.GetFontString then
            local fs = b:GetFontString()
            if fs then PG.Theme.SetFont(fs, geo.font) end
          end
          b.pick = opt[2]
          b.__pgFull = opt[3]
          local text = opt[1]
          if locked or not open then
            b:SetEnabled(false)
            if b.pick == locked then
              b:SetText((b.__pgCard and P.win or "|cff40ff40") .. text .. "|r")
              b:SetAlpha(1)
            else
              b:SetText(text)
              b:SetAlpha(0.45)
            end
          else
            b:SetEnabled(true)
            b:SetText(text)
            b:SetAlpha(1)
          end
          b:Show()
          parts[#parts + 1] = tostring(counts[opt[2]] or 0)
        end
      end
      if ready then
        row.tally:SetText(table.concat(parts, nOpt <= 3 and " : " or "/"))
      else
        row.tally:SetText(P.chgray .. "waiting for boss names|r")
      end
    end
  end
end

local SCOPE_WORD = { group = "Party", guild = "Guild", public = "Public" }

local function applyHeight(rec)
  if not dlg then return end
  local h = (rec and not dlg.__pgFrozen) and boardHeight(#rec.card) or G.SETUP_H
  if math.floor(dlg:GetHeight() + 0.5) ~= h then dlg:SetHeight(h) end
  -- the note hangs off the LAST board row, so it follows the height instead of
  -- floating at a constant offset above a bottom that moved
  if noteFS then
    local y = rec and (-G.BOARD_TOP - math.max(1, #rec.card) * G.BOARD_PITCH - 8) or -560
    noteFS:ClearAllPoints()
    noteFS:SetPoint("TOPLEFT", K.INSET, y)
    noteFS:SetPoint("TOPRIGHT", -K.INSET, y)
  end
end

refreshDialog = function()
  if not dlg then return end
  local rec = myParley()
  -- A settled parley's tally owns this panel until the player dismisses it, and
  -- a LIVE parley always takes it back - the same rule the game windows apply
  -- to a frozen result (CONCURRENCY.md 5.9).
  if dlg.__pgFrozen then
    if not rec then return end
    thawDialog()
  end
  local isOpen = rec ~= nil
  for i = 1, #configWidgets do configWidgets[i]:SetShown(not isOpen) end
  for i = 1, #liveWidgets do liveWidgets[i]:SetShown(isOpen) end
  local bookieNow = isOpen and rec.isBookie or false
  lockBtn:SetShown(bookieNow and rec.phase == "open")
  cancelBtn:SetShown(bookieNow)
  cancelBtn:ClearAllPoints()
  if bookieNow and rec.phase ~= "open" then
    -- with nothing left to lock, the one remaining button takes the centre
    cancelBtn:SetPoint("BOTTOM", dlg, "BOTTOM", 0, 18)
  else
    cancelBtn:SetPoint("BOTTOM", dlg, "BOTTOM", 68, 18)
  end
  applyHeight(rec)
  -- A1 pop, on the TRANSITION only. The window does not re-show when a parley
  -- opens - it swaps its contents and changes height - so without this the
  -- biggest state change in the mode is the one moment with no motion at all.
  -- Gated on the transition rather than fired from every repaint, because a
  -- board that popped on every inbound BET would be a strobe.
  if dlg.__pgWasOpen ~= isOpen then
    dlg.__pgWasOpen = isOpen
    if PG.Theme and PG.Theme.Pop then PG.Theme.Pop(dlg) end
  end
  if not isOpen then
    hideBoard()
    -- availability is a live query, and so is the season: the config side
    -- reappearing after a parley ends must show both as they are now
    if picker then picker:Refresh() end
    syncMaps()
    refreshCard()
    return
  end

  statusHead:SetText(rec.isBookie and "Your parley is open"
    or (shortOf(rec.bookie) .. "'s parley"))
  statusFS:SetText(P.chgold .. tmoney(rec.stake) .. "|r a bet on "
    .. (mapName(rec.mapId) or "the key") .. "   -   "
    .. (SCOPE_WORD[rec.scope] or rec.scope))
  if rec.phase == "open" then
    noteFS:SetText("One click per line, and it's locked in. Bets close the moment "
      .. "the key starts.")
  else
    local run = rec.run
    local live = (run and run.active) and ("  -  " .. (run.wipes or 0)
      .. ((run.wipes == 1) and " boss wipe" or " boss wipes")) or ""
    noteFS:SetText(P.chgray .. "No more bets - the key is running." .. live
      .. " The result lands when your addons can talk again.|r")
  end
  refreshBoard()
end

-------------------------------------------------------------------------------
-- THE SETTLED REPORT (PLAN 5). This mode has no results WINDOW, so the panel
-- that says "your parley is open" carries the closing tally instead, marked and
-- inert, until the player X's it. It does not get an eighth window.
-------------------------------------------------------------------------------

local function reportBody(rec)
  local list = rankedNets(rec)
  if not list then return nil end
  for i = 1, #list do list[i].rank = i end
  local me = PG.FullName("player")
  local shown = math.min(#list, K.REPORT_ROWS)
  if me and #list > K.REPORT_ROWS then
    for i = K.REPORT_ROWS, #list do
      if list[i].name == me then
        table.insert(list, K.REPORT_ROWS, table.remove(list, i))
        break
      end
    end
  end
  local out = {}
  for i = 1, shown do
    local e = list[i]
    local amount = (e.net >= 0 and "+" or "-") .. PG.Money(math.abs(e.net))
    local colour = (e.net > 0 and P.chgreen) or (e.net < 0 and P.chred) or P.chgray
    out[#out + 1] = e.rank .. ". " .. shortOf(e.name)
      .. (e.name == me and (P.chgold .. " (you)|r") or "")
      .. "  " .. colour .. amount .. "|r"
  end
  if #list > shown then
    out[#out + 1] = P.chgray .. "... and " .. (#list - shown) .. " more|r"
  end
  return table.concat(out, "|n")
end

freezeDialog = function(rec, text)
  -- Only a panel that was actually on screen, or one Safety has hidden - the
  -- same predicate the game windows use, and for the same reason: a key ends
  -- exactly when the surface reporting it may not be visible. A player who
  -- never opened this window gets the toast and the Ledger, and no window
  -- appears unbidden.
  if not dlg then return end
  local hidden = PG.Safety.HidBy and PG.Safety.HidBy(dlg)
  if not (dlg:IsShown() or hidden) then return end
  local body = reportBody(rec)
  if not body then return end   -- a parley that never paid anyone has no result
  dlg.__pgFrozen = true
  for i = 1, #configWidgets do configWidgets[i]:Hide() end
  for i = 1, #liveWidgets do liveWidgets[i]:Hide() end
  hideBoard()
  lockBtn:Hide()
  cancelBtn:Hide()
  dlg:SetHeight(G.SETUP_H)
  statusHead:SetShown(true)
  statusFS:SetShown(true)
  statusHead:SetText("The parley is settled")
  -- statusFS is a two-line box in the live layout; frozen, it borrows the
  -- board's whole vertical band for the tally
  statusFS:SetHeight(320)
  statusFS:SetMaxLines(16)
  statusFS:SetJustifyH("LEFT")
  local head = text and (P.chgray .. text .. "|r|n|n") or ""
  statusFS:SetText(head .. body .. "|n|n" .. P.chgray .. "Close to dismiss.|r")
  local clock = PG.UI.ClockAgo and PG.UI.ClockAgo(0)
  if PG.UI.SetTitle then
    PG.UI.SetTitle(dlg, "Mythic Parley - final" .. (clock and (" (" .. clock .. ")") or ""))
  end
  if PG.Theme and PG.Theme.Stamp then PG.Theme.Stamp(dlg, "SETTLED") end
end

thawDialog = function()
  if not (dlg and dlg.__pgFrozen) then return end
  dlg.__pgFrozen = false
  statusFS:SetHeight(32)
  statusFS:SetMaxLines(2)
  statusFS:SetJustifyH("CENTER")
  if PG.UI.SetTitle then PG.UI.SetTitle(dlg, "Mythic Parley") end
end

function PG.MP.OpenDialog()
  if not dlg then buildDialog() end
  requestMaps()
  refreshDialog()
  dlg:Show()
end

-- /pg keys. Everything this mode assumes about the client, printed - which is
-- the same job /pg comm does for the send gates and /pg rolls does for the roll
-- parser. Every one of these assumptions fails SAFE, so the failure mode is a
-- line quietly not being offered; without this command that is indistinguishable
-- from the addon being broken.
-- "bosses UNKNOWN" on every dungeon has several very different causes, and a
-- diagnostic that cannot tell them apart is not one. This reports the journal
-- itself: whether the load-on-demand addon came in, which entry points exist,
-- and how much the tier walk can actually see.
local function journalStatus()
  ensureJournal()
  local missing = {}
  for _, n in ipairs({ "EJ_GetNumTiers", "EJ_SelectTier", "EJ_GetInstanceByIndex",
                       "EJ_GetEncounterInfoByIndex" }) do
    if type(_G[n]) ~= "function" then missing[#missing + 1] = n end
  end
  if #missing > 0 then
    return "journal: MISSING " .. table.concat(missing, ", ")
  end
  local loaded = "?"
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
  if type(isLoaded) == "function" then
    local ok, v = pcall(isLoaded, "Blizzard_EncounterJournal")
    if ok then loaded = tostring(v and true or false) end
  end
  local okT, nTiers = pcall(EJ_GetNumTiers)
  nTiers = (okT and tonumber(nTiers)) or 0
  local seen = 0
  for tier = 1, nTiers do
    if not pcall(EJ_SelectTier, tier) then break end
    for i = 1, 60 do
      local ok, id = pcall(EJ_GetInstanceByIndex, i, false)
      if not ok or not id then break end
      seen = seen + 1
    end
  end
  return "journal: addonLoaded=" .. loaded .. "  tiers=" .. nTiers
    .. "  dungeons visible=" .. seen
end

function PG.MP.Diagnose()
  local out = {}
  out[#out + 1] = "lockdown=" .. tostring(PG.Comm.Locked())
    .. "  activeKey=" .. tostring(activeMapId())
    .. "  slotted=" .. tostring(slottedMapId())
  out[#out + 1] = journalStatus()
  local maps = seasonMaps()
  out[#out + 1] = #maps .. " dungeon(s) this season"
    .. (#maps == 0 and " - asked the server again just now" or "")
  local known = 0
  for i = 1, #maps do
    local id = maps[i]
    local roster = rosterOf(id)
    if roster then known = known + 1 end
    out[#out + 1] = "  " .. (mapName(id) or ("#" .. id)) .. " - "
      .. (roster and (#roster .. " bosses, " .. (SRC_WORD[rosterSrc[id]] or "?"))
        or "bosses UNKNOWN, per-boss lines not offered")
  end
  if #maps > 0 then
    out[#out + 1] = known .. "/" .. #maps
      .. " resolved. An unknown dungeon learns its bosses the first time you run it."
  end
  return out
end

function PG.MP.OpenGames()
  local out = {}
  for _, rec in pairs(parleys) do
    -- a LOCKED parley is not offerable: its bets are shut, so a Join would hand
    -- the player a table they can only watch
    if rec.kind == "lite" and rec.phase == "open" then
      out[#out + 1] = {
        game = "MP", host = rec.bookie, token = rec.token, scope = rec.scope,
        stake = rec.stake, expires = rec.expires,
      }
    end
  end
  table.sort(out, function(x, y) return x.host < y.host end)
  return out
end

function PG.MP.JoinOpen(key)
  local k = PG.SafeStr(key)
  if not k then return false end
  local rec = parleys[k]
  if not rec or rec.kind ~= "lite" then return false end
  if myParley() then
    toast("You're already in " .. shortOf(myParley().bookie) .. "'s parley.")
    return false
  end
  if rec.phase ~= "open" then
    toast(shortOf(rec.bookie) .. "'s parley is already locked - the key has started.")
    evict(rec)
    return false
  end
  adoptFull(rec)
  toast(shortOf(rec.bookie) .. "'s Mythic Parley - " .. P.chgold .. PG.Money(rec.stake)
    .. "|r a bet on " .. (mapName(rec.mapId) or "their key") .. ".", rec)
  PG.MP.OpenDialog()
  return true
end

-------------------------------------------------------------------------------
-- Wire handling
--
-- Gate order (CONCURRENCY.md 5.2). Gates a-e are Comm's. Here:
--   f  mtype class      bookie-authored vs the table's BET; unknown -> drop
--   g  session          parleys[keyOf(sender, token)], or - for BET - the
--                       involved record matched on (bookie, token)
--   h  kind             a lite record accepts only CLOSE/RES (evict), HB
--                       (refresh), ROSTER (names) and LOCK (stop being joinable)
--   i  scope equality   blocks re-broadcasting a token on another distribution
--   j  sender authority bookie-authored is guaranteed by g's key; BET must come
--                       from someone allowed at this table (PARLEY.md 4.1)
-------------------------------------------------------------------------------

local function liteObserve(rec, mtype, f1, f2)
  if mtype == "HB" then
    rec.lastHB = GetTime()
    rec.expires = GetTime() + K.LITE_TTL
  elseif mtype == "ROSTER" then
    rec.roster = decodeRoster(f2) or rec.roster
  elseif mtype == "LOCK" then
    rec.phase = "locked"
    rec.lockAt = GetTime()
    -- the invitation dies with the thing it invited you into (CONCURRENCY.md
    -- 5.6 rule 4): a popup offering a table whose bets have shut is a live
    -- countdown into nothing
    if rec.askKey then
      PG.UI.Dismiss(rec.askKey)
      rec.askKey = nil
    end
    removeLauncherRow(rec)
  elseif mtype == "CLOSE" or mtype == "RES" then
    evict(rec)
  end
end

local function offerGuild(rec)
  addLite(rec)
  if PG.IsDND() then return end
  local overflow = shortOf(rec.bookie)
    .. " opened a Mythic Parley - it's in the Pengyou Games window."
  if not (PG.UI.GuildAskOK and PG.UI.GuildAskOK(rec.bookie)) then
    -- over budget: the launcher row above IS the invitation (CONCURRENCY.md
    -- 5.6 rule 1). One throttled toast points at it.
    toast(overflow, nil, { key = "mp-open-overflow" })
    return
  end
  local askKey = "MP:" .. rec.key
  local ok = PG.UI.Ask(askKey,
    shortOf(rec.bookie) .. " opened a Mythic Parley - " .. PG.Money(rec.stake)
      .. " a bet on " .. (mapName(rec.mapId) or "their key") .. ". Bet on it?",
    "Bet", "No thanks", 45,
    function()
      rec.askKey = nil
      PG.MP.JoinOpen(rec.key)
    end,
    function() rec.askKey = nil end,
    "MP")
  if ok then
    rec.askKey = askKey
    if PG.UI.GuildAskSpend then PG.UI.GuildAskSpend(rec.bookie) end
  else
    toast(overflow, nil, { key = "mp-open-overflow" })
  end
end

-- Decision table for an inbound OPEN (CONCURRENCY.md 4.2), evaluated in order.
-- Row 1 (self) is Comm's; rows 2-7 are here.
local function onOpen(token, sender, scope, f1, f2, f3, f4)
  -- row 2: malformed fields, or a scope this mode does not play to
  local stake = PG.SafeNum(f1)
  local mapId = PG.SafeNum(f2)
  if not (stake and mapId) then return end
  stake, mapId = math.floor(stake), math.floor(mapId)
  if stake < K.STAKE_MIN or stake > K.STAKE_MAX then return end
  if mapId < 0 or mapId > 99999 then return end   -- 0 = no dungeon declared
  local card = decodeCard(f3)
  if not card then return end
  -- the declared code exists to be CHECKED against the delivered distribution,
  -- never trusted (SCOPE.md 3.1)
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f4))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end
  if not PG.MP.SCOPES[scope] then return end

  local key = keyOf(sender, token)
  -- row 3: a finished parley's key can never be resurrected
  if recent[key] and (GetTime() - recent[key]) < K.RECENT_TTL then return end
  -- row 4: idempotent. A retransmitted OPEN refreshes liveness and nothing else
  local rec = parleys[key]
  if rec then
    rec.lastHB = GetTime()
    if rec.kind == "lite" then rec.expires = GetTime() + K.LITE_TTL end
    return
  end
  -- row 5: supersession (which may have just freed the full slot)
  supersede(sender, token)
  -- row 6: the lite budget
  if (mine or scope == "guild") and liteCount() >= K.MAX_LITE then evictOldestLite() end

  -- row 7: create the record
  rec = {
    key = key, token = token, bookie = sender, scope = scope,
    stake = stake, mapId = (mapId > 0) and mapId or nil, card = card,
    -- our own client may already know this dungeon's bosses; the bookie's
    -- ROSTER overwrites it either way, so this is only what the board draws in
    -- the second before that lands
    roster = rosterOf(mapId),
    isBookie = false, phase = "open", bets = {},
    openedAt = GetTime(), lastHB = GetTime(),
  }
  if mine then
    addLite(rec)
  elseif scope == "guild" then
    offerGuild(rec)
  else
    adoptFull(rec)
    toast(shortOf(sender) .. " opened a Mythic Parley - " .. P.chgold .. PG.Money(stake)
      .. "|r a bet on " .. (mapName(mapId) or "the key") .. ".", rec)
  end
end

local function onMessage(mtype, token, sender, scope, f1, f2, f3, f4, f5, f6, f7, f8, f9)
  if PG.IsSecret(f1) or PG.IsSecret(f2) or PG.IsSecret(f3) or PG.IsSecret(f4) then return end
  if PG.IsSecret(f5) or PG.IsSecret(f6) or PG.IsSecret(f7) then return end
  if PG.IsSecret(f8) or PG.IsSecret(f9) then return end
  if type(mtype) ~= "string" or type(sender) ~= "string" then return end
  if not validToken(token) then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3, f4) end

  -- gate f + g
  local rec
  if BOOKIE_AUTHORED[mtype] then
    rec = parleys[keyOf(sender, token)]
  elseif mtype == "BET" then
    -- gate g: identity is the PAIR, and BET is the one broadcast in the suite
    -- that cannot be keyed on the sender - so it names its bookie (f3).
    local m = myParley()
    if m and m.token == token and PG.SafeStr(f3) == m.bookie then rec = m end
  else
    return
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype, f1, f2) end   -- gate h
  if scope ~= rec.scope then return end                                   -- gate i

  if mtype == "BET" then
    if not betsAccepted(rec) then return end
    local idx = PG.SafeNum(f1)
    if not idx or idx ~= math.floor(idx) or idx < 1 or idx > #rec.card then return end
    local e = rec.card[idx]
    local pick = PG.SafeStr(f2)
    if not pick then return end
    -- The pick must be one this line actually offers. For a boss-pick line that
    -- means an id ON THIS DUNGEON'S ROSTER, which is what stops a bet on a boss
    -- the card never listed - and it is why a client with no roster refuses to
    -- record boss-pick bets rather than guessing. That refusal is the same on
    -- every client without a roster, and a client WITH one is the normal case,
    -- so it does not split the pool in practice; PARLEY.md 9 names it anyway.
    local ok = false
    local def = MARKET[e.t]
    if def.opts then
      for i = 1, #def.opts do
        if def.opts[i][2] == pick then ok = true break end
      end
    elseif rec.roster then
      -- a boss-pick line's options ARE the roster positions, so a pick has to
      -- name one that exists on this dungeon's roster
      local n = tonumber(pick)
      ok = (n ~= nil and n == math.floor(n) and n >= 1 and n <= #rec.roster)
    end
    if not ok then return end
    -- gate j: a bet moves other people's money, so the sender must be allowed
    -- at this table
    if not betSenderOK(rec, sender) then return end
    local picks = rec.bets[sender]
    if not picks then
      picks = {}
      rec.bets[sender] = picks
    end
    if not picks[idx] then picks[idx] = pick end   -- first pick per line locks
    if refreshBoard then refreshBoard() end
    return
  end

  -- everything below is bookie-authored, and gate g already proved the sender
  -- IS this record's bookie (the key is bookie|token)
  rec.lastHB = GetTime()
  if mtype == "CLOSE" then
    closeParley(rec, shortOf(sender) .. " called the parley off - stakes returned.")
  elseif mtype == "HB" then
    return
  elseif mtype == "ROSTER" then
    local list = decodeRoster(f2)
    if list then
      rec.roster = list
      if refreshBoard then refreshBoard() end
    end
  elseif mtype == "LOCK" then
    if lockLocally(rec) then
      local m = PG.SafeNum(f1)
      if m and m > 0 then rec.actualMapId = math.floor(m) end
      local lvl = PG.SafeNum(f2)
      if lvl and lvl > 0 then rec.keyLevel = math.floor(lvl) end
      if rec.mapId and rec.actualMapId and rec.actualMapId ~= rec.mapId then
        rec.mapMismatch = true
      end
      toast("No more bets - " .. shortOf(sender) .. " has started the key.", rec,
        { key = "mp-lock" })
      if refreshDialog then refreshDialog() end
    end
  elseif mtype == "RES" then
    -- A RES for a parley we never saw lock still settles: LOCK is sent at the
    -- edge of a lockdown and can be dropped, and refusing here would strand
    -- every bettor who missed one message.
    lockLocally(rec)
    local outcome = PG.SafeStr(f1)
    if outcome ~= "C" and outcome ~= "A" then return end
    settleParley(rec, {
      outcome = outcome,
      t = PG.SafeStr(f2) or "-",
      d = PG.SafeStr(f3) or "-",
      w = PG.SafeStr(f4) or "-",
      s = PG.SafeStr(f5) or "-",
      fd = PG.SafeStr(f6) or "-",
      fw = PG.SafeStr(f7) or "-",
      wb = PG.SafeStr(f8) or "-",
      bd = PG.SafeStr(f9) or "-",
    })
  end
end

-- Lockdown drops are permanent. A dropped OPEN means nobody heard the parley
-- exists; un-open it. A dropped BET is the sender's own loss and is never
-- recorded (the pick is only taken from onSent). A dropped ROSTER is re-sent
-- every fourth heartbeat. A dropped LOCK is covered by every client's own
-- restriction and by RES. A dropped RES releases the in-flight flag so the
-- retry schedule can try again.
local function onDrop(mtype, token)
  local rec = myParley()
  if not (rec and rec.isBookie) then return end
  if PG.SafeStr(token) ~= rec.token then return end
  if mtype == "OPEN" then
    closeParley(rec, "The parley could not be opened (messaging is locked).")
  elseif mtype == "RES" then
    local run = rec.run
    if run then run.inflight = false end
  end
end

-------------------------------------------------------------------------------
-- Safety transitions
--
-- RESTRICT_ON is the lock trigger that matters: ADDON_RESTRICTION_STATE_CHANGED
-- fires BEFORE the restriction activates, which makes it the only trigger with
-- a working wire guaranteed underneath it. It also fires for a raid encounter
-- and for a PvP match, and the lock is still taken and still final - from that
-- instant the bookie cannot speak, cannot heartbeat and cannot keep the table
-- honest, so betting must stop. If the key never happens, K.LOCK_MAX voids the
-- parley and every stake comes back.
-------------------------------------------------------------------------------

local function onSafetyChange(_, trigger)
  local rec = myParley()
  if not rec then return end
  if trigger ~= "RESTRICT_ON" then return end
  if rec.isBookie then
    bookieLock(rec, "Bets are locked - your addons have gone quiet.")
    return
  end
  -- A BETTOR only self-locks at GROUP scope, and the scope test is the whole
  -- rule. At group scope the bookie is in our party, so a restriction we can
  -- see is the same one they are about to take, and freezing here is a free
  -- backstop for a dropped LOCK. At GUILD scope our own restriction says
  -- nothing about theirs: a guildmate who pulls a raid boss while betting on
  -- somebody else's key would otherwise lock themselves out of a table that is
  -- still wide open, permanently, because the lock is final.
  if rec.scope ~= "group" then return end
  if lockLocally(rec) and refreshDialog then refreshDialog() end
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

PG.RegisterInit(function()
  if PG.Theme and PG.Theme.C then
    local c = PG.Theme.C()
    for k in pairs(P) do
      if c[k] ~= nil then P[k] = c[k] end
    end
  end
  PG.Comm.Register("MP", onMessage, onDrop)
  -- Every message this mode sends is a BROADCAST; it has no 1:1 traffic at all,
  -- so a whisper claiming to be MP is by construction not ours and vouches for
  -- nobody (SCOPE.md 4.3).
  if PG.Comm.RegisterTrust then
    PG.Comm.RegisterTrust("MP", function() return false end)
  end
  PG.Safety.OnChange(onSafetyChange)
  PG.RegisterEvent("ENCOUNTER_START", onEncounterStart)
  PG.RegisterEvent("ENCOUNTER_END", onEncounterEnd)
  PG.RegisterEvent("UNIT_DIED", onUnitDied)
  PG.RegisterEvent("CHALLENGE_MODE_START", onChallengeStart)
  PG.RegisterEvent("CHALLENGE_MODE_COMPLETED", onChallengeCompleted)
  PG.RegisterEvent("CHALLENGE_MODE_RESET", onChallengeReset)
  PG.RegisterEvent("CHALLENGE_MODE_DEATH_COUNT_UPDATED", onDeathCount)
  -- The season list arrives asynchronously; ask once at load and repaint when
  -- it lands, so the picker is never stuck on "no dungeons reported yet".
  requestMaps()
  PG.RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE", function()
    if dlg and not myParley() then
      syncMaps()
      if refreshCard then refreshCard() end
    end
  end)
  -- Zoning is the only moment step 3b can start working when it could not
  -- before, and rosterOf caches its misses.
  PG.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    forgetRosterMisses()
    if dlg and not myParley() and refreshCard then refreshCard() end
  end)
end)
