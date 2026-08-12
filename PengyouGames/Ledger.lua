-- Ledger.lua - session nets, lifetime totals, settlement algorithm, ledger window.
local ADDON, PG = ...

PG.Ledger = {}

local function today() return date("%Y-%m-%d") end

-- Applies an integer-gold delta for fullName to tonight's session and to the
-- lifetime totals. reason is informational only (debug echo); it is not
-- persisted. Rejects secrets and wrong types (secrets would silently become
-- nil in SavedVariables).
function PG.Ledger.Add(fullName, deltaGold, reason)
  if PG.IsSecret(fullName) or PG.IsSecret(deltaGold) or PG.IsSecret(reason) then return end
  if type(fullName) ~= "string" or fullName == "" then return end
  if type(deltaGold) ~= "number" then return end
  -- reject NaN/inf: a non-finite delta would poison the persisted totals
  if deltaGold ~= deltaGold or deltaGold == math.huge or deltaGold == -math.huge then return end
  local delta = math.floor(deltaGold)
  local led = PG.db and PG.db.ledger
  if not led then return end
  local day = today()
  led.sessions[day] = led.sessions[day] or {}
  led.sessions[day][fullName] = (led.sessions[day][fullName] or 0) + delta
  led.lifetime[fullName] = (led.lifetime[fullName] or 0) + delta
  if PG.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffPG ledger|r " .. fullName .. " "
      .. (delta >= 0 and "+" or "") .. delta .. "g (" .. tostring(reason) .. ")")
  end
end

-- Tonight's nets: array of { name = "Name-Realm", net = integerGold }, sorted
-- net descending, ties by name (byte order). Includes zero-net entries.
function PG.Ledger.Tonight()
  local out = {}
  local session = PG.db and PG.db.ledger.sessions[today()]
  if session then
    for name, net in pairs(session) do
      out[#out + 1] = { name = name, net = net }
    end
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

-- Local effect only: wipes tonight's session table. Lifetime totals keep
-- their history.
function PG.Ledger.ClearTonight()
  if PG.db and PG.db.ledger then
    PG.db.ledger.sessions[today()] = nil
  end
end

-------------------------------------------------------------------------------
-- Ledger window: "Tonight" and "Settle Up" tabs + "Clear tonight" confirm.
-------------------------------------------------------------------------------

local win, tabTonightBtn, tabSettleBtn, confirm
local rows = {}
local activeTab = "tonight"
local MAX_ROWS = 15

-- Bright defaults (today's look). When the theme layer is present the init
-- block swaps them for the dark-on-parchment neutral palette (SKIN.md 1.1/2.9)
-- and sets INK, matching the parchment sheet the rows then render on.
-- Presentation only; every value is a plain escape-code string.
local GREEN, RED, GRAY, GOLD = "|cff40ff40", "|cffff5050", "|cffaaaaaa", "|cffffd200"
local INK -- floats; nil -> rows keep the plain white look

local function mark(key)
  if PG.Theme and PG.Theme.Mark then return PG.Theme.Mark(key) end
  return ""
end

local function tmoney(g)
  if PG.Theme and PG.Theme.Money then return PG.Theme.Money(g) end
  return PG.Money(g)
end

local Refresh

local function rowAt(i)
  if not rows[i] then
    local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 22, -94 - (i - 1) * 20)
    fs:SetWidth(356)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if INK then fs:SetTextColor(INK[1], INK[2], INK[3]) end -- ink on parchment
    rows[i] = fs
  end
  return rows[i]
end

local function tonightLines()
  local lines = {}
  for _, row in ipairs(PG.Ledger.Tonight()) do
    local color = (row.net > 0 and GREEN) or (row.net < 0 and RED) or GRAY
    local amt = (row.net > 0 and "+" or "") .. tmoney(row.net)
    lines[#lines + 1] = row.name .. "  " .. color .. amt .. "|r"
  end
  if not lines[1] then lines[1] = GRAY .. "No games recorded tonight.|r" end
  return lines
end

local function settleLines()
  local me = PG.FullName("player")
  local lines = {}
  for _, t in ipairs(PG.Ledger.Settlement()) do
    if t.from == me then
      lines[#lines + 1] = GOLD .. "YOU pay " .. t.to .. " " .. tmoney(t.amount) .. "|r"
    elseif t.to == me then
      lines[#lines + 1] = GOLD .. t.from .. " pays YOU " .. tmoney(t.amount) .. "|r"
    else
      lines[#lines + 1] = t.from .. " pays " .. t.to .. " " .. tmoney(t.amount)
    end
  end
  if not lines[1] then lines[1] = GRAY .. "All square - nothing to settle.|r" end
  -- treasure-sack section glyph heads the settle list: markup, zero frames
  local glyph = mark("sack")
  if glyph ~= "" then lines[1] = glyph .. " " .. lines[1] end
  return lines
end

Refresh = function()
  if not win then return end
  tabTonightBtn:SetEnabled(activeTab ~= "tonight")
  tabSettleBtn:SetEnabled(activeTab ~= "settle")
  local lines = activeTab == "tonight" and tonightLines() or settleLines()
  local shown = math.min(#lines, MAX_ROWS)
  if #lines > MAX_ROWS then
    lines[MAX_ROWS] = GRAY .. "... and " .. (#lines - MAX_ROWS + 1) .. " more|r"
  end
  for i = 1, shown do
    rowAt(i):SetText(lines[i])
    rowAt(i):Show()
  end
  for i = shown + 1, #rows do
    rows[i]:Hide()
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
  local text = confirm:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", 16, -16)
  text:SetPoint("TOPRIGHT", -16, -16)
  text:SetText("Clear tonight's ledger? This only affects what you see.")
  local yes = PG.UI.Button(confirm, "Clear", 100, 22, function()
    PG.Ledger.ClearTonight()
    confirm:Hide()
    Refresh()
  end)
  yes:SetPoint("BOTTOMLEFT", 20, 14)
  local no = PG.UI.Button(confirm, "Cancel", 100, 22, function() confirm:Hide() end)
  no:SetPoint("BOTTOMRIGHT", -20, 14)
  -- neutral skin + parchment inset behind the warning text (SKIN.md 2.9);
  -- the plain dark look above stays the fallback. No animation beyond Pop.
  if PG.Theme and PG.Theme.Skin then
    PG.Theme.Skin(confirm, "neutral")
    if PG.Theme.Tex then
      local inset = confirm:CreateTexture(nil, "ARTWORK", nil, -8)
      inset:SetPoint("TOPLEFT", 8, -8)
      inset:SetPoint("BOTTOMRIGHT", -8, 40)
      PG.Theme.Tex(inset, "parchment") -- fail -> solid PARCH (applied by Tex)
    end
    local c = PG.Theme.C("neutral")
    text:SetTextColor(c.INK[1], c.INK[2], c.INK[3])
    yes:SetText(c.loss .. "Clear|r") -- the destructive action reads as LOSS red
  end
  PG.Safety.RegisterWindow(confirm)
  confirm:Hide()
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("ledger", "Pengyou Ledger", 400, 440, "neutral")
  -- parchment sheet under the rows area (SKIN.md 2.9); the asset chain in
  -- Theme.Tex ends in solid PARCH, so the ink rows always sit on parchment
  if PG.Theme and PG.Theme.Tex then
    local sheet = win:CreateTexture(nil, "ARTWORK", nil, -8)
    sheet:SetPoint("TOPLEFT", 16, -76)
    -- bottom inset 48 (not 56): row 15's full glyph height stays on parchment
    sheet:SetPoint("BOTTOMRIGHT", -16, 48)
    PG.Theme.Tex(sheet, "sheet")
  end
  tabTonightBtn = PG.UI.Button(win, "Tonight", 110, 24, function()
    activeTab = "tonight"
    Refresh()
  end)
  tabTonightBtn:SetPoint("TOPLEFT", 20, -48)
  tabSettleBtn = PG.UI.Button(win, "Settle Up", 110, 24, function()
    activeTab = "settle"
    Refresh()
  end)
  tabSettleBtn:SetPoint("LEFT", tabTonightBtn, "RIGHT", 8, 0)
  -- page-turn garnish on manual tab switches (gated inside Theme.Sound)
  if PG.Theme and PG.Theme.Sound then
    tabTonightBtn:HookScript("OnClick", function() PG.Theme.Sound("page") end)
    tabSettleBtn:HookScript("OnClick", function() PG.Theme.Sound("page") end)
  end
  local clearBtn = PG.UI.Button(win, "Clear tonight", 120, 22, function()
    if not confirm then buildConfirm() end
    confirm:Show()
  end)
  clearBtn:SetPoint("BOTTOMLEFT", 20, 16)
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
  -- swap to the dark-on-parchment neutral palette (SKIN.md 1.1) when the
  -- theme layer is present; without it the bright defaults above remain
  if PG.Theme and PG.Theme.C then
    local c = PG.Theme.C("neutral")
    GREEN, RED, GRAY, GOLD = c.win, c.loss, c.fade, c.amber
    INK = c.INK
  end
end)
