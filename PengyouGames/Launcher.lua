-- Launcher.lua - the launcher window: entry points into games, ledger, DND.
local ADDON, PG = ...

PG.Launcher = {}

local win, dndBtn

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
  win = PG.UI.Window("launcher", "Pengyou Games", 240, 322, "neutral")
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
  local ledgerBtn = PG.UI.Button(win, markLabel("sack", "Ledger"), 190, 26, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ledgerBtn:SetPoint("TOP", rpsBtn, "BOTTOM", 0, -10)
  local settingsBtn = PG.UI.Button(win, "Settings", 190, 26, function()
    if PG.Settings and PG.Settings.Show then PG.Settings.Show() end
  end)
  settingsBtn:SetPoint("TOP", ledgerBtn, "BOTTOM", 0, -10)
  dndBtn = PG.UI.Button(win, "", 190, 26, function()
    PG.ToggleDND()
    refreshDnd()
  end)
  dndBtn:SetPoint("TOP", settingsBtn, "BOTTOM", 0, -16)
  -- HookScript, not SetScript: the theme's Skin already hooked OnShow (pop-in)
  win:HookScript("OnShow", refreshDnd)
  refreshDnd()
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
end)
