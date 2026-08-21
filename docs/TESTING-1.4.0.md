# Live test checklist - PengyouGames 1.4.0 (the Mythic Parley)

One new module ships in 1.4.0: **`MP`, the Mythic Parley** (`docs/PARLEY.md`), reached
through a submenu on the Pull Book tile. The raid Pull Book (`PB`) is **unchanged - not one
line** - and needs no retest.

Everything a machine can check has been checked and is re-runnable:

```
./tools/parley/run.sh          # needs luajit; 113 assertions
```

That harness loads the real module against a stubbed client and drives it through its own wire
handler. It covers the settlement arithmetic (zero-sum, dust to the byte-first winner, strict
OVER), the card codec's refusals (too many lines, unknown type, duplicate line, out-of-range
value, missing boss id, trailing junk), the inbound gates (replay poisoning, cross-bookie `BET`
contamination, a pick the line does not offer, a boss id not on the roster, an out-of-range line
index), every void rule, the ledger contract (`cap`, `vouch`, the 96-byte id and 48-byte label
limits, the 40-row ceiling), the `LOCK_GRACE` convergence claim (two independent loads receiving
`LOCK` 0.4s apart commit byte-identical ledgers), and the bookie's whole path from ticking a card
through `ENCOUNTER_START`/`END` to the `RES` it emits.

**Its central scenario runs the route in the wrong order on purpose**: the group opens on the
journal's *third* boss, wipes there twice, and clears the other two in one pull each. Every
per-boss expectation only comes out right if the module keys on `dungeonEncounterID`, so a
regression to positional "boss 1 / boss 2" keying fails a test rather than a raid night.

Everything below is what only a live 12.1 client can answer.

---

## 0. The assumptions this mode rests on

All four fail SAFE - they void a line and return stakes, or quietly stop offering it, rather
than paying the wrong person - but confirm them first, because every check after this assumes
they hold. **Start with 0.4: it is one command and it answers two of the four.**

**0.1 Is addon chat really dead for the whole key, and does it come back?**

```
/pg comm
```

Run it standing at the font of power, again ten seconds into the key, and again the moment
the timer stops.

- Before: `Locked=false`
- During: `Locked=true` for the **entire** run, trash included
- After: `Locked=false`

If `Locked` is ever `false` mid-key, nothing breaks - the mode simply does not need the
window it was handed. If it is still `true` after the key ends, `RES` will retry at 0, 2, 6,
12 and 25 seconds and then on every ticker pass; if it never clears, the parley voids at
`LOCK_MAX` (90 minutes) and every stake comes back. Report the timing either way.

**0.2 Does `ADDON_RESTRICTION_STATE_CHANGED` really fire BEFORE the key activates?**

This is the one that matters most: it is the only lock trigger with a guaranteed working
wire underneath it. Open a parley, have someone else in the group watch their chat, and
start the key.

- The other player should see the parley lock (their market buttons grey out) **at the same
  moment** you do, not seconds later.
- If they do not, `CHALLENGE_MODE_START` is the backstop and the `LOCK` it sends will be
  refused by the lockdown - which is exactly the case `LOCK_GRACE` and the party client's
  own `RESTRICT_ON` self-lock exist to cover. Betting still closes; it just closes silently
  on the guild side.

Force it without a key using the CVar from the project's API notes:
`addonChatRestrictionsForced`.

**0.3 Does `C_ChallengeMode.GetCompletionInfo()` have `onTime` populated at
`CHALLENGE_MODE_COMPLETED`?**

The module re-reads it on every `RES` attempt precisely because it may lag the event by a
frame or two. If `onTime` is still nil at the last retry, the **Timed?** line voids and says so.
Watch for a settlement that reads "void, stakes returned" on a key you definitely timed - that
is this, and it is the whole bug report.

**0.4 Does the client know the season, and the bosses? One command.**

```
/pg keys
```

This is the whole of 0.1 and 0.4 in one place, and it is the first thing to run:

```
PengyouGames keys: lockdown=false  activeKey=nil  slotted=391
PengyouGames keys: 8 dungeon(s) this season
PengyouGames keys:   Ara-Kara, City of Echoes - 3 bosses, Encounter Journal
PengyouGames keys:   The Dawnbreaker - bosses UNKNOWN, per-boss lines not offered
...
PengyouGames keys: 7/8 resolved. An unknown dungeon learns its bosses the first time you run it.
```

- **`0 dungeon(s) this season`** right after login is expected for a few seconds; run it again.
  If it never fills, the parley still works with the five run-level lines and says so.
- **Any `UNKNOWN` line** is the bug report, and it needs the dungeon name exactly as printed.
  Those dungeons offer run-level lines only until you run them once.
- **Walk to an unknown dungeon's entrance and run `/pg keys` again.** It should flip to
  `Encounter Journal (this map)` - that is chain step 3, which does not depend on the tier walk
  that step 4 does. If step 4 is broken on your client but step 3 works, per-boss lines are
  available wherever it matters and the report is "cosmetic, at the door only".
- Run an unknown one and check again: it should read `learned from a run`.

---

## 1. Party scope, five people, one key

1. All five on 1.4.0. One player: **Games -> Pull Book -> Mythic Parley -> Open parley**,
   audience **Party**.
2. Everyone else should get a toast and the window should show *`<name>`'s parley*.
   **They should NOT get a popup** - at party scope hearing it is the invitation.
3. Everyone clicks picks. Check:
   - the first click per line locks and the rest of that row greys out
   - the tally under each label counts up on every client
   - the row labels show the values (`Deaths 6`, `Avanoxx attempts 1`)
   - **boss buttons show boss NAMES on every client**, not "waiting for boss names". If one
     client sits on that for more than a second or two its `ROSTER` never arrived - a real bug,
     and the line stays unclickable for them.
   - hovering a boss button shows the full name in a tooltip
4. Put the key in. Every window's markets should grey out and the note should read
   *"No more bets - the key is running."*
5. Run it. Nothing should appear on screen mid-key.
6. On completion: one results-stage takeover with the per-market outcomes and your own
   delta, then the window shows **The parley is settled** with the ranked tally and
   *Close to dismiss*.
7. `/pg ledger` -> Tonight. Compare all five screens. **They must match exactly.** A
   mismatch here is the one failure worth stopping for.

## 2. Guild scope - the point of the mode

1. Bookie opens with audience **Guild**.
2. A guildmate **not in the group and not in the dungeon** should get a popup
   (*"...opened a Mythic Parley - 100g a bet on their key. Bet on it?"*) and a row in the
   Games page's *Open games* list.
3. Decline on one guildmate; the row should stay, and Join from the row should work.
4. That guildmate bets, then **pulls a raid boss of their own** while the key has not
   started. Their parley must **stay open** - their own restriction says nothing about the
   bookie's. (This is the scope-gated self-lock; at party scope the opposite is true.)
5. Have a second guildmate open a parley of their own. The first bookie's players should
   see it as an *Open games* row and **not** a popup interrupting the live table.
6. Run the key. The guild bettors see nothing until it ends, then settle from the bookie's
   `RES`. Compare their ledgers against the party's.

## 2b. The card

1. Tick five lines and try a sixth: the checkbox should un-tick itself and toast
   *"A card holds 5 lines. Untick one first."*
2. Change the dungeon with `<` / `>` after ticking per-boss lines: **the boss lines should
   un-tick** (their ids belong to the dungeon you left) and the run-level ones should stay.
3. Open with a card of one line, and again with five. The board window should be visibly
   shorter for one line - it sizes to the card.
4. Post a card for one dungeon and deliberately run a **different** one. **Every line must
   void** with *"a different key was run"* - the run-level ones included - and the closing line
   must name both dungeons. `/pg ledger` should show no rows at all for that parley.
5. Run a key where you wipe on a **later** boss first (open on the last boss, or skip one).
   **First wall** must name the boss you actually walled on. This is the failure mode that
   motivated the whole per-boss redesign.

## 3. The things that should NOT happen

- **A locked parley must not time out.** Leave the group waiting at the entrance with the
  key in for 5+ minutes before pulling. Nobody's parley should close.
- **Abandon a key deliberately** (reset the dungeon, or all leave). Every market must void
  and every stake come back. `/pg ledger` should show **no rows at all** for that parley.
- **Public must be refused.** The audience picker's Public segment is greyed with a reason.
- **The Pull Book must be untouched.** Run a normal raid book on the same night: strip at
  ready check, three markets, settles from the pull. It should be identical to 1.3.0.
- **A 1.3.0 client at the table** should simply not see the parley: no error, no popup, no
  ledger row, and their Loot Goblins / Pull Book / Quiz games must still work with you.

## 4. Cosmetic checks

- The Pull Book tile pushes a two-tile submenu; **Back** and right-click both return to the
  grid.
- The Rules tab strip is now three rows of tabs and the scroll area starts below them - no
  tab overlapping the text.
- The parley window: the card list scrolls, nothing overlaps, and the goblin bookie is visible
  on the setup form and gone once a parley is live.
- A four-boss dungeon's **First wall** row fits inside the window with its tally still readable
  under the label.
- `/pg parley` and `/pg mp` both open it.
