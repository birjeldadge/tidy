// tidy_common.ash  --  shared code for the tidy commands (KoLmafia, aftercore).
//
//   tidy            rules for new item kinds, store top-ups at your prices, daily reprice, then Philter (LIVE)
//   tidysim         preview of tidy: writes rules for new item kinds (so you can review them), sells nothing
//   tidycloset      empties the closet into inventory and runs the tidy pipeline (LIVE, one-off)
//   tidyclosetsim   preview of tidycloset: writes rules for closet items that lack one, tallies, moves nothing
//
// Why a wrapper around Philter:
//   1. Philter asks a blocking question when it meets an item with no rule.
//      tidy writes a sensible rule first, so it never has to ask.
//   2. Philter lists MALL items at the market price, and KoL applies that price
//      to the whole listing. Anything already in your store is topped up here,
//      at the price you set, before Philter runs. Philter then finds nothing
//      left to move for those items.
//   3. Once per KoL day, every listing priced at or under tidy_protectAbove
//      (default 10,000,000 meat) is set to KoLmafia's market price. That price
//      skips the five cheapest listings, so it never undercuts anyone, and it
//      never goes below the 100-meat floor. Listings above the threshold are
//      your hand-set prices and are left alone. No price duels.
//
// Rule logic for new kinds (decide): untradeable, gear, tools, display-case items
// and rare singles stay; floor-priced junk is autosold; everything else goes to
// the mall. Review the generated rules in Philter Manager any time.
//
// Settings (KoLmafia preferences, set with: set tidy_protectAbove = 5000000):
//   tidy_protectAbove   listings priced above this are never repriced (default 10000000)
//   tidy_rulesSuffix    testing only: use OCDdata_<name><suffix>.txt instead of your real rules
// Optional file data/tidy_keep_<name>.txt, one "item name<TAB>count" per line:
//   those items always keep at least that many copies on hand (MALL/AUTO rules are patched).

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
string KEEP_FILE = "tidy_keep_" + my_name() + ".txt";

int protect_above() {
	int p = get_property("tidy_protectAbove").to_int();
	return p > 0 ? p : 10000000;
}

int sale_price(item it) {
	if (historical_age(it) < 1 && historical_price(it) > 0) return historical_price(it);
	return mall_price(it);
}

boolean is_tool_type(item it) {
	string t = item_type(it);
	return t.contains_text("reusable") || t.contains_text("grow") || t.contains_text("sticker")
		|| t.contains_text("card") || t.contains_text("folder") || t.contains_text("spur")
		|| t.contains_text("skin") || t.contains_text("avatar") || t.contains_text("message")
		|| t.contains_text("zap");
}

// Always keep one of every piece of a saved custom outfit and one of every familiar
// equipment item. Extras may sell; the last copy never does.
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
// outfit pieces and familiar equipment keep 1, everything else 0.
int protect_min(item it, boolean [item] pieces) {
	if ((KEEP_LIST contains it) && KEEP_LIST[it] > 0) return KEEP_LIST[it];
	if (is_protected_gear(it, pieces)) return 1;
	return 0;
}
int on_hand(item it) { return item_amount(it) + closet_amount(it) + equipped_amount(it); }

string rule_line(item it, string action, int q, string info, string message) {
	return "[" + it.to_int() + "]" + it.name + "\t" + action + "\t" + q + "\t" + info + "\t" + message + "\n";
}

void save_rules(OCDinfo [item] rules) {
	buffer current = file_to_buffer(RULES_FILE);
	if (current.length() > 0) buffer_to_file(current, BACKUP_FILE);
	buffer out;
	foreach it, r in rules out.append(rule_line(it, r.action, r.q, r.info, r.message));
	if (!buffer_to_file(out, RULES_FILE)) abort("tidy: failed to write " + RULES_FILE + ". Nothing sold.");
}

// Append rule lines to the rule file (keeps a .prev backup, fixes a missing trailing newline).
void append_rules(buffer add) {
	buffer current = file_to_buffer(RULES_FILE);
	if (current.length() > 0) buffer_to_file(current, BACKUP_FILE);
	string text = current.to_string();
	if (text.length() > 0 && !text.ends_with("\n")) text += "\n";
	buffer out; out.append(text); out.append(add.to_string());
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
		else print(tag + "could not take " + it + " back from the store.", "red");
	}
	if (recovered > 0) print(tag + (sim ? "would bring " : "brought ") + recovered + " protected item kind" + (recovered == 1 ? "" : "s") + " back from the store (fewer than the keep count were on hand).", "blue");
}

Decision keep(string why) { Decision d; d.action = "KEEP"; d.q = 0; d.why = why; return d; }
Decision sell(string action, int q, string why) { Decision d; d.action = action; d.q = q; d.why = why; return d; }

// Decide a rule for an item that has none yet. n = how many you have.
Decision decide(item it, int n, OCDinfo [item] bale, int [item] shop, boolean [item] pieces) {
	if (!is_tradeable(it)) return keep("untradeable");
	int m = protect_min(it, pieces);
	if (m > 0) {
		string why = (KEEP_LIST contains it) ? "on your keep list: keep " + m : "outfit piece / familiar equipment: keep 1";
		if (n > m) return sell("MALL", m, why + ", sell extras");
		return keep(why);
	}
	if (shop contains it) return sell("MALL", 0, "already in your store, extras go there at your price");
	if (display_amount(it) > 0) return keep("also in display case");
	if (bale contains it && bale[it].action != "MALL" && bale[it].action != "AUTO") return keep("default ruleset says " + bale[it].action);
	int p = sale_price(it);
	boolean gear = (it.to_slot() != $slot[none]);
	if (gear || is_tool_type(it)) {
		if (n >= 2 && p > 0 && p < 10000) {
			if (p <= 100 && autosell_price(it) >= 1) return sell("AUTO", 1, "duplicate cheap gear, keep 1");
			if (p <= 100) return keep("duplicate gear at floor, no autosell value");
			return sell("MALL", 1, "duplicate cheap gear, keep 1");
		}
		return keep("gear/tool");
	}
	if (p <= 0) return keep("no mall price");
	if (n == 1 && p >= 10000) return keep("single copy worth " + rnum(p));
	if (p <= 100) {
		if (autosell_price(it) >= 1) return sell("AUTO", 0, "mall at floor, autosell");
		return keep("floor price, no autosell value");
	}
	return sell("MALL", 0, "mall " + rnum(p));
}

// First run: no rule file yet. Write a rule for every inventory kind, sell nothing.
void bootstrap_rules(boolean sim, string tag) {
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
	print(tag + "wrote " + (nMall + nAuto + nKeep) + " rules to data/" + RULES_FILE + " (" + nMall + " mall, " + nAuto + " autosell, " + nKeep + " keep).", "blue");
	print(tag + "Review them in the relay browser: -run script- > Philter Manager. Change anything you disagree with, then run tidysim, then tidy.", "olive");
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
	int limit = protect_above();
	int [item] shop = get_shop();
	int changed = 0; int same = 0; int protectedCount = 0; int noPrice = 0;
	foreach it, n in shop {
		int cur = shop_price(it);
		if (cur > limit) { protectedCount += 1; continue; }
		// Live search only where it matters (listings at 10,000+); cheap listings use the daily cached price,
		// otherwise a big store means thousands of mall searches every day.
		int mkt = (cur >= 10000) ? mall_price(it, 0.0) : mall_price(it);
		if (mkt <= 0) { noPrice += 1; continue; }
		if (mkt > limit) { protectedCount += 1; continue; }
		if (mkt < 100) mkt = 100;
		if (mkt == cur) { same += 1; continue; }
		changed += 1;
		if (sim) print("  would reprice " + n + " " + it + ": " + rnum(cur) + " -> " + rnum(mkt), "black");
		else if (reprice_shop(mkt, shop_limit(it), it)) print("  repriced " + n + " " + it + ": " + rnum(cur) + " -> " + rnum(mkt), "black");
		else print(tag + "could not reprice " + it + "; left at " + rnum(cur) + ".", "red");
	}
	if (!sim) set_property("_tidyRepricedToday", "true");
	print(tag + (sim ? "would reprice " : "repriced ") + changed + " listing" + (changed == 1 ? "" : "s") + " to market; " + same + " already at market; " + protectedCount + " left alone (over " + rnum(limit) + " meat); " + noPrice + " with no market price.", "blue");
}

void common_guards(string tag) {
	if (!can_interact()) abort(tag + "you are in Ronin or Hardcore. This is an aftercore tool.");
	if (get_property("lastEmptiedStorage").to_int() != my_ascensions())
		abort(tag + "Hagnk's has not been emptied this ascension. Run 'pull all' first.");
	if (getvar("BaleOCD_EmptyCloset") != "-1") {
		print(tag + "BaleOCD_EmptyCloset was " + getvar("BaleOCD_EmptyCloset") + "; setting it to -1 so Philter never dumps the closet on its own.", "olive");
		cli_execute("zlib BaleOCD_EmptyCloset = -1");
	}
	// always point Philter at this character's rule file
	cli_execute("zlib BaleOCD_DataFile = " + DATA_NAME);
}

void tidy_run(boolean sim);   // defined below; ASH needs to see it before tidy_closet_run uses it

// Write rules for closet items that have none, and turn KEEP rules on closet items into
// CLST rules that keep today's inventory count on hand and file the rest back into the closet.
// Items that grant a skill stay in the closet too. Returns how many rules were written.
int closet_bootstrap(OCDinfo [item] rules, int [item] closet, string tag) {
	OCDinfo [item] bale = load_defaults();
	cli_execute("refresh shop");
	int [item] shop = get_shop();
	boolean [item] pieces = outfit_piece_set();
	int added = 0; int converted = 0;
	foreach it, n in closet {
		if (rules contains it) {
			if (rules[it].action == "KEEP") {
				rules[it].action = "CLST"; rules[it].q = item_amount(it); converted += 1;
				print("  " + it + ": KEEP -> CLST keep " + item_amount(it) + " (closet copies go back to the closet)", "black");
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
	if (added + converted > 0) {
		save_rules(rules);
		print(tag + "wrote " + added + " new closet rules and converted " + converted + " KEEP rules to CLST (previous file saved as " + BACKUP_FILE + "). Review them in Philter Manager before running tidycloset.", "blue");
	}
	return added + converted;
}

// One-time (or occasional) closet liquidation: everything in the closet comes out,
// then the normal tidy pipeline runs. Items with a CLST rule are filed straight back.
// The preview writes any missing closet rules; the live run refuses until a preview ran today.
void tidy_closet_run(boolean sim) {
	string tag = sim ? "tidycloset (preview): " : "tidycloset: ";
	common_guards(tag);
	OCDinfo [item] rules;
	if (!file_to_map(RULES_FILE, rules) || count(rules) == 0) abort(tag + "no rule file " + RULES_FILE + " yet. Run tidysim first.");
	if (!sim && get_property("_tidyClosetPreviewed") != "true") abort(tag + "run tidyclosetsim first (once per day) and look at what it will do.");
	cli_execute("refresh closet");
	int [item] closet = get_closet();
	if (sim) closet_bootstrap(rules, closet, tag);
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
	if (missing > 0) abort(tag + missing + " closet item kinds have no rule. Run tidyclosetsim to write them, then run again.");
	if (sim) {
		set_property("_tidyClosetPreviewed", "true");
		print(tag + "preview only; the closet was not touched. If the tally looks right, run tidycloset today.", "olive");
		return;
	}
	print(tag + "emptying the closet into inventory...", "red");
	if (!empty_closet()) abort(tag + "could not empty the closet. Nothing sold.");
	tidy_run(false);
	cli_execute("refresh closet");
	print(tag + "done. Closet now holds " + count(get_closet()) + " kinds.", "blue");
}

void tidy_run(boolean sim) {
	string tag = sim ? "tidy (preview): " : "tidy: ";
	common_guards(tag);

	// ---- first run: write rules, sell nothing
	OCDinfo [item] rules;
	if (!file_to_map(RULES_FILE, rules) || count(rules) == 0) {
		bootstrap_rules(sim, tag);
		if (!sim) return;
		clear(rules);
		file_to_map(RULES_FILE, rules);
	}
	if (!sim && get_property("tidy_previewed") != "true")
		abort(tag + "run tidysim once before the first live run, and look at what it will do.");

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

	// ---- new item kinds
	buffer add;
	int added = 0; int addMall = 0; int addAuto = 0; int addKeep = 0;
	foreach it, n in inv {
		if (rules contains it) continue;
		Decision d = decide(it, n, bale, shop, pieces);
		added += 1;
		if (d.action == "MALL") addMall += 1; else if (d.action == "AUTO") addAuto += 1; else addKeep += 1;
		print("  new: " + n + " " + it + "  ->  " + d.action + (d.q > 0 ? " keep " + d.q : "") + "   (" + d.why + ")", d.action == "KEEP" ? "green" : "black");
		add.append(rule_line(it, d.action, d.q, "", ""));
	}
	if (added == 0) print(tag + "no new item kinds; rule file unchanged.", "blue");
	else {
		append_rules(add);
		print(tag + "added " + added + " rules (" + addMall + " mall, " + addAuto + " autosell, " + addKeep + " keep) to data/" + RULES_FILE + ". Previous file saved as " + BACKUP_FILE + ".", "blue");
		if (sim) print(tag + "the new rules are written now so you can review them: relay browser > -run script- > Philter Manager, sort by price, change what you disagree with. Nothing is sold in a preview.", "olive");
		clear(rules);
		file_to_map(RULES_FILE, rules);
	}

	// ---- reprice the store to market (once a day), then top up at the resulting prices
	reprice_store(sim, tag);

	// ---- store top-ups at your own prices, before Philter can touch those listings
	int topped = 0; int toppedItems = 0;
	foreach it, listed in shop {
		if (!(rules contains it) || rules[it].action != "MALL") continue;
		int excess = item_amount(it) - rules[it].q;
		if (excess <= 0) continue;
		int price = shop_price(it);
		if (price <= 0) abort(tag + "could not read your store price for " + it + ". Stopping before Philter so the listing cannot be repriced.");
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
	cli_execute("zlib BaleOCD_Sim = " + (sim ? "true" : "false"));
	int meatBefore = my_meat();
	int kindsBefore = count(get_inventory());
	print(tag + "running Philter " + (sim ? "in simulation" : "LIVE") + "...", sim ? "olive" : "red");
	cli_execute("philter");
	int kindsAfter = count(get_inventory());
	cli_execute("refresh shop");
	if (sim) set_property("tidy_previewed", "true");
	print(tag + "finished. Inventory " + kindsBefore + " kinds -> " + kindsAfter + " kinds; meat " + rnum(meatBefore) + " -> " + rnum(my_meat()) + "; store now has " + count(get_shop()) + " listings.", "blue");
}
