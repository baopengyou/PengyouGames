-- harness/logfmt.lua -- the command-log file format.
--
-- WHY A TEXT FORMAT
-- A.12 makes the ordered command log the replay artifact: given the seed, the
-- rulesHash and the log, any machine can rebuild the whole match from tick 0. So
-- the log needs a form a human can read in a bug report, diff in a patch, and
-- paste into an issue -- not a Lua table dumped with tostring (which prints
-- numbers differently on 5.1 and 5.3 and would quietly corrupt the artifact).
--
-- FORMAT, one directive per line, "#" starts a comment, blank lines ignored:
--
--   version 1
--   seed    <int>                  the handshake's seed field
--   ticks   <int>                  match length in sim ticks (6000)
--   loadout <side> <5 ints>        modifier ids; all zero until M3
--   cmd <exec> <side> <seq> <kind> <target> <count> [<arrive>]
--
-- `exec` is the ABSOLUTE execution tick that crossed the wire (A.11.2's EEE
-- field), not an issue tick: the sim only ever knows exec ticks. `arrive` is the
-- optional tick at which this client received the atom, which is what the
-- reordered-arrival test replays; it defaults to 0 (everything known up front)
-- and must never exceed `exec`, because a command that arrives after its exec
-- tick is the M4 rollback case, not the M1 case.
--
-- Everything is decimal ASCII. No floats: every field is an integer, checked on
-- the way in, so a malformed log fails at parse instead of at hash-compare time.

local M = {}

M.VERSION = 1

local floor = math.floor

local function isInt(v)
  return type(v) == "number" and v == floor(v)
end

local function toInt(tok)
  local v = tonumber(tok)
  if v == nil or not isInt(v) then return nil end
  return v
end

-- Split a line on whitespace. No pattern with backtracking, no pairs.
local function tokens(line)
  local t, n = {}, 0
  for w in string.gmatch(line, "%S+") do
    n = n + 1
    t[n] = w
  end
  t.n = n
  return t
end

-- Build an empty log table.
function M.newLog(seed, ticks)
  return {
    version = M.VERSION,
    seed = seed or 0,
    ticks = ticks or 6000,
    loadout = { { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 } },
    cmds = {},
    name = "<memory>",
  }
end

-- Append a command. Returns the command table.
function M.add(log, exec, side, seq, kind, target, count, arrive)
  local c = {
    tick = exec, side = side, seq = seq,
    kind = kind, target = target, count = count,
    arrive = arrive or 0,
  }
  log.cmds[#log.cmds + 1] = c
  return c
end

-- ---------------------------------------------------------------------------
-- parse
-- ---------------------------------------------------------------------------

function M.parse(text, name)
  local log = M.newLog(0, 6000)
  log.name = name or "<string>"
  local lineNo = 0
  local sawVersion = false
  for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
    lineNo = lineNo + 1
    -- NOTE: `raw` is the for-loop control variable, and Lua 5.5 makes those
    -- const; the stripped copy has to be a separate local so this file parses
    -- under 5.5 as well as under WoW's 5.1.
    local line = raw
    local hash = string.find(line, "#", 1, true)
    if hash then line = string.sub(line, 1, hash - 1) end
    local t = tokens(line)
    if t.n > 0 then
      local d = t[1]
      if d == "version" then
        local v = toInt(t[2])
        if v ~= M.VERSION then
          return nil, string.format("%s:%d: unsupported log version %s", log.name, lineNo, tostring(t[2]))
        end
        sawVersion = true
      elseif d == "seed" then
        local v = toInt(t[2])
        if v == nil then return nil, string.format("%s:%d: seed must be an integer", log.name, lineNo) end
        log.seed = v
      elseif d == "ticks" then
        local v = toInt(t[2])
        if v == nil or v < 1 then return nil, string.format("%s:%d: ticks must be a positive integer", log.name, lineNo) end
        log.ticks = v
      elseif d == "loadout" then
        local side = toInt(t[2])
        if side ~= 1 and side ~= 2 then
          return nil, string.format("%s:%d: loadout side must be 1 or 2", log.name, lineNo)
        end
        for i = 1, 5 do
          local v = toInt(t[2 + i])
          if v == nil then return nil, string.format("%s:%d: loadout needs 5 integers", log.name, lineNo) end
          log.loadout[side][i] = v
        end
      elseif d == "cmd" then
        if t.n < 7 then
          return nil, string.format("%s:%d: cmd needs exec side seq kind target count", log.name, lineNo)
        end
        local exec, side, seq = toInt(t[2]), toInt(t[3]), toInt(t[4])
        local kind = t[5]
        local target, count = toInt(t[6]), toInt(t[7])
        local arrive = 0
        if t.n >= 8 then
          arrive = toInt(t[8])
          if arrive == nil then return nil, string.format("%s:%d: arrive must be an integer", log.name, lineNo) end
        end
        if exec == nil or side == nil or seq == nil or target == nil or count == nil then
          return nil, string.format("%s:%d: cmd fields must be integers", log.name, lineNo)
        end
        if #kind ~= 1 then
          return nil, string.format("%s:%d: kind must be one character, got %q", log.name, lineNo, kind)
        end
        if arrive > exec then
          -- M1 has no rollback (A.12's bounded-rewind path is M4), so a log that
          -- asks for a late arrival is asking for behaviour that does not exist.
          return nil, string.format("%s:%d: arrive %d is after exec %d (M4 rollback case)",
            log.name, lineNo, arrive, exec)
        end
        M.add(log, exec, side, seq, kind, target, count, arrive)
      else
        return nil, string.format("%s:%d: unknown directive %q", log.name, lineNo, d)
      end
    end
  end
  if not sawVersion then
    return nil, string.format("%s: missing 'version %d' header", log.name, M.VERSION)
  end
  return log
end

function M.load(path)
  local fh = io.open(path, "rb")
  if not fh then return nil, "cannot open " .. path end
  local text = fh:read("*a")
  fh:close()
  return M.parse(text, path)
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------

function M.render(log, note)
  local out, n = {}, 0
  local function put(s) n = n + 1; out[n] = s end
  put("# idle battle command log")
  if note then put("# " .. note) end
  put("version " .. M.VERSION)
  put("seed " .. log.seed)
  put("ticks " .. log.ticks)
  for side = 1, 2 do
    local l = log.loadout[side]
    put(string.format("loadout %d %d %d %d %d %d", side, l[1], l[2], l[3], l[4], l[5]))
  end
  put("# cmd <exec> <side> <seq> <kind> <target> <count> <arrive>")
  local cmds = log.cmds
  for i = 1, #cmds do
    local c = cmds[i]
    put(string.format("cmd %d %d %d %s %d %d %d",
      c.tick, c.side, c.seq, c.kind, c.target, c.count, c.arrive or 0))
  end
  return table.concat(out, "\n") .. "\n"
end

function M.save(path, log, note)
  local fh = io.open(path, "wb")
  if not fh then return nil, "cannot write " .. path end
  fh:write(M.render(log, note))
  fh:close()
  return true
end

return M
