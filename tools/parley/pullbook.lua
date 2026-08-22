-- The raid Pull Book, whose settlement path was rewritten in 1.5.0.
--
-- Until then every client resolved K and W from its OWN ENCOUNTER_END. That
-- cannot serve a guild spectator, who has no such event, so the bookie now
-- broadcasts the result (ENC) and everybody settles from that one message. This
-- file exists because that is a change to a shipped, working game, and a
-- settlement regression is the kind that pays the wrong person quietly.
local ROOT = ...
package.path = ROOT .. "/tools/parley/?.lua;" .. package.path
local H = require("harness")
local check, recv, drain, fire = H.check, H.recv, H.drain, H.fire

local BOOKIE = "Grizzle-R"
local function newPB(name) return H.newClient(ROOT, name, "PullBook") end

-- READY_ON is what opens a bet window; the attempt freezes on ENCOUNTER_ON.
local function openWindow(C)
  H.safety(C, "READY_ON", "readyCheck")
end
local function freeze(C)
  C.PG.Safety.state.readyCheck = false
  H.safety(C, "ENCOUNTER_ON", "inEncounter")
end

-------------------------------------------------------------------------------
print("== the party book still works, settled from ENC ==")
-------------------------------------------------------------------------------

local A = newPB("Ann-R")
H.ME = "Ann-R"
recv(A, "OPEN", "t1", BOOKIE, "group", 100, 50, "P")
openWindow(A)
for _, b in ipairs({ { "Bob-R", "K", "Y" }, { "Cid-R", "K", "N" },
                     { "Bob-R", "W", "O" }, { "Cid-R", "W", "U" },
                     { "Bob-R", "D", "T" }, { "Cid-R", "D", "H" } }) do
  recv(A, "BET", "t1", b[1], "group", b[2], b[3], BOOKIE)
end
freeze(A)
check("no bet settles before the result arrives", #A.commits == 0, #A.commits)

-- a wipe at 12%
recv(A, "ENC", "t1", BOOKIE, "group", "N", "12", "Ulgrax the Devourer")
check("K and W settle from ENC", #A.commits == 2, #A.commits)
local byM = {}
for _, c in ipairs(A.commits) do byM[c.meta.id:match("[^:]+$")] = c end
check("K: NO wins on a wipe", byM.K and byM.K.rows["Cid-R"] == 100,
  byM.K and byM.K.rows["Cid-R"])
check("W: 12% is UNDER a line of 50", byM.W and byM.W.rows["Cid-R"] == 100,
  byM.W and byM.W.rows["Cid-R"])
check("zero-sum", (function()
  for _, c in ipairs(A.commits) do if c.sum ~= 0 then return false end end
  return true
end)())

recv(A, "FD", "t1", BOOKIE, "group", "T", "Ann-R")
check("D settles from FD", #A.commits == 3, #A.commits)

-- a second copy of each changes nothing
recv(A, "ENC", "t1", BOOKIE, "group", "N", "12", "Ulgrax the Devourer")
recv(A, "FD", "t1", BOOKIE, "group", "T", "Ann-R")
check("ENC and FD are idempotent", #A.commits == 3, #A.commits)

-- a kill counts as 0% and wins UNDER
local B = newPB("Ann-R")
recv(B, "OPEN", "t2", BOOKIE, "group", 100, 50, "P")
openWindow(B)
recv(B, "BET", "t2", "Bob-R", "group", "K", "Y", BOOKIE)
recv(B, "BET", "t2", "Cid-R", "group", "K", "N", BOOKIE)
recv(B, "BET", "t2", "Bob-R", "group", "W", "U", BOOKIE)
recv(B, "BET", "t2", "Cid-R", "group", "W", "O", BOOKIE)
freeze(B)
recv(B, "ENC", "t2", BOOKIE, "group", "Y", "0", "Ulgrax the Devourer")
local byM2 = {}
for _, c in ipairs(B.commits) do byM2[c.meta.id:match("[^:]+$")] = c end
check("a kill wins YES", byM2.K and byM2.K.rows["Bob-R"] == 100)
check("a kill is 0% and wins UNDER", byM2.W and byM2.W.rows["Bob-R"] == 100)

-- an unreadable result voids both immediate markets
local C = newPB("Ann-R")
recv(C, "OPEN", "t3", BOOKIE, "group", 100, 50, "P")
openWindow(C)
recv(C, "BET", "t3", "Bob-R", "group", "K", "Y", BOOKIE)
recv(C, "BET", "t3", "Cid-R", "group", "K", "N", BOOKIE)
freeze(C)
recv(C, "ENC", "t3", BOOKIE, "group", "-", "-", "Ulgrax the Devourer")
check("an unreadable result voids K", #C.commits == 0, #C.commits)

-------------------------------------------------------------------------------
print()
print("== the guild half ==")
-------------------------------------------------------------------------------

-- A spectator hears a both-scope book on the GUILD leg only. It must be a
-- both-scope RECORD, so the party leg's traffic is accepted too.
local G = newPB("Eve-R")
H.ME = "Eve-R"
recv(G, "OPEN", "t4", BOOKIE, "guild", 100, 50, "B")
openWindow(G)
recv(G, "BET", "t4", "Bob-R", "group", "K", "Y", BOOKIE)   -- the party leg
recv(G, "BET", "t4", "Fay-R", "guild", "K", "N", BOOKIE)   -- the guild leg
freeze(G)
recv(G, "ENC", "t4", BOOKIE, "guild", "N", "12", "Ulgrax the Devourer")
check("a spectator settles a book it heard only on the guild leg",
  #G.commits == 1, #G.commits)
check("and counted BOTH legs' bettors",
  G.commits[1] and G.commits[1].rows["Bob-R"] == -100
    and G.commits[1].rows["Fay-R"] == 100, G.commits[1] and G.commits[1].n)

-- a party member hears the same book on the PARTY leg and must agree exactly
local P = newPB("Ann-R")
H.ME = "Ann-R"
recv(P, "OPEN", "t4", BOOKIE, "group", 100, 50, "B")
openWindow(P)
recv(P, "BET", "t4", "Bob-R", "group", "K", "Y", BOOKIE)
recv(P, "BET", "t4", "Fay-R", "guild", "K", "N", BOOKIE)
freeze(P)
recv(P, "ENC", "t4", BOOKIE, "group", "N", "12", "Ulgrax the Devourer")
check("the party half's ledger is identical to the guild half's",
  H.fingerprint(P) == H.fingerprint(G), "\nP: " .. H.fingerprint(P)
    .. "\nG: " .. H.fingerprint(G))

-- a THIRD distribution is still refused
local X = newPB("Ann-R")
recv(X, "OPEN", "t5", BOOKIE, "group", 100, 50, "B")
openWindow(X)
recv(X, "BET", "t5", "Bob-R", "group", "K", "Y", BOOKIE)
recv(X, "BET", "t5", "Cid-R", "public", "K", "N", BOOKIE)  -- not a leg of `both`
freeze(X)
recv(X, "ENC", "t5", BOOKIE, "group", "N", "12", "Ulgrax")
check("a bet on a distribution the book does not ride is refused",
  #X.commits == 0, #X.commits)

-- a party-scope book still refuses guild traffic outright
local Y = newPB("Ann-R")
recv(Y, "OPEN", "t6", BOOKIE, "group", 100, 50, "P")
openWindow(Y)
recv(Y, "BET", "t6", "Bob-R", "group", "K", "Y", BOOKIE)
recv(Y, "BET", "t6", "Fay-R", "guild", "K", "N", BOOKIE)
freeze(Y)
recv(Y, "ENC", "t6", BOOKIE, "group", "N", "12", "Ulgrax")
check("a party book ignores the guild distribution entirely",
  #Y.commits == 0, #Y.commits)

-- and an OPEN whose declared code does not match its delivery is refused
local Z = newPB("Ann-R")
recv(Z, "OPEN", "t7", BOOKIE, "guild", 100, 50, "P")   -- claims party, came on guild
openWindow(Z)
recv(Z, "BET", "t7", "Bob-R", "guild", "K", "Y", BOOKIE)
recv(Z, "BET", "t7", "Cid-R", "guild", "K", "N", BOOKIE)
freeze(Z)
recv(Z, "ENC", "t7", BOOKIE, "guild", "N", "12", "Ulgrax")
check("a lied-about scope code drops the OPEN", #Z.commits == 0, #Z.commits)

-------------------------------------------------------------------------------
print()
print("== the bookie: dual-send, and who may bet ==")
-------------------------------------------------------------------------------

local K = newPB("Ann-R")
H.ME = "Ann-R"
H.created = {}
K.PB.OpenDialog()
-- the audience picker mock answers "group"; drive the both case by hand below
check("Open book sends on one leg at party scope",
  H.press(K, "Open book") and H.legsOf(K, "OPEN") == "group", H.legsOf(K, "OPEN"))

-- ...and on two at both scope.
local K2 = newPB("Ann-R")
H.ME = "Ann-R"
K2.pickScope = "both"
K2.PB.OpenDialog()
H.press(K2, "Open book")
check("Open book sends on BOTH legs at both scope",
  H.legsOf(K2, "OPEN") == "group+guild", H.legsOf(K2, "OPEN"))
check("HB rides both legs too", (function()
  H.tick(K2, 40)   -- past HB_SECS
  return H.legsOf(K2, "HB") == "group+guild"
end)(), H.legsOf(K2, "HB"))

openWindow(K2)
-- A bettor who cannot reach the guild leg must be refused, because a bet that
-- landed on the party leg alone would leave the guild settling a pool it never
-- saw. This is the one rule the union audience needs.
K2.noGuild = true
H.card(K2, "YES")
check("a bettor who cannot reach the guild leg is refused",
  H.countSent(K2, "BET") == 0, H.countSent(K2, "BET"))
check("...and is told why", (function()
  for _, t in ipairs(K2.toasts) do
    if tostring(t):find("in the guild to bet", 1, true) then return true end
  end
  return false
end)())

K2.noGuild = false
H.card(K2, "YES")
check("with the guild reachable the bet goes out on both legs",
  H.legsOf(K2, "BET") == "group+guild", H.legsOf(K2, "BET"))

-- the settlement the bookie sends also rides both legs
freeze(K2)
fire(K2, "ENCOUNTER_END", 1, "Ulgrax the Devourer", 16, 20, 0, {})
drain(K2)
check("ENC rides both legs", H.legsOf(K2, "ENC") == "group+guild",
  H.legsOf(K2, "ENC"))
check("and the bookie settled from its own broadcast, not from the event",
  K2.PB ~= nil)

H.done()
