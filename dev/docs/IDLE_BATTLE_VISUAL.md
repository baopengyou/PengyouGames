# Idle Battle — visual direction notes

**Status: sketch, not binding.** Captured 2026-08-12 from a design conversation, before any
asset research. Nothing here has been verified against the 12.1 client. It exists so the
thinking is not lost, and so a later research pass has something concrete to check.

Companion to `IDLE_BATTLE.md` (the game) and `IDLE_BATTLE_DECISIONS.md` (the rules and
architecture). Where those two disagree with this file, they win — this is presentation only.

---

## Owner rulings so far

1. **Screen real estate is not a constraint.** The board may use the whole screen if that is
   what serves it. This deletes the "compact mode versus full board" tension that shaped the
   first sketch: design for a proper battlefield, not for something squeezed beside raid frames.
   A smaller or windowed presentation may still be offered later, but it is not a design driver.
2. **Asset research is deferred.** Not yet — the M-series build comes first.

---

## Precedents inside WoW itself

Blizzard has already shipped this genre in this client, which matters both for the art
vocabulary and for proving the shape is playable in a WoW UI.

| Precedent | Why it matters here |
|---|---|
| **Warfronts** (BfA) | The closest cousin: an RTS-lite with resource income, constructed buildings, and unit waves marching lanes to attack. Mechanically it is this game. Its art exists in the client. |
| **Plants vs Zombies minigame** (Hillsbrad) | Literal lane defence. The closest analogue to our *layout*, and evidence the read works at a glance. |
| **Karazhan chess** | 3D units commanded on a board — the "pieces, not soldiers" framing, where a model represents a group rather than an individual. |
| **Garrison architect table** | A building-placement UI with plots and slots. Almost exactly our six-slot problem, already solved visually. |
| **Pet battles** | The house style for a turn-structured game inside WoW: health bars, ability rows, readable state at small size. |

## What is already proven in our own code

`PG.Theme.NPC` renders a real creature model via `PlayerModel:SetDisplayInfo` on live 12.1
(Grizzle, in the Pull Book dialog), with a fallback chain ending in a static icon. So 3D
creature rendering inside an addon frame is **not** a research question — it ships today. The
open questions are which models, how many, and whether `ModelScene` (multi-actor, used by the
mount journal) is the better widget than raw `PlayerModel`.

## The recommendation, in one line

**Side-on lanes, PvZ-shaped, with 3D used surgically rather than everywhere.**

Your keep at the left, the enemy keep at the right, three horizontal lanes stacked vertically,
front and back building slots as fixed stations along each lane. It reads instantly, it matches
the vocabulary the design doc already uses ("down the lane", "your own half", "front slot"), and
it maps onto 2D frame work we know how to build.

### Why not a fully 3D battlefield

Four specific hazards, three of which this project has already been bitten by:

1. Model frames do not clip inside scroll frames.
2. Their z-order against **each other** is unreliable when they overlap.
3. Each one costs, and a 200-supply lane can hold twenty Spears. Twenty overlapping model
   widgets is a slideshow with depth-fighting.
4. Model loading is **asynchronous** — this is exactly the "invisible mascot" bug the reveal
   stage review caught, where `SetDisplayInfo` succeeds silently and renders nothing.

### Where 3D earns its place

- **One model per STACK, not per unit**, with a count badge. Solves performance and readability
  together, and it is honest to a sim that already thinks in stacks.
- **The two keeps** as persistent models. That is where the drama is: a keep visibly taking
  damage is the whole match in one image.
- **A champion model on the reveal stage** at the result moment, reusing the stage that already
  exists (`REVEAL.md`).

### Buildings should be 2D, and not as a compromise

Creature display IDs do not cover structures; garrison and warfront building art already exists
as atlases; static things read better as unambiguous icons than as small models; and it sidesteps
the overlap problem entirely. A palisade that is unmistakably a palisade at 40 pixels beats a
beautiful model nobody can identify.

## Two gifts from the existing design

- **The tick structure.** The board only changes on a 0.5 s resolve tick, so everything can
  animate in discrete steps instead of chasing frame rate — cheaper *and* more readable.
- **Fog is pure rendering** (Ruling 1, full state sharing). Not a shader problem, a
  "do not draw that" problem.

## Open, for the deferred research pass

1. Creature display IDs for a credible Spear / Horse / Bow trio, verified on 12.1.
2. `ModelScene` (multi-actor, camera, lighting) versus raw `PlayerModel` — is it viable in an
   addon, and is it better here?
3. Which Warfronts / Garrison building atlases are reachable, and how they look at icon size.
4. Whether keep models can take a visible damage state, or whether damage is conveyed by the
   frame around them.
5. What full-screen actually means for the safety layer: a full-screen board must still vanish
   instantly on a pull, and coming back must not disorient.
