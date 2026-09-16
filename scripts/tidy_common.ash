// tidy_common.ash  --  shared code for the tidy commands (KoLmafia, aftercore).
//
//   tidy            PREVIEW: writes rules for new item kinds (MALL/AUTO ones on hold), raises held, drip and worn-gear
//                   keep-counts, prints what a live run would do, sells nothing and releases no hold
//   tidy go         LIVE: rules for new item kinds, store top-ups at your prices, daily reprice, then Philter
//   tidy reset      clean sweep: backs up the rule file, then the first-run preview writes fresh rules (sells nothing)
//   tidy revert     undo the last change tidy made to the rule file (swap with the .prev copy; run again to swap back;
//                   refuses a copy that holds no readable rules)
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
//   3. Once a day, any listing priced at or under tidy_protectAbove
//      (default 1,000,000 meat) that sits above KoLmafia's market price is
//      lowered to it. That price skips the five cheapest units, so it never
//      undercuts anyone. By default it never raises a price you set, never
//      chases a market that collapsed to KoL's floor (100 meat or twice the
//      autosell value), never goes below that floor or below the rule's own
//      minimum price, and moves a listing at most tidy_maxCutPct a day.
//      Listings above the threshold, or parked at 999,999,999+, are your
//      hand-set prices and are left alone. No price duels.
//
// Rule logic for new kinds (decide): untradeable, gear, tools, display-case items
// and rare singles stay; floor-priced junk is autosold; everything else goes to
// the mall. Review the generated rules in Philter Manager any time.
//
// Settings (KoLmafia preferences, set with: set tidy_protectAbove = 5000000):
//   tidy_keepAbove      new item kinds priced at or above this each start as KEEP, whatever the count (unset = 10000; 0 = off)
//   tidy_reprice        down (default: never raise a price, never chase a market that collapsed to the floor) | both (either
//                       direction, same daily cap, fresh search before any change) | off
//   tidy_protectAbove   listings priced above this are never repriced (unset = 1000000; 0 = off, reprice everything)
//   tidy_junkBelow      off (default): the lazyman rule. Set to e.g. 1000 and new item kinds with a mall price at or
//                       below that and an autosell value start as AUTO, gear and consumables included. Protected classes still win.
//   tidy_sellConsumables false (default): potions (usable, grants an effect), food, booze, spleen items with no rule start as KEEP
//   tidy_allowGiving    false (default): rules that say CLAN (clan stash), GIFT (kmail) or DISC (discard) are turned into KEEP every run
//   tidy_maxCutPct      30: the most the daily reprice may cut one listing in one day, as a percent of its current price
//   tidy_holdNewDays    1: any run that writes a new MALL/AUTO rule (preview, first run, closet preview, live) holds it this
//                       many days before it can sell (0 = off).
//                       A held rule is released only after the wait AND after a preview has run to the end on a later day than
//                       the rule was written (the preview lists every held rule and what would sell), so nothing sells on a
//                       rule nobody looked at. Holds, top-ups and drip keep-counts count bag + closet + worn copies, as Philter does.
//                       Gear you or a familiar are wearing is never the extra: every run raises a sell rule's keep-count to the
//                       worn plus closet copies (keep_floor), the release of a hold respects the same floor, and the top-up
//                       sends bag copies only. To sell a worn copy, unequip it first.
//   tidy_priceFactor    multiply the market price by this when repricing (default 1.0 = match market;
//                       0.99 = list 1% under the market price to get the sale first; never below 100 meat).
//                       Applies only to listings above market: one already at or under market is never cut, because
//                       the market figure counts your own units and cutting there would chase your own price down daily.
//   tidy_priceJitter    random spread around the factor (default 0). 0.01 with factor 0.99 draws a factor
//                       between 0.98 and 1.00 per item per day; a listing already inside that band is left alone.
//   tidy_dataFile       use OCDdata_<this>.txt instead of OCDdata_<your name>.txt (for people who keep one Philter file for several characters)
//   tidy_rulesSuffix    testing only: use OCDdata_<name><suffix>.txt (and the matching keep/pin/drip/hold/state files) instead of your real ones
// Names in the keep, pin and drip lists must be exact: the full item name (case does not matter, entity and plain forms
// both count) or [id]name. A partial name is ignored with a message, because mafia's own lookup accepts any unique
// substring and "cowbell" could quietly mean a different item than the one you meant.
// Optional file data/tidy_keep_<name>.txt, one "item name<TAB>count" per line:
//   those items always keep at least that many copies on hand (MALL/AUTO rules are patched).
// Optional file data/tidy_pin_<name>.txt, one item name per line:
//   those store listings are never repriced (hand-set prices, "keeping an eye on it" listings).
// Optional file data/tidy_drip_<name>.txt, one "item name<TAB>count<TAB>days" per line (days optional):
//   list that many only when your store holds none of it and it has been empty that many days; never
//   top up while any are listed; the rest stays in inventory (tidy sets the rule's keep-count to match).
//   Rivals see a small stock that runs dry, not a deep one, so they price against you less.
// State tidy keeps next to the rule file: data/tidy_hold_<name>.txt (rules tidy wrote that are still on hold: item,
//   write day, decided keep-count, held keep-count, decision price) and data/tidy_state_<name>.txt (last preview and
//   its day, reprice day, closet-preview day, reset backup names, whether the inherited-file notice was shown).

// equipped_amount(item, true) counts equipment on every familiar; also past r26597, where git checkout honours
// manifest.json (Philter installs as a dependency).
since r27250;

import "zlib.ash";

// One Philter rule, the columns of a line in OCDdata_<name>.txt. q is the keep-count, under Philter's own column name:
// how many copies stay on hand (bag + closet + worn) before the action applies to the rest. info is a MALL rule's
// minimum price or a GIFT rule's recipient; message is free text that Philter Manager blanks for MALL/AUTO rules on
// every save. ASH's foreach hands out a reference to the record, so "rule.q = ..." inside a loop over the map changes
// the rule in the map.
record OCDinfo {
	string action;
	int q;
	string info;
	string message;
};

// What decide() settles on for a new item kind: the action and keep-count (q, as above) to write, and the reason
// shown next to it in the preview.
record Decision {
	string action;
	int q;
	string why;
};

// "3 rules" / "1 rule": a count with the right noun after it.
string plural(int n, string one, string many) { return n + " " + (n == 1 ? one : many); }

// tidy works on OCDdata_<name>.txt, where <name> is your character name unless tidy_dataFile names another Philter
// rule file. Philter's own BaleOCD_DataFile setting is only pointed at that file while Philter runs, then put back.
string BASE_NAME = (get_property("tidy_dataFile") != "") ? get_property("tidy_dataFile") : my_name();
string DATA_NAME = BASE_NAME + get_property("tidy_rulesSuffix");
string DATAFILE_BEFORE = (vars contains "BaleOCD_DataFile") ? vars["BaleOCD_DataFile"] : "";   // as the run found it
string RULES_FILE = "OCDdata_" + DATA_NAME + ".txt";
string BACKUP_FILE = "OCDdata_" + DATA_NAME + ".prev.txt";
string KEEP_FILE = "tidy_keep_" + DATA_NAME + ".txt";
string PIN_FILE = "tidy_pin_" + DATA_NAME + ".txt";
boolean IN_RESET = false;        // a reset's own preview must not count as "the user looked"
boolean SNAPSHOT_TAKEN = false;  // .prev is written once per run, on the first write of the rule file
boolean RULES_WRITTEN = false;   // whether this run wrote the rule file at all
boolean CLOSET_RUN = false;      // inside tidycloset go: the keep-count check must not put the one-copy minimum back on CLST rules

// Plain digits, at most 15 of them (fits a long). is_integer() also accepts a leading sign and commas ("-1", "1,000"),
// and to_int() turns a number too big for a long into 0 with nothing but a log line, so this is the only test used
// for anything that guards a sale. The length test comes first: an ASH "for" counts down when the range is empty.
boolean plain_digits(string text) {
	if (text.length() == 0 || text.length() > 15) return false;
	for i from 0 to text.length() - 1 { string ch = text.char_at(i); if (ch < "0" || ch > "9") return false; }
	return true;
}
// Empty, or only spaces and tabs. The length test comes first: an ASH "for" over an empty range counts down and would
// index character 0 of an empty string.
boolean is_blank(string line) {
	if (line.length() == 0) return true;
	for pos from 0 to line.length() - 1 { string ch = line.char_at(pos); if (ch != " " && ch != "\t") return false; }
	return true;
}
// A whole-number preference. Unset = the default. Anything that is not plain digits stops the run:
// a typo like "off", "-1" or "1e6" must never silently become 0 and switch a guard off.
int pref_int(string name, int dflt) {
	string raw = get_property(name);
	if (raw == "") return dflt;
	if (!plain_digits(raw)) abort("tidy: " + name + " is set to '" + raw + "', which is not a plain whole number (digits only:"
		+ " no sign, no commas, at most 15 digits). Fix it with: set " + name + " = " + dflt + " (or a number). Nothing done.");
	return raw.to_int();
}
// For the help text only: shows a setting as typed, never stops (help must work when a setting is broken).
string pref_text(string name, string dflt) {
	string raw = get_property(name);
	if (raw == "") return dflt + " (default)";
	return plain_digits(raw) ? raw : raw + " (NOT a plain number: every run will stop until you fix it)";
}
// Listings priced above this are never repriced. Unset = 1,000,000. 0 = off (everything gets repriced).
int protect_above() {
	int above = pref_int("tidy_protectAbove", 1000000);
	return above > 0 ? above : 0;
}
// 0.5 to 1.0; anything else (a slipped digit like 0.01, which would list everything at 1% of market) stops the run in
// common_guards. Here it just falls back to 1.0, because help must never stop.
float price_factor() {
	float factor = get_property("tidy_priceFactor").to_float();
	return (factor >= 0.5 && factor <= 1.0) ? factor : 1.0;
}
// New item kinds priced at or above this per copy start as KEEP, whatever the count. Unset = 10,000. 0 = off.
int keep_above() {
	int above = pref_int("tidy_keepAbove", 10000);
	return above > 0 ? above : 0;
}
// The lazyman rule. Off unless set above 100. When on, any new item kind with a mall price at or
// below this and an autosell value starts as AUTO, gear and consumables included. Outfit pieces,
// keep-list items, store and display-case items, restoratives and untradeables stay protected.
int junk_below() {
	int below = pref_int("tidy_junkBelow", 0);
	return below > 100 ? below : 0;
}
// Biggest price cut the daily reprice may make in one day, as a percentage of the current price.
// A transient dump of a few cheap units must not drag a listing to the floor in one run.
int max_cut_pct() {
	int pct = pref_int("tidy_maxCutPct", 30);
	if (pct < 1) pct = 1;
	if (pct > 100) pct = 100;
	return pct;
}
// New MALL/AUTO rules, whichever run writes them, are held for this many days (and until a later-day preview has
// listed them) before they can sell, so a rule nobody has looked at never sells.
int hold_new_days() {
	int days = pref_int("tidy_holdNewDays", 1);
	return days < 0 ? 0 : days;
}
// The day number (UTC calendar day), read ONCE per run. The hold write day, the due test, the drip counters, the
// reprice record and the preview record must all use the same value: with separate clock reads, a preview that
// started before and ended after 00:00 UTC recorded itself as a later-day look at the rules it had just written.
int RUN_DAY = now_to_int() / 86400000;   // the only clock read; do not add another
// While false (default), potions, food, booze and spleen items with no rule start as KEEP.
boolean sell_consumables() { return get_property("tidy_sellConsumables") == "true"; }
boolean is_consumable(item it) {
	return it.fullness > 0 || it.inebriety > 0 || it.spleen > 0 || (it.usable && effect_modifier(it, "Effect") != $effect[none]);
}
// Daily reprice mode: "down" (default: never raise a price, never chase a collapsed market to the floor),
// "both" (move to market in either direction), "off" (never reprice).
string reprice_mode() {
	string mode = to_lower_case(get_property("tidy_reprice"));
	if (mode == "both" || mode == "off") return mode;
	return "down";
}
// A list line must name an item exactly: "[id]name", or the full name (case does not matter; the entity form
// "Pok&euml;mann" and the plain form both count). to_item() alone accepts any unique substring, so "cowbell" could
// quietly protect, pin or drip a different item than the one you meant.
item exact_item(string name, string listName) {
	item it = name.to_item();
	if (it == $item[none]) { print("tidy: " + listName + " line is not an item, ignored: " + name, "red"); return $item[none]; }
	if (name.starts_with("[")) return it;
	string want = to_lower_case(name);
	if (to_lower_case(it.name) == want || to_lower_case(entity_decode(it.name)) == want) return it;
	print("tidy: " + listName + " line '" + name + "' is not an exact item name (nearest match: " + it + "); ignored."
		+ " Use the full name or [id]name.", "red");
	return $item[none];
}
// Listings you never want repriced (data/tidy_pin_<name>.txt, one item name per line).
boolean [item] load_pin_list() {
	boolean [item] pins;
	string text = file_to_buffer(PIN_FILE).to_string();
	if (text.length() == 0) return pins;
	foreach i, line in text.split_string("\n") {
		string name = line;
		if (name.ends_with("\r")) name = name.substring(0, name.length() - 1);
		if (name.length() == 0 || name.starts_with("#")) continue;
		item it = exact_item(name, "pin list");
		if (it != $item[none]) pins[it] = true;
	}
	return pins;
}
boolean [item] PIN_LIST = load_pin_list();

// Capped at 0.25: a band wider than a quarter of the price is a mispricing, not a spread.
float price_jitter() {
	float jitter = get_property("tidy_priceJitter").to_float();
	if (jitter <= 0.0) return 0.0;
	return jitter > 0.25 ? 0.25 : jitter;
}
// KoL's own floor for a mall price: 100 meat, or twice the autosell value when that is higher (the store request
// clamps to it). Pricing under it is a no-op that would repeat daily, and with a factor under 1.0 a target below it.
// A negative autosell_price() is not "no value": mafia uses it for the few items that cannot be autosold but do carry
// a mall minimum other than 100 (the mafia wiki entry for autosell_price; mafia's own repricer in StoreManager takes
// abs() of it for the same reason). No item in the current items.txt has one, so the branch is dormant, not dead.
int mall_floor(item it) {
	int autosell = autosell_price(it);
	if (autosell < 0) autosell = -autosell;
	return max(100, 2 * autosell);
}
// The band a listing may sit in: factor - jitter .. factor + jitter, never above 1.0, never below the floor.
int band_low(item it, int mkt) {
	float lo = price_factor() - price_jitter();
	if (lo < 0.01) lo = 0.01;
	int price = floor(mkt * lo); int floorPrice = mall_floor(it);
	return price < floorPrice ? floorPrice : price;
}
int band_high(item it, int mkt) {
	float hi = price_factor() + price_jitter();
	if (hi > 1.0) hi = 1.0;
	int price = floor(mkt * hi); int floorPrice = mall_floor(it);
	return price < floorPrice ? floorPrice : price;
}
// A fresh price for a listing: a random point in the band (or exactly the factor when jitter is 0).
int target_price(item it, int mkt) {
	if (price_jitter() == 0.0) {
		int price = floor(mkt * price_factor()); int floorPrice = mall_floor(it);
		return price < floorPrice ? floorPrice : price;
	}
	int lo = band_low(it, mkt); int hi = band_high(it, mkt);
	if (hi <= lo) return lo;
	return lo + random(hi - lo + 1);
}

// Drip listings (data/tidy_drip_<name>.txt): item, count to list at a time, days to stay empty first.
record DripSpec {
	int n;       // copies to list at a time
	int days;    // days the listing must have been empty before relisting
};
// Rules tidy wrote that are still on hold: item -> "<write day> <decided keep-count> <held keep-count> <decision price>".
// Kept here, not in the rule's message column: Philter Manager writes an empty message for MALL/AUTO rules on every
// save, which used to erase the hold and leave a permanent "keep everything" rule behind.
string HOLD_FILE = "tidy_hold_" + DATA_NAME + ".txt";
// kept alongside the rule file's .prev, so revert restores both
string HOLD_BACKUP_FILE = "tidy_hold_" + DATA_NAME + ".prev.txt";
// The copy starts with this line, so revert can tell "no holds then" (a copy with only the marker) from "no copy at all" (a
// missing or 0-byte file: an install from before the copy existed). file_to_map and load_holds skip "#" lines, so the
// marker is harmless if it is ever read back as records.
string HOLD_COPY_MARK = "# tidy hold copy";
boolean hold_copy_present(buffer copy) { return copy.to_string().starts_with(HOLD_COPY_MARK); }
buffer hold_copy_body(buffer copy) {
	string text = copy.to_string();
	if (!text.starts_with(HOLD_COPY_MARK)) return copy;
	int nl = text.index_of("\n"); buffer body;
	if (nl >= 0) body.append(text.substring(nl + 1));
	return body;
}
boolean write_hold_copy(buffer holds) {
	buffer out;
	out.append(HOLD_COPY_MARK + "\n");
	out.append(holds.to_string());
	return buffer_to_file(out, HOLD_BACKUP_FILE);
}
string [item] HOLDS;
boolean HOLDS_CHANGED = false;
// Load the records; move any hold an older version left in a rule's message column ("tidy new <day> q<n>") over.
// Returns how many rules were changed that way (their message is cleared; the caller saves the rules).
int load_holds(OCDinfo [item] rules, string tag) {
	clear(HOLDS); HOLDS_CHANGED = false; int migrated = 0;
	file_to_map(HOLD_FILE, HOLDS);
	// every line must have loaded under a real item, or a hold could vanish silently (a tab lost, a byte-order mark,
	// an item this KoLmafia does not know): on any doubt keep every hold by stopping here
	int lines = 0;
	foreach i, raw in file_to_buffer(HOLD_FILE).to_string().split_string("\n") {
		string line = raw; if (line.ends_with("\r")) line = line.substring(0, line.length() - 1);
		if (!is_blank(line) && !line.starts_with("#")) lines += 1;
	}
	if (lines != count(HOLDS) || (HOLDS contains $item[none])) {
		string unknown = (HOLDS contains $item[none])
			? " (one names an item this KoLmafia does not know, or starts with a hidden byte-order mark)" : "";
		abort(tag + "data/" + HOLD_FILE + " has " + lines + " lines but " + count(HOLDS) + " readable hold records" + unknown
			+ ". Every hold is kept and nothing is sold until the file is fixed (tab-separated, plain UTF-8) or restored.");
	}
	foreach it, rule in rules {
		if (!rule.message.starts_with("tidy new ")) continue;
		string [int] fields = rule.message.split_string(" ");
		int since = (count(fields) > 2 && plain_digits(fields[2])) ? fields[2].to_int() : RUN_DAY;
		// no decision recorded: hold everything
		boolean hasQ = count(fields) > 3 && fields[3].length() > 1 && plain_digits(fields[3].substring(1));
		int decidedQ = hasQ ? fields[3].substring(1).to_int() : rule.q;
		if (!(HOLDS contains it)) HOLDS[it] = since + " " + decidedQ + " " + rule.q;
		rule.message = ""; HOLDS_CHANGED = true; migrated += 1;
	}
	return migrated;
}
int on_hand(item it);   // defined below (after the keep-list helpers); ASH needs to see it here
int sale_price(item it);   // likewise
// A new MALL/AUTO rule is held, whichever run writes it (preview, first run, closet preview or live): keep everything
// on hand, remember the decided keep-count, release only after the wait and a preview on a later day (see tidy_run).
void hold_new_rule(item it, OCDinfo rule, int decidedQ) {
	rule.q = on_hand(it);
	// the price the decision came from, re-checked at release; mafia caches "nothing listed" as -1, which would make the
	// record unreadable
	int price = sale_price(it); if (price < 0) price = 0;
	HOLDS[it] = RUN_DAY + " " + decidedQ + " " + rule.q + " " + price; HOLDS_CHANGED = true;
}
void snapshot_rules();   // defined below
void save_holds(string tag) {
	if (!HOLDS_CHANGED) return;
	snapshot_rules();   // the hold file is written before the rule file, so the run's undo point (both files) is taken here
	if (!map_to_file(HOLDS, HOLD_FILE)) abort(tag + "could not write " + HOLD_FILE + ". Stopping before anything is sold.");
	HOLDS_CHANGED = false;
}
// small facts that must live next to the rule file, not in a per-install preference
string STATE_FILE = "tidy_state_" + DATA_NAME + ".txt";
string [string] load_state() { string [string] state; file_to_map(STATE_FILE, state); return state; }
void save_state(string [string] state, string tag) {
	if (!map_to_file(state, STATE_FILE)) abort(tag + "could not write " + STATE_FILE + ". Stopping before anything is sold or repriced.");
}
// The preview record ("previewed", "previewDay"), the reset backup name and the inherited-file notice live here too:
// a KoLmafia preference is per install and is not scoped by tidy_rulesSuffix, so a preview under the test suffix used
// to arm the real holds, a reset under it left a test backup name for a real revert, and two installs sharing one data
// folder disagreed about whether anyone had previewed.
string state_get(string key) { string [string] state = load_state(); return (state contains key) ? state[key] : ""; }
void state_set(string key, string value, string tag) {
	string [string] state = load_state();
	if (value == "") { if (state contains key) remove state[key]; }
	else state[key] = value;
	save_state(state, tag);
}
// One-time move of the old preferences into the state file. Real rules only: a suffixed run must not import them.
void migrate_prefs(string tag) {
	if (get_property("tidy_rulesSuffix") != "") return;
	string [string] state = load_state(); boolean changed = false;
	// the old preview record is NOT carried over: an earlier version could have armed it from a test-suffix preview,
	// so one fresh preview is required after the upgrade. The backup name and the notice flag are harmless to keep.
	foreach pref in $strings[tidy_previewed, tidy_previewDay, tidy_resetBackup, tidy_inheritedNoticed] {
		string value = get_property(pref);
		if (value == "") continue;
		string key = pref.substring(5);
		if ((key == "resetBackup" || key == "inheritedNoticed") && !(state contains key)) { state[key] = value; changed = true; }
		set_property(pref, "");
	}
	if (changed) save_state(state, tag);
}
string DRIP_FILE = "tidy_drip_" + DATA_NAME + ".txt";
string DRIP_STATE_FILE = "tidy_drip_state_" + DATA_NAME + ".txt";   // real day number each drip listing was first seen empty
DripSpec [item] load_drip_list() {
	DripSpec [item] drips;
	string text = file_to_buffer(DRIP_FILE).to_string();
	if (text.length() == 0) return drips;
	foreach i, raw in text.split_string("\n") {
		string line = raw;
		if (line.ends_with("\r")) line = line.substring(0, line.length() - 1);
		if (line.length() == 0 || line.starts_with("#")) continue;
		string [int] fields = line.split_string("\t");
		item it = exact_item(fields[0], "drip list");
		if (it == $item[none]) continue;
		DripSpec spec;
		spec.n = (count(fields) > 1) ? fields[1].to_int() : 1;
		spec.days = (count(fields) > 2) ? fields[2].to_int() : 0;
		if (spec.n < 1) spec.n = 1;
		if (spec.days < 0) spec.days = 0;
		drips[it] = spec;
	}
	return drips;
}
DripSpec [item] DRIP_LIST = load_drip_list();

int sale_price(item it) {
	if (historical_age(it) < 1 && historical_price(it) > 0) return historical_price(it);
	return mall_price(it);
}

// HP/MP restoratives are supplies, not junk. Mafia knows them (data/restores.txt inside the jar) but
// scripts cannot read the jar, so tidy ships a copy as data/tidy_restores.txt (item name, tab, hp|mp|both).
string [string] load_restores() {
	string [string] raw; string [string] restores;
	file_to_map("tidy_restores.txt", raw);
	if (count(raw) == 0) print("tidy: data/tidy_restores.txt is missing or empty, so HP/MP restoratives get no special protection"
		+ " this run (reinstall tidy to get it back).", "red");
	// mafia item names carry entities (Pok&euml;mann); accept both forms
	foreach name, kind in raw { restores[name] = kind; restores[entity_decode(name)] = kind; }
	return restores;
}
string [string] RESTORES = load_restores();
boolean is_restorative(item it) { return RESTORES contains it.name; }

boolean is_tool_type(item it) {
	string kind = item_type(it);
	return kind.contains_text("reusable") || kind.contains_text("grow") || kind.contains_text("sticker")
		|| kind.contains_text("card") || kind.contains_text("folder") || kind.contains_text("spur")
		|| kind.contains_text("skin") || kind.contains_text("avatar") || kind.contains_text("message")
		|| kind.contains_text("zap");
}
// How many of a piece of gear you can wear at once: three accessory slots, one of anything else. Keep-counts built
// on this add the closet copies: Philter satisfies a keep-count with closet copies first and sells from the bag, then
// off your body, so a "keep 1" with one copy in the closet would sell the one you are wearing.
int gear_slots(item it) { return it.to_slot() == $slot[acc1] ? 3 : 1; }

// Always keep one of every piece of a saved custom outfit (three for accessories) and one of
// every familiar equipment item. Extras may sell; the last copy never does.
boolean [item] outfit_piece_set() {
	boolean [item] pieces;
	foreach i, outfitName in get_custom_outfits() {
		foreach j, it in outfit_pieces(outfitName) { if (it != $item[none]) pieces[it] = true; }
	}
	return pieces;
}
boolean is_protected_gear(item it, boolean [item] pieces) {
	return it.to_slot() == $slot[familiar] || (pieces contains it);
}
// Your own keep list (data/tidy_keep_<name>.txt), if you have one: item name, tab, count.
int [item] load_keep_list() {
	int [item] keeps;
	string text = file_to_buffer(KEEP_FILE).to_string();
	if (text.length() == 0) return keeps;
	foreach i, raw in text.split_string("\n") {
		string line = raw;
		if (line.ends_with("\r")) line = line.substring(0, line.length() - 1);
		if (line.length() == 0 || line.starts_with("#")) continue;
		string [int] fields = line.split_string("\t");
		item it = exact_item(fields[0], "keep list");
		if (it == $item[none]) continue;
		if (count(fields) < 2 || !plain_digits(fields[1])) {
			print("tidy: keep list line for " + it + " has no plain-number count, ignored: " + line, "red");
			continue;
		}
		keeps[it] = fields[1].to_int();
	}
	return keeps;
}
int [item] KEEP_LIST = load_keep_list();
// Minimum copies to keep on hand: keep-list items keep their listed count,
// outfit pieces and familiar equipment keep as many as you can wear (3 for accessories, else 1), everything else 0.
int protect_min(item it, boolean [item] pieces) {
	if ((KEEP_LIST contains it) && KEEP_LIST[it] > 0) return KEEP_LIST[it];
	if (is_protected_gear(it, pieces)) return gear_slots(it) + closet_amount(it);
	return 0;
}
// What Philter measures a keep-count against: bag + closet + worn, where "worn" includes equipment on every familiar in
// the terrarium, not just the active one (mafia's accessible count adds getEquippedCount(item, true)). Items installed
// in the campground also count for Philter and are not counted here; nothing tidy writes rules for lives there.
int on_hand(item it) { return item_amount(it) + closet_amount(it) + equipped_amount(it, true); }
// The floor a MALL/AUTO keep-count may not go under, re-derived every time it is asked for: the keep-list, outfit or
// familiar-equipment minimum, or the copies worn by you or any familiar plus the closet copies, whichever is higher.
// Philter satisfies a keep-count with closet copies first, sells from the bag, then strips worn copies (in simulation
// too), so a rule under this floor sells the copy on your body. ONE formula, used by the keep-count patch, the hold
// check, the release, the drip and the top-up: three separate ones once disagreed, and the release day stripped gear.
int keep_floor(item it, boolean [item] pieces) {
	int minKeep = protect_min(it, pieces);
	// everything mafia counts as equipped, on you or any familiar: cards in the sleeve, codpiece gems and holstered
	// sixguns have no slot of their own but are counted (and Philter sees them too)
	int worn = equipped_amount(it, true);
	return max(minKeep, (worn > 0) ? worn + closet_amount(it) : 0);
}

string rule_line(item it, string action, int q, string info, string message) {
	return "[" + it.to_int() + "]" + it.name + "\t" + action + "\t" + q + "\t" + info + "\t" + message + "\n";
}

// Taken once per run, on the first write of the rule file, so "tidy revert" undoes the whole run and a run that
// writes nothing leaves the previous undo point alone. save_rules() is only ever reached after the file has been
// parsed and checked, so a broken file never lands in .prev.
void snapshot_rules() {
	if (SNAPSHOT_TAKEN) return;
	buffer current = file_to_buffer(RULES_FILE);
	// an empty file (first run, or after a reset) gives an empty .prev, "no previous version": a stale copy left by an
	// older run would otherwise come back, hold records and all, on a revert after the first run
	if (!buffer_to_file(current, BACKUP_FILE)) abort("tidy: could not write " + BACKUP_FILE
		+ ", so the last good copy of your rules could not be kept. Nothing changed, nothing sold.");
	if (!write_hold_copy(file_to_buffer(HOLD_FILE))) abort("tidy: could not write " + HOLD_BACKUP_FILE
		+ ", so the hold records could not be kept alongside the rules. Nothing changed, nothing sold.");
	SNAPSHOT_TAKEN = true;
}

// The whole file is always rewritten in canonical form ([id]name, action, q, info, message):
// Philter's loader crashes on a rule line that lost its trailing columns (editors strip trailing tabs).
void save_rules(OCDinfo [item] rules) {
	snapshot_rules();
	buffer out;
	foreach it, rule in rules out.append(rule_line(it, rule.action, rule.q, rule.info, rule.message));
	if (!buffer_to_file(out, RULES_FILE)) {
		// the hold file is written before the rule file and may already carry this run's records: put its previous version
		// back so the two stay a pair, or the next run reads the raised held counts as hand edits and drops the holds
		if (!buffer_to_file(hold_copy_body(file_to_buffer(HOLD_BACKUP_FILE)), HOLD_FILE))
			print("tidy: could not put the hold records back either; the next run may drop holds as hand edits.", "red");
		abort("tidy: failed to write " + RULES_FILE + ". Nothing sold.");
	}
	RULES_WRITTEN = true;
}

// Every non-comment line of the rule file must be in the parsed map, because save_rules() rewrites the whole file
// from that map: a line file_to_map skipped (no tab in it, an item this KoLmafia does not know, the same item twice)
// would be dropped silently on the next save and its item re-decided as "new". A column mafia would quietly coerce
// is just as bad: a keep-count that is not a number is read as 0 (and "5k" as 5000), an empty
// action, or a MALL minimum price that is not a number (Philter's own loader throws on that). Stop, and say which line.
void check_rule_file(OCDinfo [item] rules, string tag) {
	string text = file_to_buffer(RULES_FILE).to_string();
	int lines = 0; int noTab = 0; int unknown = 0; int badCol = 0; string first = ""; string firstWhy = "";
	foreach i, raw in text.split_string("\n") {
		string line = raw;
		if (line.ends_with("\r")) line = line.substring(0, line.length() - 1);
		if (line.length() == 0 || line.starts_with("#")) continue;
		lines += 1;
		int tab = line.index_of("\t");
		if (tab < 0) { noTab += 1; if (first == "") { first = line; firstWhy = "no tab"; } continue; }
		if (line.substring(0, tab).to_item() == $item[none]) {
			unknown += 1; if (first == "") { first = line; firstWhy = "unknown item"; }
			continue;
		}
		string [int] col = line.split_string("\t");
		string action = (count(col) > 1) ? col[1] : "";
		string keepCol = (count(col) > 2) ? col[2] : "";
		string info = (count(col) > 3) ? col[3] : "";
		string why = "";
		if (action.length() == 0) why = "an empty action column";
		else if (keepCol.length() > 0 && !plain_digits(keepCol))
			why = "a keep-count that is not a plain number ('" + keepCol + "', which mafia would read as " + keepCol.to_int() + ")";
		else if (action == "MALL" && info.length() > 0 && !plain_digits(info))
			why = "a MALL minimum price that is not a plain number ('" + info + "'; Philter refuses such a line)";
		if (why != "") { badCol += 1; if (first == "") { first = line; firstWhy = why; } }
	}
	// file_to_map files an unknown item under $item[none], one key however many such lines there are
	int known = count(rules) - ((rules contains $item[none]) ? 1 : 0);
	int dup = lines - noTab - unknown - known;
	if (noTab == 0 && unknown == 0 && dup <= 0 && badCol == 0) return;
	string why = "";
	if (noTab > 0) why += noTab + " line" + (noTab == 1 ? " has" : "s have") + " no tab in " + (noTab == 1 ? "it" : "them")
		+ " (an editor that turns tabs into spaces?); ";
	if (unknown > 0) why += unknown + " line" + (unknown == 1 ? " names" : "s name") + " an item this KoLmafia does not know"
		+ " (if that line looks normal, the file may start with a hidden byte-order mark: save it as plain UTF-8); ";
	if (dup > 0) why += dup + " line" + (dup == 1 ? " repeats" : "s repeat") + " an item already in the file; ";
	if (badCol > 0) why += badCol + " line" + (badCol == 1 ? " has" : "s have") + " a column mafia would silently rewrite; ";
	abort(tag + "data/" + RULES_FILE + " has " + lines + " rule lines, " + count(rules) + " loaded cleanly: " + why
		+ "first odd line (" + firstWhy + "): " + first + " -- a rewrite would drop or change them, so nothing was changed."
		+ " Fix the file in a tab-preserving editor, update KoLmafia, or run tidy reset to start over (the old file is backed up first).");
}

// Philter's default ruleset (installed with Philter); Bale's older OCDefault.txt as fallback.
OCDinfo [item] load_defaults() {
	OCDinfo [item] bale;
	if (!file_to_map("ocd-cleanup-default.txt", bale) || count(bale) == 0) file_to_map("OCDefault.txt", bale);
	if (count(bale) == 0) print("tidy: no default ruleset found (data/ocd-cleanup-default.txt from Philter, or OCDefault.txt):"
		+ " new item kinds get fewer KEEP defaults than usual.", "olive");
	return bale;
}

// Patch MALL/AUTO rules on protected items to keep at least the minimum, and bring copies
// back from the store for any protected item with fewer than that on hand.
void enforce_keep_one(OCDinfo [item] rules, boolean sim, string tag) {
	boolean [item] pieces = outfit_piece_set();
	int patched = 0;
	foreach it, rule in rules {
		int minKeep = protect_min(it, pieces);
		int need = keep_floor(it, pieces);   // the minimum, or the worn plus closet copies: gear on you or a familiar is never the extra
		// In a closet run the closet is empty at this point, so the floor would be the one-copy minimum again and one copy of
		// every unworn piece would stay out: the earlier lowering (worn copies or the keep-list count, no minimum) stands.
		if (CLOSET_RUN && rule.action == "CLST")
			need = max(equipped_amount(it, true), ((KEEP_LIST contains it) && KEEP_LIST[it] > 0) ? KEEP_LIST[it] : 0);
		if (need == 0) continue;
		// CLST too: Philter's fetch runs for every action but KEEP. Written in previews as well: Philter's simulation works from
		// the file and strips a worn copy into the bag whenever the count sits under the floor, sim switch or not; a preview
		// that only reported the raise left the next live run selling the copy the simulation had just taken off you.
		if ((rule.action == "MALL" || rule.action == "AUTO" || rule.action == "CLST") && rule.q < need) {
			int was = rule.q;
			rule.q = need;
			patched += 1;
			string worn = need > minKeep ? "; worn by you or a familiar, unequip it to sell it" : "";
			print("  keep " + need + " (was " + was + "): " + it + " (" + rule.action + worn + ")", "black");
		}
	}
	if (patched > 0) {
		save_rules(rules);
		print(tag + "set keep-N on " + patched + " rules (outfit pieces, familiar equipment, keep list, worn gear;"
			+ " previous file saved as " + BACKUP_FILE + ").", "blue");
	}
	int recovered = 0;
	foreach it, listed in get_shop() {
		int minKeep = protect_min(it, pieces);
		int need = minKeep - on_hand(it);
		if (minKeep == 0 || need <= 0) continue;
		if (need > listed) need = listed;
		if (sim) { print("  would take " + need + " " + it + " back from the store", "black"); recovered += 1; continue; }
		if (take_shop(need, it)) { recovered += 1; print("  took " + need + " " + it + " back from the store", "black"); }
		else abort(tag + "could not take " + it + " back from the store; mafia may be in an error state."
			+ " Stopping before anything is sold. Run 'refresh all' and try again.");
	}
	if (recovered > 0) print(tag + (sim ? "would bring " : "brought ") + plural(recovered, "protected item kind", "protected item kinds")
		+ " back from the store (fewer than the keep count were on hand).", "blue");
}

Decision keep(string why) { Decision verdict; verdict.action = "KEEP"; verdict.q = 0; verdict.why = why; return verdict; }
Decision sell(string action, int q, string why) { Decision verdict; verdict.action = action; verdict.q = q; verdict.why = why; return verdict; }

// Decide a rule for an item that has none yet. have = how many you have.
Decision decide(item it, int have, OCDinfo [item] bale, int [item] shop, boolean [item] pieces) {
	if (!is_tradeable(it)) return keep("untradeable");
	int price = sale_price(it);
	int keepAbove = keep_above();
	int minKeep = protect_min(it, pieces);
	if (minKeep > 0) {
		string why = (KEEP_LIST contains it) ? "on your keep list: keep " + minKeep : "outfit piece / familiar equipment: keep " + minKeep;
		if (have > minKeep && keepAbove > 0 && price >= keepAbove)
			return keep(why + ", extras worth " + rnum(price) + " each: yours to decide");
		if (have > minKeep && price > 0) return sell("MALL", minKeep, why + ", sell extras");
		if (have > minKeep) return keep(why + ", extras have no mall price");
		return keep(why);
	}
	if (shop contains it) return keep("already in your store: yours to decide");
	if (display_amount(it) > 0) return keep("also in display case");
	if (bale contains it && bale[it].action != "MALL" && bale[it].action != "AUTO") return keep("default ruleset says " + bale[it].action);
	if (is_restorative(it)) return keep("HP/MP restorative, a supply");
	int junkBelow = junk_below();
	if (junkBelow > 0 && price > 0 && price <= junkBelow && autosell_price(it) >= 1)
		return sell("AUTO", 0, "lazyman rule: mall " + rnum(price) + " is under " + rnum(junkBelow) + ", autosell");
	if (!sell_consumables() && is_consumable(it)) return keep("consumable: yours to decide (tidy_sellConsumables = true to sell these)");
	boolean gear = (it.to_slot() != $slot[none]);
	if (gear || is_tool_type(it)) {
		// closet copies sit inside the keep, so the copy you wear is never the extra; nor is a second worn copy (two of one
		// weapon dual-wielded, a hat-trick hat): the worn count wins over the slot count when it is higher
		int slots = max(gear_slots(it), equipped_amount(it, true)) + closet_amount(it);
		int cheap = (keepAbove > 0) ? keepAbove : 10000;   // "cheap" is the same line tidy_keepAbove draws for everything else
		if (have > slots && price > 0 && price < cheap) {
			if (price <= 100 && autosell_price(it) >= 1) return sell("AUTO", slots, "duplicate cheap gear, keep " + slots);
			if (price <= 100) return keep("duplicate gear at floor, no autosell value");
			return sell("MALL", slots, "duplicate cheap gear, keep " + slots);
		}
		return keep("gear/tool");
	}
	if (price <= 0) return keep("no mall price");
	if (keepAbove > 0 && price >= keepAbove) return keep("worth " + rnum(price) + " each: yours to decide");
	if (price <= 100) {
		if (autosell_price(it) >= 1) return sell("AUTO", 0, "mall at floor, autosell");
		return keep("floor price, no autosell value");
	}
	return sell("MALL", 0, "mall " + rnum(price));
}

// First run: no rule file yet. Write a rule for every inventory kind, sell nothing.
void bootstrap_rules(boolean sim, string tag) {
	if (file_to_buffer(RULES_FILE).length() > 0)
		abort(tag + "data/" + RULES_FILE + " exists but none of its lines parse as rules (tabs replaced by spaces? not the Philter"
			+ " format?). Nothing overwritten. Fix the file, or rename it away and run again.");
	print(tag + "no rule file " + RULES_FILE + " yet. Writing a starting rule for every item kind in your inventory."
		+ " Nothing is sold on this run.", "olive");
	OCDinfo [item] bale = load_defaults();
	cli_execute("refresh shop");
	int [item] shop = get_shop();
	boolean [item] pieces = outfit_piece_set();
	OCDinfo [item] fresh;
	int nMall = 0; int nAuto = 0; int nKeep = 0; int holdDays = hold_new_days();
	snapshot_rules();   // the undo point (no rules yet, so only the old hold records) before anything is written
	clear(HOLDS); HOLDS_CHANGED = true;   // a fresh rule file starts with fresh hold records
	foreach it, have in get_inventory() {
		Decision verdict = decide(it, on_hand(it), bale, shop, pieces);
		if (verdict.action == "MALL") nMall += 1; else if (verdict.action == "AUTO") nAuto += 1; else nKeep += 1;
		OCDinfo rule; rule.action = verdict.action; rule.q = verdict.q; rule.info = ""; rule.message = "";
		if (holdDays > 0 && verdict.action != "KEEP") hold_new_rule(it, rule, verdict.q);
		print("  " + have + " " + it + "  ->  " + verdict.action + (verdict.q > 0 ? " keep " + verdict.q : "") + "   (" + verdict.why + ")",
			verdict.action == "KEEP" ? "green" : "black");
		fresh[it] = rule;
	}
	save_holds(tag);
	save_rules(fresh);
	state_set("inheritedNoticed", "true", tag);   // this file is tidy's own, no inheritance notice needed
	print(tag + "wrote " + (nMall + nAuto + nKeep) + " rules to data/" + RULES_FILE
		+ " (" + nMall + " mall, " + nAuto + " autosell, " + nKeep + " keep).", "blue");
	if (holdDays > 0 && nMall + nAuto > 0) print(tag + "the " + (nMall + nAuto) + " MALL/AUTO rules are on hold: nothing sells on them"
		+ " until a preview on a later day has listed them with what would sell (tidy_holdNewDays).", "olive");
	print(tag + "Review them in the relay browser: -run script- > Philter Manager. Change anything you disagree with."
		+ " Tomorrow: tidy (the look), then tidy go.", "olive");
}

// "Market price" here is KoLmafia's mall_price(): it skips the five cheapest listings
// (limited stores and min-priced dumps), so it sits at or above the cheapest sellers and
// never undercuts anyone. Scripts cannot read the mall search page itself (mafia returns
// it empty), so the exact lowest seller is not available; this is the honest substitute.

// Philter's own floor for a MALL rule: the rule's fourth column, when it is a number (Philter Manager writes it).
int rule_min_price(OCDinfo [item] rules, item it) {
	if (!(rules contains it) || rules[it].action != "MALL") return 0;
	return plain_digits(rules[it].info) ? rules[it].info.to_int() : 0;
}

// Reprice every store listing to the current market price, once a day. The day is recorded in the state file next to
// the rule file BEFORE the first change, so a run that stops halfway cannot cut the same listing twice, and neither can
// two mafia installs that share one data folder (a preference would be per install).
void reprice_store(OCDinfo [item] rules, boolean sim, string tag) {
	string [string] state = load_state();
	if (!sim && (state contains "repriceDay") && state["repriceDay"] == RUN_DAY.to_string()) {
		print(tag + "store already repriced today; skipping that step.", "blue");
		return;
	}
	string mode = reprice_mode();
	if (mode == "off") { print(tag + "repricing is off (tidy_reprice = off); your prices are untouched.", "blue"); return; }
	int limit = protect_above();
	float factor = price_factor();
	int [item] shop = get_shop();
	int changed = 0; int same = 0; int protectedCount = 0; int parked = 0; int noPrice = 0; int pinned = 0;
	int wouldRaise = 0; int atFloor = 0; int atMarket = 0; int capped = 0; int atMin = 0; int failed = 0;
	int cutPct = max_cut_pct();
	if (!sim) { state["repriceDay"] = RUN_DAY.to_string(); save_state(state, tag); }
	foreach it, listed in shop {
		if (PIN_LIST contains it) { pinned += 1; continue; }
		int cur = shop_price(it);
		if (cur >= 999999999) { parked += 1; continue; }   // the "not for sale" convention, whatever the protect threshold says
		if (limit > 0 && cur > limit) { protectedCount += 1; continue; }
		// A live run searches fresh where it matters (listings at 10,000+, or a stale cache); cheap listings use the cached
		// price, or a big store means thousands of searches a day. A preview uses the cache throughout (one search per item
		// per session), so repeated previews do not hammer the mall.
		int mkt = (!sim && (cur >= 10000 || historical_age(it) >= 1.0)) ? mall_price(it, 0.0) : mall_price(it);
		if (mkt <= 0) { noPrice += 1; continue; }
		if (limit > 0 && mkt > limit) { protectedCount += 1; continue; }
		// about to change a price on a cached number? confirm with a fresh search first (live runs only)
		if (!sim && mkt != cur && cur < 10000 && historical_age(it) < 1.0) {
			mkt = mall_price(it, 0.0);
			if (mkt <= 0) { noPrice += 1; continue; }
			if (limit > 0 && mkt > limit) { protectedCount += 1; continue; }
		}
		// inside the allowed band already: leave it (with jitter 0 the band is a single price)
		if (cur >= band_low(it, mkt) && cur <= band_high(it, mkt)) { same += 1; continue; }
		if (mode == "down" && mkt <= mall_floor(it)) { atFloor += 1; continue; }   // market collapsed to the floor: not worth chasing
		int newPrice = target_price(it, mkt);
		if (newPrice == cur) { same += 1; continue; }
		if (mode == "down" && newPrice > cur) { wouldRaise += 1; continue; }   // never raise a price you set
		// Never cut a listing that is already at or under market. The market figure counts your own units, so when
		// you are the cheapest seller it IS your price, and a factor under 1.0 would cut you under yourself every day.
		if (newPrice < cur && cur <= mkt) { atMarket += 1; continue; }
		int minPrice = rule_min_price(rules, it);   // the rule's own minimum price is never undercut
		if (newPrice < minPrice) { newPrice = minPrice; atMin += 1; }
		int floorPrice = mall_floor(it);
		// no more than tidy_maxCutPct off in one day, and no more than that up in one day ("both" mode): a troll listing, or a
		// rule minimum far above the listing, cannot move you 900k in one step
		int floorToday = cur - (cur * cutPct / 100);
		int ceilToday = cur + (cur * cutPct / 100);
		if (newPrice < floorToday) { newPrice = floorToday < floorPrice ? floorPrice : floorToday; capped += 1; }
		if (newPrice > ceilToday) { newPrice = ceilToday; capped += 1; }
		if (newPrice == cur || (mode == "down" && newPrice > cur)) { same += 1; continue; }
		changed += 1;
		if (sim) print("  would reprice " + listed + " " + it + ": " + rnum(cur) + " -> " + rnum(newPrice), "black");
		else if (reprice_shop(newPrice, shop_limit(it), it))
			print("  repriced " + listed + " " + it + ": " + rnum(cur) + " -> " + rnum(newPrice), "black");
		else { failed += 1; print(tag + "could not reprice " + it + "; left at " + rnum(cur) + ".", "red"); }
	}
	if (failed > 0) abort(tag + plural(failed, "reprice", "reprices") + " failed; mafia may be in an error state."
		+ " Stopping before Philter. Run 'refresh all' and try again.");
	if (capped > 0) print(tag + plural(capped, "change", "changes") + " limited to " + cutPct + "% today (tidy_maxCutPct);"
		+ " the rest of the way comes on later days if the market stays there.", "blue");
	if (atMin > 0) print(tag + plural(atMin, "listing", "listings")
		+ " held at the rule's own minimum price (Philter Manager's minimum column).", "blue");
	string how = (factor < 1.0 || price_jitter() > 0.0)
		? " (factor " + factor + (price_jitter() > 0.0 ? " +/- " + price_jitter() : "") + ")" : "";
	string leftAlone = (limit > 0) ? "over " + rnum(limit) + " meat" : "protect threshold off";
	print(tag + (sim ? "would reprice " : "repriced ") + plural(changed, "listing", "listings") + " to market" + how + "; "
		+ same + " already there; " + protectedCount + " left alone (" + leftAlone + "); " + parked + " parked at 999,999,999+; "
		+ pinned + " pinned; " + noPrice + " with no market price.", "blue");
	if (mode == "down" && (wouldRaise > 0 || atFloor > 0))
		print(tag + wouldRaise + " below market and left there (tidy never raises your prices); " + atFloor
			+ " with a market at KoL's floor, not chased. Set tidy_reprice = both to change that.", "blue");
	if (atMarket > 0) print(tag + atMarket + " already at or under market and left there (a price factor only applies to listings"
		+ " above market, so you never chase your own price down).", "blue");
}

// Drip listings: list a fixed count only when the store holds none (and it has been empty long
// enough), never top up while any are listed, and hold the rest in inventory by setting the
// rule's keep-count to whatever is on hand, so Philter never lists it either.
void drip_step(OCDinfo [item] rules, int [item] shop, boolean sim, string tag) {
	if (count(DRIP_LIST) == 0) return;
	int [item] state;
	file_to_map(DRIP_STATE_FILE, state);
	int today = RUN_DAY;   // real (UTC) days, never wraps (the in-game calendar day wraps every 96 days)
	int listed = 0; int waiting = 0; int held = 0; boolean changed = false;
	boolean [item] pieces = outfit_piece_set();
	foreach it, spec in DRIP_LIST {
		if (!(rules contains it) || rules[it].action != "MALL") {
			print("  drip: " + it + " skipped, its rule is " + ((rules contains it) ? rules[it].action : "missing") + ", not MALL", "olive");
			continue;
		}
		if (HOLDS contains it) { print("  drip: " + it + " skipped, its rule is still on hold", "olive"); continue; }
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
				int mkt = sim ? mall_price(it) : mall_price(it, 0.0);
				if (mkt <= 0) print(tag + "drip: no market price for " + it + "; not listed.", "red");
				else {
					int price = max(target_price(it, mkt), rule_min_price(rules, it));
					// never below your keep list / outfit minimum
					int lot = min(spec.n, min(item_amount(it), on_hand(it) - protect_min(it, pieces)));
					if (lot <= 0) print("  drip: " + it + " not listed; all copies on hand are inside your keep-list or outfit minimum", "olive");
					else {
						listed += 1;
						if (sim) print("  drip: would list " + lot + " " + it + " at " + rnum(price)
							+ " (holding " + (item_amount(it) - lot) + " back)", "black");
						else if (put_shop(price, 0, lot, it)) {
							print("  drip: listed " + lot + " " + it + " at " + rnum(price) + " (holding " + item_amount(it) + " back)", "black");
							remove state[it];
						}
						else abort(tag + "drip: could not list " + it + "; mafia may be in an error state."
							+ " Stopping before Philter. Run 'refresh all' and try again.");
					}
				}
			}
		}
		// whatever is still on hand stays on hand: Philter must not list it (it counts bag + closet + worn, so keep that many);
		// never under the keep-count floor either, or this and the keep-count check would rewrite the file twice every run
		if ((rules contains it) && rules[it].action != "KEEP") {
			int want = max(on_hand(it), keep_floor(it, pieces));
			if (rules[it].q != want) { rules[it].q = want; changed = true; }
		}
	}
	if (!map_to_file(state, DRIP_STATE_FILE))
		print(tag + "warning: could not write " + DRIP_STATE_FILE + "; the empty-day counters may be off tomorrow.", "red");
	if (changed) save_rules(rules);   // only a real change moves the .prev undo point
	print(tag + "drip: " + listed + " " + (sim ? "would be " : "") + "listed, " + waiting + " waiting out the empty days, "
		+ held + " held back while listed. Rule keep-counts set to what is on hand.", "blue");
}

// Set one of Philter's zlib settings and prove it stuck. The "zlib name = value" CLI command
// silently refuses a name it has never seen, and Philter only creates its settings the first
// time Philter itself runs; on a fresh install that would have left BaleOCD_Sim unset and turned
// a preview into a live run. So write through zlib's own map, save, and read back, or stop.
void set_philter_var(string name, string value, string tag) {
	vars[name] = value;
	// the proof is this boolean; getvar() below reads zlib's in-memory map, and the vars file omits values equal to the defaults
	boolean saved = updatevars();
	if (!saved || getvar(name) != value)
		abort(tag + "could not set Philter's " + name + " to " + value + ". Stopping before anything is sold.");
}

void common_guards(boolean sim, string tag) {
	if (!sim && get_property("tidy_rulesSuffix") != "") abort(tag + "tidy_rulesSuffix is set to '" + get_property("tidy_rulesSuffix")
		+ "', which points at a test rule file. Live runs are refused while it is set. Clear it with: set tidy_rulesSuffix =");
	if (DATAFILE_BEFORE != "" && DATAFILE_BEFORE != BASE_NAME && DATAFILE_BEFORE != DATA_NAME)
		print(tag + "Philter's BaleOCD_DataFile is '" + DATAFILE_BEFORE + "', but tidy works on OCDdata_" + BASE_NAME + ".txt and points Philter"
			+ " at that file only while Philter runs (then puts yours back). If '" + DATAFILE_BEFORE + "' is a test file left behind by a run"
			+ " that stopped early, put Philter back with: zlib BaleOCD_DataFile = " + BASE_NAME + ". Only if it really is your own rule file:"
			+ " set tidy_dataFile = " + DATAFILE_BEFORE, "olive");
	string factorText = get_property("tidy_priceFactor");
	if (factorText != "" && (factorText.to_float() < 0.5 || factorText.to_float() > 1.0))
		abort(tag + "tidy_priceFactor is set to '" + factorText + "'; it must be between 0.5 and 1.0 (1.0 = match the market, 0.99 = list 1% under it)."
			+ " Fix it with: set tidy_priceFactor = 1.0. Nothing done.");
	if (!can_interact()) abort(tag + "you are in Ronin or Hardcore. This is an aftercore tool.");
	if (get_property("lastEmptiedStorage").to_int() != my_ascensions())
		abort(tag + "Hagnk's has not been emptied this ascension. Run 'pull all' first.");
	// read the map, not getvar(): a missing name prints a purple line
	string emptyCloset = (vars contains "BaleOCD_EmptyCloset") ? vars["BaleOCD_EmptyCloset"] : "";
	if (emptyCloset != "-1") {
		print(tag + "BaleOCD_EmptyCloset was '" + emptyCloset + "'; setting it to -1 so Philter never dumps the closet on its own.", "olive");
		set_philter_var("BaleOCD_EmptyCloset", "-1", tag);
	}
}
// Philter is pointed at this character's rule file only for the moment it runs (see tidy_run), and back at the real file
// afterwards, so a run under the test suffix never leaves Philter or its Manager looking at the test file.
void restore_datafile(string tag) {
	// back to whatever it was, exactly; only tidy's own name for this run (or nothing) becomes the base name. A test name a
	// stopped run left behind is put back as found and reported by the notice in common_guards, never guessed at.
	string back = (DATAFILE_BEFORE == "" || DATAFILE_BEFORE == DATA_NAME) ? BASE_NAME : DATAFILE_BEFORE;
	if (getvar("BaleOCD_DataFile") != back) set_philter_var("BaleOCD_DataFile", back, tag);
}

void tidy_run(boolean sim);   // defined below; ASH needs to see it before tidy_closet_run uses it

// Write rules for closet items that have none, and turn KEEP rules on closet items into
// CLST rules that keep today's inventory count on hand and file the rest back into the closet.
// Items that grant a skill stay in the closet too. Returns how many rules were written.
int closet_bootstrap(OCDinfo [item] rules, int [item] closet, string tag, boolean apply) {
	OCDinfo [item] bale = load_defaults();
	cli_execute("refresh shop");
	int [item] shop = get_shop();
	boolean [item] pieces = outfit_piece_set();
	int added = 0; int converted = 0; int relowered = 0; int heldNew = 0; int holdDays = hold_new_days();
	foreach it, have in closet {
		if (rules contains it) {
			if (rules[it].action == "KEEP") {
				converted += 1;
				// what is out of the closet now (bag, you, your familiars) stays out
				int keepOut = item_amount(it) + equipped_amount(it, true);
				if (apply) { rules[it].action = "CLST"; rules[it].q = keepOut; }
				print("  " + it + ": KEEP -> CLST keep " + keepOut + " (closet copies go back to the closet)"
					+ (apply ? "" : " [applied on the live run]"), "black");
			}
			else if (rules[it].action == "CLST" && rules[it].q == keep_floor(it, pieces)) {
				// A CLST rule on protected gear (outfit piece, familiar equipment, keep-list item) sits at tidy's floor, which
				// counts the closet copies. That is right every day but wrong on the one day the closet is emptied: the closet
				// copies would then be inside the keep and stay in the bag for good. For this run only, the keep-count is the copies
				// you or a familiar wear, or the keep-list count if higher; a bag copy is a spare and goes back too. There is
				// no one-copy minimum here: a CLST rule never sells, so keeping none in the bag is safe, and the next day's run
				// raises the count to the floor again once the copies are closeted. (The first version kept one copy of every
				// such item out, worn or not, which left ten pieces of unworn familiar gear in the bag after a real closet run; the
				// second counted bag copies as "out", so a copy that had escaped the closet once stayed out on every later run.)
				int minAfter = ((KEEP_LIST contains it) && KEEP_LIST[it] > 0) ? KEEP_LIST[it] : 0;
				int keepOut = max(equipped_amount(it, true), minAfter);
				if (keepOut < rules[it].q) {
					relowered += 1;
					int was = rules[it].q;
					if (apply) rules[it].q = keepOut;
					print("  " + it + ": CLST keep " + was + " -> keep " + keepOut + " for this run, so every unworn copy goes back"
						+ (apply ? "" : " [applied on the live run]"), "black");
				}
			}
			continue;
		}
		OCDinfo rule;
		// an item that grants a skill is never sold; otherwise the generator decides
		Decision verdict = (it.skill != $skill[none]) ? keep("grants a skill") : decide(it, on_hand(it), bale, shop, pieces);
		// a KEEP decision becomes CLST only on the live run, after the closet is emptied: written as CLST while the
		// closet is still full, Philter would closet the bag copies and strip a worn one on the next plain tidy go
		if (verdict.action == "KEEP") {
			if (apply) { rule.action = "CLST"; rule.q = item_amount(it) + equipped_amount(it, true); }
			else { rule.action = "KEEP"; rule.q = 0; }
		}
		else {
			rule.action = verdict.action; rule.q = verdict.q;
			if (holdDays > 0) { hold_new_rule(it, rule, verdict.q); heldNew += 1; }
		}
		rules[it] = rule; added += 1;
		string heldTag = (HOLDS contains it) ? "   [held]" : "";
		string becomes = (rule.action == "KEEP" && !apply)
			? "   (becomes CLST keep " + (item_amount(it) + equipped_amount(it, true)) + " when tidycloset go runs)" : "";
		print("  " + have + " " + it + "  ->  " + rule.action + (rule.q > 0 ? " keep " + rule.q : "") + heldTag + becomes,
			(rule.action == "CLST" || rule.action == "KEEP") ? "green" : "black");
	}
	save_holds(tag);
	if (added > 0 || (apply && converted + relowered > 0)) save_rules(rules);
	if (heldNew > 0) print(tag + plural(heldNew, "new MALL/AUTO closet rule is", "new MALL/AUTO closet rules are")
		+ " on hold: nothing sells on them until a preview on a later day has listed them.", "olive");
	if (added + converted + relowered > 0) {
		string relowerNote = relowered > 0
			? "; " + plural(relowered, "CLST keep-count", "CLST keep-counts") + " on outfit, familiar or keep-list gear "
				+ (apply ? "set" : "would be set") + " to the worn copies (or the keep-list count) for this run" : "";
		print(tag + "wrote " + added + " new closet rules; " + converted + " KEEP rules " + (apply ? "converted" : "would be converted") + " to CLST"
			+ relowerNote + (apply ? "" : " when tidycloset go runs") + " (previous file saved as " + BACKUP_FILE + ")."
			+ " Review them in Philter Manager before running tidycloset go.", "blue");
	}
	return added + converted;
}

// One-time (or occasional) closet liquidation: everything in the closet comes out,
// then the normal tidy pipeline runs. Items with a CLST rule are filed straight back.
// The preview writes any missing closet rules; the live run refuses until a preview ran today.
void tidy_closet_run(boolean sim) {
	string tag = sim ? "tidycloset (preview): " : "tidycloset: ";
	common_guards(sim, tag);
	migrate_prefs(tag);
	OCDinfo [item] rules;
	if (!file_to_map(RULES_FILE, rules) || count(rules) == 0) abort(tag + "no rule file " + RULES_FILE + " yet. Run plain tidy first.");
	if (!sim && state_get("closetPreviewedDay") != RUN_DAY.to_string())
		abort(tag + "run the preview first (plain tidycloset, no go, on the same UTC day) and look at what it will do.");
	if (!sim && state_get("previewed") != "true")
		abort(tag + "run a plain tidy preview first and look at what it will do. Nothing was changed.");
	check_rule_file(rules, tag);
	// legacy message-column markers moved to the hold file: save the cleared messages
	if (load_holds(rules, tag) > 0) save_rules(rules);
	cli_execute("refresh closet");
	int [item] closet = get_closet();
	closet_bootstrap(rules, closet, tag, !sim);
	int kinds = 0; int total = 0; int missing = 0;
	int [string] kindsBy; int [string] itemsBy; int mallVal = 0; int autoVal = 0;
	foreach it, have in closet {
		kinds += 1; total += have;
		if (!(rules contains it)) { missing += 1; if (missing <= 15) print("  no rule: " + have + " " + it, "red"); continue; }
		string action = rules[it].action;
		int sellable = max(0, have + item_amount(it) + equipped_amount(it, true) - rules[it].q);
		kindsBy[action] += 1; itemsBy[action] += have;
		if (action == "MALL") mallVal += min(sellable, have) * (historical_price(it) > 0 ? historical_price(it) : 0);
		if (action == "AUTO") autoVal += min(sellable, have) * autosell_price(it);
	}
	print(tag + kinds + " kinds / " + total + " items in the closet.", "blue");
	foreach action, kindCount in kindsBy print("  " + action + ": " + kindCount + " kinds, " + itemsBy[action] + " items", "black");
	print(tag + "mall listings worth about " + rnum(mallVal) + " meat; autosell about " + rnum(autoVal) + " meat (cached prices).", "blue");
	if (missing > 0) abort(tag + missing + " closet item kinds have no rule."
		+ " Run plain tidycloset (the preview) to write them, then run again.");
	if (sim) {
		state_set("closetPreviewedDay", RUN_DAY.to_string(), tag);
		print(tag + "preview only; the closet was not touched. If the tally looks right, run tidycloset go today (same UTC day).", "olive");
		return;
	}
	print(tag + "emptying the closet into inventory... (if a later step stops this run, the closet stays in your inventory;"
		+ " fix the cause and run tidy go)", "red");
	if (!empty_closet()) abort(tag + "could not empty the closet. Nothing sold.");
	CLOSET_RUN = true;
	tidy_run(false);
	CLOSET_RUN = false;
	cli_execute("refresh closet");
	print(tag + "done. Closet now holds " + count(get_closet()) + " kinds.", "blue");
}

// Help is printed as HTML: the gCLI collapses tabs and runs of spaces, so bold and colour do the layout.
void h_section(string text) { print_html("<font color='#1f6fb2'><b>" + text + "</b></font>"); }
void h_cmd(string cmd, string text) { print_html("<b>" + cmd + "</b> - " + text); }
void tidy_help() {
	print_html("<font color='#1f6fb2'><b>tidy</b> - inventory cleanup on top of Philter. Nothing runs live without the word <b>go</b>.</font>");
	h_section("Commands");
	h_cmd("tidy", "preview: writes rules for new item kinds, shows what a live run would do, sells nothing (also: tidy sim)");
	h_cmd("tidy go", "LIVE: new rules, store top-ups at your prices, daily reprice, then Philter");
	h_cmd("tidycloset", "preview: rules for closet items that lack one, then a tally; moves nothing");
	h_cmd("tidycloset go", "LIVE, one-off: empties the closet into inventory and runs the tidy pipeline");
	h_cmd("tidy reset", "clean sweep: backs up your rule file, then writes fresh rules for every item kind in your inventory (sells nothing)");
	h_cmd("tidy revert", "undo the last change tidy made to your rule file (after a reset, restores the backup;"
		+ " otherwise swaps in the .prev copy)");
	h_cmd("tidy help", "this text. Any other word prints it too and does nothing else");
	h_section("Settings (set name = value)");
	h_cmd("tidy_keepAbove", pref_text("tidy_keepAbove", "10000")
		+ " - new item kinds worth this much each start as KEEP, whatever the count (0 = off)");
	h_cmd("tidy_reprice", reprice_mode()
		+ " - down = never raise, never chase a floor; both = follow market either way; off = never reprice");
	h_cmd("tidy_protectAbove", pref_text("tidy_protectAbove", "1000000") + " - listings priced above this are never repriced (0 = off)");
	h_cmd("tidy_priceFactor", price_factor() + " - multiply the market price when repricing (1.0 = match, 0.99 = 1% under)");
	h_cmd("tidy_priceJitter", price_jitter() + " - random spread around the factor, per item per day (0 = off)");
	h_cmd("tidy_maxCutPct", pref_text("tidy_maxCutPct", "30")
		+ "% - the most one listing may be cut in one day; the rest comes on later days if the market stays down");
	h_cmd("tidy_holdNewDays", pref_text("tidy_holdNewDays", "1")
		+ " - rules tidy writes for new item kinds (in any run) are held this many days, and until a later-day preview has listed them (0 = off)");
	h_cmd("tidy_junkBelow", pref_text("tidy_junkBelow", "off")
		+ " - the lazyman rule: new item kinds worth this much or less each, with an autosell value, start as AUTO, gear and consumables"
		+ " included (set above 100 to turn on)");
	h_cmd("tidy_sellConsumables", (sell_consumables() ? "true" : "false")
		+ " - false = potions, food, booze and spleen items with no rule start as KEEP");
	h_cmd("tidy_allowGiving", (get_property("tidy_allowGiving") == "true" ? "true" : "false")
		+ " - false = old CLAN/GIFT/DISC rules (clan stash, kmail, discard) are turned into KEEP");
	h_cmd("tidy_dataFile", (get_property("tidy_dataFile") == "" ? my_name() + " (default: your name)" : get_property("tidy_dataFile"))
		+ " - the Philter rule file tidy works on, OCDdata_<this>.txt");
	h_section("Files in data/ (all optional)");
	h_cmd(RULES_FILE, "your rules (edit in Philter Manager)");
	h_cmd(KEEP_FILE, "item, tab, count: always keep that many on hand (" + count(KEEP_LIST) + " loaded)");
	h_cmd(PIN_FILE, "one item per line: never reprice these listings (" + count(PIN_LIST) + " loaded)");
	h_cmd(DRIP_FILE, "item, tab, count, tab, days: small lots that run dry before relisting (" + count(DRIP_LIST) + " loaded)");
	h_cmd(HOLD_FILE, "rules tidy wrote that are still on hold (tidy keeps this; leave it alone)");
	h_cmd(STATE_FILE, "tidy's own records: last preview and its day, reprice day, closet-preview day, reset backup names,"
		+ " inherited-file notice (tidy keeps this)");
	h_cmd(DRIP_STATE_FILE, "the day each drip listing was first seen empty (tidy keeps this)");
	print_html("<font color='olive'>Rules of the road: whitelist only (no rule, no action); aftercore only; Hagnk's must be emptied;"
		+ " KoL's price floor (100 meat or twice the autosell value) and a rule's own minimum price always hold.</font>");
}

// Clean sweep: back the rule file up, empty it, and run the first-run preview again (nothing sold).
void tidy_reset() {
	string tag = "tidy reset: ";
	common_guards(true, tag);   // the same checks as a preview, before anything is touched
	migrate_prefs(tag);
	buffer current = file_to_buffer(RULES_FILE);
	if (current.length() == 0) {
		print(tag + "no rule file " + RULES_FILE + " to reset; writing a fresh one now (a plain tidy is still needed before tidy go).", "olive");
		IN_RESET = true; tidy_run(true); IN_RESET = false;
		return;
	}
	string stamp = now_to_string("yyyyMMdd-HHmmss");
	string backupName = "OCDdata_" + DATA_NAME + ".before-reset-" + stamp + ".txt";
	string holdBackup = "tidy_hold_" + DATA_NAME + ".before-reset-" + stamp + ".txt";
	if (!buffer_to_file(current, backupName)) abort(tag + "could not write the backup " + backupName + ". Nothing changed.");
	if (!buffer_to_file(file_to_buffer(HOLD_FILE), holdBackup))
		abort(tag + "could not write the hold-record backup " + holdBackup + ". Nothing changed.");
	// the record goes in before the destructive write, so a failed record write changes nothing
	state_set("resetBackup", backupName, tag);   // "tidy revert" restores this first
	state_set("resetHoldBackup", holdBackup, tag);
	state_set("previewed", "false", tag);        // the fresh rules have not been looked at yet
	state_set("previewDay", "", tag);
	buffer empty;
	if (!buffer_to_file(empty, RULES_FILE))
		abort(tag + "could not clear " + RULES_FILE + ". Your old rules are still in place (backup at " + backupName + ").");
	print(tag + "old rules saved as data/" + backupName + " (hold records as " + holdBackup + "). Undo with: tidy revert."
		+ " Run a plain tidy and look before tidy go.", "olive");
	IN_RESET = true;
	tidy_run(true);
	IN_RESET = false;
}

// Undo: after a reset, restore the dated backup; otherwise swap the rule file with its .prev copy
// (the version before tidy's last write; run again to swap back).
void tidy_revert() {
	string tag = "tidy revert: ";
	common_guards(true, tag);
	migrate_prefs(tag);
	string resetBackup = state_get("resetBackup");
	if (resetBackup != "") {
		buffer old = file_to_buffer(resetBackup);
		OCDinfo [item] oldRules; file_to_map(resetBackup, oldRules);
		if (old.length() > 0 && count(oldRules) == 0)
			abort(tag + "the reset backup " + resetBackup + " holds no readable rules; not restoring it. Nothing changed.");
		if (old.length() > 0) {
			state_set("previewed", "false", tag);   // the gate first: a failed write below must not leave a live run armed
			state_set("previewDay", "", tag);
			buffer current = file_to_buffer(RULES_FILE);
			if (!buffer_to_file(old, RULES_FILE)) abort(tag + "could not write " + RULES_FILE + ". Nothing changed.");
			if (!buffer_to_file(current, BACKUP_FILE))
				print(tag + "warning: could not write " + BACKUP_FILE + ", so a second revert cannot swap back.", "red");
			string holdBackup = state_get("resetHoldBackup");
			if (holdBackup != "") {
				if (!write_hold_copy(file_to_buffer(HOLD_FILE)))
					print(tag + "warning: could not keep the current hold records in " + HOLD_BACKUP_FILE + ".", "red");
				if (!buffer_to_file(file_to_buffer(holdBackup), HOLD_FILE))
					print(tag + "warning: could not restore the hold records from " + holdBackup + "; they are still in that file.", "red");
			}
			state_set("resetBackup", "", tag);
			state_set("resetHoldBackup", "", tag);
			OCDinfo [item] check; file_to_map(RULES_FILE, check);
			print(tag + "the reset is undone: " + RULES_FILE + " is back to the " + count(check) + " rules saved in " + resetBackup
				+ (holdBackup != "" ? ", hold records restored too" : "") + ". Nothing was sold. Run a plain tidy before the next tidy go.", "olive");
			return;
		}
	}
	buffer prev = file_to_buffer(BACKUP_FILE);
	if (prev.length() == 0) abort(tag + "no previous version (" + BACKUP_FILE + ") to go back to. Nothing changed.");
	buffer current = file_to_buffer(RULES_FILE);
	OCDinfo [item] check; file_to_map(BACKUP_FILE, check);
	if (count(check) == 0) abort(tag + BACKUP_FILE + " holds no readable rules (tabs replaced by spaces?), so it is not a version"
		+ " worth going back to; not restoring it. Nothing changed.");
	// the hold records travel with the rules: both .prev copies are taken together, on a run's first write of either file,
	// so "nothing to go back to" means both match. A run that only dropped a hold leaves the rule file identical and
	// the records different; revert then restores the records and leaves the rule file as it is.
	buffer prevCopy = file_to_buffer(HOLD_BACKUP_FILE); buffer curHolds = file_to_buffer(HOLD_FILE);
	// a marked copy, or an unmarked non-empty one from the version before the marker
	boolean haveCopy = hold_copy_present(prevCopy) || prevCopy.length() > 0;
	buffer prevHolds = hold_copy_body(prevCopy);
	boolean sameRules = (prev.to_string() == current.to_string());
	boolean sameHolds = (prevHolds.to_string() == curHolds.to_string());
	if (sameRules && sameHolds) abort(tag + BACKUP_FILE + " is identical to the current rule file, and the hold records match their"
		+ " previous copy too, so there is no earlier version to go back to. Nothing changed.");
	state_set("previewed", "false", tag);   // the gate first
	state_set("previewDay", "", tag);
	if (!sameRules) {
		if (!buffer_to_file(prev, RULES_FILE)) abort(tag + "could not write " + RULES_FILE + ". Nothing changed.");
		if (!buffer_to_file(current, BACKUP_FILE))
			print(tag + "warning: could not write " + BACKUP_FILE + ", so a second revert cannot swap back.", "red");
	}
	// No copy at all (a missing or 0-byte file: an install from before the copy existed) is not a version to go back to: the
	// records are kept, and any that no longer match a rule are dropped with a message on the next run. A copy that holds
	// only the marker is a real "no holds then" and is restored as such.
	if (!haveCopy && curHolds.length() > 0) print(tag + "no previous hold records to go back to (an older version kept no copy);"
		+ " the current records are kept, and any that no longer match a rule are dropped on the next run.", "olive");
	else if (!sameHolds && !buffer_to_file(prevHolds, HOLD_FILE)) print(tag + "warning: could not restore " + HOLD_FILE
		+ "; the hold records may not match the restored rules (a mismatched hold is dropped with a message on the next run).", "red");
	if (!write_hold_copy(curHolds)) print(tag + "warning: could not write " + HOLD_BACKUP_FILE + ".", "red");
	string outcome = sameRules
		? RULES_FILE + " was already identical to its previous version and is unchanged; the hold records are back to theirs"
		: RULES_FILE + " is back to its previous version (" + count(check) + " rules), hold records with it";
	print(tag + outcome + ". Run tidy revert again to swap back (only if no run has written the file in between). Nothing was sold."
		+ " Run a plain tidy before the next tidy go.", "olive");
}

// Entry point for the argument-taking scripts. Bare = preview. "go" = live. "reset" = clean sweep. Anything else = help.
void tidy_dispatch(string which, string [int] args) {
	string word = (count(args) > 0) ? to_lower_case(args[0]) : "";
	if (count(args) > 1) { print("tidy: one word at a time, please. Commands:", "red"); tidy_help(); return; }
	if (word == "reset" && which == "tidy") { tidy_reset(); return; }
	if (word == "revert" && which == "tidy") { tidy_revert(); return; }
	if (word == "sim" || word == "preview") word = "";
	if (word != "" && word != "go") {
		if (word != "help") print("tidy: I do not know the word '" + args[0] + "'. Nothing was done. Commands:", "red");
		tidy_help();
		return;
	}
	boolean sim = (word != "go");
	if (which == "closet") tidy_closet_run(sim);
	else tidy_run(sim);
}

// What an old Philter/OCD action does, for the inherited-file notice.
string action_note(string action) {
	if (action == "CLAN") return " (put in the clan stash)";
	if (action == "GIFT") return " (kmail to another player)";
	if (action == "PULV") return " (pulverize)";
	if (action == "DISP") return " (display case)";
	if (action == "MAKE") return " (craft into something)";
	if (action == "USE") return " (use it)";
	if (action == "UNTN") return " (untinker)";
	if (action == "BREAK") return " (break apart)";
	if (action == "DISC") return " (discard, destroys the item)";
	if (action == "TODO") return " (a reminder, does nothing)";
	return "";
}

void tidy_run(boolean sim) {
	string tag = sim ? "tidy (preview): " : "tidy: ";
	common_guards(sim, tag);
	migrate_prefs(tag);

	// ---- first run: write rules, sell nothing
	OCDinfo [item] rules;
	if (!file_to_map(RULES_FILE, rules) || count(rules) == 0) {
		bootstrap_rules(sim, tag);   // stops if the file exists but nothing in it parses, before anything is copied over .prev
		if (!sim) return;
		clear(rules);
		file_to_map(RULES_FILE, rules);
	}
	// every line must have made it into the map, or a rewrite would drop rules; .prev is taken on the first write, after this
	else check_rule_file(rules, tag);
	if (!sim && state_get("previewed") != "true")
		abort(tag + "run a preview first (plain tidy, no go) and look at what it will do.");

	// ---- a rule file tidy did not write (old Philter / OCD decisions): say so, once
	if (state_get("inheritedNoticed") != "true") {
		int acting = 0; int held = 0; int [string] other;
		foreach it, rule in rules {
			if (rule.action == "MALL" || rule.action == "AUTO") acting += 1;
			else if (rule.action != "KEEP" && rule.action != "CLST") other[rule.action] += 1;
			if (on_hand(it) + shop_amount(it) + display_amount(it) > 0) held += 1;
		}
		print(tag + "found an existing rule file, data/" + RULES_FILE + ", that tidy did not write: " + count(rules)
			+ " rules from an earlier Philter or OCD setup, " + acting + " of them sell (MALL/AUTO), " + held + " cover items you hold right now.", "olive");
		foreach action, howMany in other
			print("  " + howMany + (howMany == 1 ? " rule says " : " rules say ") + action + action_note(action), "olive");
		print(tag + "those old decisions stay in force unless you change them. To start clean instead: tidy reset (backs the file up,"
			+ " then writes fresh rules for everything you hold, sells nothing).", "olive");
		state_set("inheritedNoticed", "true", tag);
	}

	// ---- nothing leaves your account except through the mall and autosell: CLAN, GIFT and DISC rules become KEEP
	if (get_property("tidy_allowGiving") != "true") {
		int neutralized = 0;
		foreach it, rule in rules {
			if (rule.action != "CLAN" && rule.action != "GIFT" && rule.action != "DISC") continue;
			print("  " + it + ": " + rule.action + (rule.action == "GIFT" && rule.info != "" ? " to " + rule.info : "") + " -> KEEP", "olive");
			rule.message = "was " + rule.action + (rule.info != "" ? " " + rule.info : "") + (rule.message != "" ? ": " + rule.message : "");
			rule.action = "KEEP"; rule.q = 0; rule.info = "";
			neutralized += 1;
		}
		if (neutralized > 0) {
			save_rules(rules);
			print(tag + "turned " + plural(neutralized, "CLAN/GIFT/DISC rule", "CLAN/GIFT/DISC rules") + " into KEEP: tidy never puts items"
				+ " in the clan stash, kmails them away, or discards them. To allow it, set tidy_allowGiving = true, then tidy revert.", "olive");
		}
	}

	// ---- load rules + defaults
	OCDinfo [item] bale = load_defaults();
	// get_shop() reuses whatever mafia loaded earlier in the session; sales since then are invisible without this.
	// (Deliberately a bare statement: if the refresh fails, mafia's error state ends the script here. Capturing the
	// return value would clear that state and let the run continue on a stale store list.)
	cli_execute("refresh shop");
	int [item] shop = get_shop();

	print(tag + count(rules) + " rules on file, " + count(get_inventory()) + " item kinds in inventory, "
		+ count(shop) + " listings in your store.", "blue");

	// ---- keep one of every outfit piece and familiar equipment item (plus your keep list)
	enforce_keep_one(rules, sim, tag);
	boolean [item] pieces = outfit_piece_set();
	int [item] inv = get_inventory();   // read after the take-back, so an item just recovered from the store gets its rule this run
	shop = get_shop();                  // likewise the store: a listing emptied by a take-back must not be topped up

	// ---- release holds: rules an earlier run wrote (any run: preview, first run, closet preview, live), once the wait is
	// over AND a preview has run since. The wait alone is a clock (UTC midnight), not a look: a rule decided from one bad
	// price sample must not sell just because a day passed. A preview that ran to the end on a later day than the write
	// listed the rule below, with what would sell; that is the look. A chained "garbo; tidy go", or "tidy; tidy go" on the
	// same day, with nobody looking keeps the hold.
	int released = 0; int stillHeld = 0; int unseen = 0; int ready = 0; int raisedHold = 0; int dropped = 0;
	int holdDays = hold_new_days();
	int migrated = load_holds(rules, tag);   // records live in data/tidy_hold_<name>.txt; older message-column markers are moved over
	int previewDay = state_get("previewDay").to_int();   // day number of the last preview that ran to the end
	boolean [item] drop;
	foreach it, holdRecord in HOLDS {
		string [int] fields = holdRecord.split_string(" ");   // "<write day> <decided keep-count> <held keep-count> [<decision price>]"
		boolean readable = (count(fields) == 3 || count(fields) == 4) && plain_digits(fields[0]) && plain_digits(fields[1])
			&& plain_digits(fields[2]) && (count(fields) != 4 || plain_digits(fields[3]));
		if (!readable) {
			print(tag + "the hold record for " + it + " in data/" + HOLD_FILE + " is unreadable ('" + holdRecord + "'); keeping the hold."
				+ " Fix or delete that line.", "red");
			stillHeld += 1; continue;
		}
		int since = fields[0].to_int(); int decidedQ = fields[1].to_int(); int heldQ = fields[2].to_int();
		int decidedPrice = (count(fields) == 4) ? fields[3].to_int() : 0;
		string priceTail = (decidedPrice > 0) ? " " + decidedPrice : "";
		if (!(rules contains it) || (rules[it].action != "MALL" && rules[it].action != "AUTO")) {
			drop[it] = true; dropped += 1;
			print("  hold dropped: " + it + " no longer has a MALL or AUTO rule", "olive");
			continue;
		}
		// tidy's own keep-count raise (keep list, outfit piece, worn or closet copies) is not a hand edit
		int expect = max(heldQ, keep_floor(it, pieces));
		if (rules[it].q != heldQ && rules[it].q != expect) {
			drop[it] = true; dropped += 1;
			print("  hold dropped: " + it + " keep-count was changed by hand (" + heldQ + " -> " + rules[it].q + "); your number stands", "olive");
			continue;
		}
		if (rules[it].q != heldQ) { HOLDS[it] = since + " " + decidedQ + " " + rules[it].q + priceTail; HOLDS_CHANGED = true; }
		// a keep-list or outfit count raised meanwhile, or copies now worn or closeted, win over the old decision
		int keepQ = max(decidedQ, keep_floor(it, pieces));
		boolean due = RUN_DAY - since >= holdDays;
		boolean seen = previewDay > since;
		// only a live run releases: a preview lists the rule and leaves the record, so the fresh search below always
		// precedes the sale
		if (due && seen && !sim) {
			// one fresh search before the sale: the decision came from a cached (possibly shared, possibly gamed) price.
			// Held again only if the market has left the band the decision was made in: an AUTO decision now worth more
			// than twice the floor and more than the lazyman number, a MALL decision whose price has at least doubled and
			// crossed tidy_keepAbove, or nothing listed at all (a fresh check is impossible, and unlisted can mean rare).
			int fresh = mall_price(it, 0.0);
			string why = "";
			if (fresh <= 0) why = "nothing is listed in the mall right now, so the price cannot be checked";
			else if (rules[it].action == "AUTO" && fresh > max(2 * mall_floor(it), junk_below()))
				why = "decided AUTO, but the market is now " + rnum(fresh);
			else if (decidedPrice > 0 && fresh >= 2 * decidedPrice && keep_above() > 0 && fresh >= keep_above())
				why = "decided at " + rnum(decidedPrice) + ", but the market is now " + rnum(fresh) + " (at or above tidy_keepAbove)";
			if (why != "") {
				stillHeld += 1;
				print("  on hold: " + it + ": " + why + "; kept on hold. Set the rule you want in Philter Manager (your keep-count drops the hold).", "red");
				continue;
			}
			rules[it].q = keepQ; drop[it] = true; released += 1; continue;
		}
		stillHeld += 1;
		// copies picked up since the rule was written are held too
		if (on_hand(it) > rules[it].q) {
			rules[it].q = on_hand(it); HOLDS[it] = since + " " + decidedQ + " " + rules[it].q + priceTail; HOLDS_CHANGED = true; raisedHold += 1;
		}
		int wouldSell = on_hand(it) - keepQ; if (wouldSell < 0) wouldSell = 0;
		if (due && seen) ready += 1; else if (due) unseen += 1;
		string decided = (decidedPrice > 0) ? " (decided at " + rnum(decidedPrice) + ")" : "";
		string when = due
			? (sim ? " on the next tidy go" + (seen ? "" : ", now that you have previewed") : "; run a plain tidy and look first")
			: " after the " + holdDays + "-day hold and a preview";
		print("  on hold: " + on_hand(it) + " " + it + "  ->  " + rules[it].action + (keepQ > 0 ? " keep " + keepQ : "") + decided
			+ ", " + wouldSell + " would sell" + when, "olive");
	}
	foreach it in drop { remove HOLDS[it]; HOLDS_CHANGED = true; }
	if (released > 0) print(tag + plural(released, "rule", "rules") + " written by an earlier run " + (released == 1 ? "is" : "are")
		+ " past the " + holdDays + "-day hold, previewed since, and can sell now.", "blue");
	if (ready > 0) print(tag + plural(ready, "held rule is", "held rules are") + " past the hold and previewed on a later day:"
		+ " the next tidy go releases " + (ready == 1 ? "it" : "them") + " after one fresh price check each (a preview never releases a hold).", "olive");
	if (unseen > 0) print(tag + plural(unseen, "held rule is", "held rules are") + " past the hold but no preview has run since "
		+ (unseen == 1 ? "it was" : "they were") + " written. "
		+ (sim ? "This preview counts: they sell on the next tidy go." : "Nothing sells on them until you run a plain tidy and look."), "olive");
	if (stillHeld > unseen + ready) print(tag + plural(stillHeld - unseen - ready, "new-kind rule", "new-kind rules")
		+ " still inside the " + holdDays + "-day hold. Review in Philter Manager or in the lines above.", "olive");

	// ---- new item kinds
	int added = 0; int addMall = 0; int addAuto = 0; int addKeep = 0; int held = 0;
	foreach it, have in inv {
		if (rules contains it) continue;
		Decision verdict = decide(it, on_hand(it), bale, shop, pieces);   // counted the way Philter counts (bag + closet + worn)
		added += 1;
		if (verdict.action == "MALL") addMall += 1; else if (verdict.action == "AUTO") addAuto += 1; else addKeep += 1;
		OCDinfo rule; rule.action = verdict.action; rule.q = verdict.q; rule.info = ""; rule.message = "";
		boolean isHeld = false;
		if (holdDays > 0 && verdict.action != "KEEP") {
			// whichever run writes the rule (a preview as much as a live run), it may not sell on it: hold everything on hand
			// until the wait is over and a later-day preview has listed it. Philter measures the keep-count against bag +
			// closet + worn copies, so the hold counts the same way.
			hold_new_rule(it, rule, verdict.q); held += 1; isHeld = true;
		}
		string heldTag = isHeld ? "   [held " + plural(holdDays, "day", "days") + "]" : "";
		print("  new: " + have + " " + it + "  ->  " + verdict.action + (verdict.q > 0 ? " keep " + verdict.q : "") + "   (" + verdict.why + ")" + heldTag,
			verdict.action == "KEEP" ? "green" : "black");
		rules[it] = rule;
	}
	if (held > 0) print(tag + plural(held, "new MALL/AUTO rule", "new MALL/AUTO rules") + " written but held: nothing sells on a rule"
		+ " the same run that wrote it, nor before a preview on a later day has listed it. Review in Philter Manager; tomorrow, a plain tidy"
		+ " then tidy go (tidy_holdNewDays).", "olive");
	// the hold records first: a rule saved with a raised keep-count but no record would read as a hand edit next run
	save_holds(tag);
	if ((released > 0 || raisedHold > 0 || migrated > 0) && added == 0) save_rules(rules);
	if (added == 0) print(tag + "no new item kinds" + (RULES_WRITTEN ? "." : "; rule file unchanged."), "blue");
	else {
		save_rules(rules);
		print(tag + "added " + added + " rules (" + addMall + " mall, " + addAuto + " autosell, " + addKeep + " keep) to data/" + RULES_FILE
			+ ". Previous file saved as " + BACKUP_FILE + ".", "blue");
		if (sim) print(tag + "the new rules are written now so you can review them: relay browser > -run script- > Philter Manager,"
			+ " sort by price, change what you disagree with. Nothing is sold in a preview.", "olive");
		clear(rules);
		file_to_map(RULES_FILE, rules);
	}

	// ---- reprice the store to market (once a day), then top up at the resulting prices
	reprice_store(rules, sim, tag);

	// ---- drip listings: small fixed lots that are allowed to run dry
	drip_step(rules, shop, sim, tag);

	// ---- store top-ups at your own prices, before Philter can touch those listings
	int topped = 0; int toppedItems = 0;
	foreach it, listed in shop {
		if (DRIP_LIST contains it) continue;
		if (!(rules contains it) || rules[it].action != "MALL") continue;
		// Philter's excess is (bag + closet + worn) - keep-count. It takes that from the bag and fetches the rest itself, off
		// any familiar wearing the item and off YOU (never out of the closet: Philter forces autoSatisfyWithCloset off while it
		// runs, so closet copies count but stay put), and lists whatever it fetched at market, which KoL applies to the whole
		// listing (your price is gone). The keep-count check above has already written every sell rule's keep-count at or
		// above the floor (worn + closet copies), in previews too, so the excess is bag copies only and nothing is worn
		// beyond the keep. The stop below is therefore unreachable today (keep_floor and the test count "worn" the same way);
		// it stays as a guard for the next edit that makes them disagree, rather than let Philter strip.
		int keepQ = max(rules[it].q, keep_floor(it, pieces));
		int wanted = on_hand(it) - keepQ;
		if (wanted <= 0) continue;
		int price = shop_price(it);
		// KoLmafia's "price unknown" value is 999,999,999,999 (StoreManager); a listing parked at 999,999,999 is a real price
		if (price <= 0 || price >= 999999999999) abort(tag + "could not read your store price for " + it + " (mafia returned " + price + ")."
			+ " Stopping before Philter so the listing cannot be repriced. Run 'refresh shop' and try again.");
		if (wanted > item_amount(it) && equipped_amount(it, true) > 0) {
			string why = tag + "the MALL rule for " + it + " keeps fewer copies than you or a familiar are wearing plus your closet copies,"
				+ " which the keep-count check should have raised. Stopping before Philter so it cannot take the item off anyone and re-list"
				+ " the whole listing at market. Please report this.";
			if (sim) print(why, "red"); else abort(why);
			continue;
		}
		int excess = min(wanted, item_amount(it));   // closet copies count but stay where they are
		if (excess <= 0) continue;
		topped += 1; toppedItems += excess;
		if (sim) print("  would add " + excess + " " + it + " to your store at your price of " + rnum(price), "black");
		else {
			if (!put_shop(price, shop_limit(it), excess, it))
				abort(tag + "could not add " + it + " to your store. Stopping before Philter so the listing cannot be repriced.");
			print("  added " + excess + " " + it + " to your store at your price of " + rnum(price), "black");
		}
	}
	if (topped > 0) print(tag + (sim ? "would top up " : "topped up ") + plural(topped, "listing", "listings")
		+ " (" + toppedItems + " items) at your prices.", "blue");
	else print(tag + "no store listings need topping up.", "blue");

	// ---- Philter
	// put back afterwards: a hand-run "philter" must behave as you left it
	string simBefore = (vars contains "BaleOCD_Sim") ? vars["BaleOCD_Sim"] : "";
	set_philter_var("BaleOCD_Sim", sim ? "true" : "false", tag);
	if (sim && getvar("BaleOCD_Sim") != "true") abort(tag + "Philter is not in simulation mode. Stopping before anything is sold.");
	// the rule file tidy works on (with the test suffix, if any), for this run only; put back right after
	set_philter_var("BaleOCD_DataFile", DATA_NAME, tag);
	int meatBefore = my_meat();
	int kindsBefore = count(get_inventory());
	print(tag + "running Philter " + (sim ? "in simulation" : "LIVE") + "...", sim ? "olive" : "red");
	boolean philterOk = cli_execute("philter");
	int kindsAfter = count(get_inventory());
	restore_datafile(tag);
	if (!philterOk) print(tag + "Philter stopped early (see the lines above). Some rules may not have run.", "red");
	if (simBefore != "" && simBefore != (sim ? "true" : "false")) set_philter_var("BaleOCD_Sim", simBefore, tag);
	cli_execute("refresh shop");
	// a simulation that stopped early is not a preview; the day is the run's start day
	if (sim && !IN_RESET && philterOk) { state_set("previewed", "true", tag); state_set("previewDay", RUN_DAY.to_string(), tag); }
	// a live run that got through Philter on the fresh rules accepts the reset; revert now undoes the last run instead
	if (!sim && philterOk) { state_set("resetBackup", "", tag); state_set("resetHoldBackup", "", tag); }
	print(tag + "finished. Inventory " + kindsBefore + " kinds -> " + kindsAfter + " kinds; meat " + rnum(meatBefore) + " -> " + rnum(my_meat())
		+ "; store now has " + count(get_shop()) + " listings.", "blue");
}
