-- net/Wire.lua -- the A.11 wire format, encode and decode. M4.
--
-- WHAT THIS FILE IS. The codec for every in-match message in A.11.3, over the
-- shipped envelope `<WIRE_VERSION>|IB|<mtype>|<token>|<payload>`, with the
-- 6-byte command atom of A.11.2 (base-36 EEE exec tick; K case-sensitive per
-- the 2026-08-12 ruling -- CASE IS THE NAMESPACE, uppercase targets a lane and
-- lowercase targets a slot; never lower() an incoming kind) and the 5-byte
-- prologue `<tick 3><ackThru 2>` that every in-match message carries.
--
-- WHAT IT IS NOT. It is not the transport (net/Transport.lua) and not the
-- reliability shim (net/Net.lua): nothing here retries, acks, or holds state
-- beyond the constant tables built at load. Encode returns a string; decode
-- returns a table or nil-plus-reason. DECODE NEVER RAISES on wire input: a
-- malformed message from a peer must be rejected, not crash the client.
--
-- WIRE ROWS COVERED. S C H X K G N M Q V -- the full in-match table. The shim
-- (net/Net.lua) drives S/C/H/N/M/Q; X/K/G/V are encoded and decoded here so
-- M6 inherits a tested codec, but no M4 code path sends them. OPEN and JOIN
-- are pre-match matchmaking rows with no prologue and are DEFERRED TO M5
-- entirely -- they carry the shipped games' own payload shapes, which belong
-- to the addon layer this directory must not reach into.
--
-- TRUNCATION, stated once here because A.11.3 fixes the field widths:
--   stateHash  5 base-36 chars = low 5 digits of the 31-bit hash (mod 36^5)
--   logDigest  4 chars                                           (mod 36^4)
--   epoch      1 char  = absolute epoch mod 36; the prologue tick recovers
--                        the absolute epoch (floor(tick / SNAPSHOT_EPOCH)),
--                        and the mod-36 char is checked against it
-- Encode takes the FULL integers and truncates; decode returns the truncated
-- values. Comparing truncations is what two real clients can do; the M4 gate
-- separately compares full 31-bit traces, which is strictly stronger.
--
-- BUDGETS. Every encode asserts the result is inside MSG_BUDGET (200); the
-- transport separately hard-errors above 255. The largest message this file
-- can construct is a C batch of 8 atoms at 70 bytes (A.11.3's own worst row).
--
-- DETERMINISM. Held to the sim's rules: integers only, no pairs, no clock, no
-- string.format/tostring on anything (numbers are rendered digit by digit
-- through the base-36 table, the same way sim/Hash.lua renders).

local IB_SIM_MODULES = rawget(_G, "IB_SIM_MODULES")
local Rules = IB_SIM_MODULES and IB_SIM_MODULES.Rules or require("sim.Rules")
local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")

local floor = math.floor
local ssub = string.sub
local sbyte = string.byte
local sfind = string.find

local M = {}

-- The shipped envelope version (dev/README: wire v4). M5 binds this to the
-- addon's real constant; until then it is one hashless character of framing.
M.WIRE_VERSION = "4"
M.MODULE = "IB"

M.MSG_BUDGET = 200   -- A.11.3's target; nothing here may construct past it
M.MSG_HARD = 255     -- the channel's hard limit, enforced by the transport

M.PROTO = 1          -- IBPROTO, the battle wire-layout version (A.11.1)

-- Field capacities, from the widths in A.11.1/A.11.3.
local B36_2 = 36 * 36                  -- 1296:  seq, ackThru, from, to
local B36_3 = 36 * 36 * 36             -- 46656: ticks
local B36_4 = B36_2 * B36_2            -- logDigest truncation
local B36_5 = B36_4 * 36               -- stateHash truncation
local B36_6 = B36_5 * 36               -- rulesHash (full 31 bits fit)
M.MAX_SEQ = B36_2 - 1
M.MAX_TICK = B36_3 - 1
M.MAX_SEED = B36_4 - 1
M.DIGEST_MOD = B36_4
M.HASH_MOD = B36_5

M.MAX_BATCH = 8      -- atoms per C message (A.11.3: 28..70 bytes)

-- ---------------------------------------------------------------------------
-- base-36 field arithmetic (the payload alphabet, deliberately excluding "|")
-- ---------------------------------------------------------------------------

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local CHARVAL = {}
for i = 1, 36 do
  CHARVAL[sbyte(B36, i)] = i - 1
end

-- Render v as exactly `width` base-36 chars. v must already be inside range;
-- every caller masks first. Digit-by-digit, no tostring, no format.
local function b36enc(v, width)
  local out = ""
  for _ = 1, width do
    local d = v % 36
    out = ssub(B36, d + 1, d + 1) .. out
    v = floor(v / 36)
  end
  return out
end

-- Parse exactly `width` chars of s starting at i. Returns value or nil.
local function b36dec(s, i, width)
  local v = 0
  for k = i, i + width - 1 do
    local c = CHARVAL[sbyte(s, k)]
    if c == nil then return nil end
    v = v * 36 + c
  end
  return v
end

-- Decimal rendering for error strings (never for wire content). Same digit
-- walk sim/Hash.lua uses, so no tostring touches a number anywhere here.
local function dec(v)
  if v < 0 then return "-" .. dec(-v) end
  if v == 0 then return "0" end
  local out = ""
  while v > 0 do
    local d = v % 10
    out = ssub(B36, d + 1, d + 1) .. out
    v = floor(v / 10)
  end
  return out
end
M.dec = dec

-- ---------------------------------------------------------------------------
-- kind letters. Derived from the hashed ruleset tables, never hand-written
-- (the same argument as Rules.UNIT_BY_KIND: a drifted copy maps a letter to
-- the wrong verb on one build only). Case-sensitive: the tables are consulted
-- with the raw character, and no case folding exists in this file.
-- ---------------------------------------------------------------------------

-- kind -> "lane" | "slot" (what the T field means, per the A.11.2 ruling)
local KIND_TARGET = {}
for i = 1, #Rules.UNITS do
  KIND_TARGET[Rules.UNITS[i].kind] = "lane"
end
KIND_TARGET["I"] = "lane"
KIND_TARGET["E"] = "lane"
KIND_TARGET["L"] = "lane"
for i = 1, #Rules.BUILDINGS do
  KIND_TARGET[Rules.BUILDINGS[i].letter] = "slot"
end

M.KIND_TARGET = KIND_TARGET

-- ---------------------------------------------------------------------------
-- the envelope
-- ---------------------------------------------------------------------------

-- The per-match token, in the CONCURRENCY.md 3.2 shape (2 chars, dash,
-- 3 chars). Derived from the seed so both endpoints of an M4 match construct
-- the identical token with no extra exchange; M5 replaces this derivation
-- with the session's real token and nothing else in the codec moves.
function M.token(seed)
  local h = Hash.int(Hash.new(), seed)
  local t = b36enc(h % B36_5, 5)
  return ssub(t, 1, 2) .. "-" .. ssub(t, 3, 5)
end

local function envelope(mtype, token, payload)
  local msg = M.WIRE_VERSION .. "|" .. M.MODULE .. "|" .. mtype .. "|" .. token .. "|" .. payload
  if #msg > M.MSG_BUDGET then
    -- A construction-time guarantee, not a transport check: nothing in this
    -- codec may ever build a message outside A.11.3's own table.
    error("Wire: constructed a " .. dec(#msg) .. "-byte message, over the "
      .. dec(M.MSG_BUDGET) .. "-byte budget (" .. mtype .. ")")
  end
  return msg
end

local function prologue(tick, ackThru)
  return b36enc(tick % B36_3, 3) .. b36enc(ackThru % B36_2, 2)
end

-- ---------------------------------------------------------------------------
-- encode. One function per A.11.3 row. Field ranges are asserted loudly:
-- an out-of-range field is OUR bug (the peer never sees it), so unlike decode
-- these raise.
-- ---------------------------------------------------------------------------

local function checkRange(name, v, lo, hi)
  if type(v) ~= "number" or floor(v) ~= v or v < lo or v > hi then
    local got = (type(v) == "number" and floor(v) == v) and dec(v) or "non-integer"
    error("Wire: " .. name .. " out of range: " .. got
      .. " not in [" .. dec(lo) .. ", " .. dec(hi) .. "]")
  end
end

-- S start (A.11.1): proto 1, seed 4, rulesHash 6, matchTicks 3, loadout 10
-- (5 ids x 2 chars), flags 1. No prologue: S precedes the match clock.
function M.encodeS(token, t)
  checkRange("S.seed", t.seed, 0, M.MAX_SEED)
  checkRange("S.rulesHash", t.rulesHash, 0, B36_6 - 1)
  checkRange("S.matchTicks", t.matchTicks, 1, M.MAX_TICK)
  local lo = ""
  for i = 1, 5 do
    local id = t.loadout[i] or 0
    checkRange("S.loadout", id, 0, B36_2 - 1)
    lo = lo .. b36enc(id, 2)
  end
  local payload = b36enc(t.proto or M.PROTO, 1) .. b36enc(t.seed, 4)
    .. b36enc(t.rulesHash, 6) .. b36enc(t.matchTicks, 3) .. lo
    .. b36enc(t.flags or 0, 1)
  return envelope("S", token, payload)
end

-- C command batch: prologue, seq 2 (the FIRST atom's seq; the batch is a
-- consecutive run seq..seq+n-1), n 1, then n 6-char atoms EEE K T N.
function M.encodeC(token, t)
  checkRange("C.tick", t.tick, 0, M.MAX_TICK)
  checkRange("C.ackThru", t.ackThru, 0, M.MAX_SEQ)
  checkRange("C.seq", t.seq, 1, M.MAX_SEQ)
  local atoms = t.atoms
  local n = #atoms
  if n < 1 or n > M.MAX_BATCH then
    error("Wire: C batch of " .. dec(n) .. " atoms (must be 1.." .. dec(M.MAX_BATCH) .. ")")
  end
  local body = ""
  for i = 1, n do
    local a = atoms[i]
    checkRange("atom.exec", a.exec, 0, M.MAX_TICK)
    local tt = KIND_TARGET[a.kind]
    if tt == nil then
      error("Wire: atom kind " .. a.kind .. " is not a wire letter")
    end
    if tt == "lane" then
      checkRange("atom.target(lane)", a.target, 1, Rules.C.LANES)
    else
      checkRange("atom.target(slot)", a.target, 1, Rules.C.SLOTS)
    end
    checkRange("atom.count", a.count, 1, 35)
    body = body .. b36enc(a.exec, 3) .. a.kind .. b36enc(a.target, 1) .. b36enc(a.count, 1)
  end
  return envelope("C", token, prologue(t.tick, t.ackThru) .. b36enc(t.seq, 2) .. b36enc(n, 1) .. body)
end

-- H heartbeat: prologue, lastSeq 2, epoch 1 (mod 36), stateHash 5, logDigest 4.
function M.encodeH(token, t)
  checkRange("H.tick", t.tick, 0, M.MAX_TICK)
  checkRange("H.ackThru", t.ackThru, 0, M.MAX_SEQ)
  checkRange("H.lastSeq", t.lastSeq, 0, M.MAX_SEQ)
  checkRange("H.epoch", t.epoch, 0, M.MAX_TICK)
  checkRange("H.stateHash", t.stateHash, 0, Hash.MOD - 1)
  checkRange("H.logDigest", t.logDigest, 0, Hash.MOD - 1)
  local payload = prologue(t.tick, t.ackThru) .. b36enc(t.lastSeq, 2)
    .. b36enc(t.epoch % 36, 1) .. b36enc(t.stateHash % B36_5, 5)
    .. b36enc(t.logDigest % B36_4, 4)
  return envelope("H", token, payload)
end

-- N resend request: prologue, from 2, to 2 (an inclusive seq range).
function M.encodeN(token, t)
  checkRange("N.tick", t.tick, 0, M.MAX_TICK)
  checkRange("N.ackThru", t.ackThru, 0, M.MAX_SEQ)
  checkRange("N.from", t.from, 1, M.MAX_SEQ)
  checkRange("N.to", t.to, t.from, M.MAX_SEQ)
  return envelope("N", token, prologue(t.tick, t.ackThru) .. b36enc(t.from, 2) .. b36enc(t.to, 2))
end

-- M mismatch: prologue, epoch 1, stateHash 5, logDigest 4.
function M.encodeM(token, t)
  checkRange("M.tick", t.tick, 0, M.MAX_TICK)
  checkRange("M.ackThru", t.ackThru, 0, M.MAX_SEQ)
  checkRange("M.epoch", t.epoch, 0, M.MAX_TICK)
  checkRange("M.stateHash", t.stateHash, 0, Hash.MOD - 1)
  checkRange("M.logDigest", t.logDigest, 0, Hash.MOD - 1)
  local payload = prologue(t.tick, t.ackThru) .. b36enc(t.epoch % 36, 1)
    .. b36enc(t.stateHash % B36_5, 5) .. b36enc(t.logDigest % B36_4, 4)
  return envelope("M", token, payload)
end

-- Q full-log request: prologue only.
function M.encodeQ(token, t)
  checkRange("Q.tick", t.tick, 0, M.MAX_TICK)
  checkRange("Q.ackThru", t.ackThru, 0, M.MAX_SEQ)
  return envelope("Q", token, prologue(t.tick, t.ackThru))
end

-- X halt: prologue + reason letter. K clear: prologue only. G resume (host
-- only): prologue + resumeTick 3. V void: prologue + reason letter. Encoded
-- and decoded so M6 inherits a tested codec; NO M4 code path sends them.
-- The X letters are A.6's own halt-reason table verbatim. A.12 names only
-- one void cause (the SYNCNO equivalent); the V set here is a PLACEHOLDER
-- alphabet for M6 to own, kept small so an unknown letter still rejects.
local HALT_REASONS = "RCYELZDMP"
local VOID_REASONS = "RDQMV"

local function letterIn(set, ch)
  return ch ~= nil and #ch == 1 and sfind(set, ch, 1, true) ~= nil
end

function M.encodeX(token, t)
  checkRange("X.tick", t.tick, 0, M.MAX_TICK)
  checkRange("X.ackThru", t.ackThru, 0, M.MAX_SEQ)
  if not letterIn(HALT_REASONS, t.reason) then error("Wire: X reason must be one of " .. HALT_REASONS) end
  return envelope("X", token, prologue(t.tick, t.ackThru) .. t.reason)
end

function M.encodeK(token, t)
  checkRange("K.tick", t.tick, 0, M.MAX_TICK)
  checkRange("K.ackThru", t.ackThru, 0, M.MAX_SEQ)
  return envelope("K", token, prologue(t.tick, t.ackThru))
end

function M.encodeG(token, t)
  checkRange("G.tick", t.tick, 0, M.MAX_TICK)
  checkRange("G.ackThru", t.ackThru, 0, M.MAX_SEQ)
  checkRange("G.resumeTick", t.resumeTick, 0, M.MAX_TICK)
  return envelope("G", token, prologue(t.tick, t.ackThru) .. b36enc(t.resumeTick, 3))
end

function M.encodeV(token, t)
  checkRange("V.tick", t.tick, 0, M.MAX_TICK)
  checkRange("V.ackThru", t.ackThru, 0, M.MAX_SEQ)
  if not letterIn(VOID_REASONS, t.reason) then error("Wire: V reason must be one of " .. VOID_REASONS) end
  return envelope("V", token, prologue(t.tick, t.ackThru) .. t.reason)
end

-- ---------------------------------------------------------------------------
-- decode. Returns (msg) or (nil, reason). NEVER raises on wire input; the
-- codec selftest proves that under pcall over structured and random garbage.
--
-- Strictness: the STRUCTURE is validated here (framing, widths, alphabet,
-- kind letters, target ranges the wire itself defines); SEMANTIC legality --
-- can this order be paid for, is that slot occupied, is the count over the
-- UI's 9 -- is the sim's job at the exec tick (A.4), because both clients
-- must reach that verdict from shared state, not each from its own decoder.
-- ---------------------------------------------------------------------------

-- Fixed payload lengths per type (C is variable and handled separately).
local PAYLOAD_LEN = { S = 25, H = 17, N = 9, M = 15, Q = 5, X = 6, K = 5, G = 8, V = 6 }

function M.decode(msg)
  if type(msg) ~= "string" then return nil, "not a string" end
  if #msg > M.MSG_HARD then return nil, "over the 255-byte hard limit" end
  if #msg < 10 then return nil, "too short to be a message" end

  -- Envelope: version | IB | mtype | token | payload. Payload may itself
  -- never contain "|" (the alphabet excludes it), so exactly 4 pipes.
  local p1 = sfind(msg, "|", 1, true)
  if not p1 then return nil, "no envelope separator" end
  local p2 = sfind(msg, "|", p1 + 1, true)
  if not p2 then return nil, "truncated envelope" end
  local p3 = sfind(msg, "|", p2 + 1, true)
  if not p3 then return nil, "truncated envelope" end
  local p4 = sfind(msg, "|", p3 + 1, true)
  if not p4 then return nil, "truncated envelope" end
  if sfind(msg, "|", p4 + 1, true) then return nil, "separator inside payload" end

  if ssub(msg, 1, p1 - 1) ~= M.WIRE_VERSION then return nil, "wrong wire version" end
  if ssub(msg, p1 + 1, p2 - 1) ~= M.MODULE then return nil, "not an IB message" end
  local mtype = ssub(msg, p2 + 1, p3 - 1)
  if #mtype ~= 1 then return nil, "mtype must be one letter" end
  local token = ssub(msg, p3 + 1, p4 - 1)
  if #token ~= 6 or ssub(token, 3, 3) ~= "-" then return nil, "malformed token" end
  if b36dec(token, 1, 2) == nil or b36dec(token, 4, 3) == nil then return nil, "malformed token" end
  local payload = ssub(msg, p4 + 1)

  if mtype == "C" then
    local n = #payload
    if n < 8 + 6 then return nil, "C payload too short" end
    if (n - 8) % 6 ~= 0 then return nil, "C payload not on the atom grid" end
    local tick = b36dec(payload, 1, 3)
    local ackThru = b36dec(payload, 4, 2)
    local seq = b36dec(payload, 6, 2)
    local count = b36dec(payload, 8, 1)
    if tick == nil or ackThru == nil or seq == nil or count == nil then
      return nil, "C header not base-36"
    end
    if seq < 1 then return nil, "C seq 0" end
    if count < 1 or count > M.MAX_BATCH then return nil, "C atom count outside 1..8" end
    if n ~= 8 + 6 * count then return nil, "C atom count disagrees with length" end
    local atoms = {}
    local at = 9
    for i = 1, count do
      local exec = b36dec(payload, at, 3)
      local kind = ssub(payload, at + 3, at + 3)
      local target = b36dec(payload, at + 4, 1)
      local cnt = b36dec(payload, at + 5, 1)
      if exec == nil or target == nil or cnt == nil then return nil, "atom not base-36" end
      local tt = KIND_TARGET[kind]   -- case-sensitive lookup; never folded
      if tt == nil then return nil, "unknown kind letter" end
      if tt == "lane" then
        if target < 1 or target > Rules.C.LANES then return nil, "lane target off the board" end
      else
        if target < 1 or target > Rules.C.SLOTS then return nil, "slot target off the board" end
      end
      if cnt < 1 then return nil, "atom count 0" end
      atoms[i] = { exec = exec, kind = kind, target = target, count = cnt, seq = seq + i - 1 }
      at = at + 6
    end
    if seq + count - 1 > M.MAX_SEQ then return nil, "C batch runs past the seq space" end
    return { mtype = "C", token = token, tick = tick, ackThru = ackThru,
             seq = seq, atoms = atoms }
  end

  local want = PAYLOAD_LEN[mtype]
  if want == nil then return nil, "unknown message type" end
  if #payload ~= want then return nil, "wrong payload length for " .. mtype end

  if mtype == "S" then
    local proto = b36dec(payload, 1, 1)
    local seed = b36dec(payload, 2, 4)
    local rulesHash = b36dec(payload, 6, 6)
    local matchTicks = b36dec(payload, 12, 3)
    local flags = b36dec(payload, 25, 1)
    if proto == nil or seed == nil or rulesHash == nil or matchTicks == nil or flags == nil then
      return nil, "S fields not base-36"
    end
    local loadout = {}
    for i = 1, 5 do
      local id = b36dec(payload, 15 + (i - 1) * 2, 2)
      if id == nil then return nil, "S loadout not base-36" end
      loadout[i] = id
    end
    return { mtype = "S", token = token, proto = proto, seed = seed,
             rulesHash = rulesHash, matchTicks = matchTicks, loadout = loadout, flags = flags }
  end

  -- Every remaining type opens with the prologue.
  local tick = b36dec(payload, 1, 3)
  local ackThru = b36dec(payload, 4, 2)
  if tick == nil or ackThru == nil then return nil, "prologue not base-36" end

  if mtype == "H" or mtype == "M" then
    local at = (mtype == "H") and 8 or 6
    local lastSeq = nil
    if mtype == "H" then
      lastSeq = b36dec(payload, 6, 2)
      if lastSeq == nil then return nil, "H lastSeq not base-36" end
    end
    local epoch = b36dec(payload, at, 1)
    local stateHash = b36dec(payload, at + 1, 5)
    local logDigest = b36dec(payload, at + 6, 4)
    if epoch == nil or stateHash == nil or logDigest == nil then
      return nil, mtype .. " fields not base-36"
    end
    return { mtype = mtype, token = token, tick = tick, ackThru = ackThru,
             lastSeq = lastSeq, epoch = epoch, stateHash = stateHash, logDigest = logDigest }
  end

  if mtype == "N" then
    local from = b36dec(payload, 6, 2)
    local to = b36dec(payload, 8, 2)
    if from == nil or to == nil then return nil, "N range not base-36" end
    if from < 1 or to < from then return nil, "N range inverted" end
    return { mtype = "N", token = token, tick = tick, ackThru = ackThru, from = from, to = to }
  end

  if mtype == "Q" or mtype == "K" then
    return { mtype = mtype, token = token, tick = tick, ackThru = ackThru }
  end

  if mtype == "X" or mtype == "V" then
    local reason = ssub(payload, 6, 6)
    local set = (mtype == "X") and HALT_REASONS or VOID_REASONS
    if not letterIn(set, reason) then return nil, mtype .. " reason letter unknown" end
    return { mtype = mtype, token = token, tick = tick, ackThru = ackThru, reason = reason }
  end

  -- G resume
  local resumeTick = b36dec(payload, 6, 3)
  if resumeTick == nil then return nil, "G resumeTick not base-36" end
  return { mtype = "G", token = token, tick = tick, ackThru = ackThru, resumeTick = resumeTick }
end

-- Registration tail (M5): hands this module to IB_SIM_MODULES when the addon
-- created it (WoW discards a chunk's return value); headless it does not
-- exist and nothing here runs. Full argument in sim/Hash.lua's tail.
local IB_REG = rawget(_G, "IB_SIM_MODULES")
if IB_REG then IB_REG.Wire = M end

return M
