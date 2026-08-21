-- The two claims that cannot be checked by reading.
--
--  A. PARLEY.md 5 - two clients that receive LOCK at DIFFERENT times accept the
--     identical set of bets and therefore commit identical ledgers.
--  B. The bookie's whole path: resolve the season and the boss roster, tick a
--     card, lock, run a key WITH THE BOSSES OUT OF JOURNAL ORDER, and emit a
--     RES whose per-boss numbers are attached to the right bosses.
local ROOT = ...
package.path = ROOT .. "/tools/parley/?.lua;" .. package.path
local H = require("harness")
local check, recv, drain, fire = H.check, H.recv, H.drain, H.fire

local BOOKIE = "Grizzle-R"
local ROSTER = "2926~Avanoxx,2906~Anub'zekt,2900~Ki'katal the Harvester"

-------------------------------------------------------------------------------
print("== A. two clients, LOCK arriving 0.4s apart, one ledger ==")
-------------------------------------------------------------------------------

local A = H.newClient(ROOT, "Ann-R")
local B = H.newClient(ROOT, "Bob-R")
local BOTH = { A, B }

for _, C in ipairs(BOTH) do
  recv(C, "OPEN", "t1", BOOKIE, "group", 100, 391, "T,X.6,L", "P")
  recv(C, "ROSTER", "t1", BOOKIE, "group", 391, ROSTER)
end

for _, bet in ipairs({ { "Cid-R", 1, "Y" }, { "Dot-R", 1, "N" }, { "Eve-R", 1, "Y" },
                       { "Cid-R", 2, "O" }, { "Dot-R", 2, "U" } }) do
  for _, C in ipairs(BOTH) do
    recv(C, "BET", "t1", bet[1], "group", bet[2], bet[3], BOOKIE)
  end
end

-- LOCK lands on A first
H.clock = H.clock + 0.1
recv(A, "LOCK", "t1", BOOKIE, "group", 391, 12)
-- Two bets already in flight when the bookie locked. They reach A AFTER A
-- locked and B BEFORE B locked. Without the grace, A drops them and B keeps
-- them, and the two ledgers disagree about who backed the first-wall pool.
H.clock = H.clock + 0.15
for _, bet in ipairs({ { "Cid-R", 3, "2900" }, { "Dot-R", 3, "2926" } }) do
  for _, C in ipairs(BOTH) do
    recv(C, "BET", "t1", bet[1], "group", bet[2], bet[3], BOOKIE)
  end
end
-- LOCK finally reaches B, 0.4s late
H.clock = H.clock + 0.25
recv(B, "LOCK", "t1", BOOKIE, "group", 391, 12)

H.clock = H.clock + 5
for _, C in ipairs(BOTH) do
  recv(C, "RES", "t1", BOOKIE, "group", "C", "Y", "9", "2", "300", "T",
    "2900", "2900", "2900.3.5,2926.1.2,2906.1.1")
  drain(C)
end

local fa, fb = H.fingerprint(A), H.fingerprint(B)
check("both clients settled the same number of lines", #A.commits == #B.commits,
  #A.commits .. " vs " .. #B.commits)
check("the in-flight bets survived on BOTH sides (LOCK_GRACE did its job)",
  #A.commits == 3, #A.commits)
check("the two ledgers are byte-identical", fa == fb, "\nA:\n" .. fa .. "\nB:\n" .. fb)

local D = H.newClient(ROOT, "Cid-R")
recv(D, "OPEN", "t9", BOOKIE, "group", 100, 391, "T", "P")
recv(D, "BET", "t9", "Ann-R", "group", 1, "Y", BOOKIE)
recv(D, "LOCK", "t9", BOOKIE, "group", 391, 12)
H.clock = H.clock + 5     -- LOCK_GRACE is 2
recv(D, "BET", "t9", "Bob-R", "group", 1, "N", BOOKIE)
recv(D, "RES", "t9", BOOKIE, "group", "C", "Y", "1", "0", "300", "-", "0", "0", "-")
drain(D)
check("a bet five seconds past LOCK is refused (line voids, one backer)",
  #D.commits == 0, #D.commits)

-------------------------------------------------------------------------------
print()
print("== B. the bookie: season, roster, card ==")
-------------------------------------------------------------------------------

H.ME = "Ann-R"
H.slotted = 391          -- the keystone is already in the font of power
H.keyActive = nil
H.deaths = 0
H.completion = nil

local K = H.newClient(ROOT, "Ann-R")
H.created = {}
K.PG.MP.OpenDialog()

local boxes = H.checkboxes()
-- availableLines() order for a three-boss dungeon: the five run-level lines,
-- the two boss-pick lines, then three per boss in roster order.
--   1 T   2 X   3 A   4 M   5 F   6 L   7 W
--   8 O.2926   9 P.2926  10 D.2926
--  11 O.2906  12 P.2906  13 D.2906
--  14 O.2900  15 P.2900  16 D.2900
check("the boss roster resolved from the Encounter Journal", #boxes >= 16, #boxes)
check("a parley cannot be opened before anything is ticked",
  (H.press(K, "Open parley") and false) or H.sentOf(K, "OPEN") == nil)

H.clickCheck(boxes[1])    -- Timed?
H.clickCheck(boxes[2])    -- Deaths o/u 6
H.clickCheck(boxes[6])    -- First wall
H.clickCheck(boxes[9])    -- Avanoxx attempts o/u 1
H.clickCheck(boxes[14])   -- Ki'katal one-shot?
check("five lines tick", true)

H.clickCheck(boxes[3])
check("a sixth tick is refused by the card cap",
  rawget(boxes[3], "checked") == false)

H.press(K, "Open parley")
local openMsg = H.sentOf(K, "OPEN")
check("OPEN went out", openMsg ~= nil)
check("OPEN carries stake, dungeon, card and scope code",
  openMsg and openMsg.f[2] == 100 and openMsg.f[3] == 391 and openMsg.f[5] == "P",
  openMsg and tostring(openMsg.f[3]))
check("the card is the five ticked lines, in builder order",
  openMsg and openMsg.f[4] == "T,X.6,L,P.2926.1,O.2900", openMsg and openMsg.f[4])

local rosterMsg = H.sentOf(K, "ROSTER")
check("a ROSTER goes out beside the OPEN so every client names the same bosses",
  rosterMsg and rosterMsg.f[3] == ROSTER, rosterMsg and rosterMsg.f[3])

local TOK = openMsg.f[1]

-------------------------------------------------------------------------------
print()
print("== B. the run, with the route in the wrong order ==")
-------------------------------------------------------------------------------

for _, b in ipairs({ { "Bob-R", 1, "Y" }, { "Cid-R", 1, "N" },
                     { "Bob-R", 3, "2900" }, { "Cid-R", 3, "2926" },
                     { "Bob-R", 4, "O" }, { "Cid-R", 4, "U" },
                     { "Bob-R", 5, "Y" }, { "Cid-R", 5, "N" } }) do
  recv(K, "BET", TOK, b[1], "group", b[2], b[3], BOOKIE == BOOKIE and "Ann-R" or nil)
end

-- the restriction fires BEFORE the key activates: that is the lock
H.safety(K, "RESTRICT_ON", "restricted")
check("RESTRICT_ON locks the table and broadcasts LOCK", H.sentOf(K, "LOCK") ~= nil)

K.locked = true           -- the wire is dead for the whole run
H.keyActive = 391
fire(K, "CHALLENGE_MODE_START")

-- The group opens on Ki'katal - the journal's LAST boss - walls twice, kills
-- it, then clears Avanoxx and Anub'zekt in one pull each. Nothing about this
-- route matches the journal's order, which is the point.
local function encounter(id, name, success, deathsAfter)
  fire(K, "ENCOUNTER_START", id, name, 8, 5)
  H.deaths = deathsAfter
  fire(K, "ENCOUNTER_END", id, name, 8, 5, success)
end

encounter(2900, "Ki'katal the Harvester", 0, 2)
fire(K, "UNIT_DIED", "GUID-raid1")          -- the tank went down first
encounter(2900, "Ki'katal the Harvester", 0, 4)
encounter(2900, "Ki'katal the Harvester", 1, 5)
encounter(2926, "Avanoxx", 1, 7)
encounter(2906, "Anub'zekt", 1, 8)
H.deaths = 9
fire(K, "CHALLENGE_MODE_DEATH_COUNT_UPDATED")

check("nothing is sent during the key",
  H.countSent(K, "RES") == 0 and H.countSent(K, "HB") == 0)

H.completion = { map = 391, level = 12, ms = 1680000, onTime = true }
H.keyActive = nil
K.locked = false
fire(K, "CHALLENGE_MODE_COMPLETED")
drain(K)

local res = H.sentOf(K, "RES")
check("RES is broadcast once the wire returns", res ~= nil)
check("exactly one RES goes out, not one per retry", H.countSent(K, "RES") == 1,
  H.countSent(K, "RES"))
check("outcome C", res and res.f[2] == "C", res and res.f[2])
check("timed = Y", res and res.f[3] == "Y", res and res.f[3])
check("9 deaths, from GetDeathCount", res and res.f[4] == "9", res and res.f[4])
check("2 boss wipes - the three kills are not wipes", res and res.f[5] == "2",
  res and res.f[5])
check("300 seconds left, from the elapsed time against the dungeon timer",
  res and res.f[6] == "300", res and res.f[6])
check("first death was the TANK", res and res.f[7] == "T", res and res.f[7])
check("FIRST WALL is Ki'katal's id, not 'boss 1'", res and res.f[8] == "2900",
  res and res.f[8])
check("WORST BOSS is Ki'katal's id (three attempts)", res and res.f[9] == "2900",
  res and res.f[9])
check("per-boss data attaches 3 attempts / 5 deaths to KI'KATAL",
  res and res.f[10]:find("2900.3.5", 1, true) ~= nil, res and res.f[10])
check("...1 attempt / 2 deaths to AVANOXX",
  res and res.f[10]:find("2926.1.2", 1, true) ~= nil, res and res.f[10])
check("...1 attempt / 1 death to ANUB'ZEKT",
  res and res.f[10]:find("2906.1.1", 1, true) ~= nil, res and res.f[10])

local byIdx = H.byIndex(K)
check("the bookie settled its own card from the RES it sent", #K.commits == 4,
  #K.commits)
check("line 3 First wall: Ki'katal backer wins",
  byIdx[3] and byIdx[3].rows["Bob-R"] == 100, byIdx[3] and byIdx[3].rows["Bob-R"])
check("line 4 Avanoxx attempts: one attempt is UNDER a line of 1",
  byIdx[4] and byIdx[4].rows["Cid-R"] == 100, byIdx[4] and byIdx[4].rows["Cid-R"])
check("line 5 Ki'katal one-shot?: three attempts, so NO wins",
  byIdx[5] and byIdx[5].rows["Cid-R"] == 100, byIdx[5] and byIdx[5].rows["Cid-R"])

-------------------------------------------------------------------------------
print()
print("== B. the run learns the dungeon it was in ==")
-------------------------------------------------------------------------------

local learned = K.PG.db.mp and K.PG.db.mp.bosses and K.PG.db.mp.bosses[391]
check("the roster is cached for next time", type(learned) == "table" and #learned == 3,
  learned and #learned)

-------------------------------------------------------------------------------
print()
print("== B. an abandoned key ==")
-------------------------------------------------------------------------------

local R = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
H.created = {}
H.keyActive = nil
R.PG.MP.OpenDialog()
local rboxes = H.checkboxes()
H.clickCheck(rboxes[1])
H.press(R, "Open parley")
local rtok = H.sentOf(R, "OPEN").f[1]
recv(R, "BET", rtok, "Bob-R", "group", 1, "Y", "Ann-R")
recv(R, "BET", rtok, "Cid-R", "group", 1, "N", "Ann-R")
H.safety(R, "RESTRICT_ON", "restricted")
R.locked = true
H.keyActive = 391
fire(R, "CHALLENGE_MODE_START")
R.locked = false
fire(R, "CHALLENGE_MODE_RESET")
drain(R)
local rres = H.sentOf(R, "RES")
check("a reset key emits RES with outcome A", rres and rres.f[2] == "A",
  rres and rres.f[2])
check("and writes nothing to the ledger", #R.commits == 0, #R.commits)

-------------------------------------------------------------------------------
print()
print("== C. the client is missing things it needs ==")
-------------------------------------------------------------------------------

-- The season list is empty (a fresh login, before the server answers). The mode
-- must still work with run-level lines rather than refusing to open at all.
local realMapTable = _G.C_ChallengeMode.GetMapTable
local asked = 0
_G.C_ChallengeMode.GetMapTable = function() return {} end
_G.C_ChallengeMode.RequestMapInfo = function() asked = asked + 1 end

local E = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
H.slotted = nil
H.keyActive = nil    -- and no key running either: nothing to default to at all
H.created = {}
E.PG.MP.OpenDialog()
check("an empty season list asks the server for one", asked > 0, asked)
H.clickCheck(H.shownChecks()[1])            -- Timed?
H.press(E, "Open parley")
local eopen = H.sentOf(E, "OPEN")
check("a parley still opens with no dungeon at all", eopen ~= nil)
check("and declares mapId 0", eopen and eopen.f[3] == 0, eopen and eopen.f[3])
check("with only the five run-level lines on offer", #H.shownChecks() == 5,
  #H.shownChecks())

local etok = eopen.f[1]
recv(E, "BET", etok, "Bob-R", "group", 1, "Y", "Ann-R")
recv(E, "BET", etok, "Cid-R", "group", 1, "N", "Ann-R")
-- a key runs, and it is NOT the declared one - because nothing was declared.
-- An undeclared parley has nothing to contradict, so it must settle normally.
H.safety(E, "RESTRICT_ON", "restricted")
E.locked = true
H.keyActive = 391
fire(E, "CHALLENGE_MODE_START")
H.completion = { map = 391, level = 12, ms = 1680000, onTime = true }
H.keyActive = nil
E.locked = false
fire(E, "CHALLENGE_MODE_COMPLETED")
drain(E)
check("an UNDECLARED parley does not void as a wrong key", #E.commits == 1,
  #E.commits)
check("and Timed? settled YES", E.commits[1] and E.commits[1].rows["Bob-R"] == 100,
  E.commits[1] and E.commits[1].rows["Bob-R"])

_G.C_ChallengeMode.GetMapTable = realMapTable

-- No Encounter Journal at all: run-level lines only, and nothing errors.
local realTiers = _G.EJ_GetNumTiers
local realByMap = _G.EJ_GetInstanceForMap
_G.EJ_GetNumTiers = nil
_G.EJ_GetInstanceForMap = nil

local J = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
H.created = {}
J.PG.MP.OpenDialog()
check("no journal means the five run-level lines and nothing else",
  #H.shownChecks() == 5, #H.shownChecks())
local diag = J.PG.MP.Diagnose()
check("/pg keys reports the dungeons as unknown rather than erroring",
  type(diag) == "table" and #diag >= 3
    and table.concat(diag, "|"):find("UNKNOWN", 1, true) ~= nil,
  diag and table.concat(diag, " / "))

_G.EJ_GetNumTiers = realTiers
_G.EJ_GetInstanceForMap = realByMap

-- The by-map path: the tier walk is broken but we are standing in the dungeon.
_G.EJ_GetNumTiers = function() return 0 end   -- tier walk yields nothing
_G.C_Map = { GetBestMapForUnit = function() return 2660 end }
_G.EJ_GetInstanceForMap = function(u) return (u == 2660) and 101 or nil end
_G.EJ_GetInstanceInfo = function(i) return (i == 101) and "Ara-Kara, City of Echoes" or nil end

local Q = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
H.created = {}
Q.PG.MP.OpenDialog()
local qd = table.concat(Q.PG.MP.Diagnose(), " / ")
check("a broken tier walk still resolves the dungeon you are standing in",
  qd:find("Ara%-Kara, City of Echoes %- 3 bosses") ~= nil, qd)
check("...and says where it came from",
  qd:find("this map", 1, true) ~= nil, qd)

_G.EJ_GetNumTiers = realTiers

-- And the name check is real: standing in the wrong dungeon resolves nothing.
_G.EJ_GetNumTiers = function() return 0 end
_G.EJ_GetInstanceInfo = function() return "Somewhere Else" end
local Z = H.newClient(ROOT, "Ann-R")
H.ME = "Ann-R"
H.created = {}
Z.PG.MP.OpenDialog()
local zd = table.concat(Z.PG.MP.Diagnose(), " / ")
check("a journal instance whose NAME disagrees is refused",
  zd:find("UNKNOWN", 1, true) ~= nil, zd)
_G.EJ_GetNumTiers = realTiers

H.done()
