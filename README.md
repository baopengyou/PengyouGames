# Pengyou Games

Raid-downtime minigames for World of Warcraft (patch 12.1). Six games -- **Loot Goblins**,
**The Pull Book**, **Rock Paper Scissors**, **Death Roll**, **The Gambler** and **Quiz**
-- run over invisible addon messages while your raid waits between pulls. All gold is
virtual: the addon keeps a shared ledger and, at the end of the night, shows a "Settle Up"
screen telling players who should pay whom by trade or mail. The addon never touches real
gold, never posts to chat itself, and hides all of its UI the instant anything
raid-critical happens.

Only people running the addon see anything -- with one deliberate exception. Death Roll
and The Gambler are settled by real `/roll` results, which means the *rolls* are visible
to your whole group whether or not they have the addon. That is the point of those two
games, and it is spelled out under [Games that use /roll](#games-that-use-roll).

## Playing with people on 1.0.0

Loot Goblins, The Pull Book and Rock Paper Scissors work between 1.0.0 and 1.1.0 players
with no change at all -- same messages, same rules, same ledger. Nothing about them was
touched.

The three new games need 1.1.0 on both sides. A player still on 1.0.0 never sees a Death
Roll, Gambler or Quiz invitation and is never told why: their addon reads the message,
finds no game called that, and quietly drops it. Nothing breaks and nothing is recorded
on their side -- they simply are not invited. If your raid is half-updated, that is the
symptom to expect, and the fix is for everyone to update.

Updating did *not* break compatibility for the three original games on purpose. Bumping
the message version would have made 1.0.0 and 1.1.0 players unable to play Loot Goblins
together, which is a much worse trade than a silently uninvited player.

## Installation

1. Copy the `PengyouGames/` folder (the folder containing `PengyouGames.toc`) into your
   WoW AddOns directory:
   - Windows: `World of Warcraft\_retail_\Interface\AddOns\PengyouGames`
   - macOS: `World of Warcraft/_retail_/Interface/AddOns/PengyouGames`
2. Restart the game or type `/reload`.
3. Type `/pg` to open the launcher.

Sharing with your raid over Discord: zip the `PengyouGames/` folder (right-click ->
Compress / Send to -> Compressed folder) and post the zip. Teammates unzip it straight
into `Interface/AddOns/` so that the result is `Interface/AddOns/PengyouGames/PengyouGames.toc`
-- not a nested `PengyouGames/PengyouGames/` folder. Everyone who wants to play needs the
addon installed; group members without it are simply never bothered.

## Slash commands

| Command | Effect |
|---|---|
| `/pg` or `/pengyou` | Toggle the launcher window |
| `/pg help` | List every command in your own chat frame |
| `/pg lg` | Open the Loot Goblins start dialog |
| `/pg book` | Open the Pull Book dialog |
| `/pg rps` | Open the Rock Paper Scissors start dialog |
| `/pg dr` or `/pg deathroll` | Open the Death Roll start dialog |
| `/pg gb` or `/pg gambler` | Open The Gambler start dialog |
| `/pg qz` or `/pg quiz` | Open the Quiz start dialog |
| `/pg ledger` | Open the ledger (Tonight / Settle Up) |
| `/pg rules` | Open the Rules explainer (one page per game) |
| `/pg dnd` | Toggle Do Not Disturb (suppresses popups and toasts) |
| `/pg settings` | Open settings (sounds, DND, minimap button, combat hiding, window scale, layout reset) |
| `/pg minimap` | Show/hide the minimap button |
| `/pg comm` | Report the messaging and audience state (why is Public greyed out?) |
| `/pg rolls` | Report whether this client can read `/roll` results, and the last few it saw |
| `/pg debug` | Toggle local debug output |

Anything unrecognized just opens the launcher.

There is also a coin-shaped **minimap button**: left-click opens the launcher, right-click
toggles DND, and dragging it moves it around the minimap rim.

Every window can be dragged anywhere, and **resized** with the grip in its bottom-right
corner (the whole window scales, and each window remembers its own size). Windows also
**never overlap each other**: opening or dragging one onto another nudges it to the
nearest clear spot.

## Who you play with

When you start a game you pick its **audience** from the scope selector in the start
dialog:

| Scope | Who it reaches |
|---|---|
| **Party** | Your party or raid, as always |
| **Guild** | Every online guild member running the addon, including guildmates on other realms -- no group needed |
| **Public** | Everyone on your realm and its connected realms running the addon, same faction |

Not every game supports every audience, and the reason is always the same one: a game can
only be played by people who can see the thing it is scored from.

| Game | Audiences |
|---|---|
| Loot Goblins | Party, Guild, Public |
| Rock Paper Scissors | Party, Guild, Public |
| Quiz | Party, Guild, Public |
| The Pull Book | Party only -- scored from the pull you are personally standing in |
| Death Roll | Party only -- a `/roll` only reaches your own group |
| The Gambler | Party only -- same reason |

The two `/roll` games are the strictest case. A roll appears in the chat of your party or
raid and nowhere else, so a guildmate in a city would be asked to bet gold on evidence
they cannot see. Guild and Public are not merely switched off for those two: they are
impossible, and the start dialog says so on hover instead of hiding the option.

Public uses a hidden chat channel that the addon joins for you. Nothing is ever printed
to your chat windows, but it does occupy one of your ten channel slots, so it is opt-in
from `/pg settings`.

## Playing more than one game at once

You **play** one game at a time. Loot Goblins, Rock Paper Scissors, Death Roll, The
Gambler and Quiz each want your full attention inside a timer, so being in one of them
puts the others' Join buttons out of reach until it ends -- the launcher greys them and
the tooltip tells you which game you are in.

Two things are *not* blocked:

- **The Pull Book runs alongside anything.** It is passive betting on your own pulls, so
  it never takes your one seat and its invitations are never greyed out.
- **You can always host.** Starting a game is never blocked by another game: if you are
  already playing something, you run the new one for everybody else without playing in it
  yourself. You take no stake, take no turn, and get no ledger row -- you just hold the
  table and can cancel it.

Any number of games can be running around you, including two Death Rolls in the same
raid. If several are open you will see an invite for each and pick the one you want;
accepting one withdraws the rest, and anything that could not fit on screen waits in the
launcher's open-games list.

## Rules

Not sure how something works? `/pg rules`, or the **Rules** button in the launcher and on
every game's start dialog. One page per game, in plain language, including how scoring
works and who you can play with.

## Games that use /roll

Death Roll and The Gambler are settled by a **real in-game roll**. This is the one place
the addon is deliberately not invisible, so here is exactly what happens:

- **You make the roll.** The window tells you the precise command to type -- `/roll 743`
  -- and you type it. There is also a ROLL button that asks your own client to make that
  same roll for you; either way it is an ordinary roll, produced by the server, that the
  addon merely *watches*. The addon never invents a number and never types into chat.
- **Your group sees it.** The roll lands in the chat of everyone in your party or raid,
  including people without the addon. Nothing else about the game is printed anywhere.
- **That is what makes the result unarguable.** Because everyone watched the same rolls,
  every player's copy of the game works out the winner from the rolls **it** saw and
  compares that against what the host announced. If the two disagree, that client records
  nothing and says so. If you were away and missed a roll that mattered, same answer:
  nothing recorded, and it tells you. Nobody has to trust anybody's screen.
- **Rolls made while the game is hidden do not count** -- not for you, not for anyone. If
  a boss pull, ready check or pull timer is up, the addon stops watching entirely, on
  every client alike, and the game resumes afterwards with time put back on the clock.
- **Wrong-sized rolls do not count either.** Roll 100 when the game asked for 743 and you
  are told, and can still roll properly before the timer ends.

If your client cannot read roll results at all -- an unusual locale, mostly -- Death Roll
and The Gambler refuse to start on it rather than seating you at a table they could never
score. `/pg rolls` says whether that is the case.

## The games

### Loot Goblins

A buy-in game of greed. One player hosts and sets the buy-in (default 100g) and a number
of rounds (default 5). Everyone in the group running the addon gets a popup: **Buy in or
pass**. Buy-ins form the pot.

Each round, a slice of the pot goes up for grabs and every goblin secretly picks one of
two buttons before the timer runs out:

- **SHARE** -- split the round's pot evenly with the other sharers.
- **HOARD** -- try to grab the lion's share (80% of the round pot, split among hoarders).

The catch: hoarding only pays while hoarders are rare -- roughly one in five pickers. If
too many people get greedy, **the hoarders get nothing** and the sharers split everything.
If nobody picks, the pot rolls over to the next round. Leftover coppers ("dust") carry
forward and go to the unluckiest player at the end.

When the final round resolves, each player's net (winnings minus buy-in) is written to
the ledger. If the game is cancelled or the host vanishes mid-game, **nothing** is
written -- buy-ins are all-or-nothing, so an interrupted game never costs anyone anything.

### The Pull Book

Pre-pull betting. One player opens the book as **bookie**, setting the stake per bet
(default 100g) and a wipe line (default 50% boss HP). From then on, whenever a ready
check or pull timer fires, a small betting strip appears with three markets:

- **Kill?** -- YES / NO: does this attempt kill the boss?
- **First death** -- TANK / HEALER / DPS: which role dies first?
- **Boss HP at end** -- OVER / UNDER the line: if you wipe, how low did you get the boss?

Click to bet; your first click per market locks. When the pull starts, bets freeze. After
the encounter ends, every market resolves automatically: losers pay a stake each, winners
split the pot. A market with fewer than two bettors, everyone on the same side, or no
winners is void -- stakes returned. Results arrive as a quiet toast once combat is over
("Pull Book: kill! 3 winners split 500g -- you +166g").

The book stays open pull after pull until the bookie closes it.

### Rock Paper Scissors

The no-gold game: pure points, pure pride. Anyone starts a match (best of 3 by default);
everyone in the group gets an invite popup. Each round, every player secretly throws
ROCK, PAPER, or SCISSORS within the timer -- and you score **one point for every player
you beat**: if 12 people throw 5 rock / 3 paper / 4 scissors, each rock player scores 4
(the scissors they smashed), each paper player 5, each scissors player 3. Everyone
throwing the same thing scores nothing. After the last round: podium -- 1st, 2nd, 3rd by
total points, ties share the spot -- and gold-medal counts persist between raid nights.
No buy-in, no ledger, no settling up.

### Death Roll

The old duel, opened up to the whole raid. The host sets a wager (default 100g) and a
starting number, which follows the wager unless they change it. Everyone who joins puts
up the same wager, and play goes one player at a time around the table from a random
starting seat.

On your turn the window tells you what to type -- `/roll 743` -- and a timer runs.
Whatever you roll becomes the ceiling for the next player, so the numbers collapse fast:
1000, 612, 88, 9. **Roll a 1 and you are out**, you owe one wager into the pot, and the
next player starts again from the opening number. Roll the wrong range and it does not
count. Run out of time, or drop connection, and you are out exactly as if you had rolled
a 1 -- the table cannot tell a lost connection from a slow decision, and waiting would
stall everybody.

The last player standing collects one wager from every player who went out. With two
players that reduces to precisely the classic duel: the first to roll a 1 pays the other
one wager.

### The Gambler

The fastest game in the suite: one roll each, over in half a minute. The host sets the
biggest number anyone can roll (default 1000), everyone rolls it once inside a single
timed window, and **the lowest roll pays the highest roll the difference between them**.
Low roll 12, high roll 964: that is 952g from one player to the other, and everyone in
between neither pays nor collects.

Ties for lowest split the bill; ties for highest split the winnings. If nobody rolls, if
only one player rolls, or if everyone rolls the same number, there is no difference to
pay and nothing changes hands. Each game is one round -- "play again" starts a fresh one
with a fresh join window, so nobody is committed beyond the round in front of them.

A warning the start dialog also gives you: **100 is the number a bare `/roll` produces**,
so a game set to 100 will quietly count somebody's loot roll as their entry. Pick
anything else.

### Quiz

No gold at all -- points, medals and how fast you know things. The host ticks which kinds
of question to use and how many to ask (default 5), everyone gets the same question at
the same moment, and answers are **typed into the quiz window**, not into chat. Your
answer goes to the host privately and stays hidden until the timer ends.

Four kinds of question, in any combination:

- **Trivia** -- a question, and you type the answer. Near misses and the usual
  alternative spellings are accepted.
- **Two Truths and a Lie** -- three statements; name the false one.
- **Unscramble** -- a jumbled word; type it straight.
- **Type Race** -- a phrase on screen; type it exactly, fastest wins.

Everyone correct scores: **3 points for the first correct answer, 2 for the second, 1 for
everyone else who got it right.** Speed is worth something without leaving a laggy player
unable to score. Wrong answers and silence both cost nothing. The host can optionally
turn on a hint that appears halfway through the timer. At the end: a podium, and
gold-medal counts that persist between raid nights.

The questions ship inside the addon rather than being sent around, so **everyone playing
needs the same version of Pengyou Games**. If yours does not match the host's you are told
so and left out, rather than being quietly shown a different question from everybody
else. It also means the answers ship with the addon: anyone determined to look them up
can. This is a game for people who would rather not.

## Virtual gold and settling up

Three games write to the ledger -- **Loot Goblins**, **Death Roll** and **The Gambler**.
Rock Paper Scissors and Quiz are points-only and never touch it, so they cannot cost
anybody a copper.

No gold ever moves through the addon. Every win and loss lands in a local ledger, keyed
by day. Open it with `/pg ledger`:

- **Tonight** -- each player's running net for the day, green or red.
- **Settle Up** -- the minimal set of payments that squares everyone up, with your own
  lines highlighted ("YOU pay Bob-Realm 250g"). Players then trade or mail the gold
  themselves -- or don't; that is between you and your raid.

"Clear tonight" wipes the day's ledger on your screen only.

## Known limitations

Pull Book bets are broadcast to the whole group and every client resolves them from its
own recorded bet set. If someone's client missed a BET broadcast (they logged in late,
relogged, or a message was dropped by the server), their ledger can disagree with
everyone else's for that attempt. The ledger is a social scorekeeper, not an
authoritative bank -- when screens disagree, the raid decides. A reconciliation protocol
is planned for a later version.

Death Roll and The Gambler go the other way, and are the most auditable games here: every
client's ledger is worked out from the same publicly visible rolls, so screens do not
disagree -- a client that *would* disagree writes nothing at all and tells you why. The
cost of that strictness is that a roll which arrives while your client has the game hidden
(boss pull, ready check, pull timer), or a roll of the wrong size, is not counted and the
turn times out instead. And if two players in the same game share a character name -- the
same name on two connected realms, with at least one of them on yours -- the game cancels
before it starts: a roll from a same-realm player is not realm-qualified in chat, so those
two players' rolls genuinely cannot be told apart, and cancelling beats paying the wrong
person.

## Raid-leader notes

- **Auto-hide**: every Pengyou window vanishes instantly when a boss encounter begins,
  a ready check appears, or a pull countdown starts -- and re-appears on its own once
  the coast is clear, with the game state intact (clients quietly resync with the host
  after every interruption). Ordinary combat (open world, raid trash) does NOT hide
  anything or pause the games -- addon messaging is fully legal there -- but a
  "Hide game windows while in combat" switch in `/pg settings` restores the old
  behavior for anyone who prefers it. The Pull Book strip is the one deliberate
  exception -- it exists precisely for the ready-check/countdown window -- and it
  disappears the moment the encounter begins.
- **DND**: players who want zero distraction can `/pg dnd`. They get no popups and no
  toasts; game invites are silently declined for them.
- **The addon never posts to chat -- but two games ask *you* to**: the addon itself
  communicates only over hidden addon messages and prints only to the player's own chat
  frame. It has never called a chat function and still does not. The honest asterisk is
  Death Roll and The Gambler: those two are settled by a real `/roll`, which the player
  types (or triggers with the ROLL button), and a roll result is visible to your whole
  group including people without the addon. That is deliberate -- it is what makes those
  two games auditable -- but it does mean they are the only two games in the suite that
  are not invisible to non-users. The other four leave no trace in chat or the combat log
  at all. If you want a completely silent raid, those are the two to skip.
- **M+ and PvP self-disable**: patch 12.1 blocks addon messaging for the entire duration
  of a Mythic+ run and any PvP match (and during boss encounters). Pengyou Games respects
  this completely: nothing is sent, no bet windows open, and anything that could not be
  delivered is dropped rather than retried. These games are for raid downtime -- trash
  combat in a raid does not interfere.
