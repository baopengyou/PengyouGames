-- tools/greps.lua -- the four greps of A.5, run against sim/ only.
--
--   1. sim files contain zero references to Fog. or any view accessor
--   2. sim files contain zero references to local player identity
--   3. sim files contain no float literals and no "/" outside a math.floor(...)
--   4. sim files contain no pairs()
--
-- Plus three the decisions doc names elsewhere but does not number:
--   5. no clock of any kind (Q11, D.7): GetTime, os.time, os.clock, os.date
--   6. no math.random or math.randomseed (determinism rule 3)
--   8. NO DUPLICATE KEY IN ONE TABLE CONSTRUCTOR. Lua keeps the LAST of
--      `{ minStack = 3, ..., minStack = 1 }` and says nothing; luac -p accepts
--      it and the constructor function cannot see it, because the literal has
--      already collapsed by the time any code runs. That shipped a defence line
--      in policy/lines.lua running minStack 1 while its own source declared 3,
--      worth 25pp on that line and 2.3pp on the statistic the M2 milestone gates
--      on. The check has to be LEXICAL, which is why it lives here.
-- And a Lua 5.1 compatibility scan, since the shipped sim runs on 5.1 while this
-- harness runs on a modern interpreter: no goto, no integer-division operator,
-- no bitwise operators, no table.unpack, no 5.2-plus string additions.
--
-- IMPORTANT: this checker STRIPS COMMENTS AND STRING LITERALS before matching.
-- A naive shell grep cannot do that, and would flag "Lua 5.1" in a comment as a
-- float literal and "and/or" in prose as a division. Grep 3 is about code.
--
-- GREP 1 HAS A SCOPE, and tools/greps.sh's header argues it at length: "zero
-- references to Fog." is a statement about the SIMULATION, while the renderer
-- and policy/Policy.lua's view builder are CLIENTS -- the layer fog exists for.
-- Mode "sim" (the default) is grep 1 in full. Mode "client" drops exactly one
-- pattern and replaces it with a stricter one: a file may say Fog. only if it
-- requires "fog.Fog", the single audited model. Every other grep-1 pattern
-- still fires, so a client cannot invent its own visibility predicate or build
-- a second fog model under a borrowed name. It is a per-directory scope chosen
-- by the caller and printed in the output; it cannot silence one line.
--
-- Usage: lua tools/greps.lua [dir] [sim|client]
--        (defaults: the sibling sim directory, mode sim)

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local dir = (arg and arg[1]) or (here .. "/../sim")
local mode = (arg and arg[2]) or "sim"
if mode ~= "sim" and mode ~= "client" then
  print("greps.lua: mode must be sim or client, not " .. tostring(mode))
  os.exit(1)
end

-- The file list is DISCOVERED, never hardcoded. A hardcoded list turns this
-- "independent second implementation of the four greps" into a checker that
-- silently stops covering sim/ the moment a fifth file lands -- the one failure
-- mode a second implementation exists to rule out. io.popen is fine here: tools/
-- is explicitly not held to the sim's determinism rules.
local FILES = {}
do
  local ph = io.popen("ls " .. string.format("%q", dir) .. " 2>/dev/null")
  if ph then
    for name in ph:lines() do
      if name:match("%.lua$") then FILES[#FILES + 1] = name end
    end
    ph:close()
  end
  table.sort(FILES)
end
if #FILES == 0 then
  print("greps.lua: found no .lua files under " .. dir .. " -- the greps did NOT run")
  os.exit(1)
end

-- Replace every comment and string literal with spaces, preserving line numbers
-- and byte offsets so reported positions stay meaningful.
local function strip(src)
  local out = {}
  local i, n = 1, #src
  local function blank(a, b)
    for k = a, b do
      out[k] = (src:sub(k, k) == "\n") and "\n" or " "
    end
  end
  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)
    if two == "--" then
      -- long comment?
      local eq = src:match("^%-%-%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local j = src:find(close, i, true)
        j = j and (j + #close - 1) or n
        blank(i, j); i = j + 1
      else
        local j = src:find("\n", i, true) or (n + 1)
        blank(i, j - 1); i = j
      end
    elseif c == "\"" or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      blank(i, math.min(j, n)); i = j + 1
    elseif src:match("^%[(=*)%[", i) then
      local eq = src:match("^%[(=*)%[", i)
      local close = "]" .. eq .. "]"
      local j = src:find(close, i, true)
      j = j and (j + #close - 1) or n
      blank(i, j); i = j + 1
    else
      out[i] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function lineOf(src, pos)
  local _, nl = src:sub(1, pos):gsub("\n", "")
  return nl + 1
end

local hits = {}
local function hit(grep, file, src, pos, what)
  hits[#hits + 1] = string.format("  [grep %s] %s:%d  %s", grep, file, lineOf(src, pos), what)
end

-- Grep 3b: every "/" must sit inside a math.floor( ... ) call. Walk backwards
-- from the slash, tracking paren depth, to find the innermost enclosing open
-- paren, then check what precedes it.
local function slashInsideFloor(code, at)
  local depth = 0
  local i = at - 1
  while i >= 1 do
    local c = code:sub(i, i)
    if c == ")" then depth = depth + 1
    elseif c == "(" then
      if depth == 0 then
        local before = code:sub(1, i - 1):match("([%w_%.]+)%s*$")
        return before == "math.floor" or before == "floor"
      end
      depth = depth - 1
    end
    i = i - 1
  end
  return false
end

for f = 1, #FILES do
  local path = dir .. "/" .. FILES[f]
  local fh = io.open(path, "rb")
  if not fh then
    hits[#hits + 1] = "  [missing] " .. path
  else
    local src = fh:read("*a"); fh:close()
    local code = strip(src)

    -- 1. no view accessors in the sim
    for _, pat in ipairs({ "IBFog", "Visible%s*%(", "View[A-Z]" }) do
      local p = code:find(pat)
      if p then hit(1, FILES[f], src, p, "view accessor: " .. pat) end
    end
    do
      local p = code:find("Fog%.")
      if p then
        if mode == "sim" then
          hit(1, FILES[f], src, p, "view accessor: Fog%.")
        elseif not src:find('require%s*%(%s*"fog%.Fog"') then
          -- The require is matched against the ORIGINAL source: the module path
          -- is a string literal and strip() has blanked it out of `code`.
          hit(1, FILES[f], src, p,
            "says Fog. but does not require \"fog.Fog\" -- a second fog model "
            .. "wearing the audited name")
        end
      end
    end

    -- 2. no local player identity (A.2)
    for _, pat in ipairs({ "FullName", "myName", "UnitName", "UnitGUID",
                           "PG%.Full", "localPlayer", "isMe", "amHost" }) do
      local p = code:find(pat)
      if p then hit(2, FILES[f], src, p, "identity: " .. pat) end
    end
    -- The literal "player" is an identity accessor in WoW, but only as a string
    -- argument, so it is checked against the ORIGINAL source's string literals.
    do
      local p = src:find("[\"']player[\"']")
      if p then hit(2, FILES[f], src, p, "identity: the \"player\" unit token") end
    end

    -- 3a. no float literals
    do
      local init = 1
      while true do
        local s, e = code:find("%d*%.%d+", init)
        if not s then break end
        -- a method or field access like t.5 cannot occur; a leading identifier
        -- char means this is a name, not a number
        local prev = code:sub(s - 1, s - 1)
        if not prev:match("[%w_]") then
          hit(3, FILES[f], src, s, "float literal: " .. code:sub(s, e))
        end
        init = e + 1
      end
      local s2 = code:find("%d+[eE][%+%-]?%d+")
      if s2 then hit(3, FILES[f], src, s2, "exponent literal") end
    end

    -- 3b. every "/" inside a math.floor(...)
    do
      local init = 1
      while true do
        local s = code:find("/", init, true)
        if not s then break end
        if not slashInsideFloor(code, s) then
          hit(3, FILES[f], src, s, "division outside math.floor")
        end
        init = s + 1
      end
    end

    -- 4. no pairs()
    do
      local init = 1
      while true do
        local s, e = code:find("pairs%s*%(", init)
        if not s then break end
        local prev = code:sub(s - 1, s - 1)
        -- ipairs is fine: it is ordered
        if prev ~= "i" then
          hit(4, FILES[f], src, s, "pairs()")
        end
        init = e
      end
    end

    -- 5. no clock
    for _, pat in ipairs({ "GetTime", "os%.time", "os%.clock", "os%.date",
                           "debugprofilestop", "GetFramerate" }) do
      local p = code:find(pat)
      if p then hit(5, FILES[f], src, p, "clock: " .. pat) end
    end

    -- 6. no stdlib RNG
    for _, pat in ipairs({ "math%.random", "math%.randomseed" }) do
      local p = code:find(pat)
      if p then hit(6, FILES[f], src, p, "stdlib RNG: " .. pat) end
    end

    -- 7. Lua 5.1 compatibility
    for _, pat in ipairs({ "%f[%w]goto%f[%W]", "//", "table%.unpack",
                           "%f[%w]bit32%f[%W]", "math%.type", "math%.tointeger",
                           "string%.pack", "%f[%w]rawlen%f[%W]" }) do
      local p = code:find(pat)
      if p then hit(7, FILES[f], src, p, "not in 5.1: " .. pat) end
    end
    -- bitwise operators. "~=" is not-equal and must not be flagged.
    do
      local init = 1
      while true do
        local s = code:find("[&|~]", init)
        if not s then break end
        local c = code:sub(s, s)
        local nxt = code:sub(s + 1, s + 1)
        if not (c == "~" and nxt == "=") then
          hit(7, FILES[f], src, s, "bitwise operator: " .. c)
        end
        init = s + 1
      end
      local s = code:find("<<") or code:find(">>")
      if s then hit(7, FILES[f], src, s, "bitwise shift") end
    end

    -- 8. no duplicate key in one table constructor.
    --
    -- Walk the stripped source keeping a stack of brace scopes; a key is a
    -- `name =` whose nearest preceding non-space character is "{" or "," (the
    -- only two places a constructor key can start), which excludes `local x = 1`
    -- and every ordinary assignment. `==`, `~=`, `<=` and `>=` are excluded so a
    -- comparison inside a constructor is never read as a key.
    --
    -- A single occurrence is never reported, so the residual false-positive risk
    -- -- a multiple assignment like `local a, c = 1, 2` at brace depth >= 1 --
    -- would have to name the SAME variable twice to fire, which is not a thing
    -- anyone writes.
    do
      local seen = { [0] = {} }
      local depth = 0
      local i, n = 1, #code
      while i <= n do
        local c = code:sub(i, i)
        if c == "{" then
          depth = depth + 1
          seen[depth] = {}
        elseif c == "}" then
          if depth > 0 then seen[depth] = nil; depth = depth - 1 end
        elseif c == "=" and depth > 0 then
          local nxt = code:sub(i + 1, i + 1)
          local prv = code:sub(i - 1, i - 1)
          if nxt ~= "=" and prv ~= "=" and prv ~= "~" and prv ~= "<" and prv ~= ">" then
            local head = code:sub(1, i - 1)
            local name = head:match("([%a_][%w_]*)%s*$")
            if name then
              local before = head:sub(1, #head - #(head:match("%s*[%a_][%w_]*%s*$")))
              local lead = before:match("([^%s])%s*$")
              if lead == "{" or lead == "," then
                local t = seen[depth]
                if t[name] then
                  hit(8, FILES[f], src, i,
                    string.format("duplicate key `%s` in one table constructor "
                      .. "(first at line %d); Lua silently keeps the LAST",
                      name, lineOf(src, t[name])))
                else
                  t[name] = i
                end
              end
            end
          end
        end
        i = i + 1
      end
    end
  end
end

if #hits == 0 then
  print("all greps pass with zero hits over " .. #FILES .. " files [" .. mode .. "]")
else
  print(#hits .. " hits:")
  for i = 1, #hits do print(hits[i]) end
  os.exit(1)
end
