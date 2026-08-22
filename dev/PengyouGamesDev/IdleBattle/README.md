# IdleBattle/ — the mounted engine (M5 part 1)

**DO NOT EDIT ANY `.lua` FILE IN THIS FOLDER except `Loader.lua`.**

Everything else here is a build product of `dev/idlebattle/tools/syncaddon.sh`:

- `sim/*.lua` and `net/*.lua` are **byte-identical copies** of the headless
  engine under `dev/idlebattle/` — the tree where the engine is edited,
  gated (`tools/ci.sh`, `m2.sh`, `m3.sh`, `m4.sh`) and golden-checked.
- `HandLog.lua` is **generated** from `harness/logs/hand.iblog` plus the three
  committed goldens in `harness/selftest.lua` (extracted, never hand-copied);
  it feeds the in-game determinism selftest, `/pgd ib selftest`.

**The direction is one-way: the headless tree is edited, the addon is synced —
never the reverse.** An edit made here is a second, untested copy of the game
that no gate reads, and it is reverted by the next sync without warning.

```sh
sh dev/idlebattle/tools/syncaddon.sh            # re-sync after an engine edit
sh dev/idlebattle/tools/syncaddon.sh --check    # prove the copies still match
                                                # (byte-for-byte), the derived
                                                # file is current, and the .toc
                                                # order still loads
```

## How the engine loads inside WoW

WoW has no `require()` and discards a chunk's return value, so the headless
`require`/`return M` idiom reaches nobody in the addon. `Loader.lua` creates
the `IB_SIM_MODULES` global before any engine file loads; each engine file
ends with a registration tail (`if IB_REG then IB_REG.Hash = M end`) that
fills it, and every file-scope import
(`IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")`) then
resolves through the table. Headless, the global does not exist and both
halves are inert. This makes the `IdleBattle\` block of `PengyouGamesDev.toc`
**dependency order** — see the comment beside it — and `syncaddon.sh`'s
loadtest executes that exact order headless (with `require` disabled) so a
broken order fails at sync time, not at login.

`IB_SIM_MODULES` is a deliberate, documented exception to the addon's
no-new-globals rule (`SPEC.md` §3), in the same class as the `SLASH_*` names
and `PengyouGamesDevDB`. The game module reads it through `PG.IBEngine` only.

## What is (and is not) mounted

Mounted: `sim/Rules.lua`, `sim/Rand.lua`, `sim/Hash.lua`, `sim/Sim.lua`,
`sim/Mods.lua`, `net/Wire.lua`, `net/Net.lua`, `net/Snap.lua`.

Not mounted, on purpose: `net/Transport.lua` (the fake M4 channel — the
addon's channel is real; `Games/IdleBattle.lua` is its replacement),
`fog/Fog.lua` (a render filter, M7), and all of `policy/`, `sweep/`,
`harness/`, `tools/` (headless tooling).
