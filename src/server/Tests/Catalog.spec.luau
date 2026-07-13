--!strict
-- CRYPTLINGS: NIGHT SHIFT — PriceLadder/ProductCatalog spec (Stage 4 economy QA;
-- SOP §4.2, §8.1; contract §F). TestEZ-style: run in Studio via TestEZ
-- (`Packages`/`DevPackages` testez) pointed at ServerScriptService.Server.Tests.
-- Pure-logic assertions — no players or DataStores needed:
--   * every sellable PriceLadder row has a ProductCatalog entry whose kind and
--     storefront price match the ladder of record (§4.2 transcribed verbatim)
--   * isRandom is set on EXACTLY STARTER_PACK / FOREMANS_KEY / CASE_BUNDLE_*
--     (the §8.1 paid-random set, direct AND indirect) and nothing else
--   * bundle case counts and bonusPct match §4.2/§4.3 (5/+0, 13/+4, 35/+12,
--     125/+20, 423/+40 — all sealed Tier 2 cases; advertised bonus % never
--     overstates the actual cases-per-Robux gain vs the 240 R$ baseline)
--   * GetSellable(restricted = true) returns ZERO isRandom items (§8.1 UK
--     under-18 gate: those players see only deterministic SKUs)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = Shared:WaitForChild("Economy")
local PriceLadder = require(Economy:WaitForChild("PriceLadder"))
local ProductCatalog = require(Economy:WaitForChild("ProductCatalog"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))

-- §8.1 paid-random set: direct (bundles) and indirect (key; pack contains a key).
local EXPECTED_RANDOM_SKUS: { [string]: boolean } = {
	STARTER_PACK = true,
	FOREMANS_KEY = true,
	CASE_BUNDLE_S = true,
	CASE_BUNDLE_M = true,
	CASE_BUNDLE_L = true,
	CASE_BUNDLE_XL = true,
	CASE_BUNDLE_WHALE = true,
}

-- §4.2 bundle ladder of record (PS99 model): count / bonusPct / price.
-- bonusPct = actual cases-per-Robux gain vs the 240 R$/5-case baseline,
-- rounded DOWN (advertised copy must never overstate — compliance).
local EXPECTED_BUNDLES: { [string]: { count: number, bonusPct: number, priceRobux: number } } = {
	CASE_BUNDLE_S = { count = 5, bonusPct = 0, priceRobux = 240 },
	CASE_BUNDLE_M = { count = 13, bonusPct = 4, priceRobux = 599 },
	CASE_BUNDLE_L = { count = 35, bonusPct = 12, priceRobux = 1499 },
	CASE_BUNDLE_XL = { count = 125, bonusPct = 20, priceRobux = 4999 },
	CASE_BUNDLE_WHALE = { count = 423, bonusPct = 40, priceRobux = 14499 },
}

-- Local flag tables so assertions never depend on the live (mutable)
-- Economy/Flags state another system may have toggled (§4.4 split tests).
local FLAGS_ALL_ON = { whaleBundlesLive = true, vipLockerPublic = true, starterPackEnabled = true }
local FLAGS_DEFAULTS = { whaleBundlesLive = false, vipLockerPublic = false, starterPackEnabled = true }

return function()
	-- TestEZ injects describe/it/expect into this function's environment
	-- (setfenv). Localize through getfenv so the file stays --!strict clean.
	local env = getfenv() :: any
	local describe: (string, () -> ()) -> () = env.describe
	local it: (string, () -> ()) -> () = env.it
	local expect: (any) -> any = env.expect
	if type(describe) ~= "function" or type(it) ~= "function" or type(expect) ~= "function" then
		warn(
			"[Catalog.spec] TestEZ globals missing — run via TestEZ from Packages/DevPackages"
				.. " (wally install); spec skipped"
		)
		return
	end

	describe("PriceLadder <-> ProductCatalog (contract §F)", function()
		it("has a ProductCatalog entry for every ladder row, kinds matching", function()
			expect(#PriceLadder.Rows > 0).to.equal(true)
			for _, row in PriceLadder.Rows do
				local productSpec = ProductCatalog.Get(row.sku)
				expect(productSpec).to.be.ok()
				expect(productSpec.sku).to.equal(row.sku)
				expect(productSpec.kind).to.equal(row.type)
			end
		end)

		it("has no orphan catalog entries (every sku traces back to the ladder)", function()
			for sku in ProductCatalog.BySku do
				expect(PriceLadder.GetRow(sku)).to.be.ok()
			end
		end)

		it("sells every wiredInMvp row at the EXACT ladder price (§4.2/§4.4)", function()
			local sellable = ProductCatalog.GetSellable(false, FLAGS_ALL_ON)
			local bySku: { [string]: any } = {}
			for _, entry in sellable do
				expect(bySku[entry.sku]).never.to.be.ok() -- no duplicate listings
				bySku[entry.sku] = entry
			end
			for _, row in PriceLadder.Rows do
				local entry = bySku[row.sku]
				if row.wiredInMvp then
					expect(entry).to.be.ok()
					expect(entry.priceRobux).to.equal(row.priceRobux)
					expect(entry.displayName).to.equal(row.displayName)
					expect(entry.kind).to.equal(row.type)
				else
					-- SEASON_PASS / SEASON_SKIP / COLLECTORS_CLUB ship later.
					expect(entry).never.to.be.ok()
				end
			end
		end)
	end)

	describe("Paid-random flagging (§8.1)", function()
		it("sets isRandom on EXACTLY the starter pack, key, and bundles", function()
			for sku, productSpec in ProductCatalog.BySku do
				expect(productSpec.isRandom).to.equal(EXPECTED_RANDOM_SKUS[sku] == true)
			end
			-- And the expected set itself is fully present in the catalog.
			for sku in EXPECTED_RANDOM_SKUS do
				expect(ProductCatalog.Get(sku)).to.be.ok()
			end
		end)

		it("returns ZERO isRandom items for restricted players (§8.1 UK gate)", function()
			local restricted = ProductCatalog.GetSellable(true, FLAGS_ALL_ON)
			expect(#restricted > 0).to.equal(true) -- deterministic SKUs still sell
			for _, entry in restricted do
				expect(entry.isRandom).to.equal(false)
				expect(EXPECTED_RANDOM_SKUS[entry.sku]).never.to.be.ok()
			end
		end)

		it("withholds whale bundles and VIP locker behind contract-F default flags (§4.1)", function()
			local defaults = ProductCatalog.GetSellable(false, FLAGS_DEFAULTS)
			local seen: { [string]: boolean } = {}
			for _, entry in defaults do
				seen[entry.sku] = true
			end
			expect(seen.CASE_BUNDLE_XL).never.to.be.ok()
			expect(seen.CASE_BUNDLE_WHALE).never.to.be.ok()
			expect(seen.PASS_VIP_LOCKER).never.to.be.ok()
			expect(seen.STARTER_PACK).to.equal(true) -- starterPackEnabled defaults true
			expect(seen.CASE_BUNDLE_S).to.equal(true)
		end)
	end)

	describe("Bundle grants (§4.2/§4.3)", function()
		it("matches case counts, bonusPct, and prices to the ladder of record", function()
			for sku, expected in EXPECTED_BUNDLES do
				local productSpec = ProductCatalog.Get(sku)
				expect(productSpec).to.be.ok()
				expect(productSpec.bonusPct).to.equal(expected.bonusPct)
				local cases = productSpec.grants.cases
				expect(cases).to.be.ok()
				expect(cases.tier).to.equal(5) -- Robux-paid bundles grant SEALED Tier 5 cases
				expect(cases.count).to.equal(expected.count)
				local row = PriceLadder.GetRow(sku)
				expect(row).to.be.ok()
				expect(row.priceRobux).to.equal(expected.priceRobux)
				-- Bundles grant sealed cases, never opens (§4.3 cross-sell).
				expect(productSpec.grants.extraOpenCredits).never.to.be.ok()
			end
		end)

		it("grants the §4.2 starter pack: 1 key + 2 open credits + misprint_trophy", function()
			local starter = ProductCatalog.Get("STARTER_PACK")
			expect(starter).to.be.ok()
			expect(starter.onePerAccount).to.equal(true)
			expect(starter.grants.consumables.foremansKey).to.equal(1)
			expect(starter.grants.extraOpenCredits).to.equal(2)
			expect(starter.grants.cryptlings.misprint_trophy).to.equal(1)
			-- The trophy must exist in the roster as the untradeable shelf piece.
			local trophy = RarityTable.GetCryptling("misprint_trophy")
			expect(trophy).to.be.ok()
			expect(trophy.tradeable).to.equal(false)
			expect(PriceLadder.GetRow("STARTER_PACK").priceRobux).to.equal(99)
		end)
	end)
end
