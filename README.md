# tidy

One-command inventory cleanup for Kingdom of Loathing, run from KoLmafia after
a farming session. It sits on top of [Philter](https://github.com/Loathing-Associates-Scripting-Society/philter)
and fixes the three things that make Philter annoying to run every day:

1. **Philter stops and asks about every item it has no rule for.** tidy writes a
   sensible rule first (see "How rules get decided"), so Philter never has to ask.
2. **Philter reprices your whole listing when it adds stock.** For any item
   whose rule says MALL and which is already in your store, tidy tops the
   listing up at *your* price before Philter runs, so your prices stay yours.
3. **Stale prices.** Once per KoL day, tidy lowers any listing under a threshold
   (default 1,000,000 meat, adjustable or off) that sits above KoLmafia's market
   price. That price skips the five cheapest listings, so it never undercuts
   anyone and never starts a price war. It never raises a price you set, never
   chases a market that has collapsed to the 100-meat floor, and never goes
   below 100 meat (all adjustable, see Settings). Listings above the threshold
   are your hand-set prices and are never touched.

Everything is whitelist-only: an item with no rule is never touched, and every
live command has a preview twin that sells nothing.

## Commands

Nothing runs live without the word `go`.

| Command | What it does |
|---|---|
| `tidy` (or `tidy sim`) | Preview. Writes rules for any inventory item kinds that have none (so you can review them), then prints exactly what a live run would do. Sells nothing. |
| `tidy go` | Live. Rules for new item kinds, keep-count check, daily reprice, drip listings, store top-ups at your prices, then Philter. Refuses until a preview has been run at least once. |
| `tidy help` | Prints the commands, your current settings, and which optional files are loaded. Does nothing else. Any other word does the same, after naming the word it did not understand. |
| `tidy reset` | Clean sweep. Backs up your rule file as `OCDdata_<name>.before-reset-<date>.txt`, then runs the first-run preview: a fresh rule for every item kind in your inventory, nothing sold. For people who picked up Philter years ago and cannot remember what they decided. |
| `tidy revert` | Undo. Right after a reset it restores the dated backup. Otherwise it swaps in the `.prev` copy that every rule-file write leaves behind; run it again to swap back. Never sells anything. |
| `tidycloset` | Preview. Writes rules for closet items that have none, then tallies. Moves nothing. |
| `tidycloset go` | Live, one-off. Empties the closet into inventory and runs the tidy pipeline. Refuses unless the preview ran the same day. |

`tidysim` and `tidyclosetsim` are older names for the two previews and still work.

Typical day: `garbo; tidy go` (or whatever your farming script is, then `tidy go`).

## Install

In KoLmafia's gCLI:

```
git checkout https://github.com/birjeldadge/tidy
```

That also installs Philter and zlib if you do not have them. Needs KoLmafia
r26597 or newer.

## First run

1. Run `tidy`. It writes a starting rule for every item kind that has none
   to `data/OCDdata_<yourname>.txt` (your existing rules, if any, are kept),
   then previews what a live run would do. **Nothing is sold.**
2. Open the relay browser, then **-run script- > Philter Manager**. Do not read
   every line: KEEP rules do nothing, and AUTO rules are sub-100-meat junk. Sort
   the MALL rules by price and look at the expensive ones. Change anything you
   disagree with. Keep-counts (the number next to MALL or AUTO) are how many
   copies stay in your inventory.
3. Run `tidy` again if you changed things, then `tidy go`.

`tidy go` refuses to run until a preview has been run at least once.

**Already had Philter or OCD?** Then a rule file exists that tidy did not write,
and every old decision in it stays in force. The first run says so, with counts.
Keep them, or `tidy reset` for a clean sweep (your old file is backed up and
`tidy revert` undoes it).

**Crimbo piles and other "hold until later" items.** A script cannot know that
salad forks sell at a premium in December. Anything you are holding for a
season or a price gets a KEEP rule (or stays in the closet with a CLST rule).
Items worth `tidy_keepAbove` or more per copy start as KEEP for exactly this
reason; cheaper seasonal stock is yours to mark.

## How rules get decided

For an item with no rule yet, in this order:

- Untradeable: **KEEP**.
- On your keep list (see below), a piece of one of your saved outfits, or familiar equipment: **keep that many** (the keep-list count; otherwise 3 for accessories, 1 for anything else) and sell extras, unless the extras are worth `tidy_keepAbove` each, then KEEP.
- Already in your mall store: **KEEP** (you priced it; you decide whether tidy tops it up. Change the rule to MALL and it will, at your price).
- Also in your display case: **KEEP**.
- Philter's default ruleset says something other than sell: **KEEP**.
- An HP/MP restorative (mafia's own list, shipped as `data/tidy_restores.txt`): **KEEP**.
- The lazyman rule, only if you turned it on: mall price at or below `tidy_junkBelow` and it has an autosell value: **AUTO**, gear and consumables included.
- A potion, food, booze or spleen item: **KEEP** while `tidy_sellConsumables` is false (the default). You know which ones you use.
- Gear or a reusable tool: **KEEP**, except cheap duplicates (under 10,000 meat each, more than you can wear): keep what you can wear and sell the rest, or autosell the rest if they sit at the 100-meat floor.
- No mall price at all: **KEEP**.
- Worth `tidy_keepAbove` (default 10,000 meat) or more per copy, any count: **KEEP**. Valuable stock is yours to decide.
- Mall price at the 100-meat floor: **AUTO** (autosell) if it has an autosell value, else KEEP.
- Everything else: **MALL**.

The closet preview uses the same logic for closet items, except anything it
would KEEP becomes **CLST** (put back in the closet, keep today's inventory
count on hand) and items that grant a skill always stay in the closet.
Existing KEEP rules on closet items are converted the same way so the closet
does not flood your inventory. Review the rules in Philter Manager before
running `tidycloset`.

## What tidy changes in your rule file, and what it never touches

Your edits in Philter Manager stick. Every run, tidy only:

- **adds** a rule for each item kind that has none (using the list above);
- **raises the keep-count** on a MALL or AUTO rule for an outfit piece, familiar
  equipment, or keep-list item, if it is lower than what you can wear or listed;
- **turns CLAN and GIFT rules into KEEP** while `tidy_allowGiving` is false, and
  prints each one;
- **sets the keep-count** on drip-list items to what you have on hand;
- in the closet preview only, **turns KEEP into CLST** for items that are in the
  closet, so they go back there instead of flooding your inventory.

It never changes the action you chose on any other rule. Sort by price in
Philter Manager, set PULV, AUTO, MALL or KEEP however you like, and `tidy go`
will honour it every day after. The whole file is rewritten in a clean
five-column form on each save (some editors strip trailing tabs, which crashes
Philter's loader), and the previous version is kept as `.prev`.

## The lazyman rule (`tidy_junkBelow`), explained fully

Off by default. It exists for one kind of player: the one who used to open the
item manager, sort by price, and autosell everything under some number. It does
that once, at rule-writing time, so you never have to.

- **Turn it on** with `set tidy_junkBelow = 1000` (any number above 100; at 100
  or below it is off, because the floor rule already autosells 100-meat junk).
- **What it does:** when tidy writes a rule for a new item kind, if the item's
  mall price is at or below your number and it has an autosell value, the rule
  is AUTO. Gear, potions, food and booze included. The reason column in the
  preview says "lazyman rule".
- **What it never touches**, because those checks come first: untradeables,
  pieces of your saved outfits, familiar equipment, keep-list items, anything
  already in your store or display case, anything Philter's default ruleset
  says to keep, and HP/MP restoratives. Items with no autosell value are not
  affected either; they follow the normal rules.
- **It only applies to new rules.** Rules that already exist are not changed.
  To apply it to everything you hold, turn it on and then `tidy reset`.
- **Undo:** `tidy revert` after a reset, or turn it off and `tidy reset` again.
- **It is the one setting that sells gear.** A duplicate seal-clubbing club is
  junk to most people; if you are not most people, leave it off.

## Settings

Set these in the gCLI with `set name = value`.

| Preference | Default | Meaning |
|---|---|---|
| `tidy_keepAbove` | 10000 | New item kinds worth this much or more per copy start as KEEP, whatever the count. `0` turns it off. |
| `tidy_reprice` | down | `down`: never raises a price you set, and never chases a market that collapsed to the 100-meat floor. `both`: follows the market in either direction. `off`: never reprices. |
| `tidy_protectAbove` | 1000000 | Listings priced above this, or whose market price is above this, are never repriced (your hand-set prices). Set to `0` to turn the guard off and reprice everything. |
| `tidy_junkBelow` | off | **The lazyman rule.** Off unless you set it above 100. At `1000`, every new item kind with a mall price of 1,000 meat or less and an autosell value starts as AUTO, gear and consumables included, the way a hand pass of "autosell anything under 1k" would. Everything above it in the list ("How rules get decided") still wins: untradeables, outfit pieces and keep-list items, store and display-case items, Philter's default KEEPs, and restoratives are never touched by it. Read that list before turning this on: it is the one setting that sells gear. |
| `tidy_sellConsumables` | false | While false, potions (anything usable that grants an effect), food, booze and spleen items with no rule start as KEEP. Set true and they follow the normal rules (floor junk autosells, the rest goes to the mall). |
| `tidy_allowGiving` | false | While false, any CLAN or GIFT rule is turned into KEEP each run, so nothing goes to the clan stash or another player. |
| `tidy_priceFactor` | 1.0 | Multiplies the market price when repricing and when pricing a fresh drip lot. `0.99` lists 1% under it (10 meat on a 1,000-meat item, 10,000 on a 1,000,000-meat item) so you get the sale first. Floor of 100 meat still applies. |
| `tidy_priceJitter` | 0 | Random spread around the factor, so your prices are not a fixed pattern a rival can read. `0.01` with factor `0.99` draws a factor between 0.98 and 1.00 per item per day. A listing already inside that band is left alone, so this does not churn your whole store daily. Never above 1.0. |
| `tidy_rulesSuffix` | (empty) | Testing only. Use `OCDdata_<name><suffix>.txt` instead of your real rules. |

**Keep list.** Create `data/tidy_keep_<yourname>.txt` with one item per line,
`item name`, a tab, then a count. Those items always keep at least that many
copies on hand (existing MALL/AUTO rules get patched, and copies are taken back
from your store if you have fewer). Example:

```
sea cowbell	3
peppermint parasol	1
```

**Pin list.** Create `data/tidy_pin_<yourname>.txt` with one item name per
line. Those listings are never repriced, whatever their price: hand-set prices,
or items you keep in the mall just to watch the price.

**Drip list (for sellers who care about the market, not just junk).** A
listing that keeps refilling tells rivals you have depth, and they price against
you. A small lot that sells out and stays empty for a while looks like you dried
up, so they leave their prices alone. Create `data/tidy_drip_<yourname>.txt`,
one item per line: `item name`, tab, how many to list at a time, tab, how many
days to stay empty before relisting (optional, default 0). tidy lists that many
only when your store holds none of it and the empty days have passed (counted
from the first tidy run that finds the listing empty); while any are listed it
never adds more, whatever you hold. The rest stays in your inventory: tidy sets
that rule's keep-count to what you have on hand every run, so Philter never
lists it either. The fresh lot is priced at the market price times your factor
(and jitter). Example:

```
Mr. Accessory	1	3
pocket wish	5
```

**About "market price".** KoLmafia deliberately hides the true cheapest listing
from scripts (it is anti-mallbot policy in mafia itself): the price a script can
see is the 5th cheapest. That is what tidy uses. At factor 1.0 you sit at or
above the cheapest sellers and never start a price war. With a factor under 1.0
you list below that number, which may or may not undercut the real cheapest
seller. Your call.

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
and Philter. tidy itself only ever writes KEEP, MALL, AUTO and CLST rules;
Philter will also pulverize, use, craft, untinker or display items if a rule
you wrote yourself says so.

That promise covers old rules too. Philter's CLAN action puts items in the clan
stash and GIFT kmails them to another player. If your rule file has any (an old
setup often does), tidy turns them into KEEP on every run and tells you which
ones. To let them fire, `set tidy_allowGiving = true`, then `tidy revert` to
put the last batch back.

## Credits

Design notes, including why each default is what it is: [DESIGN.md](DESIGN.md).

Written by Birj (birjeldadge) with Claude, Anthropic's AI assistant, doing the
coding under his direction: Birj set the rules and the ethics, two clanmates
tested and pushed back, Claude wrote and tested the ASH. Built on Philter (LASS)
and OCD Inventory Control (Bale), and Zarqon's zlib. MIT licensed.
