# tidy daily markdown ("refresh stale listings") review, 2026-11-04

**Status: review done; two stop-gaps applied on the author's go, 2026-11-04
about 14:35: `tidy_reprice` set to `off` (it was unset, so `down`), and
`vitachoconutriment capsule` with keep 4 added to `data\tidy_keep_Birj.txt`
(backup `tidy_keep_Birj.before-capsule-1104.txt`). The fix below is built on
branch `fix/reprice-anchor` (see DESIGN.md, Pricing).** Nothing in tidy's code, in the rule file or in the
store was changed. Code reviewed: tidy main
`2675596` (the installed copy in `Kolm\scripts` is byte-identical). KoLmafia
behaviour was checked against the mafia source on GitHub `main` as read on
2026-11-04 (the jar here is r29408; the mall-price code is old and stable, but
this is `main`, not the r29408 tag). Live facts were read through the relay
after the author finished playing: one store refresh, four mall searches, nothing
written. Session logs are `Kolm\sessions\Birj_YYYYMMDD.txt`.

Trigger: a clanmate pointed out that Birj was buying vitachoconutriment
capsules from their store (CONSUME, high value of adventure) while selling
his own for far less.

## The answer

The markdown step does exactly what it was built to do, and what it was built
to do loses meat. Four faults, all verified:

1. **It is a one-way ratchet.** It follows every dip in the market down (up
   to 30% a day, day after day) and never comes back up. Over weeks every
   listing drifts to the lowest point the market ever touched and stays there
   when the market recovers. The capsule went 434,999 to 295,000 in four cuts
   (Oct 4 to 12) while a few sellers sat at 290k to 300k; by Oct 30 those
   sellers were gone and the market was back at 440k to 450k; tidy did nothing,
   because "never raise a price you set" (`tidy_common.ash:799`). After the
   first cut the price is tidy's, not yours, but tidy has no memory of that.
2. **The market figure counts your own listings.** mafia's `mall_price()` is
   the price of the 5th-cheapest unit in the mall, counting per-buyer limits,
   and your own store is just another store in that count
   (`MallPriceManager.java:147-148, 439-457`; `MallSearchRequest.java:375-417`
   adds every store, your own included; it is only coloured blue in the relay,
   `:588-596`). So once the ratchet has made your stack the cheapest, the
   "market" IS your price and the tool goes blind: it cannot see that everyone
   else is higher. Live, right now: your 15 capsules at 450,000 are the only
   ones under 650,000 (next sellers: 2 @ 650,000, 9 @ 989,998, 13 @ 990,000),
   and mafia's market price for the capsule is 450,000, which is you. CONSUME
   paid 650,000 for one today. Store-wide, 1,110 of your 1,565 live listings
   sit exactly at mafia's cached market price; 514 of those hold 5 or more
   units, so for them the figure is probably you. The README and DESIGN state
   this fact and call it harmless; it is the reason `tidy_reprice = both`
   could not have recovered the capsule either.
3. **"Fresh search before any cut" does not happen.** `mall_price(item, 0.0)`
   does not force a search: with `maxAge = 0` it skips the shared price file
   and returns mafia's session cache (`MallPriceManager.java:633-648`, then
   `:498-513`, which only searches when the cache has nothing). That cache is
   filled at login from the shared price file, every entry stamped with the
   download time (`MallPriceDatabase.java:61-108`, `LoginManager.java:131`;
   8,458 of the 8,539 entries in `data\mallprices.txt` carry one timestamp,
   12:54 today). On 2026-11-01 the morning preview, the live run and the
   evening preview made zero mall searches between them (log lines 67092 to
   68197 and 119458 to 119870). Live today, `mall_price(it, 0.0)` returned the
   cached number before and after a real search. The cached numbers are
   usually right but not always: of 307 purchases on Nov 3 and 4, 45 paid more
   than the cached figure (stale low), and stale-low is exactly the direction a
   down-only repricer acts on. The code comments at `:782-784`, the README
   ("the live run searches fresh before it changes anything") and DESIGN
   ("any cut is confirmed with a fresh search first") are wrong.
4. **Big stacks at a ratcheted price are a gift to resellers.** The 125 Red
   Pills were cut 111,110 to 82,500 (Sep 14 to Oct 26) and are now sold out;
   the 5th-cheapest Red Pill today is 240,000 (ladder: 1 @ 165,000, 19 @
   240,000, 25 @ 245,000). Seven epic wads cut to 273,743: sold out, market
   450,000. Three Dreadsylvanian spooky pockets cut to 291,111: sold out,
   market 439,000. One Hunger Sauce cut to 230,000: sold out, market 493,000.
   When they sold, and at what market, the logs cannot say; that they are gone
   and where the market is now, the live search can.

The business context makes it worse. The Lost Pill Bottles (969 bought since
Sep 1 for 53.5M meat) are what produce the capsules, Red Pills and the rest:
the pills are your product, and tidy sells the product at the ratcheted price.
Meanwhile CONSUME buys the same capsule at market (about 44 in October and
November, 444,444 on Nov 1 to 3, 650,000 today), because a script can never buy
from its own store. The capsule rule is `MALL keep 0`, so every capsule the
bottles yield goes to the store instead of into tomorrow's diet.

## How wide

- Public tidy, Sep 11 to today: 1,357 listings cut, 7,077 cuts (no duplicate
  log lines; checked). Last two weeks: 117 to 382 listings cut per live run.
- 412 of those listings sat under mafia's cached market at the time of the
  tally, 153 by more than 20%, with a cached gap of 30.7M meat. Cache-based, so
  some entries are stale; the five live checks above are the proof the pattern
  is real, and four of the five had already sold out.
- Live snapshot today (cache only, no searches): 14 listings under the cached
  market, nearly all by a few meat; the two big gaps are hand-priced items above
  the 1M guard (electronic dulcimer pants 2.2M vs 14.5M cached, parasitic
  tentacles 2M vs 5M cached) and are yours to check, not tidy's.
- Of the 1,357 cut listings, 670 are still in the store at tidy's last price,
  559 are sold out or gone, 128 have since been changed by hand. Putting the
  670 back to their pre-cut prices would be 31.6M meat of listed value; the
  real repair (capped by what other sellers charge today) is less, and needs
  one real search per listing. The three biggest, live-searched today:
  sturdy Crimbo crate, 27 units, 650,000 in September walked down to 149,995
  over 36 cuts; 135 units from other sellers sit at 149,991, so that fall was
  real (a seasonal item the README says to KEEP by hand, which nobody did).
  Marvin's marvelous pill, 1,280 units (a pill-bottle product), 5,775 to 1,500
  over 11 cuts; live ladder 5 @ 1,250, then your 1,280 @ 1,500, then 2,450
  and 2,500: your stack is the market and the other sellers sit 1,000 higher,
  the capsule pattern again (1.3M on the stack). electric Kool-Aid, 12 units,
  896,942 to 700,000; the 5th-cheapest is 696,969, so that one is simply at
  market. The repair, then, is worth doing only where a stack of yours is the
  cheapest, which the search tells.

### The capsule, dated (verified from the logs)

| Date | Event |
|---|---|
| Sep 9, 12 | tidy matches the market: 440,000 to 435,000 to 434,999 (7 in store) |
| Oct 2 | CONSUME buys at 400,000 |
| Oct 4, 8, 10, 12 | tidy cuts 434,999 to 400,000 to 335,000 to 300,000 to 295,000 (18 in store) |
| Oct 20 to 28 | CONSUME buys at 295,000, 295,000, 290,000, 300,000 from three other stores (yours, at 295,000, is invisible to your own buying) |
| Oct 30 to Nov 3 | CONSUME buys at 440,000, 444,000, 444,444, 444,444, 444,444; your 18 sit at 295,000; tidy never raises |
| Nov 4 | CONSUME buys at 650,000. Live: 15 in store at 450,000 (tidy cannot raise, so this was a hand change at some point; inferred), the next seller at 650,000 |

## What to change (the proposal; built as `fix/reprice-anchor`)

0. **Keep what you eat (config, no code).** Add `vitachoconutriment capsule`
   with a count of 4 to `data\tidy_keep_Birj.txt`. CONSUME wants 1 or 2 a day
   and takes them from the bag before buying; the bottles yield about 0.6 a
   day. The other diet items the bottles produce (synthetic dog hair pill,
   distention pill, bitter pill) are already KEEP; mojo filters never sit in
   the bag at tidy time.
1. **Stop the ratchet today, one command:** `set tidy_reprice = off` until the
   fix ships. Cost: a listing the market really left behind sits unsold for a
   few days. Nothing else changes (top-ups, Philter, holds all run as now).
2. **Remember your price (the anchor).** tidy records, per listing, the last
   price it set (`data\tidy_price_<name>.txt`). When the listing's price is not
   the one tidy set, you changed it, and that becomes the anchor. Target =
   the lower of the anchor and market times the factor, never under KoL's
   floor or the rule's minimum. `down` then means "down to market, and back up
   to your price when the market recovers"; it never goes above what you set.
   `both` keeps following the market above the anchor; `off` is unchanged.
3. **Market means other sellers.** At the start of a run tidy adds your own
   player id to mafia's `forbiddenStores` preference (and removes it at the
   end, the way it handles Philter's settings). Forbidden stores are left out
   of the 5th-cheapest count (`MallPurchaseRequest.java:186-188`,
   `MallPriceManager.java:439-457`), and mafia never buys from your own store
   anyway (`MallPurchaseRequest.java:332-334`), so nothing else changes. With
   that, "at or under market" means "at or under the other sellers", and the
   raise in step 2 has a real target. Verified in source, not yet tested live.
4. **A real search before any change.** For each listing the live run is about
   to cut or raise, run the CLI `searchmall "<exact name>"` first; a search
   refreshes mafia's cached price (`MallSearchRequest.java:189-190`, confirmed
   live today). The preview keeps using cached numbers and says so. That is
   roughly 100 to 400 searches on a busy day; CONSUME and garbo already make
   about 240. The same search goes in front of a drip lot and a hold release,
   which use the cached number today.
4b. **Never below what you paid.** tidy reads your last N days of session log
   (`session_logs()`) for "buy ... for P each" lines and treats the highest
   recent price paid as a floor for that item: no cut, no top-up and no drip
   lot below it. That is the direct guard against buying high and selling low,
   whatever the market signal says.
5. **Slow down, fast up.** Cuts stay capped per day (30% now; 20% is worth
   considering). Raises go straight to the target. Reason: a wrong high price
   delays a sale, a wrong low price gives the meat away, so the two directions
   should not be symmetric.
6. **Stack guard (your call).** Skip the daily cut on any listing whose units
   times price is above a new `tidy_protectStack` (say 5,000,000). A 125-unit
   stack would then never be marked down unattended; the 1M guard today is per
   unit and did not cover the Red Pills.
7. **One-time repair.** For every listing tidy cut since Sep 11 that is still
   in the store, set the price to the lower of its pre-cut price (from the
   logs) and the other-sellers market (one real search each). Shown as a list
   first, run only on your go.
8. **Docs.** Correct the README, DESIGN and the comments at
   `tidy_common.ash:58-59, 743, 782-784, 800-801`: the fresh-search claim, the
   own-units explanation, what `both` can and cannot do, "listings" where it
   means units, and the `historical_age` test at `:785` and `:789` that
   measures the shared file's entry, not the session cache.

What stays as it is: KoL's floor, the rule's minimum price, the 1M per-unit
guard, parked prices (999,999,999+), the pin list, the preview/live split, the
"never cut a listing already at or under market" guard, the daily cap on cuts,
and the reprice-day record.

## Not verified, or out of reach

- When the Red Pills, epic wads, spooky pockets and Hunger Sauce sold, and at
  what market on that day. Only that they are gone and what the market is now.
- The real observation times behind the shared price file (one stamp on 8,458
  entries). The capsule figure is corroborated by your own purchases.
- Who set the capsule to 450,000 and when. mafia's session log does not record
  price changes made in the relay.
- The forbidden-store lever and the CLI-search refresh are verified in source
  and (the refresh) in one live check; the full design has not been built or
  tested.
- Philter prices a brand-new listing at the same cached market figure. That is
  Philter's behaviour, outside tidy, and the keep-list step above is the only
  cover for it.

## Second reader

A fresh reviewer, briefed with the code, the mafia sources, the logs and the
clanmate's complaint but not with the findings above, read it all
independently (61 tool calls; it noticed this draft in the working tree late
and states its evidence is its own). It reached the same four faults with the
same source lines, and ranked them the same way. What it added:

- **A cost floor from your own buying.** tidy can read your session log
  from ASH (`session_logs(days)`, `RuntimeLibrary.java:5294`), so it can know
  what you paid for an item in the last N days and refuse to cut a listing, or
  top one up, below that. On Oct 8 tidy cut the capsule to 335,000 the day
  after you had paid 350,000 for one. Folded into the proposal as step 4b.
- **The drip and hold-release paths run on the same cached number.** Drip lots
  (`tidy_common.ash:874`) are priced on it with no cap and no memory: the 50
  evil golden arches were relisted at about 10,000 four times (Sep 22 to Oct
  19), so a dip on relist day sends all 50 in at the dip. The hold release
  (`:1471`) compares the cached price with the decision price that came from
  the same cache, so its "market has moved" guard cannot fire. Low stakes
  today; the real-search step covers both.
- **Two more wrong claims.** `tidy_common.ash:785` and `:789` use
  `historical_age(it) < 1` to decide the cached price is fresh; that is the age
  of the shared-file entry (`MallPriceDatabase.java:267-271`), not of the
  session cache. The comment at `:743` says the five cheapest listings; it is
  units, counting limits.
- **A reduction tally.** From Oct 1 to Nov 4, 3,972 live cuts on 1,033 items
  took 38.5M meat off asking prices (58M since Sep 1): the sum of each cut's
  drop times the units listed, so a measure of how far the ratchet walked, not
  of meat lost.
- **One open question, since answered.** Nothing in `KoLmafia.java` or
  `LoginManager.java` clears the session price cache at login, so if the mafia
  process stayed up across days, a price it searched days ago would stay until
  a purchase flushed it. The author closes mafia every day (to sync the Drive
  folder) and a PowerShell script updates it daily, so the cache is at most a
  day old here.
- It also saw 20 upward reprice lines, all on Sep 8 (the private version, before
  the public tidy existed); not a loss path.

Its scripts are in the session scratchpad (`review-agent\timeline.py`,
`review-agent\cuts.py`); it changed nothing in the repo or the data.
