-- Games/PullBook.lua - The Pull Book: pre-pull betting (bookie + client + UI).
local ADDON, PG = ...

PG.PB = {}

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

-------------------------------------------------------------------------------
-- Presentation (SKIN.md "faire": Darkmoon bookmaker). Markup and color only:
-- every helper degrades to plain text / today's look when the theme layer is
-- absent, and no gameplay path branches on any of it.
-------------------------------------------------------------------------------

-- Faire palette, literal spec values (SKIN.md 1.1); refreshed from PG.Theme.C
-- at init when the theme layer is present (the values are identical).
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

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- book: nil, or { token, bookie = "Name-Realm", stake, line, isBookie }
local book
-- attempt: nil, or { bets = { [fullName] = { K=, D=, W= } }, frozen, snap,
--   firstDeath = { role, name } (bookie only), resolvedKW, dDone, fdSent, reason }
local attempt
local lastSnap        -- bookie's latest out-of-combat roster snapshot { [guid] = { name, role } }
local lastHB = 0      -- client: GetTime() of last sign of life from the bookie
local hbTicker        -- bookie: 15s heartbeat
local staleTicker     -- client: 5s bookie-liveness check

local strip           -- bet strip frame (NOT Safety-registered; managed manually)
local dlg, stakeBox, lineBox, statusFS, closeBtn, configWidgets
local bookieNPC       -- the dialog's goblin bookie handle (Emote self-gates)
local pullAt = 0      -- GetTime() of the last pull-timer expiry (see PULL_GRACE)

local refreshDialog   -- forward: defined in the dialog section

local function shortOf(full)
  return (strsplit("-", tostring(full or "?")))
end

-------------------------------------------------------------------------------
-- Result queue: results may arrive while the screen is not ours (encounter /
-- restriction / combat); queue and drain once the coast is clear. Two kinds of
-- item ride the same FIFO with the same semantics - a plain toast, and a
-- reveal-stage payload (REVEAL.md 6.5), which is only handed to
-- PG.Theme.RevealQueue at a moment the Pull Book is also happy with; the
-- engine then applies its own five-flag gate on top and holds it further if
-- the coast turns bad. Draining is presentation only; nothing here feeds
-- gameplay, and no drain path can alter the ledger or the wire.
-------------------------------------------------------------------------------

local toastQueue = {}
local toastTicker

local function canToastNow()
  local s = PG.Safety.state
  return not (s.inCombat or s.inEncounter or s.restricted)
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

-- Plain toasts keep exactly today's gate; a stage answers stageGatesOK too.
local function canDrainNow(item)
  if not canToastNow() then return false end
  if not item.reveal then return true end
  return stageGatesOK()
end

-- One item per tick, oldest drainable first. Toasts keep their exact order and
-- their exact gate, so a stage waiting out a pull never holds text back.
local function pumpToasts()
  if not toastQueue[1] then
    if toastTicker then
      toastTicker:Cancel()
      toastTicker = nil
    end
    return
  end
  for i = 1, #toastQueue do
    if canDrainNow(toastQueue[i]) then
      local item = table.remove(toastQueue, i)
      if item.reveal then
        -- decoration doctrine: we never branch on the result. The engine drops
        -- the payload under DND exactly as PG.UI.Toast drops a toast, and the
        -- ledger keeps the money either way.
        if PG.Theme and PG.Theme.RevealQueue then PG.Theme.RevealQueue(item.reveal) end
        return
      end
      PG.UI.Toast(item.text)
      -- settle chime on a drained result toast with a personal delta (SKIN.md
      -- 2.8); Theme.Sound applies its own gates on top of canToastNow here
      if item.snd and not PG.IsDND() and PG.Theme and PG.Theme.Sound then
        PG.Theme.Sound(item.snd)
      end
      return
    end
  end
end

local function startPump()
  if not toastTicker then
    toastTicker = PG.Ticker(3.2, pumpToasts)
    pumpToasts()
  end
end

-- sndKey (optional): Theme.Sound key played when this toast actually drains.
local function queueToast(text, sndKey)
  local pre = mark("ticket")
  if pre ~= "" then text = pre .. " " .. text end
  toastQueue[#toastQueue + 1] = { text = text, snd = sndKey }
  startPump()
end

local function queueReveal(payload)
  toastQueue[#toastQueue + 1] = { reveal = payload }
  startPump()
end

-- Drain-time gate for every PB stage payload. Handing a payload to the engine
-- only relinquishes the toast-queue gate: the engine's own gate is the five
-- Safety flags, and a payload that lands in the engine queue while the stage is
-- busy can sit there across a whole ready check plus countdown and then drain
-- on COUNTDOWN_OFF - the one moment PULL_GRACE exists to protect. So the same
-- gate is re-applied at drain. The engine DISCARDS a payload whose validate
-- returns false and a settlement must eventually show, so a veto puts the
-- payload back in our own queue, where canDrainNow holds it properly.
-- Presentation only: no gameplay path, ledger write or wire send reads this.
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
local function bookTally(name, delta)
  if not book then return end
  local nets = book.nets
  if not nets then
    nets = {}
    book.nets = nets
  end
  nets[name] = (nets[name] or 0) + delta
end

local function stakeLine()
  if not book then return nil end
  return "STAKE " .. PG.Money(book.stake) .. " A BET"
end

-- One settlement moment's report: ordered lines, each carrying the exact toast
-- text used when the stage is unavailable AND the stage row. `paid` counts
-- markets that actually paid out; `mine` is my total delta across them; `head`
-- / `sub` are the outcome line in its two renderings.
local function newReport()
  return { lines = {}, paid = 0 }
end

-- toastText nil -> a line that exists on the stage only (nothing to toast).
local function repAdd(rep, toastText, snd, rowText, rowRole)
  rep.lines[#rep.lines + 1] = { toast = toastText, snd = snd, row = rowText, role = rowRole }
end

local function flushToasts(rep)
  if rep.head then queueToast(rep.head) end
  for i = 1, #rep.lines do
    local ln = rep.lines[i]
    if ln.toast then queueToast(ln.toast, ln.snd) end
  end
end

local function emitReport(rep, title, emote)
  if rep.paid < 1 or not (PG.Theme and PG.Theme.RevealQueue) then
    flushToasts(rep)
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
    theme = "faire", anchor = { mode = "screen" },
    title = title,
    subtitle = rep.sub,
    rows = rows,
    marquee = stakeLine(),
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
local function closePodium(sub)
  if not (book and book.nets and PG.Theme and PG.Theme.RevealQueue) then return false end
  local list, any = {}, false
  for name, net in pairs(book.nets) do
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
    theme = "faire", anchor = { mode = "screen" }, variant = "podium",
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
-- Parimutuel math
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
  return deltas, #winners, pot
end

-- Settles one market: applies ledger deltas and records the result line in the
-- caller's report (rep), which decides afterwards whether the moment gets the
-- stage or the quiet toasts. winPick == nil means the market is void by rule
-- (unreadable result / no FD). Silent when nobody bet the market.
local function settleMarket(a, m, winPick, label, rep)
  if marketBetCount(a.bets, m) == 0 then return end
  if not winPick then
    repAdd(rep, P.chgray .. label .. ": void, stakes returned.|r", nil,
      label .. ": void, stakes returned", "fade")
    return
  end
  local deltas, nWin, pot = resolveMarket(a.bets, m, winPick, book.stake)
  if not deltas then
    repAdd(rep, P.chgray .. label .. ": void (not enough action), stakes returned.|r", nil,
      label .. ": void (not enough action)", "fade")
    return
  end
  for name, delta in pairs(deltas) do
    PG.Ledger.Add(name, delta, a.reason)
    bookTally(name, delta) -- presentation-only tally for the closing podium
  end
  local me = PG.FullName("player")
  local mine = me and deltas[me]
  local won = nWin .. (nWin == 1 and " winner takes " or " winners split ")
  local line = label .. ": " .. won .. P.chgold .. PG.Money(pot) .. "|r"
  local snd
  if mine then
    line = line .. " - you " .. (mine >= 0 and (P.chgreen .. "+" .. PG.Money(mine) .. "|r")
      or (P.chred .. PG.Money(mine) .. "|r"))
    snd = "settled"
    rep.mine = (rep.mine or 0) + mine
  end
  rep.paid = rep.paid + 1
  repAdd(rep, line, snd, label .. ": " .. won .. tmoney(pot), "win")
end

-- Resolves the first-death market and ends the attempt. winPick nil -> void.
local function finishD(winPick, deadName)
  local a = attempt
  if not a or not a.resolvedKW or a.dDone then return end
  a.dDone = true
  if marketBetCount(a.bets, "D") > 0 then
    if winPick then
      local word = ROLE_WORD[winPick] or winPick
      local header = "First death: " .. P.chred .. word .. "|r"
      if deadName then header = header .. " (" .. deadName .. ")" end
      local rep = newReport()
      rep.head = header .. "."
      rep.sub = word .. " fell first" .. (deadName and (" - " .. shortOf(deadName)) or "")
      settleMarket(a, "D", winPick, "First death bet", rep)
      emitReport(rep, "FIRST DEATH", "point")
    else
      queueToast(P.chgray .. "First death bet: void, stakes returned.|r")
    end
  end
  attempt = nil
end

local function newAttempt()
  return { bets = {}, frozen = false, snap = lastSnap }
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
  if not (strip and book) then return end
  local pre = mark("ticket")
  if pre ~= "" then pre = pre .. " " end
  strip.title:SetText(pre .. "The Pull Book - " .. PG.Money(book.stake) .. " a bet")
  local me = PG.FullName("player")
  local mine = (attempt and me) and attempt.bets[me] or nil
  local bets = attempt and attempt.bets or nil
  for r = 1, #MARKETS do
    local mk = MARKETS[r]
    local btns = strip.rows[mk.m]
    local locked = mine and mine[mk.m]
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
  local mine = (attempt and me) and attempt.bets[me] or nil
  local locked = mine and mine[m]
  if not locked then return end
  local btns = strip.rows[m]
  if not btns then return end
  for i = 1, #btns do
    if btns[i].pick == locked then PG.Theme.Pulse(btns[i]) end
  end
end

local function placeBet(m, p)
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
  }, "PB", "BET", book.token, m, p)
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
  strip.title = strip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  strip.title:SetPoint("TOP", 0, -10)
  if PG.Theme and PG.Theme.SetHeader then PG.Theme.SetHeader(strip.title, 14) end
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
  local s = PG.Safety.state
  if not (book and attempt) or attempt.frozen then return end
  if s.inEncounter or s.restricted or s.inCombat then return end
  if PG.IsDND() or PG.Comm.Locked() then return end
  if not strip then buildStrip() end
  refreshStrip()
  strip:Show()
end

-------------------------------------------------------------------------------
-- Book lifecycle
-------------------------------------------------------------------------------

local function clearAll(toastText)
  if hbTicker then
    hbTicker:Cancel()
    hbTicker = nil
  end
  if staleTicker then
    staleTicker:Cancel()
    staleTicker = nil
  end
  -- closing podium first: it reads the book's tally before the state is
  -- dropped, and its subtitle is the closing line itself, so the toast would
  -- only repeat it. Queued like everything else; queueing never touches state.
  local staged = closePodium(toastText)
  book, attempt = nil, nil
  hideStrip()
  if refreshDialog then refreshDialog() end
  if toastText and not staged then queueToast(toastText) end
end

local function startHBTicker()
  if hbTicker then hbTicker:Cancel() end
  hbTicker = PG.Ticker(HB_SECS, function()
    if book and book.isBookie and not PG.Comm.Locked() then
      PG.Comm.Broadcast("PB", "HB", book.token)
    end
  end)
end

local function startStaleTicker()
  if staleTicker then staleTicker:Cancel() end
  lastHB = GetTime()
  staleTicker = PG.Ticker(5, function()
    if not book or book.isBookie then return end
    local s = PG.Safety.state
    if s.inEncounter or s.restricted or PG.Comm.Locked() then
      lastHB = GetTime() -- bookie cannot legally send; suspend the deadline
      return
    end
    if GetTime() - lastHB > HB_MISS_SECS then
      clearAll("The Pull Book closed (lost contact with the bookie).")
    end
  end)
end

-- Bookie: broadcast the first-death adjudication after the restriction lifts,
-- and resolve D locally only once the FD has ACTUALLY gone out (onSent, not
-- the queued-ok return value): a queued-then-lockdown-dropped FD leaves the
-- attempt intact, so the 1/4/8s retries still apply and, failing those, the
-- 20s deadline voids D here identically to every client. Duplicate FDs from
-- overlapping retries are harmless: everyone (including us) settles D once.
local function bookieSendFD()
  local a = attempt
  if not (book and book.isBookie and a and a.resolvedKW) then return end
  if a.dDone or a.fdSent then return end
  if PG.Comm.Locked() then return end
  local role, name = "NONE", "-"
  if a.firstDeath then
    role, name = a.firstDeath.role, a.firstDeath.name
  end
  PG.Comm.BroadcastEx({
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
-- Encounter resolution
-------------------------------------------------------------------------------

local function resolveEncounter(encounterName, success, encounterUnitStatus)
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
  settleMarket(a, "K", succ and (succ == 1 and "Y" or "N") or nil, "Kill bet", rep)
  settleMarket(a, "W", bossPct and (bossPct > book.line and "O" or "U") or nil, "Boss HP bet", rep)
  -- the D market is still out; say so on the stage rather than leave a gap
  if marketBetCount(a.bets, "D") > 0 then
    repAdd(rep, nil, nil, "First death bet: settling...", "body")
  end
  emitReport(rep, "THE BOOK SETTLES", "excited")

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

local function tryOpenBook()
  if book then
    refreshDialog()
    return
  end
  if not IsInGroup() then
    queueToast("The Pull Book needs a group.")
    return
  end
  if PG.Comm.Locked() then
    queueToast("Cannot open the book right now (messaging is locked).")
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
  local token = (UnitName("player") or "?") .. "-" .. math.random(10000, 99999)
  if PG.Comm.Broadcast("PB", "OPEN", token, stake, line) then
    book = { token = token, bookie = me, stake = stake, line = line, isBookie = true }
    startHBTicker()
    refreshDialog()
    queueToast("The Pull Book is open - " .. P.chgold .. PG.Money(stake) .. "|r a bet, wipe line "
      .. line .. "%.")
  end
end

local function bookieClose()
  if not (book and book.isBookie) then return end
  PG.Comm.Broadcast("PB", "CLOSE", book.token)
  clearAll("You closed the Pull Book.")
end

local function numBox(parent, labelText, defaultText, maxLetters, y)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("TOPLEFT", 24, y - 4)
  label:SetText(labelText)
  label:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3]) -- chalk on the board
  shadow(label)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(70, 20)
  eb:SetPoint("TOPRIGHT", -30, y)
  eb:SetAutoFocus(false)
  eb:SetNumeric(true)
  eb:SetMaxLetters(maxLetters)
  eb:SetText(defaultText)
  return eb, label
end

local function buildDialog()
  dlg = PG.UI.Window("pullbook", "The Pull Book", 340, 300, "faire")
  local stakeLabel, lineLabel, hint, openBtn, poster, posterOK
  -- notice-board poster (SKIN.md 2.6). The poster slot is positioned whether
  -- or not the atlas renders, so the layout never depends on the art: the
  -- hint always sits in the slot, restyled per surface.
  poster = dlg:CreateTexture(nil, "ARTWORK")
  poster:SetSize(300, 88)
  poster:SetPoint("TOP", 0, -34)
  posterOK = (PG.Theme and PG.Theme.Tex) and PG.Theme.Tex(poster, "warboard") or false
  if not posterOK then poster:Hide() end
  dlg.__pgStampSlot = poster -- BOOK OPEN/CLOSED stamps slam across the poster
  hint = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hint:SetPoint("TOPLEFT", poster, "TOPLEFT", 18, -16)
  hint:SetPoint("TOPRIGHT", poster, "TOPRIGHT", -18, -16)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(true)
  hint:SetText("Bets open on a strip at every ready check or pull timer. All gold is virtual - settle up after.")
  if posterOK then
    hint:SetTextColor(P.INK[1], P.INK[2], P.INK[3]) -- ink on parchment, no shadow
  else
    hint:SetTextColor(P.CHGRAY[1], P.CHGRAY[2], P.CHGRAY[3])
    shadow(hint) -- chalk-gray straight on the board
  end
  stakeBox, stakeLabel = numBox(dlg, "Stake per bet (gold)", "100", 6, -136)
  lineBox, lineLabel = numBox(dlg, "Wipe line (boss HP %)", "50", 2, -168)
  openBtn = PG.UI.Button(dlg, mark("ticket") .. " Open book", 150, 24, tryOpenBook)
  openBtn:SetPoint("BOTTOM", 30, 18)
  statusFS = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  statusFS:SetPoint("TOPLEFT", 24, -56)
  statusFS:SetPoint("TOPRIGHT", -24, -56)
  statusFS:SetJustifyH("LEFT")
  statusFS:SetTextColor(P.CHALK[1], P.CHALK[2], P.CHALK[3])
  shadow(statusFS)
  closeBtn = PG.UI.Button(dlg, "Close book", 150, 24, bookieClose)
  closeBtn:SetPoint("BOTTOM", 30, 18)
  configWidgets = { stakeLabel, stakeBox, lineLabel, lineBox, hint, openBtn }
  if posterOK then configWidgets[#configWidgets + 1] = poster end
  -- decorative goblin bookie in the bottom-left corner (SKIN.md 2.6)
  if PG.Theme and PG.Theme.NPC then
    local npc = PG.Theme.NPC(dlg, "bookie")
    bookieNPC = npc -- the results stage nods to him; Emote self-gates on visibility
    npc.frame:SetSize(80, 100)
    npc.frame:ClearAllPoints()
    npc.frame:SetPoint("BOTTOMLEFT", 18, 16)
    dlg:HookScript("OnShow", function()
      npc:Emote("greet")
      if PG.Theme.Sound then PG.Theme.Sound("greet") end
    end)
  end
  -- stamp + sound garnish on the dialog buttons; hooks run AFTER the click
  -- handler, so `book` already reflects whether the action actually happened
  if PG.Theme then
    openBtn:HookScript("OnClick", function()
      if book and book.isBookie then
        if PG.Theme.Sound then PG.Theme.Sound("stamp") end
        if PG.Theme.Stamp then PG.Theme.Stamp(dlg, "BOOK OPEN") end
      end
    end)
    closeBtn:HookScript("OnClick", function()
      if not book then
        if PG.Theme.Sound then PG.Theme.Sound("bookclose") end
        if PG.Theme.Stamp then PG.Theme.Stamp(dlg, "BOOK CLOSED") end
      end
    end)
  end
end

refreshDialog = function()
  if not dlg then return end
  local isOpen = book ~= nil
  for i = 1, #configWidgets do
    configWidgets[i]:SetShown(not isOpen)
  end
  statusFS:SetShown(isOpen)
  closeBtn:SetShown(isOpen and book.isBookie or false)
  if book then
    local who = book.isBookie and "Your book is open" or (shortOf(book.bookie) .. "'s book is open")
    statusFS:SetText(who .. " - " .. P.chgold .. tmoney(book.stake) .. "|r a bet, wipe line "
      .. book.line .. "%.\n\nThe bet strip appears at every ready check or pull timer.")
  end
end

function PG.PB.OpenDialog()
  if not dlg then buildDialog() end
  refreshDialog()
  dlg:Show()
end

-------------------------------------------------------------------------------
-- Wire handling
-------------------------------------------------------------------------------

local function onMessage(mtype, token, sender, f1, f2)
  if PG.IsSecret(token) or PG.IsSecret(f1) or PG.IsSecret(f2) then return end
  if type(token) ~= "string" then return end

  if mtype == "OPEN" then
    local stake = tonumber(f1)
    local line = tonumber(f2)
    if not (stake and line) then return end
    stake, line = math.floor(stake), math.floor(line)
    if stake < STAKE_MIN or stake > STAKE_MAX then return end
    if line < LINE_MIN or line > LINE_MAX then return end
    if book then
      -- one book per group: any OPEN while a book is live is ignored
      if book.token == token and sender == book.bookie then lastHB = GetTime() end
      return
    end
    book = { token = token, bookie = sender, stake = stake, line = line, isBookie = false }
    startStaleTicker()
    refreshDialog()
    queueToast(shortOf(sender) .. " opened the Pull Book - " .. P.chgold .. PG.Money(stake)
      .. "|r a bet, wipe line " .. line .. "%.")
    return
  end

  if not book or token ~= book.token then return end

  if mtype == "BET" then
    if attempt and attempt.frozen then return end -- post-freeze bets ignored
    local s = PG.Safety.state
    if s.inEncounter or s.restricted then return end
    if type(f1) ~= "string" or not (VALID_PICK[f1] and VALID_PICK[f1][f2]) then return end
    -- a BET implies a bet window we may have missed the event for
    if not attempt then attempt = newAttempt() end
    local picks = attempt.bets[sender]
    if not picks then
      picks = {}
      attempt.bets[sender] = picks
    end
    if not picks[f1] then picks[f1] = f2 end -- first pick per market locks
    refreshStrip() -- presentation only: the chalk tallies are live backer counts
    return
  end

  if sender ~= book.bookie then return end

  if mtype == "CLOSE" then
    clearAll(shortOf(sender) .. " closed the Pull Book.")
  elseif mtype == "HB" then
    lastHB = GetTime()
  elseif mtype == "FD" then
    lastHB = GetTime()
    if f1 == "NONE" then
      finishD(nil, nil)
    elseif f1 == "T" or f1 == "H" or f1 == "D" then
      local dead = (type(f2) == "string" and f2 ~= "-" and f2 ~= "") and f2 or nil
      finishD(f1, dead)
    end
  end
end

local function onDrop(mtype)
  -- Lockdown drops are permanent (never retried). A dropped OPEN means nobody
  -- heard the book exists; un-open it. Dropped BET/FD/HB: the ledger is
  -- social, not authoritative (documented v1 limitation) - nothing to redo.
  if mtype == "OPEN" and book and book.isBookie then
    clearAll("The book could not be opened (messaging is locked).")
  end
end

-------------------------------------------------------------------------------
-- Safety transitions
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
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
    if not attempt then attempt = newAttempt() end
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
  -- capture the faire palette from the theme layer (SKIN.md 5.8); the literal
  -- defaults above are the same values, so this is a formality, not a branch
  if PG.Theme and PG.Theme.C then
    local c = PG.Theme.C("faire")
    for k in pairs(P) do
      if c[k] ~= nil then P[k] = c[k] end
    end
  end
  PG.Comm.Register("PB", onMessage, onDrop)
  PG.Safety.OnChange(onSafetyChange)
  PG.RegisterEvent("ENCOUNTER_END", onEncounterEnd)
  PG.RegisterEvent("UNIT_DIED", onUnitDied) -- registration pcall-guarded in the hub
end)
