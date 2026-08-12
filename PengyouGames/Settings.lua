-- Settings.lua - the settings window: sounds, DND, minimap, scale, layout.
local ADDON, PG = ...

PG.Settings = {}

local win
local syncers = {} -- one per checkbox: re-reads its source into the display

local function build()
  -- 320x460, not SCOPE.md 5.6's 320x420: that budget does not close once the
  -- section header and the (three-line at this width) channel note are given
  -- real space - the -164 checkbox would start 4px below the one at -134, and
  -- the note would run into the slider. Only the point and the per-window scale
  -- are persisted (never the size), so growing it is safe for existing users.
  win = PG.UI.Window("settings", "Settings", 320, 460, "neutral")

  -- checkbox helper (UICheckButtonTemplate: stable since vanilla). OnShow
  -- re-reads its source so the window always reflects reality (DND can also
  -- be toggled from the launcher sign, the minimap button, or /pg dnd);
  -- PG.Settings.Refresh re-syncs while the window is already open.
  local function check(label, y, get, set)
    local cb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", 24, y)
    cb.label = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb:SetScript("OnShow", function(self) self:SetChecked(get() and true or false) end)
    syncers[#syncers + 1] = function() cb:SetChecked(get() and true or false) end
    return cb
  end

  check("Sounds", -44,
    function() return PG.db.profile.sounds end,
    function(v) PG.db.profile.sounds = v end)

  check("Do Not Disturb (no popups or toasts)", -74,
    PG.IsDND,
    function(v)
      if PG.IsDND() ~= v then PG.ToggleDND() end
    end)

  check("Minimap button", -104,
    function()
      local m = PG.db.profile.minimap
      return not (m and m.hide)
    end,
    function(v)
      if PG.Launcher and PG.Launcher.SetMinimapShown then
        PG.Launcher.SetMinimapShown(v)
      end
    end)

  check("Hide game windows while in combat", -134,
    function() return PG.db.profile.hideInCombat end,
    function(v) PG.db.profile.hideInCombat = v end)

  -----------------------------------------------------------------------------
  -- Games from outside your group (SCOPE.md 5.6). Both checkboxes go through
  -- the local check() helper, so each gets its syncers entry and its OnShow
  -- re-read for free and PG.Settings.Refresh keeps them honest.
  -----------------------------------------------------------------------------

  local scopeHdr = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  scopeHdr:SetPoint("TOPLEFT", 24, -166)
  scopeHdr:SetText("Games from outside your group")
  scopeHdr:SetTextColor(0.80, 0.68, 0.42) -- BRASS

  check("Guild games: show me invites", -190,
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

  check("Public games: join the public channel", -220,
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
      -- an open Loot Goblins / RPS dialog repaints its Public segment at once
      if PG.UI and PG.UI.RefreshScopePickers then PG.UI.RefreshScopePickers() end
    end)

  local scopeNote = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  scopeNote:SetPoint("TOPLEFT", 24, -250)
  scopeNote:SetPoint("TOPRIGHT", -20, -250)
  scopeNote:SetJustifyH("LEFT")
  scopeNote:SetHeight(48) -- three or four wrapped lines at this width
  scopeNote:SetWordWrap(true)
  scopeNote:SetText("Public uses a hidden chat channel. It takes one of your ten "
    .. "channel slots and shows up in the Chat Channels list - nothing is ever "
    .. "printed to your chat windows.")
  scopeNote:SetTextColor(0.80, 0.68, 0.42) -- BRASS

  -- window scale slider. OptionsSliderTemplate keys its Low/High/Text regions
  -- off the frame name, so this is one of our two deliberately named frames
  -- (the other is the minimap button).
  local slider = CreateFrame("Slider", "PengyouGamesScaleSlider", win, "OptionsSliderTemplate")
  slider:SetPoint("TOP", 0, -310)
  slider:SetSize(240, 17)
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
  slider:SetScript("OnShow", function(self)
    local v = (PG.db and PG.db.profile.scale) or 1
    self.__pgSyncing = true
    self:SetValue(v)
    self.__pgSyncing = nil
    labelScale(v)
  end)
  local sliderHint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sliderHint:SetPoint("TOP", slider, "BOTTOM", 0, -6)
  sliderHint:SetText("Windows also resize individually via their corner grip")
  sliderHint:SetTextColor(0.66, 0.66, 0.61)

  local resetBtn = PG.UI.Button(win, "Reset window layout", 200, 24, function()
    if PG.UI.ResetLayout then PG.UI.ResetLayout() end
    PG.UI.Toast("Window layout reset.")
  end)
  resetBtn:SetPoint("TOP", 0, -368)

  local note = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  note:SetPoint("BOTTOM", 0, 20)
  note:SetPoint("LEFT", 20, 0)
  note:SetPoint("RIGHT", -20, 0)
  note:SetJustifyH("CENTER")
  note:SetWordWrap(true)
  note:SetText("Sounds only ever play out of combat, never during a countdown.")
  note:SetTextColor(0.80, 0.68, 0.42) -- BRASS
end

function PG.Settings.Show()
  if not win then build() end
  win:Show()
end

-- Re-sync every checkbox to reality while the window is open (called after
-- out-of-window toggles: launcher sign, minimap right-click, /pg dnd,
-- /pg minimap). No-op before the window is ever built or while hidden.
function PG.Settings.Refresh()
  if win and win:IsShown() then
    for i = 1, #syncers do syncers[i]() end
  end
end
