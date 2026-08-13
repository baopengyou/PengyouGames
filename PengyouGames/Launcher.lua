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
local LIST_TICK = 2         -- reconcile cadence while the window is open

-- The window without the open-games section. UNCHANGED at 1.1.0 even though the
-- suite doubled from three games to six, and the derivation is written out here
-- so the next game does not have to re-measure it:
--    62  title + tagline block, down to the top of the first button
--   +78  game grid: THREE rows of 26 - six games in two columns
--   +20  two inter-row gutters of 10
--   +10  gutter into the utility column
--   +78  utility column: Ledger, Rules, Settings - three rows of 26
--   +20  two inter-row gutters of 10
--   +16  gutter into the DND sign
--   +26  the DND sign
--   +48  bottom padding (12 of which becomes the gap above open-games row 1)
--  = 358
-- Six games in two columns occupy exactly the three rows the three games of
-- 1.0.0 occupied in one, so only the WIDTH changed (240 -> 360). Only the point
-- and the per-window scale are persisted, never a size, so existing users keep
-- their launcher position and simply see a wider window.
local BASE_HEIGHT = 358
local WIN_W = 360           -- 24 + 152 + 8 + 152 + 24; see build()
local COL_W = 152           -- one grid button
local FULL_W = 312          -- WIN_W - 48: utility buttons, the DND sign, open rows

-- ASCII only, per the source rule: SCOPE.md 6.3's separator is U+00B7.
--
-- These two tables are the launcher's own copy of the module-code -> display
-- name mapping, deliberately kept local rather than promoted to Core: this file
-- is the only place a code is rendered for a game the local client may not even
-- have loaded, and entryOf's GAME_NAME lookup below is the gate on whether an
-- open-games row can exist AT ALL. A missing entry here does not error, it
-- silently drops every invitation for that game - so when a seventh game lands,
-- these are the first two lines to edit.
local GAME_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors", PB = "Pull Book",
                    DR = "Death Roll", GB = "The Gambler", QZ = "Quiz" }
local GAME_SHORT = { LG = "Goblins", RPS = "RPS", PB = "Book",
                     DR = "Death Roll", GB = "Gambler", QZ = "Quiz" }
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
  DR = function() return PG.DR and PG.DR.OpenGames and PG.DR.OpenGames() end,
  GB = function() return PG.GB and PG.GB.OpenGames and PG.GB.OpenGames() end,
  QZ = function() return PG.QZ and PG.QZ.OpenGames and PG.QZ.OpenGames() end,
  -- note the name: the Pull Book projects OpenBooks, not OpenGames
  PB = function() return PG.PB and PG.PB.OpenBooks and PG.PB.OpenBooks() end,
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

-- The seat blocks a Join only for the games that take one. Being in a Pull Book
-- is not busy and the Pull Book claims no seat (I10, CONCURRENCY.md 6.1), so a
-- PB row stays live while you play Loot Goblins - PG.PB.JoinBook applies its
-- own first-book-wins refusal.
--
-- Since 1.1.0 the test is a DECLARED FLAG on the module rather than a module
-- code written down in this file (BRIEF 1.1). With six games and one exemption,
-- a hardcoded list is a list somebody eventually forgets to extend, and the two
-- ways of forgetting are not equally bad: an exemption list that lost PB would
-- grey out a Book the player is entitled to join, with no explanation anywhere,
-- whereas a game that forgets to declare SEAT degrades to "Join enabled" and
-- its own PG.Session.Claim then refuses with the proper worded reason. So the
-- flag is read defensively and its absence means "does not take the seat".
local function takesSeat(entry)
  local m = entry and PG[entry.game]
  return (type(m) == "table" and m.SEAT == true) or false
end

local function blockedBy(entry)
  if not takesSeat(entry) then return nil end
  if not (PG.Session and PG.Session.IsSeated and PG.Session.IsSeated()) then return nil end
  return PG.Session.Seat()
end

-- Join runs the module's existing accept path unchanged: it claims the seat
-- first, whispers JOIN and requests a resync, which is exactly SCOPE.md 6.3's
-- "public sessions construct S only on an explicit Join click".
--
-- A table rather than an if/elseif chain, because six branches of the same
-- shape is where the chain stops being readable - and because the Pull Book's
-- entry point genuinely has a different NAME and a different SIGNATURE, which
-- is much easier to see when the six sit side by side.
local JOINERS = {
  LG = function(e) if PG.LG and PG.LG.JoinOpen then PG.LG.JoinOpen(e.key) end end,
  RPS = function(e) if PG.RPS and PG.RPS.JoinOpen then PG.RPS.JoinOpen(e.key) end end,
  DR = function(e) if PG.DR and PG.DR.JoinOpen then PG.DR.JoinOpen(e.key) end end,
  GB = function(e) if PG.GB and PG.GB.JoinOpen then PG.GB.JoinOpen(e.key) end end,
  QZ = function(e) if PG.QZ and PG.QZ.JoinOpen then PG.QZ.JoinOpen(e.key) end end,
  PB = function(e) if PG.PB and PG.PB.JoinBook then PG.PB.JoinBook(e.host, e.token) end end,
}

local function joinEntry(entry)
  if not entry then return end
  local fn = JOINERS[entry.game]
  -- pcall as before: a module that errors inside its own accept path must not
  -- take the launcher's repaint down with it, or the row stays on screen
  -- claiming to be joinable forever.
  if fn then pcall(fn, entry) end
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
    row:SetSize(FULL_W, OPEN_ROW_H)
    if i == 1 then
      row:SetPoint("TOP", dndBtn, "BOTTOM", 0, -12)
    else
      row:SetPoint("TOP", rowFrames[i - 1], "BOTTOM", 0, 0)
    end
    -- S role. GameFontNormalSmall defaults to GOLD and nothing here recoloured it,
    -- so these rows rendered gold while every other list in the addon is chalk.
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 0, 0)
    -- 240 + the 58px Join button = 298, leaving 14px of slack inside FULL_W.
    -- The longest realistic row text is "Grizzlebottom - Death Roll - Party".
    row.label:SetWidth(240)
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

-- The game grid, column-major: the three 1.0.0 games keep their order down the
-- LEFT column and the three 1.1.0 games fill the right, which is the same
-- grouping the Rules tab strip uses, so the two windows teach the same map.
-- Each row is { module code, theme mark key, button label }. The label is
-- written out verbatim rather than derived from GAME_NAME because these strings
-- shipped in 1.0.0 and users read them as the names of the buttons. The trailing
-- ellipsis is gone: PG.UI.Button now binds every label to w-8 and truncates, so the
-- three dots were spending ~12px to say nothing and pushed the longest label over.
local GRID = {
  { "LG", "coin", "Loot Goblins" },
  { "PB", "ticket", "Pull Book" },
  { "RPS", "dice", "Rock Paper Scissors" },
  { "DR", "skull", "Death Roll" },
  { "GB", "greedcoin", "The Gambler" },
  { "QZ", "quiz", "Quiz" },
}

local function build()
  win = PG.UI.Window("launcher", "Pengyou Games", WIN_W, BASE_HEIGHT, "neutral")
  -- carnival-sign tagline under the title (decor only)
  local tagline = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  tagline:SetPoint("TOP", 0, -40)
  tagline:SetText("Step right up - games, wagers, glory")
  tagline:SetTextColor(0.80, 0.68, 0.42) -- BRASS
  -- Game dialogs live in their game files; guard in case a module failed to
  -- load. The closure captures `code` per iteration, so the button keeps
  -- working even if the module arrives later than the launcher.
  for i = 1, #GRID do
    local code, iconKey, label = GRID[i][1], GRID[i][2], GRID[i][3]
    local row = ((i - 1) % 3) + 1
    local b = PG.UI.Button(win, markLabel(iconKey, label), COL_W, 26, function()
      local m = PG[code]
      if type(m) == "table" and m.OpenDialog then m.OpenDialog() end
    end)
    -- 36 = 26 button + 10 gutter, so the rows land at -62, -98 and -134 -
    -- exactly where the first three buttons of 1.0.0 sat.
    if i <= 3 then
      b:SetPoint("TOPLEFT", 24, -62 - (row - 1) * 36)
    else
      b:SetPoint("TOPRIGHT", -24, -62 - (row - 1) * 36)
    end
  end
  -- The utility column is one centred stack of full-width buttons, so it reads
  -- as a different KIND of thing from the grid above it. -170 is where the old
  -- `rpsBtn BOTTOM, 0, -10` anchor put it: grid row 3 top (-134) + 26 + 10.
  local ledgerBtn = PG.UI.Button(win, markLabel("sack", "Ledger"), FULL_W, 26, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ledgerBtn:SetPoint("TOP", 0, -170)
  local rulesBtn = PG.UI.Button(win, "Rules", FULL_W, 26, function()
    if PG.Rules and PG.Rules.Toggle then PG.Rules.Toggle() end
  end)
  rulesBtn:SetPoint("TOP", ledgerBtn, "BOTTOM", 0, -10)
  local settingsBtn = PG.UI.Button(win, "Settings", FULL_W, 26, function()
    if PG.Settings and PG.Settings.Show then PG.Settings.Show() end
  end)
  settingsBtn:SetPoint("TOP", rulesBtn, "BOTTOM", 0, -10)
  dndBtn = PG.UI.Button(win, "", FULL_W, 26, function()
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
  if not p.minimap then p.minimap = { hide = false, angle = 210 } end
  return p.minimap
end

local function mmApplyPosition()
  if not mmBtn then return end
  local angle = math.rad(mmDB().angle or 210)
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
  mmBtn = CreateFrame("Button", "PengyouGamesMinimapButton", Minimap)
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
