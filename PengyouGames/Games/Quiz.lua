-- Games/Quiz.lua - four quiz modes (Trivia, Two Truths & a Lie, Unscramble,
-- Type Race) ported from Pengyou's Chat Games into the PengyouGames session
-- architecture as ONE game with four question kinds.
--
-- POINTS ONLY, ZERO GOLD. I11: this file makes zero CALLS into the ledger,
-- permanently. Check it with
--     grep -n 'PG\.Ledger\.' PengyouGames/Games/Quiz.lua
-- and not with a search for the bare word, for the reason CONCURRENCY.md I10
-- gives about the seat: the comment that documents an invariant contains the
-- name itself, so a bare-name grep can never come back empty and stops being a
-- check at all. (The escaped form above is deliberate too - it is the pattern
-- that does not match its own documentation.) Every gold concept is absent by
-- construction: no buy-in, no pot, no dust, no settlement, no rows, no meta.
-- Points, a local medal tally and a name-free personal counter are the entire
-- persisted trace, which is what lets PG.QZ.SCOPES open guild and public
-- (SCOPE.md 1.2): nothing is ever owed, so there is nothing for a stranger to
-- cheat you out of.
--
-- Structurally this is RockPaperScissors.lua: one full record plus bounded lite
-- records keyed (host, token), the single seat, host/client mirror, resync,
-- safety freezes, medals in db.qz. Read that file first; everything that is not
-- explained here is explained there.
--
-- THE ONE THING THAT IS NOT LIKE RPS: THE WIRE CARRIES INDICES, NOT TEXT.
-- Every client ships an identical Data/QuizData.lua, so a question travels as a
-- mode char plus pool indices and each client renders the prompt from its own
-- copy. Three Two Truths statements are up to 360 bytes of text and would never
-- fit; as three indices they are twelve. Type Race's phrase IS its answer, so
-- broadcasting it would put the answer in every client's message stream.
--
-- HONESTY ABOUT WHAT THAT LEAKS (BRIEF 5.3 B2). A pool-qualified index says
-- which pool a Two Truths statement came from, so anyone reading raw addon
-- traffic - or simply opening QuizData.lua, which every player has - can see
-- which of the three is the lie. There is no merge construction that hides it:
-- the answers must ship in order to render the questions at all, so a modified
-- client always wins. No theatre is spent pretending otherwise. The requirement
-- that IS met, and that matters, is that the SHIPPED client never displays an
-- answer before the reveal: applyQuestion stores only wire fields, and every
-- reveal string is computed in applyResult.
--
-- BECAUSE INDICES ARE MEANINGLESS AGAINST A DIFFERENT BANK, PG.QuizData.VERSION
-- rides on OPEN and a client whose bank disagrees refuses to construct any
-- state at all. QuizData.lua is therefore a protocol artefact, not content that
-- can be patched casually: any edit to it must bump VERSION.
--
-- FAIRNESS (BRIEF 5.3). Answers are WHISPERED, so raw arrival order at the host
-- is partly network luck. The window is fixed and everyone correct scores:
-- first correct 3, second 2, every other correct answer 1. Each client measures
-- its own elapsed time from the moment IT rendered the question and reports it;
-- the host clamps that report to at most MAX_CREDIT seconds of credit against
-- its own observation, so no cross-machine clock is ever compared and a liar
-- cannot beat someone who genuinely answered more than three seconds earlier.
--
-- ZERO PUBLIC CHAT. Answers are typed into this window and sent as addon
-- WHISPERs (SCOPE.md 2.3). Nothing here ever calls SendChatMessage.
local ADDON, PG = ...

PG.QZ = {}

local TICK = 0.5            -- master ticker period (drives all session timing)
local HB_INTERVAL = 10      -- host heartbeat cadence
local HB_TIMEOUT = 35       -- client, group scope: host is dead after this silence
-- Wide scope (SCOPE.md 6.2): host and clients are not in the same content by
-- definition, so 35s of silence is a paused game, not a dead host.
local HB_QUIET_WIDE = 150
local HB_GIVEUP_WIDE = 300
local QUIET_SYNC_EVERY = 60 -- at most one heal request per minute while quiet
local REVEAL_SECS = 6       -- pause between RESULT and the next question
local VOID_PAUSE_SECS = 3   -- pause between VOID and the replayed round
local BEGIN_PAUSE_SECS = 2  -- pause between BEGIN and question 1
local MIN_REOPEN_SECS = 5   -- floor for the timer when re-opening a frozen question
local MAX_ROWS = 9
local MAX_ROUNDS = 9
local ROSTER_CAP = 40
local SYNC_COOLDOWN = 10    -- min secs between SYNCQ handling per sender
local SYNC_MAX_REPLAY = 20  -- resync deltas above this many messages -> SYNCNO

-- Concurrency budgets (CONCURRENCY.md 2.1), identical to RPS.
local MAX_LITE = 8
local MAX_RECENT = 16
local RECENT_TTL = 120
local DONE_TTL = 60
local LITE_TTL_PAD = 10
local LITE_TTL_MIN = 15
local LITE_TTL_MAX = 180
local SWEEP_EVERY = 4
local BUSY_THROTTLE = 60
local VER_TOAST_THROTTLE = 60

-- Answer limits. ANS_MAX is load-bearing and is enforced THREE times: the edit
-- box SetMaxLetters, a client-side refusal after normalization, and a host-side
-- alphabet/length test on the received field. It is what makes the byte budget
-- provable (ANS worst case 104 bytes with a pathological 24-char token) and
-- what stops a free-text field from ever being unbounded.
local ANS_MAX = 64
-- No pool entry whose answer normalizes longer than this is ever drawn: a data
-- bug must not make a round unwinnable. Today's longest Type Race phrase
-- normalizes to 58 characters.
local ANS_NORM_MAX = 60
local MIN_ANSWER_SECS = 10
local MAX_ANSWER_SECS = 60
-- Seconds of speed credit a client's self-reported elapsed time can buy it
-- against the host's own observation. Small enough that a liar cannot beat an
-- honest player who answered more than this much earlier, large enough that
-- ordinary cross-realm latency (well under a second each way) never bites.
local MAX_CREDIT = 3.0
local HINT_AT = 0.5         -- hints appear at the halfway mark of the window

-- BRIEF 5.3: fixed window, everyone correct scores, value steps down by arrival
-- rank. This rewards speed without making a laggy player unable to score, and
-- it removes the incentive to blame the network.
local POINTS = { ["1"] = 3, ["2"] = 2, C = 1, W = 0, X = 0 }
local MODE_BIT = { T = 1, L = 2, U = 4, R = 8 }
local MODE_ORDER = { "T", "L", "U", "R" }
local MODE_NAME = { T = "Trivia", L = "Two Truths & a Lie",
                    U = "Unscramble", R = "Type Race" }
local VALID_MODE = { T = true, L = true, U = true, R = true }
local SLOT_LETTER = { "A", "B", "C" }

-- SCOPE.md 1.2 / SCOPE.md 4.3: points only, so Quiz is permitted on every
-- audience. Declared here and read by the picker, by Rules.lua's scopeBlocks
-- (which reads PG[key].SCOPES generically) and by the OPEN handler, which drops
-- any scope absent from this table.
PG.QZ.SCOPES = { group = true, guild = true, public = true }
-- BRIEF 1.1: the launcher's blockedBy() reads a declared per-module seat flag
-- instead of special-casing The Pull Book. Quiz demands a timed decision from a
-- human, so it consumes the seat exactly as RPS does despite being points-only.
PG.QZ.SEAT = true

local MODULE_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors",
                      PB = "The Pull Book", DR = "Death Roll",
                      GB = "Gambler", QZ = "Quiz" }

-- podium colors (literal, final standings places 1/2/3)
local PODIUM = { "|cffffd700", "|cffc0c0c0", "|cffcd7f32" }

-- Faire palette, literal spec values; refreshed from PG.Theme.C at init when
-- the theme layer is present (the values are identical). Presentation only.
local P = {
  chgold = "|cffffd876", chgreen = "|cff7deda4", chred = "|cffff8a70",
  chgray = "|cffa8a89c",
  CHALK = { 0.95, 0.93, 0.87 }, CHGOLD = { 1.00, 0.85, 0.46 },
  CHGRAY = { 0.66, 0.66, 0.61 }, BRASS = { 0.80, 0.68, 0.42 },
}

-------------------------------------------------------------------------------
-- The session registry (CONCURRENCY.md 2.1). Byte-for-byte the RPS model: one
-- FULL record (the session we host or sit in) plus bounded LITE records for
-- sessions we merely overhear. Identity is the PAIR (host, token), never the
-- token alone (3.2).
-------------------------------------------------------------------------------

local sessions = {}   -- [key] = record, key = host .. "|" .. token
local mine            -- key of the ONE full record (hosted or seated), or nil
local recent = {}     -- [key] = GetTime() when it died; replay defence
local recentQ = {}    -- FIFO of poisoned keys, capped at MAX_RECENT
local regCount = 0    -- #sessions, kept incrementally (pairs() is never counted)
local liteCount = 0   -- lite records among them
local sweepTicks = 0

local ticker
local win, dialog, dlgInputs, dlgScope, dlgNote, dlgStart, dlgChecks
local ui = {}
local rows = {}
local Theme           -- PG.Theme (nil if the theme layer is absent)

-- invitation throttles, all bounded (the guild budget itself is in Widgets)
local busyToastAt, busyPending = 0, 0
local overflowToastAt = 0
local verToastAt = 0

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt, hostOpen, clientRequestSync
local evict, endSession, refreshDialog, doSubmit
-- FX are namespaced rather than named individually for the same reason Bank is
-- below: a Lua chunk may hold at most 200 locals and this file is dense with
-- both constants and small helpers. Grouping also draws the line the reader
-- wants drawn - everything under FX is decoration behind runFX and can be
-- deleted without changing a single outcome.
local FX = {}

local function keyOf(host, token) return host .. "|" .. token end

-- The one full record, or nil. Every function below opens with this.
local function mySession() return mine and sessions[mine] or nil end

local function myName() return PG.FullName("player") end

local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

-- wire-field validation: non-secret, numeric, floored, in [lo, hi]; else nil
local function num(v, lo, hi)
  local n = PG.SafeNum(v)
  if not n then return nil end
  n = math.floor(n)
  if lo and n < lo then return nil end
  if hi and n > hi then return nil end
  return n
end

-- RESULT pattern: one char per participant in sorted-roster order. Without this
-- a malformed or hostile RESULT reaches POINTS[c] == nil and errors inside the
-- RefreshUI path mid-raid (critique-1 C3). Same shape as RPS's validPattern.
local function validPattern(p)
  if type(p) ~= "string" or #p < 1 or #p > ROSTER_CAP then return false end
  for i = 1, #p do
    local c = p:sub(i, i)
    if c ~= "1" and c ~= "2" and c ~= "C" and c ~= "W" and c ~= "X" then
      return false
    end
  end
  return true
end

-- Roster agreement fingerprint, copied verbatim from RockPaperScissors.lua
-- (BRIEF 4.1). RESULT patterns are positional over the sorted roster and no
-- name ever travels with an outcome, so a mirror with the right SIZE but the
-- wrong MEMBERS would score - and persist medals for - the wrong players with
-- no error anywhere, which a count comparison cannot see. Bytes are weighted by
-- position inside a name (so anagrams differ) and names by position in the list
-- (so a swap is caught).
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

local function isDigest(v)
  return type(v) == "string" and v:match("^%x%x%x%x$") ~= nil
end

local function allClear()
  -- Plain combat is deliberately absent: it neither blocks addon sends nor
  -- pauses the game (0.4.0 doctrine). Only an encounter, a ready check, a pull
  -- countdown or an addon restriction gates game progression.
  local s = PG.Safety.state
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

local function live()
  local S = mySession()
  return S ~= nil and S.phase ~= "done"
end

-- The toast mark. Theme.Mark returns "" for a key with no ASSETS entry, so
-- asking for "quiz" first and falling back to the shipped "ticket" mark means
-- this file is correct both before and after Theme.lua gains its own entry -
-- Theme.lua is not ours to edit here.
local function quizMark()
  if not Theme then return "" end
  local m = Theme.Mark("quiz")
  if m == "" then m = Theme.Mark("ticket") end
  return m
end

-- Attribution (CONCURRENCY.md 5.7): once more than one session is known, a bare
-- "Quiz: ..." cannot tell a player in two audiences WHICH game the line is
-- about, so the host's name rides along.
local function toast(text, host, opts)
  local name = "Quiz"
  if host and regCount > 1 then name = name .. " (" .. shortOf(host) .. ")" end
  local line = name .. ": " .. text
  local m = quizMark()
  if m ~= "" then line = m .. " " .. line end
  PG.UI.Toast(line, opts)
end

-- FX runner: decoration only - errors are reported and swallowed, so no
-- animation/sound problem can ever touch game state or the wire.
local function runFX(fn, arg)
  if not Theme or not fn then return end
  local ok, err = pcall(fn, arg)
  if not ok then geterrorhandler()(err) end
end

-- Every send carries the session's own scope (SCOPE.md 2.2). Only the involved
-- record ever broadcasts - a lite record has nothing to say and never consumes
-- a token from the shared 10-token bucket.
local function broadcast(mtype, ...)
  local S = mySession()
  if not S then return false end
  return PG.Comm.Broadcast(S.scope, "QZ", mtype, S.token, ...)
end

local function startTicker()
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

local function syncTicker()
  if regCount > 0 then startTicker() else stopTicker() end
end

-------------------------------------------------------------------------------
-- THE ANSWER LAYER. Transcribed from Pengyou's Chat Games with the semantics
-- preserved exactly, including the DELIBERATE REFUSAL TO ACCEPT FRAGMENTS.
--
-- Matches' three clauses look redundant to a reader who has not seen the bug
-- reports behind them:
--   * compact equality accepts "yoggsaron" for "Yogg-Saron";
--   * whole-word containment accepts "i think it's molten core";
--   * the numeric frontier clause accepts "level 60" for the answer "60" while
--     still rejecting "600".
-- What is NOT there is a substring fallback, and its absence is the point:
-- "core" must never score "Molten Core" and "mountain" must never score
-- "Blackrock Mountain". Loosening any one of the three turns the game into free
-- points. Do not "improve" this.
--
-- Everything from here to the end of the QUESTION BANK section hangs off one
-- local table. That is partly Lua's 200-locals-per-chunk ceiling, which this
-- file would otherwise blow through, and partly the right boundary anyway:
-- nothing under Bank touches session state, the wire or the UI, so it can be
-- read and reasoned about entirely on its own.
-------------------------------------------------------------------------------

local Bank = {}

-- Lowercase, strip punctuation, collapse whitespace: "Yogg-Saron!" -> "yoggsaron",
-- "Molten  Core," -> "molten core". Applied to BOTH sides of every comparison,
-- so it is an equivalence relation on answers and not a transformation of one
-- side only.
--
-- The second gsub is an addition, not a semantic change: %w is locale-dependent
-- in principle, and the ANS wire field is contractually [a-z0-9 ] so that it can
-- never contain "|" (which would corrupt strsplit), never exceed ANS_MAX bytes
-- and never carry a secret. QuizData.lua is ASCII-only, so on a C-locale client
-- this line is provably a no-op on every answer in the bank; it only bites on
-- exotic input a broken client might type.
function Bank.normalize(text)
  text = tostring(text or ""):lower()
  text = text:gsub("[^%w%s]", "")
  text = text:gsub("[^a-z0-9%s]", "")
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

-- Normalize with ALL whitespace removed: "death knight" -> "deathknight".
function Bank.compact(text)
  return (Bank.normalize(text):gsub("%s+", ""))
end

function Bank.matches(input, inputCompact, answer)
  local a = Bank.normalize(answer)
  local aCompact = Bank.compact(answer)
  if aCompact == "" then return false end

  if inputCompact == aCompact then
    return true
  end

  -- Whole-word boundaries make this safe even for short answers ("shaman" can
  -- never match " sha "). Plain find, so the answer is never a pattern.
  if (" " .. input .. " "):find(" " .. a .. " ", 1, true) then
    return true
  end

  -- %f[set] is Lua 5.1's frontier pattern. It is present in WoW's Lua and is
  -- the first use of it in this addon, so: it matches the empty transition into
  -- the set, i.e. "the digits of `a` bounded by non-digits". That is what makes
  -- "level 60" score for the answer "60" while "600" does not. It is undocumented
  -- in the 5.1 manual and invisible to luac -p, so this comment is the notice
  -- that it is deliberate and not a typo. `a` is all digits here, so it can
  -- carry no magic characters of its own.
  if a:match("^%d+$") and input:match("%f[%d]" .. a .. "%f[%D]") then
    return true
  end

  return false
end

-------------------------------------------------------------------------------
-- THE QUESTION BANK. Data/QuizData.lua is authoritative and is not reshaped
-- here; these accessors bend to its four table shapes:
--   PG.QuizData.TypeRace   = { { word = "phrase to type" }, ... }
--   PG.QuizData.Unscramble = { { word = "answer", scrambled = "JUMBLE"? }, ... }
--   PG.QuizData.Trivia     = { { q = "...", a = "...", alt = { "..." }? }, ... }
--   PG.QuizData.TwoTruths  = { truths = { "..." }, lies = { "..." } }
-- There is no multiple choice anywhere: three of the four modes require typing
-- and Trivia is free text matched against `a` plus the `alt` list.
-------------------------------------------------------------------------------

-- Usable ABSOLUTE indices per pool, computed once at init (see the init block).
-- "LT" and "LL" are the Two Truths truth and lie pools; they are separate
-- arrays in the data file and are kept separate here.
Bank.usable = { T = {}, U = {}, R = {}, LT = {}, LL = {} }
Bank.ready = false

function Bank.dataVersion()
  local D = PG.QuizData
  local v = D and PG.SafeNum(D.VERSION)
  if not v then return nil end
  v = math.floor(v)
  if v < 0 or v > 9999 then return nil end
  return v
end

function Bank.poolOf(m)
  local D = PG.QuizData
  if type(D) ~= "table" then return nil end
  if m == "T" then return D.Trivia end
  if m == "U" then return D.Unscramble end
  if m == "R" then return D.TypeRace end
  return nil
end

function Bank.twoTruthsPool(which)
  local D = PG.QuizData
  local tt = (type(D) == "table") and D.TwoTruths or nil
  if type(tt) ~= "table" then return nil end
  local p = (which == "T") and tt.truths or tt.lies
  return (type(p) == "table") and p or nil
end

-- A pool entry is usable only if a player could actually win the round with it:
-- the prompt renders, the answer is non-empty after normalization, and the
-- answer fits inside the ANS field the player has to type it into.
function Bank.usableTrivia(e)
  if type(e) ~= "table" then return false end
  if type(e.q) ~= "string" or e.q == "" then return false end
  if type(e.a) ~= "string" then return false end
  local a = Bank.normalize(e.a)
  return a ~= "" and #a <= ANS_NORM_MAX
end

function Bank.usableWord(e)
  if type(e) ~= "table" then return false end
  if type(e.word) ~= "string" then return false end
  local a = Bank.normalize(e.word)
  return a ~= "" and #a <= ANS_NORM_MAX
end

function Bank.usableStatement(s)
  return type(s) == "string" and s ~= ""
end

-- Cheap availability test used by the dialog and by hostOpen. A mode with no
-- usable entry can never serve a question, so offering it would open a session
-- that stalls on its first round.
function Bank.modeReady(m)
  if not Bank.ready then return false end
  if m == "L" then return #Bank.usable.LT >= 2 and #Bank.usable.LL >= 1 end
  local list = Bank.usable[m]
  return list ~= nil and #list >= 1
end

-------------------------------------------------------------------------------
-- The scramble. Every client MUST derive the IDENTICAL jumble from the wire, or
-- players are solving different puzzles - so math.random is never used here: it
-- is seeded per client and its sequence is not reproducible anywhere else.
--
-- Park-Miller minimal standard, s = (s * 16807) mod 2147483647. The largest
-- product is 16807 * 2147483646 = 3.6e13, well inside 2^53, so every step is
-- exact in a double on every client and platform. The seed derivation and the
-- swap schedule are both pinned below because "the same LCG" is not enough to
-- guarantee two implementations agree (critique-1 C7).
-------------------------------------------------------------------------------

function Bank.scrambleWord(word, seed)
  local M = 2147483647
  -- A word that cannot produce a different arrangement is shown as-is (the
  -- source addon's rule).
  local distinct = false
  local first = word:sub(1, 1):lower()
  for i = 2, #word do
    if word:sub(i, i):lower() ~= first then distinct = true break end
  end
  if #word < 3 or not distinct then return word end
  local chars = {}
  for i = 1, #word do chars[i] = word:sub(i, i) end
  -- 65535 * 7919 + 40 * 104729 is about 5.2e8: no precision concern, and the
  -- +1 keeps s inside [1, M-1] where the generator is a full-period permutation
  -- (s == 0 is the generator's fixed point and would return the word unshuffled).
  local s = (seed * 7919 + #word * 104729) % (M - 1) + 1
  local out = word
  -- Bounded retries instead of unbounded recursion: a pathological word cannot
  -- stack-overflow, we just accept the last shuffle.
  for _ = 1, 8 do
    for i = #chars, 2, -1 do
      s = (s * 16807) % M
      local j = (s % i) + 1
      chars[i], chars[j] = chars[j], chars[i]
    end
    out = table.concat(chars)
    if out:lower() ~= word:lower() then break end
  end
  return out
end

-------------------------------------------------------------------------------
-- Wire slot encoding. For T/U/R the question is one index and slots b/c are
-- unused ("0"). For L the three slots are POOL-QUALIFIED indices in DISPLAY
-- order - "T12", "L47", "T88" - which is what the header says openly reveals
-- the lie to anyone reading the traffic or the data file.
-------------------------------------------------------------------------------

function Bank.parseSlot(v)
  local s = PG.SafeStr(v)
  if not s or #s < 2 or #s > 8 then return nil end
  local pool, n = s:match("^([TL])(%d+)$")
  if not pool then return nil end
  local idx = tonumber(n)
  if not idx or idx < 1 or idx > 99999 then return nil end
  return pool, math.floor(idx)
end

-- Shape validation only (wire hygiene). Whether an index EXISTS is a question
-- about this client's own bank and is answered in resolveQuestion, whose
-- failure is the dataBad path rather than a dropped message: a client with a
-- divergent bank keeps its mirror and its standings (patterns are positional,
-- not textual) and simply cannot answer.
function Bank.validSlotField(v, mode)
  local s = PG.SafeStr(v)
  if not s or s == "" or #s > 8 then return nil end
  if mode == "L" then
    if not s:match("^[TL]%d+$") then return nil end
    return s
  end
  if not s:match("^%d+$") then return nil end
  return s
end

-- Resolves the live question against THIS client's bank. Returns a view table,
-- or nil when any index is missing (which is exactly the divergent-bank case).
-- Pure read: it never writes to S.
function Bank.resolveQuestion(q)
  if type(q) ~= "table" then return nil end
  local m = q.m
  if m == "L" then
    local truths, lies = Bank.twoTruthsPool("T"), Bank.twoTruthsPool("L")
    if not truths or not lies then return nil end
    local raw = { q.a, q.b, q.c }
    local slots, lie = {}, nil
    for i = 1, 3 do
      local pool, idx = Bank.parseSlot(raw[i])
      if not pool then return nil end
      local src = (pool == "T") and truths or lies
      local text = src[idx]
      if not Bank.usableStatement(text) then return nil end
      slots[i] = { pool = pool, idx = idx, text = text }
      if pool == "L" then
        if lie then return nil end -- two lies is a malformed question
        lie = i
      end
    end
    if not lie then return nil end
    -- distinctness: the same statement in two slots would make the round
    -- unanswerable and can only come from a broken or hostile host
    for i = 1, 3 do
      for k = i + 1, 3 do
        if slots[i].pool == slots[k].pool and slots[i].idx == slots[k].idx then
          return nil
        end
      end
    end
    return { m = "L", slots = slots, lie = lie }
  end
  local pool = Bank.poolOf(m)
  if type(pool) ~= "table" then return nil end
  local idx = tonumber(PG.SafeStr(q.a) or "")
  if not idx then return nil end
  idx = math.floor(idx)
  local e = pool[idx]
  if m == "T" then
    if not Bank.usableTrivia(e) then return nil end
  else
    if not Bank.usableWord(e) then return nil end
  end
  return { m = m, idx = idx, entry = e }
end

-- The scrambled string for a resolved Unscramble question: the data file's
-- fixed override when it has one (that is how "ROGUE" is stopped from being
-- shown as "ROUGE"), else the deterministic jumble.
function Bank.scrambledOf(view, seed)
  local e = view.entry
  local fixed = e.scrambled
  if type(fixed) == "string" and fixed ~= "" then return fixed:upper() end
  return Bank.scrambleWord(e.word, seed):upper()
end

-- The prompt line, rendered LOCALLY from the bank. Never on the wire.
function Bank.promptOf(view, seed)
  if not view then return "" end
  if view.m == "T" then return view.entry.q end
  if view.m == "U" then return "Unscramble:  " .. Bank.scrambledOf(view, seed) end
  if view.m == "R" then return 'Type:  "' .. view.entry.word .. '"' end
  return "Spot the LIE - two of these are true. Type A, B or C."
end

-- The hint, also local, also deterministic on every client (which matters for
-- L: naming a different "true" statement on two screens would be a bug players
-- would read as cheating).
function Bank.hintOf(view, seed)
  if not view then return "" end
  if view.m == "T" then
    local answer = tostring(view.entry.a)
    local n = Bank.normalize(answer)
    local _, wordCount = n:gsub("%S+", "")
    if wordCount < 1 then wordCount = 1 end
    return string.format('Hint: the answer starts with "%s" (%d word%s).',
      answer:sub(1, 1):upper(), wordCount, wordCount == 1 and "" or "s")
  end
  if view.m == "U" then
    local answer = tostring(view.entry.word)
    return string.format('Hint: it starts with "%s" (%d letters).',
      answer:sub(1, 1):upper(), #answer)
  end
  if view.m == "L" then
    -- name one of the two TRUE statements, chosen from the seed so every client
    -- names the same one
    local trueSlots = {}
    for i = 1, 3 do
      if view.slots[i].pool == "T" then trueSlots[#trueSlots + 1] = i end
    end
    if #trueSlots < 1 then return "" end
    local pick = trueSlots[(seed % #trueSlots) + 1]
    return "Hint: statement " .. SLOT_LETTER[pick] .. " is TRUE."
  end
  -- Type Race: the phrase is already on screen, so there is nothing to hint.
  return ""
end

-- The reveal, computed in applyResult and NEVER before: there is no code path
-- where an unmodified client paints the answer during an open window.
function Bank.answerTextOf(view)
  if not view then return "" end
  if view.m == "T" then return "Answer: " .. tostring(view.entry.a) end
  if view.m == "U" then return "Answer: " .. tostring(view.entry.word) end
  if view.m == "R" then return 'The phrase was "' .. tostring(view.entry.word) .. '"' end
  -- the quoted lie is clamped so the reveal line cannot run past its two-line box
  local lie = tostring(view.slots[view.lie].text or "")
  if #lie > 90 then lie = lie:sub(1, 87) .. "..." end
  return SLOT_LETTER[view.lie] .. ' was the lie: "' .. lie .. '"'
end

-- Adjudication. `text` arrives already normalized (the client normalizes before
-- sending and the host re-normalizes, which is idempotent), so every checker
-- below consumes exactly the forms the source addon consumed.
function Bank.checkAnswer(view, text)
  if not view then return false end
  local input = Bank.normalize(text)
  local inputCompact = Bank.compact(text)
  if input == "" then return false end
  if view.m == "T" then
    local e = view.entry
    if Bank.matches(input, inputCompact, e.a) then return true end
    local alts = e.alt
    if type(alts) == "table" then
      for i = 1, #alts do
        if Bank.matches(input, inputCompact, alts[i]) then return true end
      end
    elseif type(alts) == "string" then
      if Bank.matches(input, inputCompact, alts) then return true end
    end
    return false
  end
  if view.m == "U" then
    -- Compact compare so "death knight" matches "Deathknight".
    return inputCompact == Bank.compact(view.entry.word)
  end
  if view.m == "R" then
    -- The source stripped surrounding quotes before comparing, because players
    -- copy the quotes shown in the prompt. Bank.normalize() already deletes every
    -- quote wherever it sits, so that strip is subsumed and its deletion here
    -- is provably a no-op.
    return input == Bank.normalize(view.entry.word)
  end
  -- Two Truths: strict single letter only. Matching "b" inside a sentence would
  -- false-positive on an ordinary sentence, which is why the source anchored it.
  local letter = input:match("^([abc])$")
  if not letter then return false end
  return letter:upper() == SLOT_LETTER[view.lie]
end

-------------------------------------------------------------------------------
-- Registry primitives: identity, poisoning, listing, eviction. RPS's, unchanged.
-------------------------------------------------------------------------------

local function validToken(v)
  local t = PG.SafeStr(v)
  if not t or t == "" or #t > 24 then return nil end
  if t:find("|", 1, true) then return nil end
  return t
end

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

-- BRIEF 1.4: PG.NextToken is real in Core as of 1.1.0, so this is the guard
-- rail and not the mechanism. The local fallback exists only so a build where
-- Core is older than this file still mints a usable token.
local function nextToken()
  if type(PG.NextToken) == "function" then
    local ok, t = pcall(PG.NextToken)
    if ok then
      t = validToken(t)
      if t then return t end
    end
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

local function poison(key)
  if recent[key] then return end
  recent[key] = GetTime()
  recentQ[#recentQ + 1] = key
  while #recentQ > MAX_RECENT do
    local old = table.remove(recentQ, 1)
    if old ~= key then recent[old] = nil end
  end
end

local function isRecent(key)
  local t = recent[key]
  if not t then return false end
  if (GetTime() - t) < RECENT_TTL then return true end
  recent[key] = nil
  return false
end

local function listOpen(rec)
  rec.listed = true
  if PG.Launcher and PG.Launcher.AddOpenGame then
    pcall(PG.Launcher.AddOpenGame, {
      game = "QZ", host = rec.host, token = rec.token, scope = rec.scope,
      expires = rec.expires, key = rec.key,
    })
  end
end

local function unlistOpen(rec)
  if not rec.listed then return end
  rec.listed = false
  if PG.Launcher and PG.Launcher.RemoveOpenGame then
    pcall(PG.Launcher.RemoveOpenGame, "QZ", rec.host, rec.token)
  end
end

local function register(rec)
  sessions[rec.key] = rec
  regCount = regCount + 1
  if rec.kind == "lite" then liteCount = liteCount + 1 end
  syncTicker()
end

-- A focused EditBox behind a Safety-hidden window swallows every keystroke,
-- movement keys included, invisibly. That is the single most dangerous UI bug
-- available in this module, so the clear is called from every teardown and
-- every safety transition rather than from one clever place.
local function clearFocus()
  if ui.entry and ui.entry.ClearFocus then pcall(ui.entry.ClearFocus, ui.entry) end
end

evict = function(key, keepWindow)
  local rec = sessions[key]
  if not rec then return end
  sessions[key] = nil
  regCount = regCount - 1
  if rec.kind == "lite" then
    liteCount = liteCount - 1
  end
  PG.UI.Dismiss(rec.askKey)
  rec.askKey = nil
  unlistOpen(rec)
  if mine == key then
    mine = nil
    PG.Session.Release("QZ", rec.token)
    clearFocus()
    if win and not keepWindow then win:Hide() end
  end
  poison(key)
  syncTicker()
end

-------------------------------------------------------------------------------
-- Teardown (CONCURRENCY.md 7.1). The instant phase becomes "done", in order:
-- the seat is released, the invitation comes down, the launcher row goes, the
-- edit box loses focus, and the window keeps its final standings until DONE_TTL
-- sweeps the record away.
-------------------------------------------------------------------------------

endSession = function(text)
  local S = mySession()
  if not S then return end
  S.phase = "done"
  S.qOpen = false
  S.endText = text
  S.doneAt = GetTime()
  PG.Session.Release("QZ", S.token)
  PG.UI.Dismiss(S.askKey)
  S.askKey = nil
  unlistOpen(S)
  clearFocus()
  if win then ui.bar:Stop() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Standings: cumulative points, dense ranking (ties share a place: 1,1,2,3).
-- Sorted points desc then name asc (byte order) - identical on every client.
-------------------------------------------------------------------------------

local function computeStandings()
  local S = mySession()
  if not S then return {} end
  local list = {}
  for _, name in ipairs(S.roster) do
    list[#list + 1] = { name = name, pts = S.totals[name] or 0 }
  end
  table.sort(list, function(a, b)
    if a.pts ~= b.pts then return a.pts > b.pts end
    return a.name < b.name
  end)
  local place, lastPts = 0, nil
  for i = 1, #list do
    if list[i].pts ~= lastPts then
      place = place + 1
      lastPts = list[i].pts
    end
    list[i].place = place
  end
  return list
end

-------------------------------------------------------------------------------
-- SavedVariables. The ONLY thing this module persists:
--   PG.db.qz = { medals = { ["Name-Realm"] = 3 }, stats = { asked, correct },
--                opts = { T, L, U, R, hints } }
-- Three defences against SPEC.md 2.5's "secrets silently become nil on disk",
-- all copied from RockPaperScissors.lua's persistMedals: a write-side type gate,
-- a read-before-write revalidation to 0, and read-side tolerance so a corrupted
-- table degrades to "no record yet" and never to a Lua error inside RefreshUI
-- during a raid.
-------------------------------------------------------------------------------

local function qdb()
  if type(PG.db) ~= "table" then return nil end
  if type(PG.db.qz) ~= "table" then PG.db.qz = {} end
  local d = PG.db.qz
  if type(d.medals) ~= "table" then d.medals = {} end
  if type(d.stats) ~= "table" then d.stats = {} end
  if type(d.opts) ~= "table" then d.opts = {} end
  return d
end

local function persistMedals(winners)
  local d = qdb()
  if not d then return end
  local m = d.medals
  for i = 1, #winners do
    local name = winners[i]
    if not PG.IsSecret(name) and type(name) == "string" and name ~= "" then
      local cur = m[name]
      if PG.IsSecret(cur) or type(cur) ~= "number" then cur = 0 end
      m[name] = math.floor(cur) + 1
    end
  end
end

local function myMedalCount()
  local me = myName()
  local db = PG.db and PG.db.qz
  local m = (type(db) == "table") and db.medals or nil
  local n = (me and type(m) == "table") and m[me] or nil
  if not PG.IsSecret(n) and type(n) == "number" then return math.floor(n) end
  return 0
end

-- Per-character, name-free, never broadcast: it exists only for the
-- "Quiz record: 42 of 96" line and carries no social weight.
local function bumpStats(correct)
  local d = qdb()
  if not d then return end
  local s = d.stats
  local asked = PG.SafeNum(s.asked)
  local got = PG.SafeNum(s.correct)
  if type(asked) ~= "number" then asked = 0 end
  if type(got) ~= "number" then got = 0 end
  s.asked = math.floor(asked) + 1
  s.correct = math.floor(got) + (correct and 1 or 0)
end

local function myStats()
  local db = PG.db and PG.db.qz
  local s = (type(db) == "table") and db.stats or nil
  if type(s) ~= "table" then return 0, 0 end
  local asked = PG.SafeNum(s.asked)
  local got = PG.SafeNum(s.correct)
  if type(asked) ~= "number" or asked < 0 then asked = 0 end
  if type(got) ~= "number" or got < 0 then got = 0 end
  return math.floor(asked), math.floor(got)
end

-- Dialog options. Booleans only; all-false on read is treated as all-true,
-- because a table that came back from disk with every mode off would otherwise
-- leave Start permanently disabled with no way to explain why.
local function readOpts()
  local d = qdb()
  local o = d and d.opts or {}
  local out = { hints = o.hints ~= false }
  local any = false
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    out[m] = (o[m] == true)
    if out[m] then any = true end
  end
  if not any then
    for i = 1, #MODE_ORDER do out[MODE_ORDER[i]] = true end
  end
  return out
end

local function writeOpt(k, v)
  local d = qdb()
  if not d then return end
  d.opts[k] = (v == true)
end

-------------------------------------------------------------------------------
-- Shared state transitions. The host applies these locally at send time (the
-- section-6 loopback rule); clients apply them on receipt of host broadcasts.
-------------------------------------------------------------------------------

local function applyJoined(name)
  local S = mySession()
  if not S then return end
  -- normal path: join phase. Resync replays land here too: a desynced spectator
  -- mid-play accepts the replayed JOINED/LEFT stream to repair its roster
  -- (idempotent - a duplicate JOINED never double-adds).
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
  if S.phase == "join" then runFX(FX.joined, name) end
end

local function applyLeft(name)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if S.joined[name] then
    S.joined[name] = nil
    for i = #S.roster, 1, -1 do
      if S.roster[i] == name then table.remove(S.roster, i) end
    end
  end
  if name == myName() and not S.isHost then
    -- Withdrawal (CONCURRENCY.md 7.2): leaving now STOPS this client tracking
    -- the game. One of the two paths besides endSession allowed to free the
    -- seat (I2).
    S.joinAccepted = false
    evict(S.key)
    return
  end
  RefreshUI()
end

local function applyBegin(count, rounds, dig)
  local S = mySession()
  if not S then return end
  if S.phase ~= "join" then
    -- BEGIN while playing is ignored (totals are never re-built once play has
    -- begun, so replayed RESULTs can never double-count) - EXCEPT that a client
    -- which missed BEGIN entirely (forced spectator, S.count == nil) absorbs the
    -- original fields so resync agreement can be evaluated.
    if S.phase == "play" and S.spectator and S.count == nil then
      S.count = count
      S.rounds = rounds
      S.digest = dig
      RefreshUI()
    end
    return
  end
  S.phase = "play"
  S.count = count
  S.rounds = rounds
  S.digest = dig
  S.totals = {}
  for _, n in ipairs(S.roster) do S.totals[n] = 0 end
  local me = myName()
  -- Our mirror agrees with the host in SIZE and MEMBERSHIP, so this is not a
  -- desync we could resync out of - it is the host's roster and we are not in
  -- it. Our JOIN never landed. Tracking a game we cannot play is pointless, and
  -- the seat is not.
  -- The digest is compared unconditionally. BEGIN is refused without one, so an
  -- absent digest can never make "agrees" mean size alone and leave a mirror
  -- holding the wrong NAMES in play: every RESULT would then fit the pattern
  -- length, score the wrong roster and persist a medal for a player who lost.
  local agrees = (#S.roster == count) and rosterDigest(S.roster) == dig
  if not S.isHost and agrees and not (me and S.joined[me]) then
    toast("your join did not reach the host - you are not in this game.", S.host,
      { key = "qz-status" })
    endSession("You are not in this game.")
    evict(S.key)
    return
  end
  if not S.isHost and not agrees then
    S.spectator = true
    toast("out of sync with the host - resyncing...", S.host, { key = "qz-status" })
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(FX.begin)
end

-- r, m, a, b, c, seed, secs are the exact wire fields. a/b/c are STRINGS: a
-- plain index for T/U/R, a pool-qualified slot for L.
local function applyQuestion(r, m, a, b, c, seed, secs)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  if r < S.r then return end -- stale/late resync replay: never regress
  -- A round whose RESULT we already applied is finished, and a late or replayed
  -- QSTN for it must never re-open the window: the reveal is on screen, the
  -- points are counted, and re-arming the answer box would invite a submission
  -- the host can only drop.
  if S.appliedResults[r] then return end
  local fresh = (r ~= S.r)
  if fresh then
    S.r = r
    S.myAnswer = nil
    S.myLocked = false
    S.hintShown = false
    S.lastResult = nil
    S.dataBad = false
    S.resolveNow = false -- a Reveal-now press never carries into the next question
    if S.isHost then
      S.answers = {}
      S.answerCount = 0
    end
  end
  S.q = { m = m, a = a, b = b, c = c, seed = seed }
  local view = Bank.resolveQuestion(S.q)
  if not view then
    -- The version gate on OPEN should have caught this, so reaching here means
    -- two banks that claim the same VERSION disagree, or a hostile host sent an
    -- index outside the pool. Either way: keep the mirror and the standings
    -- (RESULT patterns are positional, not textual) and stop being able to
    -- answer, rather than erroring or dropping the session.
    S.qView = nil
    if not S.dataBad then
      S.dataBad = true
      toast("your question pack does not match the host's - watching this one.",
        S.host, { key = "qz-status" })
    end
  else
    S.qView = view
  end
  -- A REPEAT question for the round we are already in is a freeze re-open, not
  -- a new question. Two things must NOT happen on that path:
  --   * qShownAt must not move. Everyone's elapsed clock keeps running through
  --     the pause on every machine, so a 2s answer from before the ready check
  --     still outranks a 1s answer after it. Resetting the origin would put the
  --     post-reopen answer first purely because the round was interrupted
  --     (critique-1 C5).
  --   * the edit box must not be cleared, or a player who typed before the
  --     ready check silently loses what they typed (critique-1 C9).
  if fresh then
    S.qShownAt = GetTime()
    if ui.entry then ui.entry:SetText("") end
  end
  S.qOpen = true
  S.deadline = GetTime() + secs
  ShowWindow()
  if win then ui.bar:Start(secs) end
  RefreshUI()
  if fresh then runFX(FX.question) end
end

local function applyResult(r, pattern)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  -- resync idempotency: a point must never count twice under replay
  if S.appliedResults[r] then return end
  local current = r >= S.r
  if current then
    S.qOpen = false
    clearFocus()
  end
  local me = myName()
  local myChar, myGain, fastest
  local nCorrect, nWrong, nNone = 0, 0, 0
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    if c == "1" or c == "2" or c == "C" then nCorrect = nCorrect + 1
    elseif c == "W" then nWrong = nWrong + 1
    else nNone = nNone + 1 end
  end
  -- WHAT BREAKS WITHOUT THE SPECTATOR TEST: the pattern is positional and no
  -- name travels with an outcome, so a SIZE test alone pays POINTS to whoever
  -- happens to sit at that index in OUR list. A mirror holding the right number
  -- of the wrong members - a whispered LEFT/JOINED pair from a modified host, or
  -- an honest desync that swapped one player for another - would score, and at
  -- applyEnd persist medals for, the wrong people: exactly the harm :218
  -- describes, and the one thing a count comparison cannot see. A spectator is
  -- by definition a mirror the digest has NOT blessed, so it RETAINS the pattern
  -- instead of scoring it and maybeClearSpectator credits the held rounds the
  -- moment the digest matches again.
  -- appliedResults is marked on BOTH paths deliberately, and that is what keeps
  -- the resync contract intact: it means RECEIVED, not scored. A spectator that
  -- simply dropped its RESULTs would report appliedThrough() == 0 for the rest
  -- of the game and force the host to replay every round back at it on top of
  -- the JOINED/LEFT stream, which is what SYNC_MAX_REPLAY refuses - the heal
  -- would arrive as a SYNCNO and the player would spectate a game they could
  -- have rejoined.
  if S.spectator then
    S.appliedResults[r] = true
    S.heldResults[r] = pattern
  elseif #pattern == #S.roster then -- never true while the roster is desynced
    S.appliedResults[r] = true
    for i, name in ipairs(S.roster) do
      local c = pattern:sub(i, i)
      S.totals[name] = (S.totals[name] or 0) + (POINTS[c] or 0)
      if c == "1" then fastest = name end
      if name == me then
        myChar = c
        myGain = POINTS[c] or 0
      end
    end
    -- Personal stats tick here and only here: a round that was actually applied,
    -- by a player who is actually in the roster and not spectating.
    if (not S.spectator) and S.joinAccepted and myChar then
      bumpStats(myChar == "1" or myChar == "2" or myChar == "C")
    end
  end
  if current then
    S.lastResult = { r = r, pattern = pattern, nCorrect = nCorrect,
                     nWrong = nWrong, nNone = nNone, myChar = myChar,
                     myGain = myGain, fastest = fastest }
    local head = "Question " .. r .. ": "
    if nCorrect == 0 then
      S.lastResultText = head .. "nobody got it."
    elseif fastest then
      S.lastResultText = head .. shortOf(fastest) .. " was fastest - "
        .. nCorrect .. " of " .. #S.roster .. " correct."
    else
      S.lastResultText = head .. nCorrect .. " of " .. #pattern .. " correct."
    end
    S.revealText = Bank.answerTextOf(S.qView)
    ShowWindow()
    if win then ui.bar:Stop() end
  end
  RefreshUI()
  if r == S.r then runFX(FX.result) end
end

local function applyVoid(r)
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  S.qOpen = false
  S.myAnswer = nil
  S.myLocked = false
  S.lastResult = nil
  S.revealText = nil
  S.q = nil
  S.qView = nil
  if S.isHost then
    S.answers = {}
    S.answerCount = 0
  end
  S.lastResultText = "Question " .. r
    .. " was interrupted by the encounter - a new one is coming."
  -- the re-broadcast QSTN for round r then reads as a FRESH question
  -- everywhere, which is deliberate: an interruption gives everyone unlimited
  -- think time (and, in Two Truths, a long look at three statements), so
  -- re-showing the same question would be a giveaway rather than a replay.
  S.r = r - 1
  clearFocus()
  if ui.entry then ui.entry:SetText("") end
  ShowWindow()
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(FX.void)
end

local function applyEnd()
  local S = mySession()
  if not S or S.phase ~= "play" then return end
  local standings = computeStandings()
  S.standings = standings
  local winners = {}
  for i = 1, #standings do
    if standings[i].place == 1 then winners[#winners + 1] = standings[i].name end
  end
  local me = myName()
  -- Participation gate, SCOPE.md 4.4 G1 applied to medals. Three refusals in
  -- one test: a desynced spectator never applied RESULTs so its totals are
  -- wrong; a referee host (I5) has no stake in its own game; a client that
  -- merely overheard the session holds no full record at all. Outside the party
  -- only the local player's own medal is persisted - a stranger's medal count is
  -- not local-hall-of-fame material.
  if (not S.spectator) and S.joinAccepted and me and S.joined[me] then
    if S.scope == "group" then
      persistMedals(winners)
    else
      for i = 1, #winners do
        if winners[i] == me then persistMedals({ me }) end
      end
    end
  end
  S.ended = true
  local text
  if S.spectator then
    text = "Game over."
  else
    local won = false
    for i = 1, #winners do
      if winners[i] == me then won = true end
    end
    if won then
      text = (#winners > 1) and "you tied for the win!" or "you win!"
    elseif winners[1] then
      text = shortOf(winners[1]) .. ((#winners > 1) and " and friends take it." or " takes it.")
    else
      text = "done!"
    end
    text = "Game over - " .. text
  end
  -- medals are this game's money: the line is never dropped for queue space
  toast(text, S.host, { priority = "result" })
  ShowWindow()
  endSession(text)
  runFX(FX.podium)
end

local function applyCancel(reason)
  local S = mySession()
  if not S or S.phase == "done" then return end
  local text
  if reason == "few" then
    text = "Cancelled - not enough players joined. Others may be busy or away."
    if S.isHost and S.scope == "guild" then
      -- SCOPE.md 2.4: an open Blizzard bug means a rank that cannot speak in
      -- guild chat cannot SEND on the GUILD distribution either, so the host's
      -- OPEN reached nobody. There is no probe for it; this is the diagnostic.
      text = "Nobody joined. If your guild rank can't speak in guild chat, guild games can't be started from this character."
    end
  elseif reason == "host" then
    text = "Cancelled by the host."
  elseif reason == "pack" then
    text = "Cancelled - the question pack ran out of questions this game can use."
  else
    text = "Cancelled (" .. tostring(reason) .. ")."
  end
  toast(text, S.host)
  endSession(text)
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

local function hostRecordOp(op, name)
  local S = mySession()
  if not S then return end
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

-- Soft "avoid recent repeats" memory: the old addon's PickQuestionIndex, kept
-- at MODULE scope, runtime only, host side only. It is deliberately NOT in the
-- data file and NOT in SavedVariables - it is a variety heuristic across this
-- play session, not state anyone else depends on.
local recentPick = {}

local function pickAvoidingRecent(key, avail, poolN)
  local n = #avail
  if n < 1 then return nil end
  if n == 1 then return avail[1] end
  local rec = recentPick[key]
  if not rec then
    rec = { list = {}, set = {} }
    recentPick[key] = rec
  end
  local maxRecent = math.min(20, math.max(1, poolN - 1))
  local pos = math.random(n)
  for _ = 1, 50 do
    if not rec.set[avail[pos]] then break end
    pos = math.random(n)
  end
  local idx = avail[pos]
  -- An already-recent pick (all rerolls exhausted) is already tracked; inserting
  -- it again would desync the list and the set.
  if not rec.set[idx] then
    rec.list[#rec.list + 1] = idx
    rec.set[idx] = true
    while #rec.list > maxRecent do
      local old = table.remove(rec.list, 1)
      rec.set[old] = nil
    end
  end
  return idx
end

-- Hard per-session exclusion with recycling, the old AvailableWithRecycle rule
-- generalized to all four modes: when the pool cannot serve the request, the
-- retirement set is cleared but the IMMEDIATELY PREVIOUS round's picks stay
-- retired, because a question answered seconds ago must not come straight back.
local function availableFrom(list, used, lastRound, needed)
  local avail = {}
  for i = 1, #list do
    local idx = list[i]
    if not used[idx] then avail[#avail + 1] = idx end
  end
  if #avail >= needed then return avail end
  wipe(used)
  for idx in pairs(lastRound) do used[idx] = true end
  avail = {}
  for i = 1, #list do
    local idx = list[i]
    if not used[idx] then avail[#avail + 1] = idx end
  end
  if #avail >= needed then return avail end
  wipe(used)
  avail = {}
  for i = 1, #list do avail[#avail + 1] = list[i] end
  return avail
end

-- Draws the next question. HOST ONLY - a client never calls this and never
-- needs to, because the wire carries the answer to it. Returns m, a, b, c or nil.
local function hostPickQuestion()
  local S = mySession()
  if not S then return nil end
  -- 1. the mode: enabled, and able to serve a question. When more than one
  --    qualifies, avoid repeating the previous round's mode.
  local pool = {}
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    if S.modes[m] and Bank.modeReady(m) then pool[#pool + 1] = m end
  end
  if #pool == 0 then return nil end
  local choices = pool
  if #pool > 1 and S.lastMode then
    local filtered = {}
    for i = 1, #pool do
      if pool[i] ~= S.lastMode then filtered[#filtered + 1] = pool[i] end
    end
    if #filtered > 0 then choices = filtered end
  end
  local m = choices[math.random(#choices)]

  if m == "L" then
    local tAvail = availableFrom(Bank.usable.LT, S.used.LT, S.last.LT, 2)
    local lAvail = availableFrom(Bank.usable.LL, S.used.LL, S.last.LL, 1)
    if #tAvail < 2 or #lAvail < 1 then return nil end
    -- two DISTINCT truths and one lie. table.remove by index is the source's
    -- construction and is what guarantees distinctness.
    local t1 = table.remove(tAvail, math.random(#tAvail))
    local t2 = table.remove(tAvail, math.random(#tAvail))
    local li = lAvail[math.random(#lAvail)]
    wipe(S.last.LT)
    wipe(S.last.LL)
    S.used.LT[t1] = true
    S.used.LT[t2] = true
    S.last.LT[t1] = true
    S.last.LT[t2] = true
    S.used.LL[li] = true
    S.last.LL[li] = true
    -- shuffle into the A/B/C slots
    local slots = { { p = "T", i = t1 }, { p = "T", i = t2 }, { p = "L", i = li } }
    for i = 3, 2, -1 do
      local j = math.random(i)
      slots[i], slots[j] = slots[j], slots[i]
    end
    S.lastMode = m
    return m, slots[1].p .. slots[1].i, slots[2].p .. slots[2].i,
           slots[3].p .. slots[3].i
  end

  local list = Bank.usable[m]
  local avail = availableFrom(list, S.used[m], S.last[m], 1)
  local idx = pickAvoidingRecent(m, avail, #list)
  if not idx then return nil end
  wipe(S.last[m])
  S.used[m][idx] = true
  S.last[m][idx] = true
  S.lastMode = m
  return m, tostring(idx), "0", "0"
end

local function hostCancel(reason)
  local S = mySession()
  if not S then return end
  if S.endSent then return end
  broadcast("CANCEL", reason)
  applyCancel(reason)
end

-- critique-1 C1: the question's clock MUST start when the QSTN actually leaves
-- the wire, not when it is queued. PG.Comm's bucket is 10 tokens at +1/s and a
-- resync replay can drain it, so a QSTN can sit for ~10 seconds. Applying it
-- locally at submit time would start the host's own clock (and the host's
-- deadline) that much earlier than every client's, which makes the host win
-- every speed race by construction and gives clients a short window - the exact
-- opposite of the "no cross-machine clock is ever compared" guarantee.
-- BroadcastEx's onSent fires exactly once, after the message has actually gone.
local function hostStartQuestion(r)
  local S = mySession()
  if not S then return end
  local m, a, b, c = hostPickQuestion()
  if not m then
    -- Nothing left that this game can ask. Rare (125 truths against 9 rounds),
    -- but a stall with no explanation is worse than an honest cancel.
    hostCancel("pack")
    return
  end
  local seed = math.random(1, 65535)
  local secs = S.answerSecs
  local sess = S
  -- set BEFORE the call: onSent may fire synchronously inside it when the
  -- bucket has tokens, and would then be undone by an assignment afterwards
  S.qPending = true
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      -- the callback can fire a second or more later: re-resolve and refuse
      -- unless this exact record is still the involved one
      local cur = mySession()
      if cur ~= sess or sessions[sess.key] ~= sess or cur.phase ~= "play" then return end
      cur.qPending = false
      applyQuestion(r, m, a, b, c, seed, secs)
    end,
  }, "QZ", "QSTN", S.token, r, m, a, b, c, seed, secs)
  if not ok then
    S.qPending = false
    S.nextQAt = GetTime() + 2 -- send refused; the ticker retries
  end
end

local function hostAdvance(delay)
  local S = mySession()
  if not S then return end
  if S.r >= S.rounds then
    S.endPending = true -- END goes out on the next clear tick
  else
    S.nextQAt = GetTime() + delay
  end
end

local function hostResolveRound()
  local S = mySession()
  if not S or not S.q then return end
  -- Rank the correct answers by their EFFECTIVE elapsed time, ties broken by
  -- name in byte order. Only the host ranks and the result travels as a
  -- pattern, so the tie-break is deterministic and identical on every client.
  local ranked = {}
  for i = 1, #S.roster do
    local name = S.roster[i]
    local a = S.answers[name]
    if a and a.ok then ranked[#ranked + 1] = { name = name, t = a.t } end
  end
  table.sort(ranked, function(x, y)
    if x.t ~= y.t then return x.t < y.t end
    return x.name < y.name
  end)
  local first = ranked[1] and ranked[1].name or nil
  local second = ranked[2] and ranked[2].name or nil
  local chars = {}
  for i, name in ipairs(S.roster) do
    local a = S.answers[name]
    if name == first then chars[i] = "1"
    elseif name == second then chars[i] = "2"
    elseif a then chars[i] = a.ok and "C" or "W"
    else chars[i] = "X" end
  end
  local pattern = table.concat(chars)
  if not broadcast("RESULT", S.r, pattern) then
    return -- send refused; the ticker re-resolves next clear tick
  end
  S.resolveNow = false
  S.hist.results[S.r] = pattern -- exact original fields, retained for resync
  if S.r > S.hist.resultTop then S.hist.resultTop = S.r end
  applyResult(S.r, pattern)
  hostAdvance(REVEAL_SECS)
end

-- Encounter/restriction broke the question: VOID it, then replay the SAME round
-- number with a NEW question (applyVoid rewinds S.r, so the ticker's r+1 is the
-- same round).
local function hostVoidRound()
  local S = mySession()
  if not S then return end
  local r = S.r
  if broadcast("VOID", r) then
    S.broken = false
    S.frozen = false
    applyVoid(r)
    S.nextQAt = GetTime() + VOID_PAUSE_SECS
  end
end

-- assigned below, once the answer bookkeeping exists
local maybeEarlyFinish

-- After a ready check or a pull countdown: re-broadcast the SAME question with
-- a fresh timer. Clients treat a repeat QSTN for a known r as a refresh, so
-- locks stay locked and - see applyQuestion - the elapsed clock does NOT
-- restart, which is what keeps everyone's times comparable across the pause.
local function hostReopenQuestion()
  local S = mySession()
  if not S or not S.q then
    -- nothing to re-open (the question was never applied): fall back to the
    -- normal start path rather than hanging frozen forever
    if S then
      S.frozen = false
      S.nextQAt = GetTime() + 1
    end
    return
  end
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.freezeRemaining or 0))
  local q = S.q
  local r = S.r
  local sess = S
  S.qPending = true
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      local cur = mySession()
      if cur ~= sess or sessions[sess.key] ~= sess or cur.phase ~= "play" then return end
      cur.qPending = false
      cur.frozen = false
      applyQuestion(r, q.m, q.a, q.b, q.c, q.seed, secs)
      -- the last answer may have landed DURING the freeze, in which case there
      -- is nobody left to wait for and the re-opened timer would just burn down
      maybeEarlyFinish()
    end,
  }, "QZ", "QSTN", S.token, r, q.m, q.a, q.b, q.c, q.seed, secs)
  if not ok then S.qPending = false end
end

local function hostEnd()
  local S = mySession()
  if not S then return end
  if S.endSent then return end
  -- Medals persist (and the podium reveals) only once END has actually left the
  -- wire: a queued-then-lockdown-dropped END aborts via onDrop instead, with no
  -- medals anywhere.
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    scope = S.scope,
    onSent = function()
      local cur = mySession()
      if cur ~= sess or sessions[sess.key] ~= sess or cur.phase ~= "play" then return end
      cur.endPending = nil
      applyEnd()
    end,
  }, "QZ", "END", S.token)
  if ok then S.endSent = true end
end

local function hostCloseJoin()
  local S = mySession()
  if not S or S.phase ~= "join" then return end
  -- a referee host is absent from its own roster (I5), so this minimum means
  -- two OTHER players, which is exactly what a quiz needs
  local count = #S.roster
  if count < 2 then
    if broadcast("CANCEL", "few") then
      applyCancel("few")
    else
      S.joinDeadline = GetTime() + 2 -- send refused; retry shortly
    end
    return
  end
  local dig = rosterDigest(S.roster) -- membership, not just size (4 bytes)
  if broadcast("BEGIN", count, S.rounds, dig) then
    S.hist.beginCount, S.hist.beginDigest = count, dig
    applyBegin(count, S.rounds, dig)
    S.nextQAt = GetTime() + BEGIN_PAUSE_SECS
  else
    S.joinDeadline = GetTime() + 2
  end
end

local function hostHandleJoin(sender)
  local S = mySession()
  if not S or S.phase ~= "join" or S.joined[sender] then return end
  if #S.roster >= ROSTER_CAP then return end
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

local function allAnswered()
  local S = mySession()
  if not S then return false end
  local n = #S.roster
  if n < 2 then return false end
  for i = 1, n do
    if not S.answers[S.roster[i]] then return false end
  end
  return true
end

-- Everyone seated has answered: nobody is waiting on anybody, so the question
-- resolves now instead of burning the rest of the window. A resynced player
-- held out of the open question (syncHoldR) never completes the set, so that
-- round quietly falls back to its timer rather than stranding them.
maybeEarlyFinish = function()
  local S = mySession()
  if not S or S.phase ~= "play" or not S.qOpen or S.broken or S.frozen then return end
  if not (allAnswered() and allClear() and not PG.Comm.Locked()) then return end
  hostResolveRound()
end

-- The whole adjudication entry point. `tenths` is the SUBMITTER's own measured
-- elapsed time, in tenths of a second, from the moment IT rendered the question.
local function hostHandleAnswer(sender, r, tenths, text)
  local S = mySession()
  if not S or S.phase ~= "play" or not S.qOpen or S.broken then return end
  if r ~= S.r then return end
  if not S.joined[sender] then return end
  if S.answers[sender] then return end -- first submission locks
  -- Second line of defence behind the client's own normalization: the wire
  -- alphabet is contractual, and a broken or hostile client must not be able to
  -- put anything else into an adjudicated field.
  local t = Bank.normalize(text)
  if t == "" or #t > ANS_MAX then return end
  if not text:match("^[a-z0-9 ]+$") then return end
  -- Same clock origin on both sides of this subtraction: the host's own.
  local arrival = GetTime() - (S.qShownAt or GetTime())
  if arrival < 0 then arrival = 0 end
  local reported = tenths / 10
  -- A liar can claim at most MAX_CREDIT seconds of credit, and can never claim
  -- a time earlier than the question's own start on this machine.
  if reported > arrival then reported = arrival end
  if reported < 0 then reported = 0 end
  local eff = math.max(reported, arrival - MAX_CREDIT)
  S.answers[sender] = { t = eff, ok = Bank.checkAnswer(S.qView, t) }
  S.answerCount = (S.answerCount or 0) + 1
  RefreshUI()
  maybeEarlyFinish()
end

-- The "Reveal now" button, the port of the old addon's Skip. A refused
-- broadcast must retry: the ticker's play branch would otherwise only look
-- again at the deadline, so pressing Reveal now early and losing the send would
-- do nothing at all (critique-1 C5).
local function hostRevealNow()
  local S = mySession()
  if not S or S.phase ~= "play" or not S.qOpen then return end
  if S.broken or S.frozen or not allClear() or PG.Comm.Locked() then return end
  S.resolveNow = true
  hostResolveRound()
end

-- one replay entry; the explicit arity keeps trailing nils out of the wire
local function pushMsg(out, ...)
  local m = { ... }
  m.n = select("#", ...)
  out[#out + 1] = m
end

-- Resync: replay BY WHISPER exactly what the asking client missed, using the
-- ORIGINAL message types and field layouts - the full JOINED/LEFT stream if its
-- roster disagrees in count or membership, BEGIN if its phase trails, the
-- missing RESULTs in order, then the live QSTN with its real remaining seconds.
local function hostHandleSyncQ(sender, phase, rApplied, rosterN, dig)
  local S = mySession()
  if not S then return end
  if phase ~= "join" and phase ~= "play" then return end
  if not (rApplied and rosterN) then return end
  if dig ~= nil and not isDigest(dig) then return end
  if PG.Comm.Locked() then return end
  local now = GetTime()
  local last = S.syncAsk[sender]
  if last and (now - last) < SYNC_COOLDOWN then return end
  S.syncAsk[sender] = now
  local out = {}
  if rosterN ~= #S.roster or (dig and dig ~= rosterDigest(S.roster)) then
    for i = 1, #S.hist.ops do
      local op = S.hist.ops[i]
      pushMsg(out, (op.op == "J") and "JOINED" or "LEFT", op.name)
    end
  end
  if S.phase == "play" then
    if phase == "join" then
      pushMsg(out, "BEGIN", S.hist.beginCount or S.count, S.rounds,
              S.hist.beginDigest or rosterDigest(S.roster))
    end
    for r = rApplied + 1, S.hist.resultTop do
      if S.hist.results[r] then
        pushMsg(out, "RESULT", r, S.hist.results[r])
      end
    end
    if #out > 0 and S.qOpen and S.q and not S.broken and not S.frozen and S.r >= 1 then
      local remain = math.max(1, math.ceil((S.deadline or now) - now))
      pushMsg(out, "QSTN", S.r, S.q.m, S.q.a, S.q.b, S.q.c, S.q.seed, remain)
    end
  end
  if #out > SYNC_MAX_REPLAY then
    PG.Comm.Whisper(sender, "QZ", "SYNCNO", S.token)
    return
  end
  if #out == 0 then
    PG.Comm.Whisper(sender, "QZ", "SYNCOK", S.token)
    return
  end
  -- replay whispers reuse CRITICAL_DROP mtypes: shield onDrop while the send
  -- queue drains (see REPLAYABLE) so a lockdown-dropped replay whisper never
  -- aborts the live game - the asking client simply retries later
  S.syncReplayUntil = now + 30
  for i = 1, #out do
    local m = out[i]
    PG.Comm.Whisper(sender, "QZ", m[1], S.token, unpack(m, 2, m.n))
  end
end

-- Why Start may be blocked, and whether it is blocked at all (CONCURRENCY.md
-- 6.4). The ONLY refusal is I3 - this module already holds a full record.
local function involvement()
  local S = mySession()
  if S and S.phase ~= "done" then
    if S.isHost then
      return "You're already running a Quiz. Cancel it first, or wait for it to finish.", false
    end
    return "You're playing " .. shortOf(S.host)
      .. "'s Quiz. You can start your own when it's over.", false
  end
  local seat = PG.Session.Seat()
  if seat and seat.module ~= "QZ" then
    -- Referee hosting (I5): you play one round-based game and run the other.
    return "You're playing " .. (MODULE_NAME[seat.module] or seat.module)
      .. ", so you'll run this game without playing in it.", true
  end
  return nil, true
end

hostOpen = function(rounds, joinSecs, answerSecs, modes, hints, scope)
  local note, canStart = involvement()
  if not canStart then
    toast(note)
    return
  end
  local ver = Bank.dataVersion()
  if not ver then
    toast("the question pack did not load. Reinstall Pengyou Games.")
    return
  end
  -- at least one enabled mode must be able to serve a question, or the session
  -- opens and then stalls on its very first round
  local usable = 0
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    if modes[m] and Bank.modeReady(m) then usable = usable + 1 end
  end
  if usable == 0 then
    toast("none of the chosen games have enough questions in the pack.")
    return
  end
  local host = myName()
  if not host then return end
  scope = PG.SafeStr(scope) or "group"
  if not PG.QZ.SCOPES[scope] then return end
  -- availability is re-checked at the moment Start is pressed (SCOPE.md 1.3)
  local okScope, why = PG.Comm.ScopeAvailable(scope)
  if not okScope then
    toast(why or "that audience isn't available.")
    if dlgScope and dialog and dialog:IsShown() then pcall(dlgScope.Refresh, dlgScope) end
    return
  end
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  local mask = 0
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    if modes[m] then mask = mask + MODE_BIT[m] end
  end
  local token = nextToken()
  -- broadcast OPEN before touching any record: a submit-time lockdown drop
  -- invokes onDrop synchronously, and a token with no record is ignored there
  if not PG.Comm.Broadcast(scope, "QZ", "OPEN", token, rounds, joinSecs,
                           answerSecs, mask, hints and 1 or 0, ver, code) then
    toast("cannot start right now (addon messages are blocked).")
    return
  end
  local prev = mySession()
  if prev then evict(prev.key, true) end
  -- I5: hosting never fails on the seat. ClaimHost cannot refuse; it only
  -- reports whether we are a player in our own game or its referee.
  local seated = PG.Session.ClaimHost("QZ", token, host)
  local key = keyOf(host, token)
  local modeSet = {}
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    modeSet[m] = (modes[m] and Bank.modeReady(m)) and true or false
  end
  -- Everything the appliers and the host logic index is initialized HERE, where
  -- the record is built, and not in applyBegin: two paths reach the play phase
  -- without applyBegin (the comm prologue's forced-spectator path and
  -- applyBegin's own absorb-and-return branch), and a nil index on either is
  -- swallowed by Comm's pcall and silently records nothing (BRIEF 5.1 B3).
  local rec = {
    kind = "full",
    key = key,
    token = token,
    host = host,
    scope = scope,           -- immutable for the life of the session (SCOPE.md 3.1)
    isHost = true,
    seated = seated,
    refereed = not seated,
    rounds = rounds,
    joinSecs = joinSecs,
    answerSecs = answerSecs,
    modes = modeSet,
    hints = hints and true or false,
    ver = ver,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    answers = {},
    answerCount = 0,
    r = 0,
    appliedResults = {},
    heldResults = {},  -- unused on a host, present so no path can index nil
    used = { T = {}, U = {}, R = {}, LT = {}, LL = {} },
    last = { T = {}, U = {}, R = {}, LT = {}, LL = {} },
    hist = { ops = {}, results = {}, resultTop = 0 }, -- resync replay history
    syncAsk = {}, -- per-sender SYNCQ rate limiting
    joinDeadline = GetTime() + joinSecs,
    joinDeadlineDisplay = GetTime() + joinSecs,
    lastHBSent = GetTime(),
  }
  register(rec)
  mine = key
  if seated then
    if broadcast("JOINED", host) then
      hostRecordOp("J", host)
      applyJoined(host) -- host auto-joins
    end
  end
  -- a sync lockdown drop of JOINED (critical) aborts via onDrop above
  if not live() then return end
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

-- The SINGLE input path: Enter, the Submit button and the A/B/C buttons all
-- come here, so there is one lock and one code path.
-- Returns true ONLY when the whisper was refused by the lockdown - the one
-- outcome where the player still has an answer to send and the caller must
-- leave the edit box focused so they can press Enter again.
doSubmit = function(rawText)
  local S = mySession()
  -- gate l (5.2): a local action requires the INVOLVED record and a seat in it.
  -- A referee host has no answer, which is what "runs the game" means.
  if not S or not S.seated then return end
  if S.phase ~= "play" or not S.qOpen then return end
  if S.spectator or S.dataBad or S.myLocked then return end
  if S.syncHoldR == S.r then return end -- resynced mid-question: back in NEXT one
  local me = myName()
  if not me or not S.joined[me] then return end
  local text = Bank.normalize(rawText)
  -- An empty or punctuation-only answer refuses silently: a stray Enter can
  -- never burn the single submission.
  if text == "" or #text > ANS_MAX then return end
  -- Clamped to the largest window this game can run, so `tenths` always fits
  -- the 0..600 range the host validates against and a client with a stale
  -- qShownAt can never send a value the host drops AFTER we have locked
  -- (critique-1 C2).
  local elapsed = GetTime() - (S.qShownAt or GetTime())
  if elapsed < 0 then elapsed = 0 end
  if elapsed > MAX_ANSWER_SECS then elapsed = MAX_ANSWER_SECS end
  local tenths = math.floor(elapsed * 10 + 0.5)
  local blocked
  if S.isHost then
    S.myAnswer, S.myLocked = text, true
    hostHandleAnswer(me, S.r, tenths, text)
  else
    -- lock only if the whisper was actually accepted for send, so the UI never
    -- claims a lock the host can never have seen
    if PG.Comm.Whisper(S.host, "QZ", "ANS", S.token, S.r, tenths, text) then
      S.myAnswer, S.myLocked = text, true
    else
      -- A refusal is never a dead button (Rolls.lua's rule, and both DR and GB
      -- say so out loud). Comm refuses this whisper for exactly one reason a
      -- player can see - addon messages are blocked - and with no line the
      -- status still reads "type your answer and press Enter", Submit stays
      -- enabled, and the player retypes into the void until the round resolves
      -- against them.
      toast("addon messages are blocked right now - your answer did not send.",
        S.host, { key = "qz-send" })
      blocked = true
    end
  end
  if S.myLocked then
    clearFocus()
    runFX(FX.submit)
  end
  RefreshUI()
  return blocked
end

-- The full-record constructor (I7), reachable from exactly two places: the
-- invitation's Accept callback and the launcher's Join button.
local function clientAccept(rec)
  if not rec or rec.kind ~= "lite" or sessions[rec.key] ~= rec then return false end
  local cur = mySession()
  if cur and cur.phase == "done" then
    evict(cur.key, true)
    cur = nil
  end
  if cur then
    toast("you're already in " .. (cur.isHost and "your own game"
      or (shortOf(cur.host) .. "'s game")) .. " - finish it first.", rec.host)
    return false
  end
  -- 5.6 rule 3: the seat is claimed FIRST. A genuine race loses here, and
  -- nothing is whispered.
  if not PG.Session.Claim("QZ", rec.token, rec.host) then
    toast("you just joined another game - not joining this one.", rec.host)
    return false
  end
  local cfg = rec.cfg
  local openedAt = rec.openedAt
  local askKey = rec.askKey
  PG.UI.Dismiss(askKey)
  unlistOpen(rec)
  sessions[rec.key] = nil
  regCount = regCount - 1
  liteCount = liteCount - 1
  local S = {
    kind = "full",
    key = rec.key,          -- same identity: lite and full are one session
    token = rec.token,
    host = rec.host,
    scope = rec.scope,
    isHost = false,
    seated = true,
    refereed = false,
    rounds = cfg.rounds,
    joinSecs = cfg.joinSecs,
    answerSecs = cfg.answerSecs,
    modes = cfg.modes,
    hints = cfg.hints,
    ver = cfg.ver,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    answers = {},   -- unused on a client, present so no path can index nil
    answerCount = 0,
    r = 0,
    appliedResults = {},
    heldResults = {},          -- RESULTs received while desynced, scored on heal
    syncAllClear = allClear(),
    lastHB = GetTime(),
    joinDeadlineDisplay = openedAt + cfg.joinSecs,
    joinAccepted = true,       -- provisional; the host's JOINED confirms
  }
  register(S)
  mine = S.key
  PG.Comm.Whisper(S.host, "QZ", "JOIN", S.token)
  ShowWindow()
  if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
  -- The record is built at ACCEPT time, so every JOINED that landed while the
  -- invitation sat on screen was missed; the resync protocol replays exactly
  -- that stream.
  clientRequestSync()
  RefreshUI()
  return true
end

-- The launcher's Open games list joins through the same path as the popup.
function PG.QZ.JoinOpen(key)
  return clientAccept(sessions[tostring(key or "")])
end

-- Read-only view of what this module is overhearing, for the launcher list.
function PG.QZ.OpenGames()
  local out = {}
  for _, rec in pairs(sessions) do
    if rec.kind == "lite" then
      out[#out + 1] = { key = rec.key, host = rec.host, token = rec.token,
                        scope = rec.scope, expires = rec.expires, game = "QZ" }
    end
  end
  return out
end

local function clientHostDead()
  local S = mySession()
  if not S then return end
  toast("lost contact with the host - game abandoned.", S.host)
  endSession("Abandoned - the host stopped responding.")
end

-- highest round R such that RESULTs 1..R have all been applied locally
local function appliedThrough()
  local S = mySession()
  if not S then return 0 end
  local r = 0
  while S.appliedResults[r + 1] do r = r + 1 end
  return r
end

clientRequestSync = function()
  local S = mySession()
  if not S or S.isHost or S.phase == "done" or S.syncDead then return end
  local now = GetTime()
  if now - (S.lastSyncQ or 0) < SYNC_COOLDOWN or PG.Comm.Locked() then
    S.syncNeeded = true
    return
  end
  if PG.Comm.Whisper(S.host, "QZ", "SYNCQ", S.token, S.phase, appliedThrough(),
                     #S.roster, rosterDigest(S.roster)) then
    S.lastSyncQ = now
    S.syncNeeded = false
  else
    S.syncNeeded = true
  end
end

-- A resynced spectator rejoins once its mirror agrees with the host again. It
-- participates from the NEXT question (syncHoldR blocks the one already open at
-- heal time - it would have had less time than everyone else) and it earns
-- nothing for the rounds it sat out: every pattern it held carries X for a
-- player who could not answer. What those held patterns DO carry is everyone
-- else's points, and this is where they are finally counted - see applyResult.
local function maybeClearSpectator()
  local S = mySession()
  if not S or S.isHost or not S.spectator or S.syncDead then return end
  if S.phase ~= "play" or not S.count then return end
  if #S.roster ~= S.count then return end
  -- size agreement is not membership agreement, and the digest is always here to
  -- compare (BEGIN is refused without one), so a spectator can never be healed
  -- back into the game on the count check alone and start scoring other people.
  if rosterDigest(S.roster) ~= S.digest then return end
  local need = S.qOpen and (S.r - 1) or S.r
  if need < 0 then need = 0 end
  if appliedThrough() < need then return end
  local me = myName()
  if not (me and S.joined[me]) then
    toast("your join did not reach the host - you are not in this game.", S.host,
      { key = "qz-status" })
    endSession("You are not in this game.")
    evict(S.key)
    return
  end
  -- Credit the rounds that arrived while we were out of sync. They were received
  -- and retained but never scored, because until the two tests above passed
  -- nothing had PROVED our roster was the host's - and every pattern is
  -- positional over that roster. The digest match is that proof for the older
  -- rounds too: the host's roster is frozen at BEGIN (hostHandleJoin and
  -- hostHandleUnjoin both require the join phase), so one match covers every
  -- pattern this game has produced. Without this loop a healed client finishes
  -- with totals missing every round it spent desynced and persists medals for
  -- whoever led the rounds it did see; making the host replay those RESULTs
  -- instead is what SYNC_MAX_REPLAY cannot afford on top of the JOINED/LEFT
  -- stream. bumpStats stays out of it: a round spent out of sync is not a round
  -- this player answered, which is why applyResult never counted one either.
  for hr = 1, MAX_ROUNDS do
    local pat = S.heldResults[hr]
    if pat then
      S.heldResults[hr] = nil
      -- a pattern that does not fit the roster we just proved is creditable to
      -- nobody: pay no one rather than pay by index
      if #pat == #S.roster then
        for i, name in ipairs(S.roster) do
          S.totals[name] = (S.totals[name] or 0) + (POINTS[pat:sub(i, i)] or 0)
        end
      end
    end
  end
  S.spectator = false
  if S.qOpen and S.r >= 1 then S.syncHoldR = S.r end
  toast("back in sync - you are back in the game.", S.host, { key = "qz-status" })
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

local function busyToast(host)
  local now = GetTime()
  if (now - busyToastAt) < BUSY_THROTTLE then
    busyPending = busyPending + 1
    return
  end
  if (now - busyToastAt) > (BUSY_THROTTLE * 2) then busyPending = 0 end
  busyToastAt = now
  if busyPending > 0 then
    local n = busyPending + 1
    busyPending = 0
    toast(n .. " more games are open - see the Pengyou Games window.", host)
  else
    toast(shortOf(host) .. " started a game - you're in another game right now."
      .. " It's in the Pengyou Games window.", host, { key = "qz-busy" })
  end
end

local function overflowToast()
  local now = GetTime()
  if (now - overflowToastAt) < BUSY_THROTTLE then return end
  overflowToastAt = now
  toast("another game is open - see the Pengyou Games window.", nil, { key = "qz-busy" })
end

-- The version gate is silent at guild and public scope by design: a wide-scope
-- session that vanishes is not worth a line on everyone's screen. At GROUP
-- scope a silent failure is a bug report ("nobody can join my quiz"), so the
-- group gets the one line that explains it, throttled.
local function verToast(host)
  local now = GetTime()
  if (now - verToastAt) < VER_TOAST_THROTTLE then return end
  verToastAt = now
  toast(shortOf(host) .. "'s question pack is a different version - update Pengyou Games to play together.",
    host, { key = "qz-ver" })
end

-- Names the pot so the invitation is honest about what you are agreeing to.
local function inviteModes(modes)
  local n, only = 0, nil
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    if modes[m] then
      n = n + 1
      only = only or m
    end
  end
  if n == 1 then return MODE_NAME[only] end
  if n >= 4 then return "all four games" end
  return "mixed"
end

local function raiseInvite(rec)
  listOpen(rec)     -- every lite record gets a launcher row, at every scope
  if PG.Session.IsSeated() then
    if rec.scope == "group" then busyToast(rec.host) end
    return          -- guild and public stay silent while busy
  end
  if rec.scope == "public" then return end          -- never a popup (SCOPE.md 6.3)
  -- SCOPE.md 6.3: at most one guild popup per sender per 60s and three per
  -- five minutes. The counter lives in Widgets, next to AskCount, because the
  -- budget is on the user's SCREEN and not on a module.
  if rec.scope == "guild" and PG.UI.GuildAskOK and not PG.UI.GuildAskOK(rec.host) then
    return
  end
  if PG.UI.AskCount() >= (PG.UI.ASK_MAX or 3) then
    if rec.scope == "group" then overflowToast() end
    return
  end
  local askKey = "QZ:" .. rec.key
  local acceptLabel = "Play"
  local m = quizMark()
  if m ~= "" then acceptLabel = m .. " Play" end
  local where = ""
  if rec.scope == "guild" then where = " (guild)"
  elseif rec.scope == "public" then where = " (public)" end
  local ok, why = PG.UI.Ask(askKey,
    shortOf(rec.host) .. " started a Quiz" .. where .. " - "
      .. rec.cfg.rounds .. " questions, " .. inviteModes(rec.cfg.modes) .. ". Play?",
    acceptLabel, "Pass", math.max(1, rec.expires - GetTime()),
    function() clientAccept(rec) end,
    function() if sessions[rec.key] == rec then rec.askKey = nil end end,
    "QZ")
  if ok then
    rec.askKey = askKey
    if rec.scope == "guild" and PG.UI.GuildAskSpend then
      PG.UI.GuildAskSpend(rec.host)
    end
  elseif why == "full" and rec.scope == "group" then
    overflowToast()
  end
end

-- 4.3: the newest OPEN from a given host replaces that host's previous session
-- on every client, unconditionally, at any age.
local function supersede(host, newToken)
  for k, rec in pairs(sessions) do
    if rec.host == host and rec.token ~= newToken then
      local keepWindow = (rec.kind == "full" and rec.phase == "done")
      if rec.kind == "full" and rec.phase ~= "done" then
        toast(shortOf(host) .. " started a new game - your previous game is over.",
          host, { priority = "result" })
        endSession("The host started a new game.")
      end
      evict(k, keepWindow)
    end
  end
end

local function makeLiteRoom()
  local victim, oldest, anyVictim, anyOldest
  for k, rec in pairs(sessions) do
    if rec.kind == "lite" then
      local asking = rec.askKey ~= nil
      if PG.UI.IsAsking then asking = PG.UI.IsAsking(rec.askKey) end
      if not asking and (not oldest or rec.openedAt < oldest) then
        victim, oldest = k, rec.openedAt
      end
      if not anyOldest or rec.openedAt < anyOldest then
        anyVictim, anyOldest = k, rec.openedAt
      end
    end
  end
  victim = victim or anyVictim
  if not victim then return false end
  evict(victim)
  return true
end

-- The inbound OPEN decision table (4.2), evaluated in order, with one row
-- inserted for the question pack.
local function onOpen(token, sender, scope, f1, f2, f3, f4, f5, f6, f7)
  if sender == myName() then return end                     -- row 1
  -- row 2 (SCOPE.md 3.1 / BRIEF 4.4): the declared scope exists to be CHECKED
  -- against the delivered distribution, never trusted. A wire field can claim
  -- guild on a party message; a distribution cannot. The scope code is the LAST
  -- field, so it is f7 here - one field further than RPS, which is exactly the
  -- arity mistake BRIEF 4.3 exists to prevent.
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f7))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end                     -- an OPEN never whispers
  if not PG.QZ.SCOPES[scope] then return end
  -- row 2b, THE PACK GATE. An index is meaningless against a different bank, so
  -- a client that cannot resolve indices must not construct state at all: no
  -- lite record, no popup, no launcher row.
  local mine_ver = Bank.dataVersion()
  local ver = num(f6, 0, 9999)
  if not mine_ver or not ver then return end
  if ver ~= mine_ver then
    if scope == "group" then verToast(sender) end
    return
  end
  local rounds = num(f1, 1, MAX_ROUNDS)
  local joinSecs = num(f2, 5, 600)
  local answerSecs = num(f3, MIN_ANSWER_SECS, MAX_ANSWER_SECS)
  local mask = num(f4, 1, 15)
  local hints = num(f5, 0, 1)
  if not (rounds and joinSecs and answerSecs and mask and hints) then return end
  local modes = {}
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    -- integer bit test without bitlib: the four bits are 1/2/4/8 and mask is
    -- validated 1..15, so plain arithmetic is exact and portable
    modes[m] = (math.floor(mask / MODE_BIT[m]) % 2) == 1
  end
  local key = keyOf(sender, token)
  if isRecent(key) then return end                          -- row 3
  local now = GetTime()
  local existing = sessions[key]
  if existing then                                          -- row 4: idempotent
    if existing.kind == "lite" then
      existing.expires = now
        + math.max(LITE_TTL_MIN, math.min(LITE_TTL_MAX, joinSecs)) + LITE_TTL_PAD
    end
    return
  end
  supersede(sender, token)                                  -- row 5
  if liteCount >= MAX_LITE and not makeLiteRoom() then return end  -- row 6
  local rec = {                                             -- row 7
    kind = "lite",
    key = key,
    token = token,
    host = sender,
    scope = scope,
    cfg = { rounds = rounds, joinSecs = joinSecs, answerSecs = answerSecs,
            modes = modes, hints = hints == 1, ver = ver },
    openedAt = now,
    expires = now
      + math.max(LITE_TTL_MIN, math.min(LITE_TTL_MAX, joinSecs)) + LITE_TTL_PAD,
  }
  register(rec)
  raiseInvite(rec)
end

-- Gate h (5.2). A lite record holds no roster, no totals, no answers, no
-- history, no ticker and no frame, and it never reaches an applier.
local function liteObserve(rec, mtype)
  if mtype == "HB" then
    rec.expires = math.max(rec.expires, GetTime() + LITE_TTL_PAD)
  elseif mtype == "BEGIN" or mtype == "CANCEL" or mtype == "END" then
    evict(rec.key)
  end
end

local HOST_AUTHORED = {
  HB = true, JOINED = true, LEFT = true, BEGIN = true, QSTN = true,
  RESULT = true, VOID = true, END = true, CANCEL = true,
  SYNCOK = true, SYNCNO = true,
}
local CLIENT_AUTHORED = { JOIN = true, UNJOIN = true, ANS = true, SYNCQ = true }

-- The only host-authored messages that legitimately arrive by WHISPER: the
-- resync replay (hostHandleSyncQ pushes exactly JOINED / LEFT / BEGIN / RESULT /
-- QSTN) and its two answers. HB, VOID, END and CANCEL are broadcast-only by
-- construction - hostCancel, hostVoid, hostEnd and the heartbeat tick all go out
-- at the session scope and this module never replays them - so a whispered one
-- is a PRIVATE VIEW of a game everybody else is watching a different version of.
-- WHAT BREAKS WITHOUT THIS (all four measured, not argued):
--   CANCEL - the victim alone is told the quiz was cancelled, records nothing,
--            and watches everyone else bank the medals for a game she was in.
--   END    - the victim alone settles EARLY, on a partial tally, and persists a
--            medal for whoever happened to lead at that moment rather than the
--            player who actually won.
--   VOID   - the victim alone has the open question torn down and her typed
--            answer wiped, so she is the only one who cannot score this round.
--   HB     - a host that has gone silent to the group keeps ONE client's 35s
--            watchdog suppressed, so it never declares the host dead.
-- This closes nothing the host can already do by broadcast: a broadcast CANCEL
-- or END is the same message to everybody, which is exactly the property the
-- whisper takes away.
local WHISPERABLE = {
  JOINED = true, LEFT = true, BEGIN = true, RESULT = true, QSTN = true,
  SYNCOK = true, SYNCNO = true,
}

-- BRIEF 4.3: declare enough parameters for the LARGEST message and one spare.
-- The widest are OPEN (rounds, joinSecs, answerSecs, mask, hints, ver, scope)
-- and QSTN (r, m, a, b, c, seed, secs), both SEVEN fields after the token.
-- Comm.lua dispatches unpack(parts, 5), so the fields are there - a handler
-- that declares too few silently reads nil and drops every OPEN and errors on
-- the first question.
local function onComm(mtype, token, sender, scope, f1, f2, f3, f4, f5, f6, f7, f8)
  token = validToken(token)                                  -- 3.4
  if not token then return end
  if mtype == "OPEN" then
    return onOpen(token, sender, scope, f1, f2, f3, f4, f5, f6, f7)
  end

  local rec
  if HOST_AUTHORED[mtype] then
    -- gate g: identity is the PAIR. Sender authority (gate j) is free here -
    -- sender IS rec.host, because it is half the key.
    rec = sessions[keyOf(sender, token)]
  elseif CLIENT_AUTHORED[mtype] then
    local m = mySession()
    if m and m.isHost and m.token == token and scope == "private" then rec = m end
  else
    return                                                   -- unknown mtype
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype) end
  if rec ~= mySession() then return end   -- I3: the only full record is involved
  if rec.phase == "done" then return end                     -- gate k
  -- gate i: "private" is exempt because resync replays of BEGIN/RESULT/QSTN
  -- legitimately arrive by whisper - and only those (see WHISPERABLE). A
  -- client-authored message is always private (checked at gate g above), so the
  -- HOST_AUTHORED test is what keeps JOIN/UNJOIN/ANS/SYNCQ coming through.
  if scope == "private" then
    if HOST_AUTHORED[mtype] and not WHISPERABLE[mtype] then return end
  elseif scope ~= rec.scope then return end

  local S = rec
  if S.isHost then
    if mtype == "JOIN" then
      hostHandleJoin(sender)
    elseif mtype == "UNJOIN" then
      hostHandleUnjoin(sender)
    elseif mtype == "ANS" then
      local r = num(f1, 1, MAX_ROUNDS)
      local tenths = num(f2, 0, MAX_ANSWER_SECS * 10)
      local text = PG.SafeStr(f3)
      if r and tenths and text and text ~= "" and #text <= ANS_MAX then
        hostHandleAnswer(sender, r, tenths, text)
      end
    elseif mtype == "SYNCQ" then
      hostHandleSyncQ(sender, PG.SafeStr(f1), num(f2, 0, MAX_ROUNDS),
                      num(f3, 0, ROSTER_CAP), PG.SafeStr(f4))
    end
    return
  end
  -- sender == S.host is guaranteed by gate g's key
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  S.hostQuiet = false
  if S.phase == "join"
    and (mtype == "QSTN" or mtype == "RESULT" or mtype == "VOID" or mtype == "END") then
    -- we missed BEGIN entirely: spectate for now and ask the host to replay
    S.phase = "play"
    S.spectator = true
    toast("out of sync with the host - resyncing...", S.host, { key = "qz-status" })
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
    local count = num(f1, 2, ROSTER_CAP)
    local rounds = num(f2, 1, MAX_ROUNDS)
    local dig = PG.SafeStr(f3)
    -- The digest is MANDATORY, exactly as in DeathRoll: this module shipped
    -- with it from its first version, so there are no pre-digest peers to
    -- tolerate, and accepting a BEGIN without one silently demotes the whole
    -- agreement test to a count comparison - the one thing rosterDigest exists
    -- to prevent, medals included.
    if count and rounds and isDigest(dig) then
      applyBegin(count, rounds, dig)
    end
  elseif mtype == "CANCEL" then
    applyCancel(PG.SafeStr(f1) or "?")
  elseif mtype == "QSTN" then
    local r = num(f1, 1, MAX_ROUNDS)
    local m = PG.SafeStr(f2)
    local secs = num(f7, 1, 600)
    local seed = num(f6, 1, 65535)
    if r and m and VALID_MODE[m] and seed and secs then
      local a = Bank.validSlotField(f3, m)
      local b = Bank.validSlotField(f4, m)
      local c = Bank.validSlotField(f5, m)
      if a and b and c then
        if r > S.r + 1 then clientRequestSync() end -- unexpected round
        applyQuestion(r, m, a, b, c, seed, secs)
      end
    end
  elseif mtype == "RESULT" then
    local r = num(f1, 1, MAX_ROUNDS)
    local pattern = PG.SafeStr(f2)
    if r and pattern and validPattern(pattern) then
      if r > S.r then clientRequestSync() end -- result for a round we never saw
      applyResult(r, pattern)
    end
  elseif mtype == "VOID" then
    local r = num(f1, 1, MAX_ROUNDS)
    if r then applyVoid(r) end
  elseif mtype == "END" then
    applyEnd()
  elseif mtype == "SYNCOK" then
    S.syncNeeded = false
  elseif mtype == "SYNCNO" then
    if not S.syncDead then
      S.syncDead = true
      S.syncNeeded = false
      if not S.spectator then
        S.spectator = true
        toast("too far out of sync to catch up - spectating this game.", S.host,
          { key = "qz-status" })
      end
      RefreshUI()
    end
  end
  maybeClearSpectator()
end

-- An OUTGOING message of ours was permanently dropped by the comms lockdown.
-- ANS and the SYNC family are deliberately NOT critical: a dropped ANS scores
-- an X, and a dropped SYNC message means the client asks again later.
local CRITICAL_DROP = {
  OPEN = true, JOINED = true, LEFT = true, BEGIN = true,
  QSTN = true, RESULT = true, VOID = true, END = true,
}

local REPLAYABLE = {
  JOINED = true, LEFT = true, BEGIN = true, RESULT = true, QSTN = true,
}

local function onDrop(mtype, token)
  local S = mySession()
  if not (S and S.isHost and S.phase ~= "done") then return end
  local me = myName()
  local t = validToken(token)
  if not (me and t) or keyOf(me, t) ~= S.key then return end
  if not CRITICAL_DROP[mtype] then return end
  if REPLAYABLE[mtype] and S.syncReplayUntil and GetTime() < S.syncReplayUntil then return end
  toast("game aborted - addon messages were blocked mid-send.", S.host)
  endSession("Aborted - addon messages were blocked.")
end

-------------------------------------------------------------------------------
-- Safety transitions. Encounter/restriction breaks the open question (VOID once
-- clear, then a NEW question for the same round number); ready check / countdown
-- merely freezes its timer. Plain combat is deliberately NOT here.
--
-- The edit box loses focus on every _ON trigger EXCEPT plain combat, host and
-- client alike, before anything else: those triggers do hide the window through
-- Core's Safety machinery, and a focused box behind a hidden frame eats
-- keystrokes invisibly. COMBAT_ON is excluded because Core runs its safety
-- callbacks unconditionally while it hides for plain combat ONLY when
-- profile.hideInCombat is on (it defaults off), so on the default setting the
-- window is still on screen: unfocusing it mid-answer sends the rest of what
-- the player is typing to their keybinds during a pull, and nothing in this
-- addon ever calls SetFocus to hand the box back.
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
  local isOn = trigger:match("_ON$") ~= nil
  if isOn and trigger ~= "COMBAT_ON" then clearFocus() end
  local S = mySession()
  if not S or S.phase == "done" then return end
  if not S.isHost then
    if trigger == "ENCOUNTER_ON" then
      -- discard the pending, UNSENT answer; the host will void this question
      if not S.myLocked then
        S.myAnswer = nil
        if ui.entry then ui.entry:SetText("") end
      end
    end
    -- resync trigger: the session just emerged from a safety interruption
    local cur = allClear()
    if cur and S.syncAllClear == false then S.syncNeeded = true end
    S.syncAllClear = cur
    return
  end
  if not isOn then return end
  if trigger == "COMBAT_ON" then return end
  if S.phase == "join" then
    if not S.joinFrozen then
      S.joinFrozen = true
      S.joinRemaining = math.max(0, (S.joinDeadline or GetTime()) - GetTime())
    end
  elseif S.phase == "play" and S.qOpen then
    if trigger == "ENCOUNTER_ON" or trigger == "RESTRICT_ON" then
      S.broken = true -- this question is dead; VOID + a new one after the fight
      S.frozen = false
      S.answers = {}
      S.answerCount = 0
      S.myAnswer = nil
      S.myLocked = false
    elseif not S.broken and not S.frozen then
      S.frozen = true
      S.freezeRemaining = math.max(0, (S.deadline or GetTime()) - GetTime())
    end
  end
end

-------------------------------------------------------------------------------
-- Master ticker: host timing (join window, answer deadline, void/reopen/end
-- retries, heartbeat) and the client-side host-death watchdog.
-------------------------------------------------------------------------------

local function sweepRegistry()
  local now = GetTime()
  for key, rec in pairs(sessions) do
    if rec.kind == "lite" then
      if now >= rec.expires then evict(key) end
    elseif rec.phase == "done" and rec.doneAt and (now - rec.doneAt) > DONE_TTL then
      evict(key)
    end
  end
  for key, t in pairs(recent) do
    if (now - t) > RECENT_TTL then recent[key] = nil end
  end
  local i = 1
  while i <= #recentQ do
    if recent[recentQ[i]] == nil then table.remove(recentQ, i) else i = i + 1 end
  end
end

onTick = function()
  sweepTicks = sweepTicks + 1
  if sweepTicks >= SWEEP_EVERY then
    sweepTicks = 0
    sweepRegistry()
  end
  local S = mySession()
  if not S or S.phase == "done" then
    if win and win:IsShown() then RefreshUI() end
    return
  end
  local now = GetTime()
  if S.isHost then
    -- Scope-aware host abort (SCOPE.md 6.1). The 8s grace is essential: a
    -- temporary channel is dropped across EVERY loading screen.
    local okScope, why = PG.Comm.ScopeAvailable(S.scope, 8)
    if not okScope then
      why = why or "That audience is gone."
      toast(why .. " Game abandoned.", S.host)
      endSession("Abandoned - " .. why)
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
      -- THE PLAY-PHASE FREEZE IS POLLED HERE, not left to onSafetyChange, on
      -- the same predicate that stops the sends. Two holes otherwise, and both
      -- end the round with an all-"X" RESULT nobody could have beaten. First,
      -- the 12.1 comms lockdown of an M+ run or a PvP match raises no PG.Safety
      -- transition at all, so nothing would ever fire while every ANS whisper
      -- is being refused. Second, QSTN is applied from BroadcastEx's onSent
      -- (see hostStartQuestion), so a question queued behind the token bucket
      -- can OPEN after a ready check has already started - onSafetyChange saw
      -- S.qOpen false, froze nothing, and will not fire again for that state
      -- while the answer window burns down behind a window Core has hidden.
      if S.qOpen and not S.broken and not S.frozen
        and not (allClear() and not PG.Comm.Locked()) then
        S.frozen = true
        S.freezeRemaining = math.max(0, (S.deadline or now) - now)
      end
      if S.broken then
        if allClear() and not PG.Comm.Locked() then hostVoidRound() end
      elseif S.frozen then
        if allClear() and not PG.Comm.Locked() and not S.qPending then
          hostReopenQuestion()
        end
      elseif S.endPending then
        if allClear() and not PG.Comm.Locked() then hostEnd() end
      elseif S.qOpen then
        -- the deadline OR a Reveal-now press whose broadcast was refused. The
        -- full gate is re-tested rather than inferred from the freeze above:
        -- scoring a window the players were locked out of is the exact outcome
        -- that freeze exists to prevent, so it is denied twice.
        if (now >= (S.deadline or 0) or S.resolveNow)
          and allClear() and not PG.Comm.Locked() then
          hostResolveRound()
        end
      elseif S.nextQAt and now >= S.nextQAt and not S.qPending
        and allClear() and not PG.Comm.Locked() then
        S.nextQAt = nil
        hostStartQuestion(S.r + 1)
      end
    end
  else
    local st = PG.Safety.state
    if st.inEncounter or st.restricted or PG.Comm.Locked() then
      -- the host cannot legally heartbeat here: suspend the watchdog instead of
      -- declaring the host dead
      S.lastHB = (S.lastHB or now) + TICK
    else
      local quiet = now - (S.lastHB or now)
      if S.scope == "group" then
        if quiet > HB_TIMEOUT then
          clientHostDead()
          return
        end
      else
        -- SCOPE.md 6.2: silence is treated as paused first and dead much later
        if quiet > HB_GIVEUP_WIDE then
          clientHostDead()
          return
        end
        if quiet > HB_QUIET_WIDE then
          if not S.hostQuiet then
            S.hostQuiet = true
            RefreshUI()
          end
          if (now - (S.quietSyncAt or 0)) > QUIET_SYNC_EVERY then
            S.quietSyncAt = now
            clientRequestSync()
          end
        end
      end
    end
    if S.syncNeeded and allClear() then clientRequestSync() end
  end
  -- also what makes the halfway hint appear, with no timer of its own
  if win and win:IsShown() then RefreshUI() end
end

-------------------------------------------------------------------------------
-- FX (faire carnival garnish). Pure decoration behind runFX: text state is
-- always final BEFORE any of this plays.
-------------------------------------------------------------------------------

FX.joined = function(name)
  if not (win and win:IsShown()) then return end
  if name == myName() then Theme.Sound("click") end
end

FX.begin = function()
  local S = mySession()
  if not (win and win:IsShown() and S) then return end
  Theme.Banner(win, S.rounds .. " QUESTIONS", "QZ")
  Theme.Sound("stamp")
end

FX.question = function()
  if not (win and win:IsShown()) then return end
  Theme.Sound("page")
end

FX.submit = function()
  if not (win and win:IsShown()) then return end
  if ui.entry then Theme.Pulse(ui.entry) end
  Theme.Sound("click")
end

FX.void = function()
  if not (win and win:IsShown()) then return end
  Theme.Stamp(win, "QUESTION VOID")
  Theme.Sound("coincancel")
end

-- name -> dense place BEFORE this round's points landed, using the same
-- comparator and dense ranking computeStandings uses. Presentation only.
local function revealPrevPlaces(pattern)
  local S = mySession()
  if not S then return {} end
  local list = {}
  for i, name in ipairs(S.roster) do
    local c = pattern:sub(i, i)
    list[#list + 1] = { name = name,
                        pts = (S.totals[name] or 0) - (POINTS[c] or 0) }
  end
  table.sort(list, function(a, b)
    if a.pts ~= b.pts then return a.pts > b.pts end
    return a.name < b.name
  end)
  local out, place, lastPts = {}, 0, nil
  for i = 1, #list do
    if list[i].pts ~= lastPts then
      place = place + 1
      lastPts = list[i].pts
    end
    out[list[i].name] = place
  end
  return out
end

FX.result = function()
  local S = mySession()
  if not (win and win:IsShown() and S and S.lastResult) then return end
  local lr = S.lastResult
  local rows, marquee, scored = {}, nil, 0
  if S.spectator then
    rows[1] = { text = "Out of sync - standings unavailable.", role = "fade" }
  else
    local me = myName()
    local mapped = (#lr.pattern == #S.roster)
    local charOf = {}
    if mapped then
      for i, name in ipairs(S.roster) do charOf[name] = lr.pattern:sub(i, i) end
    end
    local prev = mapped and revealPrevPlaces(lr.pattern) or nil
    local standings = computeStandings()
    local leaders = 0
    for i = 1, #standings do
      local e = standings[i]
      local text = e.place .. ". " .. e.name .. "  -  " .. e.pts .. " pts"
      local c = charOf[e.name]
      if c == "X" then
        text = text .. "  " .. P.chgray .. "no answer|r"
      elseif c == "W" then
        text = text .. "  " .. P.chgray .. "wrong|r"
      elseif c then
        local g = POINTS[c] or 0
        scored = scored + g
        text = text .. "  " .. P.chgreen .. "+" .. g .. "|r"
        if c == "1" then text = text .. " " .. P.chgold .. "fastest|r" end
      end
      local was = prev and prev[e.name]
      if was and was ~= e.place then
        text = text .. "  " .. ((e.place < was)
          and (P.chgreen .. "^" .. (was - e.place) .. "|r")
          or (P.chred .. "v" .. (e.place - was) .. "|r"))
      end
      if e.place == 1 then leaders = leaders + 1 end
      rows[#rows + 1] = { text = text,
                          role = (e.place == 1) and "gold" or "body",
                          personal = (e.name == me) }
    end
    if lr.fastest then
      marquee = shortOf(lr.fastest):upper() .. " WAS FASTEST"
    elseif standings[1] then
      marquee = (leaders > 1) and (leaders .. "-WAY TIE FOR THE LEAD")
        or (shortOf(standings[1].name):upper() .. " LEADS")
    end
  end
  local sess = S
  local modeName = (S.qView and MODE_NAME[S.qView.m]) or "Quiz"
  Theme.Reveal({
    game = "QZ",
    anchor = { mode = "window", host = win },
    title = "QUESTION " .. lr.r,
    subtitle = modeName .. " - " .. lr.nCorrect .. " of "
      .. (#lr.pattern) .. " correct",
    rows = rows,
    marquee = marquee,
    burst = (scored > 0) and "stars" or "none",
    burstCount = 8,
    sound = ((lr.myGain or 0) > 0) and "settled" or "page",
    -- ownership (CONCURRENCY.md 5.8 rule 2)
    validate = function() return sessions[sess.key] == sess end,
    -- precedence (rule 3): the session we PLAY outranks one we referee
    priority = sess.seated and 1 or 0,
  })
end

FX.podium = function()
  local S = mySession()
  if not (win and win:IsShown() and S) then return end
  local sess = S
  local me = myName()
  local subtitle = S.rounds .. " questions"
  local rows, marquee, won = {}, nil, false
  if S.spectator then
    rows[1] = { text = "Out of sync - standings unavailable.", role = "fade" }
  else
    local standings = S.standings or computeStandings()
    local champ, winners = nil, 0
    for i = 1, #standings do
      local e = standings[i]
      if e.place == 1 then
        winners = winners + 1
        champ = champ or e.name
        if e.name == me then won = true end
      end
      rows[#rows + 1] = {
        text = e.place .. ". " .. e.name .. "  -  " .. e.pts .. " pts",
        role = (e.place == 1 and "gold") or (e.place == 2 and "silver")
          or (e.place == 3 and "bronze") or (((e.pts or 0) > 0) and "body")
          or "fade",
        place = (e.place <= 3) and e.place or nil,
        personal = (e.name == me),
      }
    end
    if champ then
      marquee = shortOf(champ):upper()
        .. ((winners > 1) and " AND FRIENDS TIE" or " TAKES THE CROWN")
    end
    if me and S.joined[me] then
      subtitle = subtitle .. " - your medals: " .. myMedalCount()
    end
  end
  Theme.RevealQueue({
    game = "QZ",
    anchor = { mode = "window", host = win },
    variant = "podium",
    title = "FINAL RESULTS",
    subtitle = subtitle,
    rows = rows,
    marquee = marquee,
    burst = "stars",
    burstCount = 12,
    sound = won and "cheer" or "page",
    burstSound = "fanfare",
    validate = function() return sessions[sess.key] == sess and sess.ended == true end,
    priority = sess.seated and 1 or 0,
  })
end

-------------------------------------------------------------------------------
-- Game window
-------------------------------------------------------------------------------

-- This window's own layout, on the shared 4px grid (Theme.METRIC.GRID). The
-- answer block chains off the question block, so only these two are absolute.
local WIN_W, WIN_H = 420, 620
local ROSTER_Y = -380
local PROMPT_Y, PROMPT_H = -108, 44
local STMT_Y, STMT_H, STMT_GAP = -156, 24, 4
local PROMPT_BOTTOM = PROMPT_Y - PROMPT_H                      -- -152
local STMT_BOTTOM = STMT_Y - 3 * STMT_H - 2 * STMT_GAP         -- -236

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

local function chalk(fs)
  fs:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  if Theme then Theme.Shadow(fs) end
end

local function wrapped(parent, y, h, lines, role, color)
  local inset = mt("INSET")
  local fs = parent:CreateFontString(nil, "OVERLAY", ft(role or "S"))
  fs:SetPoint("TOPLEFT", inset, y)
  fs:SetPoint("TOPRIGHT", -inset, y)
  fs:SetHeight(h)
  fs:SetJustifyH("LEFT")
  -- critique-1 C4: without an explicit TOP the prompt renders vertically
  -- centred in its box and a one-line prompt lands on top of the statements.
  fs:SetJustifyV("TOP")
  fs:SetWordWrap(true)
  fs:SetMaxLines(lines)
  local c = color or P.CHALK
  fs:SetTextColor(c[1], c[2], c[3])
  if Theme then Theme.Shadow(fs) end
  return fs
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("qz", "Quiz", WIN_W, WIN_H, "QZ")
  win.__pgResume = function() return mySession() ~= nil end

  local inset = mt("INSET")

  -- the audience, under the title (SCOPE.md 5.4)
  ui.scope = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.scope:SetPoint("TOPLEFT", inset, mt("AUD_Y"))
  ui.scope:SetPoint("TOPRIGHT", -inset, mt("AUD_Y"))
  ui.scope:SetJustifyH("CENTER")
  ui.scope:SetWordWrap(false)
  ui.scope:SetMaxLines(1)
  ui.scope:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(ui.scope) end

  -- -52, not -44: the audience line above it is 12px tall from -34, so the two
  -- shared a 2px band in every state where the info block ran long.
  ui.info = wrapped(win, -52, 28, 2, "B", P.CHGOLD)

  ui.bar = PG.UI.TimerBar(win, WIN_W - 2 * inset)
  ui.bar:SetPoint("TOPLEFT", inset, -84)

  -- The prompt box ends at PROMPT_BOTTOM and the first statement starts 4px
  -- below it, so the two can never overlap whatever the prompt's line count
  -- turns out to be.
  ui.prompt = wrapped(win, PROMPT_Y, PROMPT_H, 3, "B", P.CHGOLD)
  ui.stmt = {}
  for i = 1, 3 do
    ui.stmt[i] = wrapped(win, STMT_Y - (i - 1) * (STMT_H + STMT_GAP), STMT_H, 2, "S")
  end
  ui.hint = wrapped(win, STMT_BOTTOM - 4, 14, 1, "S", P.CHGRAY)

  -- THE EDIT BOX. SetAutoFocus(false) is not polish: an autofocused box eats
  -- every keystroke including movement keys, and this window can be hidden out
  -- from under a focused box by the Safety machinery at any moment.
  ui.entry = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
  ui.entry:SetSize(280, 22)
  ui.entry:SetPoint("TOPLEFT", inset, STMT_BOTTOM - 24)   -- layoutAnswer re-anchors
  ui.entry:SetAutoFocus(false)
  ui.entry:SetMaxLetters(ANS_MAX)
  ui.entry:SetTextInsets(4, 4, 0, 0)
  ui.entry:SetScript("OnEnterPressed", function(self)
    -- Enter releases the box the way it does everywhere else in the UI, EXCEPT
    -- when the lockdown refused the whisper. That refusal is a real outcome
    -- with a real toast now, and the player's next move is to press Enter again
    -- when the lockdown lifts; taking the focus away first makes them click
    -- back into the box before they can retype a word of it.
    if doSubmit(self:GetText()) then return end
    self:ClearFocus()
  end)
  -- ESC only drops focus; the window itself is never in UISpecialFrames and
  -- ESC must not close it.
  ui.entry:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  ui.entry:SetScript("OnTextChanged", function(self)
    if not ui.submit then return end
    local S = mySession()
    local can = (S and S.phase == "play" and S.qOpen and S.seated and not S.spectator
      and not S.dataBad and not S.myLocked and S.syncHoldR ~= S.r
      and Bank.normalize(self:GetText()) ~= "") and true or false
    ui.submit:SetEnabled(can)
  end)
  win:HookScript("OnHide", clearFocus)

  ui.submit = PG.UI.Button(win, "Submit", 76, 22, function()
    if ui.entry then doSubmit(ui.entry:GetText()) end
  end)
  ui.submit:SetPoint("TOPRIGHT", -inset, STMT_BOTTOM - 24)

  -- Mode L wires the same doSubmit the typing path uses, so there is one lock
  -- and one code path. The box stays usable in mode L (typing "b" works); the
  -- buttons exist because clicking a letter is what people will try.
  ui.abc = {}
  for i = 1, 3 do
    local letter = SLOT_LETTER[i]
    local b = PG.UI.Button(win, letter, 60, 22, function() doSubmit(letter) end)
    b:SetPoint("TOPLEFT", inset + (i - 1) * 68, STMT_BOTTOM - 52)
    ui.abc[i] = b
  end

  ui.status = win:CreateFontString(nil, "OVERLAY", ft("B"))
  ui.status:SetPoint("TOPLEFT", inset, -316)
  ui.status:SetPoint("TOPRIGHT", -inset, -316)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(false)
  ui.status:SetMaxLines(1)
  chalk(ui.status)

  ui.reveal = wrapped(win, -336, 24, 2, "S")
  -- short, self-contained, celebratory, and alone on its line: centred (PLAN 4)
  ui.gain = win:CreateFontString(nil, "OVERLAY", ft("S"))
  ui.gain:SetPoint("TOPLEFT", inset, -364)
  ui.gain:SetPoint("TOPRIGHT", -inset, -364)
  ui.gain:SetJustifyH("CENTER")
  ui.gain:SetWordWrap(false)
  ui.gain:SetMaxLines(1)
  chalk(ui.gain)

  -- The empty state is NOT list item zero: its own centred line across the
  -- standings band instead of row 1's left inset (PLAN 4).
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
  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", btnW, btnH, function()
    local S = mySession()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "QZ", "UNJOIN", S.token)
      -- the local press is authoritative for this client (7.2)
      applyLeft(myName())
    end
  end)
  ui.withdrawBtn:SetPoint("BOTTOMLEFT", inset, foot) -- shares the Start slot
  ui.revealBtn = PG.UI.Button(win, "Reveal now", btnW, btnH, function()
    hostRevealNow()
  end)
  ui.revealBtn:SetPoint("BOTTOMRIGHT", -inset, foot)
  ui.cancelBtn = PG.UI.Button(win, "Cancel game", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and live() then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOMRIGHT", -inset, foot) -- shares the Reveal-now slot
  ui.againBtn = PG.UI.Button(win, "Play again", btnW, btnH, function()
    local S = mySession()
    if S and S.isHost and S.phase == "done" and S.ended then
      hostOpen(S.rounds, S.joinSecs, S.answerSecs, S.modes, S.hints, S.scope)
    end
  end)
  ui.againBtn:SetPoint("BOTTOM", 0, foot)

  if Theme then
    win.__pgBannerSlot = rowAt(1) -- banners slide in over the standings area
  end
end

-- THE ANSWER BLOCK FOLLOWS THE QUESTION.
--
-- The three statement lines exist only in mode "L", and their 84px used to stay
-- reserved in every other mode: the window showed the question, then an empty
-- band the height of a paragraph, then the box you type into. The hint, the
-- entry row and the letter buttons now hang off whichever bottom the question
-- block actually has. Everything below (status, reveal, gain, standings) keeps
-- its absolute slot on purpose - the standings must not jump 100px between one
-- question and the next.
--
-- Re-anchored only when the shape changes, so the 1s refresh does no work.
local function layoutAnswer(isL)
  if ui.__answerL == isL then return end
  ui.__answerL = isL
  local inset = mt("INSET")
  local y = isL and STMT_BOTTOM or PROMPT_BOTTOM
  ui.hint:ClearAllPoints()
  ui.hint:SetPoint("TOPLEFT", inset, y - 4)
  ui.hint:SetPoint("TOPRIGHT", -inset, y - 4)
  ui.entry:ClearAllPoints()
  ui.entry:SetPoint("TOPLEFT", inset, y - 24)
  ui.submit:ClearAllPoints()
  ui.submit:SetPoint("TOPRIGHT", -inset, y - 24)
  for i = 1, 3 do
    ui.abc[i]:ClearAllPoints()
    ui.abc[i]:SetPoint("TOPLEFT", inset + (i - 1) * 68, y - 52)
  end
end

local SCOPE_HEADER = { group = "Party", guild = "Guild", public = "Public - realm-wide" }

-- An answer may be ANS_MAX (64) characters; the status line is one line wide.
-- Truncate the ANSWER, never the state cue after it - "Locked:" with a clipped
-- word and no "waiting for the reveal" is the half of the line that matters.
local ANS_SHOWN = 24
local function shortAnswer(a)
  a = tostring(a or "")
  if #a > ANS_SHOWN then return a:sub(1, ANS_SHOWN) .. "..." end
  return a
end

RefreshUI = function()
  local S = mySession()
  if not win or not S then return end
  win.__pgRec = S            -- 5.9: the window is bound to the involved record
  local now = GetTime()
  local me = myName()
  local isJoin = S.phase == "join"
  local isPlay = S.phase == "play"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false
  local refereed = (S.isHost and not S.seated) and true or false
  -- The resolved question stays on screen through the reveal pause (S.q is only
  -- cleared by a VOID), which is what lets the answer line be read next to the
  -- question it answers.
  local view = (isPlay and S.qView) or nil
  local showQ = (isPlay and S.q ~= nil) and true or false

  ui.scope:SetText(SCOPE_HEADER[S.scope] or "")

  if isJoin then
    local second = #S.roster .. " in so far"
    -- CONCURRENCY.md 6.3: no BUSY message exists, so the host is shown who else
    -- here runs the addon (PG.Peers, populated by CO HELLO, group-scoped and
    -- pruned against the live group since 1.1.0).
    if S.isHost and S.scope == "group" then
      local peers = 0
      for _ in pairs(PG.Peers or {}) do peers = peers + 1 end
      if peers > 0 then
        second = #S.roster .. " of " .. (peers + 1) .. " addon users have joined"
      end
    end
    ui.info:SetText(S.rounds .. " questions - " .. S.answerSecs
      .. "s each|n" .. second)
  elseif isPlay then
    if S.r >= 1 then
      local mn = (S.qView and MODE_NAME[S.qView.m]) or (S.q and MODE_NAME[S.q.m]) or ""
      ui.info:SetText("Question " .. S.r .. " of " .. S.rounds
        .. (mn ~= "" and (" - " .. mn) or ""))
    else
      ui.info:SetText(S.rounds .. " questions - get ready...")
    end
  else
    ui.info:SetText(S.endText or "Game over.")
  end

  -- prompt + statements, rendered from the LOCAL bank
  local isL = (view ~= nil and view.m == "L")
  if showQ and view then
    ui.prompt:SetText(Bank.promptOf(view, S.q.seed))
  elseif showQ and S.dataBad then
    ui.prompt:SetText(P.chgray .. "This question is not in your copy of the question pack.|r")
  else
    ui.prompt:SetText("")
  end
  for i = 1, 3 do
    if isL then
      ui.stmt[i]:SetText(SLOT_LETTER[i] .. ": " .. view.slots[i].text)
      ui.stmt[i]:Show()
    else
      ui.stmt[i]:SetText("")
      ui.stmt[i]:Hide()
    end
  end
  layoutAnswer(isL)   -- the answer block follows whichever bottom the question has

  -- the halfway hint, computed locally, with a single sound the first time
  local hintText = ""
  if S.hints and showQ and view and S.qOpen and S.qShownAt then
    if (now - S.qShownAt) >= (S.answerSecs or 20) * HINT_AT then
      hintText = Bank.hintOf(view, S.q.seed)
      if hintText ~= "" and not S.hintShown then
        S.hintShown = true
        if Theme then runFX(function() Theme.Sound("page") end) end
      end
    end
  end
  ui.hint:SetText(hintText)

  -- input row
  local canAnswer = (isPlay and S.qOpen and S.seated and inRoster and not S.spectator
    and not S.dataBad and not S.myLocked and S.syncHoldR ~= S.r) and true or false
  ui.entry:SetShown(isPlay and showQ and not refereed and not S.spectator)
  -- Enable/Disable rather than SetEnabled: those two are the EditBox widget's
  -- own long-standing methods, and a disabled box also stops accepting focus,
  -- which is the property that matters here.
  if canAnswer then ui.entry:Enable() else ui.entry:Disable() end
  ui.submit:SetShown(isPlay and showQ and not refereed and not S.spectator)
  ui.submit:SetEnabled(canAnswer and Bank.normalize(ui.entry:GetText()) ~= "")
  for i = 1, 3 do
    ui.abc[i]:SetShown(isL and not refereed and not S.spectator)
    ui.abc[i]:SetEnabled(canAnswer)
  end

  local status
  if isJoin then
    if S.isHost then
      local remaining = S.joinFrozen and (S.joinRemaining or 0)
        or math.max(0, (S.joinDeadline or now) - now)
      status = #S.roster .. " joined - questions start in " .. math.ceil(remaining) .. "s"
        .. (S.joinFrozen and " (paused)" or "")
    else
      status = #S.roster .. " joined - waiting for the host to start"
    end
  elseif isPlay then
    if S.hostQuiet then
      -- SCOPE.md 6.2: quiet is not dead.
      status = "Waiting for the host - they may be in a boss fight."
    elseif S.spectator then
      status = "Spectating - your roster is out of sync."
    elseif S.dataBad then
      -- one word shorter: the long form measured about 5px past the status
      -- line and lost its own last word, which reads as a rendering fault
      status = "Your question pack does not match the host's - watching."
    elseif S.qOpen then
      if S.isHost then
        -- only the host sees the live count; a client knows just its own lock
        status = (S.answerCount or 0) .. "/" .. #S.roster .. " answered"
        if S.seated and S.myLocked then
          status = status .. " - you locked " .. shortAnswer(S.myAnswer)
        end
      elseif S.myLocked then
        status = "Locked: " .. shortAnswer(S.myAnswer) .. " - waiting for the reveal"
      elseif S.syncHoldR == S.r and inRoster then
        status = "Resynced - you are back in from the next question."
      elseif inRoster then
        status = "Type your answer and press Enter - one guess only!"
      else
        status = "Watching this one."
      end
    else
      status = "Next question starting soon..."
    end
  else
    status = S.spectator and "Spectated - out of sync." or "Thanks for playing!"
  end
  ui.status:SetText(status)

  -- reveal + personal gain lines (persist through the pause after a RESULT)
  local lr = S.lastResult
  if isJoin then
    ui.reveal:SetText("")
    ui.gain:SetText("")
  elseif isDone and S.ended then
    ui.reveal:SetText(P.chgold .. "Final standings - " .. S.rounds .. " questions|r")
    local mineLine = ""
    if not S.spectator and S.standings then
      for i = 1, #S.standings do
        local e = S.standings[i]
        if e.name == me then
          mineLine = "You finished " .. (PODIUM[e.place] or "|cffffffff") .. "#" .. e.place
            .. "|r with " .. e.pts .. (e.pts == 1 and " point." or " points.")
        end
      end
    end
    ui.gain:SetText(mineLine)
  else
    local revealLine = S.lastResultText or ""
    if S.revealText and S.revealText ~= "" then
      revealLine = (revealLine ~= "" and (revealLine .. "|n") or "") .. S.revealText
    end
    ui.reveal:SetText(revealLine)
    local gainLine = ""
    if lr and lr.myChar then
      if lr.myChar == "X" then
        gainLine = P.chgray .. "You sat that one out.|r"
      elseif lr.myChar == "W" then
        gainLine = P.chred .. "Wrong.|r"
      elseif lr.myChar == "1" then
        gainLine = P.chgreen .. "+3 - fastest!|r"
      elseif lr.myChar == "2" then
        gainLine = P.chgreen .. "+2 - second.|r"
      else
        gainLine = P.chgreen .. "+1 - correct.|r"
      end
    end
    ui.gain:SetText(gainLine)
  end

  -- roster / standings rows. emptyText goes to the centred ui.empty, never into
  -- row 1: an empty state is not list item zero. One string across all six
  -- games (PLAN 4).
  local lines, emptyText = {}, nil
  if S.spectator and not isJoin then
    emptyText = "Out of sync - standings unavailable this game."
  elseif isJoin then
    for _, name in ipairs(S.roster) do
      lines[#lines + 1] = name .. (name == me and (P.chgold .. " (you)|r") or "")
    end
    if not lines[1] then emptyText = "Nobody has joined yet." end
  else
    local standings = (isDone and S.standings) or computeStandings()
    for i = 1, #standings do
      local e = standings[i]
      local placeColor = PODIUM[e.place] or "|cffa8a89c"
      local line = placeColor .. e.place .. ".|r " .. e.name
        .. (e.name == me and (P.chgold .. " (you)|r") or "")
        .. "  -  " .. e.pts .. " pts"
      if isDone and S.ended and e.place == 1 then
        line = line .. "  " .. PODIUM[1] .. "*|r"
      end
      lines[#lines + 1] = line
    end
  end
  -- Referee host (6.5): shown outside the numbered roster, because it holds no
  -- seat, answers nothing and wins no medal.
  if refereed then
    table.insert(lines, 1, P.chgray .. shortOf(S.host) .. " (running the game)|r")
    -- the referee line occupies the band, so the notice is no longer the only
    -- thing on screen and goes back into the list where it reads as one
    if emptyText then
      lines[2] = P.chgray .. emptyText .. "|r"
      emptyText = nil
    end
  end
  -- The local player's row is the one row the collapse may not eat: when it
  -- falls past the cut it is lifted into the last visible slot, the rule Death
  -- Roll and the reveal stage already apply (PLAN 3, F6).
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

  -- bottom line: your total, or your medal tally and record after the reveal
  if refereed then
    ui.mine:SetText(P.chgray .. "You're running this one - no answers from you.|r")
  elseif S.spectator then
    ui.mine:SetText(P.chgray .. "Spectating - no answers this game.|r")
  elseif isJoin then
    ui.mine:SetText(inRoster and "You are in - good luck!"
      or (P.chgray .. "You have not joined this game.|r"))
  elseif inRoster then
    if isDone and S.ended then
      local asked, got = myStats()
      local line = shortOf(me) .. "'s medal count: " .. P.chgold .. myMedalCount() .. "|r"
      if asked > 0 then
        line = line .. "   " .. P.chgray .. "Quiz record: " .. got .. " of " .. asked .. "|r"
      end
      ui.mine:SetText(line)
    else
      local total = (me and S.totals[me]) or 0
      ui.mine:SetText("Your total: " .. P.chgold .. total .. "|r "
        .. (total == 1 and "point" or "points"))
    end
  else
    ui.mine:SetText(P.chgray .. "You are sitting this one out.|r")
  end

  ui.startBtn:SetShown(isJoin and S.isHost)
  ui.withdrawBtn:SetShown((isJoin and not S.isHost and S.joinAccepted) and true or false)
  -- Reveal now takes the bottom-right slot only while a question is open; the
  -- rest of the time Cancel game owns it. No cancel once END is pending or
  -- queued: medals must land all-or-nothing.
  local canReveal = (S.isHost and isPlay and S.qOpen and not S.broken and not S.frozen)
    and true or false
  ui.revealBtn:SetShown(canReveal)
  ui.cancelBtn:SetShown((S.isHost and not isDone and not canReveal
    and not (S.endPending or S.endSent)) and true or false)
  ui.againBtn:SetShown((isDone and S.ended and S.isHost) and true or false)
end

ShowWindow = function()
  -- 5.9: one window per module, bound to the INVOLVED record.
  local S = mySession()
  if not S then return end
  if not (S.isHost or S.joinAccepted) then return end
  local st = PG.Safety.state
  if st.inEncounter or st.readyCheck or st.countdown or st.restricted then return end
  if st.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return end
  ensureWindow()
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
local function makeField(parent, label, y, default, maxLetters)
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
  eb:SetMaxLetters(maxLetters or 3)
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

-- Advisory notes on the audience segments (SCOPE.md 5.2 cfg.reasons).
local function scopeNote(scope)
  if scope == "public" then
    return "Points only - no gold is ever recorded, and everyone needs the same version of the question pack."
  elseif scope == "guild" then
    return "Everyone in your guild who runs the addon, on any realm."
  end
  return nil
end

refreshDialog = function()
  if not (dialog and dlgNote and dlgStart) then return end
  local note, canStart = involvement()
  local scope = dlgScope and dlgScope:Get() or nil
  local why
  if not canStart then
    why = note
  elseif not Bank.dataVersion() then
    canStart = false
    why = "The question pack did not load. Reinstall Pengyou Games."
    note = why
  elseif not scope then
    canStart = false
    why = "Nowhere to start a game: you're not in a group or a guild."
    note = why
  else
    local opts = readOpts()
    local usable = 0
    for i = 1, #MODE_ORDER do
      local m = MODE_ORDER[i]
      if opts[m] and Bank.modeReady(m) then usable = usable + 1 end
    end
    if usable == 0 then
      canStart = false
      why = "None of the chosen games have enough questions in the pack."
      note = why
    end
  end
  dlgNote:SetText(note or "")
  dlgStart:SetEnabled(canStart and true or false)
  dlgStart:SetAlpha(canStart and 1 or 0.6)
  dlgStart.__pgWhy = why
end

local function ensureDialog()
  if dialog then return end
  -- 512, not 470: PG.UI.ScopePicker is 58 tall now (its fallback hint used to
  -- render 13px OUTSIDE the rect it declared) and the note under it has to
  -- clear Start with all three of its lines showing. This dialog carries three
  -- fields, five checkboxes, the picker and the note; it is honestly tall.
  dialog = PG.UI.Window("qzdialog", "Start Quiz", DLG_W, 512, "QZ")
  local inset = mt("INSET")
  local hint = dialog:CreateFontString(nil, "OVERLAY", ft("S"))
  hint:SetPoint("TOPLEFT", inset, -56)
  hint:SetPoint("TOPRIGHT", -inset, -56)
  hint:SetHeight(24)
  hint:SetJustifyH("LEFT")
  hint:SetJustifyV("TOP")
  hint:SetWordWrap(true)
  hint:SetMaxLines(2)
  hint:SetText("Answers are typed here and whispered to the host - nothing is ever posted to chat.")
  hint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
  if Theme then Theme.Shadow(hint) end

  dlgInputs = {
    rounds = makeField(dialog, "Questions", -88, 5, 1),
    joinSecs = makeField(dialog, "Join window (sec)", -120, 30, 3),
    answerSecs = makeField(dialog, "Answer time (sec)", -152, 20, 2),
  }

  local header = dialog:CreateFontString(nil, "OVERLAY", ft("T"))
  header:SetPoint("TOPLEFT", inset, -184)
  header:SetPoint("TOPRIGHT", -inset, -184)
  header:SetJustifyH("LEFT")
  header:SetWordWrap(false)
  header:SetMaxLines(1)
  header:SetText("Which games")
  header:SetTextColor(P.BRASS[1], P.BRASS[2], P.BRASS[3])
  if Theme then Theme.Shadow(header) end

  -- Checkbox helper, local to this file, copied from Settings.lua's check().
  -- Promoting it to Widgets would mean touching a file three shipped games
  -- depend on, for twelve lines.
  local function check(label, y, get, set)
    local cb = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", inset, y)
    cb.label = dialog:CreateFontString(nil, "OVERLAY", ft("B"))
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    -- bounded: a label with no width runs out through the border art
    cb.label:SetPoint("RIGHT", dialog, "RIGHT", -inset, 0)
    cb.label:SetJustifyH("LEFT")
    cb.label:SetWordWrap(false)
    cb.label:SetMaxLines(1)
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb:SetScript("OnShow", function(self) self:SetChecked(get() and true or false) end)
    return cb
  end

  dlgChecks = {}
  for i = 1, #MODE_ORDER do
    local m = MODE_ORDER[i]
    dlgChecks[m] = check(MODE_NAME[m], -204 - (i - 1) * 28,
      function() return readOpts()[m] end,
      function(v)
        if not v then
          -- All four off has no meaning, so the last one refuses to come off.
          local opts = readOpts()
          local n = 0
          for k = 1, #MODE_ORDER do
            if opts[MODE_ORDER[k]] then n = n + 1 end
          end
          if n <= 1 then
            toast("pick at least one game.")
            dlgChecks[m]:SetChecked(true)
            return
          end
        end
        -- readOpts' all-false-reads-as-all-true rule means an unwritten table
        -- must be materialized before the first uncheck, or turning one off
        -- would leave three unwritten (and therefore still-on) neighbours.
        local opts = readOpts()
        for k = 1, #MODE_ORDER do
          writeOpt(MODE_ORDER[k], opts[MODE_ORDER[k]])
        end
        writeOpt(m, v)
        refreshDialog()
      end)
  end
  dlgChecks.hints = check("Hints at the halfway mark", -320,
    function() return readOpts().hints end,
    function(v) writeOpt("hints", v) end)

  dlgScope = PG.UI.ScopePicker(dialog, {
    key = "QZ",
    allowed = PG.QZ.SCOPES,
    reasons = scopeNote,
    onChange = function() refreshDialog() end,
  })
  dlgScope:SetPoint("TOPLEFT", dialog, "TOPLEFT", 0, -356)
  dlgScope:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", 0, -356)

  -- Anchored to the picker's own bottom, not to an absolute offset that has to
  -- be re-guessed every time the control changes height.
  dlgNote = dialog:CreateFontString(nil, "OVERLAY", ft("S"))
  dlgNote:SetPoint("TOPLEFT", dlgScope, "BOTTOMLEFT", inset, -8)
  dlgNote:SetPoint("TOPRIGHT", dlgScope, "BOTTOMRIGHT", -inset, -8)
  dlgNote:SetJustifyH("LEFT")
  -- TOP, so a one-line note sits where a three-line note starts instead of
  -- floating in the middle of its box (four of the five dialogs did this)
  dlgNote:SetJustifyV("TOP")
  dlgNote:SetWordWrap(true)
  dlgNote:SetHeight(36)
  dlgNote:SetMaxLines(3)
  dlgNote:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  if Theme then Theme.Shadow(dlgNote) end

  local startLabel = "Start quiz"
  local m = quizMark()
  if m ~= "" then startLabel = m .. " Start quiz" end
  dlgStart = PG.UI.Button(dialog, startLabel, 150, 26, function()
    local scope = dlgScope and dlgScope:Get() or nil
    if not scope then
      toast("nowhere to start a game - you're not in a group or a guild.")
      return
    end
    local rounds = fieldValue(dlgInputs.rounds, 1, MAX_ROUNDS)
    local joinSecs = fieldValue(dlgInputs.joinSecs, 15, 120)
    local answerSecs = fieldValue(dlgInputs.answerSecs, MIN_ANSWER_SECS, MAX_ANSWER_SECS)
    local opts = readOpts()
    if Theme then Theme.Sound("stamp") end
    dialog:Hide()
    hostOpen(rounds, joinSecs, answerSecs, opts, opts.hints, scope)
  end)
  dlgStart:SetPoint("BOTTOM", 0, 18)
  local dlgRules = PG.UI.Button(dialog, "Rules", 60, 22, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("QZ") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", 16, 18)
  dlgStart:SetScript("OnEnter", function(self)
    if not self.__pgWhy then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.__pgWhy, 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  dlgStart:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- HookScript, never SetScript: the skin and the picker already hooked OnShow
  dialog:HookScript("OnShow", refreshDialog)
end

-- Launcher / slash entry point. The dialog ALWAYS opens (CONCURRENCY.md 0.2);
-- Start is what explains itself.
function PG.QZ.OpenDialog()
  ensureDialog()
  if dlgScope then dlgScope:Refresh() end
  refreshDialog()
  dialog:Show()
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

-- Precomputes the usable index list for every pool, once. Data/QuizData.lua is
-- listed before this file in the .toc for grouping and readability only: every
-- file's file scope runs during load and every init callback runs later at
-- ADDON_LOADED, so PG.QuizData is non-nil here regardless of the order.
function Bank.indexPools()
  for _, m in ipairs({ "T", "U", "R" }) do
    local list, pool = {}, Bank.poolOf(m)
    if type(pool) == "table" then
      local ok = (m == "T") and Bank.usableTrivia or Bank.usableWord
      for i = 1, #pool do
        if ok(pool[i]) then list[#list + 1] = i end
      end
    end
    Bank.usable[m] = list
  end
  for _, which in ipairs({ "T", "L" }) do
    local list, pool = {}, Bank.twoTruthsPool(which)
    if pool then
      for i = 1, #pool do
        if Bank.usableStatement(pool[i]) then list[#list + 1] = i end
      end
    end
    Bank.usable[(which == "T") and "LT" or "LL"] = list
  end
  Bank.ready = (Bank.dataVersion() ~= nil)
    and (#Bank.usable.T + #Bank.usable.U + #Bank.usable.R + #Bank.usable.LT > 0)
end

PG.RegisterInit(function()
  if PG.Theme and PG.Theme.C then
    Theme = PG.Theme
    local c = Theme.C()
    for k in pairs(P) do
      if c[k] ~= nil then P[k] = c[k] end
    end
  end
  -- medals, stats and dialog options live in their own tiny table
  qdb()
  Bank.indexPools()
  PG.Comm.Register("QZ", onComm, onDrop)
  -- Whisper trust (SCOPE.md 4.3, BRIEF 4.2). A whisper carries no audience
  -- proof at all, so outside the group only the INVOLVED session vouches for
  -- one. Without this, accept() drops every JOIN, ANS and SYNCQ whisper from a
  -- guildmate or a stranger and guild and public Quiz are dead on arrival -
  -- group scope would work only by accident, through isGroupSender.
  if PG.Comm.RegisterTrust then
    PG.Comm.RegisterTrust("QZ", function(sender)
      local S = mySession()
      if not S or S.phase == "done" then return false end
      if sender == S.host then return true end
      if S.joined[sender] then return true end
      -- host side, wide scope, join window open: the first JOIN from a stranger
      -- is the entire point of a wider audience. The router's rate limiter
      -- bounds the abuse.
      if S.isHost and S.phase == "join" and S.scope ~= "group" then return true end
      return false
    end)
  end
  PG.Safety.OnChange(onSafetyChange)
  -- Accepting one invitation withdraws the rest (CONCURRENCY.md 5.6 rule 3).
  PG.Session.OnChange(function(seat)
    if not seat then return end
    local held = keyOf(seat.host or "?", seat.token or "")
    for _, rec in pairs(sessions) do
      if rec.kind == "lite" and rec.askKey and rec.key ~= held then
        PG.UI.Dismiss(rec.askKey)
        rec.askKey = nil
      end
    end
  end)
end)
