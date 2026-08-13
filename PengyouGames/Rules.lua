-- Rules.lua - the "how do I play this?" explainer, one page per game.
--
-- Pure presentation: this file reads nothing but the theme layer and writes
-- nothing at all. It never touches a session, the wire or the ledger, so it is
-- safe to open at any moment - including while a game is running.
local ADDON, PG = ...

PG.Rules = {}

local win, body, tabs, scroll
local current

-- Window geometry. 420x548 is the same rect the Ledger uses, so the two
-- reference windows of the hub are one size and one set of insets.
local WIN_W, WIN_H = 420, 548

-- Rendering helpers -----------------------------------------------------------

-- There was a themeOf(key) here that returned "goblin" for Loot Goblins and
-- "faire" for the other five, and a nine-line comment explaining the split. It
-- never rendered: Theme.C has always ignored its argument and returned one
-- frozen union table, and palette() below never branched on the name either.
-- All six pages have always looked identical. Deleting it is documenting what
-- already happened, not flattening a design.
--
-- What a page DOES get of its game's identity is real and is new: its accent
-- mark on its tab, its accent colour in the rule under the page header, and
-- its own name and tagline at the top of the page - which is the first time
-- since the window shipped that a Rules page says which game it describes.

local function mark(key)
  if PG.Theme and PG.Theme.Mark then return PG.Theme.Mark(key) end
  return ""
end

local function accent(key)
  if PG.Theme and PG.Theme.Accent then return PG.Theme.Accent(key) end
  return nil
end

local function shadow(fs)
  if PG.Theme and PG.Theme.Shadow then PG.Theme.Shadow(fs) end
end

local function fontOf(which)
  if PG.Theme and PG.Theme.FontTemplate then return PG.Theme.FontTemplate(which) end
  return "GameFontHighlight"
end

local function setFont(fs, which)
  if PG.Theme and PG.Theme.SetFont then PG.Theme.SetFont(fs, which) end
  return fs
end

-- The shared spacing grid, with the shipped literals as the fallback.
local function metrics()
  local M = PG.Theme and PG.Theme.METRIC
  local top = ((M and M.TITLE_TOP) or -12)
  local titleH = ((M and M.TITLE_H) or 24)
  return {
    INSET   = (M and M.INSET) or 24,
    FIRST   = top - titleH - ((M and M.TITLE_GAP) or 20),
    SECTION = (M and M.SECTION) or 16,
    RELATED = (M and M.RELATED) or 8,
    LINE    = (M and M.LINE) or 4,
    FOOTER  = (M and M.FOOTER) or 16,
    BTN_H   = (M and M.BTN_H) or 22,
  }
end

-- Palette with literal fallbacks, so the page stays readable if the theme
-- layer is unavailable (same doctrine as the games). One ramp, no argument.
local function palette()
  local R = PG.Theme and PG.Theme.ROLE
  return {
    head = (R and R.title) or { 1.00, 0.85, 0.46 },
    body = (R and R.body) or { 0.95, 0.93, 0.87 },
    dim = (R and R.detail) or { 0.80, 0.68, 0.42 },
  }
end

-- The gold escape a selected tab's label is written with.
local function SEL_CODE()
  local c = (PG.Theme and PG.Theme.C) and PG.Theme.C() or nil
  return (c and c.chgold) or "|cffffd876"
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
        .. "chat like any other." },
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
      { "h", "The rolls are real rolls" },
      { "p", "Nothing here is a number the addon made up. You type /roll, the "
        .. "game itself picks the number, and it lands in your chat frame where "
        .. "you - and anybody standing next to you - can read it. That is the "
        .. "point rather than a side effect, and nothing else about the game is "
        .. "ever printed to chat." },
      { "p", "Your own copy of the addon watches your roll and sends it to the "
        .. "host, and that report is what the host scores. So everyone playing "
        .. "needs the addon: somebody without it has nothing to send their roll "
        .. "in with and cannot take part, though they can still watch. If the "
        .. "host ever records a different number for your roll than the one you "
        .. "saw, your copy tells you - for your own roll only." },
      { "h", "Playing outside your group" },
      { "p", "Guild and realm-wide games work exactly the same way: the rolls "
        .. "reach the table through the addon, so the other players do not have "
        .. "to be standing next to you to see them. The thing to remember is "
        .. "the gold - it is virtual and settling up is on the honour system, "
        .. "so a stranger who loses can simply log out. Keep the wager small "
        .. "with people you cannot find again." },
      { "h", "Interruptions" },
      { "p", "A boss pull, ready check or pull timer hides everything instantly "
        .. "and your turn picks up afterwards with a fresh timer. Rolls made "
        .. "while the game is hidden do not count, for anyone. Ordinary combat "
        .. "does not interrupt the game at all. If the host goes quiet in a "
        .. "guild or realm-wide game the table simply waits - they are probably "
        .. "in a boss fight - and picks up when they come back." },
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
      { "h", "The rolls are real rolls" },
      { "p", "The number is the game's, not the addon's. You roll it yourself "
        .. "and watch it land in your own chat frame, where anybody standing "
        .. "next to you can read it too - nobody has to take your word for it." },
      { "p", "Your own copy watches YOUR roll and sends it to the host, and "
        .. "that report is what the host scores. So a player without the addon "
        .. "cannot take part: there is nothing on their side to send their roll "
        .. "in. They can still watch." },
      { "h", "Playing outside your group" },
      { "p", "Guild and realm-wide games work exactly the same way, because "
        .. "the rolls reach the table through the addon rather than through "
        .. "your party chat. Remember that the gold is virtual and settling up "
        .. "is on the honour system: a stranger who loses can simply log out, "
        .. "so keep the number small with people you cannot find again." },
      { "h", "Interruptions" },
      { "p", "A boss pull, ready check or pull timer hides everything instantly "
        .. "and the roll window re-opens afterwards, with time put back on the "
        .. "clock. Rolls made while the game is hidden do not count, for "
        .. "anyone. Ordinary combat does not interrupt the game at all. In a "
        .. "guild or realm-wide game a host who goes quiet is usually in a boss "
        .. "fight, so the table waits for them rather than giving up." },
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
  local n = 0
  for i = 1, #SCOPE_ORDER do
    local s = SCOPE_ORDER[i]
    if supported[s] then
      n = n + 1
      out[#out + 1] = { "b", SCOPE_WORDS[s] }
    end
  end
  -- Appended to EVERY page, so it has to be true of all six games. At 1.1.0 the
  -- old one-liner ("you can only play one game at a time") stopped being true
  -- in two directions at once: five games now share the one seat rather than
  -- two, and hosting a game you do not play in has always been allowed. Both
  -- halves are stated here rather than left to the README, because far more
  -- people read this window than read the README.
  -- Five of the six games offer all three audiences and the sixth offers one,
  -- so this sentence has to know which page it is on: "you choose" in front of
  -- a picker with a single enabled segment reads as a bug in the picker.
  if n > 1 then
    out[#out + 1] = { "p", "You choose the audience when you start the game." }
  else
    out[#out + 1] = { "p", "There is nothing to choose here - this is the only "
      .. "audience this game can be played to, and the reason is above." }
  end
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

-- The bullet marker is its own FontString one column to the left of the text,
-- so a wrapped bullet hangs under its first line instead of wrapping flush
-- under the dash. It used to be a literal "- " inside the wrapped string, which
-- made every multi-line bullet read as an indented paragraph with a stray
-- hyphen - and the "Each round" list on the Loot Goblins page is the densest
-- list in the addon.
local BULLET_MARK_X = 16
local BULLET_TEXT_X = 28

local function render(key)
  local page = PAGES[key]
  if not (page and body) then return end
  current = key
  local pal = palette()
  local M = metrics()
  local acc = accent(key)

  -- release the previous page's fontstrings back to the pool
  for i = 1, #body.lines do
    body.lines[i]:Hide()
    body.lines[i]:ClearAllPoints()
  end
  -- the marker pool is SPARSE (bullets only), so it is swept by the line
  -- index it shares with body.lines and every slot is nil-checked
  for i = 1, #body.lines do
    local mk = body.marks[i]
    if mk then mk:Hide() end
  end

  -- The page header: the game's name, its accent rule and its tagline. Every
  -- one of the three is new content on the page. The tagline used to be
  -- anchored 4px ABOVE the scroll child's top edge, i.e. outside the
  -- ScrollFrame's clip rect, so it has never once rendered - which left six
  -- pages with nothing on them naming the game they describe.
  local title = mark(acc and acc.mark or "book")
  title = (title ~= "" and (title .. " ") or "") .. page.title
  body.header:SetText(title)
  body.header:SetTextColor(pal.head[1], pal.head[2], pal.head[3])
  body.tagline:SetText(page.tagline)
  body.tagline:SetTextColor(pal.dim[1], pal.dim[2], pal.dim[3])
  local rc = (acc and acc.color) or pal.head
  body.rule:SetColorTexture(rc[1], rc[2], rc[3], 0.9)

  local headH = body.header:GetStringHeight()
  local tagY = headH + M.LINE + 2 + M.RELATED
  body.rule:ClearAllPoints()
  body.rule:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(headH + M.LINE))
  body.rule:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(headH + M.LINE))
  body.tagline:ClearAllPoints()
  body.tagline:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -tagY)
  body.tagline:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -tagY)
  -- measured AFTER the anchor pair: an unbound FontString reports one line
  -- regardless of its text, so reading this first would put every block on the
  -- page 12px too high the one time a tagline wraps
  local tagH = body.tagline:GetStringHeight()

  local blocks = {}
  for i = 1, #page.blocks do blocks[i] = page.blocks[i] end
  local extra = scopeBlocks(key)
  for i = 1, #extra do blocks[#blocks + 1] = extra[i] end

  local y = -(tagY + tagH + M.SECTION)
  local used = 0
  local prevKind
  for i = 1, #blocks do
    local kind, text = blocks[i][1], blocks[i][2]
    -- Gaps bind a block to what FOLLOWS it: a heading takes the section gap
    -- above it and only the related gap below. The old loop added its extra
    -- 4px AFTER anchoring the heading, so every heading in the window was
    -- glued to the paragraph it was supposed to be separating from.
    if i > 1 then
      if kind == "h" then
        y = y - M.SECTION
      elseif kind == "b" and prevKind == "b" then
        y = y - M.LINE
      else
        y = y - M.RELATED
      end
    end
    used = used + 1
    local fs = body.lines[used]
    if not fs then
      fs = body:CreateFontString(nil, "OVERLAY", fontOf("B"))
      body.lines[used] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", body, "TOPLEFT", (kind == "b") and BULLET_TEXT_X or 0, y)
    fs:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    -- One body size for the whole hub. Rules used to set its body at 10pt
    -- while the Ledger and Settings set theirs at 12, and Rules carries by far
    -- the most prose of the three.
    setFont(fs, (kind == "h") and "T" or "B")
    fs:SetText(text)
    fs:SetTextColor((kind == "h") and pal.head[1] or pal.body[1],
                    (kind == "h") and pal.head[2] or pal.body[2],
                    (kind == "h") and pal.head[3] or pal.body[3])
    shadow(fs)
    fs:Show()
    if kind == "b" then
      local mk = body.marks[used]
      if not mk then
        mk = body:CreateFontString(nil, "OVERLAY", fontOf("B"))
        mk:SetWidth(BULLET_TEXT_X - BULLET_MARK_X)
        mk:SetJustifyH("LEFT")
        mk:SetWordWrap(false)
        mk:SetMaxLines(1)
        mk:SetText("-")
        body.marks[used] = mk
      end
      setFont(mk, "B")
      mk:SetTextColor(pal.dim[1], pal.dim[2], pal.dim[3])
      shadow(mk)
      mk:ClearAllPoints()
      mk:SetPoint("TOPLEFT", body, "TOPLEFT", BULLET_MARK_X, y)
      mk:Show()
    end
    y = y - fs:GetStringHeight()
    prevKind = kind
  end

  body:SetHeight(math.max(1, -y + M.SECTION))
  if scroll then scroll:SetVerticalScroll(0) end

  -- Tab painting: ONE selection idiom, the scope picker's. The selected tab is
  -- painted (accent tint + gold label), never dimmed - the file used to
  -- brighten the selected tab to alpha 1 and dim the rest to 0.55 while the
  -- Ledger, two clicks away, did the exact opposite and greyed its selected
  -- tab out. The colour escape is what renders a gold label through the
  -- disabled font object; keep it if this ever gets refactored.
  local SEL = SEL_CODE()
  for k, btn in pairs(tabs) do
    if k == key then
      btn:SetEnabled(false)
      btn:SetText(SEL .. btn.__pgLabel .. "|r")
      if btn.tint then btn.tint:Show() end
    else
      btn:SetEnabled(true)
      btn:SetText(btn.__pgLabel)
      if btn.tint then btn.tint:Hide() end
    end
    btn:SetAlpha(1)
  end
end

-- The tab strip, in launcher order. TWO ROWS OF THREE: six tabs have never fit
-- one row at any legible width, and row 1 is the 1.0.0 games / row 2 the 1.1.0
-- games, the same grouping the launcher grid uses.
--
-- The arithmetic, derived rather than restated: three columns of TAB_W with
-- TAB_GAP between them fill exactly the content column, so the strip's left
-- edge is the page inset and its right edge is the page inset - the tabs used
-- to start at x=14 while the scroll frame below them started at x=16 and the
-- rightmost tab stopped at 400, three different left/right values on one page.
--
-- "Rock Paper" rather than "Rock Paper Scissors": the full name filled 101 of
-- the old 126px tab (and 80% of it was one label while "Quiz" filled 20% of the
-- same width). The full name is not lost - it is now the page header, in the
-- largest text on the page, which is where a player looks to find out what
-- they are reading about.
local TAB_ORDER = {
  { "LG", "Loot Goblins" }, { "PB", "Pull Book" }, { "RPS", "Rock Paper" },
  { "DR", "Death Roll" }, { "GB", "The Gambler" }, { "QZ", "Quiz" },
}

-- UIPanelScrollFrameTemplate anchors its bar OUTSIDE the frame at x=+6, so a
-- -32 right inset left the bar's right edge under the window's border art.
local SCROLLBAR_RESERVE = 38

-- THE RULES ARE A PAGE NOW, not a window. 420x548 was already the content
-- slot's exact rect, so the tab strip, the scroll frame and every block below
-- them re-anchor to nothing: the only number that moves is the first element's
-- y, because a page has no title bar to clear.
--
-- This page is the reason the six play windows stay separate: the owner wants
-- to read the rules while a game is live, and it is safe to open at any moment
-- because this file reads nothing but the theme layer and writes nothing.
local function build(pageFrame)
  win = pageFrame
  if not win then return end

  local M = metrics()
  M.FIRST = win.__pgTop or M.FIRST
  local CONTENT_W = WIN_W - M.INSET * 2
  local TAB_GAP = 12
  local TAB_W = math.floor((CONTENT_W - TAB_GAP * 2) / 3)
  local TAB_PITCH = M.BTN_H + M.LINE

  -- No title write any more. The shell's title bar carries the wordmark on
  -- every level-1 page and the nav says which page you are on; WHICH GAME you
  -- are reading about is the page header inside the scroll child, which is the
  -- one place that answer was missing before.
  tabs = {}
  for i = 1, #TAB_ORDER do
    local key, label = TAB_ORDER[i][1], TAB_ORDER[i][2]
    local col = (i - 1) % 3
    -- math.floor, not an integer-division operator: WoW Lua is 5.1 and has none
    local row = math.floor((i - 1) / 3)
    local acc = accent(key)
    local glyph = mark(acc and acc.mark or "book")
    local full = (glyph ~= "" and (glyph .. " ") or "") .. label
    local b = PG.UI.Button(win, full, TAB_W, M.BTN_H, function() render(key) end)
    b:SetPoint("TOPLEFT", M.INSET + col * (TAB_W + TAB_GAP), M.FIRST - row * TAB_PITCH)
    b.__pgLabel = full
    -- the selected tab's paint, in the game's own accent
    local ac = (acc and acc.color) or { 0.45, 0.32, 0.68 }
    b.tint = b:CreateTexture(nil, "OVERLAY")
    b.tint:SetAllPoints()
    b.tint:SetColorTexture(ac[1], ac[2], ac[3], 0.16)
    b.tint:SetBlendMode("ADD")
    b.tint:Hide()
    tabs[key] = b
  end

  -- scroll area. Both insets are derived: the left is the page inset, the right
  -- is the page inset plus the scrollbar's own width.
  local stripH = TAB_PITCH * 2 - M.LINE
  scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", M.INSET, M.FIRST - stripH - M.SECTION)
  scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_RESERVE, M.FOOTER)

  body = CreateFrame("Frame", nil, scroll)
  body:SetSize(WIN_W - M.INSET - SCROLLBAR_RESERVE, 10)
  body.lines = {}
  body.marks = {}
  scroll:SetScrollChild(body)

  -- The page header block, INSIDE the scroll child's clip rect this time. The
  -- name and tagline are centred as one unit of chrome over the left-aligned
  -- prose below them; the 2px rule between them is the game's accent colour.
  body.header = body:CreateFontString(nil, "OVERLAY", fontOf("D2"))
  setFont(body.header, "D2")
  body.header:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  body.header:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  body.header:SetJustifyH("CENTER")
  body.header:SetWordWrap(false)
  body.header:SetMaxLines(1)
  shadow(body.header)

  body.rule = body:CreateTexture(nil, "ARTWORK")
  body.rule:SetHeight(2)

  body.tagline = body:CreateFontString(nil, "OVERLAY", fontOf("S"))
  body.tagline:SetJustifyH("CENTER")
  body.tagline:SetWordWrap(true)
  body.tagline:SetMaxLines(2)
  shadow(body.tagline)
end

-- key (optional): "LG" | "PB" | "RPS" | "DR" | "GB" | "QZ". Anything else -
-- including a game whose file failed to load - falls back to the last page
-- viewed and then to Loot Goblins, so every game's Rules button is safe to
-- press unconditionally.
-- Unchanged signature, unchanged meaning: the six in-game "Rules" buttons, the
-- slash command and the shell's nav all still call these. They focus the
-- shell's Rules page instead of opening a window.
function PG.Rules.Show(key)
  local S = PG.UI and PG.UI.Shell
  if S then S.Focus("rules", key) end
end

function PG.Rules.Toggle(key)
  local S = PG.UI and PG.UI.Shell
  if not S then return end
  if S.IsShown() and S.Current() == "rules" and (not key or key == current) then
    S.Hide()
  else
    PG.Rules.Show(key)
  end
end

PG.RegisterInit(function()
  if not (PG.UI and PG.UI.Shell) then return end
  PG.UI.Shell.RegisterPage("rules", {
    build = build,
    -- the arg is the game code a caller asked for; anything unknown - including
    -- a game whose file failed to load - falls back to the last page viewed and
    -- then to Loot Goblins, so every Rules button is safe to press
    onShow = function(_, key) render(PAGES[key] and key or current or "LG") end,
  })
end)
