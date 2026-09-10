// tidy_common.ash  --  shared code for the tidy commands (KoLmafia, aftercore).
//
//   tidy            PREVIEW: writes rules for new item kinds (so you can review them), prints what a
//                   live run would do, sells nothing
//   tidy go         LIVE: rules for new item kinds, store top-ups at your prices, daily reprice, then Philter
//   tidy reset      clean sweep: backs up the rule file, then the first-run preview writes fresh rules (sells nothing)
//   tidy revert     undo the last change tidy made to the rule file (swap with the .prev copy; run again to swap back)
//   tidy help       prints the commands and settings, does nothing else (so does any other word)
//   tidycloset      PREVIEW: writes rules for closet items that lack one, tallies, moves nothing
//   tidycloset go   LIVE, one-off: empties the closet into inventory and runs the tidy pipeline
//   tidysim / tidyclosetsim   older names for the two previews, still work
//
// Why a wrapper around Philter:
//   1. Philter asks a blocking question when it meets an item with no rule.
//      tidy writes a sensible rule first, so it never has to ask.
//   2. Philter lists MALL items at the market price, and KoL applies that price
//      to the whole listing. Anything already in your store is topped up here,
//      at the price you set, before Philter runs. Philter then finds nothing
//      left to move for those items.
//   3. Once per KoL day, any listing priced at or under tidy_protectAbove
//      (default 1,000,000 meat) that sits above KoLmafia's market price is
//      lowered to it. That price skips the five cheapest listings, so it never
//      undercuts anyone. By default it never raises a price you set, never
//      chases a market that collapsed to the 100-meat floor, and never goes
//      below 100 meat. Listings above the threshold are your hand-set prices
//      and are left alone. No price duels.
//
// Rule logic for new kinds (decide): untradeable, gear, tools, display-case items
// and rare singles stay; floor-priced junk is autosold; everything else goes to
// the mall. Review the generated rules in Philter Manager any time.
//
// Settings (KoLmafia preferences, set with: set tidy_protectAbove = 5000000):
//   tidy_keepAbove      new item kinds priced at or above this each start as KEEP, whatever the count (unset = 10000; 0 = off)
//   tidy_reprice        down (default: never raise a price, never chase a market that collapsed to the floor) | both | off
//   tidy_protectAbove   listings priced above this are never repriced (unset = 1000000; 0 = off, reprice everything)
//   tidy_junkBelow      off (default): the lazyman rule. Set to e.g. 1000 and new item kinds with a mall price at or
//                       below that and an autosell value start as AUTO, gear and consumables included. Protected classes still win.
//   tidy_sellConsumables false (default): potions (usable, grants an effect), food, booze, spleen items with no rule start as KEEP
//   tidy_allowGiving    false (default): rules that say CLAN (clan stash), GIFT (kmail) or DISC (discard) are turned into KEEP every run
//   tidy_maxCutPct      30: the most the daily reprice may cut one listing in one day, as a percent of its current price
//   tidy_holdNewDays    1: a live run writes rules for new item kinds but holds them this many days before they can sell (0 = off)
//   tidy_priceFactor    multiply the market price by this when repricing (default 1.0 = match market;
//                       0.99 = list 1% under the market price to get the sale first; never below 100 meat)
//   tidy_priceJitter    random spread around the factor (default 0). 0.01 with factor 0.99 draws a factor
//                       between 0.98 and 1.00 per item per day; a listing already inside that band is left alone.
//   tidy_rulesSuffix    testing only: use OCDdata_<name><suffix>.txt instead of your real rules
// Optional file data/tidy_keep_<name>.txt, one "item name<TAB>count" per line:
//   those items always keep at least that many copies on hand (MALL/AUTO rules are patched).
// Optional file data/tidy_pin_<name>.txt, one item name per line:
//   those store listings are never repriced (hand-set prices, "keeping an eye on it" listings).
// Optional file data/tidy_drip_<name>.txt, one "item name<TAB>count<TAB>days" per line (days optional):
//   list that many only when your store holds none of it and it has been empty that many days; never
//   top up while any are listed; the rest stays in inventory (tidy sets the rule's keep-count to match).
//   Rivals see a small stock that runs dry, not a deep one, so they price against you less.

since r26597;   // git checkout honours manifest.json root_directory (needed to install Philter automatically)

import "zlib.ash";

record OCDinfo {
	string action;
	int q;
	string info;
	string message;
};

record Decision {
	string action;
	int q;
	string why;
};

string DATA_NAME = my_name() + get_property("tidy_rulesSuffix");
string RULES_FILE = "OCDdata_" + DATA_NAME + ".txt";
string BACKUP_FILE = "OCDdata_" + DATA_NAME + ".prev.txt";
string KEEP_FILE = "tidy_keep_" + DATA_NAME + ".txt";
string PIN_FILE = "tidy_pin_" + DATA_NAME + ".txt";

// A whole-number preference. Unset = the default. Anything that is not plain digits stops the run:
// a typo like "off" or "1e6" must never silently become 0 and switch a guard off.
int pref_int(string name, int dflt) {
	string s = get_property(name);
	if (s == "") return dflt;
	if (!is_integer(s)) abort("tidy: " + name + " is set to '" + s + "', which is not a whole number. Fix it with: set " + name + " = " + dflt + " (or a number). Nothing done.");
	return s.to_int();
}
// Listings priced above this are never repriced. Unset = 1,000,000. 0 = off (everything gets repriced).
int protect_above() {
	int p = pref_int("tidy_protectAbove", 1000000);
	return p > 0 ? p : 0;
}
float price_factor() {
	float f = get_property("tidy_priceFactor").to_float();
	return (f > 0.0 && f <= 1.0) ? f : 1.0;
}
// New item kinds priced at or above this per copy start as KEEP, whatever the count. Unset = 10,000. 0 = off.
int keep_above() {
	int p = pref_int("tidy_keepAbove", 10000);
	return p > 0 ? p : 0;
}
// The lazyman rule. Off unless set above 100. When on, any new item kind with a mall price at or
// below this and an autosell value starts as AUTO, gear and consumables included. Outfit pieces,
// keep-list items, store and display-case items, restoratives and untradeables stay protected.
int junk_below() {
	int j = pref_int("tidy_junkBelow", 0);
	return j > 100 ? j : 0;
}
// Biggest price cut the daily reprice may make in one day, as a percentage of the current price.
// A transient dump of a few cheap units must not drag a listing to the floor in one run.
int max_cut_pct() {
	int c = pref_int("tidy_maxCutPct", 30);
	if (c < 1) c = 1;
	if (c > 100) c = 100;
	return c;
}
// New item kinds found during a LIVE run are written with their rule but held for this many days
// before they can sell, so a rule nobody has looked at never sells in the run that created it.
int hold_new_days() {
	int d = pref_int("tidy_holdNewDays", 1);
	return d < 0 ? 0 : d;
}
int today_number() { return now_to_int() / 86400000; }
// While false (default), potions, food, booze and spleen items with no rule start as KEEP.
boolean sell_consumables() { return get_property("tidy_sellConsumables") == "true"; }
boolean is_consumable(item it) {
	return it.fullness > 0 || it.inebriety > 0 || it.spleen > 0 || (it.usable && effect_modifier(it, "Effect") != $effect[none]);
}
// Daily reprice mode: "down" (default: never raise a price, never chase a collapsed market to the floor),
// "both" (move to market in either direction), "off" (never reprice).
string reprice_mode() {
	string m = to_lower_case(get_property("tidy_reprice"));
	if (m == "both" || m == "off") return m;
	return "down";
}
// Listings you never want repriced (data/tidy_pin_<name>.txt, one item name per line).
boolean [item] load_pin_list() {
	boolean [item] p;
	string text = file_to_buffer(PIN_FILE).to_string();
	if (text.length() == 0) return p;
	foreach i, line in text.split_string("\n") {
		string name = line;
		if (name.ends_with("\r")) name = name.substring(0, name.length() - 1);
		if (name.length() == 0 || name.starts_with("#")) continue;
		item it = name.to_item();
		if (it != $item[none]) p[it] = true;
		else print("tidy: pin list line not an item, ignored: " + name, "red");
	}
	return p;
}
boolean [item] PIN_LIST = load_pin_list();

float price_jitter() {
	float j = get_property("tidy_priceJitter").to_float();
	return (j > 0.0 && j < 1.0) ? j : 0.0;
}
// The band a listing may sit in: factor - jitter .. factor + jitter, never above 1.0, never below 100 meat.
int band_low(int mkt) { float lo = price_factor() - price_jitter(); if (lo < 0.01) lo = 0.01; int p = floor(mkt * lo); return p < 100 ? 100 : p; }
int band_high(int mkt) { float hi = price_factor() + price_jitter(); if (hi > 1.0) hi = 1.0; int p = floor(mkt * hi); return p < 100 ? 100 : p; }
// A fresh price for a listing: a random point in the band (or exactly the factor when jitter is 0).
int target_price(int mkt) {
	if (price_jitter() == 0.0) { int p = floor(mkt * price_factor()); return p < 100 ? 100 : p; }
	int lo = band_low(mkt); int hi = band_high(mkt);
	if (hi <= lo) return lo;
	return lo + random(hi - lo + 1);
}

// Drip listings (data/tidy_drip_<name>.txt): item, count to list at a time, days to stay empty first.
record DripSpec {
	int n;
	int days;
};
string DRIP_FILE = "tidy_drip_" + DATA_NAME + ".txt";
string DRIP_STATE_FILE = "tidy_drip_state_" + DATA_NAME + ".txt";   // real day number each drip listing was first seen empty
DripSpec [item] load_drip_list() {
	DripSpec [item] d;
	string text = file_to_buffer(DRIP_FILE).to_string();
	if (text.length() == 0) return d;
	foreach i, line in text.split_string("\n") {
		string s = line;
		if (s.ends_with("\r")) s = s.substring(0, s.length() - 1);
		if (s.length() == 0 || s.starts_with("#")) continue;
		string [int] f = s.split_string("\t");
		item it = f[0].to_item();
		if (it == $item[none]) { print("tidy: drip list line not an item, ignored: " + s, "red"); continue; }
		DripSpec spec;
		spec.n = (count(f) > 1) ? f[1].to_int() : 1;
		spec.days = (count(f) > 2) ? f[2].to_int() : 0;
		if (spec.n < 1) spec.n = 1;
		if (spec.days < 0) spec.days = 0;
		d[it] = spec;
	}
	return d;
}
DripSpec [item] DRIP_LIST = load_drip_list();

int sale_price(item it) {
	if (historical_age(it) < 1 && historical_price(it) > 0) return historical_price(it);
	return mall_price(it);
}

// HP/MP restoratives are supplies, not junk. Mafia knows them (data/restores.txt inside the jar) but
// scripts cannot read the jar, so tidy ships a copy as data/tidy_restores.txt (item name, tab, hp|mp|both).
string [string] load_restores() {
	string [string] raw; string [string] r;
	file_to_map("tidy_restores.txt", raw);
	foreach k, v in raw { r[k] = v; r[entity_decode(k)] = v; }   // mafia item names carry entities (Pok&euml;mann); accept both forms
	return r;
}
string [string] RESTORES = load_restores();
boolean is_restorative(item it) { return RESTORES contains it.name; }

boolean is_tool_type(item it) {
	string t = item_type(it);
	return t.contains_text("reusable") || t.contains_text("grow") || t.contains_text("sticker")
		|| t.contains_text("card") || t.contains_text("folder") || t.contains_text("spur")
		|| t.contains_text("skin") || t.contains_text("avatar") || t.contains_text("message")
		|| t.contains_text("zap");
}
// How many of a piece of gear you can wear at once: three accessory slots, one of anything else.
int gear_slots(item it) { return it.to_slot() == $slot[acc1] ? 3 : 1; }

// Always keep one of every piece of a saved custom outfit (three for accessories) and one of
// every familiar equipment item. Extras may sell; the last copy never does.
boolean [item] outfit_piece_set() {
	boolean [item] s;
	foreach i, o in get_custom_outfits() {
		foreach j, it in outfit_pieces(o) { if (it != $item[none]) s[it] = true; }
	}
	return s;
}
boolean is_protected_gear(item it, boolean [item] pieces) {
	return it.to_slot() == $slot[familiar] || (pieces contains it);
}
// Your own keep list (data/tidy_keep_<name>.txt), if you have one.
int [item] load_keep_list() {
	int [item] k;
	file_to_map(KEEP_FILE, k);
	return k;
}
int [item] KEEP_LIST = load_keep_list();
// Minimum copies to keep on hand: keep-list items keep their listed count,
// outfit pieces and familiar equipment keep as many as you can wear (3 for accessories, else 1), everything else 0.
int protect_min(item it, boolean [item] pieces) {
	if ((KEEP_LIST contains it) && KEEP_LIST[it] > 0) return KEEP_LIST[it];
	if (is_protected_gear(it, pieces)) return gear_slots(it);
	return 0;
}
int on_hand(item it) { return item_amount(it) + closet_amount(it) + equipped_amount(it); }

string rule_line(item it, string action, int q, string info, string message) {
	return "[" + it.to_int() + "]" + it.name + "\t" + action + "\t" + q + "\t" + info + "\t" + message + "\n";
}

// Taken once at the start of every run, so "tidy revert" undoes the whole run, not just its last save.
void snapshot_rules() {
	buffer current = file_to_buffer(RULES_FILE);
	if (current.length() > 0) buffer_to_file(current, BACKUP_FILE);
}

// The whole file is always rewritten in canonical form ([id]name, action, q, info, message):
// Philter's loader crashes on a rule line that lost its trailing columns (editors strip trailing tabs).
void save_rules(OCDinfo [item] rules) {
	buffer out;
	foreach it, r in rules out.append(rule_line(it, r.action, r.q, r.info, r.message));
	if (!buffer_to_file(out, RULES_FILE)) abort("tidy: failed to write " + RULES_FILE + ". Nothing sold.");
}

// Philter's default ruleset (installed with Philter); Bale's older OCDefault.txt as fallback.
OCDinfo [item] load_defaults() {
	OCDinfo [item] bale;
	if (!file_to_map("ocd-cleanup-default.txt", bale) || count(bale) == 0) file_to_map("OCDefault.txt", bale);
	return bale;
}

// Patch MALL/AUTO rules on protected items to keep at least the minimum, and bring copies
// back from the store for any protected item with fewer than that on hand.
void enforce_keep_one(OCDinfo [item] rules, boolean sim, string tag) {
	boolean [item] pieces = outfit_piece_set();
	int patched = 0;
	foreach it, r in rules {
		int m = protect_min(it, pieces);
		if (m == 0) continue;
		if ((r.action == "MALL" || r.action == "AUTO") && r.q < m) {
			rules[it].q = m; patched += 1;
			print("  keep " + m + ": " + it + " (" + r.action + ")", "black");
		}
	}
	if (patched > 0) {
		if (sim) print(tag + "would set keep-N on " + patched + " protected rules (outfit pieces, familiar equipment, keep list).", "blue");
		else { save_rules(rules); print(tag + "set keep-N on " + patched + " protected rules (outfit pieces, familiar equipment, keep list; previous file saved as " + BACKUP_FILE + ").", "blue"); }
	}
	int recovered = 0;
	foreach it, n in get_shop() {
		int m = protect_min(it, pieces);
		int need = m - on_hand(it);
		if (m == 0 || need <= 0) continue;
		if (need > n) need = n;
		if (sim) { print("  would take " + need + " " + it + " back from the store", "black"); recovered += 1; continue; }
		if (take_shop(need, it)) { recovered += 1; print("  took " + need + " " + it + " back from the store", "black"); }
		else abort(tag + "could not take " + it + " back from the store; mafia may be in an error state. Stopping before anything is sold. Run 'refresh all' and try again.");
	}
	if (recovered > 0) print(tag + (sim ? "would bring " : "brought ") + recovered + " protected item kind" + (recovered == 1 ? "" : "s") + " back from the store (fewer than the keep count were on hand).", "blue");
}

Decision keep(string why) { Decision d; d.action = "KEEP"; d.q = 0; d.why = why; return d; }
Decision sell(string action, int q, string why) { Decision d; d.action = action; d.q = q; d.why = why; return d; }

// Decide a rule for an item that has none yet. n = how many you have.
Decision decide(item it, int n, OCDinfo [item] bale, int [item] shop, boolean [item] pieces) {
	if (!is_tradeable(it)) return keep("untradeable");
	int p = sale_price(it);
	int ka = keep_above();
	int m = protect_min(it, pieces);
	if (m > 0) {
		string why = (KEEP_LIST contains it) ? "on your keep list: keep " + m : "outfit piece / familiar equipment: keep " + m;
		if (n > m && ka > 0 && p >= ka) return keep(why + ", extras worth " + rnum(p) + " each: yours to decide");
		if (n > m) return sell("MALL", m, why + ", sell extras");
		return keep(why);
	}
	if (shop contains it) return keep("already in your store: yours to decide");
	if (display_amount(it) > 0) return keep("also in display case");
	if (bale contains it && bale[it].action != "MALL" && bale[it].action != "AUTO") return keep("default ruleset says " + bale[it].action);
	if (is_restorative(it)) return keep("HP/MP restorative, a supply");
	int jb = junk_below();
	if (jb > 0 && p > 0 && p <= jb && autosell_price(it) >= 1) return sell("AUTO", 0, "lazyman rule: mall " + rnum(p) + " is under " + rnum(jb) + ", autosell");
	if (!sell_consumables() && is_consumable(it)) return keep("consumable: yours to decide (tidy_sellConsumables = true to sell these)");
	boolean gear = (it.to_slot() != $slot[none]);
	if (gear || is_tool_type(it)) {
		int slots = gear_slots(it);
		if (n > slots && p > 0 && p < 10000) {
			if (p <= 100 && autosell_price(it) >= 1) return sell("AUTO", slots, "duplicate cheap gear, keep " + slots);
			if (p <= 100) return keep("duplicate gear at floor, no autosell value");
			return sell("MALL", slots, "duplicate cheap gear, keep " + slots);
		}
		return keep("gear/tool");
	}
	if (p <= 0) return keep("no mall price");
	if (ka > 0 && p >= ka) return keep("worth " + rnum(p) + " each: yours to decide");
	if (p <= 100) {
		if (autosell_price(it) >= 1) return sell("AUTO", 0, "mall at floor, autosell");
		return keep("floor price, no autosell value");
	}
	return sell("MALL", 0, "mall " + rnum(p));
}

// First run: no rule file yet. Write a rule for every inventory kind, sell nothing.
void bootstrap_rules(boolean sim, string tag) {
	if (file_to_buffer(RULES_FILE).length() > 0)
		abort(tag + "data/" + RULES_FILE + " exists but none of its lines parse as rules (tabs replaced by spaces? not the Philter format?). Nothing overwritten. Fix the file, or rename it away and run again.");
	print(tag + "no rule file " + RULES_FILE + " yet. Writing a starting rule for every item kind in your inventory. Nothing is sold on this run.", "olive");
	OCDinfo [item] bale = load_defaults();
	cli_execute("refresh shop");
	int [item] shop = get_shop();
	boolean [item] pieces = outfit_piece_set();
	buffer add;
	int nMall = 0; int nAuto = 0; int nKeep = 0;
	foreach it, n in get_inventory() {
		Decision d = decide(it, n, bale, shop, pieces);
		if (d.action == "MALL") nMall += 1; else if (d.action == "AUTO") nAuto += 1; else nKeep += 1;
		print("  " + n + " " + it + "  ->  " + d.action + (d.q > 0 ? " keep " + d.q : "") + "   (" + d.why + ")", d.action == "KEEP" ? "green" : "black");
		add.append(rule_line(it, d.action, d.q, "", ""));
	}
	if (!buffer_to_file(add, RULES_FILE)) abort(tag + "could not write " + RULES_FILE + ".");
	set_property("tidy_inheritedNoticed", "true");   // this file is tidy's own, no inheritance notice needed
	print(tag + "wrote " + (nMall + nAuto + nKeep) + " rules to data/" + RULES_FILE + " (" + nMall + " mall, " + nAuto + " autosell, " + nKeep + " keep).", "blue");
	print(tag + "Review them in the relay browser: -run script- > Philter Manager. Change anything you disagree with, run tidy again to preview, then tidy go.", "olive");
}

// "Market price" here is KoLmafia's mall_price(): it skips the five cheapest listings
// (limited stores and min-priced dumps), so it sits at or above the cheapest sellers and
// never undercuts anyone. Scripts cannot read the mall search page itself (mafia returns
// it empty), so the exact lowest seller is not available; this is the honest substitute.

// Reprice every store listing to the current market price, once per KoL day.
void reprice_store(boolean sim, string tag) {
	if (!sim && get_property("_tidyRepricedToday") == "true") {
		print(tag + "store already repriced today; skipping that step.", "blue");
		return;
	}
	string mode = reprice_mode();
	if (mode == "off") { print(tag + "repricing is off (tidy_reprice = off); your prices are untouched.", "blue"); return; }
	int limit = protect_above();
	float factor = price_factor();
	int [item] shop = get_shop();
	int changed = 0; int same = 0; int protectedCount = 0; int noPrice = 0; int pinned = 0; int wouldRaise = 0; int atFloor = 0; int capped = 0; int failed = 0;
	int cutPct = max_cut_pct();
	foreach it, n in shop {
		if (PIN_LIST contains it) { pinned += 1; continue; }
		int cur = shop_price(it);
		if (limit > 0 && cur > limit) { protectedCount += 1; continue; }
		// Live search only where it matters (listings at 10,000+); cheap listings use the daily cached price,
		// otherwise a big store means thousands of mall searches every day.
		int mkt = (cur >= 10000 || historical_age(it) >= 1.0) ? mall_price(it, 0.0) : mall_price(it);
		if (mkt <= 0) { noPrice += 1; continue; }
		if (limit > 0 && mkt > limit) { protectedCount += 1; continue; }
		// about to lower a price on a cached number? confirm with a fresh search first
		if (mkt < cur && cur < 10000 && historical_age(it) < 1.0) { mkt = mall_price(it, 0.0); if (mkt <= 0) { noPrice += 1; continue; } }
		// inside the allowed band already: leave it (with jitter 0 the band is a single price)
		if (cur >= band_low(mkt) && cur <= band_high(mkt)) { same += 1; continue; }
		if (mode == "down" && mkt <= 100) { atFloor += 1; continue; }   // market collapsed to the floor: not worth chasing
		int newp = target_price(mkt);
		if (newp == cur) { same += 1; continue; }
		if (mode == "down" && newp > cur) { wouldRaise += 1; continue; }   // never raise a price you set
		int floorToday = cur - (cur * cutPct / 100);   // no more than tidy_maxCutPct off in one day
		if (newp < floorToday) { newp = floorToday < 100 ? 100 : floorToday; capped += 1; }
		if (newp == cur) { same += 1; continue; }
		changed += 1;
		if (sim) print("  would reprice " + n + " " + it + ": " + rnum(cur) + " -> " + rnum(newp), "black");
		else if (reprice_shop(newp, shop_limit(it), it)) print("  repriced " + n + " " + it + ": " + rnum(cur) + " -> " + rnum(newp), "black");
		else { failed += 1; print(tag + "could not reprice " + it + "; left at " + rnum(cur) + ".", "red"); }
	}
	if (failed > 0) abort(tag + failed + " reprice" + (failed == 1 ? "" : "s") + " failed; mafia may be in an error state. Stopping before Philter. Run 'refresh all' and try again.");
	if (!sim) set_property("_tidyRepricedToday", "true");
	if (capped > 0) print(tag + capped + " cut" + (capped == 1 ? "" : "s") + " limited to " + cutPct + "% today (tidy_maxCutPct); the rest of the way comes on later days if the market stays there.", "blue");
	string how = (factor < 1.0 || price_jitter() > 0.0) ? " (factor " + factor + (price_jitter() > 0.0 ? " +/- " + price_jitter() : "") + ")" : "";
	print(tag + (sim ? "would reprice " : "repriced ") + changed + " listing" + (changed == 1 ? "" : "s") + " to market" + how + "; " + same + " already there; " + protectedCount + " left alone (" + (limit > 0 ? "over " + rnum(limit) + " meat" : "protect threshold off") + "); " + pinned + " pinned; " + noPrice + " with no market price.", "blue");
	if (mode == "down" && (wouldRaise > 0 || atFloor > 0))
		print(tag + wouldRaise + " below market and left there (tidy never raises your prices); " + atFloor + " with a market at the 100-meat floor, not chased. Set tidy_reprice = both to change that.", "blue");
}

// Drip listings: list a fixed count only when the store holds none (and it has been empty long
// enough), never top up while any are listed, and hold the rest in inventory by setting the
// rule's keep-count to whatever is on hand, so Philter never lists it either.
void drip_step(OCDinfo [item] rules, int [item] shop, boolean sim, string tag) {
	if (count(DRIP_LIST) == 0) return;
	int [item] state;
	file_to_map(DRIP_STATE_FILE, state);
	int today = now_to_int() / 86400000;   // real days, never wraps (the in-game calendar day wraps every 96 days)
	int listed = 0; int waiting = 0; int held = 0;
	foreach it, spec in DRIP_LIST {
		if (!(rules contains it) || rules[it].action != "MALL") { print("  drip: " + it + " skipped, its rule is " + ((rules contains it) ? rules[it].action : "missing") + ", not MALL", "olive"); continue; }
		int inStore = (shop contains it) ? shop[it] : 0;
		if (inStore > 0) {
			if (state contains it) remove state[it];
			held += 1;
			print("  drip: " + inStore + " " + it + " listed; holding " + item_amount(it) + " back until they sell out", "black");
		}
		else if (item_amount(it) <= 0) {
			print("  drip: " + it + " sold out and none on hand", "black");
		}
		else {
			if (!(state contains it)) state[it] = today;
			int emptyDays = today - state[it];
			if (emptyDays < spec.days) {
				waiting += 1;
				print("  drip: " + it + " empty for " + emptyDays + " of " + spec.days + " days; not relisting yet", "black");
			}
			else {
				int mkt = mall_price(it, 0.0);
				if (mkt <= 0) print(tag + "drip: no market price for " + it + "; not listed.", "red");
				else {
					int price = target_price(mkt);
					int n = min(spec.n, item_amount(it));
					listed += 1;
					if (sim) print("  drip: would list " + n + " " + it + " at " + rnum(price) + " (holding " + (item_amount(it) - n) + " back)", "black");
					else if (put_shop(price, 0, n, it)) { print("  drip: listed " + n + " " + it + " at " + rnum(price) + " (holding " + item_amount(it) + " back)", "black"); remove state[it]; }
					else print(tag + "drip: could not list " + it + ".", "red");
				}
			}
		}
		// whatever is still on hand stays on hand: Philter must not list it
		if ((rules contains it) && rules[it].action != "KEEP") rules[it].q = item_amount(it);
	}
	map_to_file(state, DRIP_STATE_FILE);
	save_rules(rules);
	print(tag + "drip: " + listed + " " + (sim ? "would be " : "") + "listed, " + waiting + " waiting out the empty days, " + held + " held back while listed. Rule keep-counts set to what is on hand.", "blue");
}

// Set one of Philter's zlib settings and prove it stuck. The "zlib name = value" CLI command
// silently refuses a name it has never seen, and Philter only creates its settings the first
// time Philter itself runs; on a fresh install that would have left BaleOCD_Sim unset and turned
// a preview into a live run. So write through zlib's own map, save, and read back, or stop.
void set_philter_var(string name, string value, string tag) {
	vars[name] = value;
	boolean saved = updatevars();
	if (!saved || getvar(name) != value)
		abort(tag + "could not set Philter's " + name + " to " + value + ". Stopping before anything is sold.");
}

void common_guards(string tag) {
	if (!can_interact()) abort(tag + "you are in Ronin or Hardcore. This is an aftercore tool.");
	if (get_property("lastEmptiedStorage").to_int() != my_ascensions())
		abort(tag + "Hagnk's has not been emptied this ascension. Run 'pull all' first.");
	if (getvar("BaleOCD_EmptyCloset") != "-1") {
		print(tag + "BaleOCD_EmptyCloset was '" + getvar("BaleOCD_EmptyCloset") + "'; setting it to -1 so Philter never dumps the closet on its own.", "olive");
		set_philter_var("BaleOCD_EmptyCloset", "-1", tag);
	}
	// always point Philter at this character's rule file
	set_philter_var("BaleOCD_DataFile", DATA_NAME, tag);
}

void tidy_run(boolean sim);   // defined below; ASH needs to see it before tidy_closet_run uses it
boolean IN_RESET = false;      // a reset's own preview must not count as "the user looked"

// Write rules for closet items that have none, and turn KEEP rules on closet items into
// CLST rules that keep today's inventory count on hand and file the rest back into the closet.
// Items that grant a skill stay in the closet too. Returns how many rules were written.
int closet_bootstrap(OCDinfo [item] rules, int [item] closet, string tag, boolean apply) {
	OCDinfo [item] bale = load_defaults();
	cli_execute("refresh shop");
	int [item] shop = get_shop();
	boolean [item] pieces = outfit_piece_set();
	int added = 0; int converted = 0;
	foreach it, n in closet {
		if (rules contains it) {
			if (rules[it].action == "KEEP") {
				converted += 1;
				if (apply) { rules[it].action = "CLST"; rules[it].q = item_amount(it); }
				print("  " + it + ": KEEP -> CLST keep " + item_amount(it) + " (closet copies go back to the closet)" + (apply ? "" : " [applied on the live run]"), "black");
			}
			continue;
		}
		OCDinfo r;
		if (it.skill != $skill[none]) { r.action = "CLST"; r.q = 0; }
		else {
			Decision d = decide(it, n + item_amount(it), bale, shop, pieces);
			if (d.action == "KEEP") { r.action = "CLST"; r.q = item_amount(it); }
			else { r.action = d.action; r.q = d.q; }
		}
		rules[it] = r; added += 1;
		print("  " + n + " " + it + "  ->  " + r.action + (r.q > 0 ? " keep " + r.q : ""), r.action == "CLST" ? "green" : "black");
	}
	if (added > 0 || (apply && converted > 0)) save_rules(rules);
	if (added + converted > 0)
		print(tag + "wrote " + added + " new closet rules; " + converted + " KEEP rules " + (apply ? "converted" : "would be converted") + " to CLST" + (apply ? "" : " when tidycloset go runs") + " (previous file saved as " + BACKUP_FILE + "). Review them in Philter Manager before running tidycloset go.", "blue");
	return added + converted;
}

// One-time (or occasional) closet liquidation: everything in the closet comes out,
// then the normal tidy pipeline runs. Items with a CLST rule are filed straight back.
// The preview writes any missing closet rules; the live run refuses until a preview ran today.
void tidy_closet_run(boolean sim) {
	string tag = sim ? "tidycloset (preview): " : "tidycloset: ";
	common_guards(tag);
	OCDinfo [item] rules;
	if (!file_to_map(RULES_FILE, rules) || count(rules) == 0) abort(tag + "no rule file " + RULES_FILE + " yet. Run plain tidy first.");
	if (!sim && get_property("_tidyClosetPreviewed") != "true") abort(tag + "run the preview first (plain tidycloset, no go, once per day) and look at what it will do.");
	snapshot_rules();
	cli_execute("refresh closet");
	int [item] closet = get_closet();
	closet_bootstrap(rules, closet, tag, !sim);
	int kinds = 0; int total = 0; int missing = 0;
	int [string] kindsBy; int [string] itemsBy; int mallVal = 0; int autoVal = 0;
	foreach it, n in closet {
		kinds += 1; total += n;
		if (!(rules contains it)) { missing += 1; if (missing <= 15) print("  no rule: " + n + " " + it, "red"); continue; }
		string a = rules[it].action;
		int sellable = max(0, n + item_amount(it) - rules[it].q);
		kindsBy[a] += 1; itemsBy[a] += n;
		if (a == "MALL") mallVal += min(sellable, n) * (historical_price(it) > 0 ? historical_price(it) : 0);
		if (a == "AUTO") autoVal += min(sellable, n) * autosell_price(it);
	}
	print(tag + kinds + " kinds / " + total + " items in the closet.", "blue");
	foreach a, k in kindsBy print("  " + a + ": " + k + " kinds, " + itemsBy[a] + " items", "black");
	print(tag + "mall listings worth about " + rnum(mallVal) + " meat; autosell about " + rnum(autoVal) + " meat (cached prices).", "blue");
	if (missing > 0) abort(tag + missing + " closet item kinds have no rule. Run plain tidycloset (the preview) to write them, then run again.");
	if (sim) {
		set_property("_tidyClosetPreviewed", "true");
		print(tag + "preview only; the closet was not touched. If the tally looks right, run tidycloset go today.", "olive");
		return;
	}
	print(tag + "emptying the closet into inventory...", "red");
	if (!empty_closet()) abort(tag + "could not empty the closet. Nothing sold.");
	tidy_run(false);
	cli_execute("refresh closet");
	print(tag + "done. Closet now holds " + count(get_closet()) + " kinds.", "blue");
}

// Help is printed as HTML: the gCLI collapses tabs and runs of spaces, so bold and colour do the layout.
void h_section(string s) { print_html("<font color='#1f6fb2'><b>" + s + "</b></font>"); }
void h_cmd(string cmd, string text) { print_html("<b>" + cmd + "</b> - " + text); }
void tidy_help() {
	print_html("<font color='#1f6fb2'><b>tidy</b> - inventory cleanup on top of Philter. Nothing runs live without the word <b>go</b>.</font>");
	h_section("Commands");
	h_cmd("tidy", "preview: writes rules for new item kinds, shows what a live run would do, sells nothing (also: tidy sim)");
	h_cmd("tidy go", "LIVE: new rules, store top-ups at your prices, daily reprice, then Philter");
	h_cmd("tidycloset", "preview: rules for closet items that lack one, then a tally; moves nothing");
	h_cmd("tidycloset go", "LIVE, one-off: empties the closet into inventory and runs the tidy pipeline");
	h_cmd("tidy reset", "clean sweep: backs up your rule file, then writes fresh rules for every item kind in your inventory (sells nothing)");
	h_cmd("tidy revert", "undo the last change tidy made to your rule file (after a reset, restores the backup; otherwise swaps in the .prev copy)");
	h_cmd("tidy help", "this text. Any other word prints it too and does nothing else");
	h_section("Settings (set name = value)");
	h_cmd("tidy_keepAbove", (keep_above() > 0 ? rnum(keep_above()) : "off") + " - new item kinds worth this much each start as KEEP, whatever the count (0 = off)");
	h_cmd("tidy_reprice", reprice_mode() + " - down = never raise, never chase a floor; both = follow market either way; off = never reprice");
	h_cmd("tidy_protectAbove", (protect_above() > 0 ? rnum(protect_above()) : "off") + " - listings priced above this are never repriced (0 = off, unset = 1,000,000)");
	h_cmd("tidy_priceFactor", price_factor() + " - multiply the market price when repricing (1.0 = match, 0.99 = 1% under)");
	h_cmd("tidy_priceJitter", price_jitter() + " - random spread around the factor, per item per day (0 = off)");
	h_cmd("tidy_maxCutPct", max_cut_pct() + "% - the most one listing may be cut in one day; the rest comes on later days if the market stays down");
	h_cmd("tidy_holdNewDays", hold_new_days() + " - rules a live run writes for new item kinds are held this many days before they can sell (0 = off)");
	h_cmd("tidy_junkBelow", (junk_below() > 0 ? rnum(junk_below()) : "off") + " - the lazyman rule: new item kinds worth this much or less each, with an autosell value, start as AUTO, gear and consumables included (set above 100 to turn on)");
	h_cmd("tidy_sellConsumables", (sell_consumables() ? "true" : "false") + " - false = potions, food, booze and spleen items with no rule start as KEEP");
	h_cmd("tidy_allowGiving", (get_property("tidy_allowGiving") == "true" ? "true" : "false") + " - false = old CLAN/GIFT/DISC rules (clan stash, kmail, discard) are turned into KEEP");
	h_section("Files in data/ (all optional)");
	h_cmd(RULES_FILE, "your rules (edit in Philter Manager)");
	h_cmd(KEEP_FILE, "item, tab, count: always keep that many on hand (" + count(KEEP_LIST) + " loaded)");
	h_cmd(PIN_FILE, "one item per line: never reprice these listings (" + count(PIN_LIST) + " loaded)");
	h_cmd(DRIP_FILE, "item, tab, count, tab, days: small lots that run dry before relisting (" + count(DRIP_LIST) + " loaded)");
	print_html("<font color='olive'>Rules of the road: whitelist only (no rule, no action); aftercore only; Hagnk's must be emptied; the 100-meat floor always holds.</font>");
}

// Clean sweep: back the rule file up, empty it, and run the first-run preview again (nothing sold).
void tidy_reset() {
	string tag = "tidy reset: ";
	buffer current = file_to_buffer(RULES_FILE);
	if (current.length() == 0) { print(tag + "no rule file " + RULES_FILE + " to reset; plain tidy will write a fresh one.", "olive"); tidy_run(true); return; }
	string backupName = "OCDdata_" + DATA_NAME + ".before-reset-" + now_to_string("yyyyMMdd-HHmmss") + ".txt";
	if (!buffer_to_file(current, backupName)) abort(tag + "could not write the backup " + backupName + ". Nothing changed.");
	buffer empty;
	if (!buffer_to_file(empty, RULES_FILE)) abort(tag + "could not clear " + RULES_FILE + ". Your old rules are still in place (backup at " + backupName + ").");
	set_property("tidy_resetBackup", backupName);   // "tidy revert" restores this first
	set_property("tidy_previewed", "false");        // the fresh rules have not been looked at yet
	print(tag + "old rules saved as data/" + backupName + ". Undo with: tidy revert. Run a plain tidy and look before tidy go.", "olive");
	IN_RESET = true;
	tidy_run(true);
	IN_RESET = false;
}

// Undo: after a reset, restore the dated backup; otherwise swap the rule file with its .prev copy
// (the version before tidy's last write; run again to swap back).
void tidy_revert() {
	string tag = "tidy revert: ";
	string resetBackup = get_property("tidy_resetBackup");
	if (resetBackup != "") {
		buffer old = file_to_buffer(resetBackup);
		if (old.length() > 0) {
			buffer current = file_to_buffer(RULES_FILE);
			if (!buffer_to_file(old, RULES_FILE)) abort(tag + "could not write " + RULES_FILE + ". Nothing changed.");
			buffer_to_file(current, BACKUP_FILE);
			set_property("tidy_resetBackup", "");
			OCDinfo [item] check; file_to_map(RULES_FILE, check);
			print(tag + "the reset is undone: " + RULES_FILE + " is back to the " + count(check) + " rules saved in " + resetBackup + ". Nothing was sold.", "olive");
			return;
		}
	}
	buffer prev = file_to_buffer(BACKUP_FILE);
	if (prev.length() == 0) abort(tag + "no previous version (" + BACKUP_FILE + ") to go back to. Nothing changed.");
	buffer current = file_to_buffer(RULES_FILE);
	OCDinfo [item] check; file_to_map(BACKUP_FILE, check);
	if (!buffer_to_file(prev, RULES_FILE)) abort(tag + "could not write " + RULES_FILE + ". Nothing changed.");
	buffer_to_file(current, BACKUP_FILE);
	print(tag + RULES_FILE + " is back to its previous version (" + count(check) + " rules). Run tidy revert again to swap back. Nothing was sold.", "olive");
	set_property("tidy_inheritedNoticed", "true");
}

// Entry point for the argument-taking scripts. Bare = preview. "go" = live. "reset" = clean sweep. Anything else = help.
void tidy_dispatch(string which, string [int] args) {
	string a = (count(args) > 0) ? to_lower_case(args[0]) : "";
	if (count(args) > 1) { print("tidy: one word at a time, please. Commands:", "red"); tidy_help(); return; }
	if (a == "reset" && which == "tidy") { tidy_reset(); return; }
	if (a == "revert" && which == "tidy") { tidy_revert(); return; }
	if (a == "sim" || a == "preview") a = "";
	if (a != "" && a != "go") {
		if (a != "help") print("tidy: I do not know the word '" + args[0] + "'. Nothing was done. Commands:", "red");
		tidy_help();
		return;
	}
	boolean sim = (a != "go");
	if (which == "closet") tidy_closet_run(sim);
	else tidy_run(sim);
}

void tidy_run(boolean sim) {
	string tag = sim ? "tidy (preview): " : "tidy: ";
	common_guards(tag);
	snapshot_rules();

	// ---- first run: write rules, sell nothing
	OCDinfo [item] rules;
	if (!file_to_map(RULES_FILE, rules) || count(rules) == 0) {
		bootstrap_rules(sim, tag);
		if (!sim) return;
		clear(rules);
		file_to_map(RULES_FILE, rules);
	}
	if (!sim && get_property("tidy_previewed") != "true")
		abort(tag + "run a preview first (plain tidy, no go) and look at what it will do.");

	// ---- a rule file tidy did not write (old Philter / OCD decisions): say so, once
	if (get_property("tidy_inheritedNoticed") != "true") {
		int acting = 0; int held = 0; int [string] other;
		foreach it, r in rules {
			if (r.action == "MALL" || r.action == "AUTO") acting += 1;
			else if (r.action != "KEEP" && r.action != "CLST") other[r.action] += 1;
			if (item_amount(it) + closet_amount(it) + shop_amount(it) + display_amount(it) + equipped_amount(it) > 0) held += 1;
		}
		print(tag + "found an existing rule file, data/" + RULES_FILE + ", that tidy did not write: " + count(rules) + " rules from an earlier Philter or OCD setup, " + acting + " of them sell (MALL/AUTO), " + held + " cover items you hold right now.", "olive");
		foreach a, c in other print("  " + c + (c == 1 ? " rule says " : " rules say ") + a + (a == "CLAN" ? " (put in the clan stash)" : a == "GIFT" ? " (kmail to another player)" : a == "PULV" ? " (pulverize)" : a == "DISP" ? " (display case)" : a == "MAKE" ? " (craft into something)" : a == "USE" ? " (use it)" : a == "UNTN" ? " (untinker)" : a == "BREAK" ? " (break apart)" : a == "DISC" ? " (discard, destroys the item)" : a == "TODO" ? " (a reminder, does nothing)" : ""), "olive");
		print(tag + "those old decisions stay in force unless you change them. To start clean instead: tidy reset (backs the file up, then writes fresh rules for everything you hold, sells nothing).", "olive");
		set_property("tidy_inheritedNoticed", "true");
	}

	// ---- nothing leaves your account except through the mall and autosell: CLAN, GIFT and DISC rules become KEEP
	if (get_property("tidy_allowGiving") != "true") {
		int neutralized = 0;
		foreach it, r in rules {
			if (r.action != "CLAN" && r.action != "GIFT" && r.action != "DISC") continue;
			print("  " + it + ": " + r.action + (r.action == "GIFT" && r.info != "" ? " to " + r.info : "") + " -> KEEP", "olive");
			rules[it].message = "was " + r.action + (r.info != "" ? " " + r.info : "");
			rules[it].action = "KEEP"; rules[it].q = 0; rules[it].info = "";
			neutralized += 1;
		}
		if (neutralized > 0) {
			save_rules(rules);
			print(tag + "turned " + neutralized + " CLAN/GIFT/DISC rule" + (neutralized == 1 ? "" : "s") + " into KEEP: tidy never puts items in the clan stash, kmails them away, or discards them. To allow it, set tidy_allowGiving = true, then tidy revert.", "olive");
		}
	}

	// ---- load rules + defaults
	OCDinfo [item] bale = load_defaults();
	// get_shop() reuses whatever mafia loaded earlier in the session; sales since then are invisible without this.
	cli_execute("refresh shop");
	int [item] shop = get_shop();
	int [item] inv = get_inventory();

	print(tag + count(rules) + " rules on file, " + count(inv) + " item kinds in inventory, " + count(shop) + " listings in your store.", "blue");

	// ---- keep one of every outfit piece and familiar equipment item (plus your keep list)
	enforce_keep_one(rules, sim, tag);
	boolean [item] pieces = outfit_piece_set();

	// ---- release holds: rules written by an earlier LIVE run that have waited long enough
	int released = 0; int stillHeld = 0; int holdDays = hold_new_days();
	foreach it, r in rules {
		if (!r.message.starts_with("tidy new ")) continue;
		string [int] f = r.message.split_string(" ");   // "tidy new <day> q<decided keep-count>"
		int since = (count(f) > 2) ? f[2].to_int() : 0;
		int decidedQ = (count(f) > 3) ? f[3].substring(1).to_int() : 0;
		if (today_number() - since >= holdDays) { rules[it].q = decidedQ; rules[it].message = ""; released += 1; }
		else stillHeld += 1;
	}
	if (released > 0) print(tag + released + " rule" + (released == 1 ? "" : "s") + " written by an earlier live run " + (released == 1 ? "is" : "are") + " past the " + holdDays + "-day hold and can sell now.", "blue");
	if (stillHeld > 0) print(tag + stillHeld + " new-kind rule" + (stillHeld == 1 ? "" : "s") + " still on hold (written by a live run, nobody has looked yet). Review in Philter Manager; they sell after " + holdDays + " day" + (holdDays == 1 ? "" : "s") + ".", "olive");

	// ---- new item kinds
	int added = 0; int addMall = 0; int addAuto = 0; int addKeep = 0; int held = 0;
	foreach it, n in inv {
		if (rules contains it) continue;
		Decision d = decide(it, n, bale, shop, pieces);
		added += 1;
		if (d.action == "MALL") addMall += 1; else if (d.action == "AUTO") addAuto += 1; else addKeep += 1;
		OCDinfo r; r.action = d.action; r.q = d.q; r.info = ""; r.message = "";
		if (!sim && holdDays > 0 && d.action != "KEEP") {
			// a live run may write the rule, but not sell on it: hold everything on hand until the wait is over
			r.q = n; r.message = "tidy new " + today_number() + " q" + d.q; held += 1;
		}
		print("  new: " + n + " " + it + "  ->  " + d.action + (d.q > 0 ? " keep " + d.q : "") + "   (" + d.why + ")" + (r.message != "" ? "   [held " + holdDays + " day" + (holdDays == 1 ? "" : "s") + "]" : ""), d.action == "KEEP" ? "green" : "black");
		rules[it] = r;
	}
	if (held > 0) print(tag + held + " new MALL/AUTO rule" + (held == 1 ? "" : "s") + " written but held: nothing sells on a rule the same run that wrote it. Run a preview or open Philter Manager to review them; they sell after " + holdDays + " day" + (holdDays == 1 ? "" : "s") + " (tidy_holdNewDays).", "olive");
	if (released > 0 && added == 0) save_rules(rules);
	if (added == 0) print(tag + "no new item kinds; rule file unchanged.", "blue");
	else {
		save_rules(rules);
		print(tag + "added " + added + " rules (" + addMall + " mall, " + addAuto + " autosell, " + addKeep + " keep) to data/" + RULES_FILE + ". Previous file saved as " + BACKUP_FILE + ".", "blue");
		if (sim) print(tag + "the new rules are written now so you can review them: relay browser > -run script- > Philter Manager, sort by price, change what you disagree with. Nothing is sold in a preview.", "olive");
		clear(rules);
		file_to_map(RULES_FILE, rules);
	}

	// ---- reprice the store to market (once a day), then top up at the resulting prices
	reprice_store(sim, tag);

	// ---- drip listings: small fixed lots that are allowed to run dry
	drip_step(rules, shop, sim, tag);

	// ---- store top-ups at your own prices, before Philter can touch those listings
	int topped = 0; int toppedItems = 0;
	foreach it, listed in shop {
		if (DRIP_LIST contains it) continue;
		if (!(rules contains it) || rules[it].action != "MALL") continue;
		int excess = item_amount(it) - rules[it].q;
		if (excess <= 0) continue;
		int price = shop_price(it);
		if (price <= 0 || price >= 999999999) abort(tag + "could not read your store price for " + it + " (mafia returned " + price + "). Stopping before Philter so the listing cannot be repriced. Run 'refresh shop' and try again.");
		topped += 1; toppedItems += excess;
		if (sim) print("  would add " + excess + " " + it + " to your store at your price of " + rnum(price), "black");
		else {
			if (!put_shop(price, shop_limit(it), excess, it))
				abort(tag + "could not add " + it + " to your store. Stopping before Philter so the listing cannot be repriced.");
			print("  added " + excess + " " + it + " to your store at your price of " + rnum(price), "black");
		}
	}
	if (topped > 0) print(tag + (sim ? "would top up " : "topped up ") + topped + " listing" + (topped == 1 ? "" : "s") + " (" + toppedItems + " items) at your prices.", "blue");
	else print(tag + "no store listings need topping up.", "blue");

	// ---- Philter
	set_philter_var("BaleOCD_Sim", sim ? "true" : "false", tag);
	if (sim && getvar("BaleOCD_Sim") != "true") abort(tag + "Philter is not in simulation mode. Stopping before anything is sold.");
	int meatBefore = my_meat();
	int kindsBefore = count(get_inventory());
	print(tag + "running Philter " + (sim ? "in simulation" : "LIVE") + "...", sim ? "olive" : "red");
	boolean philterOk = cli_execute("philter");
	int kindsAfter = count(get_inventory());
	if (!philterOk) print(tag + "Philter stopped early (see the lines above). Some rules may not have run.", "red");
	cli_execute("refresh shop");
	if (sim && !IN_RESET) set_property("tidy_previewed", "true");
	print(tag + "finished. Inventory " + kindsBefore + " kinds -> " + kindsAfter + " kinds; meat " + rnum(meatBefore) + " -> " + rnum(my_meat()) + "; store now has " + count(get_shop()) + " listings.", "blue");
}
