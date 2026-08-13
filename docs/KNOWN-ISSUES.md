# Known issues and things to revisit

Live-test findings and deliberate deferrals. Newest first.

---

## Quiz needs a design revisit (deferred, not forgotten)

Raised by the owner after the 1.1.0 live test. **Deliberately not being fixed yet**, because
the aesthetic and layout rework in progress may resolve part of it and it is not worth
solving twice.

**What is wrong**

1. **Typing is hard.** Three of the four modes (Trivia, Unscramble, Type Race) require the
   player to type a free-text answer into an edit box under a countdown. That is a lot of
   pressure for raid downtime, it punishes slow typists for reasons unrelated to knowing the
   answer, and it competes with the player also needing their keyboard for the game.

2. **Two Truths has two contradictory input affordances at once.** The round shows three
   statements labelled A, B and C - so the obvious input is "press A, B or C" - while the
   window simultaneously presents a free-text edit box and a Submit button, because those
   are shared with the other three modes. The player is offered two ways to answer and only
   one of them is right for this mode.

3. **Elements overlap.** Reported generally by the owner; the layout audit found specific
   instances in Quiz (the status line truncating at 372px against strings up to 545px, and
   the answer box competing with the statement block for vertical space).

**What to consider when it is picked up**

- The input control should be **per mode**, not shared. Two Truths wants three big clickable
  A/B/C cards and no edit box at all. Type Race genuinely wants an edit box. Trivia and
  Unscramble could go either way - multiple choice would remove the typing problem entirely,
  but the question bank is written for free text and has an `alt` list of accepted spellings,
  so converting it is real work on the data rather than the UI.
- If typing stays anywhere, the answer box should take focus automatically when a round
  opens, and lose it when the round resolves. Today nothing in the addon ever calls
  `SetFocus` (verified: zero call sites addon-wide).
- The scoring already tolerates slow answers by design - everyone correct scores, with the
  value stepping down by arrival rank - so the fix does not have to preserve a race.

**Do not** start this until the single-design and layout rework has shipped and been looked
at in game. Some of the overlap complaints are expected to disappear with it.

---

## Death Roll: rolls only worked for one of the two players (FIXED, shipped)

Found by the owner in a two-person live test: one player's rolls registered, the other
player's never did.

**Cause.** The host adjudicates by watching `CHAT_MSG_SYSTEM` for everyone's `/roll` and
resolving the printed name against the frozen roster (`rosterIndex` -> `S.rIndex[name]`).
The host's own name comes from `PG.FullName("player")` and always matches. Another player's
name comes from the system message through `PG.NormalizeSender`, which appends the LOCAL
realm to any name printed without one. When that lookup misses, the roll is silently
dropped and the turn runs down to a timeout.

This was self-inflicted. A security audit flagged the name mapping as a wrong-payout risk
and the resolution was "drop the roll rather than guess which player it was" - which is safe
for gold and identical, from the player's seat, to "you cannot roll."

**What shipped.** Each client observes only its OWN roll and reports it to the host as a
`ROLLED | seq | value | low | high` whisper; the host adjudicates from that report rather
than from a system message it may never resolve, and broadcasts the authoritative outcome
exactly as before. Name matching is gone from the roll path entirely - you always know your
own name (`PG.FullName("player")`) and an addon message's sender is vouched by the delivery
distribution. The host's own roll is applied locally and never whispered to itself.

**And the strict client-side verification came out**, per the same ruling. The host is
trusted, as it already is in Loot Goblins, Pull Book and Rock Paper Scissors: every client
commits from the host's `END`/`RESULT`. A client whose own observation disagrees toasts it -
for its own roll only, as information - and records the game anyway. `deriveOutcome`,
`crossCheckOK`, `sawDecidingRolls`, the timing gates built to make a claimed timeout
unforgeable, and Death Roll's duplicate-short-name cancel all went with it. The reasoning,
in the owner's words: "we can't completely stop cheating in this, and that's okay ... it's
best to not overengineer things to the point that we cripple being able to play the game at
all."

**Both games went to guild and public** in the same change, which is what the group-scoped
`/roll` system message had made impossible. `PG.DR.SCOPES` and `PG.GB.SCOPES` are all three
audiences, both modules carry the RPS-shaped whisper-trust predicate (a blanket `false`
would have dropped every JOIN, `ROLLED` and `SYNCQ` from outside the group and made the new
scopes dead on arrival), both pass `vouch` into `PG.Ledger.Commit` so public games record,
both gained the wide-scope heartbeat pair, and Death Roll's group-absence scan now runs at
group scope only.

**Two things to watch in the next live test.**

1. *Everyone at the table needs the addon.* There is no longer any way to score a player
   who cannot report a roll, and a 1.1.0 client at a newer host's table is scored as a
   no-show with no warning anywhere. If somebody "rolls and nothing happens", check their
   version before anything else.
2. *Guild and public are newly live for these two.* Nobody has played a wide-scope Death
   Roll or Gambler against a real server yet.
