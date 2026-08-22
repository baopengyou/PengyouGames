-- tools/ibshim.lua -- headless two-client drive of Games/IdleBattle.lua.
-- M5 part 1 wrote it against the stub surface; M5 part 2 promoted it here and
-- extended the WoW/PG stubs to cover the REAL BOARD's API surface. It stubs
-- the WoW API + the PG platform surface the module consumes, joins module
-- instances over an in-memory Comm bus, and drives the FULL lifecycle through
-- the board's own widgets (never through private module state):
--
--   phase 0  /pgd ib selftest (the committed hand-log goldens, headless)
--   phase A  sync bus: host -> OPEN -> lite -> invitation -> join ->
--            handshake -> play; slot-square geometry asserted on BOTH
--            clients (the side-2 client is the mirror proof), the no-fog
--            label, a cost tooltip read from Rules, the queued-order ghost,
--            unit-stack markers on the correct halves, then a CONCEDE (the
--            V row) ending both sides with no result.
--   phase B  the two void paths part 1 proved, re-proved over the board:
--            lockdown voids one side, 35 s of silence voids the other.
--   phase C  a LOSSY / DELAYING / REORDERING / DUPLICATING bus: a COMPLETE
--            match to its end -- every unit kind and every first-playable
--            building letter issued through the board by BOTH clients
--            (letters DISCOVERED from the hashed catalogue, never listed),
--            late atoms forcing rollbacks through the bridge, zero settled
--            hash mismatches, both terminal sims bit-identical (stateHash,
--            logDigest, winner, reason, tick), per-client traffic under the
--            M5 milestone's 32 messages/min, and the reveal payloads built
--            by the result path captured and cross-checked.
--
-- Endpoints are captured by wrapping PG.IBEngine's Net.new per client (the
-- harness owns the platform surface; the module is untouched). Exits
-- non-zero on any failure.
--
-- Usage: lua ibshim.lua <repo-root>

local root = ...
assert(root, "usage: lua ibshim.lua <repo-root>")
local addon = root .. "/dev/PengyouGamesDev"

-- ---------------------------------------------------------------------------
-- shared WoW globals
-- ---------------------------------------------------------------------------

local now = 1000.0            -- the fake GetTime()
function GetTime() return now end
function GetTimePreciseSec() return now end

function strsplit(sep, s)
  local out = {}
  for piece in string.gmatch(s .. sep, "([^" .. sep .. "]*)" .. sep) do out[#out + 1] = piece end
  return (table.unpack or unpack)(out)
end

local chatSink = function(text) print("  [chat] " .. tostring(text)) end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) chatSink(text) end }

local failures = {}
local function fail(msg)
  failures[#failures + 1] = msg
  print("  [FAIL] " .. msg)
end

function geterrorhandler()
  return function(err) fail("handler error: " .. tostring(err)) end
end

GameTooltip = { lines = {} }
function GameTooltip:SetOwner() self.lines = {} end
function GameTooltip:AddLine(text) self.lines[#self.lines + 1] = tostring(text or "") end
function GameTooltip:Show() end
function GameTooltip:Hide() end

-- Frames: enough surface for the board (child frames, textures, fontstrings,
-- levels, points). Parent chains are recorded so a frame can be attributed to
-- the client whose window it hangs under.
local frames = {}
function CreateFrame(kind, name, parent)
  local f = { kind = kind, parent = parent, shown = true, scripts = {},
              level = (parent and parent.level or 0) + 1, strings = {} }
  function f:SetScript(ev, fn) self.scripts[ev] = fn end
  function f:HookScript(ev, fn)
    local old = self.scripts[ev]
    self.scripts[ev] = function(...)
      if old then old(...) end
      fn(...)
    end
  end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  function f:IsVisible()
    local p = self
    while p do
      if not p.shown then return false end
      p = p.parent
    end
    return true
  end
  function f:SetSize(w, h) self.w, self.h = w, h end
  function f:SetWidth(w) self.w = w end
  function f:SetHeight(h) self.h = h end
  function f:GetWidth() return self.w or 0 end
  function f:GetHeight() return self.h or 0 end
  function f:SetPoint(point, a, b)
    if type(a) == "number" then self.x, self.y = a, b end
    self.point = point
  end
  function f:ClearAllPoints() end
  function f:SetAllPoints() end
  function f:SetFrameLevel(n) self.level = n end
  function f:GetFrameLevel() return self.level end
  function f:SetFrameStrata() end
  function f:SetAlpha(a) self.alpha = a end
  function f:EnableMouse() end
  function f:CreateFontString()
    local s = { text = "" }
    function s:SetPoint() end
    function s:ClearAllPoints() end
    function s:SetText(t) self.text = tostring(t or "") end
    function s:GetText() return self.text end
    function s:SetJustifyH() end
    function s:SetJustifyV() end
    function s:SetWordWrap() end
    function s:SetTextColor() end
    function s:SetWidth() end
    function s:SetHeight() end
    function s:SetAlpha() end
    function s:Show() self.hidden = false end
    function s:Hide() self.hidden = true end
    f.strings[#f.strings + 1] = s
    return s
  end
  function f:CreateTexture()
    local t = {}
    function t:SetColorTexture() end
    function t:SetPoint() end
    function t:ClearAllPoints() end
    function t:SetAllPoints() end
    function t:SetSize() end
    function t:SetWidth() end
    function t:SetHeight() end
    function t:SetAlpha() end
    function t:Show() t.hidden = false end
    function t:Hide() t.hidden = true end
    return t
  end
  frames[#frames + 1] = f
  return f
end

-- drive every shown frame's OnUpdate once (the WoW frame loop); the handlers
-- are closures over their own module instance, so a global drive is exact.
local function fireDrivers()
  for i = 1, #frames do
    local f = frames[i]
    if f.shown and f.scripts.OnUpdate then
      local ok, err = pcall(f.scripts.OnUpdate)
      if not ok then fail("OnUpdate: " .. tostring(err)) end
    end
  end
end

-- engine, loaded once and shared (stateless module tables)
IB_SIM_MODULES = {}
require = nil
local ORDER = {
  "IdleBattle/sim/Hash.lua", "IdleBattle/sim/Rand.lua", "IdleBattle/sim/Mods.lua",
  "IdleBattle/sim/Rules.lua", "IdleBattle/sim/Sim.lua", "IdleBattle/net/Wire.lua",
  "IdleBattle/net/Snap.lua", "IdleBattle/net/Net.lua", "IdleBattle/HandLog.lua",
}
for i = 1, #ORDER do
  local chunk = assert(loadfile(addon .. "/" .. ORDER[i]))
  chunk("PengyouGamesDev", {})
end
local ENG = IB_SIM_MODULES
local R = ENG.Rules

-- ---------------------------------------------------------------------------
-- the bus and the per-client platform
-- ---------------------------------------------------------------------------

local clients = {}

-- bus modes: "sync" delivers in the send call; "lossy" drops LOSSY_DROP% of
-- the 1-char WIRE rows, delays the survivors 0.1..3.5 s (past the 2 s order
-- delay, so LATE atoms occur and the rollback path runs through the bridge;
-- the random delays also REORDER), and duplicates DUP_PCT% of deliveries.
local busMode = "sync"
local LOSSY_DROP = 15
local DUP_PCT = 6
local pendingMsgs = {}

local function handOver(c, from, scope, module, mtype, token, ...)
  local h = c.commHandlers[module]
  if h then
    local ok, err = pcall(h, mtype, token, from.name, scope, ...)
    if not ok then fail("recv handler: " .. tostring(err)) end
  end
end

local function deliver(from, scope, target, module, mtype, token, ...)
  for i = 1, #clients do
    local c = clients[i]
    if c.name ~= from.name then
      if scope ~= "private" or c.name == target then
        -- loss/delay applies only to the 1-char WIRE rows (what Net repairs);
        -- the addon channel never loses matchmaking rows in transit, and the
        -- lossy mode exists to exercise the repair machinery, not to model a
        -- channel that does not exist.
        if busMode == "sync" or #mtype > 1 then
          handOver(c, from, scope, module, mtype, token, ...)
        elseif math.random(100) > LOSSY_DROP then
          local copies = (math.random(100) <= DUP_PCT) and 2 or 1
          for _ = 1, copies do
            local args = { ... }
            pendingMsgs[#pendingMsgs + 1] = {
              due = now + 0.1 + math.random() * 3.4, seqNo = #pendingMsgs,
              c = c, from = from, scope = scope, module = module,
              mtype = mtype, token = token, args = args,
            }
          end
        end
      end
    end
  end
end

local function drainBus()
  if #pendingMsgs == 0 then return end
  table.sort(pendingMsgs, function(a, b)
    if a.due ~= b.due then return a.due < b.due end
    return a.seqNo < b.seqNo
  end)
  while pendingMsgs[1] and pendingMsgs[1].due <= now do
    local m = table.remove(pendingMsgs, 1)
    handOver(m.c, m.from, m.scope, m.module, m.mtype, m.token,
      (table.unpack or unpack)(m.args))
  end
end

local function makeClient(name)
  local C = { name = name, commHandlers = {}, commDrops = {}, tickers = {},
              asks = {}, toasts = {}, buttons = {}, reveals = {}, eps = {},
              locked = false, sent = 0, count = 1 }
  local PG = {}
  C.PG = PG
  PG.L = setmetatable({}, { __index = function(_, k) return k end })
  PG.debug = false
  PG.db = { profile = {} }
  PG.IsSecret = function() return false end
  PG.SafeStr = function(v) if type(v) ~= "string" then return nil end return v end
  PG.SafeNum = function(v) return tonumber(v) end
  PG.FullName = function(unit) if unit == "player" then return name end return nil end
  PG.After = function(sec, fn) end
  PG.Ticker = function(sec, fn)
    local t = { fn = fn, cancelled = false }
    function t:Cancel() self.cancelled = true end
    C.tickers[#C.tickers + 1] = t
    return t
  end
  PG.RegisterInit = function(fn) C.pendingInits = C.pendingInits or {}; C.pendingInits[#C.pendingInits + 1] = fn end
  PG.RegisterEvent = function() return true end

  -- session seat (Core.lua's logic, minimal)
  PG.Session = {}
  local seat, seatCbs = nil, {}
  function PG.Session.Claim(module, token, host)
    if seat then
      if seat.module == module and seat.token == token then return true end
      return false, seat.module, seat.host
    end
    seat = { module = module, token = token, host = host }
    for i = 1, #seatCbs do pcall(seatCbs[i], seat, nil) end
    return true
  end
  function PG.Session.ClaimHost(module, token, host)
    local ok, m, h = PG.Session.Claim(module, token, host)
    if ok then return true end
    return false, m, h
  end
  function PG.Session.Release(module, token)
    if not seat or seat.module ~= module or seat.token ~= token then return false end
    local prev = seat
    seat = nil
    for i = 1, #seatCbs do pcall(seatCbs[i], nil, prev) end
    return true
  end
  function PG.Session.Seat() return seat end
  function PG.Session.IsSeated() return seat ~= nil end
  function PG.Session.OnChange(fn) seatCbs[#seatCbs + 1] = fn end

  PG.Safety = { state = {} }
  C.safetyCbs = {}
  function PG.Safety.RegisterWindow() end
  function PG.Safety.OnChange(fn) C.safetyCbs[#C.safetyCbs + 1] = fn end

  -- Theme: partial, capture-only. The module guards every call by function
  -- presence, so a partial table exercises the guarded paths; the reveal
  -- PAYLOAD (the result logic) is captured for assertion, its PLAYBACK is a
  -- real-client concern.
  PG.Theme = {
    Sound = function() end,
    Stamp = function() end,
    Shadow = function() end,
    Reveal = function(p) C.reveals[#C.reveals + 1] = p end,
    RevealQueue = function(p) C.reveals[#C.reveals + 1] = p end,
  }

  -- UI stubs
  PG.UI = {}
  function PG.UI.Window(key, title, w, h, theme)
    local f = CreateFrame("Frame")
    f.shown = false
    f.__ibClient = C
    return f
  end
  function PG.UI.Button(parent, label, w, h, onClick)
    local b = { label = label, enabled = true, alpha = 1, scripts = {}, Click = onClick }
    function b:SetPoint() end
    function b:SetEnabled(e) self.enabled = e and true or false end
    function b:SetText(t) self.label = t end
    function b:SetAlpha(a) self.alpha = a end
    function b:SetScript(ev, fn) self.scripts[ev] = fn end
    C.buttons[#C.buttons + 1] = b
    return b
  end
  function PG.UI.Ask(key, text, a, d, secs, onAccept, onDecline)
    C.asks[key] = { text = text, onAccept = onAccept, onDecline = onDecline }
  end
  function PG.UI.Dismiss(key) if key then C.asks[key] = nil end end
  function PG.UI.AskCount()
    local n = 0
    for _ in pairs(C.asks) do n = n + 1 end
    return n
  end
  function PG.UI.Toast(text) C.toasts[#C.toasts + 1] = tostring(text); print("  [" .. name .. " toast] " .. tostring(text)) end
  function PG.UI.ScopePicker(parent, cfg)
    local p = {}
    function p:SetPoint() end
    function p:Get() return "group" end
    function p:Set() return true end
    function p:Refresh() return "group" end
    return p
  end

  -- Comm stub: the dev addon's surface, wired to the bus
  PG.Comm = {}
  local SCOPES = { group = "P", guild = "G", public = "R" }
  local SCOPE_OF = { P = "group", G = "guild", R = "public" }
  function PG.Comm.ScopeCode(s) return SCOPES[s] end
  function PG.Comm.ScopeOfCode(c) return SCOPE_OF[c] end
  function PG.Comm.Locked() return C.locked end
  function PG.Comm.ScopeAvailable(s) if s == "group" then return true end return false, "no" end
  function PG.Comm.Register(module, handler, onDrop)
    C.commHandlers[module] = handler
    C.commDrops[module] = onDrop
  end
  function PG.Comm.RegisterTrust() end
  local function send(scope, target, module, mtype, token, ...)
    -- byte-budget assertion: rebuild the on-wire string the dev Comm builds
    local msg = "3|" .. module .. "|" .. mtype .. "|" .. tostring(token)
    local n = select("#", ...)
    for i = 1, n do msg = msg .. "|" .. tostring((select(i, ...))) end
    if #msg > 200 then fail("over 200 bytes: " .. msg) end
    if C.maxMsg == nil or #msg > C.maxMsg then C.maxMsg = #msg end
    if C.locked then
      local onDrop = C.commDrops[module]
      if onDrop then pcall(onDrop, mtype, tostring(token)) end
      return false
    end
    C.sent = C.sent + 1
    deliver(C, scope, target, module, mtype, tostring(token), ...)
    return true
  end
  function PG.Comm.Broadcast(scope, module, mtype, token, ...)
    if scope ~= "group" then return false end
    return send(scope, nil, module, mtype, token, ...)
  end
  function PG.Comm.Whisper(target, module, mtype, token, ...)
    if type(target) ~= "string" or target == "" then return false end
    return send("private", target, module, mtype, token, ...)
  end

  -- the engine handle, with Net.new wrapped so the harness holds each
  -- endpoint the module builds (read-only; the module is untouched)
  local engine = {}
  for k, v in pairs(ENG) do engine[k] = v end
  engine.Net = {
    new = function(opts)
      local ep = ENG.Net.new(opts)
      C.eps[#C.eps + 1] = ep
      C.ep = ep
      return ep
    end,
  }
  PG.IBEngine = engine

  -- load the module under test
  local chunk = assert(loadfile(addon .. "/Games/IdleBattle.lua"))
  chunk("PengyouGamesDev", PG)
  for i = 1, #(C.pendingInits or {}) do
    local ok, err = pcall(C.pendingInits[i])
    if not ok then fail("init: " .. tostring(err)) end
  end

  function C.fireTickers()
    for i = 1, #C.tickers do
      local t = C.tickers[i]
      if not t.cancelled then
        local ok, err = pcall(t.fn)
        if not ok then fail("ticker: " .. tostring(err)) end
      end
    end
  end
  clients[#clients + 1] = C
  return C
end

-- ---------------------------------------------------------------------------
-- the drive: clock, board lookup, board clicks
-- ---------------------------------------------------------------------------

local function step(dt)
  now = now + dt
  drainBus()
  fireDrivers()
end

local function tickSecond()
  for i = 1, #clients do clients[i].fireTickers() end
end

local function rootOf(f)
  while f.parent do f = f.parent end
  return f
end

-- first frame of client C matching pred (attribution by window parent chain)
local function clientFrame(C, pred)
  for i = 1, #frames do
    local f = frames[i]
    if pred(f) and rootOf(f).__ibClient == C then return f end
  end
  return nil
end

local function btnByTag(C, key, val)
  for i = 1, #C.buttons do
    if C.buttons[i][key] == val then return C.buttons[i] end
  end
  return nil
end

local function clickBtn(C, key, val, what)
  local b = btnByTag(C, key, val)
  if not b or not b.Click then
    fail(C.name .. ": no clickable button for " .. what)
    return
  end
  local ok, err = pcall(b.Click, b)
  if not ok then fail(C.name .. ": button " .. what .. ": " .. tostring(err)) end
end

local function fireClick(f, C, what)
  if not f then
    fail(C.name .. ": no frame to click: " .. what)
    return
  end
  local h = f.scripts and f.scripts.OnClick
  if not h then
    fail(C.name .. ": frame has no OnClick: " .. what)
    return
  end
  local ok, err = pcall(h, f)
  if not ok then fail(C.name .. ": click " .. what .. ": " .. tostring(err)) end
end

local function setCount(C, n)
  while C.count < n do
    clickBtn(C, "__ibCountBtn", 1, "count +")
    C.count = C.count + 1
  end
  while C.count > n do
    clickBtn(C, "__ibCountBtn", -1, "count -")
    C.count = C.count - 1
  end
end

-- deploy through the board: arm the unit button, set the stepper, click the
-- lane's own hit frame (never a slot hit)
local function orderUnit(C, kind, lane, count)
  setCount(C, count)
  clickBtn(C, "__ibKind", kind, "unit " .. kind)
  fireClick(clientFrame(C, function(f) return f.__ibLane == lane and f.__ibSlot == nil end),
    C, "lane " .. lane)
end

-- build through the board: arm the building button, click my slot square
local function orderBld(C, letter, slot)
  clickBtn(C, "__ibKind", letter, "building " .. letter)
  fireClick(clientFrame(C, function(f) return f.__ibSlot == slot end), C, "slot " .. slot)
end

local function hasText(C, needle)
  for i = 1, #frames do
    local f = frames[i]
    if rootOf(f).__ibClient == C then
      for k = 1, #f.strings do
        if tostring(f.strings[k].text):find(needle, 1, true) then return true end
      end
    end
  end
  return false
end

local function toastHas(C, needle)
  for i = 1, #C.toasts do
    if C.toasts[i]:find(needle, 1, true) then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- board assertions
-- ---------------------------------------------------------------------------

-- Slot-square geometry, on ONE client: 12 boxes, three of each of the four
-- fracs derived from the hashed POS_* constants -- own back/front on the LEFT
-- half, enemy mirrored to 1 - frac on the right -- and all six OWN slots
-- clickable. Run on BOTH clients, this is the render-mirror proof: the side-2
-- client must place its own squares on ITS left too.
local function assertGeometry(C, who)
  local bf = R.C.POS_BACK_SLOT / R.C.LANE_LEN
  local ff = R.C.POS_FRONT_SLOT / R.C.LANE_LEN
  local want = { [bf] = 0, [ff] = 0, [1 - bf] = 0, [1 - ff] = 0 }
  local n = 0
  for i = 1, #frames do
    local f = frames[i]
    if f.__ibBoxFrac and rootOf(f).__ibClient == C then
      n = n + 1
      if want[f.__ibBoxFrac] == nil then
        fail(who .. ": slot box at unexpected frac " .. tostring(f.__ibBoxFrac))
      else
        want[f.__ibBoxFrac] = want[f.__ibBoxFrac] + 1
      end
    end
  end
  if n ~= 4 * R.C.LANES then fail(who .. ": expected " .. 4 * R.C.LANES .. " slot boxes, saw " .. n) end
  for k, v in pairs(want) do
    if v ~= R.C.LANES then fail(who .. ": slot frac " .. tostring(k) .. " seen " .. v .. "x, want " .. R.C.LANES) end
  end
  for s = 1, R.C.SLOTS do
    if not clientFrame(C, function(f) return f.__ibSlot == s end) then
      fail(who .. ": own slot " .. s .. " has no click target")
    end
  end
end

-- Unit-stack markers: on this client, every shown "mine" marker sits on the
-- left of the given boundary and every "foe" marker on the right. True on the
-- side-2 client too = the mirror is by construction.
local function assertMarkSides(C, who, boundary)
  local mineN, foeN = 0, 0
  for i = 1, #frames do
    local f = frames[i]
    if f.__ibMark and f.shown and rootOf(f).__ibClient == C then
      if f.__ibMark == "mine" then
        mineN = mineN + 1
        if f.__ibFrac > boundary then fail(who .. ": OWN stack rendered on the enemy half (frac " .. tostring(f.__ibFrac) .. ")") end
      else
        foeN = foeN + 1
        if f.__ibFrac < 1 - boundary then fail(who .. ": ENEMY stack rendered on the viewer's half (frac " .. tostring(f.__ibFrac) .. ")") end
      end
    end
  end
  if mineN < 1 then fail(who .. ": no own unit marker rendered") end
  if foeN < 1 then fail(who .. ": no enemy unit marker rendered") end
end

-- ---------------------------------------------------------------------------
-- phase 0: the in-game selftest path
-- ---------------------------------------------------------------------------

print("== ibshim: two-client headless drive of the board ==")

local A = makeClient("Alpha-DevRealm")
local B = makeClient("Bravo-DevRealm")

print("-- selftest --")
if not A.PG.IB.Selftest() then fail("selftest returned false") end

-- ---------------------------------------------------------------------------
-- phase A: sync bus -- lifecycle, board render, orders, concede
-- ---------------------------------------------------------------------------

print("-- host / lite / invitation --")
A.PG.IB.Host("group")
local askKey
for k in pairs(B.asks) do askKey = k end
if not askKey then fail("B raised no invitation for A's OPEN") end

print("-- join / handshake --")
if askKey then
  local ok, err = pcall(B.asks[askKey].onAccept)
  if not ok then fail("accept: " .. tostring(err)) end
end
if not B.PG.Session.IsSeated() then fail("B holds no seat after accept") end
if not A.PG.Session.IsSeated() then fail("A holds no seat after hosting") end
for i = 1, 80 do
  step(0.1)
  if i % 10 == 0 then tickSecond() end
  local ca, cb = btnByTag(A, "__ibCancel", true), btnByTag(B, "__ibCancel", true)
  if ca and cb and tostring(ca.label):find("Concede", 1, true)
    and tostring(cb.label):find("Concede", 1, true) then
    break
  end
end
if not (A.ep and A.ep.sim and B.ep and B.ep.sim) then fail("handshake never built both sims") end

print("-- board render: geometry, mirror, fog label --")
assertGeometry(A, "A(host,side1)")
assertGeometry(B, "B(client,side2)")
for _, c in ipairs({ A, B }) do
  if not hasText(c, "Fog of war is a later milestone") then
    fail(c.name .. ": the permanent no-fog label is missing")
  end
end

print("-- orders through the board (sync) --")
-- a cost tooltip, read live from Rules
local sBtn = btnByTag(A, "__ibKind", R.UNITS[1].kind)
if sBtn and sBtn.scripts.OnEnter then
  local ok, err = pcall(sBtn.scripts.OnEnter, sBtn)
  if not ok then fail("tooltip OnEnter: " .. tostring(err)) end
  local seen = false
  for i = 1, #GameTooltip.lines do
    if GameTooltip.lines[i]:find("Cost " .. R.UNITS[1].cost, 1, true) then seen = true end
  end
  if not seen then fail("unit tooltip did not carry the Rules cost") end
else
  fail("no unit button / OnEnter for the first unit kind")
end
orderUnit(A, R.UNITS[1].kind, 1, 2)
-- the queued-order ghost is visible until the exec tick
local lane1A = clientFrame(A, function(f) return f.__ibLane == 1 and f.__ibSlot == nil end)
if not (lane1A and lane1A.__ibGhost and lane1A.__ibGhost.text:find("queued", 1, true)) then
  fail("A: no queued-order marker after a deploy click")
end
orderUnit(B, R.UNITS[2].kind, 2, 1)
for i = 1, 30 do
  step(0.1)
  if i % 10 == 0 then tickSecond() end
end
tickSecond()   -- one extra repaint so both boards show the marched stacks
assertMarkSides(A, "A(host,side1)", 0.4)
assertMarkSides(B, "B(client,side2)", 0.4)
-- OWNERSHIP, not just mirroring: each board's "You" economy line must carry
-- that client's OWN engine side's bank (the shim derives the side the way
-- the protocol defines it: host = 1). The two banks differ here by
-- construction (a 2-spear spend vs a horse spend), so a board that renders
-- engine side 1 as "mine" on both seats fails on the client.
for _, e in ipairs({ { A, 1, "A(host,side1)" }, { B, 2, "B(client,side2)" } }) do
  local bank = e[1].ep.sim.sides[e[2]].bank
  if not hasText(e[1], "You   Levy " .. bank .. " /") then
    fail(e[3] .. ": the You line does not show this seat's own bank (" .. bank .. ")")
  end
end
if A.ep.sim.sides[1].bank == A.ep.sim.sides[2].bank then
  fail("phase A banks coincide - the ownership assert lost its teeth")
end

print("-- concede (the V row) --")
local cb = btnByTag(B, "__ibCancel", true)
if not (cb and tostring(cb.label):find("Concede", 1, true)) then
  fail("B's cancel button is not in concede form during play")
end
clickBtn(B, "__ibCancel", true, "concede")
step(0.1)
if B.PG.Session.IsSeated() then fail("B still seated after conceding") end
if A.PG.Session.IsSeated() then fail("A still seated after receiving the V row") end
if not toastHas(A, "voided") then fail("A never learned the match was voided") end
if not hasText(B, "conceded") then fail("B's board does not say it conceded") end
if #A.reveals + #B.reveals > 0 then fail("a VOID ending must not fire the results reveal") end

-- ---------------------------------------------------------------------------
-- phase B: the two void paths (lockdown; silence), re-proved over the board
-- ---------------------------------------------------------------------------

print("-- re-host, then lockdown void / silence void --")
A.PG.IB.Host("group")
local ak2
for k in pairs(B.asks) do ak2 = k end
if not ak2 then fail("B raised no invitation for A's second OPEN") end
if ak2 then pcall(B.asks[ak2].onAccept) end
for i = 1, 80 do
  step(0.1)
  if i % 10 == 0 then tickSecond() end
end
if not (A.PG.Session.IsSeated() and B.PG.Session.IsSeated()) then
  fail("second match never reached play")
end
A.locked = true
step(0.1)
if A.PG.Session.IsSeated() then fail("A still seated after lockdown void") end
if not toastHas(A, "locked down") then fail("A's lockdown void never explained itself") end
for i = 1, 40 do
  now = now + 1
  tickSecond()
end
if B.PG.Session.IsSeated() then fail("B still seated after 40 s of silence") end
A.locked = false

-- ---------------------------------------------------------------------------
-- phase C: a COMPLETE match over the lossy/delaying/reordering/duplicating
-- bus, every kind of order the board can issue, from both seats.
-- ---------------------------------------------------------------------------

print("-- lossy-bus full match (drop " .. LOSSY_DROP .. "%, delay 0.1..3.5 s, dup " .. DUP_PCT .. "%) --")
math.randomseed(42)
local Cc = makeClient("Carol-DevRealm")
local Dd = makeClient("Dave-DevRealm")
busMode = "lossy"
local wallStart = now
Cc.PG.IB.Host("group")
local accepted = false
for i = 1, 900 do
  step(0.1)
  if i % 10 == 0 then tickSecond() end
  if not accepted then
    local k3
    for k in pairs(Dd.asks) do k3 = k end
    if k3 then
      accepted = true
      pcall(Dd.asks[k3].onAccept)
    end
  end
  if Cc.ep and Cc.ep.sim and Dd.ep and Dd.ep.sim then
    local c1, c2 = btnByTag(Cc, "__ibCancel", true), btnByTag(Dd, "__ibCancel", true)
    if c1 and c2 and tostring(c1.label):find("Concede", 1, true)
      and tostring(c2.label):find("Concede", 1, true) then
      break
    end
  end
end
if not (Cc.ep and Cc.ep.sim and Dd.ep and Dd.ep.sim) then
  fail("lossy pair never built both sims")
end

-- The order script, DISCOVERED from the hashed tables: every unit kind and
-- every first-playable building letter, per client. Late builds overflow the
-- slot cap, and one per client goes class-illegal into an untouched back
-- square -- ISSUED through the board, judged (fizzled) by both sims (A.4).
local script = {}
local counts = { 1, 3, 9 }
for k = 1, #R.UNITS do
  local kind = R.UNITS[k].kind
  script[40 + (k - 1) * 200] = { c = Cc, kind = kind, lane = k, count = counts[k] or 1 }
  script[140 + (k - 1) * 200] = { c = Dd, kind = kind, lane = R.C.LANES + 1 - k, count = counts[#counts + 1 - k] or 1 }
end
local fronts, backs = {}, {}
for i = 1, #R.BUILDINGS do
  local b = R.BUILDINGS[i]
  if b.firstPlayable == 1 then
    if b.slotClass == "front" then fronts[#fronts + 1] = b.letter else backs[#backs + 1] = b.letter end
  end
end
local function bldScript(cl, base)
  local seq = {}
  local fi, bi, slotF, slotB = 1, 1, 1, 2
  while fi <= #fronts or bi <= #backs do
    if fi <= #fronts then
      seq[#seq + 1] = { c = cl, bld = fronts[fi], slot = slotF }
      fi = fi + 1
      slotF = math.min(slotF + 2, R.C.SLOTS - 1)
    end
    if bi <= #backs then
      seq[#seq + 1] = { c = cl, bld = backs[bi], slot = slotB }
      bi = bi + 1
      slotB = math.min(slotB + 2, R.C.SLOTS)
    end
  end
  -- the guaranteed class fizzle: a FRONT building into the untouched last
  -- BACK square (ENFORCE_SLOT_CLASS is hashed 1)
  seq[#seq + 1] = { c = cl, bld = fronts[1], slot = R.C.SLOTS }
  for k = 1, #seq do script[base + (k - 1) * 180] = seq[k] end
end
bldScript(Cc, 700)
bldScript(Dd, 790)
-- sustained pressure so the match carries combat, keep damage and coalescing;
-- stops at 5600 so the last exec tick sits far inside the clock (the part-1
-- bridge drops in-match rows once a side is done -- see the README's part 2
-- flag on the clock-edge window)
local n = 0
for i = 2200, 5600, 40 do
  n = n + 1
  script[i] = { c = (n % 2 == 0) and Cc or Dd,
                kind = R.UNITS[(n % #R.UNITS) + 1].kind,
                lane = (n % R.C.LANES) + 1,
                count = (n % 3) + 1 }
end

local function bothDone()
  return not Cc.PG.Session.IsSeated() and not Dd.PG.Session.IsSeated()
    and Cc.ep.sim and Dd.ep.sim and Cc.ep.sim.over and Dd.ep.sim.over
end

for i = 1, 6800 do
  step(0.1)
  local o = script[i]
  if o then
    if o.kind then orderUnit(o.c, o.kind, o.lane, o.count) else orderBld(o.c, o.bld, o.slot) end
  end
  if i % 10 == 0 then tickSecond() end
  if i > 5700 and bothDone() then break end
end

if not bothDone() then
  fail("lossy full match never finished on both sides")
else
  local epC, epD = Cc.ep, Dd.ep
  local sC, sD = epC.sim, epD.sim
  -- convergence: both terminal sims bit-identical
  if ENG.Hash.state(sC) ~= ENG.Hash.state(sD) then fail("terminal stateHash differs between the two clients") end
  if ENG.Hash.log(sC) ~= ENG.Hash.log(sD) then fail("terminal logDigest differs between the two clients") end
  if sC.winner ~= sD.winner then fail("the two sims disagree on the winner") end
  if sC.reason ~= sD.reason then fail("the two sims disagree on the reason") end
  if sC.clock ~= sD.clock then fail("the two sims disagree on the terminal tick") end
  -- zero settled mismatches, with real comparisons made
  for _, e in ipairs({ { epC, "C" }, { epD, "D" } }) do
    if e[1].st.mismatches ~= 0 then fail(e[2] .. ": settled hash mismatches occurred") end
    if e[1].st.settledCompares < 1 then fail(e[2] .. ": no settled hash comparison ever ran") end
  end
  -- the hostile bus actually exercised the repair machinery through the bridge
  local late = epC.st.late + epD.st.late
  local rb = epC.st.rollbacks + epD.st.rollbacks
  local dup = epC.st.dupAtoms + epD.st.dupAtoms
  if late == 0 then fail("lossy bus produced no late atoms (rollback path untested)") end
  if rb == 0 then fail("no rollbacks despite late atoms") end
  if dup == 0 then fail("no duplicate atoms despite bus duplication") end
  -- both sims agree on executed/fizzled per side, and the illegal orders
  -- fizzled rather than being vetoed client-side
  for s = 1, 2 do
    if sC.sides[s].cmdsFizzled ~= sD.sides[s].cmdsFizzled then
      fail("side " .. s .. ": the sims disagree on fizzle counts")
    end
    if sC.sides[s].cmdsFizzled < 1 then fail("side " .. s .. ": the scripted illegal build never fizzled") end
    if sC.sides[s].cmdsExecuted < 5 then fail("side " .. s .. ": too few orders executed") end
  end
  -- the M5 traffic budget: per client, per minute, over the WHOLE phase
  local mins = (now - wallStart) / 60
  local rateC, rateD = Cc.sent / mins, Dd.sent / mins
  if rateC >= 32 then fail(string.format("C traffic %.1f msg/min breaks the 32/min budget", rateC)) end
  if rateD >= 32 then fail(string.format("D traffic %.1f msg/min breaks the 32/min budget", rateD)) end
  -- the result made it to the surface: verdict text and the reveal payloads
  if not (hasText(Cc, "Final:") and hasText(Dd, "Final:")) then
    fail("a finished match must show its verdict on the board")
  end
  if #Cc.reveals ~= 1 or #Dd.reveals ~= 1 then
    fail("each client should queue exactly one results reveal (C " .. #Cc.reveals .. ", D " .. #Dd.reveals .. ")")
  else
    local pc, pd = Cc.reveals[1], Dd.reveals[1]
    local w = sC.winner
    local wantC = (w == 0) and "DRAW" or ((w == 1) and "VICTORY" or "DEFEAT")
    local wantD = (w == 0) and "DRAW" or ((w == 2) and "VICTORY" or "DEFEAT")
    if pc.title ~= wantC then fail("C's reveal title " .. tostring(pc.title) .. ", want " .. wantC) end
    if pd.title ~= wantD then fail("D's reveal title " .. tostring(pd.title) .. ", want " .. wantD) end
    for _, p in ipairs({ pc, pd }) do
      if type(p.rows) ~= "table" or #p.rows < 2 then
        fail("a reveal payload is missing its player rows")
      elseif not p.rows[1].personal then
        fail("the viewer's own row must be marked personal")
      end
    end
  end
  print(string.format("  full match: %d ticks, winner %d (%s), late %d, rollbacks %d, dup %d",
    sC.clock, sC.winner, tostring(sC.reason), late, rb, dup))
  print(string.format("  traffic: C %.1f msg/min, D %.1f msg/min (budget 32); largest msg C %dB D %dB",
    rateC, rateD, Cc.maxMsg or 0, Dd.maxMsg or 0))
  print(string.format("  settled compares C %d D %d, mismatches 0/0; fizzled %d/%d executed %d/%d",
    epC.st.settledCompares, epD.st.settledCompares,
    sC.sides[1].cmdsFizzled, sC.sides[2].cmdsFizzled,
    sC.sides[1].cmdsExecuted, sC.sides[2].cmdsExecuted))
end

print("== ibshim: " .. (#failures == 0 and "GREEN" or ("RED (" .. #failures .. " failures)")) .. " ==")
os.exit(#failures == 0 and 0 or 1)
