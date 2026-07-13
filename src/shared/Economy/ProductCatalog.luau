--!strict
-- CRYPTLINGS: NIGHT SHIFT — sellable SKU catalog (CONTRACTS v1 §F).
-- Maps every Price Ladder sku -> product spec: Roblox assetId placeholder (filled
-- from the Creator Dashboard later — 0 means "not yet created"), kind, isRandom
-- (drives §8.1 paid-random compliance gating), and the grant spec executed by
-- MonetizationService on receipt.
-- Pure Luau: requires no Roblox globals (lune-safe — string require resolves
-- both under Roblox and under lune for tests/rarity-sim-style headless checks).

local PriceLadder = require("./PriceLadder")

export type GrantSpec = {
	cases: { tier: number, count: number }?, -- sealed CaseStubs into profile.locker.cases
	extraOpenCredits: number?,
	consumables: { [string]: number }?, -- scentSpray | reviveBeacon | foremansKey | exitWarp | swordSwings | gunShots | paintballShots
	cryptlings: { [string]: number }?, -- direct collection grants (e.g. misprint_trophy)
	passSku: string?, -- GamePass entitlement (cached in profile.monetization.passCache)
	resetOpens: boolean?, -- OPENS_RESET: refill the free-open allowance immediately
	petUpgrade: boolean?, -- PET_TREATS: pets.upgradeLevel += 1 via PetService.GrantUpgrade
	housingTier: number?, -- HOUSING_*: profile.housing.tier = max(current, this) (1 house / 2 two-story / 3 mansion)
}

export type ProductSpec = {
	sku: string,
	assetId: number, -- 0 = placeholder; filled in Creator Dashboard later
	kind: "DevProduct" | "GamePass" | "Subscription",
	isRandom: boolean, -- true => gated by ComplianceService.IsRandomRestricted (§8.1)
	onePerAccount: boolean?,
	bonusPct: number?, -- bundle "bonus value %" shown on the whale ladder (§4.3)
	-- Housing offer gate: only OFFER this SKU (Shop.GetCatalog) when the buyer's
	-- profile.housing.tier equals this value — that is how the discounted "_UP_"
	-- upgrade paths keep the discount matrix honest with fixed-price products.
	requiresHousingTier: number?,
	grants: GrantSpec,
}

local function spec(entry: ProductSpec): ProductSpec
	local row = PriceLadder.GetRow(entry.sku)
	assert(row ~= nil, `ProductCatalog: sku {entry.sku} missing from PriceLadder`)
	assert(row.type == entry.kind, `ProductCatalog: kind mismatch for {entry.sku}`)
	return table.freeze(entry)
end

local ProductCatalog = {}

ProductCatalog.BySku = table.freeze({
	STARTER_PACK = spec({
		sku = "STARTER_PACK",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true, -- contains a Foreman's Key (indirect paid-random)
		onePerAccount = true,
		grants = {
			consumables = { foremansKey = 1 },
			extraOpenCredits = 2,
			cryptlings = { misprint_trophy = 1 },
		},
	}),
	EXTRA_OPENING = spec({
		sku = "EXTRA_OPENING",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { extraOpenCredits = 1 },
	}),
	OPENS_RESET = spec({
		sku = "OPENS_RESET",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { resetOpens = true },
	}),
	EXIT_WARP = spec({
		sku = "EXIT_WARP",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { consumables = { exitWarp = 1 } },
	}),
	WEAPON_SWORD = spec({
		sku = "WEAPON_SWORD",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { consumables = { swordSwings = 20 } },
	}),
	WEAPON_PAINTBALL = spec({
		sku = "WEAPON_PAINTBALL",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { consumables = { paintballShots = 15 } },
	}),
	WEAPON_GUN = spec({
		sku = "WEAPON_GUN",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { consumables = { gunShots = 10 } },
	}),
	SCENT_SPRAY = spec({
		sku = "SCENT_SPRAY",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { consumables = { scentSpray = 1 } },
	}),
	REVIVE_BEACON = spec({
		sku = "REVIVE_BEACON",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = { consumables = { reviveBeacon = 1 } },
	}),
	FOREMANS_KEY = spec({
		sku = "FOREMANS_KEY",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true, -- Robux -> key -> random case (§8.1 indirect)
		grants = { consumables = { foremansKey = 1 } },
	}),
	PET_TREATS = spec({
		sku = "PET_TREATS",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false, -- deterministic: always +1 pet level (perk math is public)
		grants = { petUpgrade = true },
	}),
	CASE_BUNDLE_S = spec({
		sku = "CASE_BUNDLE_S",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true,
		bonusPct = 0,
		grants = { cases = { tier = 5, count = 5 } },
	}),
	-- bonusPct is the ADVERTISED "+X% BONUS VALUE" ribbon (§4.3). It must never
	-- overstate the real cases-per-Robux gain vs the 240 R$/5-case baseline
	-- (misleading purchase copy is a compliance risk): values are the actual
	-- gain rounded DOWN. 13/599 = +4.17% -> 4; 35/1499 = +12.1% -> 12;
	-- 125/4999 = +20.0% -> 20; 423/14499 = +40.03% -> 40 (§4.3 whale endpoint).
	CASE_BUNDLE_M = spec({
		sku = "CASE_BUNDLE_M",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true,
		bonusPct = 4,
		grants = { cases = { tier = 5, count = 13 } },
	}),
	CASE_BUNDLE_L = spec({
		sku = "CASE_BUNDLE_L",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true,
		bonusPct = 12,
		grants = { cases = { tier = 5, count = 35 } },
	}),
	CASE_BUNDLE_XL = spec({
		sku = "CASE_BUNDLE_XL",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true,
		bonusPct = 20,
		grants = { cases = { tier = 5, count = 125 } },
	}),
	CASE_BUNDLE_WHALE = spec({
		sku = "CASE_BUNDLE_WHALE",
		assetId = 0,
		kind = "DevProduct",
		isRandom = true,
		bonusPct = 40,
		grants = { cases = { tier = 5, count = 423 } },
	}),
	PASS_CARRY = spec({
		sku = "PASS_CARRY",
		assetId = 0,
		kind = "GamePass",
		isRandom = false,
		grants = { passSku = "PASS_CARRY" },
	}),
	PASS_2X_PAY = spec({
		sku = "PASS_2X_PAY",
		assetId = 0,
		kind = "GamePass",
		isRandom = false,
		grants = { passSku = "PASS_2X_PAY" },
	}),
	PASS_VIP_LOCKER = spec({
		sku = "PASS_VIP_LOCKER",
		assetId = 0,
		kind = "GamePass",
		isRandom = false,
		grants = { passSku = "PASS_VIP_LOCKER" },
	}),
	-- Housing ladder (lot collection upgrades; §4.2 amendment June 2026).
	-- Deterministic, one-way tier raises: receipts apply tier = max(current,
	-- granted), so a raced double-purchase can never downgrade a lot.
	HOUSING_HOUSE = spec({
		sku = "HOUSING_HOUSE",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		requiresHousingTier = 0,
		grants = { housingTier = 1 },
	}),
	HOUSING_TWO_STORY = spec({
		sku = "HOUSING_TWO_STORY",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		requiresHousingTier = 0,
		grants = { housingTier = 2 },
	}),
	HOUSING_TWO_STORY_UP = spec({
		sku = "HOUSING_TWO_STORY_UP",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		requiresHousingTier = 1,
		grants = { housingTier = 2 },
	}),
	HOUSING_MANSION = spec({
		sku = "HOUSING_MANSION",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		requiresHousingTier = 0,
		grants = { housingTier = 3 },
	}),
	HOUSING_MANSION_UP_HOUSE = spec({
		sku = "HOUSING_MANSION_UP_HOUSE",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		requiresHousingTier = 1,
		grants = { housingTier = 3 },
	}),
	HOUSING_MANSION_UP_TWO_STORY = spec({
		sku = "HOUSING_MANSION_UP_TWO_STORY",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		requiresHousingTier = 2,
		grants = { housingTier = 3 },
	}),
	PASS_MINIMAP = spec({
		sku = "PASS_MINIMAP",
		assetId = 0,
		kind = "GamePass",
		isRandom = false,
		grants = { passSku = "PASS_MINIMAP" },
	}),
	PASS_GOLDEN_SET = spec({
		sku = "PASS_GOLDEN_SET",
		assetId = 0,
		kind = "GamePass",
		isRandom = false,
		grants = { passSku = "PASS_GOLDEN_SET" },
	}),
	SEASON_PASS = spec({
		sku = "SEASON_PASS",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = {}, -- NOT wired in MVP (shipsAt = "season1")
	}),
	SEASON_SKIP = spec({
		sku = "SEASON_SKIP",
		assetId = 0,
		kind = "DevProduct",
		isRandom = false,
		grants = {}, -- NOT wired in MVP (shipsAt = "season1")
	}),
	COLLECTORS_CLUB = spec({
		sku = "COLLECTORS_CLUB",
		assetId = 0,
		kind = "Subscription",
		isRandom = false,
		grants = {}, -- NOT wired in MVP (shipsAt = "week8")
	}),
}) :: { [string]: ProductSpec }

function ProductCatalog.Get(sku: string): ProductSpec?
	return ProductCatalog.BySku[sku]
end

--------------------------------------------------------------------------------
-- GetSellable — the single filtered, flag-gated storefront list (CONTRACTS §F).
-- Shop.GetCatalog maps these rows onto Types.CatalogEntry (server adds odds /
-- owned). Order follows the Price Ladder of Record.
--------------------------------------------------------------------------------

-- Width-subtyped view of Economy/Flags — pass the Flags module table directly.
export type SellGateFlags = {
	whaleBundlesLive: boolean,
	vipLockerPublic: boolean,
	starterPackEnabled: boolean,
}

export type SellableEntry = {
	sku: string,
	displayName: string,
	priceRobux: number,
	kind: "DevProduct" | "GamePass" | "Subscription",
	isRandom: boolean,
	onePerAccount: boolean?,
	bonusPct: number?,
	requiresHousingTier: number?,
	grants: GrantSpec,
}

-- sku -> Flags field that must be true for the SKU to be sold (§4.1 rollout).
local FLAG_GATES: { [string]: string } = {
	STARTER_PACK = "starterPackEnabled",
	CASE_BUNDLE_XL = "whaleBundlesLive", -- whale tier ships launch+2wk (§4.1)
	CASE_BUNDLE_WHALE = "whaleBundlesLive",
	PASS_VIP_LOCKER = "vipLockerPublic", -- beta-test SKU (§3.3)
}

-- restricted: ComplianceService.IsRandomRestricted(player) — when true, every
-- isRandom SKU is withheld (§8.1: no paid randomness for restricted players).
function ProductCatalog.GetSellable(restricted: boolean, flags: SellGateFlags): { SellableEntry }
	local sellable: { SellableEntry } = {}
	for _, row in PriceLadder.Rows do
		if not row.wiredInMvp then
			continue -- SEASON_PASS / SEASON_SKIP / COLLECTORS_CLUB (shipsAt later)
		end
		local productSpec = ProductCatalog.BySku[row.sku]
		if productSpec == nil then
			continue
		end
		local gate = FLAG_GATES[row.sku]
		if gate ~= nil and not (flags :: any)[gate] then
			continue
		end
		if restricted and productSpec.isRandom then
			continue
		end
		table.insert(
			sellable,
			table.freeze({
				sku = row.sku,
				displayName = row.displayName,
				priceRobux = row.priceRobux,
				kind = productSpec.kind,
				isRandom = productSpec.isRandom,
				onePerAccount = productSpec.onePerAccount,
				bonusPct = productSpec.bonusPct,
				requiresHousingTier = productSpec.requiresHousingTier,
				grants = productSpec.grants,
			})
		)
	end
	return sellable
end

return table.freeze(ProductCatalog)
