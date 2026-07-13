--!strict
-- CRYPTLINGS: NIGHT SHIFT — ComplianceService spec (Stage 6 SOP §8.1 gates;
-- contracts §B, §E, §F, §I). TestEZ-style: run in Studio via TestEZ
-- (DevPackages testez) pointed at ServerScriptService.Server.Tests.
--
-- Covered:
--   * [AUDIT] live permissive catalog passes the §8.1 invariant audit
--   * [AUDIT] injected mismatched price / missing odds / wrong-tier odds fail
--     loudly with the offending sku in the message
--   * [GATE] ProductCatalog.GetSellable(restricted=true) withholds EVERY
--     isRandom SKU; rollout flags gate the whale/VIP SKUs
--   * [GATE] IsRandomRestricted fails CLOSED on a non-Player (contract §I)
--   * [ODDS] disclosure tiers: bundles carry their granted tier's table,
--     FOREMANS_KEY / STARTER_PACK carry the Tier 3 vault table (audit rows)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Economy = Shared:WaitForChild("Economy")
local PriceLadder = require(Economy:WaitForChild("PriceLadder")) :: any
local ProductCatalog = require(Economy:WaitForChild("ProductCatalog")) :: any

local PERMISSIVE_FLAGS = {
	whaleBundlesLive = true,
	vipLockerPublic = true,
	starterPackEnabled = true,
}

local function requireService(name: string): any
	local testsFolder = script.Parent
	local serverRoot = testsFolder and testsFolder.Parent
	local servicesFolder = serverRoot and serverRoot:FindFirstChild("Services")
	local module = servicesFolder and servicesFolder:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, service = pcall(require, module)
	if ok and type(service) == "table" then
		return service
	end
	return nil
end

local function containsSku(messages: { string }, sku: string): boolean
	for _, message in messages do
		if string.find(message, sku, 1, true) ~= nil then
			return true
		end
	end
	return false
end

return function()
	-- TestEZ injects describe/it/expect via setfenv; localize through getfenv
	-- so the file stays --!strict clean (house spec pattern).
	local env = getfenv() :: any
	local describe: (string, () -> ()) -> () = env.describe
	local it: (string, () -> ()) -> () = env.it
	local expect: (any) -> any = env.expect
	if type(describe) ~= "function" or type(it) ~= "function" or type(expect) ~= "function" then
		warn("[Compliance.spec] TestEZ globals missing — run via TestEZ from DevPackages; spec skipped")
		return
	end

	local ComplianceService = requireService("ComplianceService")
	if ComplianceService == nil then
		warn("[Compliance.spec] ComplianceService not found under Server.Services; spec skipped")
		return
	end

	describe("ComplianceService [AUDIT] (§8.1 invariants)", function()
		it("passes on the live permissive catalog", function()
			local failures = ComplianceService.RunAuditForTest(nil)
			expect(#failures).to.equal(0)
		end)

		it("fails an injected price that drifts from the Price Ladder of Record", function()
			local ladderRow = PriceLadder.GetRow("CASE_BUNDLE_S")
			local failures = ComplianceService.RunAuditForTest({
				{
					sku = "CASE_BUNDLE_S",
					priceRobux = ladderRow.priceRobux + 1, -- deliberate drift
					isRandom = true,
					odds = RarityTable.GetOdds(RarityTable.BASELINE_TIER),
					assetId = 900001,
				},
			})
			expect(#failures).to.equal(1)
			expect(containsSku(failures, "CASE_BUNDLE_S")).to.equal(true)
		end)

		it("fails an isRandom row with no odds disclosure", function()
			local ladderRow = PriceLadder.GetRow("CASE_BUNDLE_M")
			local failures = ComplianceService.RunAuditForTest({
				{
					sku = "CASE_BUNDLE_M",
					priceRobux = ladderRow.priceRobux,
					isRandom = true,
					odds = nil, -- the §8.1 sin
					assetId = 900002,
				},
			})
			expect(#failures).to.equal(1)
			expect(containsSku(failures, "CASE_BUNDLE_M")).to.equal(true)
		end)

		it("fails FOREMANS_KEY disclosing the wrong tier's odds", function()
			local ladderRow = PriceLadder.GetRow("FOREMANS_KEY")
			local failures = ComplianceService.RunAuditForTest({
				{
					sku = "FOREMANS_KEY",
					priceRobux = ladderRow.priceRobux,
					isRandom = true,
					-- The key opens a Tier 3 vault case; a Tier 2 table understates
					-- nothing but is NOT the disclosure of record (§8.1 audit).
					odds = RarityTable.GetOdds(RarityTable.BASELINE_TIER),
					assetId = 900003,
				},
			})
			expect(#failures).to.equal(1)
			expect(containsSku(failures, "FOREMANS_KEY")).to.equal(true)
		end)
	end)

	describe("ComplianceService [GATE] (restricted storefront)", function()
		it("GetSellable(restricted=true) withholds every isRandom SKU", function()
			local sellable = ProductCatalog.GetSellable(true, PERMISSIVE_FLAGS)
			expect(#sellable > 0).to.equal(true)
			for _, row in sellable do
				expect(row.isRandom).to.equal(false)
			end
		end)

		it("GetSellable(restricted=false) includes the random SKUs", function()
			local sellable = ProductCatalog.GetSellable(false, PERMISSIVE_FLAGS)
			local skus: { [string]: boolean } = {}
			for _, row in sellable do
				skus[row.sku] = true
			end
			expect(skus.CASE_BUNDLE_S).to.equal(true)
			expect(skus.FOREMANS_KEY).to.equal(true)
			expect(skus.STARTER_PACK).to.equal(true)
			expect(skus.CASE_BUNDLE_WHALE).to.equal(true) -- permissive flags
		end)

		it("rollout flags gate the whale bundles and the VIP locker pass (§4.1)", function()
			local gatedFlags = {
				whaleBundlesLive = false,
				vipLockerPublic = false,
				starterPackEnabled = true,
			}
			local skus: { [string]: boolean } = {}
			for _, row in ProductCatalog.GetSellable(false, gatedFlags) do
				skus[row.sku] = true
			end
			expect(skus.CASE_BUNDLE_XL).to.equal(nil)
			expect(skus.CASE_BUNDLE_WHALE).to.equal(nil)
			expect(skus.PASS_VIP_LOCKER).to.equal(nil)
			expect(skus.CASE_BUNDLE_S).to.equal(true) -- non-whale ladder unaffected
		end)

		it("IsRandomRestricted fails CLOSED on a non-Player (contract §I)", function()
			expect(ComplianceService.IsRandomRestricted({ UserId = 1, Name = "fake" } :: any)).to.equal(true)
			expect(ComplianceService.IsRandomRestricted(nil :: any)).to.equal(true)
		end)
	end)

	describe("ComplianceService [ODDS] (disclosure tiers)", function()
		it("audits bundles at their granted tier and the key/starter pack at the vault tier", function()
			-- The audit's own expected-tier derivation is the disclosure spec of
			-- record: rows built exactly like buildCatalogEntries must pass...
			local vaultOdds = RarityTable.GetOdds(GameConstants.VAULT_CASE_TIER)
			local keyRow = PriceLadder.GetRow("FOREMANS_KEY")
			local starterRow = PriceLadder.GetRow("STARTER_PACK")
			local bundleRow = PriceLadder.GetRow("CASE_BUNDLE_S")
			local bundleSpec = ProductCatalog.Get("CASE_BUNDLE_S")
			local failures = ComplianceService.RunAuditForTest({
				{
					sku = "FOREMANS_KEY",
					priceRobux = keyRow.priceRobux,
					isRandom = true,
					odds = vaultOdds,
					assetId = 900004,
				},
				{
					sku = "STARTER_PACK",
					priceRobux = starterRow.priceRobux,
					isRandom = true,
					odds = vaultOdds, -- contains a Foreman's Key (§F)
					assetId = 900005,
				},
				{
					sku = "CASE_BUNDLE_S",
					priceRobux = bundleRow.priceRobux,
					isRandom = true,
					odds = RarityTable.GetOdds(bundleSpec.grants.cases.tier),
					assetId = 900006,
				},
			})
			expect(#failures).to.equal(0)
		end)
	end)
end
