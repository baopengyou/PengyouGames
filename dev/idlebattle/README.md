# Idle Battle - the deterministic simulation core

This directory holds the simulation engine for **Idle Battle**, a hidden 1v1 lane battle
played inside World of Warcraft over invisible addon messages, with no server.

There is **one simulation**. It runs on both players' machines over a fully shared input
set, and only *intent* ever crosses the wire - a 6-byte command atom saying "9 Spears into
lane 2 at tick 1,340". Nothing derived is transmitted: no costs, no damage, no HP, no
winner. Both clients compute all of that themselves and must arrive at **the same integers,
bit for bit, for 6,000 ticks**. If they ever disagree, the two players are watching two
different matches and neither knows it.

That is the whole engineering problem, and everything in this directory exists to make a
disagreement impossible or, failing that, immediately visible.

**This code is headless.** No WoW APIs, no UI, no networking, no frames, no events, no
saved variables. It is plain Lua that runs under any interpreter. The addon, the wire and
the renderer are later milestones (M5, M7) and they will *wrap* this, never reach into it.

Binding design documents (this code implements them, it does not supersede them):

- `../docs/IDLE_BATTLE_DECISIONS.md` - v2, authoritative. Part A architecture, Part C
  numbers, Part E build order.
- `../docs/IDLE_BATTLE.md` - the game design.

---

## Quick start

```sh
tools/ci.sh                  # the whole M1 gate at 1000 logs. This is the one to run.
tools/ci.sh 50               # same gate, 50 command logs instead of 1000, seconds
tools/ci.sh 1000 /path/lua   # pick the interpreter (luac is looked for beside it)
```

Individual checkers, all runnable on their own:

```sh
tools/greps.sh               # the four A.5 greps over sim/
tools/comptest.sh            # Lua 5.1 / 5.4 compatibility + determinism hazards
tools/comptest.sh tools      # ...or over any other directory
tools/run_all.sh             # the tools/ suite (syntax, greps.lua, smoke, mechanics,
                             #   ruleset coverage, hash coverage, goldens, mirror,
                             #   milestone)
harness/run.sh 1000          # the harness/ suite (selftest, replay, fuzz)
lua tools/determinism.lua 1000   # the M1 milestone test on its own
lua tools/smoke.lua              # Part C arithmetic landmarks
lua tools/mechanics.lua          # rules the random logs rarely reach
lua tools/rulescover.lua         # every ruleset value is inside rulesHash
lua tools/hashcover.lua          # every state field moves the hash
lua tools/mirror.lua 2000        # A.2: a mirrored match mirrors exactly
lua harness/selftest.lua         # the committed golden hashes
lua harness/fuzz.lua 1000        # the milestone + mid-run arrival + invariants
```

Every one of them exits non-zero on failure, so any of them is usable as a CI step.
The default interpreter is `/opt/homebrew/bin/lua`.

---

## What M1 is, and how to tell whether it currently passes

Part E states the milestone:

> The same `rulesHash` and the same command log produce a **bit-identical `stateHash` after
> 6,000 ticks**, over 1,000 randomised logs, under both Lua 5.1 and the 5.4 `luac -p`
> checker, on two different machines with different CPUs. The hash must cover Levy, bank,
> every accumulator and every tiebreak counter, not just the board. All four greps pass with
> zero hits.

**How to tell: run `tools/ci.sh` and read the last line.** It prints `M1 GATE: GREEN` or
`M1 GATE: RED` with the failing steps named. Nothing else counts as evidence - not a green
test you remember, not a passing run before your edit.

Status at the time this README was written, on Lua 5.5.0 / arm64 macOS:

| Milestone clause | Status |
|---|---|
| 1,000 randomised logs, 6,000 ticks, bit-identical `stateHash` at every 60-tick epoch | **PASS** (0 desyncs) |
| ...and identical under a *different arrival order* of the same commands | **PASS** |
| ...and identical when the same atoms arrive *mid-run* at their own arrive ticks | **PASS** (`harness/fuzz.lua` run D) |
| Tick depth actually reached (not just requested) | **PASS**, and now *enforced*: `determinism.lua` fails if too few logs reach 6,000 or too few late same-tick collisions occur |
| Hash covers Levy, bank, accumulators, tiebreak counters, PRNG state | **PASS** (`tools/hashcover.lua`) |
| Unhashed derived state is a pure function of hashed state | **PASS** (`harness/runner.lua` `invariants`) |
| Every ruleset value is inside `rulesHash`, both directions | **PASS** (`tools/rulescover.lua`) |
| A.2 side symmetry over random logs *and* a deterministic same-tick spoils case | **PASS** (`tools/mirror.lua 2000`) |
| Four greps, zero hits | **PASS** (`tools/greps.sh`, 0 hits over 4 files) |
| `luac -p` over every file in `sim/`, `tools/` and `harness/` | **PASS** |
| Committed golden hashes asserted, not skipped | **PASS** (`harness/selftest.lua`, `harness/fuzz.lua` SUITE HASH) |
| Lua 5.1 compatibility | **STATIC ONLY** - see caveat below |
| Two different machines with different CPUs | **NOT DONE** - see caveat below |

Tiers T2/T3/T4 of the Q10 ladder are **not** reached by random play and the milestone run
does not cover them: they need an exact tie in `keepDamageDealt`, which random logs do not
produce. `tools/mechanics.lua` covers the comparison logic by hand-building terminal
states. That is a real gap in the *milestone*, closed by a different test, and it is stated
here rather than implied away.

`rulesHash` at that time was `297242539` (`4wyxt7`). If you see a different value, the
ruleset changed; that is a deliberate compatibility break (A.11.1) and every recorded
match log from before the change is invalid - and `harness/selftest.lua` will go **red**
until `GOLDEN_RULESHASH`, `GOLDEN_STATE`, `GOLDEN_LOGDIGEST` and `harness/fuzz.lua`'s
`GOLDEN_SUITE` are regenerated together. That redness is deliberate: it is the only check
in the tree that compares against a number written down rather than against another run of
the same process, so it must never silently switch itself off.

**Two caveats, stated plainly because a future agent will otherwise read the table as
"M1 is finished".**

1. **No Lua 5.1 interpreter exists on this machine**, so "runs under 5.1" is currently
   proven *statically* by `tools/comptest.sh` (which rejects every 5.2+/5.3+/5.4+
   construct) rather than by execution. Installing `lua5.1` and running
   `tools/ci.sh 1000 $(which lua5.1)` would close this. Until then the first real 5.1
   execution happens inside WoW, which is the worst possible place to discover a problem.
2. **The cross-machine clause is untested.** Everything here has run on one CPU. The
   arithmetic is written so that this cannot matter (see rule 1 below), but "cannot matter"
   is a claim, and the milestone asks for a measurement. Running `tools/ci.sh` on a second
   machine and comparing the printed `rulesHash` and the milestone's PASS line is the
   cheapest possible check.

---

## The determinism rules, and why each one exists

These are not style preferences. Each one, violated, produces the same failure: two clients
compute different numbers, the match silently forks, and both players believe they are
winning. `tools/greps.sh` and `tools/comptest.sh` mechanise all of them.

**1. Integer arithmetic only. No float literals. No `/` outside `math.floor(...)`.**
Lua 5.1 has one number type (double); 5.3+ has integers and floats. `/` always produces a
float in every version. Two machines can round the last bit of a float differently - across
CPU architectures, across compiler flags, across Lua builds - and one unit surviving with
1 HP on one client and dying on the other is a divergent match from that tick onward.
Everything is therefore scaled up and floored: percentages are whole percent applied as
`floor(base * (100 + pts) / 100)`, the type wheel is permille over a fixed denominator,
"half damage to structures" is `STRUCTURE_DMG_PCT = 50`. Every quantity stays far inside
2^53 so it is exact both as a 5.1 double and as a 5.3+ integer.

**2. No `pairs()`, ever.** Iteration order over a Lua hash table depends on internal
addresses, which differ between machines and between runs. A loop that applies effects in
pairs order applies them in a *different order* on the other client - and once order
matters (it decides which of two simultaneous deploys can afford to land, per A.4), that is
a desync. Arrays are walked with numeric `for`; every map that must be iterated carries a
parallel **sorted key array** (`Rules.CONST_ORDER`, `sd.modsOrder`, and so on).
`ipairs` is fine: it is ordered. `next()` is not, and is flagged for the same reason.

**3. No `math.random`, no `math.randomseed`.** 5.1 defers to C `rand()`; 5.4 uses
xoshiro256\*\*. Same seed, different sequence, different match. `sim/Rand.lua` is the only
generator the sim may use: an explicit LCG whose entire state is an integer, whose products
are provably below 2^53, and whose state is **inside the hashed sim state** - so an
accidental extra draw on one client shows up as a desync at the next heartbeat instead of
silently biasing a match. (The shipped v1.0 ruleset consumes no randomness at all; the
generator exists for the harness and for the reserved seed field.)

**4. No clocks. No `os.time`, `os.clock`, `GetTime`, `C_Timer`, `debugprofilestop`.** The
sim advances only by explicit `sim:tick()` calls. Two clients never share a wall clock, and
the match clock counts *active sim ticks only* (A.9) - a 40-minute raid pause costs the
match zero clock. A sim that reads a clock is a sim whose two copies are already different.

**5. Side-agnostic (A.2).** The sim never knows which side is the local player. Sides are
indices 1 and 2, handled by the same code, `for s = 1, 2`. No `PG.FullName`, no `"player"`,
no `myName`. **This is the strongest invariant in the design**: a simulation that cannot
tell which side you are cannot leak to you and cannot branch on you, and "one client's sim
quietly behaving differently because it can see who it is" is the main killer of lockstep
implementations. `tools/mirror.lua` tests it dynamically - the same match with the two
sides swapped must produce the exactly mirrored state.

**6. No table-address-dependent behaviour.** Never sort by table identity, never use a
table as a key where iteration order could matter. Every tie in the sim breaks by **lowest
entity id** (S10), and entity ids are allocated in a fixed order from tick 0.

**7. Lua 5.1 compatibility.** WoW runs 5.1. No `goto`, no `//`, no bitwise operators, no
`table.unpack` (5.1 spells it `unpack`), no `<const>`, no 5.2+ library functions. The
harness runs a modern interpreter where every one of those parses happily and then does not
exist on a player's machine, which is exactly why `luac -p` is not sufficient and
`tools/comptest.sh` exists. The reverse direction is checked too: `unpack`, `setfenv`,
`loadstring` and `math.pow` work in WoW and break the harness, which is just as bad,
because then the harness cannot test the shipping code.

Two further hazards that are not on the numbered list but will bite:

- **Never let `tostring` or `string.format` touch a number that reaches the hash or the
  wire.** 5.1 prints `3`, 5.3+ prints `3.0` for the same value. `sim/Hash.lua` renders
  numbers digit by digit for exactly this reason. `comptest.sh` warns on both.
- **Never concatenate a number into a string that matters.** Same problem, same reason.

---

## File layout

```
sim/                 the simulation. Nothing in here may touch WoW, the UI or the network.
  Rules.lua          the entire ruleset as integers, in ONE file, plus rulesHash over it.
                     Its INTERPRETATIONS block at the bottom lists every place the design
                     documents were silent or in conflict and this implementation chose.
  Sim.lua            the one deterministic simulation (A.1): units, buildings, both keeps,
                     Levy, bank, income, costs, per-lane supply, the Q10 tiebreak ladder.
                     Ends with the M3 hook points, all nil in M1.
  Hash.lua           31-bit integer hashing. Hash.state(sim) is the stateHash the heartbeat
                     carries; Hash.log(sim) is logDigest. No floats, no bitwise ops, no
                     tostring - all three would differ across Lua versions.
  Rand.lua           the sim's own integer LCG. See rule 3.

tools/               checkers and the first test suite. NOT held to the sim's determinism
                     rules - these run on one machine and may use io, os and pairs freely.
  ci.sh              THE M1 GATE. greps + comptest + luac -p + BOTH suites. Run this.
  greps.sh           the four A.5 greps, over every .lua file found under sim/.
  comptest.sh        Lua 5.1 / 5.4 compatibility and determinism hazards.
  strip_lua.awk      blanks comments and string literals (line numbers preserved) so the
                     two shell checkers match against CODE and never against prose.
  run_all.sh         the tools/ suite entry point, in milestone order.
  determinism.lua    the M1 milestone test: N randomised logs, each run three times -
                     twice straight and once with the commands arriving in a different
                     order - hashed at every 60-tick epoch. Also ENFORCES coverage
                     floors: enough logs must reach tick 6,000, and enough same-side
                     same-tick collisions must occur after tick 3,000, or the run
                     refuses to certify even with zero desyncs.
  greps.lua          an independent second implementation of the greps, in Lua. Discovers
                     its file list; never hardcodes it.
  smoke.lua          Part C arithmetic landmarks (income, stipend, costs, crossing times,
                     the Horse-opening chain, exact build completion ticks).
  mechanics.lua      the rules random logs rarely reach: trap caps, spoils, refunds, the
                     slot cap, every tiebreak tier, the depth-hold timer, command dedup,
                     input validation, the order-delay window, bank-cap reduction.
  rulescover.lua     every ruleset value is hashed, structural or derived - checked in
                     BOTH directions, so a new constant that no order array names fails
                     the build instead of shipping outside rulesHash.
  hashcover.lua      mutates each state field in turn and proves the hash notices.
  mirror.lua         the A.2 side-symmetry test: N random mirrored matches plus a
                     deterministic same-tick mutual-spoils case.

harness/             the SECOND suite, and not redundant with tools/. Three things live
                     ONLY here, and the M1 gate is dishonest without them:
                       * runner.lua `invariants` - the only checks on state the hash
                         deliberately does NOT cover (cacheLevyFlat, cacheBankCap, the
                         per-lane aura caches, u.lane/u.step, economy integrality). Two
                         replays of a stale cache hash EQUAL, so nothing else can see it.
                       * fuzz.lua's `arrival` mode - the only run that queues each atom
                         mid-run at its own arrive tick, which is what the wire does.
                         tools/determinism.lua only ever queues before tick 0.
                       * the committed golden hashes - selftest.lua's rulesHash/stateHash/
                         logDigest and fuzz.lua's SUITE HASH. The only comparisons in the
                         tree against a number written down rather than another run of the
                         same process, so the only ones that can catch a PLATFORM
                         disagreement rather than a self-inconsistency.
  run.sh             the harness/ entry point. NOTE: takes (logs, lua) - the REVERSE
                     argument order of run_all.sh.
  selftest.lua       ~300 hand-asserted checks, including the golden hashes.
  fuzz.lua           the milestone over legal generated logs, four arrival patterns.
  runner.lua         the run/compare/invariants engine both of the above sit on.
  gen.lua            the legal-log generator (policies: guard, turtle, brawl).
  replay.lua         replays a .iblog artifact from the CLI.
  logfmt.lua         the .iblog text format, parse and render.
  greps.lua          the harness's own independent implementation of the greps.
  logs/hand.iblog    the hand-written replay artifact the goldens are keyed to.

README.md            this file.
```

`sim/` is loaded two ways and must stay loadable both ways. Under the harness it is
`require("sim.Sim")`. Inside WoW there is no `require`, so each file falls back to a global
`IB_SIM_MODULES` table that the addon's load order must populate first
(`local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")`).
`comptest.sh` warns about this on every file that uses `require`, deliberately - it is the
one WoW-shaped assumption left in headless code.

---

## The four greps (A.5)

| # | Rejects | Because |
|---|---|---|
| 1 | `Fog.`, any visibility predicate, any render-layer or WoW-UI symbol | Fog of war is a pure render filter (A.3). A sim that can ask what is visible can branch on it, and the two clients do not have the same renderer state. M7's real proof is that a match with `Fog.Visible` stubbed to always-true produces a bit-identical hash. |
| 2 | `FullName`, `myName`, `UnitName`, the `"player"` token, any identifier containing `player` | A.2. Sides are 1 and 2. |
| 3 | float literals, exponent literals, `/` outside `math.floor(...)`, bare `floor(` without the `local floor = math.floor` alias | rule 1 |
| 4 | `pairs(`, `next(`, and `table.sort(` (flagged for hand-verification, since a comparator that ever compares table identity is a desync) | rule 2 |

Both shell checkers match against `strip_lua.awk`'s output, so the sentence "no `pairs()`
in sim code" inside a comment is not reported as a violation, and "Lua 5.1" in prose is not
reported as a float. Where a check cannot avoid over-reaching it says so in its own output
and **prefers a false positive to a miss** - grep 2's bare `player` check is the clearest
example. If one ever fires wrongly, rename the code; do not add an exception to the script.
An exception mechanism is how these greps die.

---

## Changing the sim: the checklist

1. **Run `tools/ci.sh` before and after.** A green gate before your edit is what makes the
   red gate after it meaningful.
2. **New file under `sim/`?** `greps.sh`, `comptest.sh` and `tools/greps.lua` all discover
   their file lists, so they cover it automatically. Do not reintroduce a hardcoded list.
3. **New state field?** It must be in `Hash.state`, or a divergence in it is invisible and
   M1's guarantee is void for that field. Per-side modifier state goes in `sd.mods` with its
   key appended to `sd.modsOrder` (which is sorted and hashed, so nothing new is needed in
   `Hash.lua`). Then extend `tools/hashcover.lua` to prove the hash moves. A field that is
   *derived* from other state is the one exception: name it `cache*`, leave it out of the
   hash, and re-derive it in `harness/runner.lua`'s `invariants` instead - hashing a value
   you can recompute HIDES a stale cache, because both clients compute the same wrong number
   and agree.
4. **New value in `Rules.lua`?** It must be named by an order array (`CONST_ORDER`,
   `UNIT_FIELDS`, `BUILDING_FIELDS`, `REASON_ORDER`) or `rulesHash` cannot see it, and a
   peer on a different build then passes the handshake and desyncs later.
   `tools/rulescover.lua` enforces both directions and will fail the build on an
   unclassified top-level key.
5. **Changed a number in `Rules.lua`?** `rulesHash` changes, which is a hard compatibility
   break by design - two clients with different values refuse each other politely at the
   handshake rather than desyncing at the first engagement (A.11.1, G.4). The build goes
   **red** until you regenerate all four goldens together: `GOLDEN_RULESHASH`,
   `GOLDEN_STATE`, `GOLDEN_LOGDIGEST` in `harness/selftest.lua` and `GOLDEN_SUITE` in
   `harness/fuzz.lua`. Both files print the new values on the failure path. Say so in the
   commit.
6. **New Levy payout that can fire during a resolve tick?** Route it through
   `queueCredit`, never `credit`. A credit is clipped against the receiver's bank cap, and
   a building dying on the same tick moves that cap - paying mid-walk makes the result
   depend on which side the loop reached first, which is an A.2 violation that favours the
   client. `tools/mirror.lua`'s synthetic case is the regression test.
7. **New iteration over a map?** Add a parallel ordered key array. There is no other
   acceptable answer.
8. **New tie anywhere?** Break it by lowest entity id.

---

## Where this sits in the build order (Part E)

- **P** - the Probe. Half a day in a real raid, off the critical path, calibrates every rate
  constant. Not in this directory.
- **M1** - *this directory*. The determinism harness. **The top risk**, because Ruling 1
  doubled the determinism surface: the full economy, 40 modifiers and the tiebreak
  accumulators now all run on both machines, and any line of it can desync.
- **M2** - the sim playing itself. Scripted policies both sides, 1,000 matches, reproducing
  C.6: median 380-430 s, >=75% inside the 5-10 minute band, >=80% decided by a razed keep,
  family spread under 10pp. Cross-checked against the Python model; a disagreement between
  the two is a finding, not a nuisance.
- **M3** - all 40 modifiers with the S1-S10 stacking machinery, still headless. **The second
  risk.** M1's bit-identical test must still pass for each card alone and for 200 random
  5-card loadouts per side. The hook points at the bottom of `Sim.lua` are where they land.
- **M4** - two sims in one client through a fake lossy transport; rollback; `Q` full-log
  replay from tick 0.
- **M5** - first playable over the wire. `OPEN`/`JOIN`/`S`/`C`/`H`, party scope.
- **M6** - halt and resume, symmetric and asymmetric.
- **M7** - fog as a render filter, and the four greps again on a full build.
- **M8** - loadouts, `rulesHash` refusal, all 40 cards live, offline replay of a persisted
  match descriptor.
- **M9** - matchmaking, public scope, shipping.

**Do not proceed past a red milestone.**

---

## Open items for the decisions-doc owner

Two things need a ruling in `dev/docs/IDLE_BATTLE_DECISIONS.md`. Neither blocks M1 - the
implementation has chosen and recorded a defensible answer for both, in `Rules.lua`'s
INTERPRETATIONS block - but both are places where the code and the document currently
disagree, and the document is the authority.

1. **C.5's "3-Horse opening affordable t = 24.5 s" is stale v1 arithmetic.** With the 30
   Levy opening stipend and 10 per Levy tick, `bank(t) = 30 + 10 * floor(t / 35)`, so the
   chain is 1 Horse at **0.0 s**, 2 at **10.5 s**, 3 at **21.0 s** - not 24.5 s. The
   implementation is right and the doc is wrong; the 24.5 figure was computed against a
   20-Levy stipend. `tools/smoke.lua` now pins all three ticks plus the Trap Pit (70) and
   Levy Post (315) landmarks, so the doc and the sim stay pinned to each other once the doc
   is corrected. **The rest of Part C should be swept for other figures derived against the
   old 20-Levy stipend.**

2. **Building wire letters deviate from A.11.2.** A.11.2 assigns `a`-`l` to the
   12-building catalogue *and* `i` to Investment and `l` to Ley Line. Those collide.
   `Rules.lua` resolves it in favour of unambiguous kinds - the catalogue skips `i` and `l`
   and runs `a b c d e f g h j k m n`. The alternative is to move the three verbs to unused
   uppercase codes and keep `a`-`l` contiguous. **This needs to be ruled on before M5
   freezes `proto`**, because the letter assignment is wire format and changing it
   afterwards is a compatibility break.

## Cross-implementation verification (M1 verification pass)

The suite has been run under **two Lua implementations with different numeric
models**, and they produce **identical hashes**:

| | Lua 5.5 (native 64-bit integers) | LuaJIT 2.1 (Lua 5.1 semantics, doubles) |
|---|---|---|
| `rulesHash`  | 297242539 | 297242539 |
| `stateHash`  | 1247322841 | 1247322841 |
| `logDigest`  | 511904510 | 511904510 |
| `SUITE HASH` | 1032271223 | 1032271223 |
| selftest     | 305 checks pass | 305 checks pass |

This matters more than it looks. WoW's Lua 5.1 has **no integer type** - every
number is a double - while Lua 5.5 has real integers. Those are precisely the
two representations that would disagree if any arithmetic in the sim were not
integral. They agree bit-for-bit, which is direct evidence that the
integer-only discipline holds and that the sim will behave identically inside
WoW.

Run it yourself:

    sh tools/ci.sh 60 "$(which luajit)"     # 5.1 semantics
    sh tools/ci.sh 60                       # 5.5

`tools/ci.sh` does not recognise LuaJIT as a 5.1 interpreter, so its closing
banner still claims 5.1 was "static only" even on a LuaJIT run. Ignore that
line when the interpreter is LuaJIT; the hashes above are the real evidence.

**Still genuinely unproven: a second physical machine.** Everything above ran on
one host (Darwin arm64). To close it, run `sh tools/ci.sh 1000` on another
machine - ideally the Windows gaming PC - and confirm `SUITE HASH 1404498451`
and `rulesHash 297242539`. Different CPU, different OS, same numbers.
