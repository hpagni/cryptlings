--!strict
-- CRYPTLINGS: NIGHT SHIFT — Price Ladder of Record v1 (SOP §4.2, transcribed verbatim).
-- Versioned, NEVER hand-edited live (§4.4: max one price/placement change per week,
-- via a committed change to this file). Charm pricing throughout — 19/49/99 endings
-- outconvert round numbers.
-- The 2,999 R$ anchor exists to make the 349-799 R$ passes look cheap (decoy
-- pricing) — do not expect volume from it.
-- Pure Luau: requires no Roblox globals (lune-safe).

export type LadderRow = {
	sku: string,
	displayName: string,
	type: "DevProduct" | "GamePass" | "Subscription",
	priceRobux: number,
	notes: string,
	shipsAt: string?, -- "launch" | "launch+2wk" | "season1" | "week8"
	wiredInMvp: boolean,
}

local PriceLadder = {}

PriceLadder.VERSION = 1

PriceLadder.Rows = table.freeze({
	table.freeze({
		sku = "STARTER_PACK",
		displayName = "Night Shift Starter Pack",
		type = "DevProduct",
		priceRobux = 99,
		notes = "One per account: 1 Foreman's Key + 2 extra openings + exclusive misprint shelf trophy"
			.. " (misprint_trophy). Surfaced exactly once, on the second successful extraction, 24h timer (§4.3).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "EXTRA_OPENING",
		displayName = "Extra daily case-opening",
		type = "DevProduct",
		priceRobux = 49,
		notes = "Consumable. Grants +1 extraOpenCredits.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "OPENS_RESET",
		displayName = "Opening limit reset",
		type = "DevProduct",
		priceRobux = 200,
		notes = "Consumable effect: instantly refills the free-open allowance for the current 4h window.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "EXIT_WARP",
		displayName = "Exit warp (1 use)",
		type = "DevProduct",
		priceRobux = 129,
		notes = "Consumable. Teleports you to the extraction dock mid-run. Quick-buyable in-run (exempt"
			.. " from the no-mid-run storefront rule by design — it is a panic button).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "WEAPON_SWORD",
		displayName = "Factory blade (20 swings)",
		type = "DevProduct",
		priceRobux = 99,
		notes = "Limited-use melee weapon: 20 swings, consumed per hit landed.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "WEAPON_PAINTBALL",
		displayName = "Paintball popper (15 shots)",
		type = "DevProduct",
		priceRobux = 79,
		notes = "Limited-use ranged weapon: toy paintball gun, cheaper and weaker than the Zap blaster."
			.. " 15 shots, consumed per shot fired.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "WEAPON_GUN",
		displayName = "Zap blaster (10 shots)",
		type = "DevProduct",
		priceRobux = 199,
		notes = "Limited-use ranged weapon: cartoony toy laser blaster (NOT a realistic firearm — bright"
			.. " colors, neon bolt), 10 shots, consumed per shot fired.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "SCENT_SPRAY",
		displayName = "Steady Grips (1 run)",
		type = "DevProduct",
		priceRobux = 39,
		notes = "Consumable. Carrying cases does not slow you for the current run (replaced the old"
			.. " silent-case spray per playtest direction; sku/profile key keep the legacy name).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "REVIVE_BEACON",
		displayName = "Revive beacon",
		type = "DevProduct",
		priceRobux = 75,
		notes = "Consumable.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "FOREMANS_KEY",
		displayName = "Foreman's Key (1 bonus vault case)",
		type = "DevProduct",
		priceRobux = 149,
		notes = "Consumable. Paid-random (indirect): Robux -> key -> case counts for compliance (§8.1).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "PET_TREATS",
		displayName = "Pet Treats (+1 pet level)",
		type = "DevProduct",
		priceRobux = 249,
		notes = "Consumable. Levels the equipped-pet perk: pets.upgradeLevel += 1 (cap"
			.. " PET_UPGRADE_MAX_LEVEL = 3); each level multiplies the pet perk by"
			.. " (1 + 0.25 * level). Charm 249. Buying at the cap grants nothing extra"
			.. " (PetUI hides the button at cap; the receipt is still consumed).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	-- Case bundle ladder (PS99 model): 240 -> 599 -> 1,499 -> 4,999 -> 14,499.
	-- Bundles grant SEALED Tier 2 cases into the locker — they still pass the
	-- unboxing theater and the daily cap unless VIP Locker is owned (§4.3).
	table.freeze({
		sku = "CASE_BUNDLE_S",
		displayName = "Case Bundle: 5 cases",
		type = "DevProduct",
		priceRobux = 240,
		notes = "5 Tier 2 sealed cases, +0% bonus value (ladder baseline).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "CASE_BUNDLE_M",
		displayName = "Case Bundle: 13 cases",
		type = "DevProduct",
		priceRobux = 599,
		notes = "13 Tier 2 sealed cases, +4% bonus value (actual +4.17% vs the 240 R$ baseline — never overstate).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "CASE_BUNDLE_L",
		displayName = "Case Bundle: 35 cases",
		type = "DevProduct",
		priceRobux = 1499,
		notes = "35 Tier 2 sealed cases, +12% bonus value.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "CASE_BUNDLE_XL",
		displayName = "Case Bundle: 125 cases",
		type = "DevProduct",
		priceRobux = 4999,
		notes = "125 Tier 2 sealed cases, +20% bonus value (actual +20.0%). Whale tier: gated by Flags.whaleBundlesLive"
			.. " until launch+2 weeks of payer data (§4.1).",
		shipsAt = "launch+2wk",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "CASE_BUNDLE_WHALE",
		displayName = "Case Bundle: 423 cases",
		type = "DevProduct",
		priceRobux = 14499,
		notes = "423 Tier 2 sealed cases, +40% bonus value (actual +40.03% — §4.3 pins the whale endpoint"
			.. " at +40% and the advertised ribbon must never overstate). Gated by Flags.whaleBundlesLive"
			.. " until launch+2 weeks of payer data (§4.1).",
		shipsAt = "launch+2wk",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "PASS_CARRY",
		displayName = "+2 Carry Slots",
		type = "GamePass",
		priceRobux = 349,
		notes = "Conversion workhorse tier.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "PASS_2X_PAY",
		displayName = "2x Shift Pay",
		type = "GamePass",
		priceRobux = 449,
		notes = "Doubles shift pay (banked-case pay + extraction bonus).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "PASS_VIP_LOCKER",
		displayName = "VIP Locker (open 6/day)",
		type = "GamePass",
		priceRobux = 799,
		notes = "Beta-test SKU (§3.3); public release gated by Flags.vipLockerPublic until launch+2 weeks (§4.1).",
		shipsAt = "launch+2wk",
		wiredInMvp = true,
	}) :: LadderRow,
	-- Housing ladder (lot collection upgrades; replaced PASS_PENTHOUSE June 2026).
	-- Fixed-price dev products: the "_UP_" SKUs are the discounted upgrade paths
	-- and are only OFFERED (Shop.GetCatalog filter) to players at the matching
	-- tier, so the effective price always honors the discount matrix:
	--   House 499 | 2-Story 999 (499 from House) | Mansion 2499 (1999 from
	--   House, 1499 from 2-Story).
	table.freeze({
		sku = "HOUSING_HOUSE",
		displayName = "House Upgrade",
		type = "DevProduct",
		priceRobux = 499,
		notes = "Lot upgrade: replaces the 8 ground podiums with a house that displays 12 Pets.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "HOUSING_TWO_STORY",
		displayName = "2-Story House",
		type = "DevProduct",
		priceRobux = 999,
		notes = "Lot upgrade from the starter lot straight to the 2-story house: 24 displays, 12 per story.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "HOUSING_TWO_STORY_UP",
		displayName = "2-Story House (House owner)",
		type = "DevProduct",
		priceRobux = 499,
		notes = "Discounted 2-story upgrade for House owners (999 - 499 already paid). Offered only at tier 1.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "HOUSING_MANSION",
		displayName = "Mansion",
		type = "DevProduct",
		priceRobux = 2499,
		notes = "Lot upgrade straight to the Mansion: 5 floors, 12 displays per floor (60 total), walkable stairs.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "HOUSING_MANSION_UP_HOUSE",
		displayName = "Mansion (House owner)",
		type = "DevProduct",
		priceRobux = 1999,
		notes = "Discounted Mansion for House owners. Offered only at tier 1.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "HOUSING_MANSION_UP_TWO_STORY",
		displayName = "Mansion (2-Story owner)",
		type = "DevProduct",
		priceRobux = 1499,
		notes = "Discounted Mansion for 2-Story House owners. Offered only at tier 2.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "PASS_MINIMAP",
		displayName = "Floor Minimap",
		type = "GamePass",
		priceRobux = 499,
		notes = "Live top-down minimap during shifts: the seeded floor layout, your position, other"
			.. " players, and the extraction exit. Never shows crate locations (the haul is still earned).",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "PASS_GOLDEN_SET",
		displayName = "Golden Flashlight + Foreman set (decoy anchor)",
		type = "GamePass",
		priceRobux = 2999,
		notes = "Decoy anchor: exists to make the 349-799 R$ passes look cheap. Do not expect volume.",
		shipsAt = "launch",
		wiredInMvp = true,
	}) :: LadderRow,
	table.freeze({
		sku = "SEASON_PASS",
		displayName = 'Season "Toy Line" pass',
		type = "DevProduct",
		priceRobux = 799,
		notes = "Per 6-week season (BedWars model). NOT wired in MVP.",
		shipsAt = "season1",
		wiredInMvp = false,
	}) :: LadderRow,
	table.freeze({
		sku = "SEASON_SKIP",
		displayName = "Season pass level skip",
		type = "DevProduct",
		priceRobux = 299,
		notes = "Per level — skips are the real margin. NOT wired in MVP.",
		shipsAt = "season1",
		wiredInMvp = false,
	}) :: LadderRow,
	table.freeze({
		sku = "COLLECTORS_CLUB",
		displayName = "Collector's Club",
		type = "Subscription",
		priceRobux = 0,
		notes = "~$4.99/mo subscription (priced in USD, not Robux; Roblox waives its fee on renewals)."
			.. " Early line access + 1 guaranteed rare case. NOT wired in MVP.",
		shipsAt = "week8",
		wiredInMvp = false,
	}) :: LadderRow,
})

local bySku: { [string]: LadderRow } = {}
for _, row in PriceLadder.Rows do
	bySku[row.sku] = row
end
PriceLadder.BySku = table.freeze(bySku)

function PriceLadder.GetRow(sku: string): LadderRow?
	return bySku[sku]
end

return table.freeze(PriceLadder)
