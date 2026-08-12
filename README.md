# Pengyou Games

Raid-downtime minigames for World of Warcraft (patch 12.1). Three games -- **Loot
Goblins**, **The Pull Book**, and **Rock Paper Scissors** -- run over invisible addon
messages while your raid waits between pulls. All gold is virtual: the addon keeps a shared ledger and, at the end of the night,
shows a "Settle Up" screen telling players who should pay whom by trade or mail. The
addon never touches real gold, never posts to public chat, and hides all of its UI the
instant anything raid-critical happens.

Only people running the addon see anything. Everyone else sees nothing at all.

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
| `/pg lg` | Open the Loot Goblins start dialog |
| `/pg book` | Open the Pull Book dialog |
| `/pg ledger` | Open the ledger (Tonight / Settle Up) |
| `/pg rps` | Open the Rock Paper Scissors start dialog |
| `/pg dnd` | Toggle Do Not Disturb (suppresses popups and toasts) |
| `/pg settings` | Open settings (sounds, DND, minimap button, combat hiding, window scale, layout reset) |
| `/pg minimap` | Show/hide the minimap button |
| `/pg rules` | Open the Rules explainer (one page per game) |

There is also a coin-shaped **minimap button**: left-click opens the launcher, right-click
toggles DND, and dragging it moves it around the minimap rim.

Every window can be dragged anywhere, and **resized** with the grip in its bottom-right
corner (the whole window scales, and each window remembers its own size). Windows also
**never overlap each other**: opening or dragging one onto another nudges it to the
nearest clear spot.
| `/pg debug` | Toggle local debug output |

## Who you play with

When you start a game you pick its **audience** from the scope selector in the start
dialog:

| Scope | Who it reaches |
|---|---|
| **Party** | Your party or raid, as always |
| **Guild** | Every online guild member running the addon, including guildmates on other realms -- no group needed |
| **Public** | Everyone on your realm and its connected realms running the addon, same faction |

Loot Goblins and Rock Paper Scissors support all three. **The Pull Book is party only**,
because it is scored from the boss fight you are personally standing in -- a guildmate in
a city cannot see the same result you do.

Public uses a hidden chat channel that the addon joins for you. Nothing is ever printed
to your chat windows, but it does occupy one of your ten channel slots, so it is opt-in
from `/pg settings`.

## Playing more than one game at once

You can only **play** one game at a time, but any number of games can be running around
you -- including two Loot Goblins games in the same raid. If several are open you will
see an invite for each and pick the one you want; accepting one withdraws the rest.
Starting a game is never blocked by someone else's game.

The Pull Book is the exception in the other direction: it is passive betting on your own
pulls, so it runs happily alongside whatever else you are playing.

## Rules

Not sure how something works? `/pg rules`, or the **Rules** button in the launcher and on
every game's start dialog. One page per game, in plain language, including how scoring
works and who you can play with.

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

## Virtual gold and settling up

No gold ever moves through the addon. Every win and loss lands in a local ledger, keyed
by day. Open it with `/pg ledger`:

- **Tonight** -- each player's running net for the day, green or red.
- **Settle Up** -- the minimal set of payments that squares everyone up, with your own
  lines highlighted ("YOU pay Bob-Realm 250g"). Players then trade or mail the gold
  themselves -- or don't; that is between you and your raid.

"Clear tonight" wipes the day's ledger on your screen only.

## Known v1 limitation

Pull Book bets are broadcast to the whole group and every client resolves them from its
own recorded bet set. If someone's client missed a BET broadcast (they logged in late,
relogged, or a message was dropped by the server), their ledger can disagree with
everyone else's for that attempt. The ledger is a social scorekeeper, not an
authoritative bank -- when screens disagree, the raid decides. A reconciliation protocol
is planned for a later version.

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
- **No public chat, ever**: the addon communicates only over hidden addon messages and
  prints only to the player's own chat frame. Nothing is visible to non-users, combat
  logs, or chat.
- **M+ and PvP self-disable**: patch 12.1 blocks addon messaging for the entire duration
  of a Mythic+ run and any PvP match (and during boss encounters). Pengyou Games respects
  this completely: nothing is sent, no bet windows open, and anything that could not be
  delivered is dropped rather than retried. These games are for raid downtime -- trash
  combat in a raid does not interfere.
