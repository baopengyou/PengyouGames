-- fog/Fog.lua -- the fog of war model of ../docs/IDLE_BATTLE_FOG.md.
--
-- WHY THIS DIRECTORY AND NOT sim/
-- The task asked for sim/Fog.lua "or the natural home given the existing
-- layout". It is not sim/, and the reason is the strongest invariant in the
-- tree rather than a matter of taste:
--
--   1 A.5 GREP 1 IS A STATEMENT ABOUT A DIRECTORY. tools/greps.sh and
--     tools/greps.lua DISCOVER their file list from sim/ and assert that no file
--     in it mentions Fog. or any visibility predicate. Put the fog model inside
--     sim/ and that sentence becomes self-referential: the directory that must
--     not be able to ask what is visible now defines what is visible, and the
--     only thing still stopping Sim.lua from calling it is a regex over the
--     directory that exports it. Outside sim/ the guarantee is STRUCTURAL --
--     there is no fog module inside the sim's require namespace at all.
--   2 M7'S PROOF NEEDS FOG TO BE A SEPARATE ARTIFACT. The README states it:
--     "a match with Fog.Visible stubbed to always-true produces a bit-identical
--     hash". That experiment is only meaningful if the fog model can be swapped
--     or stubbed without editing anything under sim/.
--   3 NEITHER CONSUMER IS THE SIM. This module has exactly two: the renderer
--     (M7) and policy/Policy.lua's view builder (M2). sim/ loads neither.
--
-- So fog/ is a sibling of sim/, policy/ and sweep/, and it is HELD TO THE SIM'S
-- DETERMINISM RULES exactly as policy/ and sweep/ are, because the M2 policies
-- consume it and a policy that perceives differently on two machines writes a
-- different command log: integer arithmetic only, every "/" inside math.floor,
-- no pairs(), no math.random, no clock, and no knowledge of which side is local.
-- tools/ci.sh runs greps.sh, greps.lua and comptest.sh over this directory.
--
-- ---------------------------------------------------------------------------
-- WHAT THE MODEL IS, in the doc's own order
--
--   1 SECTIONS.   A lane is 8 vision sections. Section 1 holds your keep, 2 your
--                 back slot, 3 your front slot, 4 the run up to the midline;
--                 5-8 are the mirror image on their side, with their front slot
--                 in 6, their back slot in 7 and their keep in 8.
--   2 DEFAULT.    Sections 1-4 are always visible, exactly. Sections 5-8 are not
--                 visible at all. An approaching enemy is INVISIBLE until it
--                 crosses the midline. There is no aggregate, no early warning
--                 and no "something is coming" indicator -- which is why the
--                 muster bar this file replaces had to be deleted rather than
--                 rescaled.
--   3 DYNAMIC.    A section is visible while at least one of YOUR units is
--                 inside it. That section, not the ones before or after it.
--  3a CONTACT.    A unit ALSO reveals any enemy entity it is IN COMBAT WITH,
--                 whatever section that entity is in. Entity-scoped, never
--                 section-scoped: fighting a palisade shows you the palisade and
--                 nothing standing behind it. See the CONTACT block below.
--   4 MEMORY.     Anything you have seen persists frozen at its last-seen state
--                 and never updates until seen again. Enemy BUILDINGS and the
--                 enemy KEEP's HP are remembered. Enemy UNITS are NOT.
--   5 SHIELD.     Their back slot is visible only when their front slot in that
--                 lane is empty or destroyed AND one of your units is in
--                 section 7.
--   6 MODIFIERS.  A completed vision-granting front building (Watchtower) makes
--                 sections 5 and 6 of its own lane permanently visible. The
--                 Shrine's reveal pulse, Divination, Omen and Veil -- the four
--                 M3 information effects, LIVE since M3 part 2 -- are the INFO
--                 EFFECTS block below, consuming sim/Mods.lua's INFO_EFFECTS
--                 handoff and the hashed SHRINE_PULSE_* constants.
--   7 NEVER.      Enemy Levy, bank, income, spending and loadout are not spatial
--                 and are never visible by any route -- including every route
--                 the M3 cards add (doc section 7 has no card-shaped exception).
--
-- ---------------------------------------------------------------------------
-- FRAMES, WHICH IS THE ONE PLACE THIS IS EASY TO GET WRONG
--
-- C.1 stores every position in its OWNER'S frame: u.pos is that unit's distance
-- from ITS OWN keep. Sections are numbered in the OBSERVER'S frame, from the
-- observer's keep outward. So:
--
--   my own entity at own-frame p     -> observer coordinate p
--   an enemy entity at own-frame q   -> observer coordinate LANE_LEN - q
--
-- and both go through the same sectionAt(). That is what keeps this side-
-- agnostic (A.2): there is no "my end of the lane" anywhere in the arithmetic,
-- so the same code answers for side 1 and side 2 and the mirror test holds.
--
-- Checked against the ruleset, not asserted in a comment: the enemy front slot
-- (own-frame POS_FRONT_SLOT) lands in section 6, the enemy back slot in 7 and
-- the enemy keep in 8, which is the doc's own table. The CHECKS block below
-- fails at load if a ruleset change ever moves one of them.

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
-- sim/Mods.lua is loaded ONLY for its INFO_EFFECTS handoff surface -- the
-- declared names of the four perception effects whose numbers live in the
-- hashed ruleset and whose semantics live HERE (M3 part 2). Requiring it has no
-- side effects (install() runs only when Sim.new calls it), and the dependency
-- points the allowed way: fog/ may read sim/'s declarations, sim/ can never
-- read fog/ (A.5 grep 1 makes that structural).
local Mods = IB_SIM_MODULES and IB_SIM_MODULES.Mods or require("sim.Mods")

local M = {}

local floor = math.floor

local C = Rules.C

-- ---------------------------------------------------------------------------
-- SECTION ARITHMETIC, derived from the ruleset and never written down twice.
--
-- The doc contributes exactly ONE number this ruleset does not already carry:
-- each half of a lane is cut into four. Everything else falls out --
--
--   SECTION_LEN = POS_MIDLINE / SECTIONS_PER_HALF  = 1000 / 4 = 250
--   SECTIONS    = LANE_LEN    / SECTION_LEN        = 2000 / 250 = 8
--
-- 250 and 8 are therefore RESULTS. If C.LANE_LEN or C.POS_MIDLINE ever moves,
-- this file follows it or refuses to load; it can never quietly disagree with
-- sim/Rules.lua about where the midline is, which is the failure the "never
-- hardcode a ruleset value twice" rule exists to prevent.
-- ---------------------------------------------------------------------------

M.SECTIONS_PER_HALF = 4
M.SECTION_LEN = floor(C.POS_MIDLINE / M.SECTIONS_PER_HALF)
M.SECTIONS = floor(C.LANE_LEN / M.SECTION_LEN)

-- Sections 1..OWN_SECTIONS are visible unconditionally (doc section 2).
M.OWN_SECTIONS = M.SECTIONS_PER_HALF

-- The section an entity at OBSERVER COORDINATE `x` stands in. Clamped at both
-- ends: x == LANE_LEN is the enemy keep and belongs to the last section rather
-- than to a ninth one that does not exist.
function M.sectionAt(x)
  local s = floor(x / M.SECTION_LEN) + 1
  if s < 1 then return 1 end
  if s > M.SECTIONS then return M.SECTIONS end
  return s
end

-- The section one of the OBSERVER'S OWN entities occupies, from its own-frame
-- position (u.pos, a building's slot position, the observer's keep at 0).
function M.sectionOfOwn(pos)
  return M.sectionAt(pos)
end

-- The section an ENEMY entity occupies in the OBSERVER'S numbering, from that
-- entity's OWN-frame position. This is the whole frame conversion.
function M.sectionOfEnemy(pos)
  return M.sectionAt(C.LANE_LEN - pos)
end

-- The OBSERVER COORDINATE of each fixed enemy structure -- the same conversion
-- sectionOfEnemy makes, stopped one step earlier. Section 3a needs the distance
-- from one of my units to their wall, and a distance cannot be measured in
-- section numbers. Derived here so there is one frame conversion in the file.
M.OBS_ENEMY_FRONT = C.LANE_LEN - C.POS_FRONT_SLOT       -- 1300
M.OBS_ENEMY_BACK  = C.LANE_LEN - C.POS_BACK_SLOT        -- 1700
M.OBS_ENEMY_KEEP  = C.LANE_LEN - C.POS_OWN_KEEP         -- 2000

-- The doc's table, derived rather than transcribed.
M.SEC_OWN_KEEP    = M.sectionOfOwn(C.POS_OWN_KEEP)      -- 1
M.SEC_OWN_BACK    = M.sectionOfOwn(C.POS_BACK_SLOT)     -- 2
M.SEC_OWN_FRONT   = M.sectionOfOwn(C.POS_FRONT_SLOT)    -- 3
M.SEC_ENEMY_FRONT = M.sectionOfEnemy(C.POS_FRONT_SLOT)  -- 6
M.SEC_ENEMY_BACK  = M.sectionOfEnemy(C.POS_BACK_SLOT)   -- 7
M.SEC_ENEMY_KEEP  = M.sectionOfEnemy(C.POS_OWN_KEEP)    -- 8

-- The lowest own-frame position at which an ENEMY unit is rendered under
-- DEFAULT vision, i.e. with none of the observer's units past the midline. It
-- is the first position that lands in section OWN_SECTIONS, which is the
-- midline plus one -- derived, so a roster constant cannot drift from it.
M.DEFAULT_SIGHT = C.POS_MIDLINE + 1

-- The lowest OWN-FRAME position an ENEMY entity can hold and still land inside
-- observer section `s`. Sections count outward from the OBSERVER's keep, so a
-- higher section is a LOWER enemy own-frame position -- section 5 is observer
-- coordinates 1000..1249, which is enemy own-frame 751..1000, i.e. their units
-- while they are still 751-1000 units from their OWN keep.
--
-- WHY THIS IS HERE AND NOT IN THE POLICY LAYER. It is section arithmetic, and
-- the README's checklist item 9 is explicit that "what anything can SEE" has one
-- home. A scouting line needs to name the deepest warning a bought section can
-- give it; deriving that in policy/ would be a second copy of the section table,
-- which is the drift this module exists to prevent.
--
-- The last section is special and the clamp says so: sectionAt() folds observer
-- coordinate LANE_LEN (their keep, own-frame 0) into the last section rather
-- than into a ninth one, so section SECTIONS reaches all the way to their keep.
function M.enemyPosLowOfSection(s)
  if s >= M.SECTIONS then return C.POS_OWN_KEEP end
  return C.LANE_LEN - (s * M.SECTION_LEN - 1)
end

-- THE DEEPEST EARLY WARNING SIGHT CAN BUY AT THE MIDLINE. One of your own bodies
-- standing in the first fogged section renders enemy units at own-frame
-- SCOUT_SIGHT and above -- 751 here, so 250 units of their march, which is
-- 12 sim ticks of a Horse and 25 of a Spear. It is the honest floor for a line
-- whose intent is "answer a push before it arrives": below this a threshold
-- needs a body deeper than the midline, and it is satisfiable only for as long
-- as that body lives.
M.SCOUT_SIGHT = M.enemyPosLowOfSection(M.OWN_SECTIONS + 1)

-- ---------------------------------------------------------------------------
-- CHECKS. The doc's section table, asserted against the ruleset at load time.
-- A ruleset edit that moved a slot or the midline without moving this model
-- would otherwise ship two disagreeing maps, and the disagreement would surface
-- as a rendering bug months later rather than as a failed load now.
-- ---------------------------------------------------------------------------

local function must(ok, why)
  if not ok then error("Fog: " .. why, 0) end
end

must(M.SECTION_LEN * M.SECTIONS_PER_HALF == C.POS_MIDLINE,
  "POS_MIDLINE is not divisible into whole sections per half")
must(M.SECTION_LEN * M.SECTIONS == C.LANE_LEN,
  "LANE_LEN is not a whole number of sections")
must(C.POS_MIDLINE * 2 == C.LANE_LEN,
  "the midline is not the middle of the lane; the section table assumes it is")
must(M.SECTIONS == M.SECTIONS_PER_HALF * 2,
  "the two halves do not hold the same number of sections")
must(M.SEC_OWN_KEEP == 1, "the observer keep is not in section 1")
must(M.SEC_OWN_BACK == 2, "the observer back slot is not in section 2")
must(M.SEC_OWN_FRONT == 3, "the observer front slot is not in section 3")
must(M.sectionOfOwn(C.POS_MIDLINE - 1) == M.OWN_SECTIONS,
  "the last position of the observer half is not in the last always-visible section")
must(M.sectionOfEnemy(C.POS_MIDLINE - 1) == M.OWN_SECTIONS + 1,
  "the first position past the midline is not in the first fogged section")
must(M.SEC_ENEMY_FRONT == 6, "the enemy front slot is not in section 6")
must(M.SEC_ENEMY_BACK == 7, "the enemy back slot is not in section 7")
must(M.SEC_ENEMY_KEEP == M.SECTIONS, "the enemy keep is not in the last section")
-- enemyPosLowOfSection is the inverse of sectionOfEnemy at each section's deep
-- edge, and one unit deeper belongs to the NEXT section. Asserted in both
-- directions so the two can never drift.
for s = M.OWN_SECTIONS + 1, M.SECTIONS do
  local lo = M.enemyPosLowOfSection(s)
  must(M.sectionOfEnemy(lo) == s,
    "enemyPosLowOfSection is not inside the section it names")
  if s < M.SECTIONS then
    must(M.sectionOfEnemy(lo - 1) == s + 1,
      "one position below enemyPosLowOfSection is not in the next section")
  else
    must(lo == C.POS_OWN_KEEP,
      "the last section does not reach the enemy keep")
  end
end
must(M.SCOUT_SIGHT > C.POS_OWN_KEEP and M.SCOUT_SIGHT < C.POS_MIDLINE,
  "the sight bought at the midline does not reach into the enemy half")
-- Doc 3a needs distances, so the observer coordinates of the fixed enemy
-- structures must land in the same sections the section table names for them.
-- Two conversions of one number is exactly the drift this block exists to catch.
must(M.sectionAt(M.OBS_ENEMY_FRONT) == M.SEC_ENEMY_FRONT,
  "the enemy front slot's observer coordinate is not in its own section")
must(M.sectionAt(M.OBS_ENEMY_BACK) == M.SEC_ENEMY_BACK,
  "the enemy back slot's observer coordinate is not in its own section")
must(M.sectionAt(M.OBS_ENEMY_KEEP) == M.SEC_ENEMY_KEEP,
  "the enemy keep's observer coordinate is not in its own section")
-- THE FRONT-SLOT SHIELD, AS THE GEOMETRY THE DOC CLAIMS IT IS. Section 3a keeps
-- section 5's shield "fully intact" on the grounds that "a unit cannot reach the
-- back building while the front one still stands". That is a statement about
-- BUILD_BLOCKS_ADVANCE and the two slot positions, and it is asserted here for
-- every body in the catalogue: a unit halted at range of an occupied front slot
-- is still further than its own range from the back one. If a ruleset edit ever
-- moved the slots closer together than a weapon, this file refuses to load
-- rather than shipping a shield that silently leaks.
for i = 1, #Rules.UNITS do
  local r = Rules.UNITS[i].range
  must(M.OBS_ENEMY_BACK - (M.OBS_ENEMY_FRONT - r) > r,
    "a unit stopped by an intact front building would be in contact with the back one")
end

-- Ruleset identity. A consumer holding a second ruleset would be reading a
-- different map than the one these constants were derived from.
function M.checkRuleset(rules)
  if rules == nil then return Rules end
  if rules.rulesHash ~= Rules.rulesHash then
    error("Fog: this module derived its section table from a different ruleset", 0)
  end
  return rules
end

-- Slot numbering (Rules INTERPRETATIONS 1). Local copies, because reaching into
-- policy/ from here would invert the dependency: policy consumes fog.
local function frontSlotOf(lane) return (lane - 1) * 2 + 1 end
local function isFrontSlot(slot) return (slot % 2) == 1 end
M.frontSlot = frontSlotOf
function M.backSlot(lane) return (lane - 1) * 2 + 2 end
M.isFrontSlot = isFrontSlot
function M.laneOfSlot(slot) return floor((slot - 1) / 2) + 1 end

-- ---------------------------------------------------------------------------
-- VISION MODIFIERS that exist in the M1 ruleset (doc section 6)
--
-- Watchtower is the only building in C.4 with a non-zero `vision`, and this is
-- read off the HASHED ruleset rather than matched by key: a future building
-- that grants sight gets the same treatment with no edit here, and there is no
-- second copy of a catalogue letter for rulesHash to be unable to see.
--
-- TWO READINGS ARE RECORDED HERE BECAUSE THEY ARE CHOICES, NOT DEDUCTIONS:
--
--   * EXTENT. The doc says "sections 5 and 6", so the extent is expressed in
--     sections and not in the ruleset's `vision = 600` units. Those two do not
--     agree: 600 units from the front slot at 700 reaches 1300, which is the
--     first unit of section 6, so a literal reading of the ruleset field would
--     grant section 5 and one position of section 6. The doc wins (it is
--     binding and later), and `vision = 600` is now a ruleset value with no
--     consumer. It is INSIDE rulesHash so it cannot be deleted here without a
--     compatibility break -- escalated to the doc owner instead.
--   * COMPLETION. "while it stands" is read as "while it stands COMPLETED",
--     per Rules INTERPRETATIONS 4: an under-construction building occupies the
--     slot and blocks but produces no effect until done. A tower that scouts
--     for you while it is scaffolding would be the only exception in the
--     ruleset.
-- ---------------------------------------------------------------------------

M.VISION_SECTION_LO = M.SECTIONS_PER_HALF + 1   -- 5
M.VISION_SECTION_HI = M.SECTIONS_PER_HALF + 2   -- 6

M.GRANTS_VISION = {}
for i = 1, #Rules.BUILDINGS do
  M.GRANTS_VISION[i] = (Rules.BUILDINGS[i].vision > 0) and 1 or 0
end

-- ---------------------------------------------------------------------------
-- THE M3 INFORMATION EFFECTS (doc section 6; M3 part 2)
--
-- Divination, Omen, Veil and the Shrine's reveal pulse. Their sim-side
-- existence -- card ids, affinity, hashing, loadout legality, the pulse
-- constants -- landed in M3 part 1 and is deliberately inert there: Ruling 1
-- shares the whole state, so what these four change is what a client RENDERS,
-- and that is this module's jurisdiction and nobody else's.
--
-- WHO IS RESOLVED FROM WHAT. The names come from sim/Mods.lua's declared
-- handoff surface (Mods.INFO_EFFECTS) and are resolved against the HASHED
-- ruleset -- three of the four are cards (Rules.CARD_BY_KEY) and the fourth is
-- a building ability (the Shrine, matched by catalogue key, because unlike the
-- Watchtower's `vision` field the ruleset carries no flag for "emits the reveal
-- pulse" -- the pulse CONSTANTS are hashed in Rules.C but the emitter is named
-- only by the handoff). An INFO_EFFECTS entry this block does not recognise
-- refuses to load: an under-modelled information source must fail the build,
-- not silently render as fog.
--
-- WHAT EACH ONE REVEALS is implemented at the point it applies and cross-
-- referenced here:
--
--   Divination   the SCRY layer in observe(), plus divinedBuilding() for a
--                live consumer. All COMPLETED enemy buildings, slot and
--                identity, continuously, every lane, ignoring both the section
--                rule and the front-slot shield. NEVER HP, never under
--                construction. Beaten by Veil, absolutely.
--   Omen         omenPending(). Enemy deploy orders surfaced as issued, lane
--                and count only, NEVER unit type. Temporal, not spatial: it is
--                a filter over the shared command queue, not new data.
--   Veil         not a reveal but an EXEMPTION, threaded through every
--                predicate that shows a building. The precedence rule is ONE
--                SENTENCE and it is stated at veiled() below.
--   Shrine pulse the pulse window plus the OCC layer in observe(). While a
--                completed Shrine of yours stands, every SHRINE_PULSE_EVERY
--                ticks for SHRINE_PULSE_TICKS: all enemy units in all lanes at
--                full detail, plus enemy building OCCUPANCY only -- not
--                identity, not HP.
--
-- SELF-ANNOUNCEMENT (Q9b: information modifiers announce themselves; "seeing
-- costs being seen") is PRESENTATION and lands in M7. What this module owns is
-- the fact the announcement discloses, as marks() -- so the renderer and the
-- policy view read one predicate instead of each reaching into the enemy
-- loadout, which doc section 7 forbids rendering.
-- ---------------------------------------------------------------------------

M.CARD_DIVINATION = 0
M.CARD_OMEN = 0
M.CARD_VEIL = 0
M.BLD_SHRINE = 0
for i = 1, #Mods.INFO_EFFECTS do
  local name = Mods.INFO_EFFECTS[i]
  if name == "divination" then
    M.CARD_DIVINATION = Rules.CARD_BY_KEY[name] or 0
  elseif name == "omen" then
    M.CARD_OMEN = Rules.CARD_BY_KEY[name] or 0
  elseif name == "veil" then
    M.CARD_VEIL = Rules.CARD_BY_KEY[name] or 0
  elseif name == "shrine" then
    for b = 1, #Rules.BUILDINGS do
      if Rules.BUILDINGS[b].key == name then M.BLD_SHRINE = b end
    end
  else
    error("Fog: sim/Mods.lua hands off an information effect this model does not implement: "
      .. tostring(name), 0)
  end
end
must(M.CARD_DIVINATION > 0, "the Divination card is not in the hashed pool")
must(M.CARD_OMEN > 0, "the Omen card is not in the hashed pool")
must(M.CARD_VEIL > 0, "the Veil card is not in the hashed pool")
must(M.BLD_SHRINE > 0, "the Shrine building is not in the hashed catalogue")
must(C.SHRINE_PULSE_TICKS > 0 and C.SHRINE_PULSE_TICKS < C.SHRINE_PULSE_EVERY,
  "the Shrine pulse must be briefer than its own cadence or 'periodically, briefly' is neither")

-- Does `side`'s loadout hold card id `cardId`? A read of hashed state
-- (sd.loadout has been inside Hash.state since M1), five comparisons.
function M.hasCard(sim, side, cardId)
  local lo = sim.sides[side].loadout
  for i = 1, 5 do
    if lo[i] == cardId then return true end
  end
  return false
end

-- THE VEIL PRECEDENCE RULE, in one sentence:
--
--   VEIL BEATS EVERY ROUTE THAT DOES NOT PUT A BODY THERE. A veiled side's
--   buildings are exempt from Divination, from the Shrine pulse's occupancy
--   scan and from REMOTE section light (the Watchtower's permanent sections);
--   they are still shown by a unit of yours standing in the section (doc
--   sections 2-3) and by contact (doc section 3a) -- and Veil conceals
--   BUILDINGS ONLY, never units, so no unit predicate consults it.
--
-- WHY THIS IS THE RULE AND NOT ONE OF ITS NEIGHBOURS. Three texts overlap
-- here and no two use the same words: the fog doc's section 6 row says
-- "exempt from every disclosure route ABOVE" (its table's rows: Watchtower,
-- Shrine pulse, Divination); D.3's normative card wording says "every source
-- EXCEPT contact reveal and destruction" and "beats Divination and Shrine
-- pulses absolutely"; and D.3's sentence predates the section model -- it was
-- written against Q9a's old disclosure-trigger list, where "every source"
-- could not have meant the section rule because the section rule did not
-- exist. The reading that satisfies all three at once is the one above:
-- remote scrying (tower, pulse, divination) is beaten absolutely, physical
-- presence (a body in the section, a weapon on the wall) is not -- which also
-- keeps 3a's promise ("you can see what you are fighting") unconditional,
-- exactly as D.3's contact exception demands. The one point where the texts
-- genuinely diverge -- whether a veiled building hides from a PLAIN unit-lit
-- section -- is escalated as README open item 25 rather than smoothed; this
-- implementation shows it, because the alternative deletes the base model's
-- section rule for one card and reintroduces the grinding-a-wall-you-cannot-
-- see absurdity that 3a exists to remove.
function M.veiled(sim, side)
  return M.hasCard(sim, side, M.CARD_VEIL)
end

-- A completed Shrine of `side`'s, standing right now. Under-construction does
-- not pulse (Rules INTERPRETATIONS 4: no effect until complete), and the
-- effect dies with the building exactly as the Watchtower's sight does.
function M.shrineStands(sim, side)
  local sd = sim.sides[side]
  for s = 1, C.SLOTS do
    local b = sd.slots[s]
    if b and b.done == 1 and b.b == M.BLD_SHRINE then return true end
  end
  return false
end

-- Is `side`'s reveal pulse live on this tick? The schedule is the HEX rule
-- (Rules INTERPRETATIONS 24) applied to the hashed pulse constants: live at
-- tick t iff t mod SHRINE_PULSE_EVERY < SHRINE_PULSE_TICKS -- windows [0,30),
-- [200,230), ... anchored at tick 0, because that is the one anchor the
-- documents already use for a fixed schedule ("on a fixed schedule from tick
-- 0") and it needs no per-building state. A Shrine completed mid-window joins
-- the window in progress; one that dies mid-window ends it that tick.
function M.shrinePulseActive(sim, side)
  if sim.clock % C.SHRINE_PULSE_EVERY >= C.SHRINE_PULSE_TICKS then return false end
  return M.shrineStands(sim, side)
end

-- What Divination shows the observer in enemy slot `slot`, LIVE: the identity
-- of a COMPLETED building there, or 0 -- for an empty slot, for scaffolding
-- (never under construction, D.3's own amendment), for a slot the observer has
-- no Divination to scry with, and for a veiled enemy, whose every scry is
-- empty ("a diviner facing Veil gets an empty scry"). Identity means the
-- catalogue index and the fact it is complete; NEVER HP -- there is no HP in
-- the return and no route to one.
function M.divinedBuilding(sim, side, slot)
  if not M.hasCard(sim, side, M.CARD_DIVINATION) then return 0 end
  if M.veiled(sim, 3 - side) then return 0 end
  local b = sim.sides[3 - side].slots[slot]
  if b and b.done == 1 then return b.b end
  return 0
end

-- OMEN: enemy deploy orders surfaced as issued -- lane and count only, NEVER
-- unit type. Returns (orders, units) pending into `lane` for an observer
-- holding the card; (0, 0) otherwise.
--
-- THE DETERMINISTIC REPRESENTATION, which fog open item 16 asked for. The
-- shared command queue already holds every accepted atom on both clients
-- (that is how the sim executes it later), so Omen is a FILTER over known
-- data and never new data: an enemy deploy order is surfaced while it is
-- still pending in sim.bucket AND the clock has reached its exec tick minus
-- ORDER_DELAY. Everything in that sentence is an integer both clients hold --
-- the exec tick is the hashed field of the atom, and exec - ORDER_DELAY is
-- the LATEST tick the atom can have been issued on (A.11 requires exec in
-- [issue + ORDER_DELAY, issue + ORDER_DELAY_CLAMP]), so the window is the
-- doc's own gloss, "one order-delay before it takes the field", derived
-- without touching issueTick -- which is wire metadata the sim's contract
-- deliberately excludes (Rules INTERPRETATIONS 12). The window closes when
-- the order executes and its bucket entry is consumed: what lands on the
-- field is thereafter the section rule's problem, and no omen signal is ever
-- REMEMBERED -- a stale wave warning is the same trap as a ghosted stack
-- (doc section 4), so there is no omen field in the memory store.
--
-- TWO HONEST CAVEATS, stated rather than discovered:
--   * an atom queued LATER than exec - ORDER_DELAY (a resend that only just
--     made it, A.12) surfaces late -- from arrival -- so a lossy wire can only
--     SHORTEN the warning, never lengthen it. Under-estimate, the safe
--     direction.
--   * an atom issued with a delay above the minimum surfaces from
--     exec - ORDER_DELAY, which is later than its true issue tick. Same
--     direction. The M2 driver issues every atom at the minimum delay and
--     queues it on its issue tick, so under the policy layer the window IS
--     "from the issue tick" exactly, and sweep/determinism.lua holds it to
--     byte-identical replay.
--
-- The count surfaced is clamped to MAX_UNITS_PER_ORDER exactly as execDeploy
-- will clamp it: the order surfaced is the order that can take the field.
-- cmd.cls is Sim.lua's own class code (kindIdx = cls * 100 + index; deploys
-- are class 1); the UNIT TYPE inside kindIdx is deliberately never read.
--
-- pendingDeploys is the raw filter and omenPending is the card gate over it.
-- They are separate because the FULL information regime must stay a strict
-- superset of the fogged one (the muster-bar lesson, README Finding 7): the
-- pending queue is on every client under Ruling 1, so the upper bound carries
-- the signal with no card, and only the fogged view charges a loadout slot
-- for it.
local CLS_UNIT_CODE = 1
function M.pendingDeploys(sim, side, lane)
  local RC = sim.rules.C
  local foe = 3 - side
  local nOrders, nUnits = 0, 0
  local hi = sim.clock + RC.ORDER_DELAY
  local maxN = RC.MAX_UNITS_PER_ORDER
  for t = sim.clock, hi do
    local b = sim.bucket[t]
    if b then
      for i = 1, #b do
        local cmd = b[i]
        if cmd.side == foe and cmd.cls == CLS_UNIT_CODE and cmd.target == lane then
          nOrders = nOrders + 1
          local n = cmd.count
          if n > maxN then n = maxN end
          nUnits = nUnits + n
        end
      end
    end
  end
  return nOrders, nUnits
end

function M.omenPending(sim, side, lane)
  if not M.hasCard(sim, side, M.CARD_OMEN) then return 0, 0 end
  return M.pendingDeploys(sim, side, lane)
end

-- The Q9b self-announcing marks, from the WATCHED side's chair: am I being
-- scried (their Divination, "at tick 0, persistent"), are my orders being
-- read (their Omen, same), am I being scanned RIGHT NOW (their pulse)? Veil
-- is the sole non-announcing source and so has no mark, by ruling. These are
-- the sanctioned partial disclosures of an enemy loadout nothing else may
-- render (doc section 7), which is why they are one predicate here instead
-- of two consumers each reaching into sd.loadout.
function M.marks(sim, side)
  local foe = 3 - side
  local scried = M.hasCard(sim, foe, M.CARD_DIVINATION) and 1 or 0
  local omened = M.hasCard(sim, foe, M.CARD_OMEN) and 1 or 0
  local scanned = M.shrinePulseActive(sim, foe) and 1 or 0
  return scried, omened, scanned
end

-- ---------------------------------------------------------------------------
-- VISIBLE SECTIONS
--
-- `out[s]` is 1 if the observer can see section s of that lane, 0 otherwise.
-- Pass a table to reuse it; one is allocated when you do not, so a caller that
-- keeps the result cannot be handed shared scratch by accident.
-- ---------------------------------------------------------------------------

function M.visibleSections(sim, side, lane, out)
  if out == nil then out = {} end
  local own = M.OWN_SECTIONS
  for s = 1, M.SECTIONS do
    if s <= own then out[s] = 1 else out[s] = 0 end
  end

  local sd = sim.sides[side]

  -- Doc section 3: one of your units lights the section it currently occupies,
  -- and nothing else.
  local us = sd.lanes[lane].units
  for i = 1, #us do
    out[M.sectionOfOwn(us[i].pos)] = 1
  end

  -- Doc section 6: a completed vision-granting front building, its own lane
  -- only, while it stands.
  local fb = sd.slots[frontSlotOf(lane)]
  if fb and fb.done == 1 and M.GRANTS_VISION[fb.b] == 1 then
    out[M.VISION_SECTION_LO] = 1
    out[M.VISION_SECTION_HI] = 1
  end

  return out
end

-- Module scratch for the internal per-entity predicates. Reused, never handed
-- out, and safe under the determinism rules for the same reason sim.cg is: it
-- is written before it is read inside one call and nothing reads it across
-- calls, so no table address and no iteration order can reach a result.
local SCRATCH = {}
for s = 1, M.SECTIONS do SCRATCH[s] = 0 end

function M.seesSection(sim, side, lane, section)
  local vis = M.visibleSections(sim, side, lane, SCRATCH)
  return vis[section] == 1
end

-- ---------------------------------------------------------------------------
-- CONTACT REVEALS (doc section 3a, owner ruling 2026-08-13)
--
--   "A unit also reveals any enemy entity it is in combat with, whatever
--    section that entity is in. You can see what you are fighting."
--
-- WHAT THIS FIXES. Melee range is 60 and their front slot is at observer
-- coordinate 1300, so BUILD_BLOCKS_ADVANCE stops an attacker at 1240 -- which is
-- section 5 while the wall is in section 6. Read strictly, section 3 said a
-- soldier grinding a wall could not see the wall (README open item 13). The
-- SAME defect exists on the defending side and had not been written down: two
-- melee stacks that meet just past the midline stop 60 apart, so a defender
-- holding at 990 is being killed by a stack at 1050 that section 5 does not
-- render for it. Both are one rule.
--
-- HOW CONTACT IS DETERMINED FROM THE SHARED STATE, AND WHY IT IS THIS.
-- An enemy entity is in contact with one of the observer's units when it lies
-- inside that unit's WEAPON ENVELOPE:
--
--     | observer coordinate of the entity - my unit's position | <= my range
--
-- which is character for character the test Sim.unitAttacks applies when it
-- chooses what to hit (`g <= range`, with `g` the absolute gap in the asking
-- side's frame). Taking the sim's own predicate rather than inventing a second
-- one buys three properties:
--
--   1 "AM I FIGHTING IT" AND "DO I SEE IT" ARE ONE COMPARISON, so they cannot
--     disagree. A unit whose envelope covers a palisade is a unit that hits that
--     palisade on the next resolve tick.
--   2 IT DOES NOT DEPEND ON THE RESOLVE GRID. Combat resolves every
--     RESOLVE_EVERY ticks and picks at most `targets` victims out of the
--     envelope; vision is per tick and per entity. So contact is the ENVELOPE
--     and not the subset the resolve loop selected -- otherwise a Bow standing
--     among five bodies would see three of them and WHICH three would depend on
--     entity ids, which is a rendering rule nobody would write down.
--   3 IT IS DETERMINISTIC AND SIDE-AGNOSTIC. Every term is an integer read of
--     hashed state through the same frame conversion the section rule uses;
--     there is no "my end of the lane" in it and no side is named.
--
-- IT IS THE OBSERVER'S OWN ENVELOPE, AND THAT ASYMMETRY IS A CHOICE. The
-- relation "X is inside Y's range" is symmetric whenever the two ranges are
-- equal, which is every melee engagement in C.3 (Spear and Horse are both 60) --
-- so a defender in contact does see its attacker, and a unit grinding a building
-- sees the building. It is NOT symmetric when the shooter outranges the target:
-- a Bow (320) shooting a Spear (60) from 300 units away is not revealed to that
-- Spear, because the Spear is not fighting it -- it cannot reach it. Two reasons
-- for reading it this way rather than as "either one can hit the other":
--
--   * IT IS THE READING THE DOC'S OWN SHIELD ARGUMENT USES. Section 3a justifies
--     the front-slot shield surviving with "a unit cannot REACH the back
--     building while the front one still stands". That is a statement about the
--     attacker's reach, and it is the only thing that keeps the shield a
--     geometric fact rather than a property of which buildings happen to shoot.
--   * IT IS THE SAFE DIRECTION. Everywhere this model must choose it errs
--     toward showing LESS (the tail block names what is still outside it);
--     the alternative reading would be its one over-estimate, and would put
--     the enemy's whole damage model -- unit ranges, building dmgRange, trap
--     radii and every M3 range hook -- inside the fog module.
--
-- The consequence is a real one and it is escalated rather than smoothed: under
-- this reading you do not see what is shooting you if you cannot shoot back.
-- README open item 19.
--
-- WHAT CONTACT DOES NOT DO. It never lights a SECTION. `visibleSections` is
-- untouched by everything below, so `lit`, `seen` and section memory are exactly
-- what they were, and fighting a wall reveals the wall and not the ground it
-- stands on. That is the doc's word "entity-scoped" made structural rather than
-- promised.
--
-- BUILDINGS AS OBSERVERS ARE DELIBERATELY NOT MODELLED. The doc says "a UNIT
-- also reveals", and Sim.buildingAttacks means an Arrow Tower can be firing at
-- something no unit of mine is in contact with. Implementing the doc literally
-- keeps the under-estimate; README open item 19 asks for the ruling.
-- ---------------------------------------------------------------------------

-- Whether a unit can be in contact with a BUILDING at all is a ruleset fact, not
-- a fog one: Sim.buildCands only offers buildings as targets when
-- BUILD_BLOCKS_ADVANCE is set. With it clear, units walk past buildings and
-- never engage them, so there would be nothing to reveal.
M.CONTACT_HITS_BUILDINGS = (C.BUILD_BLOCKS_ADVANCE == 1) and 1 or 0

local UNIT_BOW = Rules.UNIT_BOW

-- The weapon envelope of ONE of the observer's own units, mirroring
-- Sim.unitRangeOf exactly: the ruleset's base range plus the lane's Fletcher
-- aura for Bows. M1 has no other range source (Sim.unitRangeOf takes no hook);
-- an M3 card that adds one has to be reflected here, which is why this reads
-- through sim.rules and sd.lanes rather than caching anything.
function M.unitReach(sim, side, u)
  local r = sim.rules.UNITS[u.t].range
  if u.t == UNIT_BOW then r = r + sim.sides[side].lanes[u.lane].aura.bowRange end
  return r
end

-- The observer's own units in one lane, as (position, reach) pairs plus the
-- envelope [lo, hi] they jointly cover. `out` is reused exactly as
-- visibleSections' is; one is allocated when you do not pass one.
--
-- The envelope is a FAST REJECT and nothing else: an entity outside it cannot be
-- in contact with anything, and an entity inside it still has to match a
-- particular unit. It is there because fillFoe tests every enemy unit in a lane
-- against every own unit in it, once a second, 1,440 matches at a time.
function M.contactSet(sim, side, lane, out)
  if out == nil then out = { n = 0, p = {}, r = {}, lo = 0, hi = -1 } end
  local us = sim.sides[side].lanes[lane].units
  local n, lo, hi = 0, 0, -1
  for i = 1, #us do
    local u = us[i]
    local reach = M.unitReach(sim, side, u)
    n = n + 1
    out.p[n] = u.pos
    out.r[n] = reach
    if n == 1 then
      lo = u.pos - reach; hi = u.pos + reach
    else
      if u.pos - reach < lo then lo = u.pos - reach end
      if u.pos + reach > hi then hi = u.pos + reach end
    end
  end
  out.n = n
  out.lo = lo
  out.hi = hi
  return out
end

-- Is anything in `cs` in contact with OBSERVER COORDINATE x? Pure.
function M.inContact(cs, x)
  if cs.n == 0 or x < cs.lo or x > cs.hi then return false end
  for i = 1, cs.n do
    local d = x - cs.p[i]
    if d < 0 then d = -d end
    if d <= cs.r[i] then return true end
  end
  return false
end

-- Module scratch for the contact set, on the same terms as SCRATCH above: it is
-- written before it is read inside one call and nothing reads it across calls,
-- so no table address and no iteration order can reach a result. It is a
-- SEPARATE table from SCRATCH because a caller walking one lane holds both at
-- once.
local CONTACT = { n = 0, p = {}, r = {}, lo = 0, hi = -1 }

-- ---------------------------------------------------------------------------
-- PER-ENTITY VISIBILITY
--
-- Every predicate takes the OBSERVER's side index and the shared sim state, and
-- every one of them takes an optional `vis` so a caller walking a whole lane
-- computes the section set once. They are pure reads: nothing here writes to
-- sim state, which is what makes it legal for both clients to evaluate all four
-- of these for BOTH sides and still compute the same match.
-- ---------------------------------------------------------------------------

-- An enemy unit. Doc sections 2 and 3: the plain section rule, with no shield.
-- A unit standing in section 7 beside an intact front building IS visible; only
-- the BACK BUILDING is shielded. Doc section 3a adds the second route: a unit
-- one of mine is fighting is visible wherever it stands. Doc section 6 adds the
-- third: while the observer's Shrine pulse is live, EVERY enemy unit in EVERY
-- lane is visible at full detail -- and Veil never enters this predicate,
-- because Veil conceals buildings only.
--
-- `cs` is this side's contact set for u's lane; one is built if it is omitted.
-- `pulse` is M.shrinePulseActive(sim, side), passed by a caller walking a whole
-- board so six slots are not re-scanned per unit; computed when omitted.
function M.seesEnemyUnit(sim, side, u, vis, cs, pulse)
  if pulse == nil then pulse = M.shrinePulseActive(sim, side) end
  if pulse then return true end
  if vis == nil then vis = M.visibleSections(sim, side, u.lane, SCRATCH) end
  if vis[M.sectionOfEnemy(u.pos)] == 1 then return true end
  if cs == nil then cs = M.contactSet(sim, side, u.lane, CONTACT) end
  return M.inContact(cs, C.LANE_LEN - u.pos)
end

-- Is observer section `section` of `lane` lit by one of the observer's own
-- UNITS -- as opposed to by a vision-granting building? The two light the same
-- bitmap in visibleSections because for everything EXCEPT a veiled building
-- they are the same thing; Veil is the one rule that tells them apart (a body
-- in the section beats Veil, remote tower light does not), so the distinction
-- is derived here on demand rather than carried in every section set.
function M.unitLitSection(sim, side, lane, section)
  local us = sim.sides[side].lanes[lane].units
  for i = 1, #us do
    if M.sectionOfOwn(us[i].pos) == section then return true end
  end
  return false
end

-- The section route AS IT APPLIES TO BUILDINGS: a lit section shows the
-- buildings standing in it unless the buildings' owner holds Veil, in which
-- case only a section lit by a BODY does (the precedence rule at veiled()).
-- Sections 7 and 8 are only ever unit-lit (the Watchtower grants 5 and 6), so
-- for them this degrades to the plain bitmap test at the cost of one loop.
local function sectionShowsBuilding(sim, side, lane, section, vis)
  if vis[section] ~= 1 then return false end
  if not M.veiled(sim, 3 - side) then return true end
  return M.unitLitSection(sim, side, lane, section)
end

-- Is one of the observer's units in contact with the building standing in enemy
-- slot `slot`?
--
-- FALSE FOR AN EMPTY SLOT. There is nothing there to fight, so an empty slot is
-- learned about only through the section rule -- which is what keeps doc
-- section 5's "an empty enemy slot is indistinguishable from an unseen one" true
-- under the new rule as well.
--
-- AND FALSE FOR A SHIELDED BACK SLOT, WHICH IS A RULING BETWEEN TWO SENTENCES OF
-- THE DOC AND IS THE ONE JUDGEMENT CALL IN THIS BLOCK.
--
--   * Section 3a says contact is entity-scoped and asserts, as a fact about the
--     geometry, that the shield is untouched because "a unit cannot reach the
--     back building while the front one still stands".
--   * Section 5 says the shield holds "EVEN FROM A UNIT STANDING RIGHT NEXT TO
--     IT", which is a statement about a unit AT contact distance.
--
-- The geometry claim is true for every board reachable by walking in --
-- BUILD_BLOCKS_ADVANCE halts an attacker at the FRONT building, 400 units short
-- of the back one, and the CHECKS block asserts that for every body in C.3. It
-- is NOT true on one board: a unit already standing beyond their front slot when
-- they REBUILD it is within 60 of the back building with the front one intact.
-- On that board the two sentences disagree, and section 5's is the explicit one
-- -- it describes exactly this distance -- so the shield wins and this returns
-- false. The cost is that on that one board a unit is hitting something it
-- cannot see, which is the absurdity 3a exists to remove; it is pinned by a test
-- and escalated as README open item 19 rather than left to be discovered.
function M.inContactWithBuilding(sim, side, slot, cs)
  if M.CONTACT_HITS_BUILDINGS == 0 then return false end
  local es = sim.sides[3 - side]
  if not es.slots[slot] then return false end
  local lane = M.laneOfSlot(slot)
  if not isFrontSlot(slot) and es.slots[frontSlotOf(lane)] then return false end
  if cs == nil then cs = M.contactSet(sim, side, lane, CONTACT) end
  return M.inContact(cs, isFrontSlot(slot) and M.OBS_ENEMY_FRONT or M.OBS_ENEMY_BACK)
end

-- An enemy building, by the enemy's own slot index. Doc sections 5 and 3a.
--
-- The shield tests the LIVE front slot, not the remembered one, and that is the
-- point: a building blocks line of sight because it is standing there, not
-- because you believe it is. Under-construction counts as standing (Rules
-- INTERPRETATIONS 4: it occupies the slot and blocks).
--
-- THE SHIELD SURVIVES SECTION 3a TWICE OVER, WHICH IS DELIBERATE. First as
-- geometry: BUILD_BLOCKS_ADVANCE halts an attacker at the FRONT building, 400
-- units short of the back one, so on every board reachable by walking in, no
-- body in C.3 has an envelope that reaches the back slot -- the CHECKS block
-- asserts it and tools/fogtest.lua sweeps every unit type over every reachable
-- position rather than taking either one's word for it. Second as a rule:
-- inContactWithBuilding refuses the back slot outright while the front slot is
-- occupied, because doc section 5 says the shield holds "even from a unit
-- standing right next to it" and one board (an infiltrator caught behind a
-- rebuilt wall) can produce exactly that unit. The second is what makes the
-- claim unconditional instead of a property of the current slot positions.
--
-- SINCE M3 PART 2 this is the FULL-FIDELITY predicate -- slot, identity AND
-- HP grade sight, the kind that overwrites memory -- and it is veil-aware:
-- a veiled enemy's buildings show only to a body in the section or to contact
-- (the precedence rule at veiled()). Divination and the Shrine pulse are NOT
-- routes into this predicate on purpose: they disclose strictly less than it
-- does (identity without HP; occupancy without either) and surface through
-- their own layers in observe() and believedBuilding() instead. A predicate
-- that answered "true" for a scried building would hand its callers HP the
-- scry never showed.
function M.seesEnemyBuilding(sim, side, slot, vis, cs)
  local lane = M.laneOfSlot(slot)
  if vis == nil then vis = M.visibleSections(sim, side, lane, SCRATCH) end
  if isFrontSlot(slot) then
    if sectionShowsBuilding(sim, side, lane, M.SEC_ENEMY_FRONT, vis) then return true end
    return M.inContactWithBuilding(sim, side, slot, cs)
  end
  if sectionShowsBuilding(sim, side, lane, M.SEC_ENEMY_BACK, vis) then
    local es = sim.sides[3 - side]
    if not es.slots[frontSlotOf(lane)] then return true end
  end
  return M.inContactWithBuilding(sim, side, slot, cs)
end

-- The enemy keep. Doc section 4: its POSITION is always known, its HP is
-- remembered from last sight. One keep serves all three lanes, so seeing the
-- last section of ANY lane is seeing it -- and, under 3a, so is having a unit
-- in any lane with its weapon on it. That second route is not cosmetic: a Bow
-- razing the keep stands at 2000 - 320 = 1680, which is section 7, so under the
-- section rule alone the unit killing the keep could not watch it fall.
function M.seesEnemyKeep(sim, side)
  for lane = 1, C.LANES do
    local vis = M.visibleSections(sim, side, lane, SCRATCH)
    if vis[M.SEC_ENEMY_KEEP] == 1 then return true end
    local cs = M.contactSet(sim, side, lane, CONTACT)
    if M.inContact(cs, M.OBS_ENEMY_KEEP) then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- MEMORY
--
-- WHERE IT LIVES, AND WHY IT IS NOT IN THE SIM AND NOT IN THE STATE HASH.
--
-- Memory is a per-side store owned by the CONSUMER -- the renderer in M7, the
-- match driver in M2 -- created by newMemory() and advanced by observe(). It is
-- not a field of sim state, it is not inside Hash.state, and sim/ cannot reach
-- it. Three separate arguments, and each one alone would be sufficient:
--
--   1 IT IS DERIVED, AND HASHING A DERIVED VALUE HIDES ITS STALENESS. memory(t)
--     is a fold of observe() over the hashed state trajectory, the side index
--     and the declared cadence below. The README's own checklist already
--     settles this class: "a field that is DERIVED from other state ... leave it
--     out of the hash and re-derive it ... hashing a value you can recompute
--     HIDES a stale cache, because both clients compute the same wrong number
--     and agree." Memory is exactly that, one level up.
--   2 A DISAGREEMENT IN IT IS NOT A FORKED MATCH. The sim never reads memory --
--     A.5 grep 1 makes that structural, not a promise -- so two clients whose
--     memories differ are still playing one match, with one of them drawing it
--     wrong. Putting it in Hash.state would make tools/ci.sh, whose entire
--     meaning is "the two clients are simulating the same match", go RED for a
--     RENDER bug. That is precisely the M1/M2 conflation tools/m2.sh's header
--     exists to refuse.
--   3 IT WOULD BE A COMPATIBILITY BREAK FOR NOTHING. Hash.state feeds the
--     heartbeat and the committed goldens. Adding a render-layer fold to it
--     invalidates every recorded match log to buy a check on something that
--     cannot affect a match.
--
-- SO HOW IS IT CHECKED? By memHash() below, which is a digest of a memory store
-- on demand. tools/fogtest.lua replays the same match twice and asserts the two
-- memories are bit-identical, and asserts the same for the memory computed from
-- the OTHER seat. That is the property that matters -- both clients can compute
-- both sides' memories and agree -- and it is proved without putting a single
-- render field inside the number the heartbeat carries.
--
-- THE CADENCE IS DECLARED, NOT INFERRED. OBSERVE_EVERY is 1: memory is folded
-- once per sim tick. The doc freezes a section "on the tick it left visibility",
-- which is a per-tick statement, and unit positions move every tick (phaseMove
-- runs every tick, not only on the resolve grid), so any coarser cadence would
-- silently drop sections a fast unit walked through and would make "how coarse
-- is your memory" an unstated free parameter of the model. This roster has been
-- burned by an unstated free parameter once already (Finding 7); it does not get
-- a second one.
--
-- THE ORDER WITHIN A TICK is also declared: observe() reads the state AFTER
-- sim:tick() has returned, and the consumer additionally observes once before
-- the first tick. Consumers must not vary it -- two clients folding at different
-- points of the tick would disagree about a section that opened and closed
-- inside one tick.
--
-- WHAT IS REMEMBERED, AND WHAT IS DELIBERATELY NOT:
--
--   enemy buildings   slot, identity, HP, maxHp and the done flag, frozen at
--                     last sight; an EMPTY slot is remembered as empty, which
--                     is why a building constructed while unobserved does not
--                     appear at all.
--   enemy keep HP     frozen at last sight.
--   sections          the tick each section was last seen, per lane. The
--                     renderer needs it to know which ground has been explored,
--                     and it is what makes "a scout to their keep leaves memory
--                     of four sections" a testable claim.
--   enemy UNITS       NOT REMEMBERED, doc section 4. There is no unit field in
--                     this store and there is no accessor that returns one. A
--                     ghosted stack invites a decision against an army that
--                     moved two minutes ago, which is worse than no information.
--                     The same rule covers the two M3 sources ABOUT units: what
--                     a Shrine pulse showed of an army is gone when the pulse
--                     ends, and no Omen signal outlives its pending order --
--                     a stale wave warning is a ghosted stack wearing a bell.
--
-- SINCE M3 PART 2 THE STORE IS THREE PARALLEL LAYERS, because the two card
-- sources see LESS than a body does and memory must never promote a partial
-- sight into a full record -- a scry that recorded an HP it cannot see would
-- be fabricating evidence, which is worse than fog:
--
--   FULL layer  (slotB/slotHp/slotMaxHp/slotDone/slotSeen/slotTick)
--               written ONLY by full-fidelity sight -- the section rule and
--               contact -- through recordSlot, exactly as before part 2.
--   SCRY layer  (slotScryB/slotScryTick)
--               Divination. Stamped EVERY observation while the observer holds
--               the card: the identity of the completed building there, or 0
--               for empty, for scaffolding and for a veiled enemy (the empty
--               scry). Continuous, so its freeze never shows while the card is
--               held -- the layer exists so the composition below has one
--               shape, not because a scry can be lost mid-match.
--   OCC layer   (slotOcc/slotOccTick)
--               the Shrine pulse. Stamped on pulse ticks only: 1 if anything
--               stands in the slot -- complete or scaffolding, occupancy is a
--               fact about the SLOT (Rules INTERPRETATIONS 4: an
--               under-construction building occupies it) -- and 0 for an empty
--               or veiled one, frozen until the next pulse.
--
-- WHAT ONE LAYER'S WRITE MAY NEVER DO IS TOUCH ANOTHER: a pulse that showed a
-- slot occupied says NOTHING about which building stands there now, so the
-- frozen full record keeps its palisade; a pulse that showed it empty does not
-- delete that record either -- it is a fresher, coarser observation, and WHICH
-- of the two a consumer believes is the composition rule in
-- believedBuilding(), written once, where the renderer and the policy view
-- must share it.
--
-- THE INITIAL STATE IS THE TICK-0 BOARD, and that is not a shortcut: at tick 0
-- both sides have six empty slots and a keep at C.KEEP_HP, and the ruleset that
-- says so is shared and handshaked (rulesHash). So "never observed" and
-- "observed at tick 0" carry the same content here, which is also why doc
-- section 5's "an empty slot is indistinguishable from an unseen one" holds by
-- construction rather than by the renderer remembering to blur it.
-- ---------------------------------------------------------------------------

M.OBSERVE_EVERY = 1

M.NEVER_SEEN = -1

function M.newMemory(rules)
  local R = M.checkRuleset(rules)
  local RC = R.C
  local mem = {
    tick = 0,
    observations = 0,
    keepHp = RC.KEEP_HP,
    keepSeen = 0,
    keepTick = M.NEVER_SEEN,
    slotB = {},
    slotHp = {},
    slotMaxHp = {},
    slotDone = {},
    slotSeen = {},
    slotTick = {},
    secSeen = {},
    secTick = {},
  }
  mem.slotScryB = {}
  mem.slotScryTick = {}
  mem.slotOcc = {}
  mem.slotOccTick = {}
  for s = 1, RC.SLOTS do
    mem.slotB[s] = 0
    mem.slotHp[s] = 0
    mem.slotMaxHp[s] = 0
    mem.slotDone[s] = 0
    mem.slotSeen[s] = 0
    mem.slotTick[s] = M.NEVER_SEEN
    mem.slotScryB[s] = 0
    mem.slotScryTick[s] = M.NEVER_SEEN
    mem.slotOcc[s] = 0
    mem.slotOccTick[s] = M.NEVER_SEEN
  end
  for lane = 1, RC.LANES do
    local a, b = {}, {}
    for s = 1, M.SECTIONS do
      a[s] = 0
      b[s] = M.NEVER_SEEN
    end
    mem.secSeen[lane] = a
    mem.secTick[lane] = b
  end
  return mem
end

-- Overwrite one slot's record from the truth. Called ONLY when that slot is
-- visible this observation, which is the whole of "frozen until seen again":
-- there is no other write path into the record.
local function recordSlot(mem, es, slot, t)
  local b = es.slots[slot]
  if b then
    mem.slotB[slot] = b.b
    mem.slotHp[slot] = b.hp
    mem.slotMaxHp[slot] = b.maxHp
    mem.slotDone[slot] = b.done
  else
    mem.slotB[slot] = 0
    mem.slotHp[slot] = 0
    mem.slotMaxHp[slot] = 0
    mem.slotDone[slot] = 0
  end
  mem.slotSeen[slot] = 1
  mem.slotTick[slot] = t
end

-- Fold one observation of `side`'s view of the shared state into `mem`.
-- Idempotent for a given state: calling it twice on the same sim changes only
-- the observation counter.
function M.observe(mem, sim, side)
  local RC = sim.rules.C
  local es = sim.sides[3 - side]
  local t = sim.clock

  for lane = 1, RC.LANES do
    local vis = M.visibleSections(sim, side, lane, SCRATCH)
    -- SECTION memory is folded from the SECTION rule alone. Contact is
    -- entity-scoped (doc 3a), so grinding a wall must not mark the ground it
    -- stands on as explored -- if it did, `seen` would start measuring combat
    -- and the audit's exploration column would quietly change meaning.
    local seen, stick = mem.secSeen[lane], mem.secTick[lane]
    for s = 1, M.SECTIONS do
      if vis[s] == 1 then
        seen[s] = 1
        stick[s] = t
      end
    end

    local cs = M.contactSet(sim, side, lane, CONTACT)
    local fs = frontSlotOf(lane)
    -- Their front slot: the section rule, or a unit of mine with its weapon on
    -- the building in it. The second route is what closes README open item 13 --
    -- an attacker stopped at 1240 by the wall it is destroying now records that
    -- wall, at the HP it can see, on the tick it is hitting it. Since M3
    -- part 2 the section half is veil-aware (sectionShowsBuilding): remote
    -- tower light does not put a veiled wall into the FULL record, a body in
    -- the section still does, and in a cardless match the predicate is
    -- exactly the old bitmap test.
    if sectionShowsBuilding(sim, side, lane, M.SEC_ENEMY_FRONT, vis)
      or M.inContactWithBuilding(sim, side, fs, cs) then
      recordSlot(mem, es, fs, t)
    end
    -- Doc section 5: section 7 AND their front slot empty or destroyed. Doc 3a
    -- adds the entity-scoped route -- a Bow razing a back building from
    -- section 6 records it -- and inContactWithBuilding carries section 5's
    -- shield inside itself, so it is written once and cannot drift from the
    -- predicate the renderer will call. (Section 7 is only ever unit-lit --
    -- the Watchtower grants 5 and 6 -- so the veil-aware form changes nothing
    -- here today; it is used anyway so the rule is written once, and so a
    -- future building that lights section 7 remotely cannot quietly pierce
    -- Veil through this one call site.)
    if (sectionShowsBuilding(sim, side, lane, M.SEC_ENEMY_BACK, vis) and not es.slots[fs])
      or M.inContactWithBuilding(sim, side, fs + 1, cs) then
      recordSlot(mem, es, fs + 1, t)
    end
    if vis[M.SEC_ENEMY_KEEP] == 1 or M.inContact(cs, M.OBS_ENEMY_KEEP) then
      mem.keepHp = es.keepHp
      mem.keepSeen = 1
      mem.keepTick = t
    end
  end

  -- THE SCRY LAYER (Divination). Continuous: stamped at every observation the
  -- observer holds the card, all six slots, ignoring sections and the shield.
  -- The value is the completed building's identity, or 0 -- and 0 is a REAL
  -- observation ("nothing completed stands there"), not a missing one, which
  -- is why the tick advances for it too: it is how a diviner learns a razed
  -- wall is gone.
  --
  -- AGAINST VEIL THE LAYER IS NOT STAMPED AT ALL, and the difference between
  -- "recorded empty" and "recorded nothing" is the whole card. Veil
  -- SUPPRESSES a route; it does not manufacture observations. A veiled scry
  -- that WROTE zeros would out-vote knowledge the observer earned through the
  -- routes Veil cannot beat -- a wall recorded by a body standing at it would
  -- vanish from the screen because a lying scry "refreshed" it -- and that is
  -- deception beyond what the card promises. Left unstamped, a diviner facing
  -- Veil sees exactly what the doc says: an empty scry everywhere, stale
  -- body-earned knowledge intact, and the one clue Q9b sanctions -- a wall you
  -- have TOUCHED that the scry refuses to show is how you learn "I am against
  -- Veil". Inference, not sight.
  if M.hasCard(sim, side, M.CARD_DIVINATION) and not M.veiled(sim, 3 - side) then
    for s = 1, RC.SLOTS do
      local b = es.slots[s]
      mem.slotScryB[s] = (b and b.done == 1) and b.b or 0
      mem.slotScryTick[s] = t
    end
  end

  -- THE OCC LAYER (the Shrine pulse). Pulse ticks only: 1 when anything
  -- stands in the slot -- occupancy is a fact about the SLOT, and scaffolding
  -- occupies it (Rules INTERPRETATIONS 4) -- 0 for an empty one. It never
  -- touches the FULL record in either direction: what the scan saw is
  -- occupancy, and occupancy is what it remembers. Against Veil it is not
  -- stamped, on exactly the scry layer's argument: the scan comes back with
  -- nothing, not with a fabricated "empty" that would erase body-earned
  -- knowledge.
  if M.shrinePulseActive(sim, side) and not M.veiled(sim, 3 - side) then
    for s = 1, RC.SLOTS do
      mem.slotOcc[s] = es.slots[s] and 1 or 0
      mem.slotOccTick[s] = t
    end
  end

  mem.tick = t
  mem.observations = mem.observations + 1
  return mem
end

-- What the observer believes is in an enemy slot. Returns identity (0 = empty),
-- HP, maxHp, done and the tick it was last seen (NEVER_SEEN if never).
--
-- `lastSeen` is returned because the RENDERER needs it to decide nothing at all
-- -- doc section 4 is explicit that staleness is NOT shown -- but a TEST needs
-- it, and so does a future replay tool. Surfacing it in the UI is a design
-- change, not an implementation detail.
function M.rememberedBuilding(mem, slot)
  return mem.slotB[slot], mem.slotHp[slot], mem.slotMaxHp[slot],
         mem.slotDone[slot], mem.slotTick[slot]
end

function M.rememberedKeepHp(mem)
  return mem.keepHp, mem.keepTick
end

-- WHAT THE OBSERVER BELIEVES IS IN AN ENEMY SLOT, all three layers composed.
-- This is the one place the composition rule is written; the policy view reads
-- it and M7's renderer must read it too, because two compositions of the same
-- three layers would be two different screens.
--
-- Returns (b, hp, maxHp, done, occ, tick):
--   b     the identity drawn there, 0 when none is known
--   hp    the HP figure the drawing carries, 0 when NO HP is known -- which is
--         unambiguous, because a standing building's live hp is always >= 1
--   occ   1 when the slot is believed OCCUPIED. This is the field that says
--         more than b: a pulse-scanned slot can be known occupied with no
--         identity at all (occ 1, b 0), which no single field could express
--   tick  when the belief was formed (NEVER_SEEN for the tick-0 default)
--
-- THE RULE: THE FRESHEST LAYER WINS; a tie goes to the layer that knows MORE
-- (full > scry > occ) -- with the one exception that an EMPTY scry never beats
-- a same-tick occupancy scan, because "nothing completed stands there" does
-- not contradict "something stands there": scaffolding satisfies both, and
-- the scan is the one that saw it. Spelled out:
--
--   1 full record at tF >= everything else -> the full record, frozen.
--   2 else a scry that SHOWS a building (tS >= tO) -> that identity, done by
--     definition, occupied -- and the HP shown is the FROZEN full-record HP
--     when the record's identity matches the scry's (the screen keeps its
--     stale HP bar under a live identity), 0 when it does not (the building
--     the record knew is gone; its HP died with it).
--   3 else the occupancy scan (tO >= tS) -> occupied: the frozen full record
--     supplies whatever identity and HP it holds (a scan ping under a
--     remembered palisade draws the palisade); empty: an empty slot, however
--     confidently a stale record disagrees.
--   4 else (a fresher EMPTY scry) -> empty. This is the under-estimate: a
--     diviner whose scry shows nothing draws nothing, even over an older
--     occupancy ping -- the razed-vs-scaffolding ambiguity is exactly the
--     "is that wall up yet?" tension Divination is documented to preserve.
--
-- Veil never appears here because it already happened: a veiled enemy's scry
-- and scan layers are never stamped at all (observe()'s two folds say why
-- suppression must be absence rather than a recorded zero), so this function
-- composes only observations that were genuinely made -- and a diviner facing
-- Veil keeps the wall a body of theirs once touched, which is the sanctioned
-- inference route.
function M.believedBuilding(mem, slot)
  local tF = mem.slotTick[slot]
  local tS = mem.slotScryTick[slot]
  local tO = mem.slotOccTick[slot]
  if tF >= tS and tF >= tO then
    local b = mem.slotB[slot]
    return b, mem.slotHp[slot], mem.slotMaxHp[slot], mem.slotDone[slot],
           (b > 0) and 1 or 0, tF
  end
  local scryB = mem.slotScryB[slot]
  if scryB > 0 and tS >= tO then
    if mem.slotB[slot] == scryB then
      return scryB, mem.slotHp[slot], mem.slotMaxHp[slot], 1, 1, tS
    end
    return scryB, 0, 0, 1, 1, tS
  end
  if tO >= tS then
    if mem.slotOcc[slot] == 0 then return 0, 0, 0, 0, 0, tO end
    local b = mem.slotB[slot]
    if b > 0 then
      return b, mem.slotHp[slot], mem.slotMaxHp[slot], mem.slotDone[slot], 1, tO
    end
    return 0, 0, 0, 0, 1, tO
  end
  return 0, 0, 0, 0, 0, tS
end

function M.sectionSeen(mem, lane, section)
  return mem.secSeen[lane][section] == 1
end

-- Doc section 7, expressed as a value so there is ONE place the rule is
-- written and a test can assert against it. There is deliberately no predicate
-- here: a function implies a case in which the answer is yes.
M.ECONOMY_EVER_VISIBLE = 0
M.NEVER_RENDERED = { "bank", "earned", "spent", "wasted", "levyFlat", "loadout" }

-- 31-bit digest of a memory store, for the determinism tests. Not part of
-- Hash.state and deliberately not reachable from it; see the MEMORY block.
function M.memHash(mem)
  local h = Hash.new()
  h = Hash.int(h, mem.observations)
  h = Hash.int(h, mem.tick)
  h = Hash.int(h, mem.keepHp)
  h = Hash.int(h, mem.keepSeen)
  h = Hash.int(h, mem.keepTick)
  local n = #mem.slotB
  h = Hash.int(h, n)
  for s = 1, n do
    h = Hash.int(h, mem.slotB[s])
    h = Hash.int(h, mem.slotHp[s])
    h = Hash.int(h, mem.slotMaxHp[s])
    h = Hash.int(h, mem.slotDone[s])
    h = Hash.int(h, mem.slotSeen[s])
    h = Hash.int(h, mem.slotTick[s])
    h = Hash.int(h, mem.slotScryB[s])
    h = Hash.int(h, mem.slotScryTick[s])
    h = Hash.int(h, mem.slotOcc[s])
    h = Hash.int(h, mem.slotOccTick[s])
  end
  local nl = #mem.secSeen
  h = Hash.int(h, nl)
  for lane = 1, nl do
    local seen, stick = mem.secSeen[lane], mem.secTick[lane]
    for s = 1, M.SECTIONS do
      h = Hash.int(h, seen[s])
      h = Hash.int(h, stick[s])
    end
  end
  return h
end

-- ---------------------------------------------------------------------------
-- WHAT IS STILL NOT MODELLED, NAMED SO THE GAP IS READABLE
--
-- The four M3 information effects are LIVE (the INFO EFFECTS block above
-- closed fog open item 16), so the "strict under-estimate in four named
-- places" caveat this block used to carry is retired. What remains outside the
-- model, each deliberately and each escalated in the README rather than
-- stubbed:
--
--   self-announcement    Q9b's marks ("you are being scried", "you were
--                        scanned") are PRESENTATION and land in M7. The FACT
--                        each mark discloses is marks() above, so the renderer
--                        will not have to reach into an enemy loadout that doc
--                        section 7 forbids rendering; the pixels are not this
--                        module's business.
--   Watchfires' reveal   Q9b's table gives the Watchfires card a reveal half
--                        ("reveal their lane out to that range") and the fog
--                        doc's section 6 -- later, binding, and claiming to
--                        restate Q9b "so the two cannot drift" -- has no such
--                        row. The card's RANGE half is sim-side and landed in
--                        part 1; the reveal half is implemented as the binding
--                        doc writes it, which is not at all. README open
--                        item 26.
--   pulse vs sections    the pulse reveals units and occupancy and never
--                        lights a section or marks ground explored -- the only
--                        reading on which "occupancy only" survives its own
--                        sentence. README open item 27 asks the doc to
--                        confirm it.
--   buildings as         doc 3a says "a UNIT also reveals", so an Arrow Tower
--   observers            firing at something reveals nothing. Open item 19c.
-- ---------------------------------------------------------------------------

return M
