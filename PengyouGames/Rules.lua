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

-- Each page wears its own game's skin, so the Rules page for a game looks like
-- the game. Re-checked at 1.1.0 against what the six game files actually build:
-- Loot Goblins is the only goblin-skinned window in the suite; The Pull Book,
-- Rock Paper Scissors, Death Roll, The Gambler and Quiz all build faire ones.
-- So this one-liner is still exactly right for six pages and does not need to
-- become a table - but if a future game picks goblin, this is the line.
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
  DR = {
    title = "Death Roll",
    tagline = "Roll under the last one. Roll a 1 and you are out.",
    blocks = {
      { "h", "The idea" },
      { "p", "Everyone puts up the same wager - 100g by default, and the "
        .. "starting roll matches it unless the host changes it. Play goes one "
        .. "player at a time around the table, and whatever you roll becomes "
        .. "the ceiling for the player after you. The numbers fall fast." },
      { "h", "Your turn" },
      { "p", "When it is your turn the window tells you exactly what to type - "
        .. "for example /roll 743 - and a timer runs. You can type it yourself "
        .. "or press the ROLL button, which asks your own client to make that "
        .. "same roll. Either way it is a real, ordinary roll that lands in "
        .. "everyone's chat." },
      { "b", "Roll a 1 and you are out. Everyone else plays on, starting again "
        .. "from the opening number." },
      { "b", "Roll anything else and it becomes the next player's ceiling." },
      { "b", "Roll the wrong range and it does not count - you are told so and "
        .. "the timer keeps running." },
      { "b", "Run out of time and you are out exactly as if you had rolled a 1. "
        .. "The table does not wait." },
      { "h", "Winning and losing" },
      { "p", "The last player standing takes the pot: everyone who went out "
        .. "pays one wager and the survivor collects all of them. With two "
        .. "players that is simply the loser paying the winner - the old duel, "
        .. "unchanged." },
      { "h", "If you drop out" },
      { "p", "Say it plainly: a disconnect costs you the wager. If you vanish "
        .. "the table gives you a few seconds and then times your turn out, "
        .. "which puts you out of the game like any other missed turn. Nobody "
        .. "can tell a dropped connection from a slow decision, and a game that "
        .. "waited for one would stall for everybody." },
      { "h", "About the gold" },
      { "p", "All gold here is virtual and the addon never moves a single "
        .. "copper. Settling up is manual and on the honour system - trade or "
        .. "mail it afterwards, or agree to ignore the whole thing. If a game "
        .. "is abandoned or the host disconnects, nobody owes anybody." },
      { "h", "Everyone can see the rolls" },
      { "p", "The rolls are ordinary rolls, so they appear in the chat of "
        .. "everyone in your group, including people without the addon. That is "
        .. "the point rather than a side effect. Nothing else about the game is "
        .. "ever printed anywhere." },
      { "p", "It also means nobody has to trust anybody's screen. Your own copy "
        .. "of the game works out who won from the rolls it watched land, and "
        .. "compares that with what the host announces. If the two disagree, or "
        .. "if you missed part of the game, your copy records nothing at all "
        .. "and tells you why." },
      { "h", "Why it is party only" },
      { "p", "A roll only reaches the group you are standing in, so only your "
        .. "own party or raid can see the same rolls you do. A guildmate in a "
        .. "city would be asked to bet gold on evidence they cannot see, so "
        .. "guild and public are not offered here at all." },
      { "h", "Interruptions" },
      { "p", "A boss pull, ready check or pull timer hides everything instantly "
        .. "and your turn picks up afterwards with a fresh timer. Rolls made "
        .. "while the game is hidden do not count, for anyone. Ordinary combat "
        .. "does not interrupt the game at all." },
    },
  },
  GB = {
    title = "The Gambler",
    tagline = "Everyone rolls once. The lowest pays the highest.",
    blocks = {
      { "h", "The idea" },
      { "p", "One roll each, and the whole game is over in half a minute. The "
        .. "host sets the biggest number anyone can roll - 1000 by default - "
        .. "everyone rolls it once inside a single timed window, and the lowest "
        .. "roll pays the highest roll the difference between the two." },
      { "p", "So if the low roll is 12 and the high roll is 964, that is 952g "
        .. "from one player to the other, and everybody in between pays and "
        .. "receives nothing at all. The stake is never fixed in advance, which "
        .. "is what makes the window worth watching." },
      { "h", "Rolling" },
      { "b", "The window tells you exactly what to type. You can type it "
        .. "yourself or press ROLL, which asks your own client to make the same "
        .. "roll." },
      { "b", "Your first roll of the right size is the one that counts. Rolling "
        .. "again changes nothing." },
      { "b", "Roll the wrong size and it does not count - you are told, and you "
        .. "can still roll properly before the timer ends." },
      { "b", "Do not roll at all and you are simply not in it. You pay nothing "
        .. "and win nothing." },
      { "h", "Ties" },
      { "p", "If two or more players tie for lowest they split the bill between "
        .. "them; if they tie for highest they split the winnings. If everybody "
        .. "rolls the same number, or only one person rolls, there is no "
        .. "difference to pay and nothing changes hands." },
      { "h", "A word about 100" },
      { "p", "100 is the number a bare roll produces, so a game set to 100 will "
        .. "quietly count somebody's loot roll as their entry. The host is "
        .. "warned when they pick it. Any other number is safer." },
      { "h", "About the gold" },
      { "p", "All gold here is virtual and the addon never moves a single "
        .. "copper. Settling up is manual and on the honour system. If the game "
        .. "is abandoned or the host disconnects, nothing at all is recorded." },
      { "h", "Everyone can see the rolls" },
      { "p", "The rolls are ordinary rolls, so your whole group sees them in "
        .. "chat whether or not they have the addon. That is what makes the "
        .. "result impossible to argue with." },
      { "p", "It is not just a nice idea either: your own copy of the game "
        .. "works out the result from the rolls it watched land, and refuses to "
        .. "record anything if that disagrees with what the host announces - or "
        .. "if you were away and missed one of the two rolls that decided it." },
      { "h", "Why it is party only" },
      { "p", "A roll only reaches the group you are standing in, so only your "
        .. "own party or raid can see the same rolls you do." },
      { "h", "Interruptions" },
      { "p", "A boss pull, ready check or pull timer hides everything instantly "
        .. "and the roll window re-opens afterwards, with time put back on the "
        .. "clock. Rolls made while the game is hidden do not count, for "
        .. "anyone. Ordinary combat does not interrupt the game at all." },
      { "h", "Playing again" },
      { "p", "Each game is a single round. Play again and it is a brand new "
        .. "game, with a fresh join window, so nobody is ever committed to more "
        .. "than the round in front of them." },
    },
  },
  QZ = {
    title = "Quiz",
    tagline = "No gold. Just how fast you know things.",
    blocks = {
      { "h", "The idea" },
      { "p", "The host ticks which kinds of question to use and how many to "
        .. "ask. Everyone gets the same question at the same moment, types an "
        .. "answer into the quiz window, and the answers stay private until the "
        .. "timer ends. Nothing is ever posted to chat - your answer goes "
        .. "straight to the host and nowhere else." },
      { "h", "The four kinds" },
      { "b", "Trivia - a question, and you type the answer. Near misses and "
        .. "the usual alternative spellings are accepted." },
      { "b", "Two Truths and a Lie - three statements, and you name the one "
        .. "that is false." },
      { "b", "Unscramble - the letters of a word, jumbled. Type the word." },
      { "b", "Type Race - a phrase on screen. Type it exactly, fastest wins." },
      { "h", "Scoring" },
      { "p", "Everyone who gets it right scores. The first correct answer is "
        .. "worth 3 points, the second 2, and every other correct answer 1. "
        .. "That way being quick is worth something without leaving a player on "
        .. "a bad connection unable to score at all." },
      { "b", "A wrong answer costs nothing. Not answering costs nothing." },
      { "b", "The host can turn on a hint that appears halfway through the "
        .. "timer, if the group would rather have a gentler game." },
      { "h", "Finishing" },
      { "p", "Points add up across the questions. At the end you get a podium - "
        .. "first, second and third by total points, with ties sharing a place "
        .. "- and gold medals are remembered between raid nights." },
      { "p", "There is no buy-in and nothing is ever added to the ledger. This "
        .. "game cannot cost anybody a copper, which is why it is the one game "
        .. "besides Rock Paper Scissors that strangers can safely be invited "
        .. "to." },
      { "h", "Everyone needs the same questions" },
      { "p", "The questions live inside the addon rather than being sent "
        .. "around, so everyone playing needs the same version of Pengyou "
        .. "Games. If yours does not match the host's you are told so and left "
        .. "out, instead of being quietly shown a different question from "
        .. "everybody else." },
      { "p", "Since the questions ship with the addon, so do the answers: "
        .. "anyone determined to look them up can. This is a game for people "
        .. "who would rather not." },
      { "h", "Interruptions" },
      { "p", "Same as every game here: encounters, ready checks and pull timers "
        .. "hide it instantly and it picks up afterwards, with time put back on "
        .. "the clock. A question interrupted by a boss pull is thrown away and "
        .. "replaced rather than asked to a room that has already seen it. "
        .. "Ordinary combat is fine." },
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
  -- Appended to EVERY page, so it has to be true of all six games. At 1.1.0 the
  -- old one-liner ("you can only play one game at a time") stopped being true
  -- in two directions at once: five games now share the one seat rather than
  -- two, and hosting a game you do not play in has always been allowed. Both
  -- halves are stated here rather than left to the README, because far more
  -- people read this window than read the README.
  out[#out + 1] = { "p", "You choose the audience when you start the game." }
  out[#out + 1] = { "p", "You play one game at a time. Loot Goblins, Rock Paper "
    .. "Scissors, Death Roll, The Gambler and Quiz all want your full "
    .. "attention, so while you are in one of them the invites for the others "
    .. "wait. The Pull Book is the exception: it is passive betting on your own "
    .. "pulls and runs alongside anything." }
  out[#out + 1] = { "p", "Any number of games can be running around you, and "
    .. "you can always start one for other people even while you are playing "
    .. "something else - you simply run it without playing in it yourself." }
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

-- The tab strip, in launcher order. Six tabs no longer fit one row: at the
-- shipped 126px width plus a 4px gap that is 6 * 130 = 780px inside a 420px
-- window. The three options were narrower tabs, abbreviated labels, or a second
-- row - and the first two both break "Rock Paper Scissors", which is the whole
-- reason the tab is 126px wide in the first place. So: TWO ROWS OF THREE, tabs
-- unchanged at 126x22, row 1 the 1.0.0 games and row 2 the 1.1.0 games, which
-- is the same grouping the launcher grid uses.
--
-- The arithmetic, so nobody has to re-measure it: x = 14 + col * 130 puts the
-- three columns at 14, 144 and 274, and the rightmost tab ends at 400, leaving
-- a 20px right margin in the 420px window. y = -38 - row * 26 (22 button + 4
-- gap) puts row 1 at -38..-60 and row 2 at -64..-86, which clears the scroll
-- frame's new top edge at -96.
local TAB_ORDER = {
  { "LG", "Loot Goblins" }, { "PB", "Pull Book" }, { "RPS", "Rock Paper Scissors" },
  { "DR", "Death Roll" }, { "GB", "The Gambler" }, { "QZ", "Quiz" },
}

local function build()
  -- 480 -> 506: the second tab row costs exactly 26px and the scroll top drops
  -- by exactly 26, so the viewport is unchanged at 394px and no body content is
  -- lost. Only the point and the per-window scale are persisted, never a size,
  -- so this is safe for a user who already has a Rules window position saved.
  win = PG.UI.Window("rules", "Rules", 420, 506, "neutral")

  tabs = {}
  for i = 1, #TAB_ORDER do
    local key, label = TAB_ORDER[i][1], TAB_ORDER[i][2]
    local col = (i - 1) % 3
    -- math.floor, not an integer-division operator: WoW Lua is 5.1 and has none
    local row = math.floor((i - 1) / 3)
    local b = PG.UI.Button(win, label, 126, 22, function() render(key) end)
    b:SetPoint("TOPLEFT", 14 + col * 130, -38 - row * 26)
    tabs[key] = b
  end

  -- scroll area
  scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -96)
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

-- key (optional): "LG" | "PB" | "RPS" | "DR" | "GB" | "QZ". Anything else -
-- including a game whose file failed to load - falls back to the last page
-- viewed and then to Loot Goblins, so every game's Rules button is safe to
-- press unconditionally.
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
