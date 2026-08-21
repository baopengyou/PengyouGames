-- Mods.lua -- the modifier layer: the forty cards' RUNTIME (M3).
--
-- WHAT LIVES HERE AND WHAT DOES NOT. Every card NUMBER lives in Rules.CARDS,
-- inside rulesHash; this file holds only the semantics that turn those numbers
-- into channel points, runtime state and verb dispatch. Every mutable thing a
-- card owns lives inside the HASHED sim state: the static channel points in
-- sd.chan, per-lane machinery in the lane fields Hash.state already walks
-- (muster, bypass, cwAcc), the Vanguard flag on the unit (u.vg), and every
-- latch, countdown and cooldown in sd.mods keyed through sd.modsOrder -- so a
-- divergence in any of it is a heartbeat mismatch, never a silent fork.
--
-- HOW IT ATTACHES. Sim.new calls M.install(sim, INTERNAL) after both sides
-- exist and before the sim's own onMatchStart call. INTERNAL is a table of
-- Sim.lua's private helpers (credit, spend, queueCredit, flushCredits,
-- onUnitDeath, dmgTakenPts, addDamage, bankCapOf, clampCh, entity-kind codes),
-- passed by value so this file needs no require and no module cycle exists.
-- install() validates both loadouts, and -- the load-bearing property -- WITH
-- TWO EMPTY LOADOUTS IT INSTALLS NOTHING AT ALL: every sim.hooks field stays
-- nil, the tick path is the M1 tick path instruction for instruction, and a
-- cardless match plays byte-identically to the M1 game.
--
-- STACKING (Q4). A card contributes integer percentage POINTS into the same
-- per-side channels and the same clamp the buildings' lane auras use: static,
-- unconditional deltas are summed into sd.chan once at match start; scoped or
-- time-varying deltas are returned by the *Points hooks and join the SAME sum
-- at the point of use, clamped once, applied once (S2, S7). Nothing here
-- floors separately and nothing multiplies -- one implementation of "something
-- modified this number".
--
-- ARBITRATION (S5). At most one free-deployment effect fires per deploy order,
-- in ascending card id (Endless Ranks 5, then Conscription 8); at most one
-- bypass effect exists (Raiding Party). See INTERPRETATIONS 15 and 26.
--
-- THE FOUR INFORMATION CARDS (Divination, Omen, Veil, and the Shrine's reveal
-- pulse) are PERCEPTION effects: Ruling 1 shares the whole state, so what they
-- change is what a client RENDERS, which is fog/Fog.lua's jurisdiction. Their
-- sim-side existence is complete here -- ids, affinity, class, hashing,
-- loadout legality -- and their fog effects are the declared surface
-- M.INFO_EFFECTS at the bottom of this file, which fog/Fog.lua's EFFECTS
-- block consumes SINCE M3 PART 2 -- from fog/, never from sim/.
--
-- DETERMINISM. Held to every sim rule: integer arithmetic, "/" only inside
-- floor, no pairs/next/table.sort (ordered insertion instead), no clock, no
-- randomness, side-agnostic (every closure treats sides 1 and 2 through the
-- same spec table and no code path knows which side is local).

local M = {}

local floor = math.floor

-- Fixed key strings, so no number is ever concatenated into a hashed key.
local VG_KEY = { "vg1", "vg2", "vg3" }

-- ---------------------------------------------------------------------------
-- loadout validation (INTERPRETATIONS 13)
-- ---------------------------------------------------------------------------

-- sd.loadout has already been normalised by newSide to five slots with 0 for
-- missing entries; what is validated here is that each entry is an integer id
-- inside the pool and that no non-zero id repeats.
local function validateLoadout(R, sd, label)
  local seen = {}
  for i = 1, 5 do
    local v = sd.loadout[i]
    if type(v) ~= "number" or v ~= floor(v) then
      error("Sim: " .. label .. " loadout slot is not an integer card id")
    end
    if v < 0 or v > #R.CARDS then
      error("Sim: " .. label .. " loadout names a card outside the pool")
    end
    if v ~= 0 then
      if seen[v] then
        error("Sim: " .. label .. " loadout repeats a card (Q6: no duplicates)")
      end
      seen[v] = true
    end
  end
end

-- ---------------------------------------------------------------------------
-- install
-- ---------------------------------------------------------------------------

-- One spec per side: which cards it owns (flags plus the card rows, so every
-- number is read from the hashed table) -- built once, captured by the hook
-- closures. The spec is DERIVED from sd.loadout, which is hashed, so it needs
-- no storage of its own: rebuild-from-state (M4 rollback, replay) reruns
-- install and lands on the identical spec.
local function buildSpec(R, sd)
  local sp = { any = false }
  for i = 1, 5 do
    local id = sd.loadout[i]
    if id ~= 0 then
      sp.any = true
      local cd = R.CARDS[id]
      sp[cd.key] = cd          -- spec.chaff = the card row, etc.
    end
  end
  return sp
end

-- Sorted insertion of a runtime key into sd.mods / sd.modsOrder (the hash
-- walks modsOrder in order, and the README's checklist requires it sorted).
local function addModKey(sd, key, v)
  local order = sd.modsOrder
  local n = #order
  local i = n
  while i >= 1 and order[i] > key do
    order[i + 1] = order[i]
    i = i - 1
  end
  order[i + 1] = key
  sd.mods[key] = v
end

-- The Q3 bilinear edge: sum over i, j of m[i] * t[j] * W[i][j], an integer in
-- [-225, +225]. The opponent's edge is the exact negative (the wheel is
-- antisymmetric, asserted at Rules load), so one pass drives both sides.
local function wheelEdge(R, a, b)
  local m = { 0, 0, 0, 0, 0 }
  local t = { 0, 0, 0, 0, 0 }
  for i = 1, 5 do
    local ida, idb = a.loadout[i], b.loadout[i]
    if ida ~= 0 then
      local cd = R.CARDS[ida]
      m[1] = m[1] + cd.affSwarm
      m[2] = m[2] + cd.affBoom
      m[3] = m[3] + cd.affMystic
      m[4] = m[4] + cd.affFortress
      m[5] = m[5] + cd.affRaider
    end
    if idb ~= 0 then
      local cd = R.CARDS[idb]
      t[1] = t[1] + cd.affSwarm
      t[2] = t[2] + cd.affBoom
      t[3] = t[3] + cd.affMystic
      t[4] = t[4] + cd.affFortress
      t[5] = t[5] + cd.affRaider
    end
  end
  local edge = 0
  for i = 1, 5 do
    for j = 1, 5 do
      edge = edge + m[i] * t[j] * R.WHEEL[i][j]
    end
  end
  return edge
end

-- Cards whose ch1/ch2 are STATIC, unconditional channel deltas applied once at
-- match start. Scoped or gated cards (Bastion, Iron Discipline, Bulwark, Late
-- Levy, Rapid Masonry, the unitDmg rules, Granary Reserves' conditional half)
-- deliver their points through hooks instead, so the one clamp still sees one
-- sum. Granary Reserves' bankCap +50 (ch1) is static; its levyTick (ch2) is
-- conditional. Listed by key, walked in card-id order.
local STATIC_BOTH = {
  breedingPits = true, chaff = true, scentTrails = true, ricketyScaffolds = true,
  pressGang = true, masterMasons = true, boomtown = true, sappers = true,
}
local STATIC_CH1_ONLY = { granaryReserves = true }

function M.install(sim, INT)
  local R = sim.rules
  local C = R.C
  local s1, s2 = sim.sides[1], sim.sides[2]

  validateLoadout(R, s1, "side 1")
  validateLoadout(R, s2, "side 2")

  local spec = { buildSpec(R, s1), buildSpec(R, s2) }
  if not spec[1].any and not spec[2].any then
    -- Two empty loadouts: the M1 game. No hooks, no state, no new code on the
    -- tick path. This early return is what the "cardless matches are
    -- byte-identical in gameplay" claim rests on.
    return
  end

  local hooks = sim.hooks
  local UNITS = R.UNITS
  local MID = C.POS_MIDLINE

  -- Per-side presence of each mechanism, so a hook is registered only when
  -- some present card needs it and checks one flag at run time.
  local function has(key)
    return spec[1][key] ~= nil or spec[2][key] ~= nil
  end

  -- ------------------------------------------------------------------
  -- match start: static channel points, foe writes, unlocks, runtime
  -- keys, and the wheel edge. Registered as the named onMatchStart hook
  -- and fired by Sim.new through the standard call site.
  -- ------------------------------------------------------------------
  hooks.onMatchStart = function(sm)
    for s = 1, 2 do
      local sd = sm.sides[s]
      local es = sm.sides[3 - s]
      for i = 1, 5 do
        local id = sd.loadout[i]
        if id ~= 0 then
          local cd = R.CARDS[id]
          if STATIC_BOTH[cd.key] then
            if cd.ch1 ~= 0 then sd.chan[cd.ch1] = sd.chan[cd.ch1] + cd.pts1 end
            if cd.ch2 ~= 0 then sd.chan[cd.ch2] = sd.chan[cd.ch2] + cd.pts2 end
          elseif STATIC_CH1_ONLY[cd.key] then
            if cd.ch1 ~= 0 then sd.chan[cd.ch1] = sd.chan[cd.ch1] + cd.pts1 end
          end
          if cd.foeCh ~= 0 and cd.every == 0 then
            -- Discord: a value written into the OPPONENT's stat block when
            -- the loadout is read (Q5). Hex (every ~= 0) is time-windowed and
            -- goes through levyTickPoints instead.
            es.chan[cd.foeCh] = es.chan[cd.foeCh] + cd.foePts
          end
          if cd.unlockBld ~= 0 then
            sd.unlocks[cd.unlockBld] = 1          -- Caravan (Q8)
          end
        end
      end
      -- Runtime state, only for cards this side owns, keys sorted into
      -- modsOrder so Hash.state picks every one of them up.
      local sp = spec[s]
      if sp.goldenAge then addModKey(sd, "gaLatch", 0) end
      if sp.investment then addModKey(sd, "invAmt", 0); addModKey(sd, "invDue", 0) end
      if sp.warDrums then addModKey(sd, "wdUntil", 0) end
      if sp.scorchedEarth then addModKey(sd, "seCd", 0) end
      if sp.leyLine then addModKey(sd, "llCd", 0) end
      if sp.vanguard then
        addModKey(sd, VG_KEY[1], 0)
        addModKey(sd, VG_KEY[2], 0)
        addModKey(sd, VG_KEY[3], 0)
      end
    end
    -- Q3: one integer edge, both signs. Applied by Sim.unitDamage as the
    -- single final multiplier outside every clamp; never shown as a label.
    local edge = wheelEdge(R, sm.sides[1], sm.sides[2])
    sm.sides[1].wheelNum = edge
    sm.sides[2].wheelNum = -edge
  end

  -- ------------------------------------------------------------------
  -- income: the Levy-tick hooks
  -- ------------------------------------------------------------------
  if has("goldenAge") or has("investment") then
    -- Fixed order per INTERPRETATIONS 19: latch check, then payout; income
    -- follows in phaseIncome itself.
    hooks.onLevyTickStart = function(sm, sd)
      local sp = spec[sd.index]
      local ga = sp.goldenAge
      if ga and sd.mods.gaLatch == 0 and sd.earned >= ga.gateEarned then
        sd.mods.gaLatch = 1                       -- one-way latch
      end
      local inv = sp.investment
      if inv and sd.mods.invDue ~= 0 and sm.clock >= sd.mods.invDue then
        INT.credit(sm, sd, floor(sd.mods.invAmt * inv.pct / 100))
        sd.mods.invAmt = 0
        sd.mods.invDue = 0
      end
    end
  end

  if has("goldenAge") or has("granaryReserves") or has("hex") then
    hooks.levyTickPoints = function(sm, sd)
      local pts = 0
      local sp = spec[sd.index]
      local ga = sp.goldenAge
      if ga and sd.mods.gaLatch == 1 then pts = pts + ga.pts1 end
      local gr = sp.granaryReserves
      if gr and sd.bank * 2 >= INT.bankCapOf(sm, sd) then pts = pts + gr.pts2 end
      local hx = spec[3 - sd.index].hex
      if hx and sm.clock % hx.every < hx.window then pts = pts + hx.foePts end
      return pts
    end
  end

  if has("tradeRoutes") or has("surplus") then
    hooks.levyFlatPoints = function(sm, sd)
      local f = 0
      local sp = spec[sd.index]
      local tr = sp.tradeRoutes
      if tr then
        local n = floor(sm.clock / tr.every)
        if n > tr.cap then n = tr.cap end
        f = f + n * tr.per
      end
      local su = sp.surplus
      if su then
        local n = floor(sd.bank / su.perBank)
        if n > su.cap then n = su.cap end
        f = f + n * su.per
      end
      return f
    end
  end

  -- ------------------------------------------------------------------
  -- costs
  -- ------------------------------------------------------------------
  if has("lateLevy") then
    hooks.unitCostPoints = function(sm, sd, lane, t)
      local ll = spec[sd.index].lateLevy
      if ll and sm.clock >= floor(C.MATCH_TICKS * ll.gatePermille / 1000) then
        return ll.pts1
      end
      return 0
    end
  end

  if has("rapidMasonry") then
    hooks.rubbleCostPoints = function(sm, sd, slot)
      local rm = spec[sd.index].rapidMasonry
      if rm then return rm.pts1 end
      return 0
    end
  end

  if has("endlessRanks") or has("conscription") then
    -- S5: one free deployment per order, ascending card id (INTERPRETATIONS
    -- 15). freeUsed is transient within one order's execution: execDeploy
    -- calls this hook with i = 1..n strictly in order, single-threaded.
    local freeUsed = { false, false }
    hooks.deployCost = function(sm, sd, lane, t, cost, i)
      local si = sd.index
      if i == 1 then freeUsed[si] = false end
      if freeUsed[si] then return cost end
      local sp = spec[si]
      local er = sp.endlessRanks
      if er and i == 1 then
        local ln = sd.lanes[lane]
        if ln.muster > 0 and ln.supply + UNITS[t].cost <= C.LANE_SUPPLY_CAP then
          -- The charge is consumed only when the free unit can actually be
          -- placed (supply); with cost 0 the bank can never refuse it.
          ln.muster = ln.muster - 1
          freeUsed[si] = true
          return 0
        end
      end
      local cs = sp.conscription
      if cs and (sd.unitsDeployed + 1) % cs.per == 0 then
        freeUsed[si] = true
        return 0
      end
      return cost
    end
  end

  -- ------------------------------------------------------------------
  -- per-unit stat hooks. Each returns POINTS that join the channel sum at
  -- the call site and are clamped there, once, with everything else.
  -- ------------------------------------------------------------------
  if has("bulwarkLine") then
    hooks.unitHpPoints = function(sm, sd, t)
      local bl = spec[sd.index].bulwarkLine
      if bl and t == bl.scopeUnit then return bl.pts1 end
      return 0
    end
  end

  if has("ironDiscipline") then
    hooks.dmgTakenPoints = function(sm, sd, u)
      local id = spec[sd.index].ironDiscipline
      if id and u.pos < MID then return id.pts1 end
      return 0
    end
  end

  if has("raidingParty") then
    hooks.marchPoints = function(sm, sd, u)
      local rp = spec[sd.index].raidingParty
      if rp and u.t == rp.scopeUnit then return rp.pts1 end
      return 0
    end
  end

  if has("bastionWalls") then
    hooks.bldHpPoints = function(sm, sd, bi)
      local bw = spec[sd.index].bastionWalls
      if bw and R.BUILDINGS[bi].defensive == 1 then return bw.pts1 end
      return 0
    end
  end

  if has("watchfires") then
    hooks.bldRangePoints = function(sm, sd, b)
      local wf = spec[sd.index].watchfires
      local br = R.BUILDINGS[b.b]
      if wf and br.defensive == 1 then
        return floor(br.dmgRange * wf.pct / 100)
      end
      return 0
    end
  end

  -- Tide of Bodies reads a per-lane count of living friendly units taken at
  -- the tick-start snapshot; the counts live in transient scratch (recomputed
  -- every resolve tick, never read across ticks -- the same class as sim.cg).
  local tideN = { { 0, 0, 0 }, { 0, 0, 0 } }
  if has("tideOfBodies") or has("warDrums") or has("vanguard") or has("noRetreat") then
    hooks.unitDmgPoints = function(sm, sd, u)
      local pts = 0
      local sp = spec[sd.index]
      local tb = sp.tideOfBodies
      if tb then
        local n = tideN[sd.index][u.lane] * tb.per
        if n > tb.cap then n = tb.cap end             -- own-source ceiling
        pts = pts + n
      end
      local wd = sp.warDrums
      if wd and sm.clock < sd.mods.wdUntil then pts = pts + wd.pts1 end
      local vg = sp.vanguard
      if vg and u.vg == 1 then pts = pts + vg.pts1 end
      local nr = sp.noRetreat
      if nr then pts = pts + floor(nr.pts1 * (u.maxHp - u.snapHp) / u.maxHp) end
      return pts
    end
  end

  if has("vanguard") then
    hooks.onDeploy = function(sm, sd, u)
      local vg = spec[sd.index].vanguard
      if vg then
        local key = VG_KEY[u.lane]
        if sd.mods[key] < vg.perLaneMax then
          sd.mods[key] = sd.mods[key] + 1
          u.vg = 1                                    -- permanent, never transfers
        end
      end
    end
  end

  -- ------------------------------------------------------------------
  -- resolve-tick bookkeeping: Tide counts, the Bypass trigger, and
  -- Counterwall's clear-transition check -- all from the tick-start board.
  -- ------------------------------------------------------------------
  if has("tideOfBodies") or has("raidingParty") or has("counterwall") then
    hooks.onResolveStart = function(sm)
      for s = 1, 2 do
        local sd = sm.sides[s]
        local es = sm.sides[3 - s]
        local sp = spec[s]
        for lane = 1, C.LANES do
          if sp.tideOfBodies then
            tideN[s][lane] = #sd.lanes[lane].units
          end
          local rp = sp.raidingParty
          if rp then
            local ln = sd.lanes[lane]
            if ln.bypass == 0 then
              local b = es.slots[INT.frontSlot(lane)]
              if b then
                -- "Reach the enemy front slot while a front building stands":
                -- a Horse inside its weapon envelope of that building
                -- (INTERPRETATIONS 26).
                local bg = C.LANE_LEN - C.POS_FRONT_SLOT
                local us = ln.units
                for i = 1, #us do
                  local u = us[i]
                  if u.t == rp.scopeUnit and bg - u.pos <= UNITS[u.t].range then
                    ln.bypass = b.id
                    break
                  end
                end
              end
            end
          end
          local cw = sp.counterwall
          if cw then
            local ln = sd.lanes[lane]
            if ln.cwAcc > 0 and #es.lanes[lane].units == 0 then
              -- The lane just came clear of enemy units: pay the burst on top
              -- of the per-death 15% refunds, through the deferred-credit
              -- queue like every resolve-tick payout (INTERPRETATIONS 17).
              INT.queueCredit(sm, sd, floor(ln.cwAcc * cw.pct / 100))
              ln.cwAcc = 0
            end
          end
        end
      end
    end
  end

  -- ------------------------------------------------------------------
  -- damage-phase extras
  -- ------------------------------------------------------------------
  if has("deepFoundations") then
    -- sd here is the BUILDING OWNER. True = this back building cannot be
    -- damaged while its lane's front slot holds a building (complete or under
    -- construction). An empty or destroyed front slot confers nothing.
    hooks.bldImmune = function(sm, sd, b)
      local df = spec[sd.index].deepFoundations
      if df and b.slot % 2 == 0 then
        if sd.slots[INT.frontSlot(b.lane)] then return true end
      end
      return false
    end
  end

  if has("ward") then
    -- Called by Sim.unitDamage when a unit's damage lands on a building,
    -- with the pre-mitigation figure (INTERPRETATIONS 22). Writes into pend
    -- through the same addDamage every other source uses (S9).
    hooks.onStructHit = function(sm, sd, es, u, b, pre)
      local wd = spec[es.index].ward
      if wd then
        local d = floor(pre * wd.pct / 100)
        local m = INT.dmgTakenPts(sm, sd, u)
        if m ~= 0 then d = floor(d * (100 + m) / 100) end
        INT.addDamage(INT.K_UNIT, u, d, b.id)         -- kill credit: owner (S8)
      end
    end
  end

  if has("miasma") then
    hooks.onExtraDamage = function(sm)
      for s = 1, 2 do
        local mi = spec[s].miasma
        if mi then
          local sd = sm.sides[s]
          local es = sm.sides[3 - s]
          for lane = 1, C.LANES do
            local us = es.lanes[lane].units
            for i = 1, #us do
              local u = us[i]
              -- Owner-frame x < 1000 is enemy-frame pos > 1000: the unit is
              -- inside the card owner's half (INTERPRETATIONS 23).
              if u.snapHp > 0 and u.pos > MID then
                local d = mi.dmg
                local m = INT.dmgTakenPts(sm, es, u)
                if m ~= 0 then d = floor(d * (100 + m) / 100) end
                INT.addDamage(INT.K_UNIT, u, d, sd.keepId)
              end
            end
          end
        end
      end
    end
  end

  -- ------------------------------------------------------------------
  -- deaths and razings
  -- ------------------------------------------------------------------
  if has("endlessRanks") or has("bloodTithe") or has("warDrums") or has("counterwall") then
    hooks.onUnitDeath = function(sm, sd, es, u)
      -- sd lost the unit; es killed it (every damage source that can kill a
      -- unit belongs to the other side, S8).
      local er = spec[sd.index].endlessRanks
      if er then
        local ln = sd.lanes[u.lane]
        if ln.muster < er.perLaneMax then ln.muster = ln.muster + 1 end
      end
      local spe = spec[es.index]
      local bt = spe.bloodTithe
      if bt then
        INT.queueCredit(sm, es, floor(u.cost * bt.pct / 100))
      end
      local wd = spe.warDrums
      if wd then
        es.mods.wdUntil = sm.clock + wd.window        -- one timer per player
      end
      local cw = spe.counterwall
      if cw and u.pos > MID then
        -- Died past its own midline = inside the card owner's half. The
        -- accumulator counts PAID cost, the same figure the repel refund
        -- reads (INTERPRETATIONS 17).
        es.lanes[u.lane].cwAcc = es.lanes[u.lane].cwAcc + u.cost
      end
    end
  end

  if has("plunder") then
    hooks.onBuildingDestroyed = function(sm, sd, es, b, amt)
      local pl = spec[es.index].plunder
      if pl then
        -- Replaces the Spoils baseline rather than stacking with it.
        return floor(b.cost * pl.pct / 100) + pl.flat
      end
      return amt
    end
  end

  -- ------------------------------------------------------------------
  -- the three verbs: I Investment, E Scorched Earth, L Ley Line (A.11.2:
  -- uppercase, case is the namespace). Real dispatch replaces M1's
  -- fizzle-until-M3 default. A side that does not own the card fizzles.
  -- ------------------------------------------------------------------
  if has("investment") or has("scorchedEarth") or has("leyLine") then
    local function fizzle(sd) sd.cmdsFizzled = sd.cmdsFizzled + 1 end

    local function execInvest(sm, sd, c)
      local inv = spec[sd.index].investment
      if not inv then return fizzle(sd) end
      if sd.mods.invDue ~= 0 then return fizzle(sd) end   -- one outstanding
      local blocks = c.count
      if blocks > inv.blocksMax then blocks = inv.blocksMax end
      local cost = inv.costPerBlock * blocks
      if sd.bank < cost then return fizzle(sd) end
      INT.spend(sd, cost)
      sd.mods.invAmt = cost
      sd.mods.invDue = sm.clock + inv.window
      sd.cmdsExecuted = sd.cmdsExecuted + 1
    end

    local function execScorched(sm, sd, c)
      local se = spec[sd.index].scorchedEarth
      if not se then return fizzle(sd) end
      local lane = c.target
      if lane < 1 or lane > C.LANES then return fizzle(sd) end
      if sm.clock < sd.mods.seCd then return fizzle(sd) end
      local blocks = c.count
      if blocks > se.blocksMax then blocks = se.blocksMax end
      local cost = se.costPerBlock * blocks
      if sd.bank < cost then return fizzle(sd) end
      local es = sm.sides[3 - sd.index]
      local ln = es.lanes[lane]
      local us = ln.units
      local n = #us
      if n == 0 then return fizzle(sd) end            -- nothing to hit: no spend
      -- The up-to-targetsMax enemy units in that lane nearest MY keep: in
      -- their own frame that is the LARGEST pos, ties by lowest entity id
      -- (S10). Selection sort of at most targetsMax picks; no table.sort.
      local taken = {}
      local picks = se.targetsMax
      if picks > n then picks = n end
      INT.spend(sd, cost)
      local dmg = se.dmgPerBlock * blocks
      for _ = 1, picks do
        local bi, bp, bid = 0, -1, 0
        for i = 1, n do
          if not taken[i] then
            local u = us[i]
            if u.pos > bp or (u.pos == bp and u.id < bid) then
              bi = i; bp = u.pos; bid = u.id
            end
          end
        end
        taken[bi] = true
        local u = us[bi]
        local d = dmg
        local m = INT.dmgTakenPts(sm, es, u)          -- rides dmgTaken (S1/S2)
        if m ~= 0 then d = floor(d * (100 + m) / 100) end
        u.hp = u.hp - d                               -- command phase, before combat
      end
      -- Deaths, in array order, through the sim's one death path, then the
      -- deferred credits are paid: no building can die here, so every bank
      -- cap is already final (the queueCredit precondition).
      local w = 0
      for i = 1, n do
        local u = us[i]
        if u.hp <= 0 then
          INT.onUnitDeath(sm, es, sd, ln, u)
        else
          w = w + 1
          if w ~= i then us[w] = u end
        end
      end
      for i = n, w + 1, -1 do us[i] = nil end
      INT.flushCredits(sm)
      sd.mods.seCd = sm.clock + se.cooldown
      sd.cmdsExecuted = sd.cmdsExecuted + 1
    end

    local function execLeyLine(sm, sd, c)
      local ll = spec[sd.index].leyLine
      if not ll then return fizzle(sd) end
      local src, dst = c.target, c.count
      if src < 1 or src > C.LANES or dst < 1 or dst > C.LANES or src == dst then
        return fizzle(sd)
      end
      if sm.clock < sd.mods.llCd then return fizzle(sd) end
      local sl, dl = sd.lanes[src], sd.lanes[dst]
      local us = sl.units
      -- Everything of mine still in my own half, in ascending entity id
      -- (S10); each unit moves iff the destination's supply cap still has
      -- room for it at BASE cost (Q4, INTERPRETATIONS 20).
      local cand, nc = {}, 0
      for i = 1, #us do
        local u = us[i]
        if u.pos < MID then
          local j = nc
          while j >= 1 and cand[j].id > u.id do
            cand[j + 1] = cand[j]
            j = j - 1
          end
          cand[j + 1] = u
          nc = nc + 1
        end
      end
      local movedId = {}
      local moved = 0
      for i = 1, nc do
        local u = cand[i]
        local base = UNITS[u.t].cost
        if dl.supply + base <= C.LANE_SUPPLY_CAP then
          dl.supply = dl.supply + base
          sl.supply = sl.supply - base
          u.lane = dst
          dl.units[#dl.units + 1] = u
          movedId[u.id] = true
          moved = moved + 1
        end
      end
      if moved == 0 then return fizzle(sd) end        -- cooldown unconsumed
      local n = #us
      local w = 0
      for i = 1, n do
        local u = us[i]
        if not movedId[u.id] then
          w = w + 1
          if w ~= i then us[w] = u end
        end
      end
      for i = n, w + 1, -1 do us[i] = nil end
      sd.mods.llCd = sm.clock + ll.cooldown
      sd.cmdsExecuted = sd.cmdsExecuted + 1
    end

    hooks.execVerb = function(sm, sd, c)
      local idx = c.kindIdx - 300                     -- CLS_VERB * 100
      if idx == 1 then
        execInvest(sm, sd, c)
      elseif idx == 2 then
        execScorched(sm, sd, c)
      else
        execLeyLine(sm, sd, c)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- M3 PART 2 HANDOFF: the information cards' PERCEPTION effects.
--
-- The four render-only effects are named here as data so part 2 has one
-- declared surface to implement against, and so the sim side can state
-- exactly what it does NOT do. Nothing in sim/ reads this table beyond
-- hashing its cards like any others; fog/Fog.lua's EFFECTS block (part 2,
-- LIVE) consumes the OWNER'S LOADOUT plus these semantics to widen what a
-- client renders:
--
--   divination  reveals completed enemy buildings, slot and identity, never
--               HP, never under-construction. Self-announcing at tick 0.
--   omen        surfaces each enemy deploy order as its atom arrives: lane
--               and count only, never type. TEMPORAL, not spatial -- needs
--               its own channel per fog open item 16.
--   veil        suppresses the owner's buildings from every enemy source
--               except contact reveal and destruction; beats Divination and
--               the Shrine pulse absolutely. Not self-announcing.
--   shrine      (a building, not a card) reveal pulse every
--               C.SHRINE_PULSE_EVERY ticks for C.SHRINE_PULSE_TICKS.
--
-- In THIS milestone all four are no-ops by design: they change what is DRAWN,
-- the sim shares all state anyway (Ruling 1), and a fog effect implemented in
-- sim/ would violate A.5 grep 1. The sim-side existence -- id, class,
-- affinity, hashing, loadout legality, and the Shrine pulse constants in
-- Rules.C -- is complete.
-- ---------------------------------------------------------------------------

M.INFO_EFFECTS = { "divination", "omen", "veil", "shrine" }

return M
