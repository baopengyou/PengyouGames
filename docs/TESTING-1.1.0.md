# Live test checklist - PengyouGames 1.1.0

Three new games ship in 1.1.0: **Death Roll** and **Gambler** (real `/roll`, real gold,
party/raid only) and **Quiz** (four ported chat-game modes, points only, all audiences).

Everything below is a check a live WoW client can make and static analysis cannot. The
code has been through four adversarial review passes and an executable exploit harness;
what remains is whether the client behaves the way the API documentation says it does.

---

## 0. Before anything else: the three unverifiable assumptions

These are the only places where 1.1.0 depends on behaviour nobody has confirmed on a live
12.1 client. All three fail SAFE, but confirm them first because everything else assumes
they hold.

**0.1 Does the roll parser work on your locale?**

```
/pg rolls
```
Expect `patternSelfTest=PASSED`. The parser is built from your client's own
`RANDOM_ROLL_RESULT` string and self-tests at login against a synthetic line.

- `PASSED` - good, continue.
- `FAILED` - Death Roll and Gambler will refuse to start rather than open a table that can
  never resolve. The command prints the raw locale format string; capture that line, it is
  the whole bug report.

**0.2 Can the addon roll for you?**

Same command, `canRollForYou=true/false`.

- `true` - the ROLL button calls `RandomRoll` for you.
- `false` - the button is replaced by "Type /roll 1000 in chat." The game is fully playable
  either way; this only decides whether there is one click or one typed command.

This is the assumption most likely to be wrong: 12.0 restricted a lot of addon-initiated
action and `RandomRoll`'s status was not verifiable from documentation. If it is `false`,
that is not a bug, it is the fallback working.

**0.3 Does a `/roll` you make actually reach the addon?**

Start a Death Roll with one other person, take your turn, and confirm the roll registers
in the window rather than sitting on "waiting for your roll". If `/pg rolls` says PASSED
but rolls never register, that is the interesting failure - report it with `/pg debug` on.

---

## 1. Smoke test (solo, 2 minutes)

| Step | Expect |
|---|---|
| `/pg` | Launcher opens. **Six** game buttons in two columns, plus Ledger / Rules / Settings / DND |
| `/pg rules` | Six tabs. Read the Death Roll, Gambler and Quiz pages |
| `/pg rolls` | `patternSelfTest=PASSED` |
| `/pg comm` | Existing diagnostic still works |
| `/pg dr`, `/pg gb`, `/pg qz` | Each opens its start dialog |
| Solo, no group | Death Roll and Gambler show Party greyed out with "You're not in a party or raid." Guild and Public are greyed **permanently** for these two |
| `/reload` | No Lua errors. Turn on Lua errors first: `/console scriptErrors 1` |

**Quiz solo:** you can open the dialog but not start (needs 2+ players). Check all four
modes are offered: Trivia, Two Truths & a Lie, Unscramble, Type Race.

---

## 2. Death Roll (2 players minimum, small wager)

Use a **1g wager** for the first run. The ledger is advisory and nothing moves real gold,
but you want the numbers boring while you check the mechanics.

- [ ] Host opens a table, second player gets the invite popup and joins
- [ ] Turn order is announced and matches on both screens
- [ ] Roll on your turn - result becomes the new ceiling on **both** clients
- [ ] Roll a 1 (or force it: set the starting ceiling to 2 and roll until someone hits 1)
- [ ] Eliminated player pays into the pot; ceiling resets for the next player
- [ ] Last player standing takes the pot
- [ ] `/pg ledger` shows one Death Roll row on both clients, **with identical numbers**
- [ ] Settle Up shows the right direction (loser pays winner)

**With exactly two players this is the classic 1v1 deathroll.** That is deliberate - if it
feels like anything else, something is wrong.

**Timeout path:** have one player deliberately not roll. Expect the turn to time out after
the turn timer, that player eliminated, and the game to continue. Then check the ledger
still balances.

**Interruption path:** start a turn, then have someone ready-check. Expect the window to
hide instantly, the turn to freeze, and to resume afterwards on the same turn.

---

## 3. Gambler (3+ players is much more interesting than 2)

- [ ] Host sets a max wager and opens; everyone rolls once inside the window
- [ ] Lowest roller pays the highest roller **the difference** between their two rolls
- [ ] Everyone in between pays and receives nothing
- [ ] Ledger rows identical on every client, and they sum to zero
- [ ] Ties: run it until you get a tie for lowest or highest and confirm the split reads
      sensibly to the table. This is the rule most likely to cause an argument, so it is
      worth seeing once with real people before a real wager

**Someone doesn't roll:** expect them excluded, not charged.

---

## 4. Quiz (2+ players, any audience)

- [ ] Host picks a mode and starts; question appears in the addon window on every client
- [ ] Type an answer into the box and press Enter - it is whispered to the host, **never
      posted to chat**. Watch your chat frame and confirm nothing appears
- [ ] Scoring: first correct answer 3 points, second 2, everyone else correct 1
- [ ] Trivia accepts alternative spellings ("Arthas" for "The Lich King") and rejects
      fragments
- [ ] Two Truths shows three statements, answer with A/B/C
- [ ] Unscramble and Type Race both work
- [ ] Standings and podium at the end; medals persist across `/reload`
- [ ] **Ledger is untouched** - Quiz is points only. Confirm no Quiz row ever appears

**Guild audience:** worth one run, since it is the only new game that can use it. Both
players need 1.1.0.

---

## 5. Things worth watching for generally

- **Any Lua error at all.** `/console scriptErrors 1`, or use BugSack. Report the full
  stack.
- **A game that hangs with no result.** Every module is supposed to either finish, cancel,
  or time out. A session that sits forever is a real bug even if nothing is lost.
- **Ledger rows that differ between clients** for the same game. This is the single most
  important thing to check, and the reason to compare `/pg ledger` on two screens after
  every gold game. Identical rows on every client is the entire safety property.
- **"nothing was recorded" messages.** These are correct behaviour, not failures - a client
  refuses to write gold rows when it did not independently verify the result from the rolls
  it saw. Seeing one occasionally under bad latency is expected. Seeing one *every* game
  means something is wrong.

---

## 6. Known and deliberate

- **Death Roll and Gambler put your `/roll` in party/raid chat.** That is the point: the
  rolls are public evidence, which is what lets every client verify the result
  independently. The addon itself still prints nothing to chat.
- **The quiz answers are readable** by anyone who opens `Data/QuizData.lua`. The question
  bank has always shipped inside the addon. These are social games.
- **Death Roll and Gambler are party/raid only.** A `/roll` system message only reaches your
  own group, so guild and public are impossible, not merely disabled.
- **1.0.0 players cannot join the new games** but can still play Loot Goblins, Pull Book and
  RPS with you - the wire version deliberately did not change.

---

## 7. Known residuals (what a MODIFIED client could still do)

These all require somebody to run a deliberately altered copy of the addon. Nothing here is
reachable by an ordinary player, and none of it affects honest play. They are listed because
an honest list is more useful than a clean one.

Six adversarial review passes closed roughly thirty routes by which a modified host could
move gold to the wrong person. What survives:

**Gambler A13b - the last gold-moving route.** If a client genuinely loses the BEGIN message
to a wire drop, the host can answer that client's resync request with a lie and then
broadcast a result that fits only the lie. That one client commits wrong rows.
- It is no longer SILENT, which is what makes it acceptable to ship: the host must break
  every OTHER client to steal from one, so the victim ends up holding a Settle Up row for a
  game nobody else recorded. That is visible to the table.
- Closing it properly needs the frozen roster checked against something the host does not
  author, and the only candidate (the live group) is unsound because leaving the roster
  during the join window is legal. Measured cost of the naive fix: it breaks seven honest
  resync paths, including the maximal replay the whole budget was sized for.

**Death Roll E11b.** A claimed timeout is believable after the honest minimum turn length,
so a modified host can eliminate a player who sat silent that long. It cannot be aimed at
somebody who DID roll - that is proven, not assumed - and 15 seconds of a player visibly not
rolling is something the whole table watches happen.

**"Too far behind to catch up".** A modified host can tell one client it is hopelessly
desynced. That client then records nothing. It cannot produce wrong rows, and the player is
told explicitly, twice. No gate can distinguish this from an honest host saying the same
true thing.

**Quiz (no gold at all).** A modified host can poison one player's own medal tally, swap one
player's question, or cancel one player's invitation. Quiz never writes a ledger row.

### What this means practically

Play gold games with people you would lend gold to. That was already true - the ledger is
advisory, settlement is manual, and anyone who loses can simply log out and never pay. The
work above is not what makes the game safe to play with strangers; the buy-in size is. What
it does guarantee is that **an ordinary player running the shipped addon cannot be cheated
by a bug**, and that a deliberate cheat cannot do it invisibly.
