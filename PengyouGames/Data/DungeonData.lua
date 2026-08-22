-- Data/DungeonData.lua - the shipped boss rosters, by dungeon name.
--
-- WHY THIS FILE EXISTS, given that 1.4.0's whole design was "no shipped data".
--
-- That position was defensible and it was wrong in practice. The Encounter
-- Journal did not answer on a live 12.1 client - not through the tier walk, not
-- after loading Blizzard_EncounterJournal on demand - so the per-boss half of
-- the Mythic Parley simply never appeared. A table that goes stale when the
-- season rotates is a far smaller problem than a feature that never works, and
-- the runtime paths are still there underneath this one for exactly the case
-- where it IS stale. Owner's call, 2026-08-21, and the right one.
--
-- WHAT IS AND IS NOT IN HERE, and the rule is strict:
--
--   NAMES ONLY. No dungeonEncounterIDs, no challengeMapIDs, no numbers of any
--   kind. Those are the values this file could not be sure of - they live in
--   DungeonEncounter.db2 and are not something a guide page will tell you - and
--   a WRONG id does not fail loudly. It silently attributes nothing to that
--   boss, so every line about it voids with "that boss was never fought" and
--   the bettor is told a lie about their own run. Never ship a number you
--   cannot verify.
--
-- So the table is keyed by the dungeon's NAME and holds its bosses' NAMES, in
-- journal order. Both are things the addon can compare against what the client
-- tells it: C_ChallengeMode.GetMapUIInfo gives the dungeon name, ENCOUNTER_END
-- gives the boss name. Everything else - which boss a card line means, which
-- encounter settled it - is a position in the roster the bookie publishes, so
-- no id is needed anywhere.
--
-- THE LOCALE CONSEQUENCE, stated rather than hidden: these are the ENGLISH
-- names. On a non-English client the dungeon-name lookup simply misses, this
-- file contributes nothing, and the roster comes from the Encounter Journal or
-- from a run instead - both of which are already localised. It is a head start
-- for enUS/enGB clients, never a requirement.
--
-- Season 2 of Midnight (patch 12.1, pool live 2026-08-18): five Midnight
-- dungeons and three reworked legacy ones. Sources are listed against each
-- group; the legacy three were re-verified rather than taken from memory,
-- because they were reworked for this season and a rework can move bosses.
local ADDON, PG = ...

PG.Dungeons = {
  -- Midnight (12.x). Boss orders per Icy Veins' Midnight dungeon guide and
  -- Method's per-dungeon guides.
  ["Altar of Fangs"] = { "Rav'i", "The Writhing Coil", "Zul'jan" },
  ["Murder Row"] = { "Kystia Manaheart", "Zaen Bladesorrow",
                     "Xathuux the Annihilator", "Lithiel Cinderfury" },
  ["Den of Nalorakk"] = { "The Hoardmonger", "Sentinel of Winter", "Nalorakk" },
  ["The Blinding Vale"] = { "Lightblossom Trinity", "Ikuzz the Light Hunter",
                            "Lightwarden Ruia", "Ziekket" },
  ["Voidscar Arena"] = { "Taz'Rah", "Atroxus", "Charonus" },

  -- The reworked legacy three. Per Method's 12.1 guides: neither King's Rest
  -- nor Temple of Sethraliss lost a boss in the rework, so both keep four.
  ["King's Rest"] = { "The Golden Serpent", "Mchimba the Embalmer",
                      "The Council of Tribes", "Dazar, the First King" },
  ["Temple of Sethraliss"] = { "Adderis and Aspix", "Merektha", "Galvazzt",
                               "Avatar of Sethraliss" },
  ["Ruby Life Pools"] = { "Melidrussa Chillworn", "Kokia Blazehoof",
                          "Kyrakka and Erkhart Stormvein" },
}

-- Normalised lookup: the client's dungeon name is compared case- and
-- punctuation-insensitively, so "Kings Rest" against "King's Rest" and
-- "Dazar, The First King" against "Dazar, the First King" both land. Built once
-- here rather than re-derived per query.
PG.DungeonsByKey = {}
for name, bosses in pairs(PG.Dungeons) do
  PG.DungeonsByKey[(name:lower():gsub("[^%w]", ""))] = bosses
end
