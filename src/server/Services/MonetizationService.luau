--!strict
-- CRYPTLINGS: NIGHT SHIFT — MonetizationService (Stage 6 "Monetization wiring +
-- compliance gates"; SOP §4.1–4.3, §8.1; contracts §B, §D, §F, §H, §I).
--
-- The SINGLE MarketplaceService.ProcessReceipt owner in the game. Receipt flow:
--   resolve receipt.ProductId -> ProductCatalog sku (assetId mapping; unknown ->
--   NotProcessedYet + warn) -> idempotency (receiptId already in
--   profile.monetization.processedReceipts -> PurchaseGranted immediately) ->
--   inside PlayerDataService.WithLock: apply grants per catalog spec, record the
--   receiptId (ring buffer, last PROCESSED_RECEIPTS_MAX), analytics
--   purchase{sku, price}, ShopGrant push. Any failure -> purchase_failed +
--   NotProcessedYet (Roblox retries; nothing was recorded, nothing granted —
--   the WithLock body is yield-free, so grants + record are atomic in memory).
--
-- Grants (§4.2/§4.3): extraOpenCredits via LockerService.GrantExtraOpens;
-- consumables increment profile.consumables; CASE_BUNDLE_* generate N sealed
-- Tier-2 CaseStubs (source="bundle") via LockerService.AddCases — bundles grant
-- SEALED cases that still pass the unboxing theater and the daily open cap
-- unless VIP Locker is owned (§4.3 cross-sell). STARTER_PACK is one-per-account:
-- a second receipt grants nothing extra but is still PurchaseGranted (the
-- prompt path prevents reaching it).
--
-- GamePasses (contract §I): OwnsPass(player, sku) reads the profile passCache
-- only (never yields); the cache is refreshed via pcall'd UserOwnsGamePassAsync
-- on join and on PromptGamePassPurchaseFinished(success) (+ analytics purchase).
-- Pass EFFECTS need no wiring here — CaseService/ShiftService/LockerService/
-- ShelfService already consult OwnsPass per contract §I. The only cosmetic this
-- service owns is PASS_GOLDEN_SET: on character spawn for owners, a gold
-- greybox flashlight Part + foreman hat Part (decoy anchor, §4.2 — expect no
-- volume).
--
-- Starter Pack first-purchase break (§4.3): poll-watches stats.secondExtractionAt
-- (set by ExtractionService at the player's 2nd successful extraction) and fires
-- the one-time offer exactly once per account (monetization.starterPackOfferAt
-- is persisted BEFORE the client ever sees the offer): StarterPackOffer
-- {expiresAt = now + STARTER_PACK_OFFER_SECONDS} + analytics starter_pack_shown.
-- Gated on Flags.starterPackEnabled and NOT ComplianceService.IsRandomRestricted
-- (the pack contains a Foreman's Key — indirect paid randomness, §8.1).
-- Shop.RequestStarterPackPrompt re-validates the same eligibility + the 24h
-- window, then prompts the purchase server-side.
--
-- Compliance (§8.1, launch blocker): isRandom SKUs are refused at receipt time
-- for restricted players (defense-in-depth behind the storefront gate;
-- NotProcessedYet -> Roblox refund path). ComplianceService missing or erroring
-- fails CLOSED (restricted = true), per contract §I.
--
-- Housing (LOBBY_SOP §5.1/§5.4): PromptNextHousing(player) is the SINGLE
-- housing prompt site in the game — the server resolves the next SKU from
-- profile.housing.tier via Shared.Logic.HouseTransitions and prompts only that
-- dev product. Shop.PromptHousing takes no arguments by design (anything the
-- client passes is refused fail-closed, zero side effects); client SKU
-- selection never exists. GetHousingCtaText/GetLivePriceRobux feed lot signs +
-- ShopUI with MarketplaceService:GetProductInfo-live prices (5 min cache,
-- PriceLadder/LobbyConfig fallback copy). ProcessReceipt is untouched: the
-- requiresHousingTier refusal + one-way max() grant above remain the
-- stale-prompt defense (Security Review Scope §2).
--
-- Test hooks (Studio-only, mock-receipt acceptance specs — never production):
--   MonetizationService.SetAssetIdForTest(sku, assetId)
--   MonetizationService.ProcessReceiptForTest(receipt, playerLike?) -> decision
--   MonetizationService.SetRandomRestrictedForTest(player, restricted: boolean?)
--   MonetizationService.SetPassOwnedForTest(player, sku, owns: boolean?)
--   MonetizationService.RunStarterPackCheckForTest(player)

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig")) :: any
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local HouseTransitions = require(Shared:WaitForChild("Logic"):WaitForChild("HouseTransitions")) :: any
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))
local EconomyFolder = Shared:WaitForChild("Economy")
local Flags = require(EconomyFolder:WaitForChild("Flags"))
local PriceLadder = require(EconomyFolder:WaitForChild("PriceLadder")) :: any
local ProductCatalog = require(EconomyFolder:WaitForChild("ProductCatalog")) :: any

--------------------------------------------------------------------------------
-- Tuning — the gameplay-facing poll cadence was promoted to GameConstants at
-- Stage 6 integration (§G); the rest is service-internal plumbing.
--------------------------------------------------------------------------------

local PROCESSED_RECEIPTS_MAX = 50 -- contract §D: ring buffer, last 50 receiptIds
local STARTER_PACK_POLL_SECONDS = GameConstants.STARTER_PACK_POLL_SECONDS -- §4.3 trigger watch
local PROFILE_WAIT_TIMEOUT_SECONDS = 60 -- join flow: wait for the session lock
local PROFILE_WAIT_POLL_SECONDS = 1
local LIVE_PRICE_TTL_SECONDS = 300 -- LOBBY_SOP §5.4: GetProductInfo price cache (5 min)
local HOUSING_PROMPT_COOLDOWN_SECONDS = 3 -- Security Review Scope §1: prompt-spam cooldown

-- PASS_GOLDEN_SET greybox cosmetics (§4.2 decoy anchor — two Parts, no art).
local GOLDEN_COLOR = RarityTable.RARITY_COLORS.Godly :: Color3
local FLASHLIGHT_SIZE = Vector3.new(0.45, 0.45, 1.4)
local FLASHLIGHT_GRIP_OFFSET = CFrame.new(0, -0.2, -0.7)
local HAT_SIZE = Vector3.new(0.5, 1.6, 1.6) -- Cylinder axis = X; rotated upright

local SKU_STARTER_PACK = "STARTER_PACK"
local SKU_PASS_GOLDEN_SET = "PASS_GOLDEN_SET"
local SKU_PASS_VIP_LOCKER = "PASS_VIP_LOCKER"

local CONSUMABLE_DISPLAY_NAMES: { [string]: string } = {
	scentSpray = "Steady Grips",
	reviveBeacon = "Revive Beacon",
	foremansKey = "Foreman's Key",
	exitWarp = "Exit Warp",
	swordSwings = "Factory Blade swing(s)",
	gunShots = "Zap Blaster shot(s)",
	paintballShots = "Paintball Popper shot(s)",
}

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades that feature, never the receipt math)
--------------------------------------------------------------------------------

local siblingCache: { [string]: any } = {}

local function getSibling(name: string): any
	local cached = siblingCache[name]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end
	local container = script.Parent
	local module = container and container:FindFirstChild(name)
	local result: any = nil
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, required = pcall(require, module)
		if ok and type(required) == "table" then
			result = required
		end
	end
	siblingCache[name] = if result ~= nil then result else false
	return result
end

-- PlayerDataService with the full surface this service relies on, or nil.
local function getDataService(): any
	local dataService = getSibling("PlayerDataService")
	if
		dataService ~= nil
		and type(dataService.Get) == "function"
		and type(dataService.IsLoaded) == "function"
		and type(dataService.Update) == "function"
		and type(dataService.WithLock) == "function"
	then
		return dataService
	end
	return nil
end

-- Analytics, tolerant of player-like test fixtures (skip quietly — the real
-- AnalyticsService warns on non-Instance players).
local function track(player: any, event: string, props: { [string]: any }?)
	if typeof(player) ~= "Instance" then
		return
	end
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

-- Owner-only remote push, tolerant of player-like test fixtures.
local function fireClient(eventName: string, player: any, payload: { [string]: any })
	if typeof(player) ~= "Instance" then
		return
	end
	local ok, err = pcall(function()
		Remotes.GetEvent(eventName):FireClient(player, payload)
	end)
	if not ok then
		warn(`[MonetizationService] {eventName} push failed for {player.Name}: {err}`)
	end
end

--------------------------------------------------------------------------------
-- Service + test override state
--------------------------------------------------------------------------------

local MonetizationService = {}

-- Studio-only test overrides (keyed by player OR player-like fixture).
local restrictedOverride: { [any]: boolean } = {}
local passOwnedOverride: { [any]: { [string]: boolean } } = {}
local testAssetIdBySku: { [string]: number } = {}
local testDevProductSkuByAsset: { [number]: string } = {}
local testGamePassSkuByAsset: { [number]: string } = {}

--------------------------------------------------------------------------------
-- Compliance gate — contract §I: fail CLOSED (restricted) when ComplianceService
-- is missing or errors. §8.1: never sell randomness to restricted players.
--------------------------------------------------------------------------------

local function isRandomRestricted(player: any): boolean
	local override = restrictedOverride[player]
	if override ~= nil then
		return override
	end
	local compliance = getSibling("ComplianceService")
	if compliance ~= nil and type(compliance.IsRandomRestricted) == "function" then
		local ok, restricted = pcall(compliance.IsRandomRestricted, player)
		if ok and type(restricted) == "boolean" then
			return restricted
		end
	end
	return true -- fail-closed
end

--------------------------------------------------------------------------------
-- SKU <-> Roblox assetId resolution. Catalog assetIds are 0 placeholders until
-- the Creator Dashboard products exist; until then only test mappings resolve.
--------------------------------------------------------------------------------

local devProductSkuByAsset: { [number]: string } = {}
local gamePassSkuByAsset: { [number]: string } = {}
local gamePassSkus: { string } = {}

for sku, productSpec in ProductCatalog.BySku :: { [string]: any } do
	local row = PriceLadder.GetRow(sku)
	if productSpec.kind == "GamePass" then
		table.insert(gamePassSkus, sku)
		if productSpec.assetId > 0 then
			gamePassSkuByAsset[productSpec.assetId] = sku
		end
	elseif productSpec.kind == "DevProduct" and row ~= nil and row.wiredInMvp == true then
		if productSpec.assetId > 0 then
			devProductSkuByAsset[productSpec.assetId] = sku
		end
	end
end
table.sort(gamePassSkus) -- deterministic refresh order

local function resolveDevProductSku(productId: number): string?
	return testDevProductSkuByAsset[productId] or devProductSkuByAsset[productId]
end

local function resolveGamePassSku(gamePassId: number): string?
	return testGamePassSkuByAsset[gamePassId] or gamePassSkuByAsset[gamePassId]
end

local function resolveAssetIdForSku(sku: string): number
	local testId = testAssetIdBySku[sku]
	if testId ~= nil and testId > 0 then
		return testId
	end
	local productSpec = ProductCatalog.Get(sku)
	return if productSpec ~= nil then productSpec.assetId else 0
end

--------------------------------------------------------------------------------
-- Live price lookup — LOBBY_SOP §5.4: every displayed price is GetProductInfo-
-- fed, never a hardcoded label. Cached per sku for LIVE_PRICE_TTL_SECONDS
-- (failed lookups are cached too, so a dead marketplace never gets hammered).
-- PriceLadder stays the fallback at every call site, and ComplianceService's
-- boot audit still pins catalog prices to the ladder — this cache only feeds
-- DISPLAY surfaces (lot sign CTA, ShopUI cards via Shop.GetCatalog's
-- livePriceRobux decoration), never grant or receipt math.
--------------------------------------------------------------------------------

type LivePriceEntry = { price: number?, expiresAt: number }
local livePriceCache: { [string]: LivePriceEntry } = {}

-- May yield (MarketplaceService:GetProductInfo) on cache miss — never call
-- from a yield-free path (receipt WithLock bodies). Returns nil when the
-- product isn't live yet (placeholder assetId 0) or the lookup fails; callers
-- fall back to the PriceLadder row / LobbyConfig fallback copy.
function MonetizationService.GetLivePriceRobux(sku: string): number?
	if type(sku) ~= "string" then
		return nil
	end
	local now = os.clock()
	local cached = livePriceCache[sku]
	if cached ~= nil and now < cached.expiresAt then
		return cached.price
	end
	local productSpec = ProductCatalog.Get(sku)
	local assetId = resolveAssetIdForSku(sku)
	if productSpec == nil or assetId <= 0 then
		return nil -- not live yet; nothing worth caching
	end
	local infoType = if productSpec.kind == "GamePass" then Enum.InfoType.GamePass else Enum.InfoType.Product
	local price: number? = nil
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(assetId, infoType)
	end)
	if ok and type(info) == "table" and type((info :: any).PriceInRobux) == "number" then
		price = (info :: any).PriceInRobux
	end
	livePriceCache[sku] = { price = price, expiresAt = now + LIVE_PRICE_TTL_SECONDS }
	return price
end

--------------------------------------------------------------------------------
-- OwnsPass — contract §I. Cached (profile passCache), never yields; safe to
-- call from inside Update fns and noise-model hot paths.
--------------------------------------------------------------------------------

function MonetizationService.OwnsPass(player: any, sku: string): boolean
	local overrides = passOwnedOverride[player]
	if overrides ~= nil and overrides[sku] ~= nil then
		return overrides[sku] == true
	end
	local productSpec = ProductCatalog.Get(sku)
	if productSpec == nil or productSpec.kind ~= "GamePass" then
		return false
	end
	local dataService = getDataService()
	if dataService == nil then
		return false
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	return data ~= nil and data.monetization.passCache[sku] == true
end

--------------------------------------------------------------------------------
-- PASS_GOLDEN_SET greybox cosmetics (§4.2 decoy anchor)
--------------------------------------------------------------------------------

local function makeGoldPart(name: string, shape: Enum.PartType, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = GOLDEN_COLOR
	part.Material = Enum.Material.Metal
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	return part
end

local function weldTo(part: Part, limb: BasePart, offset: CFrame, character: Model)
	part.CFrame = limb.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = limb
	weld.Part1 = part
	weld.Parent = part
	part.Parent = character
end

local function applyGoldenSet(character: Model)
	if character:FindFirstChild("GoldenFlashlight") ~= nil then
		return -- already dressed
	end

	-- Flashlight in the right hand (R15 "RightHand" / R6 "Right Arm"), falling
	-- back to the root so the cosmetic never silently no-shows.
	local hand = character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")
		or character:FindFirstChild("HumanoidRootPart")
	if hand ~= nil and hand:IsA("BasePart") then
		local flashlight = makeGoldPart("GoldenFlashlight", Enum.PartType.Block, FLASHLIGHT_SIZE)
		weldTo(flashlight, hand, FLASHLIGHT_GRIP_OFFSET, character)
	end

	local head = character:FindFirstChild("Head")
	if head ~= nil and head:IsA("BasePart") then
		local hat = makeGoldPart("GoldenForemanHat", Enum.PartType.Cylinder, HAT_SIZE)
		-- Cylinder axis is X; stand it upright on top of the head.
		local offset = CFrame.new(0, head.Size.Y / 2 + HAT_SIZE.X / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
		weldTo(hat, head, offset, character)
	end
end

local function applyGoldenSetIfOwned(player: Player)
	if not MonetizationService.OwnsPass(player, SKU_PASS_GOLDEN_SET) then
		return
	end
	local character = player.Character
	if character ~= nil then
		applyGoldenSet(character)
	end
end

--------------------------------------------------------------------------------
-- Grant application (receipt path)
--------------------------------------------------------------------------------

local function buildBundleStubs(tier: number, count: number): { Types.CaseStub }
	local now = os.time()
	local stubs: { Types.CaseStub } = table.create(count)
	for _ = 1, count do
		table.insert(stubs, {
			uid = HttpService:GenerateGUID(false),
			tier = tier,
			lineId = RarityTable.LINE_ID,
			acquiredAt = now,
			source = "bundle" :: Types.CaseSource,
		})
	end
	return stubs
end

-- Human one-liner for the ShopGrant toast (deterministic order).
local function describeGrants(grants: any): string
	local parts: { string } = {}
	if grants.cases ~= nil then
		table.insert(parts, `{grants.cases.count} sealed Tier {grants.cases.tier} case(s)`)
	end
	if type(grants.extraOpenCredits) == "number" and grants.extraOpenCredits > 0 then
		table.insert(parts, `+{grants.extraOpenCredits} case opening(s)`)
	end
	if grants.resetOpens == true then
		table.insert(parts, "opening limit reset")
	end
	if grants.petUpgrade == true then
		table.insert(parts, "+1 pet level")
	end
	if type(grants.housingTier) == "number" then
		local tierNames: { [number]: string } = { "House", "2-Story House", "Mansion" }
		table.insert(parts, `lot upgraded: {tierNames[grants.housingTier] or `tier {grants.housingTier}`}`)
	end
	if grants.consumables ~= nil then
		local kinds = Util.Keys(grants.consumables) :: { string }
		table.sort(kinds)
		for _, kind in kinds do
			table.insert(parts, `+{grants.consumables[kind]} {CONSUMABLE_DISPLAY_NAMES[kind] or kind}`)
		end
	end
	if grants.cryptlings ~= nil then
		local ids = Util.Keys(grants.cryptlings) :: { string }
		table.sort(ids)
		for _, id in ids do
			local def = RarityTable.GetCryptling(id)
			table.insert(parts, if def ~= nil then def.name else id)
		end
	end
	if #parts == 0 then
		return "Purchase complete"
	end
	return table.concat(parts, ", ")
end

local function hasProcessedReceipt(data: Types.ProfileData, receiptId: string): boolean
	return table.find(data.monetization.processedReceipts, receiptId) ~= nil
end

-- Applies one product's grants + records the receiptId. MUST run inside
-- PlayerDataService.WithLock(player). The body is yield-free end to end
-- (AddCases/GrantExtraOpens/Update never yield, OwnsPass is cache-only), so a
-- player leaving mid-purchase can never persist a half-granted state.
-- Returns a status string: "GRANTED" | "ALREADY" | failure reason.
local function applyReceiptLocked(player: any, productSpec: any, receiptId: string): string
	local dataService = getDataService()
	if dataService == nil then
		return "NO_DATA_SERVICE"
	end
	local live = dataService.Get(player) :: Types.ProfileData?
	if live == nil then
		return "NO_PROFILE"
	end
	if hasProcessedReceipt(live, receiptId) then
		return "ALREADY" -- double-delivery of the same receiptId grants once
	end

	local grants = productSpec.grants
	-- STARTER_PACK already owned: grant nothing extra but still consume the
	-- receipt (§4.3 one-per-account; the prompt path prevents reaching this).
	local skipGrants = productSpec.onePerAccount == true and live.monetization.starterPackOwned == true

	if not skipGrants then
		if grants.cases ~= nil then
			local locker = getSibling("LockerService")
			if locker == nil or type(locker.AddCases) ~= "function" then
				return "NO_LOCKER_SERVICE"
			end
			local stubs = buildBundleStubs(grants.cases.tier, grants.cases.count)
			if locker.AddCases(player, stubs) ~= true then
				return "ADD_CASES_FAILED"
			end
		end
		if type(grants.extraOpenCredits) == "number" and grants.extraOpenCredits > 0 then
			local locker = getSibling("LockerService")
			if locker == nil or type(locker.GrantExtraOpens) ~= "function" then
				return "NO_LOCKER_SERVICE"
			end
			if locker.GrantExtraOpens(player, grants.extraOpenCredits) ~= true then
				return "GRANT_OPENS_FAILED"
			end
		end
		if grants.resetOpens == true then
			local locker = getSibling("LockerService")
			if locker == nil or type(locker.ResetOpenAllowance) ~= "function" then
				return "NO_LOCKER_SERVICE"
			end
			if locker.ResetOpenAllowance(player) ~= true then
				return "RESET_OPENS_FAILED"
			end
		end
		if grants.petUpgrade == true then
			-- PET_TREATS: pets.upgradeLevel += 1 (cap PET_UPGRADE_MAX_LEVEL).
			-- GrantUpgrade is non-yielding and returns true at the cap (consume,
			-- no extra grant — STARTER_PACK precedent; PetUI hides UPGRADE at cap).
			local pets = getSibling("PetService")
			if pets == nil or type(pets.GrantUpgrade) ~= "function" then
				return "NO_PET_SERVICE"
			end
			if pets.GrantUpgrade(player) ~= true then
				return "PET_UPGRADE_FAILED"
			end
		end
	end

	-- Remaining grants + the idempotency record land in ONE Update so they are
	-- atomic with each other; the receipt is never recorded without them.
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		if not skipGrants then
			if grants.consumables ~= nil then
				for kind, count in grants.consumables :: { [string]: number } do
					local bag = data.consumables :: any
					if type(bag[kind]) == "number" then
						bag[kind] += count
					else
						warn(`[MonetizationService] unknown consumable "{kind}" in {productSpec.sku} — skipped`)
					end
				end
			end
			if grants.cryptlings ~= nil then
				for id, count in grants.cryptlings :: { [string]: number } do
					data.collection[id] = (data.collection[id] or 0) + count
				end
			end
			if type(grants.housingTier) == "number" then
				-- One-way raise: a raced lower-tier receipt can never downgrade.
				data.housing.tier = math.max(data.housing.tier, grants.housingTier)
			end
			if productSpec.onePerAccount == true then
				data.monetization.starterPackOwned = true
			end
		end
		Util.RingAppend(data.monetization.processedReceipts, receiptId, PROCESSED_RECEIPTS_MAX)
	end) == true
	if not updated then
		return "RECORD_FAILED"
	end
	return "GRANTED"
end

--------------------------------------------------------------------------------
-- ProcessReceipt — the single owner (contract: Stage 6 monetization-server)
--------------------------------------------------------------------------------

-- playerOverride: Studio test seam only (player-like fixtures are not in
-- Players, so GetPlayerByUserId cannot find them).
local function handleReceipt(receipt: any, playerOverride: any?): Enum.ProductPurchaseDecision
	if
		type(receipt) ~= "table"
		or type(receipt.PurchaseId) ~= "string"
		or receipt.PurchaseId == ""
		or type(receipt.ProductId) ~= "number"
		or type(receipt.PlayerId) ~= "number"
	then
		warn("[MonetizationService] malformed receipt — NotProcessedYet")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local sku = resolveDevProductSku(receipt.ProductId)
	local productSpec = if sku ~= nil then ProductCatalog.Get(sku) else nil
	if sku == nil or productSpec == nil then
		warn(`[MonetizationService] receipt for unknown ProductId {receipt.ProductId} — NotProcessedYet`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player: any = playerOverride
	if player == nil then
		player = Players:GetPlayerByUserId(receipt.PlayerId)
	end
	if player == nil then
		-- Player left: Roblox redelivers the receipt on their next join.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- profile not locked yet; retry
	end

	-- Fast idempotency path: already granted on a previous delivery.
	local data = dataService.Get(player) :: Types.ProfileData?
	if data ~= nil and hasProcessedReceipt(data, receipt.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- §8.1 defense-in-depth: never DELIVER paid randomness to a restricted
	-- player, even if a prompt raced the storefront gate. NotProcessedYet is
	-- the platform refund path.
	if productSpec.isRandom and isRandomRestricted(player) then
		warn(`[MonetizationService] refusing random SKU {sku} for restricted player {tostring(player.Name)} (§8.1)`)
		track(player, "purchase_failed", { sku = sku, reason = "random_restricted" })
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Housing discount defense: a discounted "_UP_" SKU bought below its
	-- prerequisite tier would skip tiers at the discount price. Refuse ->
	-- platform refund. Buying at/above the granted tier is harmless (max()
	-- no-op) and stays granted for idempotency.
	if type(productSpec.requiresHousingTier) == "number" and productSpec.requiresHousingTier > 0 then
		local live = dataService.Get(player) :: Types.ProfileData?
		local tier = if live ~= nil and type(live.housing) == "table" then live.housing.tier else 0
		if tier < productSpec.requiresHousingTier then
			warn(
				`[MonetizationService] refusing {sku}: housing tier {tier} below required {productSpec.requiresHousingTier}`
			)
			track(player, "purchase_failed", { sku = sku, reason = "housing_tier_too_low" })
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	local ok, status = dataService.WithLock(player, function()
		return applyReceiptLocked(player, productSpec, receipt.PurchaseId)
	end)
	if not ok then
		track(player, "purchase_failed", { sku = sku, reason = "lock_error" })
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if status == "ALREADY" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if status ~= "GRANTED" then
		warn(`[MonetizationService] grant failed for {sku} ({tostring(status)}) — NotProcessedYet`)
		track(player, "purchase_failed", { sku = sku, reason = tostring(status) })
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local row = PriceLadder.GetRow(sku)
	local price = if type(receipt.CurrencySpent) == "number"
		then receipt.CurrencySpent
		else (if row ~= nil then row.priceRobux else 0)
	track(player, "purchase", { sku = sku, price = price })
	fireClient("ShopGrant", player, { sku = sku, summary = describeGrants(productSpec.grants) })
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--------------------------------------------------------------------------------
-- GamePass cache refresh + purchase-finished hook
--------------------------------------------------------------------------------

-- Pcall-refreshes every catalog game pass into profile.monetization.passCache.
-- May yield (UserOwnsGamePassAsync); call from spawned join flow only.
local function refreshPassCache(player: Player)
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return
	end

	local fetched: { [string]: boolean } = {}
	for _, sku in gamePassSkus do
		local assetId = resolveAssetIdForSku(sku)
		if assetId > 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, assetId)
			end)
			if ok and type(owns) == "boolean" then
				fetched[sku] = owns
			end
		end
	end
	if next(fetched) == nil then
		return -- nothing resolvable (assetIds still 0 placeholders) or all pcalls failed
	end

	local vipBefore = MonetizationService.OwnsPass(player, SKU_PASS_VIP_LOCKER)
	dataService.Update(player, function(data: Types.ProfileData)
		for sku, owns in fetched do
			data.monetization.passCache[sku] = owns
		end
	end)

	if player.Parent == nil then
		return
	end
	-- Publish minimap ownership as a replicated attribute the MinimapController
	-- (client) reads to gate the in-shift map.
	pcall(function()
		player:SetAttribute("OwnsMinimap", MonetizationService.OwnsPass(player, "PASS_MINIMAP"))
	end)
	applyGoldenSetIfOwned(player) -- covers a spawn that beat the cache refresh
	if MonetizationService.OwnsPass(player, SKU_PASS_VIP_LOCKER) ~= vipBefore then
		local locker = getSibling("LockerService")
		if locker ~= nil and type(locker.NotifyLockerChanged) == "function" then
			task.spawn(function()
				pcall(locker.NotifyLockerChanged, player)
			end)
		end
	end
end

local function onGamePassPurchaseFinished(player: Player, gamePassId: number, wasPurchased: boolean)
	if wasPurchased ~= true then
		return
	end
	local sku = resolveGamePassSku(gamePassId)
	if sku == nil then
		warn(`[MonetizationService] purchase finished for unknown gamePassId {gamePassId}`)
		return
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		warn(
			`[MonetizationService] pass {sku} bought before profile load for {player.Name}; join refresh will catch it`
		)
		return
	end

	local recorded = dataService.Update(player, function(data: Types.ProfileData)
		data.monetization.passCache[sku] = true
	end) == true
	if not recorded then
		return
	end

	local row = PriceLadder.GetRow(sku)
	track(player, "purchase", { sku = sku, price = if row ~= nil then row.priceRobux else 0 })
	fireClient("ShopGrant", player, {
		sku = sku,
		summary = `{if row ~= nil then row.displayName else sku} unlocked`,
	})

	if sku == SKU_PASS_GOLDEN_SET then
		applyGoldenSetIfOwned(player)
	elseif sku == SKU_PASS_VIP_LOCKER then
		-- Opens/day just changed; refresh the owner's locker snapshot.
		local locker = getSibling("LockerService")
		if locker ~= nil and type(locker.NotifyLockerChanged) == "function" then
			task.spawn(function()
				pcall(locker.NotifyLockerChanged, player)
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Starter Pack first-purchase break (§4.3)
--------------------------------------------------------------------------------

-- Eligibility shared by the prompt remote and the join re-offer: an offer was
-- made, the 24h window is open, the pack is unowned, sales are flagged on, and
-- the player may buy randomness (the pack contains a Foreman's Key, §8.1).
local function starterPackPromptable(player: any, data: Types.ProfileData, now: number): (boolean, string?)
	if Flags.starterPackEnabled ~= true then
		return false, "DISABLED"
	end
	if data.monetization.starterPackOwned then
		return false, "OWNED"
	end
	if data.monetization.starterPackOfferAt <= 0 then
		return false, "NOT_OFFERED"
	end
	if now > data.monetization.starterPackOfferAt + GameConstants.STARTER_PACK_OFFER_SECONDS then
		return false, "EXPIRED"
	end
	if isRandomRestricted(player) then
		return false, "RESTRICTED"
	end
	return true, nil
end

-- The exactly-once trigger: stats.secondExtractionAt set (ExtractionService),
-- no offer made yet. starterPackOfferAt is persisted before the client sees
-- anything, so the offer fires once per ACCOUNT, ever.
local function maybeOfferStarterPack(player: any)
	if Flags.starterPackEnabled ~= true then
		return
	end
	local dataService = getDataService()
	if dataService == nil then
		return
	end
	-- Cheap read-only probe before taking the lock (poll path runs every few
	-- seconds for every online player).
	local probe = dataService.Get(player) :: Types.ProfileData?
	if
		probe == nil
		or probe.stats.secondExtractionAt <= 0
		or probe.monetization.starterPackOfferAt ~= 0
		or probe.monetization.starterPackOwned
	then
		return
	end
	if isRandomRestricted(player) then
		return -- §8.1: the pack contains a key; restricted players never see it
	end

	dataService.WithLock(player, function()
		local live = dataService.Get(player) :: Types.ProfileData?
		if
			live == nil
			or live.stats.secondExtractionAt <= 0
			or live.monetization.starterPackOfferAt ~= 0
			or live.monetization.starterPackOwned
		then
			return
		end
		local now = os.time()
		local updated = dataService.Update(player, function(data: Types.ProfileData)
			data.monetization.starterPackOfferAt = now
		end) == true
		if not updated then
			return
		end
		fireClient("StarterPackOffer", player, { expiresAt = now + GameConstants.STARTER_PACK_OFFER_SECONDS })
		track(player, "starter_pack_shown")
	end)
end

-- Rejoin inside the 24h window: re-surface the running timer (no analytics —
-- starter_pack_shown fires only on the original offer).
local function reofferStarterPackIfOpen(player: Player)
	local dataService = getDataService()
	if dataService == nil then
		return
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return
	end
	local eligible = starterPackPromptable(player, data, os.time())
	if eligible then
		fireClient("StarterPackOffer", player, {
			expiresAt = data.monetization.starterPackOfferAt + GameConstants.STARTER_PACK_OFFER_SECONDS,
		})
	end
end

local function onRequestStarterPackPrompt(player: Player): { ok: boolean, err: string? }
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return { ok = false, err = "NO_PROFILE" }
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return { ok = false, err = "NO_PROFILE" }
	end
	local eligible, why = starterPackPromptable(player, data, os.time())
	if not eligible then
		return { ok = false, err = why }
	end
	local assetId = resolveAssetIdForSku(SKU_STARTER_PACK)
	if assetId <= 0 then
		warn("[MonetizationService] STARTER_PACK assetId is still a placeholder — cannot prompt")
		return { ok = false, err = "UNAVAILABLE" }
	end
	local promptOk = pcall(function()
		MarketplaceService:PromptProductPurchase(player, assetId)
	end)
	if not promptOk then
		return { ok = false, err = "PROMPT_FAILED" }
	end
	return { ok = true }
end

--------------------------------------------------------------------------------
-- Housing SKU selection (LOBBY_SOP §5.1/§5.4) — the server computes the next
-- housing product from profile.housing.tier via HouseTransitions.NextCta and
-- prompts ONLY that SKU; a client-chosen housing SKU is never trusted.
-- ProcessReceipt independently re-validates requiresHousingTier at grant time
-- (the refusal path above), so even a stale prompt — buy at tier 1, get
-- gifted tier 2 mid-modal — can never skip tiers at a discount.
--------------------------------------------------------------------------------

-- Last prompt timestamp per player (os.clock) — prompt-spam cooldown.
local housingPromptLastAt: { [Player]: number } = {}

-- The player's live housing tier, or nil while the profile isn't loaded.
local function housingTierOf(player: any): number?
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return nil
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil or type(data.housing) ~= "table" then
		return nil
	end
	return data.housing.tier
end

-- State-gated CTA copy for lot signs (ShelfRoomBuilder owner sign) and the
-- ShopUI "next step" card: SOP §5.4 verbatim wording from LobbyConfig with
-- the live GetProductInfo price substituted when it resolves (the fallback
-- copy already carries the suite-pinned PriceLadder price, so a failed
-- lookup degrades to the ladder price by construction). nil = no CTA: tier
-- cap, or profile not loaded — callers keep their own fallback copy.
function MonetizationService.GetHousingCtaText(player: any): string?
	local tier = housingTierOf(player)
	if tier == nil then
		return nil
	end
	local sku = HouseTransitions.NextCta(tier)
	local label: string? = LobbyConfig.HOUSING_CTA_FALLBACK[tier]
	if sku == nil or label == nil then
		return nil -- tier cap (3): nothing left to sell (SOP §5.4)
	end
	local livePrice = MonetizationService.GetLivePriceRobux(sku)
	if livePrice ~= nil then
		label = string.gsub(label :: string, "%d+ R%$", `{livePrice} R$`, 1)
	end
	return label
end

-- The ONLY housing prompt site in the game (SOP §5.1). Reads the tier from
-- the profile at call time, never from any client input. The cooldown burns
-- on every call (even refused ones) so a spamming client can't flood prompts
-- or warns (Security Review Scope §1: >= 3 s).
function MonetizationService.PromptNextHousing(player: any): { ok: boolean, sku: string?, err: string? }
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return { ok = false, err = "NOT_LOADED" }
	end
	local now = os.clock()
	local lastAt = housingPromptLastAt[player]
	if lastAt ~= nil and now - lastAt < HOUSING_PROMPT_COOLDOWN_SECONDS then
		return { ok = false } -- silent refusal, zero side effects
	end
	housingPromptLastAt[player] = now

	local tier = housingTierOf(player)
	if tier == nil then
		return { ok = false, err = "NOT_LOADED" }
	end
	local sku = HouseTransitions.NextCta(tier)
	if sku == nil then
		return { ok = false, err = "AT_MAX" } -- mansion owners: nothing to sell
	end
	local assetId = resolveAssetIdForSku(sku)
	if assetId <= 0 then
		warn(`[MonetizationService] {sku} assetId is still a placeholder — cannot prompt housing`)
		return { ok = false, sku = sku, err = "NOT_WIRED" }
	end
	local promptOk = pcall(function()
		MarketplaceService:PromptProductPurchase(player, assetId)
	end)
	if not promptOk then
		return { ok = false, sku = sku, err = "NOT_WIRED" }
	end
	track(player, "housing_prompted", { sku = sku, tier = tier })
	return { ok = true, sku = sku }
end

--------------------------------------------------------------------------------
-- Join flow
--------------------------------------------------------------------------------

-- Guards against double-wiring a player who joins between Init (PlayerAdded
-- connect) and Start (catch-up sweep over Players:GetPlayers()).
local joinWired: { [Player]: boolean } = {}

local function wirePlayer(player: Player)
	if joinWired[player] then
		return
	end
	joinWired[player] = true
	player.CharacterAdded:Connect(function(character: Model)
		if MonetizationService.OwnsPass(player, SKU_PASS_GOLDEN_SET) then
			applyGoldenSet(character)
		end
	end)
end

local function onPlayerJoined(player: Player)
	wirePlayer(player)
	local dataService = getDataService()
	if dataService == nil then
		return
	end
	local deadline = os.clock() + PROFILE_WAIT_TIMEOUT_SECONDS
	while not dataService.IsLoaded(player) do
		if player.Parent == nil or os.clock() >= deadline then
			return
		end
		task.wait(PROFILE_WAIT_POLL_SECONDS)
	end
	refreshPassCache(player)
	if player.Parent == nil then
		return
	end
	applyGoldenSetIfOwned(player) -- cached ownership from a previous session
	reofferStarterPackIfOpen(player)
	maybeOfferStarterPack(player) -- e.g. flags flipped on since their 2nd extraction
end

--------------------------------------------------------------------------------
-- Test hooks (Studio-only — mock-receipt acceptance specs; never production)
--------------------------------------------------------------------------------

-- Maps a sku to a fake Roblox assetId in BOTH directions so mock receipts and
-- mock pass-purchase callbacks resolve without Creator Dashboard products.
function MonetizationService.SetAssetIdForTest(sku: string, assetId: number): boolean
	if not RunService:IsStudio() then
		return false
	end
	local productSpec = ProductCatalog.Get(sku)
	if productSpec == nil or type(assetId) ~= "number" or assetId <= 0 then
		return false
	end
	testAssetIdBySku[sku] = assetId
	if productSpec.kind == "GamePass" then
		testGamePassSkuByAsset[assetId] = sku
	else
		testDevProductSkuByAsset[assetId] = sku
	end
	return true
end

-- Runs the real receipt handler against a mock receipt. playerLike (optional)
-- substitutes a PlayerDataService.LoadMockProfileForTest fixture for the
-- Players:GetPlayerByUserId lookup.
function MonetizationService.ProcessReceiptForTest(receipt: any, playerLike: any?): Enum.ProductPurchaseDecision
	if not RunService:IsStudio() then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return handleReceipt(receipt, playerLike)
end

-- Forces (true/false) or clears (nil) the compliance answer for one player so
-- specs can exercise both sides of the §8.1 gate without PolicyService.
function MonetizationService.SetRandomRestrictedForTest(player: any, restricted: boolean?)
	if not RunService:IsStudio() then
		return
	end
	restrictedOverride[player] = restricted
end

-- Forces (true/false) or clears (nil) one pass answer for one player.
function MonetizationService.SetPassOwnedForTest(player: any, sku: string, owns: boolean?)
	if not RunService:IsStudio() then
		return
	end
	local overrides = passOwnedOverride[player]
	if overrides == nil then
		overrides = {}
		passOwnedOverride[player] = overrides
	end
	overrides[sku] = owns
	if next(overrides) == nil then
		passOwnedOverride[player] = nil
	end
end

-- Runs the second-extraction trigger immediately (no poll wait).
function MonetizationService.RunStarterPackCheckForTest(player: any)
	if not RunService:IsStudio() then
		return
	end
	maybeOfferStarterPack(player)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Shop.DevBuy — STUDIO-ONLY playtest purchases. The Creator Dashboard products
-- don't exist yet (assetId 0), so in Studio the client BUY buttons fall back
-- to this remote, which drives the SAME receipt pipeline as a real Robux
-- purchase (dev products) or the pass cache (game passes). Hard-refused
-- outside Studio: in production this remote is a stub that always declines.
--------------------------------------------------------------------------------

local devBuyNextAssetId = 900000001

local function onDevBuy(player: Player, sku: any): { [string]: any }
	if not RunService:IsStudio() then
		return { ok = false, err = "NOT_STUDIO" }
	end
	if type(sku) ~= "string" then
		return { ok = false, err = "BAD_ARG" }
	end
	local row = PriceLadder.GetRow(sku)
	local productSpec = ProductCatalog.Get(sku)
	if row == nil or productSpec == nil or not row.wiredInMvp then
		return { ok = false, err = "UNKNOWN_SKU" }
	end

	if productSpec.kind == "GamePass" then
		-- Passes skip receipts: cache the entitlement exactly like a finished
		-- PromptGamePassPurchase would.
		local dataService = getDataService()
		if dataService == nil or not dataService.IsLoaded(player) then
			return { ok = false, err = "NOT_LOADED" }
		end
		dataService.Update(player, function(data: Types.ProfileData)
			data.monetization.passCache[sku] = true
		end)
		fireClient("ShopGrant", player, { sku = sku, summary = `{row.displayName} unlocked (Studio test purchase)` })
		track(player, "purchase", { sku = sku, price = row.priceRobux, devBuy = true })
		return { ok = true }
	end

	-- Dev products: synthesize a stable test assetId, then run the REAL
	-- receipt pipeline (idempotency, compliance gate, atomic grants, ShopGrant).
	if testAssetIdBySku[sku] == nil then
		MonetizationService.SetAssetIdForTest(sku, devBuyNextAssetId)
		devBuyNextAssetId += 1
	end
	local receipt = {
		ProductId = testAssetIdBySku[sku],
		PurchaseId = HttpService:GenerateGUID(false),
		PlayerId = player.UserId,
		CurrencySpent = row.priceRobux,
	}
	local decision = MonetizationService.ProcessReceiptForTest(receipt, player)
	if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
		return { ok = true }
	end
	return { ok = false, err = "NOT_GRANTED" } -- compliance gate or grant failure
end

--------------------------------------------------------------------------------
-- GrantSkuForAdmin — R4-1 admin grant gate (LOBBY_BUILD_PLAN_R4 binding
-- decision 1; AdminService.UnlockAll is the only shipped caller). The same
-- pipeline as the Studio DevBuy above, but ADMIN-gated instead of Studio-
-- gated: auth lives HERE at the mutation (first line, fail closed when
-- AdminService is unresolvable), not only in the chat layer. Writes the
-- test-asset maps DIRECTLY and runs receipts through handleReceipt directly,
-- so the Studio-gated seams (SetAssetIdForTest / ProcessReceiptForTest) and
-- onDevBuy's NOT_STUDIO refusal stay byte-identical and independent. Receipts
-- still flow through the REAL handler: idempotency, the §8.1 compliance gate,
-- the requiresHousingTier refusal, atomic grants and the ShopGrant toast all
-- apply (a compliance-declined random SKU returning NOT_GRANTED is correct).
-- Analytics are tagged adminGrant = true — never recorded as a real receipt.
--------------------------------------------------------------------------------

function MonetizationService.GrantSkuForAdmin(
	targetPlayer: any,
	sku: string,
	actorUserId: number
): { ok: boolean, err: string? }
	local adminService = getSibling("AdminService")
	if adminService == nil or type(adminService.IsAdmin) ~= "function" or adminService.IsAdmin(actorUserId) ~= true then
		return { ok = false, err = "NOT_ADMIN" } -- fail closed at the mutation
	end
	if type(sku) ~= "string" then
		return { ok = false, err = "UNKNOWN_SKU" }
	end
	local row = PriceLadder.GetRow(sku)
	local productSpec = ProductCatalog.Get(sku)
	if row == nil or productSpec == nil or row.wiredInMvp ~= true then
		return { ok = false, err = "UNKNOWN_SKU" }
	end

	if productSpec.kind == "GamePass" then
		-- Already owned: idempotent short-circuit (UnlockAll re-runs cleanly).
		if MonetizationService.OwnsPass(targetPlayer, sku) then
			return { ok = true }
		end
		local dataService = getDataService()
		if dataService == nil or not dataService.IsLoaded(targetPlayer) then
			return { ok = false, err = "NOT_LOADED" }
		end
		dataService.Update(targetPlayer, function(data: Types.ProfileData)
			data.monetization.passCache[sku] = true
		end)
		fireClient("ShopGrant", targetPlayer, { sku = sku, summary = `{row.displayName} unlocked (admin grant)` })
		track(targetPlayer, "purchase", { sku = sku, devBuy = false, adminGrant = true })
		return { ok = true }
	end

	-- Dev products: continue the devBuy test-assetId counter with DIRECT map
	-- writes (never via the Studio-gated SetAssetIdForTest), then run the real
	-- receipt handler directly (never via the Studio-gated ProcessReceiptForTest).
	if testAssetIdBySku[sku] == nil then
		testAssetIdBySku[sku] = devBuyNextAssetId
		testDevProductSkuByAsset[devBuyNextAssetId] = sku
		devBuyNextAssetId += 1
	end
	local receipt = {
		ProductId = testAssetIdBySku[sku],
		PurchaseId = HttpService:GenerateGUID(false),
		PlayerId = if type((targetPlayer :: any).UserId) == "number" then targetPlayer.UserId else 0,
		CurrencySpent = row.priceRobux,
	}
	local decision = handleReceipt(receipt, targetPlayer)
	if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
		track(targetPlayer, "purchase", { sku = sku, devBuy = false, adminGrant = true })
		return { ok = true }
	end
	return { ok = false, err = "NOT_GRANTED" } -- compliance gate or grant failure
end

function MonetizationService:Init()
	-- No yields (loader contract). Remotes already exist (init.server runs
	-- Remotes.InitServer() first).

	local okDevBuy, errDevBuy = pcall(function()
		Remotes.GetFunction("Shop.DevBuy").OnServerInvoke = onDevBuy
	end)
	if not okDevBuy then
		warn(`[MonetizationService] Shop.DevBuy bind failed: {errDevBuy}`)
	end

	-- Single ProcessReceipt owner in the game (assigning twice would silently
	-- drop the first owner — nothing else may set this).
	local okReceipt, errReceipt = pcall(function()
		MarketplaceService.ProcessReceipt = function(receipt: any): Enum.ProductPurchaseDecision
			local ok, decision = pcall(handleReceipt, receipt)
			if ok and decision ~= nil then
				return decision
			end
			warn(`[MonetizationService] ProcessReceipt errored: {tostring(decision)}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end)
	if not okReceipt then
		warn(`[MonetizationService] ProcessReceipt bind failed: {errReceipt}`)
	end

	local okPrompt, errPrompt = pcall(function()
		Remotes.GetFunction("Shop.RequestStarterPackPrompt").OnServerInvoke = function(player: Player)
			return onRequestStarterPackPrompt(player)
		end
	end)
	if not okPrompt then
		warn(`[MonetizationService] Shop.RequestStarterPackPrompt bind failed: {errPrompt}`)
	end

	-- Shop.PromptHousing TAKES NO ARGUMENTS BY DESIGN (SOP §5.1): the server
	-- computes the SKU from profile.housing.tier. Anything the client passes
	-- is refused fail-closed with zero side effects (Security Review Scope §1
	-- arg-type discipline — no client SKU selection channel may ever exist).
	local okHousing, errHousing = pcall(function()
		Remotes.GetFunction("Shop.PromptHousing").OnServerInvoke = function(player: Player, ...: any)
			if select("#", ...) > 0 then
				return { ok = false }
			end
			return MonetizationService.PromptNextHousing(player)
		end
	end)
	if not okHousing then
		warn(`[MonetizationService] Shop.PromptHousing bind failed: {errHousing}`)
	end

	local okPass, errPass = pcall(function()
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(player: Player, gamePassId: number, wasPurchased: boolean)
				task.spawn(onGamePassPurchaseFinished, player, gamePassId, wasPurchased)
			end
		)
	end)
	if not okPass then
		warn(`[MonetizationService] PromptGamePassPurchaseFinished connect failed: {errPass}`)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerJoined, player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		joinWired[player] = nil
		restrictedOverride[player] = nil
		passOwnedOverride[player] = nil
		housingPromptLastAt[player] = nil
	end)
end

function MonetizationService:Start()
	-- Players who joined before this service loaded (loader races PlayerAdded).
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerJoined, player)
	end

	-- §4.3 trigger watch: stats.secondExtractionAt is written by
	-- ExtractionService at the 2nd successful extraction (shift Complete
	-- adjacent); this poll turns it into the one-time offer within seconds.
	task.spawn(function()
		while true do
			task.wait(STARTER_PACK_POLL_SECONDS)
			for _, player in Players:GetPlayers() do
				task.spawn(maybeOfferStarterPack, player)
			end
		end
	end)
end

return MonetizationService
