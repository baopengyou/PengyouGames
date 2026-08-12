# WoW Idle-Battle Addon — Master Design Document

*Working design reference and the foundation for a Project Initiation Document. Purpose: capture the full agreed design plus what remains open, so implementation agents solve the **how**, not the **what**. Theme, naming, and all numbers are placeholder and deliberately swappable.*

*Supersedes: Design Snapshot v1, Content Draft v1.*

---

# PART I — THE GAME

## 1. Concept

A lightweight, hidden multiplayer game that runs inside World of Warcraft, using the invisible addon chat channels so players can face off during downtime — between raid pulls, in queue, waiting on a group. Each match is a short, self-contained idle-battle: you slot a loadout of modifiers, then fight another online player across a small lane-based map. Set your moves, let them resolve, plan, repeat.

The design deliberately has **no persistent base**. The fight *is* the game.

## 2. Platform & Hard Constraints

- Built as a WoW addon (Lua).
- All player-to-player communication rides on hidden addon chat channels. **There is no dedicated game server.**
- Only players online at the same time can interact. No persistent world; nothing ticks while logged off.
- Persistent data (unlocked modifiers, saved loadouts) lives in local saved variables.
- These constraints drive the entire architecture — see Part III.

## 3. Session Loop

1. Log in. You have your collection of unlocked modifiers and a few saved loadouts. No base to tend.
2. Lock in a loadout — 5 modifier slots, a few seconds of work.
3. The addon quietly broadcasts an "available to fight" heartbeat on the hidden channel. That's matchmaking.
4. You and another available player connect; a match fires, sized to fill a few minutes of downtime.
5. Match resolves. You bank progress toward your unlock pool. Back to WoW.

Nothing persists from the match itself except that you're one card richer.

## 4. The Match

- **Players:** 1v1 assumed (teams/FFA open).
- **Start:** both players begin from zero. Always.
- **Map:** three lanes. Each lane has a **front** building slot and a **back** building slot. A **keep** sits behind all three.
- **Resource — Levy:** starts at 0, ticks up idly. Spent on troops and buildings. One pool, three ways to use it: deploy now for pressure, invest in buildings for later, or bank for a bigger swing.
- **Rhythm:** idle. Set your moves, let the tick resolve, reassess, set again. No micro.
- **Win condition:** raze the enemy **keep**, reached only by fully breaking through a lane.
- **Target length:** 3–5 minutes.

**Provisional economy baseline** (so numbers below have scale — the flat-vs-ramp fork is still open, see Open Questions):
Levy ticks at a flat base rate. Cheap unit ≈ 1 tick of income; buildings ≈ 8–15 ticks.

## 5. The Unit Roster

Three units, shared and fixed — **identical for both players**. Modifiers are the only thing that differentiates them. Small roster on purpose: a new player knows the whole army in match one, and "which unit into which lane" stays a live decision underneath the modifiers.

| Unit | Cost | March speed | Beats | Loses to | Role |
|---|---|---|---|---|---|
| **Spear** | Low | Medium | Horse | Bow | Cheap body, anti-charge, lane holder |
| **Horse** | High | Fast | Bow | Spear | Fast pressure, reaches the back slot quickly |
| **Bow** | Medium | Slow | Spear | Horse | Ranged chip, strong vs. massed cheap units |

**Triangle:** Spear → Horse → Bow → Spear.

Units auto-march down their lane and auto-engage on tick. The player's decisions are *what, which lane, when*. Buildings are valid targets — that's what makes "crack a lane" mean something.

Because the roster is a shared constant, **the way an opponent's units deviate from baseline is the information**. Their Spear marching a hair fast means they've slotted mobility, which means they're probably going early, so you brace. Real scouting depth with zero roster memorization.

## 6. Buildings

Six slots total (front + back across three lanes), with a **cap** on how many may be occupied — suggested **4 of 6**, so something is always left undeveloped. Buildings take time to construct and are destructible. **Repelling an attack in a lane frees you to rebuild there** — slots aren't spent once-and-gone, which keeps lanes swinging back and forth instead of eroding one way.

### Defensive

| Building | Effect | Natural slot |
|---|---|---|
| **Palisade** | High HP, no offense. Enemies must chew through before advancing. | Front |
| **Arrow Tower** | Damages enemy units in its lane each tick. Low HP. | Front |
| **Trap Pit** | One-time burst on the first enemy group to reach it, then spent. Cheap. | Front |
| **Watchtower** | Reveals the lane (fog), small damage. Information as defense. | Front |
| **Redoubt** | Your units in this lane take reduced damage. Buffs defense without fighting. | Back |

### Functional

| Building | Effect | Natural slot |
|---|---|---|
| **Levy Post** | Flat increase to your Levy tick. Bread-and-butter economy. | Back |
| **Granary** | Raises bank cap, trickles extra. Enables hoarding strategies. | Back |
| **Smithy** | Your units in this lane deal more damage. | Back |
| **Stables** | Units deploy to this lane with faster march; Horse costs less here. | Back |
| **Fletcher** | Bow units in this lane cost less and gain range. | Back |
| **Shrine** | Generates a resource-independent effect — ward charge, reveal pulse. | Back |

### The Keep
Always present, not placed. Sits behind all three lanes. Raze it and you win. Substantial HP so the finish isn't a coinflip.

**The core placement tension:** front is exposed and wants defense; back is protected and wants function. That's the obvious read — which is exactly why deviating from it becomes the mind game. Early Levy is thin, so you can't fortify all three lanes at once. *Which lane do I harden first*, against an attacker guessing which one you left soft, is the whole opening.

## 7. Loadout & Modifiers

**5 slots. Modifiers only — never units.** A modifier may affect **units**, **buildings**, or **resource generation**.

Each modifier carries a hidden **type affinity**. Your dominant affinity across five slots determines your hidden type. **The player is never shown a type label** — they just build, and their identity emerges from what they gravitate toward. This is what keeps players from feeling pigeonholed into a class.

Two flavors throughout: **[Stat]** tunes numbers — readable, low risk. **[Rule]** changes how something works — high identity, high balance risk. Currently ~half the pool is [Rule], which is likely too many for a first build.

### SWARM — cheap, fast, fragile; wins early or not at all

| # | Modifier | | Effect |
|---|---|---|---|
| 1 | **Breeding Pits** | Stat | All units cost 20% less Levy. |
| 2 | **Chaff** | Stat | Units cost 40% less but have 30% less HP. |
| 3 | **Scent Trails** | Stat | Your units march 25% faster. |
| 4 | **Tide of Bodies** | Rule | +2% damage per friendly unit alive in the same lane. |
| 5 | **Endless Ranks** | Rule | When a unit dies in a lane, the next unit deployed there is free. |
| 6 | **Rickety Scaffolds** | Stat | Buildings construct 50% faster, have 40% less HP. |
| 7 | **Press-Gang** | Rule | +15% Levy tick, bank cap halved. You can't hoard, only spend. |
| 8 | **Conscription** | Rule | Every third unit deployed is free. |

### FORTRESS — slow, defensive; wins by not losing

| # | Modifier | | Effect |
|---|---|---|---|
| 1 | **Bastion Walls** | Stat | Defensive buildings gain 50% HP. |
| 2 | **Iron Discipline** | Stat | Your units take 25% less damage in your own half of a lane. |
| 3 | **Counterwall** | Rule | Fully repelling an attack in a lane refunds a chunk of Levy. |
| 4 | **Deep Foundations** | Rule | Back-slot buildings are immune until that lane's front slot falls. |
| 5 | **Rapid Masonry** | Stat | Destroyed slots rebuild at half cost. |
| 6 | **Watchfires** | Stat | Defensive buildings gain range and reveal their lane. |
| 7 | **Granary Reserves** | Stat | Higher bank cap; faster tick while bank is above half. |
| 8 | **Bulwark Line** | Stat | Spears gain 40% HP. Hard counter to a rush. |

### BOOM — slow start, explosive finish, greedy

| # | Modifier | | Effect |
|---|---|---|---|
| 1 | **Trade Routes** | Stat | Levy tick increases slightly every 10 seconds, compounding. |
| 2 | **Golden Age** | Rule | Past a total-Levy threshold, +40% tick for the rest of the match. |
| 3 | **Investment** | Rule | Spend Levy now, receive 180% back after 45 seconds. |
| 4 | **Master Masons** | Stat | Functional buildings produce 35% more. |
| 5 | **Surplus** | Rule | Unspent Levy compounds a small bonus each tick. Hoarding pays. |
| 6 | **Caravan** | Rule | Unlocks a high-yield economy building with very low HP. |
| 7 | **Late Levy** | Stat | Units deployed after the two-minute mark cost 25% less. |
| 8 | **Boomtown** | Rule | +1 building slot, breaking the normal cap. |

### RAIDER — aggressive, feeds on conflict, snowballs

| # | Modifier | | Effect |
|---|---|---|---|
| 1 | **Plunder** | Rule | Destroying an enemy building grants Levy. |
| 2 | **Blood Tithe** | Rule | Gain a small amount of Levy per enemy unit killed. |
| 3 | **War Drums** | Stat | +15% damage for 20 seconds after any of your units gets a kill. |
| 4 | **Sappers** | Stat | Your units deal double damage to buildings. |
| 5 | **Vanguard** | Stat | First three units into any lane get +50% damage. |
| 6 | **No Retreat** | Stat | Units deal more damage the lower their HP. |
| 7 | **Scorched Earth** | Rule | Burn banked Levy to instantly damage a lane. |
| 8 | **Raiding Party** | Rule | Horses march 40% faster; may bypass an intact front building once per lane. |

### MYSTIC — control, information, disruption

| # | Modifier | | Effect |
|---|---|---|---|
| 1 | **Hex** | Rule | Periodically slows the enemy's Levy tick for a window. |
| 2 | **Divination** | Rule | Reveals enemy building placements. |
| 3 | **Omen** | Rule | You see enemy deployments the moment they're made. |
| 4 | **Veil** | Rule | Your buildings are hidden from enemy vision entirely. |
| 5 | **Ward** | Stat | Your buildings reflect a portion of damage back at attackers. |
| 6 | **Miasma** | Stat | Enemy units decay slowly inside your half of a lane. |
| 7 | **Ley Line** | Rule | On a cooldown, redirect in-transit units from one lane to another. |
| 8 | **Discord** | Stat | Enemy deployments cost slightly more Levy. |

## 8. The Type Wheel

Symmetric five-cycle — each type beats two and loses to two, so it balances by structure rather than a hand-tuned matchup grid.

| Type | Beats | Loses to |
|---|---|---|
| **Swarm** | Boom, Mystic | Fortress, Raider |
| **Boom** | Mystic, Fortress | Swarm, Raider |
| **Mystic** | Fortress, Raider | Swarm, Boom |
| **Fortress** | Raider, Swarm | Mystic, Boom |
| **Raider** | Swarm, Boom | Mystic, Fortress |

The fiction: Swarm punishes greed and drowns control effects. Fortress eats cheap bodies and blunts aggression. Boom out-scales a turtle and shrugs off percentage-based disruption. Raider punishes both fragile masses and slow greed. Mystic dismantles static defense and defangs an aggressor.

The matchup applies as a **quiet global modifier** — noticeable but not decisive, since neither player knows their own or their opponent's label.

**Archetypes as tempo:** because every match starts from zero, the five types are really *tempo* identities. Swarm wants to win in the first two minutes; Boom is trying to survive long enough to explode; Fortress is stalling the entire time. That's the rush/macro/turtle tension of an RTS, arriving for free out of the economic identities.

## 9. Example Loadouts

**"Locust"** — pure Swarm
*Breeding Pits · Chaff · Scent Trails · Tide of Bodies · Conscription*
Absurdly cheap units flooding one lane, snowballing as the stack grows. No economy, no defense. Must break a lane inside ninety seconds.

**"Anvil"** — pure Fortress
*Bastion Walls · Deep Foundations · Counterwall · Iron Discipline · Granary Reserves*
Walls that don't break, economy sealed behind them, every repelled attack pays you back. Wins by making the opponent bankrupt themselves on the front line.

**"Long Game"** — pure Boom
*Trade Routes · Golden Age · Surplus · Master Masons · Boomtown*
Contributes nothing for two minutes, then fields more than anyone can answer. Fatal weakness: any early aggression at all.

**"Wolves at the Gate"** — Raider primary, Swarm secondary
*Plunder · Sappers · War Drums · Blood Tithe · Scent Trails*
Reads as Raider (4 of 5). Every building razed funds the next push. Self-fueling, and it wants the enemy to keep feeding it targets.

**"Fog"** — Mystic primary, Fortress secondary
*Veil · Divination · Hex · Ley Line · Watchfires*
Sees everything, is seen by nothing, reroutes mid-march to hit whatever isn't defended. Low raw power; wins on information asymmetry.

**"Turtle Bank"** — Fortress/Boom hybrid, no dominant affinity
*Bastion Walls · Rapid Masonry · Trade Routes · Master Masons · Granary Reserves*
A deliberate 50/50 blend. How the sim resolves a tie for dominant type is an open question — see Part IV.

## 10. Progression & Meta

- No persistent base. The meta layer is a **growing unlock pool**: over matches you earn new modifiers to draft from.
- Progression is **horizontal** (more options), never **vertical** (more raw power). Both players always start a match equal, so matches are decided by *how you built*, not *how long you've played*.
- Side effect of dropping the base: your type is a **per-match choice**, not a permanent identity. Bring Swarm one fight and Fortress the next. The whole roster stays live every session.

---

# PART II — WHY THE DESIGN LANDED HERE

Short rationale for decisions that look arbitrary out of context.

- **The base-builder was cut.** It was doing two jobs: the fun thing *during* a session and the reason to return *across* sessions. It isn't needed for the first, and the unlock pool covers the second. Cutting it removed the two hardest problems at once — persistent world state to sync, and playtime-equals-power unfairness.
- **Buildings came back, but inside the match.** Same building-up satisfaction, no persistence or fairness cost. They're built fresh each fight and lost when the board clears.
- **Slots hold modifiers, not units.** This makes hidden types *emergent* rather than assigned, and turns the shared unit roster into a scouting surface.
- **Destructible buildings behind lanes.** Wires combat directly into economy: a lost lane snowballs. It also forces defense to be a real category, which is where the Fortress archetype lives.
- **Ticking only while logged in.** Rewards presence in WoW rather than nagging like a phone game.

---

# PART III — ARCHITECTURE DIRECTION

High level only — implementation is for the code agents.

**Deterministic lockstep.** Don't sync the game; run the *identical* simulation on both clients, advance it on a shared tick, and exchange only **inputs** ("3 Spears → lane 2", "Palisade → lane 1 front"). Same start + same inputs + same order = identical result computed independently on both machines. Every other system — combat, economy, stats, modifiers, build timers, proximity — then becomes **purely local** and never touches the network. You are not syncing an RTS over a lossy chat channel; you are syncing a handful of button presses every few seconds.

**Determinism discipline** (this is the real work):
- Drive the sim off a fixed tick, never frame time or the client clock.
- Seed RNG identically on both clients.
- Keep iteration order deterministic — `pairs()` in sim-affecting code is a classic desync landmine.
- No sim behavior may depend on anything local (framerate, addon load order, UI state).

**Reliability shim over the channel.** Addon messages are small, size-capped, throttled, and not guaranteed to arrive or arrive in order. A thin layer for sequencing, acks, and resends is required. Because only inputs cross the wire — tiny and infrequent — this stays inside the channel's limits.

**Fog of war.** Simulate full state on both ends and render only part. Hidden information must never cause the two sims to diverge.

The hard work pools in exactly two places: **a deterministic sim core** and **the netcode shim**. Everything else is ordinary local game code.

---

# PART IV — OPEN QUESTIONS

Prioritized. Items 1–2 are the current focus; the design isn't PID-ready until the top block is closed.

### Economy
1. **Flat vs. ramping base income.** Does Levy tick at a constant rate all match, with *all* growth coming from what you build and slot? Or does income naturally ramp? *Lean: flat, so investing in economy is a real decision with a real cost rather than something everyone gets free.*
2. **Cost curves.** Unit costs, building costs, build times, bank cap, tick rate — and how these interact with a 3–5 minute match so economy doesn't dominate aggression.

### Modifiers
3. **Affinity resolution.** How is dominant type computed from five slots — plurality, weighted points? What breaks a tie? Is "neutral, no matchup bonus" a legitimate strategic choice, or does a tie resolve to a type?
4. **Stacking rules.** Can two modifiers touching the same stat stack? Additive or multiplicative?
5. **[Rule] modifier count.** How many per type? They carry the most identity and the most balance risk.
6. **Pool size and drafting.** How many modifiers at launch, how many unlocked at the start, and are loadouts freely chosen or drafted from a random hand?
7. **Cap inviolability.** Boomtown deliberately breaks the building cap. Is that acceptable, or is the cap absolute?
8. **Building unlocks.** Is the whole catalog available to everyone, or do some modifiers unlock buildings (e.g. Caravan)?

### Match systems
9. **Fog-of-war model.** Exactly what each player can and can't see by default; how the Mystic information modifiers layer on without contradicting "you can never see an opponent's loadout, only infer it."
10. **Timeout resolution.** Keep = sudden death is settled. What decides a match that reaches the clock — buildings standing, lane ground held, damage dealt?
11. **Tick rate and match length.** Target duration and sim tick frequency.
12. **Type balance tuning.** How strong the wheel's global modifier should be.

### Multiplayer
13. **Players per match.** 1v1 only, or teams/FFA?
14. **Matchmaking specifics.** How the heartbeat advertises presence, how a match is proposed and accepted, eligibility and range.
15. **Disconnect and grief handling.** What happens when someone logs out, zones, or wipes mid-match.

### Presentation
16. **Working title and theme.** Both TBD. The kingdom/keep skin is one option; nothing mechanical depends on it.
