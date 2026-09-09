# tidy

One-command inventory cleanup for Kingdom of Loathing, run from KoLmafia after
a farming session. It sits on top of [Philter](https://github.com/Loathing-Associates-Scripting-Society/philter)
and fixes the three things that make Philter annoying to run every day:

1. **Philter stops and asks about every item it has no rule for.** tidy writes a
   sensible rule first (see "How rules get decided"), so Philter never has to ask.
2. **Philter reprices your whole listing when it adds stock.** tidy tops up
   anything already in your store at *your* price before Philter runs, so your
   prices stay yours.
3. **Stale prices.** Once per KoL day, tidy sets every listing under a threshold
   (default 10,000,000 meat) to KoLmafia's market price. That price skips the five
   cheapest listings, so it never undercuts anyone and never starts a price war.
   Never below 100 meat. Listings above the threshold are your hand-set prices
   and are never touched.

Everything is whitelist-only: an item with no rule is never touched, and every
live command has a preview twin that sells nothing.

## Commands

| Command | What it does |
|---|---|
| `tidysim` | Preview. Writes rules for any item kinds that have none (so you can review them), then prints exactly what `tidy` would do. Sells nothing. |
| `tidy` | Live. New rules for new item kinds, store top-ups at your prices, daily reprice, then Philter. |
| `tidyclosetsim` | Preview of `tidycloset`. Writes rules for closet items that have none, then tallies. Moves nothing. |
| `tidycloset` | Live, one-off. Empties the closet into inventory and runs the tidy pipeline. Refuses unless `tidyclosetsim` ran the same day. |

Typical day: `garbo; tidy` (or whatever your farming script is, then `tidy`).

## Install

In KoLmafia's gCLI:

```
git checkout https://github.com/birjeldadge/tidy-public
```

That also installs Philter and zlib if you do not have them. Needs KoLmafia
r26597 or newer.

## First run

1. Run `tidysim`. It writes a starting rule for every item kind that has none
   to `data/OCDdata_<yourname>.txt` (your existing rules, if any, are kept),
   then previews what a live run would do. **Nothing is sold.**
2. Open the relay browser, then **-run script- > Philter Manager**. Do not read
   every line: KEEP rules do nothing, and AUTO rules are sub-100-meat junk. Sort
   the MALL rules by price and look at the expensive ones. Change anything you
   disagree with. Keep-counts (the number next to MALL or AUTO) are how many
   copies stay in your inventory.
3. Run `tidysim` again if you changed things, then `tidy`.

`tidy` refuses to go live until `tidysim` has been run at least once.

## How rules get decided

For an item with no rule yet, in this order:

- Untradeable: **KEEP**.
- A piece of one of your saved outfits, or familiar equipment: **keep 1**, sell extras.
- On your keep list (see below): keep that many, sell extras.
- Already in your mall store: **MALL**, extras go to your store at your price.
- Also in your display case: **KEEP**.
- Philter's default ruleset says something other than sell: **KEEP**.
- Gear or a reusable tool: **KEEP**. Cheap duplicates (under 10,000 meat, 2 or more): keep 1, sell the rest.
- A single copy worth 10,000 meat or more: **KEEP** (rare, decide yourself).
- Mall price at the 100-meat floor: **AUTO** (autosell) if it has an autosell value, else KEEP.
- Everything else: **MALL**.

The closet preview uses the same logic for closet items, except anything it
would KEEP becomes **CLST** (put back in the closet, keep today's inventory
count on hand) and items that grant a skill always stay in the closet.
Existing KEEP rules on closet items are converted the same way so the closet
does not flood your inventory. Review the rules in Philter Manager before
running `tidycloset`.

## Settings

Set these in the gCLI with `set name = value`.

| Preference | Default | Meaning |
|---|---|---|
| `tidy_protectAbove` | 10000000 | Listings priced above this are never repriced. |
| `tidy_rulesSuffix` | (empty) | Testing only. Use `OCDdata_<name><suffix>.txt` instead of your real rules. |

**Keep list.** Create `data/tidy_keep_<yourname>.txt` with one item per line,
`item name`, a tab, then a count. Those items always keep at least that many
copies on hand (existing MALL/AUTO rules get patched, and copies are taken back
from your store if you have fewer). Example:

```
sea cowbell	3
peppermint parasol	1
```

## Guards

- Aftercore only (refuses in Ronin or Hardcore).
- Refuses until Hagnk's has been emptied this ascension (`pull all`).
- Forces Philter's `BaleOCD_EmptyCloset` to -1 so Philter never dumps your closet on its own.
- Every rule-file write keeps the previous version as `OCDdata_<name>.prev.txt`.
- If a store price cannot be read or a top-up fails, tidy stops before Philter runs.

## What it never does

Nothing leaves your account except through the mall and autosell. No kmail, no
trades, no clan stash, no chat, no buying, no network calls of its own. The only
money-moving calls are put-in-store, reprice, take-from-store, empty-closet,
and Philter.

## Credits

Written by Birj. Built on Philter (LASS) and OCD Inventory Control (Bale), and
Zarqon's zlib. MIT licensed.
