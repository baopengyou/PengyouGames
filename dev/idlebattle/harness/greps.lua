-- harness/greps.lua -- an INDEPENDENT implementation of the four greps of A.5.
--
-- tools/greps.lua already checks these. This file deliberately does not share a
-- line of code with it: the greps are the mechanical half of the M1 gate, and a
-- checker with a bug in its comment stripper passes everything silently. Two
-- implementations that agree are evidence; one is an assertion. If the two ever
-- disagree, that disagreement is the finding.
--
-- A.5, over sim/ only:
--   1  no Fog. and no view accessor
--   2  no local player identity (A.2 -- the sim never learns which side is "me")
--   3  no float literal, and no "/" except immediately inside math.floor(...)
--   4  no pairs()
-- and, named elsewhere in the decisions doc but not numbered:
--   5  no clock of any kind (Q11, D.7)
--   6  no math.random / math.randomseed (determinism rule 3)
--   7  nothing that WoW's Lua 5.1 cannot parse
--
-- Over harness/ the rules are weaker but not absent: the harness may format
-- numbers and read files, but it must still be REPRODUCIBLE, so it may not read
-- a clock, may not use the stdlib RNG, and may not iterate a map with pairs()
-- (a generated log that depends on table iteration order cannot be replayed).
--
-- Usage: lua harness/greps.lua [simdir] [harnessdir]

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local simDir = (arg and arg[1]) or (here .. "/../sim")
local harnessDir = (arg and arg[2]) or here

-- DISCOVERED, never hardcoded. A hardcoded list turns an "independent second
-- implementation of the greps" into a checker that silently stops covering sim/
-- the moment a fifth file lands -- which is the one failure mode a second
-- implementation exists to rule out. io.popen is fine here: the harness is not
-- held to the sim's determinism rules.
local function luaFilesIn(d)
  local out = {}
  local ph = io.popen("ls " .. string.format("%q", d) .. " 2>/dev/null")
  if ph then
    for name in ph:lines() do
      if name:match("%.lua$") then out[#out + 1] = name end
    end
    ph:close()
  end
  table.sort(out)
  return out
end

local SIM_FILES = luaFilesIn(simDir)
local HARNESS_FILES = luaFilesIn(harnessDir)
if #SIM_FILES == 0 then
  print("harness/greps.lua: no .lua files under " .. simDir .. " -- the greps did NOT run")
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Blank out comments and string literals, keeping every byte offset and every
-- newline, so a reported line number still points at the right line. Written as
-- a single forward scan with an explicit state, rather than by pattern.
-- ---------------------------------------------------------------------------
local function stripped(src)
  local n = #src
  local buf = {}
  local i = 1
  local function keep(a, b)
    for k = a, b do buf[k] = src:sub(k, k) end
  end
  local function blank(a, b)
    for k = a, b do
      local c = src:sub(k, k)
      buf[k] = (c == "\n") and "\n" or " "
    end
  end
  -- Find the end of a long bracket [==[ ... ]==] opening at position p.
  local function longEnd(p)
    local eqs = src:match("^%[(=*)%[", p)
    if not eqs then return nil end
    local close = "]" .. eqs .. "]"
    local j = src:find(close, p + #eqs + 2, true)
    if not j then return n end
    return j + #close - 1
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      local le = longEnd(i + 2)
      if le then
        blank(i, le); i = le + 1
      else
        local j = src:find("\n", i, true) or (n + 1)
        blank(i, j - 1); i = j
      end
    elseif c == "\"" or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c or d == "\n" then break
        else j = j + 1 end
      end
      if j > n then j = n end
      blank(i, j); i = j + 1
    elseif c == "[" then
      local le = longEnd(i)
      if le then blank(i, le); i = le + 1 else keep(i, i); i = i + 1 end
    else
      keep(i, i); i = i + 1
    end
  end
  return table.concat(buf)
end

local hits = 0
local quiet = false
local fired = {}          -- grep id -> count, for the checker's own self-test

local function hit(grep, file, code, pos, what)
  local _, nl = code:sub(1, pos):gsub("\n", "")
  hits = hits + 1
  fired[grep] = (fired[grep] or 0) + 1
  if not quiet then
    print(string.format("  [grep %s] %s:%d  %s", grep, file, nl + 1, what))
  end
end

local function findAll(code, pat, fn)
  local init = 1
  while true do
    local s, e = code:find(pat, init)
    if not s then return end
    fn(s, e)
    init = (e >= s) and (e + 1) or (s + 1)
  end
end

-- Grep 3b, by a forward paren stack rather than a backward walk: every "(" is
-- pushed with a flag saying whether math.floor immediately preceded it, and a
-- "/" is legal only when the innermost open paren carries that flag.
local function checkDivision(file, code)
  local stack, top = {}, 0
  local i, n = 1, #code
  while i <= n do
    local c = code:sub(i, i)
    if c == "(" then
      local before = code:sub(1, i - 1):match("([%w_%.]+)%s*$")
      top = top + 1
      stack[top] = (before == "math.floor" or before == "floor")
    elseif c == ")" then
      if top > 0 then top = top - 1 end
    elseif c == "/" then
      if top == 0 or not stack[top] then
        hit(3, file, code, i, "division outside math.floor(...)")
      end
    end
    i = i + 1
  end
end

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local s = fh:read("*a")
  fh:close()
  return s
end

local FLOAT_SAFE = { "%f[%w]goto%f[%W]", "table%.unpack", "%f[%w]bit32%f[%W]",
                     "math%.type", "math%.tointeger", "string%.pack",
                     "%f[%w]rawlen%f[%W]", "<<", ">>", "//" }

local function checkSource(src, name, full)
  local code = stripped(src)

  if full then
    -- 1  view accessors
    for _, pat in ipairs({ "Fog%.", "IBFog", "Visible%s*%(", "View[A-Z]", "Render[A-Z]" }) do
      findAll(code, pat, function(s) hit(1, name, code, s, "view accessor " .. pat) end)
    end
    -- 2  local player identity
    for _, pat in ipairs({ "FullName", "myName", "UnitName", "UnitGUID", "PG%.Full",
                           "localPlayer", "isMe", "amHost", "isHost", "mySide" }) do
      findAll(code, pat, function(s) hit(2, name, code, s, "identity " .. pat) end)
    end
    -- The unit token "player" only ever appears as a string, so it is looked for
    -- in the ORIGINAL source, where the strings still exist.
    findAll(src, "[\"']player[\"']", function(s) hit(2, name, src, s, "the \"player\" unit token") end)
    -- 3a float literals
    findAll(code, "%d*%.%d+", function(s, e)
      local prev = code:sub(s - 1, s - 1)
      if not prev:match("[%w_%.]") then
        hit(3, name, code, s, "float literal " .. code:sub(s, e))
      end
    end)
    findAll(code, "%d+[eE][%+%-]?%d+", function(s, e)
      hit(3, name, code, s, "exponent literal " .. code:sub(s, e))
    end)
    -- 3b division
    checkDivision(name, code)
    -- 4 pairs()
    findAll(code, "pairs%s*%(", function(s)
      if code:sub(s - 1, s - 1) ~= "i" then hit(4, name, code, s, "pairs()") end
    end)
  else
    -- harness: reproducibility only
    findAll(code, "pairs%s*%(", function(s)
      if code:sub(s - 1, s - 1) ~= "i" then
        hit(4, name, code, s, "pairs() in the harness makes a log unreplayable")
      end
    end)
  end

  -- 5 clocks, 6 stdlib RNG: both apply everywhere
  for _, pat in ipairs({ "GetTime", "os%.time", "os%.clock", "os%.date",
                         "debugprofilestop", "GetFramerate", "GetServerTime" }) do
    findAll(code, pat, function(s) hit(5, name, code, s, "clock " .. pat) end)
  end
  for _, pat in ipairs({ "math%.random", "math%.randomseed" }) do
    findAll(code, pat, function(s) hit(6, name, code, s, "stdlib RNG " .. pat) end)
  end

  if full then
    -- 7 Lua 5.1 compatibility
    for _, pat in ipairs(FLOAT_SAFE) do
      findAll(code, pat, function(s) hit(7, name, code, s, "not in Lua 5.1: " .. pat) end)
    end
    findAll(code, "[&|~]", function(s)
      local c = code:sub(s, s)
      if not (c == "~" and code:sub(s + 1, s + 1) == "=") then
        hit(7, name, code, s, "bitwise operator " .. c)
      end
    end)
  end
end

local function checkFile(path, name, full)
  local src = read(path)
  if not src then
    hits = hits + 1
    print("  [missing] " .. path)
    return
  end
  checkSource(src, name, full)
end

-- ---------------------------------------------------------------------------
-- The checker's own self-test. A grep suite that silently matches nothing
-- reports a clean bill of health forever, so every detector is fired once
-- against planted code before the real files are scanned. The planted sample is
-- a string literal here, which this file's own stripper blanks out when it scans
-- itself -- so it cannot become a false positive.
-- ---------------------------------------------------------------------------
local function selfTest()
  local dq = string.char(34)
  local bad = table.concat({
    "local x = Fog.visible(1)",                       -- 1
    "local who = PG.FullName",                        -- 2
    "local tok = " .. dq .. "player" .. dq,           -- 2
    "local f = 0.5",                                  -- 3
    "local g = 1e3",                                  -- 3
    "local h = a / b",                                -- 3
    "for k, v in pairs(t) do end",                    -- 4
    "local t0 = GetTime()",                           -- 5
    "local r = math.random(3)",                       -- 6
    "local z = a & b",                                -- 7
  }, "\n")
  -- Everything here is legal sim code and must produce no hit at all: floored
  -- division (both spellings), a division inside a nested floor, ipairs, the
  -- not-equal operator, and a float that lives in a comment.
  local good = table.concat({
    "local ok1 = math.floor(a / b)",
    "local ok2 = floor(a * (100 + p) / 100)",
    "for i, v in ipairs(t) do end",
    "if a ~= b then end",
    "-- Lua 5.1 and 3.14 and pairs() and os.time in a comment",
    "local s = " .. dq .. "a player string" .. dq,
  }, "\n")

  quiet = true
  local before = hits
  fired = {}
  checkSource(bad, "<planted-bad>", true)
  local missing = {}
  for g = 1, 7 do
    if not fired[g] then missing[#missing + 1] = g end
  end
  local badHits = hits - before
  hits = before
  fired = {}
  checkSource(good, "<planted-good>", true)
  local goodHits = hits - before
  hits = before
  fired = {}
  quiet = false

  if #missing > 0 then
    print("  CHECKER BROKEN: greps that never fired on planted code: "
      .. table.concat(missing, ", "))
    os.exit(1)
  end
  if goodHits > 0 then
    print(string.format("  CHECKER BROKEN: %d false positives on legal sim code", goodHits))
    quiet = false
    checkSource(good, "<planted-good>", true)
    os.exit(1)
  end
  print(string.format("  self-test: all 7 detectors fire on planted code (%d hits), "
    .. "0 false positives on legal code", badHits))
end

print("A.5 greps (independent implementation)")
selfTest()
for i = 1, #SIM_FILES do
  checkFile(simDir .. "/" .. SIM_FILES[i], "sim/" .. SIM_FILES[i], true)
end
for i = 1, #HARNESS_FILES do
  checkFile(harnessDir .. "/" .. HARNESS_FILES[i], "harness/" .. HARNESS_FILES[i], false)
end

if hits > 0 then
  print(string.format("  %d hits", hits))
  os.exit(1)
end
print(string.format("  zero hits: %d sim files (greps 1-7), %d harness files (no clock, no stdlib RNG, no pairs)",
  #SIM_FILES, #HARNESS_FILES))
os.exit(0)
