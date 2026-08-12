-- Rules.lua - the "how do I play this?" explainer, one page per game.
--
-- Pure presentation: this file reads nothing but the theme layer and writes
-- nothing at all. It never touches a session, the wire or the ledger, so it is
-- safe to open at any moment - including while a game is running.
local ADDON, PG = ...

PG.Rules = {}

local win, body, tabs, scroll
local current

-- Rendering helpers -----------------------------------------------------------

local function themeOf(key)
  return (key == "LG") and "goblin" or "faire"
end

local function mark(key)
  if PG.Theme and PG.Theme.Mark then return PG.Theme.Mark(key) end
  return ""
end

local function shadow(fs)
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(fs) end
end

-- Palette with literal fallbacks, so the page stays readable if the theme
-- layer is unavailable (same doctrine as the games).
local function palette(themeName)
  local c = (PG.Theme and PG.Theme.C) and PG.Theme.C(themeName) or nil
  return {
    head = (c and c.CHGOLD) or { 1.00, 0.85, 0.46 },
    body = (c and c.CHALK) or { 0.95, 0.93, 0.87 },
    dim = (c and c.CHGRAY) or { 0.66, 0.66, 0.61 },
  }
end

-- The content ----------------------------------------------------------------
-- Each page is a flat list of blocks: { "h", text } heading,
-- { "p", text } paragraph, { "b", text } bullet. Deliberately written in
-- player language - no addon jargon, no file names, no wire talk.

local PAGES = {
  LG = {
    title = "Loot Goblins",
    tagline = "Everyone pays in. Only the greedy few get rich.",
    blocks = {
      { "h", "The idea" },
      { "p", "Everyone buys in with the same amount of gold. That pot is split "
        .. "across a handful of rounds, and each round you make one secret "
        .. "choice: SHARE or HOARD." },
      { "h", "Each round" },
      { "b", "A few people hoard (20% or fewer of those who clicked): the "
        .. "hoarders split 80% of the round's gold. Sharers get the scraps." },
      { "b", "Too many hoard (more than 20%): greed backfires. Hoarders get "
        .. "NOTHING and the sharers split everything." },
      { "b", "Nobody hoards: everyone splits the round evenly. Safe and dull." },
      { "b", "Everyone hoards: nobody gets anything and the gold rolls into "
        .. "the next round." },
      { "p", "In a small game there is always room for exactly one goblin: a "
        .. "lone hoarder always gets paid, however few of you are playing. The "
        .. "threshold only rises to two hoarders once ten people are clicking." },
      { "b", "Did not click in time? You simply score nothing that round. The "
        .. "game never waits for anyone." },
      { "h", "Winning and losing" },
      { "p", "At the end, your result is what you collected minus your buy-in. "
        .. "Collect more than you paid and you are up; the Settle Up screen "
        .. "then tells whoever is down to pay whoever is up." },
      { "h", "About the gold" },
      { "p", "All gold here is virtual and the addon never moves a single "
        .. "copper. Settling up is manual and on the honour system - trade or "
        .. "mail it afterwards, or agree to ignore the whole thing. If a game "
        .. "is abandoned or the host disconnects, nobody owes anybody." },
      { "h", "Interruptions" },
      { "p", "A boss pull, ready check or pull timer hides everything "
        .. "instantly, and the round resumes afterwards. Ordinary combat does "
        .. "not interrupt the game at all." },
    },
  },
  RPS = {
    title = "Rock Paper Scissors",
    tagline = "No gold. Just points, medals and bragging rights.",
    blocks = {
      { "h", "The idea" },
      { "p", "Best of three by default. Each round everyone secretly throws "
        .. "ROCK, PAPER or SCISSORS at the same time." },
      { "h", "Scoring" },
      { "p", "You score one point for every player you beat that round. Rock "
        .. "beats scissors, paper beats rock, scissors beats paper - as usual." },
      { "b", "Example: twelve players throw 5 rock, 3 paper, 4 scissors. Each "
        .. "rock player scores 4 (the scissors they smashed), each paper player "
        .. "scores 5, each scissors player scores 3." },
      { "b", "If everyone throws the same thing, nobody beats anybody and the "
        .. "whole round scores zero." },
      { "b", "Did not throw in time? You score nothing, and nobody scores for "
        .. "beating you." },
      { "h", "Finishing" },
      { "p", "Points add up across the rounds. At the end you get a podium: "
        .. "first, second and third by total points, with ties sharing a place. "
        .. "Gold medals are remembered between raid nights." },
      { "p", "There is no buy-in and nothing is ever added to the ledger." },
      { "h", "Interruptions" },
      { "p", "Same as every game here: encounters and pull timers hide it "
        .. "instantly and it picks up afterwards. Ordinary combat is fine." },
    },
  },
  PB = {
    title = "The Pull Book",
    tagline = "Bet on the pull you are about to make.",
    blocks = {
      { "h", "The idea" },
      { "p", "One player opens the book as the bookie and sets the stake. From "
        .. "then on, a small betting strip appears at every ready check and "
        .. "pull timer - during the ten seconds you already spend staring at "
        .. "the countdown." },
      { "h", "The markets" },
      { "b", "Kill? YES or NO - does this attempt kill the boss?" },
      { "b", "First death - which role dies first: TANK, HEALER or DPS?" },
      { "b", "Boss HP at the end - OVER or UNDER the line the bookie set. A "
        .. "kill counts as 0%, so UNDER wins." },
      { "p", "Click to bet; your first click on a market locks it in. Betting "
        .. "is optional and you can bet on as few markets as you like." },
      { "h", "How it pays" },
      { "p", "When the pull ends, each market settles on its own: everyone who "
        .. "lost pays the stake, and the winners split that pot evenly. A "
        .. "market with fewer than two bettors, or with everyone on the same "
        .. "side, is void and stakes come back." },
      { "p", "Results arrive quietly once the fight is over - never mid-pull." },
      { "h", "Why it is party only" },
      { "p", "The book is scored from the boss fight you are standing in, so "
        .. "only your own group can see the same result you do. Unlike the "
        .. "other games, it cannot be played guild-wide or publicly." },
    },
  },
}

-- Who can play with whom -----------------------------------------------------

local SCOPE_WORDS = {
  group = "Party or raid",
  guild = "Anyone in your guild, no group needed",
  public = "Anyone on your realm running the addon",
}
local SCOPE_ORDER = { "group", "guild", "public" }

local function scopeBlocks(key)
  local supported = (PG[key] and PG[key].SCOPES) or nil
  local out = { { "h", "Who can play" } }
  if type(supported) ~= "table" then
    out[#out + 1] = { "p", "Pick the audience from the dropdown when you start "
      .. "a game." }
    return out
  end
  for i = 1, #SCOPE_ORDER do
    local s = SCOPE_ORDER[i]
    if supported[s] then
      out[#out + 1] = { "b", SCOPE_WORDS[s] }
    end
  end
  out[#out + 1] = { "p", "You choose the audience when you start the game. You "
    .. "can only play one game at a time, but any number of games can be "
    .. "running around you - you will see an invite for each and pick the one "
    .. "you want." }
  return out
end

-- Layout ---------------------------------------------------------------------

local function render(key)
  local page = PAGES[key]
  if not (page and body) then return end
  current = key
  local pal = palette(themeOf(key))

  -- release the previous page's fontstrings back to the pool
  for i = 1, #body.lines do
    body.lines[i]:Hide()
    body.lines[i]:ClearAllPoints()
  end

  local blocks = {}
  for i = 1, #page.blocks do blocks[i] = page.blocks[i] end
  local extra = scopeBlocks(key)
  for i = 1, #extra do blocks[#blocks + 1] = extra[i] end

  local y = 0
  local used = 0
  for i = 1, #blocks do
    local kind, text = blocks[i][1], blocks[i][2]
    used = used + 1
    local fs = body.lines[used]
    if not fs then
      fs = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      body.lines[used] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", body, "TOPLEFT", (kind == "b") and 16 or 0, y)
    fs:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    if kind == "h" then
      fs:SetFontObject("GameFontNormal")
      fs:SetText(text)
      fs:SetTextColor(pal.head[1], pal.head[2], pal.head[3])
      if PG.Theme and PG.Theme.SetHeader then PG.Theme.SetHeader(fs, 15) end
      y = y - 4
    else
      fs:SetFontObject("GameFontHighlightSmall")
      fs:SetText((kind == "b" and "- " or "") .. text)
      fs:SetTextColor(pal.body[1], pal.body[2], pal.body[3])
    end
    shadow(fs)
    fs:Show()
    y = y - fs:GetStringHeight() - ((kind == "h") and 6 or 8)
  end

  body:SetHeight(math.max(1, -y + 8))
  if scroll then scroll:SetVerticalScroll(0) end

  -- tab highlighting
  for k, btn in pairs(tabs) do
    btn:SetAlpha(k == key and 1 or 0.55)
  end
  if win and win.title then
    win.title:SetText(mark("book") ~= "" and (mark("book") .. " Rules") or "Rules")
  end
  if body.tagline then
    body.tagline:SetText(page.title .. " - " .. page.tagline)
    body.tagline:SetTextColor(pal.dim[1], pal.dim[2], pal.dim[3])
  end
end

local function build()
  win = PG.UI.Window("rules", "Rules", 420, 480, "neutral")

  -- tab row: one per game, in launcher order
  tabs = {}
  local order = { { "LG", "Loot Goblins" }, { "PB", "Pull Book" }, { "RPS", "Rock Paper Scissors" } }
  local x = 14
  for i = 1, #order do
    local key, label = order[i][1], order[i][2]
    local b = PG.UI.Button(win, label, 126, 22, function() render(key) end)
    b:SetPoint("TOPLEFT", x, -38)
    tabs[key] = b
    x = x + 130
  end

  -- scroll area
  scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -70)
  scroll:SetPoint("BOTTOMRIGHT", -32, 16)

  body = CreateFrame("Frame", nil, scroll)
  body:SetSize(360, 10)
  body.lines = {}
  scroll:SetScrollChild(body)

  -- tagline sits above the blocks, inside the scroll child
  body.tagline = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  body.tagline:SetPoint("BOTTOMLEFT", body, "TOPLEFT", 0, 4)
  body.tagline:SetJustifyH("LEFT")
end

-- key (optional): "LG" | "PB" | "RPS". Defaults to the last page viewed, then
-- to Loot Goblins.
function PG.Rules.Show(key)
  if not win then build() end
  render(PAGES[key] and key or current or "LG")
  win:Show()
end

function PG.Rules.Toggle(key)
  if not win then build() end
  if win:IsShown() and (not key or key == current) then
    win:Hide()
  else
    PG.Rules.Show(key)
  end
end
