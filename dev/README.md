# dev/ — development workspace

Everything in here is **work in progress**. The shipped addon lives in
[`../PengyouGames/`](../PengyouGames/) and is released from the repo root; nothing in this
folder affects it.

## What is here

| Path | What it is |
|---|---|
| `PengyouGamesDev/` | A fork of the 1.0.0 addon, renamed so it can be installed **next to** the stable one |
| `docs/` | A snapshot of the design specs at the 1.0.0 fork point, free to diverge |

## Installing the dev build alongside the stable one

Copy `PengyouGamesDev/` into `Interface/AddOns/` exactly like the real addon. Both can be
enabled at once, because everything that could collide has been renamed:

| | Stable | Dev |
|---|---|---|
| Addon folder | `PengyouGames` | `PengyouGamesDev` |
| Title in the addon list | Pengyou Games | Pengyou Games (DEV) |
| Slash commands | `/pg`, `/pengyou` | `/pgd`, `/pengyoudev` |
| Saved variables | `PengyouGamesDB` | `PengyouGamesDevDB` |
| Addon message prefix | `PENGYOU` | `PENGYOUDEV` |

The separate **message prefix** is the important one: a dev client and a stable client
cannot see each other's games at all, so experiments can never disturb a real raid night,
corrupt anyone's ledger, or pop a window for a guildie who is not testing. Test dev builds
with someone else also running a dev build.

The separate **saved variables** matter almost as much — your real gold ledger and medal
tallies are never touched by anything you do in here.

## Working in here

Same rules as the shipped addon (see `../docs/SPEC.md` §2 and §3): WoW Lua 5.1 syntax
checked with `luac -p`, ASCII-only sources, no new globals, no forbidden APIs, no
dependency on other addons, and every wire message single-part and under 200 bytes.

When something in here is ready to ship, it is ported back into `../PengyouGames/` as a
normal release, not by copying this folder over it.
