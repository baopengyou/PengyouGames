# Idle Battle — Fog of War

**Status: binding. Owner-defined 2026-08-13.** This supersedes the fog model in
`IDLE_BATTLE_DECISIONS.md` §Q9a, which was written before fog had ever been specified and
whose three-bucket "muster bar" was an invention of the implementation, not a design decision.
Where Q9a disagrees with this file, **this file wins**. Q9b (how information modifiers layer
on) survives and is re-expressed in §6 below.

Fog remains a **pure render filter** (Ruling 1): both clients hold complete state, nothing is
withheld from the wire, and nothing in the simulation branches on visibility. Fog decides what
is *drawn* — and, for the M2 scripted policies, what a policy is *allowed to perceive*.

---

## 1. The map, in vision terms

A lane is 2,000 units long, from your keep at `0` to the enemy keep at `2000`. Each lane is
divided into **8 vision sections of 250 units**:

| Section | Range | Contains, from your point of view |
|---|---|---|
| 1 | 0–249 | your keep |
| 2 | 250–499 | your **back** slot (300) |
| 3 | 500–749 | your **front** slot (700) |
| 4 | 750–999 | your half, up to the midline |
| — | **1000** | **the midline** |
| 5 | 1000–1249 | their half begins |
| 6 | 1250–1499 | their **front** slot (1300) |
| 7 | 1500–1749 | their **back** slot (1700) |
| 8 | 1750–2000 | their keep (2000) |

Sections are per lane. Vision in lane 1 tells you nothing about lane 2.

## 2. Default vision — your own half, and no further

**You always see sections 1–4 of every lane: your half, out to the midline.** Everything in it,
exact: your own units and buildings, and *any enemy unit that has crossed into it*.

**You see nothing in sections 5–8 by default.** An enemy unit marching toward you is
**invisible until it reaches the midline**. There is no early warning, no aggregate, no
"something is coming" indicator. That is deliberate: it is what makes scouting worth doing and
what gives the information modifiers of §6 something to sell.

## 3. Dynamic vision — your units light up the section they stand in

> **A section of the enemy half is visible while at least one of your units is inside it.**

Not the sections before it, not the sections after it — the section the unit occupies. A unit at
position 1,400 reveals section 6 and nothing else.

This is what makes a scout a real play: send one cheap body forward and you buy sight of exactly
where it is standing, for exactly as long as it lives. It also means vision is *earned and
lost* continuously through a match rather than being a fixed property of a build.

### 3a. Contact reveals — added 2026-08-13

> **A unit also reveals any enemy entity it is in combat with, whatever section that entity is
> in. You can see what you are fighting.**

This closes a defect the first implementation surfaced by following §3 literally. Melee range is
60 units and their front building sits at 1,300, so an attacker stops at 1,240 — which is
section 5, while the building is in section 6. Read strictly, a soldier grinding down a wall
could not see the wall it was hitting, and a front building was only ever visible to a unit that
had already walked past it.

Contact reveal is **entity-scoped, not section-scoped**: fighting a palisade shows you the
palisade, not everything standing behind it. So it fixes the absurdity without quietly handing
out a section of free vision, and it leaves §5's front-slot shield fully intact — a unit cannot
reach the back building while the front one still stands, so it can never be in contact with it.

The player-facing rule is one sentence, which is the test of whether it is the right rule: *you
see what you are fighting.*

Note the interaction with §4: a unit that marches from the midline to their keep will have
*seen* sections 5, 6, 7 and 8 in turn, so after it dies you retain a memory of all four — frozen
at the moment each one left your sight.

## 4. Memory — what you have seen persists, frozen

**Anything you have seen stays on your screen after the fog closes, exactly as it was when you
last saw it, and never updates until you see it again.**

You are not shown that the information is stale. Working out whether a remembered palisade is
still standing is part of the game.

| Object | Remembered? | Rule |
|---|---|---|
| Enemy **buildings** | **Yes** | Slot, identity and HP are frozen at last sight. A building destroyed while unobserved still shows, intact, until you next see that section. A building constructed while unobserved does not appear at all. |
| Enemy **units** | **No** | Units are not ghosted at a stale position. A remembered stack is worse than no information — it invites a decision against an army that moved two minutes ago. Units are drawn only while genuinely visible. |
| Enemy **keep** | Position always known (it is always there); **HP remembered** from last sight | |

*Sub-ruling, flagged: "units are not remembered" is my reading of intent rather than a stated
requirement. It matches the standard in this genre and avoids actively misleading the player.
Say the word if you want stale unit ghosts instead — it is a one-line change in the render
filter and the policy view.*

## 5. Buildings — the back slot is protected by the front slot

Buildings are revealed by the same section rule, with one deliberate exception that gives the
front slot a second job:

> **The enemy BACK slot (section 7) is visible only when their FRONT slot in that lane is
> empty or destroyed, AND one of your units is in section 7.**

So an intact front building shields the back building from sight even from a unit standing right
next to it. Cracking the front of a lane therefore buys *information* as well as ground — which
is the mechanical justification for the front/back split the design already has, and it makes
"what are they hiding behind that palisade?" a real question.

An **empty** enemy slot is indistinguishable from an **unseen** one at range: you learn a slot
is empty only by seeing the section under the rules above.

## 6. How the information modifiers layer on (Q9b, re-expressed)

Unchanged in intent from the decisions doc; restated against this model so the two cannot drift.
Each of these *buys back* some part of what §2–§5 takes away, which is exactly why they are
worth a loadout slot.

| Source | Effect under this model |
|---|---|
| **Watchtower** (front building) | Its own lane only: sections 5 and 6 are permanently visible while it stands. Dies with the building. |
| **Shrine** — reveal pulse (back building) | Periodically, briefly: every section of every lane, plus enemy building **occupancy only** (not identity, not HP). Self-announcing. |
| **Divination** (Mystic) | All **completed** enemy buildings — slot and identity, continuously, in every lane, ignoring both the section rule and the front-slot shield. **Never HP**, never buildings under construction. |
| **Omen** (Mystic) | Enemy deploy orders surfaced as they are issued: **lane and count only, never unit type**. This is the one source of genuine early warning, and it is temporal rather than spatial — you learn a wave exists before it can be seen. |
| **Veil** (Mystic) | Your buildings are exempt from every disclosure route above. |

## 7. What is never visible, by any route

Enemy **Levy, bank, income, spending and loadout** are not spatial and are never rendered under
any circumstance. Vision is about the board. The economy is inferred from what the board does —
which is the whole scouting premise of §5 in `IDLE_BATTLE.md`, where the way an opponent's units
deviate from baseline is the information.

## 8. Consequences the implementation must respect

1. **This replaces the muster bar entirely.** There is no aggregate signal about the enemy half.
   Any policy or UI element built on `alarm` / `muster` levels must be rewritten against
   sections, and the derived 2,800/5,600 HP thresholds are void.
2. **The M2 policy view is a consumer of this model, not an author of it.** A scripted line may
   perceive exactly what a player could: its own board, enemy units in its own half, sections it
   currently lights, and its own memory of sections it has seen.
3. **Memory is per-side state that the SIM must not branch on.** It is a render/policy concern.
   If a policy consults memory, that memory must be derived deterministically from the shared
   state and the side index, so both clients still compute an identical match.
4. **Scouting becomes a real cost/benefit decision**, which is new pressure on the economy
   numbers: a cheap body spent on sight is a body not spent on pressure. Expect the M2
   distribution to move, and treat pre-fog measurements as void rather than as a baseline.
