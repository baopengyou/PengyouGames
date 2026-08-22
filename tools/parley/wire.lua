-- Wire, gates, the card codec and settlement, driven through the real handler.
local ROOT = ...
package.path = ROOT .. "/tools/parley/?.lua;" .. package.path
local H = require("harness")
local check, recv, drain = H.check, H.recv, H.drain

local BOOKIE = "Grizzle-R"

-- The scenario is built so that ROUTE ORDER AND BOSS ORDER DISAGREE: the group
-- opens on Zul'jan (the journal's THIRD boss), walls there, and clears the
-- other two in one pull each. Every per-boss expectation below therefore only
-- comes out right if the module keys on dungeonEncounterID and never on
-- position - which is the whole reason this file exists.
--
-- Ara-Kara (391): 2926 Rav'i, 2906 The Writhing Coil, 2900 Zul'jan
local CARD = "T,X.6,L,O.3,P.1.1"
--   1  T          timed?                 -> Y
--   2  X.6        deaths over/under 6    -> 9 deaths, so OVER
--   3  L          first wall (boss pick) -> 2900, the LAST boss in the journal
--   4  O.3     Zul'jan one-shot?     -> 3 attempts, so NO
--   5  P.1.1   Rav'i attempts o/u 1 -> 1 attempt, and OVER is strict: UNDER
local ROSTER = "Rav'i,The Writhing Coil,Zul'jan"
local BOSSDATA = "3.3.5,1.1.2,2.1.1"   -- id.attempts.deaths, route order

local PICKS = {
  ["Ann-R"] = { "Y", "O", "3", "Y", "O" },
  ["Bob-R"] = { "N", "U", "1", "N", "U" },
  ["Cid-R"] = { "Y", "O", "3", "N", "U" },
  ["Dot-R"] = { "N", "U", "2", "N", "U" },
}

print("== a guild parley, from OPEN to settled ==")

H.ME = "Ann-R"
local A = H.newClient(ROOT, "Ann-R")

recv(A, "OPEN", "t1", BOOKIE, "guild", 100, 391, CARD, "G")
check("a guild OPEN raises an invitation rather than adopting", A.ask ~= nil)
check("and offers a launcher row", #A.MP.OpenGames() == 1)

A.ask.accept()
check("accepting joins it", #A.MP.OpenGames() == 0)

recv(A, "ROSTER", "t1", BOOKIE, "guild", 391, ROSTER)

for who, p in pairs(PICKS) do
  for i = 1, #p do recv(A, "BET", "t1", who, "guild", i, p[i], BOOKIE) end
end

recv(A, "LOCK", "t1", BOOKIE, "guild", 391, 12)
H.clock = H.clock + 5
recv(A, "RES", "t1", BOOKIE, "guild", "C", "Y", "9", "3", "300", "T",
  "3", "3", BOSSDATA)
drain(A)

local byIdx = H.byIndex(A)
check("all five lines settled", #A.commits == 5, #A.commits)

check("1 Timed?: YES wins", byIdx[1] and byIdx[1].rows["Ann-R"] == 100
  and byIdx[1].rows["Bob-R"] == -100, byIdx[1] and byIdx[1].rows["Ann-R"])
check("2 Deaths: 9 is OVER a line of 6", byIdx[2] and byIdx[2].rows["Ann-R"] == 100,
  byIdx[2] and byIdx[2].rows["Ann-R"])
check("3 First wall: Zul'jan (2900) wins even though it is the LAST boss",
  byIdx[3] and byIdx[3].rows["Ann-R"] == 100 and byIdx[3].rows["Cid-R"] == 100
    and byIdx[3].rows["Bob-R"] == -100 and byIdx[3].rows["Dot-R"] == -100,
  byIdx[3] and byIdx[3].rows["Ann-R"])
check("4 Zul'jan one-shot?: 3 attempts, so NO wins and Ann alone pays",
  byIdx[4] and byIdx[4].rows["Ann-R"] == -100 and byIdx[4].rows["Bob-R"] == 34
    and byIdx[4].rows["Cid-R"] == 33 and byIdx[4].rows["Dot-R"] == 33,
  byIdx[4] and byIdx[4].rows["Bob-R"])
check("5 Rav'i attempts: 1 attempt is not OVER a line of 1, so UNDER wins",
  byIdx[5] and byIdx[5].rows["Ann-R"] == -100 and byIdx[5].rows["Bob-R"] == 34,
  byIdx[5] and byIdx[5].rows["Ann-R"])

for i = 1, #A.commits do
  local c = A.commits[i]
  local tag = c.meta.id:match("(%d+)$")
  check("zero-sum on line " .. tag, c.sum == 0, c.sum)
  check("every row inside cap on line " .. tag, (function()
    for _, d in pairs(c.rows) do if d > c.meta.cap or d < -c.meta.cap then return false end end
    return true
  end)(), c.meta.cap)
  check("ledger id fits 96 bytes on line " .. tag, #c.meta.id <= 96, #c.meta.id)
  check("ledger label fits 48 bytes on line " .. tag, #(c.meta.label or "") <= 48,
    c.meta.label)
  check("vouch covers every row on line " .. tag, (function()
    for n in pairs(c.rows) do if not c.meta.vouch[n] then return false end end
    return true
  end)())
end

local net = {}
for _, c in ipairs(A.commits) do
  for n, d in pairs(c.rows) do net[n] = (net[n] or 0) + d end
end
check("the whole parley is zero-sum across every line",
  (net["Ann-R"] + net["Bob-R"] + net["Cid-R"] + net["Dot-R"]) == 0)
check("Cid backed four winners and finishes up 366", net["Cid-R"] == 366, net["Cid-R"])
check("the parley closed itself after settling", #A.MP.OpenGames() == 0)

-------------------------------------------------------------------------------
print()
print("== the card codec refuses anything it cannot agree on ==")
-------------------------------------------------------------------------------

local function opens(label, card, expectOpen)
  local C = H.newClient(ROOT, "Ann-R")
  H.ME = "Ann-R"
  recv(C, "OPEN", "tz", BOOKIE, "group", 100, 391, card, "P")
  -- a party-scope OPEN adopts on hearing, so "did it open" is "is there a bet
  -- window": OpenGames only lists parleys we are NOT in, so probe with a BET
  recv(C, "ROSTER", "tz", BOOKIE, "group", 391, ROSTER)
  recv(C, "BET", "tz", "Bob-R", "group", 1, "Y", BOOKIE)
  recv(C, "BET", "tz", "Cid-R", "group", 1, "N", BOOKIE)
  recv(C, "LOCK", "tz", BOOKIE, "group", 391, 12)
  H.clock = H.clock + 5
  recv(C, "RES", "tz", BOOKIE, "group", "C", "Y", "9", "3", "300", "T",
    "3", "3", BOSSDATA)
  drain(C)
  local opened = #C.commits > 0
  check(label, opened == expectOpen, opened and "opened" or "refused")
end

opens("a well-formed card opens", "T,X.6", true)
opens("six lines is one too many", "T,X.6,A.1,M.5,F,L", false)
opens("an unknown line type is refused", "T,Z.1", false)
opens("a duplicate (type, boss) is refused", "T,T", false)
opens("a duplicate per-boss line is refused", "O.3,O.3", false)
opens("an out-of-range over/under value is refused", "X.500", false)
opens("a missing boss id is refused", "O", false)
opens("trailing junk in an entry is refused", "T.9", false)
opens("an empty card is refused", "", false)
opens("two different bosses of the same type are fine", "O.3,O.1", true)

-------------------------------------------------------------------------------
print()
print("== bets that must not be recorded ==")
-------------------------------------------------------------------------------

local function betProbe(label, setup, expectPaid)
  local C = H.newClient(ROOT, "Ann-R")
  H.ME = "Ann-R"
  recv(C, "OPEN", "tb", BOOKIE, "group", 100, 391, "L,T", "P")
  recv(C, "ROSTER", "tb", BOOKIE, "group", 391, ROSTER)
  setup(C)
  recv(C, "LOCK", "tb", BOOKIE, "group", 391, 12)
  H.clock = H.clock + 5
  recv(C, "RES", "tb", BOOKIE, "group", "C", "Y", "9", "3", "300", "T",
    "3", "3", BOSSDATA)
  drain(C)
  check(label, (#C.commits > 0) == expectPaid, #C.commits .. " commits")
end

betProbe("a boss-pick bet naming a boss NOT on the roster is dropped", function(C)
  recv(C, "BET", "tb", "Bob-R", "group", 1, "1", BOOKIE)
  recv(C, "BET", "tb", "Cid-R", "group", 1, "9999", BOOKIE)   -- not in this dungeon
end, false)

betProbe("a boss-pick bet on a listed boss is kept", function(C)
  recv(C, "BET", "tb", "Bob-R", "group", 1, "1", BOOKIE)
  recv(C, "BET", "tb", "Cid-R", "group", 1, "3", BOOKIE)
end, true)

betProbe("a line index past the end of the card is dropped", function(C)
  recv(C, "BET", "tb", "Bob-R", "group", 9, "Y", BOOKIE)
  recv(C, "BET", "tb", "Cid-R", "group", 9, "N", BOOKIE)
end, false)

betProbe("a pick that is not one of the line's options is dropped", function(C)
  recv(C, "BET", "tb", "Bob-R", "group", 2, "Y", BOOKIE)
  recv(C, "BET", "tb", "Cid-R", "group", 2, "MAYBE", BOOKIE)
end, false)

betProbe("a BET naming another bookie is dropped", function(C)
  recv(C, "BET", "tb", "Bob-R", "group", 2, "Y", BOOKIE)
  recv(C, "BET", "tb", "Cid-R", "group", 2, "N", "SomeoneElse-R")
end, false)

betProbe("a BET from outside the group is dropped at party scope", function(C)
  recv(C, "BET", "tb", "Bob-R", "group", 2, "Y", BOOKIE)
  recv(C, "BET", "tb", "Stranger-R", "group", 2, "N", BOOKIE)
end, false)

-------------------------------------------------------------------------------
print()
print("== void rules ==")
-------------------------------------------------------------------------------

-- Both probes take the picks EXPLICITLY, one pair per card line. An earlier
-- version derived them ("the other side of OVER is UNDER") and quietly fed a
-- boss id to a YES/NO line, where the module correctly dropped it - so the test
-- passed or failed for reasons that had nothing to do with what it claimed to
-- check. A pick that the line does not offer is not a test fixture, it is a
-- different test.
local function probe(label, card, picks, res, expectCommits)
  local C = H.newClient(ROOT, "Ann-R")
  H.ME = "Ann-R"
  recv(C, "OPEN", "tv", BOOKIE, "group", 100, 391, card, "P")
  recv(C, "ROSTER", "tv", BOOKIE, "group", 391, ROSTER)
  for i = 1, #picks do
    recv(C, "BET", "tv", "Bob-R", "group", i, picks[i][1], BOOKIE)
    recv(C, "BET", "tv", "Cid-R", "group", i, picks[i][2], BOOKIE)
  end
  recv(C, "LOCK", "tv", BOOKIE, "group", 391, 12)
  H.clock = H.clock + 5
  recv(C, "RES", "tv", BOOKIE, "group", unpack(res))
  drain(C)
  if type(expectCommits) == "function" then
    check(label, expectCommits(C), #C.commits .. " commits")
  else
    check(label, #C.commits == expectCommits, #C.commits)
  end
  return C
end

local FULL_CARD = "T,L,O.3,P.1.1,D.2.2"
local FULL_PICKS = {
  { "Y", "N" },            -- T      timed?
  { "3", "1" },      -- L      first wall
  { "Y", "N" },            -- O.3 one-shot?
  { "O", "U" },            -- P.2926 attempts
  { "O", "U" },            -- D.2906 deaths
}
local GOOD = { "C", "Y", "9", "3", "300", "T", "3", "3", BOSSDATA }

probe("an abandoned key voids every line", FULL_CARD, FULL_PICKS,
  { "A", "-", "-", "-", "-", "-", "-", "-", "-" }, 0)
probe("a full card with everything readable settles all five", FULL_CARD,
  FULL_PICKS, GOOD, 5)
probe("a clean run voids First wall and settles the other four", FULL_CARD,
  FULL_PICKS, { "C", "Y", "9", "0", "300", "T", "0", "3", BOSSDATA }, 4)
probe("bosses that were never fought void only their own lines", FULL_CARD,
  FULL_PICKS, { "C", "Y", "9", "3", "300", "T", "3", "3", "3.3.5" }, 3)
probe("a fractional death count voids that line and no other",
  "T,X.6", { { "Y", "N" }, { "O", "U" } },
  { "C", "Y", "7.5", "3", "300", "T", "3", "3", BOSSDATA }, 1)
probe("an unreadable timed flag voids Timed? and no other",
  "T,X.6", { { "Y", "N" }, { "O", "U" } },
  { "C", "-", "9", "3", "300", "T", "3", "3", BOSSDATA }, 1)
probe("no first death means the First death line voids",
  "T,F", { { "Y", "N" }, { "T", "H" } },
  { "C", "Y", "0", "0", "300", "-", "0", "0", "-" }, 1)

-------------------------------------------------------------------------------
print()
print("== the two new run-level lines, and the two boss-pick ones ==")
-------------------------------------------------------------------------------

local function winner(label, card, picks, res, wins)
  local C = probe(label, card, picks, res, function(c) return #c.commits == 1 end)
  local row = C.commits[1]
  check("   ... and " .. wins .. " is the winning side",
    row and row.rows[wins] == 100, row and row.rows[wins])
end

-- Time left: OVER is strict, so exactly 300s on a five-minute line is UNDER.
winner("Time left: exactly on the line is UNDER", "M.5", { { "O", "U" } },
  { "C", "Y", "9", "3", "300", "T", "3", "3", BOSSDATA }, "Cid-R")
winner("Time left: 400s beats a five-minute line", "M.5", { { "O", "U" } },
  { "C", "Y", "9", "3", "400", "T", "3", "3", BOSSDATA }, "Bob-R")
winner("Time left: an over-time key is UNDER any line", "M.5", { { "O", "U" } },
  { "C", "N", "9", "3", "-120", "T", "3", "3", BOSSDATA }, "Cid-R")
winner("First death: the tank died first", "F", { { "T", "H" } }, GOOD, "Bob-R")
winner("Worst boss: Zul'jan took the most attempts", "W",
  { { "3", "1" } }, GOOD, "Bob-R")
winner("First wall: Zul'jan, the journal's LAST boss", "L",
  { { "1", "3" } }, GOOD, "Cid-R")
-- "D.2900" alone is NOT a valid entry: D carries a boss AND a line, and the
-- codec reads the field count out of MARKET rather than off the wire, so a
-- missing line value is a malformed card and the whole OPEN is refused.
winner("Boss deaths: Zul'jan's five beats a line of 2", "D.3.2",
  { { "O", "U" } }, GOOD, "Bob-R")
winner("Boss one-shot: Rav'i went down first try", "O.1",
  { { "Y", "N" } }, GOOD, "Bob-R")

-------------------------------------------------------------------------------
print()
print("== replay, supersession and the wrong key ==")
-------------------------------------------------------------------------------

local R = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
recv(R, "OPEN", "tr1", BOOKIE, "group", 100, 391, "T", "P")
recv(R, "BET", "tr1", "Bob-R", "group", 1, "Y", BOOKIE)
recv(R, "BET", "tr1", "Cid-R", "group", 1, "N", BOOKIE)
recv(R, "CLOSE", "tr1", BOOKIE, "group")
check("CLOSE settles nothing and returns the stakes", #R.commits == 0, #R.commits)
recv(R, "OPEN", "tr1", BOOKIE, "group", 100, 391, "T", "P")
recv(R, "BET", "tr1", "Bob-R", "group", 1, "Y", BOOKIE)
recv(R, "BET", "tr1", "Cid-R", "group", 1, "N", BOOKIE)
recv(R, "RES", "tr1", BOOKIE, "group", "C", "Y", "1", "0", "300", "-", "0", "0", "-")
drain(R)
check("a replayed OPEN cannot resurrect a dead parley", #R.commits == 0, #R.commits)

local S = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
recv(S, "OPEN", "ts1", BOOKIE, "group", 100, 391, "T,O.3", "P")
recv(S, "ROSTER", "ts1", BOOKIE, "group", 391, ROSTER)
for i = 1, 2 do
  recv(S, "BET", "ts1", "Bob-R", "group", i, "Y", BOOKIE)
  recv(S, "BET", "ts1", "Cid-R", "group", i, "N", BOOKIE)
end
-- LOCK reports a DIFFERENT dungeon than the card was posted for
recv(S, "LOCK", "ts1", BOOKIE, "group", 392, 12)
H.clock = H.clock + 5
recv(S, "RES", "ts1", BOOKIE, "group", "C", "Y", "9", "3", "300", "T",
  "3", "3", BOSSDATA)
drain(S)
check("a different key voids the WHOLE card, run-level lines included",
  #S.commits == 0, #S.commits)

-- positive control: the identical card on the DECLARED key settles both lines,
-- so the check above is testing the mismatch and not something else
local S2 = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
recv(S2, "OPEN", "ts2", BOOKIE, "group", 100, 391, "T,O.3", "P")
recv(S2, "ROSTER", "ts2", BOOKIE, "group", 391, ROSTER)
for i = 1, 2 do
  recv(S2, "BET", "ts2", "Bob-R", "group", i, "Y", BOOKIE)
  recv(S2, "BET", "ts2", "Cid-R", "group", i, "N", BOOKIE)
end
recv(S2, "LOCK", "ts2", BOOKIE, "group", 391, 12)
H.clock = H.clock + 5
recv(S2, "RES", "ts2", BOOKIE, "group", "C", "Y", "9", "3", "300", "T",
  "3", "3", BOSSDATA)
drain(S2)
check("the same card on the declared key settles both lines", #S2.commits == 2,
  #S2.commits)

H.done()
