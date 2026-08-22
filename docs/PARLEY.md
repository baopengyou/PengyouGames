# PARLEY.md — The Mythic Parley

**Status: binding.** Implementation spec for the Pull Book's second mode, shipped in `1.4.0`
as module code **`MP`** in `PengyouGames/Games/MythicParley.lua`.

Companion docs: `SPEC.md` (protocol + safety), `SCOPE.md` (audience selector — see its §0c
delta, which this document is the reason for), `CONCURRENCY.md` (registry, gates, teardown),
`REVEAL.md` (results stage), `SKIN.md` (presentation).

---

## 1. The one fact this whole design is built around

**Inside a Mythic+ keystone run, this addon cannot talk to itself.**

`C_ChatInfo.InChatMessagingLockdown()` is true for the entire duration of an active keystone
(verified 12.1; see the project's API notes). Every `SendAddonMessage` is refused with
`AddOnMessageLockdown` (11), which `Comm.lua` treats as **permanent** — dropped, never retried.
Blizzard actively closes in-lockdown side channels, so there is no fallback to build and none
will be built.

The Pull Book's raid mode does not care: a raid pull is a ~30-second lockdown between two long
windows of legal traffic, and `PB` opens its bet strip in the pre-pull window and settles from
`ENCOUNTER_END` on the far side. A key is a **thirty-minute** lockdown. Any design that needs a
message during the run is dead on arrival.

So the Mythic Parley is a **pre-commitment game**:

```
   bets open           LOCK             (30 minutes of silence)           RES
  ─────────────┬──────────────┬───────────────────────────────────┬──────────────
   wire live   │  wire live   │   wire refused, events still fire  │  wire live
               │              │                                    │
        everyone's picks   key starts               key ends,  bookie broadcasts
        are already in                            lockdown lifts   the facts
```

Everything that has to be agreed is agreed **before** the key. Everything that has to be
observed is observed by the **bookie's own client**, locally, with no traffic at all. The
settlement is one broadcast on the far side.

---

## 2. What you bet on

**The bookie posts a card of up to five lines.** Not a fixed board: a parimutuel
market needs at least one backer on each side or it voids, so spreading five people across a
dozen pools produces ten void markets and two thin ones. Five is what a five-person party can
actually fill, and it makes a guild parley concentrate rather than sprawl. The cap is enforced
at the checkbox, which un-ticks itself and says why rather than silently refusing.

Ten line types. `MARKET` in the module declares which optional fields each carries, and the
wire codec reads that table rather than encoding the shape - which is what keeps a five-line
card short enough to ride on `OPEN` beside the stake and the dungeon.

### 2.1 Run-level — need nothing but the run

| Code | Row label | Settles as | Options | Resolved from |
|---|---|---|---|---|
| `T` | **Timed?** | "Time the key bet" | `YES` / `NO` | `GetCompletionInfo().onTime` |
| `X` | **Deaths** | "Deaths bet" | `OVER` / `UNDER` a line | `GetDeathCount()` |
| `A` | **Boss wipes** | "Boss wipes bet" | `OVER` / `UNDER` a line | count of `ENCOUNTER_END(success == 0)` |
| `M` | **Time left** | "Time left bet" | `OVER` / `UNDER` *n* minutes | elapsed time against `GetMapUIInfo().timeLimit`; negative when over |
| `F` | **First death** | "First death bet" | `TANK` / `HEALER` / `DPS` | `UNIT_DIED` against a roster snapshot taken at lock — the raid Pull Book's exact machinery |

### 2.2 Per boss — need the roster

| Code | Row label | Options | Resolved from |
|---|---|---|---|
| `L` | **First wall** | one per boss | the id of the first boss any attempt failed on |
| `W` | **Worst boss** | one per boss | most attempts; ties to the lowest id |
| `O` | ***boss* one-shot?** | `YES` / `NO` | that boss's attempt count == 1 |
| `P` | ***boss* attempts** | `OVER` / `UNDER` a line | that boss's attempt count |
| `D` | ***boss* deaths** | `OVER` / `UNDER` a line | `GetDeathCount()` differenced across that boss's encounters |

`OVER` is strict everywhere: a run that lands **exactly on** the line is `UNDER`. That is
stated on the Rules page in those words, because "under 5" meaning "5 or fewer" is the one thing
a bettor will argue about afterwards.

A line whose subject never happened voids with stakes returned and a reason: `L` when nobody
walled, `W` when no boss was engaged, `F` when nobody died, and `O`/`P`/`D` when that boss was
never fought.

### 2.3 The order the bosses were killed in is not a thing you can bet on

**A Mythic+ route does not visit bosses in a fixed order.** Skips, route choice and plain
preference mean "the second boss" does not exist as a fact about a run, and the first draft of
this mode was wrong to offer `BOSS 1 / BOSS 2 / BOSS 3+` as if it did. A group that opens on the
last boss and wipes has walled on *that boss*; calling it "boss 1" settles a different bet from
the one anybody placed.

So **every per-boss line keys on the boss's own `dungeonEncounterID`** — the number
`ENCOUNTER_END` reports — and never on a position. Order survives in exactly two places: the
order the buttons are drawn in, and the single question "which boss did we wall on *first*",
which still resolves to an id. The offline harness runs its whole scenario with the route
deliberately scrambled (open on the journal's third boss, wall there, clear the other two
after) precisely so that a regression to positional keying fails a test rather than a raid
night.

### 2.4 Where the dungeons and the bosses come from

**The season rotation is not shipped data.** `C_ChallengeMode.GetMapTable()` is the live list of
this season's keystone dungeons, straight from the client — nothing here goes stale in six
months and nothing depends on another addon keeping a table current. It is populated
asynchronously and can be **empty on a fresh login**, so `RequestMapInfo()` is called at load,
on every window open, and whenever the list comes back empty, and `CHALLENGE_MODE_MAPS_UPDATE`
repaints the picker when it lands. Without that the picker reads "no dungeons reported yet" for
the first minute of every session, which looks exactly like a broken addon. The picker defaults to,
in order: the keystone actually slotted in the font of power, the key already running, the last
dungeon this character posted a card for, and the first of the season. The slotted keystone
leads because it is the only one of the four that is *evidence about what is about to be run*.

**The boss roster is a chain**, in the style of `Theme.Tex`'s asset chains — try, check what
came back, fall back, and have an honest bottom:

1. the runtime memo
2. `db.mp.bosses[mapId]`, resolved or learned on a previous session
0. **the journal has to be loaded first.** `Blizzard_EncounterJournal` is a
   load-on-demand addon: the `EJ_*` functions live in the base client and answer calls all day,
   but their *data* does not exist until it has been loaded once. On a client where the player
   has not opened the journal this session — which is most clients, most of the time — the tier
   walk returns an empty list and every dungeon reports UNKNOWN. It is loaded lazily on the
   first roster question rather than at login, because it is a real chunk of memory to spend on
   a mode nobody may open. **This was missing from 1.4.0 and is the whole reason per-boss lines
   never appeared.**
3. **the journal, by the map you are standing in.** `C_Map.GetBestMapForUnit` →
   `EJ_GetInstanceForMap` → `EJ_GetInstanceInfo`: one call each, no iteration. This is tried
   *before* the tier walk because it is both cheaper and sturdier, and it is available at
   exactly the moment it is most wanted — at the dungeon door, opening a parley for the key you
   are about to run
4. **the journal, by walking its tiers**, matched to the challenge map **by name** (both strings
   come from the same client in the same locale, so they agree)
5. **what any key you run teaches this client.** `ENCOUNTER_END` during an active keystone
   records `(id, name)` for the dungeon it happened in — **always, with or without a parley
   open**, and flushed after every boss rather than at completion. It *merges* rather than
   replaces, so a key abandoned after one boss still contributes that boss and next week's run
   adds the rest, and it will not overwrite a journal roster (which has the canonical order,
   where a learned list is sorted by id — stable, but arbitrary).

   This is the path that does not depend on the Encounter Journal at all, and it is why a
   client whose journal never answers still ends up with per-boss lines: play your keys as
   normal and the dungeons fill in one at a time.
6. nil — and the per-boss lines are simply not offered, with the card page saying so and saying
   what fixes it ("run it once and the parley learns them")

Steps 3 and 4 match **exactly first, then case- and punctuation-insensitively** —
"Operation: Floodgate" against "Operation Floodgate". Normalisation is applied to both sides, so
it can never make two genuinely different dungeons compare equal, and a real mismatch still
falls through to the learned-from-a-run path.

Steps 3 and 4 **both verify by name**, and that check is load-bearing rather than defensive:
standing in a dungeon proves nothing about which challenge map the *picker* has selected, and a
roster silently attached to the wrong dungeon would name bosses that never appear and then void
every per-boss line at settlement. The seventh return of `EJ_GetEncounterInfoByIndex` is
`dungeonEncounterID` and it is the one that matters — `journalEncounterID` is the journal's own
key and matches nothing `ENCOUNTER_END` reports, so a roster built from it would name bosses
correctly and never resolve a single bet.

Every step is `pcall`'d: the journal is the least stable surface this addon touches and a
betting window is not worth a Lua error. Step 4 saves and restores the journal's current tier,
because an open Encounter Journal is a window the player may be reading. `rosterOf` memoises
its **failures** as well as its hits, so the tier walk does not run on every repaint — and
`PLAYER_ENTERING_WORLD` clears those misses, because zoning is the only moment step 3 can start
working when it could not a minute ago.

**`/pg keys` prints the whole chain's verdict**: the lockdown state, the season list, and for
every dungeon whether its bosses are known and *where they came from*. Every failure in this
chain fails safe — a line is quietly not offered — which is exactly why it needs a command: a
safe failure and a broken addon look identical from the outside.

**The bookie broadcasts the roster it resolved**, in its own `ROSTER` message, immediately after
`OPEN` and again every fourth heartbeat — once a minute — so a guildmate who joins from the
launcher two minutes late still gets boss names. Clients do not fall back to their own journal
for *naming* a live parley: one authority for the names means the board reads the same on every
screen. Until `ROSTER` lands, a boss-keyed row renders greyed with "waiting for boss names" and
cannot be clicked, because a button with no name on it is not a bet.

## 3. Rulings

These are the decisions that a player will eventually want justified. They are written down
here so the answer does not have to be re-derived in an argument at 11pm.

### 3.1 An abandoned key voids EVERY market

If the key is reset, or the group leaves without completing it, every market voids and every
stake is returned. Nothing is settled and nothing is written to the ledger.

Not because the facts are unreadable — `T` would be an unambiguous `NO`, and the death count is
right there. Because **settling an abandoned key is manipulable by the people playing it.** Five
players who can see the board and are collectively holding `NO` can end the key and take the
pot. Voiding is the only rule that no participant can steer toward a payout. Voiding is *weakly*
manipulable in the other direction (bail out to get your stake back), but the payoff is a
refund rather than a pot, and it costs the whole group the run — so it is strictly the lesser
exploit. Owner's ruling; it is not a judgement about which outcome is "fairer", it is about
which outcome can be bought.

### 3.2 The bookie is the sole authority for the result

Every client settles from one `RES` broadcast. Party members are standing in the same dungeon
and could re-derive `T` and `X` themselves — they deliberately do not.

Two reasons, and the second is the load-bearing one:

1. Guild-scope bettors are not in the dungeon and can observe *nothing*. If party members
   self-derived and guildmates took the broadcast, one settlement would have two sources and
   they would disagree the first time somebody's client missed an `ENCOUNTER_END`.
2. `A` and `B` are counted from `ENCOUNTER_END` over half an hour. A player who disconnects for
   ninety seconds mid-key comes back with a different count and no way to know it. One authority
   means one answer; a disagreement about money is worse than a wrong number that everybody
   shares.

This is the `LG` / `RPS` host-authoritative model, which `SCOPE.md` §0b already ruled acceptable
for `DR` and `GB` ("the host is trusted here exactly as it is in `LG`, `PB` and `RPS`"). The
ledger is advisory, settlement is manual, and the four `Ledger.Commit` gates are what bound the
damage.

### 3.3 Party and Guild. Not Public.

`PG.MP.SCOPES = { group = true, guild = true, public = false }`

Guild is the point of the mode — the raid wants to bet on the key three of them are about to
run, and the other seventeen want in. This is an owner decision of **2026-08-21**, and it is a
deliberate departure from `SCOPE.md` §1.2's ruling that the Pull Book is party-only. That
ruling's reasoning ("the outcome is inseparable from the raid the bookie is physically standing
in") is *still correct about the raid Pull Book* and is untouched. What changed is that a key
produces a **single, discrete, machine-read result at a known moment** — timed or not, N deaths,
N wipes — instead of a running stream of encounter events, so there is exactly one thing to
report and one moment to report it. That is what makes a spectator audience coherent here and
incoherent there.

Public stays off. At public scope `Ledger.Commit` demands a witnessed roster and there is no
independent source to check a name against; more to the point, a stranger on the realm channel
dictating a gold outcome from a dungeon nobody can see is the unbounded version of exactly the
risk §1.2 refused. The segment renders disabled, with its reason, because "why can't I?" is the
question being asked at that moment.

### 3.4 One parley, one key

A parley covers exactly one keystone run and closes when it settles. The Pull Book's raid mode
is the opposite (one book, many pulls, an `attempt` per pull) and that is right for a raid,
where the bookie's audience is standing still for three hours. A key run is a discrete unit with
a start, an end and a result — and a bookie who wants to run the next key opens a new parley,
which re-invites the guild and lets the lines move. There is no `attemptSeq`; a settled market's
ledger id is `MP:<bookie>:<token>:<market>` and is unique by construction.

### 3.5 Declaring one dungeon and running another voids the WHOLE card

The card is posted for a named dungeon, and nothing stops the group from putting a different
key in. At lock the bookie compares `GetActiveChallengeMapID()` against what it declared and
sets a mismatch flag, which also travels: `LOCK` carries the map id that is actually starting,
so a client learns it even if the bookie's own screen is the only one that could have.

On a mismatch **every line voids and every stake comes back**, exactly as for an abandoned key.

This overrules the first draft, which voided only the boss-keyed lines and let `T` `X` `A` `M`
`F` settle on the reasoning that "did we time it" does not care which dungeon it was. It does.
**A card is priced against one dungeon** — its timer, its boss count, its difficulty — so a
deaths line of 6 is a different bet on a three-boss key than on a four-boss one, and a `Timed?`
line is a different bet against a 33-minute timer than a 35-minute one. Nobody who ticked
`UNDER 6 deaths` for Ara-Kara agreed to hold it through The Dawnbreaker.

The decisive half is the same one §3.1 rests on: **the partial rule left a lever.** A group that
can see the board could swap the key to void the lines it was losing while keeping the ones it
was winning. Voiding everything is the only outcome no participant can steer toward a payout.

Changing the dungeon in the picker likewise drops every boss-keyed tick, because those ids
belong to the dungeon that was selected when they were ticked. The settlement names **both**
dungeons — "the card was for Ara-Kara +12 but The Dawnbreaker was run" — because a void notice
with one name in it invites the reply "but we ran that".

---

## 4. The wire

Module code `MP`, `WIRE_VERSION` **unchanged at `4`**.

A version bump exists to stop two clients from producing **divergent ledgers for one game**
(`SCOPE.md` §3.4, and the v3→v4 note in `Comm.lua`). A 1.3.0 client at a 1.4.0 table has no
`MP` handler registered, so `Comm`'s router drops every `MP` message at the `moduleHandlers`
lookup: it never joins, never bets, never appears in anybody's bet map, and never writes a row.
It simply does not see the mode. Nobody is scored as a no-show and nobody pays for a message
they could not send. That is an *additive* protocol change, which is the one shape that does not
need a bump — and a bump would have cost every 1.3.0 user their Pull Book, Loot Goblins and Quiz
games for a mode they cannot use anyway.

| mtype | fields after `token` | sender | notes |
|---|---|---|---|
| `OPEN` | `stake`, `mapId`, `card`, `scopeCode` | bookie | `scopeCode` is checked against the delivered distribution, never trusted |
| `ROSTER` | `mapId`, `id~name,…` | bookie | boss names, so every board reads the same; re-sent every fourth heartbeat |
| `BET` | `lineIndex`, `pick`, `bookie` | any bettor | broadcast; `bookie` is the last field so identity is the pair (`CONCURRENCY.md` §4.5) |
| `HB` | — | bookie | liveness while bets are open |
| `LOCK` | `mapId`, `keyLevel` | bookie | bets close; the run is starting. `mapId` is what is ACTUALLY starting, not what was declared |
| `RES` | `outcome`, `t`, `d`, `w`, `s`, `fd`, `fw`, `wb`, `bd` | bookie | `outcome` is `C` (completed) or `A` (abandoned → all void) |
| `CLOSE` | — | bookie | the parley is off; anything unsettled voids |

`RES` fields: `t` timed `Y`/`N`, `d` deaths, `w` boss wipes, `s` seconds left (signed), `fd`
first-death role, `fw` first-wall boss id (`0` = nobody walled), `wb` worst-boss id, and `bd` the
per-boss block `id.attempts.deaths,…`. Any field may travel as `-` meaning "unreadable", which
voids the lines that needed it and nothing else. Worst case on the wire — a five-line card, a
six-boss `bd` — is comfortably inside the 250-byte budget.

### 4.0 The card, encoded

`T,X.6,L,P.2926.1,O.2900` — entries by comma, fields inside an entry by dot. How many fields an
entry has is **not encoded**: it is read out of `MARKET`, which both sides have in their own
source, so `X.6` is a line value and `O.2900` is a boss id without either needing a tag.

`decodeCard` is strict to the point of rudeness — one bad entry drops the whole `OPEN` — and it
has to be. **A `BET` names its line by index**, so two clients that disagreed about how many
entries the card holds would apply every bet after the disagreement to the wrong pool, silently,
and pay the wrong people. Refusing the parley outright is the only failure mode that cannot do
that. It also refuses two lines with the same `(type, boss)`: those would be two pools writing
one ledger id, and with different over/under values they would disagree about who won.

A `BET` is checked against the line it names: the pick has to be an option that line actually
offers, and for a boss-pick line that means **an id on this dungeon's roster** — which is what
stops a bet on a boss the card never listed.

`BOOKIE_AUTHORED = { HB, LOCK, RES, CLOSE }`; the inbound gate order is `CONCURRENCY.md` §5.2
verbatim, with the `PB` refinements: gate `g` resolves bookie-authored traffic on
`books[keyOf(sender, token)]` (so the sender **is** the record's bookie by construction) and
resolves `BET` against the involved record matched on the pair `(bookie, token)`.

### 4.1 Gate `j` for `BET`, per scope

A bet moves other people's money, so the sender has to be somebody who is allowed at this table.

- **group**: the sender must be in the current group snapshot. Same test as `PB`.
- **guild**: the `GUILD` distribution is server-vouched — only an actual guildmate can send on
  it — so the delivery *is* the proof and there is nothing further to check. This is
  `SCOPE.md`'s own reasoning for the guild router gate, applied one layer down.

A `BET` that arrives by whisper is impossible to authorise and is refused: `MP` has no 1:1
traffic whatsoever, so it registers a trust predicate that returns `false` unconditionally
(`PB`'s line, for a different reason — `PB` because every legal sender is already covered by the
group test, `MP` because it never sends or expects a whisper at all).

---

## 5. The lock, and why bets converge

This is the only genuinely new mechanism in the mode, and the only place where the raid Pull
Book's reasoning does not carry over.

**The problem.** In `PB`, every client freezes its bet map on `ENCOUNTER_ON` — a server event
that every client observes at the same instant. The freeze is synchronised for free. In `MP` at
guild scope, a bettor in Valdrakken observes **nothing** about the key starting. Their freeze
can only come from a message, and a message takes time. In the window between the bookie
freezing and a guildmate hearing about it, that guildmate can send a `BET` which some clients
accept and others reject. Different bet maps, different parimutuel splits, divergent ledgers —
the exact failure the whole architecture exists to prevent.

**The fix: LOCK plus a receive grace.**

- The bookie broadcasts `LOCK` at the lock moment.
- On **sending or receiving** `LOCK`, a client immediately stops **sending** `BET`.
- A client keeps **accepting** inbound `BET` for `LOCK_GRACE = 2` seconds after its own `LOCK`
  moment, and then stops.

**Why that converges.** Let `L` be the bookie's lock instant and `r(c)` the instant client `c`
receives `LOCK`. Addon-message delivery inside one distribution is sub-second in the ordinary
case; call the bound `δ`. Any `BET` that any client sends was sent before that sender's own
`r(·)`, hence before `L + δ`, hence it arrives at every client before `L + 2δ`. Every client
accepts until `r(c) + 2 ≥ L + 2`. So as long as `2δ < 2` seconds — three orders of magnitude of
headroom over a real send — **every client accepts exactly the same set of bets.** The grace is
symmetric and derived from a single broadcast, which is what makes it hold without a clock sync.

**Residual case, stated rather than hidden.** A client that never receives `LOCK` at all (it was
disconnected, or it was rate-limited out) keeps sending. Its late bets arrive at frozen clients
and are dropped, and it settles a market it thinks it backed. That client is also missing
heartbeats and will time out on its own; and it is the same residual case the raid Pull Book has
carried since 0.5.0. It is not fixed here and it is not pretended away.

### 5.1 What actually fires the lock

Whichever comes first:

1. `RESTRICT_ON` — `ADDON_RESTRICTION_STATE_CHANGED` fires **before** the restriction activates,
   which makes it the one trigger that is guaranteed to have a working wire underneath it. This
   is why the trigger exists and it is the primary one.
2. `CHALLENGE_MODE_START`.
3. The bookie pressing **Lock bets**.

**The lock is final; there is no unlock.** `RESTRICT_ON` also fires for a raid encounter and for
a PvP match, so a bookie who opened a parley and then pulled a raid boss has their table closed
early. That is deliberate and it is the safe direction: from that instant the bookie cannot
speak, cannot heartbeat, and cannot keep the table honest, so betting must stop. An unlock path
would have to be broadcast from inside a lockdown to be correct, which is the thing that cannot
be done. If the key never happens, the parley voids on the `LOCK_MAX` deadline (§6) and every
stake comes back.

---

## 6. Timers

| Constant | Value | What it is |
|---|---|---|
| `HB_SECS` | 15 | bookie heartbeat cadence while bets are open |
| `HB_MISS_SECS` | 50 | group-scope liveness deadline (the `PB` number) |
| `HB_MISS_WIDE` | 300 | guild-scope liveness deadline (the `RPS`/`DR`/`GB` number, `SCOPE.md` §6.2: outside the group our own safety state says nothing about the host's) |
| `LOCK_GRACE` | 2 | inbound-`BET` acceptance window after `LOCK` (§5) |
| `LOCK_MAX` | 5400 | a locked parley with no `RES` after 90 minutes voids and closes |
| `GONE_TICKS` | 6 (3 s) | consecutive empty `GetActiveChallengeMapID` probes before the run is declared abandoned. Not one tick: `CHALLENGE_MODE_COMPLETED` can land *after* the map id clears, and this branch **voids**, so a false positive refunds a key that really was run |
| `RES_RETRIES` | 0, 2, 6, 12, 25 s | `RES` resend schedule after completion, until one actually goes out |
| `LITE_TTL` | `HB_MISS_WIDE + 10` | how long an overheard parley stays offerable |

**The liveness deadline is suspended while locked.** A locked bookie is inside a lockdown by
definition and cannot heartbeat; a client that timed it out at 50 seconds would kill every
parley 50 seconds into every key. Party clients also suspend on their own `restricted` flag
(the `PB` rule, unchanged) — belt and braces, because either one alone covers the case.

`RES` is idempotent: a duplicate from an overlapping retry settles nothing twice, because the
record is gone by the time the second one lands and gate `g` drops it.

---

## 7. UI

The mode has **no bet strip.** The raid Pull Book's strip exists because its bet window is the
ten seconds of a pull timer, and a window you have to find in ten seconds has to come to you.
The parley's bet window is *minutes* — the walk to the instance portal — and a 152px overlay
sitting on the screen for six minutes is not a feature. The markets live in the parley's own
window, which behaves like every other window in the addon: draggable, scalable, Safety-hidden,
and closed when you are done with it.

### 7.1 The Pull Book submenu

Selecting **Pull Book** on the Games page no longer opens a dialog. It pushes a level-2 shell
page (`setup:PB`) with two tiles:

- **Raid Pull** → `PG.PB.OpenDialog()` — unchanged, byte for byte.
- **Mythic Parley** → `PG.MP.OpenDialog()`

The page is registered by `Launcher.lua` rather than by either game, because it is navigation
chrome that has to exist and explain itself even when one of the two game files failed to load —
which is the same reason the shell declares its own nav band instead of deriving it from
whatever registered.

The Games grid stays at six tiles. `MP` is not a seventh game on the home page; it is the Pull
Book's other mode, which is what was asked for and is also the honest description.

### 7.2 The parley window

520 wide, and **two heights**, which no other game in the suite needs. The two halves want
genuinely different rooms: the card builder is a scrolling list of up to twenty-three lines
(620px), and the betting board is at most five rows (`124 + 44n + 130`). A 620px window with two
market rows in it reads as broken, so the height follows the state.

The width is set by the widest thing the board can hold: a boss-pick row with six options, plus
a label column, plus a backer tally. The tally sits *under* the label rather than at the right
edge for that reason — a six-option block needs every pixel from x=174 to the margin. Option
blocks are right-aligned to a common edge whatever they hold, so rows of two and rows of six
still read as one column, and rows of four or more step down to the small font because a
ten-character boss name does not fit in 72px at display size. Boss buttons carry the short name
and the full one in the tooltip.

The decorative bookie is in `configWidgets` and is therefore **gone while a parley is live** —
the board spends its width on buttons and its height on rows, and decor yields to copy.

| State | What is on screen |
|---|---|
| **config** | stake, the dungeon picker (`<` name `>`), the audience picker, and **the card** — a scrolling checkbox list with an inline value box on every over/under line, headed `THE CARD  n / 5` |
| **open** | whose parley / stake / dungeon / audience, one row per card line with live backer tallies, **Lock bets** + **Cancel parley** (bookie only) |
| **locked** | the same rows, disabled, your own picks lit; "No more bets - the key is running" |
| **frozen** | the settled tally, ranked, `Close to dismiss.` — the `PLAN 5` frozen-result treatment, identical to the Pull Book's |

**There is no closing podium**, and the raid book having one is the reason to say so. A raid
book settles once per pull and closes hours later, so its per-pull report and its closing podium
are two different moments and both earn the results stage. A parley settles and closes in the
*same instant* (§3.4), so a podium could only ever be a second full-screen takeover landing on
top of the settlement report that just played — same four markets, same people, one second
apart. The ranked tally is not lost: it is exactly what the frozen panel shows, on a surface the
player dismisses in their own time rather than one that seizes the screen twice.

`MP` claims **no session seat** (`PG.MP.SEAT = false`): like the Pull Book it is passive betting
and must run alongside a Loot Goblins game, a Quiz, or anything else. `MythicParley.lua`
contains zero calls into the session layer, permanently — checkable with the escaped-dot form

```
grep -n 'PG\.Session\.' PengyouGames/Games/MythicParley.lua
```

which is the one pattern that does not match its own documentation.

---

### 7.3 Presentation

`SKIN.md` 2.11 is the surface spec. The short version: the window is skinned like every other
(`Theme.Skin` via `PG.UI.Window`, which also brings the FX registry and the A1 pop-in), the
results stage derives its violet accent from `payload.game` so nothing has to declare it, and
the **motion budget is one animation** — A2, the pop on the button you just locked a bet with.

The board can sit on screen for the entire walk to the portal. A surface that lives that long
earns restraint: it plays no sound on a bet click, which is a departure from the raid strip
only in *how* the silence is achieved. The strip is silent by construction (it exists only
during a ready check, where `Theme.Sound`'s gates mute everything); the board is silent by
discipline, because none of those gates are closed at a dungeon door.

## 8. Ledger

One `Ledger.Commit` per settled market, all-or-nothing, with provenance:

```
id     "MP:<bookie>:<token>:<cardIndex>"
game   "MP"
host   the bookie
scope  "group" | "guild"
played (my delta is non-nil)
cap    stake * (winners + losers)
vouch  the set of names in the bet map
label  "Mythic Parley: <dungeon> +<level>"
```

The id is keyed on the **card index**, not the market code. `MP:Name-Realm:1a-7f3:3` fits
Ledger's 96-byte id field even for a 64-character realm-qualified name; `…:P2926` would not.

A line with more than `MAX_ROWS_PER_SESSION` (40) backers **voids** rather than being refused at
commit time. At guild scope that ceiling is reachable in a way it never was for a five-person
party, and `Ledger.Commit`'s own refusal toast says "this game's numbers don't add up" — which is
untrue and alarming — while leaving the UI having shown a payout the ledger did not record.
Voiding says what happened and moves no gold. It is decided from the row count alone, so every
client reaches the same verdict from the same bet map.

`vouch` is the roster this client itself watched fill up, one server-vouched `BET` at a time —
which is precisely what `SCOPE.md` §4.4 asks the field to mean, and the same construction `GB`
uses. It is not required at guild scope (the guild cache is an independent source), but a cold
guild roster is a real thing and a refusal reading `"this game listed players this client can't
verify"` would look like a bug rather than a cache miss.

---

## 8b. Degraded clients

Every one of this mode's external dependencies can be absent, and none of them may stop it
working. What is lost in each case is stated on screen rather than inferred:

| Missing | What happens |
|---|---|
| The season list (fresh login, between rotations) | The dungeon shows *"No Mythic+ dungeons reported yet"*, the server is asked again, and **a parley still opens** with `mapId 0` — "no dungeon declared". The run-level lines settle normally; per-boss lines are not offered and the wrong-key void does not apply, because there is nothing to contradict. Refusing to open at all would be a worse answer to a transient server-data gap. |
| The Encounter Journal, entirely | The five run-level lines, and the card page says the bosses are unknown and what fixes it. |
| The tier walk only | Step 3 (by the map you are in) still resolves the dungeon at its own door. |
| `GetDeathCount` | `Deaths` and per-boss `deaths` lines void; everything else settles. |
| `GetCompletionInfo.onTime` | `Timed?` and `Time left` void; everything else settles. |
| A boss never fought | That boss's lines void; the others settle. |

---

## 9. Known limits

1. **A key that starts before the bookie ever locks.** Covered: `RESTRICT_ON` fires before
   activation, and `CHALLENGE_MODE_START` is the backstop behind it.
2. **The bookie disconnects mid-key.** No `RES` ever arrives; the parley voids at `LOCK_MAX`
   (90 minutes) and every stake comes back. There is no way to do better — nobody else can see
   the run.
3. **A bettor disconnects between `LOCK` and `RES`.** They come back with no record and settle
   nothing. Their stake is not taken and their name is simply absent from everyone else's
   parimutuel pools, because a client's own `BET` is only recorded from `onSent`.
3b. **A client with no roster refuses boss-pick bets.** It cannot check that the id names a boss
   the card listed, so it drops the `BET` rather than guessing — which means a client that
   somehow never received `ROSTER` would hold a different bet map from everyone else on those
   lines only. `ROSTER` is sent beside `OPEN` and again every minute, so this is narrow, but it
   is the one place the roster broadcast is load-bearing for correctness rather than for
   labels.
4. **Two parleys at once.** First one wins, exactly as the Pull Book: the second is remembered as
   a lite record and offered in the launcher's *Open games* list once this one ends.
5. **`practiceRun`.** A practice run (a key run with no eligible keystone) still completes and
   still settles. That is intentional: it is a real run with a real timer and real deaths.
6. **Per-boss deaths are differenced, not measured.** `GetDeathCount()` is a run total and there
   is no per-encounter API, so a boss's deaths are its end reading minus its start reading.
   Deaths that happen on trash *between* `ENCOUNTER_START` and `ENCOUNTER_END` cannot occur, but
   a missing reading at either end contributes nothing to that boss rather than contributing a
   guess. The run total (`X`) is read straight from the API and is unaffected.
7. **The journal's dungeon match is by name.** Both strings come from the same client in the
   same locale, so they agree — but a dungeon the journal names differently from the challenge
   map falls through to the learned-from-a-run path rather than resolving instantly.
