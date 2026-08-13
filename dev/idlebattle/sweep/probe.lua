-- sweep/probe.lua -- what does ONE building actually cost, held against a control?
--
-- THE QUESTION. README Finding 1 states that "a building costs about 0.15pp of
-- win rate per Levy, and none of them earns it back", that the penalty tracks
-- the PRICE rather than the effect, and concludes that C.4's catalogue is a
-- factor of two too expensive. That is a recommendation to change a hashed
-- ruleset constant, which under A.11.1 is a hard compatibility break -- so it
-- had better be measured against a control and carry an error bar.
--
-- sweep/famstat.lua test 4 could not confirm it: across the sixteen lines of the
-- round-robin, building spend and win rate are not significantly associated,
-- because the sixteen lines differ in a dozen other ways at the same time. That
-- is exactly the confound a controlled probe removes.
--
-- THE DESIGN. One CONTROL line -- a plain, middling attacker with no opening
-- building at all -- and one VARIANT per building in the catalogue, identical to
-- the control in all nineteen configuration fields except that it opens by
-- buying that one building. Each plays the whole sixteen-line pool from BOTH
-- seats at N seeds, so every variant faces exactly the same opposition over
-- exactly the same seeds and the only difference between two rows of the output
-- is the building.
--
-- TWO THINGS ARE MEASURED, and they are different claims:
--   A  does buying ANY building cost win rate?      control vs each variant
--   B  does the penalty track the PRICE?            rank correlation of the
--                                                   penalty against cost, with
--                                                   a permutation null
-- Finding 1 asserts both. B is the one that licenses "halve every price"; A on
-- its own licenses only "buildings are not worth their tempo to THIS control".
--
-- EVERY NUMBER CARRIES A STANDARD ERROR, computed with an integer Newton square
-- root, because the whole question is whether a 6-point gap between two variants
-- is a fact or a coin. At 192 matches a win rate has a standard error of about
-- 3.6pp, so a difference between two variants needs to clear roughly 10pp before
-- it means anything, and most of the differences in Finding 1's table do not.
--
--   usage: lua sweep/probe.lua [seeds] [controlLine]
--          seeds        default 6 -> 192 matches per variant
--          controlLine  default "Balanced"; its opening is stripped to make the
--                       control, and every other field is inherited
--
-- A DIAGNOSTIC, not a gate: always exits 0. Held to the same determinism rules
-- as the rest of sweep/.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
local Rand = IB_SIM_MODULES and IB_SIM_MODULES.Rand or require("sim.Rand")
local Policy = IB_SIM_MODULES and IB_SIM_MODULES.Policy or require("policy.Policy")
local linesM = IB_SIM_MODULES and IB_SIM_MODULES.lines or require("policy.lines")
local driver = IB_SIM_MODULES and IB_SIM_MODULES.driver or require("sweep.driver")
local measure = IB_SIM_MODULES and IB_SIM_MODULES.measure or require("sweep.measure")

local floor = math.floor
local format = string.format

local SEEDS = tonumber(arg and arg[1]) or 6
local CONTROL = arg and arg[2] or "Balanced"
local SHUFFLES = 20000
local STAT_SEED = 20260812

local permille = measure.permille

local function pmStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%d%%", neg and "-" or "", whole, a - whole * 10)
end

local function ppStr(pm)
  local neg = pm < 0
  local a = neg and -pm or pm
  local whole = floor(a / 10)
  return format("%s%d.%dpp", neg and "-" or "+", whole, a - whole * 10)
end

-- Integer Newton square root. No math.sqrt anywhere: it returns a float, and a
-- float that reaches string.format prints differently across Lua versions.
local function isqrt(v)
  if v <= 0 then return 0 end
  local x = v
  local y = floor((x + 1) / 2)
  while y < x do
    x = y
    y = floor((x + floor(v / x)) / 2)
  end
  return x
end

-- Standard error of a win rate, in permille. Binomial, which slightly
-- OVERSTATES the error when draws are present (a draw is half a win and has
-- less variance than a coin), so every interval printed here is conservative.
local function sePm(pm, n)
  if n <= 0 then return 0 end
  return isqrt(floor(pm * (1000 - pm) / n))
end

-- ---------------------------------------------------------------------------
-- building a variant of a line
--
-- Every cfg field policy/lines.lua's line() constructor writes is copied by NAME
-- here. Copying by name rather than with a generic loop is not pedantry: pairs()
-- is banned (rule 2), and an unnamed field would silently revert to the engine's
-- default and turn a controlled comparison into an uncontrolled one. If
-- lines.lua ever grows a cfg field, the assertion below fails rather than this
-- file quietly probing the wrong thing.
-- ---------------------------------------------------------------------------

local CFG_FIELDS = {
  "nOpen", "holdUntilBuilt", "hold", "bankUntil", "bankHold", "stopBuildAt",
  "counter", "counterPct", "target", "mass", "cadence", "react", "reactAt",
  "minStack", "convertAt", "convertTo",
  -- `scout` is inherited from the control like every other field, which is what
  -- makes the probe controlled: a variant differs from its control in ONE
  -- opening building and not in whether it can see. Note the consequence for
  -- reading the table -- probing against a scouting control prices a building
  -- for a line that buys sight, and against a blind one for a line that does
  -- not, and the two are different questions.
  "scout",
  -- ...and HOW OFTEN it buys sight, for the same reason: a variant of a line
  -- that scouts three times as often as its control is not a controlled
  -- comparison of one building.
  "scoutEvery",
}

local function copyCfg(src)
  local c = {}
  for i = 1, #CFG_FIELDS do c[CFG_FIELDS[i]] = src[CFG_FIELDS[i]] end
  c.mix = { src.mix[1], src.mix[2], src.mix[3] }
  c.defend = nil
  if src.defend then
    c.defend = { bi = src.defend.bi, at = src.defend.at,
                 max = src.defend.max, notBefore = src.defend.notBefore }
  end
  c.open = {}
  c.nOpen = 0
  return c
end

-- THE GUARD, AND IT IS NOW A REAL ONE. This used to be a count that was computed,
-- printed and compared to nothing, under a comment claiming "the assertion below
-- fails rather than this file quietly probing the wrong thing" -- there was no
-- assertion. policy/lines.lua now exports the canonical cfg field list and
-- rebuilds every cfg through it, so the two lists can be compared element by
-- element in BOTH directions, which is the same discipline tools/rulescover.lua
-- applies to Rules.lua. A field added to lines.lua and not to this file now
-- fails the build instead of reverting to an engine default and turning a
-- controlled comparison into an uncontrolled one.
local CFG_FIELD_TOTAL = #CFG_FIELDS + 3   -- + mix, defend, open
do
  local declared = linesM.CFG_FIELDS
  if declared == nil then
    error("probe: policy/lines.lua exports no CFG_FIELDS -- the probe cannot "
      .. "know whether it is controlled", 0)
  end
  if CFG_FIELD_TOTAL ~= #declared then
    error(format("probe: lines.lua declares %d cfg fields, this file accounts "
      .. "for %d. A field was added to lines.lua and not here; the probe would "
      .. "have silently reverted it to the engine default.",
      #declared, CFG_FIELD_TOTAL), 0)
  end
  -- Direction 1: everything this file copies by name is a field lines.lua
  -- declares. Direction 2: everything lines.lua declares is either copied by
  -- name here or is one of the three handled by hand below.
  local byName = {}
  for i = 1, #CFG_FIELDS do byName[CFG_FIELDS[i]] = true end
  byName.mix = true; byName.defend = true; byName.open = true
  local declaredSet = {}
  for i = 1, #declared do declaredSet[declared[i]] = true end
  for i = 1, #CFG_FIELDS do
    if not declaredSet[CFG_FIELDS[i]] then
      error("probe: copies cfg." .. CFG_FIELDS[i]
        .. ", which lines.lua no longer declares", 0)
    end
  end
  for i = 1, #declared do
    if not byName[declared[i]] then
      error("probe: lines.lua declares cfg." .. declared[i]
        .. " and this file does not copy it -- the probe is not controlled", 0)
    end
  end
end

local base = linesM.BY_NAME[CONTROL]
if base == nil then error("probe: no such line: " .. tostring(CONTROL), 0) end
for i = 1, #CFG_FIELDS do
  if base.cfg[CFG_FIELDS[i]] == nil then
    error("probe: control line has no cfg." .. CFG_FIELDS[i]
      .. " -- lines.lua changed and this probe is no longer controlled", 0)
  end
end

local function makeLine(name, cfg)
  return Policy.define({
    name = name,
    family = base.family,
    note = "probe variant of " .. CONTROL .. ": " .. name,
    cfg = cfg,
    init = base.init,
    decide = base.decide,
  })
end

-- ---------------------------------------------------------------------------
-- the variants
-- ---------------------------------------------------------------------------

local variants, nVar = {}, 0
local function addVariant(name, bi)
  local cfg = copyCfg(base.cfg)
  if bi then
    local br = Rules.BUILDINGS[bi]
    cfg.open[1] = {
      bi = bi,
      front = (br.slotClass == "front") and 1 or 0,
      lane = 0,
      notBefore = 0,
    }
    cfg.nOpen = 1
  end
  nVar = nVar + 1
  variants[nVar] = {
    name = name,
    bi = bi,
    cost = bi and Rules.BUILDINGS[bi].cost or 0,
    def = makeLine(name, cfg),
  }
end

addVariant("no-building", nil)
for b = 1, #Rules.BUILDINGS do
  local br = Rules.BUILDINGS[b]
  -- Caravan is card-gated (Boom only) and the sim refuses it in M2, so probing
  -- it would measure a fizzle rather than a building.
  if br.cardGated == 0 then addVariant(br.key, b) end
end

-- ---------------------------------------------------------------------------
-- play each variant against the whole pool, both seats, same seeds
-- ---------------------------------------------------------------------------

print("Idle Battle M2 -- the controlled building probe")
print(format("  rulesHash   %s (%s)", Hash.dec(Rules.rulesHash), Rules.rulesHash36))
print(format("  control     %s with its opening stripped (%d cfg fields inherited)",
  CONTROL, CFG_FIELD_TOTAL))
print(format("  variants    %d, each = control + exactly one opening building",
  nVar))
print(format("  opposition  all %d lines, both seats, %d seeds -> %d matches each",
  #linesM.LINES, SEEDS, #linesM.LINES * 2 * SEEDS))
print("")

local POOL = linesM.LINES

for v = 1, nVar do
  local va = variants[v]
  local score, matches, keepWins, wins, tickSum = 0, 0, 0, 0, 0
  local built, spent = 0, 0
  local ord = 0
  for o = 1, #POOL do
    ord = ord + 1
    for s = 1, SEEDS do
      local seed = measure.seedFor(measure.SEED_BASE, ord, s)
      for seat = 1, 2 do
        local a, b = va.def, POOL[o]
        if seat == 2 then a, b = POOL[o], va.def end
        local m = driver.run({ a = a, b = b, seed = seed })
        local mine = m.slots[seat]
        matches = matches + 1
        if m.winnerSlot == seat then
          score = score + 2; wins = wins + 1
          if m.reason == "keep" then keepWins = keepWins + 1 end
        elseif m.winnerSlot == 0 then
          score = score + 1
        end
        tickSum = tickSum + m.ticks
        built = built + mine.buildsDone
        spent = spent + mine.spent
      end
    end
  end
  va.matches = matches
  va.pm = permille(score, matches * 2)
  va.se = sePm(va.pm, matches)
  va.keepPm = wins > 0 and permille(keepWins, wins) or 0
  va.lenSec = measure.secs(floor(tickSum / matches))
  va.builtPer = floor(built * 100 / matches)
  print(format("  ...%-12s %s +/- %s over %d matches",
    va.name, pmStr(va.pm), ppStr(va.se), matches))
end

-- ---------------------------------------------------------------------------
-- A: does buying ANY building cost win rate?
-- ---------------------------------------------------------------------------

local ctrl = variants[1]
print("")
print("== A. control vs each variant ====================================")
print(format("  the control is %s with no opening building: %s +/- %s",
  CONTROL, pmStr(ctrl.pm), ppStr(ctrl.se)))
print("")
print(format("  %-13s %-6s %-9s %-9s %-10s %-8s %s",
  "opening", "cost", "win", "+/-1 se", "vs control", "sigma", "built/match"))
print("  ------------------------------------------------------------------------")
for v = 1, nVar do
  local va = variants[v]
  local d = va.pm - ctrl.pm
  -- Standard error of the DIFFERENCE of two independent rates.
  local sd = isqrt(va.se * va.se + ctrl.se * ctrl.se)
  local sigma10 = sd > 0 and floor((d < 0 and -d or d) * 10 / sd) or 0
  local whole = floor(sigma10 / 10)
  print(format("  %-13s %-6d %-9s %-9s %-10s %d.%d      %d.%02d",
    va.name, va.cost, pmStr(va.pm), ppStr(va.se),
    v == 1 and "-" or ppStr(d), whole, sigma10 - whole * 10,
    floor(va.builtPer / 100), va.builtPer - floor(va.builtPer / 100) * 100))
end
print("")
print("  \"sigma\" is |difference| in standard errors of the difference. Below 2.0")
print("  the two rows are not distinguishable at this sample size, however")
print("  suggestive their order looks.")

-- ---------------------------------------------------------------------------
-- B: does the penalty track the PRICE?
-- ---------------------------------------------------------------------------

print("")
print("== B. does the penalty track the price? ==========================")
print("  Kendall S between building cost and win rate over the variants that")
print("  actually buy something, against a permutation null. Finding 1's claim")
print("  is that this is strongly negative: dearer building, worse result.")
print("")

local cost, win, nB = {}, {}, 0
for v = 2, nVar do
  nB = nB + 1
  cost[nB] = variants[v].cost
  win[nB] = variants[v].pm
end

local function kendallS(x, y, n)
  local s = 0
  for i = 1, n - 1 do
    for j = i + 1, n do
      local dx = x[i] - x[j]
      local dy = y[i] - y[j]
      if dx ~= 0 and dy ~= 0 then
        if (dx > 0) == (dy > 0) then s = s + 1 else s = s - 1 end
      end
    end
  end
  return s
end

local sObs = kendallS(cost, win, nB)
local rng = Rand.new(STAT_SEED)
local perm, shuf = {}, {}
local moreExtreme = 0
for _ = 1, SHUFFLES do
  for i = 1, nB do perm[i] = i end
  for i = nB, 2, -1 do
    local j = Rand.range(rng, 1, i)
    perm[i], perm[j] = perm[j], perm[i]
  end
  for i = 1, nB do shuf[i] = win[perm[i]] end
  local s = kendallS(cost, shuf, nB)
  local a = s < 0 and -s or s
  local b = sObs < 0 and -sObs or sObs
  if a >= b then moreExtreme = moreExtreme + 1 end
end
local p = permille(moreExtreme, SHUFFLES)
print(format("  Kendall S = %d over %d buildings, two-sided p = %s (%d shuffles)",
  sObs, nB, pmStr(p), SHUFFLES))
print("")
if p < 50 then
  print("  READ: the penalty does track the price. Finding 1's clause B stands and")
  print("  the catalogue is mispriced rather than any one building being bad.")
else
  print("  READ: the penalty does NOT track the price at this sample size. Whatever")
  print("  a building costs this control, it is not proportional to what it costs")
  print("  in Levy -- so \"halve every price\" is not the correction the data")
  print("  supports, and repricing the catalogue is not licensed by this probe.")
end

-- ---------------------------------------------------------------------------
-- C: the assumption-free test -- buildings that cost EXACTLY THE SAME
--
-- B can only ever say "dearer tends to be worse", and a catalogue that happens
-- to price its weakest effects highest would produce that correlation with the
-- price doing no work at all. The way to separate the two needs no model and no
-- classification of buildings into kinds: hold the PRICE fixed and see whether
-- the penalty is still free to move. If two buildings that cost the same Levy
-- differ by more than the whole catalogue differs across its price range, then
-- the effect is the dominant term and repricing cannot be the correction.
-- ---------------------------------------------------------------------------

print("")
print("== C. same price, different building =============================")
print("  Groups of buildings that cost EXACTLY the same, so tempo lost to saving")
print("  is identical by construction and the only thing left is the effect.")
print("")

local widestName, widest, widestCost = "-", -1, 0
local anyGroup = false
for v = 2, nVar do
  local c = variants[v].cost
  local first = true
  for w = 2, v - 1 do
    if variants[w].cost == c then first = false end
  end
  if first then
    local lo, hi, loN, hiN, n = 1001, -1, "-", "-", 0
    for w = 2, nVar do
      if variants[w].cost == c then
        n = n + 1
        if variants[w].pm < lo then lo = variants[w].pm; loN = variants[w].name end
        if variants[w].pm > hi then hi = variants[w].pm; hiN = variants[w].name end
      end
    end
    if n > 1 then
      anyGroup = true
      local seLo, seHi = 0, 0
      for w = 2, nVar do
        if variants[w].cost == c then
          if variants[w].name == loN then seLo = variants[w].se end
          if variants[w].name == hiN then seHi = variants[w].se end
        end
      end
      local sd = isqrt(seLo * seLo + seHi * seHi)
      local rng2 = hi - lo
      local sigma10 = sd > 0 and floor(rng2 * 10 / sd) or 0
      local whole = floor(sigma10 / 10)
      print(format("  %3d Levy, %d buildings: %s %s down to %s %s -- range %s (%d.%d sigma)",
        c, n, hiN, pmStr(hi), loN, pmStr(lo), ppStr(rng2), whole, sigma10 - whole * 10))
      if rng2 > widest then widest = rng2; widestName = hiN .. " vs " .. loN; widestCost = c end
    end
  end
end

if anyGroup then
  local bestPm, worstPm, bestN, worstN, bestC, worstC = -1, 1001, "-", "-", 0, 0
  for v = 2, nVar do
    if variants[v].pm > bestPm then
      bestPm = variants[v].pm; bestN = variants[v].name; bestC = variants[v].cost
    end
    if variants[v].pm < worstPm then
      worstPm = variants[v].pm; worstN = variants[v].name; worstC = variants[v].cost
    end
  end
  local across = bestPm - worstPm
  print("")
  print(format("  widest spread at ONE price:   %s   (%s, %d Levy)",
    ppStr(widest), widestName, widestCost))
  print(format("  spread over the WHOLE table:  %s   (%s %d Levy vs %s %d Levy)",
    ppStr(across), bestN, bestC, worstN, worstC))
  print("")
  if widest >= across then
    print("  READ: two buildings at the SAME price differ by at least as much as the")
    print("  whole catalogue differs across its entire price range. Price is not the")
    print("  dominant term -- the effect is. \"The penalty tracks the price, not the")
    print("  effect\" is the wrong way round, and halving every price would leave the")
    print("  buildings at the bottom of the table exactly where they are.")
  else
    print("  READ: the price range moves the penalty more than the effect does at a")
    print("  fixed price, so repricing is a coherent lever even though it is not the")
    print("  only one.")
  end
end

print("")
print("== what this probe does NOT settle ===============================")
print("  * Whether buildings are worth it to a DIFFERENT control. One control")
print("    line is one strategy; a building that is dead weight in front of a")
print("    mid-tempo attacker can still be correct behind a defensive one.")
print("    Granary-bank buys a 100-Levy Granary and is the best line in the")
print("    round-robin, which is the standing counter-example.")
print("  * Anything about human play (F.1).")
