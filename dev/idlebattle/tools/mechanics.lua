-- tools/mechanics.lua -- targeted tests for the rules the random logs rarely hit.
-- The determinism harness proves the sim agrees with itself; this file proves it
-- agrees with the design document.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Rules = require("sim.Rules")
local Sim = require("sim.Sim")
local C = Rules.C

local fails = 0
local function check(name, got, want)
  if got ~= want then
    fails = fails + 1
    print(string.format("FAIL  %-52s got %s want %s", name, tostring(got), tostring(want)))
  else
    print(string.format("ok    %-52s %s", name, tostring(got)))
  end
end

local function newRich()
  local sm = Sim.new(Rules, 1)
  sm.sides[1].bank = 100000
  sm.sides[2].bank = 100000
  return sm
end

-- ---------------------------------------------------------------------------
-- Trap Pit: 3600 burst, 1100 per target, up to 6 targets, NO OVERKILL.
-- Against 420-HP Spears each target absorbs only 420, so six die for 2520 of the
-- budget. Against 1020-HP Horses the per-target cap binds: three take 1020 and
-- the fourth takes the remaining 540.
-- ---------------------------------------------------------------------------
local function trapAgainst(kind, n)
  local sm = newRich()
  local seq = 0
  local function q(side, tick, k, target, count)
    seq = seq + 1
    sm:queueCommand({ side = side, seq = seq, tick = tick, kind = k, target = target, count = count })
  end
  q(2, 20, "a", 1, 1)                       -- side 2 Trap Pit, lane 1 front slot
  for i = 1, n do q(1, 100, kind, 1, 1) end -- side 1 walks into it
  local before, after = n, n
  for _ = 1, 3000 do
    sm:tick()
    local pit = sm.sides[2].slots[1]
    if pit and pit.spent == 1 then
      after = sm:unitCount(1, 1)
      break
    end
    before = sm:unitCount(1, 1)
  end
  local hps = {}
  local us = sm.sides[1].lanes[1].units
  for i = 1, #us do hps[#hps + 1] = us[i].hp end
  table.sort(hps)
  return before - after, hps[1]
end
local killedS = trapAgainst("S", 10)
check("Trap Pit kills 6 Spears, capped by its 6-target limit", killedS, 6)
local killedH, lowH = trapAgainst("H", 6)
check("Trap Pit kills 3 Horses (1020 each, budget 3600)", killedH, 3)
check("Trap Pit's leftover 540 lands on the fourth Horse", lowH, 1020 - 540)

-- ---------------------------------------------------------------------------
-- Repel refund (15 percent, defence dial) and Spoils (75 percent, offence dial)
-- ---------------------------------------------------------------------------
-- Both are measured on `earned`, not on `bank`: these fixtures run with a bank
-- far above the 200 cap, so every credit would otherwise land in `wasted`.
-- Everything a side earns beyond its stipend and its base income is a refund or
-- a spoil, so subtracting the schedule isolates them exactly.
local function extraEarned(sm, side)
  local levyTicks = 0
  if sm.clock >= 1 then levyTicks = math.floor((sm.clock - 1) / C.LEVY_EVERY) end
  return sm.sides[side].earned - C.OPENING_STIPEND - levyTicks * C.BASE_INCOME
end

do
  -- A lone Spear (cost 10) walks into an Arrow Tower and dies deep in side 2's
  -- half, so side 2 collects the repel refund.
  local sm = newRich()
  sm:queueCommand({ side = 2, seq = 1, tick = 20, kind = "e", target = 1, count = 1 })
  sm:queueCommand({ side = 1, seq = 1, tick = 200, kind = "S", target = 1, count = 1 })
  local diedAt = nil
  for _ = 1, 3000 do
    sm:tick()
    if sm.sides[1].unitsLost == 1 then diedAt = true; break end
  end
  check("the Spear died inside side 2's half", diedAt, true)
  check("repel refund is 15 percent of a Spear's 10 Levy", extraEarned(sm, 2), 1)

  -- The mirror case: a unit dying in its OWN half pays the killer nothing.
  -- Nine Spears against one meet near the midline, so the loser dies at about
  -- pos 970 -- its own side of the line.
  local sm2 = newRich()
  sm2:queueCommand({ side = 2, seq = 1, tick = 20, kind = "S", target = 1, count = 9 })
  sm2:queueCommand({ side = 1, seq = 1, tick = 20, kind = "S", target = 1, count = 1 })
  for _ = 1, 3000 do
    sm2:tick()
    if sm2.sides[1].unitsLost >= 1 then break end
  end
  check("no refund for a kill outside your own half", extraEarned(sm2, 2), 0)
end
do
  -- Side 1's Spears raze side 2's Trap Pit (cost 50) -> 75 percent = 37 Levy.
  -- Ten Spears, because the pit's burst kills the first six on the way in.
  local sm = newRich()
  sm:queueCommand({ side = 2, seq = 1, tick = 20, kind = "a", target = 1, count = 1 })
  for i = 1, 10 do
    sm:queueCommand({ side = 1, seq = i, tick = 200, kind = "S", target = 1, count = 1 })
  end
  for _ = 1, 4000 do
    sm:tick()
    if sm.sides[2].bldLost == 1 then break end
  end
  check("spoils are 75 percent of a Trap Pit's 50 Levy", extraEarned(sm, 1), 37)
  check("razing it moves the ladder T2 counter", sm.sides[1].slotsDestroyed, 1)
  check("and frees the slot for a rebuild", sm.sides[2].slots[1], false)
end

-- ---------------------------------------------------------------------------
-- Slot cap: 4 of 6 occupied, the fifth build fizzles
-- ---------------------------------------------------------------------------
do
  local sm = newRich()
  local order = { { "a", 1 }, { "d", 2 }, { "b", 3 }, { "j", 4 }, { "c", 5 }, { "k", 6 } }
  for i = 1, 6 do
    sm:queueCommand({ side = 1, seq = i, tick = 20 + i, kind = order[i][1],
                      target = order[i][2], count = 1 })
  end
  sm:run(200)
  local n = 0
  for s = 1, C.SLOTS do if sm.sides[1].slots[s] then n = n + 1 end end
  check("slot cap holds at 4 occupied", n, 4)
  check("the two over-cap builds fizzle", sm.sides[1].cmdsFizzled, 2)
end

-- ---------------------------------------------------------------------------
-- Buildings block advance and are chewed before the keep
-- ---------------------------------------------------------------------------
do
  local sm = newRich()
  sm:queueCommand({ side = 2, seq = 1, tick = 20, kind = "c", target = 1, count = 1 })  -- Palisade
  sm:queueCommand({ side = 1, seq = 1, tick = 200, kind = "S", target = 1, count = 1 })
  sm:run(1200)
  local u = sm.sides[1].lanes[1].units[1]
  check("a Spear halts at its range from the enemy front slot", u.pos, 1300 - 60)
  check("the enemy keep is untouched while the wall stands", sm:keepHp(2), C.KEEP_HP)
  check("the wall is taking damage", sm.sides[2].slots[1].hp < 8800, true)
end

-- ---------------------------------------------------------------------------
-- Q10 tiebreak ladder. Every tier must fire; nothing in the ladder is dead code.
-- Counters are set directly one tick before the clock expires, which is a
-- white-box test of the ladder itself rather than of the road that reaches it.
-- ---------------------------------------------------------------------------
local function ladder(setup)
  local sm = Sim.new(Rules, 1)
  sm:run(C.MATCH_TICKS - 1)
  setup(sm.sides[1], sm.sides[2])
  sm:tick()
  local r = sm:result()
  return r.winner, r.tier, r.reason
end

local w, t, rs = ladder(function(a, b) a.keepDamageDealt = 500; b.keepDamageDealt = 400 end)
check("T1 enemy keep HP removed decides", t .. ":" .. w .. ":" .. rs, "1:1:clock")

w, t = ladder(function(a, b)
  a.keepDamageDealt = 400; b.keepDamageDealt = 400
  a.slotsDestroyed = 1; b.slotsDestroyed = 3
end)
check("T2 enemy slots destroyed decides", t .. ":" .. w, "2:2")

w, t = ladder(function(a, b)
  a.slotsDestroyed = 2; b.slotsDestroyed = 2
  a.lanes[1].depth = 3; a.lanes[2].depth = 1
  b.lanes[1].depth = 1
end)
check("T3 deepest penetration decides", t .. ":" .. w, "3:1")

w, t = ladder(function(a, b)
  a.lanes[1].depth = 2; b.lanes[1].depth = 2
  a.keepHp = 10; b.keepHp = 20
end)
check("T4 own keep HP remaining decides", t .. ":" .. w, "4:2")

w, t = ladder(function() end)
check("T5 draw when every tier ties", t .. ":" .. w, "5:0")

-- Unit kills must NOT be a tier: the pure-turtle exploit.
w, t = ladder(function(a, b) a.unitsKilled = 500; b.unitsKilled = 0 end)
check("unit kills are never a tier", t .. ":" .. w, "5:0")

-- ---------------------------------------------------------------------------
-- Depth banding: a unit must HOLD a band for 50 sim ticks to bank it
-- ---------------------------------------------------------------------------
do
  local sm = newRich()
  sm:queueCommand({ side = 1, seq = 1, tick = 20, kind = "S", target = 1, count = 1 })
  sm:run(20 + 131)   -- a Spear at 10 per tick reaches 1310, just past DEPTH_X1
  check("Spear is past the first depth band", sm.sides[1].lanes[1].units[1].pos >= C.DEPTH_X1, true)
  check("band not yet banked at 1 tick held", sm.sides[1].lanes[1].depth, 0)
  sm:run(49)
  check("band banked after 50 consecutive ticks", sm.sides[1].lanes[1].depth, 1)
  -- The Spear keeps marching to 1940 (its range from the enemy keep), so it
  -- eventually holds all three bands and the lane banks the maximum of 3.
  sm:run(120)
  check("all three bands banked once each is held", sm.sides[1].lanes[1].depth, 3)
  -- A unit that touches a band and dies immediately banks nothing.
  local sm2 = newRich()
  sm2:queueCommand({ side = 1, seq = 1, tick = 20, kind = "S", target = 2, count = 1 })
  sm2:run(20 + 131)
  sm2.sides[1].lanes[2].units[1].hp = 0
  sm2:run(60)
  check("a touched band is not banked without the 50-tick hold",
    sm2.sides[1].lanes[2].depth, 0)
end

-- ---------------------------------------------------------------------------
-- Command hygiene: dedup, late refusal, illegal kinds
-- ---------------------------------------------------------------------------
do
  local sm = Sim.new(Rules, 1)
  local ok1 = sm:queueCommand({ side = 1, seq = 1, tick = 100, kind = "S", target = 1, count = 1 })
  local ok2, err2 = sm:queueCommand({ side = 1, seq = 1, tick = 200, kind = "S", target = 1, count = 1 })
  local ok3, err3 = sm:queueCommand({ side = 2, seq = 1, tick = 100, kind = "S", target = 1, count = 1 })
  local ok4, err4 = sm:queueCommand({ side = 1, seq = 2, tick = 100, kind = "Z", target = 1, count = 1 })
  sm:run(150)
  local ok5, err5 = sm:queueCommand({ side = 1, seq = 3, tick = 10, kind = "S", target = 1, count = 1 })
  check("first command accepted", ok1, true)
  check("duplicate (side, seq) refused", err2, "duplicate")
  check("same seq from the other side accepted", ok3, true)
  check("unknown kind refused", err4, "kind")
  check("a command already in the past is refused", err5, "late")
end

-- ---------------------------------------------------------------------------
-- queueCommand is the sim's ONLY input gate, so target and count must be
-- integral before anything downstream indexes with them. A fractional target
-- slips past the `< 1 or > LANES` range guards: lane 1.5 errors mid-tick, slot
-- 2.5 writes a building the state hash's `for slot = 1, SLOTS` loop cannot see.
-- A fractional count makes Hash.log's accumulator non-integral, which throws in
-- string.sub on 5.3+ and truncates silently on 5.1.
-- ---------------------------------------------------------------------------
do
  local sm = Sim.new(Rules, 1)
  local n = 0
  local function refuse(label, cmd, want)
    n = n + 1
    cmd.side = 1; cmd.seq = 100 + n; cmd.tick = 100
    local ok, err = sm:queueCommand(cmd)
    check(label, ok and "accepted" or err, want)
  end
  refuse("fractional lane refused", { kind = "S", target = 1.5, count = 1 }, "target")
  refuse("fractional slot refused", { kind = "d", target = 2.5, count = 1 }, "target")
  refuse("string target refused", { kind = "S", target = "1", count = 1 }, "target")
  refuse("fractional count refused", { kind = "S", target = 1, count = 3.5 }, "count")
  refuse("string count refused", { kind = "S", target = 1, count = "3" }, "count")
  -- RANGE is deliberately still legal at the gate: A.4 evaluates legality at the
  -- exec tick, so an out-of-range lane must fizzle in the sim, not be refused.
  refuse("out-of-range lane still ACCEPTED (fizzles at exec)",
    { kind = "S", target = 9, count = 1 }, "accepted")
  sm:run(120)
  check("the out-of-range lane fizzled in the sim", sm.sides[1].cmdsFizzled, 1)
  local d = sm:logDigest()
  check("log digest stayed integral", d == math.floor(d), true)
end

-- ---------------------------------------------------------------------------
-- ORDER DELAY (C.1). ORDER_DELAY and ORDER_DELAY_CLAMP are hashed constants, so
-- until something enforced them they were hashed but dead. Enforced at the gate,
-- and only when the caller supplies issueTick -- see INTERPRETATIONS 12.
-- ---------------------------------------------------------------------------
do
  local sm = Sim.new(Rules, 1)
  local n = 0
  local function try(label, issue, tick, want)
    n = n + 1
    local ok, err = sm:queueCommand({ side = 1, seq = 200 + n, tick = tick,
                                      issueTick = issue, kind = "S", target = 1, count = 1 })
    check(label, ok and "accepted" or err, want)
  end
  try("exec exactly at issue + ORDER_DELAY accepted", 100, 100 + C.ORDER_DELAY, "accepted")
  try("exec one tick inside the delay refused", 100, 100 + C.ORDER_DELAY - 1, "tooSoon")
  try("exec on the issue tick itself refused", 100, 100, "tooSoon")
  try("exec exactly at the clamp accepted", 100, 100 + C.ORDER_DELAY_CLAMP, "accepted")
  try("exec one tick past the clamp refused", 100, 100 + C.ORDER_DELAY_CLAMP + 1, "tooLate")
  try("fractional issueTick refused", 100.5, 130, "issueTick")
  -- Omitting issueTick leaves the window unchecked, which is the documented
  -- contract: the sim is a pure function of atoms with their EXEC ticks.
  local ok = sm:queueCommand({ side = 2, seq = 1, tick = 1, kind = "S", target = 1, count = 1 })
  check("an atom without issueTick is not delay-checked", ok, true)
end

-- ---------------------------------------------------------------------------
-- BANK CAP REDUCTION (INTERPRETATIONS 10). Razing a Granary drops the owner's
-- cap by 150. Levy ALREADY BANKED is not clawed back -- an attacker must not be
-- able to delete banked Levy retroactively -- so the owner keeps the balance and
-- every subsequent credit is fully wasted until it falls back under the cap.
-- ---------------------------------------------------------------------------
do
  local sm = Sim.new(Rules, 1)
  local gi = Rules.BUILDING_BY_LETTER["d"]
  local sd = sm.sides[1]
  sd.slots[2] = {
    id = 900, b = gi, slot = 2, lane = 1,
    hp = 10, maxHp = Rules.BUILDINGS[gi].hp, cost = Rules.BUILDINGS[gi].cost,
    prog = 999, startTick = 0, need = 1, done = 1, spent = 0,
    snapHp = 0, pend = 0, pendSrc = 0,
  }
  sd.cacheBankCap = 150
  sd.cacheLevyFlat = 1
  sd.bank = 350
  sd.earned = 350
  check("cap with a Granary standing", C.BANK_CAP + sd.cacheBankCap, 350)

  -- Raze it, via the sim's own destruction path.
  sm.clock = 100
  sm.hooks.onResolveStart = function(sim)
    local b = sim.sides[1].slots[2]
    if b then b.pend = b.pend + 9999 end
  end
  sm:tick()
  sm.hooks.onResolveStart = nil

  check("the Granary is gone", sd.slots[2], false)
  check("cap fell back to the base", C.BANK_CAP + sd.cacheBankCap, 200)
  check("banked Levy SURVIVES the cap reduction", sd.bank, 350)
  local wastedBefore = sd.wasted
  sm:run(40)   -- carries past at least one Levy tick
  check("every credit over the lowered cap is wasted", sd.bank, 350)
  check("and the waste counter moved", sd.wasted > wastedBefore, true)
  check("books still balance", sd.bank, sd.earned - sd.wasted - sd.spent)
end

if fails > 0 then
  print("FAILURES: " .. fails)
  os.exit(1)
end
print("all mechanics checks passed")
