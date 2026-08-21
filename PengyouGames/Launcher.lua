-- Launcher.lua - the shell's owner: the Games page, the footer and the minimap.
--
-- THERE IS NO LAUNCHER WINDOW ANY MORE. The launcher, the Ledger, the Rules and
-- the Settings are four pages of ONE window (PG.UI.Shell, Widgets.lua); this
-- file owns the shell in the sense that it builds the page you land on and the
-- footer strip that is visible from every other page. The six PLAY windows are
-- untouched and stay their own windows.
--
-- What lives here:
--   * the Games page: the 2x3 art-tile picker, the Open games list, the
--     tonight one-liner
--   * the footer: the DND sign (global state, so it belongs with the wordmark)
--     and the live/open status line, which is click-to-focus
--   * the minimap button, unchanged except that it toggles the shell
local ADDON, PG = ...

PG.Launcher = {}

local dndBtn, statusBtn, tonightFS
local tiles = {}

-------------------------------------------------------------------------------
-- The Open games list (SCOPE.md 6.3, CONCURRENCY.md 5.10).
--
-- This section is the ONLY surface for an invitation that never pops: a public
-- open (which is never allowed a popup), any open that arrives while the single
-- round-based seat is held, an open past ASK_MAX, and a guild open over its
-- invite budget. Without it those invitations are simply lost, and the toasts
-- that point at "the Pengyou Games window" point at nothing.
--
-- It is a VIEW, never a second store (5.10 rule 2): the rows are a projection of
-- the games' own lite records, rebuilt from them on show and on a slow ticker,
-- so a row can never outlive the record behind it - and a row with no record
-- behind it would be unjoinable, since every Join resolves through the module's
-- registry.
-------------------------------------------------------------------------------

local MAX_OPEN_ROWS = 5     -- SCOPE.md 6.3
local OPEN_ROW_H = 20
local OPEN_TTL = 60         -- seconds a row is offered, however long its record lives
local LIST_TICK = 2         -- reconcile cadence while the shell is open

-- THE GAMES PAGE, 420 x 548, spent to the pixel. Nothing here resizes: the old
-- launcher grew and shrank itself as open games came and went (and re-ran the
-- overlap solver each time, which moved the user's window). The list band is
-- reserved instead, exactly like the footer.
--
--    6  top pad
--   16  tagline            S, BRASS, centred
--   10  gap
--  336  tile grid          3 rows of 104 with two 12px gutters
--   12  gap
--    1  divider
--   12  gap
--   16  OPEN GAMES         T, BRASS, centred
--    8  gap
--  100  five rows of 20    SCOPE.md 6.3 caps the list at five senders, and all
--                          five stay REACHABLE: a row nobody can see is an
--                          invitation nobody can accept (CONCURRENCY.md 5.10)
--    8  gap
--   16  tonight one-liner  S, centred
--    7  bottom pad
--  = 548
local PAGE_W     = 420      -- the shell's content slot; the page never resizes
local TAG_Y      = -6
local GRID_Y     = -32
local TILE_W, TILE_H = 190, 104
local TILE_GAP_X, TILE_GAP_Y = 12, 12
local TILE_X1    = 14       -- 14 + 190 + 12 + 190 + 14 = 420
local TILE_X2    = TILE_X1 + TILE_W + TILE_GAP_X
local DIV_Y      = -380
local HEAD_Y     = -393
local ROWS_Y     = -417
local TONIGHT_Y  = -525
local INSET      = 24       -- METRIC.INSET; the list's own side inset
local ROW_LABEL_W = 280     -- 24 + 280 + gutter + 76 + 24 = 420 with room over

-- ASCII only, per the source rule: SCOPE.md 6.3's separator is U+00B7.
--
-- These two tables are the launcher's own copy of the module-code -> display
-- name mapping, deliberately kept local rather than promoted to Core: this file
-- is the only place a code is rendered for a game the local client may not even
-- have loaded, and entryOf's GAME_NAME lookup below is the gate on whether an
-- open-games row can exist AT ALL. A missing entry here does not error, it
-- silently drops every invitation for that game - so when a seventh game lands,
-- these are the first two lines to edit.
local GAME_NAME = { LG = "Loot Goblins", RPS = "Rock Paper Scissors", PB = "Pull Book",
                    DR = "Death Roll", GB = "The Gambler", QZ = "Quiz",
                    MP = "Mythic Parley" }
local GAME_SHORT = { LG = "Goblins", RPS = "RPS", PB = "Book",
                     DR = "Death Roll", GB = "Gambler", QZ = "Quiz",
                     MP = "Parley" }
-- CONCURRENCY.md 5.10 rule 1 lists opens "at every scope including group", so
-- the label set is wider than SCOPE.md 6.3's Guild|Public table.
local SCOPE_LABEL = { group = "Party", guild = "Guild", public = "Public" }

local openRows = {}   -- [game|host|token] = entry
local rowFrames = {}  -- the five rows, built once with the window
local listTicker
local refreshList

local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

-- Every field arrives from a wire-derived record, so every field is validated
-- here (PG.SafeStr / PG.SafeNum both reject secret values).
local function entryOf(t, now)
  if type(t) ~= "table" then return nil end
  local game = PG.SafeStr(t.game)
  if not game or not GAME_NAME[game] then return nil end
  local host = PG.SafeStr(t.host)
  if not host or host == "" or #host > 64 then return nil end
  local token = PG.SafeStr(t.token)
  if not token or token == "" or #token > 24 or token:find("|", 1, true) then return nil end
  local scope = PG.SafeStr(t.scope)
  if not scope or not SCOPE_LABEL[scope] then return nil end
  local key = PG.SafeStr(t.key)
  if key == "" then key = nil end
  return {
    game = game,
    host = host,
    token = token,
    scope = scope,
    -- the games all key their registries host .. "|" .. token, so a projection
    -- that omits the composite key (the Pull Book's) still resolves
    key = key or (host .. "|" .. token),
    expires = PG.SafeNum(t.expires) or (now + OPEN_TTL),
    addedAt = now,
  }
end

local function storeEntry(e)
  local k = e.game .. "|" .. e.host .. "|" .. e.token
  local prev = openRows[k]
  if prev then
    -- refresh in place; the TTL clock keeps running from when the row first
    -- appeared, so a heartbeat-extended record cannot hold a row forever
    prev.scope = e.scope
    prev.expires = e.expires
    prev.key = e.key
  else
    openRows[k] = e
  end
end

local function cull(now)
  for k, e in pairs(openRows) do
    if now > e.expires or (now - e.addedAt) > OPEN_TTL then openRows[k] = nil end
  end
end

-- Rebuild from the modules' own projections. Push (AddOpenGame) keeps the list
-- responsive; this is what keeps it HONEST - a record swept, superseded,
-- cancelled or begun elsewhere takes its row with it whether or not its
-- eviction path remembered to call RemoveOpenGame.
local PROJECTIONS = {
  LG = function() return PG.LG and PG.LG.OpenGames and PG.LG.OpenGames() end,
  RPS = function() return PG.RPS and PG.RPS.OpenGames and PG.RPS.OpenGames() end,
  DR = function() return PG.DR and PG.DR.OpenGames and PG.DR.OpenGames() end,
  GB = function() return PG.GB and PG.GB.OpenGames and PG.GB.OpenGames() end,
  QZ = function() return PG.QZ and PG.QZ.OpenGames and PG.QZ.OpenGames() end,
  -- note the name: the Pull Book projects OpenBooks, not OpenGames
  PB = function() return PG.PB and PG.PB.OpenBooks and PG.PB.OpenBooks() end,
  -- the Pull Book's other mode, and the one place the family split shows here:
  -- MP is its own module code with its own registry, so it projects and joins
  -- like any other game and shares nothing with PB but a tile
  MP = function() return PG.MP and PG.MP.OpenGames and PG.MP.OpenGames() end,
}

local function reconcile()
  local now = GetTime()
  for game, fn in pairs(PROJECTIONS) do
    local ok, list = pcall(fn)
    if ok and type(list) == "table" then
      -- this game's rows are replaced wholesale by what it actually holds
      local keep = {}
      for k, e in pairs(openRows) do
        if e.game == game then
          keep[k] = e.addedAt
          openRows[k] = nil
        end
      end
      for i = 1, #list do
        local e = entryOf(list[i], now)
        if e then
          local k = e.game .. "|" .. e.host .. "|" .. e.token
          e.addedAt = keep[k] or now -- a surviving row keeps its own TTL clock
          storeEntry(e)
        end
      end
    end
  end
  cull(now)
end

-- At most five rows, one per sender (SCOPE.md 6.3), the nearest to expiring
-- first. Ignored senders need no filter here: Comm drops them before any module
-- handler runs, so no lite record - and therefore no row - can exist for one.
local function visibleRows()
  local byHost = {}
  for _, e in pairs(openRows) do
    local cur = byHost[e.host]
    if not cur or e.expires > cur.expires then byHost[e.host] = e end
  end
  local list = {}
  for _, e in pairs(byHost) do list[#list + 1] = e end
  table.sort(list, function(a, b)
    if a.expires ~= b.expires then return a.expires < b.expires end
    if a.host ~= b.host then return a.host < b.host end
    return a.game < b.game
  end)
  while #list > MAX_OPEN_ROWS do table.remove(list) end
  return list
end

-- The seat blocks a Join only for the games that take one. Being in a Pull Book
-- is not busy and the Pull Book claims no seat (I10, CONCURRENCY.md 6.1), so a
-- PB row stays live while you play Loot Goblins - PG.PB.JoinBook applies its
-- own first-book-wins refusal.
--
-- Since 1.1.0 the test is a DECLARED FLAG on the module rather than a module
-- code written down in this file (BRIEF 1.1). With six games and one exemption,
-- a hardcoded list is a list somebody eventually forgets to extend, and the two
-- ways of forgetting are not equally bad: an exemption list that lost PB would
-- grey out a Book the player is entitled to join, with no explanation anywhere,
-- whereas a game that forgets to declare SEAT degrades to "Join enabled" and
-- its own PG.Session.Claim then refuses with the proper worded reason. So the
-- flag is read defensively and its absence means "does not take the seat".
local function takesSeat(entry)
  local m = entry and PG[entry.game]
  return (type(m) == "table" and m.SEAT == true) or false
end

local function blockedBy(entry)
  if not takesSeat(entry) then return nil end
  if not (PG.Session and PG.Session.IsSeated and PG.Session.IsSeated()) then return nil end
  return PG.Session.Seat()
end

-- Join runs the module's existing accept path unchanged: it claims the seat
-- first, whispers JOIN and requests a resync, which is exactly SCOPE.md 6.3's
-- "public sessions construct S only on an explicit Join click".
--
-- A table rather than an if/elseif chain, because six branches of the same
-- shape is where the chain stops being readable - and because the Pull Book's
-- entry point genuinely has a different NAME and a different SIGNATURE, which
-- is much easier to see when the six sit side by side.
local JOINERS = {
  LG = function(e) if PG.LG and PG.LG.JoinOpen then PG.LG.JoinOpen(e.key) end end,
  RPS = function(e) if PG.RPS and PG.RPS.JoinOpen then PG.RPS.JoinOpen(e.key) end end,
  DR = function(e) if PG.DR and PG.DR.JoinOpen then PG.DR.JoinOpen(e.key) end end,
  GB = function(e) if PG.GB and PG.GB.JoinOpen then PG.GB.JoinOpen(e.key) end end,
  QZ = function(e) if PG.QZ and PG.QZ.JoinOpen then PG.QZ.JoinOpen(e.key) end end,
  PB = function(e) if PG.PB and PG.PB.JoinBook then PG.PB.JoinBook(e.host, e.token) end end,
  MP = function(e) if PG.MP and PG.MP.JoinOpen then PG.MP.JoinOpen(e.key) end end,
}

local function joinEntry(entry)
  if not entry then return end
  local fn = JOINERS[entry.game]
  -- pcall as before: a module that errors inside its own accept path must not
  -- take the launcher's repaint down with it, or the row stays on screen
  -- claiming to be joinable forever.
  if fn then pcall(fn, entry) end
  reconcile()
  refreshList()
end

local function rowTooltip(self)
  local e = self.__pgRow and self.__pgRow.__pgEntry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(GAME_NAME[e.game] or e.game)
  GameTooltip:AddLine(e.host .. "  (" .. (SCOPE_LABEL[e.scope] or e.scope) .. ")", 1, 1, 1)
  local seat = blockedBy(e)
  if seat then
    GameTooltip:AddLine("You're playing " .. shortOf(seat.host) .. "'s "
      .. (GAME_NAME[seat.module] or "game") .. " right now.", 1, 0.5, 0.5, true)
  end
  GameTooltip:Show()
end

local emptyFS

local function buildOpenRows(parent)
  local M = (PG.Theme and PG.Theme.METRIC) or nil
  local rowW = PAGE_W - INSET * 2
  local joinW = (M and M.BTN_INLINE_W) or 76
  local joinH = (M and M.BTN_INLINE_H) or 20
  for i = 1, MAX_OPEN_ROWS do
    -- built ONCE, with the page, and shown/hidden from here on: no frame is
    -- ever created per refresh, so nothing churns during combat
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(rowW, OPEN_ROW_H)
    row:SetPoint("TOPLEFT", INSET, ROWS_Y - (i - 1) * OPEN_ROW_H)
    -- S role. GameFontNormalSmall defaults to GOLD and nothing here recoloured
    -- it, so these rows rendered gold while every other list is chalk.
    row.label = row:CreateFontString(nil, "OVERLAY",
      (PG.Theme and PG.Theme.FontTemplate) and PG.Theme.FontTemplate("S")
      or "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 0, 0)
    -- 280 + a 16px gutter + the 76px Join = 372, the full row width. The
    -- longest realistic text is "Grizzlebottom - Death Roll - Party".
    row.label:SetWidth(ROW_LABEL_W)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetMaxLines(1)
    if PG.Theme and PG.Theme.C then
      local c = PG.Theme.C()
      row.label:SetTextColor(c.CHALK[1], c.CHALK[2], c.CHALK[3])
    end
    row.joinBtn = PG.UI.Button(row, "Join", joinW, joinH, function()
      joinEntry(row.__pgEntry)
    end)
    row.joinBtn:SetPoint("RIGHT", 0, 0)
    row.joinBtn.__pgRow = row
    row.joinBtn:HookScript("OnEnter", rowTooltip)
    row.joinBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    rowFrames[i] = row
  end
  -- The launcher had no empty state at all: the toasts that say "check the
  -- Pengyou Games window" pointed at an unlabelled blank row.
  emptyFS = parent:CreateFontString(nil, "OVERLAY",
    (PG.Theme and PG.Theme.FontTemplate) and PG.Theme.FontTemplate("S")
    or "GameFontHighlightSmall")
  emptyFS:SetPoint("TOPLEFT", INSET, ROWS_Y - 24)
  emptyFS:SetPoint("TOPRIGHT", -INSET, ROWS_Y - 24)
  emptyFS:SetJustifyH("CENTER")
  emptyFS:SetWordWrap(false)
  emptyFS:SetMaxLines(1)
  emptyFS:SetText("Nobody nearby has a game open.")
  if PG.Theme and PG.Theme.C then
    local c = PG.Theme.C()
    emptyFS:SetTextColor(c.CHGRAY[1], c.CHGRAY[2], c.CHGRAY[3])
  end
end

-- Paint the rows. Tolerates a list that exists before the page does: an OPEN
-- can arrive long before the user first opens the shell, and the page is lazy.
refreshList = function()
  local list = visibleRows()
  if PG.UI and PG.UI.Shell then PG.UI.Shell.SetBadge("games", #list > 0) end
  if not rowFrames[1] then return end
  for i = 1, MAX_OPEN_ROWS do
    local row = rowFrames[i]
    local e = list[i]
    row.__pgEntry = e
    if e then
      row.label:SetText(shortOf(e.host) .. " - " .. (GAME_SHORT[e.game] or e.game)
        .. " - " .. (SCOPE_LABEL[e.scope] or e.scope))
      row.joinBtn:SetEnabled(blockedBy(e) == nil)
      row:Show()
    else
      row:Hide()
    end
  end
  if emptyFS then emptyFS:SetShown(#list == 0) end
end

-- The ticker runs only while the shell is open: the list is a convenience, not
-- a background service, and nothing about it needs to be true off screen. It
-- follows the SHELL and not the Games page, because the footer carries the open
-- count from every page.
local refreshFooter   -- forward: the ticker repaints it too

local function syncListTicker()
  local want = (PG.UI and PG.UI.Shell and PG.UI.Shell.IsShown()) and true or false
  if want and not listTicker then
    listTicker = PG.Ticker(LIST_TICK, function()
      if not (PG.UI and PG.UI.Shell and PG.UI.Shell.IsShown()) then
        syncListTicker()
        return
      end
      reconcile()
      refreshList()
      refreshFooter()
    end)
  elseif not want and listTicker then
    listTicker:Cancel()
    listTicker = nil
  end
end

-- Called from each game's OPEN handler for every lite record it creates. Must
-- survive being called before the window has ever been built.
function PG.Launcher.AddOpenGame(t)
  local e = entryOf(t, GetTime())
  if not e then return false end
  storeEntry(e)
  refreshList()
  refreshFooter()
  return true
end

function PG.Launcher.RemoveOpenGame(game, host, token)
  game, host, token = PG.SafeStr(game), PG.SafeStr(host), PG.SafeStr(token)
  if not (game and host and token) then return false end
  local k = game .. "|" .. host .. "|" .. token
  if not openRows[k] then return false end
  openRows[k] = nil
  refreshList()
  refreshFooter()
  return true
end

-- DND toggle styled as the carnival stall's hung sign: OPEN / CLOSED. It is
-- GLOBAL state, so it lives in the footer beside the wordmark rather than on
-- one page. Text only - the sign itself never animates. The DND wording moved
-- into the tooltip: the sign is two words wide and the sentence is longer than
-- the sign.
local function refreshDnd()
  if not dndBtn then return end
  dndBtn:SetText(PG.IsDND() and "|cffff8a70CLOSED|r" or "|cff7deda4OPEN|r")
  PG.UI.FitLabel(dndBtn)   -- the label changed length class
end

local function dndTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if PG.IsDND() then
    GameTooltip:AddLine("The stall is CLOSED")
    GameTooltip:AddLine("Do Not Disturb is on: no invitations, no toasts.",
      1, 1, 1, true)
  else
    GameTooltip:AddLine("The stall is OPEN")
    GameTooltip:AddLine("Invitations and toasts can reach you.", 1, 1, 1, true)
  end
  GameTooltip:AddLine("Click to flip the sign.", 0.66, 0.66, 0.61, true)
  GameTooltip:Show()
end

-- The six games, column-major: the three 1.0.0 games keep their order down the
-- LEFT column and the three 1.1.0 games fill the right, which is the same
-- grouping the Rules tab strip uses, so the two surfaces teach the same map.
-- Each row is { module code, display name, play-window key }. The window key is
-- what the footer and the "yours" tile raise; it is the key each game passes to
-- PG.UI.Window, and the Pull Book's is "pullbook" because its window IS its
-- dialog.
local GAMES = {
  { "LG",  "Loot Goblins",        "lg" },
  { "PB",  "Pull Book",           "pullbook" },
  { "RPS", "Rock Paper Scissors", "rps" },
  { "DR",  "Death Roll",          "dr" },
  { "GB",  "The Gambler",         "gb" },
  { "QZ",  "Quiz",                "qz" },
}
local WIN_KEY = {}
for i = 1, #GAMES do WIN_KEY[GAMES[i][1]] = GAMES[i][3] end

local function loaded(code)
  local m = PG[code]
  return type(m) == "table" and type(m.OpenDialog) == "function"
end

-- THE S5 BRIDGE, and the only thing about the tiles that changes next stage.
--
-- A tile pushes to that game's setup PAGE as soon as one is registered under
-- "setup:<CODE>"; until then it opens the game's existing dialog window, whose
-- signature never changes. When S5 folds a dialog in, that game's tile starts
-- pushing with no edit here.
local function openSetup(code)
  local id = "setup:" .. code
  if PG.UI.Shell.HasPage(id) then return PG.UI.Shell.Push(id) end
  local m = PG[code]
  if type(m) == "table" and type(m.OpenDialog) == "function" then
    m.OpenDialog()
    return true
  end
  return false
end

-- Three states, and no silent dead button (PLAN 1.4). "Yours" is read from the
-- SESSION REGISTRY, never from whether a window happens to be shown, so a
-- frozen results window never reports itself as running.
--
-- The Pull Book is deliberately never "yours": it claims no seat (I10) and this
-- file must not learn its private state. When PullBook.lua publishes a
-- read-only "my book" view, this is the one function that reads it.
local function tileState(code)
  if not loaded(code) then
    return "off", "", "This game did not load. Reload your interface."
  end
  local seat = (PG.Session and PG.Session.Seat) and PG.Session.Seat() or nil
  if seat then
    local mine = (seat.host == PG.FullName())
    if seat.module == code then
      return "yours", mine and "your game, in progress" or
        ("in " .. shortOf(seat.host) .. "'s game")
    end
    local m = PG[code]
    if m.SEAT == true then
      return "off", "", "You're playing " .. (mine and "your own "
        or (shortOf(seat.host) .. "'s ")) .. (GAME_NAME[seat.module] or "game")
        .. " right now."
    end
  end
  return "ready", ""
end

local function refreshTiles()
  for i = 1, #tiles do
    local t = tiles[i]
    t:SetState(tileState(t.__pgCode))
  end
end

local function tileClick(tile)
  local code = tile.__pgCode
  if tile.state == "yours" then
    -- raise the game you are IN, not the form that starts a new one. Falls
    -- through when there is nothing raisable (Safety owns the screen, or the
    -- window's own resume predicate says the record is gone).
    if PG.UI.RaiseWindow(WIN_KEY[code]) then return end
  end
  openSetup(code)
end

-------------------------------------------------------------------------------
-- THE PULL BOOK SUBMENU (setup:PB), 1.4.0
--
-- The Pull Book keeps two books now, and they are not variants of one game:
--
--   Raid Pull      bets on the boss in front of you, opened on a strip at every
--                  ready check or pull timer, settled from ENCOUNTER_END.
--   Mythic Parley  bets on a whole keystone, committed BEFORE it starts,
--                  settled from one broadcast after it ends - because inside an
--                  active key this addon cannot talk to itself AT ALL, for the
--                  entire run (PARLEY.md 1).
--
-- So the Pull Book tile pushes this page instead of opening a dialog, and the
-- Games grid stays at six tiles. `openSetup` above already prefers a registered
-- "setup:<CODE>" page over a game's OpenDialog, which is the S5 bridge working
-- exactly as it was built to: nothing in the tile path had to change.
--
-- THE PAGE LIVES HERE, not in either game file, and that is deliberate. It is
-- navigation chrome, and chrome has to exist and explain itself even when the
-- thing behind it did not load - the same reason the shell declares its own nav
-- band instead of deriving it from whatever registered. A page owned by
-- PullBook.lua would simply be absent if PullBook.lua failed, and the tile would
-- fall back to opening a dialog that is not there.
-------------------------------------------------------------------------------

local MODES = {
  { code = "PB", label = "Raid Pull",
    sub  = "Kill, first death, boss HP",
    blurb = "Bets open on a strip at every ready check and every pull timer, and "
      .. "settle the moment the boss dies or you wipe. Party only." },
  { code = "MP", label = "Mythic Parley",
    sub  = "Timed, deaths, wipes, first wall",
    blurb = "Bets on the whole key, placed before you start it - your addons go "
      .. "silent for the entire run. Party or guild." },
}

local modeTiles = {}

-- The page is 420 x 548 and every number below is spent against that, because
-- the blurb under each tile is real copy and not a caption: at a 16px gap it
-- rendered straight through the second tile.
--
--    -8  page pad (p.__pgTop)
--   -14  TWO BOOKS            T, BRASS, centred
--   -34  one-line blurb       S, 2 lines
--   -76  tile 1               372 x 132   -> bottom -208
--  -214  its blurb            S, 2 lines, 30 tall -> bottom -244
--  -258  tile 2               372 x 132   -> bottom -390
--  -396  its blurb            -> bottom -426
--  -444  the "why two books" note, S, 5 lines, 66 tall -> bottom -510
--       = 38 to spare
local MODE_TILE_W, MODE_TILE_H = 372, 132
local MODE_Y0 = -76
local MODE_BLURB_GAP, MODE_BLURB_H = 6, 30
local MODE_PITCH = MODE_TILE_H + MODE_BLURB_GAP + MODE_BLURB_H + 14
local MODE_NOTE_Y = MODE_Y0 - 2 * MODE_PITCH - 4

local function modeLoaded(code)
  local m = PG[code]
  return type(m) == "table" and type(m.OpenDialog) == "function"
end

-- SetState rewrites the tile's sub-line on every call (it takes state, sub and
-- reason together, because on the Games grid those three always change at
-- once). A mode tile's sub-line is FIXED copy rather than live status, so it has
-- to be handed back in on every repaint or the first refresh silently blanks it.
local function refreshModeTiles()
  for i = 1, #modeTiles do
    local t = modeTiles[i]
    if modeLoaded(t.__pgCode) then
      t:SetState("ready", t.__pgModeSub)
    else
      t:SetState("off", t.__pgModeSub, "This mode did not load. Reload your interface.")
    end
  end
end

local function buildPullBookPage(p)
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local Font = (PG.Theme and PG.Theme.FontTemplate) or nil
  local top = p.__pgTop or -8

  local head = p:CreateFontString(nil, "OVERLAY", Font and Font("T") or "GameFontNormal")
  head:SetPoint("TOPLEFT", INSET, top - 6)
  head:SetPoint("TOPRIGHT", -INSET, top - 6)
  head:SetJustifyH("CENTER")
  head:SetWordWrap(false)
  head:SetMaxLines(1)
  head:SetText("TWO BOOKS")
  if C then head:SetTextColor(C.BRASS[1], C.BRASS[2], C.BRASS[3]) end
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(head) end

  local blurb = p:CreateFontString(nil, "OVERLAY", Font and Font("S")
    or "GameFontHighlightSmall")
  blurb:SetPoint("TOPLEFT", INSET, top - 26)
  blurb:SetPoint("TOPRIGHT", -INSET, top - 26)
  blurb:SetJustifyH("CENTER")
  blurb:SetWordWrap(true)
  blurb:SetMaxLines(2)
  blurb:SetText("Same bookie, two very different bets. Pick the one you are "
    .. "about to run.")
  if C then blurb:SetTextColor(C.CHGRAY[1], C.CHGRAY[2], C.CHGRAY[3]) end

  for i = 1, #MODES do
    local mode = MODES[i]
    local t = PG.UI.GameTile(p, {
      code = mode.code, label = mode.label,
      width = MODE_TILE_W, height = MODE_TILE_H,
      onClick = function(self)
        local m = PG[self.__pgCode]
        if type(m) == "table" and type(m.OpenDialog) == "function" then m.OpenDialog() end
      end,
    })
    t:SetPoint("TOP", p, "TOP", 0, MODE_Y0 - (i - 1) * MODE_PITCH)
    t.__pgModeSub = mode.sub
    modeTiles[i] = t

    local line = p:CreateFontString(nil, "OVERLAY", Font and Font("S")
      or "GameFontHighlightSmall")
    line:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 2, -MODE_BLURB_GAP)
    line:SetPoint("TOPRIGHT", t, "BOTTOMRIGHT", -2, -MODE_BLURB_GAP)
    line:SetJustifyH("LEFT")
    line:SetJustifyV("TOP")
    line:SetHeight(MODE_BLURB_H)
    line:SetWordWrap(true)
    line:SetMaxLines(2)
    line:SetText(mode.blurb)
    if C then line:SetTextColor(C.CHGRAY[1], C.CHGRAY[2], C.CHGRAY[3]) end
  end

  -- The "why is this two things" answer, on the page where the question is
  -- asked, in player language and with no addon jargon in it.
  local note = p:CreateFontString(nil, "OVERLAY", Font and Font("S")
    or "GameFontHighlightSmall")
  note:SetPoint("TOPLEFT", INSET, MODE_NOTE_Y)
  note:SetPoint("TOPRIGHT", -INSET, MODE_NOTE_Y)
  note:SetJustifyH("CENTER")
  note:SetJustifyV("TOP")
  note:SetHeight(66)
  note:SetWordWrap(true)
  note:SetMaxLines(5)
  note:SetText("Blizzard switches addon chat off for the whole of a Mythic+ run, "
    .. "so nothing can be agreed, changed or cancelled once the key is in. That "
    .. "is why the parley is a separate book: everything is settled before you "
    .. "start, and the result comes back when the key ends.")
  if C then note:SetTextColor(C.CHGRAY[1], C.CHGRAY[2], C.CHGRAY[3]) end
end

-- "Tonight: +340g across 4 games." - the one line of ledger on the home page.
local function refreshTonight()
  if not tonightFS then return end
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local sessions = (PG.Ledger and PG.Ledger.Sessions) and PG.Ledger.Sessions() or {}
  local n = #sessions
  if n == 0 then
    tonightFS:SetText("No games settled tonight.")
    return
  end
  local me, net = PG.FullName(), 0
  local rows = (PG.Ledger and PG.Ledger.Tonight) and PG.Ledger.Tonight() or {}
  for i = 1, #rows do
    if rows[i].name == me then net = rows[i].net end
  end
  local amount = (net >= 0 and "+" or "") .. PG.Money(net)
  if C then
    amount = ((net > 0 and C.chgreen) or (net < 0 and C.chred) or C.chgray)
      .. amount .. "|r"
  end
  tonightFS:SetText("Tonight: " .. amount .. " across " .. n
    .. (n == 1 and " game." or " games."))
end

-------------------------------------------------------------------------------
-- The footer: the DND sign, and the status line that indexes the six separate
-- play windows (PLAN 1.3). It reads the registry, never a window's visibility.
-------------------------------------------------------------------------------

refreshFooter = function()
  if not statusBtn then return end
  refreshDnd()
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local seat = (PG.Session and PG.Session.Seat) and PG.Session.Seat() or nil
  local opens = #visibleRows()
  if seat then
    local who = (seat.host == PG.FullName()) and "your game"
      or (shortOf(seat.host) .. "'s game")
    statusBtn.label:SetText((GAME_NAME[seat.module] or "A game")
      .. " running - " .. who)
    if C then statusBtn.label:SetTextColor(C.CHALK[1], C.CHALK[2], C.CHALK[3]) end
    statusBtn:SetAlpha(1)
    statusBtn.__pgAction = "raise"
    statusBtn.__pgSeat = seat
  elseif opens > 0 then
    statusBtn.label:SetText(opens .. (opens == 1 and " game open" or " games open")
      .. " - click to see")
    if C then statusBtn.label:SetTextColor(C.CHGOLD[1], C.CHGOLD[2], C.CHGOLD[3]) end
    statusBtn:SetAlpha(1)
    statusBtn.__pgAction = "games"
    statusBtn.__pgSeat = nil
  else
    statusBtn.label:SetText("/pg for commands   -   right-click: back")
    if C then statusBtn.label:SetTextColor(C.CHGRAY[1], C.CHGRAY[2], C.CHGRAY[3]) end
    statusBtn:SetAlpha(0.4)
    statusBtn.__pgAction = nil
    statusBtn.__pgSeat = nil
  end
end

local function buildFooter(shell)
  local footer = PG.UI.Shell.Footer()
  dndBtn = PG.UI.Button(footer, "", 96, 20, function()
    PG.ToggleDND()
    refreshFooter()
    dndTip(dndBtn)          -- the sign you just flipped explains itself
  end)
  dndBtn:SetPoint("LEFT", 0, 0)
  dndBtn:HookScript("OnEnter", dndTip)
  dndBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

  statusBtn = CreateFrame("Button", nil, footer)
  statusBtn:SetPoint("LEFT", dndBtn, "RIGHT", 8, 0)
  statusBtn:SetPoint("RIGHT", 0, 0)
  statusBtn:SetHeight(20)
  statusBtn.label = statusBtn:CreateFontString(nil, "OVERLAY",
    (PG.Theme and PG.Theme.FontTemplate) and PG.Theme.FontTemplate("S")
    or "GameFontHighlightSmall")
  statusBtn.label:SetPoint("LEFT")
  statusBtn.label:SetPoint("RIGHT")
  statusBtn.label:SetJustifyH("RIGHT")
  statusBtn.label:SetWordWrap(false)
  statusBtn.label:SetMaxLines(1)
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(statusBtn.label) end
  statusBtn:SetScript("OnClick", function(self)
    if self.__pgAction == "raise" then
      local s = self.__pgSeat
      if s and WIN_KEY[s.module] then PG.UI.RaiseWindow(WIN_KEY[s.module]) end
    elseif self.__pgAction == "games" then
      PG.UI.Shell.Focus("games")
    end
  end)

  -- The shell's own show/hide drives the ticker and one honest repaint: the
  -- list is rebuilt from the modules' records on every show, so it can never
  -- present a game that ended while the window was closed.
  shell:HookScript("OnShow", function()
    reconcile()
    refreshList()
    refreshFooter()
    syncListTicker()
  end)
  shell:HookScript("OnHide", syncListTicker)
  refreshFooter()
end

-------------------------------------------------------------------------------
-- The Games page
-------------------------------------------------------------------------------

local function buildGamesPage(p)
  local C = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  local Font = (PG.Theme and PG.Theme.FontTemplate) or nil

  local tagline = p:CreateFontString(nil, "OVERLAY", Font and Font("S")
    or "GameFontHighlightSmall")
  tagline:SetPoint("TOPLEFT", INSET, TAG_Y)
  tagline:SetPoint("TOPRIGHT", -INSET, TAG_Y)
  tagline:SetJustifyH("CENTER")
  tagline:SetWordWrap(false)
  tagline:SetMaxLines(1)
  tagline:SetText("Step right up - games, wagers, glory")
  if C then tagline:SetTextColor(C.BRASS[1], C.BRASS[2], C.BRASS[3]) end

  -- The picker. Six anchored buttons, 2 columns x 3 rows: at 190x104 a tile is
  -- 109% of Blizzard's own dungeon button and the art crops with 0.8% stretch.
  for i = 1, #GAMES do
    local code, label = GAMES[i][1], GAMES[i][2]
    local col = (i <= 3) and 1 or 2
    local row = ((i - 1) % 3) + 1
    local t = PG.UI.GameTile(p, {
      code = code, label = label, width = TILE_W, height = TILE_H,
      onClick = tileClick,
    })
    t:SetPoint("TOPLEFT", (col == 1) and TILE_X1 or TILE_X2,
      GRID_Y - (row - 1) * (TILE_H + TILE_GAP_Y))
    tiles[#tiles + 1] = t
  end

  local div = p:CreateTexture(nil, "ARTWORK")
  div:SetPoint("TOPLEFT", INSET, DIV_Y)
  div:SetPoint("TOPRIGHT", -INSET, DIV_Y)
  div:SetHeight(1)
  div:SetColorTexture(0.12, 0.12, 0.13, 1)

  local head = p:CreateFontString(nil, "OVERLAY", Font and Font("T") or "GameFontNormal")
  head:SetPoint("TOPLEFT", INSET, HEAD_Y)
  head:SetPoint("TOPRIGHT", -INSET, HEAD_Y)
  head:SetJustifyH("CENTER")
  head:SetWordWrap(false)
  head:SetMaxLines(1)
  head:SetText("OPEN GAMES")
  if C then head:SetTextColor(C.BRASS[1], C.BRASS[2], C.BRASS[3]) end
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(head) end

  buildOpenRows(p)

  tonightFS = p:CreateFontString(nil, "OVERLAY", Font and Font("S")
    or "GameFontHighlightSmall")
  tonightFS:SetPoint("TOPLEFT", INSET, TONIGHT_Y)
  tonightFS:SetPoint("TOPRIGHT", -INSET, TONIGHT_Y)
  tonightFS:SetJustifyH("CENTER")
  tonightFS:SetWordWrap(false)
  tonightFS:SetMaxLines(1)
  if C then tonightFS:SetTextColor(C.CHGRAY[1], C.CHGRAY[2], C.CHGRAY[3]) end
end

local function showGamesPage()
  reconcile()
  refreshList()
  refreshTiles()
  refreshTonight()
  refreshFooter()
  syncListTicker()
end

local function openSound()
  if PG.Theme and PG.Theme.Sound then
    PG.Theme.Sound("open") -- manual open only; gated inside Theme.Sound
  end
end

-- Unchanged signatures. They mean "open the shell on the Games page" now.
function PG.Launcher.Show()
  local S = PG.UI and PG.UI.Shell
  if not S then return end
  local wasShown = S.IsShown()
  S.Focus("games")
  if not wasShown then openSound() end
end

function PG.Launcher.Toggle()
  local S = PG.UI and PG.UI.Shell
  if not S then return end
  local opening = not (S.IsShown() and S.Current() == "games")
  S.Toggle("games")
  if opening then openSound() end
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
    GameTooltip:AddLine("Left-click: games, ledger, rules, settings", 1, 1, 1)
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
  -- The four hub windows became pages inside the shell, so these keys are now
  -- written by nothing and read by nothing. Purged here for the same reason each
  -- game purges its old *dialog key: PG.UI.ResetLayout and the global scale pass
  -- both walk this table, and dead entries make them do work for windows that
  -- cannot exist. "launcher" is NOT migrated to "main" - the shell is a different
  -- size and shape, so an inherited point would place it somewhere the old
  -- window happened to sit rather than somewhere sensible.
  if PG.db and PG.db.profile and type(PG.db.profile.positions) == "table" then
    local pos = PG.db.profile.positions
    pos.launcher, pos.ledger, pos.rules, pos.settings = nil, nil, nil, nil
  end

  -- The Games page is the shell's home. Registered at init, built lazily on
  -- the first open, so the shell costs less at load than the nine windows it
  -- replaces.
  if PG.UI and PG.UI.Shell then
    PG.UI.Shell.RegisterPage("games", {
      build = buildGamesPage,
      onShow = showGamesPage,
    })
    -- Level 2, behind the Games nav item: the Pull Book tile pushes it and Back
    -- (or a right-click) comes straight back out to the grid. Registered
    -- unconditionally - if BOTH modes failed to load, the page still opens and
    -- both tiles say so, which beats a tile that does nothing when clicked.
    PG.UI.Shell.RegisterPage("setup:PB", {
      title = "Pull Book",
      level = 2,
      nav = "games",
      accent = "PB",
      build = buildPullBookPage,
      onShow = refreshModeTiles,
    })
    PG.UI.Shell.OnBuild(buildFooter)
  end
  if not mmDB().hide then buildMinimapButton() end
  -- The seat is what disables a Join (5.10 rule 3) and what decides a tile's
  -- state, so both unlock the instant a game ends and lock the instant one is
  -- accepted - without waiting for the next ticker pass.
  if PG.Session and PG.Session.OnChange then
    PG.Session.OnChange(function()
      refreshList()
      refreshTiles()
      refreshFooter()
    end)
  end
end)
