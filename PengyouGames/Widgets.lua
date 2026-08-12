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
-- Scope picker (SCOPE.md 5) - the per-game audience control.
--
-- A SEGMENTED CONTROL, never a dropdown, and that is not re-litigable
-- (SCOPE.md 5.1): three options fit, two of them are usually disabled, and the
-- disabled state IS the message ("you cannot run a Pull Book for the guild,
-- here is why"). A dropdown hides the answer behind a click, and UIDropDownMenu
-- is deprecated taint we will not import for n = 3.
--
-- Fixed order, fixed ASCII labels, standard button art: muscle memory beats
-- compactness, and the plain UIPanelButtonTemplate face plus a 12pt font stays
-- legible across the whole 0.6 - 1.6 window scale range (the grip scales the
-- dialog, so nothing here re-lays out).
-------------------------------------------------------------------------------

local SCOPE_ORDER = { "group", "guild", "public" }
local SCOPE_LABEL = { group = "Party", guild = "Guild", public = "Public" }
local SCOPE_TIP = {   -- enabled tooltips, SCOPE.md 5.4, verbatim
  group  = { "Party / Raid - everyone in your group who runs the addon." },
  guild  = { "Guild - every guildmate online right now who runs the addon, on any realm in your guild." },
  public = { "Public - your realm and its connected realms, your faction only.",
             "Not cross-faction. Not other realms." },
}
local SEG_W, SEG_H, SEG_GAP, SEG_INSET = 82, 22, 4, 20
local SCOPE_GREY = "|cff808080"   -- SCOPE.md 5.2: forbidden never looks selected

local pickers = {}  -- every live picker, for the availability event hooks

-- Live availability, never cached (SCOPE.md 1.3). PG.Comm.ScopeAvailable is the
-- authority; the local fallback below keeps the control honest on a build where
-- Comm has not shipped it yet, using the same reason strings.
local function scopeAvailable(scope)
  if PG.Comm and PG.Comm.ScopeAvailable then
    local ok, avail, why = pcall(PG.Comm.ScopeAvailable, scope)
    if ok then return avail and true or false, PG.SafeStr(why) end
  end
  if scope == "group" then
    if IsInGroup() then return true end
    return false, "You're not in a party or raid."
  elseif scope == "guild" then
    if IsInGuild() then return true end
    return false, "You're not in a guild."
  end
  return false, "Turn on 'Join the public games channel' in Settings first."
end

local function savedScope(key)
  local p = PG.db and PG.db.profile
  local t = p and p.scope
  if type(t) ~= "table" then return nil end
  local v = t[key]
  if v == "group" or v == "guild" or v == "public" then return v end
  return nil   -- anything that is not one of the three enum strings is absent
end

local function saveScope(key, scope)
  local p = PG.db and PG.db.profile
  if not p then return end
  if type(p.scope) ~= "table" then p.scope = {} end
  p.scope[key] = scope
end

-- Segmented audience picker. Renders a label row and three fixed-order segments
-- (Party, Guild, Public); exactly one is selected whenever anything is
-- selectable at all.
--   cfg.key      "LG" | "RPS" | "PB"          persistence key
--   cfg.allowed  { group=, guild=, public= }  per-game support (SCOPE.md 1.2)
--   cfg.reasons  optional fn(scope) -> string, game-specific note. On a disabled
--                segment it REPLACES the availability reason; on an enabled one
--                it rides along as an advisory (LG's public gold warning).
--   cfg.onChange optional fn(scope), user clicks only
--   cfg.width    optional, defaults to the parent's width
-- Returns a frame (44px block, unanchored - the caller places it) with:
--   :Get()      -> scope, or nil when nothing is selectable
--   :Set(scope) -> selects if allowed and available; else no-op. Programmatic:
--                  it neither persists nor fires onChange.
--   :Refresh()  -> re-queries availability, repaints, re-selects if needed
function PG.UI.ScopePicker(parent, cfg)
  cfg = cfg or {}
  local key = tostring(cfg.key or "?")
  local allowed = cfg.allowed or {}
  local width = tonumber(cfg.width)
    or (parent and parent.GetWidth and parent:GetWidth()) or 320
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(width, 44)

  -- inherit the host window's skin the same way PG.UI.TimerBar does
  local theme, host = nil, parent
  for _ = 1, 4 do
    if not host then break end
    theme = host.__pgTheme
    if theme then break end
    host = host.GetParent and host:GetParent() or nil
  end
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C(theme) or nil
  -- selected tint + label color per skin; the button's own dark art is what the
  -- label sits on, so GOLD is legible here even in the goblin dialog (the
  -- parchment rule of SKIN.md 6.1 applies to the parchment, not to the button)
  local SEL_CODE = (C and (theme == "faire" and C.chgold or C.gold)) or "|cffffd200"
  local TINT = (C and (theme == "faire" and C.VIOLET or C.GOLD)) or { 1, 0.82, 0 }

  local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetPoint("TOPLEFT", f, "TOPLEFT", SEG_INSET, 0)
  label:SetText("Audience")
  if C and theme == "goblin" then
    label:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
  elseif C and theme == "faire" then
    label:SetTextColor(C.CHALK[1], C.CHALK[2], C.CHALK[3])
    if PG.Theme.Shadow then PG.Theme.Shadow(label) end
  end

  -- fallback hint (SCOPE.md 1.3), below the 44px block; empty most of the time
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", SEG_INSET, -44)
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -SEG_INSET, -44)
  hint:SetJustifyH("LEFT")
  hint:SetText("")
  if C then hint:SetTextColor(C.BRASS[1], C.BRASS[2], C.BRASS[3]) end

  local selected = nil
  local segs = {}
  local selectScope   -- forward: the click handler needs it

  local function policyNote(scope)
    if type(cfg.reasons) ~= "function" then return nil end
    local ok, s = pcall(cfg.reasons, scope)
    if not ok then return nil end
    return PG.SafeStr(s)
  end

  local function showTip(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:AddLine(SCOPE_LABEL[b.__pgScope])
    if b.__pgOff then
      -- the reason is the entire message; wrap it
      GameTooltip:AddLine(b.__pgReason or "Not available right now.", 1, 0.82, 0, true)
    else
      local lines = SCOPE_TIP[b.__pgScope]
      for i = 1, #lines do GameTooltip:AddLine(lines[i], 1, 1, 1, true) end
    end
    -- the game's own note rides along either way (LG's public gold warning is
    -- advisory, not a refusal, so it must not displace an actionable reason)
    if b.__pgNote then GameTooltip:AddLine(b.__pgNote, 1, 0.82, 0, true) end
    GameTooltip:Show()
  end

  local function paint()
    for i = 1, #SCOPE_ORDER do
      local scope = SCOPE_ORDER[i]
      local b = segs[scope]
      local note = policyNote(scope)
      local ok, reason, ride = false, nil, nil
      if not allowed[scope] then
        -- game policy (SCOPE.md 1.2) - cfg.reasons is the whole answer here,
        -- and it outranks anything ScopeAvailable would have said
        reason = note or "This game doesn't play to that audience."
      else
        local avail, why = scopeAvailable(scope)
        if avail then
          ok, ride = true, note
        else
          reason, ride = why or "Not available right now.", note
        end
      end
      b.__pgOff = not ok
      b.__pgReason = reason
      b.__pgNote = ride
      if not ok then
        -- NOT :Disable()d: a disabled Button is a dead hover target on some
        -- builds and the tooltip here IS the feature. The click is swallowed in
        -- the handler instead, and the grey label plus faded face say "no".
        b:SetEnabled(true)
        b:SetAlpha(0.6)
        b:SetText(SCOPE_GREY .. SCOPE_LABEL[scope] .. "|r")
        b.tint:Hide()
      elseif scope == selected then
        -- the ledger-tab idiom (Ledger.lua): the selected one is the disabled-
        -- looking one, plus the skin's tint so selected never reads as forbidden
        b:SetEnabled(false)
        b:SetAlpha(1)
        b:SetText(SEL_CODE .. SCOPE_LABEL[scope] .. "|r")
        b.tint:Show()
      else
        b:SetEnabled(true)
        b:SetAlpha(1)
        b:SetText(SCOPE_LABEL[scope])
        b.tint:Hide()
      end
    end
  end

  local prev
  for i = #SCOPE_ORDER, 1, -1 do    -- built right to left; right-aligned to -20
    local scope = SCOPE_ORDER[i]
    local b = PG.UI.Button(f, SCOPE_LABEL[scope], SEG_W, SEG_H, function(self)
      if self.__pgOff then
        showTip(self)   -- swallowed click: repeat the reason, do nothing else
        return
      end
      selectScope(self.__pgScope, true)
    end)
    if prev then
      b:SetPoint("TOPRIGHT", prev, "TOPLEFT", -SEG_GAP, 0)
    else
      b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -SEG_INSET, -20)
    end
    b.__pgScope = scope
    b.tint = b:CreateTexture(nil, "OVERLAY")
    b.tint:SetAllPoints()
    b.tint:SetColorTexture(TINT[1], TINT[2], TINT[3], 0.16)
    b.tint:SetBlendMode("ADD")
    b.tint:Hide()
    b:SetScript("OnEnter", showTip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    segs[scope] = b
    prev = b
  end

  selectScope = function(scope, byUser)
    if not scope or not allowed[scope] then return false end
    if not scopeAvailable(scope) then return false end
    selected = scope
    if byUser then
      saveScope(key, scope)   -- immediately: closing without starting remembers
      hint:SetText("")
    end
    paint()
    if byUser and type(cfg.onChange) == "function" then pcall(cfg.onChange, scope) end
    return true
  end

  function f:Get() return selected end

  function f:Set(scope) return selectScope(scope, false) end

  function f:Refresh()
    -- the persisted preference always gets first refusal, and a fallback never
    -- overwrites it (SCOPE.md 1.3)
    local pref = savedScope(key) or selected
    if pref and allowed[pref] and scopeAvailable(pref) then
      selected = pref
      hint:SetText("")
    else
      local first
      for i = 1, #SCOPE_ORDER do
        local s = SCOPE_ORDER[i]
        if allowed[s] and scopeAvailable(s) then first = s break end
      end
      selected = first
      if first and pref and allowed[pref] then
        hint:SetText(SCOPE_LABEL[pref] .. " isn't available right now - using "
          .. SCOPE_LABEL[first] .. ".")
      else
        hint:SetText("")   -- nothing available at all: Start explains that
      end
    end
    paint()
    return selected
  end

  -- availability is re-checked on every dialog OnShow (SCOPE.md 1.3): hooked
  -- here so no dialog can forget, on top of the roster/guild events below
  if parent and parent.HookScript then
    parent:HookScript("OnShow", function() f:Refresh() end)
  end
  pickers[#pickers + 1] = f
  f:Refresh()
  return f
end

-- Availability is a live query, so anything that changes it must repaint the
-- open pickers: the group and guild events below, and the Settings public
-- opt-in (a checkbox tick has to un-grey the Public segment of a dialog that is
-- already open, or the fix looks like it did nothing).
function PG.UI.RefreshScopePickers()
  for i = 1, #pickers do
    if pickers[i]:IsVisible() then pcall(pickers[i].Refresh, pickers[i]) end
  end
end

-------------------------------------------------------------------------------
-- Ask popup
-------------------------------------------------------------------------------

-- Several invitations may be on screen at once (CONCURRENCY.md 5.6): until you
-- accept one you see them all and choose. Keys are per SESSION, not per game
-- ("LG:Grizzle-Illidan|1a-7f3"), so a second Loot Goblins invitation can never
-- silently auto-decline the first - that replacement path now only fires for a
-- genuine re-invitation to the SAME session.
--
-- Keys are unbounded over a session's life, so frames are pooled per theme
-- rather than kept per key. At most ASK_MAX are active at once, so each pool
-- tops out at ASK_MAX frames and CreateFrame calls stay bounded.
local ASK_MAX = 3
PG.UI.ASK_MAX = ASK_MAX   -- games route invitation number ASK_MAX+1 to the launcher

local askPool = {}   -- theme name -> array of frames (active or idle)
local askActive = {} -- key -> frame
local askOrder = {}  -- keys in activation order; drives the stack layout

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

-- Popups stack at 140 - n * 150 in UIParent centre coordinates. The offset used
-- to be computed once at activation, so closing the top popup left a hole; it is
-- now re-run from the activation order every time the set changes.
local function relayoutAsks()
  for i = 1, #askOrder do
    local f = askActive[askOrder[i]]
    if f then
      f:ClearAllPoints()
      f:SetPoint("CENTER", UIParent, "CENTER", 0, 140 - (i - 1) * 150)
    end
  end
end

local function finishAsk(f, accepted)
  if not f.active then return end
  f.active = false
  if f.ticker then
    f.ticker:Cancel()
    f.ticker = nil
  end
  f:Hide()
  local key = f.__pgAskKey
  f.__pgAskKey = nil
  if key and askActive[key] == f then
    askActive[key] = nil
    for i = 1, #askOrder do
      if askOrder[i] == key then
        table.remove(askOrder, i)
        break
      end
    end
  end
  local cb = accepted and f.onAccept or f.onDecline
  f.onAccept, f.onDecline = nil, nil
  -- close the gap before the callback runs: accepting one invitation withdraws
  -- the rest, and those Dismiss calls must see a settled layout
  relayoutAsks()
  if cb then cb() end
end

local function buildAsk(theme)
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f.__pgAskTheme = theme or "plain" -- the theme is baked in at build time
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

-- An idle frame of this theme, or a new one. Called only when the cap allows
-- another popup, so a pool holds at most ASK_MAX frames.
local function acquireAsk(theme)
  local name = theme or "plain"
  local pool = askPool[name]
  if not pool then
    pool = {}
    askPool[name] = pool
  end
  for i = 1, #pool do
    if not pool[i].active then return pool[i] end
  end
  local f = buildAsk(theme)
  pool[#pool + 1] = f
  return f
end

-- Small centered popup; the timeout counts down on a fontstring and acts as
-- decline. Auto-declines immediately (no popup) while DND is on.
--
-- key is per SESSION (game .. ":" .. host .. "|" .. token). Several keys are on
-- screen at once, stacked and re-laid-out as they come and go; a repeat Ask for
-- the SAME key still declines and replaces its predecessor.
--
-- Returns:
--   true            the popup is up (or armed behind a safety flag)
--   false, "dnd"    DND: onDecline ran, exactly as before
--   false, "full"   ASK_MAX invitations are already on screen. NEITHER callback
--                   runs - the caller routes this invitation to the launcher's
--                   Open games list plus one throttled toast (CONCURRENCY.md
--                   5.6 rule 1). An Ask you cannot see must not silently
--                   decline itself.
-- theme (optional, trailing - existing callers unaffected): "goblin" etc.
function PG.UI.Ask(key, text, acceptLabel, declineLabel, timeoutSec, onAccept, onDecline, theme)
  if PG.IsDND() then
    if onDecline then onDecline() end
    return false, "dnd"
  end
  key = tostring(key or "")
  local prev = askActive[key]
  -- a replacement occupies a slot it already holds, so it is never capped out
  if not prev and #askOrder >= ASK_MAX then return false, "full" end
  -- ordering matters and must stay: finishAsk grabs the OLD callbacks before
  -- the new ones are bound below
  if prev then finishAsk(prev, false) end
  local f = acquireAsk(theme)
  f.active = true
  f.__pgGreeted = nil
  f.__pgAskKey = key
  askActive[key] = f
  askOrder[#askOrder + 1] = key
  f.onAccept, f.onDecline = onAccept, onDecline
  f.text:SetText(tostring(text or ""))
  f.acceptBtn:SetText(acceptLabel or "Accept")
  f.declineBtn:SetText(declineLabel or "Decline")
  relayoutAsks()
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
  return true
end

-- Take one invitation down. A dead session takes its invitation with it: every
-- eviction path, applyCancel, applyEnd and endSession call this, so a cancelled
-- game can never leave a live countdown popup inviting you into nothing
-- (CONCURRENCY.md 5.6 rule 4). Declines, exactly like the timeout does, so a
-- caller that put teardown in onDecline still gets it. No-op for an unknown or
-- nil key; returns true if a popup actually came down.
function PG.UI.Dismiss(key)
  if key == nil then return false end
  local f = askActive[tostring(key)]
  if not f then return false end
  finishAsk(f, false)
  return true
end

-- Active invitations on screen, all modules. The launcher/overflow path asks
-- this before deciding whether an invitation can pop.
function PG.UI.AskCount() return #askOrder end

-- Is this key's popup actually on screen right now? The authoritative liveness
-- test behind a record's cached askKey, so a stale field can never make a
-- module believe a popup exists that finishAsk already took down.
function PG.UI.IsAsking(key)
  if key == nil then return false end
  return askActive[tostring(key)] ~= nil
end

-------------------------------------------------------------------------------
-- The guild invite budget (SCOPE.md 6.3): at most one popup per sender per 60
-- seconds and three per five minutes.
--
-- It lives HERE, next to AskCount, because it is a budget on the user's SCREEN,
-- not on a module. Kept per module it was spent twice - Loot Goblins and Rock
-- Paper Scissors each allowed three, so the real ceiling was six popups per
-- five minutes against a spec that says three.
-------------------------------------------------------------------------------

local GUILD_ASK_PER_SENDER = 60
local GUILD_ASK_WINDOW = 300
local GUILD_ASK_BUDGET = 3

local guildAskAt = {}    -- [host] = GetTime() of its last guild popup
local guildAskTimes = {} -- popup timestamps inside GUILD_ASK_WINDOW

-- Pure query: spends nothing, so a caller may test and then decline to pop.
function PG.UI.GuildAskOK(host)
  local now = GetTime()
  local i = 1
  while i <= #guildAskTimes do
    if (now - guildAskTimes[i]) > GUILD_ASK_WINDOW then
      table.remove(guildAskTimes, i)
    else
      i = i + 1
    end
  end
  local last = guildAskAt[tostring(host or "")]
  if last and (now - last) < GUILD_ASK_PER_SENDER then return false end
  return #guildAskTimes < GUILD_ASK_BUDGET
end

-- Called only once a popup is actually on screen, so a budget is never burned
-- by an invitation the user never saw.
function PG.UI.GuildAskSpend(host)
  local now = GetTime()
  for k, t in pairs(guildAskAt) do -- bounded: pruned with the window
    if (now - t) > GUILD_ASK_WINDOW then guildAskAt[k] = nil end
  end
  guildAskAt[tostring(host or "")] = now
  guildAskTimes[#guildAskTimes + 1] = now
end

-- every pooled frame, active or idle (idle ones are hidden and cheap to skip)
local function forEachAskFrame(fn)
  for _, pool in pairs(askPool) do
    for i = 1, #pool do fn(pool[i]) end
  end
end

PG.RegisterInit(function()
  -- re-show deferred / safety-hidden Asks the moment the last flag clears
  PG.Safety.OnChange(function(_, trigger)
    if trigger:match("_OFF$") then
      forEachAskFrame(showAskIfSafe)
    end
  end)
  -- availability is a live query: repaint any open picker when the group or the
  -- guild changes underneath it (SCOPE.md 5.2)
  PG.RegisterEvent("GROUP_ROSTER_UPDATE", PG.UI.RefreshScopePickers)
  PG.RegisterEvent("PLAYER_GUILD_UPDATE", PG.UI.RefreshScopePickers)
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
  local free = true
  forEachAskFrame(function(f)
    if free and rectHits(f, l, b, w, h) then free = false end
  end)
  return free
end

-------------------------------------------------------------------------------
-- Toast - one screen slot, one shared FIFO (CONCURRENCY.md 5.7).
--
-- The slot used to be a plain overwrite: LG and RPS erased each other, and a
-- Pull Book settlement line ("Kill bet: 3 winners split 900g - you +300g") could
-- be wiped by an unrelated "back in sync" line inside its own display time. The
-- Pull Book's answer was a private FIFO draining into the same single-slot sink,
-- which does not help. The queue lives here now, once, for everyone.
--
--   * FIFO, one on screen at a time, 3s life as before.
--   * Minimum on-screen time 1.2s: a newcomer never replaces a toast younger
--     than that, it queues behind it.
--   * Queue cap 4. A full queue drops the oldest "normal" entry and never a
--     "result" entry - money and medals beat status chatter.
--   * key deduplicates: a QUEUED entry with the same key is replaced in place
--     rather than appended, so a game's status line cannot fill the queue.
--   * A "normal" entry waiting longer than 8s is dropped: a stale status line is
--     worse than none. "result" entries never expire - they are the reason the
--     queue exists, and the Pull Book's settlements have to survive the boss
--     fight that suppressed the screen in the first place.
-------------------------------------------------------------------------------

local toast
local toastQ = {}       -- pending entries, oldest first
local toastTicker
local TOAST_LIFE  = 3
local TOAST_FLOOR = 1.2
local TOAST_QMAX  = 4
local TOAST_WAIT  = 8

-- The screen is ours when nothing raid-critical owns it. Same gate as before
-- plus `restricted` (which the Pull Book's private queue already honoured);
-- ready check and countdown deliberately do NOT block a one-line toast.
local function toastSurfaceOK()
  if InCombatLockdown() then return false end
  local s = PG.Safety and PG.Safety.state
  if s and (s.inCombat or s.inEncounter or s.restricted) then return false end
  return true
end

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

local function showToastNow(e)
  if not toast then buildToast() end
  toast.text:SetText(e.text)
  local now = GetTime()
  toast.shownAt = now
  toast.dieAt = now + TOAST_LIFE
  toast:SetAlpha(1)
  toast:Show()
  -- the sound belongs to the moment the line is actually read, not to the
  -- moment it was queued; Theme.Sound applies its own gates on top
  if e.sound and PG.Theme and PG.Theme.Sound then PG.Theme.Sound(e.sound) end
  if e.onShown then pcall(e.onShown) end
end

local function stopToastPump()
  if toastTicker then
    toastTicker:Cancel()
    toastTicker = nil
  end
end

local function pumpToasts()
  local now = GetTime()
  local i = 1
  while i <= #toastQ do
    local e = toastQ[i]
    if e.expires and now > e.expires then table.remove(toastQ, i) else i = i + 1 end
  end
  if not toastQ[1] then
    stopToastPump()
    return
  end
  if not toastSurfaceOK() then return end          -- hold, do not burn the line
  if PG.IsDND() then                               -- DND toggled on while queued
    wipe(toastQ)
    stopToastPump()
    return
  end
  if toast and toast:IsShown() and (now - (toast.shownAt or 0)) < TOAST_FLOOR then
    return                                          -- the floor is inviolable
  end
  showToastNow(table.remove(toastQ, 1))
  if not toastQ[1] then stopToastPump() end
end

local function startToastPump()
  if not toastTicker then
    -- one ticker for the whole addon, alive only while the queue is
    toastTicker = PG.Ticker(0.2, pumpToasts)
  end
  pumpToasts()
end

-- 3-second fading status line near the top of the screen; suppressed in DND.
-- opts (optional table, older single-argument callers are unaffected):
--   key       "lg-status", "pb-K", ... - a queued entry with the same key is
--             replaced in place instead of appended
--   sound     PG.Theme.Sound key, played when this line actually appears
--   priority  "normal" (default) | "result" - result lines are never dropped
--             for space and never time out in the queue
--   onShown   optional fn() when the line reaches the screen; the Pull Book
--             uses it to release its reveal payload in the right order
-- Attribution ("Loot Goblins (Grizzle): ...") is the caller's job: only the
-- game knows whether it currently holds more than one record.
function PG.UI.Toast(text, opts)
  if PG.IsDND() then return false end
  opts = (type(opts) == "table") and opts or nil
  local e = {
    text = tostring(text or ""),
    key = opts and opts.key or nil,
    sound = opts and opts.sound or nil,
    onShown = (opts and type(opts.onShown) == "function") and opts.onShown or nil,
    result = (opts and opts.priority == "result") and true or false,
  }
  if not e.result then e.expires = GetTime() + TOAST_WAIT end
  if e.key then
    for i = 1, #toastQ do
      if toastQ[i].key == e.key then
        -- keeps its place AND its original wait, so a status line that updates
        -- every second cannot sit in the queue forever. A result entry has no
        -- expiry to inherit and never gains one.
        if e.expires then e.expires = toastQ[i].expires or e.expires end
        toastQ[i] = e
        startToastPump()
        return true
      end
    end
  end
  if #toastQ >= TOAST_QMAX then
    local victim
    for i = 1, #toastQ do
      if not toastQ[i].result then victim = i break end
    end
    if victim then
      table.remove(toastQ, victim)                 -- oldest normal entry goes
    elseif not e.result then
      return false                                 -- all results: refuse chatter
    else
      table.remove(toastQ, 1)                      -- results only, and one more
    end                                            -- result arriving: bounded
  end                                              -- memory wins, oldest goes
  toastQ[#toastQ + 1] = e
  startToastPump()
  return true
end

-- What the Pull Book needs to delete its private FIFO and keep only its
-- reveal-payload queueing: how many lines are still waiting, and whether one is
-- on screen right now. A stage payload must not overtake the text that explains
-- it, so PB holds a reveal while this reports anything pending.
function PG.UI.ToastPending()
  local onScreen = (toast and toast:IsShown()) and true or false
  return #toastQ, onScreen
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
