-- Games/DeathRoll.lua - Death Roll: sequential-turn elimination on a REAL
-- in-game /roll. The addon never invents a number. Every turn is settled by a
-- server-generated CHAT_MSG_SYSTEM line that every single person in the group
-- sees in their own chat window, addon or no addon, which is the entire reason
-- this game exists: the rolls are the proof, and nobody has to trust anybody's
-- screen.
--
-- One host (who may also play) sets a wager and a starting ceiling. Play goes
-- one seat at a time around the sorted roster from a random first seat: the
-- seat holder must produce a real `/roll 1 <ceiling>`, and their result becomes
-- the next ceiling. Rolling a 1 eliminates you - you owe the wager into the pot
-- and the ceiling resets for the next seat. Last player standing takes the pot.
-- AT EXACTLY TWO PLAYERS THIS IS THE CLASSIC 1v1 DEATHROLL, EXACTLY: `first` is
-- one of the two, they alternate, the ceiling passes back and forth, and the
-- first to roll a 1 pays the other `wager * (2 - 1)` = the wager. The
-- "ceiling resets on elimination" rule is simply unreachable there because the
-- game ends in the same instant. That reduction is deliberate and a refactor
-- must not break it.
--
-- REAL GOLD, SO READ THIS BEFORE TOUCHING THE LEDGER PATH (BRIEF 2):
-- a host-authored END with no client-side check would let a modified host name
-- any roster member the survivor, and every client would happily write
-- zero-sum, fully vouched, gate-passing rows crediting the wrong person. So
-- every client here RE-DERIVES the whole game from the rolls IT OBSERVED
-- ITSELF (deriveOutcome below) and compares that with the host's END:
--   agrees      -> commit
--   disagrees   -> commit NOTHING, S.disputed, and say so on screen
--   own gaps    -> commit NOTHING, S.missed, and say so on screen
-- A healthy client always agrees. This is only possible because the evidence is
-- public - every group member's client renders the identical system lines - and
-- it is the one place this suite is strictly stronger than "the host says so".
--
-- Because the check is a PRECONDITION of committing and not an extra, a client
-- whose PG.Rolls.Ready() is false is refused at hostOpen AND at clientAccept.
-- Such a client could still take its turns (the host adjudicates), but it could
-- never verify anything, so it would sit at the table recording nothing while
-- everyone else recorded - the divergent ledger CONCURRENCY.md 0.4 forbids.
-- Refusing at the door costs one player a game; letting them in costs the table
-- its agreement.
--
-- GROUP SCOPE ONLY (PG.DR.SCOPES). A /roll system message reaches your own
-- party or raid and nowhere else, so a guildmate in another zone would never
-- see a single roll of the game they were invited to. Guild and public are not
-- disabled here, they are physically impossible; the doctrine and the shape are
-- The Pull Book's.
--
-- Consequences of group-only that a reader will otherwise look for and not find:
--   * There is no HB_QUIET_WIDE / HB_GIVEUP_WIDE pair. Host and clients are
--     provably in the same content, so silence really is silence and the 35s
--     heartbeat rule is the only one. Do not "restore" them.
--   * The whisper trust predicate is PB's blanket `false` (BRIEF 4.2): at group
--     scope Comm's own roster test already vouches for every legitimate
--     whisperer, so a module predicate could only ever widen the door.
--
-- THE WIRE. Envelope unchanged: 3|DR|<mtype>|<token>[|fields...]. WIRE_VERSION
-- stays "3" (BRIEF 1.2): a module code is purely additive, and a 1.0.0 client
-- finds moduleHandlers["DR"] nil and drops the traffic with no state, no row and
-- no error. B = broadcast on S.scope (always "group"); W = whisper, which every
-- 1:1 message uses at every scope (SCOPE.md 2.3).
--
--   OPEN   B  wager, ceil0, joinSecs, scopeCode  scopeCode is CHECKED against
--                                                the delivered distribution
--   JOIN   W  -                                  "I'm in"
--   JOINED B  fullName                           entrant confirmed
--   UNJOIN W  -                                  withdraw during the join window
--   LEFT   B  fullName                           withdrawal confirmed
--   BEGIN  B  count, first, dig                  roster frozen; first = opening
--                                                seat; dig = 4-hex roster digest
--   CANCEL B  reason                             aborted; NO ledger anywhere
--   TURN   B  seq, idx, ceil, secs               roster[idx] must roll 1..ceil.
--                                                A repeat with the same seq AND
--                                                idx is a pure timer refresh.
--   ROLL   B  seq, idx, value                    outcome of turn seq. 0 = "no
--                                                roll in time"; 0 or 1 eliminates
--                                                and resets the ceiling
--   END    B  winIdx                             the ledger applies here, only
--   HB     B  phase, seq                         heartbeat, every 10s
--   SYNCQ  W  phase, seq, rosterN, dig           resync request
--   SYNCST W  seq, idx, ceil, remain, alive      state snapshot; alive is a
--                                                positional [01] string
--   SYNCOK W  -                                  you are current
--   SYNCNO W  -                                  gap too large; asker spectates
--
-- There is deliberately no OUT, no VOID and no elimination-order field. See
-- hostTimeoutTurn, the Safety block and the ledger block for each reason.
--
-- BYTE BUDGET (SPEC 2.6, <= 200 bytes). Worst case is SYNCST at the 40-player
-- raid cap with a pathological 24-byte token:
--   "3|DR|SYNCST|" 12 + token 24 + "|999|40|100000|600|" 19 + 40 alive chars
--   = 95 bytes. With a realistic 6-byte token ("1a-7f3") it is 77.
-- Second largest is JOINED with the 48-byte name bound:
--   "3|DR|JOINED|" 12 + 24 + 1 + 48 = 85 bytes (67 realistic).
-- Everything else is under 50. Nothing is ever chunked and there is no
-- multipart anything, so no message can straddle a lockdown boundary.
local ADDON, PG = ...

PG.DR = {}

-- Read by PG.UI.ScopePicker (SCOPE.md 1.2 / 5.2) and by the launcher. Written
-- out in full, including the two falses, so the picker's `allowed` table reads
-- as a deliberate answer rather than an omission.
PG.DR.SCOPES = { group = true, guild = false, public = false }

-- Death Roll CLAIMS the single round-based seat (BRIEF 1.1, I1): it demands a
-- timed decision from a human, which is the whole test. The launcher reads this
-- rather than special-casing module codes.
PG.DR.SEAT = true

local TICK = 0.5             -- master ticker period (drives all session timing)
local HB_INTERVAL = 10       -- host heartbeat cadence
local HB_TIMEOUT = 35        -- client: host is dead after this much silence
local BEGIN_PAUSE_SECS = 2   -- pause between BEGIN and turn 1
local TURN_PAUSE = 2         -- pause between a survived roll and the next turn
local ELIM_PAUSE = 3.5       -- ... and after an elimination, so it can be read
local MIN_REOPEN_SECS = 8    -- floor for a turn re-opened after a freeze: a
                             -- player who just came out of a boss fight needs
                             -- longer than the stub of a timer that expired
                             -- during it
local SHORT_TURN = 4         -- turn length for a seat the host can no longer
                             -- find in the group (see hostSeesGone)
local GONE_GRACE = 10        -- ... after this many continuous seconds absent
local TIMEOUT_SLACK = 3      -- how much earlier than OUR OWN copy of a turn's
                             -- deadline a claimed timeout is still believed:
                             -- the host's TURN and its ROLL reach us with
                             -- different delays, and an honest client must not
                             -- lose its whole ledger to that jitter (see
                             -- deriveOutcome). broadcast() reports success at
                             -- ENQUEUE, so a TURN can sit seconds behind the
                             -- shared send bucket while the ROLL a whole turn
                             -- later finds it refilled - at 1 second a 1.5s
                             -- stall cost an honest table every one of its
                             -- rows. Three is affordable because what it is
                             -- subtracted from is now MIN_TURN and not
                             -- SHORT_TURN (see applyTurn)
local MAX_SEQ = 999          -- hard bound on turns in one game
local MAX_PLAYERS = 40
local MIN_CEIL, MAX_CEIL = 2, 100000
local MIN_WAGER, MAX_WAGER = 1, 100000
local MIN_JOIN, MAX_JOIN = 10, 300     -- dialog range for the join window
local MIN_TURN, MAX_TURN = 15, 60      -- ... and for the turn timer
-- A ceiling of 1 is impossible by construction (MIN_CEIL is 2): a roll of 1
-- always eliminates, so a ceiling of 1 would be a guaranteed loss for whoever's
-- turn it happened to be.
local MAX_OBS = 1000000      -- the client's own /roll ceiling: the bound a
                             -- parsed observation is validated to, which is
                             -- wider than MAX_CEIL on purpose so a wrong-range
                             -- roll can still be reported back to its roller
local SYNC_COOLDOWN = 10     -- min seconds between SYNCQ sends/serves per peer
local SYNC_MAX_REPLAY = 20   -- resync gaps larger than this get SYNCNO
local SYNC_REPLY_SECS = 25   -- how long a resync WE ASKED FOR may still be
                             -- answered by whisper (the provenance window, see
                             -- WHISPERABLE). Sized from the wire, not guessed:
                             -- a maximal replay is SYNC_MAX_REPLAY messages and
                             -- Comm's outbound bucket is capacity 10 refilling
                             -- 1/s (Comm.lua BUCKET_CAP), so the tail of a
                             -- 20-message replay reaches the wire about 10s
                             -- after its head, and a host queue that is already
                             -- busy can roughly double that. It stays under the
                             -- host's own 30s syncReplayUntil shield for the
                             -- same replay, so the window can never outlive the
                             -- reply it is waiting for.
local MAX_ROWS = 11          -- roster rows drawn in the window: derived from the
                             -- band between ROSTER_Y and ui.mine at the shared
                             -- Theme.METRIC.ROW_PITCH of 20, not guessed
local ROLL_TOAST_EVERY = 5   -- own-roll feedback: at most one line per this

-- Registry budget (CONCURRENCY.md 2.1 / 7.3), identical to LG and RPS.
local MAX_LITE = 8           -- overheard sessions remembered at once
local MAX_RECENT = 16        -- dead keys remembered
local RECENT_TTL = 120       -- seconds a dead key stays poisoned
local DONE_TTL = 60          -- seconds a finished full record lingers
local LITE_TTL_PAD = 10      -- a lite record lives joinSecs + this ...
local LITE_TTL_MIN = 15      -- ... clamped into this range
local LITE_TTL_MAX = 180
local ASK_MAX = 3            -- refreshed from PG.UI.ASK_MAX at init
local BUSY_TOAST_EVERY = 60  -- busy client: at most one group line per minute

-- The Pull Book's answer to "why can't I run this for my guild", delivered at
-- the moment the question is asked - the disabled segment IS the message.
local WIDE_SCOPE_REASON =
  "Death Roll is settled by real /roll results, and the game only shows those "
  .. "to your own party or raid. A guildmate anywhere else would never see a "
  .. "single roll."

-- Faire palette, literal spec values; refreshed from PG.Theme.C at init when
-- the theme layer is present (the values are identical). Presentation only.
local P = {
  chgold = "|cffffd876", chgreen = "|cff7deda4", chred = "|cffff8a70",
  chgray = "|cffa8a89c",
  CHALK = { 0.95, 0.93, 0.87 }, CHGOLD = { 1.00, 0.85, 0.46 },
  CHGRAY = { 0.66, 0.66, 0.61 },
}

-------------------------------------------------------------------------------
-- The session registry (CONCURRENCY.md 2). Shape copied from Loot Goblins.
--
--   * ONE full record: the session this module hosts or sits in.
--   * Bounded LITE records for sessions it merely overhears - an invitation and
--     a clean identity, nothing else. A lite record never sends, never reaches
--     an applier and never writes a ledger row.
--
-- Every function below opens with `local S = mySession()`, exactly as the three
-- shipped games do.
-------------------------------------------------------------------------------

local sessions = {}   -- [key] = record, key = host .. "|" .. token
local mine            -- key of the ONE full record (hosted or seated), or nil
local recent = {}     -- [key] = GetTime() when it died: replay defence
local recentQ = {}    -- FIFO of poisoned keys, capped at MAX_RECENT

local ticker
local tickN = 0
local win, dialog, dlgInputs, dlgScope, dlgNote, dlgOpen
local ui = {}
local rows = {}
local Theme, TC       -- PG.Theme and the faire palette (nil if Theme absent)
local npc             -- the bookie model (Theme.NPC handle), decoration only

-- invitation throttles, all bounded (the guild budget itself is in Widgets and
-- is never reached here: group scope raises no guild popups)
local busyToastAt, busyPending = 0, 0
local lastRollToastAt = 0

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt, hostOpen, refreshDialog
local clientRequestSync, endSession, evictSession, chainTop
local fxBegin, fxTurn, fxRoll, fxElim, fxEnd

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

-- Roster agreement fingerprint. Copied byte-for-byte from LootGoblins, for the
-- documented reason (LootGoblins.lua rosterDigest): TURN, ROLL, END and SYNCST
-- are all POSITIONAL over the sorted roster and no name ever travels with an
-- outcome, so a mirror whose roster has the right SIZE but the wrong MEMBERS
-- would charge the wrong players with no error anywhere - and a count
-- comparison cannot see it. Those rows would still be zero-sum, still inside
-- the cap, still fully vouched, and would pass all four ledger gates. Bytes are
-- weighted by position inside a name (so anagrams differ) and names by position
-- in the list (so a swap is caught).
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
-- pauses the game. Only the encounter/pre-pull states do.
local function allClear()
  local s = PG.Safety.state
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

-- THE ONE PREDICATE THE WHOLE GAME CLOCK RUNS ON, and it deliberately has both
-- halves. `allClear()` covers encounter / ready check / countdown / restriction;
-- `PG.Comm.Locked()` covers the 12.1 comms lockdown, which also spans an ENTIRE
-- M+ keystone run and an ENTIRE PvP match - neither of which fires
-- ENCOUNTER_START, so neither ever reaches PG.Safety at all.
--
-- Using only allClear() here is a real, verified defect and not a style point:
-- inside a key the host could not send ROLL (the send is refused) but its turn
-- deadline would keep running, and Rolls.lua discards every observation for the
-- whole run (BRIEF 3.4). Twenty minutes later the lockdown lifts and the host
-- instantly times out a player who never had a turn. So the turn FREEZES on
-- exactly the same predicate that stops the sends, and it is checked on the
-- ticker rather than only on PG.Safety transitions - because an M+ run produces
-- no transition to hear.
local function playable()
  if PG.Comm.Locked() then return false end
  return allClear()
end

-- Rolls.lua is a SEPARATE FILE and this module is meaningless without it, so
-- every crossing into it is existence-guarded instead of assumed. A missing or
-- unloaded Rolls.lua must read as "this client cannot read rolls" - a state the
-- game already refuses cleanly, at both doors - and never as a Lua error out of
-- a button click, which is what a bare PG.Rolls.Ready() would produce if the
-- .toc line were ever dropped or reordered.
local function rollsReady()
  return (PG.Rolls and PG.Rolls.Ready and PG.Rolls.Ready()) and true or false
end

local function rollsAvailable()
  return (PG.Rolls and PG.Rolls.Available and PG.Rolls.Available()) and true or false
end

local function rollsSince(t)
  if not (PG.Rolls and PG.Rolls.Since) then return {} end
  local ok, list = pcall(PG.Rolls.Since, t)
  if ok and type(list) == "table" then return list end
  return {}
end

-- Identity is the PAIR (host, token) (CONCURRENCY.md 3.2).
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

-- Core owns the counter now (BRIEF 1.4): PG.NextToken is a persisted monotonic
-- base-36 counter shared by every module, and it never returns nil. This local
-- is the same minimal fallback the three shipped games carry, kept only so a
-- build where Core somehow predates the function still mints usable tokens.
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
    if seq < 1 then seq = 1 end
    p.seq = seq
  end
  return b36(seq) .. "-" .. b36(math.random(0, 46655))
end

-- Wire token validation (CONCURRENCY.md 3.4).
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

-- UI predicate only: never a gate on hosting, on an inbound OPEN, or on opening
-- the dialog (CONCURRENCY.md 0.2).
local function live()
  local S = mySession()
  return S ~= nil and S.phase ~= "done"
end

-- DR toasts carry the dice mark (SKIN.md 2.8); plain text when Theme is absent.
local function toast(text, opts)
  if Theme then text = Theme.Mark("dice") .. " " .. text end
  PG.UI.Toast(text, opts)
end

-- Attribution (CONCURRENCY.md 5.7): while this module holds more than one
-- record its lines name the host, because a player who can see two tables
-- cannot otherwise tell which one a line is about.
local function sname(S)
  if S and S.host and recordCount() > 1 then
    return "Death Roll (" .. shortOf(S.host) .. ")"
  end
  return "Death Roll"
end

local function stoast(S, text, opts)
  toast(sname(S) .. ": " .. text, opts or { key = "dr-status" })
end

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

-- Every send carries the session's own audience (SCOPE.md 2.2), which for this
-- module is always "group". Only the ONE involved record ever broadcasts.
local function broadcast(mtype, ...)
  local S = mySession()
  if not S then return false end
  return PG.Comm.Broadcast(S.scope, "DR", mtype, S.token, ...)
end

-- One ticker for the module (I9). It runs while the registry is non-empty.
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

local function launcherAdd(rec)
  rec.listed = true
  if PG.Launcher and PG.Launcher.AddOpenGame then
    pcall(PG.Launcher.AddOpenGame, {
      game = "DR", host = rec.host, token = rec.token, scope = rec.scope,
      expires = rec.expires, key = rec.key,
    })
  end
end

local function launcherDrop(rec)
  if not rec.listed then return end
  rec.listed = nil
  if PG.Launcher and PG.Launcher.RemoveOpenGame then
    pcall(PG.Launcher.RemoveOpenGame, "DR", rec.host, rec.token)
  end
end

-- A dead session takes its invitation with it (CONCURRENCY.md 5.6 rule 4).
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
-- resurrected by a replayed OPEN (CONCURRENCY.md 4.5). It is also the only
-- place besides endSession that releases the seat (I2).
evictSession = function(rec, keepWindow)
  local key = rec.key
  if sessions[key] ~= rec then return end
  sessions[key] = nil
  dropInvite(rec)
  if mine == key then
    mine = nil
    PG.Session.Release("DR", rec.token)
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

-- Non-secret snapshot of who is in the group right now. Used only by the
-- host's absence scan below; PG.FullName already guards every secret field.
local function groupSet()
  local out = {}
  local function mark(unit)
    local n = PG.FullName(unit)
    if n then out[n] = true end
  end
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do mark("raid" .. i) end
  elseif IsInGroup() then
    mark("player")
    for i = 1, GetNumGroupMembers() - 1 do mark("party" .. i) end
  else
    mark("player")
  end
  return out
end

-- A player who has left the group receives no addon messages at group scope, so
-- they cannot roll, so they time out on their own turn anyway - which is why
-- there is no OUT message and no out-of-turn elimination in this protocol
-- (every state change carries a `seq`, and that is exactly what makes the
-- client-side derivation sound). The only cost is a wasted turn timer, and this
-- removes most of even that: once a living roster name has been missing from
-- the group for GONE_GRACE continuous seconds, their turn opens with
-- SHORT_TURN seconds instead of the full timer.
--
-- The grace is not decoration: GROUP_ROSTER_UPDATE reports a transiently
-- incomplete roster during a party->raid conversion, and a 4-second turn handed
-- to somebody who is standing right there is recoverable (they can still roll
-- and be accepted) where an instant elimination would not be.
local function hostScanGone(S)
  if not S.isHost or S.phase ~= "play" then return end
  local set = groupSet()
  local now = GetTime()
  for i = 1, #S.roster do
    if S.alive[i] then
      local n = S.roster[i]
      if set[n] then
        S.goneAt[n] = nil
      elseif not S.goneAt[n] then
        S.goneAt[n] = now
      end
    end
  end
end

local function hostSeesGone(S, name)
  local at = name and S.goneAt[name]
  return at ~= nil and (GetTime() - at) >= GONE_GRACE
end

-- The memory contract (CONCURRENCY.md 7.3), on the module ticker at 2-second
-- granularity: at most 1 + 8 + 16 = 25 registry entries are ever walked, plus
-- the host's 40-name absence scan.
local function sweep()
  local now = GetTime()
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      if now > (rec.expires or 0) then evictSession(rec) end
    elseif rec.phase == "done" and (now - (rec.doneAt or now)) > DONE_TTL then
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
  local S = mySession()
  if S and S.isHost and S.phase == "play" then hostScanGone(S) end
end

-- A session stops being active the instant phase becomes "done" (7.1), in this
-- order: state, then the SEAT (a new game may start immediately), then the
-- invitation and the launcher row.
endSession = function(text)
  local S = mySession()
  if not S then return end
  S.phase = "done"
  S.turnOpen = false
  S.frozen = false
  S.endText = text
  S.doneAt = GetTime()
  PG.Session.Release("DR", S.token)
  dropInvite(S)
  if win then ui.bar:Stop() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Roster indexing and the roll -> player mapping. GOLD DEPENDS ON THIS.
--
-- Roster keys are canonical "Name-Realm" (they come off the JOINED stream,
-- which the host built with PG.NormalizeSender). Rolls.lua hands us a name that
-- has been through the same PG.NormalizeSender, so a same-realm player's bare
-- system-line name has already had the LOCAL realm appended.
--
-- That agrees across clients for the reason worth writing down: the roll line
-- for a player on realm A is bare on realm-A clients (-> "Name-A") and
-- realm-qualified on every other client (-> "Name-A"). Both arrive at the same
-- string, and the roster key is the host's normalization of the same player,
-- which is that string too.
--
-- MATCHING IS EXACT, AND ONLY EXACT (BRIEF 3.3 a/b). No short-name fallback,
-- because "unique short name in the roster" is not the same question as "the
-- only player who could have produced this line": a NON-participant on our own
-- realm who shares a short name with a cross-realm participant would be
-- attributed to that participant, and at loot-roll ceilings (1-100 is both the
-- default here and what a raid rolls on gear all night) that is not a rare
-- shape. A dropped roll costs a turn the players can see and shout about; a
-- guessed one moves real gold to the wrong character with no error anywhere.
-- Drop is strictly correct.
-------------------------------------------------------------------------------

local function reindex(S)
  local ri, si = {}, {}
  for i = 1, #S.roster do
    local full = S.roster[i]
    ri[full] = i
    local sh = shortOf(full)
    -- false marks "more than one roster member answers to this short name"
    if si[sh] == nil then si[sh] = i else si[sh] = false end
  end
  S.rIndex, S.shortIndex = ri, si
end

local function rosterIndex(S, name)
  if not name or type(S.rIndex) ~= "table" then return nil end
  return S.rIndex[name]
end

-- BRIEF 3.3(d): two roster members sharing a short name where either is on OUR
-- realm cannot be told apart from a system line at all - the same-realm one
-- arrives bare and normalizes onto our realm, and so would a bare line from the
-- other if the server ever declined to qualify it. There is no correct
-- adjudication available, so the game refuses to BEGIN rather than run a table
-- whose payouts might land on the wrong Alice. Returns the offending short name.
local function rosterNameClash(list)
  local realm = GetNormalizedRealmName()
  realm = PG.SafeStr(realm)
  local suffix = (realm and realm ~= "") and ("-" .. realm) or nil
  local function sameRealm(full)
    if not suffix then return true end -- realm unknown: assume the worst
    return full:sub(-#suffix) == suffix
  end
  local seen = {}
  for i = 1, #list do
    local full = list[i]
    local sh = shortOf(full)
    local prev = seen[sh]
    if prev then
      if sameRealm(full) or sameRealm(prev) then return sh end
    else
      seen[sh] = full
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- THE EVIDENCE TABLES AND THE INDEPENDENT DERIVATION (BRIEF 2).
--
-- Four per-turn tables, all created in the record CONSTRUCTORS and never
-- anywhere else (critique-0 B3: two paths reach the play phase without ever
-- running applyBegin - the comm prologue's forced-spectator flip and
-- applyBegin's own absorb-and-return branch - and a nil index on either one is
-- swallowed by Comm's pcall, after which the client silently records nothing
-- for the rest of the game).
--
--   S.hostRoll[seq]  what the HOST said turn `seq` rolled (0 = timed out)
--   S.hostAt[seq]    OUR clock when that claim arrived
--   S.rolls[seq]     what THIS CLIENT observed for turn `seq`, or nil
--   S.tIdx[seq]      the seat the host opened turn `seq` for
--   S.tCeil[seq]     the ceiling the host opened turn `seq` at
--   S.tDue[seq]      OUR clock at the earliest moment a claimed TIMEOUT for turn
--                    `seq` is believable: when the window opened HERE plus the
--                    length the host declared, floored at MIN_TURN - or at
--                    SHORT_TURN for a seat WE cannot find in the group either.
--                    A timeout is the one claim proved by ABSENCE, and absence
--                    proves nothing about a window nobody could have acted in -
--                    without this a host claims a timeout fifty milliseconds
--                    after opening the turn, every client verifies the absence,
--                    and the gold moves for a game in which nobody rolled. A
--                    timer refresh may only ever move it LATER.
--   S.tGate[seq]     true while this client was able to SEE rolls for the whole
--                    of the window turn `seq` was OPEN. Set when the turn opens,
--                    cleared by the ticker the moment the gate closes under an
--                    open turn, cleared as well whenever our mirror moves past
--                    an unresolved turn by ANY route (observeRoll only ever
--                    matches S.seq, so from that instant we are blind to the
--                    old turn - see loseWitness), and RESET by a timer refresh -
--                    a refresh restarts the window, the host can only time out
--                    against the refreshed one, and during the interruption
--                    itself nobody (host included) could observe anything at
--                    all.
--
-- These four are EVIDENCE. Nothing forges them - in particular a SYNCST
-- snapshot repairs the mirror (alive / ceiling / seat / seq) and deliberately
-- leaves these alone, because a client whose evidence has a hole must lose the
-- ability to commit, not regain it.
--
-- The separate S.applied[seq] IS mirror bookkeeping and IS repaired by SYNCST.
-- The two must never be merged.
-------------------------------------------------------------------------------

-- Next living seat strictly after `from`, wrapping. `from == nil` starts AT
-- `first` and includes it. Returns nil only when nothing is alive.
local function nextLivingIn(n, alive, from, first)
  if n < 1 then return nil end
  local i
  if from == nil then
    i = first or 1
    if i < 1 or i > n then i = 1 end
  else
    i = (from % n) + 1
  end
  for _ = 1, n do
    if alive[i] then return i end
    i = (i % n) + 1
  end
  return nil
end

local function nextLiving(S, from)
  return nextLivingIn(#S.roster, S.alive, from, S.first)
end

-- Record one observation against a turn. First valid roll per actor per window
-- wins (BRIEF 3.5 leaves that to the game, and this is where it lives).
-- On the host this is also the moment the turn CLOSES and the ROLL goes out.
local hostSendRoll -- forward: defined with the host logic

local function noteObserved(S, seq, idx, name, value, at)
  if S.rolls[seq] ~= nil then return end
  S.rolls[seq] = value
  S.rollN = S.rollN + 1
  -- The watermark for the next turn's early-roll drain. It is a (time, name)
  -- pair rather than a bare time so the roll we just consumed is excluded
  -- exactly, instead of by a fudge factor: two system lines can legitimately
  -- share a GetTime() when two players roll in the same frame, and one client
  -- can never produce two of them.
  S.turnFrom = at
  S.turnFromName = name
  if S.isHost and S.turnOpen and S.seq == seq and not S.pendingRoll then
    S.pendingRoll = { seq = seq, idx = idx, value = value }
    S.turnOpen = false -- the clock stops on the FIRST accepted roll
    if win then ui.bar:Stop() end
    hostSendRoll()
  end
end

-- A turn's window can open LATE on any client - the host's TURN queues behind
-- the shared 10-token send bucket - and a player watching chat rolls the
-- instant the previous result appears. PG.Rolls.Since exists for exactly this
-- (BRIEF 3.1) and is drained the instant a window opens.
--
-- This is not only a convenience. It is what closes the blind spot in the
-- verify-by-absence branch of deriveOutcome: without it, everything between the
-- previous turn resolving and this client applying the TURN would be invisible
-- to us and a host could claim a timeout for a roll that really happened in it.
local function drainEarly(S, seq, idx, ceilN)
  if S.rolls[seq] ~= nil then return end
  if not S.roster[idx] then return end
  local from = S.turnFrom or 0
  local list = rollsSince(from)
  for i = 1, #list do
    local r = list[i]
    local fresh = (r.at > from) or (r.name ~= S.turnFromName)
    if fresh and r.low == 1 and r.high == ceilN and rosterIndex(S, r.name) == idx then
      noteObserved(S, seq, idx, r.name, r.value, r.at)
      return
    end
  end
end

-- THE DERIVATION. Replays the entire game from the frozen roster, the starting
-- ceiling, the opening seat and the rolls THIS CLIENT saw, checking the host's
-- every claim against it. Returns:
--   winnerIdx, nil        our own replay produced exactly one survivor
--   nil, "dispute"        the host contradicted something we watched happen
--   nil, "gap"            we cannot replay it: something we needed we never saw
--
-- The two failure modes are kept apart on purpose. "dispute" is an accusation
-- and is shown as one; "gap" is this client admitting it was not watching.
-- Both refuse the ledger (BRIEF 2), and that refusal is the entire point.
local function deriveOutcome(S)
  local n = #S.roster
  if n < 2 or n ~= S.count then return nil, "gap" end
  local first = S.first
  if type(first) ~= "number" or first < 1 or first > n then return nil, "gap" end
  local alive, nAlive = {}, n
  for i = 1, n do alive[i] = true end
  local ceilN = S.startCeil
  local idx = first
  local top = S.seq or 0
  for seq = 1, top do
    if nAlive <= 1 then break end
    local ti, tc = S.tIdx[seq], S.tCeil[seq]
    -- We never saw this turn open, so we have no standing on anything in it.
    if ti == nil or tc == nil then return nil, "gap" end
    -- We DID see it, and it is not the turn the rules say comes next. The seat
    -- order and the ceiling are both fully determined by the roster, `first`
    -- and the rolls, so this is the host departing from the rules.
    if ti ~= idx or tc ~= ceilN then return nil, "dispute" end
    local hv = S.hostRoll[seq]
    if hv == nil then return nil, "gap" end
    local ov = S.rolls[seq]
    if ov == nil then
      -- No observation of our own. A claimed TIMEOUT is the one outcome that
      -- CANNOT produce a system line, so it is verified by absence instead -
      -- but only if we were able to see rolls for the whole of that turn, AND
      -- only if that turn had actually RUN OUT here before the host claimed it.
      -- The gate alone says nothing about time: a host that claims the timeout
      -- the instant it opens the turn is absent from a window nobody could have
      -- rolled in, and every client would "verify" that absence and pay out.
      -- Anything else with no observation behind it is a hole in our evidence.
      if hv ~= 0 or not S.tGate[seq] then return nil, "gap" end
      local due, at = S.tDue[seq], S.hostAt[seq]
      -- Missing either time is a hole too, and a claim that beat our own copy of
      -- the deadline by more than the message jitter is not evidence of
      -- anything. Both refuse the ledger rather than accuse: a client whose TURN
      -- arrived late is honest and slow, and it must fail to the side that
      -- writes nothing.
      if due == nil or at == nil or at < (due - TIMEOUT_SLACK) then
        return nil, "gap"
      end
    elseif ov ~= hv then
      -- We watched the server print a different number than the host reported.
      return nil, "dispute"
    end
    if hv == 0 or hv == 1 then
      alive[idx] = nil
      nAlive = nAlive - 1
      ceilN = S.startCeil
    else
      ceilN = hv
    end
    idx = nextLivingIn(n, alive, idx, first)
    if idx == nil then return nil, "gap" end
  end
  if nAlive ~= 1 then return nil, "gap" end
  for i = 1, n do
    if alive[i] then return i end
  end
  return nil, "gap"
end

-- Highest turn K such that every turn 1..K has been applied to the MIRROR. This
-- is the resync question ("what did I miss"), never the ledger question - a
-- SYNCST fills it in wholesale, which is correct for a mirror and would be a
-- forgery in the evidence tables.
chainTop = function(S)
  local k = 0
  while S.applied[k + 1] do k = k + 1 end
  return k
end

-- Positional [01] string over the sorted roster, for SYNCST.
local function aliveString(S)
  local out = {}
  for i = 1, #S.roster do out[i] = S.alive[i] and "1" or "0" end
  return table.concat(out)
end

-------------------------------------------------------------------------------
-- Shared state transitions. The host applies these locally at send time (the
-- SPEC section 6 loopback rule); clients apply them on receipt.
-------------------------------------------------------------------------------

local function applyJoined(name)
  local S = mySession()
  if not S then return end
  -- Resync replays land here too: a desynced spectator mid-play accepts the
  -- replayed JOINED/LEFT stream to repair its roster, which is what lets it map
  -- positional indices onto the same names as everybody else.
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if not S.joined[name] then
    S.joined[name] = true
    S.roster[#S.roster + 1] = name
    table.sort(S.roster) -- plain byte-order sort: the spec's "sorted roster"
    reindex(S)
    -- G2 VOUCHING is accumulated from the stream we watch rather than frozen at
    -- BEGIN, so it exists even on the paths that never run applyBegin. It is
    -- what keeps a player who has since LEFT THE GROUP commit-able: groupSet()
    -- no longer holds them, but this does.
    S.vouched[name] = true
  end
  if name == myName() and S.phase == "join" then
    S.joinAccepted = true
    ShowWindow()
    if win then ui.bar:Start(math.max(1, (S.joinDeadlineDisplay or GetTime()) - GetTime())) end
  end
  RefreshUI()
end

local function applyLeft(name)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if S.joined[name] then
    S.joined[name] = nil
    S.vouched[name] = nil
    for i = #S.roster, 1, -1 do
      if S.roster[i] == name then table.remove(S.roster, i) end
    end
    reindex(S)
  end
  if name == myName() and not S.isHost then
    -- WITHDRAWAL (CONCURRENCY.md 7.2). Nothing is written anywhere: a
    -- withdrawal during the join window is an abort, and no wager exists yet.
    S.joinAccepted = false
    if win and win.__pgRec == S then win:Hide() end
    evictSession(S)
    return
  end
  RefreshUI()
end

-- `public` is false when these fields arrived by WHISPER, i.e. out of a resync
-- replay rather than off the broadcast every other client heard. It decides
-- nothing about the mirror and everything about the LEDGER: see S.beginPublic
-- in applyEnd.
local function applyBegin(count, first, dig, public)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" then
    -- BEGIN while playing is ignored. The one exception is a client that missed
    -- BEGIN entirely (forced spectator, S.count == nil): it absorbs the fields
    -- so resync agreement can be evaluated at all. Every table it might touch
    -- already exists - see the constructors - so this path indexes nothing nil.
    if S.phase == "play" and S.spectator and S.count == nil then
      S.count = count
      S.first = first
      S.digest = dig
      S.beginPublic = public and true or false
      RefreshUI()
    end
    return
  end
  S.phase = "play"
  S.count = count
  S.first = first
  S.digest = dig
  S.beginPublic = public and true or false
  S.ceil = S.startCeil
  S.seq = 0
  S.turnIdx = nil
  S.turnOpen = false
  S.nAlive = #S.roster
  for i = 1, #S.roster do S.alive[i] = true end
  S.turnFrom = GetTime()
  S.turnFromName = nil
  reindex(S)
  local me = myName()
  local agrees = (#S.roster == count) and rosterDigest(S.roster) == dig
  if not S.isHost and agrees and not (me and S.joined[me]) then
    -- Our mirror agrees with the host in size AND membership and we are not in
    -- it, so our JOIN never landed. There is no reason to track a game we are
    -- not playing, and the seat matters for the next invitation.
    stoast(S, "your entry did not reach the host - you are not in this game.")
    endSession("You are not in this game.")
    evictSession(S)
    return
  end
  if not S.isHost and not agrees then
    -- Size or membership disagreement: positional indices would name the wrong
    -- players, so we spectate (and never touch the ledger) while asking the
    -- host to replay what we missed. Setting spectator is also what lets the
    -- repair land - applyJoined/applyLeft only accept replays for a spectator.
    S.spectator = true
    stoast(S, "out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  ShowWindow()
  RefreshUI()
  runFX(fxBegin)
end

-- Our mirror is moving past turn `S.seq`. observeRoll only ever matches S.seq,
-- so from that instant we can no longer see a roll for the old turn and we stop
-- being a witness to it: a claimed timeout for it becomes a gap instead of
-- something we "verified" by absence.
--
-- EVERY route that advances S.seq has to say so, and there are three - a newer
-- TURN, a ROLL for a turn that never opened here, and a SYNCST snapshot. Miss
-- one and a modified host advances the mirror through it, opens every seat's
-- window at once (or just the one that decides the game), and claims a timeout
-- on players the whole table watched roll: their rolls land while we are looking
-- at a different seq, nothing contradicts the host, and every client pays out.
-- Tying this to S.turnOpen instead of to the seq is what made that possible:
-- turnOpen is mirror state the host writes (applySyncState sets it from
-- `remain`), so the host could switch the rule off before using it.
local function loseWitness(S, newSeq)
  local cur = S.seq or 0
  if cur >= 1 and newSeq > cur and S.hostRoll[cur] == nil then S.tGate[cur] = false end
end

local function applyTurn(seq, idx, ceilN, secs)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  local now = GetTime()
  if seq < S.seq then return end -- stale
  if seq == S.seq then
    if idx ~= S.turnIdx then return end -- same seq, different seat: malformed
    -- A repeat TURN for the current (seq, idx) is a pure timer refresh, which
    -- is how a frozen turn re-opens after an encounter without discarding it.
    S.deadline = now + secs
    S.turnOpen = true
    S.frozen = false
    S.tGate[seq] = playable() -- the window restarts; see the evidence block
    -- ... and so does the clock a claimed timeout has to beat, but ONLY
    -- FORWARDS. An honest re-open always lands past the deadline it replaces
    -- (hostReopenTurn re-issues what was left of the turn, floored), so the max
    -- costs it nothing - and without the max a modified host opens a long turn,
    -- refreshes it a second later with secs=1, and buys back a four-second
    -- window against a player the MIN_TURN floor below just protected.
    S.tDue[seq] = math.max(S.tDue[seq] or 0, now + math.max(secs, SHORT_TURN))
    ShowWindow()
    if win then ui.bar:Start(secs) end
    RefreshUI()
    drainEarly(S, seq, idx, S.ceil)
    return
  end
  if seq > S.seq + 1 and not S.isHost then clientRequestSync() end
  -- A newer turn is opening over one that never resolved: see loseWitness.
  loseWitness(S, seq)
  S.seq = seq
  S.turnIdx = idx
  S.ceil = ceilN
  S.turnOpen = true
  S.frozen = false
  S.deadline = now + secs
  -- Evidence: what the host claims about this turn, whether we are in a position
  -- to see its roll at all, and when it stops being open on OUR clock.
  S.tIdx[seq] = idx
  S.tCeil[seq] = ceilN
  S.tGate[seq] = playable()
  -- `secs` is the host's own unverifiable number, so a claimed timeout is only
  -- believed against a window at least as long as an honest host could have
  -- opened for THIS seat. The floor is MIN_TURN, the shortest turn the dialog
  -- can be configured for; without it a modified host sends TURN with secs=1 and
  -- buys back the instant elimination this check exists to stop.
  --
  -- SHORT_TURN is available only for a seat we ALSO cannot find in the group
  -- ourselves. A host may legitimately cut a turn short for a player who has
  -- gone (hostStartTurn), and every client can check "has this player gone" for
  -- itself; a host may NOT cut one short for a player who is standing right
  -- there. Where clients disagree about who is in the group, the ones that
  -- disagree derive "gap" and write no rows - divergence in the direction of
  -- "the client that caught it refuses" is the safe direction and is this
  -- file's doctrine everywhere else. hostSeesGone is checked first so the host's
  -- own copy of this test agrees with the one it opened the turn with, even if
  -- the seat reappeared in the group between the two.
  local who = S.roster[idx]
  local floorSecs = MIN_TURN
  if who and (hostSeesGone(S, who) or not groupSet()[who]) then
    floorSecs = SHORT_TURN
  end
  S.tDue[seq] = now + math.max(secs, floorSecs)
  local me = myName()
  if me and S.roster[idx] == me and S.seated and not S.spectator then
    stoast(S, "your turn - roll 1-" .. ceilN .. ".", { key = "dr-turn" })
    if Theme then Theme.Sound("click") end
  end
  ShowWindow()
  if win then ui.bar:Start(secs) end
  RefreshUI()
  runFX(fxTurn)
  drainEarly(S, seq, idx, ceilN)
end

local function applyRoll(seq, idx, value)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  -- EVIDENCE first, and unconditionally: the host's claim for this turn is
  -- recorded even on a path that will not touch the mirror, because the
  -- derivation needs the claim in order to contradict it. WHEN it arrived is
  -- part of the evidence: a claimed timeout is proved by absence, and an
  -- absence only means something once the window it was absent from has run.
  if S.hostRoll[seq] == nil then
    S.hostRoll[seq] = value
    S.hostAt[seq] = GetTime()
  end
  if S.applied[seq] then return end -- idempotent under any replay
  S.applied[seq] = true
  if seq < S.seq then
    -- A late message for a turn the mirror has already moved past. The claim is
    -- banked above; live state is untouched.
    RefreshUI()
    return
  end
  if seq > S.seq then
    -- A ROLL for a turn we never saw open: adopt it so the alive set stays
    -- right, and ask the host for the state. The derivation will find the hole
    -- on its own (tIdx[seq] is nil) and refuse the ledger. The turn we were
    -- watching is one we can no longer see rolls for (loseWitness): a ROLL for a
    -- turn that never opened is otherwise a free way to blind us to the turn
    -- that decides the game, since the derivation stops at the last elimination
    -- and never looks at this one at all.
    loseWitness(S, seq)
    S.seq = seq
    S.turnIdx = idx
    if not S.isHost then clientRequestSync() end
  end
  S.turnOpen = false
  S.frozen = false
  S.lastRoll = { idx = idx, value = value }
  local elim = (value == 0 or value == 1)
  if S.alive[idx] and elim then
    S.alive[idx] = nil
    S.nAlive = S.nAlive - 1
    S.outOrder[#S.outOrder + 1] = idx
    -- Display only, and it must stay display only: the ledger is fully
    -- determined by the wager, the roster and one winner index, so nothing
    -- about HOW somebody went out may ever reach the arithmetic.
    S.outWhy[idx] = value
  end
  S.ceil = elim and S.startCeil or value
  -- If we never observed this turn ourselves, move the early-roll watermark up
  -- to now so the next turn's drain cannot reach back past it.
  if S.rolls[seq] == nil then
    S.turnFrom = GetTime()
    S.turnFromName = nil
  end
  if S.isHost then
    if S.nAlive <= 1 then
      S.endPending = true
    else
      S.nextTurnAt = GetTime() + (elim and ELIM_PAUSE or TURN_PAUSE)
    end
  end
  if win then ui.bar:Stop() end
  ShowWindow()
  RefreshUI()
  runFX(elim and fxElim or fxRoll)
end

-- SYNCST repairs the MIRROR and nothing else. See the evidence block above for
-- why it deliberately does not fill in S.hostRoll / S.rolls / S.tIdx / S.tCeil.
local function applySyncState(seq, idx, ceilN, remain, alive)
  local S = mySession()
  if not S or S.isHost or S.phase ~= "play" then return end
  if #alive ~= #S.roster then return end
  if seq < S.seq then return end
  -- A snapshot repairs a mirror that fell behind, and the mirror is what the
  -- window and the ROLL button put in front of the player. It may not contradict
  -- our own evidence for a turn we WATCHED OPEN and have not seen resolved: a
  -- snapshot that moves that turn's seat, moves its ceiling, or declares it
  -- closed tells this player it is not their turn, or to roll a range that
  -- observeRoll - ours and every other client's - then refuses to match. The
  -- player does not roll, or rolls something nobody counts, and the host claims
  -- the timeout that produces. An honest snapshot for a live turn always agrees
  -- (the host sends its own turnIdx, its own ceiling and remain > 0); one that
  -- does not is answering about a turn we already know better than it does, and
  -- the asker re-asks on its cooldown. Turns we never saw open, and turns we
  -- have seen resolved, are repaired exactly as before.
  if S.tIdx[seq] ~= nil and S.hostRoll[seq] == nil
     and (idx ~= S.tIdx[seq] or ceilN ~= S.tCeil[seq] or remain <= 0) then return end
  local n = 0
  for i = 1, #alive do
    local on = alive:sub(i, i) == "1"
    S.alive[i] = on or nil
    if on then n = n + 1 end
  end
  S.nAlive = n
  -- The snapshot says WHO is out but not in what order or how, so the display
  -- list is completed in roster order with the cause left unknown. Saying "OUT"
  -- is honest; inventing "rolled a 1" for somebody who actually timed out is not.
  for i = 1, #S.roster do
    if not S.alive[i] then
      local known = false
      for k = 1, #S.outOrder do
        if S.outOrder[k] == i then known = true break end
      end
      if not known then S.outOrder[#S.outOrder + 1] = i end
    end
  end
  loseWitness(S, seq) -- the mirror is moving past a turn we never saw resolved
  S.seq = seq
  S.turnIdx = idx
  S.ceil = ceilN
  S.turnOpen = remain > 0
  S.frozen = false
  S.deadline = GetTime() + remain
  -- Mirror bookkeeping only: "you are current" for resync purposes.
  for k = 1, seq do S.applied[k] = true end
  S.syncNeeded = false
  if win then
    if S.turnOpen then ui.bar:Start(remain) else ui.bar:Stop() end
  end
  ShowWindow()
  RefreshUI()
end

local CANCEL_TEXT = {
  few = "Cancelled - not enough players joined. Others may be busy or away, and"
    .. " everyone needs Pengyou Games 1.1 or later to see a Death Roll table.",
  host = "Cancelled by the host - no gold changes.",
  empty = "Everyone left the table - no gold changes.",
  long = "Cancelled - this game ran too long. No gold changes.",
  dupe = "Two players in this group share a name, so rolls can't be told apart"
    .. " - nothing was recorded.",
}

local function applyCancel(reason)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local text = CANCEL_TEXT[reason]
  if not text then text = "Cancelled (" .. tostring(reason) .. ") - no gold changes." end
  stoast(S, text)
  endSession(text)
end

-- A resynced spectator rejoins once its mirror agrees with the host again. DR
-- has no simultaneous-decision fairness problem, so there is no syncHoldR
-- analogue: a healed spectator may roll on the turn that is open right now.
local function maybeClearSpectator()
  local S = mySession()
  if not S or S.isHost or not S.spectator or S.syncDead then return end
  if S.phase ~= "play" or not S.count then return end
  if #S.roster ~= S.count then return end
  -- Size agreement is not membership agreement: without the digest a spectator
  -- heals onto a same-count/wrong-member roster and writes the ledger for the
  -- wrong players, one hop later.
  if S.digest and rosterDigest(S.roster) ~= S.digest then return end
  reindex(S)
  local me = myName()
  if not (me and S.joined[me]) then
    stoast(S, "your entry did not reach the host - you are not in this game.")
    endSession("You are not in this game.")
    evictSession(S)
    return
  end
  S.spectator = false
  stoast(S, "back in sync - you are back in the game.")
  RefreshUI()
end

-------------------------------------------------------------------------------
-- END and the ledger.
--
-- THE GOLD MATH, EXACTLY. w = wager (1..100000), n = #roster == BEGIN's count
-- (2..40). Exactly n - 1 players are eliminated over the life of the game, each
-- owing w into the pot; there is no rake, no partial payment, no dust and no
-- rounding anywhere, because every quantity is an integer multiple of w.
--   winner  +w * (n - 1)
--   everyone else  -w
--   sum = w*(n-1) + (n-1)*(-w) = 0, identically, for every n >= 2.
-- Largest |delta| is the winner's: at the caps 100000 * 39 = 3,900,000, inside
-- Ledger's MAX_ROW_GOLD of 4,000,000. n <= 40 == MAX_ROWS_PER_SESSION.
--
-- WHY THE CAUSE OF AN ELIMINATION IS IRRELEVANT TO THE MATH: rolling a 1,
-- timing out, disconnecting and leaving the group are the same event on the
-- wire (ROLL with value 1 or 0) and the same event in the ledger - that player
-- is not the winner, so they owe w. END plus count plus wager fully determine
-- every row, which is why there is no elimination log on the wire at all.
-- (There was one in an earlier draft: a 40-character positional string of
-- elimination ranks. It cannot exist - forty distinct ranks need forty distinct
-- characters and base-36 supplies thirty-six - and nothing needed it. If the UI
-- wants an order it derives one locally from ROLL, and that order must never
-- feed ledger arithmetic.)
-------------------------------------------------------------------------------

local function applyEnd(winIdx)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  local n = #S.roster
  local winner = S.roster[winIdx]
  if not winner then return end

  -- BRIEF 2. Every client derives the outcome from the rolls it saw itself
  -- before it writes anything. A healthy client always agrees, and the HOST is
  -- held to exactly the same standard rather than exempted - it only ever
  -- broadcasts values it observed, so if the host's own derivation disagrees
  -- with its own END that is a bug in this file and it will refuse in public.
  local derived, why = deriveOutcome(S)
  local pot = S.wager * (n - 1)
  local me = myName()
  local text
  local eligible = (not S.spectator) and (not S.syncDead) and S.seated
    and me and S.joined[me] and true or false

  if S.spectator or S.syncDead then
    -- Roster disagreement, unrepaired: a positional winIdx would name somebody
    -- else's player, so nothing is written.
    text = "Game over - you were out of sync with the host, so no gold was recorded."
  elseif why == "dispute" or (derived ~= nil and derived ~= winIdx) then
    S.disputed = true
    S.derived = derived
    text = "Game over - the result did not match the rolls this client saw."
      .. " Nothing was recorded."
  elseif derived == nil or not S.beginPublic then
    -- BRIEF 4.1 MADE REAL. `agrees` in applyBegin compares our roster against a
    -- count and a digest, and the digest only ever proved that our mirror
    -- matches WHAT THE HOST TOLD US - never that it matches what the host told
    -- the group. A modified host that never broadcasts BEGIN at all, and
    -- whispers each client its own count and digest, gets every one of them to
    -- agree with a DIFFERENT table: shrink one victim's roster with a whispered
    -- LEFT first (applyJoined/applyLeft accept replays) and that victim writes a
    -- zero-sum, in-cap, fully vouched ledger for a game with one real player
    -- missing from it and the pot short by a wager (attack E29).
    --
    -- So the count and digest a ledger is validated against must be the ones the
    -- WHOLE GROUP heard. Then every client that agrees agreed with the same
    -- announcement, which is the only thing that makes their rows the same rows.
    -- A client healed by a private replay still plays, still watches, still
    -- shows the table - it just does not write gold for a game whose start it
    -- only ever heard about in private, which is BRIEF 2's "gaps in its own
    -- observation" case and gets BRIEF 2's message.
    S.missed = true
    text = "Game over - you missed part of this game, so no gold was recorded."
  else
    -- Agreement. Build the rows and commit. G1 participation is `eligible`
    -- (not a spectator, seated - so a referee host writes nothing, I5 - and in
    -- the roster, so a passer-by or a decliner writes nothing). G2 is the
    -- roster we watched fill up. G3 is structural: the row set comes from one
    -- winIdx and two constants, so a non-zero sum is unreachable, and `cap` is
    -- the exact largest magnitude this game can produce. G4 is the id, game,
    -- host, scope and time.
    local rows2 = {}
    for i = 1, n do
      rows2[S.roster[i]] = (i == winIdx) and pot or -S.wager
    end
    if eligible then
      PG.Ledger.Commit({
        id = "DR:" .. S.host .. ":" .. S.token,
        game = "DR",
        host = S.host,
        scope = S.scope,
        at = (type(time) == "function") and time() or nil,
        played = true,
        vouch = S.vouched,
        cap = S.wager * math.max(1, n - 1),
        label = "Death Roll",
      }, rows2)
      local myNet = rows2[me] or 0
      text = "Game over - you " .. (myNet >= 0
        and ("won " .. PG.Money(myNet)) or ("are down " .. PG.Money(-myNet)))
    elseif S.refereed then
      text = "Game over - you ran this one, so no gold was recorded for you."
    else
      text = "Game over - " .. shortOf(winner) .. " takes " .. PG.Money(pot) .. "."
    end
  end
  stoast(S, text, { priority = "result" })

  S.winIdx = winIdx
  S.ended = true
  ShowWindow()
  endSession(text)
  runFX(fxEnd)
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

-- Resync history: the ordered JOINED/LEFT stream and BEGIN's exact fields, so a
-- client with a genuine gap is healed by replaying precisely what it missed.
-- TURN and ROLL are never replayed - SYNCST supersedes them in one message -
-- which is a real simplification over Loot Goblins' per-round replay.
local function hostRecordOp(op, name)
  local S = mySession()
  if not S then return end
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

-- The host applies ONLY at send time (SPEC section 6 loopback rule), so a
-- refused send leaves the host and the group in the same state and the ticker
-- retries.
hostSendRoll = function()
  local S = mySession()
  if not S or not S.pendingRoll then return end
  local p = S.pendingRoll
  if broadcast("ROLL", p.seq, p.idx, p.value) then
    S.pendingRoll = nil
    applyRoll(p.seq, p.idx, p.value)
  end
end

local function hostCancel(reason)
  local S = mySession()
  if not S then return end
  -- END is already on the wire: clients will write the ledger when it lands, so
  -- no abort may interleave after that point.
  if S.endSent then return end
  broadcast("CANCEL", reason) -- best effort; clients otherwise time out
  applyCancel(reason)
end

local function hostStartTurn()
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  if S.nAlive <= 1 then
    S.endPending = true
    return
  end
  if S.seq >= MAX_SEQ then return hostCancel("long") end
  local idx = nextLiving(S, S.turnIdx)
  if not idx then return hostCancel("empty") end
  local secs = S.turnSecs
  if hostSeesGone(S, S.roster[idx]) then secs = SHORT_TURN end
  local seq = S.seq + 1
  if broadcast("TURN", seq, idx, S.ceil, secs) then
    applyTurn(seq, idx, S.ceil, secs)
  else
    S.nextTurnAt = GetTime() + 2 -- send refused; the ticker retries
  end
end

local function hostTimeoutTurn()
  local S = mySession()
  if not S or not S.turnOpen then return end
  -- value 0 is the wire encoding of "did not roll in time", and it eliminates
  -- exactly like a 1. This is the only incentive-compatible rule: a forfeit
  -- that cost nothing would be strictly better than rolling whenever the
  -- ceiling is low, handing every losing player a one-click escape at ceiling 2.
  -- It is made survivable rather than softened - the timer freezes for the whole
  -- of any encounter, ready check, countdown, restriction or comms lockdown, and
  -- the Rules page says a genuine disconnect costs the wager, in those words.
  if broadcast("ROLL", S.seq, S.turnIdx, 0) then
    applyRoll(S.seq, S.turnIdx, 0)
  end
end

local function hostReopenTurn()
  local S = mySession()
  if not S or not S.frozen then return end
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.freezeRemaining or 0))
  -- Same seq, same idx: every client treats this as a pure timer refresh, so
  -- nothing about the turn is discarded. A roll made DURING the interruption
  -- does not exist for anybody - Rolls.lua discards observations for the whole
  -- of it, on the host and on every client alike (BRIEF 3.4) - so there is
  -- nothing here that could have been seen by one side and not the other.
  if broadcast("TURN", S.seq, S.turnIdx, S.ceil, secs) then
    S.frozen = false
    applyTurn(S.seq, S.turnIdx, S.ceil, secs)
  end
end

local function hostEnd()
  local S = mySession()
  if not S or S.endSent then return end
  local winIdx
  for i = 1, #S.roster do
    if S.alive[i] then
      winIdx = i
      break
    end
  end
  if S.nAlive ~= 1 or not winIdx then return hostCancel("empty") end
  -- The ledger applies only once END has actually LEFT THE WIRE: a broadcast
  -- that is merely queued and later dropped by the lockdown aborts through
  -- onDrop with no ledger anywhere instead (all-or-nothing in every branch).
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      if mySession() ~= sess or sess.phase ~= "play" then return end
      sess.endPending = nil
      applyEnd(winIdx)
    end,
  }, "DR", "END", S.token, winIdx)
  if ok then S.endSent = true end
end

local function hostCloseJoin()
  local S = mySession()
  if not S or S.phase ~= "join" then return end
  local count = #S.roster
  if count < 2 then
    -- Honest text (CONCURRENCY.md 6.3): nobody replies "busy", so the host is
    -- told what silence actually means. There is no guild-rank branch because
    -- there is no guild scope.
    if broadcast("CANCEL", "few") then
      applyCancel("few")
    else
      S.joinDeadline = GetTime() + 2
    end
    return
  end
  -- BRIEF 3.3(d), checked here because this is the last moment before real gold
  -- is at stake and the roster is final from here on.
  local clash = rosterNameClash(S.roster)
  if clash then
    if broadcast("CANCEL", "dupe") then
      applyCancel("dupe")
    else
      S.joinDeadline = GetTime() + 2
    end
    return
  end
  -- A random opening seat, carried in BEGIN so every client agrees. The
  -- alternatives both carry a standing bias: "always index 1" always leads with
  -- the alphabetically-first player, and "the host goes first" is a self-dealt
  -- asymmetry. This is the only number the addon generates, and it decides
  -- turn order, never an outcome.
  local first = math.random(1, count)
  local dig = rosterDigest(S.roster)
  if broadcast("BEGIN", count, first, dig) then
    S.hist.beginCount, S.hist.beginFirst, S.hist.beginDigest = count, first, dig
    applyBegin(count, first, dig, true) -- it went out to the whole group
    S.nextTurnAt = GetTime() + BEGIN_PAUSE_SECS
  else
    S.joinDeadline = GetTime() + 2
  end
end

local function hostHandleJoin(sender)
  local S = mySession()
  if not S or S.phase ~= "join" or S.joined[sender] then return end
  if #S.roster >= MAX_PLAYERS then return end
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

-- one replay entry; the explicit arity keeps trailing nils out of the wire
local function pushMsg(out, ...)
  local m = { ... }
  m.n = select("#", ...)
  out[#out + 1] = m
end

-- Resync. Replay by whisper exactly what the asker missed: the JOINED/LEFT
-- stream if its roster disagrees, BEGIN if its phase trails, and then ONE
-- SYNCST carrying the live state. Nothing missing -> SYNCOK; a delta over
-- SYNC_MAX_REPLAY -> SYNCNO and that client spectates the game out.
local function hostHandleSyncQ(sender, phase, seq, rosterN, dig)
  local S = mySession()
  if not S then return end
  if phase ~= "join" and phase ~= "play" then return end
  if not (seq and rosterN) then return end
  if dig ~= nil and not isDigest(dig) then return end
  if PG.Comm.Locked() then return end -- the asker retries after its cooldown
  local now = GetTime()
  local last = S.syncAsk[sender]
  if last and (now - last) < SYNC_COOLDOWN then return end
  S.syncAsk[sender] = now
  local out = {}
  if rosterN ~= #S.roster or (dig and dig ~= rosterDigest(S.roster)) then
    -- The full ordered stream: idempotent application converges any subset
    -- roster onto the host roster exactly, because each name ends in the state
    -- of its last op.
    for i = 1, #S.hist.ops do
      local op = S.hist.ops[i]
      pushMsg(out, (op.op == "J") and "JOINED" or "LEFT", op.name)
    end
  end
  if S.phase == "play" then
    if phase == "join" then
      pushMsg(out, "BEGIN", S.hist.beginCount or S.count,
              S.hist.beginFirst or S.first, S.hist.beginDigest or rosterDigest(S.roster))
    end
    if #out > 0 or seq ~= S.seq then
      local remain = 0
      if S.turnOpen and not S.frozen then
        remain = math.max(1, math.ceil((S.deadline or now) - now))
      end
      pushMsg(out, "SYNCST", S.seq, S.turnIdx or 0, S.ceil, remain, aliveString(S))
    end
  end
  if #out > SYNC_MAX_REPLAY then
    PG.Comm.Whisper(sender, "DR", "SYNCNO", S.token)
    return
  end
  if #out == 0 then
    PG.Comm.Whisper(sender, "DR", "SYNCOK", S.token)
    return
  end
  -- Replay whispers reuse CRITICAL_DROP mtypes, so onDrop cannot tell a dropped
  -- replay from a dropped live broadcast: shield it for a bounded window while
  -- the send queue drains (see REPLAYABLE).
  S.syncReplayUntil = now + 30
  for i = 1, #out do
    local m = out[i]
    PG.Comm.Whisper(sender, "DR", m[1], S.token, unpack(m, 2, m.n))
  end
end

-- Hosting is NEVER blocked by another module, by the seat, or by anybody else's
-- session (I4). It refuses for exactly four reasons: this module is already in
-- a live session (I3), this client cannot read roll results at all, the
-- audience does not exist, or the OPEN broadcast was refused.
local function clamp(v, lo, hi, fallback)
  local n = PG.SafeNum(v)
  if not n then return fallback end
  n = math.floor(n)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

hostOpen = function(wager, ceil0, joinSecs, turnSecs, scope)
  -- The dialog clamps every field, and this clamps them again: hostOpen is a
  -- public-ish entry point and every one of these numbers ends up on the wire
  -- and, for the wager, in a ledger row.
  wager = clamp(wager, MIN_WAGER, MAX_WAGER, 100)
  ceil0 = clamp(ceil0, MIN_CEIL, MAX_CEIL, 100)
  joinSecs = clamp(joinSecs, MIN_JOIN, MAX_JOIN, 45)
  turnSecs = clamp(turnSecs, MIN_TURN, MAX_TURN, 30)
  local prev = mySession()
  if prev and prev.phase ~= "done" then
    if prev.isHost then
      stoast(prev, "you're already running a game. Cancel it first, or wait for it to finish.")
    else
      stoast(prev, "you're playing " .. shortOf(prev.host)
        .. "'s game. You can start your own when it's over.")
    end
    ShowWindow()
    return
  end
  -- The host is the sole adjudicator of every roll, so a client that cannot
  -- READ roll results cannot referee. This is fatal for hosting and only for
  -- hosting: such a client can still join somebody else's table and play, it
  -- just gets no local feedback on its own rolls. PG.Rolls.Ready() is latched
  -- once at init and never changes, so this is the only place it is asked.
  if not rollsReady() then
    toast("Death Roll: this client can't read /roll results, so it can't referee a game."
      .. " (/pg rolls has the details.)")
    return
  end
  local host = myName()
  if not host then return end
  scope = PG.SafeStr(scope) or "group"
  if not PG.DR.SCOPES[scope] then return end
  local avail, why = PG.Comm.ScopeAvailable(scope)
  if not avail then
    toast("Death Roll: " .. (why or "that audience isn't available."))
    return
  end
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  if prev then evictSession(prev, true) end
  local token = nextToken()
  local key = keyOf(host, token)
  -- Broadcast OPEN before constructing the record: a submit-time lockdown drop
  -- invokes our onDrop synchronously, which must not see a half-built session.
  if not PG.Comm.Broadcast(scope, "DR", "OPEN", token, wager, ceil0, joinSecs, code) then
    toast("Death Roll: cannot start right now (addon messages are blocked).")
    return
  end
  -- I5 REFEREE HOSTING. ClaimHost cannot refuse, so this can never return early
  -- and hosting stays unblocked (I4).
  local seated = PG.Session.ClaimHost("DR", token, host)
  local S = {
    kind = "full",
    key = key,
    token = token,
    host = host,
    scope = scope,
    seated = seated and true or false,
    refereed = (not seated) and true or false,
    isHost = true,
    wager = wager,
    startCeil = ceil0,
    joinSecs = joinSecs,
    turnSecs = turnSecs,
    phase = "join",
    roster = {},
    joined = {},
    vouched = {},
    rIndex = {},
    shortIndex = {},
    ceil = ceil0,
    seq = 0,
    alive = {},
    nAlive = 0,
    outOrder = {},
    outWhy = {},
    -- Evidence and mirror bookkeeping, built HERE and not in applyBegin
    -- (critique-0 B3): two paths reach the play phase without applyBegin, and a
    -- nil index on either is swallowed by a pcall and silently records nothing.
    rolls = {},
    rollN = 0,
    hostRoll = {},
    hostAt = {},
    tIdx = {},
    tCeil = {},
    tDue = {},
    tGate = {},
    applied = {},
    goneAt = {},
    hist = { ops = {} },
    syncAsk = {},
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
      applyJoined(host)
    end
    if not live() then return end -- a lockdown drop of JOINED aborts via onDrop
  else
    stoast(S, "you're playing another game, so you're running this one without playing in it.")
  end
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

-- The ROLL button's OnClick, and the ONLY caller of PG.Rolls.Request. It never
-- locks anything optimistically: the sole proof that a roll happened is the
-- observed system line, and the only state change is the host's ROLL broadcast.
local function doRoll()
  local S = mySession()
  if not S or S.phase ~= "play" or not S.turnOpen or S.frozen then return end
  -- gate l (CONCURRENCY.md 5.2): a local action needs the record we are IN and
  -- a seat in it. A referee host adjudicates and never rolls.
  if not S.seated or S.spectator then return end
  local me = myName()
  if not me or S.roster[S.turnIdx] ~= me then return end
  if not (PG.Rolls and PG.Rolls.Request) then return end
  local ok, why = PG.Rolls.Request(1, S.ceil)
  if not ok then
    -- Request's refusals are always actionable strings, and the typed /roll is
    -- on screen at all times anyway, so a refusal is never a dead button.
    stoast(S, why or ("type /roll " .. S.ceil .. " in chat."), { key = "dr-roll" })
  end
  RefreshUI()
end

-- The FULL-record constructor (I7). Called from the Ask accept callback and the
-- launcher's Join button, and NOWHERE else: an OPEN creates a lite record only,
-- so no session state exists on this client without an explicit click.
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
    wager = rec.cfg.wager,
    startCeil = rec.cfg.ceil0,
    joinSecs = rec.cfg.joinSecs,
    phase = "join",
    roster = {},
    joined = {},
    vouched = {},
    rIndex = {},
    shortIndex = {},
    ceil = rec.cfg.ceil0,
    seq = 0,
    alive = {},
    nAlive = 0,
    outOrder = {},
    outWhy = {},
    rolls = {},
    rollN = 0,
    hostRoll = {},
    hostAt = {},
    tIdx = {},
    tCeil = {},
    tDue = {},
    tGate = {},
    applied = {},
    goneAt = {},
    hist = { ops = {} },
    syncAsk = {},
    syncAllClear = allClear(),
    lastHB = now,
    joinAccepted = true, -- provisional; the host's JOINED broadcast confirms
    joinDeadlineDisplay = (rec.openedAt or now) + rec.cfg.joinSecs,
  }
  sessions[S.key] = S -- replaces the lite record under the same key
  mine = S.key
  ensureTicker()
  PG.Comm.Whisper(S.host, "DR", "JOIN", S.token)
  clientRequestSync()
  ShowWindow()
  if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
end

-- Accepting an invitation. The seat is claimed FIRST: on success every other
-- module withdraws its outstanding invitations through PG.Session.OnChange, and
-- on failure the accept is abandoned and nothing is whispered.
local function clientAccept(rec)
  if not rec or sessions[rec.key] ~= rec or rec.kind ~= "lite" then return false end
  -- A client that cannot READ roll results cannot derive the outcome, and a
  -- client that cannot derive the outcome may never commit (BRIEF 2). Letting it
  -- play anyway would mean one player at the table silently recording nothing
  -- while everyone else records - the divergent-ledger case CONCURRENCY.md 0.4
  -- exists to prevent - so the refusal happens here, before any wager exists,
  -- and it says the same thing Rolls.lua already printed at login.
  if not rollsReady() then
    toast("Death Roll: this client can't read /roll results, so it can't check the"
      .. " game's own rolls - you can't join. (/pg rolls has the details.)")
    return false
  end
  local prev = mySession()
  if prev and prev.phase ~= "done" then
    if prev.isHost then
      stoast(prev, "you're running your own game right now - finish it first.")
    else
      stoast(prev, "you're already in " .. shortOf(prev.host) .. "'s game.")
    end
    return false
  end
  if prev then evictSession(prev, true) end
  if not PG.Session.Claim("DR", rec.token, rec.host) then
    toast("Death Roll: you just joined another game - not entering here.")
    return false
  end
  rec.askKey = nil -- its popup has already closed; nothing to dismiss
  launcherDrop(rec)
  clientOpen(rec)
  return true
end

-- The launcher's Open games list joins through the same path as the popup.
function PG.DR.JoinOpen(key)
  return clientAccept(sessions[tostring(key or "")])
end

-- Read-only view of what this module is overhearing, for the launcher list.
function PG.DR.OpenGames()
  local out = {}
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      out[#out + 1] = { key = rec.key, host = rec.host, token = rec.token,
                        scope = rec.scope, expires = rec.expires, game = "DR",
                        wager = rec.cfg.wager, ceil0 = rec.cfg.ceil0 }
    end
  end
  return out
end

-- One line per minute at group scope however many opens arrive in it.
local function listedToast(rec, seated)
  local now = GetTime()
  if (now - busyToastAt) < BUSY_TOAST_EVERY then
    busyPending = busyPending + 1
    return
  end
  if (now - busyToastAt) > (BUSY_TOAST_EVERY * 2) then busyPending = 0 end
  busyToastAt = now
  local extra = busyPending
  busyPending = 0
  if extra > 0 then
    toast((extra + 1) .. " more games are open - see the Pengyou Games window.",
      { key = "dr-busy" })
  elseif seated then
    toast("Death Roll: " .. shortOf(rec.host)
      .. " started a table - you're in another game right now. It's in the Pengyou Games window.",
      { key = "dr-busy" })
  else
    toast("Death Roll: " .. shortOf(rec.host)
      .. " started a table - it's in the Pengyou Games window.", { key = "dr-busy" })
  end
end

-- One invitation per SESSION, keyed by (game, host, token).
local function raiseInvite(rec)
  launcherAdd(rec)
  -- Busy, full, or unable to read rolls at all: no popup. An Ask you cannot
  -- accept is worse than no Ask, and being busy never means being deaf - the
  -- record and the launcher row stay, and clicking Join there explains itself.
  local seated = PG.Session.IsSeated()
  if seated or PG.UI.AskCount() >= ASK_MAX or not rollsReady() then
    if rollsReady() then listedToast(rec, seated) end
    return
  end
  local acceptLabel = "I'm in"
  if Theme then acceptLabel = Theme.Mark("dice") .. " I'm in" end
  local key = "DR:" .. rec.key
  local secs = math.max(1, (rec.expires or GetTime()) - GetTime())
  local ok = PG.UI.Ask(key,
    shortOf(rec.host) .. " started Death Roll - " .. PG.Money(rec.cfg.wager)
      .. " a head, first roll 1-" .. rec.cfg.ceil0 .. ". Join?",
    acceptLabel, "Pass", secs,
    function() clientAccept(rec) end,
    -- Pass, or the countdown running out, takes the popup down, and askKey has
    -- to come down with it: a stale askKey makes the record claim a popup it no
    -- longer has, and row 6 of the OPEN table picks its eviction victim by
    -- exactly that field.
    function() if sessions[rec.key] == rec then rec.askKey = nil end end,
    "DR")
  if ok then rec.askKey = key end
end

-- SUPERSESSION (CONCURRENCY.md 4.3): the newest OPEN from a given host replaces
-- that host's previous session on every client, unconditionally, at any age.
-- Deterministic without arbitration, because the host is the sole authority for
-- its own sessions.
local function supersedeHost(host)
  for _, rec in pairs(sessions) do
    if rec.host == host then
      if rec.kind == "lite" then
        evictSession(rec)
      elseif rec.phase == "done" then
        evictSession(rec, true)
      else
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
local function onOpen(token, sender, scope, f1, f2, f3, f4)
  -- row 2: malformed fields, bad token, declared scope != delivered scope, or
  -- an audience this game does not play to. SCOPE.md 3.1: the trailing scope
  -- code is CHECKED against the delivered distribution, never trusted.
  local wager = num(f1, MIN_WAGER, MAX_WAGER)
  local ceil0 = num(f2, MIN_CEIL, MAX_CEIL)
  local joinSecs = num(f3, 5, 600)
  if not (wager and ceil0 and joinSecs) then return end
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f4))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end -- an OPEN must never arrive by whisper
  if not PG.DR.SCOPES[scope] then return end
  -- row 1: our own OPEN. Comm already refuses self-delivery; belt and braces.
  local me = myName()
  if not me or sender == me then return end
  local key = keyOf(sender, token)
  -- row 3: a finished session's key stays poisoned
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
  -- row 7: a lite record. One small table with nothing it can ever send.
  local now = GetTime()
  rec = {
    kind = "lite",
    key = key,
    token = token,
    host = sender,
    scope = scope,
    cfg = { wager = wager, ceil0 = ceil0, joinSecs = joinSecs },
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

-- Ask the host to replay whatever we missed. At most one per SYNC_COOLDOWN; a
-- refused or cooling-down request stays pending and the ticker retries it.
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
  -- "play" the moment a turn message arrived, but it still needs BEGIN
  -- replayed - that is the message carrying `first` and the roster count.
  local phase = S.count and "play" or "join"
  if PG.Comm.Whisper(S.host, "DR", "SYNCQ", S.token, phase, chainTop(S),
                     #S.roster, rosterDigest(S.roster)) then
    S.lastSyncQ = now
    S.syncNeeded = false
    -- THE PROVENANCE WINDOW OPENS HERE, and only here. See WHISPERABLE: a
    -- whispered host-authored message is the answer to this question, so it is
    -- admissible only while this question is outstanding. Both counters are
    -- reset, never accumulated - a second ask is a second question, not extra
    -- room on the first one.
    S.syncUntil = now + SYNC_REPLY_SECS
    S.syncBudget = SYNC_MAX_REPLAY
  else
    S.syncNeeded = true
  end
end

-------------------------------------------------------------------------------
-- The roll observer. ONE callback for the module, registered once at init:
-- PG.Rolls.OnRoll keeps one callback per module code and re-registering
-- replaces it, so there is nothing to attach and detach per session, and the
-- cost while nobody is playing is the mySession() lookup below.
--
-- A CLIENT NEVER CHANGES GAME STATE FROM AN OBSERVATION. It records evidence
-- and it talks to its own player; the host is the only adjudicator, and its
-- ROLL broadcast is the only thing that moves the game.
-------------------------------------------------------------------------------

local function observeRoll(roll)
  local S = mySession()
  if not S or S.phase ~= "play" or type(roll) ~= "table" then return end
  -- Rolls.lua guarantees these are plain integers in range; re-checked because
  -- everything downstream of here ends up in a gold outcome.
  local name = PG.SafeStr(roll.name)
  local value = num(roll.value, 0, MAX_OBS)
  local low = num(roll.low, 0, MAX_OBS)
  local high = num(roll.high, 0, MAX_OBS)
  local at = PG.SafeNum(roll.at)
  if not (name and value and low and high and at) then return end

  -- Evidence for the open turn, on the host and on every client alike. On the
  -- host this also closes the turn and puts ROLL on the wire.
  --
  -- The test is against the EVIDENCE the host published for this turn (tIdx,
  -- tCeil) and not against the transient S.turnOpen flag, for two reasons that
  -- both matter: it is exactly the pair deriveOutcome will compare against, and
  -- a roll landing in the half-second between a turn's deadline passing and the
  -- ticker noticing is a real roll the host has not yet ruled on. The window
  -- closes on S.hostRoll[seq] instead - once the host has published an outcome
  -- for this turn, a later /roll from the same player is somebody spamming the
  -- command, and accepting it would manufacture a dispute out of nothing.
  --
  -- That door STAYS shut now that a claimed timeout also has to outlast the
  -- turn's window (deriveOutcome). The claim can no longer arrive before the
  -- roll could have been made, so anything landing after it really is late by
  -- the rules - and recording it would let any eliminated player void the whole
  -- table's ledger by typing /roll once more. The host learns of a roll from the
  -- same system line every client sees, so it cannot outrun one either.
  local idx = rosterIndex(S, name)
  local seq = S.seq or 0
  if idx and seq >= 1 and S.hostRoll[seq] == nil and low == 1
     and S.tIdx[seq] == idx and S.tCeil[seq] == high then
    noteObserved(S, seq, idx, name, value, at)
  end

  -- Everything below is local feedback for the player's OWN roll and touches no
  -- game state. A spectator says nothing at all: it cannot map indices to names,
  -- so any assertion it made would be wrong.
  local me = myName()
  if not me or name ~= me or S.spectator or not S.seated then return end
  local now = GetTime()
  local myIdx = rosterIndex(S, me)
  if S.turnOpen and myIdx and myIdx == S.turnIdx then
    if low == 1 and high == S.ceil then
      -- Purely a status line: the roll is not "mine to apply", the host's ROLL
      -- broadcast is what actually happens, and this is deliberately not a lock
      -- on anything (see doRoll).
      S.selfRoll = { seq = S.seq, value = value }
      RefreshUI()
      return
    end
    if (now - lastRollToastAt) < ROLL_TOAST_EVERY then return end
    lastRollToastAt = now
    stoast(S, "that was /roll " .. high .. ". This turn is 1-" .. S.ceil
      .. ": type /roll " .. S.ceil .. ".", { key = "dr-roll" })
    return
  end
  if myIdx and S.alive[myIdx] then
    if (now - lastRollToastAt) < ROLL_TOAST_EVERY then return end
    lastRollToastAt = now
    stoast(S, "not your turn yet.", { key = "dr-roll" })
  end
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

local HOST_AUTHORED = {
  HB = true, JOINED = true, LEFT = true, BEGIN = true, TURN = true,
  ROLL = true, END = true, CANCEL = true, SYNCST = true,
  SYNCOK = true, SYNCNO = true,
}
local CLIENT_AUTHORED = { JOIN = true, UNJOIN = true, SYNCQ = true }

-- The only host-authored messages that legitimately arrive by WHISPER: the
-- resync replay (hostHandleSyncQ sends exactly JOINED / LEFT / BEGIN / SYNCST)
-- and its two answers. TURN, ROLL, END and CANCEL are broadcast-only by
-- construction - this module never replays them, which is what the REPLAYABLE
-- note below is about - so a whispered one is a PRIVATE VIEW of a game whose
-- whole premise is that everybody watches the same rolls. Without this a
-- modified host whispers one victim a TURN with a different ceiling and she
-- rolls the range her own window asked for while every other client's
-- observeRoll refuses to match the roll it just watched happen, or whispers her
-- a CANCEL so she alone writes nothing for a game everybody else records.
local WHISPERABLE = {
  JOINED = true, LEFT = true, BEGIN = true, SYNCST = true,
  SYNCOK = true, SYNCNO = true,
}

-- THE ALLOWLIST ALONE IS NOT ENOUGH, because the six mtypes above are exactly
-- the ones a replay is made of and three of them - JOINED, LEFT and BEGIN - are
-- what a client's ROSTER is built from. Without the window below, a modified
-- host whispers ONE victim LEFT(X), never broadcasts BEGIN at all, and whispers
-- that victim a BEGIN whose count and digest it computed over the SHRUNKEN
-- roster. `agrees` in applyBegin is then TRUE - the digest only ever proved that
-- our mirror matches what the host TOLD US, never that it matches the group -
-- so the victim is not made a spectator and X simply does not exist for it: X's
-- rolls fail rosterIndex and never become evidence, the pot is short one player,
-- and the seat arithmetic is off by one for every name sorted after X. That
-- client writes a zero-sum, in-cap, fully vouched ledger for a game nobody else
-- played (attack E29), and the same trick with a single SYNCNO deletes one
-- player's row outright (E30).
--
-- What the window does NOT close, stated here so the record is honest: a SYNCNO
-- delivered INSIDE a window the victim genuinely opened still lands (E30c).
-- clientOpen sends a SYNCQ for every client at join, so that window is open
-- early in every session, and no gate can tell a host's truthful "you are too
-- far behind to catch up" from a lying one - an honest host must be able to say
-- it. The residual is bounded and deliberately left: the victim records NOTHING
-- (never wrong rows), and it is loud rather than silent, because the player is
-- told twice - "too far out of sync to catch up - spectating this game" and
-- then "you were out of sync with the host, so no gold was recorded". Gambler
-- carries the identical residual as A12a. A cheat that can only make a table
-- refuse to record is a nuisance, not a theft, and buying it off would cost the
-- resync path that keeps honest games playable through a loading screen.
--
-- So: a whispered host-authored message is admissible ONLY WHILE WE HAVE A
-- RESYNC OUTSTANDING - that is, only as the answer to a SYNCQ we ourselves
-- sent. hostHandleSyncQ is the only host->client whisper in this file (the only
-- PG.Comm.Whisper sites with a host record are the three inside it), so a
-- whisper we did not ask for has no honest sender. The window opens in
-- clientRequestSync and closes on the FIRST of:
--   (a) SYNCOK / SYNCNO - the host's own "that is the whole answer";
--   (b) the replay BUDGET being spent - at most SYNC_MAX_REPLAY messages, which
--       is the most hostHandleSyncQ will ever send (it answers SYNCNO above
--       that); and
--   (c) SYNC_REPLY_SECS.
-- (c) alone would NOT be safe: every client sends a SYNCQ the instant it joins
-- (clientAccept), so a bare standing timer leaves a hole covering BEGIN and the
-- opening of the game - and the join window can be set as short as MIN_JOIN.
-- The budget and the terminating answer are what actually shut it.
local function syncWindowOpen(S)
  return (S.syncBudget or 0) > 0 and GetTime() <= (S.syncUntil or 0)
end

-- Gate h: a lite record is an invitation, not a mirror.
local function liteObserve(rec, mtype)
  if mtype == "HB" then
    local cap = (rec.openedAt or GetTime()) + LITE_TTL_MAX
    local want = GetTime() + LITE_TTL_MIN
    if want > cap then want = cap end
    if want > (rec.expires or 0) then rec.expires = want end
  elseif mtype == "BEGIN" or mtype == "CANCEL" or mtype == "END" then
    evictSession(rec)
  end
end

-- The inbound gate order of CONCURRENCY.md 5.2, applied VERBATIM. Gates a-e are
-- Comm's; f-l are here, and nothing before a gate may write state.
--
-- Note in particular that gate k (`rec.phase == "done"`) sits ABOVE the isHost
-- dispatch, exactly as it does in the two shipped games. An earlier draft of
-- this module wanted a "replay the result from a finished host" branch inside
-- hostHandleSyncQ; it could never have executed, and carving an exception into
-- the shared gate order to rescue it would have been a change to the one thing
-- every module is supposed to copy without thinking. A client that missed the
-- end falls back to its own derivation and, failing that, to the 35s heartbeat
-- timeout with no ledger anywhere. Simpler, and already correct.
--
-- ARITY (BRIEF 4.3): Comm dispatches unpack(parts, 5), so the widest message
-- decides how many parameters must be declared. SYNCST has five fields; f1..f6
-- is that plus one spare. Declaring too few silently reads nil and drops every
-- message of the widest type.
local function onComm(mtype, token, sender, scope, f1, f2, f3, f4, f5, f6)
  if not validToken(token) then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3, f4) end

  local rec
  if HOST_AUTHORED[mtype] then
    rec = sessions[keyOf(sender, token)] -- gate g: identity is the pair
  elseif CLIENT_AUTHORED[mtype] then
    local m = mySession()
    if m and m.isHost and m.token == token and scope == "private" then rec = m end
  else
    return -- gate f: unknown mtype
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype) end -- gate h
  if rec.phase == "done" then return end                        -- gate k
  -- gate i: scope equality. "private" is exempt because resync replays of
  -- JOINED/LEFT/BEGIN/SYNCST legitimately arrive by whisper - and only those
  -- (see WHISPERABLE), and only while we are waiting for one (the provenance
  -- window, same place).
  if scope == "private" then
    if HOST_AUTHORED[mtype] then
      if not WHISPERABLE[mtype] then return end
      if not syncWindowOpen(rec) then return end
      rec.syncBudget = rec.syncBudget - 1
      -- The host has answered in full; anything after this was not asked for.
      if mtype == "SYNCOK" or mtype == "SYNCNO" then rec.syncBudget = 0 end
    end
  elseif scope ~= rec.scope then return end
  local S = rec
  if S.isHost then
    -- gate j, client-authored: UNJOIN must come from a seated player
    if mtype == "JOIN" then
      hostHandleJoin(sender)
    elseif mtype == "UNJOIN" then
      if S.joined[sender] then hostHandleUnjoin(sender) end
    elseif mtype == "SYNCQ" then
      hostHandleSyncQ(sender, PG.SafeStr(f1), num(f2, 0, MAX_SEQ),
                      num(f3, 0, MAX_PLAYERS), PG.SafeStr(f4))
    end
    return
  end
  -- gate j, host-authored: guaranteed by gate g's key - sender IS rec.host
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  if S.phase == "join"
    and (mtype == "TURN" or mtype == "ROLL" or mtype == "END" or mtype == "SYNCST") then
    -- We missed BEGIN entirely: spectate for now (no ledger) and ask the host to
    -- replay it. Every table these appliers touch exists already (critique-0
    -- B3), so this flip cannot leave a nil index behind it.
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
    local count = num(f1, 2, MAX_PLAYERS)
    local first = num(f2, 1, MAX_PLAYERS)
    local dig = PG.SafeStr(f3)
    -- The digest is MANDATORY here, unlike LG's optional trailing field: this
    -- module has no pre-digest peers to tolerate, and every positional message
    -- that follows is meaningless without roster agreement.
    if count and first and first <= count and isDigest(dig) then
      applyBegin(count, first, dig, scope ~= "private")
    end
  elseif mtype == "CANCEL" then
    applyCancel(PG.SafeStr(f1) or "?")
  elseif mtype == "TURN" then
    local seq = num(f1, 1, MAX_SEQ)
    local idx = num(f2, 1, MAX_PLAYERS)
    local ceilN = num(f3, MIN_CEIL, MAX_CEIL)
    local secs = num(f4, 1, 600)
    if seq and idx and ceilN and secs then applyTurn(seq, idx, ceilN, secs) end
  elseif mtype == "ROLL" then
    local seq = num(f1, 1, MAX_SEQ)
    local idx = num(f2, 1, MAX_PLAYERS)
    local value = num(f3, 0, MAX_CEIL)
    if seq and idx and value then applyRoll(seq, idx, value) end
  elseif mtype == "END" then
    local winIdx = num(f1, 1, MAX_PLAYERS)
    if winIdx then applyEnd(winIdx) end
  elseif mtype == "SYNCST" then
    local seq = num(f1, 0, MAX_SEQ)
    local idx = num(f2, 0, MAX_PLAYERS)
    local ceilN = num(f3, MIN_CEIL, MAX_CEIL)
    local remain = num(f4, 0, 600)
    local alive = PG.SafeStr(f5)
    if seq and idx and ceilN and remain and alive and alive:match("^[01]+$") then
      applySyncState(seq, idx, ceilN, remain, alive)
    end
  elseif mtype == "SYNCOK" then
    S.syncNeeded = false
  elseif mtype == "SYNCNO" then
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
-- ledger effect; clients notice on the 35s heartbeat (all-or-nothing holds).
local CRITICAL_DROP = {
  OPEN = true, JOINED = true, LEFT = true, BEGIN = true,
  TURN = true, ROLL = true, END = true,
}

-- Resync replay whispers reuse the mtypes above, so onDrop cannot tell a
-- dropped replay from a dropped live broadcast. TURN and ROLL are absent here
-- because this module never replays them - SYNCST supersedes both.
local REPLAYABLE = { JOINED = true, LEFT = true, BEGIN = true }

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
-- Safety transitions.
--
-- THE PLAY-PHASE FREEZE DOES NOT LIVE HERE. It is driven from the ticker off
-- playable(), because an M+ run and a PvP match produce a comms lockdown and no
-- PG.Safety transition at all - there is literally no callback to hang it on.
-- Keeping one predicate in one place is also what stops the two halves drifting.
-- What is left here is the client's resync trigger, which needs the edge rather
-- than the level.
--
-- There is no `broken`/VOID concept anywhere in this module. A roll is a real,
-- already-happened event that cannot be un-rolled, so an interruption PAUSES
-- the game rather than discarding a turn - and it can do that safely only
-- because Rolls.lua discards observations for the whole interruption on every
-- client identically, so there is no roll that one side saw and another did not.
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
  local S = mySession()
  if not S or S.phase == "done" then return end
  -- Plain combat neither pauses the game nor blocks messaging, and it can never
  -- change allClear(); without this every trash pull would churn the turn.
  if trigger == "COMBAT_ON" or trigger == "COMBAT_OFF" then return end
  if S.isHost then return end
  -- The session just emerged from a safety interruption (allClear() went false
  -- -> true), which is exactly where messages go missing.
  local cur = allClear()
  if cur and S.syncAllClear == false then S.syncNeeded = true end
  S.syncAllClear = cur
end

-------------------------------------------------------------------------------
-- Master ticker
-------------------------------------------------------------------------------

local function serviceHost(S, now)
  -- Scope-aware host abort (SCOPE.md 6.1). At group scope this is "you left the
  -- party or raid": the session is immutable in its scope and aborts rather
  -- than migrating.
  local ok, why = PG.Comm.ScopeAvailable(S.scope, 8)
  if not ok then
    why = why or "the audience is gone."
    stoast(S, why .. " Game abandoned, no gold changes.", { priority = "result" })
    endSession("Abandoned - " .. why .. " No gold changes.")
    return
  end
  if now - (S.lastHBSent or 0) >= HB_INTERVAL and not PG.Comm.Locked() then
    if broadcast("HB", S.phase, S.seq) then S.lastHBSent = now end
  end
  local go = playable()
  if S.phase == "join" then
    if not go then
      if not S.joinFrozen then
        S.joinFrozen = true
        S.joinRemaining = math.max(0, (S.joinDeadline or now) - now)
      end
    elseif S.joinFrozen then
      S.joinFrozen = false
      S.joinDeadline = now + (S.joinRemaining or 0)
      S.joinDeadlineDisplay = S.joinDeadline
    elseif now >= (S.joinDeadline or 0) then
      hostCloseJoin()
    end
    return
  end
  if S.phase ~= "play" then return end
  if not go then
    -- The turn stops here and nothing about it is discarded. tGate is cleared
    -- so this client can never later claim to have watched the whole window -
    -- but only while the turn is actually OPEN, because a turn that already
    -- resolved cannot receive another roll and its evidence is complete.
    if S.turnOpen and S.seq >= 1 then S.tGate[S.seq] = false end
    if S.turnOpen and not S.frozen then
      S.frozen = true
      S.freezeRemaining = math.max(0, (S.deadline or now) - now)
      if win then ui.bar:Stop() end
      RefreshUI()
    end
    return
  end
  -- First matching branch only, in this order.
  if S.pendingRoll then
    hostSendRoll()
  elseif S.frozen then
    hostReopenTurn()
  elseif S.endPending then
    hostEnd()
  elseif S.turnOpen then
    if now >= (S.deadline or 0) then hostTimeoutTurn() end
  elseif S.nextTurnAt and now >= S.nextTurnAt then
    S.nextTurnAt = nil
    hostStartTurn()
  end
end

local function serviceClient(S, now)
  local st = PG.Safety.state
  if st.inEncounter or st.restricted or PG.Comm.Locked() then
    -- The host cannot legally heartbeat here, so the watchdog SUSPENDS rather
    -- than declaring the host dead.
    S.lastHB = (S.lastHB or now) + TICK
  elseif now - (S.lastHB or now) > HB_TIMEOUT then
    clientHostDead()
    return
  end
  if S.phase == "play" then
    if not playable() then
      if S.turnOpen and S.seq >= 1 then S.tGate[S.seq] = false end
      if S.turnOpen and not S.frozen then
        S.frozen = true
        S.freezeRemaining = math.max(0, (S.deadline or now) - now)
        if win then ui.bar:Stop() end
        RefreshUI()
      end
    elseif S.frozen then
      -- Come back on our own clock rather than waiting on the host's refresh:
      -- our interruption and theirs need not have been the same length, and the
      -- host's TURN refresh overwrites this the moment it lands anyway.
      S.frozen = false
      S.deadline = now + (S.freezeRemaining or 0)
      if win and S.turnOpen then ui.bar:Start(math.max(1, S.freezeRemaining or 1)) end
      RefreshUI()
    end
  end
  if S.syncNeeded and playable() then clientRequestSync() end
end

onTick = function()
  tickN = tickN + 1
  if tickN % 4 == 0 then sweep() end
  local S = mySession()
  if S and S.phase ~= "done" then
    local now = GetTime()
    if S.isHost then serviceHost(S, now) else serviceClient(S, now) end
    if win and win:IsShown() then RefreshUI() end
  end
  if not next(sessions) then stopTicker() end
end

-------------------------------------------------------------------------------
-- Reveal FX. Pure decoration: every string below is read from state the
-- appliers already settled, and nothing here writes anything. A player with
-- every effect failed loses no information (SKIN.md rule 6.7).
-------------------------------------------------------------------------------

fxBegin = function()
  if not (win and win:IsShown()) then return end
  Theme.Sound("stamp")
end

fxTurn = function()
  if not (win and win:IsShown()) then return end
  if npc and npc.Emote then pcall(npc.Emote, "point") end
end

fxRoll = function()
  if not (win and win:IsShown()) then return end
  Theme.Sound("coins")
end

-- Eliminations go to Theme.Reveal (per-event, droppable when the stage is
-- busy): the text state is already final, and in a six-player game this fires
-- up to five times in a few minutes, so it must never queue up behind itself.
fxElim = function()
  local S = mySession()
  if not (win and win:IsShown() and S and S.lastRoll) then return end
  local name = S.roster[S.lastRoll.idx]
  if not name then return end
  local sess = S
  Theme.Sound("stamp")
  Theme.Reveal({
    game = "DR",
    anchor = { mode = "window", host = win },
    title = "OUT",
    subtitle = shortOf(name) .. ((S.lastRoll.value == 0)
      and " ran out of time" or " rolled a 1"),
    rows = {
      { text = (S.nAlive or 0) .. " still standing", role = "body" },
      { text = "Pot " .. PG.Money(S.wager * ((S.count or 0) - (S.nAlive or 0))),
        role = "body" },
    },
    burst = "none",
    sound = "stamp",
    validate = function() return sessions[sess.key] == sess end,
    priority = sess.seated and 1 or 0,
  })
end

-- The result is the podium (must eventually show, so it QUEUES rather than
-- playing directly). Theme caps the row pool at 10 and collapses the rest.
fxEnd = function()
  local S = mySession()
  if not (win and win:IsShown() and S and S.ended) then return end
  local me = myName()
  local rowsOut = {}
  if S.disputed then
    rowsOut[1] = { text = "The rolls this client saw do not match this result.",
                   role = "fade" }
    rowsOut[2] = { text = "Nothing was recorded.", role = "fade" }
  elseif S.missed or S.spectator then
    rowsOut[1] = { text = "You missed part of this game - nothing was recorded.",
                   role = "fade" }
  else
    local pot = S.wager * (#S.roster - 1)
    local winner = S.roster[S.winIdx or 0]
    if winner then
      rowsOut[1] = { text = winner .. "  +" .. PG.Money(pot), role = "body",
                     place = 1, personal = (winner == me) }
    end
    for i = #S.outOrder, 1, -1 do
      local nm = S.roster[S.outOrder[i]]
      if nm then
        rowsOut[#rowsOut + 1] = { text = nm .. "  -" .. PG.Money(S.wager),
                                  role = "body", personal = (nm == me) }
      end
    end
  end
  local sess = S
  local winner = S.roster[S.winIdx or 0]
  Theme.RevealQueue({
    game = "DR",
    anchor = { mode = "window", host = win },
    variant = "podium",
    title = "DEATH ROLL",
    subtitle = (winner and not S.disputed)
      and (shortOf(winner) .. " takes " .. PG.Money(S.wager * (#S.roster - 1)))
      or "No result recorded",
    rows = rowsOut,
    burst = "coins",
    sound = "settled",
    validate = function() return sessions[sess.key] == sess end,
    -- precedence (CONCURRENCY.md 5.8 rule 3): the session we are PLAYING
    -- outranks one we merely referee
    priority = sess.seated and 1 or 0,
  })
end

-------------------------------------------------------------------------------
-- Game window
--
-- Laid out on the shared grid (Theme.METRIC) and the shared five-role ramp
-- (Theme.FontTemplate). Every y offset below is a multiple of METRIC.GRID; the
-- side inset, roster pitch, audience offset, timer height and footer geometry
-- are the shared numbers, read through mt() rather than copied.
--
-- THE BOOKIE'S COLUMN. Theme.NPC returns a real child Frame, so it draws ABOVE
-- this window's OVERLAY fontstrings: anything sharing its band was not merely
-- crowded, it was hidden - the ceiling, the turn line and the info block all
-- ran under the model in every game state. The model is now cornered at
-- NPC_W x NPC_H and everything inside its vertical band stops a gutter short of
-- it, while the ceiling, the ROLL card and the roster start BELOW it and use
-- the full content width. That is what lets the one big number of the game be
-- centred on the window rather than on whatever the goblin left over.
-------------------------------------------------------------------------------

local WIN_W, WIN_H = 400, 560
-- Resized from Theme.NPC's default 120x150, near enough its 0.8 aspect that the
-- model is not letterboxed; PullBook.lua resizes its bookie the same way. The
-- box starts below the audience line's and ends above the ceiling's, so no
-- region of this window shares a single pixel with the model.
local NPC_W, NPC_H = 80, 96
local NPC_TOP, NPC_RIGHT = -48, -14
local ROSTER_Y = -280

-- The shared ramp and grid, read at call time. The literals are only what a
-- client with no theme layer would see; this file never carries its own copy of
-- a shared number (Widgets.lua reads METRIC the same way).
local FONT_FALLBACK = {
  D1 = "GameFontNormalHuge", D2 = "GameFontNormalLarge", T = "GameFontNormal",
  B = "GameFontHighlight", S = "GameFontHighlightSmall",
}
local METRIC_FALLBACK = {
  INSET = 24, ROW_PITCH = 20, AUD_Y = -34, FOOTER = 16, BTN_W = 105, BTN_H = 22,
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

local function chalk(fs)
  fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  if Theme then Theme.Shadow(fs) end
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

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("dr", "Death Roll", WIN_W, WIN_H, "DR")
  -- Safety auto-resume, but never for a session that has since died or been
  -- replaced: the window is bound to one record and shows nothing else.
  win.__pgResume = function()
    local S = mySession()
    return S ~= nil and win.__pgRec == S
  end

  local inset = mt("INSET")
  -- everything in the model's band stops here: 12px of air, then the goblin
  local colGutter = -NPC_RIGHT + NPC_W + 12

  ui.aud = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.aud:SetPoint("TOPLEFT", inset, mt("AUD_Y"))
  ui.aud:SetPoint("TOPRIGHT", -inset, mt("AUD_Y"))
  ui.aud:SetJustifyH("CENTER")
  ui.aud:SetWordWrap(false)
  ui.aud:SetMaxLines(1)
  ui.aud:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.aud) end

  ui.info = win:CreateFontString(nil, "OVERLAY", ft("B"))
  ui.info:SetPoint("TOPLEFT", inset, -52)
  ui.info:SetPoint("TOPRIGHT", -colGutter, -52)
  ui.info:SetHeight(44)
  ui.info:SetJustifyH("LEFT")
  ui.info:SetJustifyV("TOP")
  ui.info:SetWordWrap(true)
  -- three lines, not two: the block is a column beside the model now, so a
  -- six-figure wager wraps its first line rather than losing it
  ui.info:SetMaxLines(3)
  ui.info:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(ui.info) end

  ui.bar = PG.UI.TimerBar(win, WIN_W - inset - colGutter)
  ui.bar:SetPoint("TOPLEFT", inset, -100)

  -- The hero element: the number every player is looking for. Full content
  -- width, explicitly centred, and below the model rather than behind it.
  ui.ceil = win:CreateFontString(nil, "OVERLAY", ft("D1"))
  ui.ceil:SetPoint("TOPLEFT", inset, -148)
  ui.ceil:SetPoint("TOPRIGHT", -inset, -148)
  ui.ceil:SetJustifyH("CENTER")
  ui.ceil:SetWordWrap(false)
  ui.ceil:SetMaxLines(1)
  ui.ceil:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then
    Theme.SetFont(ui.ceil, "D1")
    Theme.Shadow(ui.ceil)
  end

  ui.rollBtn = PG.UI.CardButton(win, "ROLL", 220, 46, doRoll)
  ui.rollBtn:SetPoint("TOP", 0, -184)

  -- LEFT with a width pair, never centred: this line ticks once a second on the
  -- host's join countdown, and a centred string whose width changes every tick
  -- shuffles sideways once a second (PLAN 4).
  ui.turn = win:CreateFontString(nil, "OVERLAY", ft("B"))
  ui.turn:SetPoint("TOPLEFT", inset, -236)
  ui.turn:SetPoint("TOPRIGHT", -inset, -236)
  ui.turn:SetJustifyH("LEFT")
  ui.turn:SetWordWrap(false)
  ui.turn:SetMaxLines(1)
  chalk(ui.turn)

  ui.hint = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.hint:SetPoint("TOPLEFT", inset, -256)
  ui.hint:SetPoint("TOPRIGHT", -inset, -256)
  ui.hint:SetJustifyH("LEFT")
  ui.hint:SetWordWrap(false)
  ui.hint:SetMaxLines(1)
  ui.hint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.hint) end

  -- The empty state is NOT list item zero: it gets its own centred line across
  -- the roster band instead of inheriting row 1's left inset (PLAN 4).
  ui.empty = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.empty:SetPoint("TOPLEFT", inset, ROSTER_Y)
  ui.empty:SetPoint("TOPRIGHT", -inset, ROSTER_Y)
  ui.empty:SetJustifyH("CENTER")
  ui.empty:SetWordWrap(false)
  ui.empty:SetMaxLines(1)
  ui.empty:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.empty) end

  -- one short sentence about you, alone above a centred button row: centred
  ui.mine = win:CreateFontString(nil, "OVERLAY", ft("B"))
  ui.mine:SetPoint("BOTTOMLEFT", inset, 46)
  ui.mine:SetPoint("BOTTOMRIGHT", -inset, 46)
  ui.mine:SetJustifyH("CENTER")
  ui.mine:SetWordWrap(false)
  ui.mine:SetMaxLines(1)
  chalk(ui.mine)

  local btnW, btnH, foot = mt("BTN_W"), mt("BTN_H"), mt("FOOTER")
  ui.startBtn = PG.UI.Button(win, "Start now", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and S.phase == "join" then hostCloseJoin() end
  end)
  -- the shared footer inset, which is also what opens the 1px clearance
  -- between the right-hand button and the resize grip to 5px
  ui.startBtn:SetPoint("BOTTOMLEFT", inset, foot)
  ui.cancelBtn = PG.UI.Button(win, "Cancel game", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and S.phase ~= "done" then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOMRIGHT", -inset, foot)
  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", btnW, btnH, function()
    local S = mySession()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "DR", "UNJOIN", S.token)
      -- The local press is authoritative for this client (7.2): the seat frees
      -- now rather than when the host's LEFT comes back. Nothing is owed - the
      -- wager only exists from BEGIN onwards.
      local me = myName()
      if me then applyLeft(me) end
    end
  end)
  -- shares the host-only Start slot
  ui.withdrawBtn:SetPoint("BOTTOMLEFT", inset, foot)
  ui.ledgerBtn = PG.UI.Button(win, "Open Ledger", btnW, btnH, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ui.ledgerBtn:SetPoint("BOTTOM", 0, foot)

  if Theme then
    npc = Theme.NPC(win, "bookie")
    if npc and npc.frame then
      -- decoration, so it yields: sized and cornered clear of the text column
      npc.frame:SetSize(NPC_W, NPC_H)
      npc.frame:SetPoint("TOPRIGHT", NPC_RIGHT, NPC_TOP)
    end
    win.__pgBannerSlot = rowAt(1)
  end
end

-- One entry: there is no other audience this game can have.
local SCOPE_HEADER = { group = "Party or raid" }

-- Row order is defined and identical on every client: the living, in turn order
-- from the current seat (so "who is next" reads at a glance), then the
-- eliminated in reverse elimination order (most recent first).
local function rosterLines(S, me)
  local out = {}
  local n = #S.roster
  local seat = S.turnIdx
  local order = {}
  local from = seat and (seat - 1) or nil
  local i = nextLivingIn(n, S.alive, from, S.first)
  local guard = 0
  while i and guard < n do
    guard = guard + 1
    order[#order + 1] = i
    if guard >= (S.nAlive or 0) then break end
    i = nextLivingIn(n, S.alive, i, S.first)
  end
  for k = 1, #order do
    local idx = order[k]
    local name = S.roster[idx]
    local line = name .. ((name == me) and (P.chgold .. " (you)|r") or "")
    if idx == seat and S.turnOpen then
      line = (Theme and (Theme.Mark("dice") .. " ") or "> ") .. line .. "  -  to roll"
    elseif S.lastRoll and S.lastRoll.idx == idx then
      line = line .. "  -  rolled " .. S.lastRoll.value
    end
    out[#out + 1] = line
  end
  for k = #S.outOrder, 1, -1 do
    local idx = S.outOrder[k]
    local name = S.roster[idx]
    if name then
      local w = S.outWhy[idx]
      local how = "OUT"
      if w == 0 then how = "OUT (no roll)" elseif w == 1 then how = "OUT (rolled 1)" end
      out[#out + 1] = P.chgray .. name .. "  -  " .. how .. "|r"
    end
  end
  return out
end

RefreshUI = function()
  local S = mySession()
  if not win or not S then return end
  if win.__pgRec and win.__pgRec ~= S then return end
  local now = GetTime()
  local me = myName()
  local isJoin = S.phase == "join"
  local isPlay = S.phase == "play"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false
  local myIdx = me and rosterIndex(S, me) or nil
  local myTurn = (isPlay and S.turnOpen and myIdx and myIdx == S.turnIdx) and true or false

  ui.aud:SetText(SCOPE_HEADER[S.scope] or "")

  if isJoin then
    local second = #S.roster .. " in - starting roll 1-" .. S.startCeil
    -- CONCURRENCY.md 6.3: nobody replies "busy", so the host is at least shown
    -- how many addon users are in earshot. PG.Peers is a group-scope fact and
    -- is pruned against the live group by Core.
    if S.isHost and PG.Peers then
      local peers = 0
      for _ in pairs(PG.Peers) do peers = peers + 1 end
      if peers > 0 then
        second = #S.roster .. " of " .. (peers + 1) .. " addon users have joined"
      end
    end
    ui.info:SetText("Wager " .. tmoney(S.wager) .. " a head - pot "
      .. PG.Money(S.wager * math.max(0, #S.roster - 1)) .. " if it fills|n" .. second)
  elseif isPlay then
    ui.info:SetText("Wager " .. tmoney(S.wager) .. " - pot "
      .. PG.Money(S.wager * math.max(0, (S.count or #S.roster) - (S.nAlive or 0)))
      .. "|n" .. (S.nAlive or 0) .. " of " .. (S.count or #S.roster) .. " still in")
  else
    ui.info:SetText(S.endText or "Game over.")
  end

  if isPlay and S.ceil then
    ui.ceil:SetText((S.turnOpen and "ROLL " or "") .. "1 - " .. S.ceil)
  elseif isDone and S.winIdx and S.roster[S.winIdx] then
    ui.ceil:SetText(shortOf(S.roster[S.winIdx]) .. " WINS")
  else
    ui.ceil:SetText("-")
  end

  local turnText = ""
  if isJoin then
    if S.isHost then
      local remaining = S.joinFrozen and (S.joinRemaining or 0)
        or math.max(0, (S.joinDeadline or now) - now)
      turnText = "Entries close in " .. math.ceil(remaining) .. "s"
        .. (S.joinFrozen and " (paused)" or "")
    else
      turnText = "Waiting for the host to start"
    end
  elseif isPlay then
    if S.spectator then
      turnText = S.syncDead and "Spectating - too far out of sync to catch up."
        -- shortened to fit the one status line at the content width: the old
        -- 63-character form measured past it and lost its own last word
        or "Out of sync - watch chat; the host is still counting you."
    elseif S.frozen then
      turnText = "Paused - the raid needs the screen. This turn resumes after."
    elseif myTurn and S.selfRoll and S.selfRoll.seq == S.seq then
      turnText = "You rolled " .. S.selfRoll.value .. " - waiting for the host."
    elseif S.turnOpen and S.turnIdx and S.roster[S.turnIdx] then
      turnText = myTurn and (P.chgold .. "YOUR TURN|r")
        or (shortOf(S.roster[S.turnIdx]) .. " to roll")
    elseif S.lastRoll and S.roster[S.lastRoll.idx] then
      local nm = shortOf(S.roster[S.lastRoll.idx])
      if S.lastRoll.value == 0 then
        turnText = nm .. " ran out of time - out."
      elseif S.lastRoll.value == 1 then
        turnText = nm .. " rolled a 1 - out."
      else
        turnText = nm .. " rolled " .. S.lastRoll.value .. "."
      end
    else
      turnText = "Get ready..."
    end
  elseif S.disputed then
    turnText = P.chred .. "Result disputed - nothing recorded.|r"
  end
  ui.turn:SetText(turnText)

  -- The button is a convenience and never a dependency. PG.Rolls.Available() is
  -- a live query - it reports the safety gate as well as the API - so the button
  -- appears and disappears with the gate instead of latching off on one refusal.
  local rolled = (S.selfRoll and S.selfRoll.seq == S.seq) and true or false
  local canRoll = myTurn and not S.spectator and S.seated and not S.frozen
    and not rolled and rollsAvailable() and true or false

  -- The typed path is NEVER hidden behind a failure: whenever it is this
  -- player's turn the exact command is on screen, button or no button.
  local hint = ""
  if myTurn and not S.spectator and S.seated then
    if rolled then
      hint = "If the host doesn't pick it up, type /roll " .. S.ceil .. " again."
    elseif canRoll then
      hint = "...or type /roll " .. S.ceil .. " in chat."
    else
      hint = "Type /roll " .. S.ceil .. " in chat - this client can't roll for you."
    end
  elseif isDone and S.disputed then
    -- The one line that tells a player how to settle a money dispute, so it may
    -- not be the line that truncates: shortened to fit the content width.
    hint = "Scroll up - every roll is in your chat log, as the server printed it."
  end
  ui.hint:SetText(hint)

  -- emptyText goes to the centred ui.empty, never into roster row 1: an empty
  -- state is not list item zero. One string across all six games (PLAN 4).
  local lines, emptyText
  if isJoin then
    lines = {}
    for _, name in ipairs(S.roster) do
      lines[#lines + 1] = name .. ((name == me) and (P.chgold .. " (you)|r") or "")
    end
    if #lines == 0 then emptyText = "Nobody has joined yet." end
  elseif S.spectator then
    lines = {}
    emptyText = "Out of sync - the roster is shown once the host resyncs you."
  else
    lines = rosterLines(S, me)
    if isDone and S.ended and S.winIdx and not S.disputed and not S.missed then
      local pot = S.wager * math.max(0, #S.roster - 1)
      lines = {}
      for i = 1, #S.roster do
        local name = S.roster[i]
        local tag = (i == S.winIdx)
          and (P.chgreen .. "  -  WINNER  +" .. PG.Money(pot) .. "|r")
          or (P.chred .. "  -  -" .. PG.Money(S.wager) .. "|r")
        lines[#lines + 1] = name .. ((name == me) and (P.chgold .. " (you)|r") or "") .. tag
      end
    end
  end
  if S.refereed then
    table.insert(lines, 1, P.chgray .. shortOf(S.host) .. " (running the game)|r")
    -- the referee line occupies the band, so the notice is no longer the only
    -- thing on screen and goes back into the list where it reads as one
    if emptyText then
      lines[2] = P.chgray .. emptyText .. "|r"
      emptyText = nil
    end
  end
  -- The local player's row is the one row the collapse may not eat: when it
  -- falls past the cut it is lifted into the last visible slot, the same rule
  -- the reveal stage applies to its own rows.
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

  if isDone and S.disputed then
    -- BRIEF 2: the mirror stays on screen so the player can see BOTH answers
    -- and go read the chat log, which is the actual evidence.
    -- "no winner", not "a different outcome": the long form measured past the
    -- content width and dropped the host's name, which is half the sentence.
    local ours = S.derived and S.roster[S.derived]
    ui.mine:SetText(P.chred .. "This client saw "
      .. (ours and shortOf(ours) or "no winner")
      .. "; the host said " .. shortOf(S.roster[S.winIdx or 0] or "?") .. ".|r")
  elseif S.refereed then
    ui.mine:SetText(P.chgray .. "You have no stake in this game - you're running it.|r")
  elseif S.spectator then
    ui.mine:SetText(P.chgray .. "No stake this game (spectating).|r")
  elseif isJoin and inRoster then
    ui.mine:SetText("You are in for " .. P.chgold .. PG.Money(S.wager) .. "|r.")
  elseif isPlay and inRoster then
    if myIdx and S.alive[myIdx] then
      ui.mine:SetText("You're still in - pot "
        .. PG.Money(S.wager * math.max(0, (S.count or 0) - (S.nAlive or 0))) .. ".")
    else
      ui.mine:SetText(P.chred .. "You're out - you owe " .. PG.Money(S.wager) .. ".|r")
    end
  elseif isDone then
    ui.mine:SetText(S.endText or "")
  else
    ui.mine:SetText(P.chgray .. "You have no stake in this game.|r")
  end

  ui.rollBtn:SetShown(canRoll)
  -- SetText works on both CardButton shapes (themed card face and the plain
  -- UIPanelButtonTemplate fallback), so the label is rebuilt from the live
  -- ceiling without branching on which one rendered.
  if canRoll then ui.rollBtn:SetText("ROLL 1-" .. S.ceil) end
  ui.startBtn:SetShown(isJoin and S.isHost)
  -- No live Cancel while END is queued or sent: hostCancel refuses there (the
  -- ledger is already committed to), so the affordance would silently lie.
  ui.cancelBtn:SetShown(S.isHost and not isDone and not (S.endPending or S.endSent))
  ui.withdrawBtn:SetShown((isJoin and not S.isHost and S.joinAccepted) and true or false)
  ui.ledgerBtn:SetShown((isDone and S.ended) and true or false)
end

ShowWindow = function()
  local S = mySession()
  if not S then return end
  if not (S.isHost or S.joinAccepted) then return end -- mirrors stay windowless
  local st = PG.Safety.state
  if st.inEncounter or st.readyCheck or st.countdown or st.restricted then return end
  if st.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return end
  ensureWindow()
  win.__pgRec = S
  RefreshUI()
  win:Show()
end

-------------------------------------------------------------------------------
-- Host config dialog
-------------------------------------------------------------------------------

-- The host dialog's own geometry. A left label column against a right-anchored
-- input column, both at the shared inset, so the two edges finally agree (they
-- were 20 and 24).
local DLG_W = 320
local FIELD_W = 70
local function makeField(parent, label, y, default)
  local inset = mt("INSET")
  local fs = parent:CreateFontString(nil, "OVERLAY", ft("T"))
  fs:SetPoint("TOPLEFT", inset, y)
  -- bounded: the label column is what the input column leaves, and no
  -- FontString in this file is allowed to be unbounded
  fs:SetWidth(DLG_W - 2 * inset - FIELD_W - 8)
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

local GAME_NAME = {
  LG = "Loot Goblins", RPS = "Rock Paper Scissors", PB = "The Pull Book",
  DR = "Death Roll", GB = "Gambler", QZ = "Quiz",
}

-- The dialog always opens and Start explains itself (CONCURRENCY.md 0.2).
refreshDialog = function()
  if not dialog then return end
  local note, canStart = "", true
  local S = mySession()
  local seat = PG.Session.Seat()
  if S and S.phase ~= "done" then
    canStart = false
    if S.isHost then
      note = "You're already running a Death Roll game. Cancel it first, or wait for it to finish."
    else
      note = "You're playing " .. shortOf(S.host)
        .. "'s Death Roll game. You can start your own when it's over."
    end
  elseif seat then
    -- seated in another module: Start stays ENABLED (I4/I5) and this is a
    -- statement of what will happen, not a refusal
    note = "You're playing " .. (GAME_NAME[seat.module] or "another game")
      .. ", so you'll run this game without playing in it."
  end
  if canStart and not rollsReady() then
    canStart = false
    note = "This client can't read /roll results, so it can't referee a game."
      .. " You can still join somebody else's."
  end
  local scope = dlgScope and dlgScope:Get()
  if canStart and not scope then
    canStart = false
    note = "Nowhere to start a game: you're not in a party or raid."
  end
  if note == "" then
    note = "Only players running Pengyou Games can join. Everyone else in the group"
      .. " will see the rolls in chat, but they are not in the game."
  end
  if dlgNote then dlgNote:SetText(note) end
  if dlgOpen then
    dlgOpen.__pgWhy = (not canStart) and note or nil
    dlgOpen:SetEnabled(canStart)
  end
end

local function ensureDialog()
  if dialog then return end
  -- 344, not 320: PG.UI.ScopePicker is 58 tall now (its fallback hint used to
  -- render 13px OUTSIDE the rect it declared), and the note under it has to
  -- clear the Open button with all three of its lines showing.
  dialog = PG.UI.Window("drdialog", "Start Death Roll", DLG_W, 344, "DR")
  dlgInputs = {
    wager = makeField(dialog, "Wager (gold)", -56, 100),
    ceil0 = makeField(dialog, "Starting roll", -88, 100),
    joinSecs = makeField(dialog, "Join window (sec)", -120, 45),
    turnSecs = makeField(dialog, "Turn timer (sec)", -152, 30),
  }
  -- "Default: the wager amount" without ever fighting a deliberate choice - the
  -- mirror stops the moment the user touches the ceiling box themselves.
  -- HookScript, never SetScript: InputBoxTemplate installs its own
  -- OnTextChanged and replacing it breaks the template's own behaviour.
  dlgInputs.ceil0:HookScript("OnTextChanged", function(self, userInput)
    if userInput then self.__pgTouched = true end
  end)
  dlgInputs.wager:HookScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local ceilBox = dlgInputs.ceil0
    if ceilBox.__pgTouched then return end
    local n = tonumber(self:GetText())
    if not n then return end
    n = math.floor(n)
    if n < MIN_CEIL then n = MIN_CEIL elseif n > MAX_CEIL then n = MAX_CEIL end
    ceilBox:SetText(tostring(n))
  end)

  -- Every segment renders at every moment; Guild and Public are permanently
  -- greyed and carry the answer to "why not" on hover (SCOPE.md 5.3).
  dlgScope = PG.UI.ScopePicker(dialog, {
    key = "DR",
    allowed = PG.DR.SCOPES,
    reasons = function(scope)
      if scope == "group" then return nil end
      return WIDE_SCOPE_REASON
    end,
    onChange = function() refreshDialog() end,
  })
  dlgScope:SetPoint("TOPLEFT", dialog, "TOPLEFT", 0, -184)
  dlgScope:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", 0, -184)

  -- Anchored to the picker's own bottom, not to an absolute offset that has to
  -- be re-guessed every time the control changes height.
  dlgNote = dialog:CreateFontString(nil, "OVERLAY", ft("S"))
  dlgNote:SetPoint("TOPLEFT", dlgScope, "BOTTOMLEFT", mt("INSET"), -8)
  dlgNote:SetPoint("TOPRIGHT", dlgScope, "BOTTOMRIGHT", -mt("INSET"), -8)
  dlgNote:SetJustifyH("LEFT")
  -- TOP, so a one-line note sits where a three-line note starts instead of
  -- floating in the middle of its box (four of the five dialogs did this)
  dlgNote:SetJustifyV("TOP")
  dlgNote:SetHeight(36)
  dlgNote:SetWordWrap(true)
  dlgNote:SetMaxLines(3)
  dlgNote:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(dlgNote) end

  local openLabel = "Open the table"
  if Theme then openLabel = Theme.Mark("dice") .. " Open the table" end
  dlgOpen = PG.UI.Button(dialog, openLabel, 150, 26, function()
    local wager = fieldValue(dlgInputs.wager, MIN_WAGER, MAX_WAGER)
    local ceil0 = fieldValue(dlgInputs.ceil0, MIN_CEIL, MAX_CEIL)
    local joinSecs = fieldValue(dlgInputs.joinSecs, MIN_JOIN, MAX_JOIN)
    local turnSecs = fieldValue(dlgInputs.turnSecs, MIN_TURN, MAX_TURN)
    local scope = dlgScope and dlgScope:Get()
    if not scope then
      toast("Death Roll: nowhere to start a game - you're not in a party or raid.")
      return
    end
    -- Re-checked at the moment Start is pressed: never fall back to another
    -- audience, say why and repaint (SCOPE.md 1.3).
    local ok, why = PG.Comm.ScopeAvailable(scope)
    if not ok then
      toast("Death Roll: " .. (why or "that audience isn't available."))
      dlgScope:Refresh()
      refreshDialog()
      return
    end
    if Theme then Theme.Sound("stamp") end
    dialog:Hide()
    hostOpen(wager, ceil0, joinSecs, turnSecs, scope)
  end)
  dlgOpen:SetPoint("BOTTOM", 0, 18)
  local dlgRules = PG.UI.Button(dialog, "Rules", 60, 22, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("DR") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", 16, 18)
  dlgOpen:SetScript("OnEnter", function(self)
    if not self.__pgWhy then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.__pgWhy, 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  dlgOpen:SetScript("OnLeave", function() GameTooltip:Hide() end)
  dialog:HookScript("OnShow", refreshDialog)
end

-- Launcher / slash entry point. The dialog ALWAYS opens (CONCURRENCY.md 0.2).
function PG.DR.OpenDialog()
  ensureDialog()
  refreshDialog()
  dialog:Show()
end

PG.RegisterInit(function()
  if PG.Theme and PG.Theme.C then
    Theme = PG.Theme
    TC = Theme.C()
    P.chgold, P.chgreen, P.chred, P.chgray = TC.chgold, TC.chgreen, TC.chred, TC.chgray
    P.CHALK, P.CHGOLD, P.CHGRAY = TC.CHALK, TC.CHGOLD, TC.CHGRAY
  end
  PG.Comm.Register("DR", onComm, onDrop)
  PG.Safety.OnChange(onSafetyChange)
  ASK_MAX = PG.UI.ASK_MAX or ASK_MAX

  -- One observer for the module, for the module's whole life (see observeRoll).
  -- Guarded like every other crossing into Rolls.lua: without it there is
  -- nothing to observe, and both doors already refuse.
  if PG.Rolls and PG.Rolls.OnRoll then PG.Rolls.OnRoll("DR", observeRoll) end

  -- Whisper trust (BRIEF 4.2). Group scope only, so Comm's own roster test is
  -- the entire proof and already admits every legitimate whisperer; a module
  -- predicate here could only ever open the door wider. The Pull Book's shape.
  if PG.Comm.RegisterTrust then
    PG.Comm.RegisterTrust("DR", function() return false end)
  end

  -- Accepting one invitation withdraws the rest (CONCURRENCY.md 5.6 rule 3).
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
