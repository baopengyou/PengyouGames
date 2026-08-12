# IDLE_BATTLE_DECISIONS.md — closing Part IV

*Companion to `IDLE_BATTLE.md`. This document answers Open Questions 1–16, fixes a first
set of numbers an implementer can code against tomorrow, names what ships in the first
playable build, and lists what is still genuinely the owner's call.*

*Status: **tuning pass one**. Every number below is a starting point produced by analysis
and simulation, not by playtesting. The structural decisions (Part A) are meant to hold.
The numbers (Part B) are meant to move.*

*Inputs: four specialist analyses — netcode, economy, modifiers, match systems — plus the
shipped `PengyouGames` 1.0.0 source, `SPEC.md`, `SCOPE.md`, `CONCURRENCY.md`.*

---

# 0. READ THIS FIRST

## 0.1 The finding that decides whether the concept works

**A comms lockdown cannot desync a match. It was never a synchronisation problem. It is a
fairness and pacing problem, and the answer is halt-and-resume.**

This is the single thing to react to, because it looks like an existential threat and is
not. The reasoning is short enough to check:

- During an instance encounter, an M+ run, or a PvP match, a player's **outgoing** addon
  messages are refused. **Receiving still works** (`SPEC.md` §2.1).
- A player who cannot send produces **no inputs**.
- "No inputs" is the one thing two deterministic simulations always agree about.
- The muted client keeps receiving, so it keeps applying the opponent's commands.

So the sims stay identical through a boss fight with no protocol at all. What actually
breaks is *fairness*: for eight minutes, one player can act and the other cannot. That is
a game-design problem with a game-design answer.

**The answer, in one paragraph.** Each client **halts its own simulation locally** the
moment its own `PG.Safety` state machine reports any of `ENCOUNTER_START`,
`ADDON_RESTRICTION_STATE_CHANGED`, `InChatMessagingLockdown()` going true, `READY_CHECK`,
`START_PLAYER_COUNTDOWN`, or `PLAYER_ENTERING_WORLD`. No agreement is needed and no message
is required; the two halt ticks differ by the clock skew and that difference is temporal,
not divergent, because there are no commands inside it. If sends are still legal at halt
time — the pull-timer case, which is most raid pulls, with ~10 s of warning — the halting
client broadcasts an 18-byte `X` so the freeze looks synchronised. For surprise mutes, two
consecutive missed heartbeats (12–18 s) make the other side halt anyway. **Resume is global
and single-writer**: only the host issues `G|<tick>`, only after its own lockdown is clear,
it has received the client's `K` ("I'm clear"), and the board hashes agree. Both sides
fast-forward to the resume tick — instant and exact, because nothing happened in between —
behind a visible 3-2-1 so nobody returns from a boss fight to find they already lost.

**What it costs, stated plainly, because this is the part to react to.** Raid downtime is
60–120 s. A match with a 4.5-minute median will routinely span **two to four pulls**, and
will frequently spend **more wall-clock time paused than playing**. A halt is therefore the
*normal* path, not an error path. Any design that treats it as an error will fire on nearly
every match. Concretely, a match started at the end of one downtime window will typically
finish two or three pulls later, twenty minutes of wall clock after it began.

**Why that is survivable, and this is the load-bearing synergy in the whole design:**
progression is horizontal and participation-based (`IDLE_BATTLE.md` §10). Nothing is at
stake in a match except a fraction of an unlock. That is what lets the netcode **void
aggressively instead of guessing**. When the pause budget expires, or a player logs out, or
the peer goes silent for 300 s, the match is simply voided: no winner, no forfeit, no rating
effect, and unlock credit is still paid pro-rata. A void costs the player almost nothing, so
we never have to solve the unsolvable problem of distinguishing "quit" from "muted" over a
lossy channel with no server. **Cheap voids are what make the lockdown story work.** If
progression is ever made vertical or competitive, this entire answer collapses and the
netcode gets much harder — that is the one design change that would threaten the concept.

Two hard limits fall out and should be treated as product requirements, not netcode
parameters:

1. **Refuse to start a match inside an unbounded mute container.** M+ (20–40 min of
   continuous mute) and rated PvP (5–20 min) are hangs, not pauses. Raids are the product
   and are allowed, with a one-line banner: *"Boss pulls will pause the battle."*
2. **Budget the pauses.** Single pause 12 min, total pause 20 min, wall-clock 45 min.
   Exceeding any of them voids.

## 0.2 Three other findings that changed the architecture

**(a) You cannot have both deterministic lockstep and a hidden loadout — unless the wire
carries resolved numbers instead of cards.** Part III says run the identical sim on both
clients. §7 says the opponent's loadout must never be knowable. Those are in direct tension:
if my sim must reproduce your units exactly, it must know what your cards do. The resolution
is to **split the simulation in two**:

- **The shared board** — units, buildings, keeps, positions, HP, combat, build timers. Fully
  deterministic on both clients, hashed, repaired by rollback. This is the part Part III is
  about.
- **The private economy** — Levy, bank, income, unit and building *costs*. Simulated **only
  by its owner**. Never crosses the wire, never hashed, never re-validated by the opponent.

The opponent's economy never touches your board except through the commands it produces, so
your sim does not need it. This costs exactly one thing: the receiving client stops
re-validating affordability, so a modified addon could deploy units it cannot pay for.
Accepted — see (d) below. The corresponding rule for modifiers: at match start each client
sends an **anonymous coefficient vector** (seven signed percentage-point deltas: unit HP,
unit damage, damage taken, march, building HP, building time, damage vs buildings). Cost and
income channels are private and never appear. Fourteen bytes, sent once, and a cheater
reading memory sees `+40% unit HP` and must *infer* Bulwark Line — which is what an honest
player does, just with exact numbers instead of impressions. **Memorable form of the rule:
stats and timers are shared; costs and income are private.**

**(b) Unit count is a quadratic power term, and no per-stat clamp can reach it.** Cheap units
multiply lane HP and lane damage *simultaneously*, so a cost reduction is squared in effect.
The worst legal five-card stack in the drafted pool reaches roughly a **10:1 exchange rate**
— against a type-wheel modifier of ±6%. Clamping every channel and cutting the worst card
still leaves 4.5:1. The fix is structural, not numeric: **a per-lane unit cap of 12 per
side**, as a board constant. It converts Swarm's advantage from "more units" (quadratic,
unbounded) into "reaches and refills the cap cheaper" (linear, bounded), and it makes
Fortress's stated identity — *eats cheap bodies* — actually true.

**(c) Bank cap is pinned from below by the building table, and this coupling is invisible
until it bites.** Bank cap is the strongest aggression dial in the game (the best all-in rush
line runs 37% at cap 70 and 87% at cap 150, monotonic). But a bank cap below the dearest
building makes that building *literally unpurchasable* — four whole simulation sweeps silently
ran as building-free games before this was caught. **Hard rule: `bankCap >= dearestBuilding +
2 levy ticks`.** With a 130-Levy dearest building and 10/tick income, the floor is 150. So the
cap cannot be lowered to tame aggression; aggression is tamed instead by the **baseline repel
refund** (0.2, Q1) and the lane cap.

**(d) One honest sentence in the README replaces all anti-cheat.** The addon ships as readable
Lua with no server; every check would run on the cheater's own machine. Under the model above,
the residual readable-but-unrendered surface is: enemy unit positions in their own half, the
anonymous coefficient vector, the five-number affinity vector, and unvalidated affordability.
Enemy **building placements** and the **loadout itself** are not present on your client at all
(Q9). For a game with no gold, no ladder, no rating, purely horizontal progression, and
opponents who are guildmates you will see again, that residual is worth **zero lines of
anti-cheat code**. Ship: *"This is a trust-based game between people who know each other. A
modified addon could see a little more than it should."*

## 0.3 Where the specialists disagreed, and the rulings

| Topic | Netcode | Economy | Match systems | Ruling |
|---|---|---|---|---|
| Sim tick | 10 Hz | "tick = 2 s" | 5 Hz, defers to netcode | **10 Hz sim tick, with nested cadences**: movement every tick, combat/build every 5th (0.5 s), Levy every 20th (2.0 s). All three specialists were describing different clocks. |
| Order latency | 2.0 s continuous | 4 s order window | 5 s beat grid | **2.0 s scheduled delay, no grid.** A grid costs latency and buys nothing; the module send bucket already coalesces a spammer to ~4 s, landing inside the band economy tested. |
| Match clock | 45 min wall cap | 300 s | 240 s | **300 s of active sim.** Economy has data: at 240 s only 44% of matches are decided by razing a keep vs 58% at 300 s — shortening the clock does not shorten matches, it converts wins into tiebreaks. Match systems' product-fit argument is defused by halt-and-resume. If matches drag, the fix is **keep HP** (a length dial that moves balance <1pp), never the clock. |
| Active-tick cap | 27,000 ticks | — | — | **3,000 ticks.** The match clock *is* the cap; 27,000 was derived from a 45-minute assumption that belongs to wall clock, not sim. |
| Fog model | full lockstep assumed | — | light cone preferred, lockstep as fallback | **Lockstep, plus the board/economy split (0.2a), plus deferred building disclosure (Q9).** A general light cone means split-authority determinism and continuous position sync over a lossy 255-byte channel — a different and much more expensive architecture. Reduced to one provable special case it costs three messages a match. |
| Modifiers on the wire | intent only | — | baked per-deploy coefficients | **One anonymous coefficient vector at handshake**, not per deploy. Same secrecy, 14 bytes once instead of bytes on every atom. |
| `WIRE_VERSION` | bump `"3"` → `"4"` | — | — | **No bump.** `Comm.lua:832` drops unknown modules silently, so adding `IB` breaks nothing. Ship a module-local `IBPROTO` byte inside the handshake instead, so tuning the battle never forces the guild off Loot Goblins. |
| Command validation | validate at exec tick on both clients | — | — | **Issuer validates; receiver trusts.** Follows necessarily from the private economy. |

---

# Part A — the sixteen questions

Each answer gives the decision, one paragraph of reasoning, and a confidence. Questions that
are the **owner's** call rather than an engineer's are marked **[OWNER]**, with a
recommendation anyway.

## Economy

### Q1 — Flat vs. ramping base income

**Decision: FLAT.** Levy ticks at a constant 10 per 2-second Levy tick for the entire match.
All growth comes from buildings and slotted modifiers. **Plus a new baseline rule that is
part of this answer: a 15% repel refund** — when an enemy unit dies inside *your own half* of
a lane you recover 15% (floored) of the Levy it cost to build.

**Why.** The owner's lean was right, for the opposite of the usual reason. A ramp calibrated
to deliver the same total Levy must *start below* the flat rate, and a poor opening delays
every **building** — defensive and economic alike — while barely delaying a rush, which only
needs to reach a bank threshold. Measured across 990 simulated matches per rule: ramping makes
the all-in rush the best line in the game (76–82% vs 67.5% flat) and makes the economy build
*worse* (73.6% → 57.8%). It also collapses decisiveness — matches decided by razing a keep fall
from 58% to 21–41%, pinning the median to the clock and handing the outcome to the tiebreak
ladder. It flattens decision leverage by ~30%, erasing the "when do I convert" choice entirely.
It creates the dead opening that kills downtime play: under a 3→17 ramp the first Levy Post is
affordable at 50 s versus 20 s flat. And it steals BOOM's identity, since Trade Routes, Golden
Age and Surplus *are* "my income curves upward" — if everyone gets that free, Boom becomes
"slightly more of what everyone has". Two engineering bonuses: flat income is closed-form from
the tick counter, so a client healing through a resync recomputes Levy from tick count plus its
command log with no accumulator; and flat front-loads meaning, which matters when a match can be
interrupted. The correct hybrid is the one already in the design: **flat base, with ramping
available only as a purchased building (Levy Post) or a slotted modifier (Trade Routes).** The
repel refund is added here because without it pure defence has no live path — Fortress sits at
44.2% with a 35.6pp archetype spread; at 15% it reaches 54.7% with a 24.2pp spread, without
touching the bank cap. Counterwall (Fortress) then *raises* the rate to 35% rather than being
its only source.

**Confidence: high.**

### Q2 — Cost curves

**Decision: see the full table in Part B.** Headline constants: 2-second Levy tick, 10 Levy per
tick flat, 20 Levy opening stipend, bank cap 150, keep HP 4000, 300-second match clock, lane
length 2000 units, per-lane unit cap 12 per side, slot cap 4 of 6, `x0.5` damage from units to
all structures.

**Why the shape is what it is.** The 2-second Levy tick falls out of arithmetic, not taste: a
cheap unit must be ~1 tick of income, so total match income ÷ cheap-unit cost is the number of
cheap units a match can field. At 1 s that is 300 Spears per player — unreadable. At 2 s it is
150, which measured out as a median peak of 25 concurrent units per player. 10 Levy per tick
rather than 4 or 5 buys percentage granularity, since every modifier in the pool is a percentage
and a 20% discount on a 10-cost Spear must be a clean 2. The base rate was swept: at 8/tick the
rush dominates at 83.9% because buildings cost relatively more and nobody fortifies in time; at
12/tick decisiveness collapses to 39% because everyone can afford everything. The 20-Levy stipend
exists so there is a real decision at second zero rather than at second two, and it does not
violate "both players begin from zero" — that clause is about zero *progression*. Buildings are
priced as **tempo, not attrition**: a Palisade + Arrow Tower pair costing 210 Levy buys 52 extra
seconds of survival, which at 10/tick is 260 Levy of income — a 1.24x return if you spend the
bought time and zero if you do not, which is exactly the right shape for a defensive investment.
The most important single number in the building table is the **Trap Pit at 50 Levy / 6 s build**,
deliberately below the 8–15 tick band: fortification otherwise costs 10–13 ticks of income plus
5–6 ticks of build, ~30–38 s from decision to online, and the first rush lands at 25–30 s, so at
the stated band *no defensive building can exist when the first wave arrives* and defence-by-
building is structurally impossible. The Trap Pit is affordable at 6 s and online at 18 s, and
adding trap-opening lines changed the tournament standings materially — the single best line
measured is "greedy opening + one Trap Pit + two Levy Posts" at 73.6%. Pure greed without the
trap loses. That is precisely the decision the design was looking for.

**Confidence: medium-high on the structure, medium on the specific unit and building numbers
(they are simulation output, not playtest output, and the lane cap and 2 s order delay were not
in the sweep — see Part E).**

## Modifiers

### Q3 — Affinity resolution

**Decision: affinity is a VECTOR, not a label. Kill the label entirely.** Every modifier carries
exactly 3 affinity points, spent as 3/0 (pure) or 2/1 (split across at most two types), so a
loadout always totals 15 points. Let `m` and `t` be the two players' 5-vectors over (Swarm, Boom,
Mystic, Fortress, Raider), and `W` the pentagon wheel matrix from §8 (`W[i][j] = +1` if `i` beats
`j`, `-1` if it loses, `0` if same).

```
edge = ( SUM_i SUM_j  m[i] * t[j] * W[i][j] ) / 225      -- integer numerator, [-225, +225]
myDamageMultiplier = 1 + K * edge                        -- K = 0.06 (Q12)
```

Applied as a single final multiplier on damage dealt, outside every stacking clamp. **Never shown
as a word, anywhere, including post-match.** If a readout is wanted, tint the player's own keep
banner as a blend of type colours — a colour, never a label, and self-only.

**Why.** Plurality forces a tie-break rule for the single most common build shape (2-2-1) and
creates an invisible cliff — a 3-2 build gets the full bonus, a 2-2-1 gets nothing, and the player
cannot perceive why. The bilinear form dissolves the tie problem instead of solving it: there is no
tie because there is no label. The design doc's own flagship problem case, "Turtle Bank", totals
8F/7B and simply receives 53% of Fortress's relations and 47% of Boom's — a 53/47 profile, exactly
the stated intent, with an emergent texture nobody had to author (its worst matchup is pure Boom,
its own secondary). Because the pentagon is symmetric, every row and column of `W` sums to zero,
which makes three properties free rather than fudged: a uniform 3-3-3-3-3 rainbow loadout scores
`edge = 0` against *every* opponent — neutral is a real, reachable strategic stance, not a
punishment; mirror matches resolve to exactly 0; and the opponent's edge is the exact negative of
yours, so one integer computed once drives both sides. The effect is monotone (adding a card of
type X never lowers your X-share), so player intuition is never violated, and since most 5-card
builds cannot reach 15 points in one type, the extremes soften automatically. Since the label is
never shown, formula complexity costs zero UX, so the right criterion is best emergent behaviour,
not simplest explanation. Everything is integer arithmetic on small numbers. **`K` must be a
compile-time constant bound to the protocol version, never a SavedVariable**, or the two sims
disagree. Splits are also the cheapest balance knob in the game: dilute a too-strong pure build by
making one of its cards a 2/1.

**Confidence: high.**

### Q4 — Stacking rules

**Decision: additive within a channel, multiplicative across channels, hard clamp per channel, one
rounding point. Plus a per-lane unit cap of 12 per side as a board constant.**

- **S1.** Every numeric effect declares exactly one channel from a fixed list: `unitCost`,
  `unitHP`, `unitDmg`, `dmgTaken`, `march`, `bldHP`, `bldCost`, `bldTime`, `levyTick`, `bankCap`,
  `dmgVsBuildings`.
- **S2.** Within a channel all sources (modifiers, buildings, opponent debuffs) sum as **integer
  percentage points**, then apply exactly once:
  `v = floor(base * (100 + clamp(sum, lo, hi)) / 100)`.
- **S3.** Across channels, effects multiply by construction because they touch different
  quantities. **No quantity is ever touched twice.**
- **S4.** Clamps: `unitCost [-45,+100]` with an absolute floor of 1 Levy; `unitHP [-40,+80]`;
  `unitDmg [-40,+60]`; `dmgTaken [-40,+40]`; `march [-40,+50]`; `bldHP [-50,+80]`;
  `bldCost [-50,+100]`; `bldTime [-50,+100]`; `levyTick [-30,+60]`; `bankCap [-50,+150]`;
  `dmgVsBuildings [-50,+100]`. The Q3 wheel multiplier applies **after and outside** every clamp.
- **S5.** `[Rule]` modifiers never stack numerically, they **arbitrate**. At most one "free
  deployment" effect and at most one "bypass" effect may fire per event, evaluated in ascending
  modifier-ID order. A non-firing effect does not consume its counter.
- **S6.** **No effect may compound.** Anything described as compounding becomes a bounded linear
  ramp with an explicit per-tick step and a ceiling. No effect may multiply a quantity by a factor
  derived from that same quantity.
- **S7.** All rounding is `floor`, once per channel per evaluation. Never chain floors, never
  introduce a second rounding point — that is the classic lockstep desync.
- **S8.** Kill attribution for non-unit damage (Trap Pit, Arrow Tower, Ward reflect, Miasma decay)
  credits the **owner**, so Blood Tithe and War Drums fire off them. Deliberate, and a good
  Raider/Mystic synergy.

**Why.** Additive-within-channel is not chosen because it is safer — for reductions it is actually
*more* generous than multiplicative (−20 and −40 additive is −60%, multiplicative is −52%). It is
chosen because a single summed integer per channel can be clamped, logged and reasoned about, and
because one clamp is the only thing that bounds an open-ended card pool as it grows. Integer
percentage points with a single floor is also the determinism-correct choice: no float accumulation
and no order-dependent rounding. Cross-channel multiplication is unavoidable — cost and HP
genuinely multiply into effective HP per Levy — which is exactly why the abuse analysis had to be
done in derived terms, and doing it that way is what surfaced the quadratic problem in 0.2(b) that
no per-channel clamp can reach. **The lane cap is the single most important balance lever in the
entire modifier layer** and should be treated as a board constant, on the same footing as lane
length, not as a tuning number.

**Confidence: high on the rules; medium on the specific clamp values and on 12 as the cap.**

### Q5 — `[Rule]` modifier count

**Decision: ~1/3 of the pool, but the ratio is the wrong lever. Classify by implementation surface
and ban the top tier outright.**

| Tier | Definition | Cost | Examples |
|---|---|---|---|
| **0** — render | Changes what is drawn, not what is simulated | ~nil | Veil, Divination, Omen |
| **1** — trigger | An existing event grants a resource. One hook, one number | low | Plunder, Blood Tithe, Counterwall, Conscription |
| **2** — state | A persistent flag checked in one place | medium | Deep Foundations, Golden Age, Tide of Bodies |
| **3** — agency | Grants the player a **new input** or a **new object** | high | Scorched Earth, Ley Line, Investment, Caravan, Boomtown |

**Hard rule: zero Tier-3 modifiers, ever, in this architecture.** Every Tier-3 card needs new
targeting UI, a new wire message at an arbitrary moment against a 10-token bucket refilling at
1/sec shared with the rest of the addon, a variable-payload input rather than a compact ID, and a
new failure mode when that input is refused mid-encounter by the comms lockdown — which is the
exact moment this addon exists to serve. A refused input in a deterministic sim is either a
divergence or a silently robbed player. Cutting the four Tier-3 cards removes more risk than every
other cut combined.

**Ten cards are cut, taking the pool from 40 to 30 (6 per type):** Ley Line (Tier 3, highest
implementation risk in the pool — continuous in-transit positions plus targeting UI plus an
arbitrary-moment input); Scorched Earth (Tier 3, variable-amount input, unbounded — burn 2000
banked Levy and delete a lane — and it introduces direct damage into a game that otherwise has
none); Investment (Tier 3, plus a 45-second real-time timer that will routinely straddle a pull;
its fantasy is already covered by Surplus and Trade Routes); Caravan (Tier 3, new building — see
Q8); Endless Ranks (ambiguous, the largest single contributor to the 10:1 stack, and a *pro-loser*
engine — feeding a lane generates free units which funds feeding the lane); Hex (near-duplicate of
Discord, and its "window" creates no mind game in a game where the victim cannot react); No Retreat
(damage scaling on current HP is order-dependent within a tick, and invisible to a player who
cannot read lane-scale HP bars); Bulwark Line (Spears +40% HP is dead in most matchups and
oppressive in one — textbook dead-or-dominant); Watchfires (needs a range model only Arrow Tower
has, and it is a Mystic information card wearing a Fortress jersey); Rickety Scaffolds (buildings
are anti-identity for the archetype that must win in 90 seconds).

**Five are converted `[Rule]` → `[Stat]`, losing no behaviour and removing real risk:** Press-Gang
(already just two stat deltas — mislabelled, zero work); Surplus (literal compound interest, 1% per
tick over 200 ticks is 7.3x — becomes "+1 Levy/tick per 100 banked, ceiling +10/tick"); Raiding
Party ("may bypass" implies agency or RNG, both bad — becomes "Horses march 40% faster and take 60%
less damage from buildings"); Boomtown (Q7); Omen is *retargeted* rather than converted (Q9b).

**Result: 10 `[Rule]` of 30. Swarm 2, Fortress 2, Boom 1, Raider 2, Mystic 3.** Two deliberate
asymmetries: Mystic gets 3 because all three are Tier 0 — they change what is drawn, not what is
simulated, so they are the cheapest cards in the pool. Boom gets 1 because Boom's identity genuinely
lives in thresholds and curves, which are stat-shaped by nature; forcing a rule onto it would be
decoration.

**Why not a flat quota.** A flat 2-per-type quota gives the same headline number but guts Mystic —
whose entire identity is "changes how things work" — while sparing Surplus and Investment, the two
most dangerous cards in the pool. Sorting by implementation surface lands on the same ~1/3 from an
honest direction and produces a rule the implementer can apply to cards that do not exist yet.

**Confidence: high.**

### Q6 — Pool size and drafting

**Decision: 30 at launch (6 per type). 10 unlocked at the start, all `[Stat]`, no `[Rule]` in the
starting set. One card per 2 matches played, win or lose. Fixed designer-authored unlock order.
Free choice, not drafted.**

Suggested starters, two per type: Breeding Pits + Scent Trails, Bastion Walls + Iron Discipline,
Trade Routes + Master Masons, Sappers + War Drums, Ward + Miasma.

**Why.** Ten cards gives 252 possible loadouts — plenty — while making it *impossible* to go
pure-anything on day one, so a new player's first builds are necessarily hybrids. That teaches
that mixing is normal and chasing a type is not a requirement. `[Rule]` cards then arrive as the
reward, aligning the unlock curve exactly with the complexity curve. Never start with fewer than 5
(you could not fill a loadout) and never with exactly 5 (your first loadout would be forced).
Unlocks must never be gated on **winning**: in a 20-person guild where everyone knows each other's
record, a losing streak compounding into a card deficit is corrosive. A **fixed order** buys
something more valuable here than novelty — two guildmates who have played the same number of
matches own *exactly the same collection*, so "he has better cards" becomes structurally
impossible, which is the strongest available defence of the "both players always start equal"
promise. Free choice over drafting for four reasons in priority order: the loadout is set during a
30-second lull, and a draft is another interaction step plus 3–5 more messages through a bucket
that may be in hard lockdown; a real draft must be synchronised between both players, an entire
extra protocol on top of the netcode shim that is already one of the two hard parts; the pillar
"your identity emerges from what you gravitate toward" requires **repeated deliberate choice**, and
randomising the loadout severs exactly the feedback loop the affinity system is built on; and the
doc already presumes saved loadouts, which presumes free choice. Hold **Blind Draft** as a named v2
queue mode once the sim is proven and the meta needs shaking. Wire cost is a non-issue — 30 cards
fit in 5 bits — so pool size must never be influenced by message size. But **do put a hash of the
modifier table in the handshake**: two players on different addon versions have different tables and
would desync instantly, and `Comm.lua:818` already has the polite-refusal pattern to reuse.

**Confidence: high.**

### Q7 — Cap inviolability (Boomtown) — **[OWNER]** (mild)

**Decision: the cap is soft. It is a number a modifier may raise — by at most +1, from at most one
source, clamped to `[4, 5]` — and Boomtown is the only card that does it. Boomtown converts from
`[Rule]` to `[Stat]` ("+1 building slot"). It is not in v1.**

**Why.** "Six slots, four usable, so something is always undeveloped" is a *fiction constraint*
doing real mechanical work: it is what forces the opening guess. But an inviolable cap makes
Boomtown unshippable, and Boomtown is the clearest expression of Boom's fantasy in the pool.
Implemented as a clamped integer with a no-stacking rule, the card is Tier 2 — one flag checked in
one place, read by the build validator, fully deterministic, and it crosses the wire as nothing at
all (a fifth `BUILD` command is self-evidently legal to the receiver, because the receiver does not
validate the opponent's builds anyway under 0.2(a)). The reason it is not v1 is Q5's starting-set
rule, not risk. The reason to allow +1 and never +2 is that at 5 of 6 the guess still exists (one
slot is still empty); at 6 of 6 it does not, and the opening mind game the design rests on
disappears for one player. This is marked **[OWNER]** because "is the cap part of the game's
identity or just a number" is a taste call — but the recommendation is unambiguous: soft cap, +1
maximum, forever.

**Confidence: high on the mechanism, medium on whether the owner wants the cap breakable at all.**

### Q8 — Building unlocks (Caravan)

**Decision: no. The entire building catalogue is available to everyone, always. No modifier unlocks
a building. Caravan is cut.**

**Why.** This is forced by 0.2(a), not by taste. Under the shared-board model both clients simulate
both players' buildings, which means the catalogue must be a shared constant that every client
implements in full. A modifier-gated building means every client must ship, simulate and render a
building it may never be able to build — the code cost is identical to shipping it for everyone,
and the *only* thing the gate buys is that one player is denied an option. That is a pure loss.
Worse, it breaks the "both players always start equal" pillar in a way modifiers do not: a modifier
changes numbers, an unlocked building changes the *option space*, so an opponent with Caravan is
playing a game with an extra verb. If the high-yield-fragile-economy fantasy is wanted, it belongs
as a **priced variant in the shared catalogue** (a cheaper, higher-yield, lower-HP Granary anyone
may build), reached by choice rather than by card. Cutting Caravan also removes the last Tier-3
card from Boom.

**Confidence: high.**

## Match systems

### Q9a — Fog of war: the disclosure model

**Decision: fog is message policy first, render policy second. Nothing is hidden at draw time from
data the client holds.**

Default vision, from your point of view, no modifiers:

| Object | What you see |
|---|---|
| Your own board | Everything, exact |
| Enemy keep | Position and exact HP, always, from tick 0 |
| Enemy units in **your** half (`x < 1000`) | Full: type, count, HP, position |
| Enemy units in **their** half | Nothing individual. One per-lane **muster bar**, 3 buckets (clear / pressure / heavy), driven by total marching HP in that lane |
| Enemy buildings, not yet disclosed | **Nothing — not even that the slot is occupied** |
| Enemy buildings, disclosed | Slot, identity, exact HP, permanently |
| Enemy Levy / bank / income / spend | **Never, under any modifier, ever** |
| Enemy loadout | **Never — it is not on your client** |

Building disclosure triggers, any one, permanent for the match: contact (damage exchanged with
anything of yours); it fires on you; it is destroyed; Divination; a Shrine reveal pulse (occupancy
only). Triggers 4 and 5 are suppressed by Veil; buildings under construction are never revealed by
4 or 5.

**Deferred building disclosure — the one place the light cone is worth its complexity.** A `BUILD`
command is **withheld from the wire** until the opponent first deploys into that lane; at that
moment all of that lane's builds, past and future, are transmitted with their original exec ticks
and spliced in by the existing rollback path. A lane the opponent never touches stays dark all
match. This is provably a no-op on prior state — the receiver had no entity of theirs anywhere near
that lane, so nothing in its history could have been affected — and it is what preserves the design's
stated opening mind game against a memory-reading client. Three conditions make it airtight:

1. **A building may be deferred only if its effect is confined to its owner's own half.** Palisade,
   Arrow Tower, Trap Pit, Watchtower, Levy Post, Granary and Redoubt all qualify. Smithy, Stables
   and Fletcher buff units that march into the *enemy* half, so they are disclosed at issue time.
   This is a per-building boolean in the catalogue, not a special case in the sim.
2. **No deferrable building's damage may reach past the midline.** Arrow Tower's damage range is
   clamped so that from the front slot at 700 it reaches at most 1000. Watchtower's *vision* range
   may exceed this because vision is render-only.
3. **The disclosure message is sent unconditionally, even when empty** (a `C` batch with `n = 0`),
   so its timing carries no information about whether you built anything.

**Every modifier gets a disclosure class fixed at design time.** PRIVATE — touches only your own
economy, costs, build times, bank or your own vision; never crosses in any form (all of Boom, plus
Breeding Pits, Press-Gang, Conscription, Counterwall, Rapid Masonry, Granary Reserves, Plunder,
Blood Tithe, Veil). BAKED — folded into the anonymous coefficient vector at handshake (0.2a).
EFFECT — Miasma and Discord cross as unnamed effect events ("TAX +8% for 30 s"). ANNOUNCE —
Divination and Omen, deliberately self-disclosing (Q9b). **Zero modifiers cross the wire as a name
or an ID, ever.**

**Determinism guard, mandatory:** vision state is derived, never authoritative. No sim branch may
read a vision value. Enforce structurally — the vision module lives in its own file which the sim
file never `require`s, and every vision accessor is named `View*`. Checkable by grep, matching this
codebase's existing review style (`CONCURRENCY.md` §1.2 uses the same technique).

**Why.** The question's premise — "hidden information must never cause the two sims to diverge" —
is correct for naive lockstep but escapable for the information that actually matters. The two
things the design names as inviolable, the loadout and "which lane did you leave soft", are both
things the opponent's sim provably does not need until they act. Your sim needs their units' spawn
tick, type, lane and stat deltas; it never needs their Levy, their bank, their income, or the reason
their Spear has more HP. Once that is noticed, hiding stops being a rendering promise and becomes an
**absence**, which is the only kind of hiding that survives a modified client. The coefficient
approach has a second payoff nobody planned: sending a resolved number instead of a card ID means
there is *one* implementation of "apply +40% HP" rather than two implementations of "compute what
Bulwark Line does" that must agree bit-for-bit — so it is strictly **more** desync-resistant than
exchanging loadouts. Hiding building occupancy entirely, rather than showing fogged silhouettes, is
what preserves the opening: if occupancy is visible the attacker does not guess which lane is soft,
he reads it — and it is simultaneously what gives Divination and Veil something real to fight over.

**Confidence: high on the model; medium on deferred disclosure surviving contact with the
implementation — it is explicitly scheduled after the netcode is proven (M6), with "send builds
live and accept the leak" as the standing fallback.**

### Q9b — How the Mystic and defensive information modifiers layer on

**Decision: two independent axes, so no modifier does two jobs.** *Unit vision* is **temporal** —
how early you see a wave; default is your own half plus the muster bar. *Structure vision* is
**spatial** — what is in their slots; default is nothing until touched.

| Source | Effect | Self-announcing? |
|---|---|---|
| **Watchtower** (front) | In its own lane only: enemy units fully visible from the midline out to their front slot. Dies with the building | Yes, on completion |
| **Shrine** — reveal pulse (back) | Every 20 s for 3 s: all enemy units in all lanes at full detail, plus enemy building **occupancy only** | Yes — "you were scanned" |
| **Divination** (Mystic `[Rule]`) | All **completed** enemy buildings: slot + identity, continuously, including rebuilds. **Never HP.** Never buildings under construction | Yes, at tick 0, with a persistent "you are being scried" mark |
| **Omen** (Mystic `[Rule]`) | Every enemy deployment announced the instant it is ordered: **lane + count only, never unit type** | Yes, at tick 0, persistent mark |
| **Veil** (Mystic `[Rule]`) | Your buildings emit no reveal-on-firing and are excluded from Divination and Shrine pulses. **Contact reveal still applies** | **No** |
| Hex, Discord, Miasma, Ward | No vision effect. Consequences felt, names never seen | n/a |

**One line teaches the system: information modifiers announce themselves the first time they act.
Seeing costs being seen.** Veil is the sole exception because concealment is implemented as
*silence* — a refusal to send emits nothing — which makes Veil the sneakiest tool in the game,
exactly right for it. **Conflict resolution is one rule, not a matrix: Veil beats every reveal,
absolutely.** A diviner facing Veil gets an empty scry, learns "I am against Veil" and nothing else
— inference, not sight, and precisely on-theme. Veil's scope is **buildings only**; it never
conceals units.

**Two balance amendments made as part of this answer.** (1) **Omen reveals lane and count, not unit
type.** As written it has no counter anywhere in the 30-card pool and would erase the
Spear/Horse/Bow read; stripping the type keeps it strong (you know where and how much) while leaving
the composition mind game alive, and removes the need to invent a counter-card for v1. (2)
**Divination excludes buildings under construction**, preserving the "is that wall up yet?" tension,
which is the sharpest thing about a 10-second build time.

**Post-match recap: reveal the opponent's final board — buildings, positions, what killed what —
but never their loadout.** Instead list the *effects* you actually encountered ("their Spears had
~40% more HP", "their units marched faster after a kill"). This is technically forced, since the
loadout is not on your client, and strategically correct: if loadouts were readable post-match the
fog would erode inside a small guild within a week.

**Why.** The two-axis split is what stops the information cards from collapsing into "the
see-everything pick", and it assigns each a distinct job: Watchtower is the defender's early
warning, Divination the attacker's target selection, Omen the tempo read, Veil the counter to the
attacker's tool, Shrine a non-Mystic on-ramp to the same fantasy. Making reveals self-announcing is
the balance cost that stops Mystic being strictly better — it converts an information advantage
into a legible social signal and hands the scried player a genuine counter-read ("they spent slots
on eyes, so they are light on defence"). It is also honest with the wire: under the disclosure
model, Divination and Omen literally *are* requests for the opponent's client to send more, so
announcing is not a flourish, it is what the implementation does.

**Confidence: high. (All of Q9b is v1.1+; nothing here ships in the first build.)**

### Q10 — Timeout resolution

**Decision: on the clock, the player who came closer to winning wins. There is no defensive
victory.** At the hard cap, evaluate in order; first non-tie decides.

1. **Enemy keep HP removed** — cumulative, not current, so repairs cannot erase it. Higher wins.
2. **Enemy building slots destroyed** — cumulative over the match, front and back count 1 each.
   Higher wins.
3. **Deepest penetration achieved**, summed over three lanes, using *greatest depth ever held for
   ≥ 5 consecutive seconds*, never a final-tick snapshot. Per lane: 0 = never reached their front
   slot; 1 = held `x ≥ 1300`; 2 = held `x ≥ 1500`; 3 = held `x ≥ 1700`. Max 9. Higher wins.
4. **Your own keep HP remaining.** Higher wins.
5. **Draw.** A draw pays exactly what a loss pays, so double-turtling is never worth farming.

**Unit kills are deliberately never a tier. That is the pure-turtle exploit and it must not exist
anywhere in the ladder.**

**Show the score from the 60-second mark** — a live "ahead / behind / level on the clock"
indicator. This is the anti-turtle mechanism doing its work *during* the match rather than only at
resolution, and it produces the endgame beat the design wants: the player who is behind is forced
to commit in the last minute. **No overtime, no sudden-death ramp** — a hard, predictable cap is a
product requirement for a game that exists to fit between pulls.

**Why.** Every scheme that measures anything other than progress toward the win condition is
gameable by a player who never attacks, because defence is cheap in this economy and "survive four
minutes" is a far easier goal than "raze a keep". Anchoring the ladder to the stated win condition
and ordering the tiers by decreasing proximity to it makes the exploit *structurally unreachable*
rather than patched out. Walk it: Anvil vs Anvil, neither attacking, ties T1–T3, ties T4 on equal
keeps, draws — correct, nothing happened. Anvil vs a rush that was repelled but broke one Palisade
and twice reached a front slot: the rush wins at T2 — correct, the aggressor who made progress beats
the defender who made none. Can a turtle reach T1? It must reach the keep. T2? It must destroy a
building, and Arrow Tower, Trap Pit, Counterwall and Ward all kill *units*, not buildings. T3? It
needs units past the enemy front slot. **Every tier above 4 requires offence; there is no path.**
Measuring penetration as a *held* maximum rather than a snapshot removes the coin-flip where a
marching wave happens to be across the line at t=239, and the 5-second hold stops a suicide deploy
buying a tier. **The constraint this places on the economy: a Fortress that repels the first two
waves must have a real conversion window — roughly the final 90 seconds, funded by repel refunds
and freed slots.** The ladder is only fair if that window exists, and Q1's 15% baseline refund is
partly there to fund it.

**Confidence: high.**

### Q11 — Tick rate and match length

**Decision: three separate clocks, all integer multiples of one counter. Do not conflate them.**

| Clock | Value | What resolves on it |
|---|---|---|
| **Sim tick** | **100 ms (10 Hz)**, integer counter from 0 | Movement, command execution, event ordering |
| **Resolve tick** | every **5th** sim tick (500 ms) | Combat, building construction progress, ability triggers |
| **Levy tick** | every **20th** sim tick (2.0 s) | Income, bank cap |
| **Order delay** | **20 sim ticks (2.0 s)** | Orders issued at tick `t` execute no earlier than `t + 20` |
| **Match clock** | **3,000 sim ticks (300 s) of ACTIVE sim** | Paused time does not advance the counter |

The sim is driven by **one `OnUpdate` accumulator** (`acc = acc + elapsed; while acc >= 0.1 do
step() end`), **never** by `C_Timer.NewTicker` — `C_Timer` is frame-quantised, drifts, and a loading
screen swallows an unbounded number of firings. Per-frame catch-up is clamped to 25 ticks. The
renderer interpolates positions between sim ticks so motion never looks steppy. Ship exactly **one
match length** in v1; keep a `matchTicks` field on the wire so v2 can add presets without a protocol
bump, but do not turn it on — presets fragment a tiny population and Boom against a 2-minute match
is a different balance problem.

**Amend Part III's wording: this is not lockstep.** It is **delayed-input deterministic simulation
with bounded rollback**. True lockstep stalls tick N until both players' inputs for N are in hand;
on this platform a stall lasts for a boss fight. The sim **never stalls** — it free-runs and repairs.

**Why 10 Hz.** 10 Hz gives 3,000 ticks for a full match, smooth-enough marching for an explicitly
no-micro idle game, and is trivially cheap (~50 entities × 10 Hz ≈ 10k Lua ops/sec). It also lets
the tick index fit in **3 base-36 characters** (46,655 ticks = 77 minutes of active sim), which is
what makes the 6-byte command atom possible. 20 Hz doubles the cost for no perceptible benefit and
halves that headroom; 2–5 Hz makes marching visibly chunky and forces coarse damage granularity, and
buys nothing on the wire — **wire cost is per command, not per tick.** The nested cadences exist
because the economy was calibrated on a 2-second income tick and combat on the same beat; running
combat at 2 Hz preserves every calibrated ratio exactly while keeping all damage and HP integers and
putting no player-visible event on a boundary coarser than 0.5 s.

**Why 2.0 s of order delay, surfaced as a game mechanic.** 2 seconds is 6–20× typical addon-message
latency, which makes late arrival rare rather than routine. Because the design's rhythm is "set your
moves, let them resolve", 2 s of order latency is invisible as netcode and reads as flavour —
**"orders take time to reach the field", mustering time.** Units spend the window visible, inert
and untargetable. Effective delay at send time is
`E = myTick + 20 + max(0, opponentAheadBy) + ceil(queueDelay*10)`, clamped to 40 ticks; if the
estimate exceeds 40 you are in a degraded network state — do not send, halt and warn. The clamp
exists because the **local send bucket, not the network, is the real latency source** when the addon
is busy.

**Why 300 s and not 240 s.** See 0.3. The measured tiebreak rate is the deciding evidence, and
halt-and-resume defuses the "an encounter eats the match" argument that motivated 240. **If matches
drag in playtest, lower keep HP, never the clock** — keep HP moved every archetype's win rate by
under 1pp across a near-2× sweep while moving the median from 242 s to 262 s. It is a pure length
dial; the clock is not.

**The concrete look-away guarantee this produces**, which is the game-feel property that matters
most: the fastest possible keep kill is a 3-Horse opening — 90 Levy is affordable at t=14 s, deploys
at 16 s, arrives at 26 s, and chews 4,000 keep HP at `3 × 36 × 0.5` per resolve tick, finishing at
**~63 s**. Eight surviving Spears raze a keep in 25 s. So **no opening can end a match before ~60
seconds, and an unwatched lane gives you ~37 seconds of chewing to answer it.** That is the number
to protect in every future tuning pass.

**Confidence: high on the clock structure; the 300 vs 240 choice is flagged for the owner in Part E.**

### Q12 — Type balance tuning — **[OWNER]** (taste)

**Decision: `K = 0.06`, i.e. the wheel is worth ±6% damage dealt at maximum focus, applied as a
single final multiplier outside every clamp. Recommended band 0.04–0.08.**

**Why, and why it is the owner's call.** The design says the matchup should be a "quiet global
modifier — noticeable but not decisive". How quiet is quiet is a feel judgement, not an analysis
result. What analysis *can* say is where the boundaries are. Below ~0.04 the wheel is noise: it
disappears under the variance of which lane you guessed right, and the fiction in §8 stops being
legible in play. Above ~0.10 it starts to decide even matchups, and since **neither player knows
their own label or their opponent's**, a decisive wheel is an invisible coin-flip — the worst
possible property for a system nobody can see. 0.06 sits where a focused build feels a consistent
lean over a five-minute match without any single engagement being obviously "lost to the wheel". Two
implementation constraints are not negotiable regardless of the value chosen: `K` is a
**compile-time constant bound to the protocol version, never a SavedVariable** (a mismatched `K`
desyncs the board instantly), and it applies **after and outside** the Q4 clamps, so nobody can
clamp away a bad matchup. Note also the scale check: the worst *stacking* abuse found in the pool
before the lane cap was a 10:1 exchange rate — the wheel is not in the same universe, which is the
correct relationship between a global lean and a build decision.

**Confidence: high on the mechanism and the band, medium on 0.06 specifically. Play it and move it.**

## Multiplayer

### Q13 — Players per match

**Decision: 1v1 only. Not a v1 limitation to be lifted soon — a v3-at-earliest item.**

**Why.** Three costs scale badly and one is architectural. Message volume scales with participants
against a bucket shared with every other module. The shared board doubles or triples in entity count
and hash surface. But the real reason is that **1v1 is what makes the board/economy split in 0.2(a)
clean**: with exactly two players the board is exactly two halves, disclosure has exactly one
counterparty, "the host resumes" has exactly one arbiter, and the void path has no partial states.
Teams introduce a third question — what happens when one member of a team is muted and the other is
not — for which no answer is both fair and simple. FFA additionally requires a lane topology the map
does not have. `CONCURRENCY.md`'s seat model is per-module and per-person, and it already supports
exactly what is needed: one match at a time per person, unlimited concurrent matches around them.

**Confidence: high.**

### Q14 — Matchmaking specifics

**Decision: matchmaking IS the shipped `SCOPE.md` + `CONCURRENCY.md` session model. Write no new
matchmaking. Delete the "available to fight" heartbeat from §3 of the design doc.**

The flow, entirely in existing machinery:

1. Player opens the battle dialog, picks a loadout and a **scope** via `PG.UI.ScopePicker`.
   `PG.IB.SCOPES = { group = true, guild = true, public = true }` — but see the v1 cut list; only
   `group` ships first.
2. **Pre-flight gate** (netcode 1b): refuse if `PG.Comm.Locked()` is already true; refuse if
   `select(2, IsInInstance())` is `"pvp"` or `"arena"`; refuse if
   `C_ChallengeMode.IsChallengeModeActive()` (existence-guarded and `pcall`ed — absent means allow).
   Allow `"raid"` and `"party"` with the banner.
3. `hostOpen` mints a token via `PG.NextToken()` and broadcasts `IB|OPEN|<token>|…|<scope>`.
   The host takes the seat (`PG.Session.Claim`). Invariant I4 applies: hosting is never blocked by
   another module.
4. Discovery is unchanged from `SCOPE.md` §6.3 — group scope raises a `PG.UI.Ask` popup, guild scope
   raises one within the invite budget (1/sender/60 s, 3 per 5 min), public scope only ever lands in
   the launcher's *Open games* list and constructs no state until an explicit **Join** click.
5. The first accepter whispers `IB|JOIN|<token>`. **First JOIN wins**; every later one gets a polite
   refusal whisper. This is the only new rule in the whole flow, and it exists because the battle is
   1v1 while the shipped games are N-player.
6. Host whispers `IB|S|<token>|<proto><seed><coefVector><affinityVector><tableHash>`; the client
   replies with its own `IB|S`. Both validate the table hash and refuse politely on mismatch,
   reusing the existing version-mismatch string pattern at `Comm.lua:818`.
7. Both start at tick 0. Match traffic is **all whispers** — `SCOPE.md` §2.3 already requires private
   1:1 traffic to use `WHISPER` in every scope, and a 1v1 battle is entirely private traffic. Only
   `OPEN` is ever broadcast.

**Why the heartbeat must go.** A standing "available to fight" broadcast is a per-player periodic
message on a channel shared by up to two hundred guildmates against a 60/min prefix budget. Twenty
opted-in players at one heartbeat per 30 s is 40 messages/min of pure advertising before anyone
plays anything — and it would be visible to, and would starve, Loot Goblins. The shipped
invitation model already solves discovery with **one message per attempt** and comes with the invite
budget, the DND gate, the ignore filter, the launcher list, the trust predicate and the supersession
rule already written and shipped. Reusing it is not a shortcut; it is the correct answer, and it is
what the master doc's §3 was reaching for without knowing the machinery existed.

**Confidence: high.**

### Q15 — Disconnect and grief handling

**Decision: one terminal state — VOID. There is no forfeit win, ever.**

| Situation | Detection | Result |
|---|---|---|
| Opponent muted (encounter / M+ / PvP) | 2 missed heartbeats, 12–18 s | **Halt.** Not an error |
| Opponent zoning / loading screen | local `PLAYER_ENTERING_WORLD`, or 2 missed heartbeats | **Halt**, reason `Z` |
| Pause budget exceeded | 12 min single, 20 min total, 45 min wall clock | **Void** |
| Opponent silent with no halt context | **300 s** — reuse `HB_GIVEUP_WIDE` verbatim | **Void** |
| Opponent logs out or `/reload`s | the 300 s path | **Void** |
| Local `/reload` or logout mid-match | own state is gone | **Void.** No reconnect in v1; the live match is never written to SavedVariables |
| Unrepairable desync | board hash mismatch that survives full-log replay | **Void**, both sides, with a debug dump behind `/pg debug` |
| Either player cancels | explicit `V` message | **Void** |

A void means: **no winner, no loser, no rating, no ledger row, and unlock credit paid pro-rata.**
Count credits in halves — a completed match is 2 credits, a void is 1, an unlock costs 4. Record the
abandonment locally for the player's own information only; never surface another player's abandon
count anywhere, in any UI.

**Why there is no forfeit.** Over a lossy channel with no server, "quit" and "muted" are literally
indistinguishable — the observable evidence is identical. Any forfeit rule therefore punishes a real
player for their raid pulling a boss some fraction of the time, in a game explicitly designed to be
played in a raid. The only honest verdict is a void, and the only reason a void is affordable is
that progression is participation-based (§0.1). **Grief is handled by making griefing pointless
rather than by detecting it**: there is nothing to win by quitting, since a void pays the quitter
less than finishing would, and there is nothing to take from the victim, since a void costs them
almost nothing. `SCOPE.md` §6.2's constants are reused unchanged, including the 150-second "they may
be in a boss fight" message, which is exactly the right copy for this game too.

**Confidence: high.**

## Presentation

### Q16 — Working title and theme — **[OWNER]** (pure taste)

**This is entirely the owner's call and nothing mechanical depends on it.** The one engineering
requirement is this: **the wire module code is `IB` and stays `IB` forever, independent of the
theme.** Keeping the wire identifier theme-free means the game can be renamed and re-skinned at any
point without touching the protocol, bumping a version, or breaking compatibility with players who
have not updated. Every user-visible string lives in the existing `PG.L` table.

**Recommendation: "Marches."** The word carries both meanings the game needs — a *march* is a
contested border territory, and it is what the units do — it fits the existing Levy/keep/palisade
vocabulary the design already uses, and it is short enough for a launcher row and a window title.
Runners-up: "The Levy", "Border Keep", "Two Keeps". The existing kingdom/keep skin is coherent with
all of them and `Theme.lua` already provides the themed window, the animated reveal stage and the
podium, so a themed post-match recap is close to free.

**Confidence: n/a — owner's call.**

---

# Part B — Numbers, tuning pass one

**Everything in this part is provisional.** It is simulation output plus arithmetic, not playtest
output. It is internally consistent and an implementer can code against it tomorrow. Expect the
unit and building tables to move after the first real match.

## B.1 Clocks and space

| Constant | Value | Notes |
|---|---|---|
| Sim tick | 100 ms | integer counter `t`, from 0 |
| Resolve tick | every 5 sim ticks (0.5 s) | combat, build progress |
| Levy tick | every 20 sim ticks (2.0 s) | income |
| Order delay `D_base` | 20 sim ticks (2.0 s) | "mustering"; clamp on effective delay 40 ticks |
| Match clock | 3,000 sim ticks (300 s) | active sim only; pauses do not advance it |
| Snapshot epoch | 60 sim ticks (6 s) | keep the last 5 → 30 s of rollback depth |
| Heartbeat | 60 sim ticks (6 s) | |
| Lane length | 2,000 units | integer positions |
| Own keep / own back slot / own front slot | 0 / 300 / 700 | |
| Midline | 1,000 | |
| Enemy front slot / back slot / keep | 1,300 / 1,700 / 2,000 | |
| Lanes | 3 | |
| Building slots | 6 (front + back × 3 lanes) | **cap 4 occupied** |
| Per-lane unit cap | **12 per side** | board constant, not a tuning number |

## B.2 Economy

| Constant | Value |
|---|---|
| Opening stipend | 20 Levy |
| Base income | **10 Levy per Levy tick, flat, all match** |
| Bank cap | **150** (Granary → 300) |
| Total Levy in a full match | ~1,520 |
| Repel refund | **15%** of an enemy unit's build cost when it dies in your own half (floor, credited at the tick of death, subject to bank cap) |
| Hard coupling | `bankCap >= dearestBuilding + 2 Levy ticks` — see 0.2(c) |

## B.3 Units

HP is expressed on a scale where damage lands every **resolve tick (0.5 s)**. All ratios are
preserved from the calibrated 2-second numbers; every value is an integer.

| Unit | Cost | HP | Dmg / resolve tick | Targets | Dmg range | March / sim tick | Lane crossing |
|---|---|---|---|---|---|---|---|
| **Spear** | 10 | 400 | 20 | 1 | 60 | 10 | 200 ticks (20 s) |
| **Bow** | 20 | 400 | 22 | 3 | 320 | 7 | 286 ticks (28.6 s) |
| **Horse** | 30 | 960 | 36 | 1 | 60 | 20 | 100 ticks (10 s) |

- **Counter multiplier: ×1.5 into your prey only** (Spear→Horse, Horse→Bow, Bow→Spear). ×1.0
  everywhere else. **No penalty term.**
- **All units deal ×0.5 damage to every structure**, including the keep. Sappers doubles this to
  ×1.0 — which is what makes Sappers a real slot rather than a stat nudge.
- Verified triangle at equal Levy (60 v 60), both directions: 6 Spear beats 2 Horse keeping 50–60
  of 60; 3 Bow beats 6 Spear keeping 60; 2 Horse beats 3 Bow keeping 60.

**Why the ×0.5 structure multiplier is load-bearing:** at full damage a 90-Levy Palisade bought only
9 seconds against an 80-Levy stack, making every defensive building strictly worse than spending the
same Levy on bodies. At ×0.5 a fortification repels ~1.5× its own cost. The existence of Sappers in
the design's Raider list is itself evidence the baseline was always meant to be poor at demolition.

## B.4 Buildings

| Building | Cost | HP | Build time | Effect | Deferrable? (Q9a) |
|---|---|---|---|---|---|
| **Trap Pit** | 50 | 800 | 60 ticks (6 s) | One-shot 2,400 damage, max 800 per target, nearest 3 | yes |
| **Watchtower** | 70 | 1,000 | 80 ticks (8 s) | 30 dmg / resolve tick, damage range 300, reveals lane (vision range 600) | yes |
| **Palisade** | 100 | 6,400 | 100 ticks (10 s) | Blocks advance, no offence | yes |
| **Granary** | 100 | 1,200 | 100 ticks | +1 Levy / Levy tick, bank cap +150 | yes |
| **Fletcher** | 100 | 1,200 | 100 ticks | Bow −30% cost in lane, +6 range | **no** |
| **Arrow Tower** | 110 | 1,400 | 100 ticks (10 s) | 85 dmg / resolve tick, damage range 300 | yes |
| **Redoubt** | 110 | 1,800 | 120 ticks | Friendly units in this lane take −30% (own half only) | yes |
| **Smithy** | 110 | 1,200 | 120 ticks | +25% friendly damage in lane | **no** |
| **Levy Post** | 120 | 1,400 | 120 ticks (12 s) | +3 Levy / Levy tick | yes |
| **Stables** | 120 | 1,200 | 120 ticks | +50% march in lane, Horse −30% there | **no** |
| **Shrine** | 130 | 1,200 | 140 ticks | Resource-independent effect (ward charge / reveal pulse) | yes |

In ticks of income the main catalogue is 7–13, inside the design's 8–15 band. **The Trap Pit is
deliberately outside it** — see Q2.

**Levy Post ROI, the sentence that makes greed a gamble rather than a default:** started at t=20 s
it is online at 32 s, breaks even at 112 s, and nets +102 Levy by 180 s and +282 by 300 s. Started
at 90 s it never pays back inside a normal match. **A Levy Post is a pure loss in any match decided
before ~112 seconds.**

## B.5 The keep

| Constant | Value |
|---|---|
| Keep HP | **4,000** (8,000 raw, since the ×0.5 structure multiplier applies) |
| Time for 8 surviving Spears to raze | ~25 s |
| Time for 3 Horses to raze | ~37 s |
| **Earliest possible keep kill in the game** | **~63 s** (3-Horse opening: affordable t=14 s, deploys 16 s, arrives 26 s) |

Keep HP is a **length dial, not a balance dial**: sweeping 800–1,500 (scaled: 3,200–6,000) moved
every archetype's win rate by under 1pp while moving the median match from 242 s to 262 s and
decisiveness from 70% to 63%. Pick it purely for pacing.

## B.6 Measured outcomes at these numbers

| Metric | Value |
|---|---|
| Match length | p10 152 s, **median 272 s**, p90 300 s |
| Decided by razing a keep | **58%** (vs 42% by the tiebreak ladder) |
| Archetype win rates (best line each) | Rush 67.5%, Balanced 49.4%, Greed 73.6%, Turtle 54.7% |
| Archetype spread | 24.2pp |
| Decision leverage (spread between variants of one archetype) | 20.9pp |
| Concurrent units per player | median peak 25, p90 54 |

**Caveats that matter.** The economy sweeps were run **without** the per-lane unit cap and at a
**4-second** order window rather than 2 seconds. Both changes should push in safe directions (the
cap only binds on the Swarm doomstack; shorter latency slightly favours reactive play) but neither
was measured. Re-sweep in tuning pass two.

## B.7 Wire — module `IB`

Envelope is the shipped one, unchanged: `<WIRE_VERSION>|IB|<mtype>|<token>|<payload>`. With the
`CONCURRENCY.md` §3.2 token (`"1a-7f3"`, 6 bytes) the envelope is **14 bytes typical, 18 worst
case**. Payload alphabet is base-36 plus a small set of uppercase codes, deliberately excluding `|`.
**No `WIRE_VERSION` bump** — `Comm.lua:832` drops unknown modules silently, and a module-local
`IBPROTO` byte inside the handshake carries battle-protocol versioning so tuning the game never
forces the guild off Loot Goblins.

**Command atom — fixed width, 6 bytes, no separators:** `EEE` (exec tick, 3 base-36, absolute) +
`K` (kind: `S`/`H`/`B` for units, `a`–`k` for the building catalogue) + `T` (target: `1`–`3` lane
for units, `1`–`6` slot for buildings) + `N` (count, 1 base-36, capped at 9 by the UI).

| Type | Payload | Bytes | Cadence |
|---|---|---|---|
| `OPEN` | as the shipped games, plus scope byte | ~35 | once, broadcast |
| `JOIN` | — | 14 | once, whisper |
| `S` start | `<proto 1><seed 4><coef 14><affinity 5><tableHash 4>` | **42** | once each way |
| `C` command batch | `<seq 2><ackThru 2><n 1><atoms 6n>` | 19 + 6n → **25** (n=1) to **67** (n=8) | ≤ 15/min |
| `H` heartbeat | `<tick 3><lastSeq 2><ackThru 2><epoch 1><boardHash 5><logDigest 4>` | **31** | 10/min |
| `X` halt | `<tick 3><reason 1>` — `E`ncounter `R`estriction `C`ountdown `K`readycheck `Z`oning `M`anual | 18 | on halt |
| `K` client clear | `<tick 3>` | 17 | on resume |
| `G` resume (host only) | `<tick 3>` | 17 | on resume |
| `N` resend request | `<from 2><to 2>` | 18 | on gap |
| `M` mismatch | `<epoch 1><boardHash 5><logDigest 4>` | 24 | on hash disagreement |
| `Q` full-log request | — | 14 | ≤ 1 per 10 s |
| `V` void | `<reason 1>` | 15 | terminal |

**Largest message in the entire protocol is a 67-byte command batch** — one third of the 200-byte
target and one quarter of the 255-byte hard limit. **Nothing is ever chunked, so nothing can straddle
a lockdown boundary.**

**Two mandatory encoding rules.** (1) The wire carries **intent only** — never outcomes, never
derived numbers, no costs, no damage, no HP. The moment a derived number crosses, one client can
"win" a disagreement without anyone noticing. (2) The **issuer validates affordability; the receiver
trusts** (0.2a). The issuing UI must render its own orders as pending and be prepared for them to
fizzle at the exec tick.

**Rates, per player, per minute:**

| Class | Typical | Worst |
|---|---|---|
| `H` heartbeat | 10 | 10 |
| `C` commands | 8 | 15 |
| resends | 1 | 3 |
| repair (`N` / `M`) | 0 | 2 |
| **total** | **19/min = 0.32/s** | **30/min = 0.50/s** |

Enforce a **module-level bucket above the Comm bucket: capacity 4, refill 1 per 4 s, for `C` only.**
All orders inside one refill window coalesce into a single batch of up to 8 atoms — a frantic
clicker is **coalesced, never throttled with loss**. Heartbeats bypass the module bucket but are
marked supersede, so a stale queued heartbeat is replaced rather than stacked. Contention check
against the 60/min prefix budget: worst-case battle 30 + `CO|HELLO` 1 leaves 29/min for everything
else; a Loot Goblins host runs ~9/min. A player simultaneously in a battle and hosting Loot Goblins
peaks at ~44/min — legal, but queue latency grows, which is exactly why `E` is inflated by the
measured queue delay. **Warn, never refuse** — `CONCURRENCY.md` I4 forbids cross-module refusals.

## B.8 Reliability

- **Sequencing:** per-sender monotonic `seq` from 1, 2 base-36 characters (1,296; a 5-minute match
  issues ~40). Receiver dedups on `(sender, seq)` and holds the **complete ordered command log for
  the whole match** — both players', ~80 entries × 6 bytes. Retaining everything is cheaper than any
  windowing scheme.
- **Canonical execution order within a tick: sort by `(playerIdx: 0 = host, 1 = client)`, then
  `seq`.** Write this down as a rule. Two commands landing on the same tick applied in two different
  orders is a silent desync.
- **Acks: no standalone ACK type exists.** The heartbeat's `ackThru` is the ack, and its `lastSeq`
  is the **watermark** — "the highest sequence number I have ever issued". A receiver holding 1..S
  therefore knows it has the sender's entire history as of that heartbeat, and since every later
  command has `E >= hbTick + 20`, its **confirmed-safe tick is `W = hbTick + 20`**. Above `W` the sim
  runs optimistically and is known-unconfirmed. **This is why there is no empty-turn heartbeat: there
  is no turn.** A per-turn confirmation at even 1 Hz would consume the entire prefix budget for one
  player before any commands — and it would deadlock under mute, in the exact situation it exists to
  handle.
- **Resend policy.** (i) Receiver-driven, primary: a gap is visible on the very next inbound `C`
  (each carries its own seq) → send `N` immediately; the sender replies with a `C` carrying those
  atoms verbatim, same seq, same `E`. (ii) Sender-driven backstop: a command unacked after 2
  heartbeats (12 s) is resent once, piggybacked. (iii) After 4 heartbeats unacked, stop — do not
  spend budget on a peer that is not listening; let the board hash adjudicate.
- **Bounded rollback is what makes all of this cheap.** Snapshot the full board every epoch (60
  ticks), keep the last 5 (30 s, ~60 KB). A command arriving with `E < currentTick` is **not
  dropped**: if `currentTick - E <= 300`, rewind to the snapshot at or before `E`, splice the command
  into the log, re-simulate forward (300 ticks × ~50 entities is sub-millisecond) and let the render
  snap. Only a command older than the snapshot depth is unrepairable, and that escalates.
- **Relationship to `SYNCQ`/`SYNCOK`/`SYNCNO`: reuse the shape, not the code.** The shipped protocol
  replays *original messages* to a client that fell behind, which is exactly right here too. The
  battle's version is `Q` → the peer replays its **entire command log** as `C` batches of 8 atoms —
  ~80 commands is 10 messages, inside the 10-token burst. Reuse `SYNC_COOLDOWN = 10` verbatim. The
  `SYNCNO` equivalent is **void the match**: if the log cannot be replayed, there is no spectator
  mode to fall back to.

---

# Part C — the v1 cut list

**Principle: the first playable build exists to prove the deterministic sim and the netcode. Nothing
else earns a place in it.** Two thirds of this design is content that can be added later at zero
architectural risk, and adding any of it early makes the two hard problems harder to debug.

## C.1 First playable — internal only, not shipped

| Ships | Cut |
|---|---|
| 3 units (Spear, Bow, Horse) | Everything else below |
| **6 buildings**: Palisade, Arrow Tower, Trap Pit, Watchtower, Levy Post, Granary | The other 5 (Fletcher, Redoubt, Smithy, Stables, Shrine) |
| 3 lanes, 6 slots, cap 4 | — |
| **Zero modifiers. No loadout screen. No type wheel.** | All 30 cards, the affinity vector, `K` |
| Flat income, repel refund, bank cap | — |
| Keep + the full tiebreak ladder | — |
| Muster bar as the only fog | Deferred building disclosure, all Mystic vision |
| Halt / resume / void | — |
| **Party scope only** | Guild and public scope |
| Placeholder UI on `Widgets.lua` | `Theme.lua` reveal stage, podium, animation |

Six buildings is not arbitrary: it is one of each role — wall, gun, trap, eye, income, bank — which
is the minimum that exercises the front/back slot tension and the "which lane did you harden"
opening. The three buffing buildings are cut partly for scope and partly because they are the only
ones that **cannot** be deferred under Q9a, so cutting them keeps the disclosure rule uniform while
the netcode is being proven.

## C.2 v1.0 — the first shipped build

Adds: the **10 starter `[Stat]` cards** (Q6) plus 10 more `[Stat]`-or-Tier-1 unlocks, so a 20-card
pool; the affinity vector and `K = 0.06`; the remaining 5 buildings; **guild scope**; the themed UI
and post-match recap; deferred building disclosure; saved loadouts.

## C.3 v1.1+

The remaining 10 cards including the Tier-0 Mystic vision layer (Divination, Omen, Veil) and the
Q9b information rules; the Shrine reveal pulse; **public scope**; Boomtown and the soft slot cap.

## C.4 v2+

Blind Draft as a named queue mode; match-length presets behind the existing `matchTicks` field; the
EFFECT wire class and the cross-economy cards it enables (Discord, and Hex if it is ever revived);
teams or FFA — v3 at the earliest, if ever (Q13).

## C.5 Never, in this architecture

**All four Tier-3 cards** — Ley Line, Scorched Earth, Investment, Caravan (Q5, Q8). **Endless Ranks**
(the 10:1 stack and a pro-loser engine). **No Retreat** (order-dependent within a tick). **Bulwark
Line** (dead or dominant). **Rickety Scaffolds** (anti-identity). **Watchfires** (needs a range model
only one building has, and it is a Mystic card in Fortress colours). **Any per-turn confirmation
scheme** (B.8). **Any anti-cheat** (0.2d). **Any in-encounter signalling fallback** — `SPEC.md` §2.12,
policy line, not negotiable.

---

# Part D — build order

Each step names the cheapest thing that proves the next-riskiest assumption, and a milestone that
either passes or does not. **Do not proceed past a red milestone.**

### M0 — The Probe *(half a day, run it tonight, in parallel with everything)*

**The riskiest assumption in the project is a platform assumption, and it costs almost nothing to
test.** A throwaway module that sends `IB|P|<n>` every 6 s and logs, to SavedVariables: the local
`InChatMessagingLockdown()` state, every send result code, every receive timestamp, and every
`PG.Safety` transition. Wear it for one raid night with one other person.

> **Milestone:** a log file showing the exact boundaries where sends start and stop being refused,
> the true refusal codes observed in the wild, and measured one-way latency and loss rate over a
> real raid evening. **Every constant in B.7 and B.8 is calibrated from this file.** If refusals do
> not behave as `SPEC.md` §2.1 describes, everything downstream changes and it is better to know on
> day one.

### M1 — Headless determinism harness *(no WoW, no UI, no network)*

The sim core as a plain Lua module, plus a test that replays a scripted command log.

> **Milestone:** the same seed and the same command log produce a **bit-identical board hash after
> 3,000 ticks**, over 1,000 randomised logs, under both Lua 5.1 and the 5.4 `luac -p` checker, on two
> different machines. Any `pairs()` in sim-affecting code is a bug and this harness is what finds it.

### M2 — The sim, playing itself

Wire M1 to the numbers in Part B. Both sides driven by scripted logs. No rendering.

> **Milestone:** 1,000 simulated matches terminate — by razed keep or by clock — with the outcome
> distribution in B.6 reproduced within a few points. **This is where the numbers get their first
> real test and where Part B starts to move.**

### M3 — Two sims, one client

Two instances of the sim in one addon session, fed the same log through a fake transport that can
drop, delay and reorder messages on command.

> **Milestone:** board hashes match at every epoch for 3,000 ticks with 10% packet loss and up to 3 s
> of jitter. Rollback repairs every late command. **This proves the reliability shim before a single
> real message is sent.**

### M4 — First playable, over the wire

Register `IB` on `Comm.lua`. `OPEN` / `JOIN` / `S` / `C` / `H` only. Party scope. Two real
characters. Content per C.1.

> **Milestone:** a complete 300-second match between two accounts, ending by keep or clock, with
> board hashes matching at every heartbeat and **measured traffic under 30 messages/min per player**.
> The first time this passes, the project's two hard problems are solved.

### M5 — Halt and resume

`X` / `K` / `G`, the pre-flight gate, the pause budgets, `V` and every void path.

> **Milestone:** start a match, pull a boss, finish the boss, resume. Both clients halt within 3 s of
> each other, the resume countdown fires, hashes match on the first heartbeat after resume, and the
> match clock shows only active time. Then repeat with a **surprise** mute (no pull timer) and
> confirm the 2-missed-heartbeat detector fires. **This is the milestone that validates §0.1.**

### M6 — Fog and rendering

The muster bar, the `View*` module with its grep-checkable separation, deferred building disclosure,
the live tiebreak score from the 60-second mark, the themed window.

> **Milestone:** a match played to completion where a `/dump` of the opposing player's board state
> contains **no building the local player has not legitimately discovered**, and the sim files
> contain zero references to any `View*` accessor.

### M7 — Loadouts and modifiers

The coefficient vector in the handshake, the table hash check, the affinity vector, `K`, the 10
starter cards, the unlock ledger.

> **Milestone:** two clients with deliberately different modifier tables refuse each other politely;
> two clients with matching tables play a full match where each side's units visibly deviate from
> baseline and **neither client's memory contains the other's card list**.

### M8 — Matchmaking and shipping

Guild scope, the launcher *Open games* row, the invite budget, the recap screen, the README honesty
sentence.

> **Milestone:** three concurrent battles plus a live Loot Goblins round in one raid, with no
> cross-session interference, no dropped Loot Goblins messages, and every `CONCURRENCY.md` invariant
> I1–I10 verifiable by the greps that document specifies.

---

# Part E — still genuinely undecided

These need the owner. Everything else above is decided and an implementer may proceed.

1. **Match length: 300 s or 240 s.** Analysis favours 300 (58% of matches decided by razing a keep
   vs 44% at 240). Product fit may favour 240. The owner raids and knows how long a downtime window
   actually is. *Recommendation: 300, and if it drags, cut keep HP rather than the clock.*
2. **Wheel strength `K`.** 0.06 recommended, band 0.04–0.08. This is a feel judgement about how
   "quiet" a quiet modifier should be, and it cannot be settled by analysis.
3. **Complexity appetite: any `[Rule]` cards in v1.0 at all?** The recommendation ships v1.0 with
   `[Stat]` cards only and holds every `[Rule]` for v1.1. That is the safe call. It also means v1.0
   ships without the cards that carry the most identity, and the owner may reasonably prefer to
   accept the balance risk to make the first shipped build feel like the design.
4. **Public scope for a 5-minute lockstep match with a stranger.** Technically supported by
   `SCOPE.md`, deferred to v1.1 here. The question is whether a game requiring five minutes of mutual
   attention from someone with no social tie should be offered at all. *Recommendation: guild and
   party only, indefinitely.*
5. **The README trust sentence.** 0.2(d) proposes shipping an honest admission that a modified addon
   can see slightly more than it should, in exchange for zero anti-cheat code. That is a product
   posture, not an engineering choice.
6. **Does "mustering" land?** 2.0 s of order delay is presented as flavour rather than latency. If it
   reads as lag instead of as a mechanic, the fix is presentational (a visible muster animation at
   the keep) not numeric — but only play will tell.
7. **Is the 3-bucket muster bar enough information**, or should the default show exact enemy unit
   counts in their own half? More information makes the game more readable and less of a guess; the
   design's whole opening rests on the guess. *Recommendation: 3 buckets, and let Watchtower be the
   answer.*
8. **Slot cap 4 of 6 with only 6 buildings in the catalogue.** "Something is always undeveloped" was
   sized against an 11-building catalogue. At 6 the cap may bind differently. Worth one look after M2.
9. **Whether a void should be visible at all.** Q15 records abandons locally and never surfaces
   them. A guild might want the social pressure. *Recommendation: never surface it — the moment a
   quit has a cost, the lockdown story in §0.1 starts to come apart.*
10. **Working title and theme** (Q16). *Recommendation: "Marches", wire code stays `IB` forever.*

---

*End. Part IV of `IDLE_BATTLE.md` is closed; the design is PID-ready. The open items in Part E are
tuning and taste, not architecture.*
