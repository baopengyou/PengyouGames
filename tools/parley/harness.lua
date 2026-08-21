-- Shared harness for Games/MythicParley.lua.
--
-- The module's file scope only defines things and registers an init callback,
-- and its init hands onMessage to PG.Comm.Register - so a stub Comm captures
-- the wire handler and the whole game can be driven from outside with no client
-- at all. Each "client" is a SEPARATE load of the file against a separate PG
-- table, which is what makes the two-client convergence test mean anything.
--
-- Two stubs are load-bearing and were both wrong first time round, so they are
-- called out here:
--
--   UnitFullName MUST answer per unit token. inGroupNow() walks raid1..raidN,
--   so a stub returning one constant name rejects every sender but yourself,
--   silently drops every party-scope BET, and makes a correct module look dead.
--
--   The Encounter Journal stubs decide whether per-boss lines exist at all. The
--   SEVENTH return of EJ_GetEncounterInfoByIndex is dungeonEncounterID - the
--   number ENCOUNTER_END reports - and not journalEncounterID, which is the
--   journal's own key and matches nothing.

local H = {}

H.clock = 1000.0
H.ME = nil

_G.GetTime = function() return H.clock end
_G.time = function() return 1755000000 end
_G.strsplit = function(sep, str)
  local out, start = {}, 1
  while true do
    local i = str:find(sep, start, true)
    if not i then out[#out + 1] = str:sub(start) break end
    out[#out + 1] = str:sub(start, i - 1)
    start = i + #sep
  end
  return unpack(out)
end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.geterrorhandler = function() return function(e) error(e, 0) end end
_G.GetNormalizedRealmName = function() return "R" end
_G.UnitExists = function(u) return u ~= nil end
_G.UnitGUID = function(u) return "GUID-" .. tostring(u) end
_G.UnitGroupRolesAssigned = function(u)
  if u == "raid1" then return "TANK" elseif u == "raid2" then return "HEALER" end
  return "DAMAGER"
end
_G.issecretvalue = nil

H.RAID = { "Ann", "Bob", "Cid", "Dot", "Eve" }
_G.UnitFullName = function(unit)
  if unit == "player" or unit == nil then return (H.ME:match("^([^-]+)")), "R" end
  local i = tonumber(tostring(unit):match("^raid(%d+)$"))
    or tonumber(tostring(unit):match("^party(%d+)$"))
  if i and H.RAID[i] then return H.RAID[i], "R" end
  return nil
end
_G.IsInRaid = function() return true end
_G.IsInGroup = function() return true end
_G.GetNumGroupMembers = function() return #H.RAID end

_G.GameTooltip = { SetOwner = function() end, AddLine = function() end,
                   Show = function() end, Hide = function() end }

-------------------------------------------------------------------------------
-- The dungeon world
-------------------------------------------------------------------------------

H.MAPS = {
  [391] = { name = "Ara-Kara, City of Echoes", limit = 1980, ej = 101 },
  [392] = { name = "The Dawnbreaker",          limit = 2100, ej = 102 },
}
H.ENCOUNTERS = {
  [101] = { { 2926, "Avanoxx" }, { 2906, "Anub'zekt" }, { 2900, "Ki'katal the Harvester" } },
  [102] = { { 2837, "Speaker Shadowcrown" }, { 2838, "Anub'ikkaj" }, { 2839, "Rasha'nan" } },
}
H.keyActive = nil
H.slotted = nil
H.completion = nil
H.deaths = 0

_G.C_ChallengeMode = {
  GetMapTable = function() return { 391, 392 } end,
  GetMapUIInfo = function(id)
    local m = H.MAPS[id]
    if not m then return nil end
    return m.name, id, m.limit
  end,
  GetActiveChallengeMapID = function() return H.keyActive end,
  GetSlottedKeystoneInfo = function() return H.slotted end,
  GetActiveKeystoneInfo = function() return H.keyActive and 12 or nil end,
  GetDeathCount = function() return H.deaths, 0 end,
  GetCompletionInfo = function()
    local c = H.completion
    if not c then return nil end
    return c.map, c.level, c.ms, c.onTime, 1
  end,
}

H.ejTier = 1
_G.EJ_GetNumTiers = function() return 2 end
_G.EJ_GetCurrentTier = function() return H.ejTier end
_G.EJ_SelectTier = function(t) H.ejTier = t end
_G.EJ_GetInstanceByIndex = function(i, isRaid)
  if isRaid then return nil end
  local byTier = { [1] = { 101 }, [2] = { 102 } }
  local id = (byTier[H.ejTier] or {})[i]
  if not id then return nil end
  for mapId, m in pairs(H.MAPS) do
    if m.ej == id then return id, m.name end
  end
  return id, "?"
end
_G.EJ_GetEncounterInfoByIndex = function(i, instanceID)
  local list = H.ENCOUNTERS[instanceID]
  if not (list and list[i]) then return nil end
  -- name, description, journalEncounterID, rootSectionID, link,
  -- journalInstanceID, dungeonEncounterID, instanceID
  return list[i][2], "d", 9000 + i, 1, "l", instanceID, list[i][1], instanceID
end

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------

-- The catch-all must synthesise METHODS ONLY. Returning a function for every
-- unknown key means a plain data read - frame.__pgCard, self.h - comes back as
-- a function, which is truthy and arithmetic-hostile, and the resulting error
-- looks like a module bug rather than a harness one. WoW's API is uppercase-
-- initial for methods and the addon's own fields are not, which is a clean
-- enough line to draw.
local function mockFrame()
  local f = { shown = false }
  return setmetatable(f, { __index = function(t, k)
    if not tostring(k):match("^%u") then return nil end
    local fn
    if k == "IsShown" then fn = function(s) return s.shown end
    elseif k == "Show" then fn = function(s) s.shown = true end
    elseif k == "Hide" then fn = function(s) s.shown = false end
    elseif k == "SetShown" then fn = function(s, v) s.shown = (v and true) or false end
    elseif k == "GetText" then fn = function(s) return rawget(s, "text") end
    elseif k == "SetText" then fn = function(s, v) s.text = v end
    elseif k == "GetChecked" then fn = function(s) return rawget(s, "checked") end
    elseif k == "SetChecked" then fn = function(s, v) s.checked = (v and true) or false end
    elseif k == "GetWidth" then fn = function() return 520 end
    elseif k == "GetHeight" then fn = function(s) return rawget(s, "h") or 620 end
    elseif k == "SetHeight" then fn = function(s, v) s.h = v end
    elseif k == "CreateFontString" or k == "CreateTexture" then
      fn = function() return mockFrame() end
    elseif k == "SetScrollChild" then fn = function(s2, c) s2.child = c end
    elseif k == "Get" then fn = function() return "group" end
    elseif k == "SetScript" then fn = function(s, ev, f2) s["__" .. ev] = f2 end
    else fn = function() return nil end end
    rawset(t, k, fn); return fn
  end })
end
H.mockFrame = mockFrame

-- Every frame the module builds is recorded in creation order, so a test can
-- reach the card builder's checkboxes and click them the way a player would -
-- through the module's own OnClick, not by poking its private tables. Reset
-- H.created immediately before the call you want to observe.
H.created = {}
_G.CreateFrame = function(kind, _, parent, template)
  local f = mockFrame()
  f.__template = template
  H.created[#H.created + 1] = { kind = kind, frame = f, template = template }
  return f
end

-- The CheckButtons the module built, in creation order - which is the order
-- availableLines() lists the card's rows in.
function H.checkboxes()
  local out = {}
  for _, e in ipairs(H.created) do
    if e.kind == "CheckButton" then out[#out + 1] = e.frame end
  end
  return out
end

-- The one ScrollFrame the card builder makes, so a test can ask how tall its
-- child actually is.
function H.scrollFrame()
  for _, e in ipairs(H.created) do
    if e.kind == "ScrollFrame" then return e.frame end
  end
end

-- The card list is a FIXED POOL of rows, shown and hidden rather than created
-- per refresh (nothing churns during combat). So counting the checkboxes that
-- exist counts the pool - always 25 - and the question a test actually wants is
-- how many are OFFERED.
function H.shownChecks()
  local out = {}
  for _, b in ipairs(H.checkboxes()) do
    if rawget(b, "shown") then out[#out + 1] = b end
  end
  return out
end

-- UICheckButtonTemplate toggles its own state BEFORE OnClick fires, so a test
-- that only called the handler would be testing the opposite of what a click
-- does.
function H.clickCheck(box)
  box:SetChecked(not rawget(box, "checked"))
  local fn = rawget(box, "__OnClick")
  if fn then fn(box) end
end

-------------------------------------------------------------------------------
-- One independent instance of the module
-------------------------------------------------------------------------------

function H.newClient(root, name)
  local PG, inits = {}, {}
  local C = { name = name, PG = PG, commits = {}, sent = {}, after = {},
              events = {}, toasts = {}, buttons = {}, checks = {} }

  function PG.RegisterInit(fn) inits[#inits + 1] = fn end
  function PG.RegisterEvent(ev, fn)
    C.events[ev] = C.events[ev] or {}
    table.insert(C.events[ev], fn)
    return true
  end
  function PG.After(_, fn) table.insert(C.after, fn) end
  function PG.Ticker(_, fn) C.tick = fn; return { Cancel = function() C.tick = nil end } end
  function PG.IsDND() return false end
  function PG.NextToken() C.tokN = (C.tokN or 0) + 1; return "tk-" .. C.tokN end
  PG.db = { profile = { seq = 0, scope = {} } }

  PG.Safety = { state = { inCombat = false, inEncounter = false, readyCheck = false,
                          countdown = false, restricted = false } }
  function PG.Safety.OnChange(fn) C.safety = fn end
  function PG.Safety.HidBy() return false end

  PG.Comm = {}
  function PG.Comm.Register(_, h, d) C.handler = h; C.drop = d end
  function PG.Comm.RegisterTrust() end
  function PG.Comm.Locked() return C.locked == true end
  function PG.Comm.ScopeAvailable(s) return s == "group" or s == "guild" end
  function PG.Comm.ScopeCode(s) return ({ group = "P", guild = "G" })[s] end
  function PG.Comm.ScopeOfCode(c) return ({ P = "group", G = "guild" })[c] end
  function PG.Comm.Broadcast(_, _, mtype, ...)
    if C.locked then
      if C.drop then C.drop(mtype, (...)) end
      return false
    end
    C.sent[#C.sent + 1] = { mtype = mtype, f = { ... } }
    return true
  end
  function PG.Comm.BroadcastEx(o, _, mtype, ...)
    if C.locked then
      if C.drop then C.drop(mtype, (...)) end
      return false
    end
    C.sent[#C.sent + 1] = { mtype = mtype, f = { ... } }
    if o and o.onSent then o.onSent() end
    return true
  end
  function PG.Comm.Whisper() return true end

  PG.UI = {}
  function PG.UI.Toast(t) C.toasts[#C.toasts + 1] = t; return true end
  function PG.UI.ToastPending() return 0, false end
  function PG.UI.Dismiss() return false end
  function PG.UI.GuildAskOK() return true end
  function PG.UI.GuildAskSpend() end
  function PG.UI.Ask(k, _, _, _, _, acc) C.ask = { key = k, accept = acc }; return true end
  function PG.UI.ClockAgo() return "21:47" end
  function PG.UI.SetTitle() end
  function PG.UI.OnClose() end
  function PG.UI.Window() local f = mockFrame(); f.closeBtn = mockFrame(); return f end
  function PG.UI.Button(_, label, _, _, onClick)
    local b = mockFrame()
    b.click = onClick
    C.buttons[#C.buttons + 1] = { label = tostring(label or ""), click = onClick }
    return b
  end
  function PG.UI.CardButton(_, label, _, _, onClick)
    local b = mockFrame()
    b.click = onClick
    return b
  end
  function PG.UI.ScopePicker() return mockFrame() end
  function PG.UI.FitLabel(b) return b end

  PG.Ledger = {}
  function PG.Ledger.Commit(meta, rows)
    local copy, sum, n = {}, 0, 0
    for k, v in pairs(rows) do copy[k] = v; sum = sum + v; n = n + 1 end
    C.commits[#C.commits + 1] = { meta = meta, rows = copy, sum = sum, n = n }
    return true
  end

  PG.Launcher = {}
  function PG.Launcher.AddOpenGame() return true end
  function PG.Launcher.RemoveOpenGame() return true end

  assert(loadfile(root .. "/PengyouGames/Util.lua"))("PengyouGames", PG)
  assert(loadfile(root .. "/PengyouGames/Games/MythicParley.lua"))("PengyouGames", PG)
  for i = 1, #inits do inits[i]() end
  C.MP = PG.MP
  return C
end

-------------------------------------------------------------------------------
-- Driving one client
-------------------------------------------------------------------------------

function H.recv(C, ...) local p = H.ME; H.ME = C.name; C.handler(...); H.ME = p end

function H.fire(C, ev, ...)
  local p = H.ME; H.ME = C.name
  for _, fn in ipairs(C.events[ev] or {}) do fn(ev, ...) end
  H.ME = p
end

function H.drain(C)
  local p, q = H.ME, C.after
  H.ME = C.name; C.after = {}
  for i = 1, #q do q[i]() end
  H.ME = p
end

function H.tick(C, n)
  local p = H.ME; H.ME = C.name
  for _ = 1, (n or 1) do H.clock = H.clock + 0.5; if C.tick then C.tick() end end
  H.ME = p
end

function H.press(C, needle)
  for _, b in ipairs(C.buttons) do
    if b.label:find(needle, 1, true) and b.click then
      local p = H.ME; H.ME = C.name; b.click(); H.ME = p
      return true
    end
  end
  return false
end

function H.safety(C, trigger, field)
  local p = H.ME; H.ME = C.name
  if field then C.PG.Safety.state[field] = true end
  if C.safety then C.safety(C.PG.Safety.state, trigger) end
  H.ME = p
end

function H.sentOf(C, mtype)
  for _, m in ipairs(C.sent) do if m.mtype == mtype then return m end end
end

function H.countSent(C, mtype)
  local n = 0
  for _, m in ipairs(C.sent) do if m.mtype == mtype then n = n + 1 end end
  return n
end

function H.byIndex(C)
  local out = {}
  for _, c in ipairs(C.commits) do
    out[tonumber(c.meta.id:match("(%d+)$"))] = c
  end
  return out
end

function H.fingerprint(C)
  local ids = {}
  for i = 1, #C.commits do
    local parts = {}
    for n, d in pairs(C.commits[i].rows) do parts[#parts + 1] = n .. "=" .. d end
    table.sort(parts)
    ids[#ids + 1] = C.commits[i].meta.id .. " {" .. table.concat(parts, ",") .. "}"
  end
  table.sort(ids)
  return table.concat(ids, "\n")
end

-------------------------------------------------------------------------------
-- Assertions
-------------------------------------------------------------------------------

H.pass, H.fail = 0, 0

function H.check(name, cond, detail)
  if cond then
    H.pass = H.pass + 1
    print("  ok   " .. name)
  else
    H.fail = H.fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

function H.done()
  print()
  print(string.format("%d passed, %d failed", H.pass, H.fail))
  os.exit(H.fail == 0 and 0 or 1)
end

return H
