-- Util.lua - money/name/csv/secret helpers, roster snapshot.
local ADDON, PG = ...

-- Secret-value guard (12.x combat secrecy). issecretvalue may not exist on
-- every build; when absent, nothing is treated as secret.
local isSecret = issecretvalue or function() return false end
PG.IsSecret = isSecret

-- Returns v only if it is a plain, non-secret string; else nil.
function PG.SafeStr(v)
  if isSecret(v) or type(v) ~= "string" then return nil end
  return v
end

-- Returns tonumber(v) only if v is non-secret (nil if not convertible).
function PG.SafeNum(v)
  if isSecret(v) then return nil end
  return tonumber(v)
end

-- 1250 -> "1,250g". Negatives keep the sign: -300 -> "-300g". Integer gold.
function PG.Money(g)
  local n = math.floor(tonumber(g) or 0)
  local sign = n < 0 and "-" or ""
  local s = tostring(math.abs(n))
  while true do
    local out, count = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
    s = out
    if count == 0 then break end
  end
  return sign .. s .. "g"
end

-- "Name-Realm" for a unit; empty/missing realm falls back to the player's own
-- normalized realm. Returns nil if the name is unavailable or secret.
function PG.FullName(unit)
  local name, realm = UnitFullName(unit)
  if isSecret(name) or type(name) ~= "string" or name == "" then return nil end
  if isSecret(realm) or type(realm) ~= "string" or realm == "" then
    realm = GetNormalizedRealmName()
  end
  if type(realm) ~= "string" or realm == "" then return name end
  return name .. "-" .. realm
end

-- Normalizes a CHAT_MSG_ADDON sender to "Name-Realm" (same-realm senders
-- arrive realm-less). Returns nil for secret/empty senders.
function PG.NormalizeSender(sender)
  if isSecret(sender) or type(sender) ~= "string" or sender == "" then return nil end
  if sender:find("-", 1, true) then return sender end
  local realm = GetNormalizedRealmName()
  if type(realm) == "string" and realm ~= "" then return sender .. "-" .. realm end
  return sender
end

-- CSV helpers for packing lists into a single wire field (names never contain
-- '|', ',' or ';' per spec).
function PG.CSV(list)
  return table.concat(list, ",")
end

function PG.SplitCSV(s)
  if type(s) ~= "string" or s == "" then return {} end
  return { strsplit(",", s) }
end

-- Non-secret snapshot of the current group: { [guid] = { name = "Name-Realm",
-- role = "T"|"H"|"D" } }. Take it out of combat (e.g. at READY_CHECK or
-- countdown); members whose GUID or name is secret/missing are skipped.
local ROLE_MAP = { TANK = "T", HEALER = "H", DAMAGER = "D", NONE = "D" }

local function addUnit(snap, unit)
  if not UnitExists(unit) then return end
  local guid = UnitGUID(unit)
  if isSecret(guid) or type(guid) ~= "string" then return end
  local name = PG.FullName(unit)
  if not name then return end
  local role = UnitGroupRolesAssigned(unit)
  if isSecret(role) or type(role) ~= "string" then role = "NONE" end
  snap[guid] = { name = name, role = ROLE_MAP[role] or "D" }
end

function PG.RosterSnapshot()
  local snap = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do addUnit(snap, "raid" .. i) end
  elseif IsInGroup() then
    addUnit(snap, "player")
    for i = 1, GetNumGroupMembers() - 1 do addUnit(snap, "party" .. i) end
  else
    addUnit(snap, "player")
  end
  return snap
end
