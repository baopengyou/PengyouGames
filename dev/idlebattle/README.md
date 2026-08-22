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

tools/m2.sh                  # the whole M2 gate: 1,632 scripted matches against C.6
tools/m2.sh 1                # same gate, 272 matches, ~25 s

tools/m3.sh                  # the whole M3 gate: every card alone (x2 pairings),
                             #   200 random dual loadouts, the clamp report. ~1 min
tools/m3.sh 20               # same gate, 20 loadout pairs, a smoke test
tools/m3.sh 200 "$(which luajit)"   # the 5.1-semantics half; compare SUITE HASHes

tools/m4.sh                  # the whole M4 gate: the A.11 codec, then 177 net
                             #   matches (2 sims through the lossy transport)
                             #   across four scenarios. ~30 s
tools/m4.sh "$(which luajit)"    # the 5.1-semantics half; compare the four
                             #   per-step SUITE HASHes

tools/syncaddon.sh           # M5: copy the engine into the DEV addon
                             #   (dev/PengyouGamesDev/IdleBattle/), regenerate
                             #   the derived HandLog.lua, run the loadtest
tools/syncaddon.sh --check   # M5 drift gate: non-zero if any addon copy
                             #   differs byte-for-byte from its original here,
                             #   the derived file from its sources, or the
                             #   .toc engine order no longer loads
```

**They are two gates, not one, and both must be run.** `tools/m2.sh`'s header gives
the full reasoning; the short version is that M1 is a correctness property with one
acceptable answer and M2 is a balance property measured against a provisional
document, and folding the second into the first makes a tuning question turn the
determinism gate red. **M2 is red while M1 is green**, which is exactly the situation
that would have destroyed the meaning of `tools/ci.sh` had they been merged.
`tools/m2.sh` is a front door onto `sweep/run.sh`, which stays the single definition
of what the M2 gate does.

**M2 now measures two INFORMATION REGIMES and the gate is the fogged one.** `fog`
applies `../docs/IDLE_BATTLE_FOG.md` -- the owner's binding fog model, implemented in
`fog/Fog.lua` -- to the enemy half of what a line is shown; `full` is Ruling 1's shared
state unfiltered, which is what M2's first pass silently measured. Every M2 report prints
which regime produced its numbers. See Finding 1.

> **THE REGIME USED TO BE CALLED `a3` AND IT IS NOW CALLED `fog`. THE CURRENT NUMBERS ARE
> IN FINDING 9; FINDING 8 HOLDS THE SAME MODEL PLAYED BY A ROSTER THAT NEVER SCOUTED, AND
> EVERYTHING OLDER THAN THAT WAS MEASURED UNDER `a3`.** `a3` was a three-bucket "muster bar" this
> implementation invented because fog had never been specified; the owner has now specified
> it and `IDLE_BATTLE_FOG.md` section 8.1 deletes the bar outright. **The M2 tables in this
> README are therefore VOID, not stale and not a baseline** -- the doc says so itself in
> section 8.4 -- and the rename exists so that no old number can be quoted as if it were
> comparable. Run `tools/m2.sh` to get numbers under the model that actually ships. See
> Finding 8.

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
lua tools/fogtest.lua            # FOG: every rule in docs/IDLE_BATTLE_FOG.md
                                 #   INCLUDING section 3a contact reveal AND the
                                 #   four M3 info effects (Divination, Omen,
                                 #   Veil, Shrine pulse) with their MUTATION
                                 #   suite, one at a time, against fog/Fog.lua
lua tools/m3gate.lua cards       # M3: each of the 40 cards individually,
                                 #   vs-empty + mirrored, 4 arrival patterns
lua tools/m3gate.lua loadouts 200   # M3: 200 random dual loadouts, full length
lua tools/m3gate.lua clamp 200   # M3: the clamp-saturation report
lua harness/m4run.lua codec      # M4: A.11 encode/decode round-trip, the
                                 #   byte-size table, malformed-input fuzz
lua harness/m4run.lua milestone 100   # M4: THE MILESTONE -- 10% loss, 1..30-
                                 #   tick jitter, hashes equal at every epoch
lua harness/m4run.lua rollback 40    # M4: late commands REQUIRED per run,
                                 #   every A.12 boundary case must occur
lua harness/m4run.lua deep 12    # M4: forced desync -> detect -> Q -> rebuild
lua harness/m4run.lua stress 25  # M4: 30% loss; escalation allowed, but
                                 #   convergence still asserted
lua harness/selftest.lua         # the committed golden hashes
lua harness/fuzz.lua 1000        # the milestone + mid-run arrival + invariants
lua sweep/sweep.lua 6            # M2: the C.6 cross-check, metric by metric, with
                                 #   a delta column. Informational; always exits 0.
lua sweep/sweep.lua 6 Rush-horse # ...or one line against the whole pool. Reports
                                 #   THAT LINE ONLY and prints no C.6 comparison:
                                 #   the other 16 lines play 2*seeds matches each,
                                 #   all against the named line, so every roster
                                 #   aggregate off that run is meaningless.
lua sweep/verdict.lua 6          # M2: the milestone asserted, BOTH regimes. THE gate.
lua sweep/verdict.lua 6 800000   # ...at a different seed base, to test seed luck.
                                 #   800000 is the one that moves a clause.
lua sweep/verdict.lua 6 500000 fog  # ...one regime only, half the runtime
lua sweep/determinism.lua 40 fog # M2: the policy layer replays byte-identically,
                                 #   INCLUDING each side's fog memory
lua sweep/determinism.lua 40 full   # ...and again under the other regime
lua sweep/fogaudit.lua           # M2: which lines react to something the fog
                                 #   never renders, AND how much of the board any
                                 #   line ever looks at. Per line: the lowest
                                 #   position it EVER sees an enemy unit at, the
                                 #   share of its threat detections the fog
                                 #   deletes, the mean sections it has lit and
                                 #   explored out of 8, and the share of its
                                 #   decisions taken against a board showing
                                 #   nothing at all. Diagnostic; exits 0.
lua sweep/fogaudit.lua 2 full    # ...one regime. "full" is the one that can still
                                 #   see what "fog" is deleting, so it is the one
                                 #   that sizes the defect.
lua sweep/scoutprobe.lua         # M2: WHAT BUYING SIGHT IS WORTH, decomposed
                                 #   into the body and the threshold, over three
                                 #   rosters that differ in nothing else.
                                 #   Diagnostic; exits 0.
lua sweep/scoutprobe.lua 6 500000   # ...at the gate's own sample size and seeds
lua sweep/famstat.lua            # M2: is the family-spread clause measurable at all?
lua sweep/probe.lua 6 Balanced   # M2: what one building costs against a control
lua sweep/probe.lua 6 Turtle-eco # ...and against a second, differently-minded one
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

`rulesHash` at that time was `297242539` (`4wyxt7`); on 2026-08-13 the A.11.2 wire-letter
ruling landed (contiguous `a`-`l` catalogue, uppercase `I`/`E`/`L` verbs) and it became
`333968378` (`5iu3ne`), with every golden regenerated together in the same commit - the
worked example of the paragraph below. On 2026-08-21 **M3 part 1** landed the forty cards,
the wheel matrix and the Shrine pulse constants inside the hashed ruleset and it became
**`767294897` (`cotsj5`)**, with all four goldens regenerated together again (see the M3
section below for the new values and for why `GOLDEN_LOGDIGEST` alone did not move). If
you see a different value than 767294897, the
ruleset changed; that is a deliberate compatibility break (A.11.1) and every recorded
match log from before the change is invalid - and `harness/selftest.lua` will go **red**
until `GOLDEN_RULESHASH`, `GOLDEN_STATE`, `GOLDEN_LOGDIGEST` and `harness/fuzz.lua`'s
`GOLDEN_SUITE` are regenerated together. That redness is deliberate: it is the only check
in the tree that compares against a number written down rather than against another run of
the same process, so it must never silently switch itself off.

**Two caveats, stated plainly because a future agent will otherwise read the table as
"M1 is finished".**

1. **No true Lua 5.1 interpreter exists on this machine**, so "runs under 5.1" is proven
   *statically* by `tools/comptest.sh` (which rejects every 5.2+/5.3+/5.4+ construct) plus
   *dynamically* under **LuaJIT 2.1, which implements 5.1 semantics with doubles**:
   `sh tools/ci.sh 1000 $(which luajit)` is **GREEN (5/5 steps, 1000 logs)** with
   `SUITE HASH 1912059909` (M3 part 1; the pre-M3 run was 2005649413), bit-identical to
   the Lua 5.5 run. That is the numeric model
   WoW uses and it is the half that matters most. What is still missing is PUC 5.1 itself,
   whose standard library differs from LuaJIT's in a few corners; installing `lua5.1` and
   running `tools/ci.sh 1000 $(which lua5.1)` would close it completely.
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
                     Since M3 part 1 that includes the FORTY CARDS (Rules.CARDS, id =
                     index, every payload number a hashed field), the Q3 wheel matrix
                     (Rules.WHEEL over WHEEL_TYPES) and the D.2 Shrine pulse constants.
                     Its INTERPRETATIONS block at the bottom lists every place the design
                     documents were silent or in conflict and this implementation chose;
                     items 13-28 are the M3 card readings.
  Sim.lua            the one deterministic simulation (A.1): units, buildings, both keeps,
                     Levy, bank, income, costs, per-lane supply, the Q10 tiebreak ladder.
                     Ends with the M3 hook points -- REAL since M3 part 1, registered per
                     match by Mods.install and all nil for a cardless match.
  Mods.lua           M3: the forty cards' RUNTIME. Validates loadouts, folds static card
                     points into sd.chan, computes the wheel edge, registers exactly the
                     hooks the cards present need, and implements the I/E/L verbs. Every
                     NUMBER it uses comes from Rules.CARDS; every mutable thing it owns
                     lives inside the hashed sim state. Held to every determinism rule
                     (the greps and comptest discover it automatically). With two empty
                     loadouts it installs NOTHING, which is what keeps the cardless game
                     byte-identical to M1.
  Hash.lua           31-bit integer hashing. Hash.state(sim) is the stateHash the heartbeat
                     carries; Hash.log(sim) is logDigest. No floats, no bitwise ops, no
                     tostring - all three would differ across Lua versions. UNCHANGED by
                     M3: every card field landed in state the hash already walks.
  Rand.lua           the sim's own integer LCG. See rule 3.

fog/                 THE FOG OF WAR MODEL (../docs/IDLE_BATTLE_FOG.md), and a
                     SIBLING of sim/ rather than a file inside it. The reason is
                     A.5 grep 1: greps.sh and greps.lua DISCOVER their file list
                     from sim/ and assert that nothing in it can ask what is
                     visible. Put the fog model in there and that sentence
                     becomes self-referential -- the directory that must not be
                     able to ask now defines the answer -- and M7's proof ("a
                     match with Fog stubbed to always-true hashes identically")
                     stops being possible without editing sim/. Outside sim/ the
                     guarantee is structural: there is no fog module in the sim's
                     require namespace at all. HELD TO THE SIM'S DETERMINISM
                     RULES, because the M2 policies consume it.
  Fog.lua            section arithmetic derived from the ruleset, per-entity
                     visibility for enemy units / buildings / keep, CONTACT
                     REVEALS (doc section 3a -- you see what you are fighting,
                     entity-scoped, read off the sim's own targeting predicate),
                     the front-slot shield, and the per-side MEMORY store --
                     which lives here and NOT in sim state and NOT in
                     Hash.state, for the three reasons its own MEMORY block
                     gives. SINCE M3 PART 2 it also holds the EFFECTS block:
                     Divination, Omen, Veil (the precedence rule is ONE
                     sentence, stated at veiled()) and the Shrine reveal
                     pulse, consuming sim/Mods.lua's INFO_EFFECTS handoff and
                     the hashed SHRINE_PULSE_* constants, with the memory
                     store grown into THREE parallel layers (full / scry /
                     occupancy) composed in exactly one place,
                     believedBuilding().

tools/               checkers and the first test suite. NOT held to the sim's determinism
                     rules - these run on one machine and may use io, os and pairs freely.
  ci.sh              THE M1 GATE. greps + comptest + luac -p + BOTH suites. Run this.
  m2.sh              THE M2 GATE, beside ci.sh where a future engineer will look
                     for it. A front door onto sweep/run.sh; its header argues
                     why M2 is a sibling of the M1 gate and not a step inside it.
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
  fogtest.lua        EVERY RULE IN docs/IDLE_BATTLE_FOG.md, ONE AT A TIME, each
                     against a hand-built board and each asserted with its
                     NEGATION -- visible here, invisible one section away. Also
                     asserts the two things nothing else can see: that fog memory
                     does not move stateHash, and that the muster bar is DELETED
                     rather than disabled. Runs inside the M1 gate. SINCE M3
                     PART 2: 667 checks -- a section per information card, the
                     Veil precedence route by route, the three-layer memory
                     composition, tower/card compositions from both seats, and
                     a MUTATION suite (each effect disabled in a /tmp copy of
                     Fog.lua -> its named checks must flip).
  m3.sh              THE M3 GATE, beside ci.sh and m2.sh where gates live: each
                     of the 40 cards individually (vs-empty + mirrored), 200
                     random dual loadouts, the clamp-saturation report, a
                     verdict with hard exit codes. Its header argues why it is
                     a sibling of ci.sh rather than a step inside it. Run it
                     twice (Lua + LuaJIT) and compare the printed SUITE HASHes.
  m3gate.lua         the implementation m3.sh fronts: the frozen seed
                     schedules, the four arrival patterns per log via
                     harness/runner.lua, verb-atom injection for the three verb
                     cards, and the clamp report read off installed sims' own
                     sd.chan plus card-table maxima -- with the applied-value
                     probe (real Spear deploys against independently clamped
                     arithmetic; M3 fix pass, item 3) as the step's
                     falsifiable half.
  m4.sh              THE M4 GATE, beside its three siblings: greps + comptest
                     over net/ (the strict sim mode), luac, then
                     harness/m4run.lua's five steps. Its header argues why it
                     is a sibling of ci.sh and prints what a green run does
                     NOT prove (no real channel, no halt/resume, one
                     process). Run it twice and compare the four per-step
                     SUITE HASHes.
  syncaddon.sh       M5: the ONE bridge between this tree and the DEV addon.
                     Copies the eight engine files the addon mounts into
                     dev/PengyouGamesDev/IdleBattle/ (byte-identical),
                     generates HandLog.lua there from harness/logs/hand.iblog
                     plus the committed goldens in harness/selftest.lua, and
                     LOADTESTS the addon's actual .toc order headless with
                     require() disabled. --check proves all of it instead of
                     writing it. THE HEADLESS TREE IS EDITED AND THE ADDON IS
                     SYNCED, NEVER THE REVERSE -- an edit made in the copies
                     is a second, untested game that no gate here reads, and
                     --check exists to turn that state into a red build.

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
  m4run.lua          M4's implementation: net matches (two Net endpoints over
                     one Transport, driven off harness/gen.lua logs at
                     issue = exec - ORDER_DELAY), the three-way comparison
                     (ep1 == ep2 == a no-netcode reference run of the SAME
                     issued atoms, at every epoch), the codec/malformed fuzz,
                     the forced-desync hook, and the per-step suite hashes.

net/                 M4. THE WIRE AND THE RELIABILITY SHIM, headless. HELD TO
                     THE SIM'S DETERMINISM RULES in full (greps + comptest run
                     over it in tools/m4.sh), because every file here decides
                     sim outcomes: the codec decides what a peer's atom says,
                     the transport decides WHEN it says it, and the shim
                     decides how the sim is repaired when it says it late.
                     Nothing in sim/ was touched to build any of it.
  Wire.lua           the A.11 codec: the 6-byte EEE/K/T/N atom (base-36 exec
                     tick, CASE-SENSITIVE kind letters per A.11.2 -- the
                     unit and building letter tables are DERIVED from the
                     hashed ruleset; the three verb letters I/E/L are the one
                     hand-written set, in Wire, Sim and m4run alike - drift
                     there is loud (encode error / refused atoms) but it is a
                     copy, review finding 4), the 5-byte prologue, and encode/decode for
                     S C H X K G N M Q V. Encode raises on out-of-range
                     fields and on anything past the 200-byte budget (a
                     construction-time guarantee); decode NEVER raises on
                     wire input -- malformed is rejected with a reason.
                     OPEN/JOIN are deferred to M5 (they are the addon
                     layer's rows); X/K/G/V round-trip here but nothing in
                     M4 acts on them (M6).
  Transport.lua      the fake lossy channel: two endpoints in one process,
                     per-message verdicts (drop / delay 1..30 ticks /
                     reorder-past-the-jitter-window / duplicate) drawn from
                     per-direction sim/Rand.lua streams, so every run is a
                     pure function of the seed. Enforces the real channel's
                     shape: a message over 255 bytes is a hard ERROR at
                     send, never a delivery. Jitter is SIM TICKS of the
                     harness clock; no wall clock exists here.
  Snap.lua           A.12's snapshot: layout-aware full-sim copy and
                     IN-PLACE restore, OUTSIDE sim/ (the file's header
                     argues why). bucket and seen are REBUILT from the
                     copied log rather than copied, so there is no second
                     copy of the canonical order to drift; per-phase scratch
                     is reset, which fuzz mode B already proves harmless.
                     EVERY restore re-hashes and errors unless the restored
                     sim equals the captured hash -- the copy-coverage guard
                     that makes an outside-the-sim snapshot safe to trust.
  Net.lua            the A.12 shim: per-sender seqs and dedup, ackThru on
                     every message, receiver-driven N (spanning the missing
                     range) plus the 2-heartbeat sender backstop, the
                     ORDER_DELAY input contract, bounded rollback off the
                     snapshot ring (SNAPSHOT_EPOCH x SNAPSHOT_KEEP, C.1),
                     epoch-hash exchange with the SETTLED-comparison rule,
                     and the Q full-log recovery: fresh S + fresh H + the
                     entire own-command history as verbatim C batches, the
                     requester rebuilding from tick 0 out of (rules, seed,
                     BOTH loadouts, everything retained + replayed).

policy/              M2. The scripted hands on the mouse. HELD TO THE SIM'S
                     DETERMINISM RULES, because a policy WRITES the command log:
                     one that reads a clock or rolls math.random makes the two
                     clients play different matches while every M1 check stays
                     green. greps.sh, greps.lua and comptest.sh all run over
                     this directory.
  Policy.lua         the interface a line implements, the read-only view it is
                     handed (a flat table of integers, rebuilt each poll -- a
                     policy holds no reference to the sim at all), the order
                     constructors, and the per-match instance with its own
                     sim/Rand.lua stream. Also owns THE INFORMATION REGIME
                     (M.VISION: "fog", which applies fog/Fog.lua to the foe half
                     of the view, or "full", Ruling 1's shared state unfiltered)
                     and asserts A.11.4's wire budget against
                     POLL/MAX_ORDERS_PER_POLL at load time. It CONSUMES the fog
                     model and does not implement one: the renderer must apply
                     the same rules, and two implementations of "what can be
                     seen" would be two different games. SINCE M3 PART 2 the
                     view carries the card-shaped fields, all filled through
                     fog/Fog.lua: the per-lane omen channel and believed
                     occupancy, the Q9b marks (scried/omened/scanned) and the
                     scan flag. No shipped line reads any of them (open item
                     24).
  lines.lua          the seventeen lines, four per family plus `Pathfinder` in
                     mixed, one parametric engine and seventeen configurations.
                     Each carries a note saying which Part B or Part C claim it
                     is testing. Every line declares ONE attention trigger
                     (`reactAt`), whether it BUYS SIGHT (`scout`) and HOW OFTEN
                     (`scoutEvery`), and line() enforces the relationships at
                     load: a line that buys nothing may not name a threshold
                     below REACT_MIN (the midline) or a cadence at all, a line
                     that declares a scout may go as deep as SCOUT_SIGHT and no
                     deeper, and no line may refresh faster than
                     SCOUT_EVERY_MIN. FIVE of the seventeen scout --
                     `Pathfinder` at the floor cadence and Raid-counter,
                     Turtle-eco, Counterpunch and Adaptive at the default one --
                     and the other twelve are the controls that make them
                     readable. See Findings 7, 8, 9 and 10.

sweep/               M2. The match driver, the round-robin, and the statistics
                     needed to tell a finding from a coincidence.
  driver.lua         ONE MATCH: two lines, a seed, a ruleset. The only place the
                     two worlds meet, and the only file that can let a policy
                     cheat -- so everything that could is named in its header.
                     Sim-affecting, and checked as such.
  measure.lua        THE ROUND-ROBIN, as a measurement: returns integers, prints
                     nothing, asserts nothing. Owns the FROZEN seed schedule, the
                     single transcription of C.6's published table, and Part E's
                     thresholds -- so the four consumers below cannot drift
                     apart or quote three different copies of Part C at once.
  sweep.lua          THE REPORT. C.6's own table, in C.6's own order, three
                     columns wide (measured / published / delta) with every
                     delta past 5 points marked "!" and past 10 marked "!!".
                     Always exits 0: a report that aborts on the first bad
                     clause hides the ten metrics below it.
  verdict.lua        THE GATE. Part E's milestone, asserted, one screen, exits
                     non-zero. Re-runs the same frozen seed schedule in its own
                     process, so a number that differs between the report and
                     the gate is a policy-layer determinism bug neither could
                     have caught alone.
  fogaudit.lua       WHICH LINES ARE WRITTEN AGAINST A BOARD THE FOG NEVER
                     DRAWS, AND HOW MUCH OF IT ANY LINE EVER LOOKS AT. Its
                     `EYE` column -- the share of lane-polls in which a line
                     can see ANY part of the enemy half -- is the one to read
                     when the question is what a scout bought; `lit` is a mean
                     over 8 sections and a tripwire lights one of them, so it
                     cannot resolve the answer (Finding 10).
                     Per line and per regime: whether the line DECLARES a scout,
                     the lowest own-frame position it ever sees an enemy unit at,
                     the share of its own threat detections that happen at or
                     below the midline (the fog's DEFECT under `full`, the
                     scout's DIVIDEND under `fog`), the mean sections of a lane
                     it has LIT and has ever SEEN out of 8, and the share of its
                     decisions taken against an enemy half showing nothing
                     whatever. It rides on driver.run's `onPoll` tap, whose
                     return value the driver discards, so the counts describe the
                     sweep the GATE measures rather than a second,
                     differently-driven one.
  scoutprobe.lua     WHAT BUYING SIGHT IS WORTH, and it is the controlled half
                     of Finding 9. Three rosters differing in nothing but the
                     scout and the threshold it makes satisfiable, over one
                     frozen seed schedule: no sight, sight with the old
                     threshold, sight with the threshold restored. B-A prices
                     the BODY, C-B prices the THRESHOLD. Diagnostic; exits 0;
                     builds its variants as copies so the shipped roster is
                     never mutated.
  famstat.lua        Is the failing clause measurable? Four tests: a permutation
                     null for the family label, a seed-noise floor with the
                     roster held fixed, an exact roster jackknife, and the
                     building-spend correlation with its own null. The answer
                     turned out to be no, which is the largest finding in M2.
  probe.lua          What ONE building costs, against a control line identical
                     in all nineteen configuration fields except its opening.
                     Carries a standard error on every row, because the whole
                     question is whether a 6-point gap is a fact or a coin.
  determinism.lua    the policy layer's own M1: byte-identical atoms on replay,
                     isolation between matches, an exact mirror when the seats
                     are swapped, and no order bypassing the sim's input gate.
  run.sh             the M2 gate's implementation: greps, comptest, luac,
                     determinism, the report, then the verdict. tools/m2.sh is
                     the front door onto it.

README.md            this file.
```

`sim/` and `fog/` are loaded two ways and must stay loadable both ways. Under the harness it
is `require("sim.Sim")` / `require("fog.Fog")`. Inside WoW there is no `require`, so each
file falls back to a global
`IB_SIM_MODULES` table that the addon's load order must populate first
(`local Hash = IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")`).
`comptest.sh` warns about this on every file that uses `require`, deliberately - it is the
one WoW-shaped assumption left in headless code.

---

## The four greps (A.5)

| # | Rejects | Because |
|---|---|---|
| 1 | in mode `sim`: `Fog.`, any visibility predicate, any render-layer or WoW-UI symbol. In mode `client`: the same, except that `Fog.` is allowed **only** in a file that requires `"fog.Fog"` | Fog of war is a pure render filter (Ruling 1). A sim that can ask what is visible can branch on it, and the two clients do not have the same renderer state. M7's real proof is that a match with the fog model stubbed to always-true produces a bit-identical hash. The two modes and why the scope is explicit are below the table. |
| 2 | `FullName`, `myName`, `UnitName`, the `"player"` token, any identifier containing `player` | A.2. Sides are 1 and 2. |
| 3 | float literals, exponent literals, `/` outside `math.floor(...)`, bare `floor(` without the `local floor = math.floor` alias | rule 1 |
| 4 | `pairs(`, `next(`, and `table.sort(` (flagged for hand-verification, since a comparator that ever compares table identity is a desync) | rule 2 |

**GREP 1 NOW HAS AN EXPLICIT SCOPE, AND THAT IS A CHANGE WORTH READING.** "Zero references
to `Fog.`" is a statement about the SIMULATION. The renderer (M7) and `policy/Policy.lua`'s
view builder are CLIENTS -- they are the layer fog exists FOR, and a client that cannot name
the fog module cannot apply fog. Before `fog/Fog.lua` existed, grep 1 over `policy/` was
vacuously true, and vacuous truth is not a check. So both implementations take a MODE:

| mode | grep 1 asserts | run over |
|---|---|---|
| `sim` (default) | nothing in this directory references `Fog.`, `IBFog`, a visibility predicate, a render-layer symbol or a WoW UI API | `sim/`, and `fog/` |
| `client` | a file may say `Fog.` **only if it requires `"fog.Fog"`**, the one audited model. Every other grep-1 pattern still fires | `policy/`, `sweep/` |

This is a per-directory scope chosen by the caller and printed in the output; it cannot
silence a line, and it is deliberately not the alternative on offer -- renaming the import
so `Fog.` never appears would make grep 1 pass over a directory that genuinely consults
visibility, and these checkers **prefer a false positive to a miss**. `fog/Fog.lua` itself
runs in the strict `sim` mode and passes with zero hits: it defines the model through a
plain module table and never reaches for a render layer or a WoW API.

`tools/greps.lua`, the independent Lua implementation, carries three more that the shell
one does not: no clock, no `math.random`, and **grep 8 - no duplicate key in one table
constructor**. Lua keeps the last of `{ minStack = 3, ..., minStack = 1 }` and says nothing;
`luac -p` accepts it and the constructor function cannot see it, because the literal has
already collapsed by the time any code runs. That shipped a defence line whose source
declared `minStack = 3` and which ran with 1, worth 25pp on that line and 2.3pp on the
statistic the M2 milestone gates on. Both gates now run both implementations over every
sim-affecting directory.

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
9. **Touching what anything can SEE?** It goes in `fog/Fog.lua` and nowhere else, and
   `tools/fogtest.lua` gets a case for it. Two implementations of "what is visible" -- one
   in the renderer and one in the policy view -- are two different games, and the whole
   reason fog is a separate module is that M7 and M2 must apply the same rules. Nothing
   under `sim/` may reference it; A.5 grep 1 enforces that and must stay in `sim` mode.
10. **Adding to fog memory?** It stays OUT of `Hash.state`. Memory is a fold over the
   hashed state trajectory plus a side index, the sim never reads it, and a divergence in
   it is a rendering bug rather than a forked match -- so hashing it would make `ci.sh`, the
   determinism gate, go red for something that cannot affect a match. Extend `Fog.memHash`
   instead, which `sweep/determinism.lua` asserts across replays.

---

## What M2 is, and what it found

Part E states the milestone:

> 1,000 simulated matches terminate - by razed keep or by clock - reproducing C.6 within a
> few points: **median 380-430 s, >=75% inside the 5-10 minute band, >=80% decided by a razed
> keep, family spread under 10pp.** This is where Part C gets its first test in the shipping
> language rather than in Python, and where the two models are cross-checked. **A disagreement
> between the Lua sim and the Python sim is a finding, not a nuisance.**

> ### EVERY NUMBER IN THIS SECTION IS VOID. READ THIS BEFORE READING ANY OF THEM.
>
> The owner defined fog of war on 2026-08-13 (`../docs/IDLE_BATTLE_FOG.md`, binding, and
> it supersedes `IDLE_BATTLE_DECISIONS.md` Q9a). Every fogged column below was measured
> against a **three-bucket "muster bar" that this implementation invented** because fog had
> never been specified, and section 8.1 of the new doc deletes it: *"This replaces the
> muster bar entirely. There is no aggregate signal about the enemy half... the derived
> 2,800/5,600 HP thresholds are void."* Section 8.4 says the same thing about the numbers:
> *"Expect the M2 distribution to move, and treat pre-fog measurements as void rather than
> as a baseline."*
>
> The muster bar has been deleted from the tree, the model it is replaced by is
> `fog/Fog.lua`, and the regime is renamed `a3` -> `fog` so no old number can be quoted as
> comparable. **The tables below are kept, unedited, as the RECORD OF WHAT WAS MEASURED
> UNDER A GUESS.** They are not a baseline and no clause verdict in them is current. Run
> `tools/m2.sh` for numbers under the model that ships. **Finding 8 is what changed and
> what it means; read it first.**
>
> What is NOT void: Finding 4 (Q10's tiers never fire -- a structural claim about an exact
> integer tie), Finding 6 (peak concurrent units -- identical under both regimes), the
> full-information column as an upper bound, and `rulesHash 297242539`. **Nothing in
> `sim/Rules.lua` moved in this pass either.**
>
> **THE CURRENT FOGGED NUMBERS ARE IN FINDING 10** -- 1,632 matches under `fog/Fog.lua`
> WITH the owner's section 3a contact reveal, played by a seventeen-line roster that now
> spans the sight axis: median **426 s PASS**, band **76.1% PASS**, razed keep **80.1%
> PASS**, family spread **16.8pp FAIL**. M2 is still RED. At seed base 500000 only family
> spread fails; at 600000, 700000 and 800000 the razed-keep clause fails too and at 600000
> so does the median, so **which clauses fail moves with the seed again** -- the table in
> the M2 section has all four bases.
>
> **Finding 9's fogged column is now the BEFORE column of Finding 10**, and Finding 8's is
> the before column of Finding 9. Each measured the same ruleset under a different fog
> model or a different roster; none of them is a current reading.

**How to tell: run `tools/m2.sh` and read the last line.** THE CURRENT TABLE IS IN
FINDING 10; the one below it is Finding 9's and the one below that is the muster-bar record
and is void.

**CURRENT, seed base 500000, 1,632 matches (17 lines, all 272 ordered pairs, 6 seeds each).
The two columns to the right of the gate are what each half of the last pass did, and they
are separable because the first half changed nothing but the fog model:**

| Milestone clause | target | **fog, contact + sight axis - THE GATE** | *fog, contact only (16 lines)* | *fog, before this pass (Finding 9)* |
|---|---|---|---|---|
| median match length | 380-430 s | **426 s PASS** | *414 s PASS* | *406 s PASS* |
| inside the 5-10 minute band | >= 75% | **76.1% PASS** | *75.3% PASS* | *72.5% FAIL* |
| decided by a razed keep | >= 80% | **80.1% PASS** | *80.9% PASS* | *80.0% PASS* |
| family spread | under 10pp | **16.8pp FAIL** | *14.7pp FAIL* | *11.6pp FAIL* |

Both regimes, from `tools/m2.sh` on the shipped tree, seed base 500000:

| Milestone clause | target | fog (THE GATE) | full (upper bound) |
|---|---|---|---|
| matches simulated | >= 1,000 | **1,632 PASS** | 1,632 PASS |
| every match terminated | 0 unfinished | **0 PASS** | 0 PASS |
| median match length | 380-430 s | **426 s PASS** | 434 s |
| inside the 5-10 minute band | >= 75% | **76.1% PASS** | 77.3% |
| decided by a razed keep | >= 80% | **80.1% PASS** | 78.2% |
| family spread | under 10pp | **16.8pp FAIL** | 13.8pp |
| no order bypassed the input gate | 0/0/0/0/0, <= 120 atoms/min | **0/0/0/0/0 @20 PASS** | 0/0/0/0/0 @21 PASS |

**AND THE SEED BASE STILL DECIDES WHICH CLAUSES FAIL, WHICH IS A LOSS THIS PASS SHOULD BE
READ AS OWNING.** `lua sweep/verdict.lua 6 <base> fog` on the shipped tree:

| seed base | median | band | razed keep | spread | clauses |
|---|---|---|---|---|---|
| 500000 | 426 s | 76.1% | 80.1% | 16.8pp | RED: **spread** |
| 600000 | 432 s | 77.8% | 79.1% | 15.9pp | RED: **median keep spread** |
| 700000 | 428 s | 77.6% | 78.0% | 14.6pp | RED: **keep spread** |
| 800000 | 426 s | 77.2% | 78.3% | 15.5pp | RED: **keep spread** |

**The band clause now passes at all four bases having failed at all four; the razed-keep
clause now fails at three of four having passed at all four by a tenth of a point.** The
first is contact reveal and it is a fix to the instrument (Finding 10, and the A/B holds the
roster and the seeds fixed). The second is the seventeenth line: at base 500000 contact
alone moved razed keeps 80.0% -> 80.9% and adding `Pathfinder` moved them back to 80.1%,
and blinding `Pathfinder` moves them by 0.2pp -- so it is the line's PRESENCE and not its
scouting. **A milestone clause that moves 2pp when one line of seventeen is added is
measuring the roster**, which is Finding 2's conclusion arriving for the third time from a
third direction.

Status at 1,440 matches **per
information regime** (16 lines, all 240 ordered pairs, 6 seeds each), Lua 5.5.0 / arm64
macOS, `rulesHash 297242539`, seed base 500000. **VOID -- measured under the muster bar,
see the block above:**

| Milestone clause | target | **A.3 fog - THE GATE** | *before recalibration* | full information | *before* |
|---|---|---|---|---|---|
| matches simulated | >= 1,000 | **1,440 PASS** | 1,440 PASS | 1,440 PASS | 1,440 PASS |
| every match terminated | 0 unfinished | **0 PASS** | 0 PASS | 0 PASS | 0 PASS |
| median match length | 380-430 s | **432 s FAIL** | *428 s PASS* | 419 s PASS | *414 s PASS* |
| inside the 5-10 minute band | >= 75% | **76.5% PASS** | *74.7% FAIL* | 76.7% PASS | *76.8% PASS* |
| decided by a razed keep | >= 80% | **75.9% FAIL** | *75.6% FAIL* | 80.6% PASS | *80.9% PASS* |
| family spread | under 10pp | **13.8pp FAIL** | *22.9pp FAIL* | 16.6pp FAIL | *14.2pp FAIL* |
| no order bypassed the input gate | 0/0/0/0/0, <= 120 atoms/min | **0/0/0/0/0 @21 PASS** | *same* | 0/0/0/0/0 @21 PASS | *same* |

**SUPERSEDED BY FINDING 8 -- READ THE BANNER ABOVE. M2 IS STILL RED, but on the BAND (and,
at one seed base of two, family spread), not on the three clauses named below.** The
paragraph that follows describes the muster-bar roster and is kept as the record of it.

**M2 IS STILL RED, on three clauses, and they are not the same three.** The *before*
columns are the roster as it stood when eleven of the sixteen lines were reacting to a
position A.3 never renders; the bold columns are the same sixteen lines expressed in terms
the fogged board actually supplies. **Nothing in `sim/Rules.lua` moved to produce either
column and `rulesHash` is still 297242539.** Finding 7 is the recalibration, what each
change was made FOR, and what each one alone moved.

The short version: **the band clause was an artefact of a mis-calibrated roster and passes
now; the razed-keep clause is not and did not move (-4.1pp from target, was -4.4pp); the
family-spread clause halved and still fails by 3.8pp; and the median clause has crossed the
430 s ceiling and now fails at every seed base sampled.**

**And unlike before, WHICH THREE FAIL NO LONGER MOVES WITH THE SEED.** At seed bases
500000 / 600000 / 700000 / 800000 the fogged column now fails `median keep spread` at all
four. The band clause -- which the previous version of this README correctly called "a coin
whose result was reported as a measurement" -- now passes at all four (76.5 / 76.4 / 76.1 /
75.5%), though 75.5% against a 75.0% threshold is still inside its own standard error. The
full table is in Finding 7.

**The gap between the two regime columns is the largest thing M2 found, and it is
Finding 1.** Nothing in `sim/Rules.lua` was changed to produce any of these numbers, and
`rulesHash` is still 297242539: every fix in this pass is in `policy/`, `sweep/` or
`tools/`.

Full length distribution against C.6's, in seconds, both regimes:

| | p10 | p25 | median | p75 | p90 | mean |
|---|---|---|---|---|---|---|
| this sim, A.3 fog | 195 | 307 | **432** | 592 | 600 | 424 |
| this sim, full info | 193 | 308 | **419** | 551 | 600 | 415 |
| C.6 (Python) | 233 | 310 | **406** | 526 | 600 | 412 |
| delta (fog - C.6) | -38 | -3 | **+26** | +66 | 0 | +12 |

**Where the two models are comparable, they agree to within a couple of points. Where
they disagree, it is on the metrics that are computed from the sixteen policies rather
than from the sim** - and Part C did not record its sixteen policies, nor which information
regime they played under. That distinction is the spine of everything below.

Nine findings, in descending order of how much they should change the document. All nine are
reproducible from this tree with the commands given. **Findings 1, 2, 3 and 6 correct
earlier entries in this README**, which were written under an unstated information regime,
from the round-robin alone, at one seed base, and - for one of the sixteen lines - against
a config the source did not declare:

> **The roster itself had a bug, and every M2 number in this README moved when it was
> fixed.** `Counterpunch` set `minStack` twice in one table constructor; Lua silently keeps
> the last, so a line whose source declared `minStack = 3` shipped running 1. `luac -p`
> accepts that, and `Policy.define` cannot see it because the literal has already collapsed
> before any code runs. One dead assignment was worth 25pp on that line, 4.8pp on the
> defence family, and 2.3pp on the exact statistic the milestone gates on; it also put
> decision-leverage-low 13pp away from C.6 where the corrected roster agrees to 3.1pp.
> **`tools/greps.lua` grep 8 now fails the build on a duplicate key in any table
> constructor, and both M2 and M1 gates run it.**

### Finding 10 - CONTACT REVEALS, and a roster that finally spans the sight axis. The band clause was an instrument defect and it is now green; the scouting half bought nothing measurable and that is the finding

`lua tools/fogtest.lua` proves the model (464 checks, was 335); `lua sweep/fogaudit.lua`
sizes what the roster can see; `lua sweep/verdict.lua 6 <base> fog` re-measures. **This
finding closes open item 13, rewrites open item 17, and opens open item 19.**

**PART ONE: THE OWNER RULED, AND IT WAS A TWO-SIDED DEFECT RATHER THAN THE ONE THAT WAS
REPORTED.** `IDLE_BATTLE_FOG.md` section 3a: *"A unit also reveals any enemy entity it is in
combat with, whatever section that entity is in. You can see what you are fighting."* The
half that was in open item 13 is the attacker: melee range is 60 and their wall is at
observer 1,300, so `BUILD_BLOCKS_ADVANCE` parks the attacker at 1,240, which is section 5,
and it could not see the building it was destroying. **The half nobody had written down is
the defender, and it is the bigger one.** Two Spears deployed on the same tick meet 60 apart
at own-frame 970 and 970 -- so the defender is standing in its own section 4 and the stack
killing it is in section 5, and under the section rule alone *a defender could not see the
army it was fighting in its own half's doorway*. `tools/fogtest.lua` section 15 marches both
boards rather than asserting them.

**HOW CONTACT IS DETERMINED, AND IT IS THE SIM'S OWN PREDICATE RATHER THAN A SECOND ONE.**
An enemy entity is in contact with one of your units when it is inside that unit's weapon
envelope -- `|observer coordinate of the entity - my unit's position| <= my range` -- which
is character for character the test `Sim.unitAttacks` applies when it picks a target. Three
consequences, each of which was a choice and each of which is in `fog/Fog.lua`'s CONTACT
block:

| question | answer, and why |
|---|---|
| the envelope or the victim the resolve loop picked? | THE ENVELOPE. Combat resolves every 5 ticks and picks at most `targets` of them; vision is per tick and per entity. Otherwise a Bow among five bodies would see three, and WHICH three would depend on entity ids. |
| whose range? | THE OBSERVER'S. Symmetric for every melee engagement in C.3 (both are 60), so a defender sees its attacker. NOT symmetric when the shooter outranges the target. Open item 19a. |
| does it light the section? | NO. Entity-scoped, and it is structural: `visibleSections` is untouched, so `lit`, `seen` and section memory are exactly what they were. The audit's `lit` column not moving is the check. |

**AND IT MOVED THE CLAUSE THE MILESTONE HAD BEEN FAILING AT EVERY SEED BASE.** Same
sixteen lines, same seeds, same ruleset -- the ONLY change is the fog model, so this column
pair is a clean A/B and the rarest thing in this README:

| clause | before (Finding 9) | + contact reveals | moved by |
|---|---|---|---|
| median match length | 406 s PASS | **414 s PASS** | +8 s |
| inside the 5-10 minute band | **72.5% FAIL** | **75.3% PASS** | **+2.8pp** |
| decided by a razed keep | 80.0% PASS | **80.9% PASS** | +0.9pp |
| family spread | 11.6pp FAIL | **14.7pp FAIL** | +3.1pp |

**The band clause had failed at all four sampled seed bases and at every roster this
README has published, and it was 2.5pp short. It was not a balance problem. It was a
defender that could not see the army in front of it**, answering late, losing fast, and
ending matches under five minutes. The share of a line's decisions taken against an enemy
half showing nothing at all (`blind`) fell across the whole roster at once, **7.6-22.6% ->
5.9-13.5%**, which is the mechanism in one column.

**PART TWO: THE ROSTER NOW SPANS THE SIGHT AXIS, WHICH IT DID NOT BEFORE.** Finding 9 gave
four lines a scout; `sweep/fogaudit.lua` then measured `lit` at 4.23-4.83 sections out of 8
against a free floor of 4.00, with the four scouts *indistinguishable* from the twelve blind
lines. Every scout bought sight at exactly one rate, so the roster had one point on the axis
and no way to price the mechanic. Three changes, in the order they were decided:

1. **`scoutEvery` is a declared per-line field**, defaulting to the derived one-lane cadence
   (220 ticks) and floored at a second derived constant, `SCOUT_EVERY_MIN` = 86 -- one
   traversal split across the three lanes there are to watch, plus one order delay. Below
   that a line is buying a second pair of eyes for ground the first pair already lights.
   `line()` refuses a cadence under the floor and refuses one declared by a line that buys
   no sight at all.
2. **`Pathfinder`, a seventeenth line, whose whole identity is eyes**: a tripwire into its
   blindest lane at the floor cadence, no buildings, no economy, cheap bodies with whatever
   is left. It is an ADDITION and not a replacement -- every other line carries a Part B or
   Part C claim nothing else tests, and open item 10 says deleting lines biases family
   means. The price of adding is stated where it lands: **1,632 matches instead of 1,440,
   `mixed` is a five-line family, and every seed moves**, because the seed schedule is keyed
   to the ordinal of the ordered pair. So this half is a roster change measured at the same
   seed base and NOT the same matches replayed, and it is reported that way.
3. **`Policy.darkLane` ranks on `lit` before `seen`, and that is a bug fix.** It ranked on
   `seen` alone, which is cumulative and never falls: a line that scouts all match saturates
   all three lanes, ties, and sends every remaining body to lane 1 for the rest of the
   match. That is `pressedLane`'s defect (Finding 7) in a new place -- a tiebreak standing in
   for an answer. `lit` is the live term the mechanic is about, so coverage rotates to the
   lane whose section has just gone dark.

**WHAT IT BOUGHT, AND THE ANSWER IS "ALMOST NOTHING, MEASURABLY".** `Pathfinder` buys
**42.8 tripwires and 428 Levy a match, about a quarter of a side's base income.** Blinding
that one line and changing nothing else:

| | scouting | blinded | delta |
|---|---|---|---|
| `lit` (mean sections of 8) | 4.73 | 4.70 | **+0.03** |
| `EYE` (share of lane-polls with ANY live sight of the enemy half) | 44.5% | 40.5% | **+4.1pp** |
| whole-sweep median / band / keep | 433 s / 76.6% / 78.4% | 434 s / 76.4% / 78.6% | **nothing** |

**And the largest second-order move in the same table is +3.3pp**, on `Rush-spear`, which
changed in no way whatever and merely played a `Pathfinder` carrying 428 more Levy of
pressure. **The sight a scout buys, measured in sections, is inside the noise of what the
scout's own cost does to the match.** The ceiling is one section per living body, a lane is
eight sections, and a body sent into a contested lane never reaches the enemy half at all --
it halts 60 units short of whatever is holding the doorway, which the 970/970 board above is
the proof of.

**AND YET THE TRIPWIRES ARE WORTH 15.7pp OF WIN RATE TO THE LINE THAT BUYS THEM, WHICH
MEANS THE OBVIOUS CONCLUSION IS THE WRONG ONE.** `lua sweep/scoutprobe.lua 2 500000`, 544
matches per variant, the same roster with the scout removed and the thresholds put back to
the free floor:

| variant | median | band | razed keep | spread | `Pathfinder` |
|---|---|---|---|---|---|
| A no sight, thresholds at the free floor | 419 s | 73.8% | 80.5% | 16.4pp | **63.2%** |
| B + the body, thresholds unchanged | 427 s | 76.4% | 78.6% | 17.9pp | **75.7%** |
| C + the thresholds restored (**ships**) | 433 s | 76.6% | 78.4% | 18.5pp | **78.9%** |

**+12.5pp for the body and +3.2pp for the threshold, against a standard error of about 6pp
at 64 matches a line -- so the body is real and the threshold is not resolved.** Put beside
the `lit`/`EYE` table above, that is a contradiction worth stating rather than resolving
by picking the flattering half: **the tripwires are worth a great deal and the sections
they light are worth nothing measurable, so whatever they are buying is not the section.**
Two candidates, and this pass did not separate them:

1. **CONTACT, not illumination.** Since section 3a a body reveals whatever it bumps into,
   wherever that is -- and `lit` and `EYE` count SECTIONS, so they cannot see it at all. A
   tripwire that walks into a lane and meets something now renders that something. If this
   is the mechanism, the fog doc's "buy sight" mechanic works, but through 3a rather than
   through section 3, and the audit is measuring the wrong quantity.
2. **A SPLIT-PUSH BY ACCIDENT.** A 10-Levy body sent into the darkest lane is a body sent
   into the lane the enemy is NOT defending -- `darkLane` prefers exactly that -- and if it
   survives it walks 2,000 units to an undefended keep. Under this ruleset that may simply
   be a better use of 428 Levy than adding it to a concentrated attack, and the word
   "scout" would then be decoration on a distributed raid.

**Separating them is the next measurement and it is cheap**: a variant whose scouts are
bought and then held at the midline isolates illumination from contact from raiding. It is
named here rather than guessed at, and open item 17 carries it.

**`lit` IS A BAD INSTRUMENT FOR THIS AND THE AUDIT NOW SAYS SO.** A tripwire lights ONE
section of eight, so a line buying sight in a tenth of its lane-polls moves `lit` by 0.10
and looks identical to a line that bought nothing. `sweep/fogaudit.lua` now prints `EYE`
beside it -- the share of lane-polls in which this line can see any part of the enemy half
at all, which is the unit the decision is actually made in.

**THE `lit` STATISTICS, BEFORE AND AFTER, WHICH IS THE MEASUREMENT THAT WAS ASKED FOR.**
480-544 matches, fogged regime, `lua sweep/fogaudit.lua 2 fog`:

| roster | `lit` range | `blind` range | `EYE` range |
|---|---|---|---|
| before this pass (16 lines) | 4.23 - 4.83 | 7.6 - 22.6% | not measured |
| + contact reveals (16 lines) | 4.22 - 4.91 | 5.9 - 13.5% | not measured |
| + the sight axis (17 lines, SHIPS) | 4.24 - 4.91 | 5.5 - 13.0% | 14.8 - 53.2% |

**Contact reveals moved `lit` by nothing at all, which is the entity-scoped claim holding in
the aggregate**, and it moved `blind` by 6-9 points on every line. The scouting pass moved
`lit` by nothing either, and the reason is the mechanic rather than the roster. **The line
with the most sight in the roster is still `Skirmish` (`EYE` 53.2%), which buys none: it
trickles small stacks into three lanes and illuminates the ground it fights on.** After two
passes aimed squarely at this, vision in this sim is still overwhelmingly a by-product of
attacking, and that is a fact about the model and not about the sixteen -- now seventeen --
lines.

**AND THE UPPER BOUND SEPARATES THE TWO HALVES OF THIS PASS FOR FREE, WHICH IS THE
CLEANEST ATTRIBUTION IN THIS README.** Under `full` there is no fog to reveal anything
into, and `Policy.darkLane` returns 0 in every lane so not one scout is ever issued -- so
contact reveal and the whole scouting mechanic are BOTH inert in that column, and anything
it does move is the seventeenth line and the seeds:

| clause | full, before this pass | full, now | moved by |
|---|---|---|---|
| median match length | 420 s | 434 s | +14 s |
| inside the 5-10 minute band | 76.4% | 77.3% | +0.9pp |
| decided by a razed keep | 82.2% | **78.2%** | **-4.0pp** |
| family spread | 14.9pp | 13.8pp | -1.1pp |

**So the razed-keep clause fell because a seventeenth line was added to the pool, not
because of anything about sight**, and the median rose the same way. `Pathfinder` finishes
at **73.6%**, which makes it one of the stronger lines rather than the sacrificial probe it
was expected to be -- cheap bodies, a high `react` and a threshold at `SCOUT_SIGHT` are a
good strategy in this ruleset even when the sight it pays for cannot be measured. That is
worth stating precisely because it is the opposite of the result that would have flattered
the mechanic: the line wins with the eyes it buys, but blinding it does not move its
sweep (open item 17), so what is winning is the shape of the line and not what it can see.

**AND THE NEW TESTS HAVE TEETH, ASSERTED BY MUTATION RATHER THAN CLAIMED.** Five deliberate
breaks of `fog/Fog.lua`'s contact block, each run against `tools/fogtest.lua`'s 464 checks
and each reverted:

| mutation | result |
|---|---|
| contact is always true | 25 checks fail |
| the shield no longer outranks contact for the back slot | 9 fail |
| units get no contact route (buildings keep theirs) | 6 fail |
| contact also lights the section it reveals into | 2 fail |
| `unitReach` ignores the Fletcher aura, so it stops mirroring `Sim.unitRangeOf` | 2 fail |

The last one is the one worth having: it is caught by a BEHAVIOURAL check -- the sim itself
parks a Bow behind a Fletcher 326 units short of the wall -- so the fog model and the sim
cannot drift on what a unit can reach without the build going red.

**NOTHING IN `sim/Rules.lua` WAS TOUCHED. `rulesHash` is 297242539 before and after.**

### Finding 9 - the roster now BUYS SIGHT, and the measurement says the fog doc's own answer to the fog is under-powered

`lua sweep/scoutprobe.lua` decomposes it; `lua sweep/fogaudit.lua` sizes what it buys;
`lua sweep/verdict.lua 6 <base> fog` re-measures. **This finding replaces Finding 8's fogged
column with a current one and closes the first half of open item 17.**

**WHAT WAS WRONG, AND IT WAS NOT THAT ANY LINE COULD SEE TOO MUCH.** `Policy.fillFoe` had
already been written against `fog/Fog.lua` and it audits clean: enemy units only in sections
the observer lights, enemy buildings only out of frozen memory behind the front-slot shield,
enemy keep HP remembered, enemy Levy / bank / income / spend / loadout flatly zero.
Re-checking every field of the view against the doc turned up exactly **one** disclosure
route, and it is a contradiction between two documents rather than a bug -- `keepDamageDealt`
makes the enemy keep's exact live HP derivable with no sight at all, which is now open
item 18. **No line reads it.** So the defect was on the other side of the interface: the
sixteen lines were asking for perceptions the fogged board does not supply, and six of them
had been left with an intent that had no expression at all.

**AND THE FOG DOC ALREADY SAID WHAT THE EXPRESSION IS.** Section 3: *"send one cheap body
forward and you buy sight of exactly where it is standing, for exactly as long as it
lives."* A body in the first fogged section pulls the earliest satisfiable threat threshold
from own-frame 1,001 ("they are already in my half") down to **751** ("they are still 250
units short of it"). That is `Fog.SCOUT_SIGHT`, derived from the section table, and it is
what makes "answer a push before it arrives" a sentence again.

**FOUR LINES OF SIXTEEN BUY IT, AND THE TWELVE THAT DO NOT ARE THE MEASUREMENT.** The test
applied to every line was one question -- *does this line's own stated intent require a
perception the fog grants only to a body in the enemy half?* -- and the answer was written
down before the sweep was run:

| line | scouts | why, in its own words | `reactAt` |
|---|---|---|---|
| `Raid-counter` | **yes** | "the counter to what it SEES in the lane". With no sight bought, what it sees is what has already crossed -- the one moment a counter draw is worth least. | 1150, **unchanged**: its scout is for the type draw and the lane choice, not for the threat trigger |
| `Turtle-eco` | **yes** | "meet every push". A push is met at the midline or not at all, and the answer costs 2 s of order delay plus a march. | 1001 -> **751**. Its source said 700; a body would have to hold section 6 to deliver that, which is an attack and not a tripwire, so 751 is the nearest honest equivalent and the 50-unit concession is stated |
| `Counterpunch` | **yes** | its whole idea is holding a reserve and *swinging* it. There is no right moment without sight. | 1001 -> **900**, its original value **restored verbatim** -- 900 is inside the window one tripwire renders |
| `Adaptive` | **yes** | "the closest thing here to a person", and it has three sight-hungry sub-decisions at once: a reactive Arrow Tower keyed to enemy Levy in a lane, a counter draw, and "attack the lane they left open" | 1001 -> **900**, restored verbatim |
| `Turtle-pure`, `Wall` | no | the **defence controls**. `Turtle-pure` exists to ask whether a side that commits NOTHING forward can win on Q10's ladder; a body past the midline is a commitment forward. Their 600 and 800 are **dropped outright, not re-expressed.** | 1001 |
| `Trader` | no | the **reactive-build control for `Adaptive`**. The two are near-twins and exactly one of them buys the sight that lets the trigger fire in time to lay a 60-tick Trap Pit. | 1001 |
| `Skirmish` | no | the **exploration control**. It lights more of the board than anyone (`seen` 7.70 of 8) without ever spending a body ON sight, which is what separates "explores" from "scouts" in the audit. | 1100 |
| `Greed-pure` | no | its identity is the words *"before a single unit"*, and a tripwire is a unit. `line()` now refuses a line declaring both `scout` and `holdUntilBuilt`. **This is the one intent this pass deliberately left dead**; the alternative was making the pure-economy probe impure to improve its result. | 1001 |
| the other 7 | no | never claimed to read the enemy before contact. Notes corrected where they claimed otherwise (`Rush-horse`'s "least-defended lane" is a read it cannot make). | unchanged |

**THE SCOUT IS AN ORDER, NOT A PERMISSION, AND EVERY PART OF THE PRICE IS PAID.** One
cheapest body (`SCOUT_TYPE`, read off the hashed `UNITS` table, not named), refreshed no more
often than one lane traversal by that body plus one order delay (`SCOUT_EVERY = 220` ticks,
derived from `LANE_LEN / march + ORDER_DELAY`), bought after the same reserve as the army,
consuming one of the two orders that poll. **Nothing in either constant was chosen by
looking at a win rate.** Measured cost: **17-21 scout orders and 174-204 Levy a match**,
which against that line's own earned Levy is **12-14%** -- about an eighth of its economy. And the aiming rule (`Policy.darkLane`) reads
`lit`, `seen` and `maxPos` of the polled side's OWN lanes only -- a scout is never aimed
with the information it is being sent to fetch -- which also means it returns 0 when a lane
is fully visible, so **the full-information regime issues zero scout orders in a whole
sweep** and stays a real upper bound.

**WHAT IT BUYS, AND THIS IS THE PART THAT SHOULD REACH THE DOC OWNER.**
`sweep/fogaudit.lua`'s SUB-MID column under `fog` is the early-warning dividend: threat
detections that exist only because a body of that line's was standing in that section.
Beside it, the same column under `full` is what the fog takes away from that line:

| line | dividend (`fog`) | deleted by the fog (`full`) | recovered |
|---|---|---|---|
| `Turtle-eco` | **2.2%** | 9.3% | 24% |
| `Counterpunch` | **0.4%** | 5.6% | 7% |
| `Adaptive` | **0.5%** | 20.0% | 2% |

**So buying sight recovers under a quarter of what the fog deleted, for about an eighth of
that line's economy.** The mechanism is not mysterious and it is arithmetic rather than roster
luck: the window a tripwire at the midline opens is **250 units wide**, which is 12 sim
ticks of a Horse and 25 of a Spear, against an `ORDER_DELAY` of **20**. A warning shorter
than the order delay is not a warning. Open item 17 is rewritten around this.

**AND IT COSTS WIN RATE, WHICH IS REPORTED RATHER THAN DESIGNED AWAY.** 1,440 matches,
fogged, seed base 500000, per line (standard error ~3.7pp at 180 matches per line):

| line | scouts | before | after | delta |
|---|---|---|---|---|
| `Adaptive` | yes | 84.7% | **78.8%** | **-5.9pp** |
| `Counterpunch` | yes | 61.1% | **58.3%** | -2.8pp |
| `Turtle-eco` | yes | 37.7% | **35.5%** | -2.2pp |
| `Raid-counter` | yes | 66.1% | **68.3%** | +2.2pp |
| the twelve that do not scout | - | - | - | **+8.8pp in total**, none past 1 SE |

Three of the four lines that pay for sight are worse off and the fourth is inside its own
noise. **That is the finding.** It is not a reason to take the scout away again: the four
lines could not otherwise express what their sources say they are, and a roster that plays
a strategy nobody would choose because it scores better is the same defect as a roster that
cheats, wearing the other mask.

**THE CONTROLLED DECOMPOSITION, because a pass that moves milestone numbers has to say which
half moved them.** `lua sweep/scoutprobe.lua 2 500000` -- three rosters differing in nothing
else, 480 matches each:

| variant | median | band | razed keep | family spread |
|---|---|---|---|---|
| A no sight, thresholds at the free floor | 396 s | 71.2% | 81.4% | 9.5pp |
| B + the body, thresholds unchanged | 406 s | 72.7% | 80.6% | 9.6pp |
| C + the thresholds restored (**ships**) | 405 s | 72.7% | 80.4% | 9.2pp |

**The BODY moves the clauses and the THRESHOLD moves nothing** (`C - B` is +0.0pp on the
band, -0.2pp on razed keeps). Which is worth stating plainly: the part of this pass that
restores what the fog took away from three lines' *stated intent* is, on the aggregate
statistics, free -- and the part that costs is the 180 Levy. A reader looking for a roster
tuned to pass will not find it here; the change that would have been worth doing for the
numbers is the one that did nothing.

**THE MILESTONE, RE-MEASURED. STILL RED, ON THE SAME TWO CLAUSES.** 1,440 matches per
column, `lua sweep/verdict.lua 6 500000 fog`:

| Milestone clause | target | **fog, scouting roster - THE GATE** | *fog, before (Finding 8)* | full information | *full, before* |
|---|---|---|---|---|---|
| matches simulated | >= 1,000 | **1,440 PASS** | 1,440 PASS | 1,440 PASS | 1,440 PASS |
| every match terminated | 0 unfinished | **0 PASS** | 0 PASS | 0 PASS | 0 PASS |
| median match length | 380-430 s | **406 s PASS** | *395 s PASS* | 420 s PASS | *415 s PASS* |
| inside the 5-10 minute band | >= 75% | **72.5% FAIL** | *71.0% FAIL* | 76.4% PASS | *76.5% PASS* |
| decided by a razed keep | >= 80% | **80.0% PASS** | *82.5% PASS* | 82.2% PASS | *83.2% PASS* |
| family spread | under 10pp | **11.6pp FAIL** | *12.0pp FAIL* | 14.9pp FAIL | *16.4pp FAIL* |
| no order bypassed the input gate | 0/0/0/0/0, <= 120 atoms/min | **0/0/0/0/0 @21 PASS** | *same* | 0/0/0/0/0 @21 PASS | *same* |

**FOUR SEED BASES, BOTH ROSTERS, so nothing above is one draw.** `lua sweep/verdict.lua 6
<base> fog`:

| seed base | before: median / band / keep / spread | clauses | after: median / band / keep / spread | clauses |
|---|---|---|---|---|
| 500000 | 395 s / 71.0% / 82.5% / 12.0pp | RED: band spread | **406 s / 72.5% / 80.0% / 11.6pp** | RED: band spread |
| 600000 | 397 s / 71.8% / 82.9% / 12.2pp | RED: band spread | **403 s / 73.1% / 80.1% / 14.2pp** | RED: band spread |
| 700000 | 399 s / 72.2% / 81.8% / **8.7pp** | RED: **band only** | **406 s / 73.8% / 80.1% / 11.8pp** | RED: band spread |
| 800000 | 393 s / 71.2% / 84.0% / 15.7pp | RED: band spread | **406 s / 72.9% / 82.0% / 15.7pp** | RED: band spread |

**FIVE READINGS, INCLUDING THE TWO THAT GO AGAINST THE WORK.**

1. **The band clause is the stable failure and it moved toward its target without reaching
   it**: +1.3 to +1.7pp at every base, 72.5-73.8% against 75.0%, still 1.2-2.5pp short and
   well outside the ~1.1pp standard error. The mechanism is the same one Finding 8 named --
   with warning this thin, matches end fast -- and the scout shortens the under-five-minute
   tail without closing it (27.4% under the band, was 28.9%).
2. **The razed-keep clause went from comfortable to exactly on the line**: 82.5% -> 80.0% at
   base 500000, and 80.0-82.0% across the four. It still passes at every base, but a clause
   passing to the tenth of a point is not a clause anyone should quote as met. Matches got
   slightly less decisive because a tenth of two economies is now walking forward to look
   rather than to fight: clock matches 17.4% -> 19.9%, draws 0.6% -> 1.4%.
3. **Family spread improved at the base the README publishes and got WORSE at the base where
   it used to pass** (8.7pp PASS -> 11.8pp FAIL at 700000). That is Finding 2's conclusion
   arriving again from a new direction: a statistic that flips on the seed base is a coin,
   and this pass has now moved it in both directions without touching a rule.
4. **WHICH clauses fail no longer moves with the seed at all.** Before, one base of four
   failed a different set; now all four fail `band spread`. A verdict that does not change
   its mind when the seeds move is worth more than either of the clauses that moved.
5. **The full-information column barely moved, and that is a check on the work rather than a
   result.** Under `full` no scout is ever issued, so the whole roster change reduces to
   three restored thresholds -- and the column moves by +5 s, -0.1pp, -1.0pp, -1.5pp. If the
   scouting machinery had leaked one bit of unpaid-for information into the view, this is
   the column where it would have shown up as a gain.

**NOTHING IN `sim/Rules.lua` WAS TOUCHED. `rulesHash` is 297242539 before and after, `tools/ci.sh
1000` is GREEN (5/5 steps, 1000 logs, 19,644,042 ticks, 0 desyncs), `SUITE HASH` is unchanged
at 1404498451, and `tools/fogtest.lua` now runs 335 checks (was 289) -- a new section 14
that pins the scout's geometry and its NEGATION (one section deeper is not rendered), that
the sight dies with the body, that scouting is a declared minority property of the roster,
that both scout constants are derived from the ruleset, and that no line reads the one
disclosure route open item 18 is about.**

### Finding 8 - fog was specified, the muster bar was deleted, and the roster had NO pre-contact channel at all

**SUPERSEDED IN ITS NUMBERS BY FINDING 9, WHICH GAVE FOUR LINES THE ONE THING THIS FINDING
SAYS THEY WERE MISSING.** What survives is everything about the MODEL -- the section table,
what memory keeps, what the muster bar's deletion removed, the mutation testing, and the
argument for where memory lives. The fogged clause numbers below are Finding 9's *before*
column: they measure the owner's fog model played by a roster that never bought sight, and
the doc's own section 3 says that is not the game. Read them as the baseline for Finding 9
and not as a current verdict.

`lua tools/fogtest.lua` proves the model; `lua sweep/fogaudit.lua` sizes what it does to
the roster; `tools/m2.sh` re-measures. **This finding voids every PRE-fog number in this
README and supersedes the fog half of Findings 1 and 7.**

**WHAT THE OWNER SPECIFIED, and it is not what was implemented.** A lane is 8 vision
sections of 250 units. You always see sections 1-4 -- your half, out to the midline -- and
**nothing at all** in 5-8, so an approaching enemy is invisible until it crosses. One of
your own units makes visible **the section it is standing in and no other**. Anything you
have seen persists **frozen at its last-seen state**; enemy BUILDINGS and the enemy keep's
HP are remembered that way, enemy UNITS are not ghosted. Their back slot is visible only
when their front slot is empty or destroyed AND you have a unit in section 7. Enemy
economy and loadout are never visible by any route.

**WHAT THAT DELETES.** The old model's only pre-crossing signal was a three-bucket muster
bar driven by total marching HP, with thresholds this implementation DERIVED (2,800 /
5,600) because A.3 gave none - the one number in M2 that was neither in Part C nor forced
by it, escalated as open item 8. The new doc removes the signal rather than fixing the
thresholds. So:

| gone | replaced by |
|---|---|
| `Policy.MUSTER_*` (5 constants) and the per-lane `muster` field in the view | nothing. Section 2 of the doc: *"There is no early warning, no aggregate, no 'something is coming' indicator."* |
| `Policy.ALARM_PRESSURE / ALARM_HEAVY / ALARM_NEVER` and the `alarm` field on all 16 lines | nothing. A line's only trigger is `reactAt`, satisfied by a unit it can actually SEE. |
| the derived 2,800 / 5,600 HP cut points | nothing. Open item 8 is CLOSED by the doc. |
| `hp < maxHp` building disclosure (a building became visible by being damaged) | per-side MEMORY of the section you stood in. The old rule's inversion -- "there is a wall here AND I have already started chewing it" -- is gone. |
| enemy keep HP, exact from tick 0 | keep HP as last seen. This is a direct contradiction between A.3 and the fog doc; the fog doc is later and binding, so it wins. Flagged as an open item. |

**SIX LINES LOSE A CHANNEL AND NOTHING COMPENSATES THEM, WHICH IS THE POINT.**
*(FINDING 9 HAS SINCE COMPENSATED THREE OF THE SIX, BY MAKING THEM PAY FOR IT.
`Turtle-eco`, `Counterpunch` and `Adaptive` now buy sight; `Turtle-pure`, `Wall` and
`Greed-pure` deliberately still do not, and are the controls. The paragraph below is the
state this finding measured.)*
`Turtle-pure`, `Turtle-eco`, `Wall`, `Counterpunch`, `Greed-pure` and `Adaptive` all
declared `alarm = PRESSURE` -- an intent to answer a build-up before it arrived. Under the
section model that intent is only expressible by SCOUTING, and **not one of the sixteen
lines spends a body on sight.** Their `reactAt`, `react`, openings, mixes, cadences,
`minStack` and `convertAt` are untouched: this pass is the SUBTRACTION of a channel, not a
retune. **The roster was deliberately not re-tuned to recover what this costs**, and it
must not be - the doc says to expect the distribution to move, and a roster selected to
pass is as useless as a policy that cheats. That is the same refusal Finding 7 made about
the median clause, applied to a bigger change.

**THE LARGEST THING THIS OPENS UP, AND IT IS AN OPEN ITEM RATHER THAN A RESULT.**
*(DONE IN FINDING 9, AND THE ANSWER WAS NOT THE FLATTERING ONE: four lines now buy sight,
it costs ~180 Levy a match, and it recovers under a quarter of the warning the fog deleted.
The `lit` / `seen` reading below still stands for the twelve that do not.)* The doc
makes vision something you BUY: *"send one cheap body forward and you buy sight of exactly
where it is standing, for exactly as long as it lives... It also means vision is earned and
lost continuously through a match rather than being a fixed property of a build."* That is
a whole strategic axis the roster does not touch. `sweep/fogaudit.lua` now reports `lit`
and `seen` -- mean sections of a lane a line can see now, and has ever seen, out of 8 -- so
the gap is measured rather than asserted. **240 matches, fogged regime, all sixteen lines:**

| | floor | measured range | what it means |
|---|---|---|---|
| `lit` | **4.00** (the four free home sections) | **4.25 - 4.93** | a quarter to a full section of the enemy half is illuminated at any moment |
| `seen` | 4.00 | **4.91 - 7.72** | cumulative and never falls, so it climbs for lines that push |
| `minPos` | - | **0 for all sixteen** | every line sees an enemy unit at their-frame 0 at some point: a unit that reaches THEIR keep is in section 8 and watches their reinforcements spawn |

**AND THE READING IS THE OPPOSITE OF FLATTERING.** Every unit above the 4.00 floor is an
ATTACK that happens to illuminate the ground it is standing on. **Not one line in the
roster spends a body on sight.** So `lit` measures where the roster FIGHTS, not what it
chose to LOOK at, and `seen` is a proxy for aggression rather than for reconnaissance --
which is why `Skirmish` tops it at 7.72 and `Greed-pure`, which fields nothing for two
minutes, sits at 4.91. A deliberate scout would show as `lit` rising while the attack does
not. **Until one exists, the fogged sweep measures a game with a mechanic nobody is
playing**, and that is a far larger caveat on the fogged column than the muster thresholds
ever were. Open item 17.

**AND ONE CONSEQUENCE OF THE DOC THAT MAY NOT BE INTENDED, ESCALATED RATHER THAN PATCHED.**
C.3 gives Spear and Horse a 60-unit range, and `BUILD_BLOCKS_ADVANCE` stops an attacker at
range of the building it is hitting. Their front slot sits at observer coordinate 1,300,
which is section 6 - so a unit grinding it stands at **1,240, which is section 5**, and
under the doc's rule *"not the sections before it, not the sections after it"* **it never
sees the building it is attacking.** A Bow stops at 980, still in its own half. The
sequence the doc describes still works (crack the front blind, walk through section 6 and
learn the slot is now empty, reach 1,640 in section 7 and see the back building, reach
1,940 in section 8 and see the keep) - but "you cannot see the wall you are hitting" reads
like an accident of the grid rather than a design intent, and section 5's own example
*"even from a unit standing right next to it"* suggests the author pictured the attacker
INSIDE section 6. It is implemented literally, tested literally, and raised as open item 13.

**AND IT WAS RE-MEASURED. THE MILESTONE IS STILL RED, ON TWO CLAUSES, AND THEY ARE NOT THE
SAME TWO.** 1,440 matches, fogged regime, seed base 500000, `lua sweep/verdict.lua 6 500000
fog` -- the same frozen seed schedule as every column this README has ever published:

| Milestone clause | target | **fog model - THE GATE** | *muster bar (VOID)* |
|---|---|---|---|
| matches simulated | >= 1,000 | **1,440 PASS** | 1,440 PASS |
| every match terminated | 0 unfinished | **0 PASS** | 0 PASS |
| median match length | 380-430 s | **395 s PASS** | *432 s FAIL* |
| inside the 5-10 minute band | >= 75% | **71.0% FAIL** | *76.5% PASS* |
| decided by a razed keep | >= 80% | **82.5% PASS** | *75.9% FAIL* |
| family spread | under 10pp | **12.0pp FAIL** | *13.8pp FAIL* |
| no order bypassed the input gate | 0/0/0/0/0, <= 120 atoms/min | **0/0/0/0/0 @21 PASS** | *same* |

**THREE OF THE FOUR MEASURED CLAUSES MOVED, AND THE DIRECTION IS COHERENT.** Deleting the
only pre-contact warning means a defence answers a push only once it is already in its own
half -- two seconds of order delay and up to 1,000 units of march too late. So attacks land:
**razed keeps 75.9% -> 82.5%, clearing an 80% target this sim had never met**, and matches
**get shorter, median 432 s -> 395 s**, which puts the median clause back inside its band
from the wrong side of it. The clause that broke is the 5-10 minute BAND (76.5% -> 71.0%),
and it broke for the same reason: more matches now end fast, below the 5-minute floor,
rather than grinding. **Family spread improved and still fails** (13.8 -> 12.0pp), which is
consistent with Finding 2's conclusion that the statistic has no power at four lines per
family, and with its measurement that a change of instrument alone moves it by ~9pp.

**NOTHING IN `sim/Rules.lua` WAS TOUCHED TO PRODUCE ANY OF THIS.** `rulesHash` is 297242539
before and after. The entire movement above is a change in **what the sixteen lines are
allowed to perceive**, which is the third time in this README that a correction to the
INSTRUMENT has moved a milestone-deciding number by more than the margin it was being
judged on -- and it is the strongest single argument for open item 3, which asks Part E to
say out loud which information regime it is a claim about.

**AND THE SECOND SEED BASE SEPARATES THE TWO FAILURES, WHICH IS THE MOST USEFUL THING IN
THIS FINDING.** Same roster, same schedule, `lua sweep/verdict.lua 6 <base> fog`, plus the
upper bound for scale:

| run | median | band | razed keep | family spread | clauses |
|---|---|---|---|---|---|
| fog, base 500000 | 395 s | **71.0%** | 82.5% | 12.0pp | **RED: band spread** |
| fog, base 700000 | 399 s | **72.2%** | 81.8% | **8.7pp** | **RED: band** |
| full information, base 500000 | 415 s | 76.5% | 83.2% | 16.4pp | RED: spread |

1. **THE BAND IS THE ONE STABLE FAILURE.** 71.0% and 72.2% against a 75.0% threshold, at
   both bases, roughly 3-4pp under and well outside the ~1.1pp standard error on a 75% share
   at 1,440 matches. **It is the clause to take to the doc owner**, and it is a NEW failure
   -- the muster-bar roster passed it at all four bases. The mechanism is stated above and is
   not mysterious: with no early warning, more matches end under five minutes.
2. **FAMILY SPREAD FLIPS FROM FAIL TO PASS ON THE SEED BASE ALONE**, 12.0pp -> 8.7pp,
   crossing the 10pp threshold in one step. That is the sharpest demonstration this README
   has of Finding 2's conclusion -- **the clause is a coin at four lines per family** -- and
   it should be read as evidence for open item 4 rather than as a clause that nearly passes.
3. **THE UPPER BOUND FAILS ONLY ON SPREAD, AND FAILS IT BY MORE (16.4pp).** Under full
   information the median, band and razed-keep clauses all pass. So the gap between the two
   regimes is now concentrated in the BAND (76.5% -> 71.0%) rather than in decisiveness,
   which is the reverse of Finding 1's shape: **razed keeps no longer separate the two
   regimes at all** (83.2% vs 82.5%) where they used to differ by 5.3pp. Finding 1's
   headline -- that the information regime moves clauses by more than their margins --
   survives intact; its specific claim about WHICH clause does not.

**CAVEATS, STATED RATHER THAN LEFT TO BE DISCOVERED.** Two seed bases, not four. And the
whole column carries open item 17: **no line in this roster scouts**, so every number above
is the fog model played by a roster that never buys sight -- which, given that the doc's
central new mechanic is buying sight, is a larger caveat than any of the statistics.

**WHERE MEMORY LIVES, AND WHY IT IS NOT IN THE STATE HASH.** Memory is a per-side store
created by `Fog.newMemory` and owned by the CONSUMER -- the renderer in M7, `sweep/driver.lua`
in M2 -- and folded once per sim tick (`Fog.OBSERVE_EVERY = 1`, a declared cadence, not the
poll cadence: memory must not depend on how often a policy happens to look). It is not sim
state and it is not in `Hash.state`. Three reasons, any one sufficient:

1. **It is derived, and hashing a derived value hides its staleness.** `memory(t)` is a fold
   over the hashed state trajectory, the side index and the cadence. This README's own
   checklist already settles the class: *"hashing a value you can recompute HIDES a stale
   cache, because both clients compute the same wrong number and agree."*
2. **A disagreement in it is not a forked match.** The sim never reads memory -- grep 1 makes
   that structural -- so two clients whose memories differ are still playing one match with
   one of them drawing it wrong. In `Hash.state` it would make `tools/ci.sh` go RED for a
   render bug, which is exactly the M1/M2 conflation `tools/m2.sh`'s header exists to refuse.
3. **It would be a compatibility break for nothing.** `Hash.state` feeds the heartbeat and
   the committed goldens; adding a render fold invalidates every recorded match log to buy a
   check on something that cannot affect a match.

**So how is it checked?** `Fog.memHash` digests a store on demand. `sweep/determinism.lua`
now asserts both sides' memories are bit-identical across a replay, and `tools/fogtest.lua`
asserts the fold is deterministic, that mutating a store does not move `stateHash`, and that
the mirrored board produces a bit-identical memory from the other seat. That proves the
property that matters -- both clients compute both memories and agree -- without putting one
render field inside the number the heartbeat carries.

**WHAT IS IN THE TREE NOW.** `fog/Fog.lua` (a sibling of `sim/`, not a file inside it -
the file-layout section gives the grep-1 argument), `tools/fogtest.lua` with 289 checks
wired into `tools/ci.sh`, memory owned by `sweep/driver.lua` and digested into
`sweep/determinism.lua`'s replay comparison, and `sweep/fogaudit.lua` re-expressed against
sections. **`rulesHash` is unchanged at 297242539, `SUITE HASH` is unchanged at 1404498451,
and `tools/ci.sh 1000` is GREEN (5/5 steps).**

**AND THE TESTS HAVE TEETH, WHICH IS ASSERTED BY MUTATION RATHER THAN CLAIMED.** Six
deliberate breaks of `fog/Fog.lua`, each run against `tools/fogtest.lua`:

| mutation | result |
|---|---|
| remove the front-slot shield | 2 checks fail |
| make every section always visible | 4,049 fail |
| let a unit also light the last section | 3,504 fail |
| update building memory while unseen | 6 fail |
| 5 sections per half instead of 4 | **fails at load** (the CHECKS block) |
| drop the frame conversion in `sectionOfEnemy` | **fails at load** |

The last two are the strongest form: the module refuses to load rather than computing a
wrong map, because its section table is asserted against `Rules.lua`'s landmarks at require
time.

### Finding 7 - the roster was recalibrated for A.3, and it did NOT rescue the milestone

**SUPERSEDED IN PART BY FINDING 8.** The `alarm` field this finding introduced no longer
exists: the owner's fog doc deletes the muster bar it read. What survives is the diagnosis
- eleven of sixteen lines named an attention threshold nothing rendered at - and the two
`Policy` defects it found (`pressedLane` returning lane 1 on a blank board, and `full` not
being a superset of the fogged regime). The numbers below are void.


`lua sweep/fogaudit.lua` sizes the defect; `lua sweep/verdict.lua 6` measures the effect.
**This finding closes the mechanism Finding 1 proposed and mostly refutes it.** Finding 1
ended with "the mechanism is not the ruleset, it is the roster... `policy/lines.lua`, not
`sim/Rules.lua`, is the thing to change". The roster has now been changed. One clause
recovered, one halved and still fails, one did not move at all, and one broke.

**THE DEFECT, PER LINE, MEASURED RATHER THAN ASSERTED.** Every line declares `reactAt`, an
own-frame position the enemy's leading unit must reach before the line answers. Under A.3
an enemy unit is not rendered until `pos > POS_MIDLINE`, so `sweep/fogaudit.lua` reports the
lowest position any line EVER saw one at as **1,001-1,010 under `a3`, against 0 under
`full`**. Eleven lines named a threshold at or below 1,000. The predicate did not fail; it
silently became a different one - "the instant anything crosses" - for all eleven at once,
which is also why nothing in the tree went red. The `ERASED` column below is measured under
`full`, the only regime that can still see what `a3` is deleting: it is the share of that
line's own threat detections that happen where A.3 renders nothing.

| line | family | old `reactAt` | ERASED (full) | how it was broken | now |
|---|---|---|---|---|---|
| Adaptive | mixed | 900 | **20.2%** | answers 100 units before contact; unreachable | `alarm = PRESSURE`, `reactAt = 1001` |
| Turtle-pure | defence | 600 | **13.1%** | earliest threshold in the roster, most thoroughly unreachable | `alarm = PRESSURE`, `reactAt = 1001` |
| Turtle-eco | defence | 700 | **11.9%** | "meet every push" - before it arrives | `alarm = PRESSURE`, `reactAt = 1001` |
| Wall | defence | 800 | **8.3%** | blocks, then answers early | `alarm = PRESSURE`, `reactAt = 1001` |
| Counterpunch | defence | 900 | **5.6%** | holds a reserve to swing at a push it cannot see | `alarm = PRESSURE`, `reactAt = 1001` |
| Greed-pure | economy | 900 | **2.0%** | defenceless for 2 min, answers just before contact | `alarm = PRESSURE`, `reactAt = 1001` |
| Granary-bank | economy | 1000 | 1.2% | threshold ON the midline; only pos == 1000 exactly is erased | `reactAt = 1001`, no alarm |
| Balanced | mixed | 1000 | 0.7% | same | `reactAt = 1001`, no alarm |
| Trader | mixed | 1000 | 0.7% | same | `reactAt = 1001`, no alarm |
| Greed-lite | economy | 1000 | 0.5% | same | `reactAt = 1001`, no alarm |
| Late-eco | economy | 1000 | 0.4% | same | `reactAt = 1001`, no alarm |
| Rush-horse | aggro | 1400 | 0.0% | **not broken by fog** - broken by the PATCH; see below | `reactAt = 1400`, no alarm |
| Split-push | aggro | 1300 | 0.0% | same | `reactAt = 1300`, no alarm |
| Rush-spear | aggro | 1250 | 0.0% | same | `reactAt = 1250`, no alarm |
| Raid-counter | aggro | 1150 | 0.0% | same | `reactAt = 1150`, no alarm |
| Skirmish | mixed | 1100 | 0.0% | same | `reactAt = 1100`, no alarm |

**SO IT IS SIXTEEN LINES AND NOT ELEVEN, AND THE OTHER FIVE WERE BROKEN BY THE FIX.** The
previous pass patched the eleven by giving every line a muster-bar trigger derived from its
own `reactAt`: at or below the midline earned a PRESSURE trigger, above it earned a HEAVY
one. That handed the four aggro lines and `Skirmish` a pre-emptive answer their
configuration never asked for and their notes explicitly disclaim - `Rush-horse` exists to
test "answers a threat only once it is at the gates, which is the whole aggro bet". **And
the rule was chosen by which numbers it moved**, which its own comment recorded: the two
flat alternatives were rejected because one dropped razed keeps to 73.5% and the other
dropped the band to 74.5%. That is selecting an instrument on the reading it produces, and
it is the thing the next reviewer is looking for. The trigger is now a DECLARED per-line
field (`alarm`), so it can be read rather than re-derived.

**WHAT CANNOT BE EXPRESSED, STATED RATHER THAN AVERAGED AWAY.** Six lines declared four
distinct sub-midline thresholds (600 / 700 / 800 / 900 / 900 / 900) and A.3 has **one usable
rung** to receive them: `sweep/fogaudit.lua` measures `bar >= pressure` lit in 2-6% of
lane-polls and **`bar >= heavy` in 0.0-0.1%**, so HEAVY is not a second attention level, it
is silence spelled differently. Their separation on the attention axis is **gone and cannot
be restored** - the enemy half is three-valued, and that is the instrument A.3 specifies,
not a limitation of this file. What still separates those six is `react` (52-80), the
opening, the mix, the cadence, `minStack` and `convertAt`. No line was dropped: all sixteen
survive with a documented loss, and `Raid-counter`'s note ("the counter to what it SEES in
the lane") turned out to have been fog-honest all along, since `Policy.counterType` only
ever counted rendered units.

**THE SECOND DEFECT, WHICH WAS BIGGER THAN THE FIRST.** `Policy.pressedLane` started its
best-score search at -1, which no lane can fail to beat, so on a board where every lane
scored 0 it answered "lane 1". Under full information that state ends at the enemy's first
deploy. **Under A.3 it is a quarter of the match**: `fogaudit` measures **16.8%-35.1% of
every line's decisions** taken against an enemy half showing no rendered unit, no lit bar
and no standing Levy. Three lines choose their deploy lane from that answer
(`target = "guard"`), two place their reactive building with it, and every unscripted front
slot in an opening goes where it points - so `Wall`, `Turtle-eco` and `Turtle-pure` were
playing "focus lane 1" for the first minutes of every match, and `Balanced` put its Trap Pit
in lane 1 in all 1,440 of them. It returns 0 now, and every caller already handled 0.
`Policy.openLane` was left alone deliberately and the reasoning is in its header: a tiebreak
between three lanes that are genuinely equally undefended is determinism rule 6, while a
tiebreak between three lanes nobody can see is an invention.

**THE THIRD, AND IT IS ABOUT THE UPPER BOUND RATHER THAN THE GATE.** `Policy.fillView` built
the muster bar only under `a3`, so the regime published as "an upper bound on how well
anyone can play" was MISSING a field the restricted regime had. Ruling 1 puts every enemy
unit's HP on both clients, so the bar - a three-way bucketing of a sum `full` already holds
exactly - is strictly coarser than what that regime is entitled to. The bar is now built in
both, so `full` is an actual superset of `a3` and the two columns differ only in what the
board shows, not in which roster parameters are inert.

**WHAT EACH CHANGE MOVED, SEPARATELY, at 1,440 matches per regime and seed base 500000.**
Every change was made because the thing it touched was broken; the columns are here so that
claim can be checked rather than believed:

| stage | a3 median | a3 band | a3 keep | a3 spread | full median | full band | full keep | full spread |
|---|---|---|---|---|---|---|---|---|
| as measured before this pass | 428 s | 74.7% | 75.6% | 22.9pp | 414 s | 76.8% | 80.9% | 14.2pp |
| + `pressedLane` returns 0 on a blank board | 432 s | 76.7% | 76.0% | 17.3pp | 419 s | 77.7% | 80.1% | 12.7pp |
| + the sixteen lines recalibrated (`alarm` / `reactAt`) | 432 s | 76.5% | 75.9% | 13.8pp | 415 s | 76.5% | 83.2% | 16.4pp |
| + the muster bar built under `full` too | **432 s** | **76.5%** | **75.9%** | **13.8pp** | **419 s** | **76.7%** | **80.6%** | **16.6pp** |

The last row changes the `a3` column by nothing at all, which is the point: it is a fix to
the upper-bound column and it stayed there.

**AND IT IS NOT SEED LUCK, IN EITHER DIRECTION.** The recalibrated roster under A.3, four
seed bases, 1,440 matches each:

| seed base | median | band | keep | spread | clauses |
|---|---|---|---|---|---|
| 500000 | 432 s | 76.5% | 75.9% | 13.8pp | **RED: median keep spread** |
| 600000 | 434 s | 76.4% | 74.1% | 13.6pp | **RED: median keep spread** |
| 700000 | 438 s | 76.1% | 76.3% | 11.1pp | **RED: median keep spread** |
| 800000 | 439 s | 75.5% | 75.1% | 14.5pp | **RED: median keep spread** |

Before the recalibration the four bases failed four *different* combinations. **A verdict
that no longer changes its mind about which clause is broken when the seeds move is the
single most useful thing this pass produced**, and it is worth more than the two clauses
that changed state.

**THE FOUR HONEST CONCLUSIONS, INCLUDING THE ONE THAT GOES AGAINST THE WORK.**

1. **The band clause was a roster artefact and is now genuinely passing** - 74.7% -> 76.5%,
   and at all four seed bases rather than at one. Most of that came from the `pressedLane`
   fix (+2.0pp), not from the attention recalibration (-0.2pp).
2. **The razed-keep clause is not a roster artefact.** It moved 75.6% -> 75.9% across the
   entire recalibration and sits 4.1pp under target at every seed base. Finding 1's
   hypothesis that the fogged decisiveness gap is a roster effect is **refuted**: it
   survives an honestly calibrated roster intact, and it is now the strongest candidate for
   a genuine disagreement between this sim and C.6's 85%.
3. **The median clause BROKE, and that is a real result rather than a regression to undo.**
   428 s -> 432 s, and 432-439 s across four bases against a 380-430 s ceiling. A roster
   that answers pressure only when it can actually see it fights longer, and the honest
   number is a few seconds outside Part E's band. The temptation to buy those 2 s back by
   re-tuning `alarm` is exactly the thing this pass exists to refuse: **a roster selected to
   pass is as useless as a policy that cheats.**
4. **Family spread halved, 22.9pp -> 13.8pp, and the clause still fails and still cannot be
   measured.** `lua sweep/famstat.lua 6 1 20000` re-run on the recalibrated roster:
   `P(null >= measured) = 84.1%` (was 55.9%), so the measured spread is now *further* inside
   the null than before - the four family labels carry even less detectable information than
   they did. `P(null < 10pp) = 6.5%`. Finding 2 stands unchanged in its conclusion and its
   numbers are updated in place.

**One thing this pass BROKE that was not a number in the milestone, and it must not be
buried**: Finding 2 recommends replacing the family-spread clause with "every family has a
line above 70% and no line above 90%". Under A.3 the recalibrated roster's best defence line
is `Counterpunch` at **65.0%**, where the old roster's best was `Wall` at 74.4% (`Wall` is
now 58.3%). **So this sim now misses the proposed clause for defence under BOTH regimes** -
by 5.0pp under fog, where it used to pass by 4.4pp, and by 0.6pp under full information,
where it already missed. Aggro, economy and mixed still clear it in both
(`Rush-horse` 77.7 / 75.5%, `Granary-bank` 87.7 / 84.4%, `Adaptive` 73.6 / 78.6%). **A
clause that one honest recalibration of the instrument moves by 9pp on the family it
decides is not a robust clause either**, and open item 4 is updated to say so rather than
quietly keeping the recommendation that flattered the earlier roster.

### Finding 1 - the whole first pass was measured under PERFECT INFORMATION, and that is worth more than two clauses' margins

`lua sweep/verdict.lua 6` prints both columns; `lua sweep/verdict.lua 6 500000 a3` runs one.

`Policy.fillView` handed every line a verbatim copy of the enemy side. Three of its field
groups directly contradict A.3's default-vision table:

| what the view carried | A.3 says |
|---|---|
| foe `bank / earned / spent / wasted / levyFlat` | *"Enemy Levy / bank / income / spend - Not rendered"* |
| every foe slot's identity, HP, done-flag and occupancy | *"Enemy buildings, not yet disclosed - Nothing, not even that the slot is occupied"* |
| every foe unit's type, HP and position, anywhere on the board | *"Enemy units in their half - Nothing individual. One per-lane muster bar, 3 buckets"* |

These were not unused fields; the lines are built on them. `Policy.openLane` scores lanes as
`f.supply + 120*(frontB>0) + 60*(backB>0)`, which is the enemy's **undisclosed building
occupancy plus their exact hidden unit supply**, and it is the lane rule for `target = "open"`
- 9 of the 16 lines, including all three of the strongest. `Policy.pressedLane` and
`threatLane` read exact hidden `supply` and `maxPos` at `reactAt` thresholds as low as 600,
which is deep inside the enemy's own half. `Policy.counterType` read exact enemy unit-type
counts anywhere on the board.

**The defence offered for this was true and answered the wrong question.** `Policy.lua` and
this README argued from Ruling 1 that a policy reading enemy state "is reading what its own
client already has". That is about what the CLIENT holds. A.3's table is about what the
PLAYER sees, and it is the player who plays the match Part E's milestone is characterising.

**What changed.** `policy/Policy.lua` now carries `M.VISION`, a named regime with both
settings runnable and printed in every report header. Under `"a3"` the foe half of the view
is filtered exactly as A.3 renders it: enemy purse zeroed; an enemy building's slot renders
EMPTY until `hp < maxHp` discloses it (which latches permanently, since nothing in M1 or M2
heals); an enemy unit is individually visible only once `pos > POS_MIDLINE`, i.e. once it is
in my half; and everything behind that line is summarised by A.3's three-bucket muster bar,
read back as a coarse Levy estimate. **This is not an approximation for this roster** - A.3's
two vision-granting buildings, Watchtower and Shrine, are built by none of the sixteen lines,
so `"a3"` here *is* A.3's default vision rather than a lower bound on it.

**What it did, at 1,440 matches per regime. These are the numbers as they stood when the
regime was introduced, against the pre-recalibration roster; Finding 7 re-measures both
columns against a roster that can actually perceive the fogged board:**

| clause | full information | A.3 fog | moved by |
|---|---|---|---|
| median | 414 s PASS | 428 s PASS | +14 s |
| inside the 5-10 min band | 76.8% PASS | **74.7% FAIL** | -2.1pp |
| decided by a razed keep | 80.9% PASS | **75.6% FAIL** | -5.3pp |
| family spread | 14.2pp FAIL | 22.9pp FAIL | +8.7pp |

**Two consequences, and they are the reason this is Finding 1.**

1. **The two clauses M2 used to pass, it passed by 1.8pp and 0.9pp** - and the information
   regime, an unstated and until now untested choice, moves them by 2.1pp and 5.3pp. The
   margin was smaller than a term nobody had priced. **This half stands.**
2. ~~**The mechanism is not the ruleset, it is the roster.**~~ **PARTLY REFUTED BY
   FINDING 7, which did the experiment this paragraph proposed.** The observation was
   correct: `reactAt` - the per-line attention parameter, set between 600 and 1400 across
   the roster - is unreachable below the midline, and eleven of the sixteen lines had one
   inside the enemy's own half, so the sixteen lines were indeed calibrated against a board
   no player is ever shown. The *inference* - that the fogged column's failures are
   therefore a roster effect - does not survive the fix. Recalibrating all sixteen lines
   onto signals A.3 renders **recovered the band clause (74.7% -> 76.5%), halved the family
   spread (22.9 -> 13.8pp, still failing), moved the razed-keep clause by 0.3pp, and pushed
   the median out of its band.** Two of the three fogged failures were not about the roster.
   See Finding 7 for the per-line defect list and the staged measurement.

**And the one number in M2 that is neither in Part C nor forced by it: the muster bar's
thresholds.** A.3 specifies three buckets driven by total marching HP and gives no cut
points. They are derived in `Policy.lua` rather than chosen - three equal shares of the most
marching HP a 200-Levy lane can hold at C.3's best HP-per-Levy body (Spear, 42 HP/Levy, so
8,400 HP), read back at the lower edge of each bucket - but the fogged column is genuinely
sensitive to them, which is why this is escalated rather than quietly tuned:

| muster model (480 matches) | median | band | razed keep | family spread |
|---|---|---|---|---|
| **2,800 / 5,600 HP -> 66 / 133 Levy (shipped, derived)** | 424 s | 75.6% | 75.8% | 21.2pp |
| 2,800 / 5,600 -> read back as 0 (unseen lane assumed empty) | 425 s | 73.3% | 77.7% | 13.7pp |
| 2,100 / 4,200 -> 50 / 100 | 443 s | 75.2% | 73.7% | 18.0pp |
| 4,200 / 6,300 -> 100 / 150 | 429 s | 74.1% | 74.5% | 15.5pp |
| *full information, for scale* | *415 s* | *77.0%* | *80.4%* | *12.7pp* |

**The razed-keep clause fails under every one of them and the band clause under most, so the
direction of Finding 1 is not a threshold artefact - but the size of it is not settled, and
family spread moves 7.5pp on this choice alone.** No fogged number should be quoted against
Part C until A.3 fixes the buckets. See open item 8.

**This table was measured against the PRE-RECALIBRATION roster and has not been re-run, so
it is a sensitivity to the cut points and not a current reading. `sweep/fogaudit.lua` has
since added a fact about the shipped cut points that the table cannot show and that open
item 8 needs: at 2,800 / 5,600 HP the bar reads `pressure` in 2-6% of lane-polls and
`heavy` in 0.0-0.1%.** The heavy bucket is essentially never rendered, so the top third of
A.3's own three-state widget is dead at the derived thresholds - which is why the
recalibrated roster maps every pre-contact intent onto `pressure` and no line declares
`alarm = HEAVY`. That is a rendering fact as much as a balance one and it should reach the
doc owner with the rest of item 8.

### Finding 2 - the family-spread clause is not measurable at four lines per family

`lua sweep/famstat.lua` (~8 min; numbers below are the **A.3 fog** regime at 1,440 matches
per replicate, seed base 500000). **Re-measured on the recalibrated roster
(`lua sweep/famstat.lua 6 1 20000`); the conclusion did not move and the numbers got
worse.** Family win rate here is the arithmetic mean of **four hand-written lines** whose
individual win rates run from 2.7% to 87.7%. A mean of four samples drawn from a spread that
wide has a standard error of the same order as the 10pp threshold being tested, so the first
question is not "is the ruleset balanced" but "can this statistic tell a balanced ruleset
from an unbalanced one". Five tests say no.

**1. Permutation.** Deal the sixteen measured line win rates into four *arbitrary* groups
of four, 20,000 times, and build the distribution of family spread under the null
hypothesis that the family label carries no information at all:

| null family spread | p05 | p25 | median | p75 | p95 |
|---|---|---|---|---|---|
| labels shuffled, recalibrated roster | 9.0pp | 16.5pp | **22.8pp** | 29.1pp | 37.8pp |
| *labels shuffled, before recalibration* | *9.6pp* | *17.7pp* | *24.3pp* | *31.2pp* | *40.6pp* |

The measured 13.8pp sits at the **16th percentile of that null**: `P(null >= measured) =
84.1%`. The real family grouping is indistinguishable from random grouping - and it is now
*narrower* than random grouping rather than merely indistinguishable from it. **The sweep
has not detected a family effect, and recalibrating the roster made the label carry less
detectable information, not more** (before: measured 22.9pp at the 44th percentile,
`P(null >= measured) = 55.9%`). And the number this README previously called decisive:
`P(null spread < 10.0pp) = 6.5%`, against 5.5% before. **A roster with this dispersion
fails the milestone clause about 93% of the time with the families assigned at random.**

**1b. But that is a statement about THIS ROSTER's dispersion, not about the ruleset - and
the earlier version of this finding got that wrong.** It concluded that the clause "is very
nearly unpassable by any ruleset", which does not follow from its own evidence: the null is
computed from sixteen win rates the ruleset and the roster produce *jointly*. `famstat.lua`
now runs the obvious control - shrink the same sixteen rates toward 50% and re-run the
identical permutation, which changes the roster's dispersion and nothing about the ruleset:

| roster dispersion | spread | null median | P(null < 10pp) |
|---|---|---|---|
| as measured (leverage 85.0pp) | 13.8pp | 22.8pp | **6.5%** |
| shrunk to C.6's own leverage (55.0pp) | 8.9pp | 14.7pp | **21.0%** |
| half this dispersion | 6.9pp | 11.4pp | **38.2%** |
| a quarter of it | 3.5pp | 5.7pp | **96.9%** |

**The clause is passable** - by a roster whose lines sit within about 20pp of each other -
and it is three times more passable at the dispersion C.6 itself reports. What the
permutation shows is that the statistic has **no power at this dispersion**, not that the
clause is unreachable. A layout that passes need not be a lucky draw.

**2. Seed noise, and the thing this table used to throw away.** Four replicates of the full
1,440 matches with the roster held exactly fixed and only the seed base moved. `famstat.lua`
computed a complete round-robin for each replicate and printed only the family columns, so
**every other milestone clause was measured four times and discarded.** It now prints them,
with a per-row verdict, because a replicate that would fail a clause must never again be
computed and thrown away:

**THE RECALIBRATED ROSTER, A.3, four bases** (`lua sweep/verdict.lua 6 <base> a3`, the same
frozen seed schedule; the family columns were re-measured only at 500000, so the other three
rows carry the four milestone numbers and not the family split):

| seed base | regime | aggro | economy | defence | mixed | spread | band | keep | median | clauses |
|---|---|---|---|---|---|---|---|---|---|---|
| 500000 | a3 | 53.9 | 40.1 | 53.1 | 52.7 | 13.8pp | 76.5% | 75.9% | 432 s | **RED: median keep spread** |
| 600000 | a3 | - | - | - | - | 13.6pp | 76.4% | 74.1% | 434 s | **RED: median keep spread** |
| 700000 | a3 | - | - | - | - | 11.1pp | 76.1% | 76.3% | 438 s | **RED: median keep spread** |
| 800000 | a3 | - | - | - | - | 14.5pp | 75.5% | 75.1% | 439 s | **RED: median keep spread** |
| 500000 | full | 53.8 | 39.7 | 50.1 | 56.3 | 16.6pp | 76.7% | 80.6% | 419 s | RED: spread |

**BEFORE the recalibration, for comparison. Four bases, and four different answers to the
question "which clause is broken":**

| seed base | regime | aggro | economy | defence | mixed | spread | band | keep | median | clauses |
|---|---|---|---|---|---|---|---|---|---|---|
| 500000 | a3 | 53.8 | 36.5 | 59.4 | 50.2 | 22.9pp | 74.7% | 75.6% | 428 s | **RED: band keep spread** |
| 600000 | a3 | 54.6 | 37.9 | 59.0 | 48.4 | 21.1pp | 74.1% | 75.9% | 429 s | **RED: band keep spread** |
| 700000 | a3 | 55.2 | 39.8 | 57.9 | 46.9 | 18.1pp | 75.4% | 77.0% | 441 s | **RED: median keep spread** |
| 800000 | a3 | 54.0 | 37.6 | 57.3 | 50.9 | 19.7pp | 74.0% | 76.5% | 433 s | **RED: median band keep spread** |
| 500000 | full | 55.8 | 41.6 | 53.6 | 48.8 | 14.2pp | 76.8% | 80.9% | 414 s | RED: spread |
| 600000 | full | - | - | - | - | 16.1pp | 76.1% | 81.7% | 427 s | RED: spread |
| 700000 | full | - | - | - | - | 12.1pp | 75.8% | 80.5% | 411 s | RED: spread |
| 800000 | full | - | - | - | - | 14.1pp | 75.1% | 82.4% | 418 s | RED: spread |

Match randomness moved the spread by **4.8pp** under fog before the recalibration and
**3.4pp** after it. It is not the seeds, and playing 10,000 matches instead of 1,440 would
not close a 10pp gap.

**And the band column is the clearest single argument for having done this work.** Before
the recalibration it read 74.0 / 74.1 / 74.7 / 75.4% under fog against a >= 75.0%
threshold - failing at three bases of four and passing at the fourth - and under full
information 75.1 / 75.8 / 76.1 / 76.8%, where **75.1% of 1,440 is 1,081 matches against a
pass threshold of exactly 1,080: it passed by ONE MATCH at seed base 800000.** At 1,440
matches the standard error on a 75% share is about 1.1pp, so a 75.0% threshold measured at
75.1% is comfortably inside its own noise. **On the recalibrated roster the same clause
reads 75.5 / 76.1 / 76.4 / 76.5% and passes at all four**, which is the difference between a
measurement and a coin - though 75.5% is still only half a standard error clear, so the
clause remains thin rather than safe. See open item 3.

**3. Roster jackknife.** Delete one line of sixteen and recompute exactly from the pair
matrix, so the dropped line goes as an opponent too:

- without `Greed-pure`: **1.3pp** (lowest, and the only deletion that would PASS)
- without `Greed-lite`: 10.8pp
- without `Raid-counter`: 13.2pp
- ...
- without `Rush-spear`: 22.9pp
- without `Granary-bank`: **31.1pp** (highest)

**Deleting one line of sixteen swings the clause across a 29.8pp range**, wider than the
threshold being tested by a factor of nearly three, and **one of the sixteen deletions
(`Greed-pure`, at 2.7% the worst line in the pool) would take the clause from 13.8pp to
1.3pp and turn the milestone green on its own.** That is a milestone one line moves, which
is a statement about the roster. (Before the recalibration the range was 12.4-40.0pp and no
single deletion passed under fog; the recalibration made the clause *more* sensitive to one
line, not less.)

**4. And the roster deliberately overshot - by more than it used to.** `policy/lines.lua`
says in its own header that the lines within a family are "deliberately far apart", to
reproduce C.6's headline that decision leverage (26.9-55.0pp) is five times family spread.
It overshot: within-family leverage here is **24.5-85.0pp** against C.6's 26.9-55.0pp
(before the recalibration, 30.0-81.1pp). The low end now agrees with C.6 to 2.4pp; the high
end is 1.5x and the honest recalibration widened it. **The two dispersions moved in opposite
directions** - lines got further apart (81.1 -> 85.0pp) while their family means got closer
together (22.9 -> 13.8pp) - which is exactly what a mean of four noisy samples does and is
another way of saying the family statistic is not measuring the lines.

**5. Building spend does not explain it either.** The standing explanation was that win
rate is nearly a linear function of building spend, so building-heavy families are
structurally punished. Kendall's S over the sixteen lines is **-29 of 120 pairs, two-sided
p = 19.7%** - not significant (before: -27, p = 23.0%). The best line in the pool opens with
a 100-Levy Granary and the worst buys three buildings.

**What this means for Part C.** The permutation null cannot be run against C.6's own
numbers, because **Part C recorded four of its sixteen policy names and nothing else.** The
clause as written compares two rosters, under two unrecorded information regimes, and
attributes the difference to the sim.

**The correction is to the milestone, not to `Rules.lua`.** Part C already states the
constraint the design actually cares about, in C.6's own prose: *"All three pure
archetypes have a top line above 70%, which meets the design's 'live path to victory'
constraint literally rather than approximately."* That is a floor on the best line per
family, not a mean over an arbitrary four, and it is robust to which lines somebody wrote
- adding a bad line cannot break it.

**RE-MEASURED ON THE CURRENT ROSTER UNDER THE OWNER'S FOG MODEL (Finding 9), and the
proposed replacement clause now fails on BOTH of its halves rather than one.** `lua
sweep/sweep.lua 6`, 1,440 matches, seed base 500000:

| family | best line | fog, scouting roster | in [70,90]? |
|---|---|---|---|
| aggro | Rush-horse | 71.1% | yes, by 1.1pp |
| economy | **Granary-bank** | **94.4%** | **NO -- 4.4pp ABOVE the 90% ceiling** |
| defence | **Counterpunch** | **58.3%** | **NO -- 11.7pp below the 70% floor** |
| mixed | Adaptive | 78.8% | yes |

The economy row is new and it is a correction to this README rather than a change in the
sim: `Granary-bank` was over 90% in the muster-bar reading too (93.8% in Finding 8's
roster) and the table below never checked the ceiling. **So the clause C.6's own prose
derives is missed at both ends by this roster**, which strengthens rather than weakens the
argument that no summary of sixteen hand-written lines is stable enough to gate on.

*The table this replaces, measured under the muster bar and kept as the record:*

| family | best line (A.3) | A.3 fog | in [70,90]? | best line (full) | full info | in [70,90]? |
|---|---|---|---|---|---|---|
| aggro | Rush-horse | 77.7% | yes | Rush-horse | 75.5% | yes |
| economy | Granary-bank | 87.7% | yes | Granary-bank | 84.4% | yes |
| defence | **Counterpunch** | **65.0%** | **NO, by 5.0pp** | Wall | **69.4%** | **NO, by 0.6pp** |
| mixed | Adaptive | 73.6% | yes | Adaptive | 78.6% | yes |

*Before the recalibration this table read `Rush-horse` 76.6 / 78.6, `Granary-bank`
83.3 / 87.7, `Wall` 74.4 / 69.4 and `Adaptive` 74.1 / 78.6 - so the defence row passed under
fog and failed under full information. It now fails under both, and by 5.0pp rather than by
a rounding error. Nothing about the ruleset changed between those two readings.*

**Recommendation: replace "family spread under 10pp" with "every family has a line above
70% and no line above 90%"** - it tests what the design says it wants, it survives a change
of roster, and it is the clause C.6's own text derives. **The recommendation stands and its
caveat has got much worse, which is stated here rather than dropped: this sim now MISSES the
proposed clause for defence under both regimes, by 5.0pp under fog and 0.6pp under full
information.** The history of that one cell is the argument against adopting the clause as a
hard threshold: an earlier version of this README reported defence's best line at 70.0%,
exactly on the threshold; the `Counterpunch` duplicate-key fix moved it to 74.4%; and
Finding 7's recalibration - which changed no rule, only what the lines are allowed to
perceive - moved it to 65.0%. **Three successive corrections to the INSTRUMENT moved a
milestone-deciding number by 9pp without anyone touching `Rules.lua`.** The honest reading
is that at four lines per family **no summary of the roster is stable to 5pp, let alone
1pp**. If the clause is adopted it must be adopted with a stated tolerance, or with more
than four lines per family - see open item 10, which is now the blocking piece of work for
this item rather than a nice-to-have.

### Finding 3 - a building costs real win rate, but NOT in proportion to its price

`lua sweep/probe.lua 6 Balanced` and `lua sweep/probe.lua 6 Turtle-eco` (~75 s each).
**This finding replaces the earlier "a building costs 0.15pp of win rate per Levy" entry
in this README, whose second half does not survive a control.**

A control line - `Balanced` with its opening stripped and all nineteen other configuration
fields inherited - plays the whole pool from both seats. Each variant is that control plus
exactly one opening building. 192 matches per variant; a win rate at that sample size has
a standard error of about 3.5pp, so two variants need to clear roughly 10pp before their
order means anything.

**NOT RE-MEASURED SINCE FINDING 9, AND THE TABLE BELOW IS STALE IN A KNOWN DIRECTION.** The
probe holds ONE control against the whole pool, and four lines in that pool now buy sight
(Finding 9), so every cell moved by whatever scouting opponents are worth. The control
itself is unaffected in kind -- `Balanced` and `Turtle-eco`... `Turtle-eco` **does** now
scout, so the second control column is a scouting control and the first is a blind one,
which is a difference the table does not label. `sweep/probe.lua` inherits `cfg.scout` from
its control like every other field, so both probes remain internally controlled; what is
not current is the comparison to these published numbers. **Re-run both before quoting
either.** The conclusions -- that a building costs real tempo, that the penalty does not
track price, and that the failures are the lane-scoped buildings -- rest on same-price gaps
within one column and are not disturbed by a level shift.

**Re-measured under A.3 fog after the `Counterpunch` fix; every number below moved and the
conclusion did not.** Both controls, 192 matches per variant:

| opening | cost | vs `Balanced` control (52.8%) | sigma | vs `Turtle-eco` control (74.2%) | sigma |
|---|---|---|---|---|---|
| **nothing at all** | 0 | - | - | - | - |
| Trap Pit | 50 | -8.6pp | 1.7 | **+0.2pp** | 0.0 |
| Watchtower | 70 | -10.1pp | 2.0 | -1.9pp | 0.4 |
| Palisade | 90 | **+2.4pp** | 0.4 | -9.7pp | 2.1 |
| Granary | 100 | -8.6pp | 1.7 | -7.6pp | 1.6 |
| Arrow Tower | 110 | -4.9pp | 0.9 | **+4.4pp** | 1.0 |
| Redoubt | 110 | -12.7pp | 2.5 | -13.8pp | 3.0 |
| Smithy | 110 | -18.5pp | 3.7 | -8.1pp | 1.7 |
| Fletcher | 110 | -12.7pp | 2.5 | -11.7pp | 2.5 |
| Levy Post | 120 | -13.3pp | 2.6 | -6.5pp | 1.4 |
| **Stables** | **120** | **-15.9pp** | 3.2 | **-18.5pp** | 4.0 |
| Shrine | 140 | -18.5pp | 3.7 | -15.9pp | 3.4 |

**Clause A - buying a building costs win rate - is CONFIRMED for most of the catalogue and
is large, but it is NOT universal.** Nine of eleven are negative against the roaming
control and ten of eleven against the defensive one, several past 3 sigma. The tempo
mechanism in `policy/lines.lua`'s reserve comment is real: a building is bought by fielding
nothing for the ~40 s it takes to save the whole price, because a partial reserve buys
nothing. **But three cells are positive** - Palisade for the roaming control, Trap Pit and
Arrow Tower for the defensive one - and none of the three is significant, which is the
useful part: **for the right control the tempo cost of the right building is inside the
noise.** Under the previous full-information measurement all eleven were negative and nine
were past 2.5 sigma, so the fog moves this too.

**Clause B - "the penalty tracks the PRICE, not the effect" - REMAINS REFUTED, and the
evidence for refuting it is now weaker in one place and stronger in another. Say both.**

1. **Hold the price exactly fixed and the penalty still moves.** At **110 Levy** against the
   defensive control, Arrow Tower is +4.4pp and Redoubt -13.8pp: an **18.2pp gap at 4.0
   sigma** between two buildings that cost identical Levy and therefore lose identical
   tempo. That single same-price gap is 80% of the spread of the *whole* table across its
   whole price range (22.9pp). Against the roaming control the widest same-price gap is
   13.6pp at 2.7 sigma, against a whole-table spread of 20.9pp.
2. **The correlation is control-dependent, and this is the arm that got weaker.** Against
   `Balanced` the cost-versus-win-rate rank correlation is **Kendall S = -30, p = 1.2%** -
   significant, and `probe.lua`'s own READ line for that control now says "the penalty does
   track the price". Against `Turtle-eco` it is **S = -24, p = 6.1%** - not significant at
   5%, but not the "p = 36.8%, gone" the earlier measurement reported either. **A
   relationship that is p=1% for one control and p=6% for the next is a weaker refutation
   than this README previously claimed**, and the honest statement is that price is *a*
   term, not that it is not a term.
3. **The round-robin does not support it.** Across all sixteen lines, building spend against
   win rate is Kendall S = -27 of 120 pairs, **two-sided p = 23.0%** (`sweep/famstat.lua`
   test 5). The best line in the entire pool, `Granary-bank` at 83.3%, opens with a
   100-Levy Granary.

**What the data actually points at, and it survived the re-measurement intact.** The
buildings at the bottom for the roaming control - Stables, Shrine, Smithy, Redoubt,
Fletcher - are precisely the **lane-scoped** effects, which are worth nothing to a line
whose `target = "open"` sends it wherever the enemy is not. Give the control a reason to
stay in its lane and they recover: **Smithy -18.5pp -> -8.1pp, Arrow Tower -4.9pp -> +4.4pp,
Trap Pit -8.6pp -> +0.2pp, Levy Post -13.3pp -> -6.5pp.** The two that fail under *both*
controls are **Stables** (-15.9 / -18.5) and **Shrine** (-18.5 / -15.9), and Stables is
lane-scoped twice over - a march bonus and a Horse discount, both only in its own lane.

**So the earlier recommendation in this README - "move C.4's band down to 4-8 ticks of
income", i.e. halve every price - stays withdrawn.** A uniform reprice would leave the
lane-scoped buildings exactly where they are in the ordering, because their problem is
that their effect is conditional on a commitment the buyer has not made, not that they are
dear. It would also make Trap Pit and Arrow Tower, which are already inside the noise for
a control that fights in one lane, strictly better. **Any repricing is per-building, and
the evidence for it is two control lines that disagree about how much price matters.**

**One further correction, to an instruction this README used to give.** An earlier version
said *"do not reprice anything to close the family-spread clause - the statistic cannot see
the change"*. That is withdrawn as unsupported: a repricing does move the statistic, by
more than the threshold. What it also does is trade one clause for others - scaling costs
down lengthens the median and reduces decisiveness - so the accurate warning is
**"repricing is not the way to close the family-spread clause, and `Rules.lua` should still
not be touched for that reason"**, which is a different sentence with a different
justification.

### Finding 4 - Q10's tiers 2, 3 and 4 do not fire

Of the 346 matches that reached the clock under A.3 fog: **T1 97.3%, T2 0%, T3 0%, T4 0%,
draw 2.6%.** C.6 states T1 54%, T2 25%, T3 17%, draw 4% and Q10 concludes "every tier
fires, so nothing in Q10 is dead code". The full-information regime gives the same shape
over its own clock matches, so this is not a fog effect - and **the recalibrated roster
gives the same shape again**, which matters because it is the only finding here that a
change of roster could not have rescued and did not.

Tier 2 can only be reached when both sides have removed **exactly** the same cumulative
number of HP from the enemy keep. Against a 48,000 HP keep taking chip damage all match
that is a coincidence, not an outcome - and the 2.5% of draws are the matches where NEITHER
side ever touched a keep, so they tie at 0 and fall straight past every tier to tier 5.
There is no observed path to T2/T3/T4 at these numbers. This agrees with what M1 already
recorded (random logs never reach T2-T4 either; `tools/mechanics.lua` covers them by
hand-building terminal states) and it is now confirmed under real play.

This does not make the ladder wrong - Q10's ORDERING is still the thing that makes the
pure-turtle exploit unreachable, and that part is confirmed below. It makes the *claim*
about tier frequency wrong, and it means T2-T4 will ship untested by anything except a
unit test unless tier 1 is coarsened (bucketing `keepDamageDealt`, e.g. to whole percent of
KEEP_HP, would make ties common enough for the lower tiers to matter).

**Unlike Findings 1, 2 and 3 this one is not a statistical artefact and cannot become one:**
it is a structural claim about an exact integer tie, and 0 occurrences in 350 clock
matches is not a sample-size problem.

### Finding 5 - C.6's per-line numbers are not reproducible in principle, and it is worth saying why

| line | C.6 | here, A.3 fog | here, full info | |
|---|---|---|---|---|
| Rush-horse | 77.8 (best line in the pool) | **77.7** (best in pool) | 75.5 (2nd in pool) | **agrees to 0.1pp** |
| Greed-pure | 73.3 (best economy line) | **2.7** (worst in pool) | 6.1 (worst in pool) | disagrees by 71pp |
| Turtle-eco | 71.4 (best defence line) | 40.5 | 36.1 | disagrees by 31pp |
| Balanced | 59.2 | 46.6 | 48.3 | disagrees by 11-13pp |

*(Recalibrated-roster figures. Before Finding 7 they read 76.6 / 78.6, 2.2 / 7.7,
44.4 / 47.2 and 47.2 / 40.0. **`Rush-horse` moved TOWARD C.6 under fog, from 1.2pp out to
0.1pp out, and away from it under full information** - which is a second, independent sign
that A.3 default vision is the regime C.6 was measured under, now from a roster that could
not have been tuned toward that agreement because nothing in it was chosen by looking at
C.6's table.)*

The earlier reading of this table was that the two models disagree about what a building
buys. **After Findings 1 and 2 that reading is wrong, and the correct one is duller and
more useful: these are eight different programs sharing four names.** Part C recorded that
its sweep used "sixteen scripted policies across four families" and published four names
and four numbers. It did not record what any of them did, nor what any of them could see.
`Greed-pure` here is "two Levy Posts and a Granary before a single unit, going completely
quiet for 119 s of income"; whatever `Greed-pure` was in Python is unknown and unknowable
from the document.

The informative part is which comparison survives that. **`Rush-horse` agrees to 0.1pp
because "mass the fast unit into the least-defended lane" is a strategy the name fully
specifies** - and it agrees *better* under fog than under full information, which is a small
independent sign that A.3 vision is the regime C.6 was measured under. The three that
disagree are the three whose names leave every important parameter open. That is a statement
about the document, not about either sim.

**This is the entry that should change Part C's process, not its numbers: a balance figure
that cannot be re-derived is not a cross-check, it is a memory.** The sixteen policies
belong in the document, together with their information regime, or at minimum the seed and
the config of the four named ones.

### Finding 6 - a real C.6 disagreement nobody had written down: concurrent units

The sweep has always printed this and no finding or open item mentioned it. Peak concurrent
units per side, 2,880 match-sides:

| | median peak | p90 | max |
|---|---|---|---|
| this sim, A.3 fog | **24** | 41 | **60** |
| this sim, full info | **24** | 42 | **60** |
| C.6 (Python) | 17 | 47 | 57 |
| delta | **+41%** | -13% | +5% |

The median is 41% above C.6's, which is the **largest proportional disagreement anywhere in
the cross-check table** - and it was the one row printed with no significance marker,
because the marker rule was in percentage POINTS and these are counts. `sweep/sweep.lua`
now gives the three peak rows a proportional marker rule of their own (25% out earns "!",
50% out earns "!!"), so the marker column is complete.

Two things follow. **The max is 60, which is the structural ceiling** - three lanes at 200
Levy each, all Spears at 10 Levy - so this sim reaches the bound the geometry allows and
C.6's 57 did not. And **M7's render budget should be sized against 60 per side and a median
of 25, not 57 and 17.** That is a 47% error in the thing that decides whether the renderer
keeps 60 fps in a raid, which is a cheap thing to get right now and an expensive one later.

It is roster-sensitive (a pool of Spear-heavy lines peaks higher than a Horse-heavy one) and
the two models have different rosters, so it is not a claim that Part C's arithmetic is
wrong. It is a claim that **the number M7 needs is 60, and the document currently says 57.**
Note also that the p90 goes the other way (-13%), so this is a difference in the *shape* of
the distribution and not a uniform scaling: this roster spends longer in the many-cheap-body
regime and less time at the very top. Both regimes give the same three numbers to within one
unit, so it is not a fog effect either.

**What is NOT a finding, and should be said explicitly:**

- **The shape of the match reproduces, and that is the substantive cross-validation.**
  Under full information: median 414 s against C.6's 406, p25 300 against 310, p90 600
  against 600, mean 409 against 412, band 76.8% against 77%, decisiveness 80.9% against 85%.
  Two independent implementations written from one document, in two languages with two
  numeric models, on two different policy rosters, agree on every roster-insensitive
  aggregate. **Part C's clock, economy, unit table, keep HP and Spoils arithmetic are
  cross-validated.** Under A.3 fog the length aggregates still hold (median 428, mean 419)
  and it is decisiveness that moves, which is Finding 1's point rather than an arithmetic
  disagreement.
- **C.2's bank-cap clause went UNTESTED by M2, and two of the sixteen lines were spent on
  believing otherwise.** `Granary-bank` and `Counterpunch` both carried notes saying they
  would produce a large wasted-Levy column and so test C.2's *"a hoard cannot be converted
  fast enough to buy tempo, so the cap stops being a strategic dial and becomes a cap on
  waste"*. They do not. `bankHold` is a RESERVE subtracted from `spendable`, not a hoard
  TARGET, so every Levy above the reserve is spent the tick it lands: over 1,440 matches
  `Granary-bank` peaked at 220 banked against a 350 cap and `Counterpunch` at 20 against
  200, and sweep-wide waste was a few tens of Levy in a handful of match-sides. **Neither
  line ever approached a cap, so neither confirms nor refutes C.2.** Both notes have been
  corrected to describe what the lines actually do, and `sweep/sweep.lua` now prints the raw
  `wasted` total rather than a per-match mean that floored any total under 180 to zero. The
  instrument C.2 actually needs is a controlled `BANK_CAP` sweep at 160 / 200 / 300 / 450 on
  `sweep/probe.lua`'s one-control-one-variable method; **nothing in this tree sweeps
  `BANK_CAP` today.** See open item 9.
- **C.5's "keep HP is a pure length dial" reproduces.** Doubling KEEP_HP to 72,000 moved
  the family win rates by 1-4pp (inside the noise at 240 matches) while lengthening the
  median by 63 s and dropping decisiveness from 80% to 60%. That is a third independent
  confirmation, in a third implementation.
- **Q10's central claim survives, under both regimes AND under the recalibrated roster.**
  `Turtle-pure` fills its slot cap with defence and barely attacks; on the recalibrated
  roster it wins **48.8% under A.3 fog and 42.7% under full information** (before: 55.5% /
  42.7%), and **67%** of its fogged wins are by RAZING A KEEP, not on the ladder. There is
  no defensive victory here either. This is the claim most exposed to the recalibration -
  `Turtle-pure` is one of the six lines whose attention threshold was unreachable - and it
  came through it 6.7pp weaker, which strengthens rather than weakens Q10's conclusion.
- **The order-delay window, the supply cap, the slot cap and affordability all held.** Over
  1,440 matches per regime: 0 orders refused by `Sim:queueCommand`, 0 fizzled inside the
  sim, 0 malformed, 0 count-clamped, and 0 over the per-poll rate cap. The only orders the
  gate dropped were the 542 issued inside the last 2 seconds of the clock, which could not
  have executed before it ran out. **The worst line in the pool sent 21 atoms/min of match
  clock against A.11.4's 120 budget**, so the wire is not remotely stressed by scripted
  play - which is now measured and asserted rather than inferred from two constants.
- **The earlier "Spoils at 75% is twice the lever C.6 measured" entry is not repeated
  here.** It was measured the same way as the withdrawn half of Finding 3 - by reading
  family win rates off a 240-match sweep with no error bar - and Finding 2 shows that
  family win rates at this roster size move by 4.8pp on seeds alone, by 27.6pp on one
  line's presence, and by 8.7pp on the information regime. The Spoils *direction* (more
  Spoils, shorter and more decisive
  matches: median 484 s -> 398 s, razed keeps 66.7% -> 80.4%) is a length-and-decisiveness
  effect measured on all 1,440 matches at once and is sound. **The aggression-per-family
  half of it is not, and should be re-measured with `sweep/probe.lua`'s method - one
  control, one variable, a standard error on every row - before it goes near the document.**

### How M2 guarantees the policies cannot cheat

A sweep run by policies that can see or do more than a person measures nothing, so this is
structural rather than a matter of care:

1. **A policy holds no reference to the sim.** It is handed a flat table of integers
   rebuilt by the driver each poll. No sim table, no side table, no unit, no building. There
   is no path from policy code to sim state, so nothing a policy does can move a number in
   the match.
2. **Every order goes through `Sim:queueCommand` with `issueTick` set**, so the SIM enforces
   C.1's order-delay window; the driver asks for `issue + ORDER_DELAY` exactly, the fastest
   a real client can be.
3. **Legality is never evaluated in the policy layer.** Affordability, the slot cap, the
   slot class, the lane supply cap, the count cap and card gating are all judged by the sim
   at the exec tick, per A.4. An order that cannot be paid for is a fizzle, counted and
   printed.
4. **The gate only removes what a UI could not express** - an unknown kind letter, a target
   off the board, a count outside 1..9, an order that would execute after the clock, and
   anything past 2 orders per second. **Five of those six classes are fatal and
   `sweep/verdict.lua` fails on a non-zero count of any of them, plus a sixth assertion on
   the realized rate** (`refused / badKind / badTarget / declinedRate / clamped`, and
   `atomsPerMinMax <= 120`). The sixth class, an order declined for landing after the clock,
   is benign and is deliberately *outside* the clause and not summed into it. **Earlier this
   README claimed the gate failed on every declined class; it failed on none of them**, and
   `measure.lua` merged the one class that mattered (`declinedRate`, a line out-clicking the
   wire) into the one that does not (`declinedLate`, ~400 per sweep). Both are now separate
   numbers in every report.
5. **The cadence is asserted at load, not argued in a comment.** `Policy.POLL = 10` and
   `MAX_ORDERS_PER_POLL = 2` are the only things bounding what the layer asks of the wire,
   and the sim cannot check them - `Sim:queueCommand` validates the delay *window* per atom,
   never the atom *rate*, so raising the poll rate produces no refusal and the input-gate
   clause goes on reporting all-zero while every line clicks five times faster than a
   person. `policy/Policy.lua` now derives the ceiling from A.11.4's `C` bucket (120
   atoms/min per side) and `error()`s at require time if either constant breaks it, or if
   the poll is faster than once a second.
6. **A policy cannot tell which side it is.** The view names its halves `me` and `foe` and
   carries no side index. `sweep/determinism.lua` swaps the seats and requires the exact
   mirror, which is A.2 at the policy layer.
7. **A policy is deterministic.** Its only randomness is its own `sim/Rand.lua` stream,
   seeded from the match seed and its slot; `tools/greps.sh`, `tools/greps.lua` and
   `tools/comptest.sh` all run over `policy/` and `sweep/` with 0 hits and 0 failures.
8. **A policy cannot see for free, and the one thing that buys sight is an ORDER.** The four
   scouting lines get their vision the only way the fog doc allows: by putting a body in a
   section, through `Sim:queueCommand`, at the same order delay, out of the same bank, after
   the same reserve, and costing one of the two orders that poll. `Policy.darkLane` -- the
   rule that decides where to look -- reads `lit`, `seen` and `maxPos` of the polled side's
   OWN lanes and nothing else, so a scout is never aimed using the information it exists to
   go and get. And it returns 0 when a lane is fully visible, which is why the
   full-information regime issues **zero** scout orders in a whole sweep and stays a genuine
   upper bound rather than the same roster paying for something it is being given.

`sweep/determinism.lua` asserts these behaviourally over 40 random pairings plus all 16
lines playing themselves - byte-identical atom streams on replay, immunity to other matches
being played in between, and an exact mirror under a seat swap - **and the M2 gate runs it
once per information regime**, because each regime is a different set of reads inside
`Policy.fillView` and proving one deterministic proves nothing about the other.

**And the thing this list did NOT cover until Finding 1 above.** The accurate pair of
statements is:

- **No policy ever got anything a real CLIENT could not have.** That is what points 1-7
  establish and it remains true.
- **Until Finding 1, every policy got things a real PLAYER could not see.** Ruling 1 is
  about what the client holds; A.3's default-vision table is about what is rendered, and it
  is a strictly smaller set. The earlier sentence here - *"the policy layer never once got
  something a real client could not have"* - was true and was answering the wrong question.
- **And until Finding 7, the fix to that had a mirror-image hole nobody had checked: a
  policy asking for something it could not be given.** Filtering the view answered "can a
  line SEE more than a player?"; it left "is a line ASKING for something the filtered view
  never supplies?" untested, and eleven of sixteen were. A dead read is as corrupting as a
  privileged one - it silently substitutes a different strategy and reports the result as
  the strategy its source describes. **This is now structural rather than a matter of
  care**: `policy/lines.lua`'s `line()` constructor refuses at load time to build a line
  whose `reactAt` is below `Policy.REACT_MIN`, with a message naming the line, and
  `sweep/fogaudit.lua` measures the residue - the lowest position each line ever sees an
  enemy unit at, and the share of its threat detections A.3 deletes, which must be 0.0% for
  all sixteen under `a3`. The tap `fogaudit` rides on (`driver.run`'s `onPoll`) has its
  return value discarded by the driver, so a measurement of what the lines can see cannot
  itself become a channel.

The policy layer also clears M1's cross-implementation bar. A driven match
(`Rush-horse` vs `Turtle-eco`, seed 777001, A.3 fog) produces `stateHash 624664748`,
`logDigest 895669454` and 209 atoms under **both** Lua 5.5 (native 64-bit integers) and
LuaJIT 2.1 (Lua 5.1 semantics, doubles) - the two numeric models that would disagree if any
arithmetic in the policies or the driver were not integral. **These three numbers are a
fingerprint of the ROSTER, not a ruleset golden: they moved when Finding 7 recalibrated the
sixteen lines (from `1175083558` / `236876665` / 211), and they are supposed to. The
`rulesHash`, `stateHash`, `logDigest` and `SUITE HASH` that `harness/selftest.lua` asserts
did not move, because nothing under `sim/` was touched.**

    lua    -e 'package.path="./?.lua;"..package.path' sweep/determinism.lua 40 a3
    luajit -e 'package.path="./?.lua;"..package.path' sweep/determinism.lua 40 a3

**The report, the gate and the statistics are also cross-implementation clean.** The exact
invocation matters and is given here because the previous version of this paragraph quoted
p-values without the sample size they came from and they did not reproduce. Under both
interpreters, `lua sweep/famstat.lua 2 1 20000` (480 matches, A.3 fog, 20,000 shuffles,
`STAT_SEED 20260812`) prints bit-identical values:

| | Lua 5.5 | LuaJIT 2.1 |
|---|---|---|
| family spread | 13.3pp | 13.3pp |
| `P(null >= measured)` | 86.3% | 86.3% |
| `P(null < 10pp)` | 6.2% | 6.2% |
| Kendall S (build spend vs win) | -37, p = 9.6% | -37, p = 9.6% |

Every statistic in M2 is computed in integers with an integer PRNG and an integer Newton
square root, for exactly this reason: a p-value that depends on the interpreter is not evidence.

`tools/ci.sh 1000` is **GREEN (5/5 steps, 1000 logs, 19,644,042 ticks, 0 desyncs)** with the
whole of M2 in the tree, under **both** Lua 5.5 and LuaJIT 2.1: nothing under `policy/` or
`sweep/` touches `sim/`, and `rulesHash` is unchanged at 297242539. `tools/greps.sh` and
`tools/greps.lua` both report 0 hits over the 2 files in `policy/` and the 7 in `sweep/`,
and `tools/comptest.sh` 0 failures over both.

---

## M3 part 1 - the modifier layer, SIM SIDE (2026-08-21)

All forty cards from `IDLE_BATTLE_DECISIONS.md` D.3 - the NORMATIVE wordings, not the
older ones in `IDLE_BATTLE.md` section 7 - now exist in the sim: the hashed card table,
the loadout plumbing, the Q4 S1-S10 stacking machinery, the seventeen `[Rule]` cards'
runtime including the three verbs, and the Q3/Q12 hidden-affinity wheel. **Part 2 is the
PERCEPTION half**: the fog effects of Divination, Omen, Veil and the Shrine's reveal
pulse, which belong to `fog/Fog.lua` and not to `sim/` (A.5 grep 1 makes that
structural), plus the M3 gate tooling described at the end of this section.

**Where the cards live, and why.** `Rules.CARDS`, inside `sim/Rules.lua` itself rather
than a sibling file, because the file's own first paragraph is the argument: rulesHash
must be computed over ONE artifact that cannot drift silently, and this directory has
already lived through what a value outside the hash costs. A card's id IS its index -
D.3's own order, Swarm 1-8, Fortress 9-16, Boom 17-24, Raider 25-32, Mystic 33-40 - and
every field of every card is walked by the hash in `CARD_FIELDS` order.
`tools/rulescover.lua` now fails the build on a card field outside `CARD_FIELDS`, a
non-channel channel reference, a broken wheel matrix, or an unclassified top-level key,
in both directions, like everything else in the ruleset. The wheel is `Rules.WHEEL` over
`WHEEL_TYPES` in Q3's vector order (Swarm, Boom, Mystic, Fortress, Raider); it refuses to
LOAD unless it is antisymmetric with zero diagonal and zero row sums, because those three
properties are what make the rainbow neutral, mirrors exact zeros, and one integer edge
enough for both sides.

**Loadouts are real.** `Sim.new(rules, seed, loadoutA, loadoutB)` validates at
construction: an array of exactly 5 slots, each 0 (empty) or a card id 1..40, integral,
no duplicate non-zero id. Duplicates are banned on Q6's own arithmetic - "ten cards gives
252 loadouts" is C(10,5), combinations WITHOUT repetition - and a violation is an
`error()`, not a fizzle, because a malformed loadout is a broken handshake rather than a
player mistake. PARTIAL loadouts are deliberately legal in the SIM (the M3 milestone
tests every card alone; D.1's first playable is "zero modifiers"); "exactly 5 real
cards" is the loadout UI's rule and lands at M8 (INTERPRETATIONS 13). The loadout was
already inside `Hash.state` from M1; what changed is that it now DOES something.

**Stacking is one machine (Q4).** A card's unconditional `[Stat]` delta is summed into
`sd.chan` once at match start - the same per-side channels the building auras already
travel - and every scoped or time-varying delta joins the same sum through a `*Points`
hook at the point of use: additive within the channel, clamped once from `R.CLAMPS`,
applied once, floor once (S2, S4, S7). Nothing floors separately, nothing multiplies,
and the state holds the UNclamped sum (Chaff + Breeding Pits shows -30 in the hash and
pays as -20). Discord is S2's "opponent debuffs are ordinary local arithmetic" made
concrete: install writes +15 into the OTHER side's unitCost channel and nothing else
ever knows. D.2's saturation warnings reproduce exactly - Vanguard + War Drums + No
Retreat sum to 84 points and land as the +35 clamp; the selftest pins it.

**The `[Rule]` runtime.** `sim/Mods.lua` (new, held to every determinism rule, and
discovered automatically by both grep implementations and comptest). Sim.new hands it a
table of the sim's own internals - credit, spend, queueCredit, the one death path, the
one mitigation function - so no card mechanism exists twice. Per-side runtime state all
lives INSIDE the hashed state: Golden Age's latch, Investment's amount and maturity,
War Drums' expiry, both verb cooldowns and Vanguard's three per-lane counters as
`sd.mods` keys (sorted into `sd.modsOrder`, which `Hash.state` already walked); Endless
Ranks' Muster charges, Raiding Party's Bypass and Counterwall's accumulator in the lane
fields M1 shipped for them; the Vanguard flag on the unit (`u.vg`).
`tools/hashcover.lua` gained a carded fixture that proves every one of those keys moves
the hash, and `harness/runner.lua`'s invariants now check the mods block (sorted, no key
outside the order array, integral) and the Boomtown-raised slot cap. The verbs are real
dispatch: uppercase `I`/`E`/`L` per A.11.2, case-sensitive, routed to Investment
(one outstanding, 25/block, pays 180% at the first Levy tick at or after exec + 450),
Scorched Earth (600/block to the up-to-three deepest enemy units in the lane, S10 ties,
300-tick cooldown, fizzle-not-spend on an empty lane) and Ley Line (own-half units to a
second lane at the same x, ascending id, per-unit supply fit, 450-tick cooldown). A side
that does not own the card fizzles the verb exactly as every side did in M1.

**New named hooks, and why each earned its place** (the M3 HOOKS block at the bottom of
`Sim.lua` is the full current list):

| hook | card | why no existing site fit |
|---|---|---|
| `levyTickPoints(sim, sd) -> pts` | Golden Age, Granary Reserves, Hex | phaseIncome read `sd.chan` directly; a dynamic levyTick source must join that sum BEFORE its one clamp |
| `levyFlatPoints(sim, sd) -> flat` | Trade Routes, Surplus | same, for the levyFlat channel |
| `unitCostPoints(sim, sd, lane, t) -> pts` | Late Levy | the time gate must join the unitCost sum inside `unitCostOf`; the existing `deployCost` hook is post-clamp and using it would touch the quantity twice (S3) |
| `bldImmune(sim, owner, b) -> bool` | Deep Foundations | a target FILTER: no points-hook can veto a hit. A true verdict loses the hit - no retargeting, and a Bow's target slot is consumed |
| `onStructHit(sim, sd, es, u, b, pre)` | Ward | the reflect needs the per-hit PRE-mitigation figure, which only exists inside `unitDamage`; `onExtraDamage` (its originally listed site) sees only aggregated pend |

Raiding Party's Bypass SKIP is native `Sim.lua` geometry rather than a hook - once
`ln.bypass` holds a building id, this side's Horses ignore that candidate in movement and
targeting; 0 (all of M1) matches nothing. The trigger that consumes the flag is
card-conditional and lives in `Mods` at `onResolveStart`.

**Affinity and the wheel.** Read Q3 before touching this: THERE IS NO DOMINANT TYPE.
The ruling kills the label - "there is no tie because there is no label" - so the sim
stores the loadout's affinity VECTOR only long enough to compute the bilinear edge
`sum(m[i] * t[j] * W[i][j])` in [-225, +225] at Sim.new, writes it into `sd.wheelNum`
(one side positive, the other its exact negative), and discards the vectors. Nothing
player-facing ever names a type. The multiplier is the floor-only integer form Rules.C
documents, applied by `unitDamage` as the single final multiplier outside every clamp on
EVERYTHING a unit deals - enemy units, buildings and the keep alike, per Q3's "a single
final multiplier on damage dealt" (INTERPRETATIONS 9; damage no army dealt - towers, the
Trap Pit, Ward's reflect - carries no wheel, because a tower has no type to read an edge
from). Neutral exists and is reachable: the 3-3-3-3-3
rainbow scores 0 against everything (the selftest proves it against two different pure
opponents). Every card is pure 3/0 in its home archetype except **Granary Reserves,
2 Fortress / 1 Boom** - the one split the documents force, because section 9's Turtle
Bank must total 8F/7B with pure Boom (its own secondary) as its worst matchup, and the
selftest pins both numbers (-120 against pure Boom, +15 against pure Swarm).

**Timed effects across a pause: automatic, and verified rather than assumed.** Q11's
rule is that every timed effect is denominated in SIM TICKS and the counter does not
advance while halted. The sim clock is ACTIVE ticks (A.9) and `sim/Mods.lua` reads
`sim.clock` and nothing else - no wall clock exists anywhere in `sim/` for a card to
reach (grep 3's sibling, enforced by comptest) - so a pause is simply the absence of
`tick()` calls and no card can tell it happened. The selftest states it as a check: a
carded match mid-War-Drums-window, mid-Investment-countdown and mid-Hex-window, ticked
in ragged chunks against one ticked straight, is bit-identical.

**The goldens moved, together, deliberately.** Cards are ruleset content, so rulesHash
changed - a hard compatibility break (A.11.1, G.4), every pre-M3 recorded log is
invalid, and all four goldens were regenerated in this one coherent state, `GOLDEN_SUITE`
from the full 1,000-log milestone fuzz:

| golden | pre-M3 | **M3 part 1** |
|---|---|---|
| `GOLDEN_RULESHASH` | 333968378 (`5iu3ne`) | **767294897 (`cotsj5`)** |
| `GOLDEN_STATE` (hand.iblog, tick 260) | 1822913174 | **1939244196** |
| `GOLDEN_LOGDIGEST` (same log) | 1455081792 | **1455081792 - unchanged** |
| `GOLDEN_SUITE` (1,000-log milestone) | 2005649413 (`640zp`) | **1912059909 (`me2v9`)** |

**Cardless matches are byte-identical to M1 in GAMEPLAY, and here is the reasoning, not
just the claim.** With two empty loadouts `Mods.install` returns before touching the sim:
every hook stays nil, so every new call site short-circuits on the same `if
sim.hooks.x` pattern M1 shipped; the only new unconditional work on the tick path is the
Bypass compare against `ln.bypass`, which is 0 in every cardless match and matches no
entity id; and no state field was added or reordered, so `Hash.state`'s walk is
layout-identical. Therefore every gameplay integer of a cardless match - positions, HP,
banks, counters, verdicts - is exactly M1's, which is why `GOLDEN_LOGDIGEST` did not
move (the digest covers commands only, and hand.iblog's commands are untouched) and why
selftest section 3 still asserts the same spears on the same 4 HP at the same tick 970.
`GOLDEN_STATE` and `GOLDEN_SUITE` DID move, for exactly one reason: `Hash.state` folds
`rulesHash` in as its first term, so every stateHash in the tree shifts when the ruleset
grows. Same match, new signature - which is correct, because a pre-M3 client and an M3
client must refuse each other at the handshake rather than agree until the first card.
(`SUITE` also moved because the generator changed: see below.)

**The milestone fuzz now plays cards.** `harness/gen.lua` deals a random legal 5-card
loadout to both sides in HALF its legal sample (and half the chaos sample, whose random
`I`/`E`/`L` atoms therefore exercise both real dispatch and the no-card fizzle), and its
affordability model reserves unit Levy at the unitCost clamp CEILING - Discord ended the
era when every cost modifier in reach was a discount, and an over-reservation only ever
issues fewer orders. The legal pass still asserts ZERO fizzles, over discounts, free
deploys, surcharges and all: the 1,000-log run above is 0 desyncs, 0 legal-pass fizzles,
0 invariant failures, with the four arrival patterns, the mirror and the interleaved
fine pass all applied to carded matches. The generator issues no verb atoms itself
(their legality windows are a policy question); the chaos pass throws them.

**Tests added** (`harness/selftest.lua`, sections 12-21, 333 new checks - 638 total,
was 305; **641 since the M3 fix pass** below reworked the wheel-scope and Investment
pins - one section per card CLASS): the card table, the pool shape and the
hash-coverage probes; loadout validation; every `[Stat]` channel moved and clamped at
its number, including the D.2 saturations; the economy rules (Trade Routes' ramp and
ceiling, Surplus before income, Granary Reserves' half-cap conditional, Golden Age
latching at exactly 700 earned on the Levy tick at 2380 and never unlatching, Hex's
[0,200) window recurring at 400); the S5 arbitration head-to-head (Endless Ranks
outranks Conscription by card id, one free unit per order); deaths and razings (Blood
Tithe with and without the repel overlap, Plunder replacing 75 Spoils with 120 on a
100-cost granary,
Counterwall accumulating 20 and paying 4 on the clear transition, War Drums stamping
kill-tick + 200); the board rules (Deep Foundations immune only while the front slot
holds, Rapid Masonry's 45-Levy rebuild consuming the mark, Watchfires reaching 480,
Ward reflecting 4 per 8 dealt in lockstep, Miasma's 8 only past the midline); all three
verbs' execute, fizzle, clamp, cooldown and cap paths; Raiding Party's bypass board
(horse past the wall at 1940, spear still parked at 1240, no horse-sized dent in the
wall); the wheel at maximum edge on every target class (spear-into-horse 24 -> 25,
horse 44 -> 41 on the -6% side and 44 -> 46 on the +6% side, and - at horse scale,
where floor cannot hide it - the halved 22 becoming 23 into a palisade and into the
keep), at zero (mirror, rainbow) and at Q3's own -120 worked example; the information cards proven field-identical no-ops;
the ragged-chunk pause check; and a carded determinism miniature - 8 random-loadout
matches through all four arrival modes plus the mirror, and each of the 40 cards ALONE
through an arrival replay with invariants.

**What part 1 leaves for part 2, exactly.**

1. **The perception effects** of Divination, Omen, Veil and the Shrine pulse, in
   `fog/Fog.lua` and the policy view, consuming `Mods.INFO_EFFECTS` and the hashed
   `SHRINE_PULSE_*` constants. Omen needs its own temporal channel (fog open item 16).
   Their sim-side existence - ids, affinity, class, hashing, loadout legality, the
   selftest that proves them field-inert - is complete and must not move.
   **DONE in part 2 - the section below.**
2. **The M3 gate tooling**: Part E's milestone asks for each of the 40 cards
   individually and 200 random 5-card loadouts per side run through M1's bit-identical
   test at FULL length on BOTH interpreters, plus the clamp-saturation report (every
   channel's summed value across the 200, naming the cards that saturate together).
   The selftest carries the fast miniature of the first half; the fuzz carries ~500
   carded full-length logs; the dedicated gate script and the report do not exist yet.
   **DONE in part 2 - `tools/m3.sh`, results below.**
3. **Sim-vs-policy interaction**: none of the seventeen M2 lines knows cards exist.
   Whether M2's roster should play loadouts is an M3-part-2 / doc-owner question
   (open item 24). **Still with the doc owner; part 2 changed nothing here.**

---

## M3 part 2 - the PERCEPTION half and the gate (2026-08-21)

Part 1 put the forty cards in the sim; part 2 is everything the four
*information* cards and the Shrine's reveal pulse actually DO - which is
render/policy-side by design (Ruling 1 shares all state; A.5 grep 1 keeps
`sim/` unable to ask what is visible) - plus the milestone's own gate script.
The EFFECTS block in `fog/Fog.lua` consumes `sim/Mods.lua`'s declared
`INFO_EFFECTS` handoff, resolves the three cards through the hashed
`Rules.CARD_BY_KEY` and the Shrine by catalogue key, and REFUSES TO LOAD on a
handoff entry it does not model - an under-modelled information source must
fail the build, not silently render as fog. **Nothing in `sim/` moved:
`rulesHash` is still `767294897` (`cotsj5`), and all four goldens are exactly
part 1's.**

**What each effect is, as shipped** (doc section 6 and the D.3 wordings; every
line below is pinned by a named check in `tools/fogtest.lua` 16-21):

- **Divination** - all COMPLETED enemy buildings, slot and identity,
  continuously, every lane, ignoring both the section rule and the front-slot
  shield. NEVER HP - there is no HP in the return and no field in the scry
  memory layer an HP could travel in - and never under-construction, so a
  rebuild appears on the tick it completes and a razed wall vanishes at the
  next observation ("including rebuilds", and how a diviner learns a wall
  fell). Beaten by Veil absolutely: the scry comes back EMPTY and the memory
  layer is not stamped at all. Self-announcing: the watched side's `scried`
  mark is up from tick 0.
- **Omen** - enemy deploy orders surfaced as issued: LANE AND COUNT ONLY,
  never unit type (proved by indistinguishability: five Horses and five Bows
  produce bit-identical signals). It is a FILTER over the shared command
  bucket, never new data: an atom is surfaced while it is pending and the
  clock is within one ORDER_DELAY of its exec tick - the doc's "one
  order-delay before it takes the field", derived from the hashed exec field
  without touching wire metadata. The count surfaced is clamped exactly as
  `execDeploy` will clamp it. The window closes when the order executes; no
  omen signal is ever remembered (a stale wave warning is a ghosted stack
  wearing a bell). Under `full` vision the same channel fills with no card -
  the queue is on every client under Ruling 1, so the upper bound stays a
  strict superset. Two stated under-estimates: a resend that only just made it
  surfaces late, and an atom issued with a padded delay surfaces from
  `exec - ORDER_DELAY` rather than its true issue tick (under the M2 driver,
  which issues at minimum delay, the window IS the issue tick exactly).
- **Veil** - THE PRECEDENCE RULE, one sentence: **Veil beats every route that
  does not put a body there - Divination's scry, the Shrine pulse's occupancy
  scan, and the Watchtower's remote section light - and loses to physical
  presence: a unit of yours standing in the section, and contact.** Veil
  conceals BUILDINGS only, never units; it is the one non-announcing source
  (no mark, in either direction); and suppression is ABSENCE, not a recorded
  zero - a veiled scry/scan never stamps its memory layer, so knowledge earned
  through a body is never erased by a lying refresh, and "a wall you have
  touched that the scry refuses to show" remains the sanctioned inference
  route ("I am against Veil"). See open item 25 for the one place the two
  binding texts diverge and this reading had to choose.
- **Shrine reveal pulse** - while a completed Shrine of yours stands (under
  construction does not pulse; the effect dies with the building and joins a
  window already in progress), live at tick t iff
  `t mod SHRINE_PULSE_EVERY < SHRINE_PULSE_TICKS` (the hashed 200/30, anchored
  at tick 0 exactly like Hex's schedule): ALL enemy units in ALL lanes at full
  detail, plus enemy building OCCUPANCY only - not identity, not HP, and
  scaffolding counts as occupancy because it occupies the slot. The scan
  freezes between pulses (doc section 4 verbatim), never lights a section and
  never marks ground explored (open item 27), never touches the enemy keep's
  remembered HP (the keep is not a building), and is self-announcing: the
  scanned side's `scanned` mark is up exactly while the window is.

**The memory rule the pulse and the scry forced, and it is the load-bearing
design decision of part 2: the store is now THREE PARALLEL LAYERS, and no
layer's write may ever touch another.** Full sight (the section rule and
contact) writes slot + identity + HP + done, exactly as before. Divination
writes identity + tick. The pulse writes occupancy + tick. A scry that
recorded an HP it cannot see would be fabricating evidence - worse than fog -
so partial sight is never promoted into the full record (`fogtest` section 20
asserts the full layer stays untouched through a scry-and-scan story).
What a consumer BELIEVES is composed in exactly one place,
`Fog.believedBuilding`: **the freshest layer wins; a tie goes to the layer
that knows more (full > scry > occ); an empty scry never beats a same-tick
occupancy scan** (scaffolding satisfies both "nothing completed stands there"
and "something stands there", and the scan is the one that saw it). Enemy
UNITS are still never remembered, from ANY source: what a pulse showed of an
army is gone when the window shuts. Everything above holds the existing
freeze rules: a frozen full record still shows a razed wall until a fresher
layer says otherwise, and a fresher occupancy ping of EMPTY out-votes a stale
record, however confident.

The policy view grew the matching fields, filled only through `fog/Fog.lua`:
per foe lane `omen`/`omenN` (the temporal channel, fog open item 16 - CLOSED)
and `frontOcc`/`backOcc` (believed occupancy, which can be 1 with `b` 0 after
a scan); per side the Q9b marks `scried`/`omened`/`scanned` on `me` and the
`scan` flag on `foe` (my own pulse is rendering their board right now, so a
carded line can tell confirmed-empty from dark). None of the seventeen M2
lines reads any of them (open item 24 gates that), so every M2 number in this
README is unchanged by part 2 - measured, not assumed: `lua sweep/verdict.lua 6
500000 fog` on the part-2 tree reproduces Finding 10's gate column exactly
(426 s / 76.1% / 80.1% / 16.8pp, still RED on family spread, which is open
item 4's question and not this pass's), and `sweep/determinism.lua 40` passes
under both regimes with the grown memHash.

**Tests.** `tools/fogtest.lua` grew from 464 to **667 checks** - a section per
card (16 Divination, 17 Omen, 18 Veil incl. the precedence rule route by
route, 19 the pulse), the three-layer composition pinned case by case (20),
the tower/card compositions from both seats plus carded memory determinism
(21), and **section 22, the MUTATION suite: a copy of `fog/Fog.lua` with one
effect surgically disabled is loaded from /tmp (never the tree) and the named
checks that effect carries must flip** - divination-off, omen-off (its raw
`pendingDeploys` filter must keep working, proving the mutation surgical),
veil-off, pulse-off, and watchtower-off, each with a needle-count assertion so
a refactor cannot silently defuse the mutation. All 667 pass under Lua 5.5
and LuaJIT 2.1.

**The M3 gate: `tools/m3.sh`** (a sibling of `ci.sh` and `m2.sh`; its header
argues why, and `tools/m3gate.lua` is the implementation). Part E's milestone
verbatim, three steps and a verdict:

1. **Each of the 40 cards individually**, full 6,000 ticks, fixed seeds, in
   TWO pairings - both run through straight/replay/REORDERED-queueing/MID-RUN-
   ARRIVAL and the generator's own interleaved run as a fifth pattern:
   * *card-vs-empty* - the minimal delta from the proven M1 game (a desync
     implicates the one card) and the ASYMMETRIC install case, where a
     side-biased Discord write or hook registration would hide; A.2-mirrored
     to prove it reads the same from both seats.
   * *card-mirror* - two live copies of one mechanism: S5 arbitrating with
     itself, Discord crossing both ways, the wheel edge at its exact mirror
     zero, every hook registered twice.
   The three VERB cards get seeded verb atoms INJECTED (owner side plus a
   no-card fizzle from the other seat), because the generator deliberately
   issues no verbs and a verb card whose verb never fires would pass
   vacuously; injected logs are re-trimmed to their new true end so all four
   arrival modes see the identical atom set (which costs those three cards
   the fifth pattern - the generator's own run did not contain the injected
   atoms, so its hash is dropped rather than compared against a different
   match).
2. **200 random legal 5-card loadouts on BOTH sides** from a frozen seed
   schedule (base 930000), full length, the same four patterns, zero
   mismatches allowed, every 8th pair A.2-mirrored, verbs injected wherever a
   drawn side holds a verb card (115 of the 200 pairs did).
3. **The clamp-saturation report** over the same 200 drawn pairs: per channel,
   the per-side summed potential - the STATIC sum measured off the installed
   sim's own `sd.chan` (Discord's cross-write included) plus the maximum the
   loadout's conditional/time-varying cards can add, derived from the hashed
   card table - against the Q4 clamp, with every saturating combination named
   and counted. `slotCap` is compared as the ABSOLUTE `SLOT_CAP + points` the
   sim itself clamps. Plus the **applied-value probe**: every drawn side that
   saturates `unitCost` (statically, or past Late Levy's gate) deploys real
   Spears at tick 25 and tick 3,005 on a fresh sim of its own pair, and the
   cost the sim charged must equal the tool's own independently clamped
   arithmetic - the step observes the sim APPLYING the clamp, with the exact
   per-channel clamp arithmetic pinned by selftest section 13. (The step's
   first revision instead clamped a number inside the tool and tested it
   against the same bounds - "0 of 6,000 outside their clamp" would have
   printed 0 with `Sim`'s `clampCh` deleted; the probe goes red under exactly
   that mutation, 11 failures on this draw.)
4. **Verdict** with hard exit codes, and the caveats printed on the green
   path: the perception effects are proved by `fogtest` inside the M1 gate,
   not here; cross-machine needs a second machine; balance is M2's question;
   and a green run proves the cards compute IDENTICALLY on both clients, not
   that they compute what D.3 says - a card wrong the same way on both
   machines sails through every hash, and D.3 conformance is the selftest's
   job (one exact pin per card mechanism, inside `ci.sh`).

**Measured results, shipped tree** (`sh tools/m3.sh 200` and the same under
`"$(which luajit)"`; the two interpreters' outputs agree hash for hash):

| step | Lua 5.5 (native integers) | LuaJIT 2.1 (5.1 semantics, doubles) |
|---|---|---|
| cards: 80 matches (40 x 2 pairings), 360 runs | **SUITE HASH 116896602 (`xlhzu`)**, 0 failures | **116896602** - identical |
| loadouts: 200 matches, 825 runs | **SUITE HASH 448422185 (`ez8rt`)**, 0 failures | **448422185** - identical |
| clamp: applied-value probe (19 sides: 11 saturating + 8 controls, 2 skipped for S5) | **every charged cost = clamped arithmetic** | **byte-identical report** |
| verdict | **M3 GATE: GREEN (3/3)** | **M3 GATE: GREEN (3/3)** |

The suite hashes fold every run's terminal stateHash, terminal tick, logDigest
and accept tally, so "identical" above means every integer of every one of the
1,185 runs agreed across the two numeric models. 6 of the 80 card matches and
22 of the 200 loadout matches ran the full 6,000 ticks; all 280 terminated.

**Where saturation actually occurs, from the report** (all of it LEGAL - D.2
calls saturation the structural replacement for the old headcount cap - and
all of it clamped: the report's job is the loadout UI's "channel saturated"
warning population):

| channel | clamp | sides touched (of 400) | min | max | saturating |
|---|---|---|---|---|---|
| unitCost | [-20, 40] | 173 | -40 | +15 | **13 low** (breedingPits+lateLevy x8, breedingPits+chaff x3, chaff+lateLevy x2) |
| unitDmg | [-35, 35] | 162 | 0 | +70 | **23 high** (every pair drawn from noRetreat / tideOfBodies / vanguard / warDrums) |
| levyTick | [-30, 40] | 164 | -30 | +60 | **10 high** (goldenAge+pressGang x6, goldenAge+granaryReserves x4) |
| march | [-40, 50] | 89 | 0 | +65 | **2 high** (raidingParty+scentTrails) |
| all others | - | - | inside | inside | **0** |

The Raider damage stack and the Swarm cost stack saturate exactly as D.2
warned (its Vanguard+War Drums and Chaff+Breeding Pits examples both occurred
in the draw - 3 sides each - and every occurrence is inside the counts above);
`goldenAge+pressGang` at +60 over a +40 clamp is the same phenomenon on
levyTick that D.2 did not list, worth a line in the loadout UI's warning
table. `repelRefund` is untouched because no card writes it (Counterwall pays
through its own accumulator, not the channel).

**`tools/ci.sh` stays the fast pre-commit gate and is unchanged in meaning**:
still GREEN at 1,000 logs under both interpreters on part 1's goldens
(`SUITE HASH 1912059909`), with `fogtest`'s 667 checks now inside it. `m3.sh`
is its own entry point, run to certify the milestone.

---

## M3 fix pass - closing the adversarial review (2026-08-21)

An adversarial review signed off the determinism half of M3 (every gate
reproduces under both interpreters) and required four fixes before the
milestone closes. All four are landed. **Nothing executable in `sim/` moved -
the one `sim/` file touched is `Rules.lua`, comments only - so `rulesHash` is
still `767294897` (`cotsj5`) and all four goldens are exactly part 1's.**

1. **The wheel-on-structures contradiction: the CODE was right; the record and
   the test were wrong, and both are fixed with no golden moving.** The code
   has applied the wheel to everything a unit deals - units, buildings, the
   keep - since part 1, and Q3's normative sentence backs it ("applied as a
   single final multiplier on damage dealt"; Q12 repeats "6% damage dealt at
   maximum focus").
   But `Rules.lua` INTERPRETATIONS 9 said "UNIT damage only", this README
   echoed it, and the selftest's "proof" passed only by floor coincidence at
   spear scale: the spear's halved structure figure is 8, and
   `floor(8 * 1.06)` is 8 again, so the check could not tell the two readings
   apart. A favourable matchup razing structures ~6% faster is coherent with
   Q12's quiet global edge. INTERPRETATIONS 9 is rewritten to the Q3 reading,
   the README echo above is corrected, and the selftest now pins the scope at
   HORSE scale, where floor cannot hide it: a max-edge horse deals **23** per
   resolve to a palisade and to the keep (not the unwheeled 22), and **46**
   into a spear (44 unwheeled) beside the -6% side's 24 -> **22** - every
   number verified by driving the sim under both interpreters before pinning.
2. **Investment's payout was under-pinned.** The selftest asserted
   `earned >= e0 + 90`, which a payout mutated to 360% also satisfies - the
   review proved the doubled payout passed every gate. The check is now EXACT
   in the neighbouring Plunder check's style: earned minus the counted
   window's own income (13 Levy ticks at 10 apiece) must equal 90 to the
   Levy. Re-running the review's own mutation against the new check goes red
   ("got 180, want 90"), the only failure of 641.
3. **The clamp gate's "effective values outside their clamp: 0 of 6,000" line
   was a tautology** - `tools/m3gate.lua` clamped a number itself and tested
   it against the same bounds, so it printed 0 even with `Sim`'s `clampCh`
   deleted. Replaced by the applied-value probe described in step 3 above,
   which deploys real Spears and compares the charged cost against
   independently clamped arithmetic; under exactly that `clampCh` mutation
   the probe fails 11 times on this draw and the step exits red.
4. **Prose arithmetic:** "Plunder replacing 67 Spoils with 120" was palisade
   math (`floor(90 * 75%)`) quoted against the check's 100-cost granary
   fixture; the correct replaced figure is **75**, and the README line and
   the selftest comment now say so. The assertion itself was already exact.

`tools/m3.sh` additionally states on its green path the caveat the review
asked for: **a green M3 proves the cards compute IDENTICALLY on both clients,
not that they compute what D.3 says** - a card wrong the same way on both
machines sails through every hash - and D.3 conformance is the selftest's job.

**The one accepted deviation, stated rather than implied: open item 26.**
Watchfires' Q9b REVEAL half ("reveal their lane out to that range") is
UNSHIPPED, because `IDLE_BATTLE_FOG.md` - later and binding - restates Q9b's
table without that row; the RANGE half is live and pinned (the tower reaches
480), and `fog/Fog.lua`'s tail block names the gap. M3 closes carrying
exactly this one known deviation from D.3/Q9b, pending the doc owner's
ruling on open item 26.

Post-fix numbers, identical under both interpreters: selftest **641** checks
(was 638), fogtest **667**, `ci.sh 1000` green on unchanged goldens
(`SUITE HASH 1912059909`), `m3.sh 200` green 3/3 with the cards/loadouts
suite hashes unchanged (`116896602` / `448422185` - the fix touched no sim
arithmetic and no gate seed).

---

## M4 - two sims, one client: the wire and the reliability shim (2026-08-21)

Part E states the milestone:

> Two instances of the sim in one addon session, fed the same log through a fake
> transport that can drop, delay and reorder messages on command. **MILESTONE:
> state hashes match at every epoch for 6,000 ticks with 10% packet loss and up
> to 3 s of jitter. Rollback repairs every late command. A forced deep desync is
> repaired by the `Q` full-log replay path from tick 0 - which requires both
> loadouts, and is the concrete demonstration that Ruling 1 made recovery real.
> This proves the reliability shim before a single real message is sent.**

**How to tell: run `tools/m4.sh` and read the last line.** It prints `M4 GATE:
GREEN` or `M4 GATE: RED` with the failing steps named. Run it twice - once per
interpreter - and compare the four per-step `SUITE HASH` lines, exactly like the
M1 fuzz's one number.

**WHAT WAS BUILT, AND WHERE THE ONE DESIGN DECISION LANDED.** Three modules
under `net/` (the codec, the fake channel, the shim - the file-layout section
describes each) plus `net/Snap.lua`, which is the decision: **A.12's rollback
snapshot lives OUTSIDE `sim/`, and `sim/` was not touched by M4 at all.** The
snapshot is consumer state - the sim never rolls back, its caller does, the way
the renderer owns fog memory - and everything it must carry is either hashed
state (whose layout `Hash.state` fixes), a named derived cache, or the
accepted-command log. The risk of an outside copy - a future sim field the copy
misses - is answered by a guard an inside implementation would not have needed
and this one gets for free: **every restore re-hashes the restored sim and
errors unless it equals the captured hash**, so a hashed field this file fails
to carry fails the very next rollback loudly, and an unhashed one is exactly
what `runner.invariants` (run on both terminal sims of every M4 match) exists
to catch. Two further structural choices inside the copy: `bucket` and `seen`
are REBUILT from the copied log rather than copied (the log is already in
canonical order, so there is no second copy of A.4's ordering to drift), and
restore is IN PLACE (hook closures keep reading the sim they were installed
on; `sim/Mods.lua`'s own header planned for exactly this).

**THE GAME DID NOT CHANGE, PROVED THREE WAYS.** `rulesHash` is `767294897`
before and after; `tools/ci.sh 1000` and `tools/m3.sh 200` are GREEN on the
unchanged committed goldens under both interpreters; and every M4 net match is
compared not only endpoint-against-endpoint but against a **no-netcode
reference run** of the same issued atoms through `harness/runner.lua` - the
M1 lens - at every epoch, at the terminal hash, the terminal tick and the
logDigest. A shim that agreed with itself but changed the game cannot pass
that third comparison.

**HOW A NET MATCH IS DRIVEN.** A `harness/gen.lua` legal log (the generator M1
trusts) is split into each side's orders; an atom with exec tick E is issued by
its own endpoint at sim tick `E - ORDER_DELAY` (the fastest legal client, the
M2 driver's reading), queued locally through `Sim:queueCommand` with its
`issueTick`, and shipped as an A.11.2 atom. The two endpoints' sims start when
their handshake completes (T0 skew is real and modelled, per A.11.1), tick on
the shared harness clock, and end when both are terminal, the channel is
drained and nothing is outstanding. An endpoint whose sim believes the match is
over stops issuing - a hand cannot click on a finished match - so the ISSUED
set, which all three comparisons share, is the ground truth of that run.

### The gate, step by step (`tools/m4.sh`, ~30 s per interpreter)

| step | what it is | what it asserts |
|---|---|---|
| checkers | greps + comptest over `net/`, strict sim mode | 0 hits, 0 failures - the transport and shim are held to every determinism rule |
| codec | 3,087 checks: round-trip every row, the A.11.3 byte table, malformed fuzz | every size exact (C at n=8 is 70 bytes, the protocol's largest); decode NEVER raises (pcall over corpus + 2,000 seeded garbage strings); case-sensitivity (`s` rejected where `S` parses); the transport 255-byte hard error; the transport schedule reproducing from its seed |
| MILESTONE | 100 runs at 10% loss, 1..30-tick jitter, 10% reorder | hashes equal at EVERY epoch, ep1 = ep2 = reference; **every late command repaired by bounded rollback; zero escalations, zero mismatches**; detection live in every run |
| rollback | 40 runs at 25% reorder + 5% duplication; **a run with no late command is re-seeded** (fixed +7777 rule) because it proves nothing | every A.12 boundary case OCCURRED and was survived: duplicates delivered, resends after originals, acks lost (backstop fired), commands lost until resent (N answered) |
| deep | 12 runs, carded loadouts; ep2's sim corrupted OUTSIDE the shim from tick 2,600, RECURRING until detected; every second run also wipes ep2's held peer history, re-seeded until the wiped span is past N's reach | epoch-hash exchange detects; M and Q fire; the replay is answered; **both sides rebuild from tick 0 and the rebuilt sims carry BOTH handshake loadouts** (asserted field by field); detection inside 15 epochs; final state bit-identical to the reference - the corruption is gone |
| stress | 25 runs at 30% loss, 1..40 jitter, 20% reorder, 10% dup | the full A.12 ladder may escalate (N -> backstop -> hash adjudication -> Q rebuild) and did; **convergence to the reference is still absolute** |

### Measured results (both interpreters; every number below is bit-identical under Lua 5.5 and LuaJIT 2.1)

| step | runs | late commands -> repaired by rollback | beyond depth -> repaired by Q rebuild | mismatches detected | Q sent/answered | rebuilds | dup atoms | largest message | SUITE HASH |
|---|---|---|---|---|---|---|---|---|---|
| milestone | 100 | **6,659 -> 6,659** | 0 | 0 | 0/0 | 0 | 1,930 | 58 B | **1353990724 (`e4pxg`)** |
| rollback | 40 | **2,628 -> 2,628** | 0 | 0 | 0/0 | 0 | 1,127 | 46 B | **630668562 (`fhez6`)** |
| deep | 12 | 1,012 -> 1,012 | 0 | **8** | **20/19** | **19** | 950 | **70 B** | **1794064162 (`o50rm`)** |
| stress | 25 | 1,851 -> 1,809 | **42 -> 42** | 0 | 43/36 | 42 | 2,413 | 70 B | **1907532503 (`jp1hz`)** |

Totals across the four scenarios: **177 net matches, 23,481 atoms issued,
11,304 epochs compared three ways each, 12,150 late commands - 12,108
repaired by bounded rollback (max rewind 299 ticks) and the 42 beyond-depth
arrivals repaired by full-log rebuild, 19 forced-desync recoveries, 9,908
settled hash comparisons, 0 unexplained mismatches, 0 messages over 70
bytes** against the 200-byte
budget and 255-byte hard limit. 60,626 messages crossed the fake channel;
8,246 were dropped by it and 8,170 delivered out of order. The milestone
floors are enforced, not observed: the step fails if fewer than 2 late
commands occur per run on average, if too few runs reach the full 6,000
ticks (15 of 100 did), if no delivery was ever inverted, or if either
endpoint of any run never performed a settled hash comparison.

### Four findings worth the doc owner's time

1. **Rollback is the COMMON path at these settings, not the exception.** With
   `ORDER_DELAY` 20 and 1..30-tick jitter, roughly half of all delivered
   command-bearing messages arrive after their exec tick (6,659 late over 100
   milestone matches - ~66 rollbacks per match, every one repaired inside the
   snapshot window). The shim's rollback is not an error handler; it is the
   normal receive path, which is the strongest argument for having proved it
   at M4 rather than discovering it at M5.
2. **A one-off state corruption is HEALED BY ROUTINE ROLLBACK before the hash
   exchange can see it.** The first forced-desync design flipped ep2's bank
   once; the next late command restored a pre-corruption snapshot and
   re-simulated, erasing the corruption as a side effect, and the match ended
   clean with zero detections. That is an emergent robustness property of
   A.12's own machinery (a real transient bit-flip inside the rollback window
   self-repairs), and it forced the test to model what a real desync is - a
   code path that KEEPS disagreeing - as a recurring mutation. Detection then
   fires within a few epochs, every time.
3. **A.12's resend ladder needs repair traffic outside the C bucket, and
   A.11.4 already says so.** With N answers and backstop resends queued behind
   the order-coalescing bucket (capacity 4, refill 1 per 4 s), a ~1-in-5,000
   loss chain pushed a command past the 300-tick snapshot depth at 10% loss -
   escalation in a scenario that should stay bounded. A.11.4's own budget
   table lists `resends` and `repair` as their OWN rows beside `C commands`;
   letting them ride that budget (capped at 4 messages per flush) removed the
   tail completely: 9,287 within-depth late commands at milestone+rollback
   settings, zero beyond. At 30% loss the tail is real and the ladder's last
   rung catches it: 42 beyond-depth arrivals, 42 full-log rebuilds, zero
   divergence at the end.
4. **The `Q` rebuild genuinely needs both loadouts, and the gate would notice
   if it did not.** The deep scenario runs carded (one card of each family per
   side); the rebuilt sims' `sd.loadout` arrays are asserted against the
   handshake field by field, and the rebuild call is
   `Sim.new(rules, seed, loadout1, loadout2)` - the exact triple A.11.1's
   handshake carries. This is 0.1 item 4 made concrete: under v1's private
   state this path could not have existed, because the loadout needed to
   rebuild the opponent's half was never on this client.

**AND THE GATE HAS TEETH, ASSERTED BY MUTATION RATHER THAN CLAIMED**, in the
house style. Two surgical breaks of `net/`, each run and each reverted:

| mutation | result |
|---|---|
| rollback disabled (a late atom is silently dropped) | RED six independent ways on the first seed: terminal mismatch, divergence from the no-netcode reference, epoch-trace divergence at tick 2,640, the late-vs-rollbacks accounting, spurious hash mismatches, and forbidden escalations |
| `Snap` stops copying `bank` (a hashed field missed by the outside-the-sim copy) | the restore hash-guard ERRORS on the very first rollback: "restored sim hashes to X, captured Y -- a sim field this file does not copy" |

The second is the one worth having: it is the exact failure mode that makes an
outside-the-sim snapshot dangerous, and it cannot survive one rollback, let
alone a gate run.

### INTERPRETATIONS (M4) - where A.11/A.12 were silent and this implementation chose

Recorded here because `Rules.lua`'s block is for ruleset readings and none of
these touch the ruleset. Each is cheap to overturn.

1. **The `Q` replay ships the RESPONDER'S OWN command history**, as verbatim
   `C` batches (same seqs, same exec ticks), prefixed by a fresh `S` (its
   loadout - the both-loadouts dependency made explicit) and a fresh `H`
   (whose `lastSeq` is the completion watermark). A.12's "replays its entire
   command log" cannot mean both halves: `C` carries per-SENDER seqs and no
   side field, so the requester's own half is unshippable in the message
   table as ruled - and unnecessary, since the requester retains everything
   it ever issued (A.12's own retention rule).
2. **On a settled hash mismatch, BOTH sides request `Q` and BOTH rebuild.**
   A.12 has one peer ship the full log but names no way for either client to
   know which one is healthy, and there is none - so log-truth is the only
   arbiter, both rebuild from tick 0, and both land on the same state
   whichever was wrong. Costs one redundant rebuild, removes a leader
   election.
3. **"`currentTick - E <= 300`" is implemented structurally**: repairable iff
   a kept snapshot exists at or before E (the ring keeps `SNAPSHOT_KEEP`
   epoch snapshots, plus tick 0 while filling), which is 240..300 ticks of
   depth depending on phase. Beyond it "escalates" (A.12's word) to the `Q`
   path.
4. **`H`'s 1-char epoch field is the absolute epoch mod 36**, recovered from
   the prologue tick (`floor(tick/60)`) and checked; `M`'s disputed epoch is
   recovered as the nearest epoch at or below the sender's tick matching the
   residue. 100 epochs do not fit one base-36 char any other way.
5. **A `C` batch is a consecutive-seq run** (`<seq 2>` is the first atom's),
   so a resend of non-adjacent seqs costs one message per run; "piggybacked"
   is read as "carried on the next send window", not as a new message shape.
6. **A hash comparison is trusted only when the epoch is SETTLED**: I hold
   the peer's whole history up to the `lastSeq` its `H` claims, and nothing
   of mine the peer lacks (above its `ackThru`) can execute at or before the
   epoch tick. Anything else is light still in flight, not a desync. This
   rule produced zero false positives in 9,908 settled comparisons over
   lossy channels.
7. **Repair traffic (N answers, backstop resends) bypasses the C bucket**
   (finding 3 above; A.11.4 budgets it in its own rows); the `Q` replay is
   paced at 10 messages per 100 ticks - A.12's "pace them across two burst
   windows" read against its own 10-token burst.
8. **Decode validates structure, not legality**: framing, alphabet, kind
   letters (case-sensitive, derived from the hashed tables), targets the
   wire itself defines (lane 1-3 / slot 1-6 by case), counts >= 1. A count
   of 35 decodes; the sim clamps it at the exec tick, because A.4 puts
   legality in the sim, on both clients, never in a decoder that could
   disagree with its twin.
9. **The transport's `reorder` verdict is extra delay past the jitter
   window** (a guaranteed inversion against the following window), and the
   gate counts REALISED inversions and fails if none occurred - the knob is
   measured, not trusted. `dup` delivers twice; the duplicate copy is never
   itself dropped, so "duplicated" always means "the dedup path ran".
10. **T0 skew is modelled, not idealised**: each sim starts when its endpoint
    holds both loadouts (A.11.1), so the two clocks are offset by handshake
    latency; nothing anywhere corrects for it, because atoms and hashes live
    in shared sim-tick time - which is A.11.1's own claim, now exercised.
11. **`S` is offered on a 60-tick cadence until the peer is PROVEN built** by
    its first `H` or `C` (either side's `S` can be lost; a reply-to-S rule
    can ping-pong against the `Q` answer's fresh `S`, so the cadence keys
    off evidence instead). A.11 does not specify handshake loss at all -
    M5's OPEN/JOIN layer will own the real version of this.
12. **Received atoms carry no `issueTick`** (the wire has no such field), so
    the ORDER_DELAY window is enforced at the issuer and the receiving sim
    takes the atom on its exec tick alone - the sim's documented contract.
    Stated plainly (review finding 8): this makes the window UNENFORCEABLE
    against a hostile peer, whose modified client could schedule atoms with
    less than the delay. Accepted for the same reason full state sharing
    was: this is a social game and a cheating client is out of scope.

**A layering note from the adversarial review (finding 5):** end-to-end duplicate
idempotence is enforced TWICE - the shim dedups, and the sim's own `(side,seq)`
seen-set refuses anything that slips through. The gate proves the property, not
the layer: removing the shim's dedup alone stays green because the sim absorbs
it. That is defence in depth working as designed, recorded here so nobody
mistakes the shim's counter for load-bearing.

### What a green M4 does NOT prove

- **No real channel.** The transport is a seeded model. Real refusal codes,
  the Comm-layer bucket, lockdown boundaries and true loss rates are M5's
  problem, informed by the Probe.
- **No halt/resume.** `X`/`K`/`G`/`V` round-trip through the codec and are
  counted when received; nothing acts on them until M6.
- **One process, one host.** Two endpoints share one interpreter. The
  cross-interpreter hash agreement above is the strongest split available
  before M5; the cross-machine clause still needs a second machine, exactly
  as M1's does.
- **The sim itself is not re-proved here.** `tools/ci.sh` owns that; this
  gate proves the shim DELIVERS that sim over a hostile channel unchanged.

---

## M5 part 1 - the engine mounted in the DEV addon, and the real-channel bridge (2026-08-21)

Part E's M5 is "first playable, over the wire: register `IB` on `Comm.lua`.
`OPEN`/`JOIN`/`S`/`C`/`H` only. Party scope. Two real characters. Content per
D.1." **Part 1 is the PLUMBING**: the engine mounted inside
`dev/PengyouGamesDev/` (the DEV addon that installs alongside the live one so
experiments can never touch real raiders), the comm bridge onto the addon's
real channel, matchmaking through the shipped session system, the tick driver,
and an in-game determinism selftest. **The board UI is part 2**; the match
surface shipped here is a marked stub (session status, tick, Levy, keep HP
both sides, one deploy and one build button - enough to drive a real match
end-to-end between two clients). The M5 milestone (a complete 600-second match
between two accounts, hashes matching at every heartbeat, traffic under 32
messages/min) is **not claimed** until part 2 has run it with two real
characters.

**Nothing in the engine's behaviour changed.** `rulesHash` is still
`767294897` (`cotsj5`), all four goldens are exactly M3's, and `tools/ci.sh
1000` and `tools/m4.sh` are GREEN on the tree carrying the one edit below.

**THE ONE HEADLESS EDIT: registration tails.** The addon files were already
written to IMPORT through the `IB_SIM_MODULES` global
(`IB_SIM_MODULES and IB_SIM_MODULES.Hash or require("sim.Hash")`), and that
pattern covers every cross-file reference in the eight mounted files (verified:
Rules->Hash; Sim->Hash,Rand,Mods; Wire->Rules,Hash; Snap->Hash;
Net->Rules,Sim,Hash,Wire,Snap; Hash, Rand and Mods import nothing). What the
tree did NOT have was the EXPORT half: WoW discards a chunk's return value, so
`return M` reaches nobody inside the addon and a loader file alone has nothing
to populate the table WITH. The arcade hit exactly this and its answer is the
established idiom (`devarcade/PengyouArcade/sim/Fixed.lua`): each engine file
now ends with a REGISTRATION TAIL -
`local IB_REG = rawget(_G, "IB_SIM_MODULES"); if IB_REG then IB_REG.Hash = M end`
- which is a no-op headless (the global does not exist), adds no state, and
runs once at load. The full argument sits in `sim/Hash.lua`'s tail; the other
seven point at it. `fog/Fog.lua` and `net/Transport.lua` do NOT carry tails:
Fog mounts at M7 (give it one then), Transport never ships (the bridge in
`Games/IdleBattle.lua` is its real-channel replacement).

**What is mounted, and the sync rule.** `dev/PengyouGamesDev/IdleBattle/`
holds byte-identical copies of `sim/Rules.lua sim/Rand.lua sim/Hash.lua
sim/Sim.lua sim/Mods.lua net/Wire.lua net/Net.lua net/Snap.lua`, a `Loader.lua`
that creates `IB_SIM_MODULES` (the addon's one deliberate, documented new
global), and a generated `HandLog.lua`. `tools/syncaddon.sh` is the only
bridge; `--check` byte-compares every copy, regenerates and compares the
derived file, and re-executes the addon's actual `.toc` engine order headless
with `require()` disabled - so a drifted copy, a stale derived file, a missing
tail or a broken load order is a red build, not a login surprise. **The
headless tree is edited and the addon is synced, never the reverse** (stated
in `dev/PengyouGamesDev/IdleBattle/README.md` too, which marks the folder
generated).

**The in-game determinism proof: `/pgd ib selftest`.** Runs the committed
hand-written log - `harness/logs/hand.iblog`, embedded by the sync script as
`HandLog.lua` together with the three committed goldens EXTRACTED from
`harness/selftest.lua` (written down once, never hand-copied twice) - inside
the WoW client, asserts the tick-250 landmarks section 3 asserts by hand (both
spears halted at 970 on 4 HP), and prints rulesHash + terminal stateHash +
logDigest against `767294897 / 1939244196 / 1455081792`. One match, 260 ticks,
no fuzz, runnable solo in well under a second: it turns "we believe WoW Lua
matches LuaJIT" into a one-command in-game check, and a RED there means THIS
CLIENT would desync a real match.

**The comm bridge (`Games/IdleBattle.lua`), family by family.** `net/Wire.lua`
encodes a complete envelope (`4|IB|mtype|wireToken|payload`); the addon
channel has its own envelope and token discipline, so the bridge decomposes
outbound strings and re-frames inbound payloads, and the engine's surface is
consumed exactly as `harness/m4run.lua` consumes it (`Net.new{send=...}`,
`ep:onWire(msg, now)`, `ep:step(now)`, `ep:issue(...)`):

| A.11 family | addon send path | note |
|---|---|---|
| `OPEN` | party broadcast, addon row `OPEN\|token\|joinSecs\|matchTicks\|P` | the shipped games' matchmaking shape, session token per CONCURRENCY 3.2 |
| `JOIN` | whisper to host, addon row | plus addon rows `BEGIN` / `CANCEL` / `NO reason` for pairing, teardown and the two A.11.1 refusals - pre-sim lifecycle is addon-layer, exactly as Wire.lua's header planned |
| `S` `C` `H` `N` `M` | **party-scope broadcast**, payload as one field | one route, server-vouched distribution, bystanders drop at the registry in one lookup. Deviation from A.11.1's "S whispered" recorded below |
| `Q` (request) | **whisper to the peer** | point-to-point like the shipped resync's `SYNCQ`; it concerns exactly one client |
| `Q` (answer stream) | rides the broadcast path | it is made of ordinary fresh-`S`/`H`/verbatim-`C` rows; the bridge routes by mtype and holds no per-message context, and in a 1v1 every in-match row has exactly one consumer either way |
| `V` | broadcast, Wire-encoded | the one wire row the ADDON acts on in M5 (Net defers X/K/G/V to M6): every mid-match interruption VOIDS |
| `X` `K` `G` | not sent, ignored on receipt | M6 |

The wire token (`Wire.token(seed)`, both ends derive it from the handshake
seed) never travels: the on-wire identity is the registry's server-vouched
`(host, sessionToken)` pair, which is strictly stronger, and the bridge
re-frames inbound payloads with the match's own wire token so `Net`'s check
can never false-positive. Every payload is pipe-free by Wire's own alphabet;
the largest on-wire message is a C batch of 8 at ~75 bytes against the
200-byte discipline.

**The real-budget resolution (M4 finding 3's "4 per flush", resolved against
the ACTUAL bucket in `Comm.lua`).** Net's own C bucket (capacity 4, refill 1
per 4 s) IS A.11.4's module bucket and matches the 15/min worst row. The
repair path's 4-per-flush cap, which against the fake channel could burst, is
bounded on the real channel by two facts the shim lacked: the addon's shared
bucket (capacity 10, refill 1/s) QUEUES overflow instead of refusing it, so a
repair burst drains at 1/s without tripping the server throttle; and transit
loss does not exist on the addon channel - messages die only at SEND time,
where throttle entries are requeued by Comm itself and lockdown/audience drops
VOID the match - so repair runs dry in every healthy match. Steady state is H
10/min + C <= 15/min ~ 0.42/s per side, leaving over half the refill for the
other games. The one transient exception: a Q recovery (~20 messages paced by
Net at 10 per 10 s) saturates the refill for ~20 s and other modules' traffic
queues a few seconds behind it - accepted, rare, bounded, and shared-bucket
capacity work is explicitly out of module scope (CONCURRENCY 9.9). **No second
bridge-side bucket was added**; adding one would delay repair for fairness the
queue already provides losslessly.

**Matchmaking rides the shipped session system.** Lite records for overheard
OPENs (caps, TTLs, recent-token poisoning, supersession, the 4.2 decision
table), invitation popup / launcher Open-games row per the busy rules, the
single round-based seat claimed at accept and at hostOpen, teardown through
`endSession` on every path. The handshake is A.11.1 through the engine's own
codec: host pairs with the FIRST `JOIN`, both sides exchange `S` (IBPROTO,
seed, rulesHash, matchTicks, loadout - EMPTY per D.1, but the field ships),
each side validates before feeding its endpoint and REFUSES politely with two
distinct strings (proto vs "your opponent is on a different balance patch",
G.4's wording), and each sets T0 locally the moment it holds both loadouts
(inside `Net.buildSim`) - the skew is one one-way latency and nothing corrects
it, per A.11.1. The driver is one module-global OnUpdate frame advancing
`ep:step` on the 100 ms grid from the local anchor; it is never registered
with the safety layer, because raid-safety hides UI, not state.

**Void on lockdown (M5 has NO halt/resume).** Triggers, all converging on a
clean two-sided void with no ledger effect: own encounter start / addon
restriction (PG.Safety), `PG.Comm.Locked()` observed by the driver, any queued
IB message permanently dropped (lockdown, vanished audience, failed send -
token-scoped per CONCURRENCY 5.5), the peer's `V`, or 35 s of peer silence
(H arrives every 6 s). The `V` send on our own trigger is best-effort - under
an active lockdown it drops, and the peer voids on its own trigger or the
silence timeout. M6 mounts X/K/G on the same bridge and replaces exactly these
triggers with the halt path; the comments name the spots.

**M5 INTERPRETATIONS - where this part had to choose, each cheap to
overturn.**

1. **The export half of the loading pattern did not exist** (the files
   anticipated only the import half), and a loader alone cannot supply it
   because WoW discards chunk return values. Chosen: the arcade's registration
   tails, in the headless originals, no-op headless. The alternative - a
   temporary global `require` shim during the load window - was rejected as a
   second global with other-addon blast radius.
2. **`S` rides the party broadcast, not a whisper** (A.11.1 says "whispered").
   At party scope under Ruling 1 the loadout is on every client anyway, one
   route keeps the bridge context-free, and the broadcast distribution is
   server-vouched where a whisper proves nothing. Revisit at M9 when wide
   scopes make S's audience real.
3. **An IB host must be SEATED** - hostOpen refuses, with the reason, while
   another module holds the seat. This deviates from CONCURRENCY I4/I5's
   letter (hosting is never blocked; referee hosting is the fallback) because
   a 1v1 has no referee role: the host IS a combatant. The refusal names the
   seat holder and the alternative ("finish that first").
4. **The addon-layer rows are OPEN/JOIN/BEGIN/CANCEL/NO; V is Wire-framed.**
   Pre-sim lifecycle has no tick/ackThru to carry, so it uses the shipped
   games' row shapes; the in-match terminal row uses the codec so M6 inherits
   it. `NO reason` (proto|rules|full) is the A.11.1 refusal made visible to
   the host, who returns to the join window rather than cancelling - another
   party member on the right build may still join.
5. **The driver is one module-global OnUpdate frame** (plus the module ticker
   for sweeps/deadlines at 0.5 s). CONCURRENCY I9 counts frames per SESSION;
   this frame is per MODULE, created once, hidden when idle - the spirit
   (bounded resources) holds, and the 100 ms grid is what the task's tick
   driver requires.
6. **A match that ends cleanly stops stepping at once** - trailing acks for
   the peer's last commands may go unacked, their backstop resends stop after
   4 heartbeats by A.12's own rule, and both sims reached tick 6,000
   independently. Post-over ack tidiness is cosmetic and part 2 can add a
   short linger if the diagnostic counters prove annoying.
7. **`matchTicks` ships as `Rules.C.MATCH_TICKS` (6000) always.** The field
   is validated and carried end-to-end, but a shorter clock would end without
   `sim.over` (the sim's own clock finish fires at C.MATCH_TICKS), so
   presets stay M8+ material.

---

## Where this sits in the build order (Part E)

- **P** - the Probe. Half a day in a real raid, off the critical path, calibrates every rate
  constant. Not in this directory.
- **M1** - *this directory*. The determinism harness. **The top risk**, because Ruling 1
  doubled the determinism surface: the full economy, 40 modifiers and the tiebreak
  accumulators now all run on both machines, and any line of it can desync.
- **M2** - *this directory too.* The sim playing itself. Scripted policies both sides, 1,000
  matches, reproducing C.6: median 380-430 s, >=75% inside the 5-10 minute band, >=80%
  decided by a razed keep, family spread under 10pp. Cross-checked against the Python model;
  a disagreement between the two is a finding, not a nuisance. **Status: RED. Under
  `../docs/IDLE_BATTLE_FOG.md` - the owner's binding fog model INCLUDING section 3a's
  contact reveal, and the regime the gate runs on - six of seven clauses pass at 1,632
  matches and seed base 500000, and FAMILY SPREAD fails; at the other three sampled bases
  the razed-keep clause fails too and at one of them so does the median.** The instrument
  has now been corrected three times: so that no line reacts to a position the fog never
  renders (Finding 7), so that the lines whose stated intent needs sight BUY it (Finding 9),
  and so that the fog renders what a unit is fighting (Finding 10). **The third correction
  is the only one that rescued a clause** - the 5-10 minute band went from failing at all
  four seed bases to passing at all four, because a defender could not previously see the
  army grinding it 60 units past the midline - **and it is the strongest evidence in this
  README for the general point, which is that a clause moving on a fix to what the policies
  can PERCEIVE was never a statement about the ruleset.** What is left is a family-spread
  clause that moves 2pp when one line of seventeen is added, and a razed-keep clause sitting
  within 2pp of its threshold in both directions depending on the seed. Four rulings are
  still needed before M3 starts: which information regime M2 is judged under (open item 3),
  whether the family-spread clause survives at all (open item 4), whether sight bought one
  section at a time by bodies that die is the intended mechanic (open item 17, which now has
  a measurement: a line spending a quarter of its economy on tripwires cannot be told apart
  from the same line spending it on bodies), and the three edges of the contact ruling
  (open item 19). M3 adds forty modifiers on top and every one of them will be judged
  against the same statistics.
- **M3** - all 40 modifiers with the S1-S10 stacking machinery, still headless. **The second
  risk.** M1's bit-identical test must still pass for each card alone and for 200 random
  5-card loadouts per side. The hook points at the bottom of `Sim.lua` are where they land.
  **Status: DONE and GREEN, in two parts.** Part 1 (the sim side): the hashed card table,
  loadouts, stacking, all seventeen `[Rule]` runtimes including the verbs, and the wheel;
  the M1 gate at 1,000 logs (half carded) under both interpreters on the regenerated
  goldens. Part 2 (the perception side and the gate): Divination, Omen, Veil and the
  Shrine pulse live in `fog/Fog.lua` and the policy view, `tools/fogtest.lua` at 667
  checks including a mutation suite, and **`tools/m3.sh` runs Part E's milestone verbatim
  - each card alone in two pairings, 200 random dual loadouts, the clamp-saturation
  report - GREEN 3/3 under both Lua 5.5 and LuaJIT with bit-identical suite hashes**
  (cards `116896602`, loadouts `448422185`; both M3 sections above), and the
  adversarial review's four required fixes are landed (the M3 fix pass section). **The
  milestone closes with exactly ONE accepted deviation, named rather than implied:
  open item 26 - Watchfires' Q9b reveal half is unshipped because the binding fog doc
  omits the row; its range half is live and pinned.** What M3 does NOT
  include, by open item 24: the post-M3 BALANCE re-measure, which needs the doc owner to
  say which roster and regime judge it.
- **M4** - two sims in one client through a fake lossy transport; rollback; `Q` full-log
  replay from tick 0. **Status: DONE and GREEN** (`tools/m4.sh`, 8/8 steps, both
  interpreters, the four per-step suite hashes bit-identical - the M4 section above).
  The A.11 codec, the seeded lossy transport and the A.12 shim live under `net/`,
  held to the sim's own determinism rules; `sim/` is untouched and every gate
  before this one is green on unchanged goldens. 177 net matches: every epoch
  hash equal between both endpoints AND a no-netcode reference, 12,108 late
  commands repaired by bounded rollback, forced deep desyncs detected by the
  epoch-hash exchange and repaired by the `Q` rebuild from tick 0 with both
  loadouts (asserted). What it deliberately does not prove: no real channel, no
  halt/resume (X/K/G/V decode but nothing acts on them), one process. Twelve
  A.11/A.12 readings are recorded in the M4 INTERPRETATIONS block.
- **M5** - first playable over the wire. `OPEN`/`JOIN`/`S`/`C`/`H`, party scope.
  **Status: PART 1 DONE (plumbing; the section above).** The engine is mounted in
  the DEV addon (`dev/PengyouGamesDev/IdleBattle/`, byte-identical, drift-gated
  by `tools/syncaddon.sh --check`), the `IB` module rides the addon's Comm layer
  and session system, the OnUpdate driver ticks the A.12 endpoint on the 100 ms
  grid, `/pgd ib selftest` proves the committed goldens inside the WoW client,
  and every mid-match interruption VOIDS (halt/resume is M6). Part 2 is the real
  board UI; **the M5 milestone is claimed only when part 2 has run the complete
  600-second two-account match against it.**
- **M6** - halt and resume, symmetric and asymmetric.
- **M7** - fog as a render filter, and the four greps again on a full build.
- **M8** - loadouts, `rulesHash` refusal, all 40 cards live, offline replay of a persisted
  match descriptor.
- **M9** - matchmaking, public scope, shipping.

**Do not proceed past a red milestone.**

---

## Open items for the decisions-doc owner

Twenty-six things need a ruling or an acknowledgement in `dev/docs/IDLE_BATTLE_DECISIONS.md`
or in `dev/docs/IDLE_BATTLE_FOG.md`. Items 1, 8, 13 and 16 are closed. Item 2 came out of
M1 and does not block it - the implementation has chosen and recorded a defensible answer,
in `Rules.lua`'s INTERPRETATIONS block. **Items 3 to 12 came out of M2. Item 3 is the one
that blocks the milestone, and it asks Part E to say something it never said rather than to
change a number. Items 13 to 17 came out of implementing `IDLE_BATTLE_FOG.md` and three of
them are about that document rather than about the decisions doc. Items 20 to 24 came out
of M3 part 1: every one is implemented under a recorded interpretation
(`Rules.lua` INTERPRETATIONS 13-28) and none of them blocks, but four are places where
two normative sentences disagree and the doc should pick. Items 25 to 27 came out of M3
part 2 - the perception effects - and none blocks either: each is implemented under a
recorded reading, pinned by a fogtest section, and cheap to overturn; item 24 is now the
only thing between M3 and a balance measurement.** They are stated here
rather than edited into either document because the documents are the authority and this
directory is not.

> **Items 3, 4, 5 and 6 have all been rewritten at least once, always downward.** The
> pattern is the same every time: a claim was read off family win rates from a sweep with
> no error bar, or off one seed base, or under an information regime nobody had named.
> Family win rates at this roster size move 4.8pp on seeds alone, 27.6pp on one line's
> presence and 8.7pp on the information regime, so a claim resting on them needs all three
> controls before it is worth a doc owner's time. The earlier versions are named where they
> were wrong rather than quietly replaced. **Nothing in `sim/Rules.lua` was changed at any
> point in M2; `rulesHash` is still 297242539.**

1. **CLOSED. C.5's "3-Horse opening affordable t = 24.5 s" was stale v1 arithmetic, and the
   correction has landed.** C.5 now carries a dated correction block giving the chain as 1
   Horse at **0.0 s**, 2 at **10.5 s**, 3 at **21.0 s**, and records that the rest of Part C
   was swept for the same 20-Levy-stipend error and is clean. `tools/smoke.lua` pins all
   three ticks plus the Trap Pit (70) and Levy Post (315) landmarks, so the doc and the sim
   cannot drift apart again without failing the build. **No ruling is outstanding on this
   item; it is kept here only so a reader of the earlier version does not go looking.**
   Separately, and not something this directory can check: that correction was made to
   `dev/docs/IDLE_BATTLE_DECISIONS.md` during the M2 build window, which the file boundary
   for this work forbids. Somebody with repository access should run
   `git log -1 -- dev/docs/IDLE_BATTLE_DECISIONS.md` to establish who made it and confirm
   the boundary held. Nothing under `dev/idlebattle/` wrote it.

2. **Building wire letters - RULED AND LANDED (2026-08-13).** The owner delegated the
   call; the ruling (recorded in `IDLE_BATTLE_DECISIONS.md` A.11.2) is CASE IS THE
   NAMESPACE: uppercase kinds target a lane (units `S`/`H`/`B`, verbs `I` Investment,
   `E` Scorched Earth, `L` Ley Line), lowercase kinds target a slot (the catalogue,
   contiguous `a`-`l`). Implemented in `Rules.lua` and `Sim.lua` after the M2 sweep
   finished; `rulesHash` moved to `333968378` and the goldens were regenerated together.
   The decoder is case-sensitive; never `lower()` an incoming kind. M5 can freeze `proto`.

3. **THE BLOCKING ONE, AND IT IS NOT THE ONE THIS README NAMED LAST TIME. Which
   INFORMATION REGIME is M2 measured under?** Part E's milestone gives four numbers and
   never says what the policies can see, and the answer moves two of those numbers by more
   than the margin they were passing by. Under A.3's default-vision table the band clause
   falls 76.8% -> 74.7% and razed-keep 80.9% -> 75.6%; under Ruling 1's unfiltered shared
   state - which is what M2's first pass silently measured, because Ruling 1 puts the whole
   enemy state on both clients - they pass. **Both are defensible readings of the document
   and the document does not choose.** The recommendation is that **Part E should say
   explicitly that M2 is judged under A.3 default vision**, because the milestone's four
   numbers are a description of matches people play and A.3 is what a player is shown; the
   full-information column is worth keeping as a published upper bound. Finding 1;
   reproduce with `lua sweep/verdict.lua 6`, which prints both.

   **UPDATE, AND IT SHARPENS THE ITEM RATHER THAN SETTLING IT.** The roster has since been
   recalibrated so that no line reacts to anything A.3 fails to render (Finding 7), which
   removes the obvious objection to gating on the fogged column - that the fogged numbers
   were produced by lines written for a different board. On the recalibrated roster the
   fogged column now fails `median keep spread` at **all four** sampled seed bases instead
   of failing a different trio at each, so the ruling is now being asked about a stable
   measurement rather than a shifting one. Two further reasons to name A.3 explicitly:
   `Rush-horse`, the one line whose C.6 name fully specifies its strategy, now agrees with
   C.6 to **0.1pp under fog and 2.3pp under full information**; and `full` has been fixed to
   be an actual superset of `a3` (it was missing the muster bar), so the two columns now
   differ only in what the board shows and are for the first time properly comparable.

   **SECOND UPDATE, AND IT MAKES THE ITEM MORE URGENT RATHER THAN LESS.** The owner's
   `IDLE_BATTLE_FOG.md` has since replaced the fog model both columns above were measured
   under, and re-measuring moved three of the four clauses (Finding 8). **The regime is now
   the largest single term in the milestone and it is still unstated in Part E**: under the
   fog model the sim PASSES median and razed-keep and FAILS the 5-10 minute band; under full
   information it passes all three and fails only family spread. Same ruleset, same roster,
   same seeds, different answer to "is M2 green". A milestone whose verdict depends on an
   unwritten parameter is not a milestone. The recommendation is unchanged and now applies
   to a named document: **Part E should say explicitly that M2 is judged under
   `IDLE_BATTLE_FOG.md`**, with the full-information column kept as a published upper bound.

   **THIRD UPDATE, AND IT IS THE SAME ITEM WITH A SHARPER NUMBER.** The roster has since
   been given the fog doc's own answer to the fog -- four lines that BUY sight (Finding 9) --
   and the regime is still the largest term in the milestone: **fog 406 s / 72.5% / 80.0% /
   11.6pp, full 420 s / 76.4% / 82.2% / 14.9pp.** Same ruleset, same roster, same seeds, and
   the fogged column fails two clauses while the unfogged one fails a different single
   clause. The recommendation is unchanged and now has no remaining objection to it: the
   fogged roster can no longer be dismissed either as reacting to things the fog does not
   render (Finding 7) or as ignoring the mechanic the fog exists to sell (Finding 9).

   **AND THE CLAUSE TO LOOK AT IS NOW THE BAND, NOT DECISIVENESS.** Razed keeps were the
   headline disagreement with C.6 (75.9% against a target of 80% and C.6's own 85%); under
   the fog model they are **82.5%** and the clause passes. What fails instead is *"at least
   75% of matches inside 5-10 minutes"*, at **71.0% and 72.2%** across two seed bases. The
   two are the same mechanism seen twice: with no early warning, defences answer late,
   attacks land, and matches end faster -- decisively, and some of them under five minutes.
   Whether that is the game the design wants is a question for the owner and not for this
   directory.

4. **Part E's "family spread under 10pp" clause has no power at any realistic roster and
   should be replaced.** A family win rate is the mean of four hand-written lines. Shuffle
   the sixteen measured line win rates into four *arbitrary* groups and the spread has a
   median of **22.8pp** and only a **6.5%** chance of landing under 10pp - so a roster with
   this dispersion fails the clause about 93% of the time **with the families assigned at
   random**. The measured 13.8pp sits at the 16th percentile of that null
   (`P(null >= measured) = 84.1%`): there is no detectable family effect to fix. Seeds move
   it 3.4pp; deleting one line of sixteen moves it across a 30pp range - and **one of those
   sixteen deletions, `Greed-pure`, takes the clause from 13.8pp to 1.3pp and turns the
   milestone green by itself.**
   **AND THE RECALIBRATION IS THE STRONGEST EVIDENCE THIS ITEM HAS.** Finding 7 changed
   only what the sixteen lines are allowed to perceive - no rule, no price, no threshold in
   `Rules.lua` - and the clause moved 22.9pp -> 13.8pp, which is more than the whole
   distance to the 10pp target. A clause a change of instrument moves by 9pp is not
   measuring the ruleset. It also moved the proposed REPLACEMENT clause's deciding cell by
   9pp in the other direction (defence's best line 74.4% -> 65.0%), which is why the
   replacement now needs a tolerance attached to it.
   **Two corrections to the earlier version of this item, both of which weaken it and are
   stated anyway.** (a) It said the clause "cannot be passed on purpose"; that does not
   follow from the evidence offered. Re-running the same null on the same rates shrunk
   toward 50% gives `P(null < 10pp)` = 21.0% at C.6's own reported leverage, 38.2% at half
   this dispersion and 96.9% at a quarter of it, so **the clause is passable by a roster
   whose lines sit within about 20pp of each other** and what the null actually shows is
   that the statistic has no power *at this roster's dispersion*. (b) It said **"do not
   reprice anything to close the existing clause - the statistic cannot see the change"**;
   that is withdrawn as unsupported. A repricing does move the statistic. The recommendation
   itself stands, **with a caveat that is new and is not hidden: replace the clause with
   "every family has a line above 70% and no line above 90%"**, which C.6's own prose
   derives and which survives a change of roster - but **this sim now MISSES it for defence
   under BOTH regimes**, by 5.0pp under fog (`Counterpunch` 65.0%) and 0.6pp under full
   information (`Wall` 69.4%). One bug fix in a different line, and then one recalibration
   of what the lines can see, moved that number across the threshold and then 9pp past it.
   Adopt it with a stated tolerance or with more than four lines per family. Finding 2;
   reproduce with `lua sweep/famstat.lua`. **The experiment that would settle the whole item
   and has NOT been run is writing four comparable lines per family and re-measuring** - see
   open item 10, whose stated blocker has now been removed.

5. **C.4's catalogue has a real problem, and it is scope rather than price level.** Buying a
   building costs a roaming control line up to 18.5pp of win rate (192 matches per variant,
   the largest past 3.7 sigma), so the tempo cost is confirmed. The *proportionality* to
   price is weaker than the claim needs: at **110 Levy exactly**, Arrow Tower is +4.4pp and
   Redoubt -13.8pp against a defensive control, an 18.2pp gap at 4.0 sigma between two
   buildings that lose identical tempo; and the cost-versus-win-rate correlation is p=1.2%
   against one control and p=6.1% against a second. **The buildings that fail are the
   lane-scoped ones** - Stables, Shrine, Smithy, Redoubt, Fletcher - and they recover by
   4-13pp the moment the control has a reason to stay in one lane, with Trap Pit and Arrow
   Tower going outright positive. **The ruling needed is whether a lane-scoped effect is
   priced as if the buyer will fight in that lane**, not whether the band is 8-15 ticks of
   income or 4-8. Finding 3; `lua sweep/probe.lua 6 Balanced` and
   `lua sweep/probe.lua 6 Turtle-eco`. **Both probes were re-run under A.3 fog after the
   `Counterpunch` fix; the earlier numbers in this item came from a different regime and a
   misconfigured roster and should not be quoted.**

6. **Q1's "each lever moves one thing" needs a caveat: Spoils is also a length dial.**
   Moving `SPOILS_PCT` 0 -> 75 moves the median 484 s -> 398 s and the razed-keep share
   66.7% -> 80.4%. Those are whole-sample aggregates over 1,440 matches and are sound. The
   *aggression* half of the earlier claim (+12.5pp against Q1's ~+5pp) is withdrawn: it was
   read off family win rates, which item 4 shows cannot resolve an effect that size at this
   roster. Q1's tuning rule needs the length caveat; the magnitude disagreement should be
   re-measured with `sweep/probe.lua`'s method - one control, one variable, an error bar on
   every row - before it is treated as a disagreement with Python at all.

7. **Q10's tier frequencies are wrong: T2, T3 and T4 never fire.** Of the 350 matches that
   reached the clock under A.3 fog, tier 1 resolved 97.4% and the rest were draws at 0-0.
   Q10 states T1 54 / T2 25 / T3 17 / draw 4 and concludes "nothing in Q10 is dead code".
   Tier 2 needs an EXACT tie in cumulative keep damage against a 48,000 HP keep, which does
   not happen. The ladder's ordering still does its job - no defensive victory was observed
   under either information regime - but three of its five rungs will ship exercised only by
   a unit test unless tier 1 is coarsened; bucketing `keepDamageDealt` to whole percent of
   KEEP_HP would do it. Finding 4. **This is the one M2 finding that is not a sample-size
   question**: 0 occurrences in 350 clock matches of an event requiring an exact integer tie
   is structural.

8. **CLOSED BY `IDLE_BATTLE_FOG.md`. A.3's muster bar has no thresholds, and M2 cannot be
   judged under fog until it does.** The doc did not pick cut points; it **deleted the bar**
   (section 8.1: *"This replaces the muster bar entirely... the derived 2,800/5,600 HP
   thresholds are void"*), which is the better answer to the sharper version of this item
   below - a widget whose top third never lights should not be drawn, and now it is not.
   The machinery is gone from `policy/` and the fogged M2 numbers this item was about are
   void. **No ruling is outstanding; it is kept so a reader of the earlier version does not
   go looking.** The original text follows.

   ~~A.3 specifies "one per-lane muster bar, 3 buckets (clear / pressure / heavy), driven by
   total marching HP in that lane" and gives no cut points and no statement of what a
   defender is supposed to read off it. That is fine for a renderer and fatal for a
   measurement: it is now the only number in M2 that is neither in Part C nor forced by it,
   and moving it inside its defensible range moves the fogged family spread by 7.5pp, the
   razed-keep share by 4.0pp and the band by 2.3pp. `policy/Policy.lua` derives a default
   rather than choosing one - three equal shares of the 8,400 HP a 200-Levy lane holds at
   C.3's best HP-per-Levy body, read back at each bucket's lower edge - and the sensitivity
   table is in Finding 1. **The ruling needed is the two HP cut points**, and it is cheap:
   it is a rendering decision that has to be made before M7 anyway.
   **AND THERE IS NOW A SECOND, SHARPER REASON TO MAKE IT.** `lua sweep/fogaudit.lua`
   measures how often each bucket is actually lit across 480 matches: **`pressure` in 2-6%
   of lane-polls and `heavy` in 0.0-0.1%.** At the derived cut points the top third of a
   three-state widget never renders, so A.3 as implemented is a two-state bar. That is a
   defect in the WIDGET before it is a question about balance - a player would never see the
   heavy state - and it is the reason the recalibrated roster maps every pre-contact
   intention onto `pressure` and no line declares `alarm = HEAVY`. **Whatever cut points the
   ruling picks, they should be checked against this measurement**: a bucket that never
   lights is a bucket that should not be drawn. Finding 7.~~

9. **C.2's bank-cap clause is UNTESTED, and the tooling to test it does not exist.** C.2
   states that at 2.857 Levy/s "a hoard cannot be converted quickly enough to buy tempo, so
   the cap stops being a strategic dial and becomes what it should be - a cap on waste",
   with a measured 1.8pp swing across a 160/200/300/450 sweep. **M2 neither confirms nor
   refutes any of that.** Two of the sixteen lines carried notes claiming they tested it and
   neither does: over 1,440 matches `Granary-bank` peaked at 220 banked against a 350 cap
   and `Counterpunch` at 20 against 200, and sweep-wide waste under full information was 38
   Levy across 2,880 match-sides. The notes are corrected. **What is needed is a controlled
   `BANK_CAP` sweep on `sweep/probe.lua`'s one-control-one-variable method** - re-run the
   round robin at 160 / 200 / 300 / 450 and report family win rate with a standard error
   plus total waste per cap. Nothing in this tree sweeps `BANK_CAP` today, and building it
   is M2 work that was not done rather than a question for the doc owner - it is listed here
   so the gap is on the record beside the clause it leaves open.

10. **The roster experiment that would settle item 4 has NOT been run, and the reason it was
    deferred no longer applies.** `measure.roundRobin` already takes `opts.lines`, so writing
    four *comparable* lines per family - same four archetypes, within-family leverage pulled
    from this roster's 24.5-85.0pp down into C.6's 26.9-55.0pp band - and re-measuring is
    inside M2's scope and needs no new code beyond the roster and a second `FAMILY_MEMBERS`
    mapping. The previous version of this item deferred it because the roster first had to
    be recalibrated for A.3, and tuning a tighter roster against the full-information board
    would be calibrating the instrument to a board no player sees. **That recalibration is
    done (Finding 7): every line now declares only thresholds A.3 renders, `line()` refuses
    a roster that does otherwise, and `sweep/fogaudit.lua` reports 0.0% erased detections
    for all sixteen under both regimes.** So this experiment is now unblocked and it is the
    single highest-value piece of M2 work left.
    **What it must NOT be, stated here because the temptation is obvious**: a search over
    rosters for one that passes. The recalibration above moved three milestone clauses and
    every one of its changes was made because the code was reading something A.3 does not
    render - the effects on the clauses were measured afterwards and one of them (median,
    428 -> 432 s) was a loss that has been left standing. A tighter roster must be justified
    the same way: by a stated property of the lines, decided before the sweep runs.
    **Deleting lines is not a substitute either** - it biases family means, and the
    jackknife in Finding 2 now shows one deletion (`Greed-pure`) that would turn the clause
    green on its own, which is precisely why deletion cannot be allowed to be the method.

11. **Concurrent units disagree with C.6 by 41% at the median, and M7's render budget is
    sized against the wrong number.** Peak concurrent units per side over 2,880 match-sides
    is median 24 / p90 41 / **max 60** against C.6's 17 / 47 / 57, identically under both
    information regimes. The max is the structural ceiling (three lanes x 200 Levy of 10-Levy
    Spears), so it is not roster luck. It is roster-*sensitive* at the median, and the two
    models have different rosters, so this is not a claim that Part C's arithmetic is wrong.
    **It is a claim that M7 should budget for 60 per side and a median of 25, and C.6
    currently says 57 and 17.** That is a 41% error in the input to the decision about
    whether the renderer holds 60 fps in a raid, and it is cheap now. Finding 6.

12. **Part C should record its sixteen policies AND their information regime, or M2 can
    never cross-check it.** Part C published four policy names and four win rates out of
    sixteen, and said nothing about what those policies could see. `Rush-horse` reproduces
    to **1.2pp** (76.6% here under fog against C.6's 77.8%) because the name specifies the
    strategy; `Greed-pure`, `Turtle-eco` and `Balanced` disagree by 21-71pp because their
    names specify nothing. That is not a disagreement between two sims, it is two rosters
    sharing four labels - and it makes every per-line and per-family figure in C.6
    unfalsifiable. **A balance figure that cannot be re-derived is a memory, not a
    cross-check.** Finding 5.

13. **CLOSED BY THE OWNER, 2026-08-13, AND IMPLEMENTED.** `IDLE_BATTLE_FOG.md` section 3a
    rules that *"a unit also reveals any enemy entity it is in combat with, whatever section
    that entity is in"*, entity-scoped. `fog/Fog.lua` implements it, `tools/fogtest.lua`
    section 15 pins it and its negation, and Finding 10 measures what it did to the sweep --
    which was more than any roster change in this README has managed: the 5-10 minute band
    clause went from failing at all four sampled seed bases to passing. **Two things the
    ruling did not settle came out of implementing it and are open item 19.** The original
    text follows so a reader of the earlier version does not go looking.

    ~~**FOG: at C.3's 60-unit melee range, a unit attacking the enemy front building cannot
    see it, and that is probably not intended.**~~ `IDLE_BATTLE_FOG.md` puts their front slot
    at observer coordinate 1,300, which is section 6, and section 3 is emphatic that a unit
    lights *"not the sections before it, not the sections after it"*. `BUILD_BLOCKS_ADVANCE`
    stops an attacker at range of the thing it is hitting, so a Spear or a Horse grinding
    that building stands at **1,240 - section 5** - and the building is never rendered. A
    Bow (range 320) stops at 980, still inside its own half. So under a literal reading a
    front building is only ever seen by a unit that walks PAST it, which happens after it
    falls. Section 5's own sentence *"an intact front building shields the back building
    from sight even from a unit standing right next to it"* reads as though the author
    pictured the attacker inside section 6. **It is implemented literally and
    `tools/fogtest.lua` pins it either way**; the ruling needed is whether engaging a
    building reveals it, or whether the front slot should sit at a coordinate a melee unit
    stops inside. Cheap now, and it changes what a player sees. Finding 8.

14. **FOG vs A.3: enemy keep HP. The two documents contradict each other and the
    implementation had to pick.** A.3's default-vision table gives the enemy keep
    *"position and exact HP, always, from tick 0"*. `IDLE_BATTLE_FOG.md` section 4 gives it
    *"Position always known; HP remembered from last sight"*. The fog doc is later and
    binding, so keep HP is now remembered, and the policy view carries the remembered value.
    **This is a real gameplay change** - you no longer have a live progress bar on the thing
    you are trying to raze - and it should be acknowledged explicitly rather than left as
    two documents disagreeing. If A.3 was right, it is a one-line change in `fog/Fog.lua`.

15. **FOG: `Rules.BUILDINGS.watchtower.vision = 600` is now a ruleset value with no
    consumer.** `IDLE_BATTLE_FOG.md` section 6 expresses the Watchtower's sight in SECTIONS
    -- *"sections 5 and 6 are permanently visible while it stands"* -- and the two do not
    agree: 600 units from the front slot at 700 reaches 1,300, which is the FIRST POSITION
    of section 6, so a literal reading of the ruleset field grants section 5 and one unit of
    section 6. `fog/Fog.lua` implements the doc and detects vision-granting buildings by
    `vision > 0`, so the field still selects WHICH buildings scout but no longer says how
    far. **It is inside `rulesHash`, so it cannot be removed here without a compatibility
    break** (checklist item 5). The ruling needed is whether to keep it as a selector, give
    it a section-denominated successor, or retire it at the next deliberate break.

16. **CLOSED BY M3, IN TWO HALVES, AND IMPLEMENTED.** The pulse cadence landed in part 1
    as the hashed `SHRINE_PULSE_EVERY = 200` / `SHRINE_PULSE_TICKS = 30` (D.2's own
    correction of "every 20 s for 3 s" into sim ticks), and part 2 implemented all four
    sources in `fog/Fog.lua`'s EFFECTS block - including Omen's own TEMPORAL channel into
    the policy view (`foe.lanes[l].omen` / `omenN`, lane and count only, a filter over the
    shared command queue), which is exactly the channel this item said the section model
    could not carry. `tools/fogtest.lua` sections 16-22 pin every rule and mutation-test
    each effect. The "strict under-estimate in four places" caveat is retired from
    `fog/Fog.lua`'s tail block; what remains outside the model is named there and in open
    items 19c, 25 and 26. The original text follows so a reader of the earlier version
    does not go looking.

    ~~**FOG: the three M3 information sources are named but not specifiable yet.**~~ Section 6
    lists Shrine's reveal pulse (*"Periodically, briefly"* - no cadence, no duration),
    Divination and Omen. Two of them fit the section model; **Omen does not fit it at all**
    - *"enemy deploy orders surfaced as they are issued: lane and count only"* is TEMPORAL
    rather than spatial, so it needs its own channel into both the renderer and the policy
    view rather than a section predicate. `fog/Fog.lua` implements none of them and names
    all four gaps in its MODIFIERS block, so the model is a strict UNDER-estimate of the
    shipped one in exactly four places and never an over-estimate. **The pulse cadence is
    the one number that must exist before M3 can be built.**

17. **FOG: A LINE HAS NOW SPENT A QUARTER OF ITS ECONOMY ON EYES AND THE INSTRUMENTS CANNOT
    TELL. This is the sharpest version of this item and it is the one to act on.**
    `Pathfinder` exists to buy sight and nothing else: a fresh tripwire into its blindest
    lane every 86 ticks -- the derived floor, one lane traversal split across the three lanes
    there are to watch -- which comes out at **42.8 bodies and 428 Levy a match, about a
    quarter of a side's base income** (measured, `sweep/fogaudit.lua` and the SC column).
    Blinding that one line and changing nothing else moves its own sight by:

    | statistic | Pathfinder, scouting | blinded | delta | the twelve blind lines moved by |
    |---|---|---|---|---|
    | `lit`, mean sections of 8 | 4.73 | 4.70 | **+0.03** | -0.01 to +0.07 |
    | `EYE`, share of lane-polls with ANY live sight of the enemy half | 44.5% | 40.5% | **+4.1pp** | -0.1 to +3.3pp |
    | median / band / razed keep, whole sweep | 433 s / 76.6% / 78.4% | 434 s / 76.4% / 78.6% | **nothing** | - |

    **So a quarter of an economy buys four points of "can I see anything over there", and
    the largest second-order move in the same table -- `Rush-spear`, which changed in no way
    at all and merely played a Pathfinder that had 428 more Levy of pressure -- is +3.3pp.**
    The sight a scout buys, MEASURED IN SECTIONS, is inside the noise of what the scout's
    own COST does to the match. **And the same tripwires are worth +15.7pp of win rate to
    the line that buys them** (`sweep/scoutprobe.lua`), so they are doing something large
    that the section columns cannot see -- most likely the CONTACT reveals of section 3a
    (which are entity-scoped and therefore invisible to `lit` by construction), or simply a
    distributed raid into the lane the enemy is not defending. **Separating those two is the
    cheapest high-value measurement left in M2 and it is not done.** Three things follow
    from the section half, and none of them is a policy question:
    - **The mechanic has a hard ceiling of one section per body.** A section is 250 units, a
      lane is 8 of them, and a body lights the one it stands in. Watching a whole lane is
      four simultaneous living bodies; watching the board is twelve. `lit` cannot go far
      above its 4.00 floor no matter what anybody spends, which is why the audit now reports
      `EYE` beside it.
    - **A tripwire cannot get past a contested lane, so sight is cheapest exactly where
      there is nothing to see.** Two Spears deployed on the same tick halt 60 apart at
      own-frame 970 and 970 -- `tools/fogtest.lua` section 15 walks it -- so a body sent
      into a lane the enemy is holding never reaches the enemy half at all; it joins the
      grind. It buys a section only in a lane nobody is contesting.
    - **The 250-unit warning window against a 20-tick order delay is unchanged**, and that
      is still the arithmetic in the paragraph below.
    **AND THE MEASUREMENT THAT CONTRADICTS ALL OF THAT, STATED HERE RATHER THAN LEFT IN THE
    FINDING.** `lua sweep/scoutprobe.lua 2 500000` prices the same tripwires at **+12.5pp of
    win rate for the body** and +3.2pp for the threshold (`Pathfinder` 63.2% -> 75.7% ->
    78.9%, standard error ~6pp). So the tripwires are worth a lot and the sections they
    light are worth nothing measurable. Either they are working through section 3a's CONTACT
    reveals -- which are entity-scoped and therefore invisible to `lit` and `EYE` by
    construction -- or "scouting" in this sim is a distributed raid into the lane the enemy
    is not defending. **That is the cheapest high-value measurement left in M2 and it is not
    done**; it needs a variant whose scouts are bought and then held at the midline.

    **The ruling needed is whether the doc intends sight to be bought a section at a time by
    bodies that die, or whether the buyable unit should be bigger** -- a wider section, a
    unit that lights the section in front of it, or a scout that is not stopped by the first
    thing it meets. All three are doc decisions. It is also the item most likely to be
    answered by M3's Watchtower/Shrine/Divination, which buy sight in units of SECTIONS and
    LANES rather than in bodies -- so a possible answer is "the M1 catalogue is not supposed
    to be able to see much, and the modifiers are the mechanic". That answer is available
    and it should be given explicitly rather than left to be inferred.

    **The previous version of this item, which is still the record of how it got here:**
    The earlier version of this item said nothing in the M2 roster bought sight, so
    the fogged sweep measured a game with a mechanic nobody played. Four of the sixteen
    lines now do (Finding 9), each because its own stated intent needs a perception the fog
    grants only to a body in the enemy half, and `sweep/scoutprobe.lua` prices the change.
    **What that measurement says is not flattering to the mechanic, and it is the thing to
    take to the doc owner.** A tripwire costs 17-21 Spears and 174-204 Levy a match -- 12-14%
    of the Levy that line earns -- and buys back only a small share of the warning the
    fog deleted: `sweep/fogaudit.lua` measures the early-warning dividend at **2.2% of
    Turtle-eco's threat detections, 0.5% of Adaptive's and 0.4% of Counterpunch's**, against
    the **9.3% / 20.0% / 5.6%** those same lines lose to the fog under full information. So
    on these numbers **buying sight recovers under a quarter of what the fog takes, at a
    tenth of your economy.** Three things follow, and all three are questions for the
    document rather than answers this directory can give:
    - **Is that the intended price?** Section 3 sells scouting as the thing that makes the
      fog fair. If a scout is this weak, the fog is not a trade-off, it is a tax.
    - **The tripwire's window is 250 units wide.** A body immediately past the midline
      renders enemy units from own-frame 751, which is 12 sim ticks of a Horse and 25 of a
      Spear -- the ORDER DELAY alone is 20. A warning shorter than the order delay is not a
      warning. Widening it means either wider sections or letting a unit light the section
      in front of it, both of which are doc decisions.
    - **It interacts with item 13.** A scout stopped at range by an intact front building
      halts at 1,240, section 5, and under the literal rule never sees the building it is
      standing next to -- so the commonest scouting outcome learns nothing about the thing
      the scout was sent to look at.
    Still open in the original form: **whether Part E's milestone is a claim about a roster
    that scouts at all.** Findings 8 and 9; `lua sweep/scoutprobe.lua` and
    `lua sweep/fogaudit.lua`.

18. **FOG vs the ruleset: `keepDamageDealt` is a second, always-live route to the enemy
    keep's HP, and the fog doc's memory rule does not survive it.** Section 4 says the enemy
    keep's *"HP [is] remembered from last sight"*, and `fog/Fog.lua` implements exactly that.
    But nothing heals a keep and nothing but units damages one, so `KEEP_HP -
    me.keepDamageDealt` is that keep's EXACT current HP, continuously, with no sight
    required -- and `keepDamageDealt` is this side's own accumulated statistic, which
    `Rules.C.SCORE_SHOW_TICK` exists to display live from the 20 percent mark as a term of
    the Q10 tiebreak score. **Two documents, two answers.** The implementation has NOT
    picked: the field is left in the policy view because it is a fact about the observer's
    own units, no line reads it (the engine in `policy/lines.lua` never touches it), and
    `policy/Policy.lua` names the contradiction at the point it happens. The ruling needed
    is whether the Q10 score display is exempt from the fog doc, or whether the score has to
    be withheld or coarsened until the keep is seen. It is cheap now and it is a renderer
    decision before M7 either way.

19. **FOG 3a: implementing contact reveal needed THREE readings the ruling does not make,
    and one of them is a straight contradiction between two sentences of the doc.** The
    rule itself is settled and implemented (item 13 is closed); these are the edges it
    leaves, each one implemented in the direction that keeps the model an UNDER-estimate,
    each pinned by a test in `tools/fogtest.lua` section 15 so the answer cannot change by
    accident, and each cheap to overturn.

    - **(a) WHOSE RANGE DECIDES? The observer's, so you do not see what is shooting you if
      you cannot shoot back.** "In combat with" is read as *inside my unit's weapon
      envelope* -- the same comparison `Sim.unitAttacks` makes when it picks a target. For
      every melee engagement in C.3 that is symmetric (Spear and Horse are both range 60),
      so a defender does see its attacker. It is NOT symmetric when the shooter outranges
      the target: their Bow (320) shooting my Spear (60) from 300 away is in contact with
      my Spear from ITS seat and is invisible from mine. The alternative -- "either one can
      hit the other" -- would put the enemy's whole damage model (unit ranges, building
      `dmgRange`, trap radii, every M3 range hook) inside the fog module, and would make the
      front-slot shield a property of which buildings happen to shoot rather than of the
      geometry. **The ruling needed is one sentence: is being shot at, by something you
      cannot reach, contact?**
    - **(b) THE SHIELD AND 3a CONTRADICT EACH OTHER ON EXACTLY ONE BOARD, AND SECTION 5 WAS
      GIVEN THE DECISION.** 3a says the shield is untouched because *"a unit cannot reach
      the back building while the front one still stands"*. That is true of every board
      reachable by walking in -- `BUILD_BLOCKS_ADVANCE` halts an attacker at the FRONT
      building, 400 units short of the back one, and `fog/Fog.lua` refuses to load if a
      ruleset edit ever breaks that. It is false for an INFILTRATOR: a unit already standing
      beyond their front slot when they REBUILD it is within 60 of the back building with
      the front one intact. Section 5 says the shield holds *"even from a unit standing
      right next to it"*, which describes exactly that unit, so the shield wins and on that
      one board a unit is hitting something it cannot see. **The ruling needed is which of
      the two sentences is the rule.**
    - **(c) BUILDINGS ARE NOT OBSERVERS.** The doc says *"a UNIT also reveals"*, so an Arrow
      Tower firing at an enemy unit does not reveal it. That case is nearly always moot --
      anything in a tower's range is usually in the observer's own half and free -- but not
      always, and the renderer will have to answer it in M7 anyway.

20. **M3: Q4 S5 and D.3's Swarm note give two different scopes for "one free deployment",
    and Conscription's own wording contradicts one of them.** S5 says at most one free
    effect fires "per EVENT"; the Swarm note says "per DEPLOY ORDER"; and Conscription's
    card text promises "the 3rd, 6th, 9th... costs 0", which a 9-unit batched order can
    only honour under the per-event reading (it contains the 3rd, 6th AND 9th). The note
    is the more specific gloss and the one that bounds the Swarm cost stack, so the
    implementation follows it: at most ONE free unit per deploy order, whichever effect
    fires first in ascending card id, and a blocked Conscription entitlement is LOST
    rather than deferred (deferral would need a pending-freebie mechanism no document
    describes). `Rules.lua` INTERPRETATIONS 15/16, pinned by selftest section 15. **The
    ruling needed is one sentence: is S5's event the deploy order or the individual
    unit?** A 9-spear order currently costs 80, not 60.

21. **M3: Scorched Earth's "Structures take the standard x0.5" is dead wording.** D.3
    defines its targets as "the up to three enemy UNITS in that lane nearest your own
    keep", so no structure can ever be hit and the sentence has nothing to apply to. It
    is implemented as written - units only, the clause inert - and recorded
    (INTERPRETATIONS 18). If the intent was for the burst to also strike buildings or
    the keep in that lane, that is a different card and needs a target rule (which
    slots? before or after the units?), a ruling, and a compatibility break.

22. **M3: the per-card affinity splits are unspecified for 39 of the 40 cards, and one
    is forced.** Q3 rules that every card carries 3 points, 3/0 or 2/1 across at most
    two types - and no document says WHICH cards split. The single derivable assignment
    is Granary Reserves = 2 Fortress / 1 Boom: section 9's Turtle Bank must total 8F/7B
    with pure Boom, "its own secondary", as its worst matchup, and only that split
    reproduces both (INTERPRETATIONS 14; the -120 worked example is a selftest golden).
    Every other card ships pure 3/0 in its home archetype, which is the conservative
    reading, not a claim of intent. **If the design wants more hybrid cards - and Q3's
    "2-2-1 is the most common build shape" suggests it pictured them - the owner should
    assign the splits**; each one is a hashed data edit and a deliberate compatibility
    break, cheap now and never cheaper.

23. **M3: five smaller card wordings needed a reading each; all five are implemented,
    recorded, and cheap to overturn.** (a) Counterwall's "that lane was last clear of
    enemy units" is read as the WHOLE lane, both halves - a defender facing an enemy
    that permanently garrisons its own half of the lane never gets the burst
    (INTERPRETATIONS 17). (b) Ward's "pre-mitigation damage" is read as the attacker's
    damage after its own unitDmg channel, before the structure multiplier and the wheel
    (INTERPRETATIONS 22). (c) War Drums' "any kill by any source of yours" is read as
    enemy UNIT deaths only - razing a building does not start the drums
    (INTERPRETATIONS 21). (d) Investment "credited at that Levy tick" is read as the
    first Levy tick at or after exec + 450, since exec + 450 is generally not on the
    Levy grid (INTERPRETATIONS 19). (e) Miasma's "x < 1000" is read in the CARD OWNER's
    frame, because the older doc says "inside your half of a lane" and the D.3 letter
    would otherwise damage enemies in their own half instead (INTERPRETATIONS 23). Each
    wants one confirming sentence in D.3; none blocks anything.

24. **M3: which roster and which regime is the post-M3 balance re-measure judged on?**
    M2's seventeen lines know nothing about cards, and Part E says every one of the 40
    modifiers "will be judged against the same statistics". That needs either lines
    that play loadouts (a large policy-layer work item with the same
    calibrated-instrument questions as Findings 7-10) or a ruling that the M3 balance
    pass is measured some other way (fixed archetype loadouts? the D.2 saturation
    table?). Part 2 cannot start the measurement before this is answered; the sim side
    is ready either way. **UPDATE, M3 part 2: the CORRECTNESS half of the milestone is
    done and green (`tools/m3.sh`, the M3 part 2 section), the policy view now carries
    every card-shaped field a carded line would need (omen channel, occupancy, marks,
    scan flag), and no line reads any of them - so this item is now the ONLY thing
    between M3 and a balance measurement. It still needs the ruling.**

25. **M3 part 2: does Veil hide a building from a PLAIN unit-lit section? Two binding
    sentences disagree and the implementation had to choose.** `IDLE_BATTLE_FOG.md`
    section 6 says a veiled side's buildings are *"exempt from every disclosure route
    ABOVE"* - its table's rows: Watchtower, Shrine pulse, Divination - which does NOT
    include the base section rule of sections 2-3. D.3's card wording says *"suppresses
    display of your buildings ... from EVERY SOURCE except contact reveal and
    destruction"*, which read literally beats the section rule too - but that sentence
    predates the section model (it was written against Q9a's disclosure-trigger list,
    where "every source" could not have meant a rule that did not exist). **Implemented:
    a body standing in the section SEES a veiled building; remote routes (tower light,
    scry, scan) do not.** Reasons: it is the only reading satisfying the fog doc's own
    scoping; the alternative deletes the base model's section rule for one card; and it
    would reintroduce the grinding-a-wall-you-cannot-see absurdity that 3a exists to
    remove, since a body at the wall is usually also in its section. The full argument
    is at `veiled()` in `fog/Fog.lua`; `tools/fogtest.lua` section 18 pins both the
    rule and the tower-light negation. **The ruling needed is one sentence: is the
    section rule a "disclosure route" Veil beats?** (On "destruction" as D.3's second
    exception: under this model a never-seen veiled building has nothing to disclose on
    death - the slot reads empty either way - so destruction-as-disclosure is an M7
    presentation question, like the self-announcement marks.)

26. **M3 part 2: Watchfires' REVEAL half exists in Q9b and not in the binding fog doc,
    and is implemented as the binding doc writes it - which is not at all.** Q9b's table
    gives Watchfires *"your defensive buildings gain +50% damage range AND REVEAL THEIR
    LANE OUT TO THAT RANGE"*; `IDLE_BATTLE_FOG.md` section 6 - later, binding, and
    claiming to restate Q9b *"so the two cannot drift"* - has no such row. The RANGE
    half is sim-side and landed in part 1; the reveal half is not modelled, and
    `fog/Fog.lua`'s tail block names the gap. If the reveal is wanted, the doc owner
    should add the row (and say whether it is section-scoped like the Watchtower or
    range-scoped like nothing else in the model - the two differ exactly at a section
    boundary); it is a small, isolated addition to the EFFECTS block once specified.

27. **M3 part 2: the Shrine pulse does not light sections or mark ground explored, and
    the fog doc's own phrasing can be read either way.** Section 6's row says the pulse
    reveals *"every section of every lane, plus enemy building occupancy only (not
    identity, not HP)"*; Q9b's row says *"all enemy units in all lanes at full detail,
    plus enemy building occupancy only"*. The two compose only if "every section" means
    the CONTENTS the other clauses grant - units at full detail, buildings at occupancy
    - because a pulse that genuinely lit sections would stamp the FULL memory record
    (identity + HP) through the section rule, contradicting "occupancy only" in the
    same sentence. **Implemented: the pulse reveals units and occupancy, lights no
    section, and leaves `seen`/exploration untouched** - same shape as contact being
    entity-scoped, and pinned by `tools/fogtest.lua` section 19. If the intent was that
    a scanned lane also counts as EXPLORED (the renderer's "you have seen this ground"
    state), that is one sentence for the doc and a small change here.

## Cross-implementation verification (M1 verification pass)

The suite has been run under **two Lua implementations with different numeric
models**, and they produce **identical hashes**. Every row below is keyed to the exact
command that produces it, because the previous version of this table quoted a `SUITE HASH`
and a `stateHash` that no command in this tree reproduces - a golden nobody can regenerate
is not a golden.

**All four values are the ones `harness/selftest.lua` and `harness/fuzz.lua` assert against
their committed constants**, so a mismatch on a second machine goes red on its own rather
than needing to be spotted in this table.

**M3 values (current):**

| from `sh tools/ci.sh 1000` | Lua 5.5 (native 64-bit integers) | LuaJIT 2.1 (Lua 5.1 semantics, doubles) |
|---|---|---|
| `rulesHash` (`Rules.rulesHash`) | 767294897 | 767294897 |
| `stateHash` (`hand.iblog` at tick 260, `GOLDEN_STATE`) | 1939244196 | 1939244196 |
| `logDigest` (same log, `GOLDEN_LOGDIGEST`) | 1455081792 | 1455081792 |
| `SUITE HASH` (1,000 logs, half carded, `GOLDEN_SUITE`) | **1912059909** | **1912059909** |
| selftest | 641 checks pass | 641 checks pass |
| fogtest (M3 part 2) | 667 checks pass | 667 checks pass |

| from `sh tools/m3.sh 200` (M3 part 2) | Lua 5.5 | LuaJIT 2.1 |
|---|---|---|
| `M3 CARDS SUITE HASH` (80 matches, 360 runs) | **116896602** (`xlhzu`) | **116896602** |
| `M3 LOADOUTS SUITE HASH` (200 matches, 825 runs) | **448422185** (`ez8rt`) | **448422185** |
| clamp report | byte-identical text | byte-identical text |

These two M3 suite hashes are not committed goldens (no file asserts them --
they certify a milestone rather than guard a commit); they are recorded here so
a second machine's `sh tools/m3.sh 200` is a mechanical diff.

| from `sh tools/m4.sh` (M4) | Lua 5.5 | LuaJIT 2.1 |
|---|---|---|
| codec | 3,087 checks pass | 3,087 checks pass |
| `MILESTONE SUITE HASH` (100 runs) | **1353990724** (`e4pxg`) | **1353990724** |
| `ROLLBACK SUITE HASH` (40 runs) | **630668562** (`fhez6`) | **630668562** |
| `DEEP SUITE HASH` (12 runs) | **1794064162** (`o50rm`) | **1794064162** |
| `STRESS SUITE HASH` (25 runs) | **1907532503** (`jp1hz`) | **1907532503** |

The M4 suite hashes fold every run's terminal state, terminal tick, logDigest,
settle tick, repair counters (late, rollbacks, dups, N, backstop, Q, rebuilds),
message counts and the channel's drop/inversion/byte-max statistics -- so two
interpreters printing the same four numbers agreed on every repair decision of
every net match, not merely on where the matches ended. Like the M3 pair they
are milestone certificates rather than committed goldens; a second machine's
`sh tools/m4.sh` is a mechanical diff against this table.

*The pre-M3 record, superseded when the forty cards entered the hashed ruleset
(regenerated together on 2026-08-21): rulesHash 333968378, stateHash 1822913174,
logDigest 1455081792, SUITE HASH 2005649413, 305 checks.*

**The `SUITE HASH` row is keyed to the 1,000-log milestone run and to nothing else.**
`harness/fuzz.lua` only asserts `GOLDEN_SUITE` when the run is exactly the milestone
configuration (1,000 logs, 6,000 ticks, base seed 700001, epoch 60, chaos 100, mirror on,
fine 25); a 60-log run produces a different, un-asserted number, and quoting one of those
beside the command `tools/ci.sh 60` is how the earlier version of this table stopped
reproducing.

This matters more than it looks. WoW's Lua 5.1 has **no integer type** - every
number is a double - while Lua 5.5 has real integers. Those are precisely the
two representations that would disagree if any arithmetic in the sim were not
integral. They agree bit-for-bit, which is direct evidence that the
integer-only discipline holds and that the sim will behave identically inside
WoW.

Run it yourself:

    sh tools/ci.sh 1000 "$(which luajit)"   # 5.1 semantics
    sh tools/ci.sh 1000                     # 5.5

(`sh tools/ci.sh 60` is fine as a fast check and will still assert `rulesHash`,
`GOLDEN_STATE` and `GOLDEN_LOGDIGEST`; it just does not produce the `SUITE HASH` above.)

`tools/ci.sh` does not recognise LuaJIT as a 5.1 interpreter, so its closing
banner still claims 5.1 was "static only" even on a LuaJIT run. Ignore that
line when the interpreter is LuaJIT; the hashes above are the real evidence.

**Still genuinely unproven: a second physical machine.** Everything above ran on
one host (Darwin arm64). To close it, run `sh tools/ci.sh 1000` on another
machine - ideally the Windows gaming PC - and confirm `SUITE HASH 1912059909`
and `rulesHash 767294897`. Different CPU, different OS, same numbers.
