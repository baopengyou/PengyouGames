-- sweep/fogaudit.lua -- WHICH LINES ARE WRITTEN AGAINST A BOARD THE FOG NEVER
-- DRAWS, AND HOW MUCH OF EACH LANE ANY LINE EVER LOOKS AT.
--
-- THE QUESTION. Every line in policy/lines.lua declares `reactAt`: the own-frame
-- position an enemy unit must reach before the line calls it a threat. Under
-- default vision an enemy unit is not rendered AT ALL until it is in my half, so
-- a `reactAt` at or below the midline names a position the fogged view reports
-- only when one of this line's OWN units happens to be standing in the same
-- 250-unit section. The predicate does not fail loudly; it silently becomes a
-- DIFFERENT one. A roster like that reports variance it does not have.
--
-- AND THE SECOND QUESTION, WHICH IS NEW AND IS THE MORE IMPORTANT ONE. The fog
-- doc makes vision something you BUY -- "send one cheap body forward and you buy
-- sight of exactly where it is standing, for exactly as long as it lives". So
-- the roster can now be asked a question it could not be asked under the muster
-- bar: how much of the board does any of these seventeen lines ever actually
-- LOOK at? The `lit` and `seen` columns answer it.
--
-- FIVE LINES NOW ANSWER IT DELIBERATELY, AT TWO DIFFERENT CADENCES, and the
-- report has to be able to tell them from the twelve that do not, or the columns
-- go on measuring where the roster FIGHTS. So the table carries each line's
-- declared scout CADENCE rather than a yes/no -- two lines that both buy sight,
-- one every 220 ticks and one every 86, are not doing the same thing.
--
-- AND `lit` IS THE WRONG COLUMN FOR THE ANSWER, WHICH IS WHY `EYE` IS BESIDE IT.
-- A tripwire lights ONE section of eight, so a line that buys sight in a tenth of
-- its lane-polls moves the MEAN by 0.1 and is indistinguishable from a line that
-- bought nothing. EYE is the same fact as a share of lane-polls -- can this line
-- see any part of the enemy half at all right now -- and it is the one that moves
-- when a line pays.
--
-- WHAT THIS FILE MEASURES, and it is deliberately not an opinion:
--
--   rendered    lane-polls in which this line saw ANY individual enemy unit.
--   minPos      the lowest own-frame position it EVER saw one at. Under default
--               vision alone this cannot be at or below the midline; a value
--               down there is proof the line's own units were scouting.
--   trig        lane-polls in which the line's OWN declared reactAt was
--               satisfied by a rendered unit.
--   SUB-MID     of those, the ones satisfied at a position at or below the
--               midline. Under "full" it is the share of a line's threat
--               detections the fog DELETES -- the defect, per line, in the
--               regime that can still see it. Under "fog" it is what this side
--               PAID FOR, and since the owner's section 3a it has TWO sources:
--               a body of this line's standing in that section (the scout) or
--               one of its units being in COMBAT with the enemy unit (contact).
--               Still 0.0% by construction for any line whose reactAt is above
--               the midline.
--   lit         mean sections of a lane this line can see RIGHT NOW, out of 8.
--               4.00 is a line that never leaves its own half: it buys no sight
--               at all and the enemy half is simply dark. Contact reveals are
--               ENTITY-scoped and never enter this column, which is the check
--               on that claim.
--   EYE         share of lane-polls in which `lit` is above its 4.00 floor:
--               "can I see any of the enemy half of this lane at all". Read it
--               instead of `lit` when the question is what a scout bought.
--   seen        mean sections it has EVER seen, out of 8 -- how much ground it
--               has explored and therefore how much building memory it holds.
--   blind       POLLS (not lane-polls) in which the enemy half of the board
--               carried NOTHING AT ALL: no rendered unit, no remembered
--               building, no visible Levy in any lane. It is the share of the
--               match in which "which lane is the enemy pressing?" HAS NO
--               ANSWER -- and Policy.pressedLane used to return lane 1 for every
--               one of them. EXPECT THIS TO BE HIGHER THAN IT WAS: the muster
--               bar was at least lit occasionally, and it is gone.
--
-- Run it under BOTH regimes. "full" says how much each line's declared threshold
-- was actually doing; "fog" says how much of that survives being rendered.
--
--   usage: lua sweep/fogaudit.lua [seedsPerPair] [vision]
--          seedsPerPair  default 2 (544 matches at 17 lines). A diagnostic, not a
--                        gate: it never asserts and always exits 0.
--          vision        "both" (default), "fog" or "full"
--
-- Held to sim/'s determinism rules like the rest of sweep/, and it cannot move a
-- match: sweep/driver.lua discards the tap's return value.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local linesM = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local measure = IB_SIM_MODULES and IB_SIM_MODULES.measure or require("sweep.measure")
local Fog = IB_SIM_MODULES and IB_SIM_MODULES.Fog or require("fog.Fog")

local floor = math.floor
local format = string.format

local SEEDS = tonumber(arg and arg[1]) or 2
local VISION = (arg and arg[2]) or "both"
if VISION ~= "both" and VISION ~= Policy.VISION_FOG and VISION ~= Policy.VISION_FULL then
  error("fogaudit: vision must be both / " .. Policy.VISION_FOG
    .. " / " .. Policy.VISION_FULL, 0)
end

local L = linesM.LINES
local NL = #L
local INDEX = {}
for i = 1, NL do INDEX[L[i].name] = i end

local NOPOS = 999999

local function newTally()
  local t = {}
  for i = 1, NL do
    t[i] = { polls = 0, rendered = 0, minPos = NOPOS, trig = 0, erased = 0,
             lit = 0, seen = 0, eye = 0, decisions = 0, blind = 0 }
  end
  return t
end

local function auditAt(mode)
  Policy.setVision(mode)
  local t = newTally()
  local tap = function(name, v, tick)
    local i = INDEX[name]
    if i == nil then return end
    local row = t[i]
    local reactAt = L[i].cfg.reactAt
    local anything = 0
    row.decisions = row.decisions + 1
    for lane = 1, v.laneCount do
      local f = v.foe.lanes[lane]
      row.polls = row.polls + 1
      if f.n > 0 or f.supply > 0 or f.frontB > 0 or f.backB > 0 then anything = 1 end
      -- Own sight of this lane. It is a fact about THIS line, not about the
      -- enemy, which is why it is the one aggregate the fog model permits.
      row.lit = row.lit + v.me.lanes[lane].lit
      row.seen = row.seen + v.me.lanes[lane].seen
      -- EYE: does this line have ANY live sight of the enemy half of this lane
      -- right now? `lit` is a mean over 8 sections and it drowns the answer: a
      -- tripwire lights ONE section, so a line that buys sight in a tenth of its
      -- lane-polls moves `lit` by 0.1 of a section and looks identical to a line
      -- that bought nothing. This column is the same fact in the units the
      -- decision is made in -- "can I see anything over there at all" -- and it
      -- is the one that moves when a line pays for eyes.
      if v.me.lanes[lane].lit > v.ownSections then row.eye = row.eye + 1 end
      if f.n > 0 then
        row.rendered = row.rendered + 1
        if f.maxPos < row.minPos then row.minPos = f.maxPos end
        if f.maxPos >= reactAt then
          row.trig = row.trig + 1
          -- Satisfied at a position default vision does not render. Under
          -- "fog" a non-zero cell here means the line's own units were in that
          -- section, which for this roster means its attack was there.
          if f.maxPos <= v.midline then row.erased = row.erased + 1 end
        end
      end
    end
    if anything == 0 then row.blind = row.blind + 1 end
    return tick
  end
  measure.roundRobin({ seeds = SEEDS, onPoll = tap })
  return t
end

-- Mean, to two places, in integers. A float here would be the one number in
-- the report that differed between two interpreters.
local function hundredths(num, den)
  if den == 0 then return "-" end
  local h = floor(num * 100 / den)
  local whole = floor(h / 100)
  local frac = h - whole * 100
  if frac < 10 then return format("%d.0%d", whole, frac) end
  return format("%d.%d", whole, frac)
end

local function pm(num, den)
  if den == 0 then return "-" end
  local p = measure.permille(num, den)
  local whole = floor(p / 10)
  return format("%d.%d%%", whole, p - whole * 10)
end

print("Idle Battle M2 -- fog audit of the roster's declared attention thresholds")
print(format("  matches     %d per regime (%d seeds per ordered pair)",
  NL * (NL - 1) * SEEDS, SEEDS))
print(format("  midline     %d   (with no scout, an enemy unit is rendered only ABOVE this)",
  Policy.MIDLINE))
print(format("  fog         %d sections of %d units; %d always visible, the rest bought with units",
  Fog.SECTIONS, Fog.SECTION_LEN, Fog.OWN_SECTIONS))
print("")

local function report(mode, t)
  print(format("== regime %s ==", mode))
  print(format("  %-14s %3s %7s %7s %8s %8s %7s %7s %7s %7s", "line", "SC", "reactAt",
    "minPos", "trig", "SUB-MID", "lit/8", "EYE", "seen/8", "blind"))
  print("  --------------------------------------------------------------------------------------")
  for i = 1, NL do
    local row = t[i]
    print(format("  %-14s %3s %7d %7s %8s %8s %7s %7s %7s %7s",
      L[i].name,
      -- The SCOUT column is the declared CADENCE, in ticks, not a yes/no. Two
      -- lines that both buy sight and buy it at 220 and 86 ticks are not doing
      -- the same thing, and a boolean column was what let the roster look like
      -- it spanned the axis when every scout on it sat at one point.
      L[i].cfg.scout == 1 and format("%d", L[i].cfg.scoutEvery) or "-",
      L[i].cfg.reactAt,
      row.minPos == NOPOS and "-" or format("%d", row.minPos),
      pm(row.trig, row.polls),
      row.trig == 0 and "-" or pm(row.erased, row.trig),
      hundredths(row.lit, row.polls), pm(row.eye, row.polls),
      hundredths(row.seen, row.polls),
      pm(row.blind, row.decisions)))
  end
  print("")
end

if VISION ~= Policy.VISION_FOG then report(Policy.VISION_FULL, auditAt(Policy.VISION_FULL)) end
if VISION ~= Policy.VISION_FULL then report(Policy.VISION_FOG, auditAt(Policy.VISION_FOG)) end

print("READ:")
print("  * SC is the line's declared scout CADENCE in ticks, or - for a line that")
print("    buys no sight. Five lines of seventeen buy it: Pathfinder at the")
print("    derived floor (every lane watched at once) and Raid-counter,")
print("    Turtle-eco, Counterpunch and Adaptive at the derived one-lane rate.")
print("    Every other column has to be read against this one, because a line")
print("    that pushes illuminates ground without ever having chosen to look.")
print("  * SUB-MID is the share of a line's own threat detections satisfied at or")
print("    BELOW the midline, and it means opposite things in the two regimes.")
print("    Under `full` it is the DEFECT: reads the fog deletes. Under `fog` it")
print("    is what this side PAID FOR -- and since the owner's section 3a it has")
print("    TWO sources, which is a change in what this column means: a body of")
print("    this line's standing in that section (the scout), or one of its units")
print("    being in combat with the enemy unit (contact). The second is why the")
print("    column moved for lines that never scouted a step. It is still 0.0% by")
print("    construction for any line whose reactAt is above the midline.")
print("  * minPos under fog is bounded below by the midline UNLESS this line had")
print("    a unit in the enemy section the sighting happened in. It reaches 0 for")
print("    every line eventually -- a unit that arrives at their keep watches")
print("    their reinforcements spawn -- so it says WHETHER a line ever gets")
print("    there, not whether it scouts.")
print("  * lit must be read against its floor of 4.00 -- the four home sections,")
print("    which cost nothing. Everything above 4.00 is sight this line has,")
print("    bought or incidental, and the SC column is what tells the two apart.")
print("    lit counts SECTIONS, so contact reveals do not enter it at all: doc")
print("    section 3a is entity-scoped, and this column is the check on that.")
print("  * EYE is the share of lane-polls in which lit is ABOVE that floor -- can")
print("    this line see any part of the enemy half of this lane at all right")
print("    now. Read it INSTEAD of lit when the question is what a scout bought:")
print("    a tripwire lights one section of eight, so a line that buys sight in a")
print("    tenth of its lane-polls moves lit by 0.10 and EYE by 10 points. On the")
print("    shipped roster, blinding all five scouts moves Pathfinder's lit by")
print("    0.04 and its EYE by 4.7 points -- the same fact, one of them legible.")
print("    A deliberate scout shows as lit and SUB-MID rising TOGETHER while the")
print("    line's attack does not; an attacker shows lit rising alone.")
print("  * seen climbs for lines that push (it is cumulative and never falls) and")
print("    stays near 4 for lines that do not, so on its own it is a proxy for")
print("    aggression. Skirmish is the control that proves it: it tops the column")
print("    without spending one body ON sight.")
print("  * blind is the share of a line's decisions taken against an enemy half")
print("    that shows nothing whatever. Nothing may claim to know where the")
print("    pressure is during those polls, and a scouting line buying it down is")
print("    exactly what it is paying for.")
