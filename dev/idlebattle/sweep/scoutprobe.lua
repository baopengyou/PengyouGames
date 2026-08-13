-- sweep/scoutprobe.lua -- WHAT DOES BUYING SIGHT ACTUALLY BUY, AND WHAT DOES IT
-- COST? The controlled decomposition of the one roster change this pass made.
--
-- THE PROBLEM THIS EXISTS TO SOLVE. Four of the sixteen lines now spend a cheap
-- body on vision, because ../docs/IDLE_BATTLE_FOG.md section 3 makes vision a
-- purchase and their own stated intents need it. That change moves the milestone
-- numbers, and a pass that moves milestone numbers must be able to say WHICH
-- half of the change moved them -- or the next reader cannot tell an honest
-- recalibration from a roster picked because it passed.
--
-- The change has exactly two halves and they are separable:
--
--   the BODY        a Spear sent forward lights the section it stands in, so
--                   Policy.openLane sees enemy buildings and Levy it otherwise
--                   never would, Policy.counterType sees types, Policy
--                   .pressedLane stops answering "nothing", and a reactive
--                   building trigger keyed to enemy Levy in a lane can fire
--                   before the lane is overrun. All of that happens with the
--                   line's declared reactAt left exactly where it was.
--   the THRESHOLD   with sight bought, a threshold below the midline is
--                   satisfiable again, so three of the four lines put theirs
--                   back where their source always said it was (Turtle-eco 751,
--                   Counterpunch 900, Adaptive 900).
--
-- So this file runs the same frozen seed schedule over three rosters that differ
-- in NOTHING ELSE:
--
--   A  no sight, thresholds at the free floor   -- the roster as published
--                                                  before this pass
--   B  sight bought, thresholds UNCHANGED       -- the body alone
--   C  sight bought, thresholds restored        -- what ships
--
-- B minus A is what the body is worth. C minus B is what the threshold is worth.
-- C minus A is the whole change, and it is the row the README quotes.
--
-- IT IS A DIAGNOSTIC AND IT NEVER GATES. It always exits 0, it asserts nothing,
-- and it builds its variants as COPIES so nothing in policy/lines.lua is
-- mutated -- a probe that edited the shipped roster would make every later step
-- of sweep/run.sh measure something else.
--
--   usage: lua sweep/scoutprobe.lua [seedsPerPair] [seedBase]
--          seedsPerPair  default 2 (480 matches per variant, ~20 s each)
--          seedBase      default sweep/measure.lua's frozen base
--
-- Held to sim/'s determinism rules like the rest of sweep/.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local linesM = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local measure = IB_SIM_MODULES and IB_SIM_MODULES.measure or require("sweep.measure")

local floor = math.floor
local format = string.format

local SEEDS = tonumber(arg and arg[1]) or 2
local SEEDBASE = tonumber(arg and arg[2]) or measure.SEED_BASE

-- The four lines that declare a scout, and the threshold each of them carried
-- when it could not buy sight. Written down here rather than derived, because
-- "what this line used to say" is history and history is not in the config.
local BEFORE = {
  ["Raid-counter"] = 1150,               -- unchanged even now: its scout is for
                                         -- the type draw and the lane choice
  ["Turtle-eco"]   = Policy.REACT_MIN,
  ["Counterpunch"] = Policy.REACT_MIN,
  ["Adaptive"]     = Policy.REACT_MIN,
  -- Pathfinder has no "before": it did not exist without its scout, and a
  -- Pathfinder that buys no sight is not a version of the line, it is a cheap
  -- Spear rush. Its A column is therefore what the POOL looks like with the
  -- roster's one dedicated scout blinded, which is the comparison this file can
  -- honestly make, and its own row in the per-line table should be read as that
  -- and not as "what scouting is worth to Pathfinder".
  ["Pathfinder"]   = Policy.REACT_MIN,
}

-- A roster copy with cfg overridden per line. The definition table is rebuilt so
-- the original is untouched; `decide` and `init` are shared because they are
-- stateless functions of cfg (policy/Policy.lua's definitions-and-instances
-- block), which is the whole reason one engine drives sixteen configurations.
local function variant(scoutOn, thresholdBefore)
  local out = {}
  for i = 1, #linesM.LINES do
    local L = linesM.LINES[i]
    local c = {}
    for k = 1, #linesM.CFG_FIELDS do
      local key = linesM.CFG_FIELDS[k]
      c[key] = L.cfg[key]
    end
    local was = BEFORE[L.name]
    if was ~= nil then
      if not scoutOn then c.scout = 0 end
      if thresholdBefore then c.reactAt = was end
    end
    out[i] = { name = L.name, family = L.family, note = L.note,
               cfg = c, init = L.init, decide = L.decide }
  end
  return out
end

local function runAt(lines)
  Policy.setVision(Policy.VISION_FOG)
  return measure.roundRobin({ seeds = SEEDS, seedBase = SEEDBASE, lines = lines })
end

local function pmStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%d%%", neg and "-" or "", whole, a - whole * 10)
end

local function ppStr(d)
  local neg = d < 0
  local a = neg and -d or d
  local whole = floor(a / 10)
  return format("%s%d.%dpp", neg and "-" or "+", whole, a - whole * 10)
end

print("Idle Battle M2 -- what buying sight is worth, decomposed")
print(format("  matches     %d per variant (%d seeds per ordered pair), seed base %d",
  #linesM.LINES * (#linesM.LINES - 1) * SEEDS, SEEDS, SEEDBASE))
print(format("  regime      %s (the only regime in which a scout does anything:"
  .. " under \"full\" Policy.darkLane returns 0 in every lane)", Policy.VISION_FOG))
print(format("  scout       1 x unit type %d every %d ticks per side, bought after"
  .. " the same reserve as everything else",
  Policy.SCOUT_TYPE, Policy.SCOUT_EVERY))
print("")

local A = runAt(variant(false, true))
local B = runAt(variant(true, true))
local C = runAt(variant(true, false))

local function row(label, r)
  print(format("  %-34s %8s %8s %10s %8s", label,
    format("%d s", measure.secs(r.median)), pmStr(r.bandPm), pmStr(r.keepPm),
    pmStr(r.famSpread)))
end

print(format("  %-34s %8s %8s %10s %8s", "variant", "median", "band", "razedkeep", "spread"))
print("  ------------------------------------------------------------------------")
row("A  no sight, free thresholds", A)
row("B  + the body (thresholds as A)", B)
row("C  + the thresholds restored (SHIPS)", C)
print("")
print(format("  B - A  (what the body alone is worth)   band %s  keep %s  spread %s",
  ppStr(B.bandPm - A.bandPm), ppStr(B.keepPm - A.keepPm), ppStr(B.famSpread - A.famSpread)))
print(format("  C - B  (what the threshold is worth)    band %s  keep %s  spread %s",
  ppStr(C.bandPm - B.bandPm), ppStr(C.keepPm - B.keepPm), ppStr(C.famSpread - B.famSpread)))
print(format("  C - A  (the whole roster change)        band %s  keep %s  spread %s",
  ppStr(C.bandPm - A.bandPm), ppStr(C.keepPm - A.keepPm), ppStr(C.famSpread - A.famSpread)))
print("")

print("  per-line win rate, the four lines that buy sight and the twelve that do not")
print(format("  %-14s %4s %8s %8s %8s %9s", "line", "SC", "A", "B", "C", "C - A"))
print("  ------------------------------------------------------------------------")
for i = 1, #linesM.LINES do
  local L = linesM.LINES[i]
  print(format("  %-14s %4s %8s %8s %8s %9s", L.name,
    L.cfg.scout == 1 and "yes" or "-",
    pmStr(A.linePm[i]), pmStr(B.linePm[i]), pmStr(C.linePm[i]),
    ppStr(C.linePm[i] - A.linePm[i])))
end
print("")
print("READ:")
print("  * A body spent on sight is a body not spent on pressure: 15-19 scouts a")
print("    match at the default cadence (150-190 Levy, 12-14% of that line's")
print("    earnings) and 42.8 at Pathfinder's floor cadence (428 Levy, about a")
print("    quarter of a side's base income). A scouting line that does not gain")
print("    more than that back is telling you the mechanic is priced badly --")
print("    which is a finding about the ruleset and the doc, NOT a reason to")
print("    take the scout away again.")
print("  * B - A FOR Pathfinder IS THE ONE NUMBER IN THIS TABLE THAT CONTRADICTS")
print("    THE SIGHT AUDIT, and it is the most interesting thing here. The body")
print("    is worth double figures to it while sweep/fogaudit.lua measures the")
print("    sections it lights at +0.03 of 8. Whatever the tripwire buys, it is")
print("    not the section: the candidates are the CONTACT reveals of fog doc")
print("    3a (entity-scoped, so `lit` cannot see them at all) and a distributed")
print("    raid into the lane the enemy is not defending, which is what")
print("    Policy.darkLane picks by construction. Separating them needs a")
print("    variant whose scouts stop at the midline; it is not in this file yet.")
print("  * The twelve non-scouting lines move too, because their OPPONENTS")
print("    changed. Their column is the size of the second-order effect and it")
print("    is the reason a per-line delta here cannot be read as that line's")
print("    own doing.")
print("  * Nothing in sim/Rules.lua differs between the three variants.")
