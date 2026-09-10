# tidy

One-command inventory cleanup for Kingdom of Loathing, run from KoLmafia after
a farming session. It sits on top of [Philter](https://github.com/Loathing-Associates-Scripting-Society/philter)
and fixes the three things that make Philter annoying to run every day:

1. **Philter finds items with no rule and asks whether to continue.** That is
   one prompt per run, and it means someone has to be at the keyboard, and the
   new items stay unsorted until you sit down with the manager. tidy proposes a
   rule for each new item kind first (see "How rules get decided"), so the run
   is unattended and the new items are already sorted when you look.
2. **Philter reprices your whole listing when it adds stock.** For any item
   whose rule says MALL and which is already in your store, tidy tops the
   listing up at *your* price before Philter runs, so your prices stay yours.
   The top-up counts the way Philter counts (bag, closet, and copies worn by
   you or by any familiar in your terrarium). If Philter would fetch copies off
   your familiars to sell them, tidy fetches them first and lists them at your
   price, so Philter finds nothing left to move.
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
| `tidy reset` | Clean sweep. Backs up your rule file as `OCDdata_<name>.before-reset-<date>-<time>.txt`, then runs the first-run preview: a fresh rule for every item kind in your inventory, nothing sold. `tidy go` is refused until you have run a plain `tidy` and looked. The dated backup stays the target of `tidy revert` until your first live run on the new rules; after that, revert goes back to undoing the last run. For people who picked up Philter years ago and cannot remember what they decided. |
| `tidy revert` | Undo. Right after a reset it restores the dated backup. Otherwise it swaps in the `.prev` copy taken by the last run that changed the file; run it again to swap back. Refuses a copy that holds no readable rules. After any revert, `tidy go` waits for a fresh preview. Never sells anything. |
| `tidycloset` | Preview. Writes rules for closet items that have none, then tallies. Moves nothing. |
| `tidycloset go` | Live, one-off. Empties the closet into inventory and runs the tidy pipeline. Refuses unless the closet preview ran the same day and a plain `tidy` preview has been run; both checks come before the closet is emptied. |

`tidysim` and `tidyclosetsim` are older names for the two previews and still work.

Typical day: `garbo; tidy go` (or whatever your farming script is, then `tidy go`).

## Install

In KoLmafia's gCLI:

```
git checkout https://github.com/birjeldadge/tidy
```

That also installs Philter and zlib if you do not have them. Needs KoLmafia
r27250 or newer.

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
- **turns CLAN, GIFT and DISC rules into KEEP** while `tidy_allowGiving` is
  false, and prints each one;
- **sets the keep-count** on drip-list items to what you have on hand (bag,
  closet and worn copies);
- **holds and later releases** rules a live run wrote for new item kinds (see
  `tidy_holdNewDays`); while a rule is held, its keep-count is raised to cover
  any copies picked up since, and it is released only after a preview on a
  later day has listed it (a keep-list or outfit count raised meanwhile wins
  over the held decision);
- on `tidycloset go` only, **turns KEEP into CLST** for items that are in the
  closet, so they go back there instead of flooding your inventory. The closet
  preview shows which ones and changes nothing.

It never changes the action you chose on any other rule. Sort by price in
Philter Manager, set PULV, AUTO, MALL or KEEP however you like, and `tidy go`
will honour it every day after. The whole file is rewritten in a clean
five-column form on each save (some editors strip trailing tabs, which crashes
Philter's loader). A copy of the file as it was before the run's first change (taken after it has
been read and checked) is kept as `.prev`, so `tidy revert` undoes the whole
run; a run that changes nothing leaves `.prev` alone.

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
| `tidy_maxCutPct` | 30 | The most the daily reprice may cut one listing in one day, as a percent of its current price. A few cheap units dumped by someone else for an afternoon cannot drag your listing to the floor in one run; if the market really stays there, the rest of the way comes on later days. |
| `tidy_holdNewDays` | 1 | A live run that finds a new item kind writes its rule but holds everything on hand (bag, closet and worn copies, counted the way Philter counts, plus anything picked up during the hold) for this many days, so nothing ever sells on a rule the same run that wrote it. The hold is also released only after a preview has run to the end on a later day than the rule was written: the preview lists every held rule with what would sell, and that is the look. A chained `garbo; tidy go` with nobody previewing keeps the hold. Drip listings skip a held rule too. `0` turns the hold off. |
| `tidy_junkBelow` | off | **The lazyman rule.** Off unless you set it above 100. At `1000`, every new item kind with a mall price of 1,000 meat or less and an autosell value starts as AUTO, gear and consumables included, the way a hand pass of "autosell anything under 1k" would. Everything above it in the list ("How rules get decided") still wins: untradeables, outfit pieces and keep-list items, store and display-case items, Philter's default KEEPs, and restoratives are never touched by it. Read that list before turning this on: it is the one setting that sells gear. |
| `tidy_sellConsumables` | false | While false, potions (anything usable that grants an effect), food, booze and spleen items with no rule start as KEEP. Set true and they follow the normal rules (floor junk autosells, the rest goes to the mall). |
| `tidy_allowGiving` | false | While false, any CLAN, GIFT or DISC rule is turned into KEEP each run, so nothing goes to the clan stash, to another player, or into the void. |
| `tidy_priceFactor` | 1.0 | Multiplies the market price when repricing and when pricing a fresh drip lot. `0.99` lists 1% under it (10 meat on a 1,000-meat item, 10,000 on a 1,000,000-meat item) so you get the sale first. Floor of 100 meat still applies. Only a listing above market is cut; one already at or under market is left alone, because the market figure counts your own units and cutting there would chase your own price down 1% a day. |
| `tidy_priceJitter` | 0 | Random spread around the factor, so your prices are not a fixed pattern a rival can read. `0.01` with factor `0.99` draws a factor between 0.98 and 1.00 per item per day. A listing already inside that band is left alone, so this does not churn your whole store daily. Never above 1.0. |
| `tidy_rulesSuffix` | (empty) | Testing only. Use `OCDdata_<name><suffix>.txt` (and the matching keep, pin and drip files) instead of your real ones. Live runs are refused while it is set. |

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
that rule's keep-count to what you have on hand (bag, closet and worn) every
run, so Philter never lists it either. A drip item whose rule is still on hold
(see `tidy_holdNewDays`) is not listed until the hold ends. The fresh lot is
priced at the market price times your factor (and jitter). Example:

```
Mr. Accessory	1	3
pocket wish	5
```

**About "market price".** KoLmafia deliberately hides the true cheapest listing
from scripts (it is anti-mallbot policy in mafia itself): the price a script can
see is the 5th cheapest. That is what tidy uses. At factor 1.0 you sit at or
above the cheapest sellers and never start a price war. With a factor under 1.0
you list below that number, which may or may not undercut the real cheapest
seller. Your call. It only ever applies to a listing that sits above market:
when you are the cheapest seller, the market figure is your own price, and
tidy leaves it alone.

## Guards

**If you installed before 2026-09-10 evening, `git update`.** Earlier versions
set Philter's simulation switch through a zlib command that silently does
nothing on a mafia where Philter has never been run, so on a brand-new install
the first preview could have run Philter live. tidy now writes Philter's
settings through zlib's own store and reads them back, and refuses to start
Philter if the simulation switch does not read back as on. Found by an
adversarial code review; nobody was hit, because both testers had run Philter
before.

**If you installed before 2026-09-10 night, `git update` again.** The hold on
rules written by a live run, and the store top-ups, counted only your bag,
while Philter counts bag + closet + worn copies. So on the run that wrote a new
rule, Philter could still sell the bag copies if more copies sat in your
closet, and a keep-count MALL rule on an item you were wearing could have its
listing repriced by Philter. Found by a second adversarial review of the merged
fixes; all three counts now match Philter's. The same review found that a
`tidy_priceFactor` under 1.0 cut a listing that was itself the cheapest on the
market 1% under its own price every day; a listing at or under market is now
never cut. And it found that the `.prev` copy was taken before the file was
checked, so the one file the check exists to catch (a rule file saved by an
editor that turned tabs into spaces) overwrote the good backup, and `tidy
revert` then swapped broken for broken. The copy is now taken after the check,
and revert refuses an unreadable copy. Smaller fixes from the same review:
negative or comma-formatted settings no longer switch guards off, the reset
backup expires after your first live run on the new rules, `tidycloset go`
checks for a preview before it empties the closet, and the store-price sanity
check no longer trips on a listing parked at 999,999,999 meat. A third review
found the count still missed equipment on benched familiars; fixed, and tidy
now fetches such copies itself before topping up, so Philter cannot re-list
them at market. Needs KoLmafia r27250 or newer from this version on. The same
review found that the hold released on the calendar alone, so a rule decided
from one bad price sample could sell the next evening with nobody looking; a
held rule now waits for a preview as well. Its smaller findings, fixed in the
same evening: `.prev` is taken on the first write of a run instead of at the
start, so a run that changes nothing no longer moves the undo point; a
keep-count or minimum price that is not a plain number stops the run instead
of being rewritten as 0; live runs are refused under the test suffix; `tidy
help` no longer stops on a broken setting.

- Aftercore only (refuses in Ronin or Hardcore).
- Refuses until Hagnk's has been emptied this ascension (`pull all`).
- Forces Philter's `BaleOCD_EmptyCloset` to -1 so Philter never dumps your closet on its own.
- The first time a run writes your rule file it copies the file as it was to `OCDdata_<name>.prev.txt`, after it has been read and checked; a run that writes nothing leaves the previous copy alone, so `tidy revert` always undoes the last run that changed something. If that copy cannot be written, the run stops before changing anything.
- A rule file that exists but does not parse is never overwritten; tidy stops and tells you. So does a file with lines a rewrite would drop (no tab in the line, an item this KoLmafia does not know, the same item twice) or quietly change (a keep-count that is not a plain number: `x` would become 0 and `5k` would become 5; an empty action; a MALL minimum price that is not a number): tidy names the first such line and changes nothing.
- Live runs are refused while `tidy_rulesSuffix` is set. Philter is pointed at the suffixed file only for the moment it runs and back at your real rule file straight after, so neither Philter nor its Manager is left looking at a test file.
- `tidy help` never stops on a broken setting; it shows the setting as typed and says so.
- `tidy revert` refuses to restore a copy that holds no readable rules.
- A setting that is not a plain whole number (`off`, `-1`, `1,000`, more than 15 digits) stops the run instead of silently becoming 0 and switching a guard off.
- A preview only counts as a preview if Philter's simulation ran to the end.
- Before lowering any price it confirms with a fresh mall search, and never cuts more than `tidy_maxCutPct` in a day.
- A listing already at or under market is never cut, whatever the price factor.
- A rule written by a live run cannot sell in that run, and cannot sell until a preview has run on a later day and listed it with what would sell (`tidy_holdNewDays`). The hold, the store top-ups and the drip keep-counts all count bag + closet + worn copies, the way Philter does. "Worn" includes equipment on every familiar in your terrarium, which Philter counts and will take off them.
- tidy takes a familiar item off a familiar only when a rule you wrote tells Philter to sell copies beyond the keep-count, and only so those copies list at your price; Philter would have taken them anyway. A preview sells nothing, but Philter's own simulation can move such copies into your bag (see DESIGN.md, known limits).
- If a store price cannot be read, a top-up fails, a take-back fails, or any reprice fails, tidy stops before Philter runs.
- Drip listings only ever list items whose rule says MALL.

## What it never does

Nothing leaves your account except through the mall and autosell. No kmail, no
trades, no clan stash, no chat, no buying, no network calls of its own. The only
money-moving calls are put-in-store, reprice, take-from-store, empty-closet,
and Philter. tidy itself only ever writes KEEP, MALL, AUTO and CLST rules;
Philter will also pulverize, use, craft, untinker or display items if a rule
you wrote yourself says so.

That promise covers old rules too. Philter's CLAN action puts items in the clan
stash, GIFT kmails them to another player, and DISC discards them. If your rule
file has any (an old setup often does), tidy turns them into KEEP on every run
and tells you which ones. To let them fire, `set tidy_allowGiving = true`, then `tidy revert` to
put the last batch back.

## Credits

Design notes, including why each default is what it is: [DESIGN.md](DESIGN.md).

Written by Birj (birjeldadge) with Claude, Anthropic's AI assistant, doing the
coding under his direction: Birj set the rules and the ethics, two clanmates
tested and pushed back, Claude wrote and tested the ASH. Built on Philter (LASS)
and OCD Inventory Control (Bale), and Zarqon's zlib. MIT licensed.
