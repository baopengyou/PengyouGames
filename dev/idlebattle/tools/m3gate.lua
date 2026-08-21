-- tools/m3gate.lua -- the M3 milestone, Part E verbatim, as one runnable tool.
--
--   "for each of the 40 cards individually, and for 200 randomly drawn 5-card
--    loadouts on both sides, M1's bit-identical-hash test still passes over
--    6,000 ticks. Plus a clamp-saturation report: every channel's summed value
--    across all 200 loadouts, confirming no channel is ever driven outside its
--    Q4 clamp and identifying which cards saturate together (D.2)."
--
-- THREE MODES, run in order by tools/m3.sh (the front door and the verdict):
--
--   cards      each of the 40 cards INDIVIDUALLY, in TWO pairings, both at the
--              full 6,000 ticks on fixed seeds:
--                * CARD-VS-EMPTY -- the minimal delta from the proven M1 game.
--                  A desync here implicates exactly one card, and the loadout
--                  is ASYMMETRIC, which is where a side-biased install would
--                  hide (Discord writes into the OTHER side's channel; only
--                  one side registers hooks). The A.2 mirror is run on this
--                  log for exactly that reason: the same match with the seats
--                  swapped must come out exactly mirrored.
--                * CARD-MIRROR -- the same card on BOTH sides. Two live copies
--                  of one mechanism: S5 arbitration with itself, Discord
--                  crossing both ways at once, the wheel edge at its exact
--                  mirror zero, every hook registered twice. The class of bug
--                  where two copies interfere cannot occur in any vs-empty run.
--              Each pairing is played through M1's four arrival patterns --
--              straight, replay, REORDERED queueing (a seeded permutation of
--              the same atoms), and MID-RUN ARRIVAL (each atom queued at its
--              own arrive tick, which is what the wire does) -- and every epoch
--              hash, terminal hash, logDigest and accept tally must agree.
--              runner.invariants then audits the unhashed derived state.
--              The three VERB cards (Investment, Scorched Earth, Ley Line) get
--              seeded verb atoms INJECTED into their logs -- the generator
--              deliberately issues none, and a verb card whose verb never
--              fires would make its two runs vacuously identical. Injection
--              includes a verb from the side that does NOT own the card, which
--              must fizzle identically on both clients.
--   loadouts   N (default 200 -- the milestone number) random legal 5-card
--              loadouts drawn for BOTH sides from a fixed seed schedule, full
--              length, the same four arrival patterns, zero mismatches
--              required. Verb atoms are injected wherever either side's draw
--              holds a verb card, on the same rule as above.
--   clamp      the saturation report over the SAME 200 drawn pairs (the seed
--              schedule is shared, so the report describes the population the
--              gate measured): per channel, the per-side summed potential --
--              the STATIC sum measured off the installed sim's own sd.chan
--              (Discord's cross-write included) plus the MAXIMUM the loadout's
--              conditional and time-varying cards can add, derived from the
--              hashed card table -- against the Q4 clamp, with every
--              saturating combination named and counted. Saturation is LEGAL
--              (D.2 calls it the structural replacement for the old headcount
--              cap); the census shows WHERE, so the loadout UI's "channel
--              saturated" warning (D.2) has a measured population to be
--              designed against. That the sim APPLIES the clamp is proved by
--              this step's APPLIED-VALUE PROBE: every drawn side that
--              saturates unitCost -- the channel D.2 calls the important one
--              -- deploys a real Spear on a fresh sim of its own pair, at
--              tick 25 and again past Late Levy's gate, and the cost the sim
--              charged (sd.spent, fed by Sim.unitCostOf through clampCh) must
--              equal this tool's own independently clamped arithmetic. An
--              earlier revision instead clamped a number HERE and tested it
--              against the same bounds, which could not fail; the exact
--              per-channel clamp arithmetic is pinned by selftest section 13,
--              and this step's content is the census, the probe, and the D.2
--              cross-check.
--
-- WHAT THIS GATE DOES NOT COVER, said here rather than discovered:
--   * the four information cards' PERCEPTION effects are render/policy-side
--     (fog/Fog.lua) and are proved by tools/fogtest.lua sections 16-22 inside
--     the M1 gate; here those cards are the field-inert passengers the
--     selftest already proves them to be.
--   * balance. Whether 40 cards produce a fair game is M2's kind of question
--     and open item 24's roster ruling; this gate is correctness only.
--   * D.3 conformance. A green run proves the cards compute IDENTICALLY on
--     both clients, not that they compute what D.3 says -- a card wrong the
--     same way on both machines agrees with itself in every hash here. That
--     the numbers are the document's numbers is harness/selftest.lua's job.
--
-- A SUITE HASH is folded over every run (terminal hash, terminal tick,
-- logDigest, accept tally) and printed at the end of the cards and loadouts
-- modes. Two interpreters that print the same suite hash agreed on every
-- number in every match; tools/m3.sh compares the runs mechanically.
--
--   usage: lua tools/m3gate.lua cards
--          lua tools/m3gate.lua loadouts [n]
--          lua tools/m3gate.lua clamp    [n]
--   exit:  0 = pass, 1 = at least one failure
--
-- THIS FILE IS A TOOL: pairs/io/os are fine EXCEPT anywhere a hashed or
-- printed-and-compared number is produced -- the suite hash and the report
-- lines are built from sorted, integer-only walks so both interpreters and
-- any two machines print byte-identical text.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local SimM = require("sim.Sim")
local Hash = require("sim.Hash")
local Rand = require("sim.Rand")
local gen = require("harness.gen")
local runner = require("harness.runner")
local logfmt = require("harness.logfmt")

local C = Rules.C
local floor = math.floor
local format = string.format

local MODE = arg and arg[1] or "cards"
local NLOADOUTS = tonumber(arg and arg[2]) or 200

-- The frozen seed schedule. Everything below derives from these three bases
-- and nothing else, so the cards run, the loadouts run and the clamp report
-- all describe one reproducible population.
local SEED_CARD_EMPTY = 910000
local SEED_CARD_MIRROR = 920000
local SEED_LOADOUT = 930000

local EPOCH = C.SNAPSHOT_EPOCH

local fails = 0
local function bad(fmt, ...)
  fails = fails + 1
  print(format("FAIL " .. fmt, ...))
end

-- ---------------------------------------------------------------------------
-- the frozen loadout draw (shared by `loadouts` and `clamp`)
-- ---------------------------------------------------------------------------

-- Five DISTINCT ids 1..40 (Q6: combinations without repetition), drawn from
-- the tool's own Rand stream -- the same generator the sim uses, so the draw
-- is identical under every interpreter.
local function drawLoadout(r, out)
  local n = 0
  while n < 5 do
    local id = Rand.range(r, 1, #Rules.CARDS)
    local dup = false
    for i = 1, n do
      if out[i] == id then dup = true end
    end
    if not dup then
      n = n + 1
      out[n] = id
    end
  end
  return out
end

local function loadoutSeed(i) return SEED_LOADOUT + i * 29 end

local function drawPair(i)
  local r = Rand.new(loadoutSeed(i))
  local a = drawLoadout(r, {})
  local b = drawLoadout(r, {})
  return a, b
end

local function loadoutStr(lo)
  local t = {}
  for i = 1, 5 do t[i] = Rules.CARDS[lo[i]].key end
  return table.concat(t, "+")
end

-- ---------------------------------------------------------------------------
-- verb injection
-- ---------------------------------------------------------------------------

local VERB_CARDS = {
  { key = "investment", kind = "I" },
  { key = "scorchedEarth", kind = "E" },
  { key = "leyLine", kind = "L" },
}

local function ownsCard(lo, id)
  for i = 1, 5 do
    if lo[i] == id then return true end
  end
  return false
end

-- Which verb kinds does either side's loadout make live? Returns nil when
-- none: an uncarded log is left exactly as generated, genHash check included.
local function liveVerbs(loA, loB)
  local out = nil
  for v = 1, #VERB_CARDS do
    local id = Rules.CARD_BY_KEY[VERB_CARDS[v].key]
    local a, b = ownsCard(loA, id), ownsCard(loB, id)
    if a or b then
      out = out or {}
      out[#out + 1] = { kind = VERB_CARDS[v].kind, sideA = a, sideB = b }
    end
  end
  return out
end

-- Inject seeded verb atoms: for each live verb, four from each OWNING side
-- (execute-or-fizzle inside the card's own rules: cooldowns, one-outstanding,
-- empty lanes) and ONE from a non-owning side, which must fizzle as a no-card
-- verb exactly as every side did in M1. Executed-at-exec (A.4), so nothing
-- here needs to know whether an atom will be legal. The log is re-trimmed to
-- its new true end afterwards, which restores gen.trim's invariant (every
-- surviving atom has arrive <= exec < endTick) that the four arrival modes
-- rely on to see the identical atom set; genHash is dropped because the
-- generator's own run did not contain these atoms.
local function injectVerbs(log, verbs, seed)
  local r = Rand.new(seed + 555)
  local maxSeq = { 0, 0 }
  for i = 1, #log.cmds do
    local cmd = log.cmds[i]
    if cmd.seq > maxSeq[cmd.side] then maxSeq[cmd.side] = cmd.seq end
  end
  local hi = log.endTick and (log.endTick - 1) or (log.ticks - 1)
  if hi > log.ticks - 1 then hi = log.ticks - 1 end
  if hi < C.ORDER_DELAY + 2 then return log end
  local function throw(side, kind)
    local exec = Rand.range(r, C.ORDER_DELAY + 1, hi)
    local arrive = exec - C.ORDER_DELAY
    if arrive < 0 then arrive = 0 end
    maxSeq[side] = maxSeq[side] + 1
    logfmt.add(log, exec, side, maxSeq[side], kind,
      Rand.range(r, 1, C.LANES), Rand.range(r, 1, 4), arrive)
  end
  for v = 1, #verbs do
    local w = verbs[v]
    if w.sideA then for _ = 1, 4 do throw(1, w.kind) end end
    if w.sideB then for _ = 1, 4 do throw(2, w.kind) end end
    if not (w.sideA and w.sideB) then
      throw(w.sideA and 2 or 1, w.kind)   -- the no-card fizzle, other seat
    end
  end
  log.genHash = nil
  log.genTick = nil
  return gen.trimToMatch(log)
end

-- ---------------------------------------------------------------------------
-- one log through the four arrival patterns (+ optional A.2 mirror)
-- ---------------------------------------------------------------------------

local suite = Hash.new()
local runs = 0

local function fold(trace)
  suite = Hash.int(suite, trace.terminal)
  suite = Hash.int(suite, trace.terminalTick)
  suite = Hash.int(suite, trace.logDigest)
  suite = Hash.int(suite, trace.accepted)
  suite = Hash.int(suite, trace.rejected)
end

-- Runs A (straight, kept sim), B (replay), C (reordered queueing), D (mid-run
-- arrival). Returns A's trace for the caller's bookkeeping.
local function playAll(log, seed, label, mirror)
  local perm = gen.permutation(#log.cmds, seed + 3)
  local A = runner.run(log, { epoch = EPOCH, keepSim = true })
  local B = runner.run(log, { epoch = EPOCH })
  local Cc = runner.run(log, { epoch = EPOCH, order = perm })
  local D = runner.run(log, { epoch = EPOCH, arrival = true })
  runs = runs + 4

  local ok1, w1, d1 = runner.compare(A, B)
  if not ok1 then bad("%s: replay diverged at %s: %s", label, tostring(w1), d1) end
  local ok2, w2, d2 = runner.compare(A, Cc)
  if not ok2 then bad("%s: reordered queueing diverged at %s: %s", label, tostring(w2), d2) end
  local ok3, w3, d3 = runner.compare(A, D)
  if not ok3 then bad("%s: mid-run arrival diverged at %s: %s", label, tostring(w3), d3) end

  -- The generator's own interleaved sim is a fifth arrival pattern; present
  -- only when the log left gen.make unmodified.
  if log.genHash then
    if A.terminal ~= log.genHash or A.terminalTick ~= log.genTick then
      bad("%s: replay does not reproduce the generator's own match", label)
    end
  end

  local okI, iv = runner.invariants(A.sim)
  if not okI then
    bad("%s: %d invariant failure(s), first: %s", label, #iv, iv[1])
  end

  if mirror then
    local m = runner.run(runner.mirrorLog(log), { epoch = EPOCH })
    runs = runs + 1
    local okM, why = runner.mirrorCompare(A, m)
    if not okM then bad("%s: A.2 mirror broke: %s", label, why) end
  end

  fold(A)
  A.sim = nil
  return A
end

-- ---------------------------------------------------------------------------
-- mode: cards
-- ---------------------------------------------------------------------------

local function runCards()
  print(format("M3 cards: 40 cards x { vs-empty + mirrored-pair } x 4 arrival patterns"))
  print(format("  rulesHash %s (%s)   ticks %d   epoch %d   seeds %d/%d",
    Hash.dec(Rules.rulesHash), Rules.rulesHash36, C.MATCH_TICKS, EPOCH,
    SEED_CARD_EMPTY, SEED_CARD_MIRROR))
  print("  verb atoms injected for: investment, scorchedEarth, leyLine (owner + no-card fizzle)")
  local full, ended = 0, 0
  for id = 1, #Rules.CARDS do
    local key = Rules.CARDS[id].key
    local lo = { id, 0, 0, 0, 0 }

    local seedE = SEED_CARD_EMPTY + id * 13
    local logE = gen.make(seedE, { loadoutA = lo })
    local verbs = liveVerbs(lo, { 0, 0, 0, 0, 0 })
    if verbs then logE = injectVerbs(logE, verbs, seedE) end
    local a = playAll(logE, seedE, key .. "/vs-empty", true)

    local seedM = SEED_CARD_MIRROR + id * 13
    local logM = gen.make(seedM, { loadoutA = lo, loadoutB = lo })
    local verbsM = liveVerbs(lo, lo)          -- BOTH sides own the verb here
    if verbsM then logM = injectVerbs(logM, verbsM, seedM) end
    local b = playAll(logM, seedM, key .. "/mirror", false)

    for _, t in ipairs({ a, b }) do
      if t.terminalTick >= C.MATCH_TICKS then full = full + 1 end
      if t.over then ended = ended + 1 end
    end
    io.write(format("  %2d %-16s vs-empty %s@%d   mirror %s@%d\n",
      id, key, Hash.dec(a.terminal), a.terminalTick, Hash.dec(b.terminal), b.terminalTick))
    io.flush()
  end
  print(format("  80 matches, %d ran the full %d ticks, %d terminated", full, C.MATCH_TICKS, ended))
  if ended < 80 then bad("cards: %d of 80 matches did not terminate", 80 - ended) end
end

-- ---------------------------------------------------------------------------
-- mode: loadouts
-- ---------------------------------------------------------------------------

local function runLoadouts()
  print(format("M3 loadouts: %d random 5-card pairs x 4 arrival patterns, full length", NLOADOUTS))
  print(format("  rulesHash %s (%s)   ticks %d   epoch %d   seed base %d",
    Hash.dec(Rules.rulesHash), Rules.rulesHash36, C.MATCH_TICKS, EPOCH, SEED_LOADOUT))
  local full, ended, injected = 0, 0, 0
  for i = 1, NLOADOUTS do
    local loA, loB = drawPair(i)
    local seed = loadoutSeed(i)
    local log = gen.make(seed, { loadoutA = loA, loadoutB = loB })
    local verbs = liveVerbs(loA, loB)
    if verbs then
      log = injectVerbs(log, verbs, seed)
      injected = injected + 1
    end
    local t = playAll(log, seed, format("pair %d (%s | %s)", i, loadoutStr(loA), loadoutStr(loB)),
      (i % 8) == 1)   -- every 8th pair also mirrored: 25 A.2 checks over random loadouts
    if t.terminalTick >= C.MATCH_TICKS then full = full + 1 end
    if t.over then ended = ended + 1 end
    if i % 25 == 0 then
      io.write(format("  %d pairs, %d failures\n", i, fails))
      io.flush()
    end
  end
  print(format("  %d matches, %d ran the full %d ticks, %d terminated, %d carried injected verbs",
    NLOADOUTS, full, C.MATCH_TICKS, ended, injected))
  if ended < NLOADOUTS then bad("loadouts: %d matches did not terminate", NLOADOUTS - ended) end
  if NLOADOUTS >= 200 and injected < 30 then
    -- With 5-of-40 draws on both sides a verb card is present in ~55% of
    -- pairs; a run that somehow injected almost none is not exercising the
    -- dispatch and should say so rather than certify.
    bad("loadouts: only %d pairs carried a verb card -- the draw is suspect", injected)
  end
end

-- ---------------------------------------------------------------------------
-- mode: clamp
-- ---------------------------------------------------------------------------

-- The maximum a NON-static card can add to a channel at any moment of a
-- match, read off the hashed card table (tools may not copy card numbers):
-- pts1-or-cap on ch1 (Tide of Bodies and the two levyFlat ramps express their
-- ceiling as `cap`), pts2 on ch2 (Granary Reserves' conditional half), foePts
-- on foeCh (Hex's windowed write; Discord's static one is already inside the
-- measured sd.chan and is skipped). STATIC cards are skipped entirely --
-- their contribution is measured, not derived.
local STATIC_BOTH = {
  breedingPits = true, chaff = true, scentTrails = true, ricketyScaffolds = true,
  pressGang = true, masterMasons = true, boomtown = true, sappers = true,
}
local STATIC_CH1 = { granaryReserves = true }

local function cardPeaks(id, own, foe)
  local cd = Rules.CARDS[id]
  if not STATIC_BOTH[cd.key] then
    if cd.ch1 ~= 0 and not STATIC_CH1[cd.key] then
      local v = cd.pts1
      if v == 0 then v = cd.cap end
      own[cd.ch1] = (own[cd.ch1] or 0) + v
    end
    if cd.ch2 ~= 0 then
      own[cd.ch2] = (own[cd.ch2] or 0) + cd.pts2
    end
  end
  if cd.foeCh ~= 0 and cd.every ~= 0 then
    foe[cd.foeCh] = (foe[cd.foeCh] or 0) + cd.foePts
  end
end

local function runClamp()
  print(format("M3 clamp-saturation report: the %d drawn pairs of the loadouts gate (seed base %d)",
    NLOADOUTS, SEED_LOADOUT))
  print(format("  rulesHash %s (%s)", Hash.dec(Rules.rulesHash), Rules.rulesHash36))
  print("")
  print("  Per side of each pair: STATIC channel points measured off the installed")
  print("  sim's sd.chan (Discord's cross-write included), plus the loadout's maximum")
  print("  conditional/time-varying points derived from Rules.CARDS. `sat` counts")
  print("  sides whose summed potential exceeds the Q4 clamp -- LEGAL, applied at the")
  print("  clamp (D.2: saturation replaces the old headcount cap), and the wasted")
  print("  points are the loadout UI's warning population. That the sim APPLIES the")
  print("  clamp is the applied-value probe below the census; the exact per-channel")
  print("  clamp arithmetic is selftest section 13's pins, not this report's job.")
  print("")

  local nCh = #Rules.CHANNELS
  local sides = 0
  local lo_, hi_, satHi, satLo, touched = {}, {}, {}, {}, {}
  local combos = {}          -- [ch] = { [comboString] = count }
  for ch = 1, nCh do
    local b = (ch == Rules.CH.slotCap) and C.SLOT_CAP or 0
    lo_[ch] = b; hi_[ch] = b; satHi[ch] = 0; satLo[ch] = 0; touched[ch] = 0
    combos[ch] = {}
  end

  for i = 1, NLOADOUTS do
    local loA, loB = drawPair(i)
    local sim = SimM.new(Rules, loadoutSeed(i), loA, loB)
    for s = 1, 2 do
      sides = sides + 1
      local sd = sim.sides[s]
      local own, foeAdd = {}, {}
      local myLo = (s == 1) and loA or loB
      local foeLo = (s == 1) and loB or loA
      for k = 1, 5 do
        cardPeaks(myLo[k], own, {})
        local dummy = {}
        cardPeaks(foeLo[k], dummy, foeAdd)   -- their Hex lands on MY channels
      end
      for ch = 1, nCh do
        -- slotCap's clamp is ABSOLUTE ([4,5] over SLOT_CAP + points -- see
        -- Sim.slotCapOf); every other channel clamps the summed points
        -- directly (levyFlat's clamp is over the MODIFIER flat, the building
        -- flat is a separate term -- Sim.phaseIncome).
        local base = (ch == Rules.CH.slotCap) and C.SLOT_CAP or 0
        local sum = base + sd.chan[ch] + (own[ch] or 0) + (foeAdd[ch] or 0)
        if sum ~= base then touched[ch] = touched[ch] + 1 end
        if sum < lo_[ch] then lo_[ch] = sum end
        if sum > hi_[ch] then hi_[ch] = sum end
        local cl = Rules.CLAMPS[ch]
        if sum > cl[2] or sum < cl[1] then
          if sum > cl[2] then satHi[ch] = satHi[ch] + 1 else satLo[ch] = satLo[ch] + 1 end
          -- name the cards of THIS side's loadout that touch this channel
          -- (their Hex is named from the owner's chair as hex>, so a
          -- saturation caused from across the board is attributable)
          local who = {}
          for k = 1, 5 do
            local cd = Rules.CARDS[myLo[k]]
            if cd.ch1 == ch or cd.ch2 == ch then who[#who + 1] = cd.key end
          end
          for k = 1, 5 do
            local cd = Rules.CARDS[foeLo[k]]
            if cd.foeCh == ch then who[#who + 1] = cd.key .. ">" end
          end
          table.sort(who)
          local combo = table.concat(who, "+")
          combos[ch][combo] = (combos[ch][combo] or 0) + 1
        end
      end
    end
  end

  print(format("  %-15s %-12s %6s %6s %6s %6s %6s", "channel", "clamp", "sides", "min", "max", "satHi", "satLo"))
  for ch = 1, nCh do
    local cl = Rules.CLAMPS[ch]
    print(format("  %-15s [%4d,%4d] %6d %6d %6d %6d %6d",
      Rules.CHANNELS[ch], cl[1], cl[2], touched[ch], lo_[ch], hi_[ch], satHi[ch], satLo[ch]))
  end
  print("")
  -- ------------------------------------------------------------------
  -- THE APPLIED-VALUE PROBE. The census above measures summed POTENTIAL;
  -- proving the sim APPLIES the clamp needs an observation of the sim
  -- acting, not this tool clamping its own copy of a number and testing it
  -- against the same bounds (the previous revision of this step did exactly
  -- that, and could not fail with Sim's clampCh deleted). unitCost is the
  -- observable channel -- D.2's "important one", and the only one a drawn
  -- loadout saturates statically: deploying one Spear charges
  -- floor(base * (100 + clampCh(points)) / 100) through Sim.unitCostOf, and
  -- sd.spent records exactly what was charged. Every drawn side whose
  -- unitCost points sit outside the Q4 clamp -- at tick 25 (static sum:
  -- sd.chan, Discord's cross-write included) or past Late Levy's gate
  -- (static sum plus its hashed pts1) -- deploys a Spear at BOTH ticks on a
  -- fresh sim of its own pair, plus the first 8 non-saturating sides as
  -- controls, and the two charged costs must equal this tool's OWN clamped
  -- arithmetic from Rules.CLAMPS. Sides holding a free-deployment [Rule]
  -- card (Endless Ranks, Conscription) are skipped: S5 can make the order's
  -- first unit free, which is a different mechanism than the one under
  -- test. With clampCh weakened, a chaff+breedingPits side pays 7 for a
  -- 10-Levy Spear instead of the clamped 8 and this probe goes red.
  local UC = Rules.CH.unitCost
  local ucl = Rules.CLAMPS[UC]
  local spearBase = Rules.UNITS[1].cost
  local llId = Rules.CARD_BY_KEY.lateLevy
  local llCard = Rules.CARDS[llId]
  local llTick = floor(C.MATCH_TICKS * llCard.gatePermille / 1000) + 5
  local erId, cnId = Rules.CARD_BY_KEY.endlessRanks, Rules.CARD_BY_KEY.conscription
  local function clampedCost(pts)
    if pts < ucl[1] then pts = ucl[1] end
    if pts > ucl[2] then pts = ucl[2] end
    local c = floor(spearBase * (100 + pts) / 100)
    if c < 1 then c = 1 end
    return c
  end
  local probed, satProbed, ctrls, skippedSat = 0, 0, 0, 0
  for i = 1, NLOADOUTS do
    local loA, loB = drawPair(i)
    local sim0 = SimM.new(Rules, loadoutSeed(i), loA, loB)
    for s = 1, 2 do
      local myLo = (s == 1) and loA or loB
      local free = ownsCard(myLo, erId) or ownsCard(myLo, cnId)
      local early = sim0.sides[s].chan[UC]
      local late = early + (ownsCard(myLo, llId) and llCard.pts1 or 0)
      local sat = early < ucl[1] or early > ucl[2] or late < ucl[1] or late > ucl[2]
      if sat and free then skippedSat = skippedSat + 1 end
      if (sat or ctrls < 8) and not free then
        if not sat then ctrls = ctrls + 1 end
        local sim = SimM.new(Rules, loadoutSeed(i), loA, loB)
        sim:queueCommand({ side = s, seq = 1, tick = 25, kind = "S", target = 1, count = 1 })
        sim:queueCommand({ side = s, seq = 2, tick = llTick, kind = "S", target = 1, count = 1 })
        sim:run(llTick + 1)
        local want = clampedCost(early) + clampedCost(late)
        probed = probed + 1
        if sat then satProbed = satProbed + 1 end
        if sim.sides[s].spent ~= want then
          bad("clamp probe: pair %d side %d (%s): two Spears charged %d, clamped expectation %d"
            .. " (points %d early / %d late)",
            i, s, loadoutStr(myLo), sim.sides[s].spent, want, early, late)
        end
      end
    end
  end
  print(format("  applied-value probe: %d sides deployed Spears at ticks 25 and %d;"
    .. " %d saturate unitCost, %d are in-clamp controls,",
    probed, llTick, satProbed, ctrls))
  print(format("  %d saturating sides skipped (free-deployment cards); every charged cost"
    .. " equals the independently clamped arithmetic", skippedSat))
  if satProbed == 0 then
    bad("clamp probe: no saturating side was probeable -- the probe proved nothing about the clamp")
  end

  print("")
  print("  co-saturating card sets (count x combination; `>` marks the opponent's")
  print("  cross-channel card, e.g. Hex arriving on this side's levyTick):")
  local any = false
  for ch = 1, nCh do
    local keys = {}
    for combo in pairs(combos[ch]) do keys[#keys + 1] = combo end
    table.sort(keys)
    if #keys > 0 then
      any = true
      print(format("    %s:", Rules.CHANNELS[ch]))
      for k = 1, #keys do
        print(format("      %4d x %s", combos[ch][keys[k]], keys[k]))
      end
    end
  end
  if not any then print("    (none: no drawn loadout drives any channel past its clamp)") end

  -- The D.2 worked example, asserted whenever the draw produced it: a loadout
  -- holding Vanguard + War Drums saturates unitDmg (35 + 15 over a +35 clamp),
  -- and one holding Chaff + Breeding Pits saturates unitCost downward
  -- (-20 - 10 under a -20 clamp).
  local chkVW, chkCB = 0, 0
  local vg, wd = Rules.CARD_BY_KEY.vanguard, Rules.CARD_BY_KEY.warDrums
  local cf, bp = Rules.CARD_BY_KEY.chaff, Rules.CARD_BY_KEY.breedingPits
  for i = 1, NLOADOUTS do
    local loA, loB = drawPair(i)
    for _, l in ipairs({ loA, loB }) do
      if ownsCard(l, vg) and ownsCard(l, wd) then chkVW = chkVW + 1 end
      if ownsCard(l, cf) and ownsCard(l, bp) then chkCB = chkCB + 1 end
    end
  end
  print("")
  print(format("  D.2 cross-check: %d drawn sides hold Vanguard+War Drums (each is a unitDmg satHi),"
    .. " %d hold Chaff+Breeding Pits (each a unitCost satLo)", chkVW, chkCB))
  if chkVW > satHi[Rules.CH.unitDmg] then
    bad("clamp: Vanguard+War Drums sides (%d) exceed unitDmg saturations (%d) -- the report missed some",
      chkVW, satHi[Rules.CH.unitDmg])
  end
  if chkCB > satLo[Rules.CH.unitCost] then
    bad("clamp: Chaff+Breeding Pits sides (%d) exceed unitCost satLo (%d) -- the report missed some",
      chkCB, satLo[Rules.CH.unitCost])
  end
end

-- ---------------------------------------------------------------------------

if MODE == "cards" then
  runCards()
elseif MODE == "loadouts" then
  runLoadouts()
elseif MODE == "clamp" then
  runClamp()
else
  print("m3gate: unknown mode " .. tostring(MODE) .. " (cards | loadouts [n] | clamp [n])")
  os.exit(2)
end

if MODE == "cards" or MODE == "loadouts" then
  print(format("M3 %s SUITE HASH %s (%s) over %d runs",
    MODE:upper(), Hash.dec(suite), Hash.base36(suite, 5), runs))
end

if fails > 0 then
  print(format("M3 %s: FAILED -- %d failure(s)", MODE, fails))
  os.exit(1)
end
print(format("M3 %s: PASS", MODE))
