# PengyouGames — Technical Specification v1

Raid-downtime minigame suite for WoW patch 12.1 (Midnight). Two games shipping in v1 —
**Loot Goblins** (buy-in social deduction) and **The Pull Book** (pre-pull betting) — running
concurrently over invisible addon messages, with a shared virtual-gold ledger and a
"settle up" screen that tells players who pays whom afterward. Real gold never moves
through the addon.

This document is the single source of truth for implementers. Where it conflicts with
intuition, the spec wins. The verified 12.1 API constraints live in
`~/.claude/projects/-Users-londonbalcita-Documents-London-Personal-Dev-Projects-pengyousblackjack/memory/wow-121-addon-api-constraints.md`
and are summarized in §2.

---

## 1. Product requirements (from the user)

- Both games installable/runnable **concurrently** (independent sessions, shared ledger).
- **Loot Goblins has a buy-in phase**: the starter sets a buy-in amount; everyone in the
  group running the addon gets a notification popup asking to buy in or pass.
- **All money is virtual.** The addon tracks nets and, at settle-up, directs players to
  pay each other manually (trade/mail). No automation of gold, ever.
- Zero public chat output. Non-participants see nothing. DND toggle suppresses popups.
- Raid-safety: all UI vanishes instantly on combat/encounter/ready-check/countdown.

## 2. Hard 12.1 platform rules (verified 2026-08-11; violating any of these is a bug)

1. **Comms lockdown, not combat**: `C_ChatInfo.SendAddonMessage` is refused during
   (a) an in-progress instance encounter (ENCOUNTER_START→ENCOUNTER_END), (b) an entire
   active M+ keystone run, (c) an entire active PvP match. Trash combat in raids does NOT
   block sends. Gate sends on `C_ChatInfo.InChatMessagingLockdown()` ONLY (existence-guard;
   absent = unrestricted). Do NOT gate on `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()`:
   despite the name it governs addons sending PUBLIC chat (SendChatMessage) and returns
   true on all normal realms, always — gating on it blocks every send everywhere (the
   v0.1.1 bug). Refusal code `Enum.SendAddonMessageResult.AddOnMessageLockdown`
   (fallback literal 11) is PERMANENT for that message — drop it, never retry.
   `AddonMessageThrottle` (fallback 3) is transient — retry with backoff.
2. **Never register `COMBAT_LOG_EVENT_UNFILTERED`** — it is a Lua error on 12.x.
3. Boss HP comes ONLY from `ENCOUNTER_END`'s 6th arg `encounterUnitStatus`
   (array of `{creatureID, creatureName, remainingHealthPercent}`, non-secret).
   `UnitHealth` returns secrets — never call it for game logic.
4. Player deaths come ONLY from the standalone `UNIT_DIED` event (payload: unitGUID).
   Raid/party member GUIDs are documented readable mid-encounter; boss GUIDs arrive as
   SECRET values. Guard EVERY use: `local isSecret = issecretvalue or function() return false end`;
   never compare/index/arithmetic a possibly-secret value without checking, and wrap the
   handler body in `pcall` as a second line of defense.
5. **Secrets silently become `nil` in SavedVariables** — validate before persisting.
6. Every wire message must be **single-part: ≤ 200 bytes at 25 players** (255 hard limit;
   we keep margin). No multipart transfers, so nothing can straddle a lockdown boundary.
7. Per-prefix server throttle: 10-message burst, regenerating 1/sec. Implement a matching
   token bucket client-side.
8. Pull timers: `START_PLAYER_COUNTDOWN` fires for every DBM/BigWigs/native `/pull`.
   Do not hook boss mods in v1.
9. `READY_CHECK` / countdown payloads are secret ONLY during lockdown — never true in the
   raid pre-pull window where we use them; still guard per rule 4.
10. `ADDON_RESTRICTION_STATE_CHANGED(restrictionType, state)` fires BEFORE a restriction
    activates — use it (plus ENCOUNTER_START) to freeze bets/hide UI. Existence-guard the
    event registration (wrap RegisterEvent in pcall — unknown events hard-error).
11. No deprecated APIs: no `getglobal`/`setglobal`, no `UIParentLoadAddOn`, no `BNSendGameData`.
12. Never attempt any in-encounter signaling fallback of any kind (policy line).
13. TOC: `## Interface: 120007, 120100`. First line of the .toc must be a `##` directive,
    never a bare `#` comment (12.0.7 bug skips all directives otherwise).

## 3. Environment & conventions

- WoW Lua is 5.1-flavored: `unpack` not `table.unpack`, no `goto`, no integer-division
  operator, `bit` library if needed (avoid). WoW provides `strsplit`, `format`, `wipe`,
  `tinsert`, `tremove`, `date`, `C_Timer`, `GetTimePreciseSec`. Syntax-check every file
  with `/opt/homebrew/bin/luac -p <file>` (it's Lua 5.4 — use only 5.1-compatible syntax
  so both accept it).
- Every file begins `local ADDON, PG = ...` — WoW passes the addon name and a private
  shared table to each file. `PG` is the namespace. Also set `_G.PengyouGames = PG` in
  Core.lua for debugging. Never create other globals.
- **File-scope purity**: at file scope, only define functions/tables on PG and register
  init callbacks via `PG.RegisterInit(fn)`. No cross-module calls, no CreateFrame, no
  event registration at file scope. Core runs all init callbacks at `ADDON_LOADED`.
- All money values are **integer gold**. Display via `PG.Money(g)` → `"1,250g"`.
- Full player names: always `"Name-Realm"` via `PG.FullName(unit)`
  (`UnitFullName`; empty realm → `GetNormalizedRealmName()`). Normalize CHAT_MSG_ADDON
  sender the same way (append own realm if missing). Names never contain `|`, `,`, or `;`.
- Deterministic ordering everywhere: when the spec says "sorted roster", it means the
  participant list sorted by full name with plain `table.sort(t)` (byte order). All
  clients must derive identical orderings from identical data.
- Sounds: OFF by default (`db.profile.sounds = false`); if enabled, play only when
  `not InCombatLockdown()` and no countdown is active.
- ASCII only in source files; user-visible strings in a `PG.L` table (flat English, no
  localization machinery in v1).

## 4. Files & load order

```
pengyousblackjack/               (repo root)
├── README.md                    (install + how to play — written at integration)
├── docs/SPEC.md                 (this file)
└── PengyouGames/                (the addon — folder name must match .toc)
    ├── PengyouGames.toc
    ├── Core.lua                 addon table, DB init, event hub, Safety, peers, slash
    ├── Util.lua                 money/name/csv/secret helpers, roster snapshot
    ├── Comm.lua                 protocol codec, send queue, router
    ├── Ledger.lua               session nets, settlement algorithm, ledger window
    ├── Widgets.lua              window factory, ask-popup, toast, timer bar
    ├── Games
    │   ├── LootGoblins.lua      full game (host + client + UI)
    │   └── PullBook.lua         full game (bookie + client + UI)
    └── Launcher.lua             launcher window wiring it all together
```

TOC (exact):
```
## Interface: 120007, 120100
## Title: Pengyou Games
## Notes: Raid-downtime minigames: Loot Goblins & The Pull Book. Virtual gold; settle up after.
## Author: Pengyou
## Version: 0.1.0
## SavedVariables: PengyouGamesDB

Core.lua
Util.lua
Comm.lua
Ledger.lua
Widgets.lua
Games\LootGoblins.lua
Games\PullBook.lua
Launcher.lua
```

## 5. Core.lua — foundation APIs

```lua
PG.RegisterInit(fn)                 -- fn() called at ADDON_LOADED (in registration order)
PG.RegisterEvent(event, fn)         -- multiplexed event hub; pcall-wraps fn; RegisterEvent
                                    -- call itself pcall-guarded (rule 10)
PG.After(sec, fn)  PG.Ticker(sec, fn) -- C_Timer wrappers
PG.db                               -- PengyouGamesDB, initialized with defaults:
   { profile = { sounds=false, dnd=false, scale=1, positions={} },
     ledger  = { sessions={}, lifetime={} } }
PG.Safety.state                     -- { inCombat, inEncounter, readyCheck, countdown }
PG.Safety.RegisterWindow(frame)     -- frame auto-hidden on encounter/ready/countdown/
                                    -- restriction; on plain combat ONLY if
                                    -- profile.hideInCombat (default false — comms and
                                    -- game progression are legal in plain combat, so
                                    -- since 0.4.0 the games simply keep running).
                                    -- Safety re-shows exactly what it hid once all
                                    -- clear; frames veto via frame.__pgResume() -> bool
PG.Safety.OnChange(fn)              -- fn(state, trigger) on any transition; triggers:
                                    -- "COMBAT_ON/OFF", "ENCOUNTER_ON/OFF", "READY_ON/OFF",
                                    -- "COUNTDOWN_ON/OFF", "RESTRICT_ON/OFF"
PG.Peers                            -- { [fullName]=versionString } from CO|HELLO
PG.IsDND()                          -- profile.dnd
```

Safety event wiring: PLAYER_REGEN_DISABLED/ENABLED, ENCOUNTER_START/END,
READY_CHECK/READY_CHECK_FINISHED, START_PLAYER_COUNTDOWN/CANCEL_PLAYER_COUNTDOWN,
ADDON_RESTRICTION_STATE_CHANGED (pcall-registered), GROUP_ROSTER_UPDATE.
Countdown state also self-clears via PG.After(totalTime+1) as a fallback.

Slash: `/pengyou` and `/pg` → toggle Launcher. Subcommands: `lg` (start-Goblins dialog),
`book` (Pull Book dialog), `ledger`, `dnd` (toggle + print state to self via
DEFAULT_CHAT_FRAME:AddMessage — local print only, never SendChatMessage).

Peers: on init and (rate-limited 60s) on GROUP_ROSTER_UPDATE, broadcast `CO|HELLO|-|<ver>`;
on receiving HELLO from a peer not seen in 60s, reply once. Store in PG.Peers.

## 6. Comm.lua — protocol

- Prefix `"PENGYOU"`, registered at init via `C_ChatInfo.RegisterAddonMessagePrefix`.
- Envelope: `"2|" .. module .. "|" .. mtype .. "|" .. token .. suffix` (wire v2 since
  0.3.0: adds the RPS module; 0.1.x clients are politely excluded) where suffix is
  `"|" .. table.concat(fields, "|")` if fields present. Parse with
  `strsplit("|", msg)`. Version ≠ "1" → ignore silently (log once).
- `PG.Comm.Register(module, handler)` — handler(mtype, token, sender, f1, f2, ...).
  Modules: `"CO"`, `"LG"`, `"PB"`.
- `PG.Comm.Broadcast(module, mtype, token, ...)` — channel: IsInRaid()→"RAID",
  IsInGroup(LE_PARTY_CATEGORY_INSTANCE)→"INSTANCE_CHAT", IsInGroup()→"PARTY", else drop.
- `PG.Comm.Whisper(target, module, mtype, token, ...)`.
- Send queue: token bucket (capacity 10, +1/sec). Before any send: if
  `PG.Comm.Locked()` (lockdown predicates from §2.1) → drop and call module's
  optional `onDrop(mtype)` callback. On result==throttle code → requeue front, retry
  after 1.2s. On result==lockdown code → drop. Assert at send time
  `#msg <= 250` (error to BugSack in debug, drop in release).
- Loopback: WoW does not deliver PARTY/RAID broadcasts back to the sender reliably for
  addon messages — it DOES deliver them; nevertheless every host/bookie module must
  process its own outgoing state changes locally at send time and IGNORE its own
  broadcasts on receipt (`sender == PG.FullName("player")` → return), so behavior does
  not depend on self-delivery.
- Debug: `/pg debug` toggles `PG.debug`; when on, sent/received lines go to chat frame
  locally.

## 7. Ledger.lua

- `PG.Ledger.Add(fullName, deltaGold, reason)` — applies to
  `db.ledger.sessions[date("%Y-%m-%d")][fullName]` (net, integer) and
  `db.ledger.lifetime[fullName]`. Callers pass only plain numbers/strings
  (validate: type checks + reject secrets per §2.5).
- `PG.Ledger.Tonight()` → `{ {name, net}, ... }` sorted net desc.
- `PG.Ledger.Settlement()` → list of `{from, to, amount}`: greedy — repeatedly match the
  largest debtor with the largest creditor (ties → alphabetical), transfer
  `min(|debt|, credit)`, until all zero. Deterministic.
- Ledger window (via Widgets): two tabs — "Tonight" (nets, green/red) and "Settle Up"
  (the from→to list, own lines highlighted: "YOU pay Bob-Realm 250g"), plus a
  "Clear tonight" button with confirm popup (local effect only).

## 8. Widgets.lua

- `PG.UI.Window(key, title, w, h)` → movable, clamped, `BackdropTemplate`, close button,
  ESC does NOT close (don't touch UISpecialFrames — keep out of Blizzard tables),
  position persisted in `db.profile.positions[key]`, `PG.Safety.RegisterWindow` applied,
  `SetScale(db.profile.scale)`. Strata MEDIUM. Since 0.2.0: bottom-right resize grip
  scales the whole window (0.6–1.6, per-window scale persisted next to its position),
  and factory windows never overlap — `PG.UI.ResolveOverlaps` nudges the window being
  shown/dragged/resized to the nearest clear spot (bounded best-effort, 12 passes).
- `PG.UI.Ask(key, text, acceptLabel, declineLabel, timeoutSec, onAccept, onDecline)` —
  small centered popup; timeout counts down on a fontstring; timeout==decline. Never
  shown if `PG.IsDND()` (auto-decline). Only one Ask per key at a time (new replaces old).
- `PG.UI.Toast(text)` — 3s fade line near top of screen; suppressed in DND; never in combat.
- `PG.UI.TimerBar(parent, w)` → bar with `:Start(sec)`/`:Stop()`, OnUpdate-driven.
- `PG.UI.Button(parent, label, w, h, onClick)` — UIPanelButtonTemplate.

## 9. Games/LootGoblins.lua

Session token: `shortHostName .. "-" .. random(10000,99999)` (generated at OPEN; fine at
runtime). One active LG session per group at a time: receiving OPEN while a session is
live → ignore + toast host locally ("A game is already running").

Roles: exactly one **host** (the starter). Host also plays. Clients mirror state from
broadcasts. Host processes everything locally at send time (§6 loopback rule).

### Flow & messages (all ≤200 bytes; sizes assume 25×"Name-Realm" ≈ 20 chars)

| Msg | Dir | Fields after token | Meaning |
|---|---|---|---|
| `LG\|OPEN` | B host | `buyin, rounds, joinSecs` | Buy-in phase open |
| `LG\|JOINED` | B host | `fullName` | Confirmed buy-in (one msg per joiner, incl. host) |
| `LG\|JOIN` | W→host | — | "I buy in" |
| `LG\|UNJOIN` | W→host | — | Withdraw during buy-in phase |
| `LG\|LEFT` | B host | `fullName` | Withdrawal confirmed |
| `LG\|BEGIN` | B host | `count, pot, rounds` | Buy-in closed; play begins |
| `LG\|CANCEL` | B host | `reasonCode` | Session aborted, everything refunded (no ledger) |
| `LG\|ROUND` | B host | `r, roundPot, secs` | Round r decision window open |
| `LG\|PICK` | W→host | `r, p` (`p`∈`S`,`H`) | First click locks |
| `LG\|RESULT` | B host | `r, pattern, hoardPay, sharePay, carry` | Round resolved |
| `LG\|VOID` | B host | `r` | Round voided (encounter interrupted it) |
| `LG\|END` | B host | `dustIdx, dustAmt` | Session complete → apply ledger |
| `LG\|HB` | B host | `phase, r` | Heartbeat every 10s (never during lockdown) |

`pattern`: one char per participant in **sorted-roster order**: `S`/`H`/`X` (X = no pick).
Client roster = the JOINED/LEFT stream. On BEGIN, if local roster count ≠ `count`, the
client is desynced: it locks itself to **spectator** (sees results, cannot pick, its own
ledger untouched — and shows "out of sync, sit this one out" toast).

### Host logic

- OPEN dialog fields: buy-in gold (default 100, min 1, max 100000), rounds (default 5,
  1–20), join window (default 45s), round timer (default 20s, 10–60). Host auto-joins.
- Buy-in phase: on JOIN whisper → add, broadcast JOINED. On UNJOIN → remove, broadcast
  LEFT. Duplicate JOINs idempotent. Window ends early if host clicks "Start now".
  Fewer than 2 players at window end → CANCEL (reason `few`).
- Rounds: `basePot = buyin * count`. `roundPot(r) = floor(basePot / rounds) + carryIn`.
  Resolution at deadline with picks `k` (players who clicked), hoarders `h`, sharers `s`:
  - `k == 0` → whole roundPot becomes carry; RESULT with all-X pattern, pays 0.
  - `h == 0` → each sharer gets `floor(roundPot / k)`; dust → carry.
  - `1 <= h <= max(1, floor(k * 0.2))` → hoarder pool `floor(roundPot * 0.8)`:
    each hoarder `floor(pool / h)`; remainder pool `roundPot - h*hoarderPay`:
    each sharer `floor(remainder / s)` (if `s == 0`: hoarders split the whole roundPot
    instead: each `floor(roundPot / h)`); dust → carry.
  - `h > max(1, floor(k * 0.2))` → hoarders get 0; each sharer `floor(roundPot / s)`;
    if `s == 0` → whole roundPot → carry.
  - Non-pickers (X) get 0 for the round, stay in the session.
- After final RESULT: remaining carry (dust) goes to the participant with the LOWEST
  total winnings (tie → first in sorted roster): `END|dustIdx|dustAmt` (dustIdx into
  sorted roster; `-1` if zero dust).
- **Ledger applies only at END**, on every client identically: for each participant,
  `net = totalWon - buyin` → `PG.Ledger.Add(name, net, "Loot Goblins")`. Host disconnect
  or CANCEL mid-game → no ledger effect at all (all-or-nothing).
- Encounter interruption: client side — at ENCOUNTER_ON, hide UI, discard pending pick
  state. Host side — mark round broken; after RESTRICT_OFF/ENCOUNTER_OFF, broadcast
  `VOID|r` (roundPot → carry) then continue with next ROUND (or END if r was last).
  Ready check / countdown / trash combat merely hide UI (Safety layer) — the host
  freezes the round timer (record remaining) and re-opens the same round afterward by
  re-broadcasting `ROUND|r|roundPot|remainingSecs` (clients treat repeat ROUND for
  a known r as timer refresh; locked picks stay locked).
- Heartbeat: HB every 10s outside lockdown. Clients: no HB for 35s (timer suspended
  while `Safety.state.inEncounter`) → session dead → toast + close (no ledger).

### Client UI

- Invite via `PG.UI.Ask` ("«Host» started Loot Goblins — buy-in 100g, 5 rounds. Buy in?"),
  timeout = joinSecs. Accept → JOIN whisper; window shows roster filling in live.
- Game window: pot, round x/y, timer bar, two big buttons SHARE / HOARD (lock on click),
  live status line ("7/12 picked"), result reveal (hoarders in red + payouts), running
  session winnings. After END: summary + "Open Ledger" button.

## 10. Games/PullBook.lua

One book per group. **Bookie** = whoever opens it. Config broadcast in OPEN; bets are
per-attempt, opt-in by clicking; all bets broadcast so every client can resolve locally.

| Msg | Dir | Fields after token | Meaning |
|---|---|---|---|
| `PB\|OPEN` | B bookie | `stake, line` | Book open (stake gold/bet; line = wipe-% O/U) |
| `PB\|CLOSE` | B bookie | — | Book closed |
| `PB\|BET` | B any | `m, p` | m∈`K`,`D`,`W`; p∈`Y/N`, `T/H/D`, `O/U` |
| `PB\|FD` | B bookie | `role, name` | First-death adjudication (`role`∈T/H/D or `NONE`) |

(A phase-of-wipe market variant was built in 0.2.0 and REMOVED in 0.3.0: it required
DBM/BigWigs stage callbacks, and the addon must not rely on other addons. Do not
reintroduce boss-mod dependencies.)
| `PB\|HB` | B bookie | — | Every 15s out of lockdown; 50s miss → book auto-closes |

- OPEN dialog: stake (default 100g), wipe line % (default 50, 1–99).
- **Bet window**: the strip appears on READY_CHECK or START_PLAYER_COUNTDOWN (when book
  open, not in lockdown, not DND): three rows — "Kill? YES/NO", "First death:
  TANK/HEALER/DPS", "Boss HP at end: OVER line / UNDER line". First click per market
  locks. Each click broadcasts `BET`. All clients (incl. non-bettors with the addon)
  record all bets for the pending attempt.
- Freeze: at ENCOUNTER_ON or RESTRICT_ON, pending bets freeze into the active attempt,
  strip hides. Bets received after freeze are ignored (server lockdown refuses most
  anyway). CANCEL_PLAYER_COUNTDOWN without an encounter → attempt stays pending; a
  fresh READY_CHECK/countdown reshows the strip (locked picks stay).
- **Resolution** on ENCOUNTER_END(id, name, diff, size, success, encounterUnitStatus),
  wrapped in pcall, args secrecy-checked:
  - `bossPct`: success==1 → 0; else min over `encounterUnitStatus[i].remainingHealthPercent`
    (numbers only; secret/missing/empty → W market VOID).
  - K: winners picked `Y` iff success==1 else `N`. W: winners `O` iff bossPct > line else `U`.
  - D: bookie's own UNIT_DIED observations during the encounter: first GUID that is
    non-secret AND in the roster snapshot (taken at last READY_CHECK/countdown out of
    combat: `{[guid]={name, role}}`, role from `UnitGroupRolesAssigned` mapped
    T/H/D). Bookie broadcasts `FD|role|name` within 10s of RESTRICT_OFF; clients
    resolve D on receipt. No FD within 20s of encounter end → D VOID (refund).
    `FD|NONE|-` (nobody died / all secret) → D VOID.
  - Per market independently: bettors < 2, or all on one side, or zero winners →
    VOID (no ledger effect). Else: each loser `-stake`; pot `= stake * losers` split
    `floor(pot / winners)` each; dust (`pot - winners*share`) → first winner in sorted
    order. `PG.Ledger.Add` per player, reason `"Pull Book: " .. encounterName`
    (encounterName only if a plain string; else "encounter").
  - Every client applies identical ledger deltas from its own recorded bet set. (Known
    v1 limitation, documented in README: a client that missed a BET broadcast may
    disagree; the ledger is social, not authoritative.)
- Trash combat without countdown/ready-check: nothing shows, nothing resolves.
- Toast results after RESTRICT_OFF ("Pull Book: kill! 3 winners split 500g — you +166g").

## 9b. Resync (added 0.4.0, LG and RPS identically)

Genuine message gaps (boss encounters kill comms both ways; loading screens) self-heal:
`SYNCQ` (W→host: `phase, rApplied, rosterN`, rate-limited 10s) → host compares against
its retained replay history (JOINED/LEFT stream, BEGIN, per-round RESULT fields, current
ROUND) and either whispers `SYNCOK` (current), replays the exact missed ORIGINAL
messages as whispers (handlers are idempotent: set-like roster adds, applied-round
tracking, repeat-ROUND = refresh), or whispers `SYNCNO` (>20 messages behind → spectate).
A spectator whose resync reconciles roster and rounds re-enters play from the next
round. Clients SYNCQ on emerging from a safety interruption with a live session and on
receiving an out-of-sequence ROUND/RESULT. Sync messages are not in CRITICAL_DROP.

## 10b. Games/RockPaperScissors.lua (added 0.3.0)

Zero-gold, points-based; mirrors LG's host/client structure, wire discipline, and
safety flow exactly (module `RPS`; OPEN/JOIN/JOINED/UNJOIN/LEFT/BEGIN/CANCEL/ROUND/
PICK/RESULT/END/HB/VOID with the sorted-roster pattern trick, chars `R/P/S/X`).
Scoring per round: one point per player you beat (rock scores #scissors, paper scores
#rock, scissors scores #paper; all-same = all zero; X scores 0). Standings: cumulative
points, dense ranking, podium at END; gold-medal tally persists in `db.rps.medals`.
Never touches PG.Ledger. Best-of rounds host-configurable (default 3). Theme "faire".

## 10c. Settings.lua (added 0.3.0)

`PG.Settings.Show()`: neutral-themed window — checkboxes for sounds / DND / minimap
button, a global window-scale slider (0.6–1.6; applying clears per-window grip scales
via `PG.UI.ApplyGlobalScale`), and a "Reset window layout" button
(`PG.UI.ResetLayout`). Launcher button + `/pg settings`.

## 11. Launcher.lua

Small window (via Widgets): title "Pengyou Games", buttons: "Loot Goblins…",
"Pull Book…", "Ledger", "DND: on/off". Buttons open the respective dialogs (host/bookie
config dialogs live in their game files; Launcher just calls `PG.LG.OpenDialog()` /
`PG.PB.OpenDialog()` / `PG.Ledger.Show()`). Also `/pg` routes here (§5).

## 12. Explicitly out of scope for v1

Blackjack (v2), spectator mode, late buy-in, guild-wide channel, minimap/LDB button,
options panel, localization, sound packs, cross-session stats UI, host migration
(sessions void instead), bet-set reconciliation broadcasts.
