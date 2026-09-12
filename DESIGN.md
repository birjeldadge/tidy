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
   off, live runs refused under the test suffix, a price factor outside 0.5 to
   1.0 refused.
2. First run only: a rule for every inventory item kind, the MALL and AUTO ones
   on hold, nothing sold.
3. If the rule file predates tidy: a one-time notice with counts, including any
   CLAN, GIFT, PULV, DISP, MAKE, USE, UNTN or BREAK rules it inherited.
4. CLAN, GIFT and DISC rules become KEEP (unless `tidy_allowGiving`), each one
   printed.
5. Keep-count check: every MALL, AUTO or CLST rule is raised to its floor, the
   outfit, familiar-equipment or keep-list minimum, or the copies worn by you
   or any familiar plus the closet copies, whichever is higher (previews write
   it too, because Philter's simulation strips worn gear as readily as the
   live run); and copies of outfit pieces, familiar equipment and keep-list
   items come back from the store if fewer than the minimum are on hand.
6. Held rules from earlier runs: a live run releases them, at the higher of
   the decided keep-count and today's floor, if the wait is over and a preview
   has run on a later day, after one fresh price check each; a preview only
   lists them, with what would sell.
7. Rules for new item kinds, using the generator below; the MALL and AUTO ones
   go on hold, in a preview as much as in a live run.
8. Daily reprice of the store (see pricing).
9. Drip listings (see below).
10. Top-ups: for MALL rules on items already in the store, the bag copies above
   the keep-count, counted the way Philter counts (bag + closet + worn,
   terrarium included), go in at your existing price, so Philter finds nothing
   to move for those items. Closet copies count but stay (Philter forces its
   closet setting off while it runs); worn copies sit inside the keep-count
   after step 5, so there is nothing to fetch off you or a familiar, and if a
   rule somehow still sat below its floor the run would stop here.
11. Philter, in simulation for a preview or live for `tidy go`, pointed at
   tidy's rule file for that call only.

Every run that changes the rule file or the hold records keeps the versions it
started from as `.prev` (one copy each), taken together on the first write of
either, after the rule file has been parsed and checked; a run that changes
neither leaves the previous undo point alone. The file is
always rewritten in canonical five-column form because Philter's loader throws
on a rule line that lost its trailing columns. Because that rewrite comes from
the parsed map, any line the parser skipped would vanish and any column mafia
coerces would be rewritten, so a run stops if a non-comment line has no tab,
names an item this KoLmafia does not know, repeats an item, has an empty
action, or carries a keep-count or MALL minimum price that is not a plain
number (mafia reads `x` as 0 and `5k` as 5000; Philter's own loader would have
refused the file).

## The safety model

**Nothing runs live without the word `go`.** A bare `tidy` is the preview. This
was not the original design; the first tester typed `tidy help`, and because
KoLmafia silently drops arguments a `void main()` does not declare, the live
command ran. The fix is a vararg `main(string... args)`, which mafia never
prompts for, and a dispatcher that treats any unknown word as `help`.

**Nothing sells on a rule the same run that wrote it, nor before a human saw
it.** Any run that meets a new item kind (a preview, the first run, the closet
preview, a live run) writes the generator's rule but holds everything on hand
for `tidy_holdNewDays` (default 1). A later run releases it, but only after a
preview has run to the end on a later day than the write: the preview prints
every held rule with what would sell, and that is the look. A chained
`garbo; tidy go`, or `tidy; tidy go` on the same day, with nobody looking keeps
the hold. The fourth review found the hold covered only live-written rules, so
the first run and a same-day `tidy; tidy go` sold on machine decisions. The
fifth found the day was read from the clock at six places, so a preview that
straddled 00:00 UTC recorded itself as a later-day look at its own rules; the
day is now read once per run. Only a live run releases a hold (the eighth
review found a preview could release one on a cached price), and one fresh
search first re-checks the price the decision came from; a rule that now
looks wrong stays on hold; the release also keeps
the keep-count floor of the day (worn plus closet copies), which the seventh
review found it did not. So a spoofed or
transient market price can never turn a new item into a sale before a human
saw the rule. Added after the adversarial review. The hold counts what
Philter counts, bag + closet + worn (on you or on any familiar in the
terrarium), and grows to cover copies picked up while
it lasts; the second review found the first version counted only the bag, so
Philter could still sell the bag copies when more sat in the closet. The hold
is recorded in `data/tidy_hold_<name>.txt` rather than in the rule's message
column: Philter Manager writes an empty message for MALL and AUTO rules on
every save, which erased the marker and left a permanent keep-everything rule
behind. A keep-count changed by hand on a held rule drops the hold, and the
hand-set number stands; a raise tidy itself makes for a keep-list or outfit
count, or for worn and closet copies, is not a hand change. The preview record lives in
`data/tidy_state_<name>.txt` with the reprice day, for the same two reasons a
preference would not do: the test suffix must scope it, and two installs on one
data folder must share it.

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
| Outfit piece, familiar equipment, keep-list item | keep what you can wear (3 accessories, else 1) plus any closet copies, or the listed count; sell extras, unless extras are worth `tidy_keepAbove` or have no mall price | A saved outfit is a statement of intent. Accessories fill three slots. Closet copies satisfy Philter's keep first, so they must sit inside it or the worn copy becomes the extra (a regression the fifth review caught). A 60k extra is a decision, not junk |
| Already in your store | KEEP | You priced it. Flip the rule to MALL and tidy tops it up at your price. The first draft said MALL here and dumped 27,697 items into a curated store |
| In your display case | KEEP | Collections are deliberate |
| Philter's default ruleset says keep | KEEP | Bale's judgement, still good |
| HP/MP restorative | KEEP | Supplies, not junk. Mafia exposes no flag for these to scripts and scripts cannot read the jar's table, so tidy ships mafia's list as `data/tidy_restores.txt` |
| Lazyman rule (`tidy_junkBelow`, off by default) | AUTO if at or under the number and it has an autosell value | The "autosell everything under 1k" hand pass, for people who want it. Off because it is the one setting that sells gear |
| Potion, food, booze, spleen item | KEEP unless `tidy_sellConsumables` | "If you find the need for a potion, it is better to already have it." A trader's words; adopted as the default |
| Gear or reusable tool | KEEP; duplicates under `tidy_keepAbove` beyond what you wear, or could wear, plus your closet copies sell | One of anything wearable is never junk, and the one on your body least of all (two of one weapon dual-wielded count as two) |
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
collapse is followed over several days and a fake one costs at most one step
per day it persists.

Defaults: reprice **down only** (`tidy_reprice = down`), never raise a price
the owner set, never chase a market that collapsed to KoL's floor (100 meat or
twice the autosell value, whichever is higher; a price under it is a daily
no-op), never below that floor or below the rule's own minimum price (Philter
Manager's minimum column), never touch listings above `tidy_protectAbove`
(1,000,000) or parked at 999,999,999+. `both` follows the market either way,
under the same daily cap and with a fresh search before any change; `off`
skips repricing. A preview uses the session's cached prices throughout, and
never releases a hold, so repeated previews do not hammer the mall; the live
run searches fresh, the release check included. The reprice day
lives in `data/tidy_state_<name>.txt`, written before the first change: a
preference would be per mafia install, and two installs on one synced data
folder (a real layout) would each cut once. `tidy_priceFactor` under
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
copies of the rules and the hold records, which a run takes together once, on
its first write of either file, so a revert undoes the whole run and a run
that wrote nothing does not move the undo point. Revert refuses only when
both copies match the current files; a run that only dropped a hold leaves
the rule file identical, and revert then restores the record and leaves the
file as it is. The hold copy starts with a marker line, so revert can tell
"no holds then" (restored as such) from "no copy at all" (a missing or empty
file: an install upgraded from before the copy existed; the records are
kept).
Neither sells anything. A rule file that exists but does not parse is never
overwritten, and the `.prev` copy is taken after that check, not before: the
second review found the old order let the very file the check catches destroy
the last good backup, after which revert swapped broken for broken. Revert now
refuses a copy that holds no readable rules. The dated backup is the revert
target only until the first live run on the fresh rules (after that, revert
undoes the last run), and any revert asks for a fresh preview before the next
`tidy go`, so a rule file resurrected weeks later can never be chained straight
into a live run. The hold records are backed up and restored with the rules in
both paths, and both commands run the guards and write their records before
the destructive step.

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
- The third review's rule-file and backup items, probed under the test suffix:
  a preview with nothing to write left `.prev` absent; a preview that raised a
  held keep-count created `.prev` equal to the file before that run; the next
  preview that changed nothing left it byte-identical; a keep-count of `x`, a
  keep-count of `5k`, a MALL minimum price of `abc` and an empty action each
  stopped the run naming the line, with both files unchanged; `tidy go` under
  the test suffix was refused; a run that stopped early left Philter's data-file
  setting on the real name and a completed suffixed preview put it back; `tidy
  help` ran with a broken setting and said so.
- The pricing items, probed in `both` mode with the protect threshold at 2,000
  meat and factor 1.0: a listing given a minimum price of 130 in the rule file
  was cut to 130 instead of to the 126 market; a drip lot was priced at its
  rule's 5,000 minimum; every raise and every cut in the preview stayed inside
  the 30% daily cap, and the seven listings parked at 999,999,999 were skipped.
  The reprice-day file is live-path code, verified by reading.
- The hold-record and list items, probed under the test suffix: two rules with
  the old message-column marker were moved into the hold file on the next run;
  a hold whose rule had been given a different keep-count by hand was dropped
  with the hand-set number kept; a hold on a rule turned KEEP was dropped; the
  due hold was listed, then released by the following preview; a familiar item
  with keep 0 was reported as "would set keep-N" by the preview and left at 0
  in the file; an inherited GIFT rule kept its kmail text in the note; a keep
  list with "cowbell" and a pin list with "seal-clubbing" refused those lines
  and loaded the exact ones; Philter's simulation switch read `false` again
  after the previews had set it to `true`.
- Fourth review, probed under the test suffix: a first run put every MALL and
  AUTO rule it wrote on hold, and Philter's simulation in that same run sold
  nothing; the preview record landed in the suffixed state file and the real
  one was untouched; a hold whose keep-count tidy itself had raised for a
  familiar item kept its hold with the record updated, while a hand-set count
  dropped it; a hold file with an unreadable line stopped the run before
  anything else; the closet preview put its new MALL/AUTO closet rules on hold;
  a drip lot left the keep-list/outfit minimum on hand; reset and revert went
  through the state file. The worn-gear stop and the familiar-lock stop are
  verified by reading (no worn item sits in the author's store).
- Fifth review, probed under the test suffix: cheap gear with closet copies now
  stays KEEP on a first run instead of "keep 1, sell extras"; with a drip list
  loaded, two previews in a row left `.prev` and the hold records' `.prev`
  untouched; a held MALL rule on an item now worth 280,000 meat stayed on hold
  at release time with the reason printed; `tidy revert` swapped the hold
  records back with the rules; the closet preview converted a worn, untradeable
  item to CLST with a keep-count of 1 and recorded its day in the state file;
  the familiar fetch took a leash off a benched familiar without switching
  familiars. The single clock read is verified by reading.
- Sixth review, probed under the test suffix: a preview ran to the end with an
  empty hold file and again with no hold file (the crash it found); a revert
  straight after a first run was refused; with the lazyman rule on, every AUTO
  rule under 1,000 meat released on the following day instead of staying held;
  the closet preview wrote KEEP for closet items it would keep and marked what
  they become on the live run; a worn item given a MALL keep-0 rule by hand was
  reported for a keep-count raise. The active-familiar gear split and the
  benched-first fetch order are verified by reading.
- Seventh review, probed under the test suffix with four spare leashes put on
  benched familiars (16 on hand, 4 worn): a held rule two days old, previewed
  since, released at keep 4 instead of the decided 1, the preview said 12
  would sell, and Philter's simulation sold the 12 bag copies and unequipped
  nobody, with no mall search in the preview; a keep-count sitting at the
  worn floor above the held count kept its hold instead of being dropped as a
  hand edit; a run that only dropped a hold left the rule file and its `.prev`
  identical, and `tidy revert` restored the record and said the rule file was
  unchanged; with no hold `.prev` at all, revert restored the rules and kept
  the hold records with a notice; a revert straight after a first run was
  refused; a price factor of 0.01 stopped the run and `tidy help` still
  printed; the closet preview wrote 618 rules with no CLST among them, the 34
  skill-granting closet items included. The negative decision price and the
  failed-write hold restore are verified by reading.
- Eighth review, probed under the test suffix with the same four leashes on
  benched familiars: a preview with a MALL keep 2 on the leash (worn 4) wrote
  keep 4 before Philter's simulation ran, the record followed, and nobody was
  unequipped; a due, previewed hold was listed as "releases on the next tidy
  go" and left on file by the preview, with no mall search; the hold copy
  starts with its marker line, and after a run that dropped the last hold two
  reverts in a row restored the record and then the genuine empty state; a
  CLST keep 1 on the worn leash was raised to 4; the pointer notice with a
  stale name offered the zlib line and not the tidy_dataFile one. The
  card-sleeve gate is verified by reading (the author wears no sleeve).
- Ninth review (stricter bar: catastrophic items and regressions only): one
  regression, the closet run leaving worn gear's closet copies in the bag
  under the raised CLST count. The closet preview printed the "for this run"
  re-derivation for a staged CLST rule on the leash; the live half of the
  branch is `tidycloset go` only, refused under the test suffix, and is
  verified by reading.

## Known limits

- Needs KoLmafia r27250 or newer (`equipped_amount(item, true)`, which counts
  equipment on every familiar; git installs with a `manifest.json` root, which
  is how Philter installs as a dependency, came earlier).
- Philter's simulation is not free of side effects: when a rule's keep-count is
  below the number of copies you or your familiars are wearing, Philter's cleanup
  fetches them into your bag (off your familiars and off you) before it checks
  the simulation switch, so a tidy preview can move worn gear into your bag.
  Nothing is sold. tidy writes its keep-count floor for worn gear in every
  run, previews included, before Philter runs, and keeps it at release, so
  neither its own rules nor a hand-written keep-count below the worn count
  reach the simulation with a count under it (the eighth review found the
  preview used to report the raise without writing it, and the simulation
  then stripped the copy the next live run sold).
- A preview that raises a keep-count to the floor writes the rule file, so it
  moves the undo point: `tidy revert` after it undoes that preview's writes;
  a second revert swaps back.
- A CLST keep-count at the floor means "closet every bag copy" of gear you
  wear: "keep N spares out of the closet" cannot be expressed while closet
  copies count toward the keep. The closet run is the one exception, for
  that run only: it lowers such a count to the worn copies (or the keep-list
  count) with no one-copy minimum, so every closet copy of unworn gear goes
  back. The author's first real closet run on the public script found the
  earlier version kept one copy of every protected item out, worn or not,
  because the daily floor sets every such rule to the trigger value; ten
  pieces of unworn familiar gear stayed in the bag. Fixed the same day.
- "N would sell" in a preview is the count at preview time; the live release
  sells the count at that moment, copies picked up in between included. The
  rule is what was looked at, not the number.
- Hold records come in two shapes (with and without the decision price);
  both are read, and a record without a price skips the doubled-price test.
- The "one fresh preview after upgrading" note in the README is advice, not
  enforced: an install whose state file already says a preview ran keeps it.
- A hold record with no decision price (nothing was listed when the rule was
  written, or the record predates the price column) skips the doubled-price
  test at release; the other checks still run.
- Philter's fetch for a card in the card sleeve, a codpiece gem or a holstered
  sixgun cannot be met by an unequip; with mafia's `autoSatisfyWithMall` on
  (off by default) Philter would buy the copy. tidy's floor counts those
  items too, so its own rules never get there.
- A release day costs one fresh mall search per released rule in the live run
  (a preview uses the session cache), a rule that stays held by the price
  check is searched again on each later live run, and a first run costs up to
  one search per item kind; a big first-run release is a slow run.
- Philter also counts items installed in your campground; tidy does not.
  Nothing tidy writes rules for lives there in practice.
- Restoratives come from a snapshot of mafia's `restores.txt`; new restoratives
  need a line added.
- The 5th-cheapest price is the only market signal a script can see.
- Nothing here knows about seasons. Crimbo stock is a KEEP rule you write.
- A day is a UTC calendar day, in the hold and in the reprice record; for US
  evening players a new day starts at 7 or 8 pm. It is read once per run.
- The state and hold files have no lock: two mafia installs writing the same
  file in the same second can lose a write. A sync client that lands another
  install's copy with an identical timestamp can also hand mafia a stale read.
- ASH has no try/finally: a run interrupted by hand while Philter is running
  leaves Philter's simulation switch and file pointer as tidy set them until
  the next completed run puts them back.
- A rule line with fewer than five columns is accepted and completed on the
  next rewrite (a missing keep-count becomes 0). That is deliberate, because
  editors strip trailing tabs and Philter's own loader would refuse the file;
  it also means a line truncated mid-write loses its keep-count.

## Credits and licence

Built on Philter (Loathing Associates Scripting Society, MIT for post-2020 code)
and OCD Inventory Control (Bale), with Zarqon's zlib. tidy itself is MIT.

The code was written by Claude (Anthropic's AI assistant) working under Birj's
direction, in sessions where Birj decided the rules and the pricing ethics and
two clanmates tested each change and reported back. Every change was compiled
and preview-run on Birj's account before it was pushed. If that matters to how
you read the code, now you know.
