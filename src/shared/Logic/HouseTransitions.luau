--!strict
-- CRYPTLINGS: NIGHT SHIFT — house transition table (LOBBY_SOP §5.1/§5.4).
-- Pure mapping from profile.housing.tier to the housing SKUs the server may
-- surface: the single state-gated CTA (lot sign + shop "next step" card), the
-- full per-tier offer list (Shop housing tab), and the "+N pet slots" capacity
-- copy for the client ghost preview. The server computes which SKU applies
-- from the PROFILE tier — a client-chosen housing SKU is never trusted
-- (§5.1); MonetizationService.PromptNextHousing is the only prompt site.
-- Pure Luau: requires no Roblox globals (lune-safe — string requires resolve
-- both under Roblox and under lune, exactly like Economy/ProductCatalog).

local GameConstants = require("../Config/GameConstants")
local ProductCatalog = require("../Economy/ProductCatalog")

local HouseTransitions = {}

-- The single state-gated CTA per SOP §5.4: only ever the NEXT step up the
-- discount matrix — tier 0 -> House (499), tier 1 -> Two-Story upgrade (499),
-- tier 2 -> Mansion upgrade (1499), tier 3 (cap) -> nothing to sell.
local NEXT_CTA: { [number]: string } = table.freeze({
	[0] = "HOUSING_HOUSE",
	[1] = "HOUSING_TWO_STORY_UP",
	[2] = "HOUSING_MANSION_UP_TWO_STORY",
})

-- Every SKU legally offerable at a tier (mirrors ProductCatalog's
-- requiresHousingTier gate, which Shop.GetCatalog filters by): tier 0 sees
-- the three full-price paths, owners see only their discounted upgrade
-- paths, tier 3 sees nothing. The "_UP_" SKUs are fixed-price dev products;
-- offering them only at their matching tier is what keeps the §5.1 discount
-- matrix honest (House 499 | 2-Story 999 / 499-from-House | Mansion 2499 /
-- 1999-from-House / 1499-from-2-Story).
local OFFERS: { [number]: { string } } = table.freeze({
	[0] = table.freeze({ "HOUSING_HOUSE", "HOUSING_TWO_STORY", "HOUSING_MANSION" }),
	[1] = table.freeze({ "HOUSING_TWO_STORY_UP", "HOUSING_MANSION_UP_HOUSE" }),
	[2] = table.freeze({ "HOUSING_MANSION_UP_TWO_STORY" }),
	[3] = table.freeze({}),
})

local NO_OFFERS: { string } = table.freeze({})

-- Load-time audit against the catalog of record (ProductCatalog-style hard
-- asserts: drift between this table and the catalog is a bug by definition).
for tier, skus in OFFERS do
	for _, sku in skus do
		local product = ProductCatalog.Get(sku)
		assert(product ~= nil, `HouseTransitions: sku {sku} missing from ProductCatalog`)
		assert(
			product.requiresHousingTier == tier,
			`HouseTransitions: {sku} offered at tier {tier} but requires tier {tostring(product.requiresHousingTier)}`
		)
		local granted = product.grants.housingTier
		assert(
			granted ~= nil and granted > tier,
			`HouseTransitions: {sku} must grant a tier strictly above {tier} (no downgrade/no-op paths)`
		)
	end
end
for tier, sku in NEXT_CTA do
	local offered = false
	for _, offeredSku in OFFERS[tier] do
		offered = offered or offeredSku == sku
	end
	assert(offered, `HouseTransitions: CTA {sku} is not offered at tier {tier}`)
end

-- The single next-step SKU to prompt/surface for a player at `tier`, or nil
-- at the tier cap (and for any out-of-range tier — fail closed: never sell).
function HouseTransitions.NextCta(tier: number): string?
	return NEXT_CTA[tier]
end

-- Every SKU the storefront may show a player at `tier` (unknown tiers ->
-- empty, fail closed). Returned tables are frozen module data — do not mutate.
function HouseTransitions.OffersFor(tier: number): { string }
	return OFFERS[tier] or NO_OFFERS
end

-- "+N pet slots" ghost-preview copy for the NEXT tier (SOP §5.4 verbatim:
-- +12 / +12 / +36 — sell capacity, not geometry). Tier 0 pitches the House's
-- full 12-slot capacity (the 8 lawn podiums are free starter dressing, not
-- part of the paid pitch); later tiers pitch the capacity delta. 0 at the cap.
function HouseTransitions.SlotsDelta(tier: number): number
	if tier <= 0 then
		return GameConstants.HOUSING_TIER_SLOTS[1]
	end
	local currentSlots = GameConstants.HOUSING_TIER_SLOTS[tier]
	local nextSlots = GameConstants.HOUSING_TIER_SLOTS[tier + 1]
	if currentSlots == nil or nextSlots == nil then
		return 0
	end
	return nextSlots - currentSlots
end

return table.freeze(HouseTransitions)
