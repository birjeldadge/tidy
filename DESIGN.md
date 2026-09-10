# tidy: design notes

Why this script exists, why each rule is the way it is, and what has been tested.
For how to use it, see the [README](README.md).

## The problem

Philter (the LASS rewrite of Bale's OCD Inventory Control) is the right tool for
turning a post-farming inventory into meat: a per-item rule file, a relay manager
to edit it, and a whitelist model where an item with no rule is never touched.
Running it every day has three frictions:

1. When it finds items with no rule it stops and asks whether to continue: one
   modal prompt per run, so it cannot be chained unattended after a farming
   script, and the new item kinds stay unsorted until you open the manager.
   Philter's base rule sets cover most of the initial setup; they do not cover
   what you picked up today.
2. When it adds stock to a listing you already have, KoL applies Philter's price
   to the whole listing, so a hand-set price gets overwritten.
3. Prices go stale. Nothing reprices what is already in your store.

tidy is a thin ASH wrapper that removes those three frictions and adds a safety
model on top. It is not a replacement for Philter; Philter still does every sale.
To be fair to the alternatives: Philter's `BaleOCD_MallDangerously` setting
removes the prompt by malling every uncategorized item, which is the opposite
of conservative, and a one-line Philter patch could remove the prompt by
keeping them instead. tidy's difference is that it proposes a reviewed rule for
each new item rather than a blanket answer.

## What a run does, in order

1. Guards: aftercore only, Hagnk's emptied, Philter's closet-dump setting forced
   off, Philter pointed at this character's rule file.
2. First run only: a rule for every inventory item kind, nothing sold.
3. If the rule file predates tidy: a one-time notice with counts, including any
   CLAN, GIFT, PULV, DISP, MAKE, USE, UNTN or BREAK rules it inherited.
4. CLAN, GIFT and DISC rules become KEEP (unless `tidy_allowGiving`), each one
   printed.
5. Keep-count check: outfit pieces, familiar equipment and keep-list items get a
   keep-count on their MALL/AUTO rules, and copies come back from the store if
   fewer than that are on hand.
6. Held rules from earlier live runs: released if the wait is over and a
   preview has run since; otherwise listed, with what would sell.
7. Rules for new item kinds, using the generator below.
8. Daily reprice of the store (see pricing).
9. Drip listings (see below).
10. Top-ups: for MALL rules on items already in the store, everything above the
   keep-count, counted the way Philter counts (bag + closet + worn, terrarium
   included), goes in at your existing price; copies Philter would have fetched
   off familiars (or out of the closet, when mafia may use it) are fetched
   first, so Philter finds nothing to move for those items.
11. Philter, in simulation for a preview or live for `tidy go`.

Every run keeps the version it started from as `.prev`, taken only after the
file has been parsed and checked, and the file is always rewritten in canonical
five-column form because Philter's loader throws on a rule line that lost its
trailing columns. Because that rewrite comes from the parsed map, any line the
parser skipped would vanish, so a run stops if a non-comment line has no tab,
names an item this KoLmafia does not know, or repeats an item.

## The safety model

**Nothing runs live without the word `go`.** A bare `tidy` is the preview. This
was not the original design; the first tester typed `tidy help`, and because
KoLmafia silently drops arguments a `void main()` does not declare, the live
command ran. The fix is a vararg `main(string... args)`, which mafia never
prompts for, and a dispatcher that treats any unknown word as `help`.

**Nothing sells on a rule the same run that wrote it.** A live run that meets a
new item kind writes the generator's rule but holds everything on hand for
`tidy_holdNewDays` (default 1). A later run releases it, but only after a
preview has run to the end on a later day than the write: the preview prints
every held rule with what would sell, and that is the look. A chained
`garbo; tidy go` with nobody previewing keeps the hold. So a spoofed or
transient market price can never turn a new item into a sale before a human
saw the rule. Added after the adversarial review. The hold counts what
Philter counts, bag + closet + worn (on you or on any familiar in the
terrarium), and grows to cover copies picked up while
it lasts; the second review found the first version counted only the bag, so
Philter could still sell the bag copies when more sat in the closet.

**Philter's settings are verified, not assumed.** The `zlib name = value` CLI
command silently refuses a name it has never seen, and Philter only creates its
names on its own first run, so a fresh install could once have previewed with
simulation off. tidy now writes through zlib's own store, reads each value back,
and refuses to start Philter unless simulation reads back as on. Found by the
adversarial review; nobody was hit.

**Whitelist only.** Inherited from Philter. No rule, no action.

**Nothing leaves the account except through the mall and autosell.** tidy makes
no network calls of its own, uses no kmail, trade or stash functions, and turns
inherited CLAN, GIFT and DISC rules into KEEP by default. Philter can still pulverize,
use, craft, untinker or display items if a rule the owner wrote says so; tidy
itself only ever writes KEEP, MALL, AUTO and CLST.

**Conservative generator.** The rule generator's defaults came out of two very
different testers: a farmer with 1,500 item kinds and no old rules, and a mall
trader with 7,000 kinds, a curated store and a Philter file from years ago. For
the trader, the first draft would have listed 1.66 billion meat of stock,
including two 190-million Bookes, because "single copy worth 10k+ stays" only
covered count 1. The defaults below are what survived that review.

## How the generator decides, and why

For an item with no rule, in this order:

| Check | Rule | Why |
|---|---|---|
| Untradeable | KEEP | Nothing to do with it |
| Outfit piece, familiar equipment, keep-list item | keep what you can wear (3 accessories, else 1) or the listed count; sell extras, unless extras are worth `tidy_keepAbove` | A saved outfit is a statement of intent. Accessories fill three slots. A 60k extra is a decision, not junk |
| Already in your store | KEEP | You priced it. Flip the rule to MALL and tidy tops it up at your price. The first draft said MALL here and dumped 27,697 items into a curated store |
| In your display case | KEEP | Collections are deliberate |
| Philter's default ruleset says keep | KEEP | Bale's judgement, still good |
| HP/MP restorative | KEEP | Supplies, not junk. Mafia exposes no flag for these to scripts and scripts cannot read the jar's table, so tidy ships mafia's list as `data/tidy_restores.txt` |
| Lazyman rule (`tidy_junkBelow`, off by default) | AUTO if at or under the number and it has an autosell value | The "autosell everything under 1k" hand pass, for people who want it. Off because it is the one setting that sells gear |
| Potion, food, booze, spleen item | KEEP unless `tidy_sellConsumables` | "If you find the need for a potion, it is better to already have it." A trader's words; adopted as the default |
| Gear or reusable tool | KEEP; cheap duplicates beyond what you can wear sell | One of anything wearable is never junk |
| No mall price | KEEP | Cannot value it, so do not sell it |
| Worth `tidy_keepAbove` or more each (default 10,000) | KEEP, any count | Valuable stock is a decision. This is the rule that would have saved the Bookes |
| Mall price at the 100 floor | AUTO if it has an autosell value, else KEEP | The market is flooded; autosell is the only meat left in it |
| Everything else | MALL | The junk pile |

## Pricing

KoLmafia deliberately hides the true cheapest listing from scripts: its mall
search page is blocked for scripts and `mall_price()` returns the 5th-cheapest
price, by design, to inhibit mallbots that snipe mispriced items. tidy uses that
number and calls it "market". At factor 1.0 a listing sits at or above the
cheapest sellers, so it never undercuts anyone and never starts a price war.

The 5th-cheapest figure counts units, not stores, and includes your own
listing, so one seller dumping six cheap units for an afternoon can define
"market" for a day. Two guards limit the damage: any cut is confirmed with a
fresh search first (the cheap-listing cache is per session, not per day), and
no listing is cut by more than `tidy_maxCutPct` (30%) in one day, so a real
collapse is followed over several days and a fake one costs at most one step.

Defaults: reprice **down only** (`tidy_reprice = down`), never raise a price
the owner set, never chase a market that collapsed to the 100 floor, never below
100 meat, never touch listings above `tidy_protectAbove` (1,000,000). `both`
follows the market either way; `off` skips repricing. `tidy_priceFactor` under
1.0 lists under market for people who want the sale first, but only for a
listing that sits above market: the market figure counts your own units, so
when you are the cheapest seller it is your own price, and the second review
showed a 0.99 factor cutting such a listing 1% a day forever; `tidy_priceJitter`
draws a random factor inside a band per item per day so prices are not a fixed
pattern a rival can read, and listings already inside the band are left alone
so the store does not churn daily. A pin list exempts listings entirely.

## Drip listings

A trader's idea: a listing that keeps refilling tells rivals you have depth, and
they price against you; a small lot that sells out and stays empty for a while
looks like you dried up. `data/tidy_drip_<name>.txt` names items, a lot size,
and an optional number of days to stay empty. tidy lists the lot only when the
store holds none and the days have passed, never tops it up while any are
listed, and sets the rule's keep-count to what is on hand (bag + closet + worn)
so Philter never lists the rest. A rule that is still on hold is skipped.

## Clean sweep and undo

Old Philter or OCD rule files carry decisions their owners no longer remember.
`tidy reset` backs the file up with a date and time and runs the first-run
preview; `tidy go` is then refused until the owner has run a plain preview and
looked. `tidy revert` restores that backup, or otherwise swaps in the `.prev`
copy, which every run takes once at its start so a revert undoes the whole run.
Neither sells anything. A rule file that exists but does not parse is never
overwritten, and the `.prev` copy is taken after that check, not before: the
second review found the old order let the very file the check catches destroy
the last good backup, after which revert swapped broken for broken. Revert now
refuses a copy that holds no readable rules. The dated backup is the revert
target only until the first live run on the fresh rules (after that, revert
undoes the last run), and any revert asks for a fresh preview before the next
`tidy go`, so a rule file resurrected weeks later can never be chained straight
into a live run.

## What has been tested

- Compile and preview runs on the author's account under a test rule-file
  suffix, for every change.
- Two clanmates as testers: a farmer (1,481 kinds) who completed the first live
  `tidy go` (9 outfit pieces recovered, 328 listings repriced down, Philter
  listed 3.84M meat and autosold 191k, meat delta matched exactly), and a trader
  (7,187 kinds) whose preview and accident shaped most of the defaults above.
- The live path (reprice, take-back, top-up, Philter live) has run once for
  real through the public script. Drip listings have been preview-tested only.
- An adversarial review (a fresh reviewer with the repo, the KoLmafia source,
  and the brief "look for catastrophic failure and future footguns") produced
  six catastrophic and six recoverable findings. All twelve are fixed and each
  fix was probed on the author's account: verified Philter settings, the
  one-day hold on live-written rules, the per-day cut cap with a fresh search
  before any cut, timestamped reset backups, the unparseable-file guard, DISC
  neutralising, strict whole-number settings, run-start `.prev` snapshots, a
  closet preview that changes nothing, drip limited to MALL rules, and a stop
  before Philter on any failed mafia call.
- A second adversarial review of the merged fixes, same brief, graded the twelve
  earlier findings (eight closed, four partial) and found three more catastrophic
  cases. The first, fixed next: holds and top-ups counted only the bag while
  Philter counts bag + closet + worn. Probed on the author's account under the
  test suffix: a held rule's keep-count rose from 2 to 197 (2 in the bag, 195 in
  the closet) and Philter's simulation left the item alone; a drip item on hold
  was skipped; a top-up with one copy in the closet sent 2 instead of 1; and a
  control rule with keep 1 on an item with 135 closet copies showed Philter
  selling the bag copy, which is exactly what the fix guards against.
- The second finding, the self-undercut: with factor 0.99 and the protect
  threshold set to 150 meat for the probe, 234 of the author's cheap listings
  qualified for a cut under the old logic and 224 of them sat exactly at market
  (his own listing was the market); the new logic cut 10, all above market, and
  left the 224 alone. The preview's counts matched a read-only probe of the
  same listings.
- The third finding, the backup order, probed with copies of the author's
  803-rule file under the test suffix: a fully mangled file (tabs to spaces)
  stopped the run and left `.prev` byte-identical to the good copy; `tidy
  revert` refused a mangled `.prev` and changed neither file; a file with one
  tab-less line, one unknown item and one duplicated item stopped before any
  write, both files unchanged; a good file still previewed and reverted.
- The review's quick wins, probed the same way: `tidy_holdNewDays` set to
  `-1`, `1,000` and a 20-digit number each stopped the run with the setting
  named, and `2` ran; `tidy revert` printed its new notice and cleared the
  preview flag; the closet preview still runs and leaves exactly one `.prev`.
  The closet live gate (a plain preview is now required before the closet is
  emptied) and the 999,999,999,999 unknown-price sentinel were verified by
  reading the code and mafia's source, not by a live run.
- Third review, first finding: Philter's count includes equipment on benched
  familiars (mafia's accessible count adds every familiar's equipment), and its
  cleanup fetches those copies off the familiars before selling, even in
  simulation: a simulated run on the author's account printed "Unequip Angry
  Goat / Leprechaun / Levitating Potato". Probed with a familiar item worn by
  four benched familiars: a held rule's keep-count rose from 12 (the bag) to
  16; a keep-1 top-up planned 15 copies with 3 fetched off familiars first; the
  fetch helper, run live, took the copies off and returned the active familiar
  with its own gear untouched.
- Third review, second finding: the hold released on the calendar alone.
  Probed with three held rules under the test suffix: two past the wait and one
  inside it. With no preview recorded, a preview listed all three with what
  would sell and released none; the next preview, one day-number later in the
  record, released the two that were due (one of them familiar equipment,
  released at keep 1 rather than the old decision of 0) and kept the third; a
  revert cleared the preview record again.

## Known limits

- Needs KoLmafia r27250 or newer (`equipped_amount(item, true)`, which counts
  equipment on every familiar; git installs with a `manifest.json` root, which
  is how Philter installs as a dependency, came earlier).
- Philter's simulation is not free of side effects: when a rule's keep-count is
  below the number of copies on your familiars, Philter's cleanup fetches them
  into your bag before it checks the simulation switch, so a tidy preview can
  move familiar equipment into your bag. Nothing is sold.
- Philter also counts items installed in your campground; tidy does not.
  Nothing tidy writes rules for lives there in practice.
- Restoratives come from a snapshot of mafia's `restores.txt`; new restoratives
  need a line added.
- The 5th-cheapest price is the only market signal a script can see.
- Nothing here knows about seasons. Crimbo stock is a KEEP rule you write.

## Credits and licence

Built on Philter (Loathing Associates Scripting Society, MIT for post-2020 code)
and OCD Inventory Control (Bale), with Zarqon's zlib. tidy itself is MIT.

The code was written by Claude (Anthropic's AI assistant) working under Birj's
direction, in sessions where Birj decided the rules and the pricing ethics and
two clanmates tested each change and reported back. Every change was compiled
and preview-run on Birj's account before it was pushed. If that matters to how
you read the code, now you know.
