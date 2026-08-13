-- Settings.lua - the settings window: sounds, DND, minimap, scale, layout.
--
-- ONE left column, ONE type ramp, ONE set of gaps. Everything on this page is
-- either a field label or body copy, so by the centring policy every string
-- here is LEFT-aligned inside the shared inset and the page has no centred
-- element at all - only the button's own label, which the button centres.
-- Before this pass the page ran two alignment systems at once (checkboxes,
-- header and channel note at TOPLEFT 24; slider, reset button and footer note
-- centred at TOP 0). It read as "roughly aligned" at 320 wide and would have
-- split visibly the moment the page was widened.
--
-- The vertical rhythm is ANCHORED, not absolute: every element hangs off the
-- one above it with one of the shared METRIC gaps. That is what fixes the
-- channel note vs slider-label collision - the note used to clear the label by
-- half a pixel with a hardcoded SetHeight(48), and overlapped it outright
-- whenever it wrapped to a fourth line, because nothing below it was anchored
-- to it and the layout could not self-correct in either direction.
local ADDON, PG = ...

PG.Settings = {}

-- 420x548 is the shell's content slot. The page WAS 320 wide, and every
-- element on it already derives from this pair (CONTENT_W, the bound label
-- widths, the slider) plus an anchor chain, so widening it is one constant and
-- no re-layout - which is exactly what the left-column pass bought.
local WIN_W, WIN_H = 420, 548

local win
local syncers = {} -- one per checkbox: re-reads its source into the display
local sliderSync   -- set in build(); the page's OnShow value sync

-- The shared spacing grid, with the shipped literals as the fallback so this
-- file still lays out sanely on a client where the theme layer failed to load.
local function metrics()
  local M = PG.Theme and PG.Theme.METRIC
  local top = ((M and M.TITLE_TOP) or -12)
  local titleH = ((M and M.TITLE_H) or 24)
  return {
    INSET   = (M and M.INSET) or 24,
    FIRST   = top - titleH - ((M and M.TITLE_GAP) or 20), -- title -> first element
    SECTION = (M and M.SECTION) or 16,
    RELATED = (M and M.RELATED) or 8,
    FOOTER  = (M and M.FOOTER) or 16,
    BTN_W   = (M and M.BTN_PRI_W) or 150,
    BTN_H   = (M and M.BTN_PRI_H) or 26,
  }
end

-- One role -> one colour, from the board ramp. Colour, not size, carries the
-- heading/caption distinction here: before this pass the section header and the
-- fine print were the same BRASS and only two points of size apart.
local function role(name, r, g, b)
  local R = PG.Theme and PG.Theme.ROLE
  local c = R and R[name]
  if c then return c[1], c[2], c[3] end
  return r, g, b
end

local function fontOf(which)
  if PG.Theme and PG.Theme.FontTemplate then return PG.Theme.FontTemplate(which) end
  return "GameFontHighlight"
end

-- SETTINGS IS A PAGE NOW, not a window. `win` is the page frame the shell
-- hands in; everything below is the shipped layout with two numbers moved: the
-- page is the slot's full 420 wide, and the first element sits at the page's
-- own top padding instead of clearing a title bar that is no longer there.
local function build(pageFrame)
  win = pageFrame
  if not win then return end

  local M = metrics()
  M.FIRST = win.__pgTop or M.FIRST
  local CONTENT_W = WIN_W - M.INSET * 2
  local CB = 26                       -- UICheckButtonTemplate box
  local LABEL_X = CB + 4              -- label sits one gap right of the box
  local prev                          -- the element the next one hangs off

  -- checkbox helper (UICheckButtonTemplate: stable since vanilla). OnShow
  -- re-reads its source so the window always reflects reality (DND can also
  -- be toggled from the launcher sign, the minimap button, or /pg dnd);
  -- PG.Settings.Refresh re-syncs while the window is already open.
  --
  -- The label is BOUND now. It had no width, no wrap policy and no ellipsis,
  -- so its only overflow mode was "runs through the window border into empty
  -- screen"; bound, an over-long or localised label truncates on the page.
  local function check(label, anchor, gap, get, set)
    local cb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    cb:SetSize(CB, CB)
    if anchor then
      cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
    else
      cb:SetPoint("TOPLEFT", M.INSET, M.FIRST)
    end
    cb.label = win:CreateFontString(nil, "OVERLAY", fontOf("B"))
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetWidth(CONTENT_W - LABEL_X)
    cb.label:SetJustifyH("LEFT")
    cb.label:SetWordWrap(false)
    cb.label:SetMaxLines(1)
    cb.label:SetText(label)
    cb.label:SetTextColor(role("body", 0.95, 0.93, 0.87))
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb:SetScript("OnShow", function(self) self:SetChecked(get() and true or false) end)
    syncers[#syncers + 1] = function() cb:SetChecked(get() and true or false) end
    prev = cb
    return cb
  end

  check("Sounds", nil, 0,
    function() return PG.db.profile.sounds end,
    function(v) PG.db.profile.sounds = v end)

  check("Do Not Disturb (no popups or toasts)", prev, M.RELATED,
    PG.IsDND,
    function(v)
      if PG.IsDND() ~= v then PG.ToggleDND() end
    end)

  check("Minimap button", prev, M.RELATED,
    function()
      local m = PG.db.profile.minimap
      return not (m and m.hide)
    end,
    function(v)
      if PG.Launcher and PG.Launcher.SetMinimapShown then
        PG.Launcher.SetMinimapShown(v)
      end
    end)

  check("Hide game windows while in combat", prev, M.RELATED,
    function() return PG.db.profile.hideInCombat end,
    function(v) PG.db.profile.hideInCombat = v end)

  -----------------------------------------------------------------------------
  -- Games from outside your group (SCOPE.md 5.6). Both checkboxes go through
  -- the local check() helper, so each gets its syncers entry and its OnShow
  -- re-read for free and PG.Settings.Refresh keeps them honest.
  --
  -- The heading binds to what FOLLOWS it: a section gap above, a related gap
  -- below. It used to be the other way round (6px above, 10px below), which
  -- glued every heading to the block it was meant to be separating from.
  -----------------------------------------------------------------------------

  local scopeHdr = win:CreateFontString(nil, "OVERLAY", fontOf("T"))
  scopeHdr:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -M.SECTION)
  scopeHdr:SetWidth(CONTENT_W)
  scopeHdr:SetJustifyH("LEFT")
  scopeHdr:SetWordWrap(false)
  scopeHdr:SetMaxLines(1)
  scopeHdr:SetText("Games from outside your group")
  scopeHdr:SetTextColor(role("title", 1.00, 0.85, 0.46))
  prev = scopeHdr

  check("Guild games: show me invites", prev, M.RELATED,
    function()
      -- default ON, matching Comm's guildScopeOn()
      local p = PG.db and PG.db.profile
      local si = p and p.scopeIn
      if type(si) ~= "table" then return true end
      return si.guild ~= false
    end,
    function(v)
      local p = PG.db and PG.db.profile
      if not p then return end
      if type(p.scopeIn) ~= "table" then p.scopeIn = {} end
      p.scopeIn.guild = v and true or false
    end)

  check("Public games: join the public channel", prev, M.RELATED,
    function()
      local p = PG.db and PG.db.profile
      return (p and p.publicOptIn) and true or false
    end,
    function(v)
      local p = PG.db and PG.db.profile
      if not p then return end
      p.publicOptIn = v and true or false
      if PG.Comm then
        if v then
          if PG.Comm.PublicJoin then PG.Comm.PublicJoin() end
        elseif PG.Comm.PublicLeave then
          -- a live public session needs no new abort entry point: the opt-in is
          -- the first test inside ScopeAvailable("public"), so the host-abort
          -- watchdog tears the session down on its next tick and clients fall
          -- to the host-death watchdog once accept() starts dropping the HBs
          PG.Comm.PublicLeave()
        end
      end
      -- Every open start dialog repaints its Public segment at once. This is a
      -- broadcast to the picker registry rather than a list of dialogs on
      -- purpose: at 1.1.0 there are six start dialogs, three of which never
      -- offer Public at all, and a picker self-registers when it is built - so
      -- nothing here has to know which games exist.
      if PG.UI and PG.UI.RefreshScopePickers then PG.UI.RefreshScopePickers() end
    end)

  -- No SetHeight: a FontString with a bound width sizes its own height, and
  -- everything below hangs off that height. Three lines at 320 wide, two in a
  -- wider slot, four if a word breaks badly - the slider moves either way.
  local scopeNote = win:CreateFontString(nil, "OVERLAY", fontOf("S"))
  scopeNote:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -M.SECTION)
  scopeNote:SetWidth(CONTENT_W)
  scopeNote:SetJustifyH("LEFT")
  scopeNote:SetWordWrap(true)
  scopeNote:SetText("Public uses a hidden chat channel. It takes one of your ten "
    .. "channel slots and shows up in the Chat Channels list - nothing is ever "
    .. "printed to your chat windows.")
  scopeNote:SetTextColor(role("muted", 0.66, 0.66, 0.61))

  -- window scale slider. OptionsSliderTemplate keys its Low/High/Text regions
  -- off the frame name, so this is one of our two deliberately named frames
  -- (the other is the minimap button).
  --
  -- 28px below the note: the template hangs its "Window scale: N%" label in the
  -- 12.5px band directly ABOVE the slider's top edge, so the gap has to clear
  -- the label, not the slider. That band is exactly what the old fixed -310
  -- anchor put half a pixel under the note.
  local slider = CreateFrame("Slider", "PengyouGamesScaleSlider", win, "OptionsSliderTemplate")
  slider:SetPoint("TOPLEFT", scopeNote, "BOTTOMLEFT", 0, -28)
  slider:SetSize(CONTENT_W, 17)
  slider:SetMinMaxValues(0.6, 1.6)
  slider:SetValueStep(0.05)
  slider:SetObeyStepOnDrag(true)
  local lowFS = _G["PengyouGamesScaleSliderLow"]
  local highFS = _G["PengyouGamesScaleSliderHigh"]
  local textFS = _G["PengyouGamesScaleSliderText"]
  if lowFS then lowFS:SetText("60%") end
  if highFS then highFS:SetText("160%") end
  local function labelScale(v)
    if textFS then textFS:SetText("Window scale: " .. math.floor(v * 100 + 0.5) .. "%") end
  end
  slider:SetScript("OnValueChanged", function(self, v)
    labelScale(v)
    -- OnShow programmatically syncs the slider to the stored value; only a
    -- USER change may apply (else merely opening settings would wipe the
    -- per-window grip sizes ApplyGlobalScale deliberately clears)
    if self.__pgSyncing then return end
    if PG.UI.ApplyGlobalScale then PG.UI.ApplyGlobalScale(v) end
  end)
  -- The page's onShow drives this too. Whether hiding an ancestor fires
  -- OnShow/OnHide on a shown descendant is exactly the sort of thing that
  -- differs by build, and the shell's page contract promises onShow on every
  -- appearance - so the sync is a named function, called from both.
  sliderSync = function()
    local v = (PG.db and PG.db.profile.scale) or 1
    slider.__pgSyncing = true
    slider:SetValue(v)
    slider.__pgSyncing = nil
    labelScale(v)
  end
  slider:SetScript("OnShow", sliderSync)

  -- 20 below the slider, not 6: the template's 60% / 160% labels hang in the
  -- 15.5px band under the slider, and at -6 the hint's ascenders ran straight
  -- through them.
  local sliderHint = win:CreateFontString(nil, "OVERLAY", fontOf("S"))
  sliderHint:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -20)
  sliderHint:SetWidth(CONTENT_W)
  sliderHint:SetJustifyH("LEFT")
  sliderHint:SetWordWrap(true)
  sliderHint:SetText("Windows also resize individually via their corner grip")
  sliderHint:SetTextColor(role("muted", 0.66, 0.66, 0.61))

  local resetBtn = PG.UI.Button(win, "Reset window layout", M.BTN_W, M.BTN_H, function()
    if PG.UI.ResetLayout then PG.UI.ResetLayout() end
    PG.UI.Toast("Window layout reset.")
  end)
  resetBtn:SetPoint("TOPLEFT", sliderHint, "BOTTOMLEFT", 0, -M.SECTION)

  -- BOTTOMLEFT/BOTTOMRIGHT, not BOTTOM + LEFT + RIGHT. That triple was the only
  -- one of its shape in the addon and it stated two conflicting y constraints
  -- (bottom edge -504, derived centre -260); if the resolver had ever preferred
  -- the derived centre this sentence would have landed on a checkbox.
  local note = win:CreateFontString(nil, "OVERLAY", fontOf("S"))
  note:SetPoint("BOTTOMLEFT", M.INSET, M.FOOTER)
  note:SetPoint("BOTTOMRIGHT", -M.INSET, M.FOOTER)
  note:SetJustifyH("LEFT")
  note:SetWordWrap(true)
  note:SetText("Sounds only ever play out of combat, never during a countdown.")
  note:SetTextColor(role("muted", 0.66, 0.66, 0.61))
end

-- Every checkbox re-reads its source, and the slider re-reads the stored
-- scale. Called on every appearance of the page, and by PG.Settings.Refresh.
local function syncAll()
  for i = 1, #syncers do syncers[i]() end
  if sliderSync then sliderSync() end
end

-- Unchanged signature: /pg settings and the shell's nav both call it. It
-- focuses the shell's Settings page instead of opening a window.
function PG.Settings.Show()
  local S = PG.UI and PG.UI.Shell
  if S then S.Focus("settings") end
end

-- Re-sync every control to reality while the page is on screen (called after
-- out-of-page toggles: the footer sign, minimap right-click, /pg dnd,
-- /pg minimap). IsVisible, not IsShown: the page frame is "shown" whenever it
-- is the selected page, including while the whole shell is hidden.
function PG.Settings.Refresh()
  if win and win:IsVisible() then syncAll() end
end

PG.RegisterInit(function()
  if not (PG.UI and PG.UI.Shell) then return end
  PG.UI.Shell.RegisterPage("settings", {
    build = build,
    onShow = function() syncAll() end,
  })
end)
