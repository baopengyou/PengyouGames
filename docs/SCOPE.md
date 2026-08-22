# SCOPE.md — Per-game audience selector

**Status: binding.** This is the implementation spec for the scope (audience) selector added to
every game's start dialog. Where it conflicts with intuition, taste, or an earlier doc, this
document wins. It assumes no knowledge of the research that produced it; every non-obvious
constraint is restated inline with its consequence.

Target: `PengyouGames` v0.6.0 on WoW 12.1 (`## Interface: 120007, 120100` — retail only).

Companion docs: `SPEC.md` (protocol + safety rules, still authoritative for everything not
restated here), `SKIN.md` (presentation), `REVEAL.md` (reveal stage).

---

## 0a. 1.1.0 delta (2026-08-12)

Three games were added after this document was written. The body below is **not** rewritten;
apply these deltas when reading it, in the style of `CONCURRENCY.md` section 0.3.

| Section | Delta |
|---|---|
| Sections 0 and 1.2, "not every game gets every scope" | **Extended, not changed.** Six games now: `LG` party+guild+public, `RPS` party+guild+public, `QZ` party+guild+public, `PB` party only, `DR` party only, `GB` party only. Each still declares `PG.<code>.SCOPES` in its own file and the picker still reads it. **The `DR`/`GB` half of this row is SUPERSEDED by section 0b - both are all three scopes now.** |
| Section 1.2's reasoning for `PB` being party-only | ~~**Applies verbatim, and harder, to `DR` and `GB`.**~~ **SUPERSEDED IN FULL by section 0b.** This row said guild and public were not merely unsupported for the two roll games but *impossible*, and told the reader to treat it as closed. It was wrong, and the premise it rested on was removed rather than argued with: the roll no longer travels as a system message at all. Section 1.2's reasoning still applies verbatim to `PB` alone. |
| Section 4.4's blanket `if meta.scope == "public" then return false end` | **Already superseded before 1.1.0** by the owner decision of 2026-08-12 recorded in 1.2 and implemented in `Ledger.lua`'s header: the blanket stop was replaced by gate **G1** (a client writes rows only for a session it joined and played). The four gates are what make public safe. 1.1.0 changes nothing here; the note exists because the code block above is still printed as a "hard rule" that the shipped persistence layer deliberately does not contain. |
| Section 4.4's premise that only `RPS` reaches the public channel without gold | **`QZ` is the second.** It is points-only and contains **zero calls** into the ledger, permanently - checkable with `grep -n 'PG\.Ledger\.' PengyouGames/Games/Quiz.lua`, the escaped form, so the check does not match its own documentation. Its persistence is a medal tally and a name-free counter in `db.qz`, and at non-group scope only the local player's own record is persisted (the `RPS` rule). |
| Section 2.3, all 1:1 traffic goes by whisper at every scope | **Unchanged and newly load-bearing.** `QZ` answers are typed into the addon window and whispered; nothing in it ever calls `SendChatMessage`. |
| The "nothing is visible to non-users" property | **Amended for `DR` and `GB` only.** The addon still prints nothing anywhere. Those two games ask the PLAYER to type `/roll` (or press a button that asks their own client to), and the resulting system line is visible to whoever is grouped with them, addon or not. ~~That is deliberate: it is the evidence every client re-derives the outcome from before committing a row.~~ **The trailing clause is superseded by 0b:** the system line is no longer evidence anybody else reads. It is visible because a real `/roll` is how the number is produced, and that is all. |

---

## 0b. Roll-rework delta (2026-08-13) - `DR` and `GB` open to guild and public

A two-player live test found that only one player's rolls ever registered. The host adjudicated
by watching `CHAT_MSG_SYSTEM` for **everyone's** `/roll` and resolving the printed name against
the frozen roster; a name printed without a realm is normalized onto the LOCAL realm, so the
lookup agreed for some pairs of players and missed for others, and a miss dropped the roll in
silence. From the dropped player's seat that is indistinguishable from "you cannot play".

**The model now:** every client observes only its OWN roll and reports it to the host over the
wire, as `ROLLED | seq | value | low | high` whispered to the host at every scope (`seq` is the
turn number in `DR`, the round number in `GB`). The host adjudicates from the report and
broadcasts the authoritative outcome exactly as before; its own roll is applied locally and
never whispered to itself (the section 6 loopback rule this codebase follows everywhere).

There is no name resolution left anywhere in the roll path. You always know your own name
(`PG.FullName("player")`), and the SENDER of an addon message is vouched by the delivery
distribution rather than parsed out of text.

**Consequences for this document:**

| Section | Delta |
|---|---|
| 0a rows 1 and 2, and section 1.2's table | `PG.DR.SCOPES` and `PG.GB.SCOPES` are `{ group = true, guild = true, public = true }`. Six games: `LG`, `RPS`, `QZ`, `DR`, `GB` all three; `PB` party only, and now genuinely the only exception. The audience restriction on the roll games rested entirely on the `/roll` system message being group-only, and nothing in the roll path reads a system message about anybody else any more. |
| 4.3, "PB registers a trust predicate that returns `false` unconditionally" | **Still true of `PB`, and no longer true of `DR` or `GB`.** Both now register the LG/RPS predicate verbatim (host, or already joined, or `S.isHost and S.phase == "join" and S.scope ~= "group"`). This is not optional dressing: the predicate is consulted only for whispers that fail the group test, so a blanket `false` at a wider scope drops every `JOIN`, every `ROLLED` report and every `SYNCQ` from outside the group, and the new scopes would be dead on arrival with no error anywhere. |
| 4.4, `meta.vouch` required at public | Both games pass it. `DR` passes `S.vouched`, accumulated from the `JOINED`/`LEFT` stream the client watched itself; `GB` builds one from its live roster at commit time. A missing `vouch` at public scope is refused by `Ledger.Commit` with reason `"vouch"`, which would look like a mystery at the table rather than like a bug. |
| 6.2, wide-scope heartbeats | Both games gained the RPS pair (`HB_QUIET_WIDE = 150`, `HB_GIVEUP_WIDE = 300`, one heal request per minute while quiet). At group scope the 35s rule is unchanged. Outside the group our own safety state says nothing about the host's, so a host in an encounter must read as PAUSED, not dead. |
| Group-scope facts inside the two games | `DR`'s absence scan (`hostScanGone`/`SHORT_TURN`) and both games' `PG.Peers` join-window count are GROUP facts and are now gated on `S.scope == "group"`. Outside the group every player is legitimately "not in my group" - unguarded, the absence scan would hand every seat a 4-second turn and the peer count would describe the wrong room. |
| The "no witnesses" objection in the superseded row above | Answered by deletion, not by argument. A client no longer re-derives anything and no longer refuses to commit when it disagrees; the host is trusted here exactly as it is in `LG`, `PB` and `RPS`. A client still toasts a mismatch for ITS OWN roll, as information only. Owner's ruling, 2026-08-13. |
| Non-addon players | **They can no longer take part in `DR` or `GB`.** There is nobody to report their roll, and no fallback that watches system messages for them - that is the machinery this change deleted. Stated on the Rules pages and in the README. |

---

## 0c. Mythic Parley delta (2026-08-21) - a seventh module, and the first Pull Book mode with a wide scope

`1.4.0` adds **`MP`, the Mythic Parley** (`docs/PARLEY.md`, binding) - the Pull Book's second
mode, in its own file with its own module code and its own registry. Selecting *Pull Book* on the
Games page now pushes a two-tile submenu (*Raid Pull* / *Mythic Parley*) instead of opening a
dialog; the Games grid stays at six tiles.

`PG.MP.SCOPES = { group = true, guild = true, public = false }`

| Section | Delta |
|---|---|
| 1.2's table, and 0a's extension of it | **Seven module codes now.** `LG` `RPS` `QZ` `DR` `GB` all three; `PB` party only; **`MP` party + guild**. `PB` is still the only game with a single segment. |
| 1.2's ruling that "The Pull Book is Party only" | **Unchanged for `PB`, and not extended to `MP`.** The reasoning ("the outcome is inseparable from the raid the bookie is physically standing in") is still exactly right about the raid book, and the raid book is still party-only. It does not carry to a keystone, and the difference is not a matter of degree: a key produces **one discrete machine-read result at one known moment** - `onTime`, a death count, a wipe count - where a raid book produces a running stream of encounter events with a new settlement every pull. There is one thing to report and one moment to report it, which is what makes a spectator audience coherent here and incoherent there. Owner decision, 2026-08-21; full argument in `PARLEY.md` 3.3. |
| 1.2's public segment | `MP` is **not** on Public, and this is the residual half of 1.2's original risk analysis surviving intact. At public scope `Ledger.Commit` demands a witnessed roster and there is no independent source to check a name against; a stranger on the realm channel dictating a gold outcome from a dungeon nobody can see is the unbounded version of exactly what 1.2 refused. The segment renders disabled with its own reason string. |
| 1.3's live-query rule, applied to a season | `MP`'s dungeon list is `C_ChallengeMode.GetMapTable()`, re-read on every repaint rather than cached, for 1.3's reason one level up: a season can roll over under a running client exactly as a group can dissolve under an open dialog. Nothing about the rotation is shipped data. |
| 2.3, all 1:1 traffic goes by whisper | **Unchanged and newly trivial.** `MP` has NO 1:1 traffic: every message it sends is a broadcast. Its boss names ride a broadcast `ROSTER` rather than being resolved per client, so one authority names the bosses and every board reads the same. |
| 3.4 / `WIRE_VERSION` | **No bump. Still `4`.** A bump exists to stop two clients producing divergent ledgers for ONE game. A 1.3.0 client has no `MP` handler registered, so `Comm`'s router drops every `MP` message at the `moduleHandlers` lookup: it never joins, never bets, never appears in a bet map and never writes a row. Nobody is scored as a no-show and nobody pays for a message they could not send - which is the failure the v3→v4 bump was made for. Additive module codes are the one protocol change that does not need a version. |
| 4.3, trust predicates | `MP` registers `function() return false end`, the `PB` line for a different reason. `PB` vouches for nobody because every legal sender is already covered by Comm's group test; `MP` because it has **no 1:1 traffic at all** - every message it sends is a broadcast, so a whisper claiming to be `MP` is by construction not ours. |
| 4.4, `meta.vouch` | `MP` passes one at every scope, built from the names in its own bet map - the roster this client itself watched fill up, one server-vouched `BET` at a time. It is not *required* at guild scope (the guild cache is an independent source) but a cold guild roster is real, and a `"vouch"` refusal would read as a bug rather than a cache miss. |
| 6.2, wide-scope heartbeats | `MP` uses `HB_MISS_SECS = 50` at group scope and `HB_MISS_WIDE = 300` at guild, for 0b's reason. It adds one rule those games have no need for: **while a parley is `locked`, the liveness deadline is suspended entirely.** A locked bookie is inside the M+ comms lockdown by definition and cannot heartbeat for the whole run; a client that timed it out at 50 seconds would kill every parley 50 seconds into every key. The bound while locked is `LOCK_MAX` (90 minutes), and it voids rather than settles. |
| Group-scope facts inside the game | `MP`'s gate `j` for `BET` is `inGroupNow(sender)` at group scope and **the delivery distribution itself** at guild scope - only an actual guildmate can send on `GUILD`, which is strictly stronger than a roster lookup against a cache that may be cold. Its self-lock on `RESTRICT_ON` is likewise gated on `scope == "group"`: outside the group our own restriction says nothing about the bookie's, and the lock is final, so an ungated one would let a guildmate who pulls a raid boss lock themselves out of a table that is still wide open. |
| 4.4's participation gate, at the edges | `MP` has two whole-card voids that write NOTHING to the ledger rather than writing a refund: an abandoned key, and a key that is not the one the card was posted for. Both are anti-manipulation rules rather than readability ones - the facts are perfectly readable in each case - and both are stated in `PARLEY.md` 3.1 and 3.5. |
| 6.3's five-row list | A `MP` row leaves the *Open games* list the moment its parley LOCKS, rather than at TTL: its bets are shut, so a Join would hand the player a table they can only watch. Any `PG.UI.Ask` it raised is dismissed at the same instant (`CONCURRENCY.md` 5.6 rule 4). |
| 6.3, the invite budget | Guild-scope `OPEN` never auto-adopts (I7 is a wide-scope rule and this is the first Pull Book mode that has a wide scope). It raises a `PG.UI.Ask` within `GuildAskOK`/`GuildAskSpend`, and over budget it falls back to the launcher's *Open games* row plus one throttled toast, exactly as `LG` and `RPS` do. Party-scope `OPEN` still adopts on hearing, for the Pull Book's reason: you are in the group that is about to run the key, and there is nothing to consent to until you click a pick. |

---

## 0d. Union-audience delta (2026-08-21) - `PB` opens to the guild, and a fourth scope exists

**The Pull Book is no longer party only.** It offers **Party**, **Guild** and **Party+Guild**,
because a guild half of which is spectating the raid in Discord is a real table and the old rule
shut it out. Owner decision, 2026-08-21.

Section 1.2's reasoning was not taste and could not simply be deleted. It said the book is
scored from the bookie's own `ENCOUNTER_END` and `UNIT_DIED`, so only the group in that fight can
observe the result - and it was *right*: a guildmate in Valdrakken never receives that event, so
they would not settle late, they would settle **nothing**, while the raid settled normally. One
book, two ledgers. **So the physics were changed rather than the rule.**

| Section | Delta |
|---|---|
| 1.1's "exactly three values. No other value is ever valid." | **Four now.** `both` (wire code `B`) is a SESSION scope and never a send scope. A message rides one distribution; a both-scope session therefore sends everything TWICE, on `PARTY` and on `GUILD`, and that is the sending MODULE's job rather than the queue's - only the module knows its two copies are one logical message and how to be idempotent about the duplicate. `Comm.lua` keeps `both` out of `SCOPES` (which `normalizeScope` and `resolveOut` read) and in `SESSION_SCOPES` (which the wire code and the picker read), so the separation is structural rather than a convention. |
| 3.1, "the declared code is CHECKED against the delivered distribution" | **Unchanged in substance, checked against a SET.** `PG.Comm.ScopeCarries(sessionScope, delivered)` is the one gate that knows `both` spans two, and a message on a third distribution is still refused - which is the property the check exists for. A both-scope record remembers the DECLARED scope, not the leg its `OPEN` happened to arrive on. |
| 1.2's `PB` row | `PG.PB.SCOPES = { group = true, guild = true, both = true, public = false }`. Public stays refused, with its own reason: the book pays out from one client's read of one pull, and a guild can check who called it where a stranger on the realm channel cannot. |
| 4.3 / `PB` settlement | **`PB` is now host-authoritative like `LG`, `RPS` and `MP`.** The bookie broadcasts `ENC` (success, boss HP %, encounter name) and EVERY client settles from that one message, party and guild alike. This is not new ground for the file: `FD` has been bookie-authored since 0.5.0, so all that changed is that `K` and `W` now agree with `D`. Two sources for one settlement is precisely what `PARLEY.md` 3.2 rejects. |
| 4.4's gate `j` for `PB` | Per leg. A `BET` on the group leg must still be in the group snapshot; a `BET` delivered on `GUILD` is vouched by the distribution itself, which is strictly stronger than a roster lookup against a cache that may be cold. |
| A new rule, and the only one the union audience needs | **At `both` scope a client that cannot reach the guild leg may not bet.** The check is local and certain - I know whether I can speak in guild chat - and it is what stops a bet landing on the party leg alone and leaving the guild settling a pool it never saw. The cost is stated on the Rules page: a pug who is not in your guild can watch a Party+Guild book and cannot bet in it. |
| 5.1's three-segment picker | Four segments, **opt-in**. `PG.UI.ScopePicker` reads a fourth order only when `cfg.allowed` carries a `both` key at all, because 1.3 says an unavailable scope renders greyed rather than hidden - and a fourth segment in the default order would put a permanently dead *Party+Guild* button in six other games' dialogs to serve one. Segments narrow from 68 to 58 and the label shortens to **Both** so the block still fits a 340px dialog. |
| 4.4's ledger provenance | `both` is a valid `meta.scope`. G2's independent sources are the union of the two legs' - the live group and the guild cache - which is strictly more than either alone. |
| The residual case | Both legs are checked live before a both-scope book opens and on every heartbeat (`ScopeAvailable("both")` requires both), so a book whose guild half dies closes rather than half-running. What is not covered: a single message whose first leg goes out and whose second is dropped. `onSent` fires on the first leg, so the sender records the bet; the far leg misses it. This is the same class as `PB`'s long-standing missed-`BET` limitation and is not fixed here. |

---

## 0. What is being built, in one paragraph

Each game's start dialog gains an **Audience** control with three segments — *Party*, *Guild*,
*Public*. The selection is stored on the session (`S.scope`), decides which chat distribution
every broadcast for that session goes out on, and is re-derived on receipt from the message's
own distribution argument so it cannot be lied about. Not every game gets every scope: **Loot
Goblins is Party + Guild**, **The Pull Book is Party only**, **Rock Paper Scissors is Party +
Guild + Public**. Unavailable segments stay visible and disabled with a reason, because "why
can't I?" is information the user wants. Widening the audience also widens the attack surface
on a ledger that tells real people to hand each other real gold, so this change ships together
with four ledger gates (§4.4) and per-session ledger provenance (§4.5). Those are not optional
extras; guild scope must not ship without them.

---

## 1. The scope model

### 1.1 Enum

Internal values are lowercase strings. There are exactly three. No other value is ever valid.

| Internal | Wire code | UI label | Audience |
|---|---|---|---|
| `"group"` | `P` | **Party** | Your party/raid, as today (RAID > INSTANCE_CHAT > PARTY) |
| `"guild"` | `G` | **Guild** | Every online guild member running the addon, cross-realm |
| `"public"` | `R` | **Public** | Your realm **and its connected realms**, **your faction only** |

A fourth value, `"private"`, exists **only** as a router output for `WHISPER` traffic (§4.1).
It is never a session scope, never appears in the UI, and is never stored in `S.scope`.

Constants live in `Comm.lua` next to `PREFIX`:

```lua
local SCOPES      = { group = "P", guild = "G", public = "R" }
local SCOPE_OF    = { P = "group", G = "guild", R = "public" }
```

`PG.Comm.ScopeCode(scope)` and `PG.Comm.ScopeOfCode(code)` are the only accessors; games never
hardcode a letter.

**"Public" is a deliberate lie of convenience, and must be told honestly in the tooltip.** A
custom chat channel reaches your realm plus its connected-realm group, same faction, all zones
and instances. It is *not* region-wide, *not* cross-faction, and *not* cross-realm in the
"player standing next to you in a cross-realm zone" sense. The segment is labelled **Public**
because that is what users search for; every tooltip and every in-session header spells out
"your realm and connected realms, your faction" (exact strings in §5.4). A player who invites a
friend on another realm to a Public game and watches them never appear will file a bug — the
label must pre-empt that.

### 1.2 Which game gets which scope, and why

| Game | Party | Guild | Public |
|---|---|---|---|
| **Loot Goblins** (`LG`) | yes | yes | **never** |
| **The Pull Book** (`PB`) | yes | **never** | **never** |
| **Rock Paper Scissors** (`RPS`) | yes | yes | yes |

Declared once, in each game file, and read by the picker:

```lua
PG.LG.SCOPES  = { group = true, guild = true,  public = true  }
PG.PB.SCOPES  = { group = true, guild = false, public = false }
PG.RPS.SCOPES = { group = true, guild = true,  public = true  }
```

**Loot Goblins IS available on Public — owner decision, 2026-08-12, overriding the original
draft of this section.** The reasoning that follows is retained because it correctly describes
the risk; what changed is the owner's judgement of how much that risk matters:

- The ledger is **advisory**. No gold moves automatically, settlement is manual, and any player
  may simply ignore a row. A fabricated debt is a claim, not a theft.
- Most public play is expected to be for fun, at trivial or zero buy-ins.
- Treating a social game as a financial instrument costs real usability (and code) to defend
  against an attack whose payoff is "a stranger asks you for gold and you say no".

The residual risk is real but bounded, and is contained by the ledger gates in §4.4 rather than
by forbidding the scope. The **participation gate is mandatory and load-bearing at public
scope**: a client writes ledger rows **only for a session it actually joined and played**.
A session merely overheard on the public channel never writes anything, so no stranger can
inject a debt row into the ledger of someone who never sat at the table. Combined with the
zero-sum, bound, and name-vouching gates, the worst outcome is that people you *chose* to play
with report a result you also witnessed.

The Public segment for Loot Goblins is **enabled**, with this advisory tooltip (shown on
hover, non-blocking):

> **Public — anyone on your realm.**
> Gold here is virtual and settling up is on the honour system, so a stranger who loses can
> simply log out. Fine for fun; keep buy-ins small with people you do not know.

**The Pull Book is Party only.** PB resolves bets from the bookie's own `ENCOUNTER_END` and
`UNIT_DIED` events — the outcome is inseparable from the raid the bookie is physically standing
in. A guildmate in Valdrakken cannot observe, verify, or contest the result; the bookie would
be unilaterally dictating gold outcomes to two hundred people. Both wider segments render
disabled with:

> **The Pull Book follows your own pull.**
> The book is scored from the boss fight you are standing in, so only your group can see the
> same result you do.

**Rock Paper Scissors gets everything.** Zero gold, points only, medals persisted locally. The
worst outcome of a hostile public session is ninety wasted seconds and a bogus medal in your own
SavedVariables. RPS is the *only* game permitted on the public channel, and §4.4 encodes that as
a hard rule in the persistence layer rather than as a convention, so a future game cannot
regress it by omission.

### 1.3 When a scope is unavailable

Availability is a live query, never a cached one:

```lua
-- Comm.lua. Returns ok, reasonString. reason is user-facing, shown in the tooltip.
-- graceSecs (optional, default 0) tolerates a brief public-channel gap across a
-- loading screen; only the host-abort watchdog passes it (§6.1).
function PG.Comm.ScopeAvailable(scope, graceSecs) end
```

| Scope | Available when | Reason string when not |
|---|---|---|
| `group` | `IsInGroup()` | `"You're not in a party or raid."` |
| `guild` | `IsInGuild()` and not rank-muted (§2.4) | `"You're not in a guild."` / `"Your guild rank can't speak in guild chat."` |
| `public` | opt-in on **and** `GetChannelName(PUBLIC_CHANNEL) > 0` **and** not `publicBroken` | see below |

Public failure reasons, in priority order:

1. opt-in off → `"Turn on 'Join the public games channel' in Settings first."`
2. `publicBroken` (a send returned `InvalidChatType`) → `"This client can't use custom channels."`
3. index is 0 after a join attempt → `"You're in 10 chat channels already. Leave one to use Public."`
4. index is 0 and no attempt has completed → `"Still joining the public channel — try again in a moment."`

Behaviour rules, all mandatory:

- **The segment is never hidden.** An unavailable scope renders greyed, unclickable, with the
  reason as its tooltip. Hiding it produces "where did Guild go?" tickets; greying it answers
  the question without one.
- **Availability is re-checked on every dialog `OnShow`** and again **at the moment Start is
  pressed**. The player can `/gquit`, leave the group, or hit the channel cap between opening
  the dialog and clicking Start. On a Start-time failure: do not open, do not fall back to
  another scope, toast the reason string, and re-run `picker:Refresh()` so the dialog now shows
  reality.
- **If the persisted last-used scope is unavailable at `OnShow`**, the picker selects the first
  available scope in the fixed order `group → guild → public` and shows a one-line hint under
  the control: `"<Label> isn't available right now — using <Label>."` The persisted preference
  is **not** overwritten by this fallback; only an explicit user click writes it.
- **If no scope is available at all**, every segment is disabled and the Start button is
  disabled with the tooltip `"Nowhere to start a game: you're not in a group or a guild."`
  (`PG.LG.OpenDialog` / `PG.RPS.OpenDialog` / `PG.PB.OpenDialog` currently refuse to even open
  the dialog when `not IsInGroup()` — that early-return is **removed**; the dialog always opens
  and the control explains itself.)

---

## 2. Transport mapping

### 2.1 The mapping

| Scope | `chatType` | `target` |
|---|---|---|
| `group` | `RAID` if `IsInRaid()`, else `INSTANCE_CHAT` if `IsInGroup(LE_PARTY_CATEGORY_INSTANCE)`, else `PARTY` | `nil` |
| `guild` | `GUILD` | `nil` |
| `public` | `CHANNEL` | **numeric channel index**, resolved at send time |
| *(1:1)* | `WHISPER` | `"Name-Realm"` |

`CHANNEL` is retail-only as an addon-message chat type (it is disabled on Classic). The addon is
retail-only today, so this is not a live constraint — but `Comm.lua` must treat a send result of
`Enum.SendAddonMessageResult.InvalidChatType` (fallback literal `4`) as a **permanent capability
failure**: set `publicBroken = true`, drop the entry through the normal `dropEntry` path, and
never retry. It is not a throttle and it will not heal.

### 2.2 `Comm.lua` changes

**Late resolution is mandatory.** A queued message can sit in the FIFO through a channel rejoin
(indices shift) or a party→raid conversion. Resolve `chatType`/`target` inside `rawSend`, from
`entry.scope`, never at `submit()` time.

```lua
-- replaces pickChannel() at Comm.lua:151
local function resolveOut(entry)
  if entry.chatType == "WHISPER" then return "WHISPER", entry.target end
  local s = entry.scope
  if s == "guild" then
    if not IsInGuild() then return nil end
    return "GUILD", nil
  elseif s == "public" then
    local idx = PG.Comm.PublicIndex()          -- GetChannelName(PUBLIC_CHANNEL), 0 -> nil
    if not idx then return nil end
    return "CHANNEL", idx
  end
  if IsInRaid() then return "RAID", nil end
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT", nil end
  if IsInGroup() then return "PARTY", nil end
  return nil
end

-- replaces rawSend() at Comm.lua:64. Returns nil when the audience vanished:
-- the entry is ALREADY dropped (onDrop fired) and pump must not call onSent.
local function rawSend(entry)
  local chatType, target = resolveOut(entry)
  if not chatType then
    dropEntry(entry, "no audience")
    return nil
  end
  local result = C_ChatInfo.SendAddonMessage(PREFIX, entry.msg, chatType, target)
  debugLine("sent [" .. (entry.scope or "whisper") .. "/" .. chatType
    .. (target and (":" .. tostring(target)) or "") .. "] " .. entry.msg)
  if type(result) ~= "number" then return 0 end
  return result
end
```

`pump` gains one branch: `local result = rawSend(entry); if result == nil then -- already
dropped, continue` before the throttle/lockdown tests. The `onDrop` contract is unchanged and
must stay unchanged — LG and RPS treat a dropped `OPEN`/`BEGIN`/`END` as fatal and abort the
session, and a vanished audience is exactly as fatal as a lockdown drop.

Public API after the change:

```lua
PG.Comm.Broadcast(scope, module, mtype, token, ...)          -- scope leads, like Whisper(target,...)
PG.Comm.BroadcastEx(opts, module, mtype, token, ...)         -- opts.scope, opts.onSent
PG.Comm.Whisper(target, module, mtype, token, ...)           -- UNCHANGED signature
PG.Comm.ScopeAvailable(scope [, graceSecs]) -> ok, reason
PG.Comm.RegisterTrust(module, fn(sender) -> boolean)         -- §4.3
PG.Comm.PublicIndex() -> number|nil
PG.Comm.PublicJoin() / PG.Comm.PublicLeave()
```

`BroadcastEx` keeps its pre-check: it returns `false` immediately when the scope's audience does
not exist, which is the same abort path callers already handle for "not grouped". Call sites:
`Core.lua:244` (`CO HELLO` — always `"group"`), `LootGoblins.lua:123` and `:714`,
`RockPaperScissors.lua:133` and `:666`, `PullBook.lua:691`, `:858`, `:869`, plus the two
`BroadcastEx` sites `LootGoblins.lua:548` and `RockPaperScissors.lua:496` and PB's `:555`/`:727`.
The per-game `broadcast()` helpers (`LootGoblins.lua:122`, `RockPaperScissors.lua:132`) funnel
most of them; each becomes one line:

```lua
local function broadcast(mtype, ...) return PG.Comm.Broadcast(S.scope, "LG", mtype, S.token, ...) end
```

### 2.3 Private 1:1 traffic always uses WHISPER — in every scope

**Rule, no exceptions.** `JOIN`, `UNJOIN`, `PICK`, `SYNCQ`, `SYNCOK`, `SYNCNO`, every resync
replay (`JOINED`/`LEFT`/`BEGIN`/`RESULT`/`VOID`/`ROUND`), and the `CO HELLO` reply go out as
`WHISPER` to `"Name-Realm"` regardless of `S.scope`. `PG.Comm.Whisper`'s signature does not
change and none of its 14 call sites is edited.

Two reasons, both load-bearing:

1. **`PICK` is a secret.** Loot Goblins' entire game is the hidden SHARE/HOARD choice. A pick
   broadcast on `GUILD` or on a public channel is readable by every other addon client in the
   audience, which does not merely leak information — it destroys the game.
2. **Replays are point-to-point by design.** A resync replay re-sends up to 20 messages to *one*
   client. Broadcasting them would re-apply state to everyone and burn the shared 10-token
   bucket for the whole audience.

Cross-realm addon whispers to `"Name-Realm"` work on 12.1 — no workaround, no BNet fallback, no
special-casing. Send the plain whisper.

### 2.4 The guild-rank send bug

There is an open Blizzard bug: **a guild rank that cannot speak in guild chat also cannot SEND
on the `GUILD` addon distribution.** Receiving is unaffected. A freshly-invited initiate can
therefore hear every guild game and start none, and `SendAddonMessage` gives no reliable signal.

Handling, in two layers:

1. **Pre-emptive, existence-guarded.** In `ScopeAvailable("guild")`:
   ```lua
   if C_GuildInfo and C_GuildInfo.CanSpeakInGuildChat
      and C_GuildInfo.CanSpeakInGuildChat() == false then
     return false, "Your guild rank can't speak in guild chat."
   end
   ```
   Wrapped in the same existence guard style as the rest of the codebase. If the API is absent
   on a build, fall through and allow the attempt.
2. **Diagnostic on the natural failure.** A muted host's `OPEN` reaches nobody, nobody joins,
   and the session cancels at join-close with "not enough players joined". For
   `S.scope == "guild"` that cancel message becomes:

   > `Nobody joined. If your guild rank can't speak in guild chat, guild games can't be started from this character.`

   This is `applyCancel("few")` in both LG (`LootGoblins.lua:376`) and RPS, branching on
   `S.scope`. No new API, no probe, no guesswork.

### 2.5 The public channel

```lua
local PUBLIC_CHANNEL  = "PengyouGamesRealm"   -- channel names may not contain "-"
local PUBLIC_PASSWORD = "pgv1"
```

**Join with `JoinTemporaryChannel`, never `JoinPermanentChannel`/`JoinChannelByName`.** A
permanent join is written into the user's saved channel list and is re-joined after every
relog — *including after the addon is uninstalled*. That is the etiquette failure that gets
addons blacklisted. `JoinTemporaryChannel(PUBLIC_CHANNEL, PUBLIC_PASSWORD)` is dropped at logout
and never touches the user's config.

**Always join with the password.** The first player to join a channel that does not exist creates
it and owns it; ownership auto-transfers to a random long-standing member when the owner leaves;
owners can `/ban`, `/mute` and `/password` at will. Joining with a fixed password means a squatter
who created the channel without one cannot later lock us out cheaply, and casual `/join`-ers are
excluded. The password is not a secret and is not pretending to be one.

**Join timing.** Never lazily "when a public game starts": you can only *receive* an `OPEN` if
you were already in the channel when it was sent. Join at login, gated on the opt-in setting:

```
PLAYER_ENTERING_WORLD  ->  if profile.publicOptIn then scheduleJoin() end
```

`scheduleJoin()` waits for the default zone channels to settle before joining. At login the
General/Trade/LocalDefense channels trickle in over several seconds; joining early grabs a low
`/N` slot and pushes every one of the user's channels up a number. Readiness test: scan
`C_ChatInfo.GetChannelShortcut(i)` for `i = 1, MAX_WOW_CHAT_CHANNELS` and refuse to join while
there is a gap (an empty slot below a filled one); force the join anyway after **10 seconds**.
Do **not** attempt to swap our channel to the last slot afterwards — the swap APIs reorder the
user's own channels as a side effect and are a known source of complaints.

**Index resolution.** The `target` argument is the numeric `/N` index, never the name.

```lua
function PG.Comm.PublicIndex()
  local id = GetChannelName(PUBLIC_CHANNEL)   -- returns 0, not nil, when not joined
  if type(id) ~= "number" or id == 0 then return nil end
  return id
end
```

Re-resolve on **every send** (§2.2). Never cache the index in a variable, a session field, or a
queue entry. Indices shift whenever the player joins or leaves any channel, and Trade is joined
and left every time they enter or leave a city.

**Keep it out of the user's chat windows.** Joining is not silent. Three separate suppressions,
all required, all re-run on `PLAYER_ENTERING_WORLD` and on our own `YOU_JOINED` notice:

```lua
local function hideChannel()
  for i = 1, NUM_CHAT_WINDOWS do
    local f = _G["ChatFrame" .. i]
    if f then pcall(ChatFrame_RemoveChannel, f, PUBLIC_CHANNEL) end
  end
end
```

1. `hideChannel()` — removes the channel from every chat frame's message list.
2. Five `ChatFrame_AddMessageEventFilter` registrations, each returning `true` (suppress) only
   when the message concerns `PUBLIC_CHANNEL`: `CHAT_MSG_CHANNEL_JOIN`,
   `CHAT_MSG_CHANNEL_LEAVE`, `CHAT_MSG_CHANNEL_NOTICE`, `CHAT_MSG_CHANNEL_NOTICE_USER`,
   `CHAT_MSG_CHANNEL_LIST`. Without these the user sees a join/leave line for every addon user
   on their realm.
3. Password popup suppression across the join:
   ```lua
   local saved = StaticPopupDialogs["CHAT_CHANNEL_PASSWORD"]
   StaticPopupDialogs["CHAT_CHANNEL_PASSWORD"] = nil
   JoinTemporaryChannel(PUBLIC_CHANNEL, PUBLIC_PASSWORD)
   PG.After(1, function() StaticPopupDialogs["CHAT_CHANNEL_PASSWORD"] = saved end)
   ```

What cannot be hidden, and must be stated in the Settings tooltip: the channel still appears in
the Chat Channels config pane and still consumes one of the user's **ten** channel slots. The
addon *messages* themselves never render in anyone's chat window, including for players without
the addon.

**Failure and hostile-owner handling.** Register `CHAT_MSG_CHANNEL_NOTICE` (in addition to the
display filter) and branch on the notice type for our channel:

| Notice | Action |
|---|---|
| `YOU_JOINED` | `hideChannel()`, clear backoff, `PG.Settings.Refresh()` |
| `YOU_LEFT` | mark unavailable; a `PLAYER_ENTERING_WORLD` rejoin will heal it |
| `WRONG_PASSWORD` | back off **300s**, then retry **without** the password (an owner may have cleared it), then with it again |
| `BANNED` | back off **300s**; mark unavailable; abort any live public session (§6.1) |

Never hammer a join. At the 10-channel cap the join simply fails and `GetChannelName` stays `0` —
there is no distinct return code to trust, so "index still 0 after an attempt completed" *is* the
failure signal.

---

## 3. Wire changes

### 3.1 Scope travels in `OPEN`, and the distribution is the authority

`OPEN` gains **one trailing field**: the scope code (`P`/`G`/`R`). It is the last field of the
message, for every game, including the Pull Book (which always sends `P`).

On receipt the router independently derives the scope from the message's own distribution
argument (§4.1). The two are compared:

```lua
-- in each game's OPEN branch
local declared = PG.Comm.ScopeOfCode(PG.SafeStr(fN))
if not declared then return end                 -- malformed / missing: drop
if declared ~= scope then return end            -- declared != delivered: hostile or broken, drop
if scope == "private" then return end           -- an OPEN must never arrive by whisper
if not PG.LG.SCOPES[scope] then return end      -- this game does not do this scope
```

The derived value is the one that gets stored in `S.scope`; the declared field exists to be
*checked*, not trusted. This is deliberate: a wire field can claim `guild` on a `PARTY` message,
a distribution cannot. Cost of the check is one string compare; benefit is that a client which
somehow ends up in both audiences cannot be steered into treating a party message as a guild
session, and every later scope-consistency test (§4.2) has a trustworthy anchor.

`S.scope` is **immutable for the life of the session** on both host and client. A session that
started in a party does not silently become a guild session when the host leaves the group; it
aborts (§6.1).

### 3.2 Exact field additions

Only `OPEN` changes. No other message type gains, loses or moves a field.

| Game | New `OPEN` layout | Handler arg |
|---|---|---|
| `LG` | `3｜LG｜OPEN｜token｜buyin｜rounds｜joinSecs｜scope` | `f4` |
| `RPS` | `3｜RPS｜OPEN｜token｜rounds｜joinSecs｜roundSecs｜scope` | `f4` |
| `PB` | `3｜PB｜OPEN｜token｜stake｜line｜scope` | `f3` |

`LootGoblins.lua:887` `onComm(mtype, token, sender, f1..f5)` becomes
`onComm(mtype, token, sender, scope, f1..f5)`; likewise `RockPaperScissors.lua:826` (`f1..f4`),
`PullBook.lua:982` (`f1..f2` → add `f3`), and `Core.lua:247` (`onCoMessage(mtype, token, sender,
scope, ver)`). The dispatch at `Comm.lua:242` becomes
`pcall(handler, mtype, token, sender, scope, unpack(parts, 5))` — `unpack(parts, 5)` is
**unchanged**, because scope occupies no wire slot in the header.

### 3.3 Byte budget

Guard is `MAX_BYTES = 250` in `submit()`; the spec target is ≤200 bytes. Worst case per field:
token ≤ 18 bytes (12-char name + `-` + 5 digits), buyin/stake ≤ 6 digits, rounds ≤ 2, seconds
≤ 3, scope 1, separators 1 each.

| Message | Before | After | Headroom to 200 |
|---|---|---|---|
| `LG OPEN` | `3｜LG｜OPEN｜Xxxxxxxxxxxx-99999｜100000｜20｜600` = 42 | **44** | 156 |
| `RPS OPEN` | 40 | **42** | 158 |
| `PB OPEN` | 38 | **40** | 160 |
| `LG RESULT` (40-name pattern, largest message in the protocol) | 98 | **98** (unchanged) | 102 |
| `LG JOINED` (33-byte `Name-Realm`) | 64 | **64** (unchanged) | 136 |

Total cost of the whole scope feature on the wire: **+2 bytes, on one message type, once per
session.** The no-chunking rule is untouched — nothing approaches the limit, and nothing new is
ever split.

Note for guild and public scope: `Name-Realm` strings get longer once peers are cross-realm
(connected-realm names run to ~20 characters). `LG JOINED` at 64 bytes has 136 bytes of
headroom; there is no realistic name that threatens the guard. No change needed, but do not
"optimise" names off the wire — positional roster agreement depends on them.

### 3.4 `WIRE_VERSION` must bump: `"2"` → `"3"`

**Yes, mandatory.** Not because of the two extra bytes — a trailing field is ignored by a v2
client's handler — but because **the trust and ledger rules change**. A v0.5.0 (`WIRE_VERSION
"2"`) client that is both in your group and in your guild would receive a guild-scope `OPEN`,
mirror the session under v2 rules, and at `END` write ledger rows with none of the §4.4 gates:
no participation gate, no name vouching, no zero-sum check, no provenance. It would hold ledger
rows that every v3 participant in the same game deliberately refused to write.

Divergent ledgers among participants of the same game destroy the only property that gives Settle
Up its authority — that everybody's copy says the same thing. Mixed-version play is therefore not
acceptable at any scope, including plain party games.

The existing gate at `Comm.lua:230` already handles this politely: mismatched versions are
ignored with a single chat line ("a raid member may run a newer addon"). Update that string to
name the addon version so the fix is obvious:

> `PengyouGames: ignoring messages from a different protocol version — everyone needs 0.6.0 or later to play together.`

Consequence to state in the release notes: **0.6.0 cannot play with 0.5.x.** The addon is
pre-1.0; this is the right moment to take that cost.

---

## 4. Inbound trust and ledger protection

### 4.1 Deriving scope from the distribution argument

`Comm.lua:220` currently discards the distribution (`local function onChatMsgAddon(_, prefix,
message, _, sender)` — the 4th parameter is `_`). It stops being discarded.

```lua
local function onChatMsgAddon(_, prefix, message, dist, sender, _, _, _, chanName)
```

`dist` and `chanName` go through `PG.SafeStr` first, exactly like `prefix` and `message`.

| `dist` | Derived scope |
|---|---|
| `RAID`, `RAID_LEADER`, `PARTY`, `PARTY_LEADER`, `INSTANCE_CHAT`, `INSTANCE_CHAT_LEADER` | `"group"` |
| `GUILD`, `OFFICER` | `"guild"` |
| `CHANNEL` **and** `chanName` case-insensitively equals `PUBLIC_CHANNEL` | `"public"` |
| `CHANNEL` on any other channel | **drop** |
| `WHISPER` | `"private"` |
| anything else (`SAY`, `YELL`, `BATTLEGROUND`, …) | **drop** |

### 4.2 The accept predicate

The current `isGroupSender` gate at `Comm.lua:214` is the addon's only anti-forgery mechanism.
It becomes per-scope. Message parsing moves *before* the accept test (the module name is needed
for the trust predicate); parsing is cheap and the rate limiter runs first regardless.

New order inside `onChatMsgAddon`:

1. prefix/message secret + type guards (unchanged, `Comm.lua:221-222`)
2. `PG.NormalizeSender`; drop self-delivery (unchanged, `:227`)
3. **ignore list** — `C_FriendList.IsIgnored` (existence-guarded; try `Name-Realm` then the short
   name). Ignored → drop. There is currently no ignore check anywhere in the addon and it is the
   user's only remedy against a guild or public nuisance.
4. **inbound rate limiting** (new): per-sender bucket cap **12**, refill **2/s**; global bucket
   cap **60**, refill **20/s**. Over budget → drop silently. The server throttle is per-sender,
   so N senders scale linearly; two hundred guildmates or an unbounded public channel can
   otherwise drive `applyJoined` → `RefreshUI` → FX once per message, during raid content.
5. derive scope (§4.1); unknown → drop
6. `strsplit`, `WIRE_VERSION` check, `module`/`mtype`/`token` presence
7. **accept test** (below)
8. dispatch

```lua
local function accept(sender, scope, module)
  if scope == "group"  then return isGroupSender(sender) end
  if scope == "guild"  then return guildScopeOn() end
  if scope == "public" then return publicScopeOn() end
  -- private (WHISPER): no distribution proof exists at all
  if isGroupSender(sender) then return true end
  return trustFn(module, sender)
end
```

Rationale per branch:

- **group** — unchanged. `groupNames` rebuilt on `GROUP_ROSTER_UPDATE` with a lazy rebuild on a
  miss.
- **guild** — **no roster lookup is performed, and none is needed.** The `GUILD` distribution is
  server-vouched: only an actual member of your guild can send on it. A `GetGuildRosterInfo`
  check would add nothing against forgery, would fail against a cold roster cache in the first
  seconds after login, and would silently eat legitimate `OPEN`s. The only gate is the user's own
  `profile.scopeIn.guild` preference. (A guild roster cache *is* still built — but for ledger
  name-vouching in §4.4, not for routing.)
- **public** — **there is no authentication of any kind.** Anyone on the realm can send anything.
  The only router-level gate is "the user opted in and it arrived on our channel". Public is
  therefore backstopped entirely at the session layer: a public `OPEN` never constructs session
  state without an explicit user click (§6.3), and no public session may ever write gold (§4.4).
- **private** — a whisper carries no audience proof whatsoever. Today `isGroupSender` covers it
  because every legitimate whisperer is in the group by construction. In a guild or public
  session the whisperer is provably *not* in the group, so that gate would kill `JOIN`, `PICK`
  and `SYNCQ`. It is replaced by a module-registered predicate, consulted **only** for whispers
  that fail the group test.

### 4.3 The trust predicate

```lua
PG.Comm.RegisterTrust(module, fn(sender) -> boolean)
```

Registered alongside `PG.Comm.Register`. Coarse by design: it decides whether the message reaches
the handler; the handler still validates the token, the phase and the sender exactly as it does
today (`LootGoblins.lua:915`, `RockPaperScissors.lua:855`, `PullBook.lua:1025`).

Identical implementation in LG and RPS:

```lua
PG.Comm.RegisterTrust("LG", function(sender)
  if not S or S.phase == "done" then return false end
  if sender == S.host then return true end            -- host replies/replays
  if S.joined[sender] then return true end            -- a seated player
  -- host side, wide scope, join window open: the first JOIN from a new player is
  -- by definition from someone we have no prior relationship with. That is the
  -- point of a wider audience. Rate limiting (§4.2 step 4) bounds the abuse.
  if S.isHost and S.phase == "join" and S.scope ~= "group" then return true end
  return false
end)
```

PB registers a trust predicate that returns `false` unconditionally — PB is group-only, so its
whisper traffic is always covered by `isGroupSender`.

### 4.4 Which scopes may write `PG.Ledger` — and the four gates

**Hard rule, enforced in the persistence layer, not in the games:**

```lua
-- Ledger.lua, first line of the commit path
if meta.scope == "public" then return false end
```

No public session writes gold. Ever. Today no game even offers public + gold; this line exists so
that a future game which adds a public scope cannot regress it by forgetting.

| Scope | May write `PG.Ledger` |
|---|---|
| `group` | yes |
| `guild` | yes, with all four gates below |
| `public` | **never** |

The four gates apply at **every** scope, not just guild. Each is cheap and each closes a hole
that already exists today.

**G1 — Participation.** Write only if the local player actually played:

```lua
-- LootGoblins.lua:350, replacing `if not S.spectator then`
local me = myName()
if not S.spectator and S.joinAccepted and me and S.joined[me] then
```

Today every addon client mirrors the session and writes the ledger whether or not it bought in —
`LootGoblins.lua:776-777` says so explicitly, and pressing *Pass* suppresses nothing. That turns
every listener into a corroborating witness for a fabricated debt: the attacker's "open your own
Settle Up tab" is convincing precisely because forty uninvolved clients silently transcribed a
game they declined. Decliners and passers-by keep their UI mirror and write **nothing** to
SavedVariables. This is two lines and it removes most of the fabrication's reach at every scope.

**G2 — Name vouching.** Every ledger-bound name must be one the client can independently vouch
for, and must be realm-qualified (contain `-`):

- `group` — the name was in `groupNames` at `BEGIN` time (snapshot it into `S.vouched` in
  `applyBegin`; the roster is frozen after `BEGIN` anyway).
- `guild` — the name is in the guild roster cache (built from `GetNumGuildMembers()` /
  `GetGuildRosterInfo(i)` through `PG.NormalizeSender`, refreshed on `GUILD_ROSTER_UPDATE`, with
  a `C_GuildInfo.GuildRoster()` request throttled to once per 10s and one at login) **or** in
  `groupNames`.

A host can otherwise put any forty strings on the wire — `applyJoined` validates only
non-secret and non-empty (`LootGoblins.lua:929-931`) — and every listener persists a debt for
forty characters who were never online.

**G3 — Zero-sum and bound.** Before any write, in `applyEnd`:

```lua
local sum, cap = 0, S.buyin * #S.roster
for _, name in ipairs(S.roster) do
  local d = (S.totals[name] or 0) - S.buyin
  if math.abs(d) > cap then return refuse("payouts don't add up") end
  sum = sum + d
end
if sum ~= 0 then return refuse("payouts don't add up") end
```

Clients never recompute the parimutuel math — `applyResult` accumulates the host's own
`hoardPay`/`sharePay` verbatim (`LootGoblins.lua:274-281`), bounded only by `MAX_GOLD` = 4,000,000.
A modified host can send `hoardPay = 4000000` for twenty rounds, or (the dangerous version) skew
payouts by 500g a round in a way nobody audits, because no client has the information to
disagree. The same check subsumes the dust-index hole at `LootGoblins.lua:344-347`, where
`dustAmt` is validated only to `[0, MAX_GOLD]` and is never tied to the carry the clients
themselves tracked.

**Refusal is all-or-nothing for the whole session**, never per-row: a partial write is not
zero-sum and produces exactly the phantom debt the check exists to prevent. On refusal, toast:

> `Loot Goblins: this game's numbers don't add up — nothing was recorded.`

**G4 — Provenance.** See §4.5.

RPS medals get the analogous treatment: `persistMedals` runs only under G1, and for
`S.scope ~= "group"` it persists **only the local player's** medal. A stranger's medal count is
not local-hall-of-fame material.

### 4.5 Ledger provenance (required before guild scope ships)

`PG.Ledger.Add` persists only `name -> delta` bucketed by calendar date; `reason` is explicitly
not persisted (`Ledger.lua:11-13`). `Settlement()` then nets the whole day together and emits
"YOU pay X 4,300g". A single injected row does not look like a suspicious standalone entry — it
silently changes the amount and the counterparty of an otherwise legitimate settle-up from real
games played the same night, and the victim's only remedy (`ClearTonight`) destroys the real
games too. This is the highest-value change in the entire document and it is worth shipping even
if scope never widens.

New persisted shape:

```lua
PG.db.ledger = {
  ver = 2,
  sessions = {                       -- [YYYY-MM-DD] = ARRAY of session entries
    ["2026-08-12"] = {
      { id    = "LG:Grizzle-48120",  -- module ":" token, unique per session
        game  = "LG",
        host  = "Grizzle-Illidan",
        scope = "group",
        at    = 1786000000,          -- time()
        rows  = { ["Name-Realm"] = -100, ... },
        dismissed = nil },
    },
  },
  lifetime = { ["Name-Realm"] = net },
}
```

API:

```lua
PG.Ledger.Commit(meta, rows) -> ok      -- meta = { id, game, host, scope, at }; the ONLY writer
PG.Ledger.Sessions()                    -- today's non-dismissed entries, newest first
PG.Ledger.Dismiss(id)                   -- unwinds this entry from lifetime, marks it dismissed
PG.Ledger.Tonight()                     -- unchanged return shape; sums non-dismissed entries
PG.Ledger.Settlement()                  -- unchanged
PG.Ledger.ClearTonight()                -- unchanged semantics
```

`PG.Ledger.Add` is **removed**. LG commits once per session at `END`; PB commits once per market
settlement with `id = "PB:" .. book.token .. ":" .. attemptSeq .. ":" .. market`
(`PullBook.lua:409-412` becomes one `Commit` per market instead of a loop of `Add`s).

**Migration.** On init, if `ledger.ver` is absent, convert each `sessions[day]` that is a
`name -> number` map into a single entry `{ id = "legacy:" .. day, game = "?", host = "?",
scope = "group", at = 0, rows = <old table> }`, then set `ver = 2`. `lifetime` is untouched.
Anything that fails to match that shape is discarded, not guessed at.

**Ledger window changes.** The *Tonight* tab groups rows by session with a header line
`"<game> · <host> · <scope> · <HH:MM>"` and a small `[x]` dismiss button per session. Settle Up is
unchanged except that its rows are now derived from non-dismissed entries. Sessions whose scope
is `guild` carry a one-word `Guild` tag in the header, because "who was this game with" is the
first question a disputed row raises.

---

## 5. UI specification

### 5.1 The control

It is a **segmented control**, not a Blizzard dropdown. Three reasons, and this is not
re-litigable:

1. Three options fit; a dropdown adds a click to see them.
2. Two of the three segments are usually disabled, and **the disabled state is the message**
   ("you cannot play Loot Goblins with strangers, here's why"). A dropdown hides that until the
   user opens it.
3. The codebase has no dropdown primitive, and `UIDropDownMenu` is deprecated on 12.x while the
   modern Menu API drags in taint and template dependencies for zero benefit at n=3.

The word "dropdown" may still be used in user-facing copy and release notes.

### 5.2 Widget contract

New primitive in `Widgets.lua`, next to `PG.UI.Button`:

```lua
-- Segmented audience picker. Renders a label row and three fixed-order segments
-- (Party, Guild, Public). Exactly one segment is selected at any time.
--   cfg.key      "LG" | "RPS" | "PB"   -- persistence key
--   cfg.allowed  { group=, guild=, public= }  -- per-game support (§1.2)
--   cfg.reasons  optional fn(scope) -> string, game-specific disabled tooltip
--   cfg.onChange optional fn(scope)
-- Returns a frame with:
--   :Get()      -> scope, or nil when nothing is selectable
--   :Set(scope) -> selects if allowed and available; else no-op
--   :Refresh()  -> re-queries availability, repaints, re-selects if needed
function PG.UI.ScopePicker(parent, cfg) end
```

Behaviour:

- Segments are **fixed order, fixed labels**: `Party`, `Guild`, `Public`. Order never varies by
  game or availability; muscle memory beats compactness.
- A segment is enabled iff `cfg.allowed[scope]` **and** `PG.Comm.ScopeAvailable(scope)`.
- Clicking an enabled segment selects it, writes `PG.db.profile.scope[cfg.key] = scope`
  immediately (so closing the dialog without starting still remembers), and calls `onChange`.
- Disabled segments swallow clicks and show their reason on hover. Reason priority:
  `cfg.reasons(scope)` (game policy, §1.2) first, then `ScopeAvailable`'s reason (§1.3).
- `:Refresh()` is called from the dialog's `OnShow` and from a `GROUP_ROSTER_UPDATE` /
  `PLAYER_GUILD_UPDATE` hook while the dialog is shown.
- Selected segment: `UIPanelButtonTemplate` with `:Disable()` (the existing idiom used by the
  ledger tabs at `Ledger.lua:171-172` — the selected one is the disabled-looking one) plus the
  theme's selected tint. Unselectable-for-policy segments additionally get `|cff808080` label
  text so "selected" and "forbidden" never look alike.

Geometry: label FontString `"Audience"` at `(20, y)`; three 82×22 segments at `y - 20`, 4px
gutters, right-aligned to `-20`. Total block height 44px.

### 5.3 Placement per dialog

| Dialog | Window size | Picker label `y` | Segments `y` | Notes |
|---|---|---|---|---|
| `lgdialog` (`LootGoblins.lua:1866`) | 320×270 → **320×320** | `-182` | `-202` | Below Round timer (`-150`); Open buy-in stays `BOTTOM, 0, 18` |
| `rpsdialog` (`RockPaperScissors.lua:1633`) | 320×240 → **320×290** | `-170` | `-190` | Below Round timer (`-138`); Start stays `BOTTOM, 0, 18` |
| `pullbook` (`PullBook.lua:890`) | 340×300 → **340×340** | `-200` | `-220` | Below Wipe line (`-168`). All three segments render; Guild and Public are permanently disabled. The picker joins `configWidgets` so it hides while the book is open. |

The Pull Book's picker is not decoration. It is the answer to "why can't I run a book for the
guild", delivered at the exact moment the question is asked.

### 5.4 Exact strings

Segment labels: `Party`, `Guild`, `Public`.

Enabled tooltips:

| Segment | Tooltip |
|---|---|
| Party | `Party / Raid — everyone in your group who runs the addon.` |
| Guild | `Guild — every guildmate online right now who runs the addon, on any realm in your guild.` |
| Public | `Public — your realm and its connected realms, your faction only.`<br>`Not cross-faction. Not other realms.` |

Disabled tooltips: the game-policy strings in §1.2 and the availability strings in §1.3, in that
priority order.

Live-session header: each game window shows the audience under the title —
`Party` / `Guild` / `Public — realm-wide`. For `S.scope == "guild"` the Loot Goblins window adds
one amber line under the pot:

> `Guild game — settle up with people you can find again.`

### 5.5 Persistence

```lua
profile.scope = { LG = "group", RPS = "group", PB = "group" }   -- DB_DEFAULTS, Core.lua:82
```

Read at `OnShow`, validated against `cfg.allowed` and live availability, fallback per §1.3.
Written on explicit user click only. A value that is not one of the three enum strings is treated
as absent.

### 5.6 Settings additions

Two checkboxes in a new **"Games from outside your group"** section in `Settings.lua`, below the
existing four:

| `y` | Label | Source | Default |
|---|---|---|---|
| `-164` | `Guild games: show me invites` | `profile.scopeIn.guild` | **on** |
| `-194` | `Public games: join the public channel` | `profile.publicOptIn` | **off** |

Section note beneath, in BRASS:

> `Public uses a hidden chat channel. It takes one of your ten channel slots and shows up in the Chat Channels list — nothing is ever printed to your chat windows.`

Toggling `publicOptIn` on calls `PG.Comm.PublicJoin()` immediately; off calls
`PG.Comm.PublicLeave()` and aborts any live public session. Turning `scopeIn.guild` off makes
guild-scope `OPEN`s drop at the router (§4.2) — no popup, no mirror, no state.

Window grows 320×360 → **320×420**; slider moves `-190` → `-250`, reset button `-256` → `-316`.

Both checkboxes register `syncers` entries like every other checkbox so `PG.Settings.Refresh()`
keeps them honest.

### 5.7 Slash commands

`/pg comm` (`Core.lua:293`) gains a line:

```
scope: group=<ok> guild=<ok> public=<ok|reason>  publicIndex=<n|none>
```

---

## 6. Lifecycle

### 6.1 Scope-aware host abort

`LootGoblins.lua:1077` and `RockPaperScissors.lua:1006` currently abort the session when the host
is `not IsInGroup()`. That test becomes scope-aware:

```lua
-- onTick, host branch
local ok, why = PG.Comm.ScopeAvailable(S.scope, 8)   -- 8s grace, see below
if not ok then
  toast("Loot Goblins: " .. why .. " Game abandoned, no gold changes.")
  endSession("Abandoned — " .. why .. " No gold changes.")
  return
end
```

| Scope | Aborts when |
|---|---|
| `group` | left the party/raid (unchanged) |
| `guild` | `/gquit`, gkick, or guild disband mid-session |
| `public` | channel index has been 0 continuously for **8 seconds** (grace absorbs loading screens), or a `BANNED` notice for our channel arrives (immediate, no grace) |

The 8-second grace is essential: a temporary channel is dropped across every loading screen and
re-joined on `PLAYER_ENTERING_WORLD`, so a zero-grace check would abort every public session the
first time the host takes a portal.

**The all-or-nothing ledger contract is unchanged.** An abort before `END` is submitted leaves
every ledger untouched. Once `END` has actually left the wire its `onSent` has already fired and
committed, which is correct — the audience heard it.

**A cross-scope hijack is impossible by construction.** After the token check
(`LootGoblins.lua:901`) add:

```lua
if scope ~= "private" and scope ~= S.scope then return end
```

`"private"` is exempt because resync replays of `BEGIN`/`RESULT`/`ROUND` legitimately arrive by
whisper. This one line is what stops someone re-broadcasting a live guild session's token in
party chat, and it is the only place the previously-discarded distribution argument does real
security work.

### 6.2 Watchdog when host and clients are in different content

This is the genuinely new failure mode created by widening, and it must be handled explicitly.

Today's client watchdog (`LootGoblins.lua:1109-1119`) suspends itself when **the client** is in
an encounter or a comms lockdown. In a party game that is sufficient, because host and client are
in the same content by definition. In a guild or public game the **host** can be pulling a boss
while the client stands in Valdrakken: the host physically cannot send (the 12.1 comms lockdown
refuses sends during an encounter, an entire M+ run, or an entire PvP match), the client's own
safety state is clear, and after 35 seconds of silence the client declares the host dead and
abandons a game that is merely paused.

Rules for `S.scope ~= "group"`:

```lua
local HB_TIMEOUT       = 35    -- group, unchanged
local HB_QUIET_WIDE    = 150   -- wide scope: host is quiet, not dead
local HB_GIVEUP_WIDE   = 300   -- wide scope: now they're dead
```

- At **150s** of host silence: set `S.hostQuiet = true`, repaint the window with
  `Waiting for the host — they may be in a boss fight.`, and fire `clientRequestSync()` (at most
  once per 60s) so the mirror heals the instant the host returns. **No state change, no
  spectator flip, no ledger effect.**
- At **300s**: `clientHostDead()` exactly as today.
- Any host traffic clears `hostQuiet` (`S.lastHB` is already refreshed by any host message,
  `LootGoblins.lua:916`).

The host side needs no change: its heartbeat and round timing are already lockdown-gated, so it
simply resumes and the clients resync. Note that a wide session is naturally bounded anyway
(≤20 rounds × ≤60s), so a 300s give-up cannot strand anyone for long.

### 6.3 Discovery

| Scope | How a client learns about a game |
|---|---|
| `group` | `PG.UI.Ask` invite popup, as today. Unchanged. |
| `guild` | `PG.UI.Ask` invite popup, **only** if `profile.scopeIn.guild`, not DND, and within the invite budget below. Over budget → falls through to the launcher list. |
| `public` | **Never a popup.** The entry lands in the launcher's *Open games* list and constructs no session state. |

**Guild invite budget:** at most 1 popup per sender per 60s and at most 3 popups per 5 minutes
in total. Two hundred guildmates with no budget is a denial-of-service on the user's screen, and
their only recourse today would be disabling the addon.

**Launcher *Open games* list** (`Launcher.lua`): a section below the DND button, hidden when
empty, holding at most **5** entries, each with a 60s TTL, deduped per sender, ignore-list
filtered. Row text: `"<short host> · <game> · <Guild|Public>"` with a `Join` button. The launcher
window height becomes `322 + 22 * n` when shown. `PG.Launcher.AddOpenGame{ game=, host=, token=,
scope=, expires= }` is called from each game's `OPEN` handler for wide-scope opens the user did
not get a popup for.

**Public sessions construct `S` only on an explicit `Join` click.** No state, no mirror, no
window until the user acts. On click: build `S` (via `clientOpen`), whisper `JOIN`, then
immediately `clientRequestSync()` — the existing resync protocol replays the `JOINED` stream and
`BEGIN`, so a late constructor converges on the host's roster with no new machinery.

**Wide-scope mirrors are released at `BEGIN` if the local player did not join.** For
`S.scope ~= "group"`, a client that reaches `applyBegin` and finds itself absent from
`S.roster` tears down `S` entirely (`endSession` with no text, window never shown). It has no
reason to track two hundred guildmates' game to completion, and releasing it frees the client to
receive the next `OPEN`. Group scope keeps today's behaviour: passers-by keep watching, because
in a raid that is a feature.

### 6.4 Session collision

One live session per module per client remains the rule — `live()` is unchanged.

**Priority ladder: `group` > `guild` > `public`.** A higher-priority `OPEN` may **not** preempt a
live session; live state is never destroyed by an inbound message. Priority governs only what
happens to the loser:

| Situation | Behaviour |
|---|---|
| `OPEN` (group) arrives while any session is live | Today's toast: `"<sender> tried to start a game, but one is already running."` |
| `OPEN` (guild) arrives while any session is live | Dropped **silently**, no toast. A toast per guild open is spam. |
| `OPEN` (public) arrives while any session is live | Never constructs state anyway; it enters the *Open games* list. Clicking `Join` while a session is live is refused with a toast. |
| Two public `OPEN`s arrive concurrently | Both appear in the list. They are independent sessions on independent hosts; the user picks one. This is normal and needs no arbitration. |
| Two guild `OPEN`s race | First to arrive wins; the second is dropped silently and listed. |

There is deliberately **no global "one public game per realm" arbitration.** Any such scheme
requires a coordinator that a chat channel cannot provide, and the failure mode (two games, both
work) is strictly better than the failure mode of a broken election (nobody plays).

---

## 7. Build order

Each step is independently shippable and independently testable. Do not reorder: steps 1–3 are
prerequisites for guild scope being *safe*, and step 5 is prerequisite for public existing at all.

### Step 1 — Comm scope plumbing (group + guild only)

`resolveOut`/`rawSend` late resolution, `Broadcast(scope, ...)`, `BroadcastEx` `opts.scope`,
`ScopeAvailable`, `S.scope` threaded through `hostOpen`/`clientOpen`/the `broadcast()` helpers in
LG and RPS. No public, no UI — scope is hardcoded to `"group"` at the call sites.

**Milestone:** with `/pg debug` on, every send prints `sent [group/RAID]`. Flipping the hardcoded
constant to `"guild"` and reloading, two accounts in the same guild but **not** in the same group
complete an RPS game end to end.

### Step 2 — Router, trust, rate limits, `WIRE_VERSION "3"`

Distribution → scope derivation, `accept()`, `RegisterTrust`, ignore list, inbound token buckets,
handler signature change in all four modules, the `OPEN` scope field and its declared-vs-derived
check, the scope-consistency check after the token test.

**Milestone:** a `JOIN` whisper from a non-group guildmate reaches the handler and seats the
player. A crafted `SAY`-distribution message is dropped. A 0.5.0 client produces exactly one
version-mismatch chat line and nothing else. Re-broadcasting a live guild session's token on
`PARTY` changes nothing.

### Step 3 — Ledger hardening and provenance

G1–G4, `PG.Ledger.Commit`, the `ver = 2` shape and its migration, the grouped Tonight tab with
per-session dismiss. (The former blanket public hard-stop inside `Ledger.lua` is REPLACED by the
participation gate of §1.2/§4.4: rows are written only for a session this client joined and
played, at every scope.)

**Milestone:** a hand-crafted `END` with a non-zero-sum payout writes no rows and toasts the
refusal. A player who presses *Pass* finishes the game with an empty Tonight tab. A pre-upgrade
SavedVariables file loads, shows its old rows under a `legacy` session, and settles identically.

### Step 4 — `PG.UI.ScopePicker` and dialog integration

Widget, three dialog placements, persistence, availability refresh, Settings section, the removal
of the `not IsInGroup()` early-returns in the three `OpenDialog` functions.

**Milestone:** all three dialogs render the control with correct enable states while solo, in a
party, in a guild, and in both. Loot Goblins' Public segment is greyed with the gold warning. The
Pull Book's Guild and Public segments are greyed. Selection survives `/reload`.

### Step 5 — Public channel transport (RPS only)

`JoinTemporaryChannel` with settle-detection, the three-part chat suppression, index resolution,
`CHAT_MSG_CHANNEL_NOTICE` handling and backoff, `InvalidChatType` → `publicBroken`, the launcher
*Open games* list, click-to-construct.

**Milestone:** two accounts on connected realms, in no common group and no common guild, complete
an RPS game. Neither player's chat window prints a single line about the channel. `/pg comm`
reports a non-zero `publicIndex`. Leaving the channel mid-game aborts the host's session after 8
seconds and no sooner.

### Step 6 — Lifecycle

Scope-aware host abort with grace, `HB_QUIET_WIDE`/`HB_GIVEUP_WIDE`, wide-scope mirror release at
`BEGIN`, guild invite budget, collision rules, the guild-rank diagnostic on `applyCancel("few")`.

**Milestone:** the host of a guild game `/gquit`s mid-round and every client ends cleanly with no
ledger. A host who pulls a raid boss and stays in the encounter for two minutes is *not* declared
dead; the game resumes and resyncs. A guildmate who declines a guild game holds no `S` after
`BEGIN`.

---

## 8. Out of scope for v1

Explicitly not built, not designed around, and not to be added during implementation:

1. **Cross-faction play.** A custom channel is same-faction. No Cross-RP-style bridge.
2. **Cross-realm beyond connected realms.** Public reaches your realm's connected-realm group and
   stops there.
3. **Battle.net / community channels / `BNSendGameData`** as transports. Banned by `SPEC.md` §2.11.
4. **The Pull Book on Guild or Public.** §1.2 is policy, not a default to be relaxed by a
   setting. (Loot Goblins on Public was moved IN scope by owner decision on 2026-08-12 — see
   §1.2; the participation gate in §4.4 is what makes it safe enough.)
5. **Changing a session's scope after it starts.** `S.scope` is immutable; the session aborts
   rather than migrate.
6. **More than one live session per module per client.**
7. **Channel ownership recovery, moderation, or squatter eviction** beyond the fixed password and
   the 300s backoff. If a hostile owner bans us, public is unavailable and the UI says so.
8. **A lobby, matchmaking, browsing, or a persistent list of realm games.** The *Open games* list
   is a 5-entry, 60-second, in-memory convenience and nothing more.
9. **Reputation, blacklists, or host scoring for public hosts.** The WoW ignore list is the only
   remedy and it is honoured.
10. **Guild rank / officer-note based host permissions.** Any guildmate who can speak in guild
    chat can host a guild game.
11. **Classic support for public scope.** `CHANNEL` is disabled as an addon-message chat type on
    Classic. If a Classic `.toc` ever ships, the Public segment compiles out; `publicBroken` is
    the runtime backstop.
12. **Relaying or bridging between scopes** (e.g. a guild session mirrored into party chat).
13. **Localization of the new strings.** They go through `PG.L` like everything else and stay
    English in v1.
14. **Automatic guild-rank detection beyond the one existence-guarded probe** in §2.4.
