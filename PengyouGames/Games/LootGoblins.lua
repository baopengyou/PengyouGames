-- Games/LootGoblins.lua - Loot Goblins: buy-in social deduction over addon
-- messages. Exactly one host (the starter, who also plays); clients mirror the
-- host's broadcasts. The ledger applies only at END (all-or-nothing): CANCEL,
-- host death or a local abort leaves every ledger untouched.
-- Genuine message gaps (encounter comms lockdowns, loading screens) self-heal
-- through the SYNCQ resync protocol (spec 9b): the host replays exactly the
-- ORIGINAL messages a client missed, every application is idempotent, and a
-- client that cannot prove it applied every round writes no ledger delta at all.
local ADDON, PG = ...

PG.LG = {}

local TICK = 0.5            -- master ticker period (drives all session timing)
local HB_INTERVAL = 10      -- host heartbeat cadence
local HB_TIMEOUT = 35       -- client: host is dead after this much silence
local REVEAL_SECS = 5       -- pause between RESULT and the next ROUND
local VOID_PAUSE_SECS = 3   -- pause between VOID and the next ROUND
local BEGIN_PAUSE_SECS = 2  -- pause between BEGIN and round 1
local MIN_REOPEN_SECS = 3   -- floor for the timer when re-opening a frozen round
local MAX_ROWS = 16
local MAX_GOLD = 100000 * 40 -- buy-in cap * roster cap: bound for every
                             -- pot/pay/carry/dust wire field (keeps huge/inf
                             -- out of the persisted ledger)
local SYNC_COOLDOWN = 10     -- min seconds between SYNCQ sends/serves per peer
local SYNC_MAX_REPLAY = 20   -- resync gaps larger than this get SYNCNO (spectate)

local GREEN, RED, GRAY, GOLD = "|cff40ff40", "|cffff5050", "|cffaaaaaa", "|cffffd200"

local S       -- session state; nil until the first session, phase=="done" after it
local ticker
local win, dialog, dlgInputs
local ui = {}
local rows = {}

-- Presentation layer (SKIN.md, goblin theme). Captured at init / built with
-- the window; ALL of it is decoration - game logic never branches on any of
-- these, and every Blizzard art/sound/model call routes through PG.Theme.
local Theme, TC        -- PG.Theme and the goblin palette (nil if Theme absent)
local npc              -- Grizzle, the 3D goblin host (Theme.NPC handle)
local stampPool             -- A6: up to 8 pooled red-X hoarder stamps
local sparkFrame, sparkGroup -- A9 END sparkles
-- The round/session result moment itself belongs to the shared reveal stage
-- (REVEAL.md 6.1/6.2, PG.Theme.Reveal / PG.Theme.RevealQueue), so this file
-- owns no glow/starburst/coin-shower/banner of its own for those beats.
local greetToken            -- session token the host model has greeted already
local lastNodAt, lastClinkAt = 0, 0 -- fx rate limits (join nods / pot clinks)

-- assigned below; declared here so earlier closures capture them as upvalues
local RefreshUI, ShowWindow, onTick, rowAt
local clientRequestSync, appliedThrough
local buildRevealFX, hideStamps, placeStamps, fxGreet
local fxJoined, fxBegin, fxRound, fxResult, fxVoid, fxEnd, fxPick

-- floor(a / b) for non-negative integers; exact in float math (a % b is exact
-- for integer-valued floats, so no 0.8-style rounding drift can creep in)
local function idiv(a, b) return (a - a % b) / b end

local function myName() return PG.FullName("player") end

-- wire-field validation: non-secret, numeric, floored, in [lo, hi]; else nil
local function num(v, lo, hi)
  local n = PG.SafeNum(v)
  if not n then return nil end
  n = math.floor(n)
  if lo and n < lo then return nil end
  if hi and n > hi then return nil end
  return n
end

-- Roster agreement fingerprint. RESULT patterns are positional over the sorted
-- roster and no name ever travels with an outcome, so a mirror whose roster has
-- the right SIZE but the wrong MEMBERS would credit the wrong players with no
-- error anywhere - a count comparison cannot see it. Bytes are weighted by
-- position inside a name (so anagrams differ) and names by position in the list
-- (so a swap is caught). O(roster bytes), computed only at BEGIN/SYNCQ.
local function rosterDigest(list)
  local h = 0
  for i = 1, #list do
    local name = tostring(list[i] or "")
    local s = 0
    for k = 1, #name do s = s + name:byte(k) * k end
    h = (h + i * (s % 65536)) % 65536
  end
  return string.format("%04x", h)
end

-- wire-field validation for a digest: exactly four hex digits, or reject
local function isDigest(v)
  return type(v) == "string" and v:match("^%x%x%x%x$") ~= nil
end

-- Plain combat (open world, raid trash) neither blocks addon messaging nor
-- pauses the game: the 12.1 lockdown is encounter/M+/PvP-scoped and is checked
-- separately via PG.Comm.Locked(). Only the encounter/pre-pull states pause us.
local function allClear()
  local s = PG.Safety.state
  return not (s.inEncounter or s.readyCheck or s.countdown or s.restricted)
end

local function live() return S ~= nil and S.phase ~= "done" end

-- LG toasts carry the coin mark (SKIN.md 2.8); plain text when Theme absent
local function toast(text)
  if Theme then text = Theme.Mark("coin") .. " " .. text end
  PG.UI.Toast(text)
end

-- pot amounts inside the window get the coin mark (SKIN.md 2.4)
local function tmoney(g)
  if Theme then return Theme.Money(g) end
  return PG.Money(g)
end

-- FX runner: decoration only - errors are reported and swallowed, so no
-- animation/sound/model problem can ever touch game state or the wire.
local function runFX(fn, arg)
  if not Theme or not fn then return end
  local ok, err = pcall(fn, arg)
  if not ok then geterrorhandler()(err) end
end

local function broadcast(mtype, ...)
  return PG.Comm.Broadcast("LG", mtype, S.token, ...)
end

local function startTicker()
  if ticker then ticker:Cancel() end
  ticker = PG.Ticker(TICK, function()
    local ok, err = pcall(onTick)
    if not ok then geterrorhandler()(err) end
  end)
end

local function stopTicker()
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
end

local function endSession(text)
  S.phase = "done"
  S.roundOpen = false
  S.endText = text
  stopTicker()
  if win then ui.bar:Stop() end
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Shared state transitions. The host applies these locally at send time (the
-- section-6 loopback rule); clients apply them on receipt of host broadcasts.
-------------------------------------------------------------------------------

local function applyJoined(name)
  -- normal path: the join phase. Resync replays land here too: a desynced
  -- spectator mid-play accepts the replayed JOINED/LEFT stream to repair its
  -- roster (idempotent - a duplicate JOINED never double-adds), which is what
  -- lets it map RESULT patterns to the same names as everybody else.
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if not S.joined[name] then
    S.joined[name] = true
    S.roster[#S.roster + 1] = name
    table.sort(S.roster) -- plain byte-order sort: the spec's "sorted roster"
  end
  if name == myName() and S.phase == "join" then
    S.joinAccepted = true
    ShowWindow()
    if win then ui.bar:Start(math.max(1, (S.joinDeadlineDisplay or GetTime()) - GetTime())) end
  end
  RefreshUI()
  if S.phase == "join" then runFX(fxJoined, name) end
end

local function applyLeft(name)
  -- same relaxation as applyJoined: resync replays repair a spectator roster
  if S.phase ~= "join" and not (S.phase == "play" and S.spectator) then return end
  if S.joined[name] then
    S.joined[name] = nil
    for i = #S.roster, 1, -1 do
      if S.roster[i] == name then table.remove(S.roster, i) end
    end
  end
  if name == myName() then
    S.joinAccepted = false
    if win then win:Hide() end
  end
  RefreshUI()
end

-- dig (optional): the host's roster fingerprint at BEGIN. Absent (a peer that
-- predates the field) degrades to the count-only check.
local function applyBegin(count, pot, rounds, dig)
  if S.phase ~= "join" then
    -- BEGIN while playing is ignored: totals are NEVER rebuilt once play has
    -- begun, so a replayed BEGIN can never wipe (or re-zero) applied winnings.
    -- The one exception is a client that missed BEGIN entirely (forced
    -- spectator, S.count == nil): it absorbs the original fields so resync
    -- agreement (roster count vs BEGIN count) can be evaluated at all.
    if S.phase == "play" and S.spectator and S.count == nil then
      S.count = count
      S.basePot = pot
      S.rounds = rounds
      S.digest = dig
      RefreshUI()
    end
    return
  end
  S.phase = "play"
  S.count = count
  S.basePot = pot
  S.rounds = rounds
  S.digest = dig
  S.totals = {}
  for _, n in ipairs(S.roster) do S.totals[n] = 0 end
  if not S.isHost and (#S.roster ~= count
    or (dig and rosterDigest(S.roster) ~= dig)) then
    -- our JOINED/LEFT stream disagrees with the host in size or in membership:
    -- we cannot map the pattern to names, so we spectate (and never touch the
    -- ledger) while asking the host to replay what we missed - resync can
    -- restore us. Setting spectator here is also what lets the repair land:
    -- applyJoined/applyLeft only accept replays for a spectator mid-play.
    S.spectator = true
    toast("Loot Goblins: out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxBegin)
end

local function applyRound(r, pot, secs)
  if S.phase ~= "play" then return end
  if r < S.r then return end -- stale/late resync replay: never regress the round
  if r ~= S.r then
    S.r = r
    S.myPick = nil
    S.picks = {}
  end
  -- a repeat ROUND for the current r is just a timer refresh (freeze re-open):
  -- locked picks stay locked
  S.roundPot = pot
  S.deadline = GetTime() + secs
  S.roundOpen = true
  ShowWindow()
  if win then ui.bar:Start(secs) end
  RefreshUI()
  runFX(fxRound)
end

local function applyResult(r, pattern, hoardPay, sharePay, carry)
  if S.phase ~= "play" then return end
  -- RESYNC IDEMPOTENCY, and the reason the ledger can never double-count: the
  -- END ledger delta is (session winnings - buy-in), and session winnings are
  -- accumulated here from RESULT patterns. A round whose payouts have already
  -- been applied is therefore skipped outright, no matter how often the host
  -- replays it (resync whispers reuse the ORIGINAL RESULT message).
  if S.appliedResults[r] then return end
  -- a replay of a PAST round only accumulates winnings; only a result at or
  -- ahead of the round we are in may touch the live round / reveal state
  local current = r >= S.r
  if current then
    S.roundOpen = false
    S.myPick = nil
    S.lastResult = { r = r, pattern = pattern, hoardPay = hoardPay, sharePay = sharePay, carry = carry }
  end
  local nh, ns = 0, 0
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    if c == "H" then nh = nh + 1 elseif c == "S" then ns = ns + 1 end
  end
  if #pattern == #S.roster then -- never true while our roster is desynced
    S.appliedResults[r] = true
    for i, name in ipairs(S.roster) do
      local c = pattern:sub(i, i)
      if c == "H" then
        S.totals[name] = (S.totals[name] or 0) + hoardPay
      elseif c == "S" then
        S.totals[name] = (S.totals[name] or 0) + sharePay
      end
    end
  elseif not S.isHost and not S.spectator then
    -- the pattern cannot be mapped onto our roster, so our winnings would be
    -- wrong: stop playing (and stop qualifying for the ledger) until resync
    -- repairs the roster, at which point this same RESULT is replayed
    S.spectator = true
    toast("Loot Goblins: out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if not current then
    RefreshUI()
    return -- past round: winnings banked, nothing about the live round changes
  end
  if nh + ns == 0 then
    S.lastResultText = "Round " .. r .. ": nobody picked - the whole pot carries over!"
  elseif nh > 0 and hoardPay > 0 then
    S.lastResultText = "Round " .. r .. ": " .. RED .. nh .. " hoarded " .. PG.Money(hoardPay) .. " each|r"
      .. (ns > 0 and ("; " .. ns .. " shared " .. PG.Money(sharePay) .. " each") or "")
  elseif nh > 0 then
    S.lastResultText = "Round " .. r .. ": " .. RED .. nh .. " greedy hoarders got nothing|r"
      .. (ns > 0 and ("; " .. ns .. " shared " .. PG.Money(sharePay) .. " each")
          or " - the pot carries over")
  else
    S.lastResultText = "Round " .. r .. ": everyone shared - " .. PG.Money(sharePay) .. " each"
  end
  ShowWindow()
  if win then ui.bar:Stop() end
  RefreshUI()
  if r == S.r then runFX(fxResult) end
end

local function applyVoid(r)
  if S.phase ~= "play" then return end
  -- A voided round pays nothing, so "applied" for it means "seen": the flag
  -- keeps the applied-round run contiguous across the hole a VOID leaves in
  -- the RESULT stream (rounds 1..n each end in exactly one RESULT or one
  -- VOID), and makes a replayed VOID a no-op.
  if S.appliedResults[r] then return end
  S.appliedResults[r] = true
  if r < S.r then return end -- stale replay: the live round is untouched
  S.roundOpen = false
  S.myPick = nil
  S.lastResult = nil
  S.lastResultText = "Round " .. r .. " was voided by the encounter - its pot carries over."
  ShowWindow()
  if win then ui.bar:Stop() end
  RefreshUI()
  runFX(fxVoid)
end

local function applyEnd(dustIdx, dustAmt)
  if S.phase ~= "play" then return end
  -- LEDGER INTEGRITY GATE. The ledger is written here, identically on every
  -- client, from locally accumulated winnings - so only a mirror that can
  -- prove it applied EVERY round may write it. Rounds 1..S.rounds each end in
  -- exactly one RESULT or VOID, both of which mark the round applied, so
  -- appliedThrough() == S.rounds is exactly "I missed nothing". Anyone else
  -- (spectator, or a resync that never completed) sits the ledger out rather
  -- than push totals nobody else agrees with into SavedVariables.
  if not S.isHost and not S.spectator and appliedThrough() < (S.rounds or 0) then
    S.spectator = true
    S.syncMissed = true
  end
  if not S.spectator and dustIdx >= 1 and dustAmt > 0 then
    local name = S.roster[dustIdx] -- 1-based index into the sorted roster
    if name then S.totals[name] = (S.totals[name] or 0) + dustAmt end
  end
  local me = myName()
  local myNet
  if not S.spectator then
    for _, name in ipairs(S.roster) do
      local netN = (S.totals[name] or 0) - S.buyin
      PG.Ledger.Add(name, netN, "Loot Goblins")
      if name == me then myNet = netN end
    end
  end
  S.ended = true
  local text = "Game over!"
  if myNet then
    text = "Game over - you " .. (myNet >= 0
      and ("came out +" .. PG.Money(myNet)) or ("are down " .. PG.Money(-myNet)))
  elseif S.syncMissed then
    text = "Game over - you missed part of the game, so no gold was recorded."
  elseif S.spectator then
    text = "Game over - you sat this one out (out of sync). No gold changes."
  end
  toast("Loot Goblins: " .. text)
  ShowWindow()
  endSession(text)
  runFX(fxEnd)
end

local function applyCancel(reason)
  if S.phase == "done" then return end
  local text
  if reason == "few" then
    text = "Cancelled - not enough players joined."
  elseif reason == "host" then
    text = "Cancelled by the host - no gold changes."
  else
    text = "Cancelled (" .. tostring(reason) .. ") - no gold changes."
  end
  toast("Loot Goblins: " .. text)
  endSession(text)
end

-------------------------------------------------------------------------------
-- Host logic
-------------------------------------------------------------------------------

-- Resync history: the host retains the ordered JOINED/LEFT stream, BEGIN's
-- fields and every round's exact outcome fields (RESULT verbatim, or the VOID
-- that replaced it), so a client with a genuine gap can be healed by replaying
-- precisely what it missed - see hostHandleSyncQ. Nothing is ever re-derived:
-- the replayed fields are the bytes the group already agreed on.
local function hostRecordOp(op, name)
  S.hist.ops[#S.hist.ops + 1] = { op = op, name = name }
end

local function hostRecordTop(r)
  if r > S.hist.top then S.hist.top = r end
end

local function hostStartRound(r)
  local pot = idiv(S.basePot, S.rounds) + S.carry
  if broadcast("ROUND", r, pot, S.roundSecs) then
    S.carry = 0
    applyRound(r, pot, S.roundSecs)
  else
    S.nextRoundAt = GetTime() + 2 -- send refused; the ticker retries
  end
end

local function hostAdvance(delay)
  if S.r >= S.rounds then
    S.endPending = true -- END goes out on the next clear tick
  else
    S.nextRoundAt = GetTime() + delay
  end
end

local function hostResolveRound()
  local chars = {}
  local k, h, sN = 0, 0, 0
  for i, name in ipairs(S.roster) do
    local p = S.picks[name]
    if p == "H" then
      h = h + 1
      k = k + 1
    elseif p == "S" then
      sN = sN + 1
      k = k + 1
    else
      p = "X"
    end
    chars[i] = p
  end
  local pattern = table.concat(chars)
  local pot = S.roundPot
  local hoardPay, sharePay, carryOut = 0, 0, 0
  if k == 0 then
    carryOut = pot
  elseif h == 0 then
    sharePay = idiv(pot, k) -- k == sN here
    carryOut = pot - sN * sharePay
  elseif h <= math.max(1, idiv(k, 5)) then -- floor(k * 0.2)
    if sN == 0 then
      hoardPay = idiv(pot, h) -- no sharers: hoarders split the whole round pot
      carryOut = pot - h * hoardPay
    else
      hoardPay = idiv(idiv(pot * 4, 5), h) -- floor(floor(pot * 0.8) / h)
      local remainder = pot - h * hoardPay
      sharePay = idiv(remainder, sN)
      carryOut = remainder - sN * sharePay
    end
  else
    -- too many hoarders: they get nothing
    if sN == 0 then
      carryOut = pot
    else
      sharePay = idiv(pot, sN)
      carryOut = pot - sN * sharePay
    end
  end
  local newCarry = S.carry + carryOut
  if not broadcast("RESULT", S.r, pattern, hoardPay, sharePay, newCarry) then
    return -- send refused; the ticker re-resolves next clear tick
  end
  S.carry = newCarry
  -- exact wire fields, retained verbatim for resync replays
  S.hist.results[S.r] = { pattern, hoardPay, sharePay, newCarry }
  hostRecordTop(S.r)
  applyResult(S.r, pattern, hoardPay, sharePay, newCarry)
  hostAdvance(REVEAL_SECS)
end

-- Everyone seated has locked a pick: nobody is waiting on anybody, so the
-- round resolves now instead of burning the rest of the timer. The deadline
-- stays as the fallback for anyone AFK (a missing pick is an X, as always). A
-- resynced player held out of the already-open round never completes the set,
-- so that round quietly falls back to its timer - never an early resolve that
-- would strand them.
local function allPicked()
  local n = #S.roster
  if n < 2 then return false end
  for i = 1, n do
    if not S.picks[S.roster[i]] then return false end
  end
  return true
end

-- The early-finish test, in one place: both entry points (a pick landing, and
-- a frozen round re-opening with every pick already in) use exactly the
-- ticker's deadline-branch gating - never while frozen/broken or during an
-- encounter/lockdown.
local function maybeEarlyFinish()
  if S.phase ~= "play" or not S.roundOpen or S.broken or S.frozen then return end
  if not (allPicked() and allClear() and not PG.Comm.Locked()) then return end
  hostResolveRound()
end

local function hostVoidRound()
  if broadcast("VOID", S.r) then
    S.carry = S.carry + S.roundPot
    S.hist.voids[S.r] = true -- this round leaves no RESULT: replayed as VOID
    hostRecordTop(S.r)
    S.broken = false
    S.frozen = false
    applyVoid(S.r)
    hostAdvance(VOID_PAUSE_SECS)
  end
end

local function hostReopenRound()
  local secs = math.max(MIN_REOPEN_SECS, math.ceil(S.freezeRemaining or 0))
  -- clients treat a repeat ROUND for a known r as a timer refresh
  if broadcast("ROUND", S.r, S.roundPot, secs) then
    S.frozen = false
    S.deadline = GetTime() + secs
    ShowWindow()
    if win then ui.bar:Start(secs) end
    RefreshUI()
    -- the last pick may have landed DURING the freeze, in which case there is
    -- nobody left to wait for and the re-opened timer would just burn down
    maybeEarlyFinish()
  end
end

local function hostEnd()
  if S.endSent then return end -- END is already on the wire; onSent finishes up
  local dustAmt = S.carry or 0
  local dustIdx = -1
  if dustAmt > 0 then
    -- lowest total winnings; strict < keeps the first sorted-roster entry on ties
    local bestVal
    for i, name in ipairs(S.roster) do
      local t = S.totals[name] or 0
      if bestVal == nil or t < bestVal then
        bestVal = t
        dustIdx = i
      end
    end
  end
  -- The ledger applies only once END has actually left the wire: a broadcast
  -- that is merely queued and later dropped by the lockdown aborts via onDrop
  -- with no ledger anywhere instead (all-or-nothing in every branch).
  local sess = S
  local ok = PG.Comm.BroadcastEx({
    onSent = function()
      if S ~= sess or S.phase ~= "play" then return end
      S.endPending = nil
      S.carry = 0
      applyEnd(dustIdx, dustAmt)
    end,
  }, "LG", "END", S.token, dustIdx, dustAmt)
  if ok then S.endSent = true end
end

local function hostCancel(reason)
  -- END is already on the wire: clients will write the ledger when it lands, so
  -- the host must complete too - no abort may interleave after END is queued.
  -- (endPending alone is fine: nothing has been submitted yet, so cancelling
  -- there is still all-or-nothing safe.)
  if S.endSent then return end
  -- best effort: if the broadcast is refused, clients fall back to the
  -- heartbeat timeout; either way there is no ledger effect
  broadcast("CANCEL", reason)
  applyCancel(reason)
end

local function hostCloseJoin()
  if S.phase ~= "join" then return end
  local count = #S.roster
  if count < 2 then
    if broadcast("CANCEL", "few") then
      applyCancel("few")
    else
      S.joinDeadline = GetTime() + 2 -- send refused; retry shortly
    end
    return
  end
  local pot = S.buyin * count
  local dig = rosterDigest(S.roster) -- membership, not just size (4 bytes)
  if broadcast("BEGIN", count, pot, S.rounds, dig) then
    -- BEGIN fields for replays
    S.hist.beginCount, S.hist.beginPot, S.hist.beginDigest = count, pot, dig
    applyBegin(count, pot, S.rounds, dig)
    -- seed the carry with the base pot's undistributed remainder
    -- (basePot - rounds * floor(basePot / rounds)) so the game is zero-sum:
    -- it is round 1's carryIn per "roundPot(r) = floor(basePot/rounds) + carryIn"
    S.carry = pot - S.rounds * idiv(pot, S.rounds)
    S.nextRoundAt = GetTime() + BEGIN_PAUSE_SECS
  else
    S.joinDeadline = GetTime() + 2
  end
end

local function hostHandleJoin(sender)
  if S.phase ~= "join" or S.joined[sender] then return end -- duplicate JOINs idempotent
  if broadcast("JOINED", sender) then
    hostRecordOp("J", sender)
    applyJoined(sender)
  end
end

local function hostHandleUnjoin(sender)
  if S.phase ~= "join" or sender == S.host or not S.joined[sender] then return end
  if broadcast("LEFT", sender) then
    hostRecordOp("L", sender)
    applyLeft(sender)
  end
end

local function hostHandlePick(sender, r, p)
  if S.phase ~= "play" or not S.roundOpen or S.broken then return end
  if r ~= S.r or (p ~= "S" and p ~= "H") then return end
  if not S.joined[sender] then return end
  if S.picks[sender] then return end -- first click locks
  S.picks[sender] = p
  RefreshUI()
  maybeEarlyFinish()
end

-- one replay entry; the explicit arity keeps trailing nils out of the wire
local function pushMsg(out, ...)
  local m = { ... }
  m.n = select("#", ...)
  out[#out + 1] = m
end

-- Resync: a client whispered SYNCQ (the phase it has applied, the round
-- through which it has applied every outcome, its roster count). Replay
-- whatever it missed BY WHISPER using the ORIGINAL message types and field
-- layouts - the full JOINED/LEFT stream if its roster count disagrees, BEGIN
-- if its phase trails, every missing RESULT/VOID in round order, then the live
-- ROUND with its real remaining seconds. Nothing missing -> SYNCOK; a delta
-- over SYNC_MAX_REPLAY messages -> SYNCNO (that client spectates the session
-- out, so it never writes a ledger delta).
local function hostHandleSyncQ(sender, phase, rApplied, rosterN, dig)
  if phase ~= "join" and phase ~= "play" then return end
  if not (rApplied and rosterN) then return end
  if dig ~= nil and not isDigest(dig) then return end -- malformed field: reject
  if PG.Comm.Locked() then return end -- the client retries after its cooldown
  local now = GetTime()
  local last = S.syncAsk[sender]
  if last and (now - last) < SYNC_COOLDOWN then return end -- per-sender rate limit
  S.syncAsk[sender] = now
  local out = {}
  if rosterN ~= #S.roster or (dig and dig ~= rosterDigest(S.roster)) then
    -- replay the full ordered stream: idempotent application converges any
    -- subset roster onto the host roster exactly (each name ends in the state
    -- of its last op), which is what makes the patterns mappable again. A
    -- same-size/different-membership roster is caught by the digest alone.
    for i = 1, #S.hist.ops do
      local op = S.hist.ops[i]
      pushMsg(out, (op.op == "J") and "JOINED" or "LEFT", op.name)
    end
  end
  if S.phase == "play" then
    if phase == "join" then
      -- the roster cannot change after BEGIN, so the live digest IS the BEGIN
      -- one; the fallback only covers a history that predates the field
      pushMsg(out, "BEGIN", S.hist.beginCount or S.count, S.hist.beginPot or S.basePot,
              S.rounds, S.hist.beginDigest or rosterDigest(S.roster))
    end
    for r = rApplied + 1, S.hist.top do
      local res = S.hist.results[r]
      if res then
        pushMsg(out, "RESULT", r, res[1], res[2], res[3], res[4])
      elseif S.hist.voids[r] then
        pushMsg(out, "VOID", r)
      end
    end
    if #out > 0 and S.roundOpen and not S.broken and not S.frozen and S.r >= 1 then
      local remain = math.max(1, math.ceil((S.deadline or now) - now))
      pushMsg(out, "ROUND", S.r, S.roundPot or 0, remain)
    end
  end
  if #out > SYNC_MAX_REPLAY then
    PG.Comm.Whisper(sender, "LG", "SYNCNO", S.token)
    return
  end
  if #out == 0 then
    PG.Comm.Whisper(sender, "LG", "SYNCOK", S.token)
    return
  end
  -- Replay whispers reuse CRITICAL_DROP mtypes, so onDrop cannot tell a
  -- dropped replay from a dropped live broadcast: shield it for a bounded
  -- window while the send queue drains (see REPLAYABLE) so a lockdown-dropped
  -- replay can never abort the session (and its ledger) - the asking client
  -- simply asks again after its cooldown.
  S.syncReplayUntil = now + 30
  for i = 1, #out do
    local m = out[i]
    PG.Comm.Whisper(sender, "LG", m[1], S.token, unpack(m, 2, m.n))
  end
end

local function hostOpen(buyin, rounds, joinSecs, roundSecs)
  if live() then
    toast("Loot Goblins: a game is already running.")
    return
  end
  local host = myName()
  if not host then return end
  if not IsInGroup() then
    toast("Loot Goblins needs a party or raid.")
    return
  end
  local short = host:match("^([^%-]+)") or host
  local token = short .. "-" .. math.random(10000, 99999)
  -- broadcast OPEN before constructing S: submit-time lockdown drops invoke
  -- our onDrop synchronously, which must not see a half-built live session
  if not PG.Comm.Broadcast("LG", "OPEN", token, buyin, rounds, joinSecs) then
    toast("Loot Goblins: cannot start right now (addon messages are blocked).")
    return
  end
  S = {
    token = token,
    host = host,
    isHost = true,
    buyin = buyin,
    rounds = rounds,
    joinSecs = joinSecs,
    roundSecs = roundSecs,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    picks = {},
    r = 0,
    carry = 0,
    appliedResults = {},
    hist = { ops = {}, results = {}, voids = {}, top = 0 }, -- resync replay history
    syncAsk = {}, -- per-sender SYNCQ rate limiting
    joinDeadline = GetTime() + joinSecs,
    joinDeadlineDisplay = GetTime() + joinSecs,
    lastHBSent = GetTime(),
  }
  if broadcast("JOINED", host) then
    hostRecordOp("J", host)
    applyJoined(host) -- host auto-joins
  end
  -- a sync lockdown drop of JOINED (now critical) aborts via onDrop above
  if not live() then return end
  startTicker()
  ShowWindow()
  if win then ui.bar:Start(joinSecs) end
end

-------------------------------------------------------------------------------
-- Client logic
-------------------------------------------------------------------------------

local function doPick(p)
  if not S or S.phase ~= "play" or not S.roundOpen then return end
  if S.spectator or S.myPick then return end
  if S.syncHoldR == S.r then return end -- resynced mid-round: back in NEXT round
  local me = myName()
  if not me or not S.joined[me] then return end
  if S.isHost then
    S.myPick = p
    hostHandlePick(me, S.r, p)
  else
    -- lock only if the whisper was actually accepted for send, so the UI
    -- never claims a lock the host can never have seen
    if PG.Comm.Whisper(S.host, "LG", "PICK", S.token, S.r, p) then
      S.myPick = p
    end
  end
  RefreshUI()
  if S.myPick == p then runFX(fxPick, p) end
end

local function clientOpen(token, sender, buyin, rounds, joinSecs)
  -- every addon client mirrors the session (even decliners), so the whole
  -- group applies identical ledger deltas at END
  S = {
    token = token,
    host = sender,
    isHost = false,
    buyin = buyin,
    rounds = rounds,
    joinSecs = joinSecs,
    phase = "join",
    roster = {},
    joined = {},
    totals = {},
    picks = {},
    r = 0,
    carry = 0,
    appliedResults = {},
    syncAllClear = allClear(), -- tracks all-clear transitions for resync
    lastHB = GetTime(),
    joinDeadlineDisplay = GetTime() + joinSecs,
  }
  startTicker()
  local short = sender:match("^([^%-]+)") or sender
  -- themed goblin Ask (SKIN.md 2.3): parchment look, coin-marked Accept label;
  -- plain look and labels when the Theme layer is absent
  local acceptLabel = "Buy in"
  if Theme then acceptLabel = Theme.Mark("coin") .. " Buy in" end
  PG.UI.Ask("lg-invite",
    short .. " started Loot Goblins - buy-in " .. PG.Money(buyin) .. ", "
      .. rounds .. " rounds. Buy in?",
    acceptLabel, "Pass", joinSecs,
    function()
      if S and S.token == token and S.phase == "join" then
        PG.Comm.Whisper(S.host, "LG", "JOIN", S.token)
        S.joinAccepted = true -- provisional; the host's JOINED broadcast confirms
        ShowWindow()
        if win then ui.bar:Start(math.max(1, S.joinDeadlineDisplay - GetTime())) end
      end
    end,
    nil, "goblin")
end

local function clientHostDead()
  toast("Loot Goblins: lost contact with the host - game abandoned, no gold changes.")
  endSession("Abandoned - the host stopped responding. No gold changes.")
end

-- Highest round R such that every round 1..R has been applied locally. A
-- voided round counts (it pays nothing and produces no RESULT), so this is
-- exactly "the outcomes I hold with no holes in them".
appliedThrough = function()
  if not S then return 0 end
  local r = 0
  while S.appliedResults[r + 1] do r = r + 1 end
  return r
end

-- Resync request: ask the host to replay whatever we missed (loading screens,
-- encounter comms gaps). At most one SYNCQ per SYNC_COOLDOWN; a refused or
-- cooling-down request stays pending and the ticker retries it once clear.
-- Never sent by the host, after SYNCNO, or for a finished session.
clientRequestSync = function()
  if not S or S.isHost or S.phase == "done" or S.syncDead then return end
  local now = GetTime()
  if now - (S.lastSyncQ or 0) < SYNC_COOLDOWN or PG.Comm.Locked() then
    S.syncNeeded = true
    return
  end
  -- Report the phase we have actually APPLIED, not the one we forced ourselves
  -- into: a client that never saw BEGIN (S.count == nil) flipped itself to
  -- "play" the moment a round message arrived, but it still needs BEGIN
  -- replayed - that is the message carrying the roster count we must agree on.
  local phase = S.count and "play" or "join"
  -- the digest rides along so the host can spot a same-size/wrong-membership
  -- roster, which a count comparison alone can never see
  if PG.Comm.Whisper(S.host, "LG", "SYNCQ", S.token, phase, appliedThrough(),
                     #S.roster, rosterDigest(S.roster)) then
    S.lastSyncQ = now
    S.syncNeeded = false
  else
    S.syncNeeded = true
  end
end

-- A resynced spectator rejoins once its mirror agrees with the host again:
-- roster count matches BEGIN's count and every completed round is applied. It
-- plays from the NEXT round (syncHoldR blocks the round already open at heal
-- time) and never scores retroactively - the replayed patterns carry X for
-- every round it missed, worth nothing. Its winnings are therefore identical
-- to everyone else's, which is what makes it safe to write the END ledger.
local function maybeClearSpectator()
  if not S or S.isHost or not S.spectator or S.syncDead then return end
  if S.phase ~= "play" or not S.count then return end
  if #S.roster ~= S.count then return end
  -- size agreement is not membership agreement: without this a spectator heals
  -- onto a same-count/wrong-member roster and writes the ledger for the wrong
  -- players - the very bug the digest exists to catch, one hop later
  if S.digest and rosterDigest(S.roster) ~= S.digest then return end
  local need = S.roundOpen and (S.r - 1) or S.r
  if need < 0 then need = 0 end
  if appliedThrough() < need then return end
  S.spectator = false
  if S.roundOpen and S.r >= 1 then S.syncHoldR = S.r end
  toast("Loot Goblins: back in sync - you are back in the game.")
  RefreshUI()
end

-------------------------------------------------------------------------------
-- Comm routing
-------------------------------------------------------------------------------

local function onComm(mtype, token, sender, f1, f2, f3, f4, f5)
  if mtype == "OPEN" then
    if live() then
      toast("Loot Goblins: " .. sender .. " tried to start a game, but one is already running.")
      return
    end
    local buyin = num(f1, 1, 100000)
    local rounds = num(f2, 1, 20)
    local joinSecs = num(f3, 5, 600)
    if not (buyin and rounds and joinSecs) then return end
    if type(token) ~= "string" or token == "" then return end
    clientOpen(token, sender, buyin, rounds, joinSecs)
    return
  end
  if not S or S.phase == "done" or token ~= S.token then return end
  if S.isHost then
    if mtype == "JOIN" then
      hostHandleJoin(sender)
    elseif mtype == "UNJOIN" then
      hostHandleUnjoin(sender)
    elseif mtype == "PICK" then
      hostHandlePick(sender, num(f1, 1, 20), PG.SafeStr(f2))
    elseif mtype == "SYNCQ" then
      hostHandleSyncQ(sender, PG.SafeStr(f1), num(f2, 0, 20), num(f3, 0, 40),
                      PG.SafeStr(f4))
    end
    return
  end
  if sender ~= S.host then return end -- only the host may drive the session
  S.lastHB = GetTime() -- any host traffic counts as a heartbeat
  if S.phase == "join"
    and (mtype == "ROUND" or mtype == "RESULT" or mtype == "VOID" or mtype == "END") then
    -- we missed BEGIN entirely: spectate for now (no ledger) and ask the host
    -- to replay what we missed - resync can fully restore us (roster stream +
    -- BEGIN + outcomes), unlike the old permanent sit-out
    S.phase = "play"
    S.spectator = true
    toast("Loot Goblins: out of sync with the host - resyncing...")
    clientRequestSync()
  end
  if mtype == "HB" then
    return
  elseif mtype == "JOINED" then
    local name = PG.SafeStr(f1)
    if name and name ~= "" then applyJoined(name) end
  elseif mtype == "LEFT" then
    local name = PG.SafeStr(f1)
    if name and name ~= "" then applyLeft(name) end
  elseif mtype == "BEGIN" then
    local count = num(f1, 2, 40)
    local pot = num(f2, 0, MAX_GOLD)
    local rounds = num(f3, 1, 20)
    -- optional trailing field: absent means a peer without it (count-only
    -- check, exactly as before); present but malformed drops the message
    local dig = PG.SafeStr(f4)
    if count and pot and rounds and (dig == nil or isDigest(dig)) then
      applyBegin(count, pot, rounds, dig)
    end
  elseif mtype == "CANCEL" then
    applyCancel(PG.SafeStr(f1) or "?")
  elseif mtype == "ROUND" then
    local r = num(f1, 1, 20)
    local pot = num(f2, 0, MAX_GOLD)
    local secs = num(f3, 1, 600)
    if r and pot and secs then
      if r > S.r + 1 then clientRequestSync() end -- unexpected round: we missed traffic
      applyRound(r, pot, secs)
    end
  elseif mtype == "RESULT" then
    local r = num(f1, 1, 20)
    local pattern = PG.SafeStr(f2)
    local hoardPay = num(f3, 0, MAX_GOLD)
    local sharePay = num(f4, 0, MAX_GOLD)
    local carry = num(f5, 0, MAX_GOLD)
    if r and pattern and pattern ~= "" and hoardPay and sharePay and carry then
      if r > S.r then clientRequestSync() end -- result for a round we never saw open
      applyResult(r, pattern, hoardPay, sharePay, carry)
    end
  elseif mtype == "VOID" then
    local r = num(f1, 1, 20)
    if r then applyVoid(r) end
  elseif mtype == "END" then
    local dustIdx = num(f1, -1, 40)
    local dustAmt = num(f2, 0, MAX_GOLD)
    if dustIdx and dustAmt then applyEnd(dustIdx, dustAmt) end
  elseif mtype == "SYNCOK" then
    S.syncNeeded = false -- host confirms we missed nothing
  elseif mtype == "SYNCNO" then
    -- the delta is too large to replay: spectator locks for this session, so
    -- this client sits out both the picks and the END ledger
    if not S.syncDead then
      S.syncDead = true
      S.syncNeeded = false
      if not S.spectator then
        S.spectator = true
        toast("Loot Goblins: too far out of sync to catch up - spectating this game.")
      end
      RefreshUI()
    end
  end
  maybeClearSpectator()
end

-- An OUTGOING message of ours was permanently dropped by the comms lockdown.
-- For the host, losing a state-bearing broadcast desyncs every client with no
-- legal way to repair it mid-lockdown, so the session dies locally with no
-- ledger effect; clients notice via the 35s heartbeat timeout (all-or-nothing
-- holds). This only happens in the rare queued-then-lockdown race: normal
-- interruptions are handled by the freeze/VOID flow before anything is sent.
-- JOINED/LEFT are critical too: a lost roster broadcast leaves the host with
-- a roster no client shares, so BEGIN's count check would lock every client
-- to spectator and END would apply the ledger on the host alone. The sync
-- messages (SYNCQ/SYNCOK/SYNCNO) are deliberately NOT critical: a dropped one
-- just means the client asks again after its cooldown.
local CRITICAL_DROP = {
  OPEN = true, JOINED = true, LEFT = true, BEGIN = true,
  ROUND = true, RESULT = true, VOID = true, END = true,
}

-- Resync replay whispers reuse the original mtypes above, so onDrop cannot
-- tell a dropped replay whisper from a dropped live broadcast. While a replay
-- may still be draining from the send queue (the syncReplayUntil window) a
-- drop of one of these must NOT abort the game and its pending ledger: the
-- asking client simply retries, and even a live broadcast lost in that window
-- now self-heals through the same resync path once the lockdown clears.
local REPLAYABLE = {
  JOINED = true, LEFT = true, BEGIN = true, RESULT = true, VOID = true, ROUND = true,
}

local function onDrop(mtype)
  if not (S and S.isHost and live()) then return end
  if not CRITICAL_DROP[mtype] then return end
  if REPLAYABLE[mtype] and S.syncReplayUntil and GetTime() < S.syncReplayUntil then return end
  toast("Loot Goblins: game aborted - addon messages were blocked mid-send. No gold changes.")
  endSession("Aborted - addon messages were blocked. No gold changes.")
end

-------------------------------------------------------------------------------
-- Safety transitions. Encounter/restriction breaks the open round (VOID once
-- clear); ready check / countdown merely freezes its timer. Plain combat does
-- NOTHING: messaging stays legal there, so the game just keeps running.
-- Resumption is driven by the ticker once every flag is clear again; clients
-- that missed traffic during a genuine gap ask the host to replay it (SYNCQ).
-------------------------------------------------------------------------------

local function onSafetyChange(state, trigger)
  if not live() then return end
  -- plain combat neither freezes the round nor discards picks, and it can
  -- never change allClear() (so no resync bookkeeping is missed by returning
  -- here); without this every trash pull would churn the round
  if trigger == "COMBAT_ON" or trigger == "COMBAT_OFF" then return end
  local isOn = trigger:match("_ON$") ~= nil
  if not S.isHost then
    if trigger == "ENCOUNTER_ON" then
      S.myPick = nil -- discard pending pick state; the host will void this round
    end
    -- resync trigger: the session just emerged from a safety interruption
    -- (allClear() transitioned false -> true), which is exactly where messages
    -- go missing; ask the host what we missed
    local cur = allClear()
    if cur and S.syncAllClear == false then S.syncNeeded = true end
    S.syncAllClear = cur
    return
  end
  if not isOn then return end
  if S.phase == "join" then
    if not S.joinFrozen then
      S.joinFrozen = true
      S.joinRemaining = math.max(0, (S.joinDeadline or GetTime()) - GetTime())
    end
  elseif S.phase == "play" and S.roundOpen then
    if trigger == "ENCOUNTER_ON" or trigger == "RESTRICT_ON" then
      S.broken = true -- this round is dead; VOID goes out after the encounter
      S.frozen = false
    elseif not S.broken and not S.frozen then
      S.frozen = true
      S.freezeRemaining = math.max(0, (S.deadline or GetTime()) - GetTime())
    end
  end
end

-------------------------------------------------------------------------------
-- Master ticker: host timing (join window, round deadline, void/reopen/end
-- retries, heartbeat) and the client-side host-death watchdog.
-------------------------------------------------------------------------------

onTick = function()
  if not S or S.phase == "done" then return end
  local now = GetTime()
  if S.isHost then
    if not IsInGroup() then
      toast("Loot Goblins: you left the group - game abandoned, no gold changes.")
      endSession("Abandoned - you left the group. No gold changes.")
      return
    end
    if now - (S.lastHBSent or 0) >= HB_INTERVAL and not PG.Comm.Locked() then
      if broadcast("HB", S.phase, S.r) then S.lastHBSent = now end
    end
    if S.phase == "join" then
      if S.joinFrozen then
        if allClear() then
          S.joinFrozen = false
          S.joinDeadline = now + (S.joinRemaining or 0)
          S.joinDeadlineDisplay = S.joinDeadline
        end
      elseif now >= (S.joinDeadline or 0) then
        hostCloseJoin()
      end
    elseif S.phase == "play" then
      if S.broken then
        if allClear() and not PG.Comm.Locked() then hostVoidRound() end
      elseif S.frozen then
        if allClear() and not PG.Comm.Locked() then hostReopenRound() end
      elseif S.endPending then
        if allClear() and not PG.Comm.Locked() then hostEnd() end
      elseif S.roundOpen then
        if now >= (S.deadline or 0) and not PG.Comm.Locked() then hostResolveRound() end
      elseif S.nextRoundAt and now >= S.nextRoundAt and allClear() and not PG.Comm.Locked() then
        S.nextRoundAt = nil
        hostStartRound(S.r + 1)
      end
    end
  else
    local st = PG.Safety.state
    if st.inEncounter or st.restricted or PG.Comm.Locked() then
      -- the host cannot legally heartbeat here (encounter, or the M+/PvP
      -- comms lockdown, or the pre-activation restriction window): suspend
      -- the watchdog instead of declaring the host dead
      S.lastHB = (S.lastHB or now) + TICK
    elseif now - (S.lastHB or now) > HB_TIMEOUT then
      clientHostDead()
      return
    end
    -- pending resync request (cooling down, or a refused send): retry once clear
    if S.syncNeeded and allClear() then clientRequestSync() end
  end
  if win and win:IsShown() then RefreshUI() end
end

-------------------------------------------------------------------------------
-- Reveal FX and goblin reactions (SKIN.md 2.4/2.5, choreography table 3).
-- Pure decoration: groups are built ONCE with the window and replayed via
-- Restart; every group/region is registered into the Theme OnHide contract so
-- a Safety hide Stop()s and hides everything instantly. Text state is always
-- final BEFORE any of this plays - a player with all FX failed loses nothing.
--
-- Round and session results are presented by the SHARED REVEAL STAGE
-- (REVEAL.md 6.1/6.2): fxResult builds a payload and hands it to Theme.Reveal
-- (per-round - a missed one is superseded by the next round, so it is dropped
-- rather than replayed), fxEnd hands its podium to Theme.RevealQueue (it must
-- eventually show, so it waits out an encounter/ready-check instead). The
-- stage self-gates on all five Safety flags, plays only over a shown window,
-- and never touches game state: every string below is read from state the
-- appliers already settled, and nothing here writes anything.
-------------------------------------------------------------------------------

-- guarded AnimationGroup primitives (decor only; nil on failure)
local function newGroup(region)
  local ok, g = pcall(region.CreateAnimationGroup, region)
  if ok and g then return g end
  return nil
end

local function newAnim(g, kind)
  local ok, a = pcall(g.CreateAnimation, g, kind)
  if ok and a then return a end
  return nil
end

local function setScaleRange(a, fx, fy, tx, ty)
  if not a then return end
  if pcall(a.SetScaleFrom, a, fx, fy) then
    pcall(a.SetScaleTo, a, tx, ty)
  else
    pcall(a.SetFromScale, a, fx, fy)
    pcall(a.SetToScale, a, tx, ty)
  end
end

local function setAlphaRange(a, from, to)
  if not a then return end
  pcall(a.SetFromAlpha, a, from)
  pcall(a.SetToAlpha, a, to)
end

local function restartGroup(g)
  if not g then return end
  if not pcall(g.Restart, g) then
    pcall(g.Stop, g)
    pcall(g.Play, g)
  end
end

-- Builds the A6 stamp pool and the A9 END sparkles. Called once from
-- ensureWindow after the chest (win.__pgFXOrigin) exists. The A3 glow, A4
-- starburst and A5 coin shower are NOT built here any more: the shared reveal
-- stage owns the result moment (REVEAL.md 7) and would only cover them.
buildRevealFX = function()
  if not Theme or not win then return end
  local fx = win.__pgFX or win
  local origin = win.__pgFXOrigin or win

  -- A6 hoarder stamps: pool of 8 red X marks. Without the atlas there is no
  -- fallback texture - the LOSS-colored "HOARD +x" annotation carries meaning.
  if Theme.Mark("redx") ~= "" then
    stampPool = {}
    for i = 1, 8 do
      local t = fx:CreateTexture(nil, "OVERLAY")
      t:SetSize(26, 26)
      Theme.Tex(t, "redx")
      pcall(t.SetRotation, t, -0.14)
      t:Hide()
      local g = newGroup(t)
      if g then
        local sc = newAnim(g, "Scale")
        if sc then
          setScaleRange(sc, 2.2, 2.2, 1, 1)
          sc:SetDuration(0.18)
          sc:SetOrder(1)
          pcall(sc.SetSmoothing, sc, "IN")
          pcall(sc.SetStartDelay, sc, 0.06 * (i - 1)) -- stagger baked at build
        end
        local al = newAnim(g, "Alpha")
        if al then
          setAlphaRange(al, 0, 1)
          al:SetDuration(0.12)
          al:SetOrder(1)
          pcall(al.SetStartDelay, al, 0.06 * (i - 1))
        end
        pcall(g.SetToFinalAlpha, g, true) -- the stamp persists after the slam
        Theme.RegisterGroup(win, g)
      end
      Theme.RegisterRegion(win, t)
      stampPool[i] = { tex = t, group = g }
    end
  end

  -- A9 END sparkles: two stars in one bouncing frame; a 4 s gen-checked
  -- timer stops the loop (and OnHide Stop always can)
  local okS, sf = pcall(CreateFrame, "Frame", nil, fx)
  if okS and sf then
    sf:SetSize(64, 64)
    sf:SetPoint("CENTER", origin, "CENTER", 0, 0)
    local t1 = sf:CreateTexture(nil, "OVERLAY")
    t1:SetSize(20, 20)
    t1:SetPoint("CENTER", origin, "TOPLEFT", 2, -2)
    Theme.Tex(t1, "star")
    pcall(t1.SetBlendMode, t1, "ADD")
    local t2 = sf:CreateTexture(nil, "OVERLAY")
    t2:SetSize(20, 20)
    t2:SetPoint("CENTER", origin, "BOTTOMRIGHT", -2, 2)
    Theme.Tex(t2, "star")
    pcall(t2.SetBlendMode, t2, "ADD")
    local g = newGroup(sf)
    if g then
      local a = newAnim(g, "Alpha")
      if a then
        setAlphaRange(a, 0.15, 0.75)
        a:SetDuration(0.5)
        a:SetOrder(1)
        pcall(a.SetSmoothing, a, "IN_OUT")
      end
      pcall(g.SetLooping, g, "BOUNCE")
      Theme.RegisterGroup(win, g)
      sparkGroup = g
    end
    Theme.RegisterRegion(win, sf)
    sf:Hide()
    sparkFrame = sf
  end
end

hideStamps = function()
  if not stampPool then return end
  for i = 1, #stampPool do
    local sp = stampPool[i]
    if sp.group then pcall(sp.group.Stop, sp.group) end
    sp.tex:Hide()
  end
end

placeStamps = function(pattern)
  if not stampPool or not win then return end
  hideStamps()
  local limit = #pattern
  if limit > MAX_ROWS then limit = MAX_ROWS - 1 end -- last row is "... and more"
  local used = 0
  for i = 1, limit do
    if pattern:sub(i, i) == "H" then
      used = used + 1
      if used > #stampPool then break end -- hoarders 9+: text-only LOSS color
      local sp = stampPool[used]
      sp.tex:ClearAllPoints()
      sp.tex:SetPoint("CENTER", rowAt(i), "LEFT", -2, 0)
      if sp.group then
        sp.tex:SetAlpha(0) -- invisible through the stagger; the slam raises it
        sp.tex:Show()
        restartGroup(sp.group)
      else
        sp.tex:SetAlpha(1)
        sp.tex:Show()
      end
    end
  end
end

-- Window first shows for a session: wave hello (once per token). Also clears
-- stamps a re-used window may still be showing from the previous session.
fxGreet = function()
  hideStamps()
  if npc then npc:Emote("greet") end
  Theme.Sound("greet")
end

-- Join phase: nod + chest pulse per join (1/s), coin clink for others (1/2s),
-- lock-in confirmation for self.
fxJoined = function(name)
  if not (win and win:IsShown()) then return end
  local now = GetTime()
  if now - lastNodAt >= 1 then
    lastNodAt = now
    if npc then npc:Emote("nod") end
    if ui.chest then Theme.Pulse(ui.chest) end
  end
  if name == myName() then
    Theme.Sound("coinlock")
  elseif now - lastClinkAt >= 2 then
    lastClinkAt = now
    Theme.Sound("potclink")
  end
end

-- Buy-in closes: banner + stamp sound + the goblin gets excited.
fxBegin = function()
  if not (win and win:IsShown()) then return end
  Theme.Banner(win, "BUY-IN CLOSED", "goblin")
  Theme.Sound("stamp")
  Theme.After(win, 0.2, function()
    if npc then npc:Emote("excited") end
  end)
end

-- Round opens: stale stamps go, the goblin talks up the round (loops).
fxRound = function()
  if not (win and win:IsShown()) then return end
  hideStamps()
  if npc then npc:Emote("talk") end
end

-- Local pick locked: button pop + nod. Never touches the timer bar or text.
fxPick = function(p)
  if not (win and win:IsShown()) then return end
  local btn = (p == "S") and ui.shareBtn or ui.hoardBtn
  if btn then Theme.Pulse(btn) end
  if npc then npc:Emote("nod") end
  Theme.Sound("click")
end

-- "Name-Realm" -> "Name" for the tight marquee line (names never contain "-";
-- realms do). Purely cosmetic: rows keep the full name the roster shows.
local function shortOf(full)
  full = tostring(full or "?")
  return full:match("^([^%-]+)") or full
end

-- The stage shows 9 result rows plus a "... and N more" line once a payload
-- carries more than 10 (REVEAL.md 2.3), which on a 20-man roster can swallow
-- the local player's row - and "your delta emphasized" is the point of it.
-- Move that one row up into the last visible slot; everyone else keeps their
-- relative order and the collapse line still counts the same rows.
local RV_VISIBLE = 9

local function hoistPersonal(list)
  if #list <= RV_VISIBLE + 1 then return list end -- all rows fit as they are
  for i = RV_VISIBLE + 1, #list do
    if list[i].personal then
      table.insert(list, RV_VISIBLE, table.remove(list, i))
      return list
    end
  end
  return list
end

-- Per-player payout rows for the round reveal, in roster order. Empty whenever
-- the pattern cannot be mapped onto our roster (spectator / desync) - exactly
-- the case where RefreshUI also refuses to annotate the roster, so the stage
-- shows the headline alone rather than invent payouts nobody agrees with.
local function resultRows(lr)
  local list = {}
  if S.spectator or #lr.pattern ~= #S.roster then return list end
  local me = myName()
  for i, name in ipairs(S.roster) do
    local c = lr.pattern:sub(i, i)
    local row
    if c == "H" then
      row = { text = name .. "  HOARD +" .. PG.Money(lr.hoardPay), role = "loss" }
    elseif c == "S" then
      row = { text = name .. "  share +" .. PG.Money(lr.sharePay), role = "win" }
    else
      row = { text = name .. "  no pick", role = "fade" }
    end
    row.personal = (name == me)
    list[#list + 1] = row
  end
  return hoistPersonal(list)
end

-- The money moment (SKIN.md 2.5, REVEAL.md 6.1). Timeline zero = RefreshUI has
-- already set every final string; the stage decorates, never precedes, the
-- information. Reveal (not RevealQueue): a round result that could not play is
-- superseded by the next round, and a late replay would be a lie.
fxResult = function()
  if not (win and win:IsShown() and S and S.lastResult) then return end
  local lr = S.lastResult
  local nh, ns = 0, 0
  for i = 1, #lr.pattern do
    local ch = lr.pattern:sub(i, i)
    if ch == "H" then nh = nh + 1 elseif ch == "S" then ns = ns + 1 end
  end
  -- t=0.1: red stamps still slam onto the hoarder rows. They are the one
  -- reveal artifact that OUTLIVES the stage - the roster keeps its marks after
  -- the scrim fades - and they land even when the stage declines to play.
  if nh > 0 and not S.spectator and #lr.pattern == #S.roster then
    local pattern = lr.pattern
    Theme.After(win, 0.1, function() placeStamps(pattern) end)
  end
  -- the headline the banner used to carry, now the stage's slam title
  local title
  if nh > 0 and lr.hoardPay == 0 then
    title = "GREED PUNISHED"
  elseif nh == 0 and ns > 0 then
    title = "EVERYONE SHARED"
  else
    title = "ROUND " .. lr.r
  end
  local paid = (lr.hoardPay > 0 or lr.sharePay > 0)
  Theme.Reveal({
    theme = "goblin",
    anchor = { mode = "window", host = win },
    title = title,
    subtitle = "Round " .. lr.r .. " of " .. (S.rounds or "?") .. " - pot "
      .. PG.Money(S.roundPot or 0),
    rows = resultRows(lr),
    marquee = (nh > 0)
      and (nh .. (nh == 1 and " HOARDER EXPOSED" or " HOARDERS EXPOSED")) or nil,
    -- same coin budget the A5 shower used: 10 on a share payout, 6 on a
    -- hoard-only payout, none when the whole pot carried over
    burst = paid and "coins" or "none",
    burstCount = (lr.sharePay > 0) and 10 or 6,
    -- sounds are default-off and self-gated inside Theme.Sound
    sound = paid and "coins" or nil,
    burstSound = (nh > 0 and lr.hoardPay > 0) and "laugh"
      or ((nh == 0 and lr.sharePay > 0) and "settled" or nil),
    npc = npc,
    -- nobody picked -> he asks; any hoarder (rich or busted) amuses him; he
    -- only golf-claps for a clean share
    emote = (nh + ns == 0) and "ask" or ((nh > 0) and "laugh" or "applaud"),
  })
end

-- Round voided by an encounter: red VOIDED stamp, no celebration.
fxVoid = function()
  if not (win and win:IsShown()) then return end
  hideStamps()
  Theme.Stamp(win, "VOIDED")
  Theme.Sound("coincancel")
  Theme.After(win, 0.2, function()
    if npc then npc:Emote("ask") end
  end)
end

-- Final standings for the podium: the roster ranked by net winnings desc, then
-- name asc, read straight out of the totals the window already displays. Rank
-- numbers are part of the row text so a hoisted personal row stays honest.
-- Returns the row list, the leader's name and the leader's net.
local function endRows()
  local order, net = {}, {}
  for i, name in ipairs(S.roster) do
    order[i] = name
    net[name] = (S.totals[name] or 0) - (S.buyin or 0)
  end
  table.sort(order, function(a, b)
    if net[a] ~= net[b] then return net[a] > net[b] end
    return a < b
  end)
  local me = myName()
  local list = {}
  for i = 1, #order do
    local name = order[i]
    local n = net[name]
    local role
    if i == 1 then role = "gold"
    elseif i == 2 then role = "silver"
    elseif i == 3 then role = "bronze"
    else role = (n >= 0) and "win" or "loss" end
    list[i] = {
      text = i .. ". " .. name .. "  net "
        .. ((n >= 0) and ("+" .. PG.Money(n)) or ("-" .. PG.Money(-n))),
      role = role,
      place = (i <= 3) and i or nil,
      personal = (name == me),
    }
  end
  return hoistPersonal(list), order[1], net[order[1]]
end

-- Session end (REVEAL.md 6.2): sparkles in the window, and the podium of net
-- winnings on the stage. RevealQueue, not Reveal: the final result must
-- eventually show, so it waits out an encounter/ready-check rather than being
-- dropped - and its validate culls it if this session is gone by then.
fxEnd = function()
  if not (win and win:IsShown() and S) then return end
  -- A9 sparkles stay in the window: they are its own end-state decoration and
  -- the one celebration that still plays while the podium is held back. They
  -- start after the stage's longest possible life (podium 4.80 s) instead of at
  -- 0.4 s, where they used to play entirely underneath its 0.85 scrim and were
  -- over before it faded. Theme.After is gen-checked, so a hide in between
  -- simply drops them.
  Theme.After(win, 5.2, function()
    if sparkFrame and sparkGroup then
      sparkFrame:Show()
      restartGroup(sparkGroup)
      Theme.After(win, 4, function()
        pcall(sparkGroup.Stop, sparkGroup)
        sparkFrame:Hide()
      end)
    end
  end)
  -- a spectator's totals are exactly the ones nobody agreed on (that is why it
  -- wrote no ledger), so it gets no podium - its window text says so instead
  if S.spectator then return end
  local list, topName, topNet = endRows()
  if not list[1] then return end
  local bigWin = S.basePot ~= nil and topNet >= S.basePot / 2
  local sess = S
  Theme.RevealQueue({
    theme = "goblin",
    anchor = { mode = "window", host = win },
    variant = "podium",
    title = "FINAL RESULTS",
    subtitle = #S.roster .. " goblins - pot " .. PG.Money(S.basePot or 0),
    rows = list,
    -- nets always sum to zero, so a top net of 0 means the pot came back out
    -- exactly as it went in - nobody to crown
    marquee = (topNet > 0) and (shortOf(topName) .. " TAKES THE HOARD")
      or "NOBODY BEAT THE BUY-IN",
    burst = "coins",
    burstCount = 12,
    sound = "coins",
    burstSound = "fanfare",
    npc = npc,
    emote = bigWin and "dance" or "cheer",
    validate = function() return S == sess and sess.ended == true end,
  })
end

-------------------------------------------------------------------------------
-- Game window
-------------------------------------------------------------------------------

rowAt = function(i)
  if not rows[i] then
    local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 26, -286 - (i - 1) * 17)
    fs:SetWidth(388)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if TC then fs:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end
    rows[i] = fs
  end
  return rows[i]
end

local function ensureWindow()
  if win then return end
  win = PG.UI.Window("lg", "Loot Goblins", 440, 620, "goblin")
  -- Safety auto-resume: come back after an encounter/ready-check/countdown,
  -- but never resurrect for a session that has since died.
  win.__pgResume = function() return S ~= nil end

  -- Title ribbon (decor; failure -> plain title, today's look)
  if Theme then
    local ribbon = win:CreateTexture(nil, "ARTWORK", nil, -6)
    if Theme.Tex(ribbon, "ribbon") then
      ribbon:SetSize(320, 40)
      ribbon:SetPoint("TOP", 0, -10)
      win.title:ClearAllPoints()
      win.title:SetPoint("CENTER", ribbon, "CENTER", 0, 2)
      Theme.Shadow(win.title) -- title now sits on ribbon art
    else
      ribbon:Hide()
      -- no ribbon art: the Skin-applied GOLD title would sit straight on the
      -- parchment overlay (~1.6:1, illegible; SKIN.md 6.1) - recolor to INK
      if TC then win.title:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end
    end
  end

  -- Treasure chest in a fixed 56x56 slot (art may fall back to a coin icon;
  -- layout never depends on which rendered) - also the origin every coin
  -- shower, glow, and sparkle anchors to.
  if Theme then
    ui.chest = Theme.Icon(win, "chest", 56)
    ui.chest:SetPoint("TOPLEFT", 24, -50)
    win.__pgFXOrigin = ui.chest
  end

  ui.info = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  -- 3-line money column: the ~200px between chest and goblin model cannot fit
  -- the one-line join string, which ellipsized the pot (the headline number).
  -- RefreshUI leads with the pot on its own short line; wrap-within-48px
  -- guards the rare overlong case (huge pots, 3-digit rosters).
  ui.info:SetPoint("TOPLEFT", 88, -48)
  ui.info:SetPoint("TOPRIGHT", -150, -48)
  ui.info:SetHeight(48)
  ui.info:SetJustifyH("LEFT")
  ui.info:SetJustifyV("TOP")
  ui.info:SetWordWrap(true)
  ui.info:SetMaxLines(3)
  if TC then ui.info:SetTextColor(TC.AMBER[1], TC.AMBER[2], TC.AMBER[3]) end

  ui.bar = PG.UI.TimerBar(win, 260)
  ui.bar:SetPoint("TOPLEFT", 24, -112)

  -- Grizzle the Pit Boss: 3D goblin host, reacts to the game (pure decor;
  -- Theme.NPC falls back to a static coin-pile icon in the same container)
  if Theme then
    npc = Theme.NPC(win, "host")
    npc.frame:SetPoint("TOPRIGHT", -18, -44)
    ui.plate = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.plate:SetPoint("TOP", npc.frame, "BOTTOM", 0, 1)
    ui.plate:SetText("Grizzle the Pit Boss")
    if TC then ui.plate:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end
  end

  ui.shareBtn = PG.UI.CardButton(win, "SHARE", 190, 46, function() doPick("S") end)
  ui.shareBtn:SetPoint("TOPLEFT", 24, -206)
  ui.hoardBtn = PG.UI.CardButton(win, "HOARD", 190, 46, function() doPick("H") end)
  ui.hoardBtn:SetPoint("TOPRIGHT", -24, -206)
  ui.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  ui.status:SetPoint("TOPLEFT", 24, -262)
  ui.status:SetPoint("TOPRIGHT", -24, -262)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(false)
  if TC then ui.status:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end
  ui.mine = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ui.mine:SetPoint("BOTTOMLEFT", 24, 46)
  ui.mine:SetPoint("BOTTOMRIGHT", -24, 46)
  ui.mine:SetJustifyH("LEFT")
  ui.mine:SetWordWrap(false)
  if TC then ui.mine:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end
  ui.startBtn = PG.UI.Button(win, "Start now", 105, 22, function()
    if S and S.isHost and S.phase == "join" then hostCloseJoin() end
  end)
  ui.startBtn:SetPoint("BOTTOMLEFT", 20, 16)
  ui.cancelBtn = PG.UI.Button(win, "Cancel game", 105, 22, function()
    if S and S.isHost and live() then hostCancel("host") end
  end)
  ui.cancelBtn:SetPoint("BOTTOMRIGHT", -20, 16)
  ui.withdrawBtn = PG.UI.Button(win, "Withdraw", 105, 22, function()
    if S and not S.isHost and S.phase == "join" and S.joinAccepted then
      if Theme then Theme.Sound("coincancel") end
      PG.Comm.Whisper(S.host, "LG", "UNJOIN", S.token)
    end
  end)
  ui.withdrawBtn:SetPoint("BOTTOMLEFT", 20, 16) -- shares the host-only Start slot
  ui.ledgerBtn = PG.UI.Button(win, "Open Ledger", 120, 22, function()
    if PG.Ledger and PG.Ledger.Show then PG.Ledger.Show() end
  end)
  ui.ledgerBtn:SetPoint("BOTTOM", 0, 16)

  if Theme then
    -- gold-pile decor behind the bottom buttons (above the parchment sheet,
    -- which sits at ARTWORK sublayer -8); hidden entirely if the art fails
    local pile = win:CreateTexture(nil, "ARTWORK", nil, -7)
    pile:SetSize(220, 48)
    pile:SetPoint("BOTTOM", 0, 10)
    pile:SetAlpha(0.35)
    if not Theme.Tex(pile, "goldpile") then pile:Hide() end

    win.__pgBannerSlot = rowAt(1) -- banners slide in over the roster area
    buildRevealFX()

    -- farewell bark: manual close of a FINISHED session only. Safety hides
    -- always arrive with a flag set, so allClear() filters every auto path
    -- (and Theme.Sound re-applies the same gates plus the default-off pref).
    win:HookScript("OnHide", function()
      if S and S.phase == "done" and S.ended and allClear() then
        Theme.Sound("farewell")
      end
    end)
  end
end

RefreshUI = function()
  if not win or not S then return end
  local now = GetTime()
  local me = myName()
  local isJoin = S.phase == "join"
  local isPlay = S.phase == "play"
  local isDone = S.phase == "done"
  local inRoster = (me and S.joined[me]) and true or false

  -- explicit |n breaks keep each line inside the ~200px column, pot first
  if isJoin then
    ui.info:SetText("Pot " .. tmoney(S.buyin * #S.roster) .. "|nBuy-in "
      .. PG.Money(S.buyin) .. " - " .. #S.roster .. " in|n" .. S.rounds .. " rounds")
  elseif isPlay then
    if S.r >= 1 then
      ui.info:SetText("Round " .. S.r .. "/" .. S.rounds .. "|nround pot "
        .. tmoney(S.roundPot or 0))
    else
      ui.info:SetText("Pot " .. tmoney(S.basePot or 0) .. "|n" .. #S.roster
        .. " goblins - buy-in closed")
    end
  else
    ui.info:SetText(S.endText or "Game over.")
  end

  local status
  if isJoin then
    if S.isHost then
      local remaining = S.joinFrozen and (S.joinRemaining or 0)
        or math.max(0, (S.joinDeadline or now) - now)
      status = #S.roster .. " joined - buy-in closes in " .. math.ceil(remaining) .. "s"
        .. (S.joinFrozen and " (paused)" or "")
    else
      status = #S.roster .. " joined - waiting for the host to start"
    end
  elseif isPlay then
    if S.spectator then
      status = S.syncDead and "Spectating - too far out of sync to catch up."
        or "Spectating - out of sync, resyncing with the host..."
    elseif S.roundOpen then
      if S.isHost then
        local k = 0
        for _ in pairs(S.picks) do k = k + 1 end
        status = k .. "/" .. #S.roster .. " picked"
        if S.myPick then
          status = status .. " - you locked " .. (S.myPick == "S" and "SHARE" or "HOARD")
        end
      elseif S.myPick then
        status = "You locked " .. (S.myPick == "S" and "SHARE" or "HOARD") .. " - waiting for the reveal"
      elseif S.syncHoldR == S.r and inRoster then
        status = "Back in sync - you are back in from the next round."
      elseif inRoster then
        status = "Make your pick: SHARE the pot, or HOARD it for yourself!"
      else
        status = "Watching this one."
      end
    else
      status = S.lastResultText or "Next round starting soon..."
    end
  else
    status = S.lastResultText or ""
  end
  ui.status:SetText(status)

  local lines = {}
  if S.spectator and not isJoin then
    lines[1] = GRAY .. "Out of sync - results are shown in the status line only.|r"
  elseif isJoin then
    for _, name in ipairs(S.roster) do
      lines[#lines + 1] = name .. (name == me and (GOLD .. " (you)|r") or "")
    end
    if not lines[1] then lines[1] = GRAY .. "Nobody has bought in yet.|r" end
  else
    local lr = S.lastResult
    local annotate = lr and #lr.pattern == #S.roster
    for i, name in ipairs(S.roster) do
      local ann = ""
      if annotate then
        local c = lr.pattern:sub(i, i)
        if c == "H" then
          ann = RED .. "  HOARD +" .. PG.Money(lr.hoardPay) .. "|r"
        elseif c == "S" then
          ann = GREEN .. "  share +" .. PG.Money(lr.sharePay) .. "|r"
        else
          ann = GRAY .. "  no pick|r"
        end
      end
      local total = S.totals[name] or 0
      local line = name .. (name == me and (GOLD .. " (you)|r") or "") .. ann
        .. "  -  " .. PG.Money(total)
      if isDone and S.ended then
        local netN = total - S.buyin
        line = line .. "  (" .. (netN >= 0 and (GREEN .. "+" .. PG.Money(netN))
          or (RED .. "-" .. PG.Money(-netN))) .. "|r)"
      end
      lines[#lines + 1] = line
    end
  end
  local shown = math.min(#lines, MAX_ROWS)
  if #lines > MAX_ROWS then
    lines[MAX_ROWS] = GRAY .. "... and " .. (#lines - MAX_ROWS + 1) .. " more|r"
  end
  for i = 1, shown do
    rowAt(i):SetText(lines[i])
    rowAt(i):Show()
  end
  for i = shown + 1, #rows do rows[i]:Hide() end

  if S.spectator then
    ui.mine:SetText(GRAY .. "No stake this game (spectating).|r")
  elseif inRoster then
    if isJoin then
      ui.mine:SetText("You are in for " .. GOLD .. PG.Money(S.buyin) .. "|r.")
    else
      local won = S.totals[me] or 0
      local netN = won - S.buyin
      ui.mine:SetText("Your winnings: " .. GOLD .. PG.Money(won) .. "|r  (net "
        .. (netN >= 0 and (GREEN .. "+" .. PG.Money(netN))
            or (RED .. "-" .. PG.Money(-netN))) .. "|r)")
    end
  else
    ui.mine:SetText(GRAY .. "You have no stake in this game.|r")
  end

  ui.shareBtn:SetShown(isPlay and not S.spectator)
  ui.hoardBtn:SetShown(isPlay and not S.spectator)
  local canPick = (isPlay and S.roundOpen and inRoster and not S.myPick and not S.spectator
    and S.syncHoldR ~= S.r) and true or false
  ui.shareBtn:SetEnabled(canPick)
  ui.hoardBtn:SetEnabled(canPick)
  ui.startBtn:SetShown(isJoin and S.isHost)
  -- no live Cancel button while END is queued or sent: hostCancel refuses there
  -- (the ledger is already committed to), so the affordance would silently lie
  ui.cancelBtn:SetShown(S.isHost and not isDone
    and not (S.endPending or S.endSent))
  ui.withdrawBtn:SetShown((isJoin and not S.isHost and S.joinAccepted) and true or false)
  ui.ledgerBtn:SetShown((isDone and S.ended) and true or false)
end

ShowWindow = function()
  if not S then return end
  if not (S.isHost or S.joinAccepted) then return end -- mirrors stay windowless
  local st = PG.Safety.state
  if st.inEncounter or st.readyCheck or st.countdown or st.restricted then return end
  -- plain combat hides the window only when the user opted in (Settings)
  if st.inCombat and PG.db and PG.db.profile and PG.db.profile.hideInCombat then return end
  ensureWindow()
  RefreshUI()
  win:Show()
  -- first show for this session: the host waves hello (once per token)
  if Theme and greetToken ~= S.token then
    greetToken = S.token
    runFX(fxGreet)
  end
end

-------------------------------------------------------------------------------
-- Host config dialog
-------------------------------------------------------------------------------

local function makeField(parent, label, y, default)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("TOPLEFT", 20, y)
  fs:SetText(label)
  if TC then fs:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end -- ink on parchment
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(70, 20)
  eb:SetPoint("TOPRIGHT", -24, y + 2)
  eb:SetAutoFocus(false)
  eb:SetNumeric(true)
  eb:SetMaxLetters(6)
  eb:SetText(tostring(default))
  eb:SetCursorPosition(0)
  eb.default = default
  return eb
end

local function fieldValue(eb, lo, hi)
  local n = math.floor(tonumber(eb:GetText()) or eb.default)
  if n < lo then n = lo elseif n > hi then n = hi end
  eb:SetText(tostring(n))
  return n
end

local function ensureDialog()
  if dialog then return end
  dialog = PG.UI.Window("lgdialog", "Start Loot Goblins", 320, 270, "goblin")
  -- gold crown header behind the title (decor; failure keeps the plain title)
  if Theme then
    local header = dialog:CreateTexture(nil, "ARTWORK", nil, -6)
    if Theme.Tex(header, "goldheader") then
      header:SetSize(300, 64)
      header:SetPoint("TOP", 0, 12)
      dialog.title:ClearAllPoints()
      dialog.title:SetPoint("TOP", header, "TOP", 0, -14)
      Theme.Shadow(dialog.title) -- title sits on the gold header art
    else
      header:Hide()
      -- no header art: GOLD-on-parchment is illegible (SKIN.md 6.1); use INK
      if TC then dialog.title:SetTextColor(TC.INK[1], TC.INK[2], TC.INK[3]) end
    end
  end
  dlgInputs = {
    buyin = makeField(dialog, "Buy-in (gold)", -60, 100),
    rounds = makeField(dialog, "Rounds", -90, 5),
    joinSecs = makeField(dialog, "Join window (sec)", -120, 45),
    roundSecs = makeField(dialog, "Round timer (sec)", -150, 20),
  }
  local openLabel = "Open buy-in"
  if Theme then openLabel = Theme.Mark("coin") .. " Open buy-in" end
  local openBtn = PG.UI.Button(dialog, openLabel, 150, 26, function()
    local buyin = fieldValue(dlgInputs.buyin, 1, 100000)
    local rounds = fieldValue(dlgInputs.rounds, 1, 20)
    local joinSecs = fieldValue(dlgInputs.joinSecs, 10, 300)
    local roundSecs = fieldValue(dlgInputs.roundSecs, 10, 60)
    if Theme then Theme.Sound("stamp") end
    dialog:Hide()
    hostOpen(buyin, rounds, joinSecs, roundSecs)
  end)
  openBtn:SetPoint("BOTTOM", 0, 18)
end

-- Launcher / slash entry point: host config dialog (or the running game).
function PG.LG.OpenDialog()
  if live() then
    toast("Loot Goblins: a game is already running.")
    ShowWindow()
    return
  end
  if not IsInGroup() then
    toast("Loot Goblins needs a party or raid.")
    return
  end
  ensureDialog()
  dialog:Show()
end

PG.RegisterInit(function()
  -- capture the skin layer once (SKIN.md 1.1/5.8): parchment-safe inline
  -- colors replace the bright defaults; everything degrades to the plain
  -- look when Theme is absent. Presentation only - no logic depends on it.
  if PG.Theme and PG.Theme.C then
    Theme = PG.Theme
    TC = Theme.C("goblin")
    GREEN, RED, GRAY, GOLD = TC.win, TC.loss, TC.fade, TC.amber
  end
  PG.Comm.Register("LG", onComm, onDrop)
  PG.Safety.OnChange(onSafetyChange)
end)
