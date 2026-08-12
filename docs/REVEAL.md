# PengyouGames — Shared Results-Reveal Stage (REVEAL.md)

Binding spec for `PG.Theme.Reveal` / `PG.Theme.RevealQueue`: one flashy, animated,
full-takeover reveal component shared by Loot Goblins, Rock Paper Scissors, and
The Pull Book at round/session/settlement ends. One design, no options.

This spec DELIBERATELY RELAXES SKIN.md section 6's motion-restraint doctrine for
the reveal moment only (concurrency ceiling, multi-element choreography, takeover
scrim). Everything else in SKIN.md section 0 remains absolute and is restated in
section 5 here. Where this file and SKIN.md disagree about the reveal moment,
this file wins; about anything else, SKIN.md wins.

Implementation target: `PengyouGames/Theme.lua` ONLY (this workflow builds the
engine; game integration is a later pass). WoW Lua 5.1, ASCII sources, no new
globals, file-scope purity (only `PG.Theme` functions/data at file scope; every
frame/texture/group/pool built lazily on first use). Verify with
`/opt/homebrew/bin/luac -p`.

---

## 0. Non-negotiable contracts (violating any is a bug)

1. **Instant Safety hide.** The stage frame is Safety-registered
   (`PG.Safety.RegisterWindow(stage)`) and carries
   `stage.__pgResume = function() return false end` — a FUNCTION returning
   false, never the literal `false` (Core.lua's resume loop treats a falsy
   `__pgResume` field as "no veto" and would re-show the stage). Any hide —
   Safety, host-window hide, or our own — runs the synchronous teardown in 5.2:
   Stop (never Finish) every group, hide every FX region, `StopAnimating`,
   bump generation, `stage:Hide()`. The hide path performs NO model calls, NO
   sounds, NO Show, and never schedules anything.
2. **Never re-show a hidden frame.** No reveal code path calls `Show()` on any
   window. The stage itself is shown only by the queue pump, only while
   Safety-clear. A reveal aborted by a hide simply dies; its information is
   already in the game window's text (SKIN.md rule 6.7 holds: RefreshUI sets
   final text BEFORE any reveal plays).
3. **Reveal only when Safety would allow a window.** `Reveal` plays only when
   all five flags (`inCombat`, `inEncounter`, `readyCheck`, `countdown`,
   `restricted`) are clear; `RevealQueue` holds payloads until they are
   (mirroring PullBook's toast queue). Games keep their existing gating
   (LG/RPS fx paths already no-op unless `win:IsShown()`; PB already queues).
4. **Sounds only via `PG.Theme.Sound(key)`** (self-gated, default off). The
   reveal adds no new sound entry point and no new SoundKit IDs.
5. **Bounded reusable pools.** Everything is built once, lazily, and replayed
   via `Restart()`. Zero per-event frame/texture/group/FontString creation.
   Pool inventory and hard counts in 5.3.
6. **No persistent OnUpdate decoration loops.** The reveal uses AnimationGroups
   plus gen/token-checked `C_Timer` beats. The queue pump is a self-cancelling
   `PG.Ticker` that exists only while payloads are pending. No reveal loop
   (`SetLooping`) exists at all in this component.
7. **Click-anywhere-to-skip.** Any mouse press on the stage jumps straight to
   the final fully-readable state (state machine in 4.3).
8. **Total choreography under 5 s.** Cascade 4.60 s, podium 4.80 s, both
   including the fade-out. Every game's post-result pause (LG `REVEAL_SECS`=5,
   RPS `REVEAL_SECS`=6) exceeds the stage's lifetime.
9. **All information readable AFTER animation completes.** The hold state is
   the design: title, subtitle, all rows, and the marquee sit at full alpha,
   final scale, final position; every transient (burst, flash ramp) has
   self-hidden. Burst particles arc from the stage's top region and are gone
   by t=3.3 (cascade) / t=3.4 (podium) — the last particle ends at
   `burst + 0.04*burstCount + 0.90` — and they never overlap the hold.
10. **Skip lands on the identical final state** as natural completion (the
    invariant list in 4.4). A player who skips at t=0 loses nothing.

---

## 1. Verified inventory (everything the reveal may reference)

Only the following exist in Theme.lua's tables today. The reveal must not
reference anything outside these lists; each item's fallback is the one the
existing helper already applies.

**Asset keys** (via `Theme.Tex`/`Theme.Icon`/`Theme.Mark`; each ends in a
solid-color fallback): `coin`, `coinpile`, `ticket`, `sack`, `chest`, `glow`,
`starburst`, `star`, `goldpile`, `redx`, `ribbon`, `card`, `parchment`,
`sheet`, `warboard`, `goldheader`, `tarotK`, `tarotD`, `tarotW`, `goldicon`,
`dice`, `rps_rock`, `rps_paper`, `rps_scissors`, `greedcoin`, `pass`.

Used by the reveal: `goldicon` (coin burst texture), `star` (star burst),
`ticket` (ticket burst + faire personal marker), `coin` (goblin personal
marker), `ribbon` (goblin marquee art). Fallbacks: burst textures fall back to
the asset's solid color at 8x8 (the A5 "gold dot" precedent — the burst still
reads); marquee ribbon failure falls back to the Banner composition's solid
bar; marker failure (`Theme.Tex` false) hides the marker — the row's color
role and big pop carry the emphasis.

**Sound keys** (via `Theme.Sound` only): `open`, `parchment`, `page`, `greet`,
`farewell`, `coinpick`, `coinlock`, `coincancel`, `potclink`, `stamp`,
`bookclose`, `ticket`, `coins`, `laugh`, `cheer`, `settled`, `fanfare`,
`click`. An unknown key in a payload is a silent no-op (Theme.Sound already
guarantees this).

**Emote names** (via an existing `Theme.NPC` handle's `:Emote`): `idle`,
`greet`, `talk`, `ask`, `excited`, `nod`, `cheer`, `laugh`, `applaud`,
`dance`, `point`. The reveal never creates NPC handles; it only calls
`payload.npc:Emote(payload.emote)`, which self-gates on `ok`/visibility.

**Palette names** (via `Theme.C`; the stage ground is always the dark scrim,
so only dark-safe colors are used for text): `CHALK`, `CHGOLD`, `CHGREEN`,
`CHRED`, `CHGRAY`, `GOLD`, `BRASS`, `VIOLET`, `BOARD`, `INK` (INK only on
ribbon art). Never place INK or WIN/LOSS/FADE/AMBER directly on the scrim.

**Animation primitives** (all already used in Theme.lua, all created through
the same pcall-guarded `newGroup`/`newAnim` pattern): `Scale` (via the
`setScaleRange` dual-API helper), `Alpha` (`setAlphaRange`), `Translation`,
`Rotation`, `Path` with `CreateControlPoint` (curve `SMOOTH`); smoothing
`IN` / `OUT` / `IN_OUT` / `NONE`; `SetStartDelay` / `SetEndDelay`;
`SetToFinalAlpha`; `Restart()` (with the Stop+Play fallback in `restart`).
`SetLooping` exists but the reveal does not use it. Fonts: Morpheus via
`Theme.SetHeader` (Blizzard font-object fallback built in); shadows via
`Theme.Shadow`. Literal strings/numbers only in every animation call
(SecretArguments rule).

Nothing is missing that requires a new asset. No new atlas, file, SoundKit,
display ID, or font may be added for this feature.

---

## 2. Public API

Two new functions on `PG.Theme`. Neither returns anything; callers never
branch on the reveal (decoration doctrine). Both pcall-swallow internal errors
via the existing helper conventions.

### 2.1 `PG.Theme.Reveal(payload)`

Play the reveal NOW if possible; otherwise drop it silently. "Possible" means:
stage idle, all five Safety flags clear, and (window mode) `payload.anchor.host`
exists and `IsShown()`. Use for per-round reveals, where the next round
supersedes a missed one and a late replay would be wrong.

### 2.2 `PG.Theme.RevealQueue(payload)`

Append to the reveal queue and pump. The queue drains strictly one-at-a-time,
FIFO, only while Safety-clear and the stage is idle — the same shape as
PullBook's toast queue (`queueToast`/`pumpToasts`/`canToastNow`), but with the
stricter all-five-flags gate. Use for must-eventually-show moments: session
podiums, PB settlements.

Queue semantics (binding):

- Capacity **6**. A 7th enqueue is dropped (newest loses). Reveals are
  decoration; the information already lives in game text/toasts/ledger.
- Pump: a `PG.Ticker(0.5, pump)` created on first enqueue, cancelled when the
  queue is empty. Additionally, one `PG.Safety.OnChange` callback (installed
  lazily, once, on the first reveal of EITHER kind) pumps on any `*_OFF`
  trigger — the Ask deferred-show precedent in Widgets.lua — and hides a
  non-idle stage on `COMBAT_ON`. Plain combat no longer hides the game windows,
  but `rvCanNow` already refuses to START a takeover in combat, so a stage that
  opened a second before the pull must not ride into it either (0.3).
- Drain conditions, all required: queue non-empty; stage state `IDLE`; all
  five Safety flags clear; `payload.validate` (if present) pcalls to true
  (false or error discards the payload silently); window mode: host non-nil
  and `host:IsShown()` (else discard); screen mode: `not PG.IsDND()` (else
  discard — DND suppresses toast-like surfaces).
- A second reveal arriving while one plays: `RevealQueue` queues it (played
  on a pump tick at least 0.5 s after the stage hides — a breathing gap);
  `Reveal` drops it. A playing reveal is NEVER interrupted by a new payload.

### 2.3 Payload schema (exact)

Unknown fields are ignored. Every field is defensively read (wrong types are
treated as absent); `title` absent/empty makes the whole call a silent no-op.

```
payload = {
  theme    = "goblin" | "faire",          -- default "faire"; drives title color,
                                          -- marquee art, personal marker key
  anchor   = { mode = "window", host = <frame> }   -- stage covers the host window
           | { mode = "screen" },                  -- standalone centered stage (PB)
                                          -- default: screen
  variant  = "cascade" | "podium",        -- default "cascade"

  title    = <string>,                    -- REQUIRED. The slam text ("GREED
                                          -- PUNISHED", "FINAL RESULTS", ...)
  subtitle = <string> | nil,              -- smaller line under the title

  rows     = { <row>, ... } | nil,        -- ordered result rows, max 10 honored:
                                          -- if #rows > 10, rows 1..9 show plus an
                                          -- auto "... and N more" line in "fade".
                                          -- The engine lifts the FIRST personal
                                          -- row past the cut into slot 9, so the
                                          -- viewer's own row is never collapsed
                                          -- away (the count on the fade line is
                                          -- total-9 either way, so it stays true).
                                          -- Producers of >10 rows should carry the
                                          -- rank in the row text, so a hoisted row
                                          -- still reads honestly out of order.
  -- row = {
  --   text     = <string>,               -- final display string; may embed |cff
  --                                      -- escapes (they win over role)
  --   role     = "body"|"win"|"loss"|"fade"|"gold"|"silver"|"bronze",
  --                                      -- base SetTextColor; default "body"
  --   personal = <bool>,                 -- the local player's row: bigger pop
  --                                      -- (scale 1.6) + marker icon (goblin:
  --                                      -- "coin", faire: "ticket")
  --   place    = 1|2|3 | nil,            -- podium variant only: this row rises
  --                                      -- on the medal beat; rows without
  --                                      -- place are "field" rows
  -- }

  marquee  = <string> | nil,              -- ribbon/bar line under the rows that
                                          -- slides in and STAYS (LG: "2 HOARDERS
                                          -- EXPOSED"; RPS: standings movement or
                                          -- medal line; PB: settlement headline)

  burst      = "coins"|"stars"|"tickets"|"none",  -- default "none"
  burstCount = 1..12,                     -- clamped; default 10 (podium forces 12)

  sound      = <sound key> | nil,         -- played at the title slam
  burstSound = <sound key> | nil,         -- played at the burst moment; podium
                                          -- default "fanfare" when absent

  npc      = <Theme.NPC handle> | nil,    -- the HOST WINDOW's existing goblin
  emote    = <emote name> | nil,          -- played at t=0.20 via npc:Emote

  validate = function() -> bool | nil,    -- drain-time staleness check (queue
                                          -- only); false/error discards.
                                          -- REQUIRED practice for session-scoped
                                          -- queued payloads (capture the session
                                          -- table, compare identity).
  onDone   = function(reason) | nil,      -- fires ONCE from a token-checked timer
                                          -- when the stage reached its final
                                          -- state and finished fading:
                                          -- reason "done" (natural) or "skip".
                                          -- NEVER fires for an aborted reveal
                                          -- (Safety/host hide) and is NEVER
                                          -- called from the hide path.
}
```

Color-role mapping (single mapping — the ground is always the BOARD scrim):
`body`=CHALK, `win`=CHGREEN, `loss`=CHRED, `fade`=CHGRAY, `gold`=CHGOLD,
`silver`=CHGRAY, `bronze`=BRASS. Title: GOLD (goblin) / CHGOLD (faire).
Subtitle: CHALK. Every stage FontString gets `Theme.Shadow` (busy/dark art).

---

## 3. The stage

ONE global stage frame, built lazily on the first accepted reveal, reused
forever. Construction:

- `CreateFrame("Frame", nil, UIParent)` (plain, unguarded — the PG.UI.Window
  precedent), `EnableMouse(true)` (swallows every click over it: this is both
  the skip surface and misclick protection for the window beneath),
  `SetFrameStrata("DIALOG")`.
- `Theme.EnsureFX(stage)` — installs `stage.__pgFX`, the group/region
  registries, `stage.__pgGen`, and the OnHide/OnShow wiring. Every group the
  stage builds is registered via `Theme.RegisterGroup(stage, g)`; every
  texture/child frame via `Theme.RegisterRegion(stage, r)`.
- `PG.Safety.RegisterWindow(stage)`; `stage.__pgResume = function() return
  false end`.
- One extra OnHide hook (installed once, after EnsureFX's): sets the state
  machine to `IDLE`, clears the active payload, and `pcall(stage.Hide, stage)`
  — the explicit Hide matters in window mode, where a host hide fires our
  OnHide while `stage:IsShown()` would otherwise remain true and a later
  `host:Show()` would resurrect a stale stage. This hook does teardown-state
  bookkeeping only (no Show, no sound, no model, no scheduling); the visual
  Stop/hide work is already done by EnsureFX's `hideFX`.
- Anchoring at play time (the coin-pool reparent precedent):
  - window mode: `stage:SetParent(host)`, `SetAllPoints(host)`,
    `SetFrameLevel(host:GetFrameLevel() + 40)` (well above `__pgFX` at +5).
    Parenting makes any host hide hide the stage in the same frame — plus the
    stage's own Safety registration and the hook above.
  - screen mode: `SetParent(UIParent)`, `ClearAllPoints()`, size 460x330,
    `SetScale(db.profile.scale)` (a UIParent child, so it carries the profile
    scale like every other PG surface; window mode resets it to 1 because the
    host's scale already applies), `SetFrameLevel(20)` (window mode leaves it
    at host+40, which would otherwise keep it above later DIALOG popups), and
    `SetPoint("CENTER", UIParent, "CENTER", 0, y)` where y is the first of
    `{120, 240, -160, 40, -260}` that stays fully on screen AND clears every
    shown factory window and Ask popup, via the read-only
    `PG.UI.RectFree(l, b, w, h)` query (the stage is mouse-enabled and would
    otherwise swallow a live SHARE/HOARD, card or Accept click for its whole
    life). The design anchor 120 is used anyway
    when nothing is free — the information must show, and refusing the drain
    could starve the payload for a whole session.
- Host windows get NO new hooks; parenting alone carries the hide contract.

Stage elements (geometry offsets from the stage; implementers may nudge +/- 8
px but keep the vertical order; all text set BEFORE any group plays):

```
scrim      full-stage BACKGROUND texture, SetColorTexture(BOARD, a=1) with the
           alpha animated 0 -> 0.85; the darkened panel IS the stage ground.
edges      4 x 2px BORDER textures inset 4 px (top/bottom/left/right), color
           GOLD (goblin) / CHGOLD (faire), the border-flash + resting frame.
title      FontString OVERLAY, SetHeader(24), theme title color, Shadow,
           TOP (0, -56), justify CENTER, width stage-48.
subtitle   FontString OVERLAY, GameFontNormal, CHALK, Shadow, TOP (0, -92).
rows[1..10] FontString OVERLAY, GameFontHighlight, Shadow, centered, width
           stage-64, row i at TOP (0, -128 - 22*(i-1)).
markers[1..10] 16x16 ARTWORK texture per row, anchored RIGHT of the row
           text's LEFT edge ("RIGHT", row, "LEFT", -4, 0); shown only for
           personal rows; art key "coin" (goblin) / "ticket" (faire).
marquee    child frame, 300x30 or as wide as its line needs (max stage-40):
           art = ribbon atlas with INK text (goblin) or BOARD-color bar a=0.9
           with CHGOLD text (faire) — the exact buildBanner composition;
           SetHeader(16), Shadow. Re-anchored and re-sized per play: TOP
           (0, -128 - 22*shownRows - 12); the FontString is SetWordWrap(false)
           and capped at frame-24 so a long line truncates ON the art instead
           of spilling INK text onto the scrim.
burst[1..12] 14x14 OVERLAY textures on stage.__pgFX, art key set per play
           ("goldicon" / "star" / "ticket"; re-Tex'd only when the type
           changes), origin TOP (0, -90).
```

The stage never carries a backdrop; in screen mode the scrim + edges are the
panel. Nothing on the stage is movable, and the stage is never added to the
window-overlap solver.

---

## 4. Choreography (binding timings)

Timeline zero = the queue pump accepted the payload: all FontStrings set, all
static properties applied, THEN `stage:Show()` and the beats below. Beats are
scheduled with `Theme.After(stage, t, fn)` wrapped in a play-token check
(4.5); per-row staggers ride `SetStartDelay`, set per play before `Restart()`
(anim param setters are pcall'd like everything else).

### 4.1 Cascade variant (LG round, RPS round, PB settlement)

| t (s) | Element    | Composition (type / dur / smoothing / order)                          | Notes |
|-------|-----------|------------------------------------------------------------------------|-------|
| 0.00  | scrim      | Alpha 0 -> 0.85 / 0.20 / OUT / 1, SetToFinalAlpha true                 | darken the panel |
| 0.00  | edges x4   | Alpha 0 -> 0.9 / 0.12 / NONE / 1 + Alpha 0.9 -> 0.35 / 0.25 / IN / 2, SetToFinalAlpha true | border flash; rests at 0.35 as the stage frame |
| 0.10  | title      | Scale 2.2 -> 1.0 / 0.22 / IN / 1 + Alpha 0 -> 1 / 0.12 / NONE / 1, SetToFinalAlpha true | the slam; `Theme.Sound(payload.sound)` fires here |
| 0.10  | subtitle   | Alpha 0 -> 1 / 0.20 / NONE / 1, startDelay 0.15, SetToFinalAlpha true  | lands ~0.45 |
| 0.35  | rows i=1..n | per row: Scale 1.25 -> 1.0 / 0.16 / OUT / 1 + Alpha 0 -> 1 / 0.12 / NONE / 1, startDelay 0.12*(i-1), SetToFinalAlpha true | personal row instead: Scale 1.6 -> 1.0 / 0.20 / OUT + same Alpha; marker shown at row alpha |
| 1.70  | marquee    | Translation x -40 -> 0 / 0.25 / OUT / 1 + Alpha 0 -> 1 / 0.20 / NONE / 1, SetToFinalAlpha true | slides in and STAYS (no fade-out; unlike Banner) |
| 1.90  | burst      | k = burstCount textures: Path(SMOOTH, 2 cps randomized ONCE at build; cp1 x[-110..110] y[60..120]; cp2 x[-160..160] y[-240..-180]) / 0.9 / NONE / 1 + Rotation [-200..200] deg / 0.9 / NONE / 1 + Alpha 1 -> 0 / 0.30 startDelay 0.60 / NONE / 1; per-texture startDelay 0.04*i; OnFinished hides each | `Theme.Sound(payload.burstSound)`; the A5 recipe at reveal scale |
| 3.30  | —          | all transients finished: the last burst particle self-hides at burst + 0.04*burstCount + 0.90 (worst case 1.90 + 0.48 + 0.90 = 3.28) | HOLD: fully readable. The hold beat force-hides every burst texture, so it must never start before this. |
| 4.20  | fade       | stage Alpha 1 -> 0 / 0.40 / IN / 1                                     | OnFinished: `stage:Hide()`; onDone("done") via token-checked timer |
| 4.20  | npc emote  | `payload.npc:Emote(payload.emote)`, fired from the fade beat            | window mode; the NPC sits UNDER the 0.85 scrim, so an emote during the takeover is invisible — he plays it as the scrim clears, exactly once per play, on the skip path too. Never from the hide path (no model calls there). |

Total 4.60 s. With n=10 the last row lands at 0.35 + 1.08 + 0.16 = 1.59, before
the marquee.

### 4.2 Podium variant (RPS final, LG session end)

Rows arrive best-first. Rows with `place` 1/2/3 are podium rows (colors gold/
silver/bronze applied via role); the rest are field rows. Podium rows rise
from below; the winner rises last with the big burst.

| t (s) | Element     | Composition                                                            | Notes |
|-------|------------|-------------------------------------------------------------------------|-------|
| 0.00  | scrim+edges | as 4.1                                                                  | |
| 0.10  | title       | as 4.1 (+ `payload.sound`)                                              | "FINAL RESULTS" |
| 0.10  | subtitle    | as 4.1                                                                  | |
| 0.35  | field rows  | per row: Scale 1.15 -> 1.0 / 0.12 / OUT / 1 + Alpha 0 -> 1 / 0.10 / NONE / 1, startDelay 0.08*(j-1) | quick, quiet; done by ~1.0 |
| 1.00  | bronze row  | Translation y -14 -> 0 / 0.22 / OUT / 1 + Scale 1.25 -> 1.0 / 0.22 / OUT / 1 + Alpha 0 -> 1 / 0.15 / NONE / 1 | |
| 1.40  | silver row  | same composition as bronze                                              | |
| 1.90  | gold row    | Translation y -18 -> 0 / 0.26 / OUT / 1 + Scale 1.8 -> 1.0 / 0.26 / OUT / 1 + Alpha 0 -> 1 / 0.12 / NONE / 1 | winner slam |
| 2.00  | burst       | 12 textures, recipe as 4.1                                              | `Theme.Sound(payload.burstSound or "fanfare")` |
| 2.20  | marquee     | as 4.1                                                                  | |
| 3.40  | —           | transients done (last burst particle at 2.00 + 0.48 + 0.90 = 3.38)      | HOLD |
| 4.40  | fade        | as 4.1                                                                  | ends 4.80 |
| 4.40  | npc emote   | as 4.1 (fired from the fade beat)                                       | |

Missing places degrade gracefully: absent bronze/silver beats are skipped, the
remaining beats keep their times (2-player podium: silver 1.40, gold 1.90).

### 4.3 Skip state machine

States: `IDLE -> PLAYING -> HOLD -> FADING -> IDLE`. Transitions:

- `PLAYING`, any mouse press: **Skip.** Bump the play token (kills every
  pending beat), `Stop()` every stage group, apply the final-state list (4.4)
  by direct property sets, hide the burst textures, phase = `HOLD`, schedule
  fade at +1.2 s (token-checked). No sounds play on skip; sounds not yet fired
  are simply lost.
- `HOLD`, mouse press: start the fade immediately (phase = `FADING`).
- `FADING`, mouse press: `Stop()` the fade group, `stage:Hide()` (phase =
  `IDLE`). onDone("skip") still fires (token-checked timer scheduled at the
  moment the fade path resolves).
- Any state, OnHide (Safety, host hide, our own Hide): phase = `IDLE`
  synchronously; gen bump invalidates everything pending; onDone never fires.
- `IDLE` is the only state the queue pump drains in.

### 4.4 Final-state invariant (skip == natural completion)

scrim alpha 0.85; edges alpha 0.35; title scale 1.0 alpha 1; subtitle alpha 1;
all shown rows scale 1.0 alpha 1 at rest positions with personal markers
shown; marquee at rest offset, alpha 1; all burst textures hidden; no pending
beats. Both paths land exactly here before the hold.

---

## 5. Safety and performance contracts for the implementer

### 5.1 Generation counters — two, with distinct jobs

- `stage.__pgGen` (owned by EnsureFX): bumped on every hide/show. All beats
  ride `Theme.After(stage, ...)`, which already refuses to run after a
  gen bump or while hidden.
- `stage.__pgRevealToken` (new, reveal-local): bumped on every Play, Skip, and
  the OnHide bookkeeping hook. Every beat closure captures the token at
  schedule time and returns unless it still matches. This is what lets Skip
  kill pending beats WITHOUT hiding the stage. onDone closures check the token
  the same way.

### 5.2 OnHide wiring (exact order on any hide)

EnsureFX's `hideFX` (already shipped) runs first: Stop every registered group,
hide every registered region, `StopAnimating` on `__pgFX` and the stage,
`__pgGen + 1`. Then the reveal's own OnHide hook: `__pgRevealToken + 1`, phase
= `IDLE`, active payload cleared, `pcall(stage.Hide, stage)` (no-op when
already un-shown; essential when the hide arrived via the host parent). The
whole path is synchronous and performs no Show/sound/model/scheduling.

### 5.3 Pools (hard caps; built once at stage construction)

| Pool | Count | Contents |
|---|---|---|
| scrim | 1 texture, 1 group | |
| edges | 4 textures, 4 groups | |
| title | 1 FS, 1 group | |
| subtitle | 1 FS, 1 group | |
| rows | 10 FS + 10 marker textures, 10 groups | one group per row: Scale + Alpha + Translation anims; scale-from / translation offset / startDelay set per play (Banner's re-anchor-per-play precedent) |
| marquee | 1 child frame (art + FS), 1 group | |
| burst | 12 textures, 12 groups | control points randomized ONCE at build (A5 rule); art re-keyed only when burst type changes |
| fade | 1 group on the stage frame | |

Totals: 32 regions, ~31 groups, built exactly once. The existing global
12-coin `CoinBurst` pool is NOT touched or reused — games keep it for their
non-reveal moments.

**Relaxed concurrency ceiling (the doctrine exception):** during a reveal the
stage may have up to **20** simultaneously playing AnimationGroups (peak in
practice: 12 burst + marquee + tail of the cascade + chrome ~ 16). SKIN.md
rule 6.5's caps still bind every other surface, and the stage never plays
concurrently with a game window's own A3-A7 reveal batch once games integrate
(the integration pass replaces those calls).

Flash discipline (SKIN.md 6.6) still binds: no ADD-blend layer here at all;
ramps <= 0.35 s; nothing screen-centered except the screen-mode stage itself,
which is a bounded panel, not a flash.

### 5.4 If a second reveal queues while one plays

The playing reveal is never interrupted. `RevealQueue` items wait for `IDLE` +
the 0.5 s pump cadence; `Reveal` calls are dropped. A payload whose moment has
passed must be culled by its own `validate` — the engine has no age cap.

### 5.5 Failure modes

Every Blizzard call in the stage goes through the existing guarded primitives
(`newGroup`/`newAnim`/`setScaleRange`/`setAlphaRange`/`restart`/`Theme.Tex`/
`Theme.SetHeader`/`Theme.Sound`, all pcall'd). A group that fails to build
leaves its element STATIC at final state (text visible from frame one — the
reveal degrades to an instant results card, then fades via the fade group; if
even the fade group failed, a token-checked `Theme.After(stage, 4.6, Hide)`
ends it). Art failures follow section 1's fallbacks. Nothing here may error
out of the component.

---

## 6. Per-game payload examples (integrators follow verbatim)

These are the reference shapes for the later integration pass. `TC`/`P` are
each module's captured palettes; `win`/`npc`/`S`/`book` are the modules' own
locals. Rows always carry FINAL strings (money via `PG.Money`/`Theme.Money`).

### 6.1 LG round result (from `fxResult`, replacing the direct A3-A7 calls)

```lua
local lr = S.lastResult
local rows = {}
for i, name in ipairs(S.roster) do
  local c = lr.pattern:sub(i, i)
  local row
  if c == "H" then
    row = { text = name .. "  HOARD +" .. PG.Money(lr.hoardPay), role = "loss" }
  elseif c == "S" then
    row = { text = name .. "  share +" .. PG.Money(lr.sharePay), role = "win" }
  else
    row = { text = name .. "  no pick", role = "fade" }
  end
  if name == myName() then row.personal = true end
  rows[#rows + 1] = row
end
local nh = select(2, lr.pattern:gsub("H", ""))
local title = (nh > 0 and lr.hoardPay == 0) and "GREED PUNISHED"
  or (nh == 0 and "EVERYONE SHARED" or ("ROUND " .. lr.r))
Theme.Reveal({
  theme = "goblin", anchor = { mode = "window", host = win },
  title = title,
  subtitle = "Round " .. lr.r .. " of " .. S.rounds .. " - pot " .. PG.Money(S.roundPot or 0),
  rows = rows,
  marquee = (nh > 0) and (nh .. (nh == 1 and " HOARDER EXPOSED" or " HOARDERS EXPOSED")) or nil,
  burst = (lr.sharePay > 0 or lr.hoardPay > 0) and "coins" or "none",
  burstCount = (lr.sharePay > 0) and 10 or 6,
  sound = "coins",
  burstSound = (nh > 0 and lr.hoardPay > 0) and "laugh"
    or ((nh == 0 and lr.sharePay > 0) and "settled" or nil),
  npc = npc,
  emote = (nh > 0) and "laugh" or ((lr.sharePay > 0) and "applaud" or "ask"),
})
```

### 6.2 LG session end (from `fxEnd`; queued — the podium must show)

```lua
local sess = S
local rows = {}  -- roster sorted by net desc, name asc, places 1..3 marked
-- build: { text = name .. "  net +" .. PG.Money(net), role = "gold"|"silver"|
--          "bronze"|("win"/"loss" for the field), place = 1|2|3 or nil,
--          personal = (name == me) }
Theme.RevealQueue({
  theme = "goblin", anchor = { mode = "window", host = win },
  variant = "podium",
  title = "FINAL RESULTS",
  subtitle = #sess.roster .. " goblins - pot " .. PG.Money(sess.basePot or 0),
  rows = rows,
  marquee = topName .. " TAKES THE HOARD",
  burst = "coins", burstCount = 12,
  sound = "coins", burstSound = "fanfare",
  npc = npc, emote = bigWin and "dance" or "cheer",
  validate = function() return S == sess and sess.ended == true end,
})
```

### 6.3 RPS round result (from `fxResult`)

```lua
local lr = S.lastResult
local standings = computeStandings()
local rows = {}
for i = 1, #standings do
  local e = standings[i]
  rows[#rows + 1] = {
    text = e.place .. ". " .. e.name .. "  -  " .. e.pts .. " pts",
    role = (e.place == 1) and "gold" or "body",
    personal = (e.name == myName()),
  }
end
Theme.Reveal({
  theme = "faire", anchor = { mode = "window", host = win },
  title = "ROUND " .. lr.r,
  subtitle = "Rock " .. lr.nR .. " - Paper " .. lr.nP .. " - Scissors " .. lr.nS
    .. (lr.nX > 0 and (" - " .. lr.nX .. " sat out") or ""),
  rows = rows,
  marquee = shortOf(standings[1].name) .. " LEADS",
  burst = "stars", burstCount = 8,
  sound = ((lr.myGain or 0) > 0) and "settled" or "page",
})
```

### 6.4 RPS final podium (from `fxEnd`; queued)

```lua
local sess = S
local rows = {}
for i = 1, #sess.standings do
  local e = sess.standings[i]
  rows[#rows + 1] = {
    text = e.place .. ". " .. e.name .. "  -  " .. e.pts .. " pts",
    role = (e.place == 1 and "gold") or (e.place == 2 and "silver")
        or (e.place == 3 and "bronze") or "fade",
    place = (e.place <= 3) and e.place or nil,
    personal = (e.name == myName()),
  }
end
Theme.RevealQueue({
  theme = "faire", anchor = { mode = "window", host = win },
  variant = "podium",
  title = "FINAL RESULTS",
  subtitle = "Best of " .. sess.rounds,
  rows = rows,
  marquee = champLine,          -- e.g. "GRUNT TAKES THE CROWN"
  burst = "stars", burstCount = 12,
  sound = "page", burstSound = "fanfare",
  validate = function() return S == sess and sess.ended == true end,
})
```

(No `npc` — the RPS window has no goblin.)

### 6.5 PB settled markets (queued alongside the existing toasts; screen mode —
PB has no persistent game window)

```lua
local a = attempt   -- captured at settlement time
local rows = {
  { text = "Kill bet: 3 winners split " .. PG.Money(potK), role = "win" },
  { text = "Boss HP bet: void (not enough action)",        role = "fade" },
  { text = "First death bet: settling...",                 role = "body" },
  { text = "You +" .. PG.Money(mine), role = "win", personal = true },  -- when mine ~= nil
}
Theme.RevealQueue({
  theme = "faire", anchor = { mode = "screen" },
  title = "THE BOOK SETTLES",
  subtitle = killed and "Kill!" or ("Wipe at " .. pct .. "%"),
  rows = rows,
  marquee = "STAKE " .. PG.Money(book.stake) .. " A BET",
  burst = "tickets", burstCount = 10,
  sound = "settled",
  npc = nil,  -- the bookie lives on the config dialog; pass its handle only if
              -- the dialog is the natural stage neighbor (Emote self-gates on
              -- visibility either way)
  validate = function() return true end,  -- settlement info is never stale
})
```

---

## 7. Engine integration notes (this pass)

- All code lands in `Theme.lua` (no TOC change). New file-scope items: the two
  `PG.Theme` functions plus pure locals (queue table, state constants). All
  construction lazy.
- Do NOT modify `Games/` files, `Widgets.lua`, or `Core.lua`. The examples in
  section 6 are for the later integration pass, which will also REMOVE the
  game-local A3-A7 reveal calls the stage supersedes (LG's
  glow/starburst/CoinBurst/banner cluster in `fxResult`/`fxEnd`; RPS's
  `fxResult`/`fxEnd` banners) so the stage never competes with them.
- The existing `Theme.Banner`/`Theme.Stamp`/`Theme.CoinBurst` APIs are
  unchanged and remain in use for non-reveal moments (BEGIN banner, VOID
  stamp, join-phase pulses).
- Verify: `/opt/homebrew/bin/luac -p PengyouGames/Theme.lua`; ASCII only; no
  new globals; every Blizzard call pcall'd with the documented fallback.
