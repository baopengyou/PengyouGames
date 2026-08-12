-- Widgets.lua - window factory, ask-popup, toast, timer bar, button.
local ADDON, PG = ...

PG.UI = {}

local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function applyBackdrop(f)
  f:SetBackdrop(BACKDROP)
  f:SetBackdropColor(0, 0, 0, 0.88)
  f:SetBackdropBorderColor(0.8, 0.8, 0.8, 1)
end

-------------------------------------------------------------------------------
-- Window registry: resize (proportional scale grip) + never-overlap solver
-------------------------------------------------------------------------------

local managed = {}            -- every factory window, for the overlap solver
local GAP = 8                 -- minimum clearance between windows
local SCALE_MIN, SCALE_MAX = 0.6, 1.6

-- Rect in UIParent coordinate space (all factory windows are UIParent
-- children, so local coords times own scale compare directly).
local function rectOf(f)
  local s = f:GetScale()
  local l, b, w, h = f:GetRect()
  if not l then return nil end
  return l * s, b * s, w * s, h * s
end

local function savePos(f)
  if not (PG.db and f.__pgKey) then return end
  local point, _, relPoint, x, y = f:GetPoint(1)
  if type(point) == "string" then
    PG.db.profile.positions[f.__pgKey] =
      { point = point, relPoint = relPoint, x = x, y = y, scale = f:GetScale() }
  end
end

-- Push `moved` to the nearest spot where it overlaps no other visible managed
-- window; the window being placed/dragged/resized always yields. Bounded
-- best-effort: a screen genuinely too small for every open window gives up
-- after 12 passes rather than looping.
function PG.UI.ResolveOverlaps(moved)
  if not (moved and moved:IsShown()) then return end
  local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
  local movedAny = false
  for _ = 1, 12 do
    local ml, mb, mw, mh = rectOf(moved)
    if not ml then return end
    local pushed = false
    for i = 1, #managed do
      local other = managed[i]
      if other ~= moved and other:IsShown() then
        local ol, ob, ow, oh = rectOf(other)
        if ol then
          local ox = math.min(ml + mw, ol + ow) - math.max(ml, ol)
          local oy = math.min(mb + mh, ob + oh) - math.max(mb, ob)
          if ox > 0 and oy > 0 then
            local dx, dy = 0, 0
            if ox <= oy then -- push along the axis of least penetration
              dx = (ml + mw / 2 < ol + ow / 2) and -(ox + GAP) or (ox + GAP)
            else
              dy = (mb + mh / 2 < ob + oh / 2) and -(oy + GAP) or (oy + GAP)
            end
            ml = math.max(0, math.min(ml + dx, sw - mw))
            mb = math.max(0, math.min(mb + dy, sh - mh))
            local sc = moved:GetScale()
            moved:ClearAllPoints()
            moved:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", ml / sc, mb / sc)
            pushed, movedAny = true, true
          end
        end
      end
    end
    if not pushed then break end
  end
  if movedAny then savePos(moved) end
end

-- Settings hooks: apply one scale to every window (clearing per-window grip
-- overrides - the slider is also the "make them all match again" tool), and
-- reset the whole layout to centered defaults.
function PG.UI.ApplyGlobalScale(scale)
  scale = math.max(SCALE_MIN, math.min(SCALE_MAX, tonumber(scale) or 1))
  if PG.db then
    PG.db.profile.scale = scale
    for _, pos in pairs(PG.db.profile.positions) do
      if type(pos) == "table" then pos.scale = nil end
    end
  end
  for i = 1, #managed do managed[i]:SetScale(scale) end
  for i = 1, #managed do
    if managed[i]:IsShown() then PG.UI.ResolveOverlaps(managed[i]) end
  end
  return scale
end

function PG.UI.ResetLayout()
  if PG.db then wipe(PG.db.profile.positions) end
  local scale = (PG.db and PG.db.profile.scale) or 1
  for i = 1, #managed do
    local f = managed[i]
    f:SetScale(scale)
    f:ClearAllPoints()
    f:SetPoint("CENTER")
  end
  for i = 1, #managed do
    if managed[i]:IsShown() then PG.UI.ResolveOverlaps(managed[i]) end
  end
end

-- Corner grip that resizes by SCALING the whole window (content reflows for
-- free; per-axis reflow of the game layouts is deliberately out of scope).
-- The TOPLEFT corner stays pinned while scaling so the grip tracks the cursor.
local function addResizeGrip(f)
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -3, 3)
  grip:SetFrameLevel(f:GetFrameLevel() + 10)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function(self)
    local fs = f:GetScale()
    local left, top = f:GetLeft(), f:GetTop()
    if not (left and top) then return end
    local ues = UIParent:GetEffectiveScale()
    local leftUIP, topUIP = left * fs, top * fs -- UIParent space, pinned
    local cx, cy = GetCursorPosition()
    local startDist = math.max(40,
      math.sqrt((cx - leftUIP * ues) ^ 2 + (cy - topUIP * ues) ^ 2))
    -- OnUpdate exists only while the grip is held; removed on release
    self:SetScript("OnUpdate", function()
      local nx, ny = GetCursorPosition()
      local dist = math.sqrt((nx - leftUIP * ues) ^ 2 + (ny - topUIP * ues) ^ 2)
      local newScale = math.max(SCALE_MIN, math.min(SCALE_MAX, fs * dist / startDist))
      f:SetScale(newScale)
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", leftUIP / newScale, topUIP / newScale)
    end)
  end)
  grip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    savePos(f)
    PG.UI.ResolveOverlaps(f)
  end)
end

-- Movable, screen-clamped, safety-registered window; position, per-window
-- scale (corner grip) persisted in db.profile.positions[key]; never overlaps
-- another factory window (the solver nudges the shown/moved one clear).
-- Returns the frame (created hidden); the title fontstring is frame.title.
-- ESC deliberately does NOT close it (we stay out of UISpecialFrames and all
-- other Blizzard tables).
-- theme (optional): "goblin" | "faire" | "neutral" (default "neutral"),
-- applied via PG.Theme.Skin; the plain backdrop below stays the ultimate
-- fallback when the theme layer is unavailable.
function PG.UI.Window(key, title, w, h, theme)
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f.__pgKey = key
  f:SetSize(w, h)
  f:SetFrameStrata("MEDIUM")
  applyBackdrop(f)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePos(self)
    PG.UI.ResolveOverlaps(self)
  end)
  -- default scale first; a saved per-window scale (resize grip) overrides
  f:SetScale((PG.db and PG.db.profile.scale) or 1)
  local pos = PG.db and PG.db.profile.positions[key]
  local placed = false
  if type(pos) == "table" then
    if type(pos.scale) == "number" and pos.scale >= SCALE_MIN and pos.scale <= SCALE_MAX then
      pcall(f.SetScale, f, pos.scale)
    end
    if type(pos.point) == "string" then
      -- pcall: a corrupted saved point string would error inside SetPoint
      placed = pcall(f.SetPoint, f, pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    end
  end
  if not placed then f:SetPoint("CENTER") end
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", 0, -14)
  f.title:SetText(title)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  if PG.Theme and PG.Theme.Skin then
    PG.Theme.Skin(f, theme or "neutral")
  end
  addResizeGrip(f)
  managed[#managed + 1] = f
  -- solver on show: a window opening onto an occupied spot moves itself clear
  f:HookScript("OnShow", function(self) PG.UI.ResolveOverlaps(self) end)
  PG.Safety.RegisterWindow(f)
  f:Hide()
  return f
end

function PG.UI.Button(parent, label, w, h, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  b:SetText(label)
  if onClick then
    b:SetScript("OnClick", function(self) onClick(self) end)
  end
  return b
end

-- Themed parchment-card button for PRIMARY game actions only (LG SHARE/HOARD,
-- PB market picks; doctrine SKIN.md 1.3). Same signature as PG.UI.Button.
-- Falls back to the plain UIPanelButtonTemplate button when the card face is
-- unavailable, so callers can treat the result identically either way
-- (b.__pgCard is true only on the themed variant; its label is b.text).
function PG.UI.CardButton(parent, label, w, h, onClick)
  local b
  if PG.Theme and PG.Theme.CardFace then
    b = PG.Theme.CardFace(parent, label, w, h)
  end
  if not b then
    return PG.UI.Button(parent, label, w, h, onClick)
  end
  if onClick then
    b:SetScript("OnClick", function(self) onClick(self) end)
  end
  return b
end

-------------------------------------------------------------------------------
-- Ask popup
-------------------------------------------------------------------------------

local askFrames = {} -- key -> frame; one Ask per key (a new one replaces the old)

-- Per-theme Ask flavor (icon + sounds). Goblin keeps the SKIN.md 2.3 coin
-- treatment; faire swaps in the dice mark and carnival-appropriate sounds
-- (every key exists in Theme's ASSETS/SOUNDS tables with reachable fallbacks).
local ASK_STYLE = {
  goblin = { icon = "coinpile", greet = "greet", accept = "coinlock", decline = "coincancel" },
  faire  = { icon = "dice", greet = "ticket", accept = "click", decline = "coincancel" },
}

local function safetyAllClear()
  local s = PG.Safety and PG.Safety.state
  if not s then return true end
  if s.inEncounter or s.readyCheck or s.countdown or s.restricted then return false end
  -- plain combat blocks popups only when the user opted into combat-hiding
  if s.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return false end
  return true
end

-- An Ask arriving mid-combat/encounter/ready-check/countdown stays hidden but
-- armed: the timeout keeps counting (and still declines on expiry), and the
-- popup shows once every safety flag is clear (the OnChange hook below plus
-- the timed ticker both funnel through here).
local function showAskIfSafe(f)
  if f.active and not f:IsShown() and safetyAllClear() then f:Show() end
end

local function finishAsk(f, accepted)
  if not f.active then return end
  f.active = false
  if f.ticker then
    f.ticker:Cancel()
    f.ticker = nil
  end
  f:Hide()
  local cb = accepted and f.onAccept or f.onDecline
  f.onAccept, f.onDecline = nil, nil
  if cb then cb() end
end

local function buildAsk(theme)
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f:SetSize(340, 130)
  f:SetFrameStrata("DIALOG")
  applyBackdrop(f)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.text:SetPoint("TOPLEFT", 18, -18)
  f.text:SetPoint("TOPRIGHT", -18, -18)
  f.text:SetJustifyH("CENTER")
  f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.timerText:SetPoint("BOTTOM", 0, 44)
  f.acceptBtn = PG.UI.Button(f, "Accept", 130, 24, function() finishAsk(f, true) end)
  f.acceptBtn:SetPoint("BOTTOMLEFT", 20, 14)
  f.declineBtn = PG.UI.Button(f, "Decline", 130, 24, function() finishAsk(f, false) end)
  f.declineBtn:SetPoint("BOTTOMRIGHT", -20, 14)
  -- Themed variant (SKIN.md 2.3): per-theme treatment + icon + pop-on-show +
  -- sounds. Goblin keeps parchment/ink/coins; faire uses chalk-on-board text
  -- (rule 6.1: never INK on the chalkboard) with the dice mark. Buttons stay
  -- UIPanelButtonTemplate (raid-facing reliability); the plain look above is
  -- the fallback at every layer.
  if theme and PG.Theme and PG.Theme.Skin then
    local style = ASK_STYLE[theme] or ASK_STYLE.goblin
    f:SetSize(360, 140)
    PG.Theme.Skin(f, theme) -- backdrop/parchment, pop-on-show, OnHide contract
    local C = PG.Theme.C(theme)
    f.icon = PG.Theme.Icon(f, style.icon, 36)
    f.icon:SetPoint("LEFT", 16, 8)
    f.text:ClearAllPoints()
    f.text:SetPoint("TOPLEFT", 62, -18)
    f.text:SetPoint("TOPRIGHT", -18, -18)
    f.text:SetJustifyH("LEFT")
    if theme == "faire" then
      -- chalkboard: CHALK body (~14:1 on BOARD) + shadow, CHRED countdown
      f.text:SetTextColor(C.CHALK[1], C.CHALK[2], C.CHALK[3])
      if PG.Theme.Shadow then PG.Theme.Shadow(f.text) end
      f.timerText:SetTextColor(C.CHRED[1], C.CHRED[2], C.CHRED[3])
      if PG.Theme.Shadow then PG.Theme.Shadow(f.timerText) end
    else
      f.text:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
      -- the countdown is the urgency cue; the number itself never animates
      f.timerText:SetTextColor(C.LOSS[1], C.LOSS[2], C.LOSS[3])
    end
    f:HookScript("OnShow", function(self)
      if self.active and not self.__pgGreeted then
        self.__pgGreeted = true -- once per activation, even across deferred shows
        PG.Theme.Sound(style.greet)
      end
    end)
    f.acceptBtn:HookScript("OnClick", function() PG.Theme.Sound(style.accept) end)
    f.declineBtn:HookScript("OnClick", function() PG.Theme.Sound(style.decline) end)
  end
  -- safety hides the popup but the timeout keeps running (ticker, not
  -- OnUpdate) and still declines on expiry
  PG.Safety.RegisterWindow(f)
  -- veto Core's auto-resume: the Ask has its own deferred-show machinery
  -- (showAskIfSafe), and resuming an inactive frame would show an empty popup
  f.__pgResume = function() return false end
  f:Hide()
  return f
end

-- Small centered popup; the timeout counts down on a fontstring and acts as
-- decline. Auto-declines immediately (no popup) while DND is on. Only one Ask
-- per key at a time: a new Ask declines and replaces the old one.
-- theme (optional, trailing - existing callers unaffected): "goblin" etc.;
-- the theme is baked into the key's frame on first build.
function PG.UI.Ask(key, text, acceptLabel, declineLabel, timeoutSec, onAccept, onDecline, theme)
  if PG.IsDND() then
    if onDecline then onDecline() end
    return
  end
  local f = askFrames[key]
  if not f then
    f = buildAsk(theme)
    askFrames[key] = f
  end
  if f.active then finishAsk(f, false) end
  f.active = true
  f.__pgGreeted = nil
  f.onAccept, f.onDecline = onAccept, onDecline
  f.text:SetText(tostring(text or ""))
  f.acceptBtn:SetText(acceptLabel or "Accept")
  f.declineBtn:SetText(declineLabel or "Decline")
  local stacked = 0
  for _, other in pairs(askFrames) do
    if other ~= f and other.active then stacked = stacked + 1 end
  end
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 140 - stacked * 150)
  if timeoutSec and timeoutSec > 0 then
    local deadline = GetTime() + timeoutSec
    f.timerText:SetText(math.ceil(timeoutSec) .. "s")
    f.ticker = PG.Ticker(0.25, function()
      if not f.active then
        if f.ticker then
          f.ticker:Cancel()
          f.ticker = nil
        end
        return
      end
      local remaining = deadline - GetTime()
      if remaining <= 0 then
        finishAsk(f, false) -- timeout == decline (even while safety-hidden)
      else
        f.timerText:SetText(math.ceil(remaining) .. "s")
        showAskIfSafe(f) -- deferred show for popups that arrived mid-combat
      end
    end)
  else
    f.timerText:SetText("")
  end
  showAskIfSafe(f)
end

PG.RegisterInit(function()
  -- re-show deferred / safety-hidden Asks the moment the last flag clears
  PG.Safety.OnChange(function(_, trigger)
    if trigger:match("_OFF$") then
      for _, f in pairs(askFrames) do showAskIfSafe(f) end
    end
  end)
end)

-------------------------------------------------------------------------------
-- Overlap query for screen-anchored overlays
-------------------------------------------------------------------------------

-- Read-only support for surfaces that are deliberately NOT in `managed` and not
-- in the solver (the reveal stage, REVEAL.md 3): does this rect, in UIParent
-- space, clear every shown factory window AND every shown Ask popup? Both are
-- click targets a mouse-swallowing overlay must not cover. Pure query - it
-- moves nothing, registers nothing, and lives here (not next to the solver)
-- only because it needs the Ask registry above.
local function rectHits(f, l, b, w, h)
  if not f:IsShown() then return false end
  local ol, ob, ow, oh = rectOf(f)
  return ol ~= nil
    and math.min(l + w, ol + ow) > math.max(l, ol)
    and math.min(b + h, ob + oh) > math.max(b, ob)
end

function PG.UI.RectFree(l, b, w, h)
  if type(l) ~= "number" or type(b) ~= "number"
    or type(w) ~= "number" or type(h) ~= "number" then return false end
  for i = 1, #managed do
    if rectHits(managed[i], l, b, w, h) then return false end
  end
  for _, f in pairs(askFrames) do
    if rectHits(f, l, b, w, h) then return false end
  end
  return true
end

-------------------------------------------------------------------------------
-- Toast
-------------------------------------------------------------------------------

local toast

local function buildToast()
  toast = CreateFrame("Frame", nil, UIParent)
  toast:SetSize(700, 26)
  toast:SetPoint("TOP", 0, -170)
  toast:SetFrameStrata("HIGH")
  toast.text = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  toast.text:SetPoint("CENTER")
  if PG.Theme and PG.Theme.Shadow then
    PG.Theme.Shadow(toast.text) -- toast text always floats over the world
  end
  toast:SetScript("OnUpdate", function(self)
    local remaining = (self.dieAt or 0) - GetTime()
    if remaining <= 0 then
      self:Hide()
    elseif remaining < 0.8 then
      self:SetAlpha(remaining / 0.8)
    else
      self:SetAlpha(1)
    end
  end)
  PG.Safety.RegisterWindow(toast)
  -- resume only if the toast still has meaningful life left
  toast.__pgResume = function() return ((toast.dieAt or 0) - GetTime()) > 0.5 end
  toast:Hide()
end

-- 3-second fading status line near the top of the screen; suppressed in DND,
-- never shown in combat or during an encounter.
function PG.UI.Toast(text)
  if PG.IsDND() then return end
  if InCombatLockdown() then return end
  local s = PG.Safety and PG.Safety.state
  if s and (s.inCombat or s.inEncounter) then return end
  if not toast then buildToast() end
  toast.text:SetText(tostring(text or ""))
  toast.dieAt = GetTime() + 3
  toast:SetAlpha(1)
  toast:Show()
end

-------------------------------------------------------------------------------
-- Timer bar
-------------------------------------------------------------------------------

-- Returns a StatusBar with :Start(sec) / :Stop(). Purely visual: it fires no
-- callbacks at zero; drive game logic from your own timers.
function PG.UI.TimerBar(parent, w)
  local bar = CreateFrame("StatusBar", nil, parent)
  bar:SetSize(w, 14)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.25, 0.7, 1)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER")
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  local function onUpdate(self)
    local remaining = (self.endTime or 0) - GetTime()
    if remaining <= 0 then
      self:Stop()
    else
      self:SetValue(remaining / self.total)
      self.text:SetText(tostring(math.ceil(remaining)))
    end
  end
  function bar:Start(sec)
    self.total = (sec and sec > 0) and sec or 1
    self.endTime = GetTime() + self.total
    self:SetValue(1)
    self:SetScript("OnUpdate", onUpdate)
  end
  function bar:Stop()
    self:SetScript("OnUpdate", nil)
    self:SetValue(0)
    self.text:SetText("")
  end
  -- Goblin bar skin when living inside a goblin-skinned window (SKIN.md
  -- 2.4.1); every other theme keeps the plain look above. The bar and its
  -- text never animate regardless of skin.
  if PG.Theme and PG.Theme.TimerBar then
    local host, theme = parent, nil
    for _ = 1, 4 do
      if not host then break end
      theme = host.__pgTheme
      if theme then break end
      host = host.GetParent and host:GetParent() or nil
    end
    if theme == "goblin" then PG.Theme.TimerBar(bar) end
  end
  return bar
end
