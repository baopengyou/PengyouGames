-- tools/rulescover.lua -- proves rulesHash covers the WHOLE ruleset.
--
-- Rules.computeRulesHash already errors when an order array names something that
-- does not exist. Nothing checked the REVERSE direction: a value present in the
-- ruleset but absent from its order array is silently unhashed, and two clients
-- on different builds then compute an identical rulesHash, pass the A.11.1
-- handshake, and disagree about a number the sim uses. That surfaces as a
-- heartbeat mismatch mid-match instead of G.4's polite refusal -- the worst
-- possible moment for the failure the hash exists to prevent.
--
-- pairs() is legal HERE and only here: both A.5 grep checkers scan sim/ only,
-- and walking the ruleset in an arbitrary order is exactly the point -- this file
-- asks "is every key accounted for", a question whose answer cannot depend on
-- iteration order.
--
-- Usage: lua tools/rulescover.lua

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")

local fails = 0
local function fail(m)
  fails = fails + 1
  print("FAIL  " .. m)
end

-- Both directions: order array -> map (already enforced inside Rules) AND
-- map -> order array (the direction nothing checked, which let REASON sit
-- outside rulesHash while the file claimed full coverage).
local function cover(label, map, order)
  local named = {}
  for i = 1, #order do
    local k = order[i]
    if named[k] then fail(label .. ": duplicate key in order array: " .. tostring(k)) end
    named[k] = true
    if map[k] == nil then fail(label .. ": order names a missing key: " .. tostring(k)) end
  end
  for k in pairs(map) do
    if not named[k] then fail(label .. ": UNHASHED ruleset value: " .. tostring(k)) end
  end
end

cover("C", Rules.C, Rules.CONST_ORDER)
cover("REASON", Rules.REASON, Rules.REASON_ORDER)
for i = 1, #Rules.UNITS do
  cover("UNITS[" .. i .. "]", Rules.UNITS[i], Rules.UNIT_FIELDS)
end
for i = 1, #Rules.BUILDINGS do
  cover("BUILDINGS[" .. i .. "]", Rules.BUILDINGS[i], Rules.BUILDING_FIELDS)
end
-- M3: every field of every card must be named by CARD_FIELDS in both
-- directions, or a card value ships outside rulesHash and two builds that
-- disagree about it pass the handshake.
for i = 1, #Rules.CARDS do
  cover("CARDS[" .. i .. "]", Rules.CARDS[i], Rules.CARD_FIELDS)
end
if #Rules.CARDS ~= 40 then
  fail("card pool is not 40 cards: " .. #Rules.CARDS)
end
-- The wheel: a 5x5 of -1/0/+1 named by WHEEL_TYPES, and the hash walker walks
-- exactly #WHEEL_TYPES rows of #WHEEL_TYPES entries, so a ragged or oversized
-- matrix is a hashed-value escape.
if #Rules.WHEEL ~= #Rules.WHEEL_TYPES then
  fail("WHEEL row count differs from WHEEL_TYPES")
end
for i = 1, #Rules.WHEEL do
  if #Rules.WHEEL[i] ~= #Rules.WHEEL_TYPES then
    fail("WHEEL[" .. i .. "] is not " .. #Rules.WHEEL_TYPES .. " wide")
  end
  for j = 1, #Rules.WHEEL[i] do
    local w = Rules.WHEEL[i][j]
    if w ~= -1 and w ~= 0 and w ~= 1 then
      fail("WHEEL[" .. i .. "][" .. j .. "] outside -1..1")
    end
  end
end
if #Rules.CHANNELS ~= #Rules.CLAMPS then
  fail("CHANNELS and CLAMPS differ in length: " .. #Rules.CHANNELS .. " vs " .. #Rules.CLAMPS)
end
-- Every channel a card names must exist, in both the self and the foe column,
-- and the scoped-unit field must name a real unit.
for i = 1, #Rules.CARDS do
  local cd = Rules.CARDS[i]
  if cd.ch1 < 0 or cd.ch1 > #Rules.CHANNELS then fail("CARDS[" .. i .. "].ch1 is not a channel") end
  if cd.ch2 < 0 or cd.ch2 > #Rules.CHANNELS then fail("CARDS[" .. i .. "].ch2 is not a channel") end
  if cd.foeCh < 0 or cd.foeCh > #Rules.CHANNELS then fail("CARDS[" .. i .. "].foeCh is not a channel") end
  if cd.scopeUnit < 0 or cd.scopeUnit > #Rules.UNITS then fail("CARDS[" .. i .. "].scopeUnit is not a unit") end
  if cd.unlockBld < 0 or cd.unlockBld > #Rules.BUILDINGS then fail("CARDS[" .. i .. "].unlockBld is not a building") end
end

-- Derived lookups must actually equal their derivation, so a hand edit fails.
for i = 1, #Rules.UNITS do
  if Rules.UNIT_BY_KIND[Rules.UNITS[i].kind] ~= i then
    fail("UNIT_BY_KIND drifted from UNITS at " .. i)
  end
end
for i = 1, #Rules.BUILDINGS do
  if Rules.BUILDING_BY_LETTER[Rules.BUILDINGS[i].letter] ~= i then
    fail("BUILDING_BY_LETTER drifted from BUILDINGS at " .. i)
  end
end
for i = 1, #Rules.CHANNELS do
  if Rules.CH[Rules.CHANNELS[i]] ~= i then
    fail("CH drifted from CHANNELS at " .. i)
  end
end
for i = 1, #Rules.CARDS do
  if Rules.CARD_BY_KEY[Rules.CARDS[i].key] ~= i then
    fail("CARD_BY_KEY drifted from CARDS at " .. i)
  end
end
if Rules.UNIT_SPEAR ~= 1 or Rules.UNIT_HORSE ~= 2 or Rules.UNIT_BOW ~= 3 then
  fail("UNIT_* index constants do not match the UNITS order")
end

-- Every top-level ruleset key must be classified, so a NEW table added in M3
-- fails the build until someone decides whether rulesHash covers it.
--   h = hashed   s = structural order array   d = derived from a hashed table
--   x = the hash itself
local TOP = {
  RULESET_VERSION = "h", C = "h", CONST_ORDER = "s",
  UNIT_FIELDS = "s", UNITS = "h",
  UNIT_SPEAR = "d", UNIT_HORSE = "d", UNIT_BOW = "d", UNIT_BY_KIND = "d",
  BUILDING_FIELDS = "s", BUILDINGS = "h", BUILDING_BY_LETTER = "d",
  CHANNELS = "h", CH = "d", CLAMPS = "h", TIERS = "h",
  CARDS = "h", CARD_FIELDS = "s", CARD_BY_KEY = "d",
  WHEEL = "h", WHEEL_TYPES = "s",
  REASON = "h", REASON_ORDER = "s",
  rulesHash = "x", rulesHash36 = "x", recomputeHash = "x",
}
local classified = 0
for k in pairs(Rules) do
  if not TOP[k] then
    fail("new top-level ruleset key is not classified in rulescover.lua: " .. tostring(k))
  else
    classified = classified + 1
  end
end

if fails > 0 then
  print("FAILURES: " .. fails)
  os.exit(1)
end
print(string.format(
  "ruleset coverage: %d top-level keys, %d constants, %d units, %d buildings, "
  .. "%d channels, %d cards x %d fields, a %dx%d wheel, %d reason codes -- "
  .. "every value hashed, structural or derived",
  classified, #Rules.CONST_ORDER, #Rules.UNITS, #Rules.BUILDINGS,
  #Rules.CHANNELS, #Rules.CARDS, #Rules.CARD_FIELDS,
  #Rules.WHEEL_TYPES, #Rules.WHEEL_TYPES, #Rules.REASON_ORDER))
