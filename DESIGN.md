# tidy: design notes

Why this script exists, why each rule is the way it is, and what has been tested.
For how to use it, see the [README](README.md).

## The problem

Philter (the LASS rewrite of Bale's OCD Inventory Control) is the right tool for
turning a post-farming inventory into meat: a per-item rule file, a relay manager
to edit it, and a whitelist model where an item with no rule is never touched.
Running it every day has three frictions:

1. It stops and asks about every item it has no rule for. After a day of garbo
   that is dozens of new item kinds, and the question is modal.
2. When it adds stock to a listing you already have, KoL applies Philter's price
   to the whole listing, so a hand-set price gets overwritten.
3. Prices go stale. Nothing reprices what is already in your store.

tidy is a thin ASH wrapper that removes those three frictions and adds a safety
model on top. It is not a replacement for Philter; Philter still does every sale.

## What a run does, in order

1. Guards: aftercore only, Hagnk's emptied, Philter's closet-dump setting forced
   off, Philter pointed at this character's rule file.
2. First run only: a rule for every inventory item kind, nothing sold.
3. If the rule file predates tidy: a one-time notice with counts, including any
   CLAN, GIFT, PULV, DISP, MAKE, USE, UNTN or BREAK rules it inherited.
4. CLAN and GIFT rules become KEEP (unless `tidy_allowGiving`), each one printed.
5. Keep-count check: outfit pieces, familiar equipment and keep-list items get a
   keep-count on their MALL/AUTO rules, and copies come back from the store if
   fewer than that are on hand.
6. Rules for new item kinds, using the generator below.
7. Daily reprice of the store (see pricing).
8. Drip listings (see below).
9. Top-ups: for MALL rules on items already in the store, the excess goes in at
   your existing price, so Philter finds nothing to move for those items.
10. Philter, in simulation for a preview or live for `tidy go`.

Every write to the rule file keeps the previous version as `.prev`, and the file
is always rewritten in canonical five-column form because Philter's loader
throws on a rule line that lost its trailing columns.

## The safety model

**Nothing runs live without the word `go`.** A bare `tidy` is the preview. This
was not the original design; the first tester typed `tidy help`, and because
KoLmafia silently drops arguments a `void main()` does not declare, the live
command ran. The fix is a vararg `main(string... args)`, which mafia never
prompts for, and a dispatcher that treats any unknown word as `help`.

**Whitelist only.** Inherited from Philter. No rule, no action.

**Nothing leaves the account except through the mall and autosell.** tidy makes
no network calls of its own, uses no kmail, trade or stash functions, and turns
inherited CLAN and GIFT rules into KEEP by default. Philter can still pulverize,
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

Defaults: reprice **down only** (`tidy_reprice = down`), never raise a price
the owner set, never chase a market that collapsed to the 100 floor, never below
100 meat, never touch listings above `tidy_protectAbove` (1,000,000). `both`
follows the market either way; `off` skips repricing. `tidy_priceFactor` under
1.0 lists under market for people who want the sale first; `tidy_priceJitter`
draws a random factor inside a band per item per day so prices are not a fixed
pattern a rival can read, and listings already inside the band are left alone
so the store does not churn daily. A pin list exempts listings entirely.

## Drip listings

A trader's idea: a listing that keeps refilling tells rivals you have depth, and
they price against you; a small lot that sells out and stays empty for a while
looks like you dried up. `data/tidy_drip_<name>.txt` names items, a lot size,
and an optional number of days to stay empty. tidy lists the lot only when the
store holds none and the days have passed, never tops it up while any are
listed, and sets the rule's keep-count to what is on hand so Philter never lists
the rest.

## Clean sweep and undo

Old Philter or OCD rule files carry decisions their owners no longer remember.
`tidy reset` backs the file up with a date and runs the first-run preview;
`tidy revert` restores that backup, or otherwise swaps in the `.prev` copy.
Neither sells anything.

## What has been tested

- Compile and preview runs on the author's account under a test rule-file
  suffix, for every change.
- Two clanmates as testers: a farmer (1,481 kinds) who completed the first live
  `tidy go` (9 outfit pieces recovered, 328 listings repriced down, Philter
  listed 3.84M meat and autosold 191k, meat delta matched exactly), and a trader
  (7,187 kinds) whose preview and accident shaped most of the defaults above.
- The live path (reprice, take-back, top-up, Philter live) has run once for
  real through the public script. Drip listings have been preview-tested only.

## Known limits

- Needs KoLmafia r26597 or newer (git installs with a `manifest.json` root, which
  is how Philter installs as a dependency).
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
