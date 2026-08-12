# IDLE_BATTLE_DECISIONS.md — v2

*Companion to `IDLE_BATTLE.md`. This document answers Open Questions 1–16, fixes a set of
numbers an implementer can code against tomorrow, names what ships in the first playable and
the first shipped build, and lists what is still genuinely open.*

*Status: **tuning pass two**, rewritten end-to-end under six owner rulings. The structural
decisions (Parts A and B) are meant to hold. The numbers (Part C) are meant to move.*

*Supersedes v1 of this document in full. Where v1 and v2 conflict, v2 wins; where v1 is not
mentioned, assume it was deleted rather than forgotten — §0.3 lists every deliberate deletion.*

*Inputs: three specialist reworks (architecture, economy, modifiers) run under the rulings, a
purpose-built Python match simulator (~35,000 simulated matches across the tuning sweeps), the
shipped `PengyouGames` 1.0.0 source, `SPEC.md`, `SCOPE.md`, `CONCURRENCY.md`.*

---

# 0. WHAT CHANGED IN v2, AND WHY

v1 was a correct document built on one load-bearing assumption the owner has now rejected: that
a hidden loadout had to survive a modified client, and that everything else should bend around
that. It does not, and once it stops bending, roughly a third of v1's machinery evaporates.

Six rulings. Each is binding. This section states each one and its concrete consequence, so a
reader who only knows v1 can see exactly what is different before reading another page.

## 0.1 The six rulings and what each one did

### Ruling 1 — FULL STATE SHARING

*Hiding information from the **player** does not require hiding it from the **client**. Both
clients may exchange and hold complete state, including full loadouts at handshake. Fog of war
is a rendering decision only. A modified addon can therefore see everything, and that is
accepted.*

**Consequence — this is the largest change in the document.** v1's split simulation is gone.
There is now **one deterministic simulation** covering both players' units, buildings, keeps,
Levy, bank, income, costs, cooldowns, modifier runtime state and tiebreak accumulators, run
identically on both clients over a fully shared input set. Nothing in the sim is owner-only.

Deleted outright: the board/economy split (v1 §0.2a), the anonymous 7-slot coefficient vector,
the affinity vector on the wire, the four disclosure classes (PRIVATE/BAKED/EFFECT/ANNOUNCE),
deferred building disclosure with its three airtightness conditions, the per-building
`deferrable` boolean, the unconditional empty `C` batch, the EFFECT wire class, and the rule
"issuer validates, receiver trusts."

Newly possible, and all seven of these are real:

1. **Affordability is validated on both sides.** Validation moves from issue-time-on-the-issuer
   to exec-tick-in-the-sim. A command that cannot be paid for is a no-op on both clients,
   computed identically. A fizzle is a defined outcome, not an error.
2. **The hash covers everything.** v1 could hash only the board, so a divergence in income,
   cost, bank cap or any economic modifier was undetectable until it eventually moved a unit —
   if it ever did. **v1 literally could not detect a disagreement about who won.** v2 hashes
   Levy, bank, every accumulator, every modifier flag, and the tiebreak ladder's counters.
3. **Replays, and reproducible bug reports.** A whole match is
   `(rulesHash, seed, loadoutA, loadoutB, commandLog)` ≈ 800 bytes at ten minutes. It replays
   to any tick on any machine. A desync dump is now a reproducing test case; under v1 it was
   not, because one player's cards were absent. It also makes mid-match **reconnect** possible
   for the first time (Q15).
4. **Full-log recovery becomes possible at all.** Rebuilding from tick 0 requires reconstructing
   the initial state, which requires both loadouts. v1's `Q`-then-replay path was fictional for
   the economy half — it could only ever repair the board.
5. **`[Rule]` cards become expressible.** A 7-slot coefficient vector cannot encode Tide of
   Bodies, Golden Age, Conscription or Plunder. Ruling 5 is therefore not merely *compatible*
   with Ruling 1 — it is **impossible without it**. The two rulings interlock.
6. **Cross-economy cards are free.** Hex and Discord touch the opponent's Levy; your sim now
   holds it. Ordinary local arithmetic, zero new wire.
7. **One implementation per card.** v1 needed two code paths that had to agree bit-for-bit
   ("compute what Bulwark Line does" and "apply a raw +40% HP delta"). One path now.

**The honest cost, stated plainly: the determinism surface roughly doubles.** Under v1, a float
or a `pairs()` in my economy could not desync your client, because you never ran it. Now every
line of economy, modifier and tiebreak code runs on both machines and any of it can desync.
This is paid for in the M1 harness (Part E), not in architecture.

### Ruling 2 — PAUSING IS FINE, AND THE RAID CASE IS SYMMETRIC

*In a raid, when one player pulls, the whole group enters combat, so both players usually go
mute at the same moment and resume together. v1 treated asymmetric mute as the norm; it is the
exception.*

**Consequence.** The halt design is inverted. **Symmetric pause is the fast path and requires
zero messages for correctness** — both clients receive the same server event at the same instant
and both do the right thing unilaterally. There is nothing to negotiate and no fairness
accounting to do, because neither player can act and both resume together. The `X`/`K`/`G`
protocol is demoted to an optimisation for the case where the two players are in *different
content*, which is where all the care now goes. v1's §0.1 framing — that a match "will
frequently spend more wall-clock time paused than playing" and that this is a cost to be
justified — is deleted. It is a non-event; both players are watching the same boss.

Halting also became **eager**: a client halts on suspicion and resumes on evidence, because a
halt is tick-indexed, exactly reversible, loses no state and does not advance the match clock.
v1 required two missed heartbeats (12–18 s) of confirmation before halting. v2 halts at 10 s of
silence, immediately on any local event, and never waits for the peer.

### Ruling 3 — RAID DOWNTIME IS NOT THE HARD CONSTRAINT

*The game is also for people idling in capital cities, sitting in queues, or otherwise with time
on their hands. Do not optimise for 60–120 second raid windows or treat spanning multiple pulls
as a defect.*

**Consequence.** Every v1 decision justified by "raid downtime is 60–120 s" was re-examined:

- Match clock doubled (Ruling 4 sets the band; Ruling 3 is what makes it acceptable).
- Pause budgets widened: single pause **20 min**, total pause **40 min**, wall clock **90 min**
  (v1: 12 / 20 / 45).
- Silence-to-void widened from 300 s to **900 s**. A mythic progression pull plus a wipe and a
  run-back comfortably exceeds 300 s; v1 would have voided mid-encounter.
- Rickety Scaffolds is un-cut. v1 cut it as "anti-identity for the archetype that must win in
  90 seconds." There is no 90-second requirement any more.
- Investment is un-cut. Its 45-second timer was cut for "straddling a pull"; timers are in sim
  ticks and sim ticks do not advance while halted (Ruling 2 also makes both players straddle it
  together).
- The Q1 dead-opening argument got **stronger**, not weaker: a player idling between queue pops
  has less patience for a dead first 25 seconds than a raider does, not more.

### Ruling 4 — MATCH LENGTH IS 5 TO 10 MINUTES

**Consequence.** Match clock **6,000 sim ticks = 600 s of active sim**, hard cap. All economy
numbers re-derived. The critical finding is that **a 10-minute match must not be twice as rich
as a 5-minute one**: total match Levy rises only ~14% (1,520 → 1,740) while duration doubles.
Doubling the pot would have doubled unit throughput and the compounding runway, producing a
longer version of the same three minutes rather than a longer game. The lever that does this is
the **Levy tick period, moved from 2.0 s to 3.5 s** — the single most powerful dial found in the
whole sweep. Measured length distribution: p10 233 s, median 406 s, p90 600 s; 77% inside the
5–10 minute band.

### Ruling 5 — `[Rule]` MODIFIERS SHIP IN v1.0

*The owner accepts the balance risk. Cards may be cut for **technical** reasons — a determinism
hazard in a lockstep sim, or unimplementable — never merely for being hard to balance.*

**Consequence.** Applying that test strictly: **all 40 modifiers ship. Zero technical cuts
survive.** v1's ten cuts and five deferrals all fail — nine were balance or implementation-cost
judgements, one (Watchfires) rested on a factual error about the building catalogue, and the
single genuinely technical one (No Retreat, "HP-scaled damage is order-dependent within a tick")
dissolves under a tick-start snapshot that a correct lockstep sim must have anyway for symmetric
mutual kills. 17 of 40 are `[Rule]`. 24 required rewording to be deterministic and bounded; the
rewordings are in Part D. **v1's "zero Tier-3 modifiers, ever" rule is deleted**: under the
fixed-width command atom, granting the player a new verb costs *a letter in the kind field*, not
a new message type.

### Ruling 6 — PUBLIC SCOPE IS OFFERED

**Consequence.** Party, guild and public/realm-wide all ship in v1.0, on the shipped
`SCOPE.md` machinery unchanged. This has one non-obvious knock-on that shapes Part A: **a
stranger on your realm is by definition in different content**, so the asymmetric-pause path is
*common* in public scope, not exceptional. The `X`/silence machinery is load-bearing there.

## 0.2 The one thing that did not change

**A comms lockdown cannot desync a match.** A player who cannot send produces no inputs, and "no
inputs" is the one thing two deterministic simulations always agree about. It was never a
synchronisation problem; it is a fairness and pacing problem, and the answer is halt-and-resume.
v1 got this right and v2 keeps it verbatim. What changed is only the *shape* of the halt design
(Ruling 2), not the finding underneath it.

The second thing that did not change is **why any of this is affordable**: progression is
horizontal and participation-based (`IDLE_BATTLE.md` §10), so nothing is at stake in a match
except a fraction of an unlock. That is what lets the netcode **void aggressively instead of
guessing** — no winner, no forfeit, no rating effect, credit paid pro-rata. If progression is
ever made vertical or competitive, this entire answer collapses. It remains the one design
change that would threaten the concept.

## 0.3 The delete list — do not implement these by accident

Everything below appears in v1 and is **gone**. It is listed explicitly because several are
attractive ideas that an implementer who read v1 might reach for.

| Deleted from v1 | Where it was | Why it is gone |
|---|---|---|
| The board / private-economy split | §0.2(a) | Ruling 1. Its sole purpose was defending a hidden loadout. |
| The anonymous 7-slot coefficient vector | §0.2(a), B.7 `S` | Derived from the loadout by identical code both sides; v1's own rule 1 forbade sending derived numbers. |
| The 5-number affinity vector on the wire | B.7 `S` | Same — derived, not transmitted. The affinity *system* survives (Q3). |
| "Issuer validates affordability; receiver trusts" | §0.3, B.7 rule 2 | Inverted. Both sims validate at the exec tick. |
| Deferred building disclosure | Q9a | Fog is a render filter now. Nothing is withheld from the wire. |
| The `deferrable` per-building boolean and the three airtightness conditions | Q9a, B.4 | Same. |
| The unconditional empty `C` batch (`n = 0`) sent to hide timing | Q9a | Nothing to hide on the wire. |
| The PRIVATE / BAKED / EFFECT / ANNOUNCE disclosure classes | Q9a | Same. |
| The EFFECT wire class (`TAX +8% for 30 s`) | C.4 | Cross-economy cards are local arithmetic now. |
| "Zero Tier-3 modifiers, ever, in this architecture" | Q5 | Ruling 5, plus the fixed-width atom absorbing new verbs. |
| The per-lane **headcount** cap of 12 per side | §0.2(b), Q4, B.1 | Actively harmful — see Q4. Replaced by a **supply** cap of 200 Levy. |
| "Bank cap is the strongest aggression dial in the game" | §0.2(c) | Measured false at 10 minutes: 1.8pp across a 3× sweep. The coupling *rule* survives. |
| The ten card cuts and five deferrals | Q5, Q8, C.5 | Ruling 5. All 40 ship. |
| The `View*` accessor naming convention as the enforcement mechanism | Q9a | Replaced by four stronger greps, including a side-agnostic-sim grep (A.5). |
| M6's milestone ("a `/dump` of the opposing board contains no undiscovered building") | Part D | False by construction now. Replaced. |
| Match length as an open owner question (300 s vs 240 s) | Part E | Closed by Ruling 4. |
| Public scope as an open owner question | Part E | Closed by Ruling 6. |
| "Any `[Rule]` cards in v1.0 at all?" | Part E | Closed by Ruling 5. |

---

# Part A — Architecture

*This part leads the document because Ruling 1 simplifies it materially, and because everything
in Parts B–D assumes it.*

## A.1 One simulation, both halves, nothing private

There is **one deterministic simulation**. It covers, for both players symmetrically:

- units (position, HP, type, lane, per-unit flags such as Vanguard)
- buildings (slot, type, HP, construction progress, Rubble marks)
- both keeps
- **Levy, bank, income rate, every cost, every cooldown**
- every modifier's runtime state (Golden Age latch, Muster charges, War Drums expiry,
  Investment countdown, Bypass flags, Counterwall accumulators)
- the tiebreak ladder's cumulative counters (Q10)

It runs identically on both clients over a fully shared input set. Both loadouts are exchanged
in full at handshake. **Nothing in the sim is owner-only.**

Amend `IDLE_BATTLE.md` Part III's wording, as v1 did: **this is not lockstep.** It is
**delayed-input deterministic simulation with bounded rollback**. True lockstep stalls tick *N*
until both players' inputs for *N* are in hand; on this platform a stall lasts for a boss fight.
The sim never stalls — it free-runs and repairs.

## A.2 The sim is side-agnostic, and this is the strongest invariant in the design

**The sim does not know which side is "me".** It computes both halves with the same code over
`side = 0 | 1`, where `0` is the host and `1` is the client. No sim file may reference
`PG.FullName`, `"player"`, `myName`, or any local-identity accessor.

A simulation that cannot tell which side you are **cannot leak to you and cannot branch on
you**. That bug class — one client's sim quietly behaving differently because it can see who it
is — is the main killer of lockstep implementations, and v1's design left it wide open, since
v1's sim necessarily knew which economy was its own. Under v2 it is a single grep.

## A.3 Fog of war is a pure render filter

One module, `IBFog.lua`, exports `Fog.Visible(entity) -> bool`. **The renderer is its only
caller.** The default vision rules and the Mystic vision cards (Q9a, Q9b) are all expressed as
predicates in that one function.

Consequence for the modifier pool: Divination, Omen, Veil, Watchfires' reveal and the Shrine
pulse are **pure `Fog.Visible` predicates** — zero sim surface, zero wire surface, zero desync
risk. Under Ruling 5 they are the *cheapest* `[Rule]` cards in the pool, not the most exotic,
and their ship order moves earlier accordingly (v1 deferred them to v1.1 partly on disclosure
machinery that no longer exists).

## A.4 Authority: intent on the wire, outcomes in the sim

Two encoding rules, one kept and one inverted.

1. **KEPT.** The wire carries **intent only** — never outcomes, never derived numbers, no costs,
   no damage, no HP, no coefficients. The moment a derived number crosses, one client can "win"
   a disagreement without anyone noticing. v1 got this right and it is the reason the command
   atom needed no change at all.
2. **INVERTED.** Affordability, legality (slot occupied? cap reached? lane supply full?
   Investment already outstanding?) and outcome are evaluated **at the exec tick, in the sim, on
   both clients, from state both clients hold.** The issuing UI renders orders as pending and
   predicts; **it is not the authority.**

**Canonical intra-tick execution order is elevated from a note to a hashed invariant:** sort by
`(playerIdx: 0 = host, 1 = client)`, then `seq`. Under v1 this only decided entity ordering.
Under v2 it decides **money** — two deploys landing on one tick where only one is affordable —
so the ordered log is covered by `logDigest` and an ordering disagreement is caught before it
can move a single unit.

## A.5 The four greps

The enforcement invariant flips direction and gets much cheaper than v1's. All four are
mechanical, all four are checked at M1 and again at M7, and this matches the review style
`CONCURRENCY.md` §1.2 already uses.

1. Sim files contain **zero** references to `Fog.` or any view accessor.
2. Sim files contain **zero** references to local player identity — no `PG.FullName`, no
   `"player"`, no `myName`. (A.2)
3. Sim files contain **no float literals** and **no `/` outside a `math.floor(...)`**.
4. Sim files contain **no `pairs()`**.

## A.6 Halt is always a LOCAL decision

**The rule: a client halts on its own evidence, immediately, and never waits for the peer. The
protocol is correct if every halt message is lost.** `X` is a courtesy that improves the overlay
text and shortens the asymmetric window; it is never required for correctness.

Halt reasons, each a latch, reason letter carried in `X`:

| Letter | Reason | Sends still legal at trigger? |
|---|---|---|
| `R` | `ADDON_RESTRICTION_STATE_CHANGED` → active | **Yes** — fires *before* the restriction |
| `C` | `START_PLAYER_COUNTDOWN` | **Yes**, ~10 s of warning |
| `Y` | `READY_CHECK` | **Yes** |
| `E` | `ENCOUNTER_START` | usually already muted |
| `L` | `PG.Comm.Locked()` observed true on a sim tick | muted |
| `Z` | `PLAYER_ENTERING_WORLD` (loading screen) | muted |
| `D` | our own `C` came back through `onDrop(mtype, token)`, or the effective-delay estimate exceeded the 40-tick clamp | — |
| `M` | manual (the player pressed Pause) | yes |
| `P` | peer halt inferred (`X` received, or inbound silence) | — |

`R`, `C`, `Y` and `E` arrive **free** from `PG.Safety.OnChange` (`Core.lua:237`, triggers
`RESTRICT_ON` / `COUNTDOWN_ON` / `READY_ON` / `ENCOUNTER_ON`; `SPEC.md:145`). **Zero new event
registration.** Only `Z` needs a local `PLAYER_ENTERING_WORLD` hook.

**`ADDON_RESTRICTION_STATE_CHANGED` is the most valuable event in this design and should be
named as such in the code.** `SPEC.md` rule 10 (line 56) verifies it fires **before** the
restriction activates — the one window in which a client that is about to go mute can still tell
its opponent so. Every other mute path degrades to silence detection.

**Eager halt.** A false-positive halt costs 2 messages and ~2 seconds. A missed halt costs the
only genuinely unfair state the game has. So the client halts on suspicion and resumes on
evidence. Ruling 3's high pause tolerance is what makes this affordable; eager halting is what
bounds the asymmetric damage.

## A.7 Symmetric pause — the fast path, zero required protocol

Trigger: the raid pulls. `ENCOUNTER_START`, or `START_PLAYER_COUNTDOWN` ~10 s earlier, fires
from the same server event on both clients.

```
t+0 frame   each client independently latches its halt reason, freezes the tick counter
            and the match clock, freezes the render behind a PAUSED overlay, and stops the
            module send bucket for `C`.
t+0         each client sends `X|<tick><reason>` (20 bytes) BEST-EFFORT, only if sends are
            still legal — true for R / C / Y, i.e. the pull-timer path, which is most raid
            pulls. If refused or lost, nothing breaks. An inbound `X` is idempotent and a
            no-op on an already-halted client.

            MESSAGES REQUIRED FOR CORRECTNESS: ZERO.

            During the pause the two tick counters differ by the ordinary skew (1–5 ticks).
            That difference is TEMPORAL, NOT DIVERGENT: nothing can be issued, so there is
            nothing to disagree about.

ENCOUNTER_END fires on both. Each clears its latches, then:
t+0         each side sends `K|<tick>` (19 bytes). Both sides send it; the host is not
            special here.
t+RTT       the HOST — and only the host — computes resumeTick = max(myTick, peerTick) and
            broadcasts `G|<resumeTick>` (22 bytes), then runs a local 3-2-1.
t+RTT       the lagging side fast-forwards to resumeTick (a handful of ticks) and runs its
            own 3-2-1 from receipt.
```

**Total: 2 `X` + 2 `K` + 1 `G` = 5 messages per pause across both players.** Typical resume
latency after `ENCOUNTER_END`: one RTT plus the 3 s countdown, about 3.5 seconds.

A player in an encounter can still receive, and it must:
**RECEIVE ALWAYS, LOG ALWAYS, ADVANCE NEVER WHILE HALTED.** Inbound commands during a halt are
logged with their original exec ticks and executed at resume by the identical code on both
machines. That is what makes the resume exact rather than approximate.

## A.8 Asymmetric pause — the case that needs the protocol

A is in M+ / a different raid / an arena; B is in Valdrakken. Under Ruling 6 this is the
*common* case in public scope.

**Case 1 — `X` lands** (the `ADDON_RESTRICTION_STATE_CHANGED` or countdown path). B halts on
receipt. One-sided sim = one one-way latency, ~0.2 s. Effectively free. This is why the
pre-restriction event is worth naming in the code.

**Case 2 — surprise mute, no `X` was sendable.** Liveness is **any inbound message**, not just
the heartbeat: `H` fires every 6 s and `C` traffic refreshes liveness too.
**Detector: 10 seconds of total inbound silence → provisional halt.** B stops advancing, shows
`SCOPE.md` §6.2's existing copy ("Waiting for &lt;opponent&gt; — they may be in a boss fight"),
and keeps receiving. Reversible with no ceremony if traffic returns. (v1's detector was two
missed heartbeats = 12–18 s.)

**The fairness cost, stated honestly and correctly.** It is **not** "B got free hits." Every
command B issued in the window carries `E = issue + 20` ticks and lands within ~11 s of the
resume tick, so **A is awake for all of them** and can answer within its own 2 s delay. The real
cost is **bounded initiative**: B had up to 10 seconds of unanswered decision-making, worth ~29
Levy of accrued income and one wave of positioning. In a game with a 2 s order delay and a
multi-minute keep kill, that is comparable to reacting slowly once. It is bounded, rare, and
accepted.

**Explicitly rejected: rewinding B to the peer's last-heartbeat tick on halt detection.** It
looks fair and is not — it does not retract B's already-logged commands, which keep their exec
ticks and execute anyway, so it buys only tidiness. Retracting them for real would require a
retraction message, a new failure mode, and a peer that already applied them. The rollback
machinery is not the right tool here.

**Resume, asymmetric.** A's mute lifts, A sends `K`, host issues `G|max(ticks)`. Because B is
*ahead*, it is A who fast-forwards. **A's catch-up must be rendered, not skipped**: replay the
missing ticks visually over ~1 second so the player watches what happened to their lane instead
of finding it already gone. This is a required UX behaviour, not a polish item.

## A.9 A muted client HALTS — it does not keep applying

A client that cannot send stops advancing its simulation, even though it can still receive and
could in principle keep applying the opponent's commands indefinitely without desyncing. Four
reasons, in order:

1. Advancing while unable to issue is the **only strictly-losing state the game contains**. It
   converts a chat-channel restriction into a game loss.
2. The muted client's own already-sent commands with future exec ticks would still fire, while
   nothing new could follow — a half-alive state that is worse than a clean pause and much
   harder to explain in the UI.
3. It makes the two clients behave asymmetrically, and asymmetric behaviour between two copies
   of one simulation is the single most reliable source of desync bugs.
4. With pausing accepted (Rulings 2 and 3) there is no product reason left to grind on.

v1 reached the opposite conclusion — correctly about *correctness*, wrongly about the *game*.

**The match clock counts ACTIVE SIM TICKS ONLY**, so a 40-minute M+ costs the match zero clock.

## A.10 Resume is single-writer, and clock drift is killed

Both sides send `K|<tick>` when their own latches are all clear, repeated on each heartbeat
until `G` arrives. **Only the host issues `G|<resumeTick>`**, and only when its own latches are
clear *and* it holds the peer's `K`. `G` repeats on each heartbeat until the peer's heartbeat
tick reaches `resumeTick`.

```
resumeTick = max(myTick, peerTick)
```

The lagging side fast-forwards by genuinely **re-simulating** those ticks — income accrues,
units march, combat resolves — never by assigning the counter. Both sims run the identical tick
sequence; only the wall-clock moment differs. **This is what kills accumulated drift**: skew is
absorbed at every resume rather than compounding across a match that may contain a dozen pauses.

If the **host** is the muted party, its `K` is the message it cannot send — and it does not need
to. It is the resume authority; it issues `G` when its own latches clear, and the client obeys.
The protocol has no state in which both sides wait for each other.

## A.11 The wire

Envelope is the shipped one, unchanged: `<WIRE_VERSION>|IB|<mtype>|<token>|<payload>`. With the
`CONCURRENCY.md` §3.2 token (`"1a-7f3"`, 6 bytes) the envelope is **14 bytes typical, 18 worst
case**. Payload alphabet is base-36 plus a small set of uppercase codes, deliberately excluding
`|`. **No `WIRE_VERSION` bump** — `Comm.lua:832` drops unknown modules silently, so adding `IB`
breaks nothing and tuning the battle never forces the guild off Loot Goblins.

### A.11.1 Handshake — 39 bytes, carrying strictly more than v1's 42

`IB|S|<token>|<payload>`, whispered, sent by the host on receiving `JOIN` and echoed by the
client. Payload is fixed width, no separators:

| Field | Chars | Meaning |
|---|---|---|
| `proto` | 1 | `IBPROTO` — battle **wire-layout** version |
| `seed` | 4 | 46⁴ ≈ 1.68M — reserved; no shipped system consumes it (see Q5) |
| `rulesHash` | 6 | 31-bit hash of the **entire ruleset** |
| `matchTicks` | 3 | match clock in sim ticks (6000 in v1.0) |
| `loadout` | 10 | 5 modifier IDs × 2 base-36 chars (1,295 cards addressable) |
| `flags` | 1 | reserved |

**25 bytes payload + 14 bytes envelope = 39 bytes.** v1's `S` was 42 bytes
(`proto 1 + seed 4 + coef 14 + affinity 5 + tableHash 4`). **The handshake got smaller by three
bytes while gaining the actual cards.**

`proto` gates the **wire layout**; `rulesHash` gates the **simulation content** — the modifier
table, building table, unit table, every constant in Part C, the clamp values, the lane supply
cap and `K`. Two different failure modes, two fields, **two different refusal strings**, reusing
the polite-refusal pattern at `Comm.lua:818`.

`rulesHash` is far more load-bearing than v1's `tableHash`: v1 only needed both clients to agree
about their *own* cards. v2 needs them to agree about all ten cards, both building tables and
every constant, because a single mismatched clamp value now desyncs at the first engagement.
**Consequence to plan for: a balance patch is now a hard compatibility break.** See G.4.

**T0 is set locally by each side the moment it holds both loadouts.** The resulting skew is one
one-way latency (1–5 ticks) and is absorbed by the input-delay term, never by a synchronisation
round trip.

### A.11.2 Command atom — unchanged, 6 bytes

| Field | Chars | Meaning |
|---|---|---|
| `EEE` | 3 | exec tick, base-36, absolute (46,655 ticks = 77 min of active sim) |
| `K` | 1 | kind: `S`/`H`/`B` units; `a`–`l` building catalogue; `i` Investment; `s` Scorched Earth; `l` Ley Line |
| `T` | 1 | target: `1`–`3` lane for units and verbs, `1`–`6` slot for buildings |
| `N` | 1 | count, base-36, capped at 9 by the UI; for `i`/`s` it is the block count |

The atom did not need to change because v1 already got the hard part right. **The three Tier-3
verbs Ruling 5 restored cost one letter each in the `K` field and nothing else** — this is the
concrete reason v1's "zero Tier-3 modifiers, ever" rule is deleted.

### A.11.3 Message table

Every in-match message carries a **5-byte prologue**: `<tick 3><ackThru 2>`. This is new; v1
carried tick and `ackThru` only on the heartbeat.

| Type | Payload | Bytes | Cadence |
|---|---|---|---|
| `OPEN` | as the shipped games, plus scope byte | ~35 | once, broadcast |
| `JOIN` | — | 14 | once, whisper |
| `S` start | `<proto 1><seed 4><rulesHash 6><matchTicks 3><loadout 10><flags 1>` | **39** | once each way |
| `C` command batch | prologue + `<seq 2><n 1><atoms 6n>` | 22 + 6n → **28** (n=1) to **70** (n=8) | ≤ 15/min |
| `H` heartbeat | prologue + `<lastSeq 2><epoch 1><stateHash 5><logDigest 4>` | **31** | 10/min |
| `X` halt | prologue + `<reason 1>` | 20 | on halt |
| `K` clear | prologue | 19 | on resume |
| `G` resume (host only) | prologue + `<resumeTick 3>` | 22 | on resume |
| `N` resend request | prologue + `<from 2><to 2>` | 23 | on gap |
| `M` mismatch | prologue + `<epoch 1><stateHash 5><logDigest 4>` | 29 | on hash disagreement |
| `Q` full-log request | prologue | 19 | ≤ 1 per 10 s |
| `V` void | prologue + `<reason 1>` | 20 | terminal |

**Largest message in the entire protocol is a 70-byte command batch** — one third of the
200-byte target and one quarter of the 255-byte hard limit. **Nothing is ever chunked, so
nothing can straddle a lockdown boundary.**

Note `boardHash` is renamed **`stateHash`**, and it now covers the whole sim (A.1) rather than
the board alone. This is Ruling 1's most valuable engineering payoff and the rename should be
literal in the code so nobody re-scopes it by accident.

### A.11.4 Rates and budgets

| Class | Typical | Worst |
|---|---|---|
| `H` heartbeat | 10 | 10 |
| `C` commands | 8 | 15 |
| resends | 1 | 3 |
| repair (`N` / `M`) | 0 | 2 |
| halt/resume (`X`/`K`/`G`) | 0 | 5 per pause |
| **total** | **19/min = 0.32/s** | **~32/min = 0.53/s** |

Enforce a **module-level bucket above the Comm bucket: capacity 4, refill 1 per 4 s, for `C`
only.** All orders inside one refill window coalesce into a single batch of up to 8 atoms — a
frantic clicker is **coalesced, never throttled with loss**. Heartbeats bypass the module bucket
but are marked supersede, so a stale queued heartbeat is replaced rather than stacked.
Contention against the 60/min prefix budget: worst-case battle 32 + `CO|HELLO` 1 leaves ~27/min;
a Loot Goblins host runs ~9/min. **Warn, never refuse** — `CONCURRENCY.md` I4 forbids
cross-module refusals.

## A.12 Reliability, rollback and recovery

- **Sequencing:** per-sender monotonic `seq` from 1, 2 base-36 characters (1,296; a ten-minute
  match issues ~80). Receiver dedups on `(sender, seq)` and holds the **complete ordered command
  log for the whole match** — both players', ~160 entries × 6 bytes. Retaining everything is
  cheaper than any windowing scheme, and it is now also the replay artifact (0.1, item 3).
- **Canonical execution order within a tick** — see A.4. This is a hashed invariant, not a note.
- **Acks: no standalone ACK type exists.** The heartbeat's `ackThru` is the ack and its
  `lastSeq` is the watermark — "the highest sequence number I have ever issued". A receiver
  holding 1..S therefore knows it has the sender's entire history as of that heartbeat, and
  since every later command has `E >= hbTick + 20`, its **confirmed-safe tick is
  `W = hbTick + 20`**. Above `W` the sim runs optimistically. **There is no empty-turn heartbeat
  because there is no turn.** A per-turn confirmation at even 1 Hz would consume the entire
  prefix budget for one player before any commands — and would deadlock under mute, in the exact
  situation it exists to handle.
- **Resend policy.** (i) Receiver-driven, primary: a gap is visible on the very next inbound `C`
  → send `N` immediately; the sender replies with a `C` carrying those atoms verbatim, same
  `seq`, same `E`. (ii) Sender-driven backstop: a command unacked after 2 heartbeats (12 s) is
  resent once, piggybacked. (iii) After 4 heartbeats unacked, stop — let the state hash
  adjudicate.
- **Bounded rollback.** Snapshot the full sim state every epoch (60 ticks), keep the last 5
  (30 s). A command arriving with `E < currentTick` is **not dropped**: if
  `currentTick - E <= 300`, rewind to the snapshot at or before `E`, splice the command into the
  log, re-simulate forward and let the render snap. Only a command older than the snapshot depth
  is unrepairable, and that escalates.

  *Ruling 1 changes what a snapshot contains.* It is no longer "the board" — it is Levy, banks,
  every accumulator, every latch and every cooldown as well. This is more memory (still trivial)
  and, more importantly, **it is now capable of repairing an economic divergence**, which v1's
  could not.
- **`Q` → full-log replay is now real.** Reuse the shape of `SYNCQ`/`SYNCOK`/`SYNCNO`, not the
  code. The peer replays its **entire command log** as `C` batches of 8 atoms — ~160 commands is
  20 messages, above the 10-token burst, so pace them across two burst windows. Reuse
  `SYNC_COOLDOWN = 10` verbatim. Because the receiver holds both loadouts and `rulesHash`, it
  can rebuild the initial state and replay from tick 0. **Under v1 this path was fictional for
  the economy half; it is now the primary repair for a deep desync.** The `SYNCNO` equivalent
  remains **void the match**.

## A.13 Where the specialists disagreed, and the rulings

| Topic | Positions | Ruling |
|---|---|---|
| Sim tick | netcode 10 Hz; economy "tick = 2 s"; match systems 5 Hz | **10 Hz sim tick with nested cadences.** All three were describing different clocks. |
| Levy tick period | v1 2.0 s; economy v2 3.5 s | **3.5 s.** The master balance lever — see Q1/Q2. |
| Lane cap | v1 headcount 12; economy supply 200 | **Supply 200, charged at base cost.** Headcount inverts the cost structure — see Q4. |
| Chaff / Breeding Pits pricing | modifiers "ship unchanged" (−40 / −20 cost); economy "far too strong" | **Economy wins.** Chaff −20, Breeding Pits −10. Direct measurement beats inherited values. |
| Boom's derived numbers | modifiers computed them against a 2 s Levy tick (3,000 Levy/match) | **Re-derived by the editor against the shipped 3.5 s tick (1,740 Levy/match).** See D.3 Boom. |
| Lane length | economy's crossing times imply 2,400 units | **2,000, unchanged.** Speeds are identical to v1 (10/7/20 per sim tick); only the reported crossing distance differed. Every measured result is unaffected — see C.3. |
| Plunder vs the new Spoils baseline | modifiers wrote Plunder at 50% before Spoils existed | **Plunder is re-derived to 100% + 20 flat**, per economy's explicit instruction that Spoils sits at 75% to leave Plunder room. |
| Cards over the new clamps | modifiers wrote several values against v1's looser clamps | **All modifier values re-expressed to fit the measured clamps.** Table in D.2. |
| Tide of Bodies / Ley Line cap references | both reference the deleted headcount cap of 12 | **Re-expressed against the 200 supply cap** and, for Tide, against the `unitDmg` clamp. |
| `WIRE_VERSION` | bump `"3"` → `"4"` | **No bump.** `Comm.lua:832` drops unknown modules silently. |
| Command validation | v1 "issuer validates, receiver trusts" | **Both sims validate at the exec tick.** Ruling 1. |

---

# Part B — the sixteen questions

Each answer gives the decision, reasoning, and a confidence. Questions that are the **owner's**
call are marked **[OWNER]**, with a recommendation anyway. Every answer is tagged against v1:

- **UNCHANGED** — v1's answer and reasoning both survive.
- **CONFIRMED, NEW REASONING** — same answer, but v1's argument for it is now wrong or dead.
- **CHANGED** — the answer moved.
- **REVERSED** — the answer flipped.

## Economy

### Q1 — Flat vs. ramping base income — **CONFIRMED, NEW REASONING**

**Decision: FLAT.** Levy ticks at a constant **10 per 3.5-second Levy tick** for the entire
match. All growth comes from buildings and slotted modifiers. Plus **two** baseline rules that
are part of this answer:

- **Repel refund 15%** (v1, unchanged): when an enemy unit dies inside *your own half* of a
  lane you recover 15% (floored) of the Levy it cost to build.
- **SPOILS 75% — NEW IN v2**: destroying an enemy **building** credits the destroyer 75%
  (floored) of that building's Levy cost, at the tick of destruction, subject to bank cap.

**Why flat, and why v1's stated reasoning must not be carried forward.** v1 justified flat by
claiming a ramp makes the all-in rush the best line (76–82%) and makes the economy build worse.
**At 10 minutes that specific claim is false** — a mild 7→13 ramp is close to neutral and
slightly *helps* aggression, and economy barely moves. Do not quote v1's numbers.

What actually survives, measured at the final settings:

| Income shape | Aggro | Economy | Defence | Mixed | Decisive | Best-line spread |
|---|---|---|---|---|---|---|
| **Flat 10** | 48.9 | 51.4 | 54.8 | 45.6 | **85%** razed keep | 57.8pp |
| Mild ramp 7→13 | 53.0 | 50.0 | 47.6 | 46.5 | — | 64.4pp |
| Steep ramp 3→17 | — | — | — | — | 76% razed keep | — |

1. Flat produces the **tightest family spread (9.2pp) and the highest decisiveness** of any
   income shape tested.
2. A steep ramp is actively harmful: decisiveness collapses to 76% and the median drags to
   481 s, handing outcomes to the tiebreak ladder.
3. **The dead-opening argument gets stronger under Ruling 3, not weaker.** Under 3→17 the first
   Trap Pit is affordable at 23 s instead of 7 s. A player idling in a capital city between
   queue pops has *less* patience for a dead opening than a raider does.
4. **Flat income is closed-form from the tick counter**, which under Ruling 1 matters more than
   it did: Levy is now *inside the hashed state*, and a client healing through a resync must
   recompute it exactly rather than replay an accumulator. A ramp needs an accumulator, and an
   accumulator is a thing two sims can disagree about.
5. It still protects Boom's identity. Trade Routes / Golden Age / Surplus **are** the upward
   curve; giving it away free makes Boom "slightly more of what everyone has".

Keep the design's own hybrid: **flat base, ramping only as a purchased building (Levy Post) or a
slotted card.**

**Why Spoils is new.** v1 gave the defender a 15% refund for winning a fight in their own half
and gave the attacker nothing. That asymmetry is survivable over 5 minutes and fatal over 10:
with symmetric income and a reactive defender, attack loses every even trade, and doubling the
match length doubles the number of even trades. Measured: spoils moves aggression
42.1% → 45.7% → 49.0% at 0 / 0.75 / 1.0 while pulling economy 65.0% → 61.4% → 59.7%. It is the
second-strongest aggression lever after the Levy period, and it is thematically right — it makes
"crack a lane" pay for itself. **Deliberately 75%, not 100%, so Plunder still has room to be a
card** (D.3, Raider 1).

A clean division of labour fell out and is worth stating as a tuning rule:

> **Repel refund is the defence dial. Spoils is the offence dial. Levy period is the
> aggression-vs-economy dial. Keep HP is the length dial. Each moves one thing.**

**Confidence: high.**

### Q2 — Cost curves — **CHANGED** (fully re-derived)

**Decision: see the full table in Part C.** Headline constants: 3.5-second Levy tick, 10 Levy
per tick flat, **30 Levy opening stipend**, bank cap 200, keep HP 48,000, **600-second** match
clock, lane length 2,000 units, **per-lane supply cap 200 Levy per side**, slot cap 4 of 6,
`×0.5` damage from units to all structures.

**The Levy tick period is the master balance lever, and this was the surprise of the exercise.**
Holding everything else fixed and moving only the period:

| Levy period | Aggression | Economy |
|---|---|---|
| 3.0 s | 43.9% | 57.6% |
| **3.5 s** | **47.9%** | **52.0%** |
| 4.0 s | 52.5% | 45.8% |

Nothing else came close — bank cap moved aggression 1.8pp across a 3× sweep, keep HP moved it
0.0pp. The mechanism: the period sets Levy-per-second while leaving "cheap unit = 1 tick of
income" intact, so it is the only lever that changes how *rich* the match is without touching
any cost ratio. **This is how a 10-minute match avoids being twice as rich as a 5-minute one**:
total match Levy rises only ~14% (1,520 → 1,740) while duration doubles.

**The opening stipend rises from 20 to 30 Levy** (three Levy ticks), which is what makes the
Trap Pit affordable at t = 7 s and online at t = 15 s. Its rationale is unchanged from v1 —
there must be a real decision at second zero — and it does not violate "both players begin from
zero", which is about zero *progression*.

**The Trap Pit remains deliberately below the 8–15 tick band**, at 5 ticks of income and a 6 s
build, for exactly v1's reason and that reason survives: the first wave arrives before any
8–15-tick building could exist, so at the stated band defence-by-building would be structurally
impossible.

10 Hz survives untouched, which matters more than it sounds: **6,000 ticks still fits in three
base-36 characters**, so the 6-byte command atom and every wire size in A.11 are unaffected.
**The match got twice as long at zero protocol cost.**

**Confidence: medium-high on the structure, medium on the specific unit and building numbers
(simulation output, not playtest output).**

## Modifiers

### Q3 — Affinity resolution — **UNCHANGED in substance, wire representation DELETED**

**Decision: affinity is a VECTOR, not a label. Kill the label entirely.** Every modifier carries
exactly 3 affinity points, spent 3/0 (pure) or 2/1 (split across at most two types), so a
loadout always totals 15. Let `m` and `t` be the two players' 5-vectors over (Swarm, Boom,
Mystic, Fortress, Raider), and `W` the pentagon wheel matrix from `IDLE_BATTLE.md` §8
(`W[i][j] = +1` if `i` beats `j`, `−1` if it loses, `0` if same).

```
edge = ( SUM_i SUM_j  m[i] * t[j] * W[i][j] ) / 225      -- integer numerator, [-225, +225]
myDamageMultiplier = 1 + K * edge                        -- K = 0.06 (Q12)
```

Applied as a single final multiplier on damage dealt, outside every stacking clamp. **Never
shown as a word, anywhere, including post-match.**

**What changed: the affinity vector no longer crosses the wire.** Both clients hold both
loadouts, so both compute `m`, `t` and `edge` from the same table with the same code. Sending a
derived number was the one thing v1's own encoding rule 1 forbade, and v1 did it anyway because
it had no alternative. Five bytes saved and a whole class of "the two clients computed different
affinities" bug deleted.

**Why the mechanism survives.** Plurality forces a tie-break rule for the most common build
shape (2-2-1) and creates an invisible cliff the player cannot perceive. The bilinear form
dissolves the tie problem rather than solving it: there is no tie because there is no label.
"Turtle Bank" totals 8F/7B and receives a 53/47 profile — exactly the stated intent, with an
emergent texture nobody authored (its worst matchup is pure Boom, its own secondary). Because
the pentagon is symmetric, every row and column of `W` sums to zero, which makes three
properties free: a uniform 3-3-3-3-3 rainbow scores `edge = 0` against *every* opponent, so
neutral is a real reachable stance; mirrors resolve to exactly 0; and the opponent's edge is the
exact negative of yours, so one integer drives both sides. Everything is integer arithmetic.
**`K` is a compile-time constant covered by `rulesHash`, never a SavedVariable.**

**Confidence: high.**

### Q4 — Stacking rules — **CHANGED** (clamps re-derived; headcount cap REVERSED to a supply cap)

**Decision: additive within a channel, multiplicative across channels, hard clamp per channel,
one rounding point. Plus a per-lane SUPPLY cap of 200 Levy per side as a board constant.**

- **S1.** Every numeric effect declares exactly one channel from a fixed list: `unitCost`,
  `unitHP`, `unitDmg`, `dmgTaken`, `march`, `bldHP`, `bldCost`, `bldTime`, `levyTick`,
  `levyFlat`, `bankCap`, `dmgVsBuildings`, `production`, `repelRefund`, `slotCap`.
  *(`levyFlat`, `production`, `repelRefund` and `slotCap` are new in v2 — Ruling 5's cards
  needed them.)*
- **S2.** Within a channel all sources — modifiers, buildings, **and opponent debuffs, which are
  now ordinary local arithmetic** — sum as **integer percentage points**, then apply exactly
  once: `v = floor(base * (100 + clamp(sum, lo, hi)) / 100)`.
- **S3.** Across channels, effects multiply by construction because they touch different
  quantities. **No quantity is ever touched twice.**
- **S4 (revised).** Clamps:

  | Channel | v2 clamp | v1 clamp | Note |
  |---|---|---|---|
  | `unitCost` | **[−20, +40]** | [−45, +100] | absolute floor 1 Levy. **This is the important one.** |
  | `unitHP` | **[−40, +40]** | [−40, +80] | |
  | `unitDmg` | **[−35, +35]** | [−40, +60] | |
  | `dmgTaken` | **[−30, +30]** | [−40, +40] | |
  | `march` | [−40, +50] | [−40, +50] | unchanged |
  | `levyTick` | **[−30, +40]** | [−30, +60] | |
  | `levyFlat` | [−4, +12] | — | new; flat Levy per Levy tick |
  | `bldHP` | [−50, +80] | [−50, +80] | unchanged |
  | `bldCost` | [−50, +100] | [−50, +100] | unchanged |
  | `bldTime` | [−50, +100] | [−50, +100] | unchanged |
  | `bankCap` | [−50, +150] | [−50, +150] | unchanged |
  | `dmgVsBuildings` | [−50, +100] | [−50, +100] | unchanged |
  | `production` | [−50, +100] | — | new; functional-building output |
  | `repelRefund` | [0, +30] pp | — | new; added to the 15% baseline |
  | `slotCap` | [4, 5] integer | — | new; one source only (Q7) |

  The Q3 wheel multiplier applies **after and outside** every clamp.
- **S5.** `[Rule]` modifiers never stack numerically, they **arbitrate**. At most one "free
  deployment" effect and at most one "bypass" effect may fire per event, evaluated in ascending
  modifier-ID order. A non-firing effect does not consume its counter. *(This single rule is
  what keeps Endless Ranks and Conscription from multiplying.)*
- **S6.** **No effect may compound.** Anything described as compounding becomes a bounded linear
  ramp with an explicit per-tick step and a ceiling. No effect may multiply a quantity by a
  factor derived from that same quantity.
- **S7.** All rounding is `floor`, once per channel per evaluation. Never chain floors.
- **S8.** Kill attribution for non-unit damage (Trap Pit, Arrow Tower, Ward reflect, Miasma
  decay, Scorched Earth) credits the **owner**, so Blood Tithe and War Drums fire off them.
- **S9 — NEW.** **Tick-start snapshot.** All damage and all conditional predicates in a resolve
  tick read HP, position and unit counts from a snapshot taken at the *start* of that tick;
  results are applied afterwards. This is mandatory anyway for symmetric mutual kills, and it is
  what makes No Retreat, Tide of Bodies, Iron Discipline and Ward deterministic for free.
- **S10 — NEW.** **Ties break by lowest entity ID**, always, everywhere: simultaneous killing
  blows, Trap Pit target selection, Scorched Earth target selection, Ley Line move order.

**The headcount cap is REVERSED — this is the structural change in Q4.** v1's "per-lane unit cap
of 12 per side" is deleted and replaced by a **per-lane supply cap of 200 Levy per side,
denominated in Levy and charged at each unit's BASE cost, immune to every modifier.** A lane
holds 20 Spears, or 10 Bows, or 6 Horses, or any mix summing to 200.

Why the reversal, in two parts:

1. **A headcount cap inverts the entire cost structure.** At cap 12 the lane holds 12 Spears
   (120 Levy) against 12 Bows (240 Levy), so the expensive unit wins a fight it should lose and
   the cheap body becomes worthless — the exact opposite of Swarm's identity, which the cap was
   introduced to protect. It also strangles aggression: measured, aggro sits at 42.2% at supply
   120, 48.7% at 200, 49.1% at 300 (diminishing, so 200 is the knee).
2. **Charging supply at BASE cost is what preserves v1's actual intent.** A cost discount then
   converts into "refills the cap cheaper" (linear, bounded) rather than "more bodies in the
   cap" (quadratic, unbounded), which was v1 §0.2(b)'s whole point. Entity count stays bounded
   at 20 per lane per side for render and sim cost. Measured concurrent units per player: median
   peak 17, p90 47, max 57.

**And the fix for the quadratic problem moved.** v1 believed a structural cap on unit *stock*
was the answer to cost-reduction abuse. **It does not reach the problem at all** — directly
tested, charging lane supply at *discounted* rather than base cost changes a −20% build's win
rate from 82.1% to 82.7%, i.e. not at all. A cost discount improves **flow** (how fast you
refill and how much Levy is left for buildings), and no cap on stock touches flow. **The fix is
a tight clamp on the cost channel specifically**, which is why `unitCost` went from [−45, +100]
to [−20, +40].

**The exchange rate, which is the most transferable number in this document.** Measured as
win-rate delta against a fixed opponent pool from a 55.6% baseline:

| Channel | −5% | −10% | −15% | −20% | −40% | per stated point |
|---|---|---|---|---|---|---|
| `unitCost` | +11.1 | +13.3 | +25.1 | +26.5 | +37.9 | **≈ 2.2pp** |
| `unitDmg` | — | — | — | +20.9 (@+20) | +30.0 (@+40) | ≈ 1.05pp |
| `levyTick` | — | — | — | +20.8 (@+20) | +33.7 (@+40) | ≈ 1.04pp |
| `unitHP` | — | — | — | +16.9 (@+20) | +28.6 (@+40) | ≈ 0.85pp |

> **One point of `unitCost` is worth two points of any other channel.**

**Honest caveat, and it is a real one:** this measurement is one-sided — a modified player
against an unmodified pool — so the absolute deltas overstate what happens when both players
bring five cards that largely cancel. **The relative exchange rate is the trustworthy output and
is what the clamps are built on; treat the absolute numbers as a ranking, not a forecast.**

**A deliberate design property falls out of the tight cost clamp:** at −20, a *single* cost card
saturates the channel. Chaff alone (−20) leaves Breeding Pits (−10) and Late Levy (−20)
contributing nothing. **Stacking discounts is now a trap, not a strategy.** This is intended, it
is the structural replacement for v1's lane headcount cap, and it should be surfaced in the
loadout UI as a "channel saturated" warning rather than left as a hidden gotcha.

**Confidence: high on the rules and on the exchange rate; medium on the specific clamp values
and on 200 as the supply number.**

### Q5 — `[Rule]` modifier count — **REVERSED**

**Decision: 17 `[Rule]` of 40. All 40 modifiers ship in v1.0. Zero cards are cut for technical
reasons. The "zero Tier-3 modifiers, ever" rule is deleted.**

Distribution: Swarm 3, Fortress 2, Boom 3, Raider 4, Mystic 5.

**The audit.** Ruling 5 permits exactly two cut grounds. *Determinism hazard* means an effect
whose result depends on something the two sims can legitimately disagree about; every candidate
reduces to "read the tick-start snapshot" (S9) or "break ties by entity ID" (S10), both of which
are mandatory sim disciplines regardless of modifiers. *Genuinely unimplementable* means the
client cannot compute it — which, under full state sharing, is now the **empty set**, since
every client holds every input.

Card-by-card disposition of v1's ten cuts and five deferrals:

| Card | v1's stated reason | Verdict |
|---|---|---|
| **Ley Line** | Tier 3; continuous in-transit positions + targeting UI + arbitrary-moment input | **SHIPS.** Positions were always shared board state, even in v1. Making selection automatic removes the UI. The input fits the existing 6-byte atom. |
| **Scorched Earth** | Tier 3; variable-amount input, unbounded | **SHIPS.** Quantize to 25-Levy blocks in the atom's count field. Unbounded becomes bounded by arithmetic. |
| **Investment** | Tier 3; 45 s real-time timer straddles a pull | **SHIPS.** Rulings 2 and 3 kill the pull argument; the timer is in sim ticks, which do not advance while halted. |
| **Caravan** | Tier 3; new building (see Q8) | **SHIPS.** Q8 reversed. |
| **Endless Ranks** | ambiguous; largest contributor to the 10:1 stack; pro-loser engine | **SHIPS.** Ambiguity is a reword; the rest is balance. Bounded by a 3-charge ceiling and S5. |
| **Hex** | near-duplicate of Discord | **SHIPS.** Discord was itself blocked by the private-economy split; both are rescued by the same change. |
| **No Retreat** | HP-scaled damage is order-dependent within a tick | **SHIPS.** The only genuinely technical entry, and it dissolves under S9. |
| **Bulwark Line** | dead or dominant | **SHIPS.** Pure balance — and it was *also* architecturally impossible under v1's coefficient vector without anyone noticing. |
| **Watchfires** | needs a range model only Arrow Tower has | **SHIPS.** Factually wrong: Trap Pit, Watchtower and Arrow Tower all carry range fields. |
| **Rickety Scaffolds** | anti-identity for an archetype that must win in 90 seconds | **SHIPS.** Ruling 3 deletes the 90-second premise. |
| **Discord** | deferred to v2 pending an EFFECT wire class | **SHIPS in v1.0.** No wire class exists or is needed. |
| **Boomtown** | held to v1.1 by the starting-set rule | **SHIPS in v1.0.** |

**Discord is the single clearest demonstration that Ruling 1 pays for itself.** Under v1's split,
one player's card could not touch the other's costs, because the other's costs were simulated
only by their owner and never crossed the wire — so v1 invented an entire EFFECT wire class and
then deferred the class *and the card*. Under one unified sim it is a channel value written into
the opponent's stat block when their loadout is read at handshake: **zero new wire, zero new
state, zero new message type.**

**Why Tier 3 is un-banned.** v1's ban rested on four claims: new targeting UI, a new wire message
at an arbitrary moment, a variable payload rather than a compact ID, and a new failure mode when
that input is refused mid-encounter. Three of the four are now false — the three restored verbs
(`i`, `s`, `l`) are **values in the existing `K` field of the existing 6-byte atom**, quantized
into the existing `N` field, sent through the existing `C` batch on the existing bucket. The
fourth (refused mid-encounter) is answered by A.6: you cannot issue an order while halted,
because the sim is not advancing. **Tier 3 now costs a letter and a UI affordance, not a
protocol.** The tier taxonomy is still useful for estimating implementation cost — it is no
longer a gate.

**The seed.** With every card reworded to be deterministic, **nothing in the modifier pool
requires RNG.** The 4-char `seed` field stays in the handshake because it costs nothing and a
future system may want it, but v1.0 ships with **no shared PRNG at all**, which removes an
entire category of desync.

**I want to be explicit that 40/40 is a real balance liability, not a free win.** Shipping 24
rewordings and 17 `[Rule]` cards simultaneously means the first tuning pass has far more surface
than v1 planned for. The correct response is the structural guards (S4–S10) and the hot-fix
posture in G.4 — not cuts.

**Confidence: high on the audit; the balance consequence is Ruling 5's accepted risk (G.2).**

### Q6 — Pool size and drafting — **CHANGED** (pool size only)

**Decision: 40 at launch (8 per type). 10 unlocked at the start, all `[Stat]`. One card per
2 matches played, win or lose. Fixed designer-authored unlock order. Free choice, not drafted.**

Starting ten, two per type: **Breeding Pits + Scent Trails · Bastion Walls + Iron Discipline ·
Trade Routes + Master Masons · Sappers + War Drums · Ward + Miasma.**

Same ten as v1 — and worth noting that **Bastion Walls and Iron Discipline are two of the five
cards that were architecturally impossible under v1's coefficient vector** (Part D preamble).
v1 would have desynced on its own starter set at M7.

**Unlock order: the first four unlocks are `[Rule]` cards**, so a player meets a rule-changing
card by match 8. v1's all-`[Stat]` starting set is retained, but its justification narrows: v1
had both a pedagogical reason and an implementation-cost reason, and the second is gone.
**Only the complexity ramp justifies it now**, and it is still a good reason.

**Why the rest is unchanged.** Ten cards gives 252 loadouts while making it *impossible* to go
pure-anything on day one, so a new player's first builds are necessarily hybrids — which teaches
that mixing is normal. Never start with fewer than 5 (you could not fill a loadout) and never
with exactly 5 (your first loadout would be forced). **Unlocks must never be gated on winning**:
in a 20-person guild where everyone knows each other's record, a losing streak compounding into
a card deficit is corrosive. A **fixed order** means two guildmates who have played the same
number of matches own *exactly the same collection*, so "he has better cards" is structurally
impossible — the strongest available defence of the "both players always start equal" promise.
Free choice over drafting because: the loadout is set during a lull and a draft is another
interaction plus 3–5 more messages; a real draft must be synchronised, an entire extra protocol;
the pillar "your identity emerges from what you gravitate toward" requires **repeated deliberate
choice**; and the design already presumes saved loadouts. Hold **Blind Draft** as a named v2
queue mode.

**Wire cost is a non-issue** — 40 cards fit in 6 bits, and the handshake spends 2 base-36
characters per card anyway (1,295 addressable), so pool size must never be influenced by message
size. But `rulesHash` is now mandatory and much stricter than v1's `tableHash` (A.11.1).

**Confidence: high.**

### Q7 — Cap inviolability (Boomtown) — **CHANGED** (ships in v1.0) — **[OWNER]** (mild)

**Decision: the cap is soft. It is a number a modifier may raise — by at most +1, from at most
one source, clamped to `[4, 5]` — and Boomtown is the only card that does it. Boomtown converts
`[Rule]` → `[Stat]`. It ships in v1.0.**

**Why it moved into v1.0.** v1 held it to v1.1 for the starting-set rule, not for risk. Ruling 5
settles that. It also gets **strictly better under Ruling 1**: the receiver now knows you hold
Boomtown and can validate the fifth build, so an out-of-cap build is a **detectable protocol
error** instead of something v1 had to silently trust.

**Why +1 and never +2.** At 5 of 6 the opening guess still exists (one slot is still empty); at
6 of 6 it does not, and the opening mind game the design rests on disappears for one player.
Marked **[OWNER]** because "is the cap part of the game's identity or just a number" is a taste
call — but the recommendation is unambiguous: soft cap, +1 maximum, forever.

**Confidence: high on the mechanism, medium on whether the owner wants the cap breakable.**

### Q8 — Building unlocks (Caravan) — **REVERSED**

**Decision: YES. A modifier may unlock a building. Caravan ships in v1.0 as the only one.**

**Why the reversal.** v1's answer rested on two arms and one is dead:

- *Arm 1 (dead): "forced by the shared-board model."* Under v1 §0.2(a), every client had to
  simulate and render a building it might never be able to build, so the gate bought nothing but
  denying one player an option. That argument was always weak — the code cost is identical
  either way — and Ruling 1 removes even the appearance of force.
- *Arm 2 (alive but no longer specific): "an opponent with Caravan is playing a game with an
  extra verb."* This is true, and it is a real cost. But **Ruling 5 already accepted verb-
  granting cards**: Ley Line, Scorched Earth and Investment all grant new verbs and all ship.
  Once three cards may add a verb, objecting to a fourth on principle is not a technical ground,
  and Ruling 5 permits no other kind.

**The honest position: Caravan ships because Ruling 5 leaves no ground to cut it, not because
arm 2 was wrong.** If in playtest "the option space differs between players" reads badly, the
fallback is v1's own suggestion — reprice Caravan as a shared-catalogue building anyone may
build, and convert the card into a discount on it. That fallback is one table edit and no code.

**Confidence: medium.** This is the one reversal where the losing argument still has force.

## Match systems

### Q9a — Fog of war: the disclosure model — **CHANGED** (message policy → render policy)

**Decision: fog is a pure render filter. Nothing is withheld from the wire. Everything is
withheld from the screen.**

`IBFog.lua` exports `Fog.Visible(entity) -> bool`; the renderer is its only caller (A.3).
Default vision, from your point of view, no modifiers — **unchanged from v1 as a player
experience, entirely different as an implementation**:

| Object | What you see |
|---|---|
| Your own board | Everything, exact |
| Enemy keep | Position and exact HP, always, from tick 0 |
| Enemy units in **your** half (`x < 1000`) | Full: type, count, HP, position |
| Enemy units in **their** half | Nothing individual. One per-lane **muster bar**, 3 buckets (clear / pressure / heavy), driven by total marching HP in that lane |
| Enemy buildings, not yet disclosed | Nothing — not even that the slot is occupied |
| Enemy buildings, disclosed | Slot, identity, exact HP, permanently |
| Enemy Levy / bank / income / spend | Not rendered |
| Enemy loadout | Not rendered |

Building disclosure triggers, any one, permanent for the match: contact (damage exchanged with
anything of yours); it fires on you; it is destroyed; Divination; a Shrine reveal pulse
(occupancy only). Triggers 4 and 5 are suppressed by Veil; buildings under construction are
never revealed by 4 or 5.

**What is deleted, and this is the part to read.** v1's mechanism was *absence* — a `BUILD`
command was **withheld from the wire** until the opponent first deployed into that lane, on the
theory that only an absence survives a modified client. All of that is gone: deferred building
disclosure, the `deferrable` boolean, the three airtightness conditions (own-half confinement,
the midline damage-range clamp, the unconditional empty batch), and the four disclosure classes.
**All builds go on the wire at issue time.**

**Say the consequence plainly rather than burying it: default fog is now cooperative.** The
muster bar, undisclosed buildings, the enemy's Levy and the enemy's loadout are all present on
your client and honoured only by an unmodified addon. That is exactly what Ruling 1 accepts, and
it is what the master doc's Part III said in the first place ("simulate full state on both ends
and render only part"). v1 escaped that only to defend the loadout.

**Determinism guard.** v1's guard was the `View*` naming convention and a one-way file
dependency. v2's is stronger and is the four greps in A.5 — in particular, grep 2 (the sim
cannot see which side is "me") structurally prevents the whole bug class rather than policing
one accessor.

**Confidence: high.** The medium-confidence caveat v1 attached here — "deferred disclosure may
not survive contact with the implementation" — is retired along with the mechanism.

### Q9b — How the Mystic and defensive information modifiers layer on — **CHANGED** (ships in v1.0; justification amended)

**Decision: two independent axes, so no modifier does two jobs.** *Unit vision* is **temporal**
— how early you see a wave. *Structure vision* is **spatial** — what is in their slots. All of
this **ships in v1.0** (v1 held it all to v1.1+).

| Source | Effect | Self-announcing? |
|---|---|---|
| **Watchtower** (front) | In its own lane only: enemy units fully visible from the midline out to their front slot. Dies with the building | Yes, on completion |
| **Shrine** — reveal pulse (back) | Every 200 sim ticks for 30 ticks: all enemy units in all lanes at full detail, plus enemy building **occupancy only** | Yes — "you were scanned" |
| **Divination** (Mystic `[Rule]`) | All **completed** enemy buildings: slot + identity, continuously, including rebuilds. **Never HP.** Never buildings under construction | Yes, at tick 0, persistent "you are being scried" mark |
| **Omen** (Mystic `[Rule]`) | Every enemy deploy order surfaced the moment its atom arrives — one order-delay before it takes the field: **lane + count only, never unit type** | Yes, at tick 0, persistent mark |
| **Veil** (Mystic `[Rule]`) | Suppresses display of your buildings on the enemy client from every source except contact reveal and destruction | **No** |
| **Watchfires** (Fortress `[Stat]`) | Your defensive buildings gain +50% damage range and reveal their lane out to that range | Yes, on completion |
| Hex, Discord, Miasma, Ward | No vision effect. Consequences felt, names never seen | n/a |

**One line teaches the system: information modifiers announce themselves the first time they
act. Seeing costs being seen.** Veil is the sole exception. **Conflict resolution is one rule,
not a matrix: Veil beats every reveal, absolutely.** A diviner facing Veil gets an empty scry
and learns "I am against Veil" — inference, not sight, and precisely on-theme. Veil's scope is
**buildings only**; it never conceals units.

**Two balance amendments, both retained from v1.** (1) Omen reveals **lane and count, not unit
type** — as written it had no counter anywhere in the pool and would erase the Spear/Horse/Bow
read. (2) Divination **excludes buildings under construction**, preserving the "is that wall up
yet?" tension.

**The amendment Ruling 1 forces, and it must be stated rather than glossed.** v1 argued that
self-announcement was *implementation-honest*: "Divination literally **is** a request for the
opponent to send more, so announcing is not a flourish, it is what the implementation does."
**That is no longer true. Nothing is requested.** Veil is no longer implemented as silence; it
is a render suppression on the *opponent's* client, honoured only by an unmodified addon.
Self-announcement is now a **pure balance choice** — and it is a good one, because it is the
only counterplay Mystic's information edge has. Ship it unchanged in behaviour, change the
reasoning in the code comments.

**Post-match recap: reveal the opponent's final board — buildings, positions, what killed what.
Do not reveal their loadout; list the *effects* you encountered instead** ("their Spears had
~40% more HP", "their units marched faster after a kill"). Under v1 this was technically forced.
**Under v2 it is a deliberate product choice**, because the loadout *is* on your client. It is
still the right one: if loadouts were readable post-match the fog would erode inside a small
guild within a week.

**Confidence: high.**

### Q10 — Timeout resolution — **UNCHANGED** (thresholds re-anchored; now hashed)

**Decision: on the clock, the player who came closer to winning wins. There is no defensive
victory.** At the hard cap, evaluate in order; first non-tie decides.

1. **Enemy keep HP removed** — cumulative, not current, so repairs cannot erase it.
2. **Enemy building slots destroyed** — cumulative, front and back count 1 each.
3. **Deepest penetration achieved**, summed over three lanes, using *greatest depth ever held
   for ≥ 50 sim ticks (5 s)*, never a final-tick snapshot. Per lane: 0 = never reached their
   front slot; 1 = held `x ≥ 1300`; 2 = held `x ≥ 1500`; 3 = held `x ≥ 1700`. Max 9.
4. **Your own keep HP remaining.**
5. **Draw.** A draw pays exactly what a loss pays.

**Unit kills are deliberately never a tier. That is the pure-turtle exploit and it must not
exist anywhere in the ladder.**

**Show the score from the 20% mark (t = 120 s)** — a live "ahead / behind / level on the clock"
indicator, re-anchored from v1's fixed 60 s so it means the same thing at any clock length. No
overtime, no sudden-death ramp.

**What changed.** Two things, both from Ruling 1. First, **every ladder counter is now inside
the hashed state.** v1 could not hash the ladder, which means **v1 could not detect a
disagreement about who won** — the two clients could each declare themselves the winner and
neither would ever know. That is arguably the single worst undetected failure v1 contained.
Second, the ladder now fires 15% of the time rather than 42%, because decisiveness rose from 58%
to 85% (C.6) — and **every tier fires**: of matches reaching the clock, tier 1 resolves 54%,
tier 2 25%, tier 3 17%, draw 4%. Nothing is dead code.

**Why the structure survives.** Every scheme measuring anything other than progress toward the
win condition is gameable by a player who never attacks. Anchoring the ladder to the stated win
condition and ordering tiers by decreasing proximity to it makes the exploit *structurally
unreachable*. Can a turtle reach T1? It must reach the keep. T2? It must destroy a building, and
Arrow Tower, Trap Pit, Counterwall and Ward all kill *units*. T3? It needs units past the enemy
front slot. **Every tier above 4 requires offence; there is no path.** The constraint this places
on the economy — a Fortress that repels the first waves must have a real conversion window,
funded by repel refunds and freed slots — is unchanged and is now also funded by Spoils.

**Confidence: high.**

### Q11 — Tick rate and match length — **CHANGED** (Levy tick and match clock)

**Decision: four separate clocks, all integer multiples of one counter. Do not conflate them.**

| Clock | v2 | v1 | What resolves on it |
|---|---|---|---|
| **Sim tick** | **100 ms (10 Hz)**, integer counter from 0 | same | Movement, command execution, event ordering |
| **Resolve tick** | every **5th** sim tick (0.5 s) | same | Combat, build progress, ability triggers |
| **Levy tick** | every **35th** sim tick (**3.5 s**) | 20th (2.0 s) | Income, bank cap |
| **Order delay** | **20 sim ticks (2.0 s)** | same | Orders at tick `t` execute no earlier than `t + 20` |
| **Match clock** | **6,000 sim ticks (600 s)** of ACTIVE sim | 3,000 (300 s) | Paused time does not advance the counter |

The sim is driven by **one `OnUpdate` accumulator**
(`acc = acc + elapsed; while acc >= 0.1 do step() end`), **never** by `C_Timer.NewTicker` —
`C_Timer` is frame-quantised, drifts, and a loading screen swallows an unbounded number of
firings. Per-frame catch-up is clamped to 25 ticks. The renderer interpolates positions between
sim ticks. Ship exactly **one match length** in v1.0; the `matchTicks` field exists on the wire
so v2 can add presets without a protocol bump, but do not turn it on.

**Why 10 Hz survives untouched.** 10 Hz gives 6,000 ticks for a full match, smooth-enough
marching for an explicitly no-micro idle game, and is trivially cheap (~50 entities × 10 Hz ≈
10k Lua ops/sec). It lets the tick index fit in **3 base-36 characters** (46,655 ticks = 77
minutes of active sim), which is what makes the 6-byte command atom possible — **and 6,000 still
fits, so doubling the match cost zero protocol bytes.**

**Why the Levy tick moved to 3.5 s.** See Q1/Q2. It is the master balance lever and it is the
only lever that changes match richness without touching a cost ratio.

**Why 2.0 s of order delay, surfaced as a game mechanic.** 2 seconds is 6–20× typical
addon-message latency, which makes late arrival rare rather than routine. Because the design's
rhythm is "set your moves, let them resolve", 2 s reads as flavour — **"orders take time to
reach the field", mustering time.** Units spend the window visible, inert and untargetable.
Effective delay at send time is `E = myTick + 20 + max(0, opponentAheadBy) + ceil(queueDelay*10)`,
clamped to 40 ticks; exceeding the clamp is halt reason `D`. The clamp exists because the
**local send bucket, not the network, is the real latency source** when the addon is busy.

**Timed effects across a pause — one rule, no table of special cases.** **Every timed effect in
the game is denominated in SIM TICKS, never in seconds and never in wall clock, and the sim tick
counter does not advance while halted.** A 10-minute pause is therefore invisible: no effect
matures, no window expires, no threshold arrives, no income accrues, no build progresses.
**Nothing in the sim may read `GetTime()`, the client clock, or a date** — this is grep 3's
sibling and should be checked the same way. Any effect's remaining tick count is part of the
hashed state and is restored exactly on resume rather than re-derived. Concretely: War Drums is
a 200-tick window; Investment is a 450-tick countdown; Hex is a fixed 400/200-tick schedule from
tick 0; Late Levy keys off tick 3,000; Golden Age keys off cumulative Levy, a sim quantity
needing no conversion at all.

**And a general rule for the pool, learned the hard way here: every time gate is expressed as a
FRACTION of the match clock, never as an absolute second count.** Late Levy's "two-minute mark"
was 40% of a 300 s match and would be 20% of a 600 s one — the same words meaning a different
card. Expressed as a fraction it survives the next length change too.

**Confidence: high on the clock structure; the match length is closed by Ruling 4.**

### Q12 — Type balance tuning — **UNCHANGED** — **[OWNER]** (taste)

**Decision: `K = 0.06`, i.e. the wheel is worth ±6% damage dealt at maximum focus, applied as a
single final multiplier outside every clamp. Recommended band 0.04–0.08.**

**Why, and why it is the owner's call.** How quiet a "quiet global modifier" should be is a feel
judgement. What analysis can say is where the boundaries are: below ~0.04 the wheel disappears
under the variance of which lane you guessed right, and §8's fiction stops being legible; above
~0.10 it starts to decide even matchups, and since **neither player knows their own label or
their opponent's**, a decisive wheel is an invisible coin-flip — the worst possible property for
a system nobody can see. Two implementation constraints are not negotiable at any value: `K` is
a **compile-time constant covered by `rulesHash`, never a SavedVariable**, and it applies
**after and outside** the Q4 clamps.

**Scale check, updated and now much sharper.** v1 compared the wheel to a 10:1 stacking abuse.
v2 can be precise: a single `unitCost` card at −20 is worth ~+26pp of win rate against a fixed
pool, and the wheel at maximum focus is ±6% damage. **The wheel is roughly an order of magnitude
below a single strong card**, which is the correct relationship between a global lean and a
build decision — and it is a good argument for *not* raising `K` even if the wheel feels
invisible early.

**Confidence: high on the mechanism and the band, medium on 0.06. Play it and move it.**

## Multiplayer

### Q13 — Players per match — **CONFIRMED, NEW REASONING**

**Decision: 1v1 only. A v3-at-earliest item.**

**What changed.** v1's headline reason was that "1v1 is what makes the board/economy split
clean." **That reason is deleted with the split.** The answer survives on the other three, which
were always the stronger ones:

1. Message volume scales with participants against a bucket shared with every other module.
2. The unified sim's entity count and hash surface double or triple.
3. **Teams introduce a question with no answer that is both fair and simple: what happens when
   one member of a team is muted and the other is not?** Under Ruling 2 this is *worse* than it
   looked in v1 — the symmetric-pause fast path exists precisely because two players in one
   group mute together, and a 2v2 across two groups has no symmetric case at all. Every pause
   would be asymmetric.
4. FFA additionally requires a lane topology the map does not have.

`CONCURRENCY.md`'s seat model is per-module and per-person and already supports exactly what is
needed: one match at a time per person, unlimited concurrent matches around them.

**Confidence: high.**

### Q14 — Matchmaking specifics — **CHANGED** (all three scopes ship)

**Decision: matchmaking IS the shipped `SCOPE.md` + `CONCURRENCY.md` session model. Write no new
matchmaking. Delete the "available to fight" heartbeat from §3 of the design doc.**

1. Player opens the battle dialog, picks a loadout and a **scope** via `PG.UI.ScopePicker`.
   **`PG.IB.SCOPES = { group = true, guild = true, public = true }` — all three ship in v1.0
   (Ruling 6).**
2. **Pre-flight gate**: refuse if `PG.Comm.Locked()` is already true; refuse if
   `select(2, IsInInstance())` is `"pvp"` or `"arena"`; refuse if
   `C_ChallengeMode.IsChallengeModeActive()` (existence-guarded and `pcall`ed — absent means
   allow). Allow `"raid"` and `"party"` with the banner *"Boss pulls will pause the battle."*
3. `hostOpen` mints a token via `PG.NextToken()` and broadcasts `IB|OPEN|<token>|…|<scope>`.
   The host takes the seat (`PG.Session.Claim`). Invariant I4 applies: hosting is never blocked
   by another module.
4. Discovery is unchanged from `SCOPE.md` §6.3 — group scope raises a `PG.UI.Ask` popup, guild
   scope raises one within the invite budget (1/sender/60 s, 3 per 5 min), public scope only
   ever lands in the launcher's *Open games* list and constructs no state until an explicit
   **Join** click.
5. The first accepter whispers `IB|JOIN|<token>`. **First JOIN wins**; every later one gets a
   polite refusal whisper. This is the only new rule in the whole flow, and it exists because
   the battle is 1v1 while the shipped games are N-player.
6. Host whispers `IB|S|<token>|<payload>` (A.11.1); the client replies with its own `IB|S`.
   Both validate `proto` and `rulesHash` and refuse politely on mismatch, **with two distinct
   refusal strings**, reusing the pattern at `Comm.lua:818`.
7. **Both set T0 locally the moment they hold both loadouts.** No synchronisation round trip.
   Match traffic is **all whispers** — `SCOPE.md` §2.3 already requires private 1:1 traffic to
   use `WHISPER` in every scope. Only `OPEN` is ever broadcast.

**What public scope costs, stated up front.** A stranger on your realm is by definition in
different content, so **the asymmetric-pause path (A.8) is the normal path in public scope, not
the exception.** Two consequences: the 10-second silence detector and the "they may be in a boss
fight" copy are load-bearing there rather than decorative; and the void rate in public scope
will be materially higher than in guild scope. Both are acceptable — a void is cheap by
construction (§0.2) — but public scope should be *shipped and watched*, and it is the one scope
where an abandon-rate metric would actually be worth collecting locally.

**Why the heartbeat must go** (unchanged from v1): a standing "available to fight" broadcast is
a per-player periodic message on a channel shared by up to two hundred guildmates against a
60/min prefix budget. Twenty opted-in players at one heartbeat per 30 s is 40 messages/min of
pure advertising before anyone plays anything — visible to, and starving, Loot Goblins. The
shipped invitation model already solves discovery with **one message per attempt** and comes
with the invite budget, the DND gate, the ignore filter, the launcher list, the trust predicate
and the supersession rule already written and shipped.

**Confidence: high.**

### Q15 — Disconnect and grief handling — **CHANGED** (budgets widened; reconnect becomes possible)

**Decision: one terminal state — VOID. There is no forfeit win, ever.**

| Situation | Detection | Result |
|---|---|---|
| Both players muted (same group pulls) | local `PG.Safety` event on both | **Symmetric halt.** A non-event (A.7) |
| Opponent muted, `X` landed | inbound `X` | **Halt** on receipt (~0.2 s one-sided) |
| Opponent muted, surprise | **10 s** of total inbound silence | **Provisional halt**, reversible (A.8) |
| Opponent zoning / loading | local `PLAYER_ENTERING_WORLD`, or the 10 s detector | **Halt**, reason `Z` |
| Pause budget exceeded | **20 min single, 40 min total, 90 min wall clock** *(v1: 12 / 20 / 45)* | **Void** |
| Opponent silent with no halt context | **900 s** *(v1: 300 s)* | **Void** |
| Opponent logs out or `/reload`s | the 900 s path | **Void** |
| Local `/reload` or logout mid-match | own live state is gone | **Void in v1.0; recoverable from v1.1** — see below |
| Unrepairable desync | state hash mismatch surviving full-log replay | **Void**, both sides, with a debug dump behind `/pg debug` |
| Either player cancels | explicit `V` message | **Void** |

**Why the budgets widened: Ruling 3.** The match is no longer racing a downtime window, so
patience is cheap. And v1's 300-second silence timeout was a latent bug regardless of ruling: a
mythic progression pull plus a wipe and a run-back comfortably exceeds 300 s, so **v1 would have
voided matches mid-encounter — in the exact scenario the design exists to serve.** Reuse
`SCOPE.md`'s *shape* (`HB_QUIET_WIDE` → soft warning, `HB_GIVEUP_WIDE` → give up), not its
300-second constant.

**Reconnect — newly possible, and it is Ruling 1's most underrated payoff.** A whole match is
`(rulesHash, seed, loadoutA, loadoutB, commandLog)` ≈ 800 bytes. **From v1.0, write that
descriptor to SavedVariables on every command batch.** It costs ~800 bytes and it is the
bug-report artifact anyway (0.1 item 3), so the write is free either way. **Reconnect itself
ships in v1.1**: on reload, if the descriptor is fresh and the peer still answers, rebuild the
initial state, replay the log to the peer's current tick, and rejoin. Under v1 this was
impossible in principle, because reconstructing the initial state requires both loadouts and one
of them was never on your machine.

**A void means:** no winner, no loser, no rating, no ledger row, and unlock credit paid pro-rata.
Count credits in halves — a completed match is 2 credits, a void is 1, an unlock costs 4. Record
abandonment locally for the player's own information only; **never surface another player's
abandon count anywhere.**

**Why there is no forfeit.** Over a lossy channel with no server, "quit" and "muted" are
literally indistinguishable — the observable evidence is identical. Any forfeit rule therefore
punishes a real player for their raid pulling a boss some fraction of the time, in a game
explicitly designed to be played in a raid. **Grief is handled by making griefing pointless
rather than by detecting it**: there is nothing to win by quitting, since a void pays the quitter
less than finishing would, and nothing to take from the victim, since a void costs them almost
nothing.

**Confidence: high.**

## Presentation

### Q16 — Working title and theme — **UNCHANGED** — **[OWNER]** (pure taste)

**Entirely the owner's call; nothing mechanical depends on it.** The one engineering
requirement: **the wire module code is `IB` and stays `IB` forever, independent of the theme.**
A theme-free wire identifier means the game can be renamed and re-skinned at any point without
touching the protocol, bumping a version, or breaking compatibility. Every user-visible string
lives in the existing `PG.L` table.

**Recommendation: "Marches."** A *march* is a contested border territory and it is what the
units do; it fits the existing Levy/keep/palisade vocabulary and is short enough for a launcher
row. Runners-up: "The Levy", "Border Keep", "Two Keeps". `Theme.lua` already provides the themed
window, the animated reveal stage and the podium, so a themed post-match recap is close to free.

**Confidence: n/a — owner's call.**

---

# Part C — Numbers, tuning pass two

**Everything in this part is provisional.** It is output from a purpose-built Python match
simulator, not from playtesting. It is internally consistent and an implementer can code against
it tomorrow.

## C.0 How these numbers were produced

The simulator runs the real board: 3 lanes, 1-D integer positions, march, auto-engage, the
counter triangle, multi-target attacks, building construction, traps, income, bank cap, order
delay, per-lane supply, the keep, and the full Q10 tiebreak ladder. Sixteen scripted policies
across four families (pure aggression, pure economy, pure defence, mixed) play a full
round-robin — **1,440 matches per configuration in the final pass, roughly 35,000 matches across
the tuning sweeps.** Every number below was measured, not asserted; where a value is stated, so
is what moving it did.

Two structural defects in v1 were found by the simulator that no amount of arithmetic would have
surfaced: the lane headcount cap inverting the cost structure (Q4), and Bow's multi-target being
load-bearing rather than decorative (C.3). It also independently reproduced v1's own finding
that keep HP is a pure length dial — a genuine cross-validation of two different models.

## C.1 Clocks and space

| Constant | Value | Change from v1 |
|---|---|---|
| Sim tick | 100 ms | — |
| Resolve tick | every 5 sim ticks (0.5 s) | — |
| **Levy tick** | **every 35 sim ticks (3.5 s)** | **was 20 (2.0 s)** |
| Order delay `D_base` | 20 sim ticks (2.0 s); effective-delay clamp 40 ticks | — |
| **Match clock** | **6,000 sim ticks (600 s)** of active sim | **was 3,000 (300 s)** |
| Snapshot epoch | 60 sim ticks (6 s); keep last 5 → 30 s of rollback depth | — |
| Heartbeat | 60 sim ticks (6 s) | — |
| Lane length | 2,000 units, integer positions | — |
| Own keep / back slot / front slot | 0 / 300 / 700 | — |
| Midline | 1,000 | — |
| Enemy front slot / back slot / keep | 1,300 / 1,700 / 2,000 | — |
| Lanes | 3 | — |
| Building slots | 6 (front + back × 3), **cap 4 occupied** | — |
| **Per-lane supply cap** | **200 Levy per side, charged at BASE cost** | **replaces headcount 12** |

## C.2 Economy

| Constant | Value | Change from v1 |
|---|---|---|
| **Opening stipend** | **30 Levy** (3 Levy ticks) | was 20 |
| Base income | **10 Levy per Levy tick, flat, all match** = 2.857 Levy/s | rate was 5.0 Levy/s |
| Levy ticks per match | 171 | was 150 |
| **Total base Levy in a full match** | **1,740** | was ~1,520 — **+14% for 2× the duration** |
| **Bank cap** | **200** (Granary → 350) | was 150 |
| Repel refund | **15%** of an enemy unit's build cost when it dies in your own half | — |
| **Spoils** | **75%** of an enemy building's cost to whoever razes it | **NEW** |
| Hard coupling | `bankCap >= dearestBuilding + 2 Levy ticks` = 140 + 20 = 160 ≤ 200 ✓ | rule survives |

**Bank cap is no longer an aggression dial.** Measured across 160 / 200 / 300 / 450, aggression
moves 47.6% → 48.7% → 49.4% → 49.4% — a **1.8pp total swing**. v1's claim that it is "the
strongest aggression dial in the game" (37% at cap 70, 87% at cap 150) was an artefact of the
2-second Levy tick: at 5 Levy/s a hoard could be converted into a battlefield stack fast enough
to matter. At 2.857 Levy/s with a 200-supply lane and a 2 s order delay, **a hoard cannot be
converted quickly enough to buy tempo**, so the cap stops being a strategic dial and becomes
what it should be — a cap on waste. Anyone tuning aggression by reaching for the bank cap will
find it does nothing and conclude the wrong thing.

## C.3 Units

HP is on a scale where damage lands every **resolve tick (0.5 s)**. Every value is an integer.

| Unit | Cost | HP | Dmg/resolve | Targets | Dmg range | March/sim tick | Lane crossing |
|---|---|---|---|---|---|---|---|
| **Spear** | 10 | 420 | 16 | 1 | 60 | 10 | 200 ticks (20.0 s) |
| **Bow** | 20 | 360 | 12 **per target** | **3** | 320 | 7 | 286 ticks (28.6 s) |
| **Horse** | 30 | 1,020 | 44 | 1 | 60 | 20 | 100 ticks (10.0 s) |

- **Counter multiplier: ×1.5 into your prey only** (Spear→Horse, Horse→Bow, Bow→Spear). ×1.0
  everywhere else. **No penalty term.** 1.15 and 1.25 were both tested and both blur the
  triangle; ×1.5 is v1's value, restored after testing.
- **All units deal ×0.5 damage to every structure**, including the keep. Sappers doubles this to
  ×1.0.
- **Triangle verified at equal Levy at three scales (80 / 160 / 240 Levy):** the prey is wiped to
  zero in every direction and the winner retains 39–78%.

**Bow's multi-target is structural, not a nicety.** `IDLE_BATTLE.md` §5 gives Bow the role
"strong vs. massed cheap units", and v1's B.3 table lists "Targets 3" — but nothing else in v1
depended on it. **With single-target Bow that role does not exist at any stat line**; it could
not be constructed. With 3 targets the triangle closes cleanly. This is the highest-value
correction in the unit table.

**Horse must be explicitly cost-INEFFICIENT in a stand-up fight to pay for its speed.** Tuning
unit stats against isolated equal-Levy duels over-rates Horse badly, because a duel starts both
stacks on the field and therefore prices Horse's 2× speed at zero — tuned that way, Horse reached
**94%** in the full tournament. The shipped numbers give HP-per-Levy of **42 / 18 / 34** and
damage-per-Levy of **1.6 / 1.8 / 1.47** for Spear / Bow / Horse, so **Spear is the best body per
Levy, as a cheap body should be.**

*Editorial note on lane length.* The economy simulator reported crossing times of 24.0 / 34.3 /
12.0 s, which imply a 2,400-unit path. The shipped geometry is the 2,000-unit lane from v1,
which every position-scoped rule depends on (`x < 1000` for Iron Discipline and Miasma; 1300 /
1500 / 1700 for the Q10 ladder; the Arrow Tower range). **March speeds are identical to v1 —
10 / 7 / 20 units per sim tick — so only the reported crossing distance differed, and every
measured result is unaffected.** The table above is normalised to the 2,000 lane.

## C.4 Buildings

| Building | Cost | HP | Build time | Effect |
|---|---|---|---|---|
| **Trap Pit** | 50 | 1,000 | 60 ticks (6 s) | One-shot **3,600** burst, **max 1,100 per target, up to 6 targets, no overkill**, trigger radius 120 |
| **Watchtower** | 70 | 1,250 | 90 ticks (9 s) | 38 dmg/resolve, damage range 300, reveals lane (vision range 600) |
| **Palisade** | 90 | 8,800 | 120 ticks (12 s) | Blocks advance, no offence |
| **Granary** | 100 | 1,200 | 120 ticks (12 s) | +1 Levy/Levy tick, bank cap +150 |
| **Arrow Tower** | 110 | 1,900 | 120 ticks (12 s) | 112 dmg/resolve, damage range 320 |
| **Redoubt** | 110 | 2,250 | 150 ticks (15 s) | Friendly units in this lane take −30% (own half only) |
| **Smithy** | 110 | 1,200 | 150 ticks (15 s) | +25% friendly damage in lane |
| **Fletcher** | 110 | 1,200 | 150 ticks (15 s) | Bow −30% cost in lane, +6 range |
| **Levy Post** | 120 | 1,400 | 150 ticks (15 s) | **+2 Levy/Levy tick** *(was +3)* |
| **Stables** | 120 | 1,200 | 150 ticks (15 s) | +50% march in lane, Horse −30% there |
| **Shrine** | 140 | 1,200 | 180 ticks (18 s) | Ward charge / reveal pulse |
| **Caravan** *(Boom card only)* | 120 | 400 | 120 ticks (12 s) | **+4 Levy/Levy tick.** Back slot, counts against the normal cap |

In ticks of income: **5, 7, 9, 10, 11, 11, 11, 11, 12, 12, 14** — everything except Trap Pit
inside the design's 8–15 band, with Trap Pit deliberately below it (Q2).

Defensive HP and damage are v1's shape scaled by a measured **1.25×**: sweeping defensive
strength at 1.0 / 1.4 / 1.8 moved pure defence 44.1% → 57.2% → 59.1%, so 1.25 lands it at 52–55%.

**Trap Pit had a real defect worth flagging to the implementer: damage must be capped at each
target's remaining HP before moving to the next target.** Otherwise a burst designed to punish
massed cheap units is mostly wasted as overkill on the first three bodies. Fixing this alone
materially changed defensive viability.

**Levy Post ROI, and the greed deadline.** +2 Levy per 3.5 s tick is +20% of base income.
Earliest affordable at t = 31.5 s, online at ≈ 48 s, breaks even at ≈ 258 s, nets ≈ +200 Levy by
the clock. **A Levy Post purchased after ≈ t = 370 s never pays for itself.** A committed economy
build (2 Levy Posts + Granary, all online by ≈ 90 s) grows the match pot from 1,740 to ≈ 2,470
Levy, about +42%.

Yield had to come down from v1's +3: swept at 1 / 2 / 3 it moves economy 53.9% → 61.4% → 65.8%,
so +3 is simply too strong once the payback horizon doubles. **Yield 1 balances the game by
making the building pointless (360 s payback), which violates "pure economy must have a live
path" — so 2 is the only value that is both balanced and worth buying.** The 370 s deadline is
the sentence that makes greed a gamble rather than a default, and it is the direct 10-minute
analogue of v1's "112 seconds" line. It is the number to quote to a player: **past the two-thirds
mark, stop building economy and spend.**

## C.5 The keep

| Constant | Value |
|---|---|
| **Keep HP** | **48,000** (96,000 raw, since ×0.5 applies) |
| Earliest possible keep kill (3-Horse opening) | affordable t = 24.5 s, deploys 26.5 s, arrives 36.5 s, razes at ≈ **400 s** |
| A full 200-supply lane of Horses (6) razing | ≈ 182 s of chewing |
| A full 200-supply lane of Spears (20) razing | ≈ 150 s of chewing |

**Keep HP is a pure length dial — third independent measurement, and the cleanest result in the
exercise.** Swept 14,000 / 20,000 / 26,000 / 32,000 / 40,000 / 48,000 / 56,000: the median moves
338 s → 418 s and p10 moves 135 s → 249 s **while every family win rate stays identical to the
first decimal (48.9 / 51.4 / 54.8 / 45.6 across the entire range).**

48,000 was chosen to pull the short tail into Ruling 4's band: at 32,000 only 65% of matches land
in 5–10 minutes with p10 at 196 s; at 48,000 it is 77% with p10 at 233 s.

> **If matches drag in playtest, cut keep HP. Never cut the clock.**

**The look-away guarantee, restated for the new scale.** No opening can end a match before
roughly **six minutes**, and an unwatched lane gives you minutes rather than seconds to answer
it. This is a far larger margin than v1's ~63 s and is the direct consequence of Ruling 4 — it is
also what makes the game genuinely playable while doing something else, which is Ruling 3's whole
point.

## C.6 Measured outcomes at these numbers

1,440 matches, 16 policies, full round-robin.

| Metric | v2 | v1 |
|---|---|---|
| Match length p10 / p25 / median / p75 / p90 | 233 / 310 / **406** / 526 / 600 s | 152 / — / 272 / — / 300 s |
| Mean | 412 s | — |
| **Inside the 5–10 minute band** | **77%** (23% under, 0% over by construction) | n/a |
| **Decided by razing a keep** | **85%** | 58% |
| Reaching the clock | 15% | 42% |
| Tiebreak tier that resolves (of clock matches) | T1 54%, T2 25%, T3 17%, draw 4% | — |
| Family win rates: aggro / economy / defence / mixed | 48.1 / 51.2 / 54.6 / 47.6 | — |
| **Family spread** | **7.0pp** | 24.2pp |
| Best line per family | Rush-horse 77.8, Greed-pure 73.3, Turtle-eco 71.4, Balanced 59.2 | Rush 67.5, Greed 73.6, Turtle 54.7, Balanced 49.4 |
| **Decision leverage** (spread between variants of one archetype) | **26.9–55.0pp** | 20.9pp |
| Concurrent units per player | median peak 17, p90 47, max 57 | median peak 25, p90 54 |

**The critical ratio.** Families differ by 7pp while lines *within* a family differ by 27–55pp,
meaning **how you play an archetype matters roughly five times more than which archetype you
brought.** v1 had this the other way round (24.2pp archetype spread against 20.9pp leverage).
All three pure archetypes have a top line above 70%, which meets the design's "live path to
victory" constraint literally rather than approximately. Decisiveness is much better while still
leaving the ladder a real 15% of matches to adjudicate — and every tier fires, so nothing in Q10
is dead code.

**One line to watch rather than pretend is solved: mass-Horse at 77.8% is the strongest single
line.** Its counter exists and is strong (Spear beats Horse 72–78% at equal Levy) but the
scripted defenders under-use it. **Do not pre-emptively nerf Horse on scripted-AI evidence** — a
human will punish it. Watch it in the first playtest and be ready.

The measurements themselves are solid. **How they transfer to human play is the open question**
(F.1).

## C.7 Wire sizes at a glance

| | v1 | v2 |
|---|---|---|
| Handshake `S` | 42 bytes | **39 bytes**, and now carries the actual cards |
| Command atom | 6 bytes | 6 bytes, unchanged |
| Largest message | 67 bytes (`C`, n=8) | **70 bytes** (`C`, n=8) |
| Typical traffic | 19/min | 19/min |
| Worst-case traffic | 30/min | ~32/min |

Still one third of the 200-byte target and one quarter of the 255-byte hard limit. **Nothing is
ever chunked.**

---

# Part D — Scope: what ships

**Principle, revised.** v1's principle was "the first playable exists to prove the deterministic
sim and the netcode; nothing else earns a place." That still governs the **first playable**. But
Ruling 5 changes the principle for **v1.0**: the first *shipped* build exists to feel like the
design, and the balance risk of doing that is accepted.

## D.0 The headline finding that justifies Ruling 1 on engineering grounds

Worth stating as fact, not as owner preference: **v1's coefficient vector could not express five
of v1's own ten recommended starter cards.**

The v1 handshake carried an anonymous 7-slot vector — unit HP, unit damage, damage taken, march,
building HP, building time, damage vs buildings — every slot a **flat, global, permanent**
percentage delta. Nine of the 40 cards modify a stat **conditionally**, scoped by unit type,
board position, elapsed time, current HP, or nearby unit count, and are therefore not
representable in it at all:

| Card | Why the vector breaks it |
|---|---|
| **Bastion Walls** *(starter)* | `bldHP` scoped to *defensive* buildings — the opponent's sim would buff Levy Posts too |
| **Iron Discipline** *(starter)* | `dmgTaken` scoped to `x < 1000` — the opponent's sim would apply −25% across the whole lane |
| **War Drums** *(starter)* | `unitDmg` gated on a 20-second timer — the opponent's sim would apply +15% permanently |
| **Ward** *(starter)* | building-sourced reflect damage — no slot exists |
| **Miasma** *(starter)* | territory decay damage to enemy units — no slot exists |
| Bulwark Line | `unitHP` scoped to Spear |
| Vanguard | per-unit flag |
| Tide of Bodies | count-scaled |
| No Retreat | HP-scaled |

**Under v1 as written, M7's milestone — "each side's units visibly deviate from baseline" — would
have desynced on the second starter card tested.** Ruling 1 deletes the vector and the entire
impossibility class with it, and the replacement (5 IDs × 2 chars = 10 bytes) is *smaller* than
the 19 bytes of coefficient + affinity vector it replaces.

## D.1 First playable — internal only, not shipped

| Ships | Cut |
|---|---|
| 3 units (Spear, Bow, Horse) | Everything else below |
| **6 buildings**: Palisade, Arrow Tower, Trap Pit, Watchtower, Levy Post, Granary | The other 6 |
| 3 lanes, 6 slots, cap 4, supply cap 200 | — |
| **Zero modifiers. No loadout screen. No type wheel.** | All 40 cards, the affinity system, `K` |
| Flat income, repel refund, **spoils**, bank cap | — |
| Keep + the full tiebreak ladder | — |
| Muster bar as the only fog | All Mystic vision |
| Halt / resume / void, symmetric and asymmetric | — |
| **Party scope only** | Guild and public scope |
| Placeholder UI on `Widgets.lua` | `Theme.lua` reveal stage, podium, animation |

Six buildings is one of each role — wall, gun, trap, eye, income, bank — the minimum that
exercises the front/back slot tension and the "which lane did you harden" opening. *(v1 also cut
the three buffing buildings because they were the only ones that could not be deferred under its
disclosure rule. That reason is gone; they are cut for scope alone now.)*

## D.2 v1.0 — the first shipped build

Adds: **all 40 modifiers**, the affinity system and `K = 0.06`, the remaining buildings including
Caravan, **guild and public scope**, the themed UI and post-match recap, saved loadouts, the
unlock ledger, the ~800-byte match descriptor written to SavedVariables.

**Nothing is cut for technical reasons. The technical cut list is empty.**

### Cards repriced by the editor to fit the measured clamps

The modifiers rework wrote several values against v1's looser clamps; Q4's clamps are measured
and win. Every affected card:

| Card | As proposed | **Ships as** | Why |
|---|---|---|---|
| Breeding Pits | `unitCost −20` | **`unitCost −10`** | `unitCost` is worth 2.2pp/point; −20 measured +26.5pp |
| Chaff | `unitCost −40, unitHP −30` | **`unitCost −20, unitHP −30`** | −40/−30 measured **86.1%**; −15/−30 measured 51.5% |
| Late Levy | `unitCost −25` after half-clock | **`unitCost −20`** after tick 3,000 | matches the channel clamp exactly |
| Vanguard | `unitDmg +50` | **`unitDmg +35`** | over the `unitDmg` clamp |
| No Retreat | `floor(40 × (maxHp−hp)/maxHp)` | **`floor(35 × (maxHp−hp)/maxHp)`** | over the clamp; the last 5 points were dead |
| Tide of Bodies | `+2 × N`, capped by a 12-unit lane cap | **`+2 × N`, own-source ceiling +30** | the 12-unit cap is deleted; the `unitDmg` clamp (+35) still applies on top |
| Surplus | `+1 levyFlat` per 100 banked, ceiling +8 | **`+1 levyFlat` per 50 banked, ceiling +6** | bank cap is 200, so per-100/ceiling-8 was unreachable; per-50 gives +4 at base cap and +6 with a Granary |
| Trade Routes | "yields ~1,170 extra Levy" | **yields ≈ 670 extra Levy** (+38% on 1,740) | re-derived against the 3.5 s Levy tick |
| Golden Age | threshold 1,200 cumulative earned | **threshold 700** cumulative earned, lands ≈ t = 235 s (39% of clock) | 40% of the *actual* 1,740 match income, not the 3,000 assumed |
| Caravan | +8 Levy/tick | **+4 Levy/tick**, 400 HP | +8 was 4× a Levy Post for the same cost at the 3.5 s tick |
| Plunder | 50% of building cost | **100% of cost + 20 flat** (replacing the 75% baseline, not stacking) | Spoils is 75% baseline; Plunder must beat it, per the economy lead's explicit instruction |
| Ley Line | destination capped at 12 units | **destination capped at 200 supply** | the headcount cap is deleted |
| Shrine pulse | "every 20 s for 3 s" | **every 200 sim ticks for 30 ticks** | Q11: all timers in sim ticks |
| War Drums | "20 seconds" | **200 sim ticks** | same |
| Investment | "45 seconds" | **450 sim ticks** | same |

**A consequence to surface in the loadout UI, not hide:** Raider's damage cards saturate. Vanguard
(+35) alone fills the `unitDmg` channel; adding War Drums (+15) and No Retreat (+35) wastes two
slots. Likewise Chaff (−20) alone fills `unitCost`, making Breeding Pits and Late Levy dead
alongside it. **This is intended** — it is the structural replacement for v1's lane headcount cap
(Q4) — but it must be shown as a "channel saturated" warning at loadout time.

## D.3 The 40 cards as they ship

Wording is normative. `[Stat]` = a channel delta. `[Rule]` = changes how something works.
Every timer is in sim ticks (Q11). Every conditional reads the tick-start snapshot (S9). Every
tie breaks by lowest entity ID (S10).

### SWARM — 3 `[Rule]`, 5 `[Stat]`

| # | Card | | Ships as |
|---|---|---|---|
| 1 | **Breeding Pits** | Stat | `unitCost −10`. |
| 2 | **Chaff** | Stat | `unitCost −20`, `unitHP −30`. |
| 3 | **Scent Trails** | Stat | `march +25`. |
| 4 | **Tide of Bodies** | Rule | At the start of each resolve tick, count your living units in that lane (N). Every unit of yours in that lane gains `unitDmg +2 × N` for that tick, own-source ceiling +30. Computed from the tick-start snapshot; units that die during the tick do not change it. |
| 5 | **Endless Ranks** | Rule | Each of your units that dies in a lane grants that lane one **Muster charge**, max 3 per lane. Charges never move between lanes and do not persist past the match. When you issue a deploy order into a lane holding at least one charge, the **first unit of that order is free** and one charge is consumed. At most one charge per order. |
| 6 | **Rickety Scaffolds** | Stat | `bldTime −50`, `bldHP −40`. |
| 7 | **Press-Gang** | Stat | `levyTick +15`, `bankCap −50`. *(Was `[Rule]`; it was always two stat deltas wearing a Rule label.)* |
| 8 | **Conscription** | Rule | Keep a match-long count of units you have deployed. Every third unit — the 3rd, 6th, 9th… — costs 0 Levy. Units inside a batched order are counted in issue order. The counter advances at command execution in canonical order. |

*Endless Ranks' "pro-loser engine" is bounded by the 3-charge ceiling and, crucially, by **S5**:
only one free-deployment effect may fire per deploy order, so Endless Ranks and Conscription
**overlap rather than multiply**. That single arbitration rule is what keeps the Swarm cost stack
from running away.*

### FORTRESS — 2 `[Rule]`, 6 `[Stat]`

| # | Card | | Ships as |
|---|---|---|---|
| 1 | **Bastion Walls** | Stat | `bldHP +50`, scoped to buildings flagged `defensive` in the catalogue. |
| 2 | **Iron Discipline** | Stat | `dmgTaken −25`, scoped to `x < 1000` (your own half); position read from the tick-start snapshot. |
| 3 | **Counterwall** | Rule | Track, per lane, the total Levy cost of enemy units that have died in **your half** of that lane since that lane was last clear of enemy units. When the lane transitions from containing enemy units to containing none at the start of a resolve tick, credit **20% of that accumulator** on top of the 15% baseline repel refund — 35% total on a clean repel — and reset the accumulator to zero. |
| 4 | **Deep Foundations** | Rule | While the **front** slot of a lane holds a building of yours, complete or under construction, your **back**-slot building in that lane cannot be damaged by any source. **An empty or destroyed front slot confers nothing.** |
| 5 | **Rapid Masonry** | Stat | Each time a building of yours is destroyed, its slot gains a **Rubble** mark. The next building you place into a marked slot costs 50% less (`bldCost −50`) and consumes the mark. Marks do not stack; at most one per slot. |
| 6 | **Watchfires** | Stat | Your defensive buildings gain **+50% damage range** and reveal their lane out to that range. |
| 7 | **Granary Reserves** | Stat | `bankCap +50`. At the start of each Levy tick, if your banked Levy is at or above half your modified bank cap, `levyTick +20` for that tick. |
| 8 | **Bulwark Line** | Stat | `unitHP +40`, scoped to Spear. |

*Counterwall stays a genuine `[Rule]` rather than taking v1's flat-rate conversion, because the
ambiguity that justified converting it — "fully repelling an attack", an undefined entity — is
fixable with a per-lane accumulator and a clear-transition trigger, both cheap and deterministic.
The burst also plays better than a trickle: the defender feels the repel pay out as one event.
**Simplification fallback if the accumulator is unwanted:** `repelRefund +20` pp, a flat 35%,
which is exactly v1's version. Deep Foundations needs the empty-front clause or it grants free
permanent immunity to anyone who never builds a front building. Rapid Masonry needs the Rubble
mark or it is an unbounded permanent 50% discount on six slots.*

### BOOM — 3 `[Rule]`, 5 `[Stat]`

| # | Card | | Ships as |
|---|---|---|---|
| 1 | **Trade Routes** | Stat | `levyFlat +1` for every full 60 seconds (600 sim ticks) of active match time elapsed, ceiling **+6**. Yields ≈ 670 extra Levy over a full match (+38%). |
| 2 | **Golden Age** | Rule | Once your **cumulative Levy earned** this match — not banked — reaches **700** (40% of a baseline match's income; lands ≈ t = 235 s on flat income), latch `levyTick +40` for the rest of the match. One-way latch, checked at the start of each Levy tick. *Earned-not-banked is deliberate, so the threshold never interacts with bank cap.* |
| 3 | **Investment** | Rule | Order kind `i`. Spend 25 Levy per block, 1–4 blocks. **Only one investment may be outstanding.** 450 sim ticks after its exec tick it pays **180%** of the amount, credited at that Levy tick and clipped by the bank cap together with all other same-tick credits. |
| 4 | **Master Masons** | Stat | `production +35` — the Levy output of your functional buildings. Does **not** affect their bank-cap contribution. |
| 5 | **Surplus** | Stat | At the start of each Levy tick, **before** income is added, `levyFlat +1` per full 50 Levy in your bank, ceiling **+6**. *(Was `[Rule]`; S6 forbids the original compounding form.)* |
| 6 | **Caravan** | Rule | Unlocks the **Caravan** — back slot, cost 120, HP 400, +4 Levy per Levy tick, build 120 ticks. Occupies a normal slot and counts against the normal cap. |
| 7 | **Late Levy** | Stat | Units deployed after **50% of the match clock** (tick 3,000 of 6,000) cost 20% less (`unitCost −20`). |
| 8 | **Boomtown** | Stat | `slotCap +1`, clamped to `[4, 5]`, one source only. *(Was `[Rule]`.)* |

*Every time gate in this archetype was written against a 3–5 minute match and every one broke at
10 minutes. **Late Levy's "two-minute mark" would have covered 80% of a 600-second match**, making
it indistinguishable from an unconditional discount. Expressing it as a fraction of the clock is
the only form that survives the next length change too, and that is now a blanket rule for the
pool (Q11). **Investment's one-outstanding guard is what satisfies S6:** unbounded re-investment
is 1.8× per 45 s, which is ~680× over a 600-second match.*

### RAIDER — 4 `[Rule]`, 4 `[Stat]`

| # | Card | | Ships as |
|---|---|---|---|
| 1 | **Plunder** | Rule | When an enemy building is destroyed, the owner of the source that dealt the killing damage gains **100% of that building's Levy cost plus 20 flat**, replacing the 75% Spoils baseline rather than stacking with it. Ties by lowest source entity ID. |
| 2 | **Blood Tithe** | Rule | When an enemy unit dies, the owner of the killing source gains **20%** of its Levy cost. Attribution follows S8, so Arrow Tower, Trap Pit, Ward reflect, Miasma decay and Scorched Earth kills all pay. **Stacks with the 15% baseline repel refund when the kill is in your own half — 35% total.** |
| 3 | **War Drums** | Stat | **One buff timer per player**, not per unit. Any kill by any source of yours sets the timer expiry to `currentTick + 200`. While live, all your units get `unitDmg +15`. Read from the tick-start snapshot. |
| 4 | **Sappers** | Stat | `dmgVsBuildings +100`, taking the ×0.5 structure multiplier to ×1.0. |
| 5 | **Vanguard** | Stat | The **first three units you deploy into each lane this match** are permanently flagged Vanguard and get `unitDmg +35`. The flag is assigned at deploy time in canonical order, never expires and never transfers. |
| 6 | **No Retreat** | Stat | `unitDmg` bonus = `floor(35 × (maxHp − hp) / maxHp)`, read from the unit's HP in the tick-start snapshot. |
| 7 | **Scorched Earth** | Rule | Order kind `s`, target = lane 1–3, count = 1–4 blocks of 25 Levy. At the exec tick, in the **command phase before combat**, deal **600 damage per block** to each of the up to three enemy units in that lane nearest your own keep, ties by lowest entity ID. Structures take the standard ×0.5. **300-tick cooldown.** |
| 8 | **Raiding Party** | Rule | `march +40` scoped to Horse. Additionally, **once per lane per match**, the first Horse of yours to reach the enemy front slot in that lane while an enemy front building stands consumes that lane's **Bypass** flag: your Horses in that lane are not blocked by that building and do not auto-engage it. They still take tower damage. |

*No Retreat was v1's only genuinely technical cut and it is worth being precise about why it
dissolves. Damage scaling on current HP is order-dependent **only if damage is applied
sequentially within a tick** — but sequential application already breaks symmetric mutual kills,
so any correct lockstep sim must compute all damage from a tick-start snapshot and apply it
afterwards. Once **S9** exists, No Retreat is free.*

*Scorched Earth and Raiding Party shared one underlying defect worth generalising: v1 read
"variable amount" and "may bypass" as agency and RNG, and **both are removable by quantizing the
amount into the atom's count field and making the trigger automatic and one-shot.** The remaining
objection to Scorched Earth — that it introduces direct damage into a game that otherwise has none
— is a design taste call, and Ruling 5 does not accept taste as grounds. **The 600-per-block number
is a first guess and belongs in the next economy sweep**: at 100 Levy for 1,800 damage it is
Levy-negative against Spears and roughly neutral against Horses, buying tempo rather than value.*

### MYSTIC — 5 `[Rule]`, 3 `[Stat]`

| # | Card | | Ships as |
|---|---|---|---|
| 1 | **Hex** | Rule | On a fixed schedule from tick 0 — **every 400 sim ticks, lasting 200 ticks** — the enemy's `levyTick` is reduced by 30. No RNG, no input, no state beyond the tick counter. |
| 2 | **Divination** | Rule | *Render-only.* Continuously reveals all **completed** enemy buildings — slot and identity. Never HP. Never buildings under construction. Self-announcing at tick 0. |
| 3 | **Omen** | Rule | *Render-only.* Every enemy deploy order is surfaced the moment its command atom arrives — one order-delay before it takes the field: **lane and unit count only, never unit type.** Self-announcing at tick 0. |
| 4 | **Veil** | Rule | *Render-only.* Suppresses display of your buildings on the enemy client from every source except contact reveal and destruction. **Beats Divination and Shrine pulses absolutely.** Not self-announcing. |
| 5 | **Ward** | Stat | When one of your buildings takes damage from an enemy unit, that unit takes **25% of the pre-mitigation damage**, computed from the same tick-start snapshot in the same damage phase. Reflected damage carries a **no-reflect flag** and can never reflect again. Kill credit goes to you per S8. |
| 6 | **Miasma** | Stat | At each resolve tick, every enemy unit with `x < 1000` takes **8 damage**, attributed to you. |
| 7 | **Ley Line** | Rule | Order kind `l`, target = source lane 1–3, count = destination lane 1–3. At the exec tick, every unit of yours in the source lane with `x < 1000` moves to the destination lane at the same `x`. Move in **ascending entity ID**; units that would exceed the destination lane's **200 supply cap** do not move and are not queued. **450-tick cooldown.** |
| 8 | **Discord** | Stat | Enemy unit deployments cost +15 on the **enemy's** `unitCost` channel. |

*Ley Line's v1 cut reason does not survive inspection: unit positions were shared board state in
v1 too, so "continuous in-transit positions" was never the obstacle. The obstacle was the per-unit
targeting UI, and **replacing selection with an automatic rule — "everything of yours still in your
own half" — removes it entirely while fitting the atom's two spare fields exactly.***

*The four render-only cards (Divination, Omen, Veil, plus Fortress's Watchfires reveal) are the
**cheapest cards in the pool**: zero sim surface, zero wire surface, zero desync risk. They should
be implemented first among the `[Rule]` cards, not last.*

## D.4 Technical cut list

**Empty.** Zero cards are cut for technical reasons under Ruling 5's test. This is stated as a
positive result rather than an omission, because it is the direct consequence of Ruling 1: under
full state sharing, "the client cannot compute it" is the empty set.

## D.5 v1.1+

Reconnect from the persisted match descriptor (Q15). The Shrine's second effect if the reveal
pulse and the ward charge are split into two buildings. Blind Draft groundwork.

## D.6 v2+

Blind Draft as a named queue mode; match-length presets behind the existing `matchTicks` field;
teams or FFA — v3 at the earliest, if ever (Q13).

## D.7 Never, in this architecture

- **Any per-turn confirmation scheme** (A.12) — it would consume the prefix budget and deadlock
  under mute, in the exact situation it exists to handle.
- **Any anti-cheat** (G.1) — every check would run on the cheater's own machine.
- **Any in-encounter signalling fallback** — `SPEC.md` §2.12, policy line, not negotiable.
- **Any sim code that reads `GetTime()`, the client clock, a date, framerate, addon load order,
  or UI state** (Q11, A.5).
- **Any sim code that knows which side is the local player** (A.2).

---

# Part E — Build order

Each step names the cheapest thing that proves the next-riskiest assumption, and a milestone that
either passes or does not. **Do not proceed past a red milestone.**

**The risk ordering changed in v2, and this is the most consequential structural difference in
this part.** v1 opened with the platform probe, because the riskiest assumption was whether a
comms lockdown could be survived at all. Rulings 2 and 3 largely defuse that: pausing is
acceptable, symmetric pause is the common case and needs no protocol, and the match is no longer
racing a downtime window. **The riskiest remaining assumption is Ruling 1's accepted cost — that
a doubled determinism surface, with the full economy, 40 modifiers and the tiebreak accumulators
all running identically on two machines, can actually be kept bit-identical.** So the critical
path now starts with the determinism harness. The probe still runs — it costs half a day and it
calibrates real constants — but it runs *alongside*, not in front.

### P — The Probe *(half a day, parallel, off the critical path)*

A throwaway module that sends `IB|P|<n>` every 6 s and logs to SavedVariables: the local
`InChatMessagingLockdown()` state, every send result code, every receive timestamp, and every
`PG.Safety` transition. Wear it for one raid night with one other person.

> **Milestone:** a log file showing the exact boundaries where sends start and stop being
> refused, the true refusal codes observed in the wild, and measured one-way latency and loss
> rate over a real raid evening. **Every rate constant in A.11.4 and A.12 is calibrated from this
> file.** Specifically: confirm `ADDON_RESTRICTION_STATE_CHANGED` fires *before* the restriction
> (`SPEC.md` rule 10), since A.6 treats that as the most valuable event in the design, and
> confirm that a raid pull mutes **both** members of the group at the same moment, since Ruling
> 2's fast path assumes it.

### M1 — Cross-machine determinism harness *(no WoW, no UI, no network)* — **the top risk**

The unified sim core (A.1) as a plain Lua module — units, buildings, **economy, costs, bank,
income** — plus a test that replays a scripted command log. Run the four greps (A.5) in CI from
day one.

> **Milestone:** the same `rulesHash` and the same command log produce a **bit-identical
> `stateHash` after 6,000 ticks**, over 1,000 randomised logs, under both Lua 5.1 and the 5.4
> `luac -p` checker, **on two different machines with different CPUs**. The hash must cover
> Levy, bank, every accumulator and every tiebreak counter, not just the board. All four greps
> pass with zero hits. **Any `pairs()` or float in sim-affecting code is a bug and this harness
> is what finds it.**

### M2 — The sim playing itself, and the economy re-sweep

Wire M1 to the numbers in Part C. Both sides driven by scripted policies. No rendering.

> **Milestone:** 1,000 simulated matches terminate — by razed keep or by clock — reproducing
> C.6 within a few points: **median 380–430 s, ≥75% inside the 5–10 minute band, ≥80% decided by
> a razed keep, family spread under 10pp.** This is where Part C gets its first test in the
> shipping language rather than in Python, and where the two models are cross-checked against
> each other. **A disagreement between the Lua sim and the Python sim is a finding, not a
> nuisance.**

### M3 — All 40 modifiers in the harness — **the second risk**

Every card from D.3, with the S1–S10 stacking machinery. Still headless.

> **Milestone:** for each of the 40 cards individually, and for 200 randomly drawn 5-card
> loadouts on both sides, M1's bit-identical-hash test still passes over 6,000 ticks. Plus a
> clamp-saturation report: every channel's summed value across all 200 loadouts, confirming no
> channel is ever driven outside its Q4 clamp and identifying which cards saturate together
> (D.2). **This is the milestone Ruling 5's accepted risk lands on**, and it is deliberately
> ahead of any networking so that a card-caused desync is never confused with a packet-caused
> one.

### M4 — Two sims, one client

Two instances of the sim in one addon session, fed the same log through a fake transport that can
drop, delay and reorder messages on command.

> **Milestone:** state hashes match at every epoch for 6,000 ticks with 10% packet loss and up to
> 3 s of jitter. Rollback repairs every late command. A forced deep desync is repaired by the
> `Q` full-log replay path from tick 0 — **which requires both loadouts, and is the concrete
> demonstration that Ruling 1 made recovery real** (0.1, item 4). **This proves the reliability
> shim before a single real message is sent.**

### M5 — First playable, over the wire

Register `IB` on `Comm.lua`. `OPEN` / `JOIN` / `S` / `C` / `H` only. Party scope. Two real
characters. Content per D.1.

> **Milestone:** a complete 600-second match between two accounts, ending by keep or clock, with
> state hashes matching at every heartbeat and **measured traffic under 32 messages/min per
> player**. Both clients independently reach the same verdict, including through the tiebreak
> ladder. The first time this passes, the project's two hard problems are solved.

### M6 — Halt and resume, both cases

`X` / `K` / `G`, the pre-flight gate, the pause budgets, `V` and every void path.

> **Milestone, symmetric (the fast path):** start a match with both players in the same raid,
> pull a boss, finish it, resume. Both clients halt within 3 s of each other, the resume
> countdown fires, hashes match on the first heartbeat after resume, and the match clock shows
> only active time. **Then repeat with every `X` message deliberately dropped and confirm
> nothing changes** — this is the test that proves A.6's central claim.
>
> **Milestone, asymmetric (the case that needs the protocol):** one player enters a 5-minute
> encounter the other is not in. Confirm the 10-second silence detector fires, the overlay copy
> appears, the halted side keeps logging inbound commands, and on resume the lagging side
> **visibly re-simulates** its missing ticks over ~1 s rather than snapping (A.8). Then confirm
> a match survives three consecutive pauses without accumulated clock drift (A.10).

### M7 — Fog as a render filter

`IBFog.lua`, the muster bar, the live tiebreak score from t = 120 s, the themed window.

> **Milestone (replacing v1's, which is false by construction now):** all four greps in A.5 pass
> with zero hits on a full build — in particular, **no sim file contains any reference to local
> player identity**. Plus a rendering test: with `Fog.Visible` stubbed to always-true, the match
> outcome and every state hash are **bit-identical** to the same match with fog enabled. That
> equivalence is the real proof that fog cannot affect the sim.

### M8 — Loadouts, modifiers and the wheel, over the wire

The 10-byte loadout in the handshake, `proto` and `rulesHash` validation with two distinct
refusal strings, the affinity system, `K`, all 40 cards live, the unlock ledger, the persisted
match descriptor.

> **Milestone:** two clients with deliberately different `rulesHash` values refuse each other
> politely **and with the correct one of the two messages**; two clients with a matching hash
> play a full match with five cards each where each side's units visibly deviate from baseline
> and state hashes match at every heartbeat. Then: **take the persisted 800-byte descriptor from
> that match, replay it offline on a third machine, and reproduce the final state hash exactly.**
> That is the replay guarantee from 0.1 item 3, and it is what makes every subsequent bug report
> reproducible.

### M9 — Matchmaking, public scope and shipping

Guild and public scope, the launcher *Open games* row, the invite budget, the recap screen, the
README honesty sentence.

> **Milestone:** three concurrent battles plus a live Loot Goblins round in one raid, with no
> cross-session interference, no dropped Loot Goblins messages, and every `CONCURRENCY.md`
> invariant I1–I10 verifiable by the greps that document specifies. Plus one **public-scope**
> match played to completion with a stranger, which is the first real exercise of the asymmetric
> pause path in its normal habitat (Q14).

---

# Part F — Still open

Everything above is decided and an implementer may proceed. These are the honest unknowns.

1. **Whether the measured numbers transfer to human play.** All of Part C is scripted-policy
   output. The measurements are solid; the transfer is not established. This is the single
   largest unknown in the document.
2. **Mass-Horse at 77.8%.** The strongest single line in the sweep. Its counter is strong
   (Spear beats Horse 72–78% at equal Levy) but the scripted defenders under-use it.
   *Recommendation: do not pre-emptively nerf. Watch it in the first playtest.*
3. **The specific unit and building integers.** Simulation output. Expect them to move. The
   *structural* points — Bow needs multi-target, Horse must be cost-inefficient, Trap Pit must
   not overkill — are high-confidence; the values are not.
4. **200 as the lane supply number.** It is a knee-of-the-curve reading (42.2% → 48.7% → 49.1%
   at 120 / 200 / 300) and could move a little.
5. **Spoils at 75%.** New baseline rule, one sweep of evidence, and it is entangled with
   Plunder's repricing (D.2). If Plunder feels mandatory for Raider, Spoils is too low; if
   Plunder feels redundant, it is too high.
6. **Scorched Earth at 600 damage per block.** Explicitly a first guess, flagged by its author
   for the next economy sweep.
7. **Wheel strength `K`** — 0.06 recommended, band 0.04–0.08. **[OWNER]**, a feel judgement.
   Note C.7's sharpened scale check: the wheel is roughly an order of magnitude below a single
   strong card, which argues against raising it.
8. **Whether the 10-second silence detector is too eager on a laggy realm.** A false halt costs
   2 messages and ~2 seconds, so the design assumes it is cheap — but a detector that fires
   every 30 seconds on a bad connection will read as broken regardless of what it costs.
   Calibrate from the Probe's loss data.
9. **Whether Investment, Ley Line and Scorched Earth are worth their UI in v1.0.** They ship on
   Ruling 5 and their *protocol* cost is now near zero (A.11.2), but each still needs a targeting
   affordance in a UI meant to be usable in a 30-second lull. This is a scope question, not a
   technical one.
10. **Caravan and the option-space objection** (Q8). The one reversal where the losing argument
    still has force. The fallback — a shared-catalogue building plus a discount card — is one
    table edit.
11. **Does "mustering" land?** 2.0 s of order delay is presented as flavour rather than latency.
    If it reads as lag, the fix is presentational (a visible muster animation at the keep), not
    numeric.
12. **Is the 3-bucket muster bar enough information?** *Recommendation: 3 buckets, and let
    Watchtower be the answer.*
13. **Slot cap 4 of 6 with only 6 buildings in the first playable.** "Something is always
    undeveloped" was sized against a 12-building catalogue. Worth one look after M2.
14. **Whether a void should be visible at all.** *Recommendation: never surface it — the moment
    a quit has a cost, the lockdown story starts to come apart.* Public scope (Q14) is the one
    place this may need revisiting.
15. **Working title and theme** (Q16). *Recommendation: "Marches"; wire code stays `IB` forever.*

---

# Part G — Risks we are knowingly accepting

Each of these is a decision, not an oversight. They are collected here so nobody has to
reconstruct the reasoning later.

## G.1 A modified addon sees everything (Ruling 1)

**What is exposed.** Under full state sharing, a modified client can read: the opponent's entire
loadout, their Levy, bank and income, every building including undisclosed ones and those under
construction, every unit position in their own half, and the exact effect of every card they
hold. **Fog is cooperative, not structural.** Veil, Divination, Omen, the muster bar and
undisclosed buildings are all render policy honoured only by an unmodified addon. v1 was
materially stronger here — enemy building placements and the loadout were *not present on your
client at all*.

**Why it is accepted.** The owner's ruling is explicit: *"if someone is going to cheat then oh
well, for now."* The engineering case backs it: the addon ships as readable Lua with no server,
so every check would run on the cheater's own machine; there is no gold, no ladder, no rating,
purely horizontal progression, and opponents are guildmates you will see again. And the residual
that v1 protected was already thin — it protected the *loadout* at the cost of making five of its
own ten starter cards unimplementable (D.0).

**What we ship instead of anti-cheat:** one honest sentence in the README.

> *"This is a trust-based game between people who know each other. There is no server, so a
> modified addon can see the whole board — including your opponent's cards. If that matters to
> you, play with people you trust."*

**The one place to watch it: public scope** (Ruling 6). A stranger has no social stake, and this
is the only combination in the design where the cheating posture and the scope posture pull
against each other. If public scope becomes a problem, the answer is to restrict *scope*, not to
add anti-cheat.

## G.2 Forty cards, seventeen `[Rule]`, none playtested (Ruling 5)

**The risk.** v1 planned to ship 20 `[Stat]`-or-Tier-1 cards in v1.0 and hold everything with
identity for later. v1.0 now ships **40 cards, 17 of them `[Rule]`, 24 of them reworded, and 3
of them granting the player entirely new verbs** — all at once, with zero playtest data behind
any of it. The first tuning pass has far more surface than v1 planned for, and the exchange-rate
measurement that the clamps are built on (Q4) is explicitly one-sided.

**Why it is accepted.** The owner's ruling: the first shipped build should feel like the design.
The `[Rule]` cards are where the identity is, and a v1.0 of stat nudges would ship the skeleton
without the game.

**What bounds it, and this is the real answer to the risk.** Cuts are not the mitigation —
structure is:

- **S4's tight clamps**, derived from measurement rather than taste, and deliberately tight
  enough that the strongest channel saturates on a single card (Q4).
- **S5's arbitration rule** — one free-deployment effect and one bypass effect per event — which
  is what stops the Swarm cost stack running away.
- **S6's no-compounding rule**, which converted Surplus, Trade Routes and Investment from
  exponentials into bounded linear ramps.
- **S9 and S10**, which make the conditional cards deterministic for free.
- **M3**, which puts the whole pool through the determinism harness *before* any networking, so
  a card-caused desync is never confused with a packet-caused one.

**And a specific card to watch:** Chaff. Measured at its originally-proposed −40/−30 it wins
**86.1%**. It ships at −20/−30. If any single card breaks the game it will be this one.

## G.3 The determinism surface roughly doubled (Ruling 1)

Under v1, a float or a `pairs()` in my economy could not desync your client, because you never
ran it. Now every line of economy, modifier and tiebreak code runs on both machines and any of
it can desync. **This is the price of everything Ruling 1 bought and it is not small.**

It is paid for in exactly three places: **the four greps (A.5)** run in CI from day one; **M1**,
which now hashes the whole sim rather than the board and runs on two physically different
machines; and **M3**, which runs every card through M1 before the network exists. If those three
are taken seriously the risk is managed. If any of them is skipped, this becomes the thing that
kills the project.

## G.4 A balance patch is now a hard compatibility break

**Nobody has stated this and it is a real operational cost.** `rulesHash` covers the entire
ruleset — every card value, every building stat, every clamp, `K`, and every constant in Part C
(A.11.1). It has to, because a single mismatched clamp now desyncs at the first engagement. But
that means **any tuning change splits the population until everyone updates.** v1 only hashed
the modifier table, so it had a narrower version surface (though, as D.0 shows, a narrower and
partly fictional one).

**Accepted, with three mitigations:**

1. **Batch balance changes.** Never ship a one-card tweak; ship a numbered balance patch.
2. **Make the refusal message say what it is.** Two distinct strings (A.11.1): "different
   protocol version" vs **"your opponent is on a different balance patch — everyone needs
   x.y.z"**. A player who sees the second one knows exactly what to do.
3. **Keep the ruleset in one file** so `rulesHash` is computed over a single artifact and cannot
   drift silently.

## G.5 Ten minutes of intermittent attention is a product bet

Ruling 4 sets 5–10 minutes and Ruling 3 says raid downtime is not the constraint. The measured
median is 406 s with a p90 at the 600 s cap, and a match may span several pauses and an hour of
wall clock. **Whether a player will stay engaged with a 10-minute match they check in on between
other things is a product hypothesis, not an engineering one.** The design hedges it in two
places: the `matchTicks` wire field exists so presets can be added without a protocol bump
(Q11), and **keep HP is a pure length dial that moves pacing with zero balance cost** (C.5). If
the bet is wrong, the fix is one number and no code.

## G.6 Public scope makes the hard netcode path the normal one

Under Ruling 6, a stranger on your realm is by definition in different content, so **the
asymmetric pause (A.8) is the normal case in public scope, not the exception.** Ruling 2's
elegant zero-message fast path applies only to people in the same group. Expect a materially
higher void rate in public scope. Accepted because a void is cheap by construction — but public
scope should be shipped **and watched**, and M9 exists partly to exercise it.

---

*End. Part IV of `IDLE_BATTLE.md` is closed. The architecture in Part A is settled, the numbers
in Part C are provisional by design, and the open items in Part F are tuning, taste and one
product bet — not architecture.*
