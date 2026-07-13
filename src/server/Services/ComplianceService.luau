--!strict
-- CRYPTLINGS: NIGHT SHIFT — ComplianceService (Stage 6, SOP §8.1).
-- Compliance is a LAUNCH BLOCKER (§3.1): every paid-random surface in the game
-- routes through this service. Owns the Shop.GetCatalog remote (contract §B)
-- and the boot-time monetization invariant audit.
--
-- ============================ §8.1 CHECKLIST MAP ============================
-- Each checklist item -> the enforcing code in this file (searchable [TAG]),
-- or MANUAL where no code can enforce it. PR signs off against this block
-- before any SKU goes live.
--
-- [ ] Paid random items declared in the Maturity & Compliance Questionnaire
--     (direct AND indirect — Robux -> keys -> cases counts).
--       MANUAL: Maturity & Compliance Questionnaire (Creator Dashboard).
--       Code keeps the declaration honest: ProductCatalog marks STARTER_PACK,
--       FOREMANS_KEY and every CASE_BUNDLE_* isRandom=true (indirect counts),
--       and the [AUDIT] below fails loudly if any isRandom SKU ships without
--       an odds disclosure.
-- [ ] Pre-purchase odds disclosure per rarity tier on every case purchase UI,
--     matching the in-hub odds board exactly.
--       [ODDS] buildCatalogEntries(): every isRandom CatalogEntry carries
--       odds = RarityTable.GetOdds(<disclosure tier>) — the SAME function
--       whose output the GetOddsTable remote (UnboxService) returns and the
--       hub odds board (HubService/OddsUI) renders. One function, three
--       surfaces, zero drift. The disclosure tier is per rarity tier as the
--       checklist demands: bundles disclose the tier of the cases they grant
--       (Tier 2 baseline, contract §E), the Foreman's Key — and the Starter
--       Pack that contains one — disclose the Tier 3 vault case it opens
--       (GameConstants.VAULT_CASE_TIER). [AUDIT] verifies every isRandom
--       entry's odds equal that function's output element-for-element at boot.
-- [ ] All paid-random SKUs gated off for UK users under 18 via PolicyService
--     (ArePaidRandomItemsRestricted); those players see only deterministic
--     bundles.
--       [GATE] IsRandomRestricted(player): PolicyService policy fetched on
--       join (pcall'd), cached; ANY error / missing / non-boolean field =>
--       restricted=true (FAIL-CLOSED). onGetCatalog() feeds it into
--       ProductCatalog.GetSellable(restricted, Flags), so restricted players
--       receive randomRestricted=true and ONLY deterministic items (passes,
--       EXTRA_OPENING, SCENT_SPRAY, REVIVE_BEACON — no bundles, no keys, no
--       Starter Pack). MonetizationService consults this same function before
--       firing StarterPackOffer and before prompting/granting any isRandom
--       receipt (contract §I), so restricted players can neither see nor buy
--       random SKUs.
-- [ ] No Robux/item wagering anywhere (gambling ban); trading stays
--     Robux-free with confirm-twice UI, scam reporting, and full trade logs
--     for rollback.
--       [TRADE-GUARD] By construction — see the block above :Start(). This
--       service deliberately exposes NO trade hooks. Confirm-twice and the
--       TradeLedger_v1 rollback log are owned by TradeService/TradeLedger
--       (Stage 4).
-- [ ] No unlicensed IP in any toy line or collab.
--       MANUAL: legal review per toy line / collab. Toy Line 1 ("Factory
--       Floor Misfits", RarityTable.CRYPTLINGS) is an original roster.
-- [ ] No misleading icons/thumbnails.
--       MANUAL: creative review per icon/thumbnail test (SOP §7).
-- [ ] Group (not personal account) owns the experience; ID verification +
--     W-9/W-8 filed before first DevEx request.
--       MANUAL: group ownership + tax forms (Creator Dashboard / DevEx).
-- [ ] Roblox Plus subscription active (required for publish/update).
--       MANUAL: Roblox Plus on the publishing account.
-- ============================================================================
--
-- Remotes owned here (contract §B):
--   Shop.GetCatalog() -> {items: {Types.CatalogEntry}, randomRestricted: boolean}
--
-- Public API (contract §I — the ONLY cross-stage entry point):
--   ComplianceService.IsRandomRestricted(player) -> boolean   (fail-closed true)
-- Test hooks (acceptance / TestEZ only):
--   ComplianceService.SetRestrictedForTest(player, restricted: boolean?)
--   ComplianceService.RunAuditForTest(rows?) -> {string}  (failure messages)
--
-- [AUDIT] Boot-time invariant audit (:Start()): every sellable catalog entry's
-- price must equal its Price Ladder of Record row; every isRandom entry must
-- carry its disclosure-tier odds table; assetId==0 entries are logged
-- "NOT LIVE — fill in Creator Dashboard" so no SKU dies silently. Failures
-- warn loudly AND emit analytics purchase_failed{sku, reason="AUDIT"}.

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Economy = Shared:WaitForChild("Economy")
local PriceLadder = require(Economy:WaitForChild("PriceLadder"))
local ProductCatalog = require(Economy:WaitForChild("ProductCatalog"))
local Flags = require(Economy:WaitForChild("Flags"))

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern — cross-service calls degrade, never
-- error: a missing MonetizationService means owned=false, never a broken shop)
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

local function track(player: Player, event: string, props: { [string]: any }?)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

-- Safe pcall'd pass lookup, defaulting false (contract §I pattern).
local function ownsPass(player: Player, sku: string): boolean
	local monetization = getSibling("MonetizationService")
	if monetization ~= nil and type(monetization.OwnsPass) == "function" then
		local ok, owns = pcall(monetization.OwnsPass, player, sku)
		if ok and owns == true then
			return true
		end
	end
	return false
end

-- LOBBY_SOP §5.4: displayed housing prices are MarketplaceService-live.
-- pcall'd + nil-tolerant (may yield on MonetizationService's 5-min cache miss;
-- fine here — GetCatalog is an OnServerInvoke path, never a receipt lock body).
-- A missing sibling or a not-yet-live product simply omits livePriceRobux and
-- ShopUI falls back to the PriceLadder price.
local function livePriceOf(sku: string): number?
	local monetization = getSibling("MonetizationService")
	if monetization ~= nil and type(monetization.GetLivePriceRobux) == "function" then
		local ok, price = pcall(monetization.GetLivePriceRobux, sku)
		if ok and type(price) == "number" then
			return price
		end
	end
	return nil
end

-- profile.monetization.starterPackOwned, defaulting false while the profile
-- is loading (the entry simply shows as buyable until data is authoritative —
-- MonetizationService re-checks onePerAccount server-side at receipt time).
local function ownsStarterPack(player: Player): boolean
	local playerData = getSibling("PlayerDataService")
	if playerData ~= nil and type(playerData.Get) == "function" then
		local ok, data = pcall(playerData.Get, player)
		if ok and type(data) == "table" and type(data.monetization) == "table" then
			return data.monetization.starterPackOwned == true
		end
	end
	return false
end

-- profile.housing.tier, defaulting 0 while the profile loads. Drives which
-- HOUSING_* SKU is offered (the discount matrix lives in the offer filter:
-- each SKU carries requiresHousingTier = the exact tier it is priced for).
local function housingTierOf(player: Player): number
	local playerData = getSibling("PlayerDataService")
	if playerData ~= nil and type(playerData.Get) == "function" then
		local ok, data = pcall(playerData.Get, player)
		if ok and type(data) == "table" and type(data.housing) == "table" and type(data.housing.tier) == "number" then
			return data.housing.tier
		end
	end
	return 0
end

--------------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------------

local ComplianceService = {}

--------------------------------------------------------------------------------
-- [GATE] PolicyService gating — UK under-18 (and similar) paid-random lockout
--------------------------------------------------------------------------------

-- Cached ArePaidRandomItemsRestricted per player, fetched on join. true is the
-- safe value everywhere in this file: restricted until proven otherwise.
local restrictedCache: { [Player]: boolean } = {}
-- Acceptance test hook: non-nil wins over the policy cache.
local restrictedOverride: { [Player]: boolean } = {}

-- One pcall'd policy fetch. ANY failure mode — API error, nil info, missing or
-- non-boolean field — returns true (FAIL-CLOSED, §8.1).
local function fetchRestricted(player: Player): boolean
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not ok then
		warn(
			`[ComplianceService] GetPolicyInfoForPlayerAsync({player.Name}) failed ({info}) — fail-closed: restricted`
		)
		return true
	end
	if type(info) ~= "table" or type(info.ArePaidRandomItemsRestricted) ~= "boolean" then
		warn(`[ComplianceService] policy info malformed for {player.Name} — fail-closed: restricted`)
		return true
	end
	return info.ArePaidRandomItemsRestricted
end

-- Join-time prime so steady-state IsRandomRestricted calls never yield.
local function primeRestricted(player: Player)
	local restricted = fetchRestricted(player)
	if player.Parent ~= nil then -- player may have left during the async fetch
		restrictedCache[player] = restricted
	end
end

-- Contract §I. true => this player must NEVER see or buy any isRandom SKU
-- (bundles, Foreman's Keys, Starter Pack). Fail-closed: invalid player, no
-- cached policy and a failed fetch all return true. May yield on a cache miss
-- (pre-join-prime race) — fine from remote handlers / ProcessReceipt; never
-- call inside PlayerDataService.Update.
function ComplianceService.IsRandomRestricted(player: Player): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return true
	end
	local override = restrictedOverride[player]
	if override ~= nil then
		return override
	end
	local cached = restrictedCache[player]
	if cached ~= nil then
		return cached
	end
	-- Cache miss: the join prime hasn't landed yet. Fetch inline (pcall'd,
	-- fail-closed) rather than guessing.
	local restricted = fetchRestricted(player)
	if player.Parent ~= nil then
		restrictedCache[player] = restricted
	end
	return restricted
end

-- TEST HOOK (acceptance §8.1 / TestEZ): force a player's restricted state.
-- nil clears the override (back to the real PolicyService answer).
function ComplianceService.SetRestrictedForTest(player: Player, restricted: boolean?)
	warn(`[ComplianceService] SetRestrictedForTest({player.Name}, {tostring(restricted)}) — test hook active`)
	restrictedOverride[player] = restricted
end

--------------------------------------------------------------------------------
-- [ODDS] Shop.GetCatalog — the single storefront feed
--------------------------------------------------------------------------------

-- §8.1 disclosure tier for an isRandom SKU: bundles disclose the tier of the
-- cases they grant (Tier 2 baseline, contract §E); the Foreman's Key — and the
-- Starter Pack that contains one — disclose the Tier 3 vault case it opens.
-- Same tiers the GetOddsTable remote / OddsUI tier tabs serve, so every
-- pre-purchase disclosure matches the board surface for ITS tier exactly.
local function disclosureTier(grants: any): number
	if type(grants) == "table" then
		if type(grants.cases) == "table" and type(grants.cases.tier) == "number" then
			return grants.cases.tier
		end
		if type(grants.consumables) == "table" and type(grants.consumables.foremansKey) == "number" then
			return GameConstants.VAULT_CASE_TIER
		end
	end
	return RarityTable.BASELINE_TIER
end

-- Decorates ProductCatalog.GetSellable rows into wire-safe Types.CatalogEntry.
-- Whitelist-copied: grant specs and any future internal fields never leak to
-- the client. odds is attached to EVERY isRandom entry, straight from
-- RarityTable.GetOdds(disclosureTier) — the same function behind the
-- GetOddsTable remote and the hub odds board (§8.1: they must match).
-- assetId (additive CatalogEntry field) is what ShopUI prompts Marketplace
-- purchases with; 0 = not live yet (ShopUI refuses to prompt).
local function buildCatalogEntries(player: Player, restricted: boolean): { Types.CatalogEntry }
	local sellable = ProductCatalog.GetSellable(restricted, Flags)
	local items: { Types.CatalogEntry } = {}
	local housingTier = housingTierOf(player)
	for _, row in sellable do
		-- Housing offer gate: each HOUSING_* SKU is priced for exactly one
		-- current tier (the discount matrix). Other tiers never see it — except
		-- a fully-upgraded buyer's own target tier, which renders as OWNED.
		if type(row.requiresHousingTier) == "number" and row.requiresHousingTier ~= housingTier then
			local target = if type(row.grants) == "table" then row.grants.housingTier else nil
			local showAsOwned = type(target) == "number" and housingTier >= target and row.requiresHousingTier == 0
			if not showAsOwned then
				continue
			end
		end
		local owned: boolean? = nil
		if row.kind == "GamePass" then
			owned = ownsPass(player, row.sku)
		elseif row.onePerAccount == true then
			owned = ownsStarterPack(player)
		elseif type(row.requiresHousingTier) == "number" then
			local target = if type(row.grants) == "table" then row.grants.housingTier else nil
			owned = type(target) == "number" and housingTier >= target
		end
		local productSpec = ProductCatalog.Get(row.sku)
		table.insert(items, {
			sku = row.sku,
			displayName = row.displayName,
			priceRobux = row.priceRobux, -- GetSellable reads this off the Price Ladder row
			kind = row.kind :: "DevProduct" | "GamePass",
			isRandom = row.isRandom,
			odds = if row.isRandom then RarityTable.GetOdds(disclosureTier(row.grants)) else nil,
			bonusPct = row.bonusPct,
			owned = owned,
			assetId = if productSpec ~= nil then productSpec.assetId else 0,
			-- LOBBY_SOP §5.4: housing rows carry the GetProductInfo-live price.
			livePriceRobux = if type(row.requiresHousingTier) == "number" then livePriceOf(row.sku) else nil,
		})
	end
	return items
end

local function onGetCatalog(player: Player): { items: { Types.CatalogEntry }, randomRestricted: boolean }
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return { items = {}, randomRestricted = true } -- fail-closed
	end
	local restricted = ComplianceService.IsRandomRestricted(player)
	return {
		items = buildCatalogEntries(player, restricted),
		randomRestricted = restricted,
	}
end

--------------------------------------------------------------------------------
-- [AUDIT] Boot-time invariant audit
--------------------------------------------------------------------------------

export type AuditRow = {
	sku: string,
	priceRobux: number,
	isRandom: boolean,
	odds: { Types.OddsRow }?,
	assetId: number,
}

-- Audit failures awaiting analytics: engine analytics events must be
-- attributed to a Player, and the audit runs at boot before anyone joins —
-- failures are flushed as purchase_failed{sku, reason="AUDIT"} against the
-- first player who joins (the warns below fire immediately regardless).
local pendingAuditAnalytics: { { sku: string } } = {}
local auditAnalyticsFlushed = false

local function flushAuditAnalytics(player: Player)
	if auditAnalyticsFlushed or #pendingAuditAnalytics == 0 then
		return
	end
	auditAnalyticsFlushed = true
	for _, failure in pendingAuditAnalytics do
		track(player, "purchase_failed", { sku = failure.sku, reason = "AUDIT" })
	end
end

-- The audited view is deliberately PERMISSIVE — restricted=false and every
-- rollout flag forced on — so flag-gated SKUs (whale bundles, VIP Locker) are
-- audited at boot too: flipping a flag later must never be the moment a bad
-- price or missing disclosure first executes.
local function buildAuditRows(): { AuditRow }
	local permissiveFlags = {
		whaleBundlesLive = true,
		vipLockerPublic = true,
		starterPackEnabled = true,
	}
	local rows: { AuditRow } = {}
	for _, row in ProductCatalog.GetSellable(false, permissiveFlags) do
		local productSpec = ProductCatalog.Get(row.sku)
		local odds = if row.isRandom then RarityTable.GetOdds(disclosureTier(row.grants)) else nil
		table.insert(rows, {
			sku = row.sku,
			priceRobux = row.priceRobux,
			isRandom = row.isRandom,
			odds = odds, -- exactly what buildCatalogEntries attaches
			assetId = if productSpec ~= nil then productSpec.assetId else 0,
		})
	end
	return rows
end

-- The expected disclosure tier for an audited row: derived from the LIVE
-- catalog grant spec by sku (injected test rows for unknown skus fall back to
-- the baseline tier).
local function expectedDisclosureTier(sku: string): number
	local productSpec = ProductCatalog.Get(sku)
	if productSpec ~= nil then
		return disclosureTier(productSpec.grants)
	end
	return RarityTable.BASELINE_TIER
end

local function oddsMismatch(odds: { Types.OddsRow }?, tier: number): string?
	if odds == nil or #odds == 0 then
		return "isRandom entry has NO odds disclosure"
	end
	local expected = RarityTable.GetOdds(tier)
	if #odds ~= #expected then
		return `odds row count {#odds} ~= disclosed Tier {tier} table {#expected}`
	end
	for index, expectedRow in expected do
		local got = odds[index]
		if got.rarity ~= expectedRow.rarity or got.pct ~= expectedRow.pct then
			return `odds[{index}] {got.rarity}={got.pct}% ~= Tier {tier} board {expectedRow.rarity}={expectedRow.pct}%`
		end
	end
	return nil
end

-- Runs the §8.1 invariant audit over the given rows (default: the live
-- permissive catalog). Loud warns + queued purchase_failed analytics per
-- failure; returns the failure messages (TestEZ asserts on these).
local function runAudit(rows: { AuditRow }): { string }
	local failures: { string } = {}

	local function fail(sku: string, message: string)
		local line = `[ComplianceService] AUDIT FAIL {sku}: {message} (§8.1 — launch blocker)`
		warn(line)
		table.insert(failures, line)
		table.insert(pendingAuditAnalytics, { sku = sku })
	end

	for _, row in rows do
		local ladderRow = PriceLadder.GetRow(row.sku)
		if ladderRow == nil then
			fail(row.sku, "no Price Ladder of Record row")
		elseif row.priceRobux ~= ladderRow.priceRobux then
			fail(row.sku, `catalog price {row.priceRobux} R$ ~= Price Ladder row {ladderRow.priceRobux} R$`)
		end

		if row.isRandom then
			local mismatch = oddsMismatch(row.odds, expectedDisclosureTier(row.sku))
			if mismatch ~= nil then
				fail(row.sku, mismatch)
			end
		end

		if row.assetId == 0 then
			-- Logged, not failed: expected pre-dashboard state, but every one of
			-- these is a dead SKU until the id is filled in (silent-failure trap).
			warn(`[ComplianceService] AUDIT: {row.sku} assetId=0 — NOT LIVE — fill in Creator Dashboard`)
		end
	end

	if #failures == 0 then
		print(`[ComplianceService] AUDIT PASS — {#rows} sellable SKUs match the Price Ladder of Record (§8.1)`)
	end
	return failures
end

-- TEST HOOK: run the audit over injected rows (e.g. a deliberately mismatched
-- price) or, with nil, over the live catalog. Returns failure messages.
function ComplianceService.RunAuditForTest(rows: { AuditRow }?): { string }
	return runAudit(rows or buildAuditRows())
end

--------------------------------------------------------------------------------
-- [TRADE-GUARD] Trading is Robux-free BY CONSTRUCTION (§8.1 wagering ban)
--------------------------------------------------------------------------------
-- This service exposes NOTHING to the trade system, deliberately. The §8.1
-- "no Robux/item wagering" requirement is met structurally, not by a runtime
-- filter that could be bypassed:
--   * Types.TradeState carries ONLY {tradeId, players, valueWarning,
--     caseTiers?, values?, valueWarningFor?} and each TradeOffer carries ONLY
--     {offerCaseUids, offerCryptlings, confirmStage}. There is no Robux,
--     price, currency or payment field anywhere in the trade wire contract —
--     nothing for a wager to ride on. (values/valueWarning are the ValueIndex
--     fairness ADVISORY, a unitless scam-warning heuristic — not a currency.)
--   * The Trade.* remotes (contract §B) accept only case uids and cryptling
--     counts; TradeService validates offers against owned items. No remote
--     exists through which Robux could enter a trade.
--   * Adding any Robux-bearing field to TradeState/TradeOffer is therefore a
--     CONTRACT change that must come back through this checklist before ship.
-- Confirm-twice UI (stage 2 only >=3s after both stage-1s), scam value
-- warnings and the full TradeLedger_v1 rollback log are owned by
-- TradeService/TradeLedger (Stage 4) and were verified there.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function ComplianceService:Init()
	-- No yields allowed here (loader contract). Remotes already exist
	-- (init.server runs Remotes.InitServer() before any service Init).
	local ok, err = pcall(function()
		Remotes.GetFunction("Shop.GetCatalog").OnServerInvoke = function(player: Player)
			return onGetCatalog(player)
		end
	end)
	if not ok then
		warn(`[ComplianceService] Shop.GetCatalog bind failed: {err}`)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(primeRestricted, player)
		flushAuditAnalytics(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		restrictedCache[player] = nil
		restrictedOverride[player] = nil
	end)
end

function ComplianceService:Start()
	-- Players who joined before this service started (loader races PlayerAdded).
	for _, player in Players:GetPlayers() do
		if restrictedCache[player] == nil then
			task.spawn(primeRestricted, player)
		end
	end

	-- Boot-time §8.1 invariant audit (loud warns now; purchase_failed analytics
	-- flush against the first player to join — see flushAuditAnalytics).
	runAudit(buildAuditRows())
	local firstPlayer = Players:GetPlayers()[1]
	if firstPlayer ~= nil then
		flushAuditAnalytics(firstPlayer)
	end
end

return ComplianceService
