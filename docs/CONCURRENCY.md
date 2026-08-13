# CONCURRENCY.md - Session concurrency and isolation

**Status:** binding design spec. One design, no options.
**Applies to:** `Games/LootGoblins.lua` (`LG`), `Games/RockPaperScissors.lua` (`RPS`),
`Games/PullBook.lua` (`PB`), `Core.lua`, `Comm.lua`, `Widgets.lua`, `Theme.lua` (reveal stage),
`Launcher.lua`.
**Ships with:** 0.6.0, alongside `SCOPE.md`. The two documents are one release.

Answers to the seven required questions live in: §1 (the rule), §4 (simultaneous start), §3
(token identity), §5 (isolation), §6 (busy behaviour), §7 (teardown), §8/§9 (build order and
out-of-scope). §2 defines the state model everything else refers to.

---

## 0. The model, and what it supersedes

### 0.1 The owner's model, stated once

1. A person **plays** at most one round-based game at a time. That is the only exclusivity.
2. **Unlimited concurrent sessions may exist around you**, including two or more of the same
   game type in the same audience. Five people play Loot Goblins while others play Rock Paper
   Scissors in the same raid; a second Loot Goblins game starts while the first is mid-round.
   Neither may block the other.
3. **Multiple invitations are visible at once.** Until you accept one you see them all and
   choose. Accepting one withdraws the rest.
4. **Hosting is never blocked** by being a participant in someone else's game, nor by other
   sessions existing.
5. **A client fully tracks only the session it is in.** Every other live session it merely
   overhears is kept as a lightweight record: enough to show the invitation, drop its traffic
   cheaply, and resolve identity. Overhearing a session is not participating in it.

### 0.2 What this removes from the shipped code

These are the refusals that must go. Each is a direct violation of rule 2 or 4:

| Location | Code | Fate |
|---|---|---|
| `LootGoblins.lua:700-703` | `hostOpen`: `if live() then toast("a game is already running")` | **Deleted.** Replaced by the per-module involvement check (§1, I3). |
| `LootGoblins.lua:888-892` | `onComm` OPEN: `if live() then toast("<sender> tried to start a game...")` | **Deleted.** An inbound OPEN is never refused because a session exists. |
| `RockPaperScissors.lua:653-656` | same as LG `hostOpen` | **Deleted.** |
| `RockPaperScissors.lua:828-832` | same as LG OPEN toast | **Deleted.** |
| `LootGoblins.lua:1903-1908` | `OpenDialog`: refuses to open while `live()`, shows the window instead | **Deleted.** The dialog always opens; Start explains itself (§6.4). |
| `RockPaperScissors.lua:1664-1669` | same as LG `OpenDialog` | **Deleted.** |
| `LootGoblins.lua:803`, `RockPaperScissors.lua:752` | `PG.UI.Ask("lg-invite" / "rps-invite", ...)` | **Re-keyed per session** (§5.6). A second invite to the same game silently auto-declining the first is a bug under rule 3. |

### 0.3 Relationship to SCOPE.md

`SCOPE.md` is authoritative for transport, scope derivation, trust, and the ledger gates.
**This document is authoritative for how many sessions exist and how they stay apart.** Where
they disagree, the deltas below apply. Do not edit `SCOPE.md`; apply these when merging.

| SCOPE.md | Delta |
|---|---|
| §6.4 "One live session per module per client remains the rule - `live()` is unchanged" | **Superseded.** Unlimited sessions may be known; exactly one per module may be *joined or hosted* (§1, I3). `live()` is deleted as a gate and survives only as a UI predicate. |
| §6.4 collision table (group OPEN toast / guild silent / public listed) | **Superseded by §4.4 here.** No OPEN is ever "dropped because a session is live". The toast policy per scope is preserved in §6.2. |
| §8 item 6, "More than one live session per module per client" as out of scope | **Superseded.** Out-of-scope becomes "more than one *involved* session per module" (§9). |
| §4.3 trust predicate, written against the single `S` | Mechanically retargeted at the registry (§5.4). Same logic. |
| §4.5 provenance id `"LG:Grizzle-48120"` (module + token) | Becomes `game .. ":" .. host .. ":" .. token` (§3.4). Tokens are unique per host, not globally. |
| §6.3 "wide-scope mirrors released at BEGIN if the local player did not join" | **Generalised to every scope** (§7.3), per owner rule 5. Group-scope bystanders stop mirroring too. |

### 0.4 The one thing that makes concurrency safe

The audit's worst finding was that two concurrent sessions produce **divergent advisory ledgers**
on clients that overheard both. That is not fixed by arbitration. It is fixed by the
**participation gate** (`SCOPE.md` §4.4 G1): a client writes ledger rows only for a session it
actually joined and played. With G1 in place, two sessions running side by side write two
disjoint, internally-consistent sets of rows, which is exactly correct.

> **G1 is a hard prerequisite of this document.** Concurrency must not ship before it. If the
> build order forces a choice, ship G1 first and concurrency second.

---

## 1. The rule, as checkable invariants

### 1.1 Definitions

**Round-based module.** `LG` and `RPS`. These demand a timed decision from the human inside a
15-60 second window. `PB` is not round-based: it is passive pre-pull betting, designed from day
one to run alongside a round-based game, and it is exempt from every seat rule below.

> **1.1.0 delta (2026-08-12).** The definition is unchanged; the membership grew. Round-based
> modules are now **`LG`, `RPS`, `DR`, `GB` and `QZ`** - five, not two. Each of the three new
> games meets the test as written: Death Roll demands a typed `/roll` inside a turn timer *and*
> blocks every other player at the table until it arrives, The Gambler demands a roll inside a
> single timed window, and Quiz demands a typed answer in 10-60 seconds. Quiz claims the seat
> despite being points-only, because the seat is a rule about human ATTENTION and not about
> gold - `RPS`, also points-only, is the precedent.
>
> **`PB` remains the ONLY exemption, permanently.** Wherever this document says "LG and RPS",
> read "every round-based module"; wherever it says "the Pull Book is the exception", it is
> still exactly and only the Pull Book.
>
> Since 1.1.0 the membership is also **declared in the code** rather than only here: every game
> file sets `PG.<code>.SEAT` next to its `SCOPES` table (`true` for the five, `false` for `PB`),
> and `Launcher.lua`'s Join gate reads that flag instead of naming module codes in its own
> source. A future game that forgets to declare it degrades to "Join enabled" and its own
> `PG.Session.Claim` produces the real refusal - which is the safe direction, unlike a hardcoded
> exemption list that forgets `PB` and greys out a Book the player is entitled to join.

**Seated.** The local player occupies a seat in a session when *either*:
- they accepted its invitation (the click at `LootGoblins.lua:807` / `RockPaperScissors.lua:755`), **or**
- they are its host and took the seat at `hostOpen` (§1.3).

**Involved.** Seated in a session, **or** hosting it (including hosting without a seat, §1.3).
A module's *involved* session is the only one it fully tracks.

**Active.** A session is active from the moment its record is created until `phase == "done"`.
`done` is set in exactly one place per module - `endSession()` (`LootGoblins.lua:141-148`,
`RockPaperScissors.lua` equivalent) - and every abort path funnels through it.

**Reveal is not active.** The reveal stage (`Theme.Reveal` / `Theme.RevealQueue`) is decoration
that plays after the fact. A queued podium can wait out an encounter for minutes
(`Theme.lua:2010-2015`). It never holds a seat and never delays the next game.

### 1.2 The invariants

Each is stated so a reviewer can verify it by reading one place.

> **I1 - One seat, globally.** Across every round-based module combined - `LG` and `RPS` at
> 1.0.0, plus `DR`, `GB` and `QZ` since 1.1.0 - at most one seat is held at any
> instant. `PG.Session.Seat()` (§2.3) is single-valued or nil.
> *Check:* the only writers are `PG.Session.Claim` / `PG.Session.Release` in `Core.lua`. Grep
> that no module writes the holder directly.

> **I2 - The seat spans join through done, and nothing else.** Claimed at accept (or at
> `hostOpen` when the host seats itself), released the instant `endSession()` sets
> `phase = "done"`, on every path including abort. Not extended by the reveal stage, the podium,
> the results window, or the record's memory lifetime.
> *Check:* `PG.Session.Release` is called from `endSession` and from nowhere else, plus the
> `applyLeft(me)` withdrawal path (§7.2).

> **I3 - One involved session per module.** Each of `LG`, `RPS`, `PB` has at most one full
> record. Everything else it knows about is a lite record (§2.2).
> *Check:* `sessions[mine]` is the only full record; `hostOpen` refuses only when `mine` is set;
> `clientAccept` refuses only when `mine` is set.

> **I4 - Hosting is never blocked by another module or another person's session.** `hostOpen`
> refuses for exactly three reasons: this module is already involved in a session (I3), the
> transport is unavailable (`PG.Comm.ScopeAvailable`, `SCOPE.md` §1.3), or the OPEN broadcast was
> refused. It never consults the other module, the seat, or the number of sessions in the
> registry.
> *Check:* grep `hostOpen` for `PG.Session`, `PG.LG`, `PG.RPS` cross-references. There must be
> exactly one, the referee test of I5, and it must not be able to return early.

> **I5 - Referee hosting.** If the seat is held by another module when `hostOpen` runs, the host
> starts the game **without taking a seat**: it does not appear in its own roster, has no buy-in,
> makes no pick, and writes no ledger row for itself. It runs the game, sees the window, keeps
> Cancel, and sees the podium.
> *Check:* `hostOpen` gates the self-`JOINED` broadcast (`LootGoblins.lua:740-743`) on the seat
> claim succeeding.

> **I6 - No inbound message ever destroys a session you are in.** The only exception is
> same-host supersession (§4.3), which ends the old session with an explicit user-facing line and
> never auto-seats you into the new one.
> *Check:* the OPEN handler's only writes to a full record are through `endSession`.

> **I7 - No session state without consent at wide scope.** A `guild` or `public` OPEN creates a
> lite record only. `group` scope also creates a lite record only. A full record is created
> exclusively by `hostOpen` and by an accepted invitation.
> *Check:* `clientOpen` (the full-record constructor) is called from the Ask accept callback and
> the launcher Join button, and nowhere else.

> **I8 - Every message resolves to exactly one session or is dropped.** Identity is the pair
> `(host, token)` plus the derived scope. No handler may touch state before that pair resolves.
> *Check:* §5.2's gate order, applied verbatim in all three modules.

> **I9 - Bounded memory.** Per module: at most 1 full record, `MAX_LITE = 8` lite records,
> `MAX_RECENT = 16` dead-token entries. No per-session frames, tickers, animation groups, or
> `C_Timer` handles are ever created. One ticker per module, as today.
> *Check:* `CreateFrame` and `PG.Ticker` call sites in the game files stay at their current count.

> **I10 - The Pull Book neither claims nor consults the seat.** It runs alongside anything, and
> it is the only module that does. Every other game file declares `PG.<code>.SEAT = true`;
> `PullBook.lua` declares `PG.PB.SEAT = false`, which is a declaration and not a use of the
> session layer.
> *Check (corrected at 1.1.0):* zero **calls**, not zero mentions -
> `grep -n 'PG\.Session\.' PengyouGames/Games/PullBook.lua` returns nothing. The original
> "grep for `PG.Session`" wording had already been false since the file shipped, because the
> comment that documents this invariant necessarily contains the invariant's own name; a check
> that matches its own documentation is not a check. The escaped-dot pattern above is the one
> form that does not.

### 1.3 Consequences worth stating explicitly

- **You can be in Bob's Loot Goblins game and simultaneously run your own Rock Paper Scissors
  game for other people.** You play LG; you referee RPS.
- **You cannot be in Bob's Loot Goblins game and run your own Loot Goblins game.** That is I3,
  and it is a deliberate scope limit, not a policy: `LG`'s window, `ui` table, row pool, stamp
  pool, and the Grizzle model (`LootGoblins.lua:29-52`) are module singletons. Two involved
  sessions in one module requires instantiating all of it per session - a rewrite of ~800 lines
  of presentation per game for a case with no demand. See §9.
  The refusal is explanatory and actionable, never the old blanket line (§6.4).
- **You can host two games at once** as long as they are in different modules.
- **Everyone else's sessions are irrelevant to what you can do.** The registry is never consulted
  to decide whether an action is allowed.

---

## 2. The multi-session state model

### 2.1 The registry

Each round-based module replaces its single `local S` (`LootGoblins.lua:29`,
`RockPaperScissors.lua` equivalent) with:

```lua
local sessions = {}   -- [key] = record, where key = host .. "|" .. token
local mine            -- key of the ONE full record (hosted or seated), or nil
local recent = {}     -- [key] = GetTime() when it died; replay defence
local recentQ = {}    -- FIFO of recent keys, capped at MAX_RECENT

local function keyOf(host, token) return host .. "|" .. token end
local function mySession() return mine and sessions[mine] or nil end
```

**`S` does not disappear.** Every existing function keeps its first line as
`local S = mySession(); if not S then return end`, or receives the record as a parameter. This is
the single most important implementation constraint in this document: the ~1900-line game files
are not rewritten. Only the OPEN path, the comm prologue, teardown, and the shared-resource call
sites change. A patch that rewrites the appliers has gone wrong.

Constants:

```lua
local MAX_LITE     = 8     -- overheard sessions remembered at once
local MAX_RECENT   = 16    -- dead tokens remembered
local RECENT_TTL   = 120   -- seconds a dead token stays poisoned
local DONE_TTL     = 60    -- seconds a finished full record lingers before eviction
local LITE_TTL_PAD = 10    -- lite record lives joinSecs + this
local ASK_MAX      = 3     -- concurrent invite popups on screen, all modules
```

### 2.2 Record kinds

**Lite record** - created by every OPEN we accept as well-formed. Its entire job is the
invitation and clean identity.

```lua
{ kind    = "lite",
  token   = "3f-9k2",
  host    = "Grizzle-Illidan",
  scope   = "group",            -- derived from the distribution (SCOPE.md 4.1)
  cfg     = { buyin = 100, rounds = 5, joinSecs = 20 },   -- verbatim OPEN fields
  openedAt= GetTime(),
  expires = GetTime() + joinSecs + LITE_TTL_PAD,
  askKey  = "LG:Grizzle-Illidan|3f-9k2",  -- nil if it never got a popup
  listed  = true }               -- present in the launcher Open games list
```

A lite record holds **no roster, no totals, no picks, no history, no ticker, no frame**. It
costs one small table. It never sends anything. It never writes the ledger. It never touches
the window, the reveal stage, or the toast queue except through its own invitation.

**Full record** - exactly today's `S` table (`LootGoblins.lua:718-739` / `775-796`), plus:

```lua
  kind     = "full",
  key      = keyOf(host, token),
  scope    = "group" | "guild" | "public",   -- immutable (SCOPE.md 3.1)
  seated   = true | false,   -- false on a referee host (I5)
  refereed = true | false,   -- convenience mirror of (isHost and not seated)
```

The existing fields (`roster`, `joined`, `totals`, `picks`, `appliedResults`, `hist`, `syncAsk`,
`spectator`, ...) are unchanged in meaning.

### 2.3 The seat holder (Core.lua)

New section in `Core.lua`, next to `PG.Safety`. Module-global, one holder, no table of holders.

```lua
PG.Session = {}

local seat        -- { module = "LG", token = "...", host = "..." } or nil
local seatCbs = {}

-- Take the single round-based seat. Idempotent for the same (module, token).
-- Returns ok, heldModule, heldHost.
function PG.Session.Claim(module, token, host)
  if seat then
    if seat.module == module and seat.token == token then return true end
    return false, seat.module, seat.host
  end
  seat = { module = module, token = token, host = host }
  for i = 1, #seatCbs do pcall(seatCbs[i], seat) end
  return true
end

-- No-op unless (module, token) currently holds the seat. Safe to call always.
function PG.Session.Release(module, token)
  if not seat or seat.module ~= module or seat.token ~= token then return end
  seat = nil
  for i = 1, #seatCbs do pcall(seatCbs[i], nil) end
end

function PG.Session.Seat() return seat end          -- read-only view
function PG.Session.IsSeated() return seat ~= nil end
function PG.Session.OnChange(fn) seatCbs[#seatCbs + 1] = fn end
```

`PG.Session.OnChange` is how a module learns to withdraw its outstanding invitations when the
player seats themselves somewhere else (§5.6). It is the same pattern as `PG.Safety.OnChange`
(`Core.lua:141`).

`PB` never calls any of it (I10).

### 2.4 Lifecycle of a record

```
                 OPEN accepted as well-formed
                            |
                            v
                      [ lite record ]
                            |
        +-------------------+--------------------+
        | accept (Ask or launcher Join)          | decline / timeout / TTL /
        |                                        | BEGIN observed / CANCEL /
        v                                        | END / supersession
  [ full record, seated ]                        v
        |                                    (evicted)
        |  endSession() -> phase = "done", seat released
        v
  [ full record, done ]  -- window keeps final standings, podium may still play
        |
        |  DONE_TTL elapsed AND reveal payload drained AND window closed/replaced
        v
   (evicted; key -> recent[key] for RECENT_TTL)
```

`hostOpen` enters this diagram directly at `[ full record ]` (seated, or referee per I5).

### 2.5 Sweeping

One ticker per module, as today (`LootGoblins.lua:126-139`). Changes:

- It starts when the registry becomes non-empty and stops when it becomes empty.
- Every tick it services `mySession()` exactly as today.
- Every 4th tick (2s) it sweeps: lite records past `expires`, full `done` records past
  `DONE_TTL`, `recent` entries past `RECENT_TTL`. Sweeping a lite record dismisses its Ask
  (§5.6) and removes its launcher row.
- Eviction is the only place records are removed, and it always poisons the key into `recent`.

Worst case iteration per sweep: 1 + 8 + 16 = 25 table entries, once per 2 seconds, per module.

---

## 3. Token identity

### 3.1 The defect

All three modules mint `shortName .. "-" .. math.random(10000, 99999)`
(`LootGoblins.lua:711`, `RockPaperScissors.lua:663`, `PullBook.lua:857`). The name segment is
realm-less, and `math.randomseed` is never called anywhere in the addon. On a realm-wide public
channel two `Thrall`s on connected realms collide at 1/90,000 per concurrent pair, and the
Pull Book folds a colliding book's bettors into its own `attempt.bets` and pays them at its own
stake, straight into SavedVariables (`PullBook.lua:1008-1025`, `409-411`). That is the only
place in the suite where two sessions contaminate each other's *numbers*.

### 3.2 The fix: identity is the pair, so the token only needs to be unique per host

Every inbound message already carries a realm-qualified sender for free
(`PG.NormalizeSender`, `Comm.lua:223`). The registry is keyed by `(host, token)` (§2.1).
Therefore the token does not need to encode identity at all - it needs to be unique **within
one character's history**. That is a much cheaper problem, and it makes the wire smaller rather
than larger.

**Token format:**

```lua
-- Core.lua, next to the DB init
function PG.NextToken()
  local db = PG.db.profile
  db.seq = (tonumber(db.seq) or 0) + 1          -- persisted, monotonic per character
  return b36(db.seq) .. "-" .. b36(math.random(0, 46655))
end
```

- `b36` is a 5-line base-36 encoder in `Util.lua`.
- The counter is incremented **and persisted before the OPEN is broadcast**, so a crash cannot
  reissue a number.
- The random suffix (3 chars, 46,656 values) exists only to survive a SavedVariables rollback or
  a restored backup, where the counter can go backwards. It is a seatbelt, not the mechanism.
- `math.randomseed(time())` is called once in `Core.lua`'s init. This is currently missing
  entirely; the Theme FX are the only other `math.random` consumers and they perturb the stream
  per client, which is precisely why the seed must not be relied on for uniqueness.

Typical token: `"1a-7f3"`, 6 bytes. Worst realistic: 10 bytes. Today's is up to 18.

**Uniqueness argument, in full:**

| Case | Why it cannot collide |
|---|---|
| Two different hosts, any scope, any realm | Keys are `host\|token`; `host` is server-vouched and realm-qualified. The tokens may be identical; the keys never are. |
| Same host, sequential sessions | The counter is monotonic and persisted. |
| Same host, SavedVariables rolled back | The random suffix must also repeat: 1/46,656, and the old key is additionally poisoned in `recent` for 120s (§4.5). |
| A hostile client claiming another host's token | It would have to send from that host's name. The `sender` is not forgeable. |

### 3.3 Byte budget

Guard is `MAX_BYTES = 250` (`Comm.lua:8`); target is 200 at 25 participants. With
`WIRE_VERSION "3"` and the trailing scope byte from `SCOPE.md` §3.2:

| Message | Layout | Bytes |
|---|---|---|
| `LG OPEN` | `3\|LG\|OPEN\|1a-7f3\|100000\|20\|600\|P` | **36** |
| `RPS OPEN` | `3\|RPS\|OPEN\|1a-7f3\|20\|600\|60\|P` | **33** |
| `PB OPEN` | `3\|PB\|OPEN\|1a-7f3\|100000\|50\|P` | **33** |
| `LG RESULT`, 25-player pattern (largest in the protocol at 25) | `3\|LG\|RESULT\|1a-7f3\|20\|SSHHS...(25)\|4000000\|4000000\|4000000` | **75** |
| `LG JOINED`, 33-byte `Name-Realm` | `3\|LG\|JOINED\|1a-7f3\|Xxxxxxxxxxxx-TwistingNether` | **56** |
| `LG RESULT` at the 40-player roster cap | as above with a 40-char pattern | **90** |

Every message is under half the 200-byte target. The token change **saves** 8-12 bytes on every
message in the protocol, which more than pays for the scope byte. No chunking, no new fields, no
message type gains or loses a slot.

### 3.4 Consequences elsewhere

- **Ledger provenance id** (`SCOPE.md` §4.5) becomes `game .. ":" .. host .. ":" .. token`, e.g.
  `"LG:Grizzle-Illidan:1a-7f3"`. The `host` field is already in `meta`; this is a one-line
  change to the id construction and keeps ids unique now that tokens are only host-unique.
- **`PB` attempt ids** (`"PB:" .. book.token .. ":" .. attemptSeq .. ":" .. market`) gain the
  bookie the same way.
- **`greetToken`** (`LootGoblins.lua:45`) compares the full key, not the token.
- **Token validation on the wire** tightens to
  `type(token) == "string" and token ~= "" and #token <= 24 and not token:find("|", 1, true)`.

### 3.5 WIRE_VERSION

**No additional bump. `WIRE_VERSION` goes `"2"` -> `"3"` exactly once, for the 0.6.0 release
that carries `SCOPE.md` and this document together.**

Reasoning, since this is the kind of decision that gets relitigated:

- Nothing here changes a message layout. The token is an opaque string to every version; its
  internal shape is not parsed by anyone.
- The behavioural change (a client that tracks several sessions) is *unilaterally safe*: a v3
  client talking to a v3 client is the only combination that exists, because `SCOPE.md` §3.4
  already forbids v2/v3 mixing for ledger-divergence reasons and `Comm.lua:230` enforces it.
- **If, and only if, this document ships in a release later than the one carrying `SCOPE.md`,
  bump to `"4"`.** A 0.6.0 client enforcing "one live session" would silently refuse the second
  game and show no invitation - degraded but not corrupting (the participation gate keeps its
  ledger clean), yet still a version whose behaviour a host cannot predict. Ship them together
  and the question does not arise.

---

## 4. Simultaneous start, duplicates, and supersession

### 4.1 There is no arbitration between different hosts

Two hosts pressing Start within the same second produce **two games**. That is the intended
outcome, not a collision. The audit's proposed deterministic merge (compare `(token, hostFullName)`
byte-wise, loser broadcasts `CANCEL "merged"`) is **rejected and must not be built.** It directly
contradicts owner rule 2, it destroys a session someone may already have joined, and it exists to
solve a problem that the participation gate (§0.4) already solved.

The convergence property the audit wanted - *every client that heard both OPENs reaches the same
conclusion* - is satisfied, but by construction rather than by election:

- Every client that hears both OPENs creates **two lite records** and shows **two invitations**
  (owner rule 3). No client silently picks a winner, so no two clients can pick differently.
- Each client's *choice* is the human's, and it is authoritative for that client alone.
- Each host's roster is exactly whoever whispered `JOIN` to it. Partial rosters are not a split;
  they are two games with different attendance.
- Ledger rows are written only by participants, for their own session (G1). Two disjoint,
  internally consistent row sets. Nothing diverges, because nothing is shared.

The one thing that must be deterministic is **identity**, and §3 makes `(host, token)` collision-
free without any negotiation round-trip.

### 4.2 Decision table for an inbound OPEN

Evaluated in order. `key = keyOf(sender, token)`.

| # | Condition | Action |
|---|---|---|
| 1 | `sender == myName()` | Drop. `Comm.lua:227` already prevents self-delivery; this is belt and braces. |
| 2 | Malformed fields, bad token, `scope` declared != derived, scope not permitted for this game (`SCOPE.md` §3.1) | Drop silently. |
| 3 | `recent[key]` exists and is younger than `RECENT_TTL` | Drop. A finished session's token can never be resurrected (audit scenario 4). |
| 4 | `sessions[key]` exists | **Idempotent.** Refresh `expires`, do not create, do not raise a second invitation, do not toast. This is a retransmitted or duplicated OPEN. |
| 5 | Any record exists whose `host == sender` and whose token differs | **Supersession**, §4.3. |
| 6 | `#lite records == MAX_LITE` | Evict the oldest lite record that has no popup on screen; if all have popups, drop the new OPEN and add it to the launcher list only. |
| 7 | otherwise | Create a lite record. Raise an invitation or list it, per §5.6 / §6.2. |

There is **no collision window.** A late OPEN is never "a collision" - it is row 3, 4, 5 or 7.
The only two time constants in the whole path are `RECENT_TTL` (120s, poisoned dead tokens) and
the lite record's `expires` (its own `joinSecs + 10`).

### 4.3 Same-host supersession: the one deterministic convergence rule

**Rule: the newest OPEN from a given `(module, host)` replaces that host's previous session on
every client, unconditionally, at any age.**

This is deterministic and client-independent without any comparison, because the host is the sole
authority for its own sessions: if it is sending a new OPEN, its previous session is over on the
host, whatever any client still believes. This is exactly the audit's scenario 5 - a host who
finishes a game and presses "Play again" while a client that missed `END` is stuck at
`phase == "play"`, silently and permanently excluded from every future game (`LootGoblins.lua:889-892`
followed by the token gate at `:901`).

Behaviour by what the superseded record was:

| Superseded record | Action |
|---|---|
| Lite | Evict it, dismiss its Ask **silently** (no toast), remove its launcher row. Then process the new OPEN as row 7. |
| Full, `done` | Evict it, keep the window's final standings if the user has not closed it. Process the new OPEN as row 7. |
| Full, live, **we are seated** | `endSession("The host started a new game. No gold changes.")`, release the seat, evict, then process the new OPEN as row 7 - which raises a **normal invitation we may decline**. Never auto-seat. Toast: `"Loot Goblins: Grizzle started a new game - your previous game is over. No gold changes."` |
| Full, live, **we host it** | Impossible: we are the sender, and row 1 dropped it. |

**What the losing host does: nothing, because there is no losing host.** No host is ever asked to
cancel a session it started, and no `CANCEL` reason `"merged"` exists. The only host-side
supersession is a host superseding *itself*, which `hostOpen` performs locally by replacing its
own record.

**Host double-start protection.** `hostOpen` refuses while this module already holds a full
record (I3), so a double-click cannot emit two OPENs: the first call builds the record
synchronously in the same frame in which it broadcasts. If the broadcast is refused
(`LootGoblins.lua:714-717`) no record is built and the retry is legitimate.

### 4.4 Toast policy for an inbound OPEN

Preserves `SCOPE.md` §6.4's intent (no spam at wide scope) without any refusal:

| Scope | Not seated | Seated (busy) |
|---|---|---|
| `group` | Invitation popup, no toast (the popup *is* the notification). Over `ASK_MAX`: launcher row + the throttled overflow toast. | Launcher row + one throttled busy toast per 60s (§6.2). |
| `guild` | Popup if within `SCOPE.md` §6.3's guild invite budget and under `ASK_MAX`; else launcher row, silent. | Launcher row, silent. |
| `public` | Launcher row only, never a popup (`SCOPE.md` §6.3). | Launcher row, silent. |

### 4.5 Replay and stale-token defence

- **`recent`** poisons a dead key for `RECENT_TTL` (120s), which is the audit's recommended
  "refuse an OPEN whose token equals the most recently finished session from that host",
  generalised and bounded.
- **Non-OPEN messages for an unknown key** are dropped at the registry lookup: one hash lookup,
  no allocation, no state. This is what "ignore its traffic cleanly" means (owner rule 5).
- **`PB` `BET` may no longer fabricate an attempt.** `PullBook.lua:1009-1021` currently runs
  before the `sender ~= book.bookie` check and does `if not attempt then attempt = newAttempt() end`,
  so a single stray `BET` with a matching token materialises a bet window. Replaced by:
  `BET` is processed only if `book` matches `(bookie, token)`, an attempt already exists **and**
  is not frozen, and the sender is in the current group snapshot. No wire message may create an
  attempt; only the bookie's own `READY_ON` / `COUNTDOWN_ON` may (`PullBook.lua:1056-1084`).

---

## 5. Isolation guarantees

### 5.1 What must be true

Two live sessions - same game different hosts, same game different scopes, or different games -
must be unable to affect each other's state, numbers, timers, or pixels. The checklist below is
mandatory for every inbound handler in all three modules.

### 5.2 The inbound gate order

Gates a-e are `Comm.lua`'s and are shared by every module; f-l are per module. Each gate drops
on failure and nothing before the gate may write state.

| # | Gate | Where | Rule |
|---|---|---|---|
| a | **Version** | `Comm.lua:230` | `parts[1] == WIRE_VERSION` ("3"). One chat line ever, then silence. |
| b | **Distribution -> scope** | `SCOPE.md` §4.1 | Derived from the delivery argument, never from a wire field. Unknown distribution drops. |
| c | **Accept / trust** | `SCOPE.md` §4.2, retargeted in §5.4 below | Group senders by roster; guild by opt-in; public by opt-in; whispers by the module trust predicate. |
| d | **Rate limit** | `SCOPE.md` §4.2 step 4 | Per-sender 12 cap / 2 per s; global 60 cap / 20 per s. |
| e | **Module route** | `Comm.lua:240-244` | Unchanged. |
| f | **Mtype class** | new, §5.3 | `OPEN` -> the OPEN path. Host-authored set -> resolve against `(sender, token)`. Client-authored set -> resolve against the hosted record only. Unknown mtype -> drop. |
| g | **Session resolution** | new | `sessions[keyOf(sender, token)]`, or the hosted record for client-authored types. No record -> drop. **This single gate replaces the old `token ~= S.token` test and is what makes two sessions non-interfering.** |
| h | **Kind** | new | Lite record: accept only `CANCEL`, `END`, `BEGIN` (each merely evicts the record and dismisses its invitation) and `HB` (refresh `expires`). Everything else drops. A lite record never reaches an applier. |
| i | **Scope equality** | `SCOPE.md` §6.1 | `scope == "private" or scope == rec.scope`. Blocks re-broadcasting a live guild session's token into party chat. |
| j | **Sender authority** | `LootGoblins.lua:915` generalised | Host-authored: guaranteed by gate g's key (`sender` *is* `rec.host`). Client-authored: `rec.isHost` required, plus `rec.joined[sender]` for `PICK` / `UNJOIN`. |
| k | **Phase** | existing appliers | `rec.phase ~= "done"`, plus each applier's own phase precondition (`LootGoblins.lua:160, 193, 232, 251, 312, 331`). Unchanged. |
| l | **Seat, for local actions** | new | `doPick` / `doThrow` additionally require `rec == mySession()` and `rec.seated`. A referee host has no pick. |

Reference prologue, identical in `LG` and `RPS`:

```lua
local HOST_AUTHORED = {
  HB = true, JOINED = true, LEFT = true, BEGIN = true, ROUND = true,
  RESULT = true, VOID = true, END = true, CANCEL = true,
  SYNCOK = true, SYNCNO = true,
}
local CLIENT_AUTHORED = { JOIN = true, UNJOIN = true, PICK = true, SYNCQ = true }

local function onComm(mtype, token, sender, scope, f1, f2, f3, f4, f5)
  if not validToken(token) then return end                       -- 3.4
  if mtype == "OPEN" then return onOpen(token, sender, scope, f1, f2, f3, f4) end

  local rec
  if HOST_AUTHORED[mtype] then
    rec = sessions[keyOf(sender, token)]                         -- gate g
  elseif CLIENT_AUTHORED[mtype] then
    local m = mySession()
    if m and m.isHost and m.token == token and scope == "private" then rec = m end
  else
    return                                                       -- gate f
  end
  if not rec then return end
  if rec.kind == "lite" then return liteObserve(rec, mtype) end  -- gate h
  if rec.phase == "done" then return end                         -- gate k
  if scope ~= "private" and scope ~= rec.scope then return end   -- gate i
  ...                                                            -- existing body, S = rec
end
```

Splitting by mtype class rather than falling back between lookups removes the last ambiguity:
a peer who hosts a session whose token happens to equal ours can never have its whisper resolve
against our hosted record, and vice versa.

### 5.3 Why the old gate was insufficient

`if not S or S.phase == "done" or token ~= S.token then return end`
(`LootGoblins.lua:901`, `RockPaperScissors.lua:841`) is correct *only* while one session exists.
It is a filter, not a router: it cannot express "this message belongs to a session I know about
but am not in", so its answer to that case is to discard the message **and** leave the client
permanently unable to hear the other session (audit scenarios 2 and 5). Gate g answers the
routing question directly and the phase gate stops carrying a job it was never designed for.

### 5.4 Trust predicate, retargeted

`SCOPE.md` §4.3, mechanically pointed at the registry. Same logic, same rationale:

```lua
PG.Comm.RegisterTrust("LG", function(sender)
  local S = mySession()
  if not S or S.phase == "done" then return false end
  if sender == S.host then return true end
  if S.joined[sender] then return true end
  if S.isHost and S.phase == "join" and S.scope ~= "group" then return true end
  return false
end)
```

Only the involved session vouches for whisper traffic. Lite records never do - they never expect
a whisper, because we never whispered them anything.

### 5.5 Shared resource: the send queue and `onDrop`

There is one queue and one 10-token bucket for the whole addon (`Comm.lua:21-24, 95-123`), and a
lockdown drops every queued entry permanently (`Comm.lua:98-100`). `onDrop(mtype)` carries **no
session identity**, so today a dropped message kills whatever `S` happens to be
(`LootGoblins.lua:1016-1022`). With two live sessions that is one session killing another.

**Required change to `Comm.lua`:**

```lua
-- submit() records the token on the entry; dropEntry passes it through
local function dropEntry(entry, why)
  local onDrop = moduleDrops[entry.module]
  if onDrop then pcall(onDrop, entry.mtype, entry.token) end
end
```

`PG.Comm.Broadcast` / `BroadcastEx` / `Whisper` already receive `token` as a parameter; it is
stored on the entry and handed back. Each module's `onDrop(mtype, token)` then aborts **only**
the record matching `keyOf(myName(), token)`, and only if it is the involved one. A drop for an
unknown or foreign token is ignored.

Additional rules:
- Lite records never send, so they cannot consume bucket tokens.
- A client is involved in at most 2 sessions total (one seat + one referee), which bounds its own
  outbound traffic to what one session generated before this change, plus a referee's host
  traffic.
- The `JOINED`-per-joiner broadcast storm during a large join phase (`LootGoblins.lua:600-603`)
  is a pre-existing `Comm` problem, out of scope here, and is called out in §9.

### 5.6 Shared resource: the Ask popup

**Key.** `PG.UI.Ask(game .. ":" .. host .. "|" .. token, ...)`. The per-game keys `"lg-invite"` /
`"rps-invite"` (`LootGoblins.lua:803`, `RockPaperScissors.lua:752`) are the bug behind owner rule
3: a second invitation to the same game hits `if f.active then finishAsk(f, false) end`
(`Widgets.lua:360`) and silently auto-declines the first.

**New `Widgets.lua` API:**

```lua
PG.UI.Dismiss(key)        -- finishAsk(f, false) if active; no-op otherwise
PG.UI.AskCount()          -- number of active Asks, all modules
```

**Rules:**

1. **Cap.** At most `ASK_MAX = 3` active Asks across all modules. Popups stack at
   `140 - stacked * 150` (`Widgets.lua:367-372`); at n = 3 the lowest spans roughly -230 to -90
   in `UIParent` centre coordinates, which is safe on every supported resolution. A fourth
   invitation does not pop: it goes to the launcher's *Open games* list plus one throttled toast
   (§6.2).
2. **Re-layout on close.** `finishAsk` must re-run the stacking of the remaining active Asks.
   Today the offset is computed once at activation, so closing the top popup leaves a hole.
3. **Accepting one withdraws the rest.** The accept callback claims the seat first
   (`PG.Session.Claim`); on success, `PG.Session.OnChange` fires and every module dismisses its
   own outstanding invite Asks and marks those lite records `askKey = nil` (they stay in the
   launcher list until they expire). If the claim *fails* - a genuine race with a JOINED landing
   from elsewhere - the accept is abandoned with
   `"Loot Goblins: you just joined another game - not buying in here."` and nothing is whispered.
4. **A dead session takes its invitation with it.** Every eviction path, `applyCancel`,
   `applyEnd` and `endSession` call `PG.UI.Dismiss(rec.askKey)`. This is the audit's 3b defect:
   today a cancelled game leaves a live countdown popup inviting you into a dead session, and
   clicking Buy in silently does nothing.
5. **Timeout** is the invitation's remaining life, `math.max(1, rec.expires - GetTime())`, not
   the raw `joinSecs`, so a popup raised late does not outlive its join window.
6. **Replacement ordering is already correct** and must stay so: `finishAsk(f, false)` runs
   before `onAccept`/`onDecline` are rebound (`Widgets.lua:360-363`) and grabs the *old*
   callbacks (`:279-282`). Do not "simplify" that.
7. **DND** is unchanged: `PG.UI.Ask` auto-declines immediately (`Widgets.lua:351-354`), so a DND
   player never seats. Their lite records still appear in the launcher list.

### 5.7 Shared resource: the toast

`PG.UI.Toast` is a single overwrite slot with a 3-second life (`Widgets.lua:471-481`), so `LG`
and `RPS` erase each other, and a `PB` settlement line ("Kill bet: 3 winners split 900g - you
+300g") can be wiped by an unrelated "back in sync" toast within its display time. `PB` already
maintains a private FIFO draining one item per 3.2s (`PullBook.lua:144-178`) into that
single-slot sink, which does not help.

**Promote the queue into `Widgets.lua`:**

```lua
PG.UI.Toast(text, opts)   -- opts = { key = , sound = , priority = "normal"|"result" }
```

- FIFO, one on screen at a time, 3s life as today.
- **Minimum on-screen time 1.2s**: a newcomer never replaces a toast younger than that; it
  queues behind it.
- Queue cap 4; a full queue drops the **oldest `"normal"`** entry, never a `"result"` entry
  (money and medals win over status chatter).
- `key` deduplicates: a queued toast with the same key is replaced in place rather than appended.
  `LG` uses `"lg-status"`, `PB` uses `"pb-<market>"`, and so on.
- Maximum queue wait 8s, then the entry is dropped - a stale status line is worse than none.
- `PullBook.lua:144-178`'s private FIFO is **deleted**; `PB` passes `sound` through `opts` and
  keeps only its reveal-payload queueing.

**Attribution.** When a module holds more than one record, its toasts name the host:
`"Loot Goblins (Grizzle): ..."`. With a single record the text is unchanged. Without this a
player in two audiences cannot tell which game a line refers to.

### 5.8 Shared resource: the reveal stage

The stage is a single frame with an idle gate; `Theme.Reveal` drops its payload when the stage is
busy (`Theme.lua:2082-2086`, `2010-2020`), so an `LG` podium occupying it for ~5s silently eats
an `RPS` round reveal.

**Rules:**

1. **Only a full record may call `Theme.Reveal` / `Theme.RevealQueue`.** Lite records never
   present anything.
2. **Ownership.** Every payload carries
   `validate = function() return sessions[key] == rec end`, extending the existing
   `validate = (S == sess)` closure (`LootGoblins.lua:1539`, `RockPaperScissors.lua:1263`) to the
   registry. A payload whose session was evicted is culled at drain time.
3. **Precedence when both a seated and a referee session want the stage:** the **seated** session
   wins. Per-round moments (`Theme.Reveal`) from the referee session are dropped when the stage
   is busy - which is the existing, correct behaviour, because text state is always final before
   any FX runs. Session-end podiums use `Theme.RevealQueue` from both and play in order.
4. **The stage never gates the seat.** A podium may still be queued when the next game's join
   phase begins (§1.1, §7.1). It plays over it. This is cosmetic and accepted.
5. The `PB` bet strip's protection is already correct by two independent mechanisms
   (`PullBook.lua:1056-1084` plus `rvCanNow`, `Theme.lua:2010-2015`) and is unchanged.

### 5.9 Shared resource: the game window

One window per module (I3), bound to the involved record:

- `win.__pgRec = rec` at `ensureWindow` / on record change.
- `ShowWindow` (`LootGoblins.lua:1819-1835`) additionally requires `rec == mySession()`.
- `RefreshUI` is driven from `onTick` whenever `win:IsShown()` (`LootGoblins.lua:1123`) and today
  **never hides**, so a replaced session leaves a fully drawn, live-looking window behind
  (audit 5b). New rule: when the involved record is evicted or replaced and the local player is
  not seated in the replacement, `win:Hide()`.
- A `done` record keeps its window (final standings, Ledger button) until the user closes it or
  a new involved session replaces it. Eviction after `DONE_TTL` hides it.
- `PG.UI.ResolveOverlaps` (`Widgets.lua:49`) already keeps an `LG` and an `RPS` window from
  covering each other; no change.

### 5.10 Shared resource: the launcher *Open games* list

`SCOPE.md` §6.3 defines it (5 entries, 60s TTL, deduped per sender, ignore-filtered,
`PG.Launcher.AddOpenGame`). This document adds three requirements:

1. It is the **overflow target** for invitations beyond `ASK_MAX`, and the **only** surface for
   opens received while seated (§6.2), at every scope including `group`.
2. Its rows are fed from lite records, one row per record, and disappear when the record is
   evicted. It is a view, not a second store.
3. The `Join` button is disabled while the seat is held, with tooltip
   `"You're playing <Host>'s <Game> right now."` Clicking `Join` on an available row runs the
   same accept path as the Ask (claim seat -> `clientOpen` -> whisper `JOIN` ->
   `clientRequestSync()`).

---

## 6. Busy behaviour

### 6.1 What "busy" is

Busy means **the seat is held** (`PG.Session.IsSeated()`), and nothing else. Hosting a game is
not busy (rule 4). Having lite records is not busy. Being in a Pull Book is not busy (I10).

### 6.2 What a busy client does with an inbound OPEN

1. Creates the lite record exactly as usual - being busy never means being deaf.
2. **Raises no popup.** An Ask you cannot accept is worse than no Ask.
3. Adds a launcher *Open games* row with `Join` disabled (§5.10).
4. **Group scope only:** one toast, throttled to at most one per 60 seconds regardless of how
   many opens arrive in that window:

   > `Loot Goblins: Grizzle started a game - you're in another game right now. It's in the Pengyou Games window.`

   With more than one open in the throttle window, the line collapses to:

   > `2 more games are open - see the Pengyou Games window.`

   Guild and public scope: **silent**. A popular guild starting five games must not produce five
   lines. This is the same escalation shape as `SCOPE.md` §6.3's guild invite budget, and the
   throttle is one timestamp per module.

### 6.3 Does the would-be host learn you are busy? No.

**Decision: no `BUSY` message. Do not build one.** The audit proposed a one-shot `BUSY` whisper
back to the OPEN sender, and it is the wrong trade here:

- **It no longer buys correctness.** Under the old model, everyone being busy meant the host's
  game was dead on arrival and he was told "not enough players joined". Under this model the host
  is not blocked, the game runs with whoever joins, and busy players see the game in the launcher
  and can join the next one.
- **It costs the most at exactly the wrong moment.** At guild scope, one OPEN can produce a
  reply from every listening client, each spending a token from a **shared 10-token bucket**
  (`Comm.lua:21-24`) that its own live game's `PICK` whisper needs. The audit's own scenario 8a
  is that one module's traffic starving another's is session-fatal. A politeness feature must not
  be able to break a game in progress.
- **It cannot answer the question it appears to answer.** `BUSY` still does not distinguish DND,
  passed, no addon, or loading screen, so the host's uncertainty is reduced, not removed.

Instead, two zero-wire improvements:

1. **Honest cancel text.** `applyCancel` reason `"few"` (`LootGoblins.lua:376-377`) changes from
   `"Cancelled - not enough players joined."` to:

   > `Cancelled - not enough players joined. Others may be busy or away.`

2. **Show what we already know.** The host's join window gains a line built from `PG.Peers`
   (`Core.lua:235`, populated by `CO HELLO`): `"3 of 7 addon users have joined."` No new
   messages; the data is already there.

### 6.4 The Start button when this module is already involved (I3)

Never the old blanket line. The dialog always opens; Start is disabled with an explanatory
tooltip and a line in the dialog:

| Situation | Text |
|---|---|
| Hosting a live game in this module | `"You're already running a Loot Goblins game. Cancel it first, or wait for it to finish."` |
| Seated in someone else's game in this module | `"You're playing <Host>'s Loot Goblins game. You can start your own when it's over."` |
| Seated in the *other* module | Start is **enabled**. Dialog line: `"You're playing Rock Paper Scissors, so you'll run this game without playing in it."` (referee, I5). |
| Neither | Normal. |

### 6.5 Referee host, in the UI

- Roster shows the host as `"Grizzle (running the game)"`, outside the numbered roster.
- The host's own panel already has the right string for a non-participant:
  `"You have no stake in this game."` (`LootGoblins.lua:1800-1801`).
- SHARE/HOARD and throw buttons are hidden (they are already gated on roster membership).
- Cancel and the join-window controls stay.
- The referee writes **no ledger row** (participation gate G1) and the pot arithmetic is
  unaffected: `pot = buyin * #roster` with the host absent from the roster, and the zero-sum
  check (`SCOPE.md` §4.4 G3) sums over the roster, so it still balances.
- `hostCloseJoin`'s `count < 2` minimum (`LootGoblins.lua:574`) now means two *other* players.

---

## 7. Teardown

### 7.1 When a session stops being active

**The instant `endSession()` sets `phase = "done"`.** At that moment, in this order:

1. `phase = "done"`, `roundOpen = false`, ticker work for it stops (existing code).
2. `PG.Session.Release(module, token)` - the seat is free; a new game may start **now**.
3. `PG.UI.Dismiss(rec.askKey)` - any invitation for this session comes down.
4. The launcher row is removed.
5. The window keeps final standings; the podium may still be queued and will still play.

Deliberately **not** part of "active": the reveal stage, the podium, the results window, the
`DONE_TTL` memory window. A queued podium can wait out an encounter (`Theme.lua:2010-2015`);
blocking the next game behind decoration would be a self-inflicted denial of service.

### 7.2 Every path that ends a session

| Path | Trigger | Seat | Ledger | Record |
|---|---|---|---|---|
| Normal end | `END` applied (`applyEnd`, `LootGoblins.lua:331`) | released | written by participants only (G1) | `done`, evicted after `DONE_TTL` |
| Host cancel | `CANCEL` from host, or host presses Cancel | released | none | `done` -> evicted |
| Too few joined | `hostCloseJoin` -> `CANCEL "few"` | released | none | `done` -> evicted |
| Host dead | 35s group / 150s quiet + 300s wide (`SCOPE.md` §6.2) | released | none | `done` -> evicted |
| Critical send dropped | `onDrop(mtype, token)` matching **this** record (§5.5) | released | none | `done` -> evicted |
| Transport lost | `PG.Comm.ScopeAvailable(rec.scope, 8)` false on the host (`SCOPE.md` §6.1) | released | none | `done` -> evicted |
| Superseded | New OPEN from the same `(module, host)` (§4.3) | released | none | evicted immediately |
| **Withdrawn** | Local player presses Withdraw -> `applyLeft(me)` | released | none | **evicted immediately**, window hidden |
| Not seated at BEGIN | `applyBegin` finds the local player absent from `roster` | released if held | none | **evicted immediately** (see §7.3) |
| `/reload`, logout | - | gone with the client | none | gone; a hosted session is **not** resumed, and its clients abandon it on the heartbeat timeout |

Two of these are behaviour changes worth flagging in the release notes: **withdrawal now stops
your client tracking the game**, and **passing on an invitation never creates state at all**.

### 7.3 Overheard sessions can never accumulate

This is the memory contract, per module:

| Store | Cap | Eviction |
|---|---|---|
| Full record | 1 | `done` + `DONE_TTL` (60s) + reveal drained + window closed or replaced |
| Lite records | `MAX_LITE = 8` | `expires` (`joinSecs + 10`, clamped to 15..180s), or on observing `BEGIN` / `CANCEL` / `END` for that key, or LRU eviction of the oldest popup-less record at cap |
| `recent` | `MAX_RECENT = 16` | `RECENT_TTL` (120s) or FIFO at cap |

A lite record's whole purpose is the invitation window, so it dies with it. In particular it dies
at `BEGIN`: once a game we did not join has started, we have no reason to know it exists. This is
`SCOPE.md` §6.3's wide-scope mirror release, generalised to **every** scope per owner rule 5 -
group-scope bystanders stop mirroring games they declined, which is the single largest state
reduction in this document.

Sweeping is on the module ticker at 2-second granularity (§2.5), bounded at 25 entries.

### 7.4 Abort-path invariant

**All-or-nothing on the ledger is unchanged and non-negotiable.** Every abort before `END`
actually leaves the wire writes nothing anywhere (`LootGoblins.lua:544-556` documents the
contract; `onSent` is what commits it). Concurrency adds no new commit point. Every new teardown
path in §7.2 is an abort in that sense except the first row.

---

## 8. Build order

Six steps. Each is independently shippable and independently testable. `SCOPE.md` step 3
(ledger hardening, G1-G4) is a **prerequisite for step 3 here** - see §0.4.

### Step 1 - Identity and the registry, with no behaviour change

`PG.NextToken` + `b36` + `math.randomseed`; `keyOf`; `sessions` / `mine` / `recent`;
`mySession()`; `S = mySession()` threading in `LG` and `RPS`; the `(host, token)` keying in `PB`;
gate f/g/h/i/j of §5.2. The registry holds exactly one record and every refusal stays where it
is. Ledger id gains the host (§3.4).

**Milestone:** two accounts play a full Loot Goblins game and a full Rock Paper Scissors game
with identical outcomes to 0.5.0. `/pg debug` shows tokens of the form `1a-7f3`. A `/reload`
followed by a new game shows a strictly higher counter. Re-broadcasting a finished game's token
does nothing on any client.

### Step 2 - The seat, in Core, and referee hosting

`PG.Session.Claim` / `Release` / `Seat` / `OnChange`; claim at accept and at `hostOpen`; release
in `endSession` and on withdrawal; the referee path (I5) including roster, pot, buttons and the
dialog line; `PB` verified to touch none of it.

**Milestone:** accept a Loot Goblins invitation, then accept a Rock Paper Scissors invitation -
the second is refused with the exact §5.6 rule 3 string, and the first game is undamaged. While
seated in RPS, start a Loot Goblins game: it starts, you are absent from its roster, two other
accounts play it to `END`, the pot balances, and you write no ledger row while they both do.

### Step 3 - Remove the refusals; lite records; multiple invitations

Delete every row of §0.2; the OPEN decision table (§4.2); lite records and their sweep; per-
session Ask keys, `PG.UI.Dismiss`, `AskCount`, `ASK_MAX`, re-layout on close, dismissal on
session death; withdraw-the-rest on accept; supersession (§4.3).

**Milestone:** in one raid, five accounts run a Loot Goblins game while three others run Rock
Paper Scissors and two more run a **second** Loot Goblins game; all three finish, and each
participant's Tonight tab contains rows for their own game only. A client that hears two Loot
Goblins OPENs one second apart shows two popups, accepts either, and the other popup disappears.
A host who finishes a game and immediately presses Play again pulls in a client that never saw
`END` - that client sees "your previous game is over", then a fresh invitation.

### Step 4 - Isolation hardening

Token-scoped `onDrop` (§5.5); the `PB` `BET` fix (§4.5); the trust predicate retarget (§5.4);
the scope-equality gate (§5.2 i); mtype-class routing (§5.2 f).

**Milestone:** with `LG` and `RPS` both live, forcing a lockdown drop of an `LG` `RESULT` aborts
the Loot Goblins session **only**; the Rock Paper Scissors game finishes normally. A crafted
`BET` for a live book with no bet window open creates nothing. A live guild session's token
re-broadcast on `PARTY` changes nothing.

### Step 5 - Shared resources

The toast queue in `Widgets.lua` and the deletion of `PB`'s private FIFO; toast attribution;
reveal ownership and precedence; window binding and the hide-on-replace rule.

**Milestone:** an `LG` end podium and an `RPS` round result queued in the same second both play,
in order, neither eaten. A Pull Book settlement toast is never erased by a status toast; it
stays its full 3 seconds. Replacing a session hides the old window instead of leaving a live-
looking one.

### Step 6 - Teardown, budgets and the launcher list

`DONE_TTL` / `RECENT_TTL` / `MAX_LITE` / `MAX_RECENT` sweeps; the launcher *Open games* list as
overflow and busy surface; the busy toast throttle; the §6 strings; the `PG.Peers` join-window
line.

**Milestone:** after 40 opens over ten minutes with none accepted, `sessions` holds at most 8
lite records and `recent` at most 16 (verified via `/pg debug`), with no frames or tickers
created beyond the module ticker. While seated, ten guild opens produce zero popups, zero toasts,
and at most five launcher rows.

---

## 9. Out of scope

Explicitly not built, not designed around, and not to be added during implementation.

1. **Two involved sessions in the same module** - hosting a Loot Goblins game while seated in
   another Loot Goblins game. It requires per-session instantiation of every presentation
   singleton (`win`, `ui`, `rows`, `stampPool`, `sparkFrame`, the Grizzle model,
   `LootGoblins.lua:29-52`). Cross-module concurrency covers every real use case.
2. **Any negotiation, election, or merge protocol between hosts.** No `BUSY`, no `MERGED`, no
   `CANCEL "merged"`, no vote. This document adds **zero** new message types.
3. **Cross-session state of any kind** - shared pots, cross-game standings, a combined ledger
   view per audience, "who is in what" discovery beyond the launcher's 5-row list.
4. **Late join.** A session that has passed `BEGIN` cannot be joined. Its lite record is evicted
   at `BEGIN` precisely so we stop pretending otherwise.
5. **Rejoin after withdrawing** from a game you were seated in.
6. **Session persistence across `/reload` or logout.** A hosted session dies with the client and
   its participants time out on the heartbeat.
7. **Spectating a game you did not join.** Overheard sessions render an invitation and nothing
   else - no window, no roster, no standings. This is owner rule 5 and it is the reason the
   memory contract is bounded.
8. **More than one Pull Book at a time.** `PB` keeps first-book-wins; a second bookie's book is
   remembered as a lite record and surfaces in the launcher, and switching books requires no open
   attempt. Full `PB` multi-book is not v1.
9. **Fixing the `JOINED`-per-joiner broadcast storm** during a large join phase
   (`LootGoblins.lua:600-603`) or any other shared-send-bucket capacity work. It is a real
   `Comm.lua` problem (audit 8a), it is made no worse by this document, and it belongs in a
   Comm-layer change with its own spec.
10. **The Pull Book FD deadline race** (`PullBook.lua:800-802` local 20s timer versus a
    queue-delayed `FD`), which produces divergent settlements. Real, out of scope here,
    documented for the `Comm` priority work.
11. **Per-session UI scale, position, or theming.** One window per module, one saved position.
12. **Reveal-stage queue fairness across modules** beyond the seated-wins precedence of §5.8.
13. **Localisation** of the new strings; they go through `PG.L` like everything else and stay
    English in v1.
