-- Games/PullBook.lua - The Pull Book: pre-pull betting (bookie + client + UI).
--
-- 0.6.0 concurrency pass. The single module-global `book` is now a keyed
-- registry (CONCURRENCY.md 2): ONE full record - the book we are actually in,
-- hosted or adopted - plus bounded lite records for books we merely overhear.
-- Identity is the pair (bookie, token) (CONCURRENCY.md 3), which is what stops
-- a colliding token from folding another bookie's bettors into our own
-- attempt.bets and paying them at our stake.
--
-- The Pull Book NEVER takes the round-based seat (I10): it is passive pre-pull
-- betting, designed from day one to run alongside a Loot Goblins or Rock Paper
-- Scissors game, so this file contains zero references to PG.Session,
-- permanently.
--
-- The Pull Book is PARTY ONLY (SCOPE.md 1.2), and that is a rule about physics
-- rather than taste: the book is scored from the bookie's own ENCOUNTER_END and
-- UNIT_DIED, so only the group standing in that fight can observe, verify or
-- contest the result. The picker still renders Guild and Public - disabled,
-- with the reason - because "why can't I?" is the question being asked at
-- exactly that moment.
local ADDON, PG = ...

PG.PB = {}

-- Read by PG.UI.ScopePicker (SCOPE.md 1.2 / 5.2).
PG.PB.SCOPES = { group = true, guild = false, public = false }

-- Window layout, on the shared spacing grid (PG.Theme.METRIC). Mirrored as a
-- literal because file scope may not read another module's tables; every
-- offset in this file is a multiple of GRID = 4.
local INSET = 24            -- METRIC.INSET

-- The Pull Book NEVER takes the single round-based seat (CONCURRENCY.md I10):
-- it is passive pre-pull betting and runs alongside anything else in the suite.
-- Since 1.1.0 the launcher's Join gate reads this flag instead of naming "PB"
-- in its own source, so the exemption is declared where the exemption lives.
--
-- This line is a DECLARATION, not a use of the session layer, so I10's check
-- still holds - but state that check the way it has to be stated to survive
-- being written down (BRIEF 5.4 C12). The invariant is ZERO CALLS, verified
-- with the escaped-dot pattern
--     grep -n 'PG\.Session\.' PengyouGames/Games/PullBook.lua
-- and never with a search for the bare word: the comment that documents an
-- invariant inevitably contains the invariant's own name, so a bare-name grep
-- can never come back empty and stops being a check at all. The pattern above
-- is deliberately the one form that does not match its own documentation.
PG.PB.SEAT = false

local STAKE_MIN, STAKE_MAX = 1, 100000
local LINE_MIN, LINE_MAX = 1, 99
local FD_VOID_SECS = 20  -- no FD within 20s of encounter end -> D market void
local HB_SECS = 15
local HB_MISS_SECS = 50
-- Presentation only: seconds after a pull timer expires that the results stage
-- stays off the screen. COUNTDOWN_OFF lands ~1s past the pull moment, and
-- combat is flagged a moment later; this covers the gap between the two, where
-- every Safety flag is momentarily clear but the raid is mid-pull.
local PULL_GRACE = 6

-- Registry budget (CONCURRENCY.md 2.1 / 7.3). Worst case per sweep is
-- 1 + 8 + 16 = 25 table entries, once per 2 seconds.
local MAX_LITE = 8        -- overheard books remembered at once
local MAX_RECENT = 16     -- dead keys remembered
local RECENT_TTL = 120    -- seconds a dead key stays poisoned
local LITE_TTL_PAD = 10   -- a lite book outlives the bookie's own miss deadline by this
local LITE_TTL = HB_MISS_SECS + LITE_TTL_PAD
local TICK = 0.5          -- the module's ONE ticker; sweeps every 4th tick (2s)
local MAX_REVEAL_Q = 6    -- bounded: stage payloads waiting out a pull

local MARKETS = {
  { m = "K", label = "Kill?", opts = { { "YES", "Y" }, { "NO", "N" } } },
  { m = "D", label = "First death", opts = { { "TANK", "T" }, { "HEALER", "H" }, { "DPS", "D" } } },
  { m = "W", label = "Boss HP", opts = { { "OVER", "O" }, { "UNDER", "U" } } },
}

local VALID_PICK = {
  K = { Y = true, N = true },
  D = { T = true, H = true, D = true },
  W = { O = true, U = true },
}

local ROLE_WORD = { T = "Tank", H = "Healer", D = "DPS" }

-- Only these arrive from the bookie, and gate g resolves them against
-- (sender, token) - so the sender IS the record's bookie by construction
-- (CONCURRENCY.md 5.2 gate j). BET is the one type any player at the table
-- broadcasts, and it resolves against the involved book only.
local BOOKIE_AUTHORED = { CLOSE = true, HB = true, FD = true }

-------------------------------------------------------------------------------
-- Presentation (SKIN.md "faire": Darkmoon bookmaker). Markup and color only:
-- every helper degrades to plain text / today's look when the theme layer is
-- absent, and no gameplay path branches on any of it.
-------------------------------------------------------------------------------

-- The board palette, literal spec values (SKIN.md 1.1); refreshed from
-- PG.Theme.C at init when the theme layer is present (values identical).
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

-- Chalkboard treatment for the strip (SKIN.md 1.3 "faire"); the plain tooltip
-- backdrop stays the fallback when the dark dialog art is unavailable.
local FAIRE_BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 32, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local PLAIN_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- Tarot emblem per market (SKIN.md 2.7); fail -> no emblem, labels carry it.
local MARKET_ICON = { K = "tarotK", D = "tarotD", W = "tarotW" }

-- The Pull Book's own disabled-scope answer (SCOPE.md 1.2, verbatim intent).
local WIDE_SCOPE_REASON =
  "The Pull Book follows your own pull. The book is scored from the boss fight "
  .. "you are standing in, so only your group can see the same result you do."

-------------------------------------------------------------------------------
-- State
--
-- books[key] = record, key = bookie .. "|" .. token.
--   full record: the one book we are in (ours or adopted). Exactly today's
--     `book` table plus kind / key / scope / attemptSeq, so every function
--     below keeps its shape: `local book = myBook()` and the body is unchanged.
--   lite record: a book we merely overheard. No attempt, no bets, no strip, no
--     ticker, no frame - enough to drop its traffic cheaply, resolve identity,
--     and offer it in the launcher when our own book ends.
-------------------------------------------------------------------------------

local books = {}      -- [key] = record
local mine            -- key of the ONE full record, or nil
local recent = {}     -- [key] = GetTime() when it died; replay defence
local recentQ = {}    -- FIFO of poisoned keys, capped at MAX_RECENT

-- attempt belongs to the full record and to nothing else: every path that
-- replaces or evicts that record clears it. `mine` is set in exactly two places
-- (adoptFull, and the bookie's own open) and cleared in exactly one (evict), so
-- there is no path where an attempt outlives the book it was taken for.
-- attempt: nil, or { bets = { [fullName] = { K=, D=, W= } }, frozen, snap, seq,
--   firstDeath = { role, name } (bookie only), resolvedKW, dDone, fdSent, reason }
local attempt
local lastSnap        -- bookie's latest out-of-combat roster snapshot { [guid] = { name, role } }

local strip           -- bet strip frame (NOT Safety-registered; managed manually)
local dlg, stakeBox, lineBox, statusFS, statusHead, closeBtn, configWidgets, picker
local bookieNPC       -- the dialog's goblin bookie handle (Emote self-gates)
local pullAt = 0      -- GetTime() of the last pull-timer expiry (see PULL_GRACE)

local regTicker, tickN = nil, 0

local refreshDialog   -- forward: defined in the dialog section
local ensureTicker    -- forward: defined in the lifecycle section
local bookieSendFD    -- forward: defined after the wire section

local function shortOf(full)
  return (strsplit("-", tostring(full or "?")))
end

-------------------------------------------------------------------------------
-- Identity and the registry (CONCURRENCY.md 2.1, 3.2)
--
-- The registry is keyed by the PAIR, so a token only has to be unique within
-- one character's history: the sender is server-vouched and realm-qualified, so
-- two hosts can mint the same token and still never share a key. That is what
-- makes the compact token safe - and it makes every message smaller, not larger.
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

-- "1a-7f3": a persisted monotonic counter per character, plus three random
-- base-36 characters. The counter is the mechanism (incremented and persisted
-- BEFORE the OPEN goes out, so a crash cannot reissue a number); the suffix is
-- a seatbelt for a SavedVariables rollback, where the counter can go backwards.
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

local function myBook()
  return mine and books[mine] or nil
end

local function recordCount()
  local n = 0
  for _ in pairs(books) do n = n + 1 end
  return n
end

local function liteCount()
  local n = 0
  for _, rec in pairs(books) do
    if rec.kind == "lite" then n = n + 1 end
  end
  return n
end

-- A dead key can never be resurrected for RECENT_TTL: a stale or replayed OPEN
-- for a book that just closed is dropped at the front of the decision table.
local function poison(key)
  for i = 1, #recentQ do
    if recentQ[i] == key then
      table.remove(recentQ, i)
      break
    end
  end
  recent[key] = GetTime()
  recentQ[#recentQ + 1] = key
  while #recentQ > MAX_RECENT do
    local old = table.remove(recentQ, 1)
    recent[old] = nil
  end
end

-- Wire token validation (CONCURRENCY.md 3.4): opaque, bounded, separator-free.
local function validToken(token)
  if PG.IsSecret(token) or type(token) ~= "string" then return false end
  if token == "" or #token > 24 then return false end
  if token:find("|", 1, true) then return false end
  return true
end

-- "the sender is in the current group snapshot" (CONCURRENCY.md 4.5). Comm has
-- already vouched a group-scope sender against the roster; this is the module's
-- own copy of that test, kept because the BET path is the one place a wire
-- message touches another player's money.
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

-------------------------------------------------------------------------------
-- Toasts and the results stage.
--
-- The private FIFO is GONE (CONCURRENCY.md 5.7): Widgets owns one queue for the
-- whole addon, with the 1.2s floor, the 4-entry cap and the rule that a result
-- line is never dropped for a status line. What stays here is the stage
-- queueing, because only this module knows about PULL_GRACE and the bet strip.
-------------------------------------------------------------------------------

local revealQ = {}

-- rec (optional) is attribution: while more than one book is known, a line
-- names its bookie, because a player who can hear two books cannot otherwise
-- tell which one just paid them.
local function toast(text, rec, opts)
  if type(text) ~= "string" then return end
  if rec and rec.bookie and recordCount() > 1 then
    text = "(" .. shortOf(rec.bookie) .. ") " .. text
  end
  local pre = mark("ticket")
  if pre ~= "" then text = pre .. " " .. text end
  PG.UI.Toast(text, opts)
end

-- The extra conditions a full-takeover stage answers to on top of the toast
-- gate: ready check / countdown, the PULL_GRACE window after a pull timer
-- expires (every Safety flag is momentarily clear in it while the pull is
-- happening), and any moment the bet strip owns the screen - the stage must
-- never cover a live bet window.
local function stageGatesOK()
  local s = PG.Safety.state
  if s.readyCheck or s.countdown then return false end
  if (GetTime() - pullAt) < PULL_GRACE then return false end
  if strip and strip:IsShown() then return false end
  return true
end

-- Today's gate, unchanged in meaning: the screen must be ours, the pull gates
-- must be clear, and the text that explains a settlement must have been read
-- first - so a stage payload never overtakes its own toasts.
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
  while #revealQ > MAX_REVEAL_Q do table.remove(revealQ, 1) end
  if ensureTicker then ensureTicker() end
end

-- One payload per tick, oldest first. Draining is presentation only; nothing
-- here feeds gameplay, and no drain path can alter the ledger or the wire.
local function pumpReveal()
  if not revealQ[1] then return end
  if not canRevealNow() then return end
  local payload = table.remove(revealQ, 1)
  -- decoration doctrine: we never branch on the result. The engine drops the
  -- payload under DND exactly as PG.UI.Toast drops a toast, and the ledger
  -- keeps the money either way.
  if PG.Theme and PG.Theme.RevealQueue then PG.Theme.RevealQueue(payload) end
end

-- Drain-time gate for every PB stage payload. Handing a payload to the engine
-- only relinquishes our own gate: the engine's gate is the five Safety flags,
-- and a payload that lands in the engine queue while the stage is busy can sit
-- there across a whole ready check plus countdown and then drain on
-- COUNTDOWN_OFF - the one moment PULL_GRACE exists to protect. So the same gate
-- is re-applied at drain. The engine DISCARDS a payload whose validate returns
-- false and a settlement must eventually show, so a veto puts the payload back
-- in our own queue, where canRevealNow holds it properly.
--
-- Note what this deliberately does NOT test: record liveness. A settlement is
-- never stale (REVEAL.md 6.5) - the gold moved when the market resolved - and
-- the closing podium is by definition queued as its record dies. Ownership
-- culling (CONCURRENCY.md 5.8 rule 2) is for mid-session moments, and the Pull
-- Book has none: only a full record ever emits, and only about money already
-- committed.
local function stageValidate(payload)
  if stageGatesOK() then return true end
  queueReveal(payload)
  return false
end

-------------------------------------------------------------------------------
-- Settlement presentation (REVEAL.md 6.5): the shared results stage in SCREEN
-- mode - the Pull Book has no persistent window to host it. A settlement that
-- actually moved gold takes the stage (per-market outcome lines with winners
-- and pot, your own delta emphasized on its own row); trivial moments - nobody
-- bet, every market void, no theme layer - stay quiet toasts, word for word as
-- before, because a full takeover for "stakes returned" would be obnoxious.
--
-- The settlement path builds BOTH renderings as it goes and chooses between
-- them only after the ledger is written, so the accounting never depends on
-- which surface ends up showing (and neither does anything on the wire).
-------------------------------------------------------------------------------

-- Running per-book tally of settled deltas, for the closing podium. The ledger
-- is the record of record; this is only what the podium ranks. Never
-- persisted, never sent, never read by a gameplay path.
local function bookTally(rec, name, delta)
  if not rec then return end
  local nets = rec.nets
  if not nets then
    nets = {}
    rec.nets = nets
  end
  nets[name] = (nets[name] or 0) + delta
end

local function stakeLine(rec)
  if not rec then return nil end
  return "STAKE " .. PG.Money(rec.stake) .. " A BET"
end

-- One settlement moment's report: ordered lines, each carrying the exact toast
-- text used when the stage is unavailable AND the stage row. `paid` counts
-- markets that actually paid out; `mine` is my total delta across them; `head`
-- / `sub` are the outcome line in its two renderings.
local function newReport()
  return { lines = {}, paid = 0 }
end

-- toastText nil -> a line that exists on the stage only (nothing to toast).
-- key / prio ride to PG.UI.Toast: a market's line dedupes on its own key, and a
-- line that moved gold is a "result" the shared queue never drops for chatter.
local function repAdd(rep, toastText, snd, rowText, rowRole, key, prio)
  rep.lines[#rep.lines + 1] = {
    toast = toastText, snd = snd, row = rowText, role = rowRole,
    key = key, prio = prio,
  }
end

local function flushToasts(rep, rec)
  if rep.head then
    toast(rep.head, rec, {
      key = "pb-outcome",
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

local function emitReport(rep, rec, title, emote)
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
  -- settlement info is never stale, but the stage must still answer the pull
  -- gates at the moment the engine drains it, not just when we hand it over
  local payload = {
    game = "PB", anchor = { mode = "screen" },
    title = title,
    subtitle = rep.sub,
    rows = rows,
    marquee = stakeLine(rec),
    burst = "tickets", burstCount = 10,
    sound = "settled",
    npc = bookieNPC, emote = emote,
  }
  payload.validate = function() return stageValidate(payload) end
  queueReveal(payload)
end

-- End of book (the Pull Book's session end): rank what the book paid out over
-- its life, podium variant, top three rising last. Players the book never paid
-- or charged are absent. Returns true when the stage took the closing line, so
-- the caller can skip the toast that would only repeat it.
local function closePodium(rec, sub)
  if not (rec and rec.nets and PG.Theme and PG.Theme.RevealQueue) then return false end
  local list, any = {}, false
  for name, net in pairs(rec.nets) do
    list[#list + 1] = { name = name, net = net }
    if net ~= 0 then any = true end
  end
  if not any then return false end
  -- net descending, ties by name in byte order (the suite's ordering rule)
  table.sort(list, function(x, y)
    if x.net ~= y.net then return x.net > y.net end
    return x.name < y.name
  end)
  local me = PG.FullName("player")
  local rows, places, top = {}, 0, nil
  for i = 1, #list do
    local e = list[i]
    local place
    if e.net > 0 and places < 3 then -- only winners stand on the podium
      places = places + 1
      place = places
      top = top or e.name
    end
    rows[#rows + 1] = {
      -- the rank is part of the text: above 10 bettors the engine lifts the
      -- local player's row into the last visible slot, and a row carrying its
      -- own rank stays honest out of net-descending order
      text = i .. ". " .. shortOf(e.name) .. "  "
        .. (e.net >= 0 and "+" or "") .. PG.Money(e.net),
      role = (place == 1 and "gold") or (place == 2 and "silver") or (place == 3 and "bronze")
        or (e.net > 0 and "win") or (e.net < 0 and "loss") or "fade",
      place = place,
      personal = (me ~= nil and e.name == me),
    }
  end
  local payload = {
    game = "PB", anchor = { mode = "screen" }, variant = "podium",
    title = "THE BOOK CLOSES",
    subtitle = sub,
    rows = rows,
    marquee = top and (string.upper(shortOf(top)) .. " TAKES THE BOOK") or nil,
    burst = "tickets", burstCount = 12,
    sound = "bookclose", burstSound = "fanfare",
    npc = bookieNPC, emote = "applaud",
  }
  payload.validate = function() return stageValidate(payload) end
  queueReveal(payload)
  return true
end

-------------------------------------------------------------------------------
-- Parimutuel math (unchanged: every number below is exactly 0.5.0's)
-------------------------------------------------------------------------------

local function marketBetCount(bets, m)
  local n = 0
  for _, picks in pairs(bets) do
    if picks[m] then n = n + 1 end
  end
  return n
end

local function totalBetCount(bets)
  local n = 0
  for _, picks in pairs(bets) do
    if picks.K or picks.D or picks.W then n = n + 1 end
  end
  return n
end

-- nil if void (bettors < 2, or everyone on one side); else deltas map,
-- winner count, pot. Dust goes to the first winner in sorted (byte) order so
-- every client lands on the identical split.
local function resolveMarket(bets, m, winPick, stake)
  local winners, losers = {}, {}
  for name, picks in pairs(bets) do
    local p = picks[m]
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

-- Provenance id for one settled market (SCOPE.md 4.5 + CONCURRENCY.md 3.4):
-- game, bookie, token, attempt, market. The bookie is in it because tokens are
-- only unique per host now.
local function marketId(rec, a, m)
  return "PB:" .. rec.bookie .. ":" .. rec.token .. ":" .. (a.seq or 0) .. ":" .. m
end

-- Settles one market: applies ledger deltas and records the result line in the
-- caller's report (rep), which decides afterwards whether the moment gets the
-- stage or the quiet toasts. winPick == nil means the market is void by rule
-- (unreadable result / no FD). Silent when nobody bet the market.
local function settleMarket(rec, a, m, winPick, label, rep)
  if marketBetCount(a.bets, m) == 0 then return end
  if not winPick then
    repAdd(rep, P.chgray .. label .. ": void, stakes returned.|r", nil,
      label .. ": void, stakes returned", "fade", "pb-" .. m)
    return
  end
  local deltas, nWin, pot, nLose = resolveMarket(a.bets, m, winPick, rec.stake)
  if not deltas then
    repAdd(rep, P.chgray .. label .. ": void (not enough action), stakes returned.|r", nil,
      label .. ": void (not enough action)", "fade", "pb-" .. m)
    return
  end
  local me = PG.FullName("player")
  local mine2 = me and deltas[me]
  -- Ledger: one commit per settled market, all-or-nothing, with provenance.
  -- G1 (participation) is the caller's declaration and the gate re-checks it
  -- against the rows: a client that did not back this market keeps its UI
  -- mirror and writes nothing, which is what keeps two books - or a book and a
  -- Loot Goblins game - from producing divergent advisory ledgers.
  PG.Ledger.Commit({
    id = marketId(rec, a, m),
    game = "PB",
    host = rec.bookie,
    scope = rec.scope,
    at = (type(time) == "function") and time() or nil,
    played = (mine2 ~= nil),
    cap = rec.stake * math.max(1, nWin + (nLose or 0)),
    label = a.reason,
  }, deltas)
  for name, delta in pairs(deltas) do
    bookTally(rec, name, delta) -- presentation-only tally for the closing podium
  end
  local won = nWin .. (nWin == 1 and " winner takes " or " winners split ")
  local line = label .. ": " .. won .. P.chgold .. PG.Money(pot) .. "|r"
  local snd
  if mine2 then
    line = line .. " - you " .. (mine2 >= 0 and (P.chgreen .. "+" .. PG.Money(mine2) .. "|r")
      or (P.chred .. PG.Money(mine2) .. "|r"))
    snd = "settled"
    rep.mine = (rep.mine or 0) + mine2
  end
  rep.paid = rep.paid + 1
  repAdd(rep, line, snd, label .. ": " .. won .. tmoney(pot), "win",
    "pb-" .. m, "result")
end

-- Resolves the first-death market and ends the attempt. winPick nil -> void.
local function finishD(winPick, deadName)
  local a = attempt
  if not a or not a.resolvedKW or a.dDone then return end
  local book = myBook()
  if not book then return end
  a.dDone = true
  if marketBetCount(a.bets, "D") > 0 then
    if winPick then
      local word = ROLE_WORD[winPick] or winPick
      local header = "First death: " .. P.chred .. word .. "|r"
      if deadName then header = header .. " (" .. deadName .. ")" end
      local rep = newReport()
      rep.head = header .. "."
      rep.sub = word .. " fell first" .. (deadName and (" - " .. shortOf(deadName)) or "")
      settleMarket(book, a, "D", winPick, "First death bet", rep)
      emitReport(rep, book, "FIRST DEATH", "point")
    else
      toast(P.chgray .. "First death bet: void, stakes returned.|r", book, { key = "pb-D" })
    end
  end
  attempt = nil
end

-- Attempts are numbered per book so a settled market's ledger id is unique
-- across the book's life. No wire message may create one (CONCURRENCY.md 4.5):
-- only the bookie's own READY_ON / COUNTDOWN_ON does.
local function newAttempt(rec)
  rec.attemptSeq = (rec.attemptSeq or 0) + 1
  return { bets = {}, frozen = false, snap = lastSnap, seq = rec.attemptSeq }
end

-------------------------------------------------------------------------------
-- Bet strip: shown for the READY_CHECK / countdown window that Safety hides
-- everything else in, so it is deliberately NOT Safety-registered; this module
-- hides it itself on combat / encounter / restriction / window end.
-------------------------------------------------------------------------------

local function hideStrip()
  if strip then strip:Hide() end
end

local function refreshStrip()
  local book = myBook()
  if not (strip and book) then return end
  local pre = mark("ticket")
  if pre ~= "" then pre = pre .. " " end
  strip.title:SetText(pre .. "The Pull Book - " .. PG.Money(book.stake) .. " a bet")
  local me = PG.FullName("player")
  local mine2 = (attempt and me) and attempt.bets[me] or nil
  local bets = attempt and attempt.bets or nil
  for r = 1, #MARKETS do
    local mk = MARKETS[r]
    local btns = strip.rows[mk.m]
    local locked = mine2 and mine2[mk.m]
    local lockedBtn
    for i = 1, #btns do
      local b = btns[i]
      local label = b.baseLabel
      if mk.m == "W" then label = label .. " " .. book.line end
      if locked then
        b:SetEnabled(false)
        if b.pick == locked then
          -- your locked pick keeps its full card: WIN green on the parchment
          -- card, today's bright green on the plain fallback button
          b:SetText((b.__pgCard and P.win or "|cff40ff40") .. label .. "|r")
          b:SetAlpha(1)
          lockedBtn = b
        else
          b:SetText(label)
          b:SetAlpha(0.45)
        end
      else
        b:SetEnabled(true)
        b:SetText(label)
        b:SetAlpha(1)
      end
    end
    -- torn-ticket pin on the locked card (pool of one per market)
    local pin = strip.pins[mk.m]
    if pin then
      if lockedBtn then
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", lockedBtn, "TOPRIGHT", -4, -3)
        pin:Show()
      else
        pin:Hide()
      end
    end
    -- chalk tally: live backer counts, not prices (parimutuel flavor)
    local tally = strip.tallies[mk.m]
    if tally then
      local counts = {}
      if bets then
        for _, picks in pairs(bets) do
          local p = picks[mk.m]
          if p then counts[p] = (counts[p] or 0) + 1 end
        end
      end
      local parts = {}
      for i = 1, #mk.opts do parts[i] = tostring(counts[mk.opts[i][2]] or 0) end
      tally:SetText(table.concat(parts, #parts == 2 and " : " or "/"))
    end
  end
end

-- A2 lock-in pop on the just-locked ticket: the strip's entire motion budget
-- (SKIN.md 2.7 / rule 6.3). Presentation only; no-ops when hidden or unthemed.
local function popLock(m)
  if not (strip and strip:IsShown() and PG.Theme and PG.Theme.Pulse) then return end
  local me = PG.FullName("player")
  local mine2 = (attempt and me) and attempt.bets[me] or nil
  local locked = mine2 and mine2[m]
  if not locked then return end
  local btns = strip.rows[m]
  if not btns then return end
  for i = 1, #btns do
    if btns[i].pick == locked then PG.Theme.Pulse(btns[i]) end
  end
end

local function placeBet(m, p)
  local book = myBook()
  local a = attempt
  if not (book and a) or a.frozen then return end
  if PG.Comm.Locked() then return end
  local me = PG.FullName("player")
  if not me then return end
  local picks = a.bets[me]
  if picks and picks[m] then return end -- first click per market locks
  -- loopback rule: our own broadcasts are ignored on receipt, so record the
  -- pick locally - but only from onSent (the BET actually went out), never at
  -- queue time: a queued-then-lockdown-dropped BET must not leave us settling
  -- a bet nobody else saw. Everyone, including us, keeps the first pick per
  -- market, so a rare duplicate send stays consistent group-wide.
  PG.Comm.BroadcastEx({
    scope = book.scope,
    onSent = function()
      if attempt ~= a or a.frozen then return end
      local s = PG.Safety.state
      if s.inEncounter or s.restricted then return end -- mirrors the receive path
      local pk = a.bets[me]
      if not pk then
        pk = {}
        a.bets[me] = pk
      end
      if not pk[m] then pk[m] = p end
      refreshStrip()
      popLock(m) -- decoration only; the lock above is already committed
    end,
    -- The bookie rides along as the LAST field, so f1/f2 keep their meaning and
    -- no other handler shifts. Identity is the PAIR (CONCURRENCY.md 4.5):
    -- tokens are only host-unique now, and a BET is a BROADCAST every client in
    -- earshot applies, so without the bookie a colliding token folds another
    -- table's bettors into our book and settles them at OUR stake.
  }, "PB", "BET", book.token, m, p, book.bookie)
end

local function buildStrip()
  strip = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  -- 420x152 in SKIN.md 2.7; +20 wide so the 3-option row clears the tally
  strip:SetSize(440, 152)
  strip:SetPoint("TOP", UIParent, "TOP", 0, -230)
  strip:SetFrameStrata("HIGH")
  -- chalkboard backdrop; today's plain look is the fallback. Deliberately NOT
  -- Theme.Skin'd: the strip is the calm surface (instant show, no pop-in).
  -- SetBackdrop succeeds silently with a missing file (transparent strip), so
  -- gate the themed backdrop on Theme.FileExists; the fallback path is fully
  -- pcall'd too so a raising SetBackdrop can never abort the build.
  local FE = PG.Theme and PG.Theme.FileExists
  if FE and FE(FAIRE_BACKDROP.bgFile) and FE(FAIRE_BACKDROP.edgeFile)
      and pcall(strip.SetBackdrop, strip, FAIRE_BACKDROP) then
    strip:SetBackdropColor(1, 1, 1, 1)
    strip:SetBackdropBorderColor(0.45, 0.32, 0.68, 1) -- VIOLET
  else
    pcall(strip.SetBackdrop, strip, PLAIN_BACKDROP)
    pcall(strip.SetBackdropColor, strip, 0, 0, 0, 0.88)
    pcall(strip.SetBackdropBorderColor, strip, 0.8, 0.8, 0.8, 1)
  end
  -- FX registry + instant OnHide Stop contract for the lock pop (the strip's
  -- only animation); never Safety-registered, this module hides it manually
  if PG.Theme and PG.Theme.EnsureFX then PG.Theme.EnsureFX(strip) end
  -- The strip's own title: display face at D2, like every other display line
  -- in the addon (Morpheus 14 was a fifth size for one string), centred with
  -- an explicit width pair rather than by anchoring TOP and hoping.
  strip.title = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge") -- D2
  strip.title:SetPoint("TOPLEFT", INSET, -10)
  strip.title:SetPoint("TOPRIGHT", -INSET, -10)
  strip.title:SetJustifyH("CENTER")
  strip.title:SetWordWrap(false)
  strip.title:SetMaxLines(1)
  if PG.Theme and PG.Theme.SetFont then PG.Theme.SetFont(strip.title, "D2") end
  strip.title:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  shadow(strip.title)
  strip.rows, strip.tallies, strip.pins = {}, {}, {}
  for r = 1, #MARKETS do
    local mk = MARKETS[r]
    local y = -34 - (r - 1) * 34
    if PG.Theme and PG.Theme.Tex then
      local emblem = strip:CreateTexture(nil, "ARTWORK")
      emblem:SetSize(20, 20)
      emblem:SetPoint("LEFT", strip, "TOPLEFT", 14, y - 17)
      if not PG.Theme.Tex(emblem, MARKET_ICON[mk.m]) then
        emblem:Hide() -- no emblem; the labels carry the meaning
      end
    end
    local label = strip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", strip, "TOPLEFT", 40, y - 17)
    label:SetText(mk.label)
    label:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
    shadow(label)
    local btns = {}
    for i = 1, #mk.opts do
      local opt = mk.opts[i]
      -- ticket-stub card face; falls back to the plain UIPanelButtonTemplate
      -- construction inside PG.UI.CardButton (identical geometry either way)
      local b = PG.UI.CardButton(strip, opt[1], 92, 26, function() placeBet(mk.m, opt[2]) end)
      b:SetPoint("LEFT", strip, "TOPLEFT", 112 + (i - 1) * 96, y - 17)
      b.baseLabel = opt[1]
      b.pick = opt[2]
      btns[i] = b
    end
    strip.rows[mk.m] = btns
    local tally = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tally:SetPoint("RIGHT", strip, "TOPRIGHT", -14, y - 17)
    tally:SetJustifyH("RIGHT")
    tally:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
    shadow(tally)
    strip.tallies[mk.m] = tally
    local rule = strip:CreateTexture(nil, "BORDER")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 14, y - 33)
    rule:SetPoint("TOPRIGHT", -14, y - 33)
    rule:SetColorTexture(P.CHALK[1], P.CHALK[2], P.CHALK[3], 0.30)
    if PG.Theme and PG.Theme.Tex and strip.__pgFX then
      -- lock pin lives on the fx child frame so it draws above the buttons;
      -- it is state (not FX), so it is never registered for OnHide hiding
      local pin = strip.__pgFX:CreateTexture(nil, "OVERLAY")
      pin:SetSize(14, 14)
      PG.Theme.Tex(pin, "ticket")
      pin:Hide()
      strip.pins[mk.m] = pin
    end
  end
  strip:Hide()
end

local function maybeShowStrip()
  local book = myBook()
  local s = PG.Safety.state
  if not (book and attempt) or attempt.frozen then return end
  if s.inEncounter or s.restricted or s.inCombat then return end
  if PG.IsDND() or PG.Comm.Locked() then return end
  if not strip then buildStrip() end
  refreshStrip()
  strip:Show()
end

-------------------------------------------------------------------------------
-- Book lifecycle: creation, eviction, supersession, the sweep, the one ticker
-------------------------------------------------------------------------------

local function addLauncherRow(rec)
  if not (PG.Launcher and PG.Launcher.AddOpenGame) then return end
  pcall(PG.Launcher.AddOpenGame, {
    game = "PB", host = rec.bookie, token = rec.token,
    scope = rec.scope, expires = rec.expires,
  })
end

local function removeLauncherRow(rec)
  if not (PG.Launcher and PG.Launcher.RemoveOpenGame) then return end
  pcall(PG.Launcher.RemoveOpenGame, "PB", rec.bookie, rec.token)
end

-- The ONLY place a record leaves the registry, and the only place `mine` is
-- cleared. Every eviction poisons the key, takes down the launcher row and any
-- invitation it raised, and - for the involved record - drops the attempt and
-- the strip with it, so an overheard book can never leave state behind.
local function evict(rec)
  if not rec or books[rec.key] ~= rec then return end
  books[rec.key] = nil
  poison(rec.key)
  if rec.askKey then PG.UI.Dismiss(rec.askKey) end -- PB raises none today; teardown stays exact
  removeLauncherRow(rec)
  if mine == rec.key then
    mine = nil
    attempt = nil
    hideStrip()
  end
end

-- Ends one book and says so. The closing podium reads the record's tally before
-- the state is dropped, and its subtitle is the closing line itself, so the
-- toast would only repeat it. Queueing never touches state.
local function closeBook(rec, text)
  if not rec then return end
  local staged = false
  if rec.key == mine then staged = closePodium(rec, text) end
  evict(rec)
  if text and not staged then toast(text, rec) end
  if refreshDialog then refreshDialog() end
end

local function adoptFull(rec)
  rec.kind = "full"
  rec.expires = nil
  rec.lastHB = GetTime()
  books[rec.key] = rec
  mine = rec.key
  attempt = nil
  removeLauncherRow(rec)
  ensureTicker()
  if refreshDialog then refreshDialog() end
end

local function addLite(rec)
  rec.kind = "lite"
  rec.expires = GetTime() + LITE_TTL
  books[rec.key] = rec
  addLauncherRow(rec)
  ensureTicker()
end

-- Row 6 of the decision table: at the cap, the oldest overheard book yields.
local function evictOldestLite()
  local oldest
  for _, rec in pairs(books) do
    if rec.kind == "lite" and (not oldest or (rec.openedAt or 0) < (oldest.openedAt or 0)) then
      oldest = rec
    end
  end
  if oldest then evict(oldest) end
end

-- CONCURRENCY.md 4.3: the newest OPEN from a given bookie replaces that
-- bookie's previous book on every client, unconditionally, at any age. It is
-- deterministic without any comparison because the bookie is the sole authority
-- for its own books: if it is opening a new one, its old one is over on the
-- bookie, whatever we still believe. This is what un-strands a client that
-- missed CLOSE and would otherwise be silently excluded from every future book.
local function supersede(sender, token)
  for _, rec in pairs(books) do
    if rec.bookie == sender and rec.token ~= token then
      if rec.kind == "full" then
        closeBook(rec, shortOf(sender) .. " opened a new Pull Book - the old one is closed.")
      else
        evict(rec) -- silently: it never had a popup or a settlement
      end
    end
  end
end

local function sweep()
  local now = GetTime()
  for _, rec in pairs(books) do
    if rec.kind == "lite" and now > (rec.expires or 0) then evict(rec) end
  end
  while recentQ[1] and (now - (recent[recentQ[1]] or 0)) > RECENT_TTL do
    local key = table.remove(recentQ, 1)
    recent[key] = nil
  end
end

-- `recent` deliberately does NOT hold the ticker up: it is capped at
-- MAX_RECENT keys and its TTL is re-checked at lookup, so a poisoned key needs
-- no timer to stay correct.
local function stopTickerIfIdle()
  if not regTicker then return end
  if next(books) or revealQ[1] then return end
  regTicker:Cancel()
  regTicker = nil
end

-- ONE ticker for the module (I9): the bookie's heartbeat and transport
-- watchdog, the client's liveness deadline, the 2-second registry sweep and the
-- results-stage pump all ride it. It runs only while the registry or the stage
-- queue has something in it.
local function onTick()
  tickN = tickN + 1
  local book = myBook()
  if book then
    local now = GetTime()
    if book.isBookie then
      -- SCOPE.md 6.1: the audience the book was opened for has to still exist.
      -- Availability is a group test, not a lockdown test, so a boss fight
      -- never trips this - but a loading screen can blink the group away for a
      -- frame, so the loss has to persist before the book dies. Sends are
      -- refused for the whole grace anyway (Comm checks availability too).
      local ok, why = PG.Comm.ScopeAvailable(book.scope, 8)
      if not ok then
        book.scopeLostAt = book.scopeLostAt or now
        if (now - book.scopeLostAt) >= 5 then
          closeBook(book, "The Pull Book closed - " .. (why or "that audience is gone."))
        end
      else
        book.scopeLostAt = nil
        if not PG.Comm.Locked() and (now - (book.lastSend or 0)) >= HB_SECS then
          book.lastSend = now
          PG.Comm.Broadcast(book.scope, "PB", "HB", book.token)
        end
      end
    else
      local s = PG.Safety.state
      if s.inEncounter or s.restricted or PG.Comm.Locked() then
        book.lastHB = now -- the bookie cannot legally send; suspend the deadline
      elseif (now - (book.lastHB or 0)) > HB_MISS_SECS then
        closeBook(book, "The Pull Book closed (lost contact with the bookie).")
      end
    end
  end
  if (tickN % 4) == 0 then sweep() end
  pumpReveal()
  stopTickerIfIdle()
end

ensureTicker = function()
  if regTicker then return end
  regTicker = PG.Ticker(TICK, onTick)
end

-------------------------------------------------------------------------------
-- Encounter resolution
-------------------------------------------------------------------------------

local function resolveEncounter(encounterName, success, encounterUnitStatus)
  local book = myBook()
  local a = attempt
  if not (book and a and a.frozen) or a.resolvedKW then return end
  a.resolvedKW = true
  a.resolvedAt = GetTime() -- for the fast-repull grace window (READY_ON)
  local succ = PG.SafeNum(success)
  local encName = PG.SafeStr(encounterName) or "encounter"
  a.reason = "Pull Book: " .. encName

  -- bossPct: kill -> 0; wipe -> min remainingHealthPercent over the (non-
  -- secret, per platform rule 3) encounterUnitStatus array. Anything secret,
  -- missing or non-numeric leaves bossPct nil -> W market void.
  local bossPct
  if succ == 1 then
    bossPct = 0
  elseif succ then
    if not PG.IsSecret(encounterUnitStatus) and type(encounterUnitStatus) == "table" then
      for i = 1, #encounterUnitStatus do
        local e = encounterUnitStatus[i]
        if not PG.IsSecret(e) and type(e) == "table" then
          local hp = PG.SafeNum(e.remainingHealthPercent)
          if hp and (not bossPct or hp < bossPct) then bossPct = hp end
        end
      end
    end
  end

  -- the outcome line in both renderings: a toast head when the markets stay
  -- quiet, the stage subtitle when they do not (a queued stage can land well
  -- after the pull, so it names the encounter it belongs to)
  local rep = newReport()
  if totalBetCount(a.bets) > 0 then
    local pct = bossPct and math.floor(bossPct + 0.5) or nil
    if succ == 1 then
      rep.head = "Pull Book: " .. P.chgreen .. "kill!|r"
      rep.sub = encName .. " - kill!"
    elseif succ then
      rep.head = pct and string.format("Pull Book: %swipe at %d%%.|r", P.chred, pct)
        or ("Pull Book: " .. P.chred .. "wipe.|r")
      rep.sub = pct and string.format("%s - wipe at %d%%", encName, pct)
        or (encName .. " - wipe")
    else
      rep.head = "Pull Book: could not read the encounter result."
      rep.sub = encName .. " - result unreadable"
    end
  end

  -- succ unreadable/secret -> both immediate markets void
  settleMarket(book, a, "K", succ and (succ == 1 and "Y" or "N") or nil, "Kill bet", rep)
  settleMarket(book, a, "W", bossPct and (bossPct > book.line and "O" or "U") or nil,
    "Boss HP bet", rep)
  -- the D market is still out; say so on the stage rather than leave a gap
  if marketBetCount(a.bets, "D") > 0 then
    repAdd(rep, nil, nil, "First death bet: settling...", "body")
  end
  emitReport(rep, book, "THE BOOK SETTLES", "excited")

  PG.After(FD_VOID_SECS, function()
    if attempt == a and not a.dDone then finishD(nil, nil) end
  end)
  if book.isBookie then
    PG.After(1, bookieSendFD)
    PG.After(4, bookieSendFD)
    PG.After(8, bookieSendFD)
  end
end

local function onEncounterEnd(_, _, encounterName, _, _, success, encounterUnitStatus)
  -- args are combat-adjacent: secrecy-checked inside, pcall as second defense
  local ok, err = pcall(resolveEncounter, encounterName, success, encounterUnitStatus)
  if not ok then geterrorhandler()(err) end
end

-- Bookie-only observation: the first UNIT_DIED GUID that is non-secret AND in
-- the roster snapshot is the attempt's first death.
local function onUnitDied(_, guid)
  pcall(function()
    local book = myBook()
    if not (book and book.isBookie) then return end
    local a = attempt
    if not a or not a.frozen or a.resolvedKW or a.firstDeath then return end
    if PG.IsSecret(guid) or type(guid) ~= "string" then return end
    local entry = a.snap and a.snap[guid]
    if entry then
      a.firstDeath = { role = entry.role, name = entry.name }
    end
  end)
end

-------------------------------------------------------------------------------
-- Bookie dialog
-------------------------------------------------------------------------------

-- The picker is the authority on the audience; "group" is the floor because it
-- is the only audience this game has ever had.
local function pickedScope()
  if picker and picker.Get then
    local s = picker:Get()
    if s and PG.PB.SCOPES[s] then return s end
    return nil
  end
  return "group"
end

local function tryOpenBook()
  -- I3: this module is already involved in a book. The dialog explains itself
  -- (the status panel replaces the config widgets); it never refuses blankly,
  -- and it never consults another module, the seat, or anyone else's session.
  if myBook() then
    refreshDialog()
    return
  end
  local scope = pickedScope()
  if not scope then
    local _, why = PG.Comm.ScopeAvailable("group")
    toast("The Pull Book: " .. (why or "you're not in a party or raid."))
    if picker then picker:Refresh() end
    return
  end
  -- re-checked at the moment Start is pressed: the player can leave the group
  -- between opening this dialog and clicking (SCOPE.md 1.3)
  local ok, why = PG.Comm.ScopeAvailable(scope)
  if not ok then
    toast("The Pull Book: " .. (why or "that audience isn't available."))
    if picker then picker:Refresh() end
    return
  end
  if PG.Comm.Locked() then
    toast("Cannot open the book right now (messaging is locked).")
    return
  end
  local me = PG.FullName("player")
  if not me then return end
  -- clamp-to-bounds, matching LG's dialog behavior (non-numeric -> default)
  local stake = math.floor(tonumber(stakeBox:GetText() or "") or 100)
  if stake < STAKE_MIN then stake = STAKE_MIN elseif stake > STAKE_MAX then stake = STAKE_MAX end
  stakeBox:SetText(tostring(stake))
  local line = math.floor(tonumber(lineBox:GetText() or "") or 50)
  if line < LINE_MIN then line = LINE_MIN elseif line > LINE_MAX then line = LINE_MAX end
  lineBox:SetText(tostring(line))
  local token = nextToken()
  local code = PG.Comm.ScopeCode(scope)
  if not code then return end
  if PG.Comm.Broadcast(scope, "PB", "OPEN", token, stake, line, code) then
    -- built synchronously in the frame that broadcast it, so a double click
    -- cannot emit two OPENs: the check at the top of this function now sees it
    local key = keyOf(me, token)
    books[key] = {
      kind = "full", key = key, token = token, bookie = me, scope = scope,
      stake = stake, line = line, isBookie = true,
      openedAt = GetTime(), lastSend = GetTime(), lastHB = GetTime(),
    }
    mine = key
    attempt = nil
    ensureTicker()
    refreshDialog()
    toast("The Pull Book is open - " .. P.chgold .. PG.Money(stake) .. "|r a bet, wipe line "
      .. line .. "%.")
  end
end

local function bookieClose()
  local book = myBook()
  if not (book and book.isBookie) then return end
  PG.Comm.Broadcast(book.scope, "PB", "CLOSE", book.token)
  closeBook(book, "You closed the Pull Book.")
end

-- One field row, the same shape as the other five games' (F15): label LEFT at
-- the shared inset, box right-anchored at the same inset, box 2px above the
-- label's line. It used to sit at 24/-30 with the label 4px lower.
local function numBox(parent, labelText, defaultText, maxLetters, y)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")     -- T
  label:SetPoint("TOPLEFT", INSET, y)
  label:SetText(labelText)
  label:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3]) -- chalk on the board
  shadow(label)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(70, 20)
  eb:SetPoint("TOPRIGHT", -INSET, y + 2)
  eb:SetAutoFocus(false)
  eb:SetNumeric(true)
  eb:SetMaxLetters(maxLetters)
  eb:SetText(defaultText)
  return eb, label
end

-- 340x340 -> 340x380. Three things had to fit that did not: the audience block
-- is 58 tall now (its hint used to render 13px outside the rect it declared),
-- the open-book status panel is bounded instead of growing without limit, and
-- the goblin bookie had to move out of the bottom-LEFT corner so the Rules
-- button can sit where it sits in the other five dialogs (F12) - the two used
-- to overlap by 1px, with 9px of Rules unclickable under the resize grip.
local function buildDialog()
  dlg = PG.UI.Window("pullbook", "The Pull Book", 340, 380, "PB")
  local stakeLabel, lineLabel, hint, openBtn, poster, posterOK
  -- notice-board poster (SKIN.md 2.6). The poster slot is positioned whether
  -- or not the atlas renders, so the layout never depends on the art: the
  -- hint always sits in the slot, restyled per surface.
  poster = dlg:CreateTexture(nil, "ARTWORK")
  poster:SetSize(300, 88)
  poster:SetPoint("TOP", 0, -40)   -- 4 under the title container (-12..-36)
  posterOK = (PG.Theme and PG.Theme.Tex) and PG.Theme.Tex(poster, "warboard") or false
  if not posterOK then poster:Hide() end
  dlg.__pgStampSlot = poster -- BOOK OPEN/CLOSED stamps slam across the poster
  hint = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")         -- S
  hint:SetPoint("TOPLEFT", poster, "TOPLEFT", 18, -16)
  hint:SetPoint("TOPRIGHT", poster, "TOPRIGHT", -18, -16)
  hint:SetJustifyH("LEFT")   -- body copy, like every other dialog hint
  hint:SetJustifyV("TOP")
  hint:SetHeight(48)
  hint:SetWordWrap(true)
  hint:SetMaxLines(4)
  hint:SetText("Bets open on a strip at every ready check or pull timer. All gold is virtual - settle up after.")
  if posterOK then
    hint:SetTextColor(P.INK[1], P.INK[2], P.INK[3]) -- ink on parchment, no shadow
  else
    hint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
    shadow(hint) -- chalk-gray straight on the board
  end
  stakeBox, stakeLabel = numBox(dlg, "Stake per bet (gold)", "100", 6, -136)
  lineBox, lineLabel = numBox(dlg, "Wipe line (boss HP %)", "50", 2, -168)
  -- Audience (SCOPE.md 5.3): all three segments render, Guild and Public
  -- permanently disabled with the reason. This is not decoration - it is the
  -- answer to "why can't I run a book for the guild", delivered at the exact
  -- moment the question is asked.
  if PG.UI.ScopePicker then
    picker = PG.UI.ScopePicker(dlg, {
      key = "PB",
      allowed = PG.PB.SCOPES,
      width = 340,
      reasons = function(scope)
        if scope == "group" then return nil end
        return WIDE_SCOPE_REASON
      end,
    })
    picker:SetPoint("TOPLEFT", dlg, "TOPLEFT", 0, -200)
    picker:SetPoint("TOPRIGHT", dlg, "TOPRIGHT", 0, -200)
  end
  -- The primary button is centred and the Rules button sits BOTTOMLEFT 16,18
  -- at 60x22, exactly as in the other five dialogs (F12). The +30 x-offset
  -- pushed "Open book" onto "Rules" in both dialog states.
  openBtn = PG.UI.Button(dlg, mark("ticket") .. " Open book", 150, 26, tryOpenBook)
  openBtn:SetPoint("BOTTOM", 0, 18)
  local dlgRules = PG.UI.Button(dlg, "Rules", 60, 22, function()
    if PG.Rules and PG.Rules.Show then PG.Rules.Show("PB") end
  end)
  dlgRules:SetPoint("BOTTOMLEFT", 16, 18)
  -- The open-book panel: one centred display headline and a bounded body. The
  -- body used to have no height and no line cap while carrying four real
  -- paragraphs plus one line per overheard book, so it cleared the bookie by
  -- luck and grew towards him with every book in earshot (A11).
  statusHead = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")  -- D2
  statusHead:SetPoint("TOPLEFT", INSET, -56)
  statusHead:SetPoint("TOPRIGHT", -INSET, -56)
  statusHead:SetJustifyH("CENTER")
  statusHead:SetWordWrap(false)
  statusHead:SetMaxLines(1)
  if PG.Theme and PG.Theme.SetFont then PG.Theme.SetFont(statusHead, "D2") end
  statusHead:SetTextColor(P.CHGOLD[1], P.CHGOLD[2], P.CHGOLD[3])
  shadow(statusHead)
  statusFS = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")       -- B
  statusFS:SetPoint("TOPLEFT", INSET, -88)
  statusFS:SetPoint("TOPRIGHT", -INSET, -88)
  statusFS:SetJustifyH("LEFT")   -- four paragraphs of body copy: LEFT
  statusFS:SetJustifyV("TOP")
  statusFS:SetHeight(140)   -- 10 lines; the worst real case is 9
  statusFS:SetWordWrap(true)
  statusFS:SetMaxLines(10)
  statusFS:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  shadow(statusFS)
  closeBtn = PG.UI.Button(dlg, "Close book", 150, 26, bookieClose)
  closeBtn:SetPoint("BOTTOM", 0, 18)
  configWidgets = { stakeLabel, stakeBox, lineLabel, lineBox, hint, openBtn }
  if picker then configWidgets[#configWidgets + 1] = picker end
  if posterOK then configWidgets[#configWidgets + 1] = poster end
  -- Decorative goblin bookie (SKIN.md 2.6), bottom-RIGHT: the bottom-left
  -- corner is the Rules button's slot in every dialog, and at 80x100 from the
  -- left he also had the audience picker's first segment across his head.
  -- Decor moves, navigation does not (F12). x 252..332 clears the centred
  -- 150px primary button (ends 245) and the picker block above him (ends
  -- -258 against his -262 top).
  if PG.Theme and PG.Theme.NPC then
    local npc = PG.Theme.NPC(dlg, "bookie")
    bookieNPC = npc -- the results stage nods to him; Emote self-gates on visibility
    npc.frame:SetSize(80, 100)
    npc.frame:ClearAllPoints()
    npc.frame:SetPoint("BOTTOMRIGHT", -8, 18)
    dlg:HookScript("OnShow", function()
      npc:Emote("greet")
      if PG.Theme.Sound then PG.Theme.Sound("greet") end
    end)
  end
  -- stamp + sound garnish on the dialog buttons; hooks run AFTER the click
  -- handler, so the registry already reflects whether the action happened
  if PG.Theme then
    openBtn:HookScript("OnClick", function()
      local book = myBook()
      if book and book.isBookie then
        if PG.Theme.Sound then PG.Theme.Sound("stamp") end
        if PG.Theme.Stamp then PG.Theme.Stamp(dlg, "BOOK OPEN") end
      end
    end)
    closeBtn:HookScript("OnClick", function()
      if not myBook() then
        if PG.Theme.Sound then PG.Theme.Sound("bookclose") end
        if PG.Theme.Stamp then PG.Theme.Stamp(dlg, "BOOK CLOSED") end
      end
    end)
  end
end

-- How many other books we can hear right now (lite records). One line in the
-- status panel: an overheard book is not a second book we are in, and the only
-- thing the user can do with it is switch once this one ends.
local function otherBookLine()
  local n, who = 0, nil
  for _, rec in pairs(books) do
    if rec.kind == "lite" then
      n = n + 1
      who = who or shortOf(rec.bookie)
    end
  end
  if n == 0 then return "" end
  -- |n, the addon's one line-break idiom (F17): this file used to be the only
  -- one writing real "\n", so a grep for one missed the other
  if n == 1 then
    return "|n|n" .. P.chgray .. who .. " is running another book - it's in the Pengyou Games window.|r"
  end
  return "|n|n" .. P.chgray .. n .. " other books are open - they're in the Pengyou Games window.|r"
end

refreshDialog = function()
  if not dlg then return end
  local book = myBook()
  local isOpen = book ~= nil
  for i = 1, #configWidgets do
    configWidgets[i]:SetShown(not isOpen)
  end
  statusFS:SetShown(isOpen)
  statusHead:SetShown(isOpen)
  closeBtn:SetShown(isOpen and book.isBookie or false)
  -- availability is a live query: the config side reappearing after a book ends
  -- must show the audience as it is now, not as it was when the book opened
  if not isOpen and picker then picker:Refresh() end
  if book then
    -- the headline states WHOSE book and what it costs; the body carries the
    -- rest as body copy, which is why the two are separate fontstrings
    local who = book.isBookie and "Your book is open" or (shortOf(book.bookie) .. "'s book is open")
    statusHead:SetText(who)
    statusFS:SetText(P.chgold .. tmoney(book.stake) .. "|r a bet, wipe line "
      .. book.line .. "%.|n|nAudience: Party."
      .. "|n|nThe bet strip appears at every ready check or pull timer."
      .. otherBookLine())
  end
end

function PG.PB.OpenDialog()
  if not dlg then buildDialog() end
  refreshDialog()
  dlg:Show()
end

-- A view of the books we can hear but are not in, for the launcher's Open games
-- list (CONCURRENCY.md 5.10). It is a view, not a second store: rows come from
-- lite records and disappear when those records are evicted.
function PG.PB.OpenBooks()
  local out = {}
  for _, rec in pairs(books) do
    if rec.kind == "lite" then
      out[#out + 1] = {
        game = "PB", host = rec.bookie, token = rec.token, scope = rec.scope,
        stake = rec.stake, line = rec.line, expires = rec.expires,
      }
    end
  end
  table.sort(out, function(x, y) return x.host < y.host end)
  return out
end

-- Switch to an overheard book (the launcher's Join button). No wire traffic:
-- joining a book is just agreeing to score the same pull, and betting starts at
-- the next ready check. Refused while we are already in one - first book wins,
-- and full multi-book is deliberately not v1 (CONCURRENCY.md 9.8).
function PG.PB.JoinBook(host, token)
  local h, t = PG.SafeStr(host), PG.SafeStr(token)
  if not (h and t) then return false end
  local rec = books[keyOf(h, t)]
  if not rec or rec.kind ~= "lite" then return false end
  if myBook() then
    toast("You're already in " .. shortOf(myBook().bookie) .. "'s Pull Book.")
    return false
  end
  adoptFull(rec)
  toast(shortOf(rec.bookie) .. "'s Pull Book - " .. P.chgold .. PG.Money(rec.stake)
    .. "|r a bet, wipe line " .. rec.line .. "%.", rec)
  return true
end

-------------------------------------------------------------------------------
-- Wire handling
--
-- Gate order (CONCURRENCY.md 5.2). Gates a-e are Comm's (version, distribution
-- -> scope, accept/trust, rate limit, module route). Here:
--   f  mtype class      bookie-authored vs the table's BET; unknown -> drop
--   g  session          books[keyOf(sender, token)], or - for BET - the
--                       involved book matched on (bookie, token). No record ->
--                       drop. THIS is what makes two books non-interfering; the
--                       old `token ~= book.token` test was a filter, not a
--                       router, and matching a BET on the token alone let a
--                       colliding token cross-contaminate the settlement.
--   h  kind             a lite record accepts only CLOSE (evict) and HB
--                       (refresh). It never reaches an applier.
--   i  scope equality   blocks re-broadcasting a book's token on another
--                       distribution.
--   j  sender authority bookie-authored is guaranteed by g's key; BET must come
--                       from someone actually at the table.
-------------------------------------------------------------------------------

-- Everything a lite record is allowed to do: die, or stay alive a little longer.
local function liteObserve(rec, mtype)
  if mtype == "HB" then
    rec.lastHB = GetTime()
    rec.expires = GetTime() + LITE_TTL
  elseif mtype == "CLOSE" then
    evict(rec)
  end
end

-- Decision table for an inbound OPEN (CONCURRENCY.md 4.2), evaluated in order.
-- Row 1 (self) is Comm's; rows 2-7 are here. Note what is NOT here any more:
-- the blanket "a book is already open, ignore" refusal. An OPEN is never
-- refused because a session exists.
local function onOpen(token, sender, scope, f1, f2, f3)
  -- row 2: malformed fields, or a scope this game does not play to
  local stake = PG.SafeNum(f1)
  local line = PG.SafeNum(f2)
  if not (stake and line) then return end
  stake, line = math.floor(stake), math.floor(line)
  if stake < STAKE_MIN or stake > STAKE_MAX then return end
  if line < LINE_MIN or line > LINE_MAX then return end
  -- the declared code exists to be CHECKED against the delivered distribution,
  -- never trusted: a wire field can claim guild on a PARTY message, a
  -- distribution cannot (SCOPE.md 3.1)
  local declared = PG.Comm.ScopeOfCode(PG.SafeStr(f3))
  if not declared or declared ~= scope then return end
  if scope == "private" then return end -- an OPEN must never arrive by whisper
  if not PG.PB.SCOPES[scope] then return end

  local key = keyOf(sender, token)
  -- row 3: a finished book's key can never be resurrected
  if recent[key] and (GetTime() - recent[key]) < RECENT_TTL then return end
  -- row 4: idempotent. A retransmitted OPEN refreshes liveness and nothing else
  local rec = books[key]
  if rec then
    rec.lastHB = GetTime()
    if rec.kind == "lite" then rec.expires = GetTime() + LITE_TTL end
    return
  end
  -- row 5: supersession (which may have just freed the full slot)
  supersede(sender, token)
  -- row 6: the lite budget. Only relevant when this OPEN is heading for a lite
  -- record; with no book of our own it becomes the full one instead.
  if mine and liteCount() >= MAX_LITE then evictOldestLite() end

  -- row 7: create the record
  rec = {
    key = key, token = token, bookie = sender, scope = scope,
    stake = stake, line = line, isBookie = false, openedAt = GetTime(),
    lastHB = GetTime(),
  }
  if not mine then
    -- First book wins, as it always has. At party scope hearing the book IS the
    -- invitation: there is no seat, no buy-in and nothing to consent to until
    -- the strip appears at the next pull, and the local player can simply not
    -- bet. (I7's "no state without consent" is a WIDE-scope rule; the Pull Book
    -- has no wide scope, by physics.)
    adoptFull(rec)
    toast(shortOf(sender) .. " opened the Pull Book - " .. P.chgold .. PG.Money(stake)
      .. "|r a bet, wipe line " .. line .. "%.", rec)
  else
    -- We are already in a book: this one is remembered cheaply and offered in
    -- the launcher. Silent - a second bookie must not interrupt the first one's
    -- table (CONCURRENCY.md 6.2).
    addLite(rec)
  end
end

local function onMessage(mtype, token, sender, scope, f1, f2, f3)
  if PG.IsSecret(f1) or PG.IsSecret(f2) or PG.IsSecret(f3) then return end
  if type(mtype) ~= "string" or type(sender) ~= "string" then return end
  if not validToken(token) then return end
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3) end

  -- gate f + g
  local rec
  if BOOKIE_AUTHORED[mtype] then
    rec = books[keyOf(sender, token)]
  elseif mtype == "BET" then
    -- gate g: identity is the PAIR, and BET is the one broadcast in the suite
    -- that cannot be keyed on the sender - so it names its bookie (f3). Without
    -- that field a token collision (host-unique only, CONCURRENCY.md 3.2) folds
    -- another table's bettors into our book and pays them at our stake, which is
    -- the single place two sessions can corrupt each other's numbers.
    -- PG.SafeStr returns nil for a secret or non-string, and m.bookie is always
    -- a realm-qualified string, so a missing field drops the message.
    local m = myBook()
    if m and m.token == token and PG.SafeStr(f3) == m.bookie then rec = m end
  else
    return
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype) end -- gate h
  if scope ~= rec.scope then return end                          -- gate i

  if mtype == "BET" then
    -- gate j: a bet moves other people's money, so the sender must be at the
    -- table. No wire message may fabricate an attempt (CONCURRENCY.md 4.5):
    -- only the bookie's own READY_ON / COUNTDOWN_ON opens a bet window.
    local a = attempt
    if not a or a.frozen then return end -- post-freeze bets ignored
    local s = PG.Safety.state
    if s.inEncounter or s.restricted then return end
    if type(f1) ~= "string" or not (VALID_PICK[f1] and VALID_PICK[f1][f2]) then return end
    if not inGroupNow(sender) then return end
    local picks = a.bets[sender]
    if not picks then
      picks = {}
      a.bets[sender] = picks
    end
    if not picks[f1] then picks[f1] = f2 end -- first pick per market locks
    refreshStrip() -- presentation only: the chalk tallies are live backer counts
    return
  end

  -- everything below is bookie-authored, and gate g already proved the sender
  -- IS this record's bookie (the key is bookie|token)
  rec.lastHB = GetTime()
  if mtype == "CLOSE" then
    closeBook(rec, shortOf(sender) .. " closed the Pull Book.")
  elseif mtype == "FD" then
    if f1 == "NONE" then
      finishD(nil, nil)
    elseif f1 == "T" or f1 == "H" or f1 == "D" then
      local dead = (type(f2) == "string" and f2 ~= "-" and f2 ~= "") and f2 or nil
      finishD(f1, dead)
    end
  end
end

-- Lockdown drops are permanent (never retried). The token says WHICH book lost
-- the message, so another session's drop can never abort ours (CONCURRENCY.md
-- 5.5). A dropped OPEN means nobody heard the book exists; un-open it. Dropped
-- BET/FD/HB: the ledger is social, not authoritative (documented v1
-- limitation) - nothing to redo.
local function onDrop(mtype, token)
  if mtype ~= "OPEN" then return end
  local book = myBook()
  if not (book and book.isBookie) then return end
  if PG.SafeStr(token) ~= book.token then return end
  closeBook(book, "The book could not be opened (messaging is locked).")
end

-------------------------------------------------------------------------------
-- Bookie: broadcast the first-death adjudication after the restriction lifts,
-- and resolve D locally only once the FD has ACTUALLY gone out (onSent, not
-- the queued-ok return value): a queued-then-lockdown-dropped FD leaves the
-- attempt intact, so the 1/4/8s retries still apply and, failing those, the
-- 20s deadline voids D here identically to every client. Duplicate FDs from
-- overlapping retries are harmless: everyone (including us) settles D once.
-------------------------------------------------------------------------------

bookieSendFD = function()
  local book = myBook()
  local a = attempt
  if not (book and book.isBookie and a and a.resolvedKW) then return end
  if a.dDone or a.fdSent then return end
  if PG.Comm.Locked() then return end
  local role, name = "NONE", "-"
  if a.firstDeath then
    role, name = a.firstDeath.role, a.firstDeath.name
  end
  PG.Comm.BroadcastEx({
    scope = book.scope,
    onSent = function()
      if attempt ~= a or a.dDone then return end
      a.fdSent = true
      if role == "NONE" then
        finishD(nil, nil)
      else
        finishD(role, name)
      end
    end,
  }, "PB", "FD", book.token, role, name)
end

-------------------------------------------------------------------------------
-- Safety transitions
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
  local book = myBook()
  if trigger == "READY_ON" or trigger == "COUNTDOWN_ON" then
    if not book then return end
    if state.inEncounter or state.restricted or PG.Comm.Locked() then return end
    -- fast re-pull while first-death is still unresolved: void it, start
    -- fresh - but give a just-resolved encounter a 3s grace window (> the
    -- bookie's 1s FD delay) so an FD already in flight is not voided here
    -- while the bookie and faster clients settle it
    if attempt and attempt.resolvedKW and not attempt.dDone
      and (GetTime() - (attempt.resolvedAt or 0)) > 3 then
      finishD(nil, nil)
    end
    if not attempt then attempt = newAttempt(book) end
    if attempt.frozen then return end
    if book.isBookie and not state.inCombat then
      lastSnap = PG.RosterSnapshot() -- snapshot only out of combat (rule 4 hygiene)
      attempt.snap = lastSnap
    end
    maybeShowStrip()
  elseif trigger == "ENCOUNTER_ON" or trigger == "RESTRICT_ON" then
    hideStrip()
    if attempt and not attempt.frozen and not attempt.resolvedKW then
      attempt.frozen = true
    end
  elseif trigger == "COMBAT_ON" then
    hideStrip()
  elseif trigger == "COMBAT_OFF" then
    -- a bet window that opened during trash combat shows once combat drops
    -- (maybeShowStrip re-checks every gate itself)
    if state.readyCheck or state.countdown then maybeShowStrip() end
  elseif trigger == "READY_OFF" then
    -- attempt stays pending; the next ready check / countdown reshows it
    if not state.countdown then hideStrip() end
  elseif trigger == "COUNTDOWN_OFF" then
    -- presentation only: a pull timer just ran out (or was cancelled), so the
    -- results stage keeps clear for PULL_GRACE; no gameplay path reads this
    pullAt = GetTime()
    if not state.readyCheck then hideStrip() end
  elseif trigger == "RESTRICT_OFF" then
    -- restriction came and went without an encounter end (M+/PvP start that
    -- fizzled): the pending attempt thaws, locked picks stay locked
    if attempt and attempt.frozen and not attempt.resolvedKW and not state.inEncounter then
      attempt.frozen = false
    end
  end
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

PG.RegisterInit(function()
  -- capture the one palette from the theme layer (SKIN.md 5.8); the literal
  -- defaults above are the same values, so this is a formality, not a branch
  if PG.Theme and PG.Theme.C then
    local c = PG.Theme.C()
    for k in pairs(P) do
      if c[k] ~= nil then P[k] = c[k] end
    end
  end
  PG.Comm.Register("PB", onMessage, onDrop)
  -- The Pull Book is party-only, so every whisper it could ever receive is
  -- already covered by Comm's group test: it vouches for nobody (SCOPE.md 4.3).
  if PG.Comm.RegisterTrust then
    PG.Comm.RegisterTrust("PB", function() return false end)
  end
  PG.Safety.OnChange(onSafetyChange)
  PG.RegisterEvent("ENCOUNTER_END", onEncounterEnd)
  PG.RegisterEvent("UNIT_DIED", onUnitDied) -- registration pcall-guarded in the hub
end)
