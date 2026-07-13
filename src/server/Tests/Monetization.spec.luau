--!strict
-- CRYPTLINGS: NIGHT SHIFT — MonetizationService spec (Stage 6 "Monetization
-- wiring + compliance gates"; SOP §4.2/§4.3, §8.1; contracts §B, §D, §F, §I).
-- TestEZ-style: run in Studio via TestEZ (DevPackages testez) pointed at
-- ServerScriptService.Server.Tests.
--
-- Uses the Studio-only test seams end to end (mock-receipt acceptance):
--   PlayerDataService.LoadMockProfileForTest(fixture)
--   MonetizationService.SetAssetIdForTest / ProcessReceiptForTest /
--     SetRandomRestrictedForTest / SetPassOwnedForTest /
--     RunStarterPackCheckForTest
-- Outside Studio the seams are inert (SetAssetIdForTest returns false) and the
-- whole spec SKIPs with a clear warn.
--
-- Covered:
--   * CASE_BUNDLE_S receipt -> exactly 5 sealed Tier-2 source="bundle" cases;
--     double-delivery of the SAME receiptId -> PurchaseGranted, no re-grant
--   * unknown ProductId / restricted player isRandom receipt -> NotProcessedYet
--     (§8.1 defense-in-depth; deterministic SKUs still deliver)
--   * STARTER_PACK grant spec + one-per-account (second receipt consumes,
--     grants nothing extra)
--   * starter-pack trigger: secondExtractionAt set -> starterPackOfferAt
--     persisted exactly once; NEVER offered while restricted
--   * OwnsPass: cache-only profile passCache + the SetPassOwnedForTest override

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

local FIXTURE_USER_ID = 90000061

-- Studio-only fake assetIds (registered both directions by SetAssetIdForTest).
local ASSET_BUNDLE_S = 900001
local ASSET_STARTER_PACK = 900002
local ASSET_SCENT_SPRAY = 900003

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

return function()
	-- TestEZ injects describe/it/expect via setfenv; localize through getfenv
	-- so the file stays --!strict clean (house spec pattern).
	local env = getfenv() :: any
	local describe: (string, () -> ()) -> () = env.describe
	local it: (string, () -> ()) -> () = env.it
	local itSKIP: (string, () -> ()) -> () = env.itSKIP
	local expect: (any) -> any = env.expect
	local beforeEach: (() -> ()) -> () = env.beforeEach
	local afterAll: (() -> ()) -> () = env.afterAll
	if type(describe) ~= "function" or type(it) ~= "function" or type(expect) ~= "function" then
		warn("[Monetization.spec] TestEZ globals missing — run via TestEZ from DevPackages; spec skipped")
		return
	end

	local MonetizationService = requireService("MonetizationService")
	local PlayerDataService = requireService("PlayerDataService")
	if MonetizationService == nil or PlayerDataService == nil then
		warn("[Monetization.spec] MonetizationService/PlayerDataService not found; spec skipped")
		return
	end

	-- Player-like fixture with an in-memory mock profile (nothing persists).
	-- Parent = nil keeps owner-only remote pushes (ShopGrant, StarterPackOffer)
	-- silently skipped for the fixture.
	local fixture: any = {
		UserId = FIXTURE_USER_ID,
		Name = "MonetizationSpecPlayer",
		DisplayName = "MonetizationSpecPlayer",
		Parent = nil,
	}
	if PlayerDataService.LoadMockProfileForTest(fixture) == nil then
		warn("[Monetization.spec] LoadMockProfileForTest unavailable (run in Studio); spec skipped")
		describe("MonetizationService", function()
			itSKIP("requires the Studio-only PlayerDataService mock-profile seam", function() end)
		end)
		return
	end

	-- Register the fake dev-product ids (Studio-only; false outside Studio).
	local seamsLive = MonetizationService.SetAssetIdForTest("CASE_BUNDLE_S", ASSET_BUNDLE_S) == true
		and MonetizationService.SetAssetIdForTest("STARTER_PACK", ASSET_STARTER_PACK) == true
		and MonetizationService.SetAssetIdForTest("SCENT_SPRAY", ASSET_SCENT_SPRAY) == true
	if not seamsLive then
		warn("[Monetization.spec] Studio-only test seams inert (non-Studio run?); spec skipped")
		describe("MonetizationService", function()
			itSKIP("requires the Studio-only MonetizationService test seams", function() end)
		end)
		PlayerDataService.ReleaseMockProfileForTest(fixture)
		return
	end

	local receiptCounter = 0
	local function makeReceipt(productId: number, receiptId: string?): any
		receiptCounter += 1
		return {
			PurchaseId = receiptId or `monetization-spec-r{receiptCounter}`,
			ProductId = productId,
			PlayerId = FIXTURE_USER_ID,
			CurrencySpent = 240,
		}
	end

	local function getProfile(): Types.ProfileData
		local data = PlayerDataService.Get(fixture) :: Types.ProfileData?
		assert(data ~= nil, "Monetization.spec: mock profile unloaded mid-test")
		return data
	end

	local function resetProfileState()
		PlayerDataService.Update(fixture, function(data: Types.ProfileData)
			table.clear(data.locker.cases)
			data.locker.extraOpenCredits = 0
			table.clear(data.collection)
			data.consumables.scentSpray = 0
			data.consumables.reviveBeacon = 0
			data.consumables.foremansKey = 0
			data.monetization.starterPackOwned = false
			data.monetization.starterPackOfferAt = 0
			table.clear(data.monetization.processedReceipts)
			table.clear(data.monetization.passCache)
			data.stats.secondExtractionAt = 0
		end)
	end

	describe("MonetizationService (mock receipts)", function()
		beforeEach(function()
			resetProfileState()
			-- The compliance default is fail-closed (restricted) for fixtures;
			-- tests opt IN to the unrestricted path explicitly (contract §I).
			MonetizationService.SetRandomRestrictedForTest(fixture, false)
		end)

		afterAll(function()
			MonetizationService.SetRandomRestrictedForTest(fixture, nil)
			MonetizationService.SetPassOwnedForTest(fixture, "PASS_CARRY", nil)
			PlayerDataService.ReleaseMockProfileForTest(fixture)
		end)

		it("grants CASE_BUNDLE_S exactly once across a double-delivered receipt", function()
			local receipt = makeReceipt(ASSET_BUNDLE_S, "monetization-spec-bundle-r1")

			local first = MonetizationService.ProcessReceiptForTest(receipt, fixture)
			expect(first).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)

			-- Roblox redelivers the SAME PurchaseId: consume, never re-grant.
			local second = MonetizationService.ProcessReceiptForTest(receipt, fixture)
			expect(second).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)

			local cases = getProfile().locker.cases
			expect(#cases).to.equal(5) -- CASE_BUNDLE_S grant spec (§F), once
			for _, stub in cases do
				expect(stub.tier).to.equal(2)
				expect(stub.source).to.equal("bundle")
			end
			expect(#getProfile().monetization.processedReceipts).to.equal(1)
		end)

		it("returns NotProcessedYet for an unknown ProductId", function()
			local decision = MonetizationService.ProcessReceiptForTest(makeReceipt(123456789), fixture)
			expect(decision).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(#getProfile().monetization.processedReceipts).to.equal(0)
		end)

		it("refuses isRandom receipts for restricted players but still delivers deterministic SKUs (§8.1)", function()
			MonetizationService.SetRandomRestrictedForTest(fixture, true)

			local randomDecision = MonetizationService.ProcessReceiptForTest(makeReceipt(ASSET_BUNDLE_S), fixture)
			expect(randomDecision).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(#getProfile().locker.cases).to.equal(0)

			-- Money already charged on a NON-random SKU: deliver regardless.
			local sprayDecision = MonetizationService.ProcessReceiptForTest(makeReceipt(ASSET_SCENT_SPRAY), fixture)
			expect(sprayDecision).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(getProfile().consumables.scentSpray).to.equal(1)
		end)

		it("fails closed when no compliance answer exists (override cleared)", function()
			MonetizationService.SetRandomRestrictedForTest(fixture, nil)
			-- A player-like fixture is not a Player: ComplianceService answers
			-- restricted=true (contract §I fail-closed), so the receipt is refused.
			local decision = MonetizationService.ProcessReceiptForTest(makeReceipt(ASSET_BUNDLE_S), fixture)
			expect(decision).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(#getProfile().locker.cases).to.equal(0)
		end)

		it("applies the STARTER_PACK grant spec and enforces one-per-account", function()
			local first = MonetizationService.ProcessReceiptForTest(makeReceipt(ASSET_STARTER_PACK), fixture)
			expect(first).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)

			local data = getProfile()
			expect(data.monetization.starterPackOwned).to.equal(true)
			expect(data.consumables.foremansKey).to.equal(1)
			expect(data.locker.extraOpenCredits).to.equal(2)
			expect(data.collection.misprint_trophy).to.equal(1)

			-- A second purchase (NEW receiptId) is consumed but grants nothing
			-- extra (§4.3 one-per-account; the prompt path normally prevents it).
			local second = MonetizationService.ProcessReceiptForTest(makeReceipt(ASSET_STARTER_PACK), fixture)
			expect(second).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)

			data = getProfile()
			expect(data.consumables.foremansKey).to.equal(1)
			expect(data.locker.extraOpenCredits).to.equal(2)
			expect(data.collection.misprint_trophy).to.equal(1)
			expect(#data.monetization.processedReceipts).to.equal(2)
		end)

		it("offers the starter pack exactly once after the second extraction", function()
			PlayerDataService.Update(fixture, function(data: Types.ProfileData)
				data.stats.secondExtractionAt = os.time()
			end)

			MonetizationService.RunStarterPackCheckForTest(fixture)
			local offerAt = getProfile().monetization.starterPackOfferAt
			expect(offerAt > 0).to.equal(true)

			-- Re-running the trigger must never restart the 24h window.
			MonetizationService.RunStarterPackCheckForTest(fixture)
			expect(getProfile().monetization.starterPackOfferAt).to.equal(offerAt)
		end)

		it("never offers the starter pack to a restricted player (§8.1)", function()
			MonetizationService.SetRandomRestrictedForTest(fixture, true)
			PlayerDataService.Update(fixture, function(data: Types.ProfileData)
				data.stats.secondExtractionAt = os.time()
			end)

			MonetizationService.RunStarterPackCheckForTest(fixture)
			expect(getProfile().monetization.starterPackOfferAt).to.equal(0)
		end)

		it("OwnsPass reads the profile passCache and honors the test override", function()
			expect(MonetizationService.OwnsPass(fixture, "PASS_CARRY")).to.equal(false)

			PlayerDataService.Update(fixture, function(data: Types.ProfileData)
				data.monetization.passCache.PASS_CARRY = true
			end)
			expect(MonetizationService.OwnsPass(fixture, "PASS_CARRY")).to.equal(true)

			MonetizationService.SetPassOwnedForTest(fixture, "PASS_CARRY", false)
			expect(MonetizationService.OwnsPass(fixture, "PASS_CARRY")).to.equal(false)
			MonetizationService.SetPassOwnedForTest(fixture, "PASS_CARRY", nil)
			expect(MonetizationService.OwnsPass(fixture, "PASS_CARRY")).to.equal(true)

			-- Dev products are never passes, whatever the cache claims.
			expect(MonetizationService.OwnsPass(fixture, "CASE_BUNDLE_S")).to.equal(false)
		end)
	end)
end
