-- Rand.lua -- the simulation's own integer PRNG.
--
-- WHY NOT math.random
-- math.random and math.randomseed use a different algorithm in almost every Lua
-- release (5.1 defers to C rand(), 5.4 uses xoshiro256**), so two clients on
-- different Lua builds would produce different sequences from the same seed and
-- desync. Determinism rule 3 forbids both outright. This module is the
-- replacement: an explicit LCG whose entire state and arithmetic are integral.
--
-- WHY AN LCG AND NOT XORSHIFT
-- Lua 5.1 has no bitwise operators, so xorshift cannot be expressed portably.
-- A multiplicative congruential step masked with % is exact in both number
-- models provided every product stays under 2^53:
--   A * (2^32 - 1) + C = 1664525 * 4294967295 + 1013904223
--                      = 7149081450614098, below 2^53 = 9007199254740992
--
-- LOW BITS ARE WEAK in any power-of-two LCG, so no caller ever sees them: every
-- public draw is built from the high 16 bits of one or more steps.
--
-- SCOPE NOTE (Q5): the shipped v1.0 ruleset consumes no randomness at all -- every
-- modifier was reworded to be deterministic, which deletes a whole desync class.
-- This module exists because (a) the handshake reserves a 4-char seed field for a
-- future system, (b) the M1 harness needs a portable generator to build the 1000
-- randomised command logs, and (c) if a future card ever does want RNG, this is
-- the only generator it is allowed to use. Its state is part of the hashed sim
-- state, so an accidental extra draw on one client shows up as a desync
-- immediately instead of silently.

local M = {}

local floor = math.floor

local MASK32 = 4294967296  -- 2^32
local A = 1664525
local C = 1013904223

M.MASK32 = MASK32

-- Create a generator. `seed` may be any integer; it is folded into range.
function M.new(seed)
  local s = seed or 0
  s = s % MASK32
  -- Avoid the all-zero state producing a visibly patterned first draw.
  s = (s + 2463534242) % MASK32
  return { s = s }
end

function M.clone(r)
  return { s = r.s }
end

-- One raw state step. Not for direct use as a random number: the low bits of
-- a power-of-two LCG have short periods.
function M.step(r)
  local s = (A * r.s + C) % MASK32
  r.s = s
  return s
end

-- High 16 bits of one step. Uniform over [0, 65535].
function M.next16(r)
  return floor(M.step(r) / 65536)
end

-- 32 bits assembled from two steps' high halves. Uniform over [0, 2^32 - 1].
function M.next32(r)
  local hi = M.next16(r)
  local lo = M.next16(r)
  return hi * 65536 + lo
end

-- Uniform integer in [lo, hi] inclusive. lo and hi must be integers, lo <= hi.
-- Modulo bias is bounded by n / 2^32 and is irrelevant for the ranges this is
-- used with (lane indices, unit kinds, tick offsets); it is deliberately NOT
-- rejection sampled, because a rejection loop consumes a variable number of
-- draws and that makes a log harder to reason about.
function M.range(r, lo, hi)
  local n = hi - lo + 1
  return lo + (M.next32(r) % n)
end

-- ---------------------------------------------------------------------------
-- Self-test. Known seed, known sequence. If this ever fails, the generator has
-- been changed and every recorded match log is invalidated.
-- The expected values were produced by this implementation and verified to be
-- identical when computed with pure double arithmetic and with 64-bit integer
-- arithmetic.
-- ---------------------------------------------------------------------------

M.SELFTEST_SEED = 12345
M.SELFTEST_EXPECT = {
  2985844697, 1000116614, 251153310, 358338746, 811191121,
  912475636, 3960444620, 3705434726, 2843800643, 3070246870,
}

function M.selftest()
  local r = M.new(M.SELFTEST_SEED)
  for i = 1, #M.SELFTEST_EXPECT do
    local v = M.next32(r)
    if v ~= M.SELFTEST_EXPECT[i] then
      return false, i, v, M.SELFTEST_EXPECT[i]
    end
  end
  -- Range draws must stay inside their bounds.
  local r2 = M.new(7)
  for i = 1, 500 do
    local v = M.range(r2, 1, 3)
    if v < 1 or v > 3 then return false, -1, v, 0 end
  end
  return true
end

-- Registration tail (M5): hands this module to IB_SIM_MODULES when the addon
-- created it (WoW discards a chunk's return value); headless it does not
-- exist and nothing here runs. Full argument in sim/Hash.lua's tail.
local IB_REG = rawget(_G, "IB_SIM_MODULES")
if IB_REG then IB_REG.Rand = M end

return M
