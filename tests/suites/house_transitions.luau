--!strict
-- House transitions suite (LOBBY_SOP §5 — server-side housing SKU selection).
-- Pins the tier -> SKU surface that MonetizationService.PromptNextHousing and
-- the Shop housing tab trust: the single state-gated CTA per tier, the
-- per-tier offer lists, the verbatim SOP §5.1 prices (full 499/999/2499,
-- deltas 499/1499), and the no-downgrade / no-early-offer invariants.

local GameConstants = require("../../src/shared/Config/GameConstants")
local HouseTransitions = require("../../src/shared/Logic/HouseTransitions")
local PriceLadder = require("../../src/shared/Economy/PriceLadder")
local ProductCatalog = require("../../src/shared/Economy/ProductCatalog")
local expect = require("../expect")

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local TIERS = { 0, 1, 2, 3 }

local function priceOf(sku: string): number
	local row = PriceLadder.GetRow(sku)
	expect.ok(row ~= nil, `{sku} present in PriceLadder`)
	return (row :: any).priceRobux
end

local function offersContain(tier: number, sku: string): boolean
	for _, offered in HouseTransitions.OffersFor(tier) do
		if offered == sku then
			return true
		end
	end
	return false
end

-- Every housing SKU in the catalog of record (any SKU granting a tier).
local function housingSkus(): { [string]: ProductCatalog.ProductSpec }
	local found: { [string]: ProductCatalog.ProductSpec } = {}
	for sku, product in ProductCatalog.BySku do
		if product.grants.housingTier ~= nil then
			found[sku] = product
		end
	end
	return found
end

--------------------------------------------------------------------------------

test("single state-gated CTA per tier (SOP §5.4), nil at the cap", function()
	expect.eq(HouseTransitions.NextCta(0), "HOUSING_HOUSE", "tier 0 CTA")
	expect.eq(HouseTransitions.NextCta(1), "HOUSING_TWO_STORY_UP", "tier 1 CTA")
	expect.eq(HouseTransitions.NextCta(2), "HOUSING_MANSION_UP_TWO_STORY", "tier 2 CTA")
	expect.eq(HouseTransitions.NextCta(3), nil, "tier 3 (cap) has no CTA")
	expect.eq(HouseTransitions.NextCta(GameConstants.HOUSING_MAX_TIER), nil, "HOUSING_MAX_TIER has no CTA")
	expect.eq(HouseTransitions.NextCta(99), nil, "out-of-range tier fails closed")
end)

test("CTA prices are the SOP §5.1 deltas verbatim: 499 / 499 / 1499", function()
	expect.eq(priceOf(HouseTransitions.NextCta(0) :: string), 499, "tier 0 -> 1 CTA price")
	expect.eq(priceOf(HouseTransitions.NextCta(1) :: string), 499, "tier 1 -> 2 CTA price")
	expect.eq(priceOf(HouseTransitions.NextCta(2) :: string), 1499, "tier 2 -> 3 CTA price")
end)

test("offer lists per tier match the discount matrix exactly", function()
	expect.deepEq(
		HouseTransitions.OffersFor(0),
		{ "HOUSING_HOUSE", "HOUSING_TWO_STORY", "HOUSING_MANSION" },
		"tier 0 offers"
	)
	expect.deepEq(
		HouseTransitions.OffersFor(1),
		{ "HOUSING_TWO_STORY_UP", "HOUSING_MANSION_UP_HOUSE" },
		"tier 1 offers"
	)
	expect.deepEq(HouseTransitions.OffersFor(2), { "HOUSING_MANSION_UP_TWO_STORY" }, "tier 2 offers")
	expect.deepEq(HouseTransitions.OffersFor(3), {}, "tier 3 (cap) offers nothing")
	expect.deepEq(HouseTransitions.OffersFor(99), {}, "out-of-range tier offers nothing")
end)

test("full-price paths 499 / 999 / 2499 all reachable from tier 0", function()
	local wantPrices: { [string]: number } = { HOUSING_HOUSE = 499, HOUSING_TWO_STORY = 999, HOUSING_MANSION = 2499 }
	for sku, price in wantPrices do
		expect.ok(offersContain(0, sku), `{sku} offered at tier 0`)
		expect.eq(priceOf(sku), price, `{sku} full price`)
	end
end)

test("every offered SKU's requiresHousingTier equals the tier it is offered at", function()
	for _, tier in TIERS do
		for _, sku in HouseTransitions.OffersFor(tier) do
			local product = ProductCatalog.Get(sku)
			expect.ok(product ~= nil, `{sku} present in ProductCatalog`)
			expect.eq((product :: any).requiresHousingTier, tier, `{sku} prerequisite tier`)
		end
	end
end)

test("no housing SKU is ever offered below its prerequisite tier (catalog sweep)", function()
	for sku, product in housingSkus() do
		local prerequisite = product.requiresHousingTier
		expect.ok(prerequisite ~= nil, `{sku} declares requiresHousingTier`)
		for _, tier in TIERS do
			if offersContain(tier, sku) then
				expect.ok(tier >= (prerequisite :: number), `{sku} never offered below tier {tostring(prerequisite)}`)
			end
		end
	end
end)

test("granted tier strictly greater than offering tier (no downgrade paths)", function()
	for _, tier in TIERS do
		for _, sku in HouseTransitions.OffersFor(tier) do
			local product = ProductCatalog.Get(sku) :: ProductCatalog.ProductSpec
			local granted = product.grants.housingTier
			expect.ok(granted ~= nil and granted > tier, `{sku} grants strictly above tier {tier}`)
			expect.ok((granted :: number) <= GameConstants.HOUSING_MAX_TIER, `{sku} grants within HOUSING_MAX_TIER`)
		end
	end
end)

test("CTA sku is always among that tier's offers; cap tier offers none", function()
	for _, tier in TIERS do
		local cta = HouseTransitions.NextCta(tier)
		if tier < GameConstants.HOUSING_MAX_TIER then
			expect.ok(cta ~= nil, `tier {tier} has a CTA`)
			expect.ok(offersContain(tier, cta :: string), `tier {tier} CTA {tostring(cta)} is offered`)
		else
			expect.eq(cta, nil, `tier {tier} has no CTA`)
			expect.eq(#HouseTransitions.OffersFor(tier), 0, `tier {tier} offers nothing`)
		end
	end
end)

test("every catalog housing SKU is offered at exactly one tier (full coverage)", function()
	local skuCount = 0
	for sku in housingSkus() do
		skuCount += 1
		local offeredAt = 0
		for _, tier in TIERS do
			if offersContain(tier, sku) then
				offeredAt += 1
			end
		end
		expect.eq(offeredAt, 1, `{sku} offered at exactly one tier`)
	end
	expect.eq(skuCount, 6, "six housing SKUs of record (3 full-price + 3 upgrade paths)")
end)

test("SlotsDelta matches the SOP §5.4 ghost-preview copy: +12 / +12 / +36, 0 at cap", function()
	expect.eq(HouseTransitions.SlotsDelta(0), 12, "tier 0 pitch (+12 pet slots)")
	expect.eq(HouseTransitions.SlotsDelta(1), 12, "tier 1 pitch (+12 pet slots)")
	expect.eq(HouseTransitions.SlotsDelta(2), 36, "tier 2 pitch (+36 pet slots)")
	expect.eq(HouseTransitions.SlotsDelta(3), 0, "cap tier has nothing to pitch")
	expect.eq(HouseTransitions.SlotsDelta(99), 0, "out-of-range tier pitches nothing")
	-- Capacity copy stays consistent with the slot table of record: the
	-- upgrade pitches climb exactly to the mansion's 60-slot cap.
	expect.eq(
		HouseTransitions.SlotsDelta(0) + HouseTransitions.SlotsDelta(1) + HouseTransitions.SlotsDelta(2),
		GameConstants.HOUSING_MAX_SLOTS,
		"pitch deltas sum to HOUSING_MAX_SLOTS"
	)
end)

return { name = "house transitions (LOBBY_SOP §5)", tests = tests }
