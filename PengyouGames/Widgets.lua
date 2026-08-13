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
-- Returns the frame (created hidden); the title fontstring is frame.title and
-- its container is frame.titleBar.
-- ESC deliberately does NOT close it (we stay out of UISpecialFrames and all
-- other Blizzard tables).
-- accent (optional, 5th argument - the old `theme` slot): a game code, "LG"
-- "PB" "RPS" "DR" "GB" "QZ", or nothing for the house accent. It selects the
-- per-game mark and colour ONLY; there is one design and PG.Theme.Skin applies
-- it to every window. The plain backdrop below stays the ultimate fallback for
-- when the theme layer is unavailable. Legacy names still resolve.
function PG.UI.Window(key, title, w, h, accent)
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
  -- THE TITLE IS A CONTAINER, NOT A FLOATING FONTSTRING.
  --
  -- UIPanelCloseButton occupies x in [W-34, W-2] and the title's line shares
  -- that band, so a TOP-anchored string with no width slid under the X the
  -- moment it got long ("Start Rock Paper Scissors" already did). Reserving
  -- TITLE_RESERVE on BOTH sides makes the collision structurally impossible
  -- and keeps a centred string centred on the bar the player can see.
  --
  -- The width alone would have made it worse: WordWrap defaults ON, so a long
  -- title would wrap to two display lines and run into the page content at
  -- -52. Hence wrap off + one line: a title that does not fit ellipsizes.
  local M = (PG.Theme and PG.Theme.METRIC) or nil
  local reserve = (M and M.TITLE_RESERVE) or 34
  f.titleBar = CreateFrame("Frame", nil, f)
  f.titleBar:SetPoint("TOPLEFT", reserve, (M and M.TITLE_TOP) or -12)
  f.titleBar:SetPoint("TOPRIGHT", -reserve, (M and M.TITLE_TOP) or -12)
  f.titleBar:SetHeight((M and M.TITLE_H) or 24)
  local tmpl = (PG.Theme and PG.Theme.FontTemplate)
    and PG.Theme.FontTemplate("D2") or "GameFontNormalLarge"
  f.title = f.titleBar:CreateFontString(nil, "OVERLAY", tmpl)
  f.title:SetPoint("LEFT")
  f.title:SetPoint("RIGHT")          -- LEFT+RIGHT, never TOP plus a guess
  f.title:SetJustifyH("CENTER")
  f.title:SetWordWrap(false)
  f.title:SetMaxLines(1)
  f.title:SetText(title)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  -- Exposed, because the X is the addon's ONE dismiss gesture (PLAN 2.5) and
  -- ruling 5 made it load-bearing: a frozen result is dismissed by this button
  -- and by nothing else, so its owner has to be able to hook it. Hooking OnHide
  -- instead would be wrong - that also fires for a Safety hide, which is the
  -- opposite of a dismissal.
  f.closeBtn = close
  -- Skin applies the one design and stamps the accent; it also re-fonts and
  -- re-colours f.title, so the template above is only what a client without
  -- the theme layer would see.
  if PG.Theme and PG.Theme.Skin then
    PG.Theme.Skin(f, accent)
  end
  addResizeGrip(f)
  managed[#managed + 1] = f
  -- solver on show: a window opening onto an occupied spot moves itself clear
  f:HookScript("OnShow", function(self) PG.UI.ResolveOverlaps(self) end)
  PG.Safety.RegisterWindow(f)
  f:Hide()
  return f
end

-- Bind a button's label to the button. UIPanelButtonTemplate's text is
-- CENTER-anchored with no width and the template neither clips nor ellipsizes,
-- so an over-long label used to spill symmetrically past BOTH bevels onto
-- whatever was behind it. Bound, it truncates instead - which is visible,
-- fixable and never lands on a neighbour.
--
-- pad is the total reserve (default 8, i.e. 4 a side, about the width of the
-- template's bevel caps). A caller whose label is genuinely 2 px over should
-- pass a smaller pad or a wider button rather than ship an ellipsis.
-- Re-run it after a SetText that changes the label's length class; a plain
-- recolour or a same-length swap needs nothing (the width persists).
function PG.UI.FitLabel(b, pad)
  if not b then return b end
  local ok, fs = pcall(b.GetFontString, b)
  if not (ok and fs) then return b end
  local w = (b.GetWidth and b:GetWidth()) or 0
  pcall(fs.SetJustifyH, fs, "CENTER")
  pcall(fs.SetWordWrap, fs, false)
  pcall(fs.SetMaxLines, fs, 1)
  pcall(fs.SetWidth, fs, math.max(8, w - (tonumber(pad) or 8)))
  return b
end

-- Retitle a factory window. The title is a real FontString inside a bounded
-- container (PLAN 2.6), so an over-long one ellipsizes instead of sliding under
-- the close button and the caller just passes a string.
--
-- Both of these return false rather than erroring when the frame has no such
-- chrome: the six game modules drive headless in five harnesses that stub
-- PG.UI, and a window's decoration must never be a dependency of its logic.
function PG.UI.SetTitle(f, text)
  if not f then return false end
  local fs = f.title
  if type(fs) ~= "table" or type(fs.SetText) ~= "function" then return false end
  fs:SetText(tostring(text or ""))
  return true
end

-- Hook the window's X - the addon's ONE dismiss gesture, and the only way a
-- frozen result is dismissed (ruling 5). Deliberately not OnHide: that also
-- fires for a Safety hide, which is the opposite of a dismissal.
function PG.UI.OnClose(f, fn)
  if not (f and type(fn) == "function") then return false end
  local b = f.closeBtn
  if type(b) ~= "table" or type(b.HookScript) ~= "function" then return false end
  b:HookScript("OnClick", fn)
  return true
end

-- The wall-clock reading ("21:47") for something that happened `ago` seconds
-- in the past, or nil when the client has no clock functions - a caller that
-- cannot read the time renders without one rather than inventing one.
--
-- This is how a frozen result gets its timestamp WITHOUT the session record
-- carrying an extra field for it. The freeze happens up to a minute after the
-- game ended (longer if a boss pull is in the way), so the end time is derived
-- from the record's own doneAt at freeze time and the record is then free to
-- die. Nothing is stashed anywhere (PLAN 5.5).
function PG.UI.ClockAgo(ago)
  if type(date) ~= "function" or type(time) ~= "function" then return nil end
  ago = tonumber(ago) or 0
  if ago < 0 then ago = 0 end
  local ok, s = pcall(date, "%H:%M", time() - math.floor(ago))
  if ok and type(s) == "string" then return s end
  return nil
end

function PG.UI.Button(parent, label, w, h, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  b:SetText(label)
  PG.UI.FitLabel(b)
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
    -- the fallback must render at the CARD size (16), not the plain button's
    -- 12: the same primary action was two different sizes depending on whether
    -- an atlas resolved
    local plain = PG.UI.Button(parent, label, w, h, onClick)
    local big = GameFontNormalLarge
    if big then
      pcall(plain.SetNormalFontObject, plain, big)
      pcall(plain.SetHighlightFontObject, plain, big)
      pcall(plain.SetDisabledFontObject, plain, GameFontDisableLarge or big)
      PG.UI.FitLabel(plain)   -- re-fit: the font object changed under the label
    end
    return plain
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
-- 3*68 + 2*6 = 216, which centres cleanly under 320 and 420 alike, so the same
-- control works in a dialog and in a page. 82px segments were 44px of dead
-- space each for a 6-character label, and right-aligning the block while the
-- label sat left meant nothing in the control was centred.
local SEG_W, SEG_H, SEG_GAP, SEG_INSET = 68, 22, 6, 24
local SEG_BLOCK = SEG_W * 3 + SEG_GAP * 2
local PICKER_H = 58   -- label 20 + segments 22 + hint 16; see the note below

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
-- Returns a frame (58px block, unanchored - the caller places it) with:
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
  -- The declared height is the truth now. The hint used to render 13px BELOW a
  -- frame the caller was told was 44 tall, which is a live 7px overlap in the
  -- Quiz dialog and 1-5px of clearance in three others - every dialog was one
  -- copy edit from the same collision.
  f:SetSize(width, PICKER_H)

  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local Shadow = (PG.Theme and PG.Theme.Shadow) or nil
  local Font = (PG.Theme and PG.Theme.FontTemplate) or nil
  -- One selection idiom: the selected segment is painted, never forbidden.
  -- The inline colour escape is load-bearing - it is what renders the selected
  -- label gold THROUGH the disabled font object. Keep it if paint() is ever
  -- refactored.
  local SEL_CODE = (C and C.chgold) or "|cffffd876"
  local TINT = (C and C.VIOLET) or { 0.45, 0.32, 0.68 }

  local label = f:CreateFontString(nil, "OVERLAY", Font and Font("T") or "GameFontNormal")
  label:SetPoint("TOP", f, "TOP", 0, 0)
  label:SetWidth(width)
  label:SetJustifyH("CENTER")   -- the label and the block are one centred unit
  label:SetWordWrap(false)
  label:SetText("Audience")
  if C then
    label:SetTextColor(C.CHALK[1], C.CHALK[2], C.CHALK[3])
    if Shadow then Shadow(label) end
  end

  -- fallback hint (SCOPE.md 1.3), INSIDE the block; empty most of the time.
  -- Never wraps: two lines would put it back outside the frame.
  local hint = f:CreateFontString(nil, "OVERLAY", Font and Font("S") or "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", SEG_INSET, -44)
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -SEG_INSET, -44)
  hint:SetJustifyH("CENTER")
  hint:SetWordWrap(false)
  hint:SetMaxLines(1)
  hint:SetText("")
  if C then hint:SetTextColor(C.BRASS[1], C.BRASS[2], C.BRASS[3]) end
  if Shadow then Shadow(hint) end

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
        -- the handler instead, and the faded face says "no".
        --
        -- Faded ONCE. It used to be SetAlpha(0.6) AND a |cff808080 label, which
        -- put the label at ~2.7:1 - and the disabled state is only a message if
        -- you can read it. Alpha on the button dims the label and its own art
        -- together, so the label keeps its contrast against the face it sits on.
        b:SetEnabled(true)
        b:SetAlpha((PG.Theme and PG.Theme.DISABLED_ALPHA) or 0.55)
        b:SetText(SCOPE_LABEL[scope])
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
  local blockX = math.floor((width - SEG_BLOCK) / 2)   -- the block is centred
  if blockX < SEG_INSET then blockX = SEG_INSET end
  for i = 1, #SCOPE_ORDER do        -- built left to right, under the label
    local scope = SCOPE_ORDER[i]
    local b = PG.UI.Button(f, SCOPE_LABEL[scope], SEG_W, SEG_H, function(self)
      if self.__pgOff then
        showTip(self)   -- swallowed click: repeat the reason, do nothing else
        return
      end
      selectScope(self.__pgScope, true)
    end)
    if prev then
      b:SetPoint("TOPLEFT", prev, "TOPRIGHT", SEG_GAP, 0)
    else
      b:SetPoint("TOPLEFT", f, "TOPLEFT", blockX, -20)
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
-- Keys are unbounded over a session's life, so frames are pooled rather than
-- kept per key. At most ASK_MAX are active at once, so the pool tops out at
-- ASK_MAX frames and CreateFrame calls stay bounded.
local ASK_MAX = 3
PG.UI.ASK_MAX = ASK_MAX   -- games route invitation number ASK_MAX+1 to the launcher

local askPool = {}   -- ONE array of frames (active or idle), <= ASK_MAX
local askActive = {} -- key -> frame
local askOrder = {}  -- keys in activation order; drives the stack layout

-- One Ask flavour. The icon is the only per-game thing left, and it is applied
-- per ACTIVATION from the inviting game's accent - which is why one pool now
-- serves every game instead of one pool per theme.
local ASK_SOUND = { greet = "ticket", accept = "click", decline = "coincancel" }

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

local function buildAsk()
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f:SetSize(360, 140)
  f:SetFrameStrata("DIALOG")
  applyBackdrop(f)   -- the ultimate fallback; Skin paints the one design over it
  local Theme = PG.Theme
  local Font = Theme and Theme.FontTemplate
  local C = (Theme and Theme.C) and Theme.C() or nil
  if Theme and Theme.Skin then
    Theme.Skin(f)    -- one backdrop, pop-on-show, OnHide contract
  end
  -- the countdown first: the body's bottom rail anchors to it, so a longer
  -- invitation can never run down through it into the buttons
  f.timerText = f:CreateFontString(nil, "OVERLAY", Font and Font("S") or "GameFontNormalSmall")
  f.timerText:SetPoint("BOTTOM", 0, 44)
  f.timerText:SetJustifyH("CENTER")
  -- 36px mark on the TEXT's top rail, not floating at the frame's centre: with
  -- a two-line body (every real invitation is exactly two lines) the old
  -- LEFT 16,8 anchor left the icon beside white space.
  if Theme and Theme.Icon then
    f.icon = Theme.Icon(f, "ticket", 36)
    f.icon:SetPoint("TOPLEFT", 16, -18)
  end
  f.text = f:CreateFontString(nil, "OVERLAY", Font and Font("B") or "GameFontHighlight")
  f.text:SetPoint("TOPLEFT", f.icon and 62 or 18, -18)
  f.text:SetPoint("TOPRIGHT", -18, -18)
  f.text:SetJustifyH("CENTER")   -- one invitation sentence on a symmetric popup
  f.text:SetJustifyV("TOP")
  -- Bounded vertically, but by a HEIGHT, not by a third anchor: the box already
  -- has a left and a right, and a BOTTOM point would also constrain its centre
  -- x to the frame's, which contradicts them. 60 = the -18 top rail down to the
  -- countdown at -84, and 4 lines of 12pt cannot exceed it. Today's longest
  -- invitation is 2 lines; without this a wire-format change could run the body
  -- straight through the countdown and into the buttons.
  f.text:SetHeight(60)
  f.text:SetMaxLines(4)
  if C then
    -- chalk body (~14:1 on the board), CHRED countdown as the urgency cue;
    -- the number itself never animates
    f.text:SetTextColor(C.CHALK[1], C.CHALK[2], C.CHALK[3])
    f.timerText:SetTextColor(C.CHRED[1], C.CHRED[2], C.CHRED[3])
  end
  if Theme and Theme.Shadow then
    Theme.Shadow(f.text)
    Theme.Shadow(f.timerText)
  end
  f.acceptBtn = PG.UI.Button(f, "Accept", 130, 24, function() finishAsk(f, true) end)
  f.acceptBtn:SetPoint("BOTTOMLEFT", 20, 14)
  f.declineBtn = PG.UI.Button(f, "Decline", 130, 24, function() finishAsk(f, false) end)
  f.declineBtn:SetPoint("BOTTOMRIGHT", -20, 14)
  if Theme and Theme.Sound then
    f:HookScript("OnShow", function(self)
      if self.active and not self.__pgGreeted then
        self.__pgGreeted = true -- once per activation, even across deferred shows
        Theme.Sound(ASK_SOUND.greet)
      end
    end)
    f.acceptBtn:HookScript("OnClick", function() Theme.Sound(ASK_SOUND.accept) end)
    f.declineBtn:HookScript("OnClick", function() Theme.Sound(ASK_SOUND.decline) end)
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

-- An idle frame, or a new one. Called only when the cap allows another popup,
-- so the pool holds at most ASK_MAX frames.
local function acquireAsk()
  for i = 1, #askPool do
    if not askPool[i].active then return askPool[i] end
  end
  local f = buildAsk()
  askPool[#askPool + 1] = f
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
-- accent (optional, trailing - the old `theme` slot, existing callers
-- unaffected): the inviting game's code, which selects the popup's mark.
function PG.UI.Ask(key, text, acceptLabel, declineLabel, timeoutSec, onAccept, onDecline, accent)
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
  local f = acquireAsk()
  f.active = true
  f.__pgGreeted = nil
  f.__pgAskKey = key
  askActive[key] = f
  askOrder[#askOrder + 1] = key
  f.onAccept, f.onDecline = onAccept, onDecline
  -- the inviting game's mark, per activation (one pool, six possible marks)
  if f.icon and PG.Theme and PG.Theme.Accent and PG.Theme.Tex then
    PG.Theme.Tex(f.icon, PG.Theme.Accent(accent).mark)
  end
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
  for i = 1, #askPool do fn(askPool[i]) end
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
-- Declared here, above rectHits, because PG.UI.RectFree has to be able to see
-- it: the reveal stage's first candidate anchor (CENTER +120) swallows the
-- toast slot whole, and the stage's scrim is opaque enough to erase it.
local toast

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
  if toast and rectHits(toast, l, b, w, h) then return false end
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
  -- 660 x 44: two 12pt lines and their padding.
  --
  -- It was 700 x 26 with a 16pt fontstring that had no width, and a FontString
  -- with no width NEVER wraps - so nine real lines ran past the frame on one
  -- line, worst case 166 characters, which on a 4:3 UIParent loses about 150px
  -- off EACH end. The worst of them is the guild-cancel explanation, i.e. the
  -- toast that most needs reading. 12pt raises the break-even from 87
  -- characters to 116 and the second line catches the rest.
  toast:SetSize(660, 44)
  -- -110, not -170: Ask popup #1 sits at CENTER 0,140 and its DIALOG strata
  -- draws over the toast's HIGH, so the overflow toast ("3 more games are
  -- open") used to render behind the very popups it was describing.
  toast:SetPoint("TOP", 0, -110)
  toast:SetFrameStrata("HIGH")
  local Font = PG.Theme and PG.Theme.FontTemplate
  toast.text = toast:CreateFontString(nil, "OVERLAY", Font and Font("B") or "GameFontHighlight")
  toast.text:SetPoint("TOPLEFT", 10, -6)
  toast.text:SetPoint("TOPRIGHT", -10, -6)
  toast.text:SetJustifyH("CENTER")
  -- wrap, never truncate: these lines carry gold amounts, so two lines beat a
  -- dropped tail
  toast.text:SetWordWrap(true)
  toast.text:SetMaxLines(2)
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
  local M = (PG.Theme and PG.Theme.METRIC) or nil
  local Font = PG.Theme and PG.Theme.FontTemplate
  local bar = CreateFrame("StatusBar", nil, parent)
  -- 18, not 14: a 12pt countdown in a 14px track had 1.5px of air above and
  -- below and read as cramped rather than as a deliberate inset.
  bar:SetSize(w, (M and M.BAR_H) or 18)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.25, 0.7, 1)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  -- The countdown is centred, so it sits ON the fill for the first half of
  -- every timer: 10pt white with no shadow was 2.32:1 on the plain fill and
  -- 1.38:1 on the gold one. 12pt plus the standard over-art shadow, against a
  -- darkened fill (Theme.TimerBar), is the whole fix.
  bar.text = bar:CreateFontString(nil, "OVERLAY", Font and Font("B") or "GameFontHighlight")
  bar.text:SetPoint("CENTER")
  bar.text:SetJustifyH("CENTER")
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(bar.text) end
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  local function onUpdate(self)
    local remaining = (self.endTime or 0) - GetTime()
    if remaining <= 0 then
      self:Stop()
    else
      self:SetValue(remaining / self.total)
      -- "45s", matching PG.UI.Ask: two countdown widgets are frequently on
      -- screen together and used to disagree about the unit
      self.text:SetText(math.ceil(remaining) .. "s")
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
    self.text:SetText("0s")   -- land on zero; blanking it made it vanish
  end
  -- One bar skin, on every bar (it used to be gated on the goblin window). The
  -- bar and its text never animate.
  if PG.Theme and PG.Theme.TimerBar then PG.Theme.TimerBar(bar) end
  return bar
end

-------------------------------------------------------------------------------
-- Raise a factory window by its key (PLAN 1.3, the footer's click-to-focus).
--
-- The six play windows stay separate windows and can get lost behind other
-- frames; the shell is the index of them. `managed` is the only registry that
-- knows every factory window, which is why this lives here rather than in the
-- shell below.
--
-- It NEVER forces a window onto a screen that Safety owns, and it never
-- resurrects a window whose owner says the record behind it is gone:
--   * already shown  -> Raise only (no Show, no side effects)
--   * hidden         -> Show only when every Safety flag is clear AND the
--                       window's own __pgResume agrees, which is exactly the
--                       predicate Core's auto-resume uses.
-- Returns true if the window was actually raised or shown.
-------------------------------------------------------------------------------
function PG.UI.RaiseWindow(key)
  key = tostring(key or "")
  if key == "" then return false end
  local f
  for i = 1, #managed do
    if managed[i].__pgKey == key then f = managed[i] break end
  end
  if not f then return false end
  if f:IsShown() then
    pcall(f.Raise, f)
    return true
  end
  if not safetyAllClear() then return false end
  if f.__pgResume then
    local ok, res = pcall(f.__pgResume)
    if not (ok and res) then return false end
  end
  pcall(f.Show, f)
  pcall(f.Raise, f)
  return true
end

-------------------------------------------------------------------------------
-- THE GAME TILE (PLAN 2.8) - the Adventure-Guide picker button.
--
-- Six of these, anchored, 2 columns x 3 rows. Deliberately NOT a
-- ScrollBoxListGridView: at n = 6 that view drags in the mandatory
-- SetElementExtent hard-error, the MinimalScrollBar-must-be-an-EventFrame trap
-- and a DataProvider, and buys nothing a SetPoint does not.
--
-- THE SILENT DEAD BUTTON DIES HERE. The launcher shipped a fully enabled grid
-- button for a module that failed to load: click, nothing, no toast, no
-- tooltip. A tile that cannot be started says WHY on hover, and it is never
-- :Disable()d - that is the ScopePicker's reasoned idiom (a disabled Button is
-- a dead hover target on some builds and the tooltip IS the feature).
--
--   cfg.code     "LG" | "PB" | "RPS" | "DR" | "GB" | "QZ"  (accent + tile art)
--   cfg.label    the game's name, as the user reads it
--   cfg.onClick  fn(tile) - the caller decides what a click means per state
-- Returns a Button with:
--   :SetState(state, sub, reason)
--       state  "ready" | "yours" | "off"
--       sub    optional sub-line ("2 seated", "book open - 100g"), "" clears
--       reason "off" only: the sentence the hover tooltip gives instead
--   .state     the current state string
-------------------------------------------------------------------------------

local TILE_W, TILE_H = 190, 104
-- The six EJ dungeon-button files are 256 x 128 with the picture in the
-- top-left 175 x 95: 175/256 = 0.68359375, 95/128 = 0.7421875.
-- TWO TRAPS, both live on this line:
--   * the 4-arg order is (left, right, top, bottom). The generated docs say
--     (left, right, bottom, top); they are wrong, and the XML and the wiki
--     agree with the order used here.
--   * SetTexCoord must be re-applied AFTER every SetTexture, including the one
--     inside Theme.Tex - so it is applied below the Theme.Tex call, never
--     above it.
local TILE_L, TILE_R, TILE_T, TILE_B = 0, 0.68359375, 0, 0.7421875
local TILE_SCRIM_H = 34       -- the label band; grows for a two-line name
local TILE_LABEL_W = 170      -- 190 - 2 x 10
local TILE_EDGE = 2

local function tileEdge(tile, colorTex)
  local e = {}
  for i = 1, 4 do
    local t = tile:CreateTexture(nil, "BORDER", nil, 2)
    e[i] = t
  end
  e[1]:SetPoint("TOPLEFT");     e[1]:SetPoint("TOPRIGHT");     e[1]:SetHeight(TILE_EDGE)
  e[2]:SetPoint("BOTTOMLEFT");  e[2]:SetPoint("BOTTOMRIGHT");  e[2]:SetHeight(TILE_EDGE)
  e[3]:SetPoint("TOPLEFT");     e[3]:SetPoint("BOTTOMLEFT");   e[3]:SetWidth(TILE_EDGE)
  e[4]:SetPoint("TOPRIGHT");    e[4]:SetPoint("BOTTOMRIGHT");  e[4]:SetWidth(TILE_EDGE)
  for i = 1, 4 do colorTex(e[i]) end
  return e
end

function PG.UI.GameTile(parent, cfg)
  cfg = cfg or {}
  local Theme = PG.Theme
  local code = tostring(cfg.code or "PG")
  local acc = (Theme and Theme.Accent) and Theme.Accent(code) or nil
  local C = (Theme and Theme.C) and Theme.C() or nil
  local GOLD = (C and C.GOLD) or { 1, 0.82, 0 }
  local GRAY = (C and C.CHGRAY) or { 0.66, 0.66, 0.61 }
  local ACC = (acc and acc.color) or (C and C.CHGOLD) or { 1, 0.85, 0.46 }

  local tile = CreateFrame("Button", nil, parent)
  tile:SetSize(tonumber(cfg.width) or TILE_W, tonumber(cfg.height) or TILE_H)
  tile.__pgCode = code
  tile.__pgLabel = tostring(cfg.label or code)
  tile.state = "ready"

  -- the photo. A miss degrades through Theme.Tex's own chain to the second EJ
  -- path and then to a flat BOARD fill, which the design treats as a legal
  -- ground - so a wrong path costs a picture and never a layout.
  local art = tile:CreateTexture(nil, "BACKGROUND")
  art:SetAllPoints()
  if Theme and Theme.Tex then
    Theme.Tex(art, (acc and acc.tile) or "tile_pb")
  else
    art:SetColorTexture(0.07, 0.08, 0.10, 1)
  end
  pcall(art.SetTexCoord, art, TILE_L, TILE_R, TILE_T, TILE_B)  -- AFTER SetTexture
  tile.art = art

  -- the label band. Blizzard's own tile does this for the same reason: the
  -- name sits on a photograph, so it needs its own ground and a shadow.
  local scrim = tile:CreateTexture(nil, "BORDER")
  scrim:SetPoint("TOPLEFT", 4, -4)
  scrim:SetPoint("TOPRIGHT", -4, -4)
  scrim:SetHeight(TILE_SCRIM_H)
  scrim:SetColorTexture(0, 0, 0, 0.55)
  tile.scrim = scrim

  local edges = tileEdge(tile, function(t) t:SetColorTexture(0, 0, 0, 0.55) end)

  local label = tile:CreateFontString(nil, "OVERLAY",
    (Theme and Theme.FontTemplate) and Theme.FontTemplate("D2") or "GameFontNormalLarge")
  if Theme and Theme.SetFont then Theme.SetFont(label, "D2") end
  label:SetPoint("TOP", 0, -12)
  label:SetWidth(TILE_LABEL_W)
  label:SetJustifyH("CENTER")
  label:SetWordWrap(true)      -- a long name costs a second line, never a clip
  label:SetMaxLines(2)
  label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  if Theme and Theme.Shadow then Theme.Shadow(label) end
  label:SetText(tile.__pgLabel)
  tile.label = label

  local sub = tile:CreateFontString(nil, "OVERLAY",
    (Theme and Theme.FontTemplate) and Theme.FontTemplate("S") or "GameFontHighlightSmall")
  sub:SetPoint("BOTTOM", 0, 9)
  sub:SetWidth(TILE_LABEL_W)
  sub:SetJustifyH("CENTER")
  sub:SetWordWrap(false)
  sub:SetMaxLines(1)
  sub:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  if Theme and Theme.Shadow then Theme.Shadow(sub) end
  sub:SetText("")
  tile.sub = sub

  -- the live badge: the same 6x6 dot language the Games nav item uses
  local badge = tile:CreateTexture(nil, "OVERLAY", nil, 3)
  badge:SetSize(6, 6)
  badge:SetPoint("TOPRIGHT", -10, -10)
  badge:SetColorTexture(ACC[1], ACC[2], ACC[3], 1)
  badge:Hide()
  tile.badge = badge

  -- hover: the addon's one hover idiom, white at 0.08. HIGHLIGHT is a real
  -- draw layer, so the button shows and hides it without a script.
  local hi = tile:CreateTexture(nil, "HIGHLIGHT")
  hi:SetAllPoints()
  hi:SetColorTexture(1, 1, 1, 0.08)
  hi:SetBlendMode("ADD")

  local pushed = tile:CreateTexture(nil, "OVERLAY", nil, 2)
  pushed:SetAllPoints()
  pushed:SetColorTexture(0, 0, 0, 0.25)
  pushed:Hide()

  -- the scrim follows the label: "Rock Paper Scissors" is two Morpheus lines,
  -- and a two-line name on a one-line band would put its second line on the
  -- photograph.
  local function fitScrim()
    local ok, h = pcall(label.GetStringHeight, label)
    if ok and type(h) == "number" and h > 0 then
      scrim:SetHeight(math.max(TILE_SCRIM_H, math.floor(h + 0.5) + 16))
    end
  end
  fitScrim()

  local function paintEdge(bright)
    local r, g, b, a = 0, 0, 0, 0.55
    if bright then r, g, b, a = ACC[1], ACC[2], ACC[3], 0.9 end
    for i = 1, #edges do edges[i]:SetColorTexture(r, g, b, a) end
  end

  local function showTip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.__pgLabel)
    if self.state == "off" then
      local why = self.__pgReason or "Not available right now."
      if GameTooltip_AddErrorLine then
        pcall(GameTooltip_AddErrorLine, GameTooltip, why)
      else
        GameTooltip:AddLine(why, 1, 0.54, 0.44, true)
      end
    elseif self.state == "yours" then
      GameTooltip:AddLine(self.__pgSub ~= "" and self.__pgSub or "You are in this game.",
        1, 1, 1, true)
      GameTooltip:AddLine("Click to bring its window up.", 0.66, 0.66, 0.61, true)
    else
      GameTooltip:AddLine("Set up a game.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end

  tile:SetScript("OnEnter", function(self)
    paintEdge(self.state ~= "off")
    showTip(self)
  end)
  tile:SetScript("OnLeave", function()
    paintEdge(false)
    GameTooltip:Hide()
  end)
  tile:SetScript("OnMouseDown", function() pushed:Show() end)
  tile:SetScript("OnMouseUp", function() pushed:Hide() end)
  tile:SetScript("OnHide", function() pushed:Hide() end)
  tile:SetScript("OnClick", function(self)
    if self.state == "off" then
      showTip(self)   -- swallowed click: repeat the reason, do nothing else
      return
    end
    if type(cfg.onClick) == "function" then cfg.onClick(self) end
  end)

  -- state, sub-line and reason in one call, because they always change together
  function tile:SetState(state, subText, reason)
    if state ~= "yours" and state ~= "off" then state = "ready" end
    self.state = state
    self.__pgReason = (state == "off") and (reason or "Not available right now.") or nil
    self.__pgSub = tostring(subText or "")
    self.sub:SetText(self.__pgSub)
    if state == "off" then
      pcall(self.art.SetDesaturated, self.art, true)
      self.label:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
      self.badge:Hide()
    else
      pcall(self.art.SetDesaturated, self.art, false)
      self.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
      if state == "yours" then self.badge:Show() else self.badge:Hide() end
    end
    fitScrim()
    return self
  end

  return tile
end

-------------------------------------------------------------------------------
-- THE SHELL (PLAN 1.2, 1.5) - one hub window, four nav items, stacked pages.
--
-- ONLY THE HUB LIVES HERE. The six play windows stay their own windows: the
-- Pull Book legitimately runs alongside another game, and the Rules have to be
-- readable while a game is live.
--
-- Two navigation levels, Adventure-Guide shaped:
--   level 0  the persistent four-item nav: Games . Ledger . Rules . Settings
--   level 1  the four pages behind those items
--   level 2  a page pushed from a tile (a game's setup panel), with the game's
--            name in the title bar, an accent rule under it and a Back button
--
-- Pages are REAL FRAMES, one shown at a time - Blizzard's own
-- Container{SettingsCanvas, SettingsList} shape, which this addon already
-- ships a version of in PullBook.lua's configWidgets SetShown dance. They are
-- built LAZILY on first focus (the createOnDemand pattern), so the shell costs
-- less at load than the nine windows it replaces.
--
-- Selected state is PAINTED, never :Disable()d - one selection idiom addon
-- wide, and a disabled Button is a dead hover target.
-------------------------------------------------------------------------------

-- 444 x 672, and every number below is a multiple of GRID = 4:
--   12  top margin
--   24  title row      (the factory's own title container)
--    8  gap
--   26  nav band       4 x 102 + 3 x 4 = 420
--    8  gap
--  548  content slot   420 wide, exactly one page shown
--    8  gap
--   26  footer         DND sign + status; always reserved, never resizes
--   12  bottom margin
local SHELL_W, SHELL_H = 444, 672
local SHELL_PAD = 12
local NAV_W, NAV_H, NAV_GAP, NAV_BAND = 102, 24, 4, 26
local CONTENT_W, CONTENT_H = 420, 548
local FOOTER_H = 26
local NAV_Y = -44                       -- 12 + 24 + 8
local SLOT_Y = NAV_Y - NAV_BAND - 8     -- -78
local PAGE_PAD = 8                      -- first element inside a page
local TITLE_RESERVE = 80                -- 56 back button + 12, and symmetric

-- The nav is CHROME: four fixed items in a fixed order, declared by the shell
-- rather than derived from whatever registered. A module that failed to load
-- leaves its nav item in place and its page explains itself, instead of the
-- row silently losing an item and re-flowing.
local NAV_ITEMS = {
  { id = "games",    label = "Games"    },
  { id = "ledger",   label = "Ledger"   },
  { id = "rules",    label = "Rules"    },
  { id = "settings", label = "Settings" },
}

local Shell = {}
PG.UI.Shell = Shell

Shell.WIDTH, Shell.HEIGHT = SHELL_W, SHELL_H
Shell.CONTENT_W, Shell.CONTENT_H = CONTENT_W, CONTENT_H
Shell.PAGE_PAD = PAGE_PAD

local shell, slot, footer, backBtn, accentRule
local navBtns = {}
local pages = {}            -- id -> { def = , frame = , broken = }
local history = {}          -- level-2 return stack, capped
local currentId
local buildCbs = {}
local missingFrame
local inFocus = false       -- suppresses the OnShow refocus during a Focus

local function pageLevel(id)
  local p = pages[id]
  local lv = p and tonumber(p.def.level) or 1
  return (lv == 2) and 2 or 1
end

-- which nav item a page lights up: its own id when it is one, otherwise the
-- def's declared owner, otherwise Games
local function navOf(id)
  for i = 1, #NAV_ITEMS do
    if NAV_ITEMS[i].id == id then return id end
  end
  local p = pages[id]
  local n = p and p.def.nav
  return (type(n) == "string" and n) or "games"
end

local function titleOf(id)
  local p = pages[id]
  local t = p and p.def.title
  if type(t) == "function" then
    local ok, s = pcall(t)
    if ok and type(s) == "string" and s ~= "" then return s end
    t = nil
  end
  if type(t) == "string" and t ~= "" then return t end
  return "Pengyou Games"
end

local function navPaint()
  local want = currentId and navOf(currentId) or nil
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local SEL = (C and C.CHGOLD) or { 1, 0.85, 0.46 }
  local IDLE = (C and C.CHGRAY) or { 0.66, 0.66, 0.61 }
  for i = 1, #navBtns do
    local b = navBtns[i]
    local sel = (b.__pgNavId == want)
    b.rule:SetShown(sel)
    if PG.Theme and PG.Theme.SetFont then
      PG.Theme.SetFont(b.label, sel and "T" or "B")
    end
    if sel then
      b.label:SetTextColor(SEL[1], SEL[2], SEL[3])
    else
      b.label:SetTextColor(IDLE[1], IDLE[2], IDLE[3])
    end
  end
end

local function applyChrome(id)
  if not shell then return end
  if shell.title then shell.title:SetText(titleOf(id)) end
  local lvl2 = (pageLevel(id) == 2)
  backBtn:SetShown(lvl2)
  if lvl2 then
    local p = pages[id]
    local acc = (PG.Theme and PG.Theme.Accent)
      and PG.Theme.Accent(p and p.def.accent or id) or nil
    local c = (acc and acc.color) or { 0.45, 0.32, 0.68 }
    accentRule:SetColorTexture(c[1], c[2], c[3], 0.9)
    accentRule:Show()
  else
    accentRule:Hide()
  end
  navPaint()
end

-- The page for a module that is not there. One frame, reused: it is the answer
-- to a nav item whose file failed to load, and it is a sentence rather than a
-- dead click.
local function ensureMissing()
  if missingFrame then return missingFrame end
  local f = CreateFrame("Frame", nil, slot)
  f:SetSize(CONTENT_W, CONTENT_H)
  f:SetPoint("TOP", slot, "TOP", 0, 0)
  local fs = f:CreateFontString(nil, "OVERLAY",
    (PG.Theme and PG.Theme.FontTemplate) and PG.Theme.FontTemplate("B") or "GameFontHighlight")
  fs:SetPoint("TOPLEFT", 24, -160)
  fs:SetPoint("TOPRIGHT", -24, -160)
  fs:SetJustifyH("CENTER")
  fs:SetWordWrap(true)
  fs:SetMaxLines(3)
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  if C then fs:SetTextColor(C.CHGRAY[1], C.CHGRAY[2], C.CHGRAY[3]) end
  f.text = fs
  f:Hide()
  missingFrame = f
  return f
end

local function buildPage(id)
  local p = pages[id]
  if not p then return nil end
  if p.frame then return p.frame end
  local f = CreateFrame("Frame", nil, slot)
  local w = math.min(tonumber(p.def.width) or CONTENT_W, CONTENT_W)
  local h = math.min(tonumber(p.def.height) or CONTENT_H, CONTENT_H)
  f:SetSize(w, h)
  -- anchored TOP in the slot, so a page built at its old window's size keeps
  -- every internal anchor it had
  f:SetPoint("TOP", slot, "TOP", 0, 0)
  f.__pgPageId = id
  f.__pgTop = -PAGE_PAD          -- the page's first-element y; use it, do not
                                 -- keep an old window's title reserve
  f.__pgAccent = p.def.accent or "PG"
  f:Hide()
  p.frame = f
  if type(p.def.build) == "function" then
    local ok, err = pcall(p.def.build, f)
    if not ok then
      p.broken = true
      if geterrorhandler then geterrorhandler()(err) end
    end
  end
  return f
end

local function hideCurrent(nextId)
  if currentId == nil or currentId == nextId then return end
  local p = pages[currentId]
  if p and p.frame then
    p.frame:Hide()
    if type(p.def.onHide) == "function" then pcall(p.def.onHide, p.frame) end
  end
  if missingFrame then missingFrame:Hide() end
end

-- Show the shell and select a page. Builds the shell and the page on demand.
-- arg is handed to the page's onShow (Rules uses it for "which game").
function Shell.Focus(id, arg)
  local f = Shell.Frame()
  if not f then return false end
  id = tostring(id or "")
  local p = pages[id]
  local target
  if p and not p.broken then
    target = buildPage(id)
    if p.broken then target = nil end
  end
  if not target then
    target = ensureMissing()
    local label = id
    for i = 1, #NAV_ITEMS do
      if NAV_ITEMS[i].id == id then label = NAV_ITEMS[i].label end
    end
    target.text:SetText(label .. " did not load. Reload the interface, and if it "
      .. "keeps happening the addon is missing a file.")
  end
  hideCurrent(id)
  -- A level-1 page normally clears the trail: you asked for a top-level place, so
  -- Back has nowhere sensible to go. The exception is arriving from a level-2 page
  -- - tapping Rules while filling in a game's setup form. Remembering that one step
  -- is what lets Back return to the half-filled form instead of dumping the player
  -- on the grid. Capped at one entry deliberately: a deeper trail through top-level
  -- pages is a history nobody asked for.
  if pageLevel(id) == 1 then
    local from = currentId
    wipe(history)
    if from and from ~= id and pageLevel(from) == 2 then
      history[1] = from
    end
  end
  currentId = id
  target:Show()
  applyChrome(id)
  if p and not p.broken and type(p.def.onShow) == "function" then
    pcall(p.def.onShow, target, arg)
  end
  inFocus = true
  if not f:IsShown() then f:Show() end
  inFocus = false
  return true
end

-- Level 2. Same as Focus, plus a return address: Back, the Games nav item and
-- a right-click all come back out.
function Shell.Push(id, arg)
  local from = currentId
  local ok = Shell.Focus(id, arg)
  if ok and from and from ~= id and pageLevel(id) == 2 then
    history[#history + 1] = from
    while #history > 8 do table.remove(history, 1) end
  end
  return ok
end

function Shell.Back()
  local id = table.remove(history)
  if not id then
    local p = pages[currentId]
    id = (p and (p.def.back or p.def.nav)) or "games"
  end
  return Shell.Focus(id)
end

-- id must be unique. A page may be re-declared only while it is still unbuilt,
-- so a live frame can never be orphaned by a second registration.
--   def.title    string | fn() -> string   level 2 wants one; level 1 keeps
--                                          the wordmark by default
--   def.level    1 (default) | 2
--   def.nav      which nav item lights up (level 2; default "games")
--   def.back     where Back lands with an empty history (default def.nav)
--   def.accent   game code for the level-2 accent rule (default the id)
--   def.width    default 420, clamped to the slot
--   def.height   default 548, clamped to the slot
--   def.build    fn(page)          once, lazily, on first focus
--   def.onShow   fn(page, arg)     every focus, and every shell re-open
--   def.onHide   fn(page)          when another page takes the slot
function Shell.RegisterPage(id, def)
  id = tostring(id or "")
  if id == "" or type(def) ~= "table" then return false end
  local prev = pages[id]
  if prev and prev.frame then return false end
  pages[id] = { def = def }
  return true
end

function Shell.HasPage(id) return pages[tostring(id or "")] ~= nil end

-- The page frame, built if it is not yet. nil for an unregistered id.
function Shell.Page(id)
  local p = pages[tostring(id or "")]
  if not p then return nil end
  Shell.Frame()
  return buildPage(tostring(id or ""))
end

function Shell.Current() return currentId end

function Shell.IsShown() return (shell and shell:IsShown()) and true or false end

function Shell.Hide() if shell then shell:Hide() end end

-- Open on id, or close if that page is already the one on screen.
function Shell.Toggle(id, arg)
  id = tostring(id or "games")
  if Shell.IsShown() and currentId == id then
    shell:Hide()
    return false
  end
  Shell.Focus(id, arg)
  return true
end

-- A 6x6 dot on a nav item (open games waiting behind the Games item). Same
-- badge language as the tiles.
function Shell.SetBadge(id, on)
  if not shell then return end
  for i = 1, #navBtns do
    if navBtns[i].__pgNavId == id then navBtns[i].badge:SetShown(on and true or false) end
  end
end

-- The footer strip (DND sign left, status right). Its CONTENT belongs to the
-- launcher; the strip itself is chrome and is always reserved.
function Shell.Footer()
  Shell.Frame()
  return footer
end

-- Run fn(shell) once, immediately after the shell frame exists (or right now
-- if it already does). This is how the launcher fills the footer without
-- forcing the shell to be built at load.
function Shell.OnBuild(fn)
  if type(fn) ~= "function" then return end
  if shell then
    pcall(fn, shell)
  else
    buildCbs[#buildCbs + 1] = fn
  end
end

local function buildNav()
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local ACC = (C and C.CHGOLD) or { 1, 0.85, 0.46 }
  for i = 1, #NAV_ITEMS do
    local item = NAV_ITEMS[i]
    local b = CreateFrame("Button", nil, shell)
    b:SetSize(NAV_W, NAV_H)
    b:SetPoint("TOPLEFT", SHELL_PAD + (i - 1) * (NAV_W + NAV_GAP), NAV_Y)
    b.__pgNavId = item.id
    local hi = b:CreateTexture(nil, "HIGHLIGHT")
    hi:SetAllPoints()
    hi:SetColorTexture(1, 1, 1, 0.08)
    hi:SetBlendMode("ADD")
    b.label = b:CreateFontString(nil, "OVERLAY",
      (PG.Theme and PG.Theme.FontTemplate) and PG.Theme.FontTemplate("B") or "GameFontHighlight")
    b.label:SetPoint("LEFT")
    b.label:SetPoint("RIGHT")
    b.label:SetJustifyH("CENTER")
    b.label:SetWordWrap(false)
    b.label:SetMaxLines(1)
    b.label:SetText(item.label)
    if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(b.label) end
    -- selected = a 2px accent bar under the label. Painted, never disabled.
    b.rule = b:CreateTexture(nil, "OVERLAY")
    b.rule:SetPoint("BOTTOMLEFT", 8, 0)
    b.rule:SetPoint("BOTTOMRIGHT", -8, 0)
    b.rule:SetHeight(2)
    b.rule:SetColorTexture(ACC[1], ACC[2], ACC[3], 0.9)
    b.rule:Hide()
    b.badge = b:CreateTexture(nil, "OVERLAY")
    b.badge:SetSize(6, 6)
    b.badge:SetPoint("TOPRIGHT", -6, -2)
    b.badge:SetColorTexture(ACC[1], ACC[2], ACC[3], 1)
    b.badge:Hide()
    b:SetScript("OnClick", function(self) Shell.Focus(self.__pgNavId) end)
    navBtns[i] = b
  end
  navPaint()   -- idle colours from the start, before any page is focused
end

-- The one hub window. Built on first use, never rebuilt.
function Shell.Frame()
  if shell then return shell end
  shell = PG.UI.Window("main", "Pengyou Games", SHELL_W, SHELL_H, "PG")

  -- 68 reserved on the LEFT for the back button (56 + 12) and 68 on the right
  -- (34 close + 34 symmetry), so a centred title is centred on the bar the
  -- player can see and can never slide under the X.
  if shell.titleBar then
    shell.titleBar:ClearAllPoints()
    shell.titleBar:SetPoint("TOPLEFT", TITLE_RESERVE, -SHELL_PAD)
    shell.titleBar:SetPoint("TOPRIGHT", -TITLE_RESERVE, -SHELL_PAD)
  end

  backBtn = PG.UI.Button(shell, "< Back", 56, 22, function() Shell.Back() end)
  backBtn:SetPoint("TOPLEFT", SHELL_PAD, -13)
  backBtn:Hide()

  -- the level-2 accent rule, directly under the title container
  accentRule = shell:CreateTexture(nil, "OVERLAY")
  accentRule:SetPoint("TOPLEFT", TITLE_RESERVE, -38)
  accentRule:SetPoint("TOPRIGHT", -TITLE_RESERVE, -38)
  accentRule:SetHeight(2)
  accentRule:Hide()

  buildNav()

  slot = CreateFrame("Frame", nil, shell)
  slot:SetSize(CONTENT_W, CONTENT_H)
  slot:SetPoint("TOPLEFT", SHELL_PAD, SLOT_Y)

  footer = CreateFrame("Frame", nil, shell)
  footer:SetHeight(FOOTER_H)
  footer:SetPoint("BOTTOMLEFT", SHELL_PAD, SHELL_PAD)
  footer:SetPoint("BOTTOMRIGHT", -SHELL_PAD, SHELL_PAD)

  -- Right-click: back on a pushed page, close on a level-1 page. Suppressed
  -- while an EditBox has focus, so a right-click inside a setup field cannot
  -- navigate away from what you are typing into.
  shell:HookScript("OnMouseUp", function(self, button)
    if button ~= "RightButton" then return end
    if GetCurrentKeyBoardFocus then
      local ok, f = pcall(GetCurrentKeyBoardFocus)
      if ok and f then return end
    end
    if currentId and pageLevel(currentId) == 2 then
      Shell.Back()
    else
      self:Hide()
    end
  end)

  -- Re-opening the shell repaints whatever page was up. Page OnShow scripts are
  -- deliberately NOT relied on: whether hiding an ancestor fires OnHide/OnShow
  -- on a shown descendant is exactly the kind of thing that differs by build,
  -- and the page contract here promises def.onShow on every appearance.
  shell:HookScript("OnShow", function()
    if inFocus or not currentId then return end
    local p = pages[currentId]
    if p and not p.broken and p.frame and type(p.def.onShow) == "function" then
      pcall(p.def.onShow, p.frame)
    end
  end)

  for i = 1, #buildCbs do pcall(buildCbs[i], shell) end
  wipe(buildCbs)
  return shell
end
