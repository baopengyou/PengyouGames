-- Launcher.lua - the launcher window: entry points into games, ledger, DND.
local ADDON, PG = ...

PG.Launcher = {}

local win, dndBtn

-------------------------------------------------------------------------------
-- The Open games list (SCOPE.md 6.3, CONCURRENCY.md 5.10).
--
-- This section is the ONLY surface for an invitation that never pops: a public
-- open (which is never allowed a popup), any open that arrives while the single
-- round-based seat is held, an open past ASK_MAX, and a guild open over its
-- invite budget. Without it those invitations are simply lost, and the toasts
-- that point at "the Pengyou Games window" point at nothing.
--
-- It is a VIEW, never a second store (5.10 rule 2): the rows are a projection of
-- the games' own lite records, rebuilt from them on show and on a slow ticker,
-- so a row can never outlive the record behind it - and a row with no record
-- behind it would be unjoinable, since every Join resolves through the module's
-- registry.
-------------------------------------------------------------------------------

local MAX_OPEN_ROWS = 5     -- SCOPE.md 6.3
local OPEN_ROW_H = 22
local OPEN_TTL = 60         -- seconds a row is offered, however long its record lives
local BASE_HEIGHT = 394     -- the window without the section (7 buttons + DND sign)
local LIST_TICK = 2         -- reconcile cadence while the window is open

-- ASCII only, per the source rule: SCOPE.md 6.3's separator is U+00B7.
local GAME_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors", PB = "Pull Book",
                    IB = "Idle Battle (dev)" }
local GAME_SHORT = { LG = "Goblins", RPS = "RPS", PB = "Book", IB = "Battle" }
-- CONCURRENCY.md 5.10 rule 1 lists opens "at every scope including group", so
-- the label set is wider than SCOPE.md 6.3's Guild|Public table.
local SCOPE_LABEL = { group = "Party", guild = "Guild", public = "Public" }

local openRows = {}   -- [game|host|token] = entry
local rowFrames = {}  -- the five rows, built once with the window
local listTicker
local refreshList

local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

-- Every field arrives from a wire-derived record, so every field is validated
-- here (PG.SafeStr / PG.SafeNum both reject secret values).
local function entryOf(t, now)
  if type(t) ~= "table" then return nil end
  local game = PG.SafeStr(t.game)
  if not game or not GAME_NAME[game] then return nil end
  local host = PG.SafeStr(t.host)
  if not host or host == "" or #host > 64 then return nil end
  local token = PG.SafeStr(t.token)
  if not token or token == "" or #token > 24 or token:find("|", 1, true) then return nil end
  local scope = PG.SafeStr(t.scope)
  if not scope or not SCOPE_LABEL[scope] then return nil end
  local key = PG.SafeStr(t.key)
  if key == "" then key = nil end
  return {
    game = game,
    host = host,
    token = token,
    scope = scope,
    -- the games all key their registries host .. "|" .. token, so a projection
    -- that omits the composite key (the Pull Book's) still resolves
    key = key or (host .. "|" .. token),
    expires = PG.SafeNum(t.expires) or (now + OPEN_TTL),
    addedAt = now,
  }
end

local function storeEntry(e)
  local k = e.game .. "|" .. e.host .. "|" .. e.token
  local prev = openRows[k]
  if prev then
    -- refresh in place; the TTL clock keeps running from when the row first
    -- appeared, so a heartbeat-extended record cannot hold a row forever
    prev.scope = e.scope
    prev.expires = e.expires
    prev.key = e.key
  else
    openRows[k] = e
  end
end

local function cull(now)
  for k, e in pairs(openRows) do
    if now > e.expires or (now - e.addedAt) > OPEN_TTL then openRows[k] = nil end
  end
end

-- Rebuild from the modules' own projections. Push (AddOpenGame) keeps the list
-- responsive; this is what keeps it HONEST - a record swept, superseded,
-- cancelled or begun elsewhere takes its row with it whether or not its
-- eviction path remembered to call RemoveOpenGame.
local PROJECTIONS = {
  LG = function() return PG.LG and PG.LG.OpenGames and PG.LG.OpenGames() end,
  RPS = function() return PG.RPS and PG.RPS.OpenGames and PG.RPS.OpenGames() end,
  -- note the name: the Pull Book projects OpenBooks, not OpenGames
  PB = function() return PG.PB and PG.PB.OpenBooks and PG.PB.OpenBooks() end,
  IB = function() return PG.IB and PG.IB.OpenGames and PG.IB.OpenGames() end,
}

local function reconcile()
  local now = GetTime()
  for game, fn in pairs(PROJECTIONS) do
    local ok, list = pcall(fn)
    if ok and type(list) == "table" then
      -- this game's rows are replaced wholesale by what it actually holds
      local keep = {}
      for k, e in pairs(openRows) do
        if e.game == game then
          keep[k] = e.addedAt
          openRows[k] = nil
        end
      end
      for i = 1, #list do
        local e = entryOf(list[i], now)
        if e then
          local k = e.game .. "|" .. e.host .. "|" .. e.token
          e.addedAt = keep[k] or now -- a surviving row keeps its own TTL clock
          storeEntry(e)
        end
      end
    end
  end
  cull(now)
end

-- At most five rows, one per sender (SCOPE.md 6.3), the nearest to expiring
-- first. Ignored senders need no filter here: Comm drops them before any module
-- handler runs, so no lite record - and therefore no row - can exist for one.
local function visibleRows()
  local byHost = {}
  for _, e in pairs(openRows) do
    local cur = byHost[e.host]
    if not cur or e.expires > cur.expires then byHost[e.host] = e end
  end
  local list = {}
  for _, e in pairs(byHost) do list[#list + 1] = e end
  table.sort(list, function(a, b)
    if a.expires ~= b.expires then return a.expires < b.expires end
    if a.host ~= b.host then return a.host < b.host end
    return a.game < b.game
  end)
  while #list > MAX_OPEN_ROWS do table.remove(list) end
  return list
end

-- The seat blocks a join only for the seat-consuming games. Being in a Pull
-- Book is not busy and the Pull Book claims no seat (I10, CONCURRENCY.md 6.1),
-- so a PB row stays live while you play Loot Goblins - PG.PB.JoinBook applies
-- its own first-book-wins refusal. Returns the seat view when blocked.
local function blockedBy(entry)
  if not entry or entry.game == "PB" then return nil end
  if not (PG.Session and PG.Session.IsSeated and PG.Session.IsSeated()) then return nil end
  return PG.Session.Seat()
end

-- Join runs the module's existing accept path unchanged: it claims the seat
-- first, whispers JOIN and requests a resync, which is exactly SCOPE.md 6.3's
-- "public sessions construct S only on an explicit Join click".
local function joinEntry(entry)
  if not entry then return end
  if entry.game == "LG" then
    if PG.LG and PG.LG.JoinOpen then pcall(PG.LG.JoinOpen, entry.key) end
  elseif entry.game == "RPS" then
    if PG.RPS and PG.RPS.JoinOpen then pcall(PG.RPS.JoinOpen, entry.key) end
  elseif entry.game == "PB" then
    if PG.PB and PG.PB.JoinBook then pcall(PG.PB.JoinBook, entry.host, entry.token) end
  elseif entry.game == "IB" then
    if PG.IB and PG.IB.JoinOpen then pcall(PG.IB.JoinOpen, entry.key) end
  end
  reconcile()
  refreshList()
end

local function rowTooltip(self)
  local e = self.__pgRow and self.__pgRow.__pgEntry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(GAME_NAME[e.game] or e.game)
  GameTooltip:AddLine(e.host .. "  (" .. (SCOPE_LABEL[e.scope] or e.scope) .. ")", 1, 1, 1)
  local seat = blockedBy(e)
  if seat then
    GameTooltip:AddLine("You're playing " .. shortOf(seat.host) .. "'s "
      .. (GAME_NAME[seat.module] or "game") .. " right now.", 1, 0.5, 0.5, true)
  end
  GameTooltip:Show()
end

local function buildOpenRows()
  for i = 1, MAX_OPEN_ROWS do
    -- built ONCE, with the window, and shown/hidden from here on: no frame is
    -- ever created per refresh, so nothing churns during combat
    local row = CreateFrame("Frame", nil, win)
    row:SetSize(190, OPEN_ROW_H)
    if i == 1 then
      row:SetPoint("TOP", dndBtn, "BOTTOM", 0, -12)
    else
      row:SetPoint("TOP", rowFrames[i - 1], "BOTTOM", 0, 0)
    end
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.label:SetPoint("LEFT", 0, 0)
    row.label:SetWidth(126)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.joinBtn = PG.UI.Button(row, "Join", 58, 20, function()
      joinEntry(row.__pgEntry)
    end)
    row.joinBtn:SetPoint("RIGHT", 0, 0)
    row.joinBtn.__pgRow = row
    row.joinBtn:HookScript("OnEnter", rowTooltip)
    row.joinBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    rowFrames[i] = row
  end
end

-- Paint the rows and resize the window around them. Tolerates a list that
-- exists before the window does: an OPEN can arrive long before the user first
-- opens the launcher, and build() is lazy.
refreshList = function()
  if not win then return end
  local list = visibleRows()
  for i = 1, MAX_OPEN_ROWS do
    local row = rowFrames[i]
    local e = list[i]
    row.__pgEntry = e
    if e then
      row.label:SetText(shortOf(e.host) .. " - " .. (GAME_SHORT[e.game] or e.game)
        .. " - " .. (SCOPE_LABEL[e.scope] or e.scope))
      row.joinBtn:SetEnabled(blockedBy(e) == nil)
      row:Show()
    else
      row:Hide()
    end
  end
  local h = BASE_HEIGHT + OPEN_ROW_H * #list
  if math.abs(win:GetHeight() - h) > 0.5 then
    win:SetHeight(h)
    if win:IsShown() and PG.UI.ResolveOverlaps then PG.UI.ResolveOverlaps(win) end
  end
end

-- The ticker runs only while the window is open: the list is a convenience, not
-- a background service, and nothing about it needs to be true off screen.
local function syncListTicker()
  local want = (win and win:IsShown()) and true or false
  if want and not listTicker then
    listTicker = PG.Ticker(LIST_TICK, function()
      if not (win and win:IsShown()) then
        syncListTicker()
        return
      end
      reconcile()
      refreshList()
    end)
  elseif not want and listTicker then
    listTicker:Cancel()
    listTicker = nil
  end
end

-- Called from each game's OPEN handler for every lite record it creates. Must
-- survive being called before the window has ever been built.
function PG.Launcher.AddOpenGame(t)
  local e = entryOf(t, GetTime())
  if not e then return false end
  storeEntry(e)
  refreshList()
  return true
end

function PG.Launcher.RemoveOpenGame(game, host, token)
  game, host, token = PG.SafeStr(game), PG.SafeStr(host), PG.SafeStr(token)
  if not (game and host and token) then return false end
  local k = game .. "|" .. host .. "|" .. token
  if not openRows[k] then return false end
  openRows[k] = nil
  refreshList()
  return true
end

-- icon markup prefix for a button label; plain label when the theme layer is
-- absent (presentation only, SKIN.md 2.1)
local function markLabel(key, label)
  local m = (PG.Theme and PG.Theme.Mark) and PG.Theme.Mark(key) or ""
  if m ~= "" then return m .. " " .. label end
  return label
end

-- DND toggle styled as the carnival stall's hung sign: OPEN / CLOSED.
-- Bright faire hexes (the button face is dark); the DND wording stays so the
-- function reads plainly. Text only - the sign itself never animates.
local function refreshDnd()
  if dndBtn then
    dndBtn:SetText(PG.IsDND() and "|cffff8a70CLOSED|r (DND on)"
      or "|cff7deda4OPEN|r (DND off)")
  end
end

local function build()
  win = PG.UI.Window("launcher", "Pengyou Games", 240, 358, "neutral")
  -- carnival-sign tagline under the title (decor only)
  local tagline = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  tagline:SetPoint("TOP", 0, -40)
  tagline:SetText("Step right up - games, wagers, glory")
  tagline:SetTextColor(0.80, 0.68, 0.42) -- BRASS
  -- Game dialogs live in their game files; guard in case a module failed to load.
  local lgBtn = PG.UI.Button(win, markLabel("coin", "Loot Goblins..."), 190, 26, function()
    if PG.LG and PG.LG.OpenDialog then PG.LG.OpenDialog() end
  end)
  lgBtn:SetPoint("TOP", 0, -62)
  local pbBtn = PG.UI.Button(win, markLabel("ticket", "Pull Book..."), 190, 26, function()
    if PG.PB and PG.PB.OpenDialog then PG.PB.OpenDialog() end
  end)
  pbBtn:SetPoint("TOP", lgBtn, "BOTTOM", 0, -10)
  local rpsBtn = PG.UI.Button(win, markLabel("dice", "Rock Paper Scissors..."), 190, 26, function()
    if PG.RPS and PG.RPS.OpenDialog then PG.RPS.OpenDialog() end
  end)
  rpsBtn:SetPoint("TOP", pbBtn, "BOTTOM", 0, -10)
  local ibBtn = PG.UI.Button(win, "Idle Battle (dev)...", 190, 26, function()
    if PG.IB and PG.IB.OpenDialog then PG.IB.OpenDialog() end
  end)
  ibBtn:SetPoint("TOP", rpsBtn, "BOTTOM", 0, -10)
  local ledgerBtn = PG.UI.Button(win, markLabel("sack", "Ledger"), 190, 26, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ledgerBtn:SetPoint("TOP", ibBtn, "BOTTOM", 0, -10)
  local rulesBtn = PG.UI.Button(win, "Rules", 190, 26, function()
    if PG.Rules and PG.Rules.Toggle then PG.Rules.Toggle() end
  end)
  rulesBtn:SetPoint("TOP", ledgerBtn, "BOTTOM", 0, -10)
  local settingsBtn = PG.UI.Button(win, "Settings", 190, 26, function()
    if PG.Settings and PG.Settings.Show then PG.Settings.Show() end
  end)
  settingsBtn:SetPoint("TOP", rulesBtn, "BOTTOM", 0, -10)
  dndBtn = PG.UI.Button(win, "", 190, 26, function()
    PG.ToggleDND()
    refreshDnd()
  end)
  dndBtn:SetPoint("TOP", settingsBtn, "BOTTOM", 0, -16)
  buildOpenRows()
  -- HookScript, not SetScript: the theme's Skin already hooked OnShow (pop-in)
  win:HookScript("OnShow", function()
    refreshDnd()
    -- the list is rebuilt from the records on every show, so it can never
    -- present a game that ended while the window was closed
    reconcile()
    refreshList()
    syncListTicker()
  end)
  win:HookScript("OnHide", syncListTicker)
  refreshDnd()
  reconcile()
  refreshList()
end

local function openSound()
  if PG.Theme and PG.Theme.Sound then
    PG.Theme.Sound("open") -- manual open only; gated inside Theme.Sound
  end
end

function PG.Launcher.Show()
  if not win then build() end
  local wasShown = win:IsShown()
  win:Show()
  if not wasShown then openSound() end
end

function PG.Launcher.Toggle()
  if not win then build() end
  if win:IsShown() then
    win:Hide()
  else
    win:Show()
    openSound()
  end
end

-------------------------------------------------------------------------------
-- Minimap button (deliberately not Safety-registered: minimap buttons persist
-- through combat like Blizzard's own; it opens nothing on its own)
-------------------------------------------------------------------------------

local mmBtn

local function mmDB()
  local p = PG.db.profile
  -- 195, not the live addon's 210: the fork installs beside it, and two
  -- buttons defaulting to the same angle stack on one spot (M5 review)
  if not p.minimap then p.minimap = { hide = false, angle = 195 } end
  return p.minimap
end

local function mmApplyPosition()
  if not mmBtn then return end
  local angle = math.rad(mmDB().angle or 195)
  local radius = (Minimap:GetWidth() / 2) + 10
  mmBtn:ClearAllPoints()
  mmBtn:SetPoint("CENTER", Minimap, "CENTER",
    math.cos(angle) * radius, math.sin(angle) * radius)
end

local function mmStartDrag(self)
  -- OnUpdate exists only while dragging; removed again in mmStopDrag
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if mx and cx and scale and scale > 0 then
      mmDB().angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
      mmApplyPosition()
    end
  end)
end

local function mmStopDrag(self)
  self:SetScript("OnUpdate", nil)
end

local function buildMinimapButton()
  mmBtn = CreateFrame("Button", "PengyouGamesDevMinimapButton", Minimap)
  mmBtn:SetSize(31, 31)
  mmBtn:SetFrameStrata("MEDIUM")
  mmBtn:SetFrameLevel(8)
  mmBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mmBtn:RegisterForDrag("LeftButton")
  mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = mmBtn:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")

  local icon = mmBtn:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -6)
  local okTex = pcall(icon.SetTexture, icon, "Interface\\Icons\\INV_Misc_Coin_02")
  if okTex then
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pcall(icon.SetMask, icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask")
  else
    icon:SetColorTexture(0.85, 0.65, 0.13)
  end

  mmBtn:SetScript("OnDragStart", mmStartDrag)
  mmBtn:SetScript("OnDragStop", mmStopDrag)
  mmBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      PG.ToggleDND()
      refreshDnd()
    else
      PG.Launcher.Toggle()
    end
  end)
  mmBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Pengyou Games")
    GameTooltip:AddLine("Left-click: launcher", 1, 1, 1)
    GameTooltip:AddLine("Right-click: toggle DND", 1, 1, 1)
    GameTooltip:AddLine("Drag to move around the minimap", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  mmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  mmApplyPosition()
end

function PG.Launcher.SetMinimapShown(shown)
  local db = mmDB()
  db.hide = not shown
  if db.hide then
    if mmBtn then mmBtn:Hide() end
  else
    if not mmBtn then buildMinimapButton() end
    mmBtn:Show()
    mmApplyPosition()
  end
  -- an open Settings window re-syncs its minimap checkbox immediately
  if PG.Settings and PG.Settings.Refresh then PG.Settings.Refresh() end
end

function PG.Launcher.ToggleMinimap()
  local db = mmDB()
  PG.Launcher.SetMinimapShown(db.hide) -- hidden -> show, shown -> hide
  DEFAULT_CHAT_FRAME:AddMessage("PengyouGames: minimap button "
    .. (db.hide and "hidden" or "shown") .. " (/pg minimap toggles)")
end

PG.RegisterInit(function()
  if not mmDB().hide then buildMinimapButton() end
  -- The seat is what disables a Join (5.10 rule 3), so the rows unlock the
  -- instant a game ends and lock the instant one is accepted - without waiting
  -- for the next ticker pass.
  if PG.Session and PG.Session.OnChange then
    PG.Session.OnChange(function() refreshList() end)
  end
end)
