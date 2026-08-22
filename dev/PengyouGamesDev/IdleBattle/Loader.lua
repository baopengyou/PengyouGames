-- IdleBattle/Loader.lua - creates the IB_SIM_MODULES global the engine files
-- register into and import from. M5 part 1.
--
-- THE MECHANISM, in full (the engine files' tails point at sim/Hash.lua's tail
-- for the same argument from their side):
--
--   * The files beside this one are BYTE-IDENTICAL copies of the headless
--     engine under dev/idlebattle/ (sim/ and net/). They are synced by
--     dev/idlebattle/tools/syncaddon.sh and NEVER edited here; --check proves
--     the copies still match. Headless they import each other with
--         local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")
--     and export themselves with `return M`.
--   * WoW has no require() and DISCARDS a chunk's return value, so inside the
--     addon both halves of that idiom would reach nobody. This file creates
--     the IB_SIM_MODULES table BEFORE any engine file loads; each engine file
--     ends with a registration tail (`if IB_REG then IB_REG.Hash = M end`)
--     that fills it, and the imports above then find their modules there.
--   * Consequence: the IdleBattle block of PengyouGamesDev.toc is DEPENDENCY
--     ORDER, not grouping -- each engine file must load after every module it
--     names, and this file must load before all of them. The .toc says so
--     beside the block. syncaddon.sh's loadtest step executes that exact
--     order headless (require disabled) and fails the sync if it breaks.
--
-- IB_SIM_MODULES is a deliberate, documented exception to the addon's
-- no-new-globals rule (SPEC.md 3), in the same class as the SLASH_* names and
-- PengyouGamesDevDB: the platform gives the engine files no other way to see
-- each other, exactly as with the arcade's AR_SIM_MODULES. Nothing outside
-- IdleBattle\ and Games\IdleBattle.lua may read it except through PG.IBEngine.
local ADDON, PG = ...

if not rawget(_G, "IB_SIM_MODULES") then
  _G.IB_SIM_MODULES = {}
end

-- The PG-namespace handle the game module uses, so the global is written in
-- exactly one file and read through the namespace everywhere else.
PG.IBEngine = rawget(_G, "IB_SIM_MODULES")
