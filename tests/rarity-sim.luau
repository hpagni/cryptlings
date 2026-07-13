--!strict
-- CRYPTLINGS: NIGHT SHIFT — headless rarity/economy sanity sim (CONTRACTS v1 §A, §J;
-- Stage 4 economy-QA gate, SOP §8.1/§8.2). Pure Luau; run from the repo root with:
--   lune run tests/rarity-sim.luau
-- Verifies the economy data of record: tier weights, exact disclosed odds,
-- roster composition (3C/4U/3R/1E/1L/2G/1M), recipe shape, the Price Ladder,
-- a 200k-roll Tier 2 simulation through the SHIPPED RarityTable.RollCryptling
-- (the exact path UnboxService rolls with) against the DISCLOSED odds — every
-- rarity within ±1.0% absolute, Godly within ±0.15% absolute (§8.1: disclosed
-- odds are a launch blocker) — plus the spec-name aliases and the
-- ProductCatalog/GetSellable storefront gating. Prints PASS/FAIL on the last
-- line; exits nonzero on FAIL.

local RarityTable = require("../src/shared/Config/RarityTable")
local PriceLadder = require("../src/shared/Economy/PriceLadder")
local ProductCatalog = require("../src/shared/Economy/ProductCatalog")
local Flags = require("../src/shared/Economy/Flags")
local GameConstants = require("../src/shared/Config/GameConstants")
local Util = require("../src/shared/Util")

local failures = 0
local function check(condition: boolean, label: string)
	if condition then
		print(`  ok   {label}`)
	else
		failures += 1
		print(`  FAIL {label}`)
	end
end

--------------------------------------------------------------------------------
print("[1] Tier weights")
--------------------------------------------------------------------------------
for tier = 1, 3 do
	local weights = RarityTable.GetWeights(tier)
	local total = 0
	for _, rarity in RarityTable.RARITY_ORDER do
		total += weights[rarity]
	end
	check(total == RarityTable.WEIGHT_TOTAL, `tier {tier} weights sum to {RarityTable.WEIGHT_TOTAL}`)
end
check(RarityTable.BASELINE_TIER == 2, "tier 2 is the disclosed baseline")

--------------------------------------------------------------------------------
print("[2] Disclosed odds are EXACT (pct == weight / 10000)")
--------------------------------------------------------------------------------
for tier = 1, 3 do
	local weights = RarityTable.GetWeights(tier)
	local odds = RarityTable.GetOdds(tier)
	check(#odds == #RarityTable.RARITY_ORDER, `tier {tier} odds rows complete`)
	for index, row in odds do
		check(
			row.rarity == RarityTable.RARITY_ORDER[index] and row.pct == weights[row.rarity] / 10000,
			`tier {tier} {row.rarity} = {row.pct}%`
		)
	end
end

--------------------------------------------------------------------------------
print("[3] Roster: 24 in-pool (5C/6U/5R/3E/2L/2G/1M) + misprint_trophy special")
--------------------------------------------------------------------------------
local expectedPool = { Common = 5, Uncommon = 6, Rare = 5, Epic = 3, Legendary = 2, Godly = 2, Mythical = 1 }
local inPool = 0
for _, rarity in RarityTable.RARITY_ORDER do
	local pool = RarityTable.GetPoolByRarity(rarity)
	inPool += #pool
	check(#pool == expectedPool[rarity], `{rarity} pool has {expectedPool[rarity]}`)
end
check(inPool == 24, "24 Cryptlings in pool")
check(#RarityTable.CRYPTLINGS == 25, "25 total definitions")

local trophy = RarityTable.GetCryptling("misprint_trophy")
check(
	trophy ~= nil and trophy.notInPool == true and trophy.tradeable == false,
	"misprint_trophy: notInPool, untradeable"
)

for _, def in RarityTable.CRYPTLINGS do
	-- 4-12 since the collectible redesign added detail parts (stitches, crumbs…).
	local partsOk = #def.recipe >= 4 and #def.recipe <= 12
	for _, recipePart in def.recipe do
		if recipePart.shape == nil or recipePart.size == nil or recipePart.offset == nil then
			partsOk = false
		end
	end
	check(partsOk, `{def.id} recipe: 4-12 complete greybox parts ({#def.recipe})`)
end

--------------------------------------------------------------------------------
print("[4] Price Ladder of Record v1 (SOP §4.2)")
--------------------------------------------------------------------------------
local expectedPrices = {
	STARTER_PACK = 99,
	EXTRA_OPENING = 49,
	OPENS_RESET = 200,
	EXIT_WARP = 129,
	WEAPON_SWORD = 99,
	WEAPON_PAINTBALL = 79,
	WEAPON_GUN = 199,
	SCENT_SPRAY = 39,
	REVIVE_BEACON = 75,
	FOREMANS_KEY = 149,
	PET_TREATS = 249,
	CASE_BUNDLE_S = 240,
	CASE_BUNDLE_M = 599,
	CASE_BUNDLE_L = 1499,
	CASE_BUNDLE_XL = 4999,
	CASE_BUNDLE_WHALE = 14499,
	PASS_CARRY = 349,
	PASS_2X_PAY = 449,
	PASS_VIP_LOCKER = 799,
	HOUSING_HOUSE = 499,
	HOUSING_TWO_STORY = 999,
	HOUSING_TWO_STORY_UP = 499,
	HOUSING_MANSION = 2499,
	HOUSING_MANSION_UP_HOUSE = 1999,
	HOUSING_MANSION_UP_TWO_STORY = 1499,
	PASS_MINIMAP = 499,
	PASS_GOLDEN_SET = 2999,
	SEASON_PASS = 799,
	SEASON_SKIP = 299,
	COLLECTORS_CLUB = 0,
}
check(#PriceLadder.Rows == Util.Count(expectedPrices), "ladder row count matches")
for sku, price in expectedPrices do
	local row = PriceLadder.GetRow(sku)
	check(row ~= nil and row.priceRobux == price, `{sku} = {price} R$`)
end
local seasonPass = PriceLadder.GetRow("SEASON_PASS")
check(seasonPass ~= nil and seasonPass.wiredInMvp == false, "SEASON_PASS not wired in MVP")

--------------------------------------------------------------------------------
print("[5] Seeded roll simulation (tier 2 baseline, 200k rolls)")
--------------------------------------------------------------------------------
math.randomseed(0x5EED) -- Luau PCG32: deterministic for a given seed
local function rng(): number
	return math.random()
end

local ROLLS = 200000
local rarityCounts: { [string]: number } = {}
local idCounts: { [string]: number } = {}
for _ = 1, ROLLS do
	local id = RarityTable.Roll(2, rng)
	local def = RarityTable.GetCryptling(id)
	idCounts[id] = (idCounts[id] or 0) + 1
	rarityCounts[def.rarity] = (rarityCounts[def.rarity] or 0) + 1
end

local weights = RarityTable.GetWeights(2)
for _, rarity in RarityTable.RARITY_ORDER do
	local expected = ROLLS * weights[rarity] / RarityTable.WEIGHT_TOTAL
	local got = rarityCounts[rarity] or 0
	-- 4-sigma binomial tolerance plus a floor for tiny expectations
	local p = weights[rarity] / RarityTable.WEIGHT_TOTAL
	local tolerance = 4 * math.sqrt(ROLLS * p * (1 - p)) + 5
	check(math.abs(got - expected) <= tolerance, `{rarity}: {got} rolls (expected ~{math.floor(expected)})`)
end
check((idCounts["prototype_zero"] or 0) > 0, "legendary prototype_zero pulled at least once")
check(idCounts["misprint_trophy"] == nil, "misprint_trophy never rolled")
check(Util.Count(idCounts) == 24, "all 24 in-pool Cryptlings rolled")

--------------------------------------------------------------------------------
print("[5b] Observed vs DISCLOSED odds (Stage 4 gate: ±1.0% absolute, Godly ±0.15%)")
--------------------------------------------------------------------------------
-- §8.1: the disclosed odds (GetOdds feeds the hub odds board AND every
-- pre-purchase disclosure) must be what the roll path actually delivers. At
-- n=200k these tolerances are ~9 sigma — a failure means the table or the roll
-- math changed, not bad luck.
local TOLERANCE_ABS_PCT = 1.0
local TOLERANCE_GODLY_PCT = 0.15
for _, row in RarityTable.GetOdds(2) do
	local observedPct = (rarityCounts[row.rarity] or 0) / ROLLS * 100
	local tolerance = if row.rarity == "Godly" then TOLERANCE_GODLY_PCT else TOLERANCE_ABS_PCT
	local delta = math.abs(observedPct - row.pct)
	check(
		delta <= tolerance,
		string.format(
			"%-8s disclosed %5.2f%%  observed %6.3f%%  |delta| %5.3f%% <= %.2f%%",
			row.rarity,
			row.pct,
			observedPct,
			delta,
			tolerance
		)
	)
end

--------------------------------------------------------------------------------
print("[6] GameConstants spot checks")
--------------------------------------------------------------------------------
check(
	GameConstants.FREE_OPENS_PER_DAY == 30 and GameConstants.VIP_OPENS_PER_DAY == 60,
	"locker opens 30 free / 60 VIP (per 4h window)"
)
check(
	GameConstants.SHIFT_MIN_SECONDS == 240 and GameConstants.SHIFT_MAX_SECONDS == 240,
	"shift length fixed 4 min (playtest tuning; SOP §1.2 restore path = 480/720)"
)
check(GameConstants.BASE_CARRY_SLOTS == 3 and GameConstants.PASS_CARRY_BONUS == 2, "carry 3 base +2 pass")

--------------------------------------------------------------------------------
print("[7] Spec-name aliases (Stage 0 contract: GetEntry / RollCryptling)")
--------------------------------------------------------------------------------
check(RarityTable.GetEntry == RarityTable.GetCryptling, "GetEntry is GetCryptling")
check(RarityTable.RollCryptling == RarityTable.Roll, "RollCryptling is Roll")
local aliasEntry = RarityTable.GetEntry("smudge")
check(aliasEntry ~= nil and aliasEntry.id == "smudge", "GetEntry resolves a known id")
local aliasRollId = RarityTable.RollCryptling(2, function()
	return 0
end)
local aliasRollDef = RarityTable.GetEntry(aliasRollId)
check(aliasRollDef ~= nil and aliasRollDef.notInPool ~= true, "RollCryptling returns an in-pool id")

--------------------------------------------------------------------------------
print("[8] ProductCatalog matches the ladder + GetSellable gating (§F, §8.1)")
--------------------------------------------------------------------------------
check(Util.Count(ProductCatalog.BySku) == #PriceLadder.Rows, "catalog covers every ladder sku")
for _, row in PriceLadder.Rows do
	local productSpec = ProductCatalog.Get(row.sku)
	check(productSpec ~= nil and productSpec.kind == row.type, `{row.sku} kind matches ladder type`)
end

local expectedRandom = {
	STARTER_PACK = true,
	FOREMANS_KEY = true,
	CASE_BUNDLE_S = true,
	CASE_BUNDLE_M = true,
	CASE_BUNDLE_L = true,
	CASE_BUNDLE_XL = true,
	CASE_BUNDLE_WHALE = true,
}
for sku, productSpec in ProductCatalog.BySku do
	check(productSpec.isRandom == (expectedRandom[sku] == true), `{sku} isRandom = {productSpec.isRandom}`)
end

-- bonusPct = actual cases-per-Robux gain vs the 240 R$/5-case baseline,
-- rounded DOWN (advertised bonus copy must never overstate — compliance).
local expectedBundles = {
	CASE_BUNDLE_S = { count = 5, bonusPct = 0 },
	CASE_BUNDLE_M = { count = 13, bonusPct = 4 },
	CASE_BUNDLE_L = { count = 35, bonusPct = 12 },
	CASE_BUNDLE_XL = { count = 125, bonusPct = 20 },
	CASE_BUNDLE_WHALE = { count = 423, bonusPct = 40 },
}
-- Enforce the never-overstate rule itself: floor(actual gain %) >= bonusPct.
local baselineRow = PriceLadder.GetRow("CASE_BUNDLE_S")
local baselineCasesPerRobux = expectedBundles.CASE_BUNDLE_S.count / baselineRow.priceRobux
for sku, expected in expectedBundles do
	local row = PriceLadder.GetRow(sku)
	local actualGainPct = ((expected.count / row.priceRobux) / baselineCasesPerRobux - 1) * 100
	check(
		math.floor(actualGainPct + 1e-9) >= expected.bonusPct,
		`{sku} advertised +{expected.bonusPct}% never overstates actual {string.format("%.2f", actualGainPct)}%`
	)
end
for sku, expected in expectedBundles do
	local productSpec = ProductCatalog.Get(sku)
	local cases = productSpec and productSpec.grants.cases
	check(
		cases ~= nil and cases.tier == 2 and cases.count == expected.count and productSpec.bonusPct == expected.bonusPct,
		`{sku} grants {expected.count}x tier-2 cases (+{expected.bonusPct}% bonus)`
	)
end

local starter = ProductCatalog.Get("STARTER_PACK")
check(
	starter ~= nil
		and starter.onePerAccount == true
		and starter.grants.consumables ~= nil
		and starter.grants.consumables.foremansKey == 1
		and starter.grants.extraOpenCredits == 2
		and starter.grants.cryptlings ~= nil
		and starter.grants.cryptlings.misprint_trophy == 1,
	"STARTER_PACK: one/account, 1 key + 2 open credits + misprint_trophy"
)

check(
	Flags.whaleBundlesLive == false and Flags.vipLockerPublic == false and Flags.starterPackEnabled == true,
	"Flags ship with contract-F defaults"
)
local allFlags = { whaleBundlesLive = true, vipLockerPublic = true, starterPackEnabled = true }
local sellableDefault = ProductCatalog.GetSellable(false, Flags)
local sellableAll = ProductCatalog.GetSellable(false, allFlags)
local sellableRestricted = ProductCatalog.GetSellable(true, allFlags)
check(#sellableDefault == 18, `GetSellable default flags -> 18 (got {#sellableDefault})`)
check(#sellableAll == 21, `GetSellable all flags -> 21 (got {#sellableAll})`)
check(#sellableRestricted == 14, `GetSellable restricted -> 14 (got {#sellableRestricted})`)
for _, entry in sellableRestricted do
	if entry.isRandom then
		check(false, `restricted list leaked random sku {entry.sku}`)
	end
end

local ladderIndex: { [string]: number } = {}
for index, row in PriceLadder.Rows do
	ladderIndex[row.sku] = index
end
local orderOk = true
local previousIndex = 0
for _, entry in sellableAll do
	local index = ladderIndex[entry.sku]
	if index == nil or index <= previousIndex then
		orderOk = false
	end
	previousIndex = index or previousIndex
end
check(orderOk, "GetSellable preserves ladder order")

--------------------------------------------------------------------------------
if failures > 0 then
	print(`rarity-sim: FAIL — {failures} check(s) failed`)
	error(`rarity-sim: FAIL — {failures} check(s) failed`, 0)
end
print("rarity-sim: PASS — all checks passed")
