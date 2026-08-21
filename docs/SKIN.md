# PengyouGames — Skin & FX Specification (SKIN.md)

Art direction for the v1 reskin. One design, no options. Every asset referenced here is
from the verified 12.1 asset table (research doc); nothing else may be used. This spec
maps onto the frames that exist today in `Widgets.lua`, `Launcher.lua`, `Ledger.lua`,
`Games/LootGoblins.lua`, `Games/PullBook.lua` — identifiers below (`ui.info`, `ui.bar`,
`strip.rows`, …) are the real ones in code.

## 0. Non-negotiable contract (restated; violating any is a bug)

- Every `SetAtlas` / `SetTexture` / `SetDisplayInfo` / `PlaySound` / `SetFont` goes through
  a `PG.Theme` helper that pcalls the Blizzard call and applies the documented fallback
  (solid color / plain template / no-op). Helpers never propagate errors. Gameplay never
  branches on whether art rendered (sole exception: `npc.ok`, which only picks between two
  purely decorative layouts).
- Safety hide stays instant. `PG.Theme.Skin` HookScript's `OnHide` on every skinned window:
  every Theme-created AnimationGroup on that window gets `:Stop()` (never `:Finish()`),
  every particle/FX texture is hidden, and all pending `C_Timer` FX callbacks are
  invalidated (generation counter, section 5.9). No Theme code ever calls `Show()` on a
  window, and no animation callback may re-show anything.
- Sounds: `PG.Theme.Sound` is the only sound entry point. Gated on `db.profile.sounds`
  (default false), `not InCombatLockdown()`, and no Safety flag set (`inCombat`,
  `inEncounter`, `readyCheck`, `countdown`, `restricted`). Channel `"SFX"`, always pcall'd.
- Performance: no persistent `OnUpdate` for decoration; AnimationGroups built once per
  frame at construction and reused via `:Restart()`; coin pool is exactly 12 textures,
  global, reused; no decorative loop runs longer than 4 s (a one-shot timer stops it).
- WoW Lua 5.1, ASCII sources, no new globals, file-scope purity: `Theme.lua` defines only
  `PG.Theme` functions/tables at file scope; all frames, textures, pools, and groups are
  created lazily on first use at runtime.

---

## 1. Design language

Three themes. Each surface is assigned exactly one:

| Theme key   | Identity                         | Used by |
|-------------|----------------------------------|---------|
| `"goblin"`  | Goblin heist: warm parchment, gold-leaf dialog frame, treasure chest, coins | LG host dialog, LG invite Ask, LG game window |
| `"faire"`   | Darkmoon bookmaker: chalkboard black-violet, chalk lettering, parchment ticket stubs, tarot emblems | PB config dialog, PB bet strip |
| `"neutral"` | Brass-and-parchment house style   | Launcher, Ledger (+ clear confirm), shared Toast |

### 1.1 Palettes

All colors given as float RGB (for `SetColorTexture`/`SetTextColor`/vertex color) and hex
(for `|cffRRGGBB` escape codes). These are THE values; do not invent siblings.

**goblin (dark ink on light parchment):**

| Name | Float | Hex | Use |
|---|---|---|---|
| PARCH   | 0.82, 0.72, 0.55 | d1b78c | fallback body color when parchment art fails |
| INK     | 0.25, 0.17, 0.08 | 402c14 | all body text on parchment |
| AMBER   | 0.48, 0.29, 0.00 | 7a4a00 | emphasis text (pot amounts, "you") on parchment |
| GOLD    | 1.00, 0.82, 0.00 | ffd200 | text on dark elements only (ribbon, buttons, title) |
| LOSS    | 0.56, 0.09, 0.00 | 8f1600 | hoard/negative on parchment |
| WIN     | 0.08, 0.32, 0.08 | 145214 | share/positive on parchment |
| FADE    | 0.42, 0.36, 0.26 | 6b5c42 | de-emphasis ("no pick", spectator) on parchment |

**faire (chalk on chalkboard):**

| Name | Float | Hex | Use |
|---|---|---|---|
| BOARD   | 0.07, 0.08, 0.10 | 12141a | fallback board color |
| VIOLET  | 0.45, 0.32, 0.68 | 7352ad | border vertex tint, accent rules |
| CHALK   | 0.95, 0.93, 0.87 | f2eede | body text |
| CHGOLD  | 1.00, 0.85, 0.46 | ffd876 | headings, stakes |
| CHRED   | 1.00, 0.54, 0.44 | ff8a70 | losses, NO/UNDER accents |
| CHGREEN | 0.49, 0.93, 0.64 | 7deda4 | wins, locked-pick highlight |
| CHGRAY  | 0.66, 0.66, 0.61 | a8a89c | tallies, hints |

**neutral (brass house style):** reuses goblin INK/AMBER/WIN/LOSS/FADE on its parchment
inset, plus BRASS 0.80, 0.68, 0.42 (cc ad 6b -> hex `ccad6b`) for border vertex tint and
GOLD for titles on the dark frame area.

`PG.Theme.C(theme)` (section 5.8) exposes these as both floats and prebuilt `"|cff..."`
strings. `LootGoblins.lua`, `Ledger.lua`, and `PullBook.lua` replace their local
`GREEN/RED/GRAY/GOLD` constants with the theme table at init (surfaces that render on
parchment use WIN/LOSS/FADE/AMBER; the toast, on the open world, keeps bright hexes:
CHGREEN/CHRED/CHGRAY/CHGOLD).

### 1.2 Typography

- **Display font:** `Fonts\MORPHEUS.TTF` — window titles, banner text, stamp text, pot
  amount, PB strip heading. Applied via `PG.Theme.SetHeader(fs, size)` which pcalls
  `fs:SetFont("Fonts\\MORPHEUS.TTF", size, "")`, checks the boolean return, and on failure
  calls `fs:SetFontObject(GameFontNormalLarge)` (or `GameFontNormalHuge` for size >= 20).
  Sizes used: 20 (window titles), 18 (pot amount), 16 (banner), 15 (stamp), 14 (PB strip
  heading).
- **Body:** existing Blizzard font objects, unchanged: `GameFontNormal`,
  `GameFontHighlight`, `GameFontHighlightSmall`, `GameFontNormalSmall`. Theme recolors
  per-instance with `fs:SetTextColor(...)` (never touches the shared font objects).
- Every FontString sitting on world-visible or busy art gets
  `fs:SetShadowColor(0,0,0,0.8); fs:SetShadowOffset(1,-1)` — chalk text on the faire
  board, all toast text, all text on ribbons/buttons. Ink-on-parchment text gets NO
  shadow (shadow muddies dark-on-light).

### 1.3 Backdrop and border treatment per window

`PG.UI.Window` keeps producing the current plain backdrop; `PG.Theme.Skin(win, theme)`
is then called by each module right after `PG.UI.Window` returns, and restyles:

| Theme | bgFile | edgeFile / edge treatment | Overlay art |
|---|---|---|---|
| goblin | `Interface\DialogFrame\UI-DialogBox-Background` (tile 32) | `Interface\DialogFrame\UI-DialogBox-Gold-Border`, edgeSize 32, insets 11 | full-inset ARTWORK texture `Interface\AchievementFrame\UI-Achievement-Parchment-Horizontal` stretched to the insets; on failure `SetColorTexture(PARCH)` |
| faire | `Interface\DialogFrame\UI-DialogBox-Background-Dark` (tile 32) | `Interface\Tooltips\UI-Tooltip-Border`, edgeSize 16, insets 4, `SetBackdropBorderColor(VIOLET)` | none (the dark tile IS the chalkboard); on bg failure `SetColorTexture(BOARD, a=0.95)` |
| neutral | `Interface\DialogFrame\UI-DialogBox-Background` (tile 32) | `Interface\Tooltips\UI-Tooltip-Border`, edgeSize 16, insets 4, `SetBackdropBorderColor(BRASS)` | parchment inset panel only where specified (Ledger body) |

Backdrop application itself is pcall'd; on failure the window keeps the current
tooltip-style backdrop (today's look is the ultimate fallback everywhere).

Close button: unchanged `UIPanelCloseButton` on all windows.

Button doctrine (applies addon-wide): **primary game actions** (SHARE, HOARD, PB market
picks) get themed card faces (spec below). **Everything else** — Ask Accept/Decline,
Start now, Cancel game, Withdraw, Open Ledger, launcher buttons, ledger tabs, dialog
Open buttons — stays `UIPanelButtonTemplate`, with icon markup added to labels via
`PG.Theme.Mark`. This bounds risk and keeps admin actions instantly recognizable.

---

## 2. Per-surface specifications

### 2.1 Launcher (`Launcher.lua`, window key "launcher")

- Size 220x230 -> **240x250**. Theme `"neutral"`. Title "Pengyou Games" in Morpheus 20,
  GOLD.
- Buttons unchanged in behavior/template; labels gain markup prefixes:
  - Loot Goblins: `Mark("coin") .. " Loot Goblins..."` (coin = atlas
    `auctionhouse-icon-coin-gold`)
  - Pull Book: `Mark("ticket") .. " Pull Book..."` (ticket = fileID icon
    `Interface\Icons\INV_Misc_Ticket_Darkmoon_01`)
  - Ledger: `Mark("sack") .. " Ledger"` (sack = atlas `Garr_TreasureIcon`)
  - DND toggle: text only (state text must stay maximally plain).
- On `OnShow` (via Skin): `PG.Theme.Pop(win)`. Sound `"open"` (852) on manual open only.

### 2.2 LG host dialog (`ensureDialog`, window key "lgdialog")

- Size 300x250 -> **320x270**. Theme `"goblin"` (gold border + parchment).
- Title "Start Loot Goblins", Morpheus 20, GOLD (title sits on the gold header area, not
  parchment). Optional crown: `Interface\DialogFrame\UI-DialogBox-Gold-Header` 300x64
  behind the title, text re-anchored into it; on failure plain title (helper handles).
- Field labels (`makeField` FontStrings): SetTextColor(INK). EditBoxes unchanged
  (`InputBoxTemplate`).
- "Open buy-in" button: `UIPanelButtonTemplate`, label `Mark("coin") .. " Open buy-in"`.
- Sound `"stamp"` (5274) fires from the Open click (out-of-combat by definition of the
  dialog being visible; still gated by Theme.Sound).

### 2.3 LG invite Ask (`buildAsk` in Widgets.lua)

The Ask factory grows one optional theme arg: `PG.UI.Ask(key, text, acceptLabel,
declineLabel, timeoutSec, onAccept, onDecline, theme)`. LG passes `"goblin"` for
`"lg-invite"`; RPS passes `"faire"` for `"rps-invite"` (chalkboard treatment: CHALK
body text + shadow, CHRED countdown + shadow, `"dice"` icon, `"ticket"` show sound,
`"click"` accept / `"coincancel"` decline - rule 6.1's chalk-on-board pairs); every
other caller omits it -> current plain look. The goblin treatment below is unchanged.

- Size 340x130 -> **360x140** when themed. Backdrop: goblin treatment, parchment overlay
  from `UI-Achievement-Parchment-Horizontal` (wide, matches the shape).
- Coin stack icon: `PG.Theme.Icon(f, "coinpile", 36)` -> `Interface\Icons\INV_Misc_Coin_02`
  anchored LEFT (16, 8). `f.text` re-anchored TOPLEFT (62,-18) / TOPRIGHT (-18,-18),
  `SetTextColor(INK)`, justify LEFT.
- `f.timerText`: SetTextColor(LOSS) — the countdown is the urgency cue; the number itself
  never animates.
- Buttons stay `UIPanelButtonTemplate` (raid-facing reliability); Accept label comes from
  the caller ("Buy in") prefixed `Mark("coin")`.
- Show: `PG.Theme.Pop(f)` (0.15 s; plays only when actually shown — deferred safety shows
  call Pop from the same `showAskIfSafe` path). Sound `"greet"` (5964, the zany vendor
  bark) on first show of an lg-invite Ask.
- Accept click -> sound `"coinlock"` (865). Decline -> `"coincancel"` (866).

### 2.4 LG game window (`ensureWindow` in LootGoblins.lua, window key "lg")

Size 380x520 -> **440x620**. Theme `"goblin"`. Geometry (all offsets from the window,
implementers may nudge +/-8 px but keep the column split):

```
Title ribbon   atlas ui-frame-neutral-ribbon, 320x40, TOP (0,-10); title text centered
               on it, Morpheus 20, GOLD. Ribbon fail -> title text alone (current look).
Chest         `ChallengeMode-Chest` atlas, 56x56, TOPLEFT (24,-50). Fail -> Icon
               INV_Misc_Coin_02 48x48 in the same slot (fixed 56x56 frame either way;
               layout never depends on atlas dimensions).
Glow           `loottoast-glow`, 140x140, BLEND ADD, centered on the chest, alpha 0,
               shown only by the reveal choreography. Fail -> layer skipped.
ui.info        TOPLEFT (88,-52), TOPRIGHT (-150,-52). Pot amount rendered inside it via
               Theme.Money(); FontString recolored AMBER. Morpheus 18 on the pot-only
               join-phase line is NOT used - info stays GameFontNormal for mixed text.
ui.bar         TimerBar re-anchored TOPLEFT (24,-112), width 260 (skin below, 2.4.1).
Goblin model   container 120x150, TOPRIGHT (-18,-44). See 2.4.2.
Nameplate      GameFontNormalSmall under the model, "Grizzle the Pit Boss", INK.
ui.shareBtn    themed card button 190x46, TOPLEFT (24,-206).
ui.hoardBtn    themed card button 190x46, TOPRIGHT (-24,-206).
ui.status      TOPLEFT (24,-262), TOPRIGHT (-24,-262), INK.
rows           rowAt(i): TOPLEFT (26, -286 - (i-1)*17), width 388, 16 rows, INK; the
               inline color codes switch to C("goblin") hexes (WIN/LOSS/FADE/AMBER).
ui.mine        BOTTOMLEFT (24,46) / BOTTOMRIGHT (-24,46), INK with AMBER money.
Gold pile      atlas islands-queue-prop-coins, 220x48, BOTTOM (0,10), alpha 0.35,
               BACKGROUND layer, behind the bottom buttons. Fail -> hidden. Decor only.
Bottom btns    startBtn/cancelBtn/withdrawBtn/ledgerBtn unchanged positions/templates.
```

**2.4.1 Timer bar skin** (applies to `PG.UI.TimerBar` when the parent window is skinned
goblin): StatusBar texture -> atlas `lootroll-timer-fill` via
`bar:GetStatusBarTexture():SetAtlas(name, false)` pcall'd; behind it
`lootroll-timer-background`, on top `lootroll-timer-border`. Vertex color (1, 0.85, 0.4).
Fallback: current `UI-StatusBar` + solid color. The bar and its text NEVER animate; no
low-time flash; color constant for the whole round.

**2.4.2 The goblin host.** `local npc = PG.Theme.NPC(win, "host")`, container as above.

- Display ID: **6882** (clothed vanilla goblin vendor, HD model). At session start Theme
  picks 6882 or **7034** at random (once per `PG.Theme.NPC` call) so the host varies
  between nights. Failure chain: 6882 -> 7034 -> **2454** (classic low-poly; every emote
  guarded by `HasAnimation`) -> `npc.ok = false` and the container shows the static
  fallback: `Icon("coinpile", 48)` centered (a coin-stack icon; window layout unchanged).
- Model setup: `SetPortraitZoom(0.62)`, `SetCamDistanceScale(1.15)`,
  `SetRotation(-0.35)` (3/4 view facing the play area), `SetKeepModelOnHide(true)`;
  pose only from the `OnModelLoaded` script.
- Emote plan (via `npc:Emote(name)`, mapping in 5.7):

| Moment (code site) | Emote | Anim ID |
|---|---|---|
| window first shows for a session (`ShowWindow`) | `greet` | 67 wave (+ sound "greet") |
| join phase, each `applyJoined` (not self-echo spam: rate-limit 1/s) | `nod` | 185 |
| join phase idle / round open (`applyRound`) | `talk` | 60 (loops) |
| **buy-in complete** (`applyBegin`) | `excited` | 64 talk-exclamation |
| local player locks a pick (`doPick` success) | `nod` | 185 |
| **hoarder win** (RESULT, nh>0 and hoardPay>0) | `laugh` | 70 (+ VO 23330) |
| hoarders busted (nh>0, hoardPay==0) | `laugh` | 70 |
| **sharer win** (RESULT, nh==0, sharePay>0) | `applaud` | 80 (the goblin only golf-claps for sharing - comedy beat) |
| nobody picked (RESULT all-X) | `ask` | 65 talk-question |
| VOID (`applyVoid`) | `ask` | 65 |
| **session end** (`applyEnd`) | `cheer` | 68 (+ VO 19089); if one player's net >= basePot/2: `dance` 69 for 4 s instead |
| after any one-shot | auto-reset to `idle` (0) per 5.7 |

### 2.5 LG reveal choreography (the money moment)

Fires from `applyResult` / `applyEnd` ONLY when `win` exists and `win:IsShown()` (Safety
already guarantees reveals arriving mid-combat stay windowless; the choreography is
skipped, text state still updates — gameplay never waits for FX).

Sequenced by ONE reusable "reveal" plan; timeline zero = RefreshUI having set all final
text (text is readable from frame one; FX decorate, never precede, the information):

1. **t=0 Glow:** chest glow group: Alpha 0 -> 0.7 (0.25 s, OUT) then endDelay 0.5, Alpha
   -> 0 (0.45 s, IN), all order 1/2 in one group. ADD blend.
2. **t=0 Starburst:** `OBJFX_StarBurst` 48x48 at the chest center, ADD: Scale 0.5 -> 1.4
   (0.35 s, OUT) + Alpha 0 -> 0.9 (0.12 s) + Alpha -> 0 (0.2 s, order 2). Fail -> layer
   skipped (fallback `Interface\Cooldown\star4`, else nothing).
3. **t=0 Coin shower** (`PG.Theme.CoinBurst(win, n)`): global pool of exactly **12**
   textures `Interface\MoneyFrame\UI-GoldIcon`, 14x14, built once with per-coin groups.
   Per coin: Path (curve SMOOTH, 2 control points randomized ONCE at pool build; cp1 =
   up-and-outward arc offset x in [-90..90], y in [+55..+105]; cp2 = fall to x in
   [-130..130], y in [-150..-200]) + Rotation (degrees in [-200..200], full duration) +
   Alpha 1 -> 0 (duration 0.30, startDelay 0.60), all order 1. Coin duration 0.9 s;
   per-coin `SetStartDelay(0.05 * i)` stagger baked in at build. Origin: the chest
   (`win.__pgFXOrigin`). Count n: hoard-only reveal 6, shared reveal 10, END 12.
   OnFinished per coin hides it. Fallback texture: 8x8 gold `SetColorTexture(1,0.82,0,1)`
   dots — shower still reads. Only one shower at a time: a new call `:Stop()`s and
   `:Restart()`s the pool.
4. **t=0.1 Hoarder stamps:** pool of **8** `common-icon-redx` textures, 26x26,
   `SetRotation(-0.14)`, one per hoarder row (H chars in the pattern), anchored LEFT of
   `rowAt(i)` at (-2, 0), stagger 0.06 s: Scale 2.2 -> 1.0 (0.18 s, IN) + Alpha 0 -> 1
   (0.12 s). More than 8 hoarders: rows 9+ get text-only LOSS color (current behavior).
   Stamps hide on the next RefreshUI that changes rows, and on OnHide. Fallback: no
   texture; the LOSS-colored "HOARD +x" annotation carries the meaning.
5. **t=0.15 Banner:** `PG.Theme.Banner(win, text, "goblin")` slides across the top of the
   roster area (anchor TOP of row 1, y +26): RESULT -> "ROUND r", everyone-shared ->
   "EVERYONE SHARED", hoarders busted -> "GREED PUNISHED", END -> "FINAL RESULTS".
   Composition in 5.5.
6. **Goblin emote** per 2.4.2 table, at t=0.2.
7. **END only, t=0.4:** sparkle garnish: two `Interface\Cooldown\star4` 20x20 ADD
   textures at the chest corners, one group, Alpha 0.15 <-> 0.75 (0.5 s, IN_OUT),
   `SetLooping("BOUNCE")`; a `PG.After(4, ...)` (generation-checked) calls `:Stop()`.
   The flipbook sparkle (`housing-celebrationtoast-sparkledust-flipbook`) is NOT used in
   v1 — grid params unconfirmed; star4 is the shipped choice, per the asset table's own
   fallback guidance.

Sounds at reveal (all through Theme.Sound gates): RESULT with any payout -> `"coins"`
(120); RESULT hoard win adds `"laugh"` (23330); shared win -> `"settled"` (878);
END -> `"fanfare"` (888) + `"cheer"` (19089); VOID -> `"coincancel"` (866).

### 2.6 PB config dialog (`buildDialog` in PullBook.lua, window key "pullbook")

- Size 320x240 -> **340x300**. Theme `"faire"` (chalkboard + violet border).
- Title "The Pull Book", Morpheus 20, CHGOLD, shadowed.
- Poster header: atlas `warboard-parchment`, 300x88, TOP (0,-34), with the hint text
  (`hint` FontString) re-anchored INSIDE it, INK, wrapped — the "notice board" flavor.
  Atlas fail -> hide poster, hint sits on the board in CHGRAY (current anchor).
- Field labels CHALK; EditBoxes unchanged.
- "Open book" button label: `Mark("ticket") .. " Open book"`. Click -> sound `"stamp"`
  (5274). "Close book" -> sound `"bookclose"` (5275) — manual close only.
- `statusFS` (book-open state) in CHALK with CHGOLD money via `Theme.Money`.
- Bookie decor: `PG.Theme.NPC(dlg, "bookie")` in an 80x100 container BOTTOMLEFT (18,16) —
  display **7051** (gruff goblin) -> 6882 -> static `Icon("ticket", 40)`. Emotes used:
  `greet` on dialog show, `idle` otherwise. Pure decoration.
- When the book opens/closes, `PG.Theme.Stamp(dlg, "BOOK OPEN" / "BOOK CLOSED")` slams
  across the poster area (5.6).

### 2.7 PB bet strip (`buildStrip` in PullBook.lua)

The strip appears during ready check / countdown: it is the **calm surface**. Rules:
instant show (NO entrance animation), NO sounds ever (Theme.Sound is structurally silent
during ready/countdown anyway), only one micro-animation exists (lock-in pop).

- Size 400x124 -> **420x152**. Theme `"faire"`. Strata HIGH (unchanged), not
  Safety-registered (unchanged — module hides it manually).
- `strip.title`: Morpheus 14, CHGOLD, shadowed, prefixed `Mark("ticket")`; text
  unchanged ("The Pull Book - 100g a bet").
- Three market rows, height 34, at y = -34, -68, -102:
  - Emblem 20x20 left of the label, per market (file icons):
    K -> `Interface\Icons\INV_Misc_Ticket_Tarot_Heroism_01`,
    D -> `Interface\Icons\INV_Misc_Ticket_Tarot_Beasts_01`,
    W -> `Interface\Icons\INV_Misc_Ticket_Tarot_Maelstrom_01`.
    Fail -> no emblem (labels carry meaning).
  - Label (`Kill?` / `First death` / `Boss HP`) CHALK, at x 40.
  - **Ticket-stub buttons** (`strip.rows[m][i]`, currently UIPanelButtonTemplate 88x22):
    become plain `Button`s 92x26 with atlas `ui-frame-neutral-cardparchment` as the
    NormalTexture (pcall; fail -> revert to UIPanelButtonTemplate construction, the
    current look). Face text GameFontHighlightSmall recolored INK (dark on parchment
    card). Highlight texture: full-face `SetColorTexture(1, 0.82, 0, 0.18)`, ADD.
    Pushed state: label offset (1,-1).
  - Lock state (refreshStrip): your locked pick keeps its full card, text WIN green
    (`145214`), and a 14x14 `INV_Misc_Ticket_Darkmoon_01` ticket pinned to the card's
    top-right corner (pool of 3, one per market); the other buttons in that market drop
    to `SetAlpha(0.45)` and disable. Unlocked markets: full alpha, enabled.
  - **Chalk tally** per row, right-aligned at x -14: live backer counts from
    `attempt.bets` in CHGRAY, e.g. `3 : 1` (K/W) or `2 / 1 / 0` (D), updated inside
    `refreshStrip`. A 1px chalk rule under each row: `SetColorTexture(CHALK, a=0.30)`,
    x 14..-14. This is the "chalkboard odds" — counts, not prices; parimutuel flavor.
- Lock-in pop: on successful local lock (the `onSent` callback path that calls
  `refreshStrip`), the locked button plays Pop (Scale 1 -> 0.94 -> 1.0, 0.12 s total).
  Nothing else on the strip ever animates.

### 2.8 PB result toast

Results ride the existing queued `PG.UI.Toast` (700x26 top strip, OnUpdate fade —
pre-existing, kept). Theming:

- Toast text gets `SetShadowColor/Offset` per 1.2 (always; it floats over the world).
- PullBook prefixes its queued lines with `Mark("ticket") .. " "`; LootGoblins toasts
  prefix `Mark("coin") .. " "`. Money inside toast lines uses bright hexes (CHGOLD for
  pots, CHGREEN/CHRED for personal +/-), via `C("faire")` / `C("neutral")` as the caller's
  surface dictates.
- Sound on a drained PB result toast that contains a personal delta: `"settled"` (878).
  (Toasts drain only when `canToastNow()` — out of encounter/combat — so the gate
  composes with Theme.Sound's own checks.)
- No added animation: the toast's existing fade is its entire motion budget.

### 2.11 MP parley window (`buildDialog` in MythicParley.lua, window key "parley")

520 wide, and the only window in the suite with **two heights**: 620 for the card builder,
`124 + 44n + 130` for an n-line board. The reason is in `PARLEY.md` 7.2; the presentation
consequence is that the height change is a real state transition, so it gets an A1 pop
(`Theme.Pop`) fired on the transition only — never from a repaint, or an inbound bet would
strobe it.

- **Setup side.** Stake row, a `<` name `>` dungeon picker (never a dropdown, SCOPE.md 5.1),
  the audience picker, then the card: a scrolling checkbox list under a `goldheader` plate.
  The plate is the only art on this surface and it is positioned whether or not it renders,
  per 2.6's rule. Parchment is deliberately NOT used behind the list: Blizzard's own
  `UICheckButtonTemplate` art sits on it badly and chalk-on-parchment stops being readable.
- **Board side.** One row per card line: accent emblem, chalk label, backer tally *under* the
  label (a six-option boss row needs the full width), and a right-aligned block of card-face
  buttons. Blocks right-align to a common edge whatever they hold, so rows of two and rows of
  six read as one column; rows of four or more step down to the S font, because a
  ten-character boss name does not fit a 72px card at display size. Boss buttons carry the
  short name with the full one on the tooltip.
- **Motion budget: one animation.** A2 on the just-locked button, and nothing else. The board
  can be on screen for the whole walk to the portal, and a surface that lives that long earns
  restraint rather than decoration (rule 6.3).
- **Stamps (A8):** `PARLEY OPEN` on open, `NO MORE BETS` on lock, `SETTLED` on the frozen
  report.
- **There is no goblin bookie on this window**, and the Pull Book having one is the reason to
  say why. The first cut put him bottom-right and hid him whenever a parley went live, because
  the board spends its full width on buttons and its full height on rows. Hiding him meant
  toggling his container on every repaint — and `Theme.NPC` hooks `OnShow` there to **re-probe a
  model load a hide interrupted**, re-applying `SetDisplayInfo` and the camera. A10 is explicit
  that the hide path makes no model call, so a surface that hides him on every state change is
  not a surface that can have him. The visible result was a goblin spinning in the corner. He is
  absent rather than present-and-toggled, and the reveal payload carries no handle at all.

### 2.9 Ledger window (key "ledger") + Settle Up + confirm

- Size 400x440 unchanged. Theme `"neutral"`. Title "Pengyou Ledger" Morpheus 20 GOLD.
- Parchment sheet: ARTWORK texture, atlas `questbg-parchment` stretched over the rows
  area (16,-76) to (-16,56); fail -> `UI-Achievement-Parchment-Horizontal`, then PARCH
  color. Rows render on this sheet: `rowAt(i)` FontStrings recolored INK; the hex
  constants swap to `C("neutral")`: WIN/LOSS/FADE/AMBER (dark-on-parchment safe).
- Tabs `Tonight` / `Settle Up`: keep UIPanelButtonTemplate (doctrine 1.3); switching tabs
  plays sound `"page"` (836).
- Settle lines: own lines ("YOU pay ... / ... pays YOU") in AMBER with `Theme.Money`
  amounts; third-party lines INK. A 16x16 `Garr_TreasureIcon` via markup heads the
  "Settle Up" tab's first line region as a section glyph (markup, zero frames).
- "Clear tonight" confirm: theme `"neutral"`, text INK on a small parchment inset, Clear
  button label recolored LOSS via escape code. No animation beyond Pop.
- Open: Pop + sound `"parchment"` (844).

### 2.10 Shared `PG.UI.Window` factory changes (Widgets.lua)

`PG.UI.Window` gains nothing; each module calls `PG.Theme.Skin(win, theme)` after
creation. Skin: applies 1.3 backdrop treatment, restyles `f.title` (Morpheus + theme
color + optional ribbon/header per surface notes), creates `win.__pgFX` (the fx child
frame, `SetFrameLevel(win:GetFrameLevel()+5)`, all-points), installs the OnHide hook
(5.9), attaches `Pop` to OnShow via HookScript, and stores `win.__pgTheme`.

---

## 3. Animation choreography table

Every animated moment in the addon. "Comp" lists child animations (type / duration s /
smoothing / order). All groups are created once at frame construction and replayed with
`Restart()`. OnHide column: what the Safety/OnHide path does (always via `:Stop()` —
snap to base state instantly; never `Finish`).

| # | Moment | Trigger (code site) | Target | Comp | Loop | OnHide/Stop behavior |
|---|--------|--------------------|--------|------|------|----------------------|
| A1 | Window pop-in | OnShow hook of every skinned window/Ask | window | Scale 0.92->1.0 /0.18/OUT/1 + Alpha 0.6->1 /0.15/OUT/1 | NONE | Stop; base state is final state (SetToFinalAlpha true) |
| A2 | Button lock pop | LG doPick ok; PB lock onSent; **MP bet lock onSent** | the clicked button | Scale 1->0.94 /0.06/IN/1 then 0.94->1 /0.06/OUT/2 | NONE | Stop; button scale snaps to 1 |
| A3 | Chest glow | LG applyResult/applyEnd (win shown) | glow tex (ADD) | Alpha 0->0.7 /0.25/OUT/1 + Alpha 0.7->0 /0.45/IN/2 (endDelay 0.5 on order 1) | NONE | Stop; alpha snaps 0; texture hidden |
| A4 | Starburst | same as A3 | starburst tex (ADD) | Scale 0.5->1.4 /0.35/OUT/1 + Alpha 0->0.9 /0.12/NONE/1 + Alpha ->0 /0.2/IN/2 | NONE | Stop; hidden |
| A5 | Coin shower | Theme.CoinBurst (LG reveal/end) | 12 pooled coin texs | per coin: Path(SMOOTH,2cp) /0.9/NONE/1 + Rotation +-200deg /0.9/NONE/1 + Alpha 1->0 /0.3 startDelay 0.6 /NONE/1; per-coin startDelay 0.05*i | NONE | Stop all 12 groups; all coins hidden; pool reusable immediately |
| A6 | Hoarder stamp slam | LG applyResult (H rows) | up to 8 redx texs | Scale 2.2->1.0 /0.18/IN/1 + Alpha 0->1 /0.12/NONE/1; stagger 0.06*i | NONE | Stop; stamps hidden (also hidden by next roster refresh) |
| A7 | Banner slide | LG BEGIN/RESULT/VOID/END | banner frame | Translation x -40->0 /0.25/OUT/1 + Alpha 0->1 /0.2/NONE/1 + Alpha 1->0 /0.3/IN/2 (endDelay 1.6 on order 1) | NONE | Stop; banner hidden; OnFinished hides |
| A8 | Stamp (text) slam | PB book open/close; LG VOID ("VOIDED") | stamp frame | Scale 2.0->1.0 /0.18/IN/1 + Alpha 0->1 /0.12/NONE/1 + Rotation -6deg /0.12/OUT/1 (wobble; rotation not persisted - settles straight) + Alpha 1->0 /0.4/IN/2 (endDelay 2.0) | NONE | Stop; hidden |
| A9 | END sparkles | LG applyEnd only | 2 star4 texs (ADD) | Alpha 0.15<->0.75 /0.5/IN_OUT/1 | BOUNCE | Stopped by PG.After(4) (gen-checked) AND by OnHide Stop |
| A10 | Goblin emotes | per 2.4.2 table | PlayerModel | SetAnimation(id); one-shots reset to 0 via PG.After(dur) with gen check (durations: nod 1.2, wave/excited 2.0, laugh/cheer/applaud 2.5, dance 4.0; talk loops until :Emote("idle")) | n/a | OnHide: cancel/invalidate reset timer; SetKeepModelOnHide(true); NO model call in the hide path; next Show re-idles |
| A11 | Toast fade | existing PG.UI.Toast OnUpdate | toast | pre-existing alpha fade (kept as-is; not an AnimationGroup) | n/a | already Safety-registered; Hide kills it |
| A12 | Timer bars | — | — | NEVER animated beyond SetValue; no flash, no pulse | — | — |

Notes: A5 Path smoothing is NONE (gravity look comes from the control points). Groups
A3+A4+A5+A6+A7 together form the "reveal"; they are the only moment multiple effects
run at once (budget in section 6). All `SetLooping`/`CreateAnimation` calls use literal
strings/numbers only (SecretArguments=NotAllowed rule).

---

## 4. Sound map (default OFF; every entry via `PG.Theme.Sound(key)`)

| Key | SoundKit | Moment |
|---|---|---|
| `open` | 852 | launcher/generic themed window manual open |
| `parchment` | 844 | Ledger opens |
| `page` | 836 | Ledger tab switch |
| `greet` | 5964 | LG invite Ask first show; LG window greet; PB dialog greet |
| `farewell` | 5965 | LG window closed via its close button after a finished session (manual close ONLY; never any Safety/auto path) |
| `coinpick` | 864 | LG buy-in Ask shown-hover moment is NOT used; reserved for future sliders |
| `coinlock` | 865 | Ask Accept (buy-in), JOINED confirmation for self |
| `coincancel` | 866 | Ask Decline, Withdraw, VOID |
| `potclink` | 891 | join phase: another player joins (rate-limit: max 1 per 2 s) |
| `stamp` | 5274 | LG "Open buy-in" click; LG BEGIN (buy-in closes); PB "Open book" |
| `bookclose` | 5275 | PB bookie closes the book (manual only) |
| `ticket` | 39515 | PB dialog buttons (NOT strip buttons - see below) |
| `coins` | 120 | LG reveal with any payout; coin shower impact |
| `laugh` | 23330 | LG hoarder-win reveal (with emote 70) |
| `cheer` | 19089 | LG session end (with emote 68) |
| `settled` | 878 | LG shared-win reveal; PB result toast with personal delta |
| `fanfare` | 888 | LG END winner moment (once per session) |
| `click` | 852 | any other themed button |

Structural guarantee: PB bet-strip interactions occur only during ready check/countdown,
where Theme.Sound's gates make every key silent — the strip is a silent surface by
construction, not by discipline.

**The Mythic Parley's board does NOT have that structure and is silent by DISCIPLINE.**
Betting happens at the dungeon door, out of combat, with every one of Theme.Sound's gates
clear, so a key played on a bet click would actually sound — which is why the click plays
nothing at all and A2's pop is the whole feedback. `MP` plays exactly three keys, the same
three `PB` does: `greet` (window show), `stamp` (open / lock bets), `bookclose` (the bookie
cancelling, manual only). Anything that happens *to* a parley — a timeout, an abandoned key,
a settlement — is silent on the window and speaks only through the shared results stage. `fanfare` and `cheer` may both fire at END: play
`fanfare` only, then `cheer` VO 0.8 s later via gen-checked timer (skipped if hidden).

---

## 5. `Theme.lua` public API (new file; TOC entry inserted directly after `Util.lua`)

File-scope: defines `PG.Theme = {}` plus pure data tables (asset table, palettes, sound
map, emote map). Zero frames/groups/sounds at file scope. All construction lazy.

Universal fallback contract: every helper pcalls each Blizzard art/sound/model call
individually; on failure it applies the documented fallback and continues; helpers never
error out and never return nil where a region/handle is promised.

### 5.1 `PG.Theme.Skin(win, themeName)`

`themeName` in `"goblin" | "faire" | "neutral"`. Applies section 1.3 backdrop + title
treatment, creates `win.__pgFX` (fx child frame) and `win.__pgGen = 0`, hooks OnShow
(gen increment + Pop) and OnHide (5.9), stores `win.__pgTheme`. Idempotent: calling
again only re-applies colors. Returns `win`.

### 5.2 `PG.Theme.Icon(parent, key, size)` -> Texture

Creates an ARTWORK texture on `parent`, `size x size`. `key` indexes Theme's asset table
(`"coin"`, `"coinpile"`, `"ticket"`, `"sack"`, `"chest"`, `"tarotK"`, `"tarotD"`,
`"tarotW"`, `"redx"`, `"dice"`, `"greedcoin"`, `"pass"`, ...). Tries atlas or file per
the table; on failure applies that entry's fallback chain ending in
`SetColorTexture(fallback color)`. ALWAYS returns a Texture. Caller anchors it.

### 5.3 `PG.Theme.Tex(tex, key)` -> boolean

Applies art for `key` onto an existing Texture. Returns true if themed art rendered,
false if the solid-color fallback was applied (already applied by the helper; the return
lets decor callers choose `tex:Hide()` for decoration-only pieces like the gold pile).

### 5.4 `PG.Theme.Mark(key)` -> string

Cached inline markup for FontStrings: `"|A:atlas:0:0|a"` or `"|T fileID:0|t"` per the
asset table, `""` when the entry is marked unavailable at runtime (pcall probe on first
use, cached). Never nil. `PG.Theme.Money(g)` -> `Mark("coin") .. PG.Money(g)`.

### 5.5 `PG.Theme.Banner(parent, text, themeName)` -> banner frame

One banner per parent, created on first call (`parent.__pgBanner`), reused: 260x42,
ribbon atlas `ui-frame-neutral-ribbon` (fail -> solid GOLD bar 260x26), Morpheus 16 text
(goblin: INK on ribbon / faire: CHGOLD on bar), anchored TOP of `parent.__pgBannerSlot`
region if set, else parent TOP (0,-60). Plays A7; replay = `Stop()` + set text +
`Restart()`. No-op (returns frame, nothing plays) if `parent` is not shown.

### 5.6 `PG.Theme.Stamp(parent, text)` -> stamp frame

One per parent, reused: borderless frame with a 2px LOSS-red border box (4 solid
textures), Morpheus 15 text in LOSS red, sized to text +16 px. Plays A8, self-hides.
No-op when parent hidden. Fallback IS the design (no stamp atlas exists on 12.1).

### 5.7 `PG.Theme.NPC(parent, kind)` -> handle

`kind` in `"host"` (LG: display 6882 or 7034 random, then 2454) | `"bookie"` (PB: 7051,
then 6882). Creates a container Frame (caller sizes/anchors it) holding a `PlayerModel`
(pcall CreateFrame + SetDisplayInfo; async pose via OnModelLoaded; setup per 2.4.2).
On total failure the container instead holds `Icon(kindIcon, 48)` (host -> "coinpile",
bookie -> "ticket").

Handle: `{ frame = <container>, ok = <bool>, Emote = function(self, name) }`.
`Emote` names -> anim IDs: `idle 0, greet 67, talk 60, ask 65, excited 64, nod 185,
cheer 68, laugh 70, applaud 80, dance 69, point 84`. Semantics: no-op if `not ok`, if
container hidden, or if `HasAnimation` (pcall'd) is false; one-shots schedule
`SetAnimation(0)` after their 2.4.2/A10 duration through a gen-checked `PG.After` that
no-ops if the window was hidden or gen advanced; `talk` loops until `Emote("idle")`.
Emote never shows/hides anything.

### 5.8 `PG.Theme.C(themeName)` -> color table

Returns the section 1.1 palette for the theme: for each name both floats
(`t.INK = {r,g,b}`) and escape string (`t.ink = "|cff402c14"`). Frozen contents (do not
mutate). Modules capture it once at init.

### 5.9 `PG.Theme.Pop(frame)` / `PG.Theme.Pulse(region)` and the OnHide contract

- `Pop(frame)`: plays A1 on `frame` (group `frame.__pgPop`, lazy-created). No-op if
  hidden.
- `Pulse(region)`: single A2-style scale pulse on any region EXCEPT FontStrings that
  display money or the timer bar (doc-enforced; used for the chest icon on pot growth).
- **OnHide contract** (installed by Skin, and by CoinBurst/Banner/Stamp on their
  parents if unskinned): iterate `win.__pgFXGroups` (every group Theme created for this
  window is registered there at creation) calling `:Stop()`; hide all pooled/FX
  textures; `win.__pgGen = win.__pgGen + 1` (invalidates every pending Theme timer:
  timers capture gen at schedule time and compare before acting). Additionally
  `win.__pgFX:StopAnimating()` as belt-and-braces. The hide path performs NO model
  calls, NO sound, NO Show, and completes synchronously.

### 5.10 `PG.Theme.CoinBurst(parent, n)` and `PG.Theme.Sound(key)`

- `CoinBurst(parent, n)`: n clamped to [1,12], default 10. The single global 12-coin
  pool reparents to `parent.__pgFX`, anchors at `parent.__pgFXOrigin` (region; Skin sets
  the LG chest) else parent TOP, shows coins 1..n, `Restart()`s their groups (A5).
  No-op when parent hidden. Second call mid-flight restarts (bounded by pool size).
- `Sound(key)`: looks up section 4; silently no-ops unless `PG.db.profile.sounds` and
  `not InCombatLockdown()` and no Safety flag set; then
  `pcall(PlaySound, id, "SFX", false)`, result ignored (never branch on willPlay).

---

## 6. Readability and restraint rules (hard rules for implementers)

1. **Contrast minimums:** body text >= 4.5:1 against its actual backdrop; the shipped
   pairs are pre-cleared: INK on PARCH ~6.5:1, CHALK on BOARD ~14:1, LOSS on PARCH
   ~4.9:1, WIN on PARCH ~6:1, AMBER on PARCH ~4.6:1. Never place GOLD/CHGOLD text on
   parchment or INK on the chalkboard. Any text over variable art (ribbons, world) gets
   the 1.2 shadow.
2. **Never animates, ever:** the timer bar and its number; any FontString currently
   displaying money the player is deciding with (`ui.info`, `ui.mine`, roster rows,
   ledger rows, strip tallies, Ask timeout); EditBoxes; the DND button. Banners/toasts
   may CONTAIN money because they are announcements, and their text is static for the
   life of the slide (text set before Restart, never changed mid-flight).
3. **The PB strip is calm:** no entrance/exit animation, no sound, no loops; its entire
   motion budget is the 0.12 s lock pop on the button the player just clicked.
4. **Loop policy:** no looping decoration while any decision UI is active (round open,
   join open, strip visible). Loops exist only in reveal/end states, are BOUNCE/REPEAT
   with a gen-checked stop timer <= 4 s, and are killed by OnHide Stop.
5. **Concurrency caps:** per window at most ONE banner, ONE stamp, ONE coin shower, ONE
   glow+starburst pair, ONE goblin emote at a time (new replaces old via Stop+Restart).
   Ceiling: <= 16 simultaneously playing AnimationGroups per window (12 coins + glow +
   starburst + banner + stamps batch counts as reveal budget); outside reveals the cap
   is 2 (pop + pulse).
6. **Flash discipline:** ADD-blend layers ramp <= 0.35 s, peak alpha <= 0.9, size <=
   140 px, always anchored to a UI element (chest/row), never screen-centered flashes.
7. **FX never precede information:** RefreshUI sets final text BEFORE any choreography
   plays; a player who hates motion can read every state with FX entirely failed.
8. **Text is the fallback of everything:** each themed layer's failure mode is listed in
   its section and always degrades to today's plain-text UI, never to a blank region.

---

## 7. Integration notes

- New file `PengyouGames/Theme.lua`; TOC order becomes: Core, Util, **Theme**, Comm,
  Ledger, Widgets, Games\LootGoblins, Games\PullBook, Launcher. (File-scope purity means
  order is a dependency-clarity choice, not a correctness one.)
- Module diffs, summarized: Widgets (Ask theme arg, TimerBar skin hook, toast shadow),
  Launcher (Skin + label markup), Ledger (Skin, parchment sheet, palette swap, tab/page
  sound), LootGoblins (window regeometry per 2.4, Skin, NPC, reveal calls in
  applyBegin/applyRound/applyResult/applyVoid/applyEnd, palette swap), PullBook (dialog
  per 2.6, strip per 2.7, toast prefixes). No wire, timing, Safety, or ledger logic
  changes anywhere.
- Verify every new Lua file with `/opt/homebrew/bin/luac -p`; ASCII only; no globals.
- The `cappts-darkmoonfaire` atlas ("plausible") is NOT in this spec — the faire look is
  built entirely from verified pieces (tickets, tarot, warboard, chalkboard, ribbon).
  The Midnight card set and flipbook atlases are likewise deferred past v1.
