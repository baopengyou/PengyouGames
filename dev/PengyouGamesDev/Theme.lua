-- Theme.lua - goblin-heist / darkmoon-bookmaker skin layer (SKIN.md section 5).
-- Asset table, palettes, pcall-guarded texture/atlas/sound/model helpers,
-- reusable AnimationGroup factories, pooled coin shower, NPC model handle.
--
-- Contract (SKIN.md section 0): every Blizzard art/sound/model call is pcall'd
-- with a documented fallback; helpers never error and never return nil where a
-- region/handle is promised; gameplay never branches on whether art rendered
-- (sole exception: npc.ok, which only picks between two decorative layouts).
-- Safety hide stays instant: the OnHide contract (section 5.9) Stop()s every
-- Theme group, hides FX regions, and bumps the generation counter that
-- invalidates all pending Theme timers. No Theme code ever calls Show() on a
-- window; the hide path performs no model calls, no sounds, and no Show.
--
-- File-scope purity: only PG.Theme functions and pure data tables here. All
-- frames, textures, pools, and animation groups are created lazily at runtime.
local ADDON, PG = ...

PG.Theme = {}
local Theme = PG.Theme

-------------------------------------------------------------------------------
-- Pure data: palettes (SKIN.md 1.1), assets, sounds (section 4), emotes (5.7)
-------------------------------------------------------------------------------

local COLORS = {
  PARCH   = { 0.82, 0.72, 0.55, hex = "d1b78c" },
  INK     = { 0.25, 0.17, 0.08, hex = "402c14" },
  AMBER   = { 0.48, 0.29, 0.00, hex = "7a4a00" },
  GOLD    = { 1.00, 0.82, 0.00, hex = "ffd200" },
  LOSS    = { 0.56, 0.09, 0.00, hex = "8f1600" },
  WIN     = { 0.08, 0.32, 0.08, hex = "145214" },
  FADE    = { 0.42, 0.36, 0.26, hex = "6b5c42" },
  BOARD   = { 0.07, 0.08, 0.10, hex = "12141a" },
  VIOLET  = { 0.45, 0.32, 0.68, hex = "7352ad" },
  CHALK   = { 0.95, 0.93, 0.87, hex = "f2eede" },
  CHGOLD  = { 1.00, 0.85, 0.46, hex = "ffd876" },
  CHRED   = { 1.00, 0.54, 0.44, hex = "ff8a70" },
  CHGREEN = { 0.49, 0.93, 0.64, hex = "7deda4" },
  CHGRAY  = { 0.66, 0.66, 0.61, hex = "a8a89c" },
  BRASS   = { 0.80, 0.68, 0.42, hex = "ccad6b" },
}

-- Asset chains: tried in order; array steps are { atlas = name } or
-- { file = path }; .color is the terminal solid-color fallback (SKIN.md 5.2).
local ASSETS = {
  coin      = { { atlas = "auctionhouse-icon-coin-gold" },
                { file = "Interface\\MoneyFrame\\UI-GoldIcon" },
                color = { 1, 0.82, 0, 1 } },
  coinpile  = { { file = "Interface\\Icons\\INV_Misc_Coin_02" },
                color = { 1, 0.82, 0, 1 } },
  ticket    = { { file = "Interface\\Icons\\INV_Misc_Ticket_Darkmoon_01" },
                color = { 0.82, 0.72, 0.55, 1 } },
  sack      = { { atlas = "Garr_TreasureIcon" },
                { file = "Interface\\Icons\\INV_Misc_Bag_10" },
                color = { 0.80, 0.68, 0.42, 1 } },
  chest     = { { atlas = "ChallengeMode-Chest" },
                { file = "Interface\\Icons\\INV_Misc_Coin_02" },
                color = { 1, 0.82, 0, 1 } },
  glow      = { { atlas = "loottoast-glow" },
                color = { 1, 0.82, 0, 0.5 } },
  starburst = { { atlas = "OBJFX_StarBurst" },
                { file = "Interface\\Cooldown\\star4" },
                color = { 1, 1, 0.8, 0.7 } },
  star      = { { file = "Interface\\Cooldown\\star4" },
                color = { 1, 1, 0.8, 0.7 } },
  goldpile  = { { atlas = "islands-queue-prop-coins" },
                color = { 1, 0.82, 0, 0.35 } },
  redx      = { { atlas = "common-icon-redx" },
                color = { 0.56, 0.09, 0, 1 } },
  ribbon    = { { atlas = "ui-frame-neutral-ribbon" },
                color = { 1, 0.82, 0, 1 } },
  card      = { { atlas = "ui-frame-neutral-cardparchment" },
                color = { 0.82, 0.72, 0.55, 1 } },
  parchment = { { file = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal" },
                color = { 0.82, 0.72, 0.55, 1 } },
  sheet     = { { atlas = "questbg-parchment" },
                { file = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal" },
                color = { 0.82, 0.72, 0.55, 1 } },
  warboard  = { { atlas = "warboard-parchment" },
                color = { 0.82, 0.72, 0.55, 1 } },
  goldheader= { { file = "Interface\\DialogFrame\\UI-DialogBox-Gold-Header" },
                color = { 1, 0.82, 0, 1 } },
  tarotK    = { { file = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Heroism_01" },
                color = { 0.45, 0.32, 0.68, 1 } },
  tarotD    = { { file = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Beasts_01" },
                color = { 0.45, 0.32, 0.68, 1 } },
  tarotW    = { { file = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Maelstrom_01" },
                color = { 0.45, 0.32, 0.68, 1 } },
  goldicon  = { { file = "Interface\\MoneyFrame\\UI-GoldIcon" },
                color = { 1, 0.82, 0, 1 } },
  dice      = { { file = "Interface\\Buttons\\UI-GroupLoot-Dice-Up" },
                color = { 0.95, 0.93, 0.87, 1 } },
  rps_rock  = { { file = "Interface\\Icons\\INV_Stone_15" },
                color = { 0.66, 0.66, 0.61, 1 } },
  rps_paper = { { file = "Interface\\Icons\\INV_Scroll_02" },
                color = { 0.82, 0.72, 0.55, 1 } },
  rps_scissors = { { file = "Interface\\Icons\\Ability_Rogue_SliceDice" },
                color = { 0.95, 0.93, 0.87, 1 } },
  greedcoin = { { file = "Interface\\Buttons\\UI-GroupLoot-Coin-Up" },
                color = { 1, 0.82, 0, 1 } },
  pass      = { { file = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" },
                color = { 0.66, 0.66, 0.61, 1 } },
}

-- SKIN.md section 4. Every play goes through Theme.Sound's gates.
local SOUNDS = {
  open = 852, parchment = 844, page = 836, greet = 5964, farewell = 5965,
  coinpick = 864, coinlock = 865, coincancel = 866, potclink = 891,
  stamp = 5274, bookclose = 5275, ticket = 39515, coins = 120,
  laugh = 23330, cheer = 19089, settled = 878, fanfare = 888, click = 852,
}

-- Emote name -> animation ID (SKIN.md 5.7); durations for one-shot auto-reset
-- to idle (A10). talk/idle have no duration: talk loops until Emote("idle").
local EMOTES = {
  idle = 0, greet = 67, talk = 60, ask = 65, excited = 64, nod = 185,
  cheer = 68, laugh = 70, applaud = 80, dance = 69, point = 84,
}
local EMOTE_DUR = {
  greet = 2.0, excited = 2.0, ask = 2.0, point = 2.0, nod = 1.2,
  laugh = 2.5, cheer = 2.5, applaud = 2.5, dance = 4.0,
}

local NPC_IDS  = { host = { 6882, 7034, 2454 }, bookie = { 7051, 6882 } }
local NPC_ICON = { host = "coinpile", bookie = "ticket" }

-- Backdrop treatment per theme (SKIN.md 1.3).
local BACKDROPS = {
  goblin = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 11, top = 11, bottom = 11 },
  },
  faire = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  },
  neutral = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  },
}
local BORDER_TINT = { goblin = { 1, 1, 1 }, faire = COLORS.VIOLET, neutral = COLORS.BRASS }
local TITLE_COLOR = { goblin = COLORS.GOLD, faire = COLORS.CHGOLD, neutral = COLORS.GOLD }

local MORPHEUS = "Fonts\\MORPHEUS.TTF"

-------------------------------------------------------------------------------
-- Small guarded primitives
-------------------------------------------------------------------------------

local atlasCache = {}
local function atlasExists(name)
  local hit = atlasCache[name]
  if hit ~= nil then return hit end
  local exists = false
  if C_Texture and C_Texture.GetAtlasInfo then
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    exists = ok and info ~= nil
  end
  atlasCache[name] = exists
  return exists
end

-- SetBackdrop (and SetTexture) succeed silently when the file is missing, so
-- pcall alone can never detect an absent bgFile/edgeFile; probe the file id
-- directly (conservative default: false when the API is unavailable, i.e.
-- unthemed but solid, matching atlasExists).
local fileCache = {}
local function fileExists(path)
  local hit = fileCache[path]
  if hit ~= nil then return hit end
  local exists = false
  if GetFileIDFromPath then
    local ok, id = pcall(GetFileIDFromPath, path)
    exists = ok and id ~= nil
  end
  fileCache[path] = exists
  return exists
end
Theme.FileExists = fileExists

local function newGroup(owner)
  local ok, g = pcall(owner.CreateAnimationGroup, owner)
  if ok and g then return g end
  return nil
end

local function newAnim(g, kind)
  local ok, a = pcall(g.CreateAnimation, g, kind)
  if ok and a then return a end
  return nil
end

-- Scale anim setters changed names across client versions; try both.
local function setScaleRange(a, fx, fy, tx, ty)
  if not a then return end
  if pcall(a.SetScaleFrom, a, fx, fy) then
    pcall(a.SetScaleTo, a, tx, ty)
  else
    pcall(a.SetFromScale, a, fx, fy)
    pcall(a.SetToScale, a, tx, ty)
  end
end

local function setAlphaRange(a, from, to)
  if not a then return end
  pcall(a.SetFromAlpha, a, from)
  pcall(a.SetToAlpha, a, to)
end

local function restart(g)
  if not g then return end
  if not pcall(g.Restart, g) then
    pcall(g.Stop, g)
    pcall(g.Play, g)
  end
end

-------------------------------------------------------------------------------
-- 5.8 Palette. One frozen union table (do not mutate); modules capture at init.
-- For each NAME: t.NAME = {r,g,b} and t.name = "|cffrrggbb".
-------------------------------------------------------------------------------

local paletteCache
function Theme.C(themeName)
  if not paletteCache then
    paletteCache = {}
    for name, c in pairs(COLORS) do
      paletteCache[name] = { c[1], c[2], c[3] }
      paletteCache[string.lower(name)] = "|cff" .. c.hex
    end
  end
  return paletteCache
end

-------------------------------------------------------------------------------
-- 5.2 / 5.3 / 5.4 Texture and markup helpers
-------------------------------------------------------------------------------

-- Applies art for key onto an existing Texture. True if themed art rendered,
-- false if the solid-color fallback was applied (already applied; the return
-- lets decoration-only callers choose tex:Hide()).
function Theme.Tex(tex, key)
  if not tex then return false end
  local entry = ASSETS[key]
  if entry then
    for i = 1, #entry do
      local step = entry[i]
      if step.atlas then
        if atlasExists(step.atlas) and pcall(tex.SetAtlas, tex, step.atlas, false) then
          return true
        end
      elseif step.file then
        if pcall(tex.SetTexture, tex, step.file) then
          local okG, cur = pcall(tex.GetTexture, tex)
          if not okG or cur ~= nil then return true end
        end
      end
    end
  end
  local c = (entry and entry.color) or { 0.5, 0.5, 0.5, 1 }
  pcall(tex.SetColorTexture, tex, c[1], c[2], c[3], c[4] or 1)
  return false
end

-- ARTWORK texture on parent, size x size, themed per key. ALWAYS returns a
-- Texture (caller anchors it).
function Theme.Icon(parent, key, size)
  local ok, tex = pcall(parent.CreateTexture, parent, nil, "ARTWORK")
  if not (ok and tex) then
    tex = UIParent:CreateTexture(nil, "ARTWORK")
    tex:Hide()
  end
  tex:SetSize(size or 24, size or 24)
  Theme.Tex(tex, key)
  return tex
end

-- Cached inline markup for FontStrings; "" when the entry is unavailable.
-- File steps are probed on a lazily built hidden scratch texture (the same
-- pcall(SetTexture)+GetTexture~=nil check Theme.Tex uses, SKIN.md 5.4) so a
-- missing icon file never bakes dead |T markup into cached strings.
local markCache = {}
local markScratch
local function fileRenders(path)
  if markScratch == nil then
    local ok, tex = pcall(UIParent.CreateTexture, UIParent, nil, "BACKGROUND")
    if ok and tex then
      tex:Hide()
      markScratch = tex
    else
      markScratch = false
    end
  end
  if not markScratch then return false end
  if not pcall(markScratch.SetTexture, markScratch, path) then return false end
  local okG, cur = pcall(markScratch.GetTexture, markScratch)
  return not okG or cur ~= nil
end

function Theme.Mark(key)
  local hit = markCache[key]
  if hit ~= nil then return hit end
  local entry = ASSETS[key]
  local mark = ""
  if entry then
    for i = 1, #entry do
      local step = entry[i]
      if step.atlas then
        if atlasExists(step.atlas) then
          mark = "|A:" .. step.atlas .. ":0:0|a"
          break
        end
      elseif step.file then
        if fileRenders(step.file) then
          mark = "|T" .. step.file .. ":0|t"
          break
        end
      end
    end
  end
  markCache[key] = mark
  return mark
end

function Theme.Money(g)
  return Theme.Mark("coin") .. PG.Money(g)
end

-------------------------------------------------------------------------------
-- 1.2 Typography helpers
-------------------------------------------------------------------------------

-- Morpheus display font with Blizzard font-object fallback.
function Theme.SetHeader(fs, size)
  if not fs then return end
  size = size or 16
  local ok, applied = pcall(fs.SetFont, fs, MORPHEUS, size, "")
  if not (ok and applied) then
    local obj = (size >= 20) and GameFontNormalHuge or GameFontNormalLarge
    if obj then pcall(fs.SetFontObject, fs, obj) end
  end
end

-- Standard shadow for text over world/busy art (never for ink-on-parchment).
function Theme.Shadow(fs)
  if not fs then return end
  pcall(fs.SetShadowColor, fs, 0, 0, 0, 0.8)
  pcall(fs.SetShadowOffset, fs, 1, -1)
end

-------------------------------------------------------------------------------
-- 5.9 FX wiring: fx child frame, generation counter, OnHide Stop contract
-------------------------------------------------------------------------------

local coinPool -- forward declaration; global 12-texture pool (built lazily)

-- The synchronous hide path: Stop (never Finish) every registered group, hide
-- every registered FX region, stop the coin pool if this window owns it, and
-- advance the generation counter that invalidates pending Theme timers.
-- No model calls, no sounds, no Show.
local function hideFX(win)
  local groups = win.__pgFXGroups
  if groups then
    for i = 1, #groups do pcall(groups[i].Stop, groups[i]) end
  end
  local regions = win.__pgFXRegions
  if regions then
    for i = 1, #regions do pcall(regions[i].Hide, regions[i]) end
  end
  if coinPool and coinPool.owner == win then
    for i = 1, #coinPool.coins do
      local c = coinPool.coins[i]
      if c.group then pcall(c.group.Stop, c.group) end
      pcall(c.tex.Hide, c.tex)
    end
  end
  if win.__pgFX and win.__pgFX ~= win then
    pcall(win.__pgFX.StopAnimating, win.__pgFX)
  end
  pcall(win.StopAnimating, win)
  win.__pgGen = (win.__pgGen or 0) + 1
end

-- Installs (once) the fx child frame, group/region registries, generation
-- counter, and the OnHide/OnShow wiring on win. Returns the fx frame.
function Theme.EnsureFX(win)
  if win.__pgFX then return win.__pgFX end
  win.__pgGen = win.__pgGen or 0
  win.__pgFXGroups = {}
  win.__pgFXRegions = {}
  local ok, fx = pcall(CreateFrame, "Frame", nil, win)
  if ok and fx then
    fx:SetAllPoints(win)
    pcall(fx.SetFrameLevel, fx, win:GetFrameLevel() + 5)
  else
    fx = win -- degenerate: FX draw on the window itself
  end
  win.__pgFX = fx
  win:HookScript("OnHide", hideFX)
  win:HookScript("OnShow", function(self)
    self.__pgGen = (self.__pgGen or 0) + 1
  end)
  return fx
end

-- Registers an AnimationGroup into win's OnHide Stop list. Use this for any
-- module-built reveal group (glow, starburst, stamps, sparkles) so the Safety
-- hide contract covers it. Returns the group.
function Theme.RegisterGroup(win, group)
  if not group then return group end
  Theme.EnsureFX(win)
  local t = win.__pgFXGroups
  t[#t + 1] = group
  return group
end

-- Registers a texture/frame to be hidden instantly by win's OnHide. Returns it.
function Theme.RegisterRegion(win, region)
  if not region then return region end
  Theme.EnsureFX(win)
  local t = win.__pgFXRegions
  t[#t + 1] = region
  return region
end

-- Generation-checked timer: fn runs only if win's generation is unchanged
-- (no hide/show since scheduling) and win is still shown. The only sanctioned
-- way to schedule FX follow-ups (emote resets, loop stop timers, VO delays).
function Theme.After(win, sec, fn)
  Theme.EnsureFX(win)
  local gen = win.__pgGen
  PG.After(sec, function()
    if win.__pgGen ~= gen then return end
    if not win:IsShown() then return end
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
  end)
end

-------------------------------------------------------------------------------
-- Animation factories: Pop (A1), Pulse (A2)
-------------------------------------------------------------------------------

-- Nearest ancestor (or self) that carries the FX registries.
local function findHost(region)
  local r = region
  for _ = 1, 8 do
    if not r or r == UIParent then return nil end
    if r.__pgFXGroups then return r end
    r = r.GetParent and r:GetParent() or nil
  end
  return nil
end

local function buildPop(frame)
  local g = newGroup(frame)
  if not g then return false end
  local sc = newAnim(g, "Scale")
  if sc then
    setScaleRange(sc, 0.92, 0.92, 1, 1)
    sc:SetDuration(0.18)
    sc:SetOrder(1)
    pcall(sc.SetSmoothing, sc, "OUT")
  end
  local al = newAnim(g, "Alpha")
  if al then
    setAlphaRange(al, 0.6, 1)
    al:SetDuration(0.15)
    al:SetOrder(1)
    pcall(al.SetSmoothing, al, "OUT")
  end
  pcall(g.SetToFinalAlpha, g, true)
  local host = findHost(frame)
  if not host and frame.HookScript then host = frame end
  if host then Theme.RegisterGroup(host, g) end
  return g
end

-- A1 window pop-in. Lazy singleton group per frame; no-op while hidden.
function Theme.Pop(frame)
  if not frame or not frame:IsShown() then return end
  if frame.__pgPop == nil then
    frame.__pgPop = buildPop(frame) or false
  end
  local g = frame.__pgPop
  if not g then return end
  pcall(g.Stop, g)
  restart(g)
end

local function buildPulse(region)
  local g = newGroup(region)
  if not g then return false end
  local down = newAnim(g, "Scale")
  if down then
    setScaleRange(down, 1, 1, 0.94, 0.94)
    down:SetDuration(0.06)
    down:SetOrder(1)
    pcall(down.SetSmoothing, down, "IN")
  end
  local up = newAnim(g, "Scale")
  if up then
    setScaleRange(up, 0.94, 0.94, 1, 1)
    up:SetDuration(0.06)
    up:SetOrder(2)
    pcall(up.SetSmoothing, up, "OUT")
  end
  local host = findHost(region)
  if host then Theme.RegisterGroup(host, g) end
  return g
end

-- A2 micro scale pulse (button lock, chest on pot growth). Doc-enforced rule:
-- never call on the timer bar or on a FontString currently displaying money.
function Theme.Pulse(region)
  if not region or not region:IsVisible() then return end
  if region.__pgPulse == nil then
    region.__pgPulse = buildPulse(region) or false
  end
  local g = region.__pgPulse
  if not g then return end
  pcall(g.Stop, g)
  restart(g)
end

-------------------------------------------------------------------------------
-- 5.5 Banner (A7)
-------------------------------------------------------------------------------

local function buildBanner(parent, themeName)
  local fx = Theme.EnsureFX(parent)
  local ok, b = pcall(CreateFrame, "Frame", nil, fx)
  if not (ok and b) then return nil end
  b:SetSize(260, 42)
  local art = b:CreateTexture(nil, "ARTWORK")
  local textColor
  if themeName == "faire" then
    -- deliberate chalk-bar composition: dark bar, chalk-gold text (rule 6.1)
    art:SetPoint("CENTER")
    art:SetSize(260, 26)
    art:SetColorTexture(COLORS.BOARD[1], COLORS.BOARD[2], COLORS.BOARD[3], 0.9)
    textColor = COLORS.CHGOLD
  else
    if Theme.Tex(art, "ribbon") then
      art:SetAllPoints(b)
    else
      -- ribbon atlas failed: solid GOLD bar 260x26 (color already applied)
      art:SetPoint("CENTER")
      art:SetSize(260, 26)
    end
    textColor = COLORS.INK
  end
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.text:SetPoint("CENTER", 0, 2)
  Theme.SetHeader(b.text, 16)
  pcall(b.text.SetTextColor, b.text, textColor[1], textColor[2], textColor[3])
  Theme.Shadow(b.text) -- banner text always sits on ribbon/bar art
  local g = newGroup(b)
  if g then
    local slide = newAnim(g, "Translation")
    if slide then
      pcall(slide.SetOffset, slide, 40, 0)
      slide:SetDuration(0.25)
      slide:SetOrder(1)
      pcall(slide.SetSmoothing, slide, "OUT")
      -- hold at rest before the fade; kept short so an LG reveal banner
      -- uncovers the status line / roster row it slides in over quickly
      pcall(slide.SetEndDelay, slide, 0.9)
    end
    local fadeIn = newAnim(g, "Alpha")
    if fadeIn then
      setAlphaRange(fadeIn, 0, 1)
      fadeIn:SetDuration(0.2)
      fadeIn:SetOrder(1)
    end
    local fadeOut = newAnim(g, "Alpha")
    if fadeOut then
      setAlphaRange(fadeOut, 1, 0)
      fadeOut:SetDuration(0.3)
      fadeOut:SetOrder(2)
      pcall(fadeOut.SetSmoothing, fadeOut, "IN")
    end
    g:SetScript("OnFinished", function() b:Hide() end)
    Theme.RegisterGroup(parent, g)
  end
  b.group = g
  Theme.RegisterRegion(parent, b)
  b:Hide()
  return b
end

-- One banner per parent, reused. Text is set BEFORE the slide plays and never
-- changes mid-flight (rule 6.2). Returns the frame; plays nothing if parent is
-- not visible.
function Theme.Banner(parent, text, themeName)
  if not parent then return nil end
  local b = parent.__pgBanner
  if b == nil then
    b = buildBanner(parent, themeName)
    parent.__pgBanner = b or false
  end
  if not b then return nil end
  -- re-anchor each play: modules may set __pgBannerSlot after first use.
  -- Anchored 40 px left of rest; the translation slides it +40 to rest.
  b:ClearAllPoints()
  local slot = parent.__pgBannerSlot
  if slot then
    b:SetPoint("TOP", slot, "TOP", -40, 26)
  else
    b:SetPoint("TOP", parent, "TOP", -40, -60)
  end
  if b.text then b.text:SetText(tostring(text or "")) end
  if not parent:IsVisible() then return b end
  if b.group then
    pcall(b.group.Stop, b.group)
    b:Show()
    restart(b.group)
  else
    b:Show()
    Theme.After(parent, 1.5, function() b:Hide() end)
  end
  return b
end

-------------------------------------------------------------------------------
-- 5.6 Stamp (A8). The red text-box slam IS the design; no stamp atlas on 12.1.
-------------------------------------------------------------------------------

local function buildStamp(parent)
  local fx = Theme.EnsureFX(parent)
  local ok, s = pcall(CreateFrame, "Frame", nil, fx)
  if not (ok and s) then return nil end
  s:SetSize(120, 34)
  local c = COLORS.LOSS
  local function edge()
    local t = s:CreateTexture(nil, "BORDER")
    t:SetColorTexture(c[1], c[2], c[3], 0.9)
    return t
  end
  local top = edge()
  top:SetPoint("TOPLEFT")
  top:SetPoint("TOPRIGHT")
  top:SetHeight(2)
  local bottom = edge()
  bottom:SetPoint("BOTTOMLEFT")
  bottom:SetPoint("BOTTOMRIGHT")
  bottom:SetHeight(2)
  local left = edge()
  left:SetPoint("TOPLEFT")
  left:SetPoint("BOTTOMLEFT")
  left:SetWidth(2)
  local right = edge()
  right:SetPoint("TOPRIGHT")
  right:SetPoint("BOTTOMRIGHT")
  right:SetWidth(2)
  s.text = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  s.text:SetPoint("CENTER")
  Theme.SetHeader(s.text, 15)
  pcall(s.text.SetTextColor, s.text, c[1], c[2], c[3])
  local g = newGroup(s)
  if g then
    local sc = newAnim(g, "Scale")
    if sc then
      setScaleRange(sc, 2.0, 2.0, 1, 1)
      sc:SetDuration(0.18)
      sc:SetOrder(1)
      pcall(sc.SetSmoothing, sc, "IN")
      pcall(sc.SetEndDelay, sc, 2.0) -- hold before fading
    end
    local al = newAnim(g, "Alpha")
    if al then
      setAlphaRange(al, 0, 1)
      al:SetDuration(0.12)
      al:SetOrder(1)
    end
    local rot = newAnim(g, "Rotation")
    if rot then
      pcall(rot.SetDegrees, rot, -6)
      rot:SetDuration(0.12)
      rot:SetOrder(1)
      pcall(rot.SetSmoothing, rot, "OUT") -- wobble; not persisted, settles straight
    end
    local fadeOut = newAnim(g, "Alpha")
    if fadeOut then
      setAlphaRange(fadeOut, 1, 0)
      fadeOut:SetDuration(0.4)
      fadeOut:SetOrder(2)
      pcall(fadeOut.SetSmoothing, fadeOut, "IN")
    end
    g:SetScript("OnFinished", function() s:Hide() end)
    Theme.RegisterGroup(parent, g)
  end
  s.group = g
  Theme.RegisterRegion(parent, s)
  s:Hide()
  return s
end

-- One stamp per parent, reused; sized to text +16 px. Plays A8, self-hides.
-- No-op (nothing plays) when parent hidden.
function Theme.Stamp(parent, text)
  if not parent then return nil end
  local s = parent.__pgStamp
  if s == nil then
    s = buildStamp(parent)
    parent.__pgStamp = s or false
  end
  if not s then return nil end
  -- re-anchor each play: modules may set __pgStampSlot after first use
  s:ClearAllPoints()
  local slot = parent.__pgStampSlot
  if slot then
    s:SetPoint("CENTER", slot, "CENTER", 0, 0)
  else
    s:SetPoint("CENTER", parent, "CENTER", 0, 20)
  end
  s.text:SetText(tostring(text or ""))
  local tw, th = 60, 16
  local okW, wv = pcall(s.text.GetStringWidth, s.text)
  if okW and wv and wv > 0 then tw = wv end
  local okH, hv = pcall(s.text.GetStringHeight, s.text)
  if okH and hv and hv > 0 then th = hv end
  s:SetSize(math.max(tw + 16, 60), math.max(th + 16, 28))
  if not parent:IsVisible() then return s end
  if s.group then
    pcall(s.group.Stop, s.group)
    s:Show()
    restart(s.group)
  else
    s:Show()
    Theme.After(parent, 2.5, function() s:Hide() end)
  end
  return s
end

-------------------------------------------------------------------------------
-- 5.10 Coin shower (A5): one global pool of exactly 12 textures, reused
-------------------------------------------------------------------------------

local function buildCoinPool()
  local okF, holder = pcall(CreateFrame, "Frame", nil, UIParent)
  if not (okF and holder) then return nil end
  local pool = { frame = holder, coins = {} }
  for i = 1, 12 do
    local tex = holder:CreateTexture(nil, "OVERLAY")
    tex:SetSize(14, 14)
    if not Theme.Tex(tex, "goldicon") then
      tex:SetSize(8, 8) -- solid gold dot fallback; the shower still reads
    end
    tex:Hide()
    local g = newGroup(tex)
    if g then
      local stagger = 0.05 * i -- per-coin start delay baked in at build
      local path = newAnim(g, "Path")
      if path then
        pcall(path.SetCurveType, path, "SMOOTH")
        path:SetDuration(0.9)
        path:SetOrder(1)
        pcall(path.SetStartDelay, path, stagger)
        -- control points randomized ONCE at pool build (gravity look comes
        -- from the arc, smoothing stays NONE)
        local okc1, cp1 = pcall(path.CreateControlPoint, path)
        if okc1 and cp1 then
          pcall(cp1.SetOffset, cp1, math.random(-90, 90), math.random(55, 105))
        end
        local okc2, cp2 = pcall(path.CreateControlPoint, path)
        if okc2 and cp2 then
          pcall(cp2.SetOffset, cp2, math.random(-130, 130), math.random(-200, -150))
        end
      end
      local rot = newAnim(g, "Rotation")
      if rot then
        pcall(rot.SetDegrees, rot, math.random(-200, 200))
        rot:SetDuration(0.9)
        rot:SetOrder(1)
        pcall(rot.SetStartDelay, rot, stagger)
      end
      local fade = newAnim(g, "Alpha")
      if fade then
        setAlphaRange(fade, 1, 0)
        fade:SetDuration(0.30)
        fade:SetOrder(1)
        pcall(fade.SetStartDelay, fade, 0.60 + stagger)
      end
      g:SetScript("OnFinished", function() tex:Hide() end)
    end
    pool.coins[i] = { tex = tex, group = g }
  end
  return pool
end

-- Coin shower from parent.__pgFXOrigin (Skin/module sets the LG chest) else
-- parent TOP. n clamped to [1,12], default 10. Only one shower at a time:
-- a new call Stop()s and Restart()s the pool. No-op when parent not visible.
function Theme.CoinBurst(parent, n)
  if not parent or not parent:IsVisible() then return end
  n = tonumber(n) or 10
  if n < 1 then n = 1 elseif n > 12 then n = 12 end
  if coinPool == nil then
    coinPool = buildCoinPool() or false
  end
  if not coinPool then return end
  local fx = Theme.EnsureFX(parent)
  local holder = coinPool.frame
  if coinPool.owner ~= parent then
    coinPool.owner = parent
    pcall(holder.SetParent, holder, fx)
    holder:ClearAllPoints()
    holder:SetAllPoints(fx)
  end
  local origin = parent.__pgFXOrigin
  for i = 1, 12 do
    local c = coinPool.coins[i]
    c.tex:ClearAllPoints()
    if origin then
      c.tex:SetPoint("CENTER", origin, "CENTER", 0, 0)
    else
      c.tex:SetPoint("CENTER", parent, "TOP", 0, -24)
    end
  end
  holder:Show()
  for i = 1, 12 do
    local c = coinPool.coins[i]
    if c.group then pcall(c.group.Stop, c.group) end
    if i <= n and c.group then
      c.tex:Show()
      restart(c.group)
    else
      c.tex:Hide()
    end
  end
end

-------------------------------------------------------------------------------
-- 5.10 Sound. The ONLY sound entry point. Default OFF; never in combat, never
-- while any Safety flag (ready check / countdown / encounter / restricted) is
-- set. Result of PlaySound is ignored (never branch on willPlay).
-------------------------------------------------------------------------------

function Theme.Sound(key)
  local id = SOUNDS[key]
  if not id then return end
  if not (PG.db and PG.db.profile and PG.db.profile.sounds) then return end
  if InCombatLockdown() then return end
  local s = PG.Safety and PG.Safety.state
  if s and (s.inCombat or s.inEncounter or s.readyCheck or s.countdown or s.restricted) then
    return
  end
  pcall(PlaySound, id, "SFX", false)
end

-------------------------------------------------------------------------------
-- 5.7 NPC model handle (goblin host / bookie) with static-icon hard fallback
-------------------------------------------------------------------------------

-- Returns { frame = container, ok = bool, model = PlayerModel|nil,
-- Emote = function(self, name) }. Caller sizes/anchors handle.frame.
-- ok == false means the container shows a static icon instead (layout is
-- identical either way; ok is purely a decorative-layout switch).
--
-- ok flips true only from OnModelLoaded: SetDisplayInfo succeeds silently on
-- an unknown/pruned display ID (it loads nothing and never raises), so pcall
-- alone cannot detect the failure. The static icon is created up front as the
-- placeholder and hidden only once a load is confirmed (SKIN.md 2.4.2/5.7).
function Theme.NPC(parent, kind)
  Theme.EnsureFX(parent)
  -- plain unparametrized CreateFrame cannot realistically fail; created
  -- unguarded so handle.frame is NEVER the parent window (callers size and
  -- anchor handle.frame, which must not touch the game window itself)
  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(120, 150)
  local handle = { frame = container, ok = false }
  local icon = Theme.Icon(container, NPC_ICON[kind] or "coinpile", 48)
  icon:SetPoint("CENTER")
  local model
  local okM, m = pcall(CreateFrame, "PlayerModel", nil, container)
  if okM and m then model = m end
  local emoteToken = 0
  if model then
    model:SetAllPoints(container)
    pcall(model.SetKeepModelOnHide, model, true)
    -- the ONLY reliable signal a display ID actually resolved; also poses
    -- (model data arrives async)
    model:SetScript("OnModelLoaded", function(self)
      handle.ok = true
      icon:Hide()
      pcall(self.SetPortraitZoom, self, 0.62)
      pcall(self.SetCamDistanceScale, self, 1.15)
      pcall(self.SetRotation, self, -0.35)
    end)
    local ids = NPC_IDS[kind] or NPC_IDS.host
    local order = { ids[1], ids[2], ids[3] }
    if kind ~= "bookie" and ids[2] and math.random(2) == 2 then
      order[1], order[2] = ids[2], ids[1] -- the host varies between nights
    end
    -- bounded probe chain (at most #order steps): a hard Lua error advances
    -- immediately; a soft failure (no OnModelLoaded) advances after 1.5s via
    -- the gen-checked Theme.After. Exhaustion leaves the icon showing with
    -- handle.ok false. A hide/show mid-probe gen-invalidates the pending
    -- advance timer and stalls the chain with the icon still shown; the
    -- OnShow hook below detects the stall (pendingGen no longer matches the
    -- window generation) and re-arms the interrupted id rather than skipping
    -- it, so an id that was still loading is never abandoned.
    local idx, pendingGen = 0, nil
    local function tryNext()
      if handle.ok then return end
      idx = idx + 1
      local id = order[idx]
      if not id then
        pcall(model.Hide, model)
        return
      end
      if pcall(model.SetDisplayInfo, model, id) then
        Theme.After(parent, 1.5, tryNext)
        pendingGen = parent.__pgGen -- the gen the advance timer will demand
      else
        tryNext()
      end
    end
    tryNext()
    -- A10 "next Show re-idles": a hide during a one-shot emote invalidates
    -- its gen-checked reset timer, which would otherwise leave the sequence
    -- looping forever. Model call on the show path only - the hide path
    -- stays free of model calls. Also re-kicks a probe chain stalled by a
    -- hide (decor: at worst the icon shows until a load confirms).
    container:HookScript("OnShow", function()
      if handle.ok then
        emoteToken = emoteToken + 1 -- invalidate any pending one-shot reset
        pcall(model.SetAnimation, model, 0)
      elseif idx > 0 and parent.__pgGen ~= pendingGen then
        idx = idx - 1 -- retry the id whose probe window was cut short
        tryNext()
      end
    end)
  end
  handle.model = model
  -- npc:Emote(name): no-op if not ok, container hidden, or the model lacks
  -- the animation. One-shots auto-reset to idle via a gen-checked timer;
  -- "talk" loops until Emote("idle"). Never shows/hides anything.
  function handle.Emote(self, name)
    if not self.ok or not model then return end
    if not container:IsVisible() then return end
    local id = EMOTES[name]
    if not id then return end
    local okH, has = pcall(model.HasAnimation, model, id)
    if okH and has == false then return end
    emoteToken = emoteToken + 1
    pcall(model.SetAnimation, model, id)
    local dur = EMOTE_DUR[name]
    if dur then
      local token = emoteToken
      Theme.After(parent, dur, function()
        if token ~= emoteToken then return end
        if not container:IsVisible() then return end
        pcall(model.SetAnimation, model, 0)
      end)
    end
  end
  return handle
end

-------------------------------------------------------------------------------
-- Themed card-face button (SKIN.md 1.3 doctrine / 2.7). Returns nil when the
-- card atlas is unavailable so the caller can fall back to the plain
-- UIPanelButtonTemplate construction (today's look).
-------------------------------------------------------------------------------

function Theme.CardFace(parent, label, w, h)
  if not atlasExists("ui-frame-neutral-cardparchment") then return nil end
  local okB, b = pcall(CreateFrame, "Button", nil, parent)
  if not (okB and b) then return nil end
  b:SetSize(w, h)
  local face = b:CreateTexture(nil, "BACKGROUND")
  face:SetAllPoints()
  if not pcall(face.SetAtlas, face, "ui-frame-neutral-cardparchment", false) then
    b:Hide()
    return nil
  end
  b.face = face
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 0.82, 0, 0.18)
  pcall(hl.SetBlendMode, hl, "ADD")
  pcall(b.SetNormalFontObject, b, GameFontHighlightSmall)
  pcall(b.SetHighlightFontObject, b, GameFontHighlightSmall)
  pcall(b.SetDisabledFontObject, b, GameFontDisableSmall or GameFontHighlightSmall)
  -- disabled visual state: the plain-button fallback grays out via its
  -- template, so the themed face must too (desaturate + dim the parchment)
  b:SetScript("OnDisable", function(self)
    if self.face then
      pcall(self.face.SetDesaturated, self.face, true)
      pcall(self.face.SetAlpha, self.face, 0.55)
    end
  end)
  b:SetScript("OnEnable", function(self)
    if self.face then
      pcall(self.face.SetDesaturated, self.face, false)
      pcall(self.face.SetAlpha, self.face, 1)
    end
  end)
  b:SetText(label or "")
  local okF, fs = pcall(b.GetFontString, b)
  if okF and fs then
    b.text = fs
    local ink = COLORS.INK
    pcall(fs.SetTextColor, fs, ink[1], ink[2], ink[3]) -- dark ink on parchment card
  end
  pcall(b.SetPushedTextOffset, b, 1, -1)
  b.__pgCard = true
  return b
end

-------------------------------------------------------------------------------
-- 2.4.1 Goblin timer-bar skin. Fallback: keep the current UI-StatusBar look.
-- The bar and its text NEVER animate; color constant for the whole round.
-------------------------------------------------------------------------------

function Theme.TimerBar(bar)
  if not bar then return bar end
  local okT, tex = pcall(bar.GetStatusBarTexture, bar)
  local skinned = false
  if okT and tex and atlasExists("lootroll-timer-fill") then
    skinned = pcall(tex.SetAtlas, tex, "lootroll-timer-fill", false)
  end
  if not skinned then return bar end
  pcall(bar.SetStatusBarColor, bar, 1, 0.85, 0.4)
  if atlasExists("lootroll-timer-background") then
    local bg = bar:CreateTexture(nil, "BACKGROUND", nil, 2)
    bg:SetAllPoints()
    pcall(bg.SetAtlas, bg, "lootroll-timer-background", false)
  end
  if atlasExists("lootroll-timer-border") then
    local border = bar:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    pcall(border.SetAtlas, border, "lootroll-timer-border", false)
  end
  return bar
end

-------------------------------------------------------------------------------
-- 5.1 Skin: backdrop + title treatment + FX wiring + pop-on-show.
-- Idempotent; re-calling (even with a different theme) only re-applies the
-- visual treatment - hooks and fx wiring install exactly once.
-------------------------------------------------------------------------------

function Theme.Skin(win, themeName)
  if not win then return win end
  if not BACKDROPS[themeName] then themeName = "neutral" end
  Theme.EnsureFX(win)
  win.__pgTheme = themeName
  if win.SetBackdrop then
    -- SetBackdrop succeeds silently when a file is missing (it would simply
    -- render nothing, replacing the working plain backdrop with a transparent
    -- frame), so gate on file existence - pcall alone cannot see that failure
    local bd = BACKDROPS[themeName]
    local usable = fileExists(bd.bgFile) and fileExists(bd.edgeFile)
    local ok = usable and pcall(win.SetBackdrop, win, bd)
    if ok then
      pcall(win.SetBackdropColor, win, 1, 1, 1, 1)
      local t = BORDER_TINT[themeName]
      pcall(win.SetBackdropBorderColor, win, t[1], t[2], t[3], 1)
    elseif themeName == "faire" then
      -- backdrop unusable: paint the chalkboard directly
      if not win.__pgBoardFallback then
        local tex = win:CreateTexture(nil, "BACKGROUND")
        tex:SetPoint("TOPLEFT", 4, -4)
        tex:SetPoint("BOTTOMRIGHT", -4, 4)
        tex:SetColorTexture(COLORS.BOARD[1], COLORS.BOARD[2], COLORS.BOARD[3], 0.95)
        win.__pgBoardFallback = tex
      end
      win.__pgBoardFallback:Show()
    end
    -- (goblin/neutral backdrop failure: SetBackdrop was never called, so the
    -- plain tooltip backdrop from PG.UI.Window's applyBackdrop remains)
  end
  if themeName == "goblin" then
    if not win.__pgParch then
      local tex = win:CreateTexture(nil, "ARTWORK", nil, -8)
      tex:SetPoint("TOPLEFT", 11, -11)
      tex:SetPoint("BOTTOMRIGHT", -11, 11)
      Theme.Tex(tex, "parchment") -- fail -> solid PARCH (applied by Tex)
      win.__pgParch = tex
    end
    win.__pgParch:Show()
  elseif win.__pgParch then
    win.__pgParch:Hide()
  end
  if win.__pgBoardFallback and themeName ~= "faire" then
    win.__pgBoardFallback:Hide()
  end
  local fs = win.title
  if fs then
    Theme.SetHeader(fs, 20)
    local c = TITLE_COLOR[themeName]
    pcall(fs.SetTextColor, fs, c[1], c[2], c[3])
    if themeName == "faire" then Theme.Shadow(fs) end
  end
  if not win.__pgPopHooked then
    win.__pgPopHooked = true
    win:HookScript("OnShow", function(self) Theme.Pop(self) end)
  end
  return win
end

-------------------------------------------------------------------------------
-- REVEAL.md - the shared results-reveal stage (Theme.Reveal / Theme.RevealQueue)
--
-- ONE lazily built, Safety-registered, full-takeover stage frame, reused
-- forever. Bounded pools (REVEAL.md 5.3): 1 scrim + 4 edges + 2 headline
-- FontStrings + 10 rows + 10 markers + 1 marquee + 12 burst = 32 regions and
-- 31 groups, built exactly once. Nothing is created per event.
--
-- Contracts restated (all enforced below):
--   * any hide (Safety, host hide, our own) runs EnsureFX's synchronous hideFX
--     -- Stop every group, hide every region, StopAnimating, gen bump -- and
--     then this file's bookkeeping hook: reveal-token bump, phase IDLE, active
--     payload dropped, explicit Hide. No Show / sound / model / scheduling on
--     the hide path, and onDone never fires from it.
--   * __pgResume is a FUNCTION returning false, so Core's auto-resume loop
--     never re-shows the stage.
--   * beats are gen-checked (Theme.After) AND token-checked, so Skip can kill
--     pending beats without hiding the stage.
--   * sounds only via Theme.Sound; no loops; no OnUpdate; no new globals.
-------------------------------------------------------------------------------

local RV_ROWS     = 10    -- row/marker pool (hard cap; an 11th row collapses)
local RV_BURSTN   = 12    -- burst pool (hard cap)
local RV_QCAP     = 6     -- queue capacity; a 7th enqueue is dropped
local RV_GAP      = 0.5   -- pump cadence and the breathing gap after a hide
local RV_ROW_TOP  = -128  -- row 1 offset from the stage TOP
local RV_ROW_STEP = -22
local RV_IDLE, RV_PLAYING, RV_HOLD, RV_FADING = 0, 1, 2, 3

-- Row color roles. The ground is always the BOARD scrim, so only dark-safe
-- colors appear here (REVEAL.md 2.3).
local RV_ROLE = {
  body   = COLORS.CHALK,  win    = COLORS.CHGREEN, loss  = COLORS.CHRED,
  fade   = COLORS.CHGRAY, gold   = COLORS.CHGOLD,  silver = COLORS.CHGRAY,
  bronze = COLORS.BRASS,
}
local RV_TITLE_C   = { goblin = COLORS.GOLD, faire = COLORS.CHGOLD }
local RV_MARKER    = { goblin = "coin", faire = "ticket" }
local RV_BURST_ART = { coins = "goldicon", stars = "star", tickets = "ticket" }

local rvStage             -- nil = unbuilt, false = construction failed
local rvQueue = {}
local rvTicker            -- self-cancelling pump; exists only while pending
local rvHooked = false    -- Safety.OnChange installed once, on first enqueue
local rvActive            -- normalized payload currently on the stage
local rvDone              -- its onDone; grabbed-and-cleared so it fires once
local rvSkipped           -- a click influenced this play -> reason "skip"
local rvSettleRow, rvSettleMarquee, rvStartFade, rvResolveFade, rvClick, rvPump

-------------------------------------------------------------------------------
-- Defensive payload readers: a wrong type is "absent" (REVEAL.md 2.3), and a
-- possibly-secret value is never indexed, compared, or concatenated.
-------------------------------------------------------------------------------

local function rvStr(v)
  if PG.IsSecret and PG.IsSecret(v) then return nil end
  if type(v) ~= "string" or v == "" then return nil end
  return v
end

local function rvNum(v)
  if PG.IsSecret and PG.IsSecret(v) then return nil end
  return tonumber(v)
end

-- A frame-like host: anything we can ask IsShown. Never assumes a widget type.
local function rvFrameOf(v)
  if PG.IsSecret and PG.IsSecret(v) then return nil end
  local t = type(v)
  if t ~= "table" and t ~= "userdata" then return nil end
  if type(v.IsShown) ~= "function" then return nil end
  return v
end

-- One normalized display row. File-scope so the row loop below allocates no
-- closure per call (the file's style everywhere else).
local function rvMakeRow(variant, r, txt)
  local place
  if variant == "podium" then
    local pl = rvNum(r.place)
    if pl == 1 or pl == 2 or pl == 3 then place = pl end
  end
  return { text = txt,
           color = RV_ROLE[rvStr(r.role) or ""] or RV_ROLE.body,
           personal = (r.personal and true) or false,
           place = place }
end

-- payload -> normalized private copy, or nil when the call is a silent no-op
-- (not a table / no title / window mode without a usable host). Never errors:
-- every unreadable field simply degrades to its default.
local function rvNormalize(payload)
  if type(payload) ~= "table" then return nil end
  local title = rvStr(payload.title)
  if not title then return nil end
  local p = {}
  p.theme    = (rvStr(payload.theme) == "goblin") and "goblin" or "faire"
  p.variant  = (rvStr(payload.variant) == "podium") and "podium" or "cascade"
  p.title    = title
  p.subtitle = rvStr(payload.subtitle)
  p.marquee  = rvStr(payload.marquee)

  local a = payload.anchor
  if type(a) == "table" and rvStr(a.mode) == "window" then
    p.host = rvFrameOf(a.host)
    if not p.host then return nil end -- declared window mode, no window: drop
  end

  p.burstArt = RV_BURST_ART[rvStr(payload.burst) or ""]
  local n = rvNum(payload.burstCount) or 10
  if p.variant == "podium" then n = RV_BURSTN end
  if n < 1 then n = 1 elseif n > RV_BURSTN then n = RV_BURSTN end
  p.burstCount = math.floor(n)

  p.sound = rvStr(payload.sound)
  p.burstSound = rvStr(payload.burstSound)
  if p.variant == "podium" and not p.burstSound then p.burstSound = "fanfare" end

  local npc = payload.npc
  if type(npc) == "table" and type(npc.Emote) == "function" then
    p.npc = npc
    p.emote = rvStr(payload.emote)
  end
  if type(payload.validate) == "function" then p.validate = payload.validate end
  if type(payload.onDone) == "function" then p.onDone = payload.onDone end
  -- Stage precedence (CONCURRENCY.md 5.8 rule 3): the caller reports whether
  -- this payload belongs to the session the player is actually SEATED in. A
  -- player who plays one game while refereeing another gets their own game's
  -- moment first. 0 = a session we merely run, 1 = the one we are in.
  local pri = rvNum(payload.priority) or 0
  if pri < 0 then pri = 0 elseif pri > 9 then pri = 9 end
  p.priority = math.floor(pri)

  -- Rows: at most 10 lines. More than 10 valid rows keep 1..9 and collapse the
  -- rest into a "... and N more" fade line. The local player's row is the one
  -- row the collapse may not eat (2.3 "personal" is the whole reason the stage
  -- addresses the viewer): when it falls past the cut it is lifted into the
  -- last visible slot. The count on the fade line is total-9 either way, so the
  -- line stays true whether or not a hoist happened.
  local rows, total, mine, spill = {}, 0, false, nil
  local src = payload.rows
  if type(src) == "table" then
    for i = 1, #src do
      local r = src[i]
      if type(r) == "table" then
        local txt = rvStr(r.text)
        if txt then
          total = total + 1
          if #rows < RV_ROWS then
            local rec = rvMakeRow(p.variant, r, txt)
            rows[#rows + 1] = rec
            if rec.personal then
              -- slot 10 is overwritten by the collapse line, so a personal row
              -- landing there still needs the lift
              if #rows < RV_ROWS then mine = true else spill = spill or rec end
            end
          elseif not spill and r.personal then
            spill = rvMakeRow(p.variant, r, txt)
          end
        end
      end
    end
  end
  if total > RV_ROWS then
    if spill and not mine then rows[RV_ROWS - 1] = spill end
    rows[RV_ROWS] = { text = "... and " .. (total - RV_ROWS + 1) .. " more",
                      color = RV_ROLE.fade, personal = false }
  end
  local claimed = {} -- one row per podium place; later claimants are field rows
  for i = 1, #rows do
    local pl = rows[i].place
    if pl then
      if claimed[pl] then rows[i].place = nil else claimed[pl] = true end
    end
  end
  p.rows = rows
  return p
end

-------------------------------------------------------------------------------
-- Stage construction (once, lazily, on the first accepted reveal)
-------------------------------------------------------------------------------

-- Every animation parameter setter is pcall'd; literal numbers/strings only.
local function rvTune(a, dur, order, smoothing, delay)
  if not a then return end
  pcall(a.SetDuration, a, dur)
  pcall(a.SetOrder, a, order)
  pcall(a.SetSmoothing, a, smoothing)
  pcall(a.SetStartDelay, a, delay or 0)
end

local function rvFS(parent, template, header)
  local ok, fs = pcall(parent.CreateFontString, parent, nil, "OVERLAY", template)
  if not (ok and fs) then return nil end
  if header then Theme.SetHeader(fs, header) end
  Theme.Shadow(fs) -- every stage FontString sits on busy/dark art
  pcall(fs.SetJustifyH, fs, "CENTER")
  return fs
end

local function rvBuild()
  local okF, s = pcall(CreateFrame, "Frame", nil, UIParent)
  if not (okF and s) then return false end
  pcall(s.Hide, s) -- CreateFrame returns a shown frame
  pcall(s.SetSize, s, 460, 330)
  pcall(s.SetPoint, s, "CENTER", UIParent, "CENTER", 0, 120)
  pcall(s.SetFrameStrata, s, "DIALOG")
  pcall(s.EnableMouse, s, true) -- skip surface + misclick shield for the window
  local fx = Theme.EnsureFX(s)
  s.__pgRevealPhase = RV_IDLE
  s.__pgRevealToken = 0
  s.__pgRevealHideAt = 0

  -- scrim: the darkened panel IS the stage ground
  local scrim = s:CreateTexture(nil, "BACKGROUND")
  scrim:SetAllPoints(s)
  scrim:SetColorTexture(COLORS.BOARD[1], COLORS.BOARD[2], COLORS.BOARD[3], 1)
  scrim:SetAlpha(0)
  Theme.RegisterRegion(s, scrim)
  s.rvScrim = scrim
  local sg = newGroup(scrim)
  if sg then
    local a = newAnim(sg, "Alpha")
    setAlphaRange(a, 0, 0.85)
    rvTune(a, 0.20, 1, "OUT", 0)
    pcall(sg.SetToFinalAlpha, sg, true)
    sg:SetScript("OnFinished", function() pcall(scrim.SetAlpha, scrim, 0.85) end)
    Theme.RegisterGroup(s, sg)
  end
  s.rvScrimG = sg

  -- edges: border flash that rests at 0.35 as the stage frame
  s.rvEdge, s.rvEdgeG = {}, {}
  for i = 1, 4 do
    local e = s:CreateTexture(nil, "BORDER")
    e:SetAlpha(0)
    if i == 1 then
      e:SetPoint("TOPLEFT", 4, -4); e:SetPoint("TOPRIGHT", -4, -4); e:SetHeight(2)
    elseif i == 2 then
      e:SetPoint("BOTTOMLEFT", 4, 4); e:SetPoint("BOTTOMRIGHT", -4, 4); e:SetHeight(2)
    elseif i == 3 then
      e:SetPoint("TOPLEFT", 4, -4); e:SetPoint("BOTTOMLEFT", 4, 4); e:SetWidth(2)
    else
      e:SetPoint("TOPRIGHT", -4, -4); e:SetPoint("BOTTOMRIGHT", -4, 4); e:SetWidth(2)
    end
    Theme.RegisterRegion(s, e)
    s.rvEdge[i] = e
    local eg = newGroup(e)
    if eg then
      local up = newAnim(eg, "Alpha")
      setAlphaRange(up, 0, 0.9)
      rvTune(up, 0.12, 1, "NONE", 0)
      local down = newAnim(eg, "Alpha")
      setAlphaRange(down, 0.9, 0.35)
      rvTune(down, 0.25, 2, "IN", 0)
      pcall(eg.SetToFinalAlpha, eg, true)
      eg:SetScript("OnFinished", function() pcall(e.SetAlpha, e, 0.35) end)
      Theme.RegisterGroup(s, eg)
    end
    s.rvEdgeG[i] = eg
  end

  -- title: the slam
  local title = rvFS(s, "GameFontNormalHuge", 24)
  s.rvTitle = title
  if title then
    title:SetPoint("TOP", s, "TOP", 0, -56)
    title:SetAlpha(0)
    local tg = newGroup(title)
    if tg then
      local sc = newAnim(tg, "Scale")
      setScaleRange(sc, 2.2, 2.2, 1, 1)
      rvTune(sc, 0.22, 1, "IN", 0)
      local al = newAnim(tg, "Alpha")
      setAlphaRange(al, 0, 1)
      rvTune(al, 0.12, 1, "NONE", 0)
      pcall(tg.SetToFinalAlpha, tg, true)
      tg:SetScript("OnFinished", function() pcall(title.SetAlpha, title, 1) end)
      Theme.RegisterGroup(s, tg)
    end
    s.rvTitleG = tg
  end

  -- subtitle
  local sub = rvFS(s, "GameFontNormal")
  s.rvSub = sub
  if sub then
    sub:SetPoint("TOP", s, "TOP", 0, -92)
    pcall(sub.SetTextColor, sub, COLORS.CHALK[1], COLORS.CHALK[2], COLORS.CHALK[3])
    sub:SetAlpha(0)
    local ug = newGroup(sub)
    if ug then
      local al = newAnim(ug, "Alpha")
      setAlphaRange(al, 0, 1)
      rvTune(al, 0.20, 1, "NONE", 0.15)
      pcall(ug.SetToFinalAlpha, ug, true)
      ug:SetScript("OnFinished", function() pcall(sub.SetAlpha, sub, 1) end)
      Theme.RegisterGroup(s, ug)
    end
    s.rvSubG = ug
  end

  -- rows + personal markers. One group per row (Scale + Alpha + Translation);
  -- the from-scale, offset and start delay are set per play.
  s.rvRow = {}
  for i = 1, RV_ROWS do
    local rec = { slot = i }
    local fs = rvFS(s, "GameFontHighlight")
    rec.fs = fs
    if fs then
      fs:SetPoint("TOP", s, "TOP", 0, RV_ROW_TOP + RV_ROW_STEP * (i - 1))
      fs:SetAlpha(0)
      fs:Hide()
      local mk = s:CreateTexture(nil, "ARTWORK")
      mk:SetSize(16, 16)
      mk:SetPoint("RIGHT", fs, "LEFT", -4, 0)
      mk:Hide()
      Theme.RegisterRegion(s, mk)
      rec.marker = mk
      local rg = newGroup(fs)
      if rg then
        rec.scale = newAnim(rg, "Scale")
        rec.alpha = newAnim(rg, "Alpha")
        rec.move  = newAnim(rg, "Translation")
        pcall(rg.SetToFinalAlpha, rg, true)
        rg:SetScript("OnFinished", function() rvSettleRow(rec) end)
        Theme.RegisterGroup(s, rg)
      end
      rec.g = rg
    end
    s.rvRow[i] = rec
  end

  -- marquee: slides in and STAYS (unlike Banner). Composition per theme is the
  -- buildBanner recipe, re-applied only when the theme changes.
  local okM, mq = pcall(CreateFrame, "Frame", nil, fx)
  if okM and mq then
    mq:SetSize(300, 30)
    mq.art = mq:CreateTexture(nil, "ARTWORK")
    mq.text = mq:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mq.text:SetPoint("CENTER", 0, 2)
    Theme.SetHeader(mq.text, 16)
    Theme.Shadow(mq.text)
    mq:SetAlpha(0)
    mq:Hide()
    Theme.RegisterRegion(s, mq)
    local mg = newGroup(mq)
    if mg then
      local slide = newAnim(mg, "Translation")
      if slide then pcall(slide.SetOffset, slide, 40, 0) end
      rvTune(slide, 0.25, 1, "OUT", 0)
      local al = newAnim(mg, "Alpha")
      setAlphaRange(al, 0, 1)
      rvTune(al, 0.20, 1, "NONE", 0)
      pcall(mg.SetToFinalAlpha, mg, true)
      mg:SetScript("OnFinished", function() rvSettleMarquee() end)
      Theme.RegisterGroup(s, mg)
    end
    s.rvMq, s.rvMqG = mq, mg
  end

  -- burst: the A5 recipe at reveal scale; control points randomized ONCE here
  s.rvBurst = {}
  for i = 1, RV_BURSTN do
    local tex = fx:CreateTexture(nil, "OVERLAY")
    tex:SetSize(14, 14)
    tex:Hide()
    Theme.RegisterRegion(s, tex)
    local bg = newGroup(tex)
    if bg then
      local stagger = 0.04 * i
      local path = newAnim(bg, "Path")
      if path then
        pcall(path.SetCurveType, path, "SMOOTH")
        rvTune(path, 0.9, 1, "NONE", stagger)
        local ok1, cp1 = pcall(path.CreateControlPoint, path)
        if ok1 and cp1 then
          pcall(cp1.SetOffset, cp1, math.random(-110, 110), math.random(60, 120))
        end
        local ok2, cp2 = pcall(path.CreateControlPoint, path)
        if ok2 and cp2 then
          pcall(cp2.SetOffset, cp2, math.random(-160, 160), math.random(-240, -180))
        end
      end
      local rot = newAnim(bg, "Rotation")
      if rot then
        pcall(rot.SetDegrees, rot, math.random(-200, 200))
        rvTune(rot, 0.9, 1, "NONE", stagger)
      end
      local al = newAnim(bg, "Alpha")
      setAlphaRange(al, 1, 0)
      rvTune(al, 0.30, 1, "NONE", 0.60 + stagger)
      bg:SetScript("OnFinished", function() pcall(tex.Hide, tex) end)
      Theme.RegisterGroup(s, bg)
    end
    s.rvBurst[i] = { tex = tex, g = bg }
  end

  -- fade-out of the whole stage
  local fg = newGroup(s)
  if fg then
    local al = newAnim(fg, "Alpha")
    setAlphaRange(al, 1, 0)
    rvTune(al, 0.40, 1, "IN", 0)
    fg:SetScript("OnFinished", function() rvResolveFade() end)
    Theme.RegisterGroup(s, fg)
  end
  s.rvFadeG = fg

  s:SetScript("OnMouseDown", function() rvClick() end)
  -- Teardown bookkeeping, installed AFTER EnsureFX's hideFX so the visual
  -- Stop/hide work has already run. State only: no Show, no sound, no model,
  -- no scheduling, and onDone is never called from here.
  s:HookScript("OnHide", function(self)
    self.__pgRevealToken = (self.__pgRevealToken or 0) + 1
    self.__pgRevealPhase = RV_IDLE
    self.__pgRevealHideAt = (GetTime and GetTime()) or 0
    rvActive, rvDone, rvSkipped = nil, nil, false
    -- essential in window mode: a host hide fires this while our own shown
    -- flag would stay true and a later host:Show() would resurrect the stage
    pcall(self.Hide, self)
  end)
  if PG.Safety and PG.Safety.RegisterWindow then PG.Safety.RegisterWindow(s) end
  -- a FUNCTION returning false: a falsy field would read as "no veto"
  s.__pgResume = function() return false end
  return s
end

local function rvEnsure()
  if rvStage == nil then rvStage = rvBuild() or false end
  return rvStage or nil
end

-------------------------------------------------------------------------------
-- Final state (REVEAL.md 4.4) - skip and natural completion both land here
-------------------------------------------------------------------------------

rvSettleRow = function(rec)
  local s = rvStage
  if not (s and rec and rec.fs) then return end
  pcall(rec.fs.ClearAllPoints, rec.fs)
  pcall(rec.fs.SetPoint, rec.fs, "TOP", s, "TOP", 0,
        RV_ROW_TOP + RV_ROW_STEP * ((rec.slot or 1) - 1))
  pcall(rec.fs.SetAlpha, rec.fs, 1)
  if rec.marker then
    if rec.personal then
      pcall(rec.marker.SetAlpha, rec.marker, 1)
      pcall(rec.marker.Show, rec.marker)
    else
      pcall(rec.marker.Hide, rec.marker)
    end
  end
end

rvSettleMarquee = function()
  local s = rvStage
  if not (s and s.rvMq) then return end
  local mq = s.rvMq
  pcall(mq.ClearAllPoints, mq)
  pcall(mq.SetPoint, mq, "TOP", s, "TOP", 0, s.rvMqY or -140)
  pcall(mq.SetAlpha, mq, 1)
end

local function rvApplyFinal()
  local s = rvStage
  if not s then return end
  pcall(s.SetAlpha, s, 1)
  if s.rvScrim then pcall(s.rvScrim.SetAlpha, s.rvScrim, 0.85) end
  for i = 1, 4 do
    local e = s.rvEdge[i]
    if e then pcall(e.SetAlpha, e, 0.35) end
  end
  if s.rvTitle then pcall(s.rvTitle.SetAlpha, s.rvTitle, 1) end
  if s.rvSub and s.rvSubUsed then pcall(s.rvSub.SetAlpha, s.rvSub, 1) end
  for i = 1, RV_ROWS do
    local rec = s.rvRow[i]
    if rec and rec.used then rvSettleRow(rec) end
  end
  if s.rvMqUsed then rvSettleMarquee() end
  for i = 1, RV_BURSTN do
    local b = s.rvBurst[i]
    if b and b.tex then pcall(b.tex.Hide, b.tex) end
  end
end

-- Stop (never Finish) every group the stage owns. The stage is the only owner
-- of its FX registry, so the registry IS the reveal's group list.
local function rvStopGroups()
  local s = rvStage
  local t = s and s.__pgFXGroups
  if not t then return end
  for i = 1, #t do pcall(t[i].Stop, t[i]) end
end

-- Gen-checked (Theme.After refuses after a hide/show) AND token-checked, so a
-- Skip kills every pending beat without hiding the stage.
local function rvBeat(tok, t, fn)
  local s = rvStage
  if not s then return end
  Theme.After(s, t, function()
    if s.__pgRevealToken ~= tok then return end
    fn()
  end)
end

rvResolveFade = function()
  local s = rvStage
  if not s then return end
  -- Stop() can fire OnFinished, so hideFX's teardown loop may land here from
  -- the hide path. An aborted reveal must never resolve: no onDone, and
  -- nothing scheduled from a hide. A hidden or host-hidden stage is not
  -- visible; the natural fade and the click paths both are.
  local okV, vis = pcall(s.IsVisible, s)
  if not (okV and vis) then return end
  local fn = rvDone
  local reason = rvSkipped and "skip" or "done"
  rvDone = nil -- grabbed-and-cleared: onDone fires exactly once, and an abort
               -- (which clears it from the hide hook) can never fire it
  s.__pgRevealPhase = RV_IDLE
  pcall(s.SetAlpha, s, 1)
  pcall(s.Hide, s)
  if fn then
    PG.After(0, function()
      local ok, err = pcall(fn, reason)
      if not ok and PG.debug then geterrorhandler()(err) end
    end)
  end
end

rvStartFade = function()
  local s = rvStage
  if not s then return end
  s.__pgRevealPhase = RV_FADING
  -- The NPC lives in the host window UNDERNEATH the 0.85 scrim, so an emote
  -- played at t=0.20 was invisible and over before the stage cleared. He plays
  -- it as the scrim starts to fade instead - exactly once per play, on the
  -- natural and the skip path alike (never from the hide path, which does no
  -- model calls: nothing there reaches this function).
  local a = rvActive
  if a and a.npc and a.emote and not a.emoted then
    a.emoted = true
    pcall(a.npc.Emote, a.npc, a.emote)
  end
  local g = s.rvFadeG
  if not g then
    rvResolveFade() -- no fade group ever built: end it now (REVEAL.md 5.5)
    return
  end
  pcall(g.Stop, g)
  restart(g)
  -- net for a group that refuses to play: end the stage anyway
  rvBeat(s.__pgRevealToken, 0.6, function()
    if s.__pgRevealPhase == RV_FADING then rvResolveFade() end
  end)
end

-- Click anywhere on the stage: PLAYING -> HOLD -> FADING -> IDLE (4.3)
rvClick = function()
  local s = rvStage
  if not s then return end
  local phase = s.__pgRevealPhase
  if phase == RV_PLAYING then
    s.__pgRevealToken = (s.__pgRevealToken or 0) + 1
    rvSkipped = true
    rvStopGroups()
    rvApplyFinal()
    s.__pgRevealPhase = RV_HOLD
    rvBeat(s.__pgRevealToken, 1.2, function() rvStartFade() end)
  elseif phase == RV_HOLD then
    s.__pgRevealToken = (s.__pgRevealToken or 0) + 1 -- kill the natural fade beat
    rvSkipped = true
    rvStartFade()
  elseif phase == RV_FADING then
    rvSkipped = true
    if s.rvFadeG then pcall(s.rvFadeG.Stop, s.rvFadeG) end
    rvResolveFade()
  end
end

-------------------------------------------------------------------------------
-- Play: all text and static properties set BEFORE Show, then the beats
-------------------------------------------------------------------------------

-- Screen mode is mouse-enabled and swallows every click over its rect for the
-- whole 4.6 s play, so it must not land on a game window: an LG/RPS window is
-- centred by default and its SHARE/HOARD (or card) row sits exactly where the
-- design anchor puts the stage. REVEAL.md 3 keeps the stage out of the overlap
-- solver, so it yields by hand here instead - the design anchor first, then
-- offsets that clear every shown factory window, and the design anchor anyway
-- when nothing is free (the information must show; a drain refusal could
-- starve the payload for a whole session).
local RV_SCREEN_Y = { 120, 240, -160, 40, -260 }

local function rvScreenY(w, h, sc)
  if not (PG.UI and PG.UI.RectFree) then return 120 end
  local okS, sw = pcall(UIParent.GetWidth, UIParent)
  local okH, sh = pcall(UIParent.GetHeight, UIParent)
  if not (okS and okH and type(sw) == "number" and type(sh) == "number") then
    return 120
  end
  local ew, eh = w * sc, h * sc -- the stage's rect in UIParent space
  if not (sw > ew and sh > eh) then return 120 end
  local l = (sw - ew) / 2
  local lo, hi = (eh - sh) / 2, (sh - eh) / 2 -- stay fully on screen
  for i = 1, #RV_SCREEN_Y do
    -- SetPoint offsets ride the frame's own scale, so the candidate is scaled
    -- for the rect test and returned unscaled for the anchor
    local off = RV_SCREEN_Y[i] * sc
    if off >= lo and off <= hi
       and PG.UI.RectFree(l, (sh - eh) / 2 + off, ew, eh) then
      return RV_SCREEN_Y[i]
    end
  end
  return 120
end

local function rvPlay(p)
  local s = rvEnsure()
  if not s then return end
  local n = #p.rows
  local podium = (p.variant == "podium")

  -- anchor / size
  local w = 460
  pcall(s.SetFrameStrata, s, "DIALOG")
  if p.host then
    local okW, hw = pcall(p.host.GetWidth, p.host)
    if okW and type(hw) == "number" and hw > 200 then w = hw end
    pcall(s.SetScale, s, 1) -- as a child of the host, its scale already applies
    pcall(s.SetParent, s, p.host)
    pcall(s.ClearAllPoints, s)
    pcall(s.SetAllPoints, s, p.host)
    local okL, lvl = pcall(p.host.GetFrameLevel, p.host)
    if okL and type(lvl) == "number" then pcall(s.SetFrameLevel, s, lvl + 40) end
  else
    local h = 330
    local need = 152 + 22 * n + (p.marquee and 54 or 0)
    if need > h then h = need end
    -- a UIParent child now, so it carries the profile scale every other PG
    -- surface does, and a modest level: window mode leaves it at host+40, which
    -- would otherwise keep it above later DIALOG popups and eat their clicks
    local sc = (PG.db and PG.db.profile and tonumber(PG.db.profile.scale)) or 1
    if not (sc > 0) then sc = 1 end
    pcall(s.SetParent, s, UIParent)
    pcall(s.ClearAllPoints, s)
    pcall(s.SetSize, s, w, h)
    pcall(s.SetScale, s, sc)
    pcall(s.SetFrameLevel, s, 20)
    pcall(s.SetPoint, s, "CENTER", UIParent, "CENTER", 0, rvScreenY(w, h, sc))
  end

  -- scrim + edges
  if s.rvScrim then
    pcall(s.rvScrim.Show, s.rvScrim)
    pcall(s.rvScrim.SetAlpha, s.rvScrim, s.rvScrimG and 0 or 0.85)
  end
  local ec = RV_TITLE_C[p.theme]
  for i = 1, 4 do
    local e = s.rvEdge[i]
    if e then
      pcall(e.SetColorTexture, e, ec[1], ec[2], ec[3], 1)
      pcall(e.Show, e)
      pcall(e.SetAlpha, e, s.rvEdgeG[i] and 0 or 0.35)
    end
  end

  -- title + subtitle
  if s.rvTitle then
    pcall(s.rvTitle.SetText, s.rvTitle, p.title)
    pcall(s.rvTitle.SetTextColor, s.rvTitle, ec[1], ec[2], ec[3])
    pcall(s.rvTitle.SetWidth, s.rvTitle, w - 48)
    pcall(s.rvTitle.SetAlpha, s.rvTitle, s.rvTitleG and 0 or 1)
    pcall(s.rvTitle.Show, s.rvTitle)
  end
  s.rvSubUsed = false
  if s.rvSub then
    if p.subtitle then
      s.rvSubUsed = true
      pcall(s.rvSub.SetText, s.rvSub, p.subtitle)
      pcall(s.rvSub.SetWidth, s.rvSub, w - 48)
      pcall(s.rvSub.SetAlpha, s.rvSub, s.rvSubG and 0 or 1)
      pcall(s.rvSub.Show, s.rvSub)
    else
      pcall(s.rvSub.Hide, s.rvSub)
    end
  end

  -- rows: text, color, composition, pre-play offset
  local markerKey = RV_MARKER[p.theme]
  local field = 0
  for i = 1, RV_ROWS do
    local rec = s.rvRow[i]
    local row = p.rows[i]
    rec.used, rec.personal, rec.place, rec.slot = false, false, nil, i
    if rec.fs then
      if not row then
        pcall(rec.fs.Hide, rec.fs)
        if rec.marker then pcall(rec.marker.Hide, rec.marker) end
      else
        rec.used = true
        rec.personal = row.personal
        rec.place = row.place
        pcall(rec.fs.SetText, rec.fs, row.text)
        pcall(rec.fs.SetTextColor, rec.fs, row.color[1], row.color[2], row.color[3])
        pcall(rec.fs.SetWidth, rec.fs, w - 64)
        pcall(rec.fs.Show, rec.fs)
        local fromScale, sDur, aDur, dy, delay = 1.25, 0.16, 0.12, 0, 0
        if podium then
          if row.place == 1 then
            fromScale, sDur, aDur, dy = 1.8, 0.26, 0.12, 18
          elseif row.place then
            fromScale, sDur, aDur, dy = 1.25, 0.22, 0.15, 14
          else
            field = field + 1
            fromScale, sDur, aDur = 1.15, 0.12, 0.10
            delay = 0.08 * (field - 1)
            -- the local player's row keeps its pop even among field rows; a
            -- placed row instead keeps the medal composition above
            if row.personal then fromScale, sDur, aDur = 1.6, 0.20, 0.12 end
          end
        else
          delay = 0.12 * (i - 1)
          if row.personal then fromScale, sDur = 1.6, 0.20 end
        end
        -- rows that rise start dy px below rest; the group's OnFinished
        -- re-anchors them at rest (translations do not persist)
        pcall(rec.fs.ClearAllPoints, rec.fs)
        pcall(rec.fs.SetPoint, rec.fs, "TOP", s, "TOP", 0,
              RV_ROW_TOP + RV_ROW_STEP * (i - 1) - dy)
        setScaleRange(rec.scale, fromScale, fromScale, 1, 1)
        rvTune(rec.scale, sDur, 1, "OUT", delay)
        setAlphaRange(rec.alpha, 0, 1)
        rvTune(rec.alpha, aDur, 1, "NONE", delay)
        if rec.move then
          pcall(rec.move.SetOffset, rec.move, 0, dy)
          rvTune(rec.move, (dy > 0) and sDur or 0.01, 1, "OUT", delay)
        end
        -- personal marker: art failure hides it (the row color and the big pop
        -- carry the emphasis); it appears when the row lands
        local personal = false
        if rec.marker then
          pcall(rec.marker.Hide, rec.marker)
          if row.personal and markerKey then
            personal = Theme.Tex(rec.marker, markerKey)
            pcall(rec.marker.ClearAllPoints, rec.marker)
            local okS, sw = pcall(rec.fs.GetStringWidth, rec.fs)
            if okS and type(sw) == "number" and sw > 0 and sw < (w - 64) then
              -- rows are centered inside a full-width FontString: keep the
              -- marker beside the glyphs, not out at the layout box edge
              pcall(rec.marker.SetPoint, rec.marker, "RIGHT", rec.fs, "CENTER",
                    -(sw / 2) - 4, 0)
            else
              pcall(rec.marker.SetPoint, rec.marker, "RIGHT", rec.fs, "LEFT", -4, 0)
            end
          end
        end
        rec.personal = personal
        if rec.g then
          pcall(rec.fs.SetAlpha, rec.fs, 0)
        else
          rvSettleRow(rec) -- no group: this row is static at final state
        end
      end
    end
  end

  -- marquee
  s.rvMqUsed = false
  if s.rvMq then
    local mq = s.rvMq
    if p.marquee then
      s.rvMqUsed = true
      s.rvMqY = RV_ROW_TOP + RV_ROW_STEP * n - 12
      if s.rvMqTheme ~= p.theme then
        s.rvMqTheme = p.theme
        local art = mq.art
        pcall(art.ClearAllPoints, art)
        mq.artFull = false -- art sized per play below unless it fills the frame
        if p.theme == "goblin" then
          if Theme.Tex(art, "ribbon") then
            pcall(art.SetAllPoints, art, mq)
            mq.artFull = true -- the ribbon stretches with the frame
          else
            pcall(art.SetPoint, art, "CENTER") -- ribbon failed: solid gold bar
          end
          pcall(mq.text.SetTextColor, mq.text, COLORS.INK[1], COLORS.INK[2], COLORS.INK[3])
        else
          pcall(art.SetPoint, art, "CENTER")
          pcall(art.SetColorTexture, art, COLORS.BOARD[1], COLORS.BOARD[2],
                COLORS.BOARD[3], 0.9)
          pcall(mq.text.SetTextColor, mq.text, COLORS.CHGOLD[1], COLORS.CHGOLD[2],
                COLORS.CHGOLD[3])
        end
      end
      -- The ribbon is 300 px of art under a FontString with no width cap, so a
      -- long line used to spill its INK text off the art and onto the near-
      -- black scrim (SKIN.md: INK never sits on the scrim). Measure the string
      -- unbound, grow the ribbon to it up to the stage width, then cap the text
      -- so anything still too long truncates ON the ribbon.
      pcall(mq.text.SetWordWrap, mq.text, false)
      pcall(mq.text.SetWidth, mq.text, 0)
      pcall(mq.text.SetText, mq.text, p.marquee)
      local mqW = 300
      local okT, tw = pcall(mq.text.GetStringWidth, mq.text)
      if okT and type(tw) == "number" and tw > 0 then
        mqW = math.max(300, math.min(w - 40, tw + 24))
      end
      pcall(mq.SetSize, mq, mqW, 30)
      pcall(mq.text.SetWidth, mq.text, mqW - 24)
      if not mq.artFull then pcall(mq.art.SetSize, mq.art, mqW, 26) end
      pcall(mq.ClearAllPoints, mq)
      pcall(mq.SetPoint, mq, "TOP", s, "TOP", s.rvMqG and -40 or 0, s.rvMqY)
      pcall(mq.SetAlpha, mq, s.rvMqG and 0 or 1)
      pcall(mq.Show, mq)
    else
      pcall(mq.Hide, mq)
    end
  end

  -- burst textures: art re-keyed only when the type changes
  if p.burstArt and s.rvBurstKey ~= p.burstArt then
    s.rvBurstKey = p.burstArt
    for i = 1, RV_BURSTN do
      local tex = s.rvBurst[i].tex
      if Theme.Tex(tex, p.burstArt) then
        pcall(tex.SetSize, tex, 14, 14)
      else
        pcall(tex.SetSize, tex, 8, 8) -- solid dot fallback; the burst still reads
      end
    end
  end
  for i = 1, RV_BURSTN do
    local tex = s.rvBurst[i].tex
    pcall(tex.ClearAllPoints, tex)
    pcall(tex.SetPoint, tex, "CENTER", s, "TOP", 0, -90)
    pcall(tex.SetAlpha, tex, 1)
    pcall(tex.Hide, tex)
  end

  -- everything is readable from frame one; now play
  rvActive, rvDone, rvSkipped = p, p.onDone, false
  pcall(s.SetAlpha, s, 1)
  pcall(s.Show, s)
  s.__pgRevealToken = (s.__pgRevealToken or 0) + 1
  s.__pgRevealPhase = RV_PLAYING
  local tok = s.__pgRevealToken

  restart(s.rvScrimG)
  for i = 1, 4 do restart(s.rvEdgeG[i]) end
  rvBeat(tok, 0.10, function()
    restart(s.rvTitleG)
    if s.rvSubUsed then restart(s.rvSubG) end
    Theme.Sound(p.sound)
  end)
  -- the NPC emote rides the fade beat (see rvStartFade), not a beat here: under
  -- the scrim there is nothing to see
  rvBeat(tok, 0.35, function()
    for i = 1, RV_ROWS do
      local rec = s.rvRow[i]
      if rec.used and rec.g and not (podium and rec.place) then restart(rec.g) end
    end
  end)
  if podium then
    local placeAt = { 1.90, 1.40, 1.00 } -- gold, silver, bronze
    for i = 1, RV_ROWS do
      local rec = s.rvRow[i]
      if rec.used and rec.g and rec.place then
        rvBeat(tok, placeAt[rec.place], function() restart(rec.g) end)
      end
    end
  end
  if s.rvMqUsed then
    rvBeat(tok, podium and 2.20 or 1.70, function() restart(s.rvMqG) end)
  end
  rvBeat(tok, podium and 2.00 or 1.90, function()
    if p.burstArt then
      for i = 1, p.burstCount do
        local b = s.rvBurst[i]
        if b.g then
          pcall(b.tex.Show, b.tex)
          restart(b.g)
        end
      end
    end
    Theme.Sound(p.burstSound)
  end)
  -- Burst particle i lives stagger(0.04*i) + 0.90 s, so the last of 12 lands at
  -- burst + 1.38. The hold must start AFTER that (REVEAL.md 0.9: transients
  -- never overlap the hold) - rvApplyFinal hides every burst texture
  -- unconditionally, and at 2.90/3.00 it was yanking the last particles off the
  -- screen at full alpha, mid-arc.
  rvBeat(tok, podium and 3.40 or 3.30, function()
    s.__pgRevealPhase = RV_HOLD
    rvApplyFinal() -- the hold state is the design: everything at full alpha
  end)
  rvBeat(tok, podium and 4.40 or 4.20, function() rvStartFade() end)
end

-------------------------------------------------------------------------------
-- Gates, queue, public API
-------------------------------------------------------------------------------

-- All five Safety flags clear (REVEAL.md 0.3): a full-takeover scrim is never
-- acceptable while anything raid-critical is happening, plain combat included.
local function rvCanNow()
  local st = PG.Safety and PG.Safety.state
  if not st then return true end
  return not (st.inCombat or st.inEncounter or st.readyCheck or st.countdown
              or st.restricted)
end

local function rvIdle()
  return (not rvStage) or rvStage.__pgRevealPhase == RV_IDLE
end

-- Drain-time checks: staleness, the host window, and DND for screen mode.
local function rvDrainOK(p)
  if p.validate then
    local ok, res = pcall(p.validate)
    if not (ok and res) then return false end
  end
  if p.host then
    local ok, shown = pcall(p.host.IsShown, p.host)
    if not (ok and shown) then return false end
  elseif PG.IsDND and PG.IsDND() then
    return false
  end
  return true
end

rvPump = function()
  if not rvQueue[1] then
    if rvTicker then
      pcall(rvTicker.Cancel, rvTicker)
      rvTicker = nil
    end
    return
  end
  if not (rvIdle() and rvCanNow()) then return end
  if rvStage then
    local now = (GetTime and GetTime()) or 0
    -- a breathing gap after the previous reveal (REVEAL.md 5.4)
    if (now - (rvStage.__pgRevealHideAt or 0)) < RV_GAP then return end
  end
  for _ = 1, RV_QCAP do
    local p = table.remove(rvQueue, 1)
    if not p then return end
    if rvDrainOK(p) then
      rvPlay(p)
      return
    end
  end
end

-- Installed once, on the first reveal of either kind. Two jobs:
--   * any "_OFF" trigger pumps the queue (the Ask deferred-show precedent);
--   * COMBAT_ON tears the stage down. Plain combat deliberately does not hide
--     the game windows any more, but rvCanNow already refuses to START a
--     takeover in combat - so a stage that opened a second before the pull
--     must not ride a mouse-blocking scrim into it either.
local function rvHook()
  if rvHooked then return end
  rvHooked = true
  if not (PG.Safety and PG.Safety.OnChange) then return end
  PG.Safety.OnChange(function(_, trigger)
    if type(trigger) ~= "string" then return end
    if trigger == "COMBAT_ON" then
      if rvStage and rvStage.__pgRevealPhase ~= RV_IDLE then
        pcall(rvStage.Hide, rvStage) -- instant teardown via the OnHide chain
      end
      return
    end
    if trigger:find("_OFF", 1, true) then rvPump() end
  end)
end

local function rvDoReveal(payload)
  local p = rvNormalize(payload)
  if not p then return end
  if not (rvIdle() and rvCanNow()) then return end
  if not rvDrainOK(p) then return end
  rvHook()
  rvPlay(p)
end

local function rvDoQueue(payload)
  local p = rvNormalize(payload)
  if not p then return end
  if #rvQueue >= RV_QCAP then return end -- newest loses; the info lives in text
  -- Precedence at DRAIN time, never preemption: a payload already playing is
  -- never torn down (the text behind it is final and the beats are timed), but
  -- a seated session's podium queues AHEAD of a refereed one's. Insertion is
  -- stable among equal priorities, so same-rank payloads keep FIFO order.
  local at = #rvQueue + 1
  for i = 1, #rvQueue do
    if (rvQueue[i].priority or 0) < p.priority then
      at = i
      break
    end
  end
  table.insert(rvQueue, at, p)
  rvHook()
  if not rvTicker then rvTicker = PG.Ticker(RV_GAP, rvPump) end
  rvPump()
end

-- Play the reveal NOW if possible (stage idle, Safety clear, host shown, not
-- stale); otherwise drop it silently. For per-round moments, where the next
-- round supersedes a missed one. Returns nothing; never errors.
function Theme.Reveal(payload)
  local ok, err = pcall(rvDoReveal, payload)
  if not ok and PG.debug then geterrorhandler()(err) end
end

-- Append to the reveal queue and pump. FIFO, one at a time, only while
-- Safety-clear and idle. For must-eventually-show moments (podiums,
-- settlements). Returns nothing; never errors.
function Theme.RevealQueue(payload)
  local ok, err = pcall(rvDoQueue, payload)
  if not ok and PG.debug then geterrorhandler()(err) end
end
